using module ./StudentSourceInventory.psm1
using module ./StudentTextEvidence.psm1
using module ./StudentWaveEvidence.psm1
#requires -Version 7.4

param([string] $BankPath = (Join-Path $PSScriptRoot '../data/source-bank'))
$ErrorActionPreference = 'Stop'

function Assert-SameObject($Actual,$Expected,[string] $Context) {
    if (![object]::ReferenceEquals($Actual,$Expected)) { throw "Object identity mismatch: $Context" }
}

$inventory = Open-StudentSourceInventory (Join-Path $BankPath 'sources.bin')
foreach ($unit in $inventory.Units.Values) {
    if ($unit.Path -and (Get-FileHash -LiteralPath $unit.Path).Hash -cne $unit.Checksum) {
        throw 'A retained source file has changed.'
    }
    if ($unit.Parent) {
        Assert-SameObject $unit.Parent $inventory.Units[$unit.Parent.Id] 'parent'
        if (!$unit.Parent.Children.Contains($unit)) { throw 'A reverse source relationship is missing.' }
    }
    if ($unit.CorrespondingText) {
        Assert-SameObject $unit.CorrespondingText $inventory.Units[$unit.CorrespondingText.Id] 'text link'
    }
}

$documents = @(Get-ChildItem -LiteralPath (Join-Path $BankPath 'linguistic') -File -Filter 'pg*.bin' | ForEach-Object {
    $doc = Open-StudentTextEvidence $_.FullName $inventory
    Assert-SameObject $doc.Source $inventory.Units[$doc.Source.Id] 'document source'
    if ($doc.Tokens.Length % 4 -or $doc.OriginalSpans.Length*2 -ne $doc.Tokens.Length) { throw 'Invalid document token layout.' }
    foreach ($issue in $doc.Issues) { Assert-SameObject $issue.Document $doc 'diagnostic document' }
    foreach ($sentence in $doc.Interpretations) {
        Assert-SameObject $sentence.Document $doc 'sentence document'
        if ($sentence.OccurrenceRanges.Length -ne 2*$sentence.Readings.Length) { throw 'Invalid sentence occurrence layout.' }
        foreach ($reading in $sentence.Morphology) { Assert-SameObject $reading.Sentence $sentence 'morphology owner' }
        foreach ($relation in $sentence.Relations) { Assert-SameObject $relation.Sentence $sentence 'grammar owner' }
    }
    $doc
})
if ($documents.Count -ne 4) { throw 'Expected all four expanded text works.' }
$alice = @($documents | Where-Object { $_.Source.EvidenceGroup -ceq 'Gutenberg/11' })[0]
if ($alice.Interpretations.Length*2 -ne $alice.Sentences.Length -or !$alice.Issues.Length) {
    throw 'Alice sentence interpretations or raw-input diagnostics are incomplete.'
}
$wordStudy = @($documents | Where-Object { $_.Source.EvidenceGroup -ceq 'Gutenberg/30036' })[0]
if ($wordStudy.Interpretations.Length*2 -ne $wordStudy.Sentences.Length) {
    throw 'Word Study and English Grammar sentence interpretations are incomplete.'
}

$tracks = @(Get-ChildItem -LiteralPath (Join-Path $BankPath 'waveform') -File -Filter '*.bin' | ForEach-Object {
    $track = Open-StudentWaveEvidence $_.FullName $inventory
    Assert-SameObject $track.Source $inventory.Units[$track.Source.Id] 'waveform source'
    if ($track.Rms.Length -ne [Math]::Floor($track.Samples/[double]$track.Hop) -or $track.PitchTriples.Length % 3) {
        throw 'Waveform array layout disagrees with its analysis clock.'
    }
    foreach ($annotation in $track.AnnotationOwners) {
        Assert-SameObject $annotation $inventory.Units[$annotation.Id] 'annotation source'
        Assert-SameObject $annotation.Parent $track.Source 'annotation clock'
    }
    $track
})
$expected = @($inventory.Units.Values | Where-Object Kind -In 'OriginalHumanAudio','OriginalConversationChannel','PrivatePerformanceAudio')
if (@($tracks.Source.Id | Sort-Object -Unique).Count -ne $expected.Count -or $tracks.Count -ne $expected.Count) {
    throw 'Waveform coverage is incomplete or has duplicate sources.'
}
$channels = @($tracks | Where-Object {$_.Source.Kind -ceq 'OriginalConversationChannel'} | Sort-Object {$_.Source.Id})
$overlap = Measure-StudentAnnotationOverlap $channels[0] $channels[1]
if (!$overlap.FirstRms.Length) { throw 'Expected candidate overlap intervals.' }
$turns = @(Find-StudentTurnHypothesis $overlap)
$words = 0
foreach ($turn in $turns) {
    $words += $turn.AnnotationOrdinals.Length
    if ($turn.PrecedingOtherChannel -and [object]::ReferenceEquals($turn.Wave,$turn.PrecedingOtherChannel.Wave)) {
        throw 'A proposed turn transition links the same channel.'
    }
}
$publisherWords = @($inventory.Units.Values | Where-Object Kind -CEQ PublisherTranscriptWordSamples)
if ($words -ne $publisherWords.Count) { throw 'Turn hypotheses omitted or duplicated word labels.' }
"Verified $($inventory.Units.Count) original index entries, $($documents.Count) text works and $($tracks.Count) waveform tracks."
"Verified $($alice.Interpretations.Count + $wordStudy.Interpretations.Count) sentence records, $($overlap.FirstRms.Length) candidate overlaps and $($turns.Count) turn hypotheses."
