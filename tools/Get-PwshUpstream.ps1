# Fetch and verify the immutable Xamarin-independent Pwsh base into build/.
[CmdletBinding()]
param(
    [string] $OutputDirectory = [IO.Path]::Combine(
        $PSScriptRoot, '..', 'build', 'upstream', 'pwsh'),
    [switch] $Offline
)

Set-StrictMode -Version Latest
$repositoryRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$buildRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($repositoryRoot, 'build'))
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outputRoot.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Pwsh upstream output must remain under this repository build directory.'
}

$manifestPath = [IO.Path]::Combine($repositoryRoot, 'lib', 'manifest.json')
$manifest = [IO.File]::ReadAllText($manifestPath, [Text.UTF8Encoding]::new($false, $true)) |
    ConvertFrom-Json
$pin = $manifest.pwshUpstream
if ($null -eq $pin -or [string]$pin.commit -notmatch '^[0-9a-f]{40}$') {
    throw 'lib/manifest.json does not contain a full Pwsh upstream commit pin.'
}
if ([string]$pin.repo -cne 'https://github.com/MansfieldPlumbing/Pwsh') {
    throw 'The Pwsh upstream repository identity is not admitted.'
}

$commitRoot = [IO.Path]::Combine($outputRoot, [string]$pin.commit)
[IO.Directory]::CreateDirectory($commitRoot) | Out-Null
$client = if ($Offline) { $null } else { [Net.Http.HttpClient]::new() }
try {
    $receipts = foreach ($file in @($pin.files)) {
        $relative = [string]$file.path
        if ($relative -notmatch '^[A-Za-z0-9._/-]+$' -or
            $relative.StartsWith('/') -or $relative.Split('/') -contains '..') {
            throw "Invalid pinned Pwsh path '$relative'."
        }
        if ([string]$file.sha256 -notmatch '^[0-9A-F]{64}$' -or [long]$file.bytes -le 0) {
            throw "Invalid integrity metadata for Pwsh path '$relative'."
        }

        $target = [IO.Path]::Combine($commitRoot, $relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        $verified = $false
        if ([IO.File]::Exists($target)) {
            $existing = [IO.File]::ReadAllBytes($target)
            $existingHash = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($existing))
            $verified = $existing.LongLength -eq [long]$file.bytes -and
                $existingHash -ceq [string]$file.sha256
        }
        if (-not $verified) {
            if ($Offline) { throw "Pinned Pwsh file is absent or invalid in offline mode: $relative" }
            $url = 'https://raw.githubusercontent.com/MansfieldPlumbing/Pwsh/{0}/{1}' -f 
                [string]$pin.commit, $relative
            [byte[]] $bytes = $client.GetByteArrayAsync($url).GetAwaiter().GetResult()
            $hash = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($bytes))
            if ($bytes.LongLength -ne [long]$file.bytes -or $hash -cne [string]$file.sha256) {
                throw "Pinned Pwsh content failed integrity verification: $relative"
            }
            $temporary = $target + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            try {
                [IO.File]::WriteAllBytes($temporary, $bytes)
                [IO.File]::Move($temporary, $target, $true)
            }
            finally {
                if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
            }
        }
        [pscustomobject]@{
            Path = $relative
            Bytes = [long]$file.bytes
            SHA256 = [string]$file.sha256
            LocalPath = $target
        }
    }
}
finally {
    if ($null -ne $client) { $client.Dispose() }
}

[pscustomobject]@{
    PSTypeName = 'Kokoro.Build.PwshUpstreamReceipt'
    Repository = [string]$pin.repo
    Commit = [string]$pin.commit
    Files = @($receipts)
    Passed = $true
}
