/* hexagon-sim harness for the PowerShell-emitted looped two-group HMX conv (src/emit/Kokoro.HmxConvPlanes.ps1,
 * New-KokoroHmxConvPlanesLoopSteps) at decoder shapes: CI input channels (whole 32-blocks), CO output channels
 * (whole 64-groups), kernel KK (1 or 3). Same contract and checks as emitted_conv_twogroup.c:
 *   A1 = sum (h - 128) * Wh,  A2 = sum l * Wh [+ sum (h - 128) * Wl],  A3 = sum l * Wl (WP == 2)
 * each group checked as two exact bytes of a 16-bit window at shift LA (A1) or LB (A2, A3).
 * Build with -DCI -DCO -DKK -DDD -DWP -DLA -DLB -include <emitted_code.h>. Test tool only. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#define IDX(i, j) (64 * ((i) / 2) + 2 * (j) + ((i) % 2))
#define CB (CI / 32)
#define OB (CO / 32)
#define G (CO / 64)
#define NT 3
#define T (NT * 32)
#define PAD 1
#define STRIDE (NT * OB * 2048)
#define GROUPS (WP == 2 ? 3 : 2)
#define ALIGN(x) ((((size_t)(x)) + 65535) & ~(size_t)65535)
#define WIN_BYTES ((size_t)(NT + 2 * PAD) * CB * 2048)
#define W_BYTES ((size_t)G * KK * CB * 2048)
typedef void (*conv_fn)(void* hi, void* lo, const void* wh, const void* tbl, unsigned tiles, void* planes);
static int8_t Xh[T][CI], Wh[KK][CO][CI], Wl[WP == 2 ? KK : 1][WP == 2 ? CO : 1][WP == 2 ? CI : 1];
static uint8_t Xl[T][CI];
static uint32_t lcg = 4243;
static int rnd(int lo, int hi) { lcg = lcg * 1103515245u + 12345u; return lo + (int)((lcg >> 8) % (unsigned)(hi - lo + 1)); }
static long long floordiv(long long a, long long b) { long long q = a / b; return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q; }
static void pack_weights(unsigned char* dst, int wl) {
  for (int g = 0; g < G; g++) for (int k = 0; k < KK; k++) for (int cb = 0; cb < CB; cb++) {
    unsigned char* blk = dst + (((size_t)g * KK + k) * CB + cb) * 2048;
    for (int h = 0; h < 2; h++) for (int ii = 0; ii < 32; ii++) for (int cc = 0; cc < 32; cc++) {
      int o = 64 * g + 32 * h + cc, i = 32 * cb + ii;
      blk[1024 * h + 128 * (ii / 4) + 4 * cc + ii % 4] = (unsigned char)(wl ? Wl[k][o][i] : Wh[k][o][i]);
    }
  }
}
int main(void){
  unsigned char* v = (unsigned char*)(cfg(0x38) << 16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r |= 1u << 26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *hi = v, *lo = v + ALIGN(WIN_BYTES), *wh = lo + ALIGN(WIN_BYTES), *wl = wh + W_BYTES;   /* Wl follows Wh */
  uint32_t* tbl = (uint32_t*)(wh + ALIGN((WP == 2 ? 2 : 1) * W_BYTES));
  unsigned char* planes = (unsigned char*)tbl + ALIGN((size_t)512 * GROUPS * OB);
  if ((size_t)(planes + 6 * (size_t)STRIDE - v) > 8u * 1024 * 1024) { printf("emitted conv loop layout exceeds VTCM FAIL\n"); return 1; }
  int half = (KK - 1) / 2;
  for (int t = 0; t < T; t++) for (int c = 0; c < CI; c++) { Xh[t][c] = (int8_t)rnd(-8, 8); Xl[t][c] = (uint8_t)rnd(0, 255); }
  for (int k = 0; k < KK; k++) for (int o = 0; o < CO; o++) for (int i = 0; i < CI; i++) {
    Wh[k][o][i] = (int8_t)rnd(-8, 8); if (WP == 2) Wl[k][o][i] = (int8_t)rnd(-8, 8); }
  memset(hi, 128, WIN_BYTES); memset(lo, 0, WIN_BYTES);
  for (int t = 0; t < T; t++) for (int c = 0; c < CI; c++) {
    size_t at = ((size_t)(t / 32 + PAD) * CB + c / 32) * 2048 + 2 * IDX(t % 32, c % 32) + 1;
    hi[at] = (unsigned char)(Xh[t][c] + 128); lo[at] = Xl[t][c];
  }
  pack_weights(wh, 0); if (WP == 2) pack_weights(wl, 1);
  const int L[6] = { LA, LA, LB, LB, LB, LB };
  for (int ob = 0; ob < OB; ob++) for (int cc = 0; cc < 32; cc++) {
    int o = 32 * ob + cc; long long sh = 0, sl = 0;
    for (int k = 0; k < KK; k++) for (int i = 0; i < CI; i++) { sh += Wh[k][o][i]; if (WP == 2) sl += Wl[k][o][i]; }
    long long bias1 = -128 * sh + (1LL << (LA + 15)), bias2 = (WP == 2 ? -128 * sl : 0) + (1LL << (LB + 15)), bias3 = 1LL << (LB + 15);
    for (int p = 0; p < 2 * GROUPS; p++) {
      uint32_t* t32 = tbl + 128 * GROUPS * ob + 64 * p;
      t32[cc] = (uint32_t)(((p & 1 ? 9 : 1) - L[p] + 15) << 10);
      t32[32 + cc] = (uint32_t)(p < 2 ? bias1 : p < 4 ? bias2 : bias3);
    }
  }
  memset(planes, 0, (size_t)6 * STRIDE);
  conv_fn f = (conv_fn)(uintptr_t)EMITTED_CODE;
  f(hi + (size_t)PAD * CB * 2048, lo + (size_t)PAD * CB * 2048, wh, tbl, NT, planes);
  int bad[6] = {0, 0, 0, 0, 0, 0}, sat = 0;
  for (int t = 0; t < T; t++) for (int o = 0; o < CO; o++) {
    long long a1 = 0, a2 = 0, a3 = 0;
    for (int k = 0; k < KK; k++) { int ts = t + DD * (k - half); if (ts < 0 || ts >= T) continue;
      for (int i = 0; i < CI; i++) { a1 += (long long)Xh[ts][i] * Wh[k][o][i]; a2 += (long long)Xl[ts][i] * Wh[k][o][i];
        if (WP == 2) { a2 += (long long)Xh[ts][i] * Wl[k][o][i]; a3 += (long long)Xl[ts][i] * Wl[k][o][i]; } } }
    long long acc[3] = { a1, a2, a3 };
    size_t at = ((size_t)(t / 32) * OB + o / 32) * 2048 + 2 * IDX(t % 32, o % 32) + 1;
    for (int grp = 0; grp < GROUPS; grp++) {
      int Lg = grp ? LB : LA; long long a = acc[grp] + (1LL << (Lg + 15));
      long long h = floordiv(a, 1LL << (Lg + 8)); int rh = h < 0 ? 0 : h > 255 ? 255 : (int)h;
      int rl = (int)(floordiv(a, 1LL << Lg) & 255);
      unsigned char ph = planes[(size_t)(2 * grp) * STRIDE + at], pl = planes[(size_t)(2 * grp + 1) * STRIDE + at];
      if (ph != rh) bad[2 * grp]++;
      if (rh == 0 || rh == 255) sat++; else if (pl != rl) bad[2 * grp + 1]++;
    }
  }
  int any = bad[0] || bad[1] || bad[2] || bad[3] || bad[4] || bad[5];
  printf("emitted conv loop CI=%d CO=%d K=%d D=%d WP=%d LA=%d LB=%d mismatches A1h=%d A1l=%d A2h=%d A2l=%d A3h=%d A3l=%d /%d saturated=%d %s\n",
         CI, CO, KK, DD, WP, LA, LB, bad[0], bad[1], bad[2], bad[3], bad[4], bad[5], T * CO, sat, any ? "FAIL" : "PASS");
  return any != 0;
}
