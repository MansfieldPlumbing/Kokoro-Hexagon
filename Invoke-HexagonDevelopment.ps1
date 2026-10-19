#requires -Version 7.4
<#
.SYNOPSIS
Hexagon V73 development: instruction records, encoding, assembly text and layout for emitted DSP code.

.DESCRIPTION
One owning file for Hexagon work. $script:Instructions holds one record per V73 instruction or fixed instruction
group: its encoding pattern, immediate rule, register-pair rules, byte length, assembly template and manual source.
The encoder (HexagonEncoder, lowered to IL by PSLowering) reads those records; nothing below repeats them per op.

Dot-source this file to load the records, classes and functions. Run it with -Command Instructions to list them.

Encoding sources: Hexagon V73 PRM 80-N2040-53 Rev. AB (PDF SHA-256
44EBAFD1119F725BD3C6FFB87499232520DF9A0A6E3E3DC6EA329B15DAED11A8) and V73 HVX PRM 80-N2040-54 Rev. AB, with bit
patterns checked against Hexagon SDK 6.4.0.2 hexagon-llvm-mc where noted. Each instruction ends its own packet; no
duplexes, extenders or scheduling except the fixed groups listed.
#>
[CmdletBinding()]
param([ValidateSet('Instructions')][string]$Command)

# Pattern letters: 0/1 fixed bits, '-' fixed zero, P parse bits, other letters operand fields (d s t u v x e r i).
# Rule names how a step's values become fields; Pairs lists fields that must be even register pairs 0..30.
# Asm tokens: {d} {s} {t} {u} {v} {x} {e} {r} {i} {Offset} {Bytes} {Label} and {d1} {s1} {t1} for the odd register of
# a pair; {VectorOffset}/{VectorPost} for vector address offsets and {AlignRegister} for valign.
$script:Instructions = @(
    @{ Op='imm';            Pattern='01111000ii-iiiiiPPiiiiiiiiiddddd'; Rule='Signed16'; Asm='r{d} = #{i}'; Source='PRM p.145' }
    @{ Op='lo';             Pattern='01110001ii1xxxxxPPiiiiiiiiiiiiii'; Rule='Raw'; Asm='r{x}.l = #{i}'; Source='PRM p.145' }
    @{ Op='hi';             Pattern='01110010ii1xxxxxPPiiiiiiiiiiiiii'; Rule='Raw'; Asm='r{x}.h = #{i}'; Source='PRM p.145' }
    @{ Op='eq';             Pattern='11110010-00sssssPP-ttttt---000dd'; Asm='p{d} = cmp.eq(r{s},r{t})'; Source='PRM p.157' }
    @{ Op='gtu';            Pattern='11110010-11sssssPP-ttttt---000dd'; Asm='p{d} = cmp.gtu(r{s},r{t})'; Source='PRM p.157' }
    @{ Op='jump-p';         Pattern='01011100ii0iiiiiPPi00-uuiiiiiii-'; Rule='Branch'; Asm='if (p{u}) jump:nt {Label}'; Source='PRM p.163' }
    @{ Op='loop0-r';        Pattern='01100000000sssssPP-iiiii---ii---'; Rule='LoopStart'; Asm='loop0({Label},r{s})'; Source='PRM pp.146,195' }
    @{ Op='loop1-r';        Pattern='01100000001sssssPP-iiiii---ii---'; Rule='LoopStart'; Asm='loop1({Label},r{s})'; Source='PRM pp.146,195' }
    @{ Op='load';           Pattern='10010ii1100sssssPPiiiiiiiiiddddd'; Rule='Offset'; Scale=4; Min=-4096; Max=4092; Message='Word offset out of range'; Asm='r{d} = memw(r{s}+#{Offset})'; Source='PRM p.206' }
    @{ Op='store';          Pattern='10100ii1100sssssPPitttttiiiiiiii'; Rule='Offset'; Scale=4; Min=-4096; Max=4092; Message='Word offset out of range'; Asm='memw(r{s}+#{Offset}) = r{t}'; Source='PRM p.214' }
    @{ Op='add';            Pattern='11110011000sssssPP-ttttt---ddddd'; Asm='r{d} = add(r{s},r{t})'; Source='PRM p.189' }
    @{ Op='addi';           Pattern='1011iiiiiiisssssPPiiiiiiiiiddddd'; Rule='Signed16'; Asm='r{d} = add(r{s},#{i})'; Source='PRM p.189' }
    @{ Op='sfadd';          Pattern='11101011000sssssPP0ttttt000ddddd'; Asm='r{d} = sfadd(r{s},r{t})'; Source='PRM p.242' }
    @{ Op='sfsub';          Pattern='11101011000sssssPP0ttttt001ddddd'; Asm='r{d} = sfsub(r{s},r{t})'; Source='PRM p.242' }
    @{ Op='sfmpy';          Pattern='11101011010sssssPP0ttttt000ddddd'; Asm='r{d} = sfmpy(r{s},r{t})'; Source='PRM p.242' }
    @{ Op='sfmax';          Pattern='11101011100sssssPP0ttttt000ddddd'; Asm='r{d} = sfmax(r{s},r{t})'; Source='PRM p.474' }
    @{ Op='sfinvsqrta';     Pattern='10001011111sssssPP------0eeddddd'; Asm='r{d},p{e} = sfinvsqrta(r{s})'; Source='PRM p.470' }
    @{ Op='and';            Pattern='11110001000sssssPP0ttttt000ddddd'; Asm='r{d} = and(r{s},r{t})'; Source='PRM p.304' }
    @{ Op='xor';            Pattern='11110001011sssssPP0ttttt000ddddd'; Asm='r{d} = xor(r{s},r{t})'; Source='PRM p.304' }
    @{ Op='or';             Pattern='11110001001sssssPP0ttttt000ddddd'; Asm='r{d} = or(r{s},r{t})'; Source='SDK 6.4.0.2 hexagon-llvm-mc: r24 = or(r24,r0) = 0xF138C018' }
    @{ Op='conv-sf2w-chop'; Pattern='10001011100sssssPP000000001ddddd'; Asm='r{d} = convert_sf2w(r{s}):chop'; Source='PRM p.242' }
    @{ Op='conv-w2sf';      Pattern='10001011010sssssPP000000000ddddd'; Asm='r{d} = convert_w2sf(r{s})'; Source='PRM p.242' }
    @{ Op='vload';          Pattern='00101000000sssssPPiiiiii---ddddd'; Rule='VectorOffset'; Asm='v{d} = vmem(r{s}+#{VectorOffset})'; Source='HVX PRM' }
    @{ Op='vload-post';     Pattern='00101001000sssssPPiiiiii---ddddd'; Rule='VectorPost'; Asm='v{d} = vmem(r{s}++#{VectorPost})'; Source='HVX PRM' }
    @{ Op='vstore';         Pattern='00101000001sssssPPiiiiii---ttttt'; Rule='VectorOffset'; Asm='vmem(r{s}+#{VectorOffset}) = v{t}'; Source='HVX PRM' }
    @{ Op='vstore-post';    Pattern='00101001001sssssPPiiiiii---ttttt'; Rule='VectorPost'; Asm='vmem(r{s}++#{VectorPost}) = v{t}'; Source='HVX PRM' }
    @{ Op='vadd-sf';        Pattern='00011111100tttttPP1sssss110ddddd'; Asm='v{d}.sf = vadd(v{s}.sf,v{t}.sf)'; Source='HVX PRM' }
    @{ Op='vsub-sf';        Pattern='00011111100tttttPP1sssss111ddddd'; Asm='v{d}.sf = vsub(v{s}.sf,v{t}.sf)'; Source='HVX PRM' }
    @{ Op='vmpy-sf';        Pattern='00011111100tttttPP1sssss001ddddd'; Asm='v{d}.sf = vmpy(v{s}.sf,v{t}.sf)'; Source='HVX PRM' }
    @{ Op='vmpy-hf-qf32';   Pattern='00011111111tttttPP1sssss111ddddd'; Rule='Pairs'; Pairs='d'; Message='FP32 conversion destination pair must be even and 0..30'; Asm='v{d1}:{d}.qf32 = vmpy(v{s}.hf,v{t}.hf)'; Source='SDK 19.0.04 +hvx-ieee-fp' }
    @{ Op='vconv-qf32-hf';  Pattern='00011110--0--100PP1sssss110ddddd'; Rule='Pairs'; Pairs='s'; Message='QFloat source pair must be even and 0..30'; Asm='v{d}.hf = v{s1}:{s}.qf32'; Source='SDK 19.0.04 +hvx-ieee-fp' }
    @{ Op='vshuffe-h';      Pattern='00011111010tttttPP0sssss011ddddd'; Asm='v{d}.h = vshuffe(v{s}.h,v{t}.h)'; Source='SDK 19.0.04' }
    @{ Op='vmpy-sf-qf32';   Pattern='00011111111tttttPP1sssss001ddddd'; Asm='v{d}.qf32 = vmpy(v{s}.sf,v{t}.sf)'; Source='HVX PRM pp.154,250,262' }
    @{ Op='vadd-sf-qf32';   Pattern='00011111101tttttPP1sssss001ddddd'; Asm='v{d}.qf32 = vadd(v{s}.sf,v{t}.sf)'; Source='HVX PRM pp.154,250,262' }
    @{ Op='vconv-qf32-sf';  Pattern='00011110--0--100PP1sssss000ddddd'; Asm='v{d}.sf = v{s}.qf32'; Source='HVX PRM pp.154,250,262' }
    @{ Op='vsplat';         Pattern='00011001101sssssPP000000001ddddd'; Asm='v{d} = vsplat(r{s})'; Source='HVX PRM' }
    @{ Op='vand';           Pattern='00011100001tttttPP0sssss101ddddd'; Asm='v{d} = vand(v{s},v{t})'; Source='HVX PRM' }
    @{ Op='vxor';           Pattern='00011100001tttttPP0sssss111ddddd'; Asm='v{d} = vxor(v{s},v{t})'; Source='HVX PRM' }
    @{ Op='vlsr-uw';        Pattern='00011001100tttttPP0sssss001ddddd'; Asm='v{d}.uw = vlsr(v{s}.uw,r{t})'; Source='SDK 6.4.0.2: v0.uw=vlsr(v1.uw,r2) -> 0x1982C120' }
    @{ Op='vadd-w';         Pattern='00011100010tttttPP0sssss000ddddd'; Asm='v{d}.w = vadd(v{s}.w,v{t}.w)'; Source='SDK 6.4.0.2: v0.w=vadd(v1.w,v2.w) -> 0x1C42C100' }
    @{ Op='vmpyie-w-uh';    Pattern='00011111110tttttPP0sssss000ddddd'; Asm='v{d}.w = vmpyie(v{s}.w,v{t}.uh)'; Source='SDK 6.4.0.2: v0.w=vmpyie(v1.w,v2.uh) -> 0x1FC2C100' }
    @{ Op='mpyu-d';         Pattern='11100101010sssssPP0ttttt000ddddd'; Rule='Pairs'; Pairs='d'; Message='Integer register pair must be even and 0..30'; Asm='r{d1}:{d} = mpyu(r{s},r{t})'; Source='SDK 6.4.0.2' }
    @{ Op='mpy-d';          Pattern='11100101000sssssPP0ttttt000ddddd'; Rule='Pairs'; Pairs='d'; Message='Integer register pair must be even and 0..30'; Asm='r{d1}:{d} = mpy(r{s},r{t})'; Source='SDK 6.4.0.2' }
    @{ Op='add-d';          Pattern='11010011000sssssPP0ttttt111ddddd'; Rule='Pairs'; Pairs='dst'; Message='Integer register pair must be even and 0..30'; Asm='r{d1}:{d} = add(r{s1}:{s},r{t1}:{t})'; Source='SDK 6.4.0.2' }
    @{ Op='sub-d';          Pattern='11010011001tttttPP0sssss111ddddd'; Rule='Pairs'; Pairs='dst'; Message='Integer register pair must be even and 0..30'; Asm='r{d1}:{d} = sub(r{s1}:{s},r{t1}:{t})'; Source='SDK 6.4.0.2' }
    @{ Op='gtu-d';          Pattern='11010010100sssssPP0ttttt100000dd'; Rule='Pairs'; Pairs='st'; Message='Integer register pair must be even and 0..30'; Asm='p{d} = cmp.gtu(r{s1}:{s},r{t1}:{t})'; Source='SDK 6.4.0.2' }
    @{ Op='gt';             Pattern='11110010010sssssPP0ttttt000000dd'; Asm='p{d} = cmp.gt(r{s},r{t})'; Source='SDK 6.4.0.2' }
    @{ Op='sub';            Pattern='11110011001tttttPP0sssss000ddddd'; Asm='r{d} = sub(r{s},r{t})'; Source='SDK 6.4.0.2' }
    @{ Op='lsr-i';          Pattern='10001100000sssssPP0iiiii001ddddd'; Rule='Unsigned'; Min=0; Max=31; Message='Word shift out of range'; Asm='r{d} = lsr(r{s},#{i})'; Source='SDK 6.4.0.2' }
    @{ Op='asl-i';          Pattern='10001100000sssssPP0iiiii010ddddd'; Rule='Unsigned'; Min=0; Max=31; Message='Word shift out of range'; Asm='r{d} = asl(r{s},#{i})'; Source='SDK 6.4.0.2' }
    @{ Op='asr-d-i';        Pattern='10000000000sssssPPiiiiii000ddddd'; Rule='PairShift'; Pairs='ds'; Min=0; Max=63; Message='Integer register pair must be even and 0..30'; Asm='r{d1}:{d} = asr(r{s1}:{s},#{i})'; Source='SDK 6.4.0.2' }
    @{ Op='vasr-w';         Pattern='00011001011tttttPP0sssss101ddddd'; Asm='v{d}.w = vasr(v{s}.w,r{t})'; Source='SDK 6.4.0.2' }
    @{ Op='vasl-w';         Pattern='00011001011tttttPP0sssss111ddddd'; Asm='v{d}.w = vasl(v{s}.w,r{t})'; Source='SDK 6.4.0.2' }
    @{ Op='vmax-w';         Pattern='00011111001tttttPP0sssss000ddddd'; Asm='v{d}.w = vmax(v{s}.w,v{t}.w)'; Source='SDK 6.4.0.2' }
    @{ Op='vasr-wv';        Pattern='00011111101tttttPP0sssss000ddddd'; Asm='v{d}.w = vasr(v{s}.w,v{t}.w)'; Source='SDK 6.4.0.2; HVX PRM: amount > 0 shifts right' }
    @{ Op='vlsr-wv';        Pattern='00011111101tttttPP0sssss001ddddd'; Asm='v{d}.w = vlsr(v{s}.w,v{t}.w)'; Source='SDK 6.4.0.2' }
    @{ Op='vasr-hv';        Pattern='00011111101tttttPP0sssss011ddddd'; Asm='v{d}.h = vasr(v{s}.h,v{t}.h)'; Source='SDK 6.4.0.2' }
    @{ Op='vasl-wv';        Pattern='00011111101tttttPP0sssss100ddddd'; Asm='v{d}.w = vasl(v{s}.w,v{t}.w)'; Source='SDK 6.4.0.2' }
    @{ Op='vmin-h';         Pattern='00011111000tttttPP0sssss011ddddd'; Asm='v{d}.h = vmin(v{s}.h,v{t}.h)'; Source='SDK 6.4.0.2' }
    @{ Op='vmax-h';         Pattern='00011111000tttttPP0sssss111ddddd'; Asm='v{d}.h = vmax(v{s}.h,v{t}.h)'; Source='SDK 6.4.0.2' }
    @{ Op='vmin-w';         Pattern='00011111000tttttPP0sssss100ddddd'; Asm='v{d}.w = vmin(v{s}.w,v{t}.w)'; Source='SDK 6.4.0.2' }
    @{ Op='vor';            Pattern='00011100001tttttPP0sssss110ddddd'; Asm='v{d} = vor(v{s},v{t})'; Source='SDK 6.4.0.2' }
    @{ Op='vsub-w';         Pattern='00011100010tttttPP0sssss111ddddd'; Asm='v{d}.w = vsub(v{s}.w,v{t}.w)'; Source='HVX PRM pp.227-230' }
    @{ Op='vmpy-h-rnd-sat'; Pattern='00011100001tttttPP0sssss001ddddd'; Asm='v{d}.h = vmpy(v{s}.h,v{t}.h):<<1:rnd:sat'; Source='SDK 6.4.0.2 +hvxv73 128B' }
    @{ Op='vadd-h';         Pattern='00011111101tttttPP0sssss111ddddd'; Asm='v{d}.h = vadd(v{s}.h,v{t}.h)'; Source='SDK 6.4.0.2 +hvxv73 128B' }
    @{ Op='vadd-h-sat';     Pattern='00011100010tttttPP0sssss011ddddd'; Asm='v{d}.h = vadd(v{s}.h,v{t}.h):sat'; Source='SDK 6.4.0.2 +hvxv73 128B' }
    @{ Op='vsub-h';         Pattern='00011100010tttttPP0sssss110ddddd'; Asm='v{d}.h = vsub(v{s}.h,v{t}.h)'; Source='SDK 6.4.0.2 +hvxv73 128B' }
    @{ Op='vabs-h-sat';     Pattern='0001111000000000PP0sssss001ddddd'; Asm='v{d}.h = vabs(v{s}.h):sat'; Source='SDK 6.4.0.2 +hvxv73 128B' }
    @{ Op='vasr-h';         Pattern='00011001011tttttPP0sssss110ddddd'; Asm='v{d}.h = vasr(v{s}.h,r{t})'; Source='SDK 6.4.0.2 +hvxv73 128B' }
    @{ Op='vasl-h';         Pattern='00011001100tttttPP0sssss000ddddd'; Asm='v{d}.h = vasl(v{s}.h,r{t})'; Source='SDK 6.4.0.2 +hvxv73 128B' }
    @{ Op='vsplat-h';       Pattern='00011001110sssssPP000000001ddddd'; Asm='v{d}.h = vsplat(r{s})'; Source='SDK 6.4.0.2 +hvxv73 128B' }
    @{ Op='vmpye-w-uh';     Pattern='00011111111tttttPP0sssss101ddddd'; Asm='v{d}.w = vmpye(v{s}.w,v{t}.uh)'; Source='SDK 6.4.0.2; Q31 multiply pair, first half' }
    @{ Op='vmpyo-acc-w-h-rnd-sat-shift'; Pattern='00011100001tttttPP1sssss111ddddd'; Asm='v{d}.w += vmpyo(v{s}.w,v{t}.h):<<1:rnd:sat:shift'; Source='SDK 6.4.0.2; Q31 multiply pair, accumulating half (d read and written)' }
    @{ Op='vmpy-acc-ww-h-h'; Pattern='00011100000tttttPP1sssss111ddddd'; AsmEvenD=$true; Asm='v{d1}:{d}.w += vmpy(v{s}.h,v{t}.h)'; Source='SDK 6.4.0.2; widening multiply-accumulate into a pair (d even)' }
    @{ Op='vmpy-acc-ww-h-r'; Pattern='00011001101tttttPP1sssss110ddddd'; AsmEvenD=$true; Asm='v{d1}:{d}.w += vmpy(v{s}.h,r{t}.h)'; Source='SDK 6.4.0.2; widening multiply-accumulate into a pair (d even)' }
    @{ Op='vlut16';         Pattern='00011011vvvvvxxxPP1sssss110ddddd'; Rule='Lookup'; Asm='v{d1}:{d}.h = vlut16(v{s}.b,v{v}.h,r{x})'; Source='HVX PRM pp.227-230' }
    @{ Op='vlut16-or';      Pattern='00011011vvvvvxxxPP1sssss111ddddd'; Rule='Lookup'; Asm='v{d1}:{d}.h |= vlut16(v{s}.b,v{v}.h,r{x})'; Source='HVX PRM pp.227-230' }
    @{ Op='valign';         Pattern='00011011tttttxxxPP0sssss000ddddd'; Rule='AlignRegister'; Asm='v{d} = valign(v{s},v{t},r{AlignRegister})'; Source='HVX PRM' }
    @{ Op='valign-imm';     Pattern='00011110001tttttPP1sssssiiiddddd'; Rule='Unsigned'; Min=0; Max=7; Message='Valign immediate out of range (0..7)'; Asm='v{d} = valign(v{s},v{t},#{i})'; Source='HVX PRM' }
    @{ Op='vshuff';         Pattern='00011011tttttrrrPP1sssss011ddddd'; Rule='Shuffle'; Asm='v{d1}:{d} = vshuff(v{s},v{t},r{r})'; Source='HVX PRM' }
    @{ Op='trap0';          Pattern='0101010000000000PP0iiiii000iii00'; Rule='Unsigned'; Min=0; Max=255; Message='Trap0 immediate out of range (0..255)'; Asm='trap0(#{i})'; Source='PRM' }
    @{ Op='pcycle';         Pattern='0110111100011110PP000000000ddddd'; Rule='CounterPair'; Asm='r{d1}:{d} = pcycle'; Source='PRM' }
    @{ Op='hwticks';        Pattern='0110100000011110PP000000000ddddd'; Rule='CounterPair'; Asm='r{d1}:{d} = c31:30'; Source='PRM' }
    @{ Op='upcycle';        Pattern='0110100000001110PP000000000ddddd'; Rule='CounterPair'; Asm='r{d1}:{d} = upcycle'; Source='SDK 6.4.0.2: r7:6 = upcycle -> 0x680EC006; PRM 2.2.9: reads zero unless the RTOS enables user access' }
    @{ Op='store-d';        Pattern='10100ii1110sssssPPitttttiiiiiiii'; Rule='Offset'; Scale=8; Min=-8192; Max=8184; Message='Double word offset out of range or unaligned'; Pairs='t'; PairMessage='Store-d source register pair must be even and 0..30'; Asm='memd(r{s}+#{Offset}) = r{t1}:{t}'; Source='SDK 6.4.0.2' }
    @{ Op='mxclracc';       Pattern='1010011011100000PP00000000010001'; Asm='mxclracc'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='mxclracc.hf';    Pattern='1010011011100000PP00000000010011'; Asm='mxclracc.hf'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='cvt-hf';         Pattern='10100110111sssssPP01101000010000'; Rule='Registers'; Fields='s'; Message='Cvt source register out of range (0..31)'; Asm='cvt.hf = acc(r{s})'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='cvt-ub';         Pattern='10100110111sssssPP01011100010000'; Rule='Registers'; Fields='s'; Message='Cvt source register out of range (0..31)'; Asm='cvt.ub = acc(r{s})'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='cvt-ub-sc0';     Pattern='10100110111sssssPP01110000010000'; Rule='Registers'; Fields='s'; Message='Cvt source register out of range (0..31)'; Asm='cvt.ub = acc(r{s}):sc0'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='cvt-ub-sc1';     Pattern='10100110111sssssPP01110100010000'; Rule='Registers'; Fields='s'; Message='Cvt source register out of range (0..31)'; Asm='cvt.ub = acc(r{s}):sc1'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='mxmem-cvt';      Pattern='10100110111sssssPP0ttttt00011000'; Rule='Registers'; Fields='st'; Message='Mxmem-cvt base register out of range (0..31)'; Message2='Mxmem-cvt stride register out of range (0..31)'; Asm='mxmem(r{s},r{t}) = cvt'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='mxmem-after-hf'; Pattern='10100110111sssssPP1ttttt00000100'; Rule='Registers'; Fields='st'; Message='Mxmem-cvt base register out of range (0..31)'; Message2='Mxmem-cvt stride register out of range (0..31)'; Asm='mxmem(r{s},r{t}):after.hf = acc'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='mxmem-after-retain-cm-ub'; Pattern='10100110111sssssPP0ttttt00001111'; Rule='Registers'; Fields='st'; Message='Mxmem-cvt base register out of range (0..31)'; Message2='Mxmem-cvt stride register out of range (0..31)'; Asm='mxmem(r{s},r{t}):after:retain:cm.ub = acc'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='bias-mxmem';     Pattern='10010010000sssssPP00001111111111'; Rule='Registers'; Fields='s'; Message='Bias address register out of range (0..31)'; Asm='bias = mxmem(r{s})'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='bias-mxmem2';    Pattern='10010010000sssssPP00001111111110'; Rule='Registers'; Fields='s'; Message='Bias address register out of range (0..31)'; Asm='bias = mxmem2(r{s})'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='act-hf';         Pattern='10010010000sssssPP0ttttt11100100'; Source='SDK 6.4.0.2 +hmxv73; slot 1 of an HMX packet' }
    @{ Op='act-ub';         Pattern='10010010000sssssPP0ttttt11101100'; Source='SDK 6.4.0.2 +hmxv73; slot 1 of an HMX packet' }
    @{ Op='act-ub-cm';      Pattern='10010010000sssssPP0ttttt11101101'; Source='SDK 6.4.0.2 +hmxv73; slot 1 of an HMX packet' }
    @{ Op='wt-hf';          Pattern='10010010000uuuuuPP1vvvvv11101111'; Source='SDK 6.4.0.2 +hmxv73; slot 0 of an HMX packet' }
    @{ Op='wt-b';           Pattern='10010010000uuuuuPP1vvvvv11100000'; Source='SDK 6.4.0.2 +hmxv73; slot 0 of an HMX packet' }
    @{ Op='wt-n';           Pattern='10010010000uuuuuPP1vvvvv11100001'; Source='SDK 6.4.0.2 +hmxv73; slot 0 of an HMX packet' }
    @{ Op='act-ub-single';  Pattern='10010010000sssssPP0ttttt11110000'; Source='SDK 6.4.0.2 +hmxv73 conv forms' }
    @{ Op='act-hf-single';  Pattern='10010010000sssssPP0ttttt11111000'; Source='SDK 6.4.0.2 +hmxv73 conv forms' }
    @{ Op='wt-b-deep';      Pattern='10010010000uuuuuPP1vvvvv11101000'; Source='SDK 6.4.0.2 +hmxv73 conv forms' }
    @{ Op='mxmem-after-sat-ub'; Pattern='10100110111sssssPP0ttttt00000100'; Rule='Registers'; Fields='st'; Message='Mxmem-cvt base register out of range (0..31)'; Message2='Mxmem-cvt stride register out of range (0..31)'; Asm='mxmem(r{s},r{t}):after:sat.ub = acc'; Source='SDK 6.4.0.2 +hmxv73' }
    @{ Op='mxmem-after-retain-sat-ub'; Pattern='10100110111sssssPP0ttttt00001100'; Rule='Registers'; Fields='st'; Message='Mxmem-cvt base register out of range (0..31)'; Message2='Mxmem-cvt stride register out of range (0..31)'; Asm='mxmem(r{s},r{t}):after:retain:sat.ub = acc'; Source='SDK 6.4.0.2 +hmxv73; :retain keeps the accumulator' }
    @{ Op='mxmem-after-ub'; Pattern='10100110111sssssPP0ttttt00000110'; Rule='Registers'; Fields='st'; Message='Mxmem-cvt base register out of range (0..31)'; Message2='Mxmem-cvt stride register out of range (0..31)'; Asm='mxmem(r{s},r{t}):after.ub = acc'; Source='SDK 6.4.0.2 +hmxv73; .ub without :sat wraps modulo 256' }
    @{ Op='immext';         Pattern='0000iiiiiiiiiiiiPPiiiiiiiiiiiiii'; Source='SDK 6.4.0.2; first word of got-call' }
    @{ Op='add-pc';         Pattern='0110101001001001PP0iiiiii00ddddd'; Rule='Unsigned'; Min=0; Max=63; Message='add(pc) immediate out of range (0..63)'; Asm='r{d} = add(pc,#{i})'; Source='SDK 6.4.0.2' }
    @{ Op='callr';          Pattern='01010000101sssssPP00000000000000'; Asm='callr r{s}'; Source='SDK 6.4.0.2' }
    @{ Op='syncht';         Pattern='1010100001000000PP00000000000000'; Asm='syncht'; Source='SDK 6.4.0.2' }
    @{ Op='allocframe';     Pattern='1010000010011101PP000iiiiiiiiiii'; Rule='Frame'; Asm='allocframe(#{Bytes})'; Source='SDK 6.4.0.2' }
    @{ Op='dealloc-return'; Pattern='1001011000011110PP00000000011110'; Asm='dealloc_return'; Source='SDK 6.4.0.2' }
    @{ Op='load-d';         Pattern='10010ii1110sssssPPiiiiiiiiiddddd'; Rule='Offset'; Scale=8; Min=-8192; Max=8184; Message='Double word offset out of range or unaligned'; Pairs='d'; PairMessage='Load-d destination register pair must be even and 0..30'; Asm='r{d1}:{d} = memd(r{s}+#{Offset})'; Source='SDK 6.4.0.2' }
    @{ Op='return';         Pattern='01010010100sssssPP--------------'; Rule='Return'; Asm='jumpr r31'; Source='SDK 6.4.0.2' }
    @{ Op='dmstart';        Pattern='10100110000sssssPP00000000100000'; Asm='dmstart(r{s})'; Source='SDK 6.4.0.2 user DMA' }
    @{ Op='dmlink';         Pattern='10100110000sssssPP0ttttt01000000'; Asm='dmlink(r{s},r{t})'; Source='SDK 6.4.0.2 user DMA' }
    @{ Op='dmwait';         Pattern='1010100000000000PP000000001ddddd'; Asm='r{d} = dmwait'; Source='SDK 6.4.0.2 user DMA' }
    @{ Op='dmpoll';         Pattern='1010100000000000PP000000010ddddd'; Asm='r{d} = dmpoll'; Source='SDK 6.4.0.2 user DMA' }
    @{ Op='release-at';     Pattern='10100000111sssssPP00000000001100'; Asm='release(r{s}):at'; Source='SDK 6.4.0.2' }
    @{ Op='load-ub';        Pattern='10010ii1001sssssPPiiiiiiiiiddddd'; Rule='Offset'; Scale=1; Min=-1024; Max=1023; Message='Byte offset out of range'; Asm='r{d} = memub(r{s}+#{Offset})'; Source='SDK 6.4.0.2' }
    @{ Op='store-h';        Pattern='10100ii1010sssssPPitttttiiiiiiii'; Rule='Offset'; Scale=2; Min=-2048; Max=2046; Message='Halfword offset out of range or unaligned'; Asm='memh(r{s}+#{Offset}) = r{t}'; Source='SDK 6.4.0.2' }
    @{ Op='max';            Pattern='11010101110sssssPP0ttttt000ddddd'; Asm='r{d} = max(r{s},r{t})'; Source='SDK 6.4.0.2' }
    @{ Op='min';            Pattern='11010101101tttttPP0sssss000ddddd'; Asm='r{d} = min(r{s},r{t})'; Source='SDK 6.4.0.2' }
    @{ Op='asr-i';          Pattern='10001100000sssssPP0iiiii000ddddd'; Rule='Unsigned'; Min=0; Max=31; Message='Word shift out of range'; Asm='r{d} = asr(r{s},#{i})'; Source='SDK 6.4.0.2' }
    # Fixed groups of several words, encoded as a unit.
    @{ Op='label';          Rule='Label'; Bytes=0 }
    @{ Op='endloop0';       Rule='EndLoop'; Bytes=8; Asm='{ r14 = add(r14,#0); r15 = add(r15,#0) }:endloop0'; Source='Loop-end packet of preserving adds' }
    @{ Op='endloop1';       Rule='EndLoop'; Bytes=12; Asm='{ r13 = add(r13,#0); r14 = add(r14,#0); r15 = add(r15,#0) }:endloop1'; Source='Loop-end packet of preserving adds' }
    @{ Op='got-call';       Rule='GotCall'; Bytes=16; Source='{ rd = add(pc,##slot-pc) }; rd = memw(rd); callr rd. Clobbers rd and the caller-saved registers.' }
    @{ Op='hmx-pair';       Rule='HmxPair'; Bytes=8; Source='One packet: activation load (slot 1) then weight load (slot 0), named by form' }
    @{ Op='mxmpy-fp16';     Rule='HmxMultiply'; Bytes=8; Act='act-hf'; Wt='wt-hf' }
    @{ Op='mxmpy-w8a8';     Rule='HmxMultiply'; Bytes=8; Act='act-ub'; Wt='wt-b' }
    @{ Op='mxmpy-w4a8';     Rule='HmxMultiply'; Bytes=8; Act='act-ub'; Wt='wt-n' }
    @{ Op='mxmpy-w8a8-cm';  Rule='HmxMultiply'; Bytes=8; Act='act-ub-cm'; Wt='wt-b' }
    @{ Op='mxmpy-w4a8-cm';  Rule='HmxMultiply'; Bytes=8; Act='act-ub-cm'; Wt='wt-n' }
)
$script:InstructionByOp = @{}
foreach ($record in $script:Instructions) {
    if ($script:InstructionByOp.ContainsKey($record.Op)) { throw "Duplicate instruction record: $($record.Op)" }
    if (-not $record.ContainsKey('Rule')) { $record.Rule = 'Plain' }
    if (-not $record.ContainsKey('Bytes')) { $record.Bytes = 4 }
    $script:InstructionByOp[$record.Op] = $record
}

# The encoder's rule numbers, in the order the encoder tests them.
$script:EncodingRules = @('Plain','Label','EndLoop','LoopStart','Pairs','PairShift','Unsigned','Signed16','Raw','Offset',
    'VectorOffset','VectorPost','Branch','AlignRegister','Lookup','Shuffle','CounterPair','Registers','GotCall','Frame',
    'HmxPair','HmxMultiply','Return')

# The authoring tables cross this boundary once. Fields and presence bits are
# shared by all jobs; absence is distinct from a supplied zero.
class HexagonStep {
    [string] $Op
    [int] $d
    [int] $s
    [int] $t
    [int] $u
    [int] $x
    [int] $e
    [int] $r
    [int] $v
    [long] $i
    [long] $Offset
    [long] $Bytes
    [long] $Delta
    [string] $Name
    [string] $Label
    [string] $Import
    [string] $Data
    [string] $Act
    [string] $Wt
    [long] $Present

    HexagonStep() { }

    static [int] FieldIndex([string] $Name) {
        if ($Name -eq 'Op') { return 0 }
        if ($Name -eq 'd') { return 1 }
        if ($Name -eq 's') { return 2 }
        if ($Name -eq 't') { return 3 }
        if ($Name -eq 'u') { return 4 }
        if ($Name -eq 'x') { return 5 }
        if ($Name -eq 'e') { return 6 }
        if ($Name -eq 'r') { return 7 }
        if ($Name -eq 'v') { return 8 }
        if ($Name -eq 'i') { return 9 }
        if ($Name -eq 'Offset') { return 10 }
        if ($Name -eq 'Bytes') { return 11 }
        if ($Name -eq 'Delta') { return 12 }
        if ($Name -eq 'Name') { return 13 }
        if ($Name -eq 'Label') { return 14 }
        if ($Name -eq 'Import') { return 15 }
        if ($Name -eq 'Data') { return 16 }
        if ($Name -eq 'Act') { return 17 }
        if ($Name -eq 'Wt') { return 18 }
        return -1
    }

    [bool] ContainsKey([string] $Name) {
        [int] $index = [HexagonStep]::FieldIndex($Name)
        return $index -ge 0 -and ($this.Present -band (1L -shl $index)) -ne 0L
    }

    [long] Get([string] $Name) {
        if ($Name -eq 'd') { return [long]$this.d }
        if ($Name -eq 's') { return [long]$this.s }
        if ($Name -eq 't') { return [long]$this.t }
        if ($Name -eq 'u') { return [long]$this.u }
        if ($Name -eq 'x') { return [long]$this.x }
        if ($Name -eq 'e') { return [long]$this.e }
        if ($Name -eq 'r') { return [long]$this.r }
        if ($Name -eq 'v') { return [long]$this.v }
        if ($Name -eq 'i') { return $this.i }
        if ($Name -eq 'Offset') { return $this.Offset }
        if ($Name -eq 'Bytes') { return $this.Bytes }
        if ($Name -eq 'Delta') { return $this.Delta }
        throw [ArgumentException]::new('Unknown numeric step field: ' + $Name)
    }

    static [string] Invalid([int] $Index, [string] $Op, [string] $Field) {
        return 'Step ' + [Convert]::ToString($Index) + ' Op=' + $Op + ' field=' + $Field + ': exact CLR type required'
    }

    static [HexagonStep[]] Convert([hashtable[]] $Source) {
        [HexagonStep[]] $result = [HexagonStep[]]::new($Source.Length)
        for ([int]$index = 0; $index -lt $Source.Length; $index++) {
            [hashtable] $table = $Source[$index]
            if ([object]$table -eq $null) { throw [HexagonStep]::Invalid($index, '<missing>', '<step>') }
            [object] $raw = $table.get_Item('Op')
            if ($raw -eq $null) { throw [HexagonStep]::Invalid($index, '<missing>', 'Op') }
            if ($raw.GetType().FullName -cne 'System.String') { throw [HexagonStep]::Invalid($index, '<invalid>', 'Op') }
            [string] $operation = [string]$raw
            [HexagonStep] $step = [HexagonStep]::new()
            [object[]] $keys = [object[]]::new($table.Count)
            $table.Keys.CopyTo([Array]$keys, 0)
            for ([int]$keyAt = 0; $keyAt -lt $keys.Length; $keyAt++) {
                [object] $rawKey = $keys[$keyAt]
                if ($rawKey.GetType().FullName -cne 'System.String') { throw [HexagonStep]::Invalid($index, $operation, '<key>') }
                [string] $key = [string]$rawKey
                [int] $field = [HexagonStep]::FieldIndex($key)
                if ($field -lt 0) { throw [HexagonStep]::Invalid($index, $operation, $key) }
                $raw = $table.get_Item($key)
                if ($raw -eq $null) { throw [HexagonStep]::Invalid($index, $operation, $key) }
                [string] $typeName = $raw.GetType().FullName
                [long] $number = 0L
                [string] $text = ''
                if ($field -ge 1 -and $field -le 8) {
                    if ($typeName -cne 'System.Int32') { throw [HexagonStep]::Invalid($index, $operation, $key) }
                    $number = [long][int]$raw
                } elseif ($field -ge 9 -and $field -le 12) {
                    if ($typeName -ceq 'System.Int32') { $number = [long][int]$raw }
                    elseif ($typeName -ceq 'System.Int64') { $number = [long]$raw }
                    else { throw [HexagonStep]::Invalid($index, $operation, $key) }
                } else {
                    if ($typeName -cne 'System.String') { throw [HexagonStep]::Invalid($index, $operation, $key) }
                    $text = [string]$raw
                }
                if ($field -eq 0) { $step.Op = $text }
                elseif ($field -eq 1) { $step.d = [int]$number }
                elseif ($field -eq 2) { $step.s = [int]$number }
                elseif ($field -eq 3) { $step.t = [int]$number }
                elseif ($field -eq 4) { $step.u = [int]$number }
                elseif ($field -eq 5) { $step.x = [int]$number }
                elseif ($field -eq 6) { $step.e = [int]$number }
                elseif ($field -eq 7) { $step.r = [int]$number }
                elseif ($field -eq 8) { $step.v = [int]$number }
                elseif ($field -eq 9) { $step.i = $number }
                elseif ($field -eq 10) { $step.Offset = $number }
                elseif ($field -eq 11) { $step.Bytes = $number }
                elseif ($field -eq 12) { $step.Delta = $number }
                elseif ($field -eq 13) { $step.Name = $text }
                elseif ($field -eq 14) { $step.Label = $text }
                elseif ($field -eq 15) { $step.Import = $text }
                elseif ($field -eq 16) { $step.Data = $text }
                elseif ($field -eq 17) { $step.Act = $text }
                elseif ($field -eq 18) { $step.Wt = $text }
                $step.Present = $step.Present -bor (1L -shl $field)
            }
            $result[$index] = $step
        }
        return $result
    }
}

# Fixed bits and field positions of one encoding pattern, indexed once.
class HexagonForm {
    [string] $Name
    [int[]] $Pattern
    [int[]] $Counts
    [long] $Mask
    [long] $Bits
    [int] $Fixed

    HexagonForm([string] $Name, [string] $Pattern) {
        $this.Name = $Name
        if ($Pattern.Length -ne 32) { throw ('Invalid instruction form: ' + $Name) }
        $this.Pattern = [int[]]::new(32)
        $this.Counts = [int[]]::new(128)
        for ([int]$at = 0; $at -lt 32; $at++) {
            [int] $key = [int]$Pattern.get_Chars($at)
            $this.Pattern[$at] = $key
            if ($key -eq 48 -or $key -eq 49 -or $key -eq 45) {
                $this.Mask = $this.Mask -bor (1L -shl (31 - $at))
                $this.Fixed = $this.Fixed + 1
                if ($key -eq 49) { $this.Bits = $this.Bits -bor (1L -shl (31 - $at)) }
            } else { $this.Counts[$key] = $this.Counts[$key] + 1 }
        }
    }
}

class HexagonFields {
    [long[]] $Values
    [bool[]] $Present
    HexagonFields() {
        $this.Values = [long[]]::new(128)
        $this.Present = [bool[]]::new(128)
    }
    [void] Set([string] $Name, [long] $Value) {
        [int] $key = [int]$Name.get_Chars(0)
        $this.Values[$key] = $Value
        $this.Present[$key] = $true
    }
    [long] Get([string] $Name) { return $this.Values[[int]$Name.get_Chars(0)] }
}

class HexagonDecoded {
    [string] $Op
    [HexagonFields] $Fields
    HexagonDecoded([string] $Op, [HexagonFields] $Fields) { $this.Op = $Op; $this.Fields = $Fields }
}

class HexagonLayout {
    [int[]] $Lengths
    [long] $Size
    [System.Collections.Generic.Dictionary[string,long]] $Labels
    [string[]] $Imports
    HexagonLayout() { }
}

# One instruction record as the encoder sees it.
class HexagonRule {
    [int] $Kind
    [int] $Bytes
    [long] $Scale
    [long] $Min
    [long] $Max
    [string] $Pairs
    [string] $Fields
    [string] $Message
    [string] $Message2
    [string] $PairMessage
    [string] $Act
    [string] $Wt
    HexagonRule() { }
}

class HexagonEncoder {
    [HexagonForm[]] $Forms
    [System.Collections.Generic.Dictionary[string,HexagonForm]] $ByName
    [System.Collections.Generic.Dictionary[string,HexagonRule]] $Rules

    # Forms are tried most specific first when decoding. Rules arrive as parallel arrays, one entry per record.
    HexagonEncoder([string[]] $Names, [string[]] $Patterns, [string[]] $RuleOps, [int[]] $Kinds, [int[]] $Bytes,
        [long[]] $Scales, [long[]] $Mins, [long[]] $Maxes, [string[]] $Pairs, [string[]] $Fields, [string[]] $Messages,
        [string[]] $Messages2, [string[]] $PairMessages, [string[]] $Acts, [string[]] $Wts) {
        [HexagonForm[]] $unsorted = [HexagonForm[]]::new($Names.Length)
        $this.ByName = [System.Collections.Generic.Dictionary[string,HexagonForm]]::new([StringComparer]::InvariantCultureIgnoreCase)
        for ([int]$n = 0; $n -lt $Names.Length; $n++) {
            [HexagonForm] $form = [HexagonForm]::new($Names[$n], $Patterns[$n])
            $unsorted[$n] = $form
            $this.ByName.Add($Names[$n], $form)
        }
        $this.Forms = [HexagonForm[]]::new($Names.Length)
        [bool[]] $taken = [bool[]]::new($Names.Length)
        for ([int]$slot = 0; $slot -lt $Names.Length; $slot++) {
            [int] $best = -1
            for ([int]$n = 0; $n -lt $Names.Length; $n++) {
                if ($taken[$n]) { continue }
                if ($best -lt 0 -or $unsorted[$n].Fixed -gt $unsorted[$best].Fixed) { $best = $n }
            }
            $taken[$best] = $true
            $this.Forms[$slot] = $unsorted[$best]
        }
        $this.Rules = [System.Collections.Generic.Dictionary[string,HexagonRule]]::new([StringComparer]::Ordinal)
        for ([int]$n = 0; $n -lt $RuleOps.Length; $n++) {
            [HexagonRule] $rule = [HexagonRule]::new()
            $rule.Kind = $Kinds[$n]; $rule.Bytes = $Bytes[$n]; $rule.Scale = $Scales[$n]; $rule.Min = $Mins[$n]; $rule.Max = $Maxes[$n]
            $rule.Pairs = $Pairs[$n]; $rule.Fields = $Fields[$n]; $rule.Message = $Messages[$n]; $rule.Message2 = $Messages2[$n]
            $rule.PairMessage = $PairMessages[$n]; $rule.Act = $Acts[$n]; $rule.Wt = $Wts[$n]
            $this.Rules.Add($RuleOps[$n], $rule)
        }
    }

    [uint32] Word([string] $Name, [HexagonFields] $Fields) {
        if (-not $this.ByName.ContainsKey($Name)) { throw ('Invalid instruction form: ' + $Name) }
        [HexagonForm] $form = $this.ByName.get_Item($Name)
        [long[]] $values = [long[]]::new(128)
        for ([int]$key = 0; $key -lt 128; $key++) {
            if ($form.Counts[$key] -eq 0) { continue }
            [string] $fieldName = [Convert]::ToString([char]$key)
            if (-not $Fields.Present[$key]) { throw ('Missing ' + $Name + ' field ' + $fieldName) }
            [long] $value = $Fields.Values[$key]
            if ($value -lt 0L -or $value -ge (1L -shl $form.Counts[$key])) { throw ($Name + ' field ' + $fieldName + ' out of range') }
            $values[$key] = $value
        }
        [long] $word = 0L
        for ([int]$at = 31; $at -ge 0; $at--) {
            [int] $key = $form.Pattern[$at]
            [long] $bit = 0L
            if ($key -eq 49) { $bit = 1L }
            elseif ($key -ne 48 -and $key -ne 45) {
                $bit = $values[$key] -band 1L
                $values[$key] = $values[$key] -shr 1
            }
            $word = $word -bor ($bit -shl (31 - $at))
        }
        return [uint32]$word
    }

    [HexagonDecoded] Read([uint32] $Word) {
        [long] $bits = [long]$Word
        foreach ($form in $this.Forms) {
            if (($bits -band $form.Mask) -ne $form.Bits) { continue }
            [HexagonFields] $fields = [HexagonFields]::new()
            for ([int]$at = 0; $at -lt 32; $at++) {
                [int] $key = $form.Pattern[$at]
                if ($key -eq 48 -or $key -eq 49 -or $key -eq 45) { continue }
                $fields.Present[$key] = $true
                $fields.Values[$key] = ($fields.Values[$key] -shl 1) -bor (($bits -shr (31 - $at)) -band 1L)
            }
            return [HexagonDecoded]::new($form.Name, $fields)
        }
        throw ('Unknown Hexagon instruction 0x' + [Convert]::ToString($bits, 16).PadLeft(8, [char]48).ToUpperInvariant())
    }

    [int] Length([HexagonStep] $Step) {
        if (-not $this.Rules.ContainsKey($Step.Op)) { return 4 }
        return $this.Rules.get_Item($Step.Op).Bytes
    }

    [HexagonLayout] Layout([HexagonStep[]] $Steps, [long] $Base) {
        [HexagonLayout] $layout = [HexagonLayout]::new()
        $layout.Lengths = [int[]]::new($Steps.Length)
        $layout.Labels = [System.Collections.Generic.Dictionary[string,long]]::new([StringComparer]::InvariantCultureIgnoreCase)
        [System.Collections.Generic.List[string]] $imports = [System.Collections.Generic.List[string]]::new()
        for ([int]$n = 0; $n -lt $Steps.Length; $n++) {
            [HexagonStep] $step = $Steps[$n]
            if ($step.Op -eq 'label') {
                if ($layout.Labels.ContainsKey($step.Name)) { throw ('Duplicate label ' + $step.Name) }
                $layout.Labels.Add($step.Name, $Base + $layout.Size)
            }
            if ($step.ContainsKey('Import') -and $step.Import.Length -gt 0 -and -not $imports.Contains($step.Import)) { $imports.Add($step.Import) }
            [int] $length = $this.Length($step)
            $layout.Lengths[$n] = $length
            $layout.Size = $layout.Size + [long]$length
        }
        $layout.Imports = $imports.ToArray()
        return $layout
    }

    static [void] Relocate([HexagonLayout] $Layout, [long] $Base) {
        [string[]] $keys = [string[]]::new($Layout.Labels.Count)
        $Layout.Labels.Keys.CopyTo($keys, 0)
        foreach ($key in $keys) { $Layout.Labels.set_Item($key, $Layout.Labels.get_Item($key) + $Base) }
    }

    [byte[]] Packet([string] $Act, [string] $Wt, [HexagonStep] $Step, [string] $Failure) {
        [HexagonFields] $a = [HexagonFields]::new()
        $a.Set('s', [long]$Step.s); $a.Set('t', [long]$Step.t); $a.Set('P', 1L)
        [HexagonFields] $w = [HexagonFields]::new()
        $w.Set('u', [long]$Step.u); $w.Set('v', [long]$Step.v); $w.Set('P', 3L)
        [uint32] $w0 = $this.Word($Act, $a)
        [uint32] $w1 = $this.Word($Wt, $w)
        if ($this.Read($w0).Op -ne $Act -or $this.Read($w1).Op -ne $Wt) { throw $Failure }
        [byte[]] $bytes = [byte[]]::new(8)
        [Array]::Copy([BitConverter]::GetBytes($w0), 0, $bytes, 0, 4)
        [Array]::Copy([BitConverter]::GetBytes($w1), 0, $bytes, 4, 4)
        return $bytes
    }

    # Each letter of $Fields names a one-letter register field.
    static [void] RequirePairs([HexagonStep] $Step, [string] $Fields, [string] $Message) {
        for ([int]$at = 0; $at -lt $Fields.Length; $at++) {
            [long] $value = $Step.Get([Convert]::ToString($Fields.get_Chars($at)))
            if ($value % 2L -ne 0L -or $value -lt 0L -or $value -gt 30L) { throw $Message }
        }
    }

    [byte[]] Instruction([HexagonStep] $Step, [long] $Pc, [long] $Target) {
        if (-not $this.Rules.ContainsKey($Step.Op)) { throw ('Invalid instruction form: ' + $Step.Op) }
        [HexagonRule] $rule = $this.Rules.get_Item($Step.Op)
        [int] $kind = $rule.Kind
        if ($kind -eq 1) { return [byte[]]::new(0) }
        [HexagonFields] $fields = [HexagonFields]::new()
        $fields.Set('P', 3L)
        foreach ($key in [string[]]@('d','s','t','x','u','e')) { if ($Step.ContainsKey($key)) { $fields.Set($key, $Step.Get($key)) } }
        if ($kind -eq 2) {
            # The required loop-end packet contains only preserving adds.
            [int] $words = 2
            if ($Step.Op -eq 'endloop1') { $words = 3 }
            [byte[]] $loopBytes = [byte[]]::new(4*$words)
            for ([int]$loopWord=0; $loopWord -lt $words; $loopWord++) {
                [HexagonFields] $loopFields = [HexagonFields]::new()
                [long] $reg = 16-$words+$loopWord
                $loopFields.Set('s',$reg); $loopFields.Set('d',$reg); $loopFields.Set('i',0L)
                [long] $parse = 1L
                if ($loopWord -eq $words-1) { $parse = 3L }
                elseif (($words -eq 2 -and $loopWord -eq 0) -or ($words -eq 3 -and $loopWord -eq 1)) { $parse = 2L }
                $loopFields.Set('P',$parse)
                [Array]::Copy([BitConverter]::GetBytes($this.Word('addi',$loopFields)),0,$loopBytes,4*$loopWord,4)
            }
            return $loopBytes
        }
        elseif ($kind -eq 3) {
            [long] $loopDelta = $Target-$Pc
            if ($loopDelta % 4L -ne 0L -or $loopDelta -lt -256L -or $loopDelta -gt 252L) { throw 'Hardware loop start out of range or unaligned' }
            $fields.Set('i', [long]($loopDelta/4L) -band 127L)
        }
        elseif ($kind -eq 4) { [HexagonEncoder]::RequirePairs($Step, $rule.Pairs, $rule.Message) }
        elseif ($kind -eq 5) {
            [HexagonEncoder]::RequirePairs($Step, $rule.Pairs, $rule.Message)
            if ($Step.i -lt $rule.Min -or $Step.i -gt $rule.Max) { throw 'Double-word shift out of range' }
            $fields.Set('i', $Step.i)
        }
        elseif ($kind -eq 6) {
            if ($Step.i -lt $rule.Min -or $Step.i -gt $rule.Max) { throw $rule.Message }
            $fields.Set('i', $Step.i)
        }
        elseif ($kind -eq 7) {
            if ($Step.i -lt -32768L -or $Step.i -gt 32767L) { throw 'Signed immediate out of range' }
            $fields.Set('i', $Step.i -band 65535L)
        }
        elseif ($kind -eq 8) { $fields.Set('i', $Step.i) }
        elseif ($kind -eq 9) {
            if ($Step.Offset % $rule.Scale -ne 0L -or $Step.Offset -lt $rule.Min -or $Step.Offset -gt $rule.Max) { throw $rule.Message }
            if ($rule.Pairs.Length -gt 0) { [HexagonEncoder]::RequirePairs($Step, $rule.Pairs, $rule.PairMessage) }
            $fields.Set('i', ([long]($Step.Offset / $rule.Scale)) -band 2047L)
            # A double-word store names its base and source pair even when the step leaves them at zero.
            if ($Step.Op -eq 'store-d') { $fields.Set('t', [long]$Step.t); $fields.Set('s', [long]$Step.s) }
        }
        elseif ($kind -eq 10 -or $kind -eq 11) {
            [int] $vOff = 1
            if ($kind -eq 10) {
                $vOff = 0
                if ($Step.ContainsKey('Offset')) {
                    if ($Step.Offset % 128L -ne 0L) { throw 'Vector offset must be multiple of 128 bytes' }
                    $vOff = [int]($Step.Offset / 128L)
                } elseif ($Step.ContainsKey('i')) { $vOff = [int]$Step.i }
                if ($vOff -lt -8 -or $vOff -gt 7) { throw 'Vector immediate offset out of range (-8..7)' }
            } else {
                if ($Step.ContainsKey('i')) { $vOff = [int]$Step.i }
                if ($vOff -lt -8 -or $vOff -gt 7) { throw 'Vector post-increment offset out of range (-8..7)' }
            }
            if ($vOff -ge 0) { $fields.Set('i', [long]$vOff) } else { $fields.Set('i', (1L -shl 5) -bor ([long]$vOff -band 7L)) }
        }
        elseif ($kind -eq 12) {
            [long] $delta = $Target - $Pc
            if ($delta % 4L -ne 0L -or $delta -lt -65536L -or $delta -gt 65532L) { throw 'Branch out of range' }
            $fields.Set('i', ([long]($delta / 4L)) -band 32767L)
        }
        elseif ($kind -eq 13) {
            if ($Step.ContainsKey('r')) { $fields.Set('x', [long]$Step.r) }
            if ($fields.Get('x') -lt 0L -or $fields.Get('x') -gt 7L) { throw 'Valign register out of range (r0..r7)' }
        }
        elseif ($kind -eq 14) {
            if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Lookup destination pair must be even and 0..30' }
            if ($Step.x -lt 0 -or $Step.x -gt 7) { throw 'Lookup scalar control must be r0..7' }
            if ($Step.v -lt 0 -or $Step.v -gt 31) { throw 'Lookup table vector out of range' }
            $fields.Set('v', [long]$Step.v)
        }
        elseif ($kind -eq 15) {
            if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Vshuff destination register pair must be even and 0..30' }
            if ($Step.s -lt 0 -or $Step.s -gt 31 -or $Step.t -lt 0 -or $Step.t -gt 31) { throw 'Vshuff source register out of range (0..31)' }
            if ($Step.r -lt 0 -or $Step.r -gt 7) { throw 'Vshuff scalar register out of range (r0..r7)' }
            $fields.Set('d', [long]$Step.d); $fields.Set('s', [long]$Step.s); $fields.Set('t', [long]$Step.t); $fields.Set('r', [long]$Step.r)
        }
        elseif ($kind -eq 16) {
            if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Pcycle/Hwticks destination register pair must be even and 0..30' }
            $fields.Set('d', [long]$Step.d)
        }
        elseif ($kind -eq 17) {
            # Register fields 0..31, checked in order; the second field reports Message2.
            for ([int]$at = 0; $at -lt $rule.Fields.Length; $at++) {
                [string] $name = [Convert]::ToString($rule.Fields.get_Chars($at))
                [long] $value = $Step.Get($name)
                if ($value -lt 0L -or $value -gt 31L) {
                    if ($at -eq 0) { throw $rule.Message }
                    throw $rule.Message2
                }
            }
            for ([int]$at = 0; $at -lt $rule.Fields.Length; $at++) {
                [string] $name = [Convert]::ToString($rule.Fields.get_Chars($at))
                $fields.Set($name, $Step.Get($name))
            }
        }
        elseif ($kind -eq 18) {
            if (-not $Step.ContainsKey('Import') -or $Step.Import.Length -eq 0) { throw 'got-call needs an Import' }
            if ($Step.d -lt 0 -or $Step.d -gt 27) { throw 'got-call register out of range (r0..r27)' }
            [long] $delta = $Target - $Pc
            if ($delta -lt -2147483648L -or $delta -gt 2147483647L) { throw 'GOT slot out of range' }
            [long] $u = $delta -band 4294967295L
            [byte[]] $bytes = [byte[]]::new(16)
            [HexagonFields] $part = [HexagonFields]::new()
            $part.Set('i', $u -shr 6); $part.Set('P', 1L)
            [Array]::Copy([BitConverter]::GetBytes($this.Word('immext', $part)), 0, $bytes, 0, 4)
            $part = [HexagonFields]::new(); $part.Set('i', $u -band 63L); $part.Set('d', [long]$Step.d); $part.Set('P', 3L)
            [Array]::Copy([BitConverter]::GetBytes($this.Word('add-pc', $part)), 0, $bytes, 4, 4)
            $part = [HexagonFields]::new(); $part.Set('i', 0L); $part.Set('s', [long]$Step.d); $part.Set('d', [long]$Step.d); $part.Set('P', 3L)
            [Array]::Copy([BitConverter]::GetBytes($this.Word('load', $part)), 0, $bytes, 8, 4)
            $part = [HexagonFields]::new(); $part.Set('s', [long]$Step.d); $part.Set('P', 3L)
            [Array]::Copy([BitConverter]::GetBytes($this.Word('callr', $part)), 0, $bytes, 12, 4)
            return $bytes
        }
        elseif ($kind -eq 19) {
            if ($Step.Bytes % 8L -ne 0L -or $Step.Bytes -lt 0L -or $Step.Bytes -gt 16376L) { throw 'Frame size must be a multiple of 8 up to 16376' }
            $fields.Set('i', [long]($Step.Bytes / 8L))
        }
        elseif ($kind -eq 20) {
            if ($Step.Act -notin 'act-hf','act-hf-single','act-ub','act-ub-cm','act-ub-single') { throw ('Unsupported HMX activation form: ' + $Step.Act) }
            if ($Step.Wt -notin 'wt-hf','wt-b','wt-n','wt-b-deep') { throw ('Unsupported HMX weight form: ' + $Step.Wt) }
            foreach ($r in [string[]]@('s','t','u','v')) { if ($Step.Get($r) -lt 0L -or $Step.Get($r) -gt 31L) { throw ('HMX register ' + $r + ' out of range (0..31)') } }
            return $this.Packet($Step.Act, $Step.Wt, $Step, 'HMX packet failed round-trip decode')
        }
        elseif ($kind -eq 21) {
            if ($Step.s -lt 0 -or $Step.s -gt 31 -or $Step.t -lt 0 -or $Step.t -gt 31) { throw 'HMX activation registers out of range (0..31)' }
            if ($Step.u -lt 0 -or $Step.u -gt 31 -or $Step.v -lt 0 -or $Step.v -gt 31) { throw 'HMX weight registers out of range (0..31)' }
            return $this.Packet($rule.Act, $rule.Wt, $Step, 'HMX dual-slot packet failed round-trip decode')
        }
        elseif ($kind -eq 22) { $fields.Set('s', 31L) }
        [uint32] $word = $this.Word($Step.Op, $fields)
        [HexagonDecoded] $decoded = $this.Read($word)
        if ($decoded.Op -ne $Step.Op) { throw 'Instruction decoded to a different operation' }
        for ([int]$fieldIndex = 0; $fieldIndex -lt 128; $fieldIndex++) {
            if ($fields.Present[$fieldIndex] -and $decoded.Fields.Values[$fieldIndex] -ne $fields.Values[$fieldIndex]) { throw ('Decode mismatch: ' + [Convert]::ToString([char]$fieldIndex)) }
        }
        return [BitConverter]::GetBytes($word)
    }

    [byte[]] Encode([HexagonStep[]] $Steps, [HexagonLayout] $Layout, [long] $Base,
        [System.Collections.Generic.Dictionary[string,long]] $Got, [System.Collections.Generic.Dictionary[string,long]] $Data) {
        [byte[]] $result = [byte[]]::new([int]$Layout.Size)
        [long] $pc = $Base
        for ([int]$n = 0; $n -lt $Steps.Length; $n++) {
            [HexagonStep] $step = $Steps[$n]
            [long] $target = 0L
            if ($step.ContainsKey('Import') -and $step.Import.Length -gt 0) { $target = $Got.get_Item($step.Import) }
            elseif ($step.ContainsKey('Data') -and $step.Data.Length -gt 0) {
                if (-not $Data.ContainsKey($step.Data)) { throw ('Unknown data ' + $step.Data) }
                $target = $Data.get_Item($step.Data)
            } elseif ($step.ContainsKey('Label') -and $step.Label.Length -gt 0) {
                if (-not $Layout.Labels.ContainsKey($step.Label)) { throw ('Unknown label ' + $step.Label) }
                $target = $Layout.Labels.get_Item($step.Label)
            }
            [byte[]] $bytes = $this.Instruction($step, $pc, $target)
            [int] $length = $Layout.Lengths[$n]
            if ($bytes.Length -ne $length) { throw ('Encoded length mismatch: ' + $step.Op) }
            [Array]::Copy($bytes, 0, $result, [int]($pc - $Base), $length)
            $pc = $pc + [long]$length
        }
        return $result
    }
}

function New-HexagonEncoder {
    # Builds the lowered encoder from the instruction records. $Type is the lowered HexagonEncoder type.
    param([Parameter(Mandatory)][type]$Type)
    $withPattern = @($script:Instructions | Where-Object { $_.ContainsKey('Pattern') })
    $text = { param($record, $key) if ($record.ContainsKey($key)) { [string]$record[$key] } else { '' } }
    $number = { param($record, $key) if ($record.ContainsKey($key)) { [long]$record[$key] } else { 0L } }
    $Type::new(
        [string[]]@($withPattern.Op), [string[]]@($withPattern.Pattern),
        [string[]]@($script:Instructions.Op),
        [int[]]@(foreach ($record in $script:Instructions) { [array]::IndexOf($script:EncodingRules, $record.Rule) }),
        [int[]]@($script:Instructions.Bytes),
        [long[]]@(foreach ($record in $script:Instructions) { & $number $record 'Scale' }),
        [long[]]@(foreach ($record in $script:Instructions) { & $number $record 'Min' }),
        [long[]]@(foreach ($record in $script:Instructions) { & $number $record 'Max' }),
        [string[]]@(foreach ($record in $script:Instructions) { & $text $record 'Pairs' }),
        [string[]]@(foreach ($record in $script:Instructions) { & $text $record 'Fields' }),
        [string[]]@(foreach ($record in $script:Instructions) { & $text $record 'Message' }),
        [string[]]@(foreach ($record in $script:Instructions) { & $text $record 'Message2' }),
        [string[]]@(foreach ($record in $script:Instructions) { & $text $record 'PairMessage' }),
        [string[]]@(foreach ($record in $script:Instructions) { & $text $record 'Act' }),
        [string[]]@(foreach ($record in $script:Instructions) { & $text $record 'Wt' }))
}

function Get-InstructionSet {
    # Instruction-set descriptor used by job builders that lay out their own labels.
    param([string] $Isa)
    if ($Isa -and $Isa -ne 'HexagonV73') { throw "Unsupported ISA: $Isa" }
    $byOp = $script:InstructionByOp
    [pscustomobject]@{
        Id='HexagonV73'; Name='Hexagon V73'; StateBit=0
        Length={ param($Step) $record = $byOp[$Step.Op]; if ($record) { $record.Bytes } else { 4 } }.GetNewClosure()
    }
}

function ConvertTo-HexagonAssembly {
    # Assembly text of one step from its instruction record, for independent assembly by the SDK toolchain.
    param([hashtable] $Step)
    $record = $script:InstructionByOp[$Step.Op]
    if (-not $record) { throw "Unsupported operation: $($Step.Op)" }
    switch ($record.Rule) {
        'Label' { return "$($Step.Name):" }
        'EndLoop' { return $record.Asm }
        'GotCall' {
            # Delta (GOT slot - pc) is filled in after layout by the emitter for independent assembly.
            if ($null -eq $Step.Delta) { throw 'got-call assembly needs the resolved Delta' }
            return "{ r$($Step.d) = add(pc,##$($Step.Delta)) }`n{ r$($Step.d) = memw(r$($Step.d)+#0) }`n{ callr r$($Step.d) }"
        }
        'HmxPair' {
            $act = @{ 'act-hf'='activation.hf'; 'act-hf-single'='activation.hf'; 'act-ub'='activation.ub'; 'act-ub-cm'='activation.ub'; 'act-ub-single'='activation.ub' }[$Step.Act]
            $actSuffix = @{ 'act-hf'=''; 'act-hf-single'=':single'; 'act-ub'=''; 'act-ub-cm'=':cm'; 'act-ub-single'=':single' }[$Step.Act]
            $wt = @{ 'wt-hf'='weight.hf'; 'wt-b'='weight.b'; 'wt-n'='weight.n'; 'wt-b-deep'='weight.b' }[$Step.Wt]
            $wtSuffix = if ($Step.Wt -eq 'wt-b-deep') { ':deep' } else { '' }
            return "{`n`t$act = mxmem(r$($Step.s),r$($Step.t))$actSuffix`n`t$wt = mxmem(r$($Step.u),r$($Step.v))$wtSuffix`n}"
        }
        'HmxMultiply' {
            $actType = if ($record.Act -eq 'act-hf') { 'hf' } else { 'ub' }
            $actSuffix = if ($record.Act -eq 'act-ub-cm') { ':cm' } else { '' }
            $wtType = $record.Wt.Substring(3)
            return "{`n`tactivation.$actType = mxmem(r$($Step.s),r$($Step.t))$actSuffix`n`tweight.$wtType = mxmem(r$($Step.u),r$($Step.v))`n}"
        }
    }
    if (-not $record.ContainsKey('Asm')) { throw "Unsupported operation: $($Step.Op)" }
    if ($record.ContainsKey('AsmEvenD') -and $Step.d % 2) { throw 'Vector pair register must be even' }
    $vectorOffset = if ($Step.ContainsKey('Offset')) { [int]($Step.Offset / 128) } elseif ($Step.ContainsKey('i')) { [int]$Step.i } else { 0 }
    $vectorPost = if ($Step.ContainsKey('i')) { [int]$Step.i } else { 1 }
    $alignRegister = if ($Step.ContainsKey('x')) { $Step.x } elseif ($Step.ContainsKey('r')) { $Step.r } else { 0 }
    $text = [regex]::Replace($record.Asm, '\{([A-Za-z]+)(1?)\}', {
        param($m)
        $name = $m.Groups[1].Value
        switch -CaseSensitive ($name) {
            'VectorOffset' { return [string]$vectorOffset }
            'VectorPost' { return [string]$vectorPost }
            'AlignRegister' { return [string]$alignRegister }
        }
        $value = $Step[$name]
        if ($m.Groups[2].Value) { return [string]($value + 1) }
        [string]$value
    })
    "{ $text }"
}

function New-HexagonProbeSteps {
    # FastRPC skel ABI (SDK 6.4.0.2 qaic): (uint64 handle, uint32 scalars, remote_arg *args) arrives in r1:r0, r2, r3;
    # remote_arg is 8 bytes on the DSP. Method 0 opens a stateless handle, method 1 closes, method 2 adds two int32s.
    $steps = [Collections.Generic.List[hashtable]]::new()
    foreach ($dispatch in @(@(0x00020001,'open'),@(0x01000010,'success'),@(0x02010100,'sum'))) {
        $steps.Add(@{Op='lo';x=4;i=([long]$dispatch[0] -band 65535)})
        $steps.Add(@{Op='hi';x=4;i=([long]$dispatch[0] -shr 16)})
        $steps.Add(@{Op='eq';d=0;s=2;t=4})
        $steps.Add(@{Op='jump-p';u=0;Label=$dispatch[1]})
    }
    $steps.Add(@{Op='imm';d=0;i=20}); $steps.Add(@{Op='return'}) # AEE_EUNSUPPORTED
    $steps.Add(@{Op='label';Name='open'})
    $steps.Add(@{Op='imm';d=4;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=4}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    $steps.Add(@{Op='imm';d=4;i=1}); $steps.Add(@{Op='store';s=3;t=4;Offset=16})
    $steps.Add(@{Op='imm';d=4;i=0}); $steps.Add(@{Op='store';s=3;t=4;Offset=20})
    $steps.Add(@{Op='label';Name='success'})
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label';Name='bad'})
    $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'}) # AEE_EBADPARM
    $steps.Add(@{Op='label';Name='sum'})
    $steps.Add(@{Op='imm';d=4;i=0})
    $steps.Add(@{Op='eq';d=0;s=3;t=4}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    # Require at least 8 input and 4 output bytes before pointers are read.
    foreach ($check in @(@(4,8),@(12,4))) {
        $steps.Add(@{Op='load';d=4;s=3;Offset=$check[0]})
        $steps.Add(@{Op='imm';d=5;i=($check[1]-1)})
        $steps.Add(@{Op='gtu';d=0;s=4;t=5})
        # Branch over the immediate return only for a sufficient buffer length.
        $label = "length_$($check[0])"
        $steps.Add(@{Op='jump-p';u=0;Label=$label})
        $steps.Add(@{Op='imm';d=0;i=14}); $steps.Add(@{Op='return'})
        $steps.Add(@{Op='label';Name=$label})
    }
    $steps.Add(@{Op='load';d=4;s=3;Offset=0})
    $steps.Add(@{Op='load';d=5;s=3;Offset=8})
    $steps.Add(@{Op='imm';d=6;i=0})
    foreach ($r in 4,5) {
        $steps.Add(@{Op='eq';d=0;s=$r;t=6}); $steps.Add(@{Op='jump-p';u=0;Label='bad'})
    }
    $steps.Add(@{Op='load';d=6;s=4;Offset=0})
    $steps.Add(@{Op='load';d=7;s=4;Offset=4})
    $steps.Add(@{Op='add';d=6;s=6;t=7})
    $steps.Add(@{Op='store';s=5;t=6;Offset=0})
    $steps.Add(@{Op='imm';d=0;i=0}); $steps.Add(@{Op='return'})
    $steps.ToArray()
}

if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Command) {
    'Instructions' {
        $script:Instructions | ForEach-Object { [pscustomobject]@{ Op = $_.Op; Rule = $_.Rule; Bytes = $_.Bytes; Asm = $_.Asm; Source = $_.Source } }
    }
    default { "Hexagon V73 instruction records: $($script:Instructions.Count). Commands: Instructions" }
}
