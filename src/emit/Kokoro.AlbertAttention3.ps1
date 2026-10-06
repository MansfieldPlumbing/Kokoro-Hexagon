#requires -Version 7.4
# Direct V73 ALBERT attention core specialized to three tokens, 12 heads and
# 64 channels per head. Input is fused QKV [3,2304], row-major; output is
# context [3,768]. Score reductions and context combination are scalar FP32.
# The rejected HVX context candidate is not used. One diagnostic invocation.
function New-KokoroAlbertAttention3Steps {
    param(
        [switch]$RegionBody,
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')][string]$LabelPrefix='attention',
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')][string]$DomainFailureLabel='domain'
    )
    if (-not $RegionBody -and ($PSBoundParameters.ContainsKey('LabelPrefix') -or
        $PSBoundParameters.ContainsKey('DomainFailureLabel'))) { throw 'Region label options require RegionBody.' }
    $steps=[Collections.Generic.List[hashtable]]::new()
    $imm={param([int]$r,[uint32]$v)$steps.Add(@{Op='lo';x=$r;i=($v-band 65535)});$steps.Add(@{Op='hi';x=$r;i=($v-shr 16)})}
    $fp={param([int]$r,[float]$v)& $imm $r ([BitConverter]::SingleToUInt32Bits($v))}
    $ptr={param([int]$r,[int]$base,[int]$offset)
        $steps.Add(@{Op='addi';d=$r;s=$base;i=0})
        if($offset){& $imm 13 ([uint32]$offset);$steps.Add(@{Op='add';d=$r;s=$r;t=13})}
    }
    foreach($dispatch in @(@(0x00020001,'open'),@(0x01000010,'success'),@(0x02010100,'attention'))){
        & $imm 4 $dispatch[0];$steps.Add(@{Op='eq';d=0;s=2;t=4});$steps.Add(@{Op='jump-p';u=0;Label=$dispatch[1]})
    }
    $steps.Add(@{Op='imm';d=0;i=20});$steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='bad'});$steps.Add(@{Op='imm';d=0;i=14});$steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='domain'});$steps.Add(@{Op='imm';d=0;i=33});$steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='open'});$steps.Add(@{Op='imm';d=4;i=0});$steps.Add(@{Op='eq';d=0;s=3;t=4});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
    $steps.Add(@{Op='imm';d=4;i=1});$steps.Add(@{Op='store';s=3;t=4;Offset=16});$steps.Add(@{Op='imm';d=4;i=0});$steps.Add(@{Op='store';s=3;t=4;Offset=20})
    $steps.Add(@{Op='label';Name='success'});$steps.Add(@{Op='imm';d=0;i=0});$steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='attention'});$steps.Add(@{Op='imm';d=15;i=0});$steps.Add(@{Op='eq';d=0;s=3;t=15});$steps.Add(@{Op='jump-p';u=0;Label='bad'})
    foreach($arg in @(@(4,27648),@(12,9216))){$steps.Add(@{Op='load';d=0;s=3;Offset=$arg[0]});& $imm 1 ([uint32]($arg[1]-1));$steps.Add(@{Op='gtu';d=0;s=0;t=1});$steps.Add(@{Op='jump-p';u=0;Label="length_$($arg[0])"});$steps.Add(@{Op='imm';d=0;i=14});$steps.Add(@{Op='return'});$steps.Add(@{Op='label';Name="length_$($arg[0])"})}
    foreach($arg in @(@(0,4),@(8,5))){$steps.Add(@{Op='load';d=$arg[1];s=3;Offset=$arg[0]});$steps.Add(@{Op='eq';d=0;s=$arg[1];t=15});$steps.Add(@{Op='jump-p';u=0;Label='bad'});$steps.Add(@{Op='imm';d=0;i=3});$steps.Add(@{Op='and';d=0;s=$arg[1];t=0});$steps.Add(@{Op='gtu';d=0;s=0;t=15});$steps.Add(@{Op='jump-p';u=0;Label='bad'})}
    # Entire QKV input must be finite and bounded before any multiply.
    & $imm 12 0x7fffffff;& $fp 13 1024.0
    $steps.Add(@{Op='addi';d=6;s=4;i=0});& $imm 7 6912
    $steps.Add(@{Op='label';Name='scan'})
    $steps.Add(@{Op='load';d=0;s=6;Offset=0});$steps.Add(@{Op='and';d=0;s=0;t=12});$steps.Add(@{Op='gtu';d=0;s=0;t=13});$steps.Add(@{Op='jump-p';u=0;Label='domain'})
    $steps.Add(@{Op='addi';d=6;s=6;i=4});$steps.Add(@{Op='addi';d=7;s=7;i=-1});$steps.Add(@{Op='gtu';d=0;s=7;t=15});$steps.Add(@{Op='jump-p';u=0;Label='scan'})
    $arithmeticStart=$steps.Count
    for($head=0;$head -lt 12;$head++){
        for($query=0;$query -lt 3;$query++){
            $rowId=$head*3+$query
            & $fp 14 ([float](1.0/[Math]::Sqrt(64.0)))
            for($key=0;$key -lt 3;$key++){
                & $ptr 6 4 ($query*9216+$head*256)
                & $ptr 7 4 ($key*9216+3072+$head*256)
                $steps.Add(@{Op='imm';d=8;i=64});$steps.Add(@{Op='imm';d=9;i=0})
                $steps.Add(@{Op='label';Name="dot_${rowId}_$key"})
                $steps.Add(@{Op='load';d=0;s=6;Offset=0});$steps.Add(@{Op='load';d=1;s=7;Offset=0});$steps.Add(@{Op='sfmpy';d=0;s=0;t=1});$steps.Add(@{Op='sfadd';d=9;s=9;t=0})
                $steps.Add(@{Op='addi';d=6;s=6;i=4});$steps.Add(@{Op='addi';d=7;s=7;i=4});$steps.Add(@{Op='addi';d=8;s=8;i=-1});$steps.Add(@{Op='gtu';d=0;s=8;t=15});$steps.Add(@{Op='jump-p';u=0;Label="dot_${rowId}_$key"})
                $steps.Add(@{Op='sfmpy';d=(10+$key);s=9;t=14})
            }
            $steps.Add(@{Op='sfmax';d=13;s=10;t=11});$steps.Add(@{Op='sfmax';d=13;s=13;t=12})
            foreach($r in 10,11,12){$steps.Add(@{Op='sfsub';d=($r-4);s=$r;t=13})}
            & $imm 13 0x7fffffff;& $fp 14 64.0
            foreach($r in 6,7,8){$steps.Add(@{Op='and';d=0;s=$r;t=13});$steps.Add(@{Op='gtu';d=0;s=0;t=14});$steps.Add(@{Op='jump-p';u=0;Label='domain'})}
            & $fp 9 ([float](1.0/64.0));foreach($r in 6,7,8){$steps.Add(@{Op='sfmpy';d=$r;s=$r;t=9})}
            & $fp 9 ([float](1.0/5040.0));foreach($r in 10,11,12){$steps.Add(@{Op='addi';d=$r;s=9;i=0})}
            foreach($coefficient in @([float](1.0/720.0),[float](1.0/120.0),[float](1.0/24.0),[float](1.0/6.0),[float]0.5,[float]1.0,[float]1.0)){
                & $fp 9 $coefficient
                for($lane=0;$lane -lt 3;$lane++){$steps.Add(@{Op='sfmpy';d=(10+$lane);s=(10+$lane);t=(6+$lane)});$steps.Add(@{Op='sfadd';d=(10+$lane);s=(10+$lane);t=9})}
            }
            for($square=0;$square -lt 6;$square++){foreach($r in 10,11,12){$steps.Add(@{Op='sfmpy';d=$r;s=$r;t=$r})}}
            $steps.Add(@{Op='sfadd';d=13;s=10;t=11});$steps.Add(@{Op='sfadd';d=13;s=13;t=12});$steps.Add(@{Op='sfinvsqrta';d=9;e=1;s=13})
            & $fp 0 0.5;& $fp 1 1.5
            for($iteration=0;$iteration -lt 3;$iteration++){$steps.Add(@{Op='sfmpy';d=2;s=13;t=0});$steps.Add(@{Op='sfmpy';d=2;s=2;t=9});$steps.Add(@{Op='sfmpy';d=2;s=2;t=9});$steps.Add(@{Op='sfsub';d=2;s=1;t=2});$steps.Add(@{Op='sfmpy';d=9;s=9;t=2})}
            $steps.Add(@{Op='sfmpy';d=9;s=9;t=9});foreach($r in 10,11,12){$steps.Add(@{Op='sfmpy';d=$r;s=$r;t=9})}
            & $ptr 6 4 (6144+$head*256);& $ptr 7 4 (15360+$head*256);& $ptr 8 4 (24576+$head*256);& $ptr 9 5 ($query*3072+$head*256)
            $steps.Add(@{Op='imm';d=13;i=64});$steps.Add(@{Op='label';Name="context_$rowId"})
            $steps.Add(@{Op='load';d=0;s=6;Offset=0});$steps.Add(@{Op='sfmpy';d=0;s=0;t=10})
            $steps.Add(@{Op='load';d=1;s=7;Offset=0});$steps.Add(@{Op='sfmpy';d=1;s=1;t=11});$steps.Add(@{Op='sfadd';d=0;s=0;t=1})
            $steps.Add(@{Op='load';d=1;s=8;Offset=0});$steps.Add(@{Op='sfmpy';d=1;s=1;t=12});$steps.Add(@{Op='sfadd';d=0;s=0;t=1});$steps.Add(@{Op='store';s=9;t=0;Offset=0})
            foreach($r in 6,7,8,9){$steps.Add(@{Op='addi';d=$r;s=$r;i=4})}
            $steps.Add(@{Op='addi';d=13;s=13;i=-1});$steps.Add(@{Op='gtu';d=0;s=13;t=15});$steps.Add(@{Op='jump-p';u=0;Label="context_$rowId"})
        }
    }
    if ($RegionBody) {
        $body=[Collections.Generic.List[hashtable]]::new()
        $body.Add(@{Op='load';d=4;s=3;Offset=0})
        $body.Add(@{Op='load';d=5;s=3;Offset=8})
        $body.Add(@{Op='imm';d=15;i=0})
        $labels=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        for ($index=$arithmeticStart; $index -lt $steps.Count; $index++) {
            $step=$steps[$index].Clone()
            if ($step.Op -eq 'label') {
                $step.Name=$LabelPrefix+'_'+$step.Name
                if (-not $labels.Add($step.Name)) { throw 'Duplicate region label.' }
            }
            if ($step.ContainsKey('Label')) {
                $step.Label=if ($step.Label -eq 'domain') { $DomainFailureLabel } else { $LabelPrefix+'_'+$step.Label }
            }
            $body.Add($step)
        }
        if ($labels.Contains($DomainFailureLabel)) { throw 'External failure label collides with region label.' }
        foreach ($step in $body) {
            if ($step.ContainsKey('Label') -and $step.Label -ne $DomainFailureLabel -and -not $labels.Contains($step.Label)) {
                throw 'Region branch target is unresolved.'
            }
        }
        return $body.ToArray()
    }
    $steps.Add(@{Op='imm';d=0;i=0});$steps.Add(@{Op='return'});$steps.ToArray()
}

function New-KokoroAlbertAttention3Region {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')][string]$LabelPrefix,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')][string]$DomainFailureLabel
    )
    [pscustomobject]@{
        Schema=1; Kind='albert_attention_context_3'; Geometry=[int[]]@(3,12,64)
        DescriptorRegister=3; DescriptorLayout='remote_arg32_qkv_context'; DescriptorBytes=16
        DescriptorLifetime='stable_and_disjoint_from_output_until_region_exit'
        MinimumBufferBytes=[int[]]@(27648,9216)
        InputLayout='token_major_fused_qkv'; OutputLayout='token_major_context'
        RequiredEntryAdmission=[string[]]@('exact_geometry','accessible_descriptor','minimum_buffer_lengths',
            'nonzero_aligned_pointers','nonwrapping_disjoint_buffer_ranges','finite_input_absolute_value_at_most_1024')
        ScalarClobbers=[int[]]@(0,1,2,4,5,6,7,8,9,10,11,12,13,14,15)
        PredicateClobbers=[int[]]@(0,1)
        ExitKind='fallthrough_or_external_domain_failure'; ExternalBranches=[string[]]@($DomainFailureLabel)
        ExternalFailureStatus=33; MaximumCenteredScoreMagnitude=64
        EntryAdmissionIncluded=$false; NumericalDSPExecutionVerified=$false
        Steps=@(New-KokoroAlbertAttention3Steps -RegionBody -LabelPrefix $LabelPrefix -DomainFailureLabel $DomainFailureLabel)
    }
}
