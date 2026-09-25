# Elementwise graph used by the R0Sub0 HVX benchmark specialization.
# Constants are explicit inputs so the backend cannot reassociate floating-point operations.
param($z, $gain, $shift, $mask, $alpha, $inverseAlpha, $one, $cubic)
$scaled = Mul $z $gain
$affine = Add $scaled $shift
$y = Mul $affine $mask
$u = Mul $y $alpha
$u2 = Mul $u $u
$cubicTerm = Mul $u2 $cubic
$polynomial = Add $one $cubicTerm
$sine = Mul $u $polynomial
$sine2 = Mul $sine $sine
$correction = Mul $sine2 $inverseAlpha
$output = Add $y $correction
