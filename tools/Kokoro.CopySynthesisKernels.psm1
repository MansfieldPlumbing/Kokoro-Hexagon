using namespace System.Linq.Expressions
# Offline numeric kernels, authored in PowerShell expression trees, following
# Kokoro.CaptureKernels.psm1. No source compiler, native library or extra dependency.
Set-StrictMode -Version Latest

function New-CopyLoop {
    param([ParameterExpression]$Index,[Expression]$Limit,[Expression]$Body,[int]$Start=0)
    $done=[Expression]::Label('done')
    [Expression]::Block([Expression]::Assign($Index,[Expression]::Constant($Start)),
        [Expression]::Loop([Expression]::IfThenElse([Expression]::LessThan($Index,$Limit),
            [Expression]::Block($Body,[Expression]::PostIncrementAssign($Index),[Expression]::Empty()),
            [Expression]::Break($done)),$done))
}
function New-CopyMath {
    param([string]$Name,[Expression[]]$Arguments)
    $types=[Type[]]::new($Arguments.Length);[Array]::Fill($types,[double])
    [Expression]::Call([math].GetMethod($Name,$types),$Arguments)
}
function New-CopyKernel {
    param([Type]$Delegate,[ParameterExpression[]]$Parameters,[ParameterExpression[]]$Variables,[Expression[]]$Body,[switch]$Value)
    if(-not $Value){$Body+= [Expression]::Empty()}
    [Expression]::Lambda($Delegate,[Expression]::Block($Variables,$Body),$Parameters).Compile()
}
function Get-KokoroCopySynthesisKernels {
    param([int]$Length,[double[]]$Window,[int[]]$PeriodBand)
    $E=[Expression];$size=$E::Constant($Length);$bins=$E::Constant(1+$Length/2 -as [int])
    $zero=$E::Constant(0);$one=$E::Constant(1);$dz=$E::Constant(0.0);$do=$E::Constant(1.0)
    $i=$E::Variable([int],'index');$at=$E::Variable([int],'address');$h=$E::Variable([int],'harmonic');$band=$E::Variable([int],'band')
    $sum=$E::Variable([double],'sum');$fraction=$E::Variable([double],'fraction');$value=$E::Variable([double],'value')
    $a=$E::Parameter([double[]],'a');$b=$E::Parameter([double[]],'b');$c=$E::Parameter([double[]],'c');$d=$E::Parameter([double[]],'d')
    $center=$E::Parameter([int],'center');$gain=$E::Parameter([double],'gain')
    $ai=$E::ArrayAccess($a,$i);$bi=$E::ArrayAccess($b,$i)
    $di=$E::ArrayAccess($d,$i);$ci=$E::ArrayAccess($c,$i)
    $asDouble={param([Expression]$x) $E::Convert($x,[double])}
    $valid=$E::AndAlso($E::GreaterThanOrEqual($at,$zero),$E::LessThan($at,$E::ArrayLength($a)))
    $kernels=[ordered]@{}
    $kernels.Window=New-CopyKernel ([Action[double[],int,double[],double[]]]) @($a,$center,$b,$d) @($i,$at) @(
        (New-CopyLoop $i $size ($E::Block(
            $E::Assign($at,$E::Subtract($E::Add($center,$i),$E::Constant($Length/2 -as [int]))),
            $E::Assign($di,$E::Condition($valid,$E::Multiply($E::ArrayIndex($a,$at),$bi),$dz))))))
    $imag=$E::ArrayIndex($a,$E::Add($i,$bins))
    $kernels.Power=New-CopyKernel ([Action[double[],double[],double]]) @($a,$b,$gain) @($i) @(
        (New-CopyLoop $i $bins ($E::Assign($bi,$E::Multiply($gain,$E::Multiply(
            $E::Condition($E::OrElse($E::Equal($i,$zero),$E::Equal($i,$E::Subtract($bins,$one))),$E::Constant(0.5),$do),
            $E::Add($E::Multiply($ai,$ai),$E::Multiply($imag,$imag))))))))
    $freq=$E::Multiply((& $asDouble $i),$E::Constant(24000.0/$Length))
    $nearest=New-CopyMath Round @($E::Divide($freq,$gain))
    $distance=New-CopyMath Abs @($E::Subtract($freq,$E::Multiply($nearest,$gain)))
    $margin=New-CopyMath Min @($E::Multiply($gain,$E::Constant(0.4)),$E::Constant(24000.0/$Length))
    $mask=$E::AndAlso($E::GreaterThan($gain,$dz),$E::AndAlso($E::GreaterThan($i,$zero),$E::LessThanOrEqual($distance,$margin)))
    $envIndex=$E::Divide($E::Multiply($i,$E::Constant(64)),$bins)
    $pb=$E::ArrayIndex($E::Constant($PeriodBand),$i)
    $kernels.Bands=New-CopyKernel ([Action[double[],double,double[]]]) @($a,$gain,$b) @($i,$band) @(
        (New-CopyLoop $i $bins ($E::Block(
            $E::Assign($band,$pb),
            $E::AddAssign($E::ArrayAccess($b,$envIndex),$ai),
            $E::AddAssign($E::ArrayAccess($b,$E::Add($band,$E::Constant(64))),$ai),
            $E::IfThen($mask,$E::Block(
                $E::AddAssign($E::ArrayAccess($b,$E::Add($band,$E::Constant(76))),$ai),
                $E::AddAssign($E::ArrayAccess($b,$E::Add($band,$E::Constant(88))),$do),$E::Empty()))))))
    # Fundamental phase is integrated at the sample clock from captured F0's 300-sample grid.
    $pos=$E::Divide($E::Subtract((& $asDouble $i),$E::Constant(0.5)),$E::Constant(300.0))
    $last=$E::Subtract($E::ArrayLength($a),$one)
    $kernels.Phase=New-CopyKernel ([Action[double[],double[]]]) @($a,$b) @($i,$at,$fraction,$value) @(
        $E::Assign($E::ArrayAccess($b,$zero),$dz),
        (New-CopyLoop $i ($E::ArrayLength($b)) ($E::Block(
            $E::Assign($at,$E::Convert($pos,[int])),
            $E::Assign($fraction,$E::Subtract($pos,(& $asDouble $at))),
            $E::IfThen($E::GreaterThanOrEqual($at,$last),$E::Block($E::Assign($at,$last),$E::Assign($fraction,$dz),$E::Empty())),
            $E::Assign($value,$E::Add($E::Multiply($E::ArrayIndex($a,$at),$E::Subtract($do,$fraction)),
                $E::Multiply($E::ArrayIndex($a,$E::Condition($E::LessThan($at,$last),$E::Add($at,$one),$at)),$fraction))),
            $E::Assign($bi,$E::Modulo($E::Add($E::ArrayIndex($b,$E::Subtract($i,$one)),
                $E::Multiply($value,$E::Constant(2*[math]::PI/24000))),$E::Constant(2*[math]::PI))))) -Start 1))
    $noiseGain=New-CopyMath Sqrt @((New-CopyMath Max @($dz,$E::Multiply($E::Multiply($bi,$E::Subtract($do,$ci)),$E::Constant($Length/2.0)))))
    $kernels.Noise=New-CopyKernel ([Action[double[],double[],double[],double[]]]) @($a,$b,$c,$d) @($i,$value) @(
        (New-CopyLoop $i $bins ($E::Block($E::Assign($value,$noiseGain),
            $E::Assign($di,$E::Multiply($ai,$value)),
            $E::Assign($E::ArrayAccess($d,$E::Add($i,$bins)),$E::Multiply($imag,$value))))))
    $binPos=$E::Multiply((& $asDouble $i),$E::Multiply($gain,$E::Constant($Length/24000.0)))
    $sampleEnv=$E::Add($E::Multiply($E::ArrayIndex($a,$at),$E::Subtract($do,$fraction)),
        $E::Multiply($E::ArrayIndex($a,$h),$fraction))
    $samplePeriod=$E::Add($E::Multiply($E::ArrayIndex($b,$at),$E::Subtract($do,$fraction)),
        $E::Multiply($E::ArrayIndex($b,$h),$fraction))
    $amplitude=New-CopyMath Sqrt @((New-CopyMath Max @($dz,$E::Multiply($E::Multiply($sampleEnv,$samplePeriod),$E::Multiply($gain,$E::Constant(2*$Length/24000.0))))))
    $kernels.Amplitudes=New-CopyKernel ([Action[double[],double[],double,double[]]]) @($a,$b,$gain,$c) @($i,$at,$h,$fraction) @(
        $E::Assign($E::ArrayAccess($c,$zero),$dz),
        (New-CopyLoop $i ($E::ArrayLength($c)) ($E::Block($E::Assign($at,$E::Convert($binPos,[int])),
            $E::Assign($fraction,$E::Subtract($binPos,(& $asDouble $at))),
            $E::Assign($h,$E::Condition($E::LessThan($at,$E::Subtract($bins,$one)),$E::Add($at,$one),$at)),
            $E::Assign($ci,$amplitude))) -Start 1))
    $phaseAt=$E::ArrayIndex($a,$at)
    $harm=$E::Multiply($E::ArrayIndex($b,$h),(New-CopyMath Cos @($E::Multiply((& $asDouble $h),$phaseAt))))
    $kernels.Harmonics=New-CopyKernel ([Action[double[],int,double[],double[],double[]]]) @($a,$center,$b,$c,$d) @($i,$at,$h,$sum) @(
        (New-CopyLoop $i $size ($E::Block(
            $E::Assign($at,$E::Subtract($E::Add($center,$i),$E::Constant($Length/2 -as [int]))),
            $E::IfThen($valid,$E::Block($E::Assign($sum,$dz),
                (New-CopyLoop $h ($E::ArrayLength($b)) ($E::AddAssign($sum,$harm)) -Start 1),
                $E::AddAssign($di,$E::Multiply($sum,$ci)),$E::Empty()))))))
    $validOut=$E::AndAlso($E::GreaterThanOrEqual($at,$zero),$E::LessThan($at,$E::ArrayLength($c)))
    $kernels.Overlap=New-CopyKernel ([Action[double[],int,double[],double[],double[]]]) @($a,$center,$b,$c,$d) @($i,$at) @(
        (New-CopyLoop $i $size ($E::Block(
            $E::Assign($at,$E::Subtract($E::Add($center,$i),$E::Constant($Length/2 -as [int]))),
            $E::IfThen($validOut,$E::Block($E::AddAssign($E::ArrayAccess($c,$at),$ai),
                $E::AddAssign($E::ArrayAccess($d,$at),$bi),$E::Empty()))))))
    $kernels.Normalize=New-CopyKernel ([Action[double[],double[]]]) @($a,$b) @($i) @(
        (New-CopyLoop $i ($E::ArrayLength($a)) ($E::DivideAssign($ai,(New-CopyMath Max @($bi,$E::Constant(1e-12)))))))
    $kernels.Scale=New-CopyKernel ([Action[double[],double]]) @($a,$gain) @($i) @(
        (New-CopyLoop $i ($E::ArrayLength($a)) ($E::MultiplyAssign($ai,$gain))))
    $kernels.Dot=New-CopyKernel ([Func[double[],double[],double]]) @($a,$b) @($i,$sum) @(
        $E::Assign($sum,$dz),(New-CopyLoop $i ($E::ArrayLength($a)) ($E::AddAssign($sum,$E::Multiply($ai,$bi)))),$sum) -Value
    $kernels.Log=New-CopyKernel ([Action[double[],double,double[]]]) @($a,$gain,$b) @($i) @(
        (New-CopyLoop $i ($E::ArrayLength($a)) ($E::Assign($bi,$E::Multiply($E::Constant(10.0),
            (New-CopyMath Log10 @((New-CopyMath Max @($ai,$gain)))))))))
    $difference=$E::Subtract($ai,$bi)
    $kernels.SquaredDistance=New-CopyKernel ([Func[double[],double[],double]]) @($a,$b) @($i,$sum) @(
        $E::Assign($sum,$dz),(New-CopyLoop $i ($E::ArrayLength($a)) ($E::AddAssign($sum,$E::Multiply($difference,$difference)))),$sum) -Value
    $raw=$E::Parameter([byte[]],'raw')
    $kernels.WhiteNoise=New-CopyKernel ([Action[byte[],double[]]]) @($raw,$b) @($i) @(
        (New-CopyLoop $i ($E::ArrayLength($b)) ($E::Assign($bi,$E::Divide(
            $E::Subtract($E::Convert($E::ArrayIndex($raw,$i),[double]),$E::Constant(127.5)),
            $E::Constant([math]::Sqrt(5461.25)))))))
    $sumA=$E::Variable([double],'sumA');$sumB=$E::Variable([double],'sumB')
    $squaredA=$E::Variable([double],'squaredA');$squaredB=$E::Variable([double],'squaredB');$cross=$E::Variable([double],'cross')
    $count=$E::Convert($E::ArrayLength($a),[double])
    # Two passes: first means, then centered covariance and centered variances.
    # Avoid subtracting large nearly equal raw second moments at the log floor.
    $centeredA=$E::Subtract($ai,$sumA);$centeredB=$E::Subtract($bi,$sumB)
    $denominator=$E::Multiply((New-CopyMath Sqrt @($squaredA)),(New-CopyMath Sqrt @($squaredB)))
    $undefined=$E::Throw($E::Constant([InvalidOperationException]::new(
        'Correlation requires positive variance in both paired populations.')),[double])
    $kernels.Correlation=New-CopyKernel ([Func[double[],double[],double]]) @($a,$b) @($i,$sumA,$sumB,$squaredA,$squaredB,$cross) @(
        $E::Assign($sumA,$dz),$E::Assign($sumB,$dz),$E::Assign($squaredA,$dz),$E::Assign($squaredB,$dz),$E::Assign($cross,$dz),
        (New-CopyLoop $i ($E::ArrayLength($a)) ($E::Block($E::AddAssign($sumA,$ai),$E::AddAssign($sumB,$bi)))),
        $E::DivideAssign($sumA,$count),$E::DivideAssign($sumB,$count),
        (New-CopyLoop $i ($E::ArrayLength($a)) ($E::Block(
            $E::AddAssign($squaredA,$E::Multiply($centeredA,$centeredA)),
            $E::AddAssign($squaredB,$E::Multiply($centeredB,$centeredB)),
            $E::AddAssign($cross,$E::Multiply($centeredA,$centeredB))))),
        $E::Condition($E::AndAlso($E::GreaterThan($squaredA,$dz),$E::GreaterThan($squaredB,$dz)),
            $E::Condition($E::AndAlso($E::Equal($cross,$squaredA),$E::Equal($cross,$squaredB)),
                $do,$E::Divide($cross,$denominator)),$undefined)) -Value
    # Continuous harmonic tracks: linear amplitude, and smooth unwrapped phase
    # corrections relative to the shared F0 integral. Corrections have zero slope
    # at frame knots, so instantaneous frequency is continuous at those knots.
    $hop=$E::Parameter([int],'hop')
    $amplitudes=$E::Parameter([double[][]],'amplitudes');$offsets=$E::Parameter([double[][]],'offsets')
    $frameAmplitude=$E::Variable([double[]],'frameAmplitude');$nextAmplitude=$E::Variable([double[]],'nextAmplitude')
    $frameOffset=$E::Variable([double[]],'frameOffset');$nextOffset=$E::Variable([double[]],'nextOffset')
    $frame=$E::Variable([int],'frame');$next=$E::Variable([int],'next')
    $limit=$E::Variable([int],'trackLimit')
    $blend=$E::Variable([double],'blend');$amplitudeValue=$E::Variable([double],'amplitudeValue')
    $correction=$E::Variable([double],'correction')
    $trackFrames=$E::ArrayLength($amplitudes)
    $firstAmplitude=$E::Condition($E::LessThan($h,$E::ArrayLength($frameAmplitude)),$E::ArrayIndex($frameAmplitude,$h),$dz)
    $secondAmplitude=$E::Condition($E::LessThan($h,$E::ArrayLength($nextAmplitude)),$E::ArrayIndex($nextAmplitude,$h),$dz)
    $firstOffset=$E::Condition($E::LessThan($h,$E::ArrayLength($frameOffset)),$E::ArrayIndex($frameOffset,$h),
        $E::Condition($E::LessThan($h,$E::ArrayLength($nextOffset)),$E::ArrayIndex($nextOffset,$h),$dz))
    $secondOffset=$E::Condition($E::LessThan($h,$E::ArrayLength($nextOffset)),$E::ArrayIndex($nextOffset,$h),$firstOffset)
    $smooth=$E::Multiply($E::Multiply($fraction,$fraction),$E::Subtract($E::Constant(3.0),$E::Multiply($E::Constant(2.0),$fraction)))
    $kernels.Tracks=New-CopyKernel ([Action[double[],double[][],double[][],int,double[]]]) @($a,$amplitudes,$offsets,$hop,$d) @(
        $i,$h,$frame,$next,$limit,$frameAmplitude,$nextAmplitude,$frameOffset,$nextOffset,$fraction,$blend,$amplitudeValue,$correction,$sum) @(
        (New-CopyLoop $i ($E::ArrayLength($d)) ($E::Block(
            $E::Assign($frame,$E::Divide($i,$hop)),
            $E::Assign($next,$E::Condition($E::LessThan($E::Add($frame,$one),$trackFrames),$E::Add($frame,$one),$frame)),
            $E::Assign($frameAmplitude,$E::ArrayIndex($amplitudes,$frame)),$E::Assign($nextAmplitude,$E::ArrayIndex($amplitudes,$next)),
            $E::Assign($frameOffset,$E::ArrayIndex($offsets,$frame)),$E::Assign($nextOffset,$E::ArrayIndex($offsets,$next)),
            $E::Assign($limit,$E::Condition($E::GreaterThan($E::ArrayLength($frameAmplitude),$E::ArrayLength($nextAmplitude)),
                $E::ArrayLength($frameAmplitude),$E::ArrayLength($nextAmplitude))),
            $E::Assign($fraction,$E::Divide($E::Convert($E::Modulo($i,$hop),[double]),$E::Convert($hop,[double]))),
            $E::Assign($blend,$smooth),$E::Assign($sum,$dz),
            (New-CopyLoop $h $limit ($E::Block(
                $E::Assign($amplitudeValue,$E::Add($E::Multiply($firstAmplitude,$E::Subtract($do,$fraction)),
                    $E::Multiply($secondAmplitude,$fraction))),
                $E::Assign($correction,$E::Add($E::Multiply($firstOffset,$E::Subtract($do,$blend)),
                    $E::Multiply($secondOffset,$blend))),
                $E::AddAssign($sum,$E::Multiply($amplitudeValue,(New-CopyMath Cos @(
                    $E::Add($E::Multiply($E::Convert($h,[double]),$ai),$correction))))))) -Start 1),
            $E::Assign($di,$sum)))))
    $kernels.Subtract=New-CopyKernel ([Action[double[],double[],double[]]]) @($a,$b,$c) @($i) @(
        (New-CopyLoop $i ($E::ArrayLength($a)) ($E::Assign($ci,$E::Subtract($ai,$bi)))))
    $kernels.Add=New-CopyKernel ([Action[double[],double[],double[]]]) @($a,$b,$c) @($i) @(
        (New-CopyLoop $i ($E::ArrayLength($a)) ($E::Assign($ci,$E::Add($ai,$bi)))))
    [pscustomobject]$kernels
}
Export-ModuleMember -Function Get-KokoroCopySynthesisKernels
