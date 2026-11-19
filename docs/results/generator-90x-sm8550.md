# Whole-generator DSP throughput on SM8550

On the attached SM8550, the generator produced 11.775 seconds of reference-matching PCM in **129.92 ms** and **129.96 ms** at the two warm medians, or **90.63×** and **90.61×** real time. All 24 warm candidate invocations finished below the 130.833 ms budget for 90×. The intervening 81× control used the same fixture, harness and power votes.

| Phone series | Warm runs | Median DSP ms | DSP range, ms | Real-time multiple | Median host invoke ms |
|---|---:|---:|---:|---:|---:|
| Candidate A | 12 | 129.921 | 128.982–130.565 | 90.63× | 165.468 |
| Committed 81× control | 12 | 144.734 | 144.088–145.280 | 81.36× | 189.421 |
| Candidate B | 12 | 129.955 | 129.035–130.375 | 90.61× | 162.217 |

Each series began with one additional cold invocation. All 39 invocations completed stage 7 and matched the SHA-256 of all 282,600 signed PCM samples. Real-time multiple is audio duration divided by DSP region time. Host invocation is reported separately. The measurements cover one phone and one seeded whole-generator fixture with host coefficients.

## What changed

* For each 32-channel input block, HMX visits the neighboring taps before moving to the next block. The emitter precomputes up to three activation and weight address pairs in scalar registers. Weights retain their original offsets. Prebinding alone measured 145.20 ms. Changing tap traversal brought the equivalent six-run median to about 135.8 ms before polling changes.
* HMX reuses the emitted output-group loop. The PCM tail combines only the first 32-channel block, which contains all five sample lanes. Where the combine reads only the low byte of accumulator group three, the emitter skips the unused high-plane store.
* Each existing worker copies a disjoint range of whole 2 KiB history croutons as part of its fill or combine dispatch. Each worker then runs its original numerical body. The same publication fence and weight wait still precede HMX. The activation producer uses a compact channel loop and a hardware row-pair loop.
* The worker polling pause is 128. Spans of 120 tiles reduce how often the schedule saves and restores section state. A 160-tile experiment exceeded the 8 MiB VTCM budget during layout and never reached the phone.

The timing gain establishes a benefit from the ordering on this workload. The internal HMX pipeline, buffering and physical fetch width remain unobserved. Every history transfer in the candidate covers complete croutons.

## Reproduce the candidate

From a checkout containing this report, run the following in PowerShell 7. Supply an output directory for the library and a fixture directory with the files identified below.

```powershell
. ./Invoke-HexagonDevelopment.ps1
. ./src/jobs/Kokoro.Generator60x16Run.ps1
$job = New-KokoroGenerator60x16RunSteps -Frames 56521 -BatchTiles 4 -HvxThreads 4 `
    -AdaInMode Constants -Tail -Front -Whole -Source -Schedule Backward -SpanTiles 120 `
    -SeededNoise -WeightPlanes 1 -ResidentSourceChannels 128,256 -AsyncWeights `
    -HostCoefficients -VectorPackets -PowerVotes HvxPower,CoreMax,HmxPower
$definition = @{
    Steps = $job.Steps
    Symbol = 'kokoro_generator_tail_skel_handle_invoke'
    Soname = 'libkokoro_generator_tail_skel.so'
}
$null = Invoke-HexagonEmission -Kernel Definition -Definition $definition -OutputDirectory $out
[pscustomobject]$job.Layout | Select-Object PcmOffset,Tiles,OutputBytes,Samples,InputBytes,
    @{Name='Speech';Expression={'True'}},@{Name='Runs';Expression={13}} |
    ConvertTo-Json | Set-Content (Join-Path $out 'runner-layout.json')
```

The local confirmation used the direct phone harness under `build/lighthouse-60x-20261119T092441/direct/tools`, with its fixture from the same build directory. Invoke `Invoke-GeneratorTailProbe.ps1` with `-EmissionDirectory $out -FixtureDirectory $fixture -Runs 13 -ExpectedPcmSHA256 $pcmHash -Adb C:/dev/pwsh/scripts/adb.ps1`. Run one phone job at a time. Check the reported library digest against the local binary, all PCM digests, and the startup-restoration receipt. Discard run 0 and divide region ticks by 19,200 for milliseconds.

| Artifact | SHA-256 |
|---|---|
| Candidate library | `3CA2DCF299E05E6F090C4C218527D8A04C56B6685041544A6D859A82D9728EFE` |
| Control library from 19e3fbd | `4DA65019B97CC325A2E07F44ECBE15B7CA4298AA0402B598C466D9B3D89F7B25` |
| Reference PCM | `B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF` |
| activations.bin | `FCD019515B2968EDAAE8E6EE83A6C80A52F3535B71845CDE1E7CE68B2B2E3870` |
| tables.bin | `0CECC381D7F0FC692CA958C4AC890FD2B32F0DA699A34EF2BA8898B0785985A5` |
| weights.bin | `74FE3CDA2B681588517B85ACED79093A9354FDF12C8F8A80ADFBB530D3AF375A` |

An independent emission from the release source reproduced the candidate library SHA-256 byte for byte. A rebuild of 19e3fbd also reproduced the control digest.

The local per-run CSVs and device receipts are in `build/rt80-1795102334443/confirm-shared120-112101`. An earlier exploratory receipt for a 120-tile variant contained a different library digest after two phone harnesses overlapped. That receipt was discarded. The confirmation above used serialized phone access and checked both the binary and PCM digests. The phone startup files and staged files from before the overlap were checked against their backups.
