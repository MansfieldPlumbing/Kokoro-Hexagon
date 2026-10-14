#requires -Version 7.4
Set-StrictMode -Version Latest

class KokoroProsodySourceCount {
    [string] $Source
    [int] $KeptSentences
    [int] $ExcludedSentences
    [long] $KeptUnits
    [long] $ExcludedUnits
}

class KokoroProsodyBankResult {
    [string] $Binary
    [string] $Manifest
    [long] $Bytes
    [int] $Units
    [int] $Contexts
    [int] $Samples
    [int] $Mismatches
    [KokoroProsodySourceCount[]] $Sources
}

function Read-KokoroProsodyNpy {
    # Offline reader, using the existing bank reader's NPY v1 contract.
    param([IO.Compression.ZipArchive] $Zip, [string] $Name, [string] $Dtype)
    $entry = $Zip.GetEntry("$Name.npy")
    if (-not $entry -or $entry.Length -gt 512MB) { throw "Missing/oversized array: $Name" }
    $stream = $entry.Open(); $memory = [IO.MemoryStream]::new()
    try { $stream.CopyTo($memory); $bytes = $memory.ToArray() }
    finally { $stream.Dispose(); $memory.Dispose() }
    if ($bytes.Length -lt 10 -or [Convert]::ToHexString($bytes, 0, 8) -cne '934E554D50590100') { throw "Expected NPY v1: $Name" }
    $offset = 10 + [BitConverter]::ToUInt16($bytes, 8)
    if ($offset -gt $bytes.Length) { throw "Truncated array: $Name" }
    $header = [Text.Encoding]::ASCII.GetString($bytes, 10, $offset - 10)
    if (-not $header.Contains("'descr': '$Dtype'") -or -not $header.Contains("'fortran_order': False")) { throw "Unexpected layout: $Name" }
    if ($header -notmatch "'shape': \((?<count>[0-9]+),\)") { throw "Expected vector: $Name" }
    $count = [int]$Matches.count
    $width = [int]$Dtype.Substring(2)
    if ([long]$count * $width -ne $bytes.Length - $offset) { throw "Array length mismatch: $Name" }
    [pscustomobject]@{ Bytes = $bytes; Offset = $offset; Count = $count }
}

function Get-KokoroGutenbergSources {
    # Read-only provenance reconstruction from the harvest's original books.
    param([string] $Directory)
    $sources = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($book in (Get-ChildItem -LiteralPath $Directory -Filter '*.raw.txt' -File | Sort-Object Name)) {
        $text = [IO.File]::ReadAllText($book.FullName)
        if (-not $text.Contains('print editions not protected by U.S. copyright')) { continue }
        $start = $text.IndexOf('*** START', [StringComparison]::Ordinal)
        $end = $text.IndexOf('*** END', [StringComparison]::Ordinal)
        if ($start -lt 0 -or $end -le $start) { continue }
        $body = $text.Substring($text.IndexOf("`n", $start) + 1)
        $body = $body.Substring(0, $body.IndexOf('*** END', [StringComparison]::Ordinal))
        foreach ($paragraph in [regex]::Split($body, '\r?\n\s*\r?\n')) {
            $normal = [regex]::Replace($paragraph, '\s+', ' ').Replace('_', '').Replace([char]0x2019, "'").Replace([char]0x201C, '"').Replace([char]0x201D, '"')
            foreach ($sentence in [regex]::Split($normal, '(?<=[.!?])\s+')) {
                $sentence = $sentence.Trim()
                if ($sentence -match "^[A-Z][A-Za-z ,;'\-]+[.!?]$" -and -not $sources.ContainsKey($sentence)) {
                    $sources.Add($sentence, $book.BaseName)
                }
            }
        }
    }
    return , $sources
}

function New-KokoroProsodyBank {
    <# Offline manufacture only. The caller supplies typed text/phoneme arrays from
    the preserved capture order. Runtime consumers need only the binary and PSD1.
    Header: magic/version, units, contexts, records/index/candidates/F0/N offsets.
    Record (24 bytes): left/symbol/right uint16, duration int16, source sentence
    int32, source token int32, contour half-sample offset int64. Context index:
    48-bit ordinal UTF-16 triphone key, candidate start/count (int32 each).
    Candidates retain source order, including original sentence/token identities.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Texts,
        [Parameter(Mandatory)][string[]] $Phonemes,
        [Parameter(Mandatory)][string] $BankDirectory,
        [Parameter(Mandatory)][string] $GutenbergDirectory,
        [Parameter(Mandatory)][string] $OutputDirectory
    )
    if ($Texts.Length -ne $Phonemes.Length -or $Texts.Length -eq 0) { throw 'Capture order length mismatch.' }
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    $build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
    if (-not $output.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'Prosody outputs must be under this worktree build/.' }
    [void][IO.Directory]::CreateDirectory($output)
    $binary = Join-Path $output 'prosody.bin'; $manifest = Join-Path $output 'prosody.psd1'
    if ([IO.File]::Exists($binary) -or [IO.File]::Exists($manifest)) { throw 'Choose a fresh output directory.' }
    $sources = Get-KokoroGutenbergSources $GutenbergDirectory
    $counts = [Collections.Generic.Dictionary[string,KokoroProsodySourceCount]]::new([StringComparer]::Ordinal)
    $keep = [bool[]]::new($Texts.Length); $units = 0L
    for ($s = 0; $s -lt $Texts.Length; $s++) {
        $source = ''; $keep[$s] = $sources.TryGetValue($Texts[$s], [ref]$source)
        if (-not $keep[$s]) { $source = 'Unestablished' }
        if (-not $counts.ContainsKey($source)) { $item = [KokoroProsodySourceCount]::new(); $item.Source = $source; $counts.Add($source, $item) }
        $tokens = $Phonemes[$s].Length + 2
        if ($keep[$s]) { $counts[$source].KeptSentences++; $counts[$source].KeptUnits += $tokens; $units += $tokens }
        else { $counts[$source].ExcludedSentences++; $counts[$source].ExcludedUnits += $tokens }
    }
    if ($units -lt 1000 -or $units -gt [int]::MaxValue) { throw 'Invalid admitted unit count.' }
    $index = [Collections.Generic.Dictionary[long,Collections.Generic.List[int]]]::new()
    $records = [IO.MemoryStream]::new(); $recordWriter = [IO.BinaryWriter]::new($records)
    $pitch = [IO.MemoryStream]::new(); $noise = [IO.MemoryStream]::new()
    $sampleIds = [Collections.Generic.HashSet[int]]::new(); $rng = [Random]::new(1501)
    while ($sampleIds.Count -lt 1000) { [void]$sampleIds.Add($rng.Next([int]$units)) }
    $samples = [Collections.Generic.List[object]]::new()
    $unit = 0; $halfOffset = 0L; $sentenceCount = 0
    try {
        foreach ($chunk in (Get-ChildItem -LiteralPath $BankDirectory -Filter 'chunk-*.npz' -File | Sort-Object Name)) {
            $base = [int]$chunk.BaseName.Substring(6) * 1000
            $zip = [IO.Compression.ZipFile]::OpenRead($chunk.FullName)
            try {
                $dur = Read-KokoroProsodyNpy $zip 'dur' '<i2'
                $f0 = Read-KokoroProsodyNpy $zip 'f0' '<f2'; $nn = Read-KokoroProsodyNpy $zip 'n' '<f2'
                $to = Read-KokoroProsodyNpy $zip 'tok_off' '<i8'; $fo = Read-KokoroProsodyNpy $zip 'frm_off' '<i8'
            } finally { $zip.Dispose() }
            if ($to.Count -ne $fo.Count -or $f0.Count -ne $nn.Count -or $base + $to.Count - 1 -gt $Texts.Length) { throw 'Chunk/order shape mismatch.' }
            for ($local = 0; $local -lt $to.Count - 1; $local++) {
                $s = $base + $local; $sentenceCount++
                if (-not $keep[$s]) { continue }
                $tokens = '<' + $Phonemes[$s] + '>'
                $t0 = [BitConverter]::ToInt64($to.Bytes, $to.Offset + 8 * $local)
                $t1 = [BitConverter]::ToInt64($to.Bytes, $to.Offset + 8 * ($local + 1))
                $frame = [BitConverter]::ToInt64($fo.Bytes, $fo.Offset + 8 * $local)
                $endFrame = [BitConverter]::ToInt64($fo.Bytes, $fo.Offset + 8 * ($local + 1))
                if ($t0 -lt 0 -or $t1 -gt $dur.Count -or $t1 - $t0 -ne $tokens.Length -or $frame -lt 0 -or 2 * $endFrame -gt $f0.Count) { throw 'Invalid sentence offsets.' }
                $contourBytes = [int](4 * ($endFrame - $frame))
                $pitch.Write($f0.Bytes, [int]($f0.Offset + 4 * $frame), $contourBytes)
                $noise.Write($nn.Bytes, [int]($nn.Offset + 4 * $frame), $contourBytes)
                for ($i = 0; $i -lt $tokens.Length; $i++) {
                    $d = [BitConverter]::ToInt16($dur.Bytes, [int]($dur.Offset + 2 * ($t0 + $i)))
                    if ($d -le 0 -or $frame + $d -gt $endFrame) { throw 'Invalid unit duration.' }
                    $left = [char]'#'; $right = [char]'#'
                    if ($i -gt 0) { $left = $tokens[$i - 1] }; if ($i + 1 -lt $tokens.Length) { $right = $tokens[$i + 1] }
                    $key = ([long]$left -shl 32) -bor ([long]$tokens[$i] -shl 16) -bor [long]$right
                    if (-not $index.ContainsKey($key)) { $index.Add($key, [Collections.Generic.List[int]]::new()) }; $index[$key].Add($unit)
                    $recordWriter.Write([uint16]$left); $recordWriter.Write([uint16]$tokens[$i]); $recordWriter.Write([uint16]$right)
                    $recordWriter.Write([short]$d); $recordWriter.Write([int]$s); $recordWriter.Write([int]$i); $recordWriter.Write([long]$halfOffset)
                    if ($sampleIds.Contains($unit)) { $samples.Add([pscustomobject]@{ Unit = $unit; Chunk = $chunk.FullName; Token = $t0 + $i; Frame = $frame; Duration = $d; HalfOffset = $halfOffset }) }
                    $halfOffset += 2 * $d; $frame += $d; $unit++
                }
                if ($frame -ne $endFrame) { throw 'Duration/frame sum mismatch.' }
            }
            Write-Verbose "Packed $($chunk.Name): $unit units"
        }
        if ($sentenceCount -ne $Texts.Length -or $unit -ne $units -or $samples.Count -ne 1000) { throw 'Incomplete bank traversal.' }
        $recordOffset = 128L; $indexOffset = $recordOffset + $records.Length
        $candidateOffset = $indexOffset + 16L * $index.Count
        $f0Offset = $candidateOffset + 4L * $unit; $nOffset = $f0Offset + $pitch.Length
        $file = [IO.File]::Open($binary, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $writer = [IO.BinaryWriter]::new($file)
        try {
            $writer.Write([Text.Encoding]::ASCII.GetBytes('KPROS015')); $writer.Write([int]1); $writer.Write([int]$unit); $writer.Write([int]$index.Count)
            foreach ($offset in @($recordOffset, $indexOffset, $candidateOffset, $f0Offset, $nOffset, $halfOffset)) { $writer.Write([long]$offset) }
            $file.Position = $recordOffset; $records.Position = 0; $records.CopyTo($file)
            $keys = [long[]]@($index.Keys); [Array]::Sort($keys); $candidate = 0
            foreach ($key in $keys) { $writer.Write([long]$key); $writer.Write([int]$candidate); $writer.Write([int]$index[$key].Count); $candidate += $index[$key].Count }
            foreach ($key in $keys) { $values = $index[$key].ToArray(); $bytes = [byte[]]::new(4 * $values.Length); [Buffer]::BlockCopy($values, 0, $bytes, 0, $bytes.Length); $writer.Write($bytes) }
            $pitch.Position = 0; $pitch.CopyTo($file); $noise.Position = 0; $noise.CopyTo($file); $writer.Flush()
            # Independent source reread after serialization. Compare duration and
            # every original float16 byte, rather than converted numeric values.
            foreach ($group in ($samples | Group-Object Chunk)) {
                $zip = [IO.Compression.ZipFile]::OpenRead($group.Name)
                try { $dur = Read-KokoroProsodyNpy $zip 'dur' '<i2'; $f0 = Read-KokoroProsodyNpy $zip 'f0' '<f2'; $nn = Read-KokoroProsodyNpy $zip 'n' '<f2' } finally { $zip.Dispose() }
                foreach ($sample in $group.Group) {
                    $file.Position = $recordOffset + 24L * $sample.Unit + 6
                    $reader = [IO.BinaryReader]::new($file, [Text.Encoding]::UTF8, $true)
                    try { $actual = $reader.ReadInt16() } finally { $reader.Dispose() }
                    if ($actual -ne [BitConverter]::ToInt16($dur.Bytes, [int]($dur.Offset + 2 * $sample.Token))) { throw 'Duration parity failed.' }
                    foreach ($pair in @(@($f0, $f0Offset), @($nn, $nOffset))) {
                        $length = 4 * $sample.Duration; $actualBytes = [byte[]]::new($length)
                        $file.Position = [long]$pair[1] + 2 * $sample.HalfOffset; $file.ReadExactly($actualBytes)
                        $expectedBytes = [byte[]]::new($length); [Buffer]::BlockCopy($pair[0].Bytes, [int]($pair[0].Offset + 4 * $sample.Frame), $expectedBytes, 0, $length)
                        if ([Convert]::ToHexString($actualBytes) -cne [Convert]::ToHexString($expectedBytes)) { throw 'Float16 bit parity failed.' }
                    }
                }
            }
        } finally { $writer.Dispose(); $file.Dispose() }
        $hash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash; $length = (Get-Item -LiteralPath $binary).Length
        $data = [Text.StringBuilder]::new()
        [void]$data.AppendLine('@{').AppendLine("    File = 'prosody.bin'").AppendLine("    SHA256 = '$hash'").AppendLine("    Bytes = $length").AppendLine("    Units = $unit").AppendLine("    Contexts = $($index.Count)").AppendLine('    GateSamples = 1000').AppendLine('    GateMismatches = 0').AppendLine('    GateSeed = 1501').AppendLine('    Sources = @(')
        foreach ($item in ($counts.Values | Sort-Object Source)) {
            [void]$data.AppendLine("        @{ Source = '$($item.Source)'; KeptSentences = $($item.KeptSentences); ExcludedSentences = $($item.ExcludedSentences); KeptUnits = $($item.KeptUnits); ExcludedUnits = $($item.ExcludedUnits) }")
        }
        [void]$data.AppendLine('    )').AppendLine('}')
        [IO.File]::WriteAllText($manifest, $data.ToString(), [Text.UTF8Encoding]::new($false))
        $result = [KokoroProsodyBankResult]::new()
        $result.Binary = $binary; $result.Manifest = $manifest; $result.Bytes = $length
        $result.Units = $unit; $result.Contexts = $index.Count; $result.Samples = 1000; $result.Mismatches = 0
        $result.Sources = [KokoroProsodySourceCount[]]@($counts.Values)
        $result
    } finally { $recordWriter.Dispose(); $records.Dispose(); $pitch.Dispose(); $noise.Dispose() }
}

Export-ModuleMember -Function New-KokoroProsodyBank
