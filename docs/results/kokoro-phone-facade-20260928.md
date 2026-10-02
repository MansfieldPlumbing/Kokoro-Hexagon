# Kokoro phone facade result — 2026-09-28

## Implemented

The downstream repository now contains a state-driven, full-window phone
facade using the immutable Pwsh `AndroidCanvas.psm1` binding at commit
`ba84d1921c272699b45e75e21360a454fb647f7c`.

- `Kokoro.Facade.psm1` owns responsive safe-area layout, status/progress state,
  bounded utterance display, a large primary action, touch hit testing, and
  Canvas rendering.
- `Start-KokoroFacade.ps1` is a device-profile entry point using the admitted
  `NativeActivityHandle`.
- `Build-KokoroFacadePackage.ps1` stages the profile, pinned display binding,
  facade module, metadata-only speech-session reducer, and launcher icon with a
  hash manifest under ignored `build/`.
- The square launcher art is 1254 by 1254 pixels, full bleed, and uses a large
  high-contrast cyan mark without embedded text or a baked-in system mask.

The Windows structural gate passed at 1080 by 2340 pixels with representative
system-bar insets. The primary action is 181 pixels high. Calculated contrast is
18.20:1 for primary text and 14.16:1 for action text. These are source/layout
checks, not Android accessibility-service certification.

## Device boundary

The connected S23 has the expected Kokoro package installed, but the installed
APK is not debuggable, so its private `Profile.ps1` cannot be replaced through
ADB. The pinned Pwsh builder also hard-codes its own launcher icon and does not
yet admit a downstream profile/module bundle. Therefore the facade has not been
executed on the device and the icon has not been installed. A generic upstream
application-input hook is specified in `docs/architecture/pwsh-upstream-pr-note.md`.

## Speech-session boundary

`Kokoro.SpeechSession.psm1` now projects admitted engine state into the facade
without carrying samples or tensor data. The current engine has
`SynthesisReady = false`, so the reducer remains in `ModelAdmitted` and rejects
warmup and requests. A synthetic future-ready descriptor passed the ordered
warmup, request, monotonic PCM-counter, draining, cancellation, fault, and
closure gates. Cancellation advances a generation number so late completion
from an earlier request cannot become the current result.

## Transport audit

The owner-authorized local `C:\Dev\adb` inspection found a direct WinUSB ADB
implementation, not an Android Open Accessory implementation. It is unversioned
local source and includes C# components, so none of it was copied into the
PowerShell-authored product path. Kokoro already has bounded AOA negotiation and
framing prototypes in `tools/UsbAoa.ps1` and `tools/Invoke-KokoroAoa.ps1`; the
Android accessory endpoint and package resources remain unimplemented gates.
