# Student native replay v0

The owning application is `Invoke-KokoroDevelopment.ps1 Student`; implementation
and compiled kernels are in `tools/Kokoro.Student.psm1`. `-h` lists commands.
The existing bank is evidence, read only. Learning selects real exemplars and
observed medoid directions; it does not average vectors or fit projections.

## Native contract

All integers and IEEE FP32 values are little endian. A program ends at its exact
byte extent. It starts with one COPY and may then contain DIRECTION, RESIDUAL
and FLAGS instructions. Unknown opcodes, truncated operands, invalid indices,
invalid keys and nonfinite replay values fail admission.

| Opcode | Payload | Bytes including opcode | Meaning |
| --- | --- | ---: | --- |
| 1 COPY | signed i32 exemplar ID | 5 | Expand the real exemplar's int16 tile using the shared voice key. ID -1 copies the immediately previous source-unit replay. |
| 2 DIRECTION | signed i32 pair ID | 5 | Add that pair's selected real medoid direction. |
| 3 RESIDUAL | u8 shift, u16 count, count × (u16 channel, i16 correction) | 4 + 4 × count | Add correction × voice-key[channel] × 2^-shift, with FP32 multiplication and addition. |
| 4 FLAGS | u32 bits | 5 | OR the bits into the replay result's flags. |

Channels are 0 through 511. Each RESIDUAL block has at most 512 entries and a
shift from 0 through 30. Multiple blocks permit coarse and fine corrections;
no float residual is stored. A previous-unit COPY requires an actual predecessor
in the same source sentence. The caller enforces that sentence boundary. The
interpreter checks that a predecessor contains exactly 512 values.

The interpreter returns a typed `KokoroStudentReplayResult`, containing 512
FP32 values and uint32 flags. It performs deterministic selection, addition and
fixed-point expansion. Flags do not change feature values.

## Libraries

`exemplars.i16` stores 512 signed int16 values per real bank unit, in global
unit order, a logical 16 × 32 tile. `voice-key.f32` stores 512 positive FP32
channel keys. For each channel, its key is selected as the largest of that
channel's real observed chunk keys. Every library vector is the corresponding
real unit, re-encoded with this one shared key using ties-to-even rounding;
out-of-range values are rejected. This conversion can change the original
dequantized FP32 vector, so quality must be measured against the original bank
values, not just the converted tile.

`directions.f32` contains 512 FP32 values per selected phoneme-pair medoid,
in the measurement's pair order. Each direction is the difference of its two
real consecutive source units, rounded to FP32. `pair-ids.i32` maps each bank
unit to its pair ID, or -1 when no admitted pair applies. The pair is always
within one source sentence. This map is an index, not a raw control track.

`native-library.clixml` is the typed PowerShell persistence description: version,
byte order, counts, paths, hashes and opcode descriptions. Native vectors and
programs remain native binary. It does not serialize raw per-frame controls.
Library writing uses bounded chunks, including for arrays exceeding 2 GiB.

`copy-programs.bin` is the initial COPY-only program store: one five-byte
program per bank unit, implicit fixed stride 5, selecting its measured best
real other exemplar. This initialization makes no 46/70 dB quality claim and
contains no RESIDUAL. The climber must evaluate original bank features.

## Commands and checks

```powershell
& ./Invoke-KokoroDevelopment.ps1 Student -Parameters @{Step='Replay'; KernelOnly=$true} -OutputDirectory build/student-replay-check
& ./Invoke-KokoroDevelopment.ps1 Student -Parameters @{Step='Replay'} -OutputDirectory build/student-replay-library
```

The first runs native hand fixtures. The second also builds the complete real
exemplar/direction library from the already measured bank, checking order and
every chunk hash. It reuses the measured medoids rather than repeating their
search. Fixture binaries exercise all four opcodes, COPY-previous, exact flags,
repeat determinism, truncation, invalid exemplar/pair/channel indices, absent
predecessors and unknown opcodes. The existing feature/nearest/medoid kernel
checks also run. All kernels pass the pinned compiler's CLR-only admission.

The nine COPY-only listening pairs were rendered first; see
`results/student-copy-only-offline-20261015.md`. Their SNR is a PCM-domain result,
separate from the later feature-domain quality bars.
