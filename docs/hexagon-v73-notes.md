# Hexagon V73 notes

Architecture facts this project relies on, each with its source. A claim from a manual
alone says so; "assembler" means SDK 6.4.0.2 `hexagon-llvm-mc` (V73, `+hvxv73`, 128-byte);
"SM8550" means a counter run on the phone (`docs/results/`).

## HVX packing

| Fact | Source |
| --- | --- |
| HVX resources: two multiply pipes, shift, permute; one vector load and one vector store per packet | V73 HVX PRM 80-N2040-54 Rev. AB ch. 5; V75 HVX PRM in the SDK |
| Slots: multiplies 2-3; operations that need a full 32/64-bit scalar (lookup, splat, insert, add/sub with Rt) 2-3; simple ALU, permute and shift 0-3, including shifts by a scalar | V73 HVX PRM §5.1.3 Table 5-2 (p. 25); assembler places `vlsr(Vu.uw,Rt)` in slots 1 and 2 |
| Single-vector ALU uses any one pipe: four in one packet assemble | assembler |
| A halfword (16-bit) multiply takes both multiply pipes: two in one packet are rejected | assembler ("HVX resource use violation") |
| One shift pipe: two shifts in one packet are rejected | assembler |
| `vlut16` (pair output) takes shift and permute | SM8550 pipe counters equal static counts |
| Packet encoding: slot 3 at the lowest address, strictly decreasing; an instruction takes a higher free slot it can use; a lone load or store goes in slot 0 | V75 PRM "Ordering constraints" in the SDK; assembler output |

Correction recorded 2026-10-07: "HVX multiplies issue only in slots 2/3" is right, but it
was applied to every HVX instruction with a scalar operand; shifts by Rt are slots 0-3.

## Issue and threads (SM8550)

| Fact | Source |
| --- | --- |
| One hardware thread commits an HVX-containing packet at most every second cycle; scalar packets fill the cycle between | SM8550 PMU 0x7/0x4 (`generator60x-pmu-sm8550-20261007.md`) |
| Four 128-byte HVX contexts (`qurt_hvx_get_units()` = 0x400) | SM8550 |
| Four HVX worker threads run AdaIN + Snake 3.09x faster than one, output exact | `generator60x-hvx-threads-sm8550-20261007.md` |
| UPCYCLE / UTIMER = 73.0 (1.40 GHz) during the stage | SM8550 |
| HVX packet counter (0x111) counts one per packet on V73 (V79 documents two) | SM8550 counts equal static counts |

## QuRT from emitted code

The DSP image does not export the `libqurt.a` trap stubs (`qurt_pmu_*`,
`qurt_hvx_get_units`, futex, HVX lock); emit their trap sequences inline (SDK 6.4.0.2
`computev73/lib/pic/libqurt.a`, SHA-256 `8e0ba5fd…`). `qurt_thread_create/join/exit` are
imports, as the SDK multithreading example uses them from a skel.
