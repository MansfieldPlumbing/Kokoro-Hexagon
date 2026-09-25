param()

# Generic C ABI binding for the FullLanguageMode appliance runspace. Delegate
# types are emitted once per signature; no source text is compiled or evaluated.
$typeCache = [Collections.Generic.Dictionary[string, Type]]::new([StringComparer]::Ordinal)
$delegateCounter = 0

$newDelegateType = {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][Type]$ReturnType,
        [Parameter(Mandatory)][AllowEmptyCollection()][Type[]]$ParameterTypes
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
    $signature = $ReturnType.AssemblyQualifiedName + '(' + ($parameterNames -join ',') + ')'
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
        [Parameter(Mandatory)][AllowEmptyCollection()][Type[]]$ParameterTypes
    )
    if ($Library -eq [IntPtr]::Zero) { throw 'Native library handle is null.' }
    $address = [Runtime.InteropServices.NativeLibrary]::GetExport($Library, $Name)
    $type = & $newDelegateType $Name $ReturnType $ParameterTypes
    [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($address, $type)
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName = 'Kokoro.Native.Binding'
    Name = 'Native.Binding'
    CallingConvention = 'Cdecl'
    NewDelegateType = $newDelegateType
    BindExport = $bindExport
}
