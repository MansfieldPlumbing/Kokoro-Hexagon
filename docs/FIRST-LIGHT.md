# First light — 2026-09-22

Device: Samsung Galaxy S23 (SM-S911U, SM8550, Hexagon V73), QAIRT 2.46.0.260424.
Host app: AndroidSMA `.preview`, arm64 Debug, built from AndroidSMA `a320c45`
with `<uses-native-library android:name="libcdsprpc.so" android:required="false"/>`.

Phrase: `af_heart`, 131 frames (3.27 s), 160-frame capacity.

## First vocalization (PowerShell iSTFT)

```
Job=kokoro-speak
FrontMs=68.1 GenMs=4688.7
TotalMs=14482.0 Samples=78600 Seconds=3.27
NonFinite=0 AudioSnrDb=24.25
PlayState=Playing Played=True
Passed=True
```

## Whole decoder on HTP (iSTFT in graph, burst vote, 8 MB VTCM)

```
Job=kokoro-speak
Perf=burst SetRc=0
FrontMs=38.8 GenMs=1567.0
TotalMs=2345.0 Samples=78600 Seconds=3.27
NonFinite=0 AudioSnrDb=23.99
Passed=True
```

`AudioSnrDb` is measured against the full-length (unmasked) PyTorch decoder.
The fp32 CPU run of the same masked design scores 24.2 dB, so HTP adds no
measurable error beyond the design.
