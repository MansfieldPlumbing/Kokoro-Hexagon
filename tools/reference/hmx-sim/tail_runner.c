/* Reference-only OS/resource shim for the generator tail job (src/emit/Kokoro.GeneratorTailRun.ps1).
 * The job executes the unchanged emitted ELF image; this file supplies memory and the documented
 * resource APIs, then saves the complete output buffer. No model or floating-point arithmetic. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned char input[INPUT_BYTES] __attribute__((aligned(128)));
static unsigned char weights[WEIGHT_BYTES] __attribute__((aligned(128)));
static unsigned char params[PARAMETER_BYTES] __attribute__((aligned(128)));
static unsigned char output[OUTPUT_BYTES] __attribute__((aligned(128)));
static unsigned cfg(int off) {unsigned base;__asm__ volatile("%0 = cfgbase":"=r"(base));return *(volatile unsigned*)((base<<16)+off);}
static int noop(void){return 0;}
static int acquire(void *attr,unsigned timeout){(void)attr;(void)timeout;return 1;}
static int getvtcm(void *attr,void **ptr,unsigned *length){(void)attr;*ptr=(void*)(cfg(0x38)<<16);*length=VTCM_BYTES;return 0;}
static int load(const char *root,const char *name,void *dest,size_t bytes){char path[1024];if(snprintf(path,sizeof(path),"%s/%s",root,name)>=(int)sizeof(path))return 1;FILE*f=fopen(path,"rb");if(!f)return 1;size_t n=fread(dest,1,bytes,f);int extra=fgetc(f);fclose(f);return n!=bytes||extra!=EOF;}
static int save(const char *root,const char *name,const void *data,size_t bytes){char path[1024];if(snprintf(path,sizeof(path),"%s/%s",root,name)>=(int)sizeof(path))return 1;FILE*f=fopen(path,"wb");if(!f)return 1;size_t n=fwrite(data,1,bytes,f);fclose(f);return n!=bytes;}
struct arg {void *ptr;unsigned bytes;};
int main(int argc,char **argv){
 if(argc!=2)return 2;
 unsigned ssr;__asm__ volatile("%0 = ssr":"=r"(ssr));ssr|=1u<<26;__asm__ volatile("ssr = %0; isync"::"r"(ssr));
 PATCH_GOT;
 if(load(argv[1],"activations.bin",input,sizeof(input))||load(argv[1],"weights.bin",weights,sizeof(weights))||load(argv[1],"tables.bin",params,sizeof(params)))return 3;
 unsigned tiles=TILES;struct arg args[5]={{&tiles,4},{input,sizeof(input)},{weights,sizeof(weights)},{params,sizeof(params)},{output,sizeof(output)}};
 typedef int(*entry_fn)(unsigned,unsigned,unsigned,struct arg*);
 entry_fn volatile entry=(entry_fn)(image+ENTRY);
 int rc=entry(0,0,0x02040100,args);
 unsigned stage=*(unsigned*)(output+36),codes=*(unsigned*)(output+40),done=*(unsigned*)(output+44);
 if(save(argv[1],"simulator-output.bin",output,sizeof(output)))return 4;
 printf("TailRunnerRc=%d Stage=%u Done=%u CodesOffset=%u\n",rc,stage,done,codes);
 fflush(stdout);
 return rc||stage!=7||done!=1;
}
