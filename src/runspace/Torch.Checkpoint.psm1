param()

# Reads a torch.save v1.6+ checkpoint (a zip holding one pickle plus raw storages) and
# returns the state_dict as tensor descriptors. Only the opcodes torch emits are
# implemented; anything else throws rather than guessing.
# Pickle opcode values follow CPython Lib/pickle.py.

$dtypeOf = @{
    'FloatStorage'  = @{ Name = 'float32'; Bytes = 4 }
    'DoubleStorage' = @{ Name = 'float64'; Bytes = 8 }
    'HalfStorage'   = @{ Name = 'float16'; Bytes = 2 }
    'LongStorage'   = @{ Name = 'int64';   Bytes = 8 }
    'IntStorage'    = @{ Name = 'int32';   Bytes = 4 }
    'ShortStorage'  = @{ Name = 'int16';   Bytes = 2 }
    'CharStorage'   = @{ Name = 'int8';    Bytes = 1 }
    'ByteStorage'   = @{ Name = 'uint8';   Bytes = 1 }
    'BoolStorage'   = @{ Name = 'bool';    Bytes = 1 }
    'BFloat16Storage' = @{ Name = 'bfloat16'; Bytes = 2 }
}

$unpickle = {
    param([byte[]]$Data)

    $stack = [Collections.Generic.List[object]]::new()
    $memo  = [Collections.Generic.Dictionary[int,object]]::new()
    $marks = [Collections.Generic.Stack[int]]::new()
    [int]$i = 0
    [int]$n = $Data.Length

    # No helper closure here: GetNewClosure() snapshots $i, so a closure would advance
    # its own copy of the cursor and leave the real one behind.
    while ($i -lt $n) {
        [byte]$op = $Data[$i]; $i++
        switch ($op) {
            0x80 { $i++ }                                              # PROTO
            0x95 { $i += 8 }                                           # FRAME
            0x28 { $marks.Push($stack.Count) }                         # MARK
            0x4e { $stack.Add($null) }                                 # NONE
            0x88 { $stack.Add($true) }                                 # NEWTRUE
            0x89 { $stack.Add($false) }                                # NEWFALSE
            0x4b { $stack.Add([int]$Data[$i]); $i++ }                  # BININT1
            0x4d { $stack.Add([int][BitConverter]::ToUInt16($Data,$i)); $i += 2 }   # BININT2
            0x4a { $stack.Add([int][BitConverter]::ToInt32($Data,$i)); $i += 4 }    # BININT
            0x8a {                                                     # LONG1
                [int]$len = $Data[$i]; $i++
                [long]$v = 0
                for ([int]$k = $len - 1; $k -ge 0; $k--) { $v = ($v -shl 8) -bor $Data[$i + $k] }
                $i += $len; $stack.Add($v)
            }
            0x8c {                                                     # SHORT_BINUNICODE
                [int]$len = $Data[$i]; $i++
                $stack.Add([Text.Encoding]::UTF8.GetString($Data, $i, $len)); $i += $len
            }
            0x58 {                                                     # BINUNICODE
                [int]$len = [BitConverter]::ToInt32($Data, $i); $i += 4
                $stack.Add([Text.Encoding]::UTF8.GetString($Data, $i, $len)); $i += $len
            }
            0x71 { $memo[[int]$Data[$i]] = $stack[$stack.Count - 1]; $i++ }          # BINPUT
            0x72 { $memo[[BitConverter]::ToInt32($Data,$i)] = $stack[$stack.Count-1]; $i += 4 } # LONG_BINPUT
            0x68 { $stack.Add($memo[[int]$Data[$i]]); $i++ }                          # BINGET
            0x6a { $stack.Add($memo[[BitConverter]::ToInt32($Data,$i)]); $i += 4 }    # LONG_BINGET
            0x63 {                                                     # GLOBAL: module\nname\n
                [int]$s0 = $i
                while ($i -lt $n -and $Data[$i] -ne 10) { $i++ }
                $module = [Text.Encoding]::ASCII.GetString($Data, $s0, $i - $s0); $i++
                [int]$s1 = $i
                while ($i -lt $n -and $Data[$i] -ne 10) { $i++ }
                $name = [Text.Encoding]::ASCII.GetString($Data, $s1, $i - $s1); $i++
                $stack.Add([pscustomobject]@{ Kind = 'global'; Module = $module; Name = $name })
            }
            0x93 {                                                     # STACK_GLOBAL
                $name = $stack[$stack.Count - 1]; $stack.RemoveAt($stack.Count - 1)
                $module = $stack[$stack.Count - 1]; $stack.RemoveAt($stack.Count - 1)
                $stack.Add([pscustomobject]@{ Kind = 'global'; Module = $module; Name = $name })
            }
            0x51 {                                                     # BINPERSID
                $pid = $stack[$stack.Count - 1]; $stack.RemoveAt($stack.Count - 1)
                # ('storage', <StorageType global>, key, location, numel)
                $storageType = $pid[1]
                $stack.Add([pscustomobject]@{
                    Kind = 'storage'; StorageType = $storageType.Name
                    Key = [string]$pid[2]; Location = [string]$pid[3]; Numel = [long]$pid[4]
                })
            }
            0x29 { $stack.Add(@()) }                                   # EMPTY_TUPLE
            0x85 { $t = @($stack[$stack.Count-1]); $stack.RemoveAt($stack.Count-1); $stack.Add($t) }   # TUPLE1
            0x86 {                                                     # TUPLE2
                $b = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $a = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $stack.Add(@($a, $b))
            }
            0x87 {                                                     # TUPLE3
                $c = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $b = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $a = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $stack.Add(@($a, $b, $c))
            }
            0x74 {                                                     # TUPLE
                # Built through a List, not @(...): the subexpression operator flattens a
                # nested tuple (the size tuple) into the outer one.
                [int]$m = $marks.Pop()
                $items = [Collections.Generic.List[object]]::new()
                for ([int]$k = $m; $k -lt $stack.Count; $k++) { [void]$items.Add($stack[$k]) }
                while ($stack.Count -gt $m) { $stack.RemoveAt($stack.Count - 1) }
                $stack.Add($items.ToArray())
            }
            0x5d { $stack.Add([Collections.Generic.List[object]]::new()) }            # EMPTY_LIST
            0x65 {                                                     # APPENDS
                [int]$m = $marks.Pop()
                $list = $stack[$m - 1]
                for ([int]$k = $m; $k -lt $stack.Count; $k++) { [void]$list.Add($stack[$k]) }
                while ($stack.Count -gt $m) { $stack.RemoveAt($stack.Count - 1) }
            }
            0x7d { $stack.Add([Collections.Specialized.OrderedDictionary]::new()) }   # EMPTY_DICT
            0x73 {                                                     # SETITEM
                # Distinct names: $k and $v are type-constrained by the [int]/[long]
                # declarations elsewhere in this scope, and PowerShell keeps that constraint.
                $setVal = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $setKey = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $stack[$stack.Count-1][$setKey] = $setVal
            }
            0x75 {                                                     # SETITEMS
                [int]$m = $marks.Pop()
                $dict = $stack[$m - 1]
                for ([int]$k = $m; $k -lt $stack.Count; $k += 2) { $dict[$stack[$k]] = $stack[$k + 1] }
                while ($stack.Count -gt $m) { $stack.RemoveAt($stack.Count - 1) }
            }
            0x52 {                                                     # REDUCE
                $args = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $fn   = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                if ($fn.Name -eq '_rebuild_tensor_v2' -or $fn.Name -eq '_rebuild_tensor') {
                    $stack.Add([pscustomobject]@{
                        Kind = 'tensor'; Storage = $args[0]; Offset = [long]$args[1]
                        Shape = @($args[2]); Stride = @($args[3])
                    })
                }
                elseif ($fn.Name -eq 'OrderedDict') { $stack.Add([Collections.Specialized.OrderedDictionary]::new()) }
                else { throw "unsupported REDUCE callable $($fn.Module).$($fn.Name)" }
            }
            0x81 {                                                     # NEWOBJ
                $args = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $cls  = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $stack.Add([pscustomobject]@{ Kind = 'object'; Class = $cls; Args = $args })
            }
            0x62 {                                                     # BUILD
                $state = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $target = $stack[$stack.Count-1]
                if ($state -is [Collections.Specialized.OrderedDictionary] -and
                    $target -is [Collections.Specialized.OrderedDictionary]) {
                    foreach ($sk in $state.Keys) { $target[$sk] = $state[$sk] }
                }
                elseif ($null -ne $state -and $target -is [psobject] -and $target.Kind -eq 'object') {
                    $target | Add-Member -NotePropertyName State -NotePropertyValue $state -Force
                }
            }
            0x61 {                                                     # APPEND
                $item = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                [void]$stack[$stack.Count-1].Add($item)
            }
            0x43 {                                                     # SHORT_BINBYTES
                [int]$bl = $Data[$i]; $i++
                [byte[]]$bb = [byte[]]::new($bl); [Array]::Copy($Data, $i, $bb, 0, $bl); $i += $bl
                $stack.Add($bb)
            }
            0x42 {                                                     # BINBYTES
                [int]$bl = [BitConverter]::ToInt32($Data, $i); $i += 4
                [byte[]]$bb = [byte[]]::new($bl); [Array]::Copy($Data, $i, $bb, 0, $bl); $i += $bl
                $stack.Add($bb)
            }
            0x2e { return $stack[$stack.Count - 1] }                   # STOP
            default { throw ("unsupported pickle opcode 0x{0:X2} at {1}" -f $op, ($i - 1)) }
        }
    }
    throw 'pickle ended without STOP'
}.GetNewClosure()

$read = {
    param([string]$Path)

    [void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @{}
        foreach ($e in $zip.Entries) { $entries[$e.FullName] = $e }
        $pklName = ($zip.Entries | Where-Object { $_.FullName -like '*/data.pkl' } | Select-Object -First 1).FullName
        if (-not $pklName) { throw 'no data.pkl in archive' }
        $prefix = $pklName.Substring(0, $pklName.Length - 'data.pkl'.Length)

        $e = $entries[$pklName]
        [byte[]]$pkl = [byte[]]::new($e.Length)
        $s = $e.Open()
        try { [void]$s.ReadExactly($pkl, 0, $pkl.Length) } finally { $s.Dispose() }

        $root = & $unpickle $pkl

        # The state dict nests: bert/predictor/decoder each hold their own dict, so walk it
        # and join the keys with dots, which is how torch names parameters anyway.
        $out = [Collections.Specialized.OrderedDictionary]::new()
        $pending = [Collections.Generic.Stack[object]]::new()
        $pending.Push([pscustomobject]@{ Prefix = ''; Node = $root })
        while ($pending.Count -gt 0) {
            $frame = $pending.Pop()
            $node = $frame.Node
            if ($node -isnot [Collections.Specialized.OrderedDictionary]) { continue }
            $names = @($node.Keys)
            for ([int]$ki = $names.Count - 1; $ki -ge 0; $ki--) {
                $name = [string]$names[$ki]
                $child = $node[$names[$ki]]
                $full = if ($frame.Prefix) { $frame.Prefix + '.' + $name } else { $name }
                if ($child -is [Collections.Specialized.OrderedDictionary]) {
                    $pending.Push([pscustomobject]@{ Prefix = $full; Node = $child })
                    continue
                }
                if ($null -eq $child -or $child.Kind -ne 'tensor') { continue }
                $d = $dtypeOf[$child.Storage.StorageType]
                if ($null -eq $d) { throw "unknown storage type $($child.Storage.StorageType)" }
                [long]$count = 1; foreach ($dim in $child.Shape) { $count *= [long]$dim }
                $out[$full] = [pscustomobject]@{
                    Name = $full
                    DType = $d.Name
                    ItemBytes = $d.Bytes
                    Shape = [int[]]$child.Shape
                    Stride = [long[]]$child.Stride
                    Count = $count
                    Entry = "$prefix" + "data/" + $child.Storage.Key
                    Offset = $child.Offset
                }
            }
        }
        [pscustomobject]@{
            PSTypeName = 'Torch.Checkpoint'
            Path = $Path
            Prefix = $prefix
            Tensors = $out
        }
    }
    finally { $zip.Dispose() }
}.GetNewClosure()

# Materialise one tensor's raw bytes from its storage entry.
$bytes = {
    param([object]$Checkpoint, [string]$Name)
    $t = $Checkpoint.Tensors[$Name]
    if ($null -eq $t) { throw "no tensor $Name" }
    [void][Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
    $zip = [IO.Compression.ZipFile]::OpenRead($Checkpoint.Path)
    try {
        $e = ($zip.Entries | Where-Object { $_.FullName -eq $t.Entry } | Select-Object -First 1)
        if ($null -eq $e) { throw "no storage entry $($t.Entry)" }
        [byte[]]$raw = [byte[]]::new($e.Length)
        $s = $e.Open()
        try { [void]$s.ReadExactly($raw, 0, $raw.Length) } finally { $s.Dispose() }
        [long]$start = $t.Offset * $t.ItemBytes
        [long]$len = $t.Count * $t.ItemBytes
        if ($start + $len -gt $raw.Length) { throw "tensor $Name runs past storage: $start+$len > $($raw.Length)" }
        [byte[]]$slice = [byte[]]::new($len)
        [Array]::Copy($raw, $start, $slice, 0, $len)
        return ,$slice
    }
    finally { $zip.Dispose() }
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName = 'Torch.CheckpointReader'
    Name       = 'Torch.Checkpoint'
    Read       = $read
    Bytes      = $bytes
    Unpickle   = $unpickle
}
