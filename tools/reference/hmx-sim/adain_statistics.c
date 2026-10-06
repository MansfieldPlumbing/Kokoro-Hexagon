/* Reference-only staging/checks; the moments run from PowerShell-emitted bytes. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifndef NT
#define NT 245
#endif
#ifndef NC
#define NC 128
#endif
static unsigned cfg(int off) {
    unsigned base; __asm__ volatile("%0 = cfgbase":"=r"(base));
    return *(volatile unsigned *)((base<<16)+off);
}
static int load(const char *path,void *out,size_t size) {
    FILE *f=fopen(path,"rb"); if (!f) return 1;
    size_t got=fread(out,1,size,f); int extra=fgetc(f); fclose(f);
    return got!=size || extra!=EOF;
}
typedef void (*statistics_fn)(const void*,void*,unsigned);
int main(int argc,char **argv) {
    if (argc!=4 || NT<1 || NT>245 || (NC!=128 && NC!=256) || NT*NC*64>2031616) return 2;
    unsigned char *v=(unsigned char *)(cfg(0x38)<<16);
    uint32_t expected[NC*2],*out=(uint32_t *)(v+2031616);
    if (load(argv[1],v,NT*NC*64) || load(argv[2],expected,sizeof(expected))) return 3;
    memset(out,0,NC*8);
    ((statistics_fn)(uintptr_t)EMITTED_CODE)(v,out,NT);
    __asm__ volatile("syncht");
    int bad=0; for (int n=0;n<NC*2;n++) if (out[n]!=expected[n]) bad++;
    FILE *f=fopen(argv[3],"wb"); if (!f) return 4;
    size_t wrote=fwrite(out,1,NC*8,f); fclose(f); if (wrote!=NC*8) return 5;
    printf("adain-statistics tiles=%d mismatches=%d/%d %s\n",NT,bad,NC*2,bad?"FAIL":"PASS");
    return bad!=0;
}
