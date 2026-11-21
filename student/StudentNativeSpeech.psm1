using module ./StudentSourceInventory.psm1
using module ./StudentTextEvidence.psm1
using module ./StudentWaveEvidence.psm1
#requires -Version 7.4

class StudentNativeSpeech {
    [StudentSourceUnit] $Source
    [StudentWaveEvidence] $Prosody
    [string] $DecoderHash
    [int] $Rate
    [int] $Channels
    [int] $Hop = 1024
    [int] $SpectralWindow = 2048
    # Per frame and channel: centroid Hz, flatness, flux, rolloff Hz, RMS dBFS.
    [single[]] $Observations

    [single] Level([int] $Frame,[int] $Channel) {
        if ($Frame -lt 0 -or $Channel -lt 0 -or $Channel -ge $this.Channels -or
            (5L*$Frame + 5)*$this.Channels -gt $this.Observations.Length) {
            throw [ArgumentOutOfRangeException]::new('Frame or channel')
        }
        return $this.Observations[($Frame*$this.Channels+$Channel)*5+4]
    }
}

class StudentBoundaryHypothesis {
    [StudentNativeSpeech] $Wave
    [StudentSourceUnit] $Annotation
    [bool] $IsEnd
    [long] $PublisherSample
    [long[]] $CandidateSamples
    [single[]] $CandidateLevels
    [string] $Status
}

class StudentPerformanceInterval {
    [StudentNativeSpeech] $Recording
    [StudentBoundaryHypothesis] $Onset
    [StudentBoundaryHypothesis] $Release
    [int] $FirstInteriorFrame
    [int] $InteriorFrameCount
}

function Find-StudentPerformanceIntervals {
    param([StudentNativeSpeech] $Wave)
    $onset=$null
    foreach ($boundary in Find-StudentBoundaryHypotheses $Wave) {
        if ($boundary.Annotation.Kind -cne 'PublisherTranscriptEventSamples') { continue }
        if (!$boundary.IsEnd) { $onset=$boundary; continue }
        $interval=[StudentPerformanceInterval]::new()
        $interval.Recording=$Wave
        $interval.Onset=$onset
        $interval.Release=$boundary
        # Spectral stats include the preceding hop, and flux compares the previous spectral window.
        $first=[int][Math]::Ceiling(($onset.PublisherSample+$Wave.SpectralWindow)/[double]$Wave.Hop)
        $end=[int][Math]::Min($Wave.Observations.Length/(5*$Wave.Channels),
            1+[Math]::Floor(($boundary.PublisherSample-$Wave.Hop)/[double]$Wave.Hop))
        $interval.FirstInteriorFrame=$first
        $interval.InteriorFrameCount=[Math]::Max(0,$end-$first)
        $interval
    }
}

class StudentHumanChapter {
    [StudentNativeSpeech] $Wave
    [StudentTextEvidence] $Document
    [StudentHumanChapter] $Previous
    [StudentHumanChapter] $Next
    [int] $ChapterNumber
    [int] $Start
    [int] $Length
    [int] $FirstToken
    [int] $LastToken
}

class StudentLexicalPhoneHypothesis {
    [StudentSourceUnit] $Dictionary
    [string] $PublisherWord
    [StudentBoundaryHypothesis] $Onset
    [StudentBoundaryHypothesis] $Release
    [string[][]] $ArpabetAlternatives
}

class StudentRecognizedUtterance {
    [StudentHumanChapter] $Chapter
    [long] $DecodedStartTicks
    [long] $DecodedDurationTicks
}

class StudentHumanWordAnchor {
    [StudentRecognizedUtterance] $Utterance
    [string] $RecognizedWord
    [string] $RecognizerPronunciation
    [single] $RecognizerScore
    [int[]] $CandidateTokens
}

function Find-StudentHumanWordAnchors {
    param([StudentHumanChapter] $Chapter,[string] $Path)
    $r=[IO.BinaryReader]::new([IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path))
    try {
        if ($r.ReadString() -cnotin 'StudentHumanDictation/2','StudentHumanDictation/3' -or
            $r.ReadString() -cne $Chapter.Wave.Source.Id -or $r.ReadString() -cne $Chapter.Wave.Source.Checksum) {
            throw 'Dictation belongs to a different recording.'
        }
        $null=$r.ReadString()
        $null=$r.ReadString()
        $null=$r.ReadString()
        $observed=[Collections.Generic.List[StudentHumanWordAnchor]]::new()
        while ($r.BaseStream.Position -lt $r.BaseStream.Length) {
            $utterance=[StudentRecognizedUtterance]::new()
            $utterance.Chapter=$Chapter
            $utterance.DecodedStartTicks=$r.ReadInt64()
            $utterance.DecodedDurationTicks=$r.ReadInt64()
            $count=$r.ReadInt32()
            if ($count -lt 1 -or $count -gt $r.BaseStream.Length-$r.BaseStream.Position) { throw 'Invalid recognizer utterance extent.' }
            for ($i=0;$i -lt $count;$i++) {
                $word=[StudentHumanWordAnchor]::new()
                $word.Utterance=$utterance
                $word.RecognizedWord=$r.ReadString()
                $word.RecognizerPronunciation=$r.ReadString()
                $word.RecognizerScore=$r.ReadSingle()
                $word.CandidateTokens=[int[]]::new(0)
                $observed.Add($word)
            }
        }
    } finally { $r.Dispose() }
    $doc=$Chapter.Document
    $source=[IO.File]::ReadAllText($doc.Source.Path)
    $words=[Collections.Generic.List[string]]::new()
    $tokens=[Collections.Generic.List[int]]::new()
    for ($i=$Chapter.FirstToken;$i -le $Chapter.LastToken;$i++) {
        if ($doc.Tokens[4*$i] -ne 1) { continue }
        $form=$source.Substring($doc.OriginalSpans[2*$i],$doc.OriginalSpans[2*$i+1])
        $words.Add($form.ToLowerInvariant().Replace([char]0x2019,[char]39))
        $tokens.Add($i)
    }
    $index=[Collections.Generic.Dictionary[string,Collections.Generic.List[int]]]::new([StringComparer]::Ordinal)
    for ($i=1;$i+1 -lt $words.Count;$i++) {
        $key=$words[$i-1]+' '+$words[$i]+' '+$words[$i+1]
        if (!$index.ContainsKey($key)) { $index.Add($key,[Collections.Generic.List[int]]::new()) }
        $index[$key].Add($tokens[$i])
    }
    for ($i=1;$i+1 -lt $observed.Count;$i++) {
        $key=($observed[$i-1].RecognizedWord+' '+$observed[$i].RecognizedWord+' '+$observed[$i+1].RecognizedWord).ToLowerInvariant().Replace([char]0x2019,[char]39)
        if ($index.ContainsKey($key)) { $observed[$i].CandidateTokens=$index[$key].ToArray() }
    }
    $observed.ToArray()
}

function Join-StudentDramaticChapters {
    param([StudentTextEvidence] $Document,[StudentNativeSpeech[]] $Tracks)
    if ($Document.Source.EvidenceGroup -cne 'Gutenberg/11') { throw 'Expected the edition referenced by the dramatic recording.' }
    $text=[IO.File]::ReadAllText($Document.Source.Path)
    $headings=[regex]::Matches($text,'(?m)^CHAPTER (I|II|III|IV|V|VI|VII|VIII|IX|X|XI|XII)\. [^\r\n]+')
    $end=$text.IndexOf('*** END OF',[StringComparison]::Ordinal)
    if ($headings.Count -ne 12 -or $end -le $headings[11].Index) { throw 'Unexpected chapter structure in the original edition.' }
    $chapters=[Collections.Generic.SortedDictionary[int,StudentHumanChapter]]::new()
    foreach ($track in $Tracks) {
        if ($track.Source.Kind -cne 'OriginalHumanAudio' -or
            ![object]::ReferenceEquals($track.Source.Parent.CorrespondingText,$Document.Source)) { continue }
        if ([IO.Path]::GetFileName($track.Source.Path) -cnotmatch '^aliceinwonderland_(\d\d)_carroll\.mp3$') { continue }
        $number=[int]$Matches[1]
        if ($number -lt 1 -or $number -gt $headings.Count) { continue }
        $start=$headings[$number-1].Index
        $stop=if ($number -lt $headings.Count) {$headings[$number].Index} else {$end}
        $first=-1
        $last=-1
        for ($i=0;$i -lt $Document.OriginalSpans.Length/2;$i++) {
            $offset=$Document.OriginalSpans[2*$i]
            if ($offset -lt $start -or $offset -ge $stop) { continue }
            if ($first -lt 0) { $first=$i }
            $last=$i
        }
        $chapter=[StudentHumanChapter]::new()
        $chapter.Wave=$track
        $chapter.Document=$Document
        $chapter.ChapterNumber=$number
        $chapter.Start=$start
        $chapter.Length=$stop-$start
        $chapter.FirstToken=$first
        $chapter.LastToken=$last
        $chapters.Add($number,$chapter)
    }
    foreach ($chapter in $chapters.Values) {
        if ($chapters.ContainsKey($chapter.ChapterNumber-1)) { $chapter.Previous=$chapters[$chapter.ChapterNumber-1] }
        if ($chapters.ContainsKey($chapter.ChapterNumber+1)) { $chapter.Next=$chapters[$chapter.ChapterNumber+1] }
        $chapter
    }
}

function Get-StudentArpabetAlternatives {
    param([StudentSourceUnit] $Dictionary,[Collections.Generic.HashSet[string]] $Words)
    if ($Dictionary.Id -cne 'StudentLexicon/cmudict.dict' -or
        (Get-FileHash -LiteralPath $Dictionary.Path).Hash -cne $Dictionary.Checksum) { throw 'Expected the retained pronunciation dictionary.' }
    $readings=[Collections.Generic.Dictionary[string,Collections.Generic.List[string[]]]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [IO.File]::ReadLines($Dictionary.Path)) {
        if ($line -cnotmatch '^(\S+?)(?:\(\d+\))? (.+)$') { continue }
        $key=$Matches[1]
        if (!$words.Contains($key)) { continue }
        if (!$readings.ContainsKey($key)) { $readings.Add($key,[Collections.Generic.List[string[]]]::new()) }
        $readings[$key].Add($Matches[2].Split(' ',[StringSplitOptions]::RemoveEmptyEntries))
    }
    $pool=[Collections.Generic.Dictionary[string,string[][]]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $readings.Keys) { $pool.Add($key,$readings[$key].ToArray()) }
    ,$pool
}

function Join-StudentConversationPhones {
    param([StudentNativeSpeech] $Wave,[StudentSourceUnit] $Dictionary)
    if (!$Wave.Source.CorrespondingText -or
        (Get-FileHash -LiteralPath $Wave.Source.CorrespondingText.Path).Hash -cne $Wave.Source.CorrespondingText.Checksum) {
        throw 'Published conversation text no longer matches its original revision.'
    }
    $metadata=Get-Content -LiteralPath $Wave.Source.CorrespondingText.Path -Raw | ConvertFrom-Json -AsHashtable
    $side=if ($Wave.Source.Id.EndsWith('.a.flac',[StringComparison]::Ordinal)) {'a'} elseif ($Wave.Source.Id.EndsWith('.b.flac',[StringComparison]::Ordinal)) {'b'} else {throw 'Expected an Open Yap channel.'}
    $labels=$metadata.transcripts[$side].words
    $words=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $keys=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($unit in $Wave.Source.Children) {
        if ($unit.Kind -cne 'PublisherTranscriptWordSamples') { continue }
        $ordinal=[int]$unit.Id.Substring($unit.Id.LastIndexOf('/')+1)
        if ($ordinal -ge $labels.Length) { throw 'Missing original publisher word label.' }
        $key=([string]$labels[$ordinal].word).ToLowerInvariant()
        $keys.Add($unit.Id,$key)
        $null=$words.Add($key)
    }
    $pool=Get-StudentArpabetAlternatives $Dictionary $words
    $onset=$null
    foreach ($boundary in Find-StudentBoundaryHypotheses $Wave) {
        if (!$keys.ContainsKey($boundary.Annotation.Id)) { continue }
        if (!$boundary.IsEnd) { $onset=$boundary; continue }
        $candidate=[StudentLexicalPhoneHypothesis]::new()
        $candidate.Dictionary=$Dictionary
        $candidate.Onset=$onset
        $candidate.Release=$boundary
        $candidate.PublisherWord=$keys[$boundary.Annotation.Id]
        $candidate.ArpabetAlternatives=$pool[$candidate.PublisherWord]
        $candidate
    }
}
function Open-StudentNativeSpeech {
    param([string] $Path,[StudentSourceInventory] $Inventory)
    $r=[IO.BinaryReader]::new([IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path))
    try {
        if ($r.ReadString() -cne 'StudentNativeSpeech/1') { throw 'Invalid native evidence signature.' }
        $obj=[StudentNativeSpeech]::new()
        $obj.Source=$Inventory.Units.get_Item($r.ReadString())
        if ($r.ReadString() -cne $obj.Source.Checksum) { throw 'Native evidence belongs to a different source revision.' }
        $obj.DecoderHash=$r.ReadString()
        $obj.Rate=$r.ReadInt32()
        $obj.Channels=$r.ReadInt32()
        $size=$r.BaseStream.Length-$r.BaseStream.Position
        if ($obj.Rate -le 0 -or $obj.Channels -le 0 -or !$size -or $size % (20L*$obj.Channels) -or $size -gt [int]::MaxValue) {
            throw 'Invalid native evidence shape.'
        }
        $bytes=$r.ReadBytes([int]$size)
        $obj.Observations=[single[]]::new($bytes.Length/4)
        [Buffer]::BlockCopy($bytes,0,$obj.Observations,0,$bytes.Length)
        $obj
    } finally { $r.Dispose() }
}

function Find-StudentBoundaryHypotheses {
    param([StudentNativeSpeech] $Wave,[ValidateRange(1,1000)][int] $RadiusMilliseconds=60)
    if ($Wave.Source.SampleRate -ne $Wave.Rate -or $Wave.Channels -ne 1) {
        throw 'Boundary comparisons require the publisher annotation clock on a single native channel.'
    }
    $frames=[int]($Wave.Observations.Length/5)
    foreach ($label in $Wave.Source.Children) {
        if ($label.Kind -cnotin 'PublisherTranscriptWordSamples','PublisherTranscriptEventSamples') { continue }
        foreach ($isEnd in $false,$true) {
            $answer=[StudentBoundaryHypothesis]::new()
            $answer.Annotation=$label
            $answer.Wave=$Wave
            $answer.IsEnd=$isEnd
            $answer.PublisherSample=if ($isEnd) {$label.Start+$label.Length} else {$label.Start}
            $radius=$RadiusMilliseconds*$Wave.Rate/1000.0
            $first=[Math]::Max(1,[int][Math]::Ceiling(($answer.PublisherSample-$radius)/$Wave.Hop-0.5))
            $last=[Math]::Min($frames-2,[int][Math]::Floor(($answer.PublisherSample+$radius)/$Wave.Hop-0.5))
            $samples=[Collections.Generic.List[long]]::new()
            $levels=[Collections.Generic.List[single]]::new()
            for ($frame=$first;$frame -le $last;$frame++) {
                $current=$Wave.Level($frame,0)
                if ([single]::IsFinite($current) -and $current -lt $Wave.Level($frame-1,0) -and $current -lt $Wave.Level($frame+1,0)) {
                    $samples.Add([long]($frame*$Wave.Hop+$Wave.Hop/2))
                    $levels.Add($current)
                }
            }
            $answer.CandidateSamples=$samples.ToArray()
            $answer.CandidateLevels=$levels.ToArray()
            $answer.Status=if ($samples.Count -gt 1) {'CompetingEnergyMinima'} elseif ($samples.Count) {'SingleEnergyMinimumUnverified'} else {'NoEnergyMinimum'}
            $answer
        }
    }
}

Export-ModuleMember -Function Open-StudentNativeSpeech,Find-StudentBoundaryHypotheses,Join-StudentDramaticChapters,Join-StudentConversationPhones,Find-StudentHumanWordAnchors,Find-StudentPerformanceIntervals,Get-StudentArpabetAlternatives
