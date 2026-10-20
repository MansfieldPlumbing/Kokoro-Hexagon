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
Speech runs our compiled phonemizer and the lowered teacher from Text in process.
CompareConvolution checks every returned teacher boundary against the previous convolution.
Kernels checks short spans, phase tails, output padding and dilation against the previous kernel.
Library compiles and loads the reference, then returns without rendering; dot-source
it (. ./Invoke-KokoroPrecomputedDecoder.ps1 -Mode Library) to call Invoke-OfflineDecoder,
Invoke-OfflineGenerator and the compiled delegates from the caller's scope.
.PARAMETER Threads
Compiled convolution workers, 2 through 64; default 4.
.PARAMETER Runs
Supplied gate renders per case, 1 through 10; default 10. Report run ten as warm.
Speech defaults to one render; an explicit Runs repeats in process with resident weights and kernels.
.PARAMETER CaseName
Optional dog or peach filter for capture diagnostics.
.PARAMETER InputRepository
Read-only main checkout containing the preserved captures, checkpoint and bank.
.PARAMETER OutputDirectory
Outputs below this worktree's build directory. Join defaults to
build/precomputed-decoder-20261014; other modes choose a fresh timestamped child.
Completed results and existing compiled artifacts are never overwritten.
.PARAMETER Seed
Seeded and Join reset this seed for each render, using uniform phase and Gaussian noise.
.PARAMETER Text
Speech mode input for the pinned compiled English phonemizer. One group of at most 510 phonemes.
.PARAMETER Convolution
Direct uses packed AVX2 with the reference FP32 rounding schedule; Reference uses the previous SSE worker.
.PARAMETER CompareConvolution
Render the same phonemes and seeded draws through both methods; require bit equality at every returned boundary.
.PARAMETER ReferenceSpeechDirectory
Compare every boundary with an existing Speech receipt instead of rendering a second teacher pass.
.PARAMETER Dense
Vector uses packed double-precision SIMD for dense layers and independent recurrent direction workers.
Scalar retains the original accumulation loops. Both preserve the same rounding boundaries.
.PARAMETER ConvolutionTileFrames
Maximum time tile in frames. Each phase reduces it to fit the declared active-cache budget.
.PARAMETER SelectedUnits
An existing in-process mine.ps1 result, or its selection.clixml record. Reuses
the recorded paths; the unchanged reference reader supplies donor provenance.
.PARAMETER DonorRecords
The existing donors.clixml objects. Reads their precomputed native features and
moments, validates source chunks, and runs the join/generator stage without
decoding the same donors again. Existing WAVs must reproduce exactly.
.PARAMETER h
Show help without compiling, loading weights or rendering.
.EXAMPLE
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Join'; Seed=17}
.EXAMPLE
& ./Invoke-KokoroDevelopment.ps1 PrecomputedDecoder -Parameters @{Mode='Speech'; Text='Text to render.'; CompareConvolution=$true}
#>

#requires -Version 7.7
using namespace System.Runtime.Intrinsics
using namespace System.Runtime.Intrinsics.X86
[CmdletBinding()]
param(
    [ValidateSet('Admit','Nodes','Levels','Gate','Seeded','Join','Library','Speech','Kernels')][string] $Mode = 'Gate',
    [ValidateRange(2,64)][int] $Threads = 4,
    [ValidateRange(1,10)][int] $Runs = 10,
    [ValidateSet('','dog','peach')][string] $CaseName = '',
    [string] $InputRepository = (Split-Path $PSScriptRoot -Parent),
    [string] $OutputDirectory = '',
    [int] $Seed = 17,
    [string] $Text = '',
    [ValidateSet('af_heart','am_michael')][string] $Voice = 'af_heart',
    [ValidateRange(0.1,10)][double] $Speed = 1,
    [ValidateSet('Direct','Reference')][string] $Convolution = 'Direct',
    [switch] $CompareConvolution,
    [string] $ReferenceSpeechDirectory = '',
    [ValidateSet('Vector','Scalar')][string] $Dense = 'Vector',
    [ValidateRange(8,1024)][int] $ConvolutionTileFrames = 1024,
    [Collections.IDictionary] $SelectedUnits = $null,
    [object[]] $DonorRecords = @(),
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
class OfflineDonor {
    [int] $Sentence
    [string] $Text
    [int[]] $Durations
    [int[]] $Offsets
    [float[]] $TextEncoder
    [float[]] $F0
    [float[]] $N
    [OfflineDecoderResult] $Decoded
    [double] $DecoderMs
}

class OfflineExperimentMath {
    static [int[]] Durations([short[]] $source, [int] $start, [int] $count) {
        $result = [int[]]::new($count)
        for ($i = 0; $i -lt $count; $i++) {
            $value = [int]$source[$start + $i]
            if ($value -le 0) { throw [ArgumentException]::new('Nonpositive bank duration.') }
            $result[$i] = $value
        }
        return $result
    }
    static [int[]] Offsets([int[]] $durations) {
        $result = [int[]]::new($durations.Length + 1)
        for ($i = 0; $i -lt $durations.Length; $i++) { $result[$i + 1] = $result[$i] + $durations[$i] }
        return $result
    }
    static [float[]] EncoderSlice([short[]] $source, [float[]] $scales, [int] $allTokens, [int] $start, [int] $count) {
        if ($source.Length -ne 512 * $allTokens -or $scales.Length -ne 512 -or $start -lt 0 -or $start + $count -gt $allTokens) { throw [ArgumentException]::new('Bank encoder shape mismatch.') }
        $result = [float[]]::new(512 * $count)
        for ($c = 0; $c -lt 512; $c++) {
            for ($i = 0; $i -lt $count; $i++) { $result[$c * $count + $i] = [float]([float]$source[$c * $allTokens + $start + $i] * $scales[$c]) }
        }
        return $result
    }
    static [float[]] HalfSlice([ushort[]] $source, [int] $start, [int] $count) {
        if ($start -lt 0 -or $start + $count -gt $source.Length) { throw [ArgumentException]::new('Bank contour range mismatch.') }
        $result = [float[]]::new($count)
        for ($i = 0; $i -lt $count; $i++) {
            $bits = [int]$source[$start + $i]; $exponent = ($bits -shr 10) -band 31; $mantissa = $bits -band 1023
            $value = [float]0
            if ($exponent -eq 0) { $value = [float]([double]$mantissa * [double]0.000000059604644775390625) }
            elseif ($exponent -lt 31) { $value = [BitConverter]::Int32BitsToSingle((($exponent + 112) -shl 23) -bor ($mantissa -shl 13)) }
            else { throw [ArgumentException]::new('Nonfinite bank contour.') }
            if (($bits -band 32768) -ne 0) { $value = -$value }
            $result[$i] = $value
        }
        return $result
    }
    static [void] CopyFrames([float[]] $source, [int] $sourceFrames, [int] $firstFrame, [int] $count, [float[]] $destination, [int] $destinationFrames, [int] $destinationFirst) {
        if ($source.Length -ne 512 * $sourceFrames -or $destination.Length -ne 512 * $destinationFrames -or $firstFrame -lt 0 -or $firstFrame + $count -gt $sourceFrames -or $destinationFirst -lt 0 -or $destinationFirst + $count -gt $destinationFrames) { throw [ArgumentException]::new('Feature slice range mismatch.') }
        for ($c = 0; $c -lt 512; $c++) { [Array]::Copy($source, $c * $sourceFrames + $firstFrame, $destination, $c * $destinationFrames + $destinationFirst, $count) }
    }
    static [void] AddTokenMoments([double[]] $source, [int] $channels, [int] $tokens, [int] $token, [double[]] $total) {
        if ($source.Length -ne 2 * $channels * ($tokens + 1) -or $total.Length -ne 2 * $channels -or $token -lt 0 -or $token -ge $tokens) { throw [ArgumentException]::new('Token moment shape mismatch.') }
        for ($c = 0; $c -lt $channels; $c++) {
            $total[$c] += $source[2 * $channels + $token * $channels + $c]
            $total[$channels + $c] += $source[2 * $channels + $tokens * $channels + $token * $channels + $c]
        }
    }
    static [double[]] FinishMoments([double[]] $total, [int] $frames) {
        if ($frames -le 0 -or $total.Length % 2 -ne 0) { throw [ArgumentException]::new('Invalid composed moments.') }
        $channels = [int]($total.Length / 2); $result = [double[]]::new($total.Length)
        for ($c = 0; $c -lt $channels; $c++) {
            $mean = $total[$c] / [double]$frames
            $variance = [Math]::Max([double]0, $total[$channels + $c] / [double]$frames - $mean * $mean)
            $result[$c] = [double][float]$mean; $result[$channels + $c] = [double][float]$variance
        }
        return $result
    }
    static [void] AddLiveLevels([double[]] $source, [double[]] $total) {
        if ($source.Length -lt $total.Length) { throw [ArgumentException]::new('Live level shape mismatch.') }
        for ($i = 0; $i -lt $total.Length; $i++) { $total[$i] += $source[$i] }
    }
    static [double[]] AverageLevels([double[]] $total, [int] $count) {
        $result = [double[]]::new($total.Length)
        for ($i = 0; $i -lt $total.Length; $i++) { $result[$i] = [double][float]($total[$i] / [double]$count) }
        return $result
    }
    static [double] Median([double[]] $values) {
        if ($values.Length -eq 0) { return [double]0 }
        $sorted = [double[]]$values.Clone(); [Array]::Sort($sorted)
        $middle = [int][Math]::Floor([double]$sorted.Length / [double]2)
        if ($sorted.Length % 2 -ne 0) { return $sorted[$middle] }
        return ($sorted[$middle - 1] + $sorted[$middle]) / [double]2
    }
    static [double[]] LevelErrors([double[]] $supplied, [double[]] $live, [int] $channels) {
        $means = [double[]]::new($channels); $deviations = [double[]]::new($channels); $maxMean = [double]0; $maxDeviation = [double]0
        for ($c = 0; $c -lt $channels; $c++) {
            $means[$c] = [Math]::Abs($supplied[$c] - $live[$c]) / [Math]::Max([double]0.000000000001, [Math]::Abs($live[$c]))
            $sd = [Math]::Sqrt($live[$channels + $c]); $bankSd = [Math]::Sqrt($supplied[$channels + $c])
            $deviations[$c] = [Math]::Abs($bankSd - $sd) / [Math]::Max([double]0.000000000001, $sd)
            $maxMean = [Math]::Max($maxMean, $means[$c]); $maxDeviation = [Math]::Max($maxDeviation, $deviations[$c])
        }
        return [double[]]@($maxMean, [OfflineExperimentMath]::Median($means), $maxDeviation, [OfflineExperimentMath]::Median($deviations))
    }
    static [float[]] Windows([int[]] $frameOffsets, [int] $extension) {
        if ($extension -le 0 -or $frameOffsets.Length -lt 2) { throw [ArgumentException]::new('Invalid overlap window.') }
        $units = $frameOffsets.Length - 1; $frames = $frameOffsets[$units]; $result = [float[]]::new($units * $frames)
        for ($t = 0; $t -lt $frames; $t++) {
            $leftRamp = [double]1; $accumulated = [float]0
            for ($u = 0; $u -lt $units; $u++) {
                $rightRamp = [double]0
                if ($u + 1 -lt $units) {
                    $position = ([double]$t + [double]0.5 - [double]($frameOffsets[$u + 1] - $extension)) / [double](2 * $extension)
                    if ($position -ge [double]1) { $rightRamp = [double]1 }
                    elseif ($position -gt [double]0) { $sine = [Math]::Sin([double]1.5707963267948966 * $position); $rightRamp = $sine * $sine }
                }
                # A rising sine-squared ramp at each ordered join. Differences telescope,
                # including when a short unit lies inside two overlap windows.
                $weight = [float]($leftRamp - $rightRamp)
                if ($rightRamp -eq [double]0) { $weight = [float]([float]1 - $accumulated) }
                if ($weight -lt [float]0) { throw [ArgumentException]::new('Negative overlap weight.') }
                $result[$u * $frames + $t] = $weight; $accumulated = [float]($accumulated + $weight); $leftRamp = $rightRamp
            }
            if ($accumulated -ne [float]1) { throw [ArgumentException]::new('Overlap weights do not sum exactly to one.') }
        }
        return $result
    }
    static [void] AddWindowedUnit([float[]] $source, [int] $sourceFirst, [int] $targetFirst, [int] $unit, [float[]] $weights, [float[]] $destination, [int] $frames) {
        $sourceFrames = [int]($source.Length / 512)
        if ($destination.Length -ne 512 * $frames -or $weights.Length % $frames -ne 0) { throw [ArgumentException]::new('Overlap shape mismatch.') }
        for ($t = 0; $t -lt $frames; $t++) {
            $weight = $weights[$unit * $frames + $t]
            if ($weight -eq [float]0) { continue }
            $from = $sourceFirst + $t - $targetFirst
            if ($from -lt 0 -or $from -ge $sourceFrames) { throw [ArgumentException]::new('Required donor neighbouring frame is unavailable; no padding invented.') }
            for ($c = 0; $c -lt 512; $c++) {
                $at = $c * $frames + $t
                $destination[$at] = [float]($destination[$at] + [float]($source[$c * $sourceFrames + $from] * $weight))
            }
        }
    }
    static [double[]] JoinMetrics([float[]] $pcm, [int[]] $joins) {
        if ($pcm.Length -lt 480) { throw [ArgumentException]::new('Audio shorter than 20 ms.') }
        $differences = [double[]]::new($pcm.Length - 1)
        for ($i = 0; $i -lt $differences.Length; $i++) { $differences[$i] = [Math]::Abs([double]$pcm[$i + 1] - [double]$pcm[$i]) }
        # Every complete 480-sample window, one-sample hop; 479 differences.
        $windows = [double[]]::new($pcm.Length - 479); $deque = [int[]]::new($differences.Length); $head = 0; $tail = 0
        for ($i = 0; $i -lt $differences.Length; $i++) {
            while ($tail -gt $head -and $differences[$deque[$tail - 1]] -le $differences[$i]) { $tail-- }
            $deque[$tail] = $i; $tail++
            while ($tail -gt $head -and $deque[$head] -lt $i - 478) { $head++ }
            if ($i -ge 478) { $windows[$i - 478] = $differences[$deque[$head]] }
        }
        $baseline = [OfflineExperimentMath]::Median($windows); $ratios = [double[]]::new($joins.Length); $largest = [double]0
        for ($j = 0; $j -lt $joins.Length; $j++) {
            $peak = [double]0; $first = [Math]::Max(0, $joins[$j] - 240); $last = [Math]::Min($differences.Length - 1, $joins[$j] + 239)
            for ($i = $first; $i -le $last; $i++) { $peak = [Math]::Max($peak, $differences[$i]) }
            $ratio = [double]0
            if ($baseline -gt [double]0) { $ratio = $peak / $baseline } elseif ($peak -gt [double]0) { $ratio = [double]::PositiveInfinity }
            $ratios[$j] = $ratio; $largest = [Math]::Max($largest, $ratio)
        }
        return [double[]]@($largest, [OfflineExperimentMath]::Median($ratios), $baseline)
    }
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

class OfflineDirectConvolutionWorker {
    # Stride-1, ungrouped Conv1d: out[oc, t] = bias[oc] + sum over ic, tap of w[oc, ic, tap] * x[ic, t + tap * dilation - padding].
    # Weights are packed once as 8-output-channel AVX2 vectors; the input is a zero-padded copy, so
    # every read is in bounds. Each step loads one weight vector and updates eight time positions.
    [float[]] $Padded
    [System.Runtime.Intrinsics.Vector256[float][]] $Packed
    [float[]] $Bias
    [float[]] $Output
    [int] $InputChannels
    [int] $OutputChannels
    [int] $PaddedFrames
    [int] $OutputFrames
    [int] $WorkFrames
    [int] $OutputStep
    [int] $OutputOffset
    [int] $InputOffset
    [int] $TimeTile
    [int] $Kernel
    [int] $Dilation
    [int] $FirstBlock
    [int] $LastBlock

    [void] Store([System.Runtime.Intrinsics.Vector256[float]] $sum, [int] $block, [int] $frame) {
        if ($frame -ge $this.WorkFrames) { return }
        $destinationFrame = $this.OutputOffset + $frame * $this.OutputStep
        $low = [System.Runtime.Intrinsics.X86.Avx]::ExtractVector128($sum, [byte]0)
        $high = [System.Runtime.Intrinsics.X86.Avx]::ExtractVector128($sum, [byte]1)
        for ($lane = 0; $lane -lt 8; $lane++) {
            $oc = $block * 8 + $lane
            if ($oc -ge $this.OutputChannels) { return }
            $value = [float]0
            if ($lane -lt 4) { $value = [System.Runtime.Intrinsics.X86.Sse41]::Extract($low, [byte]$lane) }
            else { $value = [System.Runtime.Intrinsics.X86.Sse41]::Extract($high, [byte]($lane - 4)) }
            $this.Output[$oc * $this.OutputFrames + $destinationFrame] = [float]($value + $this.Bias[$oc])
        }
    }

    [void] Run() {
      # Two output-channel blocks share each input broadcast (16 accumulators). Each output's
      # summation order (input channel, then tap) is unchanged, so results stay bit-identical.
      $source = $this.Padded; $weights = $this.Packed
      $inputs = $this.InputChannels; $kernelTaps = $this.Kernel; $tapStride = $this.Dilation
      $rowFrames = $this.PaddedFrames; $shift = $this.InputOffset
      for ($tile = 0; $tile -lt $this.WorkFrames; $tile += $this.TimeTile) {
        $tileEnd = [Math]::Min($tile + $this.TimeTile, $this.WorkFrames)
        $pairEnd = $this.LastBlock - ($this.LastBlock - $this.FirstBlock) % 2
        for ($block = $this.FirstBlock; $block -lt $pairEnd; $block += 2) {
            for ($t = $tile; $t -lt $tileEnd; $t += 8) {
                $a0 = [System.Runtime.Intrinsics.Vector256[float]]::Zero; $a1 = $a0; $a2 = $a0; $a3 = $a0; $a4 = $a0; $a5 = $a0; $a6 = $a0; $a7 = $a0
                $b0 = $a0; $b1 = $a0; $b2 = $a0; $b3 = $a0; $b4 = $a0; $b5 = $a0; $b6 = $a0; $b7 = $a0
                for ($ic = 0; $ic -lt $inputs; $ic++) {
                    $row = $ic * $rowFrames + $t + $shift
                    $firstAt = ($block * $inputs + $ic) * $kernelTaps
                    $secondAt = (($block + 1) * $inputs + $ic) * $kernelTaps
                    for ($tap = 0; $tap -lt $kernelTaps; $tap++) {
                        $wa = $weights[$firstAt + $tap]; $wb = $weights[$secondAt + $tap]
                        $at = $row + $tap * $tapStride
                        $x = [System.Runtime.Intrinsics.Vector256]::Create($source[$at])
                        $a0 = [System.Runtime.Intrinsics.X86.Avx]::Add($a0, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wa, $x)); $b0 = [System.Runtime.Intrinsics.X86.Avx]::Add($b0, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wb, $x))
                        $x = [System.Runtime.Intrinsics.Vector256]::Create($source[$at + 1])
                        $a1 = [System.Runtime.Intrinsics.X86.Avx]::Add($a1, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wa, $x)); $b1 = [System.Runtime.Intrinsics.X86.Avx]::Add($b1, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wb, $x))
                        $x = [System.Runtime.Intrinsics.Vector256]::Create($source[$at + 2])
                        $a2 = [System.Runtime.Intrinsics.X86.Avx]::Add($a2, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wa, $x)); $b2 = [System.Runtime.Intrinsics.X86.Avx]::Add($b2, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wb, $x))
                        $x = [System.Runtime.Intrinsics.Vector256]::Create($source[$at + 3])
                        $a3 = [System.Runtime.Intrinsics.X86.Avx]::Add($a3, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wa, $x)); $b3 = [System.Runtime.Intrinsics.X86.Avx]::Add($b3, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wb, $x))
                        $x = [System.Runtime.Intrinsics.Vector256]::Create($source[$at + 4])
                        $a4 = [System.Runtime.Intrinsics.X86.Avx]::Add($a4, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wa, $x)); $b4 = [System.Runtime.Intrinsics.X86.Avx]::Add($b4, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wb, $x))
                        $x = [System.Runtime.Intrinsics.Vector256]::Create($source[$at + 5])
                        $a5 = [System.Runtime.Intrinsics.X86.Avx]::Add($a5, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wa, $x)); $b5 = [System.Runtime.Intrinsics.X86.Avx]::Add($b5, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wb, $x))
                        $x = [System.Runtime.Intrinsics.Vector256]::Create($source[$at + 6])
                        $a6 = [System.Runtime.Intrinsics.X86.Avx]::Add($a6, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wa, $x)); $b6 = [System.Runtime.Intrinsics.X86.Avx]::Add($b6, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wb, $x))
                        $x = [System.Runtime.Intrinsics.Vector256]::Create($source[$at + 7])
                        $a7 = [System.Runtime.Intrinsics.X86.Avx]::Add($a7, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wa, $x)); $b7 = [System.Runtime.Intrinsics.X86.Avx]::Add($b7, [System.Runtime.Intrinsics.X86.Avx]::Multiply($wb, $x))
                    }
                }
                $this.Store($a0, $block, $t); $this.Store($a1, $block, $t + 1); $this.Store($a2, $block, $t + 2); $this.Store($a3, $block, $t + 3)
                $this.Store($a4, $block, $t + 4); $this.Store($a5, $block, $t + 5); $this.Store($a6, $block, $t + 6); $this.Store($a7, $block, $t + 7)
                $this.Store($b0, $block + 1, $t); $this.Store($b1, $block + 1, $t + 1); $this.Store($b2, $block + 1, $t + 2); $this.Store($b3, $block + 1, $t + 3)
                $this.Store($b4, $block + 1, $t + 4); $this.Store($b5, $block + 1, $t + 5); $this.Store($b6, $block + 1, $t + 6); $this.Store($b7, $block + 1, $t + 7)
            }
        }
        for ($block = $pairEnd; $block -lt $this.LastBlock; $block++) {
            for ($t = $tile; $t -lt $tileEnd; $t += 8) {
                $s0 = [System.Runtime.Intrinsics.Vector256[float]]::Zero; $s1 = $s0; $s2 = $s0; $s3 = $s0
                $s4 = $s0; $s5 = $s0; $s6 = $s0; $s7 = $s0
                for ($ic = 0; $ic -lt $this.InputChannels; $ic++) {
                    $row = $ic * $this.PaddedFrames + $t + $this.InputOffset
                    $packedAt = ($block * $this.InputChannels + $ic) * $this.Kernel
                    for ($tap = 0; $tap -lt $this.Kernel; $tap++) {
                        $w = $this.Packed[$packedAt + $tap]
                        $at = $row + $tap * $this.Dilation
                        $s0 = [System.Runtime.Intrinsics.X86.Avx]::Add($s0, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create($this.Padded[$at])))
                        $s1 = [System.Runtime.Intrinsics.X86.Avx]::Add($s1, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create($this.Padded[$at + 1])))
                        $s2 = [System.Runtime.Intrinsics.X86.Avx]::Add($s2, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create($this.Padded[$at + 2])))
                        $s3 = [System.Runtime.Intrinsics.X86.Avx]::Add($s3, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create($this.Padded[$at + 3])))
                        $s4 = [System.Runtime.Intrinsics.X86.Avx]::Add($s4, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create($this.Padded[$at + 4])))
                        $s5 = [System.Runtime.Intrinsics.X86.Avx]::Add($s5, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create($this.Padded[$at + 5])))
                        $s6 = [System.Runtime.Intrinsics.X86.Avx]::Add($s6, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create($this.Padded[$at + 6])))
                        $s7 = [System.Runtime.Intrinsics.X86.Avx]::Add($s7, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create($this.Padded[$at + 7])))
                    }
                }
                $this.Store($s0, $block, $t); $this.Store($s1, $block, $t + 1); $this.Store($s2, $block, $t + 2); $this.Store($s3, $block, $t + 3)
                $this.Store($s4, $block, $t + 4); $this.Store($s5, $block, $t + 5); $this.Store($s6, $block, $t + 6); $this.Store($s7, $block, $t + 7)
            }
        }
      }
    }

    static [System.Runtime.Intrinsics.Vector256[float][]] PackWeights([float[]] $weights, [int] $outputs, [int] $inputs, [int] $tapCount, [bool] $transpose, [int] $tapStep, [int] $firstTap) {
        if ($weights.Length -ne $outputs * $inputs * $tapCount) { throw [ArgumentException]::new('Packed weight shape mismatch.') }
        if ($tapStep -lt 1 -or $firstTap -lt 0) { throw [ArgumentException]::new('Invalid convolution phase.') }
        $selectedTaps = 0
        if ($firstTap -lt $tapCount) { $selectedTaps = [int](($tapCount - 1 - $firstTap - ($tapCount - 1 - $firstTap) % $tapStep) / $tapStep) + 1 }
        $blocks = [int](($outputs + 7 - ($outputs + 7) % 8) / 8)
        $vectors = [System.Runtime.Intrinsics.Vector256[float][]]::new($blocks * $inputs * $selectedTaps)
        $lanes = [float[]]::new(8)
        for ($block = 0; $block -lt $blocks; $block++) {
            for ($ic = 0; $ic -lt $inputs; $ic++) {
                for ($tap = 0; $tap -lt $selectedTaps; $tap++) {
                    for ($lane = 0; $lane -lt 8; $lane++) {
                        $oc = $block * 8 + $lane; $lanes[$lane] = [float]0
                        if ($oc -lt $outputs) {
                            $weightAt = ($oc * $inputs + $ic) * $tapCount + $firstTap + $tap * $tapStep
                            if ($transpose) { $weightAt = ($ic * $outputs + $oc) * $tapCount + $firstTap + $tap * $tapStep }
                            $lanes[$lane] = $weights[$weightAt]
                        }
                    }
                    $vectors[($block * $inputs + $ic) * $selectedTaps + $tap] = [System.Runtime.Intrinsics.Vector256]::Create($lanes[0], $lanes[1], $lanes[2], $lanes[3], $lanes[4], $lanes[5], $lanes[6], $lanes[7])
                }
            }
        }
        return $vectors
    }

    static [float[]] PadInput([float[]] $values, [int] $channels, [int] $frames, [int] $padding, [int] $copyFrames) {
        if ($values.Length -ne $channels * $frames -or $copyFrames -lt $frames + 2 * $padding) { throw [ArgumentException]::new('Padded input shape mismatch.') }
        $copy = [float[]]::new($channels * $copyFrames)
        for ($c = 0; $c -lt $channels; $c++) { [Array]::Copy($values, $c * $frames, $copy, $c * $copyFrames + $padding, $frames) }
        return $copy
    }
}

class OfflineDenseWorker {
    [float[]] $Input
    [System.Runtime.Intrinsics.Vector256[double][]] $Packed
    [System.Runtime.Intrinsics.Vector256[double][]] $Bias
    [float[]] $Output
    [int] $Rows
    [int] $InputChannels
    [int] $OutputChannels
    [int] $FirstBlock
    [int] $LastBlock

    [void] Store([System.Runtime.Intrinsics.Vector256[double]] $sum, [int] $block, [int] $row) {
        if ($row -ge $this.Rows) { return }
        $at = $row * $this.OutputChannels + $block * 4
        $low = [System.Runtime.Intrinsics.X86.Sse2]::ConvertToVector128Single([System.Runtime.Intrinsics.X86.Avx]::ExtractVector128($sum, [byte]0))
        $high = [System.Runtime.Intrinsics.X86.Sse2]::ConvertToVector128Single([System.Runtime.Intrinsics.X86.Avx]::ExtractVector128($sum, [byte]1))
        $this.Output[$at] = [System.Runtime.Intrinsics.X86.Sse41]::Extract($low, [byte]0)
        if ($block * 4 + 1 -lt $this.OutputChannels) { $this.Output[$at + 1] = [System.Runtime.Intrinsics.X86.Sse41]::Extract($low, [byte]1) }
        if ($block * 4 + 2 -lt $this.OutputChannels) { $this.Output[$at + 2] = [System.Runtime.Intrinsics.X86.Sse41]::Extract($high, [byte]0) }
        if ($block * 4 + 3 -lt $this.OutputChannels) { $this.Output[$at + 3] = [System.Runtime.Intrinsics.X86.Sse41]::Extract($high, [byte]1) }
    }

    [void] Run() {
        for ($block = $this.FirstBlock; $block -lt $this.LastBlock; $block++) {
            for ($r = 0; $r -lt $this.Rows; $r += 4) {
                $s0 = $this.Bias[$block]; $s1 = $s0; $s2 = $s0; $s3 = $s0
                $xAt = $r * $this.InputChannels; $wAt = $block * $this.InputChannels
                for ($i = 0; $i -lt $this.InputChannels; $i++) {
                    $w = $this.Packed[$wAt + $i]
                    $s0 = [System.Runtime.Intrinsics.X86.Avx]::Add($s0, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create([double]$this.Input[$xAt + $i])))
                    $s1 = [System.Runtime.Intrinsics.X86.Avx]::Add($s1, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create([double]$this.Input[$xAt + $this.InputChannels + $i])))
                    $s2 = [System.Runtime.Intrinsics.X86.Avx]::Add($s2, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create([double]$this.Input[$xAt + 2 * $this.InputChannels + $i])))
                    $s3 = [System.Runtime.Intrinsics.X86.Avx]::Add($s3, [System.Runtime.Intrinsics.X86.Avx]::Multiply($w, [System.Runtime.Intrinsics.Vector256]::Create([double]$this.Input[$xAt + 3 * $this.InputChannels + $i])))
                }
                $this.Store($s0, $block, $r); $this.Store($s1, $block, $r + 1); $this.Store($s2, $block, $r + 2); $this.Store($s3, $block, $r + 3)
            }
        }
    }

    static [System.Runtime.Intrinsics.Vector256[double][]] Pack([float[]] $weights, [int] $outputs, [int] $inputs) {
        if ($outputs -lt 1 -or $inputs -lt 1 -or $weights.Length -ne $outputs * $inputs) { throw [ArgumentException]::new('Dense weight shape mismatch.') }
        $blocks = [int](($outputs + 3 - ($outputs + 3) % 4) / 4)
        $vectors = [System.Runtime.Intrinsics.Vector256[double][]]::new($blocks * $inputs)
        $lanes = [double[]]::new(4)
        for ($block = 0; $block -lt $blocks; $block++) {
            for ($i = 0; $i -lt $inputs; $i++) {
                for ($lane = 0; $lane -lt 4; $lane++) {
                    $o = $block * 4 + $lane; $lanes[$lane] = [double]0
                    if ($o -lt $outputs) { $lanes[$lane] = [double]$weights[$o * $inputs + $i] }
                }
                $vectors[$block * $inputs + $i] = [System.Runtime.Intrinsics.Vector256]::Create($lanes[0], $lanes[1], $lanes[2], $lanes[3])
            }
        }
        return $vectors
    }
}

class OfflineLstmWorker {
    [float[]] $Values
    [float[]] $InputWeights
    [float[]] $HiddenWeights
    [float[]] $InputBias
    [float[]] $HiddenBias
    [float[]] $Output
    [int] $Rows
    [int] $Inputs
    [int] $Hidden
    [int] $FirstDirection
    [int] $LastDirection
    # Phase 0 computes every step's input projection for gates [FirstGate, LastGate) of one
    # direction; phase 1 runs that direction's recurrence. Both add in the same order as
    # OfflineUpstreamMath.Lstm (biases, then inputs, then hidden state) in double precision.
    [double[]] $Projection
    [int] $Phase
    [int] $FirstGate
    [int] $LastGate
    [void] Run() {
        if ($this.Phase -eq 0) { [OfflineUpstreamMath]::LstmProjection($this.Values, $this.Rows, $this.Inputs, $this.Hidden, $this.InputWeights, $this.InputBias, $this.HiddenBias, $this.Projection, $this.FirstDirection, $this.FirstGate, $this.LastGate); return }
        if ($this.Phase -eq 1) { [OfflineUpstreamMath]::LstmRecurrence($this.Projection, $this.Rows, $this.Hidden, $this.HiddenWeights, $this.Output, $this.FirstDirection); return }
        $completed = [OfflineUpstreamMath]::Lstm($this.Values, $this.Rows, $this.Inputs, $this.Hidden, $this.InputWeights, $this.HiddenWeights, $this.InputBias, $this.HiddenBias, $this.Output, $this.FirstDirection, $this.LastDirection)
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

# Stock KModel upstream of the decoder: transformers AlbertModel (PL-BERT), bert_encoder,
# the prosody predictor's LSTMs and AdaLayerNorm, and duration rounding (kokoro/model.py,
# kokoro/modules.py). Arrays are time-major [rows x columns] unless a name says channels.
class OfflineUpstreamMath {
    static [float[]] Linear([float[]] $x, [int] $rows, [int] $inputs, [float[]] $weight, [float[]] $bias, [int] $outputs) {
        if ($x.Length -ne $rows * $inputs -or $weight.Length -ne $outputs * $inputs -or $bias.Length -ne $outputs) { throw [ArgumentException]::new('Linear shape mismatch.') }
        $y = [float[]]::new($rows * $outputs)
        for ($r = 0; $r -lt $rows; $r++) {
            $xAt = $r * $inputs
            for ($o = 0; $o -lt $outputs; $o++) {
                $wAt = $o * $inputs; $sum = [double]$bias[$o]
                for ($i = 0; $i -lt $inputs; $i++) { $sum += [double]$x[$xAt + $i] * [double]$weight[$wAt + $i] }
                $y[$r * $outputs + $o] = [float]$sum
            }
        }
        return $y
    }
    static [float[]] LayerNorm([float[]] $x, [int] $rows, [int] $columns, [float[]] $gamma, [float[]] $beta, [double] $epsilon) {
        if ($x.Length -ne $rows * $columns -or $gamma.Length -ne $columns -or $beta.Length -ne $columns) { throw [ArgumentException]::new('LayerNorm shape mismatch.') }
        $y = [float[]]::new($x.Length)
        for ($r = 0; $r -lt $rows; $r++) {
            $at = $r * $columns; $mean = [double]0; $variance = [double]0
            for ($c = 0; $c -lt $columns; $c++) { $mean += [double]$x[$at + $c] }
            $mean = $mean / [double]$columns
            for ($c = 0; $c -lt $columns; $c++) { $delta = [double]$x[$at + $c] - $mean; $variance += $delta * $delta }
            $inverse = [double]1 / [Math]::Sqrt($variance / [double]$columns + $epsilon)
            for ($c = 0; $c -lt $columns; $c++) { $y[$at + $c] = [float](([double]$x[$at + $c] - $mean) * $inverse * [double]$gamma[$c] + [double]$beta[$c]) }
        }
        return $y
    }
    static [float[]] AdaLayerNorm([float[]] $x, [int] $rows, [int] $columns, [float[]] $affine, [double] $epsilon) {
        # AdaLayerNorm: layer_norm without affine, then (1 + gamma) * x + beta, gamma and beta from fc(style).
        if ($x.Length -ne $rows * $columns -or $affine.Length -ne 2 * $columns) { throw [ArgumentException]::new('AdaLayerNorm shape mismatch.') }
        $y = [float[]]::new($x.Length)
        for ($r = 0; $r -lt $rows; $r++) {
            $at = $r * $columns; $mean = [double]0; $variance = [double]0
            for ($c = 0; $c -lt $columns; $c++) { $mean += [double]$x[$at + $c] }
            $mean = $mean / [double]$columns
            for ($c = 0; $c -lt $columns; $c++) { $delta = [double]$x[$at + $c] - $mean; $variance += $delta * $delta }
            $inverse = [double]1 / [Math]::Sqrt($variance / [double]$columns + $epsilon)
            for ($c = 0; $c -lt $columns; $c++) {
                $normal = ([double]$x[$at + $c] - $mean) * $inverse
                $y[$at + $c] = [float](([double]1 + [double]$affine[$c]) * $normal + [double]$affine[$columns + $c])
            }
        }
        return $y
    }
    static [float[]] Add([float[]] $a, [float[]] $b) {
        if ($a.Length -ne $b.Length) { throw [ArgumentException]::new('Add shape mismatch.') }
        $y = [float[]]::new($a.Length)
        for ($i = 0; $i -lt $a.Length; $i++) { $y[$i] = [float]([double]$a[$i] + [double]$b[$i]) }
        return $y
    }
    static [float[]] GeluNew([float[]] $x) {
        # transformers gelu_new: 0.5 x (1 + tanh(sqrt(2 / pi) (x + 0.044715 x^3)))
        $y = [float[]]::new($x.Length); $scale = [Math]::Sqrt([double]2 / [Math]::PI)
        for ($i = 0; $i -lt $x.Length; $i++) {
            $v = [double]$x[$i]
            $y[$i] = [float]([double]0.5 * $v * ([double]1 + [Math]::Tanh($scale * ($v + [double]0.044715 * $v * $v * $v))))
        }
        return $y
    }
    static [float[]] AlbertEmbeddings([int[]] $ids, [float[]] $words, [float[]] $positions, [float[]] $types, [int] $width) {
        # word + position (0..rows-1) + token type 0; LayerNorm is applied by the caller.
        $rows = $ids.Length
        if ($rows * $width -gt $positions.Length -or $types.Length -lt $width) { throw [ArgumentException]::new('Embedding extent exceeded.') }
        $y = [float[]]::new($rows * $width)
        for ($t = 0; $t -lt $rows; $t++) {
            if ($ids[$t] -lt 0 -or ($ids[$t] + 1) * $width -gt $words.Length) { throw [ArgumentException]::new('Token outside vocabulary.') }
            for ($c = 0; $c -lt $width; $c++) {
                $y[$t * $width + $c] = [float]([double]$words[$ids[$t] * $width + $c] + [double]$positions[$t * $width + $c] + [double]$types[$c])
            }
        }
        return $y
    }
    static [float[]] SelfAttention([float[]] $query, [float[]] $key, [float[]] $value, [int] $rows, [int] $heads, [int] $width) {
        # Unmasked scaled dot-product attention per head (a single unpadded utterance).
        $headWidth = [int]($width / $heads)
        if ($query.Length -ne $rows * $width -or $key.Length -ne $query.Length -or $value.Length -ne $query.Length -or $headWidth * $heads -ne $width) { throw [ArgumentException]::new('Attention shape mismatch.') }
        $context = [float[]]::new($rows * $width); $scores = [double[]]::new($rows)
        $scale = [double]1 / [Math]::Sqrt([double]$headWidth)
        for ($h = 0; $h -lt $heads; $h++) {
            $offset = $h * $headWidth
            for ($i = 0; $i -lt $rows; $i++) {
                $maximum = [double]::NegativeInfinity
                for ($j = 0; $j -lt $rows; $j++) {
                    $dot = [double]0
                    for ($d = 0; $d -lt $headWidth; $d++) { $dot += [double]$query[$i * $width + $offset + $d] * [double]$key[$j * $width + $offset + $d] }
                    $scores[$j] = $dot * $scale
                    if ($scores[$j] -gt $maximum) { $maximum = $scores[$j] }
                }
                $total = [double]0
                for ($j = 0; $j -lt $rows; $j++) { $scores[$j] = [Math]::Exp($scores[$j] - $maximum); $total += $scores[$j] }
                for ($d = 0; $d -lt $headWidth; $d++) {
                    $sum = [double]0
                    for ($j = 0; $j -lt $rows; $j++) { $sum += $scores[$j] * [double]$value[$j * $width + $offset + $d] }
                    $context[$i * $width + $offset + $d] = [float]($sum / $total)
                }
            }
        }
        return $context
    }
    static [float[]] Lstm([float[]] $x, [int] $rows, [int] $inputs, [int] $hidden, [float[]] $inputWeights, [float[]] $hiddenWeights, [float[]] $inputBias, [float[]] $hiddenBias, [float[]] $y, [int] $firstDirection, [int] $lastDirection) {
        # Bidirectional single-layer nn.LSTM, gate order i, f, g, o. Weights hold the forward
        # direction followed by the reverse direction. Output [rows x 2 hidden], forward first.
        $gates = 4 * $hidden
        if ($x.Length -ne $rows * $inputs -or $inputWeights.Length -ne 2 * $gates * $inputs -or $hiddenWeights.Length -ne 2 * $gates * $hidden -or
            $inputBias.Length -ne 2 * $gates -or $hiddenBias.Length -ne 2 * $gates -or $y.Length -ne $rows * 2 * $hidden -or
            $firstDirection -lt 0 -or $lastDirection -gt 2 -or $firstDirection -ge $lastDirection) { throw [ArgumentException]::new('LSTM shape mismatch.') }
        $state = [double[]]::new($hidden); $cell = [double[]]::new($hidden); $pre = [double[]]::new($gates)
        for ($direction = $firstDirection; $direction -lt $lastDirection; $direction++) {
            for ($j = 0; $j -lt $hidden; $j++) { $state[$j] = [double]0; $cell[$j] = [double]0 }
            for ($step = 0; $step -lt $rows; $step++) {
                $t = $step
                if ($direction -eq 1) { $t = $rows - 1 - $step }
                for ($g = 0; $g -lt $gates; $g++) {
                    $row = $direction * $gates + $g
                    $sum = [double]$inputBias[$row] + [double]$hiddenBias[$row]
                    $wAt = $row * $inputs; $xAt = $t * $inputs
                    for ($i = 0; $i -lt $inputs; $i++) { $sum += [double]$inputWeights[$wAt + $i] * [double]$x[$xAt + $i] }
                    $hAt = $row * $hidden
                    for ($i = 0; $i -lt $hidden; $i++) { $sum += [double]$hiddenWeights[$hAt + $i] * $state[$i] }
                    $pre[$g] = $sum
                }
                for ($j = 0; $j -lt $hidden; $j++) {
                    $inputGate = [double]1 / ([double]1 + [Math]::Exp(-$pre[$j]))
                    $forgetGate = [double]1 / ([double]1 + [Math]::Exp(-$pre[$hidden + $j]))
                    $candidate = [Math]::Tanh($pre[2 * $hidden + $j])
                    $outputGate = [double]1 / ([double]1 + [Math]::Exp(-$pre[3 * $hidden + $j]))
                    $cell[$j] = $forgetGate * $cell[$j] + $inputGate * $candidate
                    $state[$j] = $outputGate * [Math]::Tanh($cell[$j])
                    $y[$t * 2 * $hidden + $direction * $hidden + $j] = [float]$state[$j]
                }
            }
        }
        return $y
    }
    static [void] LstmProjection([float[]] $x, [int] $rows, [int] $inputs, [int] $hidden, [float[]] $inputWeights, [float[]] $inputBias, [float[]] $hiddenBias, [double[]] $projection, [int] $direction, [int] $firstGate, [int] $lastGate) {
        $gates = 4 * $hidden
        if ($projection.Length -ne 2 * $rows * $gates -or $firstGate -lt 0 -or $lastGate -gt $gates) { throw [ArgumentException]::new('LSTM projection shape mismatch.') }
        for ($t = 0; $t -lt $rows; $t++) {
            $xAt = $t * $inputs; $outAt = ($direction * $rows + $t) * $gates
            for ($g = $firstGate; $g -lt $lastGate; $g++) {
                $row = $direction * $gates + $g
                $sum = [double]$inputBias[$row] + [double]$hiddenBias[$row]
                $wAt = $row * $inputs
                for ($i = 0; $i -lt $inputs; $i++) { $sum += [double]$inputWeights[$wAt + $i] * [double]$x[$xAt + $i] }
                $projection[$outAt + $g] = $sum
            }
        }
    }
    static [void] LstmRecurrence([double[]] $projection, [int] $rows, [int] $hidden, [float[]] $hiddenWeights, [float[]] $y, [int] $direction) {
        $gates = 4 * $hidden
        $state = [double[]]::new($hidden); $cell = [double[]]::new($hidden); $pre = [double[]]::new($gates)
        for ($step = 0; $step -lt $rows; $step++) {
            $t = $step
            if ($direction -eq 1) { $t = $rows - 1 - $step }
            $inAt = ($direction * $rows + $t) * $gates
            for ($g = 0; $g -lt $gates; $g++) {
                $sum = $projection[$inAt + $g]
                $hAt = ($direction * $gates + $g) * $hidden
                for ($i = 0; $i -lt $hidden; $i++) { $sum += [double]$hiddenWeights[$hAt + $i] * $state[$i] }
                $pre[$g] = $sum
            }
            for ($j = 0; $j -lt $hidden; $j++) {
                $inputGate = [double]1 / ([double]1 + [Math]::Exp(-$pre[$j]))
                $forgetGate = [double]1 / ([double]1 + [Math]::Exp(-$pre[$hidden + $j]))
                $candidate = [Math]::Tanh($pre[2 * $hidden + $j])
                $outputGate = [double]1 / ([double]1 + [Math]::Exp(-$pre[3 * $hidden + $j]))
                $cell[$j] = $forgetGate * $cell[$j] + $inputGate * $candidate
                $state[$j] = $outputGate * [Math]::Tanh($cell[$j])
                $y[$t * 2 * $hidden + $direction * $hidden + $j] = [float]$state[$j]
            }
        }
    }
    static [float[]] AppendStyle([float[]] $x, [int] $rows, [int] $columns, [float[]] $style) {
        $width = $columns + $style.Length
        if ($x.Length -ne $rows * $columns) { throw [ArgumentException]::new('Style append shape mismatch.') }
        $y = [float[]]::new($rows * $width)
        for ($r = 0; $r -lt $rows; $r++) {
            for ($c = 0; $c -lt $columns; $c++) { $y[$r * $width + $c] = $x[$r * $columns + $c] }
            for ($c = 0; $c -lt $style.Length; $c++) { $y[$r * $width + $columns + $c] = $style[$c] }
        }
        return $y
    }
    static [int[]] Durations([float[]] $logits, [int] $rows, [int] $bins, [double] $speed) {
        # sigmoid(logits).sum(-1) / speed, rounded half to even (torch.round), clamped to at least 1.
        if ($logits.Length -ne $rows * $bins -or $speed -le [double]0) { throw [ArgumentException]::new('Duration shape mismatch.') }
        $durations = [int[]]::new($rows)
        for ($r = 0; $r -lt $rows; $r++) {
            $sum = [float]0
            for ($b = 0; $b -lt $bins; $b++) { $sum += [float]([double]1 / ([double]1 + [Math]::Exp(-[double]$logits[$r * $bins + $b]))) }
            $rounded = [Math]::Round([double]$sum / $speed)
            if ($rounded -lt [double]1) { $rounded = [double]1 }
            $durations[$r] = [int]$rounded
        }
        return $durations
    }
    static [float[]] ExpandChannels([float[]] $x, [int] $rows, [int] $columns, [int[]] $durations) {
        # Time-major token rows to channel-major frames: x^T @ alignment.
        if ($x.Length -ne $rows * $columns -or $durations.Length -ne $rows) { throw [ArgumentException]::new('Expansion shape mismatch.') }
        $frames = 0
        for ($r = 0; $r -lt $rows; $r++) { $frames += $durations[$r] }
        $y = [float[]]::new($columns * $frames); $at = 0
        for ($r = 0; $r -lt $rows; $r++) {
            for ($k = 0; $k -lt $durations[$r]; $k++) {
                for ($c = 0; $c -lt $columns; $c++) { $y[$c * $frames + $at] = $x[$r * $columns + $c] }
                $at++
            }
        }
        return $y
    }
    static [float[]] ChannelsToRows([float[]] $x, [int] $channels, [int] $frames) {
        if ($x.Length -ne $channels * $frames) { throw [ArgumentException]::new('Transpose shape mismatch.') }
        $y = [float[]]::new($x.Length)
        for ($c = 0; $c -lt $channels; $c++) { for ($f = 0; $f -lt $frames; $f++) { $y[$f * $channels + $c] = $x[$c * $frames + $f] } }
        return $y
    }
    static [float[]] RowsToChannels([float[]] $x, [int] $frames, [int] $channels) {
        if ($x.Length -ne $channels * $frames) { throw [ArgumentException]::new('Transpose shape mismatch.') }
        $y = [float[]]::new($x.Length)
        for ($f = 0; $f -lt $frames; $f++) { for ($c = 0; $c -lt $channels; $c++) { $y[$c * $frames + $f] = $x[$f * $channels + $c] } }
        return $y
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($h) { Get-Help $PSCommandPath -Detailed; return }
if ($Mode -eq 'Speech' -and [string]::IsNullOrWhiteSpace($Text)) { throw 'Speech requires Text.' }
if ($CompareConvolution -and $Mode -ne 'Speech') { throw 'CompareConvolution requires Speech mode.' }
if ($ReferenceSpeechDirectory -and $Mode -ne 'Speech') { throw 'ReferenceSpeechDirectory requires Speech mode.' }
if ($CompareConvolution -and $ReferenceSpeechDirectory) { throw 'Choose a fresh convolution comparison or a recorded speech reference.' }
if ($CaseName) { $CaseName = $CaseName.ToLowerInvariant() }
if ($Mode -eq 'Nodes' -and $CaseName -eq 'peach') { throw 'The supplied intermediate-node reference covers dog only.' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $root 'build/precomputed-decoder-20261014'
    if ($Mode -ne 'Join') { $OutputDirectory = Join-Path $OutputDirectory ($Mode + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')) }
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith((Join-Path $root 'build') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be in this worktree build/.' }
[void][IO.Directory]::CreateDirectory($output)
$finishedOutputs = switch ($Mode) {
    'Gate' { 'part1-gate.clixml' }
    'Nodes' { 'nodes.clixml' }
    'Levels' { 'dog-level-gate.clixml'; 'peach-level-gate.clixml' }
    'Seeded' { 'dog-seeded-pcm.f32'; 'peach-seeded-pcm.f32' }
    'Join' { 'store-size.clixml' }
    'Speech' { 'speech.clixml'; 'speech.wav' }
}
foreach ($finishedOutput in $finishedOutputs) {
    if ([IO.File]::Exists((Join-Path $output $finishedOutput))) { throw 'Existing completed result is immutable; choose a fresh output directory.' }
}
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
if ([IO.File]::Exists($dll)) { throw 'Existing compiled artifact is immutable; choose a fresh output directory.' }
$compiled = Export-LoweredAssembly -SourcePath $PSCommandPath -ClassName OfflineConvolutionWorker -OutputPath $dll -Deterministic
$admission = Test-LoweredAssembly -AssemblyPath $dll
if (-not $admission.ClrOnlyAdmitted) { throw 'Offline numeric kernels reference SMA.' }
$assembly = [Reflection.Assembly]::LoadFrom($dll)
$workerType = $assembly.GetType('OfflineConvolutionWorker', $true)
$mathType = $assembly.GetType('OfflineRenderMath', $true)
$upstreamMath = $assembly.GetType('OfflineUpstreamMath', $true)
$directConvolution = $assembly.GetType('OfflineDirectConvolutionWorker', $true)
$denseWorker = $assembly.GetType('OfflineDenseWorker', $true)
$lstmWorker = $assembly.GetType('OfflineLstmWorker', $true)
if (-not [System.Runtime.Intrinsics.X86.Avx2]::IsSupported) { throw 'The direct convolution kernel needs AVX2.' }
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
$denseCache = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$lstmCache = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
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
function Get-OfflineConvolution([string] $Name, [int] $Groups, [bool] $Transpose, [string] $Module = 'decoder.module.') {
    $prefix = $Module + $Name
    if ($convolutionCache.ContainsKey($prefix)) { return $convolutionCache[$prefix] }
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
    $result = [pscustomobject]@{ Weights = $weight; Bias = $bias; InputChannels = $cin; OutputChannels = $cout; Kernel = $shape[2]; Packed = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal) }
    $convolutionCache.Add($prefix, $result); $result
}
function Invoke-OfflineConv {
    param([float[]] $InputValues, [int] $Frames, [string] $Name, [int] $Stride = 1, [int] $Padding = 0, [int] $Dilation = 1, [int] $Groups = 1, [switch] $Transpose, [int] $OutputPadding = 0,
        [string] $Module = 'decoder.module.')
    $conv = Get-OfflineConvolution $Name $Groups $Transpose.IsPresent $Module
    if ($InputValues.Length -ne $conv.InputChannels * $Frames) { throw "Convolution input shape: $Name" }
    $outFrames = [int][Math]::Floor(($Frames + 2 * $Padding - $Dilation * ($conv.Kernel - 1) - 1) / [double]$Stride) + 1
    if ($Transpose) { $outFrames = ($Frames - 1) * $Stride - 2 * $Padding + $Dilation * ($conv.Kernel - 1) + $OutputPadding + 1 }
    $result = [float[]]::new($conv.OutputChannels * $outFrames)
    if ($Convolution -eq 'Direct' -and $Groups -eq 1 -and (($Stride -eq 1 -and -not $Transpose) -or ($Transpose -and $Dilation -eq 1))) {
        # One packed kernel handles ordinary convolution and each transposed phase.
        # A phase visits ascending original taps and consecutive input frames; there are no inserted zeros.
        $phaseCount = 1; $inputPadding = $Padding
        if ($Transpose) { $phaseCount = $Stride; $inputPadding = [int][Math]::Ceiling(($conv.Kernel + $Padding) / [double]$Stride) }
        $packingKey = '{0}:{1}:{2}:{3}' -f $Transpose.IsPresent, $Stride, $Padding, $Dilation
        if (-not $conv.Packed.ContainsKey($packingKey)) {
            $conv.Packed[$packingKey] = @(for ($phase = 0; $phase -lt $phaseCount; $phase++) {
                $firstTap = 0; $tapStep = 1; $inputOffset = 0; $tapDirection = $Dilation
                if ($Transpose) {
                    $firstTap = ($phase + $Padding) % $Stride; $tapStep = $Stride
                    $inputOffset = $inputPadding + [int](($phase + $Padding - $firstTap) / $Stride); $tapDirection = -1
                }
                $packed = $directConvolution::PackWeights($conv.Weights, $conv.OutputChannels, $conv.InputChannels, $conv.Kernel, $Transpose.IsPresent, $tapStep, $firstTap)
                [pscustomobject]@{ Weights = $packed; Taps = [int]($packed.Length / ([Math]::Ceiling($conv.OutputChannels / 8.0) * $conv.InputChannels)); InputOffset = $inputOffset; Dilation = $tapDirection }
            })
        }
        $paddedFrames = $Frames + 2 * $inputPadding + 7
        $padded = $directConvolution::PadInput($InputValues, $conv.InputChannels, $Frames, $inputPadding, $paddedFrames)
        $blocks = [int][Math]::Ceiling($conv.OutputChannels / 8.0); $workerCount = [Math]::Min($Threads, $blocks)
        $running = [Collections.Generic.List[Threading.Tasks.Task]]::new(); $keepWorkers = [Collections.Generic.List[object]]::new()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        for ($phase = 0; $phase -lt $phaseCount; $phase++) {
          $phaseFrames = [int][Math]::Floor(($outFrames - 1 - $phase) / [double]$phaseCount) + 1
          if ($phaseFrames -le 0) { continue }
          $phaseWeights = $conv.Packed[$packingKey][$phase]
          # Bound the active input tile, output block and weights to 1 MiB,
          # leaving room within the target CPU's 1.25 MiB per-core L2.
          $activeWeightBytes = 32 * $conv.InputChannels * $phaseWeights.Taps
          $haloBytes = 4 * $conv.InputChannels * [Math]::Abs($phaseWeights.Dilation) * [Math]::Max(0, $phaseWeights.Taps - 1)
          $cacheFrames = [int][Math]::Floor((1048576 - $activeWeightBytes - $haloBytes) / [double](4 * $conv.InputChannels + 32))
          $timeTile = [Math]::Max(8, [Math]::Min($ConvolutionTileFrames, $cacheFrames))
          $timeTile -= $timeTile % 8
          for ($workerIndex = 0; $workerIndex -lt $workerCount; $workerIndex++) {
            $worker = [Activator]::CreateInstance($directConvolution)
            $worker.Padded = $padded; $worker.Packed = $phaseWeights.Weights; $worker.Bias = $conv.Bias; $worker.Output = $result
            $worker.InputChannels = $conv.InputChannels; $worker.OutputChannels = $conv.OutputChannels
            $worker.PaddedFrames = $paddedFrames; $worker.OutputFrames = $outFrames; $worker.Kernel = $phaseWeights.Taps; $worker.Dilation = $phaseWeights.Dilation
            $worker.WorkFrames = $phaseFrames; $worker.OutputStep = $phaseCount; $worker.OutputOffset = $phase; $worker.InputOffset = $phaseWeights.InputOffset
            $worker.TimeTile = $timeTile
            $worker.FirstBlock = [int][Math]::Floor($workerIndex * $blocks / [double]$workerCount)
            $worker.LastBlock = [int][Math]::Floor(($workerIndex + 1) * $blocks / [double]$workerCount)
            $keepWorkers.Add($worker); $running.Add([Threading.Tasks.Task]::Run($directConvolution.GetMethod('Run').CreateDelegate([Action], $worker)))
          }
        }
        [Threading.Tasks.Task]::WaitAll($running.ToArray()); $watch.Stop()
        $profile.Add([pscustomobject]@{ Stage = $Name; Kind = 'DirectConvolution'; Milliseconds = $watch.Elapsed.TotalMilliseconds; Frames = $outFrames })
        return , $result
    }
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
function Invoke-OfflineAdaIn([float[]] $InputValues, [int] $Channels, [int] $Frames, [float[]] $AcousticStyle, [string] $Name, [string] $Module = 'decoder.module.') {
    $prefix = $Module + $Name
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
function Invoke-OfflineDecoderBlock([float[]] $InputValues, [int] $Frames, [float[]] $AcousticStyle, [string] $Name, [switch] $Upsample, [string] $Module = 'decoder.module.') {
    # Stock AdainResBlk1d (istftnet.py); the predictor's F0 and N blocks use the same form under predictor.module.
    $cin = [int]($InputValues.Length / $Frames)
    $next = Invoke-OfflineAdaIn $InputValues $cin $Frames $AcousticStyle ($Name + '.norm1') $Module
    $next = $leaky.Invoke($next, [float]0.2); $nextFrames = $Frames
    if ($Upsample) { $next = Invoke-OfflineConv $next $Frames ($Name + '.pool') -Stride 2 -Padding 1 -Groups $cin -Transpose -OutputPadding 1 -Module $Module; $nextFrames = 2 * $Frames }
    $next = Invoke-OfflineConv $next $nextFrames ($Name + '.conv1') -Padding 1 -Module $Module
    $cout = [int]($next.Length / $nextFrames)
    $next = Invoke-OfflineAdaIn $next $cout $nextFrames $AcousticStyle ($Name + '.norm2') $Module
    $next = $leaky.Invoke($next, [float]0.2)
    $next = Invoke-OfflineConv $next $nextFrames ($Name + '.conv2') -Padding 1 -Module $Module
    $shortcut = $InputValues
    if ($Upsample) { $shortcut = $nearest2.Invoke($InputValues, $cin, $Frames) }
    if ($cin -ne $cout) { $shortcut = Invoke-OfflineConv $shortcut $nextFrames ($Name + '.conv1x1') -Module $Module }
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
function Invoke-OfflineLstm([float[]] $Rows, [int] $rowCount, [string] $Prefix) {
    $stageWatch = [Diagnostics.Stopwatch]::StartNew()
    # Stock bidirectional nn.LSTM: forward weights followed by the _reverse weights.
    if (-not $lstmCache.ContainsKey($Prefix)) {
      $joinedParts = @(foreach ($name in 'weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0') {
        $forward = Read-OfflineWeight ($Prefix + '.' + $name); $reverse = Read-OfflineWeight ($Prefix + '.' + $name + '_reverse')
        $joined = [float[]]::new($forward.Length + $reverse.Length)
        [Array]::Copy($forward, 0, $joined, 0, $forward.Length); [Array]::Copy($reverse, 0, $joined, $forward.Length, $reverse.Length)
        , $joined
      })
      $lstmCache.Add($Prefix, $joinedParts)
    }
    $parts = $lstmCache[$Prefix]
    $hidden = [int]($parts[2].Length / 8); $inputs = [int]($parts[0].Length / (8 * $hidden))
    $values = [float[]]::new($rowCount * 2 * $hidden)
    if ($Dense -eq 'Scalar') {
        [void]$upstreamMath::Lstm($Rows, $rowCount, $inputs, $hidden, $parts[0], $parts[1], $parts[2], $parts[3], $values, 0, 2)
    } else {
        # Input projections for every step first, split by gate across all threads; then one
        # recurrence per direction. Bit-identical to the single-pass scalar Lstm.
        $gateCount = 4 * $hidden; $projection = [double[]]::new(2 * $rowCount * $gateCount)
        $perDirection = [Math]::Max(1, [int][Math]::Floor($Threads / 2))
        foreach ($phase in 0, 1) {
            $running = [Collections.Generic.List[Threading.Tasks.Task]]::new(); $keepWorkers = [Collections.Generic.List[object]]::new()
            for ($direction = 0; $direction -lt 2; $direction++) {
                $pieces = 1; if ($phase -eq 0) { $pieces = $perDirection }
                for ($piece = 0; $piece -lt $pieces; $piece++) {
                    $worker = [Activator]::CreateInstance($lstmWorker)
                    $worker.Values = $Rows; $worker.Rows = $rowCount; $worker.Inputs = $inputs; $worker.Hidden = $hidden
                    $worker.InputWeights = $parts[0]; $worker.HiddenWeights = $parts[1]; $worker.InputBias = $parts[2]; $worker.HiddenBias = $parts[3]
                    $worker.Output = $values; $worker.FirstDirection = $direction; $worker.LastDirection = $direction + 1
                    $worker.Projection = $projection; $worker.Phase = $phase
                    $worker.FirstGate = [int][Math]::Floor($piece * $gateCount / [double]$pieces)
                    $worker.LastGate = [int][Math]::Floor(($piece + 1) * $gateCount / [double]$pieces)
                    $keepWorkers.Add($worker); $running.Add([Threading.Tasks.Task]::Run($lstmWorker.GetMethod('Run').CreateDelegate([Action], $worker)))
                }
            }
            [Threading.Tasks.Task]::WaitAll($running.ToArray())
        }
    }
    $profile.Add([pscustomobject]@{ Stage = $Prefix; Kind = 'Lstm'; Milliseconds = $stageWatch.Elapsed.TotalMilliseconds; Frames = $rowCount })
    return , $values
}
function Invoke-OfflineLinear([float[]] $Rows, [int] $rowCount, [string] $Prefix) {
    $stageWatch = [Diagnostics.Stopwatch]::StartNew()
    $weight = Read-OfflineWeight ($Prefix + '.weight'); $bias = Read-OfflineWeight ($Prefix + '.bias')
    $inputs = [int]($weight.Length / $bias.Length)
    if ($Dense -eq 'Scalar') {
        $values = $upstreamMath::Linear($Rows, $rowCount, $inputs, $weight, $bias, $bias.Length)
    } else {
        if ($Rows.Length -ne $rowCount * $inputs -or $rowCount -lt 1) { throw 'Dense input shape mismatch.' }
        if (-not $denseCache.ContainsKey($Prefix)) {
            $denseCache.Add($Prefix, [pscustomobject]@{ Weights = $denseWorker::Pack($weight, $bias.Length, $inputs); Bias = $denseWorker::Pack($bias, $bias.Length, 1) })
        }
        $packed = $denseCache[$Prefix]
        $roundedRows = [int][Math]::Ceiling($rowCount / 4.0) * 4
        $paddedRows = [float[]]::new($roundedRows * $inputs)
        [Array]::Copy($Rows, $paddedRows, $Rows.Length)
        $values = [float[]]::new($rowCount * $bias.Length)
        $blocks = [int][Math]::Ceiling($bias.Length / 4.0); $workerCount = [Math]::Min($Threads, $blocks)
        $running = [Collections.Generic.List[Threading.Tasks.Task]]::new(); $keepWorkers = [Collections.Generic.List[object]]::new()
        for ($workerIndex = 0; $workerIndex -lt $workerCount; $workerIndex++) {
            $worker = [Activator]::CreateInstance($denseWorker)
            $worker.Input = $paddedRows; $worker.Packed = $packed.Weights; $worker.Bias = $packed.Bias; $worker.Output = $values
            $worker.Rows = $rowCount; $worker.InputChannels = $inputs; $worker.OutputChannels = $bias.Length
            $worker.FirstBlock = [int][Math]::Floor($workerIndex * $blocks / [double]$workerCount)
            $worker.LastBlock = [int][Math]::Floor(($workerIndex + 1) * $blocks / [double]$workerCount)
            $keepWorkers.Add($worker); $running.Add([Threading.Tasks.Task]::Run($denseWorker.GetMethod('Run').CreateDelegate([Action], $worker)))
        }
        [Threading.Tasks.Task]::WaitAll($running.ToArray())
    }
    $profile.Add([pscustomobject]@{ Stage = $Prefix; Kind = 'Linear'; Milliseconds = $stageWatch.Elapsed.TotalMilliseconds; Frames = $rowCount })
    return , $values
}
function Invoke-OfflineAlbert([int[]] $Ids) {
    # transformers AlbertModel as used by stock CustomAlbert: one shared layer applied 12 times.
    $p = 'bert.module.'; $layer = $p + 'encoder.albert_layer_groups.0.albert_layers.0.'; $t = $Ids.Length
    $x = $upstreamMath::AlbertEmbeddings($Ids, (Read-OfflineWeight ($p + 'embeddings.word_embeddings.weight')),
        (Read-OfflineWeight ($p + 'embeddings.position_embeddings.weight')), (Read-OfflineWeight ($p + 'embeddings.token_type_embeddings.weight')), 128)
    $x = $upstreamMath::LayerNorm($x, $t, 128, (Read-OfflineWeight ($p + 'embeddings.LayerNorm.weight')), (Read-OfflineWeight ($p + 'embeddings.LayerNorm.bias')), [double]1e-12)
    $h = Invoke-OfflineLinear $x $t ($p + 'encoder.embedding_hidden_mapping_in')
    for ($repeat = 0; $repeat -lt 12; $repeat++) {
        $query = Invoke-OfflineLinear $h $t ($layer + 'attention.query')
        $key = Invoke-OfflineLinear $h $t ($layer + 'attention.key')
        $value = Invoke-OfflineLinear $h $t ($layer + 'attention.value')
        $context = $upstreamMath::SelfAttention($query, $key, $value, $t, 12, 768)
        $projected = Invoke-OfflineLinear $context $t ($layer + 'attention.dense')
        $attention = $upstreamMath::LayerNorm($upstreamMath::Add($h, $projected), $t, 768,
            (Read-OfflineWeight ($layer + 'attention.LayerNorm.weight')), (Read-OfflineWeight ($layer + 'attention.LayerNorm.bias')), [double]1e-12)
        $feedForward = $upstreamMath::GeluNew((Invoke-OfflineLinear $attention $t ($layer + 'ffn')))
        $feedForward = Invoke-OfflineLinear $feedForward $t ($layer + 'ffn_output')
        $h = $upstreamMath::LayerNorm($upstreamMath::Add($feedForward, $attention), $t, 768,
            (Read-OfflineWeight ($layer + 'full_layer_layer_norm.weight')), (Read-OfflineWeight ($layer + 'full_layer_layer_norm.bias')), [double]1e-12)
    }
    return , $h
}
function Read-OfflineVoiceRow([string] $Voice, [int] $PhonemeCount) {
    # Stock KPipeline: pack[len(phonemes) - 1]; acoustic style is [:128], prosody style [128:].
    if ($Voice -cnotmatch '^[a-z]{2}_[a-z]+$') { throw 'Invalid voice name.' }
    if ($PhonemeCount -lt 1 -or $PhonemeCount -gt 510) { throw 'Phoneme count outside the voice pack (1..510).' }
    $manifest = Get-Content -LiteralPath (Join-Path $InputRepository 'lib/manifest.json') -Raw | ConvertFrom-Json
    $pin = @($manifest.model.files | Where-Object path -CEQ "voices\$Voice.pt")
    if ($pin.Count -ne 1) { throw "Voice $Voice is not pinned in lib/manifest.json." }
    $archive = & $reader.ReadTensor (Join-Path $InputRepository "build/inputs/kokoro/$($manifest.model.revision)/voices/$Voice.pt") $pin[0].sha256
    $raw = & $reader.TensorRow $archive ($PhonemeCount - 1)
    if ($raw.Length -ne 1024) { throw 'Voice row is not 256 float32 values.' }
    $row = [float[]]::new(256); [Buffer]::BlockCopy($raw, 0, $row, 0, 1024)
    return [pscustomobject]@{ Acoustic = [float[]]$row[0..127]; Prosody = [float[]]$row[128..255] }
}
function Invoke-OfflineSpeech {
    # Stock KModel.forward_with_tokens on the host: phonemes to PCM, every intermediate returned.
    # -SkipGenerator stops at the decoder: Pcm is $null. Teacher evidence for the Student
    # (durations, F0, N, encodings and the generator input Features) does not need PCM.
    param([Parameter(Mandatory)][string] $Phonemes, [string] $Voice = 'af_heart', [double] $Speed = 1, [switch] $SkipGenerator)
    $config = Get-Content -LiteralPath (Join-Path $InputRepository "build/inputs/kokoro/f3ff3571791e39611d31c381e3a41a3af07b4987/config.json") -Raw | ConvertFrom-Json -AsHashtable
    $ids = [Collections.Generic.List[int]]::new(); $ids.Add(0)
    foreach ($symbol in $Phonemes.ToCharArray()) { $id = $config.vocab[[string]$symbol]; if ($null -ne $id) { $ids.Add([int]$id) } }
    $ids.Add(0); $tokenIds = $ids.ToArray(); $t = $tokenIds.Length
    if ($t -gt 512) { throw 'More than 510 phonemes; stock splits longer input.' }
    $style = Read-OfflineVoiceRow $Voice $Phonemes.Length
    $bert = Invoke-OfflineAlbert $tokenIds
    $durationInput = Invoke-OfflineLinear $bert $t 'bert_encoder.module'
    $x = $upstreamMath::AppendStyle($durationInput, $t, 512, $style.Prosody)
    for ($layer = 0; $layer -lt 3; $layer++) {
        $x = Invoke-OfflineLstm $x $t "predictor.module.text_encoder.lstms.$(2 * $layer)"
        $affine = Invoke-OfflineLinear $style.Prosody 1 "predictor.module.text_encoder.lstms.$(2 * $layer + 1).fc"
        $x = $upstreamMath::AppendStyle($upstreamMath::AdaLayerNorm($x, $t, 512, $affine, [double]1e-5), $t, 512, $style.Prosody)
    }
    $durationFeatures = $x
    $logits = Invoke-OfflineLinear (Invoke-OfflineLstm $durationFeatures $t 'predictor.module.lstm') $t 'predictor.module.duration_proj.linear_layer'
    $durations = $upstreamMath::Durations($logits, $t, 50, $Speed)
    $frames = 0; foreach ($duration in $durations) { $frames += $duration }
    $aligned = $upstreamMath::ExpandChannels($durationFeatures, $t, 640, $durations)
    $shared = Invoke-OfflineLstm ($upstreamMath::ChannelsToRows($aligned, 640, $frames)) $frames 'predictor.module.shared'
    $shared = $upstreamMath::RowsToChannels($shared, $frames, 512)
    $curves = @{}
    foreach ($curve in 'F0', 'N') {
        $values = $shared; $curveFrames = $frames
        for ($block = 0; $block -lt 3; $block++) {
            $values = Invoke-OfflineDecoderBlock $values $curveFrames $style.Prosody "$curve.$block" -Upsample:($block -eq 1) -Module 'predictor.module.'
            if ($block -eq 1) { $curveFrames *= 2 }
        }
        $curves[$curve] = Invoke-OfflineConv $values $curveFrames "$($curve)_proj" -Module 'predictor.module.'
    }
    $encoderWatch = [Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $script:OfflineTextEncoder) {
        Import-Module (Join-Path $root 'tools/Kokoro.TextEncoder.psm1')
        $script:OfflineTextEncoder = (Initialize-KokoroTextEncoder -CheckpointPath $modelPath).Engine
    }
    if ($Convolution -eq 'Direct') {
        for ($layer = 0; $layer -lt 3; $layer++) {
            $encoderPrefix = "text_encoder.module.cnn.$layer.0"
            if (-not $convolutionCache.ContainsKey($encoderPrefix)) {
                $encoderWeights = [float[]]::new(1310720); $encoderBias = [float[]]::new(512)
                [Array]::Copy($script:OfflineTextEncoder.ConvWeights, $layer * 1310720, $encoderWeights, 0, 1310720)
                [Array]::Copy($script:OfflineTextEncoder.ConvBias, $layer * 512, $encoderBias, 0, 512)
                $convolutionCache.Add($encoderPrefix, [pscustomobject]@{ Weights = $encoderWeights; Bias = $encoderBias; InputChannels = 512; OutputChannels = 512; Kernel = 5; Packed = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal) })
            }
        }
        $script:OfflineTextEncoder.Convolution = [Func[float[],int,int,float[]]]{
            param([float[]] $Values, [int] $FrameCount, [int] $LayerIndex)
            return , (Invoke-OfflineConv $Values $FrameCount "cnn.$LayerIndex.0" -Padding 2 -Module 'text_encoder.module.')
        }
    } else { $script:OfflineTextEncoder.Convolution = $null }
    $textEncoding = $script:OfflineTextEncoder.Run($tokenIds, $t)
    $profile.Add([pscustomobject]@{ Stage = 'text_encoder'; Kind = 'TextEncoderTotal'; Milliseconds = $encoderWatch.Elapsed.TotalMilliseconds; Frames = $t })
    $decoded = Invoke-OfflineDecoder ($align.Invoke($textEncoding, $durations)) $curves.F0 $curves.N $style.Acoustic -TokenDurations $durations
    $pcm = $null
    if (-not $SkipGenerator) {
        $sourceDraws = New-OfflineDraws ($curves.F0.Length * 300)
        $pcm = Invoke-OfflineGenerator $decoded.Features $style.Acoustic $curves.F0 $sourceDraws.Uniform $sourceDraws.Harmonic $sourceDraws.Extra
    }
    [pscustomobject]@{ Phonemes = $Phonemes; Voice = $Voice; Seed = $Seed; TokenIds = $tokenIds; Bert = $bert; DurationFeatures = $durationFeatures
        Durations = $durations; F0 = $curves.F0; N = $curves.N; TextEncoding = $textEncoding; Features = $decoded.Features; Pcm = $pcm }
}
$script:OfflineTextEncoder = $null
function New-OfflineDraws([int] $SampleCount) {
    $flat = $draws.Invoke($Seed, $SampleCount)
    $repeated = $draws.Invoke($Seed, $SampleCount)
    if (-not [Linq.Enumerable]::SequenceEqual[float]($flat, $repeated)) { throw 'Seeded draws are not reproducible.' }
    $uniform = [float[]]::new(9); $gaussian = [float[]]::new(9 * $SampleCount); $extraNoise = [float[]]::new($SampleCount)
    [Array]::Copy($flat, 0, $uniform, 0, 9); [Array]::Copy($flat, 9, $gaussian, 0, $gaussian.Length)
    [Array]::Copy($flat, 9 + $gaussian.Length, $extraNoise, 0, $SampleCount)
    return [pscustomobject]@{ Uniform = $uniform; Harmonic = $gaussian; Extra = $extraNoise }
}
function Write-OfflineArray([string] $DestinationPath, [Array] $ArrayValues) {
    $raw = [byte[]]::new([Buffer]::ByteLength($ArrayValues)); [Buffer]::BlockCopy($ArrayValues, 0, $raw, 0, $raw.Length)
    [IO.File]::WriteAllBytes($DestinationPath, $raw)
}
function Read-OfflineArray([string] $SourcePath, [type] $ElementType, [int] $ElementCount) {
    $raw = [IO.File]::ReadAllBytes($SourcePath); $values = [Array]::CreateInstance($ElementType, $ElementCount)
    if ($raw.Length -ne [Buffer]::ByteLength($values)) { throw "Native array length mismatch: $SourcePath" }
    [Buffer]::BlockCopy($raw, 0, $values, 0, $raw.Length); return , $values
}
function Write-OfflineWave([string] $DestinationPath, [float[]] $PcmValues) {
    if ([IO.File]::Exists($DestinationPath)) {
        $existing = [IO.File]::ReadAllBytes($DestinationPath); $newBytes = [byte[]]::new(4 * $PcmValues.Length)
        [Buffer]::BlockCopy($PcmValues, 0, $newBytes, 0, $newBytes.Length)
        if ($existing.Length -ne 44 + $newBytes.Length -or [BitConverter]::ToUInt16($existing,20) -ne 3 -or [BitConverter]::ToUInt16($existing,22) -ne 1 -or [BitConverter]::ToInt32($existing,24) -ne 24000) { throw 'Existing WAV does not match this experiment format.' }
        $oldBytes = [byte[]]::new($newBytes.Length); [Array]::Copy($existing,44,$oldBytes,0,$oldBytes.Length)
        if (-not [Linq.Enumerable]::SequenceEqual[byte]($oldBytes,$newBytes)) { throw "Existing WAV differs; refusing overwrite: $DestinationPath" }
        Write-Host "Preserved identical existing WAV: $DestinationPath"; return
    }
    $stream = [IO.File]::Create($DestinationPath); $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36 + 4 * $PcmValues.Length))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
        $writer.Write([short]3); $writer.Write([short]1); $writer.Write([int]24000); $writer.Write([int]96000)
        $writer.Write([short]4); $writer.Write([short]32); $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int](4 * $PcmValues.Length))
        $raw = [byte[]]::new(4 * $PcmValues.Length); [Buffer]::BlockCopy($PcmValues, 0, $raw, 0, $raw.Length); $writer.Write($raw)
    } finally { $writer.Dispose(); $stream.Dispose() }
}
function Invoke-OfflineBankSelection {
    # mine.ps1 was authored for PowerShell's default non-strict indexing:
    # its third context character extends beyond the terminal padding. Keep
    # that existing script's execution semantics without changing its source.
    Set-StrictMode -Off
    $selectionDirectory = Join-Path $output 'selection'
    if ($null -ne $SelectedUnits) { $selectionDirectory = Join-Path $output ('selection-reader-' + [Guid]::NewGuid().ToString('N')) }
    [void][IO.Directory]::CreateDirectory($selectionDirectory)
    $heldoutSource = Join-Path $InputRepository 'build/unit-bank/scripts/heldout.json'; $heldoutCopy = Join-Path $selectionDirectory 'heldout.json'
    if ([IO.File]::Exists($heldoutCopy)) {
        if ((Get-FileHash -LiteralPath $heldoutCopy).Hash -cne (Get-FileHash -LiteralPath $heldoutSource).Hash) { throw 'Held-out copy differs from preserved input.' }
    } else { [IO.File]::Copy($heldoutSource, $heldoutCopy, $false) }
    $savedWeights = $env:KOKORO_TARGETW
    try {
        $env:KOKORO_TARGETW = '4,1,0.5,4,8,2'
        # Existing trusted selector owns its preserved JSON boundary. Retain its
        # in-process objects; this experiment neither parses nor produces JSON.
        $requestedSizes = [int[]]@(1000000)
        if ($null -ne $SelectedUnits) { $requestedSizes = [int[]]::new(0) }
        if(-not $env:KOKORO_NOTES){throw 'Set KOKORO_NOTES to the project notes folder (Invoke-KokoroDevelopment.ps1 sets it).'}
        . (Join-Path $env:KOKORO_NOTES 'reference/unit-bank/mine.ps1') -Dir $selectionDirectory -Sizes $requestedSizes -K 40 | Out-Host
        $selection = $SelectedUnits
        if ($null -eq $selection) {
            $selection = $results["$sent"]
            $selection | Export-Clixml -LiteralPath (Join-Path $output 'selection.clixml')
        }
        if ($selection['sentences'] -ne $order.Count -or $selection['picks'].Count -ne 9) { throw 'Saved selection does not cover the full bank and nine targets.' }
        return [pscustomobject]@{ Picks = $selection['picks']; Order = $order; ReadNpy = (Get-Command Read-Npy).ScriptBlock; BankSentences = $selection['sentences']; BankUnits = $selection['units'] }
    } finally { $env:KOKORO_TARGETW = $savedWeights }
}
function Read-OfflineBankArray([IO.Compression.ZipArchive] $Archive, [string] $ArrayName, [string] $ExpectedType, [type] $ElementType) {
    $npy = & $bankSelection.ReadNpy $Archive $ArrayName
    if ($npy.Type -cne $ExpectedType) { throw "Unexpected bank dtype: $ArrayName" }
    $width = [int]$ExpectedType.Substring(2)
    if (($npy.Bytes.Length - $npy.Offset) % $width -ne 0) { throw 'Truncated bank array.' }
    $values = [Array]::CreateInstance($ElementType, [int](($npy.Bytes.Length - $npy.Offset) / $width))
    [Buffer]::BlockCopy($npy.Bytes, $npy.Offset, $values, 0, [Buffer]::ByteLength($values)); return , $values
}
function Invoke-OfflineJoinExperiment {
    if (@(Get-ChildItem -LiteralPath $output -Filter '*.wav' -File).Count -and $DonorRecords.Count -eq 0) { throw 'Existing WAVs require their recorded donor inputs.' }
    # KOKORO_MEASURE_AUDIO_REPOSITORY names a checkout of the pinned MeasureAudio commit.
    $measurementRoot = $env:KOKORO_MEASURE_AUDIO_REPOSITORY
    if (-not $measurementRoot) { throw 'Set KOKORO_MEASURE_AUDIO_REPOSITORY to a checkout of MeasureAudio commit 93a6d82.' }
    if ((& git -C $measurementRoot rev-parse HEAD) -cne '93a6d8220ed20734b0f5a943ef95b03c922d5be1') { throw 'MeasureAudio revision differs from requested commit.' }
    $experimentType = $assembly.GetType('OfflineExperimentMath', $true)
    $bankDurations = $experimentType.GetMethod('Durations').CreateDelegate([Func[short[],int,int,int[]]])
    $offsets = $experimentType.GetMethod('Offsets').CreateDelegate([Func[int[],int[]]])
    $encoderSlice = $experimentType.GetMethod('EncoderSlice').CreateDelegate([Func[short[],float[],int,int,int,float[]]])
    $halfSlice = $experimentType.GetMethod('HalfSlice').CreateDelegate([Func[ushort[],int,int,float[]]])
    $copyFrames = $experimentType.GetMethod('CopyFrames').CreateDelegate([Action[float[],int,int,int,float[],int,int]])
    $addMoments = $experimentType.GetMethod('AddTokenMoments').CreateDelegate([Action[double[],int,int,int,double[]]])
    $finishMoments = $experimentType.GetMethod('FinishMoments').CreateDelegate([Func[double[],int,double[]]])
    $addLive = $experimentType.GetMethod('AddLiveLevels').CreateDelegate([Action[double[],double[]]])
    $averageLevels = $experimentType.GetMethod('AverageLevels').CreateDelegate([Func[double[],int,double[]]])
    $levelErrors = $experimentType.GetMethod('LevelErrors').CreateDelegate([Func[double[],double[],int,double[]]])
    $windows = $experimentType.GetMethod('Windows').CreateDelegate([Func[int[],int,float[]]])
    $addWindow = $experimentType.GetMethod('AddWindowedUnit').CreateDelegate([Action[float[],int,int,int,float[],float[],int]])
    $joinMetrics = $experimentType.GetMethod('JoinMetrics').CreateDelegate([Func[float[],int[],double[]]])
    # Verify half conversion against the existing runtime on all 65,536 encodings
    # that represent finite half values; this is data-format admission, not fitting.
    $halfCodes = [ushort[]]::new(63488); $at = 0
    for ($code = 0; $code -lt 65536; $code++) { if (($code -band 31744) -ne 31744) { $halfCodes[$at] = [ushort]$code; $at++ } }
    $halfValues = $halfSlice.Invoke($halfCodes, 0, $halfCodes.Length)
    for ($at = 0; $at -lt $halfCodes.Length; $at++) {
        $expectedHalf = [float][BitConverter]::ToHalf([BitConverter]::GetBytes($halfCodes[$at]), 0)
        if ([BitConverter]::SingleToInt32Bits($expectedHalf) -ne [BitConverter]::SingleToInt32Bits($halfValues[$at])) { throw 'Half decoding admission failed.' }
    }
    $bankSelection = Invoke-OfflineBankSelection
    if ($bankSelection.Picks.Count -ne 9) { throw 'Expected nine held-out selections.' }
    $donorIds = [Collections.Generic.SortedSet[int]]::new()
    foreach ($pick in $bankSelection.Picks) { foreach ($unit in $pick.path) { [void]$donorIds.Add([int]$unit.s) } }
    $voicePath = Join-Path $InputRepository 'build/inputs/kokoro/f3ff3571791e39611d31c381e3a41a3af07b4987/voices/af_heart.pt'
    if ((Get-FileHash -LiteralPath $voicePath).Hash -cne '0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF') { throw 'Voice integrity mismatch.' }
    $voiceArchive = & $reader.ReadTensor $voicePath '0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF'; $rowBytes = & $reader.TensorRow $voiceArchive 25
    $fixedStyle = [float[]]::new(128); [Buffer]::BlockCopy($rowBytes, 0, $fixedStyle, 0, 512)
    $donors = [Collections.Generic.Dictionary[int,OfflineDonor]]::new()
    $prepared = [Collections.Generic.Dictionary[int,object]]::new()
    foreach ($recordedDonor in $DonorRecords) { $prepared.Add([int]$recordedDonor.Sentence, $recordedDonor) }
    if ($prepared.Count -ne 0 -and $prepared.Count -ne $donorIds.Count) { throw 'Prepared donor set does not cover the selected units.' }
    $donorDirectory = Join-Path $output 'donors'; [void][IO.Directory]::CreateDirectory($donorDirectory)
    $donorResults = [Collections.Generic.List[object]]::new(); $lastChunk = -1; $arrays = $null
    foreach ($sourceId in $donorIds) {
        $chunk = [int][Math]::Floor($sourceId / 1000.0)
        if ($chunk -ne $lastChunk) {
            $chunkPath = Join-Path $InputRepository ('build/unit-bank/chunk-{0:D4}.npz' -f $chunk)
            $zip = [IO.Compression.ZipFile]::OpenRead($chunkPath)
            try {
                $arrays = [pscustomobject]@{
                    Tokens = Read-OfflineBankArray $zip 't_en' '<i2' ([short]); Scales = Read-OfflineBankArray $zip 'scale' '<f4' ([float])
                    Durations = Read-OfflineBankArray $zip 'dur' '<i2' ([short]); F0 = Read-OfflineBankArray $zip 'f0' '<f2' ([ushort]); N = Read-OfflineBankArray $zip 'n' '<f2' ([ushort])
                    TokenOffsets = Read-OfflineBankArray $zip 'tok_off' '<i8' ([long]); FrameOffsets = Read-OfflineBankArray $zip 'frm_off' '<i8' ([long])
                }
            } finally { $zip.Dispose() }
            $lastChunk = $chunk
        }
        $localId = $sourceId % 1000; $tokenFirst = [int]$arrays.TokenOffsets[$localId]; $tokenCount = [int]($arrays.TokenOffsets[$localId + 1] - $tokenFirst)
        $frameFirst = [int]$arrays.FrameOffsets[$localId]; $frameCount = [int]($arrays.FrameOffsets[$localId + 1] - $frameFirst)
        $donor = [OfflineDonor]::new(); $donor.Sentence = $sourceId; $donor.Text = $bankSelection.Order[$sourceId].text
        $donor.Durations = $bankDurations.Invoke($arrays.Durations, $tokenFirst, $tokenCount); $donor.Offsets = $offsets.Invoke($donor.Durations)
        if ($donor.Offsets[$tokenCount] -ne $frameCount) { throw 'Bank duration/frame offset mismatch.' }
        $donor.TextEncoder = $encoderSlice.Invoke($arrays.Tokens, $arrays.Scales, $arrays.Durations.Length, $tokenFirst, $tokenCount)
        $donor.F0 = $halfSlice.Invoke($arrays.F0, 2 * $frameFirst, 2 * $frameCount); $donor.N = $halfSlice.Invoke($arrays.N, 2 * $frameFirst, 2 * $frameCount)
        if ($prepared.Count -gt 0) {
            $savedDonor = $prepared[$sourceId]
            if ($savedDonor.SourceChunkSHA256 -cne (Get-FileHash -LiteralPath $chunkPath).Hash -or $savedDonor.Frames -ne $donor.F0.Length -or
                -not [Linq.Enumerable]::SequenceEqual[int]([int[]]$savedDonor.Durations,$donor.Durations)) { throw 'Prepared donor provenance/shape mismatch.' }
            $donor.Decoded = [OfflineDecoderResult]::new(); $donor.Decoded.Features = Read-OfflineArray (Join-Path $donorDirectory "$sourceId-decoder.f32") ([float]) (512 * $donor.F0.Length)
            $restoredSites = [Collections.Generic.List[OfflineLevelRecord]]::new()
            foreach ($savedSite in $savedDonor.Sites) {
                if ($savedSite.Name -cnotmatch '^(encode|decode\.[0-3])\.norm[12]$') { throw 'Invalid prepared site name.' }
                $site = [OfflineLevelRecord]::new(); $site.Name = $savedSite.Name; $site.Channels = $savedSite.Channels; $site.Frames = $savedSite.Frames; $site.TokenFrames = [int[]]$savedSite.TokenFrames
                $site.Statistics = Read-OfflineArray (Join-Path $donorDirectory ("$sourceId-" + $site.Name + '-moments.f64')) ([double]) (2 * $site.Channels * ($tokenCount + 1))
                $restoredSites.Add($site)
            }
            if ($restoredSites.Count -ne 10) { throw 'Incomplete prepared normalization sites.' }
            $donor.Decoded.Levels = $restoredSites.ToArray(); $donor.DecoderMs = $savedDonor.DecoderMs
            $donors.Add($sourceId,$donor); $donorResults.Add($savedDonor); continue
        }
        $donorAsr = $align.Invoke($donor.TextEncoder, $donor.Durations); $profile.Clear(); $donorWatch = [Diagnostics.Stopwatch]::StartNew()
        $donor.Decoded = Invoke-OfflineDecoder $donorAsr $donor.F0 $donor.N $fixedStyle -TokenDurations $donor.Durations
        $donorWatch.Stop(); $donor.DecoderMs = $donorWatch.Elapsed.TotalMilliseconds
        Write-OfflineArray (Join-Path $donorDirectory "$sourceId-decoder.f32") $donor.Decoded.Features
        $originalEncoder = [short[]]::new(512 * $tokenCount)
        for ($channel = 0; $channel -lt 512; $channel++) { [Array]::Copy($arrays.Tokens, $channel * $arrays.Durations.Length + $tokenFirst, $originalEncoder, $channel * $tokenCount, $tokenCount) }
        Write-OfflineArray (Join-Path $donorDirectory "$sourceId-t_en.i16") $originalEncoder
        foreach ($site in $donor.Decoded.Levels) { Write-OfflineArray (Join-Path $donorDirectory ("$sourceId-" + $site.Name + '-moments.f64')) $site.Statistics }
        $donorResults.Add([pscustomobject]@{ Sentence = $sourceId; Text = $donor.Text; Tokens = $tokenCount; Frames = 2 * $frameCount; Durations = $donor.Durations; DecoderMs = $donor.DecoderMs; Sites = @($donor.Decoded.Levels | Select-Object Name, Channels, Frames, TokenFrames); SourceChunkSHA256 = (Get-FileHash -LiteralPath $chunkPath).Hash })
        $donors.Add($sourceId, $donor); $donorResults.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'donors.clixml')
        Write-Host ('donor {0}: {1} tokens, {2} output frames, decoder {3:F3} ms ({4}/{5})' -f $sourceId,$tokenCount,(2*$frameCount),$donor.DecoderMs,$donors.Count,$donorIds.Count)
    }
    $frozen = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $firstDonor = $donors[$donorIds.Min]
    foreach ($template in $firstDonor.Decoded.Levels) {
        $totals = [double[]]::new(2 * $template.Channels)
        foreach ($donor in $donors.Values) { $site = @($donor.Decoded.Levels | Where-Object Name -CEQ $template.Name)[0]; $addLive.Invoke($site.Statistics, $totals) }
        $record = [OfflineLevelRecord]::new(); $record.Name = $template.Name; $record.Channels = $template.Channels; $record.Statistics = $averageLevels.Invoke($totals, $donors.Count)
        $frozen.Add($record.Name, $record)
    }
    $measurements = [Collections.Generic.List[object]]::new(); $levelsReport = [Collections.Generic.List[object]]::new(); $unitReport = [Collections.Generic.List[object]]::new()
    $targetIndex = 0
    foreach ($pick in $bankSelection.Picks) {
        $targetIndex++; $units = @($pick.path); $targetDurations = [int[]]::new($units.Count)
        for ($u = 0; $u -lt $units.Count; $u++) { $targetDurations[$u] = $donors[[int]$units[$u].s].Durations[[int]$units[$u].i] }
        $targetOffsets = $offsets.Invoke($targetDurations); $targetFrames = $targetOffsets[$units.Count]; $decoderFrames = 2 * $targetFrames
        $targetEncoder = [float[]]::new(512 * $units.Count); $targetF0 = [float[]]::new($decoderFrames); $targetN = [float[]]::new($decoderFrames)
        $rawFeatures = [float[]]::new(512 * $decoderFrames); $outputOffsets = $scaleFrames.Invoke($targetOffsets, 2)
        $joinSamples = [int[]]::new($units.Count - 1)
        for ($u = 0; $u -lt $units.Count; $u++) {
            $donor = $donors[[int]$units[$u].s]; $token = [int]$units[$u].i; $sourceFirst = 2 * $donor.Offsets[$token]; $length = 2 * $targetDurations[$u]; $destinationFirst = 2 * $targetOffsets[$u]
            $copyFrames.Invoke($donor.TextEncoder, $donor.Durations.Length, $token, 1, $targetEncoder, $units.Count, $u)
            [Array]::Copy($donor.F0, $sourceFirst, $targetF0, $destinationFirst, $length); [Array]::Copy($donor.N, $sourceFirst, $targetN, $destinationFirst, $length)
            $copyFrames.Invoke($donor.Decoded.Features, $donor.F0.Length, $sourceFirst, $length, $rawFeatures, $decoderFrames, $destinationFirst)
            if ($u -gt 0) { $joinSamples[$u - 1] = $destinationFirst * 300 }
            $unitReport.Add([pscustomobject]@{ Target = $targetIndex; TargetToken = $u; Donor = $donor.Sentence; DonorText = $donor.Text; TokenFirst = $token; TokenEndExclusive = $token + 1; FrameFirst = $sourceFirst; FrameEndExclusive = $sourceFirst + $length; TargetFrameFirst = $destinationFirst })
        }
        $unitReport.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'selected-units.clixml')
        $targetAsr = $align.Invoke($targetEncoder, $targetDurations); $profile.Clear(); $targetWatch = [Diagnostics.Stopwatch]::StartNew()
        $planned = Invoke-OfflineDecoder $targetAsr $targetF0 $targetN $fixedStyle -TokenDurations $targetDurations
        $targetWatch.Stop(); $plannedMs = $targetWatch.Elapsed.TotalMilliseconds
        $composed = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($template in $planned.Levels) {
            $totals = [double[]]::new(2 * $template.Channels)
            for ($u = 0; $u -lt $units.Count; $u++) {
                $donor = $donors[[int]$units[$u].s]; $site = @($donor.Decoded.Levels | Where-Object Name -CEQ $template.Name)[0]
                $addMoments.Invoke($site.Statistics, $site.Channels, $donor.Durations.Length, [int]$units[$u].i, $totals)
            }
            $record = [OfflineLevelRecord]::new(); $record.Name = $template.Name; $record.Channels = $template.Channels; $record.Frames = $template.Frames
            $record.Statistics = $finishMoments.Invoke($totals, $record.Frames); $composed.Add($record.Name, $record)
            $relative = $levelErrors.Invoke($record.Statistics, $template.Statistics, $record.Channels)
            $levelsReport.Add([pscustomobject]@{ Target = $targetIndex; Site = $record.Name; MeanMaxRelative = $relative[0]; MeanMedianRelative = $relative[1]; StdMaxRelative = $relative[2]; StdMedianRelative = $relative[3] })
        }
        $levelsReport.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'level-errors.clixml')
        $seededDraws = New-OfflineDraws ($decoderFrames * 300)
        foreach ($variant in @('A','B','C1','C2','C4','D','E')) {
            $features = $null; $decodeMs = [double]0; $featureSnr = [double]::NaN
            switch ($variant) {
                'A' { $features = $planned.Features; $decodeMs = $plannedMs }
                'B' { $features = $rawFeatures }
                { $_ -in @('C1','C2','C4') } {
                    $extension = [int]$variant.Substring(1); $weights = $windows.Invoke($outputOffsets, $extension); $features = [float[]]::new(512 * $decoderFrames)
                    for ($u = 0; $u -lt $units.Count; $u++) {
                        $donor = $donors[[int]$units[$u].s]; $token = [int]$units[$u].i
                        $addWindow.Invoke($donor.Decoded.Features, 2 * $donor.Offsets[$token], $outputOffsets[$u], $u, $weights, $features, $decoderFrames)
                    }
                }
                'D' {
                    $profile.Clear(); $targetWatch.Restart(); $banked = Invoke-OfflineDecoder $targetAsr $targetF0 $targetN $fixedStyle -TokenDurations $targetDurations -LevelMode Supplied -SuppliedLevels $composed
                    $targetWatch.Stop(); $decodeMs = $targetWatch.Elapsed.TotalMilliseconds; $features = $banked.Features
                    $featureSnr = $compare.Invoke($features, $planned.Features)[0]
                }
                'E' {
                    $profile.Clear(); $targetWatch.Restart(); $control = Invoke-OfflineDecoder $targetAsr $targetF0 $targetN $fixedStyle -TokenDurations $targetDurations -LevelMode Supplied -SuppliedLevels $frozen
                    $targetWatch.Stop(); $decodeMs = $targetWatch.Elapsed.TotalMilliseconds; $features = $control.Features
                    $featureSnr = $compare.Invoke($features, $planned.Features)[0]
                }
            }
            $profile.Clear(); $targetWatch.Restart(); $pcm = Invoke-OfflineGenerator $features $fixedStyle $targetF0 $seededDraws.Uniform $seededDraws.Harmonic $seededDraws.Extra
            $targetWatch.Stop(); $generatorMs = $targetWatch.Elapsed.TotalMilliseconds; $path = Join-Path $output ('{0:D2}-{1}.wav' -f $targetIndex,$variant)
            Write-OfflineWave $path $pcm
            $join = $joinMetrics.Invoke($pcm, $joinSamples)
            $measurements.Add([pscustomobject]@{ Sentence = $targetIndex; Text = $pick.text; Variant = $variant; Path = $path; IntegratedLufs = [double]::NaN; TruePeakDbtp = [double]::NaN; JoinMax = $join[0]; JoinMedian = $join[1]; WindowMedianDelta = $join[2]; DecoderOutputSnrDb = $featureSnr; DecoderMs = $decodeMs; GeneratorMs = $generatorMs; Frames = $decoderFrames; Seed = $Seed; VoiceRow = 25; SourceSHA256 = $sourceHash; AssemblySHA256 = $admission.SHA256 })
            $measurements.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'measurements.clixml')
            Write-Host ('sentence {0} {1}: join max/median {2:F3}/{3:F3}; generator {4:F3} ms; decoder-output SNR {5:F3} dB' -f $targetIndex,$variant,$join[0],$join[1],$generatorMs,$featureSnr)
        }
    }
    # The requested pinned MeasureAudio command admits folders. Batch all WAVs
    # after rendering, retaining its own implementation and avoiding its
    # single-FileInfo Count failure. Execute from its owning worktree.
    Push-Location -LiteralPath $measurementRoot
    try { $audioMeasurements = @(& ./Invoke-KokoroDevelopment.ps1 MeasureAudio -Path $output) }
    finally { Pop-Location }
    if ($audioMeasurements.Count -ne $measurements.Count) { throw 'MeasureAudio did not return every variant.' }
    foreach ($render in $measurements) {
        $audio = @($audioMeasurements | Where-Object Path -CEQ $render.Path)
        if ($audio.Count -ne 1) { throw 'Missing/duplicate WAV measurement.' }
        $render.IntegratedLufs = $audio[0].IntegratedLufs; $render.TruePeakDbtp = $audio[0].TruePeakDbtp
    }
    $measurements.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'measurements.clixml')
    $tokenTotal = [long]0; foreach ($donor in $donors.Values) { $tokenTotal += $donor.Durations.Length }
    $decoderBytes = (Get-ChildItem $donorDirectory -Filter '*-decoder.f32' | Measure-Object Length -Sum).Sum
    $encoderBytes = (Get-ChildItem $donorDirectory -Filter '*-t_en.i16' | Measure-Object Length -Sum).Sum
    $momentBytes = (Get-ChildItem $donorDirectory -Filter '*-moments.f64' | Measure-Object Length -Sum).Sum
    [pscustomobject]@{ Donors = $donors.Count; Units = $tokenTotal; DecoderBytes = $decoderBytes; TextEncoderBytes = $encoderBytes; MomentBytes = $momentBytes; DecoderBytesPerUnit = $decoderBytes / $tokenTotal; TextEncoderBytesPerUnit = $encoderBytes / $tokenTotal } | Export-Clixml -LiteralPath (Join-Path $output 'store-size.clixml')
    return $measurements.ToArray()
}
if ($Mode -eq 'Library') { return }
if ($Mode -eq 'Join') { Invoke-OfflineJoinExperiment; return }
if ($Mode -eq 'Kernels') {
    $kernelCases = @(
        @{ Name = 'generator.ups.0'; Stride = 10; Padding = 5; Dilation = 1; Transpose = $true }
        @{ Name = 'generator.ups.1'; Stride = 6; Padding = 3; Dilation = 1; Transpose = $true }
        @{ Name = 'generator.resblocks.3.convs1.0'; Stride = 1; Padding = 1; Dilation = 1; Transpose = $false }
        @{ Name = 'generator.resblocks.3.convs1.0'; Stride = 1; Padding = 3; Dilation = 3; Transpose = $false }
    )
    $kernelResults = [Collections.Generic.List[object]]::new()
    foreach ($kernelCase in $kernelCases) {
      $definition = Get-OfflineConvolution $kernelCase.Name 1 $kernelCase.Transpose
      foreach ($frameCount in 1,7,17) {
        $values = [float[]]::new($definition.InputChannels * $frameCount)
        $randomValues = $draws.Invoke($Seed, $values.Length)
        [Array]::Copy($randomValues, 9, $values, 0, $values.Length)
        $callParameters = @{ InputValues = $values; Frames = $frameCount; Name = $kernelCase.Name; Stride = $kernelCase.Stride; Padding = $kernelCase.Padding; Dilation = $kernelCase.Dilation; Transpose = $kernelCase.Transpose; OutputPadding = 0 }
        if ($kernelCase.Transpose -and $frameCount -eq 7) { $callParameters.OutputPadding = 1 }
        $Convolution = 'Reference'; $expectedValues = Invoke-OfflineConv @callParameters
        $Convolution = 'Direct'; $actualValues = Invoke-OfflineConv @callParameters
        $metrics = $compare.Invoke($actualValues, $expectedValues)
        $exact = [Linq.Enumerable]::SequenceEqual[float]($actualValues, $expectedValues)
        $kernelResults.Add([pscustomobject]@{ Kernel = $kernelCase.Name; InputFrames = $frameCount; Dilation = $kernelCase.Dilation; OutputPadding = $callParameters.OutputPadding; Exact = $exact; SnrDb = $metrics[0]; MaxAbsError = $metrics[1]; SourceSHA256 = $sourceHash; AssemblySHA256 = $admission.SHA256 })
      }
    }
    $kernelResults.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'kernel-checks.clixml')
    if (@($kernelResults | Where-Object { -not $_.Exact }).Count -gt 0) { throw 'Packed convolution boundary check failed.' }
    $kernelResults.ToArray()
    return
}
if ($Mode -eq 'Speech') {
    $speechOutput = $output
    $speechRuns = 1
    if ($PSBoundParameters.ContainsKey('Runs')) { $speechRuns = $Runs }
    $speechResults = [Collections.Generic.List[object]]::new()
    for ($speechRun = 1; $speechRun -le $speechRuns; $speechRun++) {
    if ($speechRuns -gt 1) {
        $output = Join-Path $speechOutput ('run-{0:D2}' -f $speechRun)
        [void][IO.Directory]::CreateDirectory($output)
    }
    $speechWatch = [Diagnostics.Stopwatch]::StartNew()
    $driverDirectory = Join-Path $root 'build/phonemizer/english/driver/D7B06FD52B900130E8702544D14BE2F662EC2E009EFCE6B33E3FC92BE8B70AD1-library-dll'
    $driverPin = '112DC0B565042184DF74FA5176F09F6E8294857693B44F0BBED456A43B3FEEF1'
    $driverReceipt = Import-PowerShellDataFile (Join-Path $driverDirectory 'driver-receipt.psd1')
    $driverPath = Join-Path $driverDirectory ([IO.Path]::GetFileName($driverReceipt.Output))
    if ($driverReceipt.AssemblySha256 -cne $driverPin -or (Get-FileHash -LiteralPath $driverPath).Hash -cne $driverPin) { throw 'Compiled English phonemizer integrity mismatch.' }
    $driverAssembly = [Reflection.Assembly]::LoadFrom($driverPath)
    $phonemize = $driverAssembly.GetType('CoreDriver', $true).GetMethod('Run').CreateDelegate([Func[string,object]])
    $pronunciation = $phonemize.Invoke($Text)
    if (-not $pronunciation.Complete -or -not $pronunciation.KokoroPhones) { throw 'Compiled phonemizer could not resolve Text.' }
    $phonemizerMs = $speechWatch.Elapsed.TotalMilliseconds
    $profile.Clear()
    $teacherWatch = [Diagnostics.Stopwatch]::StartNew()
    $speech = Invoke-OfflineSpeech -Phonemes $pronunciation.KokoroPhones -Voice $Voice -Speed $Speed
    $teacherWatch.Stop(); $speechWatch.Stop()
    $profile.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'speech-profile.clixml')
    Write-OfflineWave (Join-Path $output 'speech.wav') $speech.Pcm
    foreach ($boundary in 'TokenIds','Durations','Bert','DurationFeatures','F0','N','TextEncoding','Features','Pcm') {
        Write-OfflineArray (Join-Path $output ($boundary + '.bin')) $speech.$boundary
    }
    $result = [pscustomobject]@{
        Text = $Text; Phonemes = $speech.Phonemes; Voice = $Voice; Seed = $Seed; Speed = $Speed
        Tokens = $speech.TokenIds.Length; Samples = $speech.Pcm.Length; AudioSeconds = $speech.Pcm.Length / 24000.0
        Run = $speechRun; Convolution = $Convolution; Dense = $Dense; Threads = $Threads; ConvolutionTileFrames = $ConvolutionTileFrames; PhonemizerMs = $phonemizerMs; TeacherMs = $teacherWatch.Elapsed.TotalMilliseconds
        TextToPcmMs = $speechWatch.Elapsed.TotalMilliseconds
        RealTimeFactor = $speechWatch.Elapsed.TotalSeconds / ($speech.Pcm.Length / 24000.0)
        TimingScope = 'Host text-to-PCM including phonemizer, excluding teacher compilation and checkpoint loading'
        SourceSHA256 = $sourceHash; AssemblySHA256 = $admission.SHA256; DriverSHA256 = $driverPin
        TextEncoderSHA256 = (Get-FileHash -LiteralPath $script:OfflineTextEncoder.GetType().Assembly.Location).Hash
        PcmSHA256 = (Get-FileHash -LiteralPath (Join-Path $output 'Pcm.bin')).Hash
        Path = Join-Path $output 'speech.wav'; Comparison = @()
    }
    if ($CompareConvolution -or $ReferenceSpeechDirectory) {
        $candidateMethod = $Convolution
        if ($ReferenceSpeechDirectory) {
            $referenceDirectory = [IO.Path]::GetFullPath($ReferenceSpeechDirectory)
            $referenceReceipt = Import-Clixml -LiteralPath (Join-Path $referenceDirectory 'speech.clixml')
            if ($referenceReceipt.Phonemes -cne $speech.Phonemes -or $referenceReceipt.Voice -cne $Voice -or $referenceReceipt.Seed -ne $Seed -or $referenceReceipt.Speed -ne $Speed -or $referenceReceipt.DriverSHA256 -cne $driverPin) { throw 'Speech reference has different inputs.' }
            if ((Get-FileHash -LiteralPath (Join-Path $referenceDirectory 'Pcm.bin')).Hash -cne $referenceReceipt.PcmSHA256) { throw 'Recorded reference PCM integrity mismatch.' }
            $referenceSpeech = @{}
            foreach ($boundary in 'TokenIds','Durations','Bert','DurationFeatures','F0','N','TextEncoding','Features','Pcm') {
                $referenceSpeech[$boundary] = Read-OfflineArray (Join-Path $referenceDirectory ($boundary + '.bin')) $speech.$boundary.GetType().GetElementType() $speech.$boundary.Length
            }
            $comparisonMethod = 'Recorded'; $comparisonMs = $referenceReceipt.TeacherMs
        } else {
            $Convolution = if ($candidateMethod -eq 'Direct') { 'Reference' } else { 'Direct' }
            $profile.Clear(); $teacherWatch.Restart()
            $referenceSpeech = Invoke-OfflineSpeech -Phonemes $pronunciation.KokoroPhones -Voice $Voice -Speed $Speed
            $teacherWatch.Stop()
            $profile.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'comparison-profile.clixml')
            $comparisonMethod = $Convolution; $comparisonMs = $teacherWatch.Elapsed.TotalMilliseconds
        }
        $comparisons = foreach ($boundary in 'TokenIds','Durations','Bert','DurationFeatures','F0','N','TextEncoding','Features','Pcm') {
            $candidateValues = $speech.$boundary; $referenceValues = $referenceSpeech.$boundary
            $referenceBytes = [byte[]]::new([Buffer]::ByteLength($referenceValues))
            [Buffer]::BlockCopy($referenceValues, 0, $referenceBytes, 0, $referenceBytes.Length)
            $exact = [Linq.Enumerable]::SequenceEqual[byte](
                [IO.File]::ReadAllBytes((Join-Path $output ($boundary + '.bin'))),
                $referenceBytes)
            $metrics = if ($candidateValues.Length -eq $referenceValues.Length) { $compare.Invoke([float[]]$candidateValues, [float[]]$referenceValues) } else { [double[]]@([double]::NegativeInfinity, [double]::PositiveInfinity) }
            [pscustomobject]@{ Boundary = $boundary; BitExact = $exact; SnrDb = $metrics[0]; MaxAbsError = $metrics[1] }
        }
        $result.Comparison = [pscustomobject]@{ Method = $comparisonMethod; TeacherMs = $comparisonMs; Boundaries = @($comparisons) }
        $Convolution = $candidateMethod
    }
    $result | Export-Clixml -LiteralPath (Join-Path $output 'speech.clixml')
    if (($CompareConvolution -or $ReferenceSpeechDirectory) -and @($result.Comparison.Boundaries | Where-Object { -not $_.BitExact }).Count -gt 0) { throw 'Rewrite changed a teacher boundary; inspect speech.clixml.' }
    $speechResults.Add($result)
    Write-Host ('Speech run {0}: {1:F3} seconds, RTF {2:F3}, PCM {3}' -f $speechRun, ($result.TextToPcmMs / 1000), $result.RealTimeFactor, $result.PcmSHA256)
    }
    $output = $speechOutput
    $speechResults.ToArray() | Export-Clixml -LiteralPath (Join-Path $output 'speech-runs.clixml')
    return $speechResults.ToArray()
}
$captures =Import-PowerShellDataFile (Join-Path $InputRepository 'build/score-capture-20261014/capture.psd1')
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
