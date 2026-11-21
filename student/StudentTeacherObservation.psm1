using module ./StudentSourceInventory.psm1
using module ./StudentTextEvidence.psm1
#requires -Version 7.4

class StudentTeacherObservation {
    [StudentTextEvidence] $Document
    [StudentSentenceEvidence[]] $Sentences
    [int[]] $WordOccurrenceIndices
    [int] $Start
    [int] $Length
    [string] $InputText
    [int[]] $InputSourceOffsets
    [string] $Phones
    [string] $Configuration
    [string] $Directory
    [long] $KokoroSamples
    [string] $KokoroWavePath
    [string] $ZiraWavePath
    [object] $ZiraUtterance
    [string[]] $Names
    [int[]] $Lengths
    [int[]] $StockTokenTickStarts
    [Collections.Generic.Dictionary[string,Array]] $Tensors
    [StudentStockExecution] $StockExecution
    [StudentStockExecution] $ProceduralExecution
    [StudentResidualIntervention[]] $ResidualInterventions
    [StudentUnresolvedProceduralPronunciation[]] $UnresolvedProceduralPronunciations
}

class StudentUnresolvedProceduralPronunciation {
    [StudentTeacherObservation] $Teacher
    [string] $Attempt
    [string] $Reason
}

class StudentResidualIntervention {
    [StudentStockExecution] $Baseline
    [StudentStockExecution] $Outcome
    [string] $Site
    [string] $Intention
    [StudentStockActivation] $BaselineCorrection
    [StudentStockActivation] $BaselineResidualSum
    [StudentStockActivation] $WithheldCorrection

    [bool] ChangedWaveform() { return $this.Baseline.Waveform.Checksum -cne $this.Outcome.Waveform.Checksum }
}

enum StudentExecutionClockStatus { MissingEndpoints; MissingTokenClock; UnresolvedGrid; Contradiction; Agreement }

class StudentExecutionClockBearing {
    [StudentStockExecution] $Execution
    [StudentStockActivation] $Durations
    [int[]] $TokenTicks
    [StudentExecutionClockStatus] $Status
}

class StudentStockExecution {
    [StudentTeacherObservation] $Teacher
    [string] $Recipe
    [StudentStockActivation[]] $Activations
    [StudentStockNormalization[]] $Normalizations
    [StudentAlbertApplication[]] $AlbertApplications
    [StudentStockConvolution[]] $Convolutions
    [StudentStockActivation] $GeneratorInput
    [StudentStockActivation] $Waveform
    [StudentStockExecution] $FrontStateReplay

    [StudentStockActivation] DurationActivation() {
        foreach ($candidate in $this.Activations) {
            if ($candidate.Stage -cin 'procedural.duration.realized','predictor.durations') { return $candidate }
        }
        return $null
    }

    [int[]] BuildTokenTickStarts([StudentStockActivation] $DurationActivation) {
        if ([object]::ReferenceEquals($this,$this.Teacher.StockExecution)) { return $this.Teacher.StockTokenTickStarts }
        if (!$DurationActivation) { return $null }
        $durations=[int[]]$DurationActivation.Read()
        $starts=[int[]]::new($durations.Length+1)
        for ($i=0;$i -lt $durations.Length;$i++) { $starts[$i+1]=$starts[$i]+2*$durations[$i] }
        return $starts
    }

    [int[]] TokenTickStarts() {
        if ([object]::ReferenceEquals($this,$this.Teacher.StockExecution)) { return $this.Teacher.StockTokenTickStarts }
        $starts=$this.BuildTokenTickStarts($this.DurationActivation())
        if (!$starts) { throw 'Execution has no retained durations.' }
        if ($starts[-1] -ne $this.GeneratorInput.Extent) { throw 'Execution token clock disagrees with the generator clock.' }
        return $starts
    }

    [StudentExecutionClockBearing] ObserveTokenClock() {
        $result=[StudentExecutionClockBearing]::new()
        $result.Execution=$this
        if (!$this.GeneratorInput -or !$this.Waveform) {
            $result.Status=[StudentExecutionClockStatus]::MissingEndpoints
            return $result
        }
        $result.Durations=$this.DurationActivation()
        $result.TokenTicks=$this.BuildTokenTickStarts($result.Durations)
        if (!$result.TokenTicks) {
            $result.Status=[StudentExecutionClockStatus]::MissingTokenClock
            return $result
        }
        $grid=$this.GeneratorInput.FrameClock()
        $wave=$this.Waveform.FrameClock()
        if (!$grid -or !$wave -or $wave.SamplesPerFrame -ne 1 -or $grid.SampleRate -ne $wave.SampleRate) {
            $result.Status=[StudentExecutionClockStatus]::UnresolvedGrid
        } elseif ($result.TokenTicks[-1] -ne $grid.FrameCount -or
            [long]$grid.FrameCount * $grid.SamplesPerFrame -ne $wave.FrameCount) {
            $result.Status=[StudentExecutionClockStatus]::Contradiction
        } else {
            $result.Status=[StudentExecutionClockStatus]::Agreement
            for ($i=1;$i -lt $result.TokenTicks.Length;$i++) {
                if ($result.TokenTicks[$i] -lt $result.TokenTicks[$i-1]) {
                    $result.Status=[StudentExecutionClockStatus]::Contradiction
                    break
                }
            }
        }
        return $result
    }
}

class StudentStockConvolution {
    [StudentStockActivation] $Geometry
    [StudentStockActivation] $Output

    [int[]] InputFramesForOutput([int] $Frame) {
        if ($Frame -lt 0 -or $Frame -ge $this.Output.Extent) { throw 'Frame is outside the convolution output.' }
        $dimensions=[int[]]$this.Geometry.Read()
        $positions=[Collections.Generic.List[int]]::new()
        for ($tap=0;$tap -lt $dimensions[3];$tap++) {
            if ($dimensions[8]) {
                $position=$Frame+$dimensions[5]-$tap*$dimensions[6]
                if ($position%$dimensions[4]) { continue }
                $position=[int]($position/$dimensions[4])
            } else { $position=$Frame*$dimensions[4]-$dimensions[5]+$tap*$dimensions[6] }
            if ($position -ge 0 -and $position -lt $dimensions[0]) { $positions.Add($position) }
        }
        return $positions.ToArray()
    }
}

class StudentAlbertApplication {
    [StudentStockExecution] $Execution
    [int] $Application
    [StudentStockActivation] $Attention
    [StudentStockActivation] $AttentionContext
    [StudentStockActivation] $Hidden
}

class StudentStockNormalization {
    [StudentStockExecution] $Execution
    [string] $Site
    [StudentStockActivation] $Input
    [StudentStockActivation] $Output
    [StudentStockActivation] $Parameters
    [StudentStockActivation] $TokenAccumulators
    [StudentStockActivation] $TokenFrames
    [StudentStockActivation] $Geometry

    [int] ChannelCount() { return $this.Parameters.Extent }
    [int] ScopeFrameCount() { return $this.Input.Extent }
    [single] Epsilon() { return [single]0.00001 }
}

enum StudentStockClockBasis { DeclaredAxis; ExecutionExtent }

class StudentStockFrameClock {
    [StudentStockActivation] $Owner
    [StudentStockClockBasis] $Basis
    [StudentStockActivation] $ExtentReference
    [int] $FrameCount
    [int] $SamplesPerFrame
    [int] $SampleRate = 24000
    [int] $ReflectedPrefixFrames

    [long] SampleGridOffset([int] $Frame) {
        if ($Frame -lt 0 -or $Frame -ge $this.FrameCount) { throw 'Frame is outside the captured axis.' }
        return [long]$Frame*$this.SamplesPerFrame
    }
}

class StudentStockActivation {
    [StudentStockExecution] $Execution
    [string] $Stage
    [string] $Axes
    [int] $Extent
    [int] $Count
    [byte] $TypeCode
    [string] $Checksum
    [string] $Path

    [StudentStockFrameClock] FrameClock() {
        $hop=0
        $prefix=0
        $reference=$null
        if ($this.Axes.Contains('sample@24000',[StringComparison]::Ordinal)) { $hop=1 }
        elseif ($this.Axes.Contains('frame@80',[StringComparison]::Ordinal)) { $hop=300 }
        elseif ($this.Axes.Contains('frame@40',[StringComparison]::Ordinal)) { $hop=600 }
        elseif ($this.Axes -ceq 'channel,frame' -and $this.Execution.GeneratorInput) {
            $reference=$this.Execution.GeneratorInput
            $ticks=$reference.Extent
            if ($this.Extent -eq $ticks) { $hop=300 }
            elseif (2*$this.Extent -eq $ticks) { $hop=600 }
            elseif ($this.Extent -eq 10*$ticks) { $hop=30 }
            elseif ($this.Extent -eq 60*$ticks -or $this.Extent -eq 60*$ticks+1) {
                $hop=5
                if ($this.Extent -eq 60*$ticks+1 -and
                    ($this.Stage.StartsWith('generator.stage.1.',[StringComparison]::Ordinal) -or
                     $this.Stage -cmatch '^(decoder\.module\.)?generator\.resblocks\.[345]\.' -or
                     $this.Stage -ceq 'decoder.module.generator.conv_post')) { $prefix=1 }
            }
        }
        if (!$hop) { return $null }
        $clock=[StudentStockFrameClock]::new()
        $clock.Owner=$this
        if ($reference) {
            $clock.Basis=[StudentStockClockBasis]::ExecutionExtent
            $clock.ExtentReference=$reference
        }
        $clock.FrameCount=$this.Extent
        $clock.SamplesPerFrame=$hop
        $clock.ReflectedPrefixFrames=$prefix
        return $clock
    }

    [int[]] Shape() {
        if ($this.Axes -ceq 'head,queryToken,keyToken') { return [int[]]@(12,$this.Extent,$this.Extent) }
        if ($this.Axes -ceq 'harmonic-or-noise,sample@24000,harmonic') { return [int[]]@(2,$this.Extent,9) }
        if ($this.Axes -ceq 'direction,channel,token') { return [int[]]@(2,256,$this.Extent) }
        if ($this.Axes -ceq 'sample@24000,harmonic') { return [int[]]@($this.Extent,9) }
        if ($this.Axes -cin 'direction,token,gateOrState,channel','direction,frame@40,gateOrState,channel') {
            return [int[]]@(2,$this.Extent,6,[int]($this.Count/(12*$this.Extent)))
        }
        if ($this.Axes -ceq 'channel,frame' -or $this.Axes -ceq 'channel,token' -or $this.Axes -ceq 'channel,whole-invocation') {
            return [int[]]@([int]($this.Count/$this.Extent),$this.Extent)
        }
        if ($this.Axes -ceq 'token,channel' -or $this.Axes -ceq 'frame@40,channel' -or $this.Axes -ceq 'styleRow,channel') {
            return [int[]]@($this.Extent,[int]($this.Count/$this.Extent))
        }
        return [int[]]@($this.Count)
    }

    [Array] Read() {
        $values = switch ($this.TypeCode) {
            1 { , [single[]]::new($this.Count) }
            2 { , [double[]]::new($this.Count) }
            3 { , [int[]]::new($this.Count) }
            default { throw 'Invalid stock tensor element type.' }
        }
        $bytes = [byte[]]::new([Buffer]::ByteLength($values))
        $file = [IO.File]::OpenRead($this.Path)
        try {
            $gzip = [IO.Compression.GZipStream]::new($file,[IO.Compression.CompressionMode]::Decompress)
            try {
                $gzip.ReadExactly($bytes)
                if ($gzip.ReadByte() -ne -1) { throw 'Unexpected tensor length.' }
            } finally { $gzip.Dispose() }
        } finally { $file.Dispose() }
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $this.Checksum) { throw 'Stock tensor hash mismatch.' }
        [Buffer]::BlockCopy($bytes,0,$values,0,$bytes.Length)
        return $values
    }
}

function Get-StudentStockBufferRoots([string] $BankPath) {
    Join-Path $BankPath 'stock-activation-buffers'
    $config=Join-Path $BankPath 'stock-activation-roots.txt'
    if ([IO.File]::Exists($config)) {
        foreach ($root in [IO.File]::ReadLines($config)) {
            if (![IO.Path]::IsPathFullyQualified($root)) { throw 'Stock activation roots must be absolute paths.' }
            $root
        }
    }
}

function Open-StudentStockExecution([StudentTeacherObservation] $Teacher,[string] $Name='stock-execution.bin') {
    $path = Join-Path $Teacher.Directory $Name
    if (![IO.File]::Exists($path)) { return }
    $execution = [StudentStockExecution]::new()
    $execution.Teacher = $Teacher
    $buffers = @(Get-StudentStockBufferRoots ([IO.Path]::GetFullPath((Join-Path $Teacher.Directory '../..'))))
    $r = [IO.BinaryReader]::new([IO.File]::OpenRead($path))
    try {
        if ($r.ReadString() -cne 'StudentStockExecution/1' -or
            $r.ReadString() -cne (Get-FileHash -LiteralPath (Join-Path $Teacher.Directory 'observation.bin')).Hash) {
            throw 'Stock execution belongs to a different teacher observation.'
        }
        $execution.Recipe = $r.ReadString()
        $count = $r.ReadInt32()
        if ($count -lt 1 -or $count -gt 10000) { throw 'Invalid activation count.' }
        $execution.Activations = [StudentStockActivation[]]::new($count)
        $stages=[Collections.Generic.Dictionary[string,StudentStockActivation]]::new([StringComparer]::Ordinal)
        for ($i=0; $i -lt $count; $i++) {
            $a = [StudentStockActivation]::new()
            $a.Execution = $execution
            $a.Stage = $r.ReadString()
            $a.Axes = $r.ReadString()
            $a.Extent = $r.ReadInt32()
            $a.Count = $r.ReadInt32()
            $a.TypeCode = $r.ReadByte()
            $a.Checksum = $r.ReadString()
            if ($a.Checksum -cnotmatch '^[0-9A-F]{64}$' -or $a.Extent -le 0 -or $a.Count -le 0 -or $a.TypeCode -notin 1,2,3) { throw 'Invalid activation descriptor.' }
            foreach ($root in $buffers) {
                $candidate=Join-Path $root ($a.Checksum + '.gz')
                if ([IO.File]::Exists($candidate)) { $a.Path=$candidate; break }
            }
            if (!$a.Path) { throw "Missing tensor $($a.Checksum)." }
            $execution.Activations[$i] = $a
            $stages.Add($a.Stage,$a)
        }
        if ($r.BaseStream.Position -ne $r.BaseStream.Length) { throw 'Unexpected execution index data.' }
        $execution.GeneratorInput=$stages['decoder.generator_input']
        $execution.Waveform=$stages['generator.waveform']
        $execution.Convolutions=@(foreach ($a in $execution.Activations) {
            if ($a.Axes -cne 'inputFrames,inputChannels,outputChannels,kernel,stride,padding,dilation,groups,transpose,outputPadding') { continue }
            $conv=[StudentStockConvolution]::new()
            $conv.Geometry=$a
            $conv.Output=$stages[$a.Stage.Substring(0,$a.Stage.Length-'.geometry'.Length)]
            if (!$conv.Output) { throw "Convolution lacks its observed output: $($a.Stage)." }
            $conv
        })
        $execution.AlbertApplications=@(foreach ($a in $execution.Activations) {
            if ($a.Stage -cnotmatch '^albert\.([0-9]+)\.attention\.weights$') { continue }
            $layer=[StudentAlbertApplication]::new()
            $layer.Execution=$execution
            $layer.Application=[int]$Matches[1]
            $layer.Attention=$a
            $layer.AttentionContext=$stages["albert.$($layer.Application).attention.context"]
            $layer.Hidden=$stages["albert.$($layer.Application).hidden"]
            $layer
        })
        $execution.Normalizations=@(foreach ($a in $execution.Activations) {
            if (!$a.Stage.EndsWith('.parameters',[StringComparison]::Ordinal)) { continue }
            $site=[StudentStockNormalization]::new()
            $site.Execution=$execution
            $site.Site=$a.Stage.Substring(0,$a.Stage.Length-'.parameters'.Length)
            $site.Parameters=$a
            $site.Input=$stages[$site.Site+'.input']
            $site.Output=$stages[$site.Site+'.output']
            $site.Geometry=$stages[$site.Site+'.geometry']
            $site.TokenAccumulators=$stages[$site.Site+'.accumulators']
            $site.TokenFrames=$stages[$site.Site+'.token_frames']
            $site
        })
        $execution
    } finally { $r.Dispose() }
}

class StudentTeacherWaveEvidence {
    [StudentTeacherObservation] $Owner
    [string] $Engine
    [int] $SampleRate
    [int] $Hop
    [long] $Samples
    [single[]] $Rms
}

function Measure-StudentTeacherWave {
    param([StudentTeacherObservation] $Observation,[ValidateSet('Kokoro','Zira')][string] $Engine)
    $path=if ($Engine -ceq 'Kokoro') {$Observation.KokoroWavePath} else {$Observation.ZiraWavePath}
    $r=[IO.BinaryReader]::new([IO.File]::OpenRead($path))
    try {
        if ($r.ReadUInt32() -ne 0x46464952) { throw 'Expected RIFF PCM.' }
        $null=$r.ReadUInt32()
        if ($r.ReadUInt32() -ne 0x45564157) { throw 'Expected WAVE input.' }
        $rate=0
        $dataAt=-1L
        $dataLength=0L
        while ($r.BaseStream.Position+8 -le $r.BaseStream.Length) {
            $tag=$r.ReadUInt32()
            $length=$r.ReadUInt32()
            $at=$r.BaseStream.Position
            if ($at+$length -gt $r.BaseStream.Length) { throw 'Truncated teacher WAV chunk.' }
            if ($tag -eq 0x20746D66 -and $length -ge 16) {
                if ($r.ReadUInt16() -ne 1 -or $r.ReadUInt16() -ne 1) { throw 'Expected mono PCM.' }
                $rate=$r.ReadUInt32()
                $null=$r.ReadUInt32()
                if ($r.ReadUInt16() -ne 2 -or $r.ReadUInt16() -ne 16) { throw 'Expected 16-bit PCM.' }
            } elseif ($tag -eq 0x61746164) {
                $dataAt=$at
                $dataLength=$length
            }
            $r.BaseStream.Position=$at+$length+($length%2)
        }
        if ($rate -le 0 -or $dataAt -lt 0 -or $dataLength%2) { throw 'Invalid teacher sample clock.' }
        $wave=[StudentTeacherWaveEvidence]::new()
        $wave.Owner=$Observation
        $wave.Engine=$Engine
        $wave.SampleRate=$rate
        $wave.Hop=[int]($rate/50)
        $wave.Samples=$dataLength/2
        $wave.Rms=[single[]]::new([int][Math]::Floor($wave.Samples/[double]$wave.Hop))
        $r.BaseStream.Position=$dataAt
        for ($frame=0;$frame -lt $wave.Rms.Length;$frame++) {
            $energy=0.0
            for ($sample=0;$sample -lt $wave.Hop;$sample++) {
                $value=[double]$r.ReadInt16()/32768.0
                $energy+=$value*$value
            }
            $wave.Rms[$frame]=[Math]::Sqrt($energy/$wave.Hop)
        }
        $wave
    } finally { $r.Dispose() }
}

function Open-StudentTeacherObservation {
    param([string] $Directory,[StudentTextEvidence] $Document,[switch] $LoadTensors,[psmoduleinfo] $ZiraModule)
    $r=[IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $Directory 'observation.bin')))
    try {
        if ($r.ReadString() -cne 'StudentTeacherObservation/1' -or $r.ReadString() -cne $Document.Source.Id) { throw 'Teacher observation has a different source.' }
        $item=[StudentTeacherObservation]::new()
        $item.Document=$Document
        $item.Directory=$Directory
        $item.Configuration=$r.ReadString()
        $item.Start=$r.ReadInt32()
        $item.Length=$r.ReadInt32()
        $item.InputText=$r.ReadString()
        $item.Phones=$r.ReadString()
        $item.KokoroSamples=$r.ReadInt64()
        $first=$r.ReadInt32()
        $last=$r.ReadInt32()
        if ($first -lt 0 -or $last -lt $first -or $last -ge $Document.Interpretations.Length) { throw 'Invalid sentence references.' }
        $item.Sentences=$Document.Interpretations[$first..$last]
        $source=[IO.File]::ReadAllText($Document.Source.Path)
        if ($item.Start -lt 0 -or $item.Length -le 0 -or $item.Start+$item.Length -gt $source.Length) { throw 'Invalid original text extent.' }
        $item.WordOccurrenceIndices=@(
            for ($index=$Document.Sentences[2*$first];$index -le $Document.Sentences[2*$last+1];$index++) {
                $sourceStart=$Document.OriginalSpans[2*$index]
                if ($Document.Tokens[4*$index] -eq 1 -and $sourceStart -ge $item.Start -and $sourceStart -lt $item.Start+$item.Length) { $index }
            }
        )
        $original=$source.Substring($item.Start,$item.Length)
        if (($original -replace '\r\n|\r|\n',' ') -cne $item.InputText) { throw 'Teacher input cannot be reconstructed from its original source.' }
        $item.InputSourceOffsets=[int[]]::new($item.InputText.Length+1)
        $normalized=0
        for ($offset=0;$offset -lt $original.Length;$offset++) {
            $item.InputSourceOffsets[$normalized++]=$item.Start+$offset
            if ($original[$offset] -eq [char]13 -and $offset+1 -lt $original.Length -and $original[$offset+1] -eq [char]10) { $offset++ }
        }
        $item.InputSourceOffsets[$normalized]=$item.Start+$item.Length
        foreach ($name in 'kokoro.wav','zira.wav','zira-events.psd1') {
            if ((Get-FileHash -LiteralPath (Join-Path $Directory $name)).Hash -cne $r.ReadString()) { throw "Artifact hash mismatch for $name." }
        }
        $item.KokoroWavePath=Join-Path $Directory 'kokoro.wav'
        $item.ZiraWavePath=Join-Path $Directory 'zira.wav'
        if ((Get-Item -LiteralPath $item.KokoroWavePath).Length -ne 44+2*$item.KokoroSamples) {
            throw 'Stock WAV size disagrees with the captured sample count.'
        }
        if ($ZiraModule) {
            $item.ZiraUtterance=& $ZiraModule {
                param($Path)
                try { Import-EnglishZiraObservation -Path $Path }
                catch {
                    # The legacy writer escaped ASCII quotes only. SMA also treats curly quotes as delimiters.
                    $original=[IO.File]::ReadAllText($Path)
                    $escaped=[regex]::Replace($original,'[\u2018\u2019\u201A\u201B]','$0$0')
                    if ($escaped -ceq $original) { throw }
                    $tokens=$null
                    $errors=$null
                    $ast=[Management.Automation.Language.Parser]::ParseInput($escaped,[ref]$tokens,[ref]$errors)
                    if ($errors.Length -or $ast.EndBlock.Statements.Count -ne 1) { throw }
                    $statement=$ast.EndBlock.Statements[0]
                    if ($statement -isnot [Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1 -or
                        $statement.PipelineElements[0].Expression -isnot [Management.Automation.Language.HashtableAst]) { throw }
                    Import-EnglishZiraObservation -Path $Path -Data $statement.PipelineElements[0].Expression.SafeGetValue()
                }
            } (Join-Path $Directory 'zira-events.psd1')
            if ($item.ZiraUtterance.GetType().Name -cne 'EnglishZiraUtterance' -or $item.ZiraUtterance.Text -cne $item.InputText) {
                throw 'Zira events did not restore against the same source projection.'
            }
        }
        $item.Tensors=[Collections.Generic.Dictionary[string,Array]]::new([StringComparer]::Ordinal)
        $count=$r.ReadInt32()
        if ($count -ne 12) { throw 'Unexpected stock evidence schema.' }
        $item.Names=[string[]]::new($count)
        $item.Lengths=[int[]]::new($count)
        $extents=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
        for ($i=0;$i -lt $count;$i++) {
            $name=$r.ReadString()
            $integer=$r.ReadBoolean()
            $length=$r.ReadInt32()
            if ($length -lt 0 -or 4L*$length -gt $r.BaseStream.Length-$r.BaseStream.Position) { throw 'Invalid tensor extent.' }
            $item.Names[$i]=$name
            $item.Lengths[$i]=$length
            $extents.Add($name,$length)
            if ($integer -ne ($name -cin 'TokenIds','Durations')) { throw 'Stock tensor element type differs.' }
            if ($LoadTensors -or $integer) {
                $bytes=$r.ReadBytes(4*$length)
                $vector=if ($integer) { ,([int[]]::new($length)) } else { ,([float[]]::new($length)) }
                [Buffer]::BlockCopy($bytes,0,$vector,0,$bytes.Length)
                $item.Tensors.Add($name,$vector)
            } else { $r.BaseStream.Position+=4L*$length }
        }
        if ($r.BaseStream.Position -ne $r.BaseStream.Length) { throw 'Trailing tensor data.' }
        $tokens=$item.Phones.Length+2
        $ticks=$extents.get_Item('F0')
        if ($extents.get_Item('TokenIds') -ne $tokens -or $extents.get_Item('Durations') -ne $tokens -or
            $ticks -ne $extents.get_Item('N') -or 300L*$ticks -ne $item.KokoroSamples -or
            $extents.get_Item('Features') -ne 512L*$ticks -or $extents.get_Item('Aligned') -ne 256L*$ticks -or
            $extents.get_Item('Bert') -ne 768L*$tokens -or $extents.get_Item('BertEncoder') -ne 512L*$tokens -or
            $extents.get_Item('DurationFeatures') -ne 640L*$tokens -or $extents.get_Item('TextEncoding') -ne 512L*$tokens -or
            $extents.get_Item('AcousticStyle') -ne 128 -or $extents.get_Item('ProsodyStyle') -ne 128) {
            throw 'Stock observation shapes do not share the pinned token and frame clocks.'
        }
        $durationFrames=0L
        $durations=$item.Tensors['Durations']
        $item.StockTokenTickStarts=[int[]]::new($durations.Length+1)
        for ($i=0;$i -lt $durations.Length;$i++) {
            $duration=$durations[$i]
            if ($duration -lt 0) { throw 'Negative stock duration.' }
            $durationFrames+=$duration
            $item.StockTokenTickStarts[$i+1]=2*$durationFrames
        }
        if (2*$durationFrames -ne $ticks) { throw 'Durations fail the stock frame invariant.' }
        $item.StockExecution=Open-StudentStockExecution $item
        if ($item.StockExecution) { $item.StockExecution.FrontStateReplay=Open-StudentStockExecution $item 'front-state-replay.bin' }
        $item.ProceduralExecution=Open-StudentStockExecution $item 'procedural-execution.bin'
        $failureLog=Join-Path $Directory 'procedural-execution.bin.failure.txt'
        $item.UnresolvedProceduralPronunciations=@(if ([IO.File]::Exists($failureLog)) {
            $attempt=''
            foreach ($line in [IO.File]::ReadLines($failureLog)) {
                if ($line -cmatch '^\d{4}-\d{2}-\d{2}T') { $attempt=$line }
                if ($line -cne 'The phonemizer could not resolve -Text.') { continue }
                $unresolved=[StudentUnresolvedProceduralPronunciation]::new()
                $unresolved.Teacher=$item
                $unresolved.Attempt=$attempt
                $unresolved.Reason=$line
                $unresolved
            }
        })
        $item.ResidualInterventions=@(if ($item.StockExecution) {
            foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter 'intervention-*.bin' -File) {
                $outcome=Open-StudentStockExecution $item $file.Name
                $recipe=$outcome.Recipe -split "`n",3
                if ($recipe.Count -ne 3 -or $file.BaseName -cne "intervention-$($recipe[1])" -or
                    $outcome.GeneratorInput.Checksum -cne $item.StockExecution.GeneratorInput.Checksum) {
                    throw 'Controlled residual capture does not match its stock baseline.'
                }
                $experiment=[StudentResidualIntervention]::new()
                $experiment.Baseline=$item.StockExecution
                $experiment.Outcome=$outcome
                $experiment.Site=$recipe[1]
                $experiment.Intention=$recipe[2]
                $split=$experiment.Site.LastIndexOf('.')
                $correction='decoder.module.'+$experiment.Site.Substring(0,$split)+'.convs2'+$experiment.Site.Substring($split)
                foreach ($a in $experiment.Baseline.Activations) {
                    if ($a.Stage -ceq $correction) { $experiment.BaselineCorrection=$a }
                    if ($a.Stage -ceq ($experiment.Site+'.residual_sum')) { $experiment.BaselineResidualSum=$a }
                }
                foreach ($a in $outcome.Activations) {
                    if ($a.Stage -ceq $correction) { $experiment.WithheldCorrection=$a; break }
                }
                if (!$experiment.BaselineResidualSum -or !$experiment.BaselineCorrection -or !$experiment.WithheldCorrection -or
                    $experiment.BaselineCorrection.Checksum -cne $experiment.WithheldCorrection.Checksum) {
                    throw 'The experimental correction must match the stock correction before the addition is suppressed.'
                }
                $experiment
            }
        })
        $item
    } finally { $r.Dispose() }
}
Export-ModuleMember -Function Open-StudentTeacherObservation,Measure-StudentTeacherWave,Get-StudentStockBufferRoots
