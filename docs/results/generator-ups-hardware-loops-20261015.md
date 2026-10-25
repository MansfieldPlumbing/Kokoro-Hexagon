# FP16 upsampler phase connections and hardware loops, 2026-10-15

No numerical STOP condition. These are upsampler and convolution-loop component
gates, not completion of the main path or whole-generator PCM admission.

Worktree: `Kokoro-Hexagon-generator-templates`, branch
`generator-templates`, parent `7cce7662d829d17af961c4b27d75aa3cc9ddf06a`.
Nothing was pushed. Inputs and reference identities are the preserved dog capture,
checkpoint and admitted offline numeric assembly recorded in
`generator-main-fp16-stamps-20261014.md`.

## Connected upsamplers

Each job executes every phase convolution, then repacks their native FP16
croutons into chronological croutons in VTCM. The phase and handoff loops use
hardware loop 1; the convolution and handoff callees use hardware loop 0.
The last stage includes its leading reflection sample by copying chronological
column 2 into column 0. The final graph-length sample and tail remain part of
the unfinished whole-generator connection.

| Layer | Input positions | Output positions | Own-input SNR dB | Peak error | Run-0 HMX ms | Run-0 issued TMAC/s | Five-warm median HMX ms | Five-warm issued TMAC/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| ups.0 | 32 | 320 | 73.11565978 | 0.004551887512 | 0.03630208 | 3.46616801 | 0.04031250 | 3.12134251 |
| ups.1, leading reflection included | 160 | 960 | 72.71783637 | 0.002223014832 | 0.02416667 | 3.90504166 | 0.02651042 | 3.55980222 |

The float reference consumes decoded FP16 device inputs and original float
weights. Both chronological native handoffs are byte-exact against repacking
their own actual device phase outputs. All decoded outputs are finite.
Six invocations use the same diagnostic handle; warm medians use runs 1–5.
The HMX timer sums only the phase convolution calls and synchronization,
excluding phase-weight DMA and chronological packing. Rates count three issued
taps per phase, including a zero tap, rather than counting only useful taps.

Stage A uses captured `gen.input_x`, followed by the original leaky activation.
Stage B uses the mean of captured resblocks 0–2, followed by that activation.
This is not a connection from the new stage A to the new stage B. The original
independent stage-B phase probes used 32 input positions; their conditions differ
from this 160-position test. No speed improvement is inferred across those runs.

| Artifact | Library SHA256 | Code bytes | VTCM bytes |
|---|---|---:|---:|
| ups.0 | `3776AF7F2AE5B32F455732A35FEAF342CA6993CF28E10B4621359E68E63B9026` | 14,412 | 1,376,256 |
| ups.1, leading reflection | `57C124C2C71867ED93D3AB5049194E7A1824A09B86CD0EDFADDD4036995CDC33` | 6,168 | 917,504 |

Native packed-output SHA256 values:

- ups.0: `EAD7F5EAE4C07F02EF3D84EE0352F47EA760B8949BF8BA94B08B7205187C249B`
- ups.1: `389B42B2B695C17CF1D127EED4560D5C0992B07FF8F4D6D7331B3BAB085D0CB5`

Artifacts, native outputs, phase gates, timing records and own-input references
are in `build/generator-templates/ups0-connected-joined1/` and
`build/generator-templates/ups1-connected-reflected1/`. These jobs produce no PCM
or WAV. Whole-generator DSP time, cycles per 300 samples and loudness are unmeasured.

## Convolution loop-control parity

The FP16 convolution tile loop now uses loop 0. On the phone, the connected
resblocks.3.convs1.0 / convs2.0 lock diagnostic retains exactly the same three
decoded native outputs as `lock-warm-both-layers-20261015`: convolution, activated
operand and consumer. File SHA256 comparisons of all three `part*.f32` files
pass. The lock operand remains 73.75686728 dB against its own equations.

| Layer | Own-input SNR dB | Run-0 HMX ms | Run-0 TMAC/s | Five-warm median HMX ms | Five-warm median TMAC/s |
|---|---:|---:|---:|---:|---:|
| resblocks.3.convs1.0 | 70.93992187 | 0.01364583 | 3.45789948 | 0.01442708 | 3.27064861 |
| resblocks.3.convs2.0 | 71.99225824 | 0.01473958 | 3.20130623 | 0.01416667 | 3.33077082 |

Library SHA256:
`073B908373685853135168C9D74B154ABB0FF5B8B19B9726F4B88DFE05782683`,
7,248 code bytes, 1,572,864 VTCM bytes. Artifacts and the partial offline-continuation
WAV pair are in `build/generator-templates/lock-hardware-loop0-20261015/`.
`stock-then-template1.wav` is stock first, 0.6 s gap, 16-bit mono, 24 kHz.
The baseline and candidate use identical input, weight and table conditions;
their emitted loop-control code differs. Timing variation does not establish
a speed improvement. No arithmetic work has been hand-bundled.

## ISA evidence and reproduction

Register-count loop encodings come from V73 PRM 80-N2040-53 Rev. AB, page 195.
Page 146 states: "The last packet in a hardware loop 0 must contain two or more instruction words."
Loop 1 requires at least three words. The emitted loop-end packets use preserving
adds only; the arithmetic bodies retain their existing packet boundaries.
The same artifacts passed the pinned SDK assembler byte comparison before
execution. General SDK/API portability is unverified.

Commands from the worktree, with fresh output names for repeats:

```powershell
& ./build/generator-templates/check-ups-connected.ps1 -Stage 0
& ./build/generator-templates/check-ups-connected.ps1 -Stage 1 -RunLabel reflected1
& Pwsh-Development/tools/board.ps1 Lock -Agent Codex -Reason 'Admit FP16 convolution hardware loop 0'
try {
    & ./Invoke-KokoroDevelopment.ps1 Run -Case generator-template1 -Runs 6 -Soc SM8550 -Parameters @{
        ConnectedConsumer=$true; Shape='Lock'
    } -OutputDirectory Kokoro-Hexagon-generator-templates/build/generator-templates/lock-hardware-loop0-20261015
} finally {
    & Pwsh-Development/tools/board.ps1 Unlock -Agent Codex
}
& ./Invoke-KokoroDevelopment.ps1 Verify
```

The one-time upsampler probe, retained under ignored build output, also takes and
releases the board lock in a finally block. Startup restoration passed after
each phone session. Device identifiers and unrelated logs were not collected.
Protected captures, manifests, pins and frozen receipts remain unchanged.
Unrequested product scope: none. Main-resblock residual connections, streamed
source addition, the tail and whole-sentence admission remain unfinished.
