#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$path = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'src', 'runspace', 'Native.Binding.psm1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Native.Binding.psm1 does not parse.' }
$binding = $ast.GetScriptBlock().InvokeReturnAsIs()

$coldClock = [Diagnostics.Stopwatch]::StartNew()
$first = & $binding.NewDelegateType 'Pid' ([int]) ([Type[]]@())
$coldMicroseconds = $coldClock.Elapsed.TotalMicroseconds
$second = & $binding.NewDelegateType 'PidAgain' ([int]) ([Type[]]@())
if (-not [object]::ReferenceEquals($first, $second)) {
    throw 'Equivalent native signatures did not reuse a delegate type.'
}
$cacheClock = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 10000; $i++) {
    [void](& $binding.NewDelegateType 'PidCached' ([int]) ([Type[]]@()))
}
$cacheNanosecondsPerLookup = $cacheClock.Elapsed.TotalNanoseconds / 10000

$libraryName = if ($IsWindows) { 'kernel32.dll' } else { 'libc.so.6' }
$exportName = if ($IsWindows) { 'GetCurrentProcessId' } else { 'getpid' }
$library = [Runtime.InteropServices.NativeLibrary]::Load($libraryName)
try {
    $getPid = & $binding.BindExport $library $exportName ([int]) ([Type[]]@())
    $processId = [int]$getPid.DynamicInvoke([object[]]@())
    if ($processId -ne [Environment]::ProcessId) { throw 'Native process id did not match the managed process id.' }
}
finally {
    [Runtime.InteropServices.NativeLibrary]::Free($library)
}

[pscustomobject]@{
    Parsed = $true
    SignatureCache = $true
    ColdTypeMicroseconds = [Math]::Round($coldMicroseconds, 1)
    CachedNanosecondsPerLookup = [Math]::Round($cacheNanosecondsPerLookup, 1)
    NativeCall = $true
    Passed = $true
}
