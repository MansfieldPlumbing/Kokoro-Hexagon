#requires -Version 7.4
# Stock ALBERT embeddings before their LayerNorm (transformers modeling_albert.py AlbertEmbeddings: word_embeddings(ids)
# + position_embeddings(0..T-1) + token_type_embeddings(0)), as a gather on 16-bit values (one LSB for the sum).
# Structure after MNN 43bc0686 htp-ops-lib/src/dsp/shared_gather_ops.cc (row gather by index); layout native croutons.
#   output = posType (copied), then per token t: output[t] += word[clamp(id_t, 0, Vocab - 1)], then biased (xor 0x8000).
# Word rows are stored gather-ready (Invoke-KokoroHexagon.ps1 ConvertTo-KokoroEmbeddingRows): per id, Blocks vectors of
# 128 B with channel 32 b + j in the even halfword of lane j (odd halfwords 0); an odd token shifts the row up 16 bits.
# posType: signed int16 croutons (Blocks * 32 wide, tiles of 32 tokens), position + token type 0, rows past T zero.
# Token ids are data: each is clamped to the vocabulary before it addresses a row.
#
# r0 = ids (int32[T]), r1 = word rows, r2 = posType, r3 = output (biased u16 croutons), r4 = T >= 1.
# Uses r5..r15, v0..v3, v31; r16..r27 are untouched.
function New-KokoroEmbed16Steps {
    param([ValidateSet(1,2,4,8,16)][int]$Blocks=4,[Parameter(Mandatory)][ValidateRange(1,65536)][int]$Vocab,[Parameter(Mandatory)][ValidateRange(1,512)][int]$Tokens,[string]$LabelPrefix='embed16')
    $tiles = [int][math]::Ceiling($Tokens / 32); $tileStride = 2048L * $Blocks; $rowBytes = 128 * $Blocks; $vectors = $tiles * $Blocks * 16
    $s = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$r,[long]$v) $u=[uint32]($v -band 0xffffffffL); $s.Add(@{Op='lo';x=$r;i=($u -band 65535)}); $s.Add(@{Op='hi';x=$r;i=($u -shr 16)}) }
    & $imm 13 0x80008000L; $s.Add(@{Op='vsplat';d=31;s=13})
    $s.Add(@{Op='imm';d=14;i=0}); $s.Add(@{Op='imm';d=12;i=16})
    # Copy posType into the output.
    $s.Add(@{Op='addi';d=5;s=2;i=0}); $s.Add(@{Op='addi';d=6;s=3;i=0}); & $imm 7 $vectors
    $s.Add(@{Op='label';Name="${LabelPrefix}_copy"})
    $s.Add(@{Op='vload';d=0;s=5;Offset=0}); $s.Add(@{Op='vstore';s=6;t=0;Offset=0})
    $s.Add(@{Op='addi';d=5;s=5;i=128}); $s.Add(@{Op='addi';d=6;s=6;i=128})
    $s.Add(@{Op='addi';d=7;s=7;i=-1}); $s.Add(@{Op='gtu';d=0;s=7;t=14}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_copy"})
    # Gather: r5 ids, r6 output row pair of token t (block 0), r7 tokens left, r8 row pairs left in the tile, r9 vocab - 1.
    $s.Add(@{Op='addi';d=5;s=0;i=0}); $s.Add(@{Op='addi';d=6;s=3;i=0}); $s.Add(@{Op='addi';d=7;s=4;i=0}); $s.Add(@{Op='imm';d=8;i=16})
    & $imm 9 ($Vocab - 1)
    $done = "${LabelPrefix}_done"
    $s.Add(@{Op='label';Name="${LabelPrefix}_pair"})
    foreach ($parity in 0, 1) {
        $s.Add(@{Op='load';d=11;s=5;Offset=0}); $s.Add(@{Op='addi';d=5;s=5;i=4})
        $s.Add(@{Op='max';d=11;s=11;t=14}); $s.Add(@{Op='min';d=11;s=11;t=9})              # clamp the id
        $s.Add(@{Op='asl-i';d=11;s=11;i=[int][math]::Log2($rowBytes)}); $s.Add(@{Op='add';d=13;s=1;t=11})   # row address
        $s.Add(@{Op='addi';d=15;s=6;i=0})
        for ($b = 0; $b -lt $Blocks; $b++) {
            $s.Add(@{Op='vload';d=1;s=13;Offset=(128*$b)})
            if ($parity) { $s.Add(@{Op='vasl-w';d=1;s=1;t=12}) }
            $s.Add(@{Op='vload';d=2;s=15;Offset=0}); $s.Add(@{Op='vadd-h-sat';d=2;s=2;t=1}); $s.Add(@{Op='vstore';s=15;t=2;Offset=0})
            if ($b -lt $Blocks - 1) { $s.Add(@{Op='addi';d=15;s=15;i=2048}) }
        }
        $s.Add(@{Op='addi';d=7;s=7;i=-1}); $s.Add(@{Op='eq';d=0;s=7;t=14}); $s.Add(@{Op='jump-p';u=0;Label=$done})
    }
    $s.Add(@{Op='addi';d=6;s=6;i=128})
    $s.Add(@{Op='addi';d=8;s=8;i=-1}); $s.Add(@{Op='gtu';d=0;s=8;t=14}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_pair"})
    & $imm 13 ($tileStride - 2048); $s.Add(@{Op='add';d=6;s=6;t=13}); $s.Add(@{Op='imm';d=8;i=16})
    $s.Add(@{Op='eq';d=0;s=14;t=14}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_pair"})
    $s.Add(@{Op='label';Name=$done})
    # Bias every vector.
    $s.Add(@{Op='addi';d=6;s=3;i=0}); & $imm 7 $vectors
    $s.Add(@{Op='label';Name="${LabelPrefix}_bias"})
    $s.Add(@{Op='vload';d=0;s=6;Offset=0}); $s.Add(@{Op='vxor';d=0;s=0;t=31}); $s.Add(@{Op='vstore';s=6;t=0;Offset=0}); $s.Add(@{Op='addi';d=6;s=6;i=128})
    $s.Add(@{Op='addi';d=7;s=7;i=-1}); $s.Add(@{Op='gtu';d=0;s=7;t=14}); $s.Add(@{Op='jump-p';u=0;Label="${LabelPrefix}_bias"})
    $s.Add(@{Op='return'})
    $s.ToArray()
}
