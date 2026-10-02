# Verification Receipt: Exhaustive HMX & Pcycle Named Encoders vs SDK LLVM Assembler Oracle

- Date: 2026-09-23
- Authoring Harness: Pure PowerShell 7.4 named instruction encoders (`src/emit/Hexagon.ps1`)
- Toolchain: Zero C compiler in runtime or build loop
- Scope: Hexagon V73 HMX Matrix Operations, 64-bit Pcycle Telemetry & 64-bit Memory Operations

---

## 1. Pinned Independent Oracle Metadata

The Qualcomm Hexagon SDK LLVM assembler (`hexagon-llvm-mc`) is utilized **exclusively as a differential instruction-encoding and syntax legality oracle**. It is strictly forbidden from defining instruction ordering, packet scheduling, or physical data layout.

| Component | Path / Identification | Pinned SHA-256 |
|---|---|---|
| **HMX Prototypes Header** | `HEXAGON_Tools/19.0.04/.../include/hmx_hexagon_protos.h` | `b902a75377335f9e89b0ea01c3e3d4836fdebde0703d5a82328dde26af17808e` |
| **LLVM MC Assembler** | `HEXAGON_Tools/19.0.04/Tools/bin/hexagon-llvm-mc` | `fc64c65aca06186106a73ba93e65ddf7c906bf4905b786dc748d3f034401ea27` |
| **Compiler / Tools Version** | Qualcomm Hexagon Tools 19.0.04 (LLVM 19.0.0) | Registered Target: `hexagon` |
| **Assembler Flags** | `-triple=hexagon -mcpu=hexagonv73 -mattr=+hmxv73,+hvxv73,+hvx-length128b,+hvx-ieee-fp` |

---

## 2. Exhaustive Operand & Modifier Sweep Results

Validation executed via [`tools/Test-HmxEncoders.ps1`](file:///c:/Dev/Antigravity/Kokoro-Hexagon/tools/Test-HmxEncoders.ps1):

```text
=================================================================
 Phase 1: Named HMX & Pcycle Encoder Exhaustive Validation Suite
=================================================================
[+] Pinned Assembler: /home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools/bin/hexagon-llvm-mc (SHA-256: fc64c65aca06186106a73ba93e65ddf7c906bf4905b786dc748d3f034401ea27)
[+] Pinned HMX Protos: /home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools/target/hexagon/include/hmx_hexagon_protos.h (SHA-256: b902a75377335f9e89b0ea01c3e3d4836fdebde0703d5a82328dde26af17808e)
[+] Generated 2598 legal assembly test cases across all categories.
[+] Total Tested Instructions/Packets: 2598
[+] Total Emitted Code Bytes: 19392
[+] Oracle Byte Mismatches: 0
[+] Legal Instruction Sweep: 100% BIT-EXACT MATCH WITH LLVM ORACLE
[+] Invalid Operands Tested: 14
[+] Invalid Operands Rejected: 14
[+] Invalid Operand Rejection: 100% REJECTED

TestedCases          : 2598
EmittedBytes         : 19392
OracleBytes          : 19392
Mismatches           : 0
InvalidCasesTested   : 14
InvalidCasesRejected : 14
Pass                 : True
```

### Coverage Breakdown:
1. **64-bit Hardware Cycle Counter (`pcycle`)**:
   - Instruction: `rD = s31:30` (Syntax: `rD:D+1 = pcycle`).
   - Swept all 16 legal register pairs ($r1:0, r3:2, \dots, r31:30$). All matched 100%.
   - Rejected odd destination registers ($r1, r31$), out-of-range ($r32, r-1$).
2. **64-bit Memory Store (`store-d`)**:
   - Instruction: `memd(rS + #Offset) = rT:T+1`.
   - Swept address registers ($r0..r31$), data register pairs ($r1:0..r31:30$), and positive/negative offsets ($-4096 \le \text{Offset} \le 4088$). All matched 100%.
   - Rejected unaligned offsets (`#4`, `#7`), odd source pairs (`r1`), and out-of-range offsets (`#16384`).
3. **HMX Accumulator Controls**:
   - `mxclracc` (`0xa6e0c011`): integer accumulator reset.
   - `mxclracc.hf` (`0xa6e0c013`): half-precision float accumulator reset.
4. **HMX Accumulator Conversions (`cvt`)**:
   - `cvt.hf = acc(Rs)`: swept all 32 source registers ($r0..r31$).
   - `cvt.ub = acc(Rs)`: swept all 32 source registers ($r0..r31$).
   - `cvt.ub = acc(Rs):sc0`: swept all 32 source registers with scale 0.
   - `cvt.ub = acc(Rs):sc1`: swept all 32 source registers with scale 1.
5. **HMX Store (`mxmem-cvt`)**:
   - `mxmem(Rs, Rt) = cvt`: swept all boundary pairs ($r0, r1, r4, r7, r10, r15, r16, r28, r30, r31$). All matched 100%.
6. **HMX Dual-Slot Paired Packets**:
   - `mxmpy-fp16`: `{ activation.hf = mxmem(Rs, Rt); weight.hf = mxmem(Ru, Rv) }`
   - `mxmpy-w8a8`: `{ activation.ub = mxmem(Rs, Rt); weight.b = mxmem(Ru, Rv) }`
   - `mxmpy-w4a8`: `{ activation.ub = mxmem(Rs, Rt); weight.n = mxmem(Ru, Rv) }`
   - Swept combinations across boundary registers ($0, 1, 4, 10, 15, 16, 28, 29, 31$). Dual-slot packet parse bits (`PP = 01` for activation load, `PP = 11` for weight load) matched 100%.

---

## 3. Full ELF Library Emission Verification

Verification executed via [`tools/Test-HexagonEmission.ps1`](file:///c:/Dev/Antigravity/Kokoro-Hexagon/tools/Test-HexagonEmission.ps1):

- Emitted Library: `libkokoro_hmx_matrix_skel.so`
- Kernel Entry: `kokoro_hmx_matrix_skel_handle_invoke`
- Emitted Code Bytes: **464 bytes**
- Library SHA-256: `5F00169BE3340500E94B5D7FE4FF013A4EA3C6C5691252FE3BCDE0C12947E6C3`
- Dynamic Imports: 0
- Dynamic Relocations: 0
- Section Table Validation: `.text` section extracted and compared against independent LLVM object assembly.
- Result: **InstructionBytesMatch = True**.

---

## 4. Verification Boundary Disclaimer

This receipt certifies **instruction-encoding correctness only**. It verifies that the emitted opcodes and packet parse bits conform exactly to the Hexagon V73 ISA specification. It does **not** certify physical W4 nibble layout, row/column ordering, or mathematical matrix dot-product semantics on silicon. Those physical data-layout properties will be established on hardware in Phase 3 using deliberately discriminating specimens.
