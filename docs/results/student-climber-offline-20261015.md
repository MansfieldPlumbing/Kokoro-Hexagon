# Student full-bank climber v0

Both feature-quality bars complete on the same read-only bank: 2,429,833 units,
43,679 sentences, K=4, and the measured real medoid directions. No phone,
Python, fitted projection, centroid or control climbing is involved.

| Result | 46 dB bar | 70 dB bar |
| --- | ---: | ---: |
| Units without RESIDUAL | 7,806 | 2,210 |
| Share without RESIDUAL | 0.321256646% | 0.090952753% |
| Minimum independently replayed feature SNR | 46.000000001 dB | 70.000000017 dB |
| Mutation attempts, including initialization records | 14,578,998 | 14,578,998 |
| Accepted shorter mutations, excluding initialization | 3,622,307 | 3,745,503 |
| Initial quality seed bytes | 9,375,583,545 | 9,375,583,545 |
| Final program bytes | 4,820,102,656 | 7,442,181,693 |

The bare best-exemplar COPY is tested first. Where it misses quality, a
quality-passing corrected seed is initialized before shortening begins.
Initialization is not counted as an accepted shortening. Subsequent candidates
must pass the quality bar and be strictly shorter. Attempts include trimming
residual channels, alternate real exemplars and COPY-previous plus the selected
real direction. Unrepresentable direction corrections are rejected candidates.
Every source sentence resets the previous-unit state.

## Compacted byte bill

Only reachable exemplar and direction rows are retained; COPY and DIRECTION
IDs are rewritten. Residual bytes below are already included in program bytes.

| Component, bytes | 46 dB | 70 dB |
| --- | ---: | ---: |
| Programs | 4,820,102,656 | 7,442,181,693 |
| Of which RESIDUAL | 4,807,948,776 | 7,430,027,828 |
| Real int16 exemplar library | 1,591,023,616 | 1,578,627,072 |
| Real FP32 direction library | 1,908,736 | 1,908,736 |
| Shared voice key | 2,048 | 2,048 |
| Program offsets | 19,440,416 | 19,440,416 |
| Native total | 6,432,477,472 | 9,042,159,965 |
| Typed descriptions | 165,078 | 165,077 |
| Total store | 6,432,642,550 | 9,042,325,042 |

The matching full-bank int16 baseline is 2,488,148,992 bytes. These stores are
2.585312443× and 3.634157388× that baseline: v0 does not compress this bank.
The requested approximately 52 MB baseline describes approximately 51,000
units, a different cardinality; no matched 51,000-unit climber experiment is
claimed. Learning journals and source-bank metadata are not runtime store bytes.

## Validation and provenance

Each final program was replayed independently by the native interpreter against
its teacher vector before accepting its measured SNR. Hand fixtures cover both
quality bars, strict shorter-and-quality acceptance, rejected unrepresentable
corrections, previous-state reset and identical output across sentence-boundary
partitions. Compaction fixtures verify COPY and DIRECTION preserve replay,
reject missing mappings and preserve program extents. This is feature fidelity,
not a claim that selected-unit speech is natural or stock phoneme-to-PCM speech.

The resumed run retains nine completed original chunks and their kernel pins;
later chunks use source-sentence partitions. Both kernel identities are recorded
in the summary rather than attributing the whole run to the final helper DLL.

- Bank order SHA256:
  `6FB62AA7037808BAF9AA17D14AB0F5D5CD64B4733419B991EB3555C6C8983E64`.
- Climber kernels:
  `0DB7AF49A97A623F6B7DC5C59A0E5C409BB46CE9F4E2B4EF1B684122C2DDEFBB`
  and `EE4DD6FB9A55CDEFC1B781BA07E19AC9D91307CA911B620AA7D72D90ADB3B017`.
- Climb summaries, native journals and offsets:
  `build/student-climber-parallel-full-20261015/`.
- Compacted stores:
  `build/student-climber-compact-full-20261015/bar-46/compact-store.clixml`
  and `bar-70/compact-store.clixml`.
- 46 dB description SHA256:
  `C2D9CA89A51CEAF7FA588C638160505FB3391B65759154A7E9AF90BFF4334446`.
- 70 dB description SHA256:
  `659630356B3F314C294A3F7BEB341D85EE930E6ED5F5EFF97A7A694B95761FC4`.

The earlier nine COPY-only listening gate remains separate. Nine post-climb
listening pairs and the resident CONST control gate are subsequent work.
This batch-learning result has no audio-time denominator; it is not a synthesis
speed measurement or a hardware/SDK/API performance claim.
