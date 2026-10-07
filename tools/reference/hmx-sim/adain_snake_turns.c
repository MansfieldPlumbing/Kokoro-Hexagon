/* hexagon-sim harness for the PowerShell-emitted fused AdaIN+Snake in phase turns
 * (src/emit/Kokoro.AdaInSnakeTurns.ps1). Build with -include <emitted_code.h> defining EMITTED_CODE[].
 * Test tool only: the emitted function runs from its bytes; this C stages data, models the intended
 * integer contract lane by lane, and compares every output byte. It also reports the SNR of the
 * 16-bit output against the double-precision Snake of the same K, M, S. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#define CH 128
#define PI 3.14159265358979323846
#define NT 2
#define IDX(i, j) (64 * ((i) / 2) + 2 * (j) + ((i) % 2))
typedef void (*fn_t)(const void* in, void* hi, void* lo, const void* consts, unsigned tiles);
static uint32_t lcg = 12345;
static int32_t rnd(int32_t lo, int32_t hi) { lcg = lcg * 1103515245u + 12345u; uint32_t r = (lcg >> 1) ^ (lcg << 15); return lo + (int32_t)(r % (uint32_t)(hi - lo + 1)); }
static int32_t sat32(int64_t v) { return v > INT32_MAX ? INT32_MAX : v < INT32_MIN ? INT32_MIN : (int32_t)v; }
static int16_t sat16(int32_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }
static int32_t q31(int32_t a, int32_t b) { return sat32(((int64_t)a * b + ((int64_t)1 << 30)) >> 31); }
static int16_t q15(int16_t a, int16_t b) { return sat16((int32_t)(((int64_t)a * b * 2 + 32768) >> 16)); }
static int32_t K[CH], M[CH], S[CH];
static int16_t X[NT * 32][CH];
static int16_t coef[5];
static int32_t model(int c, int16_t x) {
  int32_t p = q31((int32_t)x << 16, K[c]) + M[c];
  int16_t g = (int16_t)(((uint32_t)p >> 8) & 0xffff);
  int16_t ga = g == -32768 ? 32767 : (int16_t)(g < 0 ? -g : g);
  int16_t u = (int16_t)((ga - 16384) * 2);
  int16_t z = q15(u, u);
  int16_t a = (int16_t)(q15(coef[4], z) + coef[3]);
  a = (int16_t)(q15(a, z) + coef[2]); a = (int16_t)(q15(a, z) + coef[1]); a = (int16_t)(q15(a, z) + coef[0]);
  int16_t q = sat16(q15(a, u) + 16384);
  int32_t v = p + (((int32_t)q * 10430) >> 6);
  int32_t o = q31(v, S[c]);
  return o > 32767 ? 32767 : o < -32768 ? -32768 : o;
}
int main(void) {
  unsigned char* v = (unsigned char*)(cfg(0x38) << 16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r |= 1u << 26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *in = v, *hi = v + 65536, *lo = v + 131072; int32_t* consts = (int32_t*)(v + 196608);
  for (int k = 1; k <= 5; k++) { double f = 1; for (int i = 1; i <= 2 * k - 1; i++) f *= i;
    coef[k - 1] = (int16_t)lround(pow(-1, k - 1) * pow(PI / 2, 2 * k - 1) / f * 16384); }
  for (int c = 0; c < CH; c++) { K[c] = rnd(-220000000, 220000000); M[c] = rnd(-33554432, 33554432); S[c] = rnd(150000, 380000); }
  memcpy(consts, K, sizeof K); memcpy(consts + CH, M, sizeof M); memcpy(consts + 2 * CH, S, sizeof S);
  for (int t = 0; t < NT * 32; t++) for (int c = 0; c < CH; c++) X[t][c] = (int16_t)rnd(-20000, 20000);
  for (int t = 0; t < NT * 32; t++) for (int c = 0; c < CH; c++) {
    size_t at = ((size_t)(t / 32) * (CH / 32) + c / 32) * 2048 + 2 * IDX(t % 32, c % 32);
    uint16_t b = (uint16_t)(X[t][c] + 32768); in[at] = (unsigned char)b; in[at + 1] = (unsigned char)(b >> 8);
  }
  memset(hi, 0, NT * 8192); memset(lo, 0, NT * 8192);
  ((fn_t)(uintptr_t)EMITTED_CODE)(in, hi, lo, consts, NT);
  int badHi = 0, badLo = 0, shown = 0; double sig = 0, err = 0;
  for (int t = 0; t < NT * 32; t++) for (int c = 0; c < CH; c++) {
    size_t at = ((size_t)(t / 32) * (CH / 32) + c / 32) * 2048 + 2 * IDX(t % 32, c % 32) + 1;
    int32_t o = model(c, X[t][c]);
    int eh = (o >> 8) + 128, el = o & 255;
    if (hi[at] != eh) badHi++;
    if (lo[at] != el) badLo++;
    if ((hi[at] != eh || lo[at] != el) && shown < 8) { printf("t=%d c=%d x=%d model=%d hi %d/%d lo %d/%d\n", t, c, (int)X[t][c], (int)o, hi[at], eh, lo[at], el); shown++; }
    /* Double-precision reference of the same constants: P turns, s = P + (1 - cos 2 pi P) / (2 pi). */
    double p = ((double)X[t][c] * 65536.0 * K[c] / 2147483648.0 + M[c]) / 16777216.0;
    double ideal = (p + (1 - cos(2 * PI * p)) / (2 * PI)) * 16777216.0 * S[c] / 2147483648.0;
    int32_t emitted = ((int32_t)hi[at] - 128) * 256 + lo[at];
    if (ideal > -32768 && ideal < 32767) { sig += ideal * ideal; err += (emitted - ideal) * (emitted - ideal); }
  }
  printf("adain-snake-turns C=%d tiles=%d high mismatches=%d low mismatches=%d/%d snr-vs-double=%.2f dB %s\n",
         CH, NT, badHi, badLo, NT * 32 * CH, 10 * log10(sig / err), (badHi || badLo) ? "FAIL" : "PASS");
  return (badHi || badLo) != 0;
}
