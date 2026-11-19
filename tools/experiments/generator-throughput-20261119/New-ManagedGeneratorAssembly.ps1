#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EmissionDirectory,
    [Parameter(Mandatory)][string]$FixtureDirectory,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$files = [ordered]@{
    Program = Join-Path $EmissionDirectory 'libkokoro_generator_tail_skel.so'
    Weights = Join-Path $FixtureDirectory 'weights.bin'
    Tables = Join-Path $FixtureDirectory 'tables.bin'
    Layout = Join-Path $EmissionDirectory 'runner-layout.json'
}
# Follow PSC's persisted IL pipeline, adding manifest resources at PE serialization.
$assembly = [Reflection.Emit.PersistedAssemblyBuilder]::new([Reflection.AssemblyName]::new('Kokoroku'), [object].Assembly)
$module = $assembly.DefineDynamicModule('Kokoroku.dll')
$model = $module.DefineType('Kokoroku.Generator', 'Public, Abstract, Sealed')
$getAssembly = [Reflection.Assembly].GetMethod('GetExecutingAssembly')
$getStream = [Reflection.Assembly].GetMethod('GetManifestResourceStream', [type[]]@([string]))
foreach ($name in $files.Keys) {
    $method = $model.DefineMethod("Open$name", 'Public, Static', [IO.Stream], [type[]]@())
    $il = $method.GetILGenerator()
    $il.Emit([Reflection.Emit.OpCodes]::Call, $getAssembly)
    $il.Emit([Reflection.Emit.OpCodes]::Ldstr, "Kokoroku.$name")
    $il.Emit([Reflection.Emit.OpCodes]::Callvirt, $getStream)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
}
$null = $model.CreateType()
$instructions = $fieldData = $null
$metadata = $assembly.GenerateMetadata([ref]$instructions, [ref]$fieldData)
$resources = [Reflection.Metadata.BlobBuilder]::new()
foreach ($name in $files.Keys) {
    $resources.Align(8)
    $offset = $resources.Count
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $files[$name]).Path)
    $resources.WriteUInt32($bytes.Length)
    $resources.WriteBytes($bytes)
    $null = $metadata.AddManifestResource('Public', $metadata.GetOrAddString("Kokoroku.$name"), [Reflection.Metadata.EntityHandle]::new(), $offset)
}
$pe = [Reflection.PortableExecutable.ManagedPEBuilder]::new(
    [Reflection.PortableExecutable.PEHeaderBuilder]::CreateLibraryHeader(),
    [Reflection.Metadata.Ecma335.MetadataRootBuilder]::new($metadata),
    $instructions, $fieldData, $resources)
$image = [Reflection.Metadata.BlobBuilder]::new()
$null = $pe.Serialize($image)
$path = [IO.Path]::GetFullPath($OutputPath)
$temp = "$path.$([guid]::NewGuid()).tmp"
try {
    $output = [IO.File]::Open($temp, 'CreateNew', 'Write', 'None')
    try { $image.WriteContentTo($output) } finally { $output.Dispose() }
    $context = [Runtime.Loader.AssemblyLoadContext]::new('KokorokuVerification', $true)
    try {
        $inputStream = [IO.File]::OpenRead($temp)
        try { $loaded = $context.LoadFromStream($inputStream) } finally { $inputStream.Dispose() }
        $api = $loaded.GetType('Kokoroku.Generator', $true)
        foreach ($name in $files.Keys) {
            $stream = $api.GetMethod("Open$name").Invoke($null, $null)
            try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) } finally { $stream.Dispose() }
            if ($hash -cne (Get-FileHash -LiteralPath $files[$name]).Hash) { throw "$name verification failed." }
        }
    } finally { $context.Unload() }
    [IO.File]::Move($temp, $path)
} finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
Get-FileHash -LiteralPath $path
