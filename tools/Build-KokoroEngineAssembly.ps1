#requires -Version 7.4
# Consolidate verified weight and phoneme/voice parts into one downstream model DLL.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WeightAssemblyPath,
    [Parameter(Mandatory)][string] $PhonemeAssemblyPath,
    [Parameter(Mandatory)][string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$weightPath = (Resolve-Path -LiteralPath $WeightAssemblyPath).Path
$phonemePath = (Resolve-Path -LiteralPath $PhonemeAssemblyPath).Path
$target = [IO.Path]::GetFullPath($OutputPath)
if ([IO.File]::Exists($target)) { throw "The output already exists: $target" }

$weightAssembly = [Reflection.Assembly]::LoadFrom($weightPath)
$phonemeAssembly = [Reflection.Assembly]::LoadFrom($phonemePath)
if ($weightAssembly.GetName().Name -cne 'Kokoro.Weights.FP32' -or
    $null -eq $weightAssembly.GetType('Kokoro.Weights.Marker', $false)) {
    throw 'The weight assembly identity is not admitted.'
}
if ($phonemeAssembly.GetName().Name -cne 'Kokoro.Phonemes') {
    throw 'The phoneme assembly identity is not admitted.'
}

$readResource = {
    param([Reflection.Assembly] $Assembly, [string] $Name, [int] $ExpectedBytes = -1)
    $stream = $Assembly.GetManifestResourceStream($Name)
    if ($null -eq $stream) { throw "Managed resource is missing: $Name" }
    try {
        if ($stream.Length -gt [int]::MaxValue -or
            ($ExpectedBytes -ge 0 -and $stream.Length -ne $ExpectedBytes)) {
            throw "Managed resource length is invalid: $Name"
        }
        [byte[]]$bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes, 0, $bytes.Length)
        if ($stream.ReadByte() -ne -1) { throw "Managed resource has trailing data: $Name" }
        return ,$bytes
    }
    finally { $stream.Dispose() }
}.GetNewClosure()

[byte[]]$indexBytes = & $readResource $weightAssembly 'Kokoro.WeightIndex.json'
$weightIndex = [Text.Encoding]::UTF8.GetString($indexBytes) | ConvertFrom-Json
if (-not $weightIndex.complete -or $weightIndex.precision -cne 'FP32' -or
    [int]$weightIndex.tensor_count -ne 548 -or @($weightIndex.tensors).Count -ne 548) {
    throw 'The weight assembly does not contain the complete admitted FP32 index.'
}
$weightNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($tensor in @($weightIndex.tensors)) {
    if (-not $weightNames.Add([string]$tensor.resource) -or
        [string]$tensor.sha256 -notmatch '^[0-9A-F]{64}$' -or
        [int]$tensor.bytes -le 0) {
        throw 'The weight resource index contains an invalid or duplicate entry.'
    }
}

$voiceNames = @($phonemeAssembly.GetManifestResourceNames() |
    Where-Object { $_ -match '^Kokoro\.Voices\.[a-z]{2}_[a-z0-9_]+\.f32$' })
if ($voiceNames.Count -ne 1) { throw 'The phoneme assembly must carry exactly one admitted voice.' }
[byte[]]$voiceBytes = & $readResource $phonemeAssembly $voiceNames[0] 522240

$phonemeSource = [IO.Path]::Combine($root, 'src', 'text', 'Kokoro.PhonemeExpression.ps1')
$phonemeTokens = $null
$phonemeErrors = $null
$phonemeAst = [Management.Automation.Language.Parser]::ParseFile(
    $phonemeSource, [ref]$phonemeTokens, [ref]$phonemeErrors)
if ($phonemeErrors.Count -ne 0) { throw 'The phoneme expression source does not parse.' }
$phonemeBlock = $phonemeAst.GetScriptBlock()
$phonemeContract = & $phonemeBlock $root
$phonemeReceipt = & $phonemeContract.Verify
if (-not $phonemeReceipt.Passed) { throw 'The phoneme expression contract did not verify.' }
$persistedPhoneme = $phonemeAssembly.GetType('Kokoro.Phonemes.Contract', $true)
$persistedVocabularyHash = [string]$persistedPhoneme.GetMethod('VocabularySHA256').Invoke($null, @())
if ($persistedVocabularyHash -cne $phonemeReceipt.SourceSHA256) {
    throw 'The phoneme assembly vocabulary identity differs from source.'
}

$modelContract = & ([IO.Path]::Combine($root, 'src', 'build', 'Get-KokoroModelContract.ps1')) `
    -RepositoryRoot $root
if ($modelContract.Complete) { throw 'This builder expects the current incomplete graph contract.' }

$upstream = & ([IO.Path]::Combine($root, 'tools', 'Get-PwshUpstream.ps1'))
$setupReceipt = @($upstream.Files | Where-Object { $_.Path -ceq 'setup.ps1' })
if ($setupReceipt.Count -ne 1) { throw 'The pinned Pwsh setup receipt is not unique.' }
$imports = & ([IO.Path]::Combine($root, 'src', 'build', 'Import-PwshBuildFunction.ps1')) `
    -SetupPath $setupReceipt[0].LocalPath -RepositoryRoot $root `
    -FunctionName 'Write-MicrosoftLambdaToMethodBuilder', 'Set-DeterministicMvid'
foreach ($definition in $imports.Definitions) { . $definition }

$assemblyName = 'Dev.MansfieldPlumbing.Kokoro.Model'
$builder = [Reflection.Emit.PersistedAssemblyBuilder]::new(
    [Reflection.AssemblyName]::new($assemblyName), [object].Assembly)
$module = $builder.DefineDynamicModule("$assemblyName.dll")
$type = $module.DefineType('Dev.MansfieldPlumbing.Kokoro.Model.Contract',
    [Reflection.TypeAttributes]'Public,Abstract,Sealed,BeforeFieldInit')
$attributes = [Reflection.MethodAttributes]'Public,Static,HideBySig'
$ids = & $phonemeContract.BuildIds
$row = & $phonemeContract.BuildVoiceRow
$methods = @(
    [pscustomobject]@{ Name='Ids'; Return=[int[]]; Parameters=[type[]]@([string]); Lambda=$ids },
    [pscustomobject]@{ Name='VoiceRowIndex'; Return=[int]; Parameters=[type[]]@([int]); Lambda=$row },
    [pscustomobject]@{ Name='VocabularySHA256'; Return=[string]; Parameters=[type[]]@(); Lambda=[Linq.Expressions.Expression]::Lambda[Func[string]]([Linq.Expressions.Expression]::Constant($phonemeReceipt.SourceSHA256, [string])) },
    [pscustomobject]@{ Name='GraphSHA256'; Return=[string]; Parameters=[type[]]@(); Lambda=[Linq.Expressions.Expression]::Lambda[Func[string]]([Linq.Expressions.Expression]::Constant($modelContract.GraphSHA256, [string])) },
    [pscustomobject]@{ Name='ModelContractVersion'; Return=[int]; Parameters=[type[]]@(); Lambda=[Linq.Expressions.Expression]::Lambda[Func[int]]([Linq.Expressions.Expression]::Constant(1, [int])) },
    [pscustomobject]@{ Name='SynthesisReady'; Return=[bool]; Parameters=[type[]]@(); Lambda=[Linq.Expressions.Expression]::Lambda[Func[bool]]([Linq.Expressions.Expression]::Constant($false, [bool])) }
)
foreach ($entry in $methods) {
    $method = $type.DefineMethod($entry.Name, $attributes, $entry.Return, $entry.Parameters)
    [void](Write-MicrosoftLambdaToMethodBuilder -Lambda $entry.Lambda -MethodBuilder $method)
}
[void]$type.CreateType()

$il = $null
$fieldData = $null
$metadata = $builder.GenerateMetadata([ref]$il, [ref]$fieldData)
$resources = [Reflection.Metadata.BlobBuilder]::new()
$addResource = {
    param([string] $Name, [byte[]] $Bytes)
    [uint32]$offset = [uint32]$resources.Count
    $resources.WriteInt32($Bytes.Length)
    $resources.WriteBytes($Bytes)
    [void]$metadata.AddManifestResource(
        [Reflection.ManifestResourceAttributes]::Public,
        $metadata.GetOrAddString($Name),
        [Reflection.Metadata.EntityHandle]::new(), $offset)
}.GetNewClosure()

foreach ($tensor in @($weightIndex.tensors)) {
    [byte[]]$bytes = & $readResource $weightAssembly ([string]$tensor.resource) ([int]$tensor.bytes)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if ($hash -cne [string]$tensor.sha256) {
        throw "Weight resource integrity failed: $($tensor.resource)"
    }
    & $addResource ([string]$tensor.resource) $bytes
}
& $addResource 'Kokoro.WeightIndex.json' $indexBytes
& $addResource $voiceNames[0] $voiceBytes

$engineIdentity = [ordered]@{
    schema = 1
    assembly = $assemblyName
    pwsh_commit = [string]$upstream.Commit
    model_revision = [string]((Get-Content -LiteralPath ([IO.Path]::Combine($root, 'lib', 'manifest.json')) -Raw | ConvertFrom-Json).model.revision)
    checkpoint_sha256 = [string]$weightIndex.source_sha256
    vocabulary_sha256 = [string]$phonemeReceipt.SourceSHA256
    graph_sha256 = [string]$modelContract.GraphSHA256
    graph_scope = [string]$modelContract.Scope
    graph_complete = $false
    voice_resource = [string]$voiceNames[0]
    tensor_count = 548
    precision = 'FP32'
    synthesis_ready = $false
}
[byte[]]$identityBytes = [Text.Encoding]::UTF8.GetBytes(
    ($engineIdentity | ConvertTo-Json -Depth 6 -Compress))
& $addResource 'Kokoro.EngineContract.json' $identityBytes

$pe = [Reflection.PortableExecutable.ManagedPEBuilder]::new(
    [Reflection.PortableExecutable.PEHeaderBuilder]::CreateLibraryHeader(),
    [Reflection.Metadata.Ecma335.MetadataRootBuilder]::new($metadata),
    $il, $fieldData, $resources, $null, $null, 0,
    [Reflection.Metadata.MethodDefinitionHandle]::new(),
    [Reflection.PortableExecutable.CorFlags]::ILOnly, $null)
$blob = [Reflection.Metadata.BlobBuilder]::new()
[void]$pe.Serialize($blob)
$stream = [IO.MemoryStream]::new()
try {
    $blob.WriteContentTo($stream)
    [byte[]]$assemblyBytes = Set-DeterministicMvid -Assembly $stream.ToArray()
}
finally { $stream.Dispose() }

[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
$output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $output.Write($assemblyBytes, 0, $assemblyBytes.Length) }
finally { $output.Dispose() }

$loaded = [Reflection.Assembly]::LoadFrom($target)
$loadedType = $loaded.GetType('Dev.MansfieldPlumbing.Kokoro.Model.Contract', $true)
if ([bool]$loadedType.GetMethod('SynthesisReady').Invoke($null, @()) -or
    $null -ne $loadedType.GetMethod('SynthesizePhonemes')) {
    throw 'The incomplete downstream model assembly admitted synthesis.'
}
if ([string]$loadedType.GetMethod('GraphSHA256').Invoke($null, @()) -cne
    [string]$modelContract.GraphSHA256) {
    throw 'The downstream model assembly graph identity differs.'
}

[pscustomobject]@{
    Path = $target
    Assembly = $loaded.GetName().Name
    Bytes = $assemblyBytes.Length
    SHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($assemblyBytes))
    TensorCount = 548
    VoiceResource = [string]$voiceNames[0]
    GraphSHA256 = [string]$modelContract.GraphSHA256
    SynthesisReady = $false
    WindowsLoad = $true
}
