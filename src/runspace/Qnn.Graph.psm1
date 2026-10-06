param(
    [Parameter(Mandatory)]
    [object]$Abi,

    [Parameter(Mandatory)]
    [object]$Native
)

# QNN graph authoring primitives. Every physical allocation belongs to one
# disposable arena. Semantic recipe objects live outside the arena.

$opConfigType = & $Abi.NewOpConfigType

$newArena = {
    [pscustomobject]@{
        PSTypeName = 'AndroidSMA.Qnn.NativeArena'
        Pointers   = [Collections.Generic.List[IntPtr]]::new()
        Closed     = $false
    }
}.GetNewClosure()

$allocate = {
    param([object]$Arena, [int]$Bytes)
    if ($Arena.Closed) {
        throw 'Cannot allocate from a closed QNN arena.'
    }
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
    [void]$Arena.Pointers.Add($pointer)
    [byte[]]$zero = [byte[]]::new($Bytes)
    [Runtime.InteropServices.Marshal]::Copy($zero, 0, $pointer, $Bytes)
    $pointer
}.GetNewClosure()

$allocateString = {
    param([object]$Arena, [string]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($Value)
    [void]$Arena.Pointers.Add($pointer)
    $pointer
}.GetNewClosure()

$allocateBytes = {
    param([object]$Arena, [byte[]]$Bytes)
    $pointer = & $allocate $Arena $Bytes.Length
    [Runtime.InteropServices.Marshal]::Copy(
        $Bytes, 0, $pointer, $Bytes.Length
    )
    $pointer
}.GetNewClosure()

$allocateDimensions = {
    param([object]$Arena, [int[]]$Shape)
    $pointer = & $allocate $Arena ($Shape.Length * 4)
    for ($index = 0; $index -lt $Shape.Length; $index++) {
        [Runtime.InteropServices.Marshal]::WriteInt32(
            $pointer,
            $index * 4,
            $Shape[$index]
        )
    }
    $pointer
}.GetNewClosure()

$freeArena = {
    param([object]$Arena)
    if ($null -eq $Arena -or $Arena.Closed) {
        return
    }
    for ($index = $Arena.Pointers.Count - 1; $index -ge 0; $index--) {
        $pointer = $Arena.Pointers[$index]
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)
        }
    }
    $Arena.Pointers.Clear()
    $Arena.Closed = $true
}.GetNewClosure()

$newTensor = {
    param(
        [object]$Arena,
        [string]$Name,
        [int]$TensorType,
        [int]$DataType,
        [int[]]$Shape,
        [byte[]]$Data
        ,
        [object]$Quantize = $null
    )

    $tensorPointer = & $allocate $Arena ([int]$Abi.Layout.TensorBytes)
    $namePointer = & $allocateString $Arena $Name
    $dimensionPointer = & $allocateDimensions $Arena $Shape
    $dataPointer = [IntPtr]::Zero
    [int]$dataLength = 0

    if ($null -ne $Data -and $Data.Length -gt 0) {
        $dataPointer = & $allocateBytes $Arena $Data
        $dataLength = $Data.Length
    }

    $offset = $Abi.Layout.Tensor
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $tensorPointer, [int]$offset.Version, [int]$Abi.Enum.TensorVersion1
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $tensorPointer, [int]$offset.Id, 0
    )
    [Runtime.InteropServices.Marshal]::WriteIntPtr(
        $tensorPointer, [int]$offset.Name, $namePointer
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $tensorPointer, [int]$offset.Type, $TensorType
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $tensorPointer, [int]$offset.DataFormat, [int]$Abi.Enum.FlatBuffer
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $tensorPointer, [int]$offset.DataType, $DataType
    )
    # Quantization. $Quantize is $null for float tensors (the historical behaviour), or
    # @{ Encoding='ScaleOffset'; Scale=<float>; Offset=<int> }
    # @{ Encoding='AxisScaleOffset'; Axis=<int>; ScaleOffsets=@(@(<float>,<int>), ...) }
    if ($null -eq $Quantize) {
        [Runtime.InteropServices.Marshal]::WriteInt32(
            $tensorPointer, [int]$offset.QuantDef, [int]$Abi.Enum.QuantUndefined
        )
        [Runtime.InteropServices.Marshal]::WriteInt32(
            $tensorPointer, [int]$offset.QuantEncoding, [int]$Abi.Enum.QuantUndefined
        )
    }
    else {
        [int]$unionBase = [int]$offset.QuantUnion
        [Runtime.InteropServices.Marshal]::WriteInt32(
            $tensorPointer, [int]$offset.QuantDef, [int]$Abi.Enum.DefinitionDefined
        )
        [string]$encoding = [string]$Quantize.Encoding
        if ($encoding -eq 'ScaleOffset') {
            $so = $Abi.Layout.ScaleOffset
            [Runtime.InteropServices.Marshal]::WriteInt32(
                $tensorPointer, [int]$offset.QuantEncoding, [int]$Abi.Enum.QuantScaleOffset
            )
            [Runtime.InteropServices.Marshal]::WriteInt32(
                $tensorPointer, $unionBase + [int]$so.Scale,
                [BitConverter]::SingleToInt32Bits([float]$Quantize.Scale)
            )
            [Runtime.InteropServices.Marshal]::WriteInt32(
                $tensorPointer, $unionBase + [int]$so.Offset, [int]$Quantize.Offset
            )
        }
        elseif ($encoding -eq 'AxisScaleOffset') {
            $aso = $Abi.Layout.AxisScaleOffset
            $so = $Abi.Layout.ScaleOffset
            [object[]]$pairs = $Quantize.ScaleOffsets
            [int]$count = $pairs.Length
            $pairsPointer = & $allocate $Arena ($count * [int]$so.SizeBytes)
            for ([int]$i = 0; $i -lt $count; $i++) {
                [int]$base = $i * [int]$so.SizeBytes
                [Runtime.InteropServices.Marshal]::WriteInt32(
                    $pairsPointer, $base + [int]$so.Scale,
                    [BitConverter]::SingleToInt32Bits([float]$pairs[$i][0])
                )
                [Runtime.InteropServices.Marshal]::WriteInt32(
                    $pairsPointer, $base + [int]$so.Offset, [int]$pairs[$i][1]
                )
            }
            [Runtime.InteropServices.Marshal]::WriteInt32(
                $tensorPointer, [int]$offset.QuantEncoding, [int]$Abi.Enum.QuantAxisScaleOffset
            )
            [Runtime.InteropServices.Marshal]::WriteInt32(
                $tensorPointer, $unionBase + [int]$aso.Axis, [int]$Quantize.Axis
            )
            [Runtime.InteropServices.Marshal]::WriteInt32(
                $tensorPointer, $unionBase + [int]$aso.Count, $count
            )
            [Runtime.InteropServices.Marshal]::WriteIntPtr(
                $tensorPointer, $unionBase + [int]$aso.Pointer, $pairsPointer
            )
        }
        else { throw "unsupported quantization encoding '$encoding'" }
    }
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $tensorPointer, [int]$offset.Rank, $Shape.Length
    )
    [Runtime.InteropServices.Marshal]::WriteIntPtr(
        $tensorPointer, [int]$offset.Dimensions, $dimensionPointer
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $tensorPointer, [int]$offset.MemType, [int]$Abi.Enum.RawMemory
    )
    [Runtime.InteropServices.Marshal]::WriteIntPtr(
        $tensorPointer, [int]$offset.ClientData, $dataPointer
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $tensorPointer, [int]$offset.ClientBytes, $dataLength
    )

    [pscustomobject]@{
        PSTypeName = 'AndroidSMA.Qnn.Tensor'
        Name       = $Name
        Ptr        = $tensorPointer
        Type       = $TensorType
        DataType   = $DataType
        Shape      = [int[]]$Shape.Clone()
        DataPtr    = $dataPointer
        DataBytes  = $dataLength
        Id         = 0
        Registered = $false
    }
}.GetNewClosure()

$registerTensor = {
    param([object]$Trial, [object]$Tensor)
    $create = & $Native.GetDelegate `
        'TensorCreateGraphTensor' ([uint64]) ([Type[]]@([IntPtr], [IntPtr]))
    $rc = [uint64]$create.DynamicInvoke(
        [object[]]@($Trial.Graph, $Tensor.Ptr)
    )
    $Tensor.Id = [Runtime.InteropServices.Marshal]::ReadInt32(
        $Tensor.Ptr,
        [int]$Abi.Layout.Tensor.Id
    )
    $Tensor.Registered = $rc -eq 0 -and $Tensor.Id -ne 0
    [pscustomobject]@{
        Tensor = $Tensor
        Rc     = $rc
        Id     = $Tensor.Id
    }
}.GetNewClosure()

$newTensorArray = {
    param([object]$Arena, [object[]]$Tensors)
    $tensorBytes = [int]$Abi.Layout.TensorBytes
    $pointer = & $allocate $Arena ($tensorBytes * $Tensors.Count)
    [byte[]]$scratch = [byte[]]::new($tensorBytes)
    for ($index = 0; $index -lt $Tensors.Count; $index++) {
        [Runtime.InteropServices.Marshal]::Copy(
            $Tensors[$index].Ptr, $scratch, 0, $tensorBytes
        )
        [Runtime.InteropServices.Marshal]::Copy(
            $scratch,
            0,
            [IntPtr]::Add($pointer, $index * $tensorBytes),
            $tensorBytes
        )
    }
    $pointer
}.GetNewClosure()

$newTensorParam = {
    param(
        [object]$Arena,
        [string]$Name,
        [object]$Tensor
    )
    if (-not $Tensor.Registered) {
        throw "Tensor parameter must be graph-registered: $($Tensor.Name)"
    }
    $pointer = & $allocate $Arena ([int]$Abi.Layout.ParamBytes)
    $namePointer = & $allocateString $Arena $Name
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $pointer, [int]$Abi.Layout.Param.Type, [int]$Abi.Enum.ParamTensor
    )
    [Runtime.InteropServices.Marshal]::WriteIntPtr(
        $pointer, [int]$Abi.Layout.Param.Name, $namePointer
    )
    [byte[]]$tensorBytes = [byte[]]::new([int]$Abi.Layout.TensorBytes)
    [Runtime.InteropServices.Marshal]::Copy(
        $Tensor.Ptr, $tensorBytes, 0, $tensorBytes.Length
    )
    [Runtime.InteropServices.Marshal]::Copy(
        $tensorBytes,
        0,
        [IntPtr]::Add($pointer, [int]$Abi.Layout.Param.Value),
        $tensorBytes.Length
    )
    $pointer
}.GetNewClosure()

$newScalarBoolParam = {
    param(
        [object]$Arena,
        [string]$Name,
        [bool]$Value
    )
    $pointer = & $allocate $Arena ([int]$Abi.Layout.ParamBytes)
    $namePointer = & $allocateString $Arena $Name
    $valueOffset = [int]$Abi.Layout.Param.Value
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $pointer, [int]$Abi.Layout.Param.Type, [int]$Abi.Enum.ParamScalar
    )
    [Runtime.InteropServices.Marshal]::WriteIntPtr(
        $pointer, [int]$Abi.Layout.Param.Name, $namePointer
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $pointer, $valueOffset, [int]$Abi.Enum.Bool8
    )
    [Runtime.InteropServices.Marshal]::WriteByte(
        $pointer, $valueOffset + 8, $(if ($Value) { [byte]1 } else { [byte]0 })
    )
    $pointer
}.GetNewClosure()

$newScalarUInt32Param = {
    param(
        [object]$Arena,
        [string]$Name,
        [uint32]$Value
    )
    $pointer = & $allocate $Arena ([int]$Abi.Layout.ParamBytes)
    $namePointer = & $allocateString $Arena $Name
    $valueOffset = [int]$Abi.Layout.Param.Value
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $pointer, [int]$Abi.Layout.Param.Type, [int]$Abi.Enum.ParamScalar
    )
    [Runtime.InteropServices.Marshal]::WriteIntPtr(
        $pointer, [int]$Abi.Layout.Param.Name, $namePointer
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $pointer, $valueOffset, [int]$Abi.Enum.UInt32
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $pointer, $valueOffset + 8, [int]$Value
    )
    $pointer
}.GetNewClosure()

$newParamArray = {
    param([object]$Arena, [IntPtr[]]$Parameters)
    $paramBytes = [int]$Abi.Layout.ParamBytes
    $pointer = & $allocate $Arena ($paramBytes * $Parameters.Count)
    [byte[]]$scratch = [byte[]]::new($paramBytes)
    for ($index = 0; $index -lt $Parameters.Count; $index++) {
        [Runtime.InteropServices.Marshal]::Copy(
            $Parameters[$index], $scratch, 0, $paramBytes
        )
        [Runtime.InteropServices.Marshal]::Copy(
            $scratch,
            0,
            [IntPtr]::Add($pointer, $index * $paramBytes),
            $paramBytes
        )
    }
    $pointer
}.GetNewClosure()

$newOp = {
    param(
        [object]$Arena,
        [string]$Name,
        [string]$Type,
        [object[]]$Inputs,
        [object[]]$Outputs,
        [IntPtr[]]$Parameters
    )
    $inputsPointer = & $newTensorArray $Arena $Inputs
    $outputsPointer = & $newTensorArray $Arena $Outputs
    $paramsPointer = [IntPtr]::Zero
    [int]$parameterCount = 0
    if ($null -ne $Parameters -and $Parameters.Count -gt 0) {
        $paramsPointer = & $newParamArray $Arena $Parameters
        $parameterCount = $Parameters.Count
    }

    $op = [Activator]::CreateInstance($opConfigType)
    $values = [ordered]@{
        Version     = [int]$Abi.Enum.OpConfigVersion1
        Name        = (& $allocateString $Arena $Name)
        PackageName = (& $allocateString $Arena 'qti.aisw')
        TypeName    = (& $allocateString $Arena $Type)
        NumParams   = [uint32]$parameterCount
        Params      = $paramsPointer
        NumInputs   = [uint32]$Inputs.Count
        Inputs      = $inputsPointer
        NumOutputs  = [uint32]$Outputs.Count
        Outputs     = $outputsPointer
    }
    foreach ($entry in $values.GetEnumerator()) {
        $opConfigType.GetField([string]$entry.Key).SetValue($op, $entry.Value)
    }
    [pscustomobject]@{
        PSTypeName = 'AndroidSMA.Qnn.OpConfig'
        Name       = $Name
        Type       = $Type
        Value      = $op
        Inputs     = $Inputs
        Outputs    = $Outputs
        Parameters = $Parameters
    }
}.GetNewClosure()

$addNode = {
    param([object]$Trial, [object]$Op)
    $add = & $Native.GetDelegate `
        'GraphAddNode' ([uint64]) ([Type[]]@([IntPtr], $opConfigType))
    [uint64]$add.DynamicInvoke([object[]]@($Trial.Graph, $Op.Value))
}.GetNewClosure()

$finalize = {
    param([object]$Trial)
    $call = & $Native.GetDelegate `
        'GraphFinalize' ([uint64]) ([Type[]]@([IntPtr], [IntPtr], [IntPtr]))
    [uint64]$call.DynamicInvoke(
        [object[]]@($Trial.Graph, [IntPtr]::Zero, [IntPtr]::Zero)
    )
}.GetNewClosure()

$newExecTensor = {
    param(
        [object]$Arena,
        [object]$Tensor,
        [byte[]]$Data
    )
    $pointer = & $allocate $Arena ([int]$Abi.Layout.TensorBytes)
    [byte[]]$scratch = [byte[]]::new([int]$Abi.Layout.TensorBytes)
    [Runtime.InteropServices.Marshal]::Copy(
        $Tensor.Ptr, $scratch, 0, $scratch.Length
    )
    [Runtime.InteropServices.Marshal]::Copy(
        $scratch, 0, $pointer, $scratch.Length
    )
    $dataPointer = & $allocateBytes $Arena $Data
    [Runtime.InteropServices.Marshal]::WriteIntPtr(
        $pointer, [int]$Abi.Layout.Tensor.ClientData, $dataPointer
    )
    [Runtime.InteropServices.Marshal]::WriteInt32(
        $pointer, [int]$Abi.Layout.Tensor.ClientBytes, $Data.Length
    )
    [pscustomobject]@{
        Ptr       = $pointer
        DataPtr   = $dataPointer
        DataBytes = $Data.Length
        Tensor    = $Tensor
    }
}.GetNewClosure()

$execute = {
    param(
        [object]$Trial,
        [object]$Arena,
        [object[]]$Inputs,
        [object[]]$Outputs
    )
    $inputDescriptors = [object[]]::new($Inputs.Count)
    for ($index = 0; $index -lt $Inputs.Count; $index++) {
        $inputDescriptors[$index] = $Inputs[$index].Tensor
    }
    $outputDescriptors = [object[]]::new($Outputs.Count)
    for ($index = 0; $index -lt $Outputs.Count; $index++) {
        $outputDescriptors[$index] = $Outputs[$index].Tensor
    }
    $inputArray = & $newTensorArray $Arena $inputDescriptors
    $outputArray = & $newTensorArray $Arena $outputDescriptors

    for ($index = 0; $index -lt $Inputs.Count; $index++) {
        $base = [IntPtr]::Add(
            $inputArray, $index * [int]$Abi.Layout.TensorBytes
        )
        [Runtime.InteropServices.Marshal]::WriteIntPtr(
            $base, [int]$Abi.Layout.Tensor.ClientData, $Inputs[$index].DataPtr
        )
        [Runtime.InteropServices.Marshal]::WriteInt32(
            $base, [int]$Abi.Layout.Tensor.ClientBytes, $Inputs[$index].DataBytes
        )
    }
    for ($index = 0; $index -lt $Outputs.Count; $index++) {
        $base = [IntPtr]::Add(
            $outputArray, $index * [int]$Abi.Layout.TensorBytes
        )
        [Runtime.InteropServices.Marshal]::WriteIntPtr(
            $base, [int]$Abi.Layout.Tensor.ClientData, $Outputs[$index].DataPtr
        )
        [Runtime.InteropServices.Marshal]::WriteInt32(
            $base, [int]$Abi.Layout.Tensor.ClientBytes, $Outputs[$index].DataBytes
        )
    }

    $call = & $Native.GetDelegate `
        'GraphExecute' ([uint64]) ([Type[]]@(
            [IntPtr], [IntPtr], [uint32], [IntPtr], [uint32], [IntPtr], [IntPtr]
        ))
    [uint64]$call.DynamicInvoke([object[]]@(
        $Trial.Graph,
        $inputArray,
        [uint32]$Inputs.Count,
        $outputArray,
        [uint32]$Outputs.Count,
        [IntPtr]::Zero,
        [IntPtr]::Zero
    ))
}.GetNewClosure()

$serializeContext = {
    param([object]$Trial, [object]$Arena)
    $getSize = & $Native.GetDelegate `
        'ContextGetBinarySize' ([uint64]) ([Type[]]@(
            [IntPtr], ([uint64]).MakeByRefType()
        ))
    $sizeArgs = [object[]]@($Trial.Context, [uint64]0)
    $sizeRc = [uint64]$getSize.DynamicInvoke($sizeArgs)
    [uint64]$size = $sizeArgs[1]
    if ($sizeRc -ne 0 -or $size -eq 0) {
        throw "contextGetBinarySize rc=$sizeRc size=$size"
    }
    $pointer = & $allocate $Arena ([int]$size)
    $getBinary = & $Native.GetDelegate `
        'ContextGetBinary' ([uint64]) ([Type[]]@(
            [IntPtr], [IntPtr], [uint64], ([uint64]).MakeByRefType()
        ))
    $binaryArgs = [object[]]@($Trial.Context, $pointer, $size, [uint64]0)
    $binaryRc = [uint64]$getBinary.DynamicInvoke($binaryArgs)
    [uint64]$written = $binaryArgs[3]
    if ($binaryRc -ne 0 -or $written -eq 0) {
        throw "contextGetBinary rc=$binaryRc written=$written"
    }
    [byte[]]$bytes = [byte[]]::new([int]$written)
    [Runtime.InteropServices.Marshal]::Copy($pointer, $bytes, 0, $bytes.Length)
    return ,$bytes
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName          = 'AndroidSMA.Qnn.GraphCapability'
    Name                = 'Qnn.Graph'
    Abi                 = $Abi
    Native              = $Native
    OpConfigType        = $opConfigType
    NewArena            = $newArena
    FreeArena           = $freeArena
    Allocate            = $allocate
    AllocateBytes       = $allocateBytes
    NewTensor           = $newTensor
    RegisterTensor      = $registerTensor
    NewTensorArray      = $newTensorArray
    NewTensorParam      = $newTensorParam
    NewScalarBoolParam  = $newScalarBoolParam
    NewScalarUInt32Param = $newScalarUInt32Param
    NewOp               = $newOp
    AddNode             = $addNode
    Finalize            = $finalize
    NewExecTensor       = $newExecTensor
    Execute             = $execute
    SerializeContext    = $serializeContext
}
