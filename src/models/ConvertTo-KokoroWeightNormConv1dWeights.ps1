#requires -Version 7.4
# Folds frozen weight_norm(dim=0) Conv1d weights for a build-time model artifact.
# This is not AdaIN: it does not depend on an activation or style control.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 2048)][int] $InputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 2048)][int] $OutputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 31)][int] $KernelSize,
    [Parameter(Mandatory)][float[]] $WeightV,
    [Parameter(Mandatory)][float[]] $WeightG
)

$ErrorActionPreference = 'Stop'
$count = [long]$InputChannels * $OutputChannels * $KernelSize
if ($count -gt 67108864 -or $WeightV.Length -ne $count -or $WeightG.Length -ne $OutputChannels) {
    throw 'Weight-normalized Conv1D shape is outside the admitted folding contract.'
}
foreach ($values in @($WeightV, $WeightG)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw 'Weight-normalized Conv1D parameter is non-finite.' }
    }
}

$folded = [float[]]::new([int]$count)
$perOutput = $InputChannels * $KernelSize
for ($output = 0; $output -lt $OutputChannels; $output++) {
    $offset = $output * $perOutput
    [double]$squares = 0
    for ($i = 0; $i -lt $perOutput; $i++) {
        [double]$value = $WeightV[$offset + $i]
        $squares += $value * $value
    }
    if ($squares -eq 0) { throw 'Weight-normalized Conv1D direction has zero norm.' }
    [double]$scale = [double]$WeightG[$output] / [Math]::Sqrt($squares)
    for ($i = 0; $i -lt $perOutput; $i++) {
        [double]$value = [double]$WeightV[$offset + $i] * $scale
        if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
            throw 'Folded Conv1D weight is non-finite.'
        }
        $folded[$offset + $i] = [float]$value
    }
}
Write-Output -NoEnumerate $folded
