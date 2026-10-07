# Hexagon V73 singleton-packet encoders.
# Source: 80-N2040-53 Rev. AB, pp. 145, 157, 163, 189, 206, 214, 242, 304.
# PDF SHA256: 44EBAFD1119F725BD3C6FFB87499232520DF9A0A6E3E3DC6EA329B15DAED11A8
# Each instruction ends its own packet. No duplexes, extenders or scheduling yet.
$script:HexagonForms = @{
    'imm'    = '01111000ii-iiiiiPPiiiiiiiiiddddd'
    'lo'     = '01110001ii1xxxxxPPiiiiiiiiiiiiii'
    'hi'     = '01110010ii1xxxxxPPiiiiiiiiiiiiii'
    'eq'     = '11110010-00sssssPP-ttttt---000dd'
    'gtu'    = '11110010-11sssssPP-ttttt---000dd'
    'jump-p' = '01011100ii0iiiiiPPi00-uuiiiiiii-'
    'load'   = '10010ii1100sssssPPiiiiiiiiiddddd'
    'store'  = '10100ii1100sssssPPitttttiiiiiiii'
    'add'    = '11110011000sssssPP-ttttt---ddddd'
    'addi'   = '1011iiiiiiisssssPPiiiiiiiiiddddd'
    'sfadd'          = '11101011000sssssPP0ttttt000ddddd'
    'sfsub'          = '11101011000sssssPP0ttttt001ddddd'
    'sfmpy'          = '11101011010sssssPP0ttttt000ddddd'
    # V73 PRM 80-N2040-53 Rev. AB p.474.
    'sfmax'          = '11101011100sssssPP0ttttt000ddddd'
    # V73 PRM 80-N2040-53 Rev. AB p.470 (same pinned manual as above).
    'sfinvsqrta'     = '10001011111sssssPP------0eeddddd'
    'and'            = '11110001000sssssPP0ttttt000ddddd'
    'xor'            = '11110001011sssssPP0ttttt000ddddd'
    # SDK 6.4.0.2 hexagon-llvm-mc (V73): r24 = or(r24,r0) = 0xF138C018.
    'or'             = '11110001001sssssPP0ttttt000ddddd'
    'conv-sf2w-chop' = '10001011100sssssPP000000001ddddd'
    'conv-w2sf'      = '10001011010sssssPP000000000ddddd'
    'vload'          = '00101000000sssssPPiiiiii---ddddd'
    'vload-post'     = '00101001000sssssPPiiiiii---ddddd'
    'vstore'         = '00101000001sssssPPiiiiii---ttttt'
    'vstore-post'    = '00101001001sssssPPiiiiii---ttttt'
    'vadd-sf'        = '00011111100tttttPP1sssss110ddddd'
    'vsub-sf'        = '00011111100tttttPP1sssss111ddddd'
    'vmpy-sf'        = '00011111100tttttPP1sssss001ddddd'
    # V73 HVX PRM 80-N2040-54 Rev. AB pp.154,250,262. QFloat
    # intermediates are explicit; these are not the optional IEEE-result forms.
    'vmpy-sf-qf32'   = '00011111111tttttPP1sssss001ddddd'
    'vadd-sf-qf32'   = '00011111101tttttPP1sssss001ddddd'
    'vconv-qf32-sf'  = '00011110--0--100PP1sssss000ddddd'
    'vsplat'         = '00011001101sssssPP000000001ddddd'
    'vand'           = '00011100001tttttPP0sssss101ddddd'
    'vxor'           = '00011100001tttttPP0sssss111ddddd'
    # SDK 6.4.0.2 V73 assembler: v0.uw=vlsr(v1.uw,r2) -> 0x1982C120;
    # v0.w=vadd(v1.w,v2.w) -> 0x1C42C100; v0.w=vmpyie(v1.w,v2.uh) -> 0x1FC2C100.
    'vlsr-uw'        = '00011001100tttttPP0sssss001ddddd'
    'vadd-w'         = '00011100010tttttPP0sssss000ddddd'
    'vmpyie-w-uh'    = '00011111110tttttPP0sssss000ddddd'
    # Integer AdaIN: SDK 6.4.0.2 V73, checked against assembler in emission tests.
    'mpyu-d'         = '11100101010sssssPP0ttttt000ddddd'
    'mpy-d'          = '11100101000sssssPP0ttttt000ddddd'
    'add-d'          = '11010011000sssssPP0ttttt111ddddd'
    'sub-d'          = '11010011001tttttPP0sssss111ddddd'
    'gtu-d'          = '11010010100sssssPP0ttttt100000dd'
    'gt'             = '11110010010sssssPP0ttttt000000dd'
    'sub'            = '11110011001tttttPP0sssss000ddddd'
    'lsr-i'          = '10001100000sssssPP0iiiii001ddddd'
    'asl-i'          = '10001100000sssssPP0iiiii010ddddd'
    'asr-d-i'        = '10000000000sssssPPiiiiii000ddddd'
    'vasr-w'         = '00011001011tttttPP0sssss101ddddd'
    'vasl-w'         = '00011001011tttttPP0sssss111ddddd'
    'vmax-w'         = '00011111001tttttPP0sssss000ddddd'
    'vmin-w'         = '00011111000tttttPP0sssss100ddddd'
    'vor'            = '00011100001tttttPP0sssss110ddddd'
    # V73 HVX PRM Rev AB pp.227-230, halfword lookup with r0..7 control.
    'vsub-w'         = '00011100010tttttPP0sssss111ddddd'
    # Halfword HVX: SDK 6.4.0.2 hexagon-llvm-mc (+hvxv73, 128B), two register sets each.
    'vmpy-h-rnd-sat' = '00011100001tttttPP0sssss001ddddd'
    'vadd-h' = '00011111101tttttPP0sssss111ddddd'
    'vadd-h-sat' = '00011100010tttttPP0sssss011ddddd'
    'vsub-h' = '00011100010tttttPP0sssss110ddddd'
    'vabs-h-sat' = '0001111000000000PP0sssss001ddddd'
    'vasr-h' = '00011001011tttttPP0sssss110ddddd'
    'vasl-h' = '00011001100tttttPP0sssss000ddddd'
    'vsplat-h' = '00011001110sssssPP000000001ddddd'
    'vlut16'         = '00011011vvvvvxxxPP1sssss110ddddd'
    'vlut16-or'      = '00011011vvvvvxxxPP1sssss111ddddd'
    'valign'         = '00011011tttttxxxPP0sssss000ddddd'
    'valign-imm'     = '00011110001tttttPP1sssssiiiddddd'
    'vshuff'         = '00011011tttttrrrPP1sssss011ddddd'
    'trap0'          = '0101010000000000PP0iiiii000iii00'
    'pcycle'         = '0110111100011110PP000000000ddddd'
    'hwticks'        = '0110100000011110PP000000000ddddd'
    'store-d'        = '10100ii1110sssssPPitttttiiiiiiii'
    'mxclracc'       = '1010011011100000PP00000000010001'
    'mxclracc.hf'    = '1010011011100000PP00000000010011'
    'cvt-hf'         = '10100110111sssssPP01101000010000'
    'cvt-ub'         = '10100110111sssssPP01011100010000'
    'cvt-ub-sc0'     = '10100110111sssssPP01110000010000'
    'cvt-ub-sc1'     = '10100110111sssssPP01110100010000'
    'mxmem-cvt'      = '10100110111sssssPP0ttttt00011000'
    'mxmem-after-hf' = '10100110111sssssPP1ttttt00000100'
    'mxmem-after-retain-cm-ub' = '10100110111sssssPP0ttttt00001111'
    'bias-mxmem'     = '10010010000sssssPP00001111111111'
    'bias-mxmem2'    = '10010010000sssssPP00001111111110'
    'act-hf'         = '10010010000sssssPP0ttttt11100100'
    'act-ub'         = '10010010000sssssPP0ttttt11101100'
    'act-ub-cm'      = '10010010000sssssPP0ttttt11101101'
    'wt-hf'          = '10010010000uuuuuPP1vvvvv11101111'
    'wt-b'           = '10010010000uuuuuPP1vvvvv11100000'
    'wt-n'           = '10010010000uuuuuPP1vvvvv11100001'
    # Conv forms, bit patterns from SDK 6.4.0.2 hexagon-llvm-mc (+hmxv73) with varied registers.
    'act-ub-single'  = '10010010000sssssPP0ttttt11110000'
    'wt-b-deep'      = '10010010000uuuuuPP1vvvvv11101000'
    'mxmem-after-sat-ub' = '10100110111sssssPP0ttttt00000100'
    # Accumulator byte stores (non-cm): SDK 6.4.0.2 hexagon-llvm-mc (+hmxv73), registers (12,9), (3,17), (30,0).
    # :retain keeps the accumulator for a second store; .ub without :sat wraps modulo 256.
    'mxmem-after-retain-sat-ub' = '10100110111sssssPP0ttttt00001100'
    'mxmem-after-ub' = '10100110111sssssPP0ttttt00000110'
    # Calls through the GOT and stack frames, bit patterns from SDK 6.4.0.2 hexagon-llvm-mc (V73).
    'immext'         = '0000iiiiiiiiiiiiPPiiiiiiiiiiiiii'
    'add-pc'         = '0110101001001001PP0iiiiii00ddddd'
    'callr'          = '01010000101sssssPP00000000000000'
    'syncht'         = '1010100001000000PP00000000000000'
    'allocframe'     = '1010000010011101PP000iiiiiiiiiii'
    'dealloc-return' = '1001011000011110PP00000000011110'
    'load-d'         = '10010ii1110sssssPPiiiiiiiiiddddd'
    'return'         = '01010010100sssssPP--------------'
    # User DMA, bit patterns from SDK 6.4.0.2 hexagon-llvm-mc (V73). Descriptor use follows
    # llama.cpp ad2156533102a0d3c4e5fbdf422dc25fba4d03ba ggml/src/ggml-hexagon/htp/dma-queue.h.
    'dmstart'        = '10100110000sssssPP00000000100000'
    'dmlink'         = '10100110000sssssPP0ttttt01000000'
    'dmwait'         = '1010100000000000PP000000001ddddd'
    'dmpoll'         = '1010100000000000PP000000010ddddd'
    'release-at'     = '10100000111sssssPP00000000001100'
    # Byte load, halfword store and scalar max/min, bit patterns from SDK 6.4.0.2 hexagon-llvm-mc (V73).
    'load-ub'        = '10010ii1001sssssPPiiiiiiiiiddddd'
    'store-h'        = '10100ii1010sssssPPitttttiiiiiiii'
    'max'            = '11010101110sssssPP0ttttt000ddddd'
    'min'            = '11010101101tttttPP0sssss000ddddd'
    'asr-i'          = '10001100000sssssPP0iiiii000ddddd'
}

function ConvertTo-HexagonWord {
    param([string] $Form, [hashtable] $Fields)
    $pattern = $script:HexagonForms[$Form]
    if (-not $pattern -or $pattern.Length -ne 32) { throw "Invalid instruction form: $Form" }
    $values = @{}; $counts = @{}
    foreach ($c in $pattern.ToCharArray()) {
        $key = [string]$c
        if ($key -notmatch '[01-]') { $counts[$key] = 1 + [int]$counts[$key] }
    }
    foreach ($key in $counts.Keys) {
        if (-not $Fields.ContainsKey($key)) { throw "Missing $Form field $key" }
        $value = [long]$Fields[$key]
        if ($value -lt 0 -or $value -ge (1L -shl $counts[$key])) { throw "$Form field $key out of range" }
        $values[$key] = $value
    }
    [uint32]$word = 0
    for ($at = 31; $at -ge 0; $at--) {
        $key = [string]$pattern[$at]; $bit = 0
        if ($key -eq '1') { $bit = 1 }
        elseif ($key -ne '0' -and $key -ne '-') {
            $bit = $values[$key] -band 1
            $values[$key] = $values[$key] -shr 1
        }
        $word = $word -bor ([uint32]$bit -shl (31 - $at))
    }
    $word
}

function Read-HexagonWord {
    param([uint32] $Word)
    foreach ($name in $script:HexagonForms.Keys) {
        $pattern = $script:HexagonForms[$name]; $fields = @{}; $match = $true
        for ($at = 0; $at -lt 32; $at++) {
            $key = [string]$pattern[$at]; $bit = ($Word -shr (31 - $at)) -band 1
            if ($key -eq '0' -or $key -eq '-') { if ($bit -ne 0) { $match = $false; break } }
            elseif ($key -eq '1') { if ($bit -ne 1) { $match = $false; break } }
            else { $fields[$key] = ([long]$fields[$key] -shl 1) -bor $bit }
        }
        if ($match) { return [pscustomobject]@{ Op=$name; Fields=$fields } }
    }
    throw ('Unknown Hexagon instruction 0x{0:X8}' -f $Word)
}

function New-HexagonInstruction {
    param([hashtable] $Step, [long] $Pc, [long] $Target)
    if ($Step.Op -eq 'label') { return }
    $fields = @{ P=3 }
    foreach ($key in 'd','s','t','x','u','e') { if ($Step.ContainsKey($key)) { $fields[$key] = $Step[$key] } }
    switch ($Step.Op) {
        { $_ -in 'mpyu-d','mpy-d','add-d','sub-d','gtu-d','asr-d-i' } {
            $pairs = switch ($Step.Op) {
                { $_ -in 'mpyu-d','mpy-d' } { @('d') }
                'gtu-d' { @('s','t') }
                'asr-d-i' { @('d','s') }
                default { @('d','s','t') }
            }
            foreach ($r in $pairs) { if ($Step[$r] % 2 -ne 0 -or $Step[$r] -lt 0 -or $Step[$r] -gt 30) { throw 'Integer register pair must be even and 0..30' } }
            if ($Step.Op -eq 'asr-d-i') {
                if ($Step.i -lt 0 -or $Step.i -gt 63) { throw 'Double-word shift out of range' }
                $fields.i=[long]$Step.i
            }
        }
        { $_ -in 'lsr-i','asl-i','asr-i' } {
            if ($Step.i -lt 0 -or $Step.i -gt 31) { throw 'Word shift out of range' }
            $fields.i=[long]$Step.i
        }
        { $_ -in 'imm','addi' } {
            if ($Step.i -lt -32768 -or $Step.i -gt 32767) { throw 'Signed immediate out of range' }
            $fields.i = [long]$Step.i -band 65535
        }
        { $_ -in 'lo','hi' } { $fields.i = $Step.i }
        { $_ -in 'load','store' } {
            if ($Step.Offset % 4 -ne 0 -or $Step.Offset -lt -4096 -or $Step.Offset -gt 4092) { throw 'Word offset out of range' }
            $fields.i = ([long]$Step.Offset / 4) -band 2047
        }
        'load-ub' {
            if ($Step.Offset -lt -1024 -or $Step.Offset -gt 1023) { throw 'Byte offset out of range' }
            $fields.i = [long]$Step.Offset -band 2047
        }
        'store-h' {
            if ($Step.Offset % 2 -ne 0 -or $Step.Offset -lt -2048 -or $Step.Offset -gt 2046) { throw 'Halfword offset out of range or unaligned' }
            $fields.i = ([long]$Step.Offset / 2) -band 2047
        }
        { $_ -in 'vload','vstore' } {
            $vOff = if ($Step.ContainsKey('Offset')) {
                if ($Step.Offset % 128 -ne 0) { throw 'Vector offset must be multiple of 128 bytes' }
                [int]($Step.Offset / 128)
            } elseif ($Step.ContainsKey('i')) {
                [int]$Step.i
            } else { 0 }
            if ($vOff -lt -8 -or $vOff -gt 7) { throw 'Vector immediate offset out of range (-8..7)' }
            $fields.i = if ($vOff -ge 0) { [long]$vOff } else { (1L -shl 5) -bor ($vOff -band 7) }
        }
        { $_ -in 'vload-post','vstore-post' } {
            $vOff = if ($Step.ContainsKey('i')) { [int]$Step.i } else { 1 }
            if ($vOff -lt -8 -or $vOff -gt 7) { throw 'Vector post-increment offset out of range (-8..7)' }
            $fields.i = if ($vOff -ge 0) { [long]$vOff } else { (1L -shl 5) -bor ($vOff -band 7) }
        }
        'jump-p' {
            $delta = $Target - $Pc
            if ($delta % 4 -ne 0 -or $delta -lt -65536 -or $delta -gt 65532) { throw 'Branch out of range' }
            $fields.i = ([long]$delta / 4) -band 32767
        }
        'valign' {
            if ($Step.ContainsKey('r')) { $fields.x = [long]$Step.r }
            if ($fields.x -lt 0 -or $fields.x -gt 7) { throw 'Valign register out of range (r0..r7)' }
        }
        { $_ -in 'vlut16','vlut16-or' } {
            if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Lookup destination pair must be even and 0..30' }
            if ($Step.x -lt 0 -or $Step.x -gt 7) { throw 'Lookup scalar control must be r0..7' }
            if ($Step.v -lt 0 -or $Step.v -gt 31) { throw 'Lookup table vector out of range' }
            $fields.v=[long]$Step.v
        }
        'valign-imm' {
            if ($Step.i -lt 0 -or $Step.i -gt 7) { throw 'Valign immediate out of range (0..7)' }
            $fields.i = [long]$Step.i
        }
        'vshuff' {
            if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Vshuff destination register pair must be even and 0..30' }
            if ($Step.s -lt 0 -or $Step.s -gt 31 -or $Step.t -lt 0 -or $Step.t -gt 31) { throw 'Vshuff source register out of range (0..31)' }
            if ($Step.r -lt 0 -or $Step.r -gt 7) { throw 'Vshuff scalar register out of range (r0..r7)' }
            $fields.d = [long]$Step.d; $fields.s = [long]$Step.s; $fields.t = [long]$Step.t; $fields.r = [long]$Step.r
        }
        'trap0' {
            if ($Step.i -lt 0 -or $Step.i -gt 255) { throw 'Trap0 immediate out of range (0..255)' }
            $fields.i = [long]$Step.i
        }
        { $_ -in 'pcycle', 'hwticks' } {
            if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Pcycle/Hwticks destination register pair must be even and 0..30' }
            $fields.d = [long]$Step.d
        }
        'store-d' {
            if ($Step.Offset % 8 -ne 0 -or $Step.Offset -lt -8192 -or $Step.Offset -gt 8184) { throw 'Double word offset out of range or unaligned' }
            if ($Step.t % 2 -ne 0 -or $Step.t -lt 0 -or $Step.t -gt 30) { throw 'Store-d source register pair must be even and 0..30' }
            $fields.i = ([long]$Step.Offset / 8) -band 2047
            $fields.t = [long]$Step.t
            $fields.s = [long]$Step.s
        }
        'mxclracc' { }
        'mxclracc.hf' { }
        { $_ -in 'cvt-hf','cvt-ub','cvt-ub-sc0','cvt-ub-sc1' } {
            if ($Step.s -lt 0 -or $Step.s -gt 31) { throw 'Cvt source register out of range (0..31)' }
            $fields.s = [long]$Step.s
        }
        'got-call' {
            # { rd = add(pc, ##slot-pc) } ; rd = memw(rd) ; callr rd -- the ELF writer passes the
            # import's GOT slot as Target. Clobbers rd and the caller-saved registers.
            if (-not $Step.Import) { throw 'got-call needs an Import' }
            if ($Step.d -lt 0 -or $Step.d -gt 27) { throw 'got-call register out of range (r0..r27)' }
            $delta = $Target - $Pc
            if ($delta -lt [int]::MinValue -or $delta -gt [int]::MaxValue) { throw 'GOT slot out of range' }
            [uint32]$u = [uint32]($delta -band 0xFFFFFFFF)
            $words = @(
                (ConvertTo-HexagonWord 'immext' @{ i=[long]($u -shr 6); P=1 }),
                (ConvertTo-HexagonWord 'add-pc' @{ i=[long]($u -band 63); d=[long]$Step.d; P=3 }),
                (ConvertTo-HexagonWord 'load' @{ i=0; s=[long]$Step.d; d=[long]$Step.d; P=3 }),
                (ConvertTo-HexagonWord 'callr' @{ s=[long]$Step.d; P=3 }))
            $bytes = [byte[]]::new(16)
            for ($n = 0; $n -lt 4; $n++) { [Array]::Copy([BitConverter]::GetBytes([uint32]$words[$n]), 0, $bytes, 4 * $n, 4) }
            return $bytes
        }
        'allocframe' {
            if ($Step.Bytes % 8 -ne 0 -or $Step.Bytes -lt 0 -or $Step.Bytes -gt 16376) { throw 'Frame size must be a multiple of 8 up to 16376' }
            $fields.i = [long]($Step.Bytes / 8)
        }
        'dealloc-return' { }
        'add-pc' {
            if ($Step.i -lt 0 -or $Step.i -gt 63) { throw 'add(pc) immediate out of range (0..63)' }
            $fields.i = [long]$Step.i
        }
        'load-d' {
            if ($Step.Offset % 8 -ne 0 -or $Step.Offset -lt -8192 -or $Step.Offset -gt 8184) { throw 'Double word offset out of range or unaligned' }
            if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Load-d destination register pair must be even and 0..30' }
            $fields.i = ([long]$Step.Offset / 8) -band 2047
        }
        'callr' { }
        'syncht' { }
        'hmx-pair' {
            # One packet: activation load (slot 1) then weight load (slot 0), named by form.
            if ($Step.Act -notin 'act-hf','act-ub','act-ub-cm','act-ub-single') { throw "Unsupported HMX activation form: $($Step.Act)" }
            if ($Step.Wt -notin 'wt-hf','wt-b','wt-n','wt-b-deep') { throw "Unsupported HMX weight form: $($Step.Wt)" }
            foreach ($r in 's','t','u','v') { if ($Step[$r] -lt 0 -or $Step[$r] -gt 31) { throw "HMX register $r out of range (0..31)" } }
            $w0 = ConvertTo-HexagonWord $Step.Act @{ s=[long]$Step.s; t=[long]$Step.t; P=1 }
            $w1 = ConvertTo-HexagonWord $Step.Wt  @{ u=[long]$Step.u; v=[long]$Step.v; P=3 }
            if ((Read-HexagonWord $w0).Op -ne $Step.Act -or (Read-HexagonWord $w1).Op -ne $Step.Wt) { throw 'HMX packet failed round-trip decode' }
            $bytes = [byte[]]::new(8)
            [Array]::Copy([BitConverter]::GetBytes($w0), 0, $bytes, 0, 4)
            [Array]::Copy([BitConverter]::GetBytes($w1), 0, $bytes, 4, 4)
            return $bytes
        }
        { $_ -in 'mxmem-cvt','mxmem-after-hf','mxmem-after-retain-cm-ub','mxmem-after-sat-ub','mxmem-after-retain-sat-ub','mxmem-after-ub' } {
            if ($Step.s -lt 0 -or $Step.s -gt 31) { throw 'Mxmem-cvt base register out of range (0..31)' }
            if ($Step.t -lt 0 -or $Step.t -gt 31) { throw 'Mxmem-cvt stride register out of range (0..31)' }
            $fields.s = [long]$Step.s
            $fields.t = [long]$Step.t
        }
        { $_ -in 'bias-mxmem','bias-mxmem2' } {
            if ($Step.s -lt 0 -or $Step.s -gt 31) { throw 'Bias address register out of range (0..31)' }
            $fields.s = [long]$Step.s
        }
        { $_ -in 'mxmpy-fp16','mxmpy-w8a8','mxmpy-w4a8','mxmpy-w8a8-cm','mxmpy-w4a8-cm' } {
            if ($Step.s -lt 0 -or $Step.s -gt 31 -or $Step.t -lt 0 -or $Step.t -gt 31) { throw 'HMX activation registers out of range (0..31)' }
            if ($Step.u -lt 0 -or $Step.u -gt 31 -or $Step.v -lt 0 -or $Step.v -gt 31) { throw 'HMX weight registers out of range (0..31)' }
            $actForm = if ($Step.Op -eq 'mxmpy-fp16') { 'act-hf' } elseif ($Step.Op.EndsWith('-cm')) { 'act-ub-cm' } else { 'act-ub' }
            $wtForm  = if ($Step.Op -eq 'mxmpy-fp16') { 'wt-hf' } elseif ($Step.Op.StartsWith('mxmpy-w8a8')) { 'wt-b' } else { 'wt-n' }
            $w0 = ConvertTo-HexagonWord $actForm @{ s=[long]$Step.s; t=[long]$Step.t; P=1 }
            $w1 = ConvertTo-HexagonWord $wtForm  @{ u=[long]$Step.u; v=[long]$Step.v; P=3 }
            $d0 = Read-HexagonWord $w0
            $d1 = Read-HexagonWord $w1
            if ($d0.Op -ne $actForm -or $d1.Op -ne $wtForm) { throw 'HMX dual-slot packet failed round-trip decode' }
            $bytes = [byte[]]::new(8)
            [Array]::Copy([BitConverter]::GetBytes($w0), 0, $bytes, 0, 4)
            [Array]::Copy([BitConverter]::GetBytes($w1), 0, $bytes, 4, 4)
            return $bytes
        }
        'return' { $fields.s = 31 }
    }
    $word = ConvertTo-HexagonWord $Step.Op $fields
    $decoded = Read-HexagonWord $word
    if ($decoded.Op -ne $Step.Op) { throw 'Instruction decoded to a different operation' }
    foreach ($key in $fields.Keys) { if ($decoded.Fields[$key] -ne $fields[$key]) { throw "Decode mismatch: $key" } }
    [BitConverter]::GetBytes($word)
}

function Get-InstructionSet {
    param([string] $Isa)
    if ($Isa -and $Isa -ne 'HexagonV73') { throw "Unsupported ISA: $Isa" }
    [pscustomobject]@{
        Id='HexagonV73'; Name='Hexagon V73'; StateBit=0
        Length={ param($Step)
            if ($Step.Op -eq 'label') { 0 }
            elseif ($Step.Op -in 'mxmpy-fp16','mxmpy-w8a8','mxmpy-w4a8','mxmpy-w8a8-cm','mxmpy-w4a8-cm','hmx-pair') { 8 }
            elseif ($Step.Op -eq 'got-call') { 16 }
            else { 4 }
        }
        Encode={ param($Step,$Pc,$Target) New-HexagonInstruction $Step $Pc $Target }
    }
}

function ConvertTo-HexagonAssembly {
    param([hashtable] $Step)
    switch ($Step.Op) {
        'label' { return "$($Step.Name):" }
        'imm' { $s = "r$($Step.d) = #$($Step.i)" }
        'lo' { $s = "r$($Step.x).l = #$($Step.i)" }
        'hi' { $s = "r$($Step.x).h = #$($Step.i)" }
        'eq' { $s = "p$($Step.d) = cmp.eq(r$($Step.s),r$($Step.t))" }
        'gtu' { $s = "p$($Step.d) = cmp.gtu(r$($Step.s),r$($Step.t))" }
        'jump-p' { $s = "if (p$($Step.u)) jump:nt $($Step.Label)" }
        'load' { $s = "r$($Step.d) = memw(r$($Step.s)+#$($Step.Offset))" }
        'store' { $s = "memw(r$($Step.s)+#$($Step.Offset)) = r$($Step.t)" }
        'add' { $s = "r$($Step.d) = add(r$($Step.s),r$($Step.t))" }
        'addi' { $s = "r$($Step.d) = add(r$($Step.s),#$($Step.i))" }
        'sfadd'          { $s = "r$($Step.d) = sfadd(r$($Step.s),r$($Step.t))" }
        'sfsub'          { $s = "r$($Step.d) = sfsub(r$($Step.s),r$($Step.t))" }
        'sfmpy'          { $s = "r$($Step.d) = sfmpy(r$($Step.s),r$($Step.t))" }
        'sfmax'          { $s = "r$($Step.d) = sfmax(r$($Step.s),r$($Step.t))" }
        'sfinvsqrta'     { $s = "r$($Step.d),p$($Step.e) = sfinvsqrta(r$($Step.s))" }
        'and'            { $s = "r$($Step.d) = and(r$($Step.s),r$($Step.t))" }
        'xor'            { $s = "r$($Step.d) = xor(r$($Step.s),r$($Step.t))" }
        'or'             { $s = "r$($Step.d) = or(r$($Step.s),r$($Step.t))" }
        'conv-sf2w-chop' { $s = "r$($Step.d) = convert_sf2w(r$($Step.s)):chop" }
        'conv-w2sf'      { $s = "r$($Step.d) = convert_w2sf(r$($Step.s))" }
        'vload'          {
            $vOff = if ($Step.ContainsKey('Offset')) { [int]($Step.Offset / 128) } elseif ($Step.ContainsKey('i')) { [int]$Step.i } else { 0 }
            $s = "v$($Step.d) = vmem(r$($Step.s)+#$vOff)"
        }
        'vload-post'     {
            $vOff = if ($Step.ContainsKey('i')) { [int]$Step.i } else { 1 }
            $s = "v$($Step.d) = vmem(r$($Step.s)++#$vOff)"
        }
        'vstore'         {
            $vOff = if ($Step.ContainsKey('Offset')) { [int]($Step.Offset / 128) } elseif ($Step.ContainsKey('i')) { [int]$Step.i } else { 0 }
            $s = "vmem(r$($Step.s)+#$vOff) = v$($Step.t)"
        }
        'vstore-post'    {
            $vOff = if ($Step.ContainsKey('i')) { [int]$Step.i } else { 1 }
            $s = "vmem(r$($Step.s)++#$vOff) = v$($Step.t)"
        }
        'vadd-sf'        { $s = "v$($Step.d).sf = vadd(v$($Step.s).sf,v$($Step.t).sf)" }
        'vsub-sf'        { $s = "v$($Step.d).sf = vsub(v$($Step.s).sf,v$($Step.t).sf)" }
        'vmpy-sf'        { $s = "v$($Step.d).sf = vmpy(v$($Step.s).sf,v$($Step.t).sf)" }
        'vlsr-uw'        { $s = "v$($Step.d).uw = vlsr(v$($Step.s).uw,r$($Step.t))" }
        'vadd-w'         { $s = "v$($Step.d).w = vadd(v$($Step.s).w,v$($Step.t).w)" }
        'vmpyie-w-uh'    { $s = "v$($Step.d).w = vmpyie(v$($Step.s).w,v$($Step.t).uh)" }
        'mpyu-d' { $s="r$($Step.d+1):$($Step.d) = mpyu(r$($Step.s),r$($Step.t))" }
        'mpy-d' { $s="r$($Step.d+1):$($Step.d) = mpy(r$($Step.s),r$($Step.t))" }
        'add-d' { $s="r$($Step.d+1):$($Step.d) = add(r$($Step.s+1):$($Step.s),r$($Step.t+1):$($Step.t))" }
        'sub-d' { $s="r$($Step.d+1):$($Step.d) = sub(r$($Step.s+1):$($Step.s),r$($Step.t+1):$($Step.t))" }
        'gtu-d' { $s="p$($Step.d) = cmp.gtu(r$($Step.s+1):$($Step.s),r$($Step.t+1):$($Step.t))" }
        'gt' { $s="p$($Step.d) = cmp.gt(r$($Step.s),r$($Step.t))" }
        'sub' { $s="r$($Step.d) = sub(r$($Step.s),r$($Step.t))" }
        'lsr-i' { $s="r$($Step.d) = lsr(r$($Step.s),#$($Step.i))" }
        'asl-i' { $s="r$($Step.d) = asl(r$($Step.s),#$($Step.i))" }
        'asr-d-i' { $s="r$($Step.d+1):$($Step.d) = asr(r$($Step.s+1):$($Step.s),#$($Step.i))" }
        'vasr-w' { $s="v$($Step.d).w = vasr(v$($Step.s).w,r$($Step.t))" }
        'vasl-w' { $s="v$($Step.d).w = vasl(v$($Step.s).w,r$($Step.t))" }
        'vmax-w' { $s="v$($Step.d).w = vmax(v$($Step.s).w,v$($Step.t).w)" }
        'vmin-w' { $s="v$($Step.d).w = vmin(v$($Step.s).w,v$($Step.t).w)" }
        'vor' { $s="v$($Step.d) = vor(v$($Step.s),v$($Step.t))" }
        'vsub-w' { $s="v$($Step.d).w = vsub(v$($Step.s).w,v$($Step.t).w)" }
        'vmpy-h-rnd-sat' { $s="v$($Step.d).h = vmpy(v$($Step.s).h,v$($Step.t).h):<<1:rnd:sat" }
        'vadd-h' { $s="v$($Step.d).h = vadd(v$($Step.s).h,v$($Step.t).h)" }
        'vadd-h-sat' { $s="v$($Step.d).h = vadd(v$($Step.s).h,v$($Step.t).h):sat" }
        'vsub-h' { $s="v$($Step.d).h = vsub(v$($Step.s).h,v$($Step.t).h)" }
        'vabs-h-sat' { $s="v$($Step.d).h = vabs(v$($Step.s).h):sat" }
        'vasr-h' { $s="v$($Step.d).h = vasr(v$($Step.s).h,r$($Step.t))" }
        'vasl-h' { $s="v$($Step.d).h = vasl(v$($Step.s).h,r$($Step.t))" }
        'vsplat-h' { $s="v$($Step.d).h = vsplat(r$($Step.s))" }
        'vlut16' { $s="v$($Step.d+1):$($Step.d).h = vlut16(v$($Step.s).b,v$($Step.v).h,r$($Step.x))" }
        'vlut16-or' { $s="v$($Step.d+1):$($Step.d).h |= vlut16(v$($Step.s).b,v$($Step.v).h,r$($Step.x))" }
        'vmpy-sf-qf32'   { $s = "v$($Step.d).qf32 = vmpy(v$($Step.s).sf,v$($Step.t).sf)" }
        'vadd-sf-qf32'   { $s = "v$($Step.d).qf32 = vadd(v$($Step.s).sf,v$($Step.t).sf)" }
        'vconv-qf32-sf'  { $s = "v$($Step.d).sf = v$($Step.s).qf32" }
        'vsplat'         { $s = "v$($Step.d) = vsplat(r$($Step.s))" }
        'vand'           { $s = "v$($Step.d) = vand(v$($Step.s),v$($Step.t))" }
        'vxor'           { $s = "v$($Step.d) = vxor(v$($Step.s),v$($Step.t))" }
        'valign'         {
            $reg = if ($Step.ContainsKey('x')) { $Step.x } elseif ($Step.ContainsKey('r')) { $Step.r } else { 0 }
            $s = "v$($Step.d) = valign(v$($Step.s),v$($Step.t),r$reg)"
        }
        'valign-imm'     { $s = "v$($Step.d) = valign(v$($Step.s),v$($Step.t),#$($Step.i))" }
        'vshuff'         { $s = "v$($Step.d + 1):$($Step.d) = vshuff(v$($Step.s),v$($Step.t),r$($Step.r))" }
        'trap0'          { $s = "trap0(#$($Step.i))" }
        'pcycle'         { $s = "r$($Step.d + 1):$($Step.d) = pcycle" }
        'hwticks'        { $s = "r$($Step.d + 1):$($Step.d) = c31:30" }
        'store-d'        { $s = "memd(r$($Step.s)+#$($Step.Offset)) = r$($Step.t + 1):$($Step.t)" }
        'mxclracc'       { $s = "mxclracc" }
        'mxclracc.hf'    { $s = "mxclracc.hf" }
        'cvt-hf'         { $s = "cvt.hf = acc(r$($Step.s))" }
        'cvt-ub'         { $s = "cvt.ub = acc(r$($Step.s))" }
        'cvt-ub-sc0'     { $s = "cvt.ub = acc(r$($Step.s)):sc0" }
        'cvt-ub-sc1'     { $s = "cvt.ub = acc(r$($Step.s)):sc1" }
        'mxmem-cvt'      { $s = "mxmem(r$($Step.s),r$($Step.t)) = cvt" }
        'mxmem-after-hf' { $s = "mxmem(r$($Step.s),r$($Step.t)):after.hf = acc" }
        'mxmem-after-retain-cm-ub' { $s = "mxmem(r$($Step.s),r$($Step.t)):after:retain:cm.ub = acc" }
        'mxmem-after-sat-ub' { $s = "mxmem(r$($Step.s),r$($Step.t)):after:sat.ub = acc" }
        'mxmem-after-retain-sat-ub' { $s = "mxmem(r$($Step.s),r$($Step.t)):after:retain:sat.ub = acc" }
        'mxmem-after-ub' { $s = "mxmem(r$($Step.s),r$($Step.t)):after.ub = acc" }
        'got-call' {
            # Delta (GOT slot - pc) is filled in after layout by the emitter for independent assembly.
            if ($null -eq $Step.Delta) { throw 'got-call assembly needs the resolved Delta' }
            return "{ r$($Step.d) = add(pc,##$($Step.Delta)) }`n{ r$($Step.d) = memw(r$($Step.d)+#0) }`n{ callr r$($Step.d) }"
        }
        'allocframe'     { $s = "allocframe(#$($Step.Bytes))" }
        'dealloc-return' { $s = 'dealloc_return' }
        'add-pc'         { $s = "r$($Step.d) = add(pc,#$($Step.i))" }
        'load-d'         { $s = "r$($Step.d + 1):$($Step.d) = memd(r$($Step.s)+#$($Step.Offset))" }
        'callr'          { $s = "callr r$($Step.s)" }
        'syncht'         { $s = 'syncht' }
        'dmstart'        { $s = "dmstart(r$($Step.s))" }
        'dmlink'         { $s = "dmlink(r$($Step.s),r$($Step.t))" }
        'dmwait'         { $s = "r$($Step.d) = dmwait" }
        'dmpoll'         { $s = "r$($Step.d) = dmpoll" }
        'release-at'     { $s = "release(r$($Step.s)):at" }
        'load-ub'        { $s = "r$($Step.d) = memub(r$($Step.s)+#$($Step.Offset))" }
        'store-h'        { $s = "memh(r$($Step.s)+#$($Step.Offset)) = r$($Step.t)" }
        'max'            { $s = "r$($Step.d) = max(r$($Step.s),r$($Step.t))" }
        'min'            { $s = "r$($Step.d) = min(r$($Step.s),r$($Step.t))" }
        'asr-i'          { $s = "r$($Step.d) = asr(r$($Step.s),#$($Step.i))" }
        'hmx-pair' {
            $act = @{ 'act-hf'='activation.hf'; 'act-ub'='activation.ub'; 'act-ub-cm'='activation.ub'; 'act-ub-single'='activation.ub' }[$Step.Act]
            $actSuffix = @{ 'act-hf'=''; 'act-ub'=''; 'act-ub-cm'=':cm'; 'act-ub-single'=':single' }[$Step.Act]
            $wt = @{ 'wt-hf'='weight.hf'; 'wt-b'='weight.b'; 'wt-n'='weight.n'; 'wt-b-deep'='weight.b' }[$Step.Wt]
            $wtSuffix = if ($Step.Wt -eq 'wt-b-deep') { ':deep' } else { '' }
            return "{`n`t$act = mxmem(r$($Step.s),r$($Step.t))$actSuffix`n`t$wt = mxmem(r$($Step.u),r$($Step.v))$wtSuffix`n}"
        }
        'bias-mxmem'     { $s = "bias = mxmem(r$($Step.s))" }
        'bias-mxmem2'    { $s = "bias = mxmem2(r$($Step.s))" }
        { $_ -in 'mxmpy-fp16','mxmpy-w8a8','mxmpy-w4a8','mxmpy-w8a8-cm','mxmpy-w4a8-cm' } {
            $actType = if ($Step.Op -eq 'mxmpy-fp16') { 'hf' } else { 'ub' }
            $actSuffix = if ($Step.Op.EndsWith('-cm')) { ':cm' } else { '' }
            $wtType  = if ($Step.Op -eq 'mxmpy-fp16') { 'hf' } elseif ($Step.Op.StartsWith('mxmpy-w8a8')) { 'b' } else { 'n' }
            return "{`n`tactivation.$actType = mxmem(r$($Step.s),r$($Step.t))$actSuffix`n`tweight.$wtType = mxmem(r$($Step.u),r$($Step.v))`n}"
        }
        'return'         { $s = 'jumpr r31' }
        default { throw "Unsupported operation: $($Step.Op)" }
    }
    "{ $s }"
}

function New-HexagonProbeSteps {
    # SDK 6.4.0.2 qaic handle ABI: (uint64 handle, uint32 scalars, remote_arg *args)
    # arrives in r1:r0, r2, r3. remote_arg is 8 bytes on the DSP.
    # Method 0 opens a stateless handle, method 1 closes, method 2 adds two int32s.
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
