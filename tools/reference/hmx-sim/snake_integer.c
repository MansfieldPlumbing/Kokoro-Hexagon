/* Reference-only staging. All Snake arithmetic runs from emitted bytes. */
#include <stdint.h>
#include <stdio.h>
#ifndef NC
#define NC 128
#endif
static unsigned char input[NT*NC*64] __attribute__((aligned(128)));
static unsigned char output[NT*NC*64] __attribute__((aligned(128)));
static unsigned char params[NC*12+512] __attribute__((aligned(128)));
static int load(const char *path,void *out,size_t size) {
 FILE *f=fopen(path,"rb"); if (!f) return 1;
 size_t got=fread(out,1,size,f); int extra=fgetc(f); fclose(f);
 return got!=size || extra!=EOF;
}
typedef void (*snake_fn)(const void*,void*,const void*,unsigned);
int main(int argc,char **argv) {
 if (argc!=4 || NT<1 || NT>1024 || (NC!=128 && NC!=256)) return 2;
 if (load(argv[1],input,sizeof(input)) || load(argv[2],params,sizeof(params))) return 3;
 ((snake_fn)(uintptr_t)EMITTED_CODE)(input,output,params,NT);
 __asm__ volatile("syncht");
 FILE *f=fopen(argv[3],"wb"); if (!f) return 4;
 size_t wrote=fwrite(output,1,sizeof(output),f); fclose(f);
 if (wrote!=sizeof(output)) return 5;
 printf("integer-snake tiles=%d emitted HVX COMPLETE\n",NT); return 0;
}
