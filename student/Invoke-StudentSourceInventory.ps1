using module ./StudentSourceInventory.psm1
#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $Bank = (Join-Path $PSScriptRoot '../data/source-bank'),
    [string[]] $WorkDirectory = @(
        (Join-Path $PSScriptRoot '../build/grammar-corpus/raw'),
        (Join-Path $PSScriptRoot '../build/human-recordings/alice-librivox-4139')
    ),
    [switch] $AcquireAlice,
    [string] $LexiconDirectory = (Join-Path $PSScriptRoot '../../ChatGPT-Workspace/StudentLexicon/reference'),
    [string] $PrivatePerformanceDirectory
)

$ErrorActionPreference = 'Stop'
$bank = [IO.Directory]::CreateDirectory($Bank).FullName
$inventory = [StudentSourceInventory]::new()
$previousPath = Join-Path $bank 'sources.bin'
$previous = if (Test-Path -LiteralPath $previousPath -PathType Leaf) { Open-StudentSourceInventory $previousPath }
$gutenberg = [IO.Directory]::CreateDirectory((Join-Path $bank 'Gutenberg')).FullName
$rights = 'Consult the license retained in the original Project Gutenberg file.'

function Copy-StudentRetainedOriginal([IO.FileInfo] $File, [string] $Directory, [string] $Digest) {
    $null = [IO.Directory]::CreateDirectory($Directory)
    $target = Join-Path $Directory $File.Name
    if (!(Test-Path -LiteralPath $target)) {
        $temporary = "$target.$([guid]::NewGuid()).partial"
        try {
            [IO.File]::Copy($File.FullName,$temporary)
            if ((Get-FileHash -LiteralPath $temporary).Hash -cne $Digest) { throw 'Source changed during retention.' }
            [IO.File]::Move($temporary,$target)
        } finally { [IO.File]::Delete($temporary) }
    }
    if ((Get-FileHash -LiteralPath $target).Hash -cne $Digest) { throw 'Retained source checksum mismatch.' }
    $target
}

function Save-StudentLocalOriginal([IO.FileInfo] $File, [string] $Id, [string] $Kind, [string] $Rights, [string] $Group) {
    $digest = (Get-FileHash -LiteralPath $File.FullName).Hash
    if ($previous -and $previous.Units.ContainsKey($Id) -and $previous.Units[$Id].Checksum -cne $digest) {
        throw "Existing source identity has different content: $Id"
    }
    $path = Copy-StudentRetainedOriginal $File (Join-Path $bank "local-originals/$digest") $digest
    $null = Add-StudentSourceFile -Inventory $inventory -Id $Id -Kind $Kind -Path $path -Rights $Rights -EvidenceGroup $Group
}

$retainedDirectories = @(Get-ChildItem -LiteralPath $gutenberg -Directory -Recurse -Depth 1)
foreach ($directory in @($retainedDirectories.FullName) + $WorkDirectory) {
    if (!$directory -or !(Test-Path -LiteralPath $directory -PathType Container)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $directory -File -Filter 'pg*.txt') {
        if ($file.BaseName -cnotmatch '^pg([0-9]+)$') { continue }
        $ebook = $Matches[1]
        $digest = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $id = "Gutenberg/${ebook}/$digest"
        if ($inventory.Units.ContainsKey($id)) { continue }
        $copy = Copy-StudentRetainedOriginal $file (Join-Path $gutenberg "$ebook/$digest") $digest
        $work = Add-StudentSourceFile -Inventory $inventory -Id $id -Kind FullText -Path $copy `
            -PublisherUri "https://www.gutenberg.org/ebooks/$ebook" -Rights $rights -EvidenceGroup "Gutenberg/$ebook"
        if ($work.Checksum -cne $digest) { throw "Stored work differs from its source: $copy" }

        # Offsets use UTF-16 code units of the BOM-aware UTF-8 decoding, with original line endings.
        $content = [IO.File]::ReadAllText($copy, [Text.UTF8Encoding]::new($false, $true))
        $position = 0
        foreach ($separator in [regex]::Matches($content, '(?:\r\n|\n|\r(?!\n))(?:[ \t]*(?:\r\n|\n|\r(?!\n)))+')) {
            if ($separator.Index -gt $position) {
                $span = [StudentSourceUnit]::new()
                $span.Id = "$id/utf16/$position"
                $span.Kind = 'TextSpanUtf16'
                $span.Start = $position
                $span.Length = $separator.Index - $position
                $span.Parent = $work
                $inventory.Add($span)
            }
            $position = $separator.Index + $separator.Length
        }
        if ($position -lt $content.Length) {
            $span = [StudentSourceUnit]::new()
            $span.Id = "$id/utf16/$position"
            $span.Kind = 'TextSpanUtf16'
            $span.Start = $position
            $span.Length = $content.Length - $position
            $span.Parent = $work
            $inventory.Add($span)
        }
    }
}

foreach ($name in 'metadata.json', 'pg_catalog.csv') {
    $path = Join-Path $gutenberg $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $null = Add-StudentSourceFile -Inventory $inventory -Id "Gutenberg/Mirror/$name" -Kind PublisherCatalog `
            -Path $path -PublisherUri "https://www.gutenberg.org/ebooks/offline_catalogs.html" -EvidenceGroup 'Gutenberg'
    }
}

if (Test-Path -LiteralPath $LexiconDirectory -PathType Container) {
    foreach ($file in Get-ChildItem -LiteralPath $LexiconDirectory -File) {
        Save-StudentLocalOriginal $file "StudentLexicon/$($file.Name)" LexicalReference `
            'See the original notices and CORPUS-PROVENANCE.md in StudentLexicon.' "StudentLexicon/$($file.Name)"
    }
}

if ($PrivatePerformanceDirectory) {
    $privateRoot = (Resolve-Path -LiteralPath $PrivatePerformanceDirectory).Path
    foreach ($file in Get-ChildItem -LiteralPath $privateRoot -Recurse -File) {
        if ($file.Extension -notin '.mp3', '.wav', '.srt', '.docx') { continue }
        $relative = [IO.Path]::GetRelativePath($privateRoot, $file.FullName)
        $kind = if ($file.Extension -in '.mp3', '.wav') { 'PrivatePerformanceAudio' } else { 'PrivatePerformanceReference' }
        Save-StudentLocalOriginal $file "PrivatePerformance/$relative" $kind `
            'Private workspace material. Rights for external reuse unverified.' PrivateGeneratedPerformance
    }
}
if ($previous) {
    foreach ($unit in $previous.Units.Values) {
        if ($unit.Kind -cin 'LexicalReference','PrivatePerformanceAudio','PrivatePerformanceReference' -and
            !$inventory.Units.ContainsKey($unit.Id)) {
            $inventory.Add($unit)
        }
    }
}

$libriSpeech = Join-Path $bank 'LibriSpeech'
$checksums = Join-Path $libriSpeech 'md5sum.txt'
if (Test-Path -LiteralPath $checksums -PathType Leaf) {
    $release = Add-StudentSourceFile -Inventory $inventory -Id 'OpenSLR/12' -Kind PublisherReleaseChecksums `
        -Path $checksums -PublisherUri 'https://www.openslr.org/12/' -Rights 'OpenSLR lists the corpus as CC BY 4.0.' `
        -EvidenceGroup 'LibriSpeech'
    foreach ($line in Get-Content -LiteralPath $checksums) {
        if ($line -cnotmatch '^(?<digest>[0-9a-f]{32})\s+(?<name>[a-z0-9-]+\.tar\.gz)$') { continue }
        $name = $Matches.name
        $expected = $Matches.digest
        $path = Join-Path $libriSpeech $name
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if ((Get-FileHash -LiteralPath $path -Algorithm MD5).Hash -ne $expected) { throw "OpenSLR checksum mismatch for $name" }
        $null = Add-StudentSourceFile -Inventory $inventory -Id "OpenSLR/12/$name" -Kind VerifiedPublisherArchive `
            -Path $path -PublisherUri "https://www.openslr.org/resources/12/$name" -Rights $release.Rights `
            -EvidenceGroup $release.EvidenceGroup -Parent $release
    }
}

$openYap = Join-Path $bank 'OpenYap'
$shardReceipt = Join-Path $openYap 'publisher-shard.txt'
if (Test-Path -LiteralPath $shardReceipt -PathType Leaf) {
    $shard = [IO.File]::ReadAllText($shardReceipt).Trim()
    if ($shard -cnotmatch '^https://huggingface\.co/datasets/TheAgenticDataCompany/open-yap-1k/resolve/[a-f0-9]{40}/shard-[0-9]{5}\.tar$') {
        throw 'Open Yap requires a pinned publisher shard URL.'
    }
    foreach ($transcript in Get-ChildItem -LiteralPath $openYap -File -Filter 'conv_*.json') {
        $channelPaths = @(
            (Join-Path $openYap "$($transcript.BaseName).a.flac"),
            (Join-Path $openYap "$($transcript.BaseName).b.flac")
        )
        if (!(Test-Path -LiteralPath $channelPaths[0]) -or !(Test-Path -LiteralPath $channelPaths[1])) {
            Write-Warning "Missing original channels for $($transcript.BaseName)"
            continue
        }
        $id = "OpenYap/$($transcript.BaseName)"
        $conversation = Add-StudentSourceFile -Inventory $inventory -Id $id -Kind PublisherConversationTranscript `
            -Path $transcript.FullName -PublisherUri $shard -Rights 'CC BY 4.0' -EvidenceGroup $id
        $channels = @(foreach ($channelPath in $channelPaths) {
            $stream = [IO.File]::OpenRead($channelPath)
            try { $clock = Read-StudentFlacClock $stream } finally { $stream.Dispose() }
            $channel = Add-StudentSourceFile -Inventory $inventory -Id "$id/$([IO.Path]::GetFileName($channelPath))" `
                -Kind OriginalConversationChannel -Path $channelPath -PublisherUri $shard -Rights $conversation.Rights `
                -EvidenceGroup $id -Parent $conversation -CorrespondingText $conversation
            $channel.SampleRate = $clock.Item1
            $channel.Channels = $clock.Item2
            $channel.SampleCount = $clock.Item3
            $channel
        })
        if ($channels[0].SampleRate -ne 48000 -or $channels[1].SampleRate -ne $channels[0].SampleRate -or
            $channels[0].SampleCount -le 0 -or $channels[0].SampleCount -ne $channels[1].SampleCount -or
            $channels[0].Channels -ne 1 -or $channels[1].Channels -ne 1) {
            throw "Unexpected conversation source clocks for $id"
        }
        $metadata = Get-Content -LiteralPath $transcript.FullName -Raw | ConvertFrom-Json -AsHashtable
        if ($metadata.conversation_id -cne $transcript.BaseName -or $metadata.sample_rate -ne $channels[0].SampleRate) {
            throw "Conversation transcript identity or source clock differs for $id"
        }
        for ($side = 0; $side -lt 2; $side++) {
            $key = @('a','b')[$side]
            $channel = $channels[$side]
            $words = $metadata.transcripts[$key].words
            if (!$words.Count) { throw "Missing transcript observations for $id channel $key" }
            for ($index = 0; $index -lt $words.Count; $index++) {
                $label = $words[$index]
                $observation = [StudentSourceUnit]::new()
                $observation.Id = "$($channel.Id)/transcript/$index"
                $observation.Parent = $channel
                $observation.CorrespondingText = $conversation
                $observation.EvidenceGroup = $id
                $observation.Kind = 'PublisherTranscriptUnresolved'
                if ($null -ne $label.start -and $null -ne $label.end -and
                    [double]::IsFinite($label.start) -and [double]::IsFinite($label.end)) {
                    $first = [long][Math]::Round($label.start * $channel.SampleRate)
                    $last = [long][Math]::Round($label.end * $channel.SampleRate)
                    if ($first -ge 0 -and $last -ge $first -and $last -le $channel.SampleCount) {
                        $observation.Start = $first
                        $observation.Length = $last - $first
                        $observation.Kind = if ($label.type -ceq 'word') {
                            'PublisherTranscriptWordSamples'
                        } else {
                            'PublisherTranscriptEventSamples'
                        }
                    }
                }
                $inventory.Add($observation)
            }
        }
    }
}

$amiArchive = Join-Path $bank 'AMI/ami_public_manual_1.6.2.zip'
if (Test-Path -LiteralPath $amiArchive -PathType Leaf) {
    $null = Add-StudentSourceFile -Inventory $inventory -Id 'AMI/manual/1.6.2' -Kind PublisherMeetingAnnotations `
        -Path $amiArchive -PublisherUri 'https://groups.inf.ed.ac.uk/ami/download/' -Rights 'CC BY 4.0' -EvidenceGroup 'AMI'
}

$archiveId = 'aliceinwonderland_1102_librivox'
$recordingDir = [IO.Directory]::CreateDirectory((Join-Path $bank "LibriVox/$archiveId")).FullName
$publisher = "https://archive.org/details/$archiveId"
$metadataPath = Join-Path $recordingDir 'archive-metadata.json'
if ($AcquireAlice -and !(Test-Path -LiteralPath $metadataPath)) {
    Invoke-WebRequest "https://archive.org/metadata/$archiveId" -OutFile "$metadataPath.partial" -TimeoutSec 60
    $null = Get-Content -LiteralPath "$metadataPath.partial" -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move("$metadataPath.partial", $metadataPath)
}
if (Test-Path -LiteralPath $metadataPath) {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable
    if ($metadata.metadata.identifier -cne $archiveId) { throw 'Unexpected Internet Archive identifier.' }
    $recording = Add-StudentSourceFile -Inventory $inventory -Id "LibriVox/$archiveId" -Kind PublisherRecordingMetadata `
        -Path $metadataPath -PublisherUri $publisher -Rights 'Public Domain Mark 1.0' -EvidenceGroup "LibriVox/$archiveId"
    $candidateTexts = @($inventory.Units.Values.Where({ $_.Kind -ceq 'FullText' -and $_.EvidenceGroup -ceq 'Gutenberg/11' }))
    if ($candidateTexts.Count -eq 1) { $recording.CorrespondingText = $candidateTexts[0] }
    $files = @($metadata.files.Where({ $_.source -ceq 'original' -and $_.format -ceq 'VBR MP3' }) | Sort-Object { $_.name })
    if ($files.Count -ne 13) { throw 'The publisher manifest must list 13 original tracks.' }
    foreach ($entry in $files) {
        if ($entry.name -cnotmatch '^aliceinwonderland_(?:0[0-9]|1[0-2])_carroll\.mp3$' -or $entry.sha1 -cnotmatch '^[0-9a-f]{40}$') {
            throw 'Unexpected original track metadata.'
        }
        $path = Join-Path $recordingDir $entry.name
        $uri = "https://archive.org/download/$archiveId/$($entry.name)"
        $candidate = $path
        try {
            if (!(Test-Path -LiteralPath $path)) {
                if (!$AcquireAlice) {
                    Write-Warning "Missing original track: $($entry.name)"
                    continue
                }
                $candidate = "$path.partial"
                Invoke-WebRequest $uri -Resume -OutFile $candidate -TimeoutSec 90
            }
            if ((Get-Item -LiteralPath $candidate).Length -ne [long]$entry.size -or
                (Get-FileHash -LiteralPath $candidate -Algorithm SHA1).Hash -ne $entry.sha1) {
                throw 'Publisher length or SHA-1 mismatch.'
            }
            if ($candidate -cne $path) { [IO.File]::Move($candidate, $path) }
            $seconds = [double]::Parse($entry.length, [Globalization.CultureInfo]::InvariantCulture)
            $null = Add-StudentSourceFile -Inventory $inventory -Id "$($recording.Id)/$($entry.name)" -Kind OriginalHumanAudio `
                -Path $path -PublisherUri $uri -Rights $recording.Rights -EvidenceGroup $recording.EvidenceGroup `
                -Parent $recording -PublishedSeconds $seconds
        } catch {
            Write-Warning "Track $($entry.name): $($_.Exception.Message)"
        }
    }
}

$index = Join-Path $bank 'sources.bin'
Save-StudentSourceInventory $inventory $index
$inventory
