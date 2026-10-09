#requires -Version 7.4
<#
.SYNOPSIS
The one entrypoint for Kokoro-Hexagon work: where the project stands, what to do next, and every routine operation.

.DESCRIPTION
Run it with no arguments first. It prints the commit, the attached phone, the next step from the newest handoff,
the ratchet cases and the commands below. Every recurring operation belongs here as a command. A step typed by hand
twice, or written as a scratch script, is a missing command: add it here.

  Status                      Project state, next step, phone, cases, commands (default).
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
  Find     -Pattern           Search project source, docs and receipts (not build/).
  Tools                       The older scripts under tools/, grouped; to be absorbed into this file as they are used.

.EXAMPLE
pwsh -NoProfile -File ./Invoke-KokoroHexagon.ps1
pwsh -NoProfile -File ./Invoke-KokoroHexagon.ps1 Run -Case benchmark-0-sm8550 -Hypothesis 'layout slack'
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Status', 'Ratchet', 'Run', 'Emit', 'Check', 'Compare', 'JobInput', 'Capture', 'StockCapture', 'Albert', 'AlbertError', 'Find', 'Tools')]
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
    [int] $Seed = 17
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

switch ($Command) {
    'Status' {
        $head = git -C $Root log -1 --format='%h %s'
        $dirty = @(git -C $Root status --porcelain).Count
        "Kokoro-Hexagon  $head"
        "                $dirty uncommitted"
        $phones = @(Get-Phone)
        "Phone           $(if ($phones) { ($phones.Soc -join ', ') } else { 'none attached' })"
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
        Import-Module (Join-Path $Root 'tools/Kokoro.CaptureMath.psm1') -Force
        Import-Module (Join-Path $Root 'tools/Kokoro.CaptureKernels.psm1') -Force
        $cap = Read-KokoroCapture -Directory $(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path })
        if ($cap.Json.block -ne 'albert') { throw 'Not an ALBERT capture.' }
        $conv = Get-Conv1dKernel; $rowsKernel = Get-QuantizeRowsKernel
        $double = { param([float[]] $v) $d = [double[]]::new($v.Length); [Array]::Copy($v, $d, $v.Length); , $d }
        $quantize = { param([double[]] $v, [int] $rows, [int] $levels)
            $clip = [double[]]::new($rows); [Array]::Fill($clip, 1.0); $q = [double[]]::new($v.Length); $e = [double[]]::new($rows)
            $rowsKernel.Invoke($v, $rows, $v.Length / $rows, $levels, $clip, $q, $e); , $q }
        $snr = { param([double[]] $y, [double[]] $ref) $s = 0.0; $n = 0.0; for ($i = 0; $i -lt $y.Length; $i++) { $s += $ref[$i] * $ref[$i]; $n += ($y[$i] - $ref[$i]) * ($y[$i] - $ref[$i]) }; if ($n -eq 0) { 999 } else { [math]::Round(10 * [math]::Log10($s / $n), 2) } }
        $layer = 'bert.encoder.albert_layer_groups.0.albert_layers.0'
        $linears = [Collections.Generic.List[object]]::new()
        $linears.Add(@('mapping_in', 'bert.embeddings.output', 'bert.encoder.embedding_hidden_mapping_in', 'bert.encoder.embedding_hidden_mapping_in.output', $false))
        for ($r = 0; $r -lt 12; $r++) {
            foreach ($n in 'query', 'key', 'value') { $linears.Add(@("$n.$r", "bert.layer.$r.input", "$layer.attention.$n", "bert.layer.$r.attention.$n.output", $false)) }
            $linears.Add(@("dense.$r", "bert.layer.$r.attention.dense.input", "$layer.attention.dense", "bert.layer.$r.attention.dense.output", $false))
            $linears.Add(@("ffn.$r", "bert.layer.$r.attention.LayerNorm.output", "$layer.ffn", "bert.layer.$r.ffn.output", $false))
            $linears.Add(@("ffn_output.$r", "bert.layer.$r.activation.output", "$layer.ffn_output", "bert.layer.$r.ffn_output.output", $false))
        }
        $linears.Add(@('bert_encoder', 'bert_dur', 'bert_encoder', 'd_en', $true))
        $rows = foreach ($l in $linears) {
            $xt = & $double (Read-KokoroCaptureTensor -Capture $cap -Name $l[1])                 # [T][Cin]
            $w = & $double (Read-KokoroCaptureTensor -Capture $cap -Name "$($l[2]).weight")     # [Cout][Cin]
            $b = & $double (Read-KokoroCaptureTensor -Capture $cap -Name "$($l[2]).bias")
            $out32 = Read-KokoroCaptureTensor -Capture $cap -Name $l[3]
            $cout = $b.Length; $cin = $w.Length / $cout; $T = $xt.Length / $cin
            $x = [double[]]::new($xt.Length); for ($t0 = 0; $t0 -lt $T; $t0++) { for ($i = 0; $i -lt $cin; $i++) { $x[$i * $T + $t0] = $xt[$t0 * $cin + $i] } }
            $ref = [double[]]::new($cout * $T)                                                   # captured output as [Cout][T]
            for ($t0 = 0; $t0 -lt $T; $t0++) { for ($o = 0; $o -lt $cout; $o++) { $ref[$o * $T + $t0] = $(if ($l[4]) { $out32[$o * $T + $t0] } else { $out32[$t0 * $cout + $o] }) } }
            $run = { param([double[]] $xx, [double[]] $ww) $y = [double[]]::new($cout * $T); $conv.Invoke($xx, $cin, $T, $ww, $cout, 1, 0, $y)
                for ($o = 0; $o -lt $cout; $o++) { for ($t0 = 0; $t0 -lt $T; $t0++) { $y[$o * $T + $t0] += $b[$o] } }; , $y }
            $w8 = & $quantize $w $cout 127; $a16 = & $quantize $x 1 32767; $a8 = & $quantize $x 1 127
            [pscustomobject]@{ Linear = $l[0]; Shape = "$cout x $cin"; Stock = & $snr (& $run $x $w) $ref; W8 = & $snr (& $run $x $w8) $ref
                A16 = & $snr (& $run $a16 $w) $ref; A16W8 = & $snr (& $run $a16 $w8) $ref; A8W8 = & $snr (& $run $a8 $w8) $ref
                XAbsMax = [math]::Round((Get-KokoroAbsMax $xt), 2) }
        }
        "capture '$($cap.Json.phonemes)'  tokens $($cap.Json.tensors.'bert.input_ids'.shape[-1])"
        'Stock = this float64 linear against the capture (agreement check); the rest are dB SNR against the capture.'
        $rows | Format-Table -AutoSize | Out-String -Width 160
        'Per linear, worst repeat:'
        $rows | Group-Object { $_.Linear -replace '\.\d+$', '' } | ForEach-Object {
            [pscustomobject]@{ Linear = $_.Name; W8 = ($_.Group.W8 | Measure-Object -Minimum).Minimum; A16W8 = ($_.Group.A16W8 | Measure-Object -Minimum).Minimum; A8W8 = ($_.Group.A8W8 | Measure-Object -Minimum).Minimum; XAbsMax = ($_.Group.XAbsMax | Measure-Object -Maximum).Maximum } } | Format-Table -AutoSize | Out-String -Width 160
    }
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
