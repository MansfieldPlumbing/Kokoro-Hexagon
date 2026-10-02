# Hardware receipt: direct V73 W4A8 contraction and INT32 readback

Date: 2026-09-24
Target: Samsung Galaxy S23, SM8550, Hexagon V73
Execution boundary: unsigned CDSP user process domain

## Artifact

- Producer: PowerShell named-instruction emitter
- Library: `libkokoro_hmx_matrix_skel.so`
- SHA-256: `A5A2C178247236DC5EFE50179586C631F9392636A9E53DD8932BD8A059629577`
- File size: 8,384 bytes
- Code size: 2,556 bytes
- Dynamic imports: 0
- Relocations: 0

The integer path performs the HMX contraction, four biased accumulator-plane
extracts, and a sixteen-block HVX byte-plane interleave directly in the
emitted library. Qualcomm HexKL is used by the diagnostic helper only to
produce an independent expected output in the same process.

## Encoder gate

The pinned Qualcomm LLVM 19.0.04 assembler was the independent byte oracle for
2,713 legal instruction and packet cases. All 19,852 emitted code bytes
matched. Eighteen invalid operand cases were rejected.

## Device gate

Dense integer inputs have an expected result of 32 in every INT32 lane.

| Mode | Direct output SHA-256 | Qualcomm oracle SHA-256 | Result |
| --- | --- | --- | --- |
| W8A8 | `E649DCF992752D6621F670C1ED2574E5A7262637F6AEC668ACE146CE9531DB4D` | same | exact |
| W4A8 | `E649DCF992752D6621F670C1ED2574E5A7262637F6AEC668ACE146CE9531DB4D` | same | exact |

The W4A8 path reached its final stage marker, returned 2,048 nonzero bytes in
the 8,192-byte INT32 result, and passed the exact semantic gate.

Thirty-one additional warm invocations reused the resident operands:

| Mode | Compute ticks min / median / p95 / max | Median compute | Median host invoke |
| --- | --- | ---: | ---: |
| FP16 | 3 / 4 / 4 / 23 | 0.208 microseconds | 0.237 ms |
| W8A8 | 47 / 48 / 50 / 69 | 2.50 microseconds | 0.245 ms |
| W4A8 | 48 / 48 / 50 / 65 | 2.50 microseconds | 0.247 ms |

The integer measurement includes the contraction, all four accumulator-plane
extracts, and the HVX interleave. W8A8 and W4A8 share the same integer
readback cost. These numbers characterize this emitted kernel; the LLVM
comparison remains a separate gate.

The complete probe passed and restored the application startup files. The raw
device receipt is outside the repository at:

`C:\Dev\Antigravity\Build\Kokoro-QNN\hexagon-emission\w4-direct-readback-20260924\device-receipt-abb607aa90914c4da229d4ed570077bc.txt`

## Remaining performance gate

Run repeated resident W4A8 tiles in one invocation against an LLVM-compiled
implementation with identical inputs, output layout, lock scope, and timing
boundaries. FastRPC setup and transport are reported separately.
