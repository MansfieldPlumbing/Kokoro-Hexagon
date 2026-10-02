# Admit the real downstream engine DLL through the signed model store on Windows.
#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AssemblyPath,
    [switch] $Child,
    [string] $PrivateRoot,
    [string] $PublicKeyPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$modulePath = [IO.Path]::Combine($root, 'src', 'runspace', 'Model.Store.psm1')
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $modulePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Model.Store.psm1 does not parse.' }

if ($Child) {
    if ([string]::IsNullOrWhiteSpace($PrivateRoot) -or
        [string]::IsNullOrWhiteSpace($PublicKeyPath)) {
        throw 'Child admission requires private-root and public-key paths.'
    }
    $publicKey = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PublicKeyPath).Path)
    $store = $ast.GetScriptBlock().InvokeReturnAsIs(@(
        (Resolve-Path -LiteralPath $PrivateRoot).Path,
        $publicKey, 'test-win-x64', 1, 536870912))
    $active = & $store.LoadActive
    if ($null -eq $active -or
        $active.Assembly.GetName().Name -cne 'Dev.MansfieldPlumbing.Kokoro.Model') {
        throw 'The active downstream engine assembly identity differs.'
    }
    $type = $active.Assembly.GetType('Dev.MansfieldPlumbing.Kokoro.Model.Contract', $true)
    if ([bool]$type.GetMethod('SynthesisReady').Invoke($null, @()) -or
        $null -ne $type.GetMethod('SynthesizePhonemes')) {
        throw 'The admitted incomplete engine exposed synthesis.'
    }
    [pscustomobject]@{
        Loaded = $true
        Assembly = $active.Assembly.GetName().Name
        AssemblySHA256 = $active.AssemblySha256
        SynthesisReady = $false
    }
    exit 0
}

$resolvedAssembly = (Resolve-Path -LiteralPath $AssemblyPath).Path
$assemblyItem = Get-Item -LiteralPath $resolvedAssembly
$assemblyHash = (Get-FileHash -LiteralPath $resolvedAssembly -Algorithm SHA256).Hash
$assemblyName = [Reflection.AssemblyName]::GetAssemblyName($resolvedAssembly).Name
if ($assemblyName -cne 'Dev.MansfieldPlumbing.Kokoro.Model' -or
    $assemblyItem.Length -gt 536870912) {
    throw 'The downstream engine payload identity or size is not admitted.'
}
$assembly = [Reflection.Assembly]::LoadFrom($resolvedAssembly)
$contractType = $assembly.GetType('Dev.MansfieldPlumbing.Kokoro.Model.Contract', $true)
$graphHash = [string]$contractType.GetMethod('GraphSHA256').Invoke($null, @())

$testRoot = [IO.Path]::GetFullPath([IO.Path]::Combine(
    $root, 'build', 'test', 'engine-store-' + [Guid]::NewGuid().ToString('N')))
$admittedTestRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($root, 'build', 'test'))
if (-not $testRoot.StartsWith(
        $admittedTestRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The model-store test root escaped build/test.'
}
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$publicKeyPath = [IO.Path]::Combine($testRoot, 'model-public.pem')
$ecdsa = [Security.Cryptography.ECDsa]::Create()
$ecdsa.GenerateKey([Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256'))
try {
    $publicKey = $ecdsa.ExportSubjectPublicKeyInfoPem()
    [IO.File]::WriteAllText($publicKeyPath, $publicKey, [Text.UTF8Encoding]::new($false))
    $signed = [ordered]@{
        modelId = 'kokoro-v1.0-af-heart-fp32'
        version = '1.0.0'
        assemblyName = $assemblyName
        assemblySha256 = $assemblyHash
        assemblyBytes = $assemblyItem.Length
        graphSha256 = $graphHash
        weightSha256 = '496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4'
        modelContractVersion = 1
        runtimeAbi = 'test-win-x64'
        uri = 'https://example.invalid/Dev.MansfieldPlumbing.Kokoro.Model.dll'
        expiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('O')
    } | ConvertTo-Json -Compress
    [byte[]]$signedBytes = [Text.Encoding]::UTF8.GetBytes($signed)
    [byte[]]$signature = $ecdsa.SignData(
        $signedBytes, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $manifest = '{"schema":1,"signed":' + $signed +
        ',"signature":{"algorithm":"ECDSA_P256_SHA256","value":"' +
        [Convert]::ToBase64String($signature) + '"}}'

    $store = $ast.GetScriptBlock().InvokeReturnAsIs(@(
        $testRoot, $publicKey, 'test-win-x64', 1, 536870912))
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $installed = & $store.InstallFile $manifest $resolvedAssembly
    $clock.Stop()
    if ($installed.AssemblySha256 -cne $assemblyHash) {
        throw 'The installed downstream engine identity differs.'
    }

    & pwsh -NoProfile -File $PSCommandPath -Child `
        -AssemblyPath $resolvedAssembly -PrivateRoot $testRoot `
        -PublicKeyPath $publicKeyPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Fresh-process downstream engine load failed.' }

    [pscustomobject]@{
        Passed = $true
        Assembly = $assemblyName
        Bytes = $assemblyItem.Length
        SHA256 = $assemblyHash
        SignedManifest = $true
        ContentAddressedInstall = $true
        AtomicActivation = $true
        FreshProcessLoad = $true
        SynthesisReady = $false
        InstallMilliseconds = [Math]::Round($clock.Elapsed.TotalMilliseconds, 1)
    }
}
finally {
    $ecdsa.Dispose()
    if ([IO.Directory]::Exists($testRoot)) {
        [IO.Directory]::Delete($testRoot, $true)
    }
}
