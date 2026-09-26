#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroLinear.ps1'
$actual = & $stage -InputTensor ([float[]]@(1, 2, 3, 4, 5, 6)) `
    -Weights ([float[]]@(1, 0, -1, 0, 1, 1)) -Bias ([float[]]@(0.5, -1)) `
    -Rows 2 -InputChannels 3 -OutputChannels 2
if ($actual.Length -ne 4 -or $actual[0] -ne -1.5 -or
    $actual[1] -ne 4 -or $actual[2] -ne -1.5 -or $actual[3] -ne 10) {
    throw 'Analytic Kokoro linear projection differs.'
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
    $weightName = 'bert_encoder.module.weight'
    $biasName = 'bert_encoder.module.bias'
    if (($checkpoint.Tensors[$weightName].Shape -join ',') -cne '512,768' -or
        ($checkpoint.Tensors[$biasName].Shape -join ',') -cne '512') {
        throw 'Stock BERT encoder projection shape differs.'
    }
    [byte[]]$weightBytes = & $reader.Bytes $checkpoint $weightName
    [byte[]]$biasBytes = & $reader.Bytes $checkpoint $biasName
    [float[]]$weights = [float[]]::new($weightBytes.Length / 4)
    [float[]]$bias = [float[]]::new($biasBytes.Length / 4)
    [Buffer]::BlockCopy($weightBytes, 0, $weights, 0, $weightBytes.Length)
    [Buffer]::BlockCopy($biasBytes, 0, $bias, 0, $biasBytes.Length)
    $inputTensor = [float[]]::new(2 * 768)
    for ($i = 0; $i -lt $inputTensor.Length; $i++) {
        $inputTensor[$i] = [float](0.1 * [Math]::Cos($i * 0.02))
    }
    $output = & $stage -InputTensor $inputTensor -Weights $weights -Bias $bias `
        -Rows 2 -InputChannels 768 -OutputChannels 512
    if ($output.Length -ne 1024) { throw 'Stock BERT encoder output shape differs.' }
    foreach ($value in $output) {
        if (-not [float]::IsFinite($value)) { throw 'Stock BERT encoder output is non-finite.' }
    }
}
Write-Output 'PASS: Kokoro BERT encoder linear arithmetic and optional pinned checkpoint gate'
