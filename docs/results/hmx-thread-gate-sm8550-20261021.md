# Matrix unit from a second thread, SM8550

Kokoro-Hexagon working tree after `ea2db1b`, `Invoke-KokoroDevelopment.ps1 Run -Case generator-tile-equivalence
-Parameters @{TileBlock=4; MatrixThread=<k>; MatrixLock=<mode>}`. Design: `generator-depth-first-w4-design.md`
(build order step 3).

## What ran

The 128-channel section in the tile schedule at blocks of 4 tiles (fixture and reference as in
`generator-tile-schedule-sm8550-20261021.md`). The run harness takes the matrix unit for the main thread with
`compute_resource_hmx_lock` before the job. Job parameters:

- `MatrixThread`: 0 runs every convolution on the main thread; 1 sends every convolution to HVX worker 1 through its
  pool record (the convolution body reads only r0 to r15).
- `MatrixLock`: `Main` leaves the lock with the main thread. `Worker` has the main thread release it with QuRT
  `unlock2(0)` (`trap0(#0x1d)`, r5 = 1) before the workers start, worker 1 take it with try-lock (`trap0(#0x1d)`, r5 = 2)
  at thread start and release it at exit, and the main thread take it back after the join. `Convolution` has worker 1
  take it before and release it after every convolution (1,440 pairs per run: 80 steps of 18 convolutions).

## Result

| Convolutions on | Lock held by | DSP median | Output tensor |
| --- | --- | ---: | --- |
| main thread | main thread | 40.10 ms (3 runs) | byte-identical |
| worker 1 | main thread | | job fault, `InvokeRc` 0x8000040D, `Stage` 5, twice |
| worker 1 | worker 1 for the job | 40.46 ms (3 runs); 40.57 and 40.09 ms (5 runs each) | byte-identical |
| worker 1 | worker 1 per convolution | 41.71 and 41.72 ms (5 runs each) | byte-identical |

The layer schedule measured 31.02 to 31.20 ms in the same sessions. Byte-identical means the tile tensor equals the
layer tensor (`9D5F9DABDE7BC814...`), 0 differing bytes.

## Observations

- The matrix unit is gated per thread on SM8550. A thread that does not hold the matrix lock faults on matrix
  instructions even while the unit is idle and another thread of the same process holds the lock. With the lock handed
  to it, the same code produces the reference output exactly.
- Taking and releasing the lock around every convolution costs about 1.4 ms over 1,440 pairs, about 1 microsecond per
  pair, uncontended. A stage of the section takes about 28 microseconds at this speed (39.9 ms over 80 steps of 18
  stages), so moving the lock with each convolution costs a few percent of a stage.
- Consequence for the rotation in the design: the matrix unit cannot be shared by schedule alone. The lock travels with
  the convolution, taken by the thread whose turn it is; at fixed phase the try-lock finds the unit free.
