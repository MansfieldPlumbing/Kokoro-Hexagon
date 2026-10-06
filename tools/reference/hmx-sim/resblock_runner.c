/* Reference-only OS/resource shim. The complete connected job executes the
 * unchanged emitted ELF image; this file supplies memory and documented APIs.
 * No model or floating-point arithmetic. Device uses its actual QuRT/HAP APIs. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned char input[INPUT_BYTES] __attribute__((aligned(128)));
static unsigned char weights[WEIGHT_BYTES] __attribute__((aligned(128)));
static unsigned char params[PARAMETER_BYTES] __attribute__((aligned(128)));
static unsigned char output[OUTPUT_BYTES] __attribute__((aligned(128)));
static unsigned char expected[INPUT_BYTES] __attribute__((aligned(128)));
static unsigned char expected_coeff[COEFFICIENT_BYTES] __attribute__((aligned(128)));
static unsigned cfg(int off) {unsigned base;__asm__ volatile("%0 = cfgbase":"=r"(base));return *(volatile unsigned*)((base<<16)+off);}
static int noop(void){return 0;}
static int acquire(void *attr,unsigned timeout){(void)attr;(void)timeout;return 1;}
static int getvtcm(void *attr,void **ptr,unsigned *length){(void)attr;*ptr=(void*)(cfg(0x38)<<16);*length=VTCM_BYTES;return 0;}
static int load(const char *root,const char *name,void *dest,size_t bytes){char path[1024];if(snprintf(path,sizeof(path),"%s/%s",root,name)>=sizeof(path))return 1;FILE*f=fopen(path,"rb");if(!f)return 1;size_t n=fread(dest,1,bytes,f);int extra=fgetc(f);fclose(f);return n!=bytes||extra!=EOF;}
static int save(const char *root,const char *name,const void *data,size_t bytes){char path[1024];if(snprintf(path,sizeof(path),"%s/%s",root,name)>=sizeof(path))return 1;FILE*f=fopen(path,"wb");if(!f)return 1;size_t n=fwrite(data,1,bytes,f);fclose(f);return n!=bytes;}
struct arg {void *ptr;unsigned bytes;};
int main(int argc,char **argv){
 if(argc!=2)return 2;
 unsigned ssr;__asm__ volatile("%0 = ssr":"=r"(ssr));ssr|=1u<<26;__asm__ volatile("ssr = %0; isync"::"r"(ssr));
 PATCH_GOT;
 if(load(argv[1],"activations.bin",input,sizeof(input))||load(argv[1],"weights.bin",weights,sizeof(weights))||load(argv[1],"tables.bin",params,sizeof(params))||load(argv[1],"expected.bin",expected,sizeof(expected))||load(argv[1],"expected-coefficients.bin",expected_coeff,sizeof(expected_coeff)))return 3;
 unsigned tiles=TILES;struct arg args[5]={{&tiles,4},{input,sizeof(input)},{weights,sizeof(weights)},{params,sizeof(params)},{output,sizeof(output)}};
 typedef int(*entry_fn)(unsigned,unsigned,unsigned,struct arg*);
 /* Volatile prevents the SDK compiler from lowering image+ENTRY to call image.
  * Its generated reference-runner.s exposed that lost byte offset at -O2. */
 entry_fn volatile entry=(entry_fn)(image+ENTRY);
 printf("EmittedEntry=%08x FirstWord=%08x ImageBytes=%u\n",(unsigned)(uintptr_t)entry,*(volatile unsigned*)(image+ENTRY),(unsigned)sizeof(image));fflush(stdout);
#ifdef ADMISSION_ONLY
 memset(output,0x5a,64);
 int bad=0;tiles=0;if(entry(0,0,0x02040100,args)!=14)bad++;tiles=TILES;
 args[1].bytes--;if(entry(0,0,0x02040100,args)!=14)bad++;args[1].bytes++;
 args[1].ptr=0;if(entry(0,0,0x02040100,args)!=14)bad++;args[1].ptr=input;
 args[4].bytes--;if(entry(0,0,0x02040100,args)!=14)bad++;args[4].bytes++;
 for(unsigned i=0;i<64;i++)if(output[i]!=0x5a)bad++;
 printf("AdmissionChecks=4 AdmissionFailures=%d TelemetryPreserved=%s\n",bad,bad?"false":"true");
 return bad!=0;
#endif
 int rc=entry(0,0,0x02040100,args);
 unsigned stage=*(unsigned*)(output+36),offset=*(unsigned*)(output+40),completed=*(unsigned*)(output+44);
 if(save(argv[1],"simulator-workspace.bin",output,sizeof(output)))return 4;
 if(offset<FINAL_OFFSET+64||offset>FINAL_OFFSET+191||offset+COEFFICIENT_OFFSET+COEFFICIENT_BYTES>sizeof(output))return 5;
 unsigned mismatch=0,coeff_mismatch=0;
 for(unsigned i=1;i<INPUT_BYTES;i+=2)if(output[offset+i]!=expected[i])mismatch++;
 for(unsigned i=0;i<COEFFICIENT_BYTES;i++)if(output[offset+COEFFICIENT_OFFSET+i]!=expected_coeff[i])coeff_mismatch++;
 printf("ConnectedRunnerRc=%d Stage=%u CompletedStages=%u FinalLaneMismatches=%u CoefficientByteMismatches=%u\n",rc,stage,completed,mismatch,coeff_mismatch);
 fflush(stdout);
 return rc||stage!=7||completed!=COMPLETED_STAGES||mismatch||coeff_mismatch;
}
