#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroConv1d.ps1'
$analytic = & $stage -InputTensor ([float[]]@(1, 2, 3, 4)) `
    -Weights ([float[]]@(0, 1, 0)) -Bias ([float[]]@(0)) `
    -Frames 4 -InputChannels 1 -OutputChannels 1 `
    -KernelSize 3 -Stride 2 -Padding 1
if (($analytic -join ',') -cne '1,3') {
    throw 'Analytic ordinary Conv1D stride/padding differs.'
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
            throw "Stock noise convolution tensor shape differs: $Name"
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    $spectrum = [float[]]::new(22 * 121)
    for ($i = 0; $i -lt $spectrum.Length; $i++) {
        $spectrum[$i] = [float](0.1 * [Math]::Sin($i * 0.03))
    }
    $first = & $stage -InputTensor $spectrum `
        -Weights (& $read 'decoder.module.generator.noise_convs.0.weight' '256,22,12') `
        -Bias (& $read 'decoder.module.generator.noise_convs.0.bias' '256') `
        -Frames 121 -InputChannels 22 -OutputChannels 256 `
        -KernelSize 12 -Stride 6 -Padding 3
    $second = & $stage -InputTensor $spectrum `
        -Weights (& $read 'decoder.module.generator.noise_convs.1.weight' '128,22,1') `
        -Bias (& $read 'decoder.module.generator.noise_convs.1.bias' '128') `
        -Frames 121 -InputChannels 22 -OutputChannels 128 `
        -KernelSize 1 -Stride 1 -Padding 0
    if ($first.Length -ne 256 * 20 -or $second.Length -ne 128 * 121) {
        throw 'Stock noise convolution frame alignment differs.'
    }
    foreach ($values in @($first, $second)) {
        foreach ($value in $values) {
            if (-not [float]::IsFinite($value)) {
                throw 'Stock noise convolution output is non-finite.'
            }
        }
    }
}
Write-Output 'PASS: generator noise convolutions analytic and optional stock gate'
