# Model assembly Windows load receipt

Date: 2026-09-24  
Source: repository `model.ps1` and `setup-kokoro.ps1 -Step 4 -KeepIntermediates -AcceptWritePlan`

The graph source was later renamed, byte-for-byte, to
`New-KokoroDecoderGraph.ps1`; the filename above records the path used for
this dated receipt.

The build verified the pinned package catalogs, parsed the model source into a two-node DAG, persisted its identity and control schema, and produced the managed assembly outside the repository.

```text
Assembly       Kokoro-Hexagon.dll
Bytes          15360
SHA-256        042EADF34367ABD71616520A75C0B3E7DD14B7318ECD11BEF2596CCFC923837B
Graph SHA-256  1AD914D60E464F0D990C66C5121E6E4E32F111AEEA0FE3567F9B9452F9A02D12
Nodes          2
Controls       asr,F0_curve,N,style,gb,har8,mask,mask8,capacity
```

`tools/Test-WindowsModelAssembly.ps1` then loaded that Android-build output directly in the current Windows PowerShell process, resolved `Dev.MansfieldPlumbing.Pwsh.NativeHost`, invoked `ModelGraphSHA256()` and `ModelControls()`, and matched the embedded graph hash to an independent lowering of the checked-out `model.ps1`.

This establishes a portable managed model identity and control surface. It does not establish Windows synthesis, phonemization, embedded weights, or Android execution for this assembly revision.
