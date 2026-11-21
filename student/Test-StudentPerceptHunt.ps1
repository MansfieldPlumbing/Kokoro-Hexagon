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
