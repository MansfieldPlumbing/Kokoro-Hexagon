# Resident provider host control — 2026-09-24

Scope: Windows x64 behavioral control only. This is not an Android performance
receipt.

Command:

```powershell
pwsh -NoProfile -File tools/Test-Provider.ps1
```

Observed result on the development host:

```text
ProviderReady=True InputBytes=22 OutputBytes=22 InitializeMs=391.664 ProfileMs=257.713 FirstInvokeMs=115.812 WarmMeanUs=1206.013 Result=KOKORO STAYS RESIDENT.
```

The gate created one SMA runspace, admitted a profile by SHA-256 after parsing
its AST, cached its handler, passed UTF-8 text as data, received one byte array,
then reused the same provider for 1,000 warm invocations. The measured warm mean
includes the unmanaged-style pointer boundary, UTF-8 decode, script-block call,
UTF-8 encode and copy into the caller buffer.

The cold numbers are useful only to separate initialization from warm dispatch.
They are not forecasts for Android TTFT. The Android build still needs a
persistent provider entry point, physical startup/RSS measurement and first
speaker audio before making a product latency claim.
