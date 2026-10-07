/* hexagon-sim harness for the PowerShell-emitted two-group HMX conv (src/emit/Kokoro.HmxConvPlanes.ps1).
 * Inputs: high window h (u8, zero point 128) and low window l (u8, zero point 0); weights Wh [, Wl].
 *   A1 = sum (h - 128) * Wh,  A2 = sum l * Wh [+ sum (h - 128) * Wl]
 * Each group is checked as two exact bytes of a 16-bit window: a = A + 2^(L+15),
 * high = sat(floor(a / 2^(L+8))), low = floor(a / 2^L) mod 256, with L = LA for A1 and LB for A2.
 * Build with -DCH -DKK -DDD -DWP=<1|2> -DLA -DLB -include <emitted_code.h>. Test tool only. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#define IDX(i, j) (64 * ((i) / 2) + 2 * (j) + ((i) % 2))
#define CB (CH / 32)
#define OB (CH / 32)
#define G (CH / 64)
#define NT 3
#define T (NT * 32)
#define PAD 1
#define STRIDE (NT * OB * 2048)
typedef void (*conv_fn)(void* hi, void* lo, const void* wh, const void* tbl, unsigned tiles, void* planes);
static int8_t Xh[T][CH], Wh[KK][CH][CH], Wl[KK][CH][CH];
static uint8_t Xl[T][CH];
static int RefHi[4][T][CH], RefLo[4][T][CH];
static uint32_t lcg = 4242;
static int rnd(int lo, int hi) { lcg = lcg * 1103515245u + 12345u; return lo + (int)((lcg >> 8) % (unsigned)(hi - lo + 1)); }
static long long floordiv(long long a, long long b) { long long q = a / b; return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q; }
static void pack_weights(unsigned char* dst, int8_t w[KK][CH][CH]) {
  for (int g = 0; g < G; g++) for (int k = 0; k < KK; k++) for (int cb = 0; cb < CB; cb++) {
    unsigned char* blk = dst + (((size_t)g * KK + k) * CB + cb) * 2048;
    for (int h = 0; h < 2; h++) for (int ii = 0; ii < 32; ii++) for (int cc = 0; cc < 32; cc++)
      blk[1024 * h + 128 * (ii / 4) + 4 * cc + ii % 4] = (unsigned char)w[k][64 * g + 32 * h + cc][32 * cb + ii];
  }
}
int main(void){
  unsigned char* v = (unsigned char*)(cfg(0x38) << 16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r |= 1u << 26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *hi = v, *lo = v + 65536, *wh = v + 131072, *wl = wh + (size_t)G * KK * CB * 2048;   /* Wl follows Wh */
  uint32_t* tbl = (uint32_t*)(v + 655360); unsigned char* planes = v + 1048576;
  int half = (KK - 1) / 2;
  for (int t = 0; t < T; t++) for (int c = 0; c < CH; c++) { Xh[t][c] = (int8_t)rnd(-8, 8); Xl[t][c] = (uint8_t)rnd(0, 255); }
  for (int k = 0; k < KK; k++) for (int o = 0; o < CH; o++) for (int i = 0; i < CH; i++) { Wh[k][o][i] = (int8_t)rnd(-8, 8); Wl[k][o][i] = (int8_t)rnd(-8, 8); }
  memset(hi, 128, (size_t)(NT + 2 * PAD) * CB * 2048); memset(lo, 0, (size_t)(NT + 2 * PAD) * CB * 2048);
  for (int t = 0; t < T; t++) for (int c = 0; c < CH; c++) {
    size_t at = ((size_t)(t / 32 + PAD) * CB + c / 32) * 2048 + 2 * IDX(t % 32, c % 32) + 1;
    hi[at] = (unsigned char)(Xh[t][c] + 128); lo[at] = Xl[t][c];
  }
  pack_weights(wh, Wh); pack_weights(wl, Wl);
  const int L[4] = { LA, LA, LB, LB };
  for (int ob = 0; ob < OB; ob++) for (int cc = 0; cc < 32; cc++) {
    int o = 32 * ob + cc; long long sh = 0, sl = 0;
    for (int k = 0; k < KK; k++) for (int i = 0; i < CH; i++) { sh += Wh[k][o][i]; sl += Wl[k][o][i]; }
    long long bias1 = -128 * sh + (1LL << (LA + 15)), bias2 = (WP == 2 ? -128 * sl : 0) + (1LL << (LB + 15));
    for (int p = 0; p < 4; p++) {
      uint32_t* t32 = tbl + 256 * ob + 64 * p;
      t32[cc] = (uint32_t)(((p & 1 ? 9 : 1) - L[p] + 15) << 10);    /* 2^(1-L) high, 2^(9-L) low */
      t32[32 + cc] = (uint32_t)(p < 2 ? bias1 : bias2);
    }
  }
  for (int t = 0; t < T; t++) for (int o = 0; o < CH; o++) {
    long long a1 = 0, a2 = 0;
    for (int k = 0; k < KK; k++) { int ts = t + DD * (k - half); if (ts < 0 || ts >= T) continue;
      for (int i = 0; i < CH; i++) { a1 += (long long)Xh[ts][i] * Wh[k][o][i]; a2 += (long long)Xl[ts][i] * Wh[k][o][i];
        if (WP == 2) a2 += (long long)Xh[ts][i] * Wl[k][o][i]; } }
    long long acc[2] = { a1, a2 };
    for (int grp = 0; grp < 2; grp++) {
      int Lg = grp ? LB : LA; long long a = acc[grp] + (1LL << (Lg + 15));
      long long h = floordiv(a, 1LL << (Lg + 8)); RefHi[grp][t][o] = h < 0 ? 0 : h > 255 ? 255 : (int)h;
      RefLo[grp][t][o] = (int)(floordiv(a, 1LL << Lg) & 255);
    }
  }
  memset(planes, 0, (size_t)4 * STRIDE);
  conv_fn f = (conv_fn)(uintptr_t)EMITTED_CODE;
  f(hi + (size_t)PAD * CB * 2048, lo + (size_t)PAD * CB * 2048, wh, tbl, NT, planes);
  int bad[4] = {0, 0, 0, 0}, sat = 0;
  for (int t = 0; t < T; t++) for (int o = 0; o < CH; o++) for (int grp = 0; grp < 2; grp++) {
    size_t at = ((size_t)(t / 32) * OB + o / 32) * 2048 + 2 * IDX(t % 32, o % 32) + 1;
    unsigned char ph = planes[(size_t)(2 * grp) * STRIDE + at], pl = planes[(size_t)(2 * grp + 1) * STRIDE + at];
    if (ph != RefHi[grp][t][o]) bad[2 * grp]++;
    if (RefHi[grp][t][o] == 0 || RefHi[grp][t][o] == 255) sat++; else if (pl != RefLo[grp][t][o]) bad[2 * grp + 1]++;
  }
  printf("emitted two-group C=%d K=%d D=%d WP=%d LA=%d LB=%d mismatches A1h=%d A1l=%d A2h=%d A2l=%d /%d saturated=%d %s\n",
         CH, KK, DD, WP, LA, LB, bad[0], bad[1], bad[2], bad[3], T * CH, sat, (bad[0] || bad[1] || bad[2] || bad[3]) ? "FAIL" : "PASS");
  return (bad[0] || bad[1] || bad[2] || bad[3]) != 0;
}
