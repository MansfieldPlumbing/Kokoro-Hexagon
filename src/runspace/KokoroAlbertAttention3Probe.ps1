# Device-only differential; vendor libcdsprpc is diagnostic transport, not product admission.
# Host remote_arg ABI: 16-byte pointer/uint64-length entries.
# Interface wayfinder: quic/fastrpc d247519650fe5cb16de6c78edaa95bcc4be25073 inc/remote.h.
param([ValidateSet('Attention','Output','Connected')][string]$Stage='Attention',[string]$DiagnosticDirectory,
    [ValidatePattern('^[A-F0-9]{64}$')][string]$HostVerifiedManifestSHA256)
$ErrorActionPreference='Stop'
if (-not $DiagnosticDirectory) { $DiagnosticDirectory=[IO.Path]::Combine($Activity.FilesDir.AbsolutePath,'kokoro-fl','albert-attention3-emitted') }
$dir=$DiagnosticDirectory; $receipt=[IO.Path]::Combine($dir,'receipt.txt')
$lines=[Collections.Generic.List[string]]::new(); $lines.Add('Job=kokoro-albert-'+$Stage.ToLowerInvariant()+'3-emitted')
$save={ [IO.File]::WriteAllLines($receipt,$lines) }
& $save
$hash={ param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }
$M=[Runtime.InteropServices.Marshal]; $native=[IntPtr]::Zero; $libc=[IntPtr]::Zero
$opened=$false; $passed=$false; $pins=[Collections.Generic.List[object]]::new(); $allocations=[Collections.Generic.List[object]]::new()
$environmentBackup=@{}; $phase='Artifacts'
try {
    if ([IntPtr]::Size -ne 8) { throw 'Requires arm64 host' }
    $modulePath=[IO.Path]::Combine($dir,'Native.Binding.psm1')
    if (-not [IO.File]::Exists($modulePath) -and $Stage -eq 'Attention') { $modulePath=[IO.Path]::Combine([IO.Path]::GetDirectoryName($dir),'Native.Binding.psm1') }
    # Diagnostic-only host admission: the runner pins source, ELF and fixture,
    # verifies SHA-256 after each copy into private storage, and only then
    # launches this unique session. This is not a product model-store verifier.
    if (-not $HostVerifiedManifestSHA256 -and (& $hash ([IO.File]::ReadAllBytes($modulePath))) -cne '7A42BF2FE487C303116E315CA594736B2D3FDA24FE2741618736427AB062E89F') { throw 'Delegate factory pin mismatch' }
    $tokens=$null; $errors=$null; $ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Delegate factory parse failed' }; $abi=$ast.GetScriptBlock().InvokeReturnAsIs()
    $connectedStage=$Stage -eq 'Connected'; $outputStage=$Stage -in @('Output','Connected')
    $libraryName=if ($connectedStage) { 'libkokoro_albert_connected_attention3_skel.so' } elseif ($outputStage) { 'libkokoro_albert_attention_output3_skel.so' } else { 'libkokoro_albert_attention3_skel.so' }
    $libraryHash=if ($connectedStage) { '0502E64043BFEB7CD979F7626D30908B438BAA5A26F12EBFE7A2BA298781CF11' } elseif ($outputStage) { 'C7F1164999CB8BC8929EBFCB6FF2DFB046DB8272C7FE8220C2EE91AF3E441B6C' } else { '36E9FF41F6F622B27B8725DDB7E1ADA687C6D315F7C8034606BC38DF3904CF9F' }
    $so=[IO.Path]::Combine($dir,$libraryName)
    if (-not [IO.File]::Exists($so) -and -not $outputStage) { $so=[IO.Path]::Combine([IO.Path]::GetDirectoryName($dir),'qnn',$libraryName) }
    if (-not $HostVerifiedManifestSHA256 -and (& $hash ([IO.File]::ReadAllBytes($so))) -cne $libraryHash) { throw 'Emitted library pin mismatch' }
    $manifestBytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($dir,'fixture.json'))
    $manifestHash=if ($HostVerifiedManifestSHA256) { $HostVerifiedManifestSHA256 } else { & $hash $manifestBytes }
    $allowed=if ($connectedStage) { @('35C4AB66C4C8CB32194D117F2A56006B7D6E35F8B1AD3AA8A749AA9577643D7F') } elseif ($outputStage) { @('B199DD7515407557BA9ABE302BE25A217D66BE32DCE975A7A71B68A5BA759146','D35B4CC581E9A995C268FDBFBC99EB186ED93CE69A2A0AE5D834649A47D5A5EA') } else { @('08E767B7482C755CA70C59F53A9F69040DFE626AE290206FE3C4566978DEA76E') }
    if ($manifestHash -cnotin $allowed) { throw 'Fixture manifest pin mismatch' }
    $document=[Text.Json.JsonDocument]::Parse([Text.Encoding]::UTF8.GetString($manifestBytes)); $fixture=$document.RootElement
    $role=if ($connectedStage) { 'stock_albert_connected_attention3_differential_fixture' } elseif ($outputStage) { 'stock_albert_attention_output3_differential_fixture' } else { 'stock_albert_attention3_differential_fixture' }
    if ($fixture.GetProperty('Role').GetString() -cne $role -or $fixture.GetProperty('Tokens').GetInt32() -ne 3) { throw 'Fixture contract differs' }
    if ($outputStage) {
        $inputLayout=if ($connectedStage) { 'qkv_then_original_hidden' } else { 'context_then_hidden' }
        $outputLayout=if ($connectedStage) { 'context_hidden_projected_normalized' } else { 'projected_then_normalized' }
        if ($fixture.GetProperty('HiddenSize').GetInt32() -ne 768 -or $fixture.GetProperty('InputLayout').GetString() -cne $inputLayout -or
            $fixture.GetProperty('WeightLayout').GetString() -cne 'output_input_bias_ln_gain_ln_bias' -or $fixture.GetProperty('OutputLayout').GetString() -cne $outputLayout -or
            $fixture.GetProperty('MaximumAbsoluteError').GetDouble() -ne 1e-4 -or $fixture.GetProperty('MinimumSNRdB').GetDouble() -ne 80) { throw 'Output shape/layout/limits differ' }
    } elseif ($fixture.GetProperty('Heads').GetInt32() -ne 12 -or $fixture.GetProperty('HeadWidth').GetInt32() -ne 64) { throw 'Attention shape differs' }
    $load={
        param([string]$Property,[int]$Length)
        $record=$fixture.GetProperty($Property); $name=$record.GetProperty('Name').GetString()
        if ($name -cnotmatch '^[a-z0-9-]+\.f32$') { throw 'Payload path rejected' }
        $bytes=[IO.File]::ReadAllBytes([IO.Path]::Combine($dir,$name))
        if ($bytes.Length -ne $Length -or $record.GetProperty('Bytes').GetInt32() -ne $Length -or
            (-not $HostVerifiedManifestSHA256 -and (& $hash $bytes) -cne $record.GetProperty('SHA256').GetString())) { throw 'Payload integrity differs' }
        return ,$bytes
    }
    $inputLength=if ($connectedStage) {36864} elseif ($outputStage) { 18432 } else { 27648 }; $outputLength=if ($connectedStage) {36864} elseif ($outputStage) { 18432 } else { 9216 }
    [byte[]]$inputBytes=& $load 'Input' $inputLength; [byte[]]$expectedBytes=& $load 'Expected' $outputLength; [byte[]]$output=[byte[]]::new($outputLength)
    # Output-only RPC storage is private staging, not a published tensor. The
    # ABI does not promise its incoming bytes survive a rejected invocation.
    # Only an observed successful synchronous completion can publish staging.
    [byte[]]$transportOutput=[byte[]]::new($outputLength)
    $publish={ param([int]$Status)
        if ($Status -eq 0) { [Buffer]::BlockCopy($transportOutput,0,$output,0,$outputLength); return $true }
        return $false
    }
    [float[]]$expected=[float[]]::new($outputLength/4); [float[]]$actual=[float[]]::new($outputLength/4); [Buffer]::BlockCopy($expectedBytes,0,$expected,0,$outputLength)
    if ($outputStage) { [byte[]]$weightsBytes=& $load 'Weights' 2368512 }
    [byte[]]$inputSnapshot=$inputBytes.Clone()
    if ($outputStage) { [byte[]]$weightsSnapshot=$weightsBytes.Clone() }
    $lines.Add('IntegrityScope='+$(if ($HostVerifiedManifestSHA256) {'WindowsStagedSHA256'} else {'DeviceSHA256'}))
    $lines.Add('ArtifactsVerified=True'); $lines.Add('LibrarySHA256='+$libraryHash); $lines.Add('FixtureSHA256='+$manifestHash); & $save
    $allocate={ param([int]$Size) $ptr=$M::AllocHGlobal($Size); $allocations.Add(@($ptr,$Size)); $M::Copy([byte[]]::new($Size),0,$ptr,$Size); $ptr }
    $pin={ param([byte[]]$Bytes) $g=[Runtime.InteropServices.GCHandle]::Alloc($Bytes,[Runtime.InteropServices.GCHandleType]::Pinned); $pins.Add($g); $g.AddrOfPinnedObject() }
    $phase='SearchPath'
    # C ABI declarations: AOSP bionic 09a271af557444c9a6b3f3146d6d474156fd6cdb,
    # libc/include/stdlib.h:56-57. This is an ABI wayfinder, not firmware identity.
    # POSIX bindings avoid a Mono.Android/Java.Interop dependency in the new diagnostic.
    $libc=[Runtime.InteropServices.NativeLibrary]::Load('libc.so')
    $setenv=$M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($libc,'setenv'),(& $abi.NewDelegateType 'AlbertProbe_setenv' ([int]) ([Type[]]@([IntPtr],[IntPtr],[int]))))
    $unsetenv=$M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($libc,'unsetenv'),(& $abi.NewDelegateType 'AlbertProbe_unsetenv' ([int]) ([Type[]]@([IntPtr]))))
    $search=[IO.Path]::GetDirectoryName($so)+';/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/dsp'
    $searchPtr=& $pin ([Text.Encoding]::UTF8.GetBytes($search+[char]0))
    foreach ($name in @('ADSP_LIBRARY_PATH','DSP_LIBRARY_PATH')) {
        $namePtr=& $pin ([Text.Encoding]::UTF8.GetBytes($name+[char]0)); $environmentBackup[$name]=@($namePtr,[Environment]::GetEnvironmentVariable($name))
        if ([int]$setenv.DynamicInvoke([object[]]@($namePtr,$searchPtr,1)) -ne 0) { throw 'Search path setup failed' }
        [Environment]::SetEnvironmentVariable($name,$search)
    }
    $phase='VendorTransport'
    # The vendor path was inventoried on the authorized arm64 target. This is
    # an explicit diagnostic client, not a packaged/product transport.
    $native=[Runtime.InteropServices.NativeLibrary]::Load('/vendor/lib64/libcdsprpc.so')
    $fn={ param($Name,$ReturnType,$Parameters) $M::GetDelegateForFunctionPointer([Runtime.InteropServices.NativeLibrary]::GetExport($native,$Name),(& $abi.NewDelegateType ('AlbertProbe_'+$Name) $ReturnType $Parameters)) }
    $control=& $fn 'remote_session_control' ([int]) ([Type[]]@([uint32],[IntPtr],[uint32])); $open=& $fn 'remote_handle64_open' ([int]) ([Type[]]@([IntPtr],([uint64]).MakeByRefType()))
    $invoke=& $fn 'remote_handle64_invoke' ([int]) ([Type[]]@([uint64],[uint32],[IntPtr])); $close=& $fn 'remote_handle64_close' ([int]) ([Type[]]@([uint64]))
    $phase='UnsignedPD'
    $config=& $allocate 8; $M::WriteInt32($config,0,3); $M::WriteInt32($config,4,1)
    $rc=[int]$control.DynamicInvoke([object[]]@([uint32]2,$config,[uint32]8)); $lines.Add("ControlRc=$rc"); & $save
    if ($rc -ne 0) { throw 'Unsigned PD configuration failed' }
    $symbol=if ($connectedStage) { 'kokoro_albert_connected_attention3_skel_handle_invoke' } elseif ($outputStage) { 'kokoro_albert_attention_output3_skel_handle_invoke' } else { 'kokoro_albert_attention3_skel_handle_invoke' }
    $uri='file:///'+$libraryName+'?'+$symbol+'&_modver=1.0&_dom=cdsp'; $uriPtr=& $pin ([Text.Encoding]::UTF8.GetBytes($uri+[char]0))
    $phase='LibraryOpen'; $oa=[object[]]@($uriPtr,[uint64]0); $rc=[int]$open.DynamicInvoke($oa); $lines.Add("OpenRc=$rc"); & $save
    if ($rc -ne 0) { throw 'Emitted library open failed' }; $handle=[uint64]$oa[1]; $opened=$true; $lines.Add('LibraryOpened=True'); & $save
    $inputPtr=& $pin $inputBytes; $outputPtr=& $pin $transportOutput
    if ($outputStage) {
        [byte[]]$geometry=[byte[]]::new(12); [Buffer]::BlockCopy([int[]]@(3,768,768),0,$geometry,0,12)
        $geometryPtr=& $pin $geometry; $weightsPtr=& $pin $weightsBytes; $argsPtr=& $allocate 64
        $buffers=@(@($geometryPtr,12),@($inputPtr,$inputLength),@($weightsPtr,2368512),@($outputPtr,$outputLength)); $scalar=[uint32]0x02030100
    } else { $argsPtr=& $allocate 32; $buffers=@(@($inputPtr,27648),@($outputPtr,9216)); $scalar=[uint32]0x02010100 }
    for ($b=0; $b -lt $buffers.Count; $b++) { $M::WriteIntPtr($argsPtr,16*$b,$buffers[$b][0]); $M::WriteInt64($argsPtr,16*$b+8,$buffers[$b][1]) }
    $call=[object[]]@($handle,$scalar,$argsPtr); $times=[double[]]::new(13); $phase='Numerics'
    for ($iteration=0; $iteration -lt 13; $iteration++) {
        $sw=[Diagnostics.Stopwatch]::StartNew(); $rc=[int]$invoke.DynamicInvoke($call); $sw.Stop()
        if (-not (& $publish $rc)) { $lines.Add("InvokeRc=$rc"); throw 'DSP invocation failed' }; $times[$iteration]=$sw.Elapsed.TotalMilliseconds
        if ($iteration -eq 0) {
            [Buffer]::BlockCopy($output,0,$actual,0,$outputLength)
            $segments=if ($connectedStage) { @('Context','HiddenCopy','Projection','ResidualLayerNorm') } elseif ($outputStage) { @('Projection','ResidualLayerNorm') } else { @('Context') }; $numericsPassed=$true
            for ($segment=0; $segment -lt $segments.Count; $segment++) {
                [double]$maxError=0; [double]$signal=0; [double]$noise=0
                for ($i=$segment*2304; $i -lt ($segment+1)*2304; $i++) {
                    if (-not [float]::IsFinite($actual[$i])) { throw 'Non-finite output' }
                    $delta=[double]$actual[$i]-$expected[$i]; $maxError=[Math]::Max($maxError,[Math]::Abs($delta)); $signal+=[double]$expected[$i]*$expected[$i]; $noise+=$delta*$delta
                }
                $snr=if ($noise -eq 0) { [double]::PositiveInfinity } elseif ($signal -eq 0) { [double]::NegativeInfinity } else { 10*[Math]::Log10($signal/$noise) }
                $limit=if ($segments[$segment] -eq 'HiddenCopy') {0} elseif ($segments[$segment] -eq 'Context') {2e-5} else {1e-4}; $ok=$maxError -le $limit -and (-not $outputStage -or $snr -ge 80)
                $lines.Add(('{0}: Values=2304 MaxError={1:R} SNRdB={2:R} Passed={3}' -f $segments[$segment],$maxError,$snr,$ok)); if (-not $ok) { $numericsPassed=$false }
            }
            & $save; if (-not $numericsPassed) { throw 'Numerical boundary exceeds declared limits' }
        }
    }
    [double[]]$warm=$times[1..12]; [Array]::Sort($warm)
    $lines.Add(('ColdMs={0:F3} WarmMedianMs={1:F3} WarmMinMs={2:F3} WarmMaxMs={3:F3} Samples=12' -f $times[0],(($warm[5]+$warm[6])/2),$warm[0],$warm[11]))
    $phase='Guards'; [byte[]]$validOutputSnapshot=$output.Clone(); $rawPreserved=$true
    $lines.Add('GateScope=NumericsAndSuccessOnlyPublication'); & $save
    for ($b=0; $b -lt $buffers.Count; $b++) {
        [byte[]]$transportSnapshot=$transportOutput.Clone()
        $M::WriteInt64($argsPtr,16*$b+8,$buffers[$b][1]-1)
        try { $rc=[int]$invoke.DynamicInvoke($call) } finally { $M::WriteInt64($argsPtr,16*$b+8,$buffers[$b][1]) }
        $published=& $publish $rc
        $unchanged=[Linq.Enumerable]::SequenceEqual[byte]($output,$validOutputSnapshot)
        $rawUnchanged=[Linq.Enumerable]::SequenceEqual[byte]($transportOutput,$transportSnapshot)
        $rawPreserved=$rawPreserved -and $rawUnchanged
        $lines.Add(('LengthGuard: Buffer={0} Rc={1} Published={2} PublishedOutputUnchanged={3} RawOutputUnchanged={4}' -f $b,$rc,$published,$unchanged,$rawUnchanged)); & $save
        [Array]::Clear($transportSnapshot,0,$transportSnapshot.Length)
        if ($rc -ne 14 -or $published -or -not $unchanged) { throw 'Length guard/publication preservation failed' }
    }
    $domainPointers=if ($outputStage) { @($inputPtr,$weightsPtr) } else { @($inputPtr) }
    foreach ($ptr in $domainPointers) {
        $saved=$M::ReadInt32($ptr); $M::WriteInt32($ptr,0,0x7f800000)
        try { $rc=[int]$invoke.DynamicInvoke($call) } finally { $M::WriteInt32($ptr,0,$saved) }
        $published=& $publish $rc
        $lines.Add(('DomainGuard: Rc={0} Published={1} PublishedOutputUnchanged={2}' -f $rc,$published,[Linq.Enumerable]::SequenceEqual[byte]($output,$validOutputSnapshot))); & $save
        if ($rc -ne 33 -or $published -or -not [Linq.Enumerable]::SequenceEqual[byte]($output,$validOutputSnapshot)) { throw 'Domain guard/publication preservation failed' }
    }
    if ($outputStage) {
        $M::WriteInt32($geometryPtr,0,4)
        try { $rc=[int]$invoke.DynamicInvoke($call) } finally { $M::WriteInt32($geometryPtr,0,3) }
        $published=& $publish $rc
        $lines.Add(('GeometryGuard: Rc={0} Published={1} PublishedOutputUnchanged={2}' -f $rc,$published,[Linq.Enumerable]::SequenceEqual[byte]($output,$validOutputSnapshot))); & $save
        if ($rc -ne 14 -or $published -or -not [Linq.Enumerable]::SequenceEqual[byte]($output,$validOutputSnapshot)) { throw 'Geometry guard/publication preservation failed' }
        # Finite admitted inputs can fail after projection has written staging.
        # Select an existing positive residual, force its projection to 1024
        # using one zero weight row and a bounded bias, then reject the sum.
        $hiddenOffset=if ($connectedStage) {27648} else {9216}; $channel=-1
        for ($i=0; $i -lt 2304; $i++) { if ([BitConverter]::ToSingle($inputBytes,$hiddenOffset+4*$i) -gt 0) { $channel=$i%768; break } }
        if ($channel -lt 0) { throw 'Late-domain fixture has no positive residual.' }
        $rowOffset=$channel*3072; $biasOffset=2359296+4*$channel
        [byte[]]$savedRow=[byte[]]::new(3072); [Buffer]::BlockCopy($weightsBytes,$rowOffset,$savedRow,0,3072)
        $savedBias=[BitConverter]::ToInt32($weightsBytes,$biasOffset)
        try {
            [Array]::Clear($weightsBytes,$rowOffset,3072)
            [Buffer]::BlockCopy([BitConverter]::GetBytes([float]1024),0,$weightsBytes,$biasOffset,4)
            $rc=[int]$invoke.DynamicInvoke($call)
        } finally {
            [Buffer]::BlockCopy($savedRow,0,$weightsBytes,$rowOffset,3072)
            [Buffer]::BlockCopy([BitConverter]::GetBytes($savedBias),0,$weightsBytes,$biasOffset,4)
            [Array]::Clear($savedRow)
        }
        $published=& $publish $rc
        $lines.Add(('LateDomainGuard: Rc={0} Published={1} PublishedOutputUnchanged={2}' -f $rc,$published,[Linq.Enumerable]::SequenceEqual[byte]($output,$validOutputSnapshot))); & $save
        if ($rc -ne 33 -or $published -or -not [Linq.Enumerable]::SequenceEqual[byte]($output,$validOutputSnapshot)) { throw 'Late-domain publication preservation failed' }
        if (-not [Linq.Enumerable]::SequenceEqual[byte]($weightsBytes,$weightsSnapshot)) { throw 'Weights restoration failed' }
    }
    if (-not [Linq.Enumerable]::SequenceEqual[byte]($inputBytes,$inputSnapshot)) { throw 'Input restoration failed' }
    # Rejected staging must not contaminate the next successful completion.
    $rc=[int]$invoke.DynamicInvoke($call)
    if (-not (& $publish $rc) -or -not [Linq.Enumerable]::SequenceEqual[byte]($output,$validOutputSnapshot)) { throw 'Recovery invocation differs' }
    $lines.Add('RecoveryVerified=True'); $lines.Add('RawLengthGuardOutputPreserved='+$rawPreserved)
    $lines.Add('GuardsVerified=True'); $passed=$true
} catch {
    # Fixed-field errors: runtime exception messages may contain private paths.
    $lines.Add('ErrorPhase='+$phase); $lines.Add('ErrorCategory='+$_.Exception.GetType().Name); $lines.Add('At='+$_.InvocationInfo.ScriptLineNumber)
    if ($phase -eq 'VendorTransport') {
        $detail=$_.Exception.ToString()
        $lines.Add('LinkerNamespaceDenied='+[bool]($detail -match 'not accessible for the namespace'))
        $lines.Add('NativeDependencyNotFound='+[bool]($detail -match 'not found'))
        # Read-only app-context node admission, independent of driver ioctl
        # lineage. Opening a descriptor is not a CDSP session or worker load.
        # No capability ioctl, domain creation, policy change or fallback RPC.
        if ($libc -ne [IntPtr]::Zero) {
            try {
                $rawOpen=& $abi.BindExport $libc 'open' ([int]) ([Type[]]@([IntPtr],[int],[int])) $true
                $rawClose=& $abi.BindExport $libc 'close' ([int]) ([Type[]]@([int])) $true
                foreach ($node in @('/dev/adsprpc-smd','/dev/adsprpc-smd-secure','/dev/cdsprpc-smd','/dev/fastrpc-cdsp')) {
                    $nodePtr=$M::StringToHGlobalAnsi($node); $rawFd=-1
                    try {
                        $rawFd=[int]$rawOpen.DynamicInvoke([object[]]@($nodePtr,0,0))
                        $rawError=$M::GetLastPInvokeError()
                        $lines.Add(('NodeOpen: Path={0} Opened={1} Errno={2}' -f $node,($rawFd -ge 0),$(if ($rawFd -ge 0) {0} else {$rawError})))
                    } finally {
                        if ($rawFd -ge 0) { $closeRc=[int]$rawClose.DynamicInvoke([object[]]@($rawFd)); $lines.Add('NodeDescriptorClosed='+($closeRc -eq 0)) }
                        $M::FreeHGlobal($nodePtr)
                    }
                }
            } catch { $lines.Add('NodeOpenDiagnosticError='+$_.Exception.GetType().Name) }
        }
    }
} finally {
    if ($opened) { try { $rc=[int]$close.DynamicInvoke([object[]]@($handle)); $lines.Add("CloseRc=$rc"); if ($rc -ne 0) { $passed=$false } } catch { $passed=$false } }
    foreach ($name in $environmentBackup.Keys) {
        try {
            $entry=$environmentBackup[$name]
            if ($null -eq $entry[1]) { $rc=[int]$unsetenv.DynamicInvoke([object[]]@($entry[0])) } else {
                $valuePtr=& $pin ([Text.Encoding]::UTF8.GetBytes($entry[1]+[char]0)); $rc=[int]$setenv.DynamicInvoke([object[]]@($entry[0],$valuePtr,1))
            }
            [Environment]::SetEnvironmentVariable($name,$entry[1]); if ($rc -ne 0) { $passed=$false }
        } catch { $passed=$false }
    }
    foreach ($item in $allocations) { $M::Copy([byte[]]::new([int]$item[1]),0,[IntPtr]$item[0],[int]$item[1]); $M::FreeHGlobal([IntPtr]$item[0]) }
    foreach ($pinHandle in $pins) { if ($pinHandle.IsAllocated) { $pinHandle.Free() } }
    foreach ($buffer in @($inputBytes,$weightsBytes,$geometry,$expectedBytes,$output,$transportOutput,$transportSnapshot,$expected,$actual,$inputSnapshot,$weightsSnapshot,$validOutputSnapshot)) { if ($null -ne $buffer) { [Array]::Clear($buffer,0,$buffer.Length) } }
    if ($null -ne $document) { $document.Dispose() }
    if ($native -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($native) }
    if ($libc -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($libc) }
}
$lines.Add("Passed=$passed"); & $save
