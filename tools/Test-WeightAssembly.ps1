#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AssemblyPath
)
$ErrorActionPreference = 'Stop'
$path = (Resolve-Path -LiteralPath $AssemblyPath).Path
$assembly = [Reflection.Assembly]::LoadFrom($path)
if ($null -eq $assembly.GetType('Kokoro.Weights.Marker', $false)) {
    throw 'The managed weight assembly marker is missing.'
}
$resourceNames = [Collections.Generic.HashSet[string]]::new(
    [string[]]$assembly.GetManifestResourceNames(), [StringComparer]::Ordinal)
$indexName = 'Kokoro.WeightIndex.json'
if (-not $resourceNames.Contains($indexName)) { throw 'The tensor index resource is missing.' }
$indexStream = $assembly.GetManifestResourceStream($indexName)
try {
    $indexBytes = [byte[]]::new([int]$indexStream.Length)
    $indexStream.ReadExactly($indexBytes, 0, $indexBytes.Length)
    if ($indexStream.ReadByte() -ne -1) { throw 'The tensor index has trailing bytes.' }
}
finally { $indexStream.Dispose() }
$index = [Text.Encoding]::UTF8.GetString($indexBytes) | ConvertFrom-Json -AsHashtable
if ($index.schema -ne 1 -or $index.tensor_count -ne @($index.tensors).Count -or
    $resourceNames.Count -ne $index.tensor_count + 1 -or
    $index.precision -cnotin @('FP32', 'FP16') -or
    $index.source_sha256 -cne '496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4') {
    throw 'The tensor index header or resource count is invalid.'
}
[int]$itemBytes = if ($index.precision -eq 'FP16') { 2 } else { 4 }
[string]$dtype = if ($index.precision -eq 'FP16') { 'float16' } else { 'float32' }
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
[long]$total = 0
foreach ($tensor in $index.tensors) {
    if (-not $seen.Add([string]$tensor.name) -or
        $tensor.resource -cne "Kokoro.Weight.$($tensor.name)" -or
        -not $resourceNames.Contains([string]$tensor.resource) -or
        $tensor.dtype -cne $dtype -or $tensor.bytes -le 0 -or
        $tensor.sha256 -cnotmatch '^[0-9A-F]{64}$' -or
        $tensor.source_sha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw "The tensor index entry is invalid: $($tensor.name)"
    }
    [long]$count = 1
    foreach ($dimension in $tensor.shape) {
        if ($dimension -le 0 -or $count -gt [long]::MaxValue / [long]$dimension) {
            throw "The tensor shape is invalid: $($tensor.name)"
        }
        $count *= [long]$dimension
    }
    if ($count * $itemBytes -ne [long]$tensor.bytes) {
        throw "The tensor byte count differs from its shape: $($tensor.name)"
    }
    $stream = $assembly.GetManifestResourceStream([string]$tensor.resource)
    if ($null -eq $stream) { throw "The tensor resource is missing: $($tensor.name)" }
    $digest = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        if ($stream.Length -ne [long]$tensor.bytes) {
            throw "The tensor resource length differs: $($tensor.name)"
        }
        [byte[]]$buffer = [byte[]]::new(65536)
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $digest.AppendData($buffer, 0, $read)
        }
        $actual = [Convert]::ToHexString($digest.GetHashAndReset())
        if ($actual -cne $tensor.sha256) {
            throw "The tensor resource digest differs: $($tensor.name)"
        }
    }
    finally { $digest.Dispose(); $stream.Dispose() }
    $total += [long]$tensor.bytes
}
if ($total -ne [long]$index.tensor_bytes -or
    ($index.complete -and ($index.tensor_count -ne 548 -or $total -ne 327053640 * ($itemBytes / 4)))) {
    throw 'The total tensor payload is invalid.'
}
[pscustomobject]@{
    WindowsLoad = $true
    Complete = [bool]$index.complete
    Precision = [string]$index.precision
    TensorCount = [int]$index.tensor_count
    TensorBytes = $total
    AssemblyBytes = (Get-Item -LiteralPath $path).Length
    AssemblySHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
