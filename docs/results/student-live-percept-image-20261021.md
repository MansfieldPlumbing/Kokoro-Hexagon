# Live Student percept image

Implementation: Kokoro-Hexagon commit `4e2e213`, in `student/Invoke-Student.ps1`.
`Percepts` opens live typed objects with shared ETS methods for observing evidence, pinning a percept,
querying its neighborhood, inspecting graph shape, creating attached specializations, connecting progression
edges and checkpointing. `Describe` reports examples, counter-examples, recordings, rules, genealogy and
untested or exception-heavy evidence shapes.

The image owns its percept graph and physical controller performances. Occurrence recordings reference the
same performance and evidence objects. Persistence flattens identities only at the checkpoint boundary;
restore reconstructs shared objects and binds them to the common machine. Percepts contain no executable
source, stored audio, generator tensors or per-percept interpreter. Checkpoints use compressed PowerShell
serialization, with atomic replacement and the previous checkpoint retained for recovery.

## Production image

The production checkpoint receipt (`../../../../Kokoro-Hexagon/build/student-image-checkpoint.clixml`) records
the image built from the [human alignment](student-human-word-alignment-20261021.md):

| Measure | Result |
| --- | ---: |
| Initial typed percepts | 3 |
| Human occurrence observations | 2,148 |
| Shared controller performances | 1 |
| Fixture observations | 0 |

The production image (`../../../../Kokoro-Hexagon/build/student/image.clixml.gz`) has SHA-256
`982F553FB058D391160C3C37E92E1D71B93EBA98D572F02B49AF4E2C44C08F04` at this checkpoint. The generic Word
percept is reported as untested because it has examples but no counter-examples. These observations do not
admit a pronunciation or prosody rule; held-out rule admission is subsequent work.

## Persistence and runtime mutation checks

The isolated image test receipt (`../../../../Kokoro-Hexagon/build/student-image-check-20261021T094855/receipt.clixml`),
SHA-256 `F28E194C51A032D79D06BF37CA070205DBCF9D6220E2643661ECBD902CF299C4`, records these checks:

| Measure | Result |
| --- | ---: |
| Compressed test checkpoint | 5,461,669 bytes |
| Test percepts | 4 |
| Test evidence objects | 2,149 |
| Test-only counter-example fixtures | 1 |
| Shared performances | 1 |
| Percepts consulted at pinned depth | 3 |
| Complete create, mutate, checkpoint and restore sequence | 185.766372 seconds |

Reference-identity checks pass for restored parents, evidence and occurrence recordings. A counter-example
added through the live object's Observe method survives checkpointing. An attached branch retains its
counter-evidence genealogy, and a prerequisite edge survives restore. Neighborhood lookup excludes the
unrelated sibling at the tested depth. The fixture image is isolated from the production image.

The test checkpoint has SHA-256 `5F64D592D7F6E33AFA6D12E52BB45A7D714ED4ACC24901261C24951658941243` and the
receipt records machine SHA-256 `40C633B215DAE7DFEFA16214E53E2732F37C3D8E5BD4CBDB75C8D73CBBD6532A`.
The Verify log (`../../../../Kokoro-Hexagon/build/student-verify-image.log`) passes before commit.
These are host object and persistence checks, not phone throughput or learned-rule acceptance measurements.
