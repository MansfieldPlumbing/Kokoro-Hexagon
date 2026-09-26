#requires -Version 7.4
# Kokoro AdaIN1d.fc(s) -> (1 + gamma, beta), one batch item.
# kokoro/istftnet.py:20-31 at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Weights use the stock nn.Linear [2*Channels, StyleDim] row-major layout.
# This is a scalar reference stage, not the emitted Hexagon implementation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][float[]] $Weights,
    [Parameter(Mandatory)][float[]] $Bias,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $Channels
)

$ErrorActionPreference = 'Stop'
$styleDim = $Style.Length
if ($styleDim -lt 1 -or $styleDim -gt 1024 -or
    $Weights.Length -ne [long]2 * $Channels * $styleDim -or
    $Bias.Length -ne 2 * $Channels) {
    throw 'AdaIN style projection shape is invalid.'
}
foreach ($value in $Style) {
    if (-not [float]::IsFinite($value)) { throw 'Style vector is non-finite.' }
}
foreach ($value in $Weights) {
    if (-not [float]::IsFinite($value)) { throw 'Style projection weight is non-finite.' }
}
foreach ($value in $Bias) {
    if (-not [float]::IsFinite($value)) { throw 'Style projection bias is non-finite.' }
}

$gain = [float[]]::new($Channels)
$shift = [float[]]::new($Channels)
for ($row = 0; $row -lt 2 * $Channels; $row++) {
    $sum = [double]$Bias[$row]
    $offset = $row * $styleDim
    for ($column = 0; $column -lt $styleDim; $column++) {
        $sum += [double]$Weights[$offset + $column] * [double]$Style[$column]
    }
    if ($row -lt $Channels) {
        $sum += 1.0
        if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
            throw 'AdaIN style gain is non-finite.'
        }
        $gain[$row] = [float]$sum
    } else {
        if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
            throw 'AdaIN style shift is non-finite.'
        }
        $shift[$row - $Channels] = [float]$sum
    }
}

[pscustomobject]@{ Gain = $gain; Shift = $shift }
