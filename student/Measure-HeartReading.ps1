#requires -Version 7.7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReadingDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ImagePath
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $ReadingDirectory).Path
$output = [IO.Directory]::CreateDirectory($OutputDirectory).FullName
$destination = if ($ImagePath) { (Resolve-Path -LiteralPath $ImagePath).Path }
$methodHash = (Get-FileHash -LiteralPath $PSCommandPath).Hash
$null = . "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition

& $studentOwner {
    param($source, $output, $destination, $methodHash)

    function Read-Transcript($path) {
        $archive = [IO.Compression.ZipFile]::OpenRead($path)
        try {
            $reader = [IO.StreamReader]::new($archive.GetEntry('word/document.xml').Open())
            try { [xml]$document = $reader.ReadToEnd() } finally { $reader.Dispose() }
            foreach ($p in $document.SelectNodes("//*[local-name()='body']/*[local-name()='p']")) {
                $line = (($p.SelectNodes(".//*[local-name()='t']") | ForEach-Object InnerText) -join '') -replace '\s+', ' '
                if ($line.Trim()) { $line.Trim() }
            }
        } finally { $archive.Dispose() }
    }

    function Get-Median([double[]]$values) {
        if (!$values.Count) { return }
        [Array]::Sort($values)
        $middle = $values.Count -shr 1
        if ($values.Count % 2) { $values[$middle] }
        else { ($values[$middle - 1] + $values[$middle]) / 2 }
    }

    $spokenPath = Join-Path $source 'transcript-spoken.docx'
    $taggedPath = Join-Path $source 'transcript-tagged.docx'
    $spoken = @(Read-Transcript $spokenPath)
    $tagged = @(Read-Transcript $taggedPath)
    $tagPattern = '\[(?<Name>[^\[\]]+)\]'
    $clips = @(Get-ChildItem -LiteralPath (Join-Path $source 'paragraphs') -Filter 'paragraph-*.wav')
    if (!$spoken.Count -or $spoken.Count -ne $tagged.Count -or $spoken.Count -ne $clips.Count) {
        throw 'Expected one spoken paragraph, tagged paragraph and clip per reading.'
    }
    $kernels = Import-StudentKernels
    $zira = Import-StudentZira
    $rate = 24000
    $hop = 480
    $window = 600
    $pitchHop = 240
    $pitchWindow = 720
    $status = 'Generated recording, spectral alignment hypothesis, independently unreviewed'
    try {
        $paragraphs = @(for ($p = 0; $p -lt $spoken.Count; $p++) {
            $number = $p + 1
            $content = $spoken[$p]
            $markup = $tagged[$p]
            if ((($markup -replace $tagPattern, '' -replace '\s+', ' ').Trim()) -cne $content) {
                throw "Tagged and spoken text differ in paragraph $number."
            }
            if ($content.Length -gt $script:StudentText.ZiraCharacters) { throw "Paragraph $number exceeds the Zira capture bound." }
            $path = Join-Path $source "paragraphs/paragraph-$number.wav"
            $bytes = [IO.File]::ReadAllBytes($path)
            # The supplied clips use a fixed 44-byte IEEE float WAV header.
            if ($bytes.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'RIFF' -or
                [Text.Encoding]::ASCII.GetString($bytes, 8, 8) -cne 'WAVEfmt ' -or
                [Text.Encoding]::ASCII.GetString($bytes, 36, 4) -cne 'data' -or
                [BitConverter]::ToInt32($bytes, 16) -ne 16 -or [BitConverter]::ToInt16($bytes, 20) -ne 3 -or
                [BitConverter]::ToInt16($bytes, 22) -ne 1 -or [BitConverter]::ToInt32($bytes, 24) -ne $rate -or
                [BitConverter]::ToInt16($bytes, 34) -ne 32 -or ($bytes.Length - 44) % 4 -or
                [BitConverter]::ToInt32($bytes, 40) -ne $bytes.Length - 44) { throw "Unexpected clip format in $path." }
            $audioHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            $signal = [float[]]::new(($bytes.Length - 44) / 4)
            [Buffer]::BlockCopy($bytes, 44, $signal, 0, $bytes.Length - 44)
            $reference = Get-StudentZiraAudio $content $zira
            $native = Read-StudentAudio $reference.Wav
            # Interpolate the 16 kHz reference onto the clip clock before comparing spectral bands.
            $resampled = [float[]]::new([int][Math]::Floor($native.Length * 1.5))
            for ($i = 0; $i -lt $resampled.Length; $i++) {
                $position = $i * (2.0 / 3.0)
                $left = [int][Math]::Floor($position)
                $right = [Math]::Min($left + 1, $native.Length - 1)
                $resampled[$i] = $native[$left] + ($position - $left) * ($native[$right] - $native[$left])
            }
            $refBands = $kernels.SpectralBands.Invoke($resampled, $rate, $hop, $window)
            $clipBands = $kernels.SpectralBands.Invoke($signal, $rate, $hop, $window)
            $map = $kernels.SpectralWarp.Invoke($refBands, $clipBands, 250, 75)
            $alternate = $kernels.SpectralWarp.Invoke($refBands, $clipBands, 125, 25)
            $words = @(foreach ($label in $reference.Capture.Words) {
                $first = [int][Math]::Clamp([Math]::Round(($label.StartSeconds * $rate - $window / 2) / $hop), 0, $map.Length - 1)
                $last = [int][Math]::Clamp([Math]::Round(($label.EndSeconds * $rate - $window / 2) / $hop), $first, $map.Length - 1)
                [pscustomobject]@{
                    Text = $content.Substring($label.Start, $label.Length)
                    Offset = $label.Start
                    Length = $label.Length
                    StartMs = 20 * $map[$first] + 12.5
                    EndMs = 20 * $map[$last] + 12.5
                    StartShiftMs = 20 * [Math]::Abs($map[$first] - $alternate[$first])
                    EndShiftMs = 20 * [Math]::Abs($map[$last] - $alternate[$last])
                    MedianF0Hz = $null
                }
            })
            $positions = @{}
            foreach ($match in [regex]::Matches($markup, $tagPattern)) {
                $offset = (($markup.Substring(0, $match.Index) -replace $tagPattern, '' -replace '\s+', ' ').Trim()).Length
                $index = @($words | Where-Object { $_.Offset + $_.Length -le $offset }).Count
                if (!$positions.ContainsKey($index)) { $positions[$index] = [Collections.Generic.List[string]]::new() }
                $positions[$index].Add($match.Groups['Name'].Value)
            }
            $track = $kernels.PitchTrack.Invoke($signal, $rate, $pitchHop, $pitchWindow, 48, 343, 0.15)
            $frameCount = $track.Length / 3
            $peak = 0.0
            for ($i = 0; $i -lt $frameCount; $i++) { $peak = [Math]::Max($peak, $track[3 * $i + 2]) }
            $floor = $peak * [Math]::Pow(10, -35 / 20.0)
            foreach ($word in $words) {
                $f0 = @(for ($i = [int][Math]::Max(0, [Math]::Ceiling(($word.StartMs - 15) / 10)); $i -lt $frameCount -and 10 * $i + 15 -lt $word.EndMs; $i++) {
                    if ($track[3 * $i] -gt 0 -and $track[3 * $i + 2] -gt $floor) { $track[3 * $i] }
                })
                if ($f0.Count -ge 3) { $word.MedianF0Hz = [Math]::Round((Get-Median $f0), 1) }
            }
            $boundaries = @(for ($i = 0; $i -le $words.Count; $i++) {
                $previous = if ($i -gt 0) { $words[$i - 1] }
                $next = if ($i -lt $words.Count) { $words[$i] }
                $from = if ($previous) { $previous.Offset + $previous.Length } else { 0 }
                $to = if ($next) { $next.Offset } else { $content.Length }
                if ($from -gt $to) { throw "Overlapping reference labels in paragraph $number." }
                $mark = $content.Substring($from, $to - $from).Trim()
                $quiet = 0
                $run = 0
                if ($previous -and $next) {
                    # Include only whole RMS windows inside the estimated interword interval.
                    for ($frame = [int][Math]::Ceiling($previous.EndMs / 10); $frame -lt $frameCount -and 10 * $frame + 30 -le $next.StartMs; $frame++) {
                        if ($track[3 * $frame + 2] -le $floor) { $run++; $quiet = [Math]::Max($quiet, $run) }
                        else { $run = 0 }
                    }
                }
                [pscustomobject]@{
                    Index = $i
                    Tags = @(if ($positions.ContainsKey($i)) { $positions[$i].ToArray() })
                    Mark = $mark
                    Previous = ${previous}?.Text
                    Next = ${next}?.Text
                    StartMs = ${previous}?.EndMs
                    EndMs = ${next}?.StartMs
                    WarpShiftMs = [Math]::Max([double]${previous}?.EndShiftMs, [double]${next}?.StartShiftMs)
                    CollapsedNeighbor = ($previous -and $previous.EndMs -le $previous.StartMs) -or
                        ($next -and $next.EndMs -le $next.StartMs)
                    QuietRmsMs = if ($previous -and $next) { 10 * $quiet }
                    PitchChangeSemitones = if (${previous}?.MedianF0Hz -and ${next}?.MedianF0Hz) {
                        [Math]::Round(12 * [Math]::Log2($next.MedianF0Hz / $previous.MedianF0Hz), 2)
                    }
                }
            })
            [pscustomobject]@{
                Paragraph = $number; File = "paragraphs/paragraph-$number.wav"; AudioSHA256 = $audioHash
                DurationSeconds = $signal.Length / $rate; ReferenceSHA256 = $reference.Capture.AudioSHA256
                Words = $words; Boundaries = $boundaries
            }
        })
    } finally { Remove-Module -ModuleInfo $zira -Force }

    $receipt = [pscustomobject]@{
        Status = $status
        MethodSHA256 = $methodHash
        KernelSHA256 = $kernels.SHA256
        SpokenSHA256 = (Get-FileHash -LiteralPath $spokenPath).Hash
        TaggedSHA256 = (Get-FileHash -LiteralPath $taggedPath).Hash
        Measurement = [pscustomobject]@{
            SampleRate = $rate; SpectralHop = $hop; SpectralWindow = $window
            WarpRadiusFrames = 250; WarpEdgeFrames = 75; AlternateRadiusFrames = 125; AlternateEdgeFrames = 25
            LevelHop = $pitchHop; LevelWindow = $pitchWindow; QuietRelativeToPeakDb = -35; MinimumVoicedFrames = 3
        }
        Paragraphs = $paragraphs
    }
    $receiptPath = Join-Path $output 'heart-reading-alignment.json'
    $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $receiptPath -Encoding utf8
    $receiptHash = (Get-FileHash -LiteralPath $receiptPath).Hash
    if ($destination) {
        $image = Open-StudentImage $destination
        $image.Changed = $false
        $node = New-StudentPercept $image 'Performance.Generated.HeartReading.Alignment' 'RecordingObservation' ([float[]](0,0,0,0)) $image.Percepts['Occurrence']
        foreach ($paragraph in $paragraphs) {
            $observation = [pscustomobject]@{
                Identity = "$($node.Identity)/$receiptHash/$($paragraph.Paragraph)"
                Occurrence = $paragraph.File
                Provenance = "$($paragraph.File) / $($paragraph.AudioSHA256)"
                Condition = $status
                Measured = [pscustomobject]@{
                    ReceiptSHA256 = $receiptHash; SpokenSHA256 = $receipt.SpokenSHA256; TaggedSHA256 = $receipt.TaggedSHA256
                    Alignment = $paragraph
                }
            }
            $null = Add-StudentImageObservation $image $node.Identity $observation Example
        }
        if ($image.Changed) { $null = Save-StudentImage $image $destination }
        $restored = Open-StudentImage $destination
        foreach ($identity in $image.Evidence.Keys) {
            if (!$restored.Evidence.ContainsKey($identity)) { throw "Missing evidence after reload: $identity" }
        }
        [pscustomobject]@{ Image = $destination; SHA256 = (Get-FileHash -LiteralPath $destination).Hash; Evidence = $restored.Evidence.Count }
    }
    [pscustomobject]@{ Receipt = $receiptPath; SHA256 = $receiptHash; Paragraphs = $paragraphs.Count }
} $source $output $destination $methodHash
