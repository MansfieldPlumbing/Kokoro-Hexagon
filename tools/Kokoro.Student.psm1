#requires -Version 7.7
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Numeric work is lowered from these PowerShell classes. Libraries select real
# occurrences; sums below evaluate total squared differences, never centroids.
class KokoroStudentReplayResult {
    [float[]] $Values
    [uint] $Flags
    KokoroStudentReplayResult() { $this.Flags=[uint]0 }
}

class KokoroStudentCodec {
    static [byte[]] CopyPrograms([int[]] $candidates,[int] $k) {
        if($k -le 0 -or $candidates.Length%$k -ne 0){throw [ArgumentException]::new('COPY candidate extent mismatch.')}
        $count=[int]($candidates.Length/$k);$programs=[byte[]]::new(5*$count)
        for($unit=0;$unit -lt $count;$unit++){
            $id=$candidates[$unit*$k]
            if($id -lt 0 -or $id -ge $count -or $id -eq $unit){throw [ArgumentException]::new('Invalid real other exemplar ID.')}
            $at=$unit*5;$programs[$at]=[byte]1
            for($part=0;$part -lt 4;$part++){$programs[$at+1+$part]=[byte](($id -shr (8*$part)) -band 255)}
        }
        return $programs
    }
    static [KokoroStudentReplayResult] Replay([byte[]] $program,[short[]] $library,[float[]] $key,[float[]] $directions,[float[]] $previous) {
        if($key.Length -ne 512 -or $library.Length%512 -ne 0 -or $directions.Length%512 -ne 0 -or $program.Length -eq 0){throw [ArgumentException]::new('Invalid replay extent.')}
        for($channel=0;$channel -lt 512;$channel++){if(-not [float]::IsFinite($key[$channel]) -or $key[$channel] -le [float]0){throw [ArgumentException]::new('Invalid voice key.')}}
        $result=[KokoroStudentReplayResult]::new();$result.Values=[float[]]::new(512)
        $at=0;$started=$false
        while($at -lt $program.Length){
            $opcode=[int]$program[$at];$at++
            if($opcode -eq 1){
                if($started -or $program.Length-$at -lt 4){throw [ArgumentException]::new('Invalid COPY.')}
                $unit=[BitConverter]::ToInt32($program,$at);$at+=4
                if($unit -eq -1){
                    if($previous.Length -ne 512){throw [ArgumentException]::new('COPY previous requires a predecessor.')}
                    [Array]::Copy($previous,$result.Values,512)
                }else{
                    if($unit -lt 0 -or $unit -ge [int]($library.Length/512)){throw [ArgumentException]::new('COPY unit outside library.')}
                    for($channel=0;$channel -lt 512;$channel++){$result.Values[$channel]=[float]([float]$library[$unit*512+$channel]*$key[$channel])}
                }
                $started=$true
            }elseif($opcode -eq 2){
                if(-not $started -or $program.Length-$at -lt 4){throw [ArgumentException]::new('Invalid DIRECTION.')}
                $pair=[BitConverter]::ToInt32($program,$at);$at+=4
                if($pair -lt 0 -or $pair -ge [int]($directions.Length/512)){throw [ArgumentException]::new('DIRECTION outside library.')}
                for($channel=0;$channel -lt 512;$channel++){$result.Values[$channel]=[float]($result.Values[$channel]+$directions[$pair*512+$channel])}
            }elseif($opcode -eq 3){
                if(-not $started -or $program.Length-$at -lt 3){throw [ArgumentException]::new('Invalid RESIDUAL.')}
                $shift=[int]$program[$at];$count=[int][BitConverter]::ToUInt16($program,$at+1);$at+=3
                if($shift -gt 30 -or $count -gt 512 -or $count*4 -gt $program.Length-$at){throw [ArgumentException]::new('Invalid RESIDUAL extent.')}
                $factor=[float][Math]::Pow(2.0,-$shift)
                for($entry=0;$entry -lt $count;$entry++){
                    $channel=[int][BitConverter]::ToUInt16($program,$at);$correction=[BitConverter]::ToInt16($program,$at+2);$at+=4
                    if($channel -ge 512){throw [ArgumentException]::new('Residual channel outside tile.')}
                    $scale=[float]($key[$channel]*$factor)
                    $result.Values[$channel]=[float]($result.Values[$channel]+[float]([float]$correction*$scale))
                }
            }elseif($opcode -eq 4){
                if(-not $started -or $program.Length-$at -lt 4){throw [ArgumentException]::new('Invalid FLAGS.')}
                $result.Flags=$result.Flags -bor [BitConverter]::ToUInt32($program,$at);$at+=4
            }else{throw [ArgumentException]::new('Unknown student opcode.')}
        }
        if(-not $started){throw [ArgumentException]::new('Missing COPY.')}
        for($channel=0;$channel -lt 512;$channel++){if(-not [float]::IsFinite($result.Values[$channel])){throw [ArgumentException]::new('Nonfinite replay.')}}
        return $result
    }

    static [short[]] PackLibrary([float[]] $vectors,[float[]] $key) {
        if($vectors.Length%512 -ne 0 -or $key.Length -ne 512){throw [ArgumentException]::new('Library extent mismatch.')}
        $result=[short[]]::new($vectors.Length)
        for($channel=0;$channel -lt 512;$channel++){
            if(-not [float]::IsFinite($key[$channel]) -or $key[$channel] -le [float]0){throw [ArgumentException]::new('Invalid voice key.')}
        }
        for($unit=0;$unit -lt [int]($vectors.Length/512);$unit++){
            for($channel=0;$channel -lt 512;$channel++){
                $at=$unit*512+$channel;$value=[Math]::Round([double]$vectors[$at]/[double]$key[$channel])
                if(-not [double]::IsFinite($value) -or $value -lt [double]-32768 -or $value -gt [double]32767){throw [ArgumentException]::new('Selected key cannot represent real exemplar.')}
                $result[$at]=[short]$value
            }
        }
        return $result
    }

    static [void] WriteLibrary([string] $path,[short[]] $values) {
        $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        try{
            $at=0
            while($at -lt $values.Length){
                $count=[Math]::Min(1048576,$values.Length-$at);$part=[short[]]::new($count);$raw=[byte[]]::new(2*$count)
                [Array]::Copy($values,$at,$part,0,$count);[Buffer]::BlockCopy($part,0,$raw,0,$raw.Length);$stream.Write($raw,0,$raw.Length);$at+=$count
            }
        }finally{$stream.Dispose()}
    }
}

class KokoroStudentCandidate {
    [byte[]] $Program
    [float[]] $Values
    [double] $SquaredError
    [int] $ResidualChannels
    KokoroStudentCandidate() { $this.ResidualChannels=0 }
}

class KokoroStudentClimber {
    [float[]] $Source
    [short[]] $Library
    [float[]] $VoiceKey
    [float[]] $Directions
    [int[]] $Nearest
    [int[]] $PairIds
    [bool[]] $Starts
    [bool[]] $UsedExemplars
    [bool[]] $UsedDirections
    [int] $First
    [int] $UnitCount
    [int] $K
    [double] $Bar
    [string] $Directory
    [long] $ProgramBytes
    [long] $InitialBytes
    [long] $NoResidual
    [long] $ResidualBytes
    [long] $Accepted
    [long] $Attempts
    [long] $Completed
    [double] $MinimumSNR

    static [short[]] ReadLibrary([string] $path,[int] $values) {
        $stream=[IO.File]::OpenRead($path)
        try{
            if($stream.Length -ne 2L*[long]$values){throw [ArgumentException]::new('Native library extent differs.')}
            $result=[short[]]::new($values);$at=0
            while($at -lt $values){
                $count=[Math]::Min(1048576,$values-$at);$raw=[byte[]]::new(2*$count);$part=[short[]]::new($count)
                $stream.ReadExactly($raw,0,$raw.Length);[Buffer]::BlockCopy($raw,0,$part,0,$raw.Length);[Array]::Copy($part,0,$result,$at,$count);$at+=$count
            }
            return $result
        }finally{$stream.Dispose()}
    }

    static [byte[]] BaseProgram([int] $exemplar,[int] $pair) {
        $size=5;if($pair -ge 0){$size=10};$result=[byte[]]::new($size);$result[0]=[byte]1
        $id=[BitConverter]::GetBytes($exemplar);[Array]::Copy($id,0,$result,1,4)
        if($pair -ge 0){$result[5]=[byte]2;$id=[BitConverter]::GetBytes($pair);[Array]::Copy($id,0,$result,6,4)}
        return $result
    }

    static [double] Error([float[]] $values,[float[]] $target) {
        $sum=[double]0
        for($channel=0;$channel -lt 512;$channel++){$delta=[double]$values[$channel]-[double]$target[$channel];$sum+=$delta*$delta}
        return $sum
    }

    static [KokoroStudentCandidate] Complete([byte[]] $baseProgram,[float[]] $baseValues,[float[]] $target,[float[]] $key,[double] $budget,[bool] $trim) {
        $result=[KokoroStudentCandidate]::new();$result.Values=[float[]]$baseValues.Clone()
        $baseError=[double[]]::new(512);$finalError=[double[]]::new(512)
        $codes0=[short[]]::new(512);$codes1=[short[]]::new(512);$fine=[short[]]::new(512)
        $costs=[int[]]::new(512);$scores=[double[]]::new(512);$order=[int[]]::new(512);$keep=[bool[]]::new(512)
        $total=[double]0
        for($channel=0;$channel -lt 512;$channel++){
            $order[$channel]=$channel;$delta=[double]$target[$channel]-[double]$baseValues[$channel];$baseError[$channel]=$delta*$delta
            $value=$baseValues[$channel]
            $correction=[short][Math]::Clamp([Math]::Round($delta/[double]$key[$channel]),-32768.0,32767.0)
            $codes0[$channel]=$correction;$value=[float]($value+[float]([float]$correction*$key[$channel]))
            $delta=[double]$target[$channel]-[double]$value
            $correction=[short][Math]::Clamp([Math]::Round($delta/[double]$key[$channel]),-32768.0,32767.0)
            $codes1[$channel]=$correction;$value=[float]($value+[float]([float]$correction*$key[$channel]))
            $scale=[float]($key[$channel]*[float]0.000030517578125)
            $delta=[double]$target[$channel]-[double]$value
            $correction=[short][Math]::Clamp([Math]::Round($delta/[double]$scale),-32768.0,32767.0)
            $fine[$channel]=$correction;$value=[float]($value+[float]([float]$correction*$scale))
            $result.Values[$channel]=$value;$delta=[double]$target[$channel]-[double]$value;$finalError[$channel]=$delta*$delta;$total+=$finalError[$channel]
            $cost=0;if($codes0[$channel] -ne [short]0){$cost+=4};if($codes1[$channel] -ne [short]0){$cost+=4};if($fine[$channel] -ne [short]0){$cost+=4}
            $costs[$channel]=$cost;$keep[$channel]=$cost -gt 0
            $scores[$channel]=[double]::NegativeInfinity
            if($cost -gt 0){$scores[$channel]=($baseError[$channel]-$finalError[$channel])/[double]$cost}
        }
        if($trim){
            [Array]::Sort[double,int]($scores,$order)
            for($index=0;$index -lt 512;$index++){
                $channel=$order[$index]
                if($keep[$channel]){
                    $without=$total+$baseError[$channel]-$finalError[$channel]
                    if($without -le $budget){$keep[$channel]=$false;$total=$without;$result.Values[$channel]=$baseValues[$channel]}
                }
            }
        }
        $counts=[int[]]::new(3);$bytes=$baseProgram.Length
        for($block=0;$block -lt 3;$block++){
            $codes=$codes0;if($block -eq 1){$codes=$codes1};if($block -eq 2){$codes=$fine}
            for($channel=0;$channel -lt 512;$channel++){if($keep[$channel] -and $codes[$channel] -ne [short]0){$counts[$block]=$counts[$block]+1}}
            if($counts[$block] -gt 0){$bytes+=4+4*$counts[$block]}
        }
        $result.Program=[byte[]]::new($bytes);[Array]::Copy($baseProgram,$result.Program,$baseProgram.Length);$at=$baseProgram.Length
        for($block=0;$block -lt 3;$block++){
            $codes=$codes0;if($block -eq 1){$codes=$codes1};if($block -eq 2){$codes=$fine}
            $count=$counts[$block]
            if($count -gt 0){
                $shift=0;if($block -eq 2){$shift=15}
                $result.Program[$at]=[byte]3;$result.Program[$at+1]=[byte]$shift;$result.Program[$at+2]=[byte]($count -band 255);$result.Program[$at+3]=[byte]($count -shr 8);$at+=4
                for($channel=0;$channel -lt 512;$channel++){
                    if($keep[$channel] -and $codes[$channel] -ne [short]0){
                        $code=[int]$codes[$channel] -band 65535
                        $result.Program[$at]=[byte]($channel -band 255);$result.Program[$at+1]=[byte]($channel -shr 8)
                        $result.Program[$at+2]=[byte]($code -band 255);$result.Program[$at+3]=[byte]($code -shr 8);$at+=4
                    }
                }
            }
        }
        for($channel=0;$channel -lt 512;$channel++){if($keep[$channel]){$result.ResidualChannels++}}
        $result.SquaredError=[KokoroStudentClimber]::Error($result.Values,$target)
        return $result
    }

    [void] Journal([IO.BinaryWriter] $writer,[int] $unit,[int] $mutation,[int] $candidate,[int] $bytes,[double] $snr,[bool] $kept,[int] $previousBytes) {
        $writer.Write($unit);$writer.Write($mutation);$writer.Write($candidate);$writer.Write($bytes);$writer.Write($snr);$writer.Write([int]$kept);$writer.Write($previousBytes)
        $this.Attempts+=1L;if($kept -and $mutation -ne 0){$this.Accepted+=1L}
    }

    [void] Run() {
        if($this.Source.Length -ne 512*$this.UnitCount -or $this.Starts.Length -ne $this.UnitCount){throw [ArgumentException]::new('Climber source extent mismatch.')}
        $programStream=[IO.File]::Open([IO.Path]::Combine($this.Directory,'programs.bin'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        $indexStream=[IO.File]::Open([IO.Path]::Combine($this.Directory,'offsets.i64'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        $journalStream=[IO.File]::Open([IO.Path]::Combine($this.Directory,'journal.bin'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        $programWriter=[IO.BinaryWriter]::new($programStream);$indexWriter=[IO.BinaryWriter]::new($indexStream);$journalWriter=[IO.BinaryWriter]::new($journalStream)
        $this.MinimumSNR=[double]::PositiveInfinity;$previous=[float[]]::new(0)
        try{
            for($local=0;$local -lt $this.UnitCount;$local++){
                $unit=$this.First+$local;if($this.Starts[$local]){$previous=[float[]]::new(0)}
                $target=[float[]]::new(512);[Array]::Copy($this.Source,$local*512,$target,0,512)
                $signal=[double]0;for($channel=0;$channel -lt 512;$channel++){$signal+=[double]$target[$channel]*[double]$target[$channel]}
                $budget=$signal/[Math]::Pow(10.0,$this.Bar/10.0)
                $id=$this.Nearest[$unit*$this.K];$baseProgram=[KokoroStudentClimber]::BaseProgram($id,-1)
                $baseValues=[KokoroStudentCodec]::Replay($baseProgram,$this.Library,$this.VoiceKey,$this.Directions,$previous).Values
                $best=[KokoroStudentClimber]::Complete($baseProgram,$baseValues,$target,$this.VoiceKey,$budget,$false)
                if($best.SquaredError -gt $budget){throw [ArgumentException]::new('Initial COPY plus int16 corrections violates feature bar.')}
                $this.InitialBytes+=[long]$best.Program.Length;$snr=[double]::PositiveInfinity;if($best.SquaredError -gt [double]0){$snr=10.0*[Math]::Log10($signal/$best.SquaredError)}
                $this.Journal($journalWriter,$unit,0,$id,$best.Program.Length,$snr,$true,0)
                $candidate=[KokoroStudentClimber]::Complete($baseProgram,$baseValues,$target,$this.VoiceKey,$budget,$true)
                $snr=[double]::PositiveInfinity;if($candidate.SquaredError -gt [double]0){$snr=10.0*[Math]::Log10($signal/$candidate.SquaredError)}
                $kept=$candidate.Program.Length -lt $best.Program.Length -and $candidate.SquaredError -le $budget
                $this.Journal($journalWriter,$unit,1,$id,$candidate.Program.Length,$snr,$kept,$best.Program.Length)
                if($kept){$best=$candidate}
                for($rank=1;$rank -lt $this.K;$rank++){
                    $other=$this.Nearest[$unit*$this.K+$rank]
                    if($other -ge 0){
                        $baseProgram=[KokoroStudentClimber]::BaseProgram($other,-1);$baseValues=[KokoroStudentCodec]::Replay($baseProgram,$this.Library,$this.VoiceKey,$this.Directions,$previous).Values
                        $candidate=[KokoroStudentClimber]::Complete($baseProgram,$baseValues,$target,$this.VoiceKey,$budget,$true)
                        $snr=[double]::PositiveInfinity;if($candidate.SquaredError -gt [double]0){$snr=10.0*[Math]::Log10($signal/$candidate.SquaredError)}
                        $kept=$candidate.Program.Length -lt $best.Program.Length -and $candidate.SquaredError -le $budget
                        $this.Journal($journalWriter,$unit,1+$rank,$other,$candidate.Program.Length,$snr,$kept,$best.Program.Length)
                        if($kept){$best=$candidate}
                    }else{$this.Journal($journalWriter,$unit,1+$rank,-1,0,[double]::NegativeInfinity,$false,$best.Program.Length)}
                }
                $pair=$this.PairIds[$unit]
                if($previous.Length -eq 512 -and $pair -ge 0){
                    $baseProgram=[KokoroStudentClimber]::BaseProgram(-1,$pair);$baseValues=[KokoroStudentCodec]::Replay($baseProgram,$this.Library,$this.VoiceKey,$this.Directions,$previous).Values
                    $candidate=[KokoroStudentClimber]::Complete($baseProgram,$baseValues,$target,$this.VoiceKey,$budget,$true)
                    $snr=[double]::PositiveInfinity;if($candidate.SquaredError -gt [double]0){$snr=10.0*[Math]::Log10($signal/$candidate.SquaredError)}
                    $kept=$candidate.Program.Length -lt $best.Program.Length -and $candidate.SquaredError -le $budget
                    $this.Journal($journalWriter,$unit,5,$pair,$candidate.Program.Length,$snr,$kept,$best.Program.Length)
                    if($kept){$best=$candidate}
                }else{$this.Journal($journalWriter,$unit,5,-1,0,[double]::NegativeInfinity,$false,$best.Program.Length)}
                $replayed=[KokoroStudentCodec]::Replay($best.Program,$this.Library,$this.VoiceKey,$this.Directions,$previous).Values
                $squaredError=[KokoroStudentClimber]::Error($replayed,$target)
                if($squaredError -gt $budget){throw [ArgumentException]::new('Independent final replay failed feature quality.')}
                $snr=[double]::PositiveInfinity;if($squaredError -gt [double]0){$snr=10.0*[Math]::Log10($signal/$squaredError)}
                $this.MinimumSNR=[Math]::Min($this.MinimumSNR,$snr)
                $copyId=[BitConverter]::ToInt32($best.Program,1)
                $baseBytes=5;if($copyId -lt 0){$baseBytes=10};$this.ResidualBytes+=[long]($best.Program.Length-$baseBytes)
                if($copyId -ge 0){$this.UsedExemplars[$copyId]=$true}else{$this.UsedDirections[[BitConverter]::ToInt32($best.Program,6)]=$true}
                $indexWriter.Write($programStream.Position);$programWriter.Write($best.Program);$this.ProgramBytes+=[long]$best.Program.Length
                if($best.ResidualChannels -eq 0){$this.NoResidual+=1L}
                $previous=$replayed;$this.Completed=$local+1
            }
            $indexWriter.Write($programStream.Position)
        }finally{$programWriter.Dispose();$indexWriter.Dispose();$journalWriter.Dispose();$programStream.Dispose();$indexStream.Dispose();$journalStream.Dispose()}
    }
}

class KokoroStudentStore {
    static [void] Mark([byte[]] $programs,[bool[]] $copies,[bool[]] $directions) {
        $at=0
        while($at -lt $programs.Length){
            $opcode=[int]$programs[$at];$at++
            if($opcode -eq 1 -or $opcode -eq 2){
                if($programs.Length-$at -lt 4){throw [ArgumentException]::new('Truncated reference index.')}
                $id=[BitConverter]::ToInt32($programs,$at);$at+=4
                if($opcode -eq 1){if($id -ge 0){if($id -ge $copies.Length){throw [ArgumentException]::new('COPY reference outside library.')};$copies[$id]=$true}elseif($id -ne -1){throw [ArgumentException]::new('Invalid previous COPY.')}}
                else{if($id -lt 0 -or $id -ge $directions.Length){throw [ArgumentException]::new('DIRECTION reference outside library.')};$directions[$id]=$true}
            }elseif($opcode -eq 3){
                if($programs.Length-$at -lt 3){throw [ArgumentException]::new('Truncated residual index.')}
                $count=[int][BitConverter]::ToUInt16($programs,$at+1);$at+=3
                if($count -gt 512 -or 4*$count -gt $programs.Length-$at){throw [ArgumentException]::new('Residual reference extent differs.')};$at+=4*$count
            }elseif($opcode -eq 4){if($programs.Length-$at -lt 4){throw [ArgumentException]::new('Truncated flags index.')};$at+=4}
            else{throw [ArgumentException]::new('Invalid opcode in reference index.')}
        }
    }
    static [int[]] Map([byte[]] $mask) {
        $map=[int[]]::new($mask.Length);$count=0
        for($unit=0;$unit -lt $mask.Length;$unit++){
            $map[$unit]=-1
            if($mask[$unit] -eq [byte]1){$map[$unit]=$count;$count++}
            elseif($mask[$unit] -ne [byte]0){throw [ArgumentException]::new('Invalid used-library mask.')}
        }
        return $map
    }

    static [long] CompactLibrary([short[]] $library,[int[]] $map,[string] $path) {
        if($library.Length -ne 512*$map.Length){throw [ArgumentException]::new('Compaction map extent differs.')}
        $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        $part=[short[]]::new(512*1024);$raw=[byte[]]::new(2*$part.Length);$at=0;$count=0
        try{
            for($unit=0;$unit -lt $map.Length;$unit++){
                if($map[$unit] -ge 0){
                    if($map[$unit] -ne $count){throw [ArgumentException]::new('Compaction map is not dense.')}
                    [Array]::Copy($library,$unit*512,$part,$at,512);$at+=512;$count++
                    if($at -eq $part.Length){[Buffer]::BlockCopy($part,0,$raw,0,2*$at);$stream.Write($raw,0,2*$at);$at=0}
                }
            }
            if($at -gt 0){[Buffer]::BlockCopy($part,0,$raw,0,2*$at);$stream.Write($raw,0,2*$at)}
            return 1024L*[long]$count
        }finally{$stream.Dispose()}
    }

    static [byte[]] Rewrite([byte[]] $programs,[int[]] $copies,[int[]] $directions) {
        $result=[byte[]]$programs.Clone();$at=0
        while($at -lt $result.Length){
            $opcode=[int]$result[$at];$at++
            if($opcode -eq 1 -or $opcode -eq 2){
                if($result.Length-$at -lt 4){throw [ArgumentException]::new('Truncated program during compaction.')}
                $id=[BitConverter]::ToInt32($result,$at);$mapped=$id
                if($opcode -eq 1 -and $id -ge 0){
                    if($id -ge $copies.Length -or $copies[$id] -lt 0){throw [ArgumentException]::new('COPY is missing from compact library.')}
                    $mapped=$copies[$id]
                }elseif($opcode -eq 2){
                    if($id -lt 0 -or $id -ge $directions.Length -or $directions[$id] -lt 0){throw [ArgumentException]::new('DIRECTION is missing from compact library.')}
                    $mapped=$directions[$id]
                }elseif($id -ne -1){throw [ArgumentException]::new('Invalid COPY sentinel.')}
                $bytes=[BitConverter]::GetBytes($mapped);[Array]::Copy($bytes,0,$result,$at,4);$at+=4
            }elseif($opcode -eq 3){
                if($result.Length-$at -lt 3){throw [ArgumentException]::new('Truncated residual during compaction.')}
                $count=[int][BitConverter]::ToUInt16($result,$at+1);$at+=3
                if($count -gt 512 -or $count*4 -gt $result.Length-$at){throw [ArgumentException]::new('Invalid residual during compaction.')}
                $at+=$count*4
            }elseif($opcode -eq 4){
                if($result.Length-$at -lt 4){throw [ArgumentException]::new('Truncated flags during compaction.')};$at+=4
            }else{throw [ArgumentException]::new('Invalid opcode during compaction.')}
        }
        return $result
    }
}

class KokoroStudentMath {
    static [float[]] UnitMajor([float[]] $channelMajor,[int] $units) {
        if($units -le 0 -or $channelMajor.Length -ne 512*$units){throw [ArgumentException]::new('Feature transpose extent differs.')}
        $result=[float[]]::new($channelMajor.Length)
        for($unit=0;$unit -lt $units;$unit++){for($channel=0;$channel -lt 512;$channel++){$result[$unit*512+$channel]=$channelMajor[$channel*$units+$unit]}}
        return $result
    }
    static [float[]] Stretch([float[]] $values,[int] $count) {
        if($values.Length -eq 0 -or $count -le 0){throw [ArgumentException]::new('Contour stretch extent differs.')}
        $result=[float[]]::new($count)
        for($frame=0;$frame -lt $count;$frame++){$index=[int][Math]::Floor([double]$frame*[double]$values.Length/[double]$count);$result[$frame]=$values[$index]}
        return $result
    }
    static [float[]] Gain([float[]] $values,[float] $gain) {
        if(-not [float]::IsFinite($gain) -or $gain -le [float]0){throw [ArgumentException]::new('Invalid output gain.')}
        $result=[float[]]::new($values.Length)
        for($sample=0;$sample -lt $values.Length;$sample++){$result[$sample]=[float]($values[$sample]*$gain)}
        return $result
    }
    static [double[]] PcmStats([float[]] $values) {
        $peak=[double]0;$clips=[double]0
        for($sample=0;$sample -lt $values.Length;$sample++){
            if(-not [float]::IsFinite($values[$sample])){throw [ArgumentException]::new('Nonfinite PCM.')}
            $peak=[Math]::Max($peak,[Math]::Abs([double]$values[$sample]))
            if($values[$sample] -lt [float]-1 -or $values[$sample] -gt [float](32767.0/32768.0)){$clips+=1.0}
        }
        return [double[]]@($peak,$clips)
    }
    static [short[]] Pcm16([float[]] $samples) {
        $result=[short[]]::new($samples.Length)
        for($i=0;$i -lt $samples.Length;$i++) {
            if(-not [float]::IsFinite($samples[$i])) { throw [ArgumentException]::new('Nonfinite PCM.') }
            $value=[Math]::Round([double]$samples[$i]*32768.0)
            $result[$i]=[short][Math]::Clamp($value,-32768.0,32767.0)
        }
        return $result
    }
    static [float[]] PcmFloat([short[]] $samples) {
        $result=[float[]]::new($samples.Length)
        for($i=0;$i -lt $samples.Length;$i++) { $result[$i]=[float]([double]$samples[$i]/32768.0) }
        return $result
    }
    static [void] Expand([short[]] $quantized, [float[]] $scales, [int] $units, [float[]] $vectors, [int] $first, [double[]] $energy) {
        if ($quantized.Length -ne 512*$units -or $scales.Length -ne 512 -or $first -lt 0 -or $first+$units -gt $energy.Length -or $vectors.Length -ne 512*$energy.Length) { throw [ArgumentException]::new('Bank vector extent mismatch.') }
        for ($unit=0; $unit -lt $units; $unit++) {
            $sum=[double]0
            for ($channel=0; $channel -lt 512; $channel++) {
                $value=[float]([float]$quantized[$channel*$units+$unit]*$scales[$channel])
                if (-not [float]::IsFinite($value)) { throw [ArgumentException]::new('Nonfinite bank feature.') }
                $vectors[($first+$unit)*512+$channel]=$value
                $sum+=[double]$value*[double]$value
            }
            $energy[$first+$unit]=$sum
        }
    }
}

class KokoroStudentNearestWorker {
    [float[]] $Vectors
    [int[]] $Order
    [int[]] $Offsets
    [int[]] $UnitGroups
    [int[]] $Nearest
    [double[]] $Errors
    [int] $First
    [int] $Last
    [int] $K
    [int] $Completed
    [void] Run() {
        $bestIds=[int[]]::new($this.K);$bestErrors=[double[]]::new($this.K)
        for ($unit=$this.First; $unit -lt $this.Last; $unit++) {
            for ($rank=0; $rank -lt $this.K; $rank++) { $bestIds[$rank]=-1; $bestErrors[$rank]=[double]::PositiveInfinity }
            $group=$this.UnitGroups[$unit];$base=$unit*512
            for ($at=$this.Offsets[$group]; $at -lt $this.Offsets[$group+1]; $at++) {
                $candidate=$this.Order[$at]
                if ($candidate -eq $unit) { continue }
                $other=$candidate*512;$distance=[double]0
                for ($channel=0; $channel -lt 512; $channel++) {
                    $difference=[double]$this.Vectors[$base+$channel]-[double]$this.Vectors[$other+$channel]
                    $distance+=$difference*$difference
                    if ($distance -gt $bestErrors[$this.K-1]) { break }
                }
                if ($distance -gt $bestErrors[$this.K-1]) { continue }
                $insert=$this.K
                for ($rank=0; $rank -lt $this.K; $rank++) {
                    if ($distance -lt $bestErrors[$rank] -or ($distance -eq $bestErrors[$rank] -and ($bestIds[$rank] -lt 0 -or $candidate -lt $bestIds[$rank]))) { $insert=$rank; break }
                }
                if ($insert -lt $this.K) {
                    for ($rank=$this.K-1; $rank -gt $insert; $rank--) { $bestIds[$rank]=$bestIds[$rank-1];$bestErrors[$rank]=$bestErrors[$rank-1] }
                    $bestIds[$insert]=$candidate;$bestErrors[$insert]=$distance
                }
            }
            for ($rank=0; $rank -lt $this.K; $rank++) { $this.Nearest[$unit*$this.K+$rank]=$bestIds[$rank];$this.Errors[$unit*$this.K+$rank]=$bestErrors[$rank] }
            $this.Completed=$unit-$this.First+1
        }
    }
}

class KokoroStudentDirectionWorker {
    [float[]] $Vectors
    [int[]] $Order
    [int[]] $Offsets
    [int[]] $Medoids
    [double[]] $Energy
    [double[]] $Errors
    [int] $First
    [int] $Last
    [int] $Completed
    [void] Run() {
        for ($group=$this.First; $group -lt $this.Last; $group++) {
            $firstAt=$this.Offsets[$group];$lastAt=$this.Offsets[$group+1];$count=$lastAt-$firstAt
            $totals=[double[]]::new(512);$signal=[double]0
            for ($at=$firstAt; $at -lt $lastAt; $at++) {
                $base=$this.Order[$at]*512
                for ($channel=0; $channel -lt 512; $channel++) {
                    $direction=[double]$this.Vectors[$base+$channel]-[double]$this.Vectors[$base-512+$channel]
                    $totals[$channel]+=$direction;$signal+=$direction*$direction
                }
            }
            $best=[double]::PositiveInfinity;$medoid=-1
            for ($at=$firstAt; $at -lt $lastAt; $at++) {
                $candidate=$this.Order[$at];$base=$candidate*512;$norm=[double]0;$dot=[double]0
                for ($channel=0; $channel -lt 512; $channel++) {
                    $direction=[double]$this.Vectors[$base+$channel]-[double]$this.Vectors[$base-512+$channel]
                    $norm+=$direction*$direction;$dot+=$direction*$totals[$channel]
                }
                $score=[double]$count*$norm-[double]2*$dot
                if ($score -lt $best -or ($score -eq $best -and ($medoid -lt 0 -or $candidate -lt $medoid))) { $best=$score;$medoid=$candidate }
            }
            $squaredError=[double]0;$medoidBase=$medoid*512
            for ($at=$firstAt; $at -lt $lastAt; $at++) {
                $base=$this.Order[$at]*512
                for ($channel=0; $channel -lt 512; $channel++) {
                    $direction=[double]$this.Vectors[$base+$channel]-[double]$this.Vectors[$base-512+$channel]
                    $selected=[double]$this.Vectors[$medoidBase+$channel]-[double]$this.Vectors[$medoidBase-512+$channel]
                    $difference=$direction-$selected;$squaredError+=$difference*$difference
                }
            }
            $this.Medoids[$group]=$medoid;$this.Energy[$group]=$signal;$this.Errors[$group]=$squaredError;$this.Completed=$group-$this.First+1
        }
    }
}

function Read-KokoroStudentNpy {
    param([IO.Compression.ZipArchive]$Archive,[string]$Name,[string]$DType,[type]$ElementType)
    # The preserved mine.ps1 NPY reader supplies the format. No bank entrypoint
    # is executed, and no preserved JSON is rewritten.
    $entry=$Archive.GetEntry($Name+'.npy')
    if($null -eq $entry -or $entry.Length -gt 1073741824){throw "Missing/oversized bank array: $Name"}
    $stream=$entry.Open();$memory=[IO.MemoryStream]::new()
    try{$stream.CopyTo($memory);$raw=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
    if($raw.Length -lt 10 -or $raw[0] -ne 147 -or [Text.Encoding]::ASCII.GetString($raw,1,5) -cne 'NUMPY' -or $raw[6] -ne 1){throw 'Unsupported NPY header.'}
    $headerLength=[BitConverter]::ToUInt16($raw,8);$offset=10+$headerLength
    if($offset -gt $raw.Length){throw 'Truncated NPY header.'}
    $header=[Text.Encoding]::ASCII.GetString($raw,10,$headerLength)
    if($header -cnotmatch "'descr': '$([regex]::Escape($DType))'" -or $header -cnotmatch "'fortran_order': False"){throw "Bank dtype/order mismatch: $Name"}
    $width=switch($ElementType.FullName){'System.Int16'{2};'System.UInt16'{2};'System.Single'{4};'System.Int64'{8};default{throw 'Unsupported bank element type.'}}
    if(($raw.Length-$offset)%$width){throw 'Incomplete native array.'}
    $values=[Array]::CreateInstance($ElementType,[int](($raw.Length-$offset)/$width))
    [Buffer]::BlockCopy($raw,$offset,$values,0,$raw.Length-$offset)
    return ,$values
}

function Get-KokoroStudentKernel {
    param([string]$Directory)
    $root=Split-Path -Parent $PSScriptRoot
    $compiler=Join-Path $root 'build/phonemizer/inputs/pslowering-1afabe056235a570da29e268824784557d4f6cdd'
    $pins=@(Import-Csv (Join-Path $compiler 'verified-source.tsv') -Delimiter "`t")
    if($pins.Count -ne 9){throw 'Incomplete pinned compiler.'}
    foreach($pin in $pins){if($pin.Commit -cne '1afabe056235a570da29e268824784557d4f6cdd' -or (Get-FileHash (Join-Path $compiler $pin.Path)).Hash -cne $pin.Sha256){throw 'Compiler integrity differs.'}}
    Import-Module (Join-Path $compiler 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1')
    $dll=Join-Path $Directory 'Kokoro.Student.dll'
    $null=Export-LoweredAssembly -SourcePath $PSCommandPath -ClassName KokoroStudentMath -OutputPath $dll -Deterministic
    $admission=Test-LoweredAssembly -AssemblyPath $dll
    if(-not $admission.ClrOnlyAdmitted){throw 'Student kernels reference SMA.'}
    $assembly=[Reflection.Assembly]::LoadFrom($dll)
    [pscustomobject]@{Assembly=$assembly;SHA256=(Get-FileHash $dll).Hash;
        Expand=$assembly.GetType('KokoroStudentMath',$true).GetMethod('Expand').CreateDelegate([Action[short[],float[],int,float[],int,double[]]]);
        NearestType=$assembly.GetType('KokoroStudentNearestWorker',$true);DirectionType=$assembly.GetType('KokoroStudentDirectionWorker',$true)}
}

function Get-KokoroStudentQuantiles {
    param([double[]]$Values)
    if($Values.Length -eq 0){throw 'Empty measurement population.'}
    $copy=[double[]]$Values.Clone();[Array]::Sort($copy)
    $middle=[int][Math]::Floor(($copy.Length-1)/2)
    [pscustomobject]@{Count=$copy.Length;Median=$copy[$middle];MedianRule='Lower observed rank';
        P10=$copy[[int][Math]::Ceiling(0.1*$copy.Length)-1];P90=$copy[[int][Math]::Ceiling(0.9*$copy.Length)-1]}
}

function Test-KokoroStudentKernel {
    param($Kernel)
    $quantized=[short[]]::new(1024);$quantized[0]=4;$quantized[1]=-8;$quantized[2]=2;$quantized[3]=6
    $scales=[float[]]::new(512);$scales[0]=[float]0.25;$scales[1]=[float]0.5
    $expanded=[float[]]::new(1536);$energy=[double[]]::new(3)
    $Kernel.Expand.Invoke($quantized,$scales,2,$expanded,1,$energy)
    if($expanded[512] -ne 1 -or $expanded[513] -ne 1 -or $expanded[1024] -ne -2 -or $expanded[1025] -ne 3 -or $energy[1] -ne 2 -or $energy[2] -ne 13){throw 'Bank dequantization/layout check failed.'}
    $vectors=[float[]]::new(5*512)
    $values=[float[]]@(0,1,3,6,9)
    for($unit=0;$unit -lt 5;$unit++){$vectors[$unit*512]=$values[$unit]}
    $worker=[Activator]::CreateInstance($Kernel.NearestType)
    $worker.Vectors=$vectors;$worker.Order=[int[]]@(0,1,2,3,4);$worker.Offsets=[int[]]@(0,5);$worker.UnitGroups=[int[]]::new(5)
    $worker.Nearest=[int[]]::new(10);$worker.Errors=[double[]]::new(10);$worker.First=0;$worker.Last=5;$worker.K=2
    $worker.Run()
    if(-not [Linq.Enumerable]::SequenceEqual[int]($worker.Nearest,[int[]]@(1,2,0,2,1,0,2,4,3,2)) -or
        -not [Linq.Enumerable]::SequenceEqual[double]($worker.Errors,[double[]]@(1,9,1,4,4,9,9,9,9,36))){throw 'Compiled nearest selection failed self-exclusion/distance/tie check.'}
    $direction=[Activator]::CreateInstance($Kernel.DirectionType)
    $direction.Vectors=$vectors;$direction.Order=[int[]]@(1,2,3,4);$direction.Offsets=[int[]]@(0,4)
    $direction.Medoids=[int[]]::new(1);$direction.Energy=[double[]]::new(1);$direction.Errors=[double[]]::new(1);$direction.First=0;$direction.Last=1
    $direction.Run()
    if($direction.Medoids[0] -ne 2 -or $direction.Energy[0] -ne 23 -or $direction.Errors[0] -ne 3){throw 'Compiled direction medoid differs from direct total squared differences.'}
    return $true
}

function Read-KokoroStudentBank {
    param([string]$BankPath,$Kernel,[int]$SentenceLimit=0)
    $orderPath=Join-Path $BankPath 'order.json'
    $sentences=@(Get-Content -LiteralPath $orderPath -Raw | ConvertFrom-Json -AsHashtable)
    if($SentenceLimit -gt 0){$sentences=@($sentences | Select-Object -First $SentenceLimit)}
    $total=0L;foreach($sentence in $sentences){$total+=$sentence.phonemes.Length+2}
    if($total -lt 2 -or $total -gt [int]::MaxValue/512){throw 'Unsupported bank vector extent.'}
    $count=[int]$total;$vectors=[float[]]::new(512*$count);$energy=[double[]]::new($count)
    $unitSentences=[int[]]::new($count);$unitTokens=[int[]]::new($count);$unitContexts=[int[]]::new($count);$unitPhones=[int[]]::new($count)
    $contexts=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $phones=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $contextGroups=[Collections.Generic.List[Collections.Generic.List[int]]]::new();$phoneGroups=[Collections.Generic.List[Collections.Generic.List[int]]]::new()
    $pairGroups=[Collections.Generic.Dictionary[string,Collections.Generic.List[int]]]::new([StringComparer]::Ordinal)
    $provenance=[Collections.Generic.List[object]]::new();$at=0;$sentenceAt=0
    foreach($chunk in Get-ChildItem -LiteralPath $BankPath -Filter 'chunk-*.npz' | Sort-Object Name){
        if($sentenceAt -ge $sentences.Count){break}
        if([int]$chunk.BaseName.Substring(6)*1000 -ne $sentenceAt){throw 'Bank chunk ordering differs.'}
        $zip=[IO.Compression.ZipFile]::OpenRead($chunk.FullName)
        try{
            $offsets=Read-KokoroStudentNpy $zip tok_off '<i8' ([long])
            $packed=Read-KokoroStudentNpy $zip t_en '<i2' ([short]);$scales=Read-KokoroStudentNpy $zip scale '<f4' ([float])
        }finally{$zip.Dispose()}
        $sourceCount=[int]$offsets[$offsets.Length-1];$take=[Math]::Min($offsets.Length-1,$sentences.Count-$sentenceAt)
        $takeUnits=[int]$offsets[$take]
        if($takeUnits -ne $sourceCount){
            $subset=[short[]]::new(512*$takeUnits)
            for($channel=0;$channel -lt 512;$channel++){[Array]::Copy($packed,$channel*$sourceCount,$subset,$channel*$takeUnits,$takeUnits)}
            $packed=$subset
        }
        $Kernel.Expand.Invoke($packed,$scales,$takeUnits,$vectors,$at,$energy)
        for($local=0;$local -lt $take;$local++){
            $padded='##<'+$sentences[$sentenceAt].phonemes+'>##';$length=[int]($offsets[$local+1]-$offsets[$local])
            if($length -ne $padded.Length-4){throw 'Bank phoneme/token alignment differs.'}
            for($token=0;$token -lt $length;$token++){
                $context=$padded.Substring($token+1,3);$phone=$padded.Substring($token+2,1)
                if(-not $contexts.ContainsKey($context)){$contexts.Add($context,$contextGroups.Count);$contextGroups.Add([Collections.Generic.List[int]]::new())}
                if(-not $phones.ContainsKey($phone)){$phones.Add($phone,$phoneGroups.Count);$phoneGroups.Add([Collections.Generic.List[int]]::new())}
                $contextId=$contexts[$context];$phoneId=$phones[$phone];$contextGroups[$contextId].Add($at);$phoneGroups[$phoneId].Add($at)
                $unitContexts[$at]=$contextId;$unitPhones[$at]=$phoneId;$unitSentences[$at]=$sentenceAt;$unitTokens[$at]=$token
                if($token -gt 0){$pair=$padded.Substring($token+1,2);if(-not $pairGroups.ContainsKey($pair)){$pairGroups.Add($pair,[Collections.Generic.List[int]]::new())};$pairGroups[$pair].Add($at)}
                $at++
            }
            $sentenceAt++
        }
        $provenance.Add([pscustomobject]@{Path=$chunk.FullName;SHA256=(Get-FileHash -LiteralPath $chunk.FullName).Hash;Sentences=$take;Units=$takeUnits})
        Write-Host "Student bank: $sentenceAt sentences, $at units"
    }
    if($at -ne $count -or $sentenceAt -ne $sentences.Count){throw 'Incomplete bank.'}
    [pscustomobject]@{PSTypeName='Kokoro.Student.Bank';Path=$BankPath;Vectors=$vectors;Energy=$energy;Count=$count;Sentences=$sentences;
        UnitSentences=$unitSentences;UnitTokens=$unitTokens;UnitContexts=$unitContexts;UnitPhones=$unitPhones;
        Contexts=$contexts;Phones=$phones;ContextGroups=$contextGroups;PhoneGroups=$phoneGroups;PairGroups=$pairGroups;
        Provenance=$provenance;OrderSHA256=(Get-FileHash -LiteralPath $orderPath).Hash}
}

function ConvertTo-KokoroStudentGroups {
    param([object[]]$Groups)
    $total=0;foreach($group in $Groups){$total+=$group.Count}
    $order=[int[]]::new($total);$offsets=[int[]]::new($Groups.Count+1);$at=0
    for($groupIndex=0;$groupIndex -lt $Groups.Count;$groupIndex++){$offsets[$groupIndex]=$at;foreach($unit in $Groups[$groupIndex]){$order[$at]=[int]$unit;$at++}}
    $offsets[$Groups.Count]=$at
    [pscustomobject]@{Order=$order;Offsets=$offsets}
}

function Wait-KokoroStudentWorkers {
    param([object[]]$Workers,[Threading.Tasks.Task[]]$Tasks,[string]$Stage)
    $watch=[Diagnostics.Stopwatch]::StartNew();$last=0.0
    while(-not [Threading.Tasks.Task]::WaitAll($Tasks,1000)){
        if($watch.Elapsed.TotalSeconds-$last -ge 20){$completed=0L;foreach($worker in $Workers){$completed+=$worker.Completed};Write-Host "Student $Stage : $completed completed";$last=$watch.Elapsed.TotalSeconds}
    }
    [Threading.Tasks.Task]::WaitAll($Tasks)
    return $watch.Elapsed.TotalMilliseconds
}

function Measure-KokoroStudentStructure {
    [CmdletBinding()]
    param([string]$BankPath,[Parameter(Mandatory)][string]$OutputDirectory,[ValidateRange(1,64)][int]$Threads=12,
        [ValidateRange(1,16)][int]$K=4,[ValidateRange(0,1000000)][int]$SentenceLimit=0)
    $root=Split-Path -Parent $PSScriptRoot
    if(-not $BankPath){$BankPath=Join-Path $root 'build/unit-bank'}
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh student directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    $kernel=Get-KokoroStudentKernel $out
    $null=Test-KokoroStudentKernel $kernel
    $bank=Read-KokoroStudentBank -BankPath $BankPath -Kernel $kernel -SentenceLimit $SentenceLimit
    $allGroups=[Collections.Generic.List[object]]::new()
    foreach($group in $bank.ContextGroups){$allGroups.Add($group)}
    foreach($group in $bank.PhoneGroups){$allGroups.Add($group)}
    $groups=ConvertTo-KokoroStudentGroups $allGroups.ToArray();$unitGroups=[int[]]::new($bank.Count);$fallback=0
    for($unit=0;$unit -lt $bank.Count;$unit++){
        $group=$bank.UnitContexts[$unit]
        if($bank.ContextGroups[$group].Count -lt 2){$group=$bank.ContextGroups.Count+$bank.UnitPhones[$unit];$fallback++}
        $unitGroups[$unit]=$group
    }
    $nearest=[int[]]::new($bank.Count*$K);$errors=[double[]]::new($nearest.Length)
    $workers=[Collections.Generic.List[object]]::new();$tasks=[Collections.Generic.List[Threading.Tasks.Task]]::new()
    for($index=0;$index -lt $Threads;$index++){
        $worker=[Activator]::CreateInstance($kernel.NearestType);$worker.Vectors=$bank.Vectors;$worker.Order=$groups.Order;$worker.Offsets=$groups.Offsets;$worker.UnitGroups=$unitGroups
        $worker.Nearest=$nearest;$worker.Errors=$errors;$worker.K=$K;$worker.First=[int][Math]::Floor($index*$bank.Count/[double]$Threads);$worker.Last=[int][Math]::Floor(($index+1)*$bank.Count/[double]$Threads)
        $workers.Add($worker);$tasks.Add([Threading.Tasks.Task]::Run($kernel.NearestType.GetMethod('Run').CreateDelegate([Action],$worker)))
    }
    $nearestMs=Wait-KokoroStudentWorkers $workers.ToArray() $tasks.ToArray() 'exemplars'
    $ratios=[double[]]::new($bank.Count);$missing=0
    for($unit=0;$unit -lt $bank.Count;$unit++){
        if($nearest[$unit*$K] -lt 0){$missing++;$ratios[$unit]=0}
        elseif($errors[$unit*$K] -eq 0){$ratios[$unit]=[double]::PositiveInfinity}
        else{$ratios[$unit]=$bank.Energy[$unit]/$errors[$unit*$K]}
    }
    $pairNames=@($bank.PairGroups.Keys | Where-Object {$bank.PairGroups[$_].Count -ge 20} | Sort-Object -CaseSensitive)
    $selectedGroups=[Collections.Generic.List[object]]::new();foreach($pairName in $pairNames){$selectedGroups.Add($bank.PairGroups[$pairName])}
    $directions=ConvertTo-KokoroStudentGroups $selectedGroups.ToArray();$medoids=[int[]]::new($pairNames.Count);$directionEnergy=[double[]]::new($pairNames.Count);$directionErrors=[double[]]::new($pairNames.Count)
    $workers.Clear();$tasks.Clear()
    for($index=0;$index -lt $Threads;$index++){
        $worker=[Activator]::CreateInstance($kernel.DirectionType);$worker.Vectors=$bank.Vectors;$worker.Order=$directions.Order;$worker.Offsets=$directions.Offsets
        $worker.Medoids=$medoids;$worker.Energy=$directionEnergy;$worker.Errors=$directionErrors;$worker.First=[int][Math]::Floor($index*$pairNames.Count/[double]$Threads);$worker.Last=[int][Math]::Floor(($index+1)*$pairNames.Count/[double]$Threads)
        $workers.Add($worker);$tasks.Add([Threading.Tasks.Task]::Run($kernel.DirectionType.GetMethod('Run').CreateDelegate([Action],$worker)))
    }
    $directionMs=Wait-KokoroStudentWorkers $workers.ToArray() $tasks.ToArray() 'directions'
    $covered=0L;$pairRows=@(for($index=0;$index -lt $pairNames.Count;$index++){
        $ratio=if($directionErrors[$index] -eq 0){[double]::PositiveInfinity}else{$directionEnergy[$index]/$directionErrors[$index]}
        $occurrences=$bank.PairGroups[$pairNames[$index]].Count
        if($ratio -gt 10){$covered+=$occurrences}
        [pscustomobject]@{Pair=$pairNames[$index];Occurrences=$occurrences;MedoidUnit=$medoids[$index];Energy=$directionEnergy[$index];Error=$directionErrors[$index];Ratio=$ratio}
    })
    foreach($arrayRecord in @(@('nearest.i32',$nearest),@('nearest-errors.f64',$errors),@('energy.f64',$bank.Energy))){
        $raw=[byte[]]::new([Buffer]::ByteLength($arrayRecord[1]));[Buffer]::BlockCopy($arrayRecord[1],0,$raw,0,$raw.Length);[IO.File]::WriteAllBytes((Join-Path $out $arrayRecord[0]),$raw)
    }
    $pairRows | Export-Clixml -LiteralPath (Join-Path $out 'directions.clixml');$pairRows | Export-Csv -LiteralPath (Join-Path $out 'directions.csv')
    $bank.Provenance.ToArray() | Export-Clixml -LiteralPath (Join-Path $out 'bank-provenance.clixml')
    $report=[pscustomobject]@{PSTypeName='Kokoro.Student.Structure';Units=$bank.Count;Sentences=$bank.Sentences.Count;Contexts=$bank.ContextGroups.Count;
        K=$K;FallbackUnits=$fallback;UnitsWithoutOtherExemplar=$missing;ExemplarRatio=(Get-KokoroStudentQuantiles $ratios);
        DirectionRatio=$(if($pairRows.Count){Get-KokoroStudentQuantiles ([double[]]$pairRows.Ratio)}else{$null});DirectionPairs=$pairRows.Count;
        PairCoveredUnits=$covered;PairCoveredBankShare=$covered/[double]$bank.Count;NearestMilliseconds=$nearestMs;DirectionMilliseconds=$directionMs;
        Distance='Squared difference of dequantized FP32 bank features, FP64 accumulation; same triphone, then phoneme fallback; self excluded';
        Medoid='Observed within-sentence direction minimizing total squared difference; counted sums only, no centroid';
        SourceSHA256=(Get-FileHash $PSCommandPath).Hash;KernelSHA256=$kernel.SHA256;OrderSHA256=$bank.OrderSHA256;Directory=$out}
    $report | Export-Clixml -LiteralPath (Join-Path $out 'structure.clixml')
    $script:StudentContext=[pscustomobject]@{Bank=$bank;Kernel=$kernel;Nearest=$nearest;Errors=$errors;Directions=$pairRows;K=$K;Report=$report}
    return $report
}

function Write-KokoroStudentWave {
    param([string]$Path,[short[]]$Samples)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    $writer=[IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([int](36+2*$Samples.Length))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([int]16)
        $writer.Write([short]1);$writer.Write([short]1);$writer.Write([int]24000);$writer.Write([int]48000)
        $writer.Write([short]2);$writer.Write([short]16);$writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([int](2*$Samples.Length))
        $raw=[byte[]]::new(2*$Samples.Length);[Buffer]::BlockCopy($Samples,0,$raw,0,$raw.Length);$writer.Write($raw)
    } finally {$writer.Dispose();$stream.Dispose()}
    $header=[IO.File]::ReadAllBytes($Path)
    if($header.Length -ne 44+2*$Samples.Length -or [BitConverter]::ToInt16($header,20) -ne 1 -or [BitConverter]::ToInt32($header,24) -ne 24000){throw 'PCM16 WAV verification failed.'}
}

function Render-KokoroStudentCopy {
    [CmdletBinding()]
    param([string]$BankPath,[Parameter(Mandatory)][string]$OutputDirectory,[string]$MeasurementDirectory,
        [ValidateRange(2,64)][int]$Threads=4,[int[]]$Targets=(1..9),[Collections.IDictionary]$SelectedUnits=$null,
        [Collections.Generic.Dictionary[int,float[]]]$ReplayVectors=$null,[switch]$OnlyCandidate,[ValidateRange(0.25,4)][float]$Intensity=1,[ValidateRange(0.5,2)][double]$DurationScale=1,[Collections.IDictionary]$TokenFrames=$null)
    $root=Split-Path -Parent $PSScriptRoot
    if(-not $BankPath){$BankPath=Join-Path $root 'build/unit-bank'}
    if(-not $MeasurementDirectory){$MeasurementDirectory=Join-Path $root 'build/student-20261015-full'}
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh student directory under build/.'}
    if($Targets.Count -eq 0 -or @($Targets | Where-Object {$_ -lt 1 -or $_ -gt 9}).Count -or @($Targets | Select-Object -Unique).Count -ne $Targets.Count){throw 'Targets must be distinct members of 1..9.'}
    [void][IO.Directory]::CreateDirectory($out)
    $kernel=Get-KokoroStudentKernel $out;$null=Test-KokoroStudentKernel $kernel
    $studentMath=$kernel.Assembly.GetType('KokoroStudentMath',$true)
    $pcm16=$studentMath.GetMethod('Pcm16').CreateDelegate([Func[float[],short[]]])
    $pcmFloat=$studentMath.GetMethod('PcmFloat').CreateDelegate([Func[short[],float[]]])
    $stretch=$studentMath.GetMethod('Stretch').CreateDelegate([Func[float[],int,float[]]])
    $gainPcm=$studentMath.GetMethod('Gain').CreateDelegate([Func[float[],float,float[]]])
    $pcmStats=$studentMath.GetMethod('PcmStats').CreateDelegate([Func[float[],double[]]])
    $testPcm=$pcm16.Invoke([float[]]@(-2,-1,0,0.5,1,2))
    if(-not [Linq.Enumerable]::SequenceEqual[short]($testPcm,[short[]]@(-32768,-32768,0,16384,32767,32767))){throw 'PCM16 saturation check failed.'}
    $sourcePath=Join-Path $root 'tools/Invoke-KokoroPrecomputedDecoder.ps1'
    $sourceHash=(Get-FileHash $sourcePath).Hash
    if($sourceHash -cne '8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257'){throw 'Offline reference source differs.'}
    $dll=Join-Path $root "build/precomputed-decoder-reopen-20261014/final-artifact-gate/$sourceHash/Kokoro.OfflineRender.dll"
    $dllHash=(Get-FileHash $dll).Hash
    if($dllHash -cne '446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D'){throw 'Offline reference assembly differs.'}
    $assembly=[Reflection.Assembly]::LoadFrom($dll);$mathType=$assembly.GetType('OfflineRenderMath',$true)
    $workerType=$assembly.GetType('OfflineConvolutionWorker',$true)
    $delegateTypes=@{
        FrameIndices=[Func[int,int,int,int,int,int,bool,int[]]];PackInputs=[Func[float[],int[],int,int,int,int,System.Runtime.Intrinsics.Vector128[float][]]]
        ActiveIndices=[Func[int[],int,bool[]]];FoldWeights=[Func[float[],float[],float[]]];Align=[Func[float[],int[],float[]]]
        AdaIn=[Func[float[],int,int,float[],float[],float[],float[],float[],float[]]];Leaky=[Func[float[],float,float[]]]
        Residual=[Func[float[],float[],float,float[]]];Nearest2=[Func[float[],int,int,float[]]];Snake=[Func[float[],float[],int,float[]]]
        Average3=[Func[float[],float[],float[],float[]]];ReflectLeft=[Func[float[],int,int,float[]]];Draws=[Func[int,int,float[]]]
        Harmonic=[Func[float[],float[],float[],float[],float[],float[],float[]]];Stft=[Func[float[],float[]]];InverseStft=[Func[float[],int,float[]]]
        Compare=[Func[float[],float[],double[]]];MeasureLevels=[Func[float[],int,int,int[],double[]]];ScaleFrames=[Func[int[],int,int[]]]
        ApplyLevels=[Func[float[],int,int,float[],float[],float[],float[],float[],double[],float[]]]
    }
    foreach($delegateName in $delegateTypes.Keys){Set-Variable -Name $delegateName -Value ($mathType.GetMethod($delegateName).CreateDelegate($delegateTypes[$delegateName]))}
    $experiment=$assembly.GetType('OfflineExperimentMath',$true)
    $encoderSlice=$experiment.GetMethod('EncoderSlice').CreateDelegate([Func[short[],float[],int,int,int,float[]]])
    $halfSlice=$experiment.GetMethod('HalfSlice').CreateDelegate([Func[ushort[],int,int,float[]]])
    $durationsSlice=$experiment.GetMethod('Durations').CreateDelegate([Func[short[],int,int,int[]]])
    $offsetsFor=$experiment.GetMethod('Offsets').CreateDelegate([Func[int[],int[]]])
    $tokens=$null;$parseErrors=$null
    $referenceAst=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Offline source parse failed.'}
    foreach($functionName in 'Read-OfflineWeight','Get-OfflineConvolution','Invoke-OfflineConv','Invoke-OfflineAdaIn','Join-OfflineChannels','Invoke-OfflineDecoderBlock','Invoke-OfflineDecoder','Invoke-OfflineGeneratorBlock','Invoke-OfflineGenerator','New-OfflineDraws'){
        $definition=$referenceAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName},$false)
        if($null -eq $definition){throw "Missing reference function $functionName"}
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function Test-OfflineNode([string]$Name,[float[]]$Values) {}
    $Mode='Gate';$Seed=17;$levelContext=$null
    $profile=[Collections.Generic.List[object]]::new()
    $weightCache=[Collections.Generic.Dictionary[string,float[]]]::new([StringComparer]::Ordinal)
    $convolutionCache=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $torch=Import-Module (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1') -PassThru
    $reader=$torch.Invoke({[pscustomobject]@{Read=$read;Bytes=$bytes;ReadTensor=$readTensor;TensorRow=$tensorRow}})[0]
    $modelRoot=Join-Path $root 'build/inputs/kokoro/f3ff3571791e39611d31c381e3a41a3af07b4987'
    $modelPath=Join-Path $modelRoot 'kokoro-v1_0.pth'
    if((Get-FileHash $modelPath).Hash -cne '496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4'){throw 'Checkpoint integrity differs.'}
    $checkpoint=& $reader.Read $modelPath
    $voiceArchive=& $reader.ReadTensor (Join-Path $modelRoot 'voices/af_heart.pt') '0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF'
    $rowBytes=& $reader.TensorRow $voiceArchive 25;$style=[float[]]::new(128);[Buffer]::BlockCopy($rowBytes,0,$style,0,512)
    $measurement=Import-Clixml (Join-Path $MeasurementDirectory 'structure.clixml')
    $orderPath=Join-Path $BankPath 'order.json'
    if((Get-FileHash $orderPath).Hash -cne $measurement.OrderSHA256 -or $measurement.Units -ne 2429833 -or $measurement.K -ne 4){throw 'Full-bank measurement identity differs.'}
    $nearestPath=Join-Path $MeasurementDirectory 'nearest.i32'
    if((Get-FileHash $nearestPath).Hash -cne '70DFD110F8B8E2A8EBDFC2507357727F04BAB0E2A974E51E340E1A9EE8D914AA'){throw 'Measured nearest IDs differ.'}
    $nearestRaw=[IO.File]::ReadAllBytes($nearestPath);$nearest=[int[]]::new($nearestRaw.Length/4);[Buffer]::BlockCopy($nearestRaw,0,$nearest,0,$nearestRaw.Length)
    $sentences=@(Get-Content -LiteralPath $orderPath -Raw | ConvertFrom-Json)
    $prefix=[int[]]::new($sentences.Count+1)
    for($sentence=0;$sentence -lt $sentences.Count;$sentence++){$prefix[$sentence+1]=$prefix[$sentence]+$sentences[$sentence].phonemes.Length+2}
    if($prefix[$sentences.Count] -ne $measurement.Units){throw 'Bank unit numbering differs.'}
    $selection=$SelectedUnits
    if($null -eq $selection){$selection=Import-Clixml (Join-Path $root 'build/precomputed-decoder-20261014/selection.clixml')}
    $needed=[Collections.Generic.HashSet[int]]::new();$chosen=[Collections.Generic.List[object]]::new()
    foreach($target in $Targets){
        $pick=$selection.picks[$target-1];$ids=[int[]]::new($pick.path.Count);$copyIds=[int[]]::new($ids.Length)
        for($token=0;$token -lt $ids.Length;$token++){
            $unit=$pick.path[$token];$ids[$token]=$prefix[[int]$unit.s]+[int]$unit.i;$copyIds[$token]=$nearest[$ids[$token]*4]
            if($copyIds[$token] -lt 0 -or $copyIds[$token] -eq $ids[$token]){throw 'Missing other exemplar.'}
            [void]$needed.Add($ids[$token]);[void]$needed.Add($copyIds[$token])
        }
        $chosen.Add([pscustomobject]@{Target=$target;Text=$pick.text;OriginalIds=$ids;CopyIds=$copyIds})
    }
    $byChunk=[Collections.Generic.Dictionary[int,object]]::new()
    foreach($id in $needed){
        $sentence=[Array]::BinarySearch($prefix,$id);if($sentence -lt 0){$sentence=-$sentence-2}
        $chunk=[int][Math]::Floor($sentence/1000.0)
        if(-not $byChunk.ContainsKey($chunk)){$byChunk.Add($chunk,[Collections.Generic.List[object]]::new())}
        $byChunk[$chunk].Add([pscustomobject]@{Id=$id;Sentence=$sentence;Token=$id-$prefix[$sentence]})
    }
    $provenance=@(Import-Clixml (Join-Path $MeasurementDirectory 'bank-provenance.clixml'))
    $units=[Collections.Generic.Dictionary[int,object]]::new()
    foreach($chunk in @($byChunk.Keys | Sort-Object)){
        $chunkPath=Join-Path $BankPath ('chunk-{0:D4}.npz' -f $chunk)
        $pin=@($provenance | Where-Object { [IO.Path]::GetFileName($_.Path) -ceq [IO.Path]::GetFileName($chunkPath) })
        if($pin.Count -ne 1 -or (Get-FileHash $chunkPath).Hash -cne $pin[0].SHA256){throw 'Bank chunk differs from measurement.'}
        Write-Host "Student COPY: reading chunk $chunk"
        $zip=[IO.Compression.ZipFile]::OpenRead($chunkPath)
        try {
            $encoded=Read-KokoroStudentNpy $zip t_en '<i2' ([short]);$scales=Read-KokoroStudentNpy $zip scale '<f4' ([float])
            $tokenOffsets=Read-KokoroStudentNpy $zip tok_off '<i8' ([long]);$frameOffsets=Read-KokoroStudentNpy $zip frm_off '<i8' ([long])
            $bankDurations=Read-KokoroStudentNpy $zip dur '<i2' ([short]);$pitchCodes=Read-KokoroStudentNpy $zip f0 '<f2' ([ushort]);$energyCodes=Read-KokoroStudentNpy $zip n '<f2' ([ushort])
            $allTokens=[int]($encoded.Length/512)
            foreach($record in $byChunk[$chunk]){
                $local=$record.Sentence%1000;$first=[int]$tokenOffsets[$local];$count=$prefix[$record.Sentence+1]-$prefix[$record.Sentence]
                $lengths=$durationsSlice.Invoke($bankDurations,$first,$count);$offsets=$offsetsFor.Invoke($lengths)
                $duration=$lengths[$record.Token];$frameFirst=[int](2*($frameOffsets[$local]+$offsets[$record.Token]))
                $units.Add($record.Id,[pscustomobject]@{Features=$encoderSlice.Invoke($encoded,$scales,$allTokens,$first+$record.Token,1);Duration=$duration;
                    Pitch=$halfSlice.Invoke($pitchCodes,$frameFirst,2*$duration);Energy=$halfSlice.Invoke($energyCodes,$frameFirst,2*$duration)})
            }
        } finally {$zip.Dispose()}
    }
    $chosen.ToArray() | Export-Clixml -LiteralPath (Join-Path $out 'copy-programs.clixml')
    $results=[Collections.Generic.List[object]]::new()
    foreach($case in $chosen){
        $tokenCount=$case.OriginalIds.Length;$originalEncoder=[float[]]::new(512*$tokenCount);$copyEncoder=[float[]]::new($originalEncoder.Length)
        $tokenDurations=[int[]]::new($tokenCount);$frameCount=0
        $originalTicks=0;$scaledTicks=0
        for($token=0;$token -lt $tokenCount;$token++){
            $originalTicks+=$units[$case.OriginalIds[$token]].Duration
            $nextTick=[int][Math]::Max($scaledTicks+1,[Math]::Round($originalTicks*$DurationScale))
            $tokenDurations[$token]=$nextTick-$scaledTicks;$scaledTicks=$nextTick;$frameCount+=2*$tokenDurations[$token]
        }
        if($null -ne $TokenFrames){
            foreach($keyIndex in $TokenFrames.Keys){
                $tokenIndex=[int]$keyIndex;$overrideFrames=[int]$TokenFrames[$keyIndex]
                if($tokenIndex -lt 0 -or $tokenIndex -ge $tokenCount -or $overrideFrames -lt 2 -or $overrideFrames -gt 800 -or $overrideFrames%2){throw 'TokenFrames requires valid token indices and even 300-sample frame counts from 2 through 800.'}
                $frameCount+=$overrideFrames-2*$tokenDurations[$tokenIndex];$tokenDurations[$tokenIndex]=[int]($overrideFrames/2)
            }
        }
        $pitch=[float[]]::new($frameCount);$energyCurve=[float[]]::new($frameCount);$frameAt=0
        for($token=0;$token -lt $tokenCount;$token++){
            $originalUnit=$units[$case.OriginalIds[$token]];$copyUnit=$units[$case.CopyIds[$token]]
            $candidateFeatures=$copyUnit.Features
            if($null -ne $ReplayVectors){if(-not $ReplayVectors.ContainsKey($case.OriginalIds[$token])){throw 'Missing selected student replay.'};$candidateFeatures=$ReplayVectors[$case.OriginalIds[$token]]}
            for($channel=0;$channel -lt 512;$channel++){$originalEncoder[$channel*$tokenCount+$token]=$originalUnit.Features[$channel];$copyEncoder[$channel*$tokenCount+$token]=$candidateFeatures[$channel]}
            $count=2*$tokenDurations[$token];$unitPitch=$originalUnit.Pitch;$unitEnergy=$originalUnit.Energy
            if($count -ne $unitPitch.Length){$unitPitch=$stretch.Invoke($unitPitch,$count);$unitEnergy=$stretch.Invoke($unitEnergy,$count)}
            [Array]::Copy($unitPitch,0,$pitch,$frameAt,$count);[Array]::Copy($unitEnergy,0,$energyCurve,$frameAt,$count);$frameAt+=$count
        }
        $random=New-OfflineDraws ($frameCount*300);$rendered=[Collections.Generic.List[object]]::new()
        $variants=@('original','copy');if($OnlyCandidate){$variants=@('copy')}
        foreach($variant in $variants){
            Write-Host "Student render target $($case.Target): $variant, $frameCount frames"
            $profile.Clear();$watch=[Diagnostics.Stopwatch]::StartNew()
            $encoder=if($variant -ceq 'original'){$originalEncoder}else{$copyEncoder}
            $decoded=Invoke-OfflineDecoder ($align.Invoke($encoder,$tokenDurations)) $pitch $energyCurve $style -TokenDurations $tokenDurations
            $pcm=Invoke-OfflineGenerator $decoded.Features $style $pitch $random.Uniform $random.Harmonic $random.Extra
            $watch.Stop();if($pcm.Length -ne $frameCount*300){throw 'Rendered PCM extent differs.'}
            if($Intensity -ne [float]1){$pcm=$gainPcm.Invoke($pcm,$Intensity)}
            $stats=$pcmStats.Invoke($pcm)
            $fileVariant=$variant;if($null -ne $ReplayVectors -and $variant -ceq 'copy'){$fileVariant='student'}
            $codes=$pcm16.Invoke($pcm);$path=Join-Path $out ('{0:D2}-{1}.wav' -f $case.Target,$fileVariant)
            Write-KokoroStudentWave $path $codes
            $rendered.Add([pscustomobject]@{Pcm=$pcm;Codes=$codes;Milliseconds=$watch.Elapsed.TotalMilliseconds;Path=$path;SHA256=(Get-FileHash $path).Hash;Peak=$stats[0];ClippedSamples=$stats[1]})
        }
        if($OnlyCandidate){
            $single=$rendered[0];$seconds=$frameCount/80.0
            $result=[pscustomobject]@{PSTypeName='Kokoro.Student.Render';Text=$case.Text;Path=$single.Path;SHA256=$single.SHA256;AudioSeconds=$seconds;OutputGain=$Intensity;DurationScale=$DurationScale;
                TokenFrames=$TokenFrames;Peak=$single.Peak;ClippedSamples=$single.ClippedSamples;HostMilliseconds=$single.Milliseconds;HostMsPerAudioSecond=$single.Milliseconds/$seconds;StudentKernelSHA256=$kernel.SHA256;ReferenceKernelSHA256=$dllHash;
                Scope='Student feature replay with inherited selected-unit F0/N and existing offline live AdaIN/source/generator; output gain and duration stretch are explicit controls, not learned expression';
                TimingDifference='Windows offline FP32 decoder/source/generator, single host run; unlike old SM8550 int8 generator ~40 ms/audio-s (preserved separate 41.918118, combined 46.867294).'}
            $results.Add($result);$results.ToArray()|Export-Clixml -LiteralPath (Join-Path $out 'student-render.clixml');continue
        }
        $floatMetrics=$compare.Invoke($rendered[1].Pcm,$rendered[0].Pcm)
        $pcmMetrics=$compare.Invoke($pcmFloat.Invoke($rendered[1].Codes),$pcmFloat.Invoke($rendered[0].Codes))
        $pair=[short[]]::new(2*$rendered[0].Codes.Length+14400)
        [Array]::Copy($rendered[0].Codes,0,$pair,0,$rendered[0].Codes.Length);[Array]::Copy($rendered[1].Codes,0,$pair,$rendered[0].Codes.Length+14400,$rendered[1].Codes.Length)
        $pairLabel='copy';if($null -ne $ReplayVectors){$pairLabel='student'}
        $pairPath=Join-Path $out ('{0:D2}-original-then-{1}.wav' -f $case.Target,$pairLabel);Write-KokoroStudentWave $pairPath $pair
        $seconds=$frameCount/80.0
        $result=[pscustomobject]@{Target=$case.Target;Text=$case.Text;Tokens=$tokenCount;Frames=$frameCount;AudioSeconds=$seconds;FloatPcmSNR=$floatMetrics[0];Pcm16SNR=$pcmMetrics[0];PeakError=$floatMetrics[1];
            OriginalMs=$rendered[0].Milliseconds;CopyMs=$rendered[1].Milliseconds;OriginalMsPerAudioSecond=$rendered[0].Milliseconds/$seconds;CopyMsPerAudioSecond=$rendered[1].Milliseconds/$seconds;
            PairPath=$pairPath;PairSHA256=(Get-FileHash $pairPath).Hash;OriginalSHA256=$rendered[0].SHA256;CopySHA256=$rendered[1].SHA256;
            ReferenceSourceSHA256=$sourceHash;ReferenceKernelSHA256=$dllHash;StudentKernelSHA256=$kernel.SHA256;Threads=$Threads;Seed=$Seed;VoiceRow=25;
            ReferenceKind='Selected-bank feature reconstruction; not untouched stock fresh-text synthesis';
            Scope=$(if($null -eq $ReplayVectors){'Windows offline FP32 whole selected target decoder plus source/generator; live AdaIN, matched original durations/F0/N/style/noise; COPY only, no RESIDUAL'}else{'Windows offline FP32 original selected features versus student native opcode replay; matched durations/F0/N/style/noise, live AdaIN, gain and duration controls'});
            TimingDifference='Single offline host runs, original first; unlike SM8550 int8 DSP generator-only timing. Historical approximate reference 40 ms/audio-second, separate preserved run 41.918118, combined 46.867294.'}
        $results.Add($result);$results.ToArray() | Export-Clixml -LiteralPath (Join-Path $out 'copy-render.clixml')
        Write-Host "Student COPY target $($case.Target): PCM SNR $($result.Pcm16SNR) dB; $pairPath"
    }
    return $results.ToArray()
}

function Get-KokoroStudentCodec {
    param($Kernel)
    $codecType=$Kernel.Assembly.GetType('KokoroStudentCodec',$true)
    [pscustomobject]@{
        Replay=$codecType.GetMethod('Replay').CreateDelegate([Func[byte[],short[],float[],float[],float[],object]])
        Pack=$codecType.GetMethod('PackLibrary').CreateDelegate([Func[float[],float[],short[]]])
        WriteLibrary=$codecType.GetMethod('WriteLibrary').CreateDelegate([Action[string,short[]]])
        CopyPrograms=$codecType.GetMethod('CopyPrograms').CreateDelegate([Func[int[],int,byte[]]])
    }
}

function Test-KokoroStudentReplay {
    param($Codec,[string]$Directory)
    $key=[float[]]::new(512);[Array]::Fill($key,[float]0.25)
    $library=[short[]]::new(1024);$library[0]=4;$library[1]=-8;$library[512]=12
    $direction=[float[]]::new(512);$direction[0]=[float]0.5
    $memory=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($memory)
    $writer.Write([byte]1);$writer.Write([int]0);$writer.Write([byte]2);$writer.Write([int]0)
    $writer.Write([byte]3);$writer.Write([byte]0);$writer.Write([ushort]1);$writer.Write([ushort]1);$writer.Write([short]2)
    $writer.Write([byte]4);$writer.Write([uint]9);$writer.Flush();$program=$memory.ToArray();$writer.Dispose();$memory.Dispose()
    $actual=$Codec.Replay.Invoke($program,$library,$key,$direction,[float[]]::new(0))
    if($actual.Values[0] -ne 1.5 -or $actual.Values[1] -ne -1.5 -or $actual.Flags -ne 9){throw 'Opcode replay fixture differs.'}
    $again=$Codec.Replay.Invoke($program,$library,$key,$direction,[float[]]::new(0))
    if(-not [Linq.Enumerable]::SequenceEqual[float]($actual.Values,$again.Values) -or $again.Flags -ne $actual.Flags){throw 'Opcode replay is not deterministic.'}
    $previous=$Codec.Replay.Invoke([byte[]]@(1,255,255,255,255,2,0,0,0,0),$library,$key,$direction,$actual.Values)
    if($previous.Values[0] -ne 2 -or $previous.Values[1] -ne -1.5){throw 'COPY previous plus DIRECTION failed.'}
    $rejected=0
    foreach($bad in @([byte[]]@(1,0),[byte[]]@(1,2,0,0,0),[byte[]]@(1,255,255,255,255),[byte[]]@(1,0,0,0,0,3,0,1,0,0,2,1,0),[byte[]]@(1,0,0,0,0,2,1,0,0,0),[byte[]]@(99))){
        try{$null=$Codec.Replay.Invoke($bad,$library,$key,$direction,[float[]]::new(0))}catch{$rejected++}
    }
    if($rejected -ne 6){throw 'Malformed opcode admission failed.'}
    $copies=$Codec.CopyPrograms.Invoke([int[]]@(1,0),1)
    if(-not [Linq.Enumerable]::SequenceEqual[byte]($copies,[byte[]]@(1,1,0,0,0,1,0,0,0,0))){throw 'Native COPY program encoding differs.'}
    if($Directory){[IO.File]::WriteAllBytes((Join-Path $Directory 'fixture-program.bin'),$program);$Codec.WriteLibrary.Invoke((Join-Path $Directory 'fixture-library.i16'),$library)}
    [pscustomobject]@{PSTypeName='Kokoro.Student.ReplayCheck';Passed=$true;MalformedRejected=$rejected;ProgramBytes=$program.Length}
}

function Write-KokoroStudentCopyPrograms {
    param($Codec,[string]$MeasurementDirectory,[string]$Directory)
    $path=Join-Path $MeasurementDirectory 'nearest.i32'
    if((Get-FileHash $path).Hash -cne '70DFD110F8B8E2A8EBDFC2507357727F04BAB0E2A974E51E340E1A9EE8D914AA'){throw 'COPY measurement identity differs.'}
    $raw=[IO.File]::ReadAllBytes($path);$nearest=[int[]]::new($raw.Length/4);[Buffer]::BlockCopy($raw,0,$nearest,0,$raw.Length)
    $programs=$Codec.CopyPrograms.Invoke($nearest,4);$programPath=Join-Path $Directory 'copy-programs.bin'
    if(Test-Path $programPath){throw 'COPY program output already exists.'}
    [IO.File]::WriteAllBytes($programPath,$programs)
    [pscustomobject]@{PSTypeName='Kokoro.Student.CopyPrograms';Path=$programPath;Bytes=$programs.Length;Stride=5;Units=$programs.Length/5;SHA256=(Get-FileHash $programPath).Hash}
}

function New-KokoroStudentReplayLibrary {
    [CmdletBinding()]
    param([string]$BankPath,[Parameter(Mandatory)][string]$OutputDirectory,[string]$MeasurementDirectory,[switch]$KernelOnly)
    $root=Split-Path -Parent $PSScriptRoot
    if(-not $BankPath){$BankPath=Join-Path $root 'build/unit-bank'}
    if(-not $MeasurementDirectory){$MeasurementDirectory=Join-Path $root 'build/student-20261015-full'}
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh student directory under build/.'}
    if(-not [BitConverter]::IsLittleEndian){throw 'Student native format requires little-endian host.'}
    [void][IO.Directory]::CreateDirectory($out);$kernel=Get-KokoroStudentKernel $out;$codec=Get-KokoroStudentCodec $kernel
    $script:StudentReplayKernel=[pscustomobject]@{Kernel=$kernel;Codec=$codec}
    $null=Test-KokoroStudentKernel $kernel;$check=Test-KokoroStudentReplay $codec $out
    if($KernelOnly){return $check}
    $measurement=Import-Clixml (Join-Path $MeasurementDirectory 'structure.clixml')
    if($measurement.Units -ne 2429833 -or $measurement.K -ne 4){throw 'Replay requires the complete measured bank.'}
    $bank=Read-KokoroStudentBank -BankPath $BankPath -Kernel $kernel
    $pins=@(Import-Clixml (Join-Path $MeasurementDirectory 'bank-provenance.clixml'))
    if($bank.OrderSHA256 -cne $measurement.OrderSHA256 -or $bank.Provenance.Count -ne $pins.Count){throw 'Replay bank identity differs.'}
    for($chunkIndex=0;$chunkIndex -lt $pins.Count;$chunkIndex++){if($bank.Provenance[$chunkIndex].SHA256 -cne $pins[$chunkIndex].SHA256){throw 'Replay source chunk differs.'}}
    # Select an existing channel key, the largest of the 44 observed chunk keys.
    # No averaging or fitting. One shared 512-channel voice key serves all tiles.
    $key=[float[]]::new(512)
    foreach($pin in $pins){
        $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $BankPath ([IO.Path]::GetFileName($pin.Path))))
        try{$scales=Read-KokoroStudentNpy $zip scale '<f4' ([float])}finally{$zip.Dispose()}
        if($scales.Length -ne 512){throw 'Voice key extent differs.'}
        for($channel=0;$channel -lt 512;$channel++){if($scales[$channel] -gt $key[$channel]){$key[$channel]=$scales[$channel]}}
    }
    Write-Host 'Student replay: packing real exemplars with the selected shared voice key'
    $watch=[Diagnostics.Stopwatch]::StartNew();$library=$codec.Pack.Invoke($bank.Vectors,$key);$watch.Stop()
    $libraryPath=Join-Path $out 'exemplars.i16';$codec.WriteLibrary.Invoke($libraryPath,$library)
    if((Get-Item $libraryPath).Length -ne 1024L*$bank.Count){throw 'Native library length differs.'}
    $directionPath=Join-Path $MeasurementDirectory 'directions.clixml'
    if((Get-FileHash $directionPath).Hash -cne '91D3EA0A704E810539B4C762A96AB2CBAF4D45FA45F8D3AC70AF03B07E2F04A2'){throw 'Measured medoid identity differs.'}
    $pairs=@(Import-Clixml $directionPath);$directionVectors=[float[]]::new(512*$pairs.Count)
    $pairIds=[int[]]::new($bank.Count);[Array]::Fill($pairIds,-1)
    for($pair=0;$pair -lt $pairs.Count;$pair++){
        $unit=[int]$pairs[$pair].MedoidUnit
        if($unit -lt 1 -or $bank.UnitSentences[$unit] -ne $bank.UnitSentences[$unit-1]){throw 'Medoid crosses source sentence.'}
        for($channel=0;$channel -lt 512;$channel++){$directionVectors[$pair*512+$channel]=[float]([double]$bank.Vectors[$unit*512+$channel]-[double]$bank.Vectors[($unit-1)*512+$channel])}
        foreach($occurrence in $bank.PairGroups[$pairs[$pair].Pair]){$pairIds[$occurrence]=$pair}
    }
    foreach($record in @(@('voice-key.f32',$key),@('directions.f32',$directionVectors),@('pair-ids.i32',$pairIds))){
        $raw=[byte[]]::new([Buffer]::ByteLength($record[1]));[Buffer]::BlockCopy($record[1],0,$raw,0,$raw.Length);[IO.File]::WriteAllBytes((Join-Path $out $record[0]),$raw)
    }
    $copyPrograms=Write-KokoroStudentCopyPrograms $codec $MeasurementDirectory $out
    $description=[pscustomobject]@{PSTypeName='Kokoro.Student.NativeLibrary';Version=1;ByteOrder='LittleEndian';Channels=512;Units=$bank.Count;DirectionPairs=$pairs.Count;CopyPrograms=$copyPrograms;
        LibraryPath=$libraryPath;LibrarySHA256=(Get-FileHash $libraryPath).Hash;KeyPath=(Join-Path $out 'voice-key.f32');DirectionsPath=(Join-Path $out 'directions.f32');PairIdsPath=(Join-Path $out 'pair-ids.i32');
        KeySHA256=(Get-FileHash (Join-Path $out 'voice-key.f32')).Hash;DirectionsSHA256=(Get-FileHash (Join-Path $out 'directions.f32')).Hash;PairIdsSHA256=(Get-FileHash (Join-Path $out 'pair-ids.i32')).Hash;
        Copy='01 i32 exemplar ID; -1 copies the immediately previous source-unit replay';Direction='02 i32 pair ID; adds the selected observed medoid direction';
        Residual='03 u8 shift u16 count; count*(u16 channel,i16 correction), correction*voice-key[channel]*2^-shift';Flags='04 u32 bits; OR into flags';
        ProgramEnd='Exact byte extent, no terminator';KeySelection='Per channel, largest real observed bank chunk key';LibraryBytes=1024L*$bank.Count;
        DirectionBytes=4L*$directionVectors.Length;KeyBytes=2048;PackingMilliseconds=$watch.Elapsed.TotalMilliseconds;KernelSHA256=$kernel.SHA256;ProgramKernelSHA256=$kernel.SHA256;OrderSHA256=$bank.OrderSHA256;Directory=$out}
    $description | Export-Clixml -LiteralPath (Join-Path $out 'native-library.clixml')
    $script:StudentReplayContext=[pscustomobject]@{Bank=$bank;Kernel=$kernel;Codec=$codec;Library=$library;Key=$key;Directions=$directionVectors;PairIds=$pairIds;Description=$description;MeasurementDirectory=$MeasurementDirectory}
    return $description
}

function Test-KokoroStudentClimber {
    param($Kernel,[string]$Directory)
    $workerType=$Kernel.Assembly.GetType('KokoroStudentClimber',$true)
    $codec=Get-KokoroStudentCodec $Kernel
    $key=[float[]]::new(512);[Array]::Fill($key,[float]0.01317)
    $source=[float[]]::new(8*512)
    for($unit=0;$unit -lt 8;$unit++){for($channel=0;$channel -lt 512;$channel++){$source[$unit*512+$channel]=[float](($unit*3+$channel%17+1)*0.01001)}}
    $library=$codec.Pack.Invoke($source,$key);$directions=[float[]]::new(512)
    for($channel=0;$channel -lt 512;$channel++){$directions[$channel]=[float]($source[512+$channel]-$source[$channel])}
    $nearest=[int[]]@(1,2,0,2,1,3,2,4,3,5,4,6,5,7,6,5)
    $rows=@(foreach($bar in 46,70){
        $out=Join-Path $Directory "fixture-$bar";[void][IO.Directory]::CreateDirectory($out)
        $worker=[Activator]::CreateInstance($workerType);$worker.Source=$source;$worker.Library=$library;$worker.VoiceKey=$key;$worker.Directions=$directions
        $worker.Nearest=$nearest;$worker.PairIds=[int[]]@( -1,0,0,0,0,0,0,0);$worker.Starts=[bool[]]@($true,$false,$false,$false,$true,$false,$false,$false)
        $worker.UsedExemplars=[bool[]]::new(8);$worker.UsedDirections=[bool[]]::new(1);$worker.First=0;$worker.UnitCount=8;$worker.K=2;$worker.Bar=$bar;$worker.Directory=$out
        $worker.Run()
        if($worker.Completed -ne 8 -or $worker.MinimumSNR -lt $bar -or $worker.ProgramBytes -gt $worker.InitialBytes -or $worker.Attempts -ne 32){throw 'Climber quality/count/size fixture failed.'}
        $journal=[IO.File]::ReadAllBytes((Join-Path $out 'journal.bin'))
        if($journal.Length -ne 32*$worker.Attempts){throw 'Climber journal extent differs.'}
        for($at=0;$at -lt $journal.Length;$at+=32){
            $mutation=[BitConverter]::ToInt32($journal,$at+4);$kept=[BitConverter]::ToInt32($journal,$at+24)
            if($mutation -ne 0 -and $kept -ne 0 -and ([BitConverter]::ToDouble($journal,$at+16) -lt $bar -or [BitConverter]::ToInt32($journal,$at+12) -ge [BitConverter]::ToInt32($journal,$at+28))){throw 'Climber kept a non-improving mutation.'}
        }
        [pscustomobject]@{Bar=$bar;Units=$worker.Completed;MinimumSNR=$worker.MinimumSNR;InitialBytes=$worker.InitialBytes;ProgramBytes=$worker.ProgramBytes;NoResidual=$worker.NoResidual;Attempts=$worker.Attempts;Accepted=$worker.Accepted}
    })
    $complete=$workerType.GetMethod('Complete').CreateDelegate([Func[byte[],float[],float[],float[],double,bool,object]])
    $largeBase=[float[]]::new(512);[Array]::Fill($largeBase,[float]1000000)
    $impossible=$complete.Invoke([byte[]]@(1,255,255,255,255,2,0,0,0,0),$largeBase,[float[]]::new(512),$key,0.00000001,$true)
    if($impossible.SquaredError -le 0.00000001){throw 'Unrepresentable direction mutation was admitted.'}
    $actual=$codec.Replay.Invoke($impossible.Program,$library,$key,$largeBase,[float[]]::new(512)).Values
    if(-not [Linq.Enumerable]::SequenceEqual[float]($actual,$impossible.Values)){throw 'Rejected candidate record differs from actual native replay.'}
    $readLibrary=$workerType.GetMethod('ReadLibrary').CreateDelegate([Func[string,int,short[]]])
    $readBack=$readLibrary.Invoke((Join-Path $Directory 'fixture-library.i16'),1024)
    if($readBack[0] -ne 4 -or $readBack[1] -ne -8 -or $readBack[512] -ne 12){throw 'Native library read fixture failed.'}
    $partitionWorkers=[Collections.Generic.List[object]]::new();$partitionTasks=[Collections.Generic.List[Threading.Tasks.Task]]::new()
    for($part=0;$part -lt 2;$part++){
        $worker=[Activator]::CreateInstance($workerType);$worker.Source=[float[]]::new(4*512);[Array]::Copy($source,$part*4*512,$worker.Source,0,$worker.Source.Length)
        $worker.Library=$library;$worker.VoiceKey=$key;$worker.Directions=$directions;$worker.Nearest=$nearest;$worker.PairIds=[int[]]@(-1,0,0,0,0,0,0,0)
        $worker.Starts=[bool[]]@($true,$false,$false,$false);$worker.UsedExemplars=[bool[]]::new(8);$worker.UsedDirections=[bool[]]::new(1);$worker.First=$part*4;$worker.UnitCount=4;$worker.K=2;$worker.Bar=70
        $worker.Directory=Join-Path $Directory "partition-$part";[void][IO.Directory]::CreateDirectory($worker.Directory)
        $partitionWorkers.Add($worker);$partitionTasks.Add([Threading.Tasks.Task]::Run($workerType.GetMethod('Run').CreateDelegate([Action],$worker)))
    }
    [Threading.Tasks.Task]::WaitAll($partitionTasks.ToArray())
    $joined=[IO.MemoryStream]::new()
    try{foreach($worker in $partitionWorkers){$raw=[IO.File]::ReadAllBytes((Join-Path $worker.Directory 'programs.bin'));$joined.Write($raw,0,$raw.Length)};$actual=$joined.ToArray()}finally{$joined.Dispose()}
    if(-not [Linq.Enumerable]::SequenceEqual[byte]($actual,[IO.File]::ReadAllBytes((Join-Path $Directory 'fixture-70/programs.bin')))){throw 'Parallel source-sentence partition changed programs.'}
    return $rows
}

function Read-KokoroStudentNative {
    param([string]$Path,[type]$Type,[int]$Width)
    $raw=[IO.File]::ReadAllBytes($Path)
    if($raw.Length%$Width){throw 'Native component is truncated.'}
    $values=[Array]::CreateInstance($Type,[int]($raw.Length/$Width));[Buffer]::BlockCopy($raw,0,$values,0,$raw.Length);return ,$values
}

function Invoke-KokoroStudentClimb {
    [CmdletBinding()]
    param([string]$BankPath,[Parameter(Mandatory)][string]$OutputDirectory,[string]$LibraryDirectory,[string]$MeasurementDirectory,[switch]$KernelOnly,[ValidateRange(0,44)][int]$ChunkLimit=0,
        [ValidateRange(2,64)][int]$Threads=4,[string]$ResumeDirectory)
    $root=Split-Path -Parent $PSScriptRoot
    if(-not $BankPath){$BankPath=Join-Path $root 'build/unit-bank'}
    if(-not $LibraryDirectory){$LibraryDirectory=Join-Path $root 'build/student-replay-full-20261015'}
    if(-not $MeasurementDirectory){$MeasurementDirectory=Join-Path $root 'build/student-20261015-full'}
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh student directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out);$kernel=Get-KokoroStudentKernel $out
    $null=Test-KokoroStudentKernel $kernel;$null=Test-KokoroStudentReplay (Get-KokoroStudentCodec $kernel) $out
    $fixtures=Test-KokoroStudentClimber $kernel $out
    if($KernelOnly){return $fixtures}
    $description=Import-Clixml (Join-Path $LibraryDirectory 'native-library.clixml')
    if($description.Units -ne 2429833 -or $description.Channels -ne 512 -or $description.ByteOrder -cne 'LittleEndian' -or -not [BitConverter]::IsLittleEndian){throw 'Native replay library identity differs.'}
    foreach($pin in @(@($description.LibraryPath,$description.LibrarySHA256),@($description.KeyPath,$description.KeySHA256),@($description.DirectionsPath,$description.DirectionsSHA256),@($description.PairIdsPath,$description.PairIdsSHA256))){if((Get-FileHash $pin[0]).Hash -cne $pin[1]){throw 'Native replay component differs.'}}
    $workerType=$kernel.Assembly.GetType('KokoroStudentClimber',$true)
    $readLibrary=$workerType.GetMethod('ReadLibrary').CreateDelegate([Func[string,int,short[]]])
    $library=$readLibrary.Invoke($description.LibraryPath,[int](512*$description.Units))
    $key=Read-KokoroStudentNative $description.KeyPath ([float]) 4;$directions=Read-KokoroStudentNative $description.DirectionsPath ([float]) 4;$pairIds=Read-KokoroStudentNative $description.PairIdsPath ([int]) 4
    $nearestPath=Join-Path $MeasurementDirectory 'nearest.i32'
    if((Get-FileHash $nearestPath).Hash -cne '70DFD110F8B8E2A8EBDFC2507357727F04BAB0E2A974E51E340E1A9EE8D914AA'){throw 'Climber candidates differ from measurement.'}
    $nearest=Read-KokoroStudentNative $nearestPath ([int]) 4
    $provenance=@(Import-Clixml (Join-Path $MeasurementDirectory 'bank-provenance.clixml'))
    if((Get-FileHash (Join-Path $BankPath 'order.json')).Hash -cne $description.OrderSHA256){throw 'Climber bank order differs.'}
    $usedCopies=@([bool[]]::new($description.Units),[bool[]]::new($description.Units));$usedPairs=@([bool[]]::new($description.DirectionPairs),[bool[]]::new($description.DirectionPairs))
    $rows=[Collections.Generic.List[object]]::new();$first=0;$startChunk=0;$watch=[Diagnostics.Stopwatch]::StartNew()
    if($ResumeDirectory){
        $savedRows=@(Import-Clixml (Join-Path $ResumeDirectory 'climb-chunks.clixml'))
        $oldKernelHash=(Get-FileHash (Join-Path $ResumeDirectory 'Kokoro.Student.dll')).Hash
        $mark=$kernel.Assembly.GetType('KokoroStudentStore',$true).GetMethod('Mark').CreateDelegate([Action[byte[],bool[],bool[]]])
        foreach($sourceChunk in @($savedRows.Chunk|Sort-Object -Unique)){
            if($sourceChunk -ne $startChunk){throw 'Resume chunks are not contiguous.'}
            foreach($bar in 46,70){
                $group=@($savedRows|Where-Object {$_.Chunk -eq $sourceChunk -and $_.Bar -eq $bar}|Sort-Object First)
                if([long](($group|Measure-Object Units -Sum).Sum) -ne $provenance[$sourceChunk].Units){throw 'Resume chunk is incomplete.'}
                $index=if($bar -eq 46){0}else{1}
                foreach($row in $group){
                    if($row.MinimumSNR -lt $bar){throw 'Resume row failed its quality bar.'}
                    $directory=Join-Path $out ('bar-{0}/chunk-{1:D4}-unit-{2:D7}' -f $bar,$sourceChunk,$row.First);[void][IO.Directory]::CreateDirectory($directory)
                    foreach($name in 'programs.bin','offsets.i64','journal.bin'){
                        $sourcePath=Join-Path $row.Directory $name;$targetPath=Join-Path $directory $name
                        [IO.File]::Copy($sourcePath,$targetPath,$false)
                        if((Get-FileHash $sourcePath).Hash -cne (Get-FileHash $targetPath).Hash){throw 'Resume copy SHA256 differs.'}
                    }
                    $programs=[IO.File]::ReadAllBytes((Join-Path $directory 'programs.bin'))
                    if($programs.Length -ne $row.ProgramBytes -or (Get-Item (Join-Path $directory 'offsets.i64')).Length -ne 8L*($row.Units+1)){throw 'Resume native extent differs.'}
                    $mark.Invoke($programs,$usedCopies[$index],$usedPairs[$index]);$row.Directory=$directory
                    $row|Add-Member NoteProperty KernelSHA256 $oldKernelHash -Force;$row|Add-Member NoteProperty Resumed $true -Force;$rows.Add($row)
                }
            }
            $first+=$provenance[$sourceChunk].Units;$startChunk++
        }
        $rows.ToArray()|Export-Clixml -LiteralPath (Join-Path $out 'climb-chunks.clixml')
        Write-Host "Student climb: resumed $startChunk complete source chunks, $first units per bar"
    }
    for($chunk=$startChunk;$chunk -lt $provenance.Count;$chunk++){
        if($ChunkLimit -gt 0 -and $chunk -ge $ChunkLimit){break}
        $path=Join-Path $BankPath ('chunk-{0:D4}.npz' -f $chunk)
        if((Get-FileHash $path).Hash -cne $provenance[$chunk].SHA256){throw 'Climber bank chunk differs.'}
        $zip=[IO.Compression.ZipFile]::OpenRead($path)
        try{$packed=Read-KokoroStudentNpy $zip t_en '<i2' ([short]);$scales=Read-KokoroStudentNpy $zip scale '<f4' ([float]);$offsets=Read-KokoroStudentNpy $zip tok_off '<i8' ([long])}finally{$zip.Dispose()}
        $count=[int]($packed.Length/512);$source=[float[]]::new($packed.Length);$energy=[double[]]::new($count);$kernel.Expand.Invoke($packed,$scales,$count,$source,0,$energy)
        $starts=[bool[]]::new($count);for($sentence=0;$sentence -lt $offsets.Length-1;$sentence++){$starts[[int]$offsets[$sentence]]=$true}
        $workers=[Collections.Generic.List[object]]::new();$tasks=[Collections.Generic.List[Threading.Tasks.Task]]::new()
        $parts=[Math]::Max(1,[int][Math]::Floor($Threads/2.0));$sentences=$offsets.Length-1
        for($index=0;$index -lt 2;$index++){
            $bar=if($index -eq 0){46}else{70}
            for($part=0;$part -lt $parts;$part++){
                $sentenceFirst=[int][Math]::Floor($part*$sentences/[double]$parts);$sentenceEnd=[int][Math]::Floor(($part+1)*$sentences/[double]$parts)
                $unitFirst=[int]$offsets[$sentenceFirst];$unitEnd=[int]$offsets[$sentenceEnd];$units=$unitEnd-$unitFirst;if($units -le 0){continue}
                $directory=Join-Path $out ('bar-{0}/chunk-{1:D4}-unit-{2:D7}' -f $bar,$chunk,($first+$unitFirst));[void][IO.Directory]::CreateDirectory($directory)
                $slice=[float[]]::new(512*$units);[Array]::Copy($source,512*$unitFirst,$slice,0,$slice.Length);$sliceStarts=[bool[]]::new($units);[Array]::Copy($starts,$unitFirst,$sliceStarts,0,$units)
                $worker=[Activator]::CreateInstance($workerType);$worker.Source=$slice;$worker.Library=$library;$worker.VoiceKey=$key;$worker.Directions=$directions;$worker.Nearest=$nearest;$worker.PairIds=$pairIds
                $worker.Starts=$sliceStarts;$worker.UsedExemplars=$usedCopies[$index];$worker.UsedDirections=$usedPairs[$index];$worker.First=$first+$unitFirst;$worker.UnitCount=$units;$worker.K=4;$worker.Bar=$bar;$worker.Directory=$directory
                $workers.Add($worker);$tasks.Add([Threading.Tasks.Task]::Run($workerType.GetMethod('Run').CreateDelegate([Action],$worker)))
            }
        }
        $milliseconds=Wait-KokoroStudentWorkers $workers.ToArray() $tasks.ToArray() "climb chunk $chunk"
        foreach($worker in $workers){
            $rows.Add([pscustomobject]@{Chunk=$chunk;Bar=$worker.Bar;First=$worker.First;Units=$worker.Completed;ProgramBytes=$worker.ProgramBytes;ResidualBytes=$worker.ResidualBytes;InitialBytes=$worker.InitialBytes;NoResidual=$worker.NoResidual;MinimumSNR=$worker.MinimumSNR;Attempts=$worker.Attempts;Accepted=$worker.Accepted;SharedBatchMilliseconds=$milliseconds;Directory=$worker.Directory;KernelSHA256=$kernel.SHA256;Resumed=$false})
            Write-Host "Student climb $($worker.Bar) dB chunk $chunk : $($worker.Completed) units, $($worker.NoResidual) without residual, $($worker.ProgramBytes) program bytes"
        }
        $first+=$count;$rows.ToArray() | Export-Clixml -LiteralPath (Join-Path $out 'climb-chunks.clixml')
    }
    $watch.Stop();$summaries=@(for($index=0;$index -lt 2;$index++){
        $bar=if($index -eq 0){46}else{70};$group=@($rows | Where-Object Bar -EQ $bar)
        $programBytes=[long](($group|Measure-Object ProgramBytes -Sum).Sum);$noResidual=[long](($group|Measure-Object NoResidual -Sum).Sum)
        $copyCount=0;foreach($used in $usedCopies[$index]){if($used){$copyCount++}};$directionCount=0;foreach($used in $usedPairs[$index]){if($used){$directionCount++}}
        foreach($mask in @(@("used-exemplars-$bar.u8",$usedCopies[$index]),@("used-directions-$bar.u8",$usedPairs[$index]))){$raw=[byte[]]::new($mask[1].Length);[Buffer]::BlockCopy($mask[1],0,$raw,0,$raw.Length);[IO.File]::WriteAllBytes((Join-Path $out $mask[0]),$raw)}
        [pscustomobject]@{PSTypeName='Kokoro.Student.Climb';Bar=$bar;Units=$first;CompleteBank=$first -eq $description.Units;NoResidual=$noResidual;NoResidualShare=$noResidual/[double]$first;ProgramBytes=$programBytes;
            ResidualBytes=[long](($group|Measure-Object ResidualBytes -Sum).Sum);
            InitialBytes=[long](($group|Measure-Object InitialBytes -Sum).Sum);OffsetBytes=8L*($first+$group.Count);ReferencedExemplars=$copyCount;ReferencedDirections=$directionCount;
            UnprunedCoreBytes=$programBytes+8L*($first+$group.Count)+$description.LibraryBytes+$description.DirectionBytes+$description.KeyBytes;
            MinimumFeatureSNR=($group|Measure-Object MinimumSNR -Minimum).Minimum;Attempts=[long](($group|Measure-Object Attempts -Sum).Sum);Accepted=[long](($group|Measure-Object Accepted -Sum).Sum);
            KernelSHA256=$kernel.SHA256;KernelHashes=@($rows.KernelSHA256|Sort-Object -Unique);Threads=$Threads;Directory=$out;BatchMilliseconds=$watch.Elapsed.TotalMilliseconds;BaselineUnits=$description.Units;BaselineInt16Bytes=1024L*$description.Units}
    })
    $summaries | Export-Clixml -LiteralPath (Join-Path $out 'climb.clixml')
    $script:StudentClimbContext=[pscustomobject]@{Kernel=$kernel;Library=$library;Key=$key;Directions=$directions;UsedCopies=$usedCopies;UsedPairs=$usedPairs;Rows=$rows;Summaries=$summaries;LibraryDescription=$description}
    return $summaries
}

function Get-KokoroStudentStore {
    param($Kernel)
    $type=$Kernel.Assembly.GetType('KokoroStudentStore',$true)
    [pscustomobject]@{Map=$type.GetMethod('Map').CreateDelegate([Func[byte[],int[]]]);
        Compact=$type.GetMethod('CompactLibrary').CreateDelegate([Func[short[],int[],string,long]]);
        Rewrite=$type.GetMethod('Rewrite').CreateDelegate([Func[byte[],int[],int[],byte[]]])}
}

function Test-KokoroStudentStore {
    param($Kernel,[string]$Directory)
    $store=Get-KokoroStudentStore $Kernel;$codec=Get-KokoroStudentCodec $Kernel
    $copyMap=$store.Map.Invoke([byte[]]@(1,0,1));$pairMap=$store.Map.Invoke([byte[]]@(0,1))
    if(-not [Linq.Enumerable]::SequenceEqual[int]($copyMap,[int[]]@(0,-1,1))){throw 'Compaction map fixture failed.'}
    $library=[short[]]::new(1536);$library[0]=2;$library[512]=5;$library[1024]=9
    $path=Join-Path $Directory 'fixture-compact.i16';$bytes=$store.Compact.Invoke($library,$copyMap,$path)
    if($bytes -ne 2048 -or (Get-Item $path).Length -ne $bytes){throw 'Compaction library extent fixture failed.'}
    $read=$Kernel.Assembly.GetType('KokoroStudentClimber',$true).GetMethod('ReadLibrary').CreateDelegate([Func[string,int,short[]]])
    $compact=$read.Invoke($path,1024);$key=[float[]]::new(512);[Array]::Fill($key,[float]1)
    $oldDirections=[float[]]::new(1024);$oldDirections[512]=-2;$newDirections=[float[]]::new(512);$newDirections[0]=-2
    $before=[byte[]]@(1,2,0,0,0);$after=$store.Rewrite.Invoke($before,$copyMap,$pairMap)
    $a=$codec.Replay.Invoke($before,$library,$key,$oldDirections,[float[]]::new(0));$b=$codec.Replay.Invoke($after,$compact,$key,$newDirections,[float[]]::new(0))
    if(-not [Linq.Enumerable]::SequenceEqual[float]($a.Values,$b.Values)){throw 'Compacted COPY changed replay.'}
    $before=[byte[]]@(1,255,255,255,255,2,1,0,0,0);$after=$store.Rewrite.Invoke($before,$copyMap,$pairMap)
    $a=$codec.Replay.Invoke($before,$library,$key,$oldDirections,$a.Values);$b=$codec.Replay.Invoke($after,$compact,$key,$newDirections,$b.Values)
    if(-not [Linq.Enumerable]::SequenceEqual[float]($a.Values,$b.Values) -or $b.Values[0] -ne 7){throw 'Compacted DIRECTION changed replay.'}
    $rejected=$false;try{$null=$store.Rewrite.Invoke([byte[]]@(1,1,0,0,0),$copyMap,$pairMap)}catch{$rejected=$true}
    if(-not $rejected){throw 'Missing compact exemplar was admitted.'}
    return $true
}

function Complete-KokoroStudentStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClimbDirectory,[Parameter(Mandatory)][string]$OutputDirectory,[string]$LibraryDirectory,[switch]$KernelOnly)
    $root=Split-Path -Parent $PSScriptRoot
    if(-not $LibraryDirectory){$LibraryDirectory=Join-Path $root 'build/student-replay-full-20261015'}
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh student directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out);$kernel=Get-KokoroStudentKernel $out
    $null=Test-KokoroStudentStore $kernel $out
    if($KernelOnly){return [pscustomobject]@{Passed=$true;KernelSHA256=$kernel.SHA256}}
    $description=Import-Clixml (Join-Path $LibraryDirectory 'native-library.clixml')
    foreach($pin in @(@($description.LibraryPath,$description.LibrarySHA256),@($description.KeyPath,$description.KeySHA256),@($description.DirectionsPath,$description.DirectionsSHA256))){if((Get-FileHash $pin[0]).Hash -cne $pin[1]){throw 'Compaction source library differs.'}}
    $summaries=@(Import-Clixml (Join-Path $ClimbDirectory 'climb.clixml'));$rows=@(Import-Clixml (Join-Path $ClimbDirectory 'climb-chunks.clixml'))
    if($summaries.Count -ne 2 -or @($summaries | Where-Object {-not $_.CompleteBank -or $_.Units -ne $description.Units}).Count){throw 'Compaction requires both complete full-bank bars.'}
    $store=Get-KokoroStudentStore $kernel
    $read=$kernel.Assembly.GetType('KokoroStudentClimber',$true).GetMethod('ReadLibrary').CreateDelegate([Func[string,int,short[]]])
    $library=$read.Invoke($description.LibraryPath,[int](512*$description.Units));$allDirections=Read-KokoroStudentNative $description.DirectionsPath ([float]) 4
    $results=@(foreach($summary in $summaries){
        $bar=[int]$summary.Bar;$directory=Join-Path $out "bar-$bar";[void][IO.Directory]::CreateDirectory($directory)
        $copyMap=$store.Map.Invoke([IO.File]::ReadAllBytes((Join-Path $ClimbDirectory "used-exemplars-$bar.u8")))
        $pairMap=$store.Map.Invoke([IO.File]::ReadAllBytes((Join-Path $ClimbDirectory "used-directions-$bar.u8")))
        if($copyMap.Length -ne $description.Units -or $pairMap.Length -ne $description.DirectionPairs){throw 'Compaction mask extent differs.'}
        $copyCount=0;foreach($mapped in $copyMap){if($mapped -ge 0){$copyCount++}}
        $pairCount=0;foreach($mapped in $pairMap){if($mapped -ge 0){$pairCount++}}
        if($copyCount -ne $summary.ReferencedExemplars -or $pairCount -ne $summary.ReferencedDirections){throw 'Compaction reference counts differ.'}
        $libraryPath=Join-Path $directory 'exemplars.i16';$libraryBytes=$store.Compact.Invoke($library,$copyMap,$libraryPath)
        $directions=[float[]]::new(512*$pairCount)
        for($pair=0;$pair -lt $pairMap.Length;$pair++){if($pairMap[$pair] -ge 0){[Array]::Copy($allDirections,$pair*512,$directions,$pairMap[$pair]*512,512)}}
        $directionPath=Join-Path $directory 'directions.f32';$raw=[byte[]]::new(4*$directions.Length);[Buffer]::BlockCopy($directions,0,$raw,0,$raw.Length);[IO.File]::WriteAllBytes($directionPath,$raw)
        $keyPath=Join-Path $directory 'voice-key.f32';[IO.File]::Copy($description.KeyPath,$keyPath,$false)
        $programBytes=0L;$offsetBytes=0L;$entries=[Collections.Generic.List[object]]::new()
        foreach($row in @($rows|Where-Object Bar -EQ $bar|Sort-Object Chunk)){
            $chunkDirectory=Join-Path $directory ('chunk-{0:D4}-unit-{1:D7}' -f $row.Chunk,$row.First);[void][IO.Directory]::CreateDirectory($chunkDirectory)
            $programPath=Join-Path $chunkDirectory 'programs.bin';$offsetPath=Join-Path $chunkDirectory 'offsets.i64'
            $rewritten=$store.Rewrite.Invoke([IO.File]::ReadAllBytes((Join-Path $row.Directory 'programs.bin')),$copyMap,$pairMap)
            if($rewritten.Length -ne $row.ProgramBytes){throw 'Compaction changed program extents.'}
            [IO.File]::WriteAllBytes($programPath,$rewritten);[IO.File]::Copy((Join-Path $row.Directory 'offsets.i64'),$offsetPath,$false)
            if((Get-Item $offsetPath).Length -ne 8L*($row.Units+1)){throw 'Compaction offset extent differs.'}
            $programBytes+=$rewritten.Length;$offsetBytes+=(Get-Item $offsetPath).Length
            $entries.Add([pscustomobject]@{Chunk=$row.Chunk;First=$row.First;Units=$row.Units;ProgramPath=$programPath;ProgramSHA256=(Get-FileHash $programPath).Hash;OffsetPath=$offsetPath;OffsetSHA256=(Get-FileHash $offsetPath).Hash})
        }
        if($programBytes -ne $summary.ProgramBytes -or $offsetBytes -ne $summary.OffsetBytes){throw 'Compact total program/index bytes differ.'}
        $manifest=[pscustomobject]@{PSTypeName='Kokoro.Student.CompactStore';Version=1;Bar=$bar;Units=$summary.Units;Exemplars=$copyCount;DirectionPairs=$pairCount;
            LibraryPath=$libraryPath;LibrarySHA256=(Get-FileHash $libraryPath).Hash;LibraryBytes=$libraryBytes;DirectionsPath=$directionPath;DirectionsSHA256=(Get-FileHash $directionPath).Hash;DirectionBytes=$raw.Length;
            KeyPath=$keyPath;KeySHA256=(Get-FileHash $keyPath).Hash;KeyBytes=(Get-Item $keyPath).Length;Chunks=$entries.ToArray();ProgramBytes=$programBytes;ResidualBytes=$summary.ResidualBytes;OffsetBytes=$offsetBytes;
            NoResidual=$summary.NoResidual;NoResidualShare=$summary.NoResidualShare;MinimumFeatureSNR=$summary.MinimumFeatureSNR;ClimbKernelSHA256=$summary.KernelSHA256;CompactionKernelSHA256=$kernel.SHA256;
            NativeBytes=$libraryBytes+$raw.Length+(Get-Item $keyPath).Length+$programBytes+$offsetBytes;Directory=$directory;SourceClimbDirectory=$ClimbDirectory}
        $manifestPath=Join-Path $directory 'compact-store.clixml';$manifest|Export-Clixml -LiteralPath $manifestPath
        [pscustomobject]@{Bar=$bar;StorePath=$manifestPath;NativeBytes=$manifest.NativeBytes;DescriptionBytes=(Get-Item $manifestPath).Length;TotalBytes=$manifest.NativeBytes+(Get-Item $manifestPath).Length;
            NoResidualShare=$summary.NoResidualShare;Exemplars=$copyCount;Directions=$pairCount;ManifestSHA256=(Get-FileHash $manifestPath).Hash}
    })
    $results|Export-Clixml -LiteralPath (Join-Path $out 'compact-stores.clixml');return $results
}

function New-KokoroStudentTextSelection {
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$OutputDirectory,[ValidateRange(100,1000000)][int]$SelectionSentences=1000000,
        [string]$DriverDirectory,[string]$DriverSHA256)
    Set-StrictMode -Off
    $root=Split-Path -Parent $PSScriptRoot;$out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh student directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    if(-not $DriverDirectory){
        if($DriverSHA256){throw 'A driver SHA256 override requires its directory.'}
        $DriverDirectory=Join-Path $root 'build/phonemizer/english/driver/D7B06FD52B900130E8702544D14BE2F662EC2E009EFCE6B33E3FC92BE8B70AD1-library-dll'
        $DriverSHA256='112DC0B565042184DF74FA5176F09F6E8294857693B44F0BBED456A43B3FEEF1'
    }
    if($DriverSHA256 -cnotmatch '^[A-F0-9]{64}$'){throw 'An explicitly selected driver requires its SHA256 pin.'}
    $DriverDirectory=[IO.Path]::GetFullPath($DriverDirectory)
    if(-not $DriverDirectory.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Student drivers must be project build artifacts.'}
    $driverReceipt=Import-PowerShellDataFile (Join-Path $DriverDirectory 'driver-receipt.psd1')
    $driverPath=[IO.Path]::GetFullPath($driverReceipt.Output)
    if([IO.Path]::GetDirectoryName($driverPath) -cne $DriverDirectory -or (Get-FileHash $driverPath).Hash -cne $DriverSHA256 -or $driverReceipt.AssemblySha256 -cne $DriverSHA256){throw 'Selected phonemizer driver differs.'}
    $driverAssembly=[Reflection.Assembly]::LoadFrom($driverPath)
    $run=$driverAssembly.GetType('CoreDriver',$true).GetMethod('Run').CreateDelegate([Func[string,object]])
    $pronunciation=$run.Invoke($Text)
    if(-not $pronunciation.Complete -or -not $pronunciation.KokoroPhones){throw 'Phonemizer could not complete the requested line.'}
    $held=@([pscustomobject]@{text=$Text;phonemes=$pronunciation.KokoroPhones})
    $Sizes=[int[]]@($SelectionSentences);$K=40
    if(-not $env:KOKORO_NOTES){throw 'Set KOKORO_NOTES to the project notes folder (Invoke-KokoroDevelopment.ps1 sets it).'}
    $minePath=Join-Path $env:KOKORO_NOTES 'reference/unit-bank/mine.ps1'
    if((Get-FileHash $minePath).Hash -cne '293DA2E73F207595B2368F224FAC681157AC22BE28EB0913B1674F1093A274FA'){throw 'Existing selector source differs.'}
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($minePath,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Existing selector parse failed.'}
    $savedWeights=$env:KOKORO_TARGETW
    try {
        $env:KOKORO_TARGETW='4,1,0.5,4,8,2'
        foreach($statement in $ast.EndBlock.Statements){
            if($statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Left -is [Management.Automation.Language.VariableExpressionAst] -and $statement.Left.VariablePath.UserPath -ceq 'held'){continue}
            if(@($statement.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'ConvertTo-Json'},$true)).Count){continue}
            . ([scriptblock]::Create($statement.Extent.Text)) | Out-Host
        }
    } finally {$env:KOKORO_TARGETW=$savedWeights}
    $selection=$results[[string]$sent]
    if($selection.sentences -ne [Math]::Min($SelectionSentences,$order.Count) -or $selection.picks.Count -ne 1){throw 'Fresh selection is incomplete.'}
    $selection|Export-Clixml -LiteralPath (Join-Path $out 'selection.clixml')
    [pscustomobject]@{Text=$Text;Phonemes=$pronunciation.KokoroPhones;SelectionPath=(Join-Path $out 'selection.clixml');SelectorSHA256=(Get-FileHash $minePath).Hash;DriverSHA256=(Get-FileHash $driverPath).Hash;Directory=$out}
}

function New-KokoroStudentSelectedReplay {
    param([Collections.IDictionary]$Selection,[Parameter(Mandatory)][string]$OutputDirectory,[string]$LibraryDirectory,[int]$Bar=70)
    $root=Split-Path -Parent $PSScriptRoot
    if(-not $LibraryDirectory){$LibraryDirectory=Join-Path $root 'build/student-replay-full-20261015'}
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh student directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out);$kernel=Get-KokoroStudentKernel $out;$codec=Get-KokoroStudentCodec $kernel
    $description=Import-Clixml (Join-Path $LibraryDirectory 'native-library.clixml')
    foreach($pin in @(@($description.LibraryPath,$description.LibrarySHA256),@($description.KeyPath,$description.KeySHA256),@($description.DirectionsPath,$description.DirectionsSHA256),@($description.PairIdsPath,$description.PairIdsSHA256))){if((Get-FileHash $pin[0]).Hash -cne $pin[1]){throw 'Selected replay library differs.'}}
    $workerType=$kernel.Assembly.GetType('KokoroStudentClimber',$true)
    $read=$workerType.GetMethod('ReadLibrary').CreateDelegate([Func[string,int,short[]]])
    $library=$read.Invoke($description.LibraryPath,[int](512*$description.Units))
    $key=Read-KokoroStudentNative $description.KeyPath ([float]) 4;$directions=Read-KokoroStudentNative $description.DirectionsPath ([float]) 4;$pairIds=Read-KokoroStudentNative $description.PairIdsPath ([int]) 4
    $nearestPath=Join-Path $root 'build/student-20261015-full/nearest.i32'
    if((Get-FileHash $nearestPath).Hash -cne '70DFD110F8B8E2A8EBDFC2507357727F04BAB0E2A974E51E340E1A9EE8D914AA'){throw 'Selected replay candidates differ.'}
    $nearest=Read-KokoroStudentNative $nearestPath ([int]) 4
    $bankPath=Join-Path $root 'build/unit-bank';$orderPath=Join-Path $bankPath 'order.json'
    if((Get-FileHash $orderPath).Hash -cne $description.OrderSHA256){throw 'Selected replay bank order differs.'}
    $order=@(Get-Content $orderPath -Raw|ConvertFrom-Json);$prefix=[int[]]::new($order.Count+1)
    for($sentence=0;$sentence -lt $order.Count;$sentence++){$prefix[$sentence+1]=$prefix[$sentence]+$order[$sentence].phonemes.Length+2}
    $required=[Collections.Generic.HashSet[int]]::new();$donors=[Collections.Generic.HashSet[int]]::new()
    foreach($pick in $Selection.picks){foreach($unit in $pick.path){[void]$required.Add($prefix[[int]$unit.s]+[int]$unit.i);[void]$donors.Add([int]$unit.s)}}
    $provenance=@(Import-Clixml (Join-Path $root 'build/student-20261015-full/bank-provenance.clixml'))
    $unitMajor=$kernel.Assembly.GetType('KokoroStudentMath',$true).GetMethod('UnitMajor').CreateDelegate([Func[float[],int,float[]]])
    $referenceSource='8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257'
    $referencePath=Join-Path $root "build/precomputed-decoder-reopen-20261014/final-artifact-gate/$referenceSource/Kokoro.OfflineRender.dll"
    if((Get-FileHash $referencePath).Hash -cne '446FD867E60D8D21F267D9B372A6736D357E84DEF7B680609E8386CBE22D1F8D'){throw 'Selected replay reference differs.'}
    $reference=[Reflection.Assembly]::LoadFrom($referencePath)
    $encoderSlice=$reference.GetType('OfflineExperimentMath',$true).GetMethod('EncoderSlice').CreateDelegate([Func[short[],float[],int,int,int,float[]]])
    $replayed=[Collections.Generic.Dictionary[int,float[]]]::new();$usedCopies=[bool[]]::new($description.Units);$usedPairs=[bool[]]::new($description.DirectionPairs);$records=[Collections.Generic.List[object]]::new()
    $chunks=@($donors | ForEach-Object {[int][Math]::Floor($_/1000.0)} | Sort-Object -Unique)
    foreach($chunk in $chunks){
        $path=Join-Path $bankPath ('chunk-{0:D4}.npz' -f $chunk)
        if((Get-FileHash $path).Hash -cne $provenance[$chunk].SHA256){throw 'Selected replay source chunk differs.'}
        $zip=[IO.Compression.ZipFile]::OpenRead($path)
        try{$packed=Read-KokoroStudentNpy $zip t_en '<i2' ([short]);$scales=Read-KokoroStudentNpy $zip scale '<f4' ([float]);$offsets=Read-KokoroStudentNpy $zip tok_off '<i8' ([long])}finally{$zip.Dispose()}
        foreach($sentence in @($donors|Where-Object {[int][Math]::Floor($_/1000.0) -eq $chunk}|Sort-Object)){
            $count=$prefix[$sentence+1]-$prefix[$sentence];$source=$unitMajor.Invoke($encoderSlice.Invoke($packed,$scales,[int]($packed.Length/512),[int]$offsets[$sentence%1000],$count),$count)
            $directory=Join-Path $out "source-$sentence";[void][IO.Directory]::CreateDirectory($directory)
            $worker=[Activator]::CreateInstance($workerType);$worker.Source=$source;$worker.Library=$library;$worker.VoiceKey=$key;$worker.Directions=$directions;$worker.Nearest=$nearest;$worker.PairIds=$pairIds
            $worker.Starts=[bool[]]::new($count);$worker.Starts[0]=$true;$worker.UsedExemplars=$usedCopies;$worker.UsedDirections=$usedPairs;$worker.First=$prefix[$sentence];$worker.UnitCount=$count;$worker.K=4;$worker.Bar=$Bar;$worker.Directory=$directory
            $worker.Run();$programs=[IO.File]::ReadAllBytes((Join-Path $directory 'programs.bin'));$indices=Read-KokoroStudentNative (Join-Path $directory 'offsets.i64') ([long]) 8
            $previous=[float[]]::new(0)
            for($unit=0;$unit -lt $count;$unit++){
                $program=[byte[]]::new($indices[$unit+1]-$indices[$unit]);[Array]::Copy($programs,[int]$indices[$unit],$program,0,$program.Length)
                $previous=$codec.Replay.Invoke($program,$library,$key,$directions,$previous).Values
                $id=$prefix[$sentence]+$unit;if($required.Contains($id)){$replayed.Add($id,$previous)}
            }
            $records.Add([pscustomobject]@{Sentence=$sentence;Units=$count;MinimumFeatureSNR=$worker.MinimumSNR;ProgramBytes=$worker.ProgramBytes;Bar=$Bar})
            Write-Host "Selected student replay: source $sentence, $count units, minimum $($worker.MinimumSNR) dB"
        }
    }
    if($replayed.Count -ne $required.Count){throw 'Selected student replay is incomplete.'}
    $records.ToArray()|Export-Clixml -LiteralPath (Join-Path $out 'selected-replay.clixml')
    $script:StudentSelectedReplay=[pscustomobject]@{Vectors=$replayed;Records=$records.ToArray();Kernel=$kernel;Directory=$out}
    return $script:StudentSelectedReplay
}

function Read-KokoroStudentStoredReplay {
    param([Parameter(Mandatory)][Collections.IDictionary]$Selection,
        [Parameter(Mandatory)][string]$StoreDirectory,[Parameter(Mandatory)][string]$OutputDirectory)
    $root=Split-Path -Parent $PSScriptRoot;$out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Choose a fresh stored-replay directory under build/.'}
    $store=Import-Clixml (Join-Path $StoreDirectory 'compact-store.clixml')
    if($store.Units -ne 2429833 -or $store.Bar -ne 70 -or $store.MinimumFeatureSNR -lt 70){throw 'Listening gate requires the complete 70 dB compact store.'}
    foreach($pin in @(@($store.LibraryPath,$store.LibrarySHA256),@($store.KeyPath,$store.KeySHA256),@($store.DirectionsPath,$store.DirectionsSHA256))){if((Get-FileHash $pin[0]).Hash -cne $pin[1]){throw 'Stored replay library differs.'}}
    $orderPath=Join-Path $root 'build/unit-bank/order.json'
    if((Get-FileHash $orderPath).Hash -cne '6FB62AA7037808BAF9AA17D14AB0F5D5CD64B4733419B991EB3555C6C8983E64'){throw 'Stored replay bank order differs.'}
    $order=@(Get-Content $orderPath -Raw|ConvertFrom-Json);$prefix=[int[]]::new($order.Count+1)
    for($sentence=0;$sentence -lt $order.Count;$sentence++){$prefix[$sentence+1]=$prefix[$sentence]+$order[$sentence].phonemes.Length+2}
    $required=[Collections.Generic.HashSet[int]]::new();$donors=[Collections.Generic.HashSet[int]]::new()
    foreach($pick in $Selection.picks){foreach($unit in $pick.path){[void]$required.Add($prefix[[int]$unit.s]+[int]$unit.i);[void]$donors.Add([int]$unit.s)}}
    [void][IO.Directory]::CreateDirectory($out);$kernel=Get-KokoroStudentKernel $out
    $null=Test-KokoroStudentReplay (Get-KokoroStudentCodec $kernel) $out
    $codec=Get-KokoroStudentCodec $kernel
    $read=$kernel.Assembly.GetType('KokoroStudentClimber',$true).GetMethod('ReadLibrary').CreateDelegate([Func[string,int,short[]]])
    $library=$read.Invoke($store.LibraryPath,[int](512*$store.Exemplars))
    $key=Read-KokoroStudentNative $store.KeyPath ([float]) 4
    $directions=Read-KokoroStudentNative $store.DirectionsPath ([float]) 4
    $vectors=[Collections.Generic.Dictionary[int,float[]]]::new();$records=[Collections.Generic.List[object]]::new()
    foreach($chunk in @($store.Chunks|Sort-Object First)){
        $sentences=@($donors|Where-Object {$prefix[$_] -ge $chunk.First -and $prefix[$_] -lt $chunk.First+$chunk.Units}|Sort-Object)
        if(-not $sentences.Count){continue}
        if((Get-FileHash $chunk.ProgramPath).Hash -cne $chunk.ProgramSHA256 -or (Get-FileHash $chunk.OffsetPath).Hash -cne $chunk.OffsetSHA256){throw 'Stored replay program chunk differs.'}
        $programs=[IO.File]::ReadAllBytes($chunk.ProgramPath);$offsets=Read-KokoroStudentNative $chunk.OffsetPath ([long]) 8
        if($offsets.Length -ne $chunk.Units+1 -or $offsets[0] -ne 0 -or $offsets[-1] -ne $programs.Length){throw 'Stored replay offsets differ.'}
        foreach($sentence in $sentences){
            $first=$prefix[$sentence];$end=$prefix[$sentence+1]
            if($end -gt $chunk.First+$chunk.Units){throw 'Stored replay partition splits a source sentence.'}
            $previous=[float[]]::new(0)
            for($id=$first;$id -lt $end;$id++){
                $local=$id-$chunk.First;$start=$offsets[$local];$length=$offsets[$local+1]-$start
                if($start -lt 0 -or $length -lt 5 -or $start+$length -gt $programs.Length){throw 'Stored replay program extent differs.'}
                $program=[byte[]]::new($length);[Array]::Copy($programs,[int]$start,$program,0,$program.Length)
                $previous=$codec.Replay.Invoke($program,$library,$key,$directions,$previous).Values
                if($required.Contains($id)){$vectors.Add($id,$previous)}
            }
            $records.Add([pscustomobject]@{Sentence=$sentence;Units=$end-$first;ProgramSHA256=$chunk.ProgramSHA256;MinimumFeatureSNR=$store.MinimumFeatureSNR;Bar=$store.Bar})
        }
    }
    if($vectors.Count -ne $required.Count){throw 'Stored selected replay is incomplete.'}
    $records.ToArray()|Export-Clixml (Join-Path $out 'stored-replay.clixml')
    $script:StudentSelectedReplay=[pscustomobject]@{Vectors=$vectors;Records=$records.ToArray();Kernel=$kernel;Directory=$out;StoreDirectory=$StoreDirectory}
    return $script:StudentSelectedReplay
}

function Invoke-KokoroStudentStrokeBoundary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputDirectory,[ValidateRange(2,64)][int]$Threads=4,
        [ValidateRange(1,128)][int]$TrainingSentences=32)
    $root=Split-Path -Parent $PSScriptRoot;$out=[IO.Path]::GetFullPath($OutputDirectory)
    if(-not $out.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path $out)){throw 'Choose a fresh stroke experiment directory under build/.'}
    [void][IO.Directory]::CreateDirectory($out)
    # Reuse the existing renderer's reference bootstrap, not another model implementation.
    $bootstrap=(Get-Command Render-KokoroStudentCopy).ScriptBlock.Ast.Body.EndBlock.Statements
    $inside=$false;$executed=0
    foreach($statement in $bootstrap){
        $assignment=$statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Left -is [Management.Automation.Language.VariableExpressionAst]
        if($assignment -and $statement.Left.VariablePath.UserPath -ceq 'sourcePath'){$inside=$true}
        if($assignment -and $statement.Left.VariablePath.UserPath -ceq 'measurement'){break}
        if($inside){. ([scriptblock]::Create($statement.Extent.Text));$executed++}
    }
    if($executed -lt 20 -or $sourceHash -cne '8DAD8231FDCBF80C024E2C9C0A4D53FC7CE0E02D3415ABBE2FE73A1AB8E07257'){throw 'Reference bootstrap contract differs.'}
    function Test-OfflineNode([string]$Name,[float[]]$Values) {}
    $definition=$referenceAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-OfflineReference'},$false)
    . ([scriptblock]::Create($definition.Extent.Text));$InputRepository=$root
    $studentDll=Join-Path $root 'build/student-replay-nine-a-20261015/Kokoro.Student.dll'
    if((Get-FileHash $studentDll).Hash -cne 'EE4DD6FB9A55CDEFC1B781BA07E19AC9D91307CA911B620AA7D72D90ADB3B017'){throw 'Preserved PCM helpers differ.'}
    $studentType=[Reflection.Assembly]::LoadFrom($studentDll).GetType('KokoroStudentMath',$true)
    $pcm16=$studentType.GetMethod('Pcm16').CreateDelegate([Func[float[],short[]]])
    $finite=$studentType.GetMethod('PcmStats').CreateDelegate([Func[float[],double[]]])
    function Write-StrokeReferenceArray([string]$Name,[Array]$Values){
        $path=Join-Path $out $Name;if(Test-Path $path){throw 'Stroke reference artifact already exists.'}
        $raw=[byte[]]::new([Buffer]::ByteLength($Values));[Buffer]::BlockCopy($Values,0,$raw,0,$raw.Length)
        [IO.File]::WriteAllBytes($path,$raw)
        [pscustomobject]@{Path=$path;Bytes=$raw.Length;SHA256=(Get-FileHash $path).Hash}
    }
    $inputs=[Collections.Generic.List[object]]::new()
    $captures=Import-PowerShellDataFile (Join-Path $root 'build/score-capture-20261014/capture.psd1')
    foreach($capture in $captures.Cases){
        $inputs.Add([pscustomobject]@{Name=$capture.Name;Kind='IntactStockCapture';Training=$false;Text=$capture.Name;Phonemes=$capture.Phonemes;
            Encoded=(Read-OfflineReference $capture 'text-encoder');Durations=(Read-OfflineReference $capture 'durations');
            F0=(Read-OfflineReference $capture 'f0');N=(Read-OfflineReference $capture 'n');Style=(Read-OfflineReference $capture 'acoustic');VoiceRow=$capture.Row;
            Uniform=(Read-OfflineReference $capture 'draw0-rand');Harmonic=(Read-OfflineReference $capture 'draw1-randn_like');Extra=(Read-OfflineReference $capture 'draw2-randn_like');
            ExpectedPcm=(Read-OfflineReference $capture 'pcm');ExpectedWave=$null;SourceSentence=-1})
    }
    $selection=Import-Clixml (Join-Path $root 'build/precomputed-decoder-20261014/selection.clixml')
    $held=@(Get-Content (Join-Path $root 'build/precomputed-decoder-20261014/selection/heldout.json') -Raw|ConvertFrom-Json)
    $orderPath=Join-Path $root 'build/unit-bank/order.json'
    if((Get-FileHash $orderPath).Hash -cne '6FB62AA7037808BAF9AA17D14AB0F5D5CD64B4733419B991EB3555C6C8983E64'){throw 'Bank order differs.'}
    $order=@(Get-Content $orderPath -Raw|ConvertFrom-Json)
    $heldTexts=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($target in $held){[void]$heldTexts.Add($target.text)}
    $needed=[Collections.Generic.Dictionary[int,Collections.Generic.HashSet[int]]]::new()
    foreach($pick in $selection.picks){foreach($unit in $pick.path){
        $s=[int]$unit.s;if(-not $needed.ContainsKey($s)){$needed.Add($s,[Collections.Generic.HashSet[int]]::new())};[void]$needed[$s].Add([int]$unit.i)
    }}
    for($s=0;$s -lt $TrainingSentences;$s++){
        if($heldTexts.Contains($order[$s].text)){throw 'Training text overlaps a held-out sentence.'}
        if(-not $needed.ContainsKey($s)){$needed.Add($s,[Collections.Generic.HashSet[int]]::new())}
    }
    $provenance=@(Import-Clixml (Join-Path $root 'build/student-20261015-full/bank-provenance.clixml'))
    $units=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($chunk in @($needed.Keys|ForEach-Object {[int][Math]::Floor($_/1000.0)}|Sort-Object -Unique)){
        $path=Join-Path $root ('build/unit-bank/chunk-{0:D4}.npz' -f $chunk)
        if((Get-FileHash $path).Hash -cne $provenance[$chunk].SHA256){throw 'Source bank chunk differs.'}
        $zip=[IO.Compression.ZipFile]::OpenRead($path)
        try{
            $packed=Read-KokoroStudentNpy $zip t_en '<i2' ([short]);$scales=Read-KokoroStudentNpy $zip scale '<f4' ([float])
            $tokenOffsets=Read-KokoroStudentNpy $zip tok_off '<i8' ([long]);$frameOffsets=Read-KokoroStudentNpy $zip frm_off '<i8' ([long])
            $dur=Read-KokoroStudentNpy $zip dur '<i2' ([short]);$f0=Read-KokoroStudentNpy $zip f0 '<f2' ([ushort]);$noise=Read-KokoroStudentNpy $zip n '<f2' ([ushort])
            foreach($s in @($needed.Keys|Where-Object {[int][Math]::Floor($_/1000.0) -eq $chunk}|Sort-Object)){
                $local=$s%1000;$first=[int]$tokenOffsets[$local];$count=[int]($tokenOffsets[$local+1]-$tokenOffsets[$local])
                $lengths=$durationsSlice.Invoke($dur,$first,$count);$offsets=$offsetsFor.Invoke($lengths);$frames=2*$offsets[-1]
                if($s -lt $TrainingSentences){
                    $inputs.Add([pscustomobject]@{Name=('train-{0:D4}' -f $s);Kind='FixedIndependentTrainingSentence';Training=$true;Text=$order[$s].text;Phonemes=$order[$s].phonemes;
                        Encoded=$encoderSlice.Invoke($packed,$scales,[int]($packed.Length/512),$first,$count);Durations=$lengths;
                        F0=$halfSlice.Invoke($f0,[int](2*$frameOffsets[$local]),$frames);N=$halfSlice.Invoke($noise,[int](2*$frameOffsets[$local]),$frames);
                        Style=$style;VoiceRow=25;Uniform=$null;Harmonic=$null;Extra=$null;ExpectedPcm=$null;ExpectedWave=$null;SourceSentence=$s})
                }
                foreach($i in $needed[$s]){
                    $n=2*$lengths[$i];$f=[int](2*($frameOffsets[$local]+$offsets[$i]))
                    $units.Add("$s/$i",[pscustomobject]@{Feature=$encoderSlice.Invoke($packed,$scales,[int]($packed.Length/512),$first+$i,1);Duration=$lengths[$i];F0=$halfSlice.Invoke($f0,$f,$n);N=$halfSlice.Invoke($noise,$f,$n)})
                }
            }
        }finally{$zip.Dispose()}
        Write-Host "Stroke boundary: read source chunk $chunk"
    }
    $oldWaves=@(Import-Clixml (Join-Path $root 'build/student-copy-nine-20261015-r2/copy-render.clixml'))
    for($target=0;$target -lt 9;$target++){
        $pick=$selection.picks[$target];$count=$pick.path.Count
        if($count -ne $held[$target].phonemes.Length+2){throw 'Held-out alignment differs.'}
        $encoded=[float[]]::new(512*$count);$lengths=[int[]]::new($count);$f0List=[Collections.Generic.List[float]]::new();$nList=[Collections.Generic.List[float]]::new()
        for($i=0;$i -lt $count;$i++){
            $unit=$units[('{0}/{1}' -f $pick.path[$i].s,$pick.path[$i].i)];$lengths[$i]=$unit.Duration
            for($channel=0;$channel -lt 512;$channel++){$encoded[$channel*$count+$i]=$unit.Feature[$channel]}
            $f0List.AddRange($unit.F0);$nList.AddRange($unit.N)
        }
        $pitch=$f0List.ToArray();$random=New-OfflineDraws ($pitch.Length*300)
        $expected=Join-Path $root ('build/student-copy-nine-20261015-r2/{0:D2}-original.wav' -f ($target+1))
        if((Get-FileHash $expected).Hash -cne $oldWaves[$target].OriginalSHA256){throw 'Held-out reference WAV differs.'}
        $inputs.Add([pscustomobject]@{Name=('{0:D2}' -f ($target+1));Kind='ExistingSelectedBankReference';Training=$false;Text=$pick.text;Phonemes=$held[$target].phonemes;
            Encoded=$encoded;Durations=$lengths;F0=$pitch;N=$nList.ToArray();Style=$style;VoiceRow=25;
            Uniform=$random.Uniform;Harmonic=$random.Harmonic;Extra=$random.Extra;ExpectedPcm=$null;ExpectedWave=$expected;SourceSentence=-1})
    }
    $records=[Collections.Generic.List[object]]::new()
    foreach($inputCase in $inputs){
        foreach($array in @($inputCase.Encoded,$inputCase.F0,$inputCase.N,$inputCase.Style)){$null=$finite.Invoke($array)}
        $watch=[Diagnostics.Stopwatch]::StartNew();$decoded=Invoke-OfflineDecoder ($align.Invoke($inputCase.Encoded,$inputCase.Durations)) $inputCase.F0 $inputCase.N $inputCase.Style -TokenDurations $inputCase.Durations;$watch.Stop()
        $x=$decoded.Features;$null=$finite.Invoke($x);$frames=$inputCase.F0.Length
        if($x.Length -ne 512*$frames){throw 'Decoder/generator boundary shape differs.'}
        $record=[pscustomobject]@{Name=$inputCase.Name;Kind=$inputCase.Kind;Training=$inputCase.Training;Text=$inputCase.Text;Phonemes=$inputCase.Phonemes;SourceSentence=$inputCase.SourceSentence;
            Channels=512;Frames=$frames;Shape=[int[]]@(1,512,$frames);Precision='Float32';Ordering='ChannelMajor';FrameSamples=300;SampleRate=24000;Voice='af_heart';VoiceRow=$inputCase.VoiceRow;
            Features=(Write-StrokeReferenceArray ($inputCase.Name+'.features.f32') $x);F0=(Write-StrokeReferenceArray ($inputCase.Name+'.f0.f32') $inputCase.F0);
            Style=(Write-StrokeReferenceArray ($inputCase.Name+'.style.f32') $inputCase.Style);Durations=(Write-StrokeReferenceArray ($inputCase.Name+'.durations.i32') $inputCase.Durations);
            Uniform=$null;Harmonic=$null;Extra=$null;Pcm=$null;Wave=$null;DecoderMs=$watch.Elapsed.TotalMilliseconds;GeneratorMs=$null;ReferenceSNR=$null;ReferencePeakError=$null;BitExactPcm16=$null;
            ReferenceSourceSHA256=$sourceHash;ReferenceKernelSHA256=$dllHash;Controls='Frozen stock offline generator: internal live AdaIN and mathematical Snake; external F0/style/source draws matched'}
        if(-not $inputCase.Training){
            foreach($array in @($inputCase.Uniform,$inputCase.Harmonic,$inputCase.Extra)){$null=$finite.Invoke($array)}
            $record.Uniform=Write-StrokeReferenceArray ($inputCase.Name+'.uniform.f32') $inputCase.Uniform
            $record.Harmonic=Write-StrokeReferenceArray ($inputCase.Name+'.harmonic.f32') $inputCase.Harmonic
            $record.Extra=Write-StrokeReferenceArray ($inputCase.Name+'.extra.f32') $inputCase.Extra
            $watch.Restart();$pcm=Invoke-OfflineGenerator $x $inputCase.Style $inputCase.F0 $inputCase.Uniform $inputCase.Harmonic $inputCase.Extra;$watch.Stop();$record.GeneratorMs=$watch.Elapsed.TotalMilliseconds
            $null=$finite.Invoke($pcm);$codes=$pcm16.Invoke($pcm)
            if($null -ne $inputCase.ExpectedPcm){
                $metrics=$compare.Invoke($pcm,$inputCase.ExpectedPcm);$record.ReferenceSNR=$metrics[0];$record.ReferencePeakError=$metrics[1]
                if($metrics[0] -lt 80 -or $metrics[1] -gt 0.0001){throw 'STOP: required stock reference reproduction failed.'}
            }else{
                $raw=[IO.File]::ReadAllBytes($inputCase.ExpectedWave);$expectedCodes=[short[]]::new(($raw.Length-44)/2);[Buffer]::BlockCopy($raw,44,$expectedCodes,0,$raw.Length-44)
                $record.BitExactPcm16=[Linq.Enumerable]::SequenceEqual[short]($codes,$expectedCodes)
                if(-not $record.BitExactPcm16){throw 'STOP: required held-out reference reproduction failed.'}
            }
            $record.Pcm=Write-StrokeReferenceArray ($inputCase.Name+'.pcm.f32') $pcm
            $wave=Join-Path $out ($inputCase.Name+'.reference.wav');Write-KokoroStudentWave $wave $codes;$record.Wave=[pscustomobject]@{Path=$wave;SHA256=(Get-FileHash $wave).Hash;Bytes=(Get-Item $wave).Length}
        }
        $records.Add($record);$records.ToArray()|Export-Clixml (Join-Path $out 'boundary.clixml')
        Write-Host "Stroke boundary: $($record.Name), $frames frames, reference checked=$(!$record.Training)"
    }
    return $records.ToArray()
}

function Invoke-KokoroStudent {
    [CmdletBinding()]
    param([ValidateSet('Measure','Render','Replay','Climb','StrokeBoundary','Strokes')][string]$Step='Measure',[string]$BankPath,[Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateRange(1,64)][int]$Threads=4,[ValidateRange(1,16)][int]$K=4,[ValidateRange(0,1000000)][int]$SentenceLimit=0,
        [string]$MeasurementDirectory,[ValidateSet('CopyOnly')][string]$Replay='CopyOnly',[int[]]$Targets=(1..9),[switch]$KernelOnly,[string]$LibraryDirectory,[ValidateRange(0,44)][int]$ChunkLimit=0,[switch]$Finalize,[string]$ClimbDirectory,
        [string]$Text,[switch]$PrepareOnly,[Collections.IDictionary]$SelectedUnits=$null,[switch]$StudentReplay,[ValidateRange(0.25,4)][float]$Intensity=1,[ValidateRange(0.5,2)][double]$DurationScale=1,[ValidateRange(100,1000000)][int]$SelectionSentences=1000000,[switch]$ReuseReplay,[string]$ResumeDirectory,[switch]$CompareOriginal,[Collections.IDictionary]$TokenFrames=$null,[string]$DriverDirectory,[string]$DriverSHA256,[string]$StoreDirectory,[ValidateRange(1,128)][int]$TrainingSentences=32,[string]$Stage='Admit',[string]$ExperimentDirectory,[ValidateRange(16,4096)][int]$LibrarySize=1024,[string]$ReconstructionDirectory,[string[]]$CaseNames=@())
    switch($Step){
        'StrokeBoundary'{Invoke-KokoroStudentStrokeBoundary -OutputDirectory $OutputDirectory -Threads $Threads -TrainingSentences $TrainingSentences}
        'Strokes'{Import-Module (Join-Path $PSScriptRoot 'Kokoro.StudentStrokes.psm1');Invoke-KokoroStudentStrokes -Stage $Stage -ExperimentDirectory $ExperimentDirectory -OutputDirectory $OutputDirectory -LibrarySize $LibrarySize -Threads $Threads -LibraryDirectory $LibraryDirectory -ReconstructionDirectory $ReconstructionDirectory -CaseNames $CaseNames}
        'Measure'{Measure-KokoroStudentStructure -BankPath $BankPath -OutputDirectory $OutputDirectory -Threads $Threads -K $K -SentenceLimit $SentenceLimit}
        'Render'{
            if($PrepareOnly){New-KokoroStudentTextSelection -Text $Text -OutputDirectory $OutputDirectory -SelectionSentences $SelectionSentences -DriverDirectory $DriverDirectory -DriverSHA256 $DriverSHA256}
            elseif($StudentReplay){
                if($null -eq $SelectedUnits){$SelectedUnits=Import-Clixml (Join-Path (Split-Path -Parent $PSScriptRoot) 'build/precomputed-decoder-20261014/selection.clixml')}
                if($ReuseReplay){$state=$script:StudentSelectedReplay}
                elseif($StoreDirectory){$state=Read-KokoroStudentStoredReplay -Selection $SelectedUnits -StoreDirectory $StoreDirectory -OutputDirectory ($OutputDirectory+'-replay')}
                else{$state=New-KokoroStudentSelectedReplay -Selection $SelectedUnits -OutputDirectory ($OutputDirectory+'-replay') -LibraryDirectory $LibraryDirectory}
                Render-KokoroStudentCopy -BankPath $BankPath -OutputDirectory $OutputDirectory -MeasurementDirectory $MeasurementDirectory -Threads $Threads -Targets $Targets -SelectedUnits $SelectedUnits -ReplayVectors $state.Vectors -OnlyCandidate:(!$CompareOriginal) -Intensity $Intensity -DurationScale $DurationScale -TokenFrames $TokenFrames
            }
            else{Render-KokoroStudentCopy -BankPath $BankPath -OutputDirectory $OutputDirectory -MeasurementDirectory $MeasurementDirectory -Threads $Threads -Targets $Targets -SelectedUnits $SelectedUnits}
        }
        'Replay'{New-KokoroStudentReplayLibrary -BankPath $BankPath -OutputDirectory $OutputDirectory -MeasurementDirectory $MeasurementDirectory -KernelOnly:$KernelOnly}
        'Climb'{
            if($Finalize){Complete-KokoroStudentStore -ClimbDirectory $ClimbDirectory -OutputDirectory $OutputDirectory -LibraryDirectory $LibraryDirectory -KernelOnly:$KernelOnly}
            else{Invoke-KokoroStudentClimb -BankPath $BankPath -OutputDirectory $OutputDirectory -LibraryDirectory $LibraryDirectory -MeasurementDirectory $MeasurementDirectory -KernelOnly:$KernelOnly -ChunkLimit $ChunkLimit -Threads $Threads -ResumeDirectory $ResumeDirectory}
        }
    }
}

Export-ModuleMember -Function Invoke-KokoroStudent,Measure-KokoroStudentStructure
