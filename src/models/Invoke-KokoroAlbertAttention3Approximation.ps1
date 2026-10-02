#requires -Version 7.4
# FP32 oracle for the directly emitted three-token ALBERT attention region.
[CmdletBinding()]
param([Parameter(Mandatory)][float[]]$Qkv)
$ErrorActionPreference='Stop'
if($Qkv.Length -ne 6912){throw 'ALBERT attention3 requires fused QKV [3,2304].'}
foreach($value in $Qkv){if(-not [float]::IsFinite($value) -or [Math]::Abs($value) -gt 1024.0){throw 'ALBERT attention3 input is outside its finite bounded domain.'}}
$output=[float[]]::new(2304);$softmax=Join-Path $PSScriptRoot 'Invoke-KokoroAlbertShiftedSoftmax3.ps1';$scale=[float](1.0/[Math]::Sqrt(64.0))
for($head=0;$head -lt 12;$head++){
    for($query=0;$query -lt 3;$query++){
        $scores=[float[]]::new(3)
        for($key=0;$key -lt 3;$key++){
            $dot=[float]0.0
            for($dimension=0;$dimension -lt 64;$dimension++){
                $product=[float]($Qkv[$query*2304+$head*64+$dimension]*$Qkv[$key*2304+768+$head*64+$dimension])
                $dot=[float]($dot+$product)
            }
            $scores[$key]=[float]($dot*$scale)
        }
        $maximum=[Math]::Max($scores[0],[Math]::Max($scores[1],$scores[2]))
        $shifted=[float[]]@([float]($scores[0]-$maximum),[float]($scores[1]-$maximum),[float]($scores[2]-$maximum))
        $probabilities=& $softmax -ShiftedScores $shifted
        for($dimension=0;$dimension -lt 64;$dimension++){
            $v0=$Qkv[1536+$head*64+$dimension]
            $v1=$Qkv[3840+$head*64+$dimension]
            $v2=$Qkv[6144+$head*64+$dimension]
            $sum=[float]([float]($probabilities[0]*$v0)+[float]($probabilities[1]*$v1))
            $output[$query*768+$head*64+$dimension]=[float]($sum+[float]($probabilities[2]*$v2))
        }
    }
}
Write-Output -NoEnumerate $output
