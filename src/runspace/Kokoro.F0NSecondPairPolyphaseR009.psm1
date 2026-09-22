param(
    [Parameter(Mandatory)][object]$Abi,
    [Parameter(Mandatory)][object]$Native,
    [Parameter(Mandatory)][object]$Graph
)

$specimen = [pscustomobject]@{
    PSTypeName = 'AndroidSMA.Kokoro.R009Polyphase.SpecimenContract'
    FileName = 'R009_F0N_PAIR_POLYPHASE_F65_TO_F130_SPECIMEN.bin'
    Bytes = 6340620
    Sha256 = '33D25E8C154915A481B97CA687CA01CE4C28CBA1EC579135E9A8C9BB11D716C4'
    Values = [ordered]@{
        F0InputF65       = @(0,133120)
        N0InputF65       = @(133120,133120)
        F0Norm1Scale     = @(266240,2048)
        N0Norm1Scale     = @(268288,2048)
        F0Norm1Bias      = @(270336,2048)
        N0Norm1Bias      = @(272384,2048)
        F0Norm2Scale     = @(274432,1024)
        N0Norm2Scale     = @(275456,1024)
        F0Norm2Bias      = @(276480,1024)
        N0Norm2Bias      = @(277504,1024)
        Epsilon          = @(278528,4)
        ResidualDivisor  = @(278532,4)
        PreluAlpha       = @(278536,4)
        F0ShortcutWeight = @(278540,524288)
        F0PoolPolyphaseWeight = @(802828,8192)
        F0PoolPolyphaseBias   = @(811020,4096)
        F0Conv1Weight    = @(815116,1572864)
        F0Conv1Bias      = @(2387980,1024)
        F0Conv2Weight    = @(2389004,786432)
        F0Conv2Bias      = @(3175436,1024)
        N0ShortcutWeight = @(3176460,524288)
        N0PoolPolyphaseWeight = @(3700748,8192)
        N0PoolPolyphaseBias   = @(3708940,4096)
        N0Conv1Weight    = @(3713036,1572864)
        N0Conv1Bias      = @(5285900,1024)
        N0Conv2Weight    = @(5286924,786432)
        N0Conv2Bias      = @(6073356,1024)
        F0OutputOracle   = @(6074380,133120)
        N0OutputOracle   = @(6207500,133120)
    }
}

$invoke = {
    param([object]$Android,[string]$ArtifactDirectory)

    [bool]$hostPreflight = $false
    if ($null -ne $Android.PSObject.Properties['HostPreflight']) {
        $hostPreflight = [bool]$Android.HostPreflight
    }
    if (-not $hostPreflight) { [void](& $Native.Initialize $Android) }

    [int]$pidBefore = [Environment]::ProcessId
    [string]$bundlePath = [IO.Path]::Combine($ArtifactDirectory,[string]$specimen.FileName)
    [byte[]]$bundle = [IO.File]::ReadAllBytes($bundlePath)
    if ($bundle.Length -ne [int]$specimen.Bytes) { throw 'R009 specimen byte contract' }
    [string]$bundleSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bundle))
    if ($bundleSha -ne [string]$specimen.Sha256) { throw 'R009 specimen SHA contract' }

    [object]$specimenValues = $specimen.Values
    [int]$float32Type = [int]$Abi.Enum['Float32']
    [int]$uint32Type = [int]$Abi.Enum['UInt32']
    [int]$appWriteType = [int]$Abi.Enum['AppWrite']
    [int]$appReadType = [int]$Abi.Enum['AppRead']
    [int]$nativeType = [int]$Abi.Enum['Native']
    [int]$staticType = [int]$Abi.Enum['Static']
    [int]$tensorIdOffset = [int]$Abi.Layout.Tensor['Id']
    [int]$paramNameOffset = [int]$Abi.Layout.Param['Name']
    [Type]$opConfigType = $Graph.OpConfigType
    [scriptblock]$graphNewArena = $Graph.NewArena
    [scriptblock]$graphFreeArena = $Graph.FreeArena
    [scriptblock]$graphNewTensor = $Graph.NewTensor
    [scriptblock]$graphRegisterTensor = $Graph.RegisterTensor
    [scriptblock]$graphNewTensorParam = $Graph.NewTensorParam
    [scriptblock]$graphNewScalarBoolParam = $Graph.NewScalarBoolParam
    [scriptblock]$graphNewScalarUInt32Param = $Graph.NewScalarUInt32Param
    [scriptblock]$graphNewOp = $Graph.NewOp
    [scriptblock]$graphAddNode = $Graph.AddNode
    [scriptblock]$graphFinalize = $Graph.Finalize
    [scriptblock]$graphSerializeContext = $Graph.SerializeContext
    [scriptblock]$graphNewExecTensor = $Graph.NewExecTensor
    [scriptblock]$graphExecute = $Graph.Execute

    $slice = {
        param([string]$Name)
        $range = $specimenValues[$Name]
        [byte[]]$value = [byte[]]::new([int]$range[1])
        [Buffer]::BlockCopy($bundle,[int]$range[0],$value,0,[int]$range[1])
        return ,$value
    }.GetNewClosure()
    $u32 = {
        param([uint32[]]$Values)
        [byte[]]$bytes = [byte[]]::new($Values.Count * 4)
        [Buffer]::BlockCopy($Values,0,$bytes,0,$bytes.Length)
        return ,$bytes
    }.GetNewClosure()

    $trial = $null
    $arena = $null
    $receipt = $null
    [uint64]$closeRc = [uint64]::MaxValue
    [string]$stage = 'open'
    try {
        if (-not $hostPreflight) { $trial = & $Native.NewTrial 'KOKORO_F0N_PAIR_R009_F65_TO_F130' }
        $arena = & $graphNewArena
        $tensors = [Collections.Generic.Dictionary[string,object]]::new()
        $operations = [Collections.Generic.List[object]]::new()
        $addCodes = [Collections.Generic.List[uint64]]::new()
        [int]$syntheticId = 1

        $newTensor = {
            param([string]$Name,[int[]]$Shape,[int]$Type,[byte[]]$Data)
            $tensor = & $graphNewTensor $arena $Name $Type $float32Type $Shape $Data
            if ($hostPreflight) {
                [Runtime.InteropServices.Marshal]::WriteInt32($tensor.Ptr,$tensorIdOffset,$syntheticId)
                $tensor.Id = $syntheticId
                $tensor.Registered = $true
                $syntheticId++
            } else {
                $registered = & $graphRegisterTensor $trial $tensor
                if ($registered.Rc -ne 0 -or $registered.Id -eq 0) { throw "tensor $Name rc=$($registered.Rc)" }
            }
            $tensors[$Name] = $tensor
            $tensor
        }.GetNewClosure()
        $newUInt32Tensor = {
            param([string]$Name,[uint32[]]$Values,[int[]]$Shape)
            $tensor = & $graphNewTensor $arena $Name $staticType $uint32Type $Shape (& $u32 $Values)
            if ($hostPreflight) {
                [Runtime.InteropServices.Marshal]::WriteInt32($tensor.Ptr,$tensorIdOffset,$syntheticId)
                $tensor.Id = $syntheticId
                $tensor.Registered = $true
                $syntheticId++
            } else {
                $registered = & $graphRegisterTensor $trial $tensor
                if ($registered.Rc -ne 0 -or $registered.Id -eq 0) { throw "tensor $Name rc=$($registered.Rc)" }
            }
            $tensors[$Name] = $tensor
            $tensor
        }.GetNewClosure()
        $addOperation = {
            param([string]$Name,[string]$Type,[string[]]$Inputs,[string]$Output,[int[]]$OutputShape,[IntPtr[]]$Parameters,[bool]$IsEndpoint)
            [int]$outputType = if ($IsEndpoint) { $appReadType } else { $nativeType }
            $outputTensor = & $newTensor $Output $OutputShape $outputType $null
            [object[]]$inputTensors = @(foreach ($inputName in $Inputs) {
                if (-not $tensors.ContainsKey($inputName)) { throw "missing input Value: $Name <- $inputName" }
                $tensors[$inputName]
            })
            $op = & $graphNewOp $arena $Name $Type $inputTensors ([object[]]@($outputTensor)) $Parameters
            [void]$operations.Add($op)
            [uint64]$rc = 0
            if (-not $hostPreflight) {
                $rc = & $graphAddNode $trial $op
                if ($rc -ne 0) { throw "graphAddNode $Name rc=$rc" }
            }
            [void]$addCodes.Add($rc)
            $outputTensor
        }.GetNewClosure()
        $tensorParameter = {
            param([string]$Name,[object]$Tensor)
            & $graphNewTensorParam $arena $Name $Tensor
        }.GetNewClosure()
        $transpose = {
            param([string]$Name,[string]$Source,[string]$Output,[int[]]$Shape)
            $perm = & $newUInt32Tensor ($Name + '.perm') ([uint32[]]@(0,2,1)) ([int[]]@(3))
            $parameter = & $tensorParameter 'perm' $perm
            & $addOperation $Name 'Transpose' @($Source) $Output $Shape ([IntPtr[]]@($parameter)) $false
        }.GetNewClosure()
        $reshape = {
            param([string]$Name,[string]$Source,[string]$Output,[int[]]$Shape)
            & $addOperation $Name 'Reshape' @($Source) $Output $Shape ([IntPtr[]]@()) $false
        }.GetNewClosure()
        $reduceMean = {
            param([string]$Name,[string]$Source,[string]$Output,[int[]]$Shape,[uint32]$Axis)
            $axes = & $newUInt32Tensor ($Name + '.axes') ([uint32[]]@($Axis)) ([int[]]@(1))
            $p0 = & $tensorParameter 'axes' $axes
            $p1 = & $graphNewScalarBoolParam $arena 'keep_dims' $true
            & $addOperation $Name 'ReduceMean' @($Source) $Output $Shape ([IntPtr[]]@($p0,$p1)) $false
        }.GetNewClosure()
        $elementWise = {
            param([string]$Name,[string]$Type,[string[]]$Inputs,[string]$Output,[int[]]$Shape,[bool]$Endpoint)
            & $addOperation $Name $Type $Inputs $Output $Shape ([IntPtr[]]@()) $Endpoint
        }.GetNewClosure()
        $prelu = {
            param([string]$Name,[string]$Source,[string]$Output,[int[]]$Shape)
            & $addOperation $Name 'Prelu' @($Source,'PreluAlpha') $Output $Shape ([IntPtr[]]@()) $false
        }.GetNewClosure()
        $concat = {
            param([string]$Name,[string[]]$Inputs,[string]$Output,[int[]]$Shape,[uint32]$Axis)
            $axisParameter = & $graphNewScalarUInt32Param $arena 'axis' $Axis
            & $addOperation $Name 'Concat' $Inputs $Output $Shape ([IntPtr[]]@($axisParameter)) $false
        }.GetNewClosure()
        $conv = {
            param([string]$Name,[string]$Source,[string]$Weight,[string]$Bias,[string]$Output,[int[]]$OutputShape,[uint32[]]$Padding)
            $dilation = & $newUInt32Tensor ($Name + '.dilation') ([uint32[]]@(1,1)) ([int[]]@(2))
            $stride = & $newUInt32Tensor ($Name + '.stride') ([uint32[]]@(1,1)) ([int[]]@(2))
            $paddingTensor = & $newUInt32Tensor ($Name + '.pad_amount') $Padding ([int[]]@(2,2))
            $p0 = & $graphNewScalarUInt32Param $arena 'group' 1
            $p1 = & $tensorParameter 'dilation' $dilation
            $p2 = & $tensorParameter 'stride' $stride
            $p3 = & $tensorParameter 'pad_amount' $paddingTensor
            [string[]]$inputs = if ([string]::IsNullOrEmpty($Bias)) { @($Source,$Weight) } else { @($Source,$Weight,$Bias) }
            & $addOperation $Name 'Conv2d' $inputs $Output $OutputShape ([IntPtr[]]@($p0,$p1,$p2,$p3)) $false
        }.GetNewClosure()
        $polyphaseConv = {
            param([string]$Name,[string]$Source,[string]$Weight,[string]$Bias,[string]$Output)
            $dilation = & $newUInt32Tensor ($Name + '.dilation') ([uint32[]]@(1,1)) ([int[]]@(2))
            $stride = & $newUInt32Tensor ($Name + '.stride') ([uint32[]]@(1,1)) ([int[]]@(2))
            $boundary = & $newUInt32Tensor ($Name + '.pad_amount') ([uint32[]]@(0,0,0,1)) ([int[]]@(2,2))
            $p0 = & $graphNewScalarUInt32Param $arena 'group' 512
            $p1 = & $tensorParameter 'dilation' $dilation
            $p2 = & $tensorParameter 'stride' $stride
            $p3 = & $tensorParameter 'pad_amount' $boundary
            & $addOperation $Name 'Conv2d' @($Source,$Weight,$Bias) $Output ([int[]]@(1,1,65,1024)) ([IntPtr[]]@($p0,$p1,$p2,$p3)) $false
        }.GetNewClosure()

        $inputShapes = [ordered]@{
            F0InputF65=@(1,512,65); N0InputF65=@(1,512,65)
            F0Norm1Scale=@(1,512,1); N0Norm1Scale=@(1,512,1)
            F0Norm1Bias=@(1,512,1); N0Norm1Bias=@(1,512,1)
            F0Norm2Scale=@(1,256,1); N0Norm2Scale=@(1,256,1)
            F0Norm2Bias=@(1,256,1); N0Norm2Bias=@(1,256,1)
        }
        [string[]]$inputNames = [string[]]$inputShapes.Keys
        foreach ($entry in $inputShapes.GetEnumerator()) { [void](& $newTensor $entry.Key ([int[]]$entry.Value) $appWriteType $null) }

        $staticShapes = [ordered]@{
            Epsilon=@(1); ResidualDivisor=@(1); PreluAlpha=@(1)
            F0ShortcutWeight=@(1,1,512,256); F0PoolPolyphaseWeight=@(1,2,1,1024); F0PoolPolyphaseBias=@(1024)
            F0Conv1Weight=@(1,3,512,256); F0Conv1Bias=@(256); F0Conv2Weight=@(1,3,256,256); F0Conv2Bias=@(256)
            N0ShortcutWeight=@(1,1,512,256); N0PoolPolyphaseWeight=@(1,2,1,1024); N0PoolPolyphaseBias=@(1024)
            N0Conv1Weight=@(1,3,512,256); N0Conv1Bias=@(256); N0Conv2Weight=@(1,3,256,256); N0Conv2Bias=@(256)
        }
        foreach ($entry in $staticShapes.GetEnumerator()) { [void](& $newTensor $entry.Key ([int[]]$entry.Value) $staticType (& $slice $entry.Key)) }

        foreach ($branch in @('F0','N0')) {
            [string]$source = $branch + 'InputF65'
            [void](& $transpose "$branch.shortcut.transpose" $source "$branch.ShortcutFMajor65" @(1,65,512))
            [void](& $reshape "$branch.shortcut.lift" "$branch.ShortcutFMajor65" "$branch.ShortcutLifted" @(1,65,1,512))
            [void](& $concat "$branch.shortcut.duplicate" @("$branch.ShortcutLifted","$branch.ShortcutLifted") "$branch.ShortcutDuplicated" @(1,65,2,512) 2)
            [void](& $reshape "$branch.shortcut.expand" "$branch.ShortcutDuplicated" "$branch.ShortcutFourD" @(1,1,130,512))
            [void](& $conv "$branch.shortcut.conv" "$branch.ShortcutFourD" ($branch+'ShortcutWeight') '' "$branch.ShortcutProjectedFourD" @(1,1,130,256) ([uint32[]]@(0,0,0,0)))
            [void](& $reshape "$branch.shortcut.squeeze" "$branch.ShortcutProjectedFourD" "$branch.ShortcutProjected" @(1,130,256))

            [void](& $reduceMean "$branch.norm1.mean" $source "$branch.Norm1Mean" @(1,512,1) 2)
            [void](& $elementWise "$branch.norm1.center" 'ElementWiseSubtract' @($source,"$branch.Norm1Mean") "$branch.Centered1" @(1,512,65) $false)
            [void](& $elementWise "$branch.norm1.square" 'ElementWiseMultiply' @("$branch.Centered1","$branch.Centered1") "$branch.Squared1" @(1,512,65) $false)
            [void](& $reduceMean "$branch.norm1.variance" "$branch.Squared1" "$branch.Variance1" @(1,512,1) 2)
            [void](& $elementWise "$branch.norm1.epsilon" 'ElementWiseAdd' @("$branch.Variance1",'Epsilon') "$branch.VarianceEps1" @(1,512,1) $false)
            [void](& $elementWise "$branch.norm1.sqrt" 'ElementWiseSquareRoot' @("$branch.VarianceEps1") "$branch.Std1" @(1,512,1) $false)
            [void](& $elementWise "$branch.norm1.divide" 'ElementWiseDivide' @("$branch.Centered1","$branch.Std1") "$branch.Normalized1" @(1,512,65) $false)
            [void](& $elementWise "$branch.norm1.scale" 'ElementWiseMultiply' @(($branch+'Norm1Scale'),"$branch.Normalized1") "$branch.Norm1Scaled" @(1,512,65) $false)
            [void](& $elementWise "$branch.norm1.bias" 'ElementWiseAdd' @("$branch.Norm1Scaled",($branch+'Norm1Bias')) "$branch.Norm1Styled" @(1,512,65) $false)
            [void](& $prelu "$branch.act1" "$branch.Norm1Styled" "$branch.Act1" @(1,512,65))

            [void](& $transpose "$branch.learned.transpose" "$branch.Act1" "$branch.LearnedFMajor65" @(1,65,512))
            [void](& $reshape "$branch.pool.expand" "$branch.LearnedFMajor65" "$branch.PoolInput" @(1,1,65,512))
            [void](& $polyphaseConv "$branch.pool.polyphase" "$branch.PoolInput" ($branch+'PoolPolyphaseWeight') ($branch+'PoolPolyphaseBias') "$branch.PolyphaseFourD")
            [void](& $reshape "$branch.pool.phase.reshape" "$branch.PolyphaseFourD" "$branch.PolyphaseGrouped" @(1,65,512,2))
            $phasePerm = & $newUInt32Tensor ($branch + '.pool.phase.perm') ([uint32[]]@(0,1,3,2)) ([int[]]@(4))
            $phaseParameter = & $tensorParameter 'perm' $phasePerm
            [void](& $addOperation "$branch.pool.phase.transpose" 'Transpose' @("$branch.PolyphaseGrouped") "$branch.PolyphaseInterleavable" @(1,65,2,512) ([IntPtr[]]@($phaseParameter)) $false)
            [void](& $reshape "$branch.conv1.expand" "$branch.PolyphaseInterleavable" "$branch.Conv1Input" @(1,1,130,512))
            [void](& $conv "$branch.conv1" "$branch.Conv1Input" ($branch+'Conv1Weight') ($branch+'Conv1Bias') "$branch.Conv1FourD" @(1,1,130,256) ([uint32[]]@(0,0,1,1)))
            [void](& $reshape "$branch.conv1.squeeze" "$branch.Conv1FourD" "$branch.Conv1" @(1,130,256))

            [void](& $reduceMean "$branch.norm2.mean" "$branch.Conv1" "$branch.Norm2Mean" @(1,1,256) 1)
            [void](& $elementWise "$branch.norm2.center" 'ElementWiseSubtract' @("$branch.Conv1","$branch.Norm2Mean") "$branch.Centered2" @(1,130,256) $false)
            [void](& $elementWise "$branch.norm2.square" 'ElementWiseMultiply' @("$branch.Centered2","$branch.Centered2") "$branch.Squared2" @(1,130,256) $false)
            [void](& $reduceMean "$branch.norm2.variance" "$branch.Squared2" "$branch.Variance2" @(1,1,256) 1)
            [void](& $elementWise "$branch.norm2.epsilon" 'ElementWiseAdd' @("$branch.Variance2",'Epsilon') "$branch.VarianceEps2" @(1,1,256) $false)
            [void](& $elementWise "$branch.norm2.sqrt" 'ElementWiseSquareRoot' @("$branch.VarianceEps2") "$branch.Std2" @(1,1,256) $false)
            [void](& $elementWise "$branch.norm2.divide" 'ElementWiseDivide' @("$branch.Centered2","$branch.Std2") "$branch.Normalized2" @(1,130,256) $false)
            [void](& $transpose "$branch.norm2.scale.transpose" ($branch+'Norm2Scale') "$branch.Norm2ScaleFMajor" @(1,1,256))
            [void](& $transpose "$branch.norm2.bias.transpose" ($branch+'Norm2Bias') "$branch.Norm2BiasFMajor" @(1,1,256))
            [void](& $elementWise "$branch.norm2.scale" 'ElementWiseMultiply' @("$branch.Norm2ScaleFMajor","$branch.Normalized2") "$branch.Norm2Scaled" @(1,130,256) $false)
            [void](& $elementWise "$branch.norm2.bias" 'ElementWiseAdd' @("$branch.Norm2Scaled","$branch.Norm2BiasFMajor") "$branch.Norm2Styled" @(1,130,256) $false)
            [void](& $prelu "$branch.act2" "$branch.Norm2Styled" "$branch.Act2" @(1,130,256))
            [void](& $reshape "$branch.conv2.expand" "$branch.Act2" "$branch.Conv2Input" @(1,1,130,256))
            [void](& $conv "$branch.conv2" "$branch.Conv2Input" ($branch+'Conv2Weight') ($branch+'Conv2Bias') "$branch.Conv2FourD" @(1,1,130,256) ([uint32[]]@(0,0,1,1)))
            [void](& $reshape "$branch.conv2.squeeze" "$branch.Conv2FourD" "$branch.Conv2" @(1,130,256))
            [void](& $elementWise "$branch.residual" 'ElementWiseAdd' @("$branch.Conv2","$branch.ShortcutProjected") "$branch.Residual" @(1,130,256) $false)
            [void](& $elementWise "$branch.divide" 'ElementWiseDivide' @("$branch.Residual",'ResidualDivisor') "$branch.Divided" @(1,130,256) $false)
            $perm = & $newUInt32Tensor ($branch + '.output.perm') ([uint32[]]@(0,2,1)) ([int[]]@(3))
            $parameter = & $tensorParameter 'perm' $perm
            [void](& $addOperation "$branch.output.transpose" 'Transpose' @("$branch.Divided") "$branch.Output" @(1,256,130) ([IntPtr[]]@($parameter)) $true)
        }

        if ($operations.Count -ne 84) { throw "R009 polyphase operation census expected=84 actual=$($operations.Count)" }
        $expectedFamilies = [ordered]@{
            Conv2d=8; ElementWiseAdd=10; ElementWiseDivide=6; ElementWiseMultiply=8
            ElementWiseSquareRoot=4; ElementWiseSubtract=4; Prelu=4; ReduceMean=8
            Reshape=18; Concat=2; Transpose=12
        }
        $actualFamilies = [ordered]@{}
        foreach ($operation in $operations) {
            [string]$family = $operation.Type
            if ($actualFamilies.Contains($family)) { $actualFamilies[$family] = [int]$actualFamilies[$family] + 1 }
            else { $actualFamilies[$family] = 1 }
        }
        foreach ($expectedFamilyEntry in $expectedFamilies.GetEnumerator()) {
            if (-not $actualFamilies.Contains($expectedFamilyEntry.Key)) {
                throw "R009 family missing=$($expectedFamilyEntry.Key) actual=$($actualFamilies.Keys -join ',')"
            }
            if ([int]$actualFamilies[$expectedFamilyEntry.Key] -ne [int]$expectedFamilyEntry.Value) {
                $census = @(); foreach ($kv in $actualFamilies.GetEnumerator()) { $census += ($kv.Key + '=' + $kv.Value) }
                throw "R009 family $($expectedFamilyEntry.Key) expected=$($expectedFamilyEntry.Value) census[$($census -join ' ')]"
            }
        }
        foreach ($operation in $operations) {
            $value = $operation.Value
            foreach ($field in @('Name','PackageName','TypeName','Inputs','Outputs')) {
                [IntPtr]$pointer = [IntPtr]($opConfigType.GetField($field).GetValue($value))
                if ($pointer -eq [IntPtr]::Zero) { throw "R009 descriptor $($operation.Name).$field=NULL" }
            }
            foreach ($parameter in $operation.Parameters) {
                [IntPtr]$namePointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($parameter,$paramNameOffset)
                if ($namePointer -eq [IntPtr]::Zero) { throw "R009 descriptor $($operation.Name).Param.Name=NULL" }
                if (-not $arena.Pointers.Contains($namePointer)) { throw "R009 descriptor $($operation.Name).Param.Name=UNOWNED" }
            }
        }

        if ($hostPreflight) {
            $closeRc = 0
            $receipt = [pscustomobject]@{
                PSTypeName='AndroidSMA.Kokoro.R009Polyphase.HostReceipt'; Proof='KOKORO-QNN-R009-F0N-SECOND-PAIR-POLYPHASE'
                Passed=$true; Stage='host-materialized'; InputDomain='F65'; OutputDomain='F130'
                OperationCount=$operations.Count; OperatorFamilies=$actualFamilies; TensorCount=$tensors.Count
                TargetExecuted=$false; PidBefore=$pidBefore; PidAfter=[Environment]::ProcessId; CloseRc=0
            }
            return $receipt
        }

        $stage = 'finalize'
        [uint64]$finalizeRc = & $graphFinalize $trial
        if ($finalizeRc -ne 0) { throw "graphFinalize rc=$finalizeRc" }
        [byte[]]$contextBytes = & $graphSerializeContext $trial $arena
        [string]$contextSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($contextBytes))
        $stage = 'execute'
        $execInputs = [Collections.Generic.List[object]]::new()
        foreach ($name in $inputNames) { [void]$execInputs.Add((& $graphNewExecTensor $arena $tensors[$name] (& $slice $name))) }
        [byte[]]$f0Bytes = [byte[]]::new(133120)
        [byte[]]$n0Bytes = [byte[]]::new(133120)
        $f0Exec = & $graphNewExecTensor $arena $tensors['F0.Output'] $f0Bytes
        $n0Exec = & $graphNewExecTensor $arena $tensors['N0.Output'] $n0Bytes
        [uint64]$executeRc = & $graphExecute $trial $arena $execInputs.ToArray() ([object[]]@($f0Exec,$n0Exec))
        if ($executeRc -ne 0) { throw "graphExecute rc=$executeRc" }
        [Runtime.InteropServices.Marshal]::Copy($f0Exec.DataPtr,$f0Bytes,0,$f0Bytes.Length)
        [Runtime.InteropServices.Marshal]::Copy($n0Exec.DataPtr,$n0Bytes,0,$n0Bytes.Length)
        [float[]]$actual = [float[]]::new(66560)
        [float[]]$oracle = [float[]]::new(66560)
        [Buffer]::BlockCopy($f0Bytes,0,$actual,0,133120)
        [Buffer]::BlockCopy($n0Bytes,0,$actual,133120,133120)
        [Buffer]::BlockCopy((& $slice 'F0OutputOracle'),0,$oracle,0,133120)
        [Buffer]::BlockCopy((& $slice 'N0OutputOracle'),0,$oracle,133120,133120)
        [double]$maxAbs = 0; [double]$sumSq = 0; [bool]$finite = $true
        [int]$maxIndex = -1; [int]$over = 0; [int]$overEven = 0; [int]$overLast = 0; [int]$overFirst = 0
        for ([int]$index=0; $index -lt $actual.Length; $index++) {
            [double]$difference = [Math]::Abs([double]$actual[$index] - [double]$oracle[$index])
            if (-not [double]::IsFinite($difference)) { $finite = $false }
            if ($difference -gt $maxAbs) { $maxAbs = $difference; $maxIndex = $index }
            $sumSq += $difference * $difference
            if ($difference -gt 0.02) {
                $over++
                [int]$t = ($index % 33280) % 130
                if (($t % 2) -eq 0) { $overEven++ }
                if ($t -eq 129) { $overLast++ }
                if ($t -eq 0) { $overFirst++ }
            }
        }
        [double]$oracleMax = 0; [double]$relMax = 0
        for ([int]$index=0; $index -lt $oracle.Length; $index++) {
            [double]$o = [Math]::Abs([double]$oracle[$index])
            if ($o -gt $oracleMax) { $oracleMax = $o }
            if ($o -gt 1.0) {
                [double]$rel = [Math]::Abs([double]$actual[$index] - [double]$oracle[$index]) / $o
                if ($rel -gt $relMax) { $relMax = $rel }
            }
        }
        [int]$mBranch = [Math]::Floor($maxIndex / 33280); [int]$mRest = $maxIndex % 33280
        [string]$diag = "over=$over overEvenT=$overEven overT0=$overFirst overT129=$overLast maxBranch=$mBranch maxChannel=$([Math]::Floor($mRest / 130)) maxT=$($mRest % 130) oracleMax=$([Math]::Round($oracleMax,4)) relMaxAbove1=$([Math]::Round($relMax,6))"
        [double]$rmse = [Math]::Sqrt($sumSq / $actual.Length)
        [double]$tolerance = 0.02
        [bool]$passed = $finite -and $maxAbs -le $tolerance
        $receipt = [pscustomobject]@{
            PSTypeName='AndroidSMA.Kokoro.R009Polyphase.Receipt'; Proof='KOKORO-QNN-R009-F0N-SECOND-PAIR-POLYPHASE'
            Parent='KOKORO-QNN-R008-F0N-FIRST-PAIR'; ParentContextSha256='58508E1A8E98142F58E09F6AFF13078E6246660115C58567B1B626072EAA6355'
            Passed=$passed; Stage=if($passed){'validated'}else{'oracle'}; Error=if($passed){$null}else{'oracle envelope'}
            InputDomain='F65'; OutputDomain='F130'; OperationCount=$operations.Count; ValidateRc=0
            AddCodes=$addCodes.ToArray(); FinalizeRc=$finalizeRc; ExecuteRc=$executeRc
            MaxAbs=$maxAbs; Rmse=$rmse; Tolerance=$tolerance; ContextBytes=$contextBytes.Length
            ContextSha256=$contextSha; ContextPath=$null; PidBefore=$pidBefore; PidAfter=[Environment]::ProcessId
            Diag=$diag; CloseRc=[uint64]::MaxValue
        }
    } catch {
        $receipt = [pscustomobject]@{
            PSTypeName='AndroidSMA.Kokoro.R009Polyphase.Receipt'; Proof='KOKORO-QNN-R009-F0N-SECOND-PAIR-POLYPHASE'
            Passed=$false; Stage=$stage; Error=$_.Exception.Message; ErrorStack=$_.ScriptStackTrace
            PidBefore=$pidBefore; PidAfter=[Environment]::ProcessId; CloseRc=[uint64]::MaxValue
        }
    } finally {
        [string]$cleanupError = $null
        try {
            if ($null -ne $trial) { try { $closeRc = [uint64](& $Native.CloseTrial $trial) } catch { $cleanupError = $_.Exception.Message } }
        } finally {
            if ($null -ne $arena) { try { & $graphFreeArena $arena } catch { $cleanupError += $_.Exception.Message } }
            if ($null -ne $receipt) {
                $receipt.CloseRc = $closeRc
                if (-not [string]::IsNullOrEmpty($cleanupError)) { $receipt.Passed=$false; $receipt.Stage='cleanup'; $receipt.Error=$cleanupError }
            }
        }
    }
    if ($hostPreflight) { return $receipt }
    if ($receipt.Passed -and $closeRc -eq 0) {
        $path = [IO.Path]::Combine([string]$Android.DataRoot,'KOKORO_F0N_PAIR_POLYPHASE_R009_F65_TO_F130.QNN')
        $candidate = $path + '.candidate'
        try {
            [IO.File]::WriteAllBytes($candidate,$contextBytes)
            [IO.File]::Move($candidate,$path,$true)
            $receipt.ContextPath=$path; $receipt.Stage='complete'
        } catch {
            $receipt.Passed=$false; $receipt.Stage='promote'; $receipt.Error=$_.Exception.Message
            if ([IO.File]::Exists($candidate)) { [IO.File]::Delete($candidate) }
        }
    } elseif ($receipt.Passed) { $receipt.Passed=$false; $receipt.Stage='cleanup'; $receipt.Error="close=$closeRc" }
    $receipt
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName='AndroidSMA.Kokoro.F0NSecondPairPolyphaseR009Capability'
    Name='Kokoro.F0NSecondPairPolyphaseR009'
    Specimen=$specimen
    Invoke=$invoke
}
