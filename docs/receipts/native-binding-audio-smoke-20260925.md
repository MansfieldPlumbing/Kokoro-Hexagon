# Native-binding audio smoke

Date: 2026-09-25

`Native.Binding.psm1` was parsed and exercised in a clean Windows PowerShell
process, then used by `Audio.AAudio.psm1` on physical SM8550 and SM8635
devices. Both devices opened 24 kHz mono float streams, wrote and consumed all
6,000 frames, completed drain, and returned zero from close. The SM8550 run
reported zero xruns; the SM8635 run reported one startup xrun.

The Windows default render endpoint also accepted a 350 ms buffer through the
local QuickPS WASAPI implementation: 48 kHz, stereo, 32-bit, 16,800 frames.
The exercised source was `QuickPS/src/Wasapi.Windows.ps1`, SHA-256
`33185FF24A9DFF34450C473924DBE59DF5E570829F8BFF4EAE2DA661D49ADDE6`.

A historical staged Kokoro/QNN oracle job was also replayed on the SM8550 to
exercise speech-shaped PCM through the new AAudio binding. It produced and
played 24,000/24,000 frames with zero xruns, but failed its numerical gate:
6.36 dB audio SNR against the staged oracle. The owner heard the utterance as
“tab.” This is not a passing synthesis receipt and does not promote the
historical QNN path into the product.
