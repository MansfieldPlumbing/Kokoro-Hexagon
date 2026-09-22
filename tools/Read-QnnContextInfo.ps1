#requires -Version 7.4
# Graph and tensor metadata from a QNN context binary via QnnSystem (offsets: pinned QAIRT 2.46 Layouts.psd1).
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ContextPath,
    [Parameter(Mandatory)][string] $QnnSystem,   # QnnSystem library matching the QAIRT build (e.g. from onnxruntime-qnn)
    [string] $NativePs1 = (Join-Path $PSScriptRoot '..\..\QuickPS\src\Native.ps1')
)
$ErrorActionPreference = 'Stop'
$Native = & $NativePs1
$M = [Runtime.InteropServices.Marshal]
$u64 = [uint64]; $ptr = [IntPtr]

$lib = $Native.LoadLibrary($QnnSystem)
$getProviders = $Native.GetCall($Native.GetExport($lib, 'QnnSystemInterface_getProviders'), $u64, [Type[]]@($ptr, $ptr))
$listOut = $M::AllocHGlobal(8); $countOut = $M::AllocHGlobal(4)
$rc = $getProviders.Invoke($listOut, $countOut); if ($rc -ne 0) { throw "getProviders rc=$rc" }
$iface = $M::ReadIntPtr($M::ReadIntPtr($listOut))                    # first provider
$impl = [IntPtr]::Add($iface, 32)                                     # union v1_10
$fn = { param([int] $Offset) $M::ReadIntPtr($impl, $Offset) }
$create = $Native.GetCall((& $fn 0), $u64, [Type[]]@($ptr))
$getInfo = $Native.GetCall((& $fn 8), $u64, [Type[]]@($ptr, $ptr, $u64, $ptr, $ptr))
$free = $Native.GetCall((& $fn 24), $u64, [Type[]]@($ptr))

[byte[]] $bin = [IO.File]::ReadAllBytes($ContextPath)
$buf = $M::AllocHGlobal($bin.Length); $M::Copy($bin, 0, $buf, $bin.Length)
$hOut = $M::AllocHGlobal(8); $infoOut = $M::AllocHGlobal(8); $sizeOut = $M::AllocHGlobal(8)
try {
    $rc = $create.Invoke($hOut); if ($rc -ne 0) { throw "systemContextCreate rc=$rc" }
    $h = $M::ReadIntPtr($hOut)
    $rc = $getInfo.Invoke($h, $buf, [uint64]$bin.Length, $infoOut, $sizeOut); if ($rc -ne 0) { throw "getBinaryInfo rc=$rc" }
    $bi = $M::ReadIntPtr($infoOut); $ver = $M::ReadInt32($bi); $u = [IntPtr]::Add($bi, 8)
    $gOff = switch ($ver) { 1 { 112 } 2 { 112 } 3 { 88 } default { throw "BinaryInfo version $ver" } }
    $numGraphs = $M::ReadInt32($u, $gOff); $graphs = $M::ReadIntPtr($u, $gOff + 8)

    $readTensor = {
        param([IntPtr] $t)
        $tv = [IntPtr]::Add($t, 8)                                    # union v1/v2 share the leading fields
        $rank = $M::ReadInt32($tv, 72); $dp = $M::ReadIntPtr($tv, 80)
        [pscustomobject]@{
            Id       = [uint32]$M::ReadInt32($tv, 0)
            Name     = $M::PtrToStringUTF8($M::ReadIntPtr($tv, 8))
            Type     = $M::ReadInt32($tv, 16)
            DataType = '0x{0:X4}' -f $M::ReadInt32($tv, 24)
            Dims     = [uint32[]]@(for ($i = 0; $i -lt $rank; $i++) { [uint32]$M::ReadInt32($dp, 4 * $i) })
            Version  = $M::ReadInt32($t)
        }
    }
    for ($g = 0; $g -lt $numGraphs; $g++) {
        $gi = [IntPtr]::Add($graphs, 88 * $g); $gu = [IntPtr]::Add($gi, 8)
        $name = $M::PtrToStringUTF8($M::ReadIntPtr($gu, 0))
        $io = foreach ($pair in @(@('in', 8, 16), @('out', 24, 32))) {
            $n = $M::ReadInt32($gu, $pair[1]); $arr = $M::ReadIntPtr($gu, $pair[2])
            for ($i = 0; $i -lt $n; $i++) { $x = & $readTensor ([IntPtr]::Add($arr, 144 * $i)); $x | Add-Member NoteProperty Dir $pair[0]; $x }
        }
        [pscustomobject]@{ BinaryInfoVersion = $ver; GraphInfoVersion = $M::ReadInt32($gi); Graph = $name; Tensors = @($io) }
    }
    [void]$free.Invoke($h)
}
finally { foreach ($p in $buf, $hOut, $infoOut, $sizeOut, $listOut, $countOut) { $M::FreeHGlobal($p) } }
