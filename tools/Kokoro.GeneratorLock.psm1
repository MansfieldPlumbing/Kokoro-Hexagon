#requires -Version 7.7
Set-StrictMode -Version Latest

class KokoroLockStructureMath {
    static [double[]] SeatTotals([float[]] $values, [float[]] $alpha, [int] $frames, [int] $positions) {
        $channels = $alpha.Length
        $count = [int]($frames - $frames % $positions)
        $totals = [double[]]::new($channels * $positions)
        for ($channel = 0; $channel -lt $channels; $channel++) {
            for ($time = 0; $time -lt $count; $time++) {
                $phase = [double]$alpha[$channel] * [double]$values[$channel * $frames + $time]
                $totals[$channel * $positions + $time % $positions] += $phase
            }
        }
        return $totals
    }
    static [double[]] Analyze([float[]] $values, [float[]] $alpha, [int] $frames, [int] $positions, [double[]] $bias, [double[]] $changes) {
        $channels = $alpha.Length
        $frameCount = [int](($frames - $frames % $positions) / $positions)
        $energy = [double]0; $afterBias = [double]0; $residual = [double]0
        $changeAt = 0
        for ($channel = 0; $channel -lt $channels; $channel++) {
            $previous = [double]0
            for ($frame = 0; $frame -lt $frameCount; $frame++) {
                $channelLock = [double]0
                for ($seat = 0; $seat -lt $positions; $seat++) {
                    $at = $channel * $frames + $frame * $positions + $seat
                    $phase = [double]$alpha[$channel] * [double]$values[$at]
                    $channelLock += $phase - $bias[$channel * $positions + $seat]
                }
                $channelLock /= [double]$positions
                if ($frame -gt 0) { $changes[$changeAt] = [Math]::Abs($channelLock - $previous); $changeAt++ }
                $previous = $channelLock
                for ($seat = 0; $seat -lt $positions; $seat++) {
                    $at = $channel * $frames + $frame * $positions + $seat
                    $phase = [double]$alpha[$channel] * [double]$values[$at]
                    $difference = $phase - $bias[$channel * $positions + $seat]
                    $remaining = $difference - $channelLock
                    $energy += $phase * $phase; $afterBias += $difference * $difference; $residual += $remaining * $remaining
                }
            }
        }
        return [double[]]@($energy, $afterBias, $residual)
    }
    static [float[]] ApplySplit([float[]] $values, [float[]] $alpha, [int] $frames, [int] $positions, [double[]] $bias) {
        $channels = $alpha.Length
        $output = [float[]]::new($values.Length)
        $sinBias = [double[]]::new($bias.Length); $cosBias = [double[]]::new($bias.Length)
        for ($at = 0; $at -lt $bias.Length; $at++) { $sinBias[$at] = [Math]::Sin([double]2 * $bias[$at]); $cosBias[$at] = [Math]::Cos([double]2 * $bias[$at]) }
        for ($channel = 0; $channel -lt $channels; $channel++) {
            for ($first = 0; $first -lt $frames; $first += $positions) {
                $count = [Math]::Min($positions, $frames - $first)
                $channelLock = [double]0
                for ($seat = 0; $seat -lt $count; $seat++) {
                    $at = $channel * $frames + $first + $seat
                    $channelLock += [double]$alpha[$channel] * [double]$values[$at] - $bias[$channel * $positions + $seat]
                }
                $channelLock /= [double]$count
                $sine = [Math]::Sin([double]2 * $channelLock); $cosine = [Math]::Cos([double]2 * $channelLock)
                for ($seat = 0; $seat -lt $count; $seat++) {
                    $at = $channel * $frames + $first + $seat; $biasAt = $channel * $positions + $seat
                    $height = [double]0.5 * ([double]1 - $cosBias[$biasAt] * $cosine + $sinBias[$biasAt] * $sine)
                    $output[$at] = [float]([double]$values[$at] + $height / [double]$alpha[$channel])
                }
            }
        }
        return $output
    }
}

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
            if ($phi -lt 0.0) { $phi = -$phi }
            if ($phi -gt [Math]::PI/2) { $phi = [Math]::PI-$phi }
            $phi = [Math]::Clamp($phi,0.0,[Math]::PI/2)
            $w = [Math]::Clamp($Tables.Seats[$at+2]+$Tables.Seats[$at+3]*($phi-$phase),0.0,1.0)
            $result[$channel*$OutputFrames+$t] = [float]([double]$InputValues[$channel*$Frames+$position]+$w/[double]$Alpha[$channel])
        }
    }
    return ,$result
}

function New-KokoroLockStructureStudy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $OutputDirectory)
    $root=Split-Path -Parent $PSScriptRoot
    $destination=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $destination.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $destination)){throw 'Choose a fresh study directory under build/.'}
    [void][IO.Directory]::CreateDirectory($destination)
    $compilerRoot=Join-Path $root 'build/phonemizer/inputs/pslowering-1afabe056235a570da29e268824784557d4f6cdd'
    $pins=@(Import-Csv -LiteralPath (Join-Path $compilerRoot 'verified-source.tsv') -Delimiter "`t")
    if($pins.Count -ne 9){throw 'Incomplete pinned compiler.'}
    foreach($pin in $pins){if($pin.Commit -cne '1afabe056235a570da29e268824784557d4f6cdd' -or (Get-FileHash -LiteralPath (Join-Path $compilerRoot $pin.Path)).Hash -cne $pin.Sha256){throw 'Compiler integrity mismatch.'}}
    Import-Module (Join-Path $compilerRoot 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1')
    $sourcePath=Join-Path $PSScriptRoot 'Kokoro.GeneratorLock.psm1'
    $kernelPath=Join-Path $destination 'Kokoro.LockStructure.dll'
    $null=Export-LoweredAssembly -SourcePath $sourcePath -ClassName KokoroLockStructureMath -OutputPath $kernelPath -Deterministic
    $admission=Test-LoweredAssembly -AssemblyPath $kernelPath
    if(-not $admission.ClrOnlyAdmitted){throw 'Lock structure kernel references SMA.'}
    $kernel=[Reflection.Assembly]::LoadFrom($kernelPath).GetType('KokoroLockStructureMath',$true)
    [pscustomobject]@{PSTypeName='Kokoro.LockStructure.Study';Directory=$destination;
        SourceSHA256=(Get-FileHash -LiteralPath $sourcePath).Hash;AssemblySHA256=(Get-FileHash -LiteralPath $kernelPath).Hash;
        Totals=$kernel.GetMethod('SeatTotals').CreateDelegate([Func[float[],float[],int,int,double[]]]);
        Analyze=$kernel.GetMethod('Analyze').CreateDelegate([Func[float[],float[],int,int,double[],double[],double[]]]);
        Apply=$kernel.GetMethod('ApplySplit').CreateDelegate([Func[float[],float[],int,int,double[],float[]]]);
        Sites=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);
        Observations=[Collections.Generic.List[object]]::new();Biases=[Collections.Generic.Dictionary[string,double[]]]::new([StringComparer]::Ordinal)}
}

function Add-KokoroLockStructureObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Study,[Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Site,[Parameter(Mandatory)][float[]]$InputValues,
        [Parameter(Mandatory)][float[]]$Alpha,[Parameter(Mandatory)][int]$Frames)
    if($CaseName -cnotmatch '^(dog|peach|[0-9]{2})$' -or $Site -cnotmatch '^generator\.(resblocks|noise_res)\.[0-9]+\.adain[12]\.[012]$' -or
        $Alpha.Length -notin 128,256 -or $InputValues.Length -ne $Alpha.Length*$Frames){throw 'Invalid observed Snake input contract.'}
    $positions=if($Alpha.Length -eq 256){10}else{60}
    $frameCount=[int](($Frames-$Frames%$positions)/$positions)
    if($frameCount -lt 2){throw 'Insufficient complete frames for temporal measurement.'}
    $name="$CaseName.$Site.input.f32";$path=Join-Path $Study.Directory $name
    if(Test-Path -LiteralPath $path){throw 'Duplicate observation; preserved inputs cannot be overwritten.'}
    foreach($value in $Alpha){if(-not [float]::IsFinite($value) -or $value -eq 0){throw 'Invalid Snake alpha.'}}
    $raw=[byte[]]::new(4*$InputValues.Length);[Buffer]::BlockCopy($InputValues,0,$raw,0,$raw.Length);[IO.File]::WriteAllBytes($path,$raw)
    $totals=$Study.Totals.Invoke($InputValues,$Alpha,$Frames,$positions)
    if(-not [double]::IsFinite([Linq.Enumerable]::Sum([double[]]$totals))){throw 'Nonfinite observed Snake phase.'}
    if(-not $Study.Sites.ContainsKey($Site)){
        $Study.Sites.Add($Site,[pscustomobject]@{Name=$Site;Alpha=$Alpha.Clone();Channels=$Alpha.Length;Positions=$positions;
            TotalFrames=0L;Totals=[double[]]::new($totals.Length);Changes=[Collections.Generic.List[double[]]]::new()})
    }
    $siteRecord=$Study.Sites[$Site]
    if(-not [Linq.Enumerable]::SequenceEqual[float]($Alpha,[float[]]$siteRecord.Alpha)){throw 'Site alpha changed across cases.'}
    for($index=0;$index -lt $totals.Length;$index++){$siteRecord.Totals[$index]+=$totals[$index]}
    $siteRecord.TotalFrames+=$frameCount
    $Study.Observations.Add([pscustomobject]@{Case=$CaseName;Site=$Site;Frames=$Frames;CompleteFrames=$frameCount;
        BoundaryRows=($Frames%$positions);Path=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash})
}

function Complete-KokoroLockStructureStudy {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Study)
    # A is one pooled, fixed pattern per site/channel/seat across all measured
    # cases. B is mean_seat(phase-A) for each channel/frame. Shares are ordered
    # energy reductions: A, then B, then the remaining residual; they sum to one.
    foreach($siteRecord in $Study.Sites.Values){
        $bias=[float[]]::new($siteRecord.Totals.Length)
        for($index=0;$index -lt $bias.Length;$index++){$bias[$index]=[float]($siteRecord.Totals[$index]/$siteRecord.TotalFrames)}
        $Study.Biases.Add($siteRecord.Name,[double[]]$bias)
        $raw=[byte[]]::new(4*$bias.Length);[Buffer]::BlockCopy($bias,0,$raw,0,$raw.Length)
        [IO.File]::WriteAllBytes((Join-Path $Study.Directory ($siteRecord.Name+'.fixed-bias.f32')),$raw)
    }
    $rows=[Collections.Generic.List[object]]::new()
    foreach($observation in $Study.Observations){
        $siteRecord=$Study.Sites[$observation.Site]
        if((Get-FileHash -LiteralPath $observation.Path).Hash -cne $observation.SHA256){throw 'Observed input integrity differs.'}
        $raw=[IO.File]::ReadAllBytes($observation.Path);$values=[float[]]::new($raw.Length/4);[Buffer]::BlockCopy($raw,0,$values,0,$raw.Length)
        $changes=[double[]]::new($siteRecord.Channels*($observation.CompleteFrames-1))
        $energies=$Study.Analyze.Invoke($values,[float[]]$siteRecord.Alpha,[int]$observation.Frames,[int]$siteRecord.Positions,$Study.Biases[$observation.Site],$changes)
        if($energies[0] -le 0 -or -not [double]::IsFinite($energies[0])){throw 'Invalid measured phase energy.'}
        $siteRecord.Changes.Add($changes)
        [Array]::Sort($changes);$middle=[int][Math]::Floor($changes.Length/2)
        $median=if($changes.Length%2){$changes[$middle]}else{($changes[$middle-1]+$changes[$middle])/2}
        $shares=[double[]]@((($energies[0]-$energies[1])/$energies[0]),(($energies[1]-$energies[2])/$energies[0]),($energies[2]/$energies[0]))
        $dominant=if($shares[0] -ge $shares[1] -and $shares[0] -ge $shares[2]){'FixedSeatBias'}elseif($shares[1] -ge $shares[2]){'ChannelFrameLock'}else{'Residual'}
        $rows.Add([pscustomobject]@{Case=$observation.Case;Site=$observation.Site;Channels=$siteRecord.Channels;Positions=$siteRecord.Positions;
            CompleteFrames=$observation.CompleteFrames;BoundaryRows=$observation.BoundaryRows;Energy=$energies[0];AfterBiasEnergy=$energies[1];ResidualEnergy=$energies[2];
            FixedBiasShare=$shares[0];ChannelFrameShare=$shares[1];ResidualShare=$shares[2];Dominant=$dominant;
            MedianAbsFrameDeltaRadians=$median;P99AbsFrameDeltaRadians=$changes[[int][Math]::Ceiling(0.99*$changes.Length)-1];
            StreamPhaseBytesPerAudioSecond=(80L*4*$siteRecord.Channels);PerSeatPhaseBytesPerAudioSecond=(80L*4*$siteRecord.Channels*$siteRecord.Positions);
            RuntimeSite=$observation.Site.StartsWith('generator.resblocks.',[StringComparison]::Ordinal)})
    }
    $rows.ToArray() | Export-Clixml -LiteralPath (Join-Path $Study.Directory 'per-case-site.clixml')
    $rows.ToArray() | Export-Csv -LiteralPath (Join-Path $Study.Directory 'per-case-site.csv')
    $Study.Observations.ToArray() | Export-Clixml -LiteralPath (Join-Path $Study.Directory 'observations.clixml')
    $aggregates=foreach($siteRecord in $Study.Sites.Values){
        $siteRows=@($rows | Where-Object Site -CEQ $siteRecord.Name)
        $energy=[double]($siteRows | Measure-Object Energy -Sum).Sum
        $after=[double]($siteRows | Measure-Object AfterBiasEnergy -Sum).Sum
        $remaining=[double]($siteRows | Measure-Object ResidualEnergy -Sum).Sum
        $allChanges=[Collections.Generic.List[double]]::new()
        foreach($changeArray in $siteRecord.Changes){$allChanges.AddRange($changeArray)}
        $allChanges.Sort();$middle=[int][Math]::Floor($allChanges.Count/2)
        $fixedShare=($energy-$after)/$energy;$frameShare=($after-$remaining)/$energy;$remainingShare=$remaining/$energy
        [pscustomobject]@{Site=$siteRecord.Name;Cases=$siteRows.Count;FixedBiasShare=$fixedShare;ChannelFrameShare=$frameShare;ResidualShare=$remainingShare;
            Dominant=$(if($fixedShare -ge $frameShare -and $fixedShare -ge $remainingShare){'FixedSeatBias'}elseif($frameShare -ge $remainingShare){'ChannelFrameLock'}else{'Residual'});
            MedianAbsFrameDeltaRadians=$(if($allChanges.Count%2){$allChanges[$middle]}else{($allChanges[$middle-1]+$allChanges[$middle])/2});
            P99AbsFrameDeltaRadians=$allChanges[[int][Math]::Ceiling(0.99*$allChanges.Count)-1]}
    }
    $aggregates | Export-Csv -LiteralPath (Join-Path $Study.Directory 'per-site.csv')
    $aggregates | Export-Clixml -LiteralPath (Join-Path $Study.Directory 'per-site.clixml')
    # Raw inputs already preserve every delta's provenance. Keep live sorting
    # arrays transient rather than serializing them with resumable study state.
    foreach($siteRecord in $Study.Sites.Values){$siteRecord.Changes.Clear()}
    return $rows.ToArray()
}

function Import-KokoroLockStructureStudy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatePath)
    $saved=Import-Clixml -LiteralPath $StatePath
    $kernelPath=Join-Path $saved.Directory 'Kokoro.LockStructure.dll'
    if((Get-FileHash -LiteralPath $kernelPath).Hash -cne $saved.AssemblySHA256){throw 'Study assembly integrity differs.'}
    $kernel=[Reflection.Assembly]::LoadFrom($kernelPath).GetType('KokoroLockStructureMath',$true)
    $study=[pscustomobject]@{Directory=$saved.Directory;SourceSHA256=$saved.SourceSHA256;AssemblySHA256=$saved.AssemblySHA256;
        Totals=$kernel.GetMethod('SeatTotals').CreateDelegate([Func[float[],float[],int,int,double[]]]);
        Analyze=$kernel.GetMethod('Analyze').CreateDelegate([Func[float[],float[],int,int,double[],double[],double[]]]);
        Apply=$kernel.GetMethod('ApplySplit').CreateDelegate([Func[float[],float[],int,int,double[],float[]]]);
        Sites=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);
        Observations=[Collections.Generic.List[object]]::new();Biases=[Collections.Generic.Dictionary[string,double[]]]::new([StringComparer]::Ordinal)}
    foreach($name in $saved.Sites.Keys){
        $record=$saved.Sites[$name]
        $study.Sites.Add($name,[pscustomobject]@{Name=$record.Name;Alpha=[float[]]$record.Alpha;Channels=[int]$record.Channels;Positions=[int]$record.Positions;
            TotalFrames=[long]$record.TotalFrames;Totals=[double[]]$record.Totals;Changes=[Collections.Generic.List[double[]]]::new()})
    }
    foreach($observation in $saved.Observations){$study.Observations.Add($observation)}
    foreach($name in $saved.Biases.Keys){$study.Biases.Add($name,[double[]]$saved.Biases[$name])}
    return $study
}

Export-ModuleMember -Function New-KokoroGeneratorLockTables, Invoke-KokoroGeneratorLockReference, New-KokoroLockStructureStudy, Add-KokoroLockStructureObservation, Complete-KokoroLockStructureStudy, Import-KokoroLockStructureStudy
