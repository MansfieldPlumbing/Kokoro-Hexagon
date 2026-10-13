param()

# Generic C ABI binding for the FullLanguageMode appliance runspace. Delegate
# types are emitted once per signature; no source text is compiled or evaluated.
$typeCache = [Collections.Generic.Dictionary[string, Type]]::new([StringComparer]::Ordinal)
$delegateCounter = 0

$newDelegateType = {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][Type]$ReturnType,
        [Parameter(Mandatory)][AllowEmptyCollection()][Type[]]$ParameterTypes,
        [bool]$SetLastError = $false
    )

    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') {
        throw 'Native delegate name is invalid.'
    }
    if ($null -eq $ReturnType -or $null -eq $ParameterTypes) {
        throw 'Native delegate signature is incomplete.'
    }

    $parameterNames = [Collections.Generic.List[string]]::new($ParameterTypes.Count)
    foreach ($parameterType in $ParameterTypes) {
        if ($null -eq $parameterType) { throw 'Native delegate parameter type is null.' }
        $parameterNames.Add($parameterType.AssemblyQualifiedName)
    }
    $signature = $ReturnType.AssemblyQualifiedName + '(' + ($parameterNames -join ',') + ')' +
        ':SetLastError=' + $SetLastError
    if ($typeCache.ContainsKey($signature)) { return $typeCache[$signature] }

    $delegateCounter++
    $safeName = 'Native_' + $Name + '_' + $delegateCounter
    $assemblyName = [Reflection.AssemblyName]::new(
        "Kokoro.NativeBinding.$delegateCounter.$([Guid]::NewGuid().ToString('N'))"
    )
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        $assemblyName,
        [Reflection.Emit.AssemblyBuilderAccess]::Run
    )
    $module = $assembly.DefineDynamicModule('NativeDelegates')
    $builder = $module.DefineType(
        $safeName,
        [Reflection.TypeAttributes]'Class, Public, Sealed',
        [MulticastDelegate]
    )

    $attributeConstructor = [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(
        [Type[]]@([Runtime.InteropServices.CallingConvention])
    )
    $lastErrorField = [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetField('SetLastError')
    $attribute = [Reflection.Emit.CustomAttributeBuilder]::new(
        $attributeConstructor,
        [object[]]@([Runtime.InteropServices.CallingConvention]::Cdecl),
        [Reflection.PropertyInfo[]]@(),
        [object[]]@(),
        [Reflection.FieldInfo[]]@($lastErrorField),
        [object[]]@($SetLastError)
    )
    $builder.SetCustomAttribute($attribute)

    $constructor = $builder.DefineConstructor(
        [Reflection.MethodAttributes]'RTSpecialName, HideBySig, Public',
        [Reflection.CallingConventions]::Standard,
        [Type[]]@([object], [IntPtr])
    )
    $constructor.SetImplementationFlags([Reflection.MethodImplAttributes]::Runtime)
    $invoke = $builder.DefineMethod(
        'Invoke',
        [Reflection.MethodAttributes]'Public, HideBySig, NewSlot, Virtual',
        $ReturnType,
        $ParameterTypes
    )
    $invoke.SetImplementationFlags([Reflection.MethodImplAttributes]::Runtime)

    $type = $builder.CreateType()
    $typeCache.Add($signature, $type)
    $type
}.GetNewClosure()

$bindExport = {
    param(
        [Parameter(Mandatory)][IntPtr]$Library,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][Type]$ReturnType,
        [Parameter(Mandatory)][AllowEmptyCollection()][Type[]]$ParameterTypes,
        [bool]$SetLastError = $false
    )
    if ($Library -eq [IntPtr]::Zero) { throw 'Native library handle is null.' }
    $address = [Runtime.InteropServices.NativeLibrary]::GetExport($Library, $Name)
    $type = & $newDelegateType $Name $ReturnType $ParameterTypes $SetLastError
    [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($address, $type)
}.GetNewClosure()

$newSharedPayload = {
    param([IntPtr]$Library, [byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 1) { throw 'Shared payload is empty.' }
    # FastRPC d2475196 inc/rpcmem.h and inc/remote.h: system heap 25,
    # uncached CPU allocation, static CDSP mapping. Payload is immutable after map.
    $allocate = & $bindExport $Library 'rpcmem_alloc' ([IntPtr]) ([Type[]]@([int],[uint32],[int]))
    $free = & $bindExport $Library 'rpcmem_free' ([void]) ([Type[]]@([IntPtr]))
    $toFd = & $bindExport $Library 'rpcmem_to_fd' ([int]) ([Type[]]@([IntPtr]))
    $map = & $bindExport $Library 'remote_mem_map' ([int]) ([Type[]]@([int],[int],[int],[uint64],[UIntPtr],([uint64]).MakeByRefType()))
    $unmap = & $bindExport $Library 'remote_mem_unmap' ([int]) ([Type[]]@([int],[uint64],[UIntPtr]))
    $size = [int64]([math]::Ceiling($Bytes.Length / 4096.0) * 4096)
    if ($size -gt [int]::MaxValue) { throw 'Shared payload exceeds rpcmem_alloc bounds.' }
    $pointer = $allocate.Invoke(25, [uint32]0, [int]$size)
    if ($pointer -eq [IntPtr]::Zero) { throw 'rpcmem_alloc failed.' }
    $remoteAddress = [uint64]0
    $mapped = $false
    try {
        [Runtime.InteropServices.Marshal]::Copy($Bytes, 0, $pointer, $Bytes.Length)
        $fd = $toFd.Invoke($pointer)
        if ($fd -lt 0) { throw 'rpcmem_to_fd failed.' }
        $mapArguments = [object[]]@([int]3,[int]$fd,[int]0,[uint64]$pointer.ToInt64(),[UIntPtr]::new([uint64]$size),[uint64]0)
        $rc = [int]$map.DynamicInvoke($mapArguments)
        if ($rc -ne 0) { throw "remote_mem_map failed rc=$rc" }
        $remoteAddress = [uint64]$mapArguments[5]; $mapped = $true
        if ($remoteAddress -eq 0 -or $remoteAddress + $Bytes.Length -gt [uint32]::MaxValue) {
            throw 'Shared payload is outside the DSP address range.'
        }
        [pscustomobject]@{Pointer=$pointer;RemoteAddress=$remoteAddress;Bytes=$Bytes.Length;MappedBytes=$size;Free=$free;Unmap=$unmap}
    }
    catch {
        if ($mapped) {
            $cleanupRc = $unmap.Invoke(3,$remoteAddress,[UIntPtr]::new([uint64]$size))
            if ($cleanupRc -ne 0) { throw "Shared payload cleanup failed rc=$cleanupRc; allocation retained until process exit." }
        }
        $free.Invoke($pointer)
        throw
    }
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName = 'Kokoro.Native.Binding'
    Name = 'Native.Binding'
    CallingConvention = 'Cdecl'
    NewDelegateType = $newDelegateType
    BindExport = $bindExport
    NewSharedPayload = $newSharedPayload
}
