#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroDurationPrediction.ps1'
$weights = [float[]]::new(50 * 512)
$bias = [float[]]::new(50)
$lstmOutput = [float[]]::new(2 * 512)
$map = & $stage -LstmOutput $lstmOutput -Weights $weights -Bias $bias `
    -TokenCount 2 -Speed 1
if ($map.TokenCount -ne 2 -or $map.FrameCount -ne 50 -or
    ($map.Counts -join ',') -cne '25,25' -or
    $map.FrameToToken[0] -ne 0 -or $map.FrameToToken[49] -ne 1) {
    throw 'Analytic duration projection and alignment differ.'
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
    $weightName = 'predictor.module.duration_proj.linear_layer.weight'
    $biasName = 'predictor.module.duration_proj.linear_layer.bias'
    if (($checkpoint.Tensors[$weightName].Shape -join ',') -cne '50,512' -or
        ($checkpoint.Tensors[$biasName].Shape -join ',') -cne '50') {
        throw 'Stock duration projection shape differs.'
    }
    [byte[]]$weightBytes = & $reader.Bytes $checkpoint $weightName
    [byte[]]$biasBytes = & $reader.Bytes $checkpoint $biasName
    $weights = [float[]]::new($weightBytes.Length / 4)
    $bias = [float[]]::new($biasBytes.Length / 4)
    [Buffer]::BlockCopy($weightBytes, 0, $weights, 0, $weightBytes.Length)
    [Buffer]::BlockCopy($biasBytes, 0, $bias, 0, $biasBytes.Length)
    $stockMap = & $stage -LstmOutput $lstmOutput -Weights $weights -Bias $bias `
        -TokenCount 2 -Speed 1
    if ($stockMap.TokenCount -ne 2 -or $stockMap.FrameCount -lt 2 -or
        $stockMap.FrameToToken.Length -ne $stockMap.FrameCount) {
        throw 'Stock duration projection output shape differs.'
    }
}
Write-Output 'PASS: duration projection, stock weights, and frame-to-token map'
