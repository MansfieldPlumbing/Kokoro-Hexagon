/* hexagon-sim harness for the PowerShell-emitted decoder passes (src/emit/Kokoro.Decoder16.ps1). Build with -DPASS=<n>
 * -DCH=<channels> -DFR=<frames> [-DHW=<halfword>] [-DCHAN=<channel>] -include <emitted_code.h>. Test tool only.
 *   1 PadRows16     rows FR.. of the last tile <- HW, everything else unchanged
 *   2 LowWindow16   out = in << 8 per halfword
 *   3 FrameDouble16 out frame 2t, 2t+1 <- in frame t
 *   4 Pool2         p[2t] = q31(a[t], W1) + B, p[2t+1] = q31(a[t], W2) + q31(a[t+1], W0) + B (wrapping sums), clamped,
 *                   as high/low windows; a = 0 from frame FR
 *   5 StrideConv16  v[t] = clamp((W0 c[2t-1] + W1 c[2t] + W2 c[2t+1] + B + 2^14) >> 15) into channel CHAN, rows < FR */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#define IDX(i, j) (64 * ((i) / 2) + 2 * (j) + ((i) % 2))
#define NT ((FR + 31) / 32)
#define TB ((size_t)CH * 64)
#define ALIGN(x) ((((size_t)(x)) + 65535) & ~(size_t)65535)
#ifndef HW
#define HW 0x8000
#endif
#ifndef CHAN
#define CHAN 0
#endif
static uint32_t lcg = 7;
static int32_t rnd(int32_t lo, int32_t hi) { lcg = lcg * 1103515245u + 12345u; uint32_t r = (lcg >> 1) ^ (lcg << 15); return lo + (int32_t)(r % (uint32_t)(hi - lo + 1)); }
static int32_t sat32(int64_t v) { return v > INT32_MAX ? INT32_MAX : v < INT32_MIN ? INT32_MIN : (int32_t)v; }
static int32_t q31(int32_t a, int32_t b) { return sat32(((int64_t)a * b + ((int64_t)1 << 30)) >> 31); }
static int32_t clamp16(int32_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : v; }
static size_t at(int t, int c, int ch) { return ((size_t)(t / 32) * (ch / 32) + c / 32) * 2048 + 2 * IDX(t % 32, c % 32); }
static uint16_t get16(const unsigned char* p, size_t a) { return (uint16_t)(p[a] | p[a + 1] << 8); }
static void put16(unsigned char* p, size_t a, uint16_t v) { p[a] = (unsigned char)v; p[a + 1] = (unsigned char)(v >> 8); }
int main(void) {
  unsigned char* v = (unsigned char*)(cfg(0x38) << 16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r |= 1u << 26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *a = v, *b = v + ALIGN((NT + 1) * TB), *c2 = b + ALIGN(2 * (NT + 1) * TB), *k = c2 + ALIGN(2 * (NT + 1) * TB);
  int bad = 0, shown = 0, n = 0;
  for (size_t i = 0; i < (NT + 1) * TB; i++) a[i] = (unsigned char)rnd(0, 255);
  for (size_t i = 0; i < 2 * (NT + 1) * TB; i++) { b[i] = (unsigned char)rnd(0, 255); c2[i] = b[i]; }
#if PASS == 1
  memcpy(b, a, NT * TB);
  ((void (*)(void*))(uintptr_t)EMITTED_CODE)(a);
  for (int t = 0; t < NT * 32; t++) for (int c = 0; c < CH; c++) { size_t p = at(t, c, CH); uint16_t want = t >= FR ? HW : get16(b, p);
    n++; if (get16(a, p) != want) { bad++; if (shown++ < 6) printf("t=%d c=%d got %u want %u\n", t, c, get16(a, p), want); } }
  printf("decoder-pass padrows16 C=%d F=%d hw=0x%x mismatches=%d/%d %s\n", CH, FR, HW, bad, n, bad ? "FAIL" : "PASS");
#elif PASS == 2
  ((void (*)(void*, void*, unsigned))(uintptr_t)EMITTED_CODE)(a, b, (unsigned)(NT * TB / 128));
  for (size_t i = 0; i < NT * TB; i += 2) { n++; uint16_t want = (uint16_t)(get16(a, i) << 8); if (get16(b, i) != want) bad++; }
  printf("decoder-pass lowwindow16 C=%d tiles=%d mismatches=%d/%d %s\n", CH, NT, bad, n, bad ? "FAIL" : "PASS");
#elif PASS == 3
  ((void (*)(void*, void*, unsigned))(uintptr_t)EMITTED_CODE)(a, b, NT);
  for (int t = 0; t < 2 * NT * 32; t++) for (int c = 0; c < CH; c++) { n++;
    uint16_t want = get16(a, at(t / 2, c, CH)), got = get16(b, at(t, c, CH));
    if (got != want) { bad++; if (shown++ < 6) printf("t=%d c=%d got %u want %u\n", t, c, got, want); } }
  printf("decoder-pass framedouble16 C=%d tiles=%d mismatches=%d/%d %s\n", CH, NT, bad, n, bad ? "FAIL" : "PASS");
#elif PASS == 4
  static int16_t A[(NT + 1) * 32][CH]; static int32_t W0[CH], W1[CH], W2[CH], B[CH];
  for (int t = 0; t < (NT + 1) * 32; t++) for (int c = 0; c < CH; c++) { A[t][c] = t < FR ? (int16_t)rnd(-32768, 32767) : 0;
    put16(a, ((size_t)(t / 32) * (CH / 32) + c / 32) * 2048 + 2 * IDX(t % 32, c % 32), (uint16_t)(A[t][c] + 32768)); }
  int32_t* kc = (int32_t*)k;
  for (int c = 0; c < CH; c++) { W0[c] = rnd(-1073741824, 1073741823); W1[c] = rnd(-1073741824, 1073741823); W2[c] = rnd(-1073741824, 1073741823); B[c] = rnd(-5000, 5000);
    int base = (c / 32) * 128 + c % 32; kc[base] = W0[c]; kc[base + 32] = W1[c]; kc[base + 64] = W2[c]; kc[base + 96] = B[c]; }
  ((void (*)(void*, void*, void*, void*, unsigned))(uintptr_t)EMITTED_CODE)(a, b, c2, k, NT);
  for (int t = 0; t < 2 * NT * 32; t++) for (int c = 0; c < CH; c++) { n++;
    int s = t / 2; int32_t p = (t % 2 == 0) ? (int32_t)((uint32_t)q31(A[s][c] * 65536, W1[c]) + (uint32_t)B[c])
      : (int32_t)((uint32_t)q31(A[s][c] * 65536, W2[c]) + (uint32_t)q31(A[s + 1][c] * 65536, W0[c]) + (uint32_t)B[c]);
    p = clamp16(p); size_t q = at(t, c, CH);
    unsigned char wh = (unsigned char)((p >> 8) + 128), wl = (unsigned char)(p & 255);
    if (b[q + 1] != wh || c2[q + 1] != wl) { bad++; if (shown++ < 6) printf("t=%d c=%d p=%ld got %u/%u want %u/%u\n", t, c, (long)p, b[q + 1], c2[q + 1], wh, wl); } }
  printf("decoder-pass pool2 C=%d F=%d mismatches=%d/%d %s\n", CH, FR, bad, n, bad ? "FAIL" : "PASS");
#elif PASS == 5
  int32_t* curve = (int32_t*)k; int32_t* kc = (int32_t*)(k + 65536);
  for (int i = 0; i < 2 * FR; i++) curve[i] = rnd(-30000, 30000);
  int32_t w0 = rnd(-40000, 40000), w1 = rnd(-40000, 40000), w2 = rnd(-40000, 40000); int64_t bias = (int64_t)rnd(-50000, 50000) * 32768;
  kc[0] = w0; kc[1] = w1; kc[2] = w2; memcpy(kc + 4, &bias, 8);
  memcpy(c2, b, NT * TB);
  ((void (*)(void*, void*, void*))(uintptr_t)EMITTED_CODE)(curve, b, kc);
  for (int t = 0; t < NT * 32; t++) for (int c = 0; c < CH; c++) { n++; size_t q = at(t, c, CH); uint16_t want = get16(c2, q);
    if (c == CHAN && t < FR) { int64_t acc = (int64_t)w0 * (t ? curve[2 * t - 1] : 0) + (int64_t)w1 * curve[2 * t] + (int64_t)w2 * curve[2 * t + 1] + bias + 16384;
      want = (uint16_t)(clamp16((int32_t)(acc >> 15)) + 32768); }
    if (get16(b, q) != want) { bad++; if (shown++ < 6) printf("t=%d c=%d got %u want %u\n", t, c, get16(b, q), want); } }
  printf("decoder-pass strideconv16 C=%d F=%d channel=%d mismatches=%d/%d %s\n", CH, FR, CHAN, bad, n, bad ? "FAIL" : "PASS");
#endif
  return bad != 0;
}
