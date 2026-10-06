/* hexagon-sim probe: where does activation.ub :single (with and without :cm) start its window
 * for each Rs offset value? Two consecutive croutons hold row index r+1 in input channel 0
 * (cm: byte 32*r of a 64-row crouton; non-cm: odd byte 2*IDX(r,0)+1 of a 32-row crouton).
 * Weight (k=0, c=0) = 1, so output row s, column 0 = the input row that landed there, plus 1. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static unsigned cfg(int off){ unsigned b; __asm__ volatile("%0 = cfgbase":"=r"(b)); b<<=16; return *(volatile unsigned*)(b+off); }
#define IDX(i, j) (64 * ((i) / 2) + 2 * (j) + ((i) % 2))
int main(void){
  unsigned char* v=(unsigned char*)(cfg(0x38)<<16);
  unsigned r; __asm__ volatile("%0 = ssr":"=r"(r)); r|=1u<<26; __asm__ volatile("ssr = %0; isync"::"r"(r));
  unsigned char *a=v, *w=v+16384, *o=v+32768; uint32_t* t=(uint32_t*)(v+49152);
  for (int mode = 0; mode < 2; mode++) {            /* 0 = :single:cm (64 rows), 1 = :single (32 rows) */
    int rows = mode ? 32 : 64;
    memset(a, 0, 4096);
    for (int c = 0; c < 2; c++) for (int s = 0; s < rows; s++) {
      int row = c * rows + s;
      if (mode == 0) a[2048 * c + 32 * s] = (unsigned char)(row + 1);
      else a[2048 * c + 2 * IDX(s, 0) + 1] = (unsigned char)(row + 1);
    }
    memset(w, 0, 2048); w[0] = 1;                    /* W(k=0, c=0) at byte 128*(0/4)+4*0+0 */
    for (int i = 0; i < 64; i++) t[i] = 0;
    for (int i = 0; i < 32; i++) t[i] = mode ? 0x4000 : 0x6000;  /* fp16 2 (uh: acc*s/2) or 512 (ub cm: acc*s/512) */
    __asm__ volatile("bias = mxmem(%0)"::"r"(t):"memory");
    for (int off = 0; off < 32; off++) {
      unsigned rs = (unsigned)(uintptr_t)a | ((unsigned)(off >> 1) << 7) | ((unsigned)(off & 1) << 1);
      unsigned rt = 2048u | 0x7ffu;                  /* dY = one crouton; mask all Y; channel stop 31 */
      __asm__ volatile("mxclracc" ::: "memory");
      memset(o, 0, 4096);
      if (mode == 0) {
        __asm__ volatile("{ activation.ub = mxmem(%0,%1):single:cm\n weight.b = mxmem(%2,%3) }"::"r"(rs),"r"(rt),"r"(w),"r"(0x3ff):"memory");
        __asm__ volatile("mxmem(%0,%1):after:cm:sat.ub = acc"::"r"(o),"r"(0):"memory");
        printf("cm off %2d: row0<-%3d row1<-%3d row63<-%3d\n", off, o[0]-1, o[32]-1, o[32*63]-1);
      } else {
        __asm__ volatile("{ activation.ub = mxmem(%0,%1):single\n weight.b = mxmem(%2,%3) }"::"r"(rs),"r"(rt),"r"(w),"r"(0x3ff):"memory");
        __asm__ volatile("mxmem(%0,%1):after:sat.uh = acc:2x1"::"r"(o),"r"(0):"memory");
        uint16_t* u = (uint16_t*)o;
        printf("ncm off %2d: row0<-%3d row1<-%3d row31<-%3d\n", off, u[IDX(0,0)]-1, u[IDX(1,0)]-1, u[IDX(31,0)]-1);
      }
    }
  }
  printf("end\n"); return 0;
}
