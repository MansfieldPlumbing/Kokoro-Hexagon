/* hexagon-sim harness for the PowerShell-emitted fused AdaIN + LeakyReLU(0.2) body (src/emit/Kokoro.AdaInLeaky16.ps1).
 * Random biased-u16 input and per-channel K, M. Model: y = q31(x * 2^16, K) + M (wrapping add), out = max(y, q31(y, 0.2)),
 * clamped to int16. OUT 0 (Windows): high = (out >> 8) + 128, low = out & 255, each the odd byte of its halfword.
 * OUT 1 (Tensor): out + 32768 as u16. Build with -DCH=<channels> -DOUT=<0|1> -include <emitted_code.h>. Test tool only. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#define NT 3
#define T (NT * 32)
#define IDX(i, j) (64 * ((i) / 2) + 2 * (j) + ((i) % 2))
#define BYTES ((size_t)NT * CH * 64)
#define ALIGN(x) ((((size_t)(x)) + 65535) & ~(size_t)65535)
typedef void (*fn_t)(const void* in, void* hi, void* lo, const void* k, unsigned tiles);
static uint32_t lcg = 2026;
static int32_t rnd(int32_t lo, int32_t hi) { lcg = lcg * 1103515245u + 12345u; uint32_t r = (lcg >> 1) ^ (lcg << 15); return lo + (int32_t)(r % (uint32_t)(hi - lo + 1)); }
static int32_t sat32(int64_t v) { return v > INT32_MAX ? INT32_MAX : v < INT32_MIN ? INT32_MIN : (int32_t)v; }
static int32_t q31(int32_t a, int32_t b) { return sat32(((int64_t)a * b + ((int64_t)1 << 30)) >> 31); }
static int16_t X[T][CH]; static int32_t K[CH], M[CH];
int main(void) {
  unsigned char* v = (unsigned char*)(cfg(0x38) << 16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r |= 1u << 26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *in = v, *hi = v + ALIGN(BYTES), *lo = hi + ALIGN(BYTES); int32_t* kc = (int32_t*)(lo + ALIGN(BYTES));
  for (int c = 0; c < CH; c++) { K[c] = rnd(-60000, 60000); M[c] = rnd(-20000, 20000);
    kc[(c / 32) * 64 + c % 32] = K[c]; kc[(c / 32) * 64 + 32 + c % 32] = M[c]; }
  for (int t = 0; t < T; t++) for (int c = 0; c < CH; c++) {
    X[t][c] = (int16_t)rnd(-32768, 32767);
    size_t at = ((size_t)(t / 32) * (CH / 32) + c / 32) * 2048 + 2 * IDX(t % 32, c % 32);
    uint16_t b = (uint16_t)(X[t][c] + 32768); in[at] = (unsigned char)b; in[at + 1] = (unsigned char)(b >> 8);
  }
  memset(hi, 0, BYTES); memset(lo, 0, BYTES);
  ((fn_t)(uintptr_t)EMITTED_CODE)(in, hi, lo, kc, NT);
  int bad = 0, shown = 0, clamped = 0, negative = 0;
  for (int t = 0; t < T; t++) for (int c = 0; c < CH; c++) {
    int32_t y = (int32_t)((uint32_t)q31((int32_t)X[t][c] * 65536, K[c]) + (uint32_t)M[c]);
    int32_t l = q31(y, 429496730); if (l > y) { y = l; negative++; }
    if (y > 32767 || y < -32768) clamped++;
    int32_t o = y > 32767 ? 32767 : y < -32768 ? -32768 : y;
    size_t at = ((size_t)(t / 32) * (CH / 32) + c / 32) * 2048 + 2 * IDX(t % 32, c % 32);
    int ok;
    if (OUT == 0) ok = hi[at + 1] == (unsigned char)((o >> 8) + 128) && lo[at + 1] == (unsigned char)(o & 255) && hi[at] == 0 && lo[at] == 0;
    else ok = (int)(hi[at] | hi[at + 1] << 8) - 32768 == o;
    if (!ok) { bad++; if (shown++ < 6) printf("t=%d c=%d x=%d K=%ld M=%ld expected %ld hi %u/%u lo %u/%u\n", t, c, X[t][c], (long)K[c], (long)M[c], (long)o, hi[at], hi[at + 1], lo[at], lo[at + 1]); }
  }
  printf("adain-leaky16 %s C=%d tiles=%d mismatches=%d/%d negative=%d clamped=%d %s\n", OUT ? "tensor" : "windows", CH, NT, bad, T * CH, negative, clamped, bad ? "FAIL" : "PASS");
  return bad != 0;
}
