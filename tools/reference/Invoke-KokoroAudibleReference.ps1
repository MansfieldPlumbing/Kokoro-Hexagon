#requires -Version 7.4
# Replays the pinned, staged historical speech fixture on one Android device.
# This diagnostic never admits a candidate to the direct Hexagon product path.
[CmdletBinding()]
param(
    [string]$Serial = $env:KOKORO_QNN_SERIAL,
    [ValidateRange(5, 120)][int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$package = 'dev.mansfieldplumbing.androidsma.preview'
$root = 'files/kokoro-fl'
$adb = (Get-Command adb -CommandType Application -ErrorAction Stop |
    Select-Object -First 1).Source
if (-not $Serial) {
    $attached = @(& $adb devices | Where-Object { $_ -match "`tdevice$" })
    if ($attached.Count -ne 1) { throw 'Exactly one attached Android device is required.' }
    $Serial = ([string]$attached[0]).Split("`t")[0]
}

function Invoke-Device {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = @(& $adb -s $Serial @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Device operation failed: $($Arguments[0])" }
    $result
}
function Test-DeviceFile {
    param([Parameter(Mandatory)][string]$Path)
    & $adb -s $Serial shell run-as $package test -s $Path 2>$null
    $LASTEXITCODE -eq 0
}
function Get-DeviceHash {
    param([Parameter(Mandatory)][string]$Path)
    $result = @(Invoke-Device @('shell', 'run-as', $package, 'sha256sum', $Path))
    if ($result.Count -ne 1 -or $result[0] -notmatch '^([0-9a-fA-F]{64})\s') {
        throw 'Device hash output is malformed.'
    }
    $Matches[1].ToUpperInvariant()
}

# The historical job is executable PowerShell data. Require its exact archived
# identity before the diagnostic host reads it; text supplied at runtime is
# never admitted through this path.
$pins = [ordered]@{
    'Speak.ps1' = '9C50844759C296AB9039F3B6A9BC7E857C1E4F977199549A9A6881AA3DFE4D32'
    'speak-job.ps1' = '33D60534DD8C0486A055E1C682D9C3C6EFB602D39DB7834B794718484E9C7CE5'
    'modules/Native.Binding.psm1' = 'A9685E1DE665A5FB14905C34C852CC5AEDA2AB779751811B2137FDC5EB309097'
    'modules/Audio.AAudio.psm1' = '02CC2BEAF1CEB3B869BA35876569222E2DFF0FFD16A1D1F66975B4296C0929D4'
    'modules/Qnn.Abi.psm1' = '4294BEA0BCAD6CF6860FA31702E104A6EB1396F2BEF9937811FEF9D6E37EA3A7'
    'modules/Qnn.Native.psm1' = '91740862DB1702501ACFF049668BA1F1EB2B58685BF36EDEBC2D512789D31CF3'
    'modules/Qnn.Graph.psm1' = '56EDC881E264A31103EAB66005258FB8A097F76F6EA70AC7EEBCC66B88B3CE2C'
    'modules/Qnn.Context.psm1' = '424AA7A559C9A5F9B3E3F86DC2B035E48FDFE1634B95D3A74BDCB68CEA9E8016'
}
foreach ($item in $pins.GetEnumerator()) {
    $path = "$root/$($item.Key)"
    if (-not (Test-DeviceFile $path) -or (Get-DeviceHash $path) -cne $item.Value) {
        throw "Staged reference identity mismatch: $($item.Key)"
    }
}
$localSpeak = Join-Path $PSScriptRoot '../../src/runspace/Speak.ps1'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $localSpeak).Hash -cne $pins['Speak.ps1']) {
    throw 'Repository speech harness differs from staged reference.'
}
foreach ($name in @('front.bin', 'gen.bin', 'oracle_audio.f32', 'in_asr.f32',
        'in_F0_curve.f32', 'in_gb.f32', 'in_har8.f32', 'in_mask.f32',
        'in_mask8.f32', 'in_N.f32', 'in_style.f32')) {
    if (-not (Test-DeviceFile "$root/$name")) {
        throw "Staged reference input is missing: $name"
    }
}
$processes = @(& $adb -s $Serial shell pidof $package 2>$null)
if (($processes -join '').Trim()) { throw 'The reference app is already running.' }

$id = [Guid]::NewGuid().ToString('N')
$backup = "$root/audible-reference-backup-$id"
$output = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../build/device-results/audible-reference-$id"))
[void][IO.Directory]::CreateDirectory($output)
[void](Invoke-Device @('shell', 'run-as', $package, 'mkdir', '-p', $backup))
$startup = @('files/Start.ps1', 'files/PROFILE.PS1')
$originalHashes = @{}
foreach ($path in $startup) {
    $originalHashes[$path] = Get-DeviceHash $path
    [void](Invoke-Device @('shell', 'run-as', $package, 'cp', $path,
        "$backup/$([IO.Path]::GetFileName($path))"))
}
$hadReceipt = Test-DeviceFile "$root/receipt.txt"
$hadWav = Test-DeviceFile "$root/kokoro_htp.wav"
$originalReceiptHash = if ($hadReceipt) { Get-DeviceHash "$root/receipt.txt" } else { $null }
$originalWavHash = if ($hadWav) { Get-DeviceHash "$root/kokoro_htp.wav" } else { $null }
if ($hadReceipt) {
    [void](Invoke-Device @('shell', 'run-as', $package, 'cp', "$root/receipt.txt", "$backup/receipt.txt"))
}
if ($hadWav) {
    [void](Invoke-Device @('shell', 'run-as', $package, 'cp', "$root/kokoro_htp.wav", "$backup/kokoro_htp.wav"))
}

$changed = $false
$receipt = @()
$restored = $false
$dataRestored = $false
try {
    $changed = $true
    foreach ($path in $startup) {
        [void](Invoke-Device @('shell', 'run-as', $package, 'cp', "$root/Speak.ps1", $path))
    }
    [void](Invoke-Device @('shell', 'run-as', $package, 'truncate', '-s', '0', "$root/receipt.txt"))
    [void](Invoke-Device @('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'))
    [void](Invoke-Device @('shell', 'am', 'force-stop', $package))
    [void](Invoke-Device @('shell', 'monkey', '-p', $package,
        '-c', 'android.intent.category.LAUNCHER', '1'))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 2
        $receipt = @(Invoke-Device @('shell', 'run-as', $package, 'cat', "$root/receipt.txt"))
    } while (($receipt -join "`n") -notmatch '(?m)^Passed=' -and
        $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    [IO.File]::WriteAllLines((Join-Path $output 'receipt.txt'), $receipt)
}
finally {
    if ($changed) {
        [void](Invoke-Device @('shell', 'am', 'force-stop', $package))
        if (Test-DeviceFile "$root/receipt.txt") {
            [void](Invoke-Device @('shell', 'run-as', $package, 'cp', "$root/receipt.txt",
                "$backup/attempt-receipt.txt"))
        }
        if (Test-DeviceFile "$root/kokoro_htp.wav") {
            [void](Invoke-Device @('shell', 'run-as', $package, 'cp', "$root/kokoro_htp.wav",
                "$backup/attempt.wav"))
        }
        foreach ($path in $startup) {
            [void](Invoke-Device @('shell', 'run-as', $package, 'cp',
                "$backup/$([IO.Path]::GetFileName($path))", $path))
        }
        if ($hadReceipt) {
            [void](Invoke-Device @('shell', 'run-as', $package, 'cp', "$backup/receipt.txt", "$root/receipt.txt"))
        }
        if ($hadWav) {
            [void](Invoke-Device @('shell', 'run-as', $package, 'cp', "$backup/kokoro_htp.wav", "$root/kokoro_htp.wav"))
        }
        $restored = $true
        foreach ($path in $startup) {
            if ((Get-DeviceHash $path) -cne $originalHashes[$path]) { $restored = $false }
        }
        $dataRestored = (-not $hadReceipt -or
            (Get-DeviceHash "$root/receipt.txt") -ceq $originalReceiptHash) -and
            (-not $hadWav -or
            (Get-DeviceHash "$root/kokoro_htp.wav") -ceq $originalWavHash)
    }
}

$text = $receipt -join "`n"
$audio = [regex]::Match($text, '(?m)^AAudioRate=.*WrittenFrames=(\d+) PlaybackFrames=(\d+) XRunCount=(\d+) PlaybackComplete=(True|False)')
$snr = [regex]::Match($text, '(?m)^NonFinite=(\d+) AudioSnrDb=([-+0-9.]+)')
[pscustomobject]@{
    Job = 'kokoro-speak'
    Device = 'SM8550'
    ReceiptPath = Join-Path $output 'receipt.txt'
    ReceiptComplete = $text -match '(?m)^Passed='
    PlaybackComplete = $audio.Success -and $audio.Groups[4].Value -eq 'True'
    WrittenFrames = if ($audio.Success) { [int]$audio.Groups[1].Value } else { 0 }
    XRunCount = if ($audio.Success) { [int]$audio.Groups[3].Value } else { $null }
    AudioSnrDb = if ($snr.Success) { [double]::Parse($snr.Groups[2].Value,
        [Globalization.CultureInfo]::InvariantCulture) } else { $null }
    NumericalPassed = $text -match '(?m)^Passed=True'
    StartupRestored = $restored
    PriorDataRestored = $dataRestored
}
