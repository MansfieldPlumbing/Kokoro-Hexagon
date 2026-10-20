<#
.SYNOPSIS
The Student and its host tools: one file of declared records, one shared context and steps.
.DESCRIPTION
Steps:
  Console   Interactive text-to-speech console on the host. Type text, press Enter to render it
            with the lowered teacher (our phonemizer and our port of stock Kokoro), save it as a
            WAV under build/ and play it. Keys: Enter speak, F2 voice, F3/F4 speed, F5 replay,
            F6 toggle playback, Esc quit.
  Render    Render -Text with the lowered teacher to a WAV under build/ and return a typed result.
  Corpus    Pack the pinned Project Gutenberg text into continuous windows of at most 510 phonemes,
            flag counter-example sections, and write pronunciation-audit inputs.
  Pronunciation  Aggregate Zira pronunciation audits (-AuditDetails words.psd1 paths): agreement,
            disagreements by word and recurring symbol substitutions.
.PARAMETER Step
The step to run.
.PARAMETER Text
Text for Render.
.PARAMETER Voice
Voice pack for Render; any voice pinned in lib/manifest.json.
.PARAMETER Speed
Speaking rate for Render.
.PARAMETER Threads
Worker threads for the teacher's kernels.
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
    [ValidateSet('Console', 'Render', 'Corpus', 'Pronunciation')][string] $Step = 'Console',
    [ValidateRange(2, 64)][int] $Threads = [Math]::Max(2, [Environment]::ProcessorCount),
    [string] $Text = '',
    [string] $Voice = 'af_heart',
    [ValidateRange(0.5, 2)][double] $Speed = 1,
    [string[]] $AuditDetails = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StudentRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:StudentBuild = Join-Path $script:StudentRoot 'build'
$script:StudentContext = [ordered]@{
    Teacher = $null          # in-memory module exporting Invoke-OfflineSpeech
    Phonemize = $null        # compiled English phonemizer: Func[string,object]
    Voices = @()
    OutputDirectory = $null
}

# Pinned inputs. The phonemizer is the compiled English driver built by
# phonemizer/Invoke-EnglishPhonemizer.ps1; the teacher is tools/Invoke-KokoroPrecomputedDecoder.ps1.
$script:StudentInputs = [ordered]@{
    Phonemizer = [ordered]@{
        Directory = 'build/phonemizer/english/driver/D7B06FD52B900130E8702544D14BE2F662EC2E009EFCE6B33E3FC92BE8B70AD1-library-dll'
        SHA256 = '112DC0B565042184DF74FA5176F09F6E8294857693B44F0BBED456A43B3FEEF1'
    }
    Teacher = 'tools/Invoke-KokoroPrecomputedDecoder.ps1'
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
    AuditFileBytes = 1000000      # Test-EnglishPronunciationCorpus bounds: 1 MiB and 4096 lines
    AuditFileLines = 4000
    AuditLineCharacters = 8192    # Get-EnglishZiraReference text bound
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
    $assembly.GetType('CoreDriver', $true).GetMethod('Run').CreateDelegate([Func[string,object]])
}

function Import-StudentTeacher([string] $OutputDirectory) {
    # The lowered teacher runs inside its own module scope; only its entry points are exported.
    $reference = Join-Path $script:StudentRoot $script:StudentInputs.Teacher
    New-Module -Name KokoroTeacher -ArgumentList $reference, $OutputDirectory, $Threads -ScriptBlock {
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
        Status = 'Loading the phonemizer and the lowered teacher...'
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
        $script:StudentContext.Teacher = Import-StudentTeacher (Join-Path $script:StudentContext.OutputDirectory 'teacher')
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
        if ($script:StudentContext.Teacher) { Remove-Module -ModuleInfo $script:StudentContext.Teacher -Force }
        [Console]::Out.Write("`e[?25h`e[?1049l")
    }
}

class StudentTextTokenizer {
    # One pass over a paragraph's characters, compiled through PSLowering. Each token is four
    # integers: kind, start, length, flags. Kinds: 1 word, 2 number, 3 ordinal or format word
    # (2d, 12mo), 4 punctuation, 5 quotation mark, 6 symbol, 7 transcriber note. Flags: 1 emphasis
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
    static [int[]] Tokenize([string] $text) {
        $c = $text.ToCharArray(); $n = $c.Length
        $out = [int[]]::new(4 * $n + 4); $count = 0; $flags = 0; $i = 0
        while ($i -lt $n) {
            $code = [int]$c[$i]
            if ([char]::IsWhiteSpace($c[$i])) { $i++; continue }
            if ($code -eq 95) { $flags = $flags -bxor 1; $i++; continue }
            if ($code -eq 91) {
                $close = -1
                for ($j = $i + 1; $j -lt $n -and $j -le $i + 80; $j++) { if ($close -lt 0 -and [int]$c[$j] -eq 93) { $close = $j } }
                if ($close -gt 0 -and [StudentTextTokenizer]::NoteAt($c, $i + 1)) {
                    $out[4 * $count] = 7; $out[4 * $count + 1] = $i; $out[4 * $count + 2] = $close - $i + 1; $out[4 * $count + 3] = $flags; $count++
                    $i = $close + 1; continue
                }
                if ($close -gt 0) { $flags = $flags -bor 2; $i++; continue }
            }
            if ($code -eq 93) { $flags = $flags -band 1; $i++; continue }
            $kind = 6; $j = $i + 1
            if ([char]::IsLetter($c[$i])) {
                $kind = 1
                while ($j -lt $n -and [StudentTextTokenizer]::IsWordChar($c, $j, $i)) { $j++ }
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
            $out[4 * $count] = $kind; $out[4 * $count + 1] = $i; $out[4 * $count + 2] = $j - $i; $out[4 * $count + 3] = $flags; $count++
            $i = $j
        }
        $result = [int[]]::new(4 * $count)
        for ($k = 0; $k -lt 4 * $count; $k++) { $result[$k] = $out[$k] }
        return $result
    }
}

$script:StudentTokenKinds = @{ 1 = 'Word'; 2 = 'Number'; 3 = 'Ordinal'; 4 = 'Punctuation'; 5 = 'Quote'; 6 = 'Symbol'; 7 = 'Note' }
Update-TypeData -TypeName 'Kokoro.StudentToken' -MemberType ScriptProperty -MemberName Spoken -Value { $this.Kind -in 'Word', 'Number', 'Ordinal', 'Punctuation', 'Quote' } -Force
Update-TypeData -TypeName 'Kokoro.StudentToken' -MemberType ScriptProperty -MemberName Projection -Value {
    # The text the phonemizer receives for this token: dashes become an em dash, quotation marks a double quote.
    switch ($this.Kind) { 'Quote' { '"' } 'Punctuation' { if ($this.Text.StartsWith('--')) { '—' } else { $this.Text } } default { $this.Text } }
} -Force

function Import-StudentKernels {
    # Compiles this file's lowered classes once per source hash with the pinned PSLowering.
    if ($script:StudentContext.Contains('Kernels') -and $script:StudentContext.Kernels) { return $script:StudentContext.Kernels }
    $pin = '1afabe056235a570da29e268824784557d4f6cdd'
    $compiler = Join-Path $script:StudentBuild "phonemizer/inputs/pslowering-$pin"
    $pins = @(Import-Csv -LiteralPath (Join-Path $compiler 'verified-source.tsv') -Delimiter "`t")
    foreach ($item in $pins) { if ($item.Commit -cne $pin -or (Get-FileHash -LiteralPath (Join-Path $compiler $item.Path)).Hash -cne $item.Sha256) { throw 'Pinned compiler integrity mismatch.' } }
    Import-Module (Join-Path $compiler 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1')
    $directory = Join-Path $script:StudentBuild ('student/kernels/' + (Get-FileHash -LiteralPath $PSCommandPath).Hash)
    [void][IO.Directory]::CreateDirectory($directory)
    $dll = Join-Path $directory 'Kokoro.Student.dll'
    if (-not (Test-Path -LiteralPath $dll)) { $null = Export-LoweredAssembly -SourcePath $PSCommandPath -ClassName StudentTextTokenizer -OutputPath $dll -Deterministic }
    $admission = Test-LoweredAssembly -AssemblyPath $dll
    if (-not $admission.ClrOnlyAdmitted) { throw 'Student kernels reference SMA.' }
    $assembly = [Reflection.Assembly]::LoadFrom($dll)
    $script:StudentContext.Kernels = [pscustomobject]@{ Tokenize = $assembly.GetType('StudentTextTokenizer', $true).GetMethod('Tokenize').CreateDelegate([Func[string,int[]]]); SHA256 = $admission.SHA256 }
    $script:StudentContext.Kernels
}

function ConvertTo-StudentTokens([string] $Text) {
    $packed = $script:StudentContext.Kernels.Tokenize.Invoke($Text)
    for ($k = 0; $k -lt $packed.Length; $k += 4) {
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentToken'; Kind = $script:StudentTokenKinds[$packed[$k]]; Text = $Text.Substring($packed[$k + 1], $packed[$k + 2])
            Start = $packed[$k + 1]; Length = $packed[$k + 2]; Emphasis = ($packed[$k + 3] -band 1) -ne 0; Editorial = ($packed[$k + 3] -band 2) -ne 0 }
    }
}

function ConvertTo-StudentProjection([object[]] $Tokens) {
    # The string the phonemizer receives, generated from spoken tokens: words separated by spaces,
    # punctuation attached to the preceding token, quotation marks alternating open and close.
    $builder = [Text.StringBuilder]::new(); $open = $false; $attachNext = $true
    foreach ($token in $Tokens) {
        if (-not $token.Spoken) { continue }
        $piece = $token.Projection
        if ($token.Kind -ceq 'Quote') { $open = -not $open; if ($open) { if (-not $attachNext) { [void]$builder.Append(' ') }; [void]$builder.Append($piece); $attachNext = $true } else { [void]$builder.Append($piece); $attachNext = $false }; continue }
        $attach = $attachNext -or ($token.Kind -ceq 'Punctuation' -and $piece -notin '(', '—')
        if (-not $attach) { [void]$builder.Append(' ') }
        [void]$builder.Append($piece); $attachNext = $piece -ceq '('
    }
    $builder.ToString()
}

function Test-StudentCounterExampleHeading([object[]] $Words) {
    # True when the heading's words contain one of the counter-example word sequences.
    $texts = @($Words | ForEach-Object { $_.Text.ToUpperInvariant() })
    foreach ($sequence in $script:StudentText.CounterExampleHeadings) {
        for ($at = 0; $at + $sequence.Count -le $texts.Count; $at++) {
            $match = $true
            for ($k = 0; $k -lt $sequence.Count; $k++) { if ($texts[$at + $k] -cne $sequence[$k]) { $match = $false; break } }
            if ($match) { return $true }
        }
    }
    $false
}

function Get-StudentParagraphs {    # The full text of each pinned Project Gutenberg book in order, without its header and footer,
    # as paragraphs of typed tokens with heading and counter-example flags.
    $null = Import-StudentKernels
    $directory = Join-Path $script:StudentRoot $script:StudentInputs.Text
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter 'pg*.txt' | Sort-Object Name)) {
        $lines = [IO.File]::ReadAllLines($file.FullName)
        $first = -1; $last = $lines.Length
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($first -lt 0 -and $lines[$i].StartsWith('*** START OF', [StringComparison]::Ordinal)) { $first = $i + 1 }
            elseif ($lines[$i].StartsWith('*** END OF', [StringComparison]::Ordinal)) { $last = $i; break }
        }
        if ($first -lt 0) { throw "No Project Gutenberg start marker in $($file.Name)." }
        $paragraph = [Collections.Generic.List[string]]::new(); $counterExample = $false; $index = 0
        for ($i = $first; $i -le $last; $i++) {
            $line = if ($i -lt $last) { $lines[$i].Trim() } else { '' }
            if ($line) { $paragraph.Add($line); continue }
            if ($paragraph.Count -eq 0) { continue }
            $text = $paragraph -join ' '; $paragraph.Clear()
            $tokens = @(ConvertTo-StudentTokens $text)
            $words = @($tokens | Where-Object Kind -ceq 'Word')
            if ($words.Count -eq 0) { continue }
            $heading = $text.Length -le 120 -and -not @($words | Where-Object { $_.Text -cne $_.Text.ToUpperInvariant() }).Count
            if ($heading) { $counterExample = Test-StudentCounterExampleHeading $words }
            [pscustomobject]@{ PSTypeName = 'Kokoro.StudentParagraph'; Book = $file.BaseName; Index = $index; Text = $text; Tokens = $tokens; Heading = $heading; CounterExample = $counterExample }
            $index++
        }
    }
}

function Get-StudentSentences([object] $Paragraph) {
    # Sentence spans over typed tokens: a sentence ends at . ! or ? (with any closing quotation
    # marks) when the next spoken token starts with a capital letter or a digit, or at the paragraph end.
    $tokens = $Paragraph.Tokens; $start = 0
    for ($k = 0; $k -lt $tokens.Count; $k++) {
        if ($tokens[$k].Kind -cne 'Punctuation' -or $tokens[$k].Text -notin '.', '!', '?') { continue }
        $end = $k; while ($end + 1 -lt $tokens.Count -and $tokens[$end + 1].Kind -ceq 'Quote') { $end++ }
        $next = $end + 1; while ($next -lt $tokens.Count -and -not $tokens[$next].Spoken) { $next++ }
        if ($next -lt $tokens.Count -and -not ([char]::IsUpper($tokens[$next].Text[0]) -or [char]::IsDigit($tokens[$next].Text[0]))) { continue }
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentSentence'; Book = $Paragraph.Book; Paragraph = $Paragraph.Index; CounterExample = $Paragraph.CounterExample; Tokens = @($tokens[$start..$end]) }
        $start = $end + 1; $k = $end
    }
    if ($start -lt $tokens.Count) { [pscustomobject]@{ PSTypeName = 'Kokoro.StudentSentence'; Book = $Paragraph.Book; Paragraph = $Paragraph.Index; CounterExample = $Paragraph.CounterExample; Tokens = @($tokens[$start..($tokens.Count - 1)]) } }
}
function Invoke-StudentPhonemize([Func[string,object]] $Phonemize, [string] $Text) {
    # The compiled driver throws on input beyond its internal bounds; that text is unresolved.
    try { $Phonemize.Invoke($Text) } catch { $null }
}

function New-StudentWindows {    # Continuous windows of whole sentences, packed in reading order across sentence and paragraph
    # boundaries (never across books), each at most MaximumPhonemes long after phonemization of the
    # whole window. Window budgets vary over 1..MaximumPhonemes so every voice-pack row is used.
    param([Parameter(Mandatory)][Func[string,object]] $Phonemize, [int] $Seed = 17)
    $random = [Random]::new($Seed)
    $windows = [Collections.Generic.List[object]]::new(); $unresolved = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.List[object]]::new()
    function Close-Window {
        while ($pending.Count -gt 0) {
            $text = ($pending | ForEach-Object Text) -join ' '
            $pronunciation = Invoke-StudentPhonemize $Phonemize $text
            if ($null -ne $pronunciation -and $pronunciation.Complete -and $pronunciation.KokoroPhones -and $pronunciation.KokoroPhones.Length -le $script:StudentText.MaximumPhonemes) {
                $windows.Add([pscustomobject]@{ PSTypeName = 'Kokoro.StudentWindow'; Index = $windows.Count; Book = $pending[0].Book
                    FirstParagraph = $pending[0].Paragraph; LastParagraph = $pending[$pending.Count - 1].Paragraph; Text = $text
                    Phonemes = $pronunciation.KokoroPhones; PhonemeCount = $pronunciation.KokoroPhones.Length; Sentences = $pending.Count
                    CounterExampleSentences = @($pending | Where-Object CounterExample).Count })
                $pending.Clear(); return
            }
            if ($pending.Count -eq 1) { $unresolved.Add($pending[0]); $pending.Clear(); return }
            # The joined window exceeded the limit: close it without its last sentence, carry that one on.
            $carry = $pending[$pending.Count - 1]; $pending.RemoveAt($pending.Count - 1)
            Close-Window; $pending.Add($carry)
        }
    }
    $budget = $random.Next(1, $script:StudentText.MaximumPhonemes + 1); $estimate = 0; $book = ''
    foreach ($paragraph in Get-StudentParagraphs) {
        if ($paragraph.Book -cne $book) { Close-Window; $book = $paragraph.Book; $estimate = 0 }
        foreach ($typed in Get-StudentSentences $paragraph) {
            $sentence = ConvertTo-StudentProjection $typed.Tokens
            if (-not $sentence) { continue }
            $pronunciation = Invoke-StudentPhonemize $Phonemize $sentence
            if ($null -eq $pronunciation -or -not $pronunciation.Complete -or -not $pronunciation.KokoroPhones) {
                Close-Window; $estimate = 0
                $unresolved.Add([pscustomobject]@{ Book = $paragraph.Book; Paragraph = $paragraph.Index; Text = $sentence; CounterExample = $paragraph.CounterExample })
                continue
            }
            $length = $pronunciation.KokoroPhones.Length
            if ($pending.Count -gt 0 -and $estimate + 1 + $length -gt $budget) { Close-Window; $estimate = 0; $budget = $random.Next(1, $script:StudentText.MaximumPhonemes + 1) }
            $pending.Add([pscustomobject]@{ Book = $paragraph.Book; Paragraph = $paragraph.Index; Text = $sentence; CounterExample = $paragraph.CounterExample })
            $estimate += $length + 1
        }
    }
    Close-Window
    [pscustomobject]@{ Windows = $windows.ToArray(); Unresolved = $unresolved.ToArray() }
}

function Invoke-StudentCorpus {
    $output = New-StudentOutputDirectory 'corpus'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = New-StudentWindows -Phonemize (Import-StudentPhonemizer)
    $result.Windows | Export-Clixml -LiteralPath (Join-Path $output 'windows.clixml')
    $result.Unresolved | Export-Clixml -LiteralPath (Join-Path $output 'unresolved.clixml')
    # Pronunciation-audit inputs: one window per line, files within the audit's size bounds.
    $files = [Collections.Generic.List[string]]::new(); $lines = [Collections.Generic.List[string]]::new(); $bytes = 0
    $flush = { if ($lines.Count) { $path = Join-Path $output ('audit-{0:D3}.txt' -f $files.Count); [IO.File]::WriteAllLines($path, [string[]]$lines, [Text.UTF8Encoding]::new($false)); $files.Add($path); $lines.Clear(); $script:auditBytes = 0 } }
    $script:auditBytes = 0
    foreach ($window in $result.Windows) {
        if ($window.Text.Length -gt $script:StudentText.AuditLineCharacters) { continue }
        $size = [Text.Encoding]::UTF8.GetByteCount($window.Text) + 2
        if ($lines.Count -ge $script:StudentText.AuditFileLines -or $script:auditBytes + $size -gt $script:StudentText.AuditFileBytes) { & $flush }
        $lines.Add($window.Text); $script:auditBytes += $size
    }
    & $flush
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentCorpus'; Directory = $output; Windows = $result.Windows.Count; Phonemes = ($result.Windows | Measure-Object PhonemeCount -Sum).Sum
        CounterExampleWindows = @($result.Windows | Where-Object { $_.CounterExampleSentences -gt 0 }).Count; UnresolvedSentences = $result.Unresolved.Count
        AuditFiles = $files.ToArray(); Seconds = $watch.Elapsed.TotalSeconds }
}

function Get-StudentSymbolSubstitutions([string] $Teacher, [string] $Student) {
    # Edit-distance alignment of two symbol strings; returns the substituted, inserted and deleted
    # symbol pairs ('teacher>student', '>student' for insertions, 'teacher>' for deletions).
    $a = $Teacher.ToCharArray(); $b = $Student.ToCharArray()
    $cost = [int[,]]::new($a.Length + 1, $b.Length + 1)
    for ($i = 0; $i -le $a.Length; $i++) { $cost[$i, 0] = $i }
    for ($j = 0; $j -le $b.Length; $j++) { $cost[0, $j] = $j }
    for ($i = 1; $i -le $a.Length; $i++) {
        for ($j = 1; $j -le $b.Length; $j++) {
            $same = if ($a[$i - 1] -ceq $b[$j - 1]) { 0 } else { 1 }
            $cost[$i, $j] = [Math]::Min([Math]::Min($cost[($i - 1), $j] + 1, $cost[$i, ($j - 1)] + 1), $cost[($i - 1), ($j - 1)] + $same)
        }
    }
    $i = $a.Length; $j = $b.Length
    while ($i -gt 0 -or $j -gt 0) {
        if ($i -gt 0 -and $j -gt 0 -and $cost[$i, $j] -eq $cost[($i - 1), ($j - 1)] + $(if ($a[$i - 1] -ceq $b[$j - 1]) { 0 } else { 1 })) {
            if ($a[$i - 1] -cne $b[$j - 1]) { "$($a[$i - 1])>$($b[$j - 1])" }
            $i--; $j--
        }
        elseif ($i -gt 0 -and $cost[$i, $j] -eq $cost[($i - 1), $j] + 1) { "$($a[$i - 1])>"; $i-- }
        else { ">$($b[$j - 1])"; $j-- }
    }
}

function Invoke-StudentPronunciation {
    # Aggregates Zira pronunciation audits (phonemizer -Audit words.psd1 records): agreement,
    # disagreements by word, and symbol substitutions that recur across words.
    param([Parameter(Mandatory)][string[]] $AuditDetails)
    $rows = foreach ($path in $AuditDetails) { (Import-PowerShellDataFile -LiteralPath $path).r }
    $compared = @($rows | Where-Object { $null -ne $_[8] })
    $disagreements = @($compared | Where-Object { -not $_[8] })
    $byWord = $disagreements | Group-Object { '{0}|{1}|{2}' -f $_[1].ToLowerInvariant(), $_[7], ($_[6] -creplace '[ˈˌ]', '') } |
        Sort-Object Count -Descending | ForEach-Object { $w, $zira, $ours = $_.Name.Split('|'); [pscustomobject]@{ Word = $w; Count = $_.Count; Zira = $zira; Ours = $ours } }
    $substitutions = @{}
    foreach ($entry in $byWord) { foreach ($pair in @(Get-StudentSymbolSubstitutions $entry.Zira $entry.Ours)) { $substitutions[$pair] = [int]$substitutions[$pair] + $entry.Count } }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentPronunciation'; Words = @($rows).Count; Compared = $compared.Count
        Agreement = if ($compared.Count) { ($compared.Count - $disagreements.Count) / $compared.Count } else { $null }
        DisagreeingOccurrences = $disagreements.Count; DistinctDisagreements = @($byWord).Count; ByWord = @($byWord)
        Substitutions = @($substitutions.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ Pair = $_.Key; Occurrences = $_.Value } }) }
}

function Invoke-StudentRender {
    if (-not $Text.Trim()) { throw 'Render needs -Text.' }
    $output = New-StudentOutputDirectory 'render'
    $phonemize = Import-StudentPhonemizer
    $voices = @(Get-StudentVoices)
    if ($voices -cnotcontains $Voice) { throw "Voice $Voice is not pinned and present; available: $($voices -join ', ')." }
    $teacher = Import-StudentTeacher (Join-Path $output 'teacher')
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
    finally { Remove-Module -ModuleInfo $teacher -Force }
}

$script:StudentSteps = [ordered]@{
    Console = { Show-StudentConsole }
    Render = { Invoke-StudentRender }
    Corpus = { Invoke-StudentCorpus }
    Pronunciation = { Invoke-StudentPronunciation -AuditDetails $AuditDetails }
}
& $script:StudentSteps[$Step]
