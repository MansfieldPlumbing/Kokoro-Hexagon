# Static gate for the Pwsh base/Kokoro downstream repository boundary.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$sources = @(
    'src/build/Get-KokoroModelContract.ps1',
    'src/build/Import-PwshBuildFunction.ps1',
    'src/appliance/Kokoro.Facade.psm1',
    'src/appliance/Start-KokoroFacade.ps1',
    'src/control/Kokoro.SpeechSession.psm1',
    'tools/Build-KokoroEngineAssembly.ps1',
    'tools/Build-KokoroFacadePackage.ps1',
    'tools/Build-PhonemeContractAssembly.ps1',
    'tools/Build-WeightAssembly.ps1',
    'tools/Get-KokoroModelInput.ps1',
    'tools/Get-PwshUpstream.ps1',
    'tools/Test-KokoroEngineAssembly.ps1',
    'tools/Test-KokoroEngineStore.ps1',
    'tools/Test-KokoroFacade.ps1',
    'tools/Test-KokoroSpeechSession.ps1',
    'tools/Test-PwshDownstream.ps1')
foreach ($relative in $sources) {
    $path = [IO.Path]::Combine($root, $relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$relative has $($errors.Count) parse error(s)." }
}

$manifest = [IO.File]::ReadAllText(
    [IO.Path]::Combine($root, 'lib', 'manifest.json'),
    [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
$pin = $manifest.pwshUpstream
if ($null -eq $pin -or [string]$pin.commit -notmatch '^[0-9a-f]{40}$') {
    throw 'Pwsh upstream is not pinned to a full commit.'
}
$files = @($pin.files)
if ($files.Count -ne 3 -or @($files.path | Sort-Object -Unique).Count -ne 3 -or
    @($files.path | Sort-Object) -join ',' -cne
        'lib/manifest.json,modules/AndroidCanvas.psm1,setup.ps1') {
    throw 'Pwsh upstream must pin setup.ps1, lib/manifest.json, and AndroidCanvas.psm1.'
}
foreach ($file in $files) {
    if ([string]$file.sha256 -notmatch '^[0-9A-F]{64}$' -or [long]$file.bytes -le 0) {
        throw "Pwsh pin metadata is invalid for $($file.path)."
    }
}

$contract = & ([IO.Path]::Combine($root, 'src', 'build', 'Get-KokoroModelContract.ps1')) `
    -RepositoryRoot $root
if ($contract.Complete -or $contract.Scope -cne 'parsed-decoder-contract' -or $contract.Nodes -ne 2) {
    throw 'The extracted Kokoro model contract overstated the current graph boundary.'
}

$phonemeBuilder = [IO.File]::ReadAllText(
    [IO.Path]::Combine($root, 'tools', 'Build-PhonemeContractAssembly.ps1'),
    [Text.UTF8Encoding]::new($false, $true))
$sourceCreationToken = '[scriptblock]::' + 'Create'
$legacySetupName = 'setup-' + 'kokoro.ps1'
if ($phonemeBuilder -match [regex]::Escape($legacySetupName) -or
    $phonemeBuilder -match [regex]::Escape($sourceCreationToken)) {
    throw 'The phoneme builder regressed to the legacy setup fork or unvalidated source creation.'
}
$weightBuilder = [IO.File]::ReadAllText(
    [IO.Path]::Combine($root, 'tools', 'Build-WeightAssembly.ps1'),
    [Text.UTF8Encoding]::new($false, $true))
if ($weightBuilder -match [regex]::Escape($sourceCreationToken)) {
    throw 'The weight builder regressed to unvalidated source creation.'
}

foreach ($relative in $sources) {
    $sourceText = [IO.File]::ReadAllText(
        [IO.Path]::Combine($root, $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)),
        [Text.UTF8Encoding]::new($false, $true))
    if ($sourceText -match [regex]::Escape($legacySetupName)) {
        throw "$relative regressed to the legacy setup fork."
    }
}

Write-Output ('PASS: Pwsh {0} is the pinned Xamarin-independent base; Kokoro model contract remains explicitly incomplete and downstream.' -f $pin.commit)
