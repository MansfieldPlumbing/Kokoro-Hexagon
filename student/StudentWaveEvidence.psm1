using module ./StudentSourceInventory.psm1
#requires -Version 7.4

class StudentWaveEvidence {
    [StudentSourceUnit] $Source
    [string] $KernelHash
    [string] $DecoderHash
    [int] $Rate
    [int] $Hop
    [int] $Window
    [long] $Samples
    [float[]] $Rms
    [float[]] $PitchTriples
    [StudentSourceUnit[]] $AnnotationOwners
    [float[]] $AnnotationRms
    [float[]] $AnnotationPitch
    [int[]] $AnnotationFrameCounts
}

class StudentTimingCue {
    [StudentWaveEvidence] $Wave
    [StudentSourceUnit] $Annotation
    [int] $SourceLine
    [long] $FirstMillisecond
    [long] $LastMillisecond
    [int] $ComparedFrames
    [double] $Rms
}

class StudentConversationOverlap {
    [StudentWaveEvidence] $First
    [StudentWaveEvidence] $Second
    [int[]] $FirstAnnotations
    [int[]] $SecondAnnotations
    [long[]] $SampleStarts
    [long[]] $SampleEnds
    [float[]] $FirstRms
    [float[]] $SecondRms
}

class StudentTurnHypothesis {
    [StudentWaveEvidence] $Wave
    [int[]] $AnnotationOrdinals
    [long] $FirstSample
    [long] $EndSample
    [int] $MaxGapMilliseconds
    [StudentTurnHypothesis] $PrecedingOtherChannel
    [long] $GapFromOtherChannel
}

function Find-StudentTurnHypothesis {
    param(
        [StudentConversationOverlap] $Conversation,
        [ValidateRange(0,[int]::MaxValue)][int] $MaxGapMilliseconds = 400
    )
    $result = [Collections.Generic.List[StudentTurnHypothesis]]::new()
    foreach ($track in $Conversation.First,$Conversation.Second) {
        $indices = @(for ($i=0;$i -lt $track.AnnotationOwners.Length;$i++) {
            if ($track.AnnotationOwners[$i].Kind -ceq 'PublisherTranscriptWordSamples') { $i }
        })
        $indices = @($indices | Sort-Object { $track.AnnotationOwners[$_].Start })
        $gap = [long][Math]::Round($MaxGapMilliseconds*$track.Source.SampleRate/1000.0)
        $turn = $null
        $members = [Collections.Generic.List[int]]::new()
        foreach ($i in $indices) {
            $word = $track.AnnotationOwners[$i]
            if ($null -eq $turn -or $word.Start - $turn.EndSample -gt $gap) {
                if ($null -ne $turn) {
                    $turn.AnnotationOrdinals = $members.ToArray()
                    $result.Add($turn)
                    $members.Clear()
                }
                $turn = [StudentTurnHypothesis]::new()
                $turn.Wave = $track
                $turn.FirstSample = $word.Start
                $turn.MaxGapMilliseconds = $MaxGapMilliseconds
            }
            $turn.EndSample = [Math]::Max($turn.EndSample,$word.Start+$word.Length)
            $members.Add($i)
        }
        if ($null -ne $turn) {
            $turn.AnnotationOrdinals = $members.ToArray()
            $result.Add($turn)
        }
    }
    $priorA = $null
    $priorB = $null
    foreach ($turn in $result | Sort-Object FirstSample) {
        if ([object]::ReferenceEquals($turn.Wave,$Conversation.First)) {
            $turn.PrecedingOtherChannel = $priorB
            $priorA = $turn
        } else {
            $turn.PrecedingOtherChannel = $priorA
            $priorB = $turn
        }
        if ($turn.PrecedingOtherChannel) {
            $turn.GapFromOtherChannel = $turn.FirstSample - $turn.PrecedingOtherChannel.EndSample
        }
        $turn
    }
}

function Measure-StudentAnnotationOverlap {
    param([StudentWaveEvidence] $First, [StudentWaveEvidence] $Second)
    if ($First.Source.Kind -cne 'OriginalConversationChannel' -or $Second.Source.Kind -cne 'OriginalConversationChannel' -or
        [object]::ReferenceEquals($First.Source,$Second.Source) -or
        ![object]::ReferenceEquals($First.Source.Parent,$Second.Source.Parent) -or
        $First.Rate -ne $Second.Rate -or $First.Hop -ne $Second.Hop) {
        throw 'Select the separate channels of the same conversation on one analysis clock.'
    }
    $a = @(for ($i=0;$i -lt $First.AnnotationOwners.Length;$i++) {
        if ($First.AnnotationOwners[$i].Kind -ceq 'PublisherTranscriptWordSamples') { $i }
    })
    $b = @(for ($i=0;$i -lt $Second.AnnotationOwners.Length;$i++) {
        if ($Second.AnnotationOwners[$i].Kind -ceq 'PublisherTranscriptWordSamples') { $i }
    })
    $a = @($a | Sort-Object { $First.AnnotationOwners[$_].Start })
    $b = @($b | Sort-Object { $Second.AnnotationOwners[$_].Start })
    $firstIds=[Collections.Generic.List[int]]::new()
    $secondIds=[Collections.Generic.List[int]]::new()
    $starts=[Collections.Generic.List[long]]::new()
    $ends=[Collections.Generic.List[long]]::new()
    $firstPower=[Collections.Generic.List[float]]::new()
    $secondPower=[Collections.Generic.List[float]]::new()
    $cursor=0
    $scale=[double]$First.Rate/($First.Hop*$First.Source.SampleRate)
    foreach ($leftIndex in $a) {
        $left=$First.AnnotationOwners[$leftIndex]
        $leftEnd=$left.Start+$left.Length
        while ($cursor -lt $b.Count) {
            $right=$Second.AnnotationOwners[$b[$cursor]]
            if ($right.Start+$right.Length -gt $left.Start) { break }
            $cursor++
        }
        for ($j=$cursor;$j -lt $b.Count;$j++) {
            $right=$Second.AnnotationOwners[$b[$j]]
            if ($right.Start -ge $leftEnd) { break }
            $start=[Math]::Max($left.Start,$right.Start)
            $end=[Math]::Min($leftEnd,$right.Start+$right.Length)
            if ($end -le $start) { continue }
            $firstIds.Add($leftIndex)
            $secondIds.Add($b[$j])
            $starts.Add($start)
            $ends.Add($end)
            $from=[int][Math]::Ceiling($start*$scale)
            $to=[int][Math]::Min([Math]::Min($First.Rms.Length,$Second.Rms.Length),[Math]::Floor($end*$scale))
            $sumA=0.0
            $sumB=0.0
            for ($k=$from;$k -lt $to;$k++) {
                $sumA += [double]$First.Rms[$k]*$First.Rms[$k]
                $sumB += [double]$Second.Rms[$k]*$Second.Rms[$k]
            }
            $firstPower.Add($(if ($to -gt $from) { [Math]::Sqrt($sumA/($to-$from)) } else { [float]::NaN }))
            $secondPower.Add($(if ($to -gt $from) { [Math]::Sqrt($sumB/($to-$from)) } else { [float]::NaN }))
        }
    }
    $result=[StudentConversationOverlap]::new()
    $result.First=$First
    $result.Second=$Second
    $result.FirstAnnotations=$firstIds.ToArray()
    $result.SecondAnnotations=$secondIds.ToArray()
    $result.SampleStarts=$starts.ToArray()
    $result.SampleEnds=$ends.ToArray()
    $result.FirstRms=$firstPower.ToArray()
    $result.SecondRms=$secondPower.ToArray()
    $result
}

function Join-StudentProvisionalTiming {
    param([StudentWaveEvidence] $Wave, [StudentSourceUnit] $Annotation)
    if ($Wave.Source.Kind -cne 'PrivatePerformanceAudio' -or $Annotation.Kind -cne 'PrivatePerformanceReference') {
        throw 'Expected private waveform evidence and its provisional timing source.'
    }
    $stem = [IO.Path]::GetFileNameWithoutExtension($Wave.Source.Path)
    if ([IO.Path]::GetFileName($Annotation.Path) -cne "${stem}_PROVISIONAL_timestamps.srt") {
        throw 'The bundle filename does not nominate this recording.'
    }
    if ((Get-FileHash -LiteralPath $Annotation.Path).Hash -cne $Annotation.Checksum) { throw 'Timing source checksum mismatch.' }
    $line = 0
    $pattern = '^(\d\d):(\d\d):(\d\d),(\d{3})\s+-->\s+(\d\d):(\d\d):(\d\d),(\d{3})'
    foreach ($text in [IO.File]::ReadLines($Annotation.Path)) {
        $line++
        if ($text -cnotmatch $pattern) { continue }
        $cue = [StudentTimingCue]::new()
        $cue.Wave = $Wave
        $cue.Annotation = $Annotation
        $cue.SourceLine = $line
        $cue.FirstMillisecond = 3600000L*[int]$Matches[1]+60000L*[int]$Matches[2]+1000L*[int]$Matches[3]+[int]$Matches[4]
        $cue.LastMillisecond = 3600000L*[int]$Matches[5]+60000L*[int]$Matches[6]+1000L*[int]$Matches[7]+[int]$Matches[8]
        $first = [int][Math]::Ceiling($cue.FirstMillisecond*[double]$Wave.Rate/(1000*$Wave.Hop))
        $last = [int][Math]::Min($Wave.Rms.Length,[Math]::Floor($cue.LastMillisecond*[double]$Wave.Rate/(1000*$Wave.Hop)))
        $cue.Rms = [double]::NaN
        if ($first -ge 0 -and $last -gt $first) {
            $power = 0.0
            for ($i=$first;$i -lt $last;$i++) { $power += [double]$Wave.Rms[$i]*$Wave.Rms[$i] }
            $cue.ComparedFrames = $last-$first
            $cue.Rms = [Math]::Sqrt($power/$cue.ComparedFrames)
        }
        $cue
    }
}

function Open-StudentWaveEvidence {
    param([string] $Path, [StudentSourceInventory] $Inventory)
    $r = [IO.BinaryReader]::new([IO.File]::OpenRead((Convert-Path -LiteralPath $Path)))
    try {
        if ($r.ReadString() -cne 'StudentWaveEvidence/1') { throw 'Unknown waveform evidence format.' }
        $data = [StudentWaveEvidence]::new()
        $data.Source = $Inventory.Units.get_Item($r.ReadString())
        $data.KernelHash = $r.ReadString()
        $data.DecoderHash = $r.ReadString()
        $data.Rate = $r.ReadInt32()
        $data.Hop = $r.ReadInt32()
        $data.Window = $r.ReadInt32()
        $data.Samples = $r.ReadInt64()
        foreach ($property in 'Rms','PitchTriples') {
            $length = $r.ReadInt32()
            if ($length -lt 0 -or 4L*$length -gt $r.BaseStream.Length-$r.BaseStream.Position) { throw 'Invalid waveform array extent.' }
            $bytes = $r.ReadBytes(4*$length)
            $values = [float[]]::new($length)
            [Buffer]::BlockCopy($bytes,0,$values,0,$bytes.Length)
            $data.$property = $values
        }
        $count = $r.ReadInt32()
        if ($count -lt 0 -or $count -gt $data.Source.Children.Count) { throw 'Invalid annotation count.' }
        $data.AnnotationOwners = [StudentSourceUnit[]]::new($count)
        $data.AnnotationRms = [float[]]::new($count)
        $data.AnnotationPitch = [float[]]::new($count)
        $data.AnnotationFrameCounts = [int[]]::new($count)
        for ($i=0;$i -lt $count;$i++) {
            $unit = $Inventory.Units.get_Item($r.ReadString())
            if (![object]::ReferenceEquals($unit.Parent,$data.Source)) { throw 'Waveform annotation owner is on another source.' }
            $data.AnnotationOwners[$i] = $unit
            $data.AnnotationRms[$i] = $r.ReadSingle()
            $data.AnnotationPitch[$i] = $r.ReadSingle()
            $data.AnnotationFrameCounts[$i] = $r.ReadInt32()
        }
        if ($r.BaseStream.Position -ne $r.BaseStream.Length) { throw 'Trailing waveform evidence data.' }
        $data
    } finally { $r.Dispose() }
}

Export-ModuleMember -Function Open-StudentWaveEvidence, Join-StudentProvisionalTiming, Measure-StudentAnnotationOverlap, Find-StudentTurnHypothesis
