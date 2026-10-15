#requires -Version 7.7
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Numeric work is lowered from these PowerShell classes. Libraries select real
# occurrences; sums below evaluate total squared differences, never centroids.
class KokoroStudentMath {
    static [short[]] Pcm16([float[]] $samples) {
        $result=[short[]]::new($samples.Length)
        for($i=0;$i -lt $samples.Length;$i++) {
            if(-not [float]::IsFinite($samples[$i])) { throw [ArgumentException]::new('Nonfinite PCM.') }
            $value=[Math]::Round([double]$samples[$i]*32768.0)
            $result[$i]=[short][Math]::Clamp($value,-32768.0,32767.0)
        }
        return $result
    }
    static [float[]] PcmFloat([short[]] $samples) {
        $result=[float[]]::new($samples.Length)
        for($i=0;$i -lt $samples.Length;$i++) { $result[$i]=[float]([double]$samples[$i]/32768.0) }
        return $result
    }
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
            $squaredError=[double]0;$medoidBase=$medoid*512
            for ($at=$firstAt; $at -lt $lastAt; $at++) {
                $base=$this.Order[$at]*512
                for ($channel=0; $channel -lt 512; $channel++) {
                    $direction=[double]$this.Vectors[$base+$channel]-[double]$this.Vectors[$base-512+$channel]
                    $selected=[double]$this.Vectors[$medoidBase+$channel]-[double]$this.Vectors[$medoidBase-512+$channel]
                    $difference=$direction-$selected;$squaredError+=$difference*$difference
                }
            }
            $this.Medoids[$group]=$medoid;$this.Energy[$group]=$signal;$this.Errors[$group]=$squaredError;$this.Completed=$group-$this.First+1
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
    $selectedGroups=[Collections.Generic.List[object]]::new();foreach($pairName in $pairNames){$selectedGroups.Add($bank.PairGroups[$pairName])}
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

function Write-KokoroStudentWave {
    param([string]$Path,[short[]]$Samples)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    $writer=[IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([int](36+2*$Samples.Length))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([int]16)
        $writer.Write([short]1);$writer.Write([short]1);$writer.Write([int]24000);$writer.Write([int]48000)
        $writer.Write([short]2);$writer.Write([short]16);$writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([int](2*$Samples.Length))
        $raw=[byte[]]::new(2*$Samples.Length);[Buffer]::BlockCopy($Samples,0,$raw,0,$raw.Length);$writer.Write($raw)
    } finally {$writer.Dispose();$stream.Dispose()}
    $header=[IO.File]::ReadAllBytes($Path)
    if($header.Length -ne 44+2*$Samples.Length -or [BitConverter]::ToInt16($header,20) -ne 1 -or [BitConverter]::ToInt32($header,24) -ne 24000){throw 'PCM16 WAV verification failed.'}
}

function Render-KokoroStudentCopy {
    [CmdletBinding()]
    param([string]$BankPath,[Parameter(Mandatory)][string]$OutputDirectory,[string]$MeasurementDirectory,
        [ValidateRange(2,64)][int]$Threads=4,[int[]]$Targets=(1..9))
    $root=Split-Path -Parent $PSScriptRoot
    if(-not $BankPath){$BankPath=Join-Path $root 'build/unit-bank'}
    if(-not $MeasurementDirectory){$MeasurementDirectory=Join-Path $root 'build/student-20261015-full'}
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh student directory under build/.'}
    if($Targets.Count -eq 0 -or @($Targets | Where-Object {$_ -lt 1 -or $_ -gt 9}).Count -or @($Targets | Select-Object -Unique).Count -ne $Targets.Count){throw 'Targets must be distinct members of 1..9.'}
    [void][IO.Directory]::CreateDirectory($out)
    $kernel=Get-KokoroStudentKernel $out;$null=Test-KokoroStudentKernel $kernel
    $studentMath=$kernel.Assembly.GetType('KokoroStudentMath',$true)
    $pcm16=$studentMath.GetMethod('Pcm16').CreateDelegate([Func[float[],short[]]])
    $pcmFloat=$studentMath.GetMethod('PcmFloat').CreateDelegate([Func[short[],float[]]])
    $testPcm=$pcm16.Invoke([float[]]@(-2,-1,0,0.5,1,2))
    if(-not [Linq.Enumerable]::SequenceEqual[short]($testPcm,[short[]]@(-32768,-32768,0,16384,32767,32767))){throw 'PCM16 saturation check failed.'}
    $sourcePath=Join-Path $root 'tools/Invoke-KokoroPrecomputedDecoder.ps1'
    $sourceHash=(Get-FileHash $sourcePath).Hash
    if($sourceHash -cne '8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257'){throw 'Offline reference source differs.'}
    $dll=Join-Path $root "build/precomputed-decoder-reopen-20261014/final-artifact-gate/$sourceHash/Kokoro.OfflineRender.dll"
    $dllHash=(Get-FileHash $dll).Hash
    if($dllHash -cne '446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D'){throw 'Offline reference assembly differs.'}
    $assembly=[Reflection.Assembly]::LoadFrom($dll);$mathType=$assembly.GetType('OfflineRenderMath',$true)
    $workerType=$assembly.GetType('OfflineConvolutionWorker',$true)
    $delegateTypes=@{
        FrameIndices=[Func[int,int,int,int,int,int,bool,int[]]];PackInputs=[Func[float[],int[],int,int,int,int,System.Runtime.Intrinsics.Vector128[float][]]]
        ActiveIndices=[Func[int[],int,bool[]]];FoldWeights=[Func[float[],float[],float[]]];Align=[Func[float[],int[],float[]]]
        AdaIn=[Func[float[],int,int,float[],float[],float[],float[],float[],float[]]];Leaky=[Func[float[],float,float[]]]
        Residual=[Func[float[],float[],float,float[]]];Nearest2=[Func[float[],int,int,float[]]];Snake=[Func[float[],float[],int,float[]]]
        Average3=[Func[float[],float[],float[],float[]]];ReflectLeft=[Func[float[],int,int,float[]]];Draws=[Func[int,int,float[]]]
        Harmonic=[Func[float[],float[],float[],float[],float[],float[],float[]]];Stft=[Func[float[],float[]]];InverseStft=[Func[float[],int,float[]]]
        Compare=[Func[float[],float[],double[]]];MeasureLevels=[Func[float[],int,int,int[],double[]]];ScaleFrames=[Func[int[],int,int[]]]
        ApplyLevels=[Func[float[],int,int,float[],float[],float[],float[],float[],double[],float[]]]
    }
    foreach($delegateName in $delegateTypes.Keys){Set-Variable -Name $delegateName -Value ($mathType.GetMethod($delegateName).CreateDelegate($delegateTypes[$delegateName]))}
    $experiment=$assembly.GetType('OfflineExperimentMath',$true)
    $encoderSlice=$experiment.GetMethod('EncoderSlice').CreateDelegate([Func[short[],float[],int,int,int,float[]]])
    $halfSlice=$experiment.GetMethod('HalfSlice').CreateDelegate([Func[ushort[],int,int,float[]]])
    $durationsSlice=$experiment.GetMethod('Durations').CreateDelegate([Func[short[],int,int,int[]]])
    $offsetsFor=$experiment.GetMethod('Offsets').CreateDelegate([Func[int[],int[]]])
    $tokens=$null;$parseErrors=$null
    $referenceAst=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Offline source parse failed.'}
    foreach($functionName in 'Read-OfflineWeight','Get-OfflineConvolution','Invoke-OfflineConv','Invoke-OfflineAdaIn','Join-OfflineChannels','Invoke-OfflineDecoderBlock','Invoke-OfflineDecoder','Invoke-OfflineGeneratorBlock','Invoke-OfflineGenerator','New-OfflineDraws'){
        $definition=$referenceAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName},$false)
        if($null -eq $definition){throw "Missing reference function $functionName"}
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function Test-OfflineNode([string]$Name,[float[]]$Values) {}
    $Mode='Gate';$Seed=17;$levelContext=$null
    $profile=[Collections.Generic.List[object]]::new()
    $weightCache=[Collections.Generic.Dictionary[string,float[]]]::new([StringComparer]::Ordinal)
    $convolutionCache=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $torch=Import-Module (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1') -PassThru
    $reader=$torch.Invoke({[pscustomobject]@{Read=$read;Bytes=$bytes;ReadTensor=$readTensor;TensorRow=$tensorRow}})[0]
    $modelRoot=Join-Path $root 'build/inputs/kokoro/f3ff3571791e39611d31c381e3a41a3af07b4987'
    $modelPath=Join-Path $modelRoot 'kokoro-v1_0.pth'
    if((Get-FileHash $modelPath).Hash -cne '496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4'){throw 'Checkpoint integrity differs.'}
    $checkpoint=& $reader.Read $modelPath
    $voiceArchive=& $reader.ReadTensor (Join-Path $modelRoot 'voices/af_heart.pt') '0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF'
    $rowBytes=& $reader.TensorRow $voiceArchive 25;$style=[float[]]::new(128);[Buffer]::BlockCopy($rowBytes,0,$style,0,512)
    $measurement=Import-Clixml (Join-Path $MeasurementDirectory 'structure.clixml')
    $orderPath=Join-Path $BankPath 'order.json'
    if((Get-FileHash $orderPath).Hash -cne $measurement.OrderSHA256 -or $measurement.Units -ne 2429833 -or $measurement.K -ne 4){throw 'Full-bank measurement identity differs.'}
    $nearestPath=Join-Path $MeasurementDirectory 'nearest.i32'
    if((Get-FileHash $nearestPath).Hash -cne '70DFD110F8B8E2A8EBDFC2507357727F04BAB0E2A974E51E340E1A9EE8D914AA'){throw 'Measured nearest IDs differ.'}
    $nearestRaw=[IO.File]::ReadAllBytes($nearestPath);$nearest=[int[]]::new($nearestRaw.Length/4);[Buffer]::BlockCopy($nearestRaw,0,$nearest,0,$nearestRaw.Length)
    $sentences=@(Get-Content -LiteralPath $orderPath -Raw | ConvertFrom-Json)
    $prefix=[int[]]::new($sentences.Count+1)
    for($sentence=0;$sentence -lt $sentences.Count;$sentence++){$prefix[$sentence+1]=$prefix[$sentence]+$sentences[$sentence].phonemes.Length+2}
    if($prefix[$sentences.Count] -ne $measurement.Units){throw 'Bank unit numbering differs.'}
    $selection=Import-Clixml (Join-Path $root 'build/precomputed-decoder-20261014/selection.clixml')
    $needed=[Collections.Generic.HashSet[int]]::new();$chosen=[Collections.Generic.List[object]]::new()
    foreach($target in $Targets){
        $pick=$selection.picks[$target-1];$ids=[int[]]::new($pick.path.Count);$copyIds=[int[]]::new($ids.Length)
        for($token=0;$token -lt $ids.Length;$token++){
            $unit=$pick.path[$token];$ids[$token]=$prefix[[int]$unit.s]+[int]$unit.i;$copyIds[$token]=$nearest[$ids[$token]*4]
            if($copyIds[$token] -lt 0 -or $copyIds[$token] -eq $ids[$token]){throw 'Missing other exemplar.'}
            [void]$needed.Add($ids[$token]);[void]$needed.Add($copyIds[$token])
        }
        $chosen.Add([pscustomobject]@{Target=$target;Text=$pick.text;OriginalIds=$ids;CopyIds=$copyIds})
    }
    $byChunk=[Collections.Generic.Dictionary[int,object]]::new()
    foreach($id in $needed){
        $sentence=[Array]::BinarySearch($prefix,$id);if($sentence -lt 0){$sentence=-$sentence-2}
        $chunk=[int][Math]::Floor($sentence/1000.0)
        if(-not $byChunk.ContainsKey($chunk)){$byChunk.Add($chunk,[Collections.Generic.List[object]]::new())}
        $byChunk[$chunk].Add([pscustomobject]@{Id=$id;Sentence=$sentence;Token=$id-$prefix[$sentence]})
    }
    $provenance=@(Import-Clixml (Join-Path $MeasurementDirectory 'bank-provenance.clixml'))
    $units=[Collections.Generic.Dictionary[int,object]]::new()
    foreach($chunk in @($byChunk.Keys | Sort-Object)){
        $chunkPath=Join-Path $BankPath ('chunk-{0:D4}.npz' -f $chunk)
        $pin=@($provenance | Where-Object { [IO.Path]::GetFileName($_.Path) -ceq [IO.Path]::GetFileName($chunkPath) })
        if($pin.Count -ne 1 -or (Get-FileHash $chunkPath).Hash -cne $pin[0].SHA256){throw 'Bank chunk differs from measurement.'}
        Write-Host "Student COPY: reading chunk $chunk"
        $zip=[IO.Compression.ZipFile]::OpenRead($chunkPath)
        try {
            $encoded=Read-KokoroStudentNpy $zip t_en '<i2' ([short]);$scales=Read-KokoroStudentNpy $zip scale '<f4' ([float])
            $tokenOffsets=Read-KokoroStudentNpy $zip tok_off '<i8' ([long]);$frameOffsets=Read-KokoroStudentNpy $zip frm_off '<i8' ([long])
            $bankDurations=Read-KokoroStudentNpy $zip dur '<i2' ([short]);$pitchCodes=Read-KokoroStudentNpy $zip f0 '<f2' ([ushort]);$energyCodes=Read-KokoroStudentNpy $zip n '<f2' ([ushort])
            $allTokens=[int]($encoded.Length/512)
            foreach($record in $byChunk[$chunk]){
                $local=$record.Sentence%1000;$first=[int]$tokenOffsets[$local];$count=$prefix[$record.Sentence+1]-$prefix[$record.Sentence]
                $lengths=$durationsSlice.Invoke($bankDurations,$first,$count);$offsets=$offsetsFor.Invoke($lengths)
                $duration=$lengths[$record.Token];$frameFirst=[int](2*($frameOffsets[$local]+$offsets[$record.Token]))
                $units.Add($record.Id,[pscustomobject]@{Features=$encoderSlice.Invoke($encoded,$scales,$allTokens,$first+$record.Token,1);Duration=$duration;
                    Pitch=$halfSlice.Invoke($pitchCodes,$frameFirst,2*$duration);Energy=$halfSlice.Invoke($energyCodes,$frameFirst,2*$duration)})
            }
        } finally {$zip.Dispose()}
    }
    $chosen.ToArray() | Export-Clixml -LiteralPath (Join-Path $out 'copy-programs.clixml')
    $results=[Collections.Generic.List[object]]::new()
    foreach($case in $chosen){
        $tokenCount=$case.OriginalIds.Length;$originalEncoder=[float[]]::new(512*$tokenCount);$copyEncoder=[float[]]::new($originalEncoder.Length)
        $tokenDurations=[int[]]::new($tokenCount);$frameCount=0
        for($token=0;$token -lt $tokenCount;$token++){$tokenDurations[$token]=$units[$case.OriginalIds[$token]].Duration;$frameCount+=2*$tokenDurations[$token]}
        $pitch=[float[]]::new($frameCount);$energyCurve=[float[]]::new($frameCount);$frameAt=0
        for($token=0;$token -lt $tokenCount;$token++){
            $originalUnit=$units[$case.OriginalIds[$token]];$copyUnit=$units[$case.CopyIds[$token]]
            for($channel=0;$channel -lt 512;$channel++){$originalEncoder[$channel*$tokenCount+$token]=$originalUnit.Features[$channel];$copyEncoder[$channel*$tokenCount+$token]=$copyUnit.Features[$channel]}
            [Array]::Copy($originalUnit.Pitch,0,$pitch,$frameAt,$originalUnit.Pitch.Length);[Array]::Copy($originalUnit.Energy,0,$energyCurve,$frameAt,$originalUnit.Energy.Length);$frameAt+=$originalUnit.Pitch.Length
        }
        $random=New-OfflineDraws ($frameCount*300);$rendered=[Collections.Generic.List[object]]::new()
        foreach($variant in 'original','copy'){
            Write-Host "Student COPY target $($case.Target): $variant, $frameCount frames"
            $profile.Clear();$watch=[Diagnostics.Stopwatch]::StartNew()
            $encoder=if($variant -ceq 'original'){$originalEncoder}else{$copyEncoder}
            $decoded=Invoke-OfflineDecoder ($align.Invoke($encoder,$tokenDurations)) $pitch $energyCurve $style -TokenDurations $tokenDurations
            $pcm=Invoke-OfflineGenerator $decoded.Features $style $pitch $random.Uniform $random.Harmonic $random.Extra
            $watch.Stop();if($pcm.Length -ne $frameCount*300){throw 'Rendered PCM extent differs.'}
            $codes=$pcm16.Invoke($pcm);$path=Join-Path $out ('{0:D2}-{1}.wav' -f $case.Target,$variant)
            Write-KokoroStudentWave $path $codes
            $rendered.Add([pscustomobject]@{Pcm=$pcm;Codes=$codes;Milliseconds=$watch.Elapsed.TotalMilliseconds;Path=$path;SHA256=(Get-FileHash $path).Hash})
        }
        $floatMetrics=$compare.Invoke($rendered[1].Pcm,$rendered[0].Pcm)
        $pcmMetrics=$compare.Invoke($pcmFloat.Invoke($rendered[1].Codes),$pcmFloat.Invoke($rendered[0].Codes))
        $pair=[short[]]::new(2*$rendered[0].Codes.Length+14400)
        [Array]::Copy($rendered[0].Codes,0,$pair,0,$rendered[0].Codes.Length);[Array]::Copy($rendered[1].Codes,0,$pair,$rendered[0].Codes.Length+14400,$rendered[1].Codes.Length)
        $pairPath=Join-Path $out ('{0:D2}-original-then-copy.wav' -f $case.Target);Write-KokoroStudentWave $pairPath $pair
        $seconds=$frameCount/80.0
        $result=[pscustomobject]@{Target=$case.Target;Text=$case.Text;Tokens=$tokenCount;Frames=$frameCount;AudioSeconds=$seconds;FloatPcmSNR=$floatMetrics[0];Pcm16SNR=$pcmMetrics[0];PeakError=$floatMetrics[1];
            OriginalMs=$rendered[0].Milliseconds;CopyMs=$rendered[1].Milliseconds;OriginalMsPerAudioSecond=$rendered[0].Milliseconds/$seconds;CopyMsPerAudioSecond=$rendered[1].Milliseconds/$seconds;
            PairPath=$pairPath;PairSHA256=(Get-FileHash $pairPath).Hash;OriginalSHA256=$rendered[0].SHA256;CopySHA256=$rendered[1].SHA256;
            ReferenceSourceSHA256=$sourceHash;ReferenceKernelSHA256=$dllHash;StudentKernelSHA256=$kernel.SHA256;Threads=$Threads;Seed=$Seed;VoiceRow=25;
            Scope='Windows offline FP32 whole selected target decoder plus source/generator; live AdaIN, matched original durations/F0/N/style/noise; COPY only, no RESIDUAL';
            TimingDifference='Single offline host runs, original first; unlike SM8550 int8 DSP generator-only timing. Historical approximate reference 40 ms/audio-second, separate preserved run 41.918118, combined 46.867294.'}
        $results.Add($result);$results.ToArray() | Export-Clixml -LiteralPath (Join-Path $out 'copy-render.clixml')
        Write-Host "Student COPY target $($case.Target): PCM SNR $($result.Pcm16SNR) dB; $pairPath"
    }
    return $results.ToArray()
}

function Invoke-KokoroStudent {
    [CmdletBinding()]
    param([ValidateSet('Measure','Render')][string]$Step='Measure',[string]$BankPath,[Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateRange(1,64)][int]$Threads=4,[ValidateRange(1,16)][int]$K=4,[ValidateRange(0,1000000)][int]$SentenceLimit=0,
        [string]$MeasurementDirectory,[ValidateSet('CopyOnly')][string]$Replay='CopyOnly',[int[]]$Targets=(1..9))
    switch($Step){
        'Measure'{Measure-KokoroStudentStructure -BankPath $BankPath -OutputDirectory $OutputDirectory -Threads $Threads -K $K -SentenceLimit $SentenceLimit}
        'Render'{Render-KokoroStudentCopy -BankPath $BankPath -OutputDirectory $OutputDirectory -MeasurementDirectory $MeasurementDirectory -Threads $Threads -Targets $Targets}
    }
}

Export-ModuleMember -Function Invoke-KokoroStudent,Measure-KokoroStudentStructure
