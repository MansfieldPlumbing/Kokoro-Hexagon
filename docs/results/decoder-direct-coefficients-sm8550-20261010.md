# Decoder with direct AdaIN coefficients, SM8550, 2026-10-10

`-Moments Direct`: each AdaIN site loads its coefficients (`Km`) from the job input and computes no moments and no
coefficients. Hello world decoder (65 frames, `build/decoder16-fixture-20261009m4d`), capacity 65 with run-time
frames, chunks [0,41) and [24,65). The coefficients are the one pass's own, exported by `-Moments Export`. 3 runs per
job; DSP time is the median region time.

| Run | Output | DSP time |
| --- | --- | ---: |
| Whole utterance, moments accumulated (one pass) | reference | 14.601 ms |
| Whole utterance, its coefficients loaded directly | bit-exact with the one pass | 3.938 ms |
| Chunk [0,41), supplied moments / direct coefficients | bit-exact with each other | 13.365 / 2.909 ms |
| Chunk [24,65), supplied moments / direct coefficients | bit-exact with each other | 13.323 / 2.897 ms |
| Direct chunks stitched against the one pass | 61.97 dB | |

- With coefficients supplied, the decoder's AdaIN coefficient path (moments over the frames and the coefficient
  derivation, 10 sites, 9,632 channels) is about 10.5 ms of a 13.4 ms chunk and 10.7 ms of the 14.6 ms whole utterance.
  The rest (convs, weight streaming, LeakyReLU windows) is 2.9-3.9 ms. How the 10.5 ms divides between the HVX moments
  loop and the scalar coefficient derivation is not measured.
- This corrects `decoder-supplied-moments-sm8550-20261010.md`, which inferred that weight streaming was the fixed
  per-chunk cost. `Supplied` still derives coefficients from the supplied moments, which is why it saves little.
- The DSP side of the end state in `docs/adain-control-stream-design.md` is exact and faster; what remains is
  whether the front end can produce the coefficients. The generator's sites are not measured.

| Artifact | SHA-256 |
| --- | --- |
| Skel, Direct | `6523A50EE79EF4A9C6A53F73E2DC0166DE754810873CA2299C5865DE55C29C7B` |
| Skel, Supplied | `337B020C3CB6F932581DE241EE0680F33436478A366C88CC6EF3E271A7644EFD` |
| Skel, Export | as `decoder-coefficient-correction-sm8550-20261010.md` |
| weights.bin, tables.bin, activations.bin | as `decoder-supplied-moments-sm8550-20261010.md` |
