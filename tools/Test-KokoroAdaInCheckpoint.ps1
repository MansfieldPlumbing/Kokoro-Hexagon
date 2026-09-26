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

Write-Output 'PASS: pinned stock AdaIN tensors, identity norm default, style projection'
