# Decoder stream step, SM8550 (2026-10-28)

Kokoro-Hexagon at the commit that adds this record (parent `990376c`). The first part of the acoustic stream step: the
decoder runs as one fixed 96-frame step of a stream that has no length, with its state carried from each step to the
next.

## Method

`New-KokoroDecoder16RunSteps -Delayed -Spans -Stream` (emission parameter `DecoderStream`, `DecoderFrames` 96) runs one
step: 3 frame tiles, 6 tick tiles, through every decoder layer, and returns.

- Input per step: the step's asr tiles, the F0 and N curves with 9 frames before the step (zero before the stream's
  first frame), a first-step flag, the decoder voice base K/M, and the previous step's state.
- Output per step: 6 x tiles, then the state: the conv-input histories, the last row pairs each delayed convolution
  reads before its first output row (181,760 bytes), and the pool's lead tile, which holds its previous row pair.
  253,440 bytes in all.
- The first-step flag zeros the rows before each tensor's delay. No row is padded at an end: the stream has none.
- decode.3's conv2 (TapDelay 13) and 1x1 shortcut (TapDelay 8) put x exactly one tile (32 ticks) late, so step s returns
  x tiles 6s - 1 .. 6s + 4 and the hand-off is a tile offset.

The host side is shared packing: `ConvertTo-KokoroDecoderStepInput` packs one step, and `Invoke-KokoroDecoderStream`
feeds steps, passes each step's state to the next and assembles x.

The check is `Run -Case decoder-delay-equivalence -Parameters @{Schedules='Stream'}`. The stream and the reference take
the same input: the stock decoder capture's inputs from frame 0, repeated past its last frame. The reference is the layer
job up to 128 frames, past that the layer job in overlap-save chunks. x is compared from tick 0 up to 20 ticks before the
reference's last tick: the reference's end pads its last 20 ticks, and the stream has no end. Controls: the same
comparison one tile off must differ, and the whole stream, run a second time, must return identical x.

Existing libraries are unchanged. The six undelayed decoder libraries, the delayed whole and span libraries at 100
frames and the run-time span library emit with their previous SHA-256.

## Results

One stream library (`2A14DFD6...`, VTCM 7,634,944 bytes) in every row:

| Frames | Steps | Reference | Compared bytes | Different | Different one tile off | Replay | Reference DSP | Stream DSP |
| ---: | ---: | --- | ---: | ---: | ---: | --- | ---: | ---: |
| 100 | 2 | layer job | 184,320 | 0 | 182,647 | identical | 4.90 ms | 8.13 ms |
| 128 | 2 | layer job | 241,664 | 0 | 239,448 | identical | 4.97 ms | 8.17 ms |
| 300 | 4 | 4 layer chunks | 593,920 | 0 | 588,607 | identical | 16.89 ms | 16.31 ms |
| 471 | 6 | 5 layer chunks | 944,128 | 0 | 935,818 | identical | 24.91 ms | 24.51 ms |
| 1,500 | 16 | 16 layer chunks | 3,051,520 | 0 | 3,025,014 | identical | 78.91 ms | 65.50 ms |

Over the 16 steps of the 1,500-frame stream, a step took 4.05 to 4.18 ms on the DSP (mean 4.09 ms) for 2.4 s of
audio. Stream DSP times include steps past the compared ticks. DSP times are from one run of each stream.

A first version saved the history of E's and the shortcuts' identity windows, and the pool's previous row pair, from the
first tile of the step instead of its last. Step 0 matched and every later step differed from its first tile (tick
160); the fix took the tail of the step's last tile.

## Limits

- The generator does not yet run in the step: x leaves the step through the output buffer.
- Each step is one FastRPC call from the host, with its state passed through the host; the state could instead stay on
  the DSP side between calls.
- Silence is not yet supplied by the Student; past the input, steps here take zero input.

Receipts: `build/decoder-delay-equivalence-20261028T043739` (100 to 471 frames) and
`build/decoder-delay-equivalence-20261028T043910` (1,500 frames).
