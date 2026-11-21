#requires -Version 7.7
param([string]$BankPath=(Join-Path $PSScriptRoot '../data/source-bank'))
$ErrorActionPreference='Stop'
$percept=& "$PSScriptRoot/Invoke-Student.ps1" -Step Hunt -Corpus $BankPath
$focus=$percept.Image.MorphologicalInvestigation
$relation=$percept.Rules[0]
if ($percept.State -cne 'ObservedScope' -or !$relation.LoweredReady -or !$percept.Examples.Count -or
    $percept.ConfidenceHistory[0].OriginFamilies -ne 1) { throw 'Clock scope or lineage mismatch.' }
foreach ($example in $percept.Examples) {
    if (![object]::ReferenceEquals($example.Condition.Teacher.Document.Source,$example.Provenance) -or
        $percept.PredictCapturedExtent($example.Occurrence) -ne $example.Measured.Extent -or
        $null -ne $percept.PredictCapturedExtent($example.Measured)) {
        throw 'Lost typed provenance, prediction parity, or applicability.'
    }
}
foreach ($candidate in $relation.Constituents) {
    foreach ($example in $candidate.Current.Evidence) {
        $properties=@($example.Referent.GetType().GetProperties())
        if ($properties.Count -ne 1 -or $properties[0].Name -cne 'Value' -or $properties[0].PropertyType -ne [int]) {
            throw 'Predictive referent exposes more than its scalar coordinate.'
        }
    }
}
foreach ($hit in $focus.Hits) {
    if (!$hit.CompetingRules() -or !$focus.Nominations.ContainsKey($hit.Spelling) -or
        ![object]::ReferenceEquals($hit.Parses[0].Sentence,$hit.Sentence)) {
        throw 'Morphological focus lost competing readings or source identity.'
    }
}
if ($focus.Hits.Count -lt 1 -or $focus.Dormant.Count -lt 1 -or
    $percept.Image.Percepts.ContainsKey('CapturedCompetingMorphologyFocus')) {
    throw 'Focus should retain misses and stay in the investigation.'
}
$prior=@(foreach ($group in $focus.Nominations.get_Values()) {
    foreach ($reading in $group) { $reading }
})
$probes=@($focus.Hits + $focus.Dormant + $focus.Contradictions | ForEach-Object Spelling | Sort-Object -Unique)
$candidateVisits=0
foreach ($spelling in $probes) {
    $scan=@(foreach ($priorReading in $prior) {
        $candidateVisits++
        if ([StringComparer]::OrdinalIgnoreCase.Equals($priorReading.Spelling,$spelling) -and !$focus.WithheldSpellings.Contains($spelling)) { $priorReading }
    })
    $indexed=$focus.Nominate($spelling)
    if ($scan.Count -ne $indexed.Count) { throw "Morphology recall for '$spelling' differs from the historical scan ($($scan.Count) vs $($indexed.Count))." }
    for ($i=0;$i -lt $scan.Count;$i++) {
        if (![object]::ReferenceEquals($scan[$i],$indexed[$i])) { throw 'Morphology recall replaced historical evidence.' }
    }
}
"humanTimingBearings=$($focus.HumanWordDurations.Count) unresolvedStressCases=$($focus.UnresolvedStress.Count) matchingWordDurations=$(($focus.UnresolvedStress | Measure-Object -Property {$_.AvailableWordDurations.Count} -Sum).Sum)"
$timing=$focus.Timing
if ($focus.UnresolvedStress.Count -ne 23 -or !$timing.Windows.Count -or !$timing.ContainmentCount -or !$timing.AcousticWindowCount) {
    throw 'The retained stress questions or human timing evidence are missing.'
}
$all=@(foreach ($documentIndex in $timing.ByDocument.get_Values()) {
    foreach ($wordList in $documentIndex.get_Values()) {
        foreach ($bearing in $wordList) { $bearing }
    }
})
if ($all.Count -ne $timing.ContainmentCount) { throw 'Temporal index lost candidate relationships.' }
foreach ($bearing in $all) {
    if ($bearing.WordIndex -notin $bearing.Anchor.CandidateTokens -or
        ![object]::ReferenceEquals($bearing.Window.Utterance,$bearing.Anchor.Utterance) -or
        ![object]::ReferenceEquals($bearing.Window.Recording,$bearing.Anchor.Utterance.Chapter.Wave) -or
        $bearing.Window.FirstNativeSample -lt 0 -or
        $bearing.Window.EndNativeSample -gt $bearing.Window.NativeCoverageEnd -or
        $bearing.Window.FirstNativeSample -ge $bearing.Window.EndNativeSample) { throw 'Broken human temporal provenance.' }
}
$lateChapters=@($timing.Windows | ForEach-Object {$_.Utterance.Chapter} | Where-Object ChapterNumber -GT 6 | Sort-Object ChapterNumber -Unique)
$queries=@(foreach ($query in @($focus.Hits)+@($focus.Dormant)) {
    foreach ($chapter in $lateChapters) {
        if ([object]::ReferenceEquals($chapter.Document,$query.Sentence.Document) -and
            $query.WordIndex -ge $chapter.FirstToken -and $query.WordIndex -le $chapter.LastToken) { $query; break }
    }
})
if (!$queries.Count) { throw 'No retained morphology questions in the later chapters.' }
$exhaustive=[Collections.Generic.List[object]]::new()
$watch=[Diagnostics.Stopwatch]::StartNew()
foreach ($query in $queries) {
    $scan=@(foreach ($bearing in $all) {
        if ($bearing.WordIndex -eq $query.WordIndex -and
            [object]::ReferenceEquals($bearing.Anchor.Utterance.Chapter.Document,$query.Sentence.Document)) { $bearing }
    })
    $exhaustive.Add($scan)
}
$scanMilliseconds=$watch.Elapsed.TotalMilliseconds
$indexedResults=[Collections.Generic.List[object]]::new()
$watch.Restart()
foreach ($query in $queries) { $indexedResults.Add($timing.Find($query.Sentence.Document,$query.WordIndex)) }
$lookupMilliseconds=$watch.Elapsed.TotalMilliseconds
for ($q=0;$q -lt $queries.Count;$q++) {
    if ($indexedResults[$q].Count -ne $exhaustive[$q].Count) { throw 'Indexed temporal retrieval differs from exhaustive retrieval.' }
    for ($i=0;$i -lt $indexedResults[$q].Count;$i++) {
        if (![object]::ReferenceEquals($indexedResults[$q][$i],$exhaustive[$q][$i])) { throw 'Temporal retrieval replaced canonical evidence.' }
    }
}
$conversation=@($timing.ConversationDurations | Where-Object OrderedAlternatives -GT 0)
foreach ($range in $conversation) {
    if ($range.ShortestSamples -le 0 -or $range.LongestSamples -lt $range.ShortestSamples) { throw 'Invalid duration bounds.' }
}
"temporalWindows=$($timing.Windows.Count) rmsWindows=$($timing.AcousticWindowCount) containment=$($all.Count) unaligned=$($timing.UnalignedAnchors.Count) ambiguous=$($timing.AmbiguousAnchors.Count) unprojectable=$($timing.UnprojectableUtterances.Count) multiword=$($timing.MultiwordUtterances.Count)"
"morphologyWithHumanTiming=$($timing.WordQuestionsWithTiming) morphologyWithBothContexts=$($timing.WordQuestionsWithBothContexts) unresolvedStressWithContainment=$(@($focus.UnresolvedStress | Where-Object AvailableTiming).Count)"
"conversationWords=$($timing.ConversationDurations.Count) supportedRanges=$($conversation.Count) competingRanges=$(@($conversation | Where-Object OrderedAlternatives -GT 1).Count)"
$same=@($timing.ProceduralChecks | Where-Object {$_.Matches()})
if ($timing.ProceduralChecks.Count -ne 6) { throw 'The retained procedural histories were not all evaluated.' }
"proceduralTransferTrials=$($timing.ProceduralChecks.Count) matchingExtents=$($same.Count) contradictoryExtents=$($timing.ProceduralChecks.Count-$same.Count)"
"laterChapterQueries=$($queries.Count) exhaustiveVisits=$($queries.Count*$all.Count) indexedLookups=$($queries.Count) scanMs=$([math]::Round($scanMilliseconds,2)) lookupMs=$([math]::Round($lookupMilliseconds,2)) buildMs=$([math]::Round($timing.BuildMilliseconds,2)) buildAndLookupMs=$([math]::Round($timing.BuildMilliseconds+$lookupMilliseconds,2)) reconsiderationMs=$([math]::Round($timing.ReconsiderationMilliseconds,2))"
"historicalRecall indexedLookups=$($probes.Count) exhaustiveVisits=$candidateVisits"
foreach ($bearing in $focus.PronunciationBearings) {
    foreach ($anchor in $bearing.HumanCandidates) {
        if (![object]::ReferenceEquals($anchor.Utterance.Chapter.Document,$bearing.Sentence.Document) -or
            $bearing.WordIndex -notin $anchor.CandidateTokens) { throw 'Broken human pronunciation provenance.' }
    }
}
"morphology nominations=$($focus.Nominations.get_Count()) hits=$($focus.Hits.Count) contradictions=$($focus.Contradictions.Count) misses=$($focus.Dormant.Count) examined=$($focus.Examined)"
if ('record' -cnotin @($focus.PronunciationBearings | ForEach-Object {$_.Spelling.ToLowerInvariant()})) { 'word=record occurrences=0' }
foreach ($group in $focus.PronunciationBearings | Group-Object Spelling) {
    $readings=@($group.Group | ForEach-Object {$_.ChosenReading()} | Sort-Object -Unique)
    $anchors=($group.Group | Measure-Object -Property {$_.HumanCandidates.Count} -Sum).Sum
    $teachers=($group.Group | Measure-Object -Property {$_.TeacherContexts.Count} -Sum).Sum
    $dictionaryReadings=@(foreach ($alternative in $group.Group[0].DictionaryAlternatives) { $alternative -join ' ' })
    "word=$($group.Name) occurrences=$($group.Count) phonemizerReadings=$($readings -join ',') dictionaryReadings=$($dictionaryReadings -join '|') humanAnchorCandidates=$anchors teacherContexts=$teachers"
}
if ($percept.ControlledChecks.Count -ne 1 -or !$percept.ControlledChecks[0].ChangedSamples) { throw 'Missing controlled acoustic outcome.' }
$constituent=$relation.Constituents[0]
$historical=$constituent.Current
$next=[Activator]::CreateInstance($historical.GetType())
$next.Reliance='Demoted'
$next.Reason='Test withdrawal in a disposable image'
$constituent.Record($next)
if ($null -ne $percept.PredictCapturedExtent($percept.Examples[0].Occurrence) -or
    $relation.Current.Reliance.ToString() -cne 'Demoted' -or
    ![object]::ReferenceEquals($historical,$relation.ConstituentJudgments[0]) -or
    ![object]::ReferenceEquals($next,$relation.Current.Trigger)) {
    throw 'Dependency withdrawal or historical identity failed.'
}
"clockExamples=$($percept.Examples.Count) bytesDeferred=$($percept.DeferredWaveformBytes) interventionChanged=$($percept.ControlledChecks[0].ChangedSamples) withdrawal=$($relation.Current.Reliance)"
