#Requires -Version 7.4
<# .SYNOPSIS
Quantizes and packs one real stock-captured convolution tile for the HMX runner.
.DESCRIPTION
PowerShell build-time packing only. Per-output-channel symmetric W8, shared
activation/output scales, and real halo rows preserve the selected tile's
convolution inputs. This fixture does not establish connected residual quality.
Layouts: src/emit/Kokoro.HmxConv.ps1. Column-table scaling research reference:
onnxsim 0dd9980a50045a5079b4fd6c30a21300725e0f3b hmx_qconv.h:1-25.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaptureDirectory,
    [ValidateRange(0,5)][int]$Stage = 0,
    [ValidateRange(1,64)][int]$Tiles = 8,
    [ValidateRange(0,200000)][int]$StartFrame = 256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(0,1000000)][double]$InputScale = 0,
    [ValidateRange(0,1000000)][double]$OutputScale = 0
)
$ErrorActionPreference = 'Stop'
$captureRoot = (Resolve-Path -LiteralPath $CaptureDirectory).Path
$buildRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build'))+[IO.Path]::DirectorySeparatorChar
$out=[IO.Path]::GetFullPath($OutputDirectory)
if (-not $captureRoot.StartsWith($buildRoot,[StringComparison]::OrdinalIgnoreCase) -or
    -not $out.StartsWith($buildRoot,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Use project build/ captures and a new fixture directory.' }
$capture = Get-Content -LiteralPath (Join-Path $captureRoot 'capture.json') -Raw | ConvertFrom-Json -AsHashtable
if ($capture.sourceCommit -cne 'dfb907a02bba8152ca444717ca5d78747ccb4bec' -or $capture.verifiedCheckpointTensors -le 0) { throw 'Verified stock capture required.' }
$read = {
    param([string]$Name)
    $entry = $capture.tensors[$Name]
    if (-not $entry -or $entry.file -notmatch '^[a-zA-Z0-9_.]+\.f32$') { throw 'Invalid capture tensor descriptor.' }
    if ($entry.bytes -le 0 -or $entry.bytes -gt 67108864 -or $entry.bytes % 4 -ne 0) { throw 'Capture tensor byte length is out of bounds.' }
    $path = Join-Path $captureRoot $entry.file
    if ((Get-Item -LiteralPath $path).Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $path).Hash -cne $entry.sha256) { throw 'Capture tensor integrity mismatch.' }
    $data = [IO.File]::ReadAllBytes($path)
    $values = [float[]]::new($data.Length / 4)
    [Buffer]::BlockCopy($data,0,$values,0,$data.Length)
    foreach ($value in $values) { if (-not [float]::IsFinite($value)) { throw 'Nonfinite tensor.' } }
    return ,$values
}
$shape = $capture.tensors["stage$Stage.snake"].shape
$weightShape = $capture.tensors["stage$Stage.weight"].shape
if ($shape.Count -ne 3 -or $shape[0] -ne 1 -or $shape[1] -ne 128 -or $weightShape.Count -ne 3 -or $weightShape[0] -ne 128 -or $weightShape[1] -ne 128 -or $weightShape[2] -notin 3,7,11) { throw 'Expected 128-channel stock generator block.' }
$kernel=[int]$weightShape[2]
$frames = [int]$shape[2]; $count = $Tiles * 32
if ($frames -lt 1 -or $frames -gt 32768 -or $StartFrame % 32 -ne 0 -or $StartFrame+$count -gt $frames) { throw 'Tile bounds or captured frame count differ.' }
$inputValues = & $read "stage$Stage.snake"
$weight = & $read "stage$Stage.weight"
$bias = & $read "stage$Stage.bias"
$reference = & $read "stage$Stage.conv"
if ($inputValues.Length -ne 128*$frames -or $reference.Length -ne $inputValues.Length -or $bias.Length -ne 128 -or $StartFrame % 32 -ne 0 -or $StartFrame+$count -gt $frames) { throw 'Tile bounds or tensor lengths differ.' }
$dilation = if ($Stage % 2 -eq 0) { @(1,3,5)[[int]($Stage/2)] } else { 1 }
$inputMax = 127*$InputScale; $outputMax = 127*$OutputScale
if ($InputScale -eq 0) { foreach ($value in $inputValues) { $inputMax = [math]::Max($inputMax,[math]::Abs([double]$value)) } }
if ($OutputScale -eq 0) { foreach ($value in $reference) { $outputMax = [math]::Max($outputMax,[math]::Abs([double]$value)) } }
if ($inputMax -eq 0 -or $outputMax -eq 0) { throw 'Zero-range capture requires explicit quantization handling.' }
$sx = $inputMax/127; $sy = $outputMax/127
if ($InputScale -gt 0) { $sx=$InputScale }
if ($OutputScale -gt 0) { $sy=$OutputScale }
$scales = [double[]]::new(128); $sums = [int[]]::new(128); $biasQ = [int[]]::new(128)
$quantWeights = [byte[]]::new($weight.Length)
for ($o=0; $o -lt 128; $o++) {
    $maximum=0.0
    for ($i=0; $i -lt 128; $i++) { for ($k=0; $k -lt $kernel; $k++) { $maximum=[math]::Max($maximum,[math]::Abs([double]$weight[($o*128+$i)*$kernel+$k])) } }
    if ($maximum -eq 0) { throw 'Zero weight channel requires explicit handling.' }
    $scales[$o]=$maximum/127
    for ($i=0; $i -lt 128; $i++) { for ($k=0; $k -lt $kernel; $k++) {
        $q=[int][math]::Round($weight[($o*128+$i)*$kernel+$k]/$scales[$o],[MidpointRounding]::ToEven)
        $quantWeights[($o*128+$i)*$kernel+$k]=[byte]($q -band 255); $sums[$o]+=$q
    } }
    $b=[math]::Round($bias[$o]/($sx*$scales[$o]),[MidpointRounding]::ToEven)
    if ($b -lt [int]::MinValue -or $b -gt [int]::MaxValue) { throw 'Quantized bias overflow.' }
    $biasQ[$o]=[int]$b
}
$act=[byte[]]::new(($Tiles+2)*4*2048); [Array]::Fill($act,[byte]128)
$qx=[byte[]]::new(128*($count+64))
for ($local=0; $local -lt $count+64; $local++) {
    $t=$StartFrame+$local-32
    for ($c=0; $c -lt 128; $c++) {
        $q=if ($t -lt 0 -or $t -ge $frames) { 0 } else { [int][math]::Round($inputValues[$c*$frames+$t]/$sx,[MidpointRounding]::ToEven) }
        $q=[math]::Clamp($q,-127,127)
        $qx[$c*($count+64)+$local]=[byte]($q -band 255)
        $idx=64*[int][math]::Floor(($local%32)/2)+2*($c%32)+($local%2)
        $at=([int][math]::Floor($local/32)*4+[int][math]::Floor($c/32))*2048+2*$idx+1
        $act[$at]=[byte]($q+128)
    }
}
$wp=[byte[]]::new(2*$kernel*4*2048)
for ($g=0; $g -lt 2; $g++) { for ($k=0; $k -lt $kernel; $k++) { for ($block=0; $block -lt 4; $block++) {
    $base=(($g*$kernel+$k)*4+$block)*2048
    for ($h=0; $h -lt 2; $h++) { for ($i=0; $i -lt 32; $i++) { for ($c=0; $c -lt 32; $c++) {
        $o=64*$g+32*$h+$c; $ic=32*$block+$i
        $wp[$base+1024*$h+128*[int][math]::Floor($i/4)+4*$c+$i%4]=$quantWeights[($o*128+$ic)*$kernel+$k]
    } } }
} } }
$tables=[byte[]]::new(4*256); $tableBias=[int[]]::new(128); $tableScale=[double[]]::new(128)
for ($o=0; $o -lt 128; $o++) {
    $m=$sx*$scales[$o]/$sy
    $half=[Half]::op_Explicit([float](512*$m))
    $bits=[BitConverter]::HalfToUInt16Bits($half)
    $tableScale[$o]=[double]$half/512
    if ($tableScale[$o] -le 0 -or -not [double]::IsFinite($tableScale[$o])) { throw 'Invalid HMX conversion scale.' }
    $b=$biasQ[$o]-128*$sums[$o]+[math]::Round(128/$tableScale[$o],[MidpointRounding]::ToEven)
    if ($b -lt [int]::MinValue -or $b -gt [int]::MaxValue) { throw 'Column-table bias overflow.' }
    $tableBias[$o]=[int]$b; $base=[int][math]::Floor($o/32)*256; $col=$o%32
    [BitConverter]::GetBytes([uint32]($bits -bor (1 -shl 22))).CopyTo($tables,$base+4*$col)
    [BitConverter]::GetBytes($tableBias[$o]).CopyTo($tables,$base+128+4*$col)
}
[void][IO.Directory]::CreateDirectory($out)
$files=@{ 'activations.bin'=$act; 'weights.bin'=$wp; 'tables.bin'=$tables; 'input.s8'=$qx; 'weight.s8'=$quantWeights; 'expected.bin'=[byte[]]::new($Tiles*4*2048) }
foreach ($name in $files.Keys) { [IO.File]::WriteAllBytes((Join-Path $out $name),$files[$name]) }
$spec=@{ schema=1; capture=$captureRoot; stage=$Stage; channels=128; kernel=$kernel; dilation=$dilation; startFrame=$StartFrame; frames=$count; tiles=$Tiles; inputScale=$sx; outputScale=$sy; weightScales=$scales; biasQuantized=$biasQ; columnBias=$tableBias; columnScale=$tableScale; rounding='HMX table bit 22'; captureSha256=(Get-FileHash -LiteralPath (Join-Path $captureRoot 'capture.json')).Hash }
$spec | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory=$out; Stage=$Stage; Dilation=$dilation; Tiles=$Tiles; Frames=$count; InputScale=$sx; OutputScale=$sy }
