# S23 CDSP node inventory — 2026-09-26

A read-only ADB check saw one authorized device, the Galaxy S23. The Razr+
was not enumerated by ADB during this check, so no same-session comparison
was made. No package was installed and no DSP job was invoked.

The S23 reported Android 16 and a 5.15.189 kernel base. This does not match
the 5.15.208 LineageOS kernel revision proposed in the external source
report; that source is not device-build-matched evidence for this phone.

The checked shell context was `u:r:shell:s0`. A read-only listing of the
source-named `/dev/fastrpc-*` and `/dev/*dsprpc*` paths found only
`/dev/adsprpc-smd` (mode `0664`, `system:system`,
`vendor_qdsp_device`) and `/dev/adsprpc-smd-secure` (mode `0644`,
`system:system`, `vendor_xdsp_device`). It did not find a CDSP-named node
at those paths. This contradicts the external report's claimed S23 node
inventory but does not rule out a different route, a service-mediated path,
or the owner's separately reported queue-style test. Shell context and app
context are different; these mode bits do not establish app access.

The earlier app-context raw-open probe returned `EACCES` on the ADSP-named
node. Its result remains separate from this shell-context inventory and
from any CDSP queue test.
