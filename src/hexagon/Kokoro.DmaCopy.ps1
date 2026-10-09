#requires -Version 7.4
# Hexagon V73 user DMA: two chained 1D descriptors copy one byte range.
# Descriptor layout and start/link sequence: llama.cpp
# ad2156533102a0d3c4e5fbdf422dc25fba4d03ba ggml/src/ggml-hexagon/htp/dma-queue.h
# (dma_descriptor_1d; dma_ring_push_single_1d; dmstart/dmlink each preceded by release:at).
# 1D descriptor, 16 bytes: next, {size:24, desc_size:2 = 0, dst_comp, src_comp,
# dst_bypass = 1, src_bypass = 1, order = 0, done}, src, dst.
# r0 = two 32-byte descriptor slots (64-byte aligned); r1 source; r2 destination;
# r3 byte count, 2..2*(2^24-1). Returns r0 = dmwait status. Clobbers r0..r7.
function New-KokoroDmaCopySteps {
    param([string]$LabelPrefix='dmacopy',[switch]$NoReturn)
    $s=[Collections.Generic.List[hashtable]]::new()
    $s.Add(@{Op='lsr-i';d=4;s=3;i=1})                 # first half
    $s.Add(@{Op='sub';d=5;s=3;t=4})                   # second half
    $s.Add(@{Op='lo';x=7;i=0});$s.Add(@{Op='hi';x=7;i=0x3000}) # src_bypass | dst_bypass
    $s.Add(@{Op='imm';d=6;i=0})
    $s.Add(@{Op='store';s=0;t=6;Offset=0})            # next = null
    $s.Add(@{Op='or';d=6;s=4;t=7});$s.Add(@{Op='store';s=0;t=6;Offset=4})
    $s.Add(@{Op='store';s=0;t=1;Offset=8});$s.Add(@{Op='store';s=0;t=2;Offset=12})
    $s.Add(@{Op='imm';d=6;i=0});$s.Add(@{Op='store';s=0;t=6;Offset=32})
    $s.Add(@{Op='or';d=6;s=5;t=7});$s.Add(@{Op='store';s=0;t=6;Offset=36})
    $s.Add(@{Op='add';d=6;s=1;t=4});$s.Add(@{Op='store';s=0;t=6;Offset=40})
    $s.Add(@{Op='add';d=6;s=2;t=4});$s.Add(@{Op='store';s=0;t=6;Offset=44})
    $s.Add(@{Op='release-at';s=0});$s.Add(@{Op='dmstart';s=0})
    $s.Add(@{Op='addi';d=6;s=0;i=32})
    $s.Add(@{Op='release-at';s=6});$s.Add(@{Op='dmlink';s=0;t=6})
    $s.Add(@{Op='dmwait';d=0})
    if(-not $NoReturn){$s.Add(@{Op='return'})}
    $s.ToArray()
}
