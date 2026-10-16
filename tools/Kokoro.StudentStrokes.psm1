#requires -Version 7.7
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Bounded offline experiment. These kernels contain no decoder or neural runtime.
class KokoroStrokeMath {
    static [float[]] Pack([float[]]$values) {
        if($values.Length%512 -ne 0){throw [ArgumentException]::new('Vector extent')}
        return $values
    }
    static [double] Dot([float[]]$left,[int]$a,[float[]]$right,[int]$b) {
        $sum=[double]0
        for($q=0;$q -lt 512;$q++){$sum+=[double]$left[$a+$q]*[double]$right[$b+$q]}
        return $sum
    }
    static [float[]] FrameMajor([float[]]$values,[int]$frames) {
        if($values.Length -ne 512*$frames){throw [ArgumentException]::new('Feature extent')}
        $result=[float[]]::new($values.Length)
        for($f=0;$f -lt $frames;$f++){for($c=0;$c -lt 512;$c++){$result[$f*512+$c]=$values[$c*$frames+$f]}}
        return $result
    }
    static [float[]] ChannelMajor([float[]]$values,[int]$first,[int]$frames) {
        if($first -lt 0 -or 512*($first+$frames) -gt $values.Length){throw [ArgumentException]::new('Feature slice')}
        $result=[float[]]::new(512*$frames)
        for($f=0;$f -lt $frames;$f++){for($c=0;$c -lt 512;$c++){$result[$c*$frames+$f]=$values[($first+$f)*512+$c]}}
        return $result
    }
    static [float[]] Pool([float[]]$states,[bool[]]$starts,[float[]]$baseState) {
        $frames=$starts.Length
        if($states.Length -ne 512*$frames -or $baseState.Length -ne 512){throw [ArgumentException]::new('Candidate extent')}
        $result=[float[]]::new(2*$states.Length)
        for($f=0;$f -lt $frames;$f++){for($c=0;$c -lt 512;$c++){
            $at=$f*512+$c;$result[$at]=[float]($states[$at]-$baseState[$c])
            if(-not $starts[$f]){$result[$states.Length+$at]=[float]($states[$at]-$states[$at-512])}
        }}
        return $result
    }
    static [double[]] Norms([float[]]$vectors) {
        if($vectors.Length%512 -ne 0){throw [ArgumentException]::new('Dictionary extent')}
        $n=[int]($vectors.Length/512);$result=[double[]]::new($n)
        for($i=0;$i -lt $n;$i++){$result[$i]=[KokoroStrokeMath]::Dot($vectors,$i*512,$vectors,$i*512);if(-not [double]::IsFinite($result[$i])){throw [ArithmeticException]::new('Nonfinite stroke norm')}}
        return $result
    }
    static [int[]] Select([float[]]$vectors,[int]$maximum) {
        $norms=[KokoroStrokeMath]::Norms($vectors);$covered=[double[]]::new($norms.Length);$blocked=[bool[]]::new($norms.Length)
        $selected=[System.Collections.Generic.List[int]]::new()
        for($k=0;$k -lt $maximum;$k++){
            $winner=-1;$best=[double]0
            for($i=0;$i -lt $norms.Length;$i++){if(-not $blocked[$i]){$score=[Math]::Max([double]0,$norms[$i]-$covered[$i]);if($score -gt $best){$best=$score;$winner=$i}}}
            if($winner -lt 0){break};$selected.Add($winner);$blocked[$winner]=$true
            for($i=0;$i -lt $norms.Length;$i++){
                if($blocked[$i] -or $norms[$i] -le [double]0){continue}
                $dot=[KokoroStrokeMath]::Dot($vectors,$i*512,$vectors,$winner*512);$square=$dot*$dot
                $projection=$square/$norms[$winner];if($projection -gt $covered[$i]){$covered[$i]=$projection}
                # Signed coefficients make opposite directions equivalent too.
                if($square -ge [double]0.9999*$norms[$i]*$norms[$winner]){$blocked[$i]=$true}
            }
        }
        return $selected.ToArray()
    }
    static [float[]] Replay([float[]]$baseState,[float[]]$dictionary,[int[]]$ids,[float[]]$coefficients,[int[]]$used,[int]$frames,[int]$group) {
        if($baseState.Length -ne 512 -or $dictionary.Length%512 -ne 0 -or $ids.Length -ne 16*$frames -or $coefficients.Length -ne 48*$frames -or $used.Length -ne 3*$frames -or $group -lt 0 -or $group -gt 2){throw [ArgumentException]::new('Stroke replay extent')}
        $result=[float[]]::new(512*$frames);$budget=4;if($group -eq 1){$budget=8};if($group -eq 2){$budget=16}
        for($f=0;$f -lt $frames;$f++){
            $count=$used[$group*$frames+$f];if($count -lt 0 -or $count -gt $budget){throw [ArgumentException]::new('Active stroke budget')}
            for($c=0;$c -lt 512;$c++){
                $value=$baseState[$c]
                for($slot=0;$slot -lt $count;$slot++){
                    $id=$ids[$f*16+$slot];if($id -lt 0 -or ($id+1)*512 -gt $dictionary.Length){throw [ArgumentException]::new('Stroke ID')}
                    $product=[float]($coefficients[($group*$frames+$f)*16+$slot]*$dictionary[$id*512+$c]);$value=[float]($value+$product)
                }
                if(-not [float]::IsFinite($value)){throw [ArithmeticException]::new('Nonfinite replay output')};$result[$f*512+$c]=$value
            }
        }
        return $result
    }
    static [double[]] Measure([float[]]$truth,[float[]]$candidate,[int]$truthFirst,[int]$candidateFirst,[int]$frames) {
        if($frames -lt 1 -or ($truthFirst+$frames)*512 -gt $truth.Length -or ($candidateFirst+$frames)*512 -gt $candidate.Length){throw [ArgumentException]::new('Measurement extent')}
        # Six values per channel: signal, error, peak, p10/median/p90 absolute error.
        # Then signal/error/peak for every frame. No nonfinite SNR sentinels.
        $result=[double[]]::new(3072+3*$frames)
        for($c=0;$c -lt 512;$c++){
            $errors=[double[]]::new($frames);$signal=[double]0;$error=[double]0;$peak=[double]0
            for($f=0;$f -lt $frames;$f++){
                $x=[double]$truth[($truthFirst+$f)*512+$c];$y=[double]$candidate[($candidateFirst+$f)*512+$c]
                if(-not [double]::IsFinite($x) -or -not [double]::IsFinite($y)){throw [ArithmeticException]::new('Nonfinite acoustic feature')}
                $difference=$x-$y;$square=$difference*$difference;$absolute=[Math]::Abs($difference)
                $signal+=$x*$x;$error+=$square;$peak=[Math]::Max($peak,$absolute);$errors[$f]=$absolute
                $at=3072+3*$f;$result[$at]+=$x*$x;$result[$at+1]+=$square;$result[$at+2]=[Math]::Max($result[$at+2],$absolute)
            }
            [Array]::Sort($errors);$at=6*$c
            $result[$at]=$signal;$result[$at+1]=$error;$result[$at+2]=$peak
            $result[$at+3]=$errors[[int][Math]::Floor([double]($frames-1)*0.1)];$result[$at+4]=$errors[[int][Math]::Floor([double]($frames-1)*0.5)];$result[$at+5]=$errors[[int][Math]::Floor([double]($frames-1)*0.9)]
        }
        return $result
    }
}

class KokoroStrokeGreedyWorker {
    KokoroStrokeGreedyWorker() {}
    [float[]]$Truth
    [float[]]$BaseState
    [float[]]$Dictionary
    [float[]]$Packed
    [double[]]$Norms
    [int]$First
    [int]$Count
    [float[]]$Snapshots
    [int[]]$Ids
    [float[]]$Coefficients
    [int[]]$Used
    [double[]]$Errors
    [double[]]$Signals
    [long]$DotProducts
    [long]$Applications
    [long]$RefinementDots
    [long]$RefinementAccepted
    [int]$RefinementSweeps
    [void] Run() {
        $frames=[int]($this.Truth.Length/512)
        for($f=$this.First;$f -lt $this.First+$this.Count;$f++){
            $current=[float[]]::new(512);$residual=[float[]]::new(512);$candidate=[float[]]::new(512)
            $error=[double]0;$signal=[double]0
            for($c=0;$c -lt 512;$c++){$x=$this.Truth[$f*512+$c];$current[$c]=$this.BaseState[$c];$residual[$c]=[float]($x-$current[$c]);$d=[double]$x-[double]$current[$c];$error+=$d*$d;$signal+=[double]$x*[double]$x}
            $activeIds=[int[]]::new(16);$activeCoefficients=[float[]]::new(16)
            $this.Signals[$f]=$signal;$usedCount=0;$finished=$false
            for($step=0;$step -lt 16;$step++){
                if(-not $finished){
                    $packedResidual=[KokoroStrokeMath]::Pack($residual);$winner=-1;$best=[double]0;$coefficient=[float]0
                    for($i=0;$i -lt $this.Norms.Length;$i++){
                        if($this.Norms[$i] -le [double]0){continue}
                        $already=$false;for($j=0;$j -lt $usedCount;$j++){if($activeIds[$j] -eq $i){$already=$true;break}}
                        if($already){continue}
                        $dot=[KokoroStrokeMath]::Dot($packedResidual,0,$this.Packed,$i*512);$this.DotProducts+=1L
                        $score=$dot*$dot/$this.Norms[$i]
                        if($score -gt $best){$best=$score;$winner=$i;$coefficient=[float]($dot/$this.Norms[$i])}
                    }
                    if($winner -lt 0){$finished=$true}else{
                        if(-not [float]::IsFinite($coefficient)){throw [ArithmeticException]::new('Nonfinite stroke coefficient')}
                        $nextError=[double]0
                        for($c=0;$c -lt 512;$c++){$product=[float]($coefficient*$this.Dictionary[$winner*512+$c]);$candidate[$c]=[float]($current[$c]+$product);if(-not [float]::IsFinite($candidate[$c])){throw [ArithmeticException]::new('Nonfinite stroke output')};$d=[double]$this.Truth[$f*512+$c]-[double]$candidate[$c];$nextError+=$d*$d}
                        if($nextError -ge $error){$finished=$true}else{
                            [Array]::Copy($candidate,$current,512);$error=$nextError
                            for($c=0;$c -lt 512;$c++){$residual[$c]=[float]($this.Truth[$f*512+$c]-$current[$c])}
                            $activeIds[$usedCount]=$winner;$activeCoefficients[$usedCount]=$coefficient;$this.Ids[$f*16+$usedCount]=$winner;$usedCount++;$this.Applications+=1L
                            # Ordered greedy one-scalar updates; no joint solve or fitted matrix.
                            $order=[int[]]::new($usedCount)
                            for($j=0;$j -lt $usedCount;$j++){$order[$j]=$j}
                            for($j=1;$j -lt $usedCount;$j++){$key=$order[$j];$k=$j-1;while($k -ge 0 -and $activeIds[$order[$k]] -gt $activeIds[$key]){$order[$k+1]=$order[$k];$k--};$order[$k+1]=$key}
                            for($sweep=0;$sweep -lt $this.RefinementSweeps;$sweep++){
                                $accepted=$false
                                for($j=0;$j -lt $usedCount;$j++){
                                    $slot=$order[$j];$id=$activeIds[$slot]
                                    $dot=[KokoroStrokeMath]::Dot($residual,0,$this.Packed,$id*512);$this.RefinementDots+=1L
                                    $oldCoefficient=$activeCoefficients[$slot];$delta=[float]($dot/$this.Norms[$id]);$updated=[float]($oldCoefficient+$delta)
                                    if($updated -eq $oldCoefficient){continue}
                                    if(-not [float]::IsFinite($updated)){throw [ArithmeticException]::new('Nonfinite refined coefficient')}
                                    $activeCoefficients[$slot]=$updated;$refinedError=[double]0
                                    for($c=0;$c -lt 512;$c++){
                                        $value=$this.BaseState[$c]
                                        for($k=0;$k -lt $usedCount;$k++){$product=[float]($activeCoefficients[$k]*$this.Dictionary[$activeIds[$k]*512+$c]);$value=[float]($value+$product)}
                                        if(-not [float]::IsFinite($value)){throw [ArithmeticException]::new('Nonfinite refined output')}
                                        $candidate[$c]=$value;$d=[double]$this.Truth[$f*512+$c]-[double]$value;$refinedError+=$d*$d
                                    }
                                    if($refinedError -lt $error){
                                        [Array]::Copy($candidate,$current,512);$error=$refinedError;$accepted=$true;$this.RefinementAccepted+=1L
                                        for($c=0;$c -lt 512;$c++){$residual[$c]=[float]($this.Truth[$f*512+$c]-$current[$c])}
                                    }else{$activeCoefficients[$slot]=$oldCoefficient}
                                }
                                if(-not $accepted){break}
                            }
                        }
                    }
                }
                $group=-1;if($step -eq 3){$group=0};if($step -eq 7){$group=1};if($step -eq 15){$group=2}
                if($group -ge 0){[Array]::Copy($current,0,$this.Snapshots,($group*$frames+$f)*512,512);[Array]::Copy($activeCoefficients,0,$this.Coefficients,($group*$frames+$f)*16,$usedCount);$this.Used[$group*$frames+$f]=$usedCount;$this.Errors[$group*$frames+$f]=$error}
            }
        }
    }
}

function New-KokoroStrokeKernel {
    param([string]$Directory)
    $root=Split-Path -Parent $PSScriptRoot;$compiler=Join-Path $root 'build/phonemizer/inputs/pslowering-1afabe056235a570da29e268824784557d4f6cdd'
    $pins=@(Import-Csv (Join-Path $compiler 'verified-source.tsv') -Delimiter "`t")
    if($pins.Count -ne 9){throw 'Incomplete pinned compiler.'}
    foreach($pin in $pins){if($pin.Commit -cne '1afabe056235a570da29e268824784557d4f6cdd' -or (Get-FileHash (Join-Path $compiler $pin.Path)).Hash -cne $pin.Sha256){throw 'Compiler integrity differs.'}}
    Import-Module (Join-Path $compiler 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1')
    $path=Join-Path $Directory 'Kokoro.StudentStrokes.dll'
    $null=Export-LoweredAssembly -SourcePath $PSCommandPath -ClassName KokoroStrokeMath -OutputPath $path -Deterministic
    $admission=Test-LoweredAssembly -AssemblyPath $path;if(-not $admission.ClrOnlyAdmitted){throw 'Stroke kernels reference SMA.'}
    $assembly=[Reflection.Assembly]::LoadFrom($path);$math=$assembly.GetType('KokoroStrokeMath',$true)
    [pscustomobject]@{Path=$path;SHA256=(Get-FileHash $path).Hash;Assembly=$assembly;WorkerType=$assembly.GetType('KokoroStrokeGreedyWorker',$true);
        Pack=$math.GetMethod('Pack').CreateDelegate([Func[float[],float[]]]);
        Norms=$math.GetMethod('Norms').CreateDelegate([Func[float[],double[]]]);
        Select=$math.GetMethod('Select').CreateDelegate([Func[float[],int,int[]]]);
        Pool=$math.GetMethod('Pool').CreateDelegate([Func[float[],bool[],float[],float[]]]);
        FrameMajor=$math.GetMethod('FrameMajor').CreateDelegate([Func[float[],int,float[]]]);
        ChannelMajor=$math.GetMethod('ChannelMajor').CreateDelegate([Func[float[],int,int,float[]]]);
        Replay=$math.GetMethod('Replay').CreateDelegate([Func[float[],float[],int[],float[],int[],int,int,float[]]])}
}

function Write-KokoroStrokeArray {
    param([string]$Path,[Array]$Values)
    if(Test-Path $Path){throw 'Stroke output already exists.'}
    $raw=[byte[]]::new([Buffer]::ByteLength($Values));[Buffer]::BlockCopy($Values,0,$raw,0,$raw.Length);[IO.File]::WriteAllBytes($Path,$raw)
    [pscustomobject]@{Path=$Path;Bytes=$raw.Length;SHA256=(Get-FileHash $Path).Hash}
}

function Read-KokoroStrokeLibrary {
    param([string]$Directory,$Kernel)
    $d=Import-Clixml (Join-Path $Directory 'stroke-library.clixml')
    if((Get-FileHash $d.LibraryPath).Hash -cne $d.LibrarySHA256){throw 'Global stroke library differs.'}
    $raw=[IO.File]::ReadAllBytes($d.LibraryPath)
    if($raw.Length -ne 2112+2060*$d.Strokes -or [Text.Encoding]::ASCII.GetString($raw,0,8) -cne 'KHSTROK1' -or [BitConverter]::ToUInt32($raw,12) -ne 512 -or [BitConverter]::ToUInt32($raw,16) -ne $d.Strokes){throw 'Global stroke binary layout differs.'}
    $baseState=[float[]]::new(512);$dictionary=[float[]]::new(512*$d.Strokes)
    [Buffer]::BlockCopy($raw,64,$baseState,0,2048);[Buffer]::BlockCopy($raw,2112,$dictionary,0,4*$dictionary.Length)
    [pscustomobject]@{Description=$d;BaseState=$baseState;Dictionary=$dictionary;Packed=$Kernel.Pack.Invoke($dictionary);Norms=$Kernel.Norms.Invoke($Kernel.Pack.Invoke($dictionary))}
}

function Get-KokoroStrokeQuantiles {
    param([double[]]$Values)
    if(-not $Values.Length){return $null}
    $sorted=[double[]]$Values.Clone();[Array]::Sort($sorted);$n=$sorted.Length-1
    [pscustomobject]@{Count=$Values.Length;P10=$sorted[[int][Math]::Floor(0.1*$n)];Median=$sorted[[int][Math]::Floor(0.5*$n)];P90=$sorted[[int][Math]::Floor(0.9*$n)];Minimum=$sorted[0];Maximum=$sorted[-1];Rule='Lower observed rank'}
}

function Get-KokoroStrokeFrameContext {
    param($Record)
    $durations=Read-KokoroStrokeArray $Record.Durations ([int]) 4
    if($durations.Length -ne $Record.Phonemes.Length+2){throw 'Stroke phoneme alignment differs.'}
    $tokens=[int[]]::new($Record.Frames);$positions=[float[]]::new($Record.Frames);$classes=[byte[]]::new($Record.Frames);$boundary=[bool[]]::new($Record.Frames);$joins=[bool[]]::new($Record.Frames)
    $pick=$null
    if($Record.Kind -ceq 'ExistingSelectedBankReference'){$root=Split-Path -Parent $PSScriptRoot;$selection=Import-Clixml (Join-Path $root 'build/precomputed-decoder-20261014/selection.clixml');$pick=$selection.picks[[int]$Record.Name-1]}
    $at=0
    for($t=0;$t -lt $durations.Length;$t++){
        $length=2*$durations[$t];if($length -lt 1 -or $at+$length -gt $Record.Frames){throw 'Stroke duration extent differs.'}
        $symbol=if($t -eq 0 -or $t -eq $durations.Length-1){[char]0}else{$Record.Phonemes[$t-1]}
        $kind=[byte]0;if('AIOWYɑɔəæɛɜɪiʊuʌ'.IndexOf($symbol) -ge 0){$kind=1}elseif([char]::IsLetter($symbol)){$kind=2}
        for($f=0;$f -lt $length;$f++){$tokens[$at+$f]=$t;$positions[$at+$f]=[float](($f+0.5)/$length);$classes[$at+$f]=$kind}
        if($at -gt 0){$boundary[$at]=$true;$boundary[$at-1]=$true}
        if($null -ne $pick -and $t -gt 0){$a=$pick.path[$t-1];$b=$pick.path[$t];if($a.s -ne $b.s -or $b.i -ne $a.i+1){$joins[$at]=$true;$joins[$at-1]=$true}}
        $at+=$length
    }
    if($at -ne $Record.Frames){throw 'Stroke alignment does not cover all frames.'}
    [pscustomobject]@{Tokens=$tokens;Positions=$positions;Classes=$classes;Boundary=$boundary;Joins=$joins}
}

function Invoke-KokoroStrokeCeiling {
    param($Kernel,[object[]]$Records,[string]$LibraryDirectory,[string]$OutputDirectory,[int]$Threads)
    $library=Read-KokoroStrokeLibrary $LibraryDirectory $Kernel
    $cases=@($Records|Where-Object {-not $_.Training});if($cases.Count -ne 11){throw 'Ceiling requires eleven reproduced references.'}
    $frames=[int](($cases|Measure-Object Frames -Sum).Sum);$truth=[float[]]::new(512*$frames);$offsets=[int[]]::new($cases.Count+1);$at=0
    for($i=0;$i -lt $cases.Count;$i++){$r=$cases[$i];$x=Read-KokoroStrokeArray $r.Features ([float]) 4;$x=$Kernel.FrameMajor.Invoke($x,$r.Frames);[Array]::Copy($x,0,$truth,$at*512,$x.Length);$offsets[$i]=$at;$at+=$r.Frames};$offsets[-1]=$at
    $snapshots=[float[]]::new(3*$truth.Length);$ids=[int[]]::new(16*$frames);[Array]::Fill($ids,-1);$coefficients=[float[]]::new(3*$ids.Length);$used=[int[]]::new(3*$frames);$errors=[double[]]::new(3*$frames);$signals=[double[]]::new($frames)
    $workers=[Collections.Generic.List[object]]::new();$tasks=[Collections.Generic.List[Threading.Tasks.Task]]::new();$watch=[Diagnostics.Stopwatch]::StartNew()
    for($part=0;$part -lt $Threads;$part++){
        $first=[int][Math]::Floor($part*$frames/[double]$Threads);$end=[int][Math]::Floor(($part+1)*$frames/[double]$Threads)
        $w=[Activator]::CreateInstance($Kernel.WorkerType);$w.Truth=$truth;$w.BaseState=$library.BaseState;$w.Dictionary=$library.Dictionary;$w.Packed=$library.Packed;$w.Norms=$library.Norms;$w.First=$first;$w.Count=$end-$first
        $w.Snapshots=$snapshots;$w.Ids=$ids;$w.Coefficients=$coefficients;$w.Used=$used;$w.Errors=$errors;$w.Signals=$signals
        $w.RefinementSweeps=8
        $action=$Kernel.WorkerType.GetMethod('Run').CreateDelegate([Action],$w);$workers.Add($w);$tasks.Add([Threading.Tasks.Task]::Run($action))
    }
    [Threading.Tasks.Task]::WaitAll($tasks.ToArray());$watch.Stop()
    $measure=$Kernel.Assembly.GetType('KokoroStrokeMath',$true).GetMethod('Measure').CreateDelegate([Func[float[],float[],int,int,int,double[]]])
    $summaries=[Collections.Generic.List[object]]::new();$allChannels=[Collections.Generic.List[object]]::new();$allFrames=[Collections.Generic.List[object]]::new();$utilization=[Collections.Generic.List[object]]::new()
    for($group=0;$group -lt 3;$group++){
        $budget=[int](@(4,8,16)[$group]);$globalCounts=[int[]]::new($library.Description.Strokes);$sentenceCounts=[int[]]::new($globalCounts.Length)
        for($i=0;$i -lt $cases.Count;$i++){
            $r=$cases[$i];$first=$offsets[$i];$context=Get-KokoroStrokeFrameContext $r;$stats=$measure.Invoke($truth,$snapshots,$first,$group*$frames+$first,$r.Frames)
            $caseUsed=[Collections.Generic.HashSet[int]]::new();$snrs=[Collections.Generic.List[double]]::new();$normalized=[double[]]::new($r.Frames);$squared=[double[]]::new($r.Frames);$actual=[double[]]::new($r.Frames)
            $signalTotal=0.0;$errorTotal=0.0;$peak=0.0;$boundaryError=0.0;$boundarySignal=0.0;$boundaryCount=0;$joinError=0.0;$joinSignal=0.0;$joinCount=0
            for($f=0;$f -lt $r.Frames;$f++){
                $j=3072+3*$f;$signal=$stats[$j];$error=$stats[$j+1];$signalTotal+=$signal;$errorTotal+=$error;$peak=[Math]::Max($peak,$stats[$j+2]);$squared[$f]=$error
                $normalized[$f]=if($signal -gt 0){[Math]::Sqrt($error/$signal)}else{[Math]::Sqrt($error/512)}
                $snr=$null;if($signal -gt 0 -and $error -gt 0){$snr=10*[Math]::Log10($signal/$error);$snrs.Add($snr)}
                $n=$used[$group*$frames+$first+$f];$actual[$f]=$n
                $frameIds=[Collections.Generic.HashSet[int]]::new()
                for($slot=0;$slot -lt $n;$slot++){$id=$ids[($first+$f)*16+$slot];$globalCounts[$id]++;[void]$caseUsed.Add($id);[void]$frameIds.Add($id)}
                if($context.Boundary[$f]){$boundaryCount++;$boundaryError+=$error;$boundarySignal+=$signal}
                if($context.Joins[$f]){$joinCount++;$joinError+=$error;$joinSignal+=$signal}
                $allFrames.Add([pscustomobject]@{Case=$r.Name;Budget=$budget;Frame=$f;Token=$context.Tokens[$f];WithinToken=$context.Positions[$f];SNR=$snr;SquaredError=$error;NormalizedRmsError=$normalized[$f];PeakError=$stats[$j+2];Strokes=$n;UniqueStrokes=$frameIds.Count;TokenBoundary=$context.Boundary[$f];UnitJoin=$context.Joins[$f]})
            }
            foreach($id in $caseUsed){$sentenceCounts[$id]++}
            for($c=0;$c -lt 512;$c++){$j=6*$c;$allChannels.Add([pscustomobject]@{Case=$r.Name;Budget=$budget;Channel=$c;SignalEnergy=$stats[$j];SquaredError=$stats[$j+1];PeakError=$stats[$j+2];AbsP10=$stats[$j+3];AbsMedian=$stats[$j+4];AbsP90=$stats[$j+5];SNR=$(if($stats[$j] -gt 0 -and $stats[$j+1] -gt 0){10*[Math]::Log10($stats[$j]/$stats[$j+1])}else{$null})})}
            $feature=$Kernel.ChannelMajor.Invoke($snapshots,$group*$frames+$first,$r.Frames)
            $artifact=Write-KokoroStrokeArray (Join-Path $OutputDirectory ("$($r.Name)-oracle-$budget.features.f32")) $feature
            $summaries.Add([pscustomobject]@{Case=$r.Name;Kind='OracleGreedyCeiling';ReferenceVectorInspected=$true;Budget=$budget;Frames=$r.Frames;Features=$artifact;AggregateSNR=$(if($errorTotal -gt 0 -and $signalTotal -gt 0){10*[Math]::Log10($signalTotal/$errorTotal)}else{$null});PeakError=$peak;
                FrameSNR=Get-KokoroStrokeQuantiles $snrs.ToArray();NormalizedFrameError=Get-KokoroStrokeQuantiles $normalized;SquaredFrameError=Get-KokoroStrokeQuantiles $squared;ActualStrokes=Get-KokoroStrokeQuantiles $actual;
                DictionaryRowsUsed=$caseUsed.Count;BoundaryFrames=$boundaryCount;BoundaryErrorShare=$(if($errorTotal -gt 0){$boundaryError/$errorTotal}else{0});BoundarySignalShare=$(if($signalTotal -gt 0){$boundarySignal/$signalTotal}else{0});JoinFrames=$joinCount;JoinErrorShare=$(if($errorTotal -gt 0){$joinError/$errorTotal}else{0});JoinSignalShare=$(if($signalTotal -gt 0){$joinSignal/$signalTotal}else{0});
                KernelSHA256=$Kernel.SHA256;LibrarySHA256=$library.Description.LibrarySHA256;InferenceClaim='None: oracle-selected coefficients; not a deployable compression result'})
        }
        for($id=0;$id -lt $globalCounts.Length;$id++){$utilization.Add([pscustomobject]@{Budget=$budget;Stroke=$id;Applications=$globalCounts[$id];Sentences=$sentenceCounts[$id]})}
    }
    $summaries.ToArray()|Export-Clixml (Join-Path $OutputDirectory 'ceiling.clixml');$allFrames.ToArray()|Export-Clixml (Join-Path $OutputDirectory 'frames.clixml');$allChannels.ToArray()|Export-Clixml (Join-Path $OutputDirectory 'channels.clixml');$utilization.ToArray()|Export-Clixml (Join-Path $OutputDirectory 'utilization.clixml')
    $null=Write-KokoroStrokeArray (Join-Path $OutputDirectory 'oracle-ids.i32') $ids;$null=Write-KokoroStrokeArray (Join-Path $OutputDirectory 'oracle-coefficients.f32') $coefficients;$null=Write-KokoroStrokeArray (Join-Path $OutputDirectory 'oracle-used.i32') $used
    [pscustomobject]@{Frames=$frames;SearchMilliseconds=$watch.Elapsed.TotalMilliseconds;SearchMsPerAudioSecond=$watch.Elapsed.TotalMilliseconds/($frames/80.0);DotProducts=($workers|Measure-Object DotProducts -Sum).Sum;AcceptedApplications=($workers|Measure-Object Applications -Sum).Sum;RefinementDots=($workers|Measure-Object RefinementDots -Sum).Sum;RefinementAccepted=($workers|Measure-Object RefinementAccepted -Sum).Sum;RefinementSweeps=8;BudgetMeaning='Distinct active directions; coefficients refined in ascending stroke-ID order';Dictionary=$library.Description.Strokes;DotPrecision='Float64 left-to-right';ReplayPrecision='Float32 multiply then Float32 add';DiagnosticOracleBytes=4L*$ids.Length+4L*$coefficients.Length+4L*$used.Length;RuntimeFormat=$false;Directory=$OutputDirectory}|Export-Clixml (Join-Path $OutputDirectory 'ceiling-operations.clixml')
    return $summaries.ToArray()
}

function Invoke-KokoroStrokeRender {
    param([object[]]$Records,[string]$ReconstructionDirectory,[string]$OutputDirectory,[int]$Threads,[string[]]$CaseNames)
    $root=Split-Path -Parent $PSScriptRoot
    $student=Get-Module Kokoro.Student
    $bootstrap=@($student.Invoke({(Get-Command Render-KokoroStudentCopy).ScriptBlock.Ast.Body.EndBlock.Statements}))
    $inside=$false;$executed=0
    foreach($statement in $bootstrap){
        $assignment=$statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Left -is [Management.Automation.Language.VariableExpressionAst]
        if($assignment -and $statement.Left.VariablePath.UserPath -ceq 'sourcePath'){$inside=$true}
        if($assignment -and $statement.Left.VariablePath.UserPath -ceq 'measurement'){break}
        if($inside){. ([scriptblock]::Create($statement.Extent.Text));$executed++}
    }
    if($executed -lt 20 -or $sourceHash -cne '8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257'){throw 'Frozen renderer bootstrap differs.'}
    function Test-OfflineNode([string]$Name,[float[]]$Values) {}
    $helpers=Join-Path $root 'build/student-replay-nine-a-20261015/Kokoro.Student.dll'
    if((Get-FileHash $helpers).Hash -cne 'EE4DD6FB9A55CDEFC1B781BA07E19AC9D91307CA911B620AA7D72D90ADB3B017'){throw 'PCM helpers differ.'}
    $helperType=[Reflection.Assembly]::LoadFrom($helpers).GetType('KokoroStudentMath',$true)
    $pcm16=$helperType.GetMethod('Pcm16').CreateDelegate([Func[float[],short[]]])
    $pcmFloat=$helperType.GetMethod('PcmFloat').CreateDelegate([Func[short[],float[]]])
    $finite=$helperType.GetMethod('PcmStats').CreateDelegate([Func[float[],double[]]])
    $waveWriter=$student.Invoke({${function:Write-KokoroStudentWave}})[0]
    $reconstructions=@(Import-Clixml (Join-Path $ReconstructionDirectory 'ceiling.clixml'))
    $results=[Collections.Generic.List[object]]::new()
    foreach($record in @($Records|Where-Object {-not $_.Training -and (-not $CaseNames.Count -or $_.Name -cin $CaseNames)})){
        $pitch=Read-KokoroStrokeArray $record.F0 ([float]) 4;$voice=Read-KokoroStrokeArray $record.Style ([float]) 4
        $uniform=Read-KokoroStrokeArray $record.Uniform ([float]) 4;$harmonicDraw=Read-KokoroStrokeArray $record.Harmonic ([float]) 4;$extra=Read-KokoroStrokeArray $record.Extra ([float]) 4
        $referencePcm=Read-KokoroStrokeArray $record.Pcm ([float]) 4;$referenceCodes=$pcm16.Invoke($referencePcm);$referenceQuantized=$pcmFloat.Invoke($referenceCodes)
        $referenceWave=Join-Path $OutputDirectory ($record.Name+'-reference.wav');& $waveWriter $referenceWave $referenceCodes
        foreach($budget in 4,8,16){
            $rows=@($reconstructions|Where-Object {$_.Case -ceq $record.Name -and $_.Budget -eq $budget});if($rows.Count -ne 1){throw 'Missing/duplicate reconstructed case.'};$row=$rows[0]
            $features=Read-KokoroStrokeArray $row.Features ([float]) 4;$null=$finite.Invoke($features)
            if($features.Length -ne 512*$pitch.Length){throw 'Reconstructed feature shape differs.'}
            Write-Host "Stroke render: $($record.Name), oracle $budget"
            $profile.Clear();$watch=[Diagnostics.Stopwatch]::StartNew();$pcm=Invoke-OfflineGenerator $features $voice $pitch $uniform $harmonicDraw $extra;$watch.Stop()
            $stats=$finite.Invoke($pcm);$codes=$pcm16.Invoke($pcm);$metrics=$compare.Invoke($pcm,$referencePcm);$quantizedMetrics=$compare.Invoke($pcmFloat.Invoke($codes),$referenceQuantized)
            $path=Join-Path $OutputDirectory ("$($record.Name)-oracle-$budget.wav");& $waveWriter $path $codes
            $pair=[short[]]::new(2*$codes.Length+14400);[Array]::Copy($referenceCodes,$pair,$referenceCodes.Length);[Array]::Copy($codes,0,$pair,$referenceCodes.Length+14400,$codes.Length)
            $pairPath=Join-Path $OutputDirectory ("$($record.Name)-reference-then-oracle-$budget.wav");& $waveWriter $pairPath $pair
            $results.Add([pscustomobject]@{Case=$record.Name;Kind='OracleGreedyCeiling';Budget=$budget;AudioSeconds=$pitch.Length/80.0;FeatureSNR=$row.AggregateSNR;
                PcmSNR=$metrics[0];Pcm16SNR=$quantizedMetrics[0];PeakAbsoluteError=$metrics[1];Pcm16PeakAbsoluteError=$quantizedMetrics[1];Peak=$stats[0];ClippedSamples=$stats[1];
                GeneratorMs=$watch.Elapsed.TotalMilliseconds;GeneratorMsPerAudioSecond=$watch.Elapsed.TotalMilliseconds/($pitch.Length/80.0);WavePath=$path;WaveSHA256=(Get-FileHash $path).Hash;
                PairPath=$pairPath;PairSHA256=(Get-FileHash $pairPath).Hash;ReferenceWaveSHA256=(Get-FileHash $referenceWave).Hash;ReferenceSourceSHA256=$sourceHash;ReferenceKernelSHA256=$dllHash;
                Controls=$record.Controls;ReferenceVectorInspected=$true;RuntimeClaim=$false;ComparisonOrder='Reference, 0.6 s silence, oracle reconstruction';TimingScope='Frozen FP32 generator including source, Windows host; external inputs matched; no decoder in candidate render'})
            $results.ToArray()|Export-Clixml (Join-Path $OutputDirectory 'render.clixml')
            Write-Host "Stroke render: $($record.Name)/$budget, PCM16 $($quantizedMetrics[0]) dB"
        }
    }
    $audio=@(& (Join-Path $root 'Invoke-KokoroDevelopment.ps1') MeasureAudio -Path $OutputDirectory)
    $audio|Export-Clixml (Join-Path $OutputDirectory 'measure-audio.clixml')
    return $results.ToArray()
}

function Read-KokoroStrokeArray {
    param($Descriptor,[type]$Type,[int]$Width)
    if((Get-FileHash $Descriptor.Path).Hash -cne $Descriptor.SHA256){throw 'Stroke experiment input hash differs.'}
    $raw=[IO.File]::ReadAllBytes($Descriptor.Path);if($raw.Length%$Width){throw 'Incomplete stroke array.'}
    $result=[Array]::CreateInstance($Type,[int]($raw.Length/$Width));[Buffer]::BlockCopy($raw,0,$result,0,$raw.Length);return ,$result
}

function Test-KokoroStrokeKernel {
    param($Kernel)
    $pool=[float[]]::new(1536);$pool[0]=1;$pool[512]=-1;$pool[1025]=2
    $selected=$Kernel.Select.Invoke($Kernel.Pack.Invoke($pool),3)
    if(-not [Linq.Enumerable]::SequenceEqual[int]($selected,[int[]]@(2,0))){throw 'Stroke selection/dedup/tie fixture failed.'}
    $dictionary=[float[]]::new(1024);$dictionary[0]=1;$dictionary[513]=1
    $worker=[Activator]::CreateInstance($Kernel.WorkerType);$worker.Truth=[float[]]::new(512);$worker.Truth[0]=0.75;$worker.Truth[1]=-0.5
    $worker.BaseState=[float[]]::new(512);$worker.Dictionary=$dictionary;$worker.Packed=$Kernel.Pack.Invoke($dictionary);$worker.Norms=$Kernel.Norms.Invoke($worker.Packed)
    $worker.First=0;$worker.Count=1;$worker.Snapshots=[float[]]::new(1536);$worker.Ids=[int[]]::new(16);$worker.Coefficients=[float[]]::new(48);$worker.Used=[int[]]::new(3);$worker.Errors=[double[]]::new(3);$worker.Signals=[double[]]::new(1);$worker.RefinementSweeps=8
    $worker.Run()
    if($worker.Ids[0] -ne 0 -or $worker.Ids[1] -ne 1 -or $worker.Coefficients[0] -ne 0.75 -or $worker.Coefficients[1] -ne -0.5 -or $worker.Used[2] -ne 2 -or $worker.Errors[2] -ne 0){throw 'Signed fractional greedy stroke fixture failed.'}
    $measure=$Kernel.Assembly.GetType('KokoroStrokeMath',$true).GetMethod('Measure').CreateDelegate([Func[float[],float[],int,int,int,double[]]])
    $stats=$measure.Invoke($worker.Truth,$worker.Snapshots,0,0,1)
    if($stats.Length -ne 3075 -or $stats[1] -ne 0 -or $stats[3072] -ne 0.8125 -or $stats[3073] -ne 0){throw 'Per-channel/per-frame stroke measurement fixture failed.'}
    $dictionary[512]=0.8;$dictionary[513]=0.6;$worker.Truth[0]=0;$worker.Truth[1]=1
    $worker.Dictionary=$dictionary;$worker.Packed=$Kernel.Pack.Invoke($dictionary);$worker.Norms=$Kernel.Norms.Invoke($worker.Packed)
    $worker.Run()
    if($worker.Used[0] -ne 2 -or $worker.Ids[0] -eq $worker.Ids[1] -or $worker.RefinementAccepted -lt 1 -or $worker.Errors[0] -ge 0.01){throw 'Distinct active-stroke/refinement fixture failed.'}
    $replayed=[float[]]::new(512)
    for($c=0;$c -lt 512;$c++){for($slot=0;$slot -lt $worker.Used[0];$slot++){$product=[float]($worker.Coefficients[$slot]*$dictionary[$worker.Ids[$slot]*512+$c]);$replayed[$c]=[float]($replayed[$c]+$product)}}
    $snapshot=[float[]]::new(512);[Array]::Copy($worker.Snapshots,$snapshot,512)
    if(-not [Linq.Enumerable]::SequenceEqual[float]($replayed,$snapshot)){throw 'Stored coefficients do not replay the measured snapshot.'}
    $nativeReplay=$Kernel.Replay.Invoke($worker.BaseState,$dictionary,$worker.Ids,$worker.Coefficients,$worker.Used,1,0)
    if(-not [Linq.Enumerable]::SequenceEqual[float]($nativeReplay,$snapshot)){throw 'Native BASE/STROKE replay differs from the measured snapshot.'}
    return $true
}

function Invoke-KokoroStudentStrokes {
    [CmdletBinding()]
    param([ValidateSet('Admit','Library','Ceiling','Render','ReplayCheck')][string]$Stage='Admit',[Parameter(Mandatory)][string]$OutputDirectory,
        [string]$ExperimentDirectory,[ValidateRange(16,4096)][int]$LibrarySize=1024,[ValidateRange(1,32)][int]$Threads=4,[string]$LibraryDirectory,[string]$ReconstructionDirectory,[string[]]$CaseNames=@())
    $root=Split-Path -Parent $PSScriptRoot;$out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)){throw 'Choose a fresh stroke stage directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out);$kernel=New-KokoroStrokeKernel $out;$null=Test-KokoroStrokeKernel $kernel
    if($Stage -ceq 'Admit'){return [pscustomobject]@{Passed=$true;KernelSHA256=$kernel.SHA256}}
    $records=@(Import-Clixml (Join-Path $ExperimentDirectory 'boundary.clixml'))
    if($Stage -ceq 'ReplayCheck'){
        $library=Read-KokoroStrokeLibrary $LibraryDirectory $kernel
        $operations=Import-Clixml (Join-Path $ReconstructionDirectory 'ceiling-operations.clixml');$frames=[int]$operations.Frames
        $arrays=@{}
        foreach($spec in @(@('ids','oracle-ids.i32',[int],4),@('coefficients','oracle-coefficients.f32',[float],4),@('used','oracle-used.i32',[int],4))){$p=Join-Path $ReconstructionDirectory $spec[1];$raw=[IO.File]::ReadAllBytes($p);$a=[Array]::CreateInstance($spec[2],[int]($raw.Length/$spec[3]));[Buffer]::BlockCopy($raw,0,$a,0,$raw.Length);$arrays[$spec[0]]=$a}
        $ceiling=@(Import-Clixml (Join-Path $ReconstructionDirectory 'ceiling.clixml'));$cases=@($records|Where-Object {-not $_.Training});$results=@(for($group=0;$group -lt 3;$group++){
            $budget=[int](@(4,8,16)[$group]);$replayed=$kernel.Replay.Invoke($library.BaseState,$library.Dictionary,$arrays.ids,$arrays.coefficients,$arrays.used,$frames,$group);$at=0
            foreach($r in $cases){$row=@($ceiling|Where-Object {$_.Case -ceq $r.Name -and $_.Budget -eq $budget})[0];$expected=Read-KokoroStrokeArray $row.Features ([float]) 4;$actual=$kernel.ChannelMajor.Invoke($replayed,$at,$r.Frames);if(-not [Linq.Enumerable]::SequenceEqual[float]($actual,$expected)){throw 'Persisted oracle program did not replay its measured tensor.'};$at+=$r.Frames}
            [pscustomobject]@{Budget=$budget;Frames=$frames;Cases=$cases.Count;BitExact=$true;KernelSHA256=$kernel.SHA256;ReferenceVectorUsedInReplay=$false;CoefficientsWereOracleSelected=$true}
        });$results|Export-Clixml (Join-Path $out 'replay-check.clixml');return $results
    }
    if($Stage -ceq 'Render'){return Invoke-KokoroStrokeRender -Records $records -ReconstructionDirectory $ReconstructionDirectory -OutputDirectory $out -Threads $Threads -CaseNames $CaseNames}
    if($Stage -ceq 'Ceiling'){return Invoke-KokoroStrokeCeiling -Kernel $kernel -Records $records -LibraryDirectory $LibraryDirectory -OutputDirectory $out -Threads $Threads}
    $tests=@($records|Where-Object {-not $_.Training});$training=@($records|Where-Object Training|Sort-Object Name)
    if($tests.Count -ne 11 -or $training.Count -lt 1 -or @($tests|Where-Object {$null -eq $_.Pcm -or ($_.Kind -ceq 'ExistingSelectedBankReference' -and -not $_.BitExactPcm16)}).Count){throw 'All eleven reference reproductions must pass before stroke discovery.'}
    $testPhones=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($r in $tests){[void]$testPhones.Add($r.Phonemes)}
    foreach($r in $training){if($testPhones.Contains($r.Phonemes)){throw 'A training phoneme sequence overlaps a held-out case.'}}
    $frames=[int](($training|Measure-Object Frames -Sum).Sum);$states=[float[]]::new(512*$frames);$starts=[bool[]]::new($frames);$offsets=[int[]]::new($training.Count+1)
    $at=0;for($s=0;$s -lt $training.Count;$s++){$r=$training[$s];$x=Read-KokoroStrokeArray $r.Features ([float]) 4;$converted=$kernel.FrameMajor.Invoke($x,$r.Frames);[Array]::Copy($converted,0,$states,$at*512,$converted.Length);$starts[$at]=$true;$offsets[$s]=$at;$at+=$r.Frames};$offsets[-1]=$at
    $baseState=[float[]]::new(512);[Array]::Copy($states,$baseState,512)
    $pool=$kernel.Pool.Invoke($states,$starts,$baseState);$packed=$kernel.Pack.Invoke($pool)
    $watch=[Diagnostics.Stopwatch]::StartNew();$ids=$kernel.Select.Invoke($packed,$LibrarySize);$watch.Stop()
    $dictionary=[float[]]::new(512*$ids.Length);for($i=0;$i -lt $ids.Length;$i++){[Array]::Copy($pool,$ids[$i]*512,$dictionary,$i*512,512)}
    $path=Join-Path $out 'stroke-library.bin';$writer=[IO.BinaryWriter]::new([IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None))
    try{
        $writer.Write([Text.Encoding]::ASCII.GetBytes('KHSTROK1'))
        foreach($word in [uint[]]@(1,512,$ids.Length,1,1,12,64,2112,(2112+4*$dictionary.Length),$frames,0,0,0,0)){$writer.Write($word)}
        foreach($array in @($baseState,$dictionary)){$raw=[byte[]]::new(4*$array.Length);[Buffer]::BlockCopy($array,0,$raw,0,$raw.Length);$writer.Write($raw)}
        foreach($id in $ids){$f=$id%$frames;$s=[Array]::BinarySearch($offsets,$f);if($s -lt 0){$s=-$s-2};$writer.Write([uint]$training[$s].SourceSentence);$writer.Write([uint]($f-$offsets[$s]));$writer.Write([uint][Math]::Floor($id/[double]$frames))}
    }finally{$writer.Dispose()}
    $description=[pscustomobject]@{Version=1;Channels=512;Strokes=$ids.Length;RequestedStrokes=$LibrarySize;BaseStates=1;Precision='Float32';CoefficientPrecision='Float32';ByteOrder='LittleEndian';
        HeaderBytes=64;BaseOffset=64;BaseBytes=2048;StrokeOffset=2112;StrokeBytes=4*$dictionary.Length;ProvenanceOffset=2112+4*$dictionary.Length;ProvenanceBytes=12*$ids.Length;
        LibraryPath=$path;LibrarySHA256=(Get-FileHash $path).Hash;LibraryBytes=(Get-Item $path).Length;KernelPath=$kernel.Path;KernelSHA256=$kernel.SHA256;KernelBytes=(Get-Item $kernel.Path).Length;
        TrainingSentences=$training.Count;TrainingFrames=$frames;Training=$training|Select-Object Name,SourceSentence,Frames,Features;BaseSourceSentence=$training[0].SourceSentence;BaseSourceFrame=0;
        Selection='Largest remaining candidate energy after best single selected-direction projection; ascending candidate index breaks exact ties';Deduplication='Squared absolute cosine >= 0.9999; opposite directions equivalent';
        CandidateKinds='Observed state minus one selected real BASE; observed consecutive-frame difference within a training sentence';DiscoveryBatchMs=$watch.Elapsed.TotalMilliseconds;
        RuntimeFormat='Global vectors and one BASE only; no per-frame coefficients or feature tracks in this library';ExperimentDirectory=$ExperimentDirectory}
    $description|Export-Clixml (Join-Path $out 'stroke-library.clixml')
    [pscustomobject]@{Stage='Library';Strokes=$ids.Length;TrainingFrames=$frames;LibraryBytes=$description.LibraryBytes;DescriptionBytes=(Get-Item (Join-Path $out 'stroke-library.clixml')).Length;KernelBytes=$description.KernelBytes;SHA256=$description.LibrarySHA256;Directory=$out}
}

Export-ModuleMember -Function Invoke-KokoroStudentStrokes
