# Generator joints: ups.0 and ups.1 into the depth-first sections (SM8550)

Kokoro-Hexagon `97bc2be`. Case `generator-tile-equivalence -Parameters @{Joint='Front'}` and `@{Joint='Whole'}`;
receipts `build/generator-tile-equivalence-20261023T084346` (Front) and `build/generator-tile-equivalence-20261023T091608`
(Whole).

## Method

The 256-channel section on the chunked schedule (7,471,104 B of VTCM) and the 128-channel section on the lockstep
schedule (7,602,176 B) do not fit 8 MiB together. One job therefore runs them one after the other over the input, each
with its own VTCM layout:

1. 256-channel front: LeakyReLU(0.1) of x, `ups.0`, and the add of the source stream.
2. Chunked 256-channel section.
3. 128-channel front: `ups.1` from that section's mean, reflection, and the add of the source stream.
4. Lockstep 128-channel section.
5. Tail to PCM.

The fronts are the layer job's `ups` sequences, run over the whole section.

Each source insertion point (the input of the add after `ups`) reads a supplied stream (`-SuppliedSource`) instead of
computing `noise_convs` and `noise_res`. For the proof, the layer job computes those streams from `har` with its source
branch, and the case passes them to the depth-first job from the layer job's workspace. The case compares each section's
input and output in the two workspaces, and the PCM. Resblock weights are int8 in both jobs, with supplied (constants)
AdaIN values and blocks of 4 tiles.

## Result

| Joint | Fixture | Frames | Compared | Depth-first ms | Layer ms |
| --- | --- | ---: | --- | ---: | ---: |
| Front | `speak-20261010-h0-fast/job-input/front10-stage-fixture-20261008` | 1,700 | 256-channel mean: equal | 19.38 | 25.31 |
| Whole | `generator-whole-fixture-20261008` | 7,801 (39,000 samples) | both sections' inputs and outputs, PCM: equal | 36.60 | 59.29 |

The layer times include the source branch, which the depth-first job does not run.

- Whole PCM SHA-256: 704674F05D818666A844408BEAAEE2B65FA6879C0A357BE15034BC6FFED61D20, three runs.
- Library and VTCM:

| Job | Library bytes | VTCM bytes |
| --- | ---: | ---: |
| Depth-first whole job | 721,140 | 7,602,176 |
| Layer whole job | 954,612 | 7,208,960 |

The ring-addressing shifts of the uniform step loop had been computed once, at the first section's channel count. That
gave the 128-channel section wrong output from its first loop step, and a fault on the second invocation. They are now
computed per section.

## Not yet done

- Arbitrary length: each section runs over the whole input once. Alternating spans (a span of the 256-channel section,
  then the matching 128-channel span) need each section's state saved and restored between spans.
- The source streams come from the layer job's source branch; the binding that produces them from the Student's
  controls is not built.
- The controller contact in a whole job.
