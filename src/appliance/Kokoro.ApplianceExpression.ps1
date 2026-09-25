# Lowered, side-effect-free startup dispatch check for the appliance host.
# The pinned Pwsh build's LambdaCompiler seam can emit this same tree into the
# generated managed entrypoint; Compile() is used here only as its host oracle.

$operations = [ordered]@{
    status = 1
}

$build = {
    $operation = [Linq.Expressions.Expression]::Parameter([string], 'operation')
    $ordinal = [Linq.Expressions.Expression]::Property($null, [StringComparer].GetProperty('Ordinal'))
    $equalsMethod = [StringComparer].GetMethod('Equals', [Type[]]@([string], [string]))
    [Linq.Expressions.Expression]$body = [Linq.Expressions.Expression]::Constant(0, [int])
    $pairs = @($operations.GetEnumerator())
    for ([int]$index = $pairs.Count - 1; $index -ge 0; $index--) {
        $pair = $pairs[$index]
        $test = [Linq.Expressions.Expression]::Call(
            $ordinal,
            $equalsMethod,
            [Linq.Expressions.Expression[]]@(
                $operation,
                [Linq.Expressions.Expression]::Constant([string]$pair.Key, [string])))
        $body = [Linq.Expressions.Expression]::Condition(
            $test,
            [Linq.Expressions.Expression]::Constant([int]$pair.Value, [int]),
            $body)
    }
    [Linq.Expressions.Expression]::Lambda[Func[string,int]]($body, [Linq.Expressions.ParameterExpression[]]@($operation))
}.GetNewClosure()

$verify = {
    $lambda = & $build
    $dispatch = $lambda.Compile()
    $cases = [Collections.Generic.List[object]]::new()
    foreach ($pair in $operations.GetEnumerator()) {
        [int]$actual = $dispatch.Invoke([string]$pair.Key)
        if ($actual -ne [int]$pair.Value) { throw "Operation '$($pair.Key)' dispatched to $actual." }
        $cases.Add([pscustomobject]@{ Operation=[string]$pair.Key; Code=[int]$actual })
    }
    foreach ($unsupported in @('ping', 'receipt', 'speak', 'benchmark', 'transcribe', 'SPEAK', 'eval', $null)) {
        if ($dispatch.Invoke($unsupported) -ne 0) {
            throw 'Unknown or unimplemented operations were admitted.'
        }
    }
    [pscustomobject]@{
        Schema = 1
        ExpressionNodeType = [string]$lambda.Body.NodeType
        Operations = [string[]]@($operations.Keys)
        Cases = $cases.ToArray()
        UnknownCode = 0
        Passed = $true
    }
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName = 'Kokoro.ApplianceExpression'
    Build = $build
    Verify = $verify
}
