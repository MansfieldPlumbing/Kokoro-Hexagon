#requires -Version 7.7
Set-StrictMode -Version Latest

class KokoroGeneratorLockTables {
    [int] $Channels
    [int] $Positions
    [int] $BlockFrames
    [int] $Blocks
    [int] $StrideBytes
    [int] $StaticBytes
    [float[]] $NativeCoefficients
    [double[]] $Seats
}

function New-KokoroGeneratorLockTables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][float[]] $InputValues,
        [Parameter(Mandatory)][float[]] $Alpha,
        [Parameter(Mandatory)][float[]] $AffineCoefficients,
        [Parameter(Mandatory)][int] $Frames,
        [Parameter(Mandatory)][int] $OutputFrames,
        [ValidateRange(16,64)][int] $BlockFrames = 16
    )
    # Independent PowerShell implementation of the supplied lock equations.
    # Probe identity: 84E9927E98E94AC619A30F9C553988774730F045B5530D65F74671B7265F6576.
    $channels = $Alpha.Length
    if ($channels -notin 128,256 -or $InputValues.Length -ne $channels*$Frames -or
        $AffineCoefficients.Length -ne 5*$channels -or $OutputFrames -gt $Frames -or
        $OutputFrames -lt 1) { throw 'Invalid generator lock input shape.' }
    $positions = if ($channels -eq 256) { 10 } else { 60 }
    if ($positions*$BlockFrames % 32 -ne 0) { throw 'Lock blocks must contain full HMX tiles.' }
    $blocks = [int][Math]::Ceiling($OutputFrames/[double]($positions*$BlockFrames))
    $stride = $channels/32*($positions/2*256)
    $native = [float[]]::new(5*$channels+$blocks*$stride)
    [Array]::Copy($AffineCoefficients,0,$native,0,$AffineCoefficients.Length)
    # [block][channel][seat][mean, folded phase, sin^2, slope, direction].
    $seats = [double[]]::new($blocks*$channels*$positions*5)
    $realFrames = [int][Math]::Ceiling($Frames/[double]$positions)
    for ($blockIndex=0; $blockIndex -lt $blocks; $blockIndex++) {
        $firstFrame = $blockIndex*$BlockFrames
        $count = [Math]::Min($BlockFrames,$realFrames-$firstFrame)
        for ($channel=0; $channel -lt $channels; $channel++) {
            if (-not [float]::IsFinite($Alpha[$channel]) -or $Alpha[$channel] -eq 0) { throw 'Invalid nonzero Snake alpha.' }
            $a = [double]$Alpha[$channel]
            $affineAt = (($channel-$channel%32)/32)*160 + $channel%32
            $affineA = [double]$AffineCoefficients[$affineAt]
            $affineB = [double]$AffineCoefficients[$affineAt+32]
            for ($seat=0; $seat -lt $positions; $seat++) {
                $mean = 0.0
                for ($frameIndex=0; $frameIndex -lt $count; $frameIndex++) {
                    $t = [Math]::Min(($firstFrame+$frameIndex)*$positions+$seat,$Frames-1)
                    $mean += [double]$InputValues[$channel*$Frames+$t]
                }
                $mean /= $count
                $phase = $a*$mean
                $phase -= [Math]::Floor($phase/[Math]::PI)*[Math]::PI
                $direction = 1.0
                if ($phase -gt [Math]::PI/2) { $phase = [Math]::PI-$phase; $direction = -1.0 }
                $height = [Math]::Pow([Math]::Sin($phase),2)
                $slope = [Math]::Sin(2*$phase)
                $seatAt = (($blockIndex*$channels+$channel)*$positions+$seat)*5
                $seats[$seatAt]=$mean; $seats[$seatAt+1]=$phase; $seats[$seatAt+2]=$height
                $seats[$seatAt+3]=$slope; $seats[$seatAt+4]=$direction
                # Each pair has K0/K1, PHI0/PHI1, tangent intercept0/1, slope0/1.
                $channelBlock = ($channel-$channel%32)/32
                $pair = ($seat-$seat%2)/2
                $at = $blockIndex*$stride + 5*$channels + $channelBlock*($positions/2*256) + $pair*256 + ($seat%2)*32 + $channel%32
                $native[$at] = [float]($direction*$a*$affineA*16777216/[Math]::PI)
                $native[$at+64] = [float](($phase+$direction*$a*($affineB-$mean))*16777216/[Math]::PI)
                $native[$at+128] = [float]($height-$slope*$phase)
                $native[$at+192] = [float]$slope
            }
        }
    }
    $result = [KokoroGeneratorLockTables]::new()
    $result.Channels=$channels; $result.Positions=$positions; $result.BlockFrames=$BlockFrames
    $result.Blocks=$blocks; $result.StrideBytes=4*$stride
    $result.StaticBytes=20*$channels
    $result.NativeCoefficients=$native; $result.Seats=$seats
    $result
}

function Invoke-KokoroGeneratorLockReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][float[]] $InputValues,
        [Parameter(Mandatory)][float[]] $Alpha,
        [Parameter(Mandatory)][KokoroGeneratorLockTables] $Tables,
        [Parameter(Mandatory)][int] $Frames,
        [Parameter(Mandatory)][int] $OutputFrames,
        [ValidateRange(0,2147483647)][int] $FirstPosition = 0
    )
    if ($Alpha.Length -ne $Tables.Channels -or $InputValues.Length -ne $Tables.Channels*$Frames -or
        $OutputFrames+$FirstPosition -gt $Frames -or $OutputFrames+$FirstPosition -gt $Tables.Blocks*$Tables.BlockFrames*$Tables.Positions) {
        throw 'Invalid lock reference shape.'
    }
    $result = [float[]]::new($Tables.Channels*$OutputFrames)
    $blockPositions = $Tables.BlockFrames*$Tables.Positions
    for ($channel=0; $channel -lt $Tables.Channels; $channel++) {
        for ($t=0; $t -lt $OutputFrames; $t++) {
            $position = $t+$FirstPosition
            $blockIndex = ($position-$position%$blockPositions)/$blockPositions
            $at = (($blockIndex*$Tables.Channels+$channel)*$Tables.Positions+$position%$Tables.Positions)*5
            $mean=$Tables.Seats[$at]; $phase=$Tables.Seats[$at+1]
            $phi=$phase+$Tables.Seats[$at+4]*[double]$Alpha[$channel]*([double]$InputValues[$channel*$Frames+$position]-$mean)
            $phi -= [Math]::Floor($phi/[Math]::PI)*[Math]::PI
            $phi = [Math]::Min($phi,[Math]::PI-$phi)
            $w = [Math]::Clamp($Tables.Seats[$at+2]+$Tables.Seats[$at+3]*($phi-$phase),0.0,1.0)
            $result[$channel*$OutputFrames+$t] = [float]([double]$InputValues[$channel*$Frames+$position]+$w/[double]$Alpha[$channel])
        }
    }
    return ,$result
}

Export-ModuleMember -Function New-KokoroGeneratorLockTables, Invoke-KokoroGeneratorLockReference
