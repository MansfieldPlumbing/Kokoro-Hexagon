#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroAlbertAttention.ps1'
$identity = [float[]]@(1, 0, 0, 1)
$zero = [float[]]@(0, 0)
$parameters = @{
    'query.weight' = $identity; 'query.bias' = $zero
    'key.weight' = $identity; 'key.bias' = $zero
    'value.weight' = $identity; 'value.bias' = $zero
    'dense.weight' = $identity; 'dense.bias' = $zero
    'LayerNorm.weight' = [float[]]@(1, 1)
    'LayerNorm.bias' = $zero
}
$inputTensor = [float[]]@(1, 0, 0, 1)
$output = & $stage -HiddenStates $inputTensor -Parameters $parameters `
    -Tokens 2 -HiddenSize 2 -Heads 1
if ($output.Length -ne 4 -or
    [Math]::Abs([double]$output[0] - 1) -gt 1e-5 -or
    [Math]::Abs([double]$output[1] + 1) -gt 1e-5 -or
    [Math]::Abs([double]$output[2] + 1) -gt 1e-5 -or
    [Math]::Abs([double]$output[3] - 1) -gt 1e-5) {
    throw 'Analytic ALBERT self-attention differs.'
}
$masked = & $stage -HiddenStates $inputTensor -Parameters $parameters `
    -Tokens 2 -HiddenSize 2 -Heads 1 -KeyMask ([bool[]]@($true, $false))
if ($masked.Length -ne 4 -or $masked[0] -ne 1 -or $masked[1] -ne -1 -or
    $masked[2] -ne 0 -or $masked[3] -ne 0) {
    throw 'ALBERT attention mask contract differs.'
}
if ($CheckpointPath) {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
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
    $prefix = 'bert.module.encoder.albert_layer_groups.0.albert_layers.0.attention.'
    $stockParameters = @{}
    foreach ($name in @('query', 'key', 'value', 'dense', 'LayerNorm')) {
        foreach ($suffix in @('weight', 'bias')) {
            $keyName = "$name.$suffix"
            $descriptor = $checkpoint.Tensors[$prefix + $keyName]
            $shape = if ($suffix -eq 'weight' -and $name -ne 'LayerNorm') {
                '768,768'
            } else { '768' }
            if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $shape) {
                throw 'Stock ALBERT attention tensor shape differs.'
            }
            [byte[]]$bytes = & $reader.Bytes $checkpoint ($prefix + $keyName)
            [float[]]$values = [float[]]::new($bytes.Length / 4)
            [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
            $stockParameters[$keyName] = $values
        }
    }
    $stockInput = [float[]]::new(2 * 768)
    for ($i = 0; $i -lt $stockInput.Length; $i++) {
        $stockInput[$i] = [float](0.1 * [Math]::Sin($i * 0.03))
    }
    $stockOutput = & $stage -HiddenStates $stockInput -Parameters $stockParameters `
        -Tokens 2 -HiddenSize 768 -Heads 12
    if ($stockOutput.Length -ne $stockInput.Length) {
        throw 'Stock ALBERT attention output shape differs.'
    }
    foreach ($value in $stockOutput) {
        if (-not [float]::IsFinite($value)) { throw 'Stock ALBERT attention output is non-finite.' }
    }
}
Write-Output 'PASS: bounded ALBERT self-attention, residual norm, mask, and optional stock tensor gate'
