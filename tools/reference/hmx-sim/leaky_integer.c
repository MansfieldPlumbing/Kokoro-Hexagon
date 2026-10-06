/* Reference-only operator contract check. Arithmetic executes emitted bytes. */
#include <stdint.h>
#include <stdio.h>
static unsigned char input[NT*NC*64] __attribute__((aligned(128)));
static unsigned char output[NT*NC*64] __attribute__((aligned(128)));
static unsigned char expected[NT*NC*64] __attribute__((aligned(128)));
static unsigned char params[128] __attribute__((aligned(128)));
static int load(const char*root,const char*name,void*dest,unsigned bytes){char path[1024];if(snprintf(path,sizeof(path),"%s/%s",root,name)>=sizeof(path))return 1;FILE*f=fopen(path,"rb");if(!f)return 1;unsigned got=fread(dest,1,bytes,f);int extra=fgetc(f);fclose(f);return got!=bytes||extra!=EOF;}
int main(int argc,char**argv){
 if(argc!=2||NT<1||NT>1024||(NC!=128&&NC!=256))return 2;
 unsigned ssr;__asm__ volatile("%0 = ssr":"=r"(ssr));ssr|=1u<<26;__asm__ volatile("ssr = %0; isync"::"r"(ssr));
 if(load(argv[1],"input.bin",input,sizeof(input))||load(argv[1],"expected.bin",expected,sizeof(expected))||load(argv[1],"parameters.bin",params,12))return 3;
 typedef void(*fn)(const void*,void*,const void*,unsigned);
 fn volatile body=(fn)CODE;body(input,output,params,NT);__asm__ volatile("syncht");
 unsigned bad=0;for(unsigned i=0;i<sizeof(output);i++)if(output[i]!=expected[i])bad++;
 /* The in-place form is used by connected graph composition. */
 body(input,input,params,NT);__asm__ volatile("syncht");unsigned alias_bad=0;for(unsigned i=0;i<sizeof(input);i++)if(input[i]!=expected[i])alias_bad++;
 char path[1024];if(snprintf(path,sizeof(path),"%s/simulator-output.bin",argv[1])>=sizeof(path))return 4;FILE*f=fopen(path,"wb");if(!f)return 4;if(fwrite(output,1,sizeof(output),f)!=sizeof(output))return 4;fclose(f);
 printf("LeakyReluByteMismatches=%u/%u InPlaceByteMismatches=%u\n",bad,(unsigned)sizeof(output),alias_bad);return bad||alias_bad;
}
