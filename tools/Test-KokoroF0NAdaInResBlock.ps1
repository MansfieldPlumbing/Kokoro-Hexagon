#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroF0NAdaInResBlock.ps1'
$parameters = @{}
foreach ($side in 1, 2) {
    $parameters["norm$side.fc.weight"] = [float[]]@(0, 0)
    $parameters["norm$side.fc.bias"] = [float[]]@(0, 0)
    $parameters["conv$side.weight_v"] = [float[]]@(0, 1, 0)
    $parameters["conv$side.weight_g"] = [float[]]@(0)
    $parameters["conv$side.bias"] = [float[]]@(0)
}
$inputTensor = [float[]]@(1, 2, 3)
$actual = & $stage -InputTensor $inputTensor -Style ([float[]]@(0)) `
    -Parameters $parameters -Frames 3 -Channels 1
for ($i = 0; $i -lt 3; $i++) {
    if ([Math]::Abs([double]$actual[$i] - [double]$inputTensor[$i] / [Math]::Sqrt(2)) -gt 1e-6) {
        throw 'Analytic F0/N AdaIN residual shortcut differs.'
    }
}
$parameters['pool.weight_v'] = [float[]]@(0, 1, 0)
$parameters['pool.weight_g'] = [float[]]@(1)
$parameters['pool.bias'] = [float[]]@(0)
$upsampled = & $stage -InputTensor $inputTensor -Style ([float[]]@(0)) `
    -Parameters $parameters -Frames 3 -Channels 1 -Upsample
$expectedUpsampled = [float[]]@(1, 1, 2, 2, 3, 3)
if ($upsampled.Length -ne 6) { throw 'Analytic F0/N upsample length differs.' }
for ($i = 0; $i -lt 6; $i++) {
    if ([Math]::Abs([double]$upsampled[$i] - [double]$expectedUpsampled[$i] / [Math]::Sqrt(2)) -gt 1e-6) {
        throw 'Analytic F0/N upsample shortcut differs.'
    }
}
$changed = @{
    'norm1.fc.weight' = [float[]]::new(4)
    'norm1.fc.bias' = [float[]]::new(4)
    'norm2.fc.weight' = [float[]]::new(2)
    'norm2.fc.bias' = [float[]]::new(2)
    'conv1.weight_v' = [float[]]@(0, 1, 0, 0, 0, 0)
    'conv1.weight_g' = [float[]]@(0)
    'conv1.bias' = [float[]]@(0)
    'conv2.weight_v' = [float[]]@(0, 1, 0)
    'conv2.weight_g' = [float[]]@(0)
    'conv2.bias' = [float[]]@(0)
    'pool.weight_v' = [float[]]@(0, 1, 0, 0, 1, 0)
    'pool.weight_g' = [float[]]@(1, 1)
    'pool.bias' = [float[]]@(0, 0)
    'conv1x1.weight_v' = [float[]]@(1, 0)
    'conv1x1.weight_g' = [float[]]@(1)
}
$channelChanged = & $stage -InputTensor ([float[]]@(1, 2, 4, 5)) `
    -Style ([float[]]@(0)) -Parameters $changed -Frames 2 -Channels 2 `
    -OutputChannels 1 -Upsample
for ($i = 0; $i -lt 4; $i++) {
    if ([Math]::Abs([double]$channelChanged[$i] - [double]([float[]]@(1, 1, 2, 2))[$i] / [Math]::Sqrt(2)) -gt 1e-6) {
        throw 'Analytic F0/N channel-changing shortcut differs.'
    }
}
if ($CheckpointPath) {
    $pin = @(([IO.File]::ReadAllText((Join-Path $root 'lib/manifest.json')) |
        ConvertFrom-Json -AsHashtable).model.files | Where-Object { $_.path -ceq 'kokoro-v1_0.pth' })
    $path = (Resolve-Path -LiteralPath $CheckpointPath).Path
    if ($pin.Count -ne 1 -or (Get-Item -LiteralPath $path).Length -ne [long]$pin[0].bytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $pin[0].sha256) {
        throw 'Stock checkpoint does not match the pinned digest.'
    }
    $reader = [scriptblock]::Create([IO.File]::ReadAllText(
        (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
    $checkpoint = & $reader.Read $path
    $read = {
        param([string] $Name, [string] $Shape)
        $descriptor = $checkpoint.Tensors[$Name]
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $Shape) {
            throw 'Stock F0/N AdaIN block tensor shape differs.'
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    $stock = @{}
    $prefix = 'predictor.module.F0.0.'
    foreach ($side in 1, 2) {
        $stock["norm$side.fc.weight"] = & $read ($prefix + "norm$side.fc.weight") '1024,128'
        $stock["norm$side.fc.bias"] = & $read ($prefix + "norm$side.fc.bias") '1024'
        $stock["conv$side.weight_v"] = & $read ($prefix + "conv$side.weight_v") '512,512,3'
        $stock["conv$side.weight_g"] = & $read ($prefix + "conv$side.weight_g") '512,1,1'
        $stock["conv$side.bias"] = & $read ($prefix + "conv$side.bias") '512'
    }
    $stockInput = [float[]]::new(512 * 2)
    for ($i = 0; $i -lt $stockInput.Length; $i++) {
        $stockInput[$i] = [float](0.1 * [Math]::Sin($i * 0.02))
    }
    $stockOutput = & $stage -InputTensor $stockInput -Style ([float[]]::new(128)) `
        -Parameters $stock -Frames 2 -Channels 512
    if ($stockOutput.Length -ne $stockInput.Length) {
        throw 'Stock F0/N AdaIN block output shape differs.'
    }
    foreach ($value in $stockOutput) {
        if (-not [float]::IsFinite($value)) { throw 'Stock F0/N AdaIN block output is non-finite.' }
    }
    $middle = @{}
    $prefix = 'predictor.module.F0.1.'
    $middle['norm1.fc.weight'] = & $read ($prefix + 'norm1.fc.weight') '1024,128'
    $middle['norm1.fc.bias'] = & $read ($prefix + 'norm1.fc.bias') '1024'
    $middle['norm2.fc.weight'] = & $read ($prefix + 'norm2.fc.weight') '512,128'
    $middle['norm2.fc.bias'] = & $read ($prefix + 'norm2.fc.bias') '512'
    $middle['conv1.weight_v'] = & $read ($prefix + 'conv1.weight_v') '256,512,3'
    $middle['conv1.weight_g'] = & $read ($prefix + 'conv1.weight_g') '256,1,1'
    $middle['conv1.bias'] = & $read ($prefix + 'conv1.bias') '256'
    $middle['conv2.weight_v'] = & $read ($prefix + 'conv2.weight_v') '256,256,3'
    $middle['conv2.weight_g'] = & $read ($prefix + 'conv2.weight_g') '256,1,1'
    $middle['conv2.bias'] = & $read ($prefix + 'conv2.bias') '256'
    $middle['pool.weight_v'] = & $read ($prefix + 'pool.weight_v') '512,1,3'
    $middle['pool.weight_g'] = & $read ($prefix + 'pool.weight_g') '512,1,1'
    $middle['pool.bias'] = & $read ($prefix + 'pool.bias') '512'
    $middle['conv1x1.weight_v'] = & $read ($prefix + 'conv1x1.weight_v') '256,512,1'
    $middle['conv1x1.weight_g'] = & $read ($prefix + 'conv1x1.weight_g') '256,1,1'
    $middleOutput = & $stage -InputTensor $stockInput -Style ([float[]]::new(128)) `
        -Parameters $middle -Frames 2 -Channels 512 -OutputChannels 256 -Upsample
    if ($middleOutput.Length -ne 256 * 4) {
        throw 'Stock F0/N middle block output shape differs.'
    }
    foreach ($value in $middleOutput) {
        if (-not [float]::IsFinite($value)) { throw 'Stock F0/N middle block output is non-finite.' }
    }
}
Write-Output 'PASS: F0/N AdaIN block analytic shortcuts and optional stock-weight gates'
