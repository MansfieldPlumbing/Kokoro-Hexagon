// Kokoro-QNN DSP kernels (Hexagon V73). Plain C written for HVX auto-vectorization; timed with the QTimer.
#include <stdlib.h>
#include "HAP_farf.h"
#include "HAP_perf.h"
#include "kqnn.h"

int kqnn_open(const char *uri, remote_handle64 *h) { *h = (remote_handle64)malloc(1); return *h ? 0 : 1; }
int kqnn_close(remote_handle64 h) { free((void *)h); return 0; }

int kqnn_noop(remote_handle64 h, const int16 *x, int xLen, uint64 *dspTicks) {
    uint64 t0 = HAP_perf_get_qtimer_count();
    *dspTicks = HAP_perf_get_qtimer_count() - t0;
    return 0;
}

// x is [channels][T] int16, channel-contiguous. sums[2c] = sum(x), sums[2c+1] = sum(x*x), exact in int64.
int kqnn_stats(remote_handle64 h, const int16 *x, int xLen, int32 channels, int64 *sums, int sumsLen, uint64 *dspTicks) {
    if (sumsLen >= 3) { sums[0] = xLen; sums[1] = channels; sums[2] = sumsLen; }   // echo what the DSP received
    if (channels <= 0) return 11;
    if (xLen % channels != 0) return 12;
    if (sumsLen < 2 * channels) return 13;
    uint64 t0 = HAP_perf_get_qtimer_count();
    int T = xLen / channels;
    for (int c = 0; c < channels; c++) {
        const int16 *row = x + (size_t)c * T;
        int64 s = 0, q = 0;
        int32 s32 = 0; int64 q64 = 0;
        for (int t = 0; t < T; t++) { int32 v = row[t]; s += v; q += (int64)(v * v); }
        sums[2 * c] = s; sums[2 * c + 1] = q;
    }
    *dspTicks = HAP_perf_get_qtimer_count() - t0;
    return 0;
}
