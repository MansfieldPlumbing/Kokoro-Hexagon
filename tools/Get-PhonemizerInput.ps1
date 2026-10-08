# Fetch the pinned PSLowering compiler source into the ignored build tree for phonemizer/Invoke-EnglishPhonemizer.ps1.
# Each file is checked against its git blob id at the pinned commit before it is written.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$manifest = [IO.File]::ReadAllText([IO.Path]::Combine($root, 'lib', 'manifest.json'),
    [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
$pin = $manifest.psLowering
if ([string]$pin.commit -cnotmatch '^[0-9a-f]{40}$' -or
    [string]$pin.repo -cne 'https://github.com/MansfieldPlumbing/PSLowering') {
    throw 'The PSLowering source identity is not admitted.'
}
$commit = [string]$pin.commit
$target = [IO.Path]::Combine($root, 'build', 'phonemizer', 'inputs', "pslowering-$commit")
$rows = [Collections.Generic.List[string]]::new()
$rows.Add("Path`tCommit`tSha256")
$sha1 = [Security.Cryptography.SHA1]::Create()
foreach ($file in $pin.files) {
    $relative = [string]$file.path
    if ($relative -cnotmatch '^src/[A-Za-z0-9._/-]+$' -or $relative.Split('/') -contains '..') { throw "Invalid pinned path '$relative'." }
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($target, $relative))
    if (-not $path.StartsWith($target + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes the input directory.' }
    $bytes = if ([IO.File]::Exists($path)) { [IO.File]::ReadAllBytes($path) } else {
        $response = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/MansfieldPlumbing/PSLowering/$commit/$relative" -UseBasicParsing
        $response.RawContentStream.ToArray()
    }
    if ($bytes.Length -ne [long]$file.bytes) { throw "Length mismatch for $relative." }
    # git blob id: SHA-1 over "blob <length>\0" followed by the content.
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $blob = [Convert]::ToHexString($sha1.ComputeHash([byte[]]($header + $bytes))).ToLowerInvariant()
    if ($blob -cne [string]$file.blob) { throw "Blob id mismatch for $relative." }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    if (-not [IO.File]::Exists($path)) { [IO.File]::WriteAllBytes($path, $bytes) }
    $rows.Add("$relative`t$commit`t$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)))")
}
[IO.File]::WriteAllLines([IO.Path]::Combine($target, 'verified-source.tsv'), $rows.ToArray(), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ Directory = $target; Commit = $commit; Files = $pin.files.Count }
