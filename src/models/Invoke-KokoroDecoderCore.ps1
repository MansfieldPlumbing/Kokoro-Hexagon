#requires -Version 7.4
# Stock Decoder.encode and Decoder.decode AdaIN residual block sequence.
# Kokoro kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Input is the verified decoder prelude; output feeds Generator, not PCM.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][psobject] $Prelude,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters
)

$ErrorActionPreference = 'Stop'
$frames = [int]$Prelude.Frames
if ($frames -lt 2 -or $frames -gt 512 -or $Style.Length -ne 128 -or
    $Prelude.EncodeInput -isnot [float[]] -or
    $Prelude.EncodeInput.Length -ne [long]514 * $frames -or
    $Prelude.AsrResidual -isnot [float[]] -or
    $Prelude.AsrResidual.Length -ne [long]64 * $frames -or
    $Prelude.DownsampledF0 -isnot [float[]] -or
    $Prelude.DownsampledF0.Length -ne $frames -or
    $Prelude.DownsampledN -isnot [float[]] -or
    $Prelude.DownsampledN.Length -ne $frames) {
    throw 'Decoder core input shape is invalid.'
}
$modelRoot = $PSScriptRoot
$readBlock = {
    param([string] $Prefix, [bool] $Upsample)
    $block = @{}
    foreach ($name in @('norm1.fc.weight', 'norm1.fc.bias',
            'norm2.fc.weight', 'norm2.fc.bias', 'conv1.weight_v',
            'conv1.weight_g', 'conv1.bias', 'conv2.weight_v',
            'conv2.weight_g', 'conv2.bias',
            'conv1x1.weight_v', 'conv1x1.weight_g')) {
        $key = $Prefix + $name
        if (-not $Parameters.Contains($key) -or $Parameters[$key] -isnot [float[]]) {
            throw "Decoder core parameter is absent: $key"
        }
        $block[$name] = $Parameters[$key]
    }
    if ($Upsample) {
        foreach ($name in @('pool.weight_v', 'pool.weight_g', 'pool.bias')) {
            $key = $Prefix + $name
            if (-not $Parameters.Contains($key) -or $Parameters[$key] -isnot [float[]]) {
                throw "Decoder core upsample parameter is absent: $key"
            }
            $block[$name] = $Parameters[$key]
        }
    }
    return $block
}
$encodeParameters = & $readBlock 'encode.' $false
[float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroAdaInResBlock1d.ps1') `
    -InputTensor $Prelude.EncodeInput -Style $Style `
    -Parameters $encodeParameters -Frames $frames `
    -Channels 514 -OutputChannels 1024
for ($block = 0; $block -lt 4; $block++) {
    $joined = [float[]]::new(1090 * $frames)
    [Array]::Copy($state, $joined, $state.Length)
    [Array]::Copy($Prelude.AsrResidual, 0, $joined, 1024 * $frames, 64 * $frames)
    [Array]::Copy($Prelude.DownsampledF0, 0, $joined, 1088 * $frames, $frames)
    [Array]::Copy($Prelude.DownsampledN, 0, $joined, 1089 * $frames, $frames)
    $upsample = $block -eq 3
    $blockParameters = & $readBlock "decode.$block." $upsample
    $args = @{
        InputTensor = $joined
        Style = $Style
        Parameters = $blockParameters
        Frames = $frames
        Channels = 1090
        OutputChannels = $(if ($upsample) { 512 } else { 1024 })
    }
    if ($upsample) { $args.Upsample = $true }
    [float[]]$state = & (Join-Path $modelRoot 'Invoke-KokoroAdaInResBlock1d.ps1') @args
}
[pscustomobject]@{ Features = $state; Frames = 2 * $frames; Channels = 512 }
