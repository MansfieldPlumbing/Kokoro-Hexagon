#requires -Version 7.4
# Stock Generator.forward after harmonic STFT, for one batch item.
# kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Bounded PowerShell FP32 correctness reference, not a device backend.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $SourceSpectrum,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][ValidateRange(1, 109)][int] $InputFrames,
    [Parameter(Mandatory)][ValidateRange(4, 512)][int] $InitialChannels,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters
)

$ErrorActionPreference = 'Stop'
if ($InitialChannels % 4 -ne 0 -or
    $InputTensor.Length -ne [long]$InitialChannels * $InputFrames -or
    $SourceSpectrum.Length -ne [long]22 * (60 * $InputFrames + 1) -or
    $Style.Length -lt 1 -or $Style.Length -gt 1024) {
    throw 'Learned generator input shape differs from the configured two-stage path.'
}
foreach ($values in @($InputTensor, $SourceSpectrum, $Style)) {
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw 'Learned generator input is non-finite.' }
    }
}

function Get-Vector([string] $Name) {
    if (-not $Parameters.Contains($Name) -or $Parameters[$Name] -isnot [float[]]) {
        throw "Learned generator parameter is absent or has the wrong type: $Name"
    }
    Write-Output -NoEnumerate $Parameters[$Name]
}

function Invoke-Block([string] $Prefix, [float[]] $Values, [int] $Frames,
        [int] $Channels, [int] $Kernel) {
    $block = @{}
    foreach ($key in $Parameters.Keys) {
        if ($key -is [string] -and $key.StartsWith($Prefix, [StringComparison]::Ordinal)) {
            $block[$key.Substring($Prefix.Length)] = $Parameters[$key]
        }
    }
    [float[]]$result = & (Join-Path $PSScriptRoot 'Invoke-KokoroAdaInResBlock1.ps1') `
        -InputTensor $Values -Style $Style -Frames $Frames -Channels $Channels `
        -KernelSize $Kernel -Dilations ([int[]]@(1, 3, 5)) -Parameters $block
    Write-Output -NoEnumerate $result
}

$values = $InputTensor
$frames = $InputFrames
$sourceFrames = 60 * $InputFrames + 1
for ($stage = 0; $stage -lt 2; $stage++) {
    $channelsIn = $InitialChannels / [int][Math]::Pow(2, $stage)
    $channelsOut = $channelsIn / 2
    $rate = @(10, 6)[$stage]
    $kernel = @(20, 12)[$stage]
    $nextFrames = $frames * $rate
    $activated = [float[]]::new($values.Length)
    for ($i = 0; $i -lt $values.Length; $i++) {
        $activated[$i] = if ($values[$i] -ge 0) { $values[$i] } else { [float](0.1 * $values[$i]) }
    }
    [float[]]$upsampled = & (Join-Path $PSScriptRoot 'Invoke-KokoroWeightNormTransposeConv1d.ps1') `
        -InputTensor $activated -Frames $frames -InputChannels $channelsIn `
        -OutputChannels $channelsOut -KernelSize $kernel -Stride $rate `
        -Padding (($kernel - $rate) / 2) `
        -WeightV (Get-Vector "ups.$stage.weight_v") `
        -WeightG (Get-Vector "ups.$stage.weight_g") `
        -Bias (Get-Vector "ups.$stage.bias")

    if ($stage -eq 0) {
        $noiseKernel = 12; $noiseStride = 6; $noisePadding = 3; $noiseBlockKernel = 7
    } else {
        $noiseKernel = 1; $noiseStride = 1; $noisePadding = 0; $noiseBlockKernel = 11
    }
    [float[]]$source = & (Join-Path $PSScriptRoot 'Invoke-KokoroConv1d.ps1') `
        -InputTensor $SourceSpectrum -Frames $sourceFrames -InputChannels 22 `
        -OutputChannels $channelsOut -KernelSize $noiseKernel `
        -Stride $noiseStride -Padding $noisePadding `
        -Weights (Get-Vector "noise_convs.$stage.weight") `
        -Bias (Get-Vector "noise_convs.$stage.bias")
    [float[]]$source = Invoke-Block "noise_res.$stage." $source `
        ($source.Length / $channelsOut) $channelsOut $noiseBlockKernel

    if ($stage -eq 1) {
        # ReflectionPad1d((1, 0)) copies frame 1 into the new left frame.
        $padded = [float[]]::new($channelsOut * ($nextFrames + 1))
        for ($channel = 0; $channel -lt $channelsOut; $channel++) {
            $oldBase = $channel * $nextFrames
            $newBase = $channel * ($nextFrames + 1)
            $padded[$newBase] = $upsampled[$oldBase + 1]
            [Array]::Copy($upsampled, $oldBase, $padded, $newBase + 1, $nextFrames)
        }
        $upsampled = $padded
        $nextFrames++
    }
    if ($source.Length -ne $upsampled.Length) {
        throw 'Learned generator source and upsampled feature frames differ.'
    }
    $mixed = [float[]]::new($source.Length)
    for ($i = 0; $i -lt $mixed.Length; $i++) {
        $sum = [double]$source[$i] + [double]$upsampled[$i]
        if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
            throw 'Learned generator source mixture is non-finite.'
        }
        $mixed[$i] = [float]$sum
    }
    $average = [float[]]::new($mixed.Length)
    foreach ($j in 0, 1, 2) {
        $blockIndex = $stage * 3 + $j
        [float[]]$branch = Invoke-Block "resblocks.$blockIndex." $mixed `
            $nextFrames $channelsOut @(3, 7, 11)[$j]
        for ($i = 0; $i -lt $average.Length; $i++) {
            $sum = [double]$average[$i] + [double]$branch[$i]
            if (-not [double]::IsFinite($sum) -or [Math]::Abs($sum) -gt [float]::MaxValue) {
                throw 'Learned generator residual sum is non-finite.'
            }
            $average[$i] = [float]$sum
        }
    }
    for ($i = 0; $i -lt $average.Length; $i++) {
        $average[$i] = [float]([double]$average[$i] / 3.0)
    }
    $values = $average
    $frames = $nextFrames
}

$activated = [float[]]::new($values.Length)
for ($i = 0; $i -lt $values.Length; $i++) {
    $activated[$i] = if ($values[$i] -ge 0) { $values[$i] } else { [float](0.1 * $values[$i]) }
}
[float[]]$post = & (Join-Path $PSScriptRoot 'Invoke-KokoroWeightNormConv1d.ps1') `
    -InputTensor $activated -Frames $frames -InputChannels ($InitialChannels / 4) `
    -OutputChannels 22 -KernelSize 7 -Dilation 1 `
    -WeightV (Get-Vector 'conv_post.weight_v') `
    -WeightG (Get-Vector 'conv_post.weight_g') `
    -Bias (Get-Vector 'conv_post.bias')
[float[]]$pcm = & (Join-Path $PSScriptRoot 'ConvertTo-KokoroPcm.ps1') `
    -Post $post -Frames $frames -FrameStride $frames
[pscustomobject]@{
    Post = $post
    Pcm = $pcm
    SpectrumFrames = $frames
    Samples = $pcm.Length
}
