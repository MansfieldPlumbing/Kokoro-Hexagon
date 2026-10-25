# Listen physical controller values and typed acoustic occurrences

Implementation: Kokoro-Hexagon commit `4df7c6c`, in `student/Invoke-Student.ps1`.
Listen measures pitch, RMS level, octave spectral slope and YIN normalized difference, retaining the latter as
the declared aperiodicity descriptor. The slope fits log power across octave bands using Hamming-weighted
complex projections. This descriptor does not establish vocal-tract identity or pronunciation accuracy.

Each acoustic note has a source-audio hash and occurrence identity, physical measurements and source times.
Controller events reference those identities; the native recording contains the corresponding typed occurrences.
MPE remains an inspection export. The coefficient axis is zero pending a learned voice binding.

## Measurement

Command: `Invoke-KokoroDevelopment.ps1 Student -Parameters @{ Step = 'Listen'; Recordings = <recording directory>; RecordingLimit = 1 }`.
Input was the first complete decoded LibriVox Alice recording. Its SHA-256 is
`D4679FE0804BD92293B57D25D979AD6EB1651C7D00323E8CCA27BB7032F6FD44`.
The listening receipt (`../../../../Kokoro-Hexagon/build/student-listen-receipt.clixml`), SHA-256
`036DACF51D441D4562AE019A9C83F2EA731F375786775EAAE343CB7A0FEAE155`, records the measurements below.

| Measure | Result |
| --- | ---: |
| Source duration | 796.39725 seconds |
| Detector frames | 79,635 |
| Voiced acoustic occurrences | 2,071 |
| Native controller ticks | 63,709 |
| Median voiced pitch | 205.2 Hz |
| Minimum event spectral slope | -19.104630 dB/octave |
| Maximum event spectral slope | 5.964250 dB/octave |
| Decode time | 6.3 seconds |
| Pitch and spectral analysis time | 31.4 seconds |
| Full Listen time | 54.9 seconds |
| Unresolved occurrence references after native-record reload | 0 |

The recording's controller SHA-256 is `52DB84B2EDA4476BB8BF409B605278DCEBA8025983A4981FB345A1AD1D1D11CE`.
Its capture-machine hash is `9634B23CF0000B5140CDF587918BFD0C82E846E44F7C8E925A4C1AB48B264A39` and its
lowered-kernel hash is `D97D5190A2A3011F40148D4E8A0CEA519C8AC8A3ABF4FF885A4A2F9DA18FF1C8`.

Reloading the controller preserved every event and occurrence, and every non-null event occurrence reference
resolved. The [earlier Stems recording](student-controller-stems-20261021.md) also played through the new renderer
without rebuilding the recording, with the same reported gates in the
new playback receipt (`../../../../Kokoro-Hexagon/build/student-stems-20261021T083148/receipt.clixml`).
The M1 Verify log (`../../../../Kokoro-Hexagon/build/student-verify-m1.log`) passes before commit.
These are host measurements; human word alignment, held-out acoustic accuracy, the percept image and the
generator voice binding remain unverified.
