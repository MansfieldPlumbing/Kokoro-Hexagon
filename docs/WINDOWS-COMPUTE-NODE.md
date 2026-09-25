# Windows to Android compute node

The intended demo topology is a Windows PowerShell client with a compatible
Android phone acting as a persistent speech compute appliance. This is a target
contract, not a completed live synthesis path.

```text
Windows text / UI
  -> SMA plan and pronunciation inputs
  -> PowerShell-owned WinUSB AOA pipe
  -> resident Kokoro Android appliance (unofficial Pwsh-host fork)
  -> verified model DLL and directly emitted Hexagon backend
  -> one bounded AAudio stream
  -> receipt over the same AOA pipe
```

ADB is a development bootstrap and independent observation tool only. It is not
part of the release command or data path. `tools/UsbAoa.ps1` negotiates Android
Open Accessory mode; `tools/Invoke-KokoroAoa.ps1` owns the re-enumerated WinUSB
bulk endpoints and exchanges framed messages. The Android diagnostic endpoint
is `src/runspace/Aoa.Appliance.ps1`.

## Wire contract

Each control frame is a four-byte little-endian payload length followed by
UTF-8 JSON. Requests contain `schema`, a 32-character request `id`, an admitted
`operation`, and a `payload`. Replies repeat the schema and request id and carry
either `data` or `error`. Control frames are limited to 256 KiB. Model inputs
and other large binary artifacts will use separately typed, length-bounded,
hash-checked frames; they are not embedded as JSON arrays.

The endpoint never evaluates source received from USB. The current appliance
startup dispatch admits only the internal `status` token. AOA `ping`, `receipt`,
`speak`, `benchmark`, and `transcribe` are not admitted product operations;
each requires an implemented resident handler and a physical-device round trip
before admission. The interactive Windows loop may look like a REPL,
but the wire carries typed operations rather than PowerShell source.

## Residency and latency

AOA is the control plane, not the DSP transport. The owned Hexagon backend must
use a source-traced platform boundary and keep model weights, specialization
data, reusable tensor arenas, and the AAudio stream resident across turns.
A speaker change selects a verified voice resource; it must not reload the
model. The Windows client sends only the next bounded plan and required inputs.

Cold launch, USB negotiation, model load, control round trip, synthesis,
first audio, playback completion, and peak memory are separate receipt fields.
AOA cannot be credited with a latency improvement until those measurements
distinguish it from the current ADB development harness.

## Compatibility boundary

The present directly emitted kernel evidence covers SM8550 and SM8635, not
complete speech. A compatible Android device must support AOA device mode,
permit the app to open the accessory, expose the admitted Hexagon backend,
and pass its own graph, FP32-reference, PCM, playback, and memory receipts.
V73 compatibility is not inferred from a marketing name or Android version.

The release APK still needs two gates before the Windows demo is ADB-free:

1. its manifest and accessory filter must launch the NativeActivity for the
   pinned Kokoro AOA identity and grant the public accessory API path;
2. the Xamarin-free host must obtain and service the accessory descriptor via
   its narrow JNI boundary while keeping the model backend and AAudio resident.

Until both pass on hardware, the repository has an admitted host transport and
a diagnostic Android endpoint, not a completed ADB-free speech service.
