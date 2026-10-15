#requires -Version 7.7
Set-StrictMode -Version Latest

class KokoroGeneratorInputFrame {
    [uint32] $Version = 1
    [uint32] $Sequence
    [uint32] $Flags
    [uint32] $ValidSamples = 300
    [Half[]] $DecoderFeatures
    [Half[]] $Source10x
    [Half[]] $Source60x
    [float[]] $AdaInScale
    [float[]] $AdaInBias
    [float[]] $LockPhase
    [float] $F0Hz
    [uint32] $Voiced

    [void] Validate([bool] $PerSeatPhase) {
        if ($this.Version -ne 1 -or $this.ValidSamples -lt 1 -or $this.ValidSamples -gt 300 -or $this.Voiced -gt 1 -or
            -not [float]::IsFinite($this.F0Hz) -or $this.F0Hz -lt 0 -or
            $null -eq $this.DecoderFeatures -or $this.DecoderFeatures.Length -ne 512 -or
            $null -eq $this.Source10x -or $this.Source10x.Length -ne 2560 -or
            $null -eq $this.Source60x -or $this.Source60x.Length -ne 7680 -or
            $null -eq $this.AdaInScale -or $this.AdaInScale.Length -ne 6912 -or
            $null -eq $this.AdaInBias -or $this.AdaInBias.Length -ne 6912) {
            throw 'Invalid generator input frame.'
        }
        $phaseCount = 6912
        if ($PerSeatPhase) { $phaseCount = 184320 }
        if ($null -eq $this.LockPhase -or $this.LockPhase.Length -ne $phaseCount) {
            throw 'Invalid streamed Lock phase extent.'
        }
        foreach ($values in @($this.AdaInScale, $this.AdaInBias, $this.LockPhase)) {
            foreach ($value in $values) { if (-not [float]::IsFinite($value)) { throw 'Nonfinite generator control.' } }
        }
        foreach ($values in @($this.DecoderFeatures, $this.Source10x, $this.Source60x)) {
            foreach ($value in $values) { if (-not [Half]::IsFinite($value)) { throw 'Nonfinite generator feature.' } }
        }
    }
}

function Get-KokoroGeneratorInputContract {
    [CmdletBinding()]
    param([ValidateSet('ChannelPhase','SeatPhase')][string]$LockEncoding='ChannelPhase',
        [ValidateRange(1,64)][int]$BlockFrames=1,[switch]$FinalBoundary)
    # A block transports whole typed frames. DSP consumption remains one frame
    # at a time regardless of the transport batch size.
    $fields=[Collections.Generic.List[object]]::new()
    $offset=0
    $lockCount=if($LockEncoding -ceq 'ChannelPhase'){6912}else{184320}
    foreach($field in @(
        @('Header','UInt32',4,4), @('DecoderFeatures','Float16',512,2),
        @('Source10x','Float16',2560,2), @('Source60x','Float16',7680,2),
        @('AdaInScale','Float32',6912,4), @('AdaInBias','Float32',6912,4),
        @('LockPhase','Float32',$lockCount,4), @('F0Hz','Float32',1,4),
        @('Voiced','UInt32',1,4), @('Padding','Byte',8,1))) {
        $bytes=[int]$field[2]*[int]$field[3]
        $fields.Add([pscustomobject]@{Name=$field[0];Precision=$field[1];Count=[int]$field[2];Offset=$offset;
            BytesPerFrame=$bytes;BytesPerBlock=$bytes*$BlockFrames;BytesPerAudioSecond=80L*$bytes})
        $offset+=$bytes
    }
    $boundaryFields=[Collections.Generic.List[object]]::new();$boundaryOffset=0
    foreach($field in @(@('Header','UInt32',4,4),@('Source60x','Float16',128,2),
        @('AdaInScale','Float32',2304,4),@('AdaInBias','Float32',2304,4),@('LockPhase','Float32',2304,4))){
        $bytes=[int]$field[2]*[int]$field[3]
        $boundaryFields.Add([pscustomobject]@{Name=$field[0];Precision=$field[1];Count=[int]$field[2];Offset=$boundaryOffset;Bytes=$bytes})
        $boundaryOffset+=$bytes
    }
    [pscustomobject]@{PSTypeName='Kokoro.Generator.InputContract';Version=1;SampleRate=24000;SamplesPerFrame=300;
        FramesPerSecond=80;BlockFrames=$BlockFrames;LockEncoding=$LockEncoding;FrameBytes=$offset;
        BlockBytes=$offset*$BlockFrames+$(if($FinalBoundary){$boundaryOffset}else{0});BytesPerAudioSecond=80L*$offset;Fields=$fields.ToArray();
        BoundaryBytesPerUtterance=$boundaryOffset;BoundaryFields=$boundaryFields.ToArray();
        SiteOrder='resblocks 0..5; dilation 0..2; adain1 then adain2; channel then cycle position';
        HeaderOrder='version, sequence, flags, valid samples';ByteOrder='LittleEndian';
        BoundaryPolicy='Preserve producer row order: group 60 rows per frame, then transport the final extra 60x row once with final-frame controls. No extra audio frame.'}
}

Export-ModuleMember -Function Get-KokoroGeneratorInputContract
