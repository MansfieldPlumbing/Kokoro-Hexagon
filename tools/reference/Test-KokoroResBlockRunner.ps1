#requires -Version 7.4
param([Parameter(Mandatory)][string]$EmissionDirectory,[Parameter(Mandatory)][string]$FixtureDirectory,[ValidateSet('connected','admission')][string]$Mode='connected')
$ErrorActionPreference='Stop'
$emission=[IO.Path]::GetFullPath($EmissionDirectory);$fixture=[IO.Path]::GetFullPath($FixtureDirectory)
$layout=Get-Content (Join-Path $emission 'runner-layout.json') -Raw|ConvertFrom-Json
$link=Get-Content (Join-Path $emission 'runner-link.json') -Raw|ConvertFrom-Json
$image=[IO.File]::ReadAllBytes((Join-Path $emission 'libkokoro_resblock_run_skel.so'))
$header=Join-Path $fixture 'runner-image.h';if(Test-Path $header){throw 'Use a fresh fixture for simulator verification'}
$writer=[IO.StreamWriter]::new($header,$false,[Text.Encoding]::UTF8)
try {
 $parameterBytes=if($layout.ParameterBytes){$layout.ParameterBytes}else{49152}
 $coefficientBytes=if($layout.CoefficientBytes){$layout.CoefficientBytes}else{6144}
 $finalOffset=if($layout.FinalWorkspaceOffset){$layout.FinalWorkspaceOffset}else{0}
 $coefficientOffset=if($layout.CoefficientOffset){$layout.CoefficientOffset}else{5*$layout.InputBytes}
 $completed=if($layout.CompletedStages){$layout.CompletedStages}else{6}
 $writer.WriteLine("#define PARAMETER_BYTES $parameterBytes`n#define COEFFICIENT_BYTES $coefficientBytes`n#define FINAL_OFFSET $finalOffset`n#define COEFFICIENT_OFFSET $coefficientOffset`n#define COMPLETED_STAGES $completed")
 $writer.WriteLine("#define INPUT_BYTES $($layout.InputBytes)`n#define WEIGHT_BYTES $($layout.WeightBytes)`n#define OUTPUT_BYTES $($layout.OutputBytes)`n#define VTCM_BYTES $($layout.VtcmBytes)`n#define TILES $($layout.Tiles)`n#define ENTRY $($link.Entry)")
 $writer.WriteLine('__attribute__((section(".text"),aligned(4096))) static unsigned char image[] = {')
 for($i=0;$i -lt $image.Length;$i+=32){$last=[math]::Min($image.Length-1,$i+31);$writer.WriteLine((($image[$i..$last]|ForEach-Object {'0x'+$_.ToString('x2')}) -join ',')+',')}
 $writer.WriteLine('};')
 $patch=[Collections.Generic.List[string]]::new()
 foreach($p in $link.Got.PSObject.Properties) {
  $fn=switch($p.Name){'memcpy'{'memcpy'}'compute_resource_acquire'{'acquire'}'compute_resource_attr_get_vtcm_ptr_v2'{'getvtcm'}default{'noop'}}
  $patch.Add("*(unsigned *)(image+$($p.Value))=(unsigned)(uintptr_t)$fn;")
 }
 $writer.WriteLine('#define PATCH_GOT '+($patch -join ' '))
}finally{$writer.Dispose()}
$wslEmission=(& wsl.exe --exec wslpath -a $emission).Trim();$wslFixture=(& wsl.exe --exec wslpath -a $fixture).Trim()
$script=(& wsl.exe --exec wslpath -a (Join-Path $PSScriptRoot 'hmx-sim/run-resblock-runner.sh')).Trim()
& wsl.exe --exec bash $script $wslEmission $wslFixture $Mode
if($LASTEXITCODE){throw "Connected runner simulator failed; inspect $fixture/runner-simulator.log"}
[pscustomobject]@{LibrarySHA256=(Get-FileHash (Join-Path $emission 'libkokoro_resblock_run_skel.so')).Hash;SimulatorVerified=$true}
