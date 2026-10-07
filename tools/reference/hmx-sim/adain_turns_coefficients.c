/* hexagon-sim harness for the PowerShell-emitted phase-turns coefficients
 * (src/emit/Kokoro.AdaInTurnsCoefficients.ps1). Moments come from random 16-bit data per channel;
 * per-channel Ka, Mb, S, epsD are random. Integer model of the contract:
 *   D = N * (65536 A2 + 512 AB + B2) - S1^2 + epsD, root = floor(sqrt(D)),
 *   K = sign(Ka) * floor((|Ka| N + root/2) / root), M = Mb - sign * floor((|K S1| + N 2^14) / (N 2^15)).
 * Also reports the worst relative error of K against the real-valued AdaIN gain. Test tool only. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#define CH 128
#define N 777
typedef void (*fn_t)(const void* moments, const void* params, void* out, unsigned n);
static uint32_t lcg = 31337;
static uint32_t rnd32(void) { lcg = lcg * 1103515245u + 12345u; return (lcg >> 8) ^ (lcg << 13); }
static int rnd(int lo, int hi) { return lo + (int)(rnd32() % (unsigned)(hi - lo + 1)); }
static uint32_t isqrt64(uint64_t d) { uint32_t r = 0; for (int b = 30; b >= 0; b--) { uint32_t c = r | (1u << b); if ((uint64_t)c * c <= d) r = c; } return r; }
int main(void) {
  unsigned char* v = (unsigned char*)(cfg(0x38) << 16);
  int32_t* mom = (int32_t*)v; unsigned char* par = v + 8192; int32_t* out = (int32_t*)(v + 16384);
  int32_t S1[CH], A2[CH], AB[CH], B2[CH], Mb[CH], Sv[CH]; int64_t Ka[CH]; uint64_t eps[CH];
  for (int c = 0; c < CH; c++) {
    int spread = rnd(50, 30000), centre = rnd(-2000, 2000);
    int64_t s1 = 0, a2 = 0, ab = 0, b2 = 0;
    for (int t = 0; t < N; t++) { int x = centre + rnd(-spread, spread); if (x > 32767) x = 32767; if (x < -32768) x = -32768;
      int a = x >> 8, b = x & 255; s1 += x; a2 += a * a; ab += a * b; b2 += b * b; }
    S1[c] = (int32_t)s1; A2[c] = (int32_t)a2; AB[c] = (int32_t)ab; B2[c] = (int32_t)b2;
    /* Contract: |K| = |Ka| N / root < 2^31 (the design keeps |K| below about 1.7e8). Pick Ka from a target K. */
    { int64_t sq0 = 65536 * a2 + 512 * ab + b2; uint64_t d0 = (uint64_t)((int64_t)N * sq0 - s1 * s1) + 0;
      uint32_t r0 = isqrt64(d0 + 1); int64_t target = rnd(1000, 200000000);
      int64_t ka = (int64_t)((double)target * (r0 ? r0 : 1) / N); if (ka == 0) ka = 1; if (rnd32() & 1) ka = -ka; Ka[c] = ka; }
    Mb[c] = rnd(-(1 << 25), 1 << 25); Sv[c] = rnd(100000, 400000); eps[c] = (uint64_t)rnd(1, 1 << 20);
    mom[(c / 32) * 128 + c % 32] = S1[c]; mom[(c / 32) * 128 + 32 + c % 32] = A2[c];
    mom[(c / 32) * 128 + 64 + c % 32] = AB[c]; mom[(c / 32) * 128 + 96 + c % 32] = B2[c];
    memcpy(par + 32 * c, &Ka[c], 8); memcpy(par + 32 * c + 8, &Mb[c], 4); memcpy(par + 32 * c + 12, &Sv[c], 4); memcpy(par + 32 * c + 16, &eps[c], 8);
  }
  ((fn_t)(uintptr_t)EMITTED_CODE)(mom, par, out, N);
  int bad = 0, shown = 0; double worst = 0;
  for (int c = 0; c < CH; c++) {
    int64_t sq = 65536LL * A2[c] + 512LL * AB[c] + B2[c];
    uint64_t D = (uint64_t)((int64_t)N * sq - (int64_t)S1[c] * S1[c]) + eps[c];
    uint32_t root = isqrt64(D);
    uint64_t aka = (uint64_t)(Ka[c] < 0 ? -Ka[c] : Ka[c]);
    int32_t K = (int32_t)((aka * N + (root >> 1)) / root); if (Ka[c] < 0) K = -K;
    int64_t prod = (int64_t)K * S1[c]; uint64_t ap = (uint64_t)(prod < 0 ? -prod : prod), dv = (uint64_t)N << 15;
    int32_t q = (int32_t)((ap + (dv >> 1)) / dv); if (prod < 0) q = -q;
    int32_t M = Mb[c] - q;
    if (out[c] != K || out[CH + c] != M || out[2 * CH + c] != Sv[c]) {
      bad++; if (shown++ < 6) printf("c=%d K %ld/%ld M %ld/%ld S %ld/%ld S1=%ld A2=%ld AB=%ld B2=%ld Ka=%lld sq=%lld D=%llu root=%lu\n",
        c, (long)out[c], (long)K, (long)out[CH + c], (long)M, (long)out[2 * CH + c], (long)Sv[c], (long)S1[c], (long)A2[c], (long)AB[c],
        (long)B2[c], (long long)Ka[c], (long long)sq, (unsigned long long)D, (unsigned long)root); }
    double ideal = (double)Ka[c] * N / sqrt((double)D);
    double rel = fabs((out[c] - ideal) / ideal); if (rel > worst) worst = rel;
  }
  printf("adain-turns-coefficients C=%d N=%d mismatches=%d/%d worst K relative error vs real=%.3g %s\n", CH, N, bad, CH, worst, bad ? "FAIL" : "PASS");
  return bad != 0;
}
