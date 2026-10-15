#requires -Version 7.7
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Numeric work is lowered from these PowerShell classes. Libraries select real
# occurrences; sums below evaluate total squared differences, never centroids.
class KokoroStudentMath {
    static [void] Expand([short[]] $quantized, [float[]] $scales, [int] $units, [float[]] $vectors, [int] $first, [double[]] $energy) {
        if ($quantized.Length -ne 512*$units -or $scales.Length -ne 512 -or $first -lt 0 -or $first+$units -gt $energy.Length -or $vectors.Length -ne 512*$energy.Length) { throw [ArgumentException]::new('Bank vector extent mismatch.') }
        for ($unit=0; $unit -lt $units; $unit++) {
            $sum=[double]0
            for ($channel=0; $channel -lt 512; $channel++) {
                $value=[float]([float]$quantized[$channel*$units+$unit]*$scales[$channel])
                if (-not [float]::IsFinite($value)) { throw [ArgumentException]::new('Nonfinite bank feature.') }
                $vectors[($first+$unit)*512+$channel]=$value
                $sum+=[double]$value*[double]$value
            }
            $energy[$first+$unit]=$sum
        }
    }
}

class KokoroStudentNearestWorker {
    [float[]] $Vectors
    [int[]] $Order
    [int[]] $Offsets
    [int[]] $UnitGroups
    [int[]] $Nearest
    [double[]] $Errors
    [int] $First
    [int] $Last
    [int] $K
    [int] $Completed
    [void] Run() {
        $bestIds=[int[]]::new($this.K);$bestErrors=[double[]]::new($this.K)
        for ($unit=$this.First; $unit -lt $this.Last; $unit++) {
            for ($rank=0; $rank -lt $this.K; $rank++) { $bestIds[$rank]=-1; $bestErrors[$rank]=[double]::PositiveInfinity }
            $group=$this.UnitGroups[$unit];$base=$unit*512
            for ($at=$this.Offsets[$group]; $at -lt $this.Offsets[$group+1]; $at++) {
                $candidate=$this.Order[$at]
                if ($candidate -eq $unit) { continue }
                $other=$candidate*512;$distance=[double]0
                for ($channel=0; $channel -lt 512; $channel++) {
                    $difference=[double]$this.Vectors[$base+$channel]-[double]$this.Vectors[$other+$channel]
                    $distance+=$difference*$difference
                    if ($distance -gt $bestErrors[$this.K-1]) { break }
                }
                if ($distance -gt $bestErrors[$this.K-1]) { continue }
                $insert=$this.K
                for ($rank=0; $rank -lt $this.K; $rank++) {
                    if ($distance -lt $bestErrors[$rank] -or ($distance -eq $bestErrors[$rank] -and ($bestIds[$rank] -lt 0 -or $candidate -lt $bestIds[$rank]))) { $insert=$rank; break }
                }
                if ($insert -lt $this.K) {
                    for ($rank=$this.K-1; $rank -gt $insert; $rank--) { $bestIds[$rank]=$bestIds[$rank-1];$bestErrors[$rank]=$bestErrors[$rank-1] }
                    $bestIds[$insert]=$candidate;$bestErrors[$insert]=$distance
                }
            }
            for ($rank=0; $rank -lt $this.K; $rank++) { $this.Nearest[$unit*$this.K+$rank]=$bestIds[$rank];$this.Errors[$unit*$this.K+$rank]=$bestErrors[$rank] }
            $this.Completed=$unit-$this.First+1
        }
    }
}

class KokoroStudentDirectionWorker {
    [float[]] $Vectors
    [int[]] $Order
    [int[]] $Offsets
    [int[]] $Medoids
    [double[]] $Energy
    [double[]] $Errors
    [int] $First
    [int] $Last
    [int] $Completed
    [void] Run() {
        for ($group=$this.First; $group -lt $this.Last; $group++) {
            $firstAt=$this.Offsets[$group];$lastAt=$this.Offsets[$group+1];$count=$lastAt-$firstAt
            $totals=[double[]]::new(512);$signal=[double]0
            for ($at=$firstAt; $at -lt $lastAt; $at++) {
                $base=$this.Order[$at]*512
                for ($channel=0; $channel -lt 512; $channel++) {
                    $direction=[double]$this.Vectors[$base+$channel]-[double]$this.Vectors[$base-512+$channel]
                    $totals[$channel]+=$direction;$signal+=$direction*$direction
                }
            }
            $best=[double]::PositiveInfinity;$medoid=-1
            for ($at=$firstAt; $at -lt $lastAt; $at++) {
                $candidate=$this.Order[$at];$base=$candidate*512;$norm=[double]0;$dot=[double]0
                for ($channel=0; $channel -lt 512; $channel++) {
                    $direction=[double]$this.Vectors[$base+$channel]-[double]$this.Vectors[$base-512+$channel]
                    $norm+=$direction*$direction;$dot+=$direction*$totals[$channel]
                }
                $score=[double]$count*$norm-[double]2*$dot
                if ($score -lt $best -or ($score -eq $best -and ($medoid -lt 0 -or $candidate -lt $medoid))) { $best=$score;$medoid=$candidate }
            }
            $error=[double]0;$medoidBase=$medoid*512
            for ($at=$firstAt; $at -lt $lastAt; $at++) {
                $base=$this.Order[$at]*512
                for ($channel=0; $channel -lt 512; $channel++) {
                    $direction=[double]$this.Vectors[$base+$channel]-[double]$this.Vectors[$base-512+$channel]
                    $selected=[double]$this.Vectors[$medoidBase+$channel]-[double]$this.Vectors[$medoidBase-512+$channel]
                    $difference=$direction-$selected;$error+=$difference*$difference
                }
            }
            $this.Medoids[$group]=$medoid;$this.Energy[$group]=$signal;$this.Errors[$group]=$error;$this.Completed=$group-$this.First+1
        }
    }
}

function Read-KokoroStudentNpy {
    param([IO.Compression.ZipArchive]$Archive,[string]$Name,[string]$DType,[type]$ElementType)
    # The preserved mine.ps1 NPY reader supplies the format. No bank entrypoint
    # is executed, and no preserved JSON is rewritten.
    $entry=$Archive.GetEntry($Name+'.npy')
    if($null -eq $entry -or $entry.Length -gt 1073741824){throw "Missing/oversized bank array: $Name"}
    $stream=$entry.Open();$memory=[IO.MemoryStream]::new()
    try{$stream.CopyTo($memory);$raw=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
    if($raw.Length -lt 10 -or $raw[0] -ne 147 -or [Text.Encoding]::ASCII.GetString($raw,1,5) -cne 'NUMPY' -or $raw[6] -ne 1){throw 'Unsupported NPY header.'}
    $headerLength=[BitConverter]::ToUInt16($raw,8);$offset=10+$headerLength
    if($offset -gt $raw.Length){throw 'Truncated NPY header.'}
    $header=[Text.Encoding]::ASCII.GetString($raw,10,$headerLength)
    if($header -cnotmatch "'descr': '$([regex]::Escape($DType))'" -or $header -cnotmatch "'fortran_order': False"){throw "Bank dtype/order mismatch: $Name"}
    $width=switch($ElementType.FullName){'System.Int16'{2};'System.UInt16'{2};'System.Single'{4};'System.Int64'{8};default{throw 'Unsupported bank element type.'}}
    if(($raw.Length-$offset)%$width){throw 'Incomplete native array.'}
    $values=[Array]::CreateInstance($ElementType,[int](($raw.Length-$offset)/$width))
    [Buffer]::BlockCopy($raw,$offset,$values,0,$raw.Length-$offset)
    return ,$values
}

function Get-KokoroStudentKernel {
    param([string]$Directory)
    $root=Split-Path -Parent $PSScriptRoot
    $compiler=Join-Path $root 'build/phonemizer/inputs/pslowering-1afabe056235a570da29e268824784557d4f6cdd'
    $pins=@(Import-Csv (Join-Path $compiler 'verified-source.tsv') -Delimiter "`t")
    if($pins.Count -ne 9){throw 'Incomplete pinned compiler.'}
    foreach($pin in $pins){if($pin.Commit -cne '1afabe056235a570da29e268824784557d4f6cdd' -or (Get-FileHash (Join-Path $compiler $pin.Path)).Hash -cne $pin.Sha256){throw 'Compiler integrity differs.'}}
    Import-Module (Join-Path $compiler 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1')
    $dll=Join-Path $Directory 'Kokoro.Student.dll'
    $null=Export-LoweredAssembly -SourcePath $PSCommandPath -ClassName KokoroStudentMath -OutputPath $dll -Deterministic
    $admission=Test-LoweredAssembly -AssemblyPath $dll
    if(-not $admission.ClrOnlyAdmitted){throw 'Student kernels reference SMA.'}
    $assembly=[Reflection.Assembly]::LoadFrom($dll)
    [pscustomobject]@{Assembly=$assembly;SHA256=(Get-FileHash $dll).Hash;
        Expand=$assembly.GetType('KokoroStudentMath',$true).GetMethod('Expand').CreateDelegate([Action[short[],float[],int,float[],int,double[]]]);
        NearestType=$assembly.GetType('KokoroStudentNearestWorker',$true);DirectionType=$assembly.GetType('KokoroStudentDirectionWorker',$true)}
}

function Get-KokoroStudentQuantiles {
    param([double[]]$Values)
    if($Values.Length -eq 0){throw 'Empty measurement population.'}
    $copy=[double[]]$Values.Clone();[Array]::Sort($copy)
    $middle=[int][Math]::Floor(($copy.Length-1)/2)
    [pscustomobject]@{Count=$copy.Length;Median=$copy[$middle];MedianRule='Lower observed rank';
        P10=$copy[[int][Math]::Ceiling(0.1*$copy.Length)-1];P90=$copy[[int][Math]::Ceiling(0.9*$copy.Length)-1]}
}

function Test-KokoroStudentKernel {
    param($Kernel)
    $quantized=[short[]]::new(1024);$quantized[0]=4;$quantized[1]=-8;$quantized[2]=2;$quantized[3]=6
    $scales=[float[]]::new(512);$scales[0]=[float]0.25;$scales[1]=[float]0.5
    $expanded=[float[]]::new(1536);$energy=[double[]]::new(3)
    $Kernel.Expand.Invoke($quantized,$scales,2,$expanded,1,$energy)
    if($expanded[512] -ne 1 -or $expanded[513] -ne 1 -or $expanded[1024] -ne -2 -or $expanded[1025] -ne 3 -or $energy[1] -ne 2 -or $energy[2] -ne 13){throw 'Bank dequantization/layout check failed.'}
    $vectors=[float[]]::new(5*512)
    $values=[float[]]@(0,1,3,6,9)
    for($unit=0;$unit -lt 5;$unit++){$vectors[$unit*512]=$values[$unit]}
    $worker=[Activator]::CreateInstance($Kernel.NearestType)
    $worker.Vectors=$vectors;$worker.Order=[int[]]@(0,1,2,3,4);$worker.Offsets=[int[]]@(0,5);$worker.UnitGroups=[int[]]::new(5)
    $worker.Nearest=[int[]]::new(10);$worker.Errors=[double[]]::new(10);$worker.First=0;$worker.Last=5;$worker.K=2
    $worker.Run()
    if(-not [Linq.Enumerable]::SequenceEqual[int]($worker.Nearest,[int[]]@(1,2,0,2,1,0,2,4,3,2)) -or
        -not [Linq.Enumerable]::SequenceEqual[double]($worker.Errors,[double[]]@(1,9,1,4,4,9,9,9,9,36))){throw 'Compiled nearest selection failed self-exclusion/distance/tie check.'}
    $direction=[Activator]::CreateInstance($Kernel.DirectionType)
    $direction.Vectors=$vectors;$direction.Order=[int[]]@(1,2,3,4);$direction.Offsets=[int[]]@(0,4)
    $direction.Medoids=[int[]]::new(1);$direction.Energy=[double[]]::new(1);$direction.Errors=[double[]]::new(1);$direction.First=0;$direction.Last=1
    $direction.Run()
    if($direction.Medoids[0] -ne 2 -or $direction.Energy[0] -ne 23 -or $direction.Errors[0] -ne 3){throw 'Compiled direction medoid differs from direct total squared differences.'}
    return $true
}

function Read-KokoroStudentBank {
    param([string]$BankPath,$Kernel,[int]$SentenceLimit=0)
    $orderPath=Join-Path $BankPath 'order.json'
    $sentences=@(Get-Content -LiteralPath $orderPath -Raw | ConvertFrom-Json -AsHashtable)
    if($SentenceLimit -gt 0){$sentences=@($sentences | Select-Object -First $SentenceLimit)}
    $total=0L;foreach($sentence in $sentences){$total+=$sentence.phonemes.Length+2}
    if($total -lt 2 -or $total -gt [int]::MaxValue/512){throw 'Unsupported bank vector extent.'}
    $count=[int]$total;$vectors=[float[]]::new(512*$count);$energy=[double[]]::new($count)
    $unitSentences=[int[]]::new($count);$unitTokens=[int[]]::new($count);$unitContexts=[int[]]::new($count);$unitPhones=[int[]]::new($count)
    $contexts=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $phones=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $contextGroups=[Collections.Generic.List[Collections.Generic.List[int]]]::new();$phoneGroups=[Collections.Generic.List[Collections.Generic.List[int]]]::new()
    $pairGroups=[Collections.Generic.Dictionary[string,Collections.Generic.List[int]]]::new([StringComparer]::Ordinal)
    $provenance=[Collections.Generic.List[object]]::new();$at=0;$sentenceAt=0
    foreach($chunk in Get-ChildItem -LiteralPath $BankPath -Filter 'chunk-*.npz' | Sort-Object Name){
        if($sentenceAt -ge $sentences.Count){break}
        if([int]$chunk.BaseName.Substring(6)*1000 -ne $sentenceAt){throw 'Bank chunk ordering differs.'}
        $zip=[IO.Compression.ZipFile]::OpenRead($chunk.FullName)
        try{
            $offsets=Read-KokoroStudentNpy $zip tok_off '<i8' ([long])
            $packed=Read-KokoroStudentNpy $zip t_en '<i2' ([short]);$scales=Read-KokoroStudentNpy $zip scale '<f4' ([float])
        }finally{$zip.Dispose()}
        $sourceCount=[int]$offsets[$offsets.Length-1];$take=[Math]::Min($offsets.Length-1,$sentences.Count-$sentenceAt)
        $takeUnits=[int]$offsets[$take]
        if($takeUnits -ne $sourceCount){
            $subset=[short[]]::new(512*$takeUnits)
            for($channel=0;$channel -lt 512;$channel++){[Array]::Copy($packed,$channel*$sourceCount,$subset,$channel*$takeUnits,$takeUnits)}
            $packed=$subset
        }
        $Kernel.Expand.Invoke($packed,$scales,$takeUnits,$vectors,$at,$energy)
        for($local=0;$local -lt $take;$local++){
            $padded='##<'+$sentences[$sentenceAt].phonemes+'>##';$length=[int]($offsets[$local+1]-$offsets[$local])
            if($length -ne $padded.Length-4){throw 'Bank phoneme/token alignment differs.'}
            for($token=0;$token -lt $length;$token++){
                $context=$padded.Substring($token+1,3);$phone=$padded.Substring($token+2,1)
                if(-not $contexts.ContainsKey($context)){$contexts.Add($context,$contextGroups.Count);$contextGroups.Add([Collections.Generic.List[int]]::new())}
                if(-not $phones.ContainsKey($phone)){$phones.Add($phone,$phoneGroups.Count);$phoneGroups.Add([Collections.Generic.List[int]]::new())}
                $contextId=$contexts[$context];$phoneId=$phones[$phone];$contextGroups[$contextId].Add($at);$phoneGroups[$phoneId].Add($at)
                $unitContexts[$at]=$contextId;$unitPhones[$at]=$phoneId;$unitSentences[$at]=$sentenceAt;$unitTokens[$at]=$token
                if($token -gt 0){$pair=$padded.Substring($token+1,2);if(-not $pairGroups.ContainsKey($pair)){$pairGroups.Add($pair,[Collections.Generic.List[int]]::new())};$pairGroups[$pair].Add($at)}
                $at++
            }
            $sentenceAt++
        }
        $provenance.Add([pscustomobject]@{Path=$chunk.FullName;SHA256=(Get-FileHash -LiteralPath $chunk.FullName).Hash;Sentences=$take;Units=$takeUnits})
        Write-Host "Student bank: $sentenceAt sentences, $at units"
    }
    if($at -ne $count -or $sentenceAt -ne $sentences.Count){throw 'Incomplete bank.'}
    [pscustomobject]@{PSTypeName='Kokoro.Student.Bank';Path=$BankPath;Vectors=$vectors;Energy=$energy;Count=$count;Sentences=$sentences;
        UnitSentences=$unitSentences;UnitTokens=$unitTokens;UnitContexts=$unitContexts;UnitPhones=$unitPhones;
        Contexts=$contexts;Phones=$phones;ContextGroups=$contextGroups;PhoneGroups=$phoneGroups;PairGroups=$pairGroups;
        Provenance=$provenance;OrderSHA256=(Get-FileHash -LiteralPath $orderPath).Hash}
}

function ConvertTo-KokoroStudentGroups {
    param([object[]]$Groups)
    $total=0;foreach($group in $Groups){$total+=$group.Count}
    $order=[int[]]::new($total);$offsets=[int[]]::new($Groups.Count+1);$at=0
    for($groupIndex=0;$groupIndex -lt $Groups.Count;$groupIndex++){$offsets[$groupIndex]=$at;foreach($unit in $Groups[$groupIndex]){$order[$at]=[int]$unit;$at++}}
    $offsets[$Groups.Count]=$at
    [pscustomobject]@{Order=$order;Offsets=$offsets}
}

function Wait-KokoroStudentWorkers {
    param([object[]]$Workers,[Threading.Tasks.Task[]]$Tasks,[string]$Stage)
    $watch=[Diagnostics.Stopwatch]::StartNew();$last=0.0
    while(-not [Threading.Tasks.Task]::WaitAll($Tasks,1000)){
        if($watch.Elapsed.TotalSeconds-$last -ge 20){$completed=0L;foreach($worker in $Workers){$completed+=$worker.Completed};Write-Host "Student $Stage : $completed completed";$last=$watch.Elapsed.TotalSeconds}
    }
    [Threading.Tasks.Task]::WaitAll($Tasks)
    return $watch.Elapsed.TotalMilliseconds
}

function Measure-KokoroStudentStructure {
    [CmdletBinding()]
    param([string]$BankPath,[Parameter(Mandatory)][string]$OutputDirectory,[ValidateRange(1,64)][int]$Threads=12,
        [ValidateRange(1,16)][int]$K=4,[ValidateRange(0,1000000)][int]$SentenceLimit=0)
    $root=Split-Path -Parent $PSScriptRoot
    if(-not $BankPath){$BankPath=Join-Path $root 'build/unit-bank'}
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh student directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    $kernel=Get-KokoroStudentKernel $out
    $null=Test-KokoroStudentKernel $kernel
    $bank=Read-KokoroStudentBank -BankPath $BankPath -Kernel $kernel -SentenceLimit $SentenceLimit
    $allGroups=[Collections.Generic.List[object]]::new()
    foreach($group in $bank.ContextGroups){$allGroups.Add($group)}
    foreach($group in $bank.PhoneGroups){$allGroups.Add($group)}
    $groups=ConvertTo-KokoroStudentGroups $allGroups.ToArray();$unitGroups=[int[]]::new($bank.Count);$fallback=0
    for($unit=0;$unit -lt $bank.Count;$unit++){
        $group=$bank.UnitContexts[$unit]
        if($bank.ContextGroups[$group].Count -lt 2){$group=$bank.ContextGroups.Count+$bank.UnitPhones[$unit];$fallback++}
        $unitGroups[$unit]=$group
    }
    $nearest=[int[]]::new($bank.Count*$K);$errors=[double[]]::new($nearest.Length)
    $workers=[Collections.Generic.List[object]]::new();$tasks=[Collections.Generic.List[Threading.Tasks.Task]]::new()
    for($index=0;$index -lt $Threads;$index++){
        $worker=[Activator]::CreateInstance($kernel.NearestType);$worker.Vectors=$bank.Vectors;$worker.Order=$groups.Order;$worker.Offsets=$groups.Offsets;$worker.UnitGroups=$unitGroups
        $worker.Nearest=$nearest;$worker.Errors=$errors;$worker.K=$K;$worker.First=[int][Math]::Floor($index*$bank.Count/[double]$Threads);$worker.Last=[int][Math]::Floor(($index+1)*$bank.Count/[double]$Threads)
        $workers.Add($worker);$tasks.Add([Threading.Tasks.Task]::Run($kernel.NearestType.GetMethod('Run').CreateDelegate([Action],$worker)))
    }
    $nearestMs=Wait-KokoroStudentWorkers $workers.ToArray() $tasks.ToArray() 'exemplars'
    $ratios=[double[]]::new($bank.Count);$missing=0
    for($unit=0;$unit -lt $bank.Count;$unit++){
        if($nearest[$unit*$K] -lt 0){$missing++;$ratios[$unit]=0}
        elseif($errors[$unit*$K] -eq 0){$ratios[$unit]=[double]::PositiveInfinity}
        else{$ratios[$unit]=$bank.Energy[$unit]/$errors[$unit*$K]}
    }
    $pairNames=@($bank.PairGroups.Keys | Where-Object {$bank.PairGroups[$_].Count -ge 20} | Sort-Object -CaseSensitive)
    $selectedGroups=[Collections.Generic.List[object]]::new();foreach($name in $pairNames){$selectedGroups.Add($bank.PairGroups[$name])}
    $directions=ConvertTo-KokoroStudentGroups $selectedGroups.ToArray();$medoids=[int[]]::new($pairNames.Count);$directionEnergy=[double[]]::new($pairNames.Count);$directionErrors=[double[]]::new($pairNames.Count)
    $workers.Clear();$tasks.Clear()
    for($index=0;$index -lt $Threads;$index++){
        $worker=[Activator]::CreateInstance($kernel.DirectionType);$worker.Vectors=$bank.Vectors;$worker.Order=$directions.Order;$worker.Offsets=$directions.Offsets
        $worker.Medoids=$medoids;$worker.Energy=$directionEnergy;$worker.Errors=$directionErrors;$worker.First=[int][Math]::Floor($index*$pairNames.Count/[double]$Threads);$worker.Last=[int][Math]::Floor(($index+1)*$pairNames.Count/[double]$Threads)
        $workers.Add($worker);$tasks.Add([Threading.Tasks.Task]::Run($kernel.DirectionType.GetMethod('Run').CreateDelegate([Action],$worker)))
    }
    $directionMs=Wait-KokoroStudentWorkers $workers.ToArray() $tasks.ToArray() 'directions'
    $covered=0L;$pairRows=@(for($index=0;$index -lt $pairNames.Count;$index++){
        $ratio=if($directionErrors[$index] -eq 0){[double]::PositiveInfinity}else{$directionEnergy[$index]/$directionErrors[$index]}
        $occurrences=$bank.PairGroups[$pairNames[$index]].Count
        if($ratio -gt 10){$covered+=$occurrences}
        [pscustomobject]@{Pair=$pairNames[$index];Occurrences=$occurrences;MedoidUnit=$medoids[$index];Energy=$directionEnergy[$index];Error=$directionErrors[$index];Ratio=$ratio}
    })
    foreach($arrayRecord in @(@('nearest.i32',$nearest),@('nearest-errors.f64',$errors),@('energy.f64',$bank.Energy))){
        $raw=[byte[]]::new([Buffer]::ByteLength($arrayRecord[1]));[Buffer]::BlockCopy($arrayRecord[1],0,$raw,0,$raw.Length);[IO.File]::WriteAllBytes((Join-Path $out $arrayRecord[0]),$raw)
    }
    $pairRows | Export-Clixml -LiteralPath (Join-Path $out 'directions.clixml');$pairRows | Export-Csv -LiteralPath (Join-Path $out 'directions.csv')
    $bank.Provenance.ToArray() | Export-Clixml -LiteralPath (Join-Path $out 'bank-provenance.clixml')
    $report=[pscustomobject]@{PSTypeName='Kokoro.Student.Structure';Units=$bank.Count;Sentences=$bank.Sentences.Count;Contexts=$bank.ContextGroups.Count;
        K=$K;FallbackUnits=$fallback;UnitsWithoutOtherExemplar=$missing;ExemplarRatio=(Get-KokoroStudentQuantiles $ratios);
        DirectionRatio=$(if($pairRows.Count){Get-KokoroStudentQuantiles ([double[]]$pairRows.Ratio)}else{$null});DirectionPairs=$pairRows.Count;
        PairCoveredUnits=$covered;PairCoveredBankShare=$covered/[double]$bank.Count;NearestMilliseconds=$nearestMs;DirectionMilliseconds=$directionMs;
        Distance='Squared difference of dequantized FP32 bank features, FP64 accumulation; same triphone, then phoneme fallback; self excluded';
        Medoid='Observed within-sentence direction minimizing total squared difference; counted sums only, no centroid';
        SourceSHA256=(Get-FileHash $PSCommandPath).Hash;KernelSHA256=$kernel.SHA256;OrderSHA256=$bank.OrderSHA256;Directory=$out}
    $report | Export-Clixml -LiteralPath (Join-Path $out 'structure.clixml')
    $script:StudentContext=[pscustomobject]@{Bank=$bank;Kernel=$kernel;Nearest=$nearest;Errors=$errors;Directions=$pairRows;K=$K;Report=$report}
    return $report
}

function Invoke-KokoroStudent {
    [CmdletBinding()]
    param([ValidateSet('Measure')][string]$Step='Measure',[string]$BankPath,[Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateRange(1,64)][int]$Threads=12,[ValidateRange(1,16)][int]$K=4,[ValidateRange(0,1000000)][int]$SentenceLimit=0)
    Measure-KokoroStudentStructure -BankPath $BankPath -OutputDirectory $OutputDirectory -Threads $Threads -K $K -SentenceLimit $SentenceLimit
}

Export-ModuleMember -Function Invoke-KokoroStudent,Measure-KokoroStudentStructure
