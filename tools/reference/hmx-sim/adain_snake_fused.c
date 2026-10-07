/* Reference-only staging/checks. Frozen AdaIN affine -> Snake bodies and the fused
 * AdaIN+Snake body all run from PowerShell-emitted bytes; this compares their outputs. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define REAL 64
#define RANDOM 32
#define NT (REAL+RANDOM)
#define TB 8192u
static unsigned cfg(int off) {unsigned base;__asm__ volatile("%0 = cfgbase":"=r"(base));return *(volatile unsigned*)((base<<16)+off);}
static int load(const char *root,const char *name,void *dest,size_t bytes,size_t skip) {
    char path[1024]; if (snprintf(path,sizeof(path),"%s/%s",root,name)>=(int)sizeof(path)) return 1;
    FILE *f=fopen(path,"rb"); if (!f) return 1;
    if (fseek(f,(long)skip,SEEK_SET)) {fclose(f);return 1;}
    size_t n=fread(dest,1,bytes,f); fclose(f); return n!=bytes;
}
typedef void (*affine_fn)(const void*,void*,const void*,unsigned);
typedef void (*snake_fn)(const void*,void*,const void*,unsigned);
typedef void (*fused_fn)(const void*,void*,const void*,const void*,unsigned);
int main(int argc,char **argv) {
    if (argc!=2) return 2;
    unsigned char *v=(unsigned char *)(cfg(0x38)<<16);
    unsigned char *in=v, *q8=v+NT*TB, *ref=v+2*NT*TB, *out=v+3*NT*TB, *coef=v+4*NT*TB, *snk=coef+1024;
    if (load(argv[1],"activations.bin",in,REAL*TB,0)) return 3;
    uint32_t x=0x9E3779B9u;
    for (unsigned i=REAL*TB;i<NT*TB;i++) {x^=x<<13;x^=x>>17;x^=x<<5;in[i]=(unsigned char)x;}
    unsigned bad_total=0;
    for (int set=0;set<18;set++) {
        int b=set/6,st=set%6;
        if (load(argv[1],"expected-coefficients.bin",coef,1024,(size_t)set*1024)) return 4;
        if (load(argv[1],"tables.bin",snk,2048,(size_t)b*49152+(size_t)st*8192+2048)) return 5;
        memset(ref,0xA5,NT*TB); memset(out,0x5A,NT*TB);
        ((affine_fn)(uintptr_t)AFFINE_CODE)(in,q8,coef,NT);
        ((snake_fn)(uintptr_t)SNAKE_CODE)(q8,ref,snk,NT);
        ((fused_fn)(uintptr_t)FUSED_CODE)(in,out,coef,snk,NT);
        __asm__ volatile("syncht");
        unsigned bad=0; for (unsigned i=0;i<NT*TB;i++) bad+=out[i]!=ref[i];
        bad_total+=bad;
        printf("adain-snake-fused branch=%d stage=%d bytes=%u mismatches=%u\n",b,st,NT*TB,bad);
    }
    printf("adain-snake-fused sets=18 tiles=%d %s\n",NT,bad_total?"FAIL":"PASS");
    return bad_total!=0;
}
