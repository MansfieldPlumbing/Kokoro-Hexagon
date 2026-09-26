#requires -Version 7.4
# Stock decoder F0/N Conv1d(1,1,3,stride=2,padding=1), weight_norm dim 0.
# Kokoro kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Batch-one bounded FP32 correctness reference.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $WeightV,
    [Parameter(Mandatory)][float[]] $WeightG,
    [Parameter(Mandatory)][float[]] $Bias,
    [Parameter(Mandatory)][ValidateRange(2, 32768)][int] $Frames
)

$ErrorActionPreference = 'Stop'
if ($InputTensor.Length -ne $Frames -or $WeightV.Length -ne 3 -or
    $WeightG.Length -ne 1 -or $Bias.Length -ne 1) {
    throw 'Stride-two Conv1D tensor shape is invalid.'
}
foreach ($values in @($InputTensor, $WeightV, $WeightG, $Bias)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw 'Stride-two Conv1D input is non-finite.' }
    }
}
$norm = [Math]::Sqrt([double]$WeightV[0] * $WeightV[0] +
    [double]$WeightV[1] * $WeightV[1] + [double]$WeightV[2] * $WeightV[2])
if ($norm -eq 0) { throw 'Stride-two Conv1D weight direction has zero norm.' }
$scale = [double]$WeightG[0] / $norm
$outputFrames = [int][Math]::Ceiling($Frames / 2.0)
$result = [float[]]::new($outputFrames)
for ($frame = 0; $frame -lt $outputFrames; $frame++) {
    $sum = [double]$Bias[0]
    for ($tap = 0; $tap -lt 3; $tap++) {
        $inputFrame = 2 * $frame + $tap - 1
        if ($inputFrame -ge 0 -and $inputFrame -lt $Frames) {
            $sum += [double]$InputTensor[$inputFrame] *
                [double]$WeightV[$tap] * $scale
        }
    }
    if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
        throw 'Stride-two Conv1D output is non-finite.'
    }
    $result[$frame] = [float]$sum
}
Write-Output -NoEnumerate $result
