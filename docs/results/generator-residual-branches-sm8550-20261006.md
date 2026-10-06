# Generator residual branches on SM8550, 2026-10-06

Repository baseline: `8cc06b96e9dd5546dfd76da40f59967be55d1789`, with the
accompanying source changes. Stock Kokoro source:
`dfb907a02bba8152ca444717ca5d78747ccb4bec`, `kokoro/istftnet.py`
AdaINResBlock1 and Generator.forward. Checkpoint SHA-256:
`496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.

The existing connected integer runner now covers kernel sizes 3, 7 and 11.
Each branch runs six live full-group AdaIN/Snake/convolution stages and
three residual additions using the original captured 128-channel,
7,801-frame generator input. Weight quantization is per output channel;
activation ranges use the full-range baseline. No topology change is made.

| Branch | Kernel | Full-wrapper V73 simulation | SM8550 runs | Median DSP region ms | Final tensor SNR versus stock FP32 |
| --- | ---: | --- | --- | ---: | ---: |
| resblocks.3 | 3 | exact | 3/3 exact, earlier receipt | 211.991 | See connected-block receipt |
| resblocks.4 | 7 | exact | 3/3 exact | 204.731 | 20.311329 dB |
| resblocks.5 | 11 | exact | 3/3 exact | 213.282 | 22.019639 dB |

Each K7/K11 simulator and phone run has zero mismatches across 999,424
meaningful native output lanes and all 6,144 coefficient bytes. All six
stages complete, resource and lock calls succeed, and the firmware grants
524,288 bytes of VTCM. Host startup files are restored and their hashes
verified after each probe. The phone output hashes also match the full
simulator output tensors. K3 details are in
[the earlier phone receipt](resblock3-integer-device-sm8550-20261006.md).

| Artifact | SHA-256 |
| --- | --- |
| K7 emitted ELF | `3A343CCD2E48B4992B1CAFBE29F7460D9F97A0462B2C86F007CCF285FF451218` |
| K7 returned native tensor | `36F49C6CCE664C7067DE0702F31551D8AA17393EACDECF8547962D4C5E144C01` |
| K11 emitted ELF | `8FAA01EAF62ADF8A7930EE70C39AB9574F74FA2BA6F3F36A9EC9D1ED859F6D14` |
| K11 returned native tensor | `15AB0AA74112928D2B6265B264C0893F739F8FDC6B5579D088C593173E804ACD` |

DSP ticks use 19.2 MHz and include connected-region staging. These proof
runners use blocking copies and synchronous FastRPC, with full-group
buffers in shared DDR. They establish connected correctness and diagnostic
timing; they do not establish persistent dspqueue performance, DMA
ping-pong, whole-model RTF, TTFA or audio quality. SM8635 was not tested.

Reproduce emission with `Test-HexagonEmission.ps1 -Kernel KokoroResBlockRun
-ResBlockKernel 7` or `11`, preserving the same frame count. Use
`Export-KokoroGeneratorBlockCapture.ps1`, the connected integer fixture and
run-fixture tools, `Test-KokoroResBlockRunner.ps1`, and
`Invoke-ResBlockRunProbe.ps1`. Raw receipts remain in ignored
`build/generator-block4-run-fixture-20261006` and
`build/generator-block5-run-fixture-20261006`.

## Three-branch mean and final LeakyReLU in simulation

The emitted integer mean consumes the three checked branch outputs in their
native layout. For this capture, its 1,998,848 output bytes exactly match the
integer mean contract; comparison with the original stock branch mean is
22.665159 dB SNR, RMSE 0.3973752604 and maximum absolute error 3.777032830.
Output SHA-256:
`1D23542E5CA3FA6AD4A57EACF54D8547DDDF98D941A11FDC03F431CB8DB85A7E`.
Mean ELF SHA-256:
`B15486C3119137BDB0EE5AE8BF0B1BE370577BAF0D532BD88B7FDB5A120566F2`.

The integer LeakyReLU emitter supports stock slopes 0.1 and 0.01, both
128 and 256 channels, and aliased input/output. In simulation, the real
128-channel mean followed by slope 0.01 has zero byte mismatches both in
place and out of place. Comparison with the original stock post-LeakyReLU
capture is 23.333752 dB SNR, RMSE 0.1567885787 and maximum absolute error
3.093507365. Output SHA-256:
`E1C92184F565D9E92DF943E1F2D8B54768E75A89A786D5844A65EF4FB413BA05`.
ELF SHA-256:
`E3AC86848DE47915C27A145A37504C9D68B0FCBB98469110BAB0868883290A57`.
The seeded 256-channel, slope-0.1 case also has zero mismatches across
32,768 bytes in both modes; ELF SHA-256:
`E88AD2222094EBB4035A5952DC3F8AFC060209B3A61E9DF4041BFB2ACF022751`.
LeakyReLU has not been run on a phone or joined to the combined worker.

The extended stock capture contains 642 tensors; all 636 original tensors
retain their hashes. The six additional tensors capture the original stock
LeakyReLU inputs/outputs, without reimplementing model arithmetic.
Manifest SHA-256:
`D7BCD6916B6B30B12AF6C3C1C7658D676C3E9B914D083111F14AB17D5E05A0DF`.
Tensor SNR values are diagnostic, with no audio acceptance threshold.

## Combined worker: verification pending

`Kokoro.Generator60xRun.ps1` composes the three branches and native-layout
mean in one correctness job. The corrected ELF matches SDK assembly;
15 HVX bodies, nine convolution bodies and the mean body retain their
checked bytes. Four malformed-input cases pass with telemetry preserved.
Corrected ELF SHA-256:
`3DA827414366BC38B0DB061FDC730F2F337D5F8266F70B918B684B93D9733D31`.

We paused the complete arithmetic simulation at the time limit.
There is no completed arithmetic result or phone run for this combined
ELF. A prior combined candidate contained a base-pointer offset bug and
was superseded before phone deployment; its results do not establish
correctness. Resume with a fresh fixture and the corrected ELF, complete
`Test-KokoroResBlockRunner.ps1`, then use
`Invoke-ResBlockRunProbe.ps1 -Graph Generator60x` on the same checked image.
The corrected artifact and fixture are retained in ignored
`build/generator60x-v2-emission-20261006` and
`build/generator60x-v2-run-fixture-20261006`. The interrupted fixture must
not be treated as a passing simulator result.
