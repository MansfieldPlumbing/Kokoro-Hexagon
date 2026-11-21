using module ./StudentSourceInventory.psm1
using module ./StudentTextEvidence.psm1
using module ./StudentTeacherObservation.psm1
#requires -Version 7.7
param(
    [string] $BankPath=(Join-Path $PSScriptRoot '../data/source-bank'),
    [ValidateRange(0,1000000)][int] $Limit=0,
    [string] $SourceIdentity,
    [switch] $Procedural,
    [string] $ClockExperimentPath,
    [ValidateRange(1,1024)][int] $ReserveGiB=5,
    [ValidatePattern('^generator\.(resblocks\.[0-5]|noise_res\.[01])\.[0-2]$')]
    [string] $DropResidualPair,
    [string] $Intention
)
$ErrorActionPreference='Stop'
$experiment=[bool]$DropResidualPair
if ($experiment -and ($Procedural -or !$Intention)) { throw 'A residual intervention requires a stated intention and stock controls.' }
if ($ClockExperimentPath -and !$Procedural) { throw 'A clock experiment requires procedural capture.' }
if ($ClockExperimentPath) { $ClockExperimentPath=(Resolve-Path -LiteralPath $ClockExperimentPath).Path }
$bank=(Resolve-Path -LiteralPath $BankPath).Path
$buffers=[IO.Directory]::CreateDirectory((Join-Path $bank 'stock-activation-buffers')).FullName
$inventory=Open-StudentSourceInventory (Join-Path $bank 'sources.bin')
$indexName=if ($experiment) { "intervention-$DropResidualPair.bin" } elseif ($Procedural) { 'procedural-execution.bin' } else { 'stock-execution.bin' }
$files=@{}
foreach ($file in Get-ChildItem (Join-Path $bank 'linguistic') -Filter 'pg*.bin') {
    $doc=Open-StudentTextEvidence $file.FullName $inventory
    if (!$SourceIdentity -or $doc.Source.EvidenceGroup -ceq $SourceIdentity) { $files[$doc.Source.Id]=$file.FullName }
}
$pending=@(foreach ($dir in Get-ChildItem (Join-Path $bank 'paired-teachers') -Directory) {
    $pair=Join-Path $dir.FullName 'observation.bin'
    if (![IO.File]::Exists($pair) -or [IO.File]::Exists((Join-Path $dir.FullName $indexName))) { continue }
    if ($experiment -and ![IO.File]::Exists((Join-Path $dir.FullName 'stock-execution.bin'))) { continue }
    $r=[IO.BinaryReader]::new([IO.File]::OpenRead($pair))
    try {
        if ($r.ReadString() -cne 'StudentTeacherObservation/1') { throw "Invalid teacher pair $dir." }
        $id=$r.ReadString()
        if ($files.ContainsKey($id)) { $dir.FullName }
    } finally { $r.Dispose() }
})
if (!$pending) { return }
$null=. "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition -Threads 4
& $studentOwner {
    param($directories,$files,$inventory,$buffers,$bank,$limit,$procedural,$indexName,$drop,$intention,$clockExperiment,$reserveGiB)
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($buffers))
    $reserve=[long]$reserveGiB*1GB
    $rules=$null
    $recordings=$null
    if ($procedural -and !$clockExperiment) {
        $ruleInventory=Use-StudentInventory
        $rules=$ruleInventory.Rules
        $recordings=$ruleInventory.Recordings
    }
    $syllabus=Import-StudentSyllabus (Join-Path $script:StudentBuild ('student/stock-trace-'+[guid]::NewGuid()))
    try {
        $implementation=@($script:StudentInputs.Syllabus,$script:StudentInputs.Manifest,'src/frontend/Kokoro.TextEncoder.ps1','tools/Kokoro.TextEncoder.psm1','student/Invoke-Student.ps1')
        $pins=foreach ($name in $implementation) {
            $path=Join-Path $script:StudentRoot $name
            $hash=(Get-FileHash -LiteralPath $path).Hash
            $folder=[IO.Directory]::CreateDirectory((Join-Path $bank "teacher-provenance/$hash")).FullName
            $copy=Join-Path $folder ([IO.Path]::GetFileName($path))
            if (![IO.File]::Exists($copy)) { [IO.File]::Copy($path,$copy) }
            if ((Get-FileHash -LiteralPath $copy).Hash -cne $hash) { throw 'Implementation pin mismatch.' }
            "$name=$hash"
        }
        $recipe="procedural=$procedural af_heart speed=1 seed=17 threads=4 PowerShell=$($PSVersionTable.PSVersion) CLR=$([Environment]::Version) $($pins -join ' ')"
        if ($clockExperiment) {
            # Read historical inputs. Only the reconstructed typed observations are published.
            $historical=Import-Clixml -LiteralPath $clockExperiment
            $trainingText=[string[]]$historical.Training
            if (!$trainingText.Length) { throw 'The historical clock experiment has no training passages.' }
            $driver=$null
            foreach ($file in Get-ChildItem (Join-Path $script:StudentBuild 'phonemizer/english/driver') -Recurse -Filter driver-receipt.psd1) {
                $receipt=Import-PowerShellDataFile -LiteralPath $file.FullName
                if ($receipt.AssemblySha256 -ceq $historical.Driver) { $driver=$file; break }
            }
            if (!$driver) { throw "Historical phonemizer driver unavailable: $($historical.Driver)." }
            $script:StudentInputs.Phonemizer=@{
                Directory=[IO.Path]::GetRelativePath($script:StudentRoot,$driver.DirectoryName)
                SHA256=$historical.Driver
            }
            $recipe+=" historicalClockInput=$((Get-FileHash -LiteralPath $clockExperiment).Hash) driver=$($historical.Driver)"
            $training=@(foreach ($sentence in $trainingText) {
                $sample=New-StudentTextPhones $sentence
                $targetSpeech=& $syllabus { param($p) Invoke-OfflineSpeech -Phonemes $p -Voice af_heart -SkipDecoder } $sample.Phonemes
                $tick=0
                for ($i=0;$i -lt $sample.Phones.Count;$i++) {
                    $phone=$sample.Phones[$i]
                    $phone.FirstTick=$tick
                    $phone.Ticks=2*$targetSpeech.Durations[$i]
                    $tick+=$phone.Ticks
                    $phone.Window.Evidence=$targetSpeech
                    $phone
                }
            })
            $rules=New-StudentProsodyRules $training $false $true
        }
        $cache=@{}
        $made=0
        foreach ($target in $directories) {
            if ($limit -and $made -ge $limit) { break }
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $pair=Join-Path $target 'observation.bin'
            $r=[IO.BinaryReader]::new([IO.File]::OpenRead($pair))
            try { $null=$r.ReadString(); $id=$r.ReadString() } finally { $r.Dispose() }
            if (!$cache.ContainsKey($id)) {
                $cache.Clear()
                $cache[$id]=Open-StudentTextEvidence $files[$id] $inventory
            }
            $teacher=Open-StudentTeacherObservation $target $cache[$id] -LoadTensors
            if ($drop -and !$teacher.StockExecution.Recipe.Contains($pins[0],[StringComparison]::Ordinal)) {
                throw 'Intervention requires stock baseline with the same syllabus pin.'
            }
            $stage=Join-Path $target ("stock-execution-"+[guid]::NewGuid()+'.partial')
            $w=[IO.BinaryWriter]::new([IO.File]::Open($stage,[IO.FileMode]::CreateNew))
            $failurePath=Join-Path $target ($indexName+'.failure.txt')
            try {
                $w.Write('StudentStockExecution/1')
                $w.Write((Get-FileHash -LiteralPath $pair).Hash)
                if ($drop) { $w.Write("$recipe`n$drop`n$intention") } else { $w.Write($recipe) }
                $at=$w.BaseStream.Position
                $w.Write([int]0)
                $state=@{ Count=0; Raw=0L; Compressed=0L }
                $sink=[Action[string,string,int,Array]] {
                    param($name,$axes,$extent,$values)
                    $code=switch ($values.GetType()) {
                        ([single[]]) { [byte]1 }
                        ([double[]]) { [byte]2 }
                        ([int[]]) { [byte]3 }
                        default { throw "Unsupported tensor type for $name." }
                    }
                    $bytes=[byte[]]::new([Buffer]::ByteLength($values))
                    [Buffer]::BlockCopy($values,0,$bytes,0,$bytes.Length)
                    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
                    $path=Join-Path $buffers "$hash.gz"
                    if (![IO.File]::Exists($path)) {
                        if ($drive.AvailableFreeSpace -le $reserve+$bytes.Length) { throw 'Activation store reached the configured free-space reserve.' }
                        $temp="$path.$([guid]::NewGuid()).partial"
                        try {
                            $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew)
                            try {
                                $gzip=[IO.Compression.GZipStream]::new($stream,[IO.Compression.CompressionLevel]::Fastest)
                                try { $gzip.Write($bytes,0,$bytes.Length) } finally { $gzip.Dispose() }
                            } finally { $stream.Dispose() }
                            try {
                                [IO.File]::Move($temp,$path)
                                $state.Compressed+=(Get-Item -LiteralPath $path).Length
                            } catch [IO.IOException] {
                                if (![IO.File]::Exists($path)) { throw }
                            }
                        } finally { [IO.File]::Delete($temp) }
                    }
                    $w.Write([string]$name)
                    $w.Write([string]$axes)
                    $w.Write([int]$extent)
                    $w.Write([int]$values.Length)
                    $w.Write([byte]$code)
                    $w.Write($hash)
                    $state.Count++
                    $state.Raw+=$bytes.Length
                }
                if ($procedural) {
                    $spoken=New-StudentTextPhones $teacher.InputText
                    $sink.Invoke('procedural.phone_text','utf16CodeUnit',$spoken.Phonemes.Length,[int[]]$spoken.Phonemes.ToCharArray())
                    $controls=New-StudentProsodyStream $rules $spoken.Phones $recordings -ObservationSink $sink
                    $speech=& $syllabus {
                        param($phones,$controls,$sink)
                        Invoke-OfflineSpeech -Phonemes $phones -Voice af_heart -RecomputeText -SuppliedDurations $controls.Durations -SuppliedF0 $controls.F0 -SuppliedN $controls.N -TensorObservationSink $sink
                    } $spoken.Phonemes $controls $sink
                } else {
                    $speech=& $syllabus { param($phones,$sink,$drop) Invoke-OfflineSpeech -Phonemes $phones -Voice af_heart -RecomputeText -TensorObservationSink $sink -DropResiduals $drop } $teacher.Phones $sink $drop
                    foreach ($name in $teacher.Names) {
                        $a=$teacher.Tensors[$name]
                        $b=$speech.$name
                        $ab=[byte[]]::new([Buffer]::ByteLength($a))
                        $bb=[byte[]]::new([Buffer]::ByteLength($b))
                        [Buffer]::BlockCopy($a,0,$ab,0,$ab.Length)
                        [Buffer]::BlockCopy($b,0,$bb,0,$bb.Length)
                        if (![Linq.Enumerable]::SequenceEqual[byte]($ab,$bb)) { throw "Retained tensor differs: $name." }
                    }
                    $wavHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]](ConvertTo-StudentWave $speech.Pcm)))
                    if (!$drop -and $wavHash -cne (Get-FileHash -LiteralPath $teacher.KokoroWavePath).Hash) { throw 'Retained Kokoro WAV differs.' }
                }
                $w.BaseStream.Position=$at
                $w.Write([int]$state.Count)
                $w.Dispose()
                [IO.File]::Move($stage,(Join-Path $target $indexName))
                [IO.File]::Delete($failurePath)
                $made++
                "source=$id start=$($teacher.Start) samples=$($speech.Pcm.Length) tensors=$($state.Count) rawBytes=$($state.Raw) newCompressedBytes=$($state.Compressed) wallSeconds=$($clock.Elapsed.TotalSeconds)"
            } catch {
                [IO.File]::AppendAllText($failurePath,"$([DateTimeOffset]::UtcNow.ToString('o')) $recipe`n$_`n$($_.ScriptStackTrace)`n")
                if ($procedural -and $_.Exception.Message -ceq 'The phonemizer could not resolve -Text.') {
                    Write-Warning "Unresolved procedural pronunciation at $id offset $($teacher.Start)."
                    continue
                }
                throw
            } finally { $w.Dispose(); [IO.File]::Delete($stage) }
        }
    } finally { Remove-Module $syllabus }
} $pending $files $inventory $buffers $bank $Limit $Procedural.IsPresent $indexName $DropResidualPair $Intention $ClockExperimentPath $ReserveGiB
