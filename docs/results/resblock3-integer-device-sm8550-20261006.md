# Connected integer resblocks.3 on SM8550 — 2026-10-06

Baseline `8cc06b96e9dd5546dfd76da40f59967be55d1789` plus local uncommitted
sources. One PowerShell-emitted DSP proof job executes all six live
AdaIN → Snake → W8A8 convolutions and three residual additions. Each AdaIN
uses the complete preceding group; kernel size 3, dilations 1,1,3,1,5,1.
HMX stages eight time tiles with real neighboring halo rows. Native layout
is preserved; five full-group buffers reside in shared DDR, HMX operands in VTCM.

The wrapper's bytes match SDK 6.4.0.2 assembly. Its eight numerical bodies
are byte-for-byte unchanged from their earlier checked artifacts. The same
emitted ELF images execute in V73 simulation using reference-only API shims,
then through the existing debuggable application's FastRPC probe on SM8550.
The shim contains no model arithmetic. Four malformed admission cases
(wrong tile count, short input, null input, short output) return error 14
without changing telemetry. Power/HVX/HMX lock return codes are zero on phone.

| Encoding fixture | Valid frames | Phone versus connected reference | Median DSP region ms | Invoke wall ms, runs 0–2 |
|---|---:|---|---:|---|
| full-range | 7801 | 3/3 exact | 211.991 | 226.319, 224.502, 222.675 |
| histogram-mse | 6601 | 3/3 exact | 179.500 | 189.526, 198.286, 193.204 |

Each run has zero differences across the entire returned native tensor, and
zero byte differences across all six live AdaIN coefficient sets (1,536 int32
values). Both simulator wrapper runs independently match the prior connected
fixtures. The full-range fixture uses af_heart's original 7,801-frame capture;
histogram MSE uses the separate af_heart 6,601-frame holdout and frozen pilot
encodings. These are different inputs, so this table is not a direct timing or
quality A/B. Numerical comparisons against stock remain in the earlier
connected-block and calibration receipts; matching hardware does not establish
audio quality or erase the histogram candidate's larger peak errors.

DSP ticks are 19.2 MHz and cover the connected region including its stage
copies, after initial input staging. Invoke time additionally includes resource
acquisition and the diagnostic output workspace transfer. The firmware granted
524,288 bytes of VTCM. This correctness runner uses blocking copies and one
synchronous invoke; it is not persistent dspqueue dispatch or DMA ping-pong.
Startup files and any replaced files were backed up, restored, and startup
hashes verified by both host runs. Generated staging and backups are retained.

## Artifact identities

- full-range ELF: `30FA86379E8F8DB9497E66FDE8D493717121CD954CEED576F8B2BC1326A1A6E4`; returned native tensor: `F0C28C628BFE6B4C420A01734F6DCE6991B9D9345A1F76B069B8EA9762E8EA28`.
- histogram-mse ELF: `BCB872D7A59FCAFF39FE12B02BA18C09E5CE3D2404AB7DD99798FF832A2A0198`; returned native tensor: `6C9B184615FE268633A162E921B331BAD03C908042EEADDBFF7D3342FD6AEEAE`.

Stock source: `dfb907a02bba8152ca444717ca5d78747ccb4bec`.
Checkpoint SHA-256:
`496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.
Raw receipts and simulator outputs live in the matching ignored
`build/connected-device-*` directories. Reproduce with
`Test-HexagonEmission.ps1 -Kernel KokoroResBlockRun -ResBlockFrames <frames>`,
`New-KokoroResBlockRunFixture.ps1`, `Test-KokoroResBlockRunner.ps1`, and
`Invoke-ResBlockRunProbe.ps1` using the same frames and frozen fixture.

## Generator integration state

`Export-KokoroGeneratorCapture.ps1` captures original stock modules and STFT
methods without reimplementing generator math. The full generator capture
contains 636 hash-verified tensors: input `[1,512,130]`, both upsamplers,
six main residual blocks, two source residual blocks, final spectral outputs,
and reference waveform `[1,1,39000]`. All 548 checkpoint tensors load exactly.
Capture manifest SHA-256: 0368106F82F7656AB32EDEDBB9F42BE462EAC2C67612EDF2586758EA68BAC082.

The connected resblocks.3 phone gate is now established. Remaining work is
the other generator channel/kernel shapes, transposed convolutions, source
path, branch averaging, spectral nonlinearities and iSTFT, followed by the
front half and AAudio speech. No whole-generator RTF, TTFA, speaker-playback
or SM8635 result is established by this receipt. SM8635 is not attached.
