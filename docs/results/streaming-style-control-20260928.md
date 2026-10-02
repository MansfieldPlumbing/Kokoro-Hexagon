# Streaming style-control contract

## Scope

This receipt defines a candidate control boundary for the pinned Kokoro-82M
checkpoint. It does not establish direct DSP speech, causal stock synthesis,
or audio quality for a non-zero mutation.

For a selected voice, each AdaIN site has a fixed 128-value style vector
`s0`, projection matrix `W`, and bias `b`. The compiler may materialize the
per-voice base control once:

```text
[g0, b0] = [1, 0] + W * s0 + b
```

An admitted descriptor carries a bounded sparse delta `delta s`, not an
activation or audio buffer. The resident model materializes the mutated
control as:

```text
[g, b] = [g0, b0] + sum(W[:, index] * delta for each descriptor entry)
y = ((x - mean_t(x)) / sqrt(var_t(x) + 1e-5)) * g + b
```

The first expression is a compiler/runtime control optimization. The second
remains the stock AdaIN live activation operation for the committed segment.

## Descriptor boundary

`New-KokoroStyleControlDescriptor.ps1` canonicalizes a descriptor containing:

- schema, monotonic revision, and commit watermark;
- voice identity and style-vector dimension;
- at most 32 finite, bounded `(style coordinate, delta)` entries.

Duplicate coordinates are summed, zero entries are removed, and invalid
coordinates are rejected. The descriptor has no waveform, activation, or
operator payload. It is suitable for a future managed-model/DSP control queue,
where the consumer rejects stale revisions.

The pinned generator declares 48 AdaIN projection sites, totaling 18,432
gain/shift scalars (73,728 bytes as FP32) if every site were transmitted in
full. A descriptor instead carries only changed style coordinates. The DSP can
retain the base projections and source matrices, then materialize all affected
site controls locally. The arithmetic and transport cost of that choice remain
to be measured on the physical target.

## Exact projection gate

`Test-KokoroAdaInSparseStyleControl.ps1` used pinned stock checkpoint and
`af_heart` data, selected
`decoder.module.generator.resblocks.3.adain1.0.fc`, and applied three
descriptor deltas. The materialized control differed from a fresh stock
projection by at most `1.9055417155300347e-07`.

This verifies only the linear style-control algebra at one AdaIN site. It does
not authorize mapping punctuation or a semantic label to any particular style
coordinate. Such mappings are model variants and require next-consumer,
duration/F0, spectral, waveform, and listening gates.

## Streaming constraint

The stock contextual encoder and AdaIN time reduction require a committed
segment's whole relevant span. A revision may change an uncommitted descriptor
immediately; it cannot alter PCM already emitted. A time-varying affine within
one segment is non-stock and must be evaluated as a separate model contract.
