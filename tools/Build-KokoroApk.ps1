#requires -Version 7.4
# Downstream packaging only. Build the pinned Pwsh substrate unchanged first.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseApk,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$BaseSHA256,
    [Parameter(Mandatory)][string]$SetupPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$Debuggable,
    [switch]$DiagnosticVendorRpc
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($DiagnosticVendorRpc -and -not $Debuggable) { throw 'Vendor RPC declaration is restricted to the development diagnostic variant.' }
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output=[IO.Path]::GetFullPath($OutputDirectory)
$buildRoot=[IO.Path]::GetFullPath((Join-Path $repo 'build'))+[IO.Path]::DirectorySeparatorChar
if (-not $output.StartsWith($buildRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'APK output must be inside this repository build directory.' }
$apkPath=Join-Path $output 'Kokoro-Hexagon.apk'
if (Test-Path -LiteralPath $apkPath) { throw 'Select a fresh output directory; an existing APK is not overwritten.' }
if ((Get-Item -LiteralPath $BaseApk).Length -gt 40MB -or (Get-FileHash -LiteralPath $BaseApk).Hash -ine $BaseSHA256) { throw 'Base APK admission failed.' }
$names=@('Write-ByteSpan','New-BinaryAxmlManifest','Get-ResourceChunkConstants',
    'Test-ResChunkHeader','Test-BinaryAxml','New-ResourceTable','New-ResStringPool',
    'Get-Crc32Table','Get-Crc32','Get-DeflatedBytes','New-ApkArchive',
    'Get-LengthPrefixed','Get-ApkContentDigest','New-SignedApk','Test-SignedApk')
$import=& (Join-Path $repo 'src/build/Import-PwshBuildFunction.ps1') -SetupPath $SetupPath -FunctionName $names
foreach ($definition in $import.Definitions) { . $definition }
$script:ResourceChunkConstants=$null; $script:Crc32Table=$null
function Import-LibSourceText {
    param([string]$Path)
    if ($Path -cne 'ResourceTypes.h') { throw 'Source admission is restricted to ResourceTypes.h.' }
    $header=Join-Path (Split-Path $SetupPath) 'lib/ResourceTypes.h'
    if ((Get-FileHash -LiteralPath $header).Hash -cne 'BFF710AC90F3FCAA9FADC695C7E683C75E0442D8818ADB4AAED9D8B1CC69F4E1') { throw 'ResourceTypes.h integrity failure.' }
    [IO.File]::ReadAllText($header)
}
function Read-KokoroZipEntry {
    param([IO.Compression.ZipArchiveEntry]$Entry)
    if ($Entry.Length -gt 80MB) { throw 'ZIP entry exceeds the substrate bound.' }
    $stream=$Entry.Open(); $memory=[IO.MemoryStream]::new()
    try { $stream.CopyTo($memory); if ($memory.Length -ne $Entry.Length) { throw 'ZIP length mismatch.' }; return ,$memory.ToArray() }
    finally { $stream.Dispose(); $memory.Dispose() }
}
function Set-KokoroManifestPolicy {
    param([byte[]]$Document)
    # Typed AXML data transformation, not an upstream function/AST modification.
    # Field offsets follow pinned AOSP ResourceTypes.h and Test-BinaryAxml.
    $report=Test-BinaryAxml -Document $Document
    $strings=$report.Strings; $result=[IO.MemoryStream]::new()
    $internetSeen=$false; $backupSet=$false; $skipEnd=$false
    try {
        $result.Write($Document,0,8)
        for ($cursor=8; $cursor -lt $Document.Length;) {
            $chunk=Test-ResChunkHeader -Data $Document -At $cursor -MinimumHeaderSize 8 -End $Document.Length
            $type=[BitConverter]::ToUInt16($Document,$cursor); $omit=$false
            if ($skipEnd) {
                if ($type -ne 0x0103 -or $strings[[BitConverter]::ToInt32($Document,$cursor+20)] -cne 'uses-permission') { throw 'Only leaf permission nodes may be removed.' }
                $omit=$true; $skipEnd=$false
            } elseif ($type -eq 0x0102) {
                $ext=$cursor+16; $name=$strings[[BitConverter]::ToInt32($Document,$ext+4)]
                $start=[BitConverter]::ToUInt16($Document,$ext+8)
                $size=[BitConverter]::ToUInt16($Document,$ext+10)
                $count=[BitConverter]::ToUInt16($Document,$ext+12)
                if ($size -ne 20 -or $start+$size*$count -gt $chunk.Size-16) { throw 'Unsupported attribute layout.' }
                for ($i=0; $i -lt $count; $i++) {
                    $at=$ext+$start+$i*$size; $attribute=$strings[[BitConverter]::ToInt32($Document,$at+4)]
                    if ($name -ceq 'uses-permission' -and $attribute -ceq 'name') {
                        $raw=[BitConverter]::ToInt32($Document,$at+8)
                        if ($raw -lt 0) { throw 'Permission must be an admitted string.' }
                        if ($strings[$raw] -ceq 'android.permission.INTERNET' -and -not $internetSeen) { $internetSeen=$true }
                        else { $omit=$true; $skipEnd=$true }
                    }
                    if ($name -ceq 'application' -and $attribute -ceq 'allowBackup') {
                        if ($Document[$at+15] -ne 0x12 -or [BitConverter]::ToInt32($Document,$at+8) -ne -1) { throw 'Backup policy must be a typed boolean.' }
                        [Array]::Copy([BitConverter]::GetBytes([uint32]0),0,$Document,$at+16,4); $backupSet=$true
                    }
                }
            }
            if (-not $omit) { $result.Write($Document,$cursor,$chunk.Size) }
            $cursor+=$chunk.Size
        }
        if ($skipEnd -or -not $internetSeen -or -not $backupSet) { throw 'Manifest policy transformation incomplete.' }
        $bytes=$result.ToArray(); [Array]::Copy([BitConverter]::GetBytes([uint32]$bytes.Length),0,$bytes,4,4)
        return ,$bytes
    } finally { $result.Dispose() }
}
function Add-KokoroDiagnosticNativeLibrary {
    param([byte[]]$Document)
    # Android uses-native-library (API 31+) requests a device-published library;
    # it neither packages that client nor changes SELinux/linker policy.
    # AXML node/attribute offsets: admitted ResourceTypes.h and upstream writer.
    $parsed=Test-BinaryAxml -Document $Document
    [string[]]$strings=@($parsed.Strings)+@('uses-native-library','libcdsprpc.so')
    $elementIndex=$strings.Length-2; $libraryIndex=$strings.Length-1
    $androidIndex=[Array]::IndexOf($strings,'http://schemas.android.com/apk/res/android')
    $nameIndex=[Array]::IndexOf($strings,'name'); $requiredIndex=[Array]::IndexOf($strings,'required')
    if ($androidIndex -lt 0 -or $nameIndex -lt 0 -or $requiredIndex -lt 0) { throw 'Manifest attribute identities unavailable.' }
    $node=[IO.MemoryStream]::new(); $writer=[IO.BinaryWriter]::new($node)
    try {
        $writer.Write([uint16]0x0102); $writer.Write([uint16]16); $writer.Write([uint32]76)
        $writer.Write([uint32]1); $writer.Write([uint32]::MaxValue)
        $writer.Write([uint32]::MaxValue); $writer.Write([uint32]$elementIndex)
        $writer.Write([uint16]20); $writer.Write([uint16]20); $writer.Write([uint16]2)
        $writer.Write([uint16]0); $writer.Write([uint16]0); $writer.Write([uint16]0)
        foreach ($attribute in @(@($nameIndex,$libraryIndex,3,$libraryIndex),@($requiredIndex,-1,0x12,0))) {
            $writer.Write([uint32]$androidIndex); $writer.Write([uint32]$attribute[0]); $writer.Write([int]$attribute[1])
            $writer.Write([uint16]8); $writer.Write([byte]0); $writer.Write([byte]$attribute[2]); $writer.Write([uint32]$attribute[3])
        }
        $writer.Write([uint16]0x0103); $writer.Write([uint16]16); $writer.Write([uint32]24)
        $writer.Write([uint32]1); $writer.Write([uint32]::MaxValue)
        $writer.Write([uint32]::MaxValue); $writer.Write([uint32]$elementIndex); $writer.Flush()
        $addition=$node.ToArray()
    } finally { $writer.Dispose(); $node.Dispose() }
    $pool=New-ResStringPool -Strings $strings; $result=[IO.MemoryStream]::new(); $inserted=$false; $poolReplaced=$false
    try {
        $result.Write($Document,0,8)
        for ($cursor=8; $cursor -lt $Document.Length;) {
            $chunk=Test-ResChunkHeader -Data $Document -At $cursor -MinimumHeaderSize 8 -End $Document.Length
            $type=[BitConverter]::ToUInt16($Document,$cursor)
            if ($type -eq 1) {
                if ($poolReplaced) { throw 'Duplicate manifest string pool.' }
                $result.Write($pool,0,$pool.Length); $poolReplaced=$true
            } else {
                if ($type -eq 0x0103 -and $parsed.Strings[[BitConverter]::ToInt32($Document,$cursor+20)] -ceq 'application') {
                    if ($inserted) { throw 'Duplicate application node.' }
                    $result.Write($addition,0,$addition.Length); $inserted=$true
                }
                $result.Write($Document,$cursor,$chunk.Size)
            }
            $cursor+=$chunk.Size
        }
        if (-not $inserted -or -not $poolReplaced) { throw 'Diagnostic library declaration incomplete.' }
        $bytes=$result.ToArray(); [Array]::Copy([BitConverter]::GetBytes([uint32]$bytes.Length),0,$bytes,4,4)
        return ,$bytes
    } finally { $result.Dispose() }
}
$package='dev.mansfieldplumbing.kokoro'
$manifest=Set-KokoroManifestPolicy (New-BinaryAxmlManifest -PackageName $package -ActivityClassName 'android.app.NativeActivity' -ActivityLabel 'Kokoro-Hexagon' -VersionCode 1 -VersionName '0.1-development' -TargetSdkVersion 36 -CompileSdkVersion 36 -CompileSdkVersionCodename '16')
if ($DiagnosticVendorRpc) { $manifest=Add-KokoroDiagnosticNativeLibrary $manifest }
$parsed=Test-BinaryAxml -Document $manifest
$declared=@($parsed.Elements | Where-Object Name -CEQ 'uses-native-library')
if ($declared.Count -ne [int][bool]$DiagnosticVendorRpc -or ($DiagnosticVendorRpc -and
    ($declared[0].Attributes.name -cne 'libcdsprpc.so' -or $declared[0].Attributes.required -ne 0 -or $declared[0].Depth -ne 3))) { throw 'Diagnostic library declaration readback failed.' }
$permissions=@($parsed.Elements | Where-Object Name -CEQ 'uses-permission')
$application=@($parsed.Elements | Where-Object Name -CEQ 'application')
$activity=@($parsed.Elements | Where-Object Name -CEQ 'activity')
if ($permissions.Count -ne 1 -or $permissions[0].Attributes.name -cne 'android.permission.INTERNET' -or
    $application.Count -ne 1 -or $application[0].Attributes.allowBackup -ne 0 -or
    $activity.Count -ne 1 -or $activity[0].Attributes.name -cne 'android.app.NativeActivity' -or
    @($parsed.Elements | Where-Object Name -CEQ 'manifest')[0].Attributes.package -cne $package) { throw 'Manifest readback failed.' }
$debugExpected=if ($Debuggable) { [uint32]::MaxValue } else { [uint32]0 }
if ($application[0].Attributes.debuggable -ne $debugExpected) { throw 'Debug policy readback failed.' }
$entries=[Collections.Generic.List[object]]::new()
$nativeNames=@('libpwsh-host.so','libassembly-store.so','libpsl-native.so','libcoreclr.so','libclrjit.so',
    'libSystem.Native.so','libSystem.Globalization.Native.so','libSystem.IO.Compression.Native.so','libSystem.Security.Cryptography.Native.Android.so')
$allowed=@('AndroidManifest.xml','resources.arsc','res/mipmap-anydpi-v26/ic_launcher.xml','res/mipmap-nodpi-v4/ic_launcher_foreground.png')+@($nativeNames | ForEach-Object { "lib/arm64-v8a/$_" })
$nativeHashes=[ordered]@{}
$archive=[IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($BaseApk))
try {
    if ($archive.Entries.Count -ne $allowed.Count) { throw 'Unexpected base APK closure.' }
    foreach ($entry in $archive.Entries) {
        if ($entry.FullName -cnotin $allowed -or @($entries | Where-Object Name -CEQ $entry.FullName).Count) { throw 'Unadmitted or duplicate APK entry.' }
        $bytes=Read-KokoroZipEntry $entry
        switch -Exact ($entry.FullName) {
            'AndroidManifest.xml' { $bytes=$manifest }
            'resources.arsc' { $bytes=New-ResourceTable -PackageName $package -IconPath 'res/mipmap-anydpi-v26/ic_launcher.xml' -ForegroundPath 'res/mipmap-nodpi-v4/ic_launcher_foreground.png' -BackgroundColor ([uint32]4278926638) }
            'res/mipmap-nodpi-v4/ic_launcher_foreground.png' { $bytes=[IO.File]::ReadAllBytes((Join-Path $repo 'assets/branding/kokoro-hexagon-icon.png')) }
        }
        if ($entry.FullName.StartsWith('lib/')) { $nativeHashes[$entry.FullName]=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
        $stored=$entry.FullName -cin @('resources.arsc','res/mipmap-nodpi-v4/ic_launcher_foreground.png')
        $entries.Add([pscustomobject]@{Name=$entry.FullName;Bytes=$bytes;Stored=$stored;Alignment=$(if ($stored) {4} else {0})})
    }
} finally { $archive.Dispose() }
Write-Progress -Activity 'Compose Kokoro APK' -Status 'Building aligned archive with unchanged upstream ZIP writer'
$unsigned=New-ApkArchive -Entries $entries
$keyDirectory=Join-Path $env:LOCALAPPDATA 'Kokoro-Hexagon/Keys'
$keyPath=Join-Path $keyDirectory 'kokoro-development.pfx'
[void][IO.Directory]::CreateDirectory($keyDirectory)
$certificate=$null; $key=$null
try {
    if (Test-Path -LiteralPath $keyPath) {
        $certificate=[Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12([IO.File]::ReadAllBytes($keyPath),$null,[Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    } else {
        $key=[Security.Cryptography.RSA]::Create(2048)
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Kokoro-Hexagon Development, O=MansfieldPlumbing',$key,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1),[DateTimeOffset]::UtcNow.AddYears(30))
        $exported=$certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)
        try { $f=[IO.File]::Open($keyPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); try {$f.Write($exported,0,$exported.Length)} finally {$f.Dispose()} }
        finally { [Array]::Clear($exported,0,$exported.Length) }
    }
    $signature=New-SignedApk -Apk $unsigned -Certificate $certificate
    [byte[]]$signed=$signature.Bytes
    $null=Test-SignedApk -Apk $signed -Certificate $certificate
    if ($signed.Length -ge 40MB) { throw 'Model-less APK must be smaller than 40 MiB.' }
    $memory=[IO.MemoryStream]::new($signed,$false); $readback=[IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($entry in $readback.Entries) {
            $bytes=Read-KokoroZipEntry $entry
            $expected=@($entries | Where-Object Name -CEQ $entry.FullName)
            if ($expected.Count -ne 1 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expected[0].Bytes))) { throw 'APK payload readback failed.' }
        }
        if ($readback.Entries.Count -ne $entries.Count -or $nativeHashes.Count -ne 9) { throw 'APK closure readback failed.' }
    } finally { $readback.Dispose(); $memory.Dispose() }
    [void][IO.Directory]::CreateDirectory($output)
    [IO.File]::WriteAllBytes($apkPath,$signed)
    $receipt=[ordered]@{Schema=1;Package=$package;Label='Kokoro-Hexagon';Startup='Profile';Debuggable=[bool]$Debuggable;DiagnosticVendorRpc=[bool]$DiagnosticVendorRpc;
        BaseSHA256=$BaseSHA256.ToUpperInvariant();SetupSHA256=$import.SetupSHA256;APKBytes=$signed.Length;APKSHA256=(Get-FileHash $apkPath).Hash;
        Permissions=@('android.permission.INTERNET');AllowBackup=$false;NativePayloadsUnchanged=$nativeHashes;
        SignatureV2Verified=$true;ArchiveReadbackVerified=$true;ModelWeightsIncluded=$false;SpeechSynthesisVerified=$false}
    [IO.File]::WriteAllText((Join-Path $output 'package-receipt.json'),($receipt | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    [pscustomobject]$receipt
} finally { if ($certificate) {$certificate.Dispose()}; if ($key) {$key.Dispose()}; Write-Progress -Activity 'Compose Kokoro APK' -Completed }
