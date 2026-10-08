#requires -Version 7.4
<#
.SYNOPSIS
Runs the emitted generator tail job on an attached phone, plays its PCM, and retrieves the output.

.DESCRIPTION
Stages the skel, harness, Native.Binding.psm1, Audio.AAudio.psm1 and the tail fixture into the
host app's private storage (hash-checked), runs the harness as the app's startup script, pulls
run 0's output buffer back (hash-checked against the receipt), then restores the startup scripts
and any replaced file and verifies the restore by hash. The phone is selected by ro.soc.model;
no serial is printed. Check the retrieved buffer with tools/Test-KokoroGeneratorTailOutput.ps1.
#>
param(
    [Parameter(Mandatory)][string] $EmissionDirectory,
    [Parameter(Mandatory)][string] $FixtureDirectory,
    [ValidateRange(1, 20)][int] $Runs = 3,
    [ValidateSet('SM8550', 'SM8635')][string] $Soc = 'SM8550',
    [string] $Adb = 'C:\backup\Android\platform-tools\adb.exe',
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview',
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'
if ($Package -notmatch '^[a-zA-Z0-9_.]+$') { throw 'Invalid Android package name' }
$emission = [IO.Path]::GetFullPath($EmissionDirectory); $fixture = [IO.Path]::GetFullPath($FixtureDirectory)
$layout = Get-Content (Join-Path $emission 'runner-layout.json') -Raw | ConvertFrom-Json
$library = Join-Path $emission 'libkokoro_generator_tail_skel.so'
$serials = @(& $Adb devices | ForEach-Object { $p = $_.Split("`t"); if ($p.Count -eq 2 -and $p[1] -eq 'device') { $p[0] } } |
    Where-Object { (& $Adb -s $_ shell getprop ro.soc.model).Trim() -eq $Soc })
if ($serials.Count -ne 1) { throw "Expected exactly one attached $Soc device, found $($serials.Count)." }
$serial = $serials[0]
$run = { param([string[]]$Arguments)
    $result = & $Adb -s $serial @Arguments 2>&1
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0]) $($Arguments[1])" }
    $result }
$harness = Join-Path $PSScriptRoot '..\src\runspace\KokoroGeneratorTailProbe.ps1'
$binding = Join-Path $PSScriptRoot '..\src\runspace\Native.Binding.psm1'
$aaudio = Join-Path $PSScriptRoot '..\src\runspace\Audio.AAudio.psm1'
foreach ($p in $harness, $binding, $aaudio) { $e = $null; $null = [Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e); if ($e.Count) { throw "Does not parse: $p" } }
$id = [Guid]::NewGuid().ToString('N')
$spec = Join-Path $emission "tail-spec-$id.txt"
[IO.File]::WriteAllLines($spec, @("Tiles=$($layout.Tiles)", "Runs=$Runs", "OutputBytes=$($layout.OutputBytes)", "PcmOffset=$($layout.PcmOffset)", "Samples=$($layout.Samples)", "InputBytes=$($layout.InputBytes)"))
$temp = "/data/local/tmp/kokoro-tail-$id"
$backup = "files/kokoro-fl/generator-tail-backup-$id"
$target = 'files/kokoro-fl/generator-tail'
$startHashes = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
$null = & $run @('shell', "run-as $Package mkdir -p $backup $target files/kokoro-fl/qnn && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")
$replaced = [Collections.Generic.List[string]]::new(); $changed = $false
try {
    $files = @(
        @($harness, "$target/KokoroGeneratorTailProbe.ps1"),
        @($binding, 'files/kokoro-fl/Native.Binding.psm1'),
        @($aaudio, 'files/kokoro-fl/Audio.AAudio.psm1'),
        @($library, 'files/kokoro-fl/qnn/libkokoro_generator_tail_skel.so'),
        @($spec, "$target/spec.txt"))
    foreach ($n in 'activations.bin', 'weights.bin', 'tables.bin') { $files += , @((Join-Path $fixture $n), "$target/$n") }
    foreach ($file in $files) {
        $name = Split-Path $file[1] -Leaf; $destination = $file[1]
        $null = & $run @('push', $file[0], "$temp/$name")
        $existing = (& $run @('shell', "if run-as $Package test -f $destination; then echo yes; fi")) -join ''
        if ($existing -eq 'yes') { $null = & $run @('shell', "run-as $Package cp $destination $backup/$name"); $replaced.Add($destination) }
        $null = & $run @('shell', "run-as $Package cp $temp/$name $destination")
        $deviceHash = (& $run @('shell', 'run-as', $Package, 'sha256sum', $destination) -join '').Split(' ')[0]
        if ($deviceHash -ne (Get-FileHash $file[0]).Hash) { throw "Staged artifact hash mismatch for $name" }
    }
    $null = & $run @('shell', "run-as $Package truncate -s 0 $target/receipt.txt")
    $changed = $true
    $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $target/KokoroGeneratorTailProbe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroGeneratorTailProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do { Start-Sleep -Seconds 2; $receipt = (& $run @('shell', 'run-as', $Package, 'cat', "$target/receipt.txt")) -join "`n" }
    while ($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $receiptPath = Join-Path $emission "device-receipt-$Soc-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    $hash = [regex]::Match($receipt, '(?m)^OutputSHA256=([0-9A-F]{64})')
    if ($hash.Success) {
        $outputPath = Join-Path $emission "device-output-$Soc-$id.bin"
        & $Adb -s $serial exec-out run-as $Package cat "$target/tail-output.bin" > $outputPath
        if ($LASTEXITCODE -or (Get-FileHash -LiteralPath $outputPath).Hash -cne $hash.Groups[1].Value) { throw 'Retrieved device output integrity mismatch.' }
        "OutputPath=$outputPath"
    }
    $receipt
    "ReceiptPath=$receiptPath"
}
finally {
    if ($changed) {
        $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1")
        foreach ($d in $replaced) { $null = & $run @('shell', "run-as $Package cp $backup/$(Split-Path $d -Leaf) $d") }
        $restored = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
        if (($restored -join "`n") -cne ($startHashes -join "`n")) { throw 'Startup restoration hash mismatch' }
        'StartupRestored=True'
    }
    $null = & $run @('shell', "rm -rf $temp")
}
