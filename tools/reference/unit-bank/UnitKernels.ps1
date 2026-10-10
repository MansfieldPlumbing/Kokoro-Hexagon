class UnitKernels {
    # npy payload (little-endian int16) to a typed array.
    static [short[]] ToInt16([byte[]] $bytes, [int] $offset, [int] $count) {
        $r = [short[]]::new($count)
        [System.Buffer]::BlockCopy($bytes, $offset, $r, 0, $count * 2)
        return $r
    }
    # Channel-major [C x T] int16 to unit-major [T x C] float32 with per-channel scale.
    static [float[]] UnitMajor([short[]] $src, [float[]] $scale, [int] $channels, [int] $tokens) {
        $dst = [float[]]::new($channels * $tokens)
        for ($c = 0; $c -lt $channels; $c++) {
            $s = $scale[$c]
            $row = $c * $tokens
            for ($t = 0; $t -lt $tokens; $t++) { $dst[$t * $channels + $c] = [float]$src[$row + $t] * $s }
        }
        return $dst
    }
    # Relative squared distance |x-y|^2 / (|x|^2 + |y|^2) between two unit rows.
    static [float] RelativeDistance([float[]] $u, [int] $channels, [int] $a, [int] $b) {
        $pa = $a * $channels
        $pb = $b * $channels
        $d = [float]0
        $n = [float]0
        for ($c = 0; $c -lt $channels; $c++) {
            $x = $u[$pa + $c]
            $y = $u[$pb + $c]
            $e = $x - $y
            $d += $e * $e
            $n += $x * $x + $y * $y
        }
        return $d / $n
    }
    # TargetCost: context mismatch between a target position and a donor unit position in padded phoneme strings,
    # weighted per offset and side (index 1..3). The right-hand weights carry the measured R2 finding.
    static [double] TargetCost([string] $target, [int] $tpos, [string] $donor, [int] $upos, [double[]] $leftWeights, [double[]] $rightWeights) {
        $c = [double]0
        for ($o = 1; $o -le 3; $o++) {
            if ($target.get_Chars($tpos - $o) -cne $donor.get_Chars($upos - $o)) { $c += $leftWeights[$o] }
            if ($target.get_Chars($tpos + $o) -cne $donor.get_Chars($upos + $o)) { $c += $rightWeights[$o] }
        }
        return $c
    }
    # Distances for many pairs: pairs[2k], pairs[2k+1].
    static [float[]] PairDistances([float[]] $u, [int] $channels, [int[]] $pairs) {
        $count = [int]($pairs.Length / 2)
        $r = [float[]]::new($count)
        for ($k = 0; $k -lt $count; $k++) { $r[$k] = [UnitKernels]::RelativeDistance($u, $channels, $pairs[2 * $k], $pairs[2 * $k + 1]) }
        return $r
    }
}
