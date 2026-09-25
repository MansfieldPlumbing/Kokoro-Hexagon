#requires -Version 7.4
# Canonical device graph contract. This file is parsed as a model description; it is not
# executed on the device. Inputs name the current fixed-capacity context boundaries.
param($asr, $F0_curve, $N, $style, $gb, $har8, $mask, $mask8, $capacity)
$x0 = KokoroFront $asr $F0_curve $N $style $mask $capacity
$audio = KokoroGenerator $x0 $gb $har8 $mask $mask8 $capacity
