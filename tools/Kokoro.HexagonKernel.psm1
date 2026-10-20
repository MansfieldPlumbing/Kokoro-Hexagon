#requires -Version 7.4
# Hexagon kernel builder: define, check, emit, simulate, run and read back DSP kernels.
#
# A kernel is a typed record: buffer minimums, a job (steps added through the checked FastRPC wrapper in
# src/jobs/Kokoro.WrappedJob.ps1), an optional report channel and an optional host model. This module
#   - checks the job's register contract (no writes to wrapper-owned registers);
#   - emits it through tools/Emit-HexagonProbe.ps1 -Kernel Definition (the existing encoder, ELF writer and lowering);
#   - simulates the job's own steps on the host (KokoroHexagonSimulator, lowered by the pinned PSLowering compiler);
#   - runs it on the phone through tools/Invoke-GeneratorTailProbe.ps1 (staging, FastRPC, readback, startup restore);
#   - decodes the output buffer and the report channel and compares both with the simulator and the host model.
#
# Report channel: the job calls  & $report <register>  to append that register's 32-bit value to a report region in
# the output buffer (r28 is the cursor). The end offset is stored at output byte 48.
#
# Kernel definitions live in this module: their job scriptblocks reach the wrapper's $s, $imm, $ptr and $report through
# dynamic scope, which only crosses calls inside one module's session state.
Set-StrictMode -Version Latest

# Host execution of a kernel's own typed steps (the job region inside the wrapper). Semantics follow the encoder's
# disassembly text (src/hexagon/Hexagon.ps1) and the V73 PRM; device parity is the acceptance test.
# Code layout per step (8 ints): op, d, s, t, i, u/x, target step, unused. Memory: input at 0x10000000 (r20), output at
# 0x20000000 (r23), VTCM at 0x30000000 (r18).
class KokoroHexagonSimulator {
    static [int] W([long] $v) { $v=$v -band [long]4294967295; if($v -ge [long]2147483648){$v=$v-[long]4294967296}; return [int]$v }
    static [int] Read32([byte[]] $inp,[byte[]] $outp,[byte[]] $vtcm,[long] $a) {
        if($a -ge [long]805306368){return [BitConverter]::ToInt32($vtcm,[int]($a-[long]805306368))}
        if($a -ge [long]536870912){return [BitConverter]::ToInt32($outp,[int]($a-[long]536870912))}
        return [BitConverter]::ToInt32($inp,[int]($a-[long]268435456))
    }
    static [void] Write32([byte[]] $inp,[byte[]] $outp,[byte[]] $vtcm,[long] $a,[int] $v) {
        $b=[BitConverter]::GetBytes($v)
        if($a -ge [long]805306368){[Array]::Copy($b,0,$vtcm,[int]($a-[long]805306368),4);return}
        if($a -ge [long]536870912){[Array]::Copy($b,0,$outp,[int]($a-[long]536870912),4);return}
        [Array]::Copy($b,0,$inp,[int]($a-[long]268435456),4)
    }
    static [void] Write16([byte[]] $inp,[byte[]] $outp,[byte[]] $vtcm,[long] $a,[int] $v) {
        $b=[BitConverter]::GetBytes([short]($v -band 65535))
        if($a -ge [long]805306368){[Array]::Copy($b,0,$vtcm,[int]($a-[long]805306368),2);return}
        if($a -ge [long]536870912){[Array]::Copy($b,0,$outp,[int]($a-[long]536870912),2);return}
        [Array]::Copy($b,0,$inp,[int]($a-[long]268435456),2)
    }
    static [long] Run([int[]] $code,[int] $count,[int[]] $r,[byte[]] $inp,[byte[]] $outp,[byte[]] $vtcm,[long] $limit) {
        $p=[int[]]::new(4);$pc=0;$executed=[long]0
        while($pc -lt $count){
            $executed=$executed+[long]1;if($executed -gt $limit){throw [InvalidOperationException]::new('Step limit exceeded')}
            $b=$pc*8;$op=$code[$b];$d=$code[$b+1];$s=$code[$b+2];$t=$code[$b+3];$i=$code[$b+4];$u=$code[$b+5];$target=$code[$b+6]
            $next=$pc+1
            if($op -eq 0){}                                                         # label
            elseif($op -eq 1){$r[$d]=$i}                                            # imm      Rd=#s16
            elseif($op -eq 2){$r[$u]=($r[$u] -band -65536) -bor ($i -band 65535)}   # lo       Rx.L=#u16
            elseif($op -eq 3){$r[$u]=($r[$u] -band 65535) -bor ($i -shl 16)}        # hi       Rx.H=#u16
            elseif($op -eq 4){$r[$d]=[KokoroHexagonSimulator]::W([long]$r[$s]+[long]$r[$t])}   # add, wraps mod 2^32
            elseif($op -eq 5){$r[$d]=[KokoroHexagonSimulator]::W([long]$r[$s]+[long]$i)}       # addi
            elseif($op -eq 6){$r[$d]=[KokoroHexagonSimulator]::W([long]$r[$s]-[long]$r[$t])}   # sub      Rd=Rs-Rt
            elseif($op -eq 7){$r[$d]=$r[$s] -band $r[$t]}                           # and
            elseif($op -eq 8){$r[$d]=$r[$s] -bor $r[$t]}                            # or
            elseif($op -eq 9){$r[$d]=$r[$s] -bxor $r[$t]}                           # xor
            elseif($op -eq 10){$r[$d]=$r[$s] -shl $i}                               # asl-i
            elseif($op -eq 11){$r[$d]=$r[$s] -shr $i}                               # asr-i
            elseif($op -eq 12){$r[$d]=[KokoroHexagonSimulator]::W(([long]$r[$s] -band [long]4294967295) -shr $i)}   # lsr-i
            elseif($op -eq 13){$v=[long]$r[$s]*[long]$r[$t];$r[$d]=[KokoroHexagonSimulator]::W($v);$r[$d+1]=[KokoroHexagonSimulator]::W($v -shr 32)}   # mpy-d
            elseif($op -eq 14){$v=([long]$r[$s] -band [long]4294967295)*([long]$r[$t] -band [long]4294967295);$r[$d]=[KokoroHexagonSimulator]::W($v);$r[$d+1]=[KokoroHexagonSimulator]::W($v -shr 32)}   # mpyu-d
            elseif($op -eq 15){$v=(([long]$r[$s+1]) -shl 32) -bor ([long]$r[$s] -band [long]4294967295);$v=$v -shr $i;$r[$d]=[KokoroHexagonSimulator]::W($v);$r[$d+1]=[KokoroHexagonSimulator]::W($v -shr 32)}   # asr-d-i
            elseif($op -eq 16){$r[$d]=[KokoroHexagonSimulator]::Read32($inp,$outp,$vtcm,([long]$r[$s] -band [long]4294967295)+[long]$i)}   # load memw
            elseif($op -eq 17){[KokoroHexagonSimulator]::Write32($inp,$outp,$vtcm,([long]$r[$s] -band [long]4294967295)+[long]$i,$r[$t])}   # store memw
            elseif($op -eq 18){[KokoroHexagonSimulator]::Write16($inp,$outp,$vtcm,([long]$r[$s] -band [long]4294967295)+[long]$i,$r[$t])}   # store-h memh
            elseif($op -eq 19){$a=([long]$r[$s] -band [long]4294967295)+[long]$i;$r[$d]=[KokoroHexagonSimulator]::Read32($inp,$outp,$vtcm,$a);$r[$d+1]=[KokoroHexagonSimulator]::Read32($inp,$outp,$vtcm,$a+[long]4)}   # load-d
            elseif($op -eq 20){$a=([long]$r[$s] -band [long]4294967295)+[long]$i;[KokoroHexagonSimulator]::Write32($inp,$outp,$vtcm,$a,$r[$t]);[KokoroHexagonSimulator]::Write32($inp,$outp,$vtcm,$a+[long]4,$r[$t+1])}   # store-d
            elseif($op -eq 21){$p[$d]=0;if(([long]$r[$s] -band [long]4294967295) -gt ([long]$r[$t] -band [long]4294967295)){$p[$d]=1}}   # gtu
            elseif($op -eq 22){$p[$d]=0;if($r[$s] -gt $r[$t]){$p[$d]=1}}           # gt
            elseif($op -eq 23){$p[$d]=0;if($r[$s] -eq $r[$t]){$p[$d]=1}}           # eq
            elseif($op -eq 24){if($p[$u] -ne 0){$next=$target}}                     # jump-p
            elseif($op -eq 25){$x=[BitConverter]::Int32BitsToSingle($r[$s])*[BitConverter]::Int32BitsToSingle($r[$t]);$r[$d]=[BitConverter]::SingleToInt32Bits($x)}   # sfmpy
            elseif($op -eq 26){$x=[BitConverter]::Int32BitsToSingle($r[$s])+[BitConverter]::Int32BitsToSingle($r[$t]);$r[$d]=[BitConverter]::SingleToInt32Bits($x)}   # sfadd
            elseif($op -eq 27){$x=[BitConverter]::Int32BitsToSingle($r[$s])-[BitConverter]::Int32BitsToSingle($r[$t]);$r[$d]=[BitConverter]::SingleToInt32Bits($x)}   # sfsub
            elseif($op -eq 28){$r[$d]=[BitConverter]::SingleToInt32Bits([float]$r[$s])}   # convert_w2sf
            elseif($op -eq 29){$f=[double][BitConverter]::Int32BitsToSingle($r[$s]);$w=[Math]::Truncate($f);if($w -gt [double]2147483647){$w=[double]2147483647};if($w -lt [double]-2147483648){$w=[double]-2147483648};$r[$d]=[int]$w}   # convert_sf2w:chop
            elseif($op -eq 30){$r[$d]=[Math]::Min($r[$s],$r[$t])}                   # min
            elseif($op -eq 31){$r[$d]=[Math]::Max($r[$s],$r[$t])}                   # max
            elseif($op -eq 32){return $executed}                                    # return
            else{throw [InvalidOperationException]::new('Unsupported simulator op code')}
            $pc=$next
        }
        return $executed
    }
}

$script:Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Build=Join-Path $script:Root 'build/hexagon-kernel'
# Registers the job must not write: r20 input and r23 output bases, r26:27 start ticks (the wrapper stores them after the
# job), r29-r31 stack, frame and link. r28 is the report cursor when a report channel is declared.
$script:ReservedWrites=@(20,23,26,27,29,30,31)
$script:PairWrites=@('mpy-d','mpyu-d','add-d','sub-d','asr-d-i','load-d')
$script:UseCount=0
$script:BuilderIndex=$null
$script:SimulatorType=$null
$script:SimulatorOps=@{label=0;imm=1;lo=2;hi=3;add=4;addi=5;sub=6;and=7;or=8;xor=9;'asl-i'=10;'asr-i'=11;'lsr-i'=12;'mpy-d'=13;'mpyu-d'=14;'asr-d-i'=15;
    load=16;store=17;'store-h'=18;'load-d'=19;'store-d'=20;gtu=21;gt=22;eq=23;'jump-p'=24;sfmpy=25;sfadd=26;sfsub=27;'conv-w2sf'=28;'conv-sf2w-chop'=29;min=30;max=31;return=32}

function Test-KokoroHexagonJobRegisters {
    param([Parameter(Mandatory)][object[]]$Steps,[int[]]$Reserved=$script:ReservedWrites)
    $bad=foreach($step in $Steps){
        if($step.Op -in 'lo','hi'){$written=@([int]$step.x)}
        elseif(-not $step.ContainsKey('d') -or $step.Op -in 'store','store-h','store-d','gtu','gt','eq','gtu-d','jump-p'){continue}
        else{$written=@([int]$step.d)};if($step.Op -in $script:PairWrites){$written+=[int]$step.d+1}
        foreach($register in $written){if($register -in $Reserved){"$($step.Op) writes r$register"}}
    }
    if($bad){throw "Register contract violated: $(@($bad|Select-Object -Unique) -join '; ')"}
}

function New-KokoroHexagonKernel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][long]$InputBytes,[Parameter(Mandatory)][long]$OutputBytes,
        [Parameter(Mandatory)][scriptblock]$Job,[long]$VtcmBytes=65536,[object[]]$Bodies,[long]$ReportOffset=-1,
        [scriptblock]$HostModel,[long]$PlaySamples=1,[long]$PcmOffset=256,[object[]]$WrittenRegions)
    . (Join-Path $script:Root 'src/hexagon/Hexagon.ps1')
    . (Join-Path $script:Root 'src/jobs/Kokoro.WrappedJob.ps1')
    if(-not $Bodies){$Bodies=@(,@("${Name}_noop",@(@{Op='return'})))}
    if($ReportOffset -ge 0 -and ($ReportOffset -lt 256 -or $ReportOffset -ge $OutputBytes -or $ReportOffset % 4)){throw 'Report region must be word aligned inside the output buffer, after the 256-byte header.'}
    $jobSteps=[Collections.Generic.List[hashtable]]::new();$simSteps=[Collections.Generic.List[hashtable]]::new()
    $reserved=if($ReportOffset -ge 0){$script:ReservedWrites+28}else{$script:ReservedWrites}
    $userJob=$Job;$reportAt=$ReportOffset
    # Not a closure: it runs inside New-KokoroWrappedJobSteps, whose $s, $imm, $ptr, $call, $sync and $dma are reached
    # through dynamic scope, as are this function's $userJob, $reportAt and $jobSteps.
    $wrapped={
        $simFirst=$s.Count
        if($reportAt -ge 0){& $ptr 28 23 $reportAt}
        $report={param([int]$Register) $s.Add(@{Op='store';s=28;t=$Register;Offset=0});$s.Add(@{Op='addi';d=28;s=28;i=4})}
        # & $use <New-*Steps builder> @{arguments} [-Prefix p]: splice an existing builder's steps into this job. Labels the
        # builder defines get the prefix, so one builder can be used more than once; labels it references elsewhere stay.
        $use={param([Parameter(Mandatory)][string]$Builder,[hashtable]$Arguments=@{},[string]$Prefix)
            $entry=@(Get-KokoroHexagonBuilder|Where-Object Name -ceq $Builder);if($entry.Count -ne 1){throw "No unique builder $Builder."}
            . (Join-Path $script:Root $entry[0].File)
            $made=@(& $Builder @Arguments)
            if(-not $Prefix){$script:UseCount++;$Prefix="u$($script:UseCount)_"}
            $defined=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($step in $made){if($step.Op -eq 'label'){[void]$defined.Add($step.Name)}}
            foreach($step in $made){$copy=$step.Clone()
                if($copy.Op -eq 'label' -and $defined.Contains($copy.Name)){$copy.Name=$Prefix+$copy.Name}
                if($copy.ContainsKey('Label') -and $defined.Contains($copy.Label)){$copy.Label=$Prefix+$copy.Label}
                $s.Add($copy)}}
        $first=$s.Count
        & $userJob
        for($i=$first;$i -lt $s.Count;$i++){$jobSteps.Add($s[$i])}
        if($reportAt -ge 0){$s.Add(@{Op='sub';d=15;s=28;t=23});$s.Add(@{Op='store';s=23;t=15;Offset=48})}
        for($i=$simFirst;$i -lt $s.Count;$i++){$simSteps.Add($s[$i])}
    }
    $steps=New-KokoroWrappedJobSteps -Minimum @(4L,$InputBytes,4L,4L,$OutputBytes) -VtcmBytes $VtcmBytes -Tiles 1 -Job $wrapped -Bodies $Bodies
    $userSteps=@($jobSteps|Where-Object{-not ($_.Op -eq 'store' -and $_.s -eq 28) -and -not ($_.Op -eq 'addi' -and $_.d -eq 28 -and $_.s -eq 28)})
    Test-KokoroHexagonJobRegisters -Steps $userSteps -Reserved $reserved
    $regions=[Collections.Generic.List[object]]::new()
    if($WrittenRegions){foreach($region in $WrittenRegions){$regions.Add([long[]]@($region[0],$region[1]))}}else{$regions.Add([long[]]@(256L,($OutputBytes-256L)))}
    [pscustomobject]@{PSTypeName='Kokoro.Hexagon.Kernel';Name=$Name;Steps=$steps;JobSteps=$jobSteps.Count;InputBytes=$InputBytes;OutputBytes=$OutputBytes;
        WrittenRegions=$regions;ReportOffset=$ReportOffset;HostModel=$HostModel;SimSteps=$simSteps.ToArray();PlaySamples=$PlaySamples;PcmOffset=$PcmOffset;
        Symbol='kokoro_generator_tail_skel_handle_invoke';Soname='libkokoro_generator_tail_skel.so'}
}

function Export-KokoroHexagonKernel {
    param([Parameter(Mandatory)]$Kernel,[string]$Directory=(Join-Path $script:Build "$($Kernel.Name)/emission"))
    [void][IO.Directory]::CreateDirectory($Directory)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $null=& (Join-Path $script:Root 'tools/Emit-HexagonProbe.ps1') -Kernel Definition -Definition $Kernel -OutputDirectory $Directory -Force
    $library=Join-Path $Directory $Kernel.Soname
    [IO.File]::WriteAllText((Join-Path $Directory 'runner-layout.json'),([ordered]@{Tiles=1;InputBytes=$Kernel.InputBytes;OutputBytes=$Kernel.OutputBytes;PcmOffset=$Kernel.PcmOffset;Samples=$Kernel.PlaySamples}|ConvertTo-Json))
    [pscustomobject]@{Directory=$Directory;Library=$library;LibrarySHA256=(Get-FileHash $library).Hash;Bytes=(Get-Item $library).Length;EmitSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,1)}
}

function Read-KokoroHexagonReport {
    param([Parameter(Mandatory)][byte[]]$Output,[Parameter(Mandatory)][long]$ReportOffset)
    $end=[BitConverter]::ToInt32($Output,48);if($end -lt $ReportOffset -or $end -gt $Output.Length -or ($end-$ReportOffset)%4){throw "Report end offset $end is invalid."}
    $words=[uint32[]]::new(($end-$ReportOffset)/4);[Buffer]::BlockCopy($Output,[int]$ReportOffset,$words,0,4*$words.Length);,$words
}

function Get-KokoroHexagonSimulator {
    if($script:SimulatorType){return $script:SimulatorType}
    $compiler=Join-Path $script:Root 'build/phonemizer/inputs/pslowering-1afabe056235a570da29e268824784557d4f6cdd'
    foreach($pin in @(Import-Csv (Join-Path $compiler 'verified-source.tsv') -Delimiter "`t")){if((Get-FileHash (Join-Path $compiler $pin.Path)).Hash -cne $pin.Sha256){throw 'Pinned PSLowering integrity differs.'}}
    Import-Module (Join-Path $compiler 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1')
    $dll=Join-Path $script:Build "simulator/KokoroHexagonSimulator-$((Get-FileHash $PSCommandPath).Hash.Substring(0,12)).dll"
    if(-not (Test-Path $dll)){
        [void][IO.Directory]::CreateDirectory((Split-Path $dll))
        $null=Export-LoweredAssembly -SourcePath $PSCommandPath -ClassName KokoroHexagonSimulator -OutputPath $dll -Deterministic
        if(-not (Test-LoweredAssembly -AssemblyPath $dll).ClrOnlyAdmitted){throw 'The simulator references SMA.'}
    }
    $script:SimulatorType=[Reflection.Assembly]::LoadFrom($dll).GetType('KokoroHexagonSimulator',$true);$script:SimulatorType
}

function Invoke-KokoroHexagonSimulator {
    # Runs the kernel's job region (SimSteps) on the host. Returns the output buffer, report words and steps executed.
    param([Parameter(Mandatory)]$Kernel,[Parameter(Mandatory)][byte[]]$InputData,[long]$StepLimit=2000000000)
    $steps=@($Kernel.SimSteps);$labels=@{}
    for($i=0;$i -lt $steps.Count;$i++){if($steps[$i].Op -eq 'label'){$labels[$steps[$i].Name]=$i}}
    $code=[int[]]::new(8*$steps.Count)
    for($i=0;$i -lt $steps.Count;$i++){$step=$steps[$i]
        if(-not $script:SimulatorOps.ContainsKey($step.Op)){throw "The simulator does not implement op '$($step.Op)' (step $i)."}
        $base=8*$i;$code[$base]=$script:SimulatorOps[$step.Op]
        foreach($field in @(@('d',1),@('s',2),@('t',3))){if($step.ContainsKey($field[0])){$code[$base+$field[1]]=[int]$step[$field[0]]}}
        if($step.ContainsKey('i')){$code[$base+4]=[int]$step.i}elseif($step.ContainsKey('Offset')){$code[$base+4]=[int]$step.Offset}
        if($step.ContainsKey('u')){$code[$base+5]=[int]$step.u}elseif($step.ContainsKey('x')){$code[$base+5]=[int]$step.x}
        if($step.Op -eq 'jump-p'){if(-not $labels.ContainsKey($step.Label)){throw "Jump to '$($step.Label)' leaves the simulated job (step $i)."};$code[$base+6]=$labels[$step.Label]}}
    $registers=[int[]]::new(32);$registers[20]=0x10000000;$registers[23]=0x20000000;$registers[18]=0x30000000
    $inputCopy=[byte[]]$InputData.Clone();$output=[byte[]]::new($Kernel.OutputBytes);$vtcm=[byte[]]::new(65536)
    $type=Get-KokoroHexagonSimulator;$watch=[Diagnostics.Stopwatch]::StartNew()
    $executed=$type::Run($code,$steps.Count,$registers,$inputCopy,$output,$vtcm,$StepLimit)
    $report=if($Kernel.ReportOffset -ge 0){Read-KokoroHexagonReport -Output $output -ReportOffset $Kernel.ReportOffset}else{$null}
    [pscustomobject]@{Output=$output;Report=$report;Steps=$executed;Registers=$registers;Milliseconds=[Math]::Round($watch.Elapsed.TotalMilliseconds,1)}
}

function Compare-KokoroHexagonOutput {
    # Device output versus simulator output, from byte 256 (the wrapper owns the header) plus the report end word.
    param([Parameter(Mandatory)][byte[]]$Device,[Parameter(Mandatory)][byte[]]$Simulated)
    $count=[Math]::Min($Device.Length,$Simulated.Length);$bad=0;$first=-1
    for($i=256;$i -lt $count;$i++){if($Device[$i] -ne $Simulated[$i]){$bad++;if($first -lt 0){$first=$i}}}
    [pscustomobject]@{ComparedBytes=$count-256;MismatchedBytes=$bad;FirstMismatch=$first;ReportEndMatch=([BitConverter]::ToInt32($Device,48) -eq [BitConverter]::ToInt32($Simulated,48))}
}

function Invoke-KokoroHexagonKernel {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Kernel,[Parameter(Mandatory)][byte[]]$InputData,[ValidateRange(1,31)][int]$Runs=3,[switch]$HostOnly,[switch]$Simulate,[string]$Soc='SM8550')
    if($InputData.Length -ne $Kernel.InputBytes){throw "Input is $($InputData.Length) bytes; the kernel declares $($Kernel.InputBytes)."}
    $simulated=$null;if($Simulate -or -not $Kernel.HostModel){$simulated=Invoke-KokoroHexagonSimulator -Kernel $Kernel -InputData $InputData}
    if($Simulate){return $simulated}
    $expected=if($Kernel.HostModel){& $Kernel.HostModel $InputData}else{$null}
    if($HostOnly){return [pscustomobject]@{Kernel=$Kernel.Name;Expected=$expected;Simulated=$simulated}}
    $emission=Export-KokoroHexagonKernel $Kernel
    $fixture=Join-Path $script:Build "$($Kernel.Name)/fixture";[void][IO.Directory]::CreateDirectory($fixture)
    [IO.File]::WriteAllBytes((Join-Path $fixture 'activations.bin'),$InputData)
    [IO.File]::WriteAllBytes((Join-Path $fixture 'weights.bin'),[byte[]]::new(4));[IO.File]::WriteAllBytes((Join-Path $fixture 'tables.bin'),[byte[]]::new(4))
    $probe=& (Join-Path $script:Root 'tools/Invoke-GeneratorTailProbe.ps1') -EmissionDirectory $emission.Directory -FixtureDirectory $fixture -Soc $Soc -Runs $Runs -TimeoutSeconds 300 2>&1
    $text=($probe|ForEach-Object{"$_"}) -join "`n"
    [IO.File]::WriteAllText((Join-Path $script:Build "$($Kernel.Name)/probe-output.txt"),$text)
    $path=[regex]::Match($text,'(?m)^OutputPath=(.+)$').Groups[1].Value.Trim()
    if(-not $path){throw "No device output: $(($probe|Select-Object -Last 6) -join ' | ')"}
    $bytes=[IO.File]::ReadAllBytes($path)
    $result=[ordered]@{Kernel=$Kernel.Name;Passed=($text -match '(?m)^Passed=True');StartupRestored=($text -match '(?m)^StartupRestored=True');
        Played=($text -match '(?m)^Played=True');MedianRegionMs=[regex]::Match($text,'MedianRegionMs=([0-9.]+)').Groups[1].Value;
        LibrarySHA256=$emission.LibrarySHA256;Output=$bytes;Report=$null;Mismatches=@()}
    if($Kernel.ReportOffset -ge 0){$result.Report=Read-KokoroHexagonReport -Output $bytes -ReportOffset $Kernel.ReportOffset}
    if($simulated){
        foreach($region in $Kernel.WrittenRegions){$bad=0;for($i=[int]$region[0];$i -lt [int]($region[0]+$region[1]);$i++){if($bytes[$i] -ne $simulated.Output[$i]){$bad++}}
            $result.Mismatches+=[pscustomobject]@{Region="Simulated@$($region[0])";Expected=[int]$region[1];Actual=[int]$region[1];Mismatches=$bad}}
        if($Kernel.ReportOffset -ge 0){$result.Mismatches+=[pscustomobject]@{Region='SimulatedReportEnd';Expected=1;Actual=1;Mismatches=[int]([BitConverter]::ToInt32($bytes,48) -ne [BitConverter]::ToInt32($simulated.Output,48))}}
    }
    if($expected){
        if($expected.PSObject.Properties['Report'] -and $null -ne $result.Report){
            $a=$expected.Report;$b=$result.Report;$count=[Math]::Min($a.Length,$b.Length);$bad=0;for($i=0;$i -lt $count;$i++){if($a[$i] -ne $b[$i]){$bad++}}
            $result.Mismatches+=[pscustomobject]@{Region='Report';Expected=$a.Length;Actual=$b.Length;Mismatches=$bad+[Math]::Abs($a.Length-$b.Length)}}
        if($expected.PSObject.Properties['Regions']){
            foreach($region in $expected.Regions){$words=$region.Words;$got=[uint32[]]::new($words.Length);[Buffer]::BlockCopy($bytes,[int]$region.Offset,$got,0,4*$words.Length);$bad=0;for($i=0;$i -lt $words.Length;$i++){if($words[$i] -ne $got[$i]){$bad++}}
                $result.Mismatches+=[pscustomobject]@{Region=$region.Name;Expected=$words.Length;Actual=$got.Length;Mismatches=$bad}}}
        if($expected.PSObject.Properties['Words']){
            $words=$expected.Words;$got=[uint32[]]::new($words.Length);[Buffer]::BlockCopy($bytes,[int]$expected.WordsOffset,$got,0,4*$words.Length);$bad=0;for($i=0;$i -lt $words.Length;$i++){if($words[$i] -ne $got[$i]){$bad++}}
            $result.Mismatches+=[pscustomobject]@{Region="Words@$($expected.WordsOffset)";Expected=$words.Length;Actual=$got.Length;Mismatches=$bad}}
    }
    [pscustomobject]$result
}

# ---------------------------------------------------------------- kernels ----------------------------------------------
# Pitch phase executor. Input: word 0 = S segments; from byte 8, S pairs (sample count >= 1, Q32 increment).
# Output: Psi after each sample's add from byte 256. With -Reporting: the sample index of every phase wrap (period boundary).
function Get-KokoroPitchPhaseKernel {
    param([Parameter(Mandatory)][int]$Segments,[Parameter(Mandatory)][int]$Samples,[switch]$Reporting)
    $inputBytes=8L+8L*$Segments;$psiBytes=4L*$Samples
    $reportOffset=if($Reporting){256L+$psiBytes}else{-1L}
    $outputBytes=if($Reporting){256L+$psiBytes+4L*$Samples}else{256L+$psiBytes}
    $withReport=[bool]$Reporting
    $job={
        $s.Add(@{Op='load';d=1;s=20;Offset=0})          # r1 = S
        $s.Add(@{Op='addi';d=2;s=20;i=8})               # r2 -> first pair
        $s.Add(@{Op='addi';d=3;s=23;i=256})             # r3 -> Psi[0]
        $s.Add(@{Op='imm';d=4;i=0})                     # r4 = Psi
        $s.Add(@{Op='imm';d=13;i=0})                    # r13 = 0
        if($withReport){$s.Add(@{Op='imm';d=7;i=0})}    # r7 = sample index
        $s.Add(@{Op='label';Name='pitch_segment'})
        $s.Add(@{Op='load';d=5;s=2;Offset=0})           # r5 = sample count
        $s.Add(@{Op='load';d=6;s=2;Offset=4})           # r6 = increment
        $s.Add(@{Op='addi';d=2;s=2;i=8})
        $s.Add(@{Op='label';Name='pitch_sample'})
        if($withReport){$s.Add(@{Op='addi';d=8;s=4;i=0})}  # r8 = Psi before the add
        $s.Add(@{Op='add';d=4;s=4;t=6})                 # Psi = add(Psi, inc): wraps mod 2^32
        $s.Add(@{Op='store';s=3;t=4;Offset=0})
        if($withReport){
            $s.Add(@{Op='gtu';d=0;s=8;t=4});$s.Add(@{Op='jump-p';u=0;Label='pitch_wrap'})
            $s.Add(@{Op='label';Name='pitch_wrap_back'})
            $s.Add(@{Op='addi';d=7;s=7;i=1})
        }
        $s.Add(@{Op='addi';d=3;s=3;i=4})
        $s.Add(@{Op='addi';d=5;s=5;i=-1})
        $s.Add(@{Op='gtu';d=0;s=5;t=13});$s.Add(@{Op='jump-p';u=0;Label='pitch_sample'})
        $s.Add(@{Op='addi';d=1;s=1;i=-1})
        $s.Add(@{Op='gtu';d=0;s=1;t=13});$s.Add(@{Op='jump-p';u=0;Label='pitch_segment'})
        if($withReport){
            $s.Add(@{Op='eq';d=0;s=13;t=13});$s.Add(@{Op='jump-p';u=0;Label='pitch_done'})
            $s.Add(@{Op='label';Name='pitch_wrap'})
            & $report 7                                   # this sample's index is a period boundary
            $s.Add(@{Op='eq';d=0;s=13;t=13});$s.Add(@{Op='jump-p';u=0;Label='pitch_wrap_back'})
            $s.Add(@{Op='label';Name='pitch_done'})
        }
    }
    $model={
        param([byte[]]$InputData)
        $segmentCount=[BitConverter]::ToInt32($InputData,0);$psi=[uint64]0;$index=0;$words=[uint32[]]::new($Samples);$marks=[Collections.Generic.List[uint32]]::new()
        for($k=0;$k -lt $segmentCount;$k++){$count=[BitConverter]::ToUInt32($InputData,8+8*$k);$increment=[uint64][BitConverter]::ToUInt32($InputData,12+8*$k)
            for($i=0;$i -lt $count;$i++){$sum=$psi+$increment;if($sum -gt 4294967295){$marks.Add([uint32]$index)};$psi=$sum -band 4294967295;$words[$index]=[uint32]$psi;$index++}}
        [pscustomobject]@{Words=$words;WordsOffset=256;Report=$marks.ToArray()}
    }.GetNewClosure()
    New-KokoroHexagonKernel -Name $(if($Reporting){'pitch-report'}else{'pitch'}) -InputBytes $inputBytes -OutputBytes $outputBytes -Job $job -ReportOffset $reportOffset -HostModel $model -Bodies @(,@('pitch_noop',@(@{Op='return'})))
}

# Per-frame F0 (Q16 Hz) to per-sample phase Psi (Q32 turns) and the sign mask, using the existing
# New-KokoroSourcePhaseSteps builder unchanged. Its register contract (from its source): r0 f0 frames, r1 L >= 2, r2/r3 Psi
# for even/odd samples (one word each per sample pair), r4 + r5 sign words, r5 bytes per halfword array, r6 constants
# record whose word 0 is M = round(2^40/24000). Samples = 300 L. No Kokoro weights are read.
function Get-KokoroSourcePhaseKernel {
    param([Parameter(Mandatory)][int]$Frames)
    if($Frames -lt 2){throw 'Source phase needs L >= 2 frames.'}
    $f0Bytes=[long]([Math]::Ceiling(4.0*$Frames/128)*128);$inputBytes=$f0Bytes+128L
    $half=600L*$Frames   # bytes of one halfword-per-sample array = bytes of one word-per-pair array
    $psiEven=256L;$psiOdd=$psiEven+$half;$masks=$psiOdd+$half;$outputBytes=$masks+2L*$half
    $job={
        $s.Add(@{Op='addi';d=0;s=20;i=0})                               # r0 -> f0 frames
        & $imm 1 $Frames                                                # r1 = L
        & $ptr 2 23 $psiEven; & $ptr 3 23 $psiOdd; & $ptr 4 23 $masks   # r2, r3, r4 output arrays
        & $imm 5 $half                                                  # r5 bytes per halfword array
        & $ptr 6 20 $f0Bytes                                            # r6 -> constants (word 0 = M)
        & $use 'New-KokoroSourcePhaseSteps' @{NoReturn=$true}
    }
    $model={
        param([byte[]]$InputData)
        $m=[long][BitConverter]::ToUInt32($InputData,[int]$f0Bytes)
        $f0=[int[]]::new($Frames);for($k=0;$k -lt $Frames;$k++){$f0[$k]=[BitConverter]::ToInt32($InputData,4*$k)}
        $low={param([long]$value) [uint32]($value -band 0xffffffffL)}
        $even=[Collections.Generic.List[uint32]]::new();$odd=[Collections.Generic.List[uint32]]::new();$sign=[Collections.Generic.List[uint32]]::new()
        $first=(([long]$f0[0]*$m) -shr 24) -band 0xffffffffL;if($first -ge 2147483648){$first-=4294967296}
        $phase=& $low (300L*$first)
        for($j=0;$j -lt 75;$j++){$even.Add($phase);$odd.Add($phase);$sign.Add(0)}
        for($k=0;$k -lt $Frames-1;$k++){
            $raw=(([long]$f0[$k+1]*$m) -shr 24) -band 0xffffffffL;$increment=if($raw -ge 2147483648){$raw-4294967296}else{$raw}
            $frameSign=if($f0[$k+1] -lt 0){[uint32]4294967295}else{[uint32]0}
            $running=& $low ([long]$phase+($increment -shr 1))
            for($j=0;$j -lt 150;$j++){$even.Add($running);$running=& $low ([long]$running+$increment);$odd.Add($running);$running=& $low ([long]$running+$increment);$sign.Add($frameSign)}
            $phase=& $low ([long]$phase+(& $low (300L*$increment)))
        }
        for($j=0;$j -lt 75;$j++){$even.Add($phase);$odd.Add($phase);$sign.Add(0)}
        [pscustomobject]@{Regions=@([pscustomobject]@{Name='PsiEven';Offset=$psiEven;Words=$even.ToArray()},[pscustomobject]@{Name='PsiOdd';Offset=$psiOdd;Words=$odd.ToArray()},[pscustomobject]@{Name='Sign';Offset=($masks+$half);Words=$sign.ToArray()})}
    }.GetNewClosure()
    $kernel=New-KokoroHexagonKernel -Name 'source-phase' -InputBytes $inputBytes -OutputBytes $outputBytes -Job $job -HostModel $model -WrittenRegions @(@($psiEven,(2L*$half)),@(($masks+$half),$half))
    $kernel|Add-Member -NotePropertyName ConstantsOffset -NotePropertyValue $f0Bytes -PassThru
}

function New-KokoroSourcePhaseInput {
    # f0 in Hz -> the source-phase kernel's input: int32 Q16 frames, padded to 128 bytes, then M at the constants offset.
    param([Parameter(Mandatory)][double[]]$F0)
    $f0Bytes=[long]([Math]::Ceiling(4.0*$F0.Length/128)*128);$data=[byte[]]::new($f0Bytes+128)
    for($k=0;$k -lt $F0.Length;$k++){[BitConverter]::GetBytes([int][Math]::Round($F0[$k]*65536)).CopyTo($data,4*$k)}
    [BitConverter]::GetBytes([uint32][Math]::Round([Math]::Pow(2,40)/24000)).CopyTo($data,[int]$f0Bytes);,$data
}

# Event-driven voice executor: typed control events in, PCM16 out. No Kokoro weights, tables or graph.
# Input (r20), byte offsets:
#   0 N samples   4 S pitch segments   8 F timbre events   12 noise seed   16 K recursion order
#   20 pitch table offset   24 timbre table offset   28 y-history offset (in the OUTPUT buffer)   32 LCG multiplier
#   36 LCG increment   40 0x7FFFFFFF   44 c1 = sqrt(12)/2^31 (f32)   48 c2 = sqrt(12)/2 (f32)   52 32768.0 (f32)
#   56 -32768   60 32767   64 timbre record bytes (12 + 4K)
#   pitch record (12 B): sample count, Q32 phase increment, pulse amplitude (f32)
#   timbre record: sample count, periodic gain gp (f32), noise gain gn (f32), a1..aK (f32)
# Output (r23): wrapper words at 0..63; PCM16 from byte 256; K zero floats then y[0..N-1] (f32) at the y-history offset.
# Per sample (operation: purpose -- V73 form):
#   cmp.eq + if(p0) jump : a control event expires, take the next one     -- Pd=cmp.eq(Rs,Rt); if (Pu) jump
#   memw loads           : read the next event's values                   -- Rd=memw(Rs+#s11:2)
#   add                  : advance phase Psi by the pitch increment       -- Rd=add(Rs,Rt), wraps mod 2^32 (PRM 11.1.1)
#   cmp.gtu              : a wrap is one period boundary -> pulse         -- Pd=cmp.gtu(Rs,Rt)
#   mpy (64) + add + and : noise state, LCG mod 2^31                      -- Rdd=mpy(Rs,Rt); add; Rd=and(Rs,Rt)
#   convert_w2sf, sfmpy, sfsub : noise to zero-mean unit-variance float    -- Rd=convert_w2sf(Rs); sfmpy; sfsub
#   sfmpy, sfadd         : excitation e = gp*pulse + gn*noise
#   K x (2 memw, sfmpy, sfsub) : recursion acc = e - sum a_k y[n-k]       -- history read linearly from y[]
#   memw store           : y[n] into the history the next samples read
#   sfmpy, convert_sf2w:chop, max, min, memh : PCM16 for the harness's AAudio playback
function Get-KokoroVoiceExecutorKernel {
    param([Parameter(Mandatory)][long]$InputBytes,[Parameter(Mandatory)][long]$OutputBytes,[Parameter(Mandatory)][long]$Samples)
    $job={
        $a={param($h) $s.Add($h)}
        & $a @{Op='load';d=1;s=20;Offset=0}                       # r1 = N
        & $a @{Op='load';d=24;s=20;Offset=20}; & $a @{Op='add';d=2;s=20;t=24}   # r2 -> pitch table
        & $a @{Op='load';d=24;s=20;Offset=24}; & $a @{Op='add';d=7;s=20;t=24}   # r7 -> timbre table
        & $a @{Op='load';d=24;s=20;Offset=28}; & $a @{Op='add';d=19;s=23;t=24}  # r19 -> y[0]
        & $a @{Op='addi';d=21;s=23;i=256}                          # r21 -> PCM[0]
        & $a @{Op='load';d=12;s=20;Offset=12}                      # r12 = noise state
        & $a @{Op='imm';d=13;i=0};& $a @{Op='imm';d=3;i=0};& $a @{Op='imm';d=8;i=0};& $a @{Op='imm';d=4;i=0};& $a @{Op='imm';d=5;i=0};& $a @{Op='imm';d=6;i=0}
        # Zero the K history floats before y[0] (output memory arrives uninitialised).
        & $a @{Op='load';d=0;s=20;Offset=16};& $a @{Op='addi';d=24;s=19;i=0}
        & $a @{Op='label';Name='ex_zero'};& $a @{Op='addi';d=24;s=24;i=-4};& $a @{Op='store';s=24;t=13;Offset=0}
        & $a @{Op='addi';d=0;s=0;i=-1};& $a @{Op='gtu';d=0;s=0;t=13};& $a @{Op='jump-p';u=0;Label='ex_zero'}
        & $a @{Op='label';Name='ex_sample'}
        # Pitch: next segment when the current one has run out; Psi += inc; wrap -> pulse.
        & $a @{Op='eq';d=0;s=3;t=13};& $a @{Op='jump-p';u=0;Label='ex_pitch_load'}
        & $a @{Op='label';Name='ex_pitch_back'}
        & $a @{Op='addi';d=3;s=3;i=-1}
        & $a @{Op='addi';d=15;s=4;i=0};& $a @{Op='add';d=4;s=4;t=5}
        & $a @{Op='imm';d=24;i=0}
        & $a @{Op='gtu';d=0;s=15;t=4};& $a @{Op='jump-p';u=0;Label='ex_wrap'}
        & $a @{Op='label';Name='ex_wrap_back'}
        # Timbre: next event when the current one has run out.
        & $a @{Op='eq';d=0;s=8;t=13};& $a @{Op='jump-p';u=0;Label='ex_timbre_load'}
        & $a @{Op='label';Name='ex_timbre_back'}
        & $a @{Op='addi';d=8;s=8;i=-1}
        # Noise: state = (state * A + C) & 0x7FFFFFFF; n = state * c1 - c2.
        & $a @{Op='load';d=25;s=20;Offset=32};& $a @{Op='mpy-d';d=14;s=12;t=25}
        & $a @{Op='load';d=25;s=20;Offset=36};& $a @{Op='add';d=12;s=14;t=25}
        & $a @{Op='load';d=25;s=20;Offset=40};& $a @{Op='and';d=12;s=12;t=25}
        & $a @{Op='conv-w2sf';d=25;s=12}
        & $a @{Op='load';d=14;s=20;Offset=44};& $a @{Op='sfmpy';d=25;s=25;t=14}
        & $a @{Op='load';d=14;s=20;Offset=48};& $a @{Op='sfsub';d=25;s=25;t=14}
        # Excitation.
        & $a @{Op='sfmpy';d=24;s=9;t=24};& $a @{Op='sfmpy';d=25;s=10;t=25};& $a @{Op='sfadd';d=22;s=24;t=25}
        # Recursion over the K most recent outputs.
        & $a @{Op='load';d=0;s=20;Offset=16};& $a @{Op='addi';d=16;s=11;i=0};& $a @{Op='addi';d=17;s=19;i=-4}
        & $a @{Op='label';Name='ex_tap'}
        & $a @{Op='load';d=24;s=16;Offset=0};& $a @{Op='load';d=25;s=17;Offset=0}
        & $a @{Op='sfmpy';d=24;s=24;t=25};& $a @{Op='sfsub';d=22;s=22;t=24}
        & $a @{Op='addi';d=16;s=16;i=4};& $a @{Op='addi';d=17;s=17;i=-4}
        & $a @{Op='addi';d=0;s=0;i=-1};& $a @{Op='gtu';d=0;s=0;t=13};& $a @{Op='jump-p';u=0;Label='ex_tap'}
        & $a @{Op='store';s=19;t=22;Offset=0};& $a @{Op='addi';d=19;s=19;i=4}
        # PCM16.
        & $a @{Op='load';d=24;s=20;Offset=52};& $a @{Op='sfmpy';d=24;s=22;t=24};& $a @{Op='conv-sf2w-chop';d=24;s=24}
        & $a @{Op='load';d=25;s=20;Offset=56};& $a @{Op='max';d=24;s=24;t=25}
        & $a @{Op='load';d=25;s=20;Offset=60};& $a @{Op='min';d=24;s=24;t=25}
        & $a @{Op='store-h';s=21;t=24;Offset=0};& $a @{Op='addi';d=21;s=21;i=2}
        & $a @{Op='addi';d=1;s=1;i=-1};& $a @{Op='gtu';d=0;s=1;t=13};& $a @{Op='jump-p';u=0;Label='ex_sample'}
        & $a @{Op='eq';d=0;s=13;t=13};& $a @{Op='jump-p';u=0;Label='ex_done'}
        # Out-of-line event loads.
        & $a @{Op='label';Name='ex_pitch_load'}
        & $a @{Op='load';d=3;s=2;Offset=0};& $a @{Op='load';d=5;s=2;Offset=4};& $a @{Op='load';d=6;s=2;Offset=8};& $a @{Op='addi';d=2;s=2;i=12}
        & $a @{Op='eq';d=0;s=13;t=13};& $a @{Op='jump-p';u=0;Label='ex_pitch_back'}
        & $a @{Op='label';Name='ex_wrap'};& $a @{Op='addi';d=24;s=6;i=0}
        & $a @{Op='eq';d=0;s=13;t=13};& $a @{Op='jump-p';u=0;Label='ex_wrap_back'}
        & $a @{Op='label';Name='ex_timbre_load'}
        & $a @{Op='load';d=8;s=7;Offset=0};& $a @{Op='load';d=9;s=7;Offset=4};& $a @{Op='load';d=10;s=7;Offset=8};& $a @{Op='addi';d=11;s=7;i=12}
        & $a @{Op='load';d=25;s=20;Offset=64};& $a @{Op='add';d=7;s=7;t=25}
        & $a @{Op='eq';d=0;s=13;t=13};& $a @{Op='jump-p';u=0;Label='ex_timbre_back'}
        & $a @{Op='label';Name='ex_done'}
    }
    New-KokoroHexagonKernel -Name 'voice-executor' -InputBytes $InputBytes -OutputBytes $OutputBytes -Job $job -PlaySamples $Samples -Bodies @(,@('ex_noop',@(@{Op='return'})))
}

# ---------------------------------------------------------------- recipes ----------------------------------------------
# The existing kernels are the builder's library. Each branch of tools/Emit-HexagonProbe.ps1 that sets $symbol is a
# recipe: its builder files, builder call and entry symbol. New-KokoroHexagonRecipeKernel runs that branch body with the
# emitter's own parameter defaults (plus overrides) and returns a kernel record the Definition path emits.
function Get-KokoroHexagonRecipe {
    param([string]$Name)
    $emitter=Join-Path $script:Root 'tools/Emit-HexagonProbe.ps1'
    $ast=[Management.Automation.Language.Parser]::ParseFile($emitter,[ref]$null,[ref]$null)
    $defaults=[ordered]@{}
    foreach($parameter in $ast.ParamBlock.Parameters){$parameterName=$parameter.Name.VariablePath.UserPath
        $isSwitch=@($parameter.Attributes|Where-Object{$_ -is [Management.Automation.Language.TypeConstraintAst] -and $_.TypeName.Name -eq 'switch'}).Count -gt 0
        $type=@($parameter.Attributes|Where-Object{$_ -is [Management.Automation.Language.TypeConstraintAst]}|Select-Object -First 1)
        $value=if($parameter.DefaultValue){$parameter.DefaultValue.Extent.Text}elseif($isSwitch){'$false'}else{'$null'}
        $defaults[$parameterName]=if($type -and -not $isSwitch -and $value -ne '$null'){"[$($type[0].TypeName.FullName)]($value)"}else{$value}}
    # The emitter's own top-level helper functions, which some recipe bodies call.
    $helpers=(@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Extent.Text}) -join "`n") -replace '\$PSScriptRoot','$hexTools'
    $rows=foreach($if in $ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst]},$true)){
        foreach($clause in $if.Clauses){
            $match=[regex]::Match($clause.Item1.Extent.Text,"^\`$Kernel -eq '([^']+)'$")
            if(-not $match.Success -or $clause.Item2.Extent.Text -notmatch '\$symbol\s*='){continue}
            if($match.Groups[1].Value -ceq 'Definition'){continue}
            if($Name -and $match.Groups[1].Value -cne $Name){continue}
            $body=$clause.Item2.Extent.Text
            [pscustomobject]@{PSTypeName='Kokoro.Hexagon.Recipe';Name=$match.Groups[1].Value;Line=$clause.Item1.Extent.StartLineNumber;
                Files=@([regex]::Matches($body,"'\.\.[\\/]src[\\/]([^']+)'")|ForEach-Object{'src/'+($_.Groups[1].Value -replace '\\','/')});
                Builders=@([regex]::Matches($body,'New-[A-Za-z0-9]+Steps')|ForEach-Object{$_.Value}|Select-Object -Unique);Body=$body;Defaults=$defaults;Helpers=$helpers}
        }
    }
    @($rows)
}

function Get-KokoroHexagonBuilder {
    # Every New-*Steps builder under src/, with its parameters: the reusable pieces recipes are made of.
    if($script:BuilderIndex){return $script:BuilderIndex}
    $script:BuilderIndex=@(Get-ChildItem (Join-Path $script:Root 'src') -Recurse -Filter *.ps1|ForEach-Object{$file=$_
        $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$null)
        $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -like 'New-*Steps'},$true)|ForEach-Object{
            $parameters=if($_.Body.ParamBlock){@($_.Body.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})}elseif($_.Parameters){@($_.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})}else{@()}
            [pscustomobject]@{Name=$_.Name;File=[IO.Path]::GetRelativePath($script:Root,$file.FullName) -replace '\\','/';Line=$_.Extent.StartLineNumber;Parameters=$parameters}}})
    $script:BuilderIndex
}

function New-KokoroHexagonRecipeKernel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,[hashtable]$Parameters=@{},[string]$OutputDirectory=(Join-Path $script:Build "recipes/$Name/work"))
    $recipe=@(Get-KokoroHexagonRecipe -Name $Name);if($recipe.Count -ne 1){throw "No unique recipe '$Name'."}
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $tools=Join-Path $script:Root 'tools'
    $assign=foreach($key in $recipe[0].Defaults.Keys){
        if($Parameters.ContainsKey($key)){continue}
        if($key -in 'Kernel','OutputDirectory','Definition'){continue}
        "`$$key=$($recipe[0].Defaults[$key] -replace '\$PSScriptRoot','$hexTools')"}
    $text="param(`$hexTools,`$hexParameters,`$OutputDirectory,`$Kernel)`n"+"foreach(`$hexKey in `$hexParameters.Keys){Set-Variable -Name `$hexKey -Value `$hexParameters[`$hexKey]}`n"+($assign -join "`n")+"`n"+
        $recipe[0].Helpers+"`n"+". (Join-Path `$hexTools '../src/hexagon/Hexagon.ps1')`n"+($recipe[0].Body.Trim().TrimStart('{').TrimEnd('}') -replace '\$PSScriptRoot','$hexTools')+
        "`n[pscustomobject]@{Steps=@(`$steps);Symbol=`$symbol;Soname=`$soname;Run=`$(if(Get-Variable run -ErrorAction SilentlyContinue){`$run}else{`$null})}"
    $result=& ([scriptblock]::Create($text)) $tools $Parameters $OutputDirectory $Name
    [pscustomobject]@{PSTypeName='Kokoro.Hexagon.Kernel';Name=$Name;Steps=$result.Steps;Symbol=$result.Symbol;Soname=$result.Soname;Run=$result.Run;Recipe=$recipe[0]}
}

function Test-KokoroHexagonRecipeEquivalence {
    # Builder rebuild (recipe -> Definition path) versus the emitter's own -Kernel path: identical library bytes or not.
    param([Parameter(Mandatory)][string]$Name,[hashtable]$Parameters=@{})
    $base=Join-Path $script:Build "recipes/$Name";$emitterDirectory=Join-Path $base 'emitter';$builderDirectory=Join-Path $base 'builder'
    $row=[ordered]@{Recipe=$Name;Status='';Identical=$false;EmitterSHA256='';BuilderSHA256='';Bytes=0;Seconds=0;Reason=''}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{$null=& (Join-Path $script:Root 'tools/Emit-HexagonProbe.ps1') -Kernel $Name -OutputDirectory $emitterDirectory -Force @Parameters}
    catch{$row.Status='EmitterFails';$row.Reason=$_.Exception.Message.Split("`n")[0];$row.Seconds=[Math]::Round($watch.Elapsed.TotalSeconds,1);return [pscustomobject]$row}
    try{
        $kernel=New-KokoroHexagonRecipeKernel -Name $Name -Parameters $Parameters
        $null=& (Join-Path $script:Root 'tools/Emit-HexagonProbe.ps1') -Kernel Definition -Definition $kernel -OutputDirectory $builderDirectory -Force
        $a=Join-Path $emitterDirectory $kernel.Soname;$b=Join-Path $builderDirectory $kernel.Soname
        $row.EmitterSHA256=(Get-FileHash $a).Hash;$row.BuilderSHA256=(Get-FileHash $b).Hash;$row.Bytes=(Get-Item $b).Length
        $row.Identical=($row.EmitterSHA256 -ceq $row.BuilderSHA256);$row.Status=if($row.Identical){'Identical'}else{'BuilderDiffers'}
    }catch{$row.Status='BuilderFails';$row.Reason=$_.Exception.Message.Split("`n")[0]}
    $row.Seconds=[Math]::Round($watch.Elapsed.TotalSeconds,1)
    [pscustomobject]$row
}

function Invoke-KokoroHexagonKernelCommand {
    # Entrypoint cases: Recipes, Builders, RecipeSweep (every recipe or -Recipe names), SourcePhase (device, corpus-1 F0).
    param([Parameter(Mandatory)][ValidateSet('Recipes','Builders','RecipeSweep','SourcePhase')][string]$Case,[string[]]$Recipe,[ValidateRange(1,31)][int]$Runs=3)
    switch($Case){
        'Recipes' {Get-KokoroHexagonRecipe|Select-Object Name,Line,Builders,Files}
        'Builders' {Get-KokoroHexagonBuilder}
        'RecipeSweep' {
            $names=if($Recipe){$Recipe}else{(Get-KokoroHexagonRecipe).Name}
            $out=Join-Path $script:Build 'recipes/sweep.csv';[void][IO.Directory]::CreateDirectory((Split-Path $out));if(Test-Path $out){Remove-Item $out}
            foreach($recipeName in $names){$row=Test-KokoroHexagonRecipeEquivalence -Name $recipeName;$row|Export-Csv -LiteralPath $out -Append;$row}
        }
        'SourcePhase' {
            $raw=[IO.File]::ReadAllBytes((Join-Path $script:Root 'build/generator-constants-gate2b-20261012-140157/generator-corpus-1/f0.f32'))
            $hz=[float[]]::new($raw.Length/4);[Buffer]::BlockCopy($raw,0,$hz,0,$raw.Length)
            $kernel=Get-KokoroSourcePhaseKernel -Frames $hz.Length;$inputData=New-KokoroSourcePhaseInput -F0 ([double[]]$hz)
            $result=Invoke-KokoroHexagonKernel -Kernel $kernel -InputData $inputData -Runs $Runs
            [pscustomobject]@{Passed=$result.Passed;StartupRestored=$result.StartupRestored;MedianRegionMs=$result.MedianRegionMs;
                Mismatches=($result.Mismatches|ForEach-Object{"$($_.Region): $($_.Mismatches) of $($_.Expected)"}) -join '; ';Library=$result.LibrarySHA256}
        }
    }
}

Export-ModuleMember -Function *-Kokoro*
