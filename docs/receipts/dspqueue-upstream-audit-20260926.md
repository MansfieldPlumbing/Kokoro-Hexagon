# DSPQueue upstream boundary — 2026-09-26

Qualcomm's public FastRPC source at immutable commit
`d247519650fe5cb16de6c78edaa95bcc4be25073` defines a
QNN-independent packet queue. Its
[shared header](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/inc/dspqueue_shared.h#L11-L69)
specifies one shared buffer, request and response ring headers, separate
cache-line state, packet alignment, version, and flags. Its
[IDL](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/idl/dspqueue_rpc.idl#L10-L45)
defines the static FastRPC-shell interface used to initialize, create,
destroy, and signal queues.

The [CPU implementation](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/src/dspqueue/dspqueue_cpu.c#L220-L305)
obtains a queue-service URI, opens it through FastRPC, maps process state,
and checks DSP and driver signaling capabilities. The
[signal path](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/src/dspqueue/dspqueue_cpu.c#L1217-L1232)
uses driver signaling when available and otherwise wakes a host thread;
that thread can call
[dspqueue_rpc_signal](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/src/dspqueue/dspqueue_cpu.c#L2564-L2575).
Therefore QNN-free queue dispatch does not imply a universally
FastRPC-ioctl-free per-job path. The actual notification behavior must be
measured for the selected mode and device.

The supplied external portability report lists candidate Motorola and
LineageOS source revisions. They have not been matched to the installed
firmware builds. Its proposed device-node inventory conflicts with this
repository's earlier read-only node observation, and a listed CDSP daemon
does not by itself establish that app calls are proxied through that daemon.
Qualcomm's [daemon architecture](https://github.com/qualcomm/fastrpc/blob/d247519650fe5cb16de6c78edaa95bcc4be25073/Docs/daemons.md#L4-L75)
describes daemons as default listeners for DSP reverse calls and dynamic
protection-domain clients as direct peers. No device-specific access route
is selected from the external report.

The reported Razr+ queue-style bypass, S23 failure, and approximately
0.1 ms dispatch figure remain unlinked to a reproducible artifact in this
checkout. Queue Monitor import semantics and an owned DSP-side queue
consumer are not established by the cited public CPU source alone. The
next gate is to recover the prior test and identify its exact bootstrap,
queue creation, signal mode, measured interval, and first S23 failure stage.
Until then, DSPQueue is a candidate product transport, not a passed gate.
