#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroLearnedGenerator.ps1'
$parameters = @{}

function Add-Block([string] $Prefix, [int] $Channels, [int] $Kernel) {
    foreach ($pass in 0, 1, 2) {
        foreach ($side in 1, 2) {
            $parameters["${Prefix}adain$side.$pass.fc.weight"] = [float[]]::new(2 * $Channels)
            $parameters["${Prefix}adain$side.$pass.fc.bias"] = [float[]]::new(2 * $Channels)
            $parameters["${Prefix}alpha$side.$pass"] = [float[]]@(1) * $Channels
            $direction = [float[]]::new($Channels * $Channels * $Kernel)
            for ($channel = 0; $channel -lt $Channels; $channel++) {
                $direction[$channel * $Channels * $Kernel] = 1
            }
            $parameters["${Prefix}convs$side.$pass.weight_v"] = $direction
            $parameters["${Prefix}convs$side.$pass.weight_g"] = [float[]]::new($Channels)
            $parameters["${Prefix}convs$side.$pass.bias"] = [float[]]::new($Channels)
        }
    }
}

for ($i = 0; $i -lt 2; $i++) {
    $channelsIn = @(4, 2)[$i]
    $channelsOut = @(2, 1)[$i]
    $upKernel = @(20, 12)[$i]
    $direction = [float[]]::new($channelsIn * $channelsOut * $upKernel)
    for ($channel = 0; $channel -lt $channelsIn; $channel++) {
        $direction[$channel * $channelsOut * $upKernel] = 1
    }
    $parameters["ups.$i.weight_v"] = $direction
    $parameters["ups.$i.weight_g"] = [float[]]::new($channelsIn)
    $parameters["ups.$i.bias"] = [float[]]::new($channelsOut)
    $noiseKernel = @(12, 1)[$i]
    $parameters["noise_convs.$i.weight"] = [float[]]::new($channelsOut * 22 * $noiseKernel)
    $parameters["noise_convs.$i.bias"] = [float[]]::new($channelsOut)
    Add-Block "noise_res.$i." $channelsOut @(7, 11)[$i]
    for ($j = 0; $j -lt 3; $j++) {
        Add-Block "resblocks.$($i * 3 + $j)." $channelsOut @(3, 7, 11)[$j]
    }
}
$postDirection = [float[]]::new(22 * 7)
for ($channel = 0; $channel -lt 22; $channel++) { $postDirection[$channel * 7] = 1 }
$parameters['conv_post.weight_v'] = $postDirection
$parameters['conv_post.weight_g'] = [float[]]::new(22)
$parameters['conv_post.bias'] = [float[]]::new(22)

$inputTensor = [float[]]::new(4)
$spectrum = [float[]]::new(22 * 61)
$args = @{
    InputTensor = $inputTensor
    SourceSpectrum = $spectrum
    Style = [float[]]@(0)
    InputFrames = 1
    InitialChannels = 4
    Parameters = $parameters
}
$result = & $stage @args
if ($result.SpectrumFrames -ne 61 -or $result.Post.Length -ne 22 * 61 -or
    $result.Samples -ne 300 -or $result.Pcm.Length -ne 300) {
    throw 'Learned generator output shape differs from the two-stage stock topology.'
}
foreach ($value in $result.Post) {
    if ($value -ne 0) { throw 'Zero-weight analytic post projection is nonzero.' }
}
foreach ($value in $result.Pcm) {
    if (-not [float]::IsFinite($value)) { throw 'Analytic PCM is non-finite.' }
}

# Drive the harmonic injection, learned upsampling, residual stack, and post
# projection with nonzero bounded fixtures. This is a topology gate, not a
# stock-weight numerical comparison.
for ($i = 0; $i -lt $spectrum.Length; $i++) { $spectrum[$i] = 1 }
$parameters['noise_convs.0.weight'][0] = 1
$parameters['noise_convs.1.weight'][0] = 1
$parameters['ups.1.weight_g'][0] = 1
$parameters['conv_post.weight_g'][0] = 1
$active = & $stage @args
if ($active.Samples -ne 300 -or
    -not @($active.Post | Where-Object { [Math]::Abs($_) -gt 1e-6 }).Count) {
    throw 'Nonzero learned generator fixture did not reach the post projection.'
}
foreach ($value in $active.Pcm) {
    if (-not [float]::IsFinite($value)) { throw 'Nonzero analytic PCM is non-finite.' }
}

$generator = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroGenerator.ps1'
$merge = [float[]]::new(9)
$merge[0] = 1
$complete = & $generator -InputTensor ([float[]]::new(8)) `
    -Style ([float[]]@(0)) -F0 ([float[]]@(120, 120)) `
    -SourceMergeWeights $merge -SourceMergeBias ([float[]]@(0)) `
    -InitialChannels 4 -Parameters $parameters `
    -InitialPhase ([float[]]::new(9)) `
    -HarmonicGaussian ([float[]]::new(5400)) `
    -NoiseGaussian ([float[]]::new(600))
if ($complete.SpectrumFrames -ne 121 -or $complete.Samples -ne 600 -or
    $complete.Pcm.Length -ne 600) {
    throw 'Connected generator source and PCM frame counts differ.'
}
foreach ($value in $complete.Pcm) {
    if (-not [float]::IsFinite($value)) { throw 'Connected generator PCM is non-finite.' }
}

$parameters.Remove('conv_post.weight_v')
$rejected = $false
try { $null = & $stage @args } catch { $rejected = $true }
if (-not $rejected) { throw 'Learned generator accepted an absent post weight.' }

if ($CheckpointPath) {
    $stock = & (Join-Path $PSScriptRoot '../src/models/Read-KokoroGeneratorWeights.ps1') `
        -CheckpointPath $CheckpointPath
    if ($stock.TensorCount -ne 303 -or $stock.Parameters.Count -ne 301 -or
        $stock.SourceMergeWeights.Length -ne 9 -or $stock.SourceMergeBias.Length -ne 1) {
        throw 'Stock generator parameter map is incomplete.'
    }
}

Write-Output 'PASS: two-stage generator topology, source-to-PCM shape, missing-weight rejection'
