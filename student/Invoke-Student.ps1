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
    [ValidateSet('Console', 'Render')][string] $Step = 'Console',
    [ValidateRange(2, 64)][int] $Threads = [Math]::Max(2, [Environment]::ProcessorCount),
    [string] $Text = '',
    [string] $Voice = 'af_heart',
    [ValidateRange(0.5, 2)][double] $Speed = 1
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
}
& $script:StudentSteps[$Step]
