# Direct FastRPC native-open probe

Date: 2026-09-25

`FastRpcDirectIoctlProbe.ps1` was refactored to bind libc `open`, `ioctl`, and
`close` through `Native.Binding.psm1`. It no longer uses
`Android.Systems.Os`, reflects a managed file-descriptor object, or imports a
QNN-named delegate factory.

The refactored probe was staged with source-hash verification and run under
the installed diagnostic app package on physical SM8550 and SM8635 devices.
Both returned `-1` when opening `/dev/adsprpc-smd`; neither reached the
read-only capability ioctl. Startup scripts were restored after each run.

The 2026-09-25 follow-up added `SetLastError` capture to the generic delegate
factory. Its clean-process Windows test confirmed that a failed native call
preserves the last-error value. On both Android devices, the same read-only
probe returned `OpenErrno=13` (`EACCES`). The probe and binding files matched
their staged source hashes; each startup script was restored from a backup.
No speech path was run.

The pinned [Qualcomm FastRPC userspace source at d247519](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/src/fastrpc_apps_user.c#L3202)
selects domain-specific device nodes; its
[device-name definitions](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/inc/fastrpc_ioctl.h#L29)
distinguish ADSP and CDSP. The upstream
[Android FastRPC driver](https://android.googlesource.com/kernel/msm.git/+/48497677f223bd018ce409aaeb4124df6ebcb07d/drivers/char/adsprpc.c)
likewise names separate `adsprpc-smd` and `cdsprpc-smd` channels. A targeted
read-only device-node check found only `adsprpc-smd` and its secure variant on
each current phone; neither exposes `cdsprpc-smd` or `fastrpc-cdsp` at that
path. Thus even a successful open of `adsprpc-smd` would not prove a CDSP
session. This upstream source is not asserted to be the phones' exact vendor
driver or policy build.

This is a failed transport gate. The result does not distinguish app SELinux
policy from other access controls or establish a permitted CDSP session API.
No private vendor ABI is inferred from binaries. The existing `libcdsprpc.so`
reference path remains separate evidence and is not a substitute for this
gate. The stock-app Hexagon path cannot be promoted until a documented,
permitted CDSP transport contract is identified and implemented.
