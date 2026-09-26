#requires -Version 7.4
# Build-time gate for one AdaIN operator against the pinned stock checkpoint.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pin = @(([IO.File]::ReadAllText((Join-Path $root 'lib/manifest.json')) |
    ConvertFrom-Json -AsHashtable).model.files | Where-Object { $_.path -ceq 'kokoro-v1_0.pth' })
if ($pin.Count -ne 1) { throw 'Stock checkpoint pin is not unique.' }
$path = (Resolve-Path -LiteralPath $CheckpointPath).Path
if ((Get-Item -LiteralPath $path).Length -ne [long]$pin[0].bytes -or
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $pin[0].sha256) {
    throw 'Stock checkpoint does not match the pinned digest.'
}

# The reader file is repository-owned static code, not user-supplied source.
$readerPath = Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'
$reader = [scriptblock]::Create([IO.File]::ReadAllText($readerPath)).InvokeReturnAsIs()
$checkpoint = & $reader.Read $path
$blockPrefix = 'decoder.module.generator.resblocks.3.'
for ($pass = 0; $pass -lt 3; $pass++) {
    foreach ($side in 1, 2) {
        $shapes = @{
            "adain$side.$pass.fc.weight" = '256,128'
            "adain$side.$pass.fc.bias" = '256'
            "alpha$side.$pass" = '1,128,1'
            "convs$side.$pass.weight_v" = '128,128,3'
            "convs$side.$pass.weight_g" = '128,1,1'
            "convs$side.$pass.bias" = '128'
        }
        foreach ($suffix in $shapes.Keys) {
            $tensor = $checkpoint.Tensors[$blockPrefix + $suffix]
            if ($null -eq $tensor -or ($tensor.Shape -join ',') -cne $shapes[$suffix]) {
                throw 'Stock AdaIN residual block parameter shape differs.'
            }
        }
    }
}
$prefix = 'decoder.module.generator.resblocks.3.adain1.0.'
$weightName = $prefix + 'fc.weight'
$biasName = $prefix + 'fc.bias'
if (($checkpoint.Tensors[$weightName].Shape -join ',') -cne '256,128' -or
    ($checkpoint.Tensors[$biasName].Shape -join ',') -cne '256') {
    throw 'Stock AdaIN style projection tensor shapes differ.'
}
if (@($checkpoint.Tensors.Keys | Where-Object { $_ -like '*adain*.norm.*' }).Count -ne 0) {
    throw 'Stock checkpoint now has AdaIN norm affine tensors; revise the default contract.'
}

[byte[]]$weightBytes = & $reader.Bytes $checkpoint $weightName
[byte[]]$biasBytes = & $reader.Bytes $checkpoint $biasName
$weights = [float[]]::new(256 * 128)
$bias = [float[]]::new(256)
[Buffer]::BlockCopy($weightBytes, 0, $weights, 0, $weightBytes.Length)
[Buffer]::BlockCopy($biasBytes, 0, $bias, 0, $biasBytes.Length)
$style = [float[]]::new(128)
$project = Join-Path $root 'src/models/ConvertTo-KokoroAdaInStyle.ps1'
$affine = & $project -Style $style -Weights $weights -Bias $bias -Channels 128
for ($channel = 0; $channel -lt 128; $channel++) {
    if ([Math]::Abs([double]$affine.Gain[$channel] - (1.0 + [double]$bias[$channel])) -gt 1e-6 -or
        [Math]::Abs([double]$affine.Shift[$channel] - [double]$bias[128 + $channel]) -gt 1e-6) {
        throw 'Stock AdaIN style projection differs from its zero-style bias contract.'
    }
}

$convPrefix = 'decoder.module.generator.resblocks.3.convs1.0.'
$vName = $convPrefix + 'weight_v'
$gName = $convPrefix + 'weight_g'
$convBiasName = $convPrefix + 'bias'
if (($checkpoint.Tensors[$vName].Shape -join ',') -cne '128,128,3' -or
    ($checkpoint.Tensors[$gName].Shape -join ',') -cne '128,1,1' -or
    ($checkpoint.Tensors[$convBiasName].Shape -join ',') -cne '128') {
    throw 'Stock AdaIN Conv1D tensor shapes differ.'
}
[byte[]]$vBytes = & $reader.Bytes $checkpoint $vName
[byte[]]$gBytes = & $reader.Bytes $checkpoint $gName
[byte[]]$convBiasBytes = & $reader.Bytes $checkpoint $convBiasName
$v = [float[]]::new(128 * 128 * 3)
$g = [float[]]::new(128)
$convBias = [float[]]::new(128)
[Buffer]::BlockCopy($vBytes, 0, $v, 0, $vBytes.Length)
[Buffer]::BlockCopy($gBytes, 0, $g, 0, $gBytes.Length)
[Buffer]::BlockCopy($convBiasBytes, 0, $convBias, 0, $convBiasBytes.Length)
$inputTensor = [float[]]::new(128 * 3)
$inputTensor[1] = 1.0
$conv = Join-Path $root 'src/models/Invoke-KokoroAdaInConv1d.ps1'
[float[]]$convOutput = & $conv -InputTensor $inputTensor -Frames 3 `
    -InputChannels 128 -OutputChannels 128 -KernelSize 3 -Dilation 1 `
    -WeightV $v -WeightG $g -Bias $convBias
foreach ($channel in @(0, 1, 127)) {
    $offset = $channel * 128 * 3
    $squares = 0.0
    for ($i = 0; $i -lt 128 * 3; $i++) {
        $value = [double]$v[$offset + $i]
        $squares += $value * $value
    }
    $scale = [double]$g[$channel] / [Math]::Sqrt($squares)
    for ($frame = 0; $frame -lt 3; $frame++) {
        $expected = [double]$convBias[$channel] + [double]$v[$offset + (2 - $frame)] * $scale
        if ([Math]::Abs([double]$convOutput[$channel * 3 + $frame] - $expected) -gt 1e-6) {
            throw 'Stock AdaIN Conv1D impulse response differs.'
        }
    }
}

Write-Output 'PASS: pinned stock AdaIN residual block shapes, identity norm, style projection, Conv1D impulse'
