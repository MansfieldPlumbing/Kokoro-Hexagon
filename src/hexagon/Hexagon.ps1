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
    # V73 PRM 80-N2040-53 Rev. AB pp.195,146: register-count hardware loops.
    'loop0-r' = '01100000000sssssPP-iiiii---ii---'
    'loop1-r' = '01100000001sssssPP-iiiii---ii---'
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
    # SDK 19.0.04, V73 +hvx-ieee-fp: generator FP16 crouton register conversion.
    'vmpy-hf-qf32'   = '00011111111tttttPP1sssss111ddddd'
    'vconv-qf32-hf'  = '00011110--0--100PP1sssss110ddddd'
    'vshuffe-h'      = '00011111010tttttPP0sssss011ddddd'
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
    # Per-lane shifts by a vector of signed 6-bit amounts, and halfword min/max: SDK 6.4.0.2 hexagon-llvm-mc
    # encodings; semantics V73 HVX PRM 80-N2040-54 Rev. AB (vasr: amount > 0 shifts right, else left).
    'vasr-wv'        = '00011111101tttttPP0sssss000ddddd'
    'vlsr-wv'        = '00011111101tttttPP0sssss001ddddd'
    'vasr-hv'        = '00011111101tttttPP0sssss011ddddd'
    'vasl-wv'        = '00011111101tttttPP0sssss100ddddd'
    'vmin-h'         = '00011111000tttttPP0sssss011ddddd'
    'vmax-h'         = '00011111000tttttPP0sssss111ddddd'
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
    # Q31 multiply pair (vmpye then accumulating vmpyo); d of the accumulating form is read and written.
    'vmpye-w-uh' = '00011111111tttttPP0sssss101ddddd'
    'vmpyo-acc-w-h-rnd-sat-shift' = '00011100001tttttPP1sssss111ddddd'
    # Widening 16x16 multiply-accumulate into a vector pair (d even): Vdd.w += vmpy(Vu.h, Vv.h | Rt.h).
    'vmpy-acc-ww-h-h' = '00011100000tttttPP1sssss111ddddd'
    'vmpy-acc-ww-h-r' = '00011001101tttttPP1sssss110ddddd'
    'vlut16'         = '00011011vvvvvxxxPP1sssss110ddddd'
    'vlut16-or'      = '00011011vvvvvxxxPP1sssss111ddddd'
    'valign'         = '00011011tttttxxxPP0sssss000ddddd'
    'valign-imm'     = '00011110001tttttPP1sssssiiiddddd'
    'vshuff'         = '00011011tttttrrrPP1sssss011ddddd'
    'trap0'          = '0101010000000000PP0iiiii000iii00'
    'pcycle'         = '0110111100011110PP000000000ddddd'
    'hwticks'        = '0110100000011110PP000000000ddddd'
    # User cycle counter UPCYCLE (c15:14): SDK 6.4.0.2 hexagon-llvm-mc (V73) r7:6 = upcycle -> 0x680EC006.
    # V73 PRM 80-N2040-53 Rev. AB section 2.2.9: reads return zero unless the RTOS enables user access.
    'upcycle'        = '0110100000001110PP000000000ddddd'
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
    'act-hf-single'  = '10010010000sssssPP0ttttt11111000'
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

# Managed encoding uses the same forms and validation as the reference below.
# Fixed bits and field positions are indexed once, rather than rescanned for
# every round-trip check. The form array retains the reference table's order.
class HexagonForm {
    [string] $Name
    [int[]] $Pattern
    [int[]] $Counts
    [long] $Mask
    [long] $Bits

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

class HexagonEncoder {
    [HexagonForm[]] $Forms
    [System.Collections.Generic.Dictionary[string,HexagonForm]] $ByName

    HexagonEncoder([string[]] $Names, [string[]] $Patterns) {
        $this.Forms = [HexagonForm[]]::new($Names.Length)
        $this.ByName = [System.Collections.Generic.Dictionary[string,HexagonForm]]::new([StringComparer]::InvariantCultureIgnoreCase)
        for ([int]$n = 0; $n -lt $Names.Length; $n++) {
            [HexagonForm] $form = [HexagonForm]::new($Names[$n], $Patterns[$n])
            $this.Forms[$n] = $form
            $this.ByName.Add($Names[$n], $form)
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

    static [int] Length([HexagonStep] $Step) {
        if ($Step.Op -eq 'label') { return 0 }
        if ($Step.Op -eq 'endloop0') { return 8 }
        if ($Step.Op -eq 'endloop1') { return 12 }
        if ($Step.Op -in 'mxmpy-fp16','mxmpy-w8a8','mxmpy-w4a8','mxmpy-w8a8-cm','mxmpy-w4a8-cm','hmx-pair') { return 8 }
        if ($Step.Op -eq 'got-call') { return 16 }
        return 4
    }

    static [HexagonLayout] Layout([HexagonStep[]] $Steps, [long] $Base) {
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
            [int] $length = [HexagonEncoder]::Length($step)
            $layout.Lengths[$n] = $length
            $layout.Size = $layout.Size + [long]$length
        }
        $layout.Imports = $imports.ToArray()
        return $layout
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

    static [void] Relocate([HexagonLayout] $Layout, [long] $Base) {
        [string[]] $keys = [string[]]::new($Layout.Labels.Count)
        $Layout.Labels.Keys.CopyTo($keys, 0)
        foreach ($key in $keys) { $Layout.Labels.set_Item($key, $Layout.Labels.get_Item($key) + $Base) }
    }

    [byte[]] Instruction([HexagonStep] $Step, [long] $Pc, [long] $Target) {
        if ($Step.Op -eq 'label') { return [byte[]]::new(0) }
        [HexagonFields] $fields = [HexagonFields]::new()
        $fields.Set('P', 3L)
        foreach ($key in [string[]]@('d','s','t','x','u','e')) { if ($Step.ContainsKey($key)) { $fields.Set($key, $Step.Get($key)) } }
        switch ($Step.Op) {
            { $_ -in 'loop0-r','loop1-r' } {
                [long] $loopDelta = $Target-$Pc
                if ($loopDelta % 4L -ne 0L -or $loopDelta -lt -256L -or $loopDelta -gt 252L) { throw 'Hardware loop start out of range or unaligned' }
                $fields.Set('i', [long]($loopDelta/4L) -band 127L)
            }
            { $_ -in 'endloop0','endloop1' } {
                # The required loop-end packet contains only preserving adds.
                # This admits loop control without bundling arithmetic work.
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
            'vmpy-hf-qf32' {
                if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'FP32 conversion destination pair must be even and 0..30' }
            }
            'vconv-qf32-hf' {
                if ($Step.s % 2 -ne 0 -or $Step.s -lt 0 -or $Step.s -gt 30) { throw 'QFloat source pair must be even and 0..30' }
            }
            { $_ -in 'mpyu-d','mpy-d','add-d','sub-d','gtu-d','asr-d-i' } {
                [string[]] $pairs = [string[]]@('d','s','t')
                if ($Step.Op -in 'mpyu-d','mpy-d') { $pairs = [string[]]@('d') }
                elseif ($Step.Op -eq 'gtu-d') { $pairs = [string[]]@('s','t') }
                elseif ($Step.Op -eq 'asr-d-i') { $pairs = [string[]]@('d','s') }
                foreach ($r in $pairs) { if ($Step.Get($r) % 2L -ne 0L -or $Step.Get($r) -lt 0L -or $Step.Get($r) -gt 30L) { throw 'Integer register pair must be even and 0..30' } }
                if ($Step.Op -eq 'asr-d-i') {
                    if ($Step.i -lt 0L -or $Step.i -gt 63L) { throw 'Double-word shift out of range' }
                    $fields.Set('i', $Step.i)
                }
            }
            { $_ -in 'lsr-i','asl-i','asr-i' } {
                if ($Step.i -lt 0L -or $Step.i -gt 31L) { throw 'Word shift out of range' }
                $fields.Set('i', $Step.i)
            }
            { $_ -in 'imm','addi' } {
                if ($Step.i -lt -32768L -or $Step.i -gt 32767L) { throw 'Signed immediate out of range' }
                $fields.Set('i', $Step.i -band 65535L)
            }
            { $_ -in 'lo','hi' } { $fields.Set('i', $Step.i) }
            { $_ -in 'load','store' } {
                if ($Step.Offset % 4L -ne 0L -or $Step.Offset -lt -4096L -or $Step.Offset -gt 4092L) { throw 'Word offset out of range' }
                $fields.Set('i', ([long]($Step.Offset / 4L)) -band 2047L)
            }
            'load-ub' {
                if ($Step.Offset -lt -1024L -or $Step.Offset -gt 1023L) { throw 'Byte offset out of range' }
                $fields.Set('i', $Step.Offset -band 2047L)
            }
            'store-h' {
                if ($Step.Offset % 2L -ne 0L -or $Step.Offset -lt -2048L -or $Step.Offset -gt 2046L) { throw 'Halfword offset out of range or unaligned' }
                $fields.Set('i', ([long]($Step.Offset / 2L)) -band 2047L)
            }
            { $_ -in 'vload','vstore' } {
                [int] $vOff = 0
                if ($Step.ContainsKey('Offset')) {
                    if ($Step.Offset % 128L -ne 0L) { throw 'Vector offset must be multiple of 128 bytes' }
                    $vOff = [int]($Step.Offset / 128L)
                } elseif ($Step.ContainsKey('i')) { $vOff = [int]$Step.i }
                if ($vOff -lt -8 -or $vOff -gt 7) { throw 'Vector immediate offset out of range (-8..7)' }
                if ($vOff -ge 0) { $fields.Set('i', [long]$vOff) } else { $fields.Set('i', (1L -shl 5) -bor ([long]$vOff -band 7L)) }
            }
            { $_ -in 'vload-post','vstore-post' } {
                [int] $vOff = 1
                if ($Step.ContainsKey('i')) { $vOff = [int]$Step.i }
                if ($vOff -lt -8 -or $vOff -gt 7) { throw 'Vector post-increment offset out of range (-8..7)' }
                if ($vOff -ge 0) { $fields.Set('i', [long]$vOff) } else { $fields.Set('i', (1L -shl 5) -bor ([long]$vOff -band 7L)) }
            }
            'jump-p' {
                [long] $delta = $Target - $Pc
                if ($delta % 4L -ne 0L -or $delta -lt -65536L -or $delta -gt 65532L) { throw 'Branch out of range' }
                $fields.Set('i', ([long]($delta / 4L)) -band 32767L)
            }
            'valign' {
                if ($Step.ContainsKey('r')) { $fields.Set('x', [long]$Step.r) }
                if ($fields.Get('x') -lt 0L -or $fields.Get('x') -gt 7L) { throw 'Valign register out of range (r0..r7)' }
            }
            { $_ -in 'vlut16','vlut16-or' } {
                if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Lookup destination pair must be even and 0..30' }
                if ($Step.x -lt 0 -or $Step.x -gt 7) { throw 'Lookup scalar control must be r0..7' }
                if ($Step.v -lt 0 -or $Step.v -gt 31) { throw 'Lookup table vector out of range' }
                $fields.Set('v', [long]$Step.v)
            }
            'valign-imm' {
                if ($Step.i -lt 0L -or $Step.i -gt 7L) { throw 'Valign immediate out of range (0..7)' }
                $fields.Set('i', $Step.i)
            }
            'vshuff' {
                if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Vshuff destination register pair must be even and 0..30' }
                if ($Step.s -lt 0 -or $Step.s -gt 31 -or $Step.t -lt 0 -or $Step.t -gt 31) { throw 'Vshuff source register out of range (0..31)' }
                if ($Step.r -lt 0 -or $Step.r -gt 7) { throw 'Vshuff scalar register out of range (r0..r7)' }
                $fields.Set('d', [long]$Step.d); $fields.Set('s', [long]$Step.s); $fields.Set('t', [long]$Step.t); $fields.Set('r', [long]$Step.r)
            }
            'trap0' {
                if ($Step.i -lt 0L -or $Step.i -gt 255L) { throw 'Trap0 immediate out of range (0..255)' }
                $fields.Set('i', $Step.i)
            }
            { $_ -in 'pcycle','hwticks','upcycle' } {
                if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Pcycle/Hwticks destination register pair must be even and 0..30' }
                $fields.Set('d', [long]$Step.d)
            }
            'store-d' {
                if ($Step.Offset % 8L -ne 0L -or $Step.Offset -lt -8192L -or $Step.Offset -gt 8184L) { throw 'Double word offset out of range or unaligned' }
                if ($Step.t % 2 -ne 0 -or $Step.t -lt 0 -or $Step.t -gt 30) { throw 'Store-d source register pair must be even and 0..30' }
                $fields.Set('i', ([long]($Step.Offset / 8L)) -band 2047L); $fields.Set('t', [long]$Step.t); $fields.Set('s', [long]$Step.s)
            }
            { $_ -in 'cvt-hf','cvt-ub','cvt-ub-sc0','cvt-ub-sc1' } {
                if ($Step.s -lt 0 -or $Step.s -gt 31) { throw 'Cvt source register out of range (0..31)' }
                $fields.Set('s', [long]$Step.s)
            }
            'got-call' {
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
            'allocframe' {
                if ($Step.Bytes % 8L -ne 0L -or $Step.Bytes -lt 0L -or $Step.Bytes -gt 16376L) { throw 'Frame size must be a multiple of 8 up to 16376' }
                $fields.Set('i', [long]($Step.Bytes / 8L))
            }
            'add-pc' {
                if ($Step.i -lt 0L -or $Step.i -gt 63L) { throw 'add(pc) immediate out of range (0..63)' }
                $fields.Set('i', $Step.i)
            }
            'load-d' {
                if ($Step.Offset % 8L -ne 0L -or $Step.Offset -lt -8192L -or $Step.Offset -gt 8184L) { throw 'Double word offset out of range or unaligned' }
                if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'Load-d destination register pair must be even and 0..30' }
                $fields.Set('i', ([long]($Step.Offset / 8L)) -band 2047L)
            }
            'hmx-pair' {
                if ($Step.Act -notin 'act-hf','act-hf-single','act-ub','act-ub-cm','act-ub-single') { throw ('Unsupported HMX activation form: ' + $Step.Act) }
                if ($Step.Wt -notin 'wt-hf','wt-b','wt-n','wt-b-deep') { throw ('Unsupported HMX weight form: ' + $Step.Wt) }
                foreach ($r in [string[]]@('s','t','u','v')) { if ($Step.Get($r) -lt 0L -or $Step.Get($r) -gt 31L) { throw ('HMX register ' + $r + ' out of range (0..31)') } }
                return $this.Packet($Step.Act, $Step.Wt, $Step, 'HMX packet failed round-trip decode')
            }
            { $_ -in 'mxmem-cvt','mxmem-after-hf','mxmem-after-retain-cm-ub','mxmem-after-sat-ub','mxmem-after-retain-sat-ub','mxmem-after-ub' } {
                if ($Step.s -lt 0 -or $Step.s -gt 31) { throw 'Mxmem-cvt base register out of range (0..31)' }
                if ($Step.t -lt 0 -or $Step.t -gt 31) { throw 'Mxmem-cvt stride register out of range (0..31)' }
                $fields.Set('s', [long]$Step.s); $fields.Set('t', [long]$Step.t)
            }
            { $_ -in 'bias-mxmem','bias-mxmem2' } {
                if ($Step.s -lt 0 -or $Step.s -gt 31) { throw 'Bias address register out of range (0..31)' }
                $fields.Set('s', [long]$Step.s)
            }
            { $_ -in 'mxmpy-fp16','mxmpy-w8a8','mxmpy-w4a8','mxmpy-w8a8-cm','mxmpy-w4a8-cm' } {
                if ($Step.s -lt 0 -or $Step.s -gt 31 -or $Step.t -lt 0 -or $Step.t -gt 31) { throw 'HMX activation registers out of range (0..31)' }
                if ($Step.u -lt 0 -or $Step.u -gt 31 -or $Step.v -lt 0 -or $Step.v -gt 31) { throw 'HMX weight registers out of range (0..31)' }
                [string] $actForm = 'act-ub'
                if ($Step.Op -eq 'mxmpy-fp16') { $actForm = 'act-hf' } elseif ($Step.Op.EndsWith('-cm')) { $actForm = 'act-ub-cm' }
                [string] $wtForm = 'wt-n'
                if ($Step.Op -eq 'mxmpy-fp16') { $wtForm = 'wt-hf' } elseif ($Step.Op.StartsWith('mxmpy-w8a8')) { $wtForm = 'wt-b' }
                return $this.Packet($actForm, $wtForm, $Step, 'HMX dual-slot packet failed round-trip decode')
            }
            'return' { $fields.Set('s', 31L) }
        }
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
        { $_ -in 'loop0-r','loop1-r' } {
            $loopDelta = $Target-$Pc
            if ($loopDelta % 4L -ne 0L -or $loopDelta -lt -256L -or $loopDelta -gt 252L) { throw 'Hardware loop start out of range or unaligned' }
            $fields.i = [long]($loopDelta/4L) -band 127L
        }
        { $_ -in 'endloop0','endloop1' } {
            $words = if ($Step.Op -eq 'endloop0') { 2 } else { 3 }
            $loopBytes = [byte[]]::new(4*$words)
            for ($loopWord=0; $loopWord -lt $words; $loopWord++) {
                $reg = 16-$words+$loopWord
                $parse = if ($loopWord -eq $words-1) { 3L } elseif (($words -eq 2 -and $loopWord -eq 0) -or ($words -eq 3 -and $loopWord -eq 1)) { 2L } else { 1L }
                $word = ConvertTo-HexagonWord 'addi' @{s=[long]$reg;d=[long]$reg;i=0L;P=$parse}
                [Array]::Copy([BitConverter]::GetBytes([uint32]$word),0,$loopBytes,4*$loopWord,4)
            }
            return $loopBytes
        }
        'vmpy-hf-qf32' {
            if ($Step.d % 2 -ne 0 -or $Step.d -lt 0 -or $Step.d -gt 30) { throw 'FP32 conversion destination pair must be even and 0..30' }
        }
        'vconv-qf32-hf' {
            if ($Step.s % 2 -ne 0 -or $Step.s -lt 0 -or $Step.s -gt 30) { throw 'QFloat source pair must be even and 0..30' }
        }
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
        { $_ -in 'pcycle', 'hwticks', 'upcycle' } {
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
            if ($Step.Act -notin 'act-hf','act-hf-single','act-ub','act-ub-cm','act-ub-single') { throw "Unsupported HMX activation form: $($Step.Act)" }
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
            elseif ($Step.Op -eq 'endloop0') { 8 }
            elseif ($Step.Op -eq 'endloop1') { 12 }
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
        'loop0-r' { $s = "loop0($($Step.Label),r$($Step.s))" }
        'loop1-r' { $s = "loop1($($Step.Label),r$($Step.s))" }
        'endloop0' { return '{ r14 = add(r14,#0); r15 = add(r15,#0) }:endloop0' }
        'endloop1' { return '{ r13 = add(r13,#0); r14 = add(r14,#0); r15 = add(r15,#0) }:endloop1' }
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
        'vmpy-hf-qf32'   { $s = "v$($Step.d+1):$($Step.d).qf32 = vmpy(v$($Step.s).hf,v$($Step.t).hf)" }
        'vconv-qf32-hf'  { $s = "v$($Step.d).hf = v$($Step.s+1):$($Step.s).qf32" }
        'vshuffe-h'      { $s = "v$($Step.d).h = vshuffe(v$($Step.s).h,v$($Step.t).h)" }
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
        'vasr-wv' { $s="v$($Step.d).w = vasr(v$($Step.s).w,v$($Step.t).w)" }
        'vlsr-wv' { $s="v$($Step.d).w = vlsr(v$($Step.s).w,v$($Step.t).w)" }
        'vasr-hv' { $s="v$($Step.d).h = vasr(v$($Step.s).h,v$($Step.t).h)" }
        'vasl-wv' { $s="v$($Step.d).w = vasl(v$($Step.s).w,v$($Step.t).w)" }
        'vmin-h' { $s="v$($Step.d).h = vmin(v$($Step.s).h,v$($Step.t).h)" }
        'vmax-h' { $s="v$($Step.d).h = vmax(v$($Step.s).h,v$($Step.t).h)" }
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
        'vmpye-w-uh' { $s="v$($Step.d).w = vmpye(v$($Step.s).w,v$($Step.t).uh)" }
        'vmpyo-acc-w-h-rnd-sat-shift' { $s="v$($Step.d).w += vmpyo(v$($Step.s).w,v$($Step.t).h):<<1:rnd:sat:shift" }
        'vmpy-acc-ww-h-h' { if ($Step.d % 2) { throw 'Vector pair register must be even' }; $s="v$($Step.d+1):$($Step.d).w += vmpy(v$($Step.s).h,v$($Step.t).h)" }
        'vmpy-acc-ww-h-r' { if ($Step.d % 2) { throw 'Vector pair register must be even' }; $s="v$($Step.d+1):$($Step.d).w += vmpy(v$($Step.s).h,r$($Step.t).h)" }
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
        'upcycle'        { $s = "r$($Step.d + 1):$($Step.d) = upcycle" }
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
            $act = @{ 'act-hf'='activation.hf'; 'act-hf-single'='activation.hf'; 'act-ub'='activation.ub'; 'act-ub-cm'='activation.ub'; 'act-ub-single'='activation.ub' }[$Step.Act]
            $actSuffix = @{ 'act-hf'=''; 'act-hf-single'=':single'; 'act-ub'=''; 'act-ub-cm'=':cm'; 'act-ub-single'=':single' }[$Step.Act]
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
