# Direct FastRPC native-open probe

Date: 2026-09-25

`FastRpcDirectIoctlProbe.ps1` was refactored to bind libc `open`, `ioctl`, and
`close` through `Native.Binding.psm1`. It no longer uses
`Android.Systems.Os`, reflects a managed file-descriptor object, or imports a
QNN-named delegate factory.

The refactored probe was staged with source-hash verification and run under
the installed appliance package on physical SM8550 and SM8635 devices. Both
returned `-1` when opening `/dev/adsprpc-smd`; neither reached the read-only
capability ioctl. Startup scripts were restored after each run.

This is a failed transport gate. The result does not distinguish app SELinux
policy, device-node permissions, or a C ABI defect, so no cause is assigned
without a source-matched policy/driver trace. The existing `libcdsprpc.so`
reference path remains separate evidence and is not a substitute for this
gate.
