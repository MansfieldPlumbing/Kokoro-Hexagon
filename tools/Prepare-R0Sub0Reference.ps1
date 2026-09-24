#requires -Version 7.4
# Pure PowerShell reference generator for Kokoro generator resblock 3 sub-iteration 0 (r0.0).
# Evaluates exact fp32 reference:
# Input x -> AdaIN1 -> Snake1 -> Conv1(d=1) -> AdaIN2 -> Snake2 -> Conv2(d=1) -> Residual Add (x + conv2).
# Conv1D inner loops are lowered via pure PowerShell Reflection.Emit for RyuJIT execution.
# Zero Python. Zero C# (no Add-Type). Zero C/C++ compiler toolchains.
using namespace System.Reflection.Emit

[CmdletBinding()]
param(
    [string]$InputDirectory = (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\candidates\c64\gen'),
    [string]$WeightDirectory = (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\emit\r0'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\r0sub0')
)
$ErrorActionPreference = 'Stop'

# 1. Synthesize typed RyuJIT Conv1D kernel via pure PowerShell Reflection.Emit
function New-RyuJitConv1dDelegate {
    $dm = [DynamicMethod]::new(
        "RyuJit_Conv1d_Kernel",
        [void],
        @([single[]], [single[]], [int], [single[]], [int], [single[]], [int], [int], [int]),
        [object]
    )
    $il = $dm.GetILGenerator()

    # void Kernel(float[] x, float[] w, int wOff, float[] b, int bOff, float[] out, int C, int T, int dil)
    # Args: 0: x, 1: w, 2: wOff, 3: b, 4: bOff, 5: out, 6: C, 7: T, 8: dil
    # Locals: 0: oc, 1: t, 2: k, 3: ic, 4: sum (double), 5: srcT, 6: wIdx, 7: ocOff
    $locOc    = $il.DeclareLocal([int])    # 0
    $locT     = $il.DeclareLocal([int])    # 1
    $locK     = $il.DeclareLocal([int])    # 2
    $locIc    = $il.DeclareLocal([int])    # 3
    $locSum   = $il.DeclareLocal([double]) # 4
    $locSrcT  = $il.DeclareLocal([int])    # 5
    $locWIdx  = $il.DeclareLocal([int])    # 6
    $locOcOff = $il.DeclareLocal([int])    # 7

    $lblLoopOcStart = $il.DefineLabel()
    $lblLoopOcEnd   = $il.DefineLabel()
    $lblLoopTStart  = $il.DefineLabel()
    $lblLoopTEnd    = $il.DefineLabel()
    $lblLoopKStart  = $il.DefineLabel()
    $lblLoopKEnd    = $il.DefineLabel()
    $lblLoopIcStart = $il.DefineLabel()
    $lblLoopIcEnd   = $il.DefineLabel()
    $lblSkipTap     = $il.DefineLabel()

    # oc = 0
    $il.Emit([OpCodes]::Ldc_I4_0)
    $il.Emit([OpCodes]::Stloc_0)

    $il.MarkLabel($lblLoopOcStart)
    $il.Emit([OpCodes]::Ldloc_0)
    $il.Emit([OpCodes]::Ldarg_S, [byte]6) # C
    $il.Emit([OpCodes]::Bge, $lblLoopOcEnd)

    # ocOff = oc * T
    $il.Emit([OpCodes]::Ldloc_0)
    $il.Emit([OpCodes]::Ldarg_S, [byte]7) # T
    $il.Emit([OpCodes]::Mul)
    $il.Emit([OpCodes]::Stloc, $locOcOff)

    # t = 0
    $il.Emit([OpCodes]::Ldc_I4_0)
    $il.Emit([OpCodes]::Stloc_1)

    $il.MarkLabel($lblLoopTStart)
    $il.Emit([OpCodes]::Ldloc_1)
    $il.Emit([OpCodes]::Ldarg_S, [byte]7) # T
    $il.Emit([OpCodes]::Bge, $lblLoopTEnd)

    # sum = 0.0
    $il.Emit([OpCodes]::Ldc_R8, [double]0.0)
    $il.Emit([OpCodes]::Stloc, $locSum)

    # k = 0
    $il.Emit([OpCodes]::Ldc_I4_0)
    $il.Emit([OpCodes]::Stloc_2)

    $il.MarkLabel($lblLoopKStart)
    $il.Emit([OpCodes]::Ldloc_2)
    $il.Emit([OpCodes]::Ldc_I4_3)
    $il.Emit([OpCodes]::Bge, $lblLoopKEnd)

    # srcT = t + (k - 1) * dil
    $il.Emit([OpCodes]::Ldloc_1) # t
    $il.Emit([OpCodes]::Ldloc_2) # k
    $il.Emit([OpCodes]::Ldc_I4_1)
    $il.Emit([OpCodes]::Sub)     # k - 1
    $il.Emit([OpCodes]::Ldarg_S, [byte]8) # dil
    $il.Emit([OpCodes]::Mul)
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Stloc, $locSrcT)

    # if (srcT < 0 || srcT >= T) skip tap
    $il.Emit([OpCodes]::Ldloc, $locSrcT)
    $il.Emit([OpCodes]::Ldc_I4_0)
    $il.Emit([OpCodes]::Blt, $lblSkipTap)
    $il.Emit([OpCodes]::Ldloc, $locSrcT)
    $il.Emit([OpCodes]::Ldarg_S, [byte]7) # T
    $il.Emit([OpCodes]::Bge, $lblSkipTap)

    # ic = 0
    $il.Emit([OpCodes]::Ldc_I4_0)
    $il.Emit([OpCodes]::Stloc_3)

    $il.MarkLabel($lblLoopIcStart)
    $il.Emit([OpCodes]::Ldloc_3)
    $il.Emit([OpCodes]::Ldarg_S, [byte]6) # C
    $il.Emit([OpCodes]::Bge, $lblLoopIcEnd)

    # wIdx = wOff + (k * C + ic) * C + oc
    $il.Emit([OpCodes]::Ldarg_2) # wOff
    $il.Emit([OpCodes]::Ldloc_2) # k
    $il.Emit([OpCodes]::Ldarg_S, [byte]6) # C
    $il.Emit([OpCodes]::Mul)
    $il.Emit([OpCodes]::Ldloc_3) # ic
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Ldarg_S, [byte]6) # C
    $il.Emit([OpCodes]::Mul)
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Ldloc_0) # oc
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Stloc, $locWIdx)

    # sum += (double)(x[ic * T + srcT] * w[wIdx])
    $il.Emit([OpCodes]::Ldarg_0) # x
    $il.Emit([OpCodes]::Ldloc_3) # ic
    $il.Emit([OpCodes]::Ldarg_S, [byte]7) # T
    $il.Emit([OpCodes]::Mul)
    $il.Emit([OpCodes]::Ldloc, $locSrcT)
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Ldelem_R4)

    $il.Emit([OpCodes]::Ldarg_1) # w
    $il.Emit([OpCodes]::Ldloc, $locWIdx)
    $il.Emit([OpCodes]::Ldelem_R4)

    $il.Emit([OpCodes]::Mul)
    $il.Emit([OpCodes]::Conv_R8)
    $il.Emit([OpCodes]::Ldloc, $locSum)
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Stloc, $locSum)

    # ic++
    $il.Emit([OpCodes]::Ldloc_3)
    $il.Emit([OpCodes]::Ldc_I4_1)
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Stloc_3)
    $il.Emit([OpCodes]::Br, $lblLoopIcStart)

    $il.MarkLabel($lblLoopIcEnd)
    $il.MarkLabel($lblSkipTap)
    # k++
    $il.Emit([OpCodes]::Ldloc_2)
    $il.Emit([OpCodes]::Ldc_I4_1)
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Stloc_2)
    $il.Emit([OpCodes]::Br, $lblLoopKStart)

    $il.MarkLabel($lblLoopKEnd)
    # out[ocOff + t] = (float)(sum + (double)b[bOff + oc])
    $il.Emit([OpCodes]::Ldarg_S, [byte]5) # out
    $il.Emit([OpCodes]::Ldloc, $locOcOff)
    $il.Emit([OpCodes]::Ldloc_1) # t
    $il.Emit([OpCodes]::Add)

    $il.Emit([OpCodes]::Ldloc, $locSum)
    $il.Emit([OpCodes]::Ldarg_3) # b
    $il.Emit([OpCodes]::Ldarg_S, [byte]4) # bOff
    $il.Emit([OpCodes]::Ldloc_0) # oc
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Ldelem_R4)
    $il.Emit([OpCodes]::Conv_R8)
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Conv_R4)
    $il.Emit([OpCodes]::Stelem_R4)

    # t++
    $il.Emit([OpCodes]::Ldloc_1)
    $il.Emit([OpCodes]::Ldc_I4_1)
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Stloc_1)
    $il.Emit([OpCodes]::Br, $lblLoopTStart)

    $il.MarkLabel($lblLoopTEnd)
    # oc++
    $il.Emit([OpCodes]::Ldloc_0)
    $il.Emit([OpCodes]::Ldc_I4_1)
    $il.Emit([OpCodes]::Add)
    $il.Emit([OpCodes]::Stloc_0)
    $il.Emit([OpCodes]::Br, $lblLoopOcStart)

    $il.MarkLabel($lblLoopOcEnd)
    $il.Emit([OpCodes]::Ret)

    return $dm.CreateDelegate([Action[single[], single[], int, single[], int, single[], int, int, int]])
}

Write-Host "Compiling Conv1D kernel via RyuJIT Reflection.Emit..."
$conv1dFn = New-RyuJitConv1dDelegate

# 2. Load Weights and Inputs
$manifest = Get-Content (Join-Path $WeightDirectory 'r0_static.json') -Raw | ConvertFrom-Json
$wb = [IO.File]::ReadAllBytes((Join-Path $WeightDirectory 'r0_static.bin'))
$hash = { param([byte[]]$b) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($b)) }

if ((& $hash $wb) -ne $manifest.Sha256) { throw 'Weight manifest hash mismatch' }

$xb = [IO.File]::ReadAllBytes((Join-Path $InputDirectory 'in_z.f32'))
$mb = [IO.File]::ReadAllBytes((Join-Path $InputDirectory 'in_mask1.f32'))

$TimeSteps = [int]($mb.Length / 4)
$C = 128
if ($xb.Length -ne $C * $TimeSteps * 4) { throw "Invalid input tensor size" }

$w = [single[]]::new($wb.Length / 4); [Buffer]::BlockCopy($wb, 0, $w, 0, $wb.Length)
$x = [single[]]::new($xb.Length / 4); [Buffer]::BlockCopy($xb, 0, $x, 0, $xb.Length)
$mask = [single[]]::new($TimeSteps); [Buffer]::BlockCopy($mb, 0, $mask, 0, $mb.Length)

[double]$maskSum = 0
for ($sampleIdx = 0; $sampleIdx -lt $TimeSteps; $sampleIdx++) { $maskSum += $mask[$sampleIdx] }
Write-Host "Input loaded: C=$C, TimeSteps=$TimeSteps, maskSum=$maskSum"

# 3. Helper: AdaIN + Snake
function Invoke-AdaINSnake {
    param(
        [single[]]$src,
        [int]$gainOff,
        [int]$shiftOff,
        [int]$alphaOff,
        [int]$ainvOff,
        [single[]]$dst
    )
    for ($c = 0; $c -lt $C; $c++) {
        $cOff = $c * $TimeSteps
        [double]$sum = 0
        for ($s = 0; $s -lt $TimeSteps; $s++) {
            $sum += [double]$src[$cOff + $s] * $mask[$s]
        }
        $mean = $sum / $maskSum

        [double]$sqSum = 0
        for ($s = 0; $s -lt $TimeSteps; $s++) {
            $d = ([double]$src[$cOff + $s] - $mean) * $mask[$s]
            $sqSum += $d * $d
        }
        [single]$rsqrtVal = [single](1.0 / [Math]::Sqrt($sqSum / $maskSum + 1e-5))

        [single]$gain  = $w[$gainOff + $c]
        [single]$shift = $w[$shiftOff + $c]
        [single]$alpha = $w[$alphaOff + $c]
        [single]$ainv  = $w[$ainvOff + $c]

        for ($s = 0; $s -lt $TimeSteps; $s++) {
            if ($mask[$s] -eq 0) {
                $dst[$cOff + $s] = 0.0f
                continue
            }
            [single]$normVal = [single](([double]$src[$cOff + $s] - $mean) * $rsqrtVal)
            [single]$affine = [single]([double]$normVal * [double]$gain + [double]$shift)

            # Snake: affine + ainv * sin(alpha * affine)^2
            [single]$u = [single]([double]$alpha * [double]$affine)
            [single]$sinVal = [MathF]::Sin($u)
            [single]$snake = [single]([double]$affine + [double]$ainv * [double]($sinVal * $sinVal))
            $dst[$cOff + $s] = $snake
        }
    }
}

# 4. Evaluate Sub-iteration 0
$act1 = [single[]]::new($x.Length)
$conv1 = [single[]]::new($x.Length)
$act2 = [single[]]::new($x.Length)
$conv2 = [single[]]::new($x.Length)
$out0 = [single[]]::new($x.Length)

Write-Host "Running Stage 1: AdaIN1 -> Snake1..."
Invoke-AdaINSnake `
    -src $x `
    -gainOff ($manifest.Values.'adain1.0.gain'.Offset / 4) `
    -shiftOff ($manifest.Values.'adain1.0.shift'.Offset / 4) `
    -alphaOff ($manifest.Values.'alpha1.0'.Offset / 4) `
    -ainvOff ($manifest.Values.'alpha1.0.inv'.Offset / 4) `
    -dst $act1

Write-Host "Running Stage 2: Conv1D (dilation=1)..."
$w1Off = $manifest.Values.'convs1.0.weight'.Offset / 4
$b1Off = $manifest.Values.'convs1.0.bias'.Offset / 4
$conv1dFn.Invoke($act1, $w, $w1Off, $w, $b1Off, $conv1, $C, $TimeSteps, 1)

Write-Host "Running Stage 3: AdaIN2 -> Snake2..."
Invoke-AdaINSnake `
    -src $conv1 `
    -gainOff ($manifest.Values.'adain2.0.gain'.Offset / 4) `
    -shiftOff ($manifest.Values.'adain2.0.shift'.Offset / 4) `
    -alphaOff ($manifest.Values.'alpha2.0'.Offset / 4) `
    -ainvOff ($manifest.Values.'alpha2.0.inv'.Offset / 4) `
    -dst $act2

Write-Host "Running Stage 4: Conv1D 2 (dilation=1)..."
$w2Off = $manifest.Values.'convs2.0.weight'.Offset / 4
$b2Off = $manifest.Values.'convs2.0.bias'.Offset / 4
$conv1dFn.Invoke($act2, $w, $w2Off, $w, $b2Off, $conv2, $C, $TimeSteps, 1)

Write-Host "Running Stage 5: Residual Add (x + conv2)..."
for ($i = 0; $i -lt $x.Length; $i++) {
    $out0[$i] = [single]([double]$x[$i] + [double]$conv2[$i])
}

# 5. Output Verification & Receipt
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$outBytes = [byte[]]::new($out0.Length * 4)
[Buffer]::BlockCopy($out0, 0, $outBytes, 0, $outBytes.Length)
$outSha = & $hash $outBytes

$refPath = Join-Path $OutputDirectory 'reference_sub0.f32'
[IO.File]::WriteAllBytes($refPath, $outBytes)
Write-Host "Saved sub-iteration 0 reference to: $refPath ($($outBytes.Length) bytes, SHA256: $outSha)"

$receipt = [ordered]@{
    Kernel = 'KokoroR0Sub0'
    Engine = 'PowerShell/SMA + RyuJIT Reflection.Emit'
    Channels = $C
    Frames = $TimeSteps
    Values = $out0.Length
    InputSHA256 = (& $hash $xb)
    WeightsSHA256 = $manifest.Sha256
    OutputSHA256 = $outSha
    File = 'reference_sub0.f32'
}
$receiptJson = $receipt | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'reference_sub0.json'), $receiptJson)
$receipt
