#requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$Child,
    [string]$PrivateRoot,
    [string]$PublicKeyPath,
    [switch]$ExpectTamper
)
$ErrorActionPreference = 'Stop'
$modulePath = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'src', 'runspace', 'Model.Store.psm1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Model.Store.psm1 does not parse.' }
if ($Child) {
    $key = [IO.File]::ReadAllText($PublicKeyPath)
    $childStore = $ast.GetScriptBlock().InvokeReturnAsIs(@($PrivateRoot, $key, 'test-win-x64', 1, 536870912))
    if ($ExpectTamper) {
        try { [void](& $childStore.LoadActive) }
        catch {
            if ($_.Exception.Message -eq 'Model manifest signature verification failed.') { exit 0 }
            throw
        }
        throw 'Tampered active model manifest was not rejected before load.'
    }
    $childLoaded = & $childStore.LoadActive
    if ($null -eq $childLoaded -or
        [IO.Path]::GetFullPath($childLoaded.Assembly.Location) -cne
        [IO.Path]::GetFullPath([IO.Path]::Combine($PrivateRoot, 'models', 'sha256',
            $childLoaded.AssemblySha256.ToLowerInvariant(), 'Kokoro-Hexagon.dll'))) {
        throw 'Admitted model assembly did not load from its private-store payload.'
    }
    exit 0
}

$temporary = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'kokoro-model-store-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$ecdsa = [Security.Cryptography.ECDsa]::Create()
$ecdsa.GenerateKey([Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
try {
    $publicKey = $ecdsa.ExportSubjectPublicKeyInfoPem()
    $publicKeyPath = [IO.Path]::Combine($temporary, 'model-public.pem')
    [IO.File]::WriteAllText($publicKeyPath, $publicKey)
    $assemblyPath = [IO.Path]::Combine($temporary, 'Kokoro.Store.TestModel.dll')
    $builder = [Reflection.Emit.PersistedAssemblyBuilder]::new(
        [Reflection.AssemblyName]::new('Kokoro.Store.TestModel'), [object].Assembly)
    $module = $builder.DefineDynamicModule('Kokoro.Store.TestModel.dll')
    $type = $module.DefineType('Kokoro.Store.TestModel.Marker',
        [Reflection.TypeAttributes]'Public,Abstract,Sealed,BeforeFieldInit')
    [void]$type.CreateType()
    $il = $null; $fields = $null
    $metadata = $builder.GenerateMetadata([ref]$il, [ref]$fields)
    $pe = [Reflection.PortableExecutable.ManagedPEBuilder]::new(
        [Reflection.PortableExecutable.PEHeaderBuilder]::CreateLibraryHeader(),
        [Reflection.Metadata.Ecma335.MetadataRootBuilder]::new($metadata),
        $il, $fields, $null, $null, $null, 0,
        [Reflection.Metadata.MethodDefinitionHandle]::new(),
        [Reflection.PortableExecutable.CorFlags]::ILOnly, $null)
    $blob = [Reflection.Metadata.BlobBuilder]::new()
    [void]$pe.Serialize($blob)
    $file = [IO.File]::Open($assemblyPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $blob.WriteContentTo($file) } finally { $file.Dispose() }
    $assemblyBytes = [IO.File]::ReadAllBytes($assemblyPath)
    $assemblyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($assemblyBytes))
    $assemblyName = [Reflection.AssemblyName]::GetAssemblyName($assemblyPath).Name
    $signed = [ordered]@{
        modelId = 'kokoro-test'
        version = '1.0.0'
        assemblyName = $assemblyName
        assemblySha256 = $assemblyHash
        assemblyBytes = $assemblyBytes.Length
        graphSha256 = ('11' * 32)
        weightSha256 = ('22' * 32)
        modelContractVersion = 1
        runtimeAbi = 'test-win-x64'
        uri = 'https://example.invalid/Kokoro-Hexagon.dll'
        expiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('O')
    } | ConvertTo-Json -Compress
    $signature = $ecdsa.SignData([Text.Encoding]::UTF8.GetBytes($signed), [Security.Cryptography.HashAlgorithmName]::SHA256)
    $manifest = '{"schema":1,"signed":' + $signed + ',"signature":{"algorithm":"ECDSA_P256_SHA256","value":"' + [Convert]::ToBase64String($signature) + '"}}'
    $store = $ast.GetScriptBlock().InvokeReturnAsIs(@($temporary, $publicKey, 'test-win-x64', 1, 536870912))
    $installClock = [Diagnostics.Stopwatch]::StartNew()
    $installed = & $store.InstallFile $manifest $assemblyPath
    $installMilliseconds = $installClock.Elapsed.TotalMilliseconds
    $active = & $store.GetActive
    if ($active.AssemblySha256 -cne $assemblyHash -or $installed.AssemblySha256 -cne $assemblyHash) {
        throw 'Installed or active model identity is incorrect.'
    }
    & pwsh -NoProfile -File $PSCommandPath -Child -PrivateRoot $temporary -PublicKeyPath $publicKeyPath
    if ($LASTEXITCODE -ne 0) { throw 'Admitted model load failed in a fresh process.' }

    # A signed payload with a managed-native header is still inadmissible.
    [byte[]]$nativeHeaderBytes = $assemblyBytes.Clone()
    $nativeStream = [IO.MemoryStream]::new($nativeHeaderBytes, $false)
    $nativeReader = [Reflection.PortableExecutable.PEReader]::new($nativeStream)
    try { $nativeHeaderOffset = $nativeReader.PEHeaders.CorHeaderStartOffset + 68 }
    finally { $nativeReader.Dispose(); $nativeStream.Dispose() }
    [BitConverter]::GetBytes([int]1).CopyTo($nativeHeaderBytes, $nativeHeaderOffset)
    $nativePath = [IO.Path]::Combine($temporary, 'Kokoro.Store.NativeHeader.dll')
    [IO.File]::WriteAllBytes($nativePath, $nativeHeaderBytes)
    $nativeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($nativeHeaderBytes))
    $nativeSignedJson = $signed.Replace($assemblyHash, $nativeHash)
    if ($nativeSignedJson -ceq $signed) { throw 'Test payload hash substitution failed.' }
    $nativeSignature = $ecdsa.SignData([Text.Encoding]::UTF8.GetBytes($nativeSignedJson), [Security.Cryptography.HashAlgorithmName]::SHA256)
    $nativeManifest = '{"schema":1,"signed":' + $nativeSignedJson + ',"signature":{"algorithm":"ECDSA_P256_SHA256","value":"' + [Convert]::ToBase64String($nativeSignature) + '"}}'
    $nativeRejected = $false
    $nativeFailure = $null
    try { [void](& $store.InstallFile $nativeManifest $nativePath) }
    catch {
        $nativeFailure = $_.Exception.Message
        $nativeRejected = $nativeFailure -eq 'Model payload must be an IL-only managed assembly.'
    }
    if (-not $nativeRejected) { throw "Signed managed-native payload was not rejected. Actual result: $nativeFailure" }

    $badManifest = $manifest.Replace('"version":"1.0.0"', '"version":"1.0.1"')
    $rejected = $false
    try { [void](& $store.InstallFile $badManifest $assemblyPath) }
    catch { $rejected = $_.Exception.Message -eq 'Model manifest signature verification failed.' }
    if (-not $rejected) { throw 'Tampered manifest was not rejected by the signature gate.' }

    $storedManifest = [IO.Path]::Combine([IO.Path]::GetDirectoryName($active.AssemblyPath), 'manifest.json')
    [IO.File]::WriteAllText($storedManifest, $badManifest)
    & pwsh -NoProfile -File $PSCommandPath -Child -PrivateRoot $temporary -PublicKeyPath $publicKeyPath -ExpectTamper
    if ($LASTEXITCODE -ne 0) { throw 'Tampered active manifest was not rejected in a fresh process.' }

    [pscustomobject]@{
        Parsed = $true
        SignedManifest = $true
        ManagedAssemblyInspectedWithoutLoad = $true
        ContentAddressedInstall = $true
        AtomicActivation = $true
        TamperRejected = $true
        ActiveLoadVerified = $true
        ActiveManifestTamperRejected = $true
        ManagedNativePayloadRejected = $true
        AssemblyBytes = $assemblyBytes.Length
        InstallMilliseconds = [Math]::Round($installMilliseconds, 1)
        Passed = $true
    }
}
finally {
    $ecdsa.Dispose()
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
}
