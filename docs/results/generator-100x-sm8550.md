# Generator exceeds 100× real time on SM8550

The whole-generator DSP region produced 11.775 seconds of audio in **115.71 ms** and **116.04 ms** at the two warm medians. Both candidate series used the same library. A run of the previous 90× release between them measured **130.19 ms**. All 24 warm candidate invocations finished within the 117.75 ms budget for 100×.

| Phone series, in order | Warm runs | Median DSP ms | Warm DSP range, ms | Real-time multiple | Median host invoke ms |
|---|---:|---:|---:|---:|---:|
| Candidate A | 12 | 115.710 | 114.863–116.550 | 101.76× | 156.707 |
| Control from 4697cc3 | 12 | 130.194 | 128.761–131.439 | 90.44× | 169.533 |
| Candidate B | 12 | 116.036 | 115.066–116.657 | 101.48× | 153.609 |

Each series began with an additional cold invocation. All 39 invocations reached stage 7 and matched the reference digest for 282,600 PCM samples at 24 kHz. The multiple uses DSP region ticks at 19.2 MHz. Host invocation includes additional work and has its own column. These measurements apply to one phone and the stock long-passage fixture with seeded noise and host coefficients.

## Changes that paid off

The generator already had four HVX workers. Several stages still ran serially because their input and output pointers advanced by different amounts. The dispatcher now accepts a byte stride per operand. For example, an STFT window task advances 640 signal bytes and writes 8,192 bytes to each activation plane per pair of tiles. A zero stride shares a read-only table. This lets workers split the harmonic merge, STFT window, plane combine and polar conversion, as well as the spectral tail and parts of the upsampling front. The standalone emitters retain their serial path.

In the backward lockstep sections, each worker now publishes its progress after the input window is filled and fenced, its preceding neighbor has published, and it holds the matrix lock. The next worker can proceed while the first combines its output. HMX execution still requires the matrix lock. On its own this change measured 128.81 ms. The final tail also compacts PCM into VTCM and transfers one batch to DDR before applying the two edge corrections.

Two tests helped choose where to spend time. Keeping an output weight group active across tiles gave 129.88 ms. Repacking residual weights into channel-major order gave 129.98 ms. Both matched the reference but landed within the previous release's variation. An alternative harmonic schedule produced a different PCM digest and was discarded. The retained implementation uses the original weights and harmonic arithmetic. The phone timings do not resolve the internal HMX pipeline.

## Reproduction and independent checks

Use the emission command and fixture digests in the [90× report](generator-90x-sm8550.md#reproduce-the-candidate) with the code in this revision. The frame count, four-tile batches, four workers, 120-tile span, power votes and fixture are the same. Use the pinned PowerShell ADB client, serialize device runs, and check both the library and full PCM digests.

| Artifact | SHA-256 |
|---|---|
| Candidate DSP library | `16CBEE7FC4E8B00AD3FE1E3BF9FD636DD4B686DFEA40E3D80B152DCAD1758A45` |
| Control DSP library | `3CA2DCF299E05E6F090C4C218527D8A04C56B6685041544A6D859A82D9728EFE` |
| Stock PCM | `B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF` |
| Second-seed PCM, control and candidate | `B4DDB8805D48110587F1752F7DC4D7A653BE05EB235FE1D201CE4966DA50B52F` |

For the second input, flip bit zero of the first byte at the generator layout's `SourceNoise.InputOffset` in a copy of the activation fixture. The control produced the same new digest on three invocations, and the candidate matched it on three invocations. The host also constructed standalone tail, STFT and harmonic-source jobs for a 61-frame input.

An independent emission from the release source reproduced the measured candidate library byte for byte.

The per-run receipts and CSVs are under `build/rt80-1795102334443/confirm-release100-qualified-114809`. The second-seed receipts are in `second-seed-control` and `second-seed-release` under the same build root. The phone harness verified startup restoration after each series.
