# Real stock resblocks.3 convolution tile on SM8550

Baseline: `8cc06b96e9dd5546dfd76da40f59967be55d1789`, with uncommitted
reference-capture, packing, probe-output, and integer HVX statistics changes.
The HMX convolution and resource-runner functions are unchanged. Both emitted
bodies matched SDK 6.4.0.2 assembler bytes before execution. After the shared
ISA additions, all 2713 HMX encoder cases still matched, and all 18 invalid
operand cases were rejected. The synthetic SM8550 probe also passed 2/2 runs.

Stock source: hexgrad/kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`.
Checkpoint: `lib/manifest.json`, SHA-256
`496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.
Windows PyTorch `2.14.0+cpu`; all 548 checkpoint tensors were checked against
loaded stock parameters. Phonemes were fed directly to stock KModel, with
`af_heart` style entry 13, speed 1, seed 17. Hooks captured the real
`[1,128,7801]` resblocks.3 input, style, effective weights, and stage outputs.

This measurement covers **convs1.0 only**, C128/K3/D1, 256 output frames
starting at frame 256. Real neighboring rows supply the halo. PowerShell packs
per-output-channel symmetric W8 weights and shared input/output activation
scales derived from the complete captured stage. Those stock reference-derived scales
are a numerical experiment, not a production calibration scheme.

| Check | Result |
|---|---:|
| Phone versus V73 simulator | 5/5 exact, 0/32768 output values different per run |
| HMX dequantized output versus stock FP32 | RMSE 0.0313975; max absolute error 0.1288064 |
| HMX output SNR versus stock FP32 | 32.0683 dB |
| Saturated output values | 0/32768 |
| Ideal quantized convolution versus stock FP32 | RMSE 0.0223399; SNR 35.0246 dB |
| HMX versus ideal output requantization | 1434/32768 values different; maximum 1 LSB |
| Median convolution ticks | 41 at 19.2 MHz; 2.14 us |
| Convolution MACs per call | 12,582,912; 5.8925 TMAC/s |
| Warm invoke wall time, four runs | 0.907-0.965 ms; first call 3.636 ms |

Timing brackets convolution only, with operands resident in VTCM. Full invoke
includes resource/power acquisition and copies. The probe restored startup
files and checked their hashes. SM8635 was not attached and was not run.
The device host was the AndroidSMA preview app's standalone test probe.

## Artifact SHA-256

- Runner ELF: `895BC88B00DC901C5F5A9F16974F68FE07573721D6D70BFE382BA43B8686F7C4`
- Convolution body: `CDF354B8BD396704C76DC40F5E36CA8B6C0DEF133597DCBA68C4A010BDEC75F2`
- Packed activations: `5761767F1D8CBCE45B90F0FDE331AF77A37EBA7D2F57BD1C522D35D410CF6149`
- Packed weights: `757063E2B970E5BB657F91FB94B7C0FCB28149A563274575BDBC1148FB492954`
- Column tables: `3CE89F7F4A58B81BD6A9770BB1CA8BE9247DBF11F24C3FFFB4E76EA118145268`
- Simulator and retrieved phone output: `279E62EBD59549F4DEB63F12DB67AC4E44DC9D64FE008A11E4E8A6B42BC0342F`
- Stock capture manifest: `841FCE39625B65F2676CB1DCFAC9563F281A2E7770FCE2FCD2E6BC9D99F81A4C`

Raw captures and comparisons: `build/stock-resblock-capture-20261006T090954Z/`
and `build/real-resblock-stage0-20261006/`. Device receipt:
`build/real-resblock-stage0-runner-20261006/KokoroHmxConvRun/device-receipt-SM8550-43e4f01cc7cd49fbb73fe375105b6401.txt`.
References: `tools/reference/capture_stock_resblock.py`,
`tools/New-KokoroHmxCaptureFixture.ps1`, and
`tools/reference/compare_captured_conv.py`. The phone expectation is the
simulator output; numerical quality is independently compared with stock
FP32 captures and PyTorch's integer-valued convolution reference.

This is not a connected residual-block quality acceptance or speech result.
Full-group integer HVX AdaIN/Snake, six connected convolutions, three residual
adds, propagated error, and the complete generator remain unverified.
