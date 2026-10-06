# Cmdlet-free device test. Uses existing r0 weights without upload or repacking.
# Ordinary pinned arrays are passed through FastRPC; zero-copy is not assumed.
$root=[IO.Path]::Combine($Activity.FilesDir.AbsolutePath,'kokoro-fl')
$dir=[IO.Path]::Combine($root,'conv-tile-emitted')
$receipt=[IO.Path]::Combine($dir,'receipt.txt')
$lines=[Collections.Generic.List[string]]::new(); $lines.Add('Job=kokoro-conv-tile-emitted')
$save={ [IO.File]::WriteAllLines($receipt,$lines) }
$hash={param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))}
$M=[Runtime.InteropServices.Marshal]; $native=[IntPtr]::Zero; $opened=$false
$pins=[Collections.Generic.List[object]]::new(); $allocations=[Collections.Generic.List[object]]::new()
$passed=$false; $setup=[Diagnostics.Stopwatch]::StartNew()
try {
    $modulePath=[IO.Path]::Combine($root,'Native.Binding.psm1')
    if((& $hash ([IO.File]::ReadAllBytes($modulePath))) -ne 'B4820C76C79FC0B66EE96E27E8D655689F33181165F55E2B0A96A3A4BE34391D') { throw 'Delegate factory pin mismatch' }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
    if($errors.Count) { throw 'Delegate factory parse failed' }
    $abi=$ast.GetScriptBlock().InvokeReturnAsIs()
    $so=[IO.Path]::Combine($root,'qnn','libkokoro_conv_skel.so')
    $soHash=& $hash ([IO.File]::ReadAllBytes($so))
    if($soHash -ne 'C5953CE583A074CEFD96605FD65ACE31AEBC1E1B7917AA9ECCBE42EBE2372E59') { throw 'Emitted library pin mismatch' }
    $lines.Add('LibrarySHA256='+$soHash)
    $search=[IO.Path]::Combine($root,'qnn')+';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach($name in 'ADSP_LIBRARY_PATH','DSP_LIBRARY_PATH') {
        [Environment]::SetEnvironmentVariable($name,$search); [Android.Systems.Os]::Setenv($name,$search,$true)
    }
    $native=[Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn={param($Name,$ReturnType,$Parameters)
        $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native,$Name),
            (& $abi.NewDelegateType ('ConvTile_'+$Name) $ReturnType $Parameters))
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
    $uri=[Text.Encoding]::UTF8.GetBytes('file:///libkokoro_conv_skel.so?kokoro_conv_skel_handle_invoke&_modver=1.0&_dom=cdsp'+[char]0)
    $uriPtr=& $pin $uri; $oa=[object[]]@($uriPtr,[uint64]0)
    $rc=[int]$open.DynamicInvoke($oa); $lines.Add("OpenRc=$rc")
    if($rc -ne 0) { throw 'Emitted convolution library open failed' }
    $handle=[uint64]$oa[1]; $opened=$true
    $weights=[IO.File]::ReadAllBytes([IO.Path]::Combine($root,'r0','r0_static.bin'))
    $weightHash=& $hash $weights
    if($weights.Length -ne 1195008 -or $weightHash -ne '997CF6049BBDF8BD987CC757CE04D5EEF73C167315C4E426FEF275AB4A0F3B05'){throw 'Existing weight pin mismatch'}
    $jsonBytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($dir,'reference.json'))
    if((& $hash $jsonBytes) -ne '1C6D8710FEC9F86437CC73A4DB594914AFB5AFE920AA94F3249DC6F939F5DF13'){throw 'Reference manifest pin mismatch'}
    $document=[Text.Json.JsonDocument]::Parse([Text.Encoding]::UTF8.GetString($jsonBytes))
    $weightPtr=& $pin $weights
    $input=[byte[]]::new(34304); $output=[byte[]]::new(33280)
    $inputPtr=& $pin $input; $outputPtr=& $pin $output
    $geometry=& $allocate 8; $M::WriteInt32($geometry,0,65); $M::WriteInt32($geometry,4,128)
    $argsPtr=& $allocate 64
    $M::WriteIntPtr($argsPtr,0,$geometry); $M::WriteInt64($argsPtr,8,8)
    $M::WriteIntPtr($argsPtr,16,$inputPtr); $M::WriteInt64($argsPtr,24,34304)
    $M::WriteIntPtr($argsPtr,32,$weightPtr); $M::WriteInt64($argsPtr,40,1195008)
    $M::WriteIntPtr($argsPtr,48,$outputPtr); $M::WriteInt64($argsPtr,56,33280)
    $call=[object[]]@($handle,[uint32]0x02030100,$argsPtr)
    $lines.Add('Shape=128x65 Halo=1 WeightSource=existing-r0 WeightRepack=False BufferMode=pinned-managed-arrays')
    $lines.Add(('SetupMs={0:F3}' -f $setup.Elapsed.TotalMilliseconds)); & $save
    $index=0
    foreach($case in $document.RootElement.GetProperty('Cases').EnumerateArray()) {
        $start=$case.GetProperty('Start').GetInt32()
        if($start -ne (@(0,4096,7616))[$index]){throw 'Unexpected reference case'}
        $bytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($dir,"input-$start.f32"))
        $inputHash=$case.GetProperty('Input').GetProperty('SHA256').GetString()
        $expectedHash=$case.GetProperty('Expected').GetProperty('SHA256').GetString()
        if($bytes.Length -ne $input.Length -or (& $hash $bytes) -ne $inputHash){throw 'Input pin mismatch'}
        [Array]::Copy($bytes,$input,$bytes.Length); [Array]::Clear($bytes,0,$bytes.Length)
        $sw=[Diagnostics.Stopwatch]::StartNew(); $rc=[int]$invoke.DynamicInvoke($call); $sw.Stop()
        $actualHash=& $hash $output
        $lines.Add(('Start={0} Rc={1} Values=8320 ExactReference={2} Ms={3:F3} SHA256={4}' -f $start,$rc,($actualHash -eq $expectedHash),$sw.Elapsed.TotalMilliseconds,$actualHash)); & $save
        if($rc -ne 0 -or $actualHash -ne $expectedHash){
            [IO.File]::WriteAllBytes([IO.Path]::Combine($dir,"mismatch-$start.f32"),$output)
            throw 'Convolution differs from scalar fp32 reference'
        }
        if((& $hash $input) -ne $inputHash){throw 'Input mutated'}
        $index++
    }
    if($index -ne 3){throw 'Incomplete reference cases'}
    # Repeated unchanged execution records a baseline, not an optimization claim.
    $times=[double[]]::new(12)
    for($iteration=0;$iteration -lt 12;$iteration++) {
        $sw=[Diagnostics.Stopwatch]::StartNew(); $rc=[int]$invoke.DynamicInvoke($call); $sw.Stop()
        if($rc -ne 0 -or (& $hash $output) -ne $expectedHash){throw 'Repeated convolution changed'}
        $times[$iteration]=$sw.Elapsed.TotalMilliseconds
        $lines.Add(('Repeat={0} Ms={1:F3}' -f $iteration,$times[$iteration]))
    }
    [Array]::Sort($times); $median=($times[5]+$times[6])/2
    $deviations=[double[]]::new(12)
    for($i=0;$i -lt 12;$i++){$deviations[$i]=[Math]::Abs($times[$i]-$median)}
    [Array]::Sort($deviations)
    $lines.Add(('MedianMs={0:F3} MADMs={1:F3} MinMs={2:F3} MaxMs={3:F3}' -f $median,(($deviations[5]+$deviations[6])/2),$times[0],$times[11])); & $save
    if((& $hash $weights) -ne $weightHash -or (& $hash $input) -ne $inputHash){throw 'Post-timing integrity failure'}
    $lines.Add('PostTimingIntegrity=True')
    foreach($dimension in 0,4){
        $prior=$M::ReadInt32($geometry,$dimension); $M::WriteInt32($geometry,$dimension,$prior-1)
        $rc=[int]$invoke.DynamicInvoke($call); $M::WriteInt32($geometry,$dimension,$prior)
        $lines.Add("WrongDimensionOffset=$dimension Rc=$rc")
        if($rc -ne 14){throw 'Geometry guard failed'}
    }
    foreach($offset in 8,24,40,56){
        $prior=$M::ReadInt64($argsPtr,$offset); $M::WriteInt64($argsPtr,$offset,$prior-1)
        $rc=[int]$invoke.DynamicInvoke($call); $M::WriteInt64($argsPtr,$offset,$prior)
        $lines.Add("ShortBufferOffset=$offset Rc=$rc")
        if($rc -ne 14){throw 'Length guard failed'}
    }
    $rc=[int]$invoke.DynamicInvoke([object[]]@($handle,[uint32]0x03030100,$argsPtr))
    $lines.Add("UnknownMethodRc=$rc")
    if($rc -ne 20){throw 'Method guard failed'}
    $rc=[int]$invoke.DynamicInvoke($call)
    if($rc -ne 0 -or (& $hash $output) -ne $expectedHash){throw 'Post-guard valid call failed'}
    $lines.Add('PostGuardExactReference=True')
    $passed=$true
}
catch {$lines.Add('Error='+$_.Exception.Message); $lines.Add('At='+$_.InvocationInfo.ScriptLineNumber)}
finally {
    if($opened){
        try {$rc=[int]$close.DynamicInvoke([object[]]@($handle)); $lines.Add("CloseRc=$rc"); if($rc -ne 0){$passed=$false}}
        catch {$passed=$false; $lines.Add('CloseError='+$_.Exception.Message)}
    }
    foreach($item in $allocations){$M::Copy([byte[]]::new([int]$item[1]),0,[IntPtr]$item[0],[int]$item[1]); $M::FreeHGlobal([IntPtr]$item[0])}
    foreach($pinHandle in $pins){if($pinHandle.IsAllocated){$pinHandle.Free()}}
    foreach($buffer in @($weights,$input,$output,$bytes)){if($null -ne $buffer){[Array]::Clear($buffer,0,$buffer.Length)}}
    if($null -ne $document){$document.Dispose()}
    if($native -ne [IntPtr]::Zero){[Runtime.InteropServices.NativeLibrary]::Free($native)}
}
$lines.Add("Passed=$passed"); & $save
[void][Android.Util.Log]::Info('KokoroConvTile',($lines -join ' | '))
