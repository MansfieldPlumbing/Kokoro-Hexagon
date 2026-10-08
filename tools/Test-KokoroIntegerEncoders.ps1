#requires -Version 7.4
<# .SYNOPSIS
Checks integer AdaIN/Snake instruction fields against the pinned V73 assembler.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../src/emit/Hexagon.ps1')
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)) { throw 'Choose a new build/ directory.' }
$steps=[Collections.Generic.List[hashtable]]::new()
foreach ($op in 'mpyu-d','mpy-d','add-d','sub-d','gtu-d','gt','sub','vasr-w','vasl-w','vmax-w','vmin-w','vor','vsub-w','vasr-wv','vlsr-wv','vasr-hv','vasl-wv','vmin-h','vmax-h') {
 foreach ($r in 0,1,7,15,31) {
  $pair=$r -band 30
  $step=@{Op=$op;d=$r;s=$r;t=(31-$r)}
  if ($op -in 'mpyu-d','mpy-d') { $step.d=$pair }
  if ($op -in 'add-d','sub-d','gtu-d') { $step.s=$pair;$step.t=(30-$pair) }
  if ($op -in 'add-d','sub-d') { $step.d=$pair }
  if ($op -in 'gt','gtu-d') { $step.d=$r%4 }
  $steps.Add($step)
 }
}
foreach ($op in 'lsr-i','asl-i','asr-d-i') {
 foreach ($shift in 0,1,8,16,31) { foreach ($r in 0,7,15,31) {
  $step=@{Op=$op;d=$r;s=(31-$r);i=$shift}
  if ($op -eq 'asr-d-i') { $step.d=$r-band 30;$step.s=(31-$r)-band 30 }
  $steps.Add($step)
 } }
}
$steps.Add(@{Op='asr-d-i';d=30;s=0;i=63})
foreach ($op in 'vlut16','vlut16-or') {
 foreach ($pair in 0,14,30) { foreach ($r in 0,7,31) { foreach ($control in 0,7) {
  $steps.Add(@{Op=$op;d=$pair;s=$r;v=(31-$r);x=$control})
 } } }
}
$bad=@(
 @{Op='mpyu-d';d=1;s=0;t=0},@{Op='add-d';d=0;s=1;t=0},
 @{Op='gtu-d';d=0;s=0;t=31},@{Op='asr-d-i';d=0;s=1;i=16},
 @{Op='asr-d-i';d=0;s=0;i=64},@{Op='lsr-i';d=0;s=0;i=32},
 @{Op='asl-i';d=0;s=0;i=-1},@{Op='vlut16';d=1;s=0;v=0;x=0},
 @{Op='vlut16';d=0;s=0;v=0;x=8},@{Op='vlut16-or';d=0;s=0;v=32;x=0})
$rejected=0
foreach ($step in $bad) { try { $null=New-HexagonInstruction $step 0 0 } catch { $rejected++ } }
if ($rejected -ne $bad.Count) { throw 'An invalid integer operand was admitted.' }
[void][IO.Directory]::CreateDirectory($out)
$asm=[Collections.Generic.List[string]]::new(); $asm.Add('.text')
$bytes=[Collections.Generic.List[byte]]::new()
foreach ($step in $steps) {
 $asm.Add((ConvertTo-HexagonAssembly $step 0 0))
 $bytes.AddRange([byte[]](New-HexagonInstruction $step 0 0))
}
$asmPath=Join-Path $out 'integer-reference.s'
[IO.File]::WriteAllLines($asmPath,$asm,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllBytes((Join-Path $out 'integer-emitted.bin'),$bytes.ToArray())
$assembler='/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools/bin/hexagon-llvm-mc'
$hash=(& wsl.exe --exec sha256sum $assembler)-split '\s+'
if ($LASTEXITCODE -or $hash[0] -cne 'fc64c65aca06186106a73ba93e65ddf7c906bf4905b786dc748d3f034401ea27') { throw 'SDK pin mismatch' }
$wslPath=(& wsl.exe --exec wslpath -a $asmPath | Select-Object -Last 1).Trim()
$reference=@(& wsl.exe --exec $assembler -triple=hexagon -mcpu=hexagonv73 '-mattr=+hvxv73,+hvx-length128b' -show-encoding $wslPath 2>&1)
$rc=$LASTEXITCODE; $reference | Set-Content (Join-Path $out 'assembler.log') -Encoding utf8NoBOM
if ($rc) { throw 'SDK rejected integer reference instructions' }
$sdk=[Collections.Generic.List[byte]]::new()
foreach ($line in $reference) {
 if ([string]$line -match 'encoding:\s*\[([^\]]+)\]') {
  foreach ($item in $Matches[1].Split(',')) { $sdk.Add([Convert]::ToByte($item.Trim().Substring(2),16)) }
 }
}
if ($sdk.Count -ne $bytes.Count) { throw 'SDK instruction byte count mismatch' }
for ($i=0;$i -lt $bytes.Count;$i++) { if ($sdk[$i] -ne $bytes[$i]) { throw "Integer encoding mismatch at byte $i" } }
[pscustomobject]@{LegalCases=$steps.Count;InstructionBytes=$bytes.Count;Mismatches=0;InvalidOperandsRejected=$rejected}
