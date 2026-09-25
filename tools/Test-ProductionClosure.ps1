#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$setup = [IO.Path]::Combine($root, 'setup-kokoro.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($setup, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'setup-kokoro.ps1 does not parse.' }
$text = [IO.File]::ReadAllText($setup)

$required = @(
    "[ValidateSet('NativeActivity')]",
    "`$baseApkLimit = 40MB",
    "`$_ -like '*.dex'",
    "`$_ -like '*/libmonodroid.so'",
    "`$_ -like '*/libxamarin-app.so'",
    "android.app.NativeActivity",
    "<PublishReadyToRun>false</PublishReadyToRun>"
)
foreach ($needle in $required) {
    if (-not $text.Contains($needle, [StringComparison]::Ordinal)) {
        throw "Production closure control is missing: $needle"
    }
}

$productSources = @(
    'src\runspace\Native.Binding.psm1',
    'src\runspace\Model.Store.psm1',
    'src\runspace\Audio.AAudio.psm1',
    'src\runspace\FastRpcDirectIoctlProbe.ps1'
)
$forbidden = 'Qnn\.|QAIRT|ONNX|PyTorch|Python|Mono\.Android|Java\.Interop|Android\.Systems\.Os'
foreach ($relative in $productSources) {
    $path = [IO.Path]::Combine($root, $relative)
    $sourceTokens = $null; $sourceErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$sourceTokens, [ref]$sourceErrors) | Out-Null
    if ($sourceErrors.Count) { throw "$relative does not parse." }
    if ([Text.RegularExpressions.Regex]::IsMatch([IO.File]::ReadAllText($path), $forbidden)) {
        throw "$relative reaches a forbidden production dependency."
    }
}

[pscustomobject]@{
    NativeActivityOnly = $true
    DexAndLegacyRuntimeRejected = $true
    ReadyToRunDisabled = $true
    BaseApkLimitBytes = 40MB
    ProductSourcesIsolated = $true
    Passed = $true
}
