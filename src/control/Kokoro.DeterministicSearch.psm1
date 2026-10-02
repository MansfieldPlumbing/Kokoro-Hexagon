#requires -Version 7.4
# Development-time deterministic candidate search. Evaluator is a trusted,
# author-supplied test callback; this module is not part of product inference.
Set-StrictMode -Version Latest

function Invoke-KokoroDeterministicSearch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Evaluate,
        [ValidateRange(-100000,100000)][double]$Initial,
        [ValidateRange(0.000001,100000)][double]$Step,
        [ValidateRange(-100000,100000)][double]$Minimum,
        [ValidateRange(-100000,100000)][double]$Maximum,
        [ValidateRange(4,128)][int]$MaxEvaluations=16,
        [ValidateRange(1,16)][int]$MaxBacktracks=1,
        [ValidateRange(1,3)][int]$WorsePatience=3)
    if($Minimum -ge $Maximum -or $Initial -lt $Minimum -or $Initial -gt $Maximum -or
       -not [double]::IsFinite($Initial) -or -not [double]::IsFinite($Step) -or
       -not [double]::IsFinite($Minimum) -or -not [double]::IsFinite($Maximum)){
        throw 'Search bounds are invalid.'
    }
    $read={param([double]$Coordinate)
        $value=& $Evaluate $Coordinate
        if($null -eq $value -or $value.PSObject.Properties['Score'] -eq $null -or
           $value.Score -isnot [double] -and $value.Score -isnot [float] -or
           -not [double]::IsFinite([double]$value.Score) -or $value.Score -lt 0 -or
           $value.Score -gt 1000000){throw 'Evaluator returned an invalid score.'}
        $value
    }
    $best=& $read $Initial
    $bestCoordinate=$Initial
    $first=$best
    $trials=[Collections.Generic.List[object]]::new()
    $visited=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$visited.Add($Initial.ToString('F8',[Globalization.CultureInfo]::InvariantCulture))
    $trials.Add([pscustomobject]@{Trial=0;Coordinate=$Initial;Delta=0.0;
        ParentCoordinate=$Initial;Score=[double]$best.Score;Decision='initial';
        ConsecutiveWorse=0;Step=$Step;EvaluatorResult=$best})
    $worse=0;$backtracks=0;$magnitude=1;$sign=-1;$proposals=0
    while($trials.Count -lt $MaxEvaluations -and $backtracks -lt $MaxBacktracks -and $proposals -lt 1024){
        $proposals++
        $parent=$bestCoordinate
        $candidate=[Math]::Round($parent+$sign*$magnitude*$Step,8)
        if($sign -lt 0){$sign=1}else{$sign=-1;$magnitude++}
        if($candidate -lt $Minimum -or $candidate -gt $Maximum){continue}
        $key=$candidate.ToString('F8',[Globalization.CultureInfo]::InvariantCulture)
        if(-not $visited.Add($key)){continue}
        $result=& $read $candidate
        $decision='worse'
        if($result.Score+1e-9 -lt $best.Score){
            $best=$result;$bestCoordinate=$candidate
            $worse=0;$magnitude=1;$sign=-1;$decision='improved'
        }else{
            $worse++
            if($worse -ge $WorsePatience){
                $backtracks++;$Step/=2;$worse=0;$magnitude=1;$sign=-1
                $decision='rollback_and_halve_step'
            }
        }
        $trials.Add([pscustomobject]@{Trial=$trials.Count;Coordinate=$candidate;
            Delta=($candidate-$parent);ParentCoordinate=$parent;Score=[double]$result.Score;
            Decision=$decision;ConsecutiveWorse=$worse;Step=$Step;EvaluatorResult=$result})
    }
    [pscustomobject]@{Initial=$first;Best=$best;BestCoordinate=$bestCoordinate;
        Backtracks=$backtracks;Evaluations=$trials.Count;Trials=$trials.ToArray();Proposals=$proposals}
}

Export-ModuleMember -Function Invoke-KokoroDeterministicSearch
