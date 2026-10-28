# DSP power votes and core clock, SM8550 (2026-10-28)

Kokoro-Hexagon at the commit that adds this record (parent `acc6394`). Every job's power lifecycle comes from
`New-KokoroHmxConvRunSteps` (`src/jobs/Kokoro.HmxConvRun.ps1`): HVX power, DCVS v2 with DCVS off, performance mode
and core target/min/max at TURBO, and HMX power. This record measures the core clock those votes give, adds the votes
that were never sent as power lifecycle records, and A/Bs each against the 60-tile span check.

## Method

- Power lifecycle records (`$powerRecords`, `src/jobs/Kokoro.HmxConvRun.ps1`): each record is one `HAP_power_set` or
  `HAP_power_get` request as (offset, word) pairs. Request types, offsets and values come from SDK 6.4.0.2
  `HAP_power.h`. The offsets were checked by compiling `offsetof` expressions with the SDK's `hexagon-clang -mv73`:
  enums are one byte, so the existing DCVS v2 words (option at byte 9, corners at bytes 20-22) are correct as emitted.
  `-PowerVotes` selects records in call order and `-PowerContext Shared` passes one context to every request instead
  of each call's own address. The defaults emit exactly as before.
- Lifecycle telemetry (`Read-KokoroJobLifecycle`): the OR of the vote return codes (telemetry word 16), the HVX and HMX
  lock return codes, the VTCM granted, and, when the `CoreClock` or `HmxClock` query record runs, the clock it returns
  and the query's own return code (words 48-60). The span check and the single-length check report it for every run.
- Core clock from the PMU path: `Run -Case generator-tile-equivalence -Parameters @{Joint='WholeSource'; PmuSplit=$true}`
  (7,801 frames). Per stage, `upcycle` cycles over 19.2 MHz `hwticks` ticks.
- A/B: `Run -Case generator-tile-equivalence -Parameters @{Joint='SpansSource'; Repeat=2; SpanSizes=60; Runs=5;
  PowerVotes=...}` (15,601 frames, 3.25 s of audio, kept settings), one configuration per run, with the clock queries
  last. The default configuration ran first and last in each series.

## Results

Core clock from the PMU path, default votes: 1,401.6 MHz in every stage from Source to Tail, in both event sets (Setup,
0.03 ms long, reads 1,242 and 1,257 MHz). `HAP_power_get` with `clk_Freq` returns 1,401,600,000 Hz in the same lifecycle.

60-tile span check, 15,601 frames:

| Votes after HVX power | Context | Vote return code | Core clock | DSP | PCM SHA-256 |
| --- | --- | --- | ---: | ---: | --- |
| Core TURBO (DCVS v2), HMX power: the default | per vote | 0 | 1,401.6 MHz | 78.27, 78.55, 78.44, 79.09 ms | `223D6305...` |
| default | shared | 0 | 1,401.6 MHz | 78.21 ms | `223D6305...` |
| default + HMX clock TURBO (HMX v2) | per vote | -3 | 1,401.6 MHz | 79.05 ms | `223D6305...` |
| default + HMX clock MAX (HMX v2) | per vote | -3 | 1,401.6 MHz | 78.24 ms | `223D6305...` |
| default + bus TURBO, bus MAX or sleep disabled (DCVS v3) | per vote | `0x80000412` | 1,401.6 MHz | 78.19-79.06 ms | `223D6305...` |
| default + bus MAX (DCVS v3) | shared | `0x8000040E` | 1,401.6 MHz | 78.60 ms | `223D6305...` |
| core TURBO, sleep latency 10 us (DCVS v2) | per vote | 0 | 1,401.6 MHz | 78.53 ms | `223D6305...` |
| **core TURBO_PLUS (DCVS v2)** | per vote | 0 | **1,478.4 MHz** | **74.67 ms** | `223D6305...` |
| **core MAX (DCVS v2)** | per vote | 0 | **1,478.4 MHz** | **74.71 ms** | `223D6305...` |

- Core TURBO_PLUS and MAX both give 1,478.4 MHz, 5.5 % above TURBO. The check takes 74.7 ms against 78.2-79.1 ms,
  about 5 % less: this job's time scales with the core clock.
- HMX v2 clock requests are refused on this target, and the `hmx_core_clk_Freq` query returns -3 in every run. The
  header states that chipsets without a separate HMX clock refuse these requests.
- DCVS v3 requests (bus corners, sleep disable, also core corners) are refused, so bus corners cannot be voted through
  this interface here. A shared context changes neither the time nor the refusals.
- PCM is identical in every configuration.

Kept: core MAX is now a kept setting of the depth-first generator emission (`Invoke-KokoroGeneratorDepthFirstEmission`,
`GeneratorPowerVotes`); a caller that names `PowerVotes` replaces it. With it, the span check takes 74.57 ms (78.18 ms in
`generator-span-front-pieces-sm8550-20261028.md`), PCM `223D6305...`, vote return code 0. Every named kernel's default
emission is byte-identical to its parent (`VerifyEmission`, 56 emitting kernels identical, 4 failing at both).

## Limits

- Only the depth-first generator takes the kept vote. The decoder, source and other jobs still vote TURBO.
- One check per configuration (the DSP time the check reports for its runs); thermal behaviour over long sustained
  runs at 1,478.4 MHz was not measured.
- The meaning of the DCVS v3 return codes was not resolved.

Receipts: `build/power-votes-20261028` and the `build/generator-tile-equivalence-20261028T*` runs.
