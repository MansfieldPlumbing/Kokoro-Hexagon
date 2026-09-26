#requires -Version 7.4
# Kokoro Generator's SineGen + SourceModuleHnNSF harmonic merge.
# kokoro/istftnet.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Optional supplied random draws make numerical gates reproducible. Without
# them, this bounded FP32 reference samples uniform phase and Gaussian noise.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $F0,
    [Parameter(Mandatory)][float[]] $MergeWeights,
    [Parameter(Mandatory)][float[]] $MergeBias,
    [ValidateRange(1, 1024)][int] $UpsampleScale = 300,
    [float[]] $InitialPhase,
    [float[]] $HarmonicGaussian,
    [float[]] $NoiseGaussian
)

$ErrorActionPreference = 'Stop'
$frames = $F0.Length
$samples = [long]$frames * $UpsampleScale
if ($frames -lt 2 -or $samples -gt 32768 -or
    $MergeWeights.Length -ne 9 -or $MergeBias.Length -ne 1 -or
    ($null -ne $InitialPhase -and $InitialPhase.Length -ne 9) -or
    ($null -ne $HarmonicGaussian -and $HarmonicGaussian.Length -ne $samples * 9) -or
    ($null -ne $NoiseGaussian -and $NoiseGaussian.Length -ne $samples)) {
    throw 'Sine source shape exceeds the bounded reference contract.'
}
foreach ($values in @($F0, $MergeWeights, $MergeBias, $InitialPhase,
        $HarmonicGaussian, $NoiseGaussian)) {
    if ($null -eq $values) { continue }
    foreach ($value in $values) {
        if (-not [float]::IsFinite($value)) { throw 'Sine source input is non-finite.' }
    }
}
$random = [Random]::new()
$normal = {
    $u1 = [Math]::Max([double]$random.NextDouble(), [double]::Epsilon)
    $u2 = [double]$random.NextDouble()
    return [Math]::Sqrt(-2.0 * [Math]::Log($u1)) * [Math]::Cos(2.0 * [Math]::PI * $u2)
}
$phaseOffset = [double[]]::new(9)
for ($harmonic = 1; $harmonic -lt 9; $harmonic++) {
    $phaseOffset[$harmonic] = if ($null -eq $InitialPhase) {
        [double]$random.NextDouble()
    } else {
        [double]$InitialPhase[$harmonic]
    }
    if ($phaseOffset[$harmonic] -lt 0 -or $phaseOffset[$harmonic] -ge 1) {
        throw 'Sine source initial phase is outside [0,1).'
    }
}
$phases = [double[]]::new($frames * 9)
$initialPhaseWeight = [Math]::Max(0.0, 1.0 - ($UpsampleScale - 1.0) / 2.0)
for ($harmonic = 0; $harmonic -lt 9; $harmonic++) {
    $cumulative = 0.0
    for ($frame = 0; $frame -lt $frames; $frame++) {
        $radians = [double]$F0[$frame] * ($harmonic + 1) / 24000.0
        $fraction = $radians - [Math]::Floor($radians)
        # The pinned source adds phase at full-rate sample zero, then linearly
        # downsamples. At scale 300, that sample is not selected by the first
        # half-pixel interpolation coordinate; the random phase vanishes.
        if ($frame -eq 0) { $fraction += $phaseOffset[$harmonic] * $initialPhaseWeight }
        $cumulative += $fraction
        $phases[$harmonic * $frames + $frame] = $cumulative *
            $UpsampleScale * 2.0 * [Math]::PI
    }
}
$harmonicSource = [float[]]::new([int]$samples)
$noiseSource = [float[]]::new([int]$samples)
$voiced = [float[]]::new([int]$samples)
for ($sample = 0; $sample -lt $samples; $sample++) {
    $frame = [int][Math]::Floor($sample / $UpsampleScale)
    $uv = if ($F0[$frame] -gt 10.0) { 1.0 } else { 0.0 }
    $voiced[$sample] = [float]$uv
    $coordinate = ($sample + 0.5) / $UpsampleScale - 0.5
    $left = [int][Math]::Floor($coordinate)
    $right = $left + 1
    $fraction = $coordinate - $left
    $left = [Math]::Clamp($left, 0, $frames - 1)
    $right = [Math]::Clamp($right, 0, $frames - 1)
    $merged = [double]$MergeBias[0]
    for ($harmonic = 0; $harmonic -lt 9; $harmonic++) {
        $base = $harmonic * $frames
        $phase = (1.0 - $fraction) * $phases[$base + $left] +
            $fraction * $phases[$base + $right]
        $draw = if ($null -eq $HarmonicGaussian) {
            & $normal
        } else {
            [double]$HarmonicGaussian[$sample * 9 + $harmonic]
        }
        $noiseAmplitude = if ($uv -eq 1.0) { 0.003 } else { 0.1 / 3.0 }
        $sine = $uv * (0.1 * [Math]::Sin($phase)) + $noiseAmplitude * $draw
        $merged += $sine * [double]$MergeWeights[$harmonic]
    }
    $value = [Math]::Tanh($merged)
    $noiseDraw = if ($null -eq $NoiseGaussian) { & $normal }
        else { [double]$NoiseGaussian[$sample] }
    $noiseValue = $noiseDraw * (0.1 / 3.0)
    if (-not [double]::IsFinite($value) -or -not [double]::IsFinite($noiseValue)) {
        throw 'Sine source output is non-finite.'
    }
    $harmonicSource[$sample] = [float]$value
    $noiseSource[$sample] = [float]$noiseValue
}
[pscustomobject]@{
    Harmonic = $harmonicSource
    Noise = $noiseSource
    Voiced = $voiced
    Samples = [int]$samples
}
