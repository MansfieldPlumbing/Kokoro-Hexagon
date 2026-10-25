# Student structure measurement, 2026-10-15

STOP condition hit: none. Checkout `Kokoro-Hexagon`, branch `main`, base
`2f5130c53d35c7fb876959c40f0cc358361fa9ee`. Implementation and receipt accompany
this commit; no push. This is step 1 of the student opcode task, not a completed
climber or a speech-quality result.

Command: `Invoke-KokoroDevelopment.ps1 Student -Parameters @{Step='Measure';Threads=12;K=4} -OutputDirectory <fresh build directory>`.
The implementation is `tools/Kokoro.Student.psm1`. Its numeric classes are
lowered with pinned PSLowering `1afabe056235a570da29e268824784557d4f6cdd`;
source integrity and CLR-only admission precede execution. No phone job,
new harness, Python or new JSON. The existing bank remains read-only.

## Full bank

43,679 sentences, 2,429,833 units, 9,862 triphone contexts. For each unit, search
every other unit in its exact padded triphone context, falling back to its
phoneme only when that context has no other unit. Self is excluded. There are
1,383 fallback units and zero units lacking another real exemplar. The four
nearest IDs are retained for the later climber; the ratios below use the best.
Equal distances select the smaller original unit ID.

| Population | Count | R median | R p10 | R p90 |
| --- | ---: | ---: | ---: | ---: |
| Unit versus best real exemplar | 2,429,833 | 33.384841 | 11.930574 | 377.870353 |
| Phoneme-pair direction consistency | 933 | 2.423232 | 1.409540 | 9.582955 |

Unit R is `sum(unit^2)/sum((unit-exemplar)^2)`. Direction R is
`sum_occurrences(norm(d)^2)/sum_occurrences(norm(d-selected_direction)^2)`.
The selected direction is one real within-sentence occurrence minimizing total
squared difference. Selection uses counted sums to evaluate that total;
no mean vector, centroid or fitted projection is formed or stored. Only pairs
with at least 20 occurrences qualify. Median is the lower observed rank;
p10/p90 use nearest rank. Both full-bank populations have odd counts.

Pairs with direction R > 10 cover 89,879 units: **3.698978% of the bank**.
Coverage counts the second unit of each qualifying within-sentence pair, with
all 2,429,833 bank units as denominator. No direction crosses a sentence boundary.

Features are dequantized FP32 using the bank's existing per-channel scale, as
in pinned `OfflineExperimentMath.EncoderSlice`; squared differences accumulate
in FP64. Minimum unit energy is 28.696652 and minimum qualifying pair energy
is 719.012336, so no zero-signal ratio convention affects these populations.
The bank's existing phonemizer errors remain; these are structural measurements.

## Twenty strongest pairs

Symbols retain the bank's encoding. Medoid ID identifies the second unit B of
the actual A-then-B occurrence; its first unit is ID minus one.

| Pair | Occurrences | R | Medoid unit B |
| --- | ---: | ---: | ---: |
| `əð` | 29 | 122.911594 | 1218763 |
| `W?` | 27 | 75.294058 | 2059112 |
| `W.` | 142 | 56.244219 | 667144 |
| `Wˈ` | 266 | 44.592743 | 981444 |
| `ɡʤ` | 51 | 31.132619 | 1624927 |
| `I.` | 196 | 28.492959 | 2424131 |
| `hW` | 266 | 27.484419 | 643568 |
| `ɔ.` | 22 | 25.059701 | 271310 |
| `ŋ.` | 1337 | 23.875383 | 1172625 |
| `A!` | 28 | 22.828569 | 98594 |
| `Oɛ` | 30 | 22.672474 | 1152210 |
| `A.` | 531 | 22.563172 | 1186951 |
| `m?` | 128 | 21.242549 | 1441395 |
| `ŋ?` | 56 | 21.242464 | 1818836 |
| `?>` | 2375 | 20.598789 | 1347819 |
| `mt` | 132 | 20.480898 | 1550502 |
| `ʌθ` | 535 | 19.989163 | 2352877 |
| `.>` | 39848 | 19.978057 | 1568772 |
| `A?` | 54 | 19.888809 | 1169976 |
| `ʤ.` | 366 | 19.448333 | 848980 |

## Twenty weakest pairs

`␠` displays an ordinary space from the bank.

| Pair | Occurrences | R | Medoid unit B |
| --- | ---: | ---: | ---: |
| `ˌɛ` | 3711 | 1.060845 | 869617 |
| `t␠` | 46507 | 1.064616 | 147941 |
| `d␠` | 26909 | 1.076768 | 344871 |
| `Oə` | 46 | 1.108074 | 2248250 |
| `ˌæ` | 1047 | 1.127157 | 1894686 |
| `ɹ␠` | 30375 | 1.127190 | 147550 |
| `i␠` | 26189 | 1.130101 | 886667 |
| `I␠` | 11904 | 1.130112 | 1606669 |
| `ˈɑ` | 16908 | 1.134873 | 215711 |
| `n␠` | 41724 | 1.137739 | 2385950 |
| `;␠` | 1439 | 1.147193 | 756564 |
| `ˌO` | 1144 | 1.158616 | 198534 |
| `A␠` | 4329 | 1.166575 | 976340 |
| `ɹə` | 4524 | 1.174728 | 2250152 |
| `,␠` | 20204 | 1.179378 | 2269169 |
| `m␠` | 9221 | 1.181823 | 1371507 |
| `əd` | 952 | 1.181826 | 1255335 |
| `ˈi` | 24857 | 1.186557 | 1517767 |
| `iə` | 1789 | 1.186649 | 2100774 |
| `əm` | 5243 | 1.194278 | 1083213 |

## Artifacts and checks

Artifacts are under `build/student-20261015-full/`; no raw feature matrix or
per-frame control track is written. The source bank is the existing evidence.

| Artifact | SHA256 |
| --- | --- |
| Module source | 5BFAF35B93CD96D9EFFAF34D70A2EE551C3560B6623FFB4FCD0C9959B682EA3C |
| CLR-only kernel | B354E9A69A7771CCC4F4311201066906FCE30F9AC73358C9740D67D62CB0048F |
| Preserved order.json | 6FB62AA7037808BAF9AA17D14AB0F5D5CD64B4733419B991EB3555C6C8983E64 |
| structure.clixml | E743FFBA4936D0D5AC66E82881E27EE4849507ABAC269BB56AC647A3023E360D |
| nearest.i32 | 70DFD110F8B8E2A8EBDFC2507357727F04BAB0E2A974E51E340E1A9EE8D914AA |
| nearest-errors.f64 | A8830DF475F29E4A7E3E6AC292EBBE87C719B1F106F95A97812349AC08157CC0 |
| directions.clixml | 91D3EA0A704E810539B4C762A96AB2CBAF4D45FA45F8D3AC70AF03B07E2F04A2 |

`energy.f64` preserves each target's signal energy, `directions.csv` all 933
pair results, and `bank-provenance.clixml` every source chunk's hash. Compiled
checks cover native dequantization/layout, exact distances, self-exclusion,
ties, and a direction medoid checked against direct total squared differences.
A three-sentence boundary run exercises an empty qualifying-pair population.
Verify passes before commit. Original captures, manifests and historical
receipts remain unchanged. Unrequested scope: none.

The measured worker wait was 5,785,267.079 ms for exact full-bank nearest
selection and 9,813.0538 ms for directions, on the laptop with 12 workers.
These batch-analysis times exclude bank loading and are not synthesis latency.
There is no audio duration, so milliseconds per second of audio cannot be
derived or compared with the old generator's approximately 40 ms/audio-second
(the supplied approximately 85 ms for 2.125 s). Hardware/DSP speed for this
student remains unverified; no device benchmark or DSP claim is made.

COPY-only listening on the nine held-out selections is next, before climbing,
as requested. Neither the 46/70 dB quality bars nor store savings have yet been
established by this structural step.
