# Retained Zira audio and event-clock verification

Implementation: Kokoro-Hexagon commits `5823c96` and `101b70c`, in the existing
`Get-EnglishZiraReference` function. The optional `WavePath` parameter retains the audio produced with the
captured phone and word events. Existing files are rejected instead of overwritten. `NoSave` still controls
observation persistence independently of WAV output.

## Source trace

The host's System.Speech informational version is
`11.0.0-rc.1.26425.128+3551975be08744f0418857c5bed8ab1545c5dd47`.
At that revision, [AudioFileOut.Play and Duration](https://github.com/dotnet/dotnet/blob/3551975be08744f0418857c5bed8ab1545c5dd47/src/runtime/src/libraries/System.Speech/src/Internal/Synthesis/AudioFileOut.cs)
count converted output bytes but divide them by the input byte rate when computing elapsed duration.
[EngineSite.CreateTtsEvent](https://github.com/dotnet/dotnet/blob/3551975be08744f0418857c5bed8ab1545c5dd47/src/runtime/src/libraries/System.Speech/src/Internal/Synthesis/EngineSite.cs)
uses that duration for event positions. The capture therefore retains Zira's native mono PCM without output conversion.

## Measurement

The capture receipt (`../../../../Kokoro-Hexagon/build/student-zira-clock-20261021T090125/receipt.clixml`) records
an automatic corpus-text prefix capture through the optional WAV path. The text was selected mechanically from
the book's chapter heading, without choosing individual sentences.

| Measure | Result |
| --- | ---: |
| Captured words | 277 |
| Captured phone events | 1,079 |
| Retained WAV duration | 109.27 seconds |
| Last phone end | 109.27 seconds |
| Repeated WAV hash | Identical |

Both retained WAVs have SHA-256 `F109238D8BB483B2CF4FE9B103DD48D4FB5AA49C1F974E7B291816DB73FC9D94`.
The receipt records the capture-owner hash `C9ED80F1D9E1A75E565B6EF50ADC891A3DE133D1236CFFA16761AEF7A7CA8203`
and engine hash `5FC7ED4C1BDA309A4CD1B82A1BBDB1811746BEBA0CC18420A3DCABF517BB350E`.
The Verify log (`../../../../Kokoro-Hexagon/build/student-verify-zira-clock.log`) passes before the clock-fix commit.

The earlier converted-format capture was rejected for alignment when its event times exceeded its WAV duration.
The native-format capture supplies identity labels and an acoustic reference for warping only. Its durations and
pauses are not human timing evidence. Human word alignment and boundary snapping are subsequent work.
