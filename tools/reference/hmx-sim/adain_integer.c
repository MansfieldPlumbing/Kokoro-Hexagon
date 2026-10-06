/* Reference-only: stage buffers and call the three PowerShell-emitted bodies. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef NC
#define NC 128
#endif
static unsigned char output[NT*NC*64] __attribute__((aligned(128)));
static unsigned cfg(int off) {
 unsigned base; __asm__ volatile("%0 = cfgbase":"=r"(base));
 return *(volatile unsigned *)((base<<16)+off);
}
static int load(const char *path,void *out,size_t size) {
 FILE *f=fopen(path,"rb"); if (!f) return 1;
 size_t got=fread(out,1,size,f); int extra=fgetc(f); fclose(f);
 return got!=size || extra!=EOF;
}
static int save(const char *path,const void *data,size_t size) {
 FILE *f=fopen(path,"wb"); if (!f) return 1;
 size_t got=fwrite(data,1,size,f); fclose(f); return got!=size;
}
typedef void (*stats_fn)(const void*,void*,unsigned);
typedef void (*math_fn)(const void*,const void*,void*,unsigned);
typedef void (*affine_fn)(const void*,void*,const void*,unsigned);
int main(int argc,char **argv) {
 if (argc!=6 || NT<1 || NT>245 || (NC!=128 && NC!=256) || NT*NC*64>2031616 || NF<2 || NF>NT*32 || NF<=(NT-1)*32) return 2;
 unsigned char *v=(unsigned char *)(cfg(0x38)<<16);
 uint32_t expected[NC*2],*moments=(uint32_t *)(v+2031616);
 void *params=v+2033664,*coeffs=v+2041856;
 void *out=output;
 if (load(argv[1],v,NT*NC*64) || load(argv[2],params,NC*16) || load(argv[3],expected,NC*8)) return 4;
 ((stats_fn)(uintptr_t)STATISTICS_CODE)(v,moments,NT);
 __asm__ volatile("syncht");
 int bad=0; for (int n=0;n<NC*2;n++) if (moments[n]!=expected[n]) bad++;
 if (bad) { printf("integer-adain moments FAIL %d/%d\n",bad,NC*2); return 5; }
 ((math_fn)(uintptr_t)COEFFICIENTS_CODE)(moments,params,coeffs,NF);
 ((affine_fn)(uintptr_t)AFFINE_CODE)(v,out,coeffs,NT);
 __asm__ volatile("syncht");
 if (save(argv[4],coeffs,NC*8) || save(argv[5],out,NT*NC*64)) return 6;
 printf("integer-adain frames=%d tiles=%d moment-mismatches=0/%d emitted-coefficients-and-affine COMPLETE\n",NF,NT,NC*2);
 return 0;
}
