# Cmdlet-free device probe for an ELF emitted entirely by PowerShell.
# Existing AndroidSMA host uses FullLanguage for native delegates and Marshal.
$root=[IO.Path]::Combine($Activity.FilesDir.AbsolutePath,'kokoro-fl')
$lines=[Collections.Generic.List[string]]::new()
$lines.Add('Job=hexagon-emitted-elf')
$M=[Runtime.InteropServices.Marshal]
$native=[IntPtr]::Zero; $handle=[uint64]0; $opened=$false
$allocations=[Collections.Generic.List[object]]::new()
$passed=$false
try {
    $modulePath=[IO.Path]::Combine($root,'Native.Binding.psm1')
    $moduleBytes=[IO.File]::ReadAllBytes($modulePath)
    $moduleHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($moduleBytes))
    if($moduleHash -ne 'B4820C76C79FC0B66EE96E27E8D655689F33181165F55E2B0A96A3A4BE34391D') { throw 'Delegate factory source pin mismatch' }
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count) { throw 'Delegate factory parse failed' }
    $abi=$ast.GetScriptBlock().InvokeReturnAsIs()
    $dspPath=[IO.Path]::Combine($root,'qnn')
    $soPath=[IO.Path]::Combine($dspPath,'libkqnn_emit_skel.so')
    $lines.Add('LibrarySHA256='+[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($soPath))))
    $search=$dspPath+';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach($name in 'ADSP_LIBRARY_PATH','DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name,$search)
        [Android.Systems.Os]::Setenv($name,$search,$true)
    }
    $native=[Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn={param($Name,$ReturnType,$Parameters)
        $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native,$Name),
            (& $abi.NewDelegateType ('Emit_'+$Name) $ReturnType $Parameters))
    }
    $control=& $fn 'remote_session_control' ([int]) ([Type[]]@([uint32],[IntPtr],[uint32]))
    $open=& $fn 'remote_handle64_open' ([int]) ([Type[]]@([IntPtr],([uint64]).MakeByRefType()))
    $invoke=& $fn 'remote_handle64_invoke' ([int]) ([Type[]]@([uint64],[uint32],[IntPtr]))
    $close=& $fn 'remote_handle64_close' ([int]) ([Type[]]@([uint64]))
    $allocate={param([int]$Size)
        $ptr=$M::AllocHGlobal($Size)
        $allocations.Add(@($ptr,$Size))
        $M::Copy([byte[]]::new($Size),0,$ptr,$Size)
        $ptr
    }
    $config=& $allocate 8
    $M::WriteInt32($config,0,3); $M::WriteInt32($config,4,1)
    $rc=[int]$control.DynamicInvoke([object[]]@([uint32]2,$config,[uint32]8))
    $lines.Add("UnsignedPdRc=$rc"); if($rc -ne 0) { throw 'Unsigned PD configuration failed' }
    $uri='file:///libkqnn_emit_skel.so?kqnn_emit_skel_handle_invoke&_modver=1.0&_dom=cdsp'
    $uriBytes=[Text.Encoding]::UTF8.GetBytes($uri+[char]0)
    $uriPtr=& $allocate $uriBytes.Length; $M::Copy($uriBytes,0,$uriPtr,$uriBytes.Length)
    $openArgs=[object[]]@($uriPtr,[uint64]0)
    $rc=[int]$open.DynamicInvoke($openArgs)
    $lines.Add("OpenRc=$rc"); if($rc -ne 0) { throw 'Emitted library open failed' }
    $handle=[uint64]$openArgs[1]; $opened=$true
    $input=& $allocate 8; $output=& $allocate 4; $argsPtr=& $allocate 32
    $M::WriteIntPtr($argsPtr,0,$input); $M::WriteInt64($argsPtr,8,8)
    $M::WriteIntPtr($argsPtr,16,$output); $M::WriteInt64($argsPtr,24,4)
    foreach($case in @(@(19,23,42),@(-200,73,-127),@([int]::MaxValue,1,[int]::MinValue),@(0,0,0))) {
        $M::WriteInt32($input,0,[int]$case[0]); $M::WriteInt32($input,4,[int]$case[1])
        $M::WriteInt32($output,0,123456789)
        $rc=[int]$invoke.DynamicInvoke([object[]]@($handle,[uint32]0x02010100,$argsPtr))
        $actual=$M::ReadInt32($output)
        $lines.Add("Add a=$($case[0]) b=$($case[1]) expected=$($case[2]) got=$actual rc=$rc")
        if($rc -ne 0 -or $actual -ne $case[2]) { throw 'Arithmetic mismatch' }
    }
    foreach($bad in @(@(8,4,'short-input'),@(24,0,'short-output'))) {
        $M::WriteInt32($output,0,123456789)
        $M::WriteInt64($argsPtr,[int]$bad[0],[long]$bad[1])
        $rc=[int]$invoke.DynamicInvoke([object[]]@($handle,[uint32]0x02010100,$argsPtr))
        # remote.h does not promise preservation of an output-only buffer on error.
        # Only a successful invocation makes the output a result to inspect.
        $lines.Add("Reject=$($bad[2]) rc=$rc")
        if($rc -ne 14) { throw 'Invalid-length rejection failed' }
        $M::WriteInt64($argsPtr,8,8); $M::WriteInt64($argsPtr,24,4)
    }
    $rc=[int]$invoke.DynamicInvoke([object[]]@($handle,[uint32]0x03000000,[IntPtr]::Zero))
    $lines.Add("UnsupportedMethodRc=$rc"); if($rc -ne 20) { throw 'Unsupported-method rejection failed' }
    $rc=[int]$invoke.DynamicInvoke([object[]]@($handle,[uint32]0x02000000,[IntPtr]::Zero))
    $lines.Add("WrongSignatureRc=$rc"); if($rc -ne 20) { throw 'Wrong-signature rejection failed' }
    $passed=$true
}
catch { $lines.Add('Error='+$_.Exception.Message); $lines.Add('At='+$_.InvocationInfo.ScriptLineNumber) }
finally {
    if($opened) {
        try { $rc=[int]$close.DynamicInvoke([object[]]@($handle)); $lines.Add("CloseRc=$rc"); if($rc -ne 0){$passed=$false} }
        catch { $passed=$false; $lines.Add('CloseError='+$_.Exception.Message) }
    }
    foreach($item in $allocations) {
        $M::Copy([byte[]]::new([int]$item[1]),0,[IntPtr]$item[0],[int]$item[1])
        $M::FreeHGlobal([IntPtr]$item[0])
    }
    if($native -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($native) }
}
$lines.Add("Passed=$passed")
[IO.File]::WriteAllLines([IO.Path]::Combine($root,'hexagon-emit-receipt.txt'),$lines)
[void][Android.Util.Log]::Info('KokoroEmit',($lines -join ' | '))
