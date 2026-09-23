# AdaIN affine subgraph from generator.resblocks.3.adain1.0.
# Input is the normalized channel-first tensor. Gain already includes 1+gamma.
# Normalization, the output mask, Snake and convolution are outside this subgraph.
param($normalized, $gain, $shift)
$scaled = Mul $normalized $gain
$output = Add $scaled $shift
