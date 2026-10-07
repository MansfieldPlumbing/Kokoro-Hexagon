/* hexagon-sim harness for the PowerShell-emitted HMX conv with two output byte planes
 * (src/emit/Kokoro.HmxConv.ps1 -OutputPlanes). With biased accumulator a = acc + 2^(L+15):
 * high plane = sat(floor(a / 2^(L+8))), low plane = floor(a / 2^L) mod 256, from power-of-two
 * table scales 2^(1-L) and 2^(9-L). Build with -DCH -DKK -DDD -DLL=<L> -include <emitted_code.h>, where the header
 * defines EMITTED_CODE[] (the bytes of build/.../emitted-code.bin). Test tool only: the emitted
 * function runs from these bytes exactly as emitted; the C here only stages data and checks results. */
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
typedef void (*conv_fn)(void* act, const void* w, void* out, const void* tbl, unsigned tiles, void* low);
static int8_t X[T][CH], Wt[KK][CH][CH];
static int RefHi[T][CH], RefLo[T][CH];
static uint32_t lcg = 777;
static int rnd(int lo, int hi) { lcg = lcg * 1103515245u + 12345u; return lo + (int)((lcg >> 8) % (unsigned)(hi - lo + 1)); }
static int floordiv(int a, int b) { int q = a / b; return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q; }
int main(void){
  unsigned char* v=(unsigned char*)(cfg(0x38)<<16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r|=1u<<26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *act = v, *wv = v + 262144, *out = v + 1048576 + 262144; uint32_t* tbl = (uint32_t*)(v + 1048576 + 524288); unsigned char* low = v + 1048576 + 786432;
  int half = (KK - 1) / 2;
  for (int t = 0; t < T; t++) for (int c = 0; c < CH; c++) X[t][c] = (int8_t)rnd(-8, 8);
  for (int k = 0; k < KK; k++) for (int o = 0; o < CH; o++) for (int i = 0; i < CH; i++) Wt[k][o][i] = (int8_t)rnd(-8, 8);
  memset(act, 128, (size_t)(NT + 2 * PAD) * CB * 2048);
  for (int t = 0; t < T; t++) for (int c = 0; c < CH; c++)
    act[((size_t)(t / 32 + PAD) * CB + c / 32) * 2048 + 2 * IDX(t % 32, c % 32) + 1] = (unsigned char)(X[t][c] + 128);
  for (int g = 0; g < G; g++) for (int k = 0; k < KK; k++) for (int cb = 0; cb < CB; cb++) {
    unsigned char* blk = wv + (((size_t)g * KK + k) * CB + cb) * 2048;
    for (int h = 0; h < 2; h++) for (int ii = 0; ii < 32; ii++) for (int cc = 0; cc < 32; cc++)
      blk[1024 * h + 128 * (ii / 4) + 4 * cc + ii % 4] = (unsigned char)Wt[k][64 * g + 32 * h + cc][32 * cb + ii];
  }
  for (int ob = 0; ob < OB; ob++) for (int cc = 0; cc < 32; cc++) {
    int o = 32 * ob + cc, sw = 0;
    for (int k = 0; k < KK; k++) for (int i = 0; i < CH; i++) sw += Wt[k][o][i];
    uint32_t bias = (uint32_t)(-128 * sw + (1 << (LL + 15)));
    tbl[128 * ob + cc] = (uint32_t)((1 - LL + 15) << 10); tbl[128 * ob + 32 + cc] = bias;        /* 2^(1-L) */
    tbl[128 * ob + 64 + cc] = (uint32_t)((9 - LL + 15) << 10); tbl[128 * ob + 96 + cc] = bias;   /* 2^(9-L) */
  }
  for (int t = 0; t < T; t++) for (int o = 0; o < CH; o++) {
    int acc = 0;
    for (int k = 0; k < KK; k++) { int ts = t + DD * (k - half); if (ts < 0 || ts >= T) continue;
      for (int i = 0; i < CH; i++) acc += X[ts][i] * Wt[k][o][i]; }
    int a = acc + (1 << (LL + 15)), hi = floordiv(a, 1 << (LL + 8));
    RefHi[t][o] = hi < 0 ? 0 : hi > 255 ? 255 : hi; RefLo[t][o] = floordiv(a, 1 << LL) & 255;
  }
  memset(out, 0, (size_t)NT * OB * 2048); memset(low, 0, (size_t)NT * OB * 2048);
  conv_fn f = (conv_fn)(uintptr_t)EMITTED_CODE;
  f(act + (size_t)PAD * CB * 2048, wv, out, tbl, NT, low);
  int badHi = 0, badLo = 0, sat = 0;
  for (int t = 0; t < T; t++) for (int o = 0; o < CH; o++) {
    size_t at = ((size_t)(t / 32) * OB + o / 32) * 2048 + 2 * IDX(t % 32, o % 32) + 1;
    if (out[at] != RefHi[t][o]) badHi++;
    if (RefHi[t][o] == 0 || RefHi[t][o] == 255) sat++; else if (low[at] != RefLo[t][o]) badLo++;
  }
  printf("emitted planes C=%d K=%d D=%d L=%d high mismatches=%d low mismatches=%d/%d saturated=%d %s\n",
         CH, KK, DD, LL, badHi, badLo, T * CH, sat, (badHi || badLo) ? "FAIL" : "PASS");
  return (badHi || badLo) != 0;
}
