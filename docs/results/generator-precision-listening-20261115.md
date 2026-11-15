# Generator activation precision by ear: 8-bit convolution inputs are about the same as float on laptop speakers; 8-bit outputs are not (2026-11-15)

Branch `live-adain`, Kokoro-Hexagon `4ffe2fd`. One listener, two passages, host emulation. Clips and renders:
`build/listen-planes-20261115/` (`index.html` with twelve players, the 16-bit WAVs, the float32 renders,
`renders.log`). Scripts: `Invoke-PlaneClips.ps1` and `PlaneMath.ps1` in the receipt's `scripts/`, not tracked in the
repository.

**Result.** Scott: "8 bits in (one byte plane into each convolution) is okay anything less sucks". Then: "not
endorsing it over full float just saying its about the same on my shitty laptop speakers. full float may still be
better". So one 8-bit plane into each convolution, with a range per channel and wide outputs, was not told apart
from float on laptop speakers. Rounding the outputs to 8 bits, or sharing one range across a tensor's channels, was
audibly worse. No pass mark was adopted.

## What was played

Windows `0EF936E1DE6E` (passage A, 11.97 s) and `0730765847E8` (passage B, 6.28 s), voice `af_heart`, generator only,
teacher x and F0, port seed 17, stock normalization. The host port's convolution was wrapped so that the input, and
optionally the output, of each of the generator's 53 convolutions is rounded onto equal steps between that tensor's
least and greatest value in the render. Weights, AdaIN, Snake, the residual sums and the tail stay float32.

| Label on the page | Inputs | Outputs | Range | PCM SNR against float, passage A | Passage B | Scott |
| --- | --- | --- | --- | ---: | ---: | --- |
| Stock Kokoro | float | float | | | | reference |
| 16 bits in and out | 65,536 levels | 65,536 levels | per channel | 53.17 dB | 54.86 dB | no remark |
| 8 bits in | 256 levels | float | per channel | 18.12 dB | 20.24 dB | "okay" |
| 8 bits in and out | 256 levels | 256 levels | per channel | 6.62 dB | 7.81 dB | "sucks" |
| 8 bits in, one range per tensor | 256 levels | float | per tensor | 10.81 dB | 11.56 dB | "sucks" |
| 4 bits in and out | 16 levels | 16 levels | per channel | -18.76 dB | -13.75 dB | "sucks" |

The 4-bit clip rendered 18.76 and 13.91 dB louder than stock and was turned down to the stock level for the page.

## Controls

- With no rounding, the wrapped port's PCM equals the stock render of passage B byte for byte.
- Every arm reports 53 convolutions through the wrapper, the count in `generator-plane-depth-20261007.md`.
- The 4-bit clips are there so that one clip should clearly differ; Scott heard them as worse.

## What follows

- The input side of each convolution may not need a second byte plane. The stored side does: what a convolution
  writes, and so the stream between convolutions, has to stay wider than 8 bits.
- A range per channel matters. One range per tensor at the same 8 bits was audibly worse.
- This agrees in order with the 7 October reference study, which used one range per tensor: 8-bit stored tensors cap
  the result, and inputs are the cheaper place to save.

## Limitations

- Laptop speakers, one listener, one sitting, two passages, one voice, labelled clips. Scott did not endorse 8-bit
  inputs over float; a better playback chain may separate them.
- Emulation on the float32 host port. Weights are float: an 8-bit input with a range per channel has to fold each
  input channel's step into the weights, and with int8 weights that costs weight precision. Not emulated.
- The ranges are each tensor's own extremes in the same render, the best case. A build needs ranges fixed in
  advance.
- Nothing here is the phone, HMX, or the generator's integer path, and no time was measured.
