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
    'and'            = '11110001000sssssPP0ttttt000ddddd'
    'xor'            = '11110001011sssssPP0ttttt000ddddd'
    'conv-sf2w-chop' = '10001011100sssssPP000000001ddddd'
    'conv-w2sf'      = '10001011010sssssPP000000000ddddd'
    'vload'          = '00101000000sssssPPiiiiii---ddddd'
    'vload-post'     = '00101001000sssssPPiiiiii---ddddd'
    'vstore'         = '00101000001sssssPPiiiiii---ttttt'
    'vstore-post'    = '00101001001sssssPPiiiiii---ttttt'
    'vadd-sf'        = '00011111100tttttPP1sssss110ddddd'
    'vsub-sf'        = '00011111100tttttPP1sssss111ddddd'
    'vmpy-sf'        = '00011111100tttttPP1sssss001ddddd'
    'vsplat'         = '00011001101sssssPP000000001ddddd'
    'vand'           = '00011100001tttttPP0sssss101ddddd'
    'vxor'           = '00011100001tttttPP0sssss111ddddd'
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
    'return'         = '01010010100sssssPP--------------'
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
    foreach ($key in 'd','s','t','x','u') { if ($Step.ContainsKey($key)) { $fields[$key] = $Step[$key] } }
    switch ($Step.Op) {
        { $_ -in 'imm','addi' } {
            if ($Step.i -lt -32768 -or $Step.i -gt 32767) { throw 'Signed immediate out of range' }
            $fields.i = [long]$Step.i -band 65535
        }
        { $_ -in 'lo','hi' } { $fields.i = $Step.i }
        { $_ -in 'load','store' } {
            if ($Step.Offset % 4 -ne 0 -or $Step.Offset -lt -4096 -or $Step.Offset -gt 4092) { throw 'Word offset out of range' }
            $fields.i = ([long]$Step.Offset / 4) -band 2047
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
        { $_ -in 'mxmem-cvt','mxmem-after-hf','mxmem-after-retain-cm-ub' } {
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
            elseif ($Step.Op -in 'mxmpy-fp16','mxmpy-w8a8','mxmpy-w4a8','mxmpy-w8a8-cm','mxmpy-w4a8-cm') { 8 }
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
        'and'            { $s = "r$($Step.d) = and(r$($Step.s),r$($Step.t))" }
        'xor'            { $s = "r$($Step.d) = xor(r$($Step.s),r$($Step.t))" }
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
