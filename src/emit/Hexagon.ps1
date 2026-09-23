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
    'sfadd'  = '11101011000sssssPP0ttttt000ddddd'
    'sfmpy'  = '11101011010sssssPP0ttttt000ddddd'
    'return' = '01010010100sssssPP--------------'
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
        'jump-p' {
            $delta = $Target - $Pc
            if ($delta % 4 -ne 0 -or $delta -lt -65536 -or $delta -gt 65532) { throw 'Branch out of range' }
            $fields.i = ([long]$delta / 4) -band 32767
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
        Length={ param($Step) if ($Step.Op -eq 'label') { 0 } else { 4 } }
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
        'sfadd' { $s = "r$($Step.d) = sfadd(r$($Step.s),r$($Step.t))" }
        'sfmpy' { $s = "r$($Step.d) = sfmpy(r$($Step.s),r$($Step.t))" }
        'return' { $s = 'jumpr r31' }
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
