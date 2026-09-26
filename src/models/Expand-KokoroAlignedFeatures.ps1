#requires -Version 7.4
# Equivalent to channel-first features @ Kokoro's one-hot alignment matrix.
# kokoro/model.py:110-117 at dfb907a02bba8152ca444717ca5d78747ccb4bec.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $Features,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $Channels,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $TokenCount,
    [Parameter(Mandatory)][int[]] $FrameToToken
)

$ErrorActionPreference = 'Stop'
$frames = $FrameToToken.Length
if ($frames -lt $TokenCount -or $frames -gt 65536 -or
    $Features.Length -ne [long]$Channels * $TokenCount -or
    [long]$Channels * $frames -gt 8388608) {
    throw 'Aligned feature shape is invalid or exceeds the reference bound.'
}
foreach ($token in $FrameToToken) {
    if ($token -lt 0 -or $token -ge $TokenCount) { throw 'Alignment token index is out of range.' }
}
foreach ($value in $Features) {
    if (-not [float]::IsFinite($value)) { throw 'Aligned feature input is non-finite.' }
}

$output = [float[]]::new($Channels * $frames)
for ($channel = 0; $channel -lt $Channels; $channel++) {
    $inputBase = $channel * $TokenCount
    $outputBase = $channel * $frames
    for ($frame = 0; $frame -lt $frames; $frame++) {
        $output[$outputBase + $frame] = $Features[$inputBase + $FrameToToken[$frame]]
    }
}
Write-Output -NoEnumerate $output
