# Direct V73 diagnostic: three-token ALBERT dense projection and residual
# LayerNorm in one invocation. All arithmetic is DSP scalar FP32.
# Semantics: Transformers 8ac2b916b042b1f78b75c9eb941c0f5d2cdd8e10
# modeling_albert.py:348-350. Torch 08187d9e0fba026dc8217405802ab5381dc88d90
# layer_norm_kernel.cpp:82-86; moments_utils.h:117,187 (population variance).
# Two-pass centered FP32 moments differ in reduction order from Torch Welford;
# this candidate requires independent numerical and physical gates.
# Diagnostic remote_arg buffers: geometry {3,768,768}; [context,hidden];
# [dense W(output,input),dense bias,LN gain,LN bias]; [projected,normalized].
# Inputs/weights and computed residual magnitudes are bounded by 1024.
function New-KokoroAlbertAttentionOutput3Steps {
    param(
        [switch]$RegionBody,
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')]
        [string]$LabelPrefix = 'attention_output',
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')]
        [string]$DomainFailureLabel = 'domain'
    )
    if (-not $RegionBody -and
        ($PSBoundParameters.ContainsKey('LabelPrefix') -or
         $PSBoundParameters.ContainsKey('DomainFailureLabel'))) {
        throw 'Region label options require RegionBody.'
    }
    $steps = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r, [uint32]$v)
        $steps.Add(@{Op='lo';x=$r;i=($v -band 65535)})
        $steps.Add(@{Op='hi';x=$r;i=($v -shr 16)})
    }
    $fp = { param([int]$r, [float]$v) & $imm $r ([BitConverter]::SingleToUInt32Bits($v)) }
    foreach ($dispatch in @(@(0x00020001,'open'),@(0x01000010,'success'),@(0x02030100,'output'))) {
        & $imm 4 $dispatch[0]
        $steps.Add(@{Op='eq';d=0;s=2;t=4}); $steps.Add(@{Op='jump-p';u=0;Label=$dispatch[1]})
    }
    $steps.Add(@{Op='imm';d=0;i=20}); $steps.Add(@{Op='return'})
    foreach ($failureEntry in @(@('bad',14),@('domain',33))) {
        $steps.Add(@{Op='label';Name=$failureEntry[0]})
        $steps.Add(@{Op='imm';d=0;i=$failureEntry[1]}); $steps.Add(@{Op='return'})
    }
    $steps.Add(@{Op='label';Name='open'}); $steps.Add(@{Op='imm';d=4;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=4}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    $steps.Add(@{Op='imm';d=4;i=1}); $steps.Add(@{Op='store';s=3;t=4;Offset=16})
    $steps.Add(@{Op='imm';d=4;i=0}); $steps.Add(@{Op='store';s=3;t=4;Offset=20})
    $steps.Add(@{Op='label';Name='success'})
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='output'}); $steps.Add(@{Op='imm';d=15;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    # Minimum accessible lengths, alignment, address wrap, and disjoint ranges
    # are admitted before reading geometry, tensor data, or storing output.
    $buffers = @(@(0,7,12),@(8,4,18432),@(16,5,2368512),@(24,6,18432))
    foreach ($b in $buffers) {
        $offset = $b[0]; $register = $b[1]; $bytes = $b[2]
        $steps.Add(@{Op='load';d=0;s=3;Offset=($offset+4)}); & $imm 1 ($bytes-1)
        $steps.Add(@{Op='gtu';d=0;s=0;t=1}); $steps.Add(@{Op='jump-p';u=0;Label="length_$offset"})
        $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="length_$offset"})
        $steps.Add(@{Op='load';d=$register;s=3;Offset=$offset})
        $steps.Add(@{Op='eq';d=0;s=$register;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
        $steps.Add(@{Op='imm';d=0;i=3}); $steps.Add(@{Op='and';d=0;s=$register;t=0})
        $steps.Add(@{Op='gtu';d=0;s=0;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
        & $imm 1 ($bytes-1); $steps.Add(@{Op='add';d=0;s=$register;t=1})
        $steps.Add(@{Op='gtu';d=0;s=$register;t=0}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    }
    for ($i=0; $i -lt $buffers.Count; $i++) {
        for ($j=$i+1; $j -lt $buffers.Count; $j++) {
            $a=$buffers[$i]; $b=$buffers[$j]; $label="disjoint_${i}_$j"
            & $imm 1 ($a[2]-1); $steps.Add(@{Op='add';d=0;s=$a[1];t=1})
            $steps.Add(@{Op='gtu';d=0;s=$b[1];t=0}); $steps.Add(@{Op='jump-p';u=0;Label=$label})
            & $imm 1 ($b[2]-1); $steps.Add(@{Op='add';d=0;s=$b[1];t=1})
            $steps.Add(@{Op='gtu';d=0;s=$a[1];t=0}); $steps.Add(@{Op='jump-p';u=0;Label=$label})
            $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
            $steps.Add(@{Op='label';Name=$label})
        }
    }
    foreach ($dim in @(@(0,3),@(4,768),@(8,768))) {
        $steps.Add(@{Op='load';d=0;s=7;Offset=$dim[0]}); & $imm 1 $dim[1]
        $steps.Add(@{Op='eq';d=0;s=0;t=1}); $steps.Add(@{Op='jump-p';u=0;Label="dimension_$($dim[0])"})
        $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name="dimension_$($dim[0])"})
    }
    & $imm 12 0x7fffffff; & $fp 13 1024
    foreach ($scan in @(@('input',4,4608),@('weights',5,592128))) {
        $steps.Add(@{Op='addi';d=9;s=$scan[1];i=0}); & $imm 8 $scan[2]
        $steps.Add(@{Op='label';Name="scan_$($scan[0])"})
        $steps.Add(@{Op='load';d=0;s=9;Offset=0}); $steps.Add(@{Op='and';d=0;s=0;t=12})
        $steps.Add(@{Op='gtu';d=0;s=0;t=13}); $steps.Add(@{Op='jump-p';u=0;Label='domain'})
        $steps.Add(@{Op='addi';d=9;s=9;i=4}); $steps.Add(@{Op='addi';d=8;s=8;i=-1})
        $steps.Add(@{Op='gtu';d=0;s=8;t=15}); $steps.Add(@{Op='jump-p';u=0;Label="scan_$($scan[0])"})
    }
    # Projection: separate FP32 multiply/add, bias-first, matching the
    # existing scalar linear tile. Retain projected values for the diagnostic.
    $arithmeticStart = $steps.Count
    & $imm 7 2359296; $steps.Add(@{Op='add';d=7;s=5;t=7})
    $steps.Add(@{Op='imm';d=8;i=768}); $steps.Add(@{Op='imm';d=14;i=0})
    $steps.Add(@{Op='label';Name='output_channel'})
    $steps.Add(@{Op='load';d=4;s=3;Offset=8}); $steps.Add(@{Op='load';d=6;s=3;Offset=24})
    $steps.Add(@{Op='add';d=6;s=6;t=14}); $steps.Add(@{Op='imm';d=9;i=3})
    $steps.Add(@{Op='label';Name='projection_row'}); $steps.Add(@{Op='load';d=2;s=7;Offset=0})
    $steps.Add(@{Op='addi';d=10;s=4;i=0}); $steps.Add(@{Op='addi';d=11;s=5;i=0})
    $steps.Add(@{Op='imm';d=12;i=768}); $steps.Add(@{Op='label';Name='projection_reduce'})
    $steps.Add(@{Op='load';d=0;s=10;Offset=0}); $steps.Add(@{Op='load';d=1;s=11;Offset=0})
    $steps.Add(@{Op='sfmpy';d=0;s=0;t=1}); $steps.Add(@{Op='sfadd';d=2;s=2;t=0})
    foreach ($r in 10,11) { $steps.Add(@{Op='addi';d=$r;s=$r;i=4}) }
    $steps.Add(@{Op='addi';d=12;s=12;i=-1}); $steps.Add(@{Op='gtu';d=0;s=12;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='projection_reduce'}); $steps.Add(@{Op='store';s=6;t=2;Offset=0})
    foreach ($r in 4,6) { $steps.Add(@{Op='addi';d=$r;s=$r;i=3072}) }
    $steps.Add(@{Op='addi';d=9;s=9;i=-1}); $steps.Add(@{Op='gtu';d=0;s=9;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='projection_row'})
    $steps.Add(@{Op='addi';d=5;s=5;i=3072}); $steps.Add(@{Op='addi';d=7;s=7;i=4})
    $steps.Add(@{Op='addi';d=14;s=14;i=4}); $steps.Add(@{Op='addi';d=8;s=8;i=-1})
    $steps.Add(@{Op='gtu';d=0;s=8;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='output_channel'})
    # Reload row pointers. Output second half materializes the FP32 residual
    # before moments, as the original Torch add does. First half retains P.
    $steps.Add(@{Op='load';d=4;s=3;Offset=8}); & $imm 0 9216
    $steps.Add(@{Op='add';d=4;s=4;t=0}); $steps.Add(@{Op='load';d=5;s=3;Offset=24})
    $steps.Add(@{Op='add';d=6;s=5;t=0}); $steps.Add(@{Op='imm';d=7;i=3})
    $steps.Add(@{Op='label';Name='norm_row'})
    $steps.Add(@{Op='addi';d=8;s=4;i=0}); $steps.Add(@{Op='addi';d=9;s=5;i=0})
    $steps.Add(@{Op='addi';d=2;s=6;i=0}); $steps.Add(@{Op='imm';d=14;i=768})
    # Anchor the mean at the first materialized residual. Summing centered
    # offsets avoids accumulating the common offset of a constant row.
    $steps.Add(@{Op='load';d=0;s=4;Offset=0}); $steps.Add(@{Op='load';d=1;s=5;Offset=0})
    $steps.Add(@{Op='sfadd';d=11;s=0;t=1})
    $steps.Add(@{Op='imm';d=10;i=0}); & $imm 12 0x7fffffff; & $fp 13 1024
    $steps.Add(@{Op='label';Name='residual_mean'})
    $steps.Add(@{Op='load';d=0;s=8;Offset=0}); $steps.Add(@{Op='load';d=1;s=9;Offset=0})
    $steps.Add(@{Op='sfadd';d=0;s=0;t=1}); $steps.Add(@{Op='and';d=1;s=0;t=12})
    $steps.Add(@{Op='gtu';d=0;s=1;t=13}); $steps.Add(@{Op='jump-p';u=0;Label='domain'})
    $steps.Add(@{Op='store';s=2;t=0;Offset=0}); $steps.Add(@{Op='sfsub';d=1;s=0;t=11})
    $steps.Add(@{Op='sfadd';d=10;s=10;t=1})
    foreach ($r in 8,9,2) { $steps.Add(@{Op='addi';d=$r;s=$r;i=4}) }
    $steps.Add(@{Op='addi';d=14;s=14;i=-1}); $steps.Add(@{Op='gtu';d=0;s=14;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='residual_mean'})
    & $fp 12 (1.0/768); $steps.Add(@{Op='sfmpy';d=10;s=10;t=12})
    $steps.Add(@{Op='sfadd';d=10;s=10;t=11})
    $steps.Add(@{Op='imm';d=11;i=0}); $steps.Add(@{Op='addi';d=9;s=6;i=0})
    $steps.Add(@{Op='imm';d=14;i=768}); $steps.Add(@{Op='label';Name='variance'})
    $steps.Add(@{Op='load';d=0;s=9;Offset=0}); $steps.Add(@{Op='sfsub';d=0;s=0;t=10})
    $steps.Add(@{Op='sfmpy';d=0;s=0;t=0}); $steps.Add(@{Op='sfadd';d=11;s=11;t=0})
    $steps.Add(@{Op='addi';d=9;s=9;i=4}); $steps.Add(@{Op='addi';d=14;s=14;i=-1})
    $steps.Add(@{Op='gtu';d=0;s=14;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='variance'})
    $steps.Add(@{Op='sfmpy';d=11;s=11;t=12}); & $fp 0 1e-12
    $steps.Add(@{Op='sfadd';d=11;s=11;t=0})
    # V73 PRM Rev. AB p.470. Positive normal seed domain follows from epsilon
    # and the residual bound. Three separate-FP32 Newton refinements.
    $steps.Add(@{Op='sfinvsqrta';d=12;e=1;s=11}); & $fp 13 0.5; & $fp 14 1.5
    for ($i=0; $i -lt 3; $i++) {
        $steps.Add(@{Op='sfmpy';d=0;s=11;t=13}); $steps.Add(@{Op='sfmpy';d=0;s=0;t=12})
        $steps.Add(@{Op='sfmpy';d=0;s=0;t=12}); $steps.Add(@{Op='sfsub';d=0;s=14;t=0})
        $steps.Add(@{Op='sfmpy';d=12;s=12;t=0})
    }
    $steps.Add(@{Op='load';d=8;s=3;Offset=16}); & $imm 0 2362368
    $steps.Add(@{Op='add';d=8;s=8;t=0}); $steps.Add(@{Op='addi';d=9;s=8;i=3072})
    $steps.Add(@{Op='addi';d=2;s=6;i=0}); $steps.Add(@{Op='imm';d=14;i=768})
    $steps.Add(@{Op='label';Name='norm_apply'})
    $steps.Add(@{Op='load';d=0;s=2;Offset=0}); $steps.Add(@{Op='sfsub';d=0;s=0;t=10})
    $steps.Add(@{Op='sfmpy';d=0;s=0;t=12}); $steps.Add(@{Op='load';d=1;s=8;Offset=0})
    $steps.Add(@{Op='sfmpy';d=0;s=0;t=1}); $steps.Add(@{Op='load';d=1;s=9;Offset=0})
    $steps.Add(@{Op='sfadd';d=0;s=0;t=1}); $steps.Add(@{Op='store';s=2;t=0;Offset=0})
    foreach ($r in 2,8,9) { $steps.Add(@{Op='addi';d=$r;s=$r;i=4}) }
    $steps.Add(@{Op='addi';d=14;s=14;i=-1}); $steps.Add(@{Op='gtu';d=0;s=14;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='norm_apply'})
    foreach ($r in 4,5,6) { $steps.Add(@{Op='addi';d=$r;s=$r;i=3072}) }
    $steps.Add(@{Op='addi';d=7;s=7;i=-1}); $steps.Add(@{Op='gtu';d=0;s=7;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='norm_row'})
    if ($RegionBody) {
        # The outer graph owns descriptor/buffer/domain admission. This body
        # has no RPC dispatch or return; domain failure branches to its owner.
        # Initialize the two registers previously established by the wrapper.
        $body = [Collections.Generic.List[hashtable]]::new()
        $body.Add(@{Op='load';d=5;s=3;Offset=16})
        $body.Add(@{Op='imm';d=15;i=0})
        $regionLabels = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        for ($index=$arithmeticStart; $index -lt $steps.Count; $index++) {
            $step = $steps[$index].Clone()
            if ($step.Op -eq 'label') {
                $step.Name = $LabelPrefix + '_' + $step.Name
                if (-not $regionLabels.Add($step.Name)) { throw 'Duplicate region label.' }
            }
            if ($step.ContainsKey('Label')) {
                $step.Label = if ($step.Label -eq 'domain') {
                    $DomainFailureLabel
                } else { $LabelPrefix + '_' + $step.Label }
            }
            $body.Add($step)
        }
        if ($regionLabels.Contains($DomainFailureLabel)) {
            throw 'External failure label collides with a region label.'
        }
        foreach ($step in $body) {
            if ($step.ContainsKey('Label') -and $step.Label -ne $DomainFailureLabel -and
                -not $regionLabels.Contains($step.Label)) {
                throw 'Region branch target is unresolved.'
            }
        }
        return $body.ToArray()
    }
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    $steps.ToArray()
}

function New-KokoroAlbertAttentionOutput3Region {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')][string]$LabelPrefix,
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,63}$')][string]$DomainFailureLabel
    )
    [pscustomobject]@{
        Schema = 1
        Kind = 'albert_attention_output_projection_residual_layernorm_3'
        Geometry = [int[]]@(3,768,768)
        DescriptorRegister = 3
        DescriptorLayout = 'remote_arg32_geometry_input_weights_output'
        DescriptorBytes = 32
        DescriptorLifetime = 'stable_and_disjoint_from_output_until_region_exit'
        MinimumBufferBytes = [int[]]@(12,18432,2368512,18432)
        InputLayout = 'context_then_hidden'
        WeightLayout = 'output_input_bias_ln_gain_ln_bias'
        OutputLayout = 'projected_then_normalized'
        RequiredEntryAdmission = [string[]]@(
            'exact_geometry', 'accessible_descriptor', 'minimum_buffer_lengths',
            'nonzero_aligned_pointers', 'nonwrapping_disjoint_buffer_ranges',
            'finite_input_and_weights_absolute_value_at_most_1024'
        )
        ScalarClobbers = [int[]]@(0,1,2,4,5,6,7,8,9,10,11,12,13,14,15)
        PredicateClobbers = [int[]]@(0,1)
        ExitKind = 'fallthrough_or_external_domain_failure'
        ExternalBranches = [string[]]@($DomainFailureLabel)
        ExternalFailureStatus = 33
        EntryAdmissionIncluded = $false
        NumericalDSPExecutionVerified = $false
        Steps = @(New-KokoroAlbertAttentionOutput3Steps -RegionBody `
            -LabelPrefix $LabelPrefix -DomainFailureLabel $DomainFailureLabel)
    }
}
