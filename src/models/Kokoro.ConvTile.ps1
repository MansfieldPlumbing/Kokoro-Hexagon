# The caller supplies a channel-first tile with one sample of halo on each side.
# Existing weights are [tap,input-channel,output-channel], without repacking.
param($halo, $weight, $bias)
$dot = Conv1D $halo $weight -Kernel 3 -Stride 1 -Dilation 1
$output = Add $dot $bias
