#requires -Version 7.4
# One direct DSP invocation: QKV -> context -> dense -> residual LayerNorm.
# Fixed diagnostic shape, not a general encoder or product dispatch backend.
# Original ALBERT semantics and arithmetic source pins are in the two regions.
. (Join-Path $PSScriptRoot 'Kokoro.AlbertAttention3.ps1')
. (Join-Path $PSScriptRoot 'Kokoro.AlbertAttentionOutput3.ps1')
function New-KokoroAlbertConnectedAttention3Steps {
    $steps=[Collections.Generic.List[hashtable]]::new()
    $original=@(New-KokoroAlbertAttentionOutput3Steps)
    $start=@(for ($i=0; $i -lt $original.Count; $i++) { if ($original[$i].Op -eq 'label' -and $original[$i].Name -ceq 'output_channel') { $i-5 } })
    if ($start.Count -ne 1) { throw 'Outer admission boundary is not unique.' }
    # Reuse the checked four-buffer admission, with longer input/output edges.
    # Geometry 12; input [QKV,original hidden] 36864; weights 2368512;
    # output arena [context,hidden copy,projected,normalized] 36864 bytes.
    $lengthEdits=0; $scanEdits=0
    for ($i=0; $i -lt $start[0]; $i++) {
        $s=$original[$i].Clone()
        if ($s.Op -eq 'lo' -and $s.x -eq 1 -and $s.i -eq 18431) { $s.i=36863; $lengthEdits++ }
        if ($s.Op -eq 'lo' -and $s.x -eq 8 -and $s.i -eq 4608) { $s.i=9216; $scanEdits++ }
        $steps.Add($s)
    }
    # Ten anchors cover length checks, end-address wrap, and pairwise alias
    # checks for both expanded ranges, not just their two minimum lengths.
    if ($lengthEdits -ne 10 -or $scanEdits -ne 1) { throw 'Outer admission adaptation differs.' }
    $imm={param([int]$r,[uint32]$v) $steps.Add(@{Op='lo';x=$r;i=($v -band 65535)}); $steps.Add(@{Op='hi';x=$r;i=($v -shr 16)})}
    # All bodies retain r3 (the outer descriptor); no callee-saved register,
    # stack frame, mutable descriptor, or cross-invocation scratch is needed.
    $context=@(New-KokoroAlbertAttention3Steps -RegionBody -LabelPrefix 'connected_context' -DomainFailureLabel 'domain')
    if ($context[0].Op -cne 'load' -or $context[0].d -ne 4 -or $context[1].Op -cne 'load' -or $context[1].d -ne 5) { throw 'Context entry contract differs.' }
    $context[0].Offset=8; $context[1].Offset=24
    foreach ($s in $context) { $steps.Add($s) }
    # Preserve X for the residual. Context never overwrites the admitted input.
    $steps.Add(@{Op='load';d=4;s=3;Offset=8}); & $imm 0 27648
    $steps.Add(@{Op='add';d=4;s=4;t=0}); $steps.Add(@{Op='load';d=5;s=3;Offset=24}); & $imm 0 9216
    $steps.Add(@{Op='add';d=5;s=5;t=0}); $steps.Add(@{Op='imm';d=6;i=2304})
    $steps.Add(@{Op='label';Name='connected_hidden_copy'})
    $steps.Add(@{Op='load';d=0;s=4;Offset=0}); $steps.Add(@{Op='store';s=5;t=0;Offset=0})
    foreach ($r in 4,5) { $steps.Add(@{Op='addi';d=$r;s=$r;i=4}) }
    $steps.Add(@{Op='addi';d=6;s=6;i=-1}); $steps.Add(@{Op='gtu';d=0;s=6;t=15})
    $steps.Add(@{Op='jump-p';u=0;Label='connected_hidden_copy'})
    # Admit the computed context to the consumer's existing bounded domain.
    $steps.Add(@{Op='load';d=4;s=3;Offset=24}); $steps.Add(@{Op='imm';d=6;i=2304})
    & $imm 12 0x7fffffff; & $imm 13 ([BitConverter]::SingleToUInt32Bits([float]1024))
    $steps.Add(@{Op='label';Name='connected_context_scan'})
    $steps.Add(@{Op='load';d=0;s=4;Offset=0}); $steps.Add(@{Op='and';d=0;s=0;t=12})
    $steps.Add(@{Op='gtu';d=0;s=0;t=13}); $steps.Add(@{Op='jump-p';u=0;Label='domain'})
    $steps.Add(@{Op='addi';d=4;s=4;i=4}); $steps.Add(@{Op='addi';d=6;s=6;i=-1})
    $steps.Add(@{Op='gtu';d=0;s=6;t=15}); $steps.Add(@{Op='jump-p';u=0;Label='connected_context_scan'})
    $output=@(New-KokoroAlbertAttentionOutput3Steps -RegionBody -LabelPrefix 'connected_output' -DomainFailureLabel 'domain')
    $inputEdits=0; $outputEdits=0
    foreach ($originalStep in $output) {
        $s=$originalStep.Clone()
        if ($s.Op -eq 'load' -and $s.s -eq 3 -and $s.Offset -eq 8) {
            $s.Offset=24; $inputEdits++; $steps.Add($s)
        } elseif ($s.Op -eq 'load' -and $s.s -eq 3 -and $s.Offset -eq 24) {
            # r0 can retain the 9216-byte residual-half offset across this
            # load. r1 is dead at both adapted output-pointer loads.
            $steps.Add($s); & $imm 1 18432; $steps.Add(@{Op='add';d=$s.d;s=$s.d;t=1}); $outputEdits++
        } else { $steps.Add($s) }
    }
    if ($inputEdits -ne 2 -or $outputEdits -ne 2) { throw 'Output pointer contract differs.' }
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    $steps.ToArray()
}
function Get-KokoroAlbertConnectedAttention3Contract {
    [pscustomobject]@{
        Schema=1; Tokens=3; HiddenSize=768; Heads=12; HeadWidth=64
        MinimumBufferBytes=[int[]]@(12,36864,2368512,36864)
        InputLayout='qkv_then_original_hidden'; OutputLayout='context_hidden_projected_normalized'
        ArenaEdges=@(
            @{Name='context';Offset=0;Bytes=9216;LiveThrough='projection'},
            @{Name='hidden';Offset=9216;Bytes=9216;LiveThrough='residual_layernorm'},
            @{Name='projected';Offset=18432;Bytes=9216;LiveThrough='residual_layernorm'},
            @{Name='normalized';Offset=27648;Bytes=9216;LiveThrough='successful_completion'})
        WeightBytes=2368512; ArenaBytes=36864; DescriptorRegister=3
        ScalarClobbers=[int[]]@(0,1,2,4,5,6,7,8,9,10,11,12,13,14,15)
        MaximumAbsoluteInput=1024; MaximumCenteredScoreMagnitude=64
        Publication='private_transport_staging_copied_only_after_rc_zero'
        DispatchCount=1; FixedShapeDiagnostic=$true; ProductTransportVerified=$false
    }
}
