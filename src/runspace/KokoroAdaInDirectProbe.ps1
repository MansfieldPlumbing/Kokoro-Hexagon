# Diagnostic harness only. Loads PC fixtures and returns DSP outputs; no host
# normalization or tensor stage dispatch. FullLanguage for vetted native ABI.
$root=[IO.Path]::Combine($Activity.FilesDir.AbsolutePath,'kokoro-fl','adain-direct')
$blockMode=$false # Host adapter specializes this reviewed diagnostic constant.
$repeatCount=1 # Bounded host-selected diagnostic repetitions, not product control.
$lines=[Collections.Generic.List[string]]::new()
$lines.Add('Job=direct-adain')
$M=[Runtime.InteropServices.Marshal]
$allocations=[Collections.Generic.List[object]]::new()
$native=[IntPtr]::Zero;$opened=$false;$handle=[uint64]0;$passed=$false
try {
    $modulePath=[IO.Path]::Combine($root,'Native.Binding.psm1')
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($modulePath))) -cne
        '7A42BF2FE487C303116E315CA594736B2D3FDA24FE2741618736427AB062E89F'){throw 'Native binding pin mismatch'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Native binding parse failed'}
    $abi=$ast.GetScriptBlock().InvokeReturnAsIs()
    # Fixture data is fixed and bounded; JSON cmdlets are unavailable in this
    # historical minimal host, so the reviewed case list is explicit here.
    $names=@('varying','shifted','constant','nearconstant','alternating','changed-control','nan-input','tail-nan-input','large-input','nan-control','tail-nan-control','short-input','wrong-shape')
    if($blockMode){$names=@('stock-block','mutated-style-block')}
    $controlLength=if($blockMode){1195008}else{1024}
    $signature=if($blockMode){[uint32]0x02030200}else{[uint32]0x02030100}
    $search=$root+';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach($name in 'ADSP_LIBRARY_PATH','DSP_LIBRARY_PATH'){
        [Environment]::SetEnvironmentVariable($name,$search)
        [Android.Systems.Os]::Setenv($name,$search,$true)
    }
    $native=[Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn={param($Name,$ReturnType,$Parameters)
        $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native,$Name),
            (& $abi.NewDelegateType ('AdaIn_'+$Name) $ReturnType $Parameters))
    }
    $control=& $fn 'remote_session_control' ([int]) ([Type[]]@([uint32],[IntPtr],[uint32]))
    $open=& $fn 'remote_handle64_open' ([int]) ([Type[]]@([IntPtr],([uint64]).MakeByRefType()))
    $invoke=& $fn 'remote_handle64_invoke' ([int]) ([Type[]]@([uint64],[uint32],[IntPtr]))
    $close=& $fn 'remote_handle64_close' ([int]) ([Type[]]@([uint64]))
    $allocate={param([int]$Size)
        if($Size -lt 1 -or $Size -gt 1195008){throw 'Diagnostic allocation bound exceeded'}
        $p=$M::AllocHGlobal($Size);$allocations.Add(@($p,$Size))
        $M::Copy([byte[]]::new($Size),0,$p,$Size);$p
    }
    $config=& $allocate 8;$M::WriteInt32($config,0,3);$M::WriteInt32($config,4,1)
    $rc=[int]$control.DynamicInvoke([object[]]@([uint32]2,$config,[uint32]8))
    $lines.Add("UnsignedPdRc=$rc");if($rc -ne 0){throw 'Unsigned PD configuration failed'}
    $uri='file:///libkokoro_adain_skel.so?kokoro_adain_skel_handle_invoke&_modver=1.0&_dom=cdsp'
    if($blockMode){$uri='file:///libkokoro_adain_resblock_skel.so?kokoro_adain_resblock_skel_handle_invoke&_modver=1.0&_dom=cdsp'}
    $uriBytes=[Text.Encoding]::UTF8.GetBytes($uri+[char]0)
    $uriPtr=& $allocate $uriBytes.Length;$M::Copy($uriBytes,0,$uriPtr,$uriBytes.Length)
    $openArgs=[object[]]@($uriPtr,[uint64]0);$rc=[int]$open.DynamicInvoke($openArgs)
    $lines.Add("OpenRc=$rc");if($rc -ne 0){throw 'Emitted AdaIN library open failed'}
    $handle=[uint64]$openArgs[1];$opened=$true
    $geometry=& $allocate 8;$x=& $allocate 32768;$affine=& $allocate $controlLength
    $y=& $allocate 32768;$argsPtr=& $allocate 80
    $argList=@(@(0,$geometry,8),@(16,$x,32768),@(32,$affine,$controlLength),@(48,$y,32768))
    if($blockMode){$scratch=& $allocate 103424;$argList=@(@(0,$geometry,8),@(16,$x,32768),@(32,$affine,$controlLength),@(48,$scratch,103424),@(64,$y,32768))}
    foreach($a in $argList){
        $M::WriteIntPtr($argsPtr,$a[0],$a[1]);$M::WriteInt64($argsPtr,$a[0]+8,$a[2])
    }
    foreach($name in $names){
        $inputBytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($root,$name+'.input.bin'))
        $controlBytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($root,$name+'.control.bin'))
        if($inputBytes.Length -ne 32768 -or $controlBytes.Length -ne $controlLength){throw 'Fixture size mismatch'}
        $M::Copy($inputBytes,0,$x,32768);$M::Copy($controlBytes,0,$affine,$controlLength)
        $M::WriteInt32($geometry,0,$(if($name -eq 'wrong-shape'){63}else{64}));$M::WriteInt32($geometry,4,128)
        $M::WriteInt64($argsPtr,24,$(if($name -eq 'short-input'){4}else{32768}))
        $expected=if($name -in 'nan-input','tail-nan-input','large-input','nan-control','tail-nan-control'){33}elseif($name -in 'short-input','wrong-shape'){14}else{0}
        $firstHash=$null
        for($repeat=0;$repeat -lt $repeatCount;$repeat++){
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $rc=[int]$invoke.DynamicInvoke([object[]]@($handle,$signature,$argsPtr))
        $watch.Stop();$lines.Add("Case=$name Repeat=$repeat Rc=$rc Expected=$expected InvokeMs=$($watch.Elapsed.TotalMilliseconds)")
        if($blockMode -and $rc -eq 35){$lines.Add("VectorCanaryExpectedBits=$($M::ReadInt32($y,0)) ActualBits=$($M::ReadInt32($y,4))")}
        if($rc -ne $expected){throw 'AdaIN dispatch result differs'}
        if($rc -eq 0){
            $result=[byte[]]::new(32768);$M::Copy($y,$result,0,32768)
            $resultHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($result))
            if($repeat -eq 0){$firstHash=$resultHash}elseif($resultHash -cne $firstHash){throw 'Repeated output differs'}
            [IO.File]::WriteAllBytes([IO.Path]::Combine($root,$name+'.output.bin'),$result)
        }
        }
    }
    $rc=[int]$invoke.DynamicInvoke([object[]]@($handle,[uint32]0x03000000,[IntPtr]::Zero))
    $lines.Add("UnsupportedMethodRc=$rc");if($rc -ne 20){throw 'Unsupported method accepted'}
    $passed=$true
} catch {$lines.Add('Error='+$_.Exception.Message);$lines.Add('At='+$_.InvocationInfo.ScriptLineNumber)}
finally {
    if($opened){try {$rc=[int]$close.DynamicInvoke([object[]]@($handle));$lines.Add("CloseRc=$rc");if($rc -ne 0){$passed=$false}}catch{$passed=$false}}
    foreach($item in $allocations){$M::Copy([byte[]]::new([int]$item[1]),0,[IntPtr]$item[0],[int]$item[1]);$M::FreeHGlobal([IntPtr]$item[0])}
    if($native -ne [IntPtr]::Zero){[Runtime.InteropServices.NativeLibrary]::Free($native)}
}
$lines.Add("Passed=$passed")
[IO.File]::WriteAllLines([IO.Path]::Combine($root,'receipt.txt'),$lines)
