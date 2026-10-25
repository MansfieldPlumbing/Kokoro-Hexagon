# Generator span loop: library size independent of length (SM8550)

Kokoro-Hexagon `6bc821c`. Case `generator-tile-equivalence -Joint Spans` (`-Repeat 4` and `-Repeat 15`, span sizes 20
and 40 tiles). Earlier span results: `generator-alternating-spans-sm8550-20261023.md`.

## Method

A span is uniform when it meets all of these conditions:

- Every range in its plan advances by the same step as in its neighbours.
- No stage touches an edge of the input: no step needs edge treatment, and no front or tail range reaches either end.
- Its lockstep run is even and starts on a fixed ring parity.

For the longest run of at least three uniform spans, the job generates the code of three consecutive spans (u, u + 1,
u + 2). Their operations must match. Each lo/hi immediate must either be equal in all three or advance by one constant
stride; each that advances is emitted as base + r16 × stride, with r16 the span index.

That code is one callable body, so the loop's branch stays short whatever the body's size (a conditional branch reaches
±64 KB). A loop over r16 runs it. The spans before and after the run are emitted individually. Lockstep runs inside the
body take their first step in a register and their step count as the dispatch's segment count.

## Result

Int8 resblock weights, supplied AdaIN values, blocks of 4 tiles. The input is the whole-generator fixture's x, S0 and
S1, repeated frame by frame.

| Audio | Span tiles | Spans (looped) | DSP ms | Library bytes | PCM SHA-256 prefix |
| ---: | ---: | --- | ---: | ---: | --- |
| 6.5 s | 20 | 9 (2 to 6) | 124.41 | 1,143,028 | 8BECC02202423AFF |
| 6.5 s | 40 | 5 (none) | 121.64 | 1,183,988 | 8BECC02202423AFF |
| 24.4 s | 20 | 31 (2 to 29) | 438.13 | 1,114,356 | 27B4BAD0B4022D8D |
| 24.4 s | 40 | 16 | 426.03 | 1,159,412 | 27B4BAD0B4022D8D |

- **Same output as unrolled:** at 6.5 s the looped job's PCM equals the unrolled job's earlier result (124.83 ms,
  1,482,996 B).
- **Span-size invariance:** at each length the PCM and both sections' outputs are equal across span sizes.
- **Library size:** at 20-tile spans the 11.4 s job emits 1,110,260 B, against 1,114,356 B at 24.4 s.
- **VTCM:** 7,602,176 B at 20-tile spans, 7,929,856 B at 40-tile spans.
- **Throughput:** 24.4 s in 438.13 ms is 18.0 ms per audio second, about 56 times real time.

## Limits

- The slow frame count may not be a multiple of 32 (the extra input frame of `ups.1` needs one more mean tile), as in
  the layer job.
- The phone harness admits at most 32,768 tiles (1,048,576 frames).
