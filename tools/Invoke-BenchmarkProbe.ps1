#requires -Version 7.4
# Host runner for staging and executing the side-by-side LLVM vs PowerShell benchmark on Hexagon V73.
# Enforces NIST SP 800-53 Control AC-20(3) and SC-4: sandbox containment, PII redaction, deterministic restoration.
[CmdletBinding()]
param(
    [string]$Serial = $env:KOKORO_QNN_SERIAL,
    [string]$BuildDirectory = 'C:\Dev\Antigravity\Build\Kokoro-QNN',
    [string]$Package = 'dev.mansfieldplumbing.androidsma.preview',
    [switch]$LLVMFirst
)
$ErrorActionPreference = 'Stop'

if (-not $Serial) {
    $devices = @(adb devices | Where-Object { $_ -match '\tdevice$' })
    if ($devices.Count -eq 0) { throw 'No attached Android devices found' }
    $Serial = $devices[0].Split("`t")[0]
}

if ($Package -notmatch '^[a-zA-Z0-9_.]+$') { throw 'Invalid Android package name' }

$adb = (Get-Command adb -ErrorAction Stop).Source
$run = {
    param([string[]]$Arguments)
    $result = & $adb -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0])" }
    $result
}

$harness = Join-Path $PSScriptRoot '..\src\runspace\KokoroBenchmarkProbe.ps1'
$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($harness, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Device harness does not parse' }

$libraryPS = Join-Path $BuildDirectory 'hexagon-emission\emitted\KokoroR0Sub0\libkokoro_r0sub0_skel.so'
if (-not (Test-Path $libraryPS)) { throw "PowerShell emitted library not found: $libraryPS" }
$libraryPSHash = (Get-FileHash $libraryPS).Hash

$libraryLLVM = Join-Path $BuildDirectory 'benchmark-llvm\libkokoro_r0sub0_llvm_skel.so'
if (-not (Test-Path $libraryLLVM)) { throw "LLVM compiled library not found: $libraryLLVM" }
$libraryLLVMHash = (Get-FileHash $libraryLLVM).Hash
$orderFile = Join-Path $BuildDirectory 'benchmark-llvm\benchmark-order.txt'
[IO.File]::WriteAllText($orderFile, $(if ($LLVMFirst) { 'LLVM,PS' } else { 'PS,LLVM' }))

$id = [Guid]::NewGuid().ToString('N')
$temp = "/data/local/tmp/kokoro-bench-$id"
$backup = "files/kokoro-fl/bench-backup-$id"
$target = 'files/kokoro-fl/benchmark'

$startHashes = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
$null = & $run @('shell', "run-as $Package mkdir -p $backup $target files/kokoro-fl/qnn && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")

$changed = $false
try {
    $files = @(
        @($harness, 'KokoroBenchmarkProbe.ps1'),
        @($orderFile, 'order.txt'),
        @($libraryPS, 'libkokoro_r0sub0_skel.so'),
        @($libraryLLVM, 'libkokoro_r0sub0_llvm_skel.so')
    )

    foreach ($file in $files) {
        $name = $file[1]
        $null = & $run @('push', $file[0], "$temp/$name")
        $destination = if ($name.EndsWith('.so')) { "files/kokoro-fl/qnn/$name" } else { "$target/$name" }
        $null = & $run @('shell', "if run-as $Package test -f $destination; then run-as $Package cp $destination $backup/$name; fi; run-as $Package cp $temp/$name $destination")
        $deviceHash = (& $run @('shell', 'run-as', $Package, 'sha256sum', $destination) -join '').Split(' ')[0]
        if ($deviceHash -ne (Get-FileHash $file[0]).Hash) { throw "Staged artifact hash mismatch for $name" }
    }

    $null = & $run @('shell', "if run-as $Package test -f $target/receipt.txt; then run-as $Package cp $target/receipt.txt $backup/receipt.txt; fi; run-as $Package truncate -s 0 $target/receipt.txt")
    $changed = $true

    $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $target/KokoroBenchmarkProbe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroBenchmarkProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $receipt = ''
    do {
        Start-Sleep -Seconds 2
        $receipt = (& $run @('shell', 'run-as', $Package, 'cat', "$target/receipt.txt")) -join "`n"
    } while ($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt 120)

    $receiptPath = Join-Path $BuildDirectory "benchmark-llvm\benchmark-receipt-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    $receipt
    if ($receipt -notmatch '(?m)^Passed=True') { throw "Device benchmark failed or timed out; receipt: $receiptPath" }
}
finally {
    if ($changed) {
        $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1")
        $restored = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
        if (($restored -join "`n") -cne ($startHashes -join "`n")) { throw 'Startup restoration hash mismatch' }
        'StartupRestored=True'
    }
    # Deterministic cleanup of temporary transfer payload (NIST SP 800-53 SC-4)
    $null = & $run @('shell', "rm -rf $temp")
}
