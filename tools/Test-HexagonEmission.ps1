#requires -Version 7.4
# The SDK assembler is an independent verifier, never an input to the emitted ELF.
[CmdletBinding()]
param(
    [string] $OutputDirectory = $(
        $buildDir = @(
            (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN'),
            (Join-Path $PSScriptRoot '..\..\..\Build\Kokoro-QNN'),
            'C:\Dev\Build\Kokoro-QNN'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $buildDir) { $buildDir = 'C:\Dev\Build\Kokoro-QNN' }
        Join-Path $buildDir 'hexagon-emission\emitted'
    ),
    [string] $ToolRoot = '/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools/bin',
    [ValidateSet('Probe','KokoroAffine','KokoroConvTile','KokoroR0Sub0','KokoroHmxLock','KokoroHmxMatrix')][string] $Kernel='Probe',
    [switch] $Force
)
$ErrorActionPreference='Stop'
$output=[IO.Path]::GetFullPath((Join-Path $OutputDirectory $Kernel))
$result=& (Join-Path $PSScriptRoot 'Emit-HexagonProbe.ps1') -OutputDirectory $output -Kernel $Kernel -Force:$Force
$wslOutput=(& wsl.exe --exec wslpath -a $output 2>$null | Select-Object -Last 1).Trim()
if($LASTEXITCODE -ne 0 -or -not $wslOutput.StartsWith('/')) { throw 'Cannot resolve output directory in WSL' }
$assembler="$ToolRoot/hexagon-llvm-mc"
$hash=(& wsl.exe --exec sha256sum $assembler 2>$null | Select-Object -Last 1) -split '\s+'
if($LASTEXITCODE -ne 0 -or $hash[0] -ne 'fc64c65aca06186106a73ba93e65ddf7c906bf4905b786dc748d3f034401ea27') { throw 'SDK assembler pin mismatch' }
# A fresh verification directory preserves previous oracle artifacts.
$check=Join-Path $output ('check-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($check)
$wslCheck=(& wsl.exe --exec wslpath -a $check 2>$null | Select-Object -Last 1).Trim()
& wsl.exe --exec $assembler -triple=hexagon -mcpu=hexagonv73 "-mattr=+hvxv73,+hvx-length128b,+hvx-ieee-fp,+hmxv73" -filetype=obj "$wslOutput/probe-oracle.s" -o "$wslCheck/oracle.o" 2>$null
if($LASTEXITCODE -ne 0) { throw 'Independent assembly failed' }
# Read the ELF32 section table directly to extract .text, avoiding another tool dependency.
$object=[IO.File]::ReadAllBytes((Join-Path $check 'oracle.o'))
if($object.Length -lt 52 -or [BitConverter]::ToUInt32($object,0) -ne 0x464C457F -or $object[4] -ne 1 -or $object[5] -ne 1) { throw 'Oracle is not ELF32 little endian' }
$sectionOffset=[BitConverter]::ToUInt32($object,32)
$sectionSize=[BitConverter]::ToUInt16($object,46)
$sectionCount=[BitConverter]::ToUInt16($object,48)
$namesIndex=[BitConverter]::ToUInt16($object,50)
if($sectionSize -ne 40 -or $namesIndex -ge $sectionCount -or [long]$sectionOffset+[long]$sectionSize*$sectionCount -gt $object.Length) { throw 'Invalid oracle section table' }
$nameSection=[long]$sectionOffset+$namesIndex*$sectionSize
$namesOffset=[BitConverter]::ToUInt32($object,$nameSection+16)
$namesSize=[BitConverter]::ToUInt32($object,$nameSection+20)
if([long]$namesOffset+$namesSize -gt $object.Length) { throw 'Invalid oracle string table' }
$textBytes=$null
for($index=0;$index -lt $sectionCount;$index++) {
    $at=[long]$sectionOffset+$index*$sectionSize
    $nameAt=[long]$namesOffset+[BitConverter]::ToUInt32($object,$at)
    if($nameAt -ge [long]$namesOffset+$namesSize) { throw 'Invalid oracle section name' }
    $end=$nameAt
    while($end -lt [long]$namesOffset+$namesSize -and $object[$end] -ne 0) { $end++ }
    if($end -ge [long]$namesOffset+$namesSize) { throw 'Unterminated oracle section name' }
    $name=[Text.Encoding]::ASCII.GetString($object,$nameAt,$end-$nameAt)
    if($name -eq '.text') {
        if($null -ne $textBytes) { throw 'Duplicate oracle text section' }
        $offset=[BitConverter]::ToUInt32($object,$at+16); $size=[BitConverter]::ToUInt32($object,$at+20)
        if([long]$offset+$size -gt $object.Length) { throw 'Invalid oracle text section' }
        $textBytes=[byte[]]::new($size); [Array]::Copy($object,$offset,$textBytes,0,$size)
    }
}
if($null -eq $textBytes) { throw 'Oracle text section absent' }
$emitted=[IO.File]::ReadAllBytes((Join-Path $output 'emitted-code.bin'))
if($emitted.Length -ne $textBytes.Length) { throw 'Oracle code size mismatch' }
for($index=0;$index -lt $emitted.Length;$index++) {
    if($emitted[$index] -ne $textBytes[$index]) { throw "Oracle instruction mismatch at byte $index" }
}
. (Join-Path $PSScriptRoot '..\src\emit\Hexagon.ps1')
$rejections=0
$badOps = @(
    @{Op='imm';d=32;i=1},
    @{Op='imm';d=0;i=32768},
    @{Op='load';d=0;s=1;Offset=3},
    @{Op='hi';x=0;i=65536},
    @{Op='vload';d=32;s=0;Offset=0},
    @{Op='vload';d=0;s=0;Offset=127},
    @{Op='vload';d=0;s=0;i=8},
    @{Op='vstore';t=32;s=0;Offset=0},
    @{Op='vadd-sf';d=32;s=0;t=0},
    @{Op='valign';d=32;s=0;t=0;r=0},
    @{Op='valign';d=0;s=0;t=0;r=8},
    @{Op='valign-imm';d=0;s=0;t=0;i=8},
    @{Op='trap0';i=256}
)
foreach($bad in $badOps) {
    try { $null=New-HexagonInstruction $bad 0 0 } catch { $rejections++ }
}
if($rejections -ne $badOps.Count) { throw "Encoder accepted an invalid operand: got $rejections expected $($badOps.Count)" }
$summary=[ordered]@{LibrarySHA256=$result.SHA256;LibraryBytes=$result.Bytes;CodeBytes=$emitted.Length;AssemblerSHA256=$hash[0];InstructionBytesMatch=$true;InvalidOperandsRejected=$rejections;Imports=$result.Imports;Relocations=$result.Relocations}
$summary | ConvertTo-Json | Set-Content (Join-Path $check 'verification.json')
[pscustomobject]$summary
