using module ./StudentSourceInventory.psm1
using module ./StudentTextEvidence.psm1
using module ./StudentNativeSpeech.psm1
using module ./StudentTeacherObservation.psm1
using module ./StudentWaveEvidence.psm1
#requires -Version 7.4
param([string] $BankPath,[string] $SourceIdentity,[psmoduleinfo] $ZiraModule)
$ErrorActionPreference='Stop'

class StudentSpeechComparison {
    [StudentTeacherObservation] $Teacher
    [StudentHumanChapter] $HumanContext
    [StudentHumanWordAnchor[]] $HumanWordAnchors
}

class StudentSpeechInvestigation {
    [StudentSourceInventory] $Inventory
    [StudentNativeSpeech[]] $Recordings
    [StudentHumanChapter[]] $HumanChapters
    [StudentHumanWordAnchor[]] $HumanWordAnchors
    [StudentLexicalPhoneHypothesis[]] $ConversationReadings
    [StudentPerformanceInterval[]] $ConversationEvents
    [StudentTimingCue[]] $PrivateCues
    [StudentSpeechComparison[]] $Comparisons
}

$investigation=[StudentSpeechInvestigation]::new()
$investigation.Inventory=Open-StudentSourceInventory (Join-Path $BankPath 'sources.bin')
$investigation.Recordings=@(foreach ($source in $investigation.Inventory.Units.Values) {
    if ($source.Kind -cnotin 'OriginalHumanAudio','OriginalConversationChannel','PrivatePerformanceAudio') { continue }
    $documentSource=$null
    if ($source.Parent) { $documentSource=$source.Parent.CorrespondingText }
    if ($SourceIdentity -and !$source.Id.StartsWith($SourceIdentity,[StringComparison]::Ordinal) -and
        (!$documentSource -or $documentSource.EvidenceGroup -cne $SourceIdentity)) { continue }
    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source.Id)))
    $nativePath=Join-Path $BankPath "native-speech/$key.bin"
    if (!(Test-Path -LiteralPath $nativePath)) { continue }
    $wave=Open-StudentNativeSpeech $nativePath $investigation.Inventory
    if (![object]::ReferenceEquals($wave.Source,$source)) { throw 'Native spectrum belongs to a different recording.' }
    $prosodyPath=Join-Path $BankPath "waveform/$key.bin"
    if (Test-Path -LiteralPath $prosodyPath) {
        $wave.Prosody=Open-StudentWaveEvidence $prosodyPath $investigation.Inventory
        if (![object]::ReferenceEquals($wave.Source,$wave.Prosody.Source)) { throw 'Prosody belongs to a different recording.' }
    }
    $wave
})
$documents=[Collections.Generic.Dictionary[string,StudentTextEvidence]]::new([StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $BankPath 'linguistic') -Filter 'pg*.bin' -File) {
    if ($SourceIdentity -and $file.BaseName -cmatch '^pg([0-9]+)$' -and "Gutenberg/$($Matches[1])" -cne $SourceIdentity) { continue }
    $doc=Open-StudentTextEvidence $file.FullName $investigation.Inventory
    if (!$SourceIdentity -or $doc.Source.EvidenceGroup -ceq $SourceIdentity) {
        if ((Get-FileHash -LiteralPath $doc.Source.Path).Hash -cne $doc.Source.Checksum) { throw 'Original work checksum mismatch.' }
        $documents.Add($doc.Source.Id,$doc)
    }
}
$investigation.HumanChapters=@(foreach ($doc in $documents.Values) {
    if ($doc.Source.EvidenceGroup -ceq 'Gutenberg/11') { Join-StudentDramaticChapters $doc $investigation.Recordings }
})
$investigation.ConversationReadings=@(foreach ($wave in $investigation.Recordings) {
    if ($wave.Source.Kind -ceq 'OriginalConversationChannel') {
        Join-StudentConversationPhones $wave $investigation.Inventory.Units.get_Item('StudentLexicon/cmudict.dict')
    }
})
$investigation.ConversationEvents=@(foreach ($wave in $investigation.Recordings) {
    if ($wave.Source.Kind -ceq 'OriginalConversationChannel') { Find-StudentPerformanceIntervals $wave }
})
$privateReferences=@($investigation.Inventory.Units.Values | Where-Object Kind -CEQ PrivatePerformanceReference)
$investigation.PrivateCues=@(foreach ($wave in $investigation.Recordings) {
    if (!$wave.Prosody -or $wave.Source.Kind -cne 'PrivatePerformanceAudio') { continue }
    $stem=[IO.Path]::GetFileNameWithoutExtension($wave.Source.Path)
    foreach ($reference in $privateReferences) {
        if ([IO.Path]::GetFileName($reference.Path) -ceq "${stem}_PROVISIONAL_timestamps.srt") {
            Join-StudentProvisionalTiming $wave.Prosody $reference
        }
    }
})
$wordAnchors=[Collections.Generic.Dictionary[int,StudentHumanWordAnchor[]]]::new()
foreach ($chapter in $investigation.HumanChapters) {
    $base=[IO.Path]::GetFileNameWithoutExtension($chapter.Wave.Source.Path)
    $path=Join-Path $BankPath "human-dictation/$base.full.bin"
    if (!(Test-Path -LiteralPath $path)) { $path=Join-Path $BankPath "human-dictation/$base.bin" }
    if (Test-Path -LiteralPath $path) { $wordAnchors.Add($chapter.ChapterNumber,@(Find-StudentHumanWordAnchors $chapter $path)) }
}
$investigation.HumanWordAnchors=@(foreach ($anchors in $wordAnchors.Values) { $anchors })
$teacherRoot=Join-Path $BankPath 'paired-teachers'
$investigation.Comparisons=@(if ($documents.Count -and (Test-Path -LiteralPath $teacherRoot)) {
    foreach ($directory in Get-ChildItem -LiteralPath $teacherRoot -Directory | Where-Object Name -NotLike '*.partial') {
        $r=[IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $directory.FullName 'observation.bin')))
        try {
            if ($r.ReadString() -cne 'StudentTeacherObservation/1') { throw 'Invalid teacher observation.' }
            $id=$r.ReadString()
        } finally { $r.Dispose() }
        if (!$documents.ContainsKey($id)) { continue }
        $comparison=[StudentSpeechComparison]::new()
        $comparison.Teacher=Open-StudentTeacherObservation $directory.FullName $documents[$id] -ZiraModule $ZiraModule
        foreach ($chapter in $investigation.HumanChapters) {
            if (![object]::ReferenceEquals($chapter.Document,$comparison.Teacher.Document) -or
                $comparison.Teacher.Start -lt $chapter.Start -or $comparison.Teacher.Start+$comparison.Teacher.Length -gt $chapter.Start+$chapter.Length) { continue }
            $comparison.HumanContext=$chapter
            if ($wordAnchors.ContainsKey($chapter.ChapterNumber)) {
                $comparison.HumanWordAnchors=@(foreach ($anchor in $wordAnchors[$chapter.ChapterNumber]) {
                    foreach ($token in $anchor.CandidateTokens) {
                        $offset=$chapter.Document.OriginalSpans[2*$token]
                        if ($offset -ge $comparison.Teacher.Start -and $offset -lt $comparison.Teacher.Start+$comparison.Teacher.Length) { $anchor; break }
                    }
                })
            }
            break
        }
        $comparison
    }
})
$investigation
