# Runtime residual-stage frame count, SM8550

On 2026-10-11, one capacity-65 emitted residual-stage worker accepted live frame
counts 2, 31, 32, 33, 64 and 65 on the attached SM8550 target through the Kokoro
diagnostic APK. Each result matched a separately emitted fixed-length job exactly
in every valid native int16 lane. All inactive lanes through the 96-row allocation
were zero. The runtime input deliberately retained nonzero data beyond its live
length, so success required masking inactive rows rather than trusting input padding.

The diagnostic uses the existing stock-derived 128-channel, kernel-3 residual
fixture and four HVX workers. AdaIN uses the live length as its denominator;
convolution windows and outputs are masked before moment accumulation.

Runtime worker SHA-256:
`C33DAB925DE03363CA0C07087EB07A809344AA17B256147FE391E88FBD68F5C0`.
Source base: `bf3dfe2`, with local runtime-frame changes applied.

Reproduce with:

```powershell
./Invoke-KokoroDevelopment.ps1 Run -Case generator-runtime-frames `
    -Path build/generator60x16-fixture-20261008-holdout `
    -OutputDirectory build/runtime-generator-frames-20261011 `
    -HostPackage dev.mansfieldplumbing.kokoro -Soc SM8550
```

The generated receipt is `build/runtime-generator-frames-20261011/receipt.json`.
Runtime DSP measurements ranged from 5.661 to 5.703 ms. These are diagnostic
single-run observations; capacity-sized execution still performs inactive work.
This establishes residual-stage correctness, not a speed improvement, complete
generator runtime-length support, streaming state carry or phone-resident fresh-text
synthesis. Source generation, upsampling and the PCM tail remain separate gates.
