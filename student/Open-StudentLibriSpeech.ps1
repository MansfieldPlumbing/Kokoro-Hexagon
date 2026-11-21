using module ./StudentSourceInventory.psm1
#requires -Version 7.4

param(
    [string] $InventoryPath = (Join-Path $PSScriptRoot '../data/source-bank/sources.bin'),
    [string] $ExtractAudioDirectory,
    [string] $AcousticDirectory,
    [switch] $AlignText
)
$ErrorActionPreference = 'Stop'

class StudentLibriBook {
    [StudentSourceUnit] $Archive
    [int] $GutenbergId
    [string[]] $Editions
}

class StudentLibriChapter {
    [StudentSourceUnit] $Archive
    [int] $Reader
    [int] $Chapter
    [StudentLibriBook] $Book
    [string] $TranscriptMember
    [StudentLibriUtterance[]] $Utterances
}

class StudentLibriUtterance {
    [StudentLibriChapter] $Chapter
    [string] $Id
    [string] $AudioMember
    [string] $AudioHash
    [int] $Rate
    [long] $Samples
    [string] $Transcript
    [int] $RmsHop
    [single[]] $Rms
    [string] $MeasurementKernel
    [string] $MeasurementDecoder
    [Collections.Generic.List[StudentLibriTextAnchor]] $TextAnchors = [Collections.Generic.List[StudentLibriTextAnchor]]::new()
}

class StudentLibriTextAnchor {
    [StudentLibriUtterance] $Utterance
    [string] $ArchiveMember
    [string] $MemberHash
    [int] $Start
    [int] $Length
}

function Read-StudentTar([StudentSourceUnit] $Source, [scriptblock] $Visit) {
    if ((Get-FileHash -LiteralPath $Source.Path).Hash -cne $Source.Checksum) { throw 'LibriSpeech archive checksum changed.' }
    $compressed = [IO.File]::OpenRead($Source.Path)
    try {
        $uncompressed = [IO.Compression.GZipStream]::new($compressed,[IO.Compression.CompressionMode]::Decompress)
        try {
            $tar = [System.Formats.Tar.TarReader]::new($uncompressed)
            try {
                while ($null -ne ($entry = $tar.GetNextEntry())) { & $Visit $entry }
            } finally { $tar.Dispose() }
        } finally { $uncompressed.Dispose() }
    } finally { $compressed.Dispose() }
}

function Read-LibriText($Entry) {
    $reader = [IO.StreamReader]::new($Entry.DataStream,[Text.Encoding]::UTF8,$true,4096,$true)
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

$bank = Open-StudentSourceInventory $InventoryPath
$booksArchive = $bank.Units.get_Item('OpenSLR/12/original-books.tar.gz')
$audioArchive = $bank.Units.get_Item('OpenSLR/12/dev-clean.tar.gz')
$audioDirectory = if ($ExtractAudioDirectory) { [IO.Directory]::CreateDirectory($ExtractAudioDirectory).FullName }
$books = [Collections.Generic.Dictionary[int,StudentLibriBook]]::new()
Read-StudentTar $booksArchive {
    param($entry)
    if (!$entry.DataStream -or $entry.Name -cnotmatch '^LibriSpeech/books/[^/]+/([0-9]+)/[^/]+$') { return }
    $id = [int]$Matches[1]
    if (!$books.ContainsKey($id)) {
        $unit = [StudentLibriBook]::new()
        $unit.Archive = $booksArchive
        $unit.GutenbergId = $id
        $books.Add($id,$unit)
    }
    $books[$id].Editions += $entry.Name
}

$chapters = [Collections.Generic.Dictionary[int,StudentLibriChapter]]::new()
$chapterBooks = [Collections.Generic.Dictionary[int,int]]::new()
$utterances = [Collections.Generic.Dictionary[string,StudentLibriUtterance]]::new([StringComparer]::Ordinal)
$transcripts = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
Read-StudentTar $audioArchive {
    param($entry)
    if (!$entry.DataStream) { return }
    if ($entry.Name -ceq 'LibriSpeech/CHAPTERS.TXT') {
        foreach ($line in (Read-LibriText $entry) -split '\r?\n') {
            if (!$line -or $line.StartsWith(';')) { continue }
            $parts = $line.Split('|')
            if ($parts.Count -ge 6 -and $parts[3].Trim() -ceq 'dev-clean') {
                $chapterBooks.Add([int]$parts[0],[int]$parts[5])
            }
        }
        return
    }
    if ($entry.Name -cnotmatch '^LibriSpeech/dev-clean/(?<reader>[0-9]+)/(?<chapter>[0-9]+)/(?<name>[^/]+)$') { return }
    $chapterId = [int]$Matches.chapter
    $name = $Matches.name
    if (!$chapters.ContainsKey($chapterId)) {
        $chapter = [StudentLibriChapter]::new()
        $chapter.Archive = $audioArchive
        $chapter.Reader = [int]$Matches.reader
        $chapter.Chapter = $chapterId
        $chapters.Add($chapterId,$chapter)
    }
    $chapter = $chapters[$chapterId]
    if ($name.EndsWith('.trans.txt',[StringComparison]::Ordinal)) {
        $chapter.TranscriptMember = $entry.Name
        foreach ($line in (Read-LibriText $entry) -split '\r?\n') {
            if (!$line) { continue }
            $space = $line.IndexOf(' ')
            if ($space -lt 1) { throw 'Malformed original transcript line.' }
            $transcripts.Add($line.Substring(0,$space),$line.Substring($space+1))
        }
    } elseif ($name.EndsWith('.flac',[StringComparison]::Ordinal)) {
        $extractionHash = ''
        if ($audioDirectory) {
            if ($name -cnotmatch '^[0-9]+-[0-9]+-[0-9]+\.flac$') { throw 'Unexpected utterance member name.' }
            $place = Join-Path $audioDirectory $name
            if (Test-Path -LiteralPath $place) {
                $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entry.DataStream))
                if ((Get-FileHash -LiteralPath $place).Hash -cne $expected) { throw 'Extracted utterance checksum mismatch.' }
                $extractionHash = $expected
            } else {
                $temporary = "$place.$([guid]::NewGuid()).partial"
                try {
                    $stream = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew)
                    try { $entry.DataStream.CopyTo($stream) } finally { $stream.Dispose() }
                    [IO.File]::Move($temporary,$place)
                } finally { [IO.File]::Delete($temporary) }
                $extractionHash = (Get-FileHash -LiteralPath $place).Hash
            }
            if ((Get-Item -LiteralPath $place).Length -ne $entry.Length) { throw 'Extracted utterance length mismatch.' }
            $stream = [IO.File]::OpenRead($place)
            try { $clock = Read-StudentFlacClock $stream } finally { $stream.Dispose() }
        } else { $clock = Read-StudentFlacClock $entry.DataStream }
        $utterance = [StudentLibriUtterance]::new()
        $utterance.Chapter = $chapter
        $utterance.Id = [IO.Path]::GetFileNameWithoutExtension($name)
        $utterance.AudioMember = $entry.Name
        $utterance.AudioHash = $extractionHash
        $utterance.Rate = $clock.Item1
        $utterance.Samples = $clock.Item3
        if ($utterance.Rate -le 0 -or $clock.Item2 -ne 1 -or $utterance.Samples -le 0) { throw 'Invalid LibriSpeech clock.' }
        $utterances.Add($utterance.Id,$utterance)
    }
}

foreach ($chapter in $chapters.Values) {
    if ($chapterBooks.ContainsKey($chapter.Chapter)) {
        $book = $null
        if ($books.TryGetValue($chapterBooks[$chapter.Chapter],[ref]$book)) { $chapter.Book = $book }
    }
}
foreach ($group in $utterances.Values | Group-Object { $_.Chapter.Chapter }) {
    $members = [StudentLibriUtterance[]]@($group.Group | Sort-Object Id)
    foreach ($member in $members) {
        if ($transcripts.ContainsKey($member.Id)) { $member.Transcript = $transcripts[$member.Id] }
    }
    $members[0].Chapter.Utterances = $members
    if (!$AcousticDirectory) { continue }
    $measurementPath = Join-Path $AcousticDirectory "$($members[0].Chapter.Chapter).bin"
    if (!(Test-Path -LiteralPath $measurementPath)) { continue }
    $r = [IO.BinaryReader]::new([IO.File]::OpenRead($measurementPath))
    try {
        if ($r.ReadString() -cne 'StudentLibriNativeRms/1' -or $r.ReadString() -cne $audioArchive.Checksum) {
            throw 'Native acoustic evidence is on a different archive revision.'
        }
        $kernel = $r.ReadString()
        $decoder = $r.ReadString()
        foreach ($member in $members) {
            if ($r.ReadString() -cne $member.Id) { throw 'Native evidence utterance order differs.' }
            $member.AudioHash = $r.ReadString()
            $member.MeasurementKernel = $kernel
            $member.MeasurementDecoder = $decoder
            $member.RmsHop = $r.ReadInt32()
            $count = $r.ReadInt32()
            if ($member.RmsHop -le 0 -or $count -ne [Math]::Floor($member.Samples/[double]$member.RmsHop)) {
                throw 'Invalid utterance RMS coverage.'
            }
            $bytes = $r.ReadBytes(4*$count)
            if ($bytes.Length -ne 4*$count) { throw 'Incomplete utterance RMS buffer.' }
            $member.Rms = [single[]]::new($count)
            [Buffer]::BlockCopy($bytes,0,$member.Rms,0,$bytes.Length)
        }
        if ($r.BaseStream.Position -ne $r.BaseStream.Length) { throw 'Trailing LibriSpeech evidence.' }
    } finally { $r.Dispose() }
}
if ($AlignText) {
    $bookUtterances=[Collections.Generic.Dictionary[int,Collections.Generic.List[StudentLibriUtterance]]]::new()
    foreach ($chapter in $chapters.Values) {
        if (!$chapter.Book -or !$chapter.Utterances) { continue }
        $id=$chapter.Book.GutenbergId
        if (!$bookUtterances.ContainsKey($id)) { $bookUtterances.Add($id,[Collections.Generic.List[StudentLibriUtterance]]::new()) }
        $bookUtterances[$id].AddRange($chapter.Utterances)
    }
    Read-StudentTar $booksArchive {
        param($entry)
        if (!$entry.DataStream -or $entry.Name -cnotmatch '^LibriSpeech/books/[^/]+/([0-9]+)/[^/]+$') { return }
        $id=[int]$Matches[1]
        if (!$bookUtterances.ContainsKey($id)) { return }
        $bytes=[byte[]]::new($entry.Length)
        $entry.DataStream.ReadExactly($bytes)
        try { $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes) }
        catch [Text.DecoderFallbackException] { return }
        if ($text.Length -and $text[0] -eq [char]0xFEFF) { $text=$text.Substring(1) }
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        $first=[Collections.Generic.Dictionary[string,Collections.Generic.List[StudentLibriUtterance]]]::new([StringComparer]::Ordinal)
        $utteranceWords=[Collections.Generic.Dictionary[string,string[]]]::new([StringComparer]::Ordinal)
        foreach ($item in $bookUtterances[$id]) {
            if (!$item.Transcript) { continue }
            $words=$item.Transcript.Split(' ',[StringSplitOptions]::RemoveEmptyEntries)
            if (!$first.ContainsKey($words[0])) { $first.Add($words[0],[Collections.Generic.List[StudentLibriUtterance]]::new()) }
            $first[$words[0]].Add($item)
            $utteranceWords.Add($item.Id,$words)
        }
        $lexemes=[regex]::Matches($text,"[\p{L}\p{Nd}]+(?:['\u2019][\p{L}\p{Nd}]+)?")
        $spellings=[string[]]::new($lexemes.Count)
        for ($i=0;$i -lt $lexemes.Count;$i++) {
            $spellings[$i]=$lexemes[$i].Value.ToUpperInvariant().Replace([char]0x2019,[char]39)
        }
        for ($i=0;$i -lt $spellings.Length;$i++) {
            if (!$first.ContainsKey($spellings[$i])) { continue }
            foreach ($item in $first[$spellings[$i]]) {
                $words=$utteranceWords[$item.Id]
                if ($i+$words.Length -gt $spellings.Length) { continue }
                $j=1
                while ($j -lt $words.Length -and $words[$j] -ceq $spellings[$i+$j]) { $j++ }
                if ($j -lt $words.Length) { continue }
                $anchor=[StudentLibriTextAnchor]::new()
                $anchor.Utterance=$item
                $anchor.ArchiveMember=$entry.Name
                $anchor.MemberHash=$digest
                $anchor.Start=$lexemes[$i].Index
                $end=$lexemes[$i+$words.Length-1]
                $anchor.Length=$end.Index+$end.Length-$anchor.Start
                $item.TextAnchors.Add($anchor)
            }
        }
    }
}
$books.Values
$chapters.Values
