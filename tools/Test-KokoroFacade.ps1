#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $IconPath = [IO.Path]::Combine(
        $PSScriptRoot, '..', 'assets', 'branding', 'kokoro-hexagon-icon.png'),
    [string] $PackageDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$modulePath = [IO.Path]::Combine($root, 'src', 'appliance', 'Kokoro.Facade.psm1')
$profilePath = [IO.Path]::Combine($root, 'src', 'appliance', 'Start-KokoroFacade.ps1')
foreach ($path in @($modulePath, $profilePath)) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$path has PowerShell parse errors." }
}
Import-Module $modulePath -Force

$layout = Get-KokoroFacadeLayout -Width 1080 -Height 2340 -InsetTop 96 -InsetBottom 120
foreach ($name in @('Header', 'Status', 'Prompt', 'Action')) {
    $box = $layout.$name
    if ($box.Left -lt $layout.Content.Left -or $box.Top -lt $layout.Content.Top -or
        $box.Right -gt $layout.Content.Right -or $box.Bottom -gt $layout.Content.Bottom -or
        $box.Right -le $box.Left -or $box.Bottom -le $box.Top) {
        throw "$name escapes or collapses the safe content area."
    }
}
if (($layout.Action.Bottom - $layout.Action.Top) -lt 96 -or
    -not (Test-KokoroFacadeHit $layout.Action (($layout.Action.Left + $layout.Action.Right) / 2) (($layout.Action.Top + $layout.Action.Bottom) / 2)) -or
    (Test-KokoroFacadeHit $layout.Action -1 -1)) {
    throw 'The primary action hit target is invalid.'
}
$wrapped = @(Split-KokoroFacadeText -Text ('speech ' * 80) -MaximumCharacters 32)
if ($wrapped.Count -lt 2 -or @($wrapped | Where-Object Length -gt 32).Count -ne 0) {
    throw 'Facade text wrapping is not bounded.'
}

function Get-RelativeLuminance([int] $Red, [int] $Green, [int] $Blue) {
    $linear = foreach ($component in @($Red, $Green, $Blue)) {
        $value = $component / 255.0
        if ($value -le 0.04045) { $value / 12.92 } else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
    }
    0.2126*$linear[0] + 0.7152*$linear[1] + 0.0722*$linear[2]
}
$background = Get-RelativeLuminance 4 16 31
$text = Get-RelativeLuminance 245 250 255
$primary = Get-RelativeLuminance 94 246 255
$onPrimary = Get-RelativeLuminance 1 22 32
$textRatio = ([Math]::Max($background, $text) + 0.05) / ([Math]::Min($background, $text) + 0.05)
$buttonRatio = ([Math]::Max($primary, $onPrimary) + 0.05) / ([Math]::Min($primary, $onPrimary) + 0.05)
if ($textRatio -lt 7.0 -or $buttonRatio -lt 7.0) { throw 'Facade primary contrast is below the enhanced target.' }

$icon = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $IconPath))
if ($icon.Length -lt 24 -or [Convert]::ToHexString($icon[0..7]) -cne '89504E470D0A1A0A') {
    throw 'The launcher icon is not a PNG.'
}
$width = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($icon, 16))
$height = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($icon, 20))
if ($width -ne $height -or $width -lt 1024) { throw 'The launcher icon must be square and at least 1024 pixels.' }
$iconHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($icon))
$packageVerified = $false
if (-not [string]::IsNullOrWhiteSpace($PackageDirectory)) {
    $packageRoot = (Resolve-Path -LiteralPath $PackageDirectory).Path
    $manifestPath = [IO.Path]::Combine($packageRoot, 'facade-manifest.json')
    $manifest = [IO.File]::ReadAllText($manifestPath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or [string]$manifest.pwsh_commit -notmatch '^[0-9a-f]{40}$' -or
        @($manifest.files).Count -ne 5) { throw 'Facade package manifest contract is invalid.' }
    foreach ($file in @($manifest.files)) {
        if ([string]$file.path -notmatch '^[A-Za-z0-9._/-]+$' -or [string]$file.path -match '(^|/)\.\.(/|$)' -or
            [string]$file.sha256 -notmatch '^[0-9A-F]{64}$' -or [long]$file.bytes -le 0) {
            throw 'Facade package contains invalid file metadata.'
        }
        $path = [IO.Path]::GetFullPath([IO.Path]::Combine($packageRoot, ([string]$file.path).Replace('/', [IO.Path]::DirectorySeparatorChar)))
        if (-not $path.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Facade package path escapes its root.'
        }
        $bytes = [IO.File]::ReadAllBytes($path)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        if ($bytes.LongLength -ne [long]$file.bytes -or $hash -cne [string]$file.sha256) {
            throw "Facade package integrity failed: $($file.path)"
        }
    }
    $packageVerified = $true
}

[pscustomobject]@{
    Parsed = $true
    SafeAreaLayout = $true
    PrimaryHitTargetPixels = [int]($layout.Action.Bottom - $layout.Action.Top)
    TextContrastRatio = [Math]::Round($textRatio, 2)
    ButtonContrastRatio = [Math]::Round($buttonRatio, 2)
    IconDimensions = "${width}x${height}"
    IconSHA256 = $iconHash
    PinnedCanvasBinding = $true
    StagedPackageVerified = $packageVerified
    DeviceExecuted = $false
    Passed = $true
}
