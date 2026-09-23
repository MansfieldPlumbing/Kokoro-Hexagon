# Executable mapping on the DSP is closed

Asked because a generic skel that jumps into a code buffer would remove the Hexagon
toolchain from the loop entirely: emit HVX instruction words from PowerShell into rpcmem and
call them. It does not work, and the answer is documented rather than inferred.

## Host side offers no execute permission

`libcdsprpc.so` on the device exports the full mapping surface — `remote_mem_map`,
`remote_mmap`, `remote_mmap64`, `fastrpc_mmap`, `rpcmem_alloc`, `rpcmem_to_fd` — but the
flags carry no permission control. From pinned upstream `fastrpc/inc/remote.h`:

```
FASTRPC_MAP_STATIC   "Map memory pages with RW- permission and CACHE WRITEBACK."
FASTRPC_MAP_FD       "Map memory pages with RW- permission ..."
FASTRPC_MAP_FD_DELAYED
    "Mapping delayed until user calls HAP_mmap() and HAP_munmap() functions on DSP.
     Delayed mapping is useful for users to map buffer on DSP with other than default
     permissions and cache modes using HAP_mmap() and HAP_munmap()."
remote_mem_map: "Currently only REMOTE_MAP_MEM_STATIC is supported."
```

So the only route to non-default permissions is DSP-side `HAP_mmap`.

## DSP side defines execute and refuses it

Hexagon SDK 6.4.0.2, `incs/HAP_mem.h`:

```c
#define HAP_PROT_EXEC   0x04    /* pages can be executed */
```

> "Passing HAP_PROT_EXEC as input results in setting 'Execute' permissions on the buffer.
>  Currently not supported."

and on `HAP_mmap` itself:

> "@param[in] prot protection flags - supported are only HAP_PROT_READ and HAP_PROT_WRITE.
>  HAP_PROT_EXEC is not supported"

The constant is defined; the capability is not implemented. This is independent of signed
versus unsigned PD.

## Consequence

A partition cannot become a kernel by emitting instruction words at runtime. The skel has to
hold a small interpreter instead: opcodes for pointwise operations, reductions and tile
moves, with operands as rpcmem pointers. The opcode stream is data, so no executable mapping
is required and `HAP_PROT_EXEC` never arises.

That costs one pass through the vendor toolchain to build the interpreter, after which every
fused partition is a byte stream written from PowerShell. It is the same shape as the kernel
symbol table found inside a QNN context (context-anatomy-20260923.md) — operations as table
indices, operands as pointers — with the table under our control.

Dispatch overhead is the risk and it is manageable at these sizes: a fused pointwise chain
over a [1,16,19200] tile is one dispatch per operation per tile across 307,200 elements. It
only becomes a problem if opcodes are made too fine-grained, which is ours to choose.
