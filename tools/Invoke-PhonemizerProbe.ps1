#requires -Version 7.4
<#
.SYNOPSIS
Runs the compiled phonemizer driver on an attached phone and checks its token IDs against Windows.

.DESCRIPTION
Stages the driver DLL, src/runspace/KokoroPhonemizerProbe.ps1 and the sentence file into the host app's
private storage (hash-checked), runs the harness as the app's startup script, then restores the startup
scripts and verifies the restore by hash. The same DLL is loaded on Windows from its path to produce the
expected IDs. The phone is selected by ro.soc.model; no serial is printed.
#>
param(
    [Parameter(Mandatory)][string] $DriverPath,
    [string] $SentencePath = (Join-Path $PSScriptRoot '..\phonemizer\corpora\english-pronunciation-challenges.txt'),
    [ValidateSet('SM8550', 'SM8635')][string] $Soc = 'SM8550',
    [string] $Adb = 'C:\backup\Android\platform-tools\adb.exe',
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview',
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'
if ($Package -notmatch '^[a-zA-Z0-9_.]+$') { throw 'Invalid Android package name' }
$driver = [IO.Path]::GetFullPath($DriverPath)
$outputRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build\phonemizer\device'))
[void][IO.Directory]::CreateDirectory($outputRoot)
[string[]]$sentences = [Linq.Enumerable]::ToArray([Linq.Enumerable]::Where(
    [IO.File]::ReadAllLines([IO.Path]::GetFullPath($SentencePath), [Text.UTF8Encoding]::new($false, $true)),
    [Func[string, bool]] { param($line) $line.Trim().Length -gt 0 }))

# Expected IDs from the same DLL on Windows.
$type = [Reflection.Assembly]::LoadFrom($driver).GetType('CoreDriver', $true)
$expected = foreach ($s in $sentences) { $r = $type.GetMethod('Run').Invoke($null, [object[]]@($s)); if ($r.Complete) { $r.SymbolIds -join ',' } else { '' } }

$serials = @(& $Adb devices | ForEach-Object { $p = $_.Split("`t"); if ($p.Count -eq 2 -and $p[1] -eq 'device') { $p[0] } } |
    Where-Object { (& $Adb -s $_ shell getprop ro.soc.model).Trim() -eq $Soc })
if ($serials.Count -ne 1) { throw "Expected exactly one attached $Soc device, found $($serials.Count)." }
$serial = $serials[0]
$run = { param([string[]]$Arguments)
    $result = & $Adb -s $serial @Arguments 2>&1
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0]) $($Arguments[1])" }
    $result }
$harness = Join-Path $PSScriptRoot '..\src\runspace\KokoroPhonemizerProbe.ps1'
$e = $null; $null = [Management.Automation.Language.Parser]::ParseFile($harness, [ref]$null, [ref]$e); if ($e.Count) { throw "Does not parse: $harness" }
$id = [Guid]::NewGuid().ToString('N')
$sentenceFile = Join-Path $outputRoot "sentences-$id.txt"
[IO.File]::WriteAllLines($sentenceFile, [string[]]$sentences, [Text.UTF8Encoding]::new($false))
$temp = "/data/local/tmp/kokoro-phonemizer-$id"
$backup = "files/kokoro-fl/phonemizer-backup-$id"
$target = 'files/kokoro-fl/phonemizer'
$startHashes = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
$null = & $run @('shell', "run-as $Package mkdir -p $backup $target && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")
$changed = $false
try {
    foreach ($file in @(@($harness, "$target/KokoroPhonemizerProbe.ps1"), @($driver, "$target/driver.dll"), @($sentenceFile, "$target/sentences.txt"))) {
        $name = Split-Path $file[1] -Leaf
        $null = & $run @('push', $file[0], "$temp/$name")
        $null = & $run @('shell', "run-as $Package cp $temp/$name $($file[1])")
        $deviceHash = (& $run @('shell', 'run-as', $Package, 'sha256sum', $file[1]) -join '').Split(' ')[0]
        if ($deviceHash -ne (Get-FileHash $file[0]).Hash) { throw "Staged artifact hash mismatch for $name" }
    }
    $null = & $run @('shell', "run-as $Package truncate -s 0 $target/receipt.txt")
    $changed = $true
    $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $target/KokoroPhonemizerProbe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroPhonemizerProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do { Start-Sleep -Seconds 2; $receipt = (& $run @('shell', 'run-as', $Package, 'cat', "$target/receipt.txt")) -join "`n" }
    while ($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $receiptPath = Join-Path $outputRoot "device-receipt-$Soc-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    $mismatch = 0
    for ($i = 0; $i -lt $sentences.Count; $i++) {
        $m = [regex]::Match($receipt, "(?m)^S$i Complete=\S+ MedianUs=\S+ Ids=(.*)$")
        if (-not $m.Success -or $m.Groups[1].Value.Trim() -cne $expected[$i]) { $mismatch++ }
    }
    @($receipt -split "`n" | Where-Object { $_ -notmatch '^S\d+ ' })
    "IdMismatchesVsWindows=$mismatch of $($sentences.Count)"
    "WindowsComplete=$(@($expected | Where-Object { $_ }).Count)"
    "ReceiptPath=$receiptPath"
}
finally {
    if ($changed) {
        $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1")
        $restored = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
        if (($restored -join "`n") -cne ($startHashes -join "`n")) { throw 'Startup restoration hash mismatch' }
        'StartupRestored=True'
    }
    $null = & $run @('shell', "rm -rf $temp")
}
