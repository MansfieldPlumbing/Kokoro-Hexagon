#requires -Version 7.4
# Incomplete two-node decoder scaffold. This is parsed for graph identity only;
# it is not executable Kokoro synthesis. Inputs are prepared acoustic tensors.
param($asr, $F0_curve, $N, $style, $gb, $har8, $mask, $mask8, $capacity)
$x0 = KokoroFront $asr $F0_curve $N $style $mask $capacity
$audio = KokoroGenerator $x0 $gb $har8 $mask $mask8 $capacity
