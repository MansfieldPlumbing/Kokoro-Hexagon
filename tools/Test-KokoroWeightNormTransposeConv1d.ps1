#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroWeightNormTransposeConv1d.ps1'
$analytic = & $stage -InputTensor ([float[]]@(1, 2)) `
    -WeightV ([float[]]@(1, 0)) -WeightG ([float[]]@(1)) `
    -Bias ([float[]]@(0)) -Frames 2 -InputChannels 1 `
    -OutputChannels 1 -KernelSize 2 -Stride 2 -Padding 0
if (($analytic -join ',') -cne '1,0,2,0') {
    throw 'Analytic generator transposed convolution differs.'
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
            throw "Stock generator upsample tensor shape differs: $Name"
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    $inputTensor = [float[]]::new(512 * 2)
    for ($i = 0; $i -lt $inputTensor.Length; $i++) {
        $inputTensor[$i] = [float](0.1 * [Math]::Sin($i * 0.03))
    }
    $first = & $stage -InputTensor $inputTensor `
        -WeightV (& $read 'decoder.module.generator.ups.0.weight_v' '512,256,20') `
        -WeightG (& $read 'decoder.module.generator.ups.0.weight_g' '512,1,1') `
        -Bias (& $read 'decoder.module.generator.ups.0.bias' '256') `
        -Frames 2 -InputChannels 512 -OutputChannels 256 `
        -KernelSize 20 -Stride 10 -Padding 5
    $second = & $stage -InputTensor $first `
        -WeightV (& $read 'decoder.module.generator.ups.1.weight_v' '256,128,12') `
        -WeightG (& $read 'decoder.module.generator.ups.1.weight_g' '256,1,1') `
        -Bias (& $read 'decoder.module.generator.ups.1.bias' '128') `
        -Frames 20 -InputChannels 256 -OutputChannels 128 `
        -KernelSize 12 -Stride 6 -Padding 3
    if ($first.Length -ne 256 * 20 -or $second.Length -ne 128 * 120) {
        throw 'Stock generator upsample output shape differs.'
    }
    foreach ($values in @($first, $second)) {
        foreach ($value in $values) {
            if (-not [float]::IsFinite($value)) {
                throw 'Stock generator upsample output is non-finite.'
            }
        }
    }
}
Write-Output 'PASS: generator transposed convolutions analytic and optional stock gate'
