#requires -Version 7.4
# Pinned Kokoro v1.0 phoneme admission. This script builds expression trees;
# the same trees are compiled for host tests and persisted into the model DLL.
# No input text is evaluated as PowerShell.

param([Parameter(Mandatory)][string]$RepositoryRoot)
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$manifest = [IO.File]::ReadAllText([IO.Path]::Combine($repositoryRoot, 'lib', 'manifest.json')) |
    ConvertFrom-Json -AsHashtable
$pin = @($manifest.model.files | Where-Object { $_.path -ceq 'config.json' })
if ($pin.Count -ne 1) { throw 'The pinned Kokoro config must have exactly one manifest entry.' }
$configPath = [IO.Path]::Combine($repositoryRoot, 'lib', 'kokoro-v1_0.config.json')
$raw = [IO.File]::ReadAllText($configPath, [Text.UTF8Encoding]::new($false, $true))
# The checked-in text has one conventional final LF; upstream's pinned bytes do not.
if (-not $raw.EndsWith("`n", [StringComparison]::Ordinal) -or $raw.EndsWith("`n`n", [StringComparison]::Ordinal)) {
    throw 'The checked-in Kokoro config has an unexpected newline convention.'
}
$sourceText = $raw.Substring(0, $raw.Length - 1)
$sourceBytes = [Text.Encoding]::UTF8.GetBytes($sourceText)
$sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceBytes))
if ($sourceBytes.Length -ne [int]$pin[0].bytes -or $sourceHash -cne [string]$pin[0].sha256) {
    throw 'The Kokoro vocabulary differs from the pinned model config.'
}
$config = $sourceText | ConvertFrom-Json -AsHashtable
if ($config.vocab.Count -ne 114 -or [int]$config.n_token -ne 178) {
    throw 'The Kokoro vocabulary shape differs from the pinned model.'
}
$idsSeen = [Collections.Generic.HashSet[int]]::new()
$slots = [char[]]::new([int]$config.n_token)
foreach ($entry in $config.vocab.GetEnumerator()) {
    $phoneme = [string]$entry.Key
    $id = [int]$entry.Value
    if ($phoneme.Length -ne 1 -or [char]::IsSurrogate($phoneme, 0) -or
        $id -le 0 -or $id -ge $slots.Length -or -not $idsSeen.Add($id)) {
        throw 'The pinned vocabulary contains an invalid phoneme or ID.'
    }
    $slots[$id] = $phoneme[0]
}
$lookup = [string]::new($slots)
$newFactory = [Linq.Expressions.Expression].GetMethod('New', [type[]]@(
    [Reflection.ConstructorInfo], [Linq.Expressions.Expression[]]))
$newException = {
    param([type]$ExceptionType, [string]$Message)
    $constructor = $ExceptionType.GetConstructor([type[]]@([string]))
    $argument = [Linq.Expressions.Expression]::Constant($Message, [string])
    $newFactory.Invoke($null, [object[]]@($constructor, [Linq.Expressions.Expression[]]@($argument)))
}.GetNewClosure()

$buildIds = {
    $phonemes = [Linq.Expressions.Expression]::Parameter([string], 'phonemes')
    $length = [Linq.Expressions.Expression]::Variable([int], 'length')
    $result = [Linq.Expressions.Expression]::Variable([int[]], 'result')
    $index = [Linq.Expressions.Expression]::Variable([int], 'index')
    $id = [Linq.Expressions.Expression]::Variable([int], 'id')
    $done = [Linq.Expressions.Expression]::Label('done')
    $zero = [Linq.Expressions.Expression]::Constant(0, [int])
    $one = [Linq.Expressions.Expression]::Constant(1, [int])
    $throwNull = [Linq.Expressions.Expression]::Throw((& $newException ([ArgumentNullException]) 'phonemes'))
    $throwEmpty = [Linq.Expressions.Expression]::Throw((& $newException ([ArgumentException]) 'A phoneme string is required.'))
    $throwLong = [Linq.Expressions.Expression]::Throw((& $newException ([ArgumentOutOfRangeException]) 'phonemes'))
    $throwUnknown = [Linq.Expressions.Expression]::Throw((& $newException ([ArgumentException]) 'Unknown Kokoro phoneme.'))
    $indexOf = [string].GetMethod('IndexOf', [type[]]@([char]))
    $getChar = [string].GetMethod('get_Chars', [type[]]@([int]))
    $loopBody = [Linq.Expressions.Expression]::IfThenElse(
        [Linq.Expressions.Expression]::LessThan($index, $length),
        [Linq.Expressions.Expression]::Block([Linq.Expressions.Expression[]]@(
            [Linq.Expressions.Expression]::Assign($id, [Linq.Expressions.Expression]::Call(
                [Linq.Expressions.Expression]::Constant($lookup, [string]), $indexOf,
                [Linq.Expressions.Expression[]]@([Linq.Expressions.Expression]::Call($phonemes, $getChar, [Linq.Expressions.Expression[]]@($index))))),
            [Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::LessThanOrEqual($id, $zero), $throwUnknown),
            [Linq.Expressions.Expression]::Assign(
                [Linq.Expressions.Expression]::ArrayAccess($result, [Linq.Expressions.Expression]::Add($index, $one)), $id),
            [Linq.Expressions.Expression]::PostIncrementAssign($index))),
        [Linq.Expressions.Expression]::Break($done))
    $body = [Linq.Expressions.Expression]::Block(
        [Linq.Expressions.ParameterExpression[]]@($length, $result, $index, $id),
        [Linq.Expressions.Expression[]]@(
            [Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::Equal(
                $phonemes, [Linq.Expressions.Expression]::Constant($null, [string])), $throwNull),
            [Linq.Expressions.Expression]::Assign($length, [Linq.Expressions.Expression]::Property($phonemes, 'Length')),
            [Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::Equal($length, $zero), $throwEmpty),
            [Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::GreaterThan(
                $length, [Linq.Expressions.Expression]::Constant(510, [int])), $throwLong),
            [Linq.Expressions.Expression]::Assign($result, [Linq.Expressions.Expression]::NewArrayBounds(
                [int], [Linq.Expressions.Expression[]]@([Linq.Expressions.Expression]::Add(
                    $length, [Linq.Expressions.Expression]::Constant(2, [int]))))),
            [Linq.Expressions.Expression]::Assign($index, $zero),
            [Linq.Expressions.Expression]::Loop($loopBody, $done),
            $result))
    [Linq.Expressions.Expression]::Lambda[Func[string,int[]]](
        $body, [Linq.Expressions.ParameterExpression[]]@($phonemes))
}.GetNewClosure()

$buildVoiceRow = {
    $count = [Linq.Expressions.Expression]::Parameter([int], 'phonemeCount')
    $bad = [Linq.Expressions.Expression]::OrElse(
        [Linq.Expressions.Expression]::LessThanOrEqual($count, [Linq.Expressions.Expression]::Constant(0, [int])),
        [Linq.Expressions.Expression]::GreaterThan($count, [Linq.Expressions.Expression]::Constant(510, [int])))
    $throwBad = [Linq.Expressions.Expression]::Throw(
        (& $newException ([ArgumentOutOfRangeException]) 'phonemeCount'), [int])
    $body = [Linq.Expressions.Expression]::Condition(
        $bad, $throwBad,
        [Linq.Expressions.Expression]::Subtract($count, [Linq.Expressions.Expression]::Constant(1, [int])))
    [Linq.Expressions.Expression]::Lambda[Func[int,int]](
        $body, [Linq.Expressions.ParameterExpression[]]@($count))
}.GetNewClosure()

$verify = {
    $admit = (& $buildIds).Compile()
    $voiceRow = (& $buildVoiceRow).Compile()
    foreach ($entry in $config.vocab.GetEnumerator()) {
        $actual = $admit.Invoke([string]$entry.Key)
        if ($actual.Length -ne 3 -or $actual[0] -ne 0 -or $actual[1] -ne [int]$entry.Value -or $actual[2] -ne 0) {
            throw 'A pinned phoneme did not map to its exact model ID.'
        }
    }
    $limit = $admit.Invoke(('a' * 510))
    if ($limit.Length -ne 512 -or $voiceRow.Invoke(510) -ne 509 -or $voiceRow.Invoke(1) -ne 0) {
        throw 'Boundary length or voice-row selection is incorrect.'
    }
    foreach ($bad in @($null, '', '🙂', ('a' * 511))) {
        try { $null = $admit.Invoke($bad); throw 'Invalid phonemes were admitted.' }
        catch [ArgumentException] { }
    }
    foreach ($badCount in @(0, 511)) {
        try { $null = $voiceRow.Invoke($badCount); throw 'Invalid voice-row count was admitted.' }
        catch [ArgumentOutOfRangeException] { }
    }
    [pscustomobject]@{ Passed = $true; VocabularyCount = $config.vocab.Count; SourceSHA256 = $sourceHash; Limit = 510 }
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName = 'Kokoro.PhonemeExpression'
    BuildIds = $buildIds
    BuildVoiceRow = $buildVoiceRow
    Verify = $verify
    SourceSHA256 = $sourceHash
}
