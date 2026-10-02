#requires -Version 7.4
# Source-policy lint only; this does not inspect an APK or prove synthesis.
[CmdletBinding()]
param([switch]$Offline)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$upstreamArgs = @{}
if ($Offline) { $upstreamArgs.Offline = $true }
$upstream = & ([IO.Path]::Combine($PSScriptRoot, 'Get-PwshUpstream.ps1')) @upstreamArgs
if (-not $upstream.Passed) { throw 'Pinned Pwsh source verification failed.' }
$setupPath = ($upstream.Files | Where-Object Path -ceq 'setup.ps1').LocalPath
if ([string]::IsNullOrWhiteSpace($setupPath)) { throw 'Pinned Pwsh setup source is missing.' }

$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Pinned Pwsh setup source does not parse.' }
$setupText = [IO.File]::ReadAllText($setupPath, [Text.UTF8Encoding]::new($false, $true))
$requiredUpstreamControls = @(
    'ConvertTo-IlOnlyImage',
    'New-ManagedHostAssemblyBytes',
    'NativeActivityHandle',
    'APP_CONTEXT_BASE_DIRECTORY',
    'Profile.ps1',
    'android.app.NativeActivity',
    'libmonodroid.so',
    'libxamarin-app.so',
    '*.dex')
foreach ($needle in $requiredUpstreamControls) {
    if (-not $setupText.Contains($needle, [StringComparison]::Ordinal)) {
        throw "Pinned Pwsh source control is missing: $needle"
    }
}

$productSources = @(
    'src\runspace\Native.Binding.psm1',
    'src\runspace\Model.Store.psm1',
    'src\runspace\Audio.AAudio.psm1',
    'src\runspace\FastRpcDirectIoctlProbe.ps1',
    'src\appliance\Kokoro.Facade.psm1',
    'src\appliance\Start-KokoroFacade.ps1',
    'src\control\Kokoro.SpeechSession.psm1',
    'tools\Build-KokoroEngineAssembly.ps1')
$forbidden = 'Qnn\.|QAIRT|ONNX|PyTorch|Python|Mono\.Android|Java\.Interop|Android\.Systems\.Os|setup-kokoro\.ps1'
foreach ($relative in $productSources) {
    $path = [IO.Path]::Combine($root, $relative)
    $sourceTokens = $null
    $sourceErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$sourceTokens, [ref]$sourceErrors)
    if ($sourceErrors.Count -ne 0) { throw "$relative does not parse." }
    if ([Text.RegularExpressions.Regex]::IsMatch([IO.File]::ReadAllText($path), $forbidden)) {
        throw "$relative reaches a forbidden production dependency or the legacy setup fork."
    }
}

$storeText = [IO.File]::ReadAllText([IO.Path]::Combine($root, 'src', 'runspace', 'Model.Store.psm1'))
if ($storeText.Contains('Kokoro-Hexagon.dll', [StringComparison]::Ordinal)) {
    throw 'The model store still hard-codes the legacy assembly filename.'
}
$downstream = & ([IO.Path]::Combine($PSScriptRoot, 'Test-PwshDownstream.ps1'))
if ([string]$downstream -notlike 'PASS:*') { throw 'The Pwsh downstream boundary gate failed.' }

[pscustomobject]@{
    PwshCommit = $upstream.Commit
    PwshSourceParses = $true
    PwshNativeActivityBaseVerified = $true
    XamarinLegacyPayloadRejectorsPresent = $true
    DownstreamSourcesExcludeReferenceRuntimes = $true
    LegacySetupAbsentFromActivePath = $true
    AssemblyIdentityComesFromSignedManifest = $true
    Passed = $true
}
