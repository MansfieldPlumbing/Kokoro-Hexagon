Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-KokoroWeightAssembly {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $OutputDirectory)
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $inputPath = [IO.Path]::GetFullPath($Path)
    $out = [IO.Path]::GetFullPath($OutputDirectory)
    $build = [IO.Path]::Combine($root, 'build') + [IO.Path]::DirectorySeparatorChar
    if (-not $out.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'Managed payload output must be under this worktree build directory.' }
    [void][IO.Directory]::CreateDirectory($out)
    [byte[]] $weights = [IO.File]::ReadAllBytes($inputPath)
    if ($weights.Length -lt 1) { throw 'Weight payload is empty.' }
    $payloadHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($weights))
    $metadata = [Reflection.Metadata.Ecma335.MetadataBuilder]::new()
    $nilString = [Reflection.Metadata.StringHandle]::new()
    $nilGuid = [Reflection.Metadata.GuidHandle]::new()
    $nilEntity = [Reflection.Metadata.EntityHandle]::new()
    $nilBlob = [Reflection.Metadata.BlobHandle]::new()
    $identity = [Guid]::new($payloadHash.Substring(0, 32))
    $null = $metadata.AddModule(0, $metadata.GetOrAddString('Kokoro.Generator.Weights.dll'), $metadata.GetOrAddGuid($identity), $nilGuid, $nilGuid)
    $null = $metadata.AddAssembly($metadata.GetOrAddString('Kokoro.Generator.Weights'), [Version]::new(1, 0, 0, 0), $nilString, $nilBlob, [Reflection.AssemblyFlags]0, [Reflection.AssemblyHashAlgorithm]::Sha256)
    $null = $metadata.AddTypeDefinition([Reflection.TypeAttributes]::NotPublic, $nilString, $metadata.GetOrAddString('<Module>'), $nilEntity, [Reflection.Metadata.Ecma335.MetadataTokens]::FieldDefinitionHandle(1), [Reflection.Metadata.Ecma335.MetadataTokens]::MethodDefinitionHandle(1))
    # CLI resources have a four-byte length prefix. The resource-relative native
    # bytes start at 128; the actual file offset is derived from the serialized PE.
    $resources = [Reflection.Metadata.BlobBuilder]::new()
    $resources.WriteBytes([byte[]]::new(124))
    $resources.WriteUInt32([uint32]$weights.Length)
    $resources.WriteBytes($weights)
    $null = $metadata.AddManifestResource([Reflection.ManifestResourceAttributes]::Public, $metadata.GetOrAddString('Kokoro.Generator.Weights'), $nilEntity, [uint32]124)
    $header = [Reflection.PortableExecutable.PEHeaderBuilder]::CreateLibraryHeader()
    $pe = [Reflection.PortableExecutable.ManagedPEBuilder]::new($header, [Reflection.Metadata.Ecma335.MetadataRootBuilder]::new($metadata), [Reflection.Metadata.BlobBuilder]::new(), $null, $resources)
    $blob = [Reflection.Metadata.BlobBuilder]::new()
    $null = $pe.Serialize($blob)
    $assemblyPath = [IO.Path]::Combine($out, 'Kokoro.Generator.Weights.dll')
    if ([IO.File]::Exists($assemblyPath)) { throw 'Choose a fresh output directory; existing weight assembly is preserved.' }
    $stagedPath = $assemblyPath + '.staged'
    [IO.File]::WriteAllBytes($stagedPath, $blob.ToArray())
    $file = [IO.File]::OpenRead($stagedPath)
    try {
        $reader = [Reflection.PortableExecutable.PEReader]::new($file)
        try {
            if (-not $reader.HasMetadata -or $file.Length -ne $blob.Count) { throw 'Staged PE/CLI signature or length differs.' }
            $resourceRva = $reader.PEHeaders.CorHeader.ResourcesDirectory.RelativeVirtualAddress
            $section = @($reader.PEHeaders.SectionHeaders | Where-Object { $resourceRva -ge $_.VirtualAddress -and $resourceRva -lt $_.VirtualAddress + $_.SizeOfRawData })
            if ($section.Count -ne 1) { throw 'Managed resource RVA has no unique file section.' }
            $offset = [long]$section[0].PointerToRawData + $resourceRva - $section[0].VirtualAddress + 128
            $readerMetadata = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($reader)
            if ($readerMetadata.GetString($readerMetadata.GetAssemblyDefinition().Name) -cne 'Kokoro.Generator.Weights') { throw 'Staged managed assembly identity differs.' }
            $moduleIdentity = $readerMetadata.GetModuleDefinition().Mvid
            $identityOffset = [long]$reader.PEHeaders.MetadataStartOffset + [Reflection.Metadata.Ecma335.MetadataReaderExtensions]::GetHeapMetadataOffset($readerMetadata, [Reflection.Metadata.Ecma335.HeapIndex]::Guid) + 16L * ([Reflection.Metadata.Ecma335.MetadataTokens]::GetHeapOffset($moduleIdentity) - 1)
            if ($readerMetadata.GetGuid($moduleIdentity) -ne $identity) { throw 'Serialized managed identity differs.' }
        }
        finally { $reader.Dispose() }
    }
    finally { $file.Dispose() }
    $validationMap = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile($stagedPath, [IO.FileMode]::Open, [NullString]::Value, 0L, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
    try {
        $validationView = $validationMap.CreateViewStream($offset, $weights.Length, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
        try {
            if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($validationView)) -cne $payloadHash) { throw 'Staged resource hash differs from native weights.' }
        }
        finally { $validationView.Dispose() }
    }
    finally { $validationMap.Dispose() }
    $assemblyHash = (Get-FileHash -LiteralPath $stagedPath).Hash
    [IO.File]::Move($stagedPath, $assemblyPath)
    $compilerHash = '6900FC735D5F463ECFDB0241B326D959CF7A8B8A252B56B1A7734F20D3BD9BD6'
    $compiler = [IO.Path]::Combine($root, 'build', 'lowered-hexagon', 'compiler', $compilerHash, 'Export-LoweredAssembly.ps1')
    if (-not [IO.File]::Exists($compiler) -or (Get-FileHash -LiteralPath $compiler).Hash -cne $compilerHash) { throw 'Existing pinned PSLowering compiler is unavailable or differs.' }
    $loader = [IO.Path]::Combine($out, 'Kokoro.MappedPayload.dll')
    & $compiler -SourcePath ([IO.Path]::Combine($root, 'src', 'runspace', 'KokoroMappedPayload.ps1')) -ClassName KokoroMappedPayload -OutputPath $loader -Deterministic | Out-Null
    $description = [pscustomobject]@{ PSTypeName = 'Kokoro.Generator.WeightAssembly'; AssemblyPath = $assemblyPath; AssemblySHA256 = $assemblyHash; AssemblyBytes = [long](Get-Item -LiteralPath $assemblyPath).Length; IdentityOffset = $identityOffset; Identity = $identity; ResourceName = 'Kokoro.Generator.Weights'; Offset = $offset; Bytes = [long]$weights.Length; PayloadSHA256 = $payloadHash; LoaderPath = $loader; LoaderSHA256 = (Get-FileHash -LiteralPath $loader).Hash; CompilerCommit = '8880e5e51c65babbf83d8d059c2316c2e4c11858' }
    $description | Export-Clixml -LiteralPath ([IO.Path]::Combine($out, 'payload.clixml'))
    return $description
}

Export-ModuleMember -Function New-KokoroWeightAssembly
