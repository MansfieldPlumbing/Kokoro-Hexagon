#requires -Version 7.4
<# .SYNOPSIS
Per-layer output error of the stock decoder's convs with 8-bit and 4-bit per-output-channel weights, on the captured inputs.
.DESCRIPTION
For each Conv1d / ConvTranspose1d of the stock decoder (tools/reference/capture_stock_decoder.py capture), the captured input
goes through the conv with the stock weights and with quantized weights (activations unquantized), and the output SNR is
reported: W8 (symmetric, absmax / 127 per output channel), W4 (absmax / 7) and W4c (per channel, the clip c * absmax / 7,
c in 0.70 .. 1.00, with the least weight squared error). Decides which decoder layers can take 4-bit weights (W4A8 per layer
where the error allows, AGENTS.md). Stride-2 and transposed convs are skipped (not Conv1d stride 1).
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CaptureDirectory)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureMath.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
$cap = Read-KokoroCapture -Directory $CaptureDirectory
$read = { param([string]$tensor) , (Read-KokoroCaptureTensor -Capture $cap -Name $tensor) }
$quant = { param([double[]]$w, [int]$cout, [int]$per, [int]$levels, [bool]$search)
    $kernel = Get-QuantizeRowsKernel; $q = [double[]]::new($w.Length); $err = [double[]]::new($cout)
    $best = [double[]]::new($cout); $bestErr = [double[]]::new($cout); [Array]::Fill($bestErr, [double]::MaxValue)
    foreach ($c in $(if ($search) { 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 1.00 } else { , 1.00 })) {
        $clip = [double[]]::new($cout); [Array]::Fill($clip, [double]$c); $kernel.Invoke($w, $cout, $per, $levels, $clip, $q, $err)
        for ($o = 0; $o -lt $cout; $o++) { if ($err[$o] -lt $bestErr[$o]) { $bestErr[$o] = $err[$o]; $best[$o] = $c } }
    }
    $kernel.Invoke($w, $cout, $per, $levels, $best, $q, $err)
    , $q }
$rows = foreach ($name in $cap.Json.moduleContracts.Keys | Sort-Object) {
    $contract = $cap.Json.moduleContracts.$name
    if ($contract.type -ne 'Conv1d' -or $contract.stride[0] -ne 1 -or $contract.groups -ne 1) { continue }
    $key = "decoder.$name"
    $w32 = & $read "$key.weight"; $x32 = & $read "$key.input.0"
    $cout = [int]$contract.out_channels; $cin = [int]$contract.in_channels; $K = [int]$contract.kernel_size[0]; $frames = $x32.Length / $cin
    $x = [double[]]::new($x32.Length); for ($i = 0; $i -lt $x.Length; $i++) { $x[$i] = $x32[$i] }
    $w = [double[]]::new($w32.Length); for ($i = 0; $i -lt $w.Length; $i++) { $w[$i] = $w32[$i] }
    $ref = [double[]]::new($cout * $frames); (Get-Conv1dKernel).Invoke($x, $cin, $frames, $w, $cout, $K, -[int][math]::Floor($K / 2), $ref)
    $sig = 0.0; foreach ($v in $ref) { $sig += $v * $v }
    $snr = [ordered]@{}
    foreach ($m in @(@('W8', 127, $false), @('W4', 7, $false), @('W4c', 7, $true))) {
        $wq = & $quant $w $cout ($cin * $K) $m[1] $m[2]
        $y = [double[]]::new($cout * $frames); (Get-Conv1dKernel).Invoke($x, $cin, $frames, $wq, $cout, $K, -[int][math]::Floor($K / 2), $y)
        $err = 0.0; for ($i = 0; $i -lt $y.Length; $i++) { $err += ($y[$i] - $ref[$i]) * ($y[$i] - $ref[$i]) }
        $snr[$m[0]] = [math]::Round(10 * [math]::Log10($sig / $err), 2)
    }
    [pscustomobject]@{ Layer = $name; Shape = "$cout x $cin x $K"; Frames = $frames; Params = $w.Length; W8 = $snr.W8; W4 = $snr.W4; W4c = $snr.W4c }
}
$rows | Format-Table -AutoSize | Out-String -Width 160
"Parameters: {0:N0}" -f ($rows | Measure-Object Params -Sum).Sum
