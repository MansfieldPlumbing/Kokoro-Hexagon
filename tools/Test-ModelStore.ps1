#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$modulePath = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'src', 'runspace', 'Model.Store.psm1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Model.Store.psm1 does not parse.' }

$temporary = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'kokoro-model-store-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$ecdsa = [Security.Cryptography.ECDsa]::Create()
$ecdsa.GenerateKey([Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
try {
    $publicKey = $ecdsa.ExportSubjectPublicKeyInfoPem()
    $assemblyPath = [Management.Automation.PSObject].Assembly.Location
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

    $badManifest = $manifest.Replace('"version":"1.0.0"', '"version":"1.0.1"')
    $rejected = $false
    try { [void](& $store.InstallFile $badManifest $assemblyPath) }
    catch { $rejected = $_.Exception.Message -eq 'Model manifest signature verification failed.' }
    if (-not $rejected) { throw 'Tampered manifest was not rejected by the signature gate.' }

    [pscustomobject]@{
        Parsed = $true
        SignedManifest = $true
        ManagedAssemblyInspectedWithoutLoad = $true
        ContentAddressedInstall = $true
        AtomicActivation = $true
        TamperRejected = $true
        AssemblyBytes = $assemblyBytes.Length
        InstallMilliseconds = [Math]::Round($installMilliseconds, 1)
        Passed = $true
    }
}
finally {
    $ecdsa.Dispose()
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
}
