#requires -Version 7.4
# Typed speech evidence adapter for Providence. It does not manufacture word/phone
# alignment, causal claims, learned contours, or independent evidence lineages.

using namespace System.Collections.Generic

class ProvidenceContourObservation {
    [object] $OriginalOwner
    [object] $Source
    [string] $Renderer
    [string] $MeasuredQuantity = 'MonoPcm16Rms'
    [int] $SampleRate
    [int] $HopSamples
    [long] $Samples
    [double[]] $Shape = @()
    [double[]] $FrameRms = @()
    [double] $MeanRms
    [double] $PeakRms
    [string] $Coordinate = 'NormalizedWholeUtterance'
    [string] $EvidencePath

    [double[]] ReadCompleteFrames([long]$First100ns,[long]$End100ns) {
        $first=[long][Math]::Ceiling($First100ns*$this.SampleRate/(10000000.0*$this.HopSamples))
        $end=[long][Math]::Floor($End100ns*$this.SampleRate/(10000000.0*$this.HopSamples))
        if($first -lt 0 -or $end -le $first -or $end -gt $this.FrameRms.Length){return @()}
        $frames=[double[]]::new($end-$first)
        [Array]::Copy($this.FrameRms,$first,$frames,0,$frames.Length)
        return $frames
    }
}
class ProvidenceControlContour {
    [object] $Teacher
    [object] $Source
    [string] $Quantity
    [string] $Provenance = 'StockKokoroPredictor'
    [string] $Coordinate = 'GeneratorInputFrame80Hz'
    [int] $FrameCount
    [double] $Mean
    [double] $VoicedShare = [double]::NaN
    [double[]] $Shape = @()
}
class ProvidenceHumanIntervalCandidate {
    [object] $Anchor
    [object] $Document
    [object] $Recording
    [object] $WaveEvidence
    [ProvidenceTextOccurrence] $Occurrence
    [int] $SourceWordOccurrence
    [long] $First100ns
    [long] $End100ns
    [double] $MeanRms = [double]::NaN
    [string] $Status = 'RecognizerUtteranceBracketOnly'
}
class ProvidenceTextOccurrence {
    [object] $Teacher
    [object] $Document
    [object] $Sentence
    [int] $TokenIndex
    [int] $StartUtf16
    [int] $LengthUtf16
    [string] $OriginalSpelling
    [object[]] $Morphology = @()
    [object[]] $GrammarRelations = @()
    [ProvidenceZiraWordBearing[]] $ZiraBearings = @()
    [ProvidenceHumanIntervalCandidate[]] $HumanCandidates = @()
    [ProvidenceStockWordBearing] $StockBearing
    [string] $Alignment = 'ExactOriginalTextOccurrence; no inferred phone-to-sample boundary'
}
class ProvidenceStockWordBearing {
    [ProvidenceTextOccurrence] $Occurrence
    [ProvidenceZiraWordBearing] $SharedTextBearing
    [object] $Clock
    [int] $FirstGeneratorFrame
    [int] $EndGeneratorFrame
    [ProvidenceControlContour] $PredictedF0
}
class ProvidenceZiraWordBearing {
    [object] $WordEvent
    [ProvidenceTextOccurrence] $Occurrence
    [object[]] $PhoneEvents = @()
    [long] $First100ns
    [long] $End100ns
    [ProvidenceContourObservation] $Contour
    [double[]] $CompleteRmsFrames = @()
}
class ProvidencePassageComparison {
    [object] $Teacher
    [object] $SourceDocument
    [object] $Source
    [int] $SourceStartUtf16
    [int] $SourceLengthUtf16
    [object[]] $SourceWords = @()
    [ProvidenceTextOccurrence[]] $Occurrences = @()
    [object] $KokoroTokenClock
    [object] $ZiraEventStream
    [ProvidenceContourObservation] $Kokoro
    [ProvidenceContourObservation] $Zira
    [ProvidenceControlContour] $KokoroPredictedF0
    [ProvidenceControlContour] $KokoroPredictedNoise
    [ProvidenceHumanIntervalCandidate[]] $HumanCandidates = @()
    [string] $HumanRelation = 'Unresolved'
    [double] $WholeUtteranceEnvelopeDistance = [double]::NaN
    [string] $ComparisonCoordinate = 'NormalizedWholeUtterance, not word or phoneme aligned'
    [string[]] $Requirements = @()
}

function Measure-ProvidenceControlContour {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Array]$Values,[Parameter(Mandatory)][string]$Quantity,
          [object]$Teacher,[object]$Source,[ValidateRange(4,256)][int]$ShapeBins=32)
    $out=[ProvidenceControlContour]::new()
    $out.Teacher=$Teacher;$out.Source=$Source;$out.Quantity=$Quantity
    $out.FrameCount=$Values.Length
    $accum=[double[]]::new($ShapeBins);$counts=[long[]]::new($ShapeBins)
    $voiced=0L;$sum=0.0
    for($i=0;$i -lt $Values.Length;$i++){
        $x=[double]$Values.GetValue($i)
        if(![double]::IsFinite($x)){throw 'Nonfinite stock control value'}
        $sum+=$x;if($x -gt 0){$voiced++}
        $bin=[int][Math]::Min($ShapeBins-1,[Math]::Floor($i*$ShapeBins/[double]$Values.Length))
        $accum[$bin]+=$x;$counts[$bin]++
    }
    if($Values.Length){$out.Mean=$sum/$Values.Length}
    if($Quantity -ceq 'PredictedF0' -and $Values.Length){$out.VoicedShare=$voiced/[double]$Values.Length}
    $out.Shape=[double[]]::new($ShapeBins)
    for($i=0;$i -lt $ShapeBins;$i++){if($counts[$i]){$out.Shape[$i]=$accum[$i]/$counts[$i]}}
    return $out
}

function Read-ProvidencePcmContour {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Renderer,[object]$Owner,[object]$Source,
        [ValidateRange(4,256)][int]$ShapeBins=32)
    $reader=[IO.BinaryReader]::new([IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path))
    try {
        if($reader.ReadUInt32() -ne 0x46464952){throw 'Not RIFF'}
        $null=$reader.ReadUInt32()
        if($reader.ReadUInt32() -ne 0x45564157){throw 'Not WAVE'}
        $rate=0;$channels=0;$width=0;$format=0;$dataOffset=-1L;$dataBytes=0L
        while($reader.BaseStream.Position+8 -le $reader.BaseStream.Length){
            $tag=$reader.ReadUInt32();$length=[long]$reader.ReadUInt32();$at=$reader.BaseStream.Position
            if($at+$length -gt $reader.BaseStream.Length){throw 'Truncated WAV chunk'}
            if($tag -eq 0x20746d66 -and $length -ge 16){
                $format=$reader.ReadUInt16();$channels=$reader.ReadUInt16();$rate=[int]$reader.ReadUInt32()
                $null=$reader.ReadUInt32();$null=$reader.ReadUInt16();$width=$reader.ReadUInt16()
            } elseif($tag -eq 0x61746164){$dataOffset=$at;$dataBytes=$length}
            $reader.BaseStream.Position=$at+$length+($length%2)
        }
        if($format -ne 1 -or $channels -ne 1 -or $width -ne 16 -or $rate -le 0 -or $dataOffset -lt 0 -or $dataBytes%2){
            throw 'Only mono PCM16 WAV with a valid data chunk is supported'
        }
        $samples=[long]($dataBytes/2)
        $hop=[Math]::Max(1,[int][Math]::Round($rate/50.0))
        $frames=[long][Math]::Ceiling($samples/[double]$hop)
        $frameRms=[double[]]::new($frames)
        $energyByBin=[double[]]::new($ShapeBins)
        $framesByBin=[long[]]::new($ShapeBins)
        $totalEnergy=0.0;$peak=0.0;$readSamples=0L
        $reader.BaseStream.Position=$dataOffset
        for($frame=0L;$frame -lt $frames;$frame++){
            $count=[int][Math]::Min([long]$hop,$samples-$readSamples)
            $energy=0.0
            for($i=0;$i -lt $count;$i++){
                $v=$reader.ReadInt16()/32768.0
                $energy+=$v*$v
            }
            $readSamples+=$count
            $rms=[Math]::Sqrt($energy/$count)
            $frameRms[$frame]=$rms
            if($rms -gt $peak){$peak=$rms}
            $totalEnergy+=$energy
            $bin=[int][Math]::Min($ShapeBins-1,[Math]::Floor($frame*$ShapeBins/[double]$frames))
            $energyByBin[$bin]+=$energy;$framesByBin[$bin]+=$count
        }
        $mean=[Math]::Sqrt($totalEnergy/[Math]::Max(1,$samples))
        $shape=[double[]]::new($ShapeBins)
        for($i=0;$i -lt $ShapeBins;$i++){
            if($framesByBin[$i] -gt 0){$shape[$i]=[Math]::Sqrt($energyByBin[$i]/$framesByBin[$i])}
        }
        $out=[ProvidenceContourObservation]::new()
        $out.OriginalOwner=$Owner;$out.Source=$Source;$out.Renderer=$Renderer
        $out.SampleRate=$rate;$out.HopSamples=$hop;$out.Samples=$samples
        $out.Shape=$shape;$out.MeanRms=$mean;$out.PeakRms=$peak
        $out.FrameRms=$frameRms
        $out.EvidencePath=[IO.Path]::GetFullPath($Path)
        return $out
    } finally {$reader.Dispose()}
}

function Join-ProvidencePassage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Comparison,[ValidateRange(4,256)][int]$ShapeBins=32)
    $t=$Comparison.Teacher
    if($null -eq $t -or $null -eq $t.Document -or $null -eq $t.Document.Source){throw 'Teacher source ownership missing'}
    if(![IO.File]::Exists($t.KokoroWavePath) -or ![IO.File]::Exists($t.ZiraWavePath)){throw 'Original teacher WAVs are required'}
    $out=[ProvidencePassageComparison]::new()
    $out.Teacher=$t;$out.SourceDocument=$t.Document;$out.Source=$t.Document.Source
    $out.SourceStartUtf16=$t.Start;$out.SourceLengthUtf16=$t.Length
    $out.SourceWords=[object[]]@($t.WordOccurrenceIndices)
    $out.ZiraEventStream=$t.ZiraUtterance
    if($t.StockExecution){
        $out.KokoroTokenClock=$t.StockExecution.ObserveTokenClock()
    }
    $text=[IO.File]::ReadAllText($t.Document.Source.Path)
    $occurrences=[List[ProvidenceTextOccurrence]]::new()
    foreach($word in $t.WordOccurrenceIndices){
        $index=[int]$word
        if(2L*$index+1 -ge $t.Document.OriginalSpans.Length){throw 'Original word occurrence index outside source coordinate array'}
        $start=$t.Document.OriginalSpans[2*$index]
        $length=$t.Document.OriginalSpans[2*$index+1]
        if($start -lt $t.Start -or $start+$length -gt $t.Start+$t.Length -or
            $start -lt 0 -or $length -le 0 -or $start+$length -gt $text.Length){
            throw 'Word occurrence does not belong to exact teacher passage source extent'
        }
        $occ=[ProvidenceTextOccurrence]::new()
        $occ.Teacher=$t;$occ.Document=$t.Document
        $occ.TokenIndex=$index;$occ.StartUtf16=$start;$occ.LengthUtf16=$length
        $occ.OriginalSpelling=$text.Substring($start,$length)
        foreach($sentence in $t.Sentences){
            $sentenceIndex=[int]$sentence.Index
            if($sentenceIndex -lt 0 -or 2L*$sentenceIndex+1 -ge $t.Document.Sentences.Length){continue}
            $first=$t.Document.Sentences[2*$sentenceIndex]
            $last=$t.Document.Sentences[2*$sentenceIndex+1]
            if($index -lt $first -or $index -gt $last){continue}
            $occ.Sentence=$sentence
            $occ.Morphology=@(foreach($m in @($sentence.Morphology)){
                if($m.Occurrence -eq $index){$m}
            })
            $occ.GrammarRelations=@(foreach($g in @($sentence.Relations)){
                if($index -in $g.Occurrences){$g}
            })
            break
        }
        $occurrences.Add($occ)
    }
    $out.Occurrences=$occurrences.ToArray()
    $out.Kokoro=Read-ProvidencePcmContour -Path $t.KokoroWavePath -Renderer Kokoro -Owner $t -Source $out.Source -ShapeBins $ShapeBins
    $out.Zira=Read-ProvidencePcmContour -Path $t.ZiraWavePath -Renderer Zira -Owner $t -Source $out.Source -ShapeBins $ShapeBins
    if ($t.ZiraUtterance) {
        $bySpan=[Dictionary[string,ProvidenceTextOccurrence]]::new([StringComparer]::Ordinal)
        foreach ($occ in $out.Occurrences) { $bySpan["$($occ.StartUtf16)/$($occ.LengthUtf16)"]=$occ }
        $sampleEnd=10000000.0*$out.Zira.Samples/$out.Zira.SampleRate
        foreach ($word in $t.ZiraUtterance.Words) {
            if ($word.Start -lt 0 -or $word.Length -le 0 -or $word.Start+$word.Length -ge $t.InputSourceOffsets.Length) { continue }
            $first=$t.InputSourceOffsets[$word.Start]
            $last=$t.InputSourceOffsets[$word.Start+$word.Length-1]+1
            $occ=$null
            if (!$bySpan.TryGetValue("$first/$($last-$first)",[ref]$occ)) { continue }
            $phones=@(foreach ($phone in $word.PhoneEvents) {
                if ($phone.Ticks -ge 0 -and $phone.DurationTicks -gt 0 -and
                    $phone.Ticks+$phone.DurationTicks -le $sampleEnd) { $phone }
            })
            if (!$phones.Count -or $phones.Count -ne $word.PhoneEvents.Length) { continue }
            $bearing=[ProvidenceZiraWordBearing]::new()
            $bearing.WordEvent=$word
            $bearing.Occurrence=$occ
            $bearing.PhoneEvents=$phones
            $bearing.First100ns=($phones | Measure-Object Ticks -Minimum).Minimum
            $bearing.End100ns=($phones | Measure-Object { $_.Ticks+$_.DurationTicks } -Maximum).Maximum
            $bearing.Contour=$out.Zira
            $bearing.CompleteRmsFrames=$out.Zira.ReadCompleteFrames($bearing.First100ns,$bearing.End100ns)
            $occ.ZiraBearings+= $bearing
        }
    }
    $phonePositions=[List[int]]::new()
    $compact=[Text.StringBuilder]::new()
    for($i=0;$i -lt $t.Phones.Length;$i++){
        if([char]::IsWhiteSpace($t.Phones[$i])){continue}
        $phonePositions.Add($i)
        $null=$compact.Append($t.Phones[$i])
    }
    $ziraWords=@($t.ZiraUtterance.Words | Where-Object { $_.Phones })
    $sharedPhones=(($ziraWords.Phones -join '') -replace '\s','')
    $stockClockQualified=$sharedPhones -and $compact.ToString() -ceq $sharedPhones -and
        $out.KokoroTokenClock.Status -eq 'Agreement'
    # The existing reader normally opens only integer controls; borrow a fresh
    # temporary teacher with its original 12 retained arrays, then release it.
    # These are Kokoro's *predictions*, not measured Zira/human pitch.
    $full=$null
    if((Get-Command Open-StudentTeacherObservation -ErrorAction SilentlyContinue)){
        try {
            $full=Open-StudentTeacherObservation $t.Directory $t.Document -LoadTensors
            if($full.Tensors.ContainsKey('F0')){
                $out.KokoroPredictedF0=Measure-ProvidenceControlContour -Values $full.Tensors['F0'] `
                    -Quantity PredictedF0 -Teacher $t -Source $out.Source -ShapeBins $ShapeBins
                if($stockClockQualified){
                    $wordByEvent=[Dictionary[object,ProvidenceZiraWordBearing]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
                    foreach($occ in $out.Occurrences){foreach($bearing in $occ.ZiraBearings){$wordByEvent[$bearing.WordEvent]=$bearing}}
                    $position=0
                    $ticks=$out.KokoroTokenClock.TokenTicks
                    foreach($word in $ziraWords){
                        $width=($word.Phones -replace '\s','').Length
                        if(!$width){continue}
                        $first=$ticks[$phonePositions[$position]+1]
                        $end=$ticks[$phonePositions[$position+$width-1]+2]
                        $position+=$width
                        $wordBearing=$null
                        if($end -le $first -or !$wordByEvent.TryGetValue($word,[ref]$wordBearing)){continue}
                        $stock=[ProvidenceStockWordBearing]::new()
                        $stock.Occurrence=$wordBearing.Occurrence
                        $stock.SharedTextBearing=$wordBearing
                        $stock.Clock=$out.KokoroTokenClock
                        $stock.FirstGeneratorFrame=$first
                        $stock.EndGeneratorFrame=$end
                        $stock.PredictedF0=Measure-ProvidenceControlContour -Values $full.Tensors['F0'][$first..($end-1)] -Quantity PredictedF0 -Teacher $t -Source $out.Source -ShapeBins $ShapeBins
                        $wordBearing.Occurrence.StockBearing=$stock
                    }
                }
            }
            if($full.Tensors.ContainsKey('N')){
                $out.KokoroPredictedNoise=Measure-ProvidenceControlContour -Values $full.Tensors['N'] `
                    -Quantity PredictedNoise -Teacher $t -Source $out.Source -ShapeBins $ShapeBins
            }
        } finally {$full=$null}
    }
    if($out.Kokoro.Shape.Length -eq $ShapeBins -and $out.Zira.Shape.Length -eq $ShapeBins){
        # Compare the normalized broad RMS *shapes*, not phonemes/F0 or equal timestamps.
        $distance=0.0
        for($i=0;$i -lt $ShapeBins;$i++){
            $k=$out.Kokoro.Shape[$i]/[Math]::Max(1e-10,$out.Kokoro.MeanRms)
            $z=$out.Zira.Shape[$i]/[Math]::Max(1e-10,$out.Zira.MeanRms)
            $distance+=[Math]::Abs($k-$z)
        }
        $out.WholeUtteranceEnvelopeDistance=$distance/$ShapeBins
    }
    $wordSet=[HashSet[int]]::new()
    foreach($word in $t.WordOccurrenceIndices){$null=$wordSet.Add([int]$word)}
    $byToken=[Dictionary[int,ProvidenceTextOccurrence]]::new()
    foreach($occ in $out.Occurrences){$byToken[$occ.TokenIndex]=$occ}
    $human=[List[ProvidenceHumanIntervalCandidate]]::new()
    foreach($anchor in @($Comparison.HumanWordAnchors)){
        if(!$anchor -or !$anchor.Utterance -or !$anchor.Utterance.Chapter){continue}
        $chapter=$anchor.Utterance.Chapter
        if(![object]::ReferenceEquals($chapter.Document,$t.Document)){continue}
        foreach($candidate in @($anchor.CandidateTokens)){
            if(!$wordSet.Contains([int]$candidate)){continue}
            $entry=[ProvidenceHumanIntervalCandidate]::new()
            $entry.Anchor=$anchor;$entry.Document=$t.Document;$entry.SourceWordOccurrence=[int]$candidate
            $entry.Occurrence=$byToken[[int]$candidate]
            $entry.Recording=$chapter.Wave
            $entry.WaveEvidence=$chapter.Wave.Prosody
            $entry.First100ns=[long]$anchor.Utterance.DecodedStartTicks
            $entry.End100ns=[long]($anchor.Utterance.DecodedStartTicks+$anchor.Utterance.DecodedDurationTicks)
            if($anchor.CandidateTokens.Length -ne 1){$entry.Status='CompetingSourceWordLocations'}
            if($entry.End100ns -le $entry.First100ns){$entry.Status='InvalidUtteranceInterval'}
            $wave=$entry.WaveEvidence
            if($wave -and $wave.Rms -and $wave.Rate -gt 0 -and $wave.Hop -gt 0 -and
                $entry.End100ns -gt $entry.First100ns){
                $first=[int][Math]::Ceiling(($entry.First100ns/10000000.0)*$wave.Rate/$wave.Hop)
                $last=[int][Math]::Floor(($entry.End100ns/10000000.0)*$wave.Rate/$wave.Hop)
                $first=[Math]::Max(0,$first);$last=[Math]::Min($wave.Rms.Length,$last)
                if($last -gt $first){
                    $sum=0.0
                    for($i=$first;$i -lt $last;$i++){$sum+=[double]$wave.Rms[$i]}
                    $entry.MeanRms=$sum/($last-$first)
                }
            }
            $entry.Occurrence.HumanCandidates+= $entry
            $human.Add($entry)
        }
    }
    $out.HumanCandidates=$human.ToArray()
    $out.HumanRelation=if($out.HumanCandidates.Length){'Candidate recognizer utterance intervals; no phone or exact word alignment'}else{'No source-qualified human interval for this passage'}
    $needs=[List[string]]::new()
    $needs.Add('Kokoro/Zira contour correspondence: only normalized whole-passage energy has been measured')
    $needs.Add('Zira pitch/phone events require verified event clocks before phoneme/F0 comparisons')
    $needs.Add('Human expressive contour comparison requires independently verified source-to-audio word/phone alignment')
    if(!$out.HumanCandidates.Length){$needs.Add('Human performance alignment absent or ambiguous for this passage')}
    $out.Requirements=$needs.ToArray()
    return $out
}

Export-ModuleMember -Function Read-ProvidencePcmContour,Join-ProvidencePassage
