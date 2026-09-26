#requires -Version 7.4
# Stage and run the source-defined diagnostic; restore prior app state.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Razr', 'S23')][string]$Device)
$ErrorActionPreference = 'Stop'
$package = 'dev.mansfieldplumbing.androidsma.preview'
$relative = 'files/kokoro-fl/dspqueue-echo/Get-DspQueueCapabilities.ps1'
$local = Join-Path $PSScriptRoot 'dspqueue-echo/Get-DspQueueCapabilities.ps1'
$runner = Join-Path $PSScriptRoot 'Invoke-RecoveredDspQueueEcho.ps1'
$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($local, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Capability probe did not parse.' }
$expected = (Get-FileHash -Algorithm SHA256 -LiteralPath $local).Hash.ToLowerInvariant()
$adb = (Get-Command adb -CommandType Application | Select-Object -First 1).Source
if (-not $adb) { throw 'adb is unavailable.' }
$serials = @(& $adb devices | Where-Object { $_ -match '^\S+\s+device$' } |
    ForEach-Object { ($_ -split '\s+')[0] })
$matches = @($serials | Where-Object {
    $model = (& $adb -s $_ shell getprop ro.product.model).Trim()
    if ($Device -eq 'Razr') { $model -match 'razr plus 2024' }
    else { $model -eq 'SM-S911U' }
})
if ($matches.Count -ne 1) { throw "Expected exactly one attached $Device device." }
$serial = $matches[0]
& $adb -s $serial shell run-as $package test -e $relative 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'A diagnostic probe already occupies the target path.' }
$temp = '/data/local/tmp/kokoro-capabilities-' + [Guid]::NewGuid().ToString('N') + '.ps1'
$staged = $false
$pushed = $false
try {
    & $adb -s $serial push $local $temp 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic probe transfer failed.' }
    $pushed = $true
    & $adb -s $serial shell run-as $package cp $temp $relative 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Diagnostic probe staging failed.' }
    $staged = $true
    $actual = ((& $adb -s $serial shell run-as $package sha256sum $relative 2>$null) -split '\s+')[0]
    if ($actual -cne $expected) { throw 'Staged diagnostic digest mismatch.' }
    & $runner -Device $Device -Probe Capabilities
} finally {
    if ($staged) {
        & $adb -s $serial shell run-as $package rm $relative 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Staged diagnostic cleanup failed.' }
        & $adb -s $serial shell run-as $package test -e $relative 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { throw 'Staged diagnostic remains in private storage.' }
    }
    if ($pushed) {
        & $adb -s $serial shell rm $temp 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Transfer copy cleanup failed.' }
    }
}
