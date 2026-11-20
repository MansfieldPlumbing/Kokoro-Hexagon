# SM8550 rounded generator throughput

On the 11.775-second lighthouse generator fixture, 125× DSP real time requires a warm median of 94.200 ms. Each primary trial runs 13 calls and excludes the first call from the median. The second seed uses four warm calls after one cold call. The DSP timer runs at 19.2 MHz. These measurements cover 282,600 samples of 24 kHz PCM. Host invocation time is recorded separately in the [per-call results](../../tools/experiments/generator-throughput-20261119/rounded-125x-runs.csv).

| Variant | Primary A, ms | Primary B, ms | Second seed, ms |
|---|---:|---:|---:|
| Auditioned rounded control | 96.510 | 96.742 | — |
| Hardware loops and one publication fence | 95.880 | 95.469 | 95.066 |
| Ring parity, wrapping double and halfword shuffle | 92.703 | 93.334 | 94.128 |
| Ring with single-shift rounding bias | 92.815 | 92.718 | 93.307 |
| Ring storing only the consumed activation planes | **91.928** | **91.874** | **91.733** |

Each successful call matched the full PCM hash for its seed from the auditioned section-rounded-keep256 generator. That generator preserves full precision in the 256-channel main section and rounds activations elsewhere. Its output differs from the full-precision reference. Every listed trial verified the staged DSP library and restored the phone startup files.

The ring patch assigns the two ring halves by parity and replaces two vector shifts in Snake with a wrapping halfword add and an even-halfword shuffle. The rounded generator still needs scalar r10 for its rounding bias. Dropping its initialization, as in the exact-generator patch, failed the primary waveform check. The bias variant shifts 16,384 right seven places in one instruction to produce the same 128.

The high-plane variant branches from the ring variant. In one-weight-plane sections whose HMX kernels skip the low activation plane, Snake omits the low-byte shift, store and mirrored store. The 256-channel main section retains both planes. Two primary medians reached 128.09× and 128.16× DSP real time. A fresh experiment checkout reproduced library SHA-256 8BB0ABBB01F12849DCDD158158EEC3C3FC54FF0D66108F721CBB047F592E63C3.

Reproduce from the repository root with a fresh destination and the existing lighthouse fixture. The variant names are section-rounded-loops, section-rounded-ring, section-rounded-bias and section-rounded-high.

~~~powershell
$tools = './tools/experiments/generator-throughput-20261119'
$tree = 'C:/dev/kokoroku-125x-rebuild'
& "$tools/New-ExperimentCheckout.ps1" -Variant section-rounded-high -Destination $tree
& "$tools/Export-ExperimentGenerator.ps1" -Checkout $tree -OutputDirectory "$tree/build/emit"
& ./tools/Invoke-GeneratorTailProbe.ps1 -EmissionDirectory "$tree/build/emit" -FixtureDirectory (Resolve-Path ./build/lighthouse-60x-20261119T092441/fixture) -Runs 13 -CapturePcm -ExpectedPcmSHA256 44064819B5BC7F2FF04F481A4CB0CD39A563679ED1D8B9CCAAEE3FACE8CD87B1 -Adb C:/dev/pwsh/scripts/adb.ps1
~~~
