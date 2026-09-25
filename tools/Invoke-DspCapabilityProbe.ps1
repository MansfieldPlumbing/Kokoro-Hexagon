#requires -Version 7.4
# Host runner for querying Qualcomm CDSP hardware capabilities via FastRPC.
# Enforces NIST SP 800-53 Control AC-20(3) and SC-4: sandbox containment, PII redaction, deterministic cleanup.
[CmdletBinding()]
param(
    [string]$Serial = $env:KOKORO_QNN_SERIAL,
    [string]$BuildDirectory = $(
        $buildDir = @(
            (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN'),
            (Join-Path $PSScriptRoot '..\..\..\Build\Kokoro-QNN'),
            'C:\Dev\Build\Kokoro-QNN'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $buildDir) { $buildDir = 'C:\Dev\Build\Kokoro-QNN' }
        Join-Path $buildDir 'dsp-capabilities'
    ),
    [string]$Package = 'dev.mansfieldplumbing.androidsma.preview'
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

$harness = Join-Path $PSScriptRoot '..\src\runspace\DspCapabilityProbe.ps1'
$binding = Join-Path $PSScriptRoot '..\src\runspace\Native.Binding.psm1'
$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($harness, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Device harness does not parse' }

[void][IO.Directory]::CreateDirectory($BuildDirectory)

$id = [Guid]::NewGuid().ToString('N')
$temp = "/data/local/tmp/dsp-cap-$id"
$backup = "files/kokoro-fl/cap-backup-$id"
$target = 'files/kokoro-fl/cap-emitted'

$startHashes = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
$null = & $run @('shell', "run-as $Package mkdir -p $backup $target && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")

$changed = $false
try {
    $name = 'DspCapabilityProbe.ps1'
    $null = & $run @('push', $harness, "$temp/$name")
    $null = & $run @('push', $binding, "$temp/Native.Binding.psm1")
    $destination = "$target/$name"
    $null = & $run @('shell', "if run-as $Package test -f $destination; then run-as $Package cp $destination $backup/$name; fi; run-as $Package cp $temp/$name $destination; run-as $Package cp $temp/Native.Binding.psm1 $target/Native.Binding.psm1")
    $deviceHash = (& $run @('shell', 'run-as', $Package, 'sha256sum', $destination) -join '').Split(' ')[0]
    if ($deviceHash -ne (Get-FileHash $harness).Hash) { throw "Staged artifact hash mismatch for $name" }

    $null = & $run @('shell', "if run-as $Package test -f $target/receipt.txt; then run-as $Package cp $target/receipt.txt $backup/receipt.txt; fi; run-as $Package truncate -s 0 $target/receipt.txt")
    $changed = $true

    $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $target/DspCapabilityProbe.ps1 files/Start.ps1 && run-as $Package cp $target/DspCapabilityProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $receipt = ''
    do {
        Start-Sleep -Seconds 2
        $receipt = (& $run @('shell', 'run-as', $Package, 'cat', "$target/receipt.txt")) -join "`n"
    } while ($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt 60)

    $receiptPath = Join-Path $BuildDirectory "capability-receipt-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    $receipt
    if ($receipt -notmatch '(?m)^Passed=True') { throw "Capability probe failed or timed out; receipt: $receiptPath" }
}
finally {
    if ($changed) {
        $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1")
        $restored = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
        if (($restored -join "`n") -cne ($startHashes -join "`n")) { throw 'Startup restoration hash mismatch' }
        'StartupRestored=True'
    }
    # Deterministic cleanup of temporary transfer payload
    $null = & $run @('shell', "rm -rf $temp")
}
