# Kokoro TextEncoder, one utterance with a valid prefix and masked trailing tokens.
# Weights and activations are float32; all numeric loops execute in lowered IL.
class KokoroTextEncoder {
    [float[]] $Embedding
    [float[]] $ConvWeights
    [float[]] $ConvBias
    [float[]] $Gamma
    [float[]] $Beta
    [float[]] $InputWeights
    [float[]] $HiddenWeights
    [float[]] $InputBias
    [float[]] $HiddenBias

    static [float[]] FoldWeightNorm([float[]] $values, [float[]] $gain) {
        if ($values.Length -ne 1310720 -or $gain.Length -ne 512) { throw [ArgumentException]::new('Convolution weight shape mismatch.') }
        $result = [float[]]::new($values.Length)
        for ($row = 0; $row -lt 512; $row++) {
            $sum = [float]0
            for ($i = 0; $i -lt 2560; $i++) { $v = $values[$row * 2560 + $i]; $sum = [float]($sum + [float]($v * $v)) }
            $scale = [float]($gain[$row] / [MathF]::Sqrt($sum))
            for ($i = 0; $i -lt 2560; $i++) { $result[$row * 2560 + $i] = [float]($values[$row * 2560 + $i] * $scale) }
        }
        return $result
    }

    [float[]] Run([int[]] $ids, [int] $length) {
        $tokens = $ids.Length
        if ($length -lt 1 -or $length -gt $tokens -or $tokens -gt 512) { throw [ArgumentException]::new('Invalid token length.') }
        $x = [float[]]::new(512 * $tokens)
        for ($t = 0; $t -lt $tokens; $t++) {
            if ($ids[$t] -lt 0 -or $ids[$t] -ge 178) { throw [ArgumentException]::new('Token outside embedding vocabulary.') }
            if ($t -lt $length) {
                for ($c = 0; $c -lt 512; $c++) { $x[$c * $tokens + $t] = $this.Embedding[$ids[$t] * 512 + $c] }
            }
        }
        for ($layer = 0; $layer -lt 3; $layer++) {
            $y = [float[]]::new(512 * $tokens)
            for ($oc = 0; $oc -lt 512; $oc++) {
                for ($t = 0; $t -lt $length; $t++) {
                    $sum = [float]0
                    for ($ic = 0; $ic -lt 512; $ic++) {
                        for ($tap = 0; $tap -lt 5; $tap++) {
                            $at = $t + $tap - 2
                            if ($at -ge 0 -and $at -lt $length) {
                                $weight = $this.ConvWeights[$layer * 1310720 + ($oc * 512 + $ic) * 5 + $tap]
                                $sum = [float]($sum + [float]($weight * $x[$ic * $tokens + $at]))
                            }
                        }
                    }
                    $y[$oc * $tokens + $t] = [float]($sum + $this.ConvBias[$layer * 512 + $oc])
                }
            }
            for ($t = 0; $t -lt $length; $t++) {
                $mean = [float]0
                for ($c = 0; $c -lt 512; $c++) { $mean = [float]($mean + $y[$c * $tokens + $t]) }
                $mean = [float]($mean / [float]512)
                $variance = [float]0
                for ($c = 0; $c -lt 512; $c++) { $delta = [float]($y[$c * $tokens + $t] - $mean); $variance = [float]($variance + [float]($delta * $delta)) }
                $inverse = [float]([float]1 / [MathF]::Sqrt([float]($variance / [float]512 + [float]0.00001)))
                for ($c = 0; $c -lt 512; $c++) {
                    $value = [float]([float]([float]($y[$c * $tokens + $t] - $mean) * $inverse) * $this.Gamma[$layer * 512 + $c] + $this.Beta[$layer * 512 + $c])
                    if ($value -lt [float]0) { $value = [float]($value * [float]0.2) }
                    $y[$c * $tokens + $t] = $value
                }
            }
            $x = $y
        }
        $output = [float[]]::new(512 * $tokens)
        for ($direction = 0; $direction -lt 2; $direction++) {
            $hidden = [float[]]::new(256); $cell = [float[]]::new(256); $gates = [float[]]::new(1024)
            for ($step = 0; $step -lt $length; $step++) {
                $t = $step
                if ($direction -eq 1) { $t = $length - 1 - $step }
                for ($gate = 0; $gate -lt 1024; $gate++) {
                    $inputSum = [float]0; $hiddenSum = [float]0
                    for ($c = 0; $c -lt 512; $c++) { $inputSum = [float]($inputSum + [float]($this.InputWeights[($direction * 1024 + $gate) * 512 + $c] * $x[$c * $tokens + $t])) }
                    for ($c = 0; $c -lt 256; $c++) { $hiddenSum = [float]($hiddenSum + [float]($this.HiddenWeights[($direction * 1024 + $gate) * 256 + $c] * $hidden[$c])) }
                    $gates[$gate] = [float]([float]($inputSum + $this.InputBias[$direction * 1024 + $gate]) + [float]($hiddenSum + $this.HiddenBias[$direction * 1024 + $gate]))
                }
                for ($c = 0; $c -lt 256; $c++) {
                    $inputGate = [float]([float]1 / [float]([float]1 + [MathF]::Exp(-$gates[$c])))
                    $forgetGate = [float]([float]1 / [float]([float]1 + [MathF]::Exp(-$gates[256 + $c])))
                    $proposal = [MathF]::Tanh($gates[512 + $c])
                    $outputGate = [float]([float]1 / [float]([float]1 + [MathF]::Exp(-$gates[768 + $c])))
                    $cell[$c] = [float]([float]($forgetGate * $cell[$c]) + [float]($inputGate * $proposal))
                    $hidden[$c] = [float]($outputGate * [MathF]::Tanh($cell[$c]))
                    $output[($direction * 256 + $c) * $tokens + $t] = $hidden[$c]
                }
            }
        }
        return $output
    }

    static [float] MaxError([float[]] $actual, [float[]] $expected) {
        if ($actual.Length -ne $expected.Length) { throw [ArgumentException]::new('Comparison shape mismatch.') }
        $maximum = [float]0
        for ($i = 0; $i -lt $actual.Length; $i++) {
            if (-not [float]::IsFinite($actual[$i]) -or -not [float]::IsFinite($expected[$i])) { throw [ArgumentException]::new('Nonfinite comparison.') }
            $maximum = [MathF]::Max($maximum, [MathF]::Abs([float]($actual[$i] - $expected[$i])))
        }
        return $maximum
    }
}
