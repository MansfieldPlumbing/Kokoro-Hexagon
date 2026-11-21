#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $Revision,
    [string] $Directory = (Join-Path $PSScriptRoot '../data/source-bank/OpenYap')
)

$ErrorActionPreference = 'Stop'
$destination = [IO.Directory]::CreateDirectory($Directory).FullName
$origin = "https://huggingface.co/datasets/TheAgenticDataCompany/open-yap-1k/resolve/$Revision/shard-00000.tar"
$receipt = Join-Path $destination 'publisher-shard.txt'
if (Test-Path -LiteralPath $receipt) {
    if ([IO.File]::ReadAllText($receipt).Trim() -cne $origin) { throw 'Select a directory for this publisher revision.' }
    return
}

function Read-ArchiveRange([long] $Start, [int] $Count) {
    $end = $Start + $Count - 1
    $response = Invoke-WebRequest $origin -Headers @{ Range = "bytes=$Start-$end" } -TimeoutSec 45 -MaximumRetryCount 2
    if ($response.StatusCode -ne 206 -or $response.Headers['Content-Range'][0] -cnotmatch "^bytes $Start-$end/\d+$" -or
        $response.Content.Length -ne $Count) {
        throw "Publisher did not return the requested tar byte range $Start-$end."
    }
    ,([byte[]]$response.Content)
}

$offset = [long]0
$conversation = ''
$completed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
while ($completed.Count -lt 3) {
    $header = Read-ArchiveRange $offset 512
    $name = [Text.Encoding]::ASCII.GetString($header, 0, 100).TrimEnd([char]0)
    $size = [Convert]::ToInt64([Text.Encoding]::ASCII.GetString($header, 124, 12).Trim([char[]]@(0, 32)), 8)
    $expected = [Convert]::ToInt32([Text.Encoding]::ASCII.GetString($header, 148, 8).Trim([char[]]@(0, 32)), 8)
    $sum = 0
    for ($i = 0; $i -lt $header.Length; $i++) {
        $sum += if ($i -ge 148 -and $i -lt 156) { 32 } else { $header[$i] }
    }
    if ($sum -ne $expected -or $size -le 0 -or $header[156] -notin 0, 48 -or
        $name -cnotmatch '^(?<id>conv_[a-z0-9]+)\.(?<member>preview\.mp3|a\.flac|b\.flac|json)$') {
        throw "Unexpected tar member at offset $offset."
    }
    if (!$conversation) { $conversation = $Matches.id }
    if ($conversation -cne $Matches.id) { throw 'The first conversation is missing an original member.' }
    $member = $Matches.member
    $dataStart = $offset + 512
    $offset = $dataStart + (($size + 511) -band (-bnot [long]511))
    if ($member -ceq 'preview.mp3') { continue }
    if (!$completed.Add($member)) { throw "Duplicate conversation member $member." }
    $target = Join-Path $destination $name
    $staging = "$target.$Revision.partial"
    if (Test-Path -LiteralPath $target) {
        if ((Get-Item -LiteralPath $target).Length -ne $size) { throw "Unexpected length for existing member $name." }
        continue
    }
    $file = [IO.File]::Open($staging, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if ($file.Length -gt $size) { throw "Oversized partial file $staging." }
        $file.Position = $file.Length
        while ($file.Position -lt $size) {
            $count = [int][Math]::Min(4MB, $size - $file.Position)
            $buffer = Read-ArchiveRange ($dataStart + $file.Position) $count
            $file.Write($buffer, 0, $buffer.Length)
        }
    } finally {
        $file.Dispose()
    }
    [IO.File]::Move($staging, $target)
}
[IO.File]::WriteAllText($receipt, $origin)
