#requires -Version 7.4
# Re-run an already installed diagnostic probe; never use for product closure.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Razr', 'S23')][string]$Device)
$ErrorActionPreference = 'Stop'
$package = 'dev.mansfieldplumbing.androidsma.preview'
$scriptPath = 'files/kokoro-fl/dspqueue-echo/DspQueueEchoProbe.ps1'
$receiptPath = 'files/kokoro-fl/dspqueue-echo/receipt.txt'
$serials = @(& adb devices | Where-Object { $_ -match '^\S+\s+device$' } |
    ForEach-Object { ($_ -split '\s+')[0] })
$matches = @($serials | Where-Object {
    $model = (& adb -s $_ shell getprop ro.product.model).Trim()
    if ($Device -eq 'Razr') { $model -match 'razr plus 2024' }
    else { $model -eq 'SM-S911U' }
})
if ($matches.Count -ne 1) { throw "Expected exactly one attached $Device device." }
$serial = $matches[0]
$run = {
    param([string[]]$Arguments)
    $result = @(& adb -s $serial @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Device command failed: $($Arguments[0])." }
    $result
}
$requireFile = {
    param([string]$Path)
    [void](& $run @('shell', 'run-as', $package, 'test', '-f', $Path))
}
& $requireFile $scriptPath
& $requireFile $receiptPath
& $requireFile 'files/Start.ps1'
& $requireFile 'files/PROFILE.PS1'
$baseline = @(& $run @('shell', 'run-as', $package, 'sha256sum',
    'files/Start.ps1', 'files/PROFILE.PS1', $receiptPath))
$backup = 'files/kokoro-fl/dspqueue-echo-backup-' + [Guid]::NewGuid().ToString('N')
[void](& $run @('shell', 'run-as', $package, 'mkdir', '-p', $backup))
[void](& $run @('shell', "run-as $package cp files/Start.ps1 $backup/Start.ps1 && run-as $package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && run-as $package cp $receiptPath $backup/receipt.txt"))
$armed = $true
$newReceipt = @()
try {
    [void](& $run @('shell', "am force-stop $package && run-as $package cp $scriptPath files/Start.ps1 && run-as $package cp $scriptPath files/PROFILE.PS1 && run-as $package truncate -s 0 $receiptPath && monkey -p $package -c android.intent.category.LAUNCHER 1"))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 2
        $newReceipt = @(& $run @('shell', 'run-as', $package, 'cat', $receiptPath))
    } while (($newReceipt -join "`n") -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt 90)
    $allowed = '^(Job|UnsignedPdRc|CreateRc|ExportRc|OpenRc|StartRc|Packets|WarmMedianUs|WarmP95Us|WriteMedianUs|ReadMedianUs|ExplicitRemoteInvokesDuringPackets|PollPackets|PollWarmMedianUs|PollReadAttemptsMedian|SynchronousWarmMedianUs|SynchronousWarmP95Us|ExplicitRemoteInvokesForSynchronousBaseline|StopRc|RecoveryStopRc|HandleCloseRc|QueueCloseRc|Passed|Error|At)='
    $fields = @($newReceipt | Where-Object { $_ -match $allowed })
    "Device=$Device"
    "ElapsedSeconds=$([Math]::Round($watch.Elapsed.TotalSeconds, 1))"
    $fields
    if (($newReceipt -join "`n") -notmatch '(?m)^Passed=True$') {
        throw 'Recovered DSPQueue diagnostic failed or timed out.'
    }
}
finally {
    if ($armed) {
        [void](& $run @('shell', "am force-stop $package && run-as $package cp $backup/Start.ps1 files/Start.ps1 && run-as $package cp $backup/PROFILE.PS1 files/PROFILE.PS1 && run-as $package cp $backup/receipt.txt $receiptPath"))
        $restored = @(& $run @('shell', 'run-as', $package, 'sha256sum',
            'files/Start.ps1', 'files/PROFILE.PS1', $receiptPath))
        if (($restored -join "`n") -cne ($baseline -join "`n")) {
            throw 'Diagnostic startup or prior receipt did not restore byte-for-byte.'
        }
        'PriorDeviceStateRestored=True'
    }
}
