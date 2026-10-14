#requires -Version 7.7
using namespace System.Runtime.Intrinsics
using namespace System.Runtime.Intrinsics.X86
<#
.SYNOPSIS
Offline float32 decoder/generator admission and precomputed-unit join experiment.
.DESCRIPTION
Numeric kernels are lowered through the unchanged frontend PSLowering pin.
No phone access. -h prints help. Admission precedes the render gates.
.PARAMETER Mode
Admit checks compiled SIMD workers; Nodes compares 25 dog intermediates;
Levels checks exact normalization replay; Gate measures ten Supplied renders;
Seeded renders the capture inputs with deterministic noise; Join runs the bank experiment.
.PARAMETER Seed
Seeded and Join reset this seed for each render, using uniform phase and Gaussian noise.
#>
[CmdletBinding()]
param(
    [ValidateSet('Admit','Nodes','Levels','Gate','Seeded','Join')][string] $Mode = 'Gate',
    [ValidateRange(2,64)][int] $Threads = 4,
    [ValidateRange(1,10)][int] $Runs = 10,
    [string] $CaseName = '',
    [string] $InputRepository = 'C:\Dev\Kokoro-Hexagon',
    [string] $OutputDirectory = '',
    [int] $Seed = 17,
    [switch] $h
)

class OfflineLevelRecord {
    [string] $Name
    [int] $Channels
    [int] $Frames
    [int[]] $TokenFrames
    # Means, variances, token-major sums, token-major squared sums.
    [double[]] $Statistics
}
class OfflineDecoderResult {
    [float[]] $Features
    [OfflineLevelRecord[]] $Levels
}

class OfflineConvolutionWorker {
    [float[]] $Input
    [float[]] $Weights
    [float[]] $Bias
    [float[]] $Output
    [int[]] $Indices
    [System.Runtime.Intrinsics.Vector128[float][]] $VectorInput
    [bool[]] $ActiveTaps
    [int] $InputChannels
    [int] $OutputChannels
    [int] $InputFrames
    [int] $OutputFrames
    [int] $Kernel
    [int] $Stride
    [int] $Dilation
    [int] $Padding
    [int] $Groups
    [bool] $Transpose
    [int] $FirstChannel
    [int] $LastChannel

    [float] ReadInput([int] $channel, [int] $frame, [int] $tap) {
        $at = $frame * $this.Stride + $tap * $this.Dilation - $this.Padding
        if ($this.Transpose) {
            $at = $frame + $this.Padding - $tap * $this.Dilation
            if ($at -lt 0 -or $at % $this.Stride -ne 0) { return [float]0 }
            $at = [int]($at / $this.Stride)
        }
        if ($at -lt 0 -or $at -ge $this.InputFrames) { return [float]0 }
        return $this.Input[$channel * $this.InputFrames + $at]
    }

    [void] Run() {
        $inputsPerGroup = [int]($this.InputChannels / $this.Groups)
        $outputsPerGroup = [int]($this.OutputChannels / $this.Groups)
        for ($oc = $this.FirstChannel; $oc -lt $this.LastChannel; $oc++) {
            $group = [int](($oc - $oc % $outputsPerGroup) / $outputsPerGroup)
            for ($t = 0; $t -lt $this.OutputFrames; $t += 4) {
                $sum = [System.Runtime.Intrinsics.Vector128[float]]::Zero
                $timeGroup = [int]($t / 4)
                $packedBase = $timeGroup * $this.InputChannels * $this.Kernel
                for ($local = 0; $local -lt $inputsPerGroup; $local++) {
                    $ic = $group * $inputsPerGroup + $local
                    for ($tap = 0; $tap -lt $this.Kernel; $tap++) {
                        $at = ($oc * $inputsPerGroup + $local) * $this.Kernel + $tap
                        if ($this.Transpose) { $at = ($ic * $outputsPerGroup + $oc % $outputsPerGroup) * $this.Kernel + $tap }
                        if (-not $this.ActiveTaps[$timeGroup * $this.Kernel + $tap]) { continue }
                        $values = $this.VectorInput[$packedBase + $ic * $this.Kernel + $tap]
                        $weight = [System.Runtime.Intrinsics.Vector128]::Create($this.Weights[$at])
                        $sum = [System.Runtime.Intrinsics.X86.Sse]::Add($sum, [System.Runtime.Intrinsics.X86.Sse]::Multiply($values, $weight))
                    }
                }
                $sum = [System.Runtime.Intrinsics.X86.Sse]::Add($sum, [System.Runtime.Intrinsics.Vector128]::Create($this.Bias[$oc]))
                $base = $oc * $this.OutputFrames + $t
                $this.Output[$base] = [System.Runtime.Intrinsics.X86.Sse41]::Extract($sum, [byte]0)
                if ($t + 1 -lt $this.OutputFrames) { $this.Output[$base + 1] = [System.Runtime.Intrinsics.X86.Sse41]::Extract($sum, [byte]1) }
                if ($t + 2 -lt $this.OutputFrames) { $this.Output[$base + 2] = [System.Runtime.Intrinsics.X86.Sse41]::Extract($sum, [byte]2) }
                if ($t + 3 -lt $this.OutputFrames) { $this.Output[$base + 3] = [System.Runtime.Intrinsics.X86.Sse41]::Extract($sum, [byte]3) }
            }
        }
    }
}

class OfflineRenderMath {
    static [double[]] MeasureLevels([float[]] $values, [int] $channels, [int] $frames, [int[]] $tokenFrames) {
        $totalFrames = 0
        for ($token = 0; $token -lt $tokenFrames.Length; $token++) { if ($tokenFrames[$token] -lt 1) { throw [ArgumentException]::new('Invalid token frame count.') }; $totalFrames += $tokenFrames[$token] }
        if ($totalFrames -ne $frames -or $values.Length -ne $channels * $frames) { throw [ArgumentException]::new('Level export alignment mismatch.') }
        $tokenValues = $channels * $tokenFrames.Length
        $output = [double[]]::new(2 * $channels + 2 * $tokenValues)
        for ($c = 0; $c -lt $channels; $c++) {
            $at = 0; $total = [double]0; $totalSquared = [double]0
            for ($token = 0; $token -lt $tokenFrames.Length; $token++) {
                $sum = [double]0; $squared = [double]0
                for ($i = 0; $i -lt $tokenFrames[$token]; $i++) { $value = [double]$values[$c * $frames + $at]; $sum += $value; $squared += $value * $value; $at++ }
                $output[2 * $channels + $token * $channels + $c] = $sum
                $output[2 * $channels + $tokenValues + $token * $channels + $c] = $squared
                $total += $sum; $totalSquared += $squared
            }
            $mean = $total / [double]$frames
            $variance = [Math]::Max([double]0, $totalSquared / [double]$frames - $mean * $mean)
            $output[$c] = [double][float]$mean; $output[$channels + $c] = [double][float]$variance
        }
        return $output
    }
    static [int[]] ScaleFrames([int[]] $durations, [int] $scale) {
        $output = [int[]]::new($durations.Length)
        for ($i = 0; $i -lt $durations.Length; $i++) { $output[$i] = $durations[$i] * $scale }
        return $output
    }
    static [float[]] ApplyLevels([float[]] $values, [int] $channels, [int] $frames, [float[]] $style, [float[]] $fc, [float[]] $bias, [float[]] $normWeight, [float[]] $normBias, [double[]] $statistics) {
        if ($values.Length -ne $channels * $frames -or $statistics.Length -lt 2 * $channels -or $fc.Length -ne 2 * $channels * $style.Length -or $bias.Length -ne 2 * $channels) { throw [ArgumentException]::new('Supplied level shape mismatch.') }
        $output = [float[]]::new($values.Length)
        for ($c = 0; $c -lt $channels; $c++) {
            $mean = [float]$statistics[$c]; $variance = [float]$statistics[$channels + $c]
            if (-not [float]::IsFinite($mean) -or -not [float]::IsFinite($variance) -or $variance -lt [float]0) { throw [ArgumentException]::new('Invalid supplied level.') }
            $gamma = [float]0; $beta = [float]0
            for ($j = 0; $j -lt $style.Length; $j++) {
                $gamma = [float]($gamma + [float]($fc[$c * $style.Length + $j] * $style[$j]))
                $beta = [float]($beta + [float]($fc[($c + $channels) * $style.Length + $j] * $style[$j]))
            }
            $gamma = [float]([float]1 + [float]($gamma + $bias[$c])); $beta = [float]($beta + $bias[$c + $channels])
            $inverse = [float]([float]1 / [MathF]::Sqrt([float]($variance + [float]0.00001)))
            for ($t = 0; $t -lt $frames; $t++) {
                $normal = [float]([float]($values[$c * $frames + $t] - $mean) * $inverse)
                $normal = [float]([float]($normal * $normWeight[$c]) + $normBias[$c])
                $output[$c * $frames + $t] = [float]([float]($normal * $gamma) + $beta)
            }
        }
        return $output
    }
    static [System.Runtime.Intrinsics.Vector128[float][]] PackInputs([float[]] $values, [int[]] $indices, [int] $channels, [int] $inputFrames, [int] $outputFrames, [int] $kernel) {
        $rounded = $outputFrames + (4 - $outputFrames % 4) % 4
        $output = [System.Runtime.Intrinsics.Vector128[float][]]::new([int]($rounded / 4) * $channels * $kernel)
        for ($t = 0; $t -lt $rounded; $t += 4) {
            $packedBase = [int]($t / 4) * $channels * $kernel
            for ($c = 0; $c -lt $channels; $c++) {
                for ($tap = 0; $tap -lt $kernel; $tap++) {
                    $map = $t * $kernel + $tap; $base = $c * $inputFrames
                    $i0 = $indices[$map]; $i1 = $indices[$map + $kernel]; $i2 = $indices[$map + 2 * $kernel]; $i3 = $indices[$map + 3 * $kernel]
                    $v0 = [float]0; $v1 = [float]0; $v2 = [float]0; $v3 = [float]0
                    if ($i0 -ge 0) { $v0 = $values[$base + $i0] }; if ($i1 -ge 0) { $v1 = $values[$base + $i1] }
                    if ($i2 -ge 0) { $v2 = $values[$base + $i2] }; if ($i3 -ge 0) { $v3 = $values[$base + $i3] }
                    $output[$packedBase + $c * $kernel + $tap] = [System.Runtime.Intrinsics.Vector128]::Create($v0, $v1, $v2, $v3)
                }
            }
        }
        return $output
    }
    static [bool[]] ActiveIndices([int[]] $indices, [int] $kernel) {
        $output = [bool[]]::new([int]($indices.Length / (4 * $kernel)))
        # One active flag for every time group and kernel tap.
        $output = [bool[]]::new([int]($indices.Length / 4))
        for ($t = 0; $t -lt [int]($indices.Length / $kernel); $t += 4) {
            for ($tap = 0; $tap -lt $kernel; $tap++) {
                $at = $t * $kernel + $tap
                $output[[int]($t / 4) * $kernel + $tap] = $indices[$at] -ge 0 -or $indices[$at + $kernel] -ge 0 -or $indices[$at + 2 * $kernel] -ge 0 -or $indices[$at + 3 * $kernel] -ge 0
            }
        }
        return $output
    }
    static [int[]] FrameIndices([int] $inputFrames, [int] $outputFrames, [int] $kernel, [int] $stride, [int] $dilation, [int] $padding, [bool] $transpose) {
        $rounded = $outputFrames + (4 - $outputFrames % 4) % 4; $output = [int[]]::new($rounded * $kernel)
        for ($t = 0; $t -lt $rounded; $t++) {
            for ($tap = 0; $tap -lt $kernel; $tap++) {
                $at = $t * $stride + $tap * $dilation - $padding
                if ($transpose) {
                    $at = $t + $padding - $tap * $dilation
                    if ($at -ge 0 -and $at % $stride -eq 0) { $at = [int]($at / $stride) } else { $at = -1 }
                }
                if ($t -ge $outputFrames -or $at -lt 0 -or $at -ge $inputFrames) { $at = -1 }
                $output[$t * $kernel + $tap] = $at
            }
        }
        return $output
    }
    static [float[]] FoldWeights([float[]] $values, [float[]] $gain) {
        if ($gain.Length -lt 1 -or $values.Length % $gain.Length -ne 0) { throw [ArgumentException]::new('Weight normalization shape mismatch.') }
        $width = [int]($values.Length / $gain.Length); $output = [float[]]::new($values.Length)
        for ($row = 0; $row -lt $gain.Length; $row++) {
            $sum = [float]0
            for ($i = 0; $i -lt $width; $i++) { $v = $values[$row * $width + $i]; $sum = [float]($sum + [float]($v * $v)) }
            $scale = [float]($gain[$row] / [MathF]::Sqrt($sum))
            for ($i = 0; $i -lt $width; $i++) { $output[$row * $width + $i] = [float]($values[$row * $width + $i] * $scale) }
        }
        return $output
    }
    static [float[]] Align([float[]] $encoder, [int[]] $durations) {
        $frames = 0
        for ($i = 0; $i -lt $durations.Length; $i++) { if ($durations[$i] -lt 1) { throw [ArgumentException]::new('Nonpositive duration.') }; $frames += $durations[$i] }
        if ($encoder.Length -ne 512 * $durations.Length) { throw [ArgumentException]::new('Encoder alignment shape mismatch.') }
        $output = [float[]]::new(512 * $frames)
        for ($c = 0; $c -lt 512; $c++) {
            $at = 0
            for ($i = 0; $i -lt $durations.Length; $i++) {
                $value = $encoder[$c * $durations.Length + $i]
                for ($j = 0; $j -lt $durations[$i]; $j++) { $output[$c * $frames + $at] = $value; $at++ }
            }
        }
        return $output
    }
    static [float[]] AdaIn([float[]] $values, [int] $channels, [int] $frames, [float[]] $style, [float[]] $fc, [float[]] $bias, [float[]] $normWeight, [float[]] $normBias) {
        if ($values.Length -ne $channels * $frames -or $fc.Length -ne $channels * 2 * $style.Length -or $bias.Length -ne $channels * 2 -or $normWeight.Length -ne $channels -or $normBias.Length -ne $channels) { throw [ArgumentException]::new('AdaIN shape mismatch.') }
        $output = [float[]]::new($values.Length)
        for ($c = 0; $c -lt $channels; $c++) {
            $gamma = [float]0; $beta = [float]0
            for ($j = 0; $j -lt $style.Length; $j++) {
                $gamma = [float]($gamma + [float]($fc[$c * $style.Length + $j] * $style[$j]))
                $beta = [float]($beta + [float]($fc[($c + $channels) * $style.Length + $j] * $style[$j]))
            }
            $gamma = [float]([float]1 + [float]($gamma + $bias[$c])); $beta = [float]($beta + $bias[$c + $channels])
            $mean = [float]0
            for ($t = 0; $t -lt $frames; $t++) { $mean = [float]($mean + $values[$c * $frames + $t]) }
            $mean = [float]($mean / [float]$frames); $variance = [float]0
            for ($t = 0; $t -lt $frames; $t++) { $delta = [float]($values[$c * $frames + $t] - $mean); $variance = [float]($variance + [float]($delta * $delta)) }
            $inverse = [float]([float]1 / [MathF]::Sqrt([float]($variance / [float]$frames + [float]0.00001)))
            for ($t = 0; $t -lt $frames; $t++) {
                $normal = [float]([float]($values[$c * $frames + $t] - $mean) * $inverse)
                $normal = [float]([float]($normal * $normWeight[$c]) + $normBias[$c])
                $output[$c * $frames + $t] = [float]([float]($normal * $gamma) + $beta)
            }
        }
        return $output
    }
    static [float[]] Leaky([float[]] $values, [float] $slope) {
        $output = [float[]]::new($values.Length)
        for ($i = 0; $i -lt $values.Length; $i++) { $value = $values[$i]; if ($value -lt [float]0) { $value = [float]($value * $slope) }; $output[$i] = $value }
        return $output
    }
    static [float[]] Residual([float[]] $a, [float[]] $b, [float] $scale) {
        if ($a.Length -ne $b.Length) { throw [ArgumentException]::new('Residual shape mismatch.') }
        $output = [float[]]::new($a.Length)
        for ($i = 0; $i -lt $a.Length; $i++) { $output[$i] = [float]([float]($a[$i] + $b[$i]) * $scale) }
        return $output
    }
    static [float[]] Nearest2([float[]] $values, [int] $channels, [int] $frames) {
        $output = [float[]]::new(2 * $values.Length)
        for ($c = 0; $c -lt $channels; $c++) {
            for ($t = 0; $t -lt $frames; $t++) { $output[$c * 2 * $frames + 2 * $t] = $values[$c * $frames + $t]; $output[$c * 2 * $frames + 2 * $t + 1] = $values[$c * $frames + $t] }
        }
        return $output
    }
    static [float[]] Snake([float[]] $values, [float[]] $alpha, [int] $frames) {
        if ($alpha.Length * $frames -ne $values.Length) { throw [ArgumentException]::new('Snake shape mismatch.') }
        $output = [float[]]::new($values.Length)
        for ($c = 0; $c -lt $alpha.Length; $c++) {
            $inverse = [float]([float]1 / $alpha[$c])
            for ($t = 0; $t -lt $frames; $t++) {
                $at = $c * $frames + $t; $sine = [MathF]::Sin([float]($alpha[$c] * $values[$at]))
                $output[$at] = [float]($values[$at] + [float]($inverse * [float]($sine * $sine)))
            }
        }
        return $output
    }
    static [float[]] Average3([float[]] $a, [float[]] $b, [float[]] $c) {
        if ($a.Length -ne $b.Length -or $a.Length -ne $c.Length) { throw [ArgumentException]::new('Average shape mismatch.') }
        $output = [float[]]::new($a.Length)
        for ($i = 0; $i -lt $a.Length; $i++) { $output[$i] = [float]([float]([float]($a[$i] + $b[$i]) + $c[$i]) / [float]3) }
        return $output
    }
    static [float[]] ReflectLeft([float[]] $values, [int] $channels, [int] $frames) {
        $output = [float[]]::new($channels * ($frames + 1))
        for ($c = 0; $c -lt $channels; $c++) {
            $output[$c * ($frames + 1)] = $values[$c * $frames + 1]
            [Array]::Copy($values, $c * $frames, $output, $c * ($frames + 1) + 1, $frames)
        }
        return $output
    }
    static [float[]] Draws([int] $seed, [int] $samples) {
        $rng = [Random]::new($seed); $output = [float[]]::new(9 + 10 * $samples)
        for ($i = 0; $i -lt 9; $i++) { $output[$i] = $rng.NextSingle() }
        for ($i = 9; $i -lt $output.Length; $i += 2) {
            $uniform = $rng.NextDouble()
            while ($uniform -le [double]0) { $uniform = $rng.NextDouble() }
            $radius = [Math]::Sqrt([double]-2 * [Math]::Log($uniform)); $angle = [double]6.283185307179586 * $rng.NextDouble()
            $output[$i] = [float]($radius * [Math]::Cos($angle))
            if ($i + 1 -lt $output.Length) { $output[$i + 1] = [float]($radius * [Math]::Sin($angle)) }
        }
        return $output
    }
    static [float[]] Harmonic([float[]] $f0, [float[]] $draw0, [float[]] $draw1, [float[]] $draw2, [float[]] $weight, [float[]] $bias) {
        $samples = 300 * $f0.Length
        if ($draw0.Length -ne 9 -or $draw1.Length -ne 9 * $samples -or $draw2.Length -ne $samples -or $weight.Length -ne 9 -or $bias.Length -ne 1) { throw [ArgumentException]::new('Harmonic source shape mismatch.') }
        $phase = [float[]]::new(9 * $f0.Length)
        for ($h = 0; $h -lt 9; $h++) {
            $sum = [double]0
            for ($t = 0; $t -lt $f0.Length; $t++) {
                $rad = [float]([float]($f0[$t] * [float]($h + 1)) / [float]24000)
                $rad = [float]($rad - [MathF]::Floor($rad)); $sum += [double]$rad
                $phase[$h * $f0.Length + $t] = [float]([float]([float]([float]$sum * [float]2) * [float]3.141592653589793) * [float]300)
            }
        }
        # The initial rand draw is added at sample zero before 300x linear
        # downsampling. Its first sample location is 149.5, so that added value
        # has no contribution to the downsampled phase in this stock graph.
        $output = [float[]]::new($samples)
        for ($t = 0; $t -lt $samples; $t++) {
            # PyTorch area_pixel_compute_source_index multiplies by the
            # float32 reciprocal scale; dividing by 300 rounds differently.
            $position = [float]([float]([float]0.0033333333333333335 * [float]([float]$t + [float]0.5)) - [float]0.5)
            if ($position -lt [float]0) { $position = [float]0 }
            $lower = [int][MathF]::Floor($position); $upper = $lower + 1
            if ($upper -ge $f0.Length) { $upper = $f0.Length - 1 }
            $fraction = [float]($position - [float]$lower); $level = [float]0
            $ft = [int](($t - $t % 300) / 300); $voiced = $f0[$ft] -gt [float]10
            $noiseAmplitude = [float]([float]0.1 / [float]3)
            if ($voiced) { $noiseAmplitude = [float]0.003 }
            for ($h = 0; $h -lt 9; $h++) {
                $angle = [float]([float]([float]([float]1 - $fraction) * $phase[$h * $f0.Length + $lower]) + [float]($fraction * $phase[$h * $f0.Length + $upper]))
                $value = [float]0
                if ($voiced) { $value = [float]([MathF]::Sin($angle) * [float]0.1) }
                $value = [float]($value + [float]($noiseAmplitude * $draw1[$t * 9 + $h]))
                $level = [float]($level + [float]($value * $weight[$h]))
            }
            $output[$t] = [MathF]::Tanh([float]($level + $bias[0]))
        }
        return $output
    }
    static [float[]] Stft([float[]] $values) {
        $frames = [int](($values.Length - $values.Length % 5) / 5) + 1
        $output = [float[]]::new(22 * $frames); $window = [float[]]::new(20)
        $cosine = [float[]]::new(220); $sine = [float[]]::new(220)
        for ($i = 0; $i -lt 20; $i++) {
            $window[$i] = [float]([float]0.5 * [float]([float]1 - [MathF]::Cos([float]([float]0.3141592653589793 * [float]$i))))
            for ($k = 0; $k -lt 11; $k++) { $angle = [double]6.283185307179586 * [double]$k * [double]$i / [double]20; $cosine[$k * 20 + $i] = [float][Math]::Cos($angle); $sine[$k * 20 + $i] = [float][Math]::Sin($angle) }
        }
        for ($t = 0; $t -lt $frames; $t++) {
            for ($k = 0; $k -lt 11; $k++) {
                $real = [float]0; $imaginary = [float]0
                for ($i = 0; $i -lt 20; $i++) {
                    $at = $t * 5 + $i - 10
                    if ($at -lt 0) { $at = -$at }; if ($at -ge $values.Length) { $at = 2 * $values.Length - 2 - $at }
                    $v = [float]($values[$at] * $window[$i]); $real = [float]($real + [float]($v * $cosine[$k * 20 + $i])); $imaginary = [float]($imaginary - [float]($v * $sine[$k * 20 + $i]))
                }
                # A real even-length FFT has real DC and Nyquist bins. Do not
                # let rounded sine coefficients create an imaginary residue
                # that changes angle's negative-real branch from +pi to -pi.
                if ($k -eq 0 -or $k -eq 10) { $imaginary = [float]0 }
                $output[$k * $frames + $t] = [MathF]::Sqrt([float]([float]($real * $real) + [float]($imaginary * $imaginary)))
                $output[($k + 11) * $frames + $t] = [MathF]::Atan2($imaginary, $real)
            }
        }
        return $output
    }
    static [float[]] SourceExtra([float[]] $f0, [float[]] $draw2) {
        if ($draw2.Length -ne 300 * $f0.Length) { throw [ArgumentException]::new('Source noise shape mismatch.') }
        $output = [float[]]::new(2 * $draw2.Length)
        for ($t = 0; $t -lt $draw2.Length; $t++) {
            $output[$t] = [float]([float]($draw2[$t] * [float]0.1) / [float]3)
            if ($f0[[int](($t - $t % 300) / 300)] -gt [float]10) { $output[$draw2.Length + $t] = [float]1 }
        }
        return $output
    }
    static [float[]] InverseStft([float[]] $values, [int] $frames) {
        if ($values.Length -ne 22 * $frames) { throw [ArgumentException]::new('iSTFT shape mismatch.') }
        $length = ($frames - 1) * 5 + 20; $wave = [float[]]::new($length); $envelope = [float[]]::new($length)
        $window = [float[]]::new(20); $cosine = [float[]]::new(220); $sine = [float[]]::new(220)
        for ($i = 0; $i -lt 20; $i++) {
            $window[$i] = [float]([float]0.5 * [float]([float]1 - [MathF]::Cos([float]([float]0.3141592653589793 * [float]$i))))
            for ($k = 0; $k -lt 11; $k++) { $angle = [double]6.283185307179586 * [double]$k * [double]$i / [double]20; $cosine[$k * 20 + $i] = [float][Math]::Cos($angle); $sine[$k * 20 + $i] = [float][Math]::Sin($angle) }
        }
        $real = [float[]]::new(11); $imaginary = [float[]]::new(11)
        for ($t = 0; $t -lt $frames; $t++) {
            for ($k = 0; $k -lt 11; $k++) {
                $magnitude = [MathF]::Exp($values[$k * $frames + $t]); $phase = [MathF]::Sin($values[($k + 11) * $frames + $t])
                $real[$k] = [float]($magnitude * [MathF]::Cos($phase)); $imaginary[$k] = [float]($magnitude * [MathF]::Sin($phase))
            }
            for ($i = 0; $i -lt 20; $i++) {
                $sum = [float]0
                for ($k = 0; $k -lt 11; $k++) {
                    $term = [float]([float]($real[$k] * $cosine[$k * 20 + $i]) - [float]($imaginary[$k] * $sine[$k * 20 + $i]))
                    if ($k -gt 0 -and $k -lt 10) { $term = [float]($term * [float]2) }
                    $sum = [float]($sum + $term)
                }
                $at = $t * 5 + $i; $wave[$at] = [float]($wave[$at] + [float]([float]($sum / [float]20) * $window[$i]))
                $envelope[$at] = [float]($envelope[$at] + [float]($window[$i] * $window[$i]))
            }
        }
        $output = [float[]]::new($length - 20)
        for ($i = 0; $i -lt $output.Length; $i++) { $output[$i] = [float]($wave[$i + 10] / $envelope[$i + 10]) }
        return $output
    }
    static [double[]] Compare([float[]] $actual, [float[]] $expected) {
        if ($actual.Length -ne $expected.Length) { throw [ArgumentException]::new('PCM shape mismatch.') }
        $signal = [double]0; $squaredError = [double]0; $maximum = [double]0
        for ($i = 0; $i -lt $actual.Length; $i++) {
            if (-not [float]::IsFinite($actual[$i]) -or -not [float]::IsFinite($expected[$i])) { throw [ArgumentException]::new('Nonfinite PCM.') }
            $delta = [double]$actual[$i] - [double]$expected[$i]; $squaredError += $delta * $delta; $signal += [double]$expected[$i] * [double]$expected[$i]
            $maximum = [Math]::Max($maximum, [Math]::Abs($delta))
        }
        $snr = [double]::PositiveInfinity
        if ($squaredError -gt [double]0) { $snr = [double]10 * [Math]::Log10($signal / $squaredError) }
        return [double[]]@($snr, $maximum)
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($h) { Get-Help $PSCommandPath -Detailed; return }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'build/precomputed-decoder-20261014' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith((Join-Path $root 'build') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be in this worktree build/.' }
[void][IO.Directory]::CreateDirectory($output)
$compiler = Join-Path $root 'build/phonemizer/inputs/pslowering-1afabe056235a570da29e268824784557d4f6cdd'
$pins = @(Import-Csv -LiteralPath (Join-Path $compiler 'verified-source.tsv') -Delimiter "`t")
if ($pins.Count -ne 9) { throw 'Incomplete pinned frontend compiler.' }
foreach ($pin in $pins) {
    $path = [IO.Path]::GetFullPath((Join-Path $compiler $pin.Path))
    if (-not $path.StartsWith($compiler + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $pin.Commit -cne '1afabe056235a570da29e268824784557d4f6cdd' -or
        (Get-FileHash -LiteralPath $path).Hash -cne $pin.Sha256) { throw 'Pinned compiler integrity mismatch.' }
}
Import-Module (Join-Path $compiler 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1')
$sourceHash = (Get-FileHash -LiteralPath $PSCommandPath).Hash
$dllDirectory = Join-Path $output $sourceHash
[void][IO.Directory]::CreateDirectory($dllDirectory)
$dll = Join-Path $dllDirectory 'Kokoro.OfflineRender.dll'
$compiled = Export-LoweredAssembly -SourcePath $PSCommandPath -ClassName OfflineConvolutionWorker -OutputPath $dll -Deterministic
$admission = Test-LoweredAssembly -AssemblyPath $dll
if (-not $admission.ClrOnlyAdmitted) { throw 'Offline numeric kernels reference SMA.' }
$assembly = [Reflection.Assembly]::LoadFrom($dll)
$workerType = $assembly.GetType('OfflineConvolutionWorker', $true)
$mathType = $assembly.GetType('OfflineRenderMath', $true)
$frameIndices = $mathType.GetMethod('FrameIndices').CreateDelegate([Func[int,int,int,int,int,int,bool,int[]]])
$packInputs = $mathType.GetMethod('PackInputs').CreateDelegate([Func[float[],int[],int,int,int,int,System.Runtime.Intrinsics.Vector128[float][]]])
$activeIndices = $mathType.GetMethod('ActiveIndices').CreateDelegate([Func[int[],int,bool[]]])
if (-not [Sse]::IsSupported -or -not [Sse41]::IsSupported) { throw 'Required SSE/SSE4.1 intrinsics unavailable on this host.' }
$workers = [Collections.Generic.List[object]]::new()
$tasks = [Collections.Generic.List[Threading.Tasks.Task]]::new()
$testOutput = [float[]]::new(16)
for ($index = 0; $index -lt 2; $index++) {
    $worker = [Activator]::CreateInstance($workerType)
    $worker.Input = [float[]]@(1,2,3,4,5,6,7,8); $worker.Weights = [float[]]@(2,3); $worker.Bias = [float[]]@(1,2)
    $worker.Output = $testOutput; $worker.InputChannels = 1; $worker.OutputChannels = 2
    $worker.Indices = $frameIndices.Invoke(8,8,1,1,1,0,$false)
    $worker.VectorInput = $packInputs.Invoke($worker.Input, $worker.Indices, 1, 8, 8, 1)
    $worker.ActiveTaps = $activeIndices.Invoke($worker.Indices, 1)
    $worker.InputFrames = 8; $worker.OutputFrames = 8; $worker.Kernel = 1; $worker.Stride = 1; $worker.Dilation = 1; $worker.Groups = 1
    $worker.FirstChannel = $index; $worker.LastChannel = $index + 1
    $action = $workerType.GetMethod('Run').CreateDelegate([Action], $worker)
    $workers.Add($worker); $tasks.Add([Threading.Tasks.Task]::Run($action))
}
[Threading.Tasks.Task]::WaitAll($tasks.ToArray())
$expected = [float[]]@(3,5,7,9,11,13,15,17,5,8,11,14,17,20,23,26)
if (-not [Linq.Enumerable]::SequenceEqual[float]($testOutput, $expected)) { throw 'Threaded SIMD convolution admission failed.' }
if ($Mode -eq 'Admit') { $admission; return }

$foldWeights = $mathType.GetMethod('FoldWeights').CreateDelegate([Func[float[],float[],float[]]])
$align = $mathType.GetMethod('Align').CreateDelegate([Func[float[],int[],float[]]])
$adaIn = $mathType.GetMethod('AdaIn').CreateDelegate([Func[float[],int,int,float[],float[],float[],float[],float[],float[]]])
$leaky = $mathType.GetMethod('Leaky').CreateDelegate([Func[float[],float,float[]]])
$residual = $mathType.GetMethod('Residual').CreateDelegate([Func[float[],float[],float,float[]]])
$nearest2 = $mathType.GetMethod('Nearest2').CreateDelegate([Func[float[],int,int,float[]]])
$snake = $mathType.GetMethod('Snake').CreateDelegate([Func[float[],float[],int,float[]]])
$average3 = $mathType.GetMethod('Average3').CreateDelegate([Func[float[],float[],float[],float[]]])
$reflectLeft = $mathType.GetMethod('ReflectLeft').CreateDelegate([Func[float[],int,int,float[]]])
$draws = $mathType.GetMethod('Draws').CreateDelegate([Func[int,int,float[]]])
$harmonic = $mathType.GetMethod('Harmonic').CreateDelegate([Func[float[],float[],float[],float[],float[],float[],float[]]])
$stft = $mathType.GetMethod('Stft').CreateDelegate([Func[float[],float[]]])
$inverseStft = $mathType.GetMethod('InverseStft').CreateDelegate([Func[float[],int,float[]]])
$compare = $mathType.GetMethod('Compare').CreateDelegate([Func[float[],float[],double[]]])
$sourceExtra = $mathType.GetMethod('SourceExtra').CreateDelegate([Func[float[],float[],float[]]])
$measureLevels = $mathType.GetMethod('MeasureLevels').CreateDelegate([Func[float[],int,int,int[],double[]]])
$scaleFrames = $mathType.GetMethod('ScaleFrames').CreateDelegate([Func[int[],int,int[]]])
$applyLevels = $mathType.GetMethod('ApplyLevels').CreateDelegate([Func[float[],int,int,float[],float[],float[],float[],float[],double[],float[]]])
$torch = Import-Module (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1') -PassThru
$reader = $torch.Invoke({ [pscustomobject]@{ Read = $read; Bytes = $bytes; ReadTensor = $readTensor; TensorRow = $tensorRow } })[0]
$modelPath = Join-Path $InputRepository 'build/inputs/kokoro/f3ff3571791e39611d31c381e3a41a3af07b4987/kokoro-v1_0.pth'
if ((Get-FileHash -LiteralPath $modelPath).Hash -cne '496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4') { throw 'Checkpoint integrity mismatch.' }
$checkpoint = & $reader.Read $modelPath
$weightCache = [Collections.Generic.Dictionary[string,float[]]]::new([StringComparer]::Ordinal)
$convolutionCache = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$profile = [Collections.Generic.List[object]]::new()
$levelContext = $null
$nodeReferences = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$nodeResults = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
if ($Mode -eq 'Nodes') {
    $nodeManifest = Import-PowerShellDataFile (Join-Path $InputRepository 'build/node-capture-20261014/nodes.psd1')
    foreach ($node in $nodeManifest.Nodes) {
        if ($node.File -cnotmatch '^[A-Za-z0-9_.-]+\.bin$') { throw 'Invalid node path.' }
        $path = Join-Path $InputRepository ('build/node-capture-20261014/' + $node.File)
        if ((Get-FileHash -LiteralPath $path).Hash -cne $node.SHA256) { throw 'Node reference integrity mismatch.' }
        $count = 1L; foreach ($dimension in $node.Shape) { $count *= $dimension }
        $raw = [IO.File]::ReadAllBytes($path)
        if ($raw.Length -ne 4 * $count) { throw 'Node reference shape mismatch.' }
        $values = [float[]]::new($count); [Buffer]::BlockCopy($raw, 0, $values, 0, $raw.Length)
        $nodeReferences.Add($node.Name, [pscustomobject]@{ Descriptor = $node; Values = $values })
    }
}
function Test-OfflineNode([string] $NodeName, [float[]] $InputValues) {
    if ($Mode -cne 'Nodes') { return }
    if (-not $nodeReferences.ContainsKey($NodeName) -or $nodeResults.ContainsKey($NodeName)) { throw "Missing/duplicate node: $NodeName" }
    $referenceNode = $nodeReferences[$NodeName]
    $metrics = $compare.Invoke($InputValues, $referenceNode.Values)
    $peak = [Math]::Max([Math]::Abs([double][Linq.Enumerable]::Min($referenceNode.Values)), [Math]::Abs([double][Linq.Enumerable]::Max($referenceNode.Values)))
    $result = [pscustomobject]@{ Name = $NodeName; MaxAbsError = $metrics[1]; SnrDb = $metrics[0]; ReferencePeak = $peak;
        BeyondFloatNoise = ($metrics[0] -lt 80 -or $metrics[1] -gt 0.0001 * [Math]::Max(1, $peak));
        AssemblySHA256 = $admission.SHA256; SourceSHA256 = $sourceHash; ReferenceSHA256 = $referenceNode.Descriptor.SHA256 }
    $nodeResults.Add($NodeName, $result)
    $raw = [byte[]]::new(4 * $InputValues.Length); [Buffer]::BlockCopy($InputValues, 0, $raw, 0, $raw.Length)
    [IO.File]::WriteAllBytes((Join-Path $output ($NodeName + '.candidate.f32')), $raw)
    $orderedResults = @($nodeManifest.Nodes | Where-Object { $nodeResults.ContainsKey($_.Name) } | ForEach-Object { $nodeResults[$_.Name] })
    $orderedResults | Export-Clixml -LiteralPath (Join-Path $output 'nodes.clixml')
    Write-Host ('node {0}: max={1:G9}; SNR={2:F6} dB; beyond_float_noise={3}' -f $NodeName, $metrics[1], $metrics[0], $result.BeyondFloatNoise)
}

function Read-OfflineWeight([string] $Name) {
    if ($weightCache.ContainsKey($Name)) { return , $weightCache[$Name] }
    $tensor = $checkpoint.Tensors[$Name]
    if ($null -eq $tensor -or $tensor.DType -cne 'float32') { throw "Missing/non-FP32 weight: $Name" }
    $stride = 1L
    for ($axis = $tensor.Shape.Length - 1; $axis -ge 0; $axis--) { if ($tensor.Stride[$axis] -ne $stride) { throw 'Noncontiguous model weight.' }; $stride *= $tensor.Shape[$axis] }
    $raw = & $reader.Bytes $checkpoint $Name; $values = [float[]]::new($tensor.Count)
    [Buffer]::BlockCopy($raw, 0, $values, 0, $raw.Length); $weightCache.Add($Name, $values)
    return , $values
}
function Get-OfflineConvolution([string] $Name, [int] $Groups, [bool] $Transpose) {
    if ($convolutionCache.ContainsKey($Name)) { return $convolutionCache[$Name] }
    $prefix = 'decoder.module.' + $Name
    $weightName = $prefix + '.weight'; $weight = $null
    if ($checkpoint.Tensors.Contains($weightName)) { $weight = Read-OfflineWeight $weightName }
    else {
        $weightName = $prefix + '.weight_v'
        $weight = $foldWeights.Invoke((Read-OfflineWeight $weightName), (Read-OfflineWeight ($prefix + '.weight_g')))
    }
    $shape = $checkpoint.Tensors[$weightName].Shape
    $cin = $shape[1] * $Groups; $cout = $shape[0]
    if ($Transpose) { $cin = $shape[0]; $cout = $shape[1] * $Groups }
    $bias = [float[]]::new($cout)
    if ($checkpoint.Tensors.Contains($prefix + '.bias')) { $bias = Read-OfflineWeight ($prefix + '.bias') }
    $result = [pscustomobject]@{ Weights = $weight; Bias = $bias; InputChannels = $cin; OutputChannels = $cout; Kernel = $shape[2] }
    $convolutionCache.Add($Name, $result); $result
}
function Invoke-OfflineConv {
    param([float[]] $InputValues, [int] $Frames, [string] $Name, [int] $Stride = 1, [int] $Padding = 0, [int] $Dilation = 1, [int] $Groups = 1, [switch] $Transpose, [int] $OutputPadding = 0)
    $conv = Get-OfflineConvolution $Name $Groups $Transpose.IsPresent
    if ($InputValues.Length -ne $conv.InputChannels * $Frames) { throw "Convolution input shape: $Name" }
    $outFrames = [int][Math]::Floor(($Frames + 2 * $Padding - $Dilation * ($conv.Kernel - 1) - 1) / [double]$Stride) + 1
    if ($Transpose) { $outFrames = ($Frames - 1) * $Stride - 2 * $Padding + $Dilation * ($conv.Kernel - 1) + $OutputPadding + 1 }
    $result = [float[]]::new($conv.OutputChannels * $outFrames)
    $indices = $frameIndices.Invoke($Frames, $outFrames, $conv.Kernel, $Stride, $Dilation, $Padding, $Transpose.IsPresent)
    $vectors = $packInputs.Invoke($InputValues, $indices, $conv.InputChannels, $Frames, $outFrames, $conv.Kernel)
    $active = $activeIndices.Invoke($indices, $conv.Kernel)
    $running = [Collections.Generic.List[Threading.Tasks.Task]]::new(); $keepWorkers = [Collections.Generic.List[object]]::new()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    for ($workerIndex = 0; $workerIndex -lt [Math]::Min($Threads, $conv.OutputChannels); $workerIndex++) {
        $worker = [Activator]::CreateInstance($workerType)
        $worker.Input = $InputValues; $worker.Output = $result; $worker.Weights = $conv.Weights; $worker.Bias = $conv.Bias
        $worker.Indices = $indices
        $worker.VectorInput = $vectors; $worker.ActiveTaps = $active
        $worker.InputChannels = $conv.InputChannels; $worker.OutputChannels = $conv.OutputChannels
        $worker.InputFrames = $Frames; $worker.OutputFrames = $outFrames
        $worker.Kernel = $conv.Kernel; $worker.Stride = $Stride; $worker.Dilation = $Dilation; $worker.Padding = $Padding; $worker.Groups = $Groups; $worker.Transpose = $Transpose.IsPresent
        $worker.FirstChannel = [int][Math]::Floor($workerIndex * $conv.OutputChannels / [double][Math]::Min($Threads, $conv.OutputChannels))
        $worker.LastChannel = [int][Math]::Floor(($workerIndex + 1) * $conv.OutputChannels / [double][Math]::Min($Threads, $conv.OutputChannels))
        $action = $workerType.GetMethod('Run').CreateDelegate([Action], $worker)
        $keepWorkers.Add($worker); $running.Add([Threading.Tasks.Task]::Run($action))
    }
    [Threading.Tasks.Task]::WaitAll($running.ToArray()); $watch.Stop()
    $profile.Add([pscustomobject]@{ Stage = $Name; Kind = 'Convolution'; Milliseconds = $watch.Elapsed.TotalMilliseconds; Frames = $outFrames })
    return , $result
}
function Invoke-OfflineAdaIn([float[]] $InputValues, [int] $Channels, [int] $Frames, [float[]] $AcousticStyle, [string] $Name) {
    $prefix = 'decoder.module.' + $Name
    $fc = Read-OfflineWeight ($prefix + '.fc.weight'); $bias = Read-OfflineWeight ($prefix + '.fc.bias')
    # The checkpoint omits these affine parameters. Stock's non-strict load
    # retains InstanceNorm's initialized ones/zeros in that case.
    $normWeight = [float[]]::new($Channels); [Array]::Fill($normWeight, [float]1)
    $normBias = [float[]]::new($Channels)
    if ($checkpoint.Tensors.Contains($prefix + '.norm.weight')) { $normWeight = Read-OfflineWeight ($prefix + '.norm.weight') }
    if ($checkpoint.Tensors.Contains($prefix + '.norm.bias')) { $normBias = Read-OfflineWeight ($prefix + '.norm.bias') }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $kind = 'LiveAdaIN'
    if ($null -ne $levelContext -and -not $Name.StartsWith('generator.', [StringComparison]::Ordinal)) {
        $record = [OfflineLevelRecord]::new(); $record.Name = $Name; $record.Channels = $Channels; $record.Frames = $Frames
        $record.TokenFrames = $scaleFrames.Invoke($levelContext.Durations, $(if ($Name -ceq 'decode.3.norm2') { 2 } else { 1 }))
        if ($levelContext.Mode -ceq 'Live') { $record.Statistics = $measureLevels.Invoke($InputValues, $Channels, $Frames, $record.TokenFrames) }
        else {
            if (-not $levelContext.Supplied.ContainsKey($Name) -or $levelContext.Supplied[$Name].Channels -ne $Channels) { throw "Missing/mismatched supplied site: $Name" }
            $record.Statistics = $levelContext.Supplied[$Name].Statistics; $kind = 'SuppliedAdaIN'
        }
        $result = $applyLevels.Invoke($InputValues, $Channels, $Frames, $AcousticStyle, $fc, $bias, $normWeight, $normBias, $record.Statistics)
        $levelContext.Exported.Add($record)
    } else { $result = $adaIn.Invoke($InputValues, $Channels, $Frames, $AcousticStyle, $fc, $bias, $normWeight, $normBias) }
    $watch.Stop()
    $profile.Add([pscustomobject]@{ Stage = $Name; Kind = $kind; Milliseconds = $watch.Elapsed.TotalMilliseconds; Frames = $Frames })
    return , $result
}
function Join-OfflineChannels([float[]] $A, [float[]] $B, [float[]] $C, [float[]] $D) {
    $result = [float[]]::new($A.Length + $B.Length + $C.Length + $D.Length)
    [Array]::Copy($A, 0, $result, 0, $A.Length); [Array]::Copy($B, 0, $result, $A.Length, $B.Length)
    [Array]::Copy($C, 0, $result, $A.Length + $B.Length, $C.Length); [Array]::Copy($D, 0, $result, $A.Length + $B.Length + $C.Length, $D.Length)
    return , $result
}
function Invoke-OfflineDecoderBlock([float[]] $InputValues, [int] $Frames, [float[]] $AcousticStyle, [string] $Name, [switch] $Upsample) {
    $cin = [int]($InputValues.Length / $Frames)
    $next = Invoke-OfflineAdaIn $InputValues $cin $Frames $AcousticStyle ($Name + '.norm1')
    $next = $leaky.Invoke($next, [float]0.2); $nextFrames = $Frames
    if ($Upsample) { $next = Invoke-OfflineConv $next $Frames ($Name + '.pool') -Stride 2 -Padding 1 -Groups $cin -Transpose -OutputPadding 1; $nextFrames = 2 * $Frames }
    $next = Invoke-OfflineConv $next $nextFrames ($Name + '.conv1') -Padding 1
    $cout = [int]($next.Length / $nextFrames)
    $next = Invoke-OfflineAdaIn $next $cout $nextFrames $AcousticStyle ($Name + '.norm2')
    $next = $leaky.Invoke($next, [float]0.2)
    $next = Invoke-OfflineConv $next $nextFrames ($Name + '.conv2') -Padding 1
    $shortcut = $InputValues
    if ($Upsample) { $shortcut = $nearest2.Invoke($InputValues, $cin, $Frames) }
    if ($cin -ne $cout) { $shortcut = Invoke-OfflineConv $shortcut $nextFrames ($Name + '.conv1x1') }
    return , $residual.Invoke($next, $shortcut, [float]0.70710677)
}
function Invoke-OfflineDecoder {
    param([float[]] $AsrValues, [float[]] $PitchCurve, [float[]] $EnergyCurve, [float[]] $AcousticStyle,
        [int[]] $TokenDurations, [ValidateSet('Live','Supplied')][string] $LevelMode = 'Live',
        [Collections.Generic.Dictionary[string,object]] $SuppliedLevels = $null)
    $levelContext = [pscustomobject]@{ Mode = $LevelMode; Durations = $TokenDurations; Supplied = $SuppliedLevels; Exported = [Collections.Generic.List[OfflineLevelRecord]]::new() }
    $frames = [int]($AsrValues.Length / 512)
    if ($AsrValues.Length -ne 512 * $frames -or $PitchCurve.Length -ne 2 * $frames -or $EnergyCurve.Length -ne $PitchCurve.Length -or $AcousticStyle.Length -ne 128) { throw 'Decoder input shape mismatch.' }
    $pitch = Invoke-OfflineConv $PitchCurve $PitchCurve.Length 'F0_conv' -Stride 2 -Padding 1
    $energy = Invoke-OfflineConv $EnergyCurve $EnergyCurve.Length 'N_conv' -Stride 2 -Padding 1
    $x = Join-OfflineChannels $AsrValues $pitch $energy ([float[]]::new(0))
    $x = Invoke-OfflineDecoderBlock $x $frames $AcousticStyle 'encode'
    Test-OfflineNode 'dec.encode' $x
    $asrResidual = Invoke-OfflineConv $AsrValues $frames 'asr_res.0'
    for ($block = 0; $block -lt 4; $block++) {
        $x = Join-OfflineChannels $x $asrResidual $pitch $energy
        $x = Invoke-OfflineDecoderBlock $x $frames $AcousticStyle "decode.$block" -Upsample:($block -eq 3)
        Test-OfflineNode ("dec.decode$block") $x
    }
    $result = [OfflineDecoderResult]::new(); $result.Features = $x; $result.Levels = $levelContext.Exported.ToArray()
    return $result
}
function Test-OfflineLevelReplay([OfflineDecoderResult] $LiveResult, [float[]] $AsrValues, [float[]] $PitchCurve, [float[]] $EnergyCurve, [float[]] $AcousticStyle, [int[]] $TokenLengths) {
    $supplied = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($site in $LiveResult.Levels) { $supplied.Add($site.Name, $site) }
    $replay = Invoke-OfflineDecoder $AsrValues $PitchCurve $EnergyCurve $AcousticStyle -TokenDurations $TokenLengths -LevelMode Supplied -SuppliedLevels $supplied
    $a = [byte[]]::new(4 * $LiveResult.Features.Length); $b = [byte[]]::new(4 * $replay.Features.Length)
    [Buffer]::BlockCopy($LiveResult.Features, 0, $a, 0, $a.Length); [Buffer]::BlockCopy($replay.Features, 0, $b, 0, $b.Length)
    if (-not [Linq.Enumerable]::SequenceEqual[byte]($a, $b)) { throw 'STOP: exported Live levels did not reproduce Live decoder output bit for bit.' }
    if (@($profile | Where-Object Kind -ceq 'SuppliedAdaIN').Count -ne 10) { throw 'Supplied path did not visit all ten sites.' }
    return $true
}
function Read-OfflineReference([hashtable] $CaptureCase, [string] $Name) {
    $tensor = @($CaptureCase.Tensors | Where-Object Name -CEQ $Name)
    if ($tensor.Count -ne 1 -or $tensor[0].File -cnotmatch '^[A-Za-z0-9_.-]+\.bin$') { throw 'Missing/invalid reference tensor.' }
    $path = Join-Path $InputRepository ('build/score-capture-20261014/' + $tensor[0].File)
    if ((Get-FileHash -LiteralPath $path).Hash -cne $tensor[0].SHA256) { throw 'Reference tensor integrity mismatch.' }
    $raw = [IO.File]::ReadAllBytes($path)
    $values = [float[]]::new($raw.Length / 4)
    if ($tensor[0].DType -ceq 'int32') { $values = [int[]]::new($raw.Length / 4) }
    [Buffer]::BlockCopy($raw, 0, $values, 0, $raw.Length); return , $values
}
function Invoke-OfflineGeneratorBlock([float[]] $InputValues, [int] $Frames, [float[]] $AcousticStyle, [string] $Name) {
    $channels = [int]($InputValues.Length / $Frames); $x = $InputValues
    for ($stage = 0; $stage -lt 3; $stage++) {
        $next = Invoke-OfflineAdaIn $x $channels $Frames $AcousticStyle ($Name + ".adain1.$stage")
        $next = $snake.Invoke($next, (Read-OfflineWeight ('decoder.module.' + $Name + ".alpha1.$stage")), $Frames)
        $conv = Get-OfflineConvolution ($Name + ".convs1.$stage") 1 $false
        $dilation = 1 + 2 * $stage; $padding = [int](($conv.Kernel - 1) * $dilation / 2)
        $next = Invoke-OfflineConv $next $Frames ($Name + ".convs1.$stage") -Dilation $dilation -Padding $padding
        $next = Invoke-OfflineAdaIn $next $channels $Frames $AcousticStyle ($Name + ".adain2.$stage")
        $next = $snake.Invoke($next, (Read-OfflineWeight ('decoder.module.' + $Name + ".alpha2.$stage")), $Frames)
        $conv = Get-OfflineConvolution ($Name + ".convs2.$stage") 1 $false
        $next = Invoke-OfflineConv $next $Frames ($Name + ".convs2.$stage") -Padding ([int](($conv.Kernel - 1) / 2))
        $x = $residual.Invoke($next, $x, [float]1)
    }
    return , $x
}
function Invoke-OfflineGenerator([float[]] $Features, [float[]] $AcousticStyle, [float[]] $PitchCurve, [float[]] $UniformDraw, [float[]] $HarmonicDraw, [float[]] $ExtraDraw) {
    Test-OfflineNode 'gen.input_x' $Features
    $source = $harmonic.Invoke($PitchCurve, $UniformDraw, $HarmonicDraw, $ExtraDraw, (Read-OfflineWeight 'decoder.module.generator.m_source.l_linear.weight'), (Read-OfflineWeight 'decoder.module.generator.m_source.l_linear.bias'))
    Test-OfflineNode 'gen.m_source.out0' $source
    if ($Mode -eq 'Nodes') {
        $extra = $sourceExtra.Invoke($PitchCurve, $ExtraDraw); $noiseOutput = [float[]]::new($source.Length); $voicingOutput = [float[]]::new($source.Length)
        [Array]::Copy($extra, 0, $noiseOutput, 0, $source.Length); [Array]::Copy($extra, $source.Length, $voicingOutput, 0, $source.Length)
        Test-OfflineNode 'gen.m_source.out1' $noiseOutput; Test-OfflineNode 'gen.m_source.out2' $voicingOutput
    }
    $har = $stft.Invoke($source); $harFrames = [int]($har.Length / 22)
    if ($Mode -eq 'Nodes') {
        $spec = [float[]]::new(11 * $harFrames); $phase = [float[]]::new(11 * $harFrames)
        [Array]::Copy($har, 0, $spec, 0, $spec.Length); [Array]::Copy($har, $spec.Length, $phase, 0, $phase.Length)
        Test-OfflineNode 'gen.har_spec' $spec; Test-OfflineNode 'gen.har_phase' $phase
    }
    $x = $Features; $frames = $PitchCurve.Length
    if ($x.Length -ne 512 * $frames) { throw 'Generator feature shape mismatch.' }
    for ($stage = 0; $stage -lt 2; $stage++) {
        $x = $leaky.Invoke($x, [float]0.1)
        $sourceFeatures = $null
        if ($stage -eq 0) { $sourceFeatures = Invoke-OfflineConv $har $harFrames 'generator.noise_convs.0' -Stride 6 -Padding 3 }
        else { $sourceFeatures = Invoke-OfflineConv $har $harFrames 'generator.noise_convs.1' }
        Test-OfflineNode ("gen.noise_convs$stage") $sourceFeatures
        $channels = 256; $nextFrames = [int]($sourceFeatures.Length / 256)
        if ($stage -eq 1) { $channels = 128; $nextFrames = [int]($sourceFeatures.Length / 128) }
        $sourceFeatures = Invoke-OfflineGeneratorBlock $sourceFeatures $nextFrames $AcousticStyle "generator.noise_res.$stage"
        Test-OfflineNode ("gen.noise_res$stage") $sourceFeatures
        $stride = 10; $padding = 5
        if ($stage -eq 1) { $stride = 6; $padding = 3 }
        $x = Invoke-OfflineConv $x $frames "generator.ups.$stage" -Stride $stride -Padding $padding -Transpose
        Test-OfflineNode ("gen.ups$stage") $x
        $frames *= $stride
        if ($stage -eq 1) { $x = $reflectLeft.Invoke($x, $channels, $frames); $frames++ }
        if ($frames -ne $nextFrames) { throw 'Generator excitation alignment mismatch.' }
        $x = $residual.Invoke($x, $sourceFeatures, [float]1)
        $branches = [object[]]::new(3)
        for ($branch = 0; $branch -lt 3; $branch++) {
            $branches[$branch] = Invoke-OfflineGeneratorBlock $x $frames $AcousticStyle ('generator.resblocks.' + (3 * $stage + $branch))
            Test-OfflineNode ('gen.resblocks' + (3 * $stage + $branch)) $branches[$branch]
        }
        $x = $average3.Invoke($branches[0], $branches[1], $branches[2])
    }
    $x = $leaky.Invoke($x, [float]0.01)
    $x = Invoke-OfflineConv $x $frames 'generator.conv_post' -Padding 3
    Test-OfflineNode 'gen.conv_post' $x
    return , $inverseStft.Invoke($x, $frames)
}
function New-OfflineDraws([int] $SampleCount) {
    $flat = $draws.Invoke($Seed, $SampleCount)
    $repeated = $draws.Invoke($Seed, $SampleCount)
    if (-not [Linq.Enumerable]::SequenceEqual[float]($flat, $repeated)) { throw 'Seeded draws are not reproducible.' }
    $uniform = [float[]]::new(9); $gaussian = [float[]]::new(9 * $SampleCount); $extraNoise = [float[]]::new($SampleCount)
    [Array]::Copy($flat, 0, $uniform, 0, 9); [Array]::Copy($flat, 9, $gaussian, 0, $gaussian.Length)
    [Array]::Copy($flat, 9 + $gaussian.Length, $extraNoise, 0, $SampleCount)
    return [pscustomobject]@{ Uniform = $uniform; Harmonic = $gaussian; Extra = $extraNoise }
}
$captures = Import-PowerShellDataFile (Join-Path $InputRepository 'build/score-capture-20261014/capture.psd1')
$gateResults = [Collections.Generic.List[object]]::new()
foreach ($case in $captures.Cases) {
    if ($CaseName -and $case.Name -cne $CaseName) { continue }
    if ($Mode -eq 'Nodes' -and $case.Name -cne 'dog') { continue }
    $durations = Read-OfflineReference $case 'durations'; $textEncoder = Read-OfflineReference $case 'text-encoder'
    $asr = $align.Invoke($textEncoder, $durations); $f0 = Read-OfflineReference $case 'f0'; $noise = Read-OfflineReference $case 'n'; $style = Read-OfflineReference $case 'acoustic'
    $draw0 = Read-OfflineReference $case 'draw0-rand'; $draw1 = Read-OfflineReference $case 'draw1-randn_like'; $draw2 = Read-OfflineReference $case 'draw2-randn_like'; $expectedPcm = Read-OfflineReference $case 'pcm'
    if ($Mode -eq 'Seeded') {
        $seededDraws = New-OfflineDraws ($f0.Length * 300)
        $draw0 = $seededDraws.Uniform; $draw1 = $seededDraws.Harmonic; $draw2 = $seededDraws.Extra
    }
    if ($Mode -eq 'Levels') {
        $profile.Clear(); $live = Invoke-OfflineDecoder $asr $f0 $noise $style -TokenDurations $durations
        $profile.Clear(); $passed = Test-OfflineLevelReplay $live $asr $f0 $noise $style $durations
        $live.Levels | Export-Clixml -LiteralPath (Join-Path $output ($case.Name + '-exported-levels.clixml'))
        [pscustomobject]@{ Case = $case.Name; BitExactReplay = $passed; Sites = $live.Levels.Length } | Export-Clixml -LiteralPath (Join-Path $output ($case.Name + '-level-gate.clixml'))
        Write-Host ('PASS {0}: ten Live/Export sites, Supplied replay bit exact' -f $case.Name)
        continue
    }
    $runCount = $Runs; if ($Mode -eq 'Nodes') { $runCount = 1 }
    for ($run = 1; $run -le $runCount; $run++) {
        $profile.Clear(); $watch = [Diagnostics.Stopwatch]::StartNew()
        $decoded = Invoke-OfflineDecoder $asr $f0 $noise $style -TokenDurations $durations
        $decoderOutput = $decoded.Features; $watch.Stop(); $decoderMs = $watch.Elapsed.TotalMilliseconds
        if ($case.Name -ceq 'dog' -and $run -gt 1 -and $decoderMs -gt 10000) {
            $profile.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'dog-decoder-stop-profile.clixml')
            $profile | Format-Table Stage, Kind, Milliseconds, Frames -AutoSize | Out-Host
            throw 'STOP: warm dog decoder pass exceeded 10 seconds.'
        }
        $watch.Restart(); $pcm = Invoke-OfflineGenerator $decoderOutput $style $f0 $draw0 $draw1 $draw2; $watch.Stop(); $generatorMs = $watch.Elapsed.TotalMilliseconds
        Test-OfflineNode 'pcm' $pcm
        $metrics = $compare.Invoke($pcm, $expectedPcm)
        if ($Mode -eq 'Seeded') {
            $seededBytes = [byte[]]::new(4 * $pcm.Length); [Buffer]::BlockCopy($pcm, 0, $seededBytes, 0, $seededBytes.Length)
            [IO.File]::WriteAllBytes((Join-Path $output ($case.Name + '-seeded-pcm.f32')), $seededBytes)
            [pscustomobject]@{ Case = $case.Name; NoiseMode = 'Seeded'; Seed = $Seed; Samples = $pcm.Length; DecoderMs = $decoderMs; GeneratorMs = $generatorMs }
            continue
        }
        $gateResult = [pscustomobject]@{ Case = $case.Name; Run = $run; Samples = $pcm.Length; SnrDb = $metrics[0]; MaxAbsError = $metrics[1]; DecoderMs = $decoderMs; GeneratorMs = $generatorMs; AssemblySHA256 = $admission.SHA256; SourceSHA256 = $sourceHash; NoiseMode = 'Supplied'; Threads = $Threads }
        $gateResults.Add($gateResult); $gateResults.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'part1-gate.clixml')
        $profile.ToArray() | Export-Clixml -LiteralPath (Join-Path $output ($case.Name + '-run' + $run + '-profile.clixml'))
        Write-Host ('{0} run {1}: {2:F6} dB, max {3:G9}, decoder {4:F3} ms, generator {5:F3} ms' -f $case.Name,$run,$metrics[0],$metrics[1],$decoderMs,$generatorMs)
        if ($metrics[0] -lt 60 -and $Mode -ne 'Nodes') {
            $raw = [byte[]]::new(4 * $pcm.Length); [Buffer]::BlockCopy($pcm, 0, $raw, 0, $raw.Length); [IO.File]::WriteAllBytes((Join-Path $output ($case.Name + '-failed-pcm.f32')), $raw)
            throw 'STOP: supplied-noise PCM gate below 60 dB. Use Nodes to locate the first divergence against the supplied intermediates.'
        }
    }
}
$gateResults.ToArray()
if ($Mode -eq 'Join') { throw 'Join implementation is not yet complete.' }
