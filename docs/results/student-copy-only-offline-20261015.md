# Student COPY-only listening gate, 2026-10-15

All nine held-out selected sentences were rendered before building the climber.
Each selected unit is replaced by its measured best real other exemplar, with
no RESIDUAL. The full-bank measurement is recorded in
`student-structure-offline-20261015.md` (implementation `98a5267`).

Both sides run the existing offline decoder and generator over the complete
selected target sequence. Original-unit durations, F0/N, af_heart style row 25,
live AdaIN, seed 17, source draws and four convolution workers match. The
original is the selected real t_en sequence; it is not stock fresh-text speech.
Previously generated B WAVs joined cached donor decoder slices and have a
different decoder boundary; they are not the reference for this comparison.

Run through the owning entrypoint:

```powershell
& ./Invoke-KokoroDevelopment.ps1 Student -Parameters @{Step='Render'; Replay='CopyOnly'} -OutputDirectory build/student-copy-nine-20261015-r2
```

Each `NN-original-then-copy.wav` is mono 24 kHz PCM16: original, 0.6 seconds of
silence, then COPY. Singles are also retained. No gain normalization or alignment
shift. Conversion rounds ties to even and saturates to signed int16. SNR uses
the original's energy; float PCM is compared before conversion and PCM16 after.

| # | Sentence | Audio s | Float PCM SNR dB | PCM16 SNR dB |
| --- | --- | ---: | ---: | ---: |
| 1 | I can eat a peach for hours. | 2.050 | 13.00973 | 13.00982 |
| 2 | She left her keys on the kitchen table again. | 2.925 | 10.71854 | 10.71858 |
| 3 | Please call me when you get home tonight. | 2.650 | 15.10204 | 15.10204 |
| 4 | My brother plays the guitar in a small band. | 3.000 | 16.56985 | 16.56993 |
| 5 | We should plant more trees along the river. | 2.850 | 16.25365 | 16.25360 |
| 6 | The children laughed at the funny little dog. | 2.875 | 15.53106 | 15.53108 |
| 7 | He forgot to bring an umbrella this morning. | 2.675 | 14.00753 | 14.00752 |
| 8 | Our train was late, so we missed the meeting. | 3.100 | 13.94702 | 13.94704 |
| 9 | There is a bakery on the corner of my street. | 2.825 | 15.56427 | 15.56434 |

These PCM measurements do not set
the climber's feature-domain 46/70 dB acceptance bars.

## Timing conditions

One Windows offline FP32 decoder+source+generator render per variant, original
first. Timers surround alignment, decoder and generator; WAV conversion/writing
is outside. Weight caches warm as the run proceeds. These are host measurements,
not DSP benchmarks, and do not establish a hardware speedup or regression.

| # | Original host ms/audio-s | COPY host ms/audio-s |
| --- | ---: | ---: |
| 1 | 12482.57 | 13476.93 |
| 2 | 11766.05 | 12815.94 |
| 3 | 11889.31 | 11241.21 |
| 4 | 11684.41 | 12393.62 |
| 5 | 13881.34 | 15361.51 |
| 6 | 16178.99 | 15546.02 |
| 7 | 15478.13 | 15474.72 |
| 8 | 15214.28 | 15820.85 |
| 9 | 15560.79 | 15078.23 |

The requested approximate old int8 whole-utterance generator reference is
85 ms / 2.125 s = **40 ms/audio-s**, about 25x. The preserved separate-generator
run is 89.076 / 2.125 = **41.918118 ms/audio-s**, a single run. The cited
`peach-combined-constants-sm8550-20261012.md` instead records decoder plus
source/generator together: “DSP region, median of five warm runs | 99.593”,
or **46.867294 ms/audio-s**, and `ResidentHvxThreads=4`. Device, precision,
stage coverage, input provenance and warm-run conditions differ from this test.
Four-thread HVX restoration remains required before bundling; no bundling or
phone run occurred here.

## Provenance and verification

Protected inputs were read only. The existing reference's source and assembly
pins are checked before loading its functions. No new reference implementation
or harness; no raw feature/control tracks, Python, new JSON, worktree or push.
Nearest IDs are reused; the full-bank search is not rerun.

| Artifact | SHA256 |
| --- | --- |
| Offline reference source | `8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257` |
| Offline reference assembly | `446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D` |
| Student native kernels | `94B64762E203394CD8E69762DD3F0D72DE783AC2016D1C1AD76A90C6384AF0A9` |
| Reused nearest.i32 | `70DFD110F8B8E2A8EBDFC2507357727F04BAB0E2A974E51E340E1A9EE8D914AA` |
| COPY ID programs CLIXML | `E67BD2685C5A78387E8651869984C9953AF7CCEB1EA5160905A3FA1248E30EC4` |
| copy-render.clixml | `B2CF68008D0A5EE06A226B3327F15863320949DFAC0FA2894BBD5CD248A75017` |
| 01 pair | `C5A2E129FD77466D4EF802CEC31693D18C2AC6A0E86035B0B81AD3AACE88FD84` |
| 02 pair | `0825525E06FC5B47E59859DC6EFCAD8582DFAD11526C6577A5E1AB95262B4F7C` |
| 03 pair | `7CF53F21C20CFF0A03D32E3585AB2506E70D9A5DBFD24376BF673C96C4513F2E` |
| 04 pair | `625ACB11E29C6B9D7EC8A87A8B031598F46BADD5181F8BF19EEF7967E65C3CD4` |
| 05 pair | `3E57DE42528FD3E967BBF305E4289DA3F130A2DD1E17C6B5A1D7681545A8C966` |
| 06 pair | `9C2CF99AA82383260018E8C1587CBB3055EF855B038B2F648401F170417D89BF` |
| 07 pair | `08380F3CDE8E5BEE399F6D22018B7F56B1670FD76986CC8B12C071CCECA5BB29` |
| 08 pair | `312E95CFAE6920446C5848F2C22FF7BAF86C578B956999A4AC5D3120C3C7ADE7` |
| 09 pair | `9F8088013356A091B45E0BDBB4C4E61BD183CC3DC64893BC7CE2A81E20433A43` |

The pinned PSLowering compiler admits CLR-only Student kernels. Native fixtures
check feature expansion, exact nearest selection/ties/self-exclusion and real
direction selection; PCM16 checks include saturation. WAV headers, lengths and
hashes are checked. Verify passes with 35 known and zero new case-pair findings.
An initial automatic-variable naming finding was corrected before commit; the
admitted Student kernel hash remained identical. Earlier profiling WIP is
preserved outside this commit.
