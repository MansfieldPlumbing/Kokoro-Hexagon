#requires -Version 7.4
# Host-side FP32 -> IEEE binary16 conversion. The loop is emitted by the
# framework expression compiler; PowerShell does not dispatch per element.
if (-not [BitConverter]::IsLittleEndian) { throw 'The FP16 emitter requires a little-endian host.' }
$inputBytes = [Linq.Expressions.Expression]::Parameter([byte[]], 'source')
$outputBytes = [Linq.Expressions.Expression]::Parameter([byte[]], 'destination')
$index = [Linq.Expressions.Expression]::Variable([int], 'index')
$bits = [Linq.Expressions.Expression]::Variable([uint16], 'bits')
$value = [Linq.Expressions.Expression]::Variable([float], 'value')
$end = [Linq.Expressions.Expression]::Label()
$toSingle = [BitConverter].GetMethod('ToSingle', [type[]]@([byte[]], [int]))
$toBits = [BitConverter].GetMethod('HalfToUInt16Bits', [type[]]@([Half]))
$isFinite = [float].GetMethod('IsFinite', [type[]]@([float]))
$abs = [MathF].GetMethod('Abs', [type[]]@([float]))
$byteOffset = [Linq.Expressions.Expression]::Multiply($index, [Linq.Expressions.Expression]::Constant(4))
$halfOffset = [Linq.Expressions.Expression]::Multiply($index, [Linq.Expressions.Expression]::Constant(2))
$halfValue = [Linq.Expressions.Expression]::Convert($value, [Half])
$lowByte = [Linq.Expressions.Expression]::Convert(
    [Linq.Expressions.Expression]::And($bits, [Linq.Expressions.Expression]::Constant([uint16]255)), [byte])
$highByte = [Linq.Expressions.Expression]::Convert(
    [Linq.Expressions.Expression]::RightShift($bits, [Linq.Expressions.Expression]::Constant(8)), [byte])
$body = [Linq.Expressions.Expression]::Block(
    [Linq.Expressions.Expression]::Assign($value, [Linq.Expressions.Expression]::Call($toSingle, $inputBytes, $byteOffset)),
    [Linq.Expressions.Expression]::IfThen(
        [Linq.Expressions.Expression]::OrElse(
            [Linq.Expressions.Expression]::Not([Linq.Expressions.Expression]::Call($isFinite, $value)),
        [Linq.Expressions.Expression]::GreaterThan(
                [Linq.Expressions.Expression]::Call($abs, $value),
                [Linq.Expressions.Expression]::Constant([float]65504))),
        [Linq.Expressions.Expression]::Throw(
            [Linq.Expressions.Expression]::Constant([OverflowException]::new('FP32 weight is outside finite FP16 range.')))),
    [Linq.Expressions.Expression]::Assign($bits, [Linq.Expressions.Expression]::Call($toBits, $halfValue)),
    [Linq.Expressions.Expression]::Assign([Linq.Expressions.Expression]::ArrayAccess($outputBytes, $halfOffset), $lowByte),
    [Linq.Expressions.Expression]::Assign([Linq.Expressions.Expression]::ArrayAccess(
        $outputBytes, [Linq.Expressions.Expression]::Add($halfOffset, [Linq.Expressions.Expression]::Constant(1))), $highByte),
    [Linq.Expressions.Expression]::PostIncrementAssign($index))
$loop = [Linq.Expressions.Expression]::Loop(
    [Linq.Expressions.Expression]::IfThenElse(
        [Linq.Expressions.Expression]::LessThan($index,
            [Linq.Expressions.Expression]::Divide([Linq.Expressions.Expression]::ArrayLength($inputBytes),
                [Linq.Expressions.Expression]::Constant(4))),
        $body,
        [Linq.Expressions.Expression]::Break($end)), $end)
$lambda = [Linq.Expressions.Expression]::Lambda[Action[byte[],byte[]]](
    [Linq.Expressions.Expression]::Block(
        [Linq.Expressions.ParameterExpression[]]@($index, $bits, $value),
        [Linq.Expressions.Expression]::Assign($index, [Linq.Expressions.Expression]::Constant(0)),
        $loop),
    [Linq.Expressions.ParameterExpression[]]@($inputBytes, $outputBytes))
$compiled = $lambda.Compile()
$convert = {
    param([byte[]]$Source)
    if ($null -eq $Source -or ($Source.Length % 4) -ne 0) {
        throw 'An FP32 byte array with a whole number of elements is required.'
    }
    [byte[]]$destination = [byte[]]::new([int]($Source.Length / 2))
    $compiled.Invoke($Source, $destination)
    return ,$destination
}.GetNewClosure()
[pscustomobject]@{ Convert = $convert; Lambda = $lambda }
