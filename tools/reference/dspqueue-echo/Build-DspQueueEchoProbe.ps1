#requires -Version 7.4
# Diagnostic reference only. The product must emit Hexagon from PowerShell.
# Source: Kokoro-Hexagon commit 85b20cc80570c20c53d2ca1c43dc03a66aae08ae.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$SdkRoot = '/home/scott/hexagon/Hexagon_SDK/6.4.0.2'
)
$ErrorActionPreference = 'Stop'
$tool = "$SdkRoot/tools/HEXAGON_Tools/19.0.04/Tools/bin/hexagon-clang"
$pins = @{
    $tool = 'e9117b76564e0c1d2cff53858201da5f88c47eabc8432f084f88f86c447221be'
    "$SdkRoot/incs/dspqueue.h" = '416e548cc56aac1097819028c5f84646d71cedacadf22b6d04472db68c7a9091'
    "$SdkRoot/incs/remote.h" = 'f61e1f92c88dbc642d17df3855dd6ff9d5e605d442a5de73b8a7e023c225bc0d'
    "$SdkRoot/incs/stddef/AEEStdErr.h" = 'f211c27792cbcdd7ac0e80ff2786ac100af65b683eabcc3d75ab424ccfde0ef8'
}
foreach ($path in $pins.Keys) {
    $result = & wsl.exe --exec sha256sum $path 2>$null
    if ($LASTEXITCODE -ne 0 -or (($result -split '\s+')[0] -cne $pins[$path])) {
        throw "SDK source/tool pin mismatch: $path"
    }
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repo 'build'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Diagnostic build output must be inside this repository build/.'
}
[void][IO.Directory]::CreateDirectory($output)
$library = Join-Path $output 'libkokoro_queue_skel.so'
if ([IO.File]::Exists($library)) { throw 'Build output already exists; choose a fresh directory' }
$source = Join-Path $PSScriptRoot 'echo.c'
$wslSource = (& wsl.exe --exec wslpath -a $source 2>$null | Select-Object -Last 1).Trim()
$wslOutput = (& wsl.exe --exec wslpath -a $output 2>$null | Select-Object -Last 1).Trim()
& wsl.exe --exec $tool -mv73 -O2 -fPIC -G0 -shared -nostdlib -Wall -Wextra -Werror `
    "-I$SdkRoot/incs" "-I$SdkRoot/incs/stddef" '-Wl,-soname,libkokoro_queue_skel.so' `
    $wslSource -o "$wslOutput/libkokoro_queue_skel.so"
if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($library)) { throw 'DSP build failed' }
[pscustomobject]@{
    SourceSHA256 = (Get-FileHash $source).Hash
    LibraryBytes = (Get-Item $library).Length
    Built = $true
    DiagnosticOnly = $true
}
