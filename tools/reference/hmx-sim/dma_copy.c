/* Reference-only checks; the copies run from PowerShell-emitted bytes (Kokoro.DmaCopy.ps1). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned cfg(int off) {
    unsigned base; __asm__ volatile("%0 = cfgbase":"=r"(base));
    return *(volatile unsigned *)((base<<16)+off);
}
typedef unsigned (*dma_copy_fn)(void*,const void*,void*,unsigned);
static uint32_t desc[16] __attribute__((aligned(64)));
static int run(const char *name,const unsigned char *src,unsigned char *dst,unsigned n,unsigned seed) {
    for (unsigned i=0;i<n;i++) ((unsigned char *)src)[i]=(unsigned char)(i*131u+seed+(i>>11));
    memset(dst,0xA5,n+128);
    memset(desc,0,sizeof(desc));
    unsigned status=((dma_copy_fn)(uintptr_t)EMITTED_CODE)(desc,src,dst,n);
    unsigned bad=0; for (unsigned i=0;i<n;i++) bad+=dst[i]!=src[i];
    unsigned tail=0; for (unsigned i=n;i<n+128;i++) tail+=dst[i]!=0xA5;
    unsigned done0=desc[1]>>31, done1=desc[9]>>31;
    printf("dma-copy %s bytes=%u mismatches=%u overrun=%u done=%u,%u status=0x%x\n",name,n,bad,tail,done0,done1,status);
    return bad||tail||!done0||!done1;
}
int main(void) {
    const unsigned n=244u*8192u;
    unsigned char *v=(unsigned char *)(cfg(0x38)<<16);
    unsigned char *a=memalign(128,n+128), *b=memalign(128,n+128);
    if (!a||!b) return 2;
    int fail=0;
    fail|=run("ddr-to-vtcm",a,v,n,7);
    fail|=run("vtcm-to-ddr",v,b,n,11);
    fail|=run("ddr-to-ddr",a,b,n,13);
    fail|=run("odd-length",a,b+1,8191u,17);
    printf("dma-copy %s\n",fail?"FAIL":"PASS");
    return fail;
}
