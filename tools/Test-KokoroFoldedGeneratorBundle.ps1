#requires -Version 7.4
[CmdletBinding()]
param([string]$CheckpointPath = 'C:\models\Kokoro-82M\kokoro-v1_0.pth')

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out = Join-Path $repo ('build/folded-generator-bundle-' + [Guid]::NewGuid().ToString('N'))
$result = & (Join-Path $repo 'tools/Build-KokoroFoldedGeneratorBundle.ps1') -CheckpointPath $CheckpointPath -OutputDirectory $out -SkipFiniteScan `
    -IncludeTensor @('resblocks.3.convs1.0.weight_v', 'resblocks.3.convs1.0.bias')
$manifest = Get-Content -LiteralPath $result.Manifest -Raw | ConvertFrom-Json
if ($manifest.role -cne 'build_time_folded_generator_weight_bundle' -or $manifest.dtype -cne 'float32' -or $manifest.complete_generator -or
    $manifest.folded_weight_norm_pair_count -lt 1 -or $manifest.tensor_count -lt 1 -or
    $manifest.bytes -ne (Get-Item -LiteralPath (Join-Path $out 'weights.fp32.bin')).Length -or
    $manifest.sha256 -cne (Get-FileHash -LiteralPath (Join-Path $out 'weights.fp32.bin') -Algorithm SHA256).Hash) {
    throw 'Folded generator bundle manifest differs from its artifact.'
}
$entry = @($manifest.tensors | Where-Object name -ceq 'resblocks.3.convs1.0.weight')
if ($entry.Count -ne 1) { throw 'Expected folded convolution entry is absent.' }
$record = & (Join-Path $repo 'src/models/Read-KokoroGeneratorWeights.ps1') -CheckpointPath $CheckpointPath -SkipFiniteScan
[float[]]$expected = & (Join-Path $repo 'src/models/ConvertTo-KokoroWeightNormConv1dWeights.ps1') `
    -InputChannels 128 -OutputChannels 128 -KernelSize 3 `
    -WeightV $record.Parameters['resblocks.3.convs1.0.weight_v'] -WeightG $record.Parameters['resblocks.3.convs1.0.weight_g']
[byte[]]$expectedBytes = [byte[]]::new($expected.Length * 4)
[Buffer]::BlockCopy($expected, 0, $expectedBytes, 0, $expectedBytes.Length)
[byte[]]$actualBytes = [byte[]]::new($entry.bytes)
$stream = [IO.File]::OpenRead((Join-Path $out 'weights.fp32.bin'))
try {
    $stream.Position = $entry.offset
    if ($stream.Read($actualBytes, 0, $actualBytes.Length) -ne $actualBytes.Length) { throw 'Folded entry is truncated.' }
} finally { $stream.Dispose() }
$matches = $expectedBytes.Length -eq $actualBytes.Length
for ($i = 0; $matches -and $i -lt $expectedBytes.Length; $i++) {
    if ($expectedBytes[$i] -ne $actualBytes[$i]) { $matches = $false }
}
if (-not $matches) { throw 'Folded bundle entry differs from the admitted folding operation.' }
[pscustomobject]@{ Passed = $true; TensorCount = $manifest.tensor_count; FoldedPairs = $manifest.folded_weight_norm_pair_count; Bytes = $manifest.bytes }
