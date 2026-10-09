#requires -Version 7.4
# Runs the emitted generator tail job in the V73 simulator (reference shim only) on a tail
# fixture; the output is checked by tools/Test-KokoroGeneratorTailOutput.ps1.
# -ExpectStage: the stage word the job leaves at output offset 36 (the tail: 7; the decoder job leaves 0).
param([Parameter(Mandatory)][string]$EmissionDirectory,[Parameter(Mandatory)][string]$FixtureDirectory,[ValidateRange(0,64)][int]$ExpectStage=7)
$ErrorActionPreference='Stop'
$emission=[IO.Path]::GetFullPath($EmissionDirectory);$fixture=[IO.Path]::GetFullPath($FixtureDirectory)
$layout=Get-Content (Join-Path $emission 'runner-layout.json') -Raw|ConvertFrom-Json
$link=Get-Content (Join-Path $emission 'runner-link.json') -Raw|ConvertFrom-Json
$image=[IO.File]::ReadAllBytes((Join-Path $emission 'libkokoro_generator_tail_skel.so'))
$header=Join-Path $fixture 'runner-image.h';if(Test-Path $header){throw 'Use a fresh fixture for simulator verification'}
$writer=[IO.StreamWriter]::new($header,$false,[Text.Encoding]::UTF8)
try {
 $writer.WriteLine("#define INPUT_BYTES $($layout.InputBytes)`n#define WEIGHT_BYTES $($layout.WeightBytes)`n#define PARAMETER_BYTES $($layout.ParameterBytes)`n#define OUTPUT_BYTES $($layout.OutputBytes)`n#define VTCM_BYTES $($layout.VtcmBytes)`n#define TILES $($layout.Tiles)`n#define ENTRY $($link.Entry)`n#define EXPECT_STAGE $ExpectStage")
 $writer.WriteLine('__attribute__((section(".text"),aligned(4096))) static unsigned char image[] = {')
 for($i=0;$i -lt $image.Length;$i+=32){$last=[math]::Min($image.Length-1,$i+31);$writer.WriteLine((($image[$i..$last]|ForEach-Object {'0x'+$_.ToString('x2')}) -join ',')+',')}
 $writer.WriteLine('};')
 $patch=[Collections.Generic.List[string]]::new()
 foreach($p in $link.Got.PSObject.Properties) {
  $fn=switch($p.Name){'compute_resource_acquire'{'acquire'}'compute_resource_attr_get_vtcm_ptr_v2'{'getvtcm'}default{'noop'}}
  $patch.Add("*(unsigned *)(image+$($p.Value))=(unsigned)(uintptr_t)$fn;")
 }
 $writer.WriteLine('#define PATCH_GOT '+($patch -join ' '))
}finally{$writer.Dispose()}
$wslFixture=(& wsl.exe --exec wslpath -a $fixture).Trim()
$script=(& wsl.exe --exec wslpath -a (Join-Path $PSScriptRoot 'hmx-sim/run-tail-runner.sh')).Trim()
& wsl.exe --exec bash $script $wslFixture
if($LASTEXITCODE){throw "Tail runner simulator failed; inspect $fixture/runner-simulator.log"}
[pscustomobject]@{LibrarySHA256=(Get-FileHash (Join-Path $emission 'libkokoro_generator_tail_skel.so')).Hash;Output=(Join-Path $fixture 'simulator-output.bin')}
