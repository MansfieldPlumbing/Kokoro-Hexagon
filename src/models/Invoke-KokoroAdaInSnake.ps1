#requires -Version 7.4
# Snake1D within Kokoro AdaINResBlock1: x + sin(alpha*x)^2 / alpha.
# kokoro/istftnet.py:69-76 at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Scalar FP32 reference, not the emitted approximation or DSP execution path.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][ValidateRange(1, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $Channels,
    [Parameter(Mandatory)][float[]] $Alpha
)

$ErrorActionPreference = 'Stop'
if ($InputTensor.Length -ne [long]$Frames * $Channels -or
    $Alpha.Length -ne $Channels -or $InputTensor.Length -gt 8388608) {
    throw 'AdaIN Snake tensor shape is invalid or exceeds the scalar bound.'
}
$output = [float[]]::new($InputTensor.Length)
for ($channel = 0; $channel -lt $Channels; $channel++) {
    $alphaValue = [double]$Alpha[$channel]
    if (-not [double]::IsFinite($alphaValue) -or $alphaValue -eq 0.0) {
        throw 'AdaIN Snake alpha must be finite and nonzero.'
    }
    $base = $channel * $Frames
    for ($frame = 0; $frame -lt $Frames; $frame++) {
        $inputValue = [double]$InputTensor[$base + $frame]
        if (-not [double]::IsFinite($inputValue)) { throw 'AdaIN Snake input is non-finite.' }
        $sine = [Math]::Sin($alphaValue * $inputValue)
        $value = $inputValue + $sine * $sine / $alphaValue
        if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
            throw 'AdaIN Snake output is non-finite.'
        }
        $output[$base + $frame] = [float]$value
    }
}
Write-Output -NoEnumerate $output
