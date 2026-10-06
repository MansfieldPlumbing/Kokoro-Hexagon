/* Reference-only staging/serialization for a connected emitted residual block.
 * No floating-point or model arithmetic in this harness. Memory copies implement
 * halo/edge staging. Live reductions, affine, Snake, conv and residual run emitted code.
 * This simulator fixture uses DDR buffers and blocking copies, not production DMA. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned char current[NT*8192] __attribute__((aligned(128)));
static unsigned char affine[NT*8192] __attribute__((aligned(128)));
static unsigned char snake[NT*8192] __attribute__((aligned(128)));
static unsigned char conv[NT*8192] __attribute__((aligned(128)));
static unsigned char skip[NT*8192] __attribute__((aligned(128)));
static unsigned char normparams[2048] __attribute__((aligned(128)));
static unsigned char snakeparams[2048] __attribute__((aligned(128)));
static unsigned char residualparams[128] __attribute__((aligned(128)));
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
static int path(char *out,size_t length,const char *root,int stage,const char *file) {
 int n=snprintf(out,length,"%s/stage%d/%s",root,stage,file); return n<0 || (size_t)n>=length;
}
/* Native byte address of the u8 lane: valid time/channels only. */
static unsigned lane(unsigned t,unsigned c) {
 return (t/32*4+c/32)*2048+(t%32/2)*128+(c%32)*4+(t%2)*2+1;
}
static void mask_padding(unsigned char *data,unsigned char value) {
 for (unsigned t=NF;t<NT*32;t++) for (unsigned c=0;c<128;c++) data[lane(t,c)]=value;
}
typedef void (*stats_fn)(const void*,void*,unsigned);
typedef void (*coeff_fn)(const void*,const void*,void*,unsigned);
typedef void (*affine_fn)(const void*,void*,const void*,unsigned);
typedef void (*conv_fn)(void*,const void*,void*,const void*,unsigned);
typedef void (*res_fn)(const void*,const void*,void*,const void*,unsigned);
int main(int argc,char **argv) {
 if (argc!=2 || NT<1 || NT>1024 || NF<2 || NF>32768 || NF>NT*32 || NF<=(NT-1)*32) return 2;
 unsigned char *v=(unsigned char *)(cfg(0x38)<<16);
 unsigned ssr; __asm__ volatile("%0 = ssr":"=r"(ssr)); ssr|=1u<<26;
 __asm__ volatile("ssr = %0; isync"::"r"(ssr));
 void *moments=v+1835008,*coeffs=v+1836032;
 unsigned char *weights=v+524288,*table=v+1572864,*tileout=v+1048576;
 char name[1024];
 if (snprintf(name,sizeof(name),"%s/input.bin",argv[1])>=sizeof(name) || load(name,current,sizeof(current))) return 3;
 for (int s=0;s<6;s++) {
  if (s%2==0) memcpy(skip,current,sizeof(skip));
  mask_padding(current,0);
  if (path(name,sizeof(name),argv[1],s,"connected-input.bin") || save(name,current,sizeof(current))) return 4;
  if (path(name,sizeof(name),argv[1],s,"adain-parameters.bin") || load(name,normparams,2048) ||
      path(name,sizeof(name),argv[1],s,"snake-parameters.bin") || load(name,snakeparams,2048)) return 5;
  ((stats_fn)(uintptr_t)STATISTICS_CODE)(current,moments,NT);
  ((coeff_fn)(uintptr_t)COEFFICIENTS_CODE)(moments,normparams,coeffs,NF);
  __asm__ volatile("syncht");
  if (path(name,sizeof(name),argv[1],s,"connected-coefficients.bin") || save(name,coeffs,1024)) return 6;
  ((affine_fn)(uintptr_t)AFFINE_CODE)(current,affine,coeffs,NT);
  ((affine_fn)(uintptr_t)SNAKE_CODE)(affine,snake,snakeparams,NT);
  __asm__ volatile("syncht");
  if (path(name,sizeof(name),argv[1],s,"connected-adain.bin") || save(name,affine,sizeof(affine)) ||
      path(name,sizeof(name),argv[1],s,"connected-snake.bin") || save(name,snake,sizeof(snake))) return 7;
  if (path(name,sizeof(name),argv[1],s,"weights.bin") || load(name,weights,WBYTES) ||
      path(name,sizeof(name),argv[1],s,"tables.bin") || load(name,table,1024)) return 8;
  conv_fn fn=(conv_fn)(uintptr_t)(s==2?CONV_D3_CODE:s==4?CONV_D5_CODE:CONV_D1_CODE);
  for (unsigned start=0;start<NT;start+=8) {
   unsigned count=NT-start<8?NT-start:8;
   /* Exactly one whole halo tile per side suffices for K3, D<=5. */
   memset(v,0,(count+2)*8192);
   for (unsigned j=1;j<(count+2)*8192;j+=2) v[j]=128;
   for (unsigned local=0;local<(count+2)*32;local++) {
    int global=((int)start-1)*32+(int)local;
    if (global>=0 && global<NF) for (unsigned c=0;c<128;c++) v[lane(local,c)]=snake[lane((unsigned)global,c)];
   }
   fn(v+8192,weights,tileout,table,count);
   __asm__ volatile("syncht");
   memcpy(conv+start*8192,tileout,count*8192);
  }
  if (path(name,sizeof(name),argv[1],s,"connected-conv.bin") || save(name,conv,sizeof(conv))) return 9;
  if (s%2) {
   if (path(name,sizeof(name),argv[1],s,"residual-parameters.bin") || load(name,residualparams,12)) return 10;
   ((res_fn)(uintptr_t)RESIDUAL_CODE)(skip,conv,current,residualparams,NT);
   __asm__ volatile("syncht");
   if (path(name,sizeof(name),argv[1],s,"connected-residual.bin") || save(name,current,sizeof(current))) return 11;
  } else memcpy(current,conv,sizeof(current));
  printf("connected-resblock stage=%d full-group AdaIN -> Snake -> HMX conv%s COMPLETE\n",s,s%2?" -> residual":"");
  fflush(stdout);
 }
 return 0;
}
