# Cmdlet-free diagnostic for delayed rpcmem mapping and DSP-side execute permission.
# Existing AndroidSMA FullLanguage host; no changes to platform security settings.
$root=[IO.Path]::Combine($Activity.FilesDir.AbsolutePath,'kokoro-fl')
$receipt=[IO.Path]::Combine($root,'hexagon-exec-receipt.txt')
$lines=[Collections.Generic.List[string]]::new(); $lines.Add('Job=hexagon-exec-smoke')
$M=[Runtime.InteropServices.Marshal]
$native=[IntPtr]::Zero; $handle=[uint64]0; $opened=$false
$allocations=[Collections.Generic.List[object]]::new(); $complete=$false
$save={ [IO.File]::WriteAllLines($receipt,$lines) }
try {
    $modulePath=[IO.Path]::Combine($root,'emit.Qnn.Abi.ps1')
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($modulePath))) -ne 'B4820C76C79FC0B66EE96E27E8D655689F33181165F55E2B0A96A3A4BE34391D') { throw 'Delegate factory source pin mismatch' }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
    if($errors.Count) { throw 'Delegate factory parse failed' }
    $abi=$ast.GetScriptBlock().InvokeReturnAsIs()
    $code=[IO.File]::ReadAllBytes([IO.Path]::Combine($root,'return73.bin'))
    if($code.Length -ne 8 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($code)) -ne 'D358D9C78B0FE0B715986D088178242968D3C0626B5C9E853195DD885B26036F') { throw 'Emitted function pin mismatch' }
    $so=[IO.Path]::Combine($root,'qnn','libkqnn_exec_skel.so')
    $soHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($so)))
    if($soHash -ne 'E22A8B4D98893AFE45A3C02E632F8C303BBB36DE62A7A01B99B5D986527C0D8A') { throw 'Diagnostic bootstrap pin mismatch' }
    $lines.Add('BootstrapSHA256='+$soHash)
    $search=[IO.Path]::Combine($root,'qnn')+';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach($name in 'ADSP_LIBRARY_PATH','DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name,$search); [Android.Systems.Os]::Setenv($name,$search,$true)
    }
    $native=[Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn={param($Name,$ReturnType,$Parameters)
        $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native,$Name),
            (& $abi.NewDelegateType ('Exec_'+$Name) $ReturnType $Parameters))
    }
    $control=& $fn 'remote_session_control' ([int]) ([Type[]]@([uint32],[IntPtr],[uint32]))
    $open=& $fn 'remote_handle64_open' ([int]) ([Type[]]@([IntPtr],([uint64]).MakeByRefType()))
    $invoke=& $fn 'remote_handle64_invoke' ([int]) ([Type[]]@([uint64],[uint32],[IntPtr]))
    $close=& $fn 'remote_handle64_close' ([int]) ([Type[]]@([uint64]))
    $alloc=& $fn 'rpcmem_alloc' ([IntPtr]) ([Type[]]@([int],[uint32],[int]))
    $free=& $fn 'rpcmem_free' ([void]) ([Type[]]@([IntPtr]))
    $tofd=& $fn 'rpcmem_to_fd' ([int]) ([Type[]]@([IntPtr]))
    $map=& $fn 'fastrpc_mmap' ([int]) ([Type[]]@([int],[int],[IntPtr],[int],[UIntPtr],[int]))
    $unmap=& $fn 'fastrpc_munmap' ([int]) ([Type[]]@([int],[int],[IntPtr],[UIntPtr]))
    $init=& $fn 'rpcmem_init' ([void]) ([Type[]]@())
    [void]$init.DynamicInvoke([object[]]@())
    $allocate={param([int]$Size)
        $ptr=$M::AllocHGlobal($Size); $allocations.Add(@($ptr,$Size))
        $M::Copy([byte[]]::new($Size),0,$ptr,$Size); $ptr
    }
    $config=& $allocate 8
    $M::WriteInt32($config,0,3); $M::WriteInt32($config,4,1)
    $rc=[int]$control.DynamicInvoke([object[]]@([uint32]2,$config,[uint32]8))
    $lines.Add("UnsignedPdRc=$rc"); if($rc -ne 0) { throw 'Unsigned PD configuration failed' }
    $uri=[Text.Encoding]::UTF8.GetBytes('file:///libkqnn_exec_skel.so?kqnn_exec_skel_handle_invoke&_modver=1.0&_dom=cdsp'+[char]0)
    $uriPtr=& $allocate $uri.Length; $M::Copy($uri,0,$uriPtr,$uri.Length)
    $oa=[object[]]@($uriPtr,[uint64]0); $rc=[int]$open.DynamicInvoke($oa)
    $lines.Add("OpenRc=$rc"); if($rc -ne 0) { throw 'Bootstrap open failed' }
    $handle=[uint64]$oa[1]; $opened=$true
    $input=& $allocate 24; $output=& $allocate 48; $argsPtr=& $allocate 32
    $M::WriteIntPtr($argsPtr,0,$input); $M::WriteInt64($argsPtr,8,24)
    $M::WriteIntPtr($argsPtr,16,$output); $M::WriteInt64($argsPtr,24,48)
    $rxMapped=$false; $rwxMapped=$false
    foreach($case in @(@('RW-control',3,0),@('RX-map',5,0),@('RX-execute',5,1),@('RWX-map',7,0),@('RWX-execute',7,1))) {
        if(($case[0] -eq 'RX-execute' -and -not $rxMapped) -or ($case[0] -eq 'RWX-execute' -and -not $rwxMapped)) {
            $lines.Add("Case=$($case[0]) Skipped=MappingRejected"); continue
        }
        $shared=[IntPtr]$alloc.DynamicInvoke([object[]]@([int]25,[uint32]1,[int]4096))
        if($shared -eq [IntPtr]::Zero) { throw 'rpcmem allocation failed' }
        $mapped=$false; $fd=-1
        try {
            $fd=[int]$tofd.DynamicInvoke([object[]]@($shared)); if($fd -lt 0) { throw 'rpcmem_to_fd failed' }
            $rc=[int]$map.DynamicInvoke([object[]]@([int]3,$fd,$shared,[int]0,[UIntPtr]4096,[int]3))
            $lines.Add("Case=$($case[0]) HostDelayedMapRc=$rc"); & $save
            if($rc -ne 0) { throw 'Host delayed mapping failed' }
            $mapped=$true
            $values=[int[]]@($fd,$case[1],$case[2],[BitConverter]::ToInt32($code,0),[BitConverter]::ToInt32($code,4),4096)
            $M::Copy($values,0,$input,6)
            $M::Copy([byte[]]::new(48),0,$output,48)
            $lines.Add("Calling=$($case[0])"); & $save
            $rc=[int]$invoke.DynamicInvoke([object[]]@($handle,[uint32]0x02010100,$argsPtr))
            if($rc -ne 0) { throw "DSP invoke failed: $rc" }
            $r=[int[]]::new(12); $M::Copy($output,$r,0,12)
            $lines.Add("Case=$($case[0]) RwMapped=$($r[2]) DataFlushRc=$($r[3]) RwUnmapRc=$($r[4]) TargetMapped=$($r[5]) ICacheRc=$($r[6]) Called=$($r[7]) Value=$($r[8]) TargetUnmapRc=$($r[9]) WriteMatch=$($r[10]) ReadMatch=$($r[11])")
            & $save
            if($r[0] -ne 0x45584543 -or $r[1] -ne $case[1] -or $r[2] -ne 1 -or $r[3] -ne 0 -or $r[4] -ne 0 -or $r[10] -ne 1) { throw 'RW preparation control failed' }
            if($r[5] -eq 1 -and ($r[9] -ne 0 -or $r[11] -ne 1)) { throw 'Target readback/unmap failed' }
            if($case[0] -eq 'RW-control' -and $r[5] -ne 1) { throw 'RW remapping control failed' }
            if($case[0] -eq 'RX-map') { $rxMapped=$r[5] -eq 1 }
            if($case[0] -eq 'RWX-map') { $rwxMapped=$r[5] -eq 1 }
            if($case[2] -eq 1 -and ($r[5] -ne 1 -or $r[6] -ne 0 -or $r[7] -ne 1 -or $r[8] -ne 73)) { throw 'Emitted target execution failed' }
        }
        finally {
            if($mapped) {
                $rc=[int]$unmap.DynamicInvoke([object[]]@([int]3,$fd,$shared,[UIntPtr]4096))
                $lines.Add("Case=$($case[0]) HostUnmapRc=$rc")
                if($rc -ne 0) { throw 'Host unmap failed' }
            }
            $M::Copy([byte[]]::new(4096),0,$shared,4096)
            [void]$free.DynamicInvoke([object[]]@($shared))
        }
    }
    $complete=$true
}
catch { $lines.Add('Error='+$_.Exception.Message); $lines.Add('At='+$_.InvocationInfo.ScriptLineNumber) }
finally {
    if($opened) {
        try { $rc=[int]$close.DynamicInvoke([object[]]@($handle)); $lines.Add("CloseRc=$rc"); if($rc -ne 0){$complete=$false} }
        catch { $complete=$false; $lines.Add('CloseError='+$_.Exception.Message) }
    }
    foreach($item in $allocations) {
        $M::Copy([byte[]]::new([int]$item[1]),0,[IntPtr]$item[0],[int]$item[1]); $M::FreeHGlobal([IntPtr]$item[0])
    }
    if($native -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($native) }
}
$lines.Add("Completed=$complete"); & $save
[void][Android.Util.Log]::Info('KokoroExec',($lines -join ' | '))
