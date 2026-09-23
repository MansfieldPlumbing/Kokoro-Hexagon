/* Diagnostic only: SDK 6.4.0.2 remote.h / HAP_mem.h, Tools 19.0.04 QuRT API.
 * The caller supplies two PowerShell-emitted instructions; this bootstrap only
 * maps, copies, synchronizes caches and optionally invokes that tiny function.
 */
#include <stdint.h>
#include "remote.h"
#include "HAP_mem.h"
#include "qurt_memory.h"

__attribute__((visibility("default")))
int kqnn_exec_skel_handle_invoke(remote_handle64 handle, uint32_t sc, remote_arg *args) {
    (void)handle;
    if (sc == 0x00020001u) {
        if (!args) return 14;
        args[2].h64 = 1;
        return 0;
    }
    if (sc == 0x01000010u) return 0;
    if (sc != 0x02010100u) return 20;
    if (!args || args[0].buf.nLen < 24 || args[1].buf.nLen < 48 ||
        !args[0].buf.pv || !args[1].buf.pv) return 14;
    const uint32_t *in = (const uint32_t *)args[0].buf.pv;
    volatile int32_t *out = (volatile int32_t *)args[1].buf.pv;
    const int fd = (int)in[0], prot = (int)in[1], execute = (int)in[2];
    if (fd < 0 || (prot != 3 && prot != 5 && prot != 7) ||
        (execute != 0 && execute != 1) || (execute && !(prot & HAP_PROT_EXEC)) || in[5] != 4096) return 14;
    for (int i = 0; i < 12; ++i) out[i] = -999;
    out[0] = 0x45584543; out[1] = prot;
    void *rw = HAP_mmap(0, 4096, HAP_PROT_READ | HAP_PROT_WRITE, 0, fd, 0);
    out[2] = rw != (void *)-1 && rw != 0;
    if (!out[2]) return 0;
    volatile uint32_t *words = (volatile uint32_t *)rw;
    words[0] = in[3]; words[1] = in[4];
    out[10] = words[0] == in[3] && words[1] == in[4];
    out[3] = qurt_mem_cache_clean((qurt_addr_t)rw, 8, QURT_MEM_CACHE_FLUSH, QURT_MEM_DCACHE);
    out[4] = HAP_munmap(rw, 4096);
    if (out[3] || out[4] || !out[10]) return 0;
    void *target = HAP_mmap(0, 4096, prot, 0, fd, 0);
    out[5] = target != (void *)-1 && target != 0;
    if (!out[5]) return 0;
    words = (volatile uint32_t *)target;
    out[11] = words[0] == in[3] && words[1] == in[4];
    out[6] = 0; out[7] = 0; out[8] = 0;
    if (execute && out[11]) {
        out[6] = qurt_mem_cache_clean((qurt_addr_t)target, 8, QURT_MEM_CACHE_INVALIDATE, QURT_MEM_ICACHE);
        if (!out[6]) {
            out[7] = 1;
            out[8] = ((int (*)(void))target)();
        }
    }
    out[9] = HAP_munmap(target, 4096);
    return 0;
}
