# Fetch immutable Kokoro checkpoint/config/voice inputs into the ignored build tree.
[CmdletBinding()]
param(
    [string[]] $Include = @('config.json'),
    [string] $OutputDirectory = [IO.Path]::Combine(
        $PSScriptRoot, '..', 'build', 'inputs', 'kokoro'),
    [switch] $Offline
)

Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$buildRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($root, 'build'))
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outputRoot.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Kokoro model inputs must remain under this repository build directory.'
}

$manifest = [IO.File]::ReadAllText(
    [IO.Path]::Combine($root, 'lib', 'manifest.json'),
    [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
$model = $manifest.model
if ([string]$model.revision -notmatch '^[0-9a-f]{40}$' -or
    [string]$model.source -cne 'huggingface.co/hexgrad/Kokoro-82M') {
    throw 'The Kokoro model source identity is not admitted.'
}

$requested = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($entry in $Include) {
    $normalized = ([string]$entry).Replace('\', '/')
    if ($normalized -notmatch '^[A-Za-z0-9._/-]+$' -or
        $normalized.StartsWith('/') -or $normalized.Split('/') -contains '..' -or
        -not $requested.Add($normalized)) {
        throw "Invalid or duplicate Kokoro model input '$entry'."
    }
}
$pins = @($model.files | Where-Object { $requested.Contains(([string]$_.path).Replace('\', '/')) })
if ($pins.Count -ne $requested.Count) { throw 'One or more requested Kokoro model inputs are not pinned.' }

$revisionRoot = [IO.Path]::Combine($outputRoot, [string]$model.revision)
[IO.Directory]::CreateDirectory($revisionRoot) | Out-Null
$client = if ($Offline) { $null } else { [Net.Http.HttpClient]::new() }
try {
    $receipts = foreach ($pin in $pins) {
        $relative = ([string]$pin.path).Replace('\', '/')
        if ([string]$pin.sha256 -notmatch '^[0-9A-F]{64}$' -or [long]$pin.bytes -le 0) {
            throw "Invalid integrity metadata for Kokoro model input '$relative'."
        }
        $target = [IO.Path]::Combine(
            $revisionRoot, $relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        $verified = $false
        if ([IO.File]::Exists($target)) {
            $item = Get-Item -LiteralPath $target
            if ($item.Length -eq [long]$pin.bytes) {
                $verified = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ceq
                    [string]$pin.sha256
            }
        }
        if (-not $verified) {
            if ($Offline) { throw "Pinned Kokoro model input is absent or invalid: $relative" }
            $escapedPath = ($relative.Split('/') | ForEach-Object {
                [Uri]::EscapeDataString($_)
            }) -join '/'
            $url = 'https://huggingface.co/hexgrad/Kokoro-82M/resolve/{0}/{1}?download=true' -f
                [string]$model.revision, $escapedPath
            $temporary = $target + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            $response = $null
            $source = $null
            $destination = $null
            $hasher = [Security.Cryptography.IncrementalHash]::CreateHash(
                [Security.Cryptography.HashAlgorithmName]::SHA256)
            try {
                $response = $client.GetAsync(
                    $url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                [void]$response.EnsureSuccessStatusCode()
                $source = $response.Content.ReadAsStream()
                $destination = [IO.FileStream]::new(
                    $temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
                    [IO.FileShare]::None, 1048576,
                    [IO.FileOptions]::SequentialScan)
                [byte[]]$buffer = [byte[]]::new(1048576)
                [long]$length = 0
                while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $length += $read
                    if ($length -gt [long]$pin.bytes) {
                        throw "Kokoro model input exceeded its pinned length: $relative"
                    }
                    $hasher.AppendData($buffer, 0, $read)
                    $destination.Write($buffer, 0, $read)
                }
                $destination.Flush($true)
                $hash = [Convert]::ToHexString($hasher.GetHashAndReset())
                if ($length -ne [long]$pin.bytes -or $hash -cne [string]$pin.sha256) {
                    throw "Kokoro model input failed integrity verification: $relative"
                }
            }
            finally {
                if ($null -ne $destination) { $destination.Dispose() }
                if ($null -ne $source) { $source.Dispose() }
                if ($null -ne $response) { $response.Dispose() }
                $hasher.Dispose()
            }
            try { [IO.File]::Move($temporary, $target, $true) }
            finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        }
        [pscustomobject]@{
            Path = $relative
            Bytes = [long]$pin.bytes
            SHA256 = [string]$pin.sha256
            LocalPath = $target
        }
    }
}
finally {
    if ($null -ne $client) { $client.Dispose() }
}

[pscustomobject]@{
    PSTypeName = 'Kokoro.Build.ModelInputReceipt'
    Source = [string]$model.source
    Revision = [string]$model.revision
    Files = @($receipts)
    Passed = $true
}
