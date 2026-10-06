param(
    [Parameter(Mandatory)][object]$NativeBinding
)

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
        QuantUnion    = 48
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

    # Qnn_QuantizeParams_t is 40 bytes: encodingDefinition@0, quantizationEncoding@4, union@8.
    # Inside Qnn_TensorV1_t that places the union at byte 48, ending at 79 where Rank begins.
    ScaleOffset = [ordered]@{
        SizeBytes = 8
        Scale     = 0
        Offset    = 4
    }

    AxisScaleOffset = [ordered]@{
        SizeBytes = 16
        Axis      = 0
        Count     = 4
        Pointer   = 8
    }
    # graphCreate's config list. QnnGraph_Config_t is 16 bytes (option@0, union@8 holding a
    # QnnHtpGraph_CustomConfig_t*), and that custom config is 56 bytes (option@0, union@8).
    GraphConfig = [ordered]@{
        SizeBytes = 16
        Option    = 0
        Union     = 8
    }

    HtpCustomConfig = [ordered]@{
        SizeBytes = 56
        Option    = 0
        Union     = 8
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
    # Widened from qnn/authority/QAIRT-2.46.0.260424 Enums.psd1. The projection previously
    # carried only Float32/UInt32/Bool8; every fixed-point path needs the rest.
    Float16 = 0x0216
    Int8    = 8
    Int16   = 22
    Int32   = 50
    UInt8   = 264
    UInt16  = 278
    SFixed2  = 770
    SFixed4  = 772
    SFixed8  = 776
    SFixed16 = 790
    SFixed32 = 818
    UFixed2  = 1026
    UFixed4  = 1028
    UFixed8  = 1032
    UFixed16 = 1046
    UFixed32 = 1074

    DefinitionImplGenerated = 0
    DefinitionDefined       = 1
    DefinitionUndefined     = 0x7FFFFFFF

    QuantScaleOffset        = 0
    QuantAxisScaleOffset    = 1
    QuantBwScaleOffset      = 2
    QuantBwAxisScaleOffset  = 3
    QuantBlock              = 4
    QuantBlockwiseExpansion = 5
    QuantVector             = 6
    QuantFloatBlock         = 7
    GraphConfigCustom       = 0
    HtpOptimization         = 1
    HtpPrecision            = 2
    HtpVtcmSizeMb           = 3
    HtpNumHvxThreads        = 6
    HtpVtcmSizeBytes        = 10
    HtpWeightsPacking       = 12
    PrecisionFloat32        = 0
    PrecisionFloat16        = 1
    ParamScalar = 0
    ParamTensor = 1
}

if ($NativeBinding.Name -cne 'Native.Binding' -or $null -eq $NativeBinding.NewDelegateType) {
    throw 'Qnn.Abi requires the generic Native.Binding capability.'
}

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
    NewDelegateType = $NativeBinding.NewDelegateType
    NewOpConfigType = $newOpConfigType
}
