# Cmdlet-free device test. Uses existing r0 weights without upload or repacking.
# Ordinary pinned arrays are passed through FastRPC; zero-copy is not assumed.
$root=[IO.Path]::Combine($Activity.FilesDir.AbsolutePath,'kokoro-fl')
$dir=[IO.Path]::Combine($root,'affine-emitted')
$receipt=[IO.Path]::Combine($dir,'receipt.txt')
$lines=[Collections.Generic.List[string]]::new(); $lines.Add('Job=kokoro-affine-emitted')
$save={ [IO.File]::WriteAllLines($receipt,$lines) }
$hash={param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))}
$M=[Runtime.InteropServices.Marshal]; $native=[IntPtr]::Zero; $opened=$false
$pins=[Collections.Generic.List[object]]::new(); $allocations=[Collections.Generic.List[object]]::new()
$passed=$false; $setup=[Diagnostics.Stopwatch]::StartNew()
try {
    $modulePath=[IO.Path]::Combine($root,'emit.Qnn.Abi.ps1')
    if((& $hash ([IO.File]::ReadAllBytes($modulePath))) -ne 'B4820C76C79FC0B66EE96E27E8D655689F33181165F55E2B0A96A3A4BE34391D') { throw 'Delegate factory pin mismatch' }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
    if($errors.Count) { throw 'Delegate factory parse failed' }
    $abi=$ast.GetScriptBlock().InvokeReturnAsIs()
    $so=[IO.Path]::Combine($root,'qnn','libkqnn_affine_skel.so')
    $soHash=& $hash ([IO.File]::ReadAllBytes($so))
    if($soHash -ne 'E12719773385A53CDC3E21DD8E5D89E89E95C975C04FA2C3E6C6DD964044A1DD') { throw 'Emitted library pin mismatch' }
    $lines.Add('LibrarySHA256='+$soHash)
    $search=[IO.Path]::Combine($root,'qnn')+';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach($name in 'ADSP_LIBRARY_PATH','DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name,$search); [Android.Systems.Os]::Setenv($name,$search,$true)
    }
    $native=[Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn={param($Name,$ReturnType,$Parameters)
        $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native,$Name),
            (& $abi.NewDelegateType ('Affine_'+$Name) $ReturnType $Parameters))
    }
    $control=& $fn 'remote_session_control' ([int]) ([Type[]]@([uint32],[IntPtr],[uint32]))
    $open=& $fn 'remote_handle64_open' ([int]) ([Type[]]@([IntPtr],([uint64]).MakeByRefType()))
    $invoke=& $fn 'remote_handle64_invoke' ([int]) ([Type[]]@([uint64],[uint32],[IntPtr]))
    $close=& $fn 'remote_handle64_close' ([int]) ([Type[]]@([uint64]))
    $allocate={param([int]$Size)
        $ptr=$M::AllocHGlobal($Size); $allocations.Add(@($ptr,$Size)); $M::Copy([byte[]]::new($Size),0,$ptr,$Size); $ptr
    }
    $pin={param([byte[]]$Bytes)
        $g=[Runtime.InteropServices.GCHandle]::Alloc($Bytes,[Runtime.InteropServices.GCHandleType]::Pinned)
        $pins.Add($g); $g.AddrOfPinnedObject()
    }
    $config=& $allocate 8; $M::WriteInt32($config,0,3); $M::WriteInt32($config,4,1)
    $rc=[int]$control.DynamicInvoke([object[]]@([uint32]2,$config,[uint32]8))
    $lines.Add("UnsignedPdRc=$rc"); if($rc -ne 0) { throw 'Unsigned PD configuration failed' }
    $uri=[Text.Encoding]::UTF8.GetBytes('file:///libkqnn_affine_skel.so?kqnn_affine_skel_handle_invoke&_modver=1.0&_dom=cdsp'+[char]0)
    $uriPtr=& $pin $uri; $oa=[object[]]@($uriPtr,[uint64]0)
    $rc=[int]$open.DynamicInvoke($oa); $lines.Add("OpenRc=$rc")
    if($rc -ne 0) { throw 'Emitted affine library open failed' }
    $handle=[uint64]$oa[1]; $opened=$true
    $weights=[IO.File]::ReadAllBytes([IO.Path]::Combine($root,'r0','r0_static.bin'))
    $weightHash=& $hash $weights
    if($weights.Length -ne 1195008 -or $weightHash -ne '997CF6049BBDF8BD987CC757CE04D5EEF73C167315C4E426FEF275AB4A0F3B05') { throw 'Existing weight pin mismatch' }
    $input=[IO.File]::ReadAllBytes([IO.Path]::Combine($dir,'normalized.f32'))
    if($input.Length -ne 3932672 -or (& $hash $input) -ne '2392D4BA33E9A036BA3A33902A7DEE4FC9035BCBFE7D1FD2C6171B34ECF526C0') { throw 'Reference input pin mismatch' }
    $expectedHash='FB44F04A5776DC460C67EE74AB9D25C5063D606663A5A06F511EDFC9CEF85C8F'
    $fused=[byte[]]::new($input.Length); $middle=[byte[]]::new($input.Length); $split=[byte[]]::new($input.Length)
    $inputPtr=& $pin $input; $weightPtr=& $pin $weights; $fusedPtr=& $pin $fused; $middlePtr=& $pin $middle; $splitPtr=& $pin $split
    $geometry=& $allocate 8; $M::WriteInt32($geometry,0,7681); $M::WriteInt32($geometry,4,128)
    $makeArgs={param([IntPtr]$InputPtr,[IntPtr]$OutputPtr)
        $p=& $allocate 64
        $M::WriteIntPtr($p,0,$geometry); $M::WriteInt64($p,8,8)
        $M::WriteIntPtr($p,16,$InputPtr); $M::WriteInt64($p,24,3932672)
        $M::WriteIntPtr($p,32,$weightPtr); $M::WriteInt64($p,40,1195008)
        $M::WriteIntPtr($p,48,$OutputPtr); $M::WriteInt64($p,56,3932672)
        $p
    }
    $fusedArgs=& $makeArgs $inputPtr $fusedPtr; $mulArgs=& $makeArgs $inputPtr $middlePtr; $addArgs=& $makeArgs $middlePtr $splitPtr
    $fa=[object[]]@($handle,[uint32]0x02030100,$fusedArgs)
    $ma=[object[]]@($handle,[uint32]0x03030100,$mulArgs)
    $aa=[object[]]@($handle,[uint32]0x04030100,$addArgs)
    $lines.Add("SetupMs=$($setup.Elapsed.TotalMilliseconds.ToString('F3',[Globalization.CultureInfo]::InvariantCulture))")
    $lines.Add('Shape=128x7681 WeightSource=existing-r0 WeightRepack=False BufferMode=pinned-managed-arrays')
    & $save
    # Cold correctness calls precede timings. FP multiply/add are separate rounds in both paths.
    $cold=[Diagnostics.Stopwatch]::StartNew(); $rc=[int]$invoke.DynamicInvoke($fa); $cold.Stop()
    if($rc -ne 0) { throw "Fused call rc=$rc" }
    $lines.Add("ColdFusedMs=$($cold.Elapsed.TotalMilliseconds.ToString('F3',[Globalization.CultureInfo]::InvariantCulture))")
    $actual=& $hash $fused
    $lines.Add("FusedSHA256=$actual ExactReference=$($actual -eq $expectedHash)"); & $save
    if($actual -ne $expectedHash) { [IO.File]::WriteAllBytes([IO.Path]::Combine($dir,'fused-mismatch.f32'),$fused); throw 'Fused result differs from fp32 reference' }
    $rc=[int]$invoke.DynamicInvoke($ma); if($rc -ne 0){throw "Multiply call rc=$rc"}
    $rc=[int]$invoke.DynamicInvoke($aa); if($rc -ne 0){throw "Shift call rc=$rc"}
    $actual=& $hash $split
    $lines.Add("SplitSHA256=$actual ExactReference=$($actual -eq $expectedHash)"); & $save
    if($actual -ne $expectedHash) { throw 'Split result differs from fp32 reference' }
    $fm=[double[]]::new(12); $sm=[double[]]::new(12)
    for($iteration=0;$iteration -lt 12;$iteration++) {
        $order=if($iteration%2 -eq 0){@(0,1)}else{@(1,0)}
        foreach($mode in $order) {
            $sw=[Diagnostics.Stopwatch]::StartNew()
            if($mode -eq 0) { $rc=[int]$invoke.DynamicInvoke($fa) }
            else { $rc=[int]$invoke.DynamicInvoke($ma); if($rc -eq 0){$rc=[int]$invoke.DynamicInvoke($aa)} }
            $sw.Stop(); if($rc -ne 0){throw "Timed invoke rc=$rc"}
            if($mode -eq 0){$fm[$iteration]=$sw.Elapsed.TotalMilliseconds}else{$sm[$iteration]=$sw.Elapsed.TotalMilliseconds}
        }
        $lines.Add(('Pair={0} FusedMs={1:F3} SplitMs={2:F3}' -f $iteration,$fm[$iteration],$sm[$iteration]))
        & $save
    }
    [Array]::Sort($fm); [Array]::Sort($sm)
    $fmedian=($fm[5]+$fm[6])/2; $smedian=($sm[5]+$sm[6])/2
    $lines.Add(('FusedMedianMs={0:F3} SplitMedianMs={1:F3} SplitOverFused={2:F3}' -f $fmedian,$smedian,($smedian/$fmedian)))
    if((& $hash $fused) -ne $expectedHash -or (& $hash $split) -ne $expectedHash -or (& $hash $weights) -ne $weightHash -or (& $hash $input) -ne '2392D4BA33E9A036BA3A33902A7DEE4FC9035BCBFE7D1FD2C6171B34ECF526C0') { throw 'Post-timing integrity failure' }
    $lines.Add('PostTimingIntegrity=True')
    # Invalid geometry and undersized input must reject without reading output values.
    $M::WriteInt32($geometry,0,7680); $rc=[int]$invoke.DynamicInvoke($fa)
    $lines.Add("WrongGeometryRc=$rc"); if($rc -ne 14){throw 'Geometry guard failed'}
    $M::WriteInt32($geometry,0,7681); $M::WriteInt64($fusedArgs,24,4)
    $echoRc=[int]$invoke.DynamicInvoke([object[]]@($handle,[uint32]0x05030100,$fusedArgs))
    $lines.Add("LengthEchoRc=$echoRc HostInputLength=$($M::ReadInt64($fusedArgs,24)) DspLengths=$($M::ReadInt32($fusedPtr,0)),$($M::ReadInt32($fusedPtr,4)),$($M::ReadInt32($fusedPtr,8)),$($M::ReadInt32($fusedPtr,12))")
    $rc=[int]$invoke.DynamicInvoke($fa); $lines.Add("ShortInputRc=$rc"); if($rc -ne 14){throw 'Length guard failed'}
    $M::WriteInt64($fusedArgs,24,3932672)
    foreach($short in @(@(8,4,'geometry'),@(40,4,'weights'),@(56,4,'output'))) {
        $prior=$M::ReadInt64($fusedArgs,$short[0]); $M::WriteInt64($fusedArgs,$short[0],$short[1])
        $rc=[int]$invoke.DynamicInvoke($fa); $lines.Add("Short-$($short[2])-Rc=$rc")
        $M::WriteInt64($fusedArgs,$short[0],$prior)
        if($rc -ne 14){throw 'Buffer length guard failed'}
    }
    $passed=$true
}
catch { $lines.Add('Error='+$_.Exception.Message); $lines.Add('At='+$_.InvocationInfo.ScriptLineNumber) }
finally {
    if($opened) {
        try {$rc=[int]$close.DynamicInvoke([object[]]@($handle)); $lines.Add("CloseRc=$rc"); if($rc -ne 0){$passed=$false}}
        catch {$passed=$false; $lines.Add('CloseError='+$_.Exception.Message)}
    }
    foreach($item in $allocations){$M::Copy([byte[]]::new([int]$item[1]),0,[IntPtr]$item[0],[int]$item[1]); $M::FreeHGlobal([IntPtr]$item[0])}
    foreach($pinHandle in $pins){if($pinHandle.IsAllocated){$pinHandle.Free()}}
    foreach($buffer in @($weights,$input,$fused,$middle,$split)){if($null -ne $buffer){[Array]::Clear($buffer,0,$buffer.Length)}}
    if($native -ne [IntPtr]::Zero){[Runtime.InteropServices.NativeLibrary]::Free($native)}
}
$lines.Add("Passed=$passed"); & $save
[void][Android.Util.Log]::Info('KokoroAffine',($lines -join ' | '))
