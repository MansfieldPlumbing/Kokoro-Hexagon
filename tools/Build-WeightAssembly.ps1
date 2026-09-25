#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CheckpointPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('FP32', 'FP16')][string]$Precision = 'FP32',
    [string[]]$IncludeTensor
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$pin = ([IO.File]::ReadAllText([IO.Path]::Combine($root, 'lib', 'manifest.json')) |
    ConvertFrom-Json -AsHashtable).model.files |
    Where-Object { $_.path -ceq 'kokoro-v1_0.pth' }
if (@($pin).Count -ne 1) { throw 'The source checkpoint has no unique manifest pin.' }
$source = (Resolve-Path -LiteralPath $CheckpointPath).Path
if ((Get-Item -LiteralPath $source).Length -ne [long]$pin.bytes -or
    (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne [string]$pin.sha256) {
    throw 'The source checkpoint does not match its manifest pin.'
}
$target = [IO.Path]::GetFullPath($OutputPath)
if ([IO.File]::Exists($target)) { throw "The output already exists: $target" }

$readerPath = [IO.Path]::Combine($root, 'src', 'runspace', 'Torch.Checkpoint.psm1')
$reader = [scriptblock]::Create([IO.File]::ReadAllText($readerPath)).InvokeReturnAsIs()
$checkpoint = & $reader.Read $source
$names = @($checkpoint.Tensors.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
if ($names.Count -ne 548) { throw "Expected 548 tensors; found $($names.Count)." }
$allNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in $names) { if (-not $allNames.Add($name)) { throw "Duplicate tensor name: $name" } }
if ($IncludeTensor) {
    $requested = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $IncludeTensor) {
        if (-not $allNames.Contains($name) -or -not $requested.Add($name)) {
            throw "The tensor selection is unknown or duplicated: $name"
        }
    }
    $names = @($names | Where-Object { $requested.Contains($_) })
}
$complete = $names.Count -eq 548
$assemblyName = if ($complete) { "Kokoro.Weights.$Precision" } else { "Kokoro.Weights.$Precision.Probe" }
$fp16 = if ($Precision -eq 'FP16') {
    [scriptblock]::Create([IO.File]::ReadAllText(
        [IO.Path]::Combine($root, 'src', 'weights', 'Kokoro.Fp16Expression.ps1'))).InvokeReturnAsIs()
} else { $null }
$builder = [Reflection.Emit.PersistedAssemblyBuilder]::new(
    [Reflection.AssemblyName]::new($assemblyName), [object].Assembly)
$module = $builder.DefineDynamicModule("$assemblyName.dll")
$type = $module.DefineType('Kokoro.Weights.Marker',
    [Reflection.TypeAttributes]'Public,Abstract,Sealed,BeforeFieldInit')
$null = $type.CreateType()
$il = $null
$field = $null
$metadata = $builder.GenerateMetadata([ref]$il, [ref]$field)
$resources = [Reflection.Metadata.BlobBuilder]::new()
$index = [Collections.Generic.List[object]]::new()
[long]$total = 0
foreach ($name in $names) {
    $tensor = $checkpoint.Tensors[$name]
    if ($tensor.DType -cne 'float32' -or $tensor.ItemBytes -ne 4 -or
        $tensor.Shape.Length -ne $tensor.Stride.Length -or $tensor.Count -le 0 -or
        $tensor.Count -gt [int]::MaxValue / 4) {
        throw "The tensor is not an admitted FP32 payload: $name"
    }
    [long]$expectedStride = 1
    for ([int]$i = $tensor.Shape.Length - 1; $i -ge 0; $i--) {
        if ($tensor.Shape[$i] -le 0 -or $tensor.Stride[$i] -ne $expectedStride) {
            throw "The tensor is not contiguous: $name"
        }
        $expectedStride *= [long]$tensor.Shape[$i]
    }
    if ($expectedStride -ne $tensor.Count) { throw "Tensor element count differs from shape: $name" }
    [int]$sourceByteCount = [int]($tensor.Count * 4)
    $payload = [IO.MemoryStream]::new($sourceByteCount)
    try {
        $copy = & $reader.CopyTensor $checkpoint $name $payload
        if ($copy.BytesWritten -ne $sourceByteCount -or $payload.Length -ne $sourceByteCount) {
            throw "Tensor copy length differs: $name"
        }
        [byte[]]$encoded = if ($Precision -eq 'FP16') {
            & $fp16.Convert $payload.ToArray()
        } else { $payload.GetBuffer() }
        [int]$byteCount = [int]($tensor.Count * $(if ($Precision -eq 'FP16') { 2 } else { 4 }))
        if ($encoded.Length -lt $byteCount) { throw "Encoded tensor length differs: $name" }
        [string]$encodedHash = if ($Precision -eq 'FP16') {
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($encoded))
        } else { $copy.SHA256 }
        [string]$resourceName = "Kokoro.Weight.$name"
        [uint32]$offset = [uint32]$resources.Count
        $resources.WriteInt32($byteCount)
        $resources.WriteBytes($encoded, 0, $byteCount)
        $null = $metadata.AddManifestResource(
            [Reflection.ManifestResourceAttributes]::Public,
            $metadata.GetOrAddString($resourceName),
            [Reflection.Metadata.EntityHandle]::new(), $offset)
        $index.Add([ordered]@{
            name = $name; resource = $resourceName
            dtype = $(if ($Precision -eq 'FP16') { 'float16' } else { 'float32' })
            shape = [int[]]$tensor.Shape; bytes = $byteCount
            sha256 = $encodedHash; source_sha256 = $copy.SHA256
        })
        $total += $byteCount
    }
    finally { $payload.Dispose() }
}
$indexDocument = [ordered]@{
    schema = 1
    source_sha256 = [string]$pin.sha256
    precision = $Precision
    complete = $complete
    tensor_count = $names.Count
    tensor_bytes = $total
    tensors = $index.ToArray()
}
$indexBytes = [Text.Encoding]::UTF8.GetBytes(($indexDocument | ConvertTo-Json -Depth 10 -Compress))
[uint32]$indexOffset = [uint32]$resources.Count
$resources.WriteInt32($indexBytes.Length)
$resources.WriteBytes($indexBytes)
$null = $metadata.AddManifestResource(
    [Reflection.ManifestResourceAttributes]::Public,
    $metadata.GetOrAddString('Kokoro.WeightIndex.json'),
    [Reflection.Metadata.EntityHandle]::new(), $indexOffset)

$pe = [Reflection.PortableExecutable.ManagedPEBuilder]::new(
    [Reflection.PortableExecutable.PEHeaderBuilder]::CreateLibraryHeader(),
    [Reflection.Metadata.Ecma335.MetadataRootBuilder]::new($metadata),
    $il, $field, $resources, $null, $null, 0,
    [Reflection.Metadata.MethodDefinitionHandle]::new(),
    [Reflection.PortableExecutable.CorFlags]::ILOnly, $null)
$blob = [Reflection.Metadata.BlobBuilder]::new()
$pe.Serialize($blob) | Out-Null
if ([IO.File]::Exists($target)) { throw "The output already exists: $target" }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
$file = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $blob.WriteContentTo($file) } finally { $file.Dispose() }
[pscustomobject]@{
    Path = $target
    Bytes = (Get-Item -LiteralPath $target).Length
    SHA256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    TensorCount = $names.Count
    TensorBytes = $total
    Complete = $complete
    Precision = $Precision
    SourceSHA256 = [string]$pin.sha256
}
