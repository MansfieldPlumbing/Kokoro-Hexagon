#requires -Version 7.4
# Row-major batch-one affine projection used after ALBERT and at other
# stock Kokoro linear layers. Kokoro model.py forward_with_tokens at
# dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Bounded FP32 correctness reference, not a device implementation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $Weights,
    [Parameter(Mandatory)][float[]] $Bias,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $Rows,
    [Parameter(Mandatory)][ValidateRange(1, 4096)][int] $InputChannels,
    [Parameter(Mandatory)][ValidateRange(1, 4096)][int] $OutputChannels
)

$ErrorActionPreference = 'Stop'
if ($InputTensor.Length -ne [long]$Rows * $InputChannels -or
    $Weights.Length -ne [long]$OutputChannels * $InputChannels -or
    $Bias.Length -ne $OutputChannels -or
    [long]$Rows * $InputChannels * $OutputChannels -gt 10000000) {
    throw 'Kokoro linear projection shape exceeds the bounded reference contract.'
}
foreach ($value in $InputTensor) {
    if (-not [float]::IsFinite($value)) { throw 'Kokoro linear input is non-finite.' }
}
foreach ($value in $Weights) {
    if (-not [float]::IsFinite($value)) { throw 'Kokoro linear weight is non-finite.' }
}
foreach ($value in $Bias) {
    if (-not [float]::IsFinite($value)) { throw 'Kokoro linear bias is non-finite.' }
}
$result = [float[]]::new($Rows * $OutputChannels)
for ($row = 0; $row -lt $Rows; $row++) {
    for ($output = 0; $output -lt $OutputChannels; $output++) {
        $sum = [double]$Bias[$output]
        for ($input = 0; $input -lt $InputChannels; $input++) {
            $sum += [double]$InputTensor[$row * $InputChannels + $input] *
                [double]$Weights[$output * $InputChannels + $input]
        }
        if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
            throw 'Kokoro linear output is non-finite.'
        }
        $result[$row * $OutputChannels + $output] = [float]$sum
    }
}
Write-Output -NoEnumerate $result
