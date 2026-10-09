/* hexagon-sim harness for the PowerShell-emitted looped plane combine (src/emit/Kokoro.PlaneCombine.ps1,
 * New-KokoroPlaneCombineLoopSteps) at decoder channel counts; ratios are 128 bytes per block, Q15 in both halfwords.
 * Random byte planes A1 high/low, A2 high/low (odd bytes), per-channel Q15 ratio and residual R.
 * Model: w = high << 8 | low, v = sat16(sum of (w_g - 32768)) over GROUPS (2, or 3 with planes 4 and 5);
 *   Conv: out = v;  Residual: out = sat16(R + q15(v, ratio_c));  Scale: out = q15(v, ratio_c).  Stored biased.
 * Build with -DCH=<channels> -DMODE=<0 Conv|1 Residual|2 Scale> -include <emitted_code.h>. Test tool only. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#define OB (CH / 32)
#define NT 3
#define STRIDE (NT * OB * 2048)
#define GROUPS 2
#define IDX(i, j) (64 * ((i) / 2) + 2 * (j) + ((i) % 2))
typedef void (*fn_t)(const void* planes, void* out, const void* ratio, unsigned tiles);
static uint32_t lcg = 99;
static int rnd(int lo, int hi) { lcg = lcg * 1103515245u + 12345u; return lo + (int)((lcg >> 8) % (unsigned)(hi - lo + 1)); }
static int16_t sat16(int32_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }
static int16_t q15(int16_t a, int16_t b) { return sat16((int32_t)(((int64_t)a * b * 2 + 32768) >> 16)); }
static int16_t R[NT * 32][CH];
int main(void) {
  unsigned char* v = (unsigned char*)(cfg(0x38) << 16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r |= 1u << 26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *planes = v, *out = v + 6 * (size_t)STRIDE; int16_t* ratio = (int16_t*)(out + (size_t)STRIDE);
  for (size_t i = 0; i < 6 * (size_t)STRIDE; i++) planes[i] = (unsigned char)rnd(0, 255);
  for (int c = 0; c < CH; c++) ratio[2 * c] = ratio[2 * c + 1] = (int16_t)rnd(8000, 32767);
  for (int t = 0; t < NT * 32; t++) for (int c = 0; c < CH; c++) {
    R[t][c] = (int16_t)rnd(-30000, 30000);
    size_t at = ((size_t)(t / 32) * OB + c / 32) * 2048 + 2 * IDX(t % 32, c % 32);
    uint16_t b = (uint16_t)(R[t][c] + 32768); out[at] = (unsigned char)b; out[at + 1] = (unsigned char)(b >> 8);
  }
  ((fn_t)(uintptr_t)EMITTED_CODE)(planes, out, ratio, NT);
  int bad = 0, shown = 0;
  for (int t = 0; t < NT * 32; t++) for (int c = 0; c < CH; c++) {
    size_t at = ((size_t)(t / 32) * OB + c / 32) * 2048 + 2 * IDX(t % 32, c % 32);
    int w1 = planes[at + 1] << 8 | planes[STRIDE + at + 1], w2 = planes[2 * STRIDE + at + 1] << 8 | planes[3 * STRIDE + at + 1];
    int w3 = planes[4 * STRIDE + at + 1] << 8 | planes[5 * STRIDE + at + 1];
    int16_t val = sat16((w1 - 32768) + (w2 - 32768));
    if (GROUPS == 3) val = sat16(val + (w3 - 32768));
    int16_t o = MODE == 1 ? sat16(R[t][c] + q15(val, ratio[2 * c])) : MODE == 2 ? q15(val, ratio[2 * c]) : val;
    int got = (int)(out[at] | out[at + 1] << 8) - 32768;
    if (got != o) { bad++; if (shown++ < 6) printf("t=%d c=%d w1=%d w2=%d R=%d expected %d got %d\n", t, c, w1, w2, R[t][c], o, got); }
  }
  printf("plane-combine-loop %s groups=%d C=%d tiles=%d mismatches=%d/%d %s\n", MODE == 1 ? "residual" : MODE == 2 ? "scale" : "conv", GROUPS, CH, NT, bad, NT * 32 * CH, bad ? "FAIL" : "PASS");
  return bad != 0;
}
