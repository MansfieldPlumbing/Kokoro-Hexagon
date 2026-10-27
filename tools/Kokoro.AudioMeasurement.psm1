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
    # Comparison: a tone against itself is exact in every measure and its f0 is the tone's; the same tone a quarter period
    # later differs in waveform but not in magnitude spectrum.
    $tone=Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate 24000 -Amplitude 0.5 -Frequency 220 -Seconds 1)
    $same=Compare-KokoroAudioData $tone $tone 'tone.wav' 'tone.wav' $null
    if (-not [double]::IsPositiveInfinity($same.WaveformSnrDb) -or $same.LogSpectralDistanceDb -ne 0 -or $same.MelCepstralDistortionDb -ne 0 -or $same.F0RmseCents -ne 0 -or
        [Math]::Abs($same.ReferenceF0MeanHz/220-1) -gt 0.005) { throw 'STOP comparison: a tone against itself is not exact, or its f0 is not 220 Hz.' }
    $shifted=Compare-KokoroAudioData $tone (Read-KokoroAudioBytes (New-KokoroAudioTestWave -Rate 24000 -Amplitude 0.5 -Frequency 220 -Seconds 1 -Phase ([Math]::PI/2))) 'tone.wav' 'shifted.wav' $null
    if ($shifted.WaveformSnrDb -gt 3 -or $shifted.MagnitudeSnrDb -lt 20 -or [Math]::Abs($shifted.F0RmseCents) -gt 5) { throw 'STOP comparison: a phase shift should change the waveform, not the magnitude spectrum or f0.' }
}

# Comparison of two renders: measures that do not require sample alignment (spectra, mel cepstra, pitch, loudness
# envelope) beside waveform SNR, plus pictures of the same quantities. Mono WAVs at one rate. Hot loops are compiled
# expression trees, as above; PNG files are written directly (zlib from the BCL, CRC-32 compiled here).
class KokoroAudioResolution {
    [int]$Window
    [double]$MagnitudeSnrDb
    [double]$LogSpectralDistanceDb
    [double]$SpectralConvergence
}
class KokoroAudioComparison {
    [string]$Reference
    [string]$Candidate
    [double]$Seconds
    [int]$BestLagSamples
    [double]$WaveformSnrDb
    [double]$MagnitudeSnrDb
    [double]$LogSpectralDistanceDb
    [double]$MelCepstralDistortionDb
    [double]$EnvelopeCorrelation
    [double]$LoudnessDifferenceLu
    [double]$VoicingAgreement
    [double]$F0RmseCents
    [double]$ReferenceF0MeanHz
    [double]$CandidateF0MeanHz
    [double]$ReferenceHnrDb
    [double]$CandidateHnrDb
    [KokoroAudioResolution[]]$Resolutions
    [string[]]$Images
    [object]$Yardstick
}
class KokoroAudioAnalysisKernels {
    [Action[double[],int,int,int,double[],int[],double[],double[],double[],double[],double[]]]$Spectrum
    [Action[double[],double[],int,int,double,double[],double[],double[]]]$Spectral
    [Action[double[],int,int,double[],int,double[]]]$Multiply
    [Action[double[],int,int,int,int,int,double[],double[],double[],double[],double[]]]$Pitch
    [Action[double[],double[],int,double[]]]$Correlate
    [Action[double[],double[],int,int,int,int,double,double,int,byte[],byte[]]]$Colorize
    [Func[byte[],uint32[],uint32]]$Crc
}
$script:AnalysisKernels=$null
Update-TypeData -TypeName KokoroAudioComparison -DefaultDisplayPropertySet Seconds,WaveformSnrDb,MagnitudeSnrDb,LogSpectralDistanceDb,MelCepstralDistortionDb,EnvelopeCorrelation,LoudnessDifferenceLu,VoicingAgreement,F0RmseCents,ReferenceHnrDb,CandidateHnrDb -Force

# A loop whose index advances by an arbitrary expression (doubling sizes, block strides).
function New-AudioLoopBy {
    param([ParameterExpression]$Index,[Expression]$From,[Expression]$Limit,[Expression]$Body,[Expression]$Next)
    $end=[Expression]::Label()
    [Expression]::Block([Expression]::Assign($Index,$From),
        [Expression]::Loop([Expression]::IfThenElse([Expression]::LessThan($Index,$Limit),
            [Expression]::Block($Body,[Expression]::Assign($Index,$Next),[Expression]::Empty()),[Expression]::Break($end)),$end))
}

function Get-KokoroAudioAnalysisKernels {
    if ($null -ne $script:AnalysisKernels) { return $script:AnalysisKernels }
    $k=[KokoroAudioAnalysisKernels]::new(); $E=[Expression]
    $i0=$E::Constant(0); $i1=$E::Constant(1); $d0=$E::Constant(0.0)
    $sqrt=[Math].GetMethod('Sqrt',[type[]]@([double])); $log=[Math].GetMethod('Log10',[type[]]@([double]))
    $at={ param($array,$index) $E::ArrayAccess($array,$index) }
    $var={ param([type]$t,[string]$n) $E::Variable($t,$n) }

    # Spectrum: frames of n samples every hop, Hann-windowed, radix-2 FFT (bit reversal on load), power of bins 0..n/2.
    $samples=$E::Parameter([double[]],'samples'); $n=$E::Parameter([int],'n'); $hop=$E::Parameter([int],'hop'); $frames=$E::Parameter([int],'frames')
    $window=$E::Parameter([double[]],'window'); $reverse=$E::Parameter([int[]],'reverse'); $cosT=$E::Parameter([double[]],'cosT'); $sinT=$E::Parameter([double[]],'sinT')
    $re=$E::Parameter([double[]],'re'); $im=$E::Parameter([double[]],'im'); $power=$E::Parameter([double[]],'power')
    $frame=& $var ([int]) 'frame'; $i=& $var ([int]) 'i'; $start=& $var ([int]) 'start'; $size=& $var ([int]) 'size'; $half=& $var ([int]) 'half'
    $block=& $var ([int]) 'block'; $j=& $var ([int]) 'j'; $a=& $var ([int]) 'a'; $b=& $var ([int]) 'b'; $step=& $var ([int]) 'step'; $bins=& $var ([int]) 'bins'
    $c=& $var ([double]) 'c'; $s=& $var ([double]) 's'; $tr=& $var ([double]) 'tr'; $ti=& $var ([double]) 'ti'
    $load=New-AudioLoop $i $i0 $n ($E::Block(
        $E::Assign((& $at $re (& $at $reverse $i)),$E::Multiply((& $at $samples $E::Add($start,$i)),(& $at $window $i))),
        $E::Assign((& $at $im (& $at $reverse $i)),$d0)))
    $butterfly=$E::Block(
        $E::Assign($c,(& $at $cosT $E::Multiply($j,$step))),$E::Assign($s,(& $at $sinT $E::Multiply($j,$step))),
        $E::Assign($a,$E::Add($block,$j)),$E::Assign($b,$E::Add($a,$half)),
        $E::Assign($tr,$E::Add($E::Multiply($c,(& $at $re $b)),$E::Multiply($s,(& $at $im $b)))),
        $E::Assign($ti,$E::Subtract($E::Multiply($c,(& $at $im $b)),$E::Multiply($s,(& $at $re $b)))),
        $E::Assign((& $at $re $b),$E::Subtract((& $at $re $a),$tr)),$E::Assign((& $at $im $b),$E::Subtract((& $at $im $a),$ti)),
        $E::AddAssign((& $at $re $a),$tr),$E::AddAssign((& $at $im $a),$ti))
    $stages=New-AudioLoopBy $size $E::Constant(2) $E::Add($n,$i1) ($E::Block(
        $E::Assign($half,$E::Divide($size,$E::Constant(2))),$E::Assign($step,$E::Divide($n,$size)),
        (New-AudioLoopBy $block $i0 $n (New-AudioLoop $j $i0 $half $butterfly) $E::Add($block,$size)))) $E::Multiply($size,$E::Constant(2))
    $store=New-AudioLoop $i $i0 $bins ($E::Assign((& $at $power $E::Add($E::Multiply($frame,$bins),$i)),
        $E::Add($E::Multiply((& $at $re $i),(& $at $re $i)),$E::Multiply((& $at $im $i),(& $at $im $i)))))
    $body=$E::Block([ParameterExpression[]]@($frame,$i,$start,$size,$half,$block,$j,$a,$b,$step,$bins,$c,$s,$tr,$ti),
        $E::Assign($bins,$E::Add($E::Divide($n,$E::Constant(2)),$i1)),
        (New-AudioLoop $frame $i0 $frames ($E::Block($E::Assign($start,$E::Multiply($frame,$hop)),$load,$stages,$store))))
    $k.Spectrum=$E::Lambda([Action[double[],int,int,int,double[],int[],double[],double[],double[],double[],double[]]],$body,
        [ParameterExpression[]]@($samples,$n,$hop,$frames,$window,$reverse,$cosT,$sinT,$re,$im,$power)).Compile()

    # Spectral: over frames x bins of two power spectra, stats[0] += (|A|-|B|)^2, stats[1] += A, stats[2] += each frame's
    # RMS log-spectral difference (dB, above floor); per-frame energies of both.
    $pa=$E::Parameter([double[]],'pa'); $pb=$E::Parameter([double[]],'pb'); $fc=$E::Parameter([int],'frames'); $bc=$E::Parameter([int],'bins')
    $floor=$E::Parameter([double],'floor'); $stats=$E::Parameter([double[]],'stats'); $ea=$E::Parameter([double[]],'energyA'); $eb=$E::Parameter([double[]],'energyB')
    $f=& $var ([int]) 'f'; $x=& $var ([int]) 'x'; $p=& $var ([double]) 'p'; $q=& $var ([double]) 'q'; $sum=& $var ([double]) 'sum'; $d=& $var ([double]) 'd'
    $db={ param($v) $E::Multiply($E::Constant(10.0),$E::Call($log,$E::Add($v,$floor))) }
    $inner=New-AudioLoop $i $i0 $bc ($E::Block(
        $E::Assign($x,$E::Add($E::Multiply($f,$bc),$i)),$E::Assign($p,(& $at $pa $x)),$E::Assign($q,(& $at $pb $x)),
        $E::Assign($d,$E::Subtract($E::Call($sqrt,$p),$E::Call($sqrt,$q))),
        $E::AddAssign((& $at $stats $i0),$E::Multiply($d,$d)),$E::AddAssign((& $at $stats $i1),$p),
        $E::Assign($d,$E::Subtract((& $db $p),(& $db $q))),$E::AddAssign($sum,$E::Multiply($d,$d)),
        $E::AddAssign((& $at $ea $f),$p),$E::AddAssign((& $at $eb $f),$q)))
    $body=$E::Block([ParameterExpression[]]@($f,$i,$x,$p,$q,$sum,$d),
        (New-AudioLoop $f $i0 $fc ($E::Block($E::Assign($sum,$d0),$inner,
            $E::AddAssign((& $at $stats $E::Constant(2)),$E::Call($sqrt,$E::Divide($sum,$E::Convert($bc,[double]))))))))
    $k.Spectral=$E::Lambda([Action[double[],double[],int,int,double,double[],double[],double[]]],$body,[ParameterExpression[]]@($pa,$pb,$fc,$bc,$floor,$stats,$ea,$eb)).Compile()

    # Multiply: out[rows x cols] = a[rows x inner] * m[inner x cols].
    $ma=$E::Parameter([double[]],'a'); $rows=$E::Parameter([int],'rows'); $innerCount=$E::Parameter([int],'inner'); $mm=$E::Parameter([double[]],'m')
    $cols=$E::Parameter([int],'cols'); $out=$E::Parameter([double[]],'out'); $r=& $var ([int]) 'r'; $col=& $var ([int]) 'col'; $t=& $var ([int]) 't'
    $body=$E::Block([ParameterExpression[]]@($r,$col,$t,$sum),
        (New-AudioLoop $r $i0 $rows (New-AudioLoop $col $i0 $cols ($E::Block($E::Assign($sum,$d0),
            (New-AudioLoop $t $i0 $innerCount ($E::AddAssign($sum,$E::Multiply((& $at $ma $E::Add($E::Multiply($r,$innerCount),$t)),(& $at $mm $E::Add($E::Multiply($t,$cols),$col)))))),
            $E::Assign((& $at $out $E::Add($E::Multiply($r,$cols),$col)),$sum))))))
    $k.Multiply=$E::Lambda([Action[double[],int,int,double[],int,double[]]],$body,[ParameterExpression[]]@($ma,$rows,$innerCount,$mm,$cols,$out)).Compile()

    # Pitch (YIN, de Cheveigne and Kawahara 2002): per frame (length L every hop) the difference function d(tau) for
    # tau = 1 .. maxLag + 1, its cumulative-mean normalization d'(tau) = d(tau) tau / sum d(1..tau), the first tau >= minLag
    # with d' < 0.15 followed down to its local minimum (else the smallest d' in range), refined by a parabola. Outputs per
    # frame: the lag, d' there (aperiodicity), the normalized autocorrelation at that lag, and the frame's energy.
    $xs=$E::Parameter([double[]],'x'); $len=$E::Parameter([int],'length'); $ph=$E::Parameter([int],'hop'); $pf=$E::Parameter([int],'frames')
    $lo=$E::Parameter([int],'minLag'); $hi=$E::Parameter([int],'maxLag'); $lags=$E::Parameter([double[]],'lags'); $aper=$E::Parameter([double[]],'aperiodicity')
    $corr=$E::Parameter([double[]],'corr'); $energy=$E::Parameter([double[]],'energy'); $scratch=$E::Parameter([double[]],'scratch')
    $lag=& $var ([int]) 'lag'; $e0=& $var ([double]) 'e0'; $e1=& $var ([double]) 'e1'; $num=& $var ([double]) 'num'; $v=& $var ([double]) 'v'; $run=& $var ([double]) 'run'
    $u=& $var ([double]) 'u'; $w=& $var ([double]) 'w'; $state=& $var ([int]) 'state'; $chosen=& $var ([int]) 'chosen'; $minimum=& $var ([int]) 'minimum'; $den=& $var ([double]) 'den'
    $three=$E::Constant(0.15)
    $difference=New-AudioLoop $lag $i1 $E::Add($hi,$E::Constant(2)) ($E::Block($E::Assign($num,$d0),
        (New-AudioLoop $t $i0 $len ($E::Block($E::Assign($v,$E::Subtract((& $at $xs $E::Add($start,$t)),(& $at $xs $E::Add($E::Add($start,$t),$lag)))),$E::AddAssign($num,$E::Multiply($v,$v))))),
        $E::Assign((& $at $scratch $lag),$num)))
    $normalize=$E::Block($E::Assign($run,$d0),(New-AudioLoop $lag $i1 $E::Add($hi,$E::Constant(2)) ($E::Block($E::AddAssign($run,(& $at $scratch $lag)),
        $E::Assign((& $at $scratch $lag),$E::Condition($E::GreaterThan($run,$d0),$E::Divide($E::Multiply((& $at $scratch $lag),$E::Convert($lag,[double])),$run),$E::Constant(1.0)))))))
    $search=$E::Block($E::Assign($state,$i0),$E::Assign($chosen,$lo),$E::Assign($minimum,$lo),
        (New-AudioLoop $lag $lo $E::Add($hi,$i1) ($E::Block(
            $E::IfThen($E::LessThan((& $at $scratch $lag),(& $at $scratch $minimum)),$E::Assign($minimum,$lag)),
            $E::IfThenElse($E::Equal($state,$i0),
                $E::IfThen($E::LessThan((& $at $scratch $lag),$three),$E::Block($E::Assign($chosen,$lag),$E::Assign($state,$i1),$E::Empty())),
                $E::IfThen($E::Equal($state,$i1),$E::IfThenElse($E::LessThan((& $at $scratch $lag),(& $at $scratch $chosen)),$E::Assign($chosen,$lag),$E::Assign($state,$E::Constant(2)))))))),
        $E::IfThen($E::Equal($state,$i0),$E::Assign($chosen,$minimum)))
    $refine=$E::Block($E::Assign($v,$E::Convert($chosen,[double])),
        $E::IfThen($E::AndAlso($E::GreaterThan($chosen,$i1),$E::LessThanOrEqual($chosen,$hi)),$E::Block(
            $E::Assign($den,$E::Add($E::Subtract((& $at $scratch $E::Subtract($chosen,$i1)),$E::Multiply($E::Constant(2.0),(& $at $scratch $chosen))),(& $at $scratch $E::Add($chosen,$i1)))),
            $E::IfThen($E::GreaterThan($den,$d0),$E::AddAssign($v,$E::Divide($E::Subtract((& $at $scratch $E::Subtract($chosen,$i1)),(& $at $scratch $E::Add($chosen,$i1))),$E::Multiply($E::Constant(2.0),$den)))),$E::Empty())))
    $autocorrelation=$E::Block($E::Assign($num,$d0),$E::Assign($e1,$d0),
        (New-AudioLoop $t $i0 $len ($E::Block($E::Assign($u,(& $at $xs $E::Add($start,$t))),$E::Assign($w,(& $at $xs $E::Add($E::Add($start,$t),$chosen))),
            $E::AddAssign($num,$E::Multiply($u,$w)),$E::AddAssign($e1,$E::Multiply($w,$w))))),
        $E::Assign((& $at $corr $f),$E::Condition($E::GreaterThan($E::Multiply($e0,$e1),$d0),$E::Divide($num,$E::Call($sqrt,$E::Multiply($e0,$e1))),$d0)))
    $body=$E::Block([ParameterExpression[]]@($f,$start,$t,$lag,$e0,$e1,$num,$v,$run,$u,$w,$state,$chosen,$minimum,$den),
        (New-AudioLoop $f $i0 $pf ($E::Block($E::Assign($start,$E::Multiply($f,$ph)),$E::Assign($e0,$d0),
            (New-AudioLoop $t $i0 $len ($E::Block($E::Assign($u,(& $at $xs $E::Add($start,$t))),$E::AddAssign($e0,$E::Multiply($u,$u))))),
            $difference,$normalize,$search,$refine,
            $E::Assign((& $at $lags $f),$v),$E::Assign((& $at $aper $f),(& $at $scratch $chosen)),$autocorrelation,$E::Assign((& $at $energy $f),$e0)))))
    $k.Pitch=$E::Lambda([Action[double[],int,int,int,int,int,double[],double[],double[],double[],double[]]],$body,[ParameterExpression[]]@($xs,$len,$ph,$pf,$lo,$hi,$lags,$aper,$corr,$energy,$scratch)).Compile()

    # Correlate: out[lag + maxLag] = sum over t of a[t] * b[t + lag], lag in [-maxLag, maxLag].
    $ca=$E::Parameter([double[]],'a'); $cb=$E::Parameter([double[]],'b'); $maxLag=$E::Parameter([int],'maxLag'); $co=$E::Parameter([double[]],'out')
    $other=& $var ([int]) 'other'
    $body=$E::Block([ParameterExpression[]]@($lag,$t,$other,$sum),
        (New-AudioLoop $lag $E::Negate($maxLag) $E::Add($maxLag,$i1) ($E::Block($E::Assign($sum,$d0),
            (New-AudioLoop $t $i0 $E::ArrayLength($ca) ($E::Block($E::Assign($other,$E::Add($t,$lag)),
                $E::IfThen($E::AndAlso($E::GreaterThanOrEqual($other,$i0),$E::LessThan($other,$E::ArrayLength($cb))),
                    $E::AddAssign($sum,$E::Multiply((& $at $ca $t),(& $at $cb $other))))))),
            $E::Assign((& $at $co $E::Add($lag,$maxLag)),$sum)))))
    $k.Correlate=$E::Lambda([Action[double[],double[],int,double[]]],$body,[ParameterExpression[]]@($ca,$cb,$maxLag,$co)).Compile()

    # Colorize: a width x height RGB image of frames x bins (low frequencies at the bottom); mode 0 maps 10 log10(A), mode 1
    # 10 log10(A) - 10 log10(B), each through [low, high] onto the 256-entry palette.
    $za=$E::Parameter([double[]],'a'); $zb=$E::Parameter([double[]],'b'); $zf=$E::Parameter([int],'frames'); $zbins=$E::Parameter([int],'bins')
    $zw=$E::Parameter([int],'width'); $zh=$E::Parameter([int],'height'); $zlo=$E::Parameter([double],'low'); $zhi=$E::Parameter([double],'high')
    $mode=$E::Parameter([int],'mode'); $palette=$E::Parameter([byte[]],'palette'); $rgb=$E::Parameter([byte[]],'rgb')
    $px=& $var ([int]) 'px'; $py=& $var ([int]) 'py'; $cell=& $var ([int]) 'cell'; $index=& $var ([int]) 'index'; $o=& $var ([int]) 'o'
    $tiny=$E::Constant(1e-20)
    $pixel=$E::Block(
        $E::Assign($cell,$E::Add($E::Multiply($E::Divide($E::Multiply($px,$zf),$zw),$zbins),$E::Divide($E::Multiply($E::Subtract($E::Subtract($zh,$i1),$py),$zbins),$zh))),
        $E::Assign($v,$E::Multiply($E::Constant(10.0),$E::Call($log,$E::Add((& $at $za $cell),$tiny)))),
        $E::IfThen($E::Equal($mode,$i1),$E::SubtractAssign($v,$E::Multiply($E::Constant(10.0),$E::Call($log,$E::Add((& $at $zb $cell),$tiny))))),
        $E::Assign($v,$E::Divide($E::Subtract($v,$zlo),$E::Subtract($zhi,$zlo))),
        $E::Assign($index,$E::Convert($E::Multiply($E::Call([Math].GetMethod('Clamp',[type[]]@([double],[double],[double])),$v,$d0,$E::Constant(1.0)),$E::Constant(255.0)),[int])),
        $E::Assign($o,$E::Multiply($E::Add($E::Multiply($py,$zw),$px),$E::Constant(3))),
        $E::Assign((& $at $rgb $o),(& $at $palette $E::Multiply($index,$E::Constant(3)))),
        $E::Assign((& $at $rgb $E::Add($o,$i1)),(& $at $palette $E::Add($E::Multiply($index,$E::Constant(3)),$i1))),
        $E::Assign((& $at $rgb $E::Add($o,$E::Constant(2))),(& $at $palette $E::Add($E::Multiply($index,$E::Constant(3)),$E::Constant(2)))))
    $body=$E::Block([ParameterExpression[]]@($px,$py,$cell,$index,$o,$v),(New-AudioLoop $py $i0 $zh (New-AudioLoop $px $i0 $zw $pixel)))
    $k.Colorize=$E::Lambda([Action[double[],double[],int,int,int,int,double,double,int,byte[],byte[]]],$body,
        [ParameterExpression[]]@($za,$zb,$zf,$zbins,$zw,$zh,$zlo,$zhi,$mode,$palette,$rgb)).Compile()

    # CRC-32 (PNG chunks) over data with the reflected 0xEDB88320 table.
    $data=$E::Parameter([byte[]],'data'); $table=$E::Parameter([uint32[]],'table'); $crc=& $var ([uint32]) 'crc'
    $body=$E::Block([ParameterExpression[]]@($crc,$i),$E::Assign($crc,$E::Constant([uint32]::MaxValue)),
        (New-AudioLoop $i $i0 $E::ArrayLength($data) ($E::Assign($crc,$E::ExclusiveOr(
            (& $at $table $E::Convert($E::And($E::ExclusiveOr($crc,$E::Convert((& $at $data $i),[uint32])),$E::Constant([uint32]255)),[int])),
            $E::RightShift($crc,$E::Constant(8)))))),
        $E::ExclusiveOr($crc,$E::Constant([uint32]::MaxValue)))
    $k.Crc=$E::Lambda([Func[byte[],uint32[],uint32]],$body,[ParameterExpression[]]@($data,$table)).Compile()
    $script:AnalysisKernels=$k
    return $k
}

# PNG, 8-bit RGB, rows of width*3 bytes.
function Write-KokoroPng {
    param([string]$Path,[int]$Width,[int]$Height,[byte[]]$Rgb)
    $raw=[byte[]]::new($Height*(1+3*$Width))
    for ($y=0; $y -lt $Height; $y++) { [Array]::Copy($Rgb,3*$Width*$y,$raw,$y*(1+3*$Width)+1,3*$Width) }
    $compressed=[IO.MemoryStream]::new(); $z=[IO.Compression.ZLibStream]::new($compressed,[IO.Compression.CompressionLevel]::Optimal,$true)
    $z.Write($raw,0,$raw.Length); $z.Dispose()
    $table=[uint32[]]::new(256); for ($n=0; $n -lt 256; $n++) { $c=[uint32]$n; for ($bit=0; $bit -lt 8; $bit++) { $c=if ($c -band 1) { [uint32](3988292384 -bxor ($c -shr 1)) } else { [uint32]($c -shr 1) } }; $table[$n]=$c }
    $crc=(Get-KokoroAudioAnalysisKernels).Crc
    $bigEndian={ param([uint32]$v) $b=[BitConverter]::GetBytes($v); [Array]::Reverse($b); ,$b }
    $file=[IO.MemoryStream]::new(); $file.Write([byte[]](137,80,78,71,13,10,26,10),0,8)
    $chunk={ param([string]$Type,[byte[]]$Data)
        $typed=[byte[]]::new(4+$Data.Length); [Text.Encoding]::ASCII.GetBytes($Type).CopyTo($typed,0); $Data.CopyTo($typed,4)
        $file.Write((& $bigEndian ([uint32]$Data.Length)),0,4); $file.Write($typed,0,$typed.Length); $file.Write((& $bigEndian ($crc.Invoke($typed,$table))),0,4) }
    $header=[byte[]]::new(13); (& $bigEndian ([uint32]$Width)).CopyTo($header,0); (& $bigEndian ([uint32]$Height)).CopyTo($header,4); $header[8]=8; $header[9]=2
    & $chunk 'IHDR' $header; & $chunk 'IDAT' $compressed.ToArray(); & $chunk 'IEND' ([byte[]]::new(0))
    [IO.File]::WriteAllBytes($Path,$file.ToArray())
}

# 256-entry palettes: Magnitude (black, purple, orange, yellow) and Difference (blue, white, red).
function Get-KokoroAudioPalette {
    param([ValidateSet('Magnitude','Difference')][string]$Kind)
    $stops=if ($Kind -eq 'Magnitude') { @(@(0,0,0,4),@(0.3,80,18,123),@(0.6,220,70,60),@(0.85,250,165,20),@(1,252,255,164)) } else { @(@(0,30,70,200),@(0.5,255,255,255),@(1,200,30,40)) }
    $palette=[byte[]]::new(768)
    for ($n=0; $n -lt 256; $n++) {
        $t=$n/255.0; $s=0; while ($s -lt $stops.Count-2 -and $t -gt $stops[$s+1][0]) { $s++ }
        $a=$stops[$s]; $b=$stops[$s+1]; $u=($t-$a[0])/($b[0]-$a[0])
        for ($ch=0; $ch -lt 3; $ch++) { $palette[3*$n+$ch]=[byte][Math]::Round($a[$ch+1]+$u*($b[$ch+1]-$a[$ch+1])) }
    }
    ,$palette
}

# Line plot of series over a common x axis: each series a double[] (NaN leaves a gap) and an RGB color.
function Write-KokoroLinePlot {
    param([string]$Path,[object[]]$Series,[double]$Low,[double]$High,[int]$Width=1200,[int]$Height=300)
    $rgb=[byte[]]::new(3*$Width*$Height); [Array]::Fill($rgb,[byte]255)
    $set={ param([int]$x,[int]$y,[byte[]]$color) if ($x -ge 0 -and $x -lt $Width -and $y -ge 0 -and $y -lt $Height) { $o=3*($y*$Width+$x); $rgb[$o]=$color[0]; $rgb[$o+1]=$color[1]; $rgb[$o+2]=$color[2] } }
    for ($g=1; $g -lt 4; $g++) { $y=[int]($g*$Height/4); for ($x=0; $x -lt $Width; $x+=4) { & $set $x $y ([byte[]](210,210,210)) } }
    foreach ($entry in $Series) {
        $values=[double[]]$entry.Values; $color=[byte[]]$entry.Color; $count=$values.Length; $previous=$null
        for ($n=0; $n -lt $count; $n++) {
            $value=$values[$n]
            if ([double]::IsNaN($value)) { $previous=$null; continue }
            $x=[int][Math]::Round($n*($Width-1)/[Math]::Max(1,$count-1)); $y=[int][Math]::Round(($Height-1)*(1-([Math]::Clamp($value,$Low,$High)-$Low)/($High-$Low)))
            if ($null -ne $previous) {
                $steps=[Math]::Max([Math]::Abs($x-$previous[0]),[Math]::Abs($y-$previous[1]))
                for ($q=0; $q -le $steps; $q++) { $f=if ($steps) { $q/$steps } else { 0 }; & $set ([int][Math]::Round($previous[0]+$f*($x-$previous[0]))) ([int][Math]::Round($previous[1]+$f*($y-$previous[1]))) $color; & $set ([int][Math]::Round($previous[0]+$f*($x-$previous[0]))) ([int][Math]::Round($previous[1]+$f*($y-$previous[1])+1)) $color }
            } else { & $set $x $y $color }
            $previous=@($x,$y)
        }
    }
    Write-KokoroPng $Path $Width $Height $rgb
}

# Power spectrogram of mono samples at window n (Hann), hop n/4.
function Get-KokoroAudioSpectrogram {
    param([double[]]$Samples,[int]$Window)
    $hop=[int]($Window/4); $frames=[Math]::Max(0,[int][Math]::Floor(($Samples.Length-$Window)/$hop)+1); $bins=[int]($Window/2+1)
    $hann=[double[]]::new($Window); for ($i=0; $i -lt $Window; $i++) { $hann[$i]=0.5-0.5*[Math]::Cos(2*[Math]::PI*$i/$Window) }
    $bitsCount=[int][Math]::Log2($Window); $reverse=[int[]]::new($Window)
    for ($i=0; $i -lt $Window; $i++) { $r=0; for ($bit=0; $bit -lt $bitsCount; $bit++) { if ($i -band (1 -shl $bit)) { $r=$r -bor (1 -shl ($bitsCount-1-$bit)) } }; $reverse[$i]=$r }
    $cosT=[double[]]::new($Window/2); $sinT=[double[]]::new($Window/2)
    for ($i=0; $i -lt $Window/2; $i++) { $cosT[$i]=[Math]::Cos(2*[Math]::PI*$i/$Window); $sinT[$i]=[Math]::Sin(2*[Math]::PI*$i/$Window) }
    $power=[double[]]::new($frames*$bins)
    (Get-KokoroAudioAnalysisKernels).Spectrum.Invoke($Samples,$Window,$hop,$frames,$hann,$reverse,$cosT,$sinT,[double[]]::new($Window),[double[]]::new($Window),$power)
    [pscustomobject]@{ Power=$power; Frames=$frames; Bins=$bins; Hop=$hop; Window=$Window }
}

# Per 10 ms frame (40 ms analysis, 60-500 Hz): f0 by YIN; voiced where its aperiodicity is below 0.2 and the frame is
# within 40 dB of the loudest; HNR = 10 log10(r / (1 - r)) from the normalized autocorrelation r at the chosen lag.
function Get-KokoroAudioPitch {
    param([double[]]$Samples,[int]$Rate)
    $minLag=[int][Math]::Floor($Rate/500.0); $maxLag=[int][Math]::Ceiling($Rate/60.0); $length=[int]($Rate*0.04); $hop=[int]($Rate*0.01)
    $frames=[Math]::Max(0,[int][Math]::Floor(($Samples.Length-$length-$maxLag-2)/$hop)+1)
    $lags=[double[]]::new($frames); $aperiodicity=[double[]]::new($frames); $corr=[double[]]::new($frames); $energy=[double[]]::new($frames)
    (Get-KokoroAudioAnalysisKernels).Pitch.Invoke($Samples,$length,$hop,$frames,$minLag,$maxLag,$lags,$aperiodicity,$corr,$energy,[double[]]::new($maxLag+3))
    $loudest=if ($frames) { [Linq.Enumerable]::Max($energy) } else { 0 }
    $f0=[double[]]::new($frames); $hnr=[Collections.Generic.List[double]]::new()
    for ($n=0; $n -lt $frames; $n++) {
        $voiced=$aperiodicity[$n] -lt 0.2 -and $energy[$n] -gt 0 -and $energy[$n] -ge $loudest*1e-4 -and $lags[$n] -gt 0
        $f0[$n]=if ($voiced) { $Rate/$lags[$n] } else { [double]::NaN }
        if ($voiced -and $corr[$n] -lt 1) { $hnr.Add(10*[Math]::Log10($corr[$n]/(1-$corr[$n]))) }
    }
    [pscustomobject]@{ F0=$f0; HnrDb=$(if ($hnr.Count) { ($hnr | Measure-Object -Average).Average } else { [double]::NaN }) }
}

function Compare-KokoroAudioData {
    param([KokoroAudioData]$Reference,[KokoroAudioData]$Candidate,[string]$ReferenceName,[string]$CandidateName,[string]$ImageDirectory)
    if ($Reference.Channels -ne 1 -or $Candidate.Channels -ne 1 -or $Reference.SampleRate -ne $Candidate.SampleRate) { throw 'Comparison needs two mono WAVs at one sample rate.' }
    $kernels=Get-KokoroAudioAnalysisKernels; $rate=$Reference.SampleRate; $count=[Math]::Min($Reference.Samples.Length,$Candidate.Samples.Length)
    $a=[double[]]::new($count); [Array]::Copy($Reference.Samples,$a,$count); $b=[double[]]::new($count); [Array]::Copy($Candidate.Samples,$b,$count)
    $result=[KokoroAudioComparison]::new(); $result.Reference=$ReferenceName; $result.Candidate=$CandidateName; $result.Seconds=$count/[double]$rate
    $snr={ param([double]$Signal,[double]$Residual) if ($Residual -le 0) { [double]::PositiveInfinity } else { 10*[Math]::Log10($Signal/$Residual) } }
    # Waveform: SNR at zero lag, and the lag (within 20 ms) of greatest cross-correlation.
    $signal=0.0; $residual=0.0; for ($n=0; $n -lt $count; $n++) { $signal+=$a[$n]*$a[$n]; $d=$a[$n]-$b[$n]; $residual+=$d*$d }
    $result.WaveformSnrDb=& $snr $signal $residual
    $maxLag=[int]($rate*0.02); $xc=[double[]]::new(2*$maxLag+1); $kernels.Correlate.Invoke($a,$b,$maxLag,$xc)
    $result.BestLagSamples=[Array]::IndexOf($xc,[Linq.Enumerable]::Max($xc))-$maxLag
    # Spectra at three resolutions.
    $resolutions=foreach ($window in 512,1024,2048) {
        $sa=Get-KokoroAudioSpectrogram $a $window; $sb=Get-KokoroAudioSpectrogram $b $window
        if (-not $sa.Frames) { continue }
        $stats=[double[]]::new(3); $ea=[double[]]::new($sa.Frames); $eb=[double[]]::new($sa.Frames)
        $floor=[Math]::Max(1e-20,[Linq.Enumerable]::Max($sa.Power)*1e-8)
        $kernels.Spectral.Invoke($sa.Power,$sb.Power,$sa.Frames,$sa.Bins,$floor,$stats,$ea,$eb)
        $entry=[KokoroAudioResolution]::new(); $entry.Window=$window; $entry.MagnitudeSnrDb=& $snr $stats[1] $stats[0]
        $entry.LogSpectralDistanceDb=$stats[2]/$sa.Frames; $entry.SpectralConvergence=[Math]::Sqrt($stats[0]/[Math]::Max($stats[1],1e-300))
        $entry
        if ($window -eq 1024) { $main=@{A=$sa;B=$sb;EnergyA=$ea;EnergyB=$eb} }
    }
    $result.Resolutions=@($resolutions)
    $result.MagnitudeSnrDb=($result.Resolutions | Measure-Object MagnitudeSnrDb -Average).Average
    $result.LogSpectralDistanceDb=($result.Resolutions | Measure-Object LogSpectralDistanceDb -Average).Average
    # Loudness envelope (1024 frames within 60 dB of the loudest) and integrated loudness.
    $top=[Linq.Enumerable]::Max($main.EnergyA); $xa=[Collections.Generic.List[double]]::new(); $xb=[Collections.Generic.List[double]]::new()
    for ($n=0; $n -lt $main.EnergyA.Length; $n++) { if ($main.EnergyA[$n] -ge $top*1e-6) { $xa.Add(10*[Math]::Log10($main.EnergyA[$n]+1e-300)); $xb.Add(10*[Math]::Log10($main.EnergyB[$n]+1e-300)) } }
    $meanA=($xa | Measure-Object -Average).Average; $meanB=($xb | Measure-Object -Average).Average; $num=0.0; $va=0.0; $vb=0.0
    for ($n=0; $n -lt $xa.Count; $n++) { $num+=($xa[$n]-$meanA)*($xb[$n]-$meanB); $va+=($xa[$n]-$meanA)*($xa[$n]-$meanA); $vb+=($xb[$n]-$meanB)*($xb[$n]-$meanB) }
    $result.EnvelopeCorrelation=if ($va -gt 0 -and $vb -gt 0) { $num/[Math]::Sqrt($va*$vb) } else { 1.0 }
    $la=Measure-KokoroAudioData $Reference $ReferenceName; $lb=Measure-KokoroAudioData $Candidate $CandidateName; $result.LoudnessDifferenceLu=$lb.IntegratedLufs-$la.IntegratedLufs
    # Mel-cepstral distortion: 80 HTK mel bands, natural-log energies, orthonormal DCT-II coefficients 1..24,
    # MCD = (10 / ln 10) sqrt(2 sum (dc)^2), averaged over frames within 60 dB of the loudest.
    $bins=$main.A.Bins; $mels=80; $toMel={ param($hz) 2595*[Math]::Log10(1+$hz/700.0) }; $fromMel={ param($m) 700*([Math]::Pow(10,$m/2595.0)-1) }
    $edges=for ($m=0; $m -le $mels+1; $m++) { & $fromMel ((& $toMel ($rate/2.0))*$m/($mels+1)) }
    $bank=[double[]]::new($bins*$mels)
    for ($m=0; $m -lt $mels; $m++) { for ($bin=0; $bin -lt $bins; $bin++) { $hz=$bin*$rate/(2.0*($bins-1))
        $w=if ($hz -ge $edges[$m] -and $hz -le $edges[$m+1]) { ($hz-$edges[$m])/($edges[$m+1]-$edges[$m]) } elseif ($hz -gt $edges[$m+1] -and $hz -le $edges[$m+2]) { ($edges[$m+2]-$hz)/($edges[$m+2]-$edges[$m+1]) } else { 0 }
        $bank[$bin*$mels+$m]=$w } }
    $coefficients=24; $dct=[double[]]::new($mels*$coefficients)
    for ($m=0; $m -lt $mels; $m++) { for ($q=0; $q -lt $coefficients; $q++) { $dct[$m*$coefficients+$q]=[Math]::Sqrt(2.0/$mels)*[Math]::Cos([Math]::PI*($q+1)*($m+0.5)/$mels) } }
    $cepstra={ param($power,[int]$frames) $melPower=[double[]]::new($frames*$mels); $kernels.Multiply.Invoke($power,$frames,$bins,$bank,$mels,$melPower)
        $melFloor=[Math]::Max(1e-30,[Linq.Enumerable]::Max($melPower)*1e-6)
        for ($n=0; $n -lt $melPower.Length; $n++) { $melPower[$n]=[Math]::Log([Math]::Max($melPower[$n],$melFloor)) }
        $c=[double[]]::new($frames*$coefficients); $kernels.Multiply.Invoke($melPower,$frames,$mels,$dct,$coefficients,$c); ,$c }
    $frames=$main.A.Frames; $ca=& $cepstra $main.A.Power $frames; $cb=& $cepstra $main.B.Power $frames
    $distortion=[Collections.Generic.List[double]]::new()
    for ($n=0; $n -lt $frames; $n++) { if ($main.EnergyA[$n] -lt $top*1e-6) { continue }
        $sum=0.0; for ($q=0; $q -lt $coefficients; $q++) { $d=$ca[$n*$coefficients+$q]-$cb[$n*$coefficients+$q]; $sum+=$d*$d }
        $distortion.Add((10/[Math]::Log(10))*[Math]::Sqrt(2*$sum)) }
    $result.MelCepstralDistortionDb=if ($distortion.Count) { ($distortion | Measure-Object -Average).Average } else { 0 }
    # Pitch and voicing.
    $pa=Get-KokoroAudioPitch $a $rate; $pb=Get-KokoroAudioPitch $b $rate
    $agree=0; $total=0; $cents=[Collections.Generic.List[double]]::new()
    for ($n=0; $n -lt $pa.F0.Length; $n++) { $va=-not [double]::IsNaN($pa.F0[$n]); $vb=-not [double]::IsNaN($pb.F0[$n])
        if ($va -or $vb) { $total++; if ($va -eq $vb) { $agree++ } }
        if ($va -and $vb) { $cents.Add(1200*[Math]::Log($pb.F0[$n]/$pa.F0[$n],2)) } }
    $result.VoicingAgreement=if ($total) { $agree/[double]$total } else { 1.0 }
    $result.F0RmseCents=if ($cents.Count) { [Math]::Sqrt(($cents | ForEach-Object { $_*$_ } | Measure-Object -Average).Average) } else { 0 }
    $result.ReferenceF0MeanHz=($pa.F0 | Where-Object { -not [double]::IsNaN($_) } | Measure-Object -Average).Average
    $result.CandidateF0MeanHz=($pb.F0 | Where-Object { -not [double]::IsNaN($_) } | Measure-Object -Average).Average
    $result.ReferenceHnrDb=$pa.HnrDb; $result.CandidateHnrDb=$pb.HnrDb
    # Pictures: 1024-point spectrograms (top 80 dB) and their difference (+-20 dB), f0 tracks, loudness envelopes.
    if ($ImageDirectory) {
        [void][IO.Directory]::CreateDirectory($ImageDirectory); $images=[Collections.Generic.List[string]]::new()
        $width=[Math]::Min(1200,[Math]::Max(200,$frames)); $height=257; $peak=10*[Math]::Log10([Linq.Enumerable]::Max($main.A.Power)+1e-300)
        foreach ($picture in @(@('spectrogram-reference.png',$main.A.Power,$null,0,'Magnitude',($peak-80),$peak),@('spectrogram-candidate.png',$main.B.Power,$null,0,'Magnitude',($peak-80),$peak),@('spectrogram-difference.png',$main.B.Power,$main.A.Power,1,'Difference',-20.0,20.0))) {
            $rgb=[byte[]]::new(3*$width*$height)
            $kernels.Colorize.Invoke([double[]]$picture[1],$(if ($null -ne $picture[2]) { [double[]]$picture[2] } else { [double[]]$picture[1] }),$frames,$bins,$width,$height,[double]$picture[5],[double]$picture[6],[int]$picture[3],(Get-KokoroAudioPalette $picture[4]),$rgb)
            $path=Join-Path $ImageDirectory $picture[0]; Write-KokoroPng $path $width $height $rgb; $images.Add($path)
        }
        $path=Join-Path $ImageDirectory 'pitch.png'; Write-KokoroLinePlot $path @(@{Values=$pa.F0;Color=[byte[]](30,70,200)},@{Values=$pb.F0;Color=[byte[]](200,30,40)}) 50 400; $images.Add($path)
        $envA=[double[]]::new($frames); $envB=[double[]]::new($frames); for ($n=0; $n -lt $frames; $n++) { $envA[$n]=10*[Math]::Log10($main.EnergyA[$n]+1e-300); $envB[$n]=10*[Math]::Log10($main.EnergyB[$n]+1e-300) }
        $path=Join-Path $ImageDirectory 'envelope.png'; Write-KokoroLinePlot $path @(@{Values=$envA;Color=[byte[]](30,70,200)},@{Values=$envB;Color=[byte[]](200,30,40)}) (10*[Math]::Log10($top+1e-300)-70) (10*[Math]::Log10($top+1e-300)+3); $images.Add($path)
        $result.Images=$images.ToArray()
    }
    return $result
}

function Compare-KokoroAudio {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reference,[Parameter(Mandatory)][string]$Candidate,[string]$Yardstick,[string]$ImageDirectory)
    $read={ param([string]$p) Read-KokoroAudioBytes ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $p).Path)) }
    $referenceAudio=& $read $Reference
    $result=Compare-KokoroAudioData $referenceAudio (& $read $Candidate) $Reference $Candidate $ImageDirectory
    # The yardstick: the same comparison between the reference and a render the same by construction (another seed).
    if ($Yardstick) { $result.Yardstick=Compare-KokoroAudioData $referenceAudio (& $read $Yardstick) $Reference $Yardstick $null }
    $result
}

Export-ModuleMember -Function Measure-KokoroAudio,Test-KokoroAudioMeasurement,Compare-KokoroAudio
