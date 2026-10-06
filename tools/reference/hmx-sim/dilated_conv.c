/* hexagon-sim probe: Kokoro-style dilated Conv1d (C_in = C_out = 128, same padding) on HMX int8.
 * Signed int8 x and w; activations stored as u8 = x + 128 (zero point 128, halo croutons = 128).
 * Each tap is one activation.ub :single read (exact 1-row offsets) per 32-channel input block,
 * paired with weight.b :deep (64 output channels). The column table high word adds
 * -128*sum(w) + 128*4096 exactly, scale 0.125 gives out = sat_u8(floor(acc/4096) + 128).
 * Checked against a scalar reference for every (K, D) Kokoro uses. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#define IDX(i, j) (64 * ((i) / 2) + 2 * (j) + ((i) % 2))
#define C 128
#define CB (C / 32)
#define NT 3                 /* time tiles of 32 rows */
#define T (NT * 32)
#define PAD 1                /* halo croutons each side (|shift| <= 25 < 32) */
#define NTP (NT + 2 * PAD)
static int8_t X[T][C], Wt[11][C][C];   /* Wt[tap][out][in] */
static int32_t Ref[T][C];
static uint32_t lcg = 12345;
static int rnd(int lo, int hi) { lcg = lcg * 1103515245u + 12345u; return lo + (int)((lcg >> 8) % (unsigned)(hi - lo + 1)); }
static int floordiv(int a, int b) { int q = a / b; return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q; }
int main(void){
  unsigned char* v=(unsigned char*)(cfg(0x38)<<16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r|=1u<<26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *act = v;                       /* CB x NTP croutons */
  unsigned char *wv = v + 262144;               /* K x CB x (C/64) x 2 KB */
  unsigned char *out = v + 524288;              /* (C/32) x NT croutons */
  uint32_t *tbl = (uint32_t*)(v + 786432);      /* C/32 tables of 256 B */
  static const int Ks[3] = {3, 7, 11}, Ds[3] = {1, 3, 5};
  for (int t = 0; t < T; t++) for (int c = 0; c < C; c++) X[t][c] = (int8_t)rnd(-8, 8);
  /* activation croutons: block (cb, tp) holds time 32*(tp-PAD) + row, channels 32*cb.. */
  memset(act, 128, (size_t)CB * NTP * 2048);
  for (int cb = 0; cb < CB; cb++) for (int tp = PAD; tp < NT + PAD; tp++) for (int s = 0; s < 32; s++) for (int k = 0; k < 32; k++)
    act[((size_t)cb * NTP + tp) * 2048 + 2 * IDX(s, k) + 1] = (unsigned char)(X[32 * (tp - PAD) + s][32 * cb + k] + 128);
  int fails = 0;
  for (int ki = 0; ki < 3; ki++) for (int di = 0; di < 3; di++) {
    int K = Ks[ki], D = Ds[di], half = (K - 1) / 2;
    for (int k = 0; k < K; k++) for (int o = 0; o < C; o++) for (int i = 0; i < C; i++) Wt[k][o][i] = (int8_t)rnd(-8, 8);
    /* weights: per tap, input block cb, output group g: 2 KB = outputs 64g+0..31 then 64g+32..63 */
    for (int k = 0; k < K; k++) for (int cb = 0; cb < CB; cb++) for (int g = 0; g < C / 64; g++) {
      unsigned char* blk = wv + (((size_t)k * CB + cb) * (C / 64) + g) * 2048;
      for (int h = 0; h < 2; h++) for (int ii = 0; ii < 32; ii++) for (int cc = 0; cc < 32; cc++)
        blk[1024 * h + 128 * (ii / 4) + 4 * cc + ii % 4] = (unsigned char)Wt[k][64 * g + 32 * h + cc][32 * cb + ii];
    }
    /* column tables: low = fp16 0.125, high = -128*sum(w) + 128*4096 */
    for (int ob = 0; ob < C / 32; ob++) for (int cc = 0; cc < 32; cc++) {
      int o = 32 * ob + cc, sw = 0;
      for (int k = 0; k < K; k++) for (int i = 0; i < C; i++) sw += Wt[k][o][i];
      tbl[64 * ob + cc] = 0x3000; tbl[64 * ob + 32 + cc] = (uint32_t)(-128 * sw + 128 * 4096);
    }
    /* reference */
    for (int t = 0; t < T; t++) for (int o = 0; o < C; o++) {
      int acc = 0;
      for (int k = 0; k < K; k++) { int ts = t + D * (k - half); if (ts < 0 || ts >= T) continue;
        for (int i = 0; i < C; i++) acc += X[ts][i] * Wt[k][o][i]; }
      int q = floordiv(acc, 4096) + 128; Ref[t][o] = q < 0 ? 0 : q > 255 ? 255 : q;
    }
    unsigned long long c0, c1; __asm__ volatile("%0 = upcycle" : "=r"(c0));
    for (int tb = 0; tb < NT; tb++) for (int g = 0; g < C / 64; g++) {
      __asm__ volatile("mxclracc" ::: "memory");
      for (int k = 0; k < K; k++) {
        int shift = D * (k - half);                     /* input row = output row + shift */
        int row = 32 * (tb + PAD) + shift;              /* absolute padded row of output row 0 */
        int tp = row / 32, off = row % 32;
        for (int cb = 0; cb < CB; cb++) {
          unsigned rs = (unsigned)(uintptr_t)(act + ((size_t)cb * NTP + tp) * 2048) | ((unsigned)(off >> 1) << 7) | ((unsigned)(off & 1) << 1);
          unsigned rt = 2048u | 0x7ffu;
          const unsigned char* w = wv + (((size_t)k * CB + cb) * (C / 64) + g) * 2048;
          __asm__ volatile("{ activation.ub = mxmem(%0,%1):single\n weight.b = mxmem(%2,%3):deep }"::"r"(rs),"r"(rt),"r"(w),"r"(0x7ff):"memory");
        }
      }
      for (int h = 0; h < 2; h++) {
        int ob = 2 * g + h;
        __asm__ volatile("bias = mxmem2(%0)"::"r"(tbl + 64 * ob):"memory");
        __asm__ volatile("mxmem(%0,%1):after:sat.ub = acc"::"r"(out + ((size_t)ob * NT + tb) * 2048),"r"(0):"memory");
      }
    }
    __asm__ volatile("%0 = upcycle" : "=r"(c1));
    int bad = 0, first = -1;
    for (int t = 0; t < T; t++) for (int o = 0; o < C; o++) {
      int got = out[((size_t)(o / 32) * NT + t / 32) * 2048 + 2 * IDX(t % 32, o % 32) + 1];
      if (got != Ref[t][o]) { if (first < 0) first = t * C + o; bad++; }
    }
    long long macs = (long long)T * C * C * K;
    printf("K=%2d D=%d mismatches=%d/%d first=%d cycles=%llu MAC/cycle=%.0f\n", K, D, bad, T * C, first, c1 - c0, (double)macs / (double)(c1 - c0));
    if (bad) { fails++; int t = first / C, o = first % C;
      printf("  t=%d o=%d got=%d ref=%d\n", t, o, out[((size_t)(o / 32) * NT + t / 32) * 2048 + 2 * IDX(t % 32, o % 32) + 1], Ref[t][o]); }
  }
  printf("%s\n", fails ? "FAIL" : "PASS"); return 0;
}
