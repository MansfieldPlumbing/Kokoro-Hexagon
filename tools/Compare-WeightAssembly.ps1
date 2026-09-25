#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Fp32AssemblyPath,
    [Parameter(Mandatory)][string]$Fp16AssemblyPath,
    [ValidateRange(1, 1000000)][int]$SampleStride = 1024
)
$ErrorActionPreference = 'Stop'
function Read-Index([Reflection.Assembly]$Assembly) {
    $stream = $Assembly.GetManifestResourceStream('Kokoro.WeightIndex.json')
    if ($null -eq $stream) { throw 'The weight index is missing.' }
    try {
        [byte[]]$bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes, 0, $bytes.Length)
        return [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable
    }
    finally { $stream.Dispose() }
}
function Read-Resource([Reflection.Assembly]$Assembly, [string]$Name, [int]$Length) {
    $stream = $Assembly.GetManifestResourceStream($Name)
    if ($null -eq $stream -or $stream.Length -ne $Length) { throw "Invalid resource: $Name" }
    try {
        [byte[]]$bytes = [byte[]]::new($Length)
        $stream.ReadExactly($bytes, 0, $Length)
        return ,$bytes
    }
    finally { $stream.Dispose() }
}
$fp32 = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $Fp32AssemblyPath).Path)
$fp16 = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $Fp16AssemblyPath).Path)
$aIndex = Read-Index $fp32
$bIndex = Read-Index $fp16
if (-not $aIndex.complete -or -not $bIndex.complete -or
    $aIndex.precision -cne 'FP32' -or $bIndex.precision -cne 'FP16' -or
    $aIndex.tensor_count -ne 548 -or $bIndex.tensor_count -ne 548 -or
    $aIndex.source_sha256 -cne $bIndex.source_sha256) {
    throw 'The assemblies do not describe one complete pinned model at two precisions.'
}
$fp16ByName = @{}
foreach ($tensor in $bIndex.tensors) {
    if ($fp16ByName.ContainsKey($tensor.name)) { throw 'Duplicate FP16 tensor.' }
    $fp16ByName[$tensor.name] = $tensor
}
[long]$sampleCount = 0
[double]$sumAbs = 0
[double]$sumSquare = 0
[double]$maxAbs = 0
[double]$maxRelativeAbove1e3 = 0
[long]$changedToZero = 0
[string]$worstTensor = ''
foreach ($a in $aIndex.tensors) {
    $b = $fp16ByName[$a.name]
    if ($null -eq $b -or $a.source_sha256 -cne $b.source_sha256 -or
        ($a.shape -join ',') -cne ($b.shape -join ',') -or
        [long]$a.bytes -ne 2 * [long]$b.bytes) {
        throw "The tensor pair is not equivalent: $($a.name)"
    }
    [byte[]]$source = Read-Resource $fp32 $a.resource ([int]$a.bytes)
    [byte[]]$encoded = Read-Resource $fp16 $b.resource ([int]$b.bytes)
    [int]$elements = [int]($source.Length / 4)
    for ([int]$i = 0; $i -lt $elements; $i += $SampleStride) {
        [float]$original = [BitConverter]::ToSingle($source, $i * 4)
        [float]$restored = [BitConverter]::UInt16BitsToHalf([BitConverter]::ToUInt16($encoded, $i * 2))
        if (-not [float]::IsFinite($original) -or -not [float]::IsFinite($restored)) {
            throw "A sampled tensor value is not finite: $($a.name)"
        }
        [double]$absError = [Math]::Abs([double]$original - [double]$restored)
        $sumAbs += $absError
        $sumSquare += $absError * $absError
        if ($absError -gt $maxAbs) { $maxAbs = $absError; $worstTensor = $a.name }
        if ([Math]::Abs([double]$original) -ge 0.001) {
            $maxRelativeAbove1e3 = [Math]::Max($maxRelativeAbove1e3,
                $absError / [Math]::Abs([double]$original))
        }
        if ($original -ne 0 -and $restored -eq 0) { $changedToZero++ }
        $sampleCount++
    }
}
[pscustomobject]@{
    TensorPairs = $aIndex.tensor_count
    SampleStride = $SampleStride
    SampleCount = $sampleCount
    MeanAbsoluteError = $sumAbs / $sampleCount
    RootMeanSquareError = [Math]::Sqrt($sumSquare / $sampleCount)
    MaxAbsoluteError = $maxAbs
    MaxRelativeErrorAbove1e3 = $maxRelativeAbove1e3
    ChangedToZero = $changedToZero
    MaxErrorTensor = $worstTensor
    AcousticParity = 'Not tested'
}
