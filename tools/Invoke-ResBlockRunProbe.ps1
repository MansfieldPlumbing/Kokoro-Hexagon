#requires -Version 7.4
<#
.SYNOPSIS
Runs the emitted connected resblocks.3 proof job on an attached phone.

.DESCRIPTION
Stages the emitted skel, Native.Binding.psm1, the device harness and a fixture from
New-KokoroResBlockRunFixture.ps1 into the host app's private storage (hash-checked), runs the
harness as the app's startup script, then restores the startup scripts and any replaced file
and verifies the restore by hash. The phone is selected by ro.soc.model; no serial is printed.
#>
param(
    [Parameter(Mandatory)][string] $LibraryPath,
    [Parameter(Mandatory)][string] $FixtureDirectory,
    [Parameter(Mandatory)][string] $Shape,
    [Parameter(Mandatory)][int] $Tiles,
    [Parameter(Mandatory)][long] $Macs,
    [ValidateRange(1, 100)][int] $Runs = 10,
    [ValidateSet('SM8550', 'SM8635')][string] $Soc = 'SM8550',
    [string] $Adb = 'C:\backup\Android\platform-tools\adb.exe',
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview',
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 120,
    [ValidateSet('ResBlock','Generator60x')][string] $Graph = 'ResBlock',
    [string] $CaptureOutputPath,
    [switch] $CompactOutput
)
$ErrorActionPreference = 'Stop'
if ($Package -notmatch '^[a-zA-Z0-9_.]+$') { throw 'Invalid Android package name' }
if ($CaptureOutputPath) {
    $CaptureOutputPath = [IO.Path]::GetFullPath($CaptureOutputPath)
    $buildRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
    if (-not $CaptureOutputPath.StartsWith($buildRoot,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $CaptureOutputPath)) { throw 'Use a new capture file within project build/.' }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($CaptureOutputPath))
}
$serials = @(& $Adb devices | Select-String "`tdevice$" | ForEach-Object { ($_ -split "`t")[0] } |
    Where-Object { (& $Adb -s $_ shell getprop ro.soc.model).Trim() -eq $Soc })
if ($serials.Count -ne 1) { throw "Expected exactly one attached $Soc device, found $($serials.Count)." }
$serial = $serials[0]
$run = { param([string[]]$Arguments)
    $result = & $Adb -s $serial @Arguments 2>&1
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0]) $($Arguments[1])" }
    $result
}
$harness = Join-Path $PSScriptRoot '..\src\runspace\KokoroResBlockRunProbe.ps1'
$binding = Join-Path $PSScriptRoot '..\src\runspace\Native.Binding.psm1'
foreach ($p in $harness, $binding) { $e = $null; $null = [Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e); if ($e.Count) { throw "Does not parse: $p" } }
$spec = Join-Path ([IO.Path]::GetTempPath()) ("hmx-conv-spec-" + [Guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllLines($spec, @("Shape=$Shape", "Graph=$Graph", "Tiles=$Tiles", "Runs=$Runs", "Macs=$Macs", "CaptureOutput=$([int][bool]$CaptureOutputPath)", "Compact=$([int][bool]$CompactOutput)"))

$id = [Guid]::NewGuid().ToString('N')
$temp = "/data/local/tmp/kokoro-resblock-$id"
$backup = "files/kokoro-fl/resblock-backup-$id"
$target = 'files/kokoro-fl/resblock-run'
$startHashes = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
$null = & $run @('shell', "run-as $Package mkdir -p $backup $target files/kokoro-fl/qnn && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")
$replaced = [Collections.Generic.List[string]]::new()
$changed = $false
try {
    $files = @(
        @($harness, "$target/KokoroResBlockRunProbe.ps1"),
        @($binding, 'files/kokoro-fl/Native.Binding.psm1'),
        @($LibraryPath, 'files/kokoro-fl/qnn/libkokoro_resblock_run_skel.so'),
        @($spec, "$target/spec.txt"))
    foreach ($n in 'activations.bin', 'weights.bin', 'tables.bin', 'expected.bin', 'expected-coefficients.bin') { $files += , @((Join-Path $FixtureDirectory $n), "$target/$n") }
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
    $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $target/KokoroResBlockRunProbe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroResBlockRunProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 2
        $receipt = (& $run @('shell', 'run-as', $Package, 'cat', "$target/receipt.txt")) -join "`n"
    } while ($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $outDir = Split-Path $LibraryPath -Parent
    $receiptPath = Join-Path $outDir "device-receipt-$Soc-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    if ($CaptureOutputPath) {
        $expectedHash = [regex]::Matches($receipt,'(?m)^OutputSHA256=([0-9A-F]{64})')
        if ($expectedHash.Count -eq 0) { throw 'No successful device output capture was recorded.' }
        & $Adb -s $serial exec-out run-as $Package cat "$target/captured-output.bin" > $CaptureOutputPath
        if ($LASTEXITCODE -or (Get-FileHash -LiteralPath $CaptureOutputPath).Hash -cne $expectedHash[$expectedHash.Count-1].Groups[1].Value) { throw 'Retrieved device output integrity mismatch.' }
        "CaptureOutputPath=$CaptureOutputPath"
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
    "StagingPreserved=True"
    "SpecPreserved=True"
}
