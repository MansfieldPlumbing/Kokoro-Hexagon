/* hexagon-sim harness for the PowerShell-emitted HMX conv (src/emit/Kokoro.HmxConv.ps1).
 * Build with -DCH=<128|256> -DKK=<3|7|11> -DDD=<1|3|5> -include <emitted_code.h>, where the header
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
typedef void (*conv_fn)(void* act, const void* w, void* out, const void* tbl, unsigned tiles);
static int8_t X[T][CH], Wt[KK][CH][CH];
static int Ref[T][CH];
static uint32_t lcg = 777;
static int rnd(int lo, int hi) { lcg = lcg * 1103515245u + 12345u; return lo + (int)((lcg >> 8) % (unsigned)(hi - lo + 1)); }
static int floordiv(int a, int b) { int q = a / b; return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q; }
int main(void){
  unsigned char* v=(unsigned char*)(cfg(0x38)<<16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r|=1u<<26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *act = v, *wv = v + 262144, *out = v + 1048576 + 262144; uint32_t* tbl = (uint32_t*)(v + 1048576 + 524288);
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
    tbl[64 * ob + cc] = 0x3000; tbl[64 * ob + 32 + cc] = (uint32_t)(-128 * sw + 128 * 4096);
  }
  for (int t = 0; t < T; t++) for (int o = 0; o < CH; o++) {
    int acc = 0;
    for (int k = 0; k < KK; k++) { int ts = t + DD * (k - half); if (ts < 0 || ts >= T) continue;
      for (int i = 0; i < CH; i++) acc += X[ts][i] * Wt[k][o][i]; }
    int q = floordiv(acc, 4096) + 128; Ref[t][o] = q < 0 ? 0 : q > 255 ? 255 : q;
  }
  memset(out, 0, (size_t)NT * OB * 2048);
  conv_fn f = (conv_fn)(uintptr_t)EMITTED_CODE;
  f(act + (size_t)PAD * CB * 2048, wv, out, tbl, NT);
  int bad = 0;
  for (int t = 0; t < T; t++) for (int o = 0; o < CH; o++)
    if (out[((size_t)(t / 32) * OB + o / 32) * 2048 + 2 * IDX(t % 32, o % 32) + 1] != Ref[t][o]) bad++;
  printf("emitted C=%d K=%d D=%d mismatches=%d/%d %s\n", CH, KK, DD, bad, T * CH, bad ? "FAIL" : "PASS");
  return bad != 0;
}
