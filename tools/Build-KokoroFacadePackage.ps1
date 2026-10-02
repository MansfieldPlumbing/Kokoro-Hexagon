#requires -Version 7.4
# Stage the pinned display binding, Kokoro facade, profile, and full-size icon.
[CmdletBinding()]
param(
    [string] $OutputDirectory = [IO.Path]::Combine(
        $PSScriptRoot, '..', 'build', 'facade-package-session')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$buildRoot = [IO.Path]::Combine($root, 'build')
$target = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $target.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Facade package output must remain under the repository build directory.'
}
if ([IO.Directory]::Exists($target)) { throw "Facade package output already exists: $target" }

$upstream = & ([IO.Path]::Combine($PSScriptRoot, 'Get-PwshUpstream.ps1'))
$canvas = @($upstream.Files | Where-Object Path -ceq 'modules/AndroidCanvas.psm1')
if ($canvas.Count -ne 1) { throw 'The pinned AndroidCanvas binding receipt is not unique.' }
$inputs = [ordered]@{
    'Profile.ps1' = [IO.Path]::Combine($root, 'src', 'appliance', 'Start-KokoroFacade.ps1')
    'modules/AndroidCanvas.psm1' = $canvas[0].LocalPath
    'modules/Kokoro.Facade.psm1' = [IO.Path]::Combine($root, 'src', 'appliance', 'Kokoro.Facade.psm1')
    'modules/Kokoro.SpeechSession.psm1' = [IO.Path]::Combine($root, 'src', 'control', 'Kokoro.SpeechSession.psm1')
    'res/mipmap/ic_launcher.png' = [IO.Path]::Combine($root, 'assets', 'branding', 'kokoro-hexagon-icon.png')
}
[IO.Directory]::CreateDirectory($target) | Out-Null
$receipts = foreach ($entry in $inputs.GetEnumerator()) {
    $source = (Resolve-Path -LiteralPath $entry.Value).Path
    $destination = [IO.Path]::Combine($target, $entry.Key.Replace('/', [IO.Path]::DirectorySeparatorChar))
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    [IO.File]::Copy($source, $destination, $false)
    $bytes = [IO.File]::ReadAllBytes($destination)
    [pscustomobject][ordered]@{
        path = $entry.Key
        bytes = $bytes.LongLength
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    }
}
$manifest = [ordered]@{
    schema = 1
    pwsh_commit = $upstream.Commit
    role = 'Kokoro phone facade staging package; not an APK or speech build'
    files = @($receipts)
} | ConvertTo-Json -Depth 5
$manifestPath = [IO.Path]::Combine($target, 'facade-manifest.json')
[IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Path = $target
    PwshCommit = $upstream.Commit
    Files = @($receipts)
    ManifestPath = $manifestPath
    Passed = $true
}
