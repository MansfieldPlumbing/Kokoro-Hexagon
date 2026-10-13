# Adapter around the unchanged combined synthesis body. No model arithmetic,
# weights, parameter tables or runtime-frame implementation is transformed.
function Add-KokoroResidentPayloadEntry {
    param([hashtable[]]$Steps, [object]$Layout)
    $s = [Collections.Generic.List[hashtable]]::new()
    $s.Add(@{Op='hwticks';d=4}) # First instruction, before dispatch or setup.
    $s.Add(@{Op='lo';x=6;i=0x0100}); $s.Add(@{Op='hi';x=6;i=0x0302})
    $s.Add(@{Op='eq';d=0;s=2;t=6}); $s.Add(@{Op='jump-p';u=0;Label='resident_payload'})
    $s.Add(@{Op='imm';d=6;i=0}); $s.Add(@{Op='eq';d=0;s=6;t=6})
    $s.Add(@{Op='jump-p';u=0;Label='original_payload_entry'})
    $s.Add(@{Op='label';Name='resident_payload'})
    $s.Add(@{Op='imm';d=6;i=0}); $s.Add(@{Op='eq';d=0;s=3;t=6}); $s.Add(@{Op='jump-p';u=0;Label='resident_bad'})
    $s.Add(@{Op='load';d=6;s=3;Offset=4}); $s.Add(@{Op='imm';d=7;i=19})
    $s.Add(@{Op='gtu';d=0;s=6;t=7}); $s.Add(@{Op='jump-p';u=0;Label='resident_config'})
    $s.Add(@{Op='label';Name='resident_bad'}); $s.Add(@{Op='imm';d=0;i=14}); $s.Add(@{Op='return'})
    $s.Add(@{Op='label';Name='resident_config'})
    $s.Add(@{Op='load';d=6;s=3;Offset=0}); $s.Add(@{Op='imm';d=7;i=0})
    $s.Add(@{Op='eq';d=0;s=6;t=7}); $s.Add(@{Op='jump-p';u=0;Label='resident_bad'})
    $s.Add(@{Op='allocframe';Bytes=64})
    $s.Add(@{Op='store-d';s=29;t=4;Offset=40})
    # DSP remote_arg entries are eight bytes, unlike their ARM64 host form.
    foreach ($pair in @(@(0,0),@(4,4),@(8,8),@(12,12),@(32,16),@(36,20))) {
        $s.Add(@{Op='load';d=7;s=3;Offset=$pair[1]}); $s.Add(@{Op='store';s=29;t=7;Offset=$pair[0]})
    }
    foreach ($pair in @(@(16,4),@(20,8),@(24,12),@(28,16))) {
        $s.Add(@{Op='load';d=7;s=6;Offset=$pair[1]}); $s.Add(@{Op='store';s=29;t=7;Offset=$pair[0]})
    }
    $s.Add(@{Op='addi';d=3;s=29;i=0})
    $s.Add(@{Op='lo';x=2;i=0x0100}); $s.Add(@{Op='hi';x=2;i=0x0204})
    $callPc=@{Op='add-pc';d=14;i=0}; $callLo=@{Op='lo';x=15;i=0}; $callHi=@{Op='hi';x=15;i=0}
    $s.Add($callPc); $s.Add($callLo); $s.Add($callHi)
    $s.Add(@{Op='add';d=14;s=14;t=15}); $s.Add(@{Op='callr';s=14})
    # Original body has completed all release/unlock work. Leave r0 unchanged.
    $s.Add(@{Op='imm';d=5;i=0}); $s.Add(@{Op='eq';d=0;s=0;t=5})
    $s.Add(@{Op='jump-p';u=0;Label='resident_timing'})
    $s.Add(@{Op='dealloc-return'})
    $s.Add(@{Op='label';Name='resident_timing'})
    $s.Add(@{Op='load';d=4;s=29;Offset=32})
    $s.Add(@{Op='load';d=5;s=29;Offset=36})
    $s.Add(@{Op='lo';x=6;i=($Layout.OutputBytes -band 65535)}); $s.Add(@{Op='hi';x=6;i=($Layout.OutputBytes -shr 16)})
    $s.Add(@{Op='gtu';d=0;s=6;t=5}); $s.Add(@{Op='jump-p';u=0;Label='resident_return'})
    $s.Add(@{Op='load-d';d=6;s=29;Offset=40}); $s.Add(@{Op='store-d';s=4;t=6;Offset=64})
    $s.Add(@{Op='hwticks';d=6}); $s.Add(@{Op='store-d';s=4;t=6;Offset=72})
    $s.Add(@{Op='label';Name='resident_return'}); $s.Add(@{Op='dealloc-return'})
    $s.Add(@{Op='label';Name='original_payload_entry'})
    $pc=0L; $callOffset=0L; $isa=Get-InstructionSet
    foreach($step in $s) { if([object]::ReferenceEquals($step,$callPc)){$callOffset=$pc}; $pc+=& $isa.Length $step }
    $delta=$pc-$callOffset; $callLo.i=$delta -band 65535; $callHi.i=$delta -shr 16
    foreach($step in $Steps){$s.Add($step)}
    $s.ToArray()
}
