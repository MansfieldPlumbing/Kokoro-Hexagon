#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$modelRoot = Join-Path $root 'src/models'
$paths = @(
    'Read-KokoroAcousticWeights.ps1',
    'Read-KokoroDecoderWeights.ps1',
    'Read-KokoroGeneratorWeights.ps1'
)
$covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($script in $paths) {
    [string[]]$names = & (Join-Path $modelRoot $script) `
        -CheckpointPath $CheckpointPath -NamesOnly
    foreach ($name in $names) {
        if (-not $covered.Add($name)) { throw "Model tensor declared twice: $name" }
    }
}
$reader = [scriptblock]::Create([IO.File]::ReadAllText(
    (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
$checkpoint = & $reader.Read (Resolve-Path -LiteralPath $CheckpointPath).Path
$uncovered = @($checkpoint.Tensors.Keys | Where-Object { -not $covered.Contains([string]$_) })
if ($checkpoint.Tensors.Count -ne 548 -or $covered.Count -ne 546) {
    throw 'Stock checkpoint or model weight-map count differs.'
}
$expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$null = $expected.Add('bert.module.pooler.weight')
$null = $expected.Add('bert.module.pooler.bias')
if ($uncovered.Count -ne 2 -or
    @($uncovered | Where-Object { -not $expected.Contains([string]$_) }).Count -ne 0) {
    throw 'An unaccounted stock checkpoint tensor is absent from the model maps.'
}
Write-Output 'PASS: 546 consumed tensors; two ALBERT pooler tensors are outside last_hidden_state'
