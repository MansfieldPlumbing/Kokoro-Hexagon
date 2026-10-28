<#
.SYNOPSIS
The one entrypoint for Kokoro-Hexagon work: where the project stands, what to do next, and every routine operation.

.DESCRIPTION
Run it with no arguments first. It prints the commit, the next step from the newest handoff,
the ratchet cases and the commands below. Every recurring operation belongs here as a command. A step typed by hand
twice, or written as a scratch script, is a missing command: add it here.

  Status                      Project state, next step, cases, commands (default). Reads the repository only:
                              no adb, no phone, no network. Phone access is only in Run, Ratchet and Compare.
  Verify                      Check tracked source, repository hygiene, handoff, Status, tests and optional case pairs.
  LineEndings [-Path]         Give every modified tracked file (or the one at -Path) back its committed line endings: unchanged
                              lines byte for byte from HEAD, changed lines in the file's dominant ending; the text is checked unchanged.
  CopySynthesis -OutputDirectory [-Path receipt.clixml]  Offline copy-synthesis; -Path rescoring changes only correlation.
                              -Parameters @{Ladder=$true} -Path run2/receipt.clixml renders R1/R4c and reuses R4.
  BuildHost -OutputDirectory  Build and retain the pinned arm64 diagnostic APK; no phone access.
  WeightAssembly -Path -OutputDirectory
                              Package native generator weights as an uncompressed managed resource and emit its mapped loader; no phone access.
  Ratchet  [-Case]            Case-pair check, then every unblocked ratchet case on the phone; throws on regression.
  Run      -Case [-Hypothesis] [-Runs]
                              Emit the case's kernel, run it on the phone, print input hashes, receipt and result.
  Run      -Case device-readiness [-Soc]
                              Read-only hardware and project-host checks; identifiers stay in memory and are never returned.
  Run      -Case host-install -Path <apk> [-Soc]
                              Install the verified Kokoro diagnostic host from its package receipt.
  Emit     -Case | -Kernel [-Parameters]
                              Emit a kernel (cached by source key) and print the library hash.
  Check    -Kernel [-Parameters]
                              Emit and check the bytes with the SDK assembler (Test-KokoroKernel).
  Compare  -Case -Setup [-Runs]
                              Run named setups of one case on the phone.
  JobInput -Reference -CaptureMap -OutputDirectory
                              Build a test case's job input from stock captures; prints which inputs match the reference.
  Capture  -Path [-Pattern]   List a stock capture's tensors: name, shape, bytes, hash prefix, and its capture spec.
  MeasureAudio -Path         Read a WAV or folder of WAVs; return typed BS.1770-4 loudness, true peak and RMS measurements.
                              PCM16/float32, mono/stereo, native sample rate. No phone access or audio writes.
  CompareAudio -Reference -Path [-OutputDirectory] [-Parameters @{Yardstick=<wav>}]
                              Compare two mono WAVs: waveform SNR, multi-resolution magnitude SNR and log-spectral
                              distance, mel-cepstral distortion, loudness envelope, YIN f0 and voicing, HNR; with
                              -OutputDirectory also spectrogram, difference, pitch and envelope PNGs; with a yardstick
                              (a render the same by construction, e.g. another seed) the same measures for scale.
  PhoneSpeech -Parameters @{Text=<sentence>; Runs=3} [-Soc] [-OutputDirectory]
                              Text to WAV on the phone in one process: our phonemizer and the stock front end on the CPU,
                              the decoder and the generator on the DSP (each on its voice base); per-stage times, the WAV,
                              and a comparison with the same text rendered from the host front end.
  StockCapture [-Block albert|decoder|generator] [-Phonemes] [-Voice] [-Seed] [-PhonemesFrom capture] [-DecoderInput json] [-OutputDirectory]
                              Run pinned stock PyTorch Kokoro on Windows (reference only) and record one block's tensors
                              under build/ with source, checkpoint and voice integrity checks. -PhonemesFrom reuses the phonemes,
                              voice and seed of another capture (a calibration set from existing sentences).
  Albert   [-Path]            ALBERT stage map: stock modules (pinned source), checkpoint tensors, captures, DSP kernels.
  AlbertError -Path           Per ALBERT linear (12 repeats of q, k, v, dense, ffn, ffn_output, plus the 128->768 mapping
                              and bert_encoder): output SNR against the stock capture with int8 per-output-channel
                              weights (W8), 16-bit per-tensor activations (A16), both, and A8W8 for contrast.
  Speak [-HeldOutIndex 0] [-Soc SM8550] [-Runs 3] [-OutputDirectory]
                              First bank-input sentence (at most 96 decoder frames): verify/restore the working
                              bank, select units in PowerShell, assemble table prosody, capture the stock syllabus on those
                              inputs, pack the existing job, run and play through AAudio. Generated files stay under build/.
  Zira -Text <sentence> [-OutputDirectory]  Windows speech API reference; returns typed phoneme/word events and a WAV.
  FrontEnd -Parameters <typed bank inputs> -OutputDirectory
  PrecomputedDecoder -Parameters @{ Mode = 'Gate' } (offline decoder/generator experiment)
                              Manufacture and gate the compact prosody bank on the laptop; no phone access.
  Student -Parameters @{ Step = 'Console' }
    Host text-to-speech console (student/Invoke-Student.ps1): our phonemizer and the lowered syllabus; plays and saves WAVs under build/.
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
  AlbertJob [-Path test] [-Soc] [-Runs] [-StopAfter operator]
                              The whole of ALBERT + bert_encoder in one DSP job from the test capture's token ids (default
                              hello world), every LSB planned from the calibration captures (bench1-3, howareyou): SNR of d_en
                              and of the stream after mapping_in and after each of the 12 repeats.
  Api      [-Pattern]         Index of every function in this file, src/ and tools/*.psm1: name, file:line, parameters,
                              summary. Start here before reading source.
  Find     -Pattern           Search project source, docs and receipts (not build/).
  Tools                       The older scripts under tools/, grouped; to be absorbed into this file as they are used.

LIBRARY
  . ./Invoke-KokoroDevelopment.ps1      loads every function below as an API without running a command (Api lists them).

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
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 AlbertLinear -Linear query.0
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 Api -Pattern 'Conv|Croutons'
pwsh -NoProfile -File ./Invoke-KokoroDevelopment.ps1 Run -Case timing-passage-0-sm8550 -Hypothesis 'layout slack'

#>
#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Status', 'Verify', 'LineEndings', 'BuildHost','Ratchet', 'Run', 'Emit', 'Check', 'Compare', 'JobInput', 'Capture', 'MeasureAudio', 'CompareAudio', 'PhoneSpeech', 'StockCapture', 'Speak', 'FrontEnd', 'PrecomputedDecoder', 'Student', 'Zira', 'Albert', 'AlbertError', 'AlbertLinear', 'AlbertLayerNorm', 'AlbertGelu', 'AlbertAttention', 'AlbertEmbed', 'AlbertJob', 'Api', 'Find', 'Tools', 'StageResidency', 'CopySynthesis', 'WeightAssembly')]
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
    [string] $PhonemesFrom,
    [string] $DecoderInput,
    [pscustomobject] $DecoderInputData,
    [string] $Text,
    [ValidateRange(0, 8)][int] $HeldOutIndex = 0,
    [string] $StopAfter,
    [string] $Linear,
    [string] $Norm,
    [string] $Repeat,
    [ValidateSet('SM8550', 'SM8635')]
    [string] $Soc = 'SM8550',
    [ValidateSet('dev.mansfieldplumbing.androidsma.preview', 'dev.mansfieldplumbing.kokoro')]
    [string] $HostPackage = 'dev.mansfieldplumbing.kokoro',
    # Pwsh-Development checkout; CI passes its own (checkout cannot write outside the workspace).
    [string] $SharedRoot,
    # Verify: a missing shared library is a failure, not a skip (CI).
    [switch] $RequireShared,
    [Alias('help')][switch] $h
)

$ErrorActionPreference = 'Stop'
if($h){Get-Help $PSCommandPath -Detailed;return}
$Root = $PSScriptRoot
$Build = Join-Path $Root 'build'
$Shared = if ($SharedRoot) { [IO.Path]::GetFullPath($SharedRoot) } else { [IO.Path]::GetFullPath((Join-Path $Root '../Pwsh-Development')) }
$StockSource = if ($env:KOKORO_STOCK_SOURCE) { $env:KOKORO_STOCK_SOURCE } else { Join-Path (Split-Path $Root) '.vendor/kokoro' }

$StockCommit = 'dfb907a02bba8152ca444717ca5d78747ccb4bec'   # lib/manifest.json kokoroSource.commit
# StockCapture runs stock PyTorch Kokoro from the reference folder to record syllabus tensors; nothing else uses Python.
# KOKORO_PYTHON names the interpreter with stock PyTorch Kokoro installed.
$Python = $env:KOKORO_PYTHON


# Editors rewrite whole files with one line ending; this repository's files mix them. For each modified tracked file,
# git's hunk map (ignoring carriage returns) says which lines changed: unchanged lines are copied byte for byte from HEAD
# and changed lines take the file's dominant ending. The resulting text must equal the working text.
function Restore-KokoroLineEndings {
    # File: one repository-relative file instead of every modified one.
    param([string]$File)
    $changed = if ($File) { @($File) } else { @(git -C $Root diff --name-only) }
    foreach ($relative in $changed) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        # The committed bytes, read raw: PowerShell's native-command pipeline would split and re-join the lines.
        $info = [Diagnostics.ProcessStartInfo]::new('git', "-C `"$Root`" cat-file blob `"HEAD:$relative`""); $info.RedirectStandardOutput = $true; $info.UseShellExecute = $false
        $process = [Diagnostics.Process]::Start($info); $memory = [IO.MemoryStream]::new(); $process.StandardOutput.BaseStream.CopyTo($memory); $process.WaitForExit()
        $headText = [Text.Encoding]::UTF8.GetString($memory.ToArray())
        $headLines = @([regex]::Matches($headText, "[^`n]*`n|[^`n]+$") | ForEach-Object Value)
        $eol = if (([regex]::Matches($headText, "`r`n")).Count -ge ([regex]::Matches($headText, "(?<!`r)`n")).Count) { "`r`n" } else { "`n" }
        $workingText = [IO.File]::ReadAllText($path)
        $newLines = $workingText -split "`r?`n"; if ($newLines[-1] -eq '') { $newLines = $newLines[0..($newLines.Count - 2)] }
        $hunks = @(git -C $Root diff --ignore-cr-at-eol -U0 -- $relative | Select-String '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@' | ForEach-Object {
            $g = $_.Matches[0].Groups
            [pscustomobject]@{ OldStart = [int]$g[1].Value; OldCount = $(if ($g[2].Success) { [int]$g[2].Value } else { 1 }); NewStart = [int]$g[3].Value; NewCount = $(if ($g[4].Success) { [int]$g[4].Value } else { 1 }) } })
        $builder = [Text.StringBuilder]::new(); $oldAt = 1
        foreach ($hunk in $hunks) {
            $oldFirst = if ($hunk.OldCount -eq 0) { $hunk.OldStart + 1 } else { $hunk.OldStart }
            while ($oldAt -lt $oldFirst) { $null = $builder.Append($headLines[$oldAt - 1]); $oldAt++ }
            for ($k = 0; $k -lt $hunk.NewCount; $k++) { $null = $builder.Append($newLines[$hunk.NewStart - 1 + $k] + $eol) }
            $oldAt += $hunk.OldCount
        }
        while ($oldAt -le $headLines.Count) { $null = $builder.Append($headLines[$oldAt - 1]); $oldAt++ }
        $rebuilt = $builder.ToString()
        $check = $rebuilt -split "`r?`n"; if ($check[-1] -eq '') { $check = $check[0..($check.Count - 2)] }
        if (($check -join "`n") -cne ($newLines -join "`n")) { throw "Line-ending restoration would change the text of $relative." }
        if ($rebuilt -cne $workingText) { [IO.File]::WriteAllText($path, $rebuilt, [Text.UTF8Encoding]::new($false)) }
        [pscustomobject]@{ Path = $relative; Hunks = $hunks.Count; Rewritten = ($rebuilt -cne $workingText) }
    }
}

# Imported once per process: the module holds the resident device session.
function Import-Evaluator { if (-not (Get-Module Kokoro.Evaluator)) { Import-Module (Join-Path $Root 'tools/Kokoro.Evaluator.psm1') -Global } }

# Every device operation goes through the pinned PowerShell ADB client (lib/manifest.json pwshAdb) with -Api.
function Get-Adb { Import-Evaluator; Get-KokoroAdbClient }

# Phone facts by SoC only; a phone is its adb.ps1 device index, and identifiers never leave adb.ps1.
function Get-Phone {
    $adb = Get-Adb
    foreach ($d in @(& $adb devices -Api | Where-Object { $_.IsAccessible -or $_.Connected })) {
        [pscustomobject]@{ Soc = ([string](& $adb shell -Api -Device ([string]$d.Index) 'getprop ro.soc.model').Stdout).Trim(); Device = [string]$d.Index }
    }
}

function Resume-Phone { $adb = Get-Adb; foreach ($p in Get-Phone) { $null = & $adb shell -Api -Device $p.Device 'input keyevent KEYCODE_WAKEUP' } }

function Get-KokoroDeviceReadiness {
    param([ValidateSet('SM8550', 'SM8635')][string] $Soc = 'SM8550',
        [ValidateSet('dev.mansfieldplumbing.androidsma.preview', 'dev.mansfieldplumbing.kokoro')]
        [string] $Package = 'dev.mansfieldplumbing.kokoro')
    # Only whitelisted hardware facts and project-app booleans leave this function.
    # Never return native command output, identifiers, broad getprop/logcat dumps or personal app inventory.
    $adb = Get-Adb
    # One device shell command as a single string, so its own flags never bind to adb.ps1 parameters.
    $probe = {
        param([string] $Device, [string[]] $Command)
        try {
            $result = & $adb shell -Api -Device $Device ($Command -join ' ')
            [pscustomobject]@{ ExitCode = [int]$result.ExitCode; Text = ([string]$result.Stdout).Trim() }
        } catch { throw 'Private device probe could not execute; native details suppressed.' }
    }
    $targets = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(& $adb devices -Api | Where-Object { $_.IsAccessible -or $_.Connected })) {
        $candidateId = [string]$candidate.Index
        $hardware = & $probe $candidateId @('getprop', 'ro.soc.model')
        if ($hardware.ExitCode -eq 0 -and $hardware.Text -ceq $Soc) { $targets.Add($candidateId) }
    }
    if ($targets.Count -ne 1) { throw "Expected exactly one authorized attached $Soc device, found $($targets.Count); identifiers suppressed." }
    $selectedId = $targets[0]
    $release = & $probe $selectedId @('getprop', 'ro.build.version.release')
    $abi = & $probe $selectedId @('getprop', 'ro.product.cpu.abilist')
    # Query only the selected project host, never a general app listing.
    $installed = & $probe $selectedId @('pm', 'path', $Package)
    $appAccess = & $probe $selectedId @('run-as', $Package, 'id', '-u')
    $startup = & $probe $selectedId @('run-as', $Package, 'test', '-f', 'files/Start.ps1')
    $profile = & $probe $selectedId @('run-as', $Package, 'test', '-f', 'files/PROFILE.PS1')
    $consoleStartup = & $probe $selectedId @('run-as', $Package, 'test', '-f', 'files/app-scripts/Start-Console.ps1')
    $process = & $probe $selectedId @('pidof', $Package)
    $diagnosticReceipt = & $probe $selectedId @('run-as', $Package, 'cat', 'files/kokoro/generator-tail/receipt.txt')
    $startedText = [regex]::Match($diagnosticReceipt.Text, '(?m)^Started=([0-9TZ:.+-]+)').Groups[1].Value
    $hostStages = [Collections.Generic.List[string]]::new()
    $fatalSignal = ''
    if ($startedText -and $appAccess.Text -match '^\d+$') {
        $epoch = [DateTimeOffset]::Parse($startedText, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
        $hostLog = & $probe $selectedId @('logcat', '-d', '-T', "$epoch.000", "--uid=$($appAccess.Text)", '-s', 'Pwsh:I', 'libc:E', 'AndroidRuntime:E', "'*:S'")
        foreach ($stage in 'GATE2B managed resolution complete', 'GATE2C CreateDefault2', 'GATE2C CreateRunspace', 'GATE2C Open', 'GATE2C DefaultRunspace set', 'GATE2D START_INVOKE_BEGIN', 'GATE2D START_INVOKE_END') {
            if ($hostLog.Text.Contains($stage, [StringComparison]::Ordinal)) { $hostStages.Add($stage) }
        }
        $fatalSignal = [regex]::Match($hostLog.Text, 'Fatal signal (6|11)\b').Groups[1].Value
    }
    [pscustomobject]@{
        Soc = $Soc
        AndroidVersion = $(if ($release.ExitCode -eq 0 -and $release.Text -match '^\d{1,2}(\.\d{1,2}){0,2}$') { $release.Text } else { 'Unavailable' })
        Arm64 = ($abi.ExitCode -eq 0 -and 'arm64-v8a' -cin ($abi.Text.Split(',')))
        ConsoleHostStartupPresent = ($consoleStartup.ExitCode -eq 0)
        ProjectHostInstalled = ($installed.ExitCode -eq 0 -and $installed.Text.StartsWith('package:', [StringComparison]::Ordinal))
        ProjectAppAccessible = ($appAccess.ExitCode -eq 0)
        StartupFilesPresent = ($startup.ExitCode -eq 0 -and $profile.ExitCode -eq 0)
        ProjectProcessRunning = ($process.ExitCode -eq 0)
        DiagnosticStarted = ($diagnosticReceipt.ExitCode -eq 0 -and $diagnosticReceipt.Text -match '(?m)^Started=')
        DiagnosticCompleted = ($diagnosticReceipt.ExitCode -eq 0 -and $diagnosticReceipt.Text -match '(?m)^Passed=')
        DiagnosticStartUtc = $startedText
        ManagedHostStages = $hostStages.ToArray()
        NativeFatalSignal = $fatalSignal
        DiagnosticReturnCodes = [string[]]@([regex]::Matches($diagnosticReceipt.Text, '(?m)^(?:UnsignedPdRc|OpenRc)=-?\d+').Value)
        DspExecutionVerified = $false
    }
}

function Install-KokoroDiagnosticHost {
    param([Parameter(Mandatory)][string] $Path, [ValidateSet('SM8550', 'SM8635')][string] $Soc)
    $apkPath = [IO.Path]::GetFullPath($Path)
    $buildPath = [IO.Path]::GetFullPath($Build) + [IO.Path]::DirectorySeparatorChar
    if (-not $apkPath.StartsWith($buildPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Diagnostic APK must be under build/.' }
    $packageReceipt = Get-Content (Join-Path (Split-Path $apkPath) 'package-receipt.json') -Raw | ConvertFrom-Json
    $upstream = (Get-Content (Join-Path $Root 'lib/manifest.json') -Raw | ConvertFrom-Json).pwshUpstream
    $setupPin = @($upstream.files | Where-Object { $_.path -ceq 'setup.ps1' })
    if ($setupPin.Count -ne 1 -or $packageReceipt.SetupSHA256 -cne $setupPin[0].sha256) {
        throw 'Diagnostic host was built from a different upstream pin; rebuild with BuildHost.'
    }
    if ($packageReceipt.Package -cne 'dev.mansfieldplumbing.kokoro' -or
        $packageReceipt.Startup -cne 'Profile' -or -not $packageReceipt.Debuggable -or
        -not $packageReceipt.SignatureV2Verified -or -not $packageReceipt.ArchiveReadbackVerified -or
        $packageReceipt.ModelWeightsIncluded -ne $false) { throw 'Diagnostic host receipt admission failed.' }
    if ((Get-Item -LiteralPath $apkPath).Length -ne $packageReceipt.APKBytes -or
        (Get-FileHash -LiteralPath $apkPath).Hash -cne $packageReceipt.APKSHA256) { throw 'Diagnostic APK integrity mismatch.' }
    $phones = @(Get-Phone | Where-Object Soc -CEQ $Soc)
    if ($phones.Count -ne 1) { throw "Expected exactly one authorized attached $Soc target; identifiers suppressed." }
    $adb = Get-Adb
    $installResult = & $adb install -Api -Device $phones[0].Device $apkPath '-r'
    if (([string]$installResult.Stdout) -cnotmatch '(?m)^Success\s*$') { throw 'Diagnostic host installation failed; native details suppressed.' }
    Get-KokoroDeviceReadiness -Soc $Soc -Package $packageReceipt.Package
}

function Test-KokoroCasePairs {
    $sharedLibrary = Join-Path $Shared 'tools/SharedLibrary.psm1'
    if (-not (Test-Path -LiteralPath $sharedLibrary)) {
        if ($RequireShared) { throw "shared library not present at $Shared" }
        return 'SKIP case-pairs: shared library not present'
    }
    Import-Module $sharedLibrary
    $ps = @(git -C $Root ls-files '*.ps1' '*.psm1') | ForEach-Object { Join-Path $Root $_ }
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
    $findings = @(Test-PowerShellCasePair -Path $ps -MaxResults ([int]::MaxValue) 6>$null)
    $known = (Import-PowerShellDataFile (Join-Path $Root 'tools/Kokoro.CasePairs.psd1')).Known
    $knownKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $currentKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $known) { [void]$knownKeys.Add("$($entry.File)`0$($entry.Names)") }
    $newFindings = foreach ($finding in $findings) {
        $key = "$($finding.File)`0$($finding.Names)"
        [void]$currentKeys.Add($key)
        if (-not $knownKeys.Contains($key)) { "$($finding.File) $($finding.Names)" }
    }
    foreach ($entry in $known) {
        if (-not $currentKeys.Contains("$($entry.File)`0$($entry.Names)")) {
            Write-Host "resolved: $($entry.File) $($entry.Names)"
        }
    }
    if ($newFindings) { throw ('new findings: ' + ($newFindings -join '; ')) }
    "PASS case-pairs: $($findings.Count) known, 0 new"
}

# Project notes (handoffs, designs, results) and reference material live outside the repository. KOKORO_NOTES names
# that folder; by default it sits beside this checkout with the shared agent rules. Modules read the same variable.
if (-not $env:KOKORO_NOTES) { $env:KOKORO_NOTES = Join-Path (Split-Path $Root) 'Pwsh-Development/docs/kokoro-hexagon' }
$script:NotesRoot = $env:KOKORO_NOTES


function Get-KokoroReferencePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    $path = Join-Path $script:NotesRoot "reference/$RelativePath"
    if (-not (Test-Path -LiteralPath $path)) { throw "Reference file '$RelativePath' is missing under $script:NotesRoot/reference. Set KOKORO_NOTES to the project notes folder." }
    $path
}

function Get-NextStep {
    $handoff = if (Test-Path $script:NotesRoot) { Get-ChildItem $script:NotesRoot -Filter 'handoff-*.md' | Sort-Object Name | Select-Object -Last 1 }
    if (-not $handoff) { return [pscustomobject]@{ Handoff = $null; Steps = @() } }

    $lines = Get-Content $handoff.FullName
    $start = ($lines | Select-String -Pattern '^## Next' | Select-Object -First 1).LineNumber
    # A numbered item runs on over indented continuation lines; join them so no step is cut mid-sentence.
    $steps = [Collections.Generic.List[string]]::new()
    if ($start) {
        foreach ($line in $lines[$start..($lines.Count - 1)]) {
            if ($line -match '^\d+\.\s') { $steps.Add($line.Trim()) }
            elseif ($steps.Count -and $line -match '^\s+\S') { $steps[-1] += ' ' + $line.Trim() }
            elseif ($steps.Count -and $line -notmatch '^\s*$') { break }
        }
    }
    [pscustomobject]@{ Handoff = $handoff.Name; Steps = @($steps | Select-Object -First 3) }
}

# Word-wraps text to the console width (120 when redirected) with a hanging indent; never truncates.
function Format-Wrapped([string] $Text, [int] $Indent = 2, [int] $Hang = 0, [string] $Lead = '') {
    $width = 120
    if (-not [Console]::IsOutputRedirected) { try { $w = [Console]::WindowWidth; if ($w -ge 40) { $width = $w - 1 } } catch { } }
    $line = (' ' * $Indent) + $Lead
    $pad = ' ' * ($Indent + $Hang)
    $fresh = $true
    foreach ($word in $Text -split '\s+' | Where-Object { $_ }) {
        if (-not $fresh -and $line.Length + 1 + $word.Length -gt $width) { $line; $line = $pad + $word }
        else { $line += $(if ($fresh) { $word } else { ' ' + $word }) }
        $fresh = $false
    }
    $line
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

# Identity table rescaling a stored tensor (LSB Scales[c]) into one conv-input LSB Common: K = Scales[c] / Common * 2^15 as
# int32 (New-KokoroAdaInLeaky16Steps -Identity computes K x / 2^15 and clamps to int16), so a gain above 1 is allowed: the
# windows fill their 16 bits from the input's own peak, whatever the LSB the tensor is stored in.
function ConvertTo-KokoroIdentityTable {
    param([Parameter(Mandatory)][double[]] $Scales, [Parameter(Mandatory)][int] $Channels, [Parameter(Mandatory)][double] $Common)
    $bytes = [byte[]]::new(256L * $Channels / 32)
    for ($c = 0; $c -lt $Scales.Length; $c++) {
        $k = [long](Get-Even ($Scales[$c] / $Common * 32768)); if ($k -lt 1 -or $k -gt [int]::MaxValue) { throw "Identity K $k out of int32 range at channel $c" }
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
        [double] $Margin = 1.25,
        # With InScale all 1, the weights are quantized in weight units (the same bytes for any input LSB, so a weight shared
        # by layers with different input LSBs packs once) and WindowLsb, the conv-input LSB, enters only units, L and bias.
        [double] $WindowLsb = 1.0)
    if ($Weight.Length -ne $Cout * $CinReal * $K) { throw "Weight has $($Weight.Length) values, expected $Cout x $CinReal x $K" }
    $fold = [float[]]::new($Cout * $Cin * $K); $wMax = [double[]]::new($Cout)
    (Get-FoldConvWeightsKernel).Invoke($Weight, $Cout, $CinReal, $Cin, $K, $InScale, $fold, $wMax)
    $sW = [double[]]::new($Cout); $Ls = [int[]]::new($Cout); $units = [double[]]::new($Cout); $coarse = 0
    for ($o = 0; $o -lt $Cout; $o++) {
        $nd = [math]::Max($Peak[$o] * $Margin / 32767, 1e-30)
        $sW[$o] = if ($wMax[$o] -gt 0) { $wMax[$o] / 127 } else { $nd / 16384 / $WindowLsb }
        $Lo = [math]::Max(2, [int][math]::Ceiling([math]::Log($nd / ($sW[$o] * $WindowLsb), 2)))
        if ($Lo -gt 14) { $Lo = 14; $sW[$o] = $nd / 16384 / $WindowLsb; $coarse++ }
        $Ls[$o] = $Lo
    }
    $bytes = [long]$Cout * $Cin * $K
    $wh = [byte[]]::new($bytes); $wl = [byte[]]::new($bytes); $sumH = [long[]]::new($Cout); $sumL = [long[]]::new($Cout)
    if ((Get-PackWeightPlanesShapedKernel).Invoke($fold, $Cout, $Cin, $K, $sW, $wh, $wl, $sumH, $sumL) -ne 0) { throw 'Weight overflow' }
    foreach ($h in $sumH) { if ($h -ne 0) { throw 'W8 weights left a high plane' } }
    # Each accumulator group carries the low byte's mean, 127.5 input LSB times the weight row sum, which cancels only in
    # their sum; at 2^-L it must leave room in each group's 16-bit window (Measure-KokoroConvWindows checks real inputs).
    for ($o = 0; $o -lt $Cout; $o++) { $offset = 127.5 * [math]::Abs($sumL[$o]) / [math]::Pow(2, $Ls[$o]); if ($offset -gt 16384) { throw ("Output ${o}: accumulator-group offset {0:N0} at L {1} leaves too little of the 16-bit window: the conv-input windows are too coarse for this input (size them from the input's peak)" -f $offset, $Ls[$o]) } }
    $tables = [byte[]]::new(1024L * $Cout / 32)
    for ($o = 0; $o -lt $Cout; $o++) {
        $Lo = $Ls[$o]; $units[$o] = $sW[$o] * $WindowLsb * [math]::Pow(2, $Lo)
        if ($Peak[$o] -gt 32767 * $units[$o]) { throw "Output ${o}: peak $($Peak[$o]) exceeds the 16-bit window ($(32767 * $units[$o]))" }
        $ob = [int][math]::Floor($o / 32); $cc = $o % 32
        $bq = if ($Bias) { [long](Get-Even ($Bias[$o] / ($sW[$o] * $WindowLsb))) } else { 0L }
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

# The two HMX accumulator-group windows of a W8 linear as the conv stores them (

# x = (h - 128) 256 + l in the conv-input LSB; win(A1) = 256 sum (h - 128) Wq / 2^L, win(A2) = (sum l Wq + bq) / 2^L,
# each through a 16-bit window), for given inputs: how many values leave int16 (the high plane saturates). Weight [o][i],
# Values token-major [T][Cin] (real units), WindowLsb the conv-input LSB, Units the deployed output LSB per channel.
function Measure-KokoroConvWindows {
    param([Parameter(Mandatory)][float[]] $Weight, [Parameter(Mandatory)][float[]] $Bias, [Parameter(Mandatory)][float[]] $Values,
        [Parameter(Mandatory)][double] $WindowLsb, [Parameter(Mandatory)][double[]] $Units)
    $cout = $Bias.Length; $cin = $Weight.Length / $cout; $tokens = $Values.Length / $cin
    $hi = [int[]]::new($Values.Length); $lo = [int[]]::new($Values.Length)
    for ($i = 0; $i -lt $Values.Length; $i++) { $x = [int][math]::Max(-32767, [math]::Min(32767, [math]::Round($Values[$i] / $WindowLsb))); $hi[$i] = $x -shr 8; $lo[$i] = $x -band 255 }
    $over1 = 0; $over2 = 0; $worst1 = 0.0; $worst2 = 0.0; $channels = [Collections.Generic.HashSet[int]]::new(); $lValues = [Collections.Generic.List[int]]::new()
    for ($o = 0; $o -lt $cout; $o++) {
        $m = 0.0; for ($i = 0; $i -lt $cin; $i++) { $m = [math]::Max($m, [math]::Abs($Weight[$o * $cin + $i])) }; $sW = $m / 127
        $q = [int[]]::new($cin); for ($i = 0; $i -lt $cin; $i++) { $q[$i] = [int][math]::Round($Weight[$o * $cin + $i] / $sW) }
        $shift = [int][math]::Round([math]::Log($Units[$o] / ($sW * $WindowLsb), 2)); $lValues.Add($shift); $scale = [math]::Pow(2, $shift)
        $bq = [math]::Round($Bias[$o] / ($sW * $WindowLsb))
        for ($k = 0; $k -lt $tokens; $k++) {
            $g1 = 0L; $g2 = 0L; for ($i = 0; $i -lt $cin; $i++) { $g1 += $hi[$k * $cin + $i] * $q[$i]; $g2 += $lo[$k * $cin + $i] * $q[$i] }
            $w1 = [math]::Abs(256.0 * $g1 / $scale); $w2 = [math]::Abs(($g2 + $bq) / $scale)
            $worst1 = [math]::Max($worst1, $w1); $worst2 = [math]::Max($worst2, $w2)
            if ($w1 -gt 32767) { $over1++; [void]$channels.Add($o) }; if ($w2 -gt 32767) { $over2++; [void]$channels.Add($o) } } }
    [pscustomobject]@{ Values = $tokens * $cout; OverA1 = $over1; WorstA1 = [math]::Round($worst1); OverA2 = $over2; WorstA2 = [math]::Round($worst2); Channels = $channels.Count
        LMin = ($lValues | Measure-Object -Minimum).Minimum; LMax = ($lValues | Measure-Object -Maximum).Maximum }
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
    param([Parameter(Mandatory)][string] $EmissionDirectory, [Parameter(Mandatory)][string] $InputDirectory, [string] $Soc = 'SM8550', [int] $Runs = 3,
        [ValidateSet('dev.mansfieldplumbing.androidsma.preview','dev.mansfieldplumbing.kokoro')][string] $Package = 'dev.mansfieldplumbing.kokoro',
        [pscustomobject] $EmissionArtifact,
        # Relaunch the app for this one job instead of using the resident listener.
        [switch] $OneShot)
    if ($null -ne $EmissionArtifact -and -not $OneShot) {
        Import-Evaluator
        # After a one-shot relaunch the listener can accept a connection and drop the first write; jobs are repeatable,
        # so a failed resident job reconnects and runs once more.
        try { return Invoke-KokoroResidentJob -EmissionArtifact $EmissionArtifact -InputDirectory $InputDirectory -Soc $Soc -Runs $Runs -Package $Package }
        catch { try { Stop-KokoroDeviceSession } catch { }; return Invoke-KokoroResidentJob -EmissionArtifact $EmissionArtifact -InputDirectory $InputDirectory -Soc $Soc -Runs $Runs -Package $Package }
    }
    Resume-Phone
    # A one-shot job relaunches the app: end the resident listener first, so the next resident job starts a new one.
    if (Get-Command Stop-KokoroDeviceSession -ErrorAction Ignore) { try { Stop-KokoroDeviceSession } catch { } }
    if ($null -ne $EmissionArtifact) {
        $out = & (Join-Path $Root 'tools/Invoke-GeneratorTailProbe.ps1') -EmissionDirectory $EmissionDirectory -EmissionArtifact $EmissionArtifact -FixtureDirectory $InputDirectory -Soc $Soc -Runs $Runs -Package $Package -TimeoutSeconds 300 -Adb (Get-Adb) 2>&1
    } else {
        $out = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $Root 'tools/Invoke-GeneratorTailProbe.ps1') -EmissionDirectory $EmissionDirectory -FixtureDirectory $InputDirectory -Soc $Soc -Runs $Runs -Package $Package -TimeoutSeconds 300 -Adb (Get-Adb) 2>&1
    }
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    $field = { param([string] $n) if ($text -match "(?m)\b$n=(\S+)") { $Matches[1] } }
    $outputPath = & $field 'OutputPath'
    if (-not $outputPath -or $text -notmatch '(?m)^Passed=True\s*$' -or $text -notmatch '(?m)^StartupRestored=True\s*$') { throw "Phone run failed or startup was not restored: $(($out | Select-Object -Last 4) -join ' | ')" }
    [pscustomobject]@{ Output = [IO.File]::ReadAllBytes($outputPath); OutputPath = $outputPath; MedianMs = [double](& $field 'MedianRegionMs')
        Lines = @($text -split '\r?\n' | Where-Object { $_ -match '^(Run=|Median|InvokeRc|Stage|Played=|Passed=|StartupRestored=|ReceiptPath=)' }) }
}

function New-KokoroDecoderConstantsTables {
    param([Parameter(Mandatory)]$Layout,[Parameter(Mandatory)][byte[]]$Tables,
        [Parameter(Mandatory)][byte[]]$Observation,[int]$OutputOffset=256,$Contracts)
    if($Tables.Length -ne $Layout.ParameterBytes -or
        $Observation.Length -ne $OutputOffset+$Layout.OutputBytes+$Layout.MomentsBytes+$Layout.KmBytes){throw 'Decoder constants source lengths differ from the layout.'}
    $result=[byte[]]::new($Layout.ConstantsParameterBytes)
    [Array]::Copy($Tables,$result,$Tables.Length)
    $terms=[Collections.Generic.List[object]]::new()
    foreach($site in $Layout.MomentSites){
        $n=if($Contracts){$site.Frames}elseif($site.Count -eq 'F2'){2*$Layout.Frames}else{$Layout.Frames}
        if($n -lt 1 -or $n -gt 65535){throw 'Constant mean denominator exceeds the DSP contract.'}
        if($Contracts){$recordAt=$site.RecordOffset}else{
            $blockIndex=[int][math]::Floor($site.Index/2)
            $recordAt=if($site.Index%2){$Layout.BlockParams[$blockIndex].Records2}else{$Layout.BlockParams[$blockIndex].Records1}
        }
        for($channel=0;$channel -lt $site.Width;$channel++){
            $momentAt=[int]($OutputOffset+$Layout.OutputBytes+$site.Offset+512L*[math]::Floor($channel/32)+4L*($channel%32))
            $sum=[BitConverter]::ToInt32($Observation,$momentAt)
            $squares=65536L*[BitConverter]::ToInt32($Observation,$momentAt+128)+512L*[BitConverter]::ToInt32($Observation,$momentAt+256)+[BitConverter]::ToInt32($Observation,$momentAt+384)
            $parameterAt=[int]($recordAt+32L*$channel)
            $ka=[bigint][BitConverter]::ToInt64($Tables,$parameterAt)
            $mb=[BitConverter]::ToInt32($Tables,$parameterAt+8)
            $eps=[BitConverter]::ToUInt64($Tables,$parameterAt+16)
            $d=[bigint]$n*$squares-[bigint]$sum*$sum+$eps
            if($d -le 0){throw "Nonpositive decoder variance at $($site.Name)/$channel."}
            $root=[long][math]::Floor([math]::Sqrt([double]$d))
            while([bigint]$root*$root -gt $d){$root--}
            while([bigint]($root+1)*($root+1) -le $d){$root++}
            if($root -lt 1 -or $root -gt 2147483647){throw 'Constant inverse denominator exceeds the DSP contract.'}
            $magnitude=[bigint]::Abs($ka)*$n+[bigint]::Divide($root,2)
            if($magnitude -gt [uint64]::MaxValue){throw 'Constant coefficient product exceeds uint64.'}
            $kMagnitude=[bigint]::Min(2147483647,[bigint]::Divide($magnitude,$root))
            $k=if($ka -lt 0){-[long]$kMagnitude}else{[long]$kMagnitude}
            $meanProduct=[bigint]$k*$sum; $meanDenominator=[long]$n*32768
            $correction=[bigint]::Min(2147483647,[bigint]::Divide([bigint]::Abs($meanProduct)+[bigint]::Divide($meanDenominator,2),$meanDenominator))
            if($meanProduct -lt 0){$correction=-$correction}
            $m=[uint32](([long]$mb-[long]$correction) -band 0xffffffffL)
            $kmBase=$OutputOffset+$Layout.OutputBytes+$Layout.MomentsBytes+$site.KmOffset
            $kmAt=[int]($kmBase+$(if($Contracts){4L*$channel}else{256L*[math]::Floor($channel/32)+4L*($channel%32)}))
            $mAt=$kmAt+$(if($Contracts){4*$site.Width}else{128})
            if([BitConverter]::ToInt32($Observation,$kmAt) -ne $k -or [BitConverter]::ToUInt32($Observation,$mAt) -ne $m){throw "Exported K/M disagrees with the exact constant terms at $($site.Name)/$channel."}
            if($Contracts -and [BitConverter]::ToInt32($Observation,[int]($kmBase+8L*$site.Width+4L*$channel)) -ne [BitConverter]::ToInt32($Tables,$parameterAt+12)){throw "Exported Snake scale differs at $($site.Name)/$channel."}
            $constantAt=[int]($Layout.ConstantsTableOffset+$site.Offset+16L*$channel)
            [Array]::Copy([BitConverter]::GetBytes([uint32]$n),0,$result,$constantAt,4)
            [Array]::Copy([BitConverter]::GetBytes([uint32]$root),0,$result,$constantAt+4,4)
            [Array]::Copy([BitConverter]::GetBytes([int]$sum),0,$result,$constantAt+8,4)
            [Array]::Copy([BitConverter]::GetBytes([uint32]$n),0,$result,$constantAt+12,4)
            $terms.Add([pscustomobject]@{Site=$site.Name;Channel=$channel;Inverse=([double]$n/$root);Mean=([double]$sum/$n)})
        }
    }
    [pscustomobject]@{Tables=$result;Terms=$terms.ToArray();Channels=$terms.Count;Sites=$Layout.MomentSites.Count}
}

function Get-KokoroDecoderSiteContracts {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)]$Layout)
    $asrScales=[double[]]::new(512)
    foreach($directory in $Fixture.CalibrationCaptures){
        $capture=Read-KokoroCapture -Directory $directory
        $stats=Get-KokoroChannelStats -Values (Read-KokoroCaptureTensor -Capture $capture -Name 'decoder.input.0') -Channels 512
        for($c=0;$c -lt 512;$c++){$asrScales[$c]=[math]::Max($asrScales[$c],$stats.AbsMax[$c])}
    }
    for($c=0;$c -lt 512;$c++){$asrScales[$c]=[math]::Max($asrScales[$c],1e-12)*$Fixture.Margin/32767}
    $inputScales=[double[]]::new(544); [Array]::Fill($inputScales,1.0); [Array]::Copy($asrScales,$inputScales,512)
    $inputScales[512]=$Fixture.F0Scale; $inputScales[513]=$Fixture.NScale
    $contracts=[Collections.Generic.List[object]]::new()
    for($block=0;$block -lt 5;$block++){
        $b=$Layout.Blocks[$block]; $name=$b.Name; $q=$Layout.BlockParams[$block]
        $scales=@($Fixture.Report | Where-Object Name -CEQ "$name.scales")
        if($scales.Count -ne 1){throw "Missing fixed fixture scales for $name."}
        $targets1=[double[]]::new($b.Cin); [Array]::Fill($targets1,[double]$scales[0].Value.X1)
        if($b.Up){$targets1=[double[]]$Fixture.PoolInputScales}
        $targets2=[double[]]::new($b.Cout); [Array]::Fill($targets2,[double]$scales[0].Value.X2)
        $contracts.Add([pscustomobject]@{Site=$Layout.MomentSites[2*$block];Norm="decoder.$name.norm1";InputScales=$inputScales;TargetScales=$targets1;RecordOffset=$q.Records1;RealChannels=$(if($block){1090}else{514})})
        $contracts.Add([pscustomobject]@{Site=$Layout.MomentSites[2*$block+1];Norm="decoder.$name.norm2";InputScales=[double[]]$Fixture.Conv1Units.PSObject.Properties[$name].Value;TargetScales=$targets2;RecordOffset=$q.Records2;RealChannels=$b.Cout})
        if(-not $b.Up){
            $inputScales=[double[]]::new(1120); [Array]::Fill($inputScales,1.0)
            [Array]::Copy([double[]]$Fixture.BlockOutputScales.PSObject.Properties[$name].Value,$inputScales,1024)
            [Array]::Copy([double[]]$Fixture.AsrResUnits,0,$inputScales,1024,64)
            $inputScales[1088]=$Fixture.F0Scale; $inputScales[1089]=$Fixture.NScale
        }
    }
    $contracts.ToArray()
}

function Set-KokoroDecoderConstantRatio {
    param([Parameter(Mandatory)][byte[]]$Tables,[int]$Offset,[double]$Inverse,[double]$Mean,[bigint]$Ka)
    if(-not [double]::IsFinite($Inverse) -or $Inverse -le 0 -or -not [double]::IsFinite($Mean) -or [math]::Abs($Mean) -gt 32767){throw 'Invalid decoder normalization constants.'}
    $inverseDenominator=1073741824L
    do {
        $inverseNumerator=[math]::Round($Inverse*$inverseDenominator,[MidpointRounding]::ToEven)
        $fits=$inverseNumerator -le 2147483647 -and [bigint]::Abs($Ka)*[bigint]$inverseNumerator+[bigint]::Divide($inverseDenominator,2) -le [uint64]::MaxValue
        if(-not $fits){$inverseDenominator=[long]($inverseDenominator/2)}
    } while(-not $fits -and $inverseDenominator -ge 1)
    if(-not $fits -or $inverseNumerator -lt 1){throw 'Decoder inverse constant cannot be represented within the integer product contract.'}
    $meanDenominator=65535L; $meanNumerator=[int][math]::Round($Mean*$meanDenominator,[MidpointRounding]::ToEven)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$inverseNumerator),0,$Tables,$Offset,4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$inverseDenominator),0,$Tables,$Offset+4,4)
    [Array]::Copy([BitConverter]::GetBytes($meanNumerator),0,$Tables,$Offset+8,4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$meanDenominator),0,$Tables,$Offset+12,4)
}

function New-KokoroDecoderCorpusConstants {
    param([Parameter(Mandatory)][string[]]$Directories,[Parameter(Mandatory)]$Contracts,
        [Parameter(Mandatory)]$Layout,[Parameter(Mandatory)][byte[]]$Tables,[Parameter(Mandatory)][string]$PeachPhonemes)
    $inverseSums=[double[]]::new($Layout.ConstantsBytes/16); $meanSums=[double[]]::new($inverseSums.Length)
    $used=[Collections.Generic.List[object]]::new(); $excluded=[Collections.Generic.List[string]]::new()
    $captures=[Collections.Generic.List[object]]::new(); $coverage=[ordered]@{}
    foreach($contract in $Contracts){
        $site=$contract.Site
        $coverage[$site.Name]=[pscustomobject]@{Site=$site.Name;CapturesUsed=0;
            Captures=[Collections.Generic.List[object]]::new()}
    }
    # Offline statistics use every non-peach utterance in full. Job capacities
    # impose no limit here; accumulator and array types supply the safety bounds.
    foreach($directory in $Directories){
        $capture=Read-KokoroCapture -Directory $directory
        if($capture.Json.phonemes -ceq $PeachPhonemes){$excluded.Add($capture.Root);continue}
        $captures.Add($capture)
        $used.Add([pscustomobject]@{Directory=$capture.Root;Phonemes=$capture.Json.phonemes;IsPeach=$false})
        foreach($contract in $Contracts){
            $site=$contract.Site; $entry=$capture.Json.tensors["$($contract.Norm).input.0"]
            if(-not $entry -or $entry.shape.Count -ne 3 -or $entry.shape[0] -ne 1 -or $entry.shape[1] -ne $contract.RealChannels){throw 'Captured AdaIN input shape differs.'}
            $frames=[long]$entry.shape[2]
            if($frames -lt 1){throw 'Captured AdaIN frames must be at least one.'}
            if($entry.bytes%4 -or ($entry.bytes/4)%$contract.RealChannels -or [bigint]$entry.bytes -ne 4*[bigint]$contract.RealChannels*$frames){throw 'Captured AdaIN input shape differs.'}
            $siteCoverage=$coverage[$site.Name]
            $siteCoverage.Captures.Add([pscustomobject]@{CaptureRoot=$capture.Root;Frames=$frames})
            $siteCoverage.CapturesUsed++
        }
    }
    if(-not $used.Count){throw 'No non-peach training utterances remain.'}
    $bounds=[ordered]@{}
    foreach($contract in $Contracts){
        $site=$contract.Site; $longest=0L
        foreach($observation in $coverage[$site.Name].Captures){$longest=[math]::Max($longest,$observation.Frames)}
        # ChannelStats widens each decoded int16 lane to double before squaring.
        # Requiring integral sums <= 2^53 proves exact double accumulation and
        # safe Int64 casts. BigInteger products do not have fixed-width overflow.
        $sumBound=[bigint]$longest*32768; $squareBound=[bigint]$longest*1073741824L
        $exactDoubleLimit=[bigint]9007199254740992L; $longLimit=[bigint][long]::MaxValue
        if($sumBound -gt $longLimit -or $squareBound -gt $longLimit -or $sumBound -gt $exactDoubleLimit -or $squareBound -gt $exactDoubleLimit){throw "Corpus accumulator overflow assertion failed: $($site.Name), frames=$longest, absSum=$sumBound, squareSum=$squareBound."}
        $epsilonBound=1.0
        foreach($scale in $contract.InputScales){
            if(-not [double]::IsFinite($scale) -or $scale -le 0){throw 'Corpus input scale must be positive and finite.'}
            $epsilon=[math]::Max(1.0,[math]::Round(1e-5*[double]$longest*$longest/($scale*$scale),[MidpointRounding]::ToEven))
            if(-not [double]::IsFinite($epsilon) -or [bigint]$epsilon -gt $longLimit){throw "Corpus epsilon overflow assertion failed: $($site.Name), frames=$longest."}
            $epsilonBound=[math]::Max($epsilonBound,$epsilon)
        }
        $varianceBound=[bigint]$longest*$squareBound+[bigint]$epsilonBound
        $varianceDouble=[double]$varianceBound
        if(-not [double]::IsFinite($varianceDouble) -or [bigint][math]::Ceiling([math]::Sqrt($varianceDouble)) -ge $longLimit-1){throw "Corpus variance/root overflow assertion failed: $($site.Name), frames=$longest."}
        $inverseBound=[double]$used.Count*$longest; $meanBound=[double]$used.Count*32768
        if(-not [double]::IsFinite($inverseBound) -or -not [double]::IsFinite($meanBound)){throw 'Corpus average accumulator overflow assertion failed.'}
        $floatElements=[bigint]$site.Width*$longest
        $nativeBytes=64*[bigint]$site.Width*[bigint]::Divide(([bigint]$longest+31),32)
        if($longest -gt [int]::MaxValue -or $floatElements -gt [Array]::MaxLength -or $nativeBytes -gt [Array]::MaxLength){throw "Corpus array/index overflow assertion failed: $($site.Name), frames=$longest."}
        $bounds[$site.Name]=[pscustomobject]@{Site=$site.Name;LongestFrames=$longest;MaxAbsChannelSum=$sumBound;MaxChannelSquareSum=$squareBound;
            DoubleExactIntegerLimit=$exactDoubleLimit;Int64Limit=$longLimit;MaxEpsilon=$epsilonBound;MaxVarianceNumerator=$varianceBound;
            VarianceArithmetic='BigInteger';MaxCorpusInverseSum=$inverseBound;MaxCorpusAbsMeanSum=$meanBound;FloatElements=$floatElements;NativeBytes=$nativeBytes}
    }
    $population=[ordered]@{Tables=$null;Used=$used.ToArray();Excluded=$excluded.ToArray();Count=$used.Count;
        SiteCoverage=@($coverage.Values);AccumulatorBounds=@($bounds.Values);MeanInverse=$inverseSums;MeanInput=$meanSums}
    foreach($capture in $captures){
        foreach($contract in $Contracts){
            $site=$contract.Site; $width=$site.Width; $real=$contract.RealChannels
            $values=Read-KokoroCaptureTensor -Capture $capture -Name "$($contract.Norm).input.0"
            if($values.Length%$real){throw 'Captured AdaIN input shape differs.'}
            $frames=[int]($values.Length/$real)
            if($frames -lt 1){throw 'Captured AdaIN frames must be at least one.'}
            $padded=[float[]]::new($width*$frames); [Array]::Copy($values,$padded,$values.Length)
            $native=[byte[]]::new(64L*$width*[math]::Ceiling($frames/32))
            (Get-QuantizeCroutons16Kernel).Invoke($padded,$frames,$contract.InputScales,$native)
            (Get-DecodeCroutons16Kernel).Invoke($native,$frames,$width,$padded)
            $sums=[double[]]::new($width); $squares=[double[]]::new($width); $peaks=[double[]]::new($width)
            (Get-ChannelStatsKernel).Invoke($padded,$width,$peaks,$sums,$squares)
            for($channel=0;$channel -lt $width;$channel++){
                if(-not [double]::IsFinite($sums[$channel]) -or -not [double]::IsFinite($squares[$channel]) -or
                    [math]::Abs($sums[$channel]) -gt [double]$bounds[$site.Name].MaxAbsChannelSum -or $squares[$channel] -lt 0 -or
                    $squares[$channel] -gt [double]$bounds[$site.Name].MaxChannelSquareSum -or
                    $sums[$channel] -ne [math]::Truncate($sums[$channel]) -or $squares[$channel] -ne [math]::Truncate($squares[$channel])){throw 'Corpus channel accumulator overflow/integrality assertion failed.'}
                $scale=$contract.InputScales[$channel]
                $eps=[long][math]::Max(1.0,[math]::Round(1e-5*[double]$frames*$frames/($scale*$scale),[MidpointRounding]::ToEven))
                $sum=[long]$sums[$channel]; $d=[bigint]$frames*[long]$squares[$channel]-[bigint]$sum*$sum+$eps
                $root=[long][math]::Floor([math]::Sqrt([double]$d))
                while([bigint]$root*$root -gt $d){$root--}
                while([bigint]($root+1)*($root+1) -le $d){$root++}
                if($root -lt 1){throw 'Captured decoder variance root is zero.'}
                $index=[int]($site.Offset/16+$channel)
                $inverseSums[$index]+=[double]$frames/$root; $meanSums[$index]+=[double]$sum/$frames
                if(-not [double]::IsFinite($inverseSums[$index]) -or -not [double]::IsFinite($meanSums[$index])){throw 'Corpus average is not finite.'}
            }
        }
    }
    $result=[byte[]]::new($Layout.ConstantsParameterBytes); [Array]::Copy($Tables,$result,$Tables.Length)
    foreach($contract in $Contracts){for($channel=0;$channel -lt $contract.Site.Width;$channel++){
        $index=[int]($contract.Site.Offset/16+$channel); $inverseSums[$index]/=$coverage[$contract.Site.Name].CapturesUsed; $meanSums[$index]/=$coverage[$contract.Site.Name].CapturesUsed
        $ka=[BitConverter]::ToInt64($Tables,[int]($contract.RecordOffset+32L*$channel))
        Set-KokoroDecoderConstantRatio -Tables $result -Offset ([int]($Layout.ConstantsTableOffset+$contract.Site.Offset+16L*$channel)) -Inverse $inverseSums[$index] -Mean $meanSums[$index] -Ka $ka
    }}
    $population.Tables=$result
    [pscustomobject]$population
}

function Get-KokoroGeneratorSiteContracts {
    # Reuse the packer's persisted residual and per-stage output units; do not
    # recalibrate or infer scales from rounded epsilon records.
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)]$Layout,[Parameter(Mandatory)][byte[]]$Tables)
    $ten=Get-Content -LiteralPath (Join-Path $Fixture.TenFixture 'fixture.json') -Raw | ConvertFrom-Json
    $sixty=Get-Content -LiteralPath (Join-Path $Fixture.SixtyFixture 'fixture.json') -Raw | ConvertFrom-Json
    $sources=@{'256/resblocks'=$ten.StageFixture;'256/noise_res'=$ten.NoiseResFixture;
        '128/resblocks'=$sixty.StageFixture;'128/noise_res'=$sixty.NoiseResFixture}
    $units=@{}; $metadata=@{}
    foreach($key in $sources.Keys){
        $directory=$sources[$key]; $f=Get-Content -LiteralPath (Join-Path $directory 'fixture.json') -Raw | ConvertFrom-Json
        foreach($file in $f.Files){if((Get-FileHash -LiteralPath (Join-Path $directory $file.Name)).Hash -cne $file.SHA256){throw "Generator scale fixture integrity differs: $key/$($file.Name)."}}
        $bytes=[IO.File]::ReadAllBytes((Join-Path $directory 'stage-output-scales.bin'))
        $values=[double[]]::new($bytes.Length/8); [Buffer]::BlockCopy($bytes,0,$values,0,$bytes.Length)
        if($values.Length -ne 6*$f.Blocks.Count*$f.OutputScales.Count){throw 'Generator output scale extent differs.'}
        $metadata[$key]=$f; $units[$key]=$values
    }
    foreach($site in $Layout.MomentSites){
        $key="$($site.Width)/$($site.Module)"; $f=$metadata[$key]
        $branch=[Array]::IndexOf([int[]]$f.Blocks,[int]$site.Block)
        if($branch -lt 0 -or $f.Frames -ne $site.Frames){throw "Generator scale fixture site differs: $($site.Name)."}
        $scales=[double[]]::new($site.Width)
        if($site.Stage%2){[Array]::Copy($units[$key],($branch*6+$site.Stage-1)*$site.Width,$scales,0,$site.Width)}
        else{[Array]::Copy([double[]]$f.OutputScales,$scales,$site.Width)}
        for($channel=0;$channel -lt $site.Width;$channel++){
            $eps=[uint64][math]::Round(1e-5*[double]$site.Frames*$site.Frames/($scales[$channel]*$scales[$channel]),[MidpointRounding]::ToEven)
            if($eps -ne [BitConverter]::ToUInt64($Tables,[int]($site.RecordOffset+32L*$channel+16))){throw "Generator input scale does not reproduce epsilon at $($site.Name)/$channel."}
        }
        [pscustomobject]@{Site=$site;Norm="generator.$($site.Module).$($site.Block).adain$(1+$site.Stage%2).$([int][math]::Floor($site.Stage/2))";
            InputScales=$scales;RealChannels=$site.Width;RecordOffset=$site.RecordOffset}
    }
}

function Test-KokoroDecoderConstants {
    param([Parameter(Mandatory)][string]$FixtureDirectory,[Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$BaselineLibrary,[ValidateRange(2,4096)][int]$Frames=65,
        [ValidateSet('SM8550','SM8635')][string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro')
    $out=[IO.Path]::GetFullPath($OutputDirectory); $fixture=[IO.Path]::GetFullPath($FixtureDirectory)
    foreach($candidate in $out,$fixture){if(-not $candidate.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Decoder constants gate uses build/ paths only.'}}
    if(Test-Path -LiteralPath $out){throw 'Choose a fresh decoder constants acceptance directory.'}
    [void][IO.Directory]::CreateDirectory($out)
    $report=[ordered]@{Gate='2(a)';Status='Failed';Fixture=$fixture;Soc=$Soc;Frames=$Frames;Stage='Emission';ListeningLabel=''}
    try {
        Import-Evaluator
        . (Join-Path $Root 'src/jobs/Kokoro.DecoderRun16.ps1')
        $layout=Get-KokoroDecoder16Layout -Frames $Frames
        $statistics=Invoke-KokoroEmission -Kernel KokoroDecoder16Run -Parameters @{DecoderFrames=$Frames}
        $report.StatisticsLibrarySHA256=$statistics.LibrarySHA256
        $report.StatisticsByteIdentical=((Get-FileHash -LiteralPath $BaselineLibrary).Hash -ceq $statistics.LibrarySHA256)
        if(-not $report.StatisticsByteIdentical){throw 'Statistics library differs from the pre-change artifact.'}
        $report.Stage='StatisticsRun'
        $referenceRun=Invoke-KokoroDeviceJob -EmissionDirectory $statistics.Directory -EmissionArtifact $statistics -InputDirectory $fixture -Soc $Soc -Runs 1 -Package $Package
        $report.StatisticsOutputPath=$referenceRun.OutputPath; $report.StatisticsDspMs=$referenceRun.MedianMs
        $report.Stage='StatisticsExport'
        $export=Invoke-KokoroEmission -Kernel KokoroDecoder16Run -Parameters @{DecoderFrames=$Frames;DecoderMoments='Export'}
        $observation=Invoke-KokoroDeviceJob -EmissionDirectory $export.Directory -EmissionArtifact $export -InputDirectory $fixture -Soc $Soc -Runs 1 -Package $Package
        for($byte=0;$byte -lt $layout.OutputBytes;$byte++){
            if($referenceRun.Output[256+$byte] -ne $observation.Output[256+$byte]){throw "Statistics Export changes decoder output at byte $byte."}
        }
        $report.Stage='ConstantsTables'
        $table=New-KokoroDecoderConstantsTables -Layout $layout -Tables ([IO.File]::ReadAllBytes((Join-Path $fixture 'tables.bin'))) -Observation $observation.Output
        $constantsInput=Join-Path $out 'constants-input'; [void][IO.Directory]::CreateDirectory($constantsInput)
        foreach($name in 'activations.bin','weights.bin'){[IO.File]::Copy((Join-Path $fixture $name),(Join-Path $constantsInput $name))}
        [IO.File]::WriteAllBytes((Join-Path $constantsInput 'tables.bin'),$table.Tables)
        $report.Sites=$table.Sites; $report.Channels=$table.Channels; $report.TermSource='Fixture statistics; exact rational N/root and S1/N'
        $report.ObservationPath=$observation.OutputPath
        $report.Stage='ConstantsRun'
        $constants=Invoke-KokoroEmission -Kernel KokoroDecoder16Run -Parameters @{DecoderFrames=$Frames;DecoderMoments='Constants'}
        if(@($constants.Steps | Where-Object {$_.Op -eq 'label' -and $_.Name -match '^dec_(moments|coeff)_'}).Count){throw 'Constants library contains a statistics body.'}
        $constantRun=Invoke-KokoroDeviceJob -EmissionDirectory $constants.Directory -EmissionArtifact $constants -InputDirectory $constantsInput -Soc $Soc -Runs 1 -Package $Package
        $report.ConstantsLibrarySHA256=$constants.LibrarySHA256; $report.ConstantsOutputPath=$constantRun.OutputPath; $report.ConstantsDspMs=$constantRun.MedianMs
        $report.ComparedBytes=$layout.OutputBytes
        $report.Stage='DecoderByteComparison'
        for($byte=0;$byte -lt $layout.OutputBytes;$byte++){
            if($referenceRun.Output[256+$byte] -ne $constantRun.Output[256+$byte]){$report.FirstDifferentByte=$byte; throw "Constants decoder output differs at byte $byte."}
        }
        $report.Status='Passed'; $report.Stage='Complete'
    } catch { $report.Error=$_.Exception.Message }
    $result=[pscustomobject]$report
    $result | Export-Clixml -LiteralPath (Join-Path $out 'acceptance-a.clixml')
    $result
}

# Depth-first decoder, delayed tensors (Get-KokoroDecoder16Layout -Delayed: each convolution reads only rows at or before
# the row it writes) against the layer job: both whole-tensor Direct jobs on the phone from the same input, tables, weights
# and K/M (the decoder voice base). x must match byte for byte after the delayed job's output delay. Each frame count is
# a slice of the stock decoder capture's inputs from frame 0; whole-tensor delayed jobs fit VTCM up to 118 frames.
function Test-KokoroDecoderDelayEquivalence {
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',
        [ValidateRange(2,118)][int[]]$Frames=@(100,118),
        [string]$Capture=(Join-Path $Build 'stock-decoder-capture-cal-af_heart-20261008'),
        [string]$DecoderPlan=(Join-Path $Build 'decoder16-plan-af_heart-f128'),
        # A decoder constants table (DecoderVoiceBase); by default the newest under build/streaming-decoder-*.
        [string]$DecoderBase)
    $out=[IO.Path]::GetFullPath($OutputDirectory); if(Test-Path -LiteralPath $out){throw "Output directory already exists: $out"}; [void][IO.Directory]::CreateDirectory($out)
    if(-not $DecoderBase){ $found=@(Get-ChildItem -Path (Join-Path $Build 'streaming-decoder-*/decoder-base.bin') -File -ErrorAction Ignore | Sort-Object LastWriteTime)
        if(-not $found.Count){throw 'No decoder voice base at build/streaming-decoder-*/decoder-base.bin; pass -DecoderBase.'}; $DecoderBase=$found[-1].FullName }
    Import-Evaluator; Import-CaptureKernels; Import-Module (Join-Path $Root 'tools/Kokoro.CaptureMath.psm1')
    . (Join-Path $Root 'src/jobs/Kokoro.DecoderRun16.ps1')
    $plan=Get-Content -LiteralPath (Join-Path $DecoderPlan 'fixture.json') -Raw | ConvertFrom-Json
    $constants=[IO.File]::ReadAllBytes($DecoderBase)
    $cap=Read-KokoroCapture -Directory $Capture
    $aligned=Read-KokoroCaptureTensor -Capture $cap -Name 'decoder.input.0'; $pitch=Read-KokoroCaptureTensor -Capture $cap -Name 'decoder.input.1'; $energy=Read-KokoroCaptureTensor -Capture $cap -Name 'decoder.input.2'
    $total=[int]($aligned.Length/512)
    $rows=foreach($f in $Frames){
        if($f -gt $total){throw "The capture holds $total frames."}
        $a=[float[]]::new(512*$f); for($c=0;$c -lt 512;$c++){ [Array]::Copy($aligned,$c*$total,$a,$c*$f,$f) }
        $p=[float[]]::new(2*$f); [Array]::Copy($pitch,$p,2*$f); $e=[float[]]::new(2*$f); [Array]::Copy($energy,$e,2*$f)
        $layout=Get-KokoroDecoder16Layout -Frames $f
        $activation=ConvertTo-KokoroDecoderInput -Aligned $a -Pitch $p -Energy $e -Capacity $f -Tiles $layout.InputTiles -InputBytes $layout.CorrectedInputBytes -FramesOffset $layout.Input.Frames `
            -AsrScales ([double[]]$plan.AsrScales) -F0CurveScale ([double]$plan.F0CurveScale) -NCurveScale ([double]$plan.NCurveScale) `
            -Coefficients (ConvertTo-KokoroDecoderCoefficients -Tables $constants -Layout $layout) -CoefficientsOffset $layout.Input.KmDeltas
        $directory=Join-Path $out "frames-$f"; [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllBytes((Join-Path $directory 'activations.bin'),$activation)
        foreach($name in 'tables.bin','weights.bin'){ [IO.File]::Copy((Join-Path $DecoderPlan $name),(Join-Path $directory $name)) }
        $jobs=foreach($delayed in $false,$true){
            $parameters=@{DecoderFrames=$f;DecoderMoments='Direct'}; if($delayed){ $parameters.DecoderDelayed=$true }
            $emission=Invoke-KokoroEmission -Kernel KokoroDecoder16Run -Parameters $parameters
            $run=Invoke-KokoroDeviceJob -EmissionDirectory $emission.Directory -EmissionArtifact $emission -InputDirectory $directory -Soc $Soc -Runs 1 -Package $Package
            [pscustomobject]@{Emission=$emission;Run=$run} }
        [IO.File]::Delete((Join-Path $directory 'weights.bin'))
        # x croutons: tile stride 32768, 32-channel blocks of 2048 bytes, a row pair per 128-byte vector; the delay is even.
        $layer=[byte[]]$jobs[0].Run.Output; $delayedOutput=[byte[]]$jobs[1].Run.Output; $at=[long]$jobs[0].Emission.Layout.OutputOffset
        $delayTicks=[int]$jobs[1].Emission.Layout.OutputDelayTicks
        # Different bytes of layer x against delayed x read Shift row pairs later, and the first one.
        $compare={param([int]$shift) $different=0L; $first=$null
            for($pair=0;$pair -lt $f;$pair++){ $q=$pair+$shift
                for($block=0;$block -lt 16;$block++){
                    $ra=$at+32768L*($pair -shr 4)+2048L*$block+128L*($pair -band 15); $ca=$at+32768L*($q -shr 4)+2048L*$block+128L*($q -band 15)
                    if([Linq.Enumerable]::SequenceEqual([ArraySegment[byte]]::new($layer,$ra,128),[ArraySegment[byte]]::new($delayedOutput,$ca,128))){ continue }
                    for($k=0;$k -lt 128;$k++){ if($layer[$ra+$k] -ne $delayedOutput[$ca+$k]){ $different++
                        if($null -eq $first){ $first=[pscustomobject]@{Tick=(2*$pair+(($k -shr 1) -band 1));Channel=(32*$block+($k -shr 2))} } } } } }
            [pscustomobject]@{Different=$different;First=$first} }
        $shifted=& $compare ($delayTicks/2); $unshifted=& $compare 0
        # Controls: x is not the zero fill, and the comparison without the delay finds differences.
        $zeroVector=[byte[]]::new(128); for($k=0;$k -lt 128;$k+=2){ $zeroVector[$k+1]=0x80 }; $live=0
        for($v=0;$v -lt 16*$f;$v++){ if(-not [Linq.Enumerable]::SequenceEqual([ArraySegment[byte]]::new($layer,$at+128L*$v,128),$zeroVector)){ $live++ } }
        [pscustomobject]@{Frames=$f;Ticks=2*$f;OutputDelayTicks=$delayTicks;ComparedBytes=2048L*$f;DifferentBytes=$shifted.Different;FirstDifference=$shifted.First
            UnshiftedDifferentBytes=$unshifted.Different;NonZeroVectors=$live;Vectors=16*$f
            LayerLibrarySHA256=$jobs[0].Emission.LibrarySHA256;DelayedLibrarySHA256=$jobs[1].Emission.LibrarySHA256;LayerDspMs=$jobs[0].Run.MedianMs;DelayedDspMs=$jobs[1].Run.MedianMs
            LayerOutputPath=$jobs[0].Run.OutputPath;DelayedOutputPath=$jobs[1].Run.OutputPath}
    }
    $result=[pscustomobject]@{PSTypeName='Kokoro.DecoderDelayEquivalence';Status=$(if(@($rows | Where-Object { $_.DifferentBytes -ne 0 -or $_.UnshiftedDifferentBytes -eq 0 -or $_.NonZeroVectors -eq 0 }).Count){'Failed'}else{'Passed'});Soc=$Soc
        Capture=[IO.Path]::GetFileName($Capture);DecoderBase=$DecoderBase;Rows=@($rows)}
    $result | Export-Clixml -LiteralPath (Join-Path $out 'decoder-delay-equivalence.clixml') -Depth 5
    $result
}

# PMU records of a profiled generator run: per category and per Unmarked site, ticks (19.2 MHz), cycles, calls and the
# eight event counters (event set A: HVX packets in counter 1; B: permutes in counter 1, HVX packets in counter 7).
function Read-KokoroPmuRecords {
    param([Parameter(Mandatory)][byte[]]$Output,[Parameter(Mandatory)]$PmuProfile,[ValidateSet('A','B')][string]$EventSet='A')
    $categories=@($PmuProfile.Categories); $packets=if($EventSet -ceq 'A'){1}else{7}
    $header=-1; $search=0
    while($search -lt $Output.Length){
        $candidate=[Array]::IndexOf[byte]($Output,0x50,$search); if($candidate -lt 0){break}
        if($candidate+$PmuProfile.SiteRecordOffset+64*$PmuProfile.SiteRecordCount -le $Output.Length -and [BitConverter]::ToUInt32($Output,$candidate) -eq 0x31554d50){if($header -ge 0){throw 'Multiple PMU records found.'};$header=$candidate}
        $search=$candidate+1
    }
    if($header -lt 0 -or [BitConverter]::ToUInt32($Output,$header+28) -ne 0){throw 'Missing PMU record or failed PMU call.'}
    $record={param([long]$at,[hashtable]$Fields)
        $counters=[uint32[]]::new(8); [Buffer]::BlockCopy($Output,$at,$counters,0,32)
        [pscustomobject]($Fields+@{Ticks=[BitConverter]::ToUInt64($Output,$at+32);Ms=[BitConverter]::ToUInt64($Output,$at+32)/19200.0;
            Cycles=[BitConverter]::ToUInt64($Output,$at+40);Calls=[BitConverter]::ToUInt32($Output,$at+48);
            HvxPackets=$counters[$packets];Permutes=$(if($EventSet -ceq 'B'){$counters[1]}else{$null});Counters=$counters})}
    $measurements=[Collections.Generic.List[object]]::new()
    for($index=0;$index -lt $categories.Count;$index++){ $measurements.Add((& $record ($header+256+64*$index) @{Category=$categories[$index]})) }
    $unmarked=@(foreach($site in $PmuProfile.Sites){ & $record ($header+$PmuProfile.SiteRecordOffset+64*$site.Index) @{Index=$site.Index;File=$site.File;MarkLine=$site.MarkLine;PrecedingLine=$site.PrecedingLine;PrecedingStep=$site.PrecedingStep} })
    $unmarkedIndex=[array]::IndexOf($categories,'Unmarked')
    if($unmarkedIndex -lt 0 -or $measurements[$unmarkedIndex].Calls -ne 0){throw 'Unexpected aggregate Unmarked record.'}
    $totalCounters=[ulong[]]::new(8)
    foreach($site in $unmarked){for($counter=0;$counter -lt 8;$counter++){$totalCounters[$counter]+=$site.Counters[$counter]}}
    $ticks=($unmarked | Measure-Object Ticks -Sum).Sum
    $measurements[$unmarkedIndex]=[pscustomobject]@{Category='Unmarked';Ticks=[ulong]$ticks;Ms=$ticks/19200.0;
        Cycles=($unmarked | Measure-Object Cycles -Sum).Sum;Calls=($unmarked | Measure-Object Calls -Sum).Sum;
        HvxPackets=$totalCounters[$packets];Permutes=$(if($EventSet -ceq 'B'){$totalCounters[1]}else{$null});Counters=$totalCounters}
    $categoryTicks=($measurements | Where-Object Category -CNotLike 'Stage.*' | Measure-Object Ticks -Sum).Sum
    $stageTicks=($measurements | Where-Object Category -CLike 'Stage.*' | Measure-Object Ticks -Sum).Sum
    if($categoryTicks -ne $stageTicks){throw "Category/stage accounting differs: $categoryTicks/$stageTicks ticks."}
    [pscustomobject]@{Measurements=$measurements.ToArray();UnmarkedSites=$unmarked}
}

function Test-KokoroGeneratorPmu {
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',
        [string]$Package='dev.mansfieldplumbing.kokoro',
        [ValidateSet('P1','P2','P3','P4')][string[]]$Profiles=@('P1','P3'),
        [ValidateSet('LibraryAndPcm','Pcm')][string]$Parity='LibraryAndPcm',
        [string]$PriorReceipt=(Join-Path $Build 'generator-constants-full-corpus-20261012-143702-run.clixml'))
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh profile directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    $rows=[Collections.Generic.List[object]]::new()
    $totals=[Collections.Generic.List[object]]::new()
    $report=[ordered]@{Status='Failed';Stage='ByteGates';Soc=$Soc;Package=$Package;Parity=$Parity;Profiles=$rows;UnprofiledRuns=$totals}
    try {
        Import-Evaluator
        $prior=Import-Clixml -LiteralPath $PriorReceipt
        if($prior.Gate.Status -cne 'Passed'){throw 'Prior generator constants gate did not pass.'}
        $peach=Join-Path $Root 'data/baselines/decoder-generator-bank-input-sm8550-20261010/input'
        $cases=@(
            @{Name='P1';Kernel='KokoroDecoderGenerator16Run';Parameters=@{ResBlockFrames=10201;ResidentHvxThreads=4;ResidentBatchTiles=14};Input=$peach;Hash='FEFF54DF8340F184FA909C35CFEE48D3F0010F8B37E7C7F0967759403F9672A5';Pcm='E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054'},
            @{Name='P2';Kernel='KokoroGeneratorWholeSource16Run';Parameters=@{ResBlockFrames=10201;ResidentHvxThreads=4;ResidentBatchTiles=14};Input=(Join-Path $prior.OutputDirectory 'A/generator');Hash='13D75D38B0B5BC8695BCAFF49378F860B5E923C80D8F14872321B14854301428';Pcm='E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054'},
            @{Name='P3';Kernel='KokoroGeneratorWholeSource16Run';Parameters=@{ResBlockFrames=10201;ResidentHvxThreads=4;ResidentBatchTiles=14;GeneratorMoments='Constants'};Input=(Join-Path $prior.OutputDirectory 'G/generator');Hash=$prior.Gate.GeneratorLibraries.Constants;Pcm=(@($prior.Gate.Variants | Where-Object Variant -CEQ 'G')[0].PcmSHA256)},
            @{Name='P4';Kernel='KokoroDecoder16Run';Parameters=@{DecoderFrames=85;DecoderMoments='Constants'};Input=(Join-Path $prior.OutputDirectory 'B/decoder');Hash='4E63E1405A5486E70F316679AE143575B9C792FF8F18D09E86F47127436D2DFD'}
        )
        $cases=@($cases | Where-Object {$_.Name -cin $Profiles})
        foreach($case in $cases){
            $report.Stage="$($case.Name)-ByteGate"
            $case.Emission=Invoke-KokoroEmission -Kernel $case.Kernel -Parameters $case.Parameters
            if($Parity -ceq 'LibraryAndPcm' -and $case.Emission.LibrarySHA256 -cne $case.Hash){throw "$($case.Name) unprofiled library differs: expected $($case.Hash), received $($case.Emission.LibrarySHA256)."}
            Write-Host "$($case.Name) UnprofiledLibrary=$($case.Emission.LibrarySHA256) Parity=$Parity"
            if($Parity -ceq 'Pcm'){
                $report.Stage="$($case.Name)-UnprofiledPcmGate"
                $run=Invoke-KokoroDeviceJob -EmissionDirectory $case.Emission.Directory -EmissionArtifact $case.Emission -InputDirectory $case.Input -Soc $Soc -Package $Package -Runs 3
                $samples=[byte[]]::new(2*$case.Emission.Layout.Samples); [Array]::Copy($run.Output,$case.Emission.Layout.PcmOffset,$samples,0,$samples.Length)
                $pcmHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($samples))
                if(-not $case.ContainsKey('Pcm') -or $pcmHash -cne $case.Pcm){throw "$($case.Name) unprofiled PCM differs: expected $($case.Pcm), received $pcmHash."}
                $totals.Add([pscustomobject]@{Profile=$case.Name;LibrarySHA256=$case.Emission.LibrarySHA256;DspMs=$run.MedianMs;PcmSHA256=$pcmHash;OutputPath=$run.OutputPath})
                Write-Host "$($case.Name) UnprofiledDspMs=$($run.MedianMs) PcmParity=True"
            }
        }
        $report.ByteGates=@($cases | ForEach-Object {[pscustomobject]@{Profile=$_.Name;LibrarySHA256=$_.Emission.LibrarySHA256;ReferenceLibrarySHA256=$_.Hash}})
        $events=@{A=[int[]]@(0x3,0x111,0x100,0x101,0x105,0x128,0x129,0x103);
            B=[int[]]@(0x12a,0x12b,0x115,0x116,0x117,0x12c,0x3,0x111)}
        foreach($case in $cases){
            foreach($eventSet in $(if($case.Name -ceq 'P4'){@('Total')}else{@('A','B')})){
                $report.Stage="$($case.Name)-$eventSet"
                $emission=$case.Emission
                if($eventSet -cne 'Total'){
                    $parameters=$case.Parameters.Clone(); $parameters.ResidentPmuEvents=$events[$eventSet]
                    $emission=Invoke-KokoroEmission -Kernel $case.Kernel -Parameters $parameters
                }
                # The resident listener returns only the header and PCM ranges; the PMU records need the whole output.
                $run=Invoke-KokoroDeviceJob -EmissionDirectory $emission.Directory -EmissionArtifact $emission -InputDirectory $case.Input -Soc $Soc -Package $Package -Runs 3 -OneShot
                $samples=[byte[]]::new(2*$emission.Layout.Samples); [Array]::Copy($run.Output,$emission.Layout.PcmOffset,$samples,0,$samples.Length)
                $pcmHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($samples))
                if($case.ContainsKey('Pcm') -and $pcmHash -cne $case.Pcm){throw "$($case.Name) profile PCM differs: expected $($case.Pcm), received $pcmHash."}
                $measurements=@(); $unmarked=@()
                if($eventSet -cne 'Total'){ $records=Read-KokoroPmuRecords -Output $run.Output -PmuProfile $emission.Layout.PmuProfile -EventSet $eventSet; $measurements=$records.Measurements; $unmarked=$records.UnmarkedSites }
                $row=[pscustomobject]@{Profile=$case.Name;EventSet=$eventSet;LibrarySHA256=$emission.LibrarySHA256;DspMs=$run.MedianMs;
                    OutputPath=$run.OutputPath;PcmSHA256=$pcmHash;Measurements=$measurements;UnmarkedSites=$unmarked}
                $rows.Add($row); $row | Export-Clixml -LiteralPath (Join-Path $out "$($case.Name)-$eventSet.clixml") -Depth 8
                Write-Host "$($case.Name) Set=$eventSet DspMs=$($run.MedianMs) PcmParity=True"
                if($case.Name -ceq 'P3' -and $eventSet -ceq 'A'){
                    $hvx=($measurements | Where-Object {$_.Category -cin 'AdaInSnake','Combine','Mean'} | Measure-Object Ms -Sum).Sum
                    $generator=($measurements | Where-Object {$_.Category -cnotlike 'Stage.*'} | Measure-Object Ms -Sum).Sum
                    $report.HvxMathShare=$hvx/$generator
                    $report.HvxDominates=$hvx -gt $generator/2
                }
            }
        }
        $report.Status='Passed'; $report.Stage='Complete'
    } catch {$report.Error=$_.Exception.Message;$report.ErrorPosition=$_.InvocationInfo.PositionMessage;$report.ErrorStack=$_.ScriptStackTrace}
    $result=[pscustomobject]$report; $result | Export-Clixml -LiteralPath (Join-Path $out 'profile.clixml') -Depth 12; $result
}

function Test-KokoroDecoderConstantsCorpus {
    param([Parameter(Mandatory)][string]$PeachFixtureDirectory,[Parameter(Mandatory)][string[]]$CorpusDirectories,
        [Parameter(Mandatory)][string]$OutputDirectory,[ValidateSet('SM8550','SM8635')][string]$Soc='SM8550',
        [string]$Package='dev.mansfieldplumbing.kokoro',[string[]]$GeneratorCaptureDirectories,
        [ValidatePattern('^[0-9A-F]{64}$')][string]$ExpectedDecoderConstantsSHA256)
    $out=[IO.Path]::GetFullPath($OutputDirectory); $peach=[IO.Path]::GetFullPath($PeachFixtureDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh corpus constants directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    $variants=[Collections.Generic.List[object]]::new()
    $report=[ordered]@{Gate='2(b)';Status='Failed';Package=$Package;Soc=$Soc;Stage='Corpus';Variants=$variants}
    try {
        Import-Evaluator
        Import-Module (Join-Path $Root 'tools/Kokoro.CaptureMath.psm1') -Force
        Import-Module (Join-Path $Root 'tools/Kokoro.CaptureKernels.psm1')
        . (Join-Path $Root 'src/jobs/Kokoro.DecoderRun16.ps1')
        # Read preserved reference metadata; all newly manufactured boundaries below are binary or typed objects.
        $whole=Get-Content -LiteralPath (Join-Path $peach 'fixture.json') -Raw | ConvertFrom-Json
        foreach($file in $whole.Files){if((Get-FileHash -LiteralPath (Join-Path $peach $file.Name)).Hash -cne $file.SHA256){throw "Peach reference integrity differs: $($file.Name)."}}
        $decoderDirectory=$whole.DecoderFixture
        $fixture=Get-Content -LiteralPath (Join-Path $decoderDirectory 'fixture.json') -Raw | ConvertFrom-Json
        foreach($file in $fixture.Files){if((Get-FileHash -LiteralPath (Join-Path $decoderDirectory $file.Name)).Hash -cne $file.SHA256){throw "Decoder reference integrity differs: $($file.Name)."}}
        $layout=Get-KokoroDecoder16Layout -Frames $fixture.Frames
        $contracts=@(Get-KokoroDecoderSiteContracts -Fixture $fixture -Layout $layout)
        $peachCapture=Read-KokoroCapture -Directory $fixture.Capture
        $tables=[IO.File]::ReadAllBytes((Join-Path $decoderDirectory 'tables.bin'))
        $corpus=New-KokoroDecoderCorpusConstants -Directories $CorpusDirectories -Contracts $contracts -Layout $layout -Tables $tables -PeachPhonemes $peachCapture.Json.phonemes
        $report.TrainingUtterances=$corpus.Count; $report.Training=$corpus.Used; $report.Excluded=$corpus.Excluded
        $report.DecoderSiteCoverage=$corpus.SiteCoverage; $report.DecoderAccumulatorBounds=$corpus.AccumulatorBounds
        $report.DecoderConstantsSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($corpus.Tables))
        if($ExpectedDecoderConstantsSHA256){
            $report.DecoderConstantsUnchanged=$report.DecoderConstantsSHA256 -ceq $ExpectedDecoderConstantsSHA256
            if(-not $report.DecoderConstantsUnchanged){throw "Decoder corpus constants bytes differ: expected $ExpectedDecoderConstantsSHA256, received $($report.DecoderConstantsSHA256)."}
        }
        $report.NoneIsPeach=(@($corpus.Used | Where-Object IsPeach).Count -eq 0)
        foreach($term in @(@('inverse',$corpus.MeanInverse),@('input',$corpus.MeanInput))){
            $bytes=[byte[]]::new(8*$term[1].Length); [Buffer]::BlockCopy($term[1],0,$bytes,0,$bytes.Length)
            [IO.File]::WriteAllBytes((Join-Path $out "corpus-mean-$($term[0])-f64.bin"),$bytes)
        }
        Write-Host "CorpusUtterances=$($corpus.Count) NoneIsPeach=$($report.NoneIsPeach)"
        $report.Stage='VariantTables'
        $normalizationOff=[byte[]]::new($layout.ConstantsParameterBytes); [Array]::Copy($tables,$normalizationOff,$tables.Length)
        $adainOff=[byte[]]::new($layout.ConstantsParameterBytes); [Array]::Copy($tables,$adainOff,$tables.Length)
        $styleZero=[byte[]]$tables.Clone()
        foreach($contract in $contracts){
            $fcBias=Read-KokoroCaptureTensor -Capture $peachCapture -Name "$($contract.Norm).fc.bias"
            $normWeight=Read-KokoroCaptureTensor -Capture $peachCapture -Name "$($contract.Norm).norm.weight"
            $normBias=Read-KokoroCaptureTensor -Capture $peachCapture -Name "$($contract.Norm).norm.bias"
            for($channel=0;$channel -lt $contract.Site.Width;$channel++){
                $recordAt=[int]($contract.RecordOffset+32L*$channel)
                $constantAt=[int]($layout.ConstantsTableOffset+$contract.Site.Offset+16L*$channel)
                $ka=[BitConverter]::ToInt64($tables,$recordAt)
                # Identity normalization in physical units is inverse = input LSB, mean = 0 in kernel input units.
                Set-KokoroDecoderConstantRatio -Tables $normalizationOff -Offset $constantAt -Inverse $contract.InputScales[$channel] -Mean 0 -Ka $ka
                $identityKa=0L
                if($channel -lt $contract.RealChannels){
                    $target=$contract.TargetScales[$channel]
                    $identityKa=[long][math]::Round(32768/$target,[MidpointRounding]::ToEven)
                    $zeroKa=[long][math]::Round((1+[double]$fcBias[$channel])*$normWeight[$channel]*32768/$target,[MidpointRounding]::ToEven)
                    $zeroMb=[int][math]::Round(((1+[double]$fcBias[$channel])*$normBias[$channel]+$fcBias[$contract.RealChannels+$channel])/$target,[MidpointRounding]::ToEven)
                    [Array]::Copy([BitConverter]::GetBytes($zeroKa),0,$styleZero,$recordAt,8)
                    [Array]::Copy([BitConverter]::GetBytes($zeroMb),0,$styleZero,$recordAt+8,4)
                }
                [Array]::Copy([BitConverter]::GetBytes($identityKa),0,$adainOff,$recordAt,8)
                [Array]::Copy([BitConverter]::GetBytes(0),0,$adainOff,$recordAt+8,4)
                Set-KokoroDecoderConstantRatio -Tables $adainOff -Offset $constantAt -Inverse $contract.InputScales[$channel] -Mean 0 -Ka $identityKa
            }
        }
        $report.Stage='GeneratorInputs'
        $wholeActivation=[IO.File]::ReadAllBytes((Join-Path $peach 'activations.bin'))
        $sourceBytes=$wholeActivation.Length-$layout.InputBytes
        $generatorWeights=[IO.File]::ReadAllBytes((Join-Path $peach 'weights.bin')); $generatorWeightBytes=$generatorWeights.Length-$layout.WeightBytes
        $generatorTables=[IO.File]::ReadAllBytes((Join-Path $peach 'tables.bin')); $generatorTableBytes=$generatorTables.Length-$layout.ParameterBytes
        foreach($pair in @(@('activations.bin',$wholeActivation,$sourceBytes),@('weights.bin',$generatorWeights,$generatorWeightBytes),@('tables.bin',$generatorTables,$generatorTableBytes))){
            $suffix=[byte[]]::new($pair[1].Length-$pair[2]); [Array]::Copy($pair[1],$pair[2],$suffix,0,$suffix.Length)
            if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($suffix)) -cne (Get-FileHash -LiteralPath (Join-Path $decoderDirectory $pair[0])).Hash){throw "Peach joined decoder suffix differs: $($pair[0])."}
        }
        $report.Stage='Emission'
        $statistics=Invoke-KokoroEmission -Kernel KokoroDecoder16Run -Parameters @{DecoderFrames=[int]$fixture.Frames}
        $constants=Invoke-KokoroEmission -Kernel KokoroDecoder16Run -Parameters @{DecoderFrames=[int]$fixture.Frames;DecoderMoments='Constants'}
        $generator=Invoke-KokoroEmission -Kernel KokoroGeneratorWholeSource16Run -Parameters @{ResBlockFrames=[int]$whole.Frames;ResidentHvxThreads=4;ResidentBatchTiles=14}
        if($generator.Layout.InputBytes -ne $layout.OutputBytes+$sourceBytes -or $generator.Layout.WeightBytes -ne $generatorWeightBytes -or $generator.Layout.ParameterBytes -ne $generatorTableBytes -or $generator.Layout.Samples -ne $whole.Samples){throw 'Accepted generator input contract differs.'}
        if($generator.LibrarySHA256 -cne '13D75D38B0B5BC8695BCAFF49378F860B5E923C80D8F14872321B14854301428'){throw 'Statistics generator library differs from the accepted peach library.'}
        Write-Host 'GeneratorStatisticsLibrary=Accepted Emitting=Export,Constants'
        $exportGenerator=Invoke-KokoroEmission -Kernel KokoroGeneratorWholeSource16Run -Parameters @{ResBlockFrames=[int]$whole.Frames;ResidentHvxThreads=4;ResidentBatchTiles=14;GeneratorMoments='Export'}
        $constantGenerator=Invoke-KokoroEmission -Kernel KokoroGeneratorWholeSource16Run -Parameters @{ResBlockFrames=[int]$whole.Frames;ResidentHvxThreads=4;ResidentBatchTiles=14;GeneratorMoments='Constants'}
        if(@($constantGenerator.Steps | Where-Object {$_.Op -eq 'label' -and $_.Name -match '^(body_(moments|coeff)|adainmoments16|turnscoeff)'}).Count){throw 'Constants generator contains a moment or moment-derived coefficient body.'}
        foreach($candidate in $exportGenerator,$constantGenerator){if($candidate.Layout.VtcmBytes -ne $generator.Layout.VtcmBytes){throw 'Generator constants/export changed the VTCM allocation.'}}
        $packing=$generator.Layout.ConstantPacking
        if($packing.MomentSites.Count -ne 48 -or @($packing.MomentSites | Where-Object Module -CEQ 'resblocks').Count -ne 36 -or @($packing.MomentSites | Where-Object Module -CEQ 'noise_res').Count -ne 12){throw 'Generator AdaIN site inventory differs from 36 residual and 12 noise sites.'}
        $report.GeneratorLibraries=[pscustomobject]@{Statistics=$generator.LibrarySHA256;Export=$exportGenerator.LibrarySHA256;Constants=$constantGenerator.LibrarySHA256;VtcmBytes=$generator.Layout.VtcmBytes;ConstantBytes=$packing.ConstantsBytes}
        $generatorOnlyTables=[byte[]]::new($generatorTableBytes); [Array]::Copy($generatorTables,$generatorOnlyTables,$generatorTableBytes)
        $report.Stage='GeneratorSiteContracts'
        $generatorContracts=@(Get-KokoroGeneratorSiteContracts -Fixture $whole -Layout $packing -Tables $generatorOnlyTables)
        if($GeneratorCaptureDirectories -and $GeneratorCaptureDirectories.Count -ne $corpus.Count){throw 'Generator capture directory count differs from the decoder corpus.'}
        $generatorCorpusDirectories=[Collections.Generic.List[string]]::new()
        foreach($training in $corpus.Used){
            $capture=Read-KokoroCapture -Directory $training.Directory
            $leaf=[IO.Path]::GetFileName($capture.Root); $candidate=$null
            if($GeneratorCaptureDirectories){$candidate=$GeneratorCaptureDirectories[$generatorCorpusDirectories.Count]}
            if(-not $candidate -and $leaf.EndsWith('-decoder',[StringComparison]::Ordinal)){
                $sibling=Join-Path ([IO.Path]::GetDirectoryName($capture.Root)) ($leaf.Substring(0,$leaf.Length-7)+'generator')
                if(Test-Path -LiteralPath (Join-Path $sibling 'capture.json')){
                    $cached=Read-KokoroCapture -Directory $sibling
                    if($cached.Json.phonemes -ceq $capture.Json.phonemes -and $cached.Json.seed -eq $capture.Json.seed -and $cached.Json.voice -ceq $capture.Json.voice -and $cached.Json.checkpointSha256 -ceq $capture.Json.checkpointSha256){$candidate=$cached.Root}
                }
            }
            if(-not $candidate){
                $report.Stage="GeneratorCorpusCapture-$($generatorCorpusDirectories.Count)"
                Write-Host "PreparingGeneratorCorpusCapture=$($generatorCorpusDirectories.Count)"
                $candidate=Join-Path $out "generator-corpus-$($generatorCorpusDirectories.Count)"
                & $PSCommandPath StockCapture -Block generator -PhonemesFrom $capture.Root -OutputDirectory $candidate | Out-Null
            }
            $captured=Read-KokoroCapture -Directory $candidate
            if($captured.Json.phonemes -cne $capture.Json.phonemes -or $captured.Json.seed -ne $capture.Json.seed -or $captured.Json.voice -cne $capture.Json.voice -or $captured.Json.checkpointSha256 -cne $capture.Json.checkpointSha256){throw 'Generator corpus utterance, seed, voice or checkpoint differs from the decoder corpus.'}
            $generatorCorpusDirectories.Add($candidate)
        }
        $report.Stage='GeneratorCorpusConstants'
        $generatorCorpus=New-KokoroDecoderCorpusConstants -Directories $generatorCorpusDirectories.ToArray() -Contracts $generatorContracts -Layout $packing -Tables $generatorOnlyTables -PeachPhonemes $peachCapture.Json.phonemes
        $report.GeneratorTraining=$generatorCorpus.Used
        $report.GeneratorSiteCoverage=$generatorCorpus.SiteCoverage
        $report.GeneratorExcluded=$generatorCorpus.Excluded
        $report.GeneratorAccumulatorBounds=$generatorCorpus.AccumulatorBounds
        foreach($siteCoverage in $generatorCorpus.SiteCoverage){Write-Host "GeneratorCorpusSite=$($siteCoverage.Site) Used=$($siteCoverage.CapturesUsed) Frames=$($siteCoverage.Captures.Frames -join ',')"}
        if($generatorCorpus.Count -ne $corpus.Count){throw 'Generator corpus population differs from the decoder corpus.'}
        Write-Host "GeneratorCorpusUtterances=$($generatorCorpus.Count) AdaInSites=$($packing.MomentSites.Count) VtcmBytes=$($generator.Layout.VtcmBytes)"
        $settings=@(@{Name='A';Description='Statistics';Tables=$tables;Emission=$statistics},@{Name='B';Description='Corpus constants';Tables=$corpus.Tables;Emission=$constants},
            @{Name='C';Description='Normalization off';Tables=$normalizationOff;Emission=$constants},@{Name='D';Description='AdaIN off';Tables=$adainOff;Emission=$constants},
            @{Name='E';Description='Zero decoder style vector; statistics normalization';Tables=$styleZero;Emission=$statistics})
        foreach($setting in $settings){$setting.GeneratorEmission=$generator; $setting.GeneratorTables=$generatorOnlyTables}
        $settings+=@(@{Name='F';Description='Decoder constants; generator constants';Tables=$corpus.Tables;Emission=$constants;GeneratorEmission=$constantGenerator;GeneratorTables=$generatorCorpus.Tables},
            @{Name='G';Description='Decoder statistics; generator constants';Tables=$tables;Emission=$statistics;GeneratorEmission=$constantGenerator;GeneratorTables=$generatorCorpus.Tables})
        $settings=@($settings | Where-Object {$_.Name -cin @('A','B','F','G')})
        $accepted=Get-KokoroRatchetCase -Name decoder-generator-bank-input-sm8550
        foreach($variant in $settings){
            $variantGenerator=$variant.GeneratorEmission
            $report.Stage="$($variant.Name)-Decoder"
            $directory=Join-Path $out $variant.Name; $decoderInput=Join-Path $directory 'decoder'; $generatorInput=Join-Path $directory 'generator'
            [void][IO.Directory]::CreateDirectory($decoderInput); [void][IO.Directory]::CreateDirectory($generatorInput)
            foreach($name in 'activations.bin','weights.bin'){[IO.File]::Copy((Join-Path $decoderDirectory $name),(Join-Path $decoderInput $name))}
            [IO.File]::WriteAllBytes((Join-Path $decoderInput 'tables.bin'),$variant.Tables)
            $decoderRun=Invoke-KokoroDeviceJob -EmissionDirectory $variant.Emission.Directory -EmissionArtifact $variant.Emission -InputDirectory $decoderInput -Soc $Soc -Runs 1 -Package $Package
            $generatorActivation=[byte[]]::new($variantGenerator.Layout.InputBytes)
            [Array]::Copy($decoderRun.Output,256,$generatorActivation,0,$layout.OutputBytes)
            [Array]::Copy($wholeActivation,0,$generatorActivation,$layout.OutputBytes,$sourceBytes)
            [IO.File]::WriteAllBytes((Join-Path $generatorInput 'activations.bin'),$generatorActivation)
            $weightPrefix=[byte[]]::new($generatorWeightBytes); [Array]::Copy($generatorWeights,$weightPrefix,$weightPrefix.Length)
            [IO.File]::WriteAllBytes((Join-Path $generatorInput 'weights.bin'),$weightPrefix); [IO.File]::WriteAllBytes((Join-Path $generatorInput 'tables.bin'),$variant.GeneratorTables)
            if($variant.Name -ceq 'A'){
                $report.Stage='GeneratorExportParity'
                $exportRun=Invoke-KokoroDeviceJob -EmissionDirectory $exportGenerator.Directory -EmissionArtifact $exportGenerator -InputDirectory $generatorInput -Soc $Soc -Runs 1 -Package $Package
                $exportMetrics=& (Join-Path $Root 'tools/Measure-KokoroPcmSnr.ps1') -OutputPath $exportRun.OutputPath -FixtureDirectory $peach -PcmOffset $exportGenerator.Layout.PcmOffset -Samples $exportGenerator.Layout.Samples
                if($exportMetrics.PcmSHA256 -cne $accepted.PcmSHA256){throw 'Export generator PCM differs byte for byte from the accepted statistics generator.'}
                $report.ExportPcmSHA256=$exportMetrics.PcmSHA256
                $report.Stage='GeneratorExportTerms'
                $exact=New-KokoroDecoderConstantsTables -Layout $packing -Tables $generatorOnlyTables -Observation $exportRun.Output -OutputOffset 0 -Contracts $generatorContracts
                $exactInput=Join-Path $directory 'generator-exact-constants'; [void][IO.Directory]::CreateDirectory($exactInput)
                foreach($file in 'activations.bin','weights.bin'){[IO.File]::Copy((Join-Path $generatorInput $file),(Join-Path $exactInput $file))}
                [IO.File]::WriteAllBytes((Join-Path $exactInput 'tables.bin'),$exact.Tables)
                $report.Stage='GeneratorExactConstantsParity'
                $exactRun=Invoke-KokoroDeviceJob -EmissionDirectory $constantGenerator.Directory -EmissionArtifact $constantGenerator -InputDirectory $exactInput -Soc $Soc -Runs 1 -Package $Package
                $exactMetrics=& (Join-Path $Root 'tools/Measure-KokoroPcmSnr.ps1') -OutputPath $exactRun.OutputPath -FixtureDirectory $peach -PcmOffset $constantGenerator.Layout.PcmOffset -Samples $constantGenerator.Layout.Samples
                if($exactMetrics.PcmSHA256 -cne $accepted.PcmSHA256){throw 'Generator constants supplied with exported exact ratios differ from statistics PCM.'}
                $report.ExactConstantsPcmSHA256=$exactMetrics.PcmSHA256
                Write-Host 'GeneratorExportParity=True GeneratorExactConstantsParity=True'
            }
            $report.Stage="$($variant.Name)-GeneratorPlayback"
            Write-Host "Playing=$($variant.Name) $($variant.Description)"
            $generatorRun=Invoke-KokoroDeviceJob -EmissionDirectory $variantGenerator.Directory -EmissionArtifact $variantGenerator -InputDirectory $generatorInput -Soc $Soc -Runs 1 -Package $Package
            $wav=Join-Path $out "$($variant.Name).wav"
            $metrics=& (Join-Path $Root 'tools/Measure-KokoroPcmSnr.ps1') -OutputPath $generatorRun.OutputPath -FixtureDirectory $peach -PcmOffset $variantGenerator.Layout.PcmOffset -Samples $variantGenerator.Layout.Samples -WavPath $wav
            $row=[pscustomobject]@{Variant=$variant.Name;Description=$variant.Description;Rms=$metrics.Rms;Peak=$metrics.Peak;ClippedSamples=$metrics.ClippedSamples;
                DecoderDspMs=$decoderRun.MedianMs;GeneratorDspMs=$generatorRun.MedianMs;Samples=$metrics.Samples;PcmSnrDb=$metrics.PcmSnrDb;
                DecoderLibrarySHA256=$variant.Emission.LibrarySHA256;GeneratorLibrarySHA256=$variantGenerator.LibrarySHA256;
                ListeningLabel='';WavPath=$wav;PcmSHA256=$metrics.PcmSHA256;DecoderOutputPath=$decoderRun.OutputPath;GeneratorOutputPath=$generatorRun.OutputPath}
            $variants.Add($row); $row | Export-Clixml -LiteralPath (Join-Path $directory 'receipt.clixml')
            Write-Host "Completed=$($variant.Name) DecoderDspMs=$($row.DecoderDspMs) RMS=$($row.Rms) Peak=$($row.Peak) Clipped=$($row.ClippedSamples)"
            if($variant.Name -ceq 'A' -and $metrics.PcmSHA256 -cne $accepted.PcmSHA256){throw 'A PCM differs from the accepted peach generator hash.'}
        }
        $report.Status='Passed'; $report.Stage='Complete'
    } catch {
        $report.Error=$_.Exception.Message; $report.ErrorPosition=$_.InvocationInfo.PositionMessage; $report.ErrorStack=$_.ScriptStackTrace
    }
    $result=[pscustomobject]$report; $result | Export-Clixml -LiteralPath (Join-Path $out 'acceptance-b.clixml') -Depth 12; $result
}

# Propagation of boundary error to PCM on the phone: Gaussian noise of a known level in x (decoder output), f0 (white per
# tick, or a constant relative offset) or the AdaIN constants (each channel's 1/std and mean) of the accepted peach input to
# the constants generator. The unperturbed run must reproduce the accepted PCM. Each row reports the boundary SNR measured
# after requantization, PCM SNR against the unperturbed run (propagation) and against stock PCM.
function Test-KokoroGeneratorPropagation {
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',
        [double[]]$LevelsDb=@(20,30,40,50,60),[ValidateSet('X','F0','F0Offset','AdaIn')][string[]]$Inputs=@('X','F0','F0Offset','AdaIn'),[int]$Seed=17,
        [string]$PriorReceipt=(Join-Path $Build 'generator-constants-full-corpus-20261012-143702-run.clixml'))
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh propagation directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    Import-Evaluator
    Import-Module (Join-Path $Root 'tools/Kokoro.CaptureKernels.psm1')
    $prior=Import-Clixml -LiteralPath $PriorReceipt
    if($prior.Gate.Status -cne 'Passed'){throw 'Prior generator constants gate did not pass.'}
    $peach=Join-Path $Root 'data/baselines/decoder-generator-bank-input-sm8550-20261010/input'
    $whole=Get-Content -LiteralPath (Join-Path $peach 'fixture.json') -Raw | ConvertFrom-Json
    $source=Join-Path $prior.OutputDirectory 'A/generator-exact-constants'
    $generator=Invoke-KokoroEmission -Kernel KokoroGeneratorWholeSource16Run -Parameters @{ResBlockFrames=[int]$whole.Frames;ResidentHvxThreads=4;ResidentBatchTiles=14;GeneratorMoments='Constants'}
    $activations=[IO.File]::ReadAllBytes((Join-Path $source 'activations.bin')); $tables=[IO.File]::ReadAllBytes((Join-Path $source 'tables.bin'))
    $ticks=[int](($whole.Frames-1)/60); $xBytes=[int]([math]::Ceiling($ticks/32)*64*512); $f0Bytes=[int]([math]::Ceiling(4*$ticks/128)*128)
    if($generator.Layout.InputBytes -ne $activations.Length -or $activations.Length -ne $xBytes+$f0Bytes+128*[math]::Ceiling($whole.Samples/64)){throw 'Generator input layout differs from x, f0 and source draws.'}
    $packing=$generator.Layout.ConstantPacking
    $stockBytes=[IO.File]::ReadAllBytes((Join-Path $peach 'expected-pcm-f32.bin')); $stock=[float[]]::new($whole.Samples); [Buffer]::BlockCopy($stockBytes,0,$stock,0,$stockBytes.Length)
    $snr={param([double[]]$Reference,[double[]]$Candidate) $s=0.0;$e=0.0; for($i=0;$i -lt $Reference.Length;$i++){$d=$Reference[$i]-$Candidate[$i];$s+=$Reference[$i]*$Reference[$i];$e+=$d*$d}; if($e -eq 0){[double]::PositiveInfinity}else{10*[math]::Log10($s/$e)}}
    $random=[Random]::new($Seed)
    $gauss={ $u=1.0-$random.NextDouble(); [math]::Sqrt(-2*[math]::Log($u))*[math]::Cos(2*[math]::PI*$random.NextDouble()) }
    $runConstants={param([string]$Name,[byte[]]$Activation,[byte[]]$Table)
        $directory=Join-Path $out $Name; [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllBytes((Join-Path $directory 'activations.bin'),$Activation); [IO.File]::WriteAllBytes((Join-Path $directory 'tables.bin'),$Table)
        [IO.File]::Copy((Join-Path $source 'weights.bin'),(Join-Path $directory 'weights.bin'))
        $job=Invoke-KokoroDeviceJob -EmissionDirectory $generator.Directory -EmissionArtifact $generator -InputDirectory $directory -Soc $Soc -Runs 1 -Package $Package
        [IO.File]::Delete((Join-Path $directory 'weights.bin'))
        $pcm=[int16[]]::new($whole.Samples); [Buffer]::BlockCopy($job.Output,$generator.Layout.PcmOffset,$pcm,0,2*$whole.Samples)
        $samples=[double[]]::new($pcm.Length); for($i=0;$i -lt $pcm.Length;$i++){$samples[$i]=$pcm[$i]/32768.0}
        [pscustomobject]@{Samples=$samples;PcmSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$job.Output[$generator.Layout.PcmOffset..($generator.Layout.PcmOffset+2*$whole.Samples-1)]));DspMs=$job.MedianMs}}
    $stockSamples=[double[]]$stock
    $accepted=Get-KokoroRatchetCase -Name decoder-generator-bank-input-sm8550
    $base=& $runConstants 'unperturbed' $activations $tables
    if($base.PcmSHA256 -cne $accepted.PcmSHA256){throw 'Unperturbed constants generator PCM differs from the accepted peach PCM.'}
    $rows=[Collections.Generic.List[object]]::new()
    $rows.Add([pscustomobject]@{Input='None';RequestedDb=$null;BoundarySnrDb=$null;PcmSnrDb=[double]::PositiveInfinity;StockSnrDb=(& $snr $stockSamples $base.Samples);DspMs=$base.DspMs})
    $ones=[double[]]::new(512); [Array]::Fill($ones,1.0)
    $x=ConvertFrom-KokoroCroutons16 -Bytes ([byte[]]$activations[0..($xBytes-1)]) -Frames $ticks -Units $ones
    $roundTrip=ConvertTo-KokoroCroutons16 -Values $x -Frames $ticks -Scales $ones
    # The encoder clamps to +-32767; a stored -32768 (biased 0) comes back as -32767 and is the only difference allowed.
    for($i=0;$i -lt $xBytes;$i+=2){
        $stored=[BitConverter]::ToUInt16($activations,$i); $again=[BitConverter]::ToUInt16($roundTrip,$i)
        if($stored -ne $again -and -not ($stored -eq 0 -and $again -eq 1)){throw 'Decoder output croutons do not round-trip.'}
    }
    $f0=[int[]]::new($ticks); [Buffer]::BlockCopy($activations,$xBytes,$f0,0,4*$ticks)
    foreach($boundary in $Inputs){
        foreach($level in $LevelsDb){
            $r=[math]::Pow(10,-$level/20); $activation=[byte[]]$activations.Clone(); $table=[byte[]]$tables.Clone(); $signal=0.0; $noise=0.0
            switch($boundary){
                'X' {
                    $noisy=[float[]]::new($x.Length)
                    for($c=0;$c -lt 512;$c++){
                        $power=0.0; for($t=0;$t -lt $ticks;$t++){$power+=[double]$x[$c*$ticks+$t]*$x[$c*$ticks+$t]}; $rms=[math]::Sqrt($power/$ticks)
                        for($t=0;$t -lt $ticks;$t++){$noisy[$c*$ticks+$t]=[float][math]::Round($x[$c*$ticks+$t]+$rms*$r*(& $gauss))}
                    }
                    $encoded=ConvertTo-KokoroCroutons16 -Values $noisy -Frames $ticks -Scales $ones; [Array]::Copy($encoded,$activation,$xBytes)
                    $decoded=ConvertFrom-KokoroCroutons16 -Bytes $encoded -Frames $ticks -Units $ones
                    for($i=0;$i -lt $x.Length;$i++){$d=[double]$decoded[$i]-$x[$i];$signal+=[double]$x[$i]*$x[$i];$noise+=$d*$d}
                }
                {$_ -in 'F0','F0Offset'} {
                    for($t=0;$t -lt $ticks;$t++){
                        if($f0[$t] -le 0){continue}
                        $g=if($boundary -ceq 'F0Offset'){1.0}else{& $gauss}
                        $value=[int][math]::Round($f0[$t]*(1+$r*$g)); $d=[double]$value-$f0[$t]; $signal+=[double]$f0[$t]*$f0[$t]; $noise+=$d*$d
                        [Array]::Copy([BitConverter]::GetBytes($value),0,$activation,$xBytes+4*$t,4)
                    }
                }
                'AdaIn' {
                    foreach($site in $packing.MomentSites){
                        for($channel=0;$channel -lt $site.Width;$channel++){
                            $at=[int]($packing.ConstantsTableOffset+$site.Offset+16L*$channel)
                            $deviation=[BitConverter]::ToUInt32($table,$at+4); $sum=[BitConverter]::ToInt32($table,$at+8)
                            if($deviation -eq 0){continue}
                            $g1=& $gauss; $g2=& $gauss
                            $newDeviation=[uint32][math]::Max(1,[math]::Round($deviation/(1+$r*$g1))); $newSum=[int][math]::Round($sum+$r*$g2*$deviation)
                            # Relative error of the scale (1/std) and of the mean in units of the channel's std.
                            $scaleError=[double]$deviation/$newDeviation-1; $meanError=([double]$newSum-$sum)/$deviation
                            $signal+=2; $noise+=$scaleError*$scaleError+$meanError*$meanError
                            [Array]::Copy([BitConverter]::GetBytes($newDeviation),0,$table,$at+4,4); [Array]::Copy([BitConverter]::GetBytes($newSum),0,$table,$at+8,4)
                        }
                    }
                }
            }
            $result=& $runConstants ('{0}-{1}dB' -f $boundary,$level) $activation $table
            $row=[pscustomobject]@{Input=$boundary;RequestedDb=$level;BoundarySnrDb=[math]::Round(10*[math]::Log10($signal/[math]::Max($noise,1e-300)),2)
                PcmSnrDb=[math]::Round((& $snr $base.Samples $result.Samples),2);StockSnrDb=[math]::Round((& $snr $stockSamples $result.Samples),2);DspMs=$result.DspMs}
            $rows.Add($row); Write-Host ("Propagation {0} requested={1} boundary={2} pcm={3} stock={4}" -f $row.Input,$row.RequestedDb,$row.BoundarySnrDb,$row.PcmSnrDb,$row.StockSnrDb)
        }
    }
    $report=[pscustomobject]@{Soc=$Soc;Seed=$Seed;Fixture=$peach;Ticks=$ticks;Samples=$whole.Samples;GeneratorLibrarySHA256=$generator.LibrarySHA256;BasePcmSHA256=$base.PcmSHA256;Rows=$rows.ToArray()}
    $report | Export-Clixml -LiteralPath (Join-Path $out 'propagation.clixml') -Depth 6
    $report
}

# Representation of generator AdaIN constants as a voice base plus k components. 170-tick segments of Student syllabus
# evidence (-Corpus, its cached windows) run through the export generator on the phone; each segment's exported 1/std and
# mean per site channel become ln(1/std) and mean/std coordinates. Principal components of the training segments give
# base + P v; each held-out segment (windows with index 7 mod 8) receives its own least-squares v for each k and runs
# through the constants generator, scored against its exported (statistics) PCM. The peach input rebuilt from its stock
# capture at the decoder output scales first checks the input encoding against stock PCM.
function Test-KokoroGeneratorRepresentation {
    param([Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$Corpus,[string]$Soc='SM8550',
        [string]$Package='dev.mansfieldplumbing.kokoro',[ValidateRange(2,4096)][int]$TrainingSegments=48,[ValidateRange(1,64)][int]$HeldOutSegments=4,
        [ValidateRange(0,64)][int[]]$Components=@(0,1,2,3,4,5,6),
        [string]$PriorReceipt=(Join-Path $Build 'generator-constants-full-corpus-20261012-143702-run.clixml'))
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh representation directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    Import-Evaluator
    Import-Module (Join-Path $Root 'tools/Kokoro.CaptureMath.psm1') -Force
    Import-Module (Join-Path $Root 'tools/Kokoro.CaptureKernels.psm1')
    $prior=Import-Clixml -LiteralPath $PriorReceipt
    if($prior.Gate.Status -cne 'Passed'){throw 'Prior generator constants gate did not pass.'}
    $peach=Join-Path $Root 'data/baselines/decoder-generator-bank-input-sm8550-20261010/input'
    $whole=Get-Content -LiteralPath (Join-Path $peach 'fixture.json') -Raw | ConvertFrom-Json
    $decoderFixture=Get-Content -LiteralPath (Join-Path $whole.DecoderFixture 'fixture.json') -Raw | ConvertFrom-Json
    # The generator input is stored at the decoder fixture's DecoderScales (fitted against the stock capture per channel).
    $units=[double[]]$decoderFixture.DecoderScales
    $statistics=Join-Path $prior.OutputDirectory 'A/generator'
    $template=[IO.File]::ReadAllBytes((Join-Path $statistics 'activations.bin')); $statisticsTables=[IO.File]::ReadAllBytes((Join-Path $statistics 'tables.bin'))
    $exportGenerator=Invoke-KokoroEmission -Kernel KokoroGeneratorWholeSource16Run -Parameters @{ResBlockFrames=[int]$whole.Frames;ResidentHvxThreads=4;ResidentBatchTiles=14;GeneratorMoments='Export'}
    $constantGenerator=Invoke-KokoroEmission -Kernel KokoroGeneratorWholeSource16Run -Parameters @{ResBlockFrames=[int]$whole.Frames;ResidentHvxThreads=4;ResidentBatchTiles=14;GeneratorMoments='Constants'}
    $packing=$constantGenerator.Layout.ConstantPacking
    $contracts=@(Get-KokoroGeneratorSiteContracts -Fixture $whole -Layout $packing -Tables $statisticsTables)
    $ticks=[int](($whole.Frames-1)/60); $xBytes=[int]([math]::Ceiling($ticks/32)*64*512)
    if($exportGenerator.Layout.InputBytes -ne $template.Length -or $units.Length -ne 512){throw 'Generator input layout differs from x, f0 and source draws.'}
    $deviceRun={param([string]$Name,$Emission,[byte[]]$Activation,[byte[]]$Table)
        $directory=Join-Path $out $Name; [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllBytes((Join-Path $directory 'activations.bin'),$Activation); [IO.File]::WriteAllBytes((Join-Path $directory 'tables.bin'),$Table)
        [IO.File]::Copy((Join-Path $statistics 'weights.bin'),(Join-Path $directory 'weights.bin'))
        $job=Invoke-KokoroDeviceJob -EmissionDirectory $Emission.Directory -EmissionArtifact $Emission -InputDirectory $directory -Soc $Soc -Runs 1 -Package $Package
        [IO.File]::Delete((Join-Path $directory 'weights.bin'))
        $samples=[double[]]::new($whole.Samples)
        for($i=0;$i -lt $samples.Length;$i++){$samples[$i]=[BitConverter]::ToInt16($job.Output,$Emission.Layout.PcmOffset+2*$i)/32768.0}
        [pscustomobject]@{Output=$job.Output;Samples=$samples;DspMs=$job.MedianMs}}
    $snr={param([double[]]$Reference,[double[]]$Candidate) $s=0.0;$e=0.0; for($i=0;$i -lt $Reference.Length;$i++){$d=$Reference[$i]-$Candidate[$i];$s+=$Reference[$i]*$Reference[$i];$e+=$d*$d}; if($e -eq 0){[double]::PositiveInfinity}else{[math]::Round(10*[math]::Log10($s/$e),2)}}
    # x as stored decoder output croutons at Decode3OutputScales; f0 as int32 Q16 Hz; source draws from the template.
    $encode={param([float[]]$Values,[float[]]$Pitch)
        $encodedInput=[byte[]]$template.Clone(); $saturated=0
        for($c=0;$c -lt 512;$c++){for($t=0;$t -lt $ticks;$t++){if([math]::Abs($Values[$c*$ticks+$t]/$units[$c]) -gt 32767){$saturated++}}}
        [Array]::Copy((ConvertTo-KokoroCroutons16 -Values $Values -Frames $ticks -Scales $units),$encodedInput,$xBytes)
        for($t=0;$t -lt $ticks;$t++){[Array]::Copy([BitConverter]::GetBytes([int][math]::Round([double]$Pitch[$t]*65536)),0,$encodedInput,$xBytes+4*$t,4)}
        [pscustomobject]@{Activation=$encodedInput;Saturated=$saturated}}
    $report=[ordered]@{Soc=$Soc;Corpus=$Corpus;Ticks=$ticks;ExportLibrarySHA256=$exportGenerator.LibrarySHA256;ConstantsLibrarySHA256=$constantGenerator.LibrarySHA256}

    # Input encoding check: the peach stock capture's generator input and f0 at the fixture scales, scored against stock.
    $capture=Read-KokoroCapture -Directory (Get-Content -LiteralPath (Join-Path $whole.SourceFixture 'fixture.json') -Raw | ConvertFrom-Json).Capture
    $peachInput=& $encode ([float[]](Read-KokoroCaptureTensor -Capture $capture -Name 'generator.leaky.0.input')) ([float[]](Read-KokoroCaptureTensor -Capture $capture -Name 'f0'))
    for($t=0;$t -lt $ticks;$t++){if([BitConverter]::ToInt32($peachInput.Activation,$xBytes+4*$t) -ne [BitConverter]::ToInt32($template,$xBytes+4*$t)){throw "Rebuilt peach f0 differs from the fixture at tick $t."}}
    $stockBytes=[IO.File]::ReadAllBytes((Join-Path $peach 'expected-pcm-f32.bin')); $stock=[float[]]::new($whole.Samples); [Buffer]::BlockCopy($stockBytes,0,$stock,0,$stockBytes.Length)
    $peachRun=& $deviceRun 'peach-rebuilt' $exportGenerator $peachInput.Activation $statisticsTables
    $report.PeachRebuiltStockSnrDb=& $snr ([double[]]$stock) $peachRun.Samples; $report.PeachRebuiltSaturated=$peachInput.Saturated
    Write-Host "Representation PeachRebuiltStockSnrDb=$($report.PeachRebuiltStockSnrDb) Saturated=$($peachInput.Saturated)"
    # Stock x must score at least as well as the DSP decoder's x on the same job (the accepted gate's statistics variant).
    $decoderInputSnr=[double](@($prior.Gate.Variants | Where-Object Variant -CEQ 'A')[0].PcmSnrDb)
    if($report.PeachRebuiltStockSnrDb -lt $decoderInputSnr){throw "Rebuilt peach input scores $($report.PeachRebuiltStockSnrDb) dB against stock, below the DSP decoder input's $decoderInputSnr dB; the input encoding is wrong."}

    # Segments from cached syllabus evidence; held-out segments come only from held-out windows.
    $syllabus=& (Join-Path $Root 'student/Invoke-Student.ps1') -Step Syllabus -Corpus $Corpus
    if($syllabus.Rendered){throw 'Representation segments must come from cached syllabus evidence; run the Student Syllabus step first.'}
    $training=[Collections.Generic.List[object]]::new(); $heldOut=[Collections.Generic.List[object]]::new()
    foreach($window in $syllabus.Windows){
        $list=$training; $limit=$TrainingSegments
        if($window.Index%8 -eq 7){$list=$heldOut; $limit=$HeldOutSegments}
        for($start=0;$start+$ticks -le $window.Ticks -and $list.Count -lt $limit;$start+=$ticks){
            $segmentValues=[float[]]::new(512*$ticks); $segmentPitch=[float[]]::new($ticks)
            for($c=0;$c -lt 512;$c++){[Array]::Copy($window.Evidence.X,$c*$window.Ticks+$start,$segmentValues,$c*$ticks,$ticks)}
            [Array]::Copy($window.Evidence.F0,$start,$segmentPitch,0,$ticks)
            if(@($segmentPitch | Where-Object {$_ -gt 0}).Count -eq 0){continue}
            $list.Add([pscustomobject]@{Window=$window.Index;Start=$start;Values=$segmentValues;Pitch=$segmentPitch})
        }
        if($training.Count -ge $TrainingSegments -and $heldOut.Count -ge $HeldOutSegments){break}
    }
    if($training.Count -lt $TrainingSegments -or $heldOut.Count -lt $HeldOutSegments){throw "Corpus supplies $($training.Count) training and $($heldOut.Count) held-out segments."}

    # Export each segment's exact constants; coordinates ln(1/std) and mean/std per site channel.
    $exported={param([string]$Name,$Segment)
        $encoded=& $encode $Segment.Values $Segment.Pitch
        $result=& $deviceRun $Name $exportGenerator $encoded.Activation $statisticsTables
        $exact=New-KokoroDecoderConstantsTables -Layout $packing -Tables $statisticsTables -Observation $result.Output -OutputOffset 0 -Contracts $contracts
        $coordinates=[double[]]::new(2*$exact.Terms.Count)
        for($i=0;$i -lt $exact.Terms.Count;$i++){$coordinates[2*$i]=[math]::Log($exact.Terms[$i].Inverse); $coordinates[2*$i+1]=$exact.Terms[$i].Mean*$exact.Terms[$i].Inverse}
        [pscustomobject]@{Segment=$Segment;Exact=$exact;Coordinates=$coordinates;Samples=$result.Samples;Saturated=$encoded.Saturated;Activation=$encoded.Activation}}
    $trainingRows=@(for($i=0;$i -lt $training.Count;$i++){& $exported "train-$i" $training[$i]})
    $heldOutRows=@(for($i=0;$i -lt $heldOut.Count;$i++){& $exported "held-$i" $heldOut[$i]})
    $dimension=$trainingRows[0].Coordinates.Length; $count=$trainingRows.Count
    $base=[double[]]::new($dimension); foreach($row in $trainingRows){for($d=0;$d -lt $dimension;$d++){$base[$d]+=$row.Coordinates[$d]/$count}}
    $centered=@(foreach($row in $trainingRows){$v=[double[]]::new($dimension); for($d=0;$d -lt $dimension;$d++){$v[$d]=$row.Coordinates[$d]-$base[$d]}; ,$v})
    # Principal components from the Gram matrix of the centered training rows (cyclic Jacobi).
    $gram=[double[,]]::new($count,$count)
    for($i=0;$i -lt $count;$i++){for($j=$i;$j -lt $count;$j++){$s=0.0; $a=$centered[$i]; $b=$centered[$j]; for($d=0;$d -lt $dimension;$d++){$s+=$a[$d]*$b[$d]}; $gram[$i,$j]=$s; $gram[$j,$i]=$s}}
    $vectors=[double[,]]::new($count,$count); for($i=0;$i -lt $count;$i++){$vectors[$i,$i]=1.0}
    for($sweep=0;$sweep -lt 100;$sweep++){
        $off=0.0; for($i=0;$i -lt $count;$i++){for($j=$i+1;$j -lt $count;$j++){$off+=$gram[$i,$j]*$gram[$i,$j]}}
        if($off -lt 1e-22){break}
        for($p1=0;$p1 -lt $count-1;$p1++){for($q1=$p1+1;$q1 -lt $count;$q1++){
            if([math]::Abs($gram[$p1,$q1]) -lt 1e-300){continue}
            $theta=($gram[$q1,$q1]-$gram[$p1,$p1])/(2*$gram[$p1,$q1]); $tangent=[math]::Sign($theta)/([math]::Abs($theta)+[math]::Sqrt($theta*$theta+1)); if($theta -eq 0){$tangent=1.0}
            $cosine=1/[math]::Sqrt($tangent*$tangent+1); $sine=$tangent*$cosine
            for($k1=0;$k1 -lt $count;$k1++){$gp=$gram[$k1,$p1]; $gq=$gram[$k1,$q1]; $gram[$k1,$p1]=$cosine*$gp-$sine*$gq; $gram[$k1,$q1]=$sine*$gp+$cosine*$gq}
            for($k1=0;$k1 -lt $count;$k1++){$gp=$gram[$p1,$k1]; $gq=$gram[$q1,$k1]; $gram[$p1,$k1]=$cosine*$gp-$sine*$gq; $gram[$q1,$k1]=$sine*$gp+$cosine*$gq}
            for($k1=0;$k1 -lt $count;$k1++){$vp=$vectors[$k1,$p1]; $vq=$vectors[$k1,$q1]; $vectors[$k1,$p1]=$cosine*$vp-$sine*$vq; $vectors[$k1,$q1]=$sine*$vp+$cosine*$vq}
        }}
    }
    $order=@(0..($count-1) | Sort-Object { -$gram[$_,$_] }); $total=0.0; foreach($i in $order){$total+=[math]::Max(0,$gram[$i,$i])}
    $axes=[Collections.Generic.List[double[]]]::new(); $explained=[Collections.Generic.List[double]]::new(); $cumulative=0.0
    foreach($i in $order){
        $lambda=$gram[$i,$i]; if($lambda -le 1e-12*$total){break}
        $axis=[double[]]::new($dimension); for($r=0;$r -lt $count;$r++){$weight=$vectors[$r,$i]/[math]::Sqrt($lambda); $row=$centered[$r]; for($d=0;$d -lt $dimension;$d++){$axis[$d]+=$weight*$row[$d]}}
        $axes.Add($axis); $cumulative+=$lambda; $explained.Add([math]::Round($cumulative/$total,6))
    }
    $report.TrainingSegments=$count; $report.Dimension=$dimension; $report.ExplainedVariance=$explained.ToArray()

    # Held-out scoring: the exact constants written through the ratio encoding, then base + top-k components.
    $rows=[Collections.Generic.List[object]]::new(); $siteByName=@{}; foreach($contract in $contracts){$siteByName[$contract.Site.Name]=$contract}
    for($h=0;$h -lt $heldOutRows.Count;$h++){
        $held=$heldOutRows[$h]; $difference=[double[]]::new($dimension); for($d=0;$d -lt $dimension;$d++){$difference[$d]=$held.Coordinates[$d]-$base[$d]}
        foreach($k in @(-1)+$Components){
            if($k -gt $axes.Count){continue}
            $fitted=if($k -lt 0){$held.Coordinates}else{
                $f=[double[]]$base.Clone()
                for($a1=0;$a1 -lt $k;$a1++){$axis=$axes[$a1]; $v=0.0; for($d=0;$d -lt $dimension;$d++){$v+=$axis[$d]*$difference[$d]}; for($d=0;$d -lt $dimension;$d++){$f[$d]+=$v*$axis[$d]}}
                $f}
            $fittedTable=[byte[]]$held.Exact.Tables.Clone(); $noise=0.0
            for($i=0;$i -lt $held.Exact.Terms.Count;$i++){
                $term=$held.Exact.Terms[$i]; $contract=$siteByName[$term.Site]
                $inverse=[math]::Exp($fitted[2*$i]); $mean=$fitted[2*$i+1]/$inverse
                $ka=[BitConverter]::ToInt64($statisticsTables,[int]($contract.RecordOffset+32L*$term.Channel))
                Set-KokoroDecoderConstantRatio -Tables $fittedTable -Offset ([int]($packing.ConstantsTableOffset+$contract.Site.Offset+16L*$term.Channel)) -Inverse $inverse -Mean $mean -Ka $ka
                $scaleError=$inverse/$term.Inverse-1; $meanError=($mean-$term.Mean)*$term.Inverse; $noise+=$scaleError*$scaleError+$meanError*$meanError
            }
            $label=if($k -lt 0){'Exact'}else{"k$k"}
            $result=& $deviceRun "held-$h-$label" $constantGenerator $held.Activation $fittedTable
            $row=[pscustomobject]@{Segment=$h;Window=$held.Segment.Window;Start=$held.Segment.Start;Components=$label
                BoundarySnrDb=if($noise -eq 0){[double]::PositiveInfinity}else{[math]::Round(10*[math]::Log10(2*$held.Exact.Terms.Count/$noise),2)}
                PcmSnrDb=(& $snr $held.Samples $result.Samples);Saturated=$held.Saturated;DspMs=$result.DspMs}
            $rows.Add($row); Write-Host ("Representation segment={0} {1} boundary={2} pcm={3}" -f $h,$label,$row.BoundarySnrDb,$row.PcmSnrDb)
        }
    }
    $report.Rows=$rows.ToArray()
    $report | Export-Clixml -LiteralPath (Join-Path $out 'representation.clixml') -Depth 6
    [pscustomobject]$report
}

# Generator PCM at reduced weight precision on the phone. The 16-bit resblock weights of the accepted constants input are
# requantized per output channel to symmetric n-bit levels (2^(n-1) - 1 steps of max|w| / (2^(n-1) - 1)); each channel's
# group 0 and group 1 table biases absorb the change in its high and low plane row sums (the -128 sumH, -128 sumL terms of
# tools/New-KokoroGenerator60x16Fixture.ps1), so every conv stays exact for its new weights. The unmodified run must
# reproduce the accepted PCM; each variant is scored against it and against stock PCM.
function Test-KokoroGeneratorWeightPrecision {
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',
        [ValidateRange(2,15)][int[]]$Bits=@(8,6,5,4),[ValidateSet('Stage0','Stage1','Both')][string[]]$Scopes=@('Stage0','Stage1','Both'),
        [string]$PriorReceipt=(Join-Path $Build 'generator-constants-full-corpus-20261012-143702-run.clixml'))
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh precision directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    Import-Evaluator
    $prior=Import-Clixml -LiteralPath $PriorReceipt
    if($prior.Gate.Status -cne 'Passed'){throw 'Prior generator constants gate did not pass.'}
    $peach=Join-Path $Root 'data/baselines/decoder-generator-bank-input-sm8550-20261010/input'
    $whole=Get-Content -LiteralPath (Join-Path $peach 'fixture.json') -Raw | ConvertFrom-Json
    $source=Join-Path $prior.OutputDirectory 'A/generator-exact-constants'
    $generator=Invoke-KokoroEmission -Kernel KokoroGeneratorWholeSource16Run -Parameters @{ResBlockFrames=[int]$whole.Frames;ResidentHvxThreads=4;ResidentBatchTiles=14;GeneratorMoments='Constants'}
    $activations=[IO.File]::ReadAllBytes((Join-Path $source 'activations.bin')); $tables=[IO.File]::ReadAllBytes((Join-Path $source 'tables.bin')); $weights=[IO.File]::ReadAllBytes((Join-Path $source 'weights.bin'))
    if($generator.Layout.WeightBytes -ne $weights.Length){throw 'Generator weight layout differs from the accepted weights.'}
    $records=@{}; foreach($site in $generator.Layout.ConstantPacking.MomentSites){if($site.Module -ceq 'resblocks'){$records["$($site.Block).$($site.Stage)"]=[long]$site.RecordOffset}}
    # Decode every resblock stage once: 16-bit value and output channel per byte position (HMX order of
    # Get-PackWeightPlanesShapedKernel: ((g K + k) CB + blk) 2048 + 1024 hh + 128 (i >> 2) + 4 c + (i & 3), o = 64 g + 32 hh + c).
    $stages=[Collections.Generic.List[object]]::new()
    foreach($region in @($generator.Layout.WeightRegions | Where-Object {$_.Name -like 'resblocks.*'})){
        $width=[int]$region.Channels; $kernel=[int]$region.Kernel; $count=$width*$width*$kernel; $blocks=$width/32
        $block=$(if($width -eq 256){0}else{3})+[Array]::IndexOf([int[]]@(3,7,11),$kernel)
        for($st=0;$st -lt 6;$st++){
            $high=[long]$region.Offset+2L*$count*$st; $low=$high+$count
            $values=[int[]]::new($count); $owner=[int[]]::new($count); $peak=[int[]]::new($width); $sumHigh=[long[]]::new($width); $sumLow=[long[]]::new($width)
            for($at=0;$at -lt $count;$at++){
                $hb=[int]$weights[$high+$at]; if($hb -ge 128){$hb-=256}; $lb=[int]$weights[$low+$at]; if($lb -ge 128){$lb-=256}
                $group=[math]::Floor($at/2048); $within=$at%2048
                $o=64*[math]::Floor($group/($kernel*$blocks))+$(if($within -ge 1024){32}else{0})+[math]::Floor(($within%128)/4)
                $v=256*$hb+$lb; $values[$at]=$v; $owner[$at]=$o; $sumHigh[$o]+=$hb; $sumLow[$o]+=$lb
                if([math]::Abs($v) -gt $peak[$o]){$peak[$o]=[math]::Abs($v)}
            }
            $stages.Add([pscustomobject]@{Block=$block;Stage=$st;Width=$width;High=$high;Low=$low;Count=$count;Values=$values;Owner=$owner;Peak=$peak;SumHigh=$sumHigh;SumLow=$sumLow
                Record=$records["$block.$st"];Scope=$(if($width -eq 256){'Stage0'}else{'Stage1'})})
        }
    }
    if($stages.Count -ne 36){throw "Expected 36 resblock stages, found $($stages.Count)."}
    $stockBytes=[IO.File]::ReadAllBytes((Join-Path $peach 'expected-pcm-f32.bin')); $stock=[float[]]::new($whole.Samples); [Buffer]::BlockCopy($stockBytes,0,$stock,0,$stockBytes.Length)
    $snr={param([double[]]$Reference,[double[]]$Candidate) $s=0.0;$e=0.0; for($i=0;$i -lt $Reference.Length;$i++){$d=$Reference[$i]-$Candidate[$i];$s+=$Reference[$i]*$Reference[$i];$e+=$d*$d}; if($e -eq 0){[double]::PositiveInfinity}else{[math]::Round(10*[math]::Log10($s/$e),2)}}
    $deviceRun={param([string]$Name,[byte[]]$WeightBytes,[byte[]]$TableBytes)
        $directory=Join-Path $out $Name; [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllBytes((Join-Path $directory 'activations.bin'),$activations); [IO.File]::WriteAllBytes((Join-Path $directory 'tables.bin'),$TableBytes); [IO.File]::WriteAllBytes((Join-Path $directory 'weights.bin'),$WeightBytes)
        $job=Invoke-KokoroDeviceJob -EmissionDirectory $generator.Directory -EmissionArtifact $generator -InputDirectory $directory -Soc $Soc -Runs 1 -Package $Package
        [IO.File]::Delete((Join-Path $directory 'weights.bin'))
        $samples=[double[]]::new($whole.Samples)
        for($i=0;$i -lt $samples.Length;$i++){$samples[$i]=[BitConverter]::ToInt16($job.Output,$generator.Layout.PcmOffset+2*$i)/32768.0}
        [pscustomobject]@{Samples=$samples;PcmSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$job.Output[$generator.Layout.PcmOffset..($generator.Layout.PcmOffset+2*$whole.Samples-1)]));DspMs=$job.MedianMs}}
    $accepted=Get-KokoroRatchetCase -Name decoder-generator-bank-input-sm8550
    $base=& $deviceRun 'weights16' $weights $tables
    if($base.PcmSHA256 -cne $accepted.PcmSHA256){throw 'Unmodified constants generator PCM differs from the accepted peach PCM.'}
    $rows=[Collections.Generic.List[object]]::new()
    $rows.Add([pscustomobject]@{Bits=16;Scope='None';Weights=0;WeightSnrDb=$null;PcmSnrDb=[double]::PositiveInfinity;StockSnrDb=(& $snr ([double[]]$stock) $base.Samples);DspMs=$base.DspMs})
    foreach($precision in $Bits){
        foreach($part in $Scopes){
            $levels=[math]::Pow(2,$precision-1)-1; $weightCopy=[byte[]]$weights.Clone(); $tableCopy=[byte[]]$tables.Clone(); $signal=0.0; $noise=0.0; $changed=0L
            foreach($stage in @($stages | Where-Object {$part -ceq 'Both' -or $_.Scope -ceq $part})){
                $newHigh=[long[]]::new($stage.Width); $newLow=[long[]]::new($stage.Width)
                for($at=0;$at -lt $stage.Count;$at++){
                    $o=$stage.Owner[$at]; $v=$stage.Values[$at]; $step=$stage.Peak[$o]/$levels
                    $w=[int][math]::Round([math]::Round($v/$step)*$step); $hb=[int][math]::Floor(($w+128)/256); $lb=$w-256*$hb
                    $weightCopy[$stage.High+$at]=[byte]($hb -band 255); $weightCopy[$stage.Low+$at]=[byte]($lb -band 255)
                    $newHigh[$o]+=$hb; $newLow[$o]+=$lb; $signal+=[double]$v*$v; $noise+=[double]($w-$v)*($w-$v)
                }
                $changed+=$stage.Count
                for($o=0;$o -lt $stage.Width;$o++){
                    $ob=[math]::Floor($o/32); $cc=$o%32
                    for($plane=0;$plane -lt 4;$plane++){
                        $at=[int]($stage.Record+32L*$stage.Width+(6*$ob+$plane)*256+128+4*$cc)
                        $delta=if($plane -lt 2){-128L*($newHigh[$o]-$stage.SumHigh[$o])}else{-128L*($newLow[$o]-$stage.SumLow[$o])}
                        $corrected=[long][BitConverter]::ToInt32($tableCopy,$at)+$delta
                        if($corrected -lt [int]::MinValue -or $corrected -gt [int]::MaxValue){throw "Table bias overflow at block $($stage.Block) stage $($stage.Stage) channel $o."}
                        [Array]::Copy([BitConverter]::GetBytes([int]$corrected),0,$tableCopy,$at,4)
                    }
                }
            }
            $result=& $deviceRun ("int{0}-{1}" -f $precision,$part) $weightCopy $tableCopy
            $row=[pscustomobject]@{Bits=$precision;Scope=$part;Weights=$changed;WeightSnrDb=[math]::Round(10*[math]::Log10($signal/[math]::Max($noise,1e-300)),2)
                PcmSnrDb=(& $snr $base.Samples $result.Samples);StockSnrDb=(& $snr ([double[]]$stock) $result.Samples);DspMs=$result.DspMs}
            $rows.Add($row); Write-Host ("Precision int{0} {1} weights={2} weight={3} pcm={4} stock={5}" -f $precision,$part,$changed,$row.WeightSnrDb,$row.PcmSnrDb,$row.StockSnrDb)
        }
    }
    $report=[pscustomobject]@{Soc=$Soc;Fixture=$peach;GeneratorLibrarySHA256=$generator.LibrarySHA256;BasePcmSHA256=$base.PcmSHA256;Rows=$rows.ToArray()}
    $report | Export-Clixml -LiteralPath (Join-Path $out 'precision.clixml') -Depth 6
    $report
}

# Each moment site's K, M and S (Turns layout: K[C], M[C], S[C] int32) from its supplied ratios and its Ka/Mb record, with
# the integer arithmetic of src/kernels/Kokoro.AdaInTurnsCoefficients.ps1 New-KokoroAdaInConstantCoefficientsLoopSteps:
#   K = sign(Ka) q(|Ka| a + b/2, b)      a/b: the site's N/root ratio (u32), |Ka| 64-bit, products modulo 2^64
#   M = Mb - sign(K c) q(|K c| + e/2, e)  c: S1/N numerator (signed), e = (d << 15) modulo 2^32
#   S = the record's S;  q(v, b) = the largest q < 2^31 with q b <= v (the kernel's bit loop).
# -Tables are the job's parameters (records and, at ConstantPacking.ConstantsTableOffset, the ratios); returns the sites'
# K/M/S at their KmOffset, ConstantPacking.KmBytes in all.
function ConvertTo-KokoroGeneratorStageCoefficients {
    param([Parameter(Mandatory)][byte[]] $Tables, [Parameter(Mandatory)] $Layout)
    $packing = $Layout.ConstantPacking; $out = [byte[]]::new([long]$packing.KmBytes)
    foreach ($site in @($packing.MomentSites)) {
        $c = [int]$site.Width; $ratios = [long]$packing.ConstantsTableOffset + [long]$site.Offset; $record = [long]$site.RecordOffset; $at = [long]$site.KmOffset
        for ($ch = 0; $ch -lt $c; $ch++) {
            $km = Get-KokoroConstantCoefficient -Tables $Tables -Ratio ($ratios + 16 * $ch) -Record ($record + 32 * $ch); $sv = [BitConverter]::ToInt32($Tables, $record + 32 * $ch + 12)
            [BitConverter]::GetBytes($km[0]).CopyTo($out, $at + 4 * $ch); [BitConverter]::GetBytes($km[1]).CopyTo($out, $at + 4 * ($c + $ch)); [BitConverter]::GetBytes([int]$sv).CopyTo($out, $at + 4 * (2 * $c + $ch))
        }
    }
    , $out
}

# One channel's K and M as New-KokoroAdaInConstantCoefficientsLoopSteps computes them, from its ratio (16 bytes at
# -Ratio: N/root numerator and denominator, S1/N numerator and denominator) and its record (Ka int64, Mb int32 at
# -Record). Shared by the generator's and the decoder's host coefficients.
function Get-KokoroConstantCoefficient {
    param([Parameter(Mandatory)][byte[]] $Tables, [long] $Ratio, [long] $Record)
    $two64 = [bigint]::Pow(2, 64); $top = [bigint]2147483647
    $quotient = { param([bigint] $v, [bigint] $b) if ($b.IsZero) { return $top }; [bigint]::Min([bigint]::Divide($v, $b), $top) }
    $a = [bigint][BitConverter]::ToUInt32($Tables, $Ratio); $b = [bigint][BitConverter]::ToUInt32($Tables, $Ratio + 4)
    $cn = [bigint][BitConverter]::ToInt32($Tables, $Ratio + 8); $d = [bigint][BitConverter]::ToUInt32($Tables, $Ratio + 12)
    $ka = [bigint][BitConverter]::ToInt64($Tables, $Record); $mb = [BitConverter]::ToInt32($Tables, $Record + 8)
    $q = & $quotient ((([bigint]::Abs($ka) * $a) % $two64 + [bigint]::Divide($b, 2)) % $two64) $b
    $k = [int]$(if ($ka.Sign -lt 0) { -$q } else { $q })
    $e = ($d * 32768) % [bigint]4294967296
    $product = [bigint]$k * $cn
    $r = & $quotient (([bigint]::Abs($product) + [bigint]::Divide($e, 2)) % $two64) $e
    # M wraps modulo 2^32 like the kernel's 32-bit subtraction.
    $wide = ([long]$mb - [long]$(if ($product.Sign -lt 0) { -$r } else { $r })) -band 0xFFFFFFFFL; if ($wide -gt 2147483647L) { $wide -= 4294967296L }
    , [int[]]@($k, [int]$wide)
}

# The decoder's K/M for every site from a constants table, in the Direct mode's input layout (each site at its KmOffset,
# blocked per 32 channels: K at 0 and M at 128 of each 256-byte block).
function ConvertTo-KokoroDecoderCoefficients {
    param([Parameter(Mandatory)][byte[]] $Tables, [Parameter(Mandatory)] $Layout)
    $out = [byte[]]::new([long]$Layout.KmBytes)
    foreach ($site in @($Layout.MomentSites)) {
        $blockIndex = [int][math]::Floor($site.Index / 2); $record = if ($site.Index % 2) { $Layout.BlockParams[$blockIndex].Records2 } else { $Layout.BlockParams[$blockIndex].Records1 }
        for ($ch = 0; $ch -lt [int]$site.Width; $ch++) {
            $km = Get-KokoroConstantCoefficient -Tables $Tables -Ratio ([long]$Layout.ConstantsTableOffset + $site.Offset + 16L * $ch) -Record ([long]$record + 32L * $ch)
            $at = [long]$site.KmOffset + 256L * [math]::Floor($ch / 32) + 4L * ($ch % 32)
            [BitConverter]::GetBytes($km[0]).CopyTo($out, $at); [BitConverter]::GetBytes($km[1]).CopyTo($out, $at + 128)
        }
    }
    , $out
}

# The job's parameters with the finished K/M/S appended where a depth-first layout with host coefficients expects them
# (ConstantPacking.HostCoefficientsOffset); returned unchanged when the layout computes them on the DSP.
function Add-KokoroGeneratorHostCoefficients {
    param([Parameter(Mandatory)][byte[]] $Tables, [Parameter(Mandatory)] $Layout)
    $at = [long]$Layout.ConstantPacking.HostCoefficientsOffset
    if ($at -lt 0) { return , $Tables }
    if ($Tables.Length -gt $at) { throw "Parameters ($($Tables.Length) B) reach past the host coefficients at $at." }
    $kms = ConvertTo-KokoroGeneratorStageCoefficients -Tables $Tables -Layout $Layout
    $out = [byte[]]::new($at + $kms.Length); [Array]::Copy($Tables, $out, $Tables.Length); [Array]::Copy($kms, 0, $out, $at, $kms.Length)
    , $out
}

# The depth-first generator job with the settings its paired phone runs kept (docs/results/
# generator-source-on-dsp-sm8550-20261024.md): K/M/S from the host, queued 256-channel weights, the packed fill, resident
# source sections and 60-tile spans. -Overrides replace any of them (opt-out). A whole-generator layout that does not
# fit VTCM falls back to 40- then 20-tile spans, then to fewer resident sources; the result's DepthFirstSettings and
# DepthFirstParameters say what was emitted. Callers append K/M/S with Add-KokoroGeneratorHostCoefficients.
function Invoke-KokoroGeneratorDepthFirstEmission {
    param([Parameter(Mandatory)][hashtable] $Parameters, [hashtable] $Overrides = @{})
    $kept = @{ GeneratorHostCoefficients = $true; GeneratorAsyncWeights = $true; GeneratorVectorPackets = $true }
    $spanSizes = @(0); $residentSets = @(, [int[]]@())
    if ($Parameters.GeneratorWhole) { $spanSizes = @(60, 40, 20) }
    if ($Parameters.GeneratorSource) { $residentSets = @([int[]]@(128, 256), [int[]]@(128), [int[]]@()) }
    if ($Overrides.ContainsKey('GeneratorSpanTiles')) { $spanSizes = @([int]$Overrides.GeneratorSpanTiles) }
    if ($Overrides.ContainsKey('GeneratorResidentSourceChannels')) { $residentSets = @(, [int[]]@($Overrides.GeneratorResidentSourceChannels)) }
    $rejected = [Collections.Generic.List[string]]::new()
    foreach ($residentSet in $residentSets) {
        foreach ($size in $spanSizes) {
            $p = $Parameters.Clone(); foreach ($key in $kept.Keys) { $p[$key] = $kept[$key] }
            foreach ($key in $Overrides.Keys) { $p[$key] = $Overrides[$key] }
            if ($size) { $p.GeneratorSpanTiles = $size }
            if ($residentSet.Count) { $p.GeneratorResidentSourceChannels = $residentSet } else { $p.Remove('GeneratorResidentSourceChannels') }
            try { $emission = Invoke-KokoroEmission -Kernel KokoroGenerator60x16Run -Parameters $p }
            catch { if ($_.Exception.Message -notmatch 'VTCM') { throw }; $rejected.Add("span $size, resident $($residentSet -join ','): $($_.Exception.Message)"); continue }
            $settings = [pscustomobject]@{ SpanTiles = $size; ResidentSourceChannels = $residentSet; HostCoefficients = [bool]$p.GeneratorHostCoefficients
                AsyncWeights = [bool]$p.GeneratorAsyncWeights; VectorPackets = [bool]$p.GeneratorVectorPackets; Rejected = $rejected.ToArray() }
            $emission | Add-Member -NotePropertyName DepthFirstSettings -NotePropertyValue $settings -Force
            $emission | Add-Member -NotePropertyName DepthFirstParameters -NotePropertyValue $p -Force
            return $emission
        }
    }
    throw "No depth-first layout fits VTCM: $($rejected -join '; ')"
}

# int8 weights in the high plane: q = round(w / 256), clamped to +-127, stored as 256 q (low plane zero). Zero-point
# biases follow the planes (as Test-KokoroGeneratorWeightPrecision): group 0 by -128 (sum q - sum Wh), group 1 by
# 128 sum Wl. HMX weight byte order: ((g K + k) CB + blk) 2048 + 1024 hh + 128 (i >> 2) + 4 c + (i & 3). -Layout is a
# KokoroGenerator60x16Run layout (its ConstantPacking and WeightRegions); -IncludeSource converts noise_res too.
function ConvertTo-KokoroGeneratorInt8 {
    param([Parameter(Mandatory)][byte[]]$Tables,[Parameter(Mandatory)][byte[]]$WeightBytes,[Parameter(Mandatory)]$Layout,[switch]$IncludeSource,
        # The int8 weights and the corrections depend only on the weights and the layout: with a directory they are
        # converted once per weights file and layout, and the tables are corrected from the stored pairs.
        [string]$CacheDirectory)
    if(-not $Layout.ConstantPacking.MomentSites -or -not $Layout.WeightRegions){throw 'The layout has no AdaIN records or weight regions to convert.'}
    $records=@{}; foreach($site in $Layout.ConstantPacking.MomentSites){ $records["$($site.Module).$($site.Block).$($site.Stage)"]=[long]$site.RecordOffset }
    if($CacheDirectory){
        $hash=[Security.Cryptography.IncrementalHash]::CreateHash('SHA256'); $hash.AppendData($WeightBytes)
        $shape=(@($Layout.WeightRegions | ForEach-Object { "$($_.Format)|$($_.Part)|$($_.Name)|$($_.Channels)|$($_.Kernel)|$($_.Offset)" }) + @($records.Keys | Sort-Object | ForEach-Object { "$_=$($records[$_])" }) + "source=$([bool]$IncludeSource)") -join "`n"
        $hash.AppendData([Text.Encoding]::UTF8.GetBytes($shape)); $key=[Convert]::ToHexString($hash.GetHashAndReset())
        $weightsPath=Join-Path $CacheDirectory "$key.weights.bin"; $correctionsPath=Join-Path $CacheDirectory "$key.corrections.bin"
        if((Test-Path -LiteralPath $weightsPath) -and (Test-Path -LiteralPath $correctionsPath)){
            $stored=[IO.File]::ReadAllBytes($correctionsPath); $pairs=[long[]]::new($stored.Length/8); [Buffer]::BlockCopy($stored,0,$pairs,0,$stored.Length)
            $runTables=[byte[]]$Tables.Clone()
            for($i=0;$i -lt $pairs.Length;$i+=2){ $at=[int]$pairs[$i]; $corrected=[long][BitConverter]::ToInt32($runTables,$at)+$pairs[$i+1]
                if($corrected -lt [int]::MinValue -or $corrected -gt [int]::MaxValue){throw "Table bias overflow at table offset $at."}
                [Array]::Copy([BitConverter]::GetBytes([int]$corrected),0,$runTables,$at,4) }
            return [pscustomobject]@{Tables=$runTables;Weights=[IO.File]::ReadAllBytes($weightsPath);Corrections=$pairs}
        }
        $converted=ConvertTo-KokoroGeneratorInt8 -Tables $Tables -WeightBytes $WeightBytes -Layout $Layout -IncludeSource:$IncludeSource
        [void][IO.Directory]::CreateDirectory($CacheDirectory); [IO.File]::WriteAllBytes($weightsPath,$converted.Weights)
        $stored=[byte[]]::new(8*$converted.Corrections.Length); [Buffer]::BlockCopy([long[]]$converted.Corrections,0,$stored,0,$stored.Length); [IO.File]::WriteAllBytes($correctionsPath,$stored)
        return $converted
    }
    $runTables=[byte[]]$Tables.Clone(); $runWeights=[byte[]]$WeightBytes.Clone(); $corrections=[Collections.Generic.List[long]]::new()
    foreach($region in @($Layout.WeightRegions | Where-Object { $_.Format -ceq 'ResblockW16' -and ($_.Part -ceq 'Main' -or $IncludeSource) })){
        $width=[int]$region.Channels; $kernel=[int]$region.Kernel; $count=$width*$width*$kernel; $blocks=$width/32
        $module=if($region.Part -ceq 'Source'){'noise_res'}else{'resblocks'}; $block=if($module -eq 'noise_res'){[int]($region.Name.Split('.')[-1])}else{$(if($width -eq 256){0}else{3})+[Array]::IndexOf([int[]]@(3,7,11),$kernel)}
        for($st=0;$st -lt 6;$st++){
            $high=[long]$region.Offset+2L*$count*$st; $low=$high+$count
            $deltaHigh=[long[]]::new($width); $sumLow=[long[]]::new($width)
            for($at=0;$at -lt $count;$at++){
                $hb=[int]$WeightBytes[$high+$at]; if($hb -ge 128){$hb-=256}; $lb=[int]$WeightBytes[$low+$at]; if($lb -ge 128){$lb-=256}
                $within=$at%2048
                $o=64*[math]::Floor([math]::Floor($at/2048)/($kernel*$blocks))+$(if($within -ge 1024){32}else{0})+[math]::Floor(($within%128)/4)
                $q=[int][math]::Max(-127,[math]::Min(127,[math]::Round((256*$hb+$lb)/256.0,[MidpointRounding]::AwayFromZero)))
                $runWeights[$high+$at]=[byte]($q -band 255); $runWeights[$low+$at]=0
                $deltaHigh[$o]+=$q-$hb; $sumLow[$o]+=$lb
            }
            $record=$records["$module.$block.$st"]
            for($o=0;$o -lt $width;$o++){
                for($plane=0;$plane -lt 4;$plane++){
                    $at=[int]($record+32L*$width+(6*[math]::Floor($o/32)+$plane)*256+128+4*($o%32))
                    $delta=if($plane -lt 2){-128L*$deltaHigh[$o]}else{128L*$sumLow[$o]}
                    $corrected=[long][BitConverter]::ToInt32($runTables,$at)+$delta
                    if($corrected -lt [int]::MinValue -or $corrected -gt [int]::MaxValue){throw "Table bias overflow at block $block stage $st channel $o."}
                    [Array]::Copy([BitConverter]::GetBytes([int]$corrected),0,$runTables,$at,4); $corrections.Add($at); $corrections.Add($delta)
                }
            }
        }
    }
    # Corrections: (table offset, bias delta) pairs, to convert further tables for the same weights without the weights.
    [pscustomobject]@{Tables=$runTables;Weights=$runWeights;Corrections=$corrections.ToArray()}
}

# The Hexagon renderer binding for the Student's controls: Kokoro's decoder (W8, runtime frame count, AdaIN moments of
# its own input) and the source-complete depth-first generator (int8, seeded noise, supplied AdaIN constants) on the
# phone. The decoder's plan is a New-KokoroDecoderFixture.ps1 -Frames build (its capacity); the generator's weights and
# records are the whole-source fixture's.
#   Decode(aligned, f0, n): x croutons from the aligned text encoding ([channel][frame], 512 x F) and the f0 and N curves
#     (2F values each).
#   Constants(x, f0, ticks): the generator AdaIN constants of a stream from the layer export job (at most about 2 s).
#   VoiceBase(constants[]): one voice table, the mean of ln(1/std) and mean/std per site channel.
#   Normalization(table): the table's per-channel normalization terms (site, channel, 1/std, mean), after Constants.
#   NormalizationTable(template, terms): a copy of a constants table with those terms written in.
#   Render(x croutons, f0, ticks, constants): PCM.
# Renders run on the resident listener like exports (ResidentRenders; a one-shot render relaunches the app and starts
# a new listener for the next resident job).
function New-KokoroSpeechRenderer {
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',
        [string]$DecoderPlan=(Join-Path $Build 'decoder16-plan-af_heart-f128'),
        [string]$GeneratorFixture=(Join-Path $Build 'generator-whole-source-fixture-20261008'),[uint32]$Seed=1)
    Import-Evaluator; Import-CaptureKernels
    $plan=Get-Content -LiteralPath (Join-Path $DecoderPlan 'fixture.json') -Raw | ConvertFrom-Json
    if($plan.Graph -cne 'Decoder16' -or -not $plan.PSObject.Properties['AsrScales']){throw 'The decoder plan needs a New-KokoroDecoderFixture.ps1 build that records its input units.'}
    $fixture=Get-Content -LiteralPath (Join-Path $GeneratorFixture 'fixture.json') -Raw | ConvertFrom-Json
    if($fixture.Graph -cne 'Generator16Whole' -or -not $fixture.SourceFixture){throw 'The renderer needs the whole-source generator fixture.'}
    $source=Get-Content -LiteralPath (Join-Path $fixture.SourceFixture 'fixture.json') -Raw | ConvertFrom-Json
    $sum=0.0; foreach($c in $source.HarmonicCoefficients){ $w=[double]$c/(0.1*32768); $sum+=$w*$w }
    $out=[IO.Path]::GetFullPath($OutputDirectory); [void][IO.Directory]::CreateDirectory($out)
    $renderer=[pscustomobject]@{PSTypeName='Kokoro.SpeechRenderer';Directory=$out;Soc=$Soc;Package=$Package;Seed=$Seed;Runs=0
        Capacity=[int]$plan.Frames;AsrScales=[double[]]$plan.AsrScales;F0CurveScale=[double]$plan.F0CurveScale;NCurveScale=[double]$plan.NCurveScale;OutputUnits=[double[]]$plan.DecoderScales
        DecoderWeights=[IO.File]::ReadAllBytes((Join-Path $DecoderPlan 'weights.bin'));DecoderTables=[IO.File]::ReadAllBytes((Join-Path $DecoderPlan 'tables.bin'))
        NoiseScale=[int][math]::Round([math]::Sqrt($sum)*4096*65536/37837.2)
        Statistics=[IO.File]::ReadAllBytes((Join-Path $GeneratorFixture 'tables.bin'));Weights=[IO.File]::ReadAllBytes((Join-Path $GeneratorFixture 'weights.bin'))
        Int8=$null;Packing=$null;DecoderLayout=$null;InputsSHA256=$null;ConstantsCache=(Join-Path $Build 'generator-constants');ResidentRenders=$true}
    $renderer | Add-Member -MemberType ScriptMethod -Name Run -Value { param($Emission,[byte[]]$Activation,[byte[]]$Tables,[byte[]]$WeightBytes,[bool]$OneShot)
        $this.Runs=$this.Runs+1; $directory=Join-Path $this.Directory ('run-{0:d3}' -f $this.Runs); [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllBytes((Join-Path $directory 'activations.bin'),$Activation); [IO.File]::WriteAllBytes((Join-Path $directory 'tables.bin'),$Tables); [IO.File]::WriteAllBytes((Join-Path $directory 'weights.bin'),$WeightBytes)
        try { Invoke-KokoroDeviceJob -EmissionDirectory $Emission.Directory -EmissionArtifact $Emission -InputDirectory $directory -Soc $this.Soc -Runs 1 -Package $this.Package -OneShot:$OneShot }
        finally { [IO.File]::Delete((Join-Path $directory 'weights.bin')) } }
    $renderer | Add-Member -MemberType ScriptMethod -Name GeneratorEmission -Value { param([int]$Ticks,[string]$Kind)
        $parameters=@{ResBlockFrames=60*$Ticks+1;ResidentHvxThreads=4;GeneratorWhole=$true;GeneratorSource=$true;SourceSeededNoise=$true}
        if($Kind -ceq 'Export'){ $parameters+=@{ResidentBatchTiles=22;GeneratorMoments='Export';GeneratorSchedule='Layer'}; return Invoke-KokoroEmission -Kernel KokoroGenerator60x16Run -Parameters $parameters }
        Invoke-KokoroGeneratorDepthFirstEmission -Parameters ($parameters+@{ResidentBatchTiles=4;GeneratorMoments='Constants';GeneratorSchedule='Backward';GeneratorWeightPlanes=1}) }
    $renderer | Add-Member -MemberType ScriptMethod -Name GeneratorInput -Value { param($Emission,[byte[]]$XCroutons,[float[]]$Pitch,[int]$Ticks)
        $noise=$Emission.Layout.SourceNoise; if(-not $noise.Seeded){throw 'The renderer job has no seeded noise.'}
        ConvertTo-KokoroGeneratorInput -XCroutons $XCroutons -Pitch $Pitch -Ticks $Ticks -InputBytes $Emission.Layout.InputBytes -NoiseOffset $noise.InputOffset -Seed $this.Seed -NoiseScale $this.NoiseScale }
    $renderer | Add-Member -MemberType ScriptMethod -Name EncodeX -Value { param([float[]]$X,[int]$Ticks)
        $croutons=[byte[]]::new([long][math]::Ceiling($Ticks/32)*32768); $z=[uint16[]]::new($croutons.Length/2); [Array]::Fill($z,[uint16]0x8000); [Buffer]::BlockCopy($z,0,$croutons,0,$croutons.Length)
        (Get-QuantizeCroutons16Kernel).Invoke($X,$Ticks,$this.OutputUnits,$croutons); ,$croutons }
    $renderer | Add-Member -MemberType ScriptMethod -Name Constants -Value { param([byte[]]$XCroutons,[float[]]$Pitch,[int]$Ticks)
        $emission=$this.GeneratorEmission($Ticks,'Export'); $this.Packing=$emission.Layout.ConstantPacking
        # An export is cached under the hash of everything it depends on (tables, weights, job, x, f0, seed, noise scale),
        # so a measurement resumes after a lost phone and replays without it.
        if(-not $this.InputsSHA256){ $hash=[Security.Cryptography.IncrementalHash]::CreateHash('SHA256'); $hash.AppendData($this.Statistics); $hash.AppendData($this.Weights); $this.InputsSHA256=[Convert]::ToHexString($hash.GetHashAndReset()) }
        $pitchBytes=[byte[]]::new(4*$Pitch.Length); [Buffer]::BlockCopy($Pitch,0,$pitchBytes,0,$pitchBytes.Length)
        $hash=[Security.Cryptography.IncrementalHash]::CreateHash('SHA256')
        foreach($part in @([Text.Encoding]::UTF8.GetBytes("$($this.InputsSHA256)`n$($emission.LibrarySHA256)`n$Ticks`n$($this.Seed)`n$($this.NoiseScale)`n"),$XCroutons,$pitchBytes)){ $hash.AppendData([byte[]]$part) }
        $cached=Join-Path $this.ConstantsCache ([Convert]::ToHexString($hash.GetHashAndReset())+'.bin')
        if(Test-Path -LiteralPath $cached){ $tables=[IO.File]::ReadAllBytes($cached); $terms=@($this.Normalization($tables))
            return [pscustomobject]@{Tables=$tables;Terms=$terms;Channels=$terms.Count;Sites=$this.Packing.MomentSites.Count} }
        $job=$this.Run($emission,$this.GeneratorInput($emission,$XCroutons,$Pitch,$Ticks),$this.Statistics,$this.Weights,$false)
        $export=New-KokoroDecoderConstantsTables -Layout $emission.Layout.ConstantPacking -Tables $this.Statistics -Observation $job.Output -OutputOffset 0 -Contracts @(1)
        [void][IO.Directory]::CreateDirectory($this.ConstantsCache); [IO.File]::WriteAllBytes($cached,$export.Tables)
        $export }
    $renderer | Add-Member -MemberType ScriptMethod -Name VoiceBase -Value { param([object[]]$Exports)
        if(-not $Exports.Count -or -not $this.Packing){throw 'A voice base needs exported constants.'}
        $count=$Exports.Count; $terms=$Exports[0].Terms.Count; $logInverse=[double[]]::new($terms); $standardMean=[double[]]::new($terms)
        foreach($export in $Exports){ for($i=0;$i -lt $terms;$i++){ $term=$export.Terms[$i]; $logInverse[$i]+=[math]::Log($term.Inverse)/$count; $standardMean[$i]+=$term.Mean*$term.Inverse/$count } }
        $this.NormalizationTable($Exports[0].Tables,@(for($i=0;$i -lt $terms;$i++){ $term=$Exports[0].Terms[$i]; $inverse=[math]::Exp($logInverse[$i])
            [pscustomobject]@{Site=$term.Site;Channel=$term.Channel;Inverse=$inverse;Mean=($standardMean[$i]/$inverse)} })) }
    $renderer | Add-Member -MemberType ScriptMethod -Name NormalizationTable -Value { param([byte[]]$Template,[object[]]$Terms)
        $sites=@{}; foreach($site in $this.Packing.MomentSites){ $sites[$site.Name]=$site }
        $table=[byte[]]$Template.Clone()
        foreach($term in $Terms){ $site=$sites[$term.Site]
            Set-KokoroDecoderConstantRatio -Tables $table -Offset ([int]($this.Packing.ConstantsTableOffset+$site.Offset+16L*$term.Channel)) -Inverse $term.Inverse -Mean $term.Mean -Ka ([bigint][BitConverter]::ToInt64($this.Statistics,[int]($site.RecordOffset+32L*$term.Channel))) }
        ,$table }
    $renderer | Add-Member -MemberType ScriptMethod -Name Normalization -Value { param([byte[]]$Table)
        if(-not $this.Packing){throw 'Reading normalization terms needs the export layout (run Constants first).'}
        foreach($site in $this.Packing.MomentSites){ for($c=0;$c -lt $site.Width;$c++){ $at=[int]($this.Packing.ConstantsTableOffset+$site.Offset+16L*$c)
            [pscustomobject]@{Site=$site.Name;Channel=$c;Inverse=[double][BitConverter]::ToUInt32($Table,$at)/[BitConverter]::ToUInt32($Table,$at+4);Mean=[double][BitConverter]::ToInt32($Table,$at+8)/[BitConverter]::ToUInt32($Table,$at+12)} } } }
    # One decoder job over at most Capacity frames: Accumulate (moments measured in the job), Export (also returns them and
    # the coefficients) or Constants (normalization supplied in -Tables).
    $renderer | Add-Member -MemberType ScriptMethod -Name DecoderRun -Value { param([float[]]$Aligned,[float[]]$Pitch,[float[]]$Energy,[string]$Moments='Accumulate',[byte[]]$Tables=$null,[byte[]]$Coefficients=$null)
        $emission=$this.DecoderEmission($Moments); $layout=$emission.Layout
        # Direct: every site's K/M (ConvertTo-KokoroDecoderCoefficients) in the input's KmDeltas region.
        $direct=if($Moments -eq 'Direct'){ @{Coefficients=$Coefficients;CoefficientsOffset=[long]$this.DecoderLayout.Input.KmDeltas} }else{ @{} }
        $activation=ConvertTo-KokoroDecoderInput -Aligned $Aligned -Pitch $Pitch -Energy $Energy -Capacity $this.Capacity -Tiles $layout.Tiles -InputBytes $layout.InputBytes -FramesOffset $layout.FramesOffset -AsrScales $this.AsrScales -F0CurveScale $this.F0CurveScale -NCurveScale $this.NCurveScale @direct
        $job=$this.Run($emission,$activation,$(if($null -ne $Tables){$Tables}else{$this.DecoderTables}),$this.DecoderWeights,$false)
        [pscustomobject]@{Job=$job;Layout=$layout;Frames=[int]($Aligned.Length/512)} }
    $renderer | Add-Member -MemberType ScriptMethod -Name DecoderEmission -Value { param([string]$Moments)
        Invoke-KokoroEmission -Kernel KokoroDecoder16Run -Parameters @{DecoderFrames=$this.Capacity;DecoderRuntimeFrames=$true;DecoderMoments=$Moments} }
    # The decoder's x for a stream. Without -Constants one job measures the stream's own moments (at most Capacity
    # frames). With -Constants (a decoder constants table: an export's or a voice base) any length decodes in chunks of
    # -Interior frames (a multiple of 16, so chunks join on whole 32-tick tiles) with 16 frames of halo each side.
    # With -Constants the chunks run in Direct mode on K/M computed once on the host from the table (-Mode Constants
    # derives them on the DSP in every chunk instead; both give the same x).
    $renderer | Add-Member -MemberType ScriptMethod -Name Decode -Value { param([float[]]$Aligned,[float[]]$Pitch,[float[]]$Energy,[byte[]]$Constants=$null,[int]$Interior=0,[ValidateSet('Direct','Constants')][string]$Mode='Direct')
        $frames=[int]($Aligned.Length/512)
        if($null -eq $Constants){
            $run=$this.DecoderRun($Aligned,$Pitch,$Energy,'Accumulate',$null)
            $xBytes=[long][math]::Ceiling(2*$frames/32)*32768; $x=[byte[]]::new($xBytes); [Array]::Copy($run.Job.Output,[long]$run.Layout.OutputOffset,$x,0,$xBytes)
            return [pscustomobject]@{PSTypeName='Kokoro.DecodedSpeech';Frames=$frames;Ticks=2*$frames;XCroutons=$x;DspMs=$run.Job.MedianMs;Chunks=1}
        }
        if($null -eq $this.DecoderLayout){ . (Join-Path $Root 'src/jobs/Kokoro.DecoderRun16.ps1'); $this.DecoderLayout=Get-KokoroDecoder16Layout -Frames $this.Capacity }
        $coefficients=if($Mode -eq 'Direct'){ ConvertTo-KokoroDecoderCoefficients -Tables $Constants -Layout $this.DecoderLayout }else{ $null }
        $self=$this
        $chunk={ param([float[]]$ChunkAligned,[float[]]$ChunkPitch,[float[]]$ChunkEnergy) $run=$self.DecoderRun($ChunkAligned,$ChunkPitch,$ChunkEnergy,$Mode,$Constants,$coefficients)
            [pscustomobject]@{Output=$run.Job.Output;OutputOffset=$run.Layout.OutputOffset;DspMs=$run.Job.MedianMs} }
        Invoke-KokoroDecoderChunks -Aligned $Aligned -Pitch $Pitch -Energy $Energy -Capacity $this.Capacity -Interior $Interior -RunChunk $chunk }
    # A stretch of exactly Capacity frames: its exported decoder moments as a constants table and their terms.
    $renderer | Add-Member -MemberType ScriptMethod -Name DecoderConstants -Value { param([float[]]$Aligned,[float[]]$Pitch,[float[]]$Energy)
        if([int]($Aligned.Length/512) -ne $this.Capacity){throw "Decoder constants are exported from stretches of exactly $($this.Capacity) frames."}
        $run=$this.DecoderRun($Aligned,$Pitch,$Energy,'Export',$null)
        if($null -eq $this.DecoderLayout){ . (Join-Path $Root 'src/jobs/Kokoro.DecoderRun16.ps1'); $this.DecoderLayout=Get-KokoroDecoder16Layout -Frames $this.Capacity }
        $layout=$this.DecoderLayout; $offset=[long]$run.Layout.OutputOffset
        $observation=[byte[]]::new($offset+$layout.OutputBytes+$layout.MomentsBytes+$layout.KmBytes); [Array]::Copy($run.Job.Output,$observation,$observation.Length)
        New-KokoroDecoderConstantsTables -Layout $layout -Tables $this.DecoderTables -Observation $observation -OutputOffset $offset }
    # The decoder's voice base: per site and channel the geometric mean of the exports' inverse deviations and the mean of
    # their standardized means (as VoiceBase does for the generator).
    $renderer | Add-Member -MemberType ScriptMethod -Name DecoderVoiceBase -Value { param([object[]]$Exports)
        if(-not $Exports.Count -or -not $this.DecoderLayout){throw 'A decoder voice base needs exported decoder constants.'}
        $layout=$this.DecoderLayout; $count=$Exports.Count; $terms=$Exports[0].Terms.Count; $logInverse=[double[]]::new($terms); $standardMean=[double[]]::new($terms)
        foreach($export in $Exports){ for($i=0;$i -lt $terms;$i++){ $term=$export.Terms[$i]; $logInverse[$i]+=[math]::Log($term.Inverse)/$count; $standardMean[$i]+=$term.Mean*$term.Inverse/$count } }
        $sites=@{}; foreach($site in $layout.MomentSites){ $sites[$site.Name]=$site }
        $table=[byte[]]$Exports[0].Tables.Clone()
        for($i=0;$i -lt $terms;$i++){ $term=$Exports[0].Terms[$i]; $site=$sites[$term.Site]; $inverse=[math]::Exp($logInverse[$i])
            $blockIndex=[int][math]::Floor($site.Index/2); $recordAt=if($site.Index%2){$layout.BlockParams[$blockIndex].Records2}else{$layout.BlockParams[$blockIndex].Records1}
            Set-KokoroDecoderConstantRatio -Tables $table -Offset ([int]($layout.ConstantsTableOffset+$site.Offset+16L*$term.Channel)) -Inverse $inverse -Mean ($standardMean[$i]/$inverse) -Ka ([bigint][BitConverter]::ToInt64($this.DecoderTables,[int]($recordAt+32L*$term.Channel))) }
        ,$table }
    $renderer | Add-Member -MemberType ScriptMethod -Name Render -Value { param([byte[]]$XCroutons,[float[]]$Pitch,[int]$Ticks,[byte[]]$Constants,[object]$Resident=$null)
        $onResident=if($null -eq $Resident){[bool]$this.ResidentRenders}else{[bool]$Resident}
        $generator=$this.GeneratorJob($Ticks,$Constants); $emission=$generator.Emission
        $job=$this.Run($emission,$this.GeneratorInput($emission,$XCroutons,$Pitch,$Ticks),$generator.Tables,$generator.Weights,-not $onResident)
        $pcm=ConvertFrom-KokoroPcm16 -Output $job.Output -Offset $emission.Layout.PcmOffset -Samples (300*$Ticks)
        [pscustomobject]@{PSTypeName='Kokoro.GeneratorRendering';Ticks=$Ticks;Pcm=$pcm;DspMs=$job.MedianMs;LibrarySHA256=$emission.LibrarySHA256} }
    # The depth-first generator job for Ticks with supplied normalization (-Constants): its emission, tables (the int8
    # corrections and host coefficients applied) and int8 weights.
    $renderer | Add-Member -MemberType ScriptMethod -Name GeneratorJob -Value { param([int]$Ticks,[byte[]]$Constants)
        $emission=$this.GeneratorEmission($Ticks,'Constants')
        if($null -eq $this.Int8){ $this.Int8=ConvertTo-KokoroGeneratorInt8 -Tables $Constants -WeightBytes $this.Weights -Layout $emission.Layout -IncludeSource -CacheDirectory (Join-Path $Build 'generator-int8') }
        $tables=[byte[]]$Constants.Clone(); $corrections=$this.Int8.Corrections
        for($i=0;$i -lt $corrections.Length;$i+=2){ $at=[int]$corrections[$i]; [Array]::Copy([BitConverter]::GetBytes([int]([long][BitConverter]::ToInt32($tables,$at)+$corrections[$i+1])),0,$tables,$at,4) }
        $tables=Add-KokoroGeneratorHostCoefficients -Tables $tables -Layout $emission.Layout
        [pscustomobject]@{Emission=$emission;Tables=$tables;Weights=$this.Int8.Weights} }
    $renderer
}

# Student speech on the phone: text through our phonemizer and the Student's prosody (host), Kokoro's text encoder
# (host), and the decoder and generator on the DSP (New-KokoroSpeechRenderer; Student -Step Speak with the renderer).
function Invoke-KokoroStudentSpeech {
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',[Parameter(Mandatory)][string]$Text,[hashtable]$Student=@{})
    $renderer=New-KokoroSpeechRenderer -OutputDirectory (Join-Path $OutputDirectory 'renderer') -Soc $Soc -Package $Package
    & (Join-Path $Root 'student/Invoke-Student.ps1') -Step Speak -Text $Text -State $renderer -OutputPath $OutputDirectory @Student
}

# The generator's AdaIN normalization on the phone without the Student (Student -Step Normalization with the renderer):
# exported moments of syllabus stretches, their profile-plus-level fit, and held-out renders with matched moments, the
# voice base, and the profile with each stream's own level per site.
function Invoke-KokoroGeneratorNormalization {
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro')
    $renderer=New-KokoroSpeechRenderer -OutputDirectory (Join-Path $OutputDirectory 'renderer') -Soc $Soc -Package $Package
    & (Join-Path $Root 'student/Invoke-Student.ps1') -Step Normalization -State $renderer -OutputPath $OutputDirectory
}

# A declared score (Student -Step Score with the renderer, no Student): its phones, durations and notes through the host
# text encoder, the DSP decoder and the generator, with the voice base and with the score's own moments.
function Invoke-KokoroGeneratorScore {
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro')
    $renderer=New-KokoroSpeechRenderer -OutputDirectory (Join-Path $OutputDirectory 'renderer') -Soc $Soc -Package $Package
    & (Join-Path $Root 'student/Invoke-Student.ps1') -Step Score -State $renderer -OutputPath $OutputDirectory
}

# Text to WAV on the phone in one process: our phonemizer and the stock front end on the CPU, the decoder (chunks on its
# voice base) and the depth-first generator (on its voice base) on the DSP, all in the app's runspace
# (src/runspace/KokoroGeneratorTailProbe.ps1 speech mode, packing shared with the renderer through
# Kokoro.CaptureKernels.psm1). The host supplies what the phone does not build: the front end's prebuilt numeric kernels,
# the decoder library and the generator library for this text's length, their tables and weights. The same text through
# the host front end and the renderer is the reference the phone's WAV is compared with.
function Invoke-KokoroPhoneSpeech {
    param([Parameter(Mandatory)][string]$Text,[string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',[ValidateRange(1,20)][int]$Runs=3,
        # The voice bases (a decoder constants table, DecoderVoiceBase; generator constants, VoiceBase); by default the newest under build/.
        [string]$DecoderBase,[string]$GeneratorBase,
        [string]$Phonemizer='build/phonemizer/english/driver/340D763896245937C41417BF7D3D197B6FE407AC750130B9299062E4D3152348-library-dll')
    $out=if($OutputDirectory){[IO.Path]::GetFullPath($OutputDirectory)}else{Join-Path $Build ('phone-speech-{0:yyyyMMddTHHmmss}' -f [DateTime]::UtcNow)}
    if(Test-Path -LiteralPath $out){throw "Output directory already exists: $out"}; [void][IO.Directory]::CreateDirectory($out)
    $newest={param([string]$Given,[string]$Wildcard,[string]$What)
        if($Given){ if(-not (Test-Path -LiteralPath $Given -PathType Leaf)){throw "$What not found: $Given"}; return [IO.Path]::GetFullPath($Given) }
        $found=@(Get-ChildItem -Path (Join-Path $Build $Wildcard) -File -ErrorAction Ignore | Sort-Object LastWriteTime)
        if(-not $found.Count){throw "No $What at build/$Wildcard; pass it explicitly."}; $found[-1].FullName }
    $decoderBasePath=& $newest $DecoderBase 'streaming-decoder-*/decoder-base.bin' 'decoder voice base'
    $generatorBasePath=& $newest $GeneratorBase 'student/voice/af_heart/adain-base-*.bin' 'generator voice base'
    $decoderBaseBytes=[IO.File]::ReadAllBytes($decoderBasePath); $generatorBaseBytes=[IO.File]::ReadAllBytes($generatorBasePath)
    $driverDirectory=Join-Path $Root $Phonemizer; $driverReceipt=Import-PowerShellDataFile (Join-Path $driverDirectory 'driver-receipt.psd1')
    $driverPath=Join-Path $driverDirectory ([IO.Path]::GetFileName($driverReceipt.Output))
    if((Get-FileHash -LiteralPath $driverPath).Hash -cne $driverReceipt.AssemblySha256){throw 'Compiled English phonemizer integrity mismatch.'}
    $phonemize=[Reflection.Assembly]::LoadFrom($driverPath).GetType('CoreDriver',$true).GetMethod('Run').CreateDelegate([Func[string,object]])
    # The host front end compiles the numeric kernels the phone loads prebuilt, and gives this text's tick count.
    $port=New-Module -Name KokoroPhoneSpeechHost -ArgumentList (Join-Path $Root 'tools/Invoke-KokoroPrecomputedDecoder.ps1'),(Join-Path $out 'port'),8 -ScriptBlock {
        param([string]$Reference,[string]$Output,[int]$WorkerThreads) . $Reference -Mode Library -OutputDirectory $Output -Threads $WorkerThreads; Export-ModuleMember -Function Invoke-OfflineSpeech,Write-OfflineWave }
    try {
        $phonemes=[string]$phonemize.Invoke($Text).KokoroPhones; if(-not $phonemes){throw 'The phonemizer gave no phonemes for this text.'}
        $front=Invoke-OfflineSpeech -Phonemes $phonemes -Voice af_heart -SkipDecoder
        $frames=[int](([int[]]$front.Durations | Measure-Object -Sum).Sum); $ticks=2*$frames
        $renderer=New-KokoroSpeechRenderer -OutputDirectory (Join-Path $out 'renderer') -Soc $Soc -Package $Package
        . (Join-Path $Root 'src/jobs/Kokoro.DecoderRun16.ps1'); $renderer.DecoderLayout=Get-KokoroDecoder16Layout -Frames $renderer.Capacity
        $decoderEmission=$renderer.DecoderEmission('Direct'); $generator=$renderer.GeneratorJob($ticks,$generatorBaseBytes)
        # Reference: the host front end's outputs through the renderer on the resident listener.
        $decoded=$renderer.Decode([float[]]$front.Aligned,[float[]]$front.F0,[float[]]$front.N,$decoderBaseBytes,0)
        $rendering=$renderer.Render($decoded.XCroutons,[float[]]$front.F0,$decoded.Ticks,$generatorBaseBytes)
        $referenceWave=Join-Path $out 'reference.wav'; Write-OfflineWave $referenceWave $rendering.Pcm
        Stop-KokoroDeviceSession
        $kernelDll=@(Get-ChildItem (Join-Path $out 'port') -Recurse -Filter 'Kokoro.OfflineRender.dll')[0].FullName
    } finally { Remove-Module -ModuleInfo $port -Force }
    # The pack: the generator job's fixture (input of zeros, tables, weights) and the decoder's library, tables, weights
    # and K/M, with the layout fields and units the phone packs inputs with.
    $pack=Join-Path $out 'pack'; [void][IO.Directory]::CreateDirectory($pack)
    $put={param([string]$Name,[byte[]]$Bytes) [IO.File]::WriteAllBytes((Join-Path $pack $Name),$Bytes)}
    & $put 'activations.bin' ([byte[]]::new($generator.Emission.Layout.InputBytes)); & $put 'tables.bin' $generator.Tables; & $put 'weights.bin' $generator.Weights
    [IO.File]::Copy($decoderEmission.Path,(Join-Path $pack 'decoder.so')); & $put 'decoder-tables.bin' $renderer.DecoderTables; & $put 'decoder-weights.bin' $renderer.DecoderWeights
    & $put 'decoder-coefficients.bin' (ConvertTo-KokoroDecoderCoefficients -Tables $decoderBaseBytes -Layout $renderer.DecoderLayout)
    [IO.File]::WriteAllText((Join-Path $pack 'speech-text.txt'),$Text)
    $decoderLayout=$decoderEmission.Layout
    [ordered]@{Voice='af_heart';Ticks=$ticks;DecoderCapacity=$renderer.Capacity;DecoderTiles=[int]$decoderLayout.Tiles;DecoderInputBytes=[long]$decoderLayout.InputBytes
        DecoderFramesOffset=[long]$decoderLayout.FramesOffset;DecoderCoefficientsOffset=[long]$renderer.DecoderLayout.Input.KmDeltas;DecoderOutputBytes=[int]$decoderLayout.OutputBytes
        DecoderPcmOffset=[int]$decoderLayout.PcmOffset;DecoderSamples=[int]$decoderLayout.Samples;DecoderOutputOffset=[long]$decoderLayout.OutputOffset
        AsrScales=$renderer.AsrScales;F0CurveScale=$renderer.F0CurveScale;NCurveScale=$renderer.NCurveScale
        NoiseOffset=[long]$generator.Emission.Layout.SourceNoise.InputOffset;Seed=[uint32]$renderer.Seed;NoiseScale=[int]$renderer.NoiseScale} |
        ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $pack 'speech-pack.json') -Encoding utf8NoBOM
    # Files the phone loads besides the job's: the shared packing, the speech pack, and the front end in its repository layout.
    $revision='f3ff3571791e39611d31c381e3a41a3af07b4987'
    $encoderSource=Join-Path $Root 'src/frontend/Kokoro.TextEncoder.ps1'; $encoderDirectory="build/frontend/encoder/$((Get-FileHash -LiteralPath $encoderSource).Hash)/bb0f67a2bf16e54086c35ff96c0d8a5e523f0519"
    $compiler='build/lowered-hexagon/compiler/6900FC735D5F463ECFDB0241B326D959CF7A8B8A252B56B1A7734F20D3BD9BD6/Export-LoweredAssembly.ps1'
    $stage=@{'kokoro/Kokoro.CaptureKernels.psm1'=(Join-Path $Root 'tools/Kokoro.CaptureKernels.psm1')
        'kokoro-frontend/build/prebuilt/Kokoro.OfflineRender.dll'=$kernelDll; 'kokoro-frontend/build/prebuilt/Phonemizer.dll'=$driverPath}
    foreach($name in 'decoder.so','decoder-tables.bin','decoder-weights.bin','decoder-coefficients.bin','speech-text.txt','speech-pack.json'){ $stage["kokoro/generator-tail/$name"]=Join-Path $pack $name }
    foreach($relative in 'tools/Invoke-KokoroPrecomputedDecoder.ps1','tools/Kokoro.TextEncoder.psm1','src/frontend/Kokoro.TextEncoder.ps1','src/runspace/Torch.Checkpoint.psm1','lib/manifest.json',
        "build/inputs/kokoro/$revision/kokoro-v1_0.pth","build/inputs/kokoro/$revision/config.json","build/inputs/kokoro/$revision/voices/af_heart.pt",$compiler,"$encoderDirectory/Kokoro.TextEncoder.dll","$encoderDirectory/Kokoro.TextEncoder.dll.sha256"){
        $local=Join-Path $Root $relative; if(-not (Test-Path -LiteralPath $local -PathType Leaf)){throw "Front-end file missing (run the host port once first): $relative"}
        $stage["kokoro-frontend/$relative"]=$local }
    Import-Evaluator
    $lines=@(& (Join-Path $Root 'tools/Invoke-GeneratorTailProbe.ps1') -EmissionDirectory $generator.Emission.Directory -EmissionArtifact $generator.Emission -FixtureDirectory $pack -Soc $Soc -Runs $Runs -Package $Package -TimeoutSeconds 600 -Adb (Get-KokoroAdbClient) -Speech -StageFiles $stage 2>&1 | ForEach-Object { "$_" -split "`r?`n" })
    $receiptText=$lines -join "`n"
    if($receiptText -notmatch '(?m)^Passed=True\s*$' -or $receiptText -notmatch '(?m)^StartupRestored=True\s*$' -or $receiptText -notmatch '(?m)^SpeechPath=(\S+)'){ throw "Phone speech run failed: $(($lines | Select-Object -Last 4) -join ' | ')" }
    $phoneWave=$Matches[1]
    $speechRuns=@(foreach($line in $lines | Where-Object { $_ -like 'Speech Run=*' }){ $row=[ordered]@{}
        foreach($field in $line.Substring(7).Split(' ')){ $pair=$field.Split('=',2); $row[$pair[0]]=if($pair[0] -ceq 'PcmSHA256'){$pair[1]}else{[double]::Parse($pair[1],[Globalization.CultureInfo]::InvariantCulture)} }
        [pscustomobject]$row })
    Import-Module (Join-Path $Root 'tools/Kokoro.AudioMeasurement.psm1')
    $comparison=Compare-KokoroAudio -Reference $referenceWave -Candidate $phoneWave -ImageDirectory (Join-Path $out 'compare')
    $result=[pscustomobject]@{PSTypeName='Kokoro.PhoneSpeech';Text=$Text;Phonemes=$phonemes.Length;Ticks=$ticks;AudioSeconds=$ticks/80.0;Runs=$speechRuns
        LoadMs=$(if($receiptText -match '(?m)^SpeechLoadMs=(\S+)'){[double]$Matches[1]}); PhoneWave=$phoneWave;ReferenceWave=$referenceWave
        ReferenceDecoderDspMs=$decoded.DspMs;ReferenceGeneratorDspMs=$rendering.DspMs;Comparison=$comparison
        DecoderBase=$decoderBasePath;GeneratorBase=$generatorBasePath;GeneratorLibrarySHA256=$generator.Emission.LibrarySHA256;Lines=$lines}
    $result | Export-Clixml -LiteralPath (Join-Path $out 'phone-speech.clixml') -Depth 6
    $result
}

# Depth-first equivalence for the 128-channel residual section (resblocks 3-5 and their mean): the layer schedule exports
# the section's exact AdaIN values on the phone; the layer and backward schedules then run with those values and the same
# input and weights, and their output tensors must be byte-identical (the backward job writes each output tile at its
# position).
function Test-KokoroGeneratorTileEquivalence {
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',
        # 128: the 128-channel section (resblocks.3-5) on the backward schedule; 256: the 256-channel section (resblocks.0-2)
        # on the chunked schedule, its weights streamed per stage. Each picks its fixture from the same utterance.
        [ValidateSet(128,256)][int]$Channels=128,
        # Section: one section's residual blocks and mean. Front: the 256-channel front (LeakyReLU, ups.0, the add of the
        # source stream) and the chunked section. Whole: both fronts and sections (ups.1 from the 256-channel mean) and the
        # tail to PCM, the 128-channel section on the backward schedule. Each source insertion point of the depth-first
        # job reads the stream the layer job computed there (noise_convs and noise_res), exported from its workspace.
        # Spans: past the layer job's length. x and the two source streams the layer job computed are repeated frame by
        # frame Repeat times (any content serves; the check is self-consistency), and the span job runs that input at
        # each of SpanSizes: every section's output and the PCM must be equal byte for byte across span sizes.
        # WholeSource: the whole generator with its source computed on the DSP (harmonic source, STFT, noise_convs and noise_res
        # as one-branch depth-first sections), against the layer job with its source, from f0 and the noise draws.
        # SpansSource: Spans for the whole generator with its source on the DSP (x, f0 and the noise draws repeated).
        [ValidateSet('Section','Front','Whole','Spans','WholeSource','SpansSource')][string]$Joint='Section',
        # Front and Whole: the depth-first job runs in spans of this many 256-channel tiles, each section's state saved
        # and restored between them.
        [int]$SpanTiles=20,[ValidateRange(2,64)][int]$Repeat=4,[int[]]$SpanSizes=@(20,40),[ValidateRange(16,4096)][int]$SourceChunkTiles=128,
        # Front and Whole: Layer feeds each source insertion point the stream the layer job computed; Zero feeds x = 0
        # there (no source contribution), and the report gives the PCM SNR against the layer job.
        # Model: the sections in ModelSections take their add's result from a frozen model of Y on U (ModelName, the
        # fold of SourceModel, a generator-source-boundary receipt, that held out ModelHeldOut), realized through the
        # supplied stream by inverting the add's integer arithmetic; the others keep the layer job's stream.
        # LayerOutput (control): the ModelSections take the layer job's own Y through the same injection as a model.
        [ValidateSet('Layer','Zero','Model','LayerOutput')][string]$SourceStreams='Layer',
        [string]$SourceModel,[ValidateSet('M1','M2')][string]$ModelName='M1',[int[]]$ModelSections=@(0,1),[string]$ModelHeldOut='build\decoder-generator-fixture-20261009',
        # Output: Y^ replaces the add's result in the depth-first job (the replacement under test); with both sections the
        # first pass gives section 1's own U and a second pass injects its Y^. Inverse (diagnostic): the supplied source N^
        # that the add turns into Y^, each section's U from the layer job.
        [ValidateSet('Output','Inverse')][string]$ModelInjection='Output',
        # Diagnosis: the depth-first job ends after this stage of its first span (its outputs are then incomplete).
        [string]$StopAfterSpanStage='',
        # Diagnosis: the depth-first job's HVX worker wait (Futex or Spin; default by schedule).
        [string]$PoolWait='',
        # Diagnosis: the layer job's HVX worker wait and tiles per batch (default Futex, 22).
        [string]$LayerPoolWait='',[int]$LayerBatchTiles=22,
        [string]$FixtureDirectory=(Join-Path $Build $(switch($Joint){'Front'{'speak-20261010-h0-fast/job-input/front10-stage-fixture-20261008'}{$_ -in 'Whole','Spans'}{'generator-whole-fixture-20261008'}{$_ -in 'WholeSource','SpansSource'}{'generator-whole-source-fixture-20261008'}default{if($Channels -eq 256){'speak-20261010-h0-fast/job-input/g256-fixture-20261008'}else{'speak-20261010-h0-fast/job-input/generator60x16-fixture-20261008-holdout2'}}})),[ValidateRange(1,21)][int]$Runs=3,
        # Tiles per step, one per HVX thread.
        [ValidateSet(2,4)][int]$TileBlock=4,
        # 1: both jobs run int8 weights q = round(w / 256) (clamped to +-127) stored as 256 q, table biases corrected; the
        # backward job keeps only the high plane resident (two planes do not fit its VTCM).
        [ValidateSet(1,2)][int]$WeightPlanes=1,
        # The controller contact proof: the backward job reads per-tile AdaIN as K_base + P * v with fixed pseudo-random P.
        # Held: v = 0 against the layer job. Moving: v = V everywhere must differ; a step from 0 to V at ControllerStep
        # must equal the v = 0 run before it and the v = V run after it, outside ControllerMargin tiles; and the step at
        # blocks of 2 must equal blocks of TileBlock.
        [switch]$ControllerContact,[int]$ControllerStep=160,[int]$ControllerMargin=8,[int]$ControllerValue=8192,[int]$SensitivityRange=1048576,
        # The backward job's fill in packets of several instructions.
        [switch]$VectorPackets,
        # Also run the backward job with PMU event sets A and B (output must equal the unprofiled run) and record its
        # time per category: fill, convolution, combine, mean, DMA, synchronization, tile fixes.
        [switch]$PmuSplit,
        # Jobs with a tail: time every run one-shot (about 30 s each) instead of one one-shot proof run plus resident timing.
        [switch]$OneShotTiming,
        # The depth-first job reads each site's K/M/S finished from the host (ConvertTo-KokoroGeneratorStageCoefficients)
        # instead of computing them from the ratios on the DSP; the layer job is unchanged.
        [switch]$HostCoefficients,
        # Computed sources: the depth-first job runs the noise_res sections of these channel counts resident (Backward,
        # one branch) instead of chunked.
        [int[]]$ResidentSourceChannels=@(),
        # The depth-first job's chunked sections queue the next stage's weights behind the current stage's convolutions.
        [switch]$AsyncWeights)
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh equivalence directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    Import-Evaluator
    $fixture=Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw | ConvertFrom-Json
    if($Joint -ne 'Section'){ $Channels=if($Joint -eq 'Front'){256}else{128} }
    $common=@{ResBlockFrames=[int]$fixture.Frames;ResidentHvxThreads=4}
    switch($Joint){
        'Section' {
            $firstBlock=if($Channels -eq 256){0}else{3}
            if($fixture.Graph -cne 'Generator60x16' -or $fixture.Module -cne 'resblocks' -or [int]$fixture.Blocks[0] -ne $firstBlock -or
                (Get-Item -LiteralPath (Join-Path $FixtureDirectory 'activations.bin')).Length -ne 64L*$Channels*[int]$fixture.Tiles){throw "The fixture is not the $Channels-channel residual section."}
            if($Channels -ne 128){ $common.Stage16Channels=$Channels }
            $depthFirst=if($Channels -eq 256){'Chunked'}else{'Backward'}
        }
        'Front' { if($fixture.Graph -cne 'Generator60x16' -or $null -ne $fixture.Module){throw 'The fixture is not the 256-channel front and section.'}; $common.Stage16Channels=256; $common.GeneratorFront=$true; $depthFirst='Chunked' }
        {$_ -in 'Whole','Spans','WholeSource','SpansSource'} { if($fixture.Graph -cne 'Generator16Whole'){throw 'The fixture is not the whole generator.'}; $common.GeneratorWhole=$true; $depthFirst='Backward'; if($Joint -in 'WholeSource','SpansSource'){ $common.GeneratorSource=$true } }
    }
    $tileBytes=64*$Channels
    # A job with a tail returns only its header and PCM through the resident listener; the workspace needs a one-shot run.
    $oneShot=$Joint -in 'Whole','Spans','WholeSource','SpansSource'
    $export=Invoke-KokoroEmission -Kernel KokoroGenerator60x16Run -Parameters ($common+@{ResidentBatchTiles=22;GeneratorMoments='Export';GeneratorSchedule='Layer'})
    $layerParameters=$common+@{ResidentBatchTiles=$LayerBatchTiles;GeneratorMoments='Constants';GeneratorSchedule='Layer'}; if($LayerPoolWait){ $layerParameters.GeneratorPoolWait=$LayerPoolWait }; if($SourceStreams -eq 'Model'){ $layerParameters.GeneratorExportFrontTensors=$true }
    $layer=Invoke-KokoroEmission -Kernel KokoroGenerator60x16Run -Parameters $layerParameters
    $tileParameters=$common+@{ResidentBatchTiles=$TileBlock;GeneratorMoments='Constants';GeneratorSchedule=$depthFirst;GeneratorWeightPlanes=$WeightPlanes;GeneratorControllerContact=$ControllerContact.IsPresent}
    # The kept depth-first settings apply unless a parameter here is given (opt-out with -Name:$false).
    $overrides=@{}
    foreach($name in 'HostCoefficients','AsyncWeights','VectorPackets'){ if($PSBoundParameters.ContainsKey($name)){ $overrides["Generator$name"]=[bool]$PSBoundParameters[$name] } }
    if($PSBoundParameters.ContainsKey('ResidentSourceChannels')){ $overrides.GeneratorResidentSourceChannels=$ResidentSourceChannels }
    if($Joint -notin 'Section','WholeSource','SpansSource'){ $tileParameters.GeneratorSuppliedSource=$true }
    if($Joint -ne 'Section' -and $PSBoundParameters.ContainsKey('SpanTiles')){ $overrides.GeneratorSpanTiles=$SpanTiles }
    if($Joint -in 'WholeSource','SpansSource' -and $SourceChunkTiles -ne 128){ $tileParameters.GeneratorSourceChunkTiles=$SourceChunkTiles }
    if($StopAfterSpanStage){ $tileParameters.GeneratorStopAfterSpanStage=$StopAfterSpanStage }
    if($PoolWait){ $tileParameters.GeneratorPoolWait=$PoolWait }
    if($SourceStreams -eq 'Model'){ $tileParameters.GeneratorExportFrontTensors=$true; if($ModelInjection -eq 'Output'){ $tileParameters.GeneratorSuppliedSectionInputs=$ModelSections } }
    if($SourceStreams -eq 'LayerOutput'){ $tileParameters.GeneratorSuppliedSectionInputs=$ModelSections }
    $tile=Invoke-KokoroGeneratorDepthFirstEmission -Parameters $tileParameters -Overrides $overrides; $tileParameters=$tile.DepthFirstParameters
    $statistics=[IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'tables.bin'))
    $weights=[IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'weights.bin'))
    $stage={param([string]$Name,[byte[]]$Tables,[byte[]]$WeightBytes,[byte[]]$Activations)
        $directory=Join-Path $out $Name; [void][IO.Directory]::CreateDirectory($directory)
        if($Activations){ [IO.File]::WriteAllBytes((Join-Path $directory 'activations.bin'),$Activations) }
        else { [IO.File]::Copy((Join-Path $FixtureDirectory 'activations.bin'),(Join-Path $directory 'activations.bin')) }
        [IO.File]::WriteAllBytes((Join-Path $directory 'weights.bin'),$WeightBytes)
        [IO.File]::WriteAllBytes((Join-Path $directory 'tables.bin'),$Tables); $directory}
    $exportRun=Invoke-KokoroDeviceJob -EmissionDirectory $export.Directory -EmissionArtifact $export -InputDirectory (& $stage 'export' $statistics $weights) -Soc $Soc -Runs 1 -Package $Package
    $exact=New-KokoroDecoderConstantsTables -Layout $export.Layout.ConstantPacking -Tables $statistics -Observation $exportRun.Output -OutputOffset 0 -Contracts @(1)
    $runTables=$exact.Tables; $runWeights=$weights
    if($WeightPlanes -eq 1){
        # The main path's resblocks only, unless the source runs on the DSP: otherwise noise_res runs only in the layer job,
        # which computes the supplied streams from its own weights.
        $converted=ConvertTo-KokoroGeneratorInt8 -Tables $exact.Tables -WeightBytes $weights -Layout $layer.Layout -IncludeSource:($Joint -in 'WholeSource','SpansSource') -CacheDirectory (Join-Path $Build 'generator-int8')
        $runTables=$converted.Tables; $runWeights=$converted.Weights
    }
    $constantsInput=& $stage 'constants' $runTables $runWeights
    # A job with a tail needs one one-shot run for its workspace; its timing runs go through the resident listener (header
    # and PCM, about 30 s less per run), checked below to give the one-shot run's PCM. -OneShotTiming times one-shot as before.
    $proofRuns=if($oneShot -and -not $OneShotTiming){1}else{$Runs}
    $layerRun=Invoke-KokoroDeviceJob -EmissionDirectory $layer.Directory -EmissionArtifact $layer -InputDirectory $constantsInput -Soc $Soc -Runs $proofRuns -Package $Package -OneShot:$oneShot
    # The DDR workspace starts at the first 128-byte boundary at least 64 bytes into the output buffer.
    $tensorBytes=[long]$fixture.Tiles*$tileBytes
    $tileInput=$constantsInput
    if([long]$tile.Layout.ConstantPacking.HostCoefficientsOffset -ge 0){
        # The same parameters, then the finished K/M/S at the offset the depth-first layout gives them.
        $tileInput=& $stage 'host-coefficients' (Add-KokoroGeneratorHostCoefficients -Tables $runTables -Layout $tile.Layout) $runWeights
    }
    if($Joint -notin 'Section','WholeSource','SpansSource'){
        # Each source stream the layer job parked in its workspace becomes the depth-first job's supplied input there.
        if($SourceStreams -eq 'Model'){
            if(-not $SourceModel){throw 'SourceStreams Model needs -SourceModel (a generator-source-boundary receipt).'}
            $boundary=Import-Clixml -LiteralPath $SourceModel; Import-CaptureKernels; $applyModel=Get-MatrixApplyKernel
        }
        # A section's tensor at a workspace offset of a run's output, [channel][frame] values at one LSB.
        $streamFrames={param($Stream) if([int]$Stream.Channels -eq 256){([int]$fixture.Frames-1)/6}else{[int]$fixture.Frames}}
        $readTensor={param($Run,[long]$Offset,$Stream)
            $ones=[double[]]::new([int]$Stream.Channels); [Array]::Fill($ones,1.0); $bytes=[byte[]]::new($Stream.Bytes); [Array]::Copy($Run.Output,128+$Offset,$bytes,0,$Stream.Bytes)
            ConvertFrom-KokoroCroutons16 -Bytes $bytes -Frames (& $streamFrames $Stream) -Units $ones}
        $encodeTensor={param($Stream,[float[]]$Values) $ones=[double[]]::new([int]$Stream.Channels); [Array]::Fill($ones,1.0); ConvertTo-KokoroCroutons16 -Values $Values -Frames (& $streamFrames $Stream) -Scales $ones}
        # The frozen fit's Y^ from U: per channel the fitted taps on U (zero past either end) and the offset, clamped to int16.
        $predictY={param($Stream,[float[]]$UValues)
            $channels=[int]$Stream.Channels; $frames=& $streamFrames $Stream
            $fit=@(@($boundary.Sections)[$Stream.Section].Fits | Where-Object { $_.Model -ceq $ModelName -and ([string]$_.HeldOutFixture).EndsWith($ModelHeldOut) })[0]
            if(-not $fit){throw "No $ModelName fit of section $($Stream.Section) holds out $ModelHeldOut."}
            $yHat=[float[]]::new($channels*$frames)
            for($c=0;$c -lt $channels;$c++){
                $w=[double[]]$fit.Weights[$c]; $nf=$w.Length; $taps=$nf-1; $reach=[int](($taps-1)/2); $m=[double[]]::new($nf*$frames)
                for($k=0;$k -lt $taps;$k++){ $lag=$k-$reach; $n=$frames-[math]::Abs($lag); for($i=0;$i -lt $n;$i++){ $m[$k*$frames+[math]::Max(0,-$lag)+$i]=$UValues[$c*$frames+[math]::Max(0,$lag)+$i] } }
                [Array]::Fill($m,1.0,$taps*$frames,$frames)
                $prediction=[double[]]::new($frames); $applyModel.Invoke($w,1,$nf,$m,$frames,[double[]]@(0.0),$prediction)
                for($i=0;$i -lt $frames;$i++){ $yHat[$c*$frames+$i]=[float][math]::Round([math]::Max(-32768,[math]::Min(32767,$prediction[$i]))) }
            }
            ,$yHat}
        # Diagnostic: the supplied source N^ for which the add gives Y^. front_add computes Y = sat(2 sat(q(U rU) + q(N rN)))
        # with q(x) = (2x + 2^15) >> 16 (Q14 ratios); N^ solves q(N^ rN) = Y^/2 - q(U rU), clamped to int16.
        $invertAdd={param($Stream,[float[]]$UValues,[float[]]$YHat)
            $channels=[int]$Stream.Channels; $frames=& $streamFrames $Stream; $q={param([long]$x) [long][math]::Floor((2.0*$x+32768)/65536)}
            $nHat=[float[]]::new($channels*$frames); $at=[long]$Stream.AddRatioOffset
            for($c=0;$c -lt $channels;$c++){
                if($Stream.AddRatioForm -ceq 'HalfwordVectors'){ $ru=[BitConverter]::ToInt16($runTables,$at+128*($c -shr 5)+4*($c -band 31)); $rn=[BitConverter]::ToInt16($runTables,$at+128*($channels/32+($c -shr 5))+4*($c -band 31)) }
                else { $ru=[BitConverter]::ToInt16($runTables,$at+4*$c); $rn=[BitConverter]::ToInt16($runTables,$at+512+4*$c) }
                for($i=0;$i -lt $frames;$i++){
                    $b=[math]::Floor($YHat[$c*$frames+$i]/2+0.5)-(& $q ([long]$UValues[$c*$frames+$i]*$ru))
                    $nHat[$c*$frames+$i]=[float][math]::Max(-32768,[math]::Min(32767,$(if($rn -eq 0){0}else{[math]::Round($b*32768.0/$rn)})))
                }
            }
            ,$nHat}
        $modelY=@{}        # The span job's input is x, then the streams (the layer job's har planes are not read).
        $activations=[byte[]]::new($tile.Layout.InputBytes)
        $layerStreams=@($layer.Layout.SourceStreams); $tileStreams=@($tile.Layout.SourceStreams)
        $fixtureActivations=[IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'activations.bin')); [Array]::Copy($fixtureActivations,$activations,[math]::Min($fixtureActivations.Length,[long]$tileStreams[0].InputOffset))
        if($layerStreams.Count -ne $tileStreams.Count){throw 'The jobs have different source insertion points.'}
        for($i=0;$i -lt $tileStreams.Count;$i++){
            if($layerStreams[$i].Bytes -ne $tileStreams[$i].Bytes){throw "Source stream $i differs in size between the jobs."}
            if($SourceStreams -eq 'Zero'){ for($at=[long]$tileStreams[$i].InputOffset+1;$at -lt [long]$tileStreams[$i].InputOffset+[long]$tileStreams[$i].Bytes;$at+=2){ $activations[$at]=0x80 } }
            elseif($SourceStreams -eq 'LayerOutput' -and $i -in $ModelSections){
                [Array]::Copy($layerRun.Output,128+[long]@($layer.Layout.Sections)[$i].InputWorkspaceOffset,$activations,[long]$tileStreams[$i].InputOffset,[long]$tileStreams[$i].Bytes)
            }
            elseif($SourceStreams -eq 'Model' -and $i -in $ModelSections){
                # Y^ from the layer job's U; in a combined run section 1 is replaced after a first pass gives its own U.
                $uLayer=& $readTensor $layerRun $layerStreams[$i].UpsWorkspaceOffset $layerStreams[$i]; $modelY[$i]=& $predictY $layerStreams[$i] $uLayer
                $modelled=if($ModelInjection -eq 'Output'){& $encodeTensor $tileStreams[$i] $modelY[$i]}else{& $encodeTensor $tileStreams[$i] (& $invertAdd $layerStreams[$i] $uLayer $modelY[$i])}
                [Array]::Copy($modelled,0,$activations,[long]$tileStreams[$i].InputOffset,$modelled.Length)
            }
            else { [Array]::Copy($layerRun.Output,128+[long]$layerStreams[$i].WorkspaceOffset,$activations,[long]$tileStreams[$i].InputOffset,[long]$tileStreams[$i].Bytes) }
        }
        $tileInput=& $stage 'supplied-source' $runTables $runWeights $activations
    }
    if($Joint -in 'Spans','SpansSource'){
        Import-CaptureKernels
        $slice={param([byte[]]$Bytes,[long]$Offset,[long]$Length) $part=[byte[]]::new($Length); [Array]::Copy($Bytes,$Offset,$part,0,$Length); ,$part}
        # [channel][frame] values at one LSB (exact for biased u16), repeated frame by frame to LongFrames.
        $repeatFrames={param([byte[]]$Bytes,[int]$Channels,[int]$Frames,[int]$LongFrames)
            $ones=[double[]]::new($Channels); [Array]::Fill($ones,1.0)
            $v=ConvertFrom-KokoroCroutons16 -Bytes $Bytes -Frames $Frames -Units $ones; $w=[float[]]::new($Channels*[long]$LongFrames)
            for($c=0;$c -lt $Channels;$c++){ for($at=0;$at -lt $LongFrames;$at+=$Frames){ [Array]::Copy($v,$c*$Frames,$w,$c*[long]$LongFrames+$at,[math]::Min($Frames,$LongFrames-$at)) } }
            ConvertTo-KokoroCroutons16 -Values $w -Frames $LongFrames -Scales $ones}
        $slowFrames=([int]$fixture.Frames-1)/6; $decFrames=$slowFrames/10; $longFrames=6*$slowFrames*$Repeat+1
        if($Joint -eq 'SpansSource'){ $fixtureActivations=[IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'activations.bin')) }
        $xLong=& $repeatFrames (& $slice $fixtureActivations 0 ([math]::Ceiling($decFrames/32)*32768)) 512 $decFrames ($decFrames*$Repeat)
        # With the source on the DSP: f0 (int32 Q16 per 300 samples) and z (int16 per sample) repeated, from the fixture.
        $f0Bytes={param([int]$Frames) [long]([math]::Ceiling(4*$Frames/128)*128)}
        $shortF0=([int]$fixture.Frames-1)/60; $shortSamples=5*([int]$fixture.Frames-1); $shortAt=[long]$layer.Layout.SourceNoise.InputOffset-(& $f0Bytes $shortF0)
        $repeatValues={param([long]$Offset,[int]$Width,[int]$Count,[int]$LongCount) $out=[byte[]]::new($Width*[long]$LongCount); for($at=0L;$at -lt $LongCount;$at+=$Count){ [Array]::Copy($fixtureActivations,$Offset,$out,$Width*$at,$Width*[math]::Min($Count,$LongCount-$at)) }; ,$out}
        $streamLong=if($Joint -eq 'SpansSource'){ @() } else { @(for($i=0;$i -lt 2;$i++){
            $at=128+[long]$layerStreams[$i].WorkspaceOffset; $streamFrames=if($i -eq 0){$slowFrames}else{[int]$fixture.Frames}
            & $repeatFrames (& $slice $layerRun.Output $at $layerStreams[$i].Bytes) $layerStreams[$i].Channels $streamFrames $(if($i -eq 0){$slowFrames*$Repeat}else{$longFrames}) }) }
        $spanRuns=@(foreach($size in $SpanSizes){
            $parameters=$tileParameters.Clone(); $parameters.ResBlockFrames=$longFrames; $parameters.GeneratorSpanTiles=$size
            $emission=Invoke-KokoroEmission -Kernel KokoroGenerator60x16Run -Parameters $parameters
            $longInput=[byte[]]::new($emission.Layout.InputBytes); [Array]::Copy($xLong,$longInput,$xLong.Length)
            if($Joint -eq 'SpansSource'){
                $longAt=[long]$emission.Layout.SourceNoise.InputOffset-(& $f0Bytes ($shortF0*$Repeat))
                $f0Long=& $repeatValues $shortAt 4 $shortF0 ($shortF0*$Repeat); [Array]::Copy($f0Long,0,$longInput,$longAt,$f0Long.Length)
                $zLong=& $repeatValues ([long]$layer.Layout.SourceNoise.InputOffset) 2 $shortSamples ($shortSamples*$Repeat); [Array]::Copy($zLong,0,$longInput,[long]$emission.Layout.SourceNoise.InputOffset,$zLong.Length)
            }
            else { $streams=@($emission.Layout.SourceStreams); for($i=0;$i -lt 2;$i++){ if($streamLong[$i].Length -ne $streams[$i].Bytes){throw "Long source stream $i has the wrong size."}; [Array]::Copy($streamLong[$i],0,$longInput,[long]$streams[$i].InputOffset,$streamLong[$i].Length) } }
            $run=Invoke-KokoroDeviceJob -EmissionDirectory $emission.Directory -EmissionArtifact $emission -InputDirectory (& $stage "spans-$size" $runTables $runWeights $longInput) -Soc $Soc -Runs $Runs -Package $Package -OneShot
            $pcmAt=[long]$emission.Layout.PcmOffset; $pcmBytes=& $slice $run.Output $pcmAt (2L*[int]$emission.Layout.Samples)
            $outputs=@(foreach($section in @($emission.Layout.Sections)){ $at=128+[long]$section.FinalWorkspaceOffset; [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData((& $slice $run.Output $at $section.Bytes))) })
            [pscustomobject]@{SpanTiles=$size;Spans=@($emission.Layout.Spans).Count;DspMs=$run.MedianMs;LibraryBytes=$emission.Bytes;VtcmBytes=$emission.Layout.VtcmBytes
                PcmSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pcmBytes));SectionSHA256=$outputs;LibrarySHA256=$emission.LibrarySHA256}
        })
        $report=[pscustomobject]@{Soc=$Soc;Fixture=$FixtureDirectory;Joint=$Joint;Repeat=$Repeat;Frames=$longFrames;Samples=5L*($longFrames-1);AudioSeconds=5.0*($longFrames-1)/24000
            Identical=(@($spanRuns | ForEach-Object { $_.PcmSHA256 + ($_.SectionSHA256 -join '') } | Select-Object -Unique).Count -eq 1);Runs=$spanRuns}
        $report | Export-Clixml -LiteralPath (Join-Path $out 'equivalence.clixml') -Depth 8
        return $report
    }
    $read={param($Run,$Emission) $at=128+[long]$Emission.Layout.FinalWorkspaceOffset; [byte[]]$Run.Output[$at..($at+$tensorBytes-1)]}
    $contactProof=$null
    if($ControllerContact){
        # Contact inputs after the constants: per stage P_K[C] and P_M[C] (fixed pseudo-random, |P| <= SensitivityRange),
        # then one controller word (v << 16) per tile.
        $contact=$tile.Layout.ControllerContact
        if($runTables.Length -gt $contact.Offset){throw 'Constants tables run past the controller contact.'}
        $sensitivities=[byte[]]::new(18*$contact.SensitivityBytesPerStage); $random=[Random]::new(7)
        for($i=0;$i -lt $sensitivities.Length;$i+=4){ [Array]::Copy([BitConverter]::GetBytes([int]$random.Next(-$SensitivityRange,$SensitivityRange+1)),0,$sensitivities,$i,4) }
        $contactTables={param([int[]]$Values)
            $bytes=[byte[]]::new($contact.ControllerOffset+$contact.ControllerBytes)
            [Array]::Copy($runTables,0,$bytes,0,$runTables.Length); [Array]::Copy($sensitivities,0,$bytes,$contact.Offset,$sensitivities.Length)
            for($t=0;$t -lt $Values.Length;$t++){ [Array]::Copy([BitConverter]::GetBytes([int]($Values[$t] -shl 16)),0,$bytes,$contact.ControllerOffset+4*$t,4) }
            $bytes}
        $tilesCount=[int]$fixture.Tiles
        $held=[int[]]::new($tilesCount); $high=[int[]]::new($tilesCount); $step=[int[]]::new($tilesCount)
        for($t=0;$t -lt $tilesCount;$t++){ $high[$t]=$ControllerValue; if($t -ge $ControllerStep){ $step[$t]=$ControllerValue } }
        $contactRun={param([string]$Name,[int[]]$Values,$Emission) Invoke-KokoroDeviceJob -EmissionDirectory $Emission.Directory -EmissionArtifact $Emission -InputDirectory (& $stage $Name (& $contactTables $Values) $runWeights) -Soc $Soc -Runs $Runs -Package $Package}
        $tileRun=& $contactRun 'contact-held' $held $tile
        $highRun=& $contactRun 'contact-high' $high $tile; $stepRun=& $contactRun 'contact-step' $step $tile
        $singleParameters=$tileParameters.Clone(); $singleParameters.ResidentBatchTiles=2
        $single=Invoke-KokoroEmission -Kernel KokoroGenerator60x16Run -Parameters $singleParameters
        $singleRun=& $contactRun 'contact-step-single' $step $single
        $heldTensor=& $read $tileRun $tile; $highTensor=& $read $highRun $tile; $stepTensor=& $read $stepRun $tile; $singleTensor=& $read $singleRun $single
        $sameTiles={param([byte[]]$A,[byte[]]$B,[int]$From,[int]$To) $bad=0; for($t=[Math]::Max(0,$From);$t -lt [Math]::Min($tilesCount,$To);$t++){ for($i=$tileBytes*$t;$i -lt $tileBytes*($t+1);$i++){ if($A[$i] -ne $B[$i]){ $bad++; break } } }; $bad}
        $contactProof=[pscustomobject]@{Step=$ControllerStep;Margin=$ControllerMargin;Value=$ControllerValue;SensitivityRange=$SensitivityRange
            HighDifferingTiles=(& $sameTiles $heldTensor $highTensor 0 $tilesCount)
            StepBeforeDifferingTiles=(& $sameTiles $stepTensor $heldTensor 0 ($ControllerStep-$ControllerMargin))
            StepAfterDifferingTiles=(& $sameTiles $stepTensor $highTensor ($ControllerStep+$ControllerMargin) $tilesCount)
            StepTransitionDifferingFromHeld=(& $sameTiles $stepTensor $heldTensor ($ControllerStep-$ControllerMargin) ($ControllerStep+$ControllerMargin))
            BlockInvariant=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stepTensor)) -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($singleTensor)))
            HighDspMs=$highRun.MedianMs;StepDspMs=$stepRun.MedianMs;SingleBlockDspMs=$singleRun.MedianMs
            StepTensorSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stepTensor))}
    }
    else { $tileRun=Invoke-KokoroDeviceJob -EmissionDirectory $tile.Directory -EmissionArtifact $tile -InputDirectory $tileInput -Soc $Soc -Runs $proofRuns -Package $Package -OneShot:$oneShot }
    if($SourceStreams -eq 'Model' -and $ModelInjection -eq 'Output' -and 0 -in $ModelSections -and 1 -in $ModelSections){
        # Section 1's Y^ from the U the fitted section 0 gives it, then the second pass.
        $uFitted=& $readTensor $tileRun $tileStreams[1].UpsWorkspaceOffset $tileStreams[1]; $modelY[1]=& $predictY $tileStreams[1] $uFitted
        $second=& $encodeTensor $tileStreams[1] $modelY[1]; [Array]::Copy($second,0,$activations,[long]$tileStreams[1].InputOffset,$second.Length)
        $tileInput=& $stage 'supplied-model-pass2' $runTables $runWeights $activations
        $tileRun=Invoke-KokoroDeviceJob -EmissionDirectory $tile.Directory -EmissionArtifact $tile -InputDirectory $tileInput -Soc $Soc -Runs $Runs -Package $Package -OneShot:$oneShot
    }
    # Per modelled section: Y^ against the layer job's Y (this utterance), and the depth-first job's section input against Y^
    # (how faithfully the injection or the inverted add realizes it).
    $modelReport=@(if($SourceStreams -eq 'Model'){ foreach($i in $ModelSections){
        $yLayer=& $readTensor $layerRun @($layer.Layout.Sections)[$i].InputWorkspaceOffset $layerStreams[$i]; $yRealized=& $readTensor $tileRun @($tile.Layout.Sections)[$i].InputWorkspaceOffset $tileStreams[$i]
        [pscustomobject]@{Section=$i;Model=$ModelName;Injection=$ModelInjection;ModelSnrDb=(Get-KokoroSnr $modelY[$i] $yLayer);RealizedSnrDb=(Get-KokoroSnr $yRealized $modelY[$i])} } })
    $layerTensor=& $read $layerRun $layer; $tileTensor=& $read $tileRun $tile
    [IO.File]::WriteAllBytes((Join-Path $out 'layer-tensor.bin'),$layerTensor); [IO.File]::WriteAllBytes((Join-Path $out 'tile-tensor.bin'),$tileTensor)
    $split=$null
    if($PmuSplit){
        $events=@{A=[int[]]@(0x3,0x111,0x100,0x101,0x105,0x128,0x129,0x103);B=[int[]]@(0x12a,0x12b,0x115,0x116,0x117,0x12c,0x3,0x111)}
        $split=@(foreach($eventSet in 'A','B'){
            $profiled=$tileParameters.Clone(); $profiled.ResidentPmuEvents=$events[$eventSet]
            $emission=Invoke-KokoroEmission -Kernel KokoroGenerator60x16Run -Parameters $profiled
            # The resident listener returns only the header and PCM ranges; the PMU records need the whole output.
            $run=Invoke-KokoroDeviceJob -EmissionDirectory $emission.Directory -EmissionArtifact $emission -InputDirectory $tileInput -Soc $Soc -Runs $Runs -Package $Package -OneShot
            $profiledTensor=& $read $run $emission
            if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($profiledTensor)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($tileTensor))){throw "Profiled tile output (set $eventSet) differs from the unprofiled run."}
            $records=Read-KokoroPmuRecords -Output $run.Output -PmuProfile $emission.Layout.PmuProfile -EventSet $eventSet
            # Per lockstep thread, ticks summed over every lockstep stage (workspace at output + 128).
            $pmuLayout=$emission.Layout.PmuProfile
            $lockstep=@(if($pmuLayout.PSObject.Properties.Name -contains 'LockstepTelemetryOffset'){ for($k=0;$k -lt $pmuLayout.LockstepThreads;$k++){
                $at=128+[long]$pmuLayout.LockstepTelemetryOffset+32*$k
                [pscustomobject]@{Thread=$k;LockWaitMs=[BitConverter]::ToUInt32($run.Output,$at)/19200.0;LockHeldMs=[BitConverter]::ToUInt32($run.Output,$at+4)/19200.0;NeighborWaitMs=[BitConverter]::ToUInt32($run.Output,$at+8)/19200.0;
                    FillMs=[BitConverter]::ToUInt32($run.Output,$at+12)/19200.0;CombineMs=[BitConverter]::ToUInt32($run.Output,$at+16)/19200.0;
                    OutputMs=[BitConverter]::ToUInt32($run.Output,$at+20)/19200.0;InputMs=[BitConverter]::ToUInt32($run.Output,$at+24)/19200.0} } })
            [pscustomobject]@{EventSet=$eventSet;DspMs=$run.MedianMs;LibrarySHA256=$emission.LibrarySHA256;Measurements=$records.Measurements;UnmarkedSites=$records.UnmarkedSites;Lockstep=$lockstep}
        })
    }
    $different=0; $first=-1; $differingTiles=[Collections.Generic.List[int]]::new()
    for($i=0;$i -lt $tensorBytes;$i++){if($layerTensor[$i] -ne $tileTensor[$i]){$different++; if($first -lt 0){$first=$i}; $t=[int][math]::Floor($i/$tileBytes); if($differingTiles.Count -eq 0 -or $differingTiles[-1] -ne $t){$differingTiles.Add($t)}}}
    # Each section's input after its front and its output, compared in the two jobs' workspaces.
    $sectionReport=@(foreach($section in @($tile.Layout.Sections)){
        # A computed source's output N against the source the layer job parked for that front.
        if($null -ne $section.SourceOf -and [int]$section.SourceOf -ge 0){ $parts=@(,@('Source','FinalWorkspaceOffset',[long]@($layer.Layout.SourceStreams)[[int]$section.SourceOf].WorkspaceOffset)) }
        else { $reference=@($layer.Layout.Sections)[$section.Section]; $parts=@(@('Input','InputWorkspaceOffset',[long]$reference.InputWorkspaceOffset),@('Output','FinalWorkspaceOffset',[long]$reference.FinalWorkspaceOffset)) }
        foreach($part in $parts){
            if([long]$section.($part[1]) -lt 0){ continue }
            $a=[long]$part[2]+128; $b=[long]$section.($part[1])+128; $bad=0; $firstBad=-1
            for($i=0L;$i -lt $section.Bytes;$i++){ if($layerRun.Output[$a+$i] -ne $tileRun.Output[$b+$i]){ $bad++; if($firstBad -lt 0){$firstBad=$i} } }
            [pscustomobject]@{Section=$section.Section;Channels=$section.Channels;Tensor=$part[0];DifferentBytes=$bad;FirstDifferingTile=$(if($firstBad -ge 0){[int][math]::Floor($firstBad/(64*$section.Channels))}else{-1})}
        }
    })
    # With the source on the DSP, also the har tensors both jobs write to the workspace.
    if($null -ne $tile.Layout.Har -and $null -ne $layer.Layout.Har){
        foreach($part in @(@('Har60','SixtyOffset','SixtyBytes'),@('HarPhaseMajor','PhaseMajorOffset','PhaseMajorBytes'))){
            $x=128+[long]$layer.Layout.Har.($part[1]); $y=128+[long]$tile.Layout.Har.($part[1]); $bad=0; $firstBad=-1
            for($i=0L;$i -lt [long]$tile.Layout.Har.($part[2]);$i++){ if($layerRun.Output[$x+$i] -ne $tileRun.Output[$y+$i]){ $bad++; if($firstBad -lt 0){$firstBad=$i} } }
            $sectionReport+=[pscustomobject]@{Section=-1;Channels=0;Tensor=$part[0];DifferentBytes=$bad;FirstDifferingTile=$firstBad}
        }
    }
    # With a tail, also the PCM (int16 per sample) of both jobs.
    $pcm=$null
    if([int]$tile.Layout.Samples -gt 1){
        $pcmOf={param($Run,$Emission) $at=[long]$Emission.Layout.PcmOffset; [byte[]]$Run.Output[$at..($at+2L*[int]$Emission.Layout.Samples-1)]}
        $layerPcm=& $pcmOf $layerRun $layer; $tilePcm=& $pcmOf $tileRun $tile
        $toFloat={param([byte[]]$Bytes) $v=[float[]]::new($Bytes.Length/2); for($i=0;$i -lt $v.Length;$i++){ $v[$i]=[BitConverter]::ToInt16($Bytes,2*$i) }; ,$v}
        $rms={param([float[]]$v) $sum=0.0; foreach($x in $v){ $sum+=[double]$x*$x }; [math]::Round([math]::Sqrt($sum/[math]::Max(1,$v.Length)),1)}
        $layerValues=& $toFloat $layerPcm; $tileValues=& $toFloat $tilePcm
        $dot={param([float[]]$A,[float[]]$B) $sum=0.0; for($i=0;$i -lt $A.Length;$i++){ $sum+=[double]$A[$i]*$B[$i] }; $sum}
        $gain=(& $dot $tileValues $layerValues)/[math]::Max(1e-9,(& $dot $tileValues $tileValues)); $matched=[float[]]::new($tileValues.Length); for($i=0;$i -lt $matched.Length;$i++){ $matched[$i]=[float]($gain*$tileValues[$i]) }
        $pcm=[pscustomobject]@{Samples=[int]$tile.Layout.Samples;SnrDb=(Get-KokoroSnr $tileValues $layerValues);LevelMatchedSnrDb=(Get-KokoroSnr $matched $layerValues);LayerRms=(& $rms $layerValues);TileRms=(& $rms $tileValues);LevelErrorDb=[math]::Round(20*[math]::Log10([math]::Max(1e-9,(& $rms $tileValues))/[math]::Max(1e-9,(& $rms $layerValues))),2);Identical=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($layerPcm)) -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($tilePcm)))
            LayerSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($layerPcm));TileSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($tilePcm))}
        # Against stock Kokoro's PCM for the same captured inputs, where the fixture carries it (float32, full scale 1).
        $stockPath=Join-Path $FixtureDirectory 'expected-pcm-f32.bin'
        if(Test-Path -LiteralPath $stockPath){
            $stockBytes=[IO.File]::ReadAllBytes($stockPath)
            if($stockBytes.Length -eq 4*$layerValues.Length){
                $stock=[float[]]::new($layerValues.Length); [Buffer]::BlockCopy($stockBytes,0,$stock,0,$stockBytes.Length); for($i=0;$i -lt $stock.Length;$i++){ $stock[$i]=32768*$stock[$i] }
                $pcm | Add-Member -NotePropertyName LayerStockSnrDb -NotePropertyValue (Get-KokoroSnr $layerValues $stock)
                $pcm | Add-Member -NotePropertyName TileStockSnrDb -NotePropertyValue (Get-KokoroSnr $tileValues $stock)
            }
        }
    }
    # Resident timing runs: their PCM must equal the one-shot proof run's before their times stand.
    $layerTiming=$layerRun; $tileTiming=$tileRun; $timingMode=if($proofRuns -lt $Runs){'Resident'}else{$(if($oneShot){'OneShot'}else{'Resident'})}
    if($proofRuns -lt $Runs){
        $layerTiming=Invoke-KokoroDeviceJob -EmissionDirectory $layer.Directory -EmissionArtifact $layer -InputDirectory $constantsInput -Soc $Soc -Runs $Runs -Package $Package
        $tileTiming=Invoke-KokoroDeviceJob -EmissionDirectory $tile.Directory -EmissionArtifact $tile -InputDirectory $tileInput -Soc $Soc -Runs $Runs -Package $Package
        if([int]$tile.Layout.Samples -gt 1){
            $samePcm={param($A,$B,$Emission) $at=[long]$Emission.Layout.PcmOffset; $n=2L*[int]$Emission.Layout.Samples
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$A.Output[$at..($at+$n-1)])) -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$B.Output[$at..($at+$n-1)]))}
            if(-not (& $samePcm $layerRun $layerTiming $layer)){throw 'Resident layer-job PCM differs from its one-shot run.'}
            if(-not (& $samePcm $tileRun $tileTiming $tile)){throw 'Resident depth-first PCM differs from its one-shot run.'}
        }
    }
    $report=[pscustomobject]@{Soc=$Soc;Fixture=$FixtureDirectory;Joint=$Joint;SourceStreams=$SourceStreams;Model=$modelReport;Pcm=$pcm;Sections=$sectionReport;Channels=$Channels;Schedule=$tileParameters.GeneratorSchedule;Tiles=[int]$fixture.Tiles;TileBlock=$TileBlock;WeightPlanes=$WeightPlanes;TensorBytes=$tensorBytes;ByteIdentical=($different -eq 0);DifferentBytes=$different;FirstDifference=$first;DifferingTiles=$differingTiles.ToArray()
        LayerDspMs=$layerTiming.MedianMs;TileDspMs=$tileTiming.MedianMs;TimingMode=$timingMode;TimingRuns=$Runs;LayerTimingLines=$layerTiming.Lines;TileTimingLines=$tileTiming.Lines;OneShotLayerDspMs=$layerRun.MedianMs;OneShotTileDspMs=$tileRun.MedianMs;LayerVtcmBytes=$layer.Layout.VtcmBytes;TileVtcmBytes=$tile.Layout.VtcmBytes;LayerLibraryBytes=$layer.Bytes;TileLibraryBytes=$tile.Bytes
        LayerLibrarySHA256=$layer.LibrarySHA256;TileLibrarySHA256=$tile.LibrarySHA256;LayerTensorSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($layerTensor))
        TileTensorSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($tileTensor));ControllerContact=$contactProof;PmuSplit=$split}
    $report | Export-Clixml -LiteralPath (Join-Path $out 'equivalence.clixml') -Depth 8
    $report
}

function Test-KokoroGeneratorSourceBoundary {
    # The source insertion points as a fitting target. Each fixture's layer decoder-and-generator job (source computed
    # from F0 on the DSP) exports, at both fronts, U (the upsampled input of the add), N (the source after noise_res)
    # and Y (the add's result, the section input), in integer LSB units. Reported per section: the powers of the add's two
    # parts (U and N times their Q14 ratios) and of Y, the U-N
    # correlation and the cancellation (power of the parts over power of the sum), saturated values in Y, and how well
    # models with no source branch predict Y on an utterance left out of the fit: M0 Y = U; M1 per-channel gain and
    # offset on U; M2 M1 with a temporal filter of FilterTaps taps on U. Every prediction is clamped to int16.
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',
        [string[]]$FixtureDirectories=@((Join-Path $Build 'decoder-generator-fixture-20261009'),(Join-Path $Build 'evaluator/input/timing-passage-0/decoder-generator-fixture-20261009'),(Join-Path $Build 'speak-20261010-h0-fast/job-input/decoder-generator-fixture-20261009')),
        [ValidateRange(1,9)][int]$FilterTaps=5,
        # A previous run's captures directory: fit again without the phone.
        [string]$CaptureDirectory)
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    if($FilterTaps % 2 -eq 0){throw 'FilterTaps is odd (centred on the frame).'}
    Import-Evaluator; Import-CaptureKernels
    $cross=Get-CrossProductKernel
    # Per fixture and section: U, N, Y as [channel][frame] doubles and the add's Q14 ratios rU, rN. Captured on the phone
    # into <OutputDirectory>/captures (croutons and captures.json), or read back from CaptureDirectory.
    $captures=if($CaptureDirectory){[IO.Path]::GetFullPath($CaptureDirectory)}else{Join-Path $out 'captures'}
    if(-not $CaptureDirectory){
        [void][IO.Directory]::CreateDirectory($captures)
        $index=@(for($u=0;$u -lt $FixtureDirectories.Count;$u++){
            $dir=$FixtureDirectories[$u]; $fixture=Get-Content -LiteralPath (Join-Path $dir 'fixture.json') -Raw | ConvertFrom-Json
            $emission=Invoke-KokoroEmission -Kernel KokoroDecoderGenerator16Run -Parameters @{ResBlockFrames=[int]$fixture.Frames;ResidentHvxThreads=4;ResidentBatchTiles=14;GeneratorExportFrontTensors=$true}
            $run=Invoke-KokoroDeviceJob -EmissionDirectory $emission.Directory -EmissionArtifact $emission -InputDirectory $dir -Soc $Soc -Runs 1 -Package $Package -OneShot
            $tables=[IO.File]::ReadAllBytes((Join-Path $dir 'tables.bin'))
            $sectionIndex=@(foreach($stream in @($emission.Layout.SourceStreams)){
                $section=@($emission.Layout.Sections)[$stream.Section]; $channels=[int]$stream.Channels
                foreach($pair in @(@('U',$stream.UpsWorkspaceOffset),@('N',$stream.WorkspaceOffset),@('Y',$section.InputWorkspaceOffset))){
                    $part=[byte[]]::new($stream.Bytes); [Array]::Copy($run.Output,128+[long]$pair[1],$part,0,$stream.Bytes); [IO.File]::WriteAllBytes((Join-Path $captures "u$u-s$($stream.Section)-$($pair[0]).bin"),$part) }
                $at=[long]$stream.AddRatioOffset; $ru=[int[]]::new($channels); $rn=[int[]]::new($channels)
                for($c=0;$c -lt $channels;$c++){
                    if($stream.AddRatioForm -ceq 'HalfwordVectors'){ $ru[$c]=[BitConverter]::ToInt16($tables,$at+128*($c -shr 5)+4*($c -band 31)); $rn[$c]=[BitConverter]::ToInt16($tables,$at+128*($channels/32+($c -shr 5))+4*($c -band 31)) }
                    else { $ru[$c]=[BitConverter]::ToInt16($tables,$at+4*$c); $rn[$c]=[BitConverter]::ToInt16($tables,$at+512+4*$c) } }
                [pscustomobject]@{Section=[int]$stream.Section;Channels=$channels;Frames=$(if($channels -eq 256){([int]$fixture.Frames-1)/6}else{[int]$fixture.Frames});RatioU=$ru;RatioN=$rn}
            })
            [pscustomobject]@{Index=$u;Fixture=$dir;Frames=[int]$fixture.Frames;DspMs=$run.MedianMs;Sections=$sectionIndex}
        })
        $index | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $captures 'captures.json') -Encoding utf8
    }
    $utterances=@(foreach($entry in @(Get-Content -LiteralPath (Join-Path $captures 'captures.json') -Raw | ConvertFrom-Json)){
        $sections=@(foreach($sec in @($entry.Sections)){
            $ones=[double[]]::new([int]$sec.Channels); [Array]::Fill($ones,1.0)
            $read={param([string]$Name) $v=ConvertFrom-KokoroCroutons16 -Bytes ([IO.File]::ReadAllBytes((Join-Path $captures "u$($entry.Index)-s$($sec.Section)-$Name.bin"))) -Frames ([int]$sec.Frames) -Units $ones; $d=[double[]]::new($v.Length); [Array]::Copy($v,$d,$v.Length); ,$d}
            [pscustomobject]@{Channels=[int]$sec.Channels;Frames=[int]$sec.Frames;U=(& $read 'U');N=(& $read 'N');Y=(& $read 'Y');RatioU=[int[]]$sec.RatioU;RatioN=[int[]]$sec.RatioN}
        })
        [pscustomobject]@{Fixture=$entry.Fixture;Frames=[int]$entry.Frames;DspMs=$entry.DspMs;Sections=$sections}
    })
    $clampedError=Get-ClampedErrorKernel; $saturatedCount=Get-SaturatedCountKernel; $apply=Get-MatrixApplyKernel
    $snr={param([double]$signal,[double]$noise) if($noise -le 0){999}else{[math]::Round(10*[math]::Log10($signal/$noise),2)}}
    # Diagonal of a.b^T over [channels][frames]: per channel sum of a_c * b_c.
    $diagonal={param([double[]]$A,[double[]]$B,[int]$Channels,[int]$Frames) $g=[double[]]::new($Channels*$Channels); $cross.Invoke($A,$Channels,$B,$Channels,$Frames,0,$Frames,$g); $d=[double[]]::new($Channels); for($c=0;$c -lt $Channels;$c++){ $d[$c]=$g[$c*$Channels+$c] }; ,$d}
    $half=[int](($FilterTaps-1)/2)
    # Features of channel c, [feature][frame]: M1 U and 1; M2 U(t - half) .. U(t + half) (zero past either end) and 1.
    $features={param($Tensors,[int]$Channel,[string]$Model)
        $f=$Tensors.Frames; $lags=if($Model -eq 'M1'){,0}else{@(-$half..$half)}; $nf=$lags.Count+1; $m=[double[]]::new($nf*$f)
        for($k=0;$k -lt $lags.Count;$k++){ $lag=$lags[$k]; $n=$f-[math]::Abs($lag); if($n -gt 0){ [Array]::Copy($Tensors.U,$Channel*$f+[math]::Max(0,$lag),$m,$k*$f+[math]::Max(0,-$lag),$n) } }
        [Array]::Fill($m,1.0,($nf-1)*$f,$f); ,$m}
    $report=[Collections.Generic.List[object]]::new()
    for($sec=0;$sec -lt 2;$sec++){
        $channels=$utterances[0].Sections[$sec].Channels
        $pu=0.0; $pn=0.0; $py=0.0; $saturated=0L; $count=0L; $suu=[double[]]::new($channels); $snn=[double[]]::new($channels); $sun=[double[]]::new($channels)
        foreach($u in $utterances){
            $s=$u.Sections[$sec]; $f=$s.Frames; $count+=$s.Y.Length; $saturated+=$saturatedCount.Invoke($s.Y)
            $du=& $diagonal $s.U $s.U $channels $f; $dn=& $diagonal $s.N $s.N $channels $f; $dy=& $diagonal $s.Y $s.Y $channels $f; $dun=& $diagonal $s.U $s.N $channels $f
            for($c=0;$c -lt $channels;$c++){ $gu=$s.RatioU[$c]/16384.0; $gn=$s.RatioN[$c]/16384.0; $pu+=$du[$c]*$gu*$gu; $pn+=$dn[$c]*$gn*$gn; $py+=$dy[$c]; $suu[$c]+=$du[$c]*$gu*$gu; $snn[$c]+=$dn[$c]*$gn*$gn; $sun[$c]+=$dun[$c]*$gu*$gn }
        }
        $sortedCorr=@(for($c=0;$c -lt $channels;$c++){ if($suu[$c] -gt 0 -and $snn[$c] -gt 0){$sun[$c]/[math]::Sqrt($suu[$c]*$snn[$c])}else{0.0} }) | Sort-Object
        # Leave one utterance out: coefficients fitted on the others, frozen, scored on Y of the one left out.
        $scores=[ordered]@{M0=[Collections.Generic.List[double]]::new();M1=[Collections.Generic.List[double]]::new();M2=[Collections.Generic.List[double]]::new()}
        # Each fold's frozen coefficients per channel: [w_features..., offset], features as in $features.
        $fitWeights=@{}; for($h=0;$h -lt $utterances.Count;$h++){ foreach($model in 'M1','M2'){ $fitWeights["$h.$model"]=[object[]]::new($channels) } }
        for($held=0;$held -lt $utterances.Count;$held++){
            $test=$utterances[$held].Sections[$sec]; $tf=$test.Frames
            $err=@{M0=0.0;M1=0.0;M2=0.0}; $sig=0.0; foreach($value in (& $diagonal $test.Y $test.Y $channels $tf)){ $sig+=$value }
            for($c=0;$c -lt $channels;$c++){
                $err.M0+=$clampedError.Invoke($test.U,$c*$tf,$test.Y,$c*$tf,$tf)
                foreach($model in 'M1','M2'){
                    $nf=if($model -eq 'M1'){2}else{$FilterTaps+1}; $gram=[double[]]::new($nf*$nf); $rhs=[double[]]::new($nf)
                    for($tr=0;$tr -lt $utterances.Count;$tr++){
                        if($tr -eq $held){ continue }
                        $s=$utterances[$tr].Sections[$sec]; $f=$s.Frames; $m=& $features $s $c $model
                        $yc=[double[]]::new($f); [Array]::Copy($s.Y,$c*$f,$yc,0,$f)
                        $g=[double[]]::new($nf*$nf); $cross.Invoke($m,$nf,$m,$nf,$f,0,$f,$g); $r=[double[]]::new($nf); $cross.Invoke($m,$nf,$yc,1,$f,0,$f,$r)
                        for($i=0;$i -lt $g.Length;$i++){ $gram[$i]+=$g[$i] }; for($i=0;$i -lt $nf;$i++){ $rhs[$i]+=$r[$i] }
                    }
                    # Least squares by Cholesky, a relative ridge of 1e-6 on the diagonal.
                    for($i=0;$i -lt $nf;$i++){ $gram[$i*$nf+$i]=[math]::Max($gram[$i*$nf+$i]*1.000001,1e-9) }
                    $L=[double[]]::new($nf*$nf)
                    for($i=0;$i -lt $nf;$i++){ for($j=0;$j -le $i;$j++){ $sum=$gram[$i*$nf+$j]; for($k=0;$k -lt $j;$k++){ $sum-=$L[$i*$nf+$k]*$L[$j*$nf+$k] }; if($i -eq $j){ $L[$i*$nf+$i]=[math]::Sqrt([math]::Max($sum,1e-12)) } else { $L[$i*$nf+$j]=$sum/$L[$j*$nf+$j] } } }
                    $z=[double[]]::new($nf); for($i=0;$i -lt $nf;$i++){ $sum=$rhs[$i]; for($k=0;$k -lt $i;$k++){ $sum-=$L[$i*$nf+$k]*$z[$k] }; $z[$i]=$sum/$L[$i*$nf+$i] }
                    $w=[double[]]::new($nf); for($i=$nf-1;$i -ge 0;$i--){ $sum=$z[$i]; for($k=$i+1;$k -lt $nf;$k++){ $sum-=$L[$k*$nf+$i]*$w[$k] }; $w[$i]=$sum/$L[$i*$nf+$i] }
                    $prediction=[double[]]::new($tf); $apply.Invoke($w,1,$nf,(& $features $test $c $model),$tf,[double[]]@(0.0),$prediction)
                    $err[$model]+=$clampedError.Invoke($prediction,0,$test.Y,$c*$tf,$tf)
                    $fitWeights["$held.$model"][$c]=$w
                }
            }
            foreach($model in 'M0','M1','M2'){ $scores[$model].Add((& $snr $sig $err[$model])) }
        }
        # The same held-out errors against Y with each channel's mean removed: the waveform part of the signal.
        $acScores=@{}; foreach($model in 'M0','M1','M2'){ $acScores[$model]=[Collections.Generic.List[double]]::new() }
        for($held=0;$held -lt $utterances.Count;$held++){
            $test=$utterances[$held].Sections[$sec]; $tf=$test.Frames; $ac=0.0
            for($c=0;$c -lt $channels;$c++){ $sum=0.0; $sq=0.0; for($i=$c*$tf;$i -lt ($c+1)*$tf;$i++){ $sum+=$test.Y[$i]; $sq+=$test.Y[$i]*$test.Y[$i] }; $ac+=$sq-$sum*$sum/$tf }
            foreach($model in 'M0','M1','M2'){ $total=(& $diagonal $test.Y $test.Y $channels $tf); $allPower=0.0; foreach($v in $total){ $allPower+=$v }; $errPower=$allPower/[math]::Pow(10,$scores[$model][$held]/10); $acScores[$model].Add((& $snr $ac $errPower)) }
        }        $report.Add([pscustomobject]@{Section=$sec;Channels=$channels
            UPartPower=[math]::Round($pu/$count,1);NPartPower=[math]::Round($pn/$count,1);YPower=[math]::Round($py/$count,1);Cancellation=[math]::Round(($pu+$pn)/$py,3);SaturatedFraction=[math]::Round($saturated/[double]$count,6)
            CorrelationMedian=[math]::Round($sortedCorr[[int]($channels/2)],3);CorrelationMin=[math]::Round($sortedCorr[0],3);CorrelationMax=[math]::Round($sortedCorr[-1],3)
            HeldOutSnrM0=$scores.M0.ToArray();HeldOutSnrM1=$scores.M1.ToArray();HeldOutSnrM2=$scores.M2.ToArray()
            HeldOutWaveformSnrM0=$acScores.M0.ToArray();HeldOutWaveformSnrM1=$acScores.M1.ToArray();HeldOutWaveformSnrM2=$acScores.M2.ToArray()
            Fits=@(foreach($key in $fitWeights.Keys){ $h,$model=$key.Split('.'); [pscustomobject]@{HeldOut=[int]$h;HeldOutFixture=$utterances[[int]$h].Fixture;Model=$model;Weights=$fitWeights[$key]} })})
    }
    $result=[pscustomobject]@{Soc=$Soc;Fixtures=$FixtureDirectories;FilterTaps=$FilterTaps;Utterances=@($utterances | ForEach-Object { [pscustomobject]@{Fixture=$_.Fixture;Frames=$_.Frames;DspMs=$_.DspMs} });Sections=$report.ToArray()}
    $result | Export-Clixml -LiteralPath (Join-Path $out 'boundary.clixml') -Depth 6
    $result
}

function Test-KokoroSourceSeededNoise {
    # Seeded source noise against its host reference: the host's Get-KokoroSourceNoise values fed to the captured-noise
    # source job must give the same output bytes (har and signal) as the seeded job generating them on the DSP from the
    # same seed. Also reports the noise statistics against the target and against the captured draws.
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',
        [string]$FixtureDirectory=(Join-Path $Build 'speak-20261010-h0-fast/job-input/harmonic-source-fixture-20261008'),
        [uint32]$Seed=1,[ValidateRange(1,21)][int]$Runs=3)
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    Import-Evaluator
    . (Join-Path $Root 'src/kernels/Kokoro.HarmonicSource16.ps1')
    $fixture=Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw | ConvertFrom-Json
    $activations=[IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'activations.bin'))
    $f0Bytes=[int]([math]::Ceiling(4*[int]$fixture.F0Frames/128)*128); $count=($activations.Length-$f0Bytes)/2
    # c_h = 0.1 w_h in Q15, so sigma = sqrt(sum_h w_h^2) for z = sum_h w_h g_h.
    $sum=0.0; foreach($c in $fixture.HarmonicCoefficients){ $w=[double]$c/(0.1*32768); $sum+=$w*$w }; $sigma=[math]::Sqrt($sum)
    $scale=[int][math]::Round($sigma*4096*65536/37837.2)
    $noise=Get-KokoroSourceNoise -Seed $Seed -Scale $scale -Count $count
    $stage={param([string]$Name,[byte[]]$Activations)
        $directory=Join-Path $out $Name; [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllBytes((Join-Path $directory 'activations.bin'),$Activations)
        foreach($file in 'weights.bin','tables.bin'){ [IO.File]::Copy((Join-Path $FixtureDirectory $file),(Join-Path $directory $file)) }
        $directory}
    $referenceInput=[byte[]]$activations.Clone(); [Buffer]::BlockCopy($noise,0,$referenceInput,$f0Bytes,2*$count)
    $seededInput=[byte[]]$activations.Clone(); [Array]::Clear($seededInput,$f0Bytes,2*$count)
    [Array]::Copy([BitConverter]::GetBytes($Seed),0,$seededInput,$f0Bytes,4); [Array]::Copy([BitConverter]::GetBytes([int]$scale),0,$seededInput,$f0Bytes+4,4)
    $frames=[int]$fixture.Frames
    $plain=Invoke-KokoroEmission -Kernel KokoroHarmonicSource16Run -Parameters @{ResBlockFrames=$frames}
    $seeded=Invoke-KokoroEmission -Kernel KokoroHarmonicSource16Run -Parameters @{ResBlockFrames=$frames;SourceSeededNoise=$true}
    $referenceRun=Invoke-KokoroDeviceJob -EmissionDirectory $plain.Directory -EmissionArtifact $plain -InputDirectory (& $stage 'host-noise' $referenceInput) -Soc $Soc -Runs $Runs -Package $Package
    $seededRun=Invoke-KokoroDeviceJob -EmissionDirectory $seeded.Directory -EmissionArtifact $seeded -InputDirectory (& $stage 'seeded' $seededInput) -Soc $Soc -Runs $Runs -Package $Package
    # Regions of the output: har planes from 256, then the signal copy (sample j at halfword 64 + j); bytes outside the
    # signal's samples are padding the job never defines.
    $harEnd=[long]$plain.Layout.SignalOutOffset; $samplesFrom=$harEnd+128; $samplesTo=$samplesFrom+2L*[int]$fixture.Samples
    $different=0; $first=-1; $harDifferent=0; $sampleDifferent=0; $paddingDifferent=0
    for($i=256;$i -lt $referenceRun.Output.Length;$i++){
        if($referenceRun.Output[$i] -ne $seededRun.Output[$i]){
            $different++; if($first -lt 0){$first=$i}
            if($i -lt $harEnd){ $harDifferent++ } elseif($i -ge $samplesFrom -and $i -lt $samplesTo){ $sampleDifferent++ } else { $paddingDifferent++ }
        }
    }
    $stats={param([int16[]]$Values)
        $n=$Values.Length; $mean=0.0; foreach($v in $Values){ $mean+=$v }; $mean/=$n
        $m2=0.0; $m4=0.0; $lag=0.0
        for($i=0;$i -lt $n;$i++){ $d=$Values[$i]-$mean; $m2+=$d*$d; $m4+=$d*$d*$d*$d; if($i -gt 0){ $lag+=($Values[$i]-$mean)*($Values[$i-1]-$mean) } }
        [pscustomobject]@{Mean=[math]::Round($mean/4096,5);Std=[math]::Round([math]::Sqrt($m2/$n)/4096,5);Kurtosis=[math]::Round(($m4/$n)/[math]::Pow($m2/$n,2),3);Lag1Correlation=[math]::Round($lag/$m2,5)}}
    $captured=[int16[]]::new($count); [Buffer]::BlockCopy($activations,$f0Bytes,$captured,0,2*$count)
    $report=[pscustomobject]@{Soc=$Soc;Fixture=$FixtureDirectory;Seed=$Seed;Scale=$scale;TargetStd=[math]::Round($sigma,5);Samples=$count
        ByteIdentical=($different -eq 0);DifferentBytes=$different;FirstDifference=$first
        DefinedBytesIdentical=($harDifferent -eq 0 -and $sampleDifferent -eq 0)
        HarDifferentBytes=$harDifferent;SignalSampleDifferentBytes=$sampleDifferent;PaddingDifferentBytes=$paddingDifferent;SeededStatistics=(& $stats $noise);CapturedStatistics=(& $stats $captured)
        CapturedDspMs=$referenceRun.MedianMs;SeededDspMs=$seededRun.MedianMs;SeededLibrarySHA256=$seeded.LibrarySHA256}
    $report | Export-Clixml -LiteralPath (Join-Path $out 'seeded-noise.clixml') -Depth 4
    $report
}

function Test-KokoroGeneratorSeededNoise {
    # The whole generator with the harmonic source, captured stock noise against seeded noise (several seeds), on the
    # accepted constants input of Test-KokoroGeneratorWeightPrecision; PCM SNR against stock and against the
    # captured-noise run.
    param([Parameter(Mandatory)][string]$OutputDirectory,[string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro',
        [uint32[]]$Seeds=@(1,2,3),[string]$PriorReceipt=(Join-Path $Build 'generator-constants-full-corpus-20261012-143702-run.clixml'))
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    Import-Evaluator
    $prior=Import-Clixml -LiteralPath $PriorReceipt
    if($prior.Gate.Status -cne 'Passed'){throw 'Prior generator constants gate did not pass.'}
    $peach=Join-Path $Root 'data/baselines/decoder-generator-bank-input-sm8550-20261010/input'
    $whole=Get-Content -LiteralPath (Join-Path $peach 'fixture.json') -Raw | ConvertFrom-Json
    $source=Join-Path $prior.OutputDirectory 'A/generator-exact-constants'
    $common=@{ResBlockFrames=[int]$whole.Frames;ResidentHvxThreads=4;ResidentBatchTiles=14;GeneratorMoments='Constants'}
    $captured=Invoke-KokoroEmission -Kernel KokoroGeneratorWholeSource16Run -Parameters $common
    $seeded=Invoke-KokoroEmission -Kernel KokoroGeneratorWholeSource16Run -Parameters ($common+@{SourceSeededNoise=$true})
    $activations=[IO.File]::ReadAllBytes((Join-Path $source 'activations.bin')); $tables=[IO.File]::ReadAllBytes((Join-Path $source 'tables.bin')); $weights=[IO.File]::ReadAllBytes((Join-Path $source 'weights.bin'))
    $noise=$seeded.Layout.SourceNoise
    # c_h = 0.1 w_h in Q15 in the source constants; sigma = sqrt(sum_h w_h^2).
    $sourceFixture=Get-Content -LiteralPath (Join-Path ([IO.Path]::Combine($peach, [string]$whole.SourceFixture)) 'fixture.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    if(-not $sourceFixture){ $sourceFixture=Get-Content -LiteralPath (Join-Path $Build 'speak-20261010-h0-fast/job-input/harmonic-source-fixture-20261008/fixture.json') -Raw | ConvertFrom-Json }
    $sum=0.0; foreach($c in $sourceFixture.HarmonicCoefficients){ $w=[double]$c/(0.1*32768); $sum+=$w*$w }; $scale=[int][math]::Round([math]::Sqrt($sum)*4096*65536/37837.2)
    $stockBytes=[IO.File]::ReadAllBytes((Join-Path $peach 'expected-pcm-f32.bin')); $stock=[float[]]::new($whole.Samples); [Buffer]::BlockCopy($stockBytes,0,$stock,0,$stockBytes.Length)
    $snr={param([double[]]$Reference,[double[]]$Candidate) $sig=0.0;$err=0.0; for($i=0;$i -lt $Reference.Length;$i++){$d=$Reference[$i]-$Candidate[$i];$sig+=$Reference[$i]*$Reference[$i];$err+=$d*$d}; if($err -eq 0){[double]::PositiveInfinity}else{[math]::Round(10*[math]::Log10($sig/$err),2)}}
    $deviceRun={param([string]$Name,$Emission,[byte[]]$ActivationBytes)
        $directory=Join-Path $out $Name; [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllBytes((Join-Path $directory 'activations.bin'),$ActivationBytes); [IO.File]::WriteAllBytes((Join-Path $directory 'tables.bin'),$tables); [IO.File]::WriteAllBytes((Join-Path $directory 'weights.bin'),$weights)
        $job=Invoke-KokoroDeviceJob -EmissionDirectory $Emission.Directory -EmissionArtifact $Emission -InputDirectory $directory -Soc $Soc -Runs 1 -Package $Package
        [IO.File]::Delete((Join-Path $directory 'weights.bin'))
        $samples=[double[]]::new($whole.Samples); for($i=0;$i -lt $samples.Length;$i++){$samples[$i]=[BitConverter]::ToInt16($job.Output,$Emission.Layout.PcmOffset+2*$i)/32768.0}
        [pscustomobject]@{Samples=$samples;DspMs=$job.MedianMs}}
    $base=& $deviceRun 'captured' $captured $activations
    $rows=[Collections.Generic.List[object]]::new()
    $rows.Add([pscustomobject]@{Noise='Captured';Seed=$null;StockSnrDb=(& $snr ([double[]]$stock) $base.Samples);CapturedSnrDb=[double]::PositiveInfinity;DspMs=$base.DspMs})
    foreach($seed in $Seeds){
        $input_=[byte[]]$activations.Clone(); [Array]::Clear($input_,$noise.InputOffset,$noise.Bytes)
        [Array]::Copy([BitConverter]::GetBytes($seed),0,$input_,$noise.InputOffset,4); [Array]::Copy([BitConverter]::GetBytes([int]$scale),0,$input_,$noise.InputOffset+4,4)
        $result=& $deviceRun "seed-$seed" $seeded $input_
        $rows.Add([pscustomobject]@{Noise='Seeded';Seed=$seed;StockSnrDb=(& $snr ([double[]]$stock) $result.Samples);CapturedSnrDb=(& $snr $base.Samples $result.Samples);DspMs=$result.DspMs})
    }
    $report=[pscustomobject]@{Soc=$Soc;Fixture=$peach;Scale=$scale;Samples=[int]$whole.Samples;Rows=$rows.ToArray()}
    $report | Export-Clixml -LiteralPath (Join-Path $out 'seeded-noise-pcm.clixml') -Depth 4
    $report
}

# Emits a diagnostic tensor job, runs it on the phone with a job input directory, and returns the output tensor bytes
# (from runner-layout.json OutputOffset), the count of halfwords at the int16 limits, DSP time and the skel identity.
function Invoke-KokoroTensorJob {
    param([Parameter(Mandatory)][string] $Kernel, [Parameter(Mandatory)][hashtable] $Parameters, [Parameter(Mandatory)][string] $InputDirectory, [string] $Soc = 'SM8550', [int] $Runs = 3)
    Import-Evaluator
    $e = Invoke-KokoroEmission -Kernel $Kernel -Parameters $Parameters
    $deviceArguments = @{ EmissionDirectory=$e.Directory; InputDirectory=$InputDirectory; Soc=$Soc; Runs=$Runs }
    if ($null -ne $e.PSObject.Properties['Layout']) { $deviceArguments.EmissionArtifact=$e }
    $run = Invoke-KokoroDeviceJob @deviceArguments
    $layout = if ($null -ne $e.PSObject.Properties['Layout']) { $e.Layout } else {
        Get-Content (Join-Path $e.Directory 'runner-layout.json') -Raw | ConvertFrom-Json
    }
    $tensor = [byte[]]::new($layout.OutputBytes - $layout.OutputOffset); [Array]::Copy($run.Output, $layout.OutputOffset, $tensor, 0, $tensor.Length)
    $saturated = 0; for ($i = 0; $i -lt $tensor.Length; $i += 2) { $u = $tensor[$i] -bor ([int]$tensor[$i + 1] -shl 8); if ($u -le 1 -or $u -ge 65535) { $saturated++ } }
    [pscustomobject]@{ Tensor = $tensor; Saturated = $saturated; MedianMs = $run.MedianMs; Skel = $e.LibrarySHA256.Substring(0, 16); Emission = $e.Key }
}

function Read-KokoroExpected([string] $Directory, [int] $Count) {
    $v = [float[]]::new($Count); [Buffer]::BlockCopy([IO.File]::ReadAllBytes((Join-Path $Directory 'expected-f32.bin')), 0, $v, 0, 4 * $Count); , $v
}

# Compare a capacity-sized residual generator with exact fixed-length jobs on identical live input lanes.
function Test-KokoroGeneratorRuntimeFrames {
    param([Parameter(Mandatory)][string]$FixtureDirectory,[Parameter(Mandatory)][string]$OutputDirectory,
        [string]$Soc='SM8550',[string]$Package='dev.mansfieldplumbing.kokoro')
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Directory]::Exists($out)){throw 'Choose a fresh runtime-frame check directory under build/.'}
    $fixture=[IO.Path]::GetFullPath($FixtureDirectory)
    if(-not $fixture.StartsWith($Build+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Use an existing build/ fixture.'}
    $source=[IO.File]::ReadAllBytes((Join-Path $fixture 'activations.bin'))
    $weights=[IO.File]::ReadAllBytes((Join-Path $fixture 'weights.bin'))
    $tables=[IO.File]::ReadAllBytes((Join-Path $fixture 'tables.bin'))
    if($source.Length -lt 24576 -or $weights.Length -lt 589824 -or $tables.Length -lt 98304){throw 'A 128-channel generator resblocks.3 fixture is required.'}
    Import-Evaluator
    $baseParameters=@{ResBlockFrames=65;ResidentBatchTiles=2;ResidentHvxThreads=4;Stage16Kernels=3}
    $runtimeParameters=$baseParameters.Clone(); $runtimeParameters.GeneratorRuntimeFrames=$true
    $runtime=Invoke-KokoroEmission -Kernel KokoroResBlock16Run -Parameters $runtimeParameters
    $results=[Collections.Generic.List[object]]::new()
    foreach($frames in 2,31,32,33,64,65){
        $pair=[Collections.Generic.List[object]]::new()
        foreach($mode in 'fixed','runtime'){
            $capacity=if($mode -ceq 'runtime'){65}else{$frames}
            $tiles=[int][math]::Ceiling($capacity/32.0); $tensorBytes=8192*$tiles
            $inputBytes=[byte[]]::new($tensorBytes+$(if($mode -ceq 'runtime'){4}else{0}))
            [Array]::Copy($source,$inputBytes,$tensorBytes)
            if($mode -ceq 'fixed'){
                for($t=$frames;$t -lt 32*$tiles;$t++){for($c=0;$c -lt 128;$c++){
                    $at=8192*[int][math]::Floor($t/32)+2048*[int][math]::Floor($c/32)+128*[int][math]::Floor(($t%32)/2)+4*($c%32)+2*($t%2)
                    $inputBytes[$at]=0; $inputBytes[$at+1]=128
                }}
            }else{[BitConverter]::GetBytes([int]$frames).CopyTo($inputBytes,$tensorBytes)}
            $dir=Join-Path $out "$frames-$mode"; [void][IO.Directory]::CreateDirectory($dir)
            [IO.File]::WriteAllBytes((Join-Path $dir 'activations.bin'),$inputBytes)
            $packedWeights=[byte[]]::new(589824); [Array]::Copy($weights,$packedWeights,$packedWeights.Length)
            $packedTables=[byte[]]::new(98304); [Array]::Copy($tables,$packedTables,$packedTables.Length)
            [IO.File]::WriteAllBytes((Join-Path $dir 'weights.bin'),$packedWeights)
            [IO.File]::WriteAllBytes((Join-Path $dir 'tables.bin'),$packedTables)
            $parameters=$baseParameters.Clone(); $parameters.ResBlockFrames=$frames
            $emission=if($mode -ceq 'runtime'){$runtime}else{Invoke-KokoroEmission -Kernel KokoroResBlock16Run -Parameters $parameters}
            $run=Invoke-KokoroDeviceJob -EmissionDirectory $emission.Directory -InputDirectory $dir -Soc $Soc -Runs 1 -Package $Package
            $offset=[BitConverter]::ToInt32($run.Output,40)
            if($offset -lt 192 -or $offset+$tensorBytes -gt $run.Output.Length){throw 'Invalid final tensor offset.'}
            $tensor=[byte[]]::new($tensorBytes); [Array]::Copy($run.Output,$offset,$tensor,0,$tensorBytes)
            $pair.Add([pscustomobject]@{Tensor=$tensor;MedianMs=$run.MedianMs;LibrarySHA256=$emission.LibrarySHA256})
        }
        $mismatches=0; $inactive=0
        for($t=0;$t -lt 96;$t++){for($c=0;$c -lt 128;$c++){
            $at=8192*[int][math]::Floor($t/32)+2048*[int][math]::Floor($c/32)+128*[int][math]::Floor(($t%32)/2)+4*($c%32)+2*($t%2)
            if($t -lt $frames){if($pair[0].Tensor[$at] -ne $pair[1].Tensor[$at] -or $pair[0].Tensor[$at+1] -ne $pair[1].Tensor[$at+1]){$mismatches++}}
            elseif($pair[1].Tensor[$at] -ne 0 -or $pair[1].Tensor[$at+1] -ne 128){$inactive++}
        }}
        $result=[pscustomobject]@{Frames=$frames;Capacity=65;Mismatches=$mismatches;NonzeroInactiveLanes=$inactive;
            FixedMs=$pair[0].MedianMs;RuntimeMs=$pair[1].MedianMs;RuntimeLibrarySHA256=$runtime.LibrarySHA256}
        $results.Add($result); $result
        if($mismatches -or $inactive){throw "Runtime frame parity failed at $frames frames."}
    }
    [IO.File]::WriteAllText((Join-Path $out 'receipt.json'),($results.ToArray()|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
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

# Per-column absolute peaks of a token-major [rows][Columns] tensor (System.Numerics.Vector<float> per chunk).
function Get-KokoroColumnPeaks {
    param([Parameter(Mandatory)][float[]] $Values, [Parameter(Mandatory)][int] $Columns, [float[]] $Add)
    $peak = [double[]]::new($Columns)
    $extra = [float[]]::new(0); if ($Add) { $extra = $Add }        # an empty array returned through $( ) would arrive as $null
    (Get-ColumnPeaksKernel).Invoke($Values, $extra, $Columns, $peak)
    , $peak
}
function ConvertTo-KokoroChannelMajor([float[]] $Values, [int] $Columns) {
    $rows = $Values.Length / $Columns; $o = [float[]]::new($Values.Length)
    for ($r = 0; $r -lt $rows; $r++) { for ($c = 0; $c -lt $Columns; $c++) { $o[$c * $rows + $r] = $Values[$r * $Columns + $c] } }
    , $o
}

# Job input for the connected ALBERT job (KokoroAlbert16Run): every LSB planned from the calibration captures (never the
# test capture), packed as the job's layout says (src/jobs/Kokoro.Albert16Run.ps1 Get-KokoroAlbert16Layout). The test
# capture supplies only the token ids and the expected outputs (d_en, and the stream after mapping_in and each repeat).
function New-KokoroAlbertJobInput {
    param([Parameter(Mandatory)][string] $TestCapture, [Parameter(Mandatory)][string[]] $CalibrationCaptures, [Parameter(Mandatory)][string] $OutputDirectory, [double] $Margin = 1.25)
    Import-CaptureKernels
    . (Join-Path $Root 'src/jobs/Kokoro.Albert16Run.ps1')
    $test = Read-KokoroCapture -Directory $TestCapture
    $cals = @(foreach ($d in $CalibrationCaptures) { Read-KokoroCapture -Directory $d })
    if ($test.Json.block -ne 'albert' -or @($cals | Where-Object { $_.Json.block -ne 'albert' }).Count) { throw 'ALBERT captures required (StockCapture -Block albert).' }
    $idBytes = [IO.File]::ReadAllBytes((Join-Path $test.Root $test.Json.tensors.'bert.input_ids'.file)); $tokens = $idBytes.Length / 4
    $L = Get-KokoroAlbert16Layout -Tokens $tokens
    $read = { param($cap, [string] $name) , (Read-KokoroCaptureTensor -Capture $cap -Name $name) }
    # Calibration peaks: per tensor, or per channel (token-major tensors), optionally of the sum of two tensors.
    $peakCache = @{}
    $peakChannels = { param([string] $name, [int] $columns, [string] $plus) $key = "$name|$columns|$plus"; if ($peakCache.ContainsKey($key)) { return , $peakCache[$key] }; $p = [double[]]::new($columns)
        foreach ($cap in $cals) { $v = & $read $cap $name; $a = if ($plus) { & $read $cap $plus } else { $null }; $q = Get-KokoroColumnPeaks -Values $v -Columns $columns -Add $a; for ($i = 0; $i -lt $columns; $i++) { $p[$i] = [math]::Max($p[$i], $q[$i]) } }
        $peakCache[$key] = $p; , $p }
    $peakTensor = { param([string] $name, [int] $columns, [string] $plus) ((& $peakChannels $name $columns $plus) | Measure-Object -Maximum).Maximum }
    $lsbOf = { param([double] $peak) [math]::Max($peak, 1e-9) * $Margin / 32767 }
    $parameter = { param([string] $name) , (& $read $test $name) }      # checkpoint tensors (identical in every capture)
    $layer = 'bert.encoder.albert_layer_groups.0.albert_layers.0'
    $weights = [byte[]]::new($L.WeightBytes); $tables = [byte[]]::new($L.ParameterBytes)
    $put = { param([string] $record, [byte[]] $bytes) $rec = $L.Tables[$record]; if ($bytes.Length -gt $rec.Bytes) { throw "$record tables: $($bytes.Length) bytes > $($rec.Bytes)" }; [Array]::Copy($bytes, 0, $tables, $rec.Offset, $bytes.Length) }
    $packed = @{}; $convUnits = [ordered]@{}
    # One linear: identity from its input's per-channel LSB, W8 pack (weights checked identical across repeats), tables,
    # and for Scale / Residual the Q15 ratios into the target LSB. Returns the conv output units.
    # The conv-input windows take their LSB from the input's own calibration peak (InputPeak): a window that uses few of its
    # 16 bits leaves the two accumulator groups' low-byte offset (127.5 input LSB times the weight row sum) large next to
    # 2^L, and their 16-bit windows overflow (ffn.0 with the stream LSB: 432 of 2048 channels, Measure-KokoroConvWindows).
    $linear = { param([string] $record, [string] $weight, [string] $parameterName, [double[]] $inputLsb, [double[]] $peak, [double] $targetLsb, [double] $inputPeak)
        $rec = $L.Tables[$record]; $cin = $rec.Cin; $cout = $rec.Cout
        $common = if ($inputPeak -gt 0) { $inputPeak * $Margin / 32767 } else { ($inputLsb | Measure-Object -Maximum).Maximum * 32768 / 32767 }
        $ones = [double[]]::new($cin); [Array]::Fill($ones, 1.0)
        $pack = ConvertTo-KokoroConvPack -Weight (& $parameter "$parameterName.weight") -Bias (& $parameter "$parameterName.bias") -Cout $cout -CinReal $cin -Cin $cin -K 1 -InScale $ones -WindowLsb $common -Peak $peak -Margin $Margin
        if ($packed.ContainsKey($weight)) { if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$packed[$weight], [byte[]]$pack.Weights)) { throw "$record W8 weights differ from the first repeat" } }
        else { $packed[$weight] = $pack.Weights; [Array]::Copy($pack.Weights, 0, $weights, $L.Weights[$weight].Offset, $pack.Weights.Length) }
        $bytes = [Collections.Generic.List[byte]]::new()
        $bytes.AddRange([byte[]](ConvertTo-KokoroIdentityTable -Scales $inputLsb -Channels $cin -Common $common)); $bytes.AddRange([byte[]]$pack.Tables)
        if ($rec.Mode -ne 'Conv' -and $targetLsb -gt 0) {   # target 0: units only (the ratios are written by a later pack)
            $ratios = [byte[]]::new(128L * $cout / 32)
            for ($o = 0; $o -lt $cout; $o++) { $q = [long](Get-Even ($pack.Units[$o] / $targetLsb * 32768)); if ($q -lt 1 -or $q -gt 32767) { throw "$record output ${o}: Q15 ratio $($pack.Units[$o] / $targetLsb) out of range" }
                [BitConverter]::GetBytes([uint32]($q -bor ($q -shl 16))).CopyTo($ratios, 128 * [math]::Floor($o / 32) + 4 * ($o % 32)) }
            $bytes.AddRange($ratios) }
        & $put $record $bytes.ToArray(); $convUnits[$record] = $pack.Units
        , $pack.Units }
    $uniform = { param([int] $n, [double] $v) $a = [double[]]::new($n); [Array]::Fill($a, $v); , $a }
    # Stream LSB: holds its peaks with margin and exceeds every conv unit added into it (Q15 ratio < 1).
    $streamLsb = { param([double] $need, [double[]] $units) [math]::Max($need, (($units | Measure-Object -Maximum).Maximum) * 1.0001) }
    $eps = [double]$test.Json.layerNormEps

    # Embeddings and their LayerNorm.
    $word = & $parameter 'bert.embeddings.word_embeddings.weight'; $position = & $parameter 'bert.embeddings.position_embeddings.weight'; $type = & $parameter 'bert.embeddings.token_type_embeddings.weight'
    $posType = [float[]]::new(128 * $tokens)
    for ($k = 0; $k -lt $tokens; $k++) { for ($c = 0; $c -lt 128; $c++) { $posType[$c * $tokens + $k] = $position[$k * 128 + $c] + $type[$c] } }
    $sumLsb = ((Get-KokoroAbsMax -Values $word) + (Get-KokoroAbsMax -Values $position) + (Get-KokoroAbsMax -Values $type)) * $Margin / 32767
    $wordRows = ConvertTo-KokoroEmbeddingRows -Table $word -Channels 128 -Lsb $sumLsb; [Array]::Copy($wordRows, 0, $weights, $L.Weights.word.Offset, $wordRows.Length)
    $uE = [double[]]@(foreach ($p in (& $peakChannels 'bert.embeddings.output' 128)) { & $lsbOf $p })
    & $put 'embed.ln' (ConvertTo-KokoroLayerNormTable -Gamma (& $parameter 'bert.embeddings.LayerNorm.weight') -Beta (& $parameter 'bert.embeddings.LayerNorm.bias') -OutScales $uE -InputLsb $sumLsb -Epsilon $eps)
    # mapping_in -> H (Scale): the stream LSB of repeat 0 also holds h + dense of repeat 0.
    $mapPeak = & $peakChannels 'bert.encoder.embedding_hidden_mapping_in.output' 768
    $sH = [double[]]::new(13)
    # A conv output unit lies in [nd, 2 nd) with nd = peak * Margin / 32767 (ConvertTo-KokoroConvPack, unless its L floor of 2
    # binds), so a stream that a dense output is added into reserves 2 nd of that dense output (its exact units depend on
    # this stream LSB); the dense pack then checks the reservation held.
    $denseBound = { param([int] $repeat) 2 * (& $lsbOf (& $peakTensor "bert.layer.$repeat.attention.dense.output" 768)) * 1.0001 }
    $need0 = [math]::Max((& $lsbOf ([math]::Max(($mapPeak | Measure-Object -Maximum).Maximum, (& $peakTensor 'bert.layer.0.input' 768 'bert.layer.0.attention.dense.output')))), (& $denseBound 0))
    # Pack once to learn the units, then fix the target and pack again with it (the units do not depend on the target).
    $units = & $linear 'mapping' 'mapping' 'bert.encoder.embedding_hidden_mapping_in' $uE $mapPeak 0 (& $peakTensor 'bert.embeddings.output' 128)
    $sH[0] = & $streamLsb $need0 $units
    $null = & $linear 'mapping' 'mapping' 'bert.encoder.embedding_hidden_mapping_in' $uE $mapPeak $sH[0] (& $peakTensor 'bert.embeddings.output' 128)
    $plan = [ordered]@{ SumLsb = $sumLsb; Stream = $null; A1 = [double[]]::new(12); F = [double[]]::new(12); G = [double[]]::new(12) }
    # Output LSB of every operator (per channel), with the stock tensor it is compared with under -StopAfter.
    $opUnits = [ordered]@{}; $opUnits['embed.ln'] = $uE; $opUnits['mapping'] = (& $uniform 768 $sH[0])
    for ($r = 0; $r -lt 12; $r++) {
        $hLsb = & $uniform 768 $sH[$r]
        $uq = & $linear "q.$r" 'q' "$layer.attention.query" $hLsb (& $peakChannels "bert.layer.$r.attention.query.output" 768) 0 (& $peakTensor "bert.layer.$r.input" 768)
        $uk = & $linear "k.$r" 'k' "$layer.attention.key" $hLsb (& $peakChannels "bert.layer.$r.attention.key.output" 768) 0 (& $peakTensor "bert.layer.$r.input" 768)
        $uv = & $linear "v.$r" 'v' "$layer.attention.value" $hLsb (& $peakChannels "bert.layer.$r.attention.value.output" 768) 0 (& $peakTensor "bert.layer.$r.input" 768)
        $opUnits["q.$r"] = $uq; $opUnits["k.$r"] = $uk; $opUnits["v.$r"] = $uv; $opUnits["attention.$r"] = $uv; $opUnits["dense.$r"] = (& $uniform 768 $sH[$r])
        # Attention: k to one LSB per head, q' with q'_c k'_c in one LSB U_h (|q'| <= 2047), as New-KokoroAlbertAttentionInput.
        $qPeak = & $peakChannels "bert.layer.$r.attention.query.output" 768; $kPeak = & $peakChannels "bert.layer.$r.attention.key.output" 768
        $headLsb = [double[]]::new(12); $qRatios = [double[]]::new(768); $kRatios = [double[]]::new(768)
        for ($h = 0; $h -lt 12; $h++) {
            $km = 0.0; $qm = 0.0; for ($c = 64 * $h; $c -lt 64 * $h + 64; $c++) { $km = [math]::Max($km, $kPeak[$c]); $qm = [math]::Max($qm, $qPeak[$c]) }
            $headK = $km * $Margin / 32767; $headLsb[$h] = $qm * $Margin / 2047 * $headK
            for ($c = 64 * $h; $c -lt 64 * $h + 64; $c++) { $kRatios[$c] = $uk[$c] / $headK; $qRatios[$c] = $uq[$c] * $headK / $headLsb[$h] }
        }
        & $put "attention.$r" ([byte[]]((ConvertTo-KokoroScaleConvertTable -Ratios $qRatios) + (ConvertTo-KokoroScaleConvertTable -Ratios $kRatios) + (ConvertTo-KokoroAttentionConstants -HeadLsb $headLsb -Tokens $tokens)))
        # dense (Residual into H, LSB sH[r]); the context keeps v's units.
        $udense = & $linear "dense.$r" 'dense' "$layer.attention.dense" $uv (& $peakChannels "bert.layer.$r.attention.dense.output" 768) 0 (& $peakTensor "bert.layer.$r.attention.dense.input" 768)
        if (($udense | Measure-Object -Maximum).Maximum -ge $sH[$r]) { throw ("Repeat {0}: dense units up to {1:E3} reach the stream LSB {2:E3} (dense peak {3:E3}, context window LSB {4:E3})" -f $r, ($udense | Measure-Object -Maximum).Maximum, $sH[$r], (& $peakTensor "bert.layer.$r.attention.dense.output" 768), ((($uv | Measure-Object -Maximum).Maximum) * 32768 / 32767)) }
        $null = & $linear "dense.$r" 'dense' "$layer.attention.dense" $uv (& $peakChannels "bert.layer.$r.attention.dense.output" 768) $sH[$r] (& $peakTensor "bert.layer.$r.attention.dense.input" 768)
        # LayerNorm(h + dense) -> A1 (one LSB, holding a1 + ffn_output and above the ffn_output units).
        $ffnOutPeak = & $peakChannels "bert.layer.$r.ffn_output.output" 768
        $needA = & $lsbOf ([math]::Max((& $peakTensor "bert.layer.$r.attention.LayerNorm.output" 768), (& $peakTensor "bert.layer.$r.attention.LayerNorm.output" 768 "bert.layer.$r.ffn_output.output")))
        $geluPeak = & $peakTensor "bert.layer.$r.activation.output" 2048; $plan.G[$r] = & $lsbOf $geluPeak
        $uffnOut = & $linear "ffn_output.$r" 'ffn_output' "$layer.ffn_output" (& $uniform 2048 $plan.G[$r]) $ffnOutPeak 0 $geluPeak
        $plan.A1[$r] = & $streamLsb $needA $uffnOut
        & $put "ln_attention.$r" (ConvertTo-KokoroLayerNormTable -Gamma (& $parameter "$layer.attention.LayerNorm.weight") -Beta (& $parameter "$layer.attention.LayerNorm.bias") -OutScales (& $uniform 768 $plan.A1[$r]) -InputLsb $sH[$r] -Epsilon $eps)
        # ffn (Scale into F, one LSB above the ffn units), gelu, ffn_output (Residual into A1).
       $ffnPeak = & $peakChannels "bert.layer.$r.ffn.output" 2048
        $uffn = & $linear "ffn.$r" 'ffn' "$layer.ffn" (& $uniform 768 $plan.A1[$r]) $ffnPeak 0 (& $peakTensor "bert.layer.$r.attention.LayerNorm.output" 768)
        $plan.F[$r] = & $streamLsb (& $lsbOf (($ffnPeak | Measure-Object -Maximum).Maximum)) $uffn
        $null = & $linear "ffn.$r" 'ffn' "$layer.ffn" (& $uniform 768 $plan.A1[$r]) $ffnPeak $plan.F[$r] (& $peakTensor "bert.layer.$r.attention.LayerNorm.output" 768)
        & $put "gelu.$r" (ConvertTo-KokoroGeluConstants -InputLsb $plan.F[$r] -OutputLsb $plan.G[$r])
        $opUnits["ln_attention.$r"] = (& $uniform 768 $plan.A1[$r]); $opUnits["ffn.$r"] = (& $uniform 768 $plan.F[$r]); $opUnits["gelu.$r"] = (& $uniform 768 $plan.G[$r]); $opUnits["ffn_output.$r"] = (& $uniform 768 $plan.A1[$r])
        $null = & $linear "ffn_output.$r" 'ffn_output' "$layer.ffn_output" (& $uniform 2048 $plan.G[$r]) $ffnOutPeak $plan.A1[$r] $geluPeak
        # LayerNorm(a1 + ffn_output) -> H: the next repeat's stream (holding h + dense of repeat r + 1), or the final output.
        $needH = & $lsbOf ((& $peakTensor "bert.layer.$r.output" 768))
        if ($r -lt 11) { $needH = [math]::Max($needH, [math]::Max((& $lsbOf (& $peakTensor "bert.layer.$($r + 1).input" 768 "bert.layer.$($r + 1).attention.dense.output")), (& $denseBound ($r + 1)))) }
        $sH[$r + 1] = $needH; $opUnits["ln_full.$r"] = (& $uniform 768 $sH[$r + 1])
        & $put "ln_full.$r" (ConvertTo-KokoroLayerNormTable -Gamma (& $parameter "$layer.full_layer_layer_norm.weight") -Beta (& $parameter "$layer.full_layer_layer_norm.bias") -OutScales (& $uniform 768 $sH[$r + 1]) -InputLsb $plan.A1[$r] -Epsilon $eps)
    }
    # Shared windows (New-KokoroAlbert16RunSteps -SharedWindows) are exact only if key and value convert H exactly as query does.
    $identityBytes = 256 * 768 / 32
    for ($r = 0; $r -lt 12; $r++) { foreach ($n in 'k', 'v') {
        $a = $L.Tables["q.$r"].Offset; $b = $L.Tables["$n.$r"].Offset
        for ($i = 0; $i -lt $identityBytes; $i++) { if ($tables[$a + $i] -ne $tables[$b + $i]) { throw "Repeat ${r}: $n's identity table differs from query's; shared windows would not be exact." } } } }
   $dPeak = [double[]]::new(512); foreach ($cap in $cals) { $st = Get-KokoroChannelStats -Values (& $read $cap 'd_en') -Channels 512; for ($i = 0; $i -lt 512; $i++) { $dPeak[$i] = [math]::Max($dPeak[$i], $st.AbsMax[$i]) } }
    $uD = & $linear 'bert_encoder' 'bert_encoder' 'bert_encoder' (& $uniform 768 $sH[12]) $dPeak 0 (& $peakTensor 'bert.layer.11.output' 768)
    $plan.Stream = $sH
    # Inputs, expected outputs.
    $scales = & $uniform 128 $sumLsb
    $pt16 = ConvertTo-KokoroCroutons16 -Values $posType -Frames $tokens -Scales $scales; for ($i = 1; $i -lt $pt16.Length; $i += 2) { $pt16[$i] = $pt16[$i] -bxor 0x80 }
    $jobInput = [byte[]]::new($L.InputBytes); [Array]::Copy($idBytes, $jobInput, $idBytes.Length); [Array]::Copy($pt16, 0, $jobInput, $L.IdBytes, $pt16.Length)
    $out = [IO.Path]::GetFullPath($OutputDirectory); [void][IO.Directory]::CreateDirectory($out)
    [IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), $jobInput); [IO.File]::WriteAllBytes((Join-Path $out 'weights.bin'), $weights); [IO.File]::WriteAllBytes((Join-Path $out 'tables.bin'), $tables)
    $write = { param([string] $file, [float[]] $v) $b = [byte[]]::new(4 * $v.Length); [Buffer]::BlockCopy($v, 0, $b, 0, $b.Length); [IO.File]::WriteAllBytes((Join-Path $out $file), $b) }
    & $write 'expected-d_en-f32.bin' (& $read $test 'd_en')
    & $write 'expected-h0-f32.bin' (ConvertTo-KokoroChannelMajor (& $read $test 'bert.encoder.embedding_hidden_mapping_in.output') 768)
    for ($r = 0; $r -lt 12; $r++) { & $write "expected-h$($r + 1)-f32.bin" (ConvertTo-KokoroChannelMajor (& $read $test "bert.layer.$r.output") 768) }
    $fixture = [ordered]@{ Test = $test.Root; Calibration = @($cals | ForEach-Object { $_.Root }); Phonemes = $test.Json.phonemes; Tokens = $tokens; Margin = $Margin
        StreamLsb = $sH; A1Lsb = $plan.A1; FLsb = $plan.F; GLsb = $plan.G; SumLsb = $sumLsb; DUnits = $uD }
    $fixture | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
    $opUnits['bert_encoder'] = $uD; $opUnits | ConvertTo-Json -Depth 3 -Compress | Set-Content (Join-Path $out 'operator-units.json') -Encoding utf8NoBOM
    $convUnits | ConvertTo-Json -Depth 3 -Compress | Set-Content (Join-Path $out 'conv-units.json') -Encoding utf8NoBOM
    [pscustomobject]$fixture
}

# The stock tensor each operator's output is compared with (token-major, first 768 channels; a sum where the job adds
# into the stream), for New-KokoroAlbert16RunSteps -StopAfter.
function Get-KokoroAlbertOperatorReference {
    param([Parameter(Mandatory)] $Capture, [Parameter(Mandatory)][string] $Operator)
    $read = { param([string] $n) , (Read-KokoroCaptureTensor -Capture $Capture -Name $n) }
    $name, $r = $Operator -split '\.'
    $plus = { param([float[]] $a, [float[]] $b) $o = [float[]]::new($a.Length); for ($i = 0; $i -lt $a.Length; $i++) { $o[$i] = $a[$i] + $b[$i] }; , $o }
    $first768 = { param([float[]] $v, [int] $cols) if ($cols -eq 768) { return , $v }; $rows = $v.Length / $cols; $o = [float[]]::new($rows * 768); for ($t = 0; $t -lt $rows; $t++) { [Array]::Copy($v, $t * $cols, $o, $t * 768, 768) }; , $o }
    switch ($name) {
        'embed' { return , (& $read 'bert.embeddings.output') }
        'mapping' { return , (& $read 'bert.encoder.embedding_hidden_mapping_in.output') }
        'q' { return , (& $read "bert.layer.$r.attention.query.output") }
        'k' { return , (& $read "bert.layer.$r.attention.key.output") }
        'v' { return , (& $read "bert.layer.$r.attention.value.output") }
        'attention' { return , (& $read "bert.layer.$r.attention.dense.input") }
        'dense' { return , (& $plus (& $read "bert.layer.$r.input") (& $read "bert.layer.$r.attention.dense.output")) }
        'ln_attention' { return , (& $read "bert.layer.$r.attention.LayerNorm.output") }
        'ffn' { return , (& $first768 (& $read "bert.layer.$r.ffn.output") 2048) }
        'gelu' { return , (& $first768 (& $read "bert.layer.$r.activation.output") 2048) }
        'ffn_output' { return , (& $plus (& $read "bert.layer.$r.attention.LayerNorm.output") (& $read "bert.layer.$r.ffn_output.output")) }
        'ln_full' { return , (& $read "bert.layer.$r.output") }
        default { throw "No reference for $Operator" }
    }
}

# The connected ALBERT job on the phone: token ids -> d_en, with the stream after mapping_in and after each repeat.
# Reports SNR against the test capture for d_en and every stream dump (error propagation through the 12 repeats).
function Test-KokoroAlbertJob {
    param([string] $TestCapture = (Join-Path $Build 'stock-albert-capture-hello'),
        [string[]] $CalibrationCaptures = @('bench1', 'bench2', 'bench3', 'howareyou' | ForEach-Object { Join-Path $Build "stock-albert-capture-$_" }),
        [string] $Soc = 'SM8550', [int] $Runs = 3, [string] $StopAfter, [switch] $SharedWindows)
    $dir = New-KokoroInputDirectory 'albert/job'
    $fx = New-KokoroAlbertJobInput -TestCapture $TestCapture -CalibrationCaptures $CalibrationCaptures -OutputDirectory $dir
    Import-Evaluator
    $parameters = @{ AlbertTokens = $fx.Tokens }; if ($StopAfter) { $parameters.AlbertStopAfter = $StopAfter }; if ($SharedWindows) { $parameters.AlbertSharedWindows = $true }
    $e = Invoke-KokoroEmission -Kernel KokoroAlbert16Run -Parameters $parameters
    $run = Invoke-KokoroDeviceJob -EmissionDirectory $e.Directory -InputDirectory $dir -Soc $Soc -Runs $Runs
    $layout = Get-Content (Join-Path $e.Directory 'runner-layout.json') -Raw | ConvertFrom-Json
    $slice = { param([long] $at, [long] $n) $b = [byte[]]::new($n); [Array]::Copy($run.Output, $at, $b, 0, $n); , $b }
    $expected = { param([string] $file, [int] $n) $v = [float[]]::new($n); [Buffer]::BlockCopy([IO.File]::ReadAllBytes((Join-Path $dir $file)), 0, $v, 0, 4 * $n); , $v }
    $T = $fx.Tokens
    $d = ConvertFrom-KokoroCroutons16 -Bytes (& $slice $layout.OutputOffset $layout.DBytes) -Frames $T -Units ([double[]]$fx.DUnits)
    $stream = for ($i = 0; $i -le 12; $i++) {
        $u = [double[]]::new(768); [Array]::Fill($u, [double]$fx.StreamLsb[$i])
        $h = ConvertFrom-KokoroCroutons16 -Bytes (& $slice ($layout.DumpOffset + $i * $layout.HBytes) $layout.HBytes) -Frames $T -Units $u
        Get-KokoroSnr $h (& $expected "expected-h$i-f32.bin" (768 * $T)) }
    # -StopAfter: dump slot 1 holds that operator's output (first 768 channels), compared with its stock tensor.
    $stopDb = $null
    if ($StopAfter -and $StopAfter -notin 'embed.ln', 'bert_encoder') {
        $units = [double[]]((Get-Content (Join-Path $dir 'operator-units.json') -Raw | ConvertFrom-Json).$StopAfter)[0..767]
        $got = ConvertFrom-KokoroCroutons16 -Bytes (& $slice ($layout.DumpOffset + $layout.HBytes) $layout.HBytes) -Frames $T -Units $units
        $stopDb = Get-KokoroSnr $got (ConvertTo-KokoroChannelMajor (Get-KokoroAlbertOperatorReference -Capture (Read-KokoroCapture -Directory $TestCapture) -Operator $StopAfter) 768)
    }
    # The output tensors (d_en and the stream dumps) without the header's tick counts, for byte comparisons between emissions.
    $tensorSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData((& $slice $layout.OutputOffset ($run.Output.Length - $layout.OutputOffset))))
    [pscustomobject]@{ Tokens = $T; Soc = $Soc; DEnDb = Get-KokoroSnr $d (& $expected 'expected-d_en-f32.bin' (512 * $T)); StreamDb = $stream; MedianMs = $run.MedianMs
        Skel = $e.LibrarySHA256.Substring(0, 16); Emission = $e.Key; Input = $dir; StopAfter = $StopAfter; Runs = $run.Lines; StopDb = $stopDb; TensorSHA256 = $tensorSha; SharedWindows = $SharedWindows.IsPresent }
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

function Test-KokoroWorkingBank {
    # This is deliberately separate from Verify. data/unit-bank is frozen evidence.
    $bankRoot = Join-Path $Build 'unit-bank'
    $manifestPath = Get-KokoroReferencePath 'unit-bank/bank-manifest.json'

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $bankRoot)) {
        $preserved = Join-Path $Root 'data/unit-bank'
        if (-not (Test-Path -LiteralPath $preserved)) { throw 'Working and preserved banks are missing; restore a manifest-verified backup. Do not recapture.' }
        Copy-Item -LiteralPath $preserved -Destination $bankRoot -Recurse
    }
    foreach ($item in $manifest.Files) {
        $file = [IO.Path]::GetFullPath((Join-Path $bankRoot $item.Path))
        if (-not $file.StartsWith($bankRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Bank manifest path escapes the working bank.' }
        if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -ne $item.Bytes -or
            (Get-FileHash -LiteralPath $file).Hash -cne $item.SHA256) { throw "Working bank integrity mismatch: $($item.Path)" }
    }
    Write-Host "Bank verified: $($manifest.Files.Count) files; preserved copy untouched."
    [pscustomobject]@{ Directory = $bankRoot; ManifestSHA256 = (Get-FileHash -LiteralPath $manifestPath).Hash }
}

function New-KokoroBankDecoderInput {
    <# .SYNOPSIS Assembles the existing all-features table baseline in PowerShell, without a reference model call.
    N shape: first 10,000 bank sentences, 8 samples per token, triphone/right-biphone/phone backoff (count >= 5).
    N/F0/duration levels: Measure-ProsodyFeatures.ps1 level 8. Voicing and t_en: mine.ps1's selected units.
    Equations and interpolation match the unit-bank reference renderer (render_pred, contour_ceiling).

    #>
    param([Parameter(Mandatory)] $Bank, [Parameter(Mandatory)][string] $Directory, [int] $Index = 0)
    $held = @(Get-Content (Get-KokoroReferencePath 'unit-bank/heldout.json') -Raw | ConvertFrom-Json)[$Index]

    $pred = @(Get-Content (Join-Path $Bank.Directory 'prosody-predictions.json') -Raw | ConvertFrom-Json)[$Index]
    if (-not $pred.aligned -or $pred.text -cne $held.text) { throw 'Held-out prediction alignment mismatch.' }
    $levels = $pred.levels[8]; $count = $held.phonemes.Length + 2
    if ($levels.Count -ne $count) { throw 'Prosody token count mismatch.' }
    $durations = [int[]]@($levels | ForEach-Object { [math]::Max(1, [int][math]::Round($_[2], [MidpointRounding]::ToEven)) })
    $frames = [int]($durations | Measure-Object -Sum).Sum
    if ($frames -gt 96) { throw "Held-out sentence $Index needs $frames decoder frames; first Speak supports at most 96. Chunking is Next item 4." }
    [void][IO.Directory]::CreateDirectory($Directory)
    $selectionDir = Join-Path $Directory 'selection'; [void][IO.Directory]::CreateDirectory($selectionDir)
    ConvertTo-Json -InputObject @($held) -Depth 5 | Set-Content (Join-Path $selectionDir 'heldout.json') -Encoding utf8NoBOM
    # Regenerate selections, never syllabus captures. Match the full-bank baseline's measured right-weighted cost
    # (unit-bank curve, 2026-10-10); restore the caller's experiment setting afterward.

    $previousWeights = $env:KOKORO_TARGETW
    try {
        $env:KOKORO_TARGETW = '4,1,0.5,4,8,2'
        & (Get-KokoroReferencePath 'unit-bank/mine.ps1') -Dir $selectionDir -Sizes @(1000000) | ForEach-Object { Write-Host $_ }

    } finally { $env:KOKORO_TARGETW = $previousWeights }
    $selectionPath = Join-Path $selectionDir 'big-selections.json'
    $selection = Get-Content -LiteralPath $selectionPath -Raw | ConvertFrom-Json
    $selected = @($selection.PSObject.Properties.Value | Sort-Object sentences)[-1]
    $picks = $selected.picks[0].path
    if ($picks.Count -ne $count) { throw 'Selection token count mismatch.' }
    $order = @(Get-Content (Join-Path $Bank.Directory 'order.json') -Raw | ConvertFrom-Json)
    if (@($order | Where-Object { $_.text -ceq $held.text -or $_.phonemes -ceq $held.phonemes }).Count) { throw 'Held-out sentence occurs in the syllabus bank.' }

    function Read-BankNpy([IO.Compression.ZipArchive] $Zip, [string] $ArrayName) {
        $entry = $Zip.GetEntry("$ArrayName.npy"); if (-not $entry -or $entry.Length -gt 512MB) { throw "Missing/oversized bank array: $ArrayName" }
        $stream = $entry.Open(); $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $stream.Dispose(); $memory.Dispose() }
        if ($bytes.Length -lt 10 -or [Convert]::ToHexString($bytes[0..7]) -cne '934E554D50590100') { throw "Expected NPY v1: $ArrayName" }
        $offset = 10 + [BitConverter]::ToUInt16($bytes, 8)
        if ($offset -gt $bytes.Length) { throw "Truncated NPY header: $ArrayName" }
        $header = [Text.Encoding]::ASCII.GetString($bytes, 10, $offset - 10)
        if ($header -notmatch "'descr': '(?<dtype><[if][248])'" -or $header -notmatch "'fortran_order': False") { throw "Unsupported bank dtype/layout: $ArrayName" }
        $null = $header -match "'descr': '(?<dtype><[if][248])'"; $dtype = $Matches.dtype
        $null = $header -match "'shape': \((?<dims>[0-9, ]+)\)"; $shape = [int[]]@($Matches.dims.Split(',') | Where-Object { $_.Trim() } | ForEach-Object { [int]$_ })
        $size = [int]$dtype.Substring(2); $elements = 1L; foreach ($dim in $shape) { $elements *= $dim }
        if ($elements * $size -ne $bytes.Length - $offset) { throw "NPY payload length mismatch: $ArrayName" }
        [pscustomobject]@{ Bytes = $bytes; Offset = $offset; Type = $dtype; Shape = $shape }
    }
    function Get-BankArray($Array, [type] $Type, [string] $Dtype) {
        if ($Array.Type -cne $Dtype) { throw "Expected bank dtype $Dtype, got $($Array.Type)." }
        $values = [Array]::CreateInstance($Type, ($Array.Bytes.Length - $Array.Offset) / [int]$Dtype.Substring(2))
        [Buffer]::BlockCopy($Array.Bytes, $Array.Offset, $values, 0, $Array.Bytes.Length - $Array.Offset); , $values
    }
    $tokens = '<' + $held.phonemes + '>'; $wanted = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $contexts = for ($i = 0; $i -lt $count; $i++) {
        $left = if ($i) { $tokens[$i - 1] } else { '#' }; $right = if ($i + 1 -lt $count) { $tokens[$i + 1] } else { '#' }
        $keys = @("3|$left$($tokens[$i])$right", "2|$($tokens[$i])$right", "1|$($tokens[$i])")
        foreach ($key in $keys) { [void]$wanted.Add($key) }; , $keys
    }
    $shapes = [Collections.Generic.Dictionary[string, double[]]]::new([StringComparer]::Ordinal)
    Write-Host 'Building the baseline N shapes from bank sentences 0..9999.'
    for ($chunkIndex = 0; $chunkIndex -lt 10; $chunkIndex++) {
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $Bank.Directory ('chunk-{0:d4}.npz' -f $chunkIndex)))
        try {
            $to = Get-BankArray (Read-BankNpy $zip 'tok_off') ([long]) '<i8'
            $fo = Get-BankArray (Read-BankNpy $zip 'frm_off') ([long]) '<i8'
            $dur = Get-BankArray (Read-BankNpy $zip 'dur') ([int16]) '<i2'
            $noise = Read-BankNpy $zip 'n'; if ($noise.Type -cne '<f2') { throw 'Expected half-precision bank N.' }
        } finally { $zip.Dispose() }
        for ($sentenceIndex = 0; $sentenceIndex -lt $to.Length - 1; $sentenceIndex++) {
            $ph = '<' + $order[1000 * $chunkIndex + $sentenceIndex].phonemes + '>'; $frame = 2L * $fo[$sentenceIndex]
            if ($ph.Length -ne $to[$sentenceIndex + 1] - $to[$sentenceIndex]) { throw 'Bank N token alignment mismatch.' }
            for ($i = 0; $i -lt $ph.Length; $i++) {
                $length = 2 * $dur[$to[$sentenceIndex] + $i]; if ($length -lt 2) { throw 'Nonpositive bank duration.' }
                $left = if ($i) { $ph[$i - 1] } else { '#' }; $right = if ($i + 1 -lt $ph.Length) { $ph[$i + 1] } else { '#' }
                $keys = @("3|$left$($ph[$i])$right", "2|$($ph[$i])$right", "1|$($ph[$i])")
                $use = @($keys | Where-Object { $wanted.Contains($_) })
                if ($use.Count) {
                    $shape = [double[]]::new(8)
                    for ($q = 0; $q -lt 8; $q++) {
                        $position = $q * ($length - 1) / 7.0; $lo = [int][math]::Floor($position); $hi = [math]::Min($lo + 1, $length - 1)
                        $a = [double][BitConverter]::ToHalf($noise.Bytes, [int]($noise.Offset + 2 * ($frame + $lo)))
                        $b = [double][BitConverter]::ToHalf($noise.Bytes, [int]($noise.Offset + 2 * ($frame + $hi)))
                        $shape[$q] = $a + ($b - $a) * ($position - $lo)
                    }
                    foreach ($key in $use) {
                        $acc = $null; if (-not $shapes.TryGetValue($key, [ref]$acc)) { $acc = [double[]]::new(9); $shapes[$key] = $acc }
                        for ($q = 0; $q -lt 8; $q++) { $acc[$q] += $shape[$q] }; $acc[8]++
                    }
                }
                $frame += $length
            }
        }
        Write-Host "  N shapes: $((1 + $chunkIndex) * 1000) sentences"
    }
    $asr = [single[]]::new(512 * $frames); $f0 = [single[]]::new(2 * $frames); $n = [single[]]::new(2 * $frames)
    $at = [int[]]::new($count); for ($i = 1; $i -lt $count; $i++) { $at[$i] = $at[$i - 1] + $durations[$i - 1] }
    foreach ($group in ($picks | Group-Object { [int][math]::Floor($_.s / 1000.0) })) {
        $chunkIndex = [int]$group.Name
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $Bank.Directory ('chunk-{0:d4}.npz' -f $chunkIndex)))
        try {
            $to = Get-BankArray (Read-BankNpy $zip 'tok_off') ([long]) '<i8'
            $fo = Get-BankArray (Read-BankNpy $zip 'frm_off') ([long]) '<i8'
            $dur = Get-BankArray (Read-BankNpy $zip 'dur') ([int16]) '<i2'
            $teArray = Read-BankNpy $zip 't_en'; $te = Get-BankArray $teArray ([int16]) '<i2'
            $scale = Get-BankArray (Read-BankNpy $zip 'scale') ([single]) '<f4'
            $pitch = Read-BankNpy $zip 'f0'; if ($pitch.Type -cne '<f2' -or $teArray.Shape[0] -ne 512 -or $scale.Length -ne 512) { throw 'Bank t_en/F0 layout mismatch.' }
        } finally { $zip.Dispose() }
        for ($i = 0; $i -lt $count; $i++) {
            $pick = $picks[$i]; if ([int][math]::Floor($pick.s / 1000.0) -ne $chunkIndex) { continue }
            $local = [int]$pick.s % 1000; $token = [long]$to[$local] + [int]$pick.i
            $donorPh = '<' + $order[[int]$pick.s].phonemes + '>'
            if ($pick.i -lt 0 -or $token -ge $to[$local + 1] -or $donorPh[[int]$pick.i] -cne $tokens[$i]) { throw 'Selected unit symbol/bounds mismatch.' }
            $frame = [long]$fo[$local]; for ($q = $to[$local]; $q -lt $token; $q++) { $frame += $dur[$q] }
            $donorLength = 2 * $dur[$token]; $length = 2 * $durations[$i]
            for ($channel = 0; $channel -lt 512; $channel++) {
                $value = [single]($te[$channel * $teArray.Shape[1] + $token] * $scale[$channel])
                for ($q = 0; $q -lt $durations[$i]; $q++) { $asr[$channel * $frames + $at[$i] + $q] = $value }
            }
            $acc = $null
            foreach ($key in $contexts[$i]) { if ($shapes.TryGetValue($key, [ref]$acc) -and $acc[8] -ge 5) { break }; $acc = $null }
            if ($null -eq $acc) { $acc = $shapes[$contexts[$i][2]] }
            if ($null -eq $acc -or $acc[8] -le 0) { throw 'No baseline N shape for selected token.' }
            $mean = 0.0; for ($q = 0; $q -lt 8; $q++) { $mean += $acc[$q] / $acc[8] / 8 }
            for ($q = 0; $q -lt $length; $q++) {
                $position = $q * ($donorLength - 1) / [double]($length - 1); $lo = [int][math]::Floor($position); $hi = [math]::Min($lo + 1, $donorLength - 1)
                $a = [double][BitConverter]::ToHalf($pitch.Bytes, [int]($pitch.Offset + 2 * (2 * $frame + $lo)))
                $b = [double][BitConverter]::ToHalf($pitch.Bytes, [int]($pitch.Offset + 2 * (2 * $frame + $hi)))
                $voicing = $a + ($b - $a) * ($position - $lo)
                $f0[2 * $at[$i] + $q] = if ($voicing -gt 10) { [math]::Exp($levels[$i][1]) } else { $voicing }
                $position = 7.0 * $q / ($length - 1); $lo = [int][math]::Floor($position); $hi = [math]::Min($lo + 1, 7)
                $n[2 * $at[$i] + $q] = ($acc[$lo] + ($acc[$hi] - $acc[$lo]) * ($position - $lo)) / $acc[8] - $mean + $levels[$i][0]
            }
        }
    }
    $tensors = [ordered]@{}
    foreach ($name in 'asr', 'F0', 'N') {
        $values = switch ($name) { 'asr' { , $asr }; 'F0' { , $f0 }; 'N' { , $n } }
        if (@($values | Where-Object { -not [single]::IsFinite($_) }).Count) { throw "Nonfinite assembled $name." }
        $bytes = [byte[]]::new(4 * $values.Length); [Buffer]::BlockCopy($values, 0, $bytes, 0, $bytes.Length)
        $file = Join-Path $Directory "$name.f32"; [IO.File]::WriteAllBytes($file, $bytes)
        $tensors[$name] = @{ file = "$name.f32"; shape = $(if ($name -ceq 'asr') { @(1, 512, $frames) } else { @(1, (2 * $frames)) }); bytes = $bytes.Length; sha256 = (Get-FileHash -LiteralPath $file).Hash }
    }
    $descriptor = Join-Path $Directory 'decoder-input.json'
    $frontData = [pscustomobject][ordered]@{ schema = 1; text = $held.text; phonemes = $held.phonemes; voice = 'af_heart'; frames = $frames; durations = $durations; tensors = $tensors
        provenance = @{ bankManifestSHA256 = $Bank.ManifestSHA256; selectionSHA256 = (Get-FileHash $selectionPath).Hash
            predictionsSHA256 = (Get-FileHash (Join-Path $Bank.Directory 'prosody-predictions.json')).Hash; heldOutIndex = $Index
            bankSentences = $selected.sentences; prosodyLevel = 8; nShapeTrainingSentences = 10000; targetWeights = '4,1,0.5,4,8,2'
            assemblyToolSHA256 = (Get-FileHash $PSCommandPath).Hash; selectionToolSHA256 = (Get-FileHash (Get-KokoroReferencePath 'unit-bank/mine.ps1')).Hash } }

    # Files bridge to the pinned Python reference only; PowerShell callers keep the typed object.
    $frontData | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $descriptor -Encoding utf8NoBOM
    Write-Host "Front end: '$($held.text)', $frames decoder frames."
    [pscustomobject]@{ Path = $descriptor; Data = $frontData }
}

function Measure-KokoroStageResidency {
    [CmdletBinding()]
    param(
        [ValidateRange(1,1073741824)][long[]]$VtcmGrantBytes=@(4MB,8MB),
        [ValidateRange(2,273)][int[]]$DecoderFrames=@(2,8,16,32,48,63,64,85,96,128),
        [ValidateRange(2,64)][int]$BatchTiles=14
    )
    if ($BatchTiles % 2) { throw 'Harmonic layouts require an even BatchTiles value.' }
    # Reuse the actual layouts in an isolated scope; loading them emits no code.
    $layouts=New-Module -ArgumentList $Root -ScriptBlock {
        param($root)
        . (Join-Path $root 'src/jobs/Kokoro.DecoderRun16.ps1')
        . (Join-Path $root 'src/jobs/Kokoro.HarmonicStft16Run.ps1')
        . (Join-Path $root 'src/jobs/Kokoro.HarmonicSource16Run.ps1')
        . (Join-Path $root 'src/jobs/Kokoro.Generator60x16Run.ps1')
        . (Join-Path $root 'src/jobs/Kokoro.GeneratorTail16Run.ps1')
    }
    $stages=@(
        @{Name='Decoder';Function='Get-KokoroDecoder16Layout';Native=$false;Batch=$false},
        @{Name='HarmonicSource';Function='Get-KokoroHarmonicSource16Layout';Native=$true;Batch=$true},
        @{Name='HarmonicStft';Function='Get-KokoroHarmonicStft16Layout';Native=$true;Batch=$true},
        @{Name='Generator60x';Function='Get-KokoroGenerator60x16Layout';Native=$true;Batch=$true},
        @{Name='GeneratorTail';Function='Get-KokoroGeneratorTail16Layout';Native=$true;Batch=$true}
    )
    foreach ($stage in $stages) {
        $samples=[Collections.Generic.List[object]]::new()
        $admission=[Collections.Generic.List[object]]::new()
        $first=$null;$last=$null
        # Exhaustive integer search, bounded by the shared native-frame domain.
        for ($frame=2;$frame -le 273;$frame++) {
            $nativeFrames=if ($stage.Native) {120*$frame+1} else {$frame}
            $arguments=@{Frames=$nativeFrames}
            if ($stage.Batch) { $arguments.BatchTiles=$BatchTiles }
            try { $layout=& $layouts {param($name,$parameters) & $name @parameters} $stage.Function $arguments }
            catch {
                $admission.Add([pscustomobject]@{DecoderFrames=$frame;Admitted=$false;Reason=$_.Exception.Message})
                continue
            }
            $admission.Add([pscustomobject]@{DecoderFrames=$frame;Admitted=$true;Bytes=[long]$layout.VtcmBytes})
            if ($null -eq $first) { $first=$layout };$last=$layout
            if ($frame -in $DecoderFrames) {
                $samples.Add([pscustomobject]@{DecoderFrames=$frame;NativeFrames=$nativeFrames;
                    VtcmBytes=[long]$layout.VtcmBytes;Regions=$layout.Regions})
            }
        }
        if ($samples.Count -lt 2) { throw "Not enough admitted samples for $($stage.Name)." }
        $meanFrame=0.0;$meanBytes=0.0
        foreach ($sample in $samples) { $meanFrame+=$sample.DecoderFrames;$meanBytes+=$sample.VtcmBytes }
        $meanFrame/=$samples.Count;$meanBytes/=$samples.Count
        $cross=0.0;$spread=0.0
        foreach ($sample in $samples) {
            $delta=$sample.DecoderFrames-$meanFrame
            $cross+=$delta*($sample.VtcmBytes-$meanBytes);$spread+=$delta*$delta
        }
        if ($spread -le 0) { throw 'The fit requires distinct frame counts.' }
        $slope=$cross/$spread;$fixed=$meanBytes-$slope*$meanFrame;$maxError=0.0
        foreach ($sample in $samples) { $maxError=[Math]::Max($maxError,[Math]::Abs($sample.VtcmBytes-$fixed-$slope*$sample.DecoderFrames)) }
        $regions=@(foreach ($name in $first.Regions.Keys) {
            if ($first.Regions[$name].Bytes -ne $last.Regions[$name].Bytes) {
                [pscustomobject]@{Name=$name;FirstBytes=[long]$first.Regions[$name].Bytes;
                    LastBytes=[long]$last.Regions[$name].Bytes}
            }
        })
        $fits=@(foreach ($grant in $VtcmGrantBytes) {
            $fitting=@($admission | Where-Object {$_.Admitted -and $_.Bytes -le $grant})
            $largest=if ($fitting.Count) {$fitting[-1]} else {$null}
            [pscustomobject]@{GrantBytes=$grant;LargestDecoderFrames=$(if ($null -ne $largest) {$largest.DecoderFrames} else {0});
                VtcmBytes=$(if ($null -ne $largest) {$largest.Bytes} else {$null});
                ReachedLayoutDomainLimit=($null -ne $largest -and $largest.DecoderFrames -eq 273)}
        })
        [pscustomobject]@{PSTypeName='Kokoro.StageResidency';Stage=$stage.Name;BatchTiles=$BatchTiles;
            FixedBytes=$fixed;BytesPerDecoderFrame=$slope;FitMaxErrorBytes=$maxError;
            FitKind='Least squares of allocated VTCM; tile/page rounding and placement are retained';
            MinimumVtcmBytes=[long]$first.VtcmBytes;GrantFits=$fits;Samples=$samples.ToArray();
            WholeUtteranceRegions=$regions;RegionMeaning='Full-length allocations in the current stage-major job, not a streaming liveness proof';
            WeightRegion=$first.Regions['Weights'];Admission=$admission.ToArray();
            LayoutSource=$stage.Function;LayoutSHA256=(Get-FileHash (Join-Path $Root ('src/jobs/'+@{Decoder='Kokoro.DecoderRun16.ps1';HarmonicSource='Kokoro.HarmonicSource16Run.ps1';HarmonicStft='Kokoro.HarmonicStft16Run.ps1';Generator60x='Kokoro.Generator60x16Run.ps1';GeneratorTail='Kokoro.GeneratorTail16Run.ps1'}[$stage.Name]))).Hash}
    }
}

function New-KokoroDiagnosticHost {
    param([Parameter(Mandatory)][string] $OutputDirectory)
    $outputPath = [IO.Path]::GetFullPath($OutputDirectory)
    $buildPrefix = [IO.Path]::GetFullPath($Build) + [IO.Path]::DirectorySeparatorChar
    if (-not $outputPath.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Path -LiteralPath $outputPath)) { throw 'Choose a fresh host output directory under build/.' }
    Import-Evaluator
    $sourceRoot = Get-KokoroPwshSource -Pin pwshUpstream
    $setupPath = Join-Path $sourceRoot 'setup.ps1'
    # Admission also checks that the running emitter and packaged SMA versions match.
    $null = & (Join-Path $Root 'src/build/Import-PwshBuildFunction.ps1') -SetupPath $setupPath -FunctionName New-SignedApk
    $baseDirectory = Join-Path $outputPath 'base'
    [void][IO.Directory]::CreateDirectory($baseDirectory)
    $baseApk = Join-Path $baseDirectory 'pwsh-base-arm64.apk'
    $cacheRoot = Join-Path $env:LOCALAPPDATA 'Kokoro-Hexagon/UpstreamBuild'
    $buildLog = Join-Path $outputPath 'host-build.log'
    if (-not $env:PWSH_SIGNING_KEY -or -not [IO.File]::Exists($env:PWSH_SIGNING_KEY)) {
        throw 'Configure PWSH_SIGNING_KEY with the existing upstream signing identity before building the base host.'
    }
    & $setupPath -Headless -Step 9 -Architecture arm64 -Payload Minimal -Startup Profile -Debuggable -Packages Folder `
        -CacheDirectory (Join-Path $cacheRoot 'packages') -SigningKeyPath $env:PWSH_SIGNING_KEY `
        -OutputDirectory $baseDirectory -ApkPath $baseApk -KeepIntermediates -AcceptWritePlan *> $buildLog
    if (-not (Test-Path -LiteralPath $baseApk)) { throw 'Pinned host build failed; inspect the local host-build.log.' }
    & (Join-Path $Root 'tools/Build-KokoroApk.ps1') -BaseApk $baseApk -BaseSHA256 (Get-FileHash -LiteralPath $baseApk).Hash `
        -SetupPath $setupPath -OutputDirectory $outputPath -Debuggable -DiagnosticVendorRpc
}

# Run -Case measurement cases and the function each one calls.
$script:KokoroMeasurementCases = [ordered]@{
    'generator-pmu' = 'Test-KokoroGeneratorPmu'
    'generator-seeded-noise' = 'Test-KokoroGeneratorSeededNoise'
    'source-seeded-noise' = 'Test-KokoroSourceSeededNoise'
    'generator-source-boundary' = 'Test-KokoroGeneratorSourceBoundary'
    'generator-tile-equivalence' = 'Test-KokoroGeneratorTileEquivalence'
    'decoder-delay-equivalence' = 'Test-KokoroDecoderDelayEquivalence'
    'generator-weight-precision' = 'Test-KokoroGeneratorWeightPrecision'
    'generator-representation' = 'Test-KokoroGeneratorRepresentation'
    'generator-propagation' = 'Test-KokoroGeneratorPropagation'
    'student-speech' = 'Invoke-KokoroStudentSpeech'
    'generator-normalization' = 'Invoke-KokoroGeneratorNormalization'
    'generator-score' = 'Invoke-KokoroGeneratorScore'
}

# Dot-sourced (. ./Invoke-KokoroDevelopment.ps1): the functions above are the API; no command runs.
if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Command) {
    'Student' {
        $studentArguments=@{}
        if($Parameters){foreach($key in $Parameters.Keys){$studentArguments[$key]=$Parameters[$key]}}
        & (Join-Path $Root 'student/Invoke-Student.ps1') @studentArguments
    }
    'CompareAudio' {
        if (-not $Reference -or -not $Path) { throw 'CompareAudio needs -Reference and -Path (mono WAVs at one rate).' }
        Import-Module (Join-Path $Root 'tools/Kokoro.AudioMeasurement.psm1')
        $yardstick=if ($Parameters -and $Parameters.Yardstick) { [string]$Parameters.Yardstick } else { $null }
        Compare-KokoroAudio -Reference $Reference -Candidate $Path -Yardstick $yardstick -ImageDirectory $OutputDirectory
    }
    'PhoneSpeech' {
        if (-not $Parameters -or -not $Parameters.Text) { throw 'PhoneSpeech needs -Parameters @{Text=<sentence>}.' }
        $speech = @{}; foreach ($k in $Parameters.Keys) { $speech[$k] = $Parameters[$k] }
        if ($OutputDirectory) { $speech.OutputDirectory = $OutputDirectory }
        Invoke-KokoroPhoneSpeech -Soc $Soc @speech
    }
    'MeasureAudio' {
        if (-not $Path) { throw 'MeasureAudio needs -Path (a WAV file or folder).' }
        Import-Module (Join-Path $Root 'tools/Kokoro.AudioMeasurement.psm1')
        Measure-KokoroAudio -Path $Path
    }
    'CopySynthesis' {
        if(-not $OutputDirectory){throw 'CopySynthesis needs a fresh -OutputDirectory under this worktree build/.'}
        $copyArguments=@{OutputDirectory=$OutputDirectory}
        if($Parameters -and $Parameters.Ladder){
            if(-not $Path){throw 'The ladder requires -Path to the run2 rendering receipt.'}
            $copyArguments.LadderReceipt=$Path
        }elseif($Path){$copyArguments.CorrelationReceipt=$Path}
        & (Join-Path $Root 'tools/Measure-KokoroCopySynthesis.ps1') @copyArguments
    }
    'WeightAssembly' {
        if (-not $Path -or -not $OutputDirectory) { throw 'WeightAssembly needs -Path (native generator weights) and -OutputDirectory (under build).' }
        Import-Module (Join-Path $Root 'tools/Kokoro.ManagedPayload.psm1')
        New-KokoroWeightAssembly -Path $Path -OutputDirectory $OutputDirectory
    }
    'StageResidency' {
        if ($null -eq $Parameters) { Measure-KokoroStageResidency }
        else { Measure-KokoroStageResidency @Parameters }
    }
    'Status' {
        $head = git -C $Root log -1 --format='%h %s'
        $dirty = @(git -C $Root status --porcelain).Count
        "Kokoro-Hexagon  $head"
        "                $dirty uncommitted"
        $next = Get-NextStep
        "Next            ($(if ($next.Handoff) { $next.Handoff } else { 'no project notes' }))"

        $next.Steps | ForEach-Object { Format-Wrapped $_ -Hang 3 }
        'Ratchet cases'
        (Import-PowerShellDataFile (Join-Path $Root 'tools/Kokoro.Ratchet.psd1')).Cases | ForEach-Object {
            Format-Wrapped $(if ($_.Blocked) { 'blocked: ' + $_.Blocked } else { $_.Kernel }) -Hang 33 -Lead ('{0,-32} ' -f $_.Name)
        }
        ''
        'Commands (Get-Help ./Invoke-KokoroDevelopment.ps1 -Full):'
        '  Status Verify BuildHost Ratchet Run Emit Check Compare JobInput Capture MeasureAudio StockCapture Speak FrontEnd PrecomputedDecoder Student Zira Albert Find Tools'
        'Contract: AGENTS.md. Reference manuals: Find-Reference (Pwsh-Development/tools/SharedLibrary.psm1).'
    }
    'BuildHost' {
        if (-not $OutputDirectory) { throw 'BuildHost needs -OutputDirectory under build/.' }
        New-KokoroDiagnosticHost -OutputDirectory $OutputDirectory
    }
    'LineEndings' { Restore-KokoroLineEndings -File $Path }
    'Verify' {
        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $commandValues = ($MyInvocation.MyCommand.Parameters['Command'].Attributes |
            Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }).ValidValues
        $checks = [ordered]@{
            'parse' = {
                $files = @(git -C $Root -c core.quotepath=false ls-files '*.ps1' '*.psm1' '*.psd1')
                if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
                $failures = [Collections.Generic.List[string]]::new()
                foreach ($file in $files) {
                    $tokens = $null; $parseErrors = $null
                    $null = [System.Management.Automation.Language.Parser]::ParseFile(
                        (Join-Path $Root $file), [ref]$tokens, [ref]$parseErrors)
                    foreach ($parseError in $parseErrors) {
                        $failures.Add("${file}:$($parseError.Extent.StartLineNumber): $($parseError.Message)")
                    }
                }
                if ($failures.Count) { throw ($failures -join '; ') }
            }
            'build-untracked' = {
                $files = @(git -C $Root ls-files build)
                if ($LASTEXITCODE -ne 0) { throw 'git ls-files build failed.' }
                if ($files.Count) { throw ('tracked build files: ' + ($files -join ', ')) }
            }
            'size' = {
                $files = @(git -C $Root -c core.quotepath=false ls-files)
                if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
                $oversized = foreach ($file in $files) {
                    $length = (Get-Item -LiteralPath (Join-Path $Root $file)).Length
                    if ($length -gt 1MB) { "${file}: $length bytes" }
                }
                if ($oversized) { throw ($oversized -join '; ') }
            }
            'handoff' = {
                # A clone without the project notes has no handoff to check.
                if (-not (Test-Path $script:NotesRoot)) { return }
                $next = Get-NextStep
                $newest = Get-ChildItem $script:NotesRoot -Filter 'handoff-*.md' |

                    Sort-Object Name | Select-Object -Last 1
                if (-not $newest -or $next.Handoff -cne $newest.Name) { throw 'Get-NextStep did not return the newest handoff.' }
                if (-not $next.Steps.Count) { throw "$($next.Handoff) has no next steps." }
                foreach ($step in $next.Steps) {
                    if ($step -notmatch '^\d+\. ') { throw "Unnumbered step: $step" }
                    $namedCommand = $false
                    foreach ($name in [regex]::Matches($step, '`([^`]+)`')) {
                        if ($commandValues -ccontains $name.Groups[1].Value) { $namedCommand = $true }
                    }
                    if (-not $namedCommand -and $step -cnotmatch 'new command `[A-Za-z][A-Za-z0-9]*`') {
                        throw "Step has no entrypoint command or new command name: $step"
                    }
                }
            }
            'status' = {
                $output = & $pwsh -NoProfile -File $PSCommandPath Status 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { throw "Status exited ${LASTEXITCODE}: $output" }
            }
            'Test-DspQueueLayout' = {
                $output = & $pwsh -NoProfile -File (Join-Path $Root 'tools/Test-DspQueueLayout.ps1') 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { throw "Test-DspQueueLayout exited ${LASTEXITCODE}: $output" }
            }
            'Test-SplitBreathGroups' = {
                $output = & $pwsh -NoProfile -File (Join-Path $Root 'tools/Test-SplitBreathGroups.ps1') 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { throw "Test-SplitBreathGroups exited ${LASTEXITCODE}: $output" }
            }
            'case-pairs' = { Test-KokoroCasePairs }
            'audio-measurement' = {
                Import-Module (Join-Path $Root 'tools/Kokoro.AudioMeasurement.psm1')
                Test-KokoroAudioMeasurement
            }
        }
        $failed = $false
        foreach ($name in $checks.Keys) {
            try {
                $result = & $checks[$name]
                if ($name -eq 'case-pairs') { $result } else { "PASS $name" }
            }
            catch {
                $failed = $true
                'FAIL {0}: {1}' -f $name, ($_.Exception.Message -replace '\s+', ' ')
            }
        }
        if ($failed) { exit 1 }
        exit 0
    }
    'Ratchet' {
        Resume-Phone
        Test-KokoroCasePairs
        Import-Evaluator
        if ($Case) { Test-KokoroRatchet -Case $Case } else { Test-KokoroRatchet }
    }
    'Run' {
        if (-not $Case) { throw 'Run needs -Case (see Status for names).' }
        # Measurement cases ($script:KokoroMeasurementCases): each writes a fresh receipt directory, build/<case>-<UTC time>
        # unless -OutputDirectory is given, and takes -OutputDirectory, -Soc, -Package and the case's -Parameters.
        if ($script:KokoroMeasurementCases.Contains($Case)) {
            if (-not $OutputDirectory) { $OutputDirectory = Join-Path $Build ('{0}-{1:yyyyMMddTHHmmss}' -f $Case, [DateTime]::UtcNow) }
            $caseParameters = if ($Parameters) { $Parameters } else { @{} }
            & $script:KokoroMeasurementCases[$Case] -OutputDirectory $OutputDirectory -Soc $Soc -Package $HostPackage @caseParameters
            break
        }
        if($Case -ceq 'decoder-constants'){
            $gateParameters=if($Parameters){$Parameters}else{@{}}
            Test-KokoroDecoderConstants -FixtureDirectory $Path -OutputDirectory $OutputDirectory -BaselineLibrary $Reference -Soc $Soc -Package $HostPackage @gateParameters
            break
        }
        if($Case -ceq 'decoder-constants-corpus'){
            Test-KokoroDecoderConstantsCorpus -PeachFixtureDirectory $Path -OutputDirectory $OutputDirectory -Soc $Soc -Package $HostPackage @Parameters
            break
        }
        if ($Case -ceq 'device-readiness') { Get-KokoroDeviceReadiness -Soc $Soc -Package $HostPackage; break }
        if ($Case -ceq 'generator-template1') {
            if (-not $OutputDirectory) { throw 'Template-1 gate needs -OutputDirectory <fresh build directory>.' }
            $templateParameters = if ($Parameters) { $Parameters } else { @{} }
            & (Join-Path $Root 'tools/Test-KokoroGeneratorTemplate1.ps1') -OutputDirectory $OutputDirectory -Soc $Soc -Package $HostPackage -Runs $(if ($Runs) { $Runs } else { 5 }) @templateParameters
            break
        }
        if ($Case -ceq 'host-install') { Install-KokoroDiagnosticHost -Path $Path -Soc $Soc; break }
        if ($Case -ceq 'harmonic-source-objects') {
            if (-not $Path) { throw 'Harmonic-source object check needs -Path <existing source fixture>.' }
            Import-Evaluator
            $sourceParameters = if ($Parameters) { $Parameters } else { @{ ResBlockFrames=7801 } }
            $sourceEmission = Invoke-KokoroEmission -Kernel KokoroHarmonicSource16Run -Parameters $sourceParameters
            $sourceRun = Invoke-KokoroDeviceJob -EmissionDirectory $sourceEmission.Directory -EmissionArtifact $sourceEmission -InputDirectory $Path -Soc $Soc -Runs $(if ($Runs) { $Runs } else { 3 }) -Package $HostPackage
            $sourceParity = $null
            if ($Reference) {
                $referenceOutput = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Reference))
                if ($referenceOutput.Length -ne $sourceRun.Output.Length) { throw 'Harmonic-source reference output length differs.' }
                for ($sourceByte=256; $sourceByte -lt $referenceOutput.Length; $sourceByte++) {
                    if ($referenceOutput[$sourceByte] -ne $sourceRun.Output[$sourceByte]) { throw "Harmonic-source output differs at byte $sourceByte." }
                }
                $sourceParity = $true
            }
            [pscustomobject]@{ Kernel=$sourceEmission.Kernel; Frames=$sourceEmission.Layout.Frames; LibrarySHA256=$sourceEmission.LibrarySHA256
                ReferencePayloadExact=$sourceParity; MedianMs=$sourceRun.MedianMs; OutputPath=$sourceRun.OutputPath; Lines=$sourceRun.Lines
                JsonArtifacts=@(Get-ChildItem -LiteralPath $sourceEmission.Directory -File -Filter '*.json').Count }
            break
        }
        if ($Case -ceq 'generator-runtime-frames') {
            if(-not $Path -or -not $OutputDirectory){throw 'Runtime-frame check needs -Path <existing stage fixture> and -OutputDirectory <fresh build directory>.'}
            Test-KokoroGeneratorRuntimeFrames -FixtureDirectory $Path -OutputDirectory $OutputDirectory -Soc $Soc -Package $HostPackage
            break
        }
        Resume-Phone; Import-Evaluator
        $c = Get-KokoroRatchetCase $Case
        'inputs:'; Show-InputHashes (Join-Path $Root $c.Input)
        $p = if ($Parameters) { $Parameters } else { $c.Parameters }
        $e = Invoke-KokoroEmission -Kernel $c.Kernel -Parameters $p
        "skel  $($e.LibrarySHA256)  (emission $($e.Key))"
        $a = @{ Case = $Case; Hypothesis = $(if ($Hypothesis) { $Hypothesis } else { "run $Case" }) }
        if ($Parameters) { $a.Parameters = $Parameters }
        if ($Runs) { $a.Runs = $Runs }
        $attemptStarted = [DateTime]::UtcNow
        $r = Invoke-KokoroExperiment @a -Package $HostPackage
        $receipt = Get-ChildItem $e.Directory -Filter 'device-receipt-*.txt' | Where-Object { $_.LastWriteTimeUtc -ge $attemptStarted } | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($receipt) { 'device receipt:'; Get-Content $receipt.FullName | Where-Object { $_ -notmatch 'SHA256=' } | ForEach-Object { "  $_" } }
        "commit $(git -C $Root rev-parse --short HEAD)$(if (git -C $Root status --porcelain) { ' (uncommitted changes)' })"
        $r | Format-List Status, MedianMs, PcmSnrDb, Clipped, PcmSHA256, Wav, Reason
        if ($r.Status -eq 'crash') { throw 'Device experiment failed; see the diagnostic receipt above.' }
    }
    'Emit' {
        Import-Evaluator
        if ($Case) { $c = Get-KokoroRatchetCase $Case; $Kernel = $c.Kernel; if (-not $Parameters) { $Parameters = $c.Parameters } }
        if (-not $Kernel) { throw 'Emit needs -Case or -Kernel.' }
        $e = Invoke-KokoroEmission -Kernel $Kernel -Parameters $(if ($Parameters) { $Parameters } else { @{} })
        $e
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
        if ($DecoderInput) {
            if ($Block -eq 'albert' -or $PhonemesFrom) { throw 'DecoderInput is for decoder/generator captures and cannot be combined with PhonemesFrom.' }
            $DecoderInput = [IO.Path]::GetFullPath($DecoderInput)
            $frontEnd = if ($DecoderInputData) { $DecoderInputData } else { Get-Content -LiteralPath $DecoderInput -Raw | ConvertFrom-Json }
            $Phonemes = $frontEnd.phonemes; $Voice = $frontEnd.voice
            if ($Voice -cne 'af_heart') { throw 'The current unit-bank tables are af_heart only.' }
        }
        if ($PhonemesFrom) {
            $from = Get-Content (Join-Path $(if ([IO.Path]::IsPathRooted($PhonemesFrom)) { $PhonemesFrom } else { Join-Path $Build $PhonemesFrom }) 'capture-spec.json') -Raw | ConvertFrom-Json
            $Phonemes = $from.phonemes; $Voice = $from.voice; $Seed = $from.seed
        }
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
        if ($DecoderInput) {
            $spec.decoderInput = @{ path = $DecoderInput; sha256 = (Get-FileHash -LiteralPath $DecoderInput).Hash }
            $spec.decoderInputToolSha256 = (Get-FileHash -LiteralPath (Get-KokoroReferencePath 'capture_decoder_input.py')).Hash

        }
        $specPath = Join-Path $out 'capture-spec.json'
        $spec | ConvertTo-Json -Depth 8 | Set-Content $specPath -Encoding utf8NoBOM
        if (-not $Python) { throw 'StockCapture needs KOKORO_PYTHON (an interpreter with stock PyTorch Kokoro).' }
        & $Python -I (Get-KokoroReferencePath $script) --spec $specPath

        if ($LASTEXITCODE -or -not (Test-Path (Join-Path $out 'capture.json'))) { throw "Stock $Block capture failed." }
        "capture: $out"
    }
    'Zira' {
        if (-not $Text) { throw 'Zira needs -Text.' }
        $ziraDirectory = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $Build ("zira-{0:yyyyMMddTHHmmssZ}" -f [DateTime]::UtcNow) }
        if (-not $ziraDirectory.StartsWith($Build + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $ziraDirectory)) { throw 'Zira requires a new output directory under build/.' }
        [void][IO.Directory]::CreateDirectory($ziraDirectory)
        & (Get-KokoroReferencePath 'unit-bank/zira.ps1') -Text $Text -OutPrefix (Join-Path $ziraDirectory 'speech')

    }
    'Speak' {
        if ($Soc -cne 'SM8550') { throw 'First Speak is the SM8550 gate; SM8635 follows chunked Speak (Next item 4).' }
        $bank = Test-KokoroWorkingBank
        $out = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $Build ("speak-{0:yyyyMMddTHHmmssZ}" -f [DateTime]::UtcNow) }
        if (-not $out.StartsWith($Build + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Speak requires a new output directory under build/.' }
        [void][IO.Directory]::CreateDirectory($out)
        # -Path can reuse an assembled descriptor after a capture/build failure; the reference loader checks every hash.
        if ($Path) {
            $frontInput = [IO.Path]::GetFullPath($Path)
            $front = Get-Content -LiteralPath $frontInput -Raw | ConvertFrom-Json
        } else {
            $assembled = New-KokoroBankDecoderInput -Bank $bank -Directory (Join-Path $out 'front-end') -Index $HeldOutIndex
            $frontInput = $assembled.Path; $front = $assembled.Data
        }
        if ($front.provenance.bankManifestSHA256 -cne $bank.ManifestSHA256) { throw 'Assembled input belongs to a different bank manifest.' }
        $decoderCapture = Join-Path $out 'decoder'; $generatorCapture = Join-Path $out 'generator'
        foreach ($blockName in 'decoder', 'generator') {
            & $PSCommandPath StockCapture -Block $blockName -DecoderInput $frontInput -DecoderInputData $front -Seed 17 -OutputDirectory (Join-Path $out $blockName) | ForEach-Object { Write-Host $_ }
        }
        # Both independently loaded stock models must have consumed exactly the assembled tensors.
        foreach ($capDir in $decoderCapture, $generatorCapture) {
            $captured = Get-Content -LiteralPath (Join-Path $capDir 'capture.json') -Raw | ConvertFrom-Json
            $tensorIndex = 0
            foreach ($name in 'asr', 'F0', 'N') {
                if ($captured.tensors.PSObject.Properties["decoder.input.$tensorIndex"].Value.sha256 -cne $front.tensors.$name.sha256) { throw "Syllabus did not consume the assembled $name." }
                $tensorIndex++
            }
        }
        $referenceDir = if ($Reference) { [IO.Path]::GetFullPath($Reference) } else { Join-Path $Build 'decoder-generator-fixture-20261009' }
        $captureMapForSpeak = @{}; $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $walk = $null; $walk = {
            param([string] $Fixture)
            if (-not $visited.Add($Fixture)) { return }
            $record = Get-Content -LiteralPath (Join-Path $Fixture 'fixture.json') -Raw | ConvertFrom-Json
            $targetCapture = if ($record.Graph -ceq 'Decoder16') { $decoderCapture } else { $generatorCapture }
            if ($record.PSObject.Properties['Capture'] -and $record.Capture) { $captureMapForSpeak[[IO.Path]::GetFullPath($record.Capture)] = $targetCapture }
            if ($record.PSObject.Properties['Captures']) { foreach ($capture in $record.Captures) { $captureMapForSpeak[[IO.Path]::GetFullPath($capture.Directory)] = $targetCapture } }
            foreach ($key in 'TenFixture', 'SixtyFixture', 'FrontFixture', 'SourceFixture', 'DecoderFixture', 'StageFixture', 'TailFixture', 'NoiseResFixture', 'UpInputScaleFixture') {
                if ($record.PSObject.Properties[$key] -and $record.$key) { & $walk $record.$key }
            }
        }
        & $walk $referenceDir
        Import-Evaluator
        $inputDir = New-KokoroJobInput -Reference $referenceDir -CaptureMap $captureMapForSpeak -OutputDirectory (Join-Path $out 'job-input')
        $fixture = Get-Content -LiteralPath (Join-Path $inputDir 'fixture.json') -Raw | ConvertFrom-Json
        if ($fixture.Frames -ne 120 * $front.frames + 1 -or $fixture.Samples -ne 600 * $front.frames) { throw 'Assembled input and connected job frame counts differ.' }
        # Fourteen tiles leave room for this held-out group's resident activations in SM8550's measured 8 MiB.
        $emission = Invoke-KokoroEmission -Kernel KokoroDecoderGenerator16Run -Parameters @{ ResBlockFrames = [int]$fixture.Frames; ResidentHvxThreads = 4; ResidentBatchTiles = 14 }
        $layout = Get-Content -LiteralPath (Join-Path $emission.Directory 'runner-layout.json') -Raw | ConvertFrom-Json
        if ($layout.VtcmBytes -gt 8388608) { throw "Speak needs $($layout.VtcmBytes) VTCM bytes; SM8550 grants 8388608. Choose a shorter group." }
        $phone = Invoke-KokoroDeviceJob -EmissionDirectory $emission.Directory -InputDirectory $inputDir -Soc $Soc -Runs $(if ($Runs) { $Runs } else { 3 })
        $wav = Join-Path $out 'dsp.wav'
        $metrics = & (Join-Path $Root 'tools/Measure-KokoroPcmSnr.ps1') -OutputPath $phone.OutputPath -FixtureDirectory $inputDir -WavPath $wav
        $result = [ordered]@{ Variant = 'unit-bank front end'; Text = $front.text; Soc = $Soc; DecoderFrames = $front.frames; Samples = $metrics.Samples
            PcmSnrDb = $metrics.PcmSnrDb; Clipped = $metrics.ClippedSamples; PcmSHA256 = $metrics.PcmSHA256; MedianDspMs = $phone.MedianMs
            DspRtf = $phone.MedianMs / 1000 / ($metrics.Samples / 24000.0); LibrarySHA256 = $emission.LibrarySHA256; Emission = $emission.Directory
            DecoderInput = $frontInput; DecoderInputSHA256 = (Get-FileHash $frontInput).Hash; JobInput = $inputDir; Output = $phone.OutputPath; Wav = $wav
            Commit = (git -C $Root rev-parse HEAD); SourceKey = (Get-KokoroSourceKey); Uncommitted = [bool]@(git -C $Root status --porcelain).Count
            DeviceReceipt = $phone.Lines; Listening = 'Not assessed; playback receipt alone does not establish intelligibility.' }
        [pscustomobject]$result
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
    'AlbertJob' {
        $a = @{ Soc = $Soc }; if ($StopAfter) { $a.StopAfter = $StopAfter }; if ($Path) { $a.TestCapture = $(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Build $Path }) }; if ($Runs) { $a.Runs = $Runs }
        $r = Test-KokoroAlbertJob @a
        'd_en {0} dB   {1} ms   tokens {2}   skel {3}' -f $r.DEnDb, $r.MedianMs, $r.Tokens, $r.Skel
        'stream after mapping_in and each repeat (dB): ' + ($r.StreamDb -join '  ')
        if ($r.StopAfter) { 'stopped after {0}: {1} dB against stock' -f $r.StopAfter, $r.StopDb }
        $r.Runs | ForEach-Object { '  ' + $_ }
    }
    'FrontEnd' {
        if (-not $Parameters) { throw 'FrontEnd needs typed -Parameters.' }
        if ($Parameters.ContainsKey('CaptureDirectory')) {
            Import-Module (Join-Path $Root 'tools/Kokoro.TextEncoder.psm1')
            Test-KokoroTextEncoder @Parameters
        } else {
            if (-not $OutputDirectory) { throw 'Prosody manufacture needs a fresh -OutputDirectory.' }
            Import-Module (Join-Path $Root 'tools/Kokoro.ProsodyBank.psm1')
            New-KokoroProsodyBank @Parameters -OutputDirectory $OutputDirectory
        }
    }
    'PrecomputedDecoder' {
        $experimentParameters = @{}
        if($Parameters){foreach($parameterName in $Parameters.Keys){$experimentParameters[$parameterName]=$Parameters[$parameterName]}}
        if($OutputDirectory){$experimentParameters.OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)}
        & (Join-Path $Root 'tools/Invoke-KokoroPrecomputedDecoder.ps1') @experimentParameters
    }
    'Api' { Get-KokoroApi -Pattern $Pattern | Format-Table -AutoSize -Wrap | Out-String -Width 220 }
    'Find' {
        if (-not $Pattern) { throw 'Find needs -Pattern.' }
        $files = @(git -C $Root ls-files) | Where-Object { $_ -match '\.(ps1|psm1|psd1|md|json|py)$' } | ForEach-Object { Join-Path $Root $_ }
        Select-String -Path $files -Pattern $Pattern | Select-Object -First 60 |
            ForEach-Object { Format-Wrapped $_.Line.Trim() -Indent 0 -Hang 4 -Lead ('{0}:{1}: ' -f [IO.Path]::GetRelativePath($Root, $_.Path), $_.LineNumber) }
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
