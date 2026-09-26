#requires -Version 7.4
# Stock ProsodyPredictor.F0Ntrain from aligned 640-channel features and style.
# Kokoro kokoro/modules.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Batch one, bounded FP32 correctness reference; not a speech output.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $AlignedFeatures,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $Frames
)

$ErrorActionPreference = 'Stop'
if ($AlignedFeatures.Length -ne [long]640 * $Frames -or $Style.Length -ne 128) {
    throw 'F0/N branch input shape is invalid.'
}
$modelRoot = $PSScriptRoot
$sharedParameters = @{}
foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0',
        'weight_ih_l0_reverse', 'weight_hh_l0_reverse',
        'bias_ih_l0_reverse', 'bias_hh_l0_reverse')) {
    $key = "shared.$name"
    if (-not $Parameters.Contains($key) -or $Parameters[$key] -isnot [float[]]) {
        throw "F0/N shared LSTM parameter is absent: $key"
    }
    $sharedParameters[$name] = $Parameters[$key]
}
$timeMajor = [float[]]::new(640 * $Frames)
for ($channel = 0; $channel -lt 640; $channel++) {
    for ($frame = 0; $frame -lt $Frames; $frame++) {
        $timeMajor[$frame * 640 + $channel] = $AlignedFeatures[$channel * $Frames + $frame]
    }
}
[float[]]$shared = & (Join-Path $modelRoot 'Invoke-KokoroBidirectionalLstm.ps1') `
    -InputTensor $timeMajor -Parameters $sharedParameters -Frames $Frames `
    -InputSize 640 -HiddenSize 256
$sharedChannels = [float[]]::new(512 * $Frames)
for ($frame = 0; $frame -lt $Frames; $frame++) {
    for ($channel = 0; $channel -lt 512; $channel++) {
        $sharedChannels[$channel * $Frames + $frame] = $shared[$frame * 512 + $channel]
    }
}
$curves = @{}
foreach ($branch in @('F0', 'N')) {
    $state = $sharedChannels
    $currentFrames = $Frames
    for ($block = 0; $block -lt 3; $block++) {
        $blockParameters = @{}
        $prefix = "$branch.$block."
        foreach ($name in @('norm1.fc.weight', 'norm1.fc.bias',
                'norm2.fc.weight', 'norm2.fc.bias', 'conv1.weight_v',
                'conv1.weight_g', 'conv1.bias', 'conv2.weight_v',
                'conv2.weight_g', 'conv2.bias')) {
            $key = $prefix + $name
            if (-not $Parameters.Contains($key) -or $Parameters[$key] -isnot [float[]]) {
                throw "F0/N block parameter is absent: $key"
            }
            $blockParameters[$name] = $Parameters[$key]
        }
        $args = @{
            InputTensor = $state
            Style = $Style
            Parameters = $blockParameters
            Frames = $currentFrames
            Channels = $(if ($block -lt 2) { 512 } else { 256 })
        }
        if ($block -eq 1) {
            foreach ($name in @('pool.weight_v', 'pool.weight_g', 'pool.bias',
                    'conv1x1.weight_v', 'conv1x1.weight_g')) {
                $key = $prefix + $name
                if (-not $Parameters.Contains($key) -or $Parameters[$key] -isnot [float[]]) {
                    throw "F0/N upsample parameter is absent: $key"
                }
                $blockParameters[$name] = $Parameters[$key]
            }
            $args.OutputChannels = 256
            $args.Upsample = $true
        }
        [float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroF0NAdaInResBlock.ps1') @args
        if ($block -eq 1) { $currentFrames *= 2 }
    }
    $weightKey = "${branch}_proj.weight"
    $biasKey = "${branch}_proj.bias"
    if (-not $Parameters.Contains($weightKey) -or $Parameters[$weightKey] -isnot [float[]] -or
        $Parameters[$weightKey].Length -ne 256 -or -not $Parameters.Contains($biasKey) -or
        $Parameters[$biasKey] -isnot [float[]] -or $Parameters[$biasKey].Length -ne 1) {
        throw "F0/N projection shape is invalid: $branch"
    }
    $curve = [float[]]::new($currentFrames)
    for ($frame = 0; $frame -lt $currentFrames; $frame++) {
        $sum = [double]$Parameters[$biasKey][0]
        for ($channel = 0; $channel -lt 256; $channel++) {
            $sum += [double]$state[$channel * $currentFrames + $frame] *
                [double]$Parameters[$weightKey][$channel]
        }
        if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
            throw "F0/N projection is non-finite: $branch"
        }
        $curve[$frame] = [float]$sum
    }
    $curves[$branch] = $curve
}
[pscustomobject]@{ F0 = $curves.F0; N = $curves.N; Frames = 2 * $Frames }
