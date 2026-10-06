# Generator 256-channel integer operators, V73 simulation, 2026-10-06

Local uncommitted work based on repository commit 8cc06b96e9dd5546dfd76da40f59967be55d1789.
Stock source: hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec,
kokoro/istftnet.py AdaIN1d and AdaINResBlock1. Checkpoint SHA-256:
496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4.

The six integer operator emitters now accept 128 or 256 channels. Default
128-channel math in all six is byte-identical to the checked artifacts. The 256-channel
forms match SDK assembly. The wider affine and Snake variants use an explicit
pointer adjustment where a vector immediate cannot reach the second array.

Using the original stock generator resblocks.0 stage-0 input, 1,300 frames and
256 channels (41 native tiles):

| Check | Result |
| --- | --- |
| Complete-group sums and squared sums | 0/512 mismatches |
| Live AdaIN gain/offset | 0/512 mismatches |
| AdaIN signed Q8 output | 0/332,800 mismatches; 0 clipped values |
| Snake and A8 requantization | 0/332,800 mismatches; 0 clipped values |
| AdaIN versus captured stock FP32 | 28.2288294260827 dB SNR; RMSE 0.0358659827863272 |
| Snake versus captured stock FP32 | 26.5087092577084 dB SNR; RMSE 0.0518804637478368 |

AdaIN output SHA-256: 5CB4F4843E011C9D4C2E9EF5936806E6100C598FE835CF7907E3C3A16C4E41FA.
Snake output SHA-256: DCA50F42F700690B88EE55488866C2B50A7ECA97A21EBCBD7216E7379523DD6A.
Relabeled stock capture manifest SHA-256: 9F8259C8B1F93DE1002AA9CA11F441E3D89510579C2EABDEC63494F5902EF353.

| Emitted ELF | SHA-256 |
| --- | --- |
| Moments | 52BC528CC128F2D3F0767CE233BE859D5CF294F3DBDCB80EF095DD664CB7F31A |
| Coefficients | 80DE5E04CB7A9DBE2258A1B66309DE79F874C93C6CCFC2764CF6586503B42132 |
| Affine | 2529B22FC264A2615A23D0FCBDC161AFA94EDEA6C169C08CF00C13F66E4C70B4 |
| Snake | B954BA60039FC1B07A32D3DDFF4AE28CA74C7095016990B568F079CD4B33792A |
| Residual | 13203D9016ABF1E0E2017B4D689F16B92464D14751BA9198C4B00EEAF7BCEBC4 |
| Three-branch mean | 7A5CD1F1BCCA8BBEC4F065C651D9BA2336CC0F812A72BB11BDF88EF6525788F8 |

Reference tools stage buffers and execute the emitted arithmetic in hexagon-sim
-mv73. The numerical comparison reads the original stock PyTorch captures;
integer-contract calculations diagnose implementation correctness. SDK assembler
SHA-256: FC64C65ACA06186106A73BA93E65DDF7C906BF4905B786DC748D3F034401EA27.

The 256-channel three-branch mean also matches SDK assembly and passes a seeded
64-frame fixture with three different input scales: 0/32,768 byte mismatches.
Fixture: build/generator-c256-average-fixture-20261006. This checks both halves
of the wider native tile against the integer mean contract.

This proves these 256-channel operator cases in simulation. Residual emission
is checked against SDK assembly; a connected 256-channel residual block and its
phone run remain pending. These tensor errors are diagnostics, with no audio
acceptance threshold. This is not generated phone speech or a whole-model timing.

Fixtures: build/generator-block0-statistics-20261006,
build/generator-block0-adain-20261006, build/generator-block0-snake-20261006.
Reproduce with the New-KokoroAdaInStatisticsFixture, New-KokoroAdaInIntegerFixture
and New-KokoroSnakeIntegerFixture tools, IntegerChannels=256 emission,
run-statistics.sh, run-adain-integer.sh and run-snake-integer.sh (channels=256),
then compare_integer_adain.py and compare_integer_snake.py.
