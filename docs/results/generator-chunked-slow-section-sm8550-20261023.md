# Generator 256-channel section, chunked schedule with streamed weights (SM8550)

Kokoro-Hexagon `f922924`. Case `generator-tile-equivalence -Parameters @{Channels=256}`; receipt
`build/generator-tile-equivalence-20261023T075845/equivalence.clixml`.

## Method

The 256-channel section (`resblocks.0-2` and their mean) is too large to keep resident: its weights are 8.26 M at one
8-bit plane, which leaves no room in VTCM for its working buffers. The chunked schedule (`-Schedule Chunked` in
`src/jobs/Kokoro.Generator60x16Run.ps1`) uses the backward convolution geometry of the 128-channel section. Each step
runs a block of 4 tiles through the six stages in order:

- DMA brings the stage's three branches' weight planes into one VTCM buffer (synchronous, before the fill).
- The AdaIN and Snake fills run one tile per HVX thread, and so do the plane combines.
- The main thread runs the three convolutions over the block.
- Each branch and plane has one conv-input buffer (two history tiles, then the block) shared by the six stages. A
  stage's two saved history tiles are copied in before its convolutions, and the block's last two tiles are copied out
  after them.

The reference is the layer schedule on the same fixture
(`speak-20261010-h0-fast/job-input/g256-fixture-20261008`, 1,700 frames, 54 tiles). Both jobs use int8 weights
q = round(w / 256) in the high plane, with supplied (constants) AdaIN values.

## Result

| Job | DSP ms (median of 3) | VTCM bytes | Library bytes | Library SHA-256 |
| --- | ---: | ---: | ---: | --- |
| Layer (reference) | 17.90 | 6,356,992 | 442,612 | D035143B... |
| Chunked, blocks of 4 | 18.50 | 7,471,104 | 499,956 | D7F943A7... |

Output tensor byte-identical, SHA-256 E77CBADEEB65182B9A4B062C3CEB23748FCE21791BD6DE83904D070D9CF76699. VerifyEmission:
60 of 60 match the baseline.

## Not yet measured

- Time per category (`-PmuSplit` has not been run on this schedule).
- Weight DMA overlapped with the previous stage's work (double buffer).
- The controller contact on this schedule. The code path is built but has not been run.
- Blocks larger than one tile per thread.
