<#
.SYNOPSIS
The Student and its host tools: one file of declared records, one shared context and steps.
.DESCRIPTION
Steps:
  Console   Interactive text-to-speech console on the host. Type text, press Enter to render it
            with the lowered syllabus (our phonemizer and our port of stock Kokoro), save it as a
            WAV under build/ and play it. Keys: Enter speak, F2 voice, F3/F4 speed, F5 replay,
            F6 toggle playback, Esc quit.
  Render    Render -Text with the lowered syllabus to a WAV under build/ and return a typed result.
  Corpus    Tokenize the pinned Project Gutenberg text, pronounce every word with our phonemizer and
            with Zira (joined by source span), learn Zira-to-Kokoro symbol correspondences, and
            pack continuous windows of at most 510 phonemes as token ranges. Writes corpus.clixml.
  Pronunciation  Counter-examples from a corpus (-Corpus, default the latest): words where Zira's
            form differs from ours, by word, with recurring symbol differences. With -Text, inspect live Zira
            per-phone stress/emphasis flags with source positions; no first-vowel stress is inserted in this check.
  Normalize Source-aligned front-end decisions for -Text, or replay stored -Corpus decisions as typed behaviours.
  Syllabus   Host syllabus evidence up to the generator boundary for -Voice: per corpus window, the
            lowered syllabus's durations, f0 and x (decoder output), cached by phoneme content under
            build/student/syllabus, and each resolved token span as a typed occurrence with its ticks.
  Recordings Decode the human recordings under -Recordings (MP3) to WAV beside them (48 kHz, two channels,
            16-bit: the Windows media transcoder's only accepted WAV profile); returns each file's frames and seconds.
  Listen    From -Recordings alone: typed acoustic notes with pitch, level, octave spectral slope and YIN aperiodicity,
            exported as MPE MIDI and a physical controller recording on the generator tick clock.
  Stems     Render -State (a controller recording or Listen result) through the host contact emulator, with synchronized
            audio and MIDI per contact. Without State, measure deterministic controller coverage and round-trip gates.
  Alignment Align retained Zira audio to human -Recordings by lowered spectral DTW, label typed word occurrences,
            and snap boundaries to the human Listen evidence. No syllabus or Zira durations enter the result.
  Percepts  Open a live percept image at -ImagePath; -State may supply an Alignment result to observe. The returned
            image has Observe, Pin, Nearby, Describe and Save methods. Source recordings are stored once.
  Describe  Describe -State (a live image), or open -ImagePath, including examples, counter-examples and genealogy.
  Learn     Seed -RulebookPath candidates, observe human boundary timing from the image, and admit prosody
            components only where held-out occurrences improve. The live image also exposes Learn and Apply.
  Audit     From -State Alignment, select boundary review cases without curated text and export audio and a blank
            review CSV. With -State Audit and -Annotations CSV, measure independently reviewed boundary error.
  Discriminate  From -State Alignment made with -PhoneLabels, fit a small acoustic contrast rule on human audio.
            Word types are split before fitting; Zira-warped phone labels remain provisional, never gold labels.
  Reconsider Re-evaluate only remembered decisions whose percept dependencies changed. Missing knowledge stays
            unresolved; prior interpretations and evidence survive. No audio or source capture is rebuilt.
.PARAMETER Corpus
Corpus directory for Pronunciation; defaults to the latest build/corpus-* with corpus.clixml.
.PARAMETER ParagraphLimit
Corpus: read at most this many paragraphs per book (0 reads all).
.PARAMETER OutputPath
Speak: a new directory under build/ for the WAVs and the result (default build/student-speak-<UTC time>).
.PARAMETER WindowLimit
Syllabus: process at most this many windows in corpus order (0 processes all).
.PARAMETER Recordings
Recordings: a directory of human recordings (MP3) under build/; WAV files go to its wav subdirectory.
.PARAMETER Step
The step to run.
.PARAMETER Text
Text for Render or Normalize.
.PARAMETER State
Normalize: a previous result's live interpretation state. MoreText retains the unfinished final token.
.PARAMETER MoreText
Normalize: more fragments will follow; complete tokens advance the resident grammar without rescanning earlier input.
.PARAMETER SourceIdentity
Normalize: stable source identity for a live interpretation stream.
.PARAMETER Voice
Voice pack for Render; any voice pinned in lib/manifest.json.
.PARAMETER Speed
Speaking rate for Render.
.PARAMETER Threads
Worker threads for the syllabus's kernels.
.EXAMPLE
./student/Invoke-Student.ps1 -Step Console
.EXAMPLE
./Invoke-KokoroDevelopment.ps1 Student -Parameters @{ Step = 'Render'; Text = 'Text to render.' }
Run from a PowerShell prompt: pwsh -File passes every argument as a string, so a
-Parameters hashtable only works in process.
#>
#requires -Version 7.7
[CmdletBinding()]
param(
    [ValidateSet('Console', 'Render', 'Corpus', 'Pronunciation', 'Normalize', 'Syllabus', 'Recordings', 'Listen', 'Stems', 'Alignment', 'Percepts', 'Describe', 'Learn', 'Audit', 'Discriminate', 'Reconsider', 'Inventory', 'Speak')][string] $Step = 'Console',
    [ValidateRange(2, 64)][int] $Threads = [Math]::Max(2, [Environment]::ProcessorCount),
    [string] $Text = '',
    [string] $Voice = 'af_heart',
    [ValidateRange(0.5, 2)][double] $Speed = 1,
    [string] $Corpus = '',
    [object] $State = $null,
    [switch] $MoreText,
    [string] $SourceIdentity = '',
    [string] $ImagePath = '',
    [string] $RulebookPath = $env:KOKORO_PROSODY_RULEBOOK,
    [string] $Annotations = '',
    [ValidateRange(8, 256)][int] $AuditCount = 32,
    [switch] $PhoneLabels,
    [ValidateRange(0, [int]::MaxValue)][int] $ParagraphLimit = 0,
    [ValidateRange(0, [int]::MaxValue)][int] $WindowLimit = 0,
    [string] $Recordings = '',
    [ValidateRange(0, [int]::MaxValue)][int] $RecordingLimit = 0,
    [string] $OutputPath = ''
)
$studentInvocation = @{}
foreach ($parameterName in $MyInvocation.MyCommand.Parameters.Keys) {
    if ([Management.Automation.PSCmdlet]::CommonParameters.Contains($parameterName)) { continue }
    $studentInvocation[$parameterName] = Get-Variable -Name $parameterName -ValueOnly
}
$studentOwner = New-Module -Name KokoroStudent -ArgumentList $studentInvocation, $PSCommandPath, $PSScriptRoot -ScriptBlock {
param($Invocation, $StudentOwnerPath, $StudentOwnerRoot)
foreach ($parameterName in $Invocation.Keys) { Set-Variable -Scope Script -Name $parameterName -Value $Invocation[$parameterName] }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StudentRoot = [IO.Path]::GetFullPath((Join-Path $StudentOwnerRoot '..'))
$script:StudentMachineSHA256 = (Get-FileHash -LiteralPath $StudentOwnerPath).Hash
$script:StudentBuild = Join-Path $script:StudentRoot 'build'
$script:StudentContext = [ordered]@{
    Syllabus = $null          # in-memory module exporting Invoke-OfflineSpeech
    Phonemize = $null        # compiled English phonemizer: Func[string,object]
    Voices = @()
    OutputDirectory = $null
    Kernels = $null          # compiled StudentTextKernels delegates
    Vocabulary = $null       # Kokoro symbol set
    Correspondences = $null  # learned Zira-to-Kokoro symbol mappings
    NormalizationType = $null # admitted managed normalization program type
    InterpretationType = $null # persistent compiled grammar engine
}

# Pinned inputs. The phonemizer is the compiled English driver built by
# phonemizer/Invoke-EnglishPhonemizer.ps1; the syllabus is tools/Invoke-KokoroPrecomputedDecoder.ps1.
$script:StudentInputs = [ordered]@{
    Phonemizer = [ordered]@{
        Directory = 'build/phonemizer/english/driver/E8BB6AD454496486459F93AB4BF42D8F9AD1D5798CE75A474AC00BF79EA3390C-library-dll'
        SHA256 = 'B5486F5CDDCA2E12D795003473F16F400E05A95BE2F8C2D972561993D1E07E87'
    }
    Syllabus = 'tools/Invoke-KokoroPrecomputedDecoder.ps1'
    Manifest = 'lib/manifest.json'
    Text = 'build/grammar-corpus/raw'
    Pronunciation = 'phonemizer/Invoke-EnglishPhonemizer.ps1'
    HumanText = 'build/human-recordings/alice-librivox-4139/pg11.txt'
}

# Text corpus records. Headings are uppercase paragraphs; a counter-example section starts
# at a heading matching this pattern and runs to the next heading that does not.
$script:StudentText = [ordered]@{
    # Word sequences that open a counter-example section when they occur in a heading.
    CounterExampleHeadings = @(@('FALSE', 'SYNTAX'), @('IMPROPRIETIES', 'FOR', 'CORRECTION'), @('EXAMPLES', 'OF', 'ERROR'), @('ERRORS', 'CONCERNING'), @('ERROR', 'CONCERNING'))
    MaximumPhonemes = 510         # stock KModel input limit (512 tokens with the two pads)
    AuditLineCharacters = 8192    # Get-EnglishZiraReference text bound
    ZiraCharacters = 1500         # source characters per Zira capture
    ZiraBatchChunks = 128         # completed batches survive an interrupted corpus build
    CorrespondenceShare = 0.5     # minimum share for a learned Zira-to-Kokoro symbol mapping
    KokoroVowels = 'AIOWYaæɐɑɒeəɛɚɜɤiɪɨᵻoøœɔuʊʌɯyᵊ'
}

$script:StudentProsodyRules = @(
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProsodyRule'; Name = 'SubjectAwaitingPredicate'; Rule = 12
        Established = 'Subject'; Awaited = 'Predicate'; Preference = 'Continuation'; Confidence = 'Medium' }
)

# The physical recording is independent of a renderer. Only its wire projection is quantized.
# Offsets follow the 12-byte controller shape; these mappings are diagnostic contacts pending voice calibration.
$script:StudentController = [ordered]@{
    TickSeconds = 0.0125; SampleRate = 24000; SamplesPerTick = 300; RecordBytes = 12
    WireEncoding = 'Little endian: UInt16 buttons, two UInt8 triggers, four Int16 axes; linear declared ranges'
    Buttons = [ordered]@{ Active = 1; Voiced = 2; NoteOn = 4; Rest = 8; Normal = 16; Slow = 32; Fast = 64 }
    Controls = @(
        [pscustomobject]@{ Name = 'LevelDb'; Unit = 'dBFS'; Offset = 2; Bytes = 1; Minimum = -96.0; Maximum = 0.0 }
        [pscustomobject]@{ Name = 'Aperiodicity'; Unit = 'ratio'; Offset = 3; Bytes = 1; Minimum = 0.0; Maximum = 1.0 }
        [pscustomobject]@{ Name = 'PitchHz'; Unit = 'hertz'; Offset = 4; Bytes = 2; Minimum = 0.0; Maximum = 1000.0 }
        [pscustomobject]@{ Name = 'Coefficient'; Unit = 'coefficient axis'; Offset = 6; Bytes = 2; Minimum = -1.0; Maximum = 1.0 }
        [pscustomobject]@{ Name = 'TiltDb'; Unit = 'dB/octave'; Offset = 8; Bytes = 2; Minimum = -96.0; Maximum = 96.0 }
        [pscustomobject]@{ Name = 'TimeSeconds'; Unit = 'seconds (reserved, zero)'; Offset = 10; Bytes = 2; Minimum = 0.0; Maximum = 0.0 }
    )
    Contacts = @('Harmonic', 'Noise', 'Events', 'Coefficient')
    PitchToleranceCents = 35.0; BoundaryToleranceTicks = 0
}

$script:StudentAlignment = [ordered]@{
    SampleRate = 16000; Hop = 320; Window = 400; Bands = 5
    SearchSeconds = 40.0; EdgeSeconds = 40.0; SnapSeconds = 0.25
    RecordingPattern = '_([0-9]+)_'; Book = 'pg11'; ChapterPattern = '(?m)^CHAPTER [IVXLCDM]+\.[^\n]*$'
}

function New-StudentOutputDirectory([string] $Name) {
    $directory = Join-Path $script:StudentBuild ('{0}-{1:yyyyMMddTHHmmss}' -f $Name, [DateTime]::UtcNow)
    if (Test-Path -LiteralPath $directory) { throw "Output directory already exists: $directory" }
    [void][IO.Directory]::CreateDirectory($directory)
    $directory
}

function Import-StudentPhonemizer {
    $pin = $script:StudentInputs.Phonemizer
    $directory = Join-Path $script:StudentRoot $pin.Directory
    $receipt = Import-PowerShellDataFile (Join-Path $directory 'driver-receipt.psd1')
    $path = Join-Path $directory ([IO.Path]::GetFileName($receipt.Output))
    if ($receipt.AssemblySha256 -cne $pin.SHA256 -or (Get-FileHash -LiteralPath $path).Hash -cne $pin.SHA256) { throw 'Compiled English phonemizer integrity mismatch.' }
    $assembly = [Reflection.Assembly]::LoadFrom($path)
    $script:StudentContext.NormalizationType = $assembly.GetType('CoreNormalizationDecision', $true)
    $script:StudentContext.InterpretationType = $assembly.GetType('CoreEngine', $true)
    $assembly.GetType('CoreDriver', $true).GetMethod('Run').CreateDelegate([Func[string,object]])
}

function Import-StudentSyllabus([string] $OutputDirectory) {
    # The lowered syllabus runs inside its own module scope; only its entry points are exported.
    $reference = Join-Path $script:StudentRoot $script:StudentInputs.Syllabus
    New-Module -Name KokoroSyllabus -ArgumentList $reference, $OutputDirectory, $Threads -ScriptBlock {
        param([string] $Reference, [string] $Output, [int] $WorkerThreads)
        . $Reference -Mode Library -OutputDirectory $Output -Threads $WorkerThreads
        Export-ModuleMember -Function Invoke-OfflineSpeech
    }
}

function Get-StudentVoices {
    $manifest = Get-Content -LiteralPath (Join-Path $script:StudentRoot $script:StudentInputs.Manifest) -Raw | ConvertFrom-Json
    @($manifest.model.files | Where-Object { $_.path -like 'voices\*.pt' } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.path) } |
        Where-Object { Test-Path -LiteralPath (Join-Path $script:StudentBuild "inputs/kokoro/$($manifest.model.revision)/voices/$_.pt") })
}

function ConvertTo-StudentWave([float[]] $Pcm, [ValidateSet(16000,24000)][int] $SampleRate = 24000) {
    # Mono PCM16 at its declared rate, rounded and saturated.
    $samples = (Import-StudentKernels).Pcm16.Invoke($Pcm)
    $memory = [IO.MemoryStream]::new(); $writer = [IO.BinaryWriter]::new($memory)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36 + 2 * $samples.Length))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
    $writer.Write([short]1); $writer.Write([short]1); $writer.Write($SampleRate); $writer.Write([int](2 * $SampleRate))
    $writer.Write([short]2); $writer.Write([short]16); $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int](2 * $samples.Length))
    $raw = [byte[]]::new(2 * $samples.Length); [Buffer]::BlockCopy($samples, 0, $raw, 0, $raw.Length); $writer.Write($raw); $writer.Flush()
    $memory.ToArray()
}

# Console: two line buffers. Each frame is composed in the back buffer; only lines that
# differ from the front buffer are written, then the buffers swap.
$script:ConsoleFront = [string[]]@()

function Write-StudentFrame([string[]] $Lines, [int] $CursorRow = -1, [int] $CursorColumn = 0) {
    $width = [Math]::Max(20, [Console]::WindowWidth); $height = [Math]::Max(5, [Console]::WindowHeight)
    $back = [string[]]::new($height)
    for ($row = 0; $row -lt $height; $row++) {
        $line = ''; if ($row -lt $Lines.Length) { $line = $Lines[$row] }
        if ($line.Length -gt $width - 1) { $line = $line.Substring(0, $width - 1) }
        $back[$row] = $line.PadRight($width - 1)
    }
    $frame = [Text.StringBuilder]::new()
    [void]$frame.Append("`e[?25l")
    for ($row = 0; $row -lt $height; $row++) {
        if ($script:ConsoleFront.Length -eq $height -and $script:ConsoleFront[$row] -ceq $back[$row]) { continue }
        [void]$frame.Append("`e[$($row + 1);1H").Append($back[$row])
    }
    if ($CursorRow -ge 0) { [void]$frame.Append("`e[$($CursorRow + 1);$([Math]::Min($width, $CursorColumn + 1))H`e[?25h") }
    [Console]::Out.Write($frame.ToString()); [Console]::Out.Flush()
    $script:ConsoleFront = $back
}

function Show-StudentConsole {
    $state = [ordered]@{
        Text = ''; Cursor = 0; Voice = 0; Speed = 1.0; Playback = $true
        Status = 'Loading the phonemizer and the lowered syllabus...'
        Last = $null; History = [Collections.Generic.List[string]]::new(); Player = $null
    }
    function Get-ConsoleLines {
        $voice = $script:StudentContext.Voices[$state.Voice]
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add('Kokoro host console: our phonemizer and our lowered port of stock Kokoro')
        $lines.Add(('Voice {0}   Speed {1:F2}   Playback {2}   Output {3}' -f $voice, $state.Speed, $(if ($state.Playback) { 'on' } else { 'off' }), $script:StudentContext.OutputDirectory))
        $lines.Add('Enter speak   F2 voice   F3/F4 speed   F5 replay   F6 playback   Esc quit')
        $lines.Add('')
        $lines.Add('> ' + $state.Text)
        $lines.Add('')
        $lines.Add($state.Status)
        $lines.Add('')
        $lines.Add('Recent renders:')
        foreach ($entry in $state.History) { $lines.Add('  ' + $entry) }
        $lines.ToArray()
    }
    function Invoke-ConsoleRender {
        $text = $state.Text.Trim()
        if (-not $text) { $state.Status = 'Type some text first.'; return }
        $state.Status = 'Rendering...'; Write-StudentFrame (Get-ConsoleLines)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $pronunciation = $script:StudentContext.Phonemize.Invoke($text)
        if (-not $pronunciation.Complete -or -not $pronunciation.KokoroPhones) { $state.Status = 'The phonemizer could not resolve this text.'; return }
        $voice = $script:StudentContext.Voices[$state.Voice]
        try { $speech = Invoke-OfflineSpeech -Phonemes $pronunciation.KokoroPhones -Voice $voice -Speed $state.Speed }
        catch { $state.Status = 'Render failed: ' + $_.Exception.Message; return }
        $watch.Stop()
        $seconds = $speech.Pcm.Length / 24000.0
        $wave = ConvertTo-StudentWave $speech.Pcm
        $path = Join-Path $script:StudentContext.OutputDirectory ('{0:D3}-{1}.wav' -f ($state.History.Count + 1), $voice)
        [IO.File]::WriteAllBytes($path, $wave)
        $state.Last = $path
        $state.Status = ('{0:F2} s of audio in {1:F2} s ({2:F2}x real time): {3}' -f $seconds, $watch.Elapsed.TotalSeconds, ($seconds / $watch.Elapsed.TotalSeconds), $path)
        $state.History.Insert(0, ('{0}  {1:F2} s  {2}' -f [IO.Path]::GetFileName($path), $seconds, $text))
        while ($state.History.Count -gt 10) { $state.History.RemoveAt($state.History.Count - 1) }
        if ($state.Playback) { Start-ConsolePlayback }
    }
    function Start-ConsolePlayback {
        if (-not $state.Last) { $state.Status = 'Nothing rendered yet.'; return }
        if ($state.Player) { $state.Player.Stop(); $state.Player.Dispose() }
        $state.Player = [System.Media.SoundPlayer]::new($state.Last); $state.Player.Play()
    }

    [Console]::Out.Write("`e[?1049h`e[2J"); $script:ConsoleFront = [string[]]@()
    try {
        Write-StudentFrame (Get-ConsoleLines)
        $script:StudentContext.OutputDirectory = New-StudentOutputDirectory 'console'
        $script:StudentContext.Phonemize = Import-StudentPhonemizer
        $script:StudentContext.Voices = @(Get-StudentVoices)
        if ($script:StudentContext.Voices.Count -eq 0) { throw 'No pinned voice pack is present under build/inputs/kokoro.' }
        $script:StudentContext.Syllabus = Import-StudentSyllabus (Join-Path $script:StudentContext.OutputDirectory 'syllabus')
        $state.Status = 'Ready.'
        while ($true) {
            Write-StudentFrame (Get-ConsoleLines) 4 (2 + $state.Cursor)
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'Escape' { return }
                'Enter' { Invoke-ConsoleRender }
                'Backspace' { if ($state.Cursor -gt 0) { $state.Text = $state.Text.Remove($state.Cursor - 1, 1); $state.Cursor-- } }
                'Delete' { if ($state.Cursor -lt $state.Text.Length) { $state.Text = $state.Text.Remove($state.Cursor, 1) } }
                'LeftArrow' { $state.Cursor = [Math]::Max(0, $state.Cursor - 1) }
                'RightArrow' { $state.Cursor = [Math]::Min($state.Text.Length, $state.Cursor + 1) }
                'Home' { $state.Cursor = 0 }
                'End' { $state.Cursor = $state.Text.Length }
                'F2' { $state.Voice = ($state.Voice + 1) % $script:StudentContext.Voices.Count }
                'F3' { $state.Speed = [Math]::Max(0.5, $state.Speed - 0.1) }
                'F4' { $state.Speed = [Math]::Min(2.0, $state.Speed + 0.1) }
                'F5' { Start-ConsolePlayback }
                'F6' { $state.Playback = -not $state.Playback }
                default {
                    if (-not [char]::IsControl($key.KeyChar)) {
                        $state.Text = $state.Text.Insert($state.Cursor, [string]$key.KeyChar); $state.Cursor++
                    }
                }
            }
        }
    }
    finally {
        if ($state.Player) { $state.Player.Stop(); $state.Player.Dispose() }
        if ($script:StudentContext.Syllabus) { Remove-Module -ModuleInfo $script:StudentContext.Syllabus -Force }
        [Console]::Out.Write("`e[?25h`e[?1049l")
    }
}

class StudentTextKernels {
    # Text kernels compiled through PSLowering. A token is four integers: kind, start, length,
    # flags. Kinds: 1 word, 2 number, 3 ordinal or format word (2d, 12mo), 4 punctuation,
    # 5 quotation mark, 6 symbol, 7 transcriber note; kinds 1 to 5 are spoken. Flags: 1 emphasis
    # (_..._ in Project Gutenberg text), 2 editorial insertion ([...]). Markup characters
    # themselves produce no token; nothing is removed from the source text.
    static [bool] IsWordChar([char[]] $c, [int] $at, [int] $start) {
        if ([char]::IsLetter($c[$at])) { return $true }
        $code = [int]$c[$at]
        if ($at -gt $start -and $at + 1 -lt $c.Length) {
            if (($code -eq 39 -or $code -eq 8217 -or $code -eq 45) -and [char]::IsLetter($c[$at - 1]) -and [char]::IsLetter($c[$at + 1])) { return $true }
        }
        return $false
    }
    static [bool] NoteAt([char[]] $c, [int] $at) {
        # Transcriber tags: [sic...], [Fist], [Footnote...], [Illustration...], [Transcriber...]
        $tags = [string[]]@('sic', 'Fist', 'Footnote', 'Illustration', 'Transcriber')
        for ($k = 0; $k -lt $tags.Length; $k++) {
            $tag = $tags[$k].ToCharArray()
            if ($at + $tag.Length -gt $c.Length) { continue }
            $same = $true
            for ($j = 0; $j -lt $tag.Length; $j++) { if ([int]$c[$at + $j] -ne [int]$tag[$j]) { $same = $false } }
            if ($same) { return $true }
        }
        return $false
    }
    static [int[]] Tokenize([string] $text, [int] $offset) {
        # Tokens of one paragraph; starts are offset into the text that holds the paragraph.
        $c = $text.ToCharArray(); $n = $c.Length
        $out = [int[]]::new(4 * $n + 4); $count = 0; $flags = 0; $i = 0
        while ($i -lt $n) {
            $code = [int]$c[$i]
            if ([char]::IsWhiteSpace($c[$i])) { $i++; continue }
            if ($code -eq 95) { $flags = $flags -bxor 1; $i++; continue }
            if ($code -eq 91) {
                $close = -1
                for ($j = $i + 1; $j -lt $n -and $j -le $i + 80; $j++) { if ($close -lt 0 -and [int]$c[$j] -eq 93) { $close = $j } }
                if ($close -gt 0 -and [StudentTextKernels]::NoteAt($c, $i + 1)) {
                    $out[4 * $count] = 7; $out[4 * $count + 1] = $i + $offset; $out[4 * $count + 2] = $close - $i + 1; $out[4 * $count + 3] = $flags; $count++
                    $i = $close + 1; continue
                }
                if ($close -gt 0) { $flags = $flags -bor 2; $i++; continue }
            }
            if ($code -eq 93) { $flags = $flags -band 1; $i++; continue }
            $kind = 6; $j = $i + 1
            if ([char]::IsLetter($c[$i])) {
                $kind = 1
                while ($j -lt $n -and [StudentTextKernels]::IsWordChar($c, $j, $i)) { $j++ }
            }
            elseif ([char]::IsDigit($c[$i])) {
                $kind = 2
                $more = $true
                while ($more -and $j -lt $n) {
                    $more = $false
                    if ([char]::IsDigit($c[$j])) { $more = $true }
                    elseif (([int]$c[$j] -eq 44 -or [int]$c[$j] -eq 46 -or [int]$c[$j] -eq 58) -and $j + 1 -lt $n -and [char]::IsDigit($c[$j + 1])) { $more = $true }
                    if ($more) { $j++ }
                }
                if ($j -lt $n -and [char]::IsLetter($c[$j])) { $kind = 3; while ($j -lt $n -and [char]::IsLetter($c[$j])) { $j++ } }
            }
            elseif ($code -eq 45 -and $i + 1 -lt $n -and [int]$c[$i + 1] -eq 45) { $kind = 4; while ($j -lt $n -and [int]$c[$j] -eq 45) { $j++ } }
            elseif ($code -eq 34 -or $code -eq 39 -or $code -eq 8216 -or $code -eq 8217 -or $code -eq 8220 -or $code -eq 8221) { $kind = 5 }
            elseif ($code -eq 46 -or $code -eq 44 -or $code -eq 59 -or $code -eq 58 -or $code -eq 33 -or $code -eq 63 -or $code -eq 40 -or $code -eq 41 -or $code -eq 8212 -or $code -eq 8211 -or $code -eq 45 -or $code -eq 8230) { $kind = 4 }
            $out[4 * $count] = $kind; $out[4 * $count + 1] = $i + $offset; $out[4 * $count + 2] = $j - $i; $out[4 * $count + 3] = $flags; $count++
            $i = $j
        }
        $result = [int[]]::new(4 * $count)
        for ($k = 0; $k -lt 4 * $count; $k++) { $result[$k] = $out[$k] }
        return $result
    }
    static [int[]] Sentences([int[]] $tokens, [char[]] $c, [int] $first, [int] $end) {
        # Sentence token ranges in tokens [first, end) as (first, last) pairs: a sentence ends at
        # . ! or ? (with any closing quotation marks) when the next spoken token starts with a
        # capital letter or a digit, or at the end of the range.
        $out = [int[]]::new(2 * ($end - $first) + 2); $count = 0; $start = $first
        for ($k = $first; $k -lt $end; $k++) {
            if ($tokens[4 * $k] -ne 4 -or $tokens[4 * $k + 2] -ne 1) { continue }
            $code = [int]$c[$tokens[4 * $k + 1]]
            if ($code -ne 46 -and $code -ne 33 -and $code -ne 63) { continue }
            $close = $k
            while ($close + 1 -lt $end -and $tokens[4 * ($close + 1)] -eq 5) { $close++ }
            $next = $close + 1
            while ($next -lt $end -and $tokens[4 * $next] -gt 5) { $next++ }
            if ($next -lt $end) {
                $lead = $c[$tokens[4 * $next + 1]]
                if (-not ([char]::IsUpper($lead) -or [char]::IsDigit($lead))) { continue }
            }
            $out[2 * $count] = $start; $out[2 * $count + 1] = $close; $count++
            $start = $close + 1; $k = $close
        }
        if ($start -lt $end) { $out[2 * $count] = $start; $out[2 * $count + 1] = $end - 1; $count++ }
        $result = [int[]]::new(2 * $count)
        for ($k = 0; $k -lt 2 * $count; $k++) { $result[$k] = $out[$k] }
        return $result
    }
    static [string] Project([int[]] $tokens, [char[]] $c, [int] $first, [int] $last, [int[]] $spans) {
        # The text our phonemizer and Zira receive for tokens first..last: spoken tokens only,
        # words separated by spaces, punctuation attached to the preceding token except ( and
        # dashes, quotation marks as alternating open and close double quotes, and -- as an em
        # dash. spans receives each token's (start, length) in that text, or (-1, 0) if unspoken.
        $size = 1
        for ($k = $first; $k -le $last; $k++) { $size += $tokens[4 * $k + 2] + 1 }
        $buffer = [char[]]::new($size); $count = 0; $open = $false; $attachNext = $true
        $marks = ' "—'.ToCharArray()
        for ($k = $first; $k -le $last; $k++) {
            $at = 2 * ($k - $first); $kind = $tokens[4 * $k]
            $spans[$at] = -1; $spans[$at + 1] = 0
            if ($kind -gt 5) { continue }
            $s = $tokens[4 * $k + 1]; $len = $tokens[4 * $k + 2]
            if ($kind -eq 5) {
                $open = -not $open
                if ($open -and -not $attachNext) { $buffer[$count] = $marks[0]; $count++ }
                $spans[$at] = $count; $spans[$at + 1] = 1; $buffer[$count] = $marks[1]; $count++
                $attachNext = $open
                continue
            }
            $dash = $kind -eq 4 -and $len -ge 2 -and [int]$c[$s] -eq 45 -and [int]$c[$s + 1] -eq 45
            $openParen = $kind -eq 4 -and $len -eq 1 -and [int]$c[$s] -eq 40
            $emDash = $dash -or ($kind -eq 4 -and $len -eq 1 -and [int]$c[$s] -eq 8212)
            $attach = $attachNext -or ($kind -eq 4 -and -not $openParen -and -not $emDash)
            if (-not $attach) { $buffer[$count] = $marks[0]; $count++ }
            $spans[$at] = $count
            if ($dash) { $buffer[$count] = $marks[2]; $count++; $spans[$at + 1] = 1 }
            else {
                for ($j = 0; $j -lt $len; $j++) { $buffer[$count] = $c[$s + $j]; $count++ }
                $spans[$at + 1] = $len
            }
            $attachNext = $openParen
        }
        return [string]::new($buffer, 0, $count)
    }
    static [int[]] Cover([int[]] $spans, [int[]] $events) {
        # For each event (start, length) in projected text, in text order, the first and last
        # token (indices into spans) lying wholly inside it; (-1, -1) when none does or a token
        # straddles the event's edge.
        $n = $spans.Length -shr 1; $m = $events.Length -shr 1
        $out = [int[]]::new(2 * $m); $p = 0
        for ($e = 0; $e -lt $m; $e++) {
            $s = $events[2 * $e]; $end = $s + $events[2 * $e + 1]
            while ($p -lt $n -and ($spans[2 * $p] -lt 0 -or $spans[2 * $p] + $spans[2 * $p + 1] -le $s)) { $p++ }
            $firstToken = -1; $lastToken = -1; $broken = $false; $q = $p
            while ($q -lt $n -and ($spans[2 * $q] -lt 0 -or $spans[2 * $q] -lt $end)) {
                if ($spans[2 * $q] -ge 0) {
                    if ($spans[2 * $q] -lt $s -or $spans[2 * $q] + $spans[2 * $q + 1] -gt $end) { $broken = $true }
                    else { if ($firstToken -lt 0) { $firstToken = $q }; $lastToken = $q }
                }
                $q++
            }
            if ($broken) { $firstToken = -1; $lastToken = -1 }
            $out[2 * $e] = $firstToken; $out[2 * $e + 1] = $lastToken
        }
        return $out
    }
    static [string] Unstressed([string] $phones) {
        # Phones without primary and secondary stress marks.
        $c = $phones.ToCharArray(); $buffer = [char[]]::new($c.Length); $count = 0
        for ($k = 0; $k -lt $c.Length; $k++) { if ([int]$c[$k] -ne 712 -and [int]$c[$k] -ne 716) { $buffer[$count] = $c[$k]; $count++ } }
        return [string]::new($buffer, 0, $count)
    }
    static [int[]] Align([string] $source, [string] $target) {
        # Minimum-edit alignment of two symbol strings as (source index, target index) pairs in
        # order; -1 marks a gap.
        $a = $source.ToCharArray(); $b = $target.ToCharArray(); $w = $b.Length + 1
        $cost = [int[]]::new(($a.Length + 1) * $w)
        for ($i = 0; $i -le $a.Length; $i++) { $cost[$i * $w] = $i }
        for ($j = 0; $j -le $b.Length; $j++) { $cost[$j] = $j }
        for ($i = 1; $i -le $a.Length; $i++) {
            for ($j = 1; $j -le $b.Length; $j++) {
                $same = 1; if ([int]$a[$i - 1] -eq [int]$b[$j - 1]) { $same = 0 }
                $cost[$i * $w + $j] = [Math]::Min([Math]::Min($cost[($i - 1) * $w + $j] + 1, $cost[$i * $w + $j - 1] + 1), $cost[($i - 1) * $w + $j - 1] + $same)
            }
        }
        $reverse = [int[]]::new(2 * ($a.Length + $b.Length) + 2); $count = 0; $i = $a.Length; $j = $b.Length
        while ($i -gt 0 -or $j -gt 0) {
            $same = 1; if ($i -gt 0 -and $j -gt 0 -and [int]$a[$i - 1] -eq [int]$b[$j - 1]) { $same = 0 }
            if ($i -gt 0 -and $j -gt 0 -and $cost[$i * $w + $j] -eq $cost[($i - 1) * $w + $j - 1] + $same) { $i--; $j--; $reverse[2 * $count] = $i; $reverse[2 * $count + 1] = $j }
            elseif ($i -gt 0 -and $cost[$i * $w + $j] -eq $cost[($i - 1) * $w + $j] + 1) { $i--; $reverse[2 * $count] = $i; $reverse[2 * $count + 1] = -1 }
            else { $j--; $reverse[2 * $count] = -1; $reverse[2 * $count + 1] = $j }
            $count++
        }
        $result = [int[]]::new(2 * $count)
        for ($k = 0; $k -lt $count; $k++) { $result[2 * $k] = $reverse[2 * ($count - 1 - $k)]; $result[2 * $k + 1] = $reverse[2 * ($count - 1 - $k) + 1] }
        return $result
    }
    static [string] Substitute([string] $phones, [char[]] $from, [string[]] $to) {
        # Replaces each symbol found in from with the corresponding string in to.
        $c = $phones.ToCharArray(); $size = $c.Length
        for ($k = 0; $k -lt $to.Length; $k++) { $size += $to[$k].Length * $c.Length }
        $buffer = [char[]]::new($size); $count = 0
        for ($i = 0; $i -lt $c.Length; $i++) {
            $hit = -1
            for ($k = 0; $k -lt $from.Length; $k++) { if ($hit -lt 0 -and [int]$from[$k] -eq [int]$c[$i]) { $hit = $k } }
            if ($hit -lt 0) { $buffer[$count] = $c[$i]; $count++ }
            else { $r = $to[$hit].ToCharArray(); for ($j = 0; $j -lt $r.Length; $j++) { $buffer[$count] = $r[$j]; $count++ } }
        }
        return [string]::new($buffer, 0, $count)
    }
    static [string] StressFirstVowel([string] $phones, [string] $vowels) {
        # Primary stress before the first vowel of each space-separated word that has no stress mark.
        $c = $phones.ToCharArray(); $v = $vowels.ToCharArray()
        $buffer = [char[]]::new(2 * $c.Length + 1); $count = 0; $i = 0
        $marks = ' ˈ'.ToCharArray()
        while ($i -lt $c.Length) {
            $end = $i; $stressed = $false
            while ($end -lt $c.Length -and [int]$c[$end] -ne 32) { if ([int]$c[$end] -eq 712 -or [int]$c[$end] -eq 716) { $stressed = $true }; $end++ }
            $placed = $stressed
            for ($k = $i; $k -lt $end; $k++) {
                if (-not $placed) {
                    $vowel = $false
                    for ($j = 0; $j -lt $v.Length; $j++) { if ([int]$v[$j] -eq [int]$c[$k]) { $vowel = $true } }
                    if ($vowel) { $buffer[$count] = $marks[1]; $count++; $placed = $true }
                }
                $buffer[$count] = $c[$k]; $count++
            }
            if ($end -lt $c.Length) { $buffer[$count] = $marks[0]; $count++ }
            $i = $end + 1
        }
        return [string]::new($buffer, 0, $count)
    }
    # Listening: audio kernels over 16-bit PCM WAV bytes and float signals. Lowered arithmetic takes identical operand
    # types, so every mixed operation is cast.
    static [float[]] MonoDecimate([byte[]] $wav, [int] $data, [int] $frames, [float[]] $taps, [int] $factor) {
        # Two-channel 16-bit PCM from byte $data on: channel mean, low-pass by $taps, every $factor-th sample kept.
        $count = [int][Math]::Floor([double]$frames / [double]$factor); $half = [int][Math]::Floor([double]$taps.Length / 2.0)
        $out = [float[]]::new($count)
        for ($n = 0; $n -lt $count; $n++) {
            $acc = 0.0
            for ($k = 0; $k -lt $taps.Length; $k++) {
                $i = $n * $factor + $k - $half
                if ($i -ge 0 -and $i -lt $frames) {
                    $b = $data + 4 * $i
                    $left = [int]$wav[$b] -bor ([int]$wav[$b + 1] -shl 8); if ($left -ge 32768) { $left = $left - 65536 }
                    $right = [int]$wav[$b + 2] -bor ([int]$wav[$b + 3] -shl 8); if ($right -ge 32768) { $right = $right - 65536 }
                    $acc = $acc + [double]$taps[$k] * [double]($left + $right) / 65536.0
                }
            }
            $out[$n] = [float]$acc
        }
        return $out
    }
    static [float[]] PitchTrack([float[]] $x, [int] $rate, [int] $hop, [int] $window, [int] $tauMin, [int] $tauMax, [double] $threshold) {
        # YIN per frame (de Cheveigne and Kawahara 2002): three values per frame, f0 in Hz (0 when unvoiced), the
        # normalized difference at the chosen lag (aperiodicity) and RMS level.
        $frames = [int][Math]::Floor([double]($x.Length - $window - $tauMax) / [double]$hop); if ($frames -lt 0) { $frames = 0 }
        $out = [float[]]::new(3 * $frames); $d = [double[]]::new($tauMax + 2); $dn = [double[]]::new($tauMax + 2)
        for ($f = 0; $f -lt $frames; $f++) {
            $start = $f * $hop
            $energy = 0.0
            for ($j = 0; $j -lt $window; $j++) { $energy = $energy + [double]$x[$start + $j] * [double]$x[$start + $j] }
            for ($tau = 1; $tau -le $tauMax + 1; $tau++) {
                $sum = 0.0
                for ($j = 0; $j -lt $window; $j++) { $diff = [double]$x[$start + $j] - [double]$x[$start + $j + $tau]; $sum = $sum + $diff * $diff }
                $d[$tau] = $sum
            }
            $running = 0.0; $dn[0] = 1.0
            for ($tau = 1; $tau -le $tauMax + 1; $tau++) {
                $running = $running + $d[$tau]
                $dn[$tau] = 1.0; if ($running -gt 0.0) { $dn[$tau] = $d[$tau] * [double]$tau / $running }
            }
            $best = -1
            for ($tau = $tauMin; $tau -le $tauMax -and $best -lt 0; $tau++) {
                if ($dn[$tau] -lt $threshold) {
                    $best = $tau
                    while ($best + 1 -le $tauMax -and $dn[$best + 1] -lt $dn[$best]) { $best = $best + 1 }
                }
            }
            $f0 = 0.0; $aperiodic = 1.0
            if ($best -gt 0) {
                $a = $dn[$best - 1]; $bb = $dn[$best]; $c = $dn[$best + 1]; $den = $a - 2.0 * $bb + $c
                $shift = 0.0; if ([Math]::Abs($den) -gt 1e-12) { $shift = 0.5 * ($a - $c) / $den }
                if ($shift -gt 1.0) { $shift = 1.0 }; if ($shift -lt -1.0) { $shift = -1.0 }
                $f0 = [double]$rate / ([double]$best + $shift); $aperiodic = $bb
            }
            $out[3 * $f] = [float]$f0; $out[3 * $f + 1] = [float]$aperiodic; $out[3 * $f + 2] = [float][Math]::Sqrt($energy / [double]$window)
        }
        return $out
    }
    static [float[]] SpectralBands([float[]] $signal, [int] $rate, [int] $hop, [int] $window) {
        # Three complex projections per octave band (0.8, 1, 1.25 times its centre), Hamming-weighted.
        $frames = [int][Math]::Floor([double]($signal.Length - $window) / [double]$hop)
        if ($frames -lt 0) { $frames = 0 }
        $out = [float[]]::new(5 * $frames); $weights = [double[]]::new($window)
        $cosStep = [double[]]::new(15); $sinStep = [double[]]::new(15)
        for ($j = 0; $j -lt $window; $j++) { $weights[$j] = 0.54 - 0.46 * [Math]::Cos(2.0 * [Math]::PI * [double]$j / [double]($window - 1)) }
        for ($band = 0; $band -lt 5; $band++) {
            for ($bin = 0; $bin -lt 3; $bin++) {
                $frequency = 250.0 * [Math]::Pow(2.0, [double]$band) * [Math]::Pow(1.25, [double]($bin - 1))
                $angle = 2.0 * [Math]::PI * $frequency / [double]$rate
                $cosStep[3 * $band + $bin] = [Math]::Cos($angle); $sinStep[3 * $band + $bin] = [Math]::Sin($angle)
            }
        }
        for ($f = 0; $f -lt $frames; $f++) {
            for ($band = 0; $band -lt 5; $band++) {
                $power = 0.0
                for ($bin = 0; $bin -lt 3; $bin++) {
                    $cosine = 1.0; $sine = 0.0; $real = 0.0; $imaginary = 0.0
                    $cosineStep = $cosStep[3 * $band + $bin]; $sineStep = $sinStep[3 * $band + $bin]
                    for ($j = 0; $j -lt $window; $j++) {
                        $value = [double]$signal[$f * $hop + $j] * $weights[$j]
                        $real = $real + $value * $cosine; $imaginary = $imaginary + $value * $sine
                        $nextCosine = $cosine * $cosineStep - $sine * $sineStep
                        $sine = $sine * $cosineStep + $cosine * $sineStep; $cosine = $nextCosine
                    }
                    $power = $power + $real * $real + $imaginary * $imaginary
                }
                $out[5 * $f + $band] = [float](10.0 * [Math]::Log10($power + 1e-20))
            }
        }
        return $out
    }
    static [float[]] BandMeans([float[]] $bands, [int[]] $bounds) {
        $count = $bounds.Length -shr 1; $out = [float[]]::new(5 * $count)
        for ($item = 0; $item -lt $count; $item++) {
            $first = $bounds[2 * $item]; $last = $bounds[2 * $item + 1]
            for ($frame = $first; $frame -lt $last; $frame++) {
                $mean = 0.0
                for ($band = 0; $band -lt 5; $band++) { $mean = $mean + [double]$bands[5 * $frame + $band] / 5.0 }
                for ($band = 0; $band -lt 5; $band++) { $out[5 * $item + $band] = $out[5 * $item + $band] + [float](([double]$bands[5 * $frame + $band] - $mean) / [double]($last - $first)) }
            }
        }
        return $out
    }
    static [double[]] ContrastThreshold([float[]] $features, [int[]] $labels, [int[]] $folds) {
        # Training only (folds 2..4). Development and test values cannot choose a feature or threshold.
        $out = [double[]]::new(4); $out[3] = -1.0
        for ($axis = 0; $axis -lt 5; $axis++) {
            $minimum = [double]::PositiveInfinity; $maximum = [double]::NegativeInfinity; $zeroCount = 0; $oneCount = 0
            for ($item = 0; $item -lt $labels.Length; $item++) {
                if ($folds[$item] -lt 2) { continue }
                $value = [double]$features[5 * $item + $axis]
                $minimum = [Math]::Min($minimum, $value); $maximum = [Math]::Max($maximum, $value)
                if ($labels[$item] -eq 0) { $zeroCount++ } else { $oneCount++ }
            }
            if ($zeroCount -eq 0 -or $oneCount -eq 0) { continue }
            for ($step = 1; $step -lt 32; $step++) {
                $threshold = $minimum + ($maximum - $minimum) * [double]$step / 32.0
                for ($polarity = -1; $polarity -le 1; $polarity = $polarity + 2) {
                    $zeroCorrect = 0; $oneCorrect = 0
                    for ($item = 0; $item -lt $labels.Length; $item++) {
                        if ($folds[$item] -lt 2) { continue }
                        $prediction = 0
                        if (($polarity -eq 1 -and [double]$features[5 * $item + $axis] -ge $threshold) -or ($polarity -eq -1 -and [double]$features[5 * $item + $axis] -lt $threshold)) { $prediction = 1 }
                        if ($prediction -eq $labels[$item]) { if ($prediction -eq 0) { $zeroCorrect++ } else { $oneCorrect++ } }
                    }
                    $score = 0.5 * ([double]$zeroCorrect / [double]$zeroCount + [double]$oneCorrect / [double]$oneCount)
                    if ($score -gt $out[3]) { $out[0] = [double]$axis; $out[1] = $threshold; $out[2] = [double]$polarity; $out[3] = $score }
                }
            }
        }
        return $out
    }
    static [int[]] ContrastDecisions([float[]] $features, [int] $axis, [double] $threshold, [int] $polarity) {
        $count = [int][Math]::Floor([double]$features.Length / 5.0); $out = [int[]]::new($count)
        for ($item = 0; $item -lt $count; $item++) {
            if (($polarity -eq 1 -and [double]$features[5 * $item + $axis] -ge $threshold) -or ($polarity -eq -1 -and [double]$features[5 * $item + $axis] -lt $threshold)) { $out[$item] = 1 }
        }
        return $out
    }
    static [float[]] SpectralSlope([float[]] $signal, [int] $rate, [int] $hop, [int] $window) {
        $bands = [StudentTextKernels]::SpectralBands($signal, $rate, $hop, $window)
        $frames = [int][Math]::Floor([double]$bands.Length / 5.0); $out = [float[]]::new($frames)
        for ($f = 0; $f -lt $frames; $f++) {
            $slope = 0.0
            for ($band = 0; $band -lt 5; $band++) { $slope = $slope + [double]($band - 2) * [double]$bands[5 * $f + $band] / 10.0 }
            $out[$f] = [float]$slope
        }
        return $out
    }
    static [int[]] SpectralWarp([float[]] $reference, [float[]] $observed, [int] $radius, [int] $edge) {
        # Banded DTW over octave spectral frames, with bounded free recording edges.
        # Output maps each reference frame to a human frame; reference durations are not retained.
        $rows = [int][Math]::Floor([double]$reference.Length / 5.0)
        $columns = [int][Math]::Floor([double]$observed.Length / 5.0)
        if ($rows -eq 0 -or $columns -eq 0 -or $reference.Length % 5 -ne 0 -or $observed.Length % 5 -ne 0 -or $radius -lt 1 -or $edge -lt 0 -or $edge -ge $columns) { throw 'Invalid spectral alignment shape or search bounds.' }
        if ((2.0 * [double]$radius + 1.0) * [double]$rows -gt 2147483647.0) { throw 'Spectral traceback exceeds the managed array range; increase the analysis hop.' }
        $width = 2 * $radius + 1; $trace = [byte[]]::new($rows * $width)
        $previous = [double[]]::new($columns + 1); $current = [double[]]::new($columns + 1)
        for ($j = 0; $j -le $columns; $j++) { $previous[$j] = [double]::PositiveInfinity; if ($j -le $edge) { $previous[$j] = 0.0 } }
        $previousLeft = 0; $previousRight = $columns
        for ($i = 1; $i -le $rows; $i++) {
            $centre = [int][Math]::Floor([double]$i * [double]$columns / [double]$rows)
            $left = [Math]::Max(1, $centre - $radius); $right = [Math]::Min($columns, $centre + $radius)
            $current[$left - 1] = [double]::PositiveInfinity
            for ($j = $left; $j -le $right; $j++) {
                $refMean = 0.0; $obsMean = 0.0
                for ($band = 0; $band -lt 5; $band++) { $refMean = $refMean + [double]$reference[5 * ($i - 1) + $band] / 5.0; $obsMean = $obsMean + [double]$observed[5 * ($j - 1) + $band] / 5.0 }
                $distance = 0.0
                for ($band = 0; $band -lt 5; $band++) {
                    $difference = ([double]$reference[5 * ($i - 1) + $band] - $refMean) - ([double]$observed[5 * ($j - 1) + $band] - $obsMean)
                    $distance = $distance + $difference * $difference / 5.0
                }
                $best = [double]::PositiveInfinity; $direction = 0
                if ($j - 1 -ge $previousLeft -and $j - 1 -le $previousRight) { $best = $previous[$j - 1] }
                if ($j -ge $previousLeft -and $j -le $previousRight -and $previous[$j] -lt $best) { $best = $previous[$j]; $direction = 1 }
                if ($current[$j - 1] -lt $best) { $best = $current[$j - 1]; $direction = 2 }
                $current[$j] = $best + $distance; $trace[($i - 1) * $width + $j - $left] = [byte]$direction
            }
            $swap = $previous; $previous = $current; $current = $swap
            $previousLeft = $left; $previousRight = $right
        }
        $column = $columns; $cost = $previous[$column]
        for ($j = [Math]::Max(1, $columns - $edge); $j -le $columns; $j++) { if ($previous[$j] -lt $cost) { $column = $j; $cost = $previous[$j] } }
        if ([double]::IsInfinity($cost)) { throw 'No alignment path fits the declared spectral band.' }
        $map = [int[]]::new($rows); $row = $rows
        while ($row -gt 0 -and $column -gt 0) {
            $centre = [int][Math]::Floor([double]$row * [double]$columns / [double]$rows); $left = [Math]::Max(1, $centre - $radius)
            $direction = [int]$trace[($row - 1) * $width + $column - $left]
            if ($direction -eq 2) { $column = $column - 1 }
            else { $map[$row - 1] = $column - 1; $row = $row - 1; if ($direction -eq 0) { $column = $column - 1 } }
        }
        return $map
    }
    static [short[]] Pcm16([float[]] $signal) {
        $out = [short[]]::new($signal.Length)
        for ($i = 0; $i -lt $signal.Length; $i++) {
            $value = [Math]::Round([double]$signal[$i] * 32768.0)
            $out[$i] = [short][Math]::Clamp($value, -32768.0, 32767.0)
        }
        return $out
    }
    static [float[]] ReadStem([byte[]] $wav) {
        # Stems writes its own fixed PCM16 mono header; the caller never routes external WAVs here.
        $count = [int][Math]::Floor([double]($wav.Length - 44) / 2.0)
        return [StudentTextKernels]::MonoPcm16($wav, 44, $count)
    }
    static [float[]] CoefficientTrack([float[]] $signal) {
        # Recover the fixed tone's first two harmonics in physical units by Fourier projection.
        # Triangle fundamental amplitude is 8/pi^2; the signed second/fundamental ratio encodes the axis.
        $frames = [int][Math]::Floor([double]$signal.Length / 300.0); $out = [float[]]::new(2 * $frames)
        for ($f = 0; $f -lt $frames; $f++) {
            $fundamental = 0.0; $second = 0.0
            for ($j = 0; $j -lt 300; $j++) {
                $angle = 2.0 * [Math]::PI * [double](300 * $f + $j + 1) / 24.0
                $value = [double]$signal[300 * $f + $j]
                $fundamental = $fundamental - $value * [Math]::Cos($angle) / 150.0
                $second = $second - $value * [Math]::Cos(2.0 * $angle) / 150.0
            }
            if ([Math]::Abs($fundamental) -gt 0.00001) {
                $axis = 2.0 * $second / $fundamental
                $out[2 * $f] = [float]$axis
                if ([Math]::Abs($axis) -gt 0.1) { $out[2 * $f + 1] = [float]($fundamental * [Math]::PI * [Math]::PI / (1.6 * [Math]::Abs($axis))) }
            }
        }
        return $out
    }
    static [float[]] ContactStem([float[]] $controls, [int] $contact, [int] $seed) {
        # Host emulator, not a generator approximation. Eight physical values per tick:
        # pitch, dBFS, aperiodicity, coefficient, tilt, seconds, buttons, response gain.
        # Integer phase and counter noise are independent of file and tile boundaries.
        $frames = [int][Math]::Floor([double]$controls.Length / 8.0)
        $out = [float[]]::new($frames * 300); $phase = 0; $tonePhase = 0; $previousButtons = 16
        for ($f = 0; $f -lt $frames; $f++) {
            $offset = 8 * $f; $buttons = [int]$controls[$offset + 6]
            $step = [int][Math]::Round([double]$controls[$offset] * 1048576.0 / 24000.0)
            $gain = [Math]::Pow(10.0, [double]$controls[$offset + 1] / 20.0)
            $brightness = [Math]::Pow(10.0, [double]$controls[$offset + 4] / 20.0)
            $axis = [double]$controls[$offset + 3]; $response = [double]$controls[$offset + 7]
            for ($j = 0; $j -lt 300; $j++) {
                $position = 300 * $f + $j; $value = 0.0
                $phase = ($phase + $step) -band 1048575; $tonePhase = ($tonePhase + 1) % 24
                if ($contact -eq 0 -and ($buttons -band 3) -eq 3) {
                    $shape = 1.0 - 4.0 * [Math]::Abs([double]$phase / 1048576.0 - 0.5)
                    $second = 1.0 - 4.0 * [Math]::Abs([double](($phase * 2) -band 1048575) / 1048576.0 - 0.5)
                    $value = $gain * ($shape + 0.25 * $brightness * $second)
                }
                if ($contact -eq 1 -and ($buttons -band 1) -eq 1 -and ($buttons -band 2) -eq 0) {
                    $counter = (($position % 65521) + ($seed % 65521) + 65521) % 65521
                    $counter = (($counter * 251) + 13849) % 65521
                    $counter = ($counter -bxor (($counter -shl 7) -band 65535)) -band 65535
                    $value = $gain * [double]$controls[$offset + 2] * (2.0 * [double]$counter / 65535.0 - 1.0)
                }
                if ($contact -eq 2 -and $j -eq 0 -and (($buttons -band 12) -ne 0 -or ($buttons -band 112) -ne ($previousButtons -band 112))) { $value = 0.5 }
                if ($contact -eq 3) {
                    $shape = 1.0 - 4.0 * [Math]::Abs([double]$tonePhase / 24.0 - 0.5)
                    $second = 1.0 - 4.0 * [Math]::Abs([double](($tonePhase * 2) % 24) / 24.0 - 0.5)
                    $value = 0.2 * $response * [Math]::Abs($axis) * ($shape + $axis * $second * 0.5)
                }
                $out[$position] = [float]$value
            }
            $previousButtons = $buttons
        }
        return $out
    }
    static [float[]] FrameLevels([float[]] $signal, [int] $hop) {
        $count = [int][Math]::Floor([double]$signal.Length / [double]$hop); $out = [float[]]::new($count)
        for ($f = 0; $f -lt $count; $f++) {
            $sum = 0.0
            for ($j = 0; $j -lt $hop; $j++) { $value = [double]$signal[$f * $hop + $j]; $sum = $sum + $value * $value }
            $out[$f] = [float][Math]::Sqrt($sum / [double]$hop)
        }
        return $out
    }
    static [float[]] MonoPcm16([byte[]] $wav, [int] $data, [int] $frames) {
        $out = [float[]]::new($frames)
        for ($i = 0; $i -lt $frames; $i++) {
            $value = [int]$wav[$data + 2 * $i] -bor ([int]$wav[$data + 2 * $i + 1] -shl 8)
            if ($value -ge 32768) { $value = $value - 65536 }
            $out[$i] = [float]([double]$value / 32768.0)
        }
        return $out
    }
    static [int[]] BoundaryEvidence([float[]] $levels) {
        $count = $levels.Length; $out = [int[]]::new($count); $db = [double[]]::new($count); $peak = -200.0
        for ($i = 0; $i -lt $count; $i++) { $db[$i] = 20.0 * [Math]::Log10([double]$levels[$i] + 1e-12); $peak = [Math]::Max($peak, $db[$i]) }
        for ($i = 1; $i + 1 -lt $count; $i++) {
            if (($db[$i] -gt $peak - 35.0) -ne ($db[$i - 1] -gt $peak - 35.0)) { $out[$i] = $out[$i] -bor 1 }
            if ($db[$i] -le $db[$i - 1] -and $db[$i] -lt $db[$i + 1]) { $out[$i] = $out[$i] -bor 2 }
            if ($db[$i] - $db[$i - 1] -ge 3.0) { $out[$i] = $out[$i] -bor 4 }
        }
        return $out
    }
}

$script:StudentTokenKinds = @{ 1 = 'Word'; 2 = 'Number'; 3 = 'Ordinal'; 4 = 'Punctuation'; 5 = 'Quote'; 6 = 'Symbol'; 7 = 'Note' }
$script:StudentPronunciationSources = @{ 0 = 'None'; 1 = 'Phonemizer'; 2 = 'Zira' }
Update-TypeData -TypeName 'Kokoro.StudentNormalizationDecision' -MemberType ScriptMethod -MemberName Realize -Value {
    if ($null -eq $this.RuntimeType) { throw 'Import the pinned Student phonemizer before replaying normalization.' }
    $programType = $this.RuntimeType
    $program = $programType::new()
    foreach ($name in 'Operation', 'Operand', 'PreviousWord', 'Role', 'Stress', 'Flap') { $program.$name = $this.$name }
    $program.Realize()
} -Force
Update-TypeData -TypeName 'Kokoro.StudentNormalizationDecision' -DefaultDisplayPropertySet Operation, ValueKind, Value, Provenance -Force
Update-TypeData -TypeName 'Kokoro.StudentInterpretationState' -MemberType ScriptMethod -MemberName Append -Value {
    param([string] $Fragment, [bool] $Final)
    & $this.Owner { param($Interpretation, $Text, $Complete); Add-StudentInterpretationText $Interpretation $Text $Complete } $this $Fragment $Final
} -Force

function New-StudentInterpretationState([string] $Source) {
    $engineType = $script:StudentContext.InterpretationType
    $engine = $engineType::new(); $engine.Polish = $true
    if (-not $Source) { $Source = 'stream:' + [Guid]::NewGuid().ToString('N') }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentInterpretationState'; Source = $Source
        Owner = $ExecutionContext.SessionState.Module
        Engine = $engine; Text = [Text.StringBuilder]::new(); Buffered = ''; Processed = 0; Completed = $false
        DriverSHA256 = $script:StudentInputs.Phonemizer.SHA256; Observations = [ordered]@{}
        Transitions = [Collections.Generic.List[object]]::new(); Result = $null }
}

function Add-StudentInterpretationText([object] $Interpretation, [string] $Fragment, [bool] $Final) {
    if ($Interpretation.PSObject.TypeNames -notcontains 'Kokoro.StudentInterpretationState') { throw 'Normalize requires a Student interpretation object.' }
    if ($Interpretation.DriverSHA256 -cne $script:StudentInputs.Phonemizer.SHA256) { throw 'Interpretation state was created with a different front-end pin.' }
    if ($Interpretation.Engine.GetType() -ne $script:StudentContext.InterpretationType) { throw 'Interpretation state requires its live compiled grammar engine.' }
    if ($Interpretation.Completed) { throw 'The interpretation stream is already complete.' }
    [void]$Interpretation.Text.Append($Fragment)
    $buffer = $Interpretation.Buffered + $Fragment
    $ready = $buffer.Length
    if (-not $Final) {
        $ready = 0
        for ($i = $buffer.Length - 1; $i -ge 0; $i--) {
            if ([char]::IsWhiteSpace($buffer[$i])) { $ready = $i + 1; break }
        }
    }
    $segment = $buffer.Substring(0, $ready)
    $offset = 0
    while ($offset -lt $segment.Length) {
        $count = $Interpretation.Engine.Occurrences.Count
        $next = $Interpretation.Engine.ScanNext($segment, $offset)
        if ($next -le $offset) { throw 'The compiled scanner did not advance.' }
        $offset = $next
        if ($Interpretation.Engine.Occurrences.Count -eq $count) { continue }
        $occurrence = $Interpretation.Engine.Occurrences[$count]
        $occurrence.Start += $Interpretation.Processed; $occurrence.End += $Interpretation.Processed
        foreach ($rule in $script:StudentProsodyRules) {
            $recognized = @($Interpretation.Engine.Candidates | Where-Object {
                $_.Status -cnotin 'Unsupported', 'Contradictory' -and $null -ne $_.($rule.Established) -and
                @($_.($rule.Established).Dependencies).Count -gt 0
            })
            $waiting = @($recognized | Where-Object { $null -eq $_.($rule.Awaited) })
            $satisfied = @($recognized | Where-Object { $null -ne $_.($rule.Awaited) })
            $previous = $Interpretation.Observations[$rule.Name]
            $status = if ($waiting.Count -and $satisfied.Count) { 'Ambiguous' }
                elseif ($waiting.Count) { 'Open' } elseif ($satisfied.Count) { 'Satisfied' }
                elseif ($null -ne $previous -and $previous.Status -cne 'Inactive') { 'Unresolved' } else { 'Inactive' }
            if ($null -ne $previous -and $previous.Status -ceq $status) { continue }
            $observation = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProsodyTransition'; Source = $Interpretation.Source
                Token = $occurrence.Identity; Rule = $rule.Rule; Name = $rule.Name; Status = $status
                Preference = if ($waiting.Count) { $rule.Preference } else { 'Unspecified' }
                Confidence = $rule.Confidence; Pause = 'Unspecified'; Provenance = 'AuthoredComposition'
                Dependencies = [int[]]@($recognized | ForEach-Object { $_.($rule.Established).Dependencies } | Sort-Object -Unique) }
            $Interpretation.Observations[$rule.Name] = $observation
            $Interpretation.Transitions.Add($observation)
        }
    }
    $Interpretation.Processed += $ready; $Interpretation.Buffered = $buffer.Substring($ready)
    $Interpretation.Completed = $Final
    $Interpretation.Result = $Interpretation.Engine.Result($Interpretation.Text.ToString())
    Get-StudentNormalizationResult $Interpretation
}

function New-StudentNormalizationDecision([object] $Program, [object] $Occurrence, [object] $Context) {
    $value = $null; $kind = 'Unclassified'
    if ($Program.Operation -ceq 'Morphology') { $value = $Program.Operand; $kind = 'WordForm' }
    elseif ($Program.Operation -ceq 'Number') {
        $number = [decimal]0
        if ([decimal]::TryParse($Program.Operand, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            $value = $number; $kind = 'Number'
        }
    }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentNormalizationDecision'; Operation = $Program.Operation
        Operand = $Program.Operand; PreviousWord = $Program.PreviousWord; Role = $Program.Role
        Stress = $Program.Stress; Flap = $Program.Flap; ValueKind = $kind; Value = $value
        Occurrence = $Occurrence; Context = $Context; Provenance = 'AuthoredReuse'
        RuntimeType = $script:StudentContext.NormalizationType }
}

function Invoke-StudentNormalization {
    $phonemize = Import-StudentPhonemizer
    if ($Corpus) {
        if ($Text -or $null -ne $State -or $MoreText) { throw 'Choose corpus replay or live text interpretation.' }
        $path = Get-StudentCorpusPath
        $data = ConvertFrom-StudentStored (Import-Clixml -LiteralPath (Join-Path $path 'corpus.clixml'))
        $decisions = @(foreach ($book in $data.Books) {
            if (-not $book.Phonemizer.PSObject.Properties['Normalizations']) { throw 'Corpus has no normalization decisions; rebuild it with the current Student.' }
            foreach ($decision in $book.Phonemizer.Normalizations) {
                if ($decision.Occurrence.Book -ne $book.Index -or $decision.Context.Book -ne $book.Index -or
                    $decision.Occurrence.First -lt 0 -or $decision.Occurrence.Last -ge $book.Phonemizer.Phones.Length) { throw 'Stored normalization occurrence is outside its book.' }
                if ($decision.Realize() -cne $book.Phonemizer.Phones[$decision.Occurrence.First]) { throw 'Stored Student normalization replay differs from its source occurrence.' }
                $decision
            }
        })
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentCorpusNormalization'; Corpus = $path
            Decisions = $decisions; Replayed = $decisions.Count; Provenance = 'AuthoredReuse' }
        return
    }
    if (-not $Text.Trim() -and $null -eq $State) { throw 'Normalize needs -Text, -Corpus or live -State.' }
    if ($null -ne $State -and $SourceIdentity -and $State.Source -cne $SourceIdentity) { throw 'A live interpretation stream must retain its source identity.' }
    $interpretation = if ($null -ne $State) { $State } else { New-StudentInterpretationState $SourceIdentity }
    $interpretation.Append($Text, [bool](-not $MoreText))
}

function Get-StudentNormalizationResult([object] $Interpretation) {
    $result = $Interpretation.Result
    $source = $Interpretation.Source
    $decisions = @(foreach ($token in $result.Tokens) {
        if ($null -eq $token.Normalization) { continue }
        $occurrence = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentOccurrenceReference'; Source = $source; Token = $token.Identity
            Start = $token.SourceStart; Length = $token.SourceEnd - $token.SourceStart }
        $context = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentContextReference'; Source = $source
            First = $token.Normalization.ContextStart; Last = $token.Normalization.ContextEnd; Alternatives = $token.Alternatives }
        $decision = New-StudentNormalizationDecision $token.Normalization $occurrence $context
        if ($decision.Realize() -cne $token.Pron) { throw 'Student normalization replay differs from the front end.' }
        $decision
    })
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentNormalization'; Source = $source
        Complete = $result.Complete -and $Interpretation.Completed; GrammarStatus = $result.GrammarStatus
        Phones = $result.KokoroPhones; Decisions = $decisions; Unresolved = $result.UnresolvedSpans
        State = $Interpretation; Prosody = $Interpretation.Transitions.ToArray()
        DriverSHA256 = $Interpretation.DriverSHA256 }
}
Update-TypeData -TypeName 'Kokoro.StudentToken' -MemberType ScriptProperty -MemberName Spoken -Value { $this.Kind -in 'Word', 'Number', 'Ordinal', 'Punctuation', 'Quote' } -Force
Update-TypeData -TypeName 'Kokoro.StudentToken' -MemberType ScriptProperty -MemberName CounterExample -Value {
    # Zira's pronunciation of the same span differs from the one used: kept as a counter-example.
    $null -ne $this.Zira -and $null -ne $this.Phonemizer -and $this.ZiraLast -eq $this.Last -and $this.ZiraComparable -cne $script:StudentContext.Kernels.Unstressed.Invoke($this.Phonemizer)
} -Force

function Import-StudentKernels {
    # Compiles this file's lowered classes once per source hash with the pinned PSLowering.
    if ($script:StudentContext.Contains('Kernels') -and $script:StudentContext.Kernels) { return $script:StudentContext.Kernels }
    $pin = '1afabe056235a570da29e268824784557d4f6cdd'
    $compiler = Join-Path $script:StudentBuild "phonemizer/inputs/pslowering-$pin"
    $pins = @(Import-Csv -LiteralPath (Join-Path $compiler 'verified-source.tsv') -Delimiter "`t")
    foreach ($item in $pins) { if ($item.Commit -cne $pin -or (Get-FileHash -LiteralPath (Join-Path $compiler $item.Path)).Hash -cne $item.Sha256) { throw 'Pinned compiler integrity mismatch.' } }
    Import-Module (Join-Path $compiler 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1')
    if ((Get-FileHash -LiteralPath $StudentOwnerPath).Hash -cne $script:StudentMachineSHA256) { throw 'Student source changed before kernel admission; restart the command.' }
    $directory = Join-Path $script:StudentBuild ('student/kernels/' + $script:StudentMachineSHA256)
    [void][IO.Directory]::CreateDirectory($directory)
    $dll = Join-Path $directory 'Kokoro.Student.dll'
    if (-not (Test-Path -LiteralPath $dll)) { $null = Export-LoweredAssembly -SourcePath $StudentOwnerPath -ClassName StudentTextKernels -OutputPath $dll -Deterministic }
    $admission = Test-LoweredAssembly -AssemblyPath $dll
    if (-not $admission.ClrOnlyAdmitted) { throw 'Student kernels reference SMA.' }
    $type = [Reflection.Assembly]::LoadFrom($dll).GetType('StudentTextKernels', $true)
    $script:StudentContext.Kernels = [pscustomobject]@{ SHA256 = $admission.SHA256
        Tokenize = $type.GetMethod('Tokenize').CreateDelegate([Func[string,int,int[]]])
        Sentences = $type.GetMethod('Sentences').CreateDelegate([Func[int[],char[],int,int,int[]]])
        Project = $type.GetMethod('Project').CreateDelegate([Func[int[],char[],int,int,int[],string]])
        Cover = $type.GetMethod('Cover').CreateDelegate([Func[int[],int[],int[]]])
        Unstressed = $type.GetMethod('Unstressed').CreateDelegate([Func[string,string]])
        Align = $type.GetMethod('Align').CreateDelegate([Func[string,string,int[]]])
        Substitute = $type.GetMethod('Substitute').CreateDelegate([Func[string,char[],string[],string]])
        StressFirstVowel = $type.GetMethod('StressFirstVowel').CreateDelegate([Func[string,string,string]])
        MonoDecimate = $type.GetMethod('MonoDecimate').CreateDelegate([Func[byte[],int,int,float[],int,float[]]])
        PitchTrack = $type.GetMethod('PitchTrack').CreateDelegate([Func[float[],int,int,int,int,int,double,float[]]])
        ContactStem = $type.GetMethod('ContactStem').CreateDelegate([Func[float[],int,int,float[]]])
        FrameLevels = $type.GetMethod('FrameLevels').CreateDelegate([Func[float[],int,float[]]])
        MonoPcm16 = $type.GetMethod('MonoPcm16').CreateDelegate([Func[byte[],int,int,float[]]])
        BoundaryEvidence = $type.GetMethod('BoundaryEvidence').CreateDelegate([Func[float[],int[]]])
        Pcm16 = $type.GetMethod('Pcm16').CreateDelegate([Func[float[],short[]]])
        ReadStem = $type.GetMethod('ReadStem').CreateDelegate([Func[byte[],float[]]])
        CoefficientTrack = $type.GetMethod('CoefficientTrack').CreateDelegate([Func[float[],float[]]])
        SpectralSlope = $type.GetMethod('SpectralSlope').CreateDelegate([Func[float[],int,int,int,float[]]])
        SpectralBands = $type.GetMethod('SpectralBands').CreateDelegate([Func[float[],int,int,int,float[]]])
        SpectralWarp = $type.GetMethod('SpectralWarp').CreateDelegate([Func[float[],float[],int,int,int[]]])
        BandMeans = $type.GetMethod('BandMeans').CreateDelegate([Func[float[],int[],float[]]])
        ContrastThreshold = $type.GetMethod('ContrastThreshold').CreateDelegate([Func[float[],int[],int[],double[]]])
        ContrastDecisions = $type.GetMethod('ContrastDecisions').CreateDelegate([Func[float[],int,double,int,int[]]])
    }
    $script:StudentContext.Kernels
}

function Import-StudentZira {
    # Zira capture and symbol mapping from the phonemizer's library mode, in their own module scope.
    $reference = Join-Path $script:StudentRoot $script:StudentInputs.Pronunciation
    New-Module -Name StudentZira -ArgumentList $reference -ScriptBlock {
        param([string] $Reference)
        . $Reference -Import
        Export-ModuleMember -Function Get-EnglishZiraReference, ConvertTo-EnglishKokoroPhones, Get-EnglishKokoroSpecification
    }
}

function Test-StudentCounterExampleHeading([string[]] $Words) {
    # True when the heading's words contain one of the counter-example word sequences.
    $texts = @($Words | ForEach-Object { $_.ToUpperInvariant() })
    foreach ($sequence in $script:StudentText.CounterExampleHeadings) {
        for ($at = 0; $at + $sequence.Count -le $texts.Count; $at++) {
            $match = $true
            for ($k = 0; $k -lt $sequence.Count; $k++) { if ($texts[$at + $k] -cne $sequence[$k]) { $match = $false; break } }
            if ($match) { return $true }
        }
    }
    $false
}

function Invoke-StudentPhonemize([Func[string,object]] $Phonemize, [string] $Text) {
    # The compiled driver throws on input beyond its internal bounds; that text is unresolved.
    try { $Phonemize.Invoke($Text) } catch { $null }
}

function Get-StudentBooks([string] $Name = '') {
    # Each pinned Project Gutenberg book without its header and footer, as one packed record: its
    # paragraphs joined by line feeds, its tokens (starts index that text), the first token of each
    # paragraph, per-paragraph heading and counter-example flags, and its sentence token ranges.
    $kernels = Import-StudentKernels
    $directory = Join-Path $script:StudentRoot $script:StudentInputs.Text
    $index = 0
    $sources = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($candidate in @(Get-ChildItem -LiteralPath $directory -Filter 'pg*.txt')) { $sources[$candidate.Name] = $candidate }
    $humanTextPath = Join-Path $script:StudentRoot $script:StudentInputs.HumanText
    if (-not (Test-Path -LiteralPath $humanTextPath -PathType Leaf)) { throw 'Human corpus text is missing: StudentInputs.HumanText.' }
    $humanTextFile = Get-Item -LiteralPath $humanTextPath
    if ($sources.ContainsKey($humanTextFile.Name) -and (Get-FileHash $sources[$humanTextFile.Name].FullName).Hash -cne (Get-FileHash $humanTextFile.FullName).Hash) { throw 'Conflicting corpus sources have the same book name.' }
    $sources[$humanTextFile.Name] = $humanTextFile
    # Append the added source so existing corpus book ordinals retain their identities.
    foreach ($file in @($sources.Values | Sort-Object @{ Expression = { $_.Name -ceq $humanTextFile.Name } }, Name)) {
        if ($Name -and $file.BaseName -cne $Name) { $index++; continue }
        $lines = [IO.File]::ReadAllLines($file.FullName)
        $first = -1; $last = $lines.Length
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($first -lt 0 -and $lines[$i].StartsWith('*** START OF', [StringComparison]::Ordinal)) { $first = $i + 1 }
            elseif ($lines[$i].StartsWith('*** END OF', [StringComparison]::Ordinal)) { $last = $i; break }
        }
        if ($first -lt 0) { throw "No Project Gutenberg start marker in $($file.Name)." }
        $text = [Text.StringBuilder]::new(); $tokens = [Collections.Generic.List[int]]::new()
        $paragraphs = [Collections.Generic.List[int]]::new(); $headings = [Collections.Generic.List[bool]]::new(); $counterExamples = [Collections.Generic.List[bool]]::new()
        $paragraph = [Collections.Generic.List[string]]::new(); $counterExample = $false
        for ($i = $first; $i -le $last; $i++) {
            $line = if ($i -lt $last) { $lines[$i].Trim() } else { '' }
            if ($line) { $paragraph.Add($line); continue }
            if ($paragraph.Count -eq 0) { continue }
            if ($ParagraphLimit -gt 0 -and $paragraphs.Count -ge $ParagraphLimit) { break }
            $value = $paragraph -join ' '; $paragraph.Clear()
            $offset = if ($text.Length) { $text.Length + 1 } else { 0 }
            $packed = $kernels.Tokenize.Invoke($value, $offset)
            $hasWord = $false
            for ($k = 0; $k -lt $packed.Length -and -not $hasWord; $k += 4) { if ($packed[$k] -eq 1) { $hasWord = $true } }
            if (-not $hasWord) { continue }
            $heading = $false
            if ($value.Length -le 120) {
                $words = @(for ($k = 0; $k -lt $packed.Length; $k += 4) { if ($packed[$k] -eq 1) { $value.Substring($packed[$k + 1] - $offset, $packed[$k + 2]) } })
                $heading = -not @($words | Where-Object { $_ -cne $_.ToUpperInvariant() }).Count
                if ($heading) { $counterExample = Test-StudentCounterExampleHeading $words }
            }
            if ($text.Length) { [void]$text.Append("`n") }
            [void]$text.Append($value)
            $paragraphs.Add($tokens.Count -shr 2); $tokens.AddRange($packed); $headings.Add($heading); $counterExamples.Add($counterExample)
        }
        $paragraphs.Add($tokens.Count -shr 2)
        $book = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentBook'; Index = $index; Name = $file.BaseName; Text = $text.ToString(); Tokens = $tokens.ToArray()
            Paragraphs = $paragraphs.ToArray(); Headings = $headings.ToArray(); CounterExample = $counterExamples.ToArray(); Sentences = $null; SentenceParagraphs = $null }
        $chars = $book.Text.ToCharArray()
        $sentences = [Collections.Generic.List[int]]::new(); $owners = [Collections.Generic.List[int]]::new()
        for ($p = 0; $p + 1 -lt $book.Paragraphs.Length; $p++) {
            $found = $kernels.Sentences.Invoke($book.Tokens, $chars, $book.Paragraphs[$p], $book.Paragraphs[$p + 1])
            $sentences.AddRange($found); for ($k = 0; $k -lt $found.Length; $k += 2) { $owners.Add($p) }
        }
        $book.Sentences = $sentences.ToArray(); $book.SentenceParagraphs = $owners.ToArray()
        $book
        $index++
    }
}

function New-StudentPronunciationTable([int] $Count) {
    # Pronunciations keyed by the first token of the span they cover: Last is the span's last
    # token (-1 when none starts there), Phones the Kokoro symbols.
    $last = [int[]]::new($Count); [Array]::Fill($last, -1)
    [pscustomobject]@{ Last = $last; Phones = [string[]]::new($Count) }
}

function Add-StudentPhonemizerPronunciations([object] $Book, [Func[string,object]] $Phonemize) {
    # Our phonemizer over each sentence's projected text. Every token it pronounces (status Valid)
    # is kept, including tokens of sentences it rejects; the whole-sentence result is kept for the
    # projection check.
    $kernels = $script:StudentContext.Kernels
    $chars = $Book.Text.ToCharArray(); $count = $Book.Tokens.Length -shr 2
    $table = New-StudentPronunciationTable $count
    $normalizations = [Collections.Generic.List[object]]::new()
    $sentenceCount = $Book.Sentences.Length -shr 1
    $complete = [string[]]::new($sentenceCount)
    for ($s = 0; $s -lt $sentenceCount; $s++) {
        $first = $Book.Sentences[2 * $s]; $last = $Book.Sentences[2 * $s + 1]
        $spans = [int[]]::new(2 * ($last - $first + 1))
        $projected = $kernels.Project.Invoke($Book.Tokens, $chars, $first, $last, $spans)
        if (-not $projected) { continue }
        $result = Invoke-StudentPhonemize $Phonemize $projected
        if ($null -eq $result) { continue }
        if ($result.Complete) { $complete[$s] = $result.KokoroPhones }
        $driverTokens = @($result.Tokens)
        $events = [int[]]::new(2 * $driverTokens.Count)
        for ($t = 0; $t -lt $driverTokens.Count; $t++) { $events[2 * $t] = $driverTokens[$t].SourceStart; $events[2 * $t + 1] = $driverTokens[$t].SourceEnd - $driverTokens[$t].SourceStart }
        $cover = $kernels.Cover.Invoke($spans, $events)
        for ($t = 0; $t -lt $driverTokens.Count; $t++) {
            if ($cover[2 * $t] -lt 0 -or $driverTokens[$t].Status -cne 'Valid' -or -not $driverTokens[$t].Pron) { continue }
            $at = $first + $cover[2 * $t]
            $table.Phones[$at] = $driverTokens[$t].Pron; $table.Last[$at] = $first + $cover[2 * $t + 1]
            $program = $driverTokens[$t].Normalization
            if ($null -ne $program) {
                $occurrence = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentOccurrenceReference'; Book = $Book.Index
                    First = $at; Last = $table.Last[$at]; Start = $Book.Tokens[4 * $at + 1]
                    Length = $Book.Tokens[4 * $table.Last[$at] + 1] + $Book.Tokens[4 * $table.Last[$at] + 2] - $Book.Tokens[4 * $at + 1] }
                $dependencies = [Collections.Generic.HashSet[int]]::new()
                for ($c = $program.ContextStart; $c -le $program.ContextEnd; $c++) {
                    if ($cover[2 * $c] -ge 0) {
                        for ($k = $cover[2 * $c]; $k -le $cover[2 * $c + 1]; $k++) { [void]$dependencies.Add($first + $k) }
                    }
                }
                $context = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentContextReference'; Book = $Book.Index
                    Tokens = [int[]]@($dependencies | Sort-Object); Alternatives = $driverTokens[$t].Alternatives }
                $decision = New-StudentNormalizationDecision $program $occurrence $context
                if ($decision.Realize() -cne $driverTokens[$t].Pron) { throw 'Corpus normalization replay differs from the front end.' }
                $normalizations.Add($decision)
            }
        }
    }
    $Book | Add-Member -NotePropertyName Phonemizer -NotePropertyValue $table -Force
    $table | Add-Member -NotePropertyName Normalizations -NotePropertyValue $normalizations.ToArray()
    $table | Add-Member -NotePropertyName DriverSHA256 -NotePropertyValue $script:StudentInputs.Phonemizer.SHA256
    $Book | Add-Member -NotePropertyName CompleteSentences -NotePropertyValue $complete -Force
}

function Get-StudentZiraChunks([object] $Book) {
    # Zira's input: consecutive sentences of one paragraph, projected together, up to
    # ZiraCharacters of source text. A sentence longer than the capture bound is not read.
    $kernels = $script:StudentContext.Kernels
    $chars = $Book.Text.ToCharArray(); $sentenceCount = $Book.Sentences.Length -shr 1
    $limit = $script:StudentText.ZiraCharacters
    $close = {
        param([int] $From, [int] $To)
        $spans = [int[]]::new(2 * ($To - $From + 1))
        $projected = $kernels.Project.Invoke($Book.Tokens, $chars, $From, $To, $spans)
        if ($projected -and $projected.Length -le $script:StudentText.AuditLineCharacters) { [pscustomobject]@{ First = $From; Last = $To; Text = $projected; Spans = $spans } }
    }
    $from = -1; $to = -1; $paragraph = -1
    for ($s = 0; $s -lt $sentenceCount; $s++) {
        $first = $Book.Sentences[2 * $s]; $last = $Book.Sentences[2 * $s + 1]
        if ($from -ge 0) {
            $end = $Book.Tokens[4 * $last + 1] + $Book.Tokens[4 * $last + 2]
            if ($Book.SentenceParagraphs[$s] -ne $paragraph -or $end - $Book.Tokens[4 * $from + 1] -gt $limit) { & $close $from $to; $from = -1 }
        }
        if ($from -lt 0) { $from = $first; $paragraph = $Book.SentenceParagraphs[$s] }
        $to = $last
    }
    if ($from -ge 0) { & $close $from $to }
}

function Invoke-StudentZiraCapture([string[]] $Texts) {
    # Zira's word events for each text on Threads parallel synthesizers: for each word event its
    # source start and length, audio position and duration (100 ns ticks) and raw phones.
    $reference = Join-Path $script:StudentRoot $script:StudentInputs.Pronunciation
    $results = [object[]]::new($Texts.Count)
    $batches = @(for ($t = 0; $t -lt $Threads; $t++) { , @(for ($i = $t; $i -lt $Texts.Count; $i += $Threads) { $i }) })
    $captured = $batches | Where-Object { $_.Count } | ForEach-Object -ThrottleLimit $Threads -Parallel {
        $captureTexts = $using:Texts
        $null = New-Module -Name StudentZira -ArgumentList $using:reference -ScriptBlock { param([string] $Reference); . $Reference -Import; Export-ModuleMember -Function Get-EnglishZiraReference }
        foreach ($i in $_) {
            $capture = try { Get-EnglishZiraReference -Text $captureTexts[$i] -NoSave } catch { $null }
            if ($null -eq $capture) { [pscustomobject]@{ Index = $i; Starts = $null }; continue }
            $audible = @($capture.Phones | Where-Object { $_.Phone.Length -gt 0 -and -not [char]::IsControl($_.Phone[0]) })
            $words = @($capture.Words); $count = $words.Count
            $starts = [int[]]::new($count); $lengths = [int[]]::new($count); $ticks = [long[]]::new($count); $durations = [long[]]::new($count); $phones = [string[]]::new($count)
            $p = 0
            for ($w = 0; $w -lt $count; $w++) {
                $limit = if ($w + 1 -lt $count) { $words[$w + 1].Ticks } else { [long]::MaxValue }
                while ($p -lt $audible.Count -and $audible[$p].Ticks -lt $words[$w].Ticks) { $p++ }
                $builder = [Text.StringBuilder]::new(); $end = $words[$w].Ticks
                while ($p -lt $audible.Count -and $audible[$p].Ticks -lt $limit) { [void]$builder.Append($audible[$p].Phone); $end = $audible[$p].Ticks + $audible[$p].DurationTicks; $p++ }
                $starts[$w] = $words[$w].Start; $lengths[$w] = $words[$w].Length; $ticks[$w] = $words[$w].Ticks; $durations[$w] = $end - $words[$w].Ticks; $phones[$w] = $builder.ToString()
            }
            [pscustomobject]@{ Index = $i; Starts = $starts; Lengths = $lengths; Ticks = $ticks; Durations = $durations; Phones = $phones }
        }
    }
    foreach ($item in $captured) { $results[$item.Index] = $item }
    $results
}

function Get-StudentZiraCaptures([string[]] $Texts) {
    # Preserve existing whole-book captures; new work is committed one content-keyed batch at a time.
    $legacyKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($Texts -join "`n"))))
    $legacyPath = Join-Path $script:StudentBuild "student/zira/$legacyKey.clixml"
    $legacy = [object[]]@()
    if (Test-Path -LiteralPath $legacyPath) { $legacy = [object[]](Import-Clixml -LiteralPath $legacyPath) }
    if ($legacy.Count -and $legacy.Count -ne $Texts.Count) { throw 'Existing Zira capture count does not match the projected text.' }
    $directory = Join-Path $script:StudentBuild 'student/zira/batches'
    [void][IO.Directory]::CreateDirectory($directory)
    $referenceHash = (Get-FileHash -LiteralPath (Join-Path $script:StudentRoot $script:StudentInputs.Pronunciation)).Hash
    $results = [object[]]::new($Texts.Count)
    $reused = 0; $imported = 0; $captured = 0
    for ($first = 0; $first -lt $Texts.Count; $first += $script:StudentText.ZiraBatchChunks) {
        $count = [Math]::Min($script:StudentText.ZiraBatchChunks, $Texts.Count - $first)
        $batchTexts = [string[]]$Texts[$first..($first + $count - 1)]
        $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $hash.AppendData([Text.Encoding]::UTF8.GetBytes($referenceHash + '|Microsoft Zira Desktop'))
            foreach ($item in $batchTexts) {
                $bytes = [Text.Encoding]::UTF8.GetBytes($item)
                $hash.AppendData([BitConverter]::GetBytes([int]$bytes.Length)); $hash.AppendData($bytes)
            }
            $key = [Convert]::ToHexString($hash.GetHashAndReset())
        }
        finally { $hash.Dispose() }
        $path = Join-Path $directory ($key + '.clixml')
        $cached = Test-Path -LiteralPath $path
        if ($cached) { $batch = [object[]](Import-Clixml -LiteralPath $path); $reused++ }
        elseif ($legacy.Count) {
            $batch = [object[]]$legacy[$first..($first + $count - 1)]
            if (@($batch | Where-Object { $null -eq $_ -or $null -eq $_.Starts }).Count) {
                $batch = @(Invoke-StudentZiraCapture $batchTexts); $captured += $count
            } else { $imported += $count }
        }
        else { $batch = @(Invoke-StudentZiraCapture $batchTexts); $captured += $count }
        if ($batch.Count -ne $count) { throw 'Zira batch returned an incomplete result set.' }
        $complete = $true
        for ($i = 0; $i -lt $count; $i++) {
            $capture = $batch[$i]
            if ($null -eq $capture -or $null -eq $capture.Starts) { $complete = $false; continue }
            $words = @($capture.Starts).Count
            foreach ($name in 'Lengths', 'Ticks', 'Durations', 'Phones') {
                if (@($capture.$name).Count -ne $words) { throw "Zira batch has mismatched $name." }
            }
            for ($word = 0; $word -lt $words; $word++) {
                if ($capture.Starts[$word] -lt 0 -or $capture.Lengths[$word] -lt 0 -or
                    [long]$capture.Starts[$word] + $capture.Lengths[$word] -gt $batchTexts[$i].Length -or
                    $capture.Ticks[$word] -lt 0 -or $capture.Durations[$word] -lt 0) { throw 'Zira batch has an invalid source span or timing.' }
            }
        }
        if (-not $cached -and $complete) {
            $pending = $path + '.partial'
            Export-Clixml -InputObject $batch -LiteralPath $pending -Depth 3
            [IO.File]::Move($pending, $path)
        }
        for ($i = 0; $i -lt $count; $i++) { $results[$first + $i] = $batch[$i] }
    }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentZiraCaptures'; Captures = $results; Cache = $directory
        ReusedBatches = $reused; ImportedChunks = $imported; CapturedChunks = $captured }
}

function Add-StudentZiraPronunciations([object] $Book, [object] $Zira) {
    # Zira reads the whole book, including sentences our phonemizer rejects. Her word events are
    # joined to tokens by source span; several events over one span (a number read as words) form
    # one pronunciation, words separated by spaces. Completed batches are cached under build/.
    $kernels = $script:StudentContext.Kernels
    $chunks = @(Get-StudentZiraChunks $Book)
    $captureResult = Get-StudentZiraCaptures ([string[]]$chunks.Text)
    $captures = $captureResult.Captures
    $vocabulary = $script:StudentContext.Vocabulary
    $count = $Book.Tokens.Length -shr 2
    $table = New-StudentPronunciationTable $count
    $table | Add-Member -NotePropertyName Ticks -NotePropertyValue ([long[]]::new($count))
    $table | Add-Member -NotePropertyName Durations -NotePropertyValue ([long[]]::new($count))
    $failed = 0; $outside = 0
    for ($c = 0; $c -lt $chunks.Count; $c++) {
        $capture = $captures[$c]
        if ($null -eq $capture -or $null -eq $capture.Starts) { $failed++; continue }
        $events = [Collections.Generic.List[int]]::new(); $phones = [Collections.Generic.List[string]]::new(); $ticks = [Collections.Generic.List[long]]::new(); $durations = [Collections.Generic.List[long]]::new()
        $starts = [int[]]$capture.Starts; $lengths = [int[]]$capture.Lengths; $starting = [long[]]$capture.Ticks; $lasting = [long[]]$capture.Durations; $raw = [string[]]$capture.Phones
        for ($w = 0; $w -lt $starts.Length; $w++) {
            $mapped = ConvertTo-EnglishKokoroPhones $raw[$w]
            $n = $events.Count
            if ($n -and $events[$n - 2] -eq $starts[$w] -and $events[$n - 1] -eq $lengths[$w]) {
                $phones[$phones.Count - 1] += ' ' + $mapped; $durations[$durations.Count - 1] = $starting[$w] + $lasting[$w] - $ticks[$ticks.Count - 1]; continue
            }
            $events.Add($starts[$w]); $events.Add($lengths[$w]); $phones.Add($mapped); $ticks.Add($starting[$w]); $durations.Add($lasting[$w])
        }
        $cover = $kernels.Cover.Invoke($chunks[$c].Spans, $events.ToArray())
        for ($e = 0; $e -lt $phones.Count; $e++) {
            if ($cover[2 * $e] -lt 0 -or -not $phones[$e]) { continue }
            $valid = $true
            foreach ($symbol in $phones[$e].ToCharArray()) { if ($symbol -ne ' ' -and -not $vocabulary.Contains($symbol)) { $valid = $false } }
            if (-not $valid) { $outside++; continue }
            $at = $chunks[$c].First + $cover[2 * $e]
            $table.Phones[$at] = $phones[$e]; $table.Last[$at] = $chunks[$c].First + $cover[2 * $e + 1]; $table.Ticks[$at] = $ticks[$e]; $table.Durations[$at] = $durations[$e]
        }
    }
    $Book | Add-Member -NotePropertyName Zira -NotePropertyValue $table -Force
    [pscustomobject]@{ Chunks = $chunks.Count; FailedChunks = $failed; OutsideVocabulary = $outside; Cache = $captureResult.Cache
        ReusedBatches = $captureResult.ReusedBatches; ImportedChunks = $captureResult.ImportedChunks; CapturedChunks = $captureResult.CapturedChunks }
}

function Get-StudentCorrespondences([object[]] $Books) {
    # Zira-to-Kokoro symbol correspondences learned from every span both pronounce: each Zira
    # symbol's aligned symbol in our unstressed pronunciation, counted over occurrences. A symbol
    # is mapped when one correspondence other than itself holds at least CorrespondenceShare.
    $kernels = $script:StudentContext.Kernels
    $pairs = [Collections.Generic.Dictionary[ValueTuple[string,string],int]]::new()
    foreach ($book in $Books) {
        $ours = $book.Phonemizer; $zira = $book.Zira
        for ($a = 0; $a -lt $ours.Phones.Length; $a++) {
            if ($null -eq $ours.Phones[$a] -or $null -eq $zira.Phones[$a] -or $ours.Last[$a] -ne $zira.Last[$a]) { continue }
            $key = [ValueTuple[string,string]]::new($zira.Phones[$a], $kernels.Unstressed.Invoke($ours.Phones[$a]))
            $seen = 0; $null = $pairs.TryGetValue($key, [ref]$seen); $pairs[$key] = $seen + 1
        }
    }
    $counts = [Collections.Generic.Dictionary[char,Collections.Generic.Dictionary[string,int]]]::new()
    foreach ($entry in $pairs.GetEnumerator()) {
        $source = $entry.Key.Item1; $target = $entry.Key.Item2
        $alignment = $kernels.Align.Invoke($source, $target)
        for ($k = 0; $k -lt $alignment.Length; $k += 2) {
            if ($alignment[$k] -lt 0) { continue }
            $symbol = $source[$alignment[$k]]
            $aligned = if ($alignment[$k + 1] -ge 0) { [string]$target[$alignment[$k + 1]] } else { '' }
            if (-not $counts.ContainsKey($symbol)) { $counts[$symbol] = [Collections.Generic.Dictionary[string,int]]::new() }
            $seen = 0; $null = $counts[$symbol].TryGetValue($aligned, [ref]$seen); $counts[$symbol][$aligned] = $seen + $entry.Value
        }
    }
    $records = foreach ($symbol in $counts.Keys) {
        $total = 0; $best = $null; $bestCount = 0
        foreach ($item in $counts[$symbol].GetEnumerator()) { $total += $item.Value; if ($item.Value -gt $bestCount) { $best = $item.Key; $bestCount = $item.Value } }
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentCorrespondence'; Zira = [string]$symbol; Kokoro = $best; Share = $bestCount / $total; Occurrences = $total
            Mapped = $best -cne [string]$symbol -and $bestCount / $total -ge $script:StudentText.CorrespondenceShare }
    }
    $mapped = @($records | Where-Object Mapped)
    [pscustomobject]@{ Records = @($records | Sort-Object Occurrences -Descending); From = [char[]]@($mapped | ForEach-Object { $_.Zira[0] }); To = [string[]]@($mapped | ForEach-Object Kokoro); SpanPairs = $pairs.Count }
}

function Resolve-StudentPronunciations([object] $Book, [object] $Correspondences) {
    # The pronunciation used for each span: ours where our phonemizer pronounces the token; else
    # Zira's, with the learned correspondences applied and primary stress before the first vowel.
    # Where both pronounce the same span and differ, ours is used and Zira's form stays on the
    # token as a counter-example.
    $kernels = $script:StudentContext.Kernels
    $count = $Book.Tokens.Length -shr 2
    $table = New-StudentPronunciationTable $count
    $table | Add-Member -NotePropertyName Source -NotePropertyValue ([byte[]]::new($count))
    $ours = $Book.Phonemizer; $zira = $Book.Zira
    for ($a = 0; $a -lt $count; $a++) {
        if ($null -ne $ours.Phones[$a]) { $table.Phones[$a] = $ours.Phones[$a]; $table.Last[$a] = $ours.Last[$a]; $table.Source[$a] = 1 }
        elseif ($null -ne $zira.Phones[$a]) {
            $learned = $kernels.Substitute.Invoke($zira.Phones[$a], $Correspondences.From, $Correspondences.To)
            $table.Phones[$a] = $kernels.StressFirstVowel.Invoke($learned, $script:StudentText.KokoroVowels); $table.Last[$a] = $zira.Last[$a]; $table.Source[$a] = 2
        }
    }
    $Book | Add-Member -NotePropertyName Resolved -NotePropertyValue $table -Force
}

function Get-StudentSentencePhonemes([object] $Book, [int] $Sentence) {
    # The sentence's Kokoro phonemes from resolved spans in token order, or null when a spoken
    # token has no pronunciation or a span runs past the sentence.
    $first = $Book.Sentences[2 * $Sentence]; $last = $Book.Sentences[2 * $Sentence + 1]
    $resolved = $Book.Resolved; $parts = [Collections.Generic.List[string]]::new(); $zira = 0; $k = $first
    while ($k -le $last) {
        if ($Book.Tokens[4 * $k] -gt 5) { $k++; continue }
        if ($null -eq $resolved.Phones[$k] -or $resolved.Last[$k] -gt $last) { return $null }
        $parts.Add($resolved.Phones[$k]); if ($resolved.Source[$k] -eq 2) { $zira++ }
        $k = $resolved.Last[$k] + 1
    }
    if ($parts.Count -eq 0) { return $null }
    [pscustomobject]@{ Phonemes = $parts -join ' '; ZiraSpans = $zira }
}

function New-StudentWindows([object[]] $Books, [int] $Seed = 17) {
    # Continuous windows of whole sentences in reading order across sentence and paragraph
    # boundaries, never across books or past a sentence without a pronunciation, each a token
    # range of at most MaximumPhonemes phonemes. Budgets vary over 1..MaximumPhonemes so every
    # voice-pack row is used.
    $random = [Random]::new($Seed); $maximum = $script:StudentText.MaximumPhonemes
    $windows = [Collections.Generic.List[object]]::new(); $pending = [Collections.Generic.List[object]]::new()
    $unresolved = 0; $mismatches = 0; $checked = 0
    $close = {
        if ($pending.Count -eq 0) { return }
        $phonemes = ($pending | ForEach-Object Phonemes) -join ' '
        $windows.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentWindow'; Index = $windows.Count; Book = $pending[0].Book; FirstToken = $pending[0].First
            LastToken = $pending[$pending.Count - 1].Last; Sentences = $pending.Count; Phonemes = $phonemes; PhonemeCount = $phonemes.Length
            ZiraSpans = ($pending | Measure-Object ZiraSpans -Sum).Sum; CounterExampleSentences = @($pending | Where-Object CounterExample).Count })
        $pending.Clear()
    }
    foreach ($book in $Books) {
        $budget = $random.Next(1, $maximum + 1); $length = 0
        for ($s = 0; $s -lt ($book.Sentences.Length -shr 1); $s++) {
            $sentence = Get-StudentSentencePhonemes $book $s
            if ($null -eq $sentence -or $sentence.Phonemes.Length -gt $maximum) { & $close; $length = 0; $unresolved++; continue }
            if ($null -ne $book.CompleteSentences[$s] -and $sentence.ZiraSpans -eq 0) { $checked++; if ($sentence.Phonemes -cne $book.CompleteSentences[$s]) { $mismatches++ } }
            if ($pending.Count -gt 0 -and $length + 1 + $sentence.Phonemes.Length -gt $budget) { & $close; $length = 0; $budget = $random.Next(1, $maximum + 1) }
            $pending.Add([pscustomobject]@{ Book = $book.Index; First = $book.Sentences[2 * $s]; Last = $book.Sentences[2 * $s + 1]; Phonemes = $sentence.Phonemes; ZiraSpans = $sentence.ZiraSpans
                CounterExample = $book.CounterExample[$book.SentenceParagraphs[$s]] })
            $length += $sentence.Phonemes.Length + 1
        }
        & $close
    }
    [pscustomobject]@{ Windows = $windows.ToArray(); UnresolvedSentences = $unresolved; CheckedSentences = $checked; ProjectionMismatches = $mismatches }
}

function Get-StudentTokens([object] $Book, [int] $First, [int] $Last) {
    # Typed view of packed tokens First..Last with every pronunciation of the span each starts;
    # ZiraComparable is Zira's form after the learned correspondences.
    $kernels = $script:StudentContext.Kernels; $correspondences = $script:StudentContext.Correspondences
    for ($k = $First; $k -le $Last; $k++) {
        $flags = $Book.Tokens[4 * $k + 3]; $zira = $Book.Zira.Phones[$k]
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentToken'; Book = $Book.Name; Index = $k; Kind = $script:StudentTokenKinds[$Book.Tokens[4 * $k]]
            Text = $Book.Text.Substring($Book.Tokens[4 * $k + 1], $Book.Tokens[4 * $k + 2]); Start = $Book.Tokens[4 * $k + 1]; Length = $Book.Tokens[4 * $k + 2]
            Emphasis = ($flags -band 1) -ne 0; Editorial = ($flags -band 2) -ne 0
            Phonemizer = $Book.Phonemizer.Phones[$k]; Last = $Book.Phonemizer.Last[$k]; Zira = $zira; ZiraLast = $Book.Zira.Last[$k]
            ZiraComparable = if ($null -ne $zira) { $kernels.Substitute.Invoke($zira, $correspondences.From, $correspondences.To) } else { $null }; ZiraSeconds = $Book.Zira.Durations[$k] / 1e7
            Resolved = $Book.Resolved.Phones[$k]; Source = $script:StudentPronunciationSources[[int]$Book.Resolved.Source[$k]] }
    }
}

function Invoke-StudentCorpus {
    $output = New-StudentOutputDirectory 'corpus'
    $watch = [Diagnostics.Stopwatch]::StartNew(); $phases = [ordered]@{}
    $null = Import-StudentKernels
    $zira = Import-StudentZira
    try {
        $script:StudentContext.Vocabulary = [Collections.Generic.HashSet[char]]::new([char[]]@((Get-EnglishKokoroSpecification).vocab.Keys | ForEach-Object { $_[0] }))
        $books = @(Get-StudentBooks); $phases.Text = $watch.Elapsed.TotalSeconds
        $phonemize = Import-StudentPhonemizer
        foreach ($book in $books) { Add-StudentPhonemizerPronunciations $book $phonemize }
        $phases.Phonemizer = $watch.Elapsed.TotalSeconds
        $capture = @(foreach ($book in $books) { Add-StudentZiraPronunciations $book $zira })
        $phases.Zira = $watch.Elapsed.TotalSeconds
    }
    finally { Remove-Module -ModuleInfo $zira -Force }
    $correspondences = Get-StudentCorrespondences $books
    $script:StudentContext.Correspondences = $correspondences
    foreach ($book in $books) { Resolve-StudentPronunciations $book $correspondences }
    $result = New-StudentWindows $books
    $phases.Windows = $watch.Elapsed.TotalSeconds
    $words = 0; $both = 0; $agree = 0; $phonemizerOnly = 0; $ziraOnly = 0; $neither = 0
    foreach ($book in $books) {
        for ($a = 0; $a -lt ($book.Tokens.Length -shr 2); $a++) {
            if ($book.Tokens[4 * $a] -ne 1) { continue }
            $words++
            $ours = $book.Phonemizer.Phones[$a]; $theirs = $book.Zira.Phones[$a]
            if ($null -ne $ours -and $null -ne $theirs -and $book.Phonemizer.Last[$a] -eq $book.Zira.Last[$a]) {
                $both++; if ($script:StudentContext.Kernels.Unstressed.Invoke($ours) -ceq $script:StudentContext.Kernels.Substitute.Invoke($theirs, $correspondences.From, $correspondences.To)) { $agree++ }
            }
            elseif ($null -ne $ours) { $phonemizerOnly++ } elseif ($null -ne $theirs) { $ziraOnly++ } else { $neither++ }
        }
    }
    $corpus = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentCorpusData'; Books = $books; Windows = $result.Windows; Correspondences = $correspondences }
    Export-Clixml -LiteralPath (Join-Path $output 'corpus.clixml') -InputObject (ConvertTo-StudentStored $corpus) -Depth 8
    $phases.Saved = $watch.Elapsed.TotalSeconds
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentCorpus'; Directory = $output; Windows = $result.Windows.Count; Phonemes = ($result.Windows | Measure-Object PhonemeCount -Sum).Sum
        WindowsWithZira = @($result.Windows | Where-Object ZiraSpans).Count; CounterExampleWindows = @($result.Windows | Where-Object CounterExampleSentences).Count
        Sentences = ($books | ForEach-Object { $_.Sentences.Length -shr 1 } | Measure-Object -Sum).Sum; UnresolvedSentences = $result.UnresolvedSentences
        CheckedSentences = $result.CheckedSentences; ProjectionMismatches = $result.ProjectionMismatches
        Words = $words; BothPronounce = $both; Agree = $agree; CounterExamples = $both - $agree; PhonemizerOnly = $phonemizerOnly; ZiraOnly = $ziraOnly; Neither = $neither
        MappedCorrespondences = @($correspondences.Records | Where-Object Mapped); ZiraCapture = $capture; Phases = [pscustomobject]$phases }
}

function ConvertTo-StudentStored([object] $Value) {
    # Storage shape for Export-Clixml: primitive arrays as bytes, sparse string arrays as positions
    # and values, custom objects member by member.
    if ($null -eq $Value) { return $null }
    if ($Value -is [string[]]) {
        $positions = [Collections.Generic.List[int]]::new(); $values = [Collections.Generic.List[string]]::new()
        for ($k = 0; $k -lt $Value.Length; $k++) { if ($null -ne $Value[$k]) { $positions.Add($k); $values.Add($Value[$k]) } }
        return [pscustomobject]@{ PSTypeName = 'Kokoro.StudentStoredStrings'; Count = $Value.Length; Positions = ConvertTo-StudentStored $positions.ToArray(); Values = $values.ToArray() }
    }
    if ($Value -is [Array] -and $Value.GetType().GetElementType().IsPrimitive -and $Value -isnot [byte[]]) {
        $bytes = [byte[]]::new([Buffer]::ByteLength($Value)); [Buffer]::BlockCopy($Value, 0, $bytes, 0, $bytes.Length)
        return [pscustomobject]@{ PSTypeName = 'Kokoro.StudentStoredArray'; Type = $Value.GetType().GetElementType().FullName; Bytes = $bytes }
    }
    if ($Value.PSObject.BaseObject -is [Management.Automation.PSCustomObject]) {
        $stored = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($Value.PSObject.TypeNames -contains 'Kokoro.StudentNormalizationDecision' -and $property.Name -ceq 'RuntimeType') { continue }
            $stored[$property.Name] = ConvertTo-StudentStored $property.Value
        }
        $result = [pscustomobject]$stored; $result.PSObject.TypeNames.Insert(0, $Value.PSObject.TypeNames[0]); return $result
    }
    if ($Value -is [Array]) { return , @(foreach ($item in $Value) { ConvertTo-StudentStored $item }) }
    $Value
}

function ConvertFrom-StudentStored([object] $Value) {
    # Inverse of ConvertTo-StudentStored after Import-Clixml.
    if ($null -eq $Value) { return $null }
    $names = $Value.PSObject.TypeNames
    if ($Value -is [Collections.IDictionary]) {
        $restoredDictionary = [ordered]@{}
        foreach ($entry in $Value.GetEnumerator()) { $restoredDictionary[[string]$entry.Key] = ConvertFrom-StudentStored $entry.Value }
        return $restoredDictionary
    }
    # Earlier image checkpoints retyped ordered dictionaries as member bags. Their original keys and values
    # are still present; recover the dictionary rather than treating Count/Keys/Values as controller fields.
    if (@($names | Where-Object { $_.EndsWith('System.Collections.Specialized.OrderedDictionary', [StringComparison]::Ordinal) }).Count -and $Value.PSObject.Properties['Keys'] -and $Value.PSObject.Properties['Values']) {
        $dictionaryKeys = @($Value.Keys); $dictionaryValues = @($Value.Values)
        if ($dictionaryKeys.Count -ne $dictionaryValues.Count) { throw 'Stored dictionary has mismatched keys and values.' }
        $restoredDictionary = [ordered]@{}
        for ($entryIndex = 0; $entryIndex -lt $dictionaryKeys.Count; $entryIndex++) { $restoredDictionary[[string]$dictionaryKeys[$entryIndex]] = ConvertFrom-StudentStored $dictionaryValues[$entryIndex] }
        return $restoredDictionary
    }
    if ($names -contains 'Deserialized.Kokoro.StudentStoredArray') {
        $type = [type]$Value.Type; $bytes = [byte[]]$Value.Bytes
        $array = [Array]::CreateInstance($type, $bytes.Length / [Buffer]::ByteLength([Array]::CreateInstance($type, 1))); [Buffer]::BlockCopy($bytes, 0, $array, 0, $bytes.Length)
        return , $array
    }
    if ($names -contains 'Deserialized.Kokoro.StudentStoredStrings') {
        $array = [string[]]::new($Value.Count); $positions = ConvertFrom-StudentStored $Value.Positions; $values = @($Value.Values)
        for ($k = 0; $k -lt $positions.Length; $k++) { $array[$positions[$k]] = $values[$k] }
        return , $array
    }
    if ($Value -is [byte[]] -or $Value -is [string] -or $Value.GetType().IsPrimitive) { return $Value }
    if ($Value -is [Collections.IList]) {
        $items = @(foreach ($item in $Value) { ConvertFrom-StudentStored $item })
        if ($items.Count -and @($items | Where-Object { $_ -isnot [bool] }).Count -eq 0) { return , [bool[]]$items }
        return , $items
    }
    if ($Value -is [Management.Automation.PSObject] -and $names[0].StartsWith('Deserialized.', [StringComparison]::Ordinal)) {
        $restored = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $restored[$property.Name] = ConvertFrom-StudentStored $property.Value }
        $result = [pscustomobject]$restored; $result.PSObject.TypeNames.Insert(0, $names[0].Substring(13))
        if ($result.PSObject.TypeNames -contains 'Kokoro.StudentNormalizationDecision') {
            $result | Add-Member -NotePropertyName RuntimeType -NotePropertyValue $script:StudentContext.NormalizationType
        }
        return $result
    }
    $Value
}

function Get-StudentCorpusPath {
    if ($Corpus) { return (Resolve-Path -LiteralPath $Corpus).Path }
    $latest = @(Get-ChildItem -LiteralPath $script:StudentBuild -Directory -Filter 'corpus-*' | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'corpus.clixml') } | Sort-Object Name)
    if (-not $latest.Count) { throw 'No corpus with corpus.clixml under build/; run -Step Corpus or pass -Corpus.' }
    $latest[-1].FullName
}

function Invoke-StudentPronunciation {
    if ($Text) {
        $ziraModule = Import-StudentZira
        try {
            $capture = & $ziraModule { param($Content); Get-EnglishZiraReference -Text $Content -NoSave } $Text
            $wordIndex = -1
            $features = @(foreach ($phone in $capture.Phones) {
                while ($wordIndex + 1 -lt $capture.Words.Count -and $capture.Words[$wordIndex + 1].Ticks -le $phone.Ticks) { $wordIndex++ }
                [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPronunciationFeature'; Phone = $phone.Phone; EmphasisBits = $phone.Emphasis
                    Stressed = ($phone.Emphasis -band 1) -ne 0; Emphasized = ($phone.Emphasis -band 2) -ne 0
                    SourceStart = $(if ($wordIndex -ge 0) { $capture.Words[$wordIndex].Start } else { -1 })
                    SourceLength = $(if ($wordIndex -ge 0) { $capture.Words[$wordIndex].Length } else { 0 }) }
            })
            [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPronunciationFeatures'; Source = $SourceIdentity; PhoneCount = $features.Count; WordCount = $capture.Words.Count
                Stressed = @($features | Where-Object Stressed).Count; Emphasized = @($features | Where-Object Emphasized).Count
                Features = $features; EngineSHA256 = $capture.EngineSha256; AssemblySHA256 = $capture.AssemblySha256
                MachineSHA256 = $script:StudentMachineSHA256; TextSHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))) }
        } finally { Remove-Module -ModuleInfo $ziraModule -Force }
        return
    }
    # Counter-examples from a corpus: words both pronounce where Zira's form, after the learned
    # correspondences, differs from ours; grouped by word with their recurring symbol differences.
    $path = Get-StudentCorpusPath
    $data = ConvertFrom-StudentStored (Import-Clixml -LiteralPath (Join-Path $path 'corpus.clixml'))
    $null = Import-StudentKernels
    $script:StudentContext.Correspondences = $data.Correspondences
    $occurrences = foreach ($book in $data.Books) {
        for ($a = 0; $a -lt ($book.Tokens.Length -shr 2); $a++) {
            if ($book.Tokens[4 * $a] -ne 1 -or $null -eq $book.Phonemizer.Phones[$a] -or $null -eq $book.Zira.Phones[$a]) { continue }
            Get-StudentTokens $book $a $a | Where-Object CounterExample
        }
    }
    $kernels = $script:StudentContext.Kernels
    $byWord = @($occurrences | Group-Object { [ValueTuple[string,string,string]]::new($_.Text.ToLowerInvariant(), $_.Phonemizer, $_.ZiraComparable) } | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{ Word = $_.Group[0].Text.ToLowerInvariant(); Count = $_.Count; Phonemizer = $_.Group[0].Phonemizer; Zira = $_.Group[0].ZiraComparable } })
    $substitutions = [Collections.Generic.Dictionary[string,int]]::new()
    foreach ($entry in $byWord) {
        $source = $entry.Zira; $target = $kernels.Unstressed.Invoke($entry.Phonemizer); $alignment = $kernels.Align.Invoke($source, $target)
        for ($k = 0; $k -lt $alignment.Length; $k += 2) {
            $z = if ($alignment[$k] -ge 0) { [string]$source[$alignment[$k]] } else { '' }
            $o = if ($alignment[$k + 1] -ge 0) { [string]$target[$alignment[$k + 1]] } else { '' }
            if ($z -cne $o) { $pair = $z + '>' + $o; $seen = 0; $null = $substitutions.TryGetValue($pair, [ref]$seen); $substitutions[$pair] = $seen + $entry.Count }
        }
    }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPronunciation'; Corpus = $path; CounterExampleOccurrences = @($occurrences).Count; DistinctCounterExamples = $byWord.Count
        ByWord = $byWord; Substitutions = @($substitutions.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ Pair = $_.Key; Occurrences = $_.Value } })
        Correspondences = $data.Correspondences.Records }
}


function Invoke-StudentRender {
    if (-not $Text.Trim()) { throw 'Render needs -Text.' }
    $output = New-StudentOutputDirectory 'render'
    $phonemize = Import-StudentPhonemizer
    $voices = @(Get-StudentVoices)
    if ($voices -cnotcontains $Voice) { throw "Voice $Voice is not pinned and present; available: $($voices -join ', ')." }
    $syllabus = Import-StudentSyllabus (Join-Path $output 'syllabus')
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $pronunciation = $phonemize.Invoke($Text)
        if (-not $pronunciation.Complete -or -not $pronunciation.KokoroPhones) { throw 'The phonemizer could not resolve -Text.' }
        $speech = Invoke-OfflineSpeech -Phonemes $pronunciation.KokoroPhones -Voice $Voice -Speed $Speed
        $watch.Stop()
        $path = Join-Path $output ($Voice + '.wav')
        [IO.File]::WriteAllBytes($path, (ConvertTo-StudentWave $speech.Pcm))
        $seconds = $speech.Pcm.Length / 24000.0
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentRender'; Text = $Text; Phonemes = $pronunciation.KokoroPhones; Voice = $Voice; Speed = $Speed
            AudioSeconds = $seconds; RenderSeconds = $watch.Elapsed.TotalSeconds; RealTimeFactor = $watch.Elapsed.TotalSeconds / $seconds; Path = $path }
    }
    finally { Remove-Module -ModuleInfo $syllabus -Force }
}

function Get-StudentWindowOccurrences([object] $Book, [object] $Window) {
    # The window's resolved token spans in order, each with its character range in the window's
    # phoneme string. Rebuilds that string the way New-StudentWindows assembled it and checks it.
    $resolved = $Book.Resolved; $occurrences = [Collections.Generic.List[object]]::new(); $phonemes = [Text.StringBuilder]::new()
    for ($s = 0; $s -lt ($Book.Sentences.Length -shr 1); $s++) {
        $first = $Book.Sentences[2 * $s]; $last = $Book.Sentences[2 * $s + 1]
        if ($first -lt $Window.FirstToken -or $last -gt $Window.LastToken) { continue }
        $k = $first
        while ($k -le $last) {
            if ($Book.Tokens[4 * $k] -gt 5) { $k++; continue }
            if ($phonemes.Length -gt 0) { $null = $phonemes.Append(' ') }
            $occurrences.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentOccurrence'; Book = $Book.Name; FirstToken = $k; LastToken = $resolved.Last[$k]
                Kind = $script:StudentTokenKinds[$Book.Tokens[4 * $k]]; Source = $script:StudentPronunciationSources[[int]$resolved.Source[$k]]
                Phonemes = $resolved.Phones[$k]; Start = $phonemes.Length; FirstTick = 0; Ticks = 0 })
            $null = $phonemes.Append($resolved.Phones[$k])
            $k = $resolved.Last[$k] + 1
        }
    }
    if ($phonemes.ToString() -cne $Window.Phonemes) { throw "Window $($Window.Index): token spans do not rebuild its phonemes." }
    $occurrences.ToArray()
}

function Invoke-StudentSyllabus {
    # Host syllabus evidence up to the generator boundary. The window is only the syllabus's evidence
    # scope; what the Student receives is typed occurrences with their ticks of x and f0.
    $path = Get-StudentCorpusPath
    $data = ConvertFrom-StudentStored (Import-Clixml -LiteralPath (Join-Path $path 'corpus.clixml'))
    $voices = @(Get-StudentVoices)
    if ($voices -cnotcontains $Voice) { throw "Voice $Voice is not pinned and present; available: $($voices -join ', ')." }
    $cache = Join-Path $script:StudentBuild "student/syllabus/$Voice"; [void][IO.Directory]::CreateDirectory($cache)
    $syllabusHash = (@($script:StudentInputs.Syllabus, 'tools/Kokoro.TextEncoder.psm1') | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $script:StudentRoot $_)).Hash }) -join '+'
    $books = @{}; foreach ($book in $data.Books) { $books[$book.Index] = $book }
    $windows = @($data.Windows); if ($WindowLimit -gt 0 -and $windows.Count -gt $WindowLimit) { $windows = $windows[0..($WindowLimit - 1)] }
    $syllabus = $null; $watch = [Diagnostics.Stopwatch]::StartNew(); $renderSeconds = 0.0
    $records = [Collections.Generic.List[object]]::new()
    try {
        foreach ($window in $windows) {
            $occurrences = Get-StudentWindowOccurrences $books[$window.Book] $window
            $keyText = [Text.Encoding]::UTF8.GetBytes("$Voice`n$Speed`n$syllabusHash`n$($window.Phonemes)")
            $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($keyText))
            $file = Join-Path $cache "$key.clixml"; $cached = Test-Path -LiteralPath $file
            if ($cached) { $evidence = ConvertFrom-StudentStored (Import-Clixml -LiteralPath $file) }
            else {
                # The syllabus compiles its kernels once into a fresh directory; evidence stays in the cache.
                if ($null -eq $syllabus) { $syllabus = Import-StudentSyllabus (Join-Path (New-StudentOutputDirectory 'syllabus') 'syllabus') }
                $render = [Diagnostics.Stopwatch]::StartNew()
                $speech = Invoke-OfflineSpeech -Phonemes $window.Phonemes -Voice $Voice -Speed $Speed -SkipGenerator
                $renderSeconds += $render.Elapsed.TotalSeconds
                $evidence = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentSyllabusEvidence'; Key = $key; Voice = $Voice; Speed = $Speed; Phonemes = $window.Phonemes
                    Durations = [int[]]$speech.Durations; F0 = [float[]]$speech.F0; N = [float[]]$speech.N; X = [float[]]$speech.Features }
                Export-Clixml -LiteralPath $file -InputObject (ConvertTo-StudentStored $evidence) -Depth 4
            }
            # One duration per token id: the two pads and one id per phoneme character.
            if ($evidence.Durations.Length -ne $window.Phonemes.Length + 2) { throw "Window $($window.Index): phonemes outside the Kokoro vocabulary." }
            $ticks = $evidence.F0.Length; $frames = 0; foreach ($duration in $evidence.Durations) { $frames += $duration }
            if ($ticks -ne 2 * $frames -or $evidence.X.Length -ne 512 * $ticks) { throw "Window $($window.Index): syllabus output is not two ticks per duration frame." }
            $frameStart = [int[]]::new($evidence.Durations.Length + 1)
            for ($i = 0; $i -lt $evidence.Durations.Length; $i++) { $frameStart[$i + 1] = $frameStart[$i] + $evidence.Durations[$i] }
            foreach ($occurrence in $occurrences) {
                $a = $occurrence.Start + 1; $b = $a + $occurrence.Phonemes.Length
                $occurrence.FirstTick = 2 * $frameStart[$a]; $occurrence.Ticks = 2 * ($frameStart[$b] - $frameStart[$a])
            }
            $records.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentSyllabusWindow'; Index = $window.Index; Key = $key; Cached = $cached; Ticks = $ticks
                AudioSeconds = $ticks / 80.0; Occurrences = $occurrences; Evidence = $evidence })
        }
    }
    finally { if ($null -ne $syllabus) { Remove-Module -ModuleInfo $syllabus -Force } }
    $rendered = @($records | Where-Object { -not $_.Cached })
    $renderedAudio = 0.0; foreach ($record in $rendered) { $renderedAudio += $record.AudioSeconds }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentSyllabus'; Corpus = $path; Voice = $Voice; Cache = $cache; Windows = $records.ToArray()
        Rendered = $rendered.Count; Cached = $records.Count - $rendered.Count; Occurrences = ($records | ForEach-Object { $_.Occurrences.Count } | Measure-Object -Sum).Sum
        AudioSeconds = ($records | Measure-Object AudioSeconds -Sum).Sum; RenderSeconds = $renderSeconds
        RenderRealTimeFactor = if ($renderedAudio) { $renderSeconds / $renderedAudio } else { $null }; WallSeconds = $watch.Elapsed.TotalSeconds }
}

function Invoke-StudentRecordings {
    # Human recordings for listening mode, decoded to PCM WAV. The Windows media transcoder is a WinRT API, reachable
    # only from Windows PowerShell 5.1, so the decode runs there.
    if (-not $Recordings) { throw 'Name a recordings directory with -Recordings.' }
    $source = [IO.Path]::GetFullPath($Recordings)
    if (-not $source.StartsWith([IO.Path]::GetFullPath($script:StudentBuild) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $source -PathType Container)) { throw 'Recordings must be an existing directory under build/.' }
    $files = @(Get-ChildItem -LiteralPath $source -Recurse -File -Filter *.mp3 | Sort-Object FullName)
    if (-not $files.Count) { throw "No MP3 recordings under $source." }
    $wav = Join-Path $source 'wav'; [void][IO.Directory]::CreateDirectory($wav)
    $jobs = @(foreach ($file in $files) { [pscustomobject]@{ Mp3 = $file.FullName; Wav = Join-Path $wav ([IO.Path]::ChangeExtension($file.Name, '.wav')) } })
    $pending = @($jobs | Where-Object { -not (Test-Path -LiteralPath $_.Wav) -or (Get-Item -LiteralPath $_.Wav).Length -le 44 })
    if ($pending.Count) {
        $decoder = @'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Transcoding.MediaTranscoder, Windows.Media.Transcoding, ContentType = WindowsRuntime]
$null = [Windows.Media.MediaProperties.MediaEncodingProfile, Windows.Media.MediaProperties, ContentType = WindowsRuntime]
$methods = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
function Wait-Operation($operation, [type] $result) {
    $method = $methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $task = $method.MakeGenericMethod($result).Invoke($null, @($operation)); [void]$task.Wait(-1); $task.Result }
function Wait-Action($action) {
    $method = $methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncActionWithProgress`1' } | Select-Object -First 1
    $task = $method.MakeGenericMethod([double]).Invoke($null, @($action)); [void]$task.Wait(-1) }
foreach ($job in (ConvertFrom-Json (Get-Content -Raw -LiteralPath $env:KOKORO_RECORDING_JOBS))) {
    $input_ = Wait-Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($job.Mp3)) ([Windows.Storage.StorageFile])
    $folder = Wait-Operation ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync([IO.Path]::GetDirectoryName($job.Wav))) ([Windows.Storage.StorageFolder])
    $output = Wait-Operation ($folder.CreateFileAsync([IO.Path]::GetFileName($job.Wav), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    # The WAV encoder accepts only its default profile here (48 kHz, two channels, 16-bit); 24 kHz or one channel
    # makes PrepareFileTranscodeAsync refuse with FailureReason Unknown.
    $profile_ = [Windows.Media.MediaProperties.MediaEncodingProfile]::CreateWav([Windows.Media.MediaProperties.AudioEncodingQuality]::High)
    $prepared = Wait-Operation ((New-Object Windows.Media.Transcoding.MediaTranscoder).PrepareFileTranscodeAsync($input_, $output, $profile_)) ([Windows.Media.Transcoding.PrepareTranscodeResult])
    if (-not $prepared.CanTranscode) { [IO.File]::Delete($job.Wav); throw ('Cannot decode ' + $job.Mp3 + ': ' + $prepared.FailureReason) }
    Wait-Action $prepared.TranscodeAsync()
}
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($decoder))
        $list = Join-Path $wav 'decode-jobs.json'
        [IO.File]::WriteAllText($list, (ConvertTo-Json -InputObject @($pending)))
        $env:KOKORO_RECORDING_JOBS = $list
        try { & powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded }
        finally { Remove-Item Env:KOKORO_RECORDING_JOBS; [IO.File]::Delete($list) }
        if ($LASTEXITCODE) { throw "Recording decode failed with exit code $LASTEXITCODE." }
    }
    foreach ($job in $jobs) {
        $layout = Get-StudentWavLayout $job.Wav
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentRecording'; Source = $job.Mp3; Wav = $job.Wav; Data = $layout.Data; Frames = $layout.Frames; Seconds = $layout.Frames / [double]$layout.Rate }
    }
}

function Get-StudentWavLayout([string] $Path) {
    # A decoded recording's sample data: RIFF chunks walked in order (Windows writes JUNK before fmt), header only.
    $head = [byte[]]::new(4096); $stream = [IO.File]::OpenRead($Path); try { $read = $stream.Read($head, 0, $head.Length) } finally { $stream.Dispose() }
    $format = -1; $data = -1
    for ($at = 12; $at + 8 -le $read -and $data -lt 0; $at += 8 + [BitConverter]::ToInt32($head, $at + 4)) {
        $id = [Text.Encoding]::ASCII.GetString($head, $at, 4)
        if ($id -ceq 'fmt ') { $format = $at + 8 } elseif ($id -ceq 'data') { $data = $at }
    }
    if ($format -lt 0 -or $data -lt 0 -or [BitConverter]::ToUInt16($head, $format) -ne 1 -or [BitConverter]::ToInt16($head, $format + 14) -ne 16) { throw "$Path is not supported PCM16 audio." }
    $rate = [BitConverter]::ToInt32($head, $format + 4); $channels = [BitConverter]::ToInt16($head, $format + 2)
    if (-not (($rate -eq 48000 -and $channels -eq 2) -or ($rate -eq 16000 -and $channels -eq 1))) { throw "$Path needs 48 kHz stereo or 16 kHz mono PCM16." }
    $dataBytes = [long][BitConverter]::ToUInt32($head, $data + 4)
    if ($dataBytes % (2 * $channels) -ne 0 -or $dataBytes + $data + 8 -gt (Get-Item -LiteralPath $Path).Length) { throw 'PCM data extends outside the WAV or contains a partial frame.' }
    [pscustomobject]@{ Data = $data + 8; Frames = [int]($dataBytes / (2 * $channels)); Rate = $rate; Channels = $channels }
}

function Read-StudentAudio([string] $Path) {
    $kernels = Import-StudentKernels; $layout = Get-StudentWavLayout $Path; $bytes = [IO.File]::ReadAllBytes($Path)
    if ($layout.Rate -eq 16000) { return ,$kernels.MonoPcm16.Invoke($bytes, $layout.Data, $layout.Frames) }
    # Shared 63-tap low-pass at 7 kHz for the human recordings' 48 kHz to 16 kHz conversion.
    $taps = [float[]]::new(63); $sum = 0.0
    for ($k = 0; $k -lt 63; $k++) { $m = $k - 31; $cut = 7000.0 / 48000.0; $value = if ($m -eq 0) { 2 * $cut } else { [Math]::Sin(2 * [Math]::PI * $cut * $m) / ([Math]::PI * $m) }; $value *= 0.54 - 0.46 * [Math]::Cos(2 * [Math]::PI * $k / 62); $taps[$k] = $value; $sum += $value }
    for ($k = 0; $k -lt 63; $k++) { $taps[$k] = $taps[$k] / $sum }
    ,$kernels.MonoDecimate.Invoke($bytes, $layout.Data, $layout.Frames, $taps, 3)
}

function Get-StudentZiraAudio([string] $Content, $ZiraModule) {
    $enginePath = Join-Path $env:WINDIR 'System32/speech/engines/tts/MSTTSEngine.dll'
    $engineHash = (Get-FileHash -LiteralPath $enginePath).Hash
    $ownerHash = (Get-FileHash -LiteralPath (Join-Path $script:StudentRoot $script:StudentInputs.Pronunciation)).Hash
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Content + $engineHash + $ownerHash)))
    $directory = Join-Path $script:StudentBuild ('student/zira-audio/' + $key); [void][IO.Directory]::CreateDirectory($directory)
    $receiptPath = Join-Path $directory 'capture.clixml'
    if (Test-Path -LiteralPath $receiptPath) {
        $retained = Import-Clixml -LiteralPath $receiptPath
        if ($retained.EngineSHA256 -cne $engineHash -or $retained.OwnerSHA256 -cne $ownerHash -or $retained.Text -cne $Content -or
            (Get-FileHash -LiteralPath (Join-Path $directory $retained.Audio)).Hash -cne $retained.AudioSHA256) { throw 'Retained Zira audio integrity mismatch.' }
    } else {
        $wavePath = Join-Path $directory 'reference.wav'
        $capture = & $ZiraModule { param($Words, $Audio); Get-EnglishZiraReference -Text $Words -NoSave -WavePath $Audio } $Content $wavePath
        $layout = Get-StudentWavLayout $wavePath; $seconds = $layout.Frames / [double]$layout.Rate
        $phones = @($capture.Phones | Where-Object { $_.Phone.Length -gt 0 -and -not [char]::IsControl($_.Phone[0]) }); $phoneIndex = 0
        $labels = @(for ($wordIndex = 0; $wordIndex -lt $capture.Words.Count; $wordIndex++) {
            $word = $capture.Words[$wordIndex]
            $next = if ($wordIndex + 1 -lt $capture.Words.Count) { $capture.Words[$wordIndex + 1].Ticks } else { [long]::MaxValue }
            $end = $word.Ticks
            while ($phoneIndex -lt $phones.Count -and $phones[$phoneIndex].Ticks -lt $word.Ticks) { $phoneIndex++ }
            while ($phoneIndex -lt $phones.Count -and $phones[$phoneIndex].Ticks -lt $next) { $end = [Math]::Max($end, $phones[$phoneIndex].Ticks + $phones[$phoneIndex].DurationTicks); $phoneIndex++ }
            if ($word.Ticks -lt 0 -or $end / 1e7 -gt $seconds + 0.001 -or $word.Start -lt 0 -or $word.Length -le 0 -or $word.Start + $word.Length -gt $Content.Length) { throw 'Zira word events are outside their source text or retained audio.' }
            [pscustomobject]@{ PSTypeName = 'Kokoro.StudentReferenceLabel'; Start = $word.Start; Length = $word.Length
                StartSeconds = $word.Ticks / 1e7; EndSeconds = $end / 1e7 }
        })
        $retained = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentZiraAudio'; Text = $Content; Audio = 'reference.wav'
            AudioSHA256 = $capture.WaveSHA256; EngineSHA256 = $engineHash; OwnerSHA256 = $ownerHash; AssemblySHA256 = $capture.AssemblySha256; Words = $labels }
        $retained | Export-Clixml -LiteralPath $receiptPath
    }
    $referencePhoneRows = @()
    if ($script:PhoneLabels) {
        $phonePath = Join-Path $directory 'phones.clixml'
        if (Test-Path -LiteralPath $phonePath) {
            $phoneCapture = Import-Clixml -LiteralPath $phonePath
            if ($phoneCapture.AudioSHA256 -cne $retained.AudioSHA256 -or $phoneCapture.EngineSHA256 -cne $engineHash -or $phoneCapture.OwnerSHA256 -cne $ownerHash) { throw 'Retained phone labels do not match their reference.' }
        } else {
            # Capture on the same native WAV clock. Null-output timing is a different SAPI path.
            # The temporary WAV is removed only after byte identity with the retained reference is proven.
            $phoneWavePath = Join-Path $directory 'phone-labels.wav'
            $capture = & $ZiraModule { param($Words, $Wave); Get-EnglishZiraReference -Text $Words -NoSave -WavePath $Wave } $Content $phoneWavePath
            if ($capture.WaveSHA256 -cne $retained.AudioSHA256) { throw 'Phone capture changed the retained reference audio.' }
            if ($capture.Words.Count -ne $retained.Words.Count) { throw 'Phone capture changed the reference word count.' }
            $phoneIndex = 0; $phoneRows = [Collections.Generic.List[object]]::new()
            for ($wordIndex = 0; $wordIndex -lt $capture.Words.Count; $wordIndex++) {
                $word = $capture.Words[$wordIndex]; $referenceWord = $retained.Words[$wordIndex]
                if ($word.Start -ne $referenceWord.Start -or $word.Length -ne $referenceWord.Length -or [Math]::Abs($word.Ticks / 1e7 - $referenceWord.StartSeconds) -gt 1e-7) { throw 'Label-only capture changed a reference word or its clock.' }
                $next = if ($wordIndex + 1 -lt $capture.Words.Count) { $capture.Words[$wordIndex + 1].Ticks } else { [long]::MaxValue }
                while ($phoneIndex -lt $capture.Phones.Count -and $capture.Phones[$phoneIndex].Ticks -lt $word.Ticks) { $phoneIndex++ }
                $withinWord = 0
                while ($phoneIndex -lt $capture.Phones.Count -and $capture.Phones[$phoneIndex].Ticks -lt $next) {
                    $phone = $capture.Phones[$phoneIndex]; $phoneIndex++
                    if (-not $phone.Phone -or [char]::IsControl($phone.Phone[0])) { continue }
                    $end = ($phone.Ticks + $phone.DurationTicks) / 1e7
                    if ($end -gt $referenceWord.EndSeconds + 1e-7) { throw 'Phone label extends beyond its retained reference word.' }
                    $phoneRows.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentReferencePhone'; Phone = $phone.Phone; Next = $phone.Next
                        Start = $word.Start; Length = $word.Length; Index = $withinWord; StartSeconds = $phone.Ticks / 1e7; EndSeconds = $end; EmphasisBits = $phone.Emphasis })
                    $withinWord++
                }
            }
            $phoneCapture = [pscustomobject]@{ AudioSHA256 = $retained.AudioSHA256; EngineSHA256 = $engineHash; OwnerSHA256 = $ownerHash; Phones = $phoneRows.ToArray() }
            $phoneCapture | Export-Clixml -LiteralPath $phonePath
            Remove-Item -LiteralPath $phoneWavePath
        }
        $referencePhoneRows = @($phoneCapture.Phones)
        if ($referencePhoneRows.Count -eq 0) { throw 'Reference capture has no phone labels.' }
    }
    [pscustomobject]@{ Capture = $retained; Wav = Join-Path $directory $retained.Audio; Phones = $referencePhoneRows }
}

function Get-StudentRecordingText($Recording, [object[]] $Books) {
    if ($Text) {
        if (-not $SourceIdentity) { throw 'Alignment -Text needs a stable -SourceIdentity.' }
        return [pscustomobject]@{ Book = $SourceIdentity; Text = $Text; Start = 0; Tokens = (Import-StudentKernels).Tokenize.Invoke($Text, 0) }
    }
    $book = @($Books | Where-Object Name -CEQ $script:StudentAlignment.Book)
    if ($book.Count -ne 1) { throw 'Alignment book is missing from the declared corpus sources.' }
    $number = [regex]::Match([IO.Path]::GetFileName($Recording.Source), $script:StudentAlignment.RecordingPattern)
    $chapters = @([regex]::Matches($book[0].Text, $script:StudentAlignment.ChapterPattern) | Where-Object { [regex]::Matches($_.Value, '\bCHAPTER ').Count -eq 1 })
    if (-not $number.Success) { throw 'Recording has no chapter index; supply -Text and -SourceIdentity.' }
    $chapterIndex = [int]$number.Groups[1].Value - 1
    if ($chapterIndex -lt 0 -or $chapterIndex -ge $chapters.Count) { throw 'Recording chapter index is outside its corpus book.' }
    $first = $chapters[$chapterIndex].Index
    $last = if ($chapterIndex + 1 -lt $chapters.Count) { $chapters[$chapterIndex + 1].Index } else { $book[0].Text.Length }
    [pscustomobject]@{ Book = $book[0].Name; Text = $book[0].Text.Substring($first, $last - $first); Start = $first; Tokens = $book[0].Tokens }
}

function Invoke-StudentAlignment {
    $kernels = Import-StudentKernels; $settings = $script:StudentAlignment
    $decoded = @(Invoke-StudentRecordings)
    if ($RecordingLimit -gt 0) { $decoded = @($decoded | Select-Object -First $RecordingLimit) }
    $books = @(if (-not $Text) { Get-StudentBooks -Name $settings.Book })
    $ziraModule = Import-StudentZira
    try { foreach ($recording in $decoded) {
        $watch = [Diagnostics.Stopwatch]::StartNew(); $source = Get-StudentRecordingText $recording $books
        $listenPath = Join-Path ([IO.Path]::GetFullPath($Recordings)) ('listen/' + [IO.Path]::ChangeExtension([IO.Path]::GetFileName($recording.Wav), '.controller.clixml'))
        if (-not (Test-Path -LiteralPath $listenPath)) { throw 'Alignment needs the human native recording; run Listen first.' }
        $humanController = Import-Clixml -LiteralPath $listenPath
        $humanHash = (Get-FileHash -LiteralPath $recording.Wav).Hash
        if ($humanController.Provenance.Kind -cne 'Human' -or $humanController.Provenance.SHA256 -cne $humanHash) { throw 'Human Listen recording does not match the audio being aligned.' }
        $samples = [Collections.Generic.List[float]]::new(); $labels = [Collections.Generic.List[object]]::new(); $referencePhones = [Collections.Generic.List[object]]::new(); $position = 0
        # The API capture bound is only an evidence transport limit. Labels keep global source offsets.
        while ($position -lt $source.Text.Length) {
            $count = [Math]::Min($script:StudentText.ZiraCharacters, $source.Text.Length - $position)
            if ($position + $count -lt $source.Text.Length) { while ($count -gt 0 -and -not [char]::IsWhiteSpace($source.Text[$position + $count - 1])) { $count-- } }
            if ($count -eq 0) { throw 'A source token exceeds the Zira audio capture bound.' }
            $content = $source.Text.Substring($position, $count)
            if (-not [string]::IsNullOrWhiteSpace($content)) {
                $reference = Get-StudentZiraAudio $content $ziraModule
                $timeOffset = $samples.Count / [double]$settings.SampleRate
                foreach ($label in $reference.Capture.Words) {
                    $labels.Add([pscustomobject]@{ Start = $source.Start + $position + $label.Start; Length = $label.Length
                        StartSeconds = $timeOffset + $label.StartSeconds; EndSeconds = $timeOffset + $label.EndSeconds })
                }
                foreach ($phone in $reference.Phones) {
                    $referencePhones.Add([pscustomobject]@{ Start = $source.Start + $position + $phone.Start; Length = $phone.Length; Index = $phone.Index
                        Phone = $phone.Phone; Next = $phone.Next; EmphasisBits = $phone.EmphasisBits
                        StartSeconds = $timeOffset + $phone.StartSeconds; EndSeconds = $timeOffset + $phone.EndSeconds })
                }
                $samples.AddRange([float[]](Read-StudentAudio $reference.Wav))
            }
            $position += $count
        }
        $human = Read-StudentAudio $recording.Wav
        $referenceBands = $kernels.SpectralBands.Invoke($samples.ToArray(), $settings.SampleRate, $settings.Hop, $settings.Window)
        $humanBands = $kernels.SpectralBands.Invoke($human, $settings.SampleRate, $settings.Hop, $settings.Window)
        $hopSeconds = $settings.Hop / [double]$settings.SampleRate
        $radius = [int][Math]::Ceiling($settings.SearchSeconds / $hopSeconds); $edge = [int][Math]::Ceiling($settings.EdgeSeconds / $hopSeconds)
        $map = $kernels.SpectralWarp.Invoke($referenceBands, $humanBands, $radius, $edge)
        $levels = (Expand-StudentController $humanController -Projection LevelRms).Frames
        $evidence = $kernels.BoundaryEvidence.Invoke($levels)
        $words = [Collections.Generic.List[object]]::new(); $previousEnd = 0.0; $tokenIndex = 0
        foreach ($label in $labels) {
            $warped = [double[]]::new(2); $snapped = [double[]]::new(2); $kinds = [int[]]::new(2)
            $endpoints = @($label.StartSeconds, $label.EndSeconds)
            for ($side = 0; $side -lt 2; $side++) {
                $frame = [int][Math]::Clamp([Math]::Round(($endpoints[$side] - $settings.Window / (2.0 * $settings.SampleRate)) / $hopSeconds), 0, $map.Length - 1)
                $warped[$side] = $map[$frame] * $hopSeconds + $settings.Window / (2.0 * $settings.SampleRate)
                $minimum = $previousEnd
                if ($side -eq 1) { $minimum += $humanController.Layout.TickSeconds }
                $snapped[$side] = [Math]::Max($minimum, $warped[$side]); $nearest = [double]::PositiveInfinity
                $tickIndex = [int][Math]::Round($warped[$side] / $humanController.Layout.TickSeconds)
                $reach = [int][Math]::Ceiling($settings.SnapSeconds / $humanController.Layout.TickSeconds)
                for ($candidate = [Math]::Max(0, $tickIndex - $reach); $candidate -le [Math]::Min($evidence.Length - 1, $tickIndex + $reach); $candidate++) {
                    $candidateSeconds = $candidate * $humanController.Layout.TickSeconds
                    $distance = [Math]::Abs($candidateSeconds - $warped[$side])
                    if ($evidence[$candidate] -ne 0 -and $candidateSeconds -ge $minimum -and $distance -lt $nearest) { $nearest = $distance; $snapped[$side] = $candidateSeconds; $kinds[$side] = $evidence[$candidate] }
                }
                $previousEnd = $snapped[$side]
            }
            while ($tokenIndex + 1 -lt $source.Tokens.Length / 4 -and $source.Tokens[4 * $tokenIndex + 1] + $source.Tokens[4 * $tokenIndex + 2] -le $label.Start) { $tokenIndex++ }
            $words.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentAlignedOccurrence'; Identity = $source.Book + ':' + $label.Start + ':' + $label.Length
                Book = $source.Book; Token = $tokenIndex; SourceStart = $label.Start; SourceLength = $label.Length
                StartSeconds = $snapped[0]; EndSeconds = $snapped[1]; WarpedStartSeconds = $warped[0]; WarpedEndSeconds = $warped[1]
                StartSnapMs = 1000 * ($snapped[0] - $warped[0]); EndSnapMs = 1000 * ($snapped[1] - $warped[1])
                StartEvidence = $kinds[0]; EndEvidence = $kinds[1]; Reader = $humanController.Provenance; SourceAudioSHA256 = $humanHash })
        }
        $wordByStart = [Collections.Generic.Dictionary[int,object]]::new()
        foreach ($word in $words) { if (-not $wordByStart.ContainsKey([int]$word.SourceStart)) { $wordByStart.Add([int]$word.SourceStart, $word) } }
        $phoneHypotheses = @(foreach ($phone in $referencePhones) {
            if (-not $wordByStart.ContainsKey([int]$phone.Start)) { continue }
            $word = $wordByStart[[int]$phone.Start]; $endpoints = @($phone.StartSeconds, $phone.EndSeconds); $mapped = [double[]]::new(2)
            for ($side = 0; $side -lt 2; $side++) {
                $frame = [int][Math]::Clamp([Math]::Round(($endpoints[$side] - $settings.Window / (2.0 * $settings.SampleRate)) / $hopSeconds), 0, $map.Length - 1)
                $mapped[$side] = $map[$frame] * $hopSeconds + $settings.Window / (2.0 * $settings.SampleRate)
            }
            [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPhoneHypothesis'; Identity = $word.Identity + ':phone:' + $phone.Index
                Occurrence = $word.Identity; Phone = $phone.Phone; Next = $phone.Next; StartSeconds = $mapped[0]; EndSeconds = $mapped[1]
                SourceStart = $word.SourceStart; SourceLength = $word.SourceLength; Book = $word.Book; EmphasisBits = $phone.EmphasisBits
                TimingSupportSeconds = $hopSeconds; LabelStatus = 'ZiraWarpHypothesis'; IndependentlyReviewed = $false; SourceAudioSHA256 = $humanHash }
        })
        $destination = New-StudentOutputDirectory 'student-alignment'
        $result = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentAlignment'; Recording = $recording.Wav; Words = $words.ToArray()
            Book = $source.Book; SourceStart = $source.Start; SourceLength = $source.Text.Length; ReferenceFrames = $referenceBands.Length / 5; HumanFrames = $humanBands.Length / 5
            NativeRecording = $listenPath; SearchSeconds = $settings.SearchSeconds; SnapSeconds = $settings.SnapSeconds
            UnsupportedBoundaries = @($words | Where-Object StartEvidence -EQ 0).Count + @($words | Where-Object EndEvidence -EQ 0).Count
            ZeroDurationWords = @($words | Where-Object { $_.EndSeconds -le $_.StartSeconds }).Count
            MaximumSnapMs = (@($words.StartSnapMs) + @($words.EndSnapMs) | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum
            Phones = $phoneHypotheses; PhoneLabelStatus = 'ZiraWarpHypothesis; no independent phone annotation'
            MachineSHA256 = $script:StudentMachineSHA256; KernelSHA256 = $kernels.SHA256; WallSeconds = $watch.Elapsed.TotalSeconds; Directory = $destination }
        $result | Export-Clixml -LiteralPath (Join-Path $destination 'receipt.clixml')
        $result
    } } finally { Remove-Module -ModuleInfo $ziraModule -Force }
}

function Write-StudentReviewExcerpt([float[]] $Signal, [double] $StartSeconds, [double] $EndSeconds, [string] $Path, [double] $ContextSeconds = 1.0) {
    $first = [int][Math]::Floor([Math]::Max(0.0, $StartSeconds - $ContextSeconds) * 16000.0)
    $last = [int][Math]::Min($Signal.Length, [Math]::Ceiling(($EndSeconds + $ContextSeconds) * 16000.0))
    if ($first -lt 0 -or $first -ge $last -or $last -gt $Signal.Length) { throw 'Review excerpt is outside its source audio.' }
    $excerpt = [float[]]::new($last - $first); [Array]::Copy($Signal, $first, $excerpt, 0, $excerpt.Length)
    [IO.File]::WriteAllBytes($Path, (ConvertTo-StudentWave $excerpt 16000))
    [pscustomobject]@{ StartSeconds = $first / 16000.0; EndSeconds = $last / 16000.0; AudioSHA256 = (Get-FileHash -LiteralPath $Path).Hash }
}

function Invoke-StudentAlignmentAudit {
    if ($null -eq $State) { throw 'Audit needs -State Alignment or a previous Audit result.' }
    if ($Annotations) {
        if (-not $State.PSObject.Properties['Cases'] -or -not $State.PSObject.Properties['AudioSHA256']) { throw 'Annotations need the original Audit result.' }
        if ((Get-FileHash -LiteralPath $State.Recording).Hash -cne $State.AudioSHA256) { throw 'Review recording changed.' }
        $casesById = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($case in $State.Cases) { $casesById.Add([string]$case.Identity, $case) }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $reviewed = [Collections.Generic.List[object]]::new(); $ambiguous = 0; $exposed = 0
        foreach ($row in @(Import-Csv -LiteralPath $Annotations)) {
            if (-not $casesById.ContainsKey($row.Identity) -or -not $seen.Add($row.Identity)) { throw 'Review contains an unknown or duplicate case.' }
            if ($row.PSObject.Properties['ReviewDataStatus'] -and $row.ReviewDataStatus -and $row.ReviewDataStatus -cne 'HumanAnnotation') { throw 'Nonhuman interface fixtures cannot enter alignment accuracy measurements.' }
            if ($row.Status -ceq 'Unreviewed') { continue }
            if ($row.Status -cnotin 'Reviewed', 'Ambiguous' -or -not $row.Reviewer.Trim()) { throw 'Review needs Reviewed/Ambiguous status and an independent reviewer identity.' }
            if ($row.Status -ceq 'Ambiguous') { $ambiguous++; continue }
            if ($row.PSObject.Properties['PredictionRevealedBeforeSave'] -and $row.PredictionRevealedBeforeSave -ieq 'True') { $exposed++; continue }
            $seconds = 0.0
            if (-not [double]::TryParse($row.ObservedSeconds, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -or -not [double]::IsFinite($seconds)) { throw 'ObservedSeconds must be finite seconds from the recording start.' }
            $case = $casesById[$row.Identity]
            if ($seconds -lt $case.ContextStartSeconds -or $seconds -gt $case.ContextEndSeconds) { throw 'Reviewed boundary is outside its supplied audio context.' }
            $reviewed.Add([pscustomobject]@{ Identity = $row.Identity; Reviewer = $row.Reviewer; ObservedSeconds = $seconds
                ErrorMs = 1000 * [Math]::Abs($seconds - $case.PredictedSeconds); SignedErrorMs = 1000 * ($case.PredictedSeconds - $seconds) })
        }
        return [pscustomobject]@{ PSTypeName = 'Kokoro.StudentAlignmentReview'; AudioSHA256 = $State.AudioSHA256
            AnnotationSHA256 = (Get-FileHash -LiteralPath $Annotations).Hash; Reviewed = $reviewed.Count; Ambiguous = $ambiguous
            Unreviewed = $State.Cases.Count - $reviewed.Count - $ambiguous - $exposed; ExposedExcluded = $exposed; Boundaries = $reviewed.ToArray()
            MeanAbsoluteErrorMs = $(if ($reviewed.Count) { ($reviewed.ErrorMs | Measure-Object -Average).Average } else { $null }) }
    }
    if (-not $State.PSObject.Properties['Words'] -or -not $State.PSObject.Properties['Recording']) { throw 'Audit needs an Alignment result.' }
    $audioHash = (Get-FileHash -LiteralPath $State.Recording).Hash
    $wordList = @($State.Words)
    if ($wordList.Count -eq 0 -or @($wordList | Where-Object SourceAudioSHA256 -CNE $audioHash).Count) { throw 'Alignment and source audio do not agree.' }
    $signal = Read-StudentAudio $State.Recording; $duration = $signal.Length / 16000.0
    $sourceBook = @(Get-StudentBooks -Name $State.Book)
    if ($sourceBook.Count -ne 1) { throw 'Audit needs its typed source book.' }
    $pool = @(foreach ($word in $wordList) {
        foreach ($side in @('Start', 'End')) {
            $at = [double]$word.($side + 'Seconds'); $snap = [double]$word.($side + 'SnapMs')
            if ($at -lt 0 -or $at -gt $duration -or $word.EndSeconds -le $word.StartSeconds) { throw 'Alignment boundary is outside its recording or has nonpositive duration.' }
            $identity = $word.Identity + ':' + $side
            $order = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
            $bucket = [int][Math]::Min(3, [Math]::Floor([Math]::Abs($snap) / (1000.0 * $State.SnapSeconds / 4.0)))
            [pscustomobject]@{ Identity = $identity; Occurrence = $word.Identity; Side = $side; PredictedSeconds = $at; SnapMs = $snap
                Evidence = $word.($side + 'Evidence'); Stratum = $side + ':' + $bucket; Order = $order
                Text = $sourceBook[0].Text.Substring($word.SourceStart, $word.SourceLength) }
        }
    })
    $groups = @($pool | Group-Object Stratum | Sort-Object Name)
    $selected = [Collections.Generic.List[object]]::new(); $rank = 0
    while ($selected.Count -lt [Math]::Min($AuditCount, $pool.Count)) {
        foreach ($group in $groups) {
            $orderedCases = @($group.Group | Sort-Object Order)
            if ($rank -lt $orderedCases.Count -and $selected.Count -lt $AuditCount) { $selected.Add($orderedCases[$rank]) }
        }
        $rank++
    }
    $destination = New-StudentOutputDirectory 'student-alignment-audit'; $cases = [Collections.Generic.List[object]]::new()
    foreach ($case in $selected) {
        $path = Join-Path $destination ('boundary-' + $cases.Count + '.wav')
        $excerpt = Write-StudentReviewExcerpt $signal $case.PredictedSeconds $case.PredictedSeconds $path
        $cases.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentBoundaryReviewCase'; Identity = $case.Identity; Occurrence = $case.Occurrence
            Side = $case.Side; Text = $case.Text; PredictedSeconds = $case.PredictedSeconds; SnapMs = $case.SnapMs; Evidence = $case.Evidence
            Stratum = $case.Stratum; ContextStartSeconds = $excerpt.StartSeconds; ContextEndSeconds = $excerpt.EndSeconds; Audio = $path
            AudioSHA256 = $excerpt.AudioSHA256; ObservedSeconds = ''; Status = 'Unreviewed'; Reviewer = ''; Note = '' })
    }
    $reviewPath = Join-Path $destination 'review.csv'; $cases | Export-Csv -LiteralPath $reviewPath
    $result = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentAlignmentAudit'; Recording = $State.Recording; AudioSHA256 = $audioHash
        PopulationBoundaries = $pool.Count; Cases = $cases.ToArray(); Reviewed = 0; MeanAbsoluteErrorMs = $null; ReviewPath = $reviewPath
        Instructions = 'Review source-relative boundary time independently in each excerpt; ObservedSeconds uses recording start, not excerpt start. Status Reviewed or Ambiguous needs Reviewer. Sampling is stratified by side and snap magnitude; aggregate error is not population-weighted.'
        MachineSHA256 = $script:StudentMachineSHA256; Directory = $destination }
    $result | Export-Clixml -LiteralPath (Join-Path $destination 'receipt.clixml') -Depth 12
    $result
}

function Measure-StudentContrast([object[]] $Observations, [int[]] $Predictions, [int] $Partition) {
    $counts = [int[]]::new(2); $correct = [int[]]::new(2)
    for ($index = 0; $index -lt $Observations.Count; $index++) {
        if ($Observations[$index].Fold -ne $Partition) { continue }
        $label = [int]$Observations[$index].Label; $counts[$label]++
        if ($Predictions[$index] -eq $label) { $correct[$label]++ }
    }
    [pscustomobject]@{ ClassCounts = $counts; Correct = $correct; Count = $counts[0] + $counts[1]
        BalancedAccuracy = $(if ($counts[0] -gt 0 -and $counts[1] -gt 0) { 0.5 * ($correct[0] / [double]$counts[0] + $correct[1] / [double]$counts[1]) } else { $null }) }
}

function Fit-StudentContrast([object[]] $Observations) {
    $features = [float[]]::new(5 * $Observations.Count); $labels = [int[]]::new($Observations.Count); $folds = [int[]]::new($Observations.Count)
    for ($index = 0; $index -lt $Observations.Count; $index++) {
        if ($Observations[$index].Features.Count -ne 5 -or $Observations[$index].Label -notin 0,1 -or $Observations[$index].Fold -notin 0,1,2,3,4) { throw 'Contrast observation has invalid dimensions, label or fold.' }
        for ($axis = 0; $axis -lt 5; $axis++) { $value = [float]$Observations[$index].Features[$axis]; if (-not [float]::IsFinite($value)) { throw 'Contrast feature is not finite.' }; $features[5 * $index + $axis] = $value }
        $labels[$index] = $Observations[$index].Label; $folds[$index] = $Observations[$index].Fold
    }
    $kernels = Import-StudentKernels; $fit = $kernels.ContrastThreshold.Invoke($features, $labels, $folds)
    if ($fit[3] -lt 0) { throw 'Contrast fitting needs both labels in training.' }
    $predictions = $kernels.ContrastDecisions.Invoke($features, [int]$fit[0], $fit[1], [int]$fit[2])
    [pscustomobject]@{ Axis = [int]$fit[0]; ThresholdDb = $fit[1]; Polarity = [int]$fit[2]; TrainingBalancedAccuracy = $fit[3]
        Development = Measure-StudentContrast $Observations $predictions 1; Test = Measure-StudentContrast $Observations $predictions 0; Predictions = $predictions }
}

function Invoke-StudentDiscrimination {
    if ($null -eq $State -or -not $State.PSObject.Properties['Phones'] -or $State.Phones.Count -eq 0) { throw 'Discriminate needs -State Alignment captured with -PhoneLabels.' }
    $kernels = Import-StudentKernels; $signal = Read-StudentAudio $State.Recording; $audioHash = (Get-FileHash -LiteralPath $State.Recording).Hash
    $settings = $script:StudentAlignment; $hopSeconds = $settings.Hop / [double]$settings.SampleRate
    $bands = $kernels.SpectralBands.Invoke($signal, $settings.SampleRate, $settings.Hop, $settings.Window)
    $frameCount = [int]($bands.Length / 5); $sourceBook = @(Get-StudentBooks -Name $State.Book)
    if ($sourceBook.Count -ne 1) { throw 'Discrimination needs the aligned typed source book.' }
    $accepted = [Collections.Generic.List[object]]::new(); $rejected = [Collections.Generic.List[object]]::new(); $bounds = [Collections.Generic.List[int]]::new()
    foreach ($phone in $State.Phones) {
        if ($phone.SourceAudioSHA256 -cne $audioHash -or $phone.LabelStatus -cne 'ZiraWarpHypothesis') { throw 'Phone hypothesis does not match the human recording or declared label source.' }
        # Only include complete spectral supports within the hypothesized phone interval. Require two frames.
        $first = [int][Math]::Ceiling($phone.StartSeconds / $hopSeconds)
        $last = [int][Math]::Floor(($phone.EndSeconds - $settings.Window / [double]$settings.SampleRate) / $hopSeconds) + 1
        if ($first -lt 1 -or $last -ge $frameCount -or $last - $first -lt 2) {
            $rejected.Add([pscustomobject]@{ Identity = $phone.Identity; Reason = 'Insufficient complete spectral support'; StartSeconds = $phone.StartSeconds; EndSeconds = $phone.EndSeconds }); continue
        }
        $spelling = $sourceBook[0].Text.Substring($phone.SourceStart, $phone.SourceLength).ToLowerInvariant()
        $wordType = [regex]::Replace($spelling, '[^\p{L}]', '')
        if (-not $wordType) { $rejected.Add([pscustomobject]@{ Identity = $phone.Identity; Reason = 'No lexical word type' }); continue }
        $fold = [int][Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($wordType))[0] % 5
        $accepted.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentAcousticPhoneEvidence'; Identity = $audioHash + ':' + $phone.Identity; Occurrence = $phone.Occurrence
            Phone = $phone.Phone; Next = $phone.Next; WordType = $wordType; Fold = $fold; StartSeconds = $phone.StartSeconds; EndSeconds = $phone.EndSeconds
            LabelStatus = $phone.LabelStatus; IndependentlyReviewed = $false; Features = [float[]]::new(5); EarlyFeatures = [float[]]::new(5); LateFeatures = [float[]]::new(5) })
        $bounds.Add($first); $bounds.Add($last)
    }
    if ($accepted.Count -eq 0) { throw 'No phone hypotheses have sufficient acoustic support.' }
    $means = $kernels.BandMeans.Invoke($bands, $bounds.ToArray())
    $earlyBounds = [int[]]::new($bounds.Count); $lateBounds = [int[]]::new($bounds.Count)
    for ($index = 0; $index -lt $bounds.Count; $index++) { $earlyBounds[$index] = $bounds[$index] - 1; $lateBounds[$index] = $bounds[$index] + 1 }
    $early = $kernels.BandMeans.Invoke($bands, $earlyBounds); $late = $kernels.BandMeans.Invoke($bands, $lateBounds)
    for ($index = 0; $index -lt $accepted.Count; $index++) {
        [Array]::Copy($means, 5 * $index, $accepted[$index].Features, 0, 5)
        [Array]::Copy($early, 5 * $index, $accepted[$index].EarlyFeatures, 0, 5); [Array]::Copy($late, 5 * $index, $accepted[$index].LateFeatures, 0, 5)
    }
    # Candidate inventory is chosen by training coverage alone. Test values cannot select the pair.
    $inventory = @($accepted | Where-Object Fold -GE 2 | Group-Object Phone | Where-Object Count -GE 20 | Sort-Object @{Expression='Count';Descending=$true},Name | Select-Object -First 12)
    $candidates = [Collections.Generic.List[object]]::new()
    for ($left = 0; $left -lt $inventory.Count; $left++) {
        for ($right = $left + 1; $right -lt $inventory.Count; $right++) {
            $names = @([string]$inventory[$left].Name, [string]$inventory[$right].Name)
            $observations = @($accepted | Where-Object Phone -CIn $names | ForEach-Object {
                [pscustomobject]@{ Identity = $_.Identity; Fold = $_.Fold; Label = [int]($_.Phone -ceq $names[1]); Features = $_.Features; Evidence = $_ }
            })
            $fit = Fit-StudentContrast $observations
            if ($fit.Development.ClassCounts[0] -lt 8 -or $fit.Development.ClassCounts[1] -lt 8) { continue }
            $candidates.Add([pscustomobject]@{ Phones = $names; Observations = $observations; Fit = $fit })
        }
    }
    if ($candidates.Count -eq 0) { throw 'No training-selected phone pair has sufficient development evidence.' }
    $winner = @($candidates | Sort-Object @{Expression={$_.Fit.Development.BalancedAccuracy};Descending=$true},@{Expression={$_.Phones -join ':'}})[0]
    $testWords = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($observation in $winner.Observations | Where-Object Fold -EQ 0) { [void]$testWords.Add($observation.Evidence.WordType) }
    if (@($winner.Observations | Where-Object { $_.Fold -ne 0 -and $testWords.Contains($_.Evidence.WordType) }).Count) { throw 'A word type crossed the test partition.' }
    $sensitive = 0; $testCount = 0
    foreach ($observation in $winner.Observations | Where-Object Fold -EQ 0) {
        $nominal = $kernels.ContrastDecisions.Invoke([float[]]$observation.Features, $winner.Fit.Axis, $winner.Fit.ThresholdDb, $winner.Fit.Polarity)[0]
        $before = $kernels.ContrastDecisions.Invoke([float[]]$observation.Evidence.EarlyFeatures, $winner.Fit.Axis, $winner.Fit.ThresholdDb, $winner.Fit.Polarity)[0]
        $after = $kernels.ContrastDecisions.Invoke([float[]]$observation.Evidence.LateFeatures, $winner.Fit.Axis, $winner.Fit.ThresholdDb, $winner.Fit.Polarity)[0]
        if ($before -ne $nominal -or $after -ne $nominal) { $sensitive++ }; $testCount++
    }
    $destination = New-StudentOutputDirectory 'student-acoustic-contrast'
    $reviewCases = @(foreach ($label in 0,1) {
        foreach ($observation in @($winner.Observations | Where-Object { $_.Fold -eq 0 -and $_.Label -eq $label } | Sort-Object Identity | Select-Object -First 16)) {
            $item = $observation.Evidence; $path = Join-Path $destination ('phone-' + $label + '-' + $item.WordType + '-' + $item.StartSeconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture) + '.wav')
            $excerpt = Write-StudentReviewExcerpt $signal $item.StartSeconds $item.EndSeconds $path 0.25
            [pscustomobject]@{ Identity = $item.Identity; WordType = $item.WordType; ProvisionalPhone = $item.Phone
                StartSeconds = $item.StartSeconds; EndSeconds = $item.EndSeconds; ContextStartSeconds = $excerpt.StartSeconds; Audio = $path
                AudioSHA256 = $excerpt.AudioSHA256; ObservedPhone = ''; ObservedStartSeconds = ''; ObservedEndSeconds = ''; Status = 'Unreviewed'; Reviewer = '' }
        }
    })
    $phoneReviewPath = Join-Path $destination 'phone-review.csv'; $reviewCases | Export-Csv -LiteralPath $phoneReviewPath
    $imagePathForContrast = if ($ImagePath) { [IO.Path]::GetFullPath($ImagePath) } else { Join-Path $destination 'image.clixml.gz' }
    $image = Open-StudentImage $imagePathForContrast
    $root = New-StudentPercept $image 'AcousticContrast' 'AcousticContrast' ([float[]](0,0,1,0)) $image.Percepts['Occurrence']
    $programIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($winner.Phones -join ':') + ':' + $winner.Fit.Axis + ':' + $winner.Fit.ThresholdDb.ToString('R', [Globalization.CultureInfo]::InvariantCulture) + ':' + $winner.Fit.Polarity)))
    $program = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentAcousticProgram'; Identity = $programIdentity; Kind = 'AcousticThreshold'; State = 'Provisional'
        Phones = $winner.Phones; Axis = $winner.Fit.Axis; ThresholdDb = $winner.Fit.ThresholdDb; Polarity = $winner.Fit.Polarity
        Units = 'dB relative to mean octave-band level'; LabelStatus = 'ZiraWarpHypothesis'; HumanValidated = $false
        TrainingBalancedAccuracy = $winner.Fit.TrainingBalancedAccuracy; Development = $winner.Fit.Development; Test = $winner.Fit.Test }
    $root.Rules.Add($program)
    Publish-StudentPercept $image $root.Identity
    for ($index = 0; $index -lt $winner.Observations.Count; $index++) {
        $observation = $winner.Observations[$index]; $measured = $observation.Evidence
        $record = [pscustomobject]@{ Identity = $observation.Identity + ':' + $programIdentity; Occurrence = $measured.Occurrence
            Provenance = [pscustomobject]@{ Kind = 'Human'; SHA256 = $audioHash; LabelSource = 'ZiraWarpHypothesis'; IndependentlyReviewed = $false }
            Condition = [pscustomobject]@{ Kind = 'PhoneHypothesis'; Phone = $measured.Phone; Next = $measured.Next; WordType = $measured.WordType; Fold = $measured.Fold }
            Measured = [pscustomobject]@{ StartSeconds = $measured.StartSeconds; EndSeconds = $measured.EndSeconds; Features = $measured.Features
                Label = $observation.Label; Prediction = $winner.Fit.Predictions[$index]; Program = $programIdentity; Comparison = 'Agreement with provisional alignment label' } }
        $role = if ($observation.Label -eq $winner.Fit.Predictions[$index]) { 'Example' } else { 'CounterExample' }
        $null = Add-StudentImageObservation $image $root.Identity $record $role
    }
    foreach ($observation in $winner.Observations) {
        $evidenceId = $observation.Identity + ':' + $programIdentity
        $decisionId = 'acoustic:' + $evidenceId
        $null = New-StudentDecision $image $decisionId 'Acoustic' ([pscustomobject]@{ Evidence = $evidenceId }) ([string[]]@('AcousticContrast'))
    }
    $root.Genealogy.Add([pscustomobject]@{ Operation = 'Proposed'; Rule = $programIdentity; Step = 'Discriminate'; Reason = 'Training fit and development pair selection; independent phone review required' })
    $image.Pin('AcousticContrast'); $checkpoint = $image.Save()
    $result = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentAcousticDiscrimination'; Program = $program; EligiblePhoneHypotheses = $accepted.Count
        Rejected = $rejected.ToArray(); CandidatePairs = $candidates.Count; TestWordTypes = $testWords.Count; TestBoundarySensitive = $sensitive; TestCount = $testCount
        BoundaryPerturbationSeconds = $hopSeconds; Evidence = $winner.Observations; Image = $checkpoint; SourceAudioSHA256 = $audioHash
        PhoneReviewPath = $phoneReviewPath; PhoneReviewCases = $reviewCases.Count
        MachineSHA256 = $script:StudentMachineSHA256; KernelSHA256 = $kernels.SHA256; Directory = $destination
        Acceptance = 'Provisional label agreement only; no independently validated phone discrimination or speech synthesis claim' }
    $result | Export-Clixml -LiteralPath (Join-Path $destination 'receipt.clixml') -Depth 16
    $result
}

function Invoke-StudentAcousticProgram($Image, [float[]] $Features) {
    if ($Features.Count -ne 5 -or @($Features | Where-Object { -not [float]::IsFinite($_) }).Count) { throw 'Acoustic classification needs five finite relative-band values.' }
    foreach ($neighbor in @(Get-StudentImageNeighborhood $Image ([float[]](0,0,1,0)) 1)) {
        foreach ($rule in $neighbor.Percept.Rules) {
            if ($rule.Kind -ceq 'AcousticThreshold' -and $rule.State -ceq 'Provisional') {
                $prediction = (Import-StudentKernels).ContrastDecisions.Invoke($Features, [int]$rule.Axis, [double]$rule.ThresholdDb, [int]$rule.Polarity)[0]
                return [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPhoneDecision'; Phone = $rule.Phones[$prediction]; Rule = $rule.Identity; Status = $rule.State; HumanValidated = $rule.HumanValidated }
            }
        }
    }
    $null
}

function Update-StudentAcousticProgram($Image) {
    if (-not $Image.Percepts.ContainsKey('AcousticContrast')) { throw 'LearnContrast needs its acoustic evidence percept.' }
    $node = $Image.Percepts['AcousticContrast']
    $current = @($node.Rules | Where-Object { $_.Kind -ceq 'AcousticThreshold' -and $_.State -ceq 'Provisional' })
    if ($current.Count -ne 1) { throw 'LearnContrast needs exactly one active provisional contrast.' }
    $program = $current[0]
    $observations = @(@($node.Examples) + @($node.CounterExamples) | ForEach-Object {
        if ($_.Condition.Kind -cne 'PhoneHypothesis' -or $_.Condition.Phone -cnotin $program.Phones) { throw 'Contrast evidence has an incompatible typed condition.' }
        $expectedFold = [int][Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($_.Condition.WordType))[0] % 5
        if ($expectedFold -ne $_.Condition.Fold -or [int]($_.Condition.Phone -ceq $program.Phones[1]) -ne $_.Measured.Label) { throw 'Contrast evidence changed its word-type split or label identity.' }
        [pscustomobject]@{ Identity = $_.Identity; Fold = $_.Condition.Fold; Label = $_.Measured.Label; Features = [float[]]$_.Measured.Features }
    })
    $fit = Fit-StudentContrast $observations
    $features = [float[]]::new(5 * $observations.Count)
    for ($index = 0; $index -lt $observations.Count; $index++) { [Array]::Copy($observations[$index].Features, 0, $features, 5 * $index, 5) }
    $predictions = (Import-StudentKernels).ContrastDecisions.Invoke($features, [int]$program.Axis, [double]$program.ThresholdDb, [int]$program.Polarity)
    $previous = Measure-StudentContrast $observations $predictions 1
    $changed = $null -ne $fit.Development.BalancedAccuracy -and $fit.Development.BalancedAccuracy -gt $previous.BalancedAccuracy
    $corrections = @()
    if ($changed) {
        $newIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($program.Identity + ':' + $observations.Count + ':' + $fit.Axis + ':' + $fit.ThresholdDb.ToString('R', [Globalization.CultureInfo]::InvariantCulture) + ':' + $fit.Polarity)))
        $replacement = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentAcousticProgram'; Identity = $newIdentity; Kind = 'AcousticThreshold'; State = 'Provisional'
            Phones = $program.Phones; Axis = $fit.Axis; ThresholdDb = $fit.ThresholdDb; Polarity = $fit.Polarity; Units = $program.Units
            LabelStatus = $program.LabelStatus; HumanValidated = $false; TrainingBalancedAccuracy = $fit.TrainingBalancedAccuracy; Development = $fit.Development; Test = $fit.Test }
        $corrections = @(for ($index = 0; $index -lt $observations.Count; $index++) {
            if ($predictions[$index] -ne $observations[$index].Label -and $fit.Predictions[$index] -eq $observations[$index].Label) { $observations[$index].Identity }
        })
        $program.State = 'Superseded'; $node.Rules.Add($replacement)
        Publish-StudentPercept $Image $node.Identity
        $node.Genealogy.Add([pscustomobject]@{ Operation = 'Refined'; Parent = $program.Identity; Rule = $newIdentity; Evidence = @($observations.Identity); Corrections = $corrections; Step = 'LearnContrast' })
        $Image.Changed = $true
    }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentContrastUpdate'; Changed = $changed; PreviousDevelopment = $previous; CandidateDevelopment = $fit.Development
        Test = $fit.Test; CorrectedEvidence = $corrections; Status = 'Provisional label agreement; no human validation' }
}

function New-StudentControllerRecording([object[]] $Events, [int] $Ticks, [object] $Provenance, [int] $Seed) {
    if ($Ticks -le 0 -or $Ticks -gt [int]::MaxValue / 300) { throw 'Controller duration is outside the audio buffer range.' }
    $previousTick = -1
    foreach ($event in $Events) {
        if ($event.Tick -ne [Math]::Truncate([double]$event.Tick) -or $event.Tick -le $previousTick -or $event.Tick -ge $Ticks) { throw 'Controller events must have increasing integer ticks within the performance.' }
        $previousTick = $event.Tick
        if ($event.Buttons -lt 0 -or $event.Buttons -gt 127) { throw 'Controller button bits are not declared.' }
        if (@(16, 32, 64) -notcontains ($event.Buttons -band 112)) { throw 'Select exactly one response mode.' }
        foreach ($control in $script:StudentController.Controls) {
            $value = [double]$event.($control.Name)
            if (-not [double]::IsFinite($value) -or $value -lt $control.Minimum -or $value -gt $control.Maximum) { throw "Controller $($control.Name) is outside its declared physical range." }
        }
        if (($event.Buttons -band 2) -ne 0 -and (($event.Buttons -band 1) -eq 0 -or $event.PitchHz -le 0)) { throw 'Voicing requires an active contact and positive pitch.' }
    }
    if ($Events.Count -eq 0 -or $Events[0].Tick -ne 0) { throw 'Controller recording needs its initial state at tick zero.' }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentControllerRecording'; Layout = $script:StudentController
        Ticks = $Ticks; Events = $Events; Occurrences = @(); Seed = $Seed; Provenance = $Provenance
        MachineSHA256 = $script:StudentMachineSHA256
        KernelSHA256 = (Import-StudentKernels).SHA256 }
}

function Expand-StudentController($Performance, [ValidateSet('All', 'LevelRms', 'PitchHz', 'Buttons')][string] $Projection = 'All') {
    # Held analog state; note-on and rest are one-tick impulses. The store retains physical values.
    $frames = [float[]]::new($(if ($Projection -cne 'All') { $Performance.Ticks } else { 8 * $Performance.Ticks }))
    $wire = [byte[]]::new($(if ($Projection -cne 'All') { 0 } else { 12 * $Performance.Ticks }))
    $index = 0; $held = $Performance.Events[0]
    for ($tickIndex = 0; $tickIndex -lt $Performance.Ticks; $tickIndex++) {
        $changed = $index -lt $Performance.Events.Count -and $Performance.Events[$index].Tick -eq $tickIndex
        if ($changed) { $held = $Performance.Events[$index]; $index++ }
        if ($Projection -cne 'All') {
            $frames[$tickIndex] = switch ($Projection) { 'LevelRms' { [float][Math]::Pow(10.0, $held.LevelDb / 20.0) }; 'PitchHz' { [float]$held.PitchHz }; 'Buttons' { [float]$held.Buttons } }
            continue
        }
        $buttons = [int]$held.Buttons; if (-not $changed) { $buttons = $buttons -band 115 }
        $base = 8 * $tickIndex
        $frames[$base] = $held.PitchHz; $frames[$base + 1] = $held.LevelDb; $frames[$base + 2] = $held.Aperiodicity
        $frames[$base + 3] = $held.Coefficient; $frames[$base + 4] = $held.TiltDb; $frames[$base + 5] = $held.TimeSeconds
        $frames[$base + 6] = $buttons; $frames[$base + 7] = switch ($buttons -band 112) { 32 { 0.25 }; 16 { 0.5 }; 64 { 1.0 } }
        $wire[12 * $tickIndex] = [byte]$buttons
        foreach ($control in $Performance.Layout.Controls) {
            $fraction = 0.0
            if ($control.Maximum -gt $control.Minimum) { $fraction = ([double]$held.($control.Name) - $control.Minimum) / ($control.Maximum - $control.Minimum) }
            $offset = 12 * $tickIndex + $control.Offset
            if ($control.Bytes -eq 1) { $wire[$offset] = [byte][Math]::Round(255 * $fraction) }
            else {
                $signed = 0
                if ($control.Maximum -gt $control.Minimum) { $signed = [int][Math]::Round(65534 * $fraction) - 32767 }
                $wire[$offset] = [byte]($signed -band 255); $wire[$offset + 1] = [byte](($signed -shr 8) -band 255)
            }
        }
    }
    [pscustomobject]@{ Frames = $frames; Wire = $wire }
}

function Export-StudentStemMidi($Performance, [float[]] $Frames, [int] $Contact, [string] $Path) {
    # MIDI 1.0 inspection only. 80 PPQN at 1 second/quarter makes one MIDI tick one generator tick.
    $body = [IO.MemoryStream]::new(); $previous = 0; $activeNote = -1
    $writeEvent = {
        param([int] $At, [byte[]] $Bytes)
        $delta = $At - $script:stemMidiTick; $script:stemMidiTick = $At
        $vlq = [Collections.Generic.List[byte]]::new(); $vlq.Insert(0, [byte]($delta -band 127)); $delta = $delta -shr 7
        while ($delta -gt 0) { $vlq.Insert(0, [byte](($delta -band 127) -bor 128)); $delta = $delta -shr 7 }
        $body.Write($vlq.ToArray()); $body.Write($Bytes)
    }
    $script:stemMidiTick = 0
    & $writeEvent 0 ([byte[]](255, 81, 3, 15, 66, 64))
    # Member channel 2, +-48 semitone pitch-bend range.
    & $writeEvent 0 ([byte[]](176, 101, 0, 176, 100, 6, 176, 6, 1))
    & $writeEvent 0 ([byte[]](177, 101, 0, 177, 100, 0, 177, 6, 48, 177, 38, 0))
    for ($tickIndex = 0; $tickIndex -lt $Performance.Ticks; $tickIndex++) {
        $offset = 8 * $tickIndex; $buttons = [int]$Frames[$offset + 6]
        $on = switch ($Contact) {
            0 { ($buttons -band 3) -eq 3 }
            1 { ($buttons -band 3) -eq 1 }
            2 { ($buttons -band 12) -ne 0 -or ($buttons -band 112) -ne $previous }
            3 { [Math]::Abs($Frames[$offset + 3]) -gt 0 }
        }
        if ($activeNote -ge 0 -and (-not $on -or ($buttons -band 4) -ne 0 -or $Contact -eq 2)) { & $writeEvent $tickIndex ([byte[]](129, $activeNote, 0)); $activeNote = -1 }
        $pitch = if ($Contact -eq 0) { [double]$Frames[$offset] } elseif ($Contact -eq 3) { 1000.0 } else { 440.0 }
        if ($on -and $pitch -gt 0) {
            $semitones = 69 + 12 * [Math]::Log($pitch / 440, 2)
            if ($activeNote -lt 0) { $activeNote = [int][Math]::Clamp([Math]::Round($semitones), 0, 127); & $writeEvent $tickIndex ([byte[]](145, $activeNote, 96)) }
            $bendValue = [int][Math]::Clamp([Math]::Round(8192 + ($semitones - $activeNote) * 8192 / 48), 0, 16383)
            & $writeEvent $tickIndex ([byte[]](225, ($bendValue -band 127), ($bendValue -shr 7)))
            & $writeEvent $tickIndex ([byte[]](177, 74, [int][Math]::Clamp([Math]::Round(127 * ($Frames[$offset + 3] + 1) / 2), 0, 127)))
            & $writeEvent $tickIndex ([byte[]](209, [int][Math]::Clamp([Math]::Round(127 * ($Frames[$offset + 1] + 96) / 96), 0, 127)))
            & $writeEvent $tickIndex ([byte[]](177, 71, [int][Math]::Clamp([Math]::Round(127 * ($Frames[$offset + 4] + 96) / 192), 0, 127)))
            & $writeEvent $tickIndex ([byte[]](177, 1, [int][Math]::Clamp([Math]::Round(127 * $Frames[$offset + 2]), 0, 127)))
        }
        $previous = $buttons -band 112
    }
    if ($activeNote -ge 0) { & $writeEvent $Performance.Ticks ([byte[]](129, $activeNote, 0)) }
    & $writeEvent $Performance.Ticks ([byte[]](255, 47, 0))
    $big = { param([int] $Value, [int] $Count) [byte[]]@(for ($i = $Count - 1; $i -ge 0; $i--) { ($Value -shr (8 * $i)) -band 255 }) }
    [IO.File]::WriteAllBytes($Path, [byte[]]([Text.Encoding]::ASCII.GetBytes('MThd') + (& $big 6 4) + (& $big 0 2) + (& $big 1 2) + (& $big 80 2) + [Text.Encoding]::ASCII.GetBytes('MTrk') + (& $big $body.Length 4) + $body.ToArray()))
    $body.Dispose()
}

function Invoke-StudentStems($Performance = $State, [string] $Destination = '') {
    $kernels = Import-StudentKernels
    # Independent known paths guard the alignment primitive before it is used on unlabelled human audio.
    $referenceBands = [float[]]::new(120); $stretchedBands = [float[]]::new(240)
    for ($frameIndex = 0; $frameIndex -lt 24; $frameIndex++) {
        for ($bandIndex = 0; $bandIndex -lt 5; $bandIndex++) {
            $value = [float](($frameIndex * ($bandIndex + 3) + $bandIndex * $bandIndex) % 31)
            $referenceBands[5 * $frameIndex + $bandIndex] = $value
            $stretchedBands[10 * $frameIndex + $bandIndex] = $value; $stretchedBands[10 * $frameIndex + 5 + $bandIndex] = $value
        }
    }
    $identityMap = $kernels.SpectralWarp.Invoke($referenceBands, $referenceBands, 8, 0)
    $stretchMap = $kernels.SpectralWarp.Invoke($referenceBands, $stretchedBands, 8, 0)
    for ($frameIndex = 0; $frameIndex -lt 24; $frameIndex++) {
        if ($identityMap[$frameIndex] -ne $frameIndex -or [Math]::Abs($stretchMap[$frameIndex] - 2 * $frameIndex) -gt 1) { throw 'Spectral warp failed its independently specified paths.' }
    }
    if ($null -ne $Performance -and $Performance.PSObject.Properties['Controller']) { $Performance = $Performance.Controller }
    if ($null -eq $Performance) {
        # Arithmetic coverage of contacts, modes, pitches and rests; no text selected for the test.
        $events = @(for ($caseIndex = 0; $caseIndex -lt 24; $caseIndex++) {
            $mode = @(16, 32, 64)[$caseIndex % 3]; $unvoiced = $caseIndex % 4 -eq 3
            [pscustomobject]@{ PSTypeName = 'Kokoro.StudentControllerEvent'; Tick = 16 * $caseIndex; Buttons = $mode + $(if ($unvoiced) { 5 } else { 7 })
                PitchHz = $(if ($unvoiced) { 0.0 } else { 80.0 + ($caseIndex * 97 % 400) }); LevelDb = -18.0
                Aperiodicity = $(if ($unvoiced) { 1.0 } else { 0.0 }); Coefficient = ($caseIndex % 9 - 4) / 4.0; TiltDb = -12.0; TimeSeconds = 0.0 }
            [pscustomobject]@{ PSTypeName = 'Kokoro.StudentControllerEvent'; Tick = 16 * $caseIndex + 12; Buttons = $mode + 8
                PitchHz = 0.0; LevelDb = -96.0; Aperiodicity = 0.0; Coefficient = 0.0; TiltDb = -12.0; TimeSeconds = 0.0 }
        })
        $Performance = New-StudentControllerRecording $events 384 'Student contact coverage' 1729
    }
    # Revalidate incoming physical recordings rather than trusting serialized type names.
    $validated = New-StudentControllerRecording $Performance.Events $Performance.Ticks $Performance.Provenance $Performance.Seed
    # Capture provenance stays attached to the original performance when a different renderer plays it.
    $validated.MachineSHA256 = $Performance.MachineSHA256; $validated.KernelSHA256 = $Performance.KernelSHA256
    if ($Performance.PSObject.Properties['Occurrences']) { $validated.Occurrences = $Performance.Occurrences }
    $Performance = $validated
    if (-not $Destination) { $Destination = New-StudentOutputDirectory 'student-stems' }
    [void][IO.Directory]::CreateDirectory($Destination)
    $expanded = Expand-StudentController $Performance
    $stems = [Collections.Generic.List[object]]::new(); $signals = [Collections.Generic.List[object]]::new()
    for ($contactIndex = 0; $contactIndex -lt $Performance.Layout.Contacts.Count; $contactIndex++) {
        $name = $Performance.Layout.Contacts[$contactIndex]
        $signal = $kernels.ContactStem.Invoke($expanded.Frames, $contactIndex, $Performance.Seed)
        $replay = $kernels.ContactStem.Invoke($expanded.Frames, $contactIndex, $Performance.Seed)
        $bytes = [byte[]](ConvertTo-StudentWave $signal); $replayedBytes = [byte[]](ConvertTo-StudentWave $replay)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        if ($hash -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($replayedBytes))) { throw 'Stem ghost replay differs.' }
        $audioPath = Join-Path $Destination "$name.wav"; [IO.File]::WriteAllBytes($audioPath, $bytes)
        $midiPath = Join-Path $Destination "$name.mpe.mid"; Export-StudentStemMidi $Performance $expanded.Frames $contactIndex $midiPath
        # Score the quantized PCM actually written, not the unquantized synthesis buffer.
        $signals.Add($kernels.ReadStem.Invoke($bytes))
        $stems.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentStem'; Contact = $name; Audio = $audioPath; Midi = $midiPath; SHA256 = $hash; Samples = $signal.Length })
    }
    $harmonic = [float[]]$signals[0]; $padded = [float[]]::new($harmonic.Length + 1200); $harmonic.CopyTo($padded, 0)
    $detected = $kernels.PitchTrack.Invoke($padded, 24000, 300, 600, 24, 343, 0.15)
    $levels = $kernels.FrameLevels.Invoke($harmonic, 300); $noiseLevels = $kernels.FrameLevels.Invoke([float[]]$signals[1], 300)
    $coefficientTrack = $kernels.CoefficientTrack.Invoke([float[]]$signals[3])
    $pitchErrors = [Collections.Generic.List[double]]::new(); $stateErrors = 0; $clickErrors = 0; $previousMode = 16
    $axisMaximumError = 0.0; $responseMaximumError = 0.0
    for ($tickIndex = 0; $tickIndex -lt $Performance.Ticks; $tickIndex++) {
        $offset = 8 * $tickIndex; $buttons = [int]$expanded.Frames[$offset + 6]
        $expectVoice = ($buttons -band 3) -eq 3; $expectNoise = ($buttons -band 3) -eq 1
        if (($levels[$tickIndex] -gt 0.00002) -ne $expectVoice -or ($noiseLevels[$tickIndex] -gt 0.00002) -ne $expectNoise) { $stateErrors++ }
        $expectClick = ($buttons -band 12) -ne 0 -or ($buttons -band 112) -ne $previousMode
        if (([Math]::Abs($signals[2][300 * $tickIndex]) -gt 0.1) -ne $expectClick) { $clickErrors++ }
        $previousMode = $buttons -band 112
        $axisExpected = [double]$expanded.Frames[$offset + 3]
        if ([Math]::Abs($axisExpected) -ge 0.1) {
            $axisMaximumError = [Math]::Max($axisMaximumError, [Math]::Abs([double]$coefficientTrack[2 * $tickIndex] - $axisExpected))
            $responseMaximumError = [Math]::Max($responseMaximumError, [Math]::Abs([double]$coefficientTrack[2 * $tickIndex + 1] - [double]$expanded.Frames[$offset + 7]))
        }
        # Interior windows only: YIN needs support on both sides. Changes remain in the boundary/level gate.
        if ($expectVoice -and $tickIndex -ge 2 -and $tickIndex + 2 -lt $Performance.Ticks) {
            $stable = $true; $expectedPitch = [double]$expanded.Frames[$offset]
            for ($relative = -2; $relative -le 2; $relative++) {
                $other = 8 * ($tickIndex + $relative)
                if (($expanded.Frames[$other + 6] -band 3) -ne 3 -or [Math]::Abs([double]$expanded.Frames[$other] - $expectedPitch) -gt 0.1) { $stable = $false }
            }
            if ($stable) {
                $actualPitch = [double]$detected[3 * ($tickIndex - 1)]
                $cents = if ($actualPitch -gt 0) { [Math]::Abs(1200 * [Math]::Log($actualPitch / $expectedPitch, 2)) } else { 12000.0 }
                $pitchErrors.Add($cents)
            }
        }
    }
    $maxCents = if ($pitchErrors.Count) { ($pitchErrors | Measure-Object -Maximum).Maximum } else { 0.0 }
    if ($stateErrors -gt 0 -or $clickErrors -gt 0 -or $maxCents -gt $Performance.Layout.PitchToleranceCents -or $axisMaximumError -gt 0.05 -or $responseMaximumError -gt 0.1) {
        throw "Stem round trip failed: state ticks=$stateErrors, event ticks=$clickErrors, max pitch cents=$maxCents, axis=$axisMaximumError, response=$responseMaximumError."
    }
    $controllerPath = Join-Path $Destination 'controller.clixml'; $Performance | Export-Clixml -LiteralPath $controllerPath
    [IO.File]::WriteAllBytes((Join-Path $Destination 'controller.bin'), $expanded.Wire)
    $result = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentStems'; Controller = $Performance; ControllerPath = $controllerPath
        Stems = $stems.ToArray(); Ticks = $Performance.Ticks; PitchFrames = $pitchErrors.Count; MaximumPitchCents = $maxCents
        PitchToleranceCents = $Performance.Layout.PitchToleranceCents; StateErrors = $stateErrors; EventErrors = $clickErrors
        BoundaryToleranceTicks = $Performance.Layout.BoundaryToleranceTicks
        SpectralWarpIdentityFrames = 24; SpectralWarpStretchedFrames = 48
        MaximumAxisError = $axisMaximumError; AxisTolerance = 0.05; MaximumResponseError = $responseMaximumError; ResponseTolerance = 0.1
        GhostReplay = $true; RenderMachineSHA256 = $script:StudentMachineSHA256; RenderKernelSHA256 = $kernels.SHA256
        BiasRow = 'Not supplied'; Binding = 'Diagnostic host contacts; generator contact not exercised' }
    $result | Export-Clixml -LiteralPath (Join-Path $Destination 'receipt.clixml')
    $result
}

function Invoke-StudentListen {
    # Listening, first form, from the audio alone (no text, no alignment yet): pitch, level and voicing per 10 ms (YIN at
    # 16 kHz), voiced stretches split at level dips and pitch jumps into notes, the silences between them as rests.
    # Written as an MPE MIDI 1.0 file (member channels 2 to 16, +-48-semitone per-note bend, channel pressure for level;
    # 1 MIDI tick = 1 ms). The native recording uses the generator clock; Stems plays its diagnostic contacts.
    $kernels = Import-StudentKernels
    $decoded = @(Invoke-StudentRecordings); if ($RecordingLimit -gt 0 -and $decoded.Count -gt $RecordingLimit) { $decoded = $decoded[0..($RecordingLimit - 1)] }
    $output = Join-Path ([IO.Path]::GetFullPath($Recordings)) 'listen'; [void][IO.Directory]::CreateDirectory($output)
    $rate = 16000; $hop = 160; $window = 400
    foreach ($recording in $decoded) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $x = Read-StudentAudio $recording.Wav
        $decodeSeconds = $watch.Elapsed.TotalSeconds
        $track = $kernels.PitchTrack.Invoke($x, $rate, $hop, $window, 32, 229, 0.15)
        $tilt = $kernels.SpectralSlope.Invoke($x, $rate, $hop, $window)
        $trackSeconds = $watch.Elapsed.TotalSeconds - $decodeSeconds
        $sourceHash = (Get-FileHash -LiteralPath $recording.Wav).Hash
        $sourceIdentity = [IO.Path]::GetRelativePath($script:StudentRoot, $recording.Wav)
        $n = [int]($track.Length / 3); $db = [double[]]::new($n); $semis = [double[]]::new($n); $peak = -200.0
        if ($n -eq 0) { throw 'Recording is too short for the Listen detector support.' }
        for ($t = 0; $t -lt $n; $t++) { $db[$t] = 20 * [Math]::Log10([double]$track[3 * $t + 2] + 1e-9); if ($db[$t] -gt $peak) { $peak = $db[$t] } }
        $floor = $peak - 35
        $voiced = [bool[]]::new($n)
        for ($t = 0; $t -lt $n; $t++) {
            $f0 = [double]$track[3 * $t]
            if ($f0 -gt 0 -and $db[$t] -gt $floor -and $track[3 * $t + 1] -lt 0.2) { $voiced[$t] = $true; $semis[$t] = 69 + 12 * [Math]::Log($f0 / 440.0, 2) }
        }
        # Notes: voiced runs, split where pitch jumps 3 semitones or level dips 9 dB below the note's peak and rises again.
        $notes = [Collections.Generic.List[object]]::new(); $t = 0
        while ($t -lt $n) {
            if (-not $voiced[$t]) { $t++; continue }
            $first = $t; $top = $db[$t]; $t++
            while ($t -lt $n -and $voiced[$t] -and [Math]::Abs($semis[$t] - $semis[$t - 1]) -lt 3 -and
                -not ($db[$t] -lt $top - 9 -and $t + 1 -lt $n -and $db[$t + 1] -gt $db[$t])) { if ($db[$t] -gt $top) { $top = $db[$t] }; $t++ }
            if ($t - $first -ge 4) {
                $values = [double[]]@($semis[$first..($t - 1)] | Sort-Object); $onset = ($db[$first..([Math]::Min($t - 1, $first + 4))] | Measure-Object -Maximum).Maximum
                $pitchTotal = 0.0; $levelTotal = 0.0; $tiltTotal = 0.0; $aperiodicTotal = 0.0
                for ($noteFrame = $first; $noteFrame -lt $t; $noteFrame++) {
                    $pitchTotal += $track[3 * $noteFrame]; $levelTotal += $db[$noteFrame]
                    $tiltTotal += $tilt[$noteFrame]; $aperiodicTotal += $track[3 * $noteFrame + 1]
                }
                $noteFrames = $t - $first
                $notes.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentAcousticOccurrence'; Identity = $sourceHash + ':' + $notes.Count
                    Source = $sourceIdentity; SourceSHA256 = $sourceHash; Kind = 'VoicedNote'; First = $first; Last = $t
                    StartSeconds = ($first * $hop + $window / 2) / $rate; EndSeconds = ($t * $hop + $window / 2) / $rate
                    PitchHz = $pitchTotal / $noteFrames; LevelDb = $levelTotal / $noteFrames
                    TiltDbPerOctave = $tiltTotal / $noteFrames; Aperiodicity = $aperiodicTotal / $noteFrames
                    Note = [int][Math]::Round($values[[int][Math]::Floor($values.Count / 2)]); Onset = $onset })
            }
        }
        $level = { param([double] $value) [int][Math]::Max(1, [Math]::Min(127, [Math]::Round(($value - $floor) / 35 * 126) + 1)) }
        $tick = { param([int] $frame) [int][Math]::Round(($frame * $hop + $window / 2) * 1000.0 / $rate) }
        # MPE: channel 1 the master (MPE Configuration Message, 15 member channels), members 2 to 16 at +-48 semitones.
        $events = [Collections.Generic.List[object]]::new()
        $add = { param([int] $at, [byte[]] $bytes) $events.Add([pscustomobject]@{ Tick = $at; Order = $script:listenOrder++; Bytes = $bytes }) }
        $script:listenOrder = 0
        & $add 0 ([byte[]](0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20))
        & $add 0 ([byte[]](0xB0, 101, 0, 0xB0, 100, 6, 0xB0, 6, 15))
        for ($c = 1; $c -le 15; $c++) { & $add 0 ([byte[]]((0xB0 + $c), 101, 0, (0xB0 + $c), 100, 0, (0xB0 + $c), 6, 48, (0xB0 + $c), 38, 0)) }
        $bend = { param([int] $channel, [double] $cents) $v = [int][Math]::Max(0, [Math]::Min(16383, 8192 + [Math]::Round($cents / 4800 * 8192))); [byte[]]((0xE0 + $channel), ($v -band 127), ($v -shr 7)) }
        for ($k = 0; $k -lt $notes.Count; $k++) {
            $note = $notes[$k]; $channel = 1 + ($k % 15); $last = -1
            & $add (& $tick $note.First) (& $bend $channel (100 * ($semis[$note.First] - $note.Note)))
            & $add (& $tick $note.First) ([byte[]]((0x90 + $channel), $note.Note, (& $level $note.Onset)))
            for ($t = $note.First + 2; $t -lt $note.Last; $t += 2) {
                & $add (& $tick $t) (& $bend $channel (100 * ($semis[$t] - $note.Note)))
                $pressure = & $level $db[$t]; if ($pressure -ne $last) { & $add (& $tick $t) ([byte[]]((0xD0 + $channel), $pressure)); $last = $pressure }
                & $add (& $tick $t) ([byte[]]((0xB0 + $channel), 74, [int][Math]::Clamp([Math]::Round(127 * ($tilt[$t] + 96) / 192), 0, 127)))
                & $add (& $tick $t) ([byte[]]((0xB0 + $channel), 1, [int][Math]::Clamp([Math]::Round(127 * $track[3 * $t + 1]), 0, 127)))
            }
            & $add (& $tick $note.Last) ([byte[]]((0x80 + $channel), $note.Note, 0))
        }
        $track_ = [IO.MemoryStream]::new(); $previous = 0
        foreach ($event in ($events | Sort-Object Tick, Order)) {
            $delta = $event.Tick - $previous; $previous = $event.Tick
            $vlq = [Collections.Generic.List[byte]]::new(); $vlq.Insert(0, [byte]($delta -band 127)); $delta = $delta -shr 7
            while ($delta -gt 0) { $vlq.Insert(0, [byte](($delta -band 127) -bor 128)); $delta = $delta -shr 7 }
            $track_.Write($vlq.ToArray(), 0, $vlq.Count); $track_.Write($event.Bytes, 0, $event.Bytes.Length)
        }
        $track_.Write([byte[]](0, 0xFF, 0x2F, 0), 0, 4)
        $body = $track_.ToArray(); $big = { param([int] $value, [int] $bytes) [byte[]]@(for ($i = $bytes - 1; $i -ge 0; $i--) { ($value -shr (8 * $i)) -band 255 }) }
        $midiPath = Join-Path $output ([IO.Path]::ChangeExtension((Split-Path -Leaf $recording.Wav), '.mpe.mid'))
        [IO.File]::WriteAllBytes($midiPath, [byte[]]([Text.Encoding]::ASCII.GetBytes('MThd') + (& $big 6 4) + (& $big 0 2) + (& $big 1 2) + (& $big 500 2) + [Text.Encoding]::ASCII.GetBytes('MTrk') + (& $big $body.Length 4) + $body))
        # Native physical recording on the generator clock. MIDI above remains an inspection export.
        $noteAt = [int[]]::new($n); [Array]::Fill($noteAt, -1)
        for ($noteIndex = 0; $noteIndex -lt $notes.Count; $noteIndex++) {
            for ($t = $notes[$noteIndex].First; $t -lt $notes[$noteIndex].Last; $t++) { $noteAt[$t] = $noteIndex }
        }
        $controllerTicks = [int][Math]::Floor(($n * $hop + $window / 2) / 200.0)
        $priorNote = -1; $priorActive = $false
        $controllerEvents = @(for ($tickIndex = 0; $tickIndex -lt $controllerTicks; $tickIndex++) {
            $frame = [int][Math]::Clamp([Math]::Round((200 * $tickIndex + 100 - $window / 2) / $hop), 0, $n - 1)
            $currentNote = $noteAt[$frame]; $active = $db[$frame] -gt $floor
            $buttons = 16; if ($active) { $buttons += 1 }; if ($currentNote -ge 0) { $buttons = $buttons -bor 3 }
            if ($currentNote -ge 0 -and $currentNote -ne $priorNote) { $buttons = $buttons -bor 4 }
            if (-not $active -and $priorActive) { $buttons = $buttons -bor 8 }
            [pscustomobject]@{ PSTypeName = 'Kokoro.StudentControllerEvent'; Tick = $tickIndex; Buttons = $buttons
                PitchHz = $(if ($currentNote -ge 0) { [double]$track[3 * $frame] } else { 0.0 })
                LevelDb = [Math]::Clamp($db[$frame], -96.0, 0.0); Aperiodicity = [Math]::Clamp([double]$track[3 * $frame + 1], 0.0, 1.0)
                Coefficient = 0.0; TiltDb = [double]$tilt[$frame]; TimeSeconds = 0.0
                Occurrence = $(if ($currentNote -ge 0) { $notes[$currentNote].Identity } else { $null }) }
            $priorNote = $currentNote; $priorActive = $active
        })
        $provenance = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProvenance'; Kind = 'Human'; Source = $sourceIdentity; SHA256 = $sourceHash
            PitchMethod = 'YIN normalized difference'; TiltMethod = 'Five octave bands, three projections per band, Hamming weighting, dB/octave regression' }
        $performance = New-StudentControllerRecording $controllerEvents $controllerTicks $provenance 1729
        $performance.Occurrences = $notes.ToArray()
        $controllerPath = Join-Path $output ([IO.Path]::ChangeExtension((Split-Path -Leaf $recording.Wav), '.controller.clixml'))
        $performance | Export-Clixml -LiteralPath $controllerPath
        $rests = @(for ($k = 1; $k -lt $notes.Count; $k++) { 10 * ($notes[$k].First - $notes[$k - 1].Last) }) | Sort-Object
        $f0s = @(foreach ($note in $notes) { for ($t = $note.First; $t -lt $note.Last; $t++) { [double]$track[3 * $t] } }) | Sort-Object
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentListening'; Recording = $recording.Wav; Seconds = $recording.Seconds; Frames = $n
            VoicedShare = [Math]::Round(@($voiced | Where-Object { $_ }).Count / [double]$n, 3); Notes = $notes.Count
            NotesPerSecond = [Math]::Round($notes.Count / $recording.Seconds, 2); MedianF0 = $(if ($f0s.Count) { [Math]::Round($f0s[[int]($f0s.Count / 2)], 1) })
            RestMedianMs = $(if ($rests.Count) { $rests[[int]($rests.Count / 2)] }); RestsOver300Ms = @($rests | Where-Object { $_ -gt 300 }).Count
            Midi = $midiPath; Controller = $performance; ControllerPath = $controllerPath; Occurrences = $notes.ToArray()
            DecodeSeconds = [Math]::Round($decodeSeconds, 1); TrackSeconds = [Math]::Round($trackSeconds, 1); WallSeconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1) }
    }
}

function Publish-StudentPercept($Image, [string] $Identity) {
    if (-not $Image.Percepts.ContainsKey($Identity)) { throw 'Publish needs an existing percept.' }
    $node = $Image.Percepts[$Identity]
    $affected = @($node); if ($null -ne $node.Parent) { $affected += $node.Parent }
    foreach ($percept in $affected) {
        $percept.Revision = [int]$percept.Revision + 1
        if ($Image.Dependents.ContainsKey($percept.Identity)) { foreach ($decisionId in $Image.Dependents[$percept.Identity]) { [void]$Image.Pending.Add([string]$decisionId) } }
    }
    $Image.Changed = $true
}

function Register-StudentDecision($Image, $Decision) {
    foreach ($dependency in $Decision.Dependencies) {
        $dependency = [string]$dependency
        if (-not $Image.Dependents.ContainsKey($dependency)) { $Image.Dependents.Add($dependency, [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)) }
        [void]$Image.Dependents[$dependency].Add([string]$Decision.Identity)
    }
}

function Get-StudentDecisionRevision($Image, $Decision) {
    (@($Decision.Dependencies | Sort-Object) | ForEach-Object {
        $dependencyId = [string]$_; $revision = if ($Image.Percepts.ContainsKey($dependencyId)) { [string]$Image.Percepts[$dependencyId].Revision } else { 'missing' }
        $dependencyId.Length.ToString() + ':' + $dependencyId + ':' + $revision
    }) -join '|'
}

function Invoke-StudentReconsideration($Image) {
    $updated = [Collections.Generic.List[object]]::new()
    foreach ($identity in @($Image.Pending)) {
        $decision = $Image.Decisions[[string]$identity]; $revision = Get-StudentDecisionRevision $Image $decision
        if ($revision -ceq $decision.Revision) { [void]$Image.Pending.Remove([string]$identity); continue }
        $previous = $decision.Current; $current = $null; $savedPin = $Image.Pinned
        try {
            if ($Image.Percepts.ContainsKey($decision.Anchor)) {
                $Image.Pinned = $decision.Anchor
                if ($decision.Kind -ceq 'Acoustic' -and $Image.Evidence.ContainsKey([string]$decision.Context.Evidence)) {
                    $current = Invoke-StudentAcousticProgram $Image ([float[]]$Image.Evidence[[string]$decision.Context.Evidence].Measured.Features)
                } elseif ($decision.Kind -ceq 'Prosody') { $current = Invoke-StudentProsodyProgram $Image $decision.Context }
            }
        } finally { $Image.Pinned = $savedPin }
        $decision.History.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentInterpretationChange'; Previous = $previous; Current = $current
            PreviousRevision = $decision.Revision; Revision = $revision; MachineSHA256 = $script:StudentMachineSHA256 })
        $decision.Current = $current; $decision.Revision = $revision
        $decision.State = if ($null -eq $current) { 'Unresolved' } elseif ($decision.Kind -ceq 'Acoustic') { [string]$current.Status } else { 'AdmittedDirection' }
        [void]$Image.Pending.Remove([string]$identity); $Image.Changed = $true; $updated.Add($decision)
    }
    $updated.ToArray()
}

function New-StudentDecision($Image, [string] $Identity, [string] $Kind, $Context, [string[]] $Dependencies) {
    if (-not $Identity -or $Kind -cnotin 'Acoustic','Prosody' -or $Dependencies.Count -eq 0 -or @($Dependencies | Where-Object { -not $_ }).Count) { throw 'Decide needs a stable identity, supported kind and percept dependencies.' }
    $storedContext = if ($Kind -ceq 'Acoustic') {
        if (-not $Context.PSObject.Properties['Evidence'] -or -not $Context.Evidence) { throw 'Acoustic decisions reference a typed evidence identity.' }
        [pscustomobject]@{ Evidence = [string]$Context.Evidence }
    } else {
        if (-not $Context.PSObject.Properties['BoundaryKind']) { throw 'Prosody decisions need a typed boundary context.' }
        [pscustomobject]@{ BoundaryKind = [string]$Context.BoundaryKind; Style = $(if ($Context.PSObject.Properties['Style']) { [string]$Context.Style } else { $Image.ActiveStyle }) }
    }
    if ($Image.Decisions.ContainsKey($Identity)) {
        $existing = $Image.Decisions[$Identity]
        $sameContext = if ($Kind -ceq 'Acoustic') { $existing.Context.Evidence -ceq $storedContext.Evidence } else {
            $existing.Context.BoundaryKind -ceq $storedContext.BoundaryKind -and $existing.Context.Style -ceq $storedContext.Style
        }
        if ($existing.Kind -cne $Kind -or -not [Linq.Enumerable]::SequenceEqual[string]([string[]]$existing.Dependencies, $Dependencies, [StringComparer]::Ordinal) -or
            -not $sameContext) { throw 'A decision identity cannot be reused for different inputs or dependencies.' }
        $null = Invoke-StudentReconsideration $Image; return $existing
    }
    $decision = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentInterpretation'; Identity = $Identity; Kind = $Kind; Anchor = $Dependencies[0]
        Dependencies = [string[]]$Dependencies.Clone(); Context = $storedContext; Revision = ''; Current = $null; State = 'Unresolved'; History = [Collections.Generic.List[object]]::new() }
    $Image.Decisions.Add($Identity, $decision); Register-StudentDecision $Image $decision; [void]$Image.Pending.Add($Identity)
    $null = Invoke-StudentReconsideration $Image
    $decision
}

function New-StudentImage([string] $Path) {
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentImage'; Owner = $ExecutionContext.SessionState.Module; Path = $Path
        Percepts = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        Evidence = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        Performances = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        Decisions = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        Dependents = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        Pending = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        Pinned = 'Occurrence'; ActiveStyle = ''; Changed = $false }
}

function New-StudentPercept($Image, [string] $Identity, [string] $Kind, [float[]] $Key, $Parent = $null) {
    if ($Image.Percepts.ContainsKey($Identity)) { return $Image.Percepts[$Identity] }
    if (-not $Identity -or -not $Kind -or $Key.Length -eq 0 -or @($Key | Where-Object { -not [float]::IsFinite($_) }).Count) { throw 'Percept identity, kind and finite key are required.' }
    $node = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPercept'; Image = $Image; Identity = $Identity; Kind = $Kind; Key = $Key; Parent = $Parent
        State = 'Candidate'; Revision = 0; Rules = [Collections.Generic.List[object]]::new(); Directions = [Collections.Generic.List[object]]::new()
        Children = [Collections.Generic.List[object]]::new(); Examples = [Collections.Generic.List[object]]::new(); CounterExamples = [Collections.Generic.List[object]]::new()
        Recordings = [Collections.Generic.List[object]]::new(); RecordingEvidence = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        Progression = [Collections.Generic.List[object]]::new(); Genealogy = [Collections.Generic.List[object]]::new() }
    $Image.Percepts.Add($Identity, $node)
    if ($null -ne $Parent) {
        $Parent.Children.Add($node)
        $edge = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProgression'; Kind = 'Specialization'; From = $Parent; To = $node; Admitted = $false }
        $Parent.Progression.Add($edge); $node.Progression.Add($edge)
    }
    $node.Genealogy.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentGenealogy'; Operation = 'Born'; Parent = $(if ($null -ne $Parent) { $Parent.Identity }); Evidence = @(); Step = 'Percepts'; MachineSHA256 = $script:StudentMachineSHA256 })
    $Image.Changed = $true
    Publish-StudentPercept $Image $node.Identity
    $node
}

function Add-StudentImageObservation($Image, [string] $Percept, $Observation, [string] $Role) {
    if ($Role -cnotin 'Example', 'CounterExample') { throw 'Evidence role must be Example or CounterExample.' }
    if (-not $Image.Percepts.ContainsKey($Percept)) { throw 'Observe needs an existing typed percept.' }
    foreach ($field in 'Identity', 'Occurrence', 'Provenance', 'Condition', 'Measured') { if (-not $Observation.PSObject.Properties[$field]) { throw "Observation needs $field." } }
    if (-not $Observation.Identity -or -not $Observation.Occurrence -or -not $Observation.Provenance) { throw 'Observation identity and provenance cannot be empty.' }
    if ($Image.Evidence.ContainsKey($Observation.Identity)) { $evidence = $Image.Evidence[$Observation.Identity] }
    else {
        $evidence = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentEvidence'; Identity = $Observation.Identity; Occurrence = $Observation.Occurrence
            Provenance = $Observation.Provenance; Condition = $Observation.Condition; Measured = $Observation.Measured }
        $Image.Evidence.Add($evidence.Identity, $evidence)
    }
    $node = $Image.Percepts[$Percept]
    $collection = $node.Examples
    if ($Role -ceq 'CounterExample') { $collection = $node.CounterExamples }
    if (-not $collection.Contains($evidence)) { $collection.Add($evidence); Publish-StudentPercept $Image $node.Identity }
    if ($node.Genealogy[0].Evidence.Count -eq 0) { $node.Genealogy[0].Evidence = @($evidence.Identity) }
    $evidence
}

function Get-StudentImageNeighborhood($Image, [float[]] $Key, [int] $Depth = 2) {
    if ($Depth -lt 0 -or -not $Image.Percepts.ContainsKey($Image.Pinned)) { throw 'Invalid pin or graph depth.' }
    $queue = [Collections.Generic.Queue[object]]::new(); $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $queue.Enqueue([pscustomobject]@{ Node = $Image.Percepts[$Image.Pinned]; Depth = 0 })
    $found = @(while ($queue.Count) {
        $entry = $queue.Dequeue(); $node = $entry.Node
        if (-not $seen.Add($node.Identity)) { continue }
        if ($Key.Length -ne $node.Key.Length) { throw 'Likeness keys must have identical dimensions.' }
        $distance = 0.0
        for ($axis = 0; $axis -lt $Key.Length; $axis++) { $difference = [double]$Key[$axis] - $node.Key[$axis]; $distance += $difference * $difference }
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPerceptNeighbor'; Percept = $node; KinDistance = $entry.Depth; LikenessDistance = [Math]::Sqrt($distance) }
        if ($entry.Depth -lt $Depth) {
            if ($null -ne $node.Parent) { $queue.Enqueue([pscustomobject]@{ Node = $node.Parent; Depth = $entry.Depth + 1 }) }
            foreach ($child in $node.Children) { $queue.Enqueue([pscustomobject]@{ Node = $child; Depth = $entry.Depth + 1 }) }
            foreach ($edge in $node.Progression) {
                $related = $edge.To
                if ($edge.To.Identity -ceq $node.Identity) { $related = $edge.From }
                $queue.Enqueue([pscustomobject]@{ Node = $related; Depth = $entry.Depth + 1 })
            }
        }
    })
    $found | Sort-Object LikenessDistance, KinDistance
}

function Get-StudentImageDescription($Image) {
    @($Image.Percepts.Values | Sort-Object Identity | ForEach-Object {
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPerceptDescription'; Identity = $_.Identity; Kind = $_.Kind; State = $_.State
            Parent = $(if ($null -ne $_.Parent) { $_.Parent.Identity }); Examples = $_.Examples.Count; CounterExamples = $_.CounterExamples.Count
            Untested = $_.Examples.Count -gt 0 -and $_.CounterExamples.Count -eq 0; MostlyExceptions = $_.CounterExamples.Count -gt $_.Examples.Count
            Rules = $_.Rules.Count; Recordings = $_.Recordings.Count; Children = $_.Children.Count; Progression = $_.Progression.Count; Genealogy = $_.Genealogy.Count }
    })
}

function Add-StudentProgression($Image, [string] $Kind, [string] $From, [string] $To, [bool] $Admitted = $false) {
    if ($Kind -cnotin 'Prerequisite', 'Specialization' -or $From -ceq $To -or -not $Image.Percepts.ContainsKey($From) -or -not $Image.Percepts.ContainsKey($To)) { throw 'Progression needs a declared kind and two distinct existing percepts.' }
    $source = $Image.Percepts[$From]; $target = $Image.Percepts[$To]
    foreach ($edge in $source.Progression) { if ($edge.Kind -ceq $Kind -and $edge.From.Identity -ceq $From -and $edge.To.Identity -ceq $To) { return $edge } }
    $edge = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProgression'; Kind = $Kind; From = $source; To = $target; Admitted = $Admitted }
    $source.Progression.Add($edge); $target.Progression.Add($edge); $Image.Changed = $true
    $edge
}

function New-StudentAirLayer($Image, [string] $Parent, [string] $Identity, [float[]] $Key, [string[]] $CounterEvidence) {
    if (-not $Image.Percepts.ContainsKey($Parent) -or $Image.Percepts.ContainsKey($Identity) -or $CounterEvidence.Count -eq 0) { throw 'A new attached branch needs its parent and the counter-evidence that caused it.' }
    $parentNode = $Image.Percepts[$Parent]
    foreach ($evidenceIdentity in $CounterEvidence) { if (-not @($parentNode.CounterExamples | Where-Object Identity -CEQ $evidenceIdentity).Count) { throw 'Air-layer evidence must remain on the parent counter-example roots.' } }
    $branch = New-StudentPercept $Image $Identity $parentNode.Kind $Key $parentNode
    $branch.State = 'Attached'
    $branch.Genealogy.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentGenealogy'; Operation = 'AirLayer'; Parent = $Parent; Evidence = $CounterEvidence; Step = 'Percepts'; MachineSHA256 = $script:StudentMachineSHA256 })
    $branch
}

function Save-StudentImage($Image, [string] $Path = '') {
    if (-not $Path) { $Path = $Image.Path }
    if (-not $Path) { throw 'The live image needs a persistence path.' }
    $Path = [IO.Path]::GetFullPath($Path); [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    # Flatten graph references only at the image boundary. The loader reconstructs one shared live object per identity.
    $nodes = @(foreach ($node in $Image.Percepts.Values) {
        [pscustomobject]@{ Identity = $node.Identity; Kind = $node.Kind; Key = $node.Key; State = $node.State; Revision = $node.Revision
            Parent = [string]$(if ($null -ne $node.Parent) { $node.Parent.Identity }); Rules = $node.Rules.ToArray(); Directions = $node.Directions.ToArray()
            Examples = @($node.Examples | ForEach-Object Identity); CounterExamples = @($node.CounterExamples | ForEach-Object Identity)
            Recordings = @($node.Recordings | ForEach-Object { [pscustomobject]@{ Occurrence = $_.Occurrence; Performance = $_.PerformanceIdentity; Evidence = $_.Evidence.Identity } }); Genealogy = $node.Genealogy.ToArray() }
    })
    $seenEdges = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $edges = @(foreach ($node in $Image.Percepts.Values) { foreach ($edge in $node.Progression) {
        $edgeIdentity = '{0}:{1}{2}:{3}{4}:{5}' -f $edge.Kind.Length, $edge.Kind, $edge.From.Identity.Length, $edge.From.Identity, $edge.To.Identity.Length, $edge.To.Identity
        if ($seenEdges.Add($edgeIdentity)) { [pscustomobject]@{ Kind = $edge.Kind; From = $edge.From.Identity; To = $edge.To.Identity; Admitted = $edge.Admitted } }
    } })
    $snapshot = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentImageSnapshot'; Pinned = $Image.Pinned; ActiveStyle = $Image.ActiveStyle; Percepts = $nodes
        Evidence = @($Image.Evidence.Values); Progression = $edges; Performances = @($Image.Performances.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Identity = $_.Key; Performance = $_.Value } })
        Decisions = @($Image.Decisions.Values); Pending = @($Image.Pending) }
    $pending = $Path + '.pending-' + [Guid]::NewGuid().ToString('N')
    $serialized = [Management.Automation.PSSerializer]::Serialize($snapshot, 40)
    $stream = [IO.File]::Open($pending, [IO.FileMode]::CreateNew)
    $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionLevel]::Optimal)
    $writer = [IO.StreamWriter]::new($gzip, [Text.UTF8Encoding]::new($false))
    try { $writer.Write($serialized) } finally { $writer.Dispose() }
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($pending, $Path, ($Path + '.previous')) } else { [IO.File]::Move($pending, $Path) }
    $Image.Path = $Path; $Image.Changed = $false
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentImageCheckpoint'; Path = $Path; SHA256 = (Get-FileHash -LiteralPath $Path).Hash
        Percepts = $Image.Percepts.Count; Evidence = $Image.Evidence.Count; Performances = $Image.Performances.Count }
}

function Open-StudentImage([string] $Path) {
    $image = New-StudentImage $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        $root = New-StudentPercept $image 'Occurrence' 'Occurrence' ([float[]](0, 0, 0, 0))
        $null = New-StudentPercept $image 'Word' 'Word' ([float[]](1, 0, 0, 0)) $root
        $null = New-StudentPercept $image 'Boundary' 'Boundary' ([float[]](0, 1, 0, 0)) $root
        return $image
    }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $compressed = $stream.ReadByte() -eq 31 -and $stream.ReadByte() -eq 139; $stream.Position = 0
        if ($compressed) {
            $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
            $reader = [IO.StreamReader]::new($gzip, [Text.Encoding]::UTF8)
            try { $snapshot = [Management.Automation.PSSerializer]::Deserialize($reader.ReadToEnd()) } finally { $reader.Dispose() }
        } else { $snapshot = Import-Clixml -LiteralPath $Path }
    } finally { $stream.Dispose() }
    if ($snapshot.PSObject.TypeNames -notcontains 'Deserialized.Kokoro.StudentImageSnapshot') { throw 'File is not a Student percept image.' }
    foreach ($saved in $snapshot.Percepts) { $null = New-StudentPercept $image $saved.Identity $saved.Kind ([float[]]$saved.Key) }
    foreach ($saved in $snapshot.Evidence) {
        $restored = ConvertFrom-StudentStored $saved
        if ($image.Evidence.ContainsKey($restored.Identity)) { throw 'Duplicate evidence identity in image.' }
        $image.Evidence.Add($restored.Identity, $restored)
    }
    foreach ($saved in $snapshot.Performances) { $image.Performances.Add($saved.Identity, (Restore-StudentPerformance $saved.Performance)) }
    foreach ($saved in $snapshot.Percepts) {
        $node = $image.Percepts[[string]$saved.Identity]; $node.State = $saved.State
        $parentIdentity = [string]$saved.Parent
        if ($parentIdentity) {
            $parent = $image.Percepts[$parentIdentity]; $node.Parent = $parent; $parent.Children.Add($node)
            $edge = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProgression'; Kind = 'Specialization'; From = $parent; To = $node; Admitted = $false }
            $parent.Progression.Add($edge); $node.Progression.Add($edge)
        }
        foreach ($identity in $saved.Examples) { $node.Examples.Add($image.Evidence[[string]$identity]) }
        foreach ($identity in $saved.CounterExamples) { $node.CounterExamples.Add($image.Evidence[[string]$identity]) }
        foreach ($item in $saved.Rules) { $node.Rules.Add((ConvertFrom-StudentStored $item)) }
        foreach ($item in $saved.Directions) { $node.Directions.Add((ConvertFrom-StudentStored $item)) }
        foreach ($item in $saved.Recordings) {
            $performanceIdentity = [string]$item.Performance
            [void]$node.RecordingEvidence.Add([string]$item.Evidence)
            $node.Recordings.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentOccurrencePerformance'; Occurrence = [string]$item.Occurrence
                PerformanceIdentity = $performanceIdentity; Performance = $image.Performances[$performanceIdentity]; Evidence = $image.Evidence[[string]$item.Evidence] })
        }
        $node.Genealogy.Clear(); foreach ($item in $saved.Genealogy) { $node.Genealogy.Add((ConvertFrom-StudentStored $item)) }
    }
    if ($snapshot.PSObject.Properties['Progression']) {
        foreach ($node in $image.Percepts.Values) { $node.Progression.Clear() }
        foreach ($edge in $snapshot.Progression) { $null = Add-StudentProgression $image $edge.Kind $edge.From $edge.To ([bool]$edge.Admitted) }
    }
    $image.Pinned = [string]$snapshot.Pinned; $image.Changed = $false
    foreach ($saved in $snapshot.Percepts) { if ($saved.PSObject.Properties['Revision']) { $image.Percepts[[string]$saved.Identity].Revision = [int]$saved.Revision } }
    if ($snapshot.PSObject.Properties['Decisions']) {
        foreach ($saved in $snapshot.Decisions) {
            $decision = ConvertFrom-StudentStored $saved; $history = [Collections.Generic.List[object]]::new()
            foreach ($entry in @($decision.History)) { $history.Add($entry) }; $decision.History = $history
            $image.Decisions.Add([string]$decision.Identity, $decision); Register-StudentDecision $image $decision
        }
        foreach ($identity in $snapshot.Pending) { if (-not $image.Decisions.ContainsKey([string]$identity)) { throw 'Pending interpretation has no stored decision.' }; [void]$image.Pending.Add([string]$identity) }
    }
    if ($snapshot.PSObject.Properties['ActiveStyle']) { $image.ActiveStyle = [string]$snapshot.ActiveStyle }
    $image
}

function Restore-StudentPerformance($Performance) {
    # Deserialization already made mutable event objects and preserved their values. Rebind their declared
    # types in place; do not recursively copy every scalar of a recording whenever the image opens.
    if ($Performance.PSObject.TypeNames[0].StartsWith('Deserialized.', [StringComparison]::Ordinal)) { $Performance.PSObject.TypeNames.Insert(0, $Performance.PSObject.TypeNames[0].Substring(13)) }
    $Performance.Layout = ConvertFrom-StudentStored $Performance.Layout
    $Performance.Provenance = ConvertFrom-StudentStored $Performance.Provenance
    foreach ($event in $Performance.Events) {
        if ($event.PSObject.TypeNames[0].StartsWith('Deserialized.', [StringComparison]::Ordinal)) { $event.PSObject.TypeNames.Insert(0, $event.PSObject.TypeNames[0].Substring(13)) }
    }
    if ($Performance.PSObject.Properties['Occurrences']) {
        foreach ($occurrence in $Performance.Occurrences) { if ($occurrence.PSObject.TypeNames[0].StartsWith('Deserialized.', [StringComparison]::Ordinal)) { $occurrence.PSObject.TypeNames.Insert(0, $occurrence.PSObject.TypeNames[0].Substring(13)) } }
    }
    if (-not $Performance.Layout.Contains('TickSeconds') -or $Performance.Layout.TickSeconds -le 0 -or $Performance.Events.Count -eq 0) { throw 'Image performance is missing its controller clock or events.' }
    $Performance
}

function Invoke-StudentPercepts {
    $path = if ($ImagePath) { [IO.Path]::GetFullPath($ImagePath) } else { Join-Path $script:StudentBuild 'student/image.clixml.gz' }
    if ($null -ne $State -and $State.PSObject.TypeNames -contains 'Kokoro.StudentImage') { $State.Owner = $ExecutionContext.SessionState.Module; return $State }
    $image = Open-StudentImage $path
    if ($null -ne $State) {
        if (-not $State.PSObject.Properties['Words'] -or -not $State.PSObject.Properties['NativeRecording']) { throw 'Percepts -State needs a live image or an Alignment result.' }
        $performance = Restore-StudentPerformance (Import-Clixml -LiteralPath $State.NativeRecording)
        $performanceIdentity = $performance.Provenance.SHA256 + ':' + $performance.MachineSHA256
        if (-not $image.Performances.ContainsKey($performanceIdentity)) { $image.Performances.Add($performanceIdentity, $performance); $image.Changed = $true }
        foreach ($word in $State.Words) {
            $observation = [pscustomobject]@{ Identity = $performanceIdentity + ':' + $word.Identity + ':' + $word.StartSeconds.ToString('R', [Globalization.CultureInfo]::InvariantCulture); Occurrence = $word.Identity; Provenance = $word.Reader
                Condition = [pscustomobject]@{ Kind = 'Word'; Book = $word.Book; Token = $word.Token; SourceStart = $word.SourceStart; SourceLength = $word.SourceLength }
                Measured = [pscustomobject]@{ StartSeconds = $word.StartSeconds; EndSeconds = $word.EndSeconds; StartEvidence = $word.StartEvidence; EndEvidence = $word.EndEvidence; StartSnapMs = $word.StartSnapMs; EndSnapMs = $word.EndSnapMs } }
            $evidence = Add-StudentImageObservation $image 'Word' $observation 'Example'
            if ($image.Percepts['Word'].RecordingEvidence.Add($evidence.Identity)) {
                $image.Percepts['Word'].Recordings.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentOccurrencePerformance'; Occurrence = $word.Identity
                    PerformanceIdentity = $performanceIdentity; Performance = $image.Performances[$performanceIdentity]; Evidence = $evidence })
            }
        }
    }
    $image
}

function Add-StudentProsodyCandidates($Image, [string] $Path) {
    if (-not $Path) {
        if ($Image.Percepts.ContainsKey('Prosody.Rule.1')) { return }
        throw 'Learn needs -RulebookPath or KOKORO_PROSODY_RULEBOOK for the initial candidate import.'
    }
    $sourceHash = (Get-FileHash -LiteralPath $Path).Hash; $content = [IO.File]::ReadAllText($Path)
    $entries = @([regex]::Matches($content, '(?ms)^### ([0-9]+)\. ([^\r\n]+)\r?\n(.*?)(?=^### [0-9]+\.|\z)'))
    if ($entries.Count -ne 80) { throw 'The declared prosody rulebook must contain all 80 candidate rules.' }
    foreach ($entry in $entries) {
        $number = [int]$entry.Groups[1].Value; $body = $entry.Groups[3].Value
        $confidence = [regex]::Match($body, '(?m)^Confidence: (High|Medium|Low)\b').Groups[1].Value
        if (-not $confidence) { throw 'Prosody candidate is missing its confidence prior.' }
        $identity = 'Prosody.Rule.' + $number
        $prior = switch ($confidence) { High { 3 }; Medium { 2 }; Low { 1 } }
        $node = New-StudentPercept $Image $identity 'ProsodyRule' ([float[]](0, 1, 0, ($prior / 3.0))) $Image.Percepts['Boundary']
        if (@($node.Rules | Where-Object SourceSHA256 -CEQ $sourceHash).Count) { continue }
        $node.State = 'SeededCandidate'
        $node.Rules.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentProsodyCandidate'; Kind = 'Seeded'; State = 'AwaitingTypedCondition'
            Number = $number; Name = $entry.Groups[2].Value; Confidence = $confidence; PriorSupport = $prior; SourceSHA256 = $sourceHash
            When = [regex]::Match($body, '(?m)^When: ([^\r\n]+)').Groups[1].Value
            Direction = [regex]::Match($body, '(?m)^What happens: ([^\r\n]+)').Groups[1].Value })
        $Image.Changed = $true
    }
}

function Add-StudentBoundaryObservations($Image) {
    $books = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $recordings = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($recording in $Image.Percepts['Word'].Recordings) { $recordings[$recording.Evidence.Identity] = $recording }
    $groups = @($Image.Percepts['Word'].Examples | Group-Object { $_.Provenance.SHA256 })
    foreach ($group in $groups) {
        $ordered = @($group.Group | Sort-Object { $_.Condition.SourceStart }, { $_.Measured.StartSeconds })
        if ($ordered.Count -lt 2) { continue }
        $performance = $recordings[$ordered[0].Identity].Performance
        $pitch = (Expand-StudentController $performance -Projection PitchHz).Frames
        $buttons = (Expand-StudentController $performance -Projection Buttons).Frames
        $tickSeconds = [double]$performance.Layout.TickSeconds
        if (-not $Image.ActiveStyle) { $Image.ActiveStyle = [string]$group.Name }
        for ($occurrenceIndex = 0; $occurrenceIndex + 1 -lt $ordered.Count; $occurrenceIndex++) {
            $current = $ordered[$occurrenceIndex]; $following = $ordered[$occurrenceIndex + 1]
            $identity = $current.Identity + ':boundary:' + $following.Occurrence
            if ($Image.Evidence.ContainsKey($identity)) { continue }
            $bookName = [string]$current.Condition.Book
            if (-not $books.ContainsKey($bookName)) {
                $book = @(Get-StudentBooks -Name $bookName)
                if ($book.Count -ne 1) { throw 'Boundary observation needs the typed source book.' }
                $books.Add($bookName, $book[0])
            }
            $book = $books[$bookName]
            # SAPI's word span can include a trailing punctuation mark. Find its last lexical token;
            # punctuation and paragraph boundaries belong to the typed source, not the voice's span width.
            $sourceEnd = $current.Condition.SourceStart
            $scanToken = [int]$current.Condition.Token
            $labelEnd = $current.Condition.SourceStart + $current.Condition.SourceLength
            while (4 * $scanToken -lt $book.Tokens.Length -and $book.Tokens[4 * $scanToken + 1] -lt $labelEnd) {
                if ($book.Tokens[4 * $scanToken] -in 1, 2, 3) { $sourceEnd = $book.Tokens[4 * $scanToken + 1] + $book.Tokens[4 * $scanToken + 2] }
                $scanToken++
            }
            if ($sourceEnd -eq $current.Condition.SourceStart) { continue }
            if ($following.Condition.SourceStart -lt $sourceEnd) { continue } # more than one spoken object from one source token
            $between = $book.Text.Substring($sourceEnd, $following.Condition.SourceStart - $sourceEnd)
            $boundaryKind = if ($between.Contains("`n")) { 'Paragraph' } elseif ($between.Contains('?')) { 'Question' } elseif ($between.Contains('!')) { 'Exclamation' } elseif ($between.Contains('.')) { 'Stop' } elseif ($between.Contains(';') -or $between.Contains(':')) { 'ColonSemicolon' } elseif ($between.Contains(',')) { 'Comma' } elseif ($between.Contains('—') -or $between.Contains('–')) { 'Dash' } else { 'None' }
            $startTick = [int][Math]::Clamp([Math]::Ceiling($current.Measured.StartSeconds / $tickSeconds), 0, $pitch.Length - 1)
            $endTick = [int][Math]::Clamp([Math]::Floor($current.Measured.EndSeconds / $tickSeconds), 0, $pitch.Length - 1)
            $nextTick = [int][Math]::Clamp([Math]::Ceiling($following.Measured.StartSeconds / $tickSeconds), 0, $pitch.Length - 1)
            $lastPitch = 0.0; $firstPitch = 0.0; $hasRest = $false
            for ($point = $endTick; $point -ge [Math]::Max($startTick, $endTick - 16); $point--) { if ($pitch[$point] -gt 0) { $lastPitch = $pitch[$point]; break } }
            $nextEnd = [int][Math]::Min($pitch.Length - 1, [Math]::Floor($following.Measured.EndSeconds / $tickSeconds))
            for ($point = $nextTick; $point -le [Math]::Min($nextEnd, $nextTick + 16); $point++) { if ($pitch[$point] -gt 0) { $firstPitch = $pitch[$point]; break } }
            for ($point = $endTick + 1; $point -lt $nextTick; $point++) { if (([int]$buttons[$point] -band 1) -eq 0) { $hasRest = $true; break } }
            $paragraph = [Array]::BinarySearch([int[]]$book.Paragraphs, [int]$current.Condition.Token)
            if ($paragraph -lt 0) { $paragraph = -$paragraph - 2 }
            $negative = $paragraph -ge 0 -and $paragraph -lt $book.CounterExample.Length -and $book.CounterExample[$paragraph]
            $observation = [pscustomobject]@{ Identity = $identity; Occurrence = $current.Occurrence + ':following:' + $following.Occurrence; Provenance = $current.Provenance
                Condition = [pscustomobject]@{ Kind = 'Boundary'; BoundaryKind = $boundaryKind; Style = [string]$group.Name; NegativeStructure = $negative }
                Measured = [pscustomobject]@{ PauseSeconds = [Math]::Max(0.0, $following.Measured.StartSeconds - $current.Measured.EndSeconds)
                    HasRest = $hasRest; HasPitch = $lastPitch -gt 0 -and $firstPitch -gt 0
                    PitchResetCents = $(if ($lastPitch -gt 0 -and $firstPitch -gt 0) { 1200 * [Math]::Log($firstPitch / $lastPitch, 2) } else { 0.0 }) } }
            $role = if ($negative) { 'CounterExample' } else { 'Example' }
            $null = Add-StudentImageObservation $Image 'Boundary' $observation $role
        }
    }
}

function Get-StudentProsodyEstimate([object[]] $Evidence, [int] $Prior = 0, [bool] $PriorRest = $false) {
    $pitchEvidence = @($Evidence | Where-Object { $_.Measured.HasPitch })
    $restVotes = @($Evidence | Where-Object { $_.Measured.HasRest }).Count
    [pscustomobject]@{ PauseSeconds = $(if ($Evidence.Count) { ($Evidence | ForEach-Object { $_.Measured.PauseSeconds } | Measure-Object -Average).Average } else { 0.0 })
        PitchResetCents = $(if ($pitchEvidence.Count) { ($pitchEvidence | ForEach-Object { $_.Measured.PitchResetCents } | Measure-Object -Average).Average } else { 0.0 })
        HasRest = (2 * ($restVotes + $(if ($PriorRest) { $Prior } else { 0 }))) -gt $Evidence.Count + $Prior }
}

function Measure-StudentProsodyEstimate([object[]] $Evidence, $Estimate) {
    $pauseError = 0.0; $pitchError = 0.0; $pitchCount = 0; $correct = 0
    foreach ($observation in $Evidence) {
        $pauseError += [Math]::Abs($observation.Measured.PauseSeconds - $Estimate.PauseSeconds)
        if ($observation.Measured.HasPitch) { $pitchError += [Math]::Abs($observation.Measured.PitchResetCents - $Estimate.PitchResetCents); $pitchCount++ }
        if ($observation.Measured.HasRest -eq $Estimate.HasRest) { $correct++ }
    }
    [pscustomobject]@{ Count = $Evidence.Count; PauseErrorMs = $(if ($Evidence.Count) { 1000 * $pauseError / $Evidence.Count } else { 0.0 })
        PitchCount = $pitchCount; PitchErrorCents = $(if ($pitchCount) { $pitchError / $pitchCount } else { 0.0 })
        BoundaryAccuracy = $(if ($Evidence.Count) { $correct / [double]$Evidence.Count } else { 0.0 }) }
}

function Invoke-StudentRuleLearning($Image) {
    $evidence = @($Image.Percepts['Boundary'].Examples) + @($Image.Percepts['Boundary'].CounterExamples)
    $folds = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    foreach ($observation in $evidence) { $folds[$observation.Identity] = [int][Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($observation.Occurrence))[0] % 5 }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($styleGroup in @($evidence | Group-Object { $_.Condition.Style })) {
        $training = @($styleGroup.Group | Where-Object { $folds[$_.Identity] -ne 0 })
        $baseline = Get-StudentProsodyEstimate $training
        foreach ($kindGroup in @($styleGroup.Group | Group-Object { $_.Condition.BoundaryKind })) {
            $train = @($kindGroup.Group | Where-Object { $folds[$_.Identity] -ne 0 }); $heldOut = @($kindGroup.Group | Where-Object { $folds[$_.Identity] -eq 0 })
            if ($train.Count -lt 8 -or $heldOut.Count -lt 4) { continue }
            $sourceRule = switch ($kindGroup.Name) { Paragraph { 31 }; Comma { 21 }; Stop { 2 }; default { 17 } }
            $prior = [int]$Image.Percepts['Prosody.Rule.' + $sourceRule].Rules[-1].PriorSupport
            $estimate = Get-StudentProsodyEstimate $train $prior ($kindGroup.Name -cnotin 'None', 'Comma')
            $referenceScore = Measure-StudentProsodyEstimate $heldOut $baseline
            $candidateScore = Measure-StudentProsodyEstimate $heldOut $estimate
            $pauseAdmitted = $candidateScore.PauseErrorMs -lt $referenceScore.PauseErrorMs
            $pitchAdmitted = $candidateScore.PitchCount -ge 4 -and $candidateScore.PitchErrorCents -lt $referenceScore.PitchErrorCents
            $boundaryAdmitted = $candidateScore.BoundaryAccuracy -gt $referenceScore.BoundaryAccuracy
            $node = New-StudentPercept $Image ('Boundary.' + $kindGroup.Name) 'Boundary' ([float[]](0, 1, 0, 0)) $Image.Percepts['Boundary']
            $identityText = $styleGroup.Name + ':' + $kindGroup.Name + ':' + $train.Count + ':' + $estimate.PauseSeconds.ToString('R', [Globalization.CultureInfo]::InvariantCulture) + ':' + $estimate.PitchResetCents.ToString('R', [Globalization.CultureInfo]::InvariantCulture) + ':' + $estimate.HasRest + ':' + $prior
            $ruleIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identityText)))
            $existing = @($node.Rules | Where-Object { $_.Kind -ceq 'Prosody' -and $_.Style -ceq $styleGroup.Name -and $_.State -ceq 'Admitted' })
            if (@($node.Rules | Where-Object Identity -CEQ $ruleIdentity).Count) { continue }
            $rule = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProsodyProgram'; Kind = 'Prosody'; Identity = $ruleIdentity; Style = [string]$styleGroup.Name; BoundaryKind = [string]$kindGroup.Name
                State = 'Rejected'; PauseSeconds = $estimate.PauseSeconds; PitchResetCents = $estimate.PitchResetCents; HasRest = $estimate.HasRest
                PauseAdmitted = $pauseAdmitted; PitchAdmitted = $pitchAdmitted; BoundaryAdmitted = $boundaryAdmitted
                Fallback = $baseline; TrainingCount = $train.Count; HeldOutCount = $heldOut.Count; BaselineScore = $referenceScore; HeldOutScore = $candidateScore; PriorRule = $sourceRule; PriorSupport = $prior }
            if ($pauseAdmitted -or $pitchAdmitted -or $boundaryAdmitted) {
                $rule.State = 'Admitted'; $node.State = 'Admitted'
                foreach ($old in $existing) {
                    $oldScore = Measure-StudentProsodyEstimate $heldOut $old
                    if (($old.PauseAdmitted -and $oldScore.PauseErrorMs -le $candidateScore.PauseErrorMs) -or ($old.PitchAdmitted -and $oldScore.PitchErrorCents -le $candidateScore.PitchErrorCents)) { $rule.State = 'RetainedExisting'; break }
                }
                if ($rule.State -ceq 'Admitted') { foreach ($old in $existing) { $old.State = 'Superseded' } }
            }
            $node.Rules.Add($rule)
            Publish-StudentPercept $Image $node.Identity
            $node.Genealogy.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentGenealogy'; Operation = $rule.State; Rule = $ruleIdentity; Evidence = @($train.Identity); HeldOut = @($heldOut.Identity); Step = 'Learn' })
            foreach ($observation in $kindGroup.Group) {
                $agreement = [Math]::Abs($observation.Measured.PauseSeconds - $rule.PauseSeconds) -le 0.05
                $prediction = [pscustomobject]@{ Identity = $observation.Identity + ':program:' + $ruleIdentity; Occurrence = $observation.Occurrence; Provenance = $observation.Provenance
                    Condition = [pscustomobject]@{ Rule = $ruleIdentity; BoundaryKind = $kindGroup.Name; Style = $styleGroup.Name }
                    Measured = [pscustomobject]@{ Actual = $observation.Measured; PredictedPauseSeconds = $rule.PauseSeconds; ToleranceSeconds = 0.05; HeldOut = $folds[$observation.Identity] -eq 0 } }
                $null = Add-StudentImageObservation $Image $node.Identity $prediction $(if ($agreement) { 'Example' } else { 'CounterExample' })
            }
            $results.Add($rule); $Image.Changed = $true
        }
    }
    $results.ToArray()
}

function Invoke-StudentProsodyProgram($Image, $Context) {
    if (-not $Context.PSObject.Properties['BoundaryKind']) { throw 'Prosody context needs its typed BoundaryKind.' }
    $style = if ($Context.PSObject.Properties['Style']) { [string]$Context.Style } else { $Image.ActiveStyle }
    foreach ($neighbor in @(Get-StudentImageNeighborhood $Image ([float[]](0,1,0,0)) 1)) {
        foreach ($rule in $neighbor.Percept.Rules) {
            if ($rule.Kind -ceq 'Prosody' -and $rule.State -ceq 'Admitted' -and $rule.Style -ceq $style -and $rule.BoundaryKind -ceq $Context.BoundaryKind) {
                return [pscustomobject]@{ PSTypeName = 'Kokoro.StudentBoundaryAction'; Rule = $rule.Identity
                    PauseSeconds = $(if ($rule.PauseAdmitted) { $rule.PauseSeconds } else { $rule.Fallback.PauseSeconds })
                    PitchResetCents = $(if ($rule.PitchAdmitted) { $rule.PitchResetCents } else { $rule.Fallback.PitchResetCents })
                    HasRest = $(if ($rule.BoundaryAdmitted) { $rule.HasRest } else { $rule.Fallback.HasRest }) }
            }
        }
    }
    $null
}

function Invoke-StudentLearning {
    $image = Invoke-StudentPercepts
    Add-StudentProsodyCandidates $image $RulebookPath
    Add-StudentBoundaryObservations $image
    $programs = @(Invoke-StudentRuleLearning $image)
    $image.Pin('Boundary')
    $null = Invoke-StudentReconsideration $image
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentLearning'; Image = $image; Programs = $programs
        SeededRules = @($image.Percepts.Values | Where-Object Kind -CEQ 'ProsodyRule').Count
        BoundaryObservations = $image.Percepts['Boundary'].Examples.Count + $image.Percepts['Boundary'].CounterExamples.Count
        AdmittedPause = @($programs | Where-Object { $_.State -ceq 'Admitted' -and $_.PauseAdmitted }).Count
        AdmittedPitch = @($programs | Where-Object { $_.State -ceq 'Admitted' -and $_.PitchAdmitted }).Count
        AdmittedBoundary = @($programs | Where-Object { $_.State -ceq 'Admitted' -and $_.BoundaryAdmitted }).Count }
}

Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Learn -Value {
    & $this.Owner { param($Image); $result = Invoke-StudentRuleLearning $Image; $null = Invoke-StudentReconsideration $Image; $result } $this
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Classify -Value {
    param([float[]] $Features)
    & $this.Owner { param($Image, $Values); $null = Invoke-StudentReconsideration $Image; Invoke-StudentAcousticProgram $Image $Values } $this $Features
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName LearnContrast -Value {
    & $this.Owner { param($Image); $result = Update-StudentAcousticProgram $Image; $null = Invoke-StudentReconsideration $Image; $result } $this
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Apply -Value {
    param($Context)
    & $this.Owner { param($Image, $TypedContext); $null = Invoke-StudentReconsideration $Image; Invoke-StudentProsodyProgram $Image $TypedContext } $this $Context
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Decide -Value {
    param([string] $Identity, [string] $Kind, $Context, [string[]] $Dependencies)
    & $this.Owner { param($Image, $DecisionId, $DecisionKind, $DecisionContext, $Required); New-StudentDecision $Image $DecisionId $DecisionKind $DecisionContext $Required } $this $Identity $Kind $Context $Dependencies
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Reconsider -Value {
    & $this.Owner { param($Image); Invoke-StudentReconsideration $Image } $this
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Publish -Value {
    param([string] $Identity)
    & $this.Owner { param($Image, $PerceptId); Publish-StudentPercept $Image $PerceptId } $this $Identity
} -Force

Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Observe -Value {
    param([string] $Percept, $Observation, [string] $Role)
    & $this.Owner { param($Image, $Identity, $Evidence, $EvidenceRole); Add-StudentImageObservation $Image $Identity $Evidence $EvidenceRole } $this $Percept $Observation $Role
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Pin -Value {
    param([string] $Identity)
    if (-not $this.Percepts.ContainsKey($Identity)) { throw 'Cannot pin a missing percept.' }; $this.Pinned = $Identity
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Nearby -Value {
    param([float[]] $Key, [int] $Depth = 2)
    & $this.Owner { param($Image, $Vector, $Reach); Get-StudentImageNeighborhood $Image $Vector $Reach } $this $Key $Depth
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Describe -Value {
    & $this.Owner { param($Image); Get-StudentImageDescription $Image } $this
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Connect -Value {
    param([string] $Kind, [string] $From, [string] $To)
    & $this.Owner { param($Image, $EdgeKind, $Source, $Target); Add-StudentProgression $Image $EdgeKind $Source $Target } $this $Kind $From $To
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName AirLayer -Value {
    param([string] $Parent, [string] $Identity, [float[]] $Key, [string[]] $CounterEvidence)
    & $this.Owner { param($Image, $ParentIdentity, $BranchIdentity, $Vector, $Evidence); New-StudentAirLayer $Image $ParentIdentity $BranchIdentity $Vector $Evidence } $this $Parent $Identity $Key $CounterEvidence
} -Force
Update-TypeData -TypeName 'Kokoro.StudentImage' -MemberType ScriptMethod -MemberName Save -Value {
    param([string] $Path = '')
    & $this.Owner { param($Image, $Destination); Save-StudentImage $Image $Destination } $this $Path
} -Force
Update-TypeData -TypeName 'Kokoro.StudentPercept' -MemberType ScriptMethod -MemberName Observe -Value {
    param($Observation, [string] $Role)
    $this.Image.Observe($this.Identity, $Observation, $Role)
} -Force

# Stage 1, the sound inventory: prosody percepts. Each phone type carries rules for its duration, voicing, pitch and
# energy (N) over typed context (stress, place in the word); the Student's controls drive Kokoro's text encoder and
# decoder, which produce x. Everything is fitted from training occurrences of the cached syllabus evidence and scored
# on held-out occurrences, each in its own domain, by typed novelty.
$script:StudentVowels = 'aeiouæɑɒɔəɚɛɜɪʊʌAIOWYᵊɐɝɘɵ'
$script:StudentStressMarks = 'ˈˌ'
# Voicing at the generator's threshold (SineGen voiced_threshold); pitch is fitted and scored where f0 is clearly
# pitched (the syllabus f0 is continuous and dips toward zero between voiced stretches).
# Phonemes that end a phrase; '$' stands for the end of the evidence.
$script:StudentPhraseMarks = ',.?!;:—…'
$script:StudentVoicedHz = 10.0
$script:StudentPitchedHz = 50.0

function Get-StudentPhoneOccurrences($Windows) {
    # Each phoneme character of each window is a phone occurrence (spaces and punctuation included; the two pads are
    # typed '^' and '$'). An occurrence is identified by its word token and its offset in the word, and is kept from the
    # window where it sits farthest from the window's ends; copies in other windows are marked unused.
    $all = [Collections.Generic.List[object]]::new(); $best = @{}
    foreach ($window in $Windows) {
        $evidence = $window.Evidence; $phonemes = $evidence.Phonemes; $n = $phonemes.Length
        $frameStart = [int[]]::new($evidence.Durations.Length + 1)
        for ($i = 0; $i -lt $evidence.Durations.Length; $i++) { $frameStart[$i + 1] = $frameStart[$i] + $evidence.Durations[$i] }
        $owner = [int[]]::new($n); [Array]::Fill($owner, -1)
        $occurrences = @($window.Occurrences)
        for ($o = 0; $o -lt $occurrences.Count; $o++) { for ($k = 0; $k -lt $occurrences[$o].Phonemes.Length; $k++) { $owner[$occurrences[$o].Start + $k] = $o } }
        for ($i = -1; $i -le $n; $i++) {
            $symbol = if ($i -lt 0) { '^' } elseif ($i -eq $n) { '$' } else { [string]$phonemes[$i] }
            $word = $null; $offset = -1; $wordIndex = -1
            if ($i -ge 0 -and $i -lt $n) {
                $wordIndex = $owner[$i]
                # A space belongs to the word that follows it.
                if ($wordIndex -lt 0) { for ($j = $i + 1; $j -lt $n -and $wordIndex -lt 0; $j++) { $wordIndex = $owner[$j] } }
                if ($wordIndex -ge 0) { $word = $occurrences[$wordIndex]; $offset = $i - $word.Start }
            }
            $stressed = $false
            if ($null -ne $word -and $offset -ge 0 -and $script:StudentVowels.Contains($symbol)) {
                for ($j = $i - 1; $j -ge $word.Start; $j--) {
                    $previous = [string]$phonemes[$j]
                    if ($script:StudentStressMarks.Contains($previous)) { $stressed = $previous -ceq 'ˈ'; break }
                    if ($script:StudentVowels.Contains($previous)) { break }
                }
            }
            # Phrase context: the punctuation that ends this phone's phrase, and its place between phrase boundaries.
            $into = 0; for ($j = $i - 1; $j -ge 0 -and -not $script:StudentPhraseMarks.Contains([string]$phonemes[$j]); $j--) { $into++ }
            $toEnd = 0; $boundary = '$'; for ($j = $i + 1; $j -lt $n; $j++) { if ($script:StudentPhraseMarks.Contains([string]$phonemes[$j])) { $boundary = [string]$phonemes[$j]; break }; $toEnd++ }
            $identity = if ($null -eq $word) { "$($window.Index):$symbol" } else { "$($word.Book):$($word.FirstToken):$offset" }
            $phone = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPhoneOccurrence'; Identity = $identity; Window = $window; Index = $i; Symbol = $symbol
                Stressed = $stressed; Vowel = $script:StudentVowels.Contains($symbol); Word = $word; Offset = $offset
                WordFinal = ($null -ne $word -and $offset -eq $word.Phonemes.Length - 1)
                Previous = $(if ($i -le 0) { '^' } else { [string]$phonemes[$i - 1] }); Next = $(if ($i + 1 -ge $n) { '$' } else { [string]$phonemes[$i + 1] })
                FirstTick = 2 * $frameStart[$i + 1]; Ticks = 2 * $evidence.Durations[$i + 1]
                Margin = [Math]::Min($i + 1, $n - $i); HeldOut = $false; Development = $false; Used = $true; Type = -1
                Boundary = $boundary; IntoPhrase = $into; ToBoundary = $toEnd }
            if ($null -ne $word) {
                $block = [int][Math]::Floor($word.FirstToken / 64) % 8
                $phone.HeldOut = $block -eq 7; $phone.Development = $block -eq 6
            }
            $all.Add($phone)
            if ($null -ne $word) {
                if ($best.ContainsKey($identity)) {
                    if ($best[$identity].Margin -lt $phone.Margin) { $best[$identity].Used = $false; $best[$identity] = $phone } else { $phone.Used = $false }
                } else { $best[$identity] = $phone }
            }
        }
    }
    $all.ToArray()
}

function Get-StudentTypeName($Phone, [bool] $SplitStress) {
    if ($SplitStress -and $Phone.Vowel -and $Phone.Stressed) { return $Phone.Symbol + 'ˈ' }
    $Phone.Symbol
}

# Controls approach their per-tick targets by this fraction per tick (pitch within a voiced run, energy throughout).
$script:StudentControlResponse = 0.5
# Phrasing reach: declination is linear in phones into the phrase up to StudentPhraseReach; the final pitch movement
# covers the last StudentFinalReach phones before a boundary.
$script:StudentPhraseReach = 80
$script:StudentFinalReach = 4

function Test-StudentPhraseFinalWord($Phone) {
    # The phone's word is the last before its phrase boundary (only the separating space between them).
    $null -ne $Phone.Word -and $Phone.Boundary -cne '$' -and $Phone.ToBoundary - ($Phone.Word.Phonemes.Length - 1 - $Phone.Offset) -le 1
}

function Add-StudentPhrasingRules($Rules, [object[]] $Training) {
    # Phrasing, fitted to what the type rules leave: lengthening of the phrase-final word by boundary and vowel class,
    # pitch declination (level and slope in phones into the phrase, capped at StudentPhraseReach), and the pitch of the
    # last StudentFinalReach phones before each kind of boundary.
    $durationSum = @{}; $durationCount = @{}
    $sx = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0; $n = 0
    foreach ($phone in $Training) {
        if (Test-StudentPhraseFinalWord $phone) {
            $key = "$($phone.Boundary)|$($phone.Vowel)"; $residual = [Math]::Log($phone.Ticks / 2 + 1) - $Rules.BaseLogFrames($phone)
            $durationSum[$key] = [double]$durationSum[$key] + $residual; $durationCount[$key] = [int]$durationCount[$key] + 1
        }
        $f0 = $phone.Window.Evidence.F0; $target = $Rules.Targets($phone); $x = [double][Math]::Min($phone.IntoPhrase, $script:StudentPhraseReach)
        for ($t = $phone.FirstTick; $t -lt $phone.FirstTick + $phone.Ticks; $t++) { if ($f0[$t] -ge $script:StudentPitchedHz) { $y = [Math]::Log($f0[$t]) - $target.LogHz; $sx += $x; $sy += $y; $sxx += $x * $x; $sxy += $x * $y; $n++ } }
    }
    foreach ($key in $durationCount.Keys) { if ($durationCount[$key] -ge 20) { $Rules.FinalDuration[$key] = $durationSum[$key] / $durationCount[$key] } }
    if ($n -gt 1) { $Rules.DeclinationSlope = ($n * $sxy - $sx * $sy) / ($n * $sxx - $sx * $sx); $Rules.DeclinationLevel = ($sy - $Rules.DeclinationSlope * $sx) / $n }
    $Rules.Phrasing = $true
    $finalSum = @{}; $finalCount = @{}
    foreach ($phone in $Training) {
        if ($phone.ToBoundary -gt $script:StudentFinalReach -or $phone.Boundary -ceq '$') { continue }
        $f0 = $phone.Window.Evidence.F0; $target = $Rules.Targets($phone)
        for ($t = $phone.FirstTick; $t -lt $phone.FirstTick + $phone.Ticks; $t++) { if ($f0[$t] -ge $script:StudentPitchedHz) { $finalSum[$phone.Boundary] = [double]$finalSum[$phone.Boundary] + [Math]::Log($f0[$t]) - $target.LogHz; $finalCount[$phone.Boundary] = [int]$finalCount[$phone.Boundary] + 1 } }
    }
    foreach ($key in $finalCount.Keys) { if ($finalCount[$key] -ge 20) { $Rules.FinalPitch[$key] = $finalSum[$key] / $finalCount[$key] } }
}

function New-StudentProsodyRules([object[]] $Training, [bool] $SplitStress, [bool] $TypePitch, [bool] $Phrasing = $false) {
    # Per type: duration as the mean of log(frames + 1), the fraction of voiced ticks, the pitch offset from the voice's
    # level (TypePitch) and the mean energy; then word-final and stressed-vowel duration terms and a stressed-vowel pitch
    # term fitted to what the type means leave. Types with no training occurrence fall back to the voice's means.
    $durationSum = @{}; $durationCount = @{}; $voiced = @{}; $ticks = @{}; $pitchSum = @{}; $pitchCount = @{}; $energySum = @{}
    $allDuration = 0.0; $allPitch = 0.0; $allPitchTicks = 0; $allEnergy = 0.0; $allTicks = 0
    foreach ($phone in $Training) {
        $name = Get-StudentTypeName $phone $SplitStress; $frames = $phone.Ticks / 2
        $durationSum[$name] = [double]$durationSum[$name] + [Math]::Log($frames + 1); $durationCount[$name] = [int]$durationCount[$name] + 1; $allDuration += [Math]::Log($frames + 1)
        $f0 = $phone.Window.Evidence.F0; $energy = $phone.Window.Evidence.N
        for ($t = $phone.FirstTick; $t -lt $phone.FirstTick + $phone.Ticks; $t++) {
            $ticks[$name] = [int]$ticks[$name] + 1; $energySum[$name] = [double]$energySum[$name] + $energy[$t]; $allEnergy += $energy[$t]; $allTicks++
            if ($f0[$t] -gt $script:StudentVoicedHz) { $voiced[$name] = [int]$voiced[$name] + 1 }
            if ($f0[$t] -ge $script:StudentPitchedHz) { $pitchSum[$name] = [double]$pitchSum[$name] + [Math]::Log($f0[$t]); $pitchCount[$name] = [int]$pitchCount[$name] + 1; $allPitch += [Math]::Log($f0[$t]); $allPitchTicks++ }
        }
    }
    $voiceLog = $allPitch / $allPitchTicks
    $rules = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProsodyRules'; SplitStress = $SplitStress; TypePitch = $TypePitch
        Duration = @{}; Voiced = @{}; Pitch = @{}; Energy = @{}; MeanDuration = $allDuration / $Training.Count; VoiceLogHz = $voiceLog; MeanEnergy = $allEnergy / $allTicks
        WordFinal = 0.0; Stressed = 0.0; StressedPitch = 0.0
        Phrasing = $false; FinalDuration = @{}; DeclinationLevel = 0.0; DeclinationSlope = 0.0; FinalPitch = @{} }
    foreach ($name in $durationCount.Keys) {
        $rules.Duration[$name] = $durationSum[$name] / $durationCount[$name]
        $rules.Voiced[$name] = [int]$voiced[$name] / [Math]::Max(1, [int]$ticks[$name])
        $rules.Energy[$name] = [double]$energySum[$name] / [Math]::Max(1, [int]$ticks[$name])
        $rules.Pitch[$name] = if ($TypePitch -and [int]$pitchCount[$name] -ge 20) { $pitchSum[$name] / $pitchCount[$name] - $voiceLog } else { 0.0 }
    }
    $mean = { param([scriptblock]$Where, [scriptblock]$Value) $s = 0.0; $n = 0; foreach ($phone in $Training) { if (& $Where $phone) { $s += & $Value $phone; $n++ } }; if ($n) { $s / $n } else { 0.0 } }
    $durationResidual = { param($Phone) [Math]::Log($Phone.Ticks / 2 + 1) - $rules.Duration[(Get-StudentTypeName $Phone $SplitStress)] }
    $rules.WordFinal = & $mean { param($p) $p.WordFinal } $durationResidual
    if (-not $SplitStress) { $rules.Stressed = & $mean { param($p) $p.Vowel -and $p.Stressed } $durationResidual }
    $stressedPitch = 0.0; $stressedTicks = 0
    foreach ($phone in $Training) {
        if (-not ($phone.Vowel -and $phone.Stressed)) { continue }
        $offset = $rules.Pitch[(Get-StudentTypeName $phone $SplitStress)]; $f0 = $phone.Window.Evidence.F0
        for ($t = $phone.FirstTick; $t -lt $phone.FirstTick + $phone.Ticks; $t++) { if ($f0[$t] -ge $script:StudentPitchedHz) { $stressedPitch += [Math]::Log($f0[$t]) - $voiceLog - $offset; $stressedTicks++ } }
    }
    if ($stressedTicks) { $rules.StressedPitch = $stressedPitch / $stressedTicks }
    $rules | Add-Member -MemberType ScriptMethod -Name BaseLogFrames -Value { param($Phone)
        $name = Get-StudentTypeName $Phone $this.SplitStress; $d = if ($this.Duration.ContainsKey($name)) { $this.Duration[$name] } elseif ($this.Duration.ContainsKey($Phone.Symbol)) { $this.Duration[$Phone.Symbol] } else { $this.MeanDuration }
        if ($Phone.WordFinal) { $d += $this.WordFinal }; if ($Phone.Vowel -and $Phone.Stressed) { $d += $this.Stressed }
        $d }
    $rules | Add-Member -MemberType ScriptMethod -Name Frames -Value { param($Phone)
        $d = $this.BaseLogFrames($Phone)
        if ($this.Phrasing -and (Test-StudentPhraseFinalWord $Phone)) { $key = "$($Phone.Boundary)|$($Phone.Vowel)"; if ($this.FinalDuration.ContainsKey($key)) { $d += $this.FinalDuration[$key] } }
        [Math]::Max(0, [int][Math]::Round([Math]::Exp($d) - 1)) }
    $rules | Add-Member -MemberType ScriptMethod -Name Targets -Value { param($Phone)
        # Per-tick targets of one occurrence: voiced, log f0 and energy.
        $name = Get-StudentTypeName $Phone $this.SplitStress; if (-not $this.Duration.ContainsKey($name)) { $name = $Phone.Symbol }
        $known = $this.Duration.ContainsKey($name)
        $logHz = $this.VoiceLogHz + $(if ($known) { [double]$this.Pitch[$name] } else { 0.0 }) + $(if ($Phone.Vowel -and $Phone.Stressed) { $this.StressedPitch } else { 0.0 })
        if ($this.Phrasing) {
            $logHz += $this.DeclinationLevel + $this.DeclinationSlope * [Math]::Min($Phone.IntoPhrase, $script:StudentPhraseReach)
            if ($Phone.ToBoundary -le $script:StudentFinalReach -and $this.FinalPitch.ContainsKey($Phone.Boundary)) { $logHz += $this.FinalPitch[$Phone.Boundary] }
        }
        [pscustomobject]@{ Voiced = $known -and [double]$this.Voiced[$name] -ge 0.5; LogHz = $logHz
            Energy = $(if ($known) { [double]$this.Energy[$name] } else { $this.MeanEnergy }) } }
    if ($Phrasing) { Add-StudentPhrasingRules $rules $Training }
    $rules
}

function Measure-StudentProsody($Rules, [object[]] $Phones) {
    # Per occurrence, with the evidence's own timing: duration error in frames, voicing agreement, pitch error (dB of the
    # f0 ratio) where both are pitched, and energy error.
    foreach ($phone in $Phones) {
        $target = $Rules.Targets($phone); $f0 = $phone.Window.Evidence.F0; $energy = $phone.Window.Evidence.N
        $agree = 0; $pitchSquares = 0.0; $pitchTicks = 0; $energySquares = 0.0
        for ($t = $phone.FirstTick; $t -lt $phone.FirstTick + $phone.Ticks; $t++) {
            if (($f0[$t] -gt $script:StudentVoicedHz) -eq $target.Voiced) { $agree++ }
            if ($f0[$t] -ge $script:StudentPitchedHz -and $target.Voiced) { $d = 20 * ($target.LogHz - [Math]::Log($f0[$t])) / [Math]::Log(10); $pitchSquares += $d * $d; $pitchTicks++ }
            $e = $target.Energy - $energy[$t]; $energySquares += $e * $e
        }
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProsodyScore'; Phone = $phone; Frames = $phone.Ticks / 2; PredictedFrames = $Rules.Frames($phone); Ticks = $phone.Ticks
            VoicingAgree = $agree; PitchSquares = $pitchSquares; PitchTicks = $pitchTicks; EnergySquares = $energySquares }
    }
}

function Get-StudentProsodySummary([object[]] $Scores, [string] $Name) {
    $durationError = 0.0; $agree = 0; $ticks = 0; $pitch = 0.0; $pitchTicks = 0; $energy = 0.0
    foreach ($row in $Scores) { $durationError += [Math]::Abs($row.PredictedFrames - $row.Frames); $agree += $row.VoicingAgree; $ticks += $row.Ticks; $pitch += $row.PitchSquares; $pitchTicks += $row.PitchTicks; $energy += $row.EnergySquares }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProsodyStratum'; Stratum = $Name; Occurrences = $Scores.Count; Ticks = $ticks
        DurationErrorFrames = [Math]::Round($durationError / [Math]::Max(1, $Scores.Count), 2)
        VoicingAgreement = $(if ($ticks) { [Math]::Round($agree / $ticks, 3) } else { $null })
        PitchErrorDb = $(if ($pitchTicks) { [Math]::Round([Math]::Sqrt($pitch / $pitchTicks), 2) } else { $null })
        EnergyRmsError = $(if ($ticks) { [Math]::Round([Math]::Sqrt($energy / $ticks), 3) } else { $null }) }
}

function Invoke-StudentInventory {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $syllabus = Invoke-StudentSyllabus
    $windows = @($syllabus.Windows)
    if (@($windows | Where-Object { $null -eq $_.Evidence.PSObject.Properties['N'] -or $null -eq $_.Evidence.N }).Count) { throw 'Syllabus evidence without N: re-render it (Syllabus step).' }
    $phones = Get-StudentPhoneOccurrences $windows
    $role = { param($Phone) if (-not $Phone.Used -or $null -eq $Phone.Word) { 'Unused' } elseif ($Phone.HeldOut) { 'HeldOut' } elseif ($Phone.Development) { 'Development' } else { 'Training' } }
    $byRole = $phones | Group-Object { & $role $_ } -AsHashTable
    $training = @($byRole['Training']); $development = @($byRole['Development']); $heldOut = @($byRole['HeldOut'])
    # The development occurrences choose whether stressed vowels are their own types (by duration error) and whether
    # types carry their own pitch offset (by pitch error).
    $candidates = foreach ($split in $false, $true) { foreach ($typePitch in $false, $true) { foreach ($phrasing in $false, $true) {
        $rules = New-StudentProsodyRules $training $split $typePitch $phrasing
        [pscustomobject]@{ Rules = $rules; Summary = Get-StudentProsodySummary @(Measure-StudentProsody $rules $development) "Development" }
    } } }
    $bySplit = @($candidates | Group-Object { $_.Rules.SplitStress } | ForEach-Object { [pscustomobject]@{ Split = $_.Group[0].Rules.SplitStress; Error = ($_.Group | Measure-Object { $_.Summary.DurationErrorFrames } -Average).Average } } | Sort-Object Error)[0].Split
    # Within the chosen type set, the candidate with the lowest duration and pitch errors, each relative to its smallest.
    $pool = @($candidates | Where-Object { $_.Rules.SplitStress -eq $bySplit })
    $bestDuration = ($pool | Measure-Object { $_.Summary.DurationErrorFrames } -Minimum).Minimum; $bestPitch = ($pool | Measure-Object { $_.Summary.PitchErrorDb } -Minimum).Minimum
    $chosen = @($pool | Sort-Object { $_.Summary.DurationErrorFrames / $bestDuration + $_.Summary.PitchErrorDb / $bestPitch })[0].Rules
    # Held-out scores, stratified by typed novelty.
    $seenWords = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); $seenContext = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($phone in $training) { $name = Get-StudentTypeName $phone $chosen.SplitStress; $null = $seenWords.Add($phone.Word.Phonemes); $null = $seenContext.Add("$($phone.Previous)|$name|$($phone.Next)") }
    $scores = @(Measure-StudentProsody $chosen $heldOut)
    foreach ($row in $scores) {
        $phone = $row.Phone; $name = Get-StudentTypeName $phone $chosen.SplitStress
        $row | Add-Member -NotePropertyName Novelty -NotePropertyValue $(if (-not $seenWords.Contains($phone.Word.Phonemes)) { 'NewWord' } elseif (-not $seenContext.Contains("$($phone.Previous)|$name|$($phone.Next)")) { 'NewContext' } else { 'SeenContext' })
        $row | Add-Member -NotePropertyName Class -NotePropertyValue $(if ($phone.Symbol -eq ' ') { 'Space' } elseif ($phone.Vowel -and $phone.Stressed) { 'StressedVowel' } elseif ($phone.Vowel) { 'Vowel' } elseif ($script:StudentStressMarks.Contains($phone.Symbol)) { 'StressMark' } elseif ([char]::IsLetter($phone.Symbol, 0)) { 'Consonant' } else { 'Punctuation' })
    }
    $strata = [Collections.Generic.List[object]]::new(); $strata.Add((Get-StudentProsodySummary $scores 'All'))
    foreach ($group in ($scores | Group-Object Novelty | Sort-Object Name)) { $strata.Add((Get-StudentProsodySummary @($group.Group) "Novelty.$($group.Name)")) }
    foreach ($group in ($scores | Group-Object Class | Sort-Object Name)) { $strata.Add((Get-StudentProsodySummary @($group.Group) "Class.$($group.Name)")) }
    foreach ($group in ($scores | Group-Object { if (Test-StudentPhraseFinalWord $_.Phone) { "PhraseFinal.$($_.Phone.Boundary)" } else { 'PhraseInternal' } } | Sort-Object Name)) { $strata.Add((Get-StudentProsodySummary @($group.Group) "Position.$($group.Name)")) }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentInventory'; Voice = $Voice; Corpus = $syllabus.Corpus; Windows = $windows.Count
        PhoneOccurrences = $phones.Count; Training = $training.Count; Development = $development.Count; HeldOut = $heldOut.Count
        Rules = $chosen; Choices = @($candidates | ForEach-Object { [pscustomobject]@{ SplitStress = $_.Rules.SplitStress; TypePitch = $_.Rules.TypePitch; Phrasing = $_.Rules.Phrasing; DurationErrorFrames = $_.Summary.DurationErrorFrames; PitchErrorDb = $_.Summary.PitchErrorDb } })
        Strata = $strata.ToArray(); Seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1); SyllabusWindows = $windows; Phones = $phones }
}

function New-StudentProsodyStream($Rules, [object[]] $Phones) {
    # The controls for phone occurrences in token order (pads included): durations in frames, and f0 and N on the tick
    # clock (two ticks per frame), each approaching its occurrence's target by StudentControlResponse per tick.
    $durations = [int[]]::new($Phones.Count); $frames = 0
    for ($o = 0; $o -lt $Phones.Count; $o++) { $durations[$o] = $Rules.Frames($Phones[$o]); $frames += $durations[$o] }
    $ticks = 2 * $frames; $f0 = [float[]]::new($ticks); $energy = [float[]]::new($ticks)
    $at = 0; $pitch = [double]::NaN; $level = [double]::NaN
    for ($o = 0; $o -lt $Phones.Count; $o++) {
        $target = $Rules.Targets($Phones[$o])
        for ($t = 0; $t -lt 2 * $durations[$o]; $t++) {
            $level = if ([double]::IsNaN($level)) { $target.Energy } else { $level + $script:StudentControlResponse * ($target.Energy - $level) }
            $energy[$at] = [float]$level
            if ($target.Voiced) { $pitch = if ([double]::IsNaN($pitch)) { $target.LogHz } else { $pitch + $script:StudentControlResponse * ($target.LogHz - $pitch) }; $f0[$at] = [float][Math]::Exp($pitch) }
            else { $pitch = [double]::NaN }
            $at++
        }
    }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentProsodyStream'; Durations = $durations; Frames = $frames; F0 = $f0; N = $energy }
}

function Get-StudentOutputPath([string] $StepName) {
    $path = if ($OutputPath) { [IO.Path]::GetFullPath($OutputPath) } else { Join-Path $script:StudentBuild ('student-{0}-{1:yyyyMMddTHHmmss}' -f $StepName.ToLowerInvariant(), [DateTime]::UtcNow) }
    if (-not $path.StartsWith([IO.Path]::GetFullPath($script:StudentBuild) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputPath must be under build/.' }
    [void][IO.Directory]::CreateDirectory($path); $path
}

function Get-StudentTrainingStretches($Inventory, [int] $Ticks, [int] $Limit) {
    # Stretches of Ticks consecutive ticks whose phone occurrences all train (one per window, in window order).
    $found = [Collections.Generic.List[object]]::new(); $byWindow = $Inventory.Phones | Group-Object { $_.Window.Index } -AsHashTable
    foreach ($window in $Inventory.SyllabusWindows) {
        if ($found.Count -ge $Limit) { break }
        $mask = [bool[]]::new($window.Ticks)
        foreach ($phone in @($byWindow[$window.Index])) { if ($phone.Used -and $null -ne $phone.Word -and -not $phone.HeldOut -and -not $phone.Development) { for ($t = $phone.FirstTick; $t -lt $phone.FirstTick + $phone.Ticks; $t++) { $mask[$t] = $true } } }
        $run = 0
        for ($t = 0; $t -lt $window.Ticks; $t++) { if ($mask[$t]) { $run++ } else { $run = 0 }; if ($run -eq $Ticks) { $found.Add([pscustomobject]@{ Window = $window; First = $t - $Ticks + 1 }); break } }
    }
    $found.ToArray()
}

function Invoke-StudentSpeakOnDsp($Inventory, [string] $Phonemes, $Stream, [string] $Out) {
    # The renderer binding in -State (Run -Case student-speech): the voice-base AdaIN constants for the generator (the
    # mean of exported constants over training stretches of syllabus x, cached by their identity), Kokoro's text encoder
    # on the host, then the decoder and the generator on the DSP. Exports run before the one-shot generator render.
    $renderer = $State; $kernels = $null
    $stretches = @(Get-StudentTrainingStretches $Inventory 130 8)
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((@($stretches | ForEach-Object { "$($_.Window.Key):$($_.First)" }) -join "`n") + "`n" + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($renderer.Statistics)))))
    $baseDirectory = Join-Path $script:StudentBuild "student/voice/$Voice"; [void][IO.Directory]::CreateDirectory($baseDirectory)
    $basePath = Join-Path $baseDirectory "adain-base-$key.bin"
    if (Test-Path -LiteralPath $basePath) { $base = [IO.File]::ReadAllBytes($basePath) }
    else {
        $exports = @(foreach ($stretch in $stretches) {
            $window = $stretch.Window; $x = [float[]]::new(512 * 130); for ($c = 0; $c -lt 512; $c++) { [Array]::Copy($window.Evidence.X, $c * $window.Ticks + $stretch.First, $x, $c * 130, 130) }
            $f0 = [float[]]::new(130); [Array]::Copy($window.Evidence.F0, $stretch.First, $f0, 0, 130)
            $renderer.Constants($renderer.EncodeX($x, 130), $f0, 130) })
        $base = $renderer.VoiceBase($exports); [IO.File]::WriteAllBytes($basePath, $base)
    }
    $syllabus = Import-StudentSyllabus (Join-Path $Out 'syllabus')
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $encoded = Invoke-OfflineSpeech -Phonemes $Phonemes -Voice $Voice -SuppliedDurations $Stream.Durations -SuppliedF0 $Stream.F0 -SuppliedN $Stream.N -SkipDecoder
        $encoderSeconds = $watch.Elapsed.TotalSeconds
    }
    finally { Remove-Module -ModuleInfo $syllabus -Force }
    $decoded = $renderer.Decode([float[]]$encoded.Aligned, $Stream.F0, $Stream.N)
    $rendering = $renderer.Render($decoded.XCroutons, $Stream.F0, $decoded.Ticks, $base)
    $wave = Join-Path $Out 'speech-dsp.wav'; [IO.File]::WriteAllBytes($wave, (ConvertTo-StudentWave $rendering.Pcm))
    $seconds = $decoded.Ticks / 80.0
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentSpeech'; Text = $Text; Phonemes = $Phonemes; Voice = $Voice; AudioSeconds = $seconds
        DecoderDspMs = $decoded.DspMs; GeneratorDspMs = $rendering.DspMs; DspTimesRealTime = [Math]::Round(1000 * $seconds / ($decoded.DspMs + $rendering.DspMs), 1)
        HostTextEncoderSeconds = [Math]::Round($encoderSeconds, 2); VoiceBase = $basePath; Wave = $wave; Directory = $Out; MachineSHA256 = $script:StudentMachineSHA256 }
}

function Invoke-StudentSpeak {
    # Text through our phonemizer and the Student's prosody rules into the syllabus port's text encoder, decoder and
    # generator (-SuppliedDurations, -SuppliedF0, -SuppliedN: PL-BERT and the predictor do not run), and the same
    # phonemes through the whole stock pipeline for comparison. Both are written as WAVs.
    if (-not $Text.Trim()) { throw 'Speak needs -Text.' }
    $out = Get-StudentOutputPath 'Speak'
    $inventory = Invoke-StudentInventory
    $phonemize = Import-StudentPhonemizer
    $pronunciation = $phonemize.Invoke($Text)
    if (-not $pronunciation.Complete -or -not $pronunciation.KokoroPhones) { throw 'The phonemizer could not resolve -Text.' }
    $phonemes = [string]$pronunciation.KokoroPhones
    $words = [Collections.Generic.List[object]]::new(); $start = 0; $token = 0
    foreach ($part in $phonemes.Split(' ')) { if ($part.Length) { $words.Add([pscustomobject]@{ Book = 'text'; FirstToken = $token; Kind = 'Word'; Phonemes = $part; Start = $start }); $token++ }; $start += $part.Length + 1 }
    $window = [pscustomobject]@{ Index = -1; Ticks = 0; Occurrences = $words.ToArray(); Evidence = [pscustomobject]@{ Phonemes = $phonemes; Durations = [int[]]::new($phonemes.Length + 2) } }
    $phones = @(Get-StudentPhoneOccurrences @($window))
    $stream = New-StudentProsodyStream $inventory.Rules $phones
    if ($null -ne $State -and $State.PSObject.TypeNames -contains 'Kokoro.SpeechRenderer') { return Invoke-StudentSpeakOnDsp $inventory $phonemes $stream $out }
    $syllabus = Import-StudentSyllabus (Join-Path $out 'syllabus')
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $student = Invoke-OfflineSpeech -Phonemes $phonemes -Voice $Voice -SuppliedDurations $stream.Durations -SuppliedF0 $stream.F0 -SuppliedN $stream.N
        $studentSeconds = $watch.Elapsed.TotalSeconds; $watch.Restart()
        $stock = Invoke-OfflineSpeech -Phonemes $phonemes -Voice $Voice
        $stockSeconds = $watch.Elapsed.TotalSeconds
    }
    finally { Remove-Module -ModuleInfo $syllabus -Force }
    $studentWave = Join-Path $out 'student-prosody.wav'; [IO.File]::WriteAllBytes($studentWave, (ConvertTo-StudentWave $student.Pcm))
    $stockWave = Join-Path $out 'stock.wav'; [IO.File]::WriteAllBytes($stockWave, (ConvertTo-StudentWave $stock.Pcm))
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentSpeech'; Text = $Text; Phonemes = $phonemes; Voice = $Voice
        StudentSeconds = [Math]::Round($stream.Frames / 40.0, 3); StockSeconds = [Math]::Round(([int[]]$stock.Durations | Measure-Object -Sum).Sum / 40.0, 3)
        StudentRenderSeconds = [Math]::Round($studentSeconds, 1); StockRenderSeconds = [Math]::Round($stockSeconds, 1)
        StudentWave = $studentWave; StockWave = $stockWave; Strata = $inventory.Strata; Directory = $out; MachineSHA256 = $script:StudentMachineSHA256 }
}


$script:StudentSteps = [ordered]@{
    Console = { Show-StudentConsole }
    Render = { Invoke-StudentRender }
    Corpus = { Invoke-StudentCorpus }
    Pronunciation = { Invoke-StudentPronunciation }
    Normalize = { Invoke-StudentNormalization }
    Syllabus = { Invoke-StudentSyllabus }
    Recordings = { Invoke-StudentRecordings }
    Listen = { Invoke-StudentListen }
    Stems = { Invoke-StudentStems }
    Alignment = { Invoke-StudentAlignment }
    Percepts = { Invoke-StudentPercepts }
    Describe = { $image = Invoke-StudentPercepts; $image.Describe() }
    Learn = { Invoke-StudentLearning }
    Audit = { Invoke-StudentAlignmentAudit }
    Discriminate = { Invoke-StudentDiscrimination }
    Reconsider = { $image = Invoke-StudentPercepts; $image.Reconsider() }
    Inventory = { Invoke-StudentInventory }
    Speak = { Invoke-StudentSpeak }
}
}
& $studentOwner { & $script:StudentSteps[$Step] }
