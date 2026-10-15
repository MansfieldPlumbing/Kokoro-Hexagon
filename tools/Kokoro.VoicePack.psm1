#requires -Version 7.4
# Kokoro voice packs as typed objects, and their profiles.
# A pack is a PyTorch zip holding one float32 storage of shape (510, 1, 256): row n is the style for an utterance of
# n + 1 phonemes. Columns 0..127 condition the decoder and generator (timbre); 128..255 condition the predictor
# (durations, F0, N). The storage is read as raw little-endian float32; the pickle is never executed.
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

class KokoroVoicePack {
    [string] $Name
    [string] $Language
    [string] $Gender
    [string] $Path
    [string] $Sha256
    [float[][]] $Rows
}

$script:Languages = @{ a = 'American English'; b = 'British English'; e = 'Spanish'; f = 'French'; h = 'Hindi'
    i = 'Italian'; j = 'Japanese'; p = 'Brazilian Portuguese'; z = 'Mandarin' }

function Read-KokoroVoicePack {
    [CmdletBinding()]
    [OutputType([KokoroVoicePack])]
    param([Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('FullName')][string] $Path)
    process {
        $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $Path))
        try {
            $entries = @($zip.Entries | Where-Object { $_.FullName -match '/data/\d+$' })
            if ($entries.Count -ne 1) { throw "$Path holds $($entries.Count) tensor storages, expected 1" }
            $order = $zip.Entries | Where-Object { $_.FullName -like '*/byteorder' }
            if ($order) {
                $reader = [IO.StreamReader]::new($order.Open()); $text = $reader.ReadToEnd(); $reader.Dispose()
                if ($text -cne 'little') { throw "$Path byte order is '$text', expected little" }
            }
            if ($entries[0].Length -ne 510 * 256 * 4) { throw "$Path storage is $($entries[0].Length) bytes, expected 522240 (510 x 256 float32)" }
            $stream = $entries[0].Open(); $buffer = [byte[]]::new($entries[0].Length); $read = 0
            while ($read -lt $buffer.Length) { $n = $stream.Read($buffer, $read, $buffer.Length - $read); if ($n -le 0) { break }; $read += $n }
            $stream.Dispose()
            if ($read -ne $buffer.Length) { throw "$Path storage truncated at $read bytes" }
        } finally { $zip.Dispose() }
        $flat = [float[]]::new(510 * 256); [Buffer]::BlockCopy($buffer, 0, $flat, 0, $buffer.Length)
        $rows = [float[][]]::new(510)
        for ($r = 0; $r -lt 510; $r++) { $row = [float[]]::new(256); [Array]::Copy($flat, $r * 256, $row, 0, 256); $rows[$r] = $row }
        $name = [IO.Path]::GetFileNameWithoutExtension($Path)
        [KokoroVoicePack]@{
            Name = $name; Path = (Resolve-Path $Path).Path; Rows = $rows
            Language = $script:Languages[[string]$name[0]]; Gender = $(if ($name[1] -ceq 'f') { 'female' } elseif ($name[1] -ceq 'm') { 'male' } else { 'unknown' })
            Sha256 = (Get-FileHash $Path -Algorithm SHA256).Hash
        }
    }
}

function Get-KokoroVoiceHalf([float[]] $Row, [int] $Start) {
    $half = [double[]]::new(128); for ($i = 0; $i -lt 128; $i++) { $half[$i] = $Row[$Start + $i] }; , $half
}

function Get-KokoroVectorNorm([double[]] $v) { $s = 0.0; foreach ($x in $v) { $s += $x * $x }; [math]::Sqrt($s) }

function Get-KokoroCosineDistance([double[]] $a, [double[]] $b) {
    $dot = 0.0; for ($i = 0; $i -lt $a.Length; $i++) { $dot += $a[$i] * $b[$i] }
    1.0 - $dot / [math]::Max((Get-KokoroVectorNorm $a) * (Get-KokoroVectorNorm $b), 1e-30)
}

function Measure-KokoroVoicePack {
    <#
    .SYNOPSIS
    Profiles voice packs: each half's size, how much it moves across the 510 length rows, and distance from a reference voice.
    .EXAMPLE
    $packs = Get-ChildItem build/inputs/kokoro/*/voices/*.pt | Read-KokoroVoicePack
    $packs | Measure-KokoroVoicePack -Reference ($packs | Where-Object Name -eq af_heart) | Sort-Object TimbreDistance
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][KokoroVoicePack] $Voice,
        [KokoroVoicePack] $Reference,
        # The length row compared across voices: row n is an utterance of n + 1 phonemes.
        [ValidateRange(0, 509)][int] $Row = 63
    )
    process {
        $profile = [ordered]@{ PSTypeName = 'Kokoro.VoiceProfile'; Name = $Voice.Name; Language = $Voice.Language; Gender = $Voice.Gender }
        foreach ($part in @(@{ Name = 'Timbre'; Start = 0 }, @{ Name = 'Prosody'; Start = 128 })) {
            $at = Get-KokoroVoiceHalf $Voice.Rows[$Row] $part.Start
            $first = Get-KokoroVoiceHalf $Voice.Rows[0] $part.Start
            $last = Get-KokoroVoiceHalf $Voice.Rows[509] $part.Start
            $profile["$($part.Name)Norm"] = Get-KokoroVectorNorm $at
            # How far the half travels from the shortest to the longest utterance, relative to its size.
            $diff = [double[]]::new(128); for ($i = 0; $i -lt 128; $i++) { $diff[$i] = $last[$i] - $first[$i] }
            $profile["$($part.Name)LengthTravel"] = (Get-KokoroVectorNorm $diff) / [math]::Max((Get-KokoroVectorNorm $at), 1e-30)
            if ($Reference) {
                $profile["$($part.Name)Distance"] = Get-KokoroCosineDistance $at (Get-KokoroVoiceHalf $Reference.Rows[$Row] $part.Start)
            }
        }
        $profile.Row = $Row; $profile.Sha256 = $Voice.Sha256
        [pscustomobject]$profile
    }
}

Export-ModuleMember -Function Read-KokoroVoicePack, Measure-KokoroVoicePack
