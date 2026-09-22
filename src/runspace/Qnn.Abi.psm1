param()

# Generated-authority projection for the SMA hot path.
# Source: qnn/authority/QAIRT-2.46.0.260424.
# This module intentionally returns one live capability object. It does not
# require Import-Module or export global commands.

$layout = [ordered]@{
    TensorBytes  = 144
    ParamBytes   = 160
    OpConfigBytes = 80

    Tensor = [ordered]@{
        Version      = 0
        Id           = 8
        Name         = 16
        Type         = 24
        DataFormat   = 28
        DataType     = 32
        QuantDef     = 40
        QuantEncoding = 44
        Rank         = 80
        Dimensions   = 88
        MemType      = 96
        ClientData   = 104
        ClientBytes  = 112
    }

    Param = [ordered]@{
        Type  = 0
        Name  = 8
        Value = 16
    }
}

$slot = [ordered]@{
    BackendCreate           = 1
    BackendFree             = 8
    ContextCreate           = 9
    ContextGetBinarySize    = 11
    ContextGetBinary        = 12
    ContextFree             = 14
    GraphCreate             = 15
    GraphAddNode            = 18
    GraphFinalize           = 19
    GraphExecute            = 21
    TensorCreateGraphTensor = 24
    DeviceCreate            = 40
    DeviceFree              = 43
}

$enum = [ordered]@{
    TensorVersion1 = 1
    OpConfigVersion1 = 1
    FlatBuffer = 0
    RawMemory = 0

    AppWrite = 0
    AppRead  = 1
    Native   = 3
    Static   = 4
    TensorNull = 5

    Float32 = 0x0232
    UInt32  = 0x0132
    Bool8   = 0x0508
    DataTypeUndefined = 0x7FFFFFFF
    TensorMemTypeUndefined = 0x7FFFFFFF

    QuantUndefined = 0x7FFFFFFF
    ParamScalar = 0
    ParamTensor = 1
}

$newDelegateType = {
    param(
        [string]$Name,
        [Type]$ReturnType,
        [Type[]]$ParameterTypes
    )

    $assemblyName = [Reflection.AssemblyName]::new(
        "AndroidSMA.Qnn.Dynamic.$Name.$([Guid]::NewGuid().ToString('N'))"
    )

    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        $assemblyName,
        [Reflection.Emit.AssemblyBuilderAccess]::Run
    )

    $module = $assembly.DefineDynamicModule('QnnDelegates')
    $builder = $module.DefineType(
        $Name,
        [Reflection.TypeAttributes]'Class, Public, Sealed',
        [MulticastDelegate]
    )

    $attributeConstructor =
        [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].
        GetConstructor(
            [Type[]]@([Runtime.InteropServices.CallingConvention])
        )

    $attribute = [Reflection.Emit.CustomAttributeBuilder]::new(
        $attributeConstructor,
        [object[]]@([Runtime.InteropServices.CallingConvention]::Cdecl)
    )

    $builder.SetCustomAttribute($attribute)

    $constructor = $builder.DefineConstructor(
        [Reflection.MethodAttributes]'RTSpecialName, HideBySig, Public',
        [Reflection.CallingConventions]::Standard,
        [Type[]]@([object], [IntPtr])
    )
    $constructor.SetImplementationFlags(
        [Reflection.MethodImplAttributes]::Runtime
    )

    $invoke = $builder.DefineMethod(
        'Invoke',
        [Reflection.MethodAttributes]'Public, HideBySig, NewSlot, Virtual',
        $ReturnType,
        $ParameterTypes
    )
    $invoke.SetImplementationFlags([Reflection.MethodImplAttributes]::Runtime)

    $builder.CreateType()
}.GetNewClosure()

$newOpConfigType = {
    $assemblyName = [Reflection.AssemblyName]::new(
        "AndroidSMA.Qnn.OpConfig.$([Guid]::NewGuid().ToString('N'))"
    )

    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        $assemblyName,
        [Reflection.Emit.AssemblyBuilderAccess]::Run
    )
    $module = $assembly.DefineDynamicModule('QnnOpConfig')
    $builder = $module.DefineType(
        'QnnOpConfig',
        [Reflection.TypeAttributes]'Public, Sealed, ExplicitLayout',
        [ValueType],
        [Reflection.Emit.PackingSize]::Size8,
        80
    )

    foreach ($field in @(
        @('Version',     [int],    0),
        @('Name',        [IntPtr], 8),
        @('PackageName', [IntPtr], 16),
        @('TypeName',    [IntPtr], 24),
        @('NumParams',   [uint32], 32),
        @('Params',      [IntPtr], 40),
        @('NumInputs',   [uint32], 48),
        @('Inputs',      [IntPtr], 56),
        @('NumOutputs',  [uint32], 64),
        @('Outputs',     [IntPtr], 72)
    )) {
        $fieldBuilder = $builder.DefineField(
            [string]$field[0],
            [Type]$field[1],
            [Reflection.FieldAttributes]::Public
        )
        $fieldBuilder.SetOffset([int]$field[2])
    }

    $builder.CreateType()
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName      = 'AndroidSMA.Qnn.AbiCapability'
    Name            = 'Qnn.Abi'
    Authority       = 'QAIRT-2.46.0.260424'
    Target          = 'aarch64-none-linux-gnu'
    Interface       = 'QnnInterface_ImplementationV2_35_t'
    Layout          = $layout
    Slot            = $slot
    Enum            = $enum
    NewDelegateType = $newDelegateType
    NewOpConfigType = $newOpConfigType
}
