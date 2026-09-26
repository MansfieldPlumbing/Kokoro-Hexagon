#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$forward = Join-Path $root 'src/models/ConvertTo-KokoroStft.ps1'
$inverse = Join-Path $root 'src/models/ConvertFrom-KokoroStft.ps1'
$ones = [float[]]::new(40)
[Array]::Fill($ones, [float]1)
$dc = & $forward -Samples $ones
if ($dc.Frames -ne 9 -or $dc.Bins -ne 11 -or
    [Math]::Abs([double]$dc.Magnitude[4] - 10) -gt 1e-5 -or
    [Math]::Abs([double]$dc.Magnitude[13] - 5) -gt 1e-5 -or
    [Math]::Abs([double]$dc.Magnitude[22]) -gt 1e-5) {
    throw 'STFT Hann DC or spectrum layout differs.'
}
$signal = [float[]]::new(40)
for ($i = 0; $i -lt $signal.Length; $i++) {
    $signal[$i] = [float](0.3 * [Math]::Sin(2 * [Math]::PI * $i / 7) +
        0.1 * [Math]::Cos(2 * [Math]::PI * $i / 11))
}
$spectrum = & $forward -Samples $signal
$reconstructed = & $inverse -Magnitude $spectrum.Magnitude `
    -Phase $spectrum.Phase -Frames $spectrum.Frames
if ($reconstructed.Length -ne $signal.Length) {
    throw 'STFT inverse centered length differs.'
}
$sumSignal = 0.0
$sumError = 0.0
for ($i = 0; $i -lt $signal.Length; $i++) {
    $sumSignal += [double]$signal[$i] * $signal[$i]
    $difference = [double]$signal[$i] - $reconstructed[$i]
    $sumError += $difference * $difference
}
$snr = 10 * [Math]::Log10($sumSignal / [Math]::Max($sumError, 1e-30))
if ($snr -lt 90) { throw "STFT forward/inverse round-trip SNR is below 90 dB: $snr" }
Write-Output ('PASS: STFT Hann DC and centered round-trip SNR {0:N1} dB' -f $snr)
