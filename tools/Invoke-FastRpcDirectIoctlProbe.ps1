#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Serial = $env:KOKORO_QNN_SERIAL,
    [string]$Package = 'dev.mansfieldplumbing.androidsma.preview',
    [string]$BuildDirectory = 'C:\Dev\Antigravity\Build\Kokoro-QNN\direct-fastrpc'
)
$ErrorActionPreference = 'Stop'
if (-not $Serial) {
    $devices = @(adb devices | Where-Object { $_ -match '\tdevice$' })
    if ($devices.Count -ne 1) { throw "Expected one attached Android device, found $($devices.Count)" }
    $Serial = $devices[0].Split("`t")[0]
}
if ($Package -notmatch '^[A-Za-z0-9_.]+$') { throw 'Invalid package name' }
$adb = (Get-Command adb -ErrorAction Stop).Source
$run = {
    param([string[]]$Arguments)
    $result = & $adb -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0])" }
    $result
}
$harness = Join-Path $PSScriptRoot '..\src\runspace\FastRpcDirectIoctlProbe.ps1'
$binding = Join-Path $PSScriptRoot '..\src\runspace\Native.Binding.psm1'
$tokens = $null; $errors = $null
[Management.Automation.Language.Parser]::ParseFile($harness, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw 'Direct ioctl harness does not parse' }
[void][IO.Directory]::CreateDirectory($BuildDirectory)
$id = [Guid]::NewGuid().ToString('N')
$temp = "/data/local/tmp/direct-fastrpc-$id"
$backup = "files/kokoro-fl/direct-fastrpc-backup-$id"
$target = 'files/kokoro-fl/direct-fastrpc'
$startHashes = @(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'))
$null = & $run @('shell', "run-as $Package mkdir -p $backup $target && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")
$changed = $false
try {
    $null = & $run @('push', $harness, "$temp/FastRpcDirectIoctlProbe.ps1")
    $null = & $run @('push', $binding, "$temp/Native.Binding.psm1")
    $null = & $run @('shell', "run-as $Package cp $temp/FastRpcDirectIoctlProbe.ps1 $target/FastRpcDirectIoctlProbe.ps1 && run-as $Package cp $temp/Native.Binding.psm1 $target/Native.Binding.psm1 && run-as $Package truncate -s 0 $target/receipt.txt")
    $deviceHash = ((& $run @('shell','run-as',$Package,'sha256sum',"$target/FastRpcDirectIoctlProbe.ps1")) -join '').Split(' ')[0]
    if ($deviceHash -ne (Get-FileHash $harness).Hash) { throw 'Staged harness hash mismatch' }
    $changed = $true
    $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $target/FastRpcDirectIoctlProbe.ps1 files/Start.ps1 && run-as $Package cp $target/FastRpcDirectIoctlProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch = [Diagnostics.Stopwatch]::StartNew(); $receipt = ''
    do {
        Start-Sleep -Milliseconds 500
        $receipt = (& $run @('shell','run-as',$Package,'cat',"$target/receipt.txt")) -join "`n"
    } while ($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt 20)
    $receiptPath = Join-Path $BuildDirectory "direct-ioctl-receipt-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    $receipt
    if ($receipt -notmatch '(?m)^Passed=True') { throw "Direct FastRPC ioctl probe failed; receipt: $receiptPath" }
}
finally {
    if ($changed) {
        $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1")
        $restored = @(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'))
        if (($restored -join "`n") -cne ($startHashes -join "`n")) { throw 'Startup restoration hash mismatch' }
        'StartupRestored=True'
    }
    $null = & $run @('shell', "rm -rf $temp")
}
