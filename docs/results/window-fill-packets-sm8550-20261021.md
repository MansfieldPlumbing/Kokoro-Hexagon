# Window fill in instruction packets, SM8550

Kokoro-Hexagon `7c52ea4`, `Run -Case generator-tile-equivalence -Parameters @{VectorPackets=$true}` against the same
case without packets: the 128-channel residual section (fixture `generator60x16-fixture-20261008-holdout2`, 319 tiles,
10,201 frames), four HVX threads, tile schedule with blocks of four tiles, two weight planes, matrix lock on the main
thread.

## Change

`Group-HexagonPackets` groups the straight-line body of the AdaIN and Snake window fill into packets of up to four
instructions under the V73 resource records in hexagon-v73-notes.md (`../hexagon-v73-notes.md`): register dependencies,
vector load and store order, one vector load, one vector store, one shift and one multiply per packet, slot ranges per
instruction class, memory operations in the lowest free slot. The rest of the job keeps one instruction per packet.

## Checks

- SDK 6.4.0.2 `hexagon-llvm-mc` (19.0.04): the unpacked tile job matches byte for byte; the packed job assembles, and
  every packet holds the same instructions at the same addresses as the assembler's. Within some packets the
  assembler chooses a different slot order.
- Phone: in all five runs the tile job's output tensor equals the layer job's byte for byte
  (`9D5F9DABDE7BC814F28DD1616D45F9780BAF6BA46E754CF545DCB5113D8B69A4`).

## Time

Alternated runs, receipts `build/generator-tile-equivalence-20261021T102219`, `T102312`, `T102334`, `T102349`:

| Run | Layer job ms | Tile job ms |
| --- | ---: | ---: |
| Unpacked | 31.15 | 39.68 |
| Packed | 31.21 | 36.51 |
| Unpacked | 31.21 | 39.74 |
| Packed | 31.08 | 36.78 |

Packing the window fill saves 3.1 ms (7.9 %) of the tile job. The tile job remains 5.5 ms (17.7 %) slower than the
layer job on this section.
