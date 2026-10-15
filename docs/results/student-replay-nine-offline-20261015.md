# Nine held-out selections through the compact student store

All nine use saved 70 dB feature programs from the completed compact store,
not a repeated climb. Each donor sentence is replayed from its own beginning,
preserving COPY-previous and DIRECTION state. Program, offset and library hashes
are checked before replay. Expanded feature vectors are transient in memory.

The reference is a selected-bank feature reconstruction, not untouched stock
fresh-text speech. Original then student PCM16 WAV pairs have a 0.6 s gap.
Selected donors, durations, inherited F0/noise contours, style row 25, source
seed 17, live AdaIN and output gain 1 are matched within each pair. These are
feature-replay tests; CONST AdaIN/lock replay is not used.

## Fidelity and normalized synthesis time

All nine reference WAV SHA256 values exactly match the earlier COPY-only gate.
That permits the PCM fidelity comparison below. Timing conditions differ from
that earlier run: these are three simultaneous Windows host batches, each
using four threads, with one original-first run per variant. Timings include
the offline FP32 decoder, source and generator. They exclude store loading,
learning, waveform writing and dispatch; they are not warm DSP benchmarks.

| Target | Audio s | COPY-only PCM16 SNR dB | Climbed PCM16 SNR dB | Reference ms/audio-s | Student ms/audio-s |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 2.050 | 13.009820 | 54.412435 | 39248.596 | 39737.709 |
| 2 | 2.925 | 10.718584 | 63.494558 | 36048.829 | 38553.403 |
| 3 | 2.650 | 15.102043 | 61.516462 | 41686.393 | 41245.046 |
| 4 | 3.000 | 16.569931 | 58.088619 | 38909.879 | 37867.113 |
| 5 | 2.850 | 16.253600 | 59.557552 | 36987.019 | 41380.174 |
| 6 | 2.875 | 15.531081 | 59.834522 | 41170.801 | 29644.779 |
| 7 | 2.675 | 14.007520 | 56.169282 | 39472.826 | 37975.786 |
| 8 | 3.100 | 13.947042 | 57.931057 | 35443.852 | 41698.590 |
| 9 | 2.825 | 15.564339 | 57.331210 | 41512.610 | 31724.159 |

The requested historical whole-utterance int8 generator comparison is
approximately 85 ms / 2.125 s = **40 ms/audio-s**, approximately 25× audio rate.
The preserved separate generator run is 89.076 / 2.125 = **41.918118 ms/audio-s**.
The [combined constants receipt](peach-combined-constants-sm8550-20261012.md)
reports “DSP region, median of five warm runs” as 99.593 ms for 2.125 s,
**46.867294 ms/audio-s**, with `ResidentHvxThreads=4`. That last row includes
decoder, source and generator; it is not generator-only. Current host results
differ in processor, precision, selected-unit inputs, normalization mode,
concurrent load, stage coverage and warm-run conditions. No DSP speed change
or hardware/SDK/API capability is inferred from this offline test. Four-thread
HVX restoration before any later bundle remains a separate requirement.

## Listening pairs

Paths below are under ignored `build/`; audio is not committed.

| Target | Text | Original then student pair |
| --- | --- | --- |
| 1 | I can eat a peach for hours. | [WAV](../../build/student-replay-nine-a-20261015/01-original-then-student.wav) |
| 2 | She left her keys on the kitchen table again. | [WAV](../../build/student-replay-nine-a-20261015/02-original-then-student.wav) |
| 3 | Please call me when you get home tonight. | [WAV](../../build/student-replay-nine-a-20261015/03-original-then-student.wav) |
| 4 | My brother plays the guitar in a small band. | [WAV](../../build/student-replay-nine-b-20261015/04-original-then-student.wav) |
| 5 | We should plant more trees along the river. | [WAV](../../build/student-replay-nine-b-20261015/05-original-then-student.wav) |
| 6 | The children laughed at the funny little dog. | [WAV](../../build/student-replay-nine-b-20261015/06-original-then-student.wav) |
| 7 | He forgot to bring an umbrella this morning. | [WAV](../../build/student-replay-nine-c-20261015/07-original-then-student.wav) |
| 8 | Our train was late, so we missed the meeting. | [WAV](../../build/student-replay-nine-c-20261015/08-original-then-student.wav) |
| 9 | There is a bakery on the corner of my street. | [WAV](../../build/student-replay-nine-c-20261015/09-original-then-student.wav) |

Pair SHA256, target order:

```text
1 5D2A376C903CF09EDA801FEA15B97746AB845ACFD382066E1F98DC5E8487148C
2 0C663D1AAB2F9CDE1CB1DF97FB7E96FA93B8F9169B198F791E116C88C05FE900
3 4E24F2B2898593BD75D799636FCFBE955D92EB620E9187B5D703FC18E5AFCEDC
4 0757207688D8E9504380F225538ADD0A785DB03844E91C4A44054C6E7CB12BAE
5 81A195379EA108ADCD5F0BB2B0522FC9404B899A03966FAD1D1AF98711431F23
6 E79FBE6569FC65E740AC0D4F5EDE71D4F70DDAE5B451ABA77035C73481240261
7 6789FBFF0BD845C2A0A9BEEEF7D41F716CFE2AFD0AC275BA4FF46D1AAEAC2800
8 2DEC9474BFA225BE0E5BC9E46BED65AE71B23C5B377C9E885226EE293C098E8C
9 A67A5B6138214DA83C6DCC4438F10576BB67EA0337045413E4CA4B2390DDAB59
```

Store description SHA256:
`659630356B3F314C294A3F7BEB341D85EE930E6ED5F5EFF97A7A694B95761FC4`.
Student compiled kernel SHA256:
`EE4DD6FB9A55CDEFC1B781BA07E19AC9D91307CA911B620AA7D72D90ADB3B017`.
Reference renderer source SHA256:
`8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257`.
Reference renderer DLL SHA256:
`446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D`.
Complete per-variant timings and hashes are in
`build/student-replay-nine-summary-20261015.clixml` and each batch's
`copy-render.clixml`. Protected bank, reference captures and prior receipts
remain unchanged.
