#requires -Version 7.4
<#
.SYNOPSIS
Builds the integer parameters for the stock generator tail: leaky_relu(0.01), conv_post,
exp/sin and the 20-point iSTFT, fed by the generator 60x output tensor.

.DESCRIPTION
Stock source: hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec, istftnet.py
Generator.forward:309-314 and TorchSTFT.inverse. iSTFT semantics: PyTorch v2.14.0
(2b3ec34829036a65cd9d1398ea72a0167dc37470) aten/src/ATen/native/SpectralOps.cpp istft:
C2R inverse with 1/N, window, overlap-add at the hop, division by the overlap-added squared
window, n_fft/2 samples trimmed at each end. Window: periodic Hann, 20 points.

Integer contract (all DSP arithmetic; this script only derives constants and, for the
iSTFT stage, the exact integer result the DSP body must reproduce):
  leaky:     u8 zp 128 at the input scale; positive multiplier 1.0, negative 0.01 (Q16).
  conv_post: per-output-channel int8 weights, outputs padded 22 -> 128; run twice on HMX
             with two column tables per channel: coarse over the calibrated range, fine over
             the 5th-95th percentile band. A frame uses the fine code unless it is 0 or 255.
  tables:    per pass, E[k][q] = exp(z) Q16, C[k][q] = cos(sin(z)) Q15, S[k][q] = sin(sin(z)) Q15.
  frame:     Re = (E*C + 2^14) >> 15, Im = (E*S + 2^14) >> 15 (Q16);
             y[n] = (sum A[n][k]*Re_k + B[n][k]*Im_k + 2^21) >> 22 (Q24), A/B Q30 with the
             window, 1/20, the bin weight and 1/1.5 folded in.
  output:    acc[p] = sum of frame samples (Q24); samples whose envelope is not 1.5 are
             multiplied by G = 1.5/envelope (Q14, rounded); pcm = clamp((v + 256) >> 9).
#>
param(
    [Parameter(Mandatory)][string] $GeneratorFixture,
    [Parameter(Mandatory)][string] $CaptureDirectory,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [ValidateRange(4, 64)][double] $MagnitudeSpan = 16,
    [ValidateRange(0.0, 0.25)][double] $FineBand = 0.05
)
$ErrorActionPreference = 'Stop'
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)) { throw 'Use a new directory inside build/' }
$generator = [IO.Path]::GetFullPath($GeneratorFixture); $captureRoot = [IO.Path]::GetFullPath($CaptureDirectory)
$runner = Get-Content (Join-Path $generator 'runner-fixture.json') -Raw | ConvertFrom-Json
$inputScale = [double]$runner.OutputScale
$frameCount = [int]$runner.Frames; $tileCount = [int]$runner.Tiles
$inputPath = Join-Path $generator 'expected.bin'
if ((Get-FileHash $inputPath).Hash -ne '1D23542E5CA3FA6AD4A57EACF54D8547DDDF98D941A11FDC03F431CB8DB85A7E') { throw 'Generator 60x output contract mismatch' }
$capture = Get-Content (Join-Path $captureRoot 'capture.json') -Raw | ConvertFrom-Json -AsHashtable
$readTensor = { param([string]$Name)
    $entry = $capture.tensors[$Name]; $path = Join-Path $captureRoot $entry.file
    if ((Get-FileHash $path).Hash -ne $entry.sha256) { throw "Capture integrity: $Name" }
    $bytes = [IO.File]::ReadAllBytes($path); $values = [float[]]::new($bytes.Length / 4)
    [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length); , $values
}
$weight = & $readTensor 'generator.conv_post.weight'      # [22,128,7]
$bias = & $readTensor 'generator.conv_post.bias'           # [22]
$post = & $readTensor 'generator.conv_post.output'         # [1,22,frames]
$audio = & $readTensor 'output'                            # [1,1,samples]
if ($post.Length -ne 22 * $frameCount) { throw 'conv_post frame count differs from the generator fixture' }
$kernel = 7; $bins = 11; $nfft = 20; $hop = 5
$sampleCount = $hop * ($frameCount - 1)
if ($audio.Length -ne $sampleCount) { throw 'Stock audio length differs from hop*(frames-1)' }

# Parameter layout (bytes): leaky 0; column tables coarse 1024, fine 2048; per pass a block of
# E | C | S tables (3 x 11,264) at 4096 (coarse) and 37888 (fine); coefficients A 71680,
# B 72704; edge gains 73728.
$layout = [ordered]@{Leaky=0;ColumnCoarse=1024;ColumnFine=2048;PassCoarse=4096;PassFine=37888;CoefA=71680;CoefB=72704;EdgeGain=73728;Bytes=73856}
$parameters = [byte[]]::new($layout.Bytes)

# leaky_relu(0.01) at the input scale (Kokoro.LeakyReluInteger.ps1 contract).
$positive = 65536L; $negative = [long][math]::Round(0.01 * 65536, [MidpointRounding]::ToEven)
$leakyBias = 128L * 65536 - 128L * ($positive + $negative) + 32768
[BitConverter]::GetBytes([int]$positive).CopyTo($parameters, 0)
[BitConverter]::GetBytes([int]$negative).CopyTo($parameters, 4)
[BitConverter]::GetBytes([int]$leakyBias).CopyTo($parameters, 8)

# Output ranges per channel and pass. Magnitude logits below max - span contribute
# exp(-span) of the peak and are clipped.
$passes = @('Coarse', 'Fine')
$outScale = @{Coarse=[double[]]::new(22); Fine=[double[]]::new(22)}; $outZero = @{Coarse=[int[]]::new(22); Fine=[int[]]::new(22)}
$range = @{Coarse=[double[,]]::new(22, 2); Fine=[double[,]]::new(22, 2)}
for ($o = 0; $o -lt 22; $o++) {
    $values = [double[]]::new($frameCount); for ($f = 0; $f -lt $frameCount; $f++) { $values[$f] = $post[$o * $frameCount + $f] }
    $sorted = [double[]]$values.Clone(); [Array]::Sort($sorted)
    $bounds = @{
        Coarse = @($sorted[0], $sorted[$frameCount - 1])
        Fine = @($sorted[[int][math]::Floor($FineBand * ($frameCount - 1))], $sorted[[int][math]::Ceiling((1 - $FineBand) * ($frameCount - 1))])
    }
    foreach ($pass in $passes) {
        $lo = $bounds[$pass][0]; $hi = $bounds[$pass][1]
        if ($o -lt $bins) { $lo = [math]::Max($lo, $hi - $MagnitudeSpan) }
        $range[$pass][$o, 0] = $lo; $range[$pass][$o, 1] = $hi
        $outScale[$pass][$o] = ($hi - $lo) / 255
        $outZero[$pass][$o] = [int][math]::Round(-$lo / $outScale[$pass][$o], [MidpointRounding]::ToEven)
    }
}

# conv_post weights, per-output-channel symmetric int8, packed in HMX consumption order.
$weightScale = [double[]]::new(128); $sums = [long[]]::new(128); $quant = [sbyte[]]::new(128 * 128 * $kernel)
for ($o = 0; $o -lt 22; $o++) {
    $mx = 0.0; for ($i = 0; $i -lt 128 * $kernel; $i++) { $mx = [math]::Max($mx, [math]::Abs([double]$weight[$o * 128 * $kernel + $i])) }
    if ($mx -eq 0) { throw 'Zero conv_post weight channel' }
    $weightScale[$o] = $mx / 127
    for ($i = 0; $i -lt 128 * $kernel; $i++) {
        $q = [int][math]::Round($weight[$o * 128 * $kernel + $i] / $weightScale[$o], [MidpointRounding]::ToEven)
        $quant[$o * 128 * $kernel + $i] = [sbyte]$q; $sums[$o] += $q
    }
}
$packed = [byte[]]::new(2 * $kernel * 4 * 2048)
for ($g = 0; $g -lt 2; $g++) { for ($k = 0; $k -lt $kernel; $k++) { for ($block = 0; $block -lt 4; $block++) {
    $base = (($g * $kernel + $k) * 4 + $block) * 2048
    for ($h = 0; $h -lt 2; $h++) { for ($i = 0; $i -lt 32; $i++) { for ($c = 0; $c -lt 32; $c++) {
        $o = 64 * $g + 32 * $h + $c; $ic = 32 * $block + $i
        if ($o -lt 22) { $packed[$base + 1024 * $h + 128 * [math]::Floor($i / 4) + 4 * $c + $i % 4] = [byte]($quant[($o * 128 + $ic) * $kernel + $k] -band 255) }
    } } }
} } }
# Column tables (Kokoro.HmxConv.ps1; scale recipe of New-KokoroHmxCaptureFixture.ps1):
# fp16 scale with bit 22 (rounding), int32 bias carrying bias, input and output zero points.
$columnScale = @{}; $columnBias = @{}
foreach ($pass in $passes) {
    $columnScale[$pass] = [double[]]::new(22); $columnBias[$pass] = [long[]]::new(22)
    for ($o = 0; $o -lt 128; $o++) {
        if ($o -lt 22) { $m = $inputScale * $weightScale[$o] / $outScale[$pass][$o]; $zero = $outZero[$pass][$o]
            $biasQ = [math]::Round($bias[$o] / ($inputScale * $weightScale[$o]), [MidpointRounding]::ToEven) }
        else { $m = 1.0; $zero = 128; $biasQ = 0 }
        $half = [Half]::op_Explicit([float](512 * $m)); $bits = [BitConverter]::HalfToUInt16Bits($half)
        $scaleHalf = [double]$half / 512
        if ($scaleHalf -le 0 -or -not [double]::IsFinite($scaleHalf)) { throw 'Invalid HMX conversion scale' }
        $b = [long]$biasQ - 128L * $sums[$o] + [long][math]::Round($zero / $scaleHalf, [MidpointRounding]::ToEven)
        if ($b -lt [int]::MinValue -or $b -gt [int]::MaxValue) { throw 'Column-table bias overflow' }
        if ($o -lt 22) { $columnScale[$pass][$o] = $scaleHalf; $columnBias[$pass][$o] = $b }
        $at = $layout["Column$pass"] + [math]::Floor($o / 32) * 256; $col = $o % 32
        [BitConverter]::GetBytes([uint32]($bits -bor (1 -shl 22))).CopyTo($parameters, $at + 4 * $col)
        [BitConverter]::GetBytes([int]$b).CopyTo($parameters, $at + 128 + 4 * $col)
    }
}

# exp / cos(sin) / sin(sin) tables per pass, bin and code.
$tableE = @{}; $tableC = @{}; $tableS = @{}
foreach ($pass in $passes) {
    $tableE[$pass] = [long[,]]::new($bins, 256); $tableC[$pass] = [long[,]]::new($bins, 256); $tableS[$pass] = [long[,]]::new($bins, 256)
    $block = $layout["Pass$pass"]
    for ($k = 0; $k -lt $bins; $k++) { for ($q = 0; $q -lt 256; $q++) {
        $zm = $outScale[$pass][$k] * ($q - $outZero[$pass][$k]); $zp = $outScale[$pass][$bins + $k] * ($q - $outZero[$pass][$bins + $k])
        $e = [math]::Round([math]::Exp($zm) * 65536, [MidpointRounding]::ToEven); if ($e -gt [int]::MaxValue) { throw 'exp table overflow' }
        $tableE[$pass][$k, $q] = [long]$e
        $tableC[$pass][$k, $q] = [long][math]::Round([math]::Cos([math]::Sin($zp)) * 32768, [MidpointRounding]::ToEven)
        $tableS[$pass][$k, $q] = [long][math]::Round([math]::Sin([math]::Sin($zp)) * 32768, [MidpointRounding]::ToEven)
        [BitConverter]::GetBytes([int]$tableE[$pass][$k, $q]).CopyTo($parameters, $block + 4 * (256 * $k + $q))
        [BitConverter]::GetBytes([int]$tableC[$pass][$k, $q]).CopyTo($parameters, $block + 11264 + 4 * (256 * $k + $q))
        [BitConverter]::GetBytes([int]$tableS[$pass][$k, $q]).CopyTo($parameters, $block + 22528 + 4 * (256 * $k + $q))
    } }
}
# Inverse DFT coefficients with the window, 1/N, bin weight and 1/1.5 folded in (Q30).
$window = [double[]]::new($nfft); for ($n = 0; $n -lt $nfft; $n++) { $window[$n] = 0.5 - 0.5 * [math]::Cos(2 * [math]::PI * $n / $nfft) }
$coefA = [long[,]]::new($nfft, $bins); $coefB = [long[,]]::new($nfft, $bins)
for ($n = 0; $n -lt $nfft; $n++) { for ($k = 0; $k -lt $bins; $k++) {
    $weightK = if ($k -eq 0 -or $k -eq $bins - 1) { 1.0 } else { 2.0 }
    $theta = 2 * [math]::PI * $k * $n / $nfft; $common = $window[$n] * $weightK / $nfft / 1.5 * 1073741824
    $coefA[$n, $k] = [long][math]::Round($common * [math]::Cos($theta), [MidpointRounding]::ToEven)
    $coefB[$n, $k] = if ($k -eq 0 -or $k -eq $bins - 1) { 0L } else { [long][math]::Round(-$common * [math]::Sin($theta), [MidpointRounding]::ToEven) }
    [BitConverter]::GetBytes([int]$coefA[$n, $k]).CopyTo($parameters, $layout.CoefA + 4 * ($bins * $n + $k))
    [BitConverter]::GetBytes([int]$coefB[$n, $k]).CopyTo($parameters, $layout.CoefB + 4 * ($bins * $n + $k))
} }
# Envelope gains for the first and last five trimmed samples (16384 = 1.0); every other
# sample has an overlap-added squared window of exactly 1.5, checked next to both edges.
$paddedLength = $nfft + $hop * ($frameCount - 1)
$envelope = { param([int]$j) $p = $j + $nfft / 2; $env = 0.0
    for ($n = $p % $hop; $n -lt $nfft; $n += $hop) { $f = ($p - $n) / $hop; if ($f -ge 0 -and $f -lt $frameCount) { $env += $window[$n] * $window[$n] } }
    $env }
$edgeGain = [Collections.Generic.List[object]]::new()
foreach ($j in @(0..4) + @(($sampleCount - 5)..($sampleCount - 1))) {
    $edgeGain.Add([pscustomobject]@{Sample=$j;Gain=[long][math]::Round(1.5 / (& $envelope $j) * 16384, [MidpointRounding]::ToEven)})
}
foreach ($j in @(5..40) + @(($sampleCount - 40)..($sampleCount - 6))) { if ([math]::Abs((& $envelope $j) - 1.5) -gt 1e-9) { throw "Envelope is not 1.5 at sample $j" } }
for ($i = 0; $i -lt 10; $i++) { [BitConverter]::GetBytes([int]$edgeGain[$i].Gain).CopyTo($parameters, $layout.EdgeGain + 4 * $i) }

# Integer iSTFT from conv_post u8 codes of both passes (frame-major [frames][22]); the fine
# code is used unless it saturated. This is the exact result the DSP body must reproduce.
function Invoke-TailIstftInteger([byte[]]$Coarse, [byte[]]$Fine) {
    $acc = [int[]]::new($paddedLength); $re = [long[]]::new($bins); $im = [long[]]::new($bins)
    for ($f = 0; $f -lt $frameCount; $f++) {
        for ($k = 0; $k -lt $bins; $k++) {
            $qm = $Fine[22 * $f + $k]; $pm = 'Fine'; if ($qm -eq 0 -or $qm -eq 255) { $qm = $Coarse[22 * $f + $k]; $pm = 'Coarse' }
            $qp = $Fine[22 * $f + $bins + $k]; $pp = 'Fine'; if ($qp -eq 0 -or $qp -eq 255) { $qp = $Coarse[22 * $f + $bins + $k]; $pp = 'Coarse' }
            $e = $tableE[$pm][$k, $qm]
            $re[$k] = ($e * $tableC[$pp][$k, $qp] + 16384) -shr 15; $im[$k] = ($e * $tableS[$pp][$k, $qp] + 16384) -shr 15
        }
        for ($n = 0; $n -lt $nfft; $n++) {
            $sum = 2097152L; for ($k = 0; $k -lt $bins; $k++) { $sum += $coefA[$n, $k] * $re[$k] + $coefB[$n, $k] * $im[$k] }
            $acc[$hop * $f + $n] += [int]($sum -shr 22)
        }
    }
    $pcm = [int16[]]::new($sampleCount); $gain = @{}; foreach ($e in $edgeGain) { $gain[$e.Sample] = $e.Gain }
    for ($j = 0; $j -lt $sampleCount; $j++) {
        $v = [long]$acc[$j + $nfft / 2]
        if ($gain.ContainsKey($j)) { $v = ($v * $gain[$j] + 8192) -shr 14 }
        $pcm[$j] = [int16][math]::Clamp(($v + 256) -shr 9, -32768L, 32767L)
    }
    , $pcm
}
function Get-SnrDb([int16[]]$Pcm) {
    $signal = 0.0; $noise = 0.0
    for ($j = 0; $j -lt $sampleCount; $j++) { $ref = [double]$audio[$j] * 32768; $d = $Pcm[$j] - $ref; $signal += $ref * $ref; $noise += $d * $d }
    10 * [math]::Log10($signal / [math]::Max($noise, 1e-30))
}
# Calibration diagnostic: stock conv_post output quantized with these scales, then this
# iSTFT arithmetic. Isolates the tail's own quantization; it is not a correctness reference.
$codes = @{}
foreach ($pass in $passes) {
    $codes[$pass] = [byte[]]::new(22 * $frameCount)
    for ($f = 0; $f -lt $frameCount; $f++) { for ($o = 0; $o -lt 22; $o++) {
        $codes[$pass][22 * $f + $o] = [byte][math]::Clamp([math]::Round($post[$o * $frameCount + $f] / $outScale[$pass][$o] + $outZero[$pass][$o], [MidpointRounding]::ToEven), 0, 255)
    } }
}
$diagnostic = Invoke-TailIstftInteger $codes.Coarse $codes.Fine
$tailSnr = Get-SnrDb $diagnostic

[void][IO.Directory]::CreateDirectory($out)
Copy-Item $inputPath (Join-Path $out 'activations.bin')
[IO.File]::WriteAllBytes((Join-Path $out 'weights.bin'), $packed)
[IO.File]::WriteAllBytes((Join-Path $out 'tables.bin'), $parameters)
$pcmBytes = [byte[]]::new(2 * $sampleCount); [Buffer]::BlockCopy($diagnostic, 0, $pcmBytes, 0, $pcmBytes.Length)
[IO.File]::WriteAllBytes((Join-Path $out 'calibration-diagnostic-pcm.s16'), $pcmBytes)
$files = @(Get-ChildItem $out -File | ForEach-Object { [ordered]@{Name=$_.Name;Bytes=$_.Length;SHA256=(Get-FileHash $_.FullName).Hash} })
$rangeOut = [ordered]@{}; foreach ($pass in $passes) { $rangeOut[$pass] = @(0..21 | ForEach-Object { ,@($range[$pass][$_, 0], $range[$pass][$_, 1]) }) }
[ordered]@{
    Graph='GeneratorTail'; Frames=$frameCount; Tiles=$tileCount; Samples=$sampleCount; SampleRate=24000
    InputScale=$inputScale; LeakyPositive=$positive; LeakyNegative=$negative; LeakyBias=$leakyBias
    MagnitudeSpan=$MagnitudeSpan; FineBand=$FineBand; OutputScale=$outScale; OutputZero=$outZero; CalibratedRange=$rangeOut
    WeightScale=@($weightScale[0..21]); ColumnScale=$columnScale; ColumnBias=$columnBias
    EdgeGain=$edgeGain; ParameterLayout=$layout
    CalibrationDiagnosticSnrDb=$tailSnr; StockAudio=[ordered]@{File=(Join-Path $captureRoot 'output.f32');SHA256=$capture.tensors['output'].sha256}
    CaptureManifestSHA256=(Get-FileHash (Join-Path $captureRoot 'capture.json')).Hash; Files=$files
} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{Directory=$out;Samples=$sampleCount;CalibrationDiagnosticSnrDb=[math]::Round($tailSnr,2)}
