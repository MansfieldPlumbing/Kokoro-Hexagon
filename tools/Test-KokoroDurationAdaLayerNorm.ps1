#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroDurationAdaLayerNorm.ps1'
$actual = & $stage -InputTensor ([float[]]@(1, 2, 3, 4)) -Style ([float[]]@(0)) `
    -FcWeights ([float[]]@(0, 0, 0, 0)) -FcBias ([float[]]@(0, 0, 0, 0)) `
    -Frames 2 -Channels 2
$expected = [float[]]@(-1, 1, 0, -1, 1, 0)
if ($actual.Length -ne $expected.Length) { throw 'Duration adaptive norm output shape differs.' }
for ($i = 0; $i -lt $actual.Length; $i++) {
    if ([Math]::Abs([double]$actual[$i] - [double]$expected[$i]) -gt 3e-5) {
        throw 'Analytic duration adaptive norm or style concatenation differs.'
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
    $prefix = 'predictor.module.text_encoder.lstms.1.fc.'
    if (($checkpoint.Tensors[$prefix + 'weight'].Shape -join ',') -cne '1024,128' -or
        ($checkpoint.Tensors[$prefix + 'bias'].Shape -join ',') -cne '1024') {
        throw 'Stock duration adaptive norm tensor shape differs.'
    }
    [byte[]]$weightBytes = & $reader.Bytes $checkpoint ($prefix + 'weight')
    [byte[]]$biasBytes = & $reader.Bytes $checkpoint ($prefix + 'bias')
    $weight = [float[]]::new($weightBytes.Length / 4)
    $bias = [float[]]::new($biasBytes.Length / 4)
    [Buffer]::BlockCopy($weightBytes, 0, $weight, 0, $weightBytes.Length)
    [Buffer]::BlockCopy($biasBytes, 0, $bias, 0, $biasBytes.Length)
    $stock = & $stage -InputTensor ([float[]]::new(2 * 512)) `
        -Style ([float[]]::new(128)) -FcWeights $weight -FcBias $bias `
        -Frames 2 -Channels 512
    if ($stock.Length -ne 1280) { throw 'Stock duration adaptive norm output shape differs.' }
    foreach ($value in $stock) {
        if (-not [float]::IsFinite($value)) { throw 'Stock duration adaptive norm output is non-finite.' }
    }
}
Write-Output 'PASS: duration adaptive layer norm, style concatenation, and stock tensor gate'
