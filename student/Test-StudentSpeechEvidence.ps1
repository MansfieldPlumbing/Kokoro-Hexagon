using module ./StudentTeacherObservation.psm1
#requires -Version 7.7
param([string] $BankPath=(Join-Path $PSScriptRoot '../data/source-bank'))
$ErrorActionPreference='Stop'
$investigation=& "$PSScriptRoot/Invoke-Student.ps1" -Step SpeechEvidence -Corpus $BankPath
$inventory=$investigation.Inventory
$expected=@($inventory.Units.Values | Where-Object Kind -In 'OriginalHumanAudio','OriginalConversationChannel','PrivatePerformanceAudio')
if ($expected.Count -ne $investigation.Recordings.Count) { throw 'Native recording coverage is incomplete.' }
foreach ($wave in $investigation.Recordings) {
    if (![object]::ReferenceEquals($wave.Source,$inventory.Units[$wave.Source.Id]) -or
        (Get-FileHash -LiteralPath $wave.Source.Path).Hash -cne $wave.Source.Checksum) { throw 'Recording source or identity mismatch.' }
    if (![object]::ReferenceEquals($wave.Source,$wave.Prosody.Source)) { throw 'Native and pitch evidence do not share their specimen.' }
}
foreach ($interval in $investigation.ConversationEvents) {
    if (![object]::ReferenceEquals($interval.Onset.Annotation,$interval.Release.Annotation) -or
        ![object]::ReferenceEquals($interval.Recording,$interval.Onset.Wave)) { throw 'Performance context identity mismatch.' }
}
foreach ($chapter in $investigation.HumanChapters) {
    if ($chapter.Next -and (![object]::ReferenceEquals($chapter.Next.Previous,$chapter) -or
        ![object]::ReferenceEquals($chapter.Next.Document,$chapter.Document))) { throw 'Chapter chronology identity mismatch.' }
}
foreach ($hypothesis in $investigation.ConversationReadings) {
    $label=$hypothesis.Onset.Annotation
    if (![object]::ReferenceEquals($label,$hypothesis.Release.Annotation) -or
        ![object]::ReferenceEquals($label.Parent,$hypothesis.Onset.Wave.Source)) { throw 'Conversation evidence uses a different annotation or clock.' }
}
$joinedChapters=0
$chapterNumbers=[Collections.Generic.HashSet[int]]::new()
$withAnchors=0
$bytes=0L
$stock=0.0
$zira=0.0
$words=0
$phones=0
$teacherRmsFrames=0L
$samplesPerSource=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
$occurrences=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($comparison in $investigation.Comparisons) {
    $teacher=$comparison.Teacher
    $null=Open-StudentTeacherObservation $teacher.Directory $teacher.Document -LoadTensors
    if (![object]::ReferenceEquals($teacher.Sentences[0].Document,$teacher.Document) -or
        $teacher.ZiraUtterance.GetType().Name -cne 'EnglishZiraUtterance') { throw 'Teacher evidence owner or type mismatch.' }
    if ($comparison.HumanContext) {
        if (![object]::ReferenceEquals($comparison.HumanContext.Document,$teacher.Document)) { throw 'Human and teacher evidence lost shared source identity.' }
        $joinedChapters++
        $null=$chapterNumbers.Add($comparison.HumanContext.ChapterNumber)
    }
    foreach ($anchor in $comparison.HumanWordAnchors) {
        if (![object]::ReferenceEquals($anchor.Utterance.Chapter,$comparison.HumanContext)) { throw 'Human anchor belongs to a different recording.' }
    }
    if ($comparison.HumanWordAnchors.Length) { $withAnchors++ }
    $stockWave=Measure-StudentTeacherWave $teacher Kokoro
    $ziraWave=Measure-StudentTeacherWave $teacher Zira
    if ($stockWave.Samples -ne $teacher.KokoroSamples -or $stockWave.SampleRate -ne 24000 -or $ziraWave.SampleRate -ne 16000 -or
        ![object]::ReferenceEquals($stockWave.Owner,$ziraWave.Owner)) { throw 'Teacher waveform clocks or owner identity differ.' }
    $stock+=$stockWave.Samples/[double]$stockWave.SampleRate
    $zira+=$ziraWave.Samples/[double]$ziraWave.SampleRate
    $teacherRmsFrames+=$stockWave.Rms.Length+$ziraWave.Rms.Length
    $words+=$teacher.ZiraUtterance.Words.Count
    $phones+=$teacher.ZiraUtterance.Phones.Count
    $bytes+=(Get-ChildItem -LiteralPath $teacher.Directory -File | Measure-Object Length -Sum).Sum
    $id=$teacher.Document.Source.EvidenceGroup
    foreach ($sentence in $teacher.Sentences) {
        $first=$teacher.Document.Sentences[2*$sentence.Index]
        $last=$teacher.Document.Sentences[2*$sentence.Index+1]
        for ($token=$first;$token -le $last;$token++) {
            if ($teacher.Document.Tokens[4*$token] -eq 1) { $null=$occurrences.Add("$id/$token") }
        }
    }
    if (!$samplesPerSource.ContainsKey($id)) { $samplesPerSource.Add($id,0) }
    $samplesPerSource[$id]++
}
"nativeTracks=$($expected.Count) chapterLinks=$($investigation.HumanChapters.Count) conversationWords=$($investigation.ConversationReadings.Count) conversationEvents=$($investigation.ConversationEvents.Count) privateCues=$($investigation.PrivateCues.Count)"
"teacherPairs=$($investigation.Comparisons.Count) sourceWords=$($occurrences.Count) humanContexts=$joinedChapters humanChapterCoverage=$($chapterNumbers.Count) teacherContextsWithRecognizedAnchors=$withAnchors stockSeconds=$stock ziraSeconds=$zira ziraWords=$words ziraPhones=$phones teacherRmsFrames=$teacherRmsFrames bytes=$bytes"
foreach ($source in $samplesPerSource.Keys) { "$source pairs=$($samplesPerSource[$source])" }

$libri=@(& "$PSScriptRoot/Invoke-Student.ps1" -Step SpeechEvidence -Corpus $BankPath -SourceIdentity LibriSpeech)
$measured=0
$frames=0L
$seconds=0.0
$unique=0
$ambiguous=0
$missing=0
foreach ($chapter in $libri) {
    if ($chapter.GetType().Name -cne 'StudentLibriChapter') { continue }
    foreach ($utterance in $chapter.Utterances) {
        if (![object]::ReferenceEquals($utterance.Chapter,$chapter)) { throw 'LibriSpeech utterance owner mismatch.' }
        if ($utterance.TextAnchors.Count -eq 1) { $unique++ }
        elseif ($utterance.TextAnchors.Count -gt 1) { $ambiguous++ }
        else { $missing++ }
        foreach ($anchor in $utterance.TextAnchors) {
            if (![object]::ReferenceEquals($anchor.Utterance,$utterance) -or $anchor.Start -lt 0 -or
                $anchor.Length -le 0 -or $anchor.ArchiveMember -cnotin $chapter.Book.Editions) {
                throw 'Original LibriSpeech text anchor identity mismatch.'
            }
        }
        if (!$utterance.Rms) { continue }
        $measured++
        $frames+=$utterance.Rms.Length
        $seconds+=$utterance.Samples/[double]$utterance.Rate
    }
}
"libriUtterancesMeasured=$measured libriNativeSeconds=$seconds libriFrames=$frames uniqueTextCandidates=$unique ambiguous=$ambiguous missing=$missing"
