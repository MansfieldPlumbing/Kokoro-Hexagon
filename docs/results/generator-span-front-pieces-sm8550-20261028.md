# Generator 60-tile spans past one span, SM8550 (2026-10-28)

Kokoro-Hexagon at the commit that adds this record (parent `7fa48b0`). With the 128-channel span front run in pieces,
60-tile spans now fit VTCM when the input is longer than one span. Before this, they had only run on inputs that one span
covered (`generator-source-on-dsp-sm8550-20261024.md`: one span at 7,801 frames). The same check is the first phone
proof of the workspace windows (`-WorkspaceWindows`, `88cd5a8`).

## Method

- 128-channel span front (`$spanFront1`, `src/jobs/Kokoro.Generator60x16Run.ps1`): the tables and the three ups[1] phase
  pairs' weights load once per span into three resident slots. The span's 256-channel mean tiles then run in pieces of
  at most 10, the mean tiles of one x tile (`$frontPieceTiles`). Each piece runs what one span call ran before over its
  own range, with its own halo and edge fixes. The front's VTCM is sized by the piece, not by the span. At 31,201 frames
  with 60-tile spans it needed 11,599,872 B and was refused; the whole job now takes 7,602,176 B at every length and
  span size emitted.
- The tail streams per batch (`generator-tail-streamed-sm8550-20261028.md`), so a 60-tile span's tail no longer sizes
  VTCM either.
- The span check of `generator-tile-equivalence` (`Joint` `Spans` and `SpansSource`) now appends the finished K/M/S
  that the kept settings read after the parameters, as the single-length checks already did. Without them every
  span job past one span was rejected at admission (`AEE_EBADPARM`, `InvokeRc` 14). That was the failure seen at 31,201
  frames before this change.
- `-WorkspaceWindows` on the check also runs each span size with workspace windows. Sections windowed in that run are
  not compared, since their slots hold only the last span's window; the PCM and the last section's output are.

The check is `Run -Case generator-tile-equivalence -Parameters @{Joint='SpansSource'; Repeat=2; SpanSizes=20,40,60;
WorkspaceWindows=$true; Runs=1}`: the fixture's x, f0 and noise repeated twice, 15,601 frames, 3.25 s of audio, kept
settings (host coefficients, queued weights, resident sources). The whole-generator check at the fixture's length,
`Joint='WholeSource'; Runs=5`, gives the PCM against the layer job and against earlier records.

## Results

At 15,601 frames (one one-shot run per job):

| Span tiles | Windows | Spans | DSP | Workspace output buffer | PCM SHA-256 | Last section output |
| ---: | --- | ---: | ---: | ---: | --- | --- |
| 20 | off | 5 | 82.22 ms | 49,823,936 B | `223D6305...` | `DA1355...` |
| 20 | on | 5 | 82.12 ms | 36,839,616 B | `223D6305...` | `DA1355...` |
| 40 | off | 3 | 80.50 ms | 49,823,936 B | `223D6305...` | `DA1355...` |
| 40 | on | 3 | 80.47 ms | 41,099,456 B | `223D6305...` | `DA1355...` |
| 60 | off | 2 | 78.18 ms | 49,823,936 B | `223D6305...` | `DA1355...` |
| 60 | on | 2 | 78.18 ms | 44,720,320 B | `223D6305...` | `DA1355...` |

PCM and the last section's output are identical across span sizes and with or without windows. 60-tile spans take
78.18 ms for 3.25 s of audio, 24.1 ms per audio second; 20-tile spans take 4.0 ms more. Windows change no DSP time.
They save the more workspace the more spans there are, because the job's output (the last section's whole tensor)
stays whole.

At 7,801 frames (`WholeSource`), the depth-first job with front pieces gives PCM `AF52480D...`, equal to the layer
job's and to `generator-tail-streamed-sm8550-20261028.md`. Its DSP time is 40.06 ms resident (median of 5) and
39.57 ms one-shot, against 39.36 and 39.69 ms one-shot (one run each) before the pieces.

## Limits

- The uniform span loop is still not formed with resident sources (`Layout.SpanRejections`): every span is emitted
  inline, so the library still grows with the length.
- The last span still flushes every stage to the end of the input.
- Lengths whose 256-channel frame count is a multiple of 32 are refused. The 128-channel front counts one input frame
  more than the 256-channel section gives, a finite-length count of ups[1]'s reflection pad.

Receipts: `build/front-pieces-whole-20261028-022257` and `build/front-pieces-spans-20261028-023130` (the 15,601-frame run).
