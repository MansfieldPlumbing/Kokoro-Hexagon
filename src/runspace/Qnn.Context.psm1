param([Parameter(Mandatory)][object]$Abi, [Parameter(Mandatory)][object]$Native, [Parameter(Mandatory)][object]$Graph)
# Precompiled context binaries: file-backed map -> contextCreateFromBinary -> graphRetrieve.
# Returns trial-shaped objects so Qnn.Native.CloseTrial and Qnn.Graph.Execute apply unchanged.

# Interface slots from QAIRT 2.46 Layouts.psd1, QnnInterface_ImplementationV2_35_t (bit offset / 64).
foreach ($pair in @(@('ContextCreateFromBinary', 13), @('GraphRetrieve', 20))) {
    if (-not $Abi.Slot.Contains($pair[0])) { $Abi.Slot[$pair[0]] = $pair[1] }
}

$loadContext = {
    param([string]$Path, [string]$GraphName, [IntPtr]$Profile = [IntPtr]::Zero)
    if (-not $Native.State.Initialized) { throw 'Qnn.Native must be initialized before loading a context.' }
    $file = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile($Path, [IO.FileMode]::Open, [NullString]::Value, 0, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
    $view = $file.CreateViewAccessor(0, 0, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
    [long]$size = [IO.FileInfo]::new($Path).Length
    $handle = $view.SafeMemoryMappedViewHandle
    [byte]$dummy = 0
    $base = [IntPtr]::Zero
    try {
        $success = $false; $handle.DangerousAddRef([ref]$success)
        $base = [IntPtr]::Add($handle.DangerousGetHandle(), [int]$view.PointerOffset)
        $create = & $Native.GetDelegate 'ContextCreateFromBinary' ([uint64]) ([Type[]]@(
            [IntPtr], [IntPtr], [IntPtr], [IntPtr], [uint64], ([IntPtr]).MakeByRefType(), [IntPtr]))
        $a = [object[]]@($Native.State.Backend, $Native.State.Device, [IntPtr]::Zero, $base, [uint64]$size, [IntPtr]::Zero, $Profile)
        $rc = [uint64]$create.DynamicInvoke($a); $context = [IntPtr]$a[5]
        if ($rc -ne 0 -or $context -eq [IntPtr]::Zero) { throw "contextCreateFromBinary rc=$rc bytes=$size" }
    }
    finally {
        # The backend copies what it needs during create; the mapping is released afterwards.
        if ($base -ne [IntPtr]::Zero) { $handle.DangerousRelease() }
        $view.Dispose(); $file.Dispose()
    }
    $namePointer = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($GraphName)
    try {
        $retrieve = & $Native.GetDelegate 'GraphRetrieve' ([uint64]) ([Type[]]@([IntPtr], [IntPtr], ([IntPtr]).MakeByRefType()))
        $g = [object[]]@($context, $namePointer, [IntPtr]::Zero)
        $grc = [uint64]$retrieve.DynamicInvoke($g); $graphHandle = [IntPtr]$g[2]
        if ($grc -ne 0 -or $graphHandle -eq [IntPtr]::Zero) {
            $free = & $Native.GetDelegate 'ContextFree' ([uint64]) ([Type[]]@([IntPtr], [IntPtr]))
            [void]$free.DynamicInvoke([object[]]@($context, [IntPtr]::Zero))
            throw "graphRetrieve rc=$grc name=$GraphName"
        }
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($namePointer) }
    [pscustomobject]@{
        PSTypeName = 'AndroidSMA.Qnn.Trial'; Name = $GraphName; Context = $context; Graph = $graphHandle
        Generation = $Native.State.Generation; Closed = $false; ContextBytes = $size
    }
}.GetNewClosure()

# Descriptor for an existing graph tensor: id, name, type, data type and shape from the host-side binary info.
$bindTensor = {
    param([object]$Arena, [uint32]$Id, [string]$Name, [int]$TensorType, [int]$DataType, [int[]]$Shape)
    $t = & $Graph.NewTensor $Arena $Name $TensorType $DataType $Shape $null
    [Runtime.InteropServices.Marshal]::WriteInt32($t.Ptr, [int]$Abi.Layout.Tensor.Id, [int]$Id)
    $t
}.GetNewClosure()

# HTP performance vote (QnnHtpPerfInfrastructure). Layouts: QAIRT 2.46 Layouts.psd1 (DcvsV3_t, PowerConfig_t,
# PerfInfrastructure_t); interface slot deviceGetInfrastructure = 312/8. The outer infrastructure struct is checked
# at runtime: infraType (offset 0) must be TYPE_PERF (0) and the perfInfra table (offset 8) must be non-null.
$setPerformance = {
    param([string]$Mode = 'burst')
    $M = [Runtime.InteropServices.Marshal]
    if (-not $Abi.Slot.Contains('DeviceGetInfrastructure')) { $Abi.Slot['DeviceGetInfrastructure'] = 39 }
    $get = & $Native.GetDelegate 'DeviceGetInfrastructure' ([uint64]) ([Type[]]@(([IntPtr]).MakeByRefType()))
    $a = [object[]]@([IntPtr]::Zero); $rc = [uint64]$get.DynamicInvoke($a); $infra = [IntPtr]$a[0]
    if ($rc -ne 0 -or $infra -eq [IntPtr]::Zero) { throw "deviceGetInfrastructure rc=$rc" }
    $type = $M::ReadInt32($infra, 0)
    [IntPtr[]]$fn = foreach ($o in 8, 16, 24, 32) { $M::ReadIntPtr($infra, $o) }
    if ($type -ne 0 -or ($fn -contains [IntPtr]::Zero)) { throw "unexpected infrastructure layout type=$type" }
    $newDelegate = { param([IntPtr]$p, [Type[]]$t) [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($p, (& $Abi.NewDelegateType ('HtpPerf' + $p.ToInt64()) ([uint64]) $t)) }
    $create = & $newDelegate $fn[0] ([Type[]]@([uint32], [uint32], ([uint32]).MakeByRefType()))
    $set = & $newDelegate $fn[2] ([Type[]]@([uint32], [IntPtr]))
    $c = [object[]]@([uint32]0, [uint32]0, [uint32]0); $crc = [uint64]$create.DynamicInvoke($c); [uint32]$id = $c[2]
    if ($crc -ne 0) { throw "createPowerConfigId rc=$crc" }
    $burst = $Mode -eq 'burst'
    # PowerConfig_t: option@0, union@4 (68 bytes). DcvsV3_t field offsets relative to the union.
    $dcvs = $M::AllocHGlobal(68); $lat = $M::AllocHGlobal(68); $poll = $M::AllocHGlobal(68); $list = $M::AllocHGlobal(32)
    try {
        foreach ($p in $dcvs, $lat, $poll) { $M::Copy([byte[]]::new(68), 0, $p, 68) }
        $M::WriteInt32($dcvs, 0, 1)                                           # POWER_CONFIGOPTION_DCVS_V3
        $u = [IntPtr]::Add($dcvs, 4)
        $corner = if ($burst) { 160 } else { 0 }                              # MAX_VOLTAGE_CORNER / let DCVS pick
        foreach ($kv in @(@(0, $id), @(4, 1), @(8, [int](-not $burst)), @(12, $(if ($burst) { 16 } else { 1 })),
                          @(16, 1), @(20, $(if ($burst) { 40 } else { 1000 })), @(24, 1), @(28, [int]$burst),
                          @(32, [int]$burst), @(36, $corner), @(40, $corner), @(44, $corner),
                          @(48, [int]$burst), @(52, $corner), @(56, $corner), @(60, $corner))) { $M::WriteInt32($u, $kv[0], [int]$kv[1]) }
        $M::WriteInt32($lat, 0, 2); $M::WriteInt32($lat, 4, $(if ($burst) { 100 } else { 1000 }))   # RPC_CONTROL_LATENCY (us)
        $M::WriteInt32($poll, 0, 3); $M::WriteInt32($poll, 4, $(if ($burst) { 9999 } else { 0 }))   # RPC_POLLING_TIME (us)
        $M::WriteIntPtr($list, 0, $dcvs); $M::WriteIntPtr($list, 8, $lat); $M::WriteIntPtr($list, 16, $poll); $M::WriteIntPtr($list, 24, [IntPtr]::Zero)
        $src = [uint64]$set.DynamicInvoke([object[]]@($id, $list))
    }
    finally { foreach ($p in $dcvs, $lat, $poll, $list) { $M::FreeHGlobal($p) } }
    [pscustomobject]@{ Mode = $Mode; PowerConfigId = $id; SetRc = $src }
}.GetNewClosure()

$newProfile = {
    param([uint32]$Level = 2)
    if (-not $Abi.Slot.Contains('ProfileCreate')) { $Abi.Slot['ProfileCreate'] = 28 }
    $c = & $Native.GetDelegate 'ProfileCreate' ([uint64]) ([Type[]]@([IntPtr], [uint32], ([IntPtr]).MakeByRefType()))
    $a = [object[]]@($Native.State.Backend, $Level, [IntPtr]::Zero); $rc = [uint64]$c.DynamicInvoke($a); if ($rc -ne 0) { throw "profileCreate rc=$rc" }; [IntPtr]$a[2]
}.GetNewClosure()

# Profiled execute (QnnProfile, QAIRT 2.46 slots 28-34; EventData_t: type@0 unit@4 value@8 identifier@16).
# Takes exec tensors from Qnn.Graph.NewExecTensor (client buffers already bound) and returns the event tree.
$executeProfiled = {
    param([object]$Trial, [object[]]$Inputs, [object[]]$Outputs, [uint32]$Level = 2, [IntPtr]$Profile = [IntPtr]::Zero)
    $M = [Runtime.InteropServices.Marshal]
    foreach ($p in @(@('ProfileCreate', 28), @('ProfileGetEvents', 30), @('ProfileGetSubEvents', 31), @('ProfileGetEventData', 32), @('ProfileFree', 34))) {
        if (-not $Abi.Slot.Contains($p[0])) { $Abi.Slot[$p[0]] = $p[1] }
    }
    $create = & $Native.GetDelegate 'ProfileCreate' ([uint64]) ([Type[]]@([IntPtr], [uint32], ([IntPtr]).MakeByRefType()))
    $events = & $Native.GetDelegate 'ProfileGetEvents' ([uint64]) ([Type[]]@([IntPtr], ([IntPtr]).MakeByRefType(), ([uint32]).MakeByRefType()))
    $sub = & $Native.GetDelegate 'ProfileGetSubEvents' ([uint64]) ([Type[]]@([uint64], ([IntPtr]).MakeByRefType(), ([uint32]).MakeByRefType()))
    $data = & $Native.GetDelegate 'ProfileGetEventData' ([uint64]) ([Type[]]@([uint64], [IntPtr]))
    $free = & $Native.GetDelegate 'ProfileFree' ([uint64]) ([Type[]]@([IntPtr]))
    $exec = & $Native.GetDelegate 'GraphExecute' ([uint64]) ([Type[]]@([IntPtr], [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr], [IntPtr]))
    $own = $Profile -eq [IntPtr]::Zero
    if ($own) { $a = [object[]]@($Native.State.Backend, $Level, [IntPtr]::Zero); $rc = [uint64]$create.DynamicInvoke($a); $prof = [IntPtr]$a[2]; if ($rc -ne 0) { throw "profileCreate rc=$rc" } } else { $prof = $Profile }
    [int]$tb = $Abi.Layout.TensorBytes
    $pack = { param([object[]]$T) $p = $M::AllocHGlobal([Math]::Max(1, $T.Count) * $tb); [byte[]]$s = [byte[]]::new($tb)
        for ($i = 0; $i -lt $T.Count; $i++) { $M::Copy($T[$i].Ptr, $s, 0, $tb); $M::Copy($s, 0, [IntPtr]::Add($p, $i * $tb), $tb) }; $p }
    $inArr = & $pack $Inputs; $outArr = & $pack $Outputs
    $ed = $M::AllocHGlobal(24)
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $xrc = [uint64]$exec.DynamicInvoke([object[]]@($Trial.Graph, $inArr, [uint32]$Inputs.Count, $outArr, [uint32]$Outputs.Count, $prof, [IntPtr]::Zero))
        $wall = $sw.Elapsed.TotalMilliseconds
        if ($xrc -ne 0) { throw "graphExecute(profiled) rc=$xrc" }
        # Copy output data back into each exec tensor's own buffer (the packed copy points at the same client buffers).
        $read = {
            param([uint64]$Id, [int]$Depth)
            [void]$data.DynamicInvoke([object[]]@($Id, $ed))
            $name = $M::PtrToStringUTF8($M::ReadIntPtr($ed, 16))
            $node = [pscustomobject]@{ Type = $M::ReadInt32($ed, 0); Unit = $M::ReadInt32($ed, 4); Value = [uint64]$M::ReadInt64($ed, 8); Name = $name; Children = @() }
            if ($Depth -lt 3) {
                $s = [object[]]@($Id, [IntPtr]::Zero, [uint32]0); [void]$sub.DynamicInvoke($s)
                $node.Children = @(for ($j = 0; $j -lt [int]$s[2]; $j++) { & $read ([uint64]$M::ReadInt64([IntPtr]$s[1], 8 * $j)) ($Depth + 1) })
            }
            $node
        }
        $e = [object[]]@($prof, [IntPtr]::Zero, [uint32]0); [void]$events.DynamicInvoke($e)
        $tree = @(for ($i = 0; $i -lt [int]$e[2]; $i++) { & $read ([uint64]$M::ReadInt64([IntPtr]$e[1], 8 * $i)) 0 })
        [pscustomobject]@{ WallMs = $wall; Events = $tree }
    }
    finally { $M::FreeHGlobal($ed); $M::FreeHGlobal($inArr); $M::FreeHGlobal($outArr); if ($own) { [void]$free.DynamicInvoke([object[]]@($prof)) } }
}.GetNewClosure()

[pscustomobject]@{ PSTypeName = 'AndroidSMA.Qnn.ContextCapability'; Name = 'Qnn.Context'; LoadContext = $loadContext; BindTensor = $bindTensor; SetPerformance = $setPerformance; ExecuteProfiled = $executeProfiled; NewProfile = $newProfile }
