#requires -Version 7.4
# Batch-one, single-layer bidirectional LSTM used by Kokoro duration and text
# branches. PyTorch torch/nn/modules/rnn.py LSTM gate equations at
# 2b3ec34829036a65cd9d1398ea72a0167dc37470; Kokoro modules.py at
# dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Input/output layout [time, feature], with forward and reverse features
# concatenated at each time. Bounded FP32 correctness reference only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $InputSize,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $HiddenSize
)

$ErrorActionPreference = 'Stop'
if ($InputTensor.Length -ne [long]$Frames * $InputSize -or
    8L * $Frames * $HiddenSize * ($InputSize + $HiddenSize) -gt 20000000) {
    throw 'Bidirectional LSTM shape exceeds the bounded reference contract.'
}
$gateCount = 4 * $HiddenSize
foreach ($suffix in @('', '_reverse')) {
    $shapes = @{
        "weight_ih_l0$suffix" = [long]$gateCount * $InputSize
        "weight_hh_l0$suffix" = [long]$gateCount * $HiddenSize
        "bias_ih_l0$suffix" = $gateCount
        "bias_hh_l0$suffix" = $gateCount
    }
    foreach ($entry in $shapes.GetEnumerator()) {
        if (-not $Parameters.Contains($entry.Key) -or
            $Parameters[$entry.Key] -isnot [float[]] -or
            $Parameters[$entry.Key].Length -ne $entry.Value) {
            throw "Bidirectional LSTM parameter shape is invalid: $($entry.Key)"
        }
    }
}
foreach ($value in $InputTensor) {
    if (-not [float]::IsFinite($value)) { throw 'Bidirectional LSTM input is non-finite.' }
}
foreach ($suffix in @('', '_reverse')) {
    foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
        foreach ($value in $Parameters[$name + $suffix]) {
            if (-not [float]::IsFinite($value)) { throw 'Bidirectional LSTM weight is non-finite.' }
        }
    }
}

$result = [float[]]::new($Frames * $HiddenSize * 2)
for ($direction = 0; $direction -lt 2; $direction++) {
    $suffix = if ($direction -eq 0) { '' } else { '_reverse' }
    [float[]]$weightInput = $Parameters["weight_ih_l0$suffix"]
    [float[]]$weightHidden = $Parameters["weight_hh_l0$suffix"]
    [float[]]$biasInput = $Parameters["bias_ih_l0$suffix"]
    [float[]]$biasHidden = $Parameters["bias_hh_l0$suffix"]
    $hidden = [float[]]::new($HiddenSize)
    $cell = [float[]]::new($HiddenSize)
    $gates = [double[]]::new($gateCount)
    for ($step = 0; $step -lt $Frames; $step++) {
        $frame = if ($direction -eq 0) { $step } else { $Frames - 1 - $step }
        for ($gate = 0; $gate -lt $gateCount; $gate++) {
            $sum = [double]$biasInput[$gate] + [double]$biasHidden[$gate]
            for ($input = 0; $input -lt $InputSize; $input++) {
                $sum += [double]$InputTensor[$frame * $InputSize + $input] *
                    [double]$weightInput[$gate * $InputSize + $input]
            }
            for ($prior = 0; $prior -lt $HiddenSize; $prior++) {
                $sum += [double]$hidden[$prior] *
                    [double]$weightHidden[$gate * $HiddenSize + $prior]
            }
            $gates[$gate] = $sum
        }
        for ($channel = 0; $channel -lt $HiddenSize; $channel++) {
            $inputGate = 1.0 / (1.0 + [Math]::Exp(-$gates[$channel]))
            $forgetGate = 1.0 / (1.0 + [Math]::Exp(-$gates[$HiddenSize + $channel]))
            $candidate = [Math]::Tanh($gates[2 * $HiddenSize + $channel])
            $outputGate = 1.0 / (1.0 + [Math]::Exp(-$gates[3 * $HiddenSize + $channel]))
            $nextCell = $forgetGate * [double]$cell[$channel] + $inputGate * $candidate
            $nextHidden = $outputGate * [Math]::Tanh($nextCell)
            if (-not [double]::IsFinite($nextCell) -or
                -not [double]::IsFinite($nextHidden)) {
                throw 'Bidirectional LSTM state is non-finite.'
            }
            $cell[$channel] = [float]$nextCell
            $hidden[$channel] = [float]$nextHidden
            $result[$frame * (2 * $HiddenSize) +
                $direction * $HiddenSize + $channel] = $hidden[$channel]
        }
    }
}
Write-Output -NoEnumerate $result
