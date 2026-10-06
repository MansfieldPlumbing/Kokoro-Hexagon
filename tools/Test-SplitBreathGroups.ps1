#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$script = [IO.Path]::Combine($PSScriptRoot, 'Split-BreathGroups.ps1')
$groups = @(& $script -Phonemes 'hɛloʊ wɜːld. əˈɡɛn.' -MaxFrames 8 -FramesPerChar 1)
if ($groups.Count -ne 3 -or @($groups | Where-Object { $_.EstFrames -gt 8 }).Count) {
    throw 'The planned groups exceeded the admitted frame cap.'
}
foreach ($group in $groups) {
    if ($group.Text -cne 'hɛloʊ' -and $group.Text -cne 'wɜːld.' -and $group.Text -cne 'əˈɡɛn.') {
        throw 'The planner split a phoneme run or changed its content.'
    }
}
$unsafeRejected = $false
try { $null = @(& $script -Phonemes 'hɛloʊwɜːld' -MaxFrames 4) }
catch { $unsafeRejected = $true }
if (-not $unsafeRejected) { throw 'A phoneme run was split without a legal boundary.' }
$invalidRejected = $false
try { $null = @(& $script -Phonemes 'a b' -MaxFrames 2 -FramesPerChar ([double]::NaN)) }
catch { $invalidRejected = $true }
if (-not $invalidRejected) { throw 'A nonfinite frame estimate was accepted.' }
[pscustomobject]@{ Passed = $true; Groups = $groups.Count; UnsafeCutRejected = $true; InvalidEstimateRejected = $true }
