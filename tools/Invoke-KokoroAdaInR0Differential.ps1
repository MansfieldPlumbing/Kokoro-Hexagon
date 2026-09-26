#requires -Version 7.4
# Historical QNN reference only. Restores the diagnostic app's prior inputs and entry scripts.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Serial,
    [Parameter(Mandatory)][string] $FixtureDir,
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview'
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixture = (Resolve-Path -LiteralPath $FixtureDir).Path
if (-not $fixture.StartsWith(([IO.Path]::Combine($root, 'build') + [IO.Path]::DirectorySeparatorChar),
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture must be under the repository build directory.'
}
$files = @('in_z.f32', 'in_mask1.f32', 'oracle_r0.f32', 'r0_static.bin',
    'oracle_a1.f32', 'oracle_snake.f32', 'oracle_conv.f32', 'oracle_a2.f32',
    'oracle_snake2.f32', 'oracle_conv2.f32', 'oracle_residual.f32',
    'oracle_residual1.f32', 'oracle_p1_AdaIn1.f32', 'oracle_p1_Snake1.f32',
    'oracle_p1_Conv1.f32', 'oracle_p1_AdaIn2.f32', 'oracle_p1_Snake2.f32',
    'oracle_p1_Conv2.f32', 'oracle_p1_Conv1_dilation1.f32')
foreach ($name in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $fixture $name) -PathType Leaf)) {
        throw "Fixture file is missing: $name"
    }
}
$frames = [int]((Get-Item -LiteralPath (Join-Path $fixture 'in_mask1.f32')).Length / 4)
if ($frames -lt 2 -or $frames -gt 128 -or
    (Get-Item -LiteralPath (Join-Path $fixture 'in_z.f32')).Length -ne 128 * $frames * 4 -or
    (Get-Item -LiteralPath (Join-Path $fixture 'oracle_r0.f32')).Length -ne 128 * $frames * 4) {
    throw 'Fixture shape is invalid.'
}
$adb = (Get-Command adb -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function Invoke-Adb([string[]] $Arguments) {
    $result = & $adb -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ADB operation failed: $($Arguments[0])" }
    return $result
}
$state = @(Invoke-Adb @('get-state')) -join ''
if ($state.Trim() -cne 'device') { throw 'Device is not ready.' }
$deviceRoot = 'files/kokoro-fl'
$backup = "$deviceRoot/r0-differential-backup"
$targets = @('files/Start.ps1', 'files/PROFILE.PS1', "$deviceRoot/receipt.txt") +
    @($files | ForEach-Object { "$deviceRoot/r0/$_" }) +
    @("$deviceRoot/r009-modules/Native.Binding.psm1")
$existing = [Collections.Generic.List[string]]::new()
[void](Invoke-Adb @('shell', 'run-as', $Package, 'mkdir', '-p', $backup,
    "$backup/r0", "$backup/r009-modules"))
foreach ($target in $targets) {
    $probe = & $adb -s $Serial shell run-as $Package test -f $target 2>$null
    if ($LASTEXITCODE -eq 0) {
        $relative = if ($target.StartsWith("$deviceRoot/r0/", [StringComparison]::Ordinal)) {
            'r0/' + [IO.Path]::GetFileName($target)
        } elseif ($target.StartsWith("$deviceRoot/r009-modules/", [StringComparison]::Ordinal)) {
            'r009-modules/' + [IO.Path]::GetFileName($target)
        } else { [IO.Path]::GetFileName($target) }
        [void](Invoke-Adb @('shell', 'run-as', $Package, 'cp', $target,
            ($backup + '/' + $relative)))
        $existing.Add($target)
    }
}
try {
    $bindingRemote = '/data/local/tmp/kokoro-r0-native-binding.psm1'
    [void](Invoke-Adb @('push', (Join-Path $root 'src/runspace/Native.Binding.psm1'), $bindingRemote))
    [void](Invoke-Adb @('shell', 'run-as', $Package, 'cp', $bindingRemote,
        "$deviceRoot/r009-modules/Native.Binding.psm1"))
    foreach ($name in $files) {
        $remote = "/data/local/tmp/kokoro-r0-differential-$name"
        [void](Invoke-Adb @('push', (Join-Path $fixture $name), $remote))
        [void](Invoke-Adb @('shell', 'run-as', $Package, 'cp', $remote, "$deviceRoot/r0/$name"))
    }
    $scriptRemote = '/data/local/tmp/kokoro-r0-differential.ps1'
    [void](Invoke-Adb @('push', (Join-Path $root 'src/runspace/R0Emit.ps1'), $scriptRemote))
    foreach ($target in @('files/Start.ps1', 'files/PROFILE.PS1')) {
        [void](Invoke-Adb @('shell', 'run-as', $Package, 'cp', $scriptRemote, $target))
    }
    [void](Invoke-Adb @('shell', 'run-as', $Package, 'truncate', '-s', '0', "$deviceRoot/receipt.txt"))
    [void](Invoke-Adb @('shell', 'am', 'force-stop', $Package))
    [void](Invoke-Adb @('shell', 'monkey', '-p', $Package, '-c', 'android.intent.category.LAUNCHER', '1'))
    $receipt = ''
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Seconds 2
        $receipt = @(Invoke-Adb @('shell', 'run-as', $Package, 'cat', "$deviceRoot/receipt.txt")) -join "`n"
        if ($receipt -match 'Job=r0emit' -and $receipt -match 'Passed=') { break }
    }
    if ($receipt -notmatch 'Job=r0emit' -or $receipt -notmatch 'Passed=') {
        throw 'QNN reference did not complete within the bounded wait.'
    }
    foreach ($line in ($receipt -split "`n")) {
        if ($line -match '^(Shape|FinalizeRc|QnnHead|OracleHead|Result|Passed|Error|Stage|StageAlt)=|^Result ') {
            Write-Output $line.Trim()
        }
    }
    if ($receipt -notmatch 'Passed=True') { throw 'QNN differential did not pass.' }
}
finally {
    [void](& $adb -s $Serial shell am force-stop $Package 2>$null)
    foreach ($target in $existing) {
        $relative = if ($target.StartsWith("$deviceRoot/r0/", [StringComparison]::Ordinal)) {
            'r0/' + [IO.Path]::GetFileName($target)
        } elseif ($target.StartsWith("$deviceRoot/r009-modules/", [StringComparison]::Ordinal)) {
            'r009-modules/' + [IO.Path]::GetFileName($target)
        } else { [IO.Path]::GetFileName($target) }
        $saved = $backup + '/' + $relative
        [void](& $adb -s $Serial shell run-as $Package cp $saved $target 2>$null)
    }
    Write-Output 'Restore: prior diagnostic app files copied back; backup retained in private storage.'
}
