# Pwsh downstream engine assembly result — 2026-09-28

## Scope

This result establishes the repository and managed-artifact boundary between
the Xamarin-independent Pwsh appliance and the Kokoro downstream engine. It
does not establish synthesis or device execution.

## Pinned inputs

- Pwsh commit: `ba84d1921c272699b45e75e21360a454fb647f7c`.
- Kokoro model revision: `f3ff3571791e39611d31c381e3a41a3af07b4987`.
- Stock checkpoint: 327,212,226 bytes, SHA-256
  `496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.
- `af_heart` voice container: 523,425 bytes, SHA-256
  `0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF`.

`tools/Get-PwshUpstream.ps1` and `tools/Get-KokoroModelInput.ps1` fetched the
immutable inputs into the ignored `build/` tree and passed online and offline
integrity verification.

## Intermediate gates

- `Kokoro.Weights.FP32.dll`: 327,285,248 bytes; all 548 contiguous FP32
  tensors embedded; tensor payload bytes 327,053,640; complete index true.
- `Kokoro.Phonemes` with `af_heart`: 525,312 bytes; 114 vocabulary mappings,
  510-phoneme limit, boundary IDs, and 522,240-byte voice tensor passed the
  Windows load gate.
- The phoneme builder imports only
  `Write-MicrosoftLambdaToMethodBuilder` and `Set-DeterministicMvid` from the
  whole-file-hash-verified Pwsh `setup.ps1`. It no longer reads
  `setup-kokoro.ps1`.

## Consolidated assembly

`tools/Build-KokoroEngineAssembly.ps1` emitted:

- assembly: `Dev.MansfieldPlumbing.Kokoro.Model`;
- size: 327,809,536 bytes;
- SHA-256: `682356E5EE8F913CD69E259C0AA309F567F81F36B2BC714867286856994CA6C3`;
- resources: 548 weight tensors, the weight index, one `af_heart` voice tensor,
  and a versioned engine-contract receipt;
- methods: phoneme IDs, voice-row index, vocabulary identity, graph identity,
  model-contract version, and `SynthesisReady`;
- PE contract: IL-only, no managed-native/ReadyToRun header;
- synthesis contract: `SynthesisReady = false`, with no
  `SynthesizePhonemes` method.

Two independent builds from the same verified part assemblies produced the
same byte length and full SHA-256. A fresh PowerShell process loaded and
verified the final assembly.

The same final assembly then passed the Windows `Model.Store.psm1` path with
an ephemeral test signing key: signed-manifest verification, content-addressed
installation, atomic activation, and fresh-process active-model load all
passed. The observed install took 734.4 ms in that single diagnostic run; it
is not a benchmark or an Android timing claim.

## Evidence boundary

The graph identity still describes the current two-node parsed decoder
contract. The assembly does not execute ALBERT, duration, F0/noise, decoder,
generator, or waveform stages and has not been admitted by the Android model
store. It is a reproducible weight-bearing downstream container, not a working
Kokoro synthesizer.
