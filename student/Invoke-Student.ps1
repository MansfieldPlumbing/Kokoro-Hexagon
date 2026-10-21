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
            form differs from ours, by word, with recurring symbol differences.
  Normalize Source-aligned front-end decisions for -Text, or replay stored -Corpus decisions as typed behaviours.
  Syllabus   Host syllabus evidence up to the generator boundary for -Voice: per corpus window, the
            lowered syllabus's durations, f0 and x (decoder output), cached by phoneme content under
            build/student/syllabus, and each resolved token span as a typed occurrence with its ticks.
.PARAMETER Corpus
Corpus directory for Pronunciation; defaults to the latest build/corpus-* with corpus.clixml.
.PARAMETER ParagraphLimit
Corpus: read at most this many paragraphs per book (0 reads all).
.PARAMETER WindowLimit
Syllabus: process at most this many windows in corpus order (0 processes all).
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
    [ValidateSet('Console', 'Render', 'Corpus', 'Pronunciation', 'Normalize', 'Syllabus')][string] $Step = 'Console',
    [ValidateRange(2, 64)][int] $Threads = [Math]::Max(2, [Environment]::ProcessorCount),
    [string] $Text = '',
    [string] $Voice = 'af_heart',
    [ValidateRange(0.5, 2)][double] $Speed = 1,
    [string] $Corpus = '',
    [object] $State = $null,
    [switch] $MoreText,
    [string] $SourceIdentity = '',
    [ValidateRange(0, [int]::MaxValue)][int] $ParagraphLimit = 0,
    [ValidateRange(0, [int]::MaxValue)][int] $WindowLimit = 0
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
        Directory = 'build/phonemizer/english/driver/27394F8EE7C83EA37142C313813931AF2D9B4FA2E4679BB200804BA7759D6558-library-dll'
        SHA256 = '865C1DB6C5F0B5A95BED00CD33B6E9859726F0B64376D28FB60152601D3AF226'
    }
    Syllabus = 'tools/Invoke-KokoroPrecomputedDecoder.ps1'
    Manifest = 'lib/manifest.json'
    Text = 'build/grammar-corpus/raw'
    Pronunciation = 'phonemizer/Invoke-EnglishPhonemizer.ps1'
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

function ConvertTo-StudentWave([float[]] $Pcm) {
    # 24 kHz mono PCM16, rounded and saturated.
    $samples = [short[]]::new($Pcm.Length)
    for ($i = 0; $i -lt $Pcm.Length; $i++) { $samples[$i] = [short][Math]::Clamp([Math]::Round([double]$Pcm[$i] * 32768.0), -32768.0, 32767.0) }
    $memory = [IO.MemoryStream]::new(); $writer = [IO.BinaryWriter]::new($memory)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36 + 2 * $samples.Length))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
    $writer.Write([short]1); $writer.Write([short]1); $writer.Write([int]24000); $writer.Write([int]48000)
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
    $directory = Join-Path $script:StudentBuild ('student/kernels/' + (Get-FileHash -LiteralPath $StudentOwnerPath).Hash)
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
        StressFirstVowel = $type.GetMethod('StressFirstVowel').CreateDelegate([Func[string,string,string]]) }
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

function Get-StudentBooks {
    # Each pinned Project Gutenberg book without its header and footer, as one packed record: its
    # paragraphs joined by line feeds, its tokens (starts index that text), the first token of each
    # paragraph, per-paragraph heading and counter-example flags, and its sentence token ranges.
    $kernels = Import-StudentKernels
    $directory = Join-Path $script:StudentRoot $script:StudentInputs.Text
    $index = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter 'pg*.txt' | Sort-Object Name)) {
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
                    Durations = [int[]]$speech.Durations; F0 = [float[]]$speech.F0; X = [float[]]$speech.Features }
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

$script:StudentSteps = [ordered]@{
    Console = { Show-StudentConsole }
    Render = { Invoke-StudentRender }
    Corpus = { Invoke-StudentCorpus }
    Pronunciation = { Invoke-StudentPronunciation }
    Normalize = { Invoke-StudentNormalization }
    Syllabus = { Invoke-StudentSyllabus }
}
}
& $studentOwner { & $script:StudentSteps[$Step] }
