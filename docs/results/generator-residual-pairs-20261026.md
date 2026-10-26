# Generator residual pairs left out one at a time (syllabus port)

Kokoro-Hexagon `e1ef4ae`, Student `-Step Residuals` on the host syllabus port (the stock-Kokoro reference), `af_heart`.

## Method

- Input: one syllabus stretch of 130 ticks (1.625 s), the first held-out stretch of the normalization study
  (`generator-normalization-sm8550-20261026.md`), rendered by the port's generator alone from the stretch's own x and
  f0, with the port's seeded source draws.
- Each generator resblock is three residual pairs, `x = x + convs2(snake(adain2(convs1(snake(adain1(x))))))`: 18 pairs
  in `resblocks.0-5` and 6 in the source branch's `noise_res.0-1`.
- Each pair's correction is left out in turn (the stream passes unchanged); the render is scored against the full
  render: PCM SNR, RMS and the change in harmonic-to-noise ratio (as defined in the normalization record). Nothing is
  retuned. Parameters are the pair's two convolutions (channels x channels x kernel each).

## Result

Full render: RMS 0.0436, harmonic-to-noise ratio 7.57 dB; each render 6.5 s on the host.

| Pairs | Channels, kernel | Parameters (3 pairs) | PCM SNR with one pair left out |
| --- | --- | ---: | --- |
| `resblocks.3` | 128, 3 | 294,912 | 13.92 to 17.35 dB |
| `resblocks.0` | 256, 3 | 1,179,648 | 12.38 to 14.62 dB |
| `resblocks.4` | 128, 7 | 688,128 | 9.83 to 11.98 dB |
| `noise_res.1` | 128, 11 | 1,081,344 | 4.57 to 13.46 dB |
| `noise_res.0` | 256, 7 | 2,752,512 | 4.95 to 10.39 dB |
| `resblocks.2` | 256, 11 | 4,325,376 | 4.77 to 7.94 dB |
| `resblocks.1` | 256, 7 | 2,752,512 | -0.34 to 2.46 dB |
| `resblocks.5` | 128, 11 | 1,081,344 | -1.06 to 1.71 dB |

Leaving out `resblocks.5.2` lowers RMS from 0.0436 to 0.01 and the harmonic-to-noise ratio by 12.21 dB. With any other
pair left out RMS stays between 0.03 and 0.05 and the harmonic-to-noise ratio moves by at most 2.24 dB.

## Observations

- **No pair is negligible at the waveform:** the smallest loss is 17.35 dB.
- **Parameter count and effect do not follow each other.** `resblocks.2` holds 4.3 million parameters and leaving out
  one of its pairs costs 4.8 to 7.9 dB; `resblocks.1` and `resblocks.5` cost the most.
- **The stage-1 wide kernel carries voicing:** its last pair is the only one whose removal collapses level and
  harmonicity.

## Not yet done

- Several pairs left out together, and whether retuning each site's K and M against the full render recovers the loss.
- The correction-to-stream ratio per pair (the trace returned nothing in this run; fixed in `e1ef4ae`).
- The same study on the phone's depth-first generator.

Receipt: `build/generator-residuals/run-20261026T163941/residuals.clixml`, with a WAV per left-out pair.
