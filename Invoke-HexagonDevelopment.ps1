#requires -Version 7.4
<#
.SYNOPSIS
Hexagon V73 development: instruction records, encoding, assembly text and layout for emitted DSP code.

.DESCRIPTION
One owning file for Hexagon work. $script:Instructions holds one record per V73 instruction or fixed instruction
group: its encoding pattern, immediate rule, register-pair rules, byte length, assembly template and manual source.
The encoder (HexagonEncoder, lowered to IL by PSLowering) reads those records; nothing below repeats them per op.

Commands: Instructions lists the ISA records; Kernels lists the kernel records; Emit manufactures a library from
-Parameters @{Kernel='Probe'; OutputDirectory='<directory>'}. Dot-sourcing retains the existing builder API.
VerifyEmission -Parameters @{BaselinePath='<baseline.csv>'; OutputDirectory='<new directory>'} checks every named
kernel in a fresh process against Recipe, Status and EmitterSHA256 baseline columns, and throws on a regression.

Encoding sources: Hexagon V73 PRM 80-N2040-53 Rev. AB (PDF SHA-256
44EBAFD1119F725BD3C6FFB87499232520DF9A0A6E3E3DC6EA329B15DAED11A8) and V73 HVX PRM 80-N2040-54 Rev. AB, with bit
patterns checked against Hexagon SDK 6.4.0.2 hexagon-llvm-mc where noted. Each instruction ends its own packet; no
duplexes, extenders or scheduling except the fixed groups listed.
#>
[CmdletBinding()]
param(
    [ValidateSet('Instructions','Kernels','Emit','VerifyEmission','EmissionParameters')][string]$Command,
    [hashtable]$Parameters=@{}
)

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
    @{ Op='mpyi';           Pattern='11101101000sssssPP0ttttt000ddddd'; Asm='r{d} = mpyi(r{s},r{t})'; Source='V73 PRM 80-N2040-53 Rev. AB, Multiply and use lower result (p. 480)' }
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
    @{ Op='pause';          Pattern='0101010001000000PP0iiiii000iii00'; Rule='Unsigned'; Min=0; Max=255; Message='Pause immediate out of range (0..255)'; Asm='pause(#{i})'; Source='LLVM test/MC/Hexagon/instructions/system_user.s: pause(#255) = 0x5440DF1C' }
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

$script:HexagonToolsRoot=Join-Path $PSScriptRoot 'tools'
# Graph models lowered by src/lower/Lower-Model.ps1. Each is PowerShell text parsed into an AST and never invoked;
# parsing the text on its own keeps the source line numbers recorded in lowered.json.
$script:KernelModels=[ordered]@{
    'Kokoro.R0Sub0'=@'
# Elementwise graph used by the R0Sub0 HVX benchmark specialization.
# Constants are explicit inputs so the backend cannot reassociate floating-point operations.
param($z, $gain, $shift, $mask, $alpha, $inverseAlpha, $one, $cubic)
$scaled = Mul $z $gain
$affine = Add $scaled $shift
$y = Mul $affine $mask
$u = Mul $y $alpha
$u2 = Mul $u $u
$cubicTerm = Mul $u2 $cubic
$polynomial = Add $one $cubicTerm
$sine = Mul $u $polynomial
$sine2 = Mul $sine $sine
$correction = Mul $sine2 $inverseAlpha
$output = Add $y $correction
'@
    'Kokoro.Affine'=@'
# AdaIN affine subgraph from generator.resblocks.3.adain1.0.
# Input is the normalized channel-first tensor. Gain already includes 1+gamma.
# Normalization, the output mask, Snake and convolution are outside this subgraph.
param($normalized, $gain, $shift)
$scaled = Mul $normalized $gain
$output = Add $scaled $shift
'@
    'Kokoro.ConvTile'=@'
# The caller supplies a channel-first tile with one sample of halo on each side.
# Existing weights are [tap,input-channel,output-channel], without repacking.
param($halo, $weight, $bias)
$dot = Conv1D $halo $weight -Kernel 3 -Stride 1 -Dilation 1
$output = Add $dot $bias
'@
}
# Kernel records retain the existing builder arguments and artifact contracts.
$script:Kernels=@(
    @{ Names=@('KokoroR0Sub0'); Build={
    $nodes=@(& (Join-Path $script:HexagonToolsRoot '..\src\lower\Lower-Model.ps1') -Model ([scriptblock]::Create($script:KernelModels['Kokoro.R0Sub0'])))
    $weights=Get-Content $WeightManifest -Raw | ConvertFrom-Json
    $weightPath=Join-Path (Split-Path $WeightManifest) 'r0_static.bin'
    if((Get-FileHash $weightPath).Hash -ne $weights.Sha256 -or (Get-Item $weightPath).Length -ne $weights.Bytes) { throw 'Existing weights fail their manifest' }
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.R0Sub0.ps1')
    $steps=@(New-KokoroR0Sub0Steps -Nodes $nodes -Frames 7681 -Channels $weights.Channels -WeightBytes $weights.Bytes -Weights $weights.Values)
    $symbol='kokoro_r0sub0_skel_handle_invoke'; $soname='libkokoro_r0sub0_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'lowered.json') ([Text.Encoding]::UTF8.GetBytes(($nodes | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroAffine','KokoroConvTile'); Build={
    $modelName=if($Kernel -eq 'KokoroAffine'){'Kokoro.Affine'}else{'Kokoro.ConvTile'}
    $nodes=@(& (Join-Path $script:HexagonToolsRoot '..\src\lower\Lower-Model.ps1') -Model ([scriptblock]::Create($script:KernelModels[$modelName])))
    $weights=Get-Content $WeightManifest -Raw | ConvertFrom-Json
    $weightPath=Join-Path (Split-Path $WeightManifest) 'r0_static.bin'
    if((Get-FileHash $weightPath).Hash -ne $weights.Sha256 -or (Get-Item $weightPath).Length -ne $weights.Bytes) { throw 'Existing weights fail their manifest' }
    if($Kernel -eq 'KokoroAffine') {
        . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.Affine.ps1')
        $steps=@(New-KokoroAdaInAffineSteps -Nodes $nodes -Channels $weights.Channels -GainOffset $weights.Values.'adain1.0.gain'.Offset -ShiftOffset $weights.Values.'adain1.0.shift'.Offset -WeightBytes $weights.Bytes)
        $symbol='kqnn_affine_skel_handle_invoke'; $soname='libkqnn_affine_skel.so'
    } else {
        if(($weights.Values.'convs1.0.weight'.Shape -join ',') -ne '1,3,128,128' -or
            ($weights.Values.'convs1.0.bias'.Shape -join ',') -ne '128') { throw 'Unexpected convolution weight layout' }
        . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.ConvTile.ps1')
        $steps=@(New-KokoroConvTileSteps -Nodes $nodes -Channels $weights.Channels -WeightOffset $weights.Values.'convs1.0.weight'.Offset -BiasOffset $weights.Values.'convs1.0.bias'.Offset -WeightBytes $weights.Bytes)
        $symbol='kokoro_conv_skel_handle_invoke'; $soname='libkokoro_conv_skel.so'
    }
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'lowered.json') ([Text.Encoding]::UTF8.GetBytes(($nodes | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroAdaIn'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AdaIn.ps1')
    $steps=@(New-KokoroAdaInSteps -Frames $AdaInFrames -Channels $AdaInChannels)
    $symbol='kokoro_adain_skel_handle_invoke'; $soname='libkokoro_adain_skel.so'
} }
    @{ Names=@('KokoroAdaInResBlock'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AdaIn.ps1')
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AdaInResBlock.ps1')
    $steps=@(New-KokoroAdaInResBlockSteps -Frames $AdaInFrames -VectorConvolution:$AdaInVectorConvolution)
    $symbol='kokoro_adain_resblock_skel_handle_invoke'; $soname='libkokoro_adain_resblock_skel.so'
} }
    @{ Names=@('KokoroAlbertSoftmax3'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AlbertSoftmax3.ps1')
    $steps=@(New-KokoroAlbertSoftmax3Steps)
    $symbol='kokoro_albert_softmax3_skel_handle_invoke'; $soname='libkokoro_albert_softmax3_skel.so'
} }
    @{ Names=@('KokoroAlbertAttention3'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AlbertAttention3.ps1')
    $steps=if ($RegionBody) { @(New-KokoroAlbertAttention3Steps -RegionBody -LabelPrefix 'encoded_context' -DomainFailureLabel 'encoding_domain') } else { @(New-KokoroAlbertAttention3Steps) }
    $symbol='kokoro_albert_attention3_skel_handle_invoke'; $soname='libkokoro_albert_attention3_skel.so'
} }
    @{ Names=@('KokoroAlbertAttentionOutput3'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AlbertAttentionOutput3.ps1')
    $steps=if ($RegionBody) { @(New-KokoroAlbertAttentionOutput3Steps -RegionBody -LabelPrefix 'encoded_output' -DomainFailureLabel 'encoding_domain') } else { @(New-KokoroAlbertAttentionOutput3Steps) }
    $symbol='kokoro_albert_attention_output3_skel_handle_invoke'; $soname='libkokoro_albert_attention_output3_skel.so'
} }
    @{ Names=@('KokoroAlbertConnectedAttention3'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AlbertConnectedAttention3.ps1')
    $steps=@(New-KokoroAlbertConnectedAttention3Steps)
    $symbol='kokoro_albert_connected_attention3_skel_handle_invoke'; $soname='libkokoro_albert_connected_attention3_skel.so'
} }
    @{ Names=@('KokoroHmxLock'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\hexagon\Kokoro.HmxLockProbe.ps1')
    $steps=@(New-KokoroHmxLockSteps)
    $symbol='kokoro_hmx_lock_skel_handle_invoke'; $soname='libkokoro_hmx_lock_skel.so'
} }
    @{ Names=@('KokoroHmxMatrix'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\hexagon\Kokoro.HmxMatrixProbe.ps1')
    $steps=@(New-KokoroHmxMatrixSteps)
    $symbol='kokoro_hmx_matrix_skel_handle_invoke'; $soname='libkokoro_hmx_matrix_skel.so'
} }
    @{ Names=@('KokoroAdaInStatistics'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AdaInStatistics.ps1')
    $steps=@(New-KokoroAdaInStatisticsSteps -Channels $IntegerChannels)
    $symbol='kokoro_adain_statistics'; $soname='libkokoro_adain_statistics.so'
} }
    @{ Names=@('KokoroAdaInIntegerCoefficients'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AdaInInteger.ps1')
    $steps=@(New-KokoroAdaInIntegerCoefficientsSteps -Channels $IntegerChannels)
    $symbol='kokoro_adain_integer_coefficients'; $soname='libkokoro_adain_integer_coefficients.so'
} }
    @{ Names=@('KokoroAdaInIntegerAffine'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AdaInInteger.ps1')
    $steps=@(New-KokoroAdaInIntegerAffineSteps -Channels $IntegerChannels)
    $symbol='kokoro_adain_integer_affine'; $soname='libkokoro_adain_integer_affine.so'
} }
    @{ Names=@('KokoroAdaInSnakeInteger'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AdaInSnakeInteger.ps1')
    $steps=@(New-KokoroAdaInSnakeIntegerSteps)
    $symbol='kokoro_adain_snake_integer'; $soname='libkokoro_adain_snake_integer.so'
} }
    @{ Names=@('KokoroAdaInSnakeTurns'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.AdaInSnakeTurns.ps1')
    $steps=@(New-KokoroAdaInSnakeTurnsSteps)
    $symbol='kokoro_adain_snake_turns'; $soname='libkokoro_adain_snake_turns.so'
} }
    @{ Names=@('KokoroSnakeInteger'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.SnakeInteger.ps1')
    $steps=@(New-KokoroSnakeIntegerSteps -Channels $IntegerChannels)
    $symbol='kokoro_snake_integer'; $soname='libkokoro_snake_integer.so'
} }
    @{ Names=@('KokoroResidualInteger'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.ResidualInteger.ps1')
    $steps=@(New-KokoroResidualIntegerSteps -Channels $IntegerChannels)
    $symbol='kokoro_residual_integer'; $soname='libkokoro_residual_integer.so'
} }
    @{ Names=@('KokoroHmxConv'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.HmxConv.ps1')
    $steps=@(New-KokoroHmxConvSteps -InputChannels $ConvChannels -OutputChannels $ConvChannels -Kernel $ConvKernel -Dilation $ConvDilation -OutputPlanes:$ConvOutputPlanes)
    $symbol='kokoro_hmx_conv'; $soname='libkokoro_hmx_conv.so'
} }
    @{ Names=@('KokoroLeakyReluInteger'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.LeakyReluInteger.ps1')
    $steps=@(New-KokoroLeakyReluIntegerSteps -Channels $IntegerChannels)
    $symbol='kokoro_leaky_relu_integer'; $soname='libkokoro_leaky_relu_integer.so'
} }
    @{ Names=@('KokoroBranchAverageInteger'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.BranchAverageInteger.ps1')
    $steps=@(New-KokoroBranchAverageIntegerSteps -Channels $IntegerChannels)
    $symbol='kokoro_branch_average_integer'; $soname='libkokoro_branch_average_integer.so'
} }
    @{ Names=@('KokoroGenerator60xRun'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60xRun.ps1')
    $run=New-KokoroGenerator60xRunSteps -Frames $ResBlockFrames -ProfileBreakdown:$ProfileBreakdown -BypassAdaInCoefficients:$BypassAdaInCoefficients -BypassStatisticsAndCoefficients:$BypassStatisticsAndCoefficients -BypassHmxCompute:$BypassHmxCompute
    $steps=@($run.Steps)
    $symbol='kokoro_resblock_run_skel_handle_invoke'; $soname='libkokoro_resblock_run_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroGeneratorTailRun'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.GeneratorTailRun.ps1')
    $run=New-KokoroGeneratorTailRunSteps -Frames $ResBlockFrames
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroGeneratorStage16TailRun'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Tail
    $steps=@($run.Steps)
    # The tail harness (src/runspace/KokoroGeneratorTailProbe.ps1) loads this name and plays the PCM.
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroResBlock16Run'); Build={
    # One or more 16-bit resblocks without the tail, under the generic tail harness (completion word 1 for one block).
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
        $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Kernels $Stage16Kernels -Channels $Stage16Channels -GenericHarness -StopAfterStage $Stage16StopAfter -DumpPoint $Stage16DumpPoint -RuntimeFrames:$GeneratorRuntimeFrames
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroGeneratorFrontStageTailRun'); Build={
    # The 128-channel front, the 16-bit stage and the tail in one job (tail harness plays the PCM).
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Front -Tail
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroGeneratorWholeSource16Run'); Build={
    # The whole generator with the harmonic source: decoder output, f0 and z to PCM (tail harness plays the PCM) under the generic tail harness (completion word 1).
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $pmu=if($ResidentPmuEvents){@{PmuEvents=$ResidentPmuEvents}}else{@{}}
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Whole -Source -AdaInMode $GeneratorMoments @pmu -SeededNoise:$SourceSeededNoise
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    # The existing generator consumes the decoder tensor through the typed layout.
} }
    @{ Names=@('KokoroDecoderGenerator16Run'); Build={
    # The decoder then the whole generator with the harmonic source: asr, F0_curve, N_curve, f0 and z to PCM, one DSP job.
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $pmu=if($ResidentPmuEvents){@{PmuEvents=$ResidentPmuEvents}}else{@{}}
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Whole -Source -Decoder -AdaInMode $GeneratorMoments -DecoderMoments $DecoderMoments @pmu
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    # Layout and link state remain part of the typed artifact.
} }
    @{ Names=@('KokoroHarmonicSource16Run'); Build={
    # The harmonic source and STFT (f0 -> har planes, signal copy) under the generic tail harness (completion word 1).
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.HarmonicSource16Run.ps1')
    $run=New-KokoroHarmonicSource16RunSteps -Frames $ResBlockFrames -SeededNoise:$SourceSeededNoise
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    # Layout and link state are returned with the emitted artifact, without JSON interchange.
} }
    @{ Names=@('KokoroHarmonicStft16Run'); Build={
    # The harmonic-source STFT (merged source -> har planes) under the generic tail harness (completion word 1).
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.HarmonicStft16Run.ps1')
    $run=New-KokoroHarmonicStft16RunSteps -Frames $ResBlockFrames
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroGeneratorWhole16Run'); Build={
    # The whole generator in one job: decoder output and har to PCM (tail harness plays the PCM).
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Whole
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroGeneratorFront10x16Run'); Build={
    # The 256-channel front and resblocks.0-2 with their mean, under the generic tail harness.
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Channels 256 -Front -GenericHarness
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroDecoder16Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.DecoderRun16.ps1')
    $run=New-KokoroDecoder16RunSteps -Frames $DecoderFrames -StopAfterBlock $DecoderStopAfterBlock -DumpPoint $DecoderDumpPoint -RuntimeFrames:$DecoderRuntimeFrames -Moments $DecoderMoments
    $steps=@($run.Steps)
    # The phone harness (tools/Invoke-GeneratorTailProbe.ps1) runs every generator job under the tail skel's name.
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    # Decoder layouts travel with the typed emission artifact.
} }
    @{ Names=@('KokoroAlbertLinear16Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Albert16Run.ps1')
    $run=New-KokoroAlbertLinear16RunSteps -InputChannels $AlbertInputChannels -OutputChannels $AlbertOutputChannels -Tokens $AlbertTokens
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroAlbertLayerNorm16Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Albert16Run.ps1')
    $run=New-KokoroAlbertLayerNorm16RunSteps -Channels $AlbertInputChannels -Tokens $AlbertTokens
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroAlbertGelu16Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Albert16Run.ps1')
    $run=New-KokoroAlbertGelu16RunSteps -Channels $AlbertInputChannels -Tokens $AlbertTokens
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroAlbertAttention16Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Albert16Run.ps1')
    $run=New-KokoroAlbertAttention16RunSteps -Tokens $AlbertTokens
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroAlbertEmbed16Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Albert16Run.ps1')
    $run=New-KokoroAlbertEmbed16RunSteps -Tokens $AlbertTokens
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroAlbert16Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Albert16Run.ps1')
    $run=New-KokoroAlbert16RunSteps -Tokens $AlbertTokens -StopAfter $AlbertStopAfter
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroGeneratorTail16Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.GeneratorTail16Run.ps1')
    $run=New-KokoroGeneratorTail16RunSteps -Frames $ResBlockFrames -DumpLogits:$TailDumpLogits
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroGenerator60x16Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $pmu=if($ResidentPmuEvents){@{PmuEvents=$ResidentPmuEvents}}else{@{}}
    # A schedule or AdaIN mode other than the defaults runs under the phone harness (tools/Invoke-GeneratorTailProbe.ps1):
    # its completion word and the tail skel's name. The defaults emit exactly as before.
    $phoneHarness=$GeneratorSchedule -ne 'Layer' -or $GeneratorMoments -ne 'Accumulate'
    $harness=if($phoneHarness){@{AdaInMode=$GeneratorMoments;Schedule=$GeneratorSchedule;GenericHarness=$true}}else{@{}}
            if($GeneratorMatrixThread){ $harness.MatrixThread=$GeneratorMatrixThread; $harness.MatrixLock=$GeneratorMatrixLock }
            if($GeneratorWeightPlanes -ne 2){ $harness.WeightPlanes=$GeneratorWeightPlanes }
            if($GeneratorControllerContact){ $harness.ControllerContact=$true }
        $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -StopAfterStage $Stage16StopAfter -DumpPoint $Stage16DumpPoint -Kernels $Stage16Kernels -RuntimeFrames:$GeneratorRuntimeFrames @pmu @harness
    $steps=@($run.Steps)
    $symbol='kokoro_resblock_run_skel_handle_invoke'; $soname='libkokoro_resblock_run_skel.so'
    if($phoneHarness){ $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so' }
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroGenerator60xResidentRun'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.Generator60xResidentRun.ps1')
    $pmu=if($ResidentPmuEvents){@{PmuEvents=$ResidentPmuEvents}}else{@{}}
    $run=New-KokoroGenerator60xResidentRunSteps -Frames $ResBlockFrames -CostProbePasses $ResidentCostProbePasses -CostProbeTurnsBody:$ResidentCostProbeTurnsBody -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -CompactOutput:$ResidentCompactOutput @pmu
    $steps=@($run.Steps)
    $symbol='kokoro_resblock_run_skel_handle_invoke'; $soname='libkokoro_resblock_run_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroResBlockRun'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.ResBlockRun.ps1')
    $run=New-KokoroResBlockRunSteps -Frames $ResBlockFrames -Kernel $ResBlockKernel
    $steps=@($run.Steps)
    $symbol='kokoro_resblock_run_skel_handle_invoke'; $soname='libkokoro_resblock_run_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json))) -AllowOverwrite:$Force
} }
    @{ Names=@('KokoroHmxConvPlanes'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.HmxConvPlanes.ps1')
    # Plane stride for the simulator harness: 3 output tiles of ConvChannels/32 blocks.
    $steps=@(New-KokoroHmxConvPlanesSteps -InputChannels $ConvChannels -OutputChannels $ConvChannels -Kernel $ConvKernel -Dilation $ConvDilation -WeightPlanes $ConvWeightPlanes -PlaneStride (3*($ConvChannels/32)*2048))
    $symbol='kokoro_hmx_conv_planes'; $soname='libkokoro_hmx_conv_planes.so'
} }
    @{ Names=@('KokoroHmxConvPlanesLoop'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.HmxConvPlanes.ps1')
    # Plane stride for the simulator harness: 3 output tiles of ConvOutputChannels/32 blocks.
    $steps=@(New-KokoroHmxConvPlanesLoopSteps -InputChannels $ConvInputChannels -OutputChannels $ConvOutputChannels -Kernel $ConvKernel -Dilation $ConvDilation -WeightPlanes $ConvWeightPlanes -PlaneStride (3*($ConvOutputChannels/32)*2048))
    $symbol='kokoro_hmx_conv_planes_loop'; $soname='libkokoro_hmx_conv_planes_loop.so'
} }
    @{ Names=@('KokoroPlaneCombine'); Build={
    . (Join-Path $script:HexagonToolsRoot '..' 'src' 'kernels' 'Kokoro.PlaneCombine.ps1')
    $steps=@(New-KokoroPlaneCombineSteps -Mode $CombineMode -Channels $ConvChannels -Groups $CombineGroups -PlaneStride (3*($ConvChannels/32)*2048))
    $symbol='kokoro_plane_combine'; $soname='libkokoro_plane_combine.so'
} }
    @{ Names=@('KokoroPlaneCombineLoop'); Build={
    . (Join-Path $script:HexagonToolsRoot '..' 'src' 'kernels' 'Kokoro.PlaneCombine.ps1')
    $steps=@(New-KokoroPlaneCombineLoopSteps -Mode $CombineMode -Channels $ConvOutputChannels -PlaneStride (3*($ConvOutputChannels/32)*2048) -OutputTileSkip $CombineOutputTileSkip)
    $symbol='kokoro_plane_combine_loop'; $soname='libkokoro_plane_combine_loop.so'
} }
    @{ Names=@('KokoroAdaInMoments16Loop'); Build={
    . (Join-Path $script:HexagonToolsRoot '..' 'src' 'kernels' 'Kokoro.AdaInMoments16.ps1')
    $steps=@(New-KokoroAdaInMoments16LoopSteps -Channels $ConvInputChannels)
    $symbol='kokoro_adain_moments16_loop'; $soname='libkokoro_adain_moments16_loop.so'
} }
    @{ Names=@('KokoroAdaInMoments16'); Build={
    . (Join-Path $script:HexagonToolsRoot '..' 'src' 'kernels' 'Kokoro.AdaInMoments16.ps1')
    $steps=@(New-KokoroAdaInMoments16Steps -Channels $ConvChannels)
    $symbol='kokoro_adain_moments16'; $soname='libkokoro_adain_moments16.so'
} }
    @{ Names=@('KokoroAdaInAffineCoefficientsLoop'); Build={
    . (Join-Path $script:HexagonToolsRoot '..' 'src' 'kernels' 'Kokoro.AdaInTurnsCoefficients.ps1')
    $steps=@(New-KokoroAdaInAffineCoefficientsLoopSteps -Channels $ConvInputChannels)
    $symbol='kokoro_adain_affine_coefficients_loop'; $soname='libkokoro_adain_affine_coefficients_loop.so'
} }
    @{ Names=@('KokoroDecoderPass'); Build={
    . (Join-Path $script:HexagonToolsRoot '..' 'src' 'kernels' 'Kokoro.Decoder16.ps1')
    $steps=@(switch($DecoderPass){
        'PadRows16' { New-KokoroPadRows16Steps -Frames $DecoderFrames -Channels $ConvInputChannels -Halfword $DecoderHalfword }
        'LowWindow16' { New-KokoroLowWindow16Steps }
        'FrameDouble16' { New-KokoroFrameDouble16Steps -Channels $ConvInputChannels }
        'Pool2' { New-KokoroPool2Steps -Channels $ConvInputChannels }
        'StrideConv16' { New-KokoroStrideConv16Steps -Frames $DecoderFrames -Channels $ConvInputChannels -Channel $DecoderChannel }
        'ScaleConvert16' { New-KokoroScaleConvert16Steps -Channels $ConvInputChannels } })
    $symbol='kokoro_decoder_pass'; $soname='libkokoro_decoder_pass.so'
} }
    @{ Names=@('KokoroAdaInLeaky16'); Build={
    . (Join-Path $script:HexagonToolsRoot '..' 'src' 'kernels' 'Kokoro.AdaInLeaky16.ps1')
    $steps=@(New-KokoroAdaInLeaky16Steps -Channels $ConvInputChannels -Output $LeakyOutput -Identity:$LeakyIdentity)
    $symbol='kokoro_adain_leaky16'; $soname='libkokoro_adain_leaky16.so'
} }
    @{ Names=@('KokoroAdaInTurnsCoefficients'); Build={
    . (Join-Path $script:HexagonToolsRoot '..' 'src' 'kernels' 'Kokoro.AdaInTurnsCoefficients.ps1')
    $steps=@(New-KokoroAdaInTurnsCoefficientsSteps -Channels $ConvChannels)
    $symbol='kokoro_adain_turns_coefficients'; $soname='libkokoro_adain_turns_coefficients.so'
} }
    @{ Names=@('KokoroGeneratorTemplate1Run'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.GeneratorTemplate1Run.ps1')
    $run=New-KokoroGeneratorTemplate1RunSteps -Channels $ConvChannels -InputChannels $TemplateInputChannels -Upsample:$TemplateUpsample -ConnectedMain:$TemplateConnectedMain -Profile:$TemplateProfile -Kernel $ConvKernel -Dilation $ConvDilation -Tiles $ConvTiles -Branches $TemplateBranches -AddResidual:$TemplateAddResidual -StoreResidual:$TemplateStoreResidual -Shape $TemplateShape -BlockFrames $TemplateBlockFrames -InitialFrameOffset $TemplateInitialFrameOffset
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
} }
    @{ Names=@('KokoroHmxConvRun'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\jobs\Kokoro.HmxConvRun.ps1')
    $run=New-KokoroHmxConvRunSteps -Channels $ConvChannels -Kernel $ConvKernel -Dilation $ConvDilation -Tiles $ConvTiles
    $steps=@($run.Steps)
    $symbol='kokoro_hmx_conv_run_skel_handle_invoke'; $soname='libkokoro_hmx_conv_run_skel.so'
} }
    @{ Names=@('Definition'); Build={
    if($null -eq $Definition -or $null -eq $Definition.Steps){throw 'Definition requires a kernel record with Steps.'}
    $steps=@($Definition.Steps)
    $symbol=$Definition.Symbol; $soname=$Definition.Soname
} }
    @{ Names=@('KokoroDmaCopy'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\hexagon\Kokoro.DmaCopy.ps1')
    $steps=@(New-KokoroDmaCopySteps)
    $symbol='kokoro_dma_copy'; $soname='libkokoro_dma_copy.so'
} }
    @{ Names=@('KokoroDmaBench'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\hexagon\Kokoro.DmaBenchProbe.ps1')
    $steps=@(New-KokoroDmaBenchSteps)
    $symbol='kokoro_dma_bench_skel_handle_invoke'; $soname='libkokoro_dma_bench_skel.so'
} }
    @{ Names=@('KokoroVtcmQuery'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\hexagon\Kokoro.VtcmQueryProbe.ps1')
    $steps=@(New-KokoroVtcmQuerySteps)
    $symbol='kokoro_vtcm_query_skel_handle_invoke'; $soname='libkokoro_vtcm_query_skel.so'
} }
    @{ Names=@('KokoroLinearTile'); Build={
    . (Join-Path $script:HexagonToolsRoot '..\src\kernels\Kokoro.LinearTile.ps1')
    $steps=@(New-KokoroLinearTileSteps -Rows $LinearRows `
        -InputChannels $LinearInputChannels -OutputChannels $LinearOutputChannels `
        -VectorOutputTiles:$LinearVectorOutputTiles)
    $symbol='kokoro_linear_skel_handle_invoke'; $soname='libkokoro_linear_skel.so'
} }
    @{ Names=@('Probe'); Build={
    $steps=@(New-HexagonProbeSteps)
    $symbol='kqnn_emit_skel_handle_invoke'; $soname='libkqnn_emit_skel.so'
} }
)
$script:KernelByName=@{}
foreach($record in $script:Kernels){
    foreach($name in $record.Names){
        if($script:KernelByName.ContainsKey($name)){throw "Duplicate kernel record: $name"}
        $script:KernelByName[$name]=$record
    }
}
function Invoke-HexagonEmission {
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $script:HexagonToolsRoot '..\build\hexagon-emission\emitted'),
    [string] $Kernel='Probe',
    # Definition: a kernel record with Steps, Symbol and Soname, built outside this script; no per-kernel branch needed here.
    [object] $Definition,
    # KokoroAlbertLinear16Run / KokoroAlbertLayerNorm16Run / KokoroAlbertGelu16Run / KokoroAlbertAttention16Run / KokoroAlbertEmbed16Run / KokoroAlbert16Run (src/jobs/Kokoro.Albert16Run.ps1); LayerNorm and GELU channels = AlbertInputChannels.
    [ValidateRange(32, 2048)][int] $AlbertInputChannels = 768,
    [ValidateRange(64, 2048)][int] $AlbertOutputChannels = 768,
    [ValidateRange(1, 512)][int] $AlbertTokens = 16,
    # KokoroAlbert16Run diagnosis: end after this operator (src/jobs/Kokoro.Albert16Run.ps1 -StopAfter).
    [string] $AlbertStopAfter = '',
    [ValidateRange(2, 32768)][int] $ResBlockFrames = 7801,
    [ValidateSet(3,7,11)][int] $ResBlockKernel = 3,
    [ValidateSet(128,256)][int] $IntegerChannels = 128,
    [ValidateRange(1, 64)][int] $ConvTiles = 8,
    [ValidateSet(128, 256)][int] $ConvChannels = 128,
    [ValidateSet(1, 3, 7, 11)][int] $ConvKernel = 3,
    # KokoroHmxConvPlanesLoop: decoder shapes.
    [ValidateRange(32, 2048)][int] $ConvInputChannels = 1120,
    [ValidateRange(64, 2048)][int] $ConvOutputChannels = 1024,
    [ValidateSet('Windows','Tensor')][string] $LeakyOutput = 'Windows',
    [switch] $LeakyIdentity,
    # KokoroDecoderPass: one pass of src/kernels/Kokoro.Decoder16.ps1.
    [ValidateSet('PadRows16','LowWindow16','FrameDouble16','Pool2','StrideConv16','ScaleConvert16')][string] $DecoderPass = 'PadRows16',
    [ValidateRange(1, 1048576)][int] $DecoderFrames = 65,
    [ValidateSet(0, 0x8000)][int] $DecoderHalfword = 0x8000,
    [ValidateRange(0, 2047)][int] $DecoderChannel = 1088,
    [ValidateRange(0, 1048576)][long] $CombineOutputTileSkip = 0,
    [ValidateRange(-1, 4)][int] $DecoderStopAfterBlock = -1,
    [ValidateSet('Block','Shortcut','Conv1','Windows1','Pool','Coeff')][string] $DecoderDumpPoint = 'Block',
    # KokoroDecoder16Run: read the frame count at run time (DecoderFrames is the capacity).
    [switch] $DecoderRuntimeFrames,
    # Residual generator stages: ResBlockFrames is capacity; live frames follow the input tensor.
    [switch] $GeneratorRuntimeFrames,
    # KokoroDecoder16Run AdaIN statistics: Accumulate, Export (records and coefficients after the output), Supplied (records
    # from the input) or Corrected (coefficient deltas from the input added to the accumulated coefficients).
    [ValidateSet('Accumulate','Export','Supplied','SuppliedExport','Corrected','Direct','Constants')][string] $DecoderMoments = 'Accumulate',
    [ValidateSet('Accumulate','Export','Constants')][string] $GeneratorMoments = 'Accumulate',
    # KokoroGenerator60x16Run: Layer (each stage over every tile) or Tile (depth-first, resident weights; see -Schedule in
    # src/jobs/Kokoro.Generator60x16Run.ps1).
    [ValidateSet('Layer','Tile')][string] $GeneratorSchedule = 'Layer',
    # KokoroGenerator60x16Run tile schedule: 0 runs the convolutions on the main thread, which holds the matrix unit;
    # 1 to 3 run them on that HVX worker, which never takes the matrix lock.
    [ValidateRange(0, 3)][int] $GeneratorMatrixThread = 0,
    # With GeneratorMatrixThread: Main keeps the matrix lock on the main thread; Worker hands it to that worker for the
    # job; Convolution has that worker take and release it around every convolution.
    [ValidateSet('Main','Worker','Convolution')][string] $GeneratorMatrixLock = 'Main',
    # KokoroGenerator60x16Run tile schedule: 1 keeps one resident int8 weight plane per stage (the high bytes).
    [ValidateSet(1, 2)][int] $GeneratorWeightPlanes = 2,
    # KokoroGenerator60x16Run tile schedule: per-tile AdaIN from the controller contact (K = K_base + P_K * v, M likewise).
    [switch] $GeneratorControllerContact,
    # KokoroHarmonicSource16Run: generate the source noise on the DSP from a seed (input holds seed and scale) instead of
    # reading captured draws.
    [switch] $SourceSeededNoise,
    [ValidateSet(1, 3, 5)][int] $ConvDilation = 1,
    [ValidateSet(1,3)][int] $TemplateBranches = 1,
    [switch] $TemplateAddResidual,
    [switch] $TemplateStoreResidual,
    [switch] $TemplateUpsample,
    [switch] $TemplateConnectedMain,
    [switch] $TemplateProfile,
    [ValidateSet('Lock','Smoothstep')][string] $TemplateShape = 'Lock',
    [ValidateSet(0,128,256,512)][int] $TemplateInputChannels = 0,
    [ValidateRange(16,64)][int] $TemplateBlockFrames = 16,
    [ValidateRange(0,63)][int] $TemplateInitialFrameOffset = 0,
    [switch] $ConvOutputPlanes,
    [ValidateSet(1,2)][int] $ConvWeightPlanes = 1,
    [ValidateSet('Conv','Residual','Scale')][string] $CombineMode = 'Conv',
    [ValidateSet(2,3)][int] $CombineGroups = 2,
    [ValidateRange(0,3)][int] $ResidentCostProbePasses = 0,
    [switch] $ResidentCostProbeTurnsBody,
    [ValidateCount(8,8)][ValidateRange(0,1023)][int[]] $ResidentPmuEvents,
    [ValidateRange(1,4)][int] $ResidentHvxThreads = 4,
    [ValidateRange(1,64)][int] $ResidentBatchTiles = 22,
    [switch] $ResidentCompactOutput,
    [ValidateRange(-1,17)][int] $Stage16StopAfter = -1,
    [switch] $TailDumpLogits,
    [ValidateCount(1,3)][int[]] $Stage16Kernels = @(3,7,11),
    [ValidateSet(128,256)][int] $Stage16Channels = 128,
    [ValidateSet('Stage','Windows','Planes')][string] $Stage16DumpPoint = 'Stage',
    [ValidateRange(2, 2048)][int] $AdaInFrames = 64,
    [ValidateRange(1, 128)][int] $AdaInChannels = 128,
    [switch] $AdaInVectorConvolution,
    [ValidateRange(1, 512)][int] $LinearRows = 3,
    [ValidateRange(1, 4096)][int] $LinearInputChannels = 768,
    [ValidateRange(1, 4096)][int] $LinearOutputChannels = 512,
    [switch] $LinearVectorOutputTiles,
    [switch] $RegionBody,
    [string] $WeightManifest = (Join-Path $script:HexagonToolsRoot '..\build\emit\r0\r0_static.json'),
    [switch] $ProfileBreakdown,
    [switch] $BypassAdaInCoefficients,
    [switch] $BypassStatisticsAndCoefficients,
    [switch] $BypassHmxCompute,
    [switch] $ResidentPayloads,
    [switch] $ReferenceAssembly,
    [switch] $Force
)
if(-not $script:KernelByName.ContainsKey($Kernel)){throw "Unknown Hexagon kernel: $Kernel"}
$ErrorActionPreference = 'Stop'
$emissionClock = [Diagnostics.Stopwatch]::StartNew()
if ($RegionBody -and $Kernel -notin @('KokoroAlbertAttention3','KokoroAlbertAttentionOutput3')) {
    throw 'Region-body encoding is supported only for the ALBERT attention regions.'
}
# Host-only. The pinned ELF writer uses .NET APIs requiring FullLanguage.
# Fetch source from an immutable upstream GitHub revision; never use or write
# the protected local Pwsh checkout. No model text is executed by this adapter.
$script:PwshBaseUrl = 'https://raw.githubusercontent.com/MansfieldPlumbing/Pwsh/e215a963295eda290599840366b51cbd99bb6d57/'
$protectedRoot = [IO.Path]::GetFullPath((Join-Path $script:HexagonToolsRoot '../../Pwsh')).TrimEnd([IO.Path]::DirectorySeparatorChar)
$outputFullPath = [IO.Path]::GetFullPath($OutputDirectory)
if ($outputFullPath.Equals($protectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $outputFullPath.StartsWith($protectedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must not be inside the protected Pwsh checkout.'
}
$OutputDirectory = $outputFullPath
function Get-PinnedUpstreamText {
    param(
        [Parameter(Mandatory)][ValidatePattern('^(setup\.ps1|lib/[A-Za-z0-9._-]+)$')][string] $Path,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string] $Sha256
    )
    $cacheDirectory = Join-Path $script:HexagonToolsRoot '../build/upstream-text'
    $cachePath = Join-Path $cacheDirectory $Sha256.ToUpperInvariant()
    $cached = [IO.File]::Exists($cachePath)
    if ($cached) {
        $bytes = [IO.File]::ReadAllBytes($cachePath)
    } else {
        $response = Invoke-WebRequest -Uri ($script:PwshBaseUrl + $Path) -UseBasicParsing
        $bytes = $response.RawContentStream.ToArray()
    }
    $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if ($actual -cne $Sha256) { throw "Pinned upstream source hash mismatch: $Path" }
    if (-not $cached) {
        [void][IO.Directory]::CreateDirectory($cacheDirectory)
        [IO.File]::WriteAllBytes($cachePath, $bytes)
    }
    [Text.Encoding]::UTF8.GetString($bytes)
}
$setupText = Get-PinnedUpstreamText 'setup.ps1' '44432CB738EDB13FB7B2AEA999C265A94F5EEAC867DC4E4E39C1503E0E813D62'
$manifestText = Get-PinnedUpstreamText 'lib/manifest.json' 'C2B3C6D044EACBACAD7E7B1C58F18EA8AE6FB836B421B5EC3788D009E57CEDC4'
$script:PwshSources = ($manifestText | ConvertFrom-Json).sources
function Import-LibSourceText {
    param([string] $Path)
    $record = @($script:PwshSources | Where-Object path -CEQ $Path)
    if ($record.Count -ne 1) { throw "Missing source pin: $Path" }
    Get-PinnedUpstreamText "lib/$Path" ([string]$record[0].sha256)
}
function Write-NewOrIdenticalFile {
    param([string] $Path, [byte[]] $Bytes, [switch] $AllowOverwrite)
    if ([IO.File]::Exists($Path)) {
        if (-not $AllowOverwrite -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))) -ne
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))) { throw "Output exists with different bytes: $Path. Choose a new output directory." }
        [IO.File]::WriteAllBytes($Path,$Bytes)
    } else { [IO.File]::WriteAllBytes($Path,$Bytes) }
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($setupText,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Pinned writer does not parse' }
$names=@('Get-ElfConstants','Get-ElfHashTableBytes','Get-ElfLayout','Get-ElfHeaderFlags',
    'Get-ElfRelocationEntrySize','Get-ElfRelocationTags','Get-AlignedOffset','Set-ElfField',
    'New-ElfStringTable','Write-ElfHeader','Write-ElfProgramHeader','Write-ElfSymbol',
    'Write-ElfDynamicTable','Write-ElfRelocation','Add-ElfSectionTable','New-ElfCodeLibrary')
$definitions=foreach($name in $names) {
    $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false))
    if($nodes.Count -ne 1) { throw "Writer function not unique: $name" }
    $source=$nodes[0].Extent.Text
    if($name -eq 'New-ElfCodeLibrary') {
        # Permit zero imports, reserve the ABI-mandatory DT_HEXAGON_VER=3 entry
        # (SDK 19.0.04 ABI guide), and retain lengths from the layout pass.
        $edits=@(
            @('[Parameter(Mandatory)][string[]] $Needed','[AllowEmptyCollection()][string[]] $Needed'),
            @('$L.Dynamic * (11 + $Needed.Count)','$L.Dynamic * (12 + $Needed.Count)'),
            @('@($elf[''DT_NULL''], 0)))','@($elf[''DT_HEXAGON_VER''], 3), @($elf[''DT_NULL''], 0)))'),
            @('$functionSize = @{}', '$functionSize = @{}; $functionLengths = @{}'),
            @('$size = 0', '$size = 0; $lengths = [Collections.Generic.List[int]]::new(); $functionLengths[$name] = $lengths'),
            @('$pc = [long]$functionOffset[$name]', '$pc = [long]$functionOffset[$name]; $lengthIndex = 0; $lengths = $functionLengths[$name]'),
            @('$length = & $isa.Length -Step $step', '$length = $lengths[$lengthIndex]; $lengthIndex++'),
            @('$size += & $isa.Length -Step $step', '$length = & $isa.Length -Step $step; $lengths.Add($length); $size += $length'),
            @('Functions = $Functions', 'Functions = $Functions; CodeSizes = $functionSize; StepLengths = $functionLengths')
        )
        foreach($edit in $edits) {
            if(([regex]::Matches($source,[regex]::Escape($edit[0]))).Count -ne 1) { throw 'Writer adaptation anchor mismatch' }
            $source=$source.Replace($edit[0],$edit[1])
        }
        # Replace the three upstream step walks with calls to the typed,
        # PowerShell-authored managed encoder. Metadata remains in the writer.
        $writerAst = [Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        $loops = @($writerAst.FindAll({ param($n) $n -is [Management.Automation.Language.ForEachStatementAst] },$true))
        $importsLoop = @($loops | Where-Object { $_.Condition.Extent.Text -eq '$Functions.PSBase.Keys' -and $_.Body.Extent.Text.Contains('$step[''Import'']') })
        $layoutLoop = @($loops | Where-Object { $_.Condition.Extent.Text -eq '$exports' -and $_.Body.Extent.Text.Contains('$size = 0;') })
        $encodeLoop = @($loops | Where-Object { $_.Condition.Extent.Text -eq '$exports' -and $_.Body.Extent.Text.Contains('$isa.Encode') })
        if ($importsLoop.Count -ne 1 -or $layoutLoop.Count -ne 1 -or $encodeLoop.Count -ne 1) { throw 'Typed writer loop anchors are not unique.' }
        $importsBody = @'
$layouts = @{}
    $layoutClock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($name in $Functions.PSBase.Keys) {
        $layout = $script:HexagonEncoder.Layout($Functions[$name], 0L)
        $layouts[$name] = $layout
        foreach ($import in $layout.Imports) { if (-not $imports.Contains($import)) { $imports.Add($import) } }
    }
    $layoutSeconds = $layoutClock.Elapsed.TotalSeconds
'@
        $layoutBody = @'
foreach ($name in $exports) {
        $functionOffset[$name] = $cursor
        $layout = $layouts[$name]
        $script:HexagonEncoderType::Relocate($layout, [long]$cursor)
        $labels[$name] = $layout.Labels
        $functionLengths[$name] = $layout.Lengths
        $functionSize[$name] = $layout.Size
        $cursor += $layout.Size
    }
'@
        $encodeBody = @'
$typedGot = [Collections.Generic.Dictionary[string,long]]::new([StringComparer]::InvariantCultureIgnoreCase)
    foreach ($key in $gotSlot.Keys) { $typedGot.Add([string]$key, [long]$gotSlot[$key]) }
    $typedData = [Collections.Generic.Dictionary[string,long]]::new([StringComparer]::InvariantCultureIgnoreCase)
    foreach ($key in $address.Keys) { $typedData.Add([string]$key, [long]$address[$key]) }
    $encodeClock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($name in $exports) {
        $bytes = $script:HexagonEncoder.Encode($Functions[$name], $layouts[$name], [long]$functionOffset[$name], $typedGot, $typedData)
        [Array]::Copy($bytes, 0, $image, [int]$functionOffset[$name], $bytes.Length)
    }
    $encodeSeconds = $encodeClock.Elapsed.TotalSeconds
'@
        $source = $source.Replace($importsLoop[0].Extent.Text, $importsBody)
        $source = $source.Replace($layoutLoop[0].Extent.Text, $layoutBody)
        $source = $source.Replace($encodeLoop[0].Extent.Text, $encodeBody)
        $source = $source.Replace('StepLengths = $functionLengths', 'StepLengths = $functionLengths; LayoutSeconds = $layoutSeconds; EncodeSeconds = $encodeSeconds')
    }
    $source
}
$adapter=Join-Path $OutputDirectory 'Pwsh.ElfWriter.ps1'
$text=$definitions -join "`n`n"
$null=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count) { throw 'Writer adapter does not parse' }
Write-NewOrIdenticalFile $adapter ([Text.Encoding]::UTF8.GetBytes($text)) -AllowOverwrite:$Force
. $adapter

# The compiler is a pinned, self-contained PowerShell source file. A verified
# sibling checkout can supply an unpublished local revision; otherwise fetch
# the immutable revision. Neither path executes an unverified working copy.
$loweringCommit = '8880e5e51c65babbf83d8d059c2316c2e4c11858'
$loweringHash = '6CF1537E3FDAC9F6073655F042FABCFB20A95468F929F59C5BBC5901DF62A00F'
$loweringCache = Join-Path $script:HexagonToolsRoot "../build/lowered-hexagon/compiler/$loweringHash/Export-LoweredAssembly.ps1"
if ([IO.File]::Exists($loweringCache)) { $loweringBytes = [IO.File]::ReadAllBytes($loweringCache) }
else {
    $siblingCompiler = Join-Path $script:HexagonToolsRoot '../../PSLowering/Export-LoweredAssembly.ps1'
    if ([IO.File]::Exists($siblingCompiler) -and (Get-FileHash $siblingCompiler).Hash -ceq $loweringHash) {
        $loweringBytes = [IO.File]::ReadAllBytes($siblingCompiler)
    } else {
        $loweringBytes = (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/MansfieldPlumbing/PSLowering/$loweringCommit/Export-LoweredAssembly.ps1" -UseBasicParsing).RawContentStream.ToArray()
    }
}
if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($loweringBytes)) -cne $loweringHash) { throw 'Pinned PSLowering compiler hash mismatch.' }
if (-not [IO.File]::Exists($loweringCache)) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($loweringCache))
    [IO.File]::WriteAllBytes($loweringCache, $loweringBytes)
}
$encoderSource = Join-Path $script:HexagonToolsRoot '../Invoke-HexagonDevelopment.ps1'
$encoderHash = (Get-FileHash $encoderSource).Hash
$encoderDirectory = Join-Path $script:HexagonToolsRoot "../build/lowered-hexagon/$loweringCommit/$encoderHash"
$encoderPath = Join-Path $encoderDirectory 'HexagonEncoder.dll'
$encoderReceipt = $encoderPath + '.sha256'
if (-not [IO.File]::Exists($encoderPath) -or -not [IO.File]::Exists($encoderReceipt)) {
    [void][IO.Directory]::CreateDirectory($encoderDirectory)
    & $loweringCache -SourcePath $encoderSource -ClassName HexagonEncoder -OutputPath $encoderPath -Deterministic | Out-Null
    [IO.File]::WriteAllText($encoderReceipt, (Get-FileHash $encoderPath).Hash)
}
if ((Get-FileHash $encoderPath).Hash -cne [IO.File]::ReadAllText($encoderReceipt)) { throw 'Cached Hexagon encoder hash mismatch.' }
$encoderAssembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($encoderPath))
if (@($encoderAssembly.GetReferencedAssemblies() | Where-Object Name -EQ 'System.Management.Automation').Count) { throw 'Hexagon encoder must be ClrOnly.' }
$script:HexagonStepType = $encoderAssembly.GetType('HexagonStep', $true)
$script:HexagonEncoderType = $encoderAssembly.GetType('HexagonEncoder', $true)
$script:HexagonEncoder = New-HexagonEncoder -Type $script:HexagonEncoderType
$script:ElfConstants=$null
$elf=Get-ElfConstants
$header=Import-LibSourceText 'ELF.h'
foreach($name in 'EM_HEXAGON','EF_HEXAGON_ISA_V73') {
    $m=[regex]::Match($header,"\b$name\s*=\s*(0x[0-9a-fA-F]+|\d+)")
    if(-not $m.Success) { throw "Missing $name" }
    $elf[$name]=[Convert]::ToUInt32($m.Groups[1].Value.Replace('0x',''),$(if($m.Groups[1].Value.StartsWith('0x')){16}else{10}))
}
$m=[regex]::Match((Import-LibSourceText 'DynamicTags.def'),'HEXAGON_DYNAMIC_TAG\(HEXAGON_VER,\s*(0x[0-9a-fA-F]+)\)')
if(-not $m.Success) { throw 'Missing Hexagon dynamic version tag' }
$elf.DT_HEXAGON_VER=[Convert]::ToUInt32($m.Groups[1].Value.Substring(2),16)
# llvm-project 08169f5fb1b7386002cdb66e52192580fc0fcf24 llvm/include/llvm/BinaryFormat/ELFRelocs/Hexagon.def:40,42
$elf['R_HEX_GLOB_DAT']=[uint32]33; $elf['R_HEX_RELATIVE']=[uint32]35
$script:Target=[pscustomobject]@{ElfClass=32;Machine='EM_HEXAGON';ElfFlags=@('EF_HEXAGON_ISA_V73');RelocationForm='RELA';GotRelocation='R_HEX_GLOB_DAT';RelativeRelocation='R_HEX_RELATIVE'}
$setupSeconds = $emissionClock.Elapsed.TotalSeconds
$kernelRecord=$script:KernelByName[$Kernel]
. $kernelRecord.Build
if ($ResidentPayloads) {
    if (($Kernel -cne 'KokoroDecoderGenerator16Run' -and -not ($Kernel -ceq 'KokoroGeneratorTemplate1Run' -and $TemplateConnectedMain)) -or $ResidentPmuEvents) { throw 'Resident payload adapter requires the combined job or connected generator main without PMU telemetry.' }
    . (Join-Path $script:HexagonToolsRoot '../src/jobs/Kokoro.ResidentPayload.ps1')
    $steps=@(Add-KokoroResidentPayloadEntry -Steps $steps -Layout $run.Layout)
    $run.Layout | Add-Member -NotePropertyName ResidentPayloads -NotePropertyValue $true -Force
}
if ($RegionBody) {
    # Close external control flow solely for independent encoding verification.
    # This has no RPC admission/open entry and must never be deployed as a worker.
    $steps+=@(@{Op='imm';d=0;i=0},@{Op='return'},@{Op='label';Name='encoding_domain'},@{Op='imm';d=0;i=33},@{Op='return'})
    $symbol+='_encoding_only'; $soname=$soname.Replace('_skel.so','_region_encoding_only.so')
}
$stepSeconds = $emissionClock.Elapsed.TotalSeconds - $setupSeconds
$stageClock = [Diagnostics.Stopwatch]::StartNew()
$typedSteps = $script:HexagonStepType::Convert([hashtable[]]$steps)
$conversionSeconds = $stageClock.Elapsed.TotalSeconds
$stageClock.Restart()
$library=New-ElfCodeLibrary -Soname $soname -Needed @() -Functions ([ordered]@{$symbol=$typedSteps}) -PageSize 4096
$librarySeconds = $stageClock.Elapsed.TotalSeconds
if($Kernel -notin 'KokoroHarmonicSource16Run','KokoroDecoder16Run','KokoroGeneratorWholeSource16Run','KokoroDecoderGenerator16Run' -and $Kernel -in 'KokoroAlbertLinear16Run','KokoroAlbertLayerNorm16Run','KokoroAlbertGelu16Run','KokoroAlbertAttention16Run','KokoroAlbertEmbed16Run','KokoroAlbert16Run','KokoroDecoder16Run','KokoroDecoderGenerator16Run','KokoroResBlockRun','KokoroGenerator60xRun','KokoroGenerator60xResidentRun','KokoroGenerator60x16Run','KokoroGeneratorTailRun','KokoroGeneratorTail16Run','KokoroGeneratorStage16TailRun','KokoroResBlock16Run','KokoroGeneratorFrontStageTailRun','KokoroGeneratorFront10x16Run','KokoroGeneratorWhole16Run','KokoroHarmonicStft16Run','KokoroHarmonicSource16Run','KokoroGeneratorWholeSource16Run') {
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-link.json') ([Text.Encoding]::UTF8.GetBytes((@{Entry=$library.Exports[$symbol];Got=$library.GotSlots} | ConvertTo-Json -Depth 4))) -AllowOverwrite:$Force
}
$path=Join-Path $OutputDirectory $soname
Write-NewOrIdenticalFile $path $library.Bytes -AllowOverwrite:$Force
$stageClock.Restart()
if ($ReferenceAssembly) {
    # GOT calls use the lengths already admitted by the writer's layout pass.
    $pcAt=[long]$library.Exports[$symbol]
    $lengths=$library.StepLengths[$symbol]
    for ($stepIndex=0; $stepIndex -lt $steps.Count; $stepIndex++) {
        $step=$steps[$stepIndex]
        if($step.Op -eq 'got-call') { $step.Delta=[long]$library.GotSlots[$step.Import]-$pcAt }
        $pcAt+=$lengths[$stepIndex]
    }
    $asm=@('.text','.p2align 2',".global $symbol",".type $symbol,@function","${symbol}:")
    $asm+=@($steps | ForEach-Object {ConvertTo-HexagonAssembly $_})
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'probe-reference.s') ([Text.Encoding]::UTF8.GetBytes(($asm -join "`n")+"`n")) -AllowOverwrite:$Force
}
$referenceSeconds = $stageClock.Elapsed.TotalSeconds
$stageClock.Restart()
$codeStart=[int]$library.Exports[$symbol]
$codeLength=[int]$library.CodeSizes[$symbol]
$code=[byte[]]::new($codeLength); [Array]::Copy($library.Bytes,$codeStart,$code,0,$codeLength)
Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'emitted-code.bin') $code -AllowOverwrite:$Force
$artifactHash=(Get-FileHash $path).Hash
$emissionResult=[pscustomobject]@{PSTypeName='Kokoro.Hexagon.Emission';Kernel=$Kernel;Path=$path;Directory=$OutputDirectory;
    EncoderPath=$encoderPath;LoweringCommit=$loweringCommit;
    Bytes=$library.Bytes.Length;CodeBytes=$codeLength;SHA256=$artifactHash;LibrarySHA256=$artifactHash;
    Imports=$library.Imports.Count;Relocations=0;RegionBodyEncodingOnly=[bool]$RegionBody;
    Timings=[pscustomobject]@{SetupSeconds=$setupSeconds;StepsSeconds=$stepSeconds;ConversionSeconds=$conversionSeconds;
        LibrarySeconds=$librarySeconds;LayoutSeconds=$library.LayoutSeconds;EncodeSeconds=$library.EncodeSeconds;
        ReferenceSeconds=$referenceSeconds;CodeSeconds=$stageClock.Elapsed.TotalSeconds;TotalSeconds=$emissionClock.Elapsed.TotalSeconds}}
if (($Kernel -ceq 'KokoroGenerator60x16Run' -and ($GeneratorSchedule -ne 'Layer' -or $GeneratorMoments -ne 'Accumulate')) -or
    $Kernel -cin 'KokoroGeneratorTemplate1Run','KokoroHarmonicSource16Run','KokoroDecoder16Run','KokoroGeneratorWholeSource16Run','KokoroDecoderGenerator16Run') {
    $emissionResult | Add-Member -NotePropertyMembers @{
        Layout=$run.Layout;Steps=$steps;Link=[pscustomobject]@{Entry=$library.Exports[$symbol];Got=$library.GotSlots}
        Buffers=[pscustomobject]@{Library=$library.Bytes;Code=$code}
    }
}
$emissionResult
}


function Get-HexagonEmissionParameters {
    # The compatibility entrypoint binds the owning function's parameters without copying their declarations.
    $dictionary=[Management.Automation.RuntimeDefinedParameterDictionary]::new()
    $metadata=(Get-Command Invoke-HexagonEmission).Parameters
    foreach($name in $metadata.Keys){
        if([Management.Automation.PSCmdlet]::CommonParameters.Contains($name)){continue}
        $attributes=[Collections.ObjectModel.Collection[Attribute]]::new()
        foreach($attribute in $metadata[$name].Attributes){$attributes.Add($attribute)}
        if($name -ceq 'Kernel'){
            $attributes.Add([Management.Automation.ValidateSetAttribute]::new([string[]]@($script:KernelByName.Keys)))
        }
        $dictionary.Add($name,[Management.Automation.RuntimeDefinedParameter]::new($name,$metadata[$name].ParameterType,$attributes))
    }
    $dictionary
}

function Test-HexagonEmissionEquivalence {
    # Fresh processes isolate each encoder load. A new directory prevents stale libraries from passing the gate.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaselinePath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        # Emission processes running at once; each kernel still gets its own process.
        [ValidateRange(1,256)][int]$Throttle=[Environment]::ProcessorCount
    )
    $baseline=@(Import-Csv -LiteralPath $BaselinePath)
    $expectedNames=@($script:KernelByName.Keys | Where-Object {$_ -cne 'Definition'})
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($row in $baseline){
        if(-not $seen.Add($row.Recipe) -or $row.Recipe -cnotin $expectedNames){
            throw "Duplicate or unknown baseline kernel: $($row.Recipe)"
        }
        if($row.Status -cnotin 'Emits','Fails' -or
            ($row.Status -ceq 'Emits' -and $row.EmitterSHA256 -cnotmatch '^[0-9A-F]{64}$') -or
            ($row.Status -ceq 'Fails' -and $row.EmitterSHA256)){
            throw "Invalid emission baseline: $($row.Recipe)"
        }
    }
    if($seen.Count -ne $expectedNames.Count){throw 'Emission baseline must cover every named kernel except Definition.'}
    $output=[IO.Path]::GetFullPath($OutputDirectory)
    if(Test-Path -LiteralPath $output){throw 'Emission equivalence requires a new output directory.'}
    [void][IO.Directory]::CreateDirectory($output)
    $results=[Collections.Generic.List[object]]::new()
    $pwsh=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
    # Start up to $Throttle emission processes; each finished one is recorded as it exits, then the results are
    # written in baseline order. The first runs alone: it fills the lowered-encoder cache the others load, which
    # concurrent first writers would race to save.
    $exitCodes=@{}; $seconds=@{}; $running=[Collections.Generic.List[object]]::new(); $next=0
    while($next -lt $baseline.Count -or $running.Count){
        while($next -lt $baseline.Count -and $running.Count -lt $(if($exitCodes.Count){$Throttle}else{1})){
            $row=$baseline[$next]; $next++
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=$pwsh
            $start.UseShellExecute=$false
            $start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true
            $start.RedirectStandardError=$true
            foreach($argument in @('-NoProfile','-File',(Join-Path $script:HexagonToolsRoot 'Emit-HexagonProbe.ps1'),
                '-Kernel',$row.Recipe,'-OutputDirectory',(Join-Path $output $row.Recipe),'-Force')){
                $start.ArgumentList.Add($argument)
            }
            $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
            if(-not $process.Start()){$process.Dispose(); throw "Cannot start emission for $($row.Recipe)"}
            $running.Add([pscustomobject]@{Recipe=$row.Recipe;Process=$process;Stdout=$process.StandardOutput.ReadToEndAsync();Stderr=$process.StandardError.ReadToEndAsync();Exit=$process.WaitForExitAsync();Clock=[Diagnostics.Stopwatch]::StartNew()})
        }
        $finished=[Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($running.Exit))
        $done=$running[$finished]; $running.RemoveAt($finished)
        try{
            $exitCodes[$done.Recipe]=$done.Process.ExitCode; $seconds[$done.Recipe]=[math]::Round($done.Clock.Elapsed.TotalSeconds,1)
            [IO.File]::WriteAllText((Join-Path $output ($done.Recipe+'.stdout.txt')),$done.Stdout.GetAwaiter().GetResult())
            [IO.File]::WriteAllText((Join-Path $output ($done.Recipe+'.stderr.txt')),$done.Stderr.GetAwaiter().GetResult())
        }
        finally{$done.Process.Dispose()}
        Write-Progress -Activity 'Hexagon emission equivalence' -Status "$($exitCodes.Count)/$($baseline.Count): $($done.Recipe)" -PercentComplete (100*$exitCodes.Count/$baseline.Count)
    }
    foreach($row in $baseline){
        $directory=Join-Path $output $row.Recipe
        $exitCode=$exitCodes[$row.Recipe]
        $libraries=@(Get-ChildItem -LiteralPath $directory -Filter *.so -File -ErrorAction SilentlyContinue)
        $hash=if($libraries.Count -eq 1){(Get-FileHash -LiteralPath $libraries[0].FullName).Hash}else{''}
        $status=if($exitCode -ne 0 -or $libraries.Count -ne 1){'Fails'}
            elseif($hash -ceq $row.EmitterSHA256){'Identical'}else{'Differs'}
        $passed=if($row.Status -ceq 'Emits'){$status -ceq 'Identical'}else{$status -ceq 'Fails' -and -not $libraries.Count}
        $result=[pscustomobject]@{Recipe=$row.Recipe;Baseline=$row.Status;Now=$status;Passed=$passed;SHA256=$hash;ExitCode=$exitCode;Seconds=$seconds[$row.Recipe]}
        $results.Add($result)
        $result | Export-Csv -LiteralPath (Join-Path $output 'emitter-compare.csv') -Append
    }
    Write-Progress -Activity 'Hexagon emission equivalence' -Completed
    $failures=@($results | Where-Object {-not $_.Passed})
    if($failures.Count){throw ('Emission equivalence failed: '+($failures.Recipe -join ', '))}
    $results
}

if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Command) {
    'Instructions' {
        $script:Instructions | ForEach-Object { [pscustomobject]@{ Op = $_.Op; Rule = $_.Rule; Bytes = $_.Bytes; Asm = $_.Asm; Source = $_.Source } }
    }
    'Kernels' {
        foreach($name in @($script:KernelByName.Keys | Sort-Object)) {
            [pscustomobject]@{Name=$name;Variants=@($script:KernelByName[$name].Names)}
        }
    }
    'Emit' { Invoke-HexagonEmission @Parameters }
    'EmissionParameters' { Get-HexagonEmissionParameters }
    'VerifyEmission' { Test-HexagonEmissionEquivalence @Parameters }
    default { "Hexagon V73 instruction records: $($script:Instructions.Count). Commands: Instructions Kernels Emit VerifyEmission" }
}
