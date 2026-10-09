/* hexagon-sim harness for the PowerShell-emitted 16-bit AdaIN moments (src/emit/Kokoro.AdaInMoments16.ps1).
 * Random x over the full int16 range (both extremes included), record pre-filled with nonzero values.
 * Expected per channel: S1 += sum x, A2 += sum a^2, AB += sum a*b, B2 += sum b^2 with a = x >> 8, b = x & 255,
 * and 65536 A2 + 512 AB + B2 == sum x^2 is checked in 64-bit. Test tool only. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#ifndef CH
#define CH 128
#endif
#define REC_AT ((size_t)NT * CH * 64 > 262144 ? 1048576 : 262144)
#define NT 7
#define IDX(i, j) (64 * ((i) / 2) + 2 * (j) + ((i) % 2))
typedef void (*fn_t)(const void* in, void* record, unsigned tiles);
static uint32_t lcg = 2026;
static int rnd(int lo, int hi) { lcg = lcg * 1103515245u + 12345u; return lo + (int)((lcg >> 8) % (unsigned)(hi - lo + 1)); }
static int16_t X[NT * 32][CH];
static int32_t pre[4][CH];
int main(void) {
  unsigned char* v = (unsigned char*)(cfg(0x38) << 16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r |= 1u << 26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char* in = v; int32_t* rec = (int32_t*)(v + REC_AT);
  for (int t = 0; t < NT * 32; t++) for (int c = 0; c < CH; c++) {
    X[t][c] = (t == 0) ? -32768 : (t == 1) ? 32767 : (int16_t)rnd(-32768, 32767);
    size_t at = ((size_t)(t / 32) * (CH / 32) + c / 32) * 2048 + 2 * IDX(t % 32, c % 32);
    uint16_t b = (uint16_t)(X[t][c] + 32768); in[at] = (unsigned char)b; in[at + 1] = (unsigned char)(b >> 8);
  }
  for (int q = 0; q < 4; q++) for (int c = 0; c < CH; c++) { pre[q][c] = rnd(-1000, 1000); rec[(c / 32) * 128 + q * 32 + c % 32] = pre[q][c]; }
  ((fn_t)(uintptr_t)EMITTED_CODE)(in, rec, NT);
  int bad = 0, identity = 0;
  for (int c = 0; c < CH; c++) {
    long long e[4] = { pre[0][c], pre[1][c], pre[2][c], pre[3][c] }, sq = 0;
    for (int t = 0; t < NT * 32; t++) { int x = X[t][c], a = x >> 8, b = x & 255; e[0] += x; e[1] += a * a; e[2] += a * b; e[3] += b * b; sq += (long long)x * x; }
    for (int q = 0; q < 4; q++) if (rec[(c / 32) * 128 + q * 32 + c % 32] != (int32_t)e[q]) bad++;
    long long g1 = rec[(c / 32) * 128 + 32 + c % 32] - pre[1][c], g2 = rec[(c / 32) * 128 + 64 + c % 32] - pre[2][c], g3 = rec[(c / 32) * 128 + 96 + c % 32] - pre[3][c];
    if (65536 * g1 + 512 * g2 + g3 != sq) identity++;
  }
  printf("adain-moments16 C=%d tiles=%d record mismatches=%d/%d square-identity failures=%d %s\n", CH, NT, bad, 4 * CH, identity, (bad || identity) ? "FAIL" : "PASS");
  return (bad || identity) != 0;
}
