#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$VoicePath
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$sourcePath = [IO.Path]::Combine($root, 'src', 'text', 'Kokoro.PhonemeExpression.ps1')
$contract = & ([scriptblock]::Create([IO.File]::ReadAllText($sourcePath))) $root
$receipt = & $contract.Verify
if (-not $receipt.Passed) { throw 'The pinned phoneme contract did not pass verification.' }
$voiceBytes = $null
$voiceResource = $null
if ($VoicePath) {
    $manifest = [IO.File]::ReadAllText([IO.Path]::Combine($root, 'lib', 'manifest.json')) |
        ConvertFrom-Json -AsHashtable
    $voiceName = [IO.Path]::GetFileName($VoicePath)
    if ($voiceName -notmatch '^[a-z]{2}_[a-z0-9_]+\.pt$') { throw 'The voice name is not admitted.' }
    $voicePin = @($manifest.model.files | Where-Object { $_.path -ceq "voices\$voiceName" })
    if ($voicePin.Count -ne 1) { throw 'The voice pack is not pinned in the model manifest.' }
    $readerPath = [IO.Path]::Combine($root, 'src', 'runspace', 'Torch.Checkpoint.psm1')
    $reader = [scriptblock]::Create([IO.File]::ReadAllText($readerPath)).InvokeReturnAsIs()
    $archive = & $reader.ReadTensor $VoicePath $voicePin[0].sha256
    $tensor = $archive.Tensors['value']
    if (($tensor.Shape -join ',') -cne '510,1,256' -or $tensor.DType -cne 'float32') {
        throw 'The pinned voice tensor shape or dtype is not admitted.'
    }
    $voiceBytes = & $reader.Bytes $archive 'value'
    if ($voiceBytes.Length -ne 522240) { throw 'The pinned voice tensor has an unexpected payload length.' }
    $voiceResource = 'Kokoro.Voices.' + [IO.Path]::GetFileNameWithoutExtension($voiceName) + '.f32'
}

# Reuse the base-host builder's exact framework LambdaCompiler seam without
# running setup's package acquisition or Android packaging steps.
$setupPath = [IO.Path]::Combine($root, 'setup-kokoro.ps1')
$tokens = $null
$parseErrors = $null
$setupAst = [Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The setup source does not parse.' }
foreach ($functionName in 'Write-MicrosoftLambdaToMethodBuilder', 'Set-DeterministicMvid') {
    $matching = @($setupAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $functionName
    }, $true))
    if ($matching.Count -ne 1) { throw "The base-host builder function $functionName is not unique." }
    . ([scriptblock]::Create($matching[0].Extent.Text))
}

$identity = [Reflection.AssemblyName]::new('Kokoro.Phonemes')
$builder = [Reflection.Emit.PersistedAssemblyBuilder]::new($identity, [object].Assembly)
$module = $builder.DefineDynamicModule('Kokoro.Phonemes.dll')
$type = $module.DefineType('Kokoro.Phonemes.Contract',
    [Reflection.TypeAttributes]'Public,Abstract,Sealed,BeforeFieldInit')
$attributes = [Reflection.MethodAttributes]'Public,Static,HideBySig'
$ids = & $contract.BuildIds
$row = & $contract.BuildVoiceRow
$hash = [Linq.Expressions.Expression]::Lambda[Func[string]](
    [Linq.Expressions.Expression]::Constant($receipt.SourceSHA256, [string]))
foreach ($entry in @(
    [pscustomobject]@{ Name='Ids'; ReturnType=[int[]]; Parameters=[type[]]@([string]); Lambda=$ids },
    [pscustomobject]@{ Name='VoiceRowIndex'; ReturnType=[int]; Parameters=[type[]]@([int]); Lambda=$row },
    [pscustomobject]@{ Name='VocabularySHA256'; ReturnType=[string]; Parameters=[type[]]@(); Lambda=$hash }
)) {
    $method = $type.DefineMethod($entry.Name, $attributes, $entry.ReturnType, $entry.Parameters)
    $null = Write-MicrosoftLambdaToMethodBuilder -Lambda $entry.Lambda -MethodBuilder $method
}
$type.CreateType() | Out-Null
if ($null -eq $voiceBytes) {
    $stream = [IO.MemoryStream]::new()
    try { $builder.Save($stream); $bytes = $stream.ToArray() }
    finally { $stream.Dispose() }
}
else {
    # PersistedAssemblyBuilder resources use the documented MetadataBuilder
    # route; its ModuleBuilder does not implement DefineManifestResource.
    $ilStream = $null
    $fieldData = $null
    $metadata = $builder.GenerateMetadata([ref]$ilStream, [ref]$fieldData)
    $resourceBlob = [Reflection.Metadata.BlobBuilder]::new()
    $resourceBlob.WriteInt32($voiceBytes.Length)
    $resourceBlob.WriteBytes([byte[]]$voiceBytes)
    $null = $metadata.AddManifestResource(
        [Reflection.ManifestResourceAttributes]::Public,
        $metadata.GetOrAddString($voiceResource),
        [Reflection.Metadata.EntityHandle]::new(), [uint32]0)
    $peBuilder = [Reflection.PortableExecutable.ManagedPEBuilder]::new(
        [Reflection.PortableExecutable.PEHeaderBuilder]::CreateLibraryHeader(),
        [Reflection.Metadata.Ecma335.MetadataRootBuilder]::new($metadata),
        $ilStream, $fieldData, $resourceBlob,
        $null, $null, 0, [Reflection.Metadata.MethodDefinitionHandle]::new(),
        [Reflection.PortableExecutable.CorFlags]::ILOnly, $null)
    $peBlob = [Reflection.Metadata.BlobBuilder]::new()
    $peBuilder.Serialize($peBlob) | Out-Null
    $bytes = $peBlob.ToArray()
}
$bytes = Set-DeterministicMvid -Assembly $bytes

# Verify the persisted image before writing it to the requested output path.
$loaded = [Reflection.Assembly]::Load($bytes)
$loadedType = $loaded.GetType('Kokoro.Phonemes.Contract', $true)
$actualHash = [string]$loadedType.GetMethod('VocabularySHA256').Invoke($null, @())
$actualIds = [int[]]$loadedType.GetMethod('Ids').Invoke($null, [object[]]@('a'))
$actualRow = [int]$loadedType.GetMethod('VoiceRowIndex').Invoke($null, [object[]]@(1))
if ($actualHash -cne $receipt.SourceSHA256 -or
    $actualIds.Length -ne 3 -or $actualIds[0] -ne 0 -or $actualIds[1] -ne 43 -or
    $actualIds[2] -ne 0 -or $actualRow -ne 0) {
    throw 'The persisted phoneme assembly failed its Windows load test.'
}
if ($null -ne $voiceBytes) {
    $resourceStream = $loaded.GetManifestResourceStream($voiceResource)
    if ($null -eq $resourceStream) { throw 'The persisted voice resource is missing.' }
    try {
        $readBack = [byte[]]::new($voiceBytes.Length)
        $resourceStream.ReadExactly($readBack, 0, $readBack.Length)
        if ($resourceStream.ReadByte() -ne -1 -or
            -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($voiceBytes, $readBack)) {
            throw 'The persisted voice bytes differ from the pinned tensor.'
        }
    }
    finally { $resourceStream.Dispose() }
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if ([IO.File]::Exists($resolvedOutput)) {
    throw "The output already exists; no file was overwritten: $resolvedOutput"
}
$directory = [IO.Path]::GetDirectoryName($resolvedOutput)
[IO.Directory]::CreateDirectory($directory) | Out-Null
[IO.File]::WriteAllBytes($resolvedOutput, $bytes)
[pscustomobject]@{
    Path = $resolvedOutput
    Bytes = $bytes.Length
    SHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    VocabularySHA256 = $receipt.SourceSHA256
    PinnedPhonemes = $receipt.VocabularyCount
    WindowsLoad = $true
    VoiceResource = $voiceResource
    VoiceBytes = $(if ($null -ne $voiceBytes) { $voiceBytes.Length } else { 0 })
}
