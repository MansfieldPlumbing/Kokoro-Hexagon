#requires -Version 7.4
using namespace System.Linq.Expressions

<#+.SYNOPSIS
Read-only WAV loudness and peak measurement, owned by MeasureAudio / Verify.
.DESCRIPTION
ITU-R BS.1770-4 (10/2015), Annex 1 Tables 1-3 and equations 2-7;
Annex 2 section 3, the published four-phase, twelve-tap interpolation filter.
https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-4-201510-S!!PDF-E.pdf

The analog prototype is recovered by inverse bilinear transformation of the
published 48 kHz biquads, then discretized at the WAV rate. No audio resampling.
Mono/stereo channel powers are summed for LUFS; RMS averages all channel samples.
Integrated loudness discards incomplete 400 ms blocks. Files shorter than 400 ms
have NaN integrated/momentary loudness; silence has -Infinity. Momentary and
short-term maxima examine every complete window, without gates. Short-term uses
the entire file below 3 s. True peak uses 4x Annex 2 interpolation at every input
rate, zero extension at both ends, and never reports less than the sample peak.
This is an electrical programme-loudness estimate, not a phone-speaker SPL model.
Per-sample decoding, filtering, interpolation, reductions and test synthesis are
expression-tree delegates, as in Kokoro.CaptureKernels.psm1. No input is evaluated.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

class KokoroAudioMeasurement {
    [string]$File
    [string]$Path
    [double]$DurationMs
    [double]$IntegratedLufs
    [double]$MomentaryMaxLufs
    [double]$ShortTermMaxLufs
    [double]$TruePeakDbtp
    [double]$RmsDbfs
}
class KokoroAudioData {
    [int]$SampleRate
    [int]$Channels
    [double[]]$Samples
}
class KokoroAudioCheck {
    [string]$Check
    [int]$SampleRate
    [double]$Amplitude
    [double]$Expected
    [double]$Actual
    [double]$Difference
}
class KokoroAudioKernels {
    [Action[byte[],int,int,double[]]]$Decode
    [Action[double[],int,double[],double[],double[]]]$Filter
    [Action[double[],int,double[],double[]]]$Peak
    [Action[double[],int,int,int,double[]]]$Loudness
    [Action[double[],int,int,double,double,int,double]]$Sine
    [Action[IO.BinaryWriter,double[],int]]$Write
}
$script:AudioKernels=$null
Update-TypeData -TypeName KokoroAudioMeasurement -DefaultDisplayPropertySet File,DurationMs,IntegratedLufs,MomentaryMaxLufs,ShortTermMaxLufs,TruePeakDbtp,RmsDbfs
Update-FormatData -PrependPath (Join-Path $PSScriptRoot 'Kokoro.AudioMeasurement.format.ps1xml')

function New-AudioLoop {
    param([ParameterExpression]$Index,[Expression]$From,[Expression]$Limit,[Expression]$Body,[int]$Step=1)
    $end=[Expression]::Label()
    [Expression]::Block([Expression]::Assign($Index,$From),
        [Expression]::Loop([Expression]::IfThenElse([Expression]::LessThan($Index,$Limit),
            [Expression]::Block($Body,[Expression]::AddAssign($Index,[Expression]::Constant($Step)),[Expression]::Empty()),
            [Expression]::Break($end)),$end))
}
function Get-KokoroAudioKernels {
    if ($null -ne $script:AudioKernels) { return $script:AudioKernels }
    if (-not [BitConverter]::IsLittleEndian) { throw 'The WAV decoder requires a little-endian host.' }
    $kernels=[KokoroAudioKernels]::new()
    $zero=[Expression]::Constant(0); $one=[Expression]::Constant(1)
    $zeroD=[Expression]::Constant(0.0); $negativeInfinity=[Expression]::Constant([double]::NegativeInfinity)
    $nan=[Expression]::Constant([double]::NaN)
    $abs=[Math].GetMethod('Abs',[type[]]@([double])); $max=[Math].GetMethod('Max',[type[]]@([double],[double]))
    $log=[Math].GetMethod('Log10',[type[]]@([double]))
    $index=[Expression]::Variable([int],'index')
    $bytes=[Expression]::Parameter([byte[]],'bytes'); $offset=[Expression]::Parameter([int],'offset')
    $format=[Expression]::Parameter([int],'format'); $samples=[Expression]::Parameter([double[]],'samples')
    $value=[Expression]::Variable([double],'value')
    $pcm=[Expression]::Divide([Expression]::Convert([Expression]::Call([BitConverter].GetMethod('ToInt16',[type[]]@([byte[]],[int])),
        $bytes,[Expression]::Add($offset,[Expression]::Multiply($index,[Expression]::Constant(2)))),[double]),[Expression]::Constant(32768.0))
    $float=[Expression]::Convert([Expression]::Call([BitConverter].GetMethod('ToSingle',[type[]]@([byte[]],[int])),
        $bytes,[Expression]::Add($offset,[Expression]::Multiply($index,[Expression]::Constant(4)))),[double])
    $body=[Expression]::Block([ParameterExpression[]]@($index,$value),
        (New-AudioLoop $index $zero ([Expression]::ArrayLength($samples)) ([Expression]::Block(
            [Expression]::Assign($value,[Expression]::Condition([Expression]::Equal($format,$one),$pcm,$float)),
            [Expression]::IfThen([Expression]::Not([Expression]::Call([double].GetMethod('IsFinite'),$value)),
                [Expression]::Throw([Expression]::Constant([IO.InvalidDataException]::new('Nonfinite WAV sample.')))),
            [Expression]::Assign([Expression]::ArrayAccess($samples,$index),$value)))))
    $kernels.Decode=[Expression]::Lambda([Action[byte[],int,int,double[]]],$body,[ParameterExpression[]]@($bytes,$offset,$format,$samples)).Compile()

    $channels=[Expression]::Parameter([int],'channels'); $coeff=[Expression]::Parameter([double[]],'coeff')
    $prefix=[Expression]::Parameter([double[]],'prefix'); $stats=[Expression]::Parameter([double[]],'stats')
    $channel=[Expression]::Variable([int],'channel'); $frame=[Expression]::Variable([int],'frame')
    $frames=[Expression]::Divide([Expression]::ArrayLength($samples),$channels)
    $first=[Expression]::Variable([double],'first'); $second=[Expression]::Variable([double],'second')
    $state=@(0..3 | ForEach-Object { [Expression]::Variable([double],"state$_") })
    $sequence=[Collections.Generic.List[Expression]]::new()
    $sequence.Add([Expression]::Assign($value,[Expression]::ArrayIndex($samples,[Expression]::Add([Expression]::Multiply($frame,$channels),$channel))))
    $sequence.Add([Expression]::AddAssign([Expression]::ArrayAccess($stats,$zero),[Expression]::Multiply($value,$value)))
    for ($stage=0; $stage -lt 2; $stage++) {
        $base=5*$stage; $current=if ($stage -eq 0) {$value} else {$first}; $filtered=if ($stage -eq 0) {$first} else {$second}
        $left=$state[2*$stage]; $right=$state[2*$stage+1]
        $sequence.Add([Expression]::Assign($filtered,[Expression]::Add([Expression]::Multiply([Expression]::ArrayIndex($coeff,[Expression]::Constant($base)),$current),$left)))
        $sequence.Add([Expression]::Assign($left,[Expression]::Add([Expression]::Subtract(
            [Expression]::Multiply([Expression]::ArrayIndex($coeff,[Expression]::Constant($base+1)),$current),
            [Expression]::Multiply([Expression]::ArrayIndex($coeff,[Expression]::Constant($base+3)),$filtered)),$right)))
        $sequence.Add([Expression]::Assign($right,[Expression]::Subtract(
            [Expression]::Multiply([Expression]::ArrayIndex($coeff,[Expression]::Constant($base+2)),$current),
            [Expression]::Multiply([Expression]::ArrayIndex($coeff,[Expression]::Constant($base+4)),$filtered))))
    }
    $sequence.Add([Expression]::AddAssign([Expression]::ArrayAccess($prefix,[Expression]::Add($frame,$one)),[Expression]::Multiply($second,$second)))
    $reset=@($state | ForEach-Object { [Expression]::Assign($_,$zeroD) })
    $channelBody=[Expression]::Block([Expression[]]@($reset + (New-AudioLoop $frame $zero $frames ([Expression]::Block($sequence)))))
    $body=[Expression]::Block([ParameterExpression[]](@($channel,$frame,$value,$first,$second)+$state),
        (New-AudioLoop $channel $zero $channels $channelBody),
        (New-AudioLoop $frame $one ([Expression]::ArrayLength($prefix)) ([Expression]::AddAssign([Expression]::ArrayAccess($prefix,$frame),[Expression]::ArrayIndex($prefix,[Expression]::Subtract($frame,$one))))))
    $kernels.Filter=[Expression]::Lambda([Action[double[],int,double[],double[],double[]]],$body,[ParameterExpression[]]@($samples,$channels,$coeff,$prefix,$stats)).Compile()

    $fir=[Expression]::Parameter([double[]],'fir'); $phase=[Expression]::Variable([int],'phase'); $tap=[Expression]::Variable([int],'tap')
    $source=[Expression]::Subtract($frame,$tap)
    $convolve=New-AudioLoop $tap $zero ([Expression]::Constant(12)) ([Expression]::IfThen(
        [Expression]::AndAlso([Expression]::GreaterThanOrEqual($source,$zero),[Expression]::LessThan($source,$frames)),
        [Expression]::Block([Expression]::AddAssign($value,[Expression]::Multiply(
            [Expression]::ArrayIndex($fir,[Expression]::Add([Expression]::Multiply($phase,[Expression]::Constant(12)),$tap)),
            [Expression]::ArrayIndex($samples,[Expression]::Add([Expression]::Multiply($source,$channels),$channel)))),[Expression]::Empty())))
    $peakCell=[Expression]::ArrayAccess($stats,$one)
    $phaseBody=[Expression]::Block([Expression]::Assign($value,$zeroD),$convolve,
        [Expression]::Assign($peakCell,[Expression]::Call($max,$peakCell,[Expression]::Call($abs,$value))))
    $body=[Expression]::Block([ParameterExpression[]]@($channel,$frame,$phase,$tap,$index,$value),
        (New-AudioLoop $index $zero ([Expression]::ArrayLength($samples)) `
            ([Expression]::Assign($peakCell,[Expression]::Call($max,$peakCell,[Expression]::Call($abs,[Expression]::ArrayIndex($samples,$index)))))),
        (New-AudioLoop $channel $zero $channels (New-AudioLoop $frame $zero ([Expression]::Add($frames,[Expression]::Constant(11))) `
            (New-AudioLoop $phase $zero ([Expression]::Constant(4)) $phaseBody))))
    $kernels.Peak=[Expression]::Lambda([Action[double[],int,double[],double[]]],$body,[ParameterExpression[]]@($samples,$channels,$fir,$stats)).Compile()

    $block=[Expression]::Parameter([int],'block'); $hop=[Expression]::Parameter([int],'hop'); $short=[Expression]::Parameter([int],'short')
    $result=[Expression]::Parameter([double[]],'result'); $sum=[Expression]::Variable([double],'sum')
    $count=[Expression]::Variable([int],'count'); $threshold=[Expression]::Variable([double],'threshold')
    $maximum=[Expression]::Variable([double],'maximum')
    $frameCount=[Expression]::Subtract([Expression]::ArrayLength($prefix),$one)
    $energy=[Expression]::Divide([Expression]::Subtract([Expression]::ArrayIndex($prefix,[Expression]::Add($index,$block)),[Expression]::ArrayIndex($prefix,$index)),[Expression]::Convert($block,[double]))
    $absolute=[Expression]::Constant([Math]::Pow(10,(-70+0.691)/10))
    $gateLoop={
        [Expression]::Block([Expression]::Assign($sum,$zeroD),[Expression]::Assign($count,$zero),
            (New-AudioLoop $index $zero ([Expression]::Divide([Expression]::Add([Expression]::Subtract($frameCount,$block),$hop),$hop)) `
                ([Expression]::Block([Expression]::Assign($value,[Expression]::Divide(
                    [Expression]::Subtract([Expression]::ArrayIndex($prefix,[Expression]::Add([Expression]::Multiply($index,$hop),$block)),
                        [Expression]::ArrayIndex($prefix,[Expression]::Multiply($index,$hop))),[Expression]::Convert($block,[double]))),
                    [Expression]::IfThen([Expression]::GreaterThan($value,$threshold),[Expression]::Block([Expression]::AddAssign($sum,$value),[Expression]::PostIncrementAssign($count),[Expression]::Empty()))))))
    }
    $toLufs={ param([Expression]$Power) [Expression]::Add([Expression]::Constant(-0.691),[Expression]::Multiply([Expression]::Constant(10.0),[Expression]::Call($log,$Power))) }
    $fullBlocks=[Expression]::Block([Expression]::Assign($threshold,$absolute),(& $gateLoop),
        [Expression]::IfThen([Expression]::GreaterThan($count,$zero),[Expression]::Block(
            [Expression]::Assign($threshold,[Expression]::Call($max,$absolute,[Expression]::Multiply([Expression]::Divide($sum,[Expression]::Convert($count,[double])),[Expression]::Constant(0.1)))),
            (& $gateLoop),[Expression]::Assign([Expression]::ArrayAccess($result,$zero),(& $toLufs ([Expression]::Divide($sum,[Expression]::Convert($count,[double]))))),[Expression]::Empty())),
        [Expression]::Assign($maximum,$zeroD),
        (New-AudioLoop $index $zero ([Expression]::Add([Expression]::Subtract($frameCount,$block),$one)) `
            ([Expression]::Assign($maximum,[Expression]::Call($max,$maximum,$energy)))),
        [Expression]::Assign([Expression]::ArrayAccess($result,$one),(& $toLufs $maximum)))
    $shortEnergy=[Expression]::Divide([Expression]::Subtract([Expression]::ArrayIndex($prefix,[Expression]::Add($index,$short)),[Expression]::ArrayIndex($prefix,$index)),[Expression]::Convert($short,[double]))
    $body=[Expression]::Block([ParameterExpression[]]@($index,$value,$sum,$count,$threshold,$maximum),
        [Expression]::Assign([Expression]::ArrayAccess($result,$zero),[Expression]::Condition([Expression]::LessThan($frameCount,$block),$nan,$negativeInfinity)),
        [Expression]::Assign([Expression]::ArrayAccess($result,$one),$nan),
        [Expression]::IfThen([Expression]::GreaterThanOrEqual($frameCount,$block),[Expression]::Block($fullBlocks,[Expression]::Empty())),
        [Expression]::Assign($maximum,$zeroD),
        (New-AudioLoop $index $zero ([Expression]::Add([Expression]::Subtract($frameCount,$short),$one)) `
            ([Expression]::Assign($maximum,[Expression]::Call($max,$maximum,$shortEnergy)))),
        [Expression]::Assign([Expression]::ArrayAccess($result,[Expression]::Constant(2)),(& $toLufs $maximum)),[Expression]::Empty())
    $kernels.Loudness=[Expression]::Lambda([Action[double[],int,int,int,double[]]],$body,[ParameterExpression[]]@($prefix,$block,$hop,$short,$result)).Compile()

    $rate=[Expression]::Parameter([int],'rate'); $amplitude=[Expression]::Parameter([double],'amplitude')
    $frequency=[Expression]::Parameter([double],'frequency'); $active=[Expression]::Parameter([int],'active'); $angle=[Expression]::Parameter([double],'angle')
    $theta=[Expression]::Add($angle,[Expression]::Divide([Expression]::Multiply([Expression]::Constant(2*[Math]::PI),
        [Expression]::Multiply($frequency,[Expression]::Convert([Expression]::Divide($index,$channels),[double]))),[Expression]::Convert($rate,[double])))
    $body=[Expression]::Block([ParameterExpression[]]@($index),
        (New-AudioLoop $index $zero ([Expression]::Multiply($active,$channels)) ([Expression]::Assign([Expression]::ArrayAccess($samples,$index),
            [Expression]::Multiply($amplitude,[Expression]::Call([Math].GetMethod('Sin',[type[]]@([double])),$theta))))))
    $kernels.Sine=[Expression]::Lambda([Action[double[],int,int,double,double,int,double]],$body,[ParameterExpression[]]@($samples,$rate,$channels,$amplitude,$frequency,$active,$angle)).Compile()
    $writer=[Expression]::Parameter([IO.BinaryWriter],'writer')
    $quantized=[Expression]::Convert([Expression]::Call([Math].GetMethod('Clamp',[type[]]@([double],[double],[double])),
        [Expression]::Call([Math].GetMethod('Round',[type[]]@([double])),[Expression]::Multiply([Expression]::ArrayIndex($samples,$index),[Expression]::Constant(32768.0))),
        [Expression]::Constant(-32768.0),[Expression]::Constant(32767.0)),[int16])
    $body=[Expression]::Block([ParameterExpression[]]@($index),
        (New-AudioLoop $index $zero ([Expression]::ArrayLength($samples)) ([Expression]::IfThenElse([Expression]::Equal($format,$one),
            [Expression]::Call($writer,[IO.BinaryWriter].GetMethod('Write',[type[]]@([int16])),$quantized),
            [Expression]::Call($writer,[IO.BinaryWriter].GetMethod('Write',[type[]]@([single])),[Expression]::Convert([Expression]::ArrayIndex($samples,$index),[single]))))))
    $kernels.Write=[Expression]::Lambda([Action[IO.BinaryWriter,double[],int]],$body,[ParameterExpression[]]@($writer,$samples,$format)).Compile()
    $script:AudioKernels=$kernels
    return $kernels
}

function Get-KokoroAudioCoefficients {
    param([int]$SampleRate)
    # Inverse BLT: q=z^-1=(1-s/c0)/(1+s/c0), c0=96000.
    # p(s)=(d0+d1+d2)+2(d0-d2)s/c0+(d0-d1+d2)s^2/c0^2.
    # Forward BLT at c=2*fs gives [p0+p1*c+p2*c^2,2*p0-2*p2*c^2,p0-p1*c+p2*c^2].
    $coefficients=[Collections.Generic.List[double]]::new()
    foreach ($stage in @(
        @(@(1.53512485958697,-2.69169618940638,1.19839281085285),@(1.0,-1.69065929318241,0.73248077421585)),
        @(@(1.0,-2.0,1.0),@(1.0,-1.99004745483398,0.99007225036621))
    )) {
        $polynomials=@(foreach ($digital in $stage) {
            $p0=$digital[0]+$digital[1]+$digital[2]; $p1=2*($digital[0]-$digital[2])/96000.0
            $p2=($digital[0]-$digital[1]+$digital[2])/(96000.0*96000.0); $c=2.0*$SampleRate
            ,@(($p0+$p1*$c+$p2*$c*$c),(2*$p0-2*$p2*$c*$c),($p0-$p1*$c+$p2*$c*$c))
        })
        foreach ($index in 0..2) { $coefficients.Add($polynomials[0][$index]/$polynomials[1][0]) }
        foreach ($index in 1..2) { $coefficients.Add($polynomials[1][$index]/$polynomials[1][0]) }
    }
    return ,$coefficients.ToArray()
}

# Annex 2 section 3. Phases 2 and 3 are the reversals of phases 1 and 0.
$phase0=[double[]]@(0.001708984375,0.010986328125,-0.0196533203125,0.033203125,-0.0594482421875,0.1373291015625,0.97216796875,-0.102294921875,0.047607421875,-0.026611328125,0.014892578125,-0.00830078125)
$phase1=[double[]]@(-0.0291748046875,0.029296875,-0.0517578125,0.089111328125,-0.16650390625,0.465087890625,0.77978515625,-0.2003173828125,0.1015625,-0.0582275390625,0.0330810546875,-0.0189208984375)
$phase2=[double[]]$phase1.Clone(); [Array]::Reverse($phase2)
$phase3=[double[]]$phase0.Clone(); [Array]::Reverse($phase3)
$script:TruePeakFir=[double[]]($phase0+$phase1+$phase2+$phase3)

function Read-KokoroAudioBytes {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 12) { throw 'Truncated WAV header.' }
    $stream=[IO.MemoryStream]::new($Bytes,$false); $reader=[IO.BinaryReader]::new($stream)
    try {
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -cne 'RIFF') { throw 'Only RIFF WAV is supported.' }
        $end=8L+$reader.ReadUInt32()
        if ($end -gt $Bytes.Length -or $end -lt 12 -or [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -cne 'WAVE') { throw 'Invalid WAV RIFF extent/type.' }
        $format=0; $channels=0; $rate=0; $align=0; $bits=0; $byteRate=0L; $dataOffset=-1; $dataLength=0
        while ($stream.Position -lt $end) {
            if ($end-$stream.Position -lt 8) { throw 'Truncated WAV chunk header.' }
            $tag=[Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)); $length=[long]$reader.ReadUInt32(); $start=$stream.Position
            $next=$start+$length+($length -band 1)
            if ($next -gt $end) { throw 'WAV chunk exceeds RIFF extent.' }
            if ($tag -ceq 'fmt ') {
                if ($format -ne 0 -or $length -lt 16) { throw 'Invalid or duplicate WAV format chunk.' }
                $format=[int]$reader.ReadUInt16(); $channels=[int]$reader.ReadUInt16(); $rate=[long]$reader.ReadUInt32()
                $byteRate=[long]$reader.ReadUInt32(); $align=[int]$reader.ReadUInt16(); $bits=[int]$reader.ReadUInt16()
                if ($format -eq 65534) {
                    if ($length -lt 40 -or $reader.ReadUInt16() -lt 22) { throw 'Truncated extensible WAV format.' }
                    $validBits=$reader.ReadUInt16(); $mask=$reader.ReadUInt32(); $subtype=[guid]::new($reader.ReadBytes(16))
                    if ($validBits -ne $bits -or ($channels -eq 1 -and $mask -notin 0,1,4) -or ($channels -eq 2 -and $mask -notin 0,3)) { throw 'Unsupported extensible WAV valid bits/channel mapping.' }
                    $format=if ($subtype -eq [guid]'00000001-0000-0010-8000-00aa00389b71') {1} elseif ($subtype -eq [guid]'00000003-0000-0010-8000-00aa00389b71') {3} else {throw 'Unsupported WAV subtype.'}
                }
            } elseif ($tag -ceq 'data') {
                if ($dataOffset -ge 0 -or $length -gt [int]::MaxValue) { throw 'Duplicate or oversized WAV data chunk.' }
                $dataOffset=[int]$start; $dataLength=[int]$length
            }
            $stream.Position=$next
        }
        if ($channels -notin 1,2 -or $rate -lt 1 -or $rate -gt [int]::MaxValue -or
            -not (($format -eq 1 -and $bits -eq 16) -or ($format -eq 3 -and $bits -eq 32)) -or
            $align -ne $channels*($bits/8) -or $byteRate -ne $rate*$align -or $dataOffset -lt 0 -or $dataLength -eq 0 -or $dataLength%$align -ne 0) {
            throw 'WAV must contain complete nonempty mono/stereo PCM16 or IEEE float32 frames at a positive rate.'
        }
        $audio=[KokoroAudioData]::new(); $audio.SampleRate=[int]$rate; $audio.Channels=$channels
        $audio.Samples=[double[]]::new($dataLength/($bits/8))
        (Get-KokoroAudioKernels).Decode.Invoke($Bytes,$dataOffset,$format,$audio.Samples)
        return $audio
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Measure-KokoroAudioData {
    param([KokoroAudioData]$Audio,[string]$Path)
    $frames=[int]($Audio.Samples.Length/$Audio.Channels)
    $prefix=[double[]]::new($frames+1); $stats=[double[]]::new(2); $loudness=[double[]]::new(3)
    $kernels=Get-KokoroAudioKernels
    $kernels.Filter.Invoke($Audio.Samples,$Audio.Channels,(Get-KokoroAudioCoefficients $Audio.SampleRate),$prefix,$stats)
    $kernels.Peak.Invoke($Audio.Samples,$Audio.Channels,$script:TruePeakFir,$stats)
    $block=[int][Math]::Max(1,[Math]::Round(0.4*$Audio.SampleRate))
    $hop=[int][Math]::Max(1,[Math]::Round(0.1*$Audio.SampleRate))
    $short=[int][Math]::Min($frames,[Math]::Max(1,[Math]::Round(3.0*$Audio.SampleRate)))
    $kernels.Loudness.Invoke($prefix,$block,$hop,$short,$loudness)
    $measurement=[KokoroAudioMeasurement]::new(); $measurement.Path=$Path; $measurement.File=[IO.Path]::GetFileName($Path)
    $measurement.DurationMs=1000.0*$frames/$Audio.SampleRate
    $measurement.IntegratedLufs=$loudness[0]; $measurement.MomentaryMaxLufs=$loudness[1]; $measurement.ShortTermMaxLufs=$loudness[2]
    $measurement.TruePeakDbtp=20*[Math]::Log10($stats[1]); $measurement.RmsDbfs=10*[Math]::Log10($stats[0]/$Audio.Samples.Length)
    return $measurement
}

function Measure-KokoroAudio {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    $item=Get-Item -LiteralPath $Path
    $files=if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $item.FullName -File -Filter '*.wav' | Sort-Object Name) } else { @($item) }
    if ($files.Count -eq 0) { throw 'The folder contains no WAV files (only immediate children are measured).' }
    foreach ($file in $files) {
        if ($file.Extension -ine '.wav') { throw 'MeasureAudio requires a WAV file or a folder of WAV files.' }
        try { Measure-KokoroAudioData -Audio (Read-KokoroAudioBytes ([IO.File]::ReadAllBytes($file.FullName))) -Path $file.FullName }
        catch { throw "Cannot measure '$($file.FullName)': $($_.Exception.Message)" }
    }
}

function New-KokoroAudioTestWave {
    param([int]$Rate,[double]$Amplitude,[double]$Frequency=997,[double]$Seconds=10,[int]$SilenceSeconds=0,[int]$Channels=1,[int]$Format=3,[double]$Phase=0)
    $activeFrames=[int][Math]::Round($Rate*$Seconds)
    $samples=[double[]]::new(($activeFrames+$Rate*$SilenceSeconds)*$Channels)
    $kernels=Get-KokoroAudioKernels; $kernels.Sine.Invoke($samples,$Rate,$Channels,$Amplitude,$Frequency,$activeFrames,$Phase)
    $bits=if ($Format -eq 1) {16} else {32}; $align=$Channels*$bits/8
    $stream=[IO.MemoryStream]::new(); $writer=[IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36+$samples.Length*$bits/8))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
        $writer.Write([uint16]$Format); $writer.Write([uint16]$Channels); $writer.Write([int]$Rate); $writer.Write([int]($Rate*$align))
        $writer.Write([uint16]$align); $writer.Write([uint16]$bits)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int]($samples.Length*$bits/8))
        $kernels.Write.Invoke($writer,$samples,$Format); $writer.Flush()
        return ,$stream.ToArray()
    } finally { $writer.Dispose(); $stream.Dispose() }
}

function Test-KokoroAudioMeasurement {
    # Synthetic WAVs stay in memory and exercise the same parser and measurement
    # as the public command. Throws immediately: never continue to real audio on failure.
    [CmdletBinding()]
    param()
    foreach ($rate in 24000,48000) {
        foreach ($amplitude in 1.0,0.5,0.1) {
            $tone=Measure-KokoroAudioData (Read-KokoroAudioBytes (New-KokoroAudioTestWave $rate $amplitude)) 'synthetic.wav'
            $expected=20*[Math]::Log10($amplitude)-3.01
            $check=[KokoroAudioCheck]::new(); $check.Check='997 Hz calibration'; $check.SampleRate=$rate; $check.Amplitude=$amplitude
            $check.Expected=$expected; $check.Actual=$tone.IntegratedLufs; $check.Difference=$check.Actual-$expected
            $check
            if (-not [double]::IsFinite($check.Actual) -or [Math]::Abs($check.Difference) -gt 0.1) { throw 'STOP calibration: inspect filter coefficients and block math; no retuning.' }
            $padded=Measure-KokoroAudioData (Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate $rate -Amplitude $amplitude -SilenceSeconds 5)) 'padded.wav'
            $check=[KokoroAudioCheck]::new(); $check.Check='5 s silence gate'; $check.SampleRate=$rate; $check.Amplitude=$amplitude
            $check.Expected=$tone.IntegratedLufs; $check.Actual=$padded.IntegratedLufs; $check.Difference=$check.Actual-$check.Expected
            $check
            if (-not [double]::IsFinite($check.Actual) -or [Math]::Abs($check.Difference) -gt 0.1) { throw 'STOP silence padding: inspect gating and block math; no retuning.' }
        }
        $low=Measure-KokoroAudioData (Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate $rate -Amplitude 0.5 -Frequency 100)) '100Hz.wav'
        $high=Measure-KokoroAudioData (Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate $rate -Amplitude 0.5 -Frequency 2000)) '2000Hz.wav'
        $check=[KokoroAudioCheck]::new(); $check.Check='100 Hz versus 2 kHz'; $check.SampleRate=$rate; $check.Amplitude=0.5
        $check.Expected=$high.IntegratedLufs; $check.Actual=$low.IntegratedLufs; $check.Difference=$check.Actual-$check.Expected
        $check
        if (-not [double]::IsFinite($check.Actual) -or -not [double]::IsFinite($check.Expected) -or $check.Actual -ge $check.Expected) { throw 'STOP K-weighting shape: inspect filter coefficients; no retuning.' }
    }
    # Boundary/representation checks use the same generated WAV path in memory.
    # Stereo must sum channel power for LUFS, while RMS remains per sample.
    $mono=Measure-KokoroAudioData (Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate 44100 -Amplitude 0.5 -Seconds 1)) 'mono.wav'
    foreach ($format in 1,3) {
        $stereo=Measure-KokoroAudioData (Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate 44100 -Amplitude 0.5 -Seconds 1 -Channels 2 -Format $format)) 'stereo.wav'
        if ([Math]::Abs($stereo.IntegratedLufs-$mono.IntegratedLufs-10*[Math]::Log10(2)) -gt 0.001 -or
            [Math]::Abs($stereo.RmsDbfs-$mono.RmsDbfs) -gt 0.001) { throw 'STOP block math/decoding: stereo or PCM16/float32 scaling failed.' }
    }
    $silence=Measure-KokoroAudioData (Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate 24000 -Amplitude 0 -Seconds 1)) 'silence.wav'
    if ($silence.IntegratedLufs -ne [double]::NegativeInfinity -or $silence.RmsDbfs -ne [double]::NegativeInfinity -or
        $silence.TruePeakDbtp -ne [double]::NegativeInfinity) { throw 'STOP gating/block math: silence failed.' }
    $brief=Measure-KokoroAudioData (Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate 24000 -Amplitude 0.5 -Seconds 0.1)) 'brief.wav'
    if (-not [double]::IsNaN($brief.IntegratedLufs) -or -not [double]::IsNaN($brief.MomentaryMaxLufs) -or
        -not [double]::IsFinite($brief.ShortTermMaxLufs)) { throw 'STOP block math: short-file window contract failed.' }
    $intersample=Measure-KokoroAudioData (Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate 48000 -Amplitude 0.5 -Frequency 12000 -Phase ([Math]::PI/4) -Seconds 1)) 'intersample.wav'
    if ($intersample.TruePeakDbtp -le $intersample.RmsDbfs+1) { throw 'STOP true peak: 4x interpolation did not find the intersample peak.' }
}

Export-ModuleMember -Function Measure-KokoroAudio,Test-KokoroAudioMeasurement
