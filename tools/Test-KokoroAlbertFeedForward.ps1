#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroAlbertFeedForward.ps1'
$parameters = @{
    'ffn.weight' = [float[]]@(0, 0, 0, 0)
    'ffn.bias' = [float[]]@(0, 0)
    'ffn_output.weight' = [float[]]@(0, 0, 0, 0)
    'ffn_output.bias' = [float[]]@(0, 0)
    'full_layer_layer_norm.weight' = [float[]]@(1, 1)
    'full_layer_layer_norm.bias' = [float[]]@(0, 0)
}
$output = & $stage -AttentionOutput ([float[]]@(1, 0, 0, 1)) `
    -Parameters $parameters -Tokens 2 -HiddenSize 2 -IntermediateSize 2
if ($output.Length -ne 4 -or $output[0] -ne 1 -or $output[1] -ne -1 -or
    $output[2] -ne -1 -or $output[3] -ne 1) {
    throw 'Analytic ALBERT feed-forward residual norm differs.'
}
$parameters['ffn.weight'] = [float[]]@(1, 0, 0, 1)
$parameters['ffn_output.weight'] = [float[]]@(1, 0, 0, 1)
$nonzero = & $stage -AttentionOutput ([float[]]@(1, 0, 0, 1)) `
    -Parameters $parameters -Tokens 2 -HiddenSize 2 -IntermediateSize 2
if ($nonzero.Length -ne 4 -or $nonzero[0] -le 0 -or $nonzero[1] -ge 0) {
    throw 'ALBERT gelu_new feed-forward branch differs.'
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
    $prefix = 'bert.module.encoder.albert_layer_groups.0.albert_layers.0.'
    $stockParameters = @{}
    $shapes = @{
        'ffn.weight' = '2048,768'; 'ffn.bias' = '2048'
        'ffn_output.weight' = '768,2048'; 'ffn_output.bias' = '768'
        'full_layer_layer_norm.weight' = '768'; 'full_layer_layer_norm.bias' = '768'
    }
    foreach ($entry in $shapes.GetEnumerator()) {
        $descriptor = $checkpoint.Tensors[$prefix + $entry.Key]
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $entry.Value) {
            throw 'Stock ALBERT feed-forward tensor shape differs.'
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint ($prefix + $entry.Key)
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        $stockParameters[$entry.Key] = $values
    }
    $stockInput = [float[]]::new(2 * 768)
    for ($i = 0; $i -lt $stockInput.Length; $i++) {
        $stockInput[$i] = [float](0.1 * [Math]::Sin($i * 0.03))
    }
    $stockOutput = & $stage -AttentionOutput $stockInput -Parameters $stockParameters `
        -Tokens 2 -HiddenSize 768 -IntermediateSize 2048
    if ($stockOutput.Length -ne $stockInput.Length) {
        throw 'Stock ALBERT feed-forward output shape differs.'
    }
    foreach ($value in $stockOutput) {
        if (-not [float]::IsFinite($value)) { throw 'Stock ALBERT feed-forward output is non-finite.' }
    }
}
Write-Output 'PASS: ALBERT feed-forward gelu_new, residual norm, and optional stock tensor gate'
