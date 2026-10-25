# Student controller recordings and diagnostic stems

Implementation: Kokoro-Hexagon commit `fac5e1a6a95007e831bd94e3de74d4fe950b4dea`, in `student/Invoke-Student.ps1`.
This replaces Listen's LPC and melody previews with a Stems step. No generator files changed in this commit.

The native recording stores physical controls, event ticks, capture provenance, a seed, and capture-machine and
lowered-kernel hashes. Playback projects these values into the declared controller layout. The capture hashes
remain attached when a different renderer plays the recording; renderer hashes belong to the playback receipt.
No Kokoro tensors or audio are stored in the controller recording.

Stems renders the harmonic source, unvoiced seeded noise, event clicks, and the coefficient-axis diagnostic tone
into synchronized audio and MPE inspection files. The bias row is not supplied. These are diagnostic signals,
not an emulation of the resident generator or a voice binding. The reserved time axis must be zero.

## Measurement

Command: `Invoke-KokoroDevelopment.ps1 Student -Parameters @{ Step = 'Stems' }`, in process.
The arithmetic coverage sequence exercises pitch, rests, noise, signed coefficients and response modes without text.
Measurements below come from the playback receipt (`../../../../Kokoro-Hexagon/build/student-stems-20261021T082133/receipt.clixml`),
SHA-256 `5C81B7F440C4798AC73423D2991FF7165C26DE393159383185D871D69F996D82`.

| Measure | Result | Gate |
| --- | ---: | ---: |
| Generator ticks | 384 | Exact declared duration |
| Stable voiced pitch frames scored | 144 | YIN with interior support |
| Maximum absolute pitch error | 0.357658 cents | 35 cents |
| Voice/noise/rest state mismatches | 0 ticks | 0 ticks |
| Event click mismatches | 0 ticks | 0 ticks |
| Maximum coefficient-axis error | 0.029563 | 0.05 |
| Maximum response-gain error | 0.068883 | 0.1 |
| Independent repeated renders | Byte-identical for every stem | Exact WAV hashes |

The detector reads the quantized PCM written to each WAV. Pitch uses the same lowered YIN kernel as Listen;
state uses frame RMS, event clicks use their sample on the tick boundary, and the coefficient detector projects
the fixed tone onto its first two Fourier harmonics. Pitch is scored only where the detector has stable support
on both sides. This gate does not establish tracking accuracy on human speech or on generator output.

The receipt records render-machine SHA-256 `188B036CB1B0A0BD7ED072319411A137FB7F31BAA9BC42E781719EEF2656A02A`
and lowered-kernel SHA-256 `CE4809DAE85A419AB076D2EC1AD471BF9A433532E64D348F8E9964DFE79EACC1`.
The host reports PowerShell `7.7.0-preview.5` and .NET `11.0.0`. The pinned lowering path admitted the kernels
without SMA references. Verify passed before the commit; its local log (`../../../../Kokoro-Hexagon/build/student-verify.log`)
records the repository checks. No phone claim is made. Listen's spectral tilt remains a declared placeholder
until its measurement step is implemented.
