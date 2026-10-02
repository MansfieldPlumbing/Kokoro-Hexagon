# Device-only stock-weight differential for ALBERT embedding_hidden_mapping_in.
# This is a diagnostic direct-emission gate, not product dispatch.
$root=[IO.Path]::Combine($Activity.FilesDir.AbsolutePath,'kokoro-fl')
$dir=[IO.Path]::Combine($root,'albert-projection-emitted')
$receipt=[IO.Path]::Combine($dir,'receipt.txt')
$lines=[Collections.Generic.List[string]]::new(); $lines.Add('Job=kokoro-albert-projection-emitted')
$save={ [IO.File]::WriteAllLines($receipt,$lines) }
$hash={param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))}
$M=[Runtime.InteropServices.Marshal]; $native=[IntPtr]::Zero; $opened=$false
$pins=[Collections.Generic.List[object]]::new(); $allocations=[Collections.Generic.List[object]]::new()
$passed=$false
try {
    $modulePath=[IO.Path]::Combine($root,'Native.Binding.psm1')
    if((& $hash ([IO.File]::ReadAllBytes($modulePath))) -ne '7A42BF2FE487C303116E315CA594736B2D3FDA24FE2741618736427AB062E89F'){throw 'Delegate factory pin mismatch'}
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Delegate factory parse failed'}
    $abi=$ast.GetScriptBlock().InvokeReturnAsIs()
    $so=[IO.Path]::Combine($root,'qnn','libkokoro_linear_skel.so')
    $soHash=& $hash ([IO.File]::ReadAllBytes($so))
    $manifestRoles=$null
    if($soHash -eq 'B9B0A1F5B08829DD9959DA856AD7111AB77577D3D132580805445931BB8048CB'){
        $expectedManifest='85FA0928B442CF31E355A280399D78FA2425785BC5DE1623D651BA6EB1B1AF2D';$expectedLayout='input_output_bias';$implementation='hvx-embedding-projection';$expectedInputChannels=128;$expectedOutputChannels=768
    }elseif($soHash -eq '08121EC5923CDC66307FAB5DA9775BCF18035A1DD6933336A9F8273107A82F08'){
        $expectedManifest='CC9364E94295578AAE1B486BB5F386CA21B71209E9684971C02527B2D7C68F0F';$expectedLayout='output_input_bias';$implementation='scalar-embedding-projection';$expectedInputChannels=128;$expectedOutputChannels=768
    }elseif($soHash -eq '96C74EB467644D731059B5087ADA5826263C1654C79C8E31162681261E1835B0'){
        $manifestRoles=@{
            'B319307E6C3C2BD82C82FCE615B1EF730272327E647BE9C5C40173293775A4B9'='hvx-attention-query'
            '963944345EE278CC0DEA091CF86F48292D7E01956BF950D9CFBBE513E010F4FB'='hvx-attention-key'
            'F92A75AA14C45BF44C09C5A5C193301615771044B32E216611C82EE895FF2B2F'='hvx-attention-value'
        };$expectedLayout='input_output_bias';$expectedInputChannels=768;$expectedOutputChannels=768
    }elseif($soHash -eq 'B883B334F79B7EFDF6F1EDC704EF1D9CE1472C3CF0B239AA7EE9F83A90796AFB'){
        $expectedManifest='88E7D447221EF872E4AE01C6DC557F235F196BDF214EB4D695A92EB208475A9D';$expectedLayout='output_input_bias';$implementation='scalar-attention-query';$expectedInputChannels=768;$expectedOutputChannels=768
    }elseif($soHash -eq '75533B7D72E460489B4689A39CB0646914108FECB2939C2A45F5537829F655BD'){
        $expectedManifest='CC1AD2352E3AF552462F18C0E44688D084787BD67B8458ED7C83B135EEB09FAB';$expectedLayout='input_output_bias';$implementation='hvx-attention-fused-qkv';$expectedInputChannels=768;$expectedOutputChannels=2304
    }else{throw 'Emitted library pin mismatch'}
    $lines.Add('LibraryAndBindingVerified=True'); & $save
    $manifestBytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($dir,'fixture.json'))
    $manifestHash=& $hash $manifestBytes
    if($null -ne $manifestRoles){
        if(-not $manifestRoles.ContainsKey($manifestHash)){throw 'Fixture manifest pin mismatch'}
        $implementation=$manifestRoles[$manifestHash]
    }elseif($manifestHash -ne $expectedManifest){throw 'Fixture manifest pin mismatch'}
    $document=[Text.Json.JsonDocument]::Parse([Text.Encoding]::UTF8.GetString($manifestBytes))
    $fixture=$document.RootElement
    $rows=$fixture.GetProperty('Rows').GetInt32()
    $inputChannels=$fixture.GetProperty('InputChannels').GetInt32()
    $outputChannels=$fixture.GetProperty('OutputChannels').GetInt32()
    if($rows -ne 3 -or $inputChannels -ne $expectedInputChannels -or
       $outputChannels -ne $expectedOutputChannels -or
       $fixture.GetProperty('WeightLayout').GetString() -ne $expectedLayout){throw 'Fixture geometry or layout differs'}
    $lines.Add('ManifestVerified=True'); & $save
    $load={param([string]$Property)
        $record=$fixture.GetProperty($Property)
        $bytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($dir,$record.GetProperty('Name').GetString()))
        if($bytes.Length -ne $record.GetProperty('Bytes').GetInt32() -or
           (& $hash $bytes) -ne $record.GetProperty('SHA256').GetString()){throw 'Fixture payload integrity differs'}
        $bytes
    }
    [byte[]]$inputBytes=& $load 'Input'; [byte[]]$weights=& $load 'WeightsAndBias'
    [byte[]]$expectedBytes=& $load 'Expected'; [byte[]]$output=[byte[]]::new($expectedBytes.Length)
    [float[]]$expected=[float[]]::new($expectedBytes.Length/4); [float[]]$actual=[float[]]::new($expected.Length)
    [Buffer]::BlockCopy($expectedBytes,0,$expected,0,$expectedBytes.Length)
    $search=[IO.Path]::Combine($root,'qnn')+';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    foreach($name in 'ADSP_LIBRARY_PATH','DSP_LIBRARY_PATH'){
        [Environment]::SetEnvironmentVariable($name,$search); [Android.Systems.Os]::Setenv($name,$search,$true)
    }
    $native=[Runtime.InteropServices.NativeLibrary]::Load('libcdsprpc.so')
    $lines.Add('FastRpcLibraryLoaded=True'); & $save
    $fn={param($Name,$ReturnType,$Parameters)
        $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native,$Name),
            (& $abi.NewDelegateType ('AlbertProjection_'+$Name) $ReturnType $Parameters))
    }
    $control=& $fn 'remote_session_control' ([int]) ([Type[]]@([uint32],[IntPtr],[uint32]))
    $open=& $fn 'remote_handle64_open' ([int]) ([Type[]]@([IntPtr],([uint64]).MakeByRefType()))
    $invoke=& $fn 'remote_handle64_invoke' ([int]) ([Type[]]@([uint64],[uint32],[IntPtr]))
    $close=& $fn 'remote_handle64_close' ([int]) ([Type[]]@([uint64]))
    $lines.Add('FastRpcDelegatesBound=True'); & $save
    $allocate={param([int]$Size)
        $ptr=$M::AllocHGlobal($Size); $allocations.Add(@($ptr,$Size)); $M::Copy([byte[]]::new($Size),0,$ptr,$Size); $ptr
    }
    $pin={param([byte[]]$Bytes)
        $g=[Runtime.InteropServices.GCHandle]::Alloc($Bytes,[Runtime.InteropServices.GCHandleType]::Pinned)
        $pins.Add($g); $g.AddrOfPinnedObject()
    }
    $config=& $allocate 8; $M::WriteInt32($config,0,3); $M::WriteInt32($config,4,1)
    $lines.Add('SessionControlStarted=True'); & $save
    $rc=[int]$control.DynamicInvoke([object[]]@([uint32]2,$config,[uint32]8))
    $lines.Add("UnsignedPdRc=$rc"); if($rc -ne 0){throw 'Unsigned PD configuration failed'}
    $uri=[Text.Encoding]::UTF8.GetBytes('file:///libkokoro_linear_skel.so?kokoro_linear_skel_handle_invoke&_modver=1.0&_dom=cdsp'+[char]0)
    $uriPtr=& $pin $uri; $oa=[object[]]@($uriPtr,[uint64]0)
    $lines.Add('RemoteOpenStarted=True'); & $save
    $rc=[int]$open.DynamicInvoke($oa); $lines.Add("OpenRc=$rc")
    if($rc -ne 0){throw 'Emitted linear library open failed'}
    $handle=[uint64]$oa[1]; $opened=$true
    $lines.Add('LibraryOpened=True'); & $save
    $geometry=& $allocate 12; $M::WriteInt32($geometry,0,$rows); $M::WriteInt32($geometry,4,$inputChannels); $M::WriteInt32($geometry,8,$outputChannels)
    $inputPtr=& $pin $inputBytes; $weightPtr=& $pin $weights; $outputPtr=& $pin $output
    $argsPtr=& $allocate 64
    $M::WriteIntPtr($argsPtr,0,$geometry); $M::WriteInt64($argsPtr,8,12)
    $M::WriteIntPtr($argsPtr,16,$inputPtr); $M::WriteInt64($argsPtr,24,$inputBytes.Length)
    $M::WriteIntPtr($argsPtr,32,$weightPtr); $M::WriteInt64($argsPtr,40,$weights.Length)
    $M::WriteIntPtr($argsPtr,48,$outputPtr); $M::WriteInt64($argsPtr,56,$output.Length)
    $call=[object[]]@($handle,[uint32]0x02030100,$argsPtr)
    $times=[double[]]::new(13)
    [double]$maxError=0
    $lines.Add('InvokeStarted=True'); & $save
    for($iteration=0;$iteration -lt $times.Length;$iteration++){
        $sw=[Diagnostics.Stopwatch]::StartNew(); $rc=[int]$invoke.DynamicInvoke($call); $sw.Stop()
        if($rc -ne 0){throw 'Linear invocation failed'}
        $times[$iteration]=$sw.Elapsed.TotalMilliseconds
        if($iteration -eq 0){
            [Buffer]::BlockCopy($output,0,$actual,0,$output.Length)
            for($i=0;$i -lt $actual.Length;$i++){
                if(-not [float]::IsFinite($actual[$i])){throw 'Non-finite DSP output'}
                $maxError=[Math]::Max($maxError,[Math]::Abs([double]$actual[$i]-[double]$expected[$i]))
            }
            if($maxError -gt 0.0001){throw 'DSP output exceeds the stock projection tolerance'}
        }
    }
    [double[]]$warm=$times[1..12]; [Array]::Sort($warm); $median=($warm[5]+$warm[6])/2
    $lines.Add(('Implementation={0} Shape={1}x{2}x{3} Values={4} MaxError={5:R}' -f $implementation,$rows,$inputChannels,$outputChannels,$actual.Length,$maxError))
    $lines.Add(('WarmMedianMs={0:F3} WarmMinMs={1:F3} WarmMaxMs={2:F3}' -f $median,$warm[0],$warm[11]))
    foreach($offset in 0,4,8){
        $prior=$M::ReadInt32($geometry,$offset); $M::WriteInt32($geometry,$offset,$prior-1)
        $rc=[int]$invoke.DynamicInvoke($call); $M::WriteInt32($geometry,$offset,$prior)
        if($rc -ne 14){throw 'Geometry guard failed'}
    }
    if((& $hash $inputBytes) -ne $fixture.GetProperty('Input').GetProperty('SHA256').GetString() -or
       (& $hash $weights) -ne $fixture.GetProperty('WeightsAndBias').GetProperty('SHA256').GetString()){
        throw 'DSP invocation mutated immutable input'}
    $passed=$true
}
catch {$lines.Add('Error='+$_.Exception.Message); $lines.Add('At='+$_.InvocationInfo.ScriptLineNumber)}
finally {
    if($opened){try{$rc=[int]$close.DynamicInvoke([object[]]@($handle));$lines.Add("CloseRc=$rc");if($rc -ne 0){$passed=$false}}catch{$passed=$false}}
    foreach($item in $allocations){$M::Copy([byte[]]::new([int]$item[1]),0,[IntPtr]$item[0],[int]$item[1]);$M::FreeHGlobal([IntPtr]$item[0])}
    foreach($pinHandle in $pins){if($pinHandle.IsAllocated){$pinHandle.Free()}}
    foreach($buffer in @($inputBytes,$weights,$expectedBytes,$output)){if($null -ne $buffer){[Array]::Clear($buffer,0,$buffer.Length)}}
    if($null -ne $document){$document.Dispose()}
    if($native -ne [IntPtr]::Zero){[Runtime.InteropServices.NativeLibrary]::Free($native)}
}
$lines.Add("Passed=$passed"); & $save
[void][Android.Util.Log]::Info('KokoroAlbertProjection',($lines -join ' | '))
