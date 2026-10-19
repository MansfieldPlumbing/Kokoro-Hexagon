# First bank-front-end DSP sentence, SM8550 — 2026-10-10

Network-free Kokoro variant, voice `af_heart`: “I can eat a peach for hours.”
Base commit `ca71f33fa26341b86f2a34b31bf7148362cfc3e5` plus this change.
Emitted DSP source key `B0DBB29078742B3A127DC36C572797868DDAA2BB196DF27796E92A90CE903A36`.

## Result

| Measurement | Result |
| --- | ---: |
| Decoder / generator frames | 85 / 10,201 |
| PCM | 51,000 samples, 24 kHz mono, 2.125 s |
| Median DSP execution, three runs | 148.495 ms |
| DSP-only RTF / speed | 0.06988 / 14.3× |
| PCM SNR against the matching teacher | 31.29 dB |
| Clipped samples | 0 |
| Requested VTCM / measured SM8550 capacity | 8,126,464 / 8,388,608 bytes (7.75 / 8 MiB) |
| Convolution batch / HVX threads | 14 tiles / 4 |

All three runs: `InvokeRc=0 Stage=7 Done=1`, identical PCM. DSP ticks were
2,823,952, 2,858,130 and 2,851,099. Host invoke times were 186.503, 179.449 and
179.790 ms; these are separate from DSP execution and are not end-to-end latency.

AAudio receipt: `Played=True`, 51,000 frames written, drain complete, zero xruns.
`Passed=True` and `StartupRestored=True`.

The retry played on the SM8550 speaker. The earlier run with no sound was the
failed resource-acquisition attempt below; that attempt never reached playback.
The initial “I” is weak. The aligned files show the assembled stream gives the first `I` two decoder frames
(50 ms), after a 13-frame initial boundary. Teacher and DSP first exceed absolute
amplitude 0.001 at samples 6,977 and 6,976, and 0.01 at the same sample 7,477. RMS
over 300-350 ms is -45.39 dBFS in both; over 350-400 ms it is -41.22/-41.23 dBFS.
This establishes a shared short, quiet onset in the matching assembled-input teacher
and DSP files. It does not establish original stock front-end behavior or exclude
an additional playback effect. Diagnose phoneme/stress, duration and native Zira
reference evidence before changing the phonemizer or prosody tables.

Native Windows `Microsoft Zira Desktop` on the same phrase is the candidate
reference for sentence-initial “I” pronunciation and prosody only, not for Zira's
entire output. The correction is to be learned in the existing prosody
controller and evaluated on untouched holdouts. No correction has been trained or
applied. If this diagnostic enters training, it no longer counts as held-out evidence.

Keep both native event times: for `a͡i`, `Duration` is 100 ms, `AudioPosition`
is 137.0625 ms and the following `k` starts at 274.875 ms (137.8125 ms apart).
For the whole phrase, durations sum to 2,315 ms, the WAV contains 2,314.150 ms,
and last `AudioPosition + Duration` is 2,905.625 ms. These are conflicting
reported clocks, not interchangeable acoustic boundaries or proof that length
causes the clarity difference. This matches the timebase caution in
[the earlier Zira substitution receipt](prosody-substitution-zira-20261010.md).
The weak opening is shared by the matching assembled-input teacher and DSP;
an original-stock-front-end defect remains unproved. Stock numerical parity and
admitted pronunciation quality remain separate checks.
The Zira WAV is preserved separately at
`data/references/zira-peach-onset-20261010/speech.wav` (102,100 bytes, SHA-256
`1B009F5660DAA527F6BBA203F4612AE217F7ECECC788EB8060AD10C444300A59`).
The frozen 26-file DSP baseline is unchanged.

## Scope and reference

The bank front end assembled `asr`, F0 and N on Windows. The phone executed the
connected decoder, harmonic source, generator and PCM path, then played its output.
This is the first integrated sentence from this network-free front end; earlier
stock-input connected speech remains a separate baseline. The lowered selector,
on-phone front-end pipeline, bounded streaming and first-audio latency are pending.

The teacher is pinned stock Kokoro `dfb907a02bba8152ca444717ca5d78747ccb4bec`, with
the assembled tensors substituted at the decoder's input by an optional pre-hook.
Decoder/generator math is unchanged. Target style is `af_heart` row `pack[25]`
for 26 phonemes, seed 17. Capture-derived tables and scales belong to this input;
this is not a deployment-calibration or original-stock-front-end quality claim.

`Speak` verifies the working bank against its 200-file manifest, assembles the
held-out input, makes matching captures, uses `New-KokoroJobInput -CaptureMap`,
emits the existing connected job and requires a successful restored phone receipt.
The preserved `data/unit-bank/` copy was never written. `Verify` does not check
bank integrity; the separate bank checks passed for all 200 files.

## Resource failure and correction

The 22-tile plan requested 8,650,752 bytes (8.25 MiB), exceeding the measured 8 MiB
capacity. All three invocations stopped at `Stage=2 Done=0`, before the connected
job or AAudio. Startup restoration succeeded. The wrapper now rejects failed
receipts instead of treating returned output bytes as success.

The 14-tile plan fit the same complete utterance in 8,126,464 bytes. Inputs, style,
phonemes and sample count were unchanged; no shortened sentence or audio crossfade
was needed. `Speak` checks the emitted VTCM requirement before phone dispatch.
Runtime capacity query and automatic replanning remain deferred work in
[the graph tiling design](../vtcm-aware-graph-tiling-design.md).

## Preserved baseline

Local frozen bundle: `data/baselines/network-free-peach-sm8550-20261010/`, ignored
by Git and outside build cleanup. It contains the exact emitted library and layout,
packed input and reference PCM, device receipt and raw output, WAV, assembled
front-end tensors and run result. File lengths and
SHA-256 values are recorded in the adjacent versioned manifest. This is a verified
local copy; no off-machine backup is established by this receipt.
The [PowerShell data manifest](bank-front-end-sm8550-20261010.manifest.psd1) covers
26 files, 121,458,681 bytes. Ratchet verifies every listed artifact before phone
execution. The original run record is retained verbatim, with the later listening
assessment in its own artifact.

| Artifact | SHA-256 |
| --- | --- |
| Emitted library | `FEFF54DF8340F184FA909C35CFEE48D3F0010F8B37E7C7F0967759403F9672A5` |
| PCM int16 samples | `E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054` |
| Assembled-input descriptor | `8084E443917E5AB31960CFCCC9010340C62D0F369D9E1B8C429085C9A7FF6F93` |

Ratchet case: `network-free-peach-sm8550`, initialized from this measurement with
31.29 dB floor, zero clipped samples, 148.495 ms ceiling, existing 3% timing-noise
allowance and the exact PCM hash. Its input is the preserved packed fixture.

## Verification

- Assembled durations and all 43,860 float32 input values exactly match the
  existing bank reference assembly (maximum absolute difference zero).
- Fresh default decoder capture retains all 167 earlier tensor hashes.
- Optional substitution passes hook ordering, exact-input/style preservation,
  negative unvoiced F0 preservation and invalid hash/shape/voice/frame/path rejection.
- Direct selector reads retain donor paths and run counts on all nine held-out
  cases with a 1,000-sentence bank slice.
- `Verify` passes. Phone results and listening above establish this sentence only.
- The new ratchet repeats the same PCM hash at 146.721 ms, 31.29 dB, zero clipping:
  one case run, zero regressions. Manifest corruption is rejected before phone execution.
- Typed PowerShell capture data reproduces all 167 decoder tensor hashes. `Speak`
  returns a typed result and avoids serializing/reloading its in-process front-end data.
