# Generator input stream

The [active Student/phase contract](student-generator-contract.md) governs new
runtime work. The concrete layout and byte rates below describe the existing
unwired diagnostic packet, including supplied source tiles and explicit lock
arrays. They do not prescribe a product bank, lock-table stream or stored source
branch. A new bridge must consume the agreed Student controls and phase state;
do not rebuild AdaIN/Snake to accommodate this older diagnostic API.

The front end supplies the generator's controls with each 300-sample frame.
At 24,000 samples/s that is 80 frames/s. Transport may batch 16 or 64 frames;
the generator still consumes one frame at a time. Weights and demonstrated
per-voice constants load at instantiation. AdaIN scale/bias and utterance-specific
Lock controls are streamed inputs.

`src/runspace/Kokoro.GeneratorInput.psm1` declares `KokoroGeneratorInputFrame`
and `Get-KokoroGeneratorInputContract`. This defines the input boundary; the
connected DSP worker has not yet been converted to consume it. Float16 feature
storage is a contract choice, not a new device precision or performance result.

## Frame layout

All numbers are little-endian. Feature arrays use channel-major order, with
cycle position innermost. Controls use resblocks 0 through 5, dilation 0 through
2, adain1 then adain2, channel, and cycle position where present. This is 36 main
sites: 18 with 256 channels/10 positions, then 18 with 128 channels/60 positions.
AdaIN scale and bias each contain 6,912 values.

| Field | Precision | Bytes/frame | Bytes/second of audio |
| --- | --- | ---: | ---: |
| Version, sequence, flags, valid samples | 4 UInt32 | 16 | 1,280 |
| Decoder feature slice | 512 Float16 | 1,024 | 81,920 |
| 10x source tile | 256 x 10 Float16 | 5,120 | 409,600 |
| 60x source tile | 128 x 60 Float16 | 15,360 | 1,228,800 |
| AdaIN scale | 6,912 Float32 | 27,648 | 2,211,840 |
| AdaIN bias | 6,912 Float32 | 27,648 | 2,211,840 |
| Channel lock phase, radians of a·u | 6,912 Float32 | 27,648 | 2,211,840 |
| F0, Hz | Float32 | 4 | 320 |
| Voiced, 0 or 1 | UInt32 | 4 | 320 |
| Alignment padding | 8 bytes | 8 | 640 |
| Total, channel phase representation | | 104,480 | 8,358,400 |

The per-seat comparison replaces only the Lock field with 184,320 Float32
phases: 737,280 bytes/frame, or 58,982,400 bytes/s. Its complete frame is
814,112 bytes, or 65,128,960 bytes/s. These are decimal payload byte rates;
transport protocol overhead is excluded. A sine/cosine pair would double the
channel Lock field; no pair-rotation implementation is established by this
contract.

A 16-frame block is 1,671,680 bytes with channel phases, or 13,025,792 bytes
with seat phases. A 64-frame block is 6,686,720 or 52,103,168 bytes respectively.
Batching changes transfer size, not cadence or bytes per second.

## Extra row and lifetime

The preserved producer has 60F+1 rows in its 60x stage. Preserve its existing
row order: group 60 rows per frame and send the remaining row once at the final
boundary. The boundary payload is a 16-byte header, 128 Float16 source values,
and 2,304 Float32 values each for scale, bias and Lock phase: 27,920 bytes per
utterance. `-FinalBoundary` includes it in `BlockBytes`. It produces no additional
audio frame; its rate contribution is 27,920 divided by utterance duration.
The frame phase measurements exclude that incomplete row and record its count.

The source branch is manufactured upstream in this contract, so its 12 Snake
sites are measured separately and do not add DSP Lock/AdaIN stream fields.
The two supplied source tiles already include that branch's output.

Fixed channel/position bias in the offline split experiment is fitted once
across the measurement cases. That descriptive fit is not evidence that a
deployable per-voice constant has been learned. No utterance-specific control
array becomes a resident preload. The student may learn the phase drive and
AdaIN controls against the same typed boundary.

## Timing comparisons

Report synthesis time as milliseconds per second of output audio as well as
the original time and duration. The historical peach receipt
`results/peach-combined-constants-sm8550-20261012.md` times decoder, harmonic
source and generator together; it is not a generator-only timing. Match stage
coverage, artifact, input, precision, clock policy and harness before claiming
a speed change. Offline measurements here establish no DSP timing. Restore
the existing four-thread HVX epilogue before any generator bundling work.
