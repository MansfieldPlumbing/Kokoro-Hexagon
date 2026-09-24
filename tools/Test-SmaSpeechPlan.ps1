#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '..\src\runspace\Sma.Speech.psm1'
$sma = [scriptblock]::Create([IO.File]::ReadAllText((Resolve-Path -LiteralPath $module))).InvokeReturnAsIs()

$source = 'Can you move it? ⟦pause:180ms⟧ I can. ⟦breath⟧ Then move it.'
$parsed = & $sma.Parse $source
if ($parsed.AuthoredText -cne $source) { throw 'Authored text was not preserved.' }
if (($parsed.Nodes.Raw -join '') -cne $source) { throw 'Node coordinates did not round-trip.' }
if ($parsed.SpokenText -match 'pause|breath|⟦|⟧') { throw 'Cue cards leaked into spoken text.' }
if (@($parsed.Nodes | Where-Object Kind -eq 'event').Count -ne 2) { throw 'Expected two cue-card events.' }

$literal = & $sma.Parse 'A literal *breath* remains authored text.'
if (@($literal.Nodes | Where-Object Kind -eq 'event').Count) { throw 'Asterisks must not create SMA events.' }

$invalidRejected = $false
try { [void](& $sma.Parse 'No ⟦pause:forever⟧') } catch { $invalidRejected = $true }
if (-not $invalidRejected) { throw 'Invalid pause cue was accepted.' }

$plan = & $sma.Plan $source 'conversation' @{ move = 7.5; can = 1.0 }
$utterances = @($plan.Units | Where-Object Kind -eq 'utterance')
if ($utterances[0].Intent -ne 'question' -or $utterances[0].ContourCandidate -ne 'polar_question_rise_candidate') { throw 'Polar question was not classified.' }
if (-not ($plan.Units | Where-Object { $_.Event -eq 'breath' -and $_.BudgetAfter -eq 0 })) { throw 'Explicit breath did not reset the planning budget.' }
if (-not ($utterances[0].ProminenceCandidates | Where-Object Word -eq 'move')) { throw 'Surprisal evidence did not reach the prominence candidates.' }

$wh = & $sma.Plan 'Why did it stop?' 'conversation'
if ($wh.Units[0].ContourCandidate -ne 'wh_question_fall_candidate') { throw 'Wh-question candidate was not classified.' }

$meter = & $sma.Plan "Find the X, find the Y,`nsolve the unknown." 'meter'
if (@($meter.Units | Where-Object Kind -eq 'utterance').Count -ne 2) { throw 'Meter line boundary was not preserved.' }
if ($meter.Units[0].ContourCandidate -ne 'meter_line_candidate') { throw 'Meter line contour candidate was not emitted.' }

$dialogue = & $sma.Plan "What's wrong?" 'conversation' @{} 14 24 'Tom' 'am_michael'
if ($dialogue.Speaker -ne 'Tom' -or $dialogue.Voice -ne 'am_michael') { throw 'Plan speaker mapping was not preserved.' }
if ($dialogue.Units[0].Speaker -ne 'Tom' -or $dialogue.Units[0].Voice -ne 'am_michael') { throw 'Unit speaker mapping was not preserved.' }

[pscustomobject]@{
    SourceRoundTrip = $true
    CanonicalCueCards = 2
    AsteriskIsLiteral = $true
    InvalidCueRejected = $true
    QuestionCandidates = 2
    SurprisalPreserved = $true
    MeterLines = 2
    SpeakerVoiceMapping = $true
    Passed = $true
}
