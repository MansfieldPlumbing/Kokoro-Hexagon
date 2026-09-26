#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroSineSource.ps1'
$weights = [float[]]::new(9)
$weights[0] = 1
$zeros = [float[]]::new(4 * 9)
$actual = & $stage -F0 ([float[]]@(120, 120)) -MergeWeights $weights `
    -MergeBias ([float[]]@(0)) -UpsampleScale 2 `
    -InitialPhase ([float[]]::new(9)) `
    -HarmonicGaussian $zeros -NoiseGaussian ([float[]]::new(4))
$expectedPhases = @(0.06283185307179587, 0.07853981633974483,
    0.10995574287564276, 0.12566370614359174)
if ($actual.Samples -ne 4 -or $actual.Harmonic.Length -ne 4 -or
    ($actual.Voiced -join ',') -cne '1,1,1,1') {
    throw 'Analytic sine source output shape or voicing differs.'
}
for ($i = 0; $i -lt 4; $i++) {
    $expected = [Math]::Tanh(0.1 * [Math]::Sin($expectedPhases[$i]))
    if ([Math]::Abs([double]$actual.Harmonic[$i] - $expected) -gt 1e-6 -or
        $actual.Noise[$i] -ne 0) {
        throw 'Analytic sine source phase or harmonic merge differs.'
    }
}
$silent = & $stage -F0 ([float[]]@(0, 0)) -MergeWeights $weights `
    -MergeBias ([float[]]@(0)) -UpsampleScale 2 `
    -InitialPhase ([float[]]::new(9)) `
    -HarmonicGaussian $zeros -NoiseGaussian ([float[]]::new(4))
if (($silent.Harmonic -join ',') -cne '0,0,0,0' -or
    ($silent.Voiced -join ',') -cne '0,0,0,0') {
    throw 'Analytic unvoiced source differs.'
}
if ($CheckpointPath) {
    $pin = @(([IO.File]::ReadAllText((Join-Path $root 'lib/manifest.json')) |
        ConvertFrom-Json -AsHashtable).model.files | Where-Object { $_.path -ceq 'kokoro-v1_0.pth' })
    $path = (Resolve-Path -LiteralPath $CheckpointPath).Path
    if ($pin.Count -ne 1 -or (Get-Item -LiteralPath $path).Length -ne [long]$pin[0].bytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $pin[0].sha256) {
        throw 'Stock checkpoint does not match the pinned digest.'
    }
    $reader = [scriptblock]::Create([IO.File]::ReadAllText(
        (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
    $checkpoint = & $reader.Read $path
    $read = {
        param([string] $Name, [string] $Shape)
        $descriptor = $checkpoint.Tensors[$Name]
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $Shape) {
            throw "Stock source tensor shape differs: $Name"
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    $stockWeights = & $read 'decoder.module.generator.m_source.l_linear.weight' '1,9'
    $stockBias = & $read 'decoder.module.generator.m_source.l_linear.bias' '1'
    $draws = [float[]]::new(600 * 9)
    $phaseA = [float[]]::new(9)
    $phaseB = [float[]]::new(9)
    $phaseB[1] = [float]0.75
    $args = @{
        F0 = [float[]]@(120, 120)
        MergeWeights = $stockWeights
        MergeBias = $stockBias
        UpsampleScale = 300
        HarmonicGaussian = $draws
        NoiseGaussian = [float[]]::new(600)
    }
    $first = & $stage @args -InitialPhase $phaseA
    $second = & $stage @args -InitialPhase $phaseB
    if ($first.Samples -ne 600 -or $second.Samples -ne 600) {
        throw 'Stock source sample count differs.'
    }
    for ($i = 0; $i -lt 600; $i++) {
        if (-not [float]::IsFinite($first.Harmonic[$i]) -or
            $first.Harmonic[$i] -ne $second.Harmonic[$i]) {
            throw 'Stock source phase downsampling or output differs.'
        }
    }
    $spectrum = & (Join-Path $root 'src/models/ConvertTo-KokoroStft.ps1') `
        -Samples $first.Harmonic
    if ($spectrum.Frames -ne 121 -or $spectrum.Magnitude.Length -ne 11 * 121 -or
        $spectrum.Phase.Length -ne 11 * 121) {
        throw 'Stock source STFT layout differs.'
    }
    $recovered = & (Join-Path $root 'src/models/ConvertFrom-KokoroStft.ps1') `
        -Magnitude $spectrum.Magnitude -Phase $spectrum.Phase `
        -Frames $spectrum.Frames
    $signalEnergy = 0.0
    $errorEnergy = 0.0
    for ($i = 0; $i -lt 600; $i++) {
        $signalEnergy += [double]$first.Harmonic[$i] * $first.Harmonic[$i]
        $difference = [double]$first.Harmonic[$i] - $recovered[$i]
        $errorEnergy += $difference * $difference
    }
    $snr = 10 * [Math]::Log10($signalEnergy / [Math]::Max($errorEnergy, 1e-30))
    if ($snr -lt 90) { throw 'Stock source STFT round-trip SNR is below 90 dB.' }
}
Write-Output 'PASS: sine source analytic phase/voicing and optional stock-weight gate'
