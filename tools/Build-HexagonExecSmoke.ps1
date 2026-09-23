#requires -Version 7.4
# SDK-built diagnostic bootstrap only. The function under test is emitted by PowerShell.
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\exec-smoke'),
    [string] $SdkRoot = '/home/scott/hexagon/Hexagon_SDK/6.4.0.2'
)
$ErrorActionPreference='Stop'
$tool="$SdkRoot/tools/HEXAGON_Tools/19.0.04/Tools/bin/hexagon-clang"
$pins=@{
    $tool='e9117b76564e0c1d2cff53858201da5f88c47eabc8432f084f88f86c447221be'
    "$SdkRoot/incs/HAP_mem.h"='4056cff8017393cb4aef7e2ec07540f2466003ec74a66a53000d2562697d5eaf'
    "$SdkRoot/incs/remote.h"='f61e1f92c88dbc642d17df3855dd6ff9d5e605d442a5de73b8a7e023c225bc0d'
    "$SdkRoot/rtos/qurt/computev73/include/qurt/qurt_memory.h"='5d75bc9998a99edcf18de86bb7d6e37dfa908195c620488ecad33a10a75b1556'
}
foreach($path in $pins.Keys) {
    $hash=(& wsl.exe --exec sha256sum $path 2>$null | Select-Object -Last 1) -split '\s+'
    if($LASTEXITCODE -ne 0 -or $hash[0] -ne $pins[$path]) { throw "SDK source/tool pin mismatch: $path" }
}
$output=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
$so=Join-Path $output 'libkqnn_exec_skel.so'
if([IO.File]::Exists($so)) { throw 'Diagnostic output exists; choose a fresh output directory.' }
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\kernels\exec-smoke\exec_smoke.c'))
$wslSource=(& wsl.exe --exec wslpath -a $source 2>$null | Select-Object -Last 1).Trim()
$wslOutput=(& wsl.exe --exec wslpath -a $output 2>$null | Select-Object -Last 1).Trim()
& wsl.exe --exec $tool -mv73 -O2 -fPIC -G0 -shared -nostdlib -Wall -Wextra -Werror "-I$SdkRoot/incs" "-I$SdkRoot/incs/stddef" "-I$SdkRoot/rtos/qurt/computev73/include/qurt" '-Wl,-soname,libkqnn_exec_skel.so' $wslSource -o "$wslOutput/libkqnn_exec_skel.so"
if($LASTEXITCODE -ne 0) { throw 'Diagnostic bootstrap build failed' }
. (Join-Path $PSScriptRoot '..\src\emit\Hexagon.ps1')
$code=[byte[]]@((New-HexagonInstruction @{Op='imm';d=0;i=73} 0 0)+(New-HexagonInstruction @{Op='return'} 4 0))
[IO.File]::WriteAllBytes((Join-Path $output 'return73.bin'),$code)
$receipt=[ordered]@{
    BootstrapSHA256=(Get-FileHash $so).Hash
    TargetSHA256=(Get-FileHash (Join-Path $output 'return73.bin')).Hash
    SourceSHA256=(Get-FileHash $source).Hash
    CompilerSHA256=$pins[$tool]
}
$receipt | ConvertTo-Json | Set-Content (Join-Path $output 'build-receipt.json')
[pscustomobject]$receipt
