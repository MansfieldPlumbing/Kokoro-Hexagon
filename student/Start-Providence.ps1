using module ./Providence.Field.psm1
using module ./Providence.Speech.psm1
#requires -Version 7.7
<#
.SYNOPSIS
  Interleaves actual retained-bank observation, cross-renderer measurement, and
  evolving CLR semantic traversal. No epochs, scripted target discoveries, or
  fabricated contours. This is the source-linked acquisition substrate, not yet
  an autonomous prosody-controller or intervention generator.
#>
[CmdletBinding()]
param(
    [string]$BankPath=(Join-Path $PSScriptRoot '../data/source-bank'),
    [string]$StateDirectory=(Join-Path $PSScriptRoot '../build/providence'),
    [ValidateRange(1,4096)][int]$InferenceBudget=48,
    [ValidateRange(4,256)][int]$ContourBins=32,
    [ValidateRange(1,32)][int]$MemoryLimitGiB=4,
    [string]$ZiraModulePath,
    [string]$CapabilityArchive,
    [switch]$SkipByteVerification,
    [switch]$Fresh
)
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot/StudentTeacherObservation.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/Providence.Bank.psm1" -ErrorAction Stop
$root=(Resolve-Path -LiteralPath $BankPath).ProviderPath
$state=[IO.Directory]::CreateDirectory($StateDirectory).FullName
$fieldPath=Join-Path $state 'field.bin'
$lock=[IO.File]::Open((Join-Path $state 'field.lock'),'OpenOrCreate','ReadWrite','None')
try {
    $readerArgs=@{BankPath=$root}
    if($ZiraModulePath){
        $zira=Import-Module (Resolve-Path -LiteralPath $ZiraModulePath).ProviderPath -PassThru -ErrorAction Stop
        if(!$zira){throw 'Requested Zira observation importer did not load'}
        $readerArgs.ZiraModule=$zira
    } else {
        $reference=Join-Path $PSScriptRoot '../phonemizer/Invoke-EnglishPhonemizer.ps1'
        $readerArgs.ZiraModule=New-Module -Name ProvidenceZira -ArgumentList $reference -ScriptBlock {
            param($Reference)
            . $Reference -Import
        }
    }
    $speech=& "$PSScriptRoot/Open-StudentSpeechInvestigation.ps1" @readerArgs
    # The Student's PowerShell-defined CLR classes must be loaded before their
    # reflected member contracts can be reconstructed from a previous process.
    $field=if(!$Fresh -and [IO.File]::Exists($fieldPath)){
        Import-ProvidenceField -Path $fieldPath
    }elseif($CapabilityArchive){
        Import-ProvidenceField -Path $CapabilityArchive -CapabilitiesOnly
    }else{New-ProvidenceField}
    $sources=@($speech.Inventory.Units.Values)
    $comparisons=@($speech.Comparisons)
    $executions=@($speech.Executions)
    $raw=[Collections.Generic.List[string]]::new()
    $options=[IO.EnumerationOptions]::new();$options.RecurseSubdirectories=$true;$options.IgnoreInaccessible=$false
    foreach($path in [IO.Directory]::EnumerateFiles($root,'*',$options)){$raw.Add($path)}
    $tensorDirs=[Collections.Generic.List[string]]::new()
    $tensorDirs.Add([IO.Path]::GetFullPath((Join-Path $root 'stock-activation-buffers')))
    $extras=Join-Path $root 'stock-activation-roots.txt'
    if([IO.File]::Exists($extras)){
        foreach($dir in [IO.File]::ReadLines($extras)){
            if($dir){$tensorDirs.Add([IO.Path]::GetFullPath($dir))}
        }
    }
    foreach($dir in $tensorDirs){
        if(![IO.Directory]::Exists($dir) -or $dir.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){continue}
        foreach($path in [IO.Directory]::EnumerateFiles($dir,'*.gz',$options)){$raw.Add($path)}
    }
    $paths=[Collections.Generic.HashSet[string]]::new($(if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}))
    $actual=[Collections.Generic.List[string]]::new()
    foreach($path in $raw){if($paths.Add($path)){$actual.Add($path)}}
    $byFile=[Collections.Generic.Dictionary[string,object]]::new($(if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}))
    foreach($unit in $sources){
        if(!$unit.Path){continue}
        $path=[IO.Path]::GetFullPath($unit.Path,$root)
        if(!$byFile.ContainsKey($path) -or $unit.Kind -cnotin 'TextSpanUtf16','PublisherTranscriptWordSamples','PublisherTranscriptEventSamples'){
            $byFile[$path]=$unit
        }
    }
    $checkpoint=Join-Path $PSScriptRoot '../build/student-retained-checkpoints'
    if (!(Test-Path -LiteralPath $checkpoint -PathType Container)) {
        $checkpoint=Join-Path $state 'file-checkpoints'
    }
    $resumed=0L;$physicalBytes=0L;$examples=0L;$failed=0L
    $start=[Diagnostics.Stopwatch]::StartNew()
    $cursorSource=0;$cursorComparison=0;$cursorExecution=0;$cursorFile=0
    $lastPersisted=0L;$steps=0L
    $lastProgress=[Diagnostics.Stopwatch]::StartNew()
    while($cursorSource -lt $sources.Count -or $cursorComparison -lt $comparisons.Count -or
          $cursorExecution -lt $executions.Count -or $cursorFile -lt $actual.Count){
        if($cursorSource -lt $sources.Count){
            $s=$sources[$cursorSource++];$null=$field.Register($s,[string]$s.Id,[string]$s.EvidenceGroup)
        }
        if($cursorExecution -lt $executions.Count){
            $exec=$executions[$cursorExecution++]
            $id='execution/'+$exec.Teacher.Directory+'/'+$exec.Recipe
            $null=$field.Register($exec,$id,[string]$exec.Teacher.Document.Source.EvidenceGroup)
        }
        if($cursorComparison -lt $comparisons.Count){
            $comparison=$comparisons[$cursorComparison++]
            $id='passage/'+$comparison.Teacher.Document.Source.Id+'/'+$comparison.Teacher.Start+'/'+$comparison.Teacher.Length
            $null=$field.Register($comparison,$id,[string]$comparison.Teacher.Document.Source.EvidenceGroup)
            try {
                $view=Join-ProvidencePassage -Comparison $comparison -ShapeBins $ContourBins
                $null=$field.Register($view,$id+'/cross-renderer',[string]$view.Source.EvidenceGroup)
                $examples++
                $ziraBearings=0
                $stockBearings=0
                foreach($occ in $view.Occurrences){
                    if($occ.StockBearing){$stockBearings++}
                    foreach($bearing in $occ.ZiraBearings){
                        $ziraBearings++
                        $null=$field.Register($bearing,"$id/zira/$($occ.TokenIndex)/$($bearing.WordEvent.Event)",[string]$view.Source.EvidenceGroup)
                        $null=$field.Require($bearing,[ProvidenceHumanIntervalCandidate],'Find source-occurrence human bracket; exact timing remains unproved')
                        $null=$field.Require($bearing,[ProvidenceStockWordBearing],'Find a stock generator window through a shared phone-stream projection')
                    }
                }
                Write-Information ("{0:u} {1} Zira word bearings={2} human brackets={3} stock clock={4} stock word bearings={5}" -f
                    [datetime]::UtcNow,$id,$ziraBearings,$view.HumanCandidates.Length,$view.KokoroTokenClock.Status,$stockBearings) -InformationAction Continue
                # The absence of an exact human performance coordinate is retained
                # as an explicit unresolved observation; it is NOT fabricated alignment.
                if(!$view.HumanCandidates.Length){
                    $need=[ProvidenceReverie]::new()
                    $need.Key=$id+'/human-timing';$need.Owner=$view;$need.OwnerKey=$id+'/cross-renderer'
                    $need.Reason='No verified word/phone-to-human-performance coordinate for this passage'
                    $field.Reveries[$need.Key]=$need
                }
            } catch {
                $failed++
                Write-Warning "Comparison ${id}: $($_.Exception.Message)"
            }
        }
        if($cursorFile -lt $actual.Count){
            $p=$actual[$cursorFile++]
            $canonical=$null;$null=$byFile.TryGetValue($p,[ref]$canonical)
            $isTensor=$false
            foreach($dir in $tensorDirs){
                if($p.StartsWith($dir+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and
                   $p.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)){$isTensor=$true;break}
            }
            if(!$SkipByteVerification){
                try {
                    $f=Read-ProvidenceRetainedFile -Path $p -CheckpointDirectory $checkpoint -TensorPayload:$isTensor -CanonicalSource $canonical
                    if($f.FromCheckpoint){$resumed++}else{$physicalBytes+=$f.Bytes}
                    if(!$f.Verified){$failed++}
                    $key='file/'+[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($p)))
                    $null=$field.Register($f,$key,$(if($canonical){[string]$canonical.EvidenceGroup}else{'UnindexedFile'}))
                    $field.FileObservations[$p]=$f.Digest
                    $field.FilesCovered++
                    if($f.Verified){$field.BytesVerified+=$f.Bytes}
                } catch {
                    $failed++
                    Write-Warning "File ${p}: $($_.Exception.Message)"
                }
            }
        }
        $null=$field.Advance($InferenceBudget)
        $steps++
        if(($steps%250) -eq 0 -or $lastProgress.Elapsed.TotalSeconds -ge 15){
            $memory=[Diagnostics.Process]::GetCurrentProcess()
            try{$bytes=$memory.WorkingSet64}finally{$memory.Dispose()}
            if($bytes -ge $MemoryLimitGiB*1GB){
                Save-ProvidenceField -Field $field -Path $fieldPath
                throw 'Memory bound reached; persisted field can be resumed with a larger limit or reduced observation budget.'
            }
            Write-Information ("{0:u} source={1}/{2} comparisons={3}/{4} files={5}/{6} bytes={7:N0} cached={8} relations={9} compositions={10} failures={11} workingSetMiB={12:N0}" -f
                [datetime]::UtcNow,$cursorSource,$sources.Count,$cursorComparison,$comparisons.Count,
                $cursorFile,$actual.Count,$physicalBytes,$resumed,$field.Percepts.Count,$field.AcquiredCompositions,$failed,($bytes/1MB)) -InformationAction Continue
            $lastProgress.Restart()
        }
        if($steps -eq 60 -or $steps-$lastPersisted -ge 1000){Save-ProvidenceField -Field $field -Path $fieldPath;$lastPersisted=$steps}
    }
    while($field.Advance(512) -gt 0){
        $memory=[Diagnostics.Process]::GetCurrentProcess()
        try{$bytes=$memory.WorkingSet64}finally{$memory.Dispose()}
        if($bytes -ge $MemoryLimitGiB*1GB){break}
    }
    Save-ProvidenceField -Field $field -Path $fieldPath
    $result=$field.Status()
    $result | Add-Member -NotePropertyName RealPairedPassages -NotePropertyValue $examples
    $result | Add-Member -NotePropertyName FilesResumed -NotePropertyValue $resumed
    $result | Add-Member -NotePropertyName PhysicalBytesRead -NotePropertyValue $physicalBytes
    $result | Add-Member -NotePropertyName FailedObservations -NotePropertyValue $failed
    $result | Add-Member -NotePropertyName Elapsed -NotePropertyValue $start.Elapsed
    return $result
} finally {$lock.Dispose()}
