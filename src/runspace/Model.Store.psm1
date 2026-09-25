param(
    [Parameter(Mandatory)][string]$PrivateRoot,
    [Parameter(Mandatory)][string]$TrustedPublicKeyPem,
    [Parameter(Mandatory)][string]$RuntimeAbi,
    [Parameter(Mandatory)][int]$ModelContractVersion,
    [long]$MaximumAssemblyBytes = 536870912
)

# Transactional private-storage model installer. The caller supplies
# ANativeActivity.internalDataPath (or a test root); this module never chooses a
# shared/external-storage location and never loads an assembly during admission.
$root = [IO.Path]::GetFullPath($PrivateRoot)
if (-not [IO.Path]::IsPathFullyQualified($root)) { throw 'Private model root must be absolute.' }
if ($MaximumAssemblyBytes -lt 1048576 -or $MaximumAssemblyBytes -gt 1073741824) {
    throw 'Maximum assembly size is outside the admitted range.'
}
if ($RuntimeAbi -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw 'Runtime ABI identifier is invalid.' }
if ($ModelContractVersion -lt 1) { throw 'Model contract version must be positive.' }

$modelRoot = [IO.Path]::Combine($root, 'models')
$contentRoot = [IO.Path]::Combine($modelRoot, 'sha256')
$stagingRoot = [IO.Path]::Combine($modelRoot, 'staging')
$activePath = [IO.Path]::Combine($modelRoot, 'active.json')

$getFileSha256 = {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
    finally { $stream.Dispose() }
}.GetNewClosure()

$getRequiredString = {
    param([Text.Json.JsonElement]$Object, [string]$Name, [string]$Pattern, [int]$MaximumLength)
    $property = [Text.Json.JsonElement]::new()
    if (-not $Object.TryGetProperty($Name, [ref]$property) -or $property.ValueKind -ne [Text.Json.JsonValueKind]::String) {
        throw "Model manifest field '$Name' is missing or is not a string."
    }
    $value = $property.GetString()
    if ($null -eq $value -or $value.Length -gt $MaximumLength -or $value -notmatch $Pattern) {
        throw "Model manifest field '$Name' is invalid."
    }
    $value
}.GetNewClosure()

$readManifest = {
    param([Parameter(Mandatory)][string]$ManifestJson)
    if ([Text.Encoding]::UTF8.GetByteCount($ManifestJson) -gt 65536) { throw 'Model manifest exceeds 65536 bytes.' }
    $document = [Text.Json.JsonDocument]::Parse($ManifestJson)
    try {
        $top = $document.RootElement
        if ($top.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Model manifest root must be an object.' }
        $schema = $top.GetProperty('schema').GetInt32()
        if ($schema -ne 1) { throw "Unsupported model manifest schema $schema." }
        $signed = $top.GetProperty('signed')
        $signature = $top.GetProperty('signature')
        if ($signed.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
            $signature.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'Model manifest signed payload or signature is invalid.'
        }
        $algorithm = & $getRequiredString $signature 'algorithm' '^ECDSA_P256_SHA256$' 32
        $signatureText = & $getRequiredString $signature 'value' '^[A-Za-z0-9+/]+={0,2}$' 256
        try { $signatureBytes = [Convert]::FromBase64String($signatureText) }
        catch { throw 'Model manifest signature is not valid base64.' }
        if ($signatureBytes.Length -lt 64 -or $signatureBytes.Length -gt 80) {
            throw 'Model manifest signature length is invalid.'
        }

        $signedJson = $signed.GetRawText()
        $signedBytes = [Text.Encoding]::UTF8.GetBytes($signedJson)
        $ecdsa = [Security.Cryptography.ECDsa]::Create()
        try {
            $ecdsa.ImportFromPem($TrustedPublicKeyPem)
            if ($ecdsa.KeySize -ne 256 -or -not $ecdsa.VerifyData(
                    $signedBytes,
                    $signatureBytes,
                    [Security.Cryptography.HashAlgorithmName]::SHA256)) {
                throw 'Model manifest signature verification failed.'
            }
        }
        finally { $ecdsa.Dispose() }

        $assemblyBytesProperty = $signed.GetProperty('assemblyBytes')
        $assemblyBytes = $assemblyBytesProperty.GetInt64()
        if ($assemblyBytes -lt 1 -or $assemblyBytes -gt $MaximumAssemblyBytes) {
            throw 'Model assembly byte count is outside the admitted range.'
        }
        $contract = $signed.GetProperty('modelContractVersion').GetInt32()
        if ($contract -ne $ModelContractVersion) { throw 'Model contract version is incompatible.' }
        $abi = & $getRequiredString $signed 'runtimeAbi' '^[A-Za-z0-9._-]{1,64}$' 64
        if ($abi -cne $RuntimeAbi) { throw 'Model runtime ABI is incompatible.' }

        $expiresText = & $getRequiredString $signed 'expiresUtc' '^\d{4}-\d{2}-\d{2}T' 64
        $expires = [DateTimeOffset]::ParseExact(
            $expiresText,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        )
        if ($expires -le [DateTimeOffset]::UtcNow) { throw 'Model manifest has expired.' }

        [pscustomobject]@{
            Schema = $schema
            SignedJson = $signedJson
            ManifestJson = $ManifestJson
            ModelId = & $getRequiredString $signed 'modelId' '^[a-z0-9][a-z0-9._-]{0,127}$' 128
            Version = & $getRequiredString $signed 'version' '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$' 64
            AssemblyName = & $getRequiredString $signed 'assemblyName' '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' 128
            AssemblySha256 = (& $getRequiredString $signed 'assemblySha256' '^[A-Fa-f0-9]{64}$' 64).ToUpperInvariant()
            GraphSha256 = (& $getRequiredString $signed 'graphSha256' '^[A-Fa-f0-9]{64}$' 64).ToUpperInvariant()
            WeightSha256 = (& $getRequiredString $signed 'weightSha256' '^[A-Fa-f0-9]{64}$' 64).ToUpperInvariant()
            Uri = & $getRequiredString $signed 'uri' '^https://' 2048
            AssemblyBytes = $assemblyBytes
            RuntimeAbi = $abi
            ModelContractVersion = $contract
            ExpiresUtc = $expires
        }
    }
    finally { $document.Dispose() }
}.GetNewClosure()

$testManagedAssembly = {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExpectedName)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $reader = [Reflection.PortableExecutable.PEReader]::new($stream)
        try {
            if (-not $reader.HasMetadata) { throw 'Model payload is not a managed assembly.' }
            $metadata = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($reader)
            if (-not $metadata.IsAssembly) { throw 'Model payload metadata is not an assembly.' }
            $definition = $metadata.GetAssemblyDefinition()
            $name = $metadata.GetString($definition.Name)
            if ($name -cne $ExpectedName) { throw 'Model assembly identity does not match its manifest.' }
        }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}.GetNewClosure()

$writeAtomicText = {
    param([string]$Path, [string]$Text)
    $parent = [IO.Path]::GetDirectoryName($Path)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = [IO.Path]::Combine($parent, '.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}.GetNewClosure()

$installStream = {
    param(
        [Parameter(Mandatory)][string]$ManifestJson,
        [Parameter(Mandatory)][IO.Stream]$AssemblyStream
    )
    if (-not $AssemblyStream.CanRead) { throw 'Model assembly stream is not readable.' }
    $manifest = & $readManifest $ManifestJson
    [IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
    [IO.Directory]::CreateDirectory($contentRoot) | Out-Null
    $stagePath = [IO.Path]::Combine($stagingRoot, [Guid]::NewGuid().ToString('N') + '.dll.partial')
    try {
        $destination = [IO.File]::Open($stagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        [long]$written = 0
        try {
            $buffer = [byte[]]::new(1048576)
            while (($count = $AssemblyStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $written += $count
                if ($written -gt $manifest.AssemblyBytes -or $written -gt $MaximumAssemblyBytes) {
                    throw 'Model assembly exceeded its admitted byte count.'
                }
                $hash.AppendData($buffer, 0, $count)
                $destination.Write($buffer, 0, $count)
            }
            $destination.Flush($true)
            $actualHash = [Convert]::ToHexString($hash.GetHashAndReset())
        }
        finally { $hash.Dispose(); $destination.Dispose() }
        if ($written -ne $manifest.AssemblyBytes) { throw 'Model assembly byte count does not match its manifest.' }
        if ($actualHash -cne $manifest.AssemblySha256) { throw 'Model assembly hash does not match its manifest.' }
        & $testManagedAssembly $stagePath $manifest.AssemblyName

        $contentDirectory = [IO.Path]::Combine($contentRoot, $actualHash.ToLowerInvariant())
        [IO.Directory]::CreateDirectory($contentDirectory) | Out-Null
        $contentPath = [IO.Path]::Combine($contentDirectory, 'Kokoro-Hexagon.dll')
        if ([IO.File]::Exists($contentPath)) {
            $existing = & $getFileSha256 $contentPath
            if ($existing -cne $actualHash) { throw 'Content-addressed model path contains different bytes.' }
        }
        else { [IO.File]::Move($stagePath, $contentPath, $false) }
        & $writeAtomicText ([IO.Path]::Combine($contentDirectory, 'manifest.json')) $ManifestJson

        $active = [ordered]@{
            schema = 1
            modelId = $manifest.ModelId
            version = $manifest.Version
            assemblySha256 = $actualHash
            relativePath = 'sha256/' + $actualHash.ToLowerInvariant() + '/Kokoro-Hexagon.dll'
            activatedUtc = [DateTimeOffset]::UtcNow.ToString('O')
        } | ConvertTo-Json -Compress
        & $writeAtomicText $activePath $active
        [pscustomobject]@{
            ModelId = $manifest.ModelId
            Version = $manifest.Version
            AssemblySha256 = $actualHash
            AssemblyPath = $contentPath
            ActivePointer = $activePath
        }
    }
    finally { if ([IO.File]::Exists($stagePath)) { [IO.File]::Delete($stagePath) } }
}.GetNewClosure()

$installFile = {
    param([string]$ManifestJson, [string]$AssemblyPath)
    $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($AssemblyPath))
    try { & $installStream $ManifestJson $stream }
    finally { $stream.Dispose() }
}.GetNewClosure()

$download = {
    param([string]$ManifestJson, [TimeSpan]$Timeout = [TimeSpan]::FromMinutes(10))
    $manifest = & $readManifest $ManifestJson
    $uri = [Uri]$manifest.Uri
    if ($uri.Scheme -cne 'https' -or -not $uri.IsAbsoluteUri -or $uri.UserInfo) {
        throw 'Model URI must be an absolute HTTPS URI without user information.'
    }
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = $Timeout
    try {
        $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            $response.EnsureSuccessStatusCode() | Out-Null
            if ($response.Content.Headers.ContentLength.HasValue -and
                $response.Content.Headers.ContentLength.Value -ne $manifest.AssemblyBytes) {
                throw 'Model response length does not match its manifest.'
            }
            $stream = $response.Content.ReadAsStream()
            try { & $installStream $ManifestJson $stream }
            finally { $stream.Dispose() }
        }
        finally { $response.Dispose() }
    }
    finally { $client.Dispose(); $handler.Dispose() }
}.GetNewClosure()

$getActive = {
    if (-not [IO.File]::Exists($activePath)) { return $null }
    $text = [IO.File]::ReadAllText($activePath)
    $active = $text | ConvertFrom-Json
    if ($active.schema -ne 1 -or $active.assemblySha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $active.relativePath -notmatch '^sha256/[a-f0-9]{64}/Kokoro-Hexagon\.dll$') {
        throw 'Active model pointer is invalid.'
    }
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($modelRoot, $active.relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $path.StartsWith($contentRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Active model pointer escapes private storage.'
    }
    if (-not [IO.File]::Exists($path)) { throw 'Active model payload is missing.' }
    $actual = & $getFileSha256 $path
    if ($actual -cne ([string]$active.assemblySha256).ToUpperInvariant()) { throw 'Active model payload hash is invalid.' }
    [pscustomobject]@{ ModelId = $active.modelId; Version = $active.version; AssemblySha256 = $actual; AssemblyPath = $path }
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName = 'Kokoro.Model.Store'
    PrivateRoot = $root
    InstallStream = $installStream
    InstallFile = $installFile
    Download = $download
    GetActive = $getActive
}
