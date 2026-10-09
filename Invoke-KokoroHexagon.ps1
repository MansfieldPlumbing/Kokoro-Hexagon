#requires -Version 7.4
<#
.SYNOPSIS
The one entrypoint for Kokoro-Hexagon work: where the project stands, what to do next, and every routine operation.

.DESCRIPTION
Run it with no arguments first. It prints the commit, the next step from the newest handoff,
the ratchet cases and the commands below. Every recurring operation belongs here as a command. A step typed by hand
twice, or written as a scratch script, is a missing command: add it here.

  Status                      Project state, next step, cases, commands (default). Reads the repository only:
                              no adb, no phone, no network. Phone access is only in Run, Ratchet and Compare.
  Ratchet  [-Case]            Case-pair check, then every unblocked ratchet case on the phone; throws on regression.
  Run      -Case [-Hypothesis] [-Runs]
                              Emit the case's kernel, run it on the phone, print input hashes, receipt and result.
  Emit     -Case | -Kernel [-Parameters]
                              Emit a kernel (cached by source key) and print the library hash.
  Check    -Kernel [-Parameters]
                              Emit and check the bytes with the SDK assembler (Test-KokoroKernel).
  Compare  -Case -Setup [-Runs]
                              Run named setups of one case on the phone.
  JobInput -Reference -CaptureMap -OutputDirectory
                              Build a test case's job input from stock captures; prints which inputs match the reference.
  Capture  -Path [-Pattern]   List a stock capture's tensors: name, shape, bytes, hash prefix, and its capture spec.
  StockCapture [-Block albert|decoder|generator] [-Phonemes] [-Voice] [-Seed] [-OutputDirectory]
                              Run pinned stock PyTorch Kokoro on Windows (reference only) and record one block's tensors
                              under build/ with source, checkpoint and voice integrity checks.
  Albert   [-Path]            ALBERT stage map: stock modules (pinned source), checkpoint tensors, captures, DSP kernels.
  AlbertError -Path           Per ALBERT linear (12 repeats of q, k, v, dense, ffn, ffn_output, plus the 128->768 mapping
                              and bert_encoder): output SNR against the stock capture with int8 per-output-channel
                              weights (W8), 16-bit per-tensor activations (A16), both, and A8W8 for contrast.
  AlbertLinear -Linear name[,name...] [-Path] [-Soc] [-Runs]
                              One ALBERT linear (mapping_in, query.0 .. ffn_output.11, bert_encoder) on the phone: job input
                              from the capture, emit, run, decode, SNR against stock. Default capture stock-albert-capture-hello.
  AlbertLayerNorm -Norm name[,name...] [-Path] [-Soc] [-Runs]
                              One ALBERT LayerNorm (attention.0 .. attention.11, full.0 .. full.11) on the phone from the
                              captured input sum: SNR against stock, and against a host float LayerNorm of the stored input.
  AlbertGelu -Repeat r[,r...] [-Path] [-Soc] [-Runs]
                              gelu_new of repeat r (0..11) on the phone from the captured ffn output: SNR against stock and
                              against the host model of the table arithmetic (Invoke-KokoroGeluTable).
  AlbertAttention -Repeat r[,r...] [-Path] [-Soc] [-Runs]
                              The attention core of repeat r (q k^T / 8, softmax, p v; 12 heads) on the phone from the captured
                              q, k, v: SNR of the context against stock, and the A12K16 precision model.
  AlbertEmbed [-Path] [-Soc] [-Runs]
                              The ALBERT embeddings (token-id gather + position + type) and their LayerNorm on the phone from the
                              captured token ids, against the captured embeddings output.
  Api      [-Pattern]         Index of every function in this file, src/ and tools/*.psm1: name, file:line, parameters,
                              summary. Start here before reading source.
  Find     -Pattern           Search project source, docs and receipts (not build/).
  Tools                       The older scripts under tools/, grouped; to be absorbed into this file as they are used.

LIBRARY
  . ./Invoke-KokoroHexagon.ps1      loads every function below as an API without running a command (Api lists them).

ANATOMY OF A DSP JOB (read these, in this order, instead of exploring)
  1. Kernel bodies     src/kernels/*.ps1: New-Kokoro*Steps return step lists (one per HVX/HMX routine; the header comment
                       of each gives its registers and memory contract).
  2. Job               src/jobs/Kokoro.<Name>Run.ps1: Get-Kokoro<Name>Layout (VTCM regions, buffer sizes) and
                       New-Kokoro<Name>RunSteps (the checked resource wrapper copied from New-KokoroResBlockRunSteps up to
                       its connected_job label, then this job's DMA, calls and bodies). Smallest example:
                       src/jobs/Kokoro.Albert16Run.ps1 (New-KokoroWrappedJobSteps: src/jobs/Kokoro.WrappedJob.ps1).
  3. Emitter entry     tools/Emit-HexagonProbe.ps1: -Kernel <Name>, its parameters, runner-layout.json (the runner contract:
                       Tiles, InputBytes, OutputBytes, PcmOffset, Samples; Samples=1 = no playback).
  4. Emission          Invoke-KokoroEmission (tools/Kokoro.Evaluator.psm1), cached by source key under build/evaluator/emit.
  5. Job input         activations.bin, weights.bin, tables.bin built on Windows from stock captures with the packing API
                       here (ConvertTo-KokoroCroutons16, ConvertTo-KokoroIdentityTable, ConvertTo-KokoroConvPack).
  6. Phone run         Invoke-KokoroDeviceJob (tools/Invoke-GeneratorTailProbe.ps1 stages skel + inputs, returns the output).
  7. Compare           decode (ConvertFrom-KokoroCroutons16) and Get-KokoroSnr against the capture.

.EXAMPLE
pwsh -NoProfile -File ./Invoke-KokoroHexagon.ps1
pwsh -NoProfile -File ./Invoke-KokoroHexagon.ps1 AlbertLinear -Linear query.0
pwsh -NoProfile -File ./Invoke-KokoroHexagon.ps1 Api -Pattern 'Conv|Croutons'
pwsh -NoProfile -File ./Invoke-KokoroHexagon.ps1 Run -Case benchmark-0-sm8550 -Hypothesis 'layout slack'
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Status', 'Ratchet', 'Run', 'Emit', 'Check', 'Compare', 'JobInput', 'Capture', 'StockCapture', 'Albert', 'AlbertError', 'AlbertLinear', 'AlbertLayerNorm', 'AlbertGelu', 'AlbertAttention', 'AlbertEmbed', 'Api', 'Find', 'Tools')]
    [string] $Command = 'Status',
    [string] $Case,
    [string] $Kernel,
    [hashtable] $Parameters,
    [string[]] $Setup,
    [string] $Hypothesis,
    [int] $Runs,
    [string] $Reference,
    [hashtable] $CaptureMap,
    [string] $OutputDirectory,
    [string] $Path,
    [string] $Pattern,
    [ValidateSet('albert', 'decoder', 'generator')]
    [string] $Block = 'albert',
    [ValidateLength(1, 510)]
    [string] $Phonemes = 'həlˈoʊ wˈɜɹld.',
    [ValidateSet('af_heart', 'am_michael')]
    [string] $Voice = 'af_heart',
    [ValidateRange(1, 100)]
    [int] $Seed = 17,
    [string] $Linear,
    [string] $Norm,
    [string] $Repeat,
    [ValidateSet('SM8550', 'SM8635')]
    [string] $Soc = 'SM8550'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Build = Join-Path $Root 'build'
$Shared = [IO.Path]::GetFullPath((Join-Path $Root '../Pwsh-Development'))
$StockSource = 'C:/Dev/.vendor/kokoro'
$StockCommit = 'dfb907a02bba8152ca444717ca5d78747ccb4bec'   # lib/manifest.json kokoroSource.commit
# Python runs only stock PyTorch Kokoro, to record reference tensors (AGENTS.md).
$Python = 'C:/bin/micromamba/envs/mono/python.exe'

function Import-Evaluator { Import-Module (Join-Path $Root 'tools/Kokoro.Evaluator.psm1') -Force -Global }

function Get-Adb {
    foreach ($candidate in $env:KOKORO_QNN_ADB, (Get-Command adb -ErrorAction Ignore).Source, 'C:/backup/Android/platform-tools/adb.exe') {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    throw 'adb not found: set KOKORO_QNN_ADB or put adb on PATH.'
}

# Phone facts by SoC only; serials never leave this function.
function Get-Phone {
    $adb = Get-Adb
    $serials = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' } | ForEach-Object { ($_ -split '\t')[0] })
    foreach ($s in $serials) { [pscustomobject]@{ Soc = (& $adb -s $s shell getprop ro.soc.model).Trim(); Serial = $s } }
}

function Resume-Phone { $adb = Get-Adb; foreach ($p in Get-Phone) { & $adb -s $p.Serial shell input keyevent KEYCODE_WAKEUP | Out-Null } }

function Get-NextStep {
    $handoff = Get-ChildItem (Join-Path $Root 'docs') -Filter 'handoff-*.md' | Sort-Object Name | Select-Object -Last 1
    $lines = Get-Content $handoff.FullName
    $start = ($lines | Select-String -Pattern '^## Next' | Select-Object -First 1).LineNumber
    $steps = if ($start) { $lines[$start..($lines.Count - 1)] | Where-Object { $_ -match '^\d+\.\s' } | Select-Object -First 3 } else { @() }
    [pscustomobject]@{ Handoff = $handoff.Name; Steps = $steps }
}

function Show-InputHashes([string] $Directory) {
    foreach ($n in 'activations.bin', 'weights.bin', 'tables.bin', 'expected-pcm-f32.bin') {
        $f = Join-Path $Directory $n
        '  {0,-22} {1}' -f $n, $(if (Test-Path $f) { (Get-FileHash $f).Hash.Substring(0, 16) } else { 'missing' })
    }
}

function Import-CaptureKernels {
    Import-Module (Join-Path $Root 'tools/Kokoro.CaptureMath.psm1') -Force -Global
    Import-Module (Join-Path $Root 'tools/Kokoro.CaptureKernels.psm1') -Force -Global
}

function Get-Even([double] $x) { [math]::Round($x, [MidpointRounding]::ToEven) }

# ---- Packing API: host-side tensors for DSP jobs -------------------------------------------------------------------------
# Contracts shared by every 16-bit HMX conv job (decoder, generator, ALBERT):
#   stored tensor   biased u16 native croutons: halfword (t, c) at ((t >> 5) * (C >> 5) + (c >> 5)) * 1024
#                   + 64 * ((t & 31) >> 1) + 2 * (c & 31) + (t & 1); value = u16 - 32768 in the tensor's LSB per channel.
#   identity table  256 B per 32-channel block: K[32] (Q15 int32) at 0, M[32] = 0 at 128; window = K * x >> 15
#                   (New-KokoroAdaInLeaky16Steps -Identity), so the conv input LSB is s_c * 32768 / K_c.
#   conv weights    W8 per output channel in HMX order (New-KokoroHmxConvPlanesLoopSteps), Cout * Cin * K bytes.
#   conv tables     1024 B per 32-output block: four 256 B planes, each u32 (exponent << 10)[32] then int32 bias[32]
#                   (New-KokoroPlaneCombineLoopSteps -Mode Conv: output u16 biased, LSB unit_o = sW_o * 2^L_o).

# Biased u16 croutons of a [channel][frame] tensor with one LSB per channel; rows past Frames hold zero (0x8000).
function ConvertTo-KokoroCroutons16 {
    param([Parameter(Mandatory)][float[]] $Values, [Parameter(Mandatory)][int] $Frames, [Parameter(Mandatory)][double[]] $Scales)
    $channels = $Scales.Length; $tiles = [int][math]::Ceiling($Frames / 32)
    $bytes = [byte[]]::new($tiles * 64L * $channels)
    for ($i = 1; $i -lt $bytes.Length; $i += 2) { $bytes[$i] = 0x80 }
    (Get-QuantizeCroutons16Kernel).Invoke($Values, $Frames, $Scales, $bytes)
    , $bytes
}

# [channel][frame] float values of biased u16 croutons, times each channel's LSB unit.
function ConvertFrom-KokoroCroutons16 {
    param([Parameter(Mandatory)][byte[]] $Bytes, [Parameter(Mandatory)][int] $Frames, [Parameter(Mandatory)][double[]] $Units)
    $channels = $Units.Length; $v = [float[]]::new($channels * $Frames)
    (Get-DecodeCroutons16Kernel).Invoke($Bytes, $Frames, $channels, $v)
    for ($c = 0; $c -lt $channels; $c++) { for ($t = 0; $t -lt $Frames; $t++) { $v[$c * $Frames + $t] = [float]($v[$c * $Frames + $t] * $Units[$c]) } }
    , $v
}

# Identity table rescaling a stored tensor (LSB Scales[c]) into one conv-input LSB Common (> every scale).
function ConvertTo-KokoroIdentityTable {
    param([Parameter(Mandatory)][double[]] $Scales, [Parameter(Mandatory)][int] $Channels, [Parameter(Mandatory)][double] $Common)
    $bytes = [byte[]]::new(256L * $Channels / 32)
    for ($c = 0; $c -lt $Scales.Length; $c++) {
        $k = [long](Get-Even ($Scales[$c] / $Common * 32768)); if ($k -lt 1 -or $k -gt 32767) { throw "Identity K $k out of Q15 range at channel $c" }
        [BitConverter]::GetBytes([int]$k).CopyTo($bytes, 256 * [math]::Floor($c / 32) + 4 * ($c % 32))
    }
    , $bytes
}

# One conv (or linear: K = 1) packed for New-KokoroHmxConvPlanesLoopSteps + New-KokoroPlaneCombineLoopSteps -Mode Conv.
# The tools/New-KokoroDecoderFixture.ps1 Add-Conv contract: weights folded by the input LSB, W8 per output channel
# (sW = max |w| / 127), output LSB sW * 2^L with L the finest in 2..14 that holds Peak[o] * Margin in 16 bits.
# Weight: [o][i][k] float, CinReal real inputs padded to Cin. Returns Weights, Tables, Units (output LSB per channel).
function ConvertTo-KokoroConvPack {
    param([Parameter(Mandatory)][float[]] $Weight, [float[]] $Bias, [Parameter(Mandatory)][int] $Cout, [Parameter(Mandatory)][int] $CinReal,
        [Parameter(Mandatory)][int] $Cin, [int] $K = 1, [Parameter(Mandatory)][double[]] $InScale, [Parameter(Mandatory)][double[]] $Peak,
        [double] $Margin = 1.25)
    if ($Weight.Length -ne $Cout * $CinReal * $K) { throw "Weight has $($Weight.Length) values, expected $Cout x $CinReal x $K" }
    $fold = [float[]]::new($Cout * $Cin * $K); $wMax = [double[]]::new($Cout)
    (Get-FoldConvWeightsKernel).Invoke($Weight, $Cout, $CinReal, $Cin, $K, $InScale, $fold, $wMax)
    $sW = [double[]]::new($Cout); $Ls = [int[]]::new($Cout); $units = [double[]]::new($Cout); $coarse = 0
    for ($o = 0; $o -lt $Cout; $o++) {
        $nd = [math]::Max($Peak[$o] * $Margin / 32767, 1e-30)
        $sW[$o] = if ($wMax[$o] -gt 0) { $wMax[$o] / 127 } else { $nd / 16384 }
        $Lo = [math]::Max(2, [int][math]::Ceiling([math]::Log($nd / $sW[$o], 2)))
        if ($Lo -gt 14) { $Lo = 14; $sW[$o] = $nd / 16384; $coarse++ }
        $Ls[$o] = $Lo
    }
    $bytes = [long]$Cout * $Cin * $K
    $wh = [byte[]]::new($bytes); $wl = [byte[]]::new($bytes); $sumH = [long[]]::new($Cout); $sumL = [long[]]::new($Cout)
    if ((Get-PackWeightPlanesShapedKernel).Invoke($fold, $Cout, $Cin, $K, $sW, $wh, $wl, $sumH, $sumL) -ne 0) { throw 'Weight overflow' }
    foreach ($h in $sumH) { if ($h -ne 0) { throw 'W8 weights left a high plane' } }
    $tables = [byte[]]::new(1024L * $Cout / 32)
    for ($o = 0; $o -lt $Cout; $o++) {
        $Lo = $Ls[$o]; $units[$o] = $sW[$o] * [math]::Pow(2, $Lo)
        if ($Peak[$o] -gt 32767 * $units[$o]) { throw "Output ${o}: peak $($Peak[$o]) exceeds the 16-bit window ($(32767 * $units[$o]))" }
        $ob = [int][math]::Floor($o / 32); $cc = $o % 32
        $bq = if ($Bias) { [long](Get-Even ($Bias[$o] / $sW[$o])) } else { 0L }
        $lg = @(($Lo - 8), $Lo); $half = foreach ($x in $lg) { if ($x -ge 1) { [long][math]::Pow(2, $x - 1) } else { 0L } }
        $biasG = @((-128L * $sumL[$o] + [long][math]::Pow(2, $lg[0] + 15) + $half[0]), ($bq + [long][math]::Pow(2, $lg[1] + 15) + $half[1]))
        for ($pl = 0; $pl -lt 4; $pl++) {
            $g = $pl -shr 1; $e = $(if ($pl % 2) { 9 } else { 1 }) - $lg[$g] + 15
            if ($e -lt 1 -or $e -gt 30) { throw "Table exponent out of range at output $o" }
            $a = (4 * $ob + $pl) * 256
            [BitConverter]::GetBytes([uint32]($e -shl 10)).CopyTo($tables, $a + 4 * $cc)
            if ($biasG[$g] -lt [int]::MinValue -or $biasG[$g] -gt [int]::MaxValue) { throw "Bias overflow at output $o" }
            [BitConverter]::GetBytes([int]$biasG[$g]).CopyTo($tables, $a + 128 + 4 * $cc)
        }
    }
    [pscustomobject]@{ Weights = $wl; Tables = $tables; Units = $units; L = "$(($Ls | Measure-Object -Minimum).Minimum)..$(($Ls | Measure-Object -Maximum).Maximum)"; CoarsenedRows = $coarse }
}

function Get-KokoroSnr([float[]] $Values, [float[]] $Reference) {
    $s = 0.0; $n = 0.0; for ($i = 0; $i -lt $Values.Length; $i++) { $d = [double]$Values[$i] - $Reference[$i]; $s += [double]$Reference[$i] * $Reference[$i]; $n += $d * $d }
    if ($n -eq 0) { 999 } else { [math]::Round(10 * [math]::Log10($s / $n), 2) }
}

# ---- ALBERT -------------------------------------------------------------------------------------------------------------
# Every nn.Linear of stock ALBERT + bert_encoder by short name (mapping_in, query.0 .. ffn_output.11, bert_encoder): the
# capture's input tensor, parameter prefix, output tensor, and whether the output is stored [channel][token] (d_en).
function Get-KokoroAlbertLinear {
    param([string] $Name)
    $layer = 'bert.encoder.albert_layer_groups.0.albert_layers.0'
    $all = [Collections.Generic.List[object]]::new()
    $all.Add([pscustomobject]@{ Name = 'mapping_in'; Input = 'bert.embeddings.output'; Parameter = 'bert.encoder.embedding_hidden_mapping_in'; Output = 'bert.encoder.embedding_hidden_mapping_in.output'; ChannelMajor = $false })
    for ($r = 0; $r -lt 12; $r++) {
        foreach ($n in 'query', 'key', 'value') { $all.Add([pscustomobject]@{ Name = "$n.$r"; Input = "bert.layer.$r.input"; Parameter = "$layer.attention.$n"; Output = "bert.layer.$r.attention.$n.output"; ChannelMajor = $false }) }
        $all.Add([pscustomobject]@{ Name = "dense.$r"; Input = "bert.layer.$r.attention.dense.input"; Parameter = "$layer.attention.dense"; Output = "bert.layer.$r.attention.dense.output"; ChannelMajor = $false })
        $all.Add([pscustomobject]@{ Name = "ffn.$r"; Input = "bert.layer.$r.attention.LayerNorm.output"; Parameter = "$layer.ffn"; Output = "bert.layer.$r.ffn.output"; ChannelMajor = $false })
        $all.Add([pscustomobject]@{ Name = "ffn_output.$r"; Input = "bert.layer.$r.activation.output"; Parameter = "$layer.ffn_output"; Output = "bert.layer.$r.ffn_output.output"; ChannelMajor = $false })
    }
    $all.Add([pscustomobject]@{ Name = 'bert_encoder'; Input = 'bert_dur'; Parameter = 'bert_encoder'; Output = 'd_en'; ChannelMajor = $true })
    if (-not $Name) { return $all }
    $hit = $all | Where-Object Name -eq $Name
    if (-not $hit) { throw "No ALBERT linear '$Name' (mapping_in, query.0 .. ffn_output.11, bert_encoder)." }
    $hit
}

# One ALBERT linear from a capture as [channel][token] doubles: X (Cin x T), W (Cout x Cin), B, Y (captured, Cout x T).
function Read-KokoroAlbertLinear {
    param([Parameter(Mandatory)] $Capture, [Parameter(Mandatory)] $Linear)
    $xt = Read-KokoroCaptureTensor -Capture $Capture -Name $Linear.Input
    $w = Read-KokoroCaptureTensor -Capture $Capture -Name "$($Linear.Parameter).weight"
    $b = Read-KokoroCaptureTensor -Capture $Capture -Name "$($Linear.Parameter).bias"
    $y32 = Read-KokoroCaptureTensor -Capture $Capture -Name $Linear.Output
    $cout = $b.Length; $cin = $w.Length / $cout; $tokens = $xt.Length / $cin
    $x = [float[]]::new($xt.Length); for ($k = 0; $k -lt $tokens; $k++) { for ($i = 0; $i -lt $cin; $i++) { $x[$i * $tokens + $k] = $xt[$k * $cin + $i] } }
    [float[]] $y = if ($Linear.ChannelMajor) { $y32 } else { $v = [float[]]::new($y32.Length); for ($k = 0; $k -lt $tokens; $k++) { for ($o = 0; $o -lt $cout; $o++) { $v[$o * $tokens + $k] = $y32[$k * $cout + $o] } }; $v }
    [pscustomobject]@{ X = $x; W = $w; B = $b; Y = $y; Cin = $cin; Cout = $cout; Tokens = $tokens }
}

# Job input for one ALBERT linear (src/jobs/Kokoro.Albert16Run.ps1) from a capture: activations.bin (X, one LSB),
# weights.bin, tables.bin (identity then conv tables), expected-f32.bin (captured Y [channel][token]), fixture.json.
# Scales come from this capture (a kernel check, not a calibrated deployment).
function New-KokoroAlbertLinearInput {
    param([Parameter(Mandatory)][string] $CaptureDirectory, [Parameter(Mandatory)][string] $Linear, [Parameter(Mandatory)][string] $OutputDirectory, [double] $Margin = 1.25)
    Import-CaptureKernels
    $cap = Read-KokoroCapture -Directory $CaptureDirectory
    if ($cap.Json.block -ne 'albert') { throw 'Not an ALBERT capture (StockCapture -Block albert).' }
    $d = Read-KokoroAlbertLinear -Capture $cap -Linear (Get-KokoroAlbertLinear $Linear)
    $sIn = [math]::Max((Get-KokoroAbsMax -Values $d.X), 1e-12) * $Margin / 32767
    $inScales = [double[]]::new($d.Cin); [Array]::Fill($inScales, $sIn)
    $common = $sIn * 32768 / 32767
    $window = [double[]]::new($d.Cin); [Array]::Fill($window, $common)
    $peak = (Get-KokoroChannelStats -Values $d.Y -Channels $d.Cout).AbsMax
    $pack = ConvertTo-KokoroConvPack -Weight $d.W -Bias $d.B -Cout $d.Cout -CinReal $d.Cin -Cin $d.Cin -K 1 -InScale $window -Peak $peak -Margin $Margin
    $identity = ConvertTo-KokoroIdentityTable -Scales $inScales -Channels $d.Cin -Common $common
    $out = [IO.Path]::GetFullPath($OutputDirectory); [void][IO.Directory]::CreateDirectory($out)
    [IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), (ConvertTo-KokoroCroutons16 -Values $d.X -Frames $d.Tokens -Scales $inScales))
    [IO.File]::WriteAllBytes((Join-Path $out 'weights.bin'), $pack.Weights)
    [IO.File]::WriteAllBytes((Join-Path $out 'tables.bin'), [byte[]]($identity + $pack.Tables))
    $ybytes = [byte[]]::new(4 * $d.Y.Length); [Buffer]::BlockCopy($d.Y, 0, $ybytes, 0, $ybytes.Length); [IO.File]::WriteAllBytes((Join-Path $out 'expected-f32.bin'), $ybytes)
    $fixture = [ordered]@{ Linear = $Linear; Capture = [IO.Path]::GetFullPath($CaptureDirectory); Phonemes = $cap.Json.phonemes; Cin = $d.Cin; Cout = $d.Cout; Tokens = $d.Tokens
        InputLsb = $sIn; Margin = $Margin; L = $pack.L; CoarsenedRows = $pack.CoarsenedRows; Units = $pack.Units }
    $fixture | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
    [pscustomobject]$fixture
}

# Runs an emitted diagnostic job on the phone through tools/Invoke-GeneratorTailProbe.ps1. Returns the raw output buffer,
# the median DSP time and the receipt lines (serials are never printed).
function Invoke-KokoroDeviceJob {
    param([Parameter(Mandatory)][string] $EmissionDirectory, [Parameter(Mandatory)][string] $InputDirectory, [string] $Soc = 'SM8550', [int] $Runs = 3)
    Resume-Phone
    $out = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $Root 'tools/Invoke-GeneratorTailProbe.ps1') -EmissionDirectory $EmissionDirectory -FixtureDirectory $InputDirectory -Soc $Soc -Runs $Runs -TimeoutSeconds 300 2>&1
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    $field = { param([string] $n) if ($text -match "(?m)\b$n=(\S+)") { $Matches[1] } }
    $outputPath = & $field 'OutputPath'
    if (-not $outputPath) { throw "Phone run produced no output: $(($out | Select-Object -Last 4) -join ' | ')" }
    [pscustomobject]@{ Output = [IO.File]::ReadAllBytes($outputPath); OutputPath = $outputPath; MedianMs = [double](& $field 'MedianRegionMs')
        Lines = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match '^(Run=|Median|InvokeRc|Stage)' }) }
}

# Emits a diagnostic tensor job, runs it on the phone with a job input directory, and returns the output tensor bytes
# (from runner-layout.json OutputOffset), the count of halfwords at the int16 limits, DSP time and the skel identity.
function Invoke-KokoroTensorJob {
    param([Parameter(Mandatory)][string] $Kernel, [Parameter(Mandatory)][hashtable] $Parameters, [Parameter(Mandatory)][string] $InputDirectory, [string] $Soc = 'SM8550', [int] $Runs = 3)
    Import-Evaluator
    $e = Invoke-KokoroEmission -Kernel $Kernel -Parameters $Parameters
    $run = Invoke-KokoroDeviceJob -EmissionDirectory $e.Directory -InputDirectory $InputDirectory -Soc $Soc -Runs $Runs
    $layout = Get-Content (Join-Path $e.Directory 'runner-layout.json') -Raw | ConvertFrom-Json
    $tensor = [byte[]]::new($layout.OutputBytes - $layout.OutputOffset); [Array]::Copy($run.Output, $layout.OutputOffset, $tensor, 0, $tensor.Length)
    $saturated = 0; for ($i = 0; $i -lt $tensor.Length; $i += 2) { $u = $tensor[$i] -bor ([int]$tensor[$i + 1] -shl 8); if ($u -le 1 -or $u -ge 65535) { $saturated++ } }
    [pscustomobject]@{ Tensor = $tensor; Saturated = $saturated; MedianMs = $run.MedianMs; Skel = $e.LibrarySHA256.Substring(0, 16); Emission = $e.Key }
}

function Read-KokoroExpected([string] $Directory, [int] $Count) {
    $v = [float[]]::new($Count); [Buffer]::BlockCopy([IO.File]::ReadAllBytes((Join-Path $Directory 'expected-f32.bin')), 0, $v, 0, 4 * $Count); , $v
}

# A fresh job input directory under build/ (an existing one is replaced).
function New-KokoroInputDirectory([string] $Name) {
    $dir = Join-Path $Build $Name
    if (Test-Path $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $dir
}

# One ALBERT linear on the phone, compared with the stock capture: build the job input, emit, run, decode, SNR.
function Test-KokoroAlbertLinear {
    param([Parameter(Mandatory)][string] $Linear, [string] $CaptureDirectory = (Join-Path $Build 'stock-albert-capture-hello'), [string] $Soc = 'SM8550', [int] $Runs = 3)
    $dir = New-KokoroInputDirectory "albert/linear-$Linear"
    $fx = New-KokoroAlbertLinearInput -CaptureDirectory $CaptureDirectory -Linear $Linear -OutputDirectory $dir
    $r = Invoke-KokoroTensorJob -Kernel KokoroAlbertLinear16Run -Parameters @{ AlbertInputChannels = $fx.Cin; AlbertOutputChannels = $fx.Cout; AlbertTokens = $fx.Tokens } -InputDirectory $dir -Soc $Soc -Runs $Runs
    $y = ConvertFrom-KokoroCroutons16 -Bytes $r.Tensor -Frames $fx.Tokens -Units ([double[]]$fx.Units)
    [pscustomobject]@{ Linear = $Linear; Shape = "$($fx.Cout) x $($fx.Cin)"; Tokens = $fx.Tokens; Soc = $Soc; SnrDb = Get-KokoroSnr $y (Read-KokoroExpected $dir ($fx.Cout * $fx.Tokens))
        MedianMs = $r.MedianMs; Saturated = $r.Saturated; Skel = $r.Skel; Emission = $r.Emission; Input = $dir }
}

# LayerNorm constants for New-KokoroLayerNorm16Steps: per 32-channel block g[32] = round(gamma / sOut * 2^6) and
# B[32] = round(beta / sOut) (int32), then epsD = max(1, round(eps * C^2 / sIn^2)) (int64). sOut: output LSB per channel.
function ConvertTo-KokoroLayerNormTable {
    param([Parameter(Mandatory)][float[]] $Gamma, [Parameter(Mandatory)][float[]] $Beta, [Parameter(Mandatory)][double[]] $OutScales,
        [Parameter(Mandatory)][double] $InputLsb, [Parameter(Mandatory)][double] $Epsilon)
    $channels = $Gamma.Length; if ($channels % 32) { throw 'Channels must be whole 32-channel blocks' }
    $bytes = [byte[]]::new([long]([math]::Ceiling((256L * $channels / 32 + 8) / 128) * 128))
    for ($c = 0; $c -lt $channels; $c++) {
        $g = [long](Get-Even ($Gamma[$c] / $OutScales[$c] * 64)); $b = [long](Get-Even ($Beta[$c] / $OutScales[$c]))
        if ([math]::Abs($g) -ge 2147483647 -or [math]::Abs($b) -gt 32767) { throw "LayerNorm channel ${c}: g $g or B $b out of range" }
        $at = 256 * [math]::Floor($c / 32) + 4 * ($c % 32)
        [BitConverter]::GetBytes([int]$g).CopyTo($bytes, $at); [BitConverter]::GetBytes([int]$b).CopyTo($bytes, $at + 128)
    }
    $epsD = [long][math]::Max(1, (Get-Even ($Epsilon * $channels * $channels / ($InputLsb * $InputLsb))))
    [BitConverter]::GetBytes($epsD).CopyTo($bytes, 256 * $channels / 32)
    , $bytes
}

# gelu_new (transformers NewGELUActivation: 0.5 x (1 + tanh(sqrt(2 / pi) (x + 0.044715 x^3)))) as relu(x) + r(|x|), where
# r(a) = gelu_new(-a) = -a sigma(-a) is even, smooth and below 1e-7 past a = 5.5. Table: 257 ordinates of r on
# a = Range * k / 256 (k = 0..256), Q17 (|r| < 0.25), for 256-interval linear interpolation with an 8-bit fraction
# (the Kokoro.SnakeInteger.ps1 vlut16 lookup). Returns the ordinates as int[].
function New-KokoroGeluTable {
    param([double] $Range = 5.5)
    $c = [math]::Sqrt(2 / [math]::PI)
    , [int[]]@(for ($k = 0; $k -le 256; $k++) { $a = $Range * $k / 256; $x = -$a; [int](Get-Even (0.5 * $x * (1 + [math]::Tanh($c * ($x + 0.044715 * $x * $x * $x))) * 131072)) })
}

# The table GELU of 16-bit inputs, as the DSP kernel computes it: x = round(v / sIn); a = |x| sIn / Range in Q16, clamped
# to 65535; index a >> 8, fraction a & 255; r = T[i] + ((T[i + 1] - T[i]) f >> 8); y = max(x sIn, 0) + r / 2^17.
function Invoke-KokoroGeluTable {
    param([Parameter(Mandatory)][float[]] $Values, [Parameter(Mandatory)][double] $InputLsb, [double] $Range = 5.5)
    $T = New-KokoroGeluTable -Range $Range; $y = [float[]]::new($Values.Length)
    for ($i = 0; $i -lt $Values.Length; $i++) {
        $x = [math]::Max(-32767, [math]::Min(32767, [int](Get-Even ($Values[$i] / $InputLsb))))
        $a = [int][math]::Min(65535, [math]::Floor([math]::Abs($x) * $InputLsb / $Range * 65536))
        $k = $a -shr 8; $f = $a -band 255; $r = $T[$k] + ((($T[$k + 1] - $T[$k]) * $f) -shr 8)
        $y[$i] = [float]([math]::Max($x * $InputLsb, 0) + $r / 131072.0)
    }
    , $y
}


# A 256-entry vlut16 table as four 128-byte vectors (entry i in vector i >> 6 at halfword 2 (i mod 32) + (i mod 64) >> 5),
# the shuffled order Kokoro.SnakeInteger.ps1 and Kokoro.Gelu16.ps1 look up (V73 HVX PRM vlut16).
function ConvertTo-KokoroLut16Vectors {
    param([Parameter(Mandatory)][int[]] $Entries)
    if ($Entries.Count -lt 256) { throw 'A vlut16 table has 256 entries' }
    $bytes = [byte[]]::new(512)
    for ($i = 0; $i -lt 256; $i++) {
        $v = $Entries[$i]; if ($v -lt 0 -or $v -gt 65535) { throw "Table entry $i ($v) is not a u16" }
        $at = $i % 64; [BitConverter]::GetBytes([uint16]$v).CopyTo($bytes, 128 * [math]::Floor($i / 64) + 2 * (2 * ($at % 32) + [math]::Floor($at / 32)))
    }
    , $bytes
}

# Kokoro.Gelu16.ps1 constants: Ma, Ka, Kb (int32) at 0, 4, 8, then the negated Q17 table q = -r at 128 (640 bytes).
function ConvertTo-KokoroGeluConstants {
    param([Parameter(Mandatory)][double] $InputLsb, [Parameter(Mandatory)][double] $OutputLsb, [double] $Range = 5.5)
    $bytes = [byte[]]::new(640)
    $ma = [long](Get-Even ($InputLsb / $Range * 2147483648)); $ka = [long](Get-Even ($InputLsb / $OutputLsb * 32768)); $kb = [long](Get-Even (0.25 / $OutputLsb))
    foreach ($k in $ma, $ka, $kb) { if ($k -lt 1 -or $k -gt 2147483647) { throw "GELU constant $k out of range" } }
    [BitConverter]::GetBytes([int]$ma).CopyTo($bytes, 0); [BitConverter]::GetBytes([int]$ka).CopyTo($bytes, 4); [BitConverter]::GetBytes([int]$kb).CopyTo($bytes, 8)
    $q = [int[]]@((New-KokoroGeluTable -Range $Range) | ForEach-Object { -$_ })
    if ($q[0] -ne 0 -or $q[256] -ne 0) { throw 'The GELU table must start and end at 0 (index i + 1 wraps).' }
    (ConvertTo-KokoroLut16Vectors -Entries $q[0..255]).CopyTo($bytes, 128)
    , $bytes
}

# Job input for one ALBERT gelu_new (KokoroAlbertGelu16Run): the captured ffn output of repeat r as input (one LSB),
# expected = the captured activation output; output LSB per tensor from its peak.
function New-KokoroAlbertGeluInput {
    param([Parameter(Mandatory)][string] $CaptureDirectory, [Parameter(Mandatory)][int] $Repeat, [Parameter(Mandatory)][string] $OutputDirectory, [double] $Margin = 1.25)
    Import-CaptureKernels
    $cap = Read-KokoroCapture -Directory $CaptureDirectory
    if ($cap.Json.block -ne 'albert') { throw 'Not an ALBERT capture (StockCapture -Block albert).' }
    $xt = Read-KokoroCaptureTensor -Capture $cap -Name "bert.layer.$Repeat.ffn.output"; $yt = Read-KokoroCaptureTensor -Capture $cap -Name "bert.layer.$Repeat.activation.output"
    $channels = $cap.Json.tensors."bert.layer.$Repeat.ffn.output".shape[-1]; $tokens = $xt.Length / $channels
    $x = [float[]]::new($xt.Length); $y = [float[]]::new($xt.Length)
    for ($k = 0; $k -lt $tokens; $k++) { for ($c = 0; $c -lt $channels; $c++) { $x[$c * $tokens + $k] = $xt[$k * $channels + $c]; $y[$c * $tokens + $k] = $yt[$k * $channels + $c] } }
    $sIn = [math]::Max((Get-KokoroAbsMax -Values $x), 1e-12) * $Margin / 32767; $sOut = [math]::Max((Get-KokoroAbsMax -Values $y), 1e-12) * $Margin / 32767
    $inScales = [double[]]::new($channels); [Array]::Fill($inScales, $sIn)
    $out = [IO.Path]::GetFullPath($OutputDirectory); [void][IO.Directory]::CreateDirectory($out)
    [IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), (ConvertTo-KokoroCroutons16 -Values $x -Frames $tokens -Scales $inScales))
    [IO.File]::WriteAllBytes((Join-Path $out 'weights.bin'), [byte[]]::new(128))
    [IO.File]::WriteAllBytes((Join-Path $out 'tables.bin'), (ConvertTo-KokoroGeluConstants -InputLsb $sIn -OutputLsb $sOut))
    $ybytes = [byte[]]::new(4 * $y.Length); [Buffer]::BlockCopy($y, 0, $ybytes, 0, $ybytes.Length); [IO.File]::WriteAllBytes((Join-Path $out 'expected-f32.bin'), $ybytes)
    $fixture = [ordered]@{ Repeat = $Repeat; Capture = [IO.Path]::GetFullPath($CaptureDirectory); Channels = $channels; Tokens = $tokens; InputLsb = $sIn; OutputLsb = $sOut; Margin = $Margin }
    $fixture | ConvertTo-Json | Set-Content (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
    [pscustomobject]@{ Repeat = $Repeat; Channels = $channels; Tokens = $tokens; InputLsb = $sIn; OutputLsb = $sOut; X = $x }
}

# One ALBERT gelu_new on the phone against the stock capture, and against the host model of the kernel's table arithmetic.
function Test-KokoroAlbertGelu {
    param([Parameter(Mandatory)][int] $Repeat, [string] $CaptureDirectory = (Join-Path $Build 'stock-albert-capture-hello'), [string] $Soc = 'SM8550', [int] $Runs = 3)
    $dir = New-KokoroInputDirectory "albert/gelu-$Repeat"
    $fx = New-KokoroAlbertGeluInput -CaptureDirectory $CaptureDirectory -Repeat $Repeat -OutputDirectory $dir
    $expected = Read-KokoroExpected $dir ($fx.Channels * $fx.Tokens)
    $model = Invoke-KokoroGeluTable -Values $fx.X -InputLsb $fx.InputLsb
    $r = Invoke-KokoroTensorJob -Kernel KokoroAlbertGelu16Run -Parameters @{ AlbertInputChannels = $fx.Channels; AlbertTokens = $fx.Tokens } -InputDirectory $dir -Soc $Soc -Runs $Runs
    $units = [double[]]::new($fx.Channels); [Array]::Fill($units, $fx.OutputLsb)
    $y = ConvertFrom-KokoroCroutons16 -Bytes $r.Tensor -Frames $fx.Tokens -Units $units
    [pscustomobject]@{ Repeat = $Repeat; Channels = $fx.Channels; Tokens = $fx.Tokens; Soc = $Soc; SnrDb = Get-KokoroSnr $y $expected; ModelDb = Get-KokoroSnr $model $expected
        VsModelDb = Get-KokoroSnr $y $model; MedianMs = $r.MedianMs; Saturated = $r.Saturated; Skel = $r.Skel; Emission = $r.Emission; Input = $dir }
}
# Attention context of one ALBERT repeat from the captured q, k, v (12 heads of 64, scores / 8, softmax over keys, no
# mask for one unpadded sentence), against the captured context (attention.dense input). -Mode: Float (agreement check),
# A16K8 (q 16-bit per tensor, k int8 per key row, p 16-bit, v int8 per channel over keys: one HMX weight plane for K and
# V^T), A16K16 (k and v 16-bit per tensor: two weight planes), A12K16 (q 12-bit: int32 headroom for 64-term q.k sums).
# Returns dB SNR.
function Measure-KokoroAlbertAttention {
    param([Parameter(Mandatory)] $Capture, [Parameter(Mandatory)][int] $Repeat, [ValidateSet('Float', 'A16K8', 'A16K16', 'A12K16')][string] $Mode = 'Float')
    $tokens = $Capture.Json.tensors.'bert.input_ids'.shape[-1]; $heads = 12; $dim = 64; $width = 768
    $query = Read-KokoroCaptureTensor -Capture $Capture -Name "bert.layer.$Repeat.attention.query.output"
    $key = Read-KokoroCaptureTensor -Capture $Capture -Name "bert.layer.$Repeat.attention.key.output"
    $value = Read-KokoroCaptureTensor -Capture $Capture -Name "bert.layer.$Repeat.attention.value.output"
    $reference = Read-KokoroCaptureTensor -Capture $Capture -Name "bert.layer.$Repeat.attention.dense.input"
    $rowInt8 = { param([double[]] $row) $m = 0.0; foreach ($v in $row) { $m = [math]::Max($m, [math]::Abs($v)) }; if ($m -eq 0) { return , $row }; $lsb = $m / 127; , [double[]]@(foreach ($v in $row) { [math]::Round($v / $lsb) * $lsb }) }
    $int16 = { param([double[]] $row, [double] $peak) $lsb = $peak * 1.25 / 32767; , [double[]]@(foreach ($v in $row) { [math]::Round($v / $lsb) * $lsb }) }
    $qPeak = Get-KokoroAbsMax -Values $query; $kPeak = Get-KokoroAbsMax -Values $key; $vPeak = Get-KokoroAbsMax -Values $value
    $context = [float[]]::new($tokens * $width)
    for ($head = 0; $head -lt $heads; $head++) {
        $qRows = @(for ($i = 0; $i -lt $tokens; $i++) { , [double[]]@(for ($e = 0; $e -lt $dim; $e++) { $query[$i * $width + $head * $dim + $e] }) })
        $kRows = @(for ($j = 0; $j -lt $tokens; $j++) { , [double[]]@(for ($e = 0; $e -lt $dim; $e++) { $key[$j * $width + $head * $dim + $e] }) })
        $vColumns = @(for ($e = 0; $e -lt $dim; $e++) { , [double[]]@(for ($j = 0; $j -lt $tokens; $j++) { $value[$j * $width + $head * $dim + $e] }) })
        if ($Mode -in 'A16K8', 'A16K16') { $qRows = @(foreach ($row in $qRows) { , (& $int16 $row $qPeak) }) }
        if ($Mode -eq 'A12K16') { $qRows = @(foreach ($row in $qRows) { , (& $int16 $row ($qPeak * 16)) }) }
        if ($Mode -eq 'A16K8') { $kRows = @(foreach ($row in $kRows) { , (& $rowInt8 $row) }); $vColumns = @(foreach ($row in $vColumns) { , (& $rowInt8 $row) }) }
        if ($Mode -in 'A16K16', 'A12K16') { $kRows = @(foreach ($row in $kRows) { , (& $int16 $row $kPeak) }); $vColumns = @(foreach ($row in $vColumns) { , (& $int16 $row $vPeak) }) }
        for ($i = 0; $i -lt $tokens; $i++) {
            $scores = [double[]]@(for ($j = 0; $j -lt $tokens; $j++) { $acc = 0.0; for ($e = 0; $e -lt $dim; $e++) { $acc += $qRows[$i][$e] * $kRows[$j][$e] }; $acc / 8 })
            $top = ($scores | Measure-Object -Maximum).Maximum
            $weights = [double[]]@(foreach ($sc in $scores) { [math]::Exp($sc - $top) }); $total = ($weights | Measure-Object -Sum).Sum
            $probabilities = [double[]]@(foreach ($w in $weights) { if ($Mode -eq 'Float') { $w / $total } else { [math]::Round($w / $total * 32767) / 32767 } })
            for ($e = 0; $e -lt $dim; $e++) { $acc = 0.0; for ($j = 0; $j -lt $tokens; $j++) { $acc += $probabilities[$j] * $vColumns[$e][$j] }; $context[$i * $width + $head * $dim + $e] = [float]$acc }
        }
    }
    Get-KokoroSnr $context $reference
}


# New-KokoroScaleConvert16Steps constants (Kokoro.Decoder16.ps1): per 32-channel block 384 B, M[32] (Q31) at 0, shift
# 16 - e at 128, round 2^(15 - e) at 256, for x' = round(x Ratios[c]) with Ratios[c] = m 2^e, m < 1, e in 0..15.
function ConvertTo-KokoroScaleConvertTable {
    param([Parameter(Mandatory)][double[]] $Ratios)
    $bytes = [byte[]]::new(384L * $Ratios.Length / 32)
    for ($c = 0; $c -lt $Ratios.Length; $c++) {
        $e = 0; $m = $Ratios[$c]; while ($m -ge 1 -and $e -lt 15) { $m /= 2; $e++ }
        $q = [long](Get-Even ($m * 2147483648)); if ($q -ge 2147483648 -or $m -ge 1) { throw "Scale ratio $($Ratios[$c]) out of range at channel $c" }
        $at = 384 * [math]::Floor($c / 32) + 4 * ($c % 32)
        [BitConverter]::GetBytes([int]$q).CopyTo($bytes, $at); [BitConverter]::GetBytes([int](16 - $e)).CopyTo($bytes, $at + 128); [BitConverter]::GetBytes([int][math]::Pow(2, 15 - $e)).CopyTo($bytes, $at + 256)
    }
    , $bytes
}

# New-KokoroAttention16Steps constants: Ce[12] (Q31 multiplier of score differences into Q16 log2 units) at 0; Horner
# e1..e6 = ln(2)^k / k! in Q15 as halfword pairs at 128; per 32-key chunk the key mask (lanes j < Tokens) and its INT_MIN
# fill at 256 + 256 c. HeadLsb[h]: the score LSB U_h.
function ConvertTo-KokoroAttentionConstants {
    param([Parameter(Mandatory)][double[]] $HeadLsb, [Parameter(Mandatory)][int] $Tokens)
    $chunks = [int][math]::Ceiling($Tokens / 32); $bytes = [byte[]]::new(256L + 256L * $chunks)
    for ($h = 0; $h -lt $HeadLsb.Length; $h++) {
        $ce = [long](Get-Even ($HeadLsb[$h] / 8 * [math]::Log2([math]::E) * [math]::Pow(2, 47))); if ($ce -lt 1 -or $ce -ge 2147483648) { throw "Head ${h}: Ce $ce out of range" }
        [BitConverter]::GetBytes([int]$ce).CopyTo($bytes, 4 * $h)
    }
    $factorial = 1.0
    for ($k = 1; $k -le 6; $k++) { $factorial *= $k; $q = [int](Get-Even ([math]::Pow([math]::Log(2), $k) / $factorial * 32768)); [BitConverter]::GetBytes([int]($q -bor ($q -shl 16))).CopyTo($bytes, 128 + 4 * ($k - 1)) }
    for ($c = 0; $c -lt $chunks; $c++) {
        for ($lane = 0; $lane -lt 32; $lane++) {
            $real = (32 * $c + $lane) -lt $Tokens
            [BitConverter]::GetBytes($(if ($real) { [uint32]::MaxValue } else { [uint32]0 })).CopyTo($bytes, 256 + 256 * $c + 4 * $lane)
            [BitConverter]::GetBytes($(if ($real) { [uint32]0 } else { [uint32]2147483648 })).CopyTo($bytes, 256 + 256 * $c + 128 + 4 * $lane)
        }
    }
    , $bytes
}

# Job input for one ALBERT attention core (KokoroAlbertAttention16Run) from a capture: q, k, v of repeat r stored 16-bit with
# one LSB per channel (as the linears produce them), the k conversion to one LSB per head and the q conversion to q'_c with
# q'_c k'_c in one LSB U_h per head (|q'| <= 2047),
# expected = the captured context (attention.dense input); the context keeps v's LSB per channel.
function New-KokoroAlbertAttentionInput {
    param([Parameter(Mandatory)][string] $CaptureDirectory, [Parameter(Mandatory)][int] $Repeat, [Parameter(Mandatory)][string] $OutputDirectory, [double] $Margin = 1.25)
    Import-CaptureKernels
    $cap = Read-KokoroCapture -Directory $CaptureDirectory
    if ($cap.Json.block -ne 'albert') { throw 'Not an ALBERT capture (StockCapture -Block albert).' }
    $width = 768; $tokens = $cap.Json.tensors.'bert.input_ids'.shape[-1]
    $toChannelMajor = { param([float[]] $values) $o = [float[]]::new($values.Length); for ($tk = 0; $tk -lt $tokens; $tk++) { for ($ch = 0; $ch -lt $width; $ch++) { $o[$ch * $tokens + $tk] = $values[$tk * $width + $ch] } }; , $o }
    $q = & $toChannelMajor (Read-KokoroCaptureTensor -Capture $cap -Name "bert.layer.$Repeat.attention.query.output")
    $k = & $toChannelMajor (Read-KokoroCaptureTensor -Capture $cap -Name "bert.layer.$Repeat.attention.key.output")
    $v = & $toChannelMajor (Read-KokoroCaptureTensor -Capture $cap -Name "bert.layer.$Repeat.attention.value.output")
    $ctx = & $toChannelMajor (Read-KokoroCaptureTensor -Capture $cap -Name "bert.layer.$Repeat.attention.dense.input")
    $lsb = { param([float[]] $x) $peaks = (Get-KokoroChannelStats -Values $x -Channels $width).AbsMax; , [double[]]@(foreach ($pk in $peaks) { [math]::Max($pk, 1e-6) * $Margin / 32767 }) }
    $uq = & $lsb $q; $uk = & $lsb $k; $uv = & $lsb $v
    $qPeak = (Get-KokoroChannelStats -Values $q -Channels $width).AbsMax
    # k to one LSB per head (kRatios), then q' so that q'_c k'_c has one LSB U_h per head with |q'| <= 2047 (ratios).
    $kPeak = (Get-KokoroChannelStats -Values $k -Channels $width).AbsMax
    $headLsb = [double[]]::new(12); $ratios = [double[]]::new($width); $kRatios = [double[]]::new($width)
    for ($h = 0; $h -lt 12; $h++) {
        $km = 0.0; $qm = 0.0; for ($c = 64 * $h; $c -lt 64 * $h + 64; $c++) { $km = [math]::Max($km, $kPeak[$c]); $qm = [math]::Max($qm, $qPeak[$c]) }
        $headK = $km * $Margin / 32767; $headLsb[$h] = $qm * $Margin / 2047 * $headK
        for ($c = 64 * $h; $c -lt 64 * $h + 64; $c++) { $kRatios[$c] = $uk[$c] / $headK; $ratios[$c] = $uq[$c] * $headK / $headLsb[$h] }
    }
    $out = [IO.Path]::GetFullPath($OutputDirectory); [void][IO.Directory]::CreateDirectory($out)
    $tensors = foreach ($pair in @(@($q, $uq), @($k, $uk), @($v, $uv))) { , (ConvertTo-KokoroCroutons16 -Values $pair[0] -Frames $tokens -Scales $pair[1]) }
    $activations = [byte[]]::new(3 * $tensors[0].Length); for ($i = 0; $i -lt 3; $i++) { [Array]::Copy($tensors[$i], 0, $activations, $i * $tensors[0].Length, $tensors[0].Length) }
    [IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), $activations)
    [IO.File]::WriteAllBytes((Join-Path $out 'weights.bin'), [byte[]]::new(128))
    $convert = [byte[]]((ConvertTo-KokoroScaleConvertTable -Ratios $ratios) + (ConvertTo-KokoroScaleConvertTable -Ratios $kRatios)); $constants = ConvertTo-KokoroAttentionConstants -HeadLsb $headLsb -Tokens $tokens
    $tables = [byte[]]::new($convert.Length + $constants.Length); [Array]::Copy($convert, $tables, $convert.Length); [Array]::Copy($constants, 0, $tables, $convert.Length, $constants.Length)
    [IO.File]::WriteAllBytes((Join-Path $out 'tables.bin'), $tables)
    $ybytes = [byte[]]::new(4 * $ctx.Length); [Buffer]::BlockCopy($ctx, 0, $ybytes, 0, $ybytes.Length); [IO.File]::WriteAllBytes((Join-Path $out 'expected-f32.bin'), $ybytes)
    $fixture = [ordered]@{ Repeat = $Repeat; Capture = [IO.Path]::GetFullPath($CaptureDirectory); Tokens = $tokens; HeadLsb = $headLsb; Units = $uv; Margin = $Margin }
    $fixture | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
    [pscustomobject]$fixture
}

# One ALBERT attention core on the phone against the stock capture (and the A12K16 precision model for reference).
function Test-KokoroAlbertAttention {
    param([Parameter(Mandatory)][int] $Repeat, [string] $CaptureDirectory = (Join-Path $Build 'stock-albert-capture-hello'), [string] $Soc = 'SM8550', [int] $Runs = 3)
    $dir = New-KokoroInputDirectory "albert/attention-$Repeat"
    $fx = New-KokoroAlbertAttentionInput -CaptureDirectory $CaptureDirectory -Repeat $Repeat -OutputDirectory $dir
    $model = Measure-KokoroAlbertAttention -Capture (Read-KokoroCapture -Directory $CaptureDirectory) -Repeat $Repeat -Mode A12K16
    $r = Invoke-KokoroTensorJob -Kernel KokoroAlbertAttention16Run -Parameters @{ AlbertTokens = $fx.Tokens } -InputDirectory $dir -Soc $Soc -Runs $Runs
    $y = ConvertFrom-KokoroCroutons16 -Bytes $r.Tensor -Frames $fx.Tokens -Units ([double[]]$fx.Units)
    [pscustomobject]@{ Repeat = $Repeat; Tokens = $fx.Tokens; Soc = $Soc; SnrDb = Get-KokoroSnr $y (Read-KokoroExpected $dir (768 * $fx.Tokens)); ModelDb = $model
        MedianMs = $r.MedianMs; Saturated = $r.Saturated; Skel = $r.Skel; Emission = $r.Emission; Input = $dir }
}

# Word embedding rows gather-ready for New-KokoroEmbed16Steps: per id, C/32 vectors of 128 B, channel 32 b + j as a signed
# int16 (value / Lsb) in the even halfword of lane j, odd halfwords 0. Table: [Vocab][C] float.
function ConvertTo-KokoroEmbeddingRows {
    param([Parameter(Mandatory)][float[]] $Table, [Parameter(Mandatory)][int] $Channels, [Parameter(Mandatory)][double] $Lsb)
    $vocab = $Table.Length / $Channels; $bytes = [byte[]]::new(128L * ($Channels / 32) * $vocab)
    for ($id = 0; $id -lt $vocab; $id++) { for ($c = 0; $c -lt $Channels; $c++) {
        $q = [int](Get-Even ($Table[$id * $Channels + $c] / $Lsb)); if ([math]::Abs($q) -gt 32767) { throw "Embedding value out of range at id $id channel $c" }
        [BitConverter]::GetBytes([int16]$q).CopyTo($bytes, 128 * (($Channels / 32) * $id + [math]::Floor($c / 32)) + 4 * ($c % 32)) } }
    , $bytes
}

# Job input for the ALBERT embeddings + LayerNorm (KokoroAlbertEmbed16Run) from a capture: the captured token ids,
# word rows, position + token type 0 as signed croutons (one LSB for the sum), the embedding LayerNorm constants;
# expected = the captured embeddings output (after its LayerNorm).
function New-KokoroAlbertEmbedInput {
    param([Parameter(Mandatory)][string] $CaptureDirectory, [Parameter(Mandatory)][string] $OutputDirectory, [double] $Margin = 1.25)
    Import-CaptureKernels
    $cap = Read-KokoroCapture -Directory $CaptureDirectory
    if ($cap.Json.block -ne 'albert') { throw 'Not an ALBERT capture (StockCapture -Block albert).' }
    $idEntry = $cap.Json.tensors.'bert.input_ids'; $idBytes = [IO.File]::ReadAllBytes((Join-Path $cap.Root $idEntry.file))
    $tokens = $idBytes.Length / 4; $channels = 128
    $word = Read-KokoroCaptureTensor -Capture $cap -Name 'bert.embeddings.word_embeddings.weight'
    $position = Read-KokoroCaptureTensor -Capture $cap -Name 'bert.embeddings.position_embeddings.weight'
    $type = Read-KokoroCaptureTensor -Capture $cap -Name 'bert.embeddings.token_type_embeddings.weight'
    $gamma = Read-KokoroCaptureTensor -Capture $cap -Name 'bert.embeddings.LayerNorm.weight'; $beta = Read-KokoroCaptureTensor -Capture $cap -Name 'bert.embeddings.LayerNorm.bias'
    $yt = Read-KokoroCaptureTensor -Capture $cap -Name 'bert.embeddings.output'
    $posType = [float[]]::new($channels * $tokens); $sum = [float[]]::new($channels * $tokens); $y = [float[]]::new($channels * $tokens)
    for ($k = 0; $k -lt $tokens; $k++) { $id = [BitConverter]::ToInt32($idBytes, 4 * $k); for ($c = 0; $c -lt $channels; $c++) {
        $pt = $position[$k * $channels + $c] + $type[$c]; $posType[$c * $tokens + $k] = $pt; $sum[$c * $tokens + $k] = $pt + $word[$id * $channels + $c]; $y[$c * $tokens + $k] = $yt[$k * $channels + $c] } }
    $lsb = [math]::Max((Get-KokoroAbsMax -Values $word) + (Get-KokoroAbsMax -Values $posType), (Get-KokoroAbsMax -Values $sum)) * $Margin / 32767
    $scales = [double[]]::new($channels); [Array]::Fill($scales, $lsb)
    # posType as signed croutons: biased croutons with the bias removed (rows past T are then 0).
    $pt16 = ConvertTo-KokoroCroutons16 -Values $posType -Frames $tokens -Scales $scales; for ($i = 1; $i -lt $pt16.Length; $i += 2) { $pt16[$i] = $pt16[$i] -bxor 0x80 }
    $idsPadded = [byte[]]::new([math]::Ceiling(4 * $tokens / 128) * 128); [Array]::Copy($idBytes, $idsPadded, $idBytes.Length)
    $jobInput = [byte[]]::new($idsPadded.Length + $pt16.Length); [Array]::Copy($idsPadded, $jobInput, $idsPadded.Length); [Array]::Copy($pt16, 0, $jobInput, $idsPadded.Length, $pt16.Length)
    $peak = (Get-KokoroChannelStats -Values $y -Channels $channels).AbsMax
    $units = [double[]]@(foreach ($p in $peak) { [math]::Max($p, 1e-6) * $Margin / 32767 })
    $out = [IO.Path]::GetFullPath($OutputDirectory); [void][IO.Directory]::CreateDirectory($out)
    [IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), $jobInput)
    [IO.File]::WriteAllBytes((Join-Path $out 'weights.bin'), (ConvertTo-KokoroEmbeddingRows -Table $word -Channels $channels -Lsb $lsb))
    [IO.File]::WriteAllBytes((Join-Path $out 'tables.bin'), (ConvertTo-KokoroLayerNormTable -Gamma $gamma -Beta $beta -OutScales $units -InputLsb $lsb -Epsilon ([double]$cap.Json.layerNormEps)))
    $ybytes = [byte[]]::new(4 * $y.Length); [Buffer]::BlockCopy($y, 0, $ybytes, 0, $ybytes.Length); [IO.File]::WriteAllBytes((Join-Path $out 'expected-f32.bin'), $ybytes)
    $fixture = [ordered]@{ Capture = [IO.Path]::GetFullPath($CaptureDirectory); Tokens = $tokens; Vocab = $word.Length / $channels; SumLsb = $lsb; Margin = $Margin; Units = $units }
    $fixture | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
    [pscustomobject]$fixture
}

# The ALBERT embeddings + LayerNorm on the phone from the captured token ids, against the captured embeddings output.
function Test-KokoroAlbertEmbed {
    param([string] $CaptureDirectory = (Join-Path $Build 'stock-albert-capture-hello'), [string] $Soc = 'SM8550', [int] $Runs = 3)
    $dir = New-KokoroInputDirectory 'albert/embed'
    $fx = New-KokoroAlbertEmbedInput -CaptureDirectory $CaptureDirectory -OutputDirectory $dir
    $r = Invoke-KokoroTensorJob -Kernel KokoroAlbertEmbed16Run -Parameters @{ AlbertTokens = $fx.Tokens } -InputDirectory $dir -Soc $Soc -Runs $Runs
    $y = ConvertFrom-KokoroCroutons16 -Bytes $r.Tensor -Frames $fx.Tokens -Units ([double[]]$fx.Units)
    [pscustomobject]@{ Tokens = $fx.Tokens; Vocab = $fx.Vocab; Soc = $Soc; SnrDb = Get-KokoroSnr $y (Read-KokoroExpected $dir (128 * $fx.Tokens)); MedianMs = $r.MedianMs
        Saturated = $r.Saturated; Skel = $r.Skel; Emission = $r.Emission; Input = $dir }
}
# Every ALBERT LayerNorm after the embeddings, by short name: attention.<r> (input layer.r.input + attention.dense output)
# and full.<r> (input attention.LayerNorm output + ffn_output output), r = 0..11. Inputs are the stock sums.
function Get-KokoroAlbertLayerNorm {
    param([string] $Name)
    $layer = 'bert.encoder.albert_layer_groups.0.albert_layers.0'
    $all = for ($r = 0; $r -lt 12; $r++) {
        [pscustomobject]@{ Name = "attention.$r"; Inputs = @("bert.layer.$r.input", "bert.layer.$r.attention.dense.output"); Parameter = "$layer.attention.LayerNorm"; Output = "bert.layer.$r.attention.LayerNorm.output" }
        [pscustomobject]@{ Name = "full.$r"; Inputs = @("bert.layer.$r.attention.LayerNorm.output", "bert.layer.$r.ffn_output.output"); Parameter = "$layer.full_layer_layer_norm"; Output = "bert.layer.$r.output" }
    }
    if (-not $Name) { return $all }
    $hit = $all | Where-Object Name -eq $Name
    if (-not $hit) { throw "No ALBERT LayerNorm '$Name' (attention.0 .. attention.11, full.0 .. full.11)." }
    $hit
}

# Job input for one ALBERT LayerNorm (KokoroAlbertLayerNorm16Run) from a capture: activations.bin (the stock input sum, one
# LSB), weights.bin (unused), tables.bin, expected-f32.bin (captured output [channel][token]), fixture.json.
function New-KokoroAlbertLayerNormInput {
    param([Parameter(Mandatory)][string] $CaptureDirectory, [Parameter(Mandatory)][string] $Norm, [Parameter(Mandatory)][string] $OutputDirectory, [double] $Margin = 1.25)
    Import-CaptureKernels
    $cap = Read-KokoroCapture -Directory $CaptureDirectory
    if ($cap.Json.block -ne 'albert') { throw 'Not an ALBERT capture (StockCapture -Block albert).' }
    $n = Get-KokoroAlbertLayerNorm $Norm
    $a = Read-KokoroCaptureTensor -Capture $cap -Name $n.Inputs[0]; $b = Read-KokoroCaptureTensor -Capture $cap -Name $n.Inputs[1]
    $y32 = Read-KokoroCaptureTensor -Capture $cap -Name $n.Output
    $gamma = Read-KokoroCaptureTensor -Capture $cap -Name "$($n.Parameter).weight"; $beta = Read-KokoroCaptureTensor -Capture $cap -Name "$($n.Parameter).bias"
    $channels = $gamma.Length; $tokens = $a.Length / $channels
    $x = [float[]]::new($a.Length); $y = [float[]]::new($a.Length)
    for ($k = 0; $k -lt $tokens; $k++) { for ($c = 0; $c -lt $channels; $c++) { $x[$c * $tokens + $k] = $a[$k * $channels + $c] + $b[$k * $channels + $c]; $y[$c * $tokens + $k] = $y32[$k * $channels + $c] } }
    $sIn = [math]::Max((Get-KokoroAbsMax -Values $x), 1e-12) * $Margin / 32767
    $inScales = [double[]]::new($channels); [Array]::Fill($inScales, $sIn)
    $peak = (Get-KokoroChannelStats -Values $y -Channels $channels).AbsMax
    $outScales = [double[]]::new($channels); for ($c = 0; $c -lt $channels; $c++) { $outScales[$c] = [math]::Max($peak[$c], 1e-6) * $Margin / 32767 }
    $out = [IO.Path]::GetFullPath($OutputDirectory); [void][IO.Directory]::CreateDirectory($out)
    [IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), (ConvertTo-KokoroCroutons16 -Values $x -Frames $tokens -Scales $inScales))
    [IO.File]::WriteAllBytes((Join-Path $out 'weights.bin'), [byte[]]::new(128))
    [IO.File]::WriteAllBytes((Join-Path $out 'tables.bin'), (ConvertTo-KokoroLayerNormTable -Gamma $gamma -Beta $beta -OutScales $outScales -InputLsb $sIn -Epsilon ([double]$cap.Json.layerNormEps)))
    $ybytes = [byte[]]::new(4 * $y.Length); [Buffer]::BlockCopy($y, 0, $ybytes, 0, $ybytes.Length); [IO.File]::WriteAllBytes((Join-Path $out 'expected-f32.bin'), $ybytes)
    $fixture = [ordered]@{ Norm = $Norm; Capture = [IO.Path]::GetFullPath($CaptureDirectory); Phonemes = $cap.Json.phonemes; Channels = $channels; Tokens = $tokens
        InputLsb = $sIn; Epsilon = $cap.Json.layerNormEps; Margin = $Margin; Units = $outScales }
    $fixture | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
    [pscustomobject]$fixture
}

# One ALBERT LayerNorm on the phone against the stock capture. Also reports a host float LayerNorm of the stored
# (quantized) input, so input quantization and kernel arithmetic error are told apart.
function Test-KokoroAlbertLayerNorm {
    param([Parameter(Mandatory)][string] $Norm, [string] $CaptureDirectory = (Join-Path $Build 'stock-albert-capture-hello'), [string] $Soc = 'SM8550', [int] $Runs = 3)
    $dir = New-KokoroInputDirectory "albert/layernorm-$Norm"
    $fx = New-KokoroAlbertLayerNormInput -CaptureDirectory $CaptureDirectory -Norm $Norm -OutputDirectory $dir
    $channels = $fx.Channels; $T = $fx.Tokens; $expected = Read-KokoroExpected $dir ($channels * $T)
    $cap = Read-KokoroCapture -Directory $CaptureDirectory; $n = Get-KokoroAlbertLayerNorm $Norm
    $gamma = Read-KokoroCaptureTensor -Capture $cap -Name "$($n.Parameter).weight"; $beta = Read-KokoroCaptureTensor -Capture $cap -Name "$($n.Parameter).bias"
    $lsb = [double[]]::new($channels); [Array]::Fill($lsb, [double]$fx.InputLsb)
    $xq = ConvertFrom-KokoroCroutons16 -Bytes ([IO.File]::ReadAllBytes((Join-Path $dir 'activations.bin'))) -Frames $T -Units $lsb
    $hostA16 = [float[]]::new($channels * $T)
    for ($k = 0; $k -lt $T; $k++) {
        $m = 0.0; for ($c = 0; $c -lt $channels; $c++) { $m += $xq[$c * $T + $k] }; $m /= $channels
        $v = 0.0; for ($c = 0; $c -lt $channels; $c++) { $d = $xq[$c * $T + $k] - $m; $v += $d * $d }; $v /= $channels
        $inv = 1 / [math]::Sqrt($v + [double]$fx.Epsilon)
        for ($c = 0; $c -lt $channels; $c++) { $hostA16[$c * $T + $k] = [float](($xq[$c * $T + $k] - $m) * $inv * $gamma[$c] + $beta[$c]) }
    }
    $r = Invoke-KokoroTensorJob -Kernel KokoroAlbertLayerNorm16Run -Parameters @{ AlbertInputChannels = $channels; AlbertTokens = $T } -InputDirectory $dir -Soc $Soc -Runs $Runs
    $y = ConvertFrom-KokoroCroutons16 -Bytes $r.Tensor -Frames $T -Units ([double[]]$fx.Units)
    [pscustomobject]@{ Norm = $Norm; Channels = $channels; Tokens = $T; Soc = $Soc; SnrDb = Get-KokoroSnr $y $expected; HostA16Db = Get-KokoroSnr $hostA16 $expected
        VsHostA16Db = Get-KokoroSnr $y $hostA16; MedianMs = $r.MedianMs; Saturated = $r.Saturated; Skel = $r.Skel; Emission = $r.Emission; Input = $dir }
}

# ---- API index ----------------------------------------------------------------------------------------------------------
# Every function in this file, src/ and tools/*.psm1: name, file:line, parameters and its leading comment line.
function Get-KokoroApi {
    param([string] $Pattern)
    $files = @(Get-Item $PSCommandPath) + @(Get-ChildItem (Join-Path $Root 'src') -Recurse -Filter '*.ps1') + @(Get-ChildItem (Join-Path $Root 'tools') -Filter '*.psm1')
    foreach ($f in $files) {
        $lines = [IO.File]::ReadAllLines($f.FullName)
        $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $i = $fn.Extent.StartLineNumber - 2; $comment = $null
            while ($i -ge 0 -and $lines[$i].TrimStart().StartsWith('#') -and -not $lines[$i].TrimStart().StartsWith('# ----')) { $comment = $lines[$i].Trim().TrimStart('#').Trim(); $i-- }
            if (-not $comment) { $first = $fn.Body.Extent.Text -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() } | Select-Object -First 1; if ($first -and $first.Trim().StartsWith('#')) { $comment = $first.Trim().TrimStart('#').Trim() } }
            $params = @(if ($fn.Body.ParamBlock) { $fn.Body.ParamBlock.Parameters } elseif ($fn.Parameters) { $fn.Parameters }) | ForEach-Object { $_.Name.VariablePath.UserPath }
            $item = [pscustomobject]@{ Name = $fn.Name; Location = "$([IO.Path]::GetRelativePath($Root, $f.FullName)):$($fn.Extent.StartLineNumber)"; Parameters = $params -join ', '; Summary = $comment }
            if (-not $Pattern -or $item.Name -match $Pattern -or "$($item.Summary)" -match $Pattern -or $item.Location -match $Pattern) { $item }
        }
    }
}

# Dot-sourced (. ./Invoke-KokoroHexagon.ps1): the functions above are the API; no command runs.
if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Command) {
    'Status' {
        $head = git -C $Root log -1 --format='%h %s'
        $dirty = @(git -C $Root status --porcelain).Count
        "Kokoro-Hexagon  $head"
        "                $dirty uncommitted"
        $next = Get-NextStep
        "Next            ($($next.Handoff))"
        $next.Steps | ForEach-Object { "  $_" }
        'Ratchet cases'
        (Import-PowerShellDataFile (Join-Path $Root 'tools/Kokoro.Ratchet.psd1')).Cases | ForEach-Object {
            '  {0,-32} {1}' -f $_.Name, $(if ($_.Blocked) { 'blocked: ' + $_.Blocked.Substring(0, [Math]::Min(70, $_.Blocked.Length)) } else { $_.Kernel })
        }
        ''
        'Commands (Get-Help ./Invoke-KokoroHexagon.ps1 -Full):'
        '  Status Ratchet Run Emit Check Compare JobInput Capture Albert Find Tools'
        'Contract: AGENTS.md. Reference manuals: Find-Reference (Pwsh-Development/tools/SharedLibrary.psm1).'
    }
    'Ratchet' {
        Resume-Phone
        Import-Module (Join-Path $Shared 'tools/SharedLibrary.psm1')
        $ps = @(git -C $Root ls-files '*.ps1' '*.psm1') | ForEach-Object { Join-Path $Root $_ }
        "case pairs: $(Test-PowerShellCasePair -Path $ps -Quiet)"
        Import-Evaluator
        if ($Case) { Test-KokoroRatchet -Case $Case } else { Test-KokoroRatchet }
    }
    'Run' {
        if (-not $Case) { throw 'Run needs -Case (see Status for names).' }
        Resume-Phone; Import-Evaluator
        $c = Get-KokoroRatchetCase $Case
        'inputs:'; Show-InputHashes (Join-Path $Root $c.Input)
        $p = if ($Parameters) { $Parameters } else { $c.Parameters }
        $e = Invoke-KokoroEmission -Kernel $c.Kernel -Parameters $p
        "skel  $($e.LibrarySHA256)  (emission $($e.Key))"
        $a = @{ Case = $Case; Hypothesis = $(if ($Hypothesis) { $Hypothesis } else { "run $Case" }) }
        if ($Parameters) { $a.Parameters = $Parameters }
        if ($Runs) { $a.Runs = $Runs }
        $r = Invoke-KokoroExperiment @a
        $receipt = Get-ChildItem $e.Directory -Filter 'device-receipt-*.txt' | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($receipt) { 'device receipt:'; Get-Content $receipt.FullName | Where-Object { $_ -notmatch 'SHA256=' } | ForEach-Object { "  $_" } }
        "commit $(git -C $Root rev-parse --short HEAD)$(if (git -C $Root status --porcelain) { ' (uncommitted changes)' })"
        $r | Format-List Status, MedianMs, PcmSnrDb, Clipped, PcmSHA256, Wav, Reason
    }
    'Emit' {
        Import-Evaluator
        if ($Case) { $c = Get-KokoroRatchetCase $Case; $Kernel = $c.Kernel; if (-not $Parameters) { $Parameters = $c.Parameters } }
        if (-not $Kernel) { throw 'Emit needs -Case or -Kernel.' }
        $e = Invoke-KokoroEmission -Kernel $Kernel -Parameters $(if ($Parameters) { $Parameters } else { @{} })
        $e | Format-List Key, LibrarySHA256, Directory
    }
    'Check' {
        if (-not $Kernel) { throw 'Check needs -Kernel.' }
        Import-Evaluator
        Test-KokoroKernel -Kernel $Kernel -Parameters $(if ($Parameters) { $Parameters } else { @{} })
    }
    'Compare' {
        if (-not $Case -or -not $Setup) { throw 'Compare needs -Case and -Setup.' }
        Resume-Phone; Import-Evaluator
        $a = @{ Case = $Case; Setup = $Setup }; if ($Runs) { $a.Runs = $Runs }
        Compare-KokoroSetup @a
    }
    'JobInput' {
        if (-not $Reference -or -not $CaptureMap -or -not $OutputDirectory) { throw 'JobInput needs -Reference, -CaptureMap and -OutputDirectory.' }
        Import-Evaluator
        if (Test-Path $OutputDirectory) { Remove-Item $OutputDirectory -Recurse -Force }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $dir = New-KokoroJobInput -Reference $Reference -CaptureMap $CaptureMap -OutputDirectory $OutputDirectory
        'built in {0:N0} s -> {1}' -f $sw.Elapsed.TotalSeconds, $dir
        foreach ($n in 'weights.bin', 'tables.bin', 'activations.bin', 'expected-pcm-f32.bin') {
            $h1 = (Get-FileHash (Join-Path $Reference $n)).Hash; $h2 = (Get-FileHash (Join-Path $dir $n)).Hash
            '  {0,-22} reference {1}  new {2}  {3}' -f $n, $h1.Substring(0, 12), $h2.Substring(0, 12), $(if ($h1 -eq $h2) { 'same' } else { 'differs' })
        }
    }
    'Capture' {
        if (-not $Path) { throw 'Capture needs -Path (a capture directory under build/).' }
        $dir = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path }
        $spec = Join-Path $dir 'capture-spec.json'
        if (Test-Path $spec) { $s = Get-Content $spec -Raw | ConvertFrom-Json; "phonemes '$($s.phonemes)' ($("$($s.phonemes)".Length) characters)  voice $($s.voice)  seed $($s.seed)" }
        $j = Get-Content (Join-Path $dir 'capture.json') -Raw | ConvertFrom-Json
        foreach ($tensor in $j.tensors.PSObject.Properties) {
            if ($Pattern -and $tensor.Name -notmatch $Pattern) { continue }
            $f = Get-ChildItem $dir -Filter "$($tensor.Name).*" -File | Select-Object -First 1
            '  {0,-56} {1,-16} {2,12} {3}' -f $tensor.Name, ($tensor.Value.shape -join 'x'), $(if ($f) { $f.Length.ToString('N0') } else { 'missing' }), $(if ($f) { (Get-FileHash $f.FullName).Hash.Substring(0, 12) })
        }
    }
    'StockCapture' {
        $manifest = Get-Content (Join-Path $Root 'lib/manifest.json') -Raw | ConvertFrom-Json
        if ($manifest.kokoroSource.commit -cne $StockCommit) { throw 'Stock source pin differs from lib/manifest.json.' }
        $out = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $Build "stock-$Block-capture-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))" }
        if (-not $out.StartsWith($Build + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Captures go under build/.' }
        if (Test-Path $out) { throw "Use a new capture directory: $out exists." }
        [void][IO.Directory]::CreateDirectory($out)
        $archive = Join-Path $out 'stock-source.zip'
        git -C $StockSource archive --format=zip "--output=$archive" $StockCommit kokoro
        if ($LASTEXITCODE) { throw 'Pinned stock source archive failed.' }
        $sourceRoot = Join-Path $out 'source'
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $sourceRoot)
        $sourceFiles = foreach ($file in Get-ChildItem (Join-Path $sourceRoot 'kokoro') -File -Filter '*.py') {
            $relative = 'kokoro/' + $file.Name
            $blob = (git -C $StockSource rev-parse "${StockCommit}:$relative").Trim(); if ($LASTEXITCODE) { throw "No pinned blob for $relative." }
            $actual = (git hash-object --no-filters -- $file.FullName).Trim()
            if ($LASTEXITCODE -or $actual -cne $blob) { throw "Extracted $relative differs from the pinned Git blob." }
            @{ path = $relative; sha256 = (Get-FileHash $file.FullName).Hash; gitBlob = $blob }
        }
        $inputRoot = Join-Path $Build "inputs/kokoro/$($manifest.model.revision)"
        $inputs = @{}
        foreach ($inputName in 'kokoro-v1_0.pth', 'config.json', "voices\$Voice.pt") {
            $pin = @($manifest.model.files | Where-Object path -CEQ $inputName); $file = Join-Path $inputRoot $inputName
            if ($pin.Count -ne 1 -or -not (Test-Path $file)) { throw "Missing pinned stock input $inputName (tools/Get-KokoroModelInput.ps1 fetches it)." }
            if ((Get-Item $file).Length -ne $pin[0].bytes -or (Get-FileHash $file).Hash -cne $pin[0].sha256) { throw "Stock input integrity mismatch: $inputName" }
            $inputs[$inputName] = @{ path = $file; sha256 = $pin[0].sha256 }
        }
        $script = @{ albert = 'capture_stock_albert.py'; decoder = 'capture_stock_decoder.py'; generator = 'capture_stock_generator.py' }[$Block]
        $spec = @{ sourceCommit = $StockCommit; sourceRoot = $sourceRoot; sourceFiles = @($sourceFiles); inputs = $inputs; phonemes = $Phonemes; voice = $Voice
            seed = $Seed; block = @{ albert = 'albert'; decoder = 'decoder'; generator = 'decoder.generator' }[$Block]; output = $out; exportToolSha256 = (Get-FileHash $PSCommandPath).Hash }
        $specPath = Join-Path $out 'capture-spec.json'
        $spec | ConvertTo-Json -Depth 8 | Set-Content $specPath -Encoding utf8NoBOM
        & $Python -I (Join-Path $Root "tools/reference/$script") --spec $specPath
        if ($LASTEXITCODE -or -not (Test-Path (Join-Path $out 'capture.json'))) { throw "Stock $Block capture failed." }
        "capture: $out"
    }
    'Albert' {
        'Stock ALBERT (pinned source):'
        foreach ($f in 'kokoro/modules.py', 'kokoro/model.py') {
            Select-String (Join-Path $StockSource $f) -Pattern 'class CustomAlbert|AlbertModel|def forward_with_tokens|self\.bert|bert_encoder' |
                ForEach-Object { '  {0}:{1}: {2}' -f $f, $_.LineNumber, $_.Line.Trim() }
        }
        $config = Get-Content (Join-Path $Root 'lib/kokoro-v1_0.config.json') -Raw | ConvertFrom-Json -AsHashtable
        "plbert config: $($config['plbert'] | ConvertTo-Json -Compress)"
        'DSP kernels:'
        Get-ChildItem (Join-Path $Root 'src/kernels') -Filter 'Kokoro.Albert*.ps1' | ForEach-Object { '  src/kernels/' + $_.Name }
        'Captures with ALBERT tensors:'
        Get-ChildItem $Build -Filter capture.json -Recurse -Depth 3 -ErrorAction Ignore | ForEach-Object {
            $n = @((Get-Content $_.FullName -Raw | ConvertFrom-Json).tensors.PSObject.Properties.Name | Where-Object { $_ -match '^bert' })
            if ($n.Count) { '  {0}  ({1} bert tensors)' -f [IO.Path]::GetRelativePath($Build, $_.DirectoryName), $n.Count }
        }
    }
    'AlbertError' {
        if (-not $Path) { throw 'AlbertError needs -Path (an ALBERT capture from StockCapture -Block albert).' }
        Import-CaptureKernels
        $cap = Read-KokoroCapture -Directory $(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path })
        if ($cap.Json.block -ne 'albert') { throw 'Not an ALBERT capture.' }
        $conv = Get-Conv1dKernel; $rowsKernel = Get-QuantizeRowsKernel
        $double = { param([float[]] $v) $d = [double[]]::new($v.Length); [Array]::Copy($v, $d, $v.Length); , $d }
        $quantize = { param([double[]] $v, [int] $rows, [int] $levels)
            $clip = [double[]]::new($rows); [Array]::Fill($clip, 1.0); $q = [double[]]::new($v.Length); $e = [double[]]::new($rows)
            $rowsKernel.Invoke($v, $rows, $v.Length / $rows, $levels, $clip, $q, $e); , $q }
        $rows = foreach ($item in Get-KokoroAlbertLinear) {
            $d = Read-KokoroAlbertLinear -Capture $cap -Linear $item
            $x = & $double $d.X; $w = & $double $d.W; $ref = & $double $d.Y; $cout = $d.Cout; $cin = $d.Cin; $T = $d.Tokens
            $run = { param([double[]] $xx, [double[]] $ww) $y = [double[]]::new($cout * $T); $conv.Invoke($xx, $cin, $T, $ww, $cout, 1, 0, $y)
                for ($o = 0; $o -lt $cout; $o++) { for ($t0 = 0; $t0 -lt $T; $t0++) { $y[$o * $T + $t0] += $d.B[$o] } }; , [float[]]$y }
            $w8 = & $quantize $w $cout 127; $a16 = & $quantize $x 1 32767; $a8 = & $quantize $x 1 127
            [pscustomobject]@{ Linear = $item.Name; Shape = "$cout x $cin"; Stock = Get-KokoroSnr (& $run $x $w) $d.Y; W8 = Get-KokoroSnr (& $run $x $w8) $d.Y
                A16 = Get-KokoroSnr (& $run $a16 $w) $d.Y; A16W8 = Get-KokoroSnr (& $run $a16 $w8) $d.Y; A8W8 = Get-KokoroSnr (& $run $a8 $w8) $d.Y
                XAbsMax = [math]::Round((Get-KokoroAbsMax $d.X), 2) }
        }
        "capture '$($cap.Json.phonemes)'  tokens $($cap.Json.tensors.'bert.input_ids'.shape[-1])"
        'Stock = this float64 linear against the capture (agreement check); the rest are dB SNR against the capture.'
        $rows | Format-Table -AutoSize | Out-String -Width 160
        'Per linear, worst repeat:'
        $rows | Group-Object { $_.Linear -replace '\.\d+$', '' } | ForEach-Object {
            [pscustomobject]@{ Linear = $_.Name; W8 = ($_.Group.W8 | Measure-Object -Minimum).Minimum; A16W8 = ($_.Group.A16W8 | Measure-Object -Minimum).Minimum; A8W8 = ($_.Group.A8W8 | Measure-Object -Minimum).Minimum; XAbsMax = ($_.Group.XAbsMax | Measure-Object -Maximum).Maximum } } | Format-Table -AutoSize | Out-String -Width 160
    }
    'AlbertLinear' {
        if (-not $Linear) { throw 'AlbertLinear needs -Linear (mapping_in, query.0 .. ffn_output.11, bert_encoder).' }
        $results = foreach ($item in ($Linear -split ',' | ForEach-Object Trim | Where-Object { $_ })) {
            $a = @{ Linear = $item; Soc = $Soc }; if ($Path) { $a.CaptureDirectory = $(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path }) }; if ($Runs) { $a.Runs = $Runs }
            $r = Test-KokoroAlbertLinear @a; Write-Host ('{0,-14} {1,-12} {2,7} dB  {3} ms  saturated {4}' -f $r.Linear, $r.Shape, $r.SnrDb, $r.MedianMs, $r.Saturated); $r }
        $results | Format-Table Linear, Shape, Tokens, Soc, SnrDb, MedianMs, Saturated, Skel -AutoSize | Out-String -Width 160
    }
    'AlbertLayerNorm' {
        if (-not $Norm) { throw 'AlbertLayerNorm needs -Norm (attention.0 .. attention.11, full.0 .. full.11).' }
        $results = foreach ($item in ($Norm -split ',' | ForEach-Object Trim | Where-Object { $_ })) {
            $a = @{ Norm = $item; Soc = $Soc }; if ($Path) { $a.CaptureDirectory = $(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path }) }; if ($Runs) { $a.Runs = $Runs }
            $r = Test-KokoroAlbertLayerNorm @a; Write-Host ('{0,-14} {1,7} dB  host A16 {2,7} dB  vs host {3,7} dB  {4} ms  saturated {5}' -f $r.Norm, $r.SnrDb, $r.HostA16Db, $r.VsHostA16Db, $r.MedianMs, $r.Saturated); $r }
        $results | Format-Table Norm, Channels, Tokens, Soc, SnrDb, HostA16Db, VsHostA16Db, MedianMs, Saturated, Skel -AutoSize | Out-String -Width 180
    }
    'AlbertGelu' {
        if (-not $Repeat) { throw 'AlbertGelu needs -Repeat (0..11, comma list).' }
        $results = foreach ($item in ($Repeat -split ',' | ForEach-Object Trim | Where-Object { $_ })) {
            $a = @{ Repeat = [int]$item; Soc = $Soc }; if ($Path) { $a.CaptureDirectory = $(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path }) }; if ($Runs) { $a.Runs = $Runs }
            $r = Test-KokoroAlbertGelu @a; Write-Host ('gelu.{0,-9} {1,7} dB  model {2,7} dB  vs model {3,7} dB  {4} ms  saturated {5}' -f $r.Repeat, $r.SnrDb, $r.ModelDb, $r.VsModelDb, $r.MedianMs, $r.Saturated); $r }
        $results | Format-Table Repeat, Channels, Tokens, Soc, SnrDb, ModelDb, VsModelDb, MedianMs, Saturated, Skel -AutoSize | Out-String -Width 180
    }
    'AlbertAttention' {
        if (-not $Repeat) { throw 'AlbertAttention needs -Repeat (0..11, comma list).' }
        $results = foreach ($item in ($Repeat -split ',' | ForEach-Object Trim | Where-Object { $_ })) {
            $a = @{ Repeat = [int]$item; Soc = $Soc }; if ($Path) { $a.CaptureDirectory = $(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path }) }; if ($Runs) { $a.Runs = $Runs }
            $r = Test-KokoroAlbertAttention @a; Write-Host ('attention.{0,-5} {1,7} dB  model {2,7} dB  {3} ms  saturated {4}' -f $r.Repeat, $r.SnrDb, $r.ModelDb, $r.MedianMs, $r.Saturated); $r }
        $results | Format-Table Repeat, Tokens, Soc, SnrDb, ModelDb, MedianMs, Saturated, Skel -AutoSize | Out-String -Width 180
    }
    'AlbertEmbed' {
        $a = @{ Soc = $Soc }; if ($Path) { $a.CaptureDirectory = $(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path }) }; if ($Runs) { $a.Runs = $Runs }
        Test-KokoroAlbertEmbed @a | Format-List
    }
    'Api' { Get-KokoroApi -Pattern $Pattern | Format-Table -AutoSize -Wrap | Out-String -Width 220 }
    'Find' {
        if (-not $Pattern) { throw 'Find needs -Pattern.' }
        $files = @(git -C $Root ls-files) | Where-Object { $_ -match '\.(ps1|psm1|psd1|md|json|py)$' } | ForEach-Object { Join-Path $Root $_ }
        Select-String -Path $files -Pattern $Pattern | Select-Object -First 60 |
            ForEach-Object { '{0}:{1}: {2}' -f [IO.Path]::GetRelativePath($Root, $_.Path), $_.LineNumber, $_.Line.Trim().Substring(0, [Math]::Min(140, $_.Line.Trim().Length)) }
    }
    'Tools' {
        $groups = [ordered]@{
            'Test-case input builders (New-*Fixture)' = 'New-*Fixture.ps1'
            'Phone probes (Invoke-*)'                 = 'Invoke-*.ps1'
            'Checks (Test-*)'                         = 'Test-*.ps1'
            'Measurements (Measure-*)'                = 'Measure-*.ps1'
            'Inputs and build (Get-/Build-/Export-/Emit-/Read-/Split-)' = '[GBERS][eumxp]*-*.ps1'
        }
        $seen = @{}
        foreach ($g in $groups.Keys) {
            $g
            Get-ChildItem (Join-Path $Root 'tools') -Filter $groups[$g] | Where-Object { -not $seen[$_.Name] } | ForEach-Object { $seen[$_.Name] = 1; '  ' + $_.BaseName }
        }
        'Modules: tools/Kokoro.Evaluator.psm1 (used by Run/Ratchet/Emit/Check/Compare/JobInput), tools/Kokoro.CaptureMath.psm1, tools/Kokoro.CaptureKernels.psm1'
    }
}
