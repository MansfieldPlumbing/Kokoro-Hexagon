# Generator exceeds 80× real time on SM8550

The whole-generator DSP region produced 282,600 samples at 24 kHz (11.775 s of audio) in 145.22 ms at the first warm median and 144.86 ms on repetition. This is 81.08× and 81.28× real time. The measurement excludes host invocation overhead. It covers the seeded fixture with host coefficients and one weight plane.

| Phone run, in order | Warm samples | Median DSP ms | Warm range, ms |
|---|---:|---:|---:|
| Candidate A | 10 | 145.22 | 144.86–146.03 |
| Previous 71× generator | 10 | 164.57 | 164.07–165.00 |
| Candidate B | 10 | 144.86 | 143.98–145.58 |

Each invocation series began with one additional cold sample. The harness checked completed stage 7 and reference PCM SHA-256 B61ACE349E3090D910E1F6E6EB20378FE70F89D38DD421B4C0AF978BFBE1A6BF. Divide region ticks by 19,200 for milliseconds. The 90× target on this fixture is 130.83 ms.

## What changed and why

The activation producer uses halfword operations for shifted inputs, packs output planes together, and batches independent row pairs. The spectral tail packs two row pairs of eleven bins into one vector. Convolutions skip weight panels that are zero by construction. This removes arithmetic while retaining weight offsets. Intermediate warm measurements were 151.33 ms after spectral packing and 148.08 ms after panel pruning.

The history restore computes the number of preceding tiles needed from the stage tap delay and reach. It copies only those tiles, scheduling a load alongside a store for the previous 2 KiB crouton. Activation-window layout and publication fences stay intact. This version measured 145.25 ms in its initial six warm runs. These cumulative timings depend on the order of changes.

## How to reproduce and interpret the measurement

Use the implementation in the commit that introduced this report. Its parent is f0ade691d37a0d34f0ec1a2d9876140564618df6. Emit the generator with 56,521 frames, four batch tiles, four HVX threads, constant AdaIN, whole/front/source/tail enabled, backward scheduling, 60-tile spans, seeded noise, one weight plane, resident source channels 128 and 256, asynchronous weights, host coefficients, vector packets and HVX/core-max/HMX votes. Use the same fixture for every binary and compare warm DSP medians separately from host invocation time.

Local receipt directories are under build/rt80-1795102334443/verify80, in candidate-A, 71x-control and candidate-B. The candidate library SHA-256 is 4DA65019B97CC325A2E07F44ECBE15B7CA4298AA0402B598C466D9B3D89F7B25.

A separate schedule prebound three activation and weight address pairs in registers and issued the three HMX operations consecutively. It produced identical PCM and a 145.20 ms warm median. That falls inside baseline variation. These measurements qualify emitted instructions, VTCM layout, output and timing. The internal HMX pipeline and physical fetch footprint remain unresolved.

## Follow-up toward 90×

A worker-polling sweep on the candidate binary varied only the encoded PAUSE immediate. Across six warm samples per setting the medians were 143.47 ms at 128, 143.49 ms at 255 and 144.29 ms at the original 16. All samples matched the reference PCM. The fastest median is 82.07× and leaves 12.64 ms to reach 90×. Sweep receipts are in build/rt80-1795102334443/poll90.
