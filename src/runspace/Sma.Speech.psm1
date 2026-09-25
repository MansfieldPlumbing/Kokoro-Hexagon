# Reversible authored-text to speech-plan boundary for the device runspace.
# This module does not phonemize or synthesize. It preserves authored source,
# admits explicit SMA cue cards, and produces testable realization candidates.

$eventNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in 'breath', 'pause', 'laugh', 'cough', 'clear_throat', 'sigh', 'gasp') {
    [void]$eventNames.Add($name)
}

$parse = {
    param([Parameter(Mandatory)][string]$Text)

    $nodes = [Collections.Generic.List[object]]::new()
    [int]$cursor = 0
    while ($cursor -lt $Text.Length) {
        [int]$open = $Text.IndexOf('⟦', $cursor, [StringComparison]::Ordinal)
        [int]$strayClose = $Text.IndexOf('⟧', $cursor, [StringComparison]::Ordinal)
        if ($strayClose -ge 0 -and ($open -lt 0 -or $strayClose -lt $open)) {
            throw "Unmatched SMA cue-card close at offset $strayClose."
        }
        if ($open -lt 0) {
            $nodes.Add([pscustomobject]@{
                Kind = 'text'; Start = $cursor; End = $Text.Length
                Raw = $Text.Substring($cursor); Name = $null; Parameter = $null
            })
            $cursor = $Text.Length
            break
        }
        if ($open -gt $cursor) {
            $nodes.Add([pscustomobject]@{
                Kind = 'text'; Start = $cursor; End = $open
                Raw = $Text.Substring($cursor, $open - $cursor); Name = $null; Parameter = $null
            })
        }
        [int]$close = $Text.IndexOf('⟧', $open + 1, [StringComparison]::Ordinal)
        if ($close -lt 0) { throw "Unclosed SMA cue card at offset $open." }
        [string]$raw = $Text.Substring($open, $close - $open + 1)
        [string]$body = $Text.Substring($open + 1, $close - $open - 1).Trim()
        if (-not $body) { throw "Empty SMA cue card at offset $open." }
        $match = [Text.RegularExpressions.Regex]::Match($body, '^(?<name>[a-z_]+)(?::(?<parameter>[^:]+))?$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $match.Success) { throw "Invalid SMA cue card '$raw'." }
        [string]$name = $match.Groups['name'].Value
        [string]$parameter = if ($match.Groups['parameter'].Success) { $match.Groups['parameter'].Value.Trim() } else { '' }
        if (-not $eventNames.Contains($name)) { throw "Unknown SMA cue card '$name'." }
        if ($name -eq 'pause') {
            $pause = [Text.RegularExpressions.Regex]::Match($parameter, '^(?<milliseconds>[1-9][0-9]{1,3})ms$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
            if (-not $pause.Success) { throw "SMA pause must be between 10ms and 9999ms: '$raw'." }
            [int]$milliseconds = [int]$pause.Groups['milliseconds'].Value
            if ($milliseconds -lt 20 -or $milliseconds -gt 5000) { throw "SMA pause is outside the admitted 20ms to 5000ms range: '$raw'." }
            $parameter = "${milliseconds}ms"
        }
        elseif ($parameter) { throw "SMA cue card '$name' does not accept a parameter." }
        $nodes.Add([pscustomobject]@{
            Kind = 'event'; Start = $open; End = $close + 1
            Raw = $raw; Name = $name; Parameter = if ($parameter) { $parameter } else { $null }
        })
        $cursor = $close + 1
    }
    if ($Text.Length -eq 0) { $nodes.Add([pscustomobject]@{ Kind = 'text'; Start = 0; End = 0; Raw = ''; Name = $null; Parameter = $null }) }

    $roundTrip = [Text.StringBuilder]::new()
    $spoken = [Text.StringBuilder]::new()
    foreach ($node in $nodes) {
        [void]$roundTrip.Append($node.Raw)
        if ($node.Kind -eq 'text') { [void]$spoken.Append($node.Raw) }
    }
    if ($roundTrip.ToString() -cne $Text) { throw 'SMA source round-trip failed.' }
    [pscustomobject]@{
        Schema = 1
        AuthoredText = $Text
        SpokenText = $spoken.ToString()
        Nodes = $nodes.ToArray()
    }
}.GetNewClosure()

$plan = {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('neutral', 'conversation', 'narrative', 'technical', 'meter')][string]$Objective = 'neutral',
        [hashtable]$LexicalSurprisal = @{},
        [ValidateRange(4, 64)][int]$SoftPlanningBudget = 14,
        [ValidateRange(8, 96)][int]$HardPlanningBudget = 24,
        [ValidatePattern('^[\p{L}\p{N}][\p{L}\p{N}_.-]{0,63}$')][string]$Speaker = 'narrator',
        [ValidatePattern('^[a-z][a-z0-9_]{0,63}$')][string]$Voice = 'af_heart'
    )
    if ($HardPlanningBudget -lt $SoftPlanningBudget) { throw 'HardPlanningBudget must not be lower than SoftPlanningBudget.' }
    $parsed = & $parse $Text
    $units = [Collections.Generic.List[object]]::new()
    [int]$load = 0
    $whWords = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($word in 'who', 'what', 'when', 'where', 'why', 'how', 'which', 'whose') { [void]$whWords.Add($word) }

    foreach ($node in $parsed.Nodes) {
        if ($node.Kind -eq 'event') {
            [bool]$recharge = $node.Name -eq 'breath'
            $before = $load
            if ($recharge) { $load = 0 }
            $units.Add([pscustomobject]@{
                Kind = 'event'; SourceStart = $node.Start; SourceEnd = $node.End
                Speaker = $Speaker; Voice = $Voice
                AuthoredText = $node.Raw; SpokenText = ''; Event = $node.Name; Parameter = $node.Parameter
                Intent = 'cue_card'; ContourCandidate = $null; PlanningLoad = 0
                BudgetBefore = $before; BudgetAfter = $load; Recharge = $recharge
                RechargeReason = if ($recharge) { 'explicit_cue' } else { $null }
                MeanSurprisal = $null; ProminenceCandidates = @()
            })
            continue
        }

        [int]$unitStart = 0
        for ($index = 0; $index -lt $node.Raw.Length; $index++) {
            [char]$character = $node.Raw[$index]
            [bool]$lineBoundary = $character -eq "`n"
            [bool]$terminal = '.!?'.Contains([string]$character)
            [bool]$strongClause = ';:—'.Contains([string]$character)
            [bool]$boundary = $terminal -or $strongClause -or ($Objective -eq 'meter' -and $lineBoundary)
            if (-not $boundary -and $index -lt $node.Raw.Length - 1) { continue }
            [int]$end = if ($boundary) { $index + 1 } else { $node.Raw.Length }
            [string]$rawUnit = $node.Raw.Substring($unitStart, $end - $unitStart)
            [string]$spokenUnit = $rawUnit.Trim()
            $unitStart = $end
            if (-not $spokenUnit) { continue }

            $wordMatches = [Text.RegularExpressions.Regex]::Matches($spokenUnit, "[\p{L}\p{N}]+(?:['’][\p{L}]+)?", [Text.RegularExpressions.RegexOptions]::CultureInvariant)
            [int]$planningLoad = $wordMatches.Count
            [double]$surprisalSum = 0
            [int]$surprisalCount = 0
            $prominence = [Collections.Generic.List[object]]::new()
            foreach ($wordMatch in $wordMatches) {
                [string]$key = $wordMatch.Value.ToLowerInvariant()
                if ($LexicalSurprisal.ContainsKey($key)) {
                    [double]$value = [double]$LexicalSurprisal[$key]
                    if (-not [double]::IsFinite($value) -or $value -lt 0) { throw "Invalid lexical surprisal for '$key'." }
                    $surprisalSum += $value; $surprisalCount++
                    $prominence.Add([pscustomobject]@{ Word = $wordMatch.Value; Surprisal = $value; Offset = $wordMatch.Index })
                }
            }
            $topProminence = [Collections.Generic.List[object]]::new()
            foreach ($candidate in $prominence) {
                [int]$insertAt = 0
                while ($insertAt -lt $topProminence.Count -and [double]$topProminence[$insertAt].Surprisal -ge [double]$candidate.Surprisal) { $insertAt++ }
                $topProminence.Insert($insertAt, $candidate)
                if ($topProminence.Count -gt 3) { $topProminence.RemoveAt(3) }
            }
            $prominenceArray = $topProminence.ToArray()
            [string]$firstWord = if ($wordMatches.Count) { $wordMatches[0].Value } else { '' }
            [bool]$isQuestion = $spokenUnit.EndsWith('?', [StringComparison]::Ordinal)
            [string]$intent = if ($isQuestion) { 'question' } elseif ($spokenUnit.EndsWith('!', [StringComparison]::Ordinal)) { 'exclamation' } elseif ($terminal) { 'statement' } else { 'continuation' }
            [string]$contour = switch ($intent) {
                'question' { if ($whWords.Contains($firstWord)) { 'wh_question_fall_candidate' } else { 'polar_question_rise_candidate' } }
                'statement' { 'statement_fall_candidate' }
                'exclamation' { 'exclamation_candidate' }
                default { 'continuation_candidate' }
            }
            if ($Objective -eq 'meter' -and $lineBoundary) { $contour = 'meter_line_candidate' }

            [int]$before = $load
            $load += $planningLoad
            [bool]$forced = $load -ge $HardPlanningBudget
            [bool]$syntacticRecharge = $terminal -or ($strongClause -and $load -ge $SoftPlanningBudget)
            [bool]$recharge = $forced -or $syntacticRecharge
            [string]$reason = if ($forced) { 'provisional_hard_budget' } elseif ($terminal) { 'sentence_boundary' } elseif ($syntacticRecharge) { 'clause_boundary' } else { $null }
            [int]$after = if ($recharge) { 0 } else { $load }
            $units.Add([pscustomobject]@{
                Kind = 'utterance'; SourceStart = $node.Start + ($end - $rawUnit.Length); SourceEnd = $node.Start + $end
                Speaker = $Speaker; Voice = $Voice
                AuthoredText = $rawUnit; SpokenText = $spokenUnit; Event = $null; Parameter = $null
                Intent = $intent; ContourCandidate = $contour; PlanningLoad = $planningLoad
                BudgetBefore = $before; BudgetAfter = $after; Recharge = $recharge; RechargeReason = $reason
                MeanSurprisal = if ($surprisalCount) { $surprisalSum / $surprisalCount } else { $null }
                ProminenceCandidates = $prominenceArray
            })
            if ($recharge) { $load = 0 }
        }
    }

    [pscustomobject]@{
        Schema = 1
        Objective = $Objective
        Speaker = $Speaker
        Voice = $Voice
        AuthoredText = $parsed.AuthoredText
        SpokenText = $parsed.SpokenText
        CueSyntax = '⟦name[:parameter]⟧'
        Units = $units.ToArray()
        Notes = @(
            'Contours and planning budgets are candidates until acoustic and device listening gates pass.'
            'Lexical surprisal is optional model evidence; it never changes authored text.'
        )
    }
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName = 'Kokoro.Sma.Speech'
    Parse = $parse
    Plan = $plan
}
