/* Reference-only file staging for the exact PowerShell-emitted convolution.
 * VTCM layout and enable sequence follow emitted_conv.c in this directory.
 * No convolution or model implementation in this harness. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifndef NT
#define NT 8
#endif
static unsigned cfg(int off) {
    unsigned base;
    __asm__ volatile("%0 = cfgbase":"=r"(base));
    return *(volatile unsigned *)((base<<16)+off);
}
static int load(const char *name, void *out, size_t size) {
    FILE *f=fopen(name,"rb");
    if (!f) return 1;
    size_t got=fread(out,1,size,f);
    int extra=fgetc(f);
    fclose(f);
    return got!=size || extra!=EOF;
}
typedef void (*conv_fn)(void*,const void*,void*,const void*,unsigned);
int main(int argc,char **argv) {
    if (argc!=5 || NT<1 || NT>32) return 2;
    unsigned char *v=(unsigned char *)(cfg(0x38)<<16);
    unsigned ssr;
    __asm__ volatile("%0 = ssr":"=r"(ssr));
    ssr|=1u<<26;
    __asm__ volatile("ssr = %0; isync"::"r"(ssr));
    unsigned char *act=v,*weights=v+524288,*out=v+1048576;
    unsigned char *table=v+1572864;
    if (load(argv[1],act,(NT+2)*4*2048) || load(argv[2],weights,2*3*4*2048) || load(argv[3],table,4*256)) {
        puts("captured FAIL file size or read"); return 3;
    }
    memset(out,0,NT*4*2048);
    ((conv_fn)(uintptr_t)EMITTED_CODE)(act+4*2048,weights,out,table,NT);
    __asm__ volatile("syncht");
    FILE *f=fopen(argv[4],"wb");
    if (!f) return 4;
    size_t wrote=fwrite(out,1,NT*4*2048,f);
    fclose(f);
    printf("captured bytes=%u %s\n",(unsigned)wrote,wrote==NT*4*2048?"PASS":"FAIL");
    return wrote!=NT*4*2048;
}
