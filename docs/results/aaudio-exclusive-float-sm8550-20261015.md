# AAudio exclusive float readback on S23

STOP condition: none.

On 2026-10-15, the attached S23 (SM8550) opened an AAudio output stream with the requested contract and returned the following values through the stream getter APIs:

| Property | Requested | Granted |
|---|---|---|
| Sharing mode | Exclusive (0) | Exclusive (0) |
| Channels | Mono (1) | Mono (1) |
| Sample rate | 24,000 Hz | 24,000 Hz |
| Format | PCM float (2) | PCM float (2) |

The granted burst size was 48 frames and buffer capacity was 1,536 frames. Stream close returned 0. The probe opened, queried and closed the stream; it did not write audio or measure latency, xruns, DSP time or HMX rate. No WAV was generated.

The existing float writer can submit Kokoro's float mono 24 kHz samples unchanged to this granted AAudio stream. No project-side resampling, channel conversion or sample-format conversion is needed. These getters establish the application stream contract; downstream hardware processing was not measured.

## Implementation and provenance

Repository/worktree: `C:\Dev\Kokoro-Hexagon-generator-templates`, branch `generator-templates`, parent commit `202f0b6fe176987382cfbf4c7c9e6776669e6bc6`. No push.

`src/runspace/Audio.AAudio.psm1` now requests exclusive sharing by default and returns the granted sharing mode alongside the existing rate, channel and format fields. Its optional diagnostic format-mismatch flag allows readback before deciding what representation to supply. The float writer rejects a stream whose granted format is not PCM float. Existing partial-write, drain and close behavior is preserved.

The module's API reference is AOSP frameworks/av commit `9e7dd63dfff0cc967f025ea9e27a299aaa99fd69`, `AAudio.h` blob `25ad5f8ef976c33b8670e4217d3f984c13096829`. The bound getter names are `AAudioStream_getSharingMode`, `AAudioStream_getSamplesPerFrame`, `AAudioStream_getSampleRate` and `AAudioStream_getFormat`. The hardware claim above comes from actual getter returns saved in `build/aaudio-readback-20261015/receipt.txt`.

Exact device command, from the worktree:

```powershell
& ./build/aaudio-readback-20261015/Invoke-Readback.ps1
```

The temporary probe uses `& $audio.Open 24000 1 0 $true`. It selects the attached SM8550 without recording identifiers, obtains the coordination lock with `board.ps1 Lock -Agent Codex`, stages hash-checked sources into the project's private storage, runs one isolated startup probe, restores both original startup files with hash checks, and releases the lock in `finally`. The first attempt failed before opening audio because the host did not expose `$Activity`; using the existing runner's `$PSScriptRoot` fallback resolved it. The completed attempt returned `Passed=True`, `CloseRc=0` and `StartupRestored=True`.

Verification command:

```powershell
& ./Invoke-KokoroDevelopment.ps1 Verify
```

Only this receipt and `src/runspace/Audio.AAudio.psm1` belong to this change. Temporary probe sources and logs remain under ignored `build/`. `C:\Dev\Pwsh-Development\BOARD.md` was updated by the mandatory lock/unlock command; other existing changes there are unrelated and excluded. No protected evidence was changed. Unrequested scope: none. There is no before/after speed comparison; this is a single requested-versus-granted API contract measurement.
