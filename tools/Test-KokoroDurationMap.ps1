#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$mapScript = Join-Path $PSScriptRoot '../src/models/New-KokoroDurationMap.ps1'
$expandScript = Join-Path $PSScriptRoot '../src/models/Expand-KokoroAlignedFeatures.ps1'
$logits = [float[]]::new(3 * 50)
for ($bin = 0; $bin -lt 50; $bin++) {
    $logits[50 + $bin] = -100.0
    $logits[100 + $bin] = 100.0
}

# 50 sigmoid(0)=25, then 25/10=2.5 rounds to even 2. A very negative
# row clamps to one frame; a very positive row gives five frames at speed 10.
$map = & $mapScript -DurationLogits $logits -TokenCount 3 -Speed 10
if (($map.Counts -join ',') -cne '2,1,5' -or
    ($map.FrameToToken -join ',') -cne '0,0,1,2,2,2,2,2') {
    throw 'Stock duration reduction, rounding, clamp, or alignment differs.'
}

$features = [float[]]@(11, 12, 13, 21, 22, 23)
[float[]]$expanded = & $expandScript -Features $features -Channels 2 `
    -TokenCount 3 -FrameToToken $map.FrameToToken
if (($expanded -join ',') -cne '11,11,12,13,13,13,13,13,21,21,22,23,23,23,23,23') {
    throw 'Gather output differs from dense one-hot feature alignment.'
}

$rejected = $false
try { $null = & $mapScript -DurationLogits $logits -TokenCount 3 -Speed 10 -MaxFrames 7 } catch { $rejected = $true }
if (-not $rejected) { throw 'Frame bound was not enforced.' }
$logits[0] = [float]::NaN
$rejected = $false
try { $null = & $mapScript -DurationLogits $logits -TokenCount 3 -Speed 10 } catch { $rejected = $true }
if (-not $rejected) { throw 'Non-finite duration logit was accepted.' }

Write-Output 'PASS: stock duration rounding, clamp, bounded map, aligned gather'
