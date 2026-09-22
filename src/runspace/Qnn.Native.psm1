param(
    [Parameter(Mandatory)]
    [object]$Abi
)

# Durable native state for one persistent SMA runspace. Contexts and graphs are
# disposable trials; provider/backend/device survive between accepted trials.

$state = [pscustomobject]@{
    Initialized   = $false
    Generation    = 0
    NativeRoot    = $null
    DataRoot      = $null
    PrepareHandle = [IntPtr]::Zero
    LibraryHandle = [IntPtr]::Zero
    Provider      = [IntPtr]::Zero
    Functions     = [IntPtr]::Zero
    Backend       = [IntPtr]::Zero
    Device        = [IntPtr]::Zero
    ProviderCount = [uint32]0
    BackendCreateRc = [uint64]::MaxValue
    DeviceCreateRc  = [uint64]::MaxValue
    Delegates     = [Collections.Generic.Dictionary[string,object]]::new()
}

$getPointer = {
    param([string]$Name)
    $index = [int]$Abi.Slot[$Name]
    [Runtime.InteropServices.Marshal]::ReadIntPtr(
        $state.Functions,
        [IntPtr]::Size * $index
    )
}.GetNewClosure()

$getDelegate = {
    param(
        [string]$Name,
        [Type]$ReturnType,
        [Type[]]$ParameterTypes
    )

    [string]$cacheKey = $Name + '|' + $ReturnType.AssemblyQualifiedName
    foreach ($parameterType in $ParameterTypes) {
        $cacheKey += '|' + $parameterType.AssemblyQualifiedName
    }

    if ($state.Delegates.ContainsKey($cacheKey)) {
        return $state.Delegates[$cacheKey]
    }

    $delegateType = & $Abi.NewDelegateType $Name $ReturnType $ParameterTypes
    $delegate = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (& $getPointer $Name),
        $delegateType
    )
    $state.Delegates.Add($cacheKey, $delegate)
    $delegate
}.GetNewClosure()

$initialize = {
    param([object]$Android)

    if ($state.Initialized) {
        return $state
    }

    [string]$nativeRoot = $Android.NativeLibraryDirectory
    [string]$dataRoot = $Android.DataRoot
    if ([string]::IsNullOrWhiteSpace($nativeRoot)) {
        throw 'AndroidSMA did not publish NativeLibraryDirectory.'
    }
    if ([string]::IsNullOrWhiteSpace($dataRoot)) {
        throw 'AndroidSMA did not publish DataRoot.'
    }

    [Environment]::SetEnvironmentVariable('ADSP_LIBRARY_PATH', $nativeRoot)
    [Android.Systems.Os]::Setenv('ADSP_LIBRARY_PATH', $nativeRoot, $true)

    $preparePath = [IO.Path]::Combine($dataRoot, 'libQnnHtpPrepare.so')
    $state.PrepareHandle = [Runtime.InteropServices.NativeLibrary]::Load($preparePath)
    $state.LibraryHandle = [Runtime.InteropServices.NativeLibrary]::Load('libQnnHtp.so')

    $providerExport = [Runtime.InteropServices.NativeLibrary]::GetExport(
        $state.LibraryHandle,
        'QnnInterface_getProviders'
    )
    $providerType = & $Abi.NewDelegateType `
        'GetProviders' ([uint64]) ([Type[]]@(
            ([IntPtr]).MakeByRefType(),
            ([uint32]).MakeByRefType()
        ))
    $getProviders = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        $providerExport,
        $providerType
    )
    $providerArgs = [object[]]@([IntPtr]::Zero, [uint32]0)
    $providerRc = [uint64]$getProviders.DynamicInvoke($providerArgs)
    if ($providerRc -ne 0 -or [uint32]$providerArgs[1] -lt 1) {
        throw "QnnInterface_getProviders rc=$providerRc count=$($providerArgs[1])"
    }

    $state.ProviderCount = [uint32]$providerArgs[1]
    $state.Provider = [Runtime.InteropServices.Marshal]::ReadIntPtr(
        [IntPtr]$providerArgs[0],
        0
    )
    $state.Functions = [IntPtr]($state.Provider.ToInt64() + 40)

    $backendCreate = & $getDelegate `
        'BackendCreate' ([uint64]) ([Type[]]@(
            [IntPtr], [IntPtr], ([IntPtr]).MakeByRefType()
        ))
    $backendArgs = [object[]]@(
        [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero
    )
    $backendRc = [uint64]$backendCreate.DynamicInvoke($backendArgs)
    if ($backendRc -ne 0) {
        throw "backendCreate rc=$backendRc"
    }
    $state.Backend = [IntPtr]$backendArgs[2]

    $deviceCreate = & $getDelegate `
        'DeviceCreate' ([uint64]) ([Type[]]@(
            [IntPtr], [IntPtr], ([IntPtr]).MakeByRefType()
        ))
    $deviceArgs = [object[]]@(
        [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero
    )
    $deviceRc = [uint64]$deviceCreate.DynamicInvoke($deviceArgs)
    $state.Device = [IntPtr]$deviceArgs[2]

    $state.NativeRoot = $nativeRoot
    $state.DataRoot = $dataRoot
    $state.Initialized = $true
    $state.Generation++
    $state.BackendCreateRc = $backendRc
    $state.DeviceCreateRc = $deviceRc
    $state
}.GetNewClosure()

$newTrial = {
    param([string]$GraphName)

    if (-not $state.Initialized) {
        throw 'Qnn.Native must be initialized before opening a trial.'
    }

    $contextCreate = & $getDelegate `
        'ContextCreate' ([uint64]) ([Type[]]@(
            [IntPtr], [IntPtr], [IntPtr], ([IntPtr]).MakeByRefType()
        ))
    $contextArgs = [object[]]@(
        $state.Backend, $state.Device, [IntPtr]::Zero, [IntPtr]::Zero
    )
    $contextRc = [uint64]$contextCreate.DynamicInvoke($contextArgs)
    $context = [IntPtr]$contextArgs[3]
    if ($contextRc -ne 0 -or $context -eq [IntPtr]::Zero) {
        throw "contextCreate rc=$contextRc"
    }

    $namePointer = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($GraphName)
    try {
        $graphCreate = & $getDelegate `
            'GraphCreate' ([uint64]) ([Type[]]@(
                [IntPtr], [IntPtr], [IntPtr], ([IntPtr]).MakeByRefType()
            ))
        $graphArgs = [object[]]@(
            $context, $namePointer, [IntPtr]::Zero, [IntPtr]::Zero
        )
        $graphRc = [uint64]$graphCreate.DynamicInvoke($graphArgs)
        $graph = [IntPtr]$graphArgs[3]
        if ($graphRc -ne 0 -or $graph -eq [IntPtr]::Zero) {
            throw "graphCreate rc=$graphRc name=$GraphName"
        }
    }
    catch {
        $contextFree = & $getDelegate `
            'ContextFree' ([uint64]) ([Type[]]@([IntPtr], [IntPtr]))
        [void]$contextFree.DynamicInvoke([object[]]@($context, [IntPtr]::Zero))
        throw
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($namePointer)
    }

    [pscustomobject]@{
        PSTypeName = 'AndroidSMA.Qnn.Trial'
        Name       = $GraphName
        Context    = $context
        Graph      = $graph
        Generation = $state.Generation
        Closed     = $false
    }
}.GetNewClosure()

$closeTrial = {
    param([object]$Trial)
    if ($null -eq $Trial -or $Trial.Closed) {
        return [uint64]0
    }
    $contextFree = & $getDelegate `
        'ContextFree' ([uint64]) ([Type[]]@([IntPtr], [IntPtr]))
    $rc = [uint64]$contextFree.DynamicInvoke(
        [object[]]@($Trial.Context, [IntPtr]::Zero)
    )
    $Trial.Closed = $true
    $rc
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName  = 'AndroidSMA.Qnn.NativeCapability'
    Name        = 'Qnn.Native'
    Abi         = $Abi
    State       = $state
    Initialize  = $initialize
    NewTrial    = $newTrial
    CloseTrial  = $closeTrial
    GetPointer  = $getPointer
    GetDelegate = $getDelegate
}
