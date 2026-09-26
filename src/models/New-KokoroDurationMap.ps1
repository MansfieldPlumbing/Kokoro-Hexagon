#requires -Version 7.4
# Stock Kokoro forward_with_tokens duration and alignment contract.
# kokoro/model.py:107-115 at dfb907a02bba8152ca444717ca5d78747ccb4bec.
# config max_dur=50. A frame-to-token map represents the same one-hot
# alignment without materializing token_count * frame_count floats.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $DurationLogits,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $TokenCount,
    [Parameter(Mandatory)][ValidateRange(0.001, 100)][double] $Speed,
    [ValidateRange(1, 65536)][int] $MaxFrames = 65536
)

$ErrorActionPreference = 'Stop'
$maxDuration = 50
if (-not [double]::IsFinite($Speed)) { throw 'Speed must be finite.' }
if ($DurationLogits.Length -ne $TokenCount * $maxDuration) {
    throw 'Duration logits shape is not [TokenCount, 50].'
}

$counts = [int[]]::new($TokenCount)
$total = 0
for ($token = 0; $token -lt $TokenCount; $token++) {
    $duration = 0.0
    for ($bin = 0; $bin -lt $maxDuration; $bin++) {
        $value = [double]$DurationLogits[$token * $maxDuration + $bin]
        if (-not [double]::IsFinite($value)) { throw 'Duration logits contain a non-finite value.' }
        # Numerically stable sigmoid; the source reduces sigmoid over max_dur.
        if ($value -ge 0.0) {
            $exponent = [Math]::Exp(-$value)
            $duration += 1.0 / (1.0 + $exponent)
        } else {
            $exponent = [Math]::Exp($value)
            $duration += $exponent / (1.0 + $exponent)
        }
    }
    $count = [int][Math]::Max(1.0, [Math]::Round($duration / $Speed, [MidpointRounding]::ToEven))
    if ($total + $count -gt $MaxFrames) { throw 'Predicted frame count exceeds MaxFrames.' }
    $counts[$token] = $count
    $total += $count
}

$frameToToken = [int[]]::new($total)
$frame = 0
for ($token = 0; $token -lt $TokenCount; $token++) {
    for ($repeat = 0; $repeat -lt $counts[$token]; $repeat++) {
        $frameToToken[$frame++] = $token
    }
}

[pscustomobject]@{
    TokenCount = $TokenCount
    FrameCount = $total
    Counts = $counts
    FrameToToken = $frameToToken
}
