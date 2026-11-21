using module ./StudentSourceInventory.psm1
using module ./StudentTextEvidence.psm1
#requires -Version 7.4

class StudentTeacherObservation {
    [StudentTextEvidence] $Document
    [StudentSentenceEvidence[]] $Sentences
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
            if ($LoadTensors) {
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
        if ($LoadTensors) {
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
        }
        $item
    } finally { $r.Dispose() }
}
Export-ModuleMember -Function Open-StudentTeacherObservation,Measure-StudentTeacherWave
