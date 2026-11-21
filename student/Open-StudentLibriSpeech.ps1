using module ./StudentSourceInventory.psm1
#requires -Version 7.4

param([string] $InventoryPath = (Join-Path $PSScriptRoot '../data/source-bank/sources.bin'))
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
    [int] $Rate
    [long] $Samples
    [string] $Transcript
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
        $clock = Read-StudentFlacClock $entry.DataStream
        $utterance = [StudentLibriUtterance]::new()
        $utterance.Chapter = $chapter
        $utterance.Id = [IO.Path]::GetFileNameWithoutExtension($name)
        $utterance.AudioMember = $entry.Name
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
}
$books.Values
$chapters.Values
