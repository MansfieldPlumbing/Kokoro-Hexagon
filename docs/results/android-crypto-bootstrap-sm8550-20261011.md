# Android crypto bootstrap and preserved sentence, SM8550

On 2026-10-11, the attached SM8550 target running Android 16 completed the protected
network-free sentence through the Kokoro diagnostic APK. Device identifiers were not retained.

The previous APK reached PowerShell but faulted at its first library SHA-256 calculation.
Pwsh commit `8dc04b1f4284f0a229e3f0daa45a0372fdb7d8e4` supplies the owned Java activity,
Java-side crypto initialization, runtime helper DEX and native callback registration.
Kokoro retains both DEX files and all native payloads unchanged, with its own package
identity and development signer. PowerShell emitter and payload both use 7.7.0-preview.5;
the runtime and Pkcs package remain pinned to .NET 11 RC1.

APK SHA-256: `8971F00E46701CDBEAA41F42BA1294F90359ECCEEF0877AEBD830F00F89C41EB`.
APK length: 17,749,002 bytes. Signature v2 and archive payload readback passed.
Kokoro source base: `bf3dfe2`, with the integration changes locally applied.

Command: `Invoke-KokoroDevelopment.ps1 Run -Case network-free-peach-sm8550 -HostPackage dev.mansfieldplumbing.kokoro -Runs 1`.

| Measurement | Result |
| --- | ---: |
| DSP execution, one run | 143.026 ms |
| Synchronous host invoke, same run | 187.845 ms |
| PCM samples at 24 kHz | 51,000 |
| Audio duration | 2.125 s |
| PCM SNR against the retained reference | 31.29 dB |
| Clipped samples | 0 |
| AAudio written frames | 51,000 |
| AAudio xruns | 0 |

Unsigned-PD selection, worker open and invoke returned zero. The job reached stage 7,
reported completion and passed. AAudio reported playback and complete drain; this is
a playback receipt. On the requested replay, the listener clearly understood the
complete sentence, including the opening word. The previously observed weak opening
"I" remains unresolved; no pronunciation or model change was made for this run.

Worker SHA-256: `FEFF54DF8340F184FA909C35CFEE48D3F0010F8B37E7C7F0967759403F9672A5`.
PCM SHA-256: `E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054`.
Both match the protected baseline. The worker retains 14 convolution batch tiles and
its 7.75 MiB VTCM request. This run establishes successful execution, not an independent
measurement of the VTCM grant or an end-to-end fresh-text latency benchmark.

The runner restored the original absence of startup files. The frozen baseline and
its timing thresholds were unchanged. Phone-resident front-end integration remains pending.
