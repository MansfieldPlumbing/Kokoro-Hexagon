#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroBidirectionalLstm.ps1'
$candidateBias = [float][Math]::Atanh(0.5)
$parameters = @{}
foreach ($suffix in @('', '_reverse')) {
    $parameters["weight_ih_l0$suffix"] = [float[]]@(0, 0, 0, 0)
    $parameters["weight_hh_l0$suffix"] = [float[]]@(0, 0, 0, 0)
    $parameters["bias_ih_l0$suffix"] = [float[]]@(0, 0, $candidateBias, 0)
    $parameters["bias_hh_l0$suffix"] = [float[]]@(0, 0, 0, 0)
}
$actual = & $stage -InputTensor ([float[]]@(0, 0)) -Parameters $parameters `
    -Frames 2 -InputSize 1 -HiddenSize 1
$first = 0.5 * [Math]::Tanh(0.25)
$second = 0.5 * [Math]::Tanh(0.375)
$expected = [double[]]@($first, $second, $second, $first)
if ($actual.Length -ne 4) { throw 'Bidirectional LSTM output shape differs.' }
for ($i = 0; $i -lt 4; $i++) {
    if ([Math]::Abs([double]$actual[$i] - $expected[$i]) -gt 1e-6) {
        throw 'Analytic bidirectional LSTM gate or direction order differs.'
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
    $stockParameters = @{}
    $prefix = 'predictor.module.lstm.'
    foreach ($suffix in @('', '_reverse')) {
        foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
            $shape = if ($name -eq 'weight_ih_l0') { '1024,640' }
                elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
            $key = $name + $suffix
            $descriptor = $checkpoint.Tensors[$prefix + $key]
            if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $shape) {
                throw 'Stock duration LSTM parameter shape differs.'
            }
            [byte[]]$bytes = & $reader.Bytes $checkpoint ($prefix + $key)
            [float[]]$values = [float[]]::new($bytes.Length / 4)
            [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
            $stockParameters[$key] = $values
        }
    }
    $stockInput = [float[]]::new(2 * 640)
    for ($i = 0; $i -lt $stockInput.Length; $i++) {
        $stockInput[$i] = [float](0.1 * [Math]::Sin($i * 0.02))
    }
    $stockOutput = & $stage -InputTensor $stockInput -Parameters $stockParameters `
        -Frames 2 -InputSize 640 -HiddenSize 256
    if ($stockOutput.Length -ne 1024) { throw 'Stock duration LSTM output shape differs.' }
    foreach ($value in $stockOutput) {
        if (-not [float]::IsFinite($value)) { throw 'Stock duration LSTM output is non-finite.' }
    }
}
Write-Output 'PASS: bidirectional LSTM gates, direction order, and optional stock duration weights'
