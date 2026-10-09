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
                       src/jobs/Kokoro.AlbertLinear16Run.ps1.
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
    [ValidateSet('Status', 'Ratchet', 'Run', 'Emit', 'Check', 'Compare', 'JobInput', 'Capture', 'StockCapture', 'Albert', 'AlbertError', 'AlbertLinear', 'Api', 'Find', 'Tools')]
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

# Job input for one ALBERT linear (src/jobs/Kokoro.AlbertLinear16Run.ps1) from a capture: activations.bin (X, one LSB),
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

# One ALBERT linear on the phone, compared with the stock capture: build the job input, emit, run, decode, SNR.
function Test-KokoroAlbertLinear {
    param([Parameter(Mandatory)][string] $Linear, [string] $CaptureDirectory = (Join-Path $Build 'stock-albert-capture-hello'), [string] $Soc = 'SM8550', [int] $Runs = 3)
    Import-Evaluator
    $dir = Join-Path $Build "albert/linear-$Linear"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    $fx = New-KokoroAlbertLinearInput -CaptureDirectory $CaptureDirectory -Linear $Linear -OutputDirectory $dir
    $e = Invoke-KokoroEmission -Kernel KokoroAlbertLinear16Run -Parameters @{ AlbertInputChannels = $fx.Cin; AlbertOutputChannels = $fx.Cout; AlbertTokens = $fx.Tokens }
    $run = Invoke-KokoroDeviceJob -EmissionDirectory $e.Directory -InputDirectory $dir -Soc $Soc -Runs $Runs
    $layout = Get-Content (Join-Path $e.Directory 'runner-layout.json') -Raw | ConvertFrom-Json
    $tensor = [byte[]]::new($layout.OutputBytes - $layout.OutputOffset); [Array]::Copy($run.Output, $layout.OutputOffset, $tensor, 0, $tensor.Length)
    $y = ConvertFrom-KokoroCroutons16 -Bytes $tensor -Frames $fx.Tokens -Units ([double[]]$fx.Units)
    $expected = [float[]]::new($fx.Cout * $fx.Tokens); [Buffer]::BlockCopy([IO.File]::ReadAllBytes((Join-Path $dir 'expected-f32.bin')), 0, $expected, 0, 4 * $expected.Length)
    $saturated = 0; for ($i = 0; $i -lt $tensor.Length; $i += 2) { $u = $tensor[$i] -bor ([int]$tensor[$i + 1] -shl 8); if ($u -le 1 -or $u -ge 65535) { $saturated++ } }
    [pscustomobject]@{ Linear = $Linear; Shape = "$($fx.Cout) x $($fx.Cin)"; Tokens = $fx.Tokens; Soc = $Soc; SnrDb = Get-KokoroSnr $y $expected; MedianMs = $run.MedianMs
        Saturated = $saturated; Skel = $e.LibrarySHA256.Substring(0, 16); Emission = $e.Key; Input = $dir }
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
        foreach ($name in 'kokoro-v1_0.pth', 'config.json', "voices\$Voice.pt") {
            $pin = @($manifest.model.files | Where-Object path -CEQ $name); $file = Join-Path $inputRoot $name
            if ($pin.Count -ne 1 -or -not (Test-Path $file)) { throw "Missing pinned stock input $name (tools/Get-KokoroModelInput.ps1 fetches it)." }
            if ((Get-Item $file).Length -ne $pin[0].bytes -or (Get-FileHash $file).Hash -cne $pin[0].sha256) { throw "Stock input integrity mismatch: $name" }
            $inputs[$name] = @{ path = $file; sha256 = $pin[0].sha256 }
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
        $results = foreach ($name in ($Linear -split ',' | ForEach-Object Trim | Where-Object { $_ })) {
            $a = @{ Linear = $name; Soc = $Soc }; if ($Path) { $a.CaptureDirectory = $(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path }) }; if ($Runs) { $a.Runs = $Runs }
            $r = Test-KokoroAlbertLinear @a; Write-Host ('{0,-14} {1,-12} {2,7} dB  {3} ms  saturated {4}' -f $r.Linear, $r.Shape, $r.SnrDb, $r.MedianMs, $r.Saturated); $r }
        $results | Format-Table Linear, Shape, Tokens, Soc, SnrDb, MedianMs, Saturated, Skel -AutoSize | Out-String -Width 160
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
