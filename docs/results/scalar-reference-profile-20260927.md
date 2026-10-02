# Stock scalar-reference profile, 2026-09-27

Scope: one admitted phoneme, boundary token IDs `[0,43,0]`, speed 100,
`af_heart` voice row zero, pinned Kokoro checkpoint SHA-256
`496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4`.
These are local Windows PowerShell-reference timings, not Android, cDSP,
speaker, or time-to-first-audio measurements.

The acoustic reader's original exhaustive admission took 0.9 s to hash the
312 MiB checkpoint, 1.1 s to parse tensor descriptors, effectively 0 s to
check the 171 descriptor shapes/strides, and 113.9 s to copy their bytes and
scan every FP32 value for finiteness. The exhaustive acoustic, decoder, and
generator reader gates had already passed for this exact checkpoint digest.
For development re-runs, `-SkipFiniteScan` still verifies that exact digest,
all declared shapes and strides, and the byte copies; it rejects any change
to the audited digest. The acoustic byte-admission stage then took 2.0 s.
This is reuse of an audited property of identical bytes, not a claim that
unchecked weights are valid.

With the same model input, the full 12-repeat scalar ALBERT encoder took
423.8 s. The following BERT projection took 2.8 s, duration branch 43.1 s,
three-layer text encoder 36.2 s, alignment below 0.1 s, and F0/N branch
63.3 s. The decoder prelude completed, then the run was stopped deliberately
before the decoder core and generator. No PCM was produced or heard. The
PowerShell scalar operator path is therefore an impractical product backend,
but its bounded gates remain useful for same-input/same-weight differential
checks of directly emitted Hexagon operators.

The source contract for the ALBERT repeat count is pinned Kokoro
`dfb907a02bba8152ca444717ca5d78747ccb4bec` and Transformers
`8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10`; the timing applies only
to this repository's PowerShell implementation and host. It does not
establish a performance bound for the DSP path.
