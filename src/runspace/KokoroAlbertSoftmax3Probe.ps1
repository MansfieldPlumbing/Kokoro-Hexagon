# Device-only stock-QKV differential for the emitted three-key ALBERT softmax.
# This is a diagnostic direct-emission gate, not product dispatch.
$root=[IO.Path]::Combine($Activity.FilesDir.AbsolutePath,'kokoro-fl')
$dir=[IO.Path]::Combine($root,'albert-softmax3-emitted')
$receipt=[IO.Path]::Combine($dir,'receipt.txt')
$lines=[Collections.Generic.List[string]]::new();$lines.Add('Job=kokoro-albert-softmax3-emitted')
$save={[IO.File]::WriteAllLines($receipt,$lines)}
$hash={param([byte[]]$Bytes)[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))}
$M=[Runtime.InteropServices.Marshal];$native=[IntPtr]::Zero;$opened=$false;$passed=$false
$pins=[Collections.Generic.List[object]]::new();$allocations=[Collections.Generic.List[object]]::new()
try {
    $modulePath=[IO.Path]::Combine($root,'Native.Binding.psm1')
    if((& $hash ([IO.File]::ReadAllBytes($modulePath))) -ne '7A42BF2FE487C303116E315CA594736B2D3FDA24FE2741618736427AB062E89F'){throw 'Delegate factory pin mismatch'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Delegate factory parse failed'}
    $abi=$ast.GetScriptBlock().InvokeReturnAsIs()
    $so=[IO.Path]::Combine($root,'qnn','libkokoro_albert_softmax3_skel.so')
    if((& $hash ([IO.File]::ReadAllBytes($so))) -ne 'F8C015FEB5F918931766FF04674160CBBDDFD13459D86CAB19D7FFB02E710067'){throw 'Emitted library pin mismatch'}
    $manifestBytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($dir,'fixture.json'))
    if((& $hash $manifestBytes) -ne 'DC9538FEF6AE232301135DDB74F8771FB51156791491CD7B781BB39263B21F57'){throw 'Fixture manifest pin mismatch'}
    $document=[Text.Json.JsonDocument]::Parse([Text.Encoding]::UTF8.GetString($manifestBytes));$fixture=$document.RootElement
    if($fixture.GetProperty('Role').GetString() -ne 'stock_albert_attention_shifted_softmax3_differential_fixture' -or
       $fixture.GetProperty('Cases').GetInt32() -ne 36 -or $fixture.GetProperty('ElementsPerCase').GetInt32() -ne 3){throw 'Fixture contract differs'}
    $load={param([string]$Property)
        $record=$fixture.GetProperty($Property);$bytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($dir,$record.GetProperty('Name').GetString()))
        if($bytes.Length -ne $record.GetProperty('Bytes').GetInt32() -or (& $hash $bytes) -ne $record.GetProperty('SHA256').GetString()){throw 'Fixture payload integrity differs'}
        $bytes
    }
    [byte[]]$inputBytes=& $load 'Input';[byte[]]$expectedBytes=& $load 'Expected';[byte[]]$output=[byte[]]::new(12)
    [float[]]$expected=[float[]]::new(108);[float[]]$actual=[float[]]::new(3)
    [Buffer]::BlockCopy($expectedBytes,0,$expected,0,$expectedBytes.Length)
    $lines.Add('ArtifactsVerified=True');& $save
    $search=[IO.Path]::Combine($root,'qnn')+';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach($name in 'ADSP_LIBRARY_PATH','DSP_LIBRARY_PATH'){[Environment]::SetEnvironmentVariable($name,$search);[Android.Systems.Os]::Setenv($name,$search,$true)}
    $native=[Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $fn={param($Name,$ReturnType,$Parameters)$M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native,$Name),(& $abi.NewDelegateType ('AlbertSoftmax3_'+$Name) $ReturnType $Parameters))}
    $control=& $fn 'remote_session_control' ([int]) ([Type[]]@([uint32],[IntPtr],[uint32]))
    $open=& $fn 'remote_handle64_open' ([int]) ([Type[]]@([IntPtr],([uint64]).MakeByRefType()))
    $invoke=& $fn 'remote_handle64_invoke' ([int]) ([Type[]]@([uint64],[uint32],[IntPtr]))
    $close=& $fn 'remote_handle64_close' ([int]) ([Type[]]@([uint64]))
    $allocate={param([int]$Size)$ptr=$M::AllocHGlobal($Size);$allocations.Add(@($ptr,$Size));$M::Copy([byte[]]::new($Size),0,$ptr,$Size);$ptr}
    $pin={param([byte[]]$Bytes)$g=[Runtime.InteropServices.GCHandle]::Alloc($Bytes,[Runtime.InteropServices.GCHandleType]::Pinned);$pins.Add($g);$g.AddrOfPinnedObject()}
    $config=& $allocate 8;$M::WriteInt32($config,0,3);$M::WriteInt32($config,4,1)
    $rc=[int]$control.DynamicInvoke([object[]]@([uint32]2,$config,[uint32]8));if($rc -ne 0){throw 'Unsigned PD configuration failed'}
    $uri=[Text.Encoding]::UTF8.GetBytes('file:///libkokoro_albert_softmax3_skel.so?kokoro_albert_softmax3_skel_handle_invoke&_modver=1.0&_dom=cdsp'+[char]0)
    $uriPtr=& $pin $uri;$oa=[object[]]@($uriPtr,[uint64]0);$rc=[int]$open.DynamicInvoke($oa)
    if($rc -ne 0){throw 'Emitted softmax library open failed'}
    $handle=[uint64]$oa[1];$opened=$true;$lines.Add('LibraryOpened=True');& $save
    $inputPtr=& $pin $inputBytes;$outputPtr=& $pin $output;$argsPtr=& $allocate 32
    $M::WriteInt64($argsPtr,8,12);$M::WriteIntPtr($argsPtr,16,$outputPtr);$M::WriteInt64($argsPtr,24,12)
    $call=[object[]]@($handle,[uint32]0x02010100,$argsPtr)
    [double]$maxError=0;[double]$maxSumError=0;$times=[double[]]::new(36)
    for($case=0;$case -lt 36;$case++){
        $M::WriteIntPtr($argsPtr,0,[IntPtr]::Add($inputPtr,12*$case))
        $sw=[Diagnostics.Stopwatch]::StartNew();$rc=[int]$invoke.DynamicInvoke($call);$sw.Stop();$times[$case]=$sw.Elapsed.TotalMilliseconds
        if($rc -ne 0){throw 'Softmax invocation failed'}
        [Buffer]::BlockCopy($output,0,$actual,0,12);$sum=0.0
        for($index=0;$index -lt 3;$index++){
            if(-not [float]::IsFinite($actual[$index])){throw 'Non-finite DSP output'}
            $maxError=[Math]::Max($maxError,[Math]::Abs([double]$actual[$index]-[double]$expected[3*$case+$index]));$sum+=$actual[$index]
        }
        $maxSumError=[Math]::Max($maxSumError,[Math]::Abs($sum-1.0))
    }
    if($maxError -gt 0.000002 -or $maxSumError -gt 0.000002){throw 'DSP softmax output exceeds tolerance'}
    [Array]::Sort($times);$median=($times[17]+$times[18])/2
    $lines.Add(('Cases=36 MaxError={0:R} MaxSumError={1:R}' -f $maxError,$maxSumError))
    $lines.Add(('InvokeMedianMs={0:F3} InvokeMinMs={1:F3} InvokeMaxMs={2:F3}' -f $median,$times[0],$times[35]))
    $M::WriteIntPtr($argsPtr,0,$inputPtr)
    $M::WriteInt64($argsPtr,8,11);$rc=[int]$invoke.DynamicInvoke($call);$M::WriteInt64($argsPtr,8,12);if($rc -ne 14){throw 'Length guard failed'}
    $saved=[byte[]]::new(12);[Array]::Copy($inputBytes,0,$saved,0,12)
    $M::WriteInt32($inputPtr,0,0x3f800000);$rc=[int]$invoke.DynamicInvoke($call);if($rc -ne 33){throw 'Positive-score guard failed'}
    foreach($offset in 0,4,8){$M::WriteInt32($inputPtr,$offset,[BitConverter]::SingleToInt32Bits(-1.0))}
    $rc=[int]$invoke.DynamicInvoke($call);if($rc -ne 33){throw 'Missing-maximum guard failed'}
    [Array]::Copy($saved,0,$inputBytes,0,12)
    if((& $hash $inputBytes) -ne $fixture.GetProperty('Input').GetProperty('SHA256').GetString()){throw 'Input restoration failed'}
    $lines.Add('GuardsVerified=True');$passed=$true
}
catch{$lines.Add('Error='+$_.Exception.Message);$lines.Add('At='+$_.InvocationInfo.ScriptLineNumber)}
finally{
    if($opened){try{$rc=[int]$close.DynamicInvoke([object[]]@($handle));$lines.Add("CloseRc=$rc");if($rc -ne 0){$passed=$false}}catch{$passed=$false}}
    foreach($item in $allocations){$M::Copy([byte[]]::new([int]$item[1]),0,[IntPtr]$item[0],[int]$item[1]);$M::FreeHGlobal([IntPtr]$item[0])}
    foreach($pinHandle in $pins){if($pinHandle.IsAllocated){$pinHandle.Free()}}
    foreach($buffer in @($inputBytes,$expectedBytes,$output,$expected,$actual)){if($null -ne $buffer){[Array]::Clear($buffer,0,$buffer.Length)}}
    if($null -ne $document){$document.Dispose()};if($native -ne [IntPtr]::Zero){[Runtime.InteropServices.NativeLibrary]::Free($native)}
}
$lines.Add("Passed=$passed");& $save
[void][Android.Util.Log]::Info('KokoroAlbertSoftmax3',($lines -join ' | '))
