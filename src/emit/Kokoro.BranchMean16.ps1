#requires -Version 7.4
# Stock generator mean of three parallel residual branches over 16-bit activations, istftnet.py:315-320,
# Kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec. Inputs and output are biased u16 (x + 32768) in native
# croutons, all three branches in the same units, so out = sat(a/3 + b/3 + c/3) with each third a Q15
# rounding multiply by 10923 (vmpy :<<1:rnd:sat), within two LSB of the exact mean.
# r0, r1, r2 input tiles; r3 output tiles (may equal an input); r4 tiles >= 1. r16..r27 are untouched.
function New-KokoroBranchMean16Steps {
    param([ValidateSet(128,256)][int]$Channels=128,[string]$LabelPrefix='branchmean16',[switch]$NoReturn)
    $s=[Collections.Generic.List[hashtable]]::new()
    $s.Add(@{Op='lo';x=6;i=0x8000}); $s.Add(@{Op='hi';x=6;i=0x8000}); $s.Add(@{Op='vsplat';d=3;s=6})
    $s.Add(@{Op='lo';x=6;i=10923}); $s.Add(@{Op='hi';x=6;i=10923}); $s.Add(@{Op='vsplat';d=4;s=6})
    # r9 = vectors to process: tiles * Channels/2 (64 or 128 vectors of 128 bytes per tile).
    $s.Add(@{Op='asl-i';d=9;s=4;i=$(if($Channels -eq 128){6}else{7})}); $s.Add(@{Op='imm';d=7;i=0})
    $loop="${LabelPrefix}_vector"
    $s.Add(@{Op='label';Name=$loop})
    $s.Add(@{Op='vload';d=0;s=0;Offset=0}); $s.Add(@{Op='vload';d=1;s=1;Offset=0}); $s.Add(@{Op='vload';d=2;s=2;Offset=0})
    foreach($v in 0,1,2){ $s.Add(@{Op='vxor';d=$v;s=$v;t=3}); $s.Add(@{Op='vmpy-h-rnd-sat';d=$v;s=$v;t=4}) }
    $s.Add(@{Op='vadd-h-sat';d=0;s=0;t=1}); $s.Add(@{Op='vadd-h-sat';d=0;s=0;t=2}); $s.Add(@{Op='vxor';d=0;s=0;t=3})
    $s.Add(@{Op='vstore';s=3;t=0;Offset=0})
    foreach($r in 0,1,2,3){ $s.Add(@{Op='addi';d=$r;s=$r;i=128}) }
    $s.Add(@{Op='addi';d=9;s=9;i=-1}); $s.Add(@{Op='gtu';d=0;s=9;t=7}); $s.Add(@{Op='jump-p';u=0;Label=$loop})
    if(-not $NoReturn){ $s.Add(@{Op='return'}) }
    $s.ToArray()
}
