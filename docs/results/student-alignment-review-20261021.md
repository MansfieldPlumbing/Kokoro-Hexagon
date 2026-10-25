# Independent review support for human alignment

Implementation: Kokoro-Hexagon commit `38884dd`, in `student/Invoke-Student.ps1`.
The Audit step accepts an Alignment result, verifies its source audio identity and bounds, and selects
review cases by a deterministic source-identity hash. Sampling is stratified by boundary side and absolute
snap magnitude. It writes mono review audio, a review CSV and a typed receipt under the ignored build tree.
No source alignment or production image is modified.

The check receipt (`../../../../Kokoro-Hexagon/build/student-alignment-audit-check.clixml`), SHA-256
`0F141128E84849D9724BEB4B0B5E09C9459D252B1410E556E91A496B0D4CC2E8`, records 32 review cases selected
from 4,296 word boundaries in the [Alice alignment](student-human-word-alignment-20261021.md).
All review WAV headers pass the declared 16,000 Hz PCM layout and payload-length checks. Context extends
one second on each side where the recording permits it. The receipt points to the generated review material.

An annotation pass takes the original Audit result and a reviewed CSV. It rejects unknown or duplicate
case identities, unsupported status values, missing reviewer identities, nonfinite times and observations
outside the supplied audio context. ObservedSeconds is measured from the original recording start.
Ambiguous cases remain separate from reviewed and unreviewed cases.

The blank CSV round trip reports zero reviewed cases and a null mean absolute boundary error. No independent
timing accuracy is established by this measurement. Reviewed-case mean absolute error, once annotations
exist, describes this stratified sample and is not a population-weighted estimate.

The Verify log (`../../../../Kokoro-Hexagon/build/student-verify-alignment-audit.log`) passes before commit.
