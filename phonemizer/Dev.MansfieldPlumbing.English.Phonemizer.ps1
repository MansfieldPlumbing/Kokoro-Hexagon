#requires -Version 7.7
[CmdletBinding(DefaultParameterSetName='Run')]
param(
    [Parameter(ParameterSetName='Build',Mandatory)][switch]$Build,
    [Parameter(ParameterSetName='Run')][switch]$Run,
    [Parameter(ParameterSetName='Inspect',Mandatory)][switch]$Inspect,
    [Parameter(ParameterSetName='Verify',Mandatory)][switch]$Verify,
    [Parameter(ParameterSetName='Import',Mandatory)][switch]$Import,
    [Parameter(ParameterSetName='Zira',Mandatory)][switch]$Zira,
    [Parameter(ParameterSetName='Speak',Mandatory)][switch]$Speak,
    [Parameter(ParameterSetName='Distill',Mandatory)][switch]$Distill,
    [Parameter(ParameterSetName='BuildDriver',Mandatory)][switch]$BuildDriver,
    [Parameter(ParameterSetName='VerifyDriver',Mandatory)][switch]$VerifyDriver,
    [Parameter(ParameterSetName='Audit',Mandatory)][switch]$Audit,
    [Parameter(ParameterSetName='Parity',Mandatory)][switch]$Parity,
    [Parameter(ParameterSetName='GenerateCorpus',Mandatory)][switch]$GenerateCorpus,
    [Parameter(ParameterSetName='LowerCorpus',Mandatory)][switch]$LowerCorpus,
    [string]$Text='',
    [string]$Voice='af_heart',
    [ValidateRange(0.5,2.0)][single]$Speed=1,
    [switch]$NoPlayback,
    [Parameter(ParameterSetName='Speak')][switch]$UseZira,
    [string]$SpeechAssemblyPath=(Join-Path $PSHOME 'System.Speech.dll'),
    [string]$KokoroDirectory=(Join-Path $env:LOCALAPPDATA 'Build\PSPerception\kokoro'),
    [string]$PythonPath='C:\bin\micromamba\envs\mono\python.exe',
    [string]$DotnetPath='dotnet',
    [string]$CorpusPath='',
    [string]$ObservationPath=(Join-Path $env:LOCALAPPDATA 'Build\PSPerception\english\zira-corpus.psd1'),
    [string]$ValidationCorpusPath='',
    [string]$CorrectionPath=(Join-Path $env:LOCALAPPDATA 'Build\PSPerception\english\zira-corrections.psd1'),
    [ValidateSet('Proof','Moby','MobyOnly')][string]$LexicalSource='Moby',
    [string]$AssemblyPath=(Join-Path $env:LOCALAPPDATA 'Build\PSPerception\english\Dev.MansfieldPlumbing.English.Phonemizer.dll')
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:EnglishReferenceCache=@{}
$script:EnglishCorrectionCache=@{}
$script:EnglishCoreCache=@{}

class EnglishZiraPhone {
    EnglishZiraPhone() {}
    [string]$Phone
    [string]$Next
    [long]$Ticks
    [long]$DurationTicks
    [int]$Emphasis
    [int]$Event
}
class EnglishZiraWord {
    EnglishZiraWord() {}
    [string]$Word
    [int]$Start
    [int]$Length
    [long]$Ticks
    [int]$Event
    [string]$RawPhones
    [string]$Phones
    [int]$StressObserved
    [long]$FirstTicks
    [int]$PhoneCount
    [int]$Role=-1
    [int[]]$SymbolIds
    [int[]]$Roles
    [EnglishZiraPhone[]]$PhoneEvents
    [EnglishZiraUtterance]$Utterance
}
class EnglishZiraUtterance {
    EnglishZiraUtterance() {}
    [int]$Version=1
    [string]$Identity
    [string]$Text
    [string]$Voice
    [string]$AssemblySha256
    [string]$EngineSha256
    [long]$CapturedAtTicks
    [string]$Partition='U'
    [EnglishZiraWord[]]$Words
    [EnglishZiraPhone[]]$Phones
    [EnglishZiraWord[]]$AlignedWords
    [string]$Alignment='Unproved'
    [string]$CapturePath
}
class EnglishZiraChoice {
    EnglishZiraChoice() {}
    [string]$Key
    [string]$Pronunciation
    [int[]]$SymbolIds
    [int]$ConstructionSupport
    [int]$AdmissionCases
    [int]$Fixes
    [int]$Regressions
    [string]$StressSource
    [bool]$Admitted
    [string]$Reason
    [EnglishZiraUtterance[]]$Captures
}

function Write-EnglishBuildReceipt {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $lines=[Collections.Generic.List[string]]::new();$lines.Add('@{')
    foreach($key in $Data.Keys){
        if([string]$key -cnotmatch '^[A-Za-z][A-Za-z0-9]*$'){throw 'Receipt field name failure.'}
        $value=$Data[$key]
        if($null -eq $value){$literal='$null'}
        elseif($value -is [bool]){$literal=if($value){'$true'}else{'$false'}}
        elseif($value -is [Array]){$literal='@('+(@($value | ForEach-Object {if($_ -is [ValueType]){[Convert]::ToString($_,[Globalization.CultureInfo]::InvariantCulture)}else{"'"+([string]$_).Replace("'","''")+"'"}}) -join ',')+')'}
        elseif($value -is [ValueType]){$literal=[Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture)}
        else{$literal="'"+([string]$value).Replace("'","''")+"'"}
        $lines.Add('    '+$key+' = '+$literal)
    }
    $lines.Add('}');[IO.File]::WriteAllLines($Path,$lines.ToArray(),[Text.UTF8Encoding]::new($false))
}

function Get-EnglishKokoroSpecification {
    $path=Join-Path $env:LOCALAPPDATA 'Build\PSPerception\kokoro-config.json'
    if((Get-FileHash -LiteralPath $path).Hash -cne '5ABB01E2403B072BF03D04FDE160443E209D7A0DAD49A423BE15196B9B43C17F'){throw 'Pinned Kokoro specification integrity failure.'}
    $vocab=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal);$reading=$false
    foreach($line in [IO.File]::ReadAllLines($path)){
        if($line -cmatch '^  "vocab": \{$'){$reading=$true;continue}
        if(-not $reading){continue}
        if($line -cmatch '^  \}$'){$reading=$false;break}
        if($line -cnotmatch '^    "(\\"|\\u[0-9A-Fa-f]{4}|[^"\\])": ([0-9]+),?$'){throw 'Pinned vocabulary line shape changed.'}
        $symbol=$Matches[1];$id=[int]$Matches[2]
        if($symbol -ceq '\"'){$symbol='"'}elseif($symbol.StartsWith('\u')){$symbol=[string][char][Convert]::ToInt32($symbol.Substring(2),16)}
        $vocab.Add($symbol,$id)
    }
    if($vocab.Count -ne 114){throw 'Pinned target vocabulary count changed.'}
    [pscustomobject]@{vocab=$vocab;plbert=[pscustomobject]@{max_position_embeddings=512}}
}

function Import-EnglishLowering {
    $compiler=Join-Path $env:LOCALAPPDATA 'Build\PSPerception\inputs\pslowering-1afabe056235a570da29e268824784557d4f6cdd'
    $manifest=Import-Csv -LiteralPath (Join-Path $compiler 'verified-source.tsv') -Delimiter "`t"
    if($manifest.Count -ne 9){throw 'Pinned lowering source count failure.'}
    foreach($row in $manifest){
        $path=[IO.Path]::GetFullPath((Join-Path $compiler $row.Path))
        if(-not $path.StartsWith($compiler+'\',[StringComparison]::OrdinalIgnoreCase) -or $row.Commit -cne '1afabe056235a570da29e268824784557d4f6cdd' -or (Get-FileHash -LiteralPath $path).Hash -cne $row.Sha256){throw 'Pinned lowering source integrity failure.'}
    }
    Import-Module (Join-Path $compiler 'src\Dev.MansfieldPlumbing.PowerShell.Lowering.psd1') -Force -Global
}

function Get-EnglishZiraTypes {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Authoring script has parse errors.'}
    $classes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.TypeDefinitionAst] -and $node.Name -cin @('EnglishZiraPhone','EnglishZiraWord','EnglishZiraUtterance','EnglishZiraChoice')},$false))
    if($classes.Count -ne 4){throw 'Typed observation definition count failure.'}
    (@($classes | ForEach-Object {$_.Extent.Text}) -join "`n").Replace('EnglishZira','CoreZira')
}

function Get-EnglishTypedLiteral {
    param($Value,[switch]$Long)
    if($null -eq $Value){return '$null'}
    if($Value -is [string]){return "'"+$Value.Replace("'","''")+"'"}
    if($Value -is [bool]){if($Value){return '$true'}else{return '$false'}}
    if($Long){return ([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)+'L'}
    ([int]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Get-EnglishTypedArrayLiteral {
    param([object[]]$Values,[ValidateSet('string','int','long')][string]$Type)
    if(-not $Values.Count){return '['+$Type+'[]]::new(0)'}
    '['+$Type+'[]]@('+(@($Values | ForEach-Object {Get-EnglishTypedLiteral $_ -Long:($Type -ceq 'long')}) -join ',')+')'
}

function Save-EnglishZiraObservation {
    param([Parameter(Mandatory)][object]$Capture,[switch]$SourceOnly)
    $directory=Join-Path $env:LOCALAPPDATA 'Build\PSPerception\english\zira-captures'
    [void][IO.Directory]::CreateDirectory($directory)
    $path=Join-Path $directory ($Capture.Identity+'-'+[guid]::NewGuid().ToString('N')+'.psd1')
    $b=[Text.StringBuilder]::new()
    [void]$b.AppendLine('@{v=1;q=1;id='+(Get-EnglishTypedLiteral $Capture.Identity)+';text='+(Get-EnglishTypedLiteral $Capture.Text)+';a='+(Get-EnglishTypedLiteral $Capture.AssemblySha256)+';g='+(Get-EnglishTypedLiteral $Capture.EngineSha256)+';t='+(Get-EnglishTypedLiteral $Capture.CapturedAtTicks -Long)+';d='+(Get-EnglishTypedLiteral $Capture.Partition)+';z='+[int]($Capture.Alignment -ceq 'ExactSourceSpansAndWordOnsets')+';p=@(')
    foreach($phone in $Capture.Phones){
        [void]$b.AppendLine('@('+(Get-EnglishTypedLiteral $phone.Phone)+','+(Get-EnglishTypedLiteral $phone.Next)+','+(Get-EnglishTypedLiteral $phone.Ticks -Long)+','+(Get-EnglishTypedLiteral $phone.DurationTicks -Long)+','+$phone.Emphasis+','+$phone.Event+'),')
    }
    # A trailing comma is not legal data syntax. Keep the schema, not object type metadata.
    if($Capture.Phones.Count){$b.Length=$b.Length-[Environment]::NewLine.Length-1;[void]$b.AppendLine()}
    [void]$b.AppendLine(');w=@(')
    $aligned=[Collections.Generic.List[int]]::new()
    for($j=0;$j -lt $Capture.Words.Count;$j++){
        $word=$Capture.Words[$j];$indices=@(foreach($phone in $word.PhoneEvents){for($i=0;$i -lt $Capture.Phones.Count;$i++){if([object]::ReferenceEquals($phone,$Capture.Phones[$i])){$i;break}}})
        if($indices.Count -ne $word.PhoneCount){throw 'Word phone reference count failure.'}
        if($Capture.AlignedWords -contains $word){$aligned.Add($j)}
        $line='@('+(Get-EnglishTypedLiteral $word.Word)+','+$word.Role+','+(Get-EnglishTypedLiteral ([string]$word.RawPhones))+','+(Get-EnglishTypedLiteral ([string]$word.Phones))+',@('+($word.SymbolIds -join ',')+'),'+$word.Start+','+$word.Length+','+(Get-EnglishTypedLiteral $word.Ticks -Long)+','+$word.Event+',@('+($indices -join ',')+'),'+$word.StressObserved+',@('+($word.Roles -join ',')+')),'
        [void]$b.AppendLine($line)
    }
    if($Capture.Words.Count){$b.Length=$b.Length-[Environment]::NewLine.Length-1;[void]$b.AppendLine()}
    [void]$b.AppendLine(');x=@('+($aligned.ToArray() -join ',')+')}')
    if($SourceOnly){return $b.ToString()}
    [IO.File]::WriteAllText($path,$b.ToString(),[Text.UTF8Encoding]::new($false));$Capture.CapturePath=$path
    $path
}

function Import-EnglishZiraObservation {
    param([Parameter(Mandatory)][string]$Path,[System.Collections.IDictionary]$Data)
    if($Data){$data=$Data}else{
        $file=Get-Item -LiteralPath $Path
        if($file.Length -gt 4194304){throw 'Observation source size bound exceeded.'}
        $data=Import-PowerShellDataFile -LiteralPath $file.FullName
    }
    if($data.v -ne 1 -or $data.q -ne 1 -or $data.id -cnotmatch '^[A-F0-9]{64}$' -or $data.a -cnotmatch '^[A-F0-9]{64}$' -or $data.g -cnotmatch '^[A-F0-9]{64}$' -or $data.text.Length -gt 8192 -or $data.p.Count -gt 16384 -or $data.w.Count -gt 4096 -or $data.z -notin @(0,1)){throw 'Observation data contract failure.'}
    $u=[EnglishZiraUtterance]::new();$u.Identity=$data.id;$u.Text=$data.text;$u.Voice='Microsoft Zira Desktop';$u.AssemblySha256=$data.a;$u.EngineSha256=$data.g;$u.CapturedAtTicks=$data.t;$u.Partition=$data.d;$u.CapturePath=$Path
    $u.Phones=[EnglishZiraPhone[]]::new($data.p.Count)
    for($i=0;$i -lt $data.p.Count;$i++){
        $row=$data.p[$i]
        if($row.Count -ne 6 -or $row[0].Length -gt 32 -or $row[1].Length -gt 32 -or $row[2] -lt 0 -or $row[3] -lt 0 -or $row[4] -lt 0 -or $row[4] -gt 3 -or $row[5] -lt 0){throw 'Phone tuple contract failure.'}
        $p=[EnglishZiraPhone]::new();$p.Phone=$row[0];$p.Next=$row[1];$p.Ticks=$row[2];$p.DurationTicks=$row[3];$p.Emphasis=$row[4];$p.Event=$row[5];$u.Phones[$i]=$p
    }
    $u.Words=[EnglishZiraWord[]]::new($data.w.Count)
    for($j=0;$j -lt $data.w.Count;$j++){
        $row=$data.w[$j]
        if($row.Count -ne 12 -or $row[5] -lt 0 -or $row[6] -lt 0 -or $row[0].Length -gt 8192 -or $row[1] -lt -1 -or $row[1] -gt 4){throw 'Word extent or role contract failure.'}
        if($data.z -eq 1 -and ($row[6] -lt 1 -or $row[5]+$row[6] -gt $u.Text.Length -or $u.Text.Substring($row[5],$row[6]) -cne $row[0])){throw 'Claimed source alignment failure.'}
        foreach($role in $row[11]){if($role -lt -1 -or $role -gt 4){throw 'Role alternative outside schema.'}}
        $w=[EnglishZiraWord]::new();$w.Word=$row[0];$w.Role=$row[1];$w.RawPhones=$row[2];$w.Phones=$row[3];$w.SymbolIds=[int[]]$row[4];$w.Start=$row[5];$w.Length=$row[6];$w.Ticks=$row[7];$w.Event=$row[8];$w.StressObserved=$row[10];$w.Roles=[int[]]$row[11];$w.FirstTicks=$w.Ticks;$w.Utterance=$u
        $w.PhoneEvents=[EnglishZiraPhone[]]::new($row[9].Count)
        for($i=0;$i -lt $row[9].Count;$i++){if($row[9][$i] -lt 0 -or $row[9][$i] -ge $u.Phones.Count){throw 'Phone reference outside utterance.'};$w.PhoneEvents[$i]=$u.Phones[$row[9][$i]]}
        $w.PhoneCount=$w.PhoneEvents.Length
        if($w.PhoneCount){$w.FirstTicks=$w.PhoneEvents[0].Ticks}
        $observed=if($w.PhoneCount){$w.PhoneEvents.Phone -join ''}else{''}
        if($observed -cne $w.RawPhones){throw 'Word phone sequence does not match provenance references.'}
        $u.Words[$j]=$w
    }
    $u.AlignedWords=[EnglishZiraWord[]]::new($data.x.Count)
    for($i=0;$i -lt $data.x.Count;$i++){if($data.x[$i] -lt 0 -or $data.x[$i] -ge $u.Words.Count){throw 'Word reference outside utterance.'};$u.AlignedWords[$i]=$u.Words[$data.x[$i]]}
    if($data.z -eq 1){if($u.AlignedWords.Count -ne $u.Words.Count -or @($u.AlignedWords | Where-Object {$_.PhoneCount -eq 0}).Count){throw 'Incomplete alignment claim.'};$u.Alignment='ExactSourceSpansAndWordOnsets'}
    $u
}

function New-EnglishZiraDataSource {
    param([object[]]$Captures=@(),[object[]]$Entries=@())
    if($Captures.Count -gt 4096 -or $Entries.Count -gt 4096){throw 'Typed corpus cardinality bound exceeded.'}
    $b=[Text.StringBuilder]::new();[void]$b.AppendLine((Get-EnglishZiraTypes));[void]$b.AppendLine('class CoreZiraCorpusData {')
    for($n=0;$n -lt $Captures.Count;$n++){
        $u=$Captures[$n]
        if($u.Text.Length -gt 8192 -or $u.Phones.Count -gt 16384 -or $u.Words.Count -gt 4096){throw 'Typed observation bound exceeded.'}
        [void]$b.AppendLine('static [CoreZiraUtterance] Capture'+$n+'() {')
        [void]$b.AppendLine('[CoreZiraUtterance]$u=[CoreZiraUtterance]::new()')
        foreach($field in @('Identity','Text','Voice','AssemblySha256','EngineSha256','Partition','Alignment')){[void]$b.AppendLine('$u.'+$field+' = '+(Get-EnglishTypedLiteral ([string]$u.$field)))}
        [void]$b.AppendLine('$u.CapturedAtTicks = '+(Get-EnglishTypedLiteral $u.CapturedAtTicks -Long))
        foreach($field in @('Phone','Next','Ticks','DurationTicks','Emphasis','Event')){
            $type=if($field -cin @('Phone','Next')){'string'}elseif($field -cin @('Ticks','DurationTicks')){'long'}else{'int'}
            [void]$b.AppendLine('['+$type+'[]]$p'+$field+' = '+(Get-EnglishTypedArrayLiteral @($u.Phones | ForEach-Object {$_.$field}) $type))
        }
        [void]$b.AppendLine('$u.Phones=[CoreZiraPhone[]]::new('+$u.Phones.Count+')')
        [void]$b.AppendLine('for([int]$i=0;$i -lt $u.Phones.Length;$i++){[CoreZiraPhone]$p=[CoreZiraPhone]::new();$p.Phone=$pPhone[$i];$p.Next=$pNext[$i];$p.Ticks=$pTicks[$i];$p.DurationTicks=$pDurationTicks[$i];$p.Emphasis=$pEmphasis[$i];$p.Event=$pEvent[$i];$u.Phones[$i]=$p}')
        foreach($field in @('Word','Start','Length','Ticks','Event')){
            $type=if($field -ceq 'Word'){'string'}elseif($field -ceq 'Ticks'){'long'}else{'int'}
            [void]$b.AppendLine('['+$type+'[]]$w'+$field+' = '+(Get-EnglishTypedArrayLiteral @($u.Words | ForEach-Object {$_.$field}) $type))
        }
        [void]$b.AppendLine('$u.Words=[CoreZiraWord[]]::new('+$u.Words.Count+')')
        [void]$b.AppendLine('for([int]$i=0;$i -lt $u.Words.Length;$i++){[CoreZiraWord]$w=[CoreZiraWord]::new();$w.Word=$wWord[$i];$w.Start=$wStart[$i];$w.Length=$wLength[$i];$w.Ticks=$wTicks[$i];$w.FirstTicks=$wTicks[$i];$w.Event=$wEvent[$i];$w.Utterance=$u;$w.RawPhones='''' ;$w.Phones='''' ;$w.SymbolIds=[int[]]::new(0);$w.Roles=[int[]]::new(0);$w.PhoneEvents=[CoreZiraPhone[]]::new(0);$u.Words[$i]=$w}')
        [void]$b.AppendLine('$u.AlignedWords=[CoreZiraWord[]]::new('+$u.AlignedWords.Count+')')
        for($j=0;$j -lt $u.Words.Count;$j++){
            $w=$u.Words[$j]
            [void]$b.AppendLine('[CoreZiraWord]$a'+$j+'=$u.Words['+$j+']')
            foreach($field in @('RawPhones','Phones')){[void]$b.AppendLine('$a'+$j+'.'+$field+' = '+(Get-EnglishTypedLiteral ([string]$w.$field)))}
            foreach($field in @('StressObserved','PhoneCount')){[void]$b.AppendLine('$a'+$j+'.'+$field+' = '+(Get-EnglishTypedLiteral $w.$field))}
            [void]$b.AppendLine('$a'+$j+'.Role = '+(Get-EnglishTypedLiteral $w.Role))
            [void]$b.AppendLine('$a'+$j+'.SymbolIds = '+(Get-EnglishTypedArrayLiteral @($w.SymbolIds) int))
            [void]$b.AppendLine('$a'+$j+'.Roles = '+(Get-EnglishTypedArrayLiteral @($w.Roles) int))
            [void]$b.AppendLine('$a'+$j+'.FirstTicks = '+(Get-EnglishTypedLiteral $w.FirstTicks -Long))
            $phoneIndices=@(foreach($phone in $w.PhoneEvents){for($i=0;$i -lt $u.Phones.Count;$i++){if($u.Phones[$i].Event -eq $phone.Event){$i;break}}})
            if($phoneIndices.Count -ne $w.PhoneCount){throw 'Typed phone provenance reference failure.'}
            [void]$b.AppendLine('$a'+$j+'.PhoneEvents=[CoreZiraPhone[]]::new('+$phoneIndices.Count+')')
            for($i=0;$i -lt $phoneIndices.Count;$i++){[void]$b.AppendLine('$a'+$j+'.PhoneEvents['+$i+']=$u.Phones['+$phoneIndices[$i]+']')}
        }
        for($j=0;$j -lt $u.AlignedWords.Count;$j++){
            $w=$u.AlignedWords[$j];$indices=@(for($i=0;$i -lt $u.Words.Count;$i++){if([object]::ReferenceEquals($u.Words[$i],$w)){$i}})
            if($indices.Count -ne 1){throw 'Typed aligned word provenance reference failure.'}
            [void]$b.AppendLine('$u.AlignedWords['+$j+']=$u.Words['+$indices[0]+']')
        }
        [void]$b.AppendLine('return $u }')
    }
    [void]$b.AppendLine('static [CoreZiraUtterance[]] Captures() { [CoreZiraUtterance[]]$r=[CoreZiraUtterance[]]::new('+$Captures.Count+')')
    for($n=0;$n -lt $Captures.Count;$n++){[void]$b.AppendLine('$r['+$n+']=[CoreZiraCorpusData]::Capture'+$n+'()')}
    [void]$b.AppendLine('return $r }')
    [void]$b.AppendLine('static [CoreZiraChoice[]] Choices([CoreZiraUtterance[]]$captures) { [CoreZiraChoice[]]$r=[CoreZiraChoice[]]::new('+$Entries.Count+')')
    for($n=0;$n -lt $Entries.Count;$n++){
        $entry=$Entries[$n];[void]$b.AppendLine('[CoreZiraChoice]$c'+$n+'=[CoreZiraChoice]::new()')
        foreach($field in @('Key','Pronunciation','StressSource','Reason')){[void]$b.AppendLine('$c'+$n+'.'+$field+' = '+(Get-EnglishTypedLiteral ([string]$entry.$field)))}
        foreach($field in @('ConstructionSupport','AdmissionCases','Fixes','Regressions')){[void]$b.AppendLine('$c'+$n+'.'+$field+' = '+(Get-EnglishTypedLiteral $entry.$field))}
        [void]$b.AppendLine('$c'+$n+'.Admitted = '+(Get-EnglishTypedLiteral ([bool]$entry.Admitted)))
        [void]$b.AppendLine('$c'+$n+'.SymbolIds = '+(Get-EnglishTypedArrayLiteral @($entry.SymbolIds) int))
        [void]$b.AppendLine('$c'+$n+'.Captures=[CoreZiraUtterance[]]::new('+$entry.Captures.Count+')')
        for($j=0;$j -lt $entry.Captures.Count;$j++){
            $identity=$entry.Captures[$j].Identity;$indices=@(for($i=0;$i -lt $Captures.Count;$i++){if($Captures[$i].Identity -ceq $identity){$i}})
            if($indices.Count -ne 1){throw 'Typed choice provenance reference failure.'}
            [void]$b.AppendLine('$c'+$n+'.Captures['+$j+']=$captures['+$indices[0]+']')
        }
        [void]$b.AppendLine('$r['+$n+']=$c'+$n)
    }
    [void]$b.AppendLine('return $r } }')
    $b.ToString()
}

function Export-EnglishZiraCorpus {
    param([object[]]$Captures,[object[]]$Entries=@(),[string]$Pointer='')
    $source=New-EnglishZiraDataSource -Captures $Captures -Entries $Entries
    $identity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source)))
    $directory=Join-Path $env:LOCALAPPDATA ('Build\PSPerception\english\typed-corpora\'+$identity)
    [void][IO.Directory]::CreateDirectory($directory)
    $input=Join-Path $directory 'observations.ps1';$output=Join-Path $directory ('Dev.MansfieldPlumbing.English.Zira.'+$identity.Substring(0,16)+'.dll')
    Import-EnglishLowering
    if(-not(Test-Path -LiteralPath $output)){
        [IO.File]::WriteAllText($input,$source,[Text.UTF8Encoding]::new($false))
        $null=Export-LoweredAssembly -SourcePath $input -ClassName CoreZiraCorpusData -OutputPath $output -Deterministic
    }
    $inspection=Test-LoweredAssembly -AssemblyPath $output
    if($inspection.AssemblyReferences.Count -ne 1 -or $inspection.AssemblyReferences[0] -cne 'System.Private.CoreLib'){throw 'Typed corpus dependency failure.'}
    $receipt=Join-Path $directory 'corpus.psd1'
    $data=[ordered]@{Assembly=$output;Sha256=(Get-FileHash -LiteralPath $output).Hash;Source=$input;SourceSha256=$identity;Captures=$Captures.Count;Entries=$Entries.Count;Gate=if(@($Entries | Where-Object Admitted).Count){'ZIRA_CORRECTION_ADMISSION=PASS'}else{'TYPED_ZIRA_OBSERVATIONS'};CompilerCommit='1afabe056235a570da29e268824784557d4f6cdd'}
    Write-EnglishBuildReceipt -Path $receipt -Data $data
    $loaded=Import-EnglishZiraCorpus -Path $receipt
    # Preserve corpus identity and the phone/word reference graph through lowering.
    if($loaded.Captures.Count -ne $Captures.Count){throw 'Typed corpus reconstruction count failure.'}
    for($i=0;$i -lt $Captures.Count;$i++){
        $before=$Captures[$i];$after=$loaded.Captures[$i]
        foreach($field in @('Identity','Text','Voice','AssemblySha256','EngineSha256','CapturedAtTicks','Partition','Alignment')){if($before.$field -cne $after.$field){throw ('Typed utterance field changed: '+$field)}}
        if($before.Words.Count -ne $after.Words.Count -or $before.Phones.Count -ne $after.Phones.Count -or $before.AlignedWords.Count -ne $after.AlignedWords.Count){throw 'Typed corpus provenance count failure.'}
        for($j=0;$j -lt $before.Phones.Count;$j++){
            foreach($field in @('Phone','Next','Ticks','DurationTicks','Emphasis','Event')){if($before.Phones[$j].$field -cne $after.Phones[$j].$field){throw 'Typed phone observation changed during lowering.'}}
        }
        for($j=0;$j -lt $before.Words.Count;$j++){
            $left=$before.Words[$j];$right=$after.Words[$j]
            foreach($field in @('Word','Start','Length','Ticks','Event','RawPhones','Phones','StressObserved','FirstTicks','PhoneCount','Role')){if($left.$field -cne $right.$field){throw ('Typed original word field changed: '+$field+' at '+$i+'/'+$j+'; source null='+[object]::ReferenceEquals($null,$left.$field)+'; lowered null='+[object]::ReferenceEquals($null,$right.$field))}}
            foreach($field in @('SymbolIds','Roles')){if(($left.$field -join ',') -cne ($right.$field -join ',')){throw 'Typed original word array changed.'}}
            if(-not [object]::ReferenceEquals($right.Utterance,$after)){throw 'Typed original word parent reference changed.'}
            if($right.PhoneEvents.Length -ne $left.PhoneEvents.Length){throw 'Typed original word phone reference count changed.'}
            for($k=0;$k -lt $left.PhoneEvents.Length;$k++){
                if($left.PhoneEvents[$k].Event -ne $right.PhoneEvents[$k].Event -or -not @($after.Phones | Where-Object {[object]::ReferenceEquals($_,$right.PhoneEvents[$k])}).Count){throw 'Typed original word phone reference changed.'}
            }
        }
        for($j=0;$j -lt $before.AlignedWords.Count;$j++){
            $left=$before.AlignedWords[$j];$right=$after.AlignedWords[$j]
            foreach($field in @('Word','Start','Length','Ticks','Event','RawPhones','Phones','StressObserved','FirstTicks','PhoneCount','Role')){if($left.$field -cne $right.$field){throw ('Typed word field changed: '+$field)}}
            foreach($field in @('SymbolIds','Roles')){if(($left.$field -join ',') -cne ($right.$field -join ',')){throw 'Typed word array changed.'}}
            if(-not [object]::ReferenceEquals($right.Utterance,$after) -or ($right.PhoneEvents.Phone -join '') -cne $right.RawPhones){throw 'Typed word/phone provenance graph failure.'}
            foreach($phone in $right.PhoneEvents){if(-not @($after.Phones | Where-Object {[object]::ReferenceEquals($_,$phone)}).Count){throw 'Typed phone link was copied instead of retained.'}}
        }
    }
    if($Pointer){
        $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Build\PSPerception'))+'\';$Pointer=[IO.Path]::GetFullPath($Pointer)
        if(-not $Pointer.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Typed corpus pointer outside build root.'}
        if(Test-Path -LiteralPath $Pointer){Copy-Item -LiteralPath $Pointer -Destination ($Pointer+'.'+[guid]::NewGuid().ToString('N')+'.before')}
        Write-EnglishBuildReceipt -Path $Pointer -Data $data
    }
    $loaded
}

function Import-EnglishZiraCorpus {
    param([Parameter(Mandatory)][string]$Path)
    $receipt=Import-PowerShellDataFile -LiteralPath $Path
    $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Build\PSPerception'))+'\'
    if($receipt.CompilerCommit -cne '1afabe056235a570da29e268824784557d4f6cdd' -or -not ([IO.Path]::GetFullPath($receipt.Assembly)).StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFullPath($receipt.Source)).StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Typed corpus source provenance failure.'}
    if((Get-FileHash -LiteralPath $receipt.Assembly).Hash -cne $receipt.Sha256 -or (Get-FileHash -LiteralPath $receipt.Source).Hash -cne $receipt.SourceSha256){throw 'Typed corpus integrity failure.'}
    $assembly=[Reflection.Assembly]::LoadFrom($receipt.Assembly)
    $dependencies=@($assembly.GetReferencedAssemblies())
    if($dependencies.Count -ne 1 -or $dependencies[0].Name -cne 'System.Private.CoreLib'){throw 'Typed corpus has external runtime dependencies.'}
    $type=$assembly.GetType('CoreZiraCorpusData',$true)
    $captures=$type.GetMethod('Captures').Invoke($null,@())
    $arguments=[object[]]::new(1);$arguments[0]=$captures
    $entries=$type.GetMethod('Choices').Invoke($null,$arguments)
    foreach($capture in $captures){$capture.CapturePath=$receipt.Assembly}
    [pscustomobject]@{Assembly=$assembly;Captures=$captures;Entries=$entries;Source=$receipt.Source;Receipt=$Path;Output=$receipt.Assembly;Gate=$receipt.Gate}
}

function Write-EnglishZiraCorpus {
    param([Parameter(Mandatory)][string]$InputPath,[string]$OutputPath=$ObservationPath)
    $input=[IO.Path]::GetFullPath($InputPath);$output=[IO.Path]::GetFullPath($OutputPath)
    $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Build\PSPerception'))+'\'
    if(-not $output.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or $input -ceq $output -or [IO.Path]::GetExtension($output) -ine '.psd1'){throw 'Observation output must be a separate PSD1 under project build root.'}
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
    if(Test-Path -LiteralPath $output){Copy-Item -LiteralPath $output -Destination ($output+'.'+[guid]::NewGuid().ToString('N')+'.before')}
    $temporary=$output+'.'+[guid]::NewGuid().ToString('N')+'.partial'
    $reader=[IO.StreamReader]::new($input,[Text.UTF8Encoding]::new($false,$true),$true)
    $writer=[IO.StreamWriter]::new($temporary,$false,[Text.UTF8Encoding]::new($false))
    $count=0;$words=0;$phones=0;$profile=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        $writer.WriteLine('@{v=1;q=1;s='+ (Get-EnglishTypedLiteral ((Get-FileHash -LiteralPath $input).Hash))+';u=@(')
        while($null -ne ($sentence=$reader.ReadLine())){
            if($sentence -notmatch '\S'){continue}
            if($sentence.Length -gt 8192){throw 'Corpus line exceeds utterance bound.'}
            $capture=Get-EnglishZiraReference -Text $sentence -NoSave
            if($null -eq $profile){$profile=$capture}
            if($profile.AssemblySha256 -cne $capture.AssemblySha256 -or $profile.EngineSha256 -cne $capture.EngineSha256){throw 'Teacher binary changed during corpus capture.'}
            if($count){$writer.WriteLine(',')}
            $literal=Save-EnglishZiraObservation -Capture $capture -SourceOnly
            $literal=$literal.Replace('v=1;q=1;','').Replace(';a='+(Get-EnglishTypedLiteral $capture.AssemblySha256),'').Replace(';g='+(Get-EnglishTypedLiteral $capture.EngineSha256),'')
            $writer.Write($literal.TrimEnd());$writer.Flush()
            $count++;$words+=$capture.Words.Count;$phones+=$capture.Phones.Count
            if($count % 100 -eq 0){Write-Progress -Activity 'Capture Zira corpus' -Status ($count.ToString()+' utterances emitted')}
        }
        if(-not $count){throw 'Corpus has no utterances.'}
        $writer.WriteLine(');a='+(Get-EnglishTypedLiteral $profile.AssemblySha256)+';g='+(Get-EnglishTypedLiteral $profile.EngineSha256)+'}')
    }finally{$reader.Dispose();$writer.Dispose();Write-Progress -Activity 'Capture Zira corpus' -Completed}
    Move-Item -LiteralPath $temporary -Destination $output -Force
    [pscustomobject]@{Gate='ZIRA_CORPUS_EMITTED';Utterances=$count;Words=$words;PhoneEvents=$phones;Seconds=$watch.Elapsed.TotalSeconds;Output=$output;Sha256=(Get-FileHash -LiteralPath $output).Hash;Roles='Unresolved until contextual admission';Schema=1}
}

function Convert-EnglishZiraCorpus {
    param([Parameter(Mandatory)][string]$Path)
    $info=Get-Item -LiteralPath $Path
    if($info.Length -gt 134217728){throw 'Corpus lowering source exceeds 128 MiB bound.'}
    $data=Import-PowerShellDataFile -LiteralPath $info.FullName -SkipLimitCheck
    if($data.v -ne 1 -or $data.q -ne 1 -or $data.u.Count -gt 4096 -or $data.a -cnotmatch '^[A-F0-9]{64}$' -or $data.g -cnotmatch '^[A-F0-9]{64}$'){throw 'Corpus schema or lowering cardinality bound failure.'}
    $captures=@(foreach($row in $data.u){
        $record=@{}+$row;$record.v=$data.v;$record.q=$data.q;$record.a=$data.a;$record.g=$data.g
        Import-EnglishZiraObservation -Path $info.FullName -Data $record
    })
    $compiled=Export-EnglishZiraCorpus -Captures $captures
    [pscustomobject]@{Gate='TYPED_ZIRA_CORPUS_LOWERED';Captures=$captures.Count;Output=$compiled.Output;Receipt=$compiled.Receipt;Source=$compiled.Source;PronunciationSelection='Observations only; contextual choices require admission'}
}
$script:MobyPhoneMap=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach($entry in '&=æ;(@)=ɛ;A=ɑ;eI=A;@=ə;-=ə;b=b;tS=ʧ;d=d;E=ɛ;i=i;f=f;g=ɡ;h=h;hw=w;I=ɪ;aI=I;dZ=ʤ;k=k;l=l;m=m;N=ŋ;n=n;Oi=Y;AU=W;O=ɔ;oU=O;u=u;U=ʊ;p=p;r=ɹ;S=ʃ;s=s;T=θ;D=ð;t=t;@r=əɹ;v=v;w=w;j=j;Z=ʒ;z=z'.Split(';')){
    $pair=$entry.Split('=');$script:MobyPhoneMap.Add($pair[0],$pair[1])
}

function ConvertFrom-MobyPronunciation {
    param([string]$Notation)
    # Decode the published lexical data notation. Stressed /@/ differs from schwa.
    $map=$script:MobyPhoneMap
    $out=[Text.StringBuilder]::new();$stress='';$at=0
    while($at -lt $Notation.Length){
        $ch=$Notation[$at]
        if($ch -ceq [char]39){$stress='ˈ';$at++;continue}
        if($ch -ceq ','){$stress='ˌ';$at++;continue}
        if($ch -ceq '_' -or $ch -ceq ' '){[void]$out.Append(' ');$at++;continue}
        if($ch -ceq '/'){
            $end=$Notation.IndexOf('/', $at+1)
            if($end -lt 0){return $null}
            $unit=$Notation.Substring($at+1,$end-$at-1);$at=$end+1
        }else{$unit=[string]$ch;$at++}
        if(-not $map.ContainsKey($unit)){return $null}
        $phone=$map[$unit]
        if($stress -and $unit -ceq '@'){$phone='ʌ'}
        if($stress -and $unit -ceq '@r'){$phone='ɜɹ'}
        if($phone[0] -cin 'AIOWYɑɔəæɛɜɪiʊuʌ'.ToCharArray() -and $stress){[void]$out.Append($stress);$stress=''}
        [void]$out.Append($phone)
    }
    if($stress){return $null}
    $out.ToString().Trim()
}

function Get-EnglishMobyFacts {
    param([switch]$WithoutAuthoredOverrides)
    $root=Join-Path $env:LOCALAPPDATA 'Build\PSPerception\inputs\public-domain-moby'
    [void][IO.Directory]::CreateDirectory($root)
    $commit='0a780d8d6a83909f9538b01aba8c6848b6689935'
    $sources=@(
        @('.untouched/mpron/mobypron.unc','pronunciations.txt','EAB1C6DFDA47178A36103041C118398C9A10ED1CE08C14D9D43865D60275B0D4'),
        @('.untouched/mpos/mobyposi.i','capabilities.txt','DAA369396E90E16ED8EB89B9E70E6B83939D021A7BD58077C82D3BE7FE1A2D14')
    )
    foreach($source in $sources){
        $path=Join-Path $root $source[1]
        if(-not(Test-Path -LiteralPath $path)){Invoke-WebRequest -Uri "https://raw.githubusercontent.com/elitejake/Moby-Project/$commit/$($source[0])" -OutFile $path}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $source[2]){throw 'Pinned public-domain data integrity failure.'}
    }
    $cache=Join-Path $root 'parsed-facts.tsv';$cacheReceipt=Join-Path $root 'parsed-facts.clixml'
    $parserHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((Get-Command Get-EnglishMobyFacts).ScriptBlock.ToString()+(Get-Command ConvertFrom-MobyPronunciation).ScriptBlock.ToString())))
    $cached=$null
    if((Test-Path -LiteralPath $cache) -and (Test-Path -LiteralPath $cacheReceipt)){
        $candidate=Import-Clixml -LiteralPath $cacheReceipt
        if($candidate.ParserHash -ceq $parserHash -and $candidate.Commit -ceq $commit -and $candidate.CacheHash -ceq (Get-FileHash -LiteralPath $cache).Hash -and $candidate.PronunciationSha256 -ceq $sources[0][2] -and $candidate.CapabilitiesSha256 -ceq $sources[1][2]){$cached=$candidate}
    }
    $records=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if($null -ne $cached){
        foreach($line in [IO.File]::ReadLines($cache)){
            $fields=$line.Split("`t")
            if($fields.Count -ne 7){throw 'Invalid cached lexical fact.'}
            $records.Add($fields[0],@($fields[0],[int]$fields[1],$fields[2],$fields[3],$fields[4],$fields[5],$fields[6]))
        }
        $rows=$cached.SourceRows;$excluded=$cached.ExcludedMultiwordOrLongRows;$unconverted=$cached.UnconvertedRows
    }else{
    $capabilities=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    foreach($line in [IO.File]::ReadLines((Join-Path $root 'capabilities.txt'),[Text.Encoding]::Latin1)){
        $split=$line.IndexOf([char]215)
        if($split -lt 1){continue}
        $word=$line.Substring(0,$split).ToLowerInvariant();$bits=0
        foreach($tag in $line.Substring($split+1).ToCharArray()){
            switch -CaseSensitive ($tag){'N'{$bits=$bits -bor 1};'p'{$bits=$bits -bor 1};'h'{$bits=$bits -bor 1};'V'{$bits=$bits -bor 10};'t'{$bits=$bits -bor 1026};'i'{$bits=$bits -bor 2};'A'{$bits=$bits -bor 4};'r'{$bits=$bits -bor 17}}
        }
        if($capabilities.ContainsKey($word)){$capabilities[$word]=$capabilities[$word] -bor $bits}else{$capabilities.Add($word,$bits)}
    }
    $rows=0;$excluded=0;$unconverted=0
    foreach($line in [IO.File]::ReadLines((Join-Path $root 'pronunciations.txt'),[Text.Encoding]::Latin1)){
        $rows++;$space=$line.IndexOf(' ')
        if($space -lt 1){$excluded++;continue}
        $word=$line.Substring(0,$space).ToLowerInvariant();$tag=''
        $slash=$word.LastIndexOf('/')
        if($slash -ge 0){$tag=$word.Substring($slash+1);$word=$word.Substring(0,$slash)}
        if($word.Length -gt 16 -or $word.Contains('_') -or $word.Length -eq 0){$excluded++;continue}
        $pron=ConvertFrom-MobyPronunciation -Notation $line.Substring($space+1)
        if($null -eq $pron){$unconverted++;$pron=''}
        if(-not $records.ContainsKey($word)){
            $flags=if($capabilities.ContainsKey($word)){$capabilities[$word]}else{0}
            $records.Add($word,@($word,$flags,'','','','',''))
        }
        $record=$records[$word]
        $slots=switch -CaseSensitive ($tag){'n'{@(0)};'v'{@(1,3)};'aj'{@(2)};'av'{@(4)};''{@(0,1,2,3,4)};default{@()}}
        foreach($slot in $slots){
            if($pron){
                $values=@($record[$slot+2].Split('|',[StringSplitOptions]::RemoveEmptyEntries))
                if($pron -cnotin $values){$record[$slot+2]=(@($values)+@($pron)) -join '|'}
            }
        }
        switch -CaseSensitive($tag){'n'{$record[1]=$record[1] -bor 1};'v'{$record[1]=$record[1] -bor 2};'aj'{$record[1]=$record[1] -bor 4}}
    }
    $writer=[IO.StreamWriter]::new($cache,$false,[Text.UTF8Encoding]::new($false))
    try{foreach($record in $records.Values){$writer.WriteLine($record -join "`t")}}finally{$writer.Dispose()}
    [pscustomobject]@{ParserHash=$parserHash;CacheHash=(Get-FileHash -LiteralPath $cache).Hash;Commit=$commit;PronunciationSha256=$sources[0][2];CapabilitiesSha256=$sources[1][2];SourceRows=$rows;ExcludedMultiwordOrLongRows=$excluded;UnconvertedRows=$unconverted} | Export-Clixml -LiteralPath $cacheReceipt
    }
    $overrides=0
    if(-not $WithoutAuthoredOverrides){foreach($fact in (Get-EnglishProofFacts)){$records[$fact[0]]=$fact;$overrides++}}
    $script:EnglishLexicalBuildStatistics=[pscustomobject]@{SourceRows=$rows;ExcludedMultiwordOrLongRows=$excluded;UnconvertedRows=$unconverted;CompiledIdentities=$records.Count;Commit=$commit;PronunciationSha256=$sources[0][2];CapabilitiesSha256=$sources[1][2];Rights='Original public-domain data only';AuthoredOverrides=$overrides;ParsedFactCache=$cache;ParserHash=$parserHash}
    foreach($record in $records.Values){,$record}
}

function Add-EnglishCompiledRange {
    param([Text.StringBuilder]$Index,[Text.StringBuilder]$Data,[string]$Value,[hashtable]$Interned)
    if($Value.Length -ge 4096 -or $Data.Length -ge 16777216){throw 'Compiled lexical range bound exceeded.'}
    if($Interned.ContainsKey($Value)){$start=$Interned[$Value]}else{$start=$Data.Length;$Interned[$Value]=$start;[void]$Data.Append($Value)}
    [void]$Index.Append([char](4096+($start -band 4095)))
    [void]$Index.Append([char](4096+(($start -shr 12) -band 4095)))
    [void]$Index.Append([char](4096+$Value.Length))
}

# Authored proof facts, not a corpus or a comprehensive English dictionary.
# Capabilities: nominal=1, verb=2, property=4, participle=8, pronoun=16,
# determiner=32, copula=64, by=128, person=256, time=512,
# transitive=1024, perception complement=2048, perfect auxiliary=4096.
# Phone slots: nominal, verb, property, participle, function word.
function Get-EnglishProofFacts {
    @(
        @('a',32,'','','','','ə'),
        @('alice',257,'ˈælɪs','','','',''),
        @('an',32,'','','','','ən'),
        @('are',64,'','','','','ɑɹ'),
        @('book',1027,'bˈʊk','bˈʊk','','',''),
        @('by',128,'','','','','bI'),
        @('cat',1,'kˈæt','','','',''),
        @('cellar',1,'sˈɛləɹ','','','',''),
        @('clock',1,'klˈɑk','','','',''),
        @('close',1031,'klˈOs','klˈOz','klˈOs','',''),
        @('closed',1038,'','klˈOzd','klˈOzd','klˈOzd',''),
        @('door',1,'dˈɔɹ','','','',''),
        @('duck',3,'dˈʌk','dˈʌk','','',''),
        @('eight',1,'ˈAt','','','',''),
        @('eighteen',1,'Atˈin','','','',''),
        @('eighty',1,'ˈAti','','','',''),
        @('eleven',1,'ɪlˈɛvən','','','',''),
        @('fifteen',1,'fɪftˈin','','','',''),
        @('fifty',1,'fˈɪfti','','','',''),
        @('five',1,'fˈIv','','','',''),
        @('forty',1,'fˈɔɹti','','','',''),
        @('four',1,'fˈɔɹ','','','',''),
        @('fourteen',1,'fɔɹtˈin','','','',''),
        @('had',4096,'','','','','hæd'),
        @('has',4096,'','','','','hæz'),
        @('have',4096,'','','','','hæv'),
        @('he',273,'hi','','','',''),
        @('her',305,'hɜɹ','','','','hɜɹ'),
        @('hundred',1,'hˈʌndɹəd','','','',''),
        @('i',273,'I','','','',''),
        @('is',64,'','','','','ɪz'),
        @('lead',1027,'lˈɛd','lˈid','','',''),
        @('live',6,'','lˈɪv','lˈIv','',''),
        @('music',1,'mjˈuzɪk','','','',''),
        @('nine',1,'nˈIn','','','',''),
        @('nineteen',1,'nIntˈin','','','',''),
        @('ninety',1,'nˈInti','','','',''),
        @('noon',513,'nˈun','','','',''),
        @('one',1,'wˈʌn','','','',''),
        @('permit',1027,'pˈɜɹmɪt','pəɹmˈɪt','','',''),
        @('permits',1027,'pˈɜɹmɪts','pəɹmˈɪts','','',''),
        @('present',1031,'pɹˈɛzənt','pɹɪzˈɛnt','pɹˈɛzənt','',''),
        @('presents',1027,'pɹˈɛzənts','pɹɪzˈɛnts','','',''),
        @('read',9226,'','ɹˈid','','ɹˈɛd',''),
        @('record',1027,'ɹˈɛkəɹd','ɹɪkˈɔɹd','','',''),
        @('records',1027,'ɹˈɛkəɹdz','ɹɪkˈɔɹdz','','',''),
        @('saw',3074,'','sˈɔ','','',''),
        @('seven',1,'sˈɛvən','','','',''),
        @('seventeen',1,'sɛvəntˈin','','','',''),
        @('seventy',1,'sˈɛvənti','','','',''),
        @('she',273,'ʃi','','','',''),
        @('shit',3,'ʃˈɪt','ʃˈɪt','','',''),
        @('six',1,'sˈɪks','','','',''),
        @('sixteen',1,'sɪkstˈin','','','',''),
        @('sixty',1,'sˈɪksti','','','',''),
        @('ten',1,'tˈɛn','','','',''),
        @('the',32,'','','','','ðə'),
        @('they',273,'ðA','','','',''),
        @('thirteen',1,'θɜɹtˈin','','','',''),
        @('thirty',1,'θˈɜɹti','','','',''),
        @('thousand',1,'θˈWzənd','','','',''),
        @('three',1,'θɹˈi','','','',''),
        @('twelve',1,'twˈɛlv','','','',''),
        @('twenty',1,'twˈɛnti','','','',''),
        @('two',1,'tˈu','','','',''),
        @('was',64,'','','','','wəz'),
        @('we',273,'wi','','','',''),
        @('were',64,'','','','','wɜɹ'),
        @('wind',1027,'wˈɪnd','wˈInd','','',''),
        @('zero',1,'zˈɪɹO','','','','')
    )
}

function Build-EnglishReference {
    [CmdletBinding()]
    param([string]$OutputPath,[ValidateSet('Proof','Moby','MobyOnly')][string]$Source='Moby')
    $authorSourceSha=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Build\PSPerception'))+'\'
    $OutputPath=[IO.Path]::GetFullPath($OutputPath)
    if(-not $OutputPath.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Assembly output must remain in the project build directory.'}
    if([IO.Path]::GetFileName($OutputPath) -cne 'Dev.MansfieldPlumbing.English.Phonemizer.dll'){throw 'Unexpected product assembly identity.'}
    $compiler=Join-Path $root 'inputs\pslowering-1afabe056235a570da29e268824784557d4f6cdd'
    $manifest=Import-Csv -LiteralPath (Join-Path $compiler 'verified-source.tsv') -Delimiter "`t"
    if($manifest.Count -ne 9){throw 'Incomplete pinned compiler source.'}
    foreach($row in $manifest){
        $inputFile=[IO.Path]::GetFullPath((Join-Path $compiler $row.Path))
        if(-not $inputFile.StartsWith($compiler+'\',[StringComparison]::OrdinalIgnoreCase) -or $row.Commit -cne '1afabe056235a570da29e268824784557d4f6cdd' -or (Get-FileHash -LiteralPath $inputFile -Algorithm SHA256).Hash -cne $row.Sha256){throw 'Pinned compiler integrity failure.'}
    }
    Import-Module (Join-Path $compiler 'src\Dev.MansfieldPlumbing.PowerShell.Lowering.psd1') -Force -ErrorAction Stop
    $configPath=Join-Path $root 'kokoro-config.json'
    if((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -cne '5ABB01E2403B072BF03D04FDE160443E209D7A0DAD49A423BE15196B9B43C17F'){throw 'Kokoro target specification integrity failure.'}
    # Build-only target vocabulary specification; no language dictionary ingestion.
    $vocab=(Get-EnglishKokoroSpecification).vocab
    $symbols=[char[]]::new(178)
    [Array]::Fill($symbols,[char]0xFFFF)
    foreach($pair in $vocab.GetEnumerator()){
        if($pair.Key.Length -ne 1 -or $pair.Value -lt 0 -or $pair.Value -ge 178){throw 'Unsupported target vocabulary.'}
        $symbols[$pair.Value]=$pair.Key[0]
    }
    $forms=[Text.StringBuilder]::new();$caps=[Text.StringBuilder]::new()
    $offsets=[Text.StringBuilder]::new();$phones=[Text.StringBuilder]::new();$roles=[Text.StringBuilder]::new();$alternates=[Text.StringBuilder]::new();$interned=@{};$alternateRow=0
    $facts=@(if($Source -ceq 'Moby'){Get-EnglishMobyFacts}elseif($Source -ceq 'MobyOnly'){Get-EnglishMobyFacts -WithoutAuthoredOverrides}else{Get-EnglishProofFacts})
    $ordered=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($fact in $facts){$ordered.Add($fact[0],$fact)}
    $facts=@($ordered.Values)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($fact in $facts){
        if($fact.Count -ne 7 -or $fact[0].Length -gt 16 -or -not $seen.Add($fact[0])){throw 'Invalid proof fact.'}
        [void]$forms.Append($fact[0].PadRight(16));[void]$caps.Append(([int]$fact[1]).ToString('X4'))
        foreach($pron in $fact[2..6]){
            foreach($ch in $pron.ToCharArray()){if($ch -cne '|' -and -not $vocab.ContainsKey([string]$ch)){throw 'Pronunciation contains an unsupported target symbol.'}}
        }
        $unique=@($fact[2..6] | Sort-Object -Unique -CaseSensitive)
        if($unique.Count -eq 1){Add-EnglishCompiledRange $offsets $phones $unique[0] $interned;[void]$roles.Append([char]4096)}
        else{
            Add-EnglishCompiledRange $offsets $phones '' $interned
            $alternateRow++;if($alternateRow -gt 20000){throw 'Compiled alternative index bound exceeded.'}
            [void]$roles.Append([char](4096+$alternateRow))
            foreach($pron in $fact[2..6]){Add-EnglishCompiledRange $alternates $phones $pron $interned}
        }
    }
    $template=@'
class Lexicon {
    static [int] Count() {return @COUNT@}
    static [string] Forms() {return '@FORMS@'}
    static [string] Flags() {return '@FLAGS@'}
    static [string] Offsets() {return '@OFFSETS@'}
    static [string] RoleIndexes() {return '@ROLES@'}
    static [string] Alternates() {return '@ALTERNATES@'}
    static [string] Sequences() {return '@PHONES@'}
    static [string] Form([int]$id) {
        if ($id -lt 0 -or $id -ge [Lexicon]::Count()) {throw [ArgumentOutOfRangeException]::new('id')}
        return [Lexicon]::Forms().Substring($id*16,16).Trim()
    }
    static [int] Find([string]$word) {
        if ([object]::ReferenceEquals($null,$word)) {return -1}
        if ($word.Length -gt 16) {return -1}
        [string]$key=$word.ToLowerInvariant().PadRight(16)
        [int]$low=0
        [int]$high=[Lexicon]::Count()-1
        while ($low -le $high) {
            [int]$half=($high-$low)/2
            [int]$mid=$low+$half
            [int]$cmp=[string]::CompareOrdinal([Lexicon]::Forms().Substring($mid*16,16),$key)
            if ($cmp -eq 0) {return $mid}
            if ($cmp -lt 0) {$low=$mid+1} else {$high=$mid-1}
        }
        return -1
    }
    static [int] Capabilities([int]$id) {
        if ($id -lt 0 -or $id -ge [Lexicon]::Count()) {throw [ArgumentOutOfRangeException]::new('id')}
        return [Convert]::ToInt32([Lexicon]::Flags().Substring($id*4,4),16)
    }
    static [string] Phones([int]$id,[int]$role) {
        if ($id -lt 0 -or $id -ge [Lexicon]::Count() -or $role -lt 0 -or $role -ge 5) {throw [ArgumentOutOfRangeException]::new('idOrRole')}
        [int]$alternate=[Convert]::ToInt32([Lexicon]::RoleIndexes().get_Chars($id))-4096
        [int]$slot=$id*3
        [string]$ranges=[Lexicon]::Offsets()
        if ($alternate -gt 0) {$ranges=[Lexicon]::Alternates();$slot=(($alternate-1)*5+$role)*3}
        [int]$start=[Convert]::ToInt32($ranges.get_Chars($slot))-4096
        [int]$high=[Convert]::ToInt32($ranges.get_Chars($slot+1))-4096
        $start=$start+$high*4096
        [int]$length=[Convert]::ToInt32($ranges.get_Chars($slot+2))-4096
        return [Lexicon]::Sequences().Substring($start,$length)
    }
}
class Phonology {
    static [string] Vocabulary() {return '@VOCAB@'}
    static [int] SymbolId([char]$phone) {
        if ([Convert]::ToInt32($phone) -eq 65535) {return -1}
        return [Phonology]::Vocabulary().IndexOf($phone)
    }
}
'@
    $generated=$template.Replace('@COUNT@',[string]$facts.Count).Replace('@FORMS@',$forms.ToString().Replace("'","''")).Replace('@FLAGS@',$caps.ToString()).Replace('@OFFSETS@',$offsets.ToString()).Replace('@ROLES@',$roles.ToString()).Replace('@ALTERNATES@',$alternates.ToString()).Replace('@PHONES@',$phones.ToString()).Replace('@VOCAB@',(-join $symbols))
    $directory=[IO.Path]::GetDirectoryName($OutputPath)
    [void][IO.Directory]::CreateDirectory($directory)
    $sourceFile=Join-Path $directory 'compiled-reference.ps1'
    if(Test-Path -LiteralPath $sourceFile){Copy-Item -LiteralPath $sourceFile -Destination ($sourceFile+'.before') -Force}
    if(Test-Path -LiteralPath $OutputPath){Copy-Item -LiteralPath $OutputPath -Destination ($OutputPath+'.before') -Force}
    [IO.File]::WriteAllText($sourceFile,$generated,[Text.UTF8Encoding]::new($false))
    $result=Export-LoweredAssembly -SourcePath $sourceFile -ClassName Lexicon -OutputPath $OutputPath -Deterministic
    $inspection=Test-LoweredAssembly -AssemblyPath $OutputPath
    if($inspection.AssemblyReferences.Count -ne 1 -or $inspection.AssemblyReferences[0] -cne 'System.Private.CoreLib'){throw 'Unexpected compiled reference dependency.'}
    $receipt=[pscustomobject]@{Assembly=$inspection;LexicalIdentities=$facts.Count;SourceSha256=$authorSourceSha;CompilerCommit='1afabe056235a570da29e268824784557d4f6cdd';DataOrigin=$Source;DataStatistics=if($Source -ceq 'Moby'){$script:EnglishLexicalBuildStatistics}else{$null};TargetVocabularySha256=(Get-FileHash -LiteralPath $configPath).Hash;Types=$result.Classes;Methods=$result.EmittedMethods;LanguageMode=[string]$ExecutionContext.SessionState.LanguageMode;Runtime=[Runtime.InteropServices.RuntimeInformation]::FrameworkDescription}
    $receipt | Export-Clixml -LiteralPath (Join-Path $directory 'build-receipt.clixml')
    $receipt
}

class EnglishOccurrence {
    [int]$Identity
    [int]$LexicalId
    [int]$Capabilities
    [string]$Text
    [int]$Start
    [int]$End
    [string]$Kind='Word'
    [object]$Value
}
class EnglishNominal {
    [EnglishOccurrence]$Head
    [EnglishOccurrence]$Determiner
    [EnglishOccurrence[]]$Modifiers=@()
    [int[]]$Dependencies=@()
}
class EnglishClause {
    [string]$Voice
    [string]$Tense
    [EnglishNominal]$Subject
    [EnglishOccurrence]$Predicate
    [EnglishNominal]$Object
    [EnglishOccurrence]$Auxiliary
    [EnglishNominal]$Agent
    [EnglishNominal]$Time
    [EnglishClause]$Complement
    [int[]]$Dependencies=@()
}
class EnglishRequirement {
    [EnglishNominal]$Subject
    [EnglishOccurrence]$Operation
    [string]$Missing
    [int[]]$Dependencies=@()
}
function New-EnglishRequirement {
    [CmdletBinding(DefaultParameterSetName='Operation')]
    param(
        [Parameter(Mandatory,ParameterSetName='Operation')][EnglishNominal]$Subject,
        [Parameter(Mandatory,ParameterSetName='Operation')][ValidateScript({($_.Capabilities -band (2+64+4096)) -ne 0})][EnglishOccurrence]$Operation,
        [Parameter(Mandatory,ParameterSetName='Determiner')][ValidateScript({($_.Capabilities -band 32) -ne 0})][EnglishOccurrence]$Determiner
    )
    $r=[EnglishRequirement]::new()
    if($PSCmdlet.ParameterSetName -ceq 'Determiner'){$r.Operation=$Determiner;$r.Missing='NominalHead';$r.Dependencies=@($Determiner.Identity);return $r}
    $r.Subject=$Subject;$r.Operation=$Operation
    $r.Missing=if(($Operation.Capabilities -band (64+4096)) -ne 0){'Predicate'}elseif(($Operation.Capabilities -band 1024) -ne 0){'Object'}else{'None'}
    $r.Dependencies=$Subject.Dependencies+@($Operation.Identity)
    $r
}

function New-EnglishNominal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({($_.Capabilities -band 1) -ne 0})][EnglishOccurrence]$Head,
        [ValidateScript({($_.Capabilities -band 32) -ne 0})][EnglishOccurrence]$Determiner,
        [ValidateScript({($_.Capabilities -band 4) -ne 0})][EnglishOccurrence[]]$Modifiers=@()
    )
    $n=[EnglishNominal]::new();$n.Head=$Head;$n.Determiner=$Determiner;$n.Modifiers=$Modifiers
    $n.Dependencies=@($Head.Identity)+@($Modifiers | ForEach-Object Identity)
    if($null -ne $Determiner){$n.Dependencies+=@($Determiner.Identity)}
    $n
}

function Invoke-EnglishClause {
    [CmdletBinding(DefaultParameterSetName='Active')]
    param(
        [Parameter(Mandatory,ParameterSetName='Active')]
        [Parameter(Mandatory,ParameterSetName='Stative')][EnglishNominal]$Subject,
        [Parameter(Mandatory,ParameterSetName='Active')][ValidateScript({($_.Capabilities -band 2) -ne 0})][EnglishOccurrence]$Verb,
        [Parameter(ParameterSetName='Active')][EnglishNominal]$Object,
        [Parameter(Mandatory,ParameterSetName='Passive')][EnglishNominal]$Patient,
        [Parameter(Mandatory,ParameterSetName='Passive')][ValidateScript({($_.Capabilities -band 8) -ne 0})][EnglishOccurrence]$Participle,
        [Parameter(Mandatory,ParameterSetName='Stative')][ValidateScript({($_.Capabilities -band 4) -ne 0})][EnglishOccurrence]$Property,
        [Parameter(Mandatory,ParameterSetName='Passive')]
        [Parameter(Mandatory,ParameterSetName='Stative')][ValidateScript({($_.Capabilities -band 64) -ne 0})][EnglishOccurrence]$Copula,
        [Parameter(ParameterSetName='Active')][ValidateScript({($_.Capabilities -band 4096) -ne 0})][EnglishOccurrence]$Perfect,
        [Parameter(ParameterSetName='Active')][ValidateSet('Unspecified','Present','Past','Perfect')][string]$Tense='Unspecified'
    )
    $c=[EnglishClause]::new();$c.Voice=$PSCmdlet.ParameterSetName;$c.Tense=$Tense
    if($PSCmdlet.ParameterSetName -ceq 'Passive'){$c.Subject=$Patient;$c.Predicate=$Participle;$c.Auxiliary=$Copula}
    elseif($PSCmdlet.ParameterSetName -ceq 'Stative'){$c.Subject=$Subject;$c.Predicate=$Property;$c.Auxiliary=$Copula}
    else{
        if(($Verb.Capabilities -band 1024) -ne 0 -and $null -eq $Object){throw 'Transitive operation requires an object.'}
        $c.Subject=$Subject;$c.Predicate=$Verb;$c.Object=$Object;$c.Auxiliary=$Perfect
    }
    $c.Dependencies=$c.Subject.Dependencies+@($c.Predicate.Identity)
    if($null -ne $c.Object){$c.Dependencies+=$c.Object.Dependencies}
    if($null -ne $c.Auxiliary){$c.Dependencies+=@($c.Auxiliary.Identity)}
    $c
}

function Add-EnglishRelation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][EnglishClause]$Clause,
        [Parameter(Mandatory)][ValidateScript({($_.Capabilities -band 128) -ne 0})][EnglishOccurrence]$Relation,
        [Parameter(Mandatory)][EnglishNominal]$Complement
    )
    $c=[EnglishClause]::new()
    foreach($name in @('Voice','Subject','Predicate','Object','Auxiliary','Agent','Time','Complement','Dependencies')){$c.$name=$Clause.$name}
    if(($Complement.Head.Capabilities -band 512) -ne 0){$c.Time=$Complement}
    elseif(($Complement.Head.Capabilities -band 256) -ne 0 -and $c.Voice -ceq 'Passive'){$c.Agent=$Complement}
    else{throw 'Unsupported relation interpretation.'}
    $c.Dependencies+=$Complement.Dependencies+@($Relation.Identity)
    $c
}

function Import-EnglishReference {
    param([string]$Path)
    $path=[IO.Path]::GetFullPath($Path)
    if($script:EnglishReferenceCache.ContainsKey($path)){return $script:EnglishReferenceCache[$path]}
    $receiptPath=Join-Path ([IO.Path]::GetDirectoryName($path)) 'build-receipt.clixml'
    $receipt=Import-Clixml -LiteralPath $receiptPath
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $receipt.Assembly.SHA256){throw 'Compiled reference integrity failure.'}
    $assembly=[Reflection.Assembly]::LoadFrom($path)
    if($assembly.GetName().Name -cne 'Dev.MansfieldPlumbing.English.Phonemizer'){throw 'Unexpected reference identity.'}
    $lex=$assembly.GetType('Lexicon',$true);$ph=$assembly.GetType('Phonology',$true)
    $reference=[pscustomobject]@{
        Assembly=$assembly
        Find=[Func[string,int]]$lex.GetMethod('Find').CreateDelegate([Func[string,int]])
        Flags=[Func[int,int]]$lex.GetMethod('Capabilities').CreateDelegate([Func[int,int]])
        Phones=[Func[int,int,string]]$lex.GetMethod('Phones').CreateDelegate([Func[int,int,string]])
        Form=[Func[int,string]]$lex.GetMethod('Form').CreateDelegate([Func[int,string]])
        SymbolId=[Func[char,int]]$ph.GetMethod('SymbolId').CreateDelegate([Func[char,int]])
        Count=$lex.GetMethod('Count').Invoke($null,@())
        Onsets=@{}
    }
    $script:EnglishReferenceCache[$path]=$reference
    $reference
}

function New-EnglishCandidate {
    param($From=$null)
    $c=[pscustomobject]@{Subject=$null;Determiner=$null;Modifiers=@();Auxiliary=$null;Predicate=$null;Object=$null;Clause=$null;Relation=$null;Requirement=$null;PredicateRole=1;Tense='Unspecified';Phase='Subject';Voice='Active';Status='Pending';Choices=@{};Bindings=@();Need='Nominal';DependencyIds=@()}
    if($null -ne $From){
        foreach($p in $From.PSObject.Properties){$c.($p.Name)=$p.Value}
        $c.Choices=@{}+$From.Choices;$c.Bindings=@($From.Bindings);$c.Modifiers=@($From.Modifiers)
    }
    $c
}

function New-EnglishContext {
    param([string]$ReferencePath=$AssemblyPath,[switch]$Profile,[string]$Corrections=$CorrectionPath)
    $table=if($Corrections -and (Test-Path -LiteralPath $Corrections)){Import-EnglishCorrections -Path $Corrections}else{@{}}
    $words=@{};foreach($key in $table.Keys){$words[$key.Split(':')[0]]=$true}
    [pscustomobject]@{
        Reference=(Import-EnglishReference $ReferencePath)
        Text='';Occurrences=[Collections.Generic.List[EnglishOccurrence]]::new()
        Candidates=@(New-EnglishCandidate);Withdrawn=[Collections.Generic.List[object]]::new()
        Revision=0;Invocations=0;Trace=[Collections.Generic.List[object]]::new();Evidence=@{}
        MaximumCandidates=16;MaximumOccurrences=256;Boundary=$false
        Profile=if($Profile){@{}}else{$null}
        Corrections=$table;CorrectionWords=$words
    }
}

function Start-EnglishMeasure {
    param([string]$Phase)
    [pscustomobject]@{Phase=$Phase;Ticks=[Diagnostics.Stopwatch]::GetTimestamp();Allocated=[GC]::GetAllocatedBytesForCurrentThread()}
}
function Stop-EnglishMeasure {
    param($Context,$Measurement)
    $ticks=[Diagnostics.Stopwatch]::GetTimestamp()-$Measurement.Ticks
    $bytes=[GC]::GetAllocatedBytesForCurrentThread()-$Measurement.Allocated
    if(-not $Context.Profile.ContainsKey($Measurement.Phase)){$Context.Profile[$Measurement.Phase]=[pscustomobject]@{Calls=0;Ticks=[long]0;AllocatedBytes=[long]0}}
    $entry=$Context.Profile[$Measurement.Phase];$entry.Calls++;$entry.Ticks+=$ticks;$entry.AllocatedBytes+=$bytes
}

function Add-EnglishBindingTrace {
    param($Context,$Candidate,[string]$Command,[hashtable]$Arguments,$Result)
    if($null -ne $Context.Profile){$measurement=Start-EnglishMeasure 'TraceMaterialization'}
    $definition=(Get-Command -Name $Command -CommandType Function).ScriptBlock.Ast
    $binding=[pscustomobject]@{Revision=$Context.Revision;Command=$Command;InvocationTemplate=$Command+' '+(($Arguments.Keys | Sort-Object | ForEach-Object {'-'+$_+' $bound.'+$_}) -join ' ');SmaAst=$definition.GetType().Name;DefinitionFile=$definition.Extent.File;DefinitionLine=$definition.Extent.StartLineNumber;Arguments=@($Arguments.GetEnumerator() | Sort-Object Key | ForEach-Object {[pscustomobject]@{Parameter=$_.Key;Type=$_.Value.GetType().FullName}});OutputType=$Result.GetType().FullName;Dependencies=@($Result.Dependencies)}
    $Candidate.Bindings+=@($binding);$Context.Trace.Add($binding);$Context.Invocations++
    if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $measurement}
}

function Complete-EnglishNominal {
    param($Context,$Candidate,[EnglishOccurrence]$Occurrence)
    $args=@{Head=$Occurrence;Modifiers=[EnglishOccurrence[]]$Candidate.Modifiers}
    if($null -ne $Candidate.Determiner){$args.Determiner=$Candidate.Determiner}
    # Fixed command identity and file-authored body; input supplies data only.
    if($null -ne $Context.Profile){$measurement=Start-EnglishMeasure 'NativeCommands'}
    $nominal=New-EnglishNominal @args
    if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $measurement}
    Add-EnglishBindingTrace $Context $Candidate 'New-EnglishNominal' $args $nominal
    $Candidate.Choices[$Occurrence.Identity]=0
    if($null -ne $Candidate.Determiner){$Candidate.Choices[$Candidate.Determiner.Identity]=4}
    foreach($mod in $Candidate.Modifiers){$Candidate.Choices[$mod.Identity]=2}
    $Candidate.Determiner=$null;$Candidate.Modifiers=@()
    $nominal
}

function Complete-EnglishClause {
    param($Context,$Candidate)
    $args=@{}
    if($Candidate.Voice -ceq 'Passive'){$args=@{Patient=$Candidate.Subject;Participle=$Candidate.Predicate;Copula=$Candidate.Auxiliary};$role=3}
    elseif($Candidate.Voice -ceq 'Stative'){$args=@{Subject=$Candidate.Subject;Property=$Candidate.Predicate;Copula=$Candidate.Auxiliary};$role=2}
    else{
        $args=@{Subject=$Candidate.Subject;Verb=$Candidate.Predicate;Tense=$Candidate.Tense};$role=$Candidate.PredicateRole
        if($null -ne $Candidate.Object){$args.Object=$Candidate.Object}
        if($null -ne $Candidate.Auxiliary){$args.Perfect=$Candidate.Auxiliary;$role=3}
    }
    if($null -ne $Context.Profile){$measurement=Start-EnglishMeasure 'NativeCommands'}
    $clause=Invoke-EnglishClause @args
    if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $measurement}
    Add-EnglishBindingTrace $Context $Candidate 'Invoke-EnglishClause' $args $clause
    $Candidate.Choices[$Candidate.Predicate.Identity]=$role
    if($null -ne $Candidate.Auxiliary){$Candidate.Choices[$Candidate.Auxiliary.Identity]=4}
    $Candidate.Clause=$clause;$Candidate.Phase='Extension';$Candidate.Status='Extensible';$Candidate.Need='OptionalRelation'
}

function Add-EnglishOccurrence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][EnglishOccurrence]$Occurrence)
    if($Context.Occurrences.Count -ge $Context.MaximumOccurrences){throw 'Utterance occurrence bound exceeded.'}
    $Occurrence.Identity=$Context.Occurrences.Count;$Context.Occurrences.Add($Occurrence);$Context.Revision++
    if($Occurrence.Kind -ceq 'Boundary'){$Context.Boundary=$Occurrence.Text -cin @('.','!','?');return}
    $Context.Boundary=$false
    $next=[Collections.Generic.List[object]]::new()
    foreach($prior in $Context.Candidates){
        $c=New-EnglishCandidate $prior
        if($c.Status -cin @('Unsupported','Contradictory')){$next.Add($c);continue}
        $f=$Occurrence.Capabilities
        if($Occurrence.LexicalId -lt 0){$c.Status='Unsupported';$c.Need='UnknownLexicalIdentity';$next.Add($c);continue}
        if($c.Phase -ceq 'Subject' -and $Occurrence.Identity -eq 0 -and $Occurrence.Text.ToLowerInvariant() -ceq 'please'){
            $c.Choices[$Occurrence.Identity]=4;$c.Need='ImperativePredicate';$next.Add($c);continue
        }
        if($c.Phase -ceq 'Subject' -and ($Occurrence.Identity -eq 0 -or ($Occurrence.Identity -eq 1 -and $Context.Occurrences[0].Text.ToLowerInvariant() -ceq 'please')) -and $Occurrence.Text.ToLowerInvariant() -cin @('play','push','press','record') -and ($f -band 2) -ne 0){
            $head=[EnglishOccurrence]::new();$head.Identity=-1;$head.Text='you';$head.Capabilities=1
            $subject=[EnglishNominal]::new();$subject.Head=$head;$subject.Modifiers=@();$subject.Dependencies=@()
            $c.Subject=$subject;$c.Phase='Predicate';$c.Need='Predicate'
        }
        if($c.Phase -cin @('Subject','Object','RelationComplement')){
            if(($f -band 32) -ne 0 -and $null -eq $c.Determiner){
                $det=New-EnglishCandidate $c;$det.Determiner=$Occurrence;$det.Choices[$Occurrence.Identity]=4;$det.Status='Pending';$det.Need='NominalHead';$next.Add($det)
                $args=@{Determiner=$Occurrence}
                if($null -ne $Context.Profile){$measurement=Start-EnglishMeasure 'NativeCommands'}
                $det.Requirement=New-EnglishRequirement @args
                if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $measurement}
                Add-EnglishBindingTrace $Context $det 'New-EnglishRequirement' $args $det.Requirement
            }
            if(($f -band 4) -ne 0 -and $null -ne $c.Determiner){
                $mod=New-EnglishCandidate $c;$mod.Modifiers+=@($Occurrence);$mod.Choices[$Occurrence.Identity]=2;$mod.Need='NominalHead';$next.Add($mod)
            }
            if(($f -band 1) -ne 0){
                $nominal=Complete-EnglishNominal $Context $c $Occurrence
                switch($c.Phase){
                    'Subject' {$c.Subject=$nominal;$c.Phase='Predicate';$c.Status='Extensible';$c.Need='Predicate'}
                    'Object' {$c.Object=$nominal;Complete-EnglishClause $Context $c}
                    'RelationComplement' {
                        if(($f -band 512) -ne 0 -or (($f -band 256) -ne 0 -and $c.Voice -ceq 'Passive')){
                            $args=@{Clause=$c.Clause;Relation=$c.Relation;Complement=$nominal}
                            if($null -ne $Context.Profile){$measurement=Start-EnglishMeasure 'NativeCommands'}
                            $result=Add-EnglishRelation @args
                            if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $measurement}
                            Add-EnglishBindingTrace $Context $c 'Add-EnglishRelation' $args $result
                            $c.Clause=$result;$c.Phase='Extension';$c.Status='Extensible';$c.Need='OptionalRelation'
                        }else{$c.Status='Unsupported';$c.Need='RelationSense';$Context.Withdrawn.Add([pscustomobject]@{Revision=$Context.Revision;Reason='UnsupportedRelationSense';Candidate=$prior})}
                    }
                }
                $next.Add($c)
            }
            if(($f -band (1+4+32)) -eq 0){$c.Status='Contradictory';$c.Need='NominalHead';$next.Add($c)}
        }
        elseif($c.Phase -ceq 'Predicate'){
            if(($f -band (64+4096)) -ne 0){
                $args=@{Subject=$c.Subject;Operation=$Occurrence}
                if($null -ne $Context.Profile){$measurement=Start-EnglishMeasure 'NativeCommands'}
                $c.Requirement=New-EnglishRequirement @args
                if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $measurement}
                Add-EnglishBindingTrace $Context $c 'New-EnglishRequirement' $args $c.Requirement
                $c.Auxiliary=$Occurrence;$c.Choices[$Occurrence.Identity]=4;$c.Phase='AfterAuxiliary';$c.Status='Pending';$c.Need=$c.Requirement.Missing;$next.Add($c)
            }
            elseif(($f -band 2) -ne 0){
                $c.Predicate=$Occurrence;$c.Choices[$Occurrence.Identity]=1
                $args=@{Subject=$c.Subject;Operation=$Occurrence}
                if($null -ne $Context.Profile){$measurement=Start-EnglishMeasure 'NativeCommands'}
                $c.Requirement=New-EnglishRequirement @args
                if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $measurement}
                Add-EnglishBindingTrace $Context $c 'New-EnglishRequirement' $args $c.Requirement
                if(($f -band 1024) -ne 0){$c.Phase='Object';$c.Status='Pending';$c.Need='Object'}else{Complete-EnglishClause $Context $c}
                $next.Add($c)
                if(($f -band 8192) -ne 0){
                    $past=New-EnglishCandidate $c;$past.PredicateRole=3;$past.Tense='Past';$past.Choices[$Occurrence.Identity]=3
                    $c.Tense='Present'
                    if($past.Phase -ceq 'Extension'){Complete-EnglishClause $Context $past}
                    $next.Add($past)
                }
            }else{$c.Status='Contradictory';$c.Need='CallablePredicate';$next.Add($c)}
        }
        elseif($c.Phase -ceq 'AfterAuxiliary'){
            if(($c.Auxiliary.Capabilities -band 4096) -ne 0 -and ($f -band 8) -ne 0){
                $c.Predicate=$Occurrence;$c.Choices[$Occurrence.Identity]=3
                if(($f -band 1024) -ne 0){$c.Phase='Object';$c.Need='Object'}else{Complete-EnglishClause $Context $c}
                $next.Add($c)
            }elseif(($c.Auxiliary.Capabilities -band 64) -ne 0){
                if(($f -band 8) -ne 0){$passive=New-EnglishCandidate $c;$passive.Predicate=$Occurrence;$passive.Voice='Passive';Complete-EnglishClause $Context $passive;$next.Add($passive)}
                if(($f -band 4) -ne 0){$stative=New-EnglishCandidate $c;$stative.Predicate=$Occurrence;$stative.Voice='Stative';Complete-EnglishClause $Context $stative;$next.Add($stative)}
                if(($f -band 12) -eq 0){$c.Status='Unsupported';$c.Need='CopularComplement';$next.Add($c)}
            }else{$c.Status='Contradictory';$c.Need='Participle';$next.Add($c)}
        }
        elseif($c.Phase -ceq 'Extension'){
            if(($f -band 128) -ne 0){$c.Relation=$Occurrence;$c.Choices[$Occurrence.Identity]=4;$c.Phase='RelationComplement';$c.Status='Pending';$c.Need='RelationComplement';$next.Add($c)}
            elseif(($c.Predicate.Capabilities -band 2048) -ne 0 -and ($f -band 2) -ne 0 -and ($f -band 1024) -eq 0){
                $args=@{Subject=$c.Object;Verb=$Occurrence}
                if($null -ne $Context.Profile){$measurement=Start-EnglishMeasure 'NativeCommands'}
                $embedded=Invoke-EnglishClause @args
                if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $measurement}
                Add-EnglishBindingTrace $Context $c 'Invoke-EnglishClause' $args $embedded
                $parent=[EnglishClause]::new()
                foreach($name in @('Voice','Subject','Predicate','Object','Auxiliary','Dependencies')){$parent.$name=$c.Clause.$name}
                $parent.Complement=$embedded;$parent.Dependencies+=$embedded.Dependencies
                $c.Clause=$parent;$c.Choices[$Occurrence.Identity]=1;$next.Add($c)
            }else{$c.Status='Unsupported';$c.Need='AdditionalConstruction';$next.Add($c)}
        }
    }
    if($next.Count -gt $Context.MaximumCandidates){throw 'Grammatical alternative bound exceeded; input not silently pruned.'}
    $Context.Candidates=$next.ToArray()
}

function Add-EnglishText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][AllowEmptyString()][string]$Chunk)
    if($Context.Text.Length+$Chunk.Length -gt 8192){throw 'Source extent bound exceeded.'}
    # Chunks end at lexical boundaries. Arbitrary mid-word chunks need buffering.
    $base=$Context.Text.Length;$Context.Text+=$Chunk;$at=0
    while($at -lt $Chunk.Length){
        if([char]::IsWhiteSpace($Chunk[$at])){$at++;continue}
        if($null -ne $Context.Profile){$scan=Start-EnglishMeasure 'TokenScan'}
        $start=$at;$kind='Word'
        if([char]::IsLetterOrDigit($Chunk[$at]) -or $Chunk[$at] -ceq '$'){
            $at++
            while($at -lt $Chunk.Length -and ([char]::IsLetterOrDigit($Chunk[$at]) -or $Chunk[$at] -cin @([char]39,[char]0x2019))){$at++}
        }else{$kind='Boundary';$at++}
        $o=[EnglishOccurrence]::new();$o.Text=$Chunk.Substring($start,$at-$start);$o.Start=$base+$start;$o.End=$base+$at;$o.Kind=$kind
        if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $scan;$lookup=Start-EnglishMeasure 'ReferenceLookup'}
        $o.LexicalId=if($kind -ceq 'Word'){$Context.Reference.Find.Invoke($o.Text)}else{-1}
        if($o.LexicalId -ge 0){$o.Capabilities=$Context.Reference.Flags.Invoke($o.LexicalId)}
        if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $lookup;$activation=Start-EnglishMeasure 'ConstructionActivation'}
        Add-EnglishOccurrence $Context $o
        if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $activation}
    }
}

function Get-EnglishResult {
    param($Context)
    if($null -ne $Context.Profile){$filter=Start-EnglishMeasure 'EvidenceFiltering'}
    $viable=@($Context.Candidates | Where-Object Status -cnotin @('Unsupported','Contradictory'))
    $contextRejected=[Collections.Generic.List[object]]::new()
    foreach($constraint in $Context.Evidence.Values){
        $accepted=[Collections.Generic.List[object]]::new()
        foreach($candidate in $viable){
            if(-not $candidate.Choices.ContainsKey($constraint.OccurrenceIdentity) -or $candidate.Choices[$constraint.OccurrenceIdentity] -in $constraint.Roles){$accepted.Add($candidate)}
            else{$contextRejected.Add([pscustomobject]@{Revision=$Context.Revision;Reason='LinkedObjectGraphConstraint';Evidence=$constraint.Id;Candidate=$candidate})}
        }
        $viable=$accepted.ToArray()
    }
    $status=if($viable.Count -gt 1){'Ambiguous'}elseif($viable.Count -eq 1){if($Context.Boundary -and $viable[0].Status -ceq 'Extensible' -and $null -ne $viable[0].Clause){'Resolved'}else{$viable[0].Status}}elseif(@($Context.Candidates | Where-Object Status -ceq 'Unsupported').Count){'Unsupported'}else{'Contradictory'}
    if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $filter;$projection=Start-EnglishMeasure 'ProjectionAndResult'}
    $tokens=[Collections.Generic.List[object]]::new();$parts=[Collections.Generic.List[string]]::new();$ids=[Collections.Generic.List[int]]::new();$unresolved=[Collections.Generic.List[object]]::new();$cursor=0
    foreach($o in $Context.Occurrences){
        $phone=$null;$roles=@();$alternatives=@();$reason=$null
        if($o.Kind -ceq 'Boundary'){
            if($Context.Reference.SymbolId.Invoke($o.Text[0]) -ge 0){$phone=$o.Text}else{$reason='UnsupportedSymbol'}
        }elseif($o.LexicalId -lt 0){$reason='UnknownLexicalIdentity'}
        elseif($viable.Count -eq 0){$reason='NoAdmittedRelationship'}
        else{
            $roles=@($viable | ForEach-Object {if($_.Choices.ContainsKey($o.Identity)){$_.Choices[$o.Identity]}else{-1}} | Sort-Object -Unique)
            if($roles -contains -1){$reason='PendingRole'}
            else{
                $alternatives=@($roles | ForEach-Object {$Context.Reference.Phones.Invoke($o.LexicalId,$_).Split('|',[StringSplitOptions]::RemoveEmptyEntries)} | Sort-Object -Unique -CaseSensitive)
                if($alternatives.Count -eq 1 -and $alternatives[0].Length -gt 0){$phone=$alternatives[0]}else{$reason='PronunciationAmbiguous'}
            }
        }
        # Unambiguous lexical projection does not require a resolved clause.
        if($null -eq $phone -and $o.LexicalId -ge 0){
            $all=@(0..4 | ForEach-Object {$Context.Reference.Phones.Invoke($o.LexicalId,$_).Split('|',[StringSplitOptions]::RemoveEmptyEntries)} | Sort-Object -Unique -CaseSensitive)
            if($all.Count -eq 1){$phone=$all[0];$reason=$null}
        }
        $pronunciationSource='CompiledLexicon'
        if($o.Kind -ceq 'Word' -and $roles.Count -eq 1 -and $roles[0] -ge 0 -and $Context.CorrectionWords.ContainsKey($o.Text.ToLowerInvariant())){
            $key=Get-EnglishCorrectionKey -Context $Context -Occurrence $o -Role $roles[0]
            if($Context.Corrections.ContainsKey($key)){$phone=$Context.Corrections[$key];$reason=$null;$pronunciationSource='ZiraCorrection'}
        }
        $start=$null;$end=$null
        if($null -ne $phone){
            if($parts.Count -gt 0){$ids.Add(16);$cursor++}
            $start=$cursor
            foreach($ch in $phone.ToCharArray()){
                $symbol=$Context.Reference.SymbolId.Invoke($ch)
                if($symbol -lt 0){throw 'Compiled phone outside target vocabulary.'}
                $ids.Add($symbol);$cursor++
            }
            $end=$cursor;$parts.Add($phone)
        }
        $record=[pscustomobject]@{Identity=$o.Identity;LexicalId=$o.LexicalId;Word=$o.Text;SourceStart=$o.Start;SourceEnd=$o.End;Pron=$phone;PronunciationSource=$pronunciationSource;SymbolIds=if($phone){[int[]]@($phone.ToCharArray() | ForEach-Object {$Context.Reference.SymbolId.Invoke($_)})}else{@()};Roles=$roles;Alternatives=$alternatives;Status=if($phone){'Valid'}else{$reason};EmissionStart=$start;EmissionEnd=$end}
        $tokens.Add($record);if($null -ne $reason){$unresolved.Add($record)}
    }
    [pscustomobject]@{
        OriginalText=$Context.Text;ProjectedText=$null;Reversible=$true
        KokoroPhones=if($unresolved.Count -eq 0){$parts -join ' '}else{$null}
        SupportedPhones=$parts -join ' ';SymbolIds=$ids.ToArray();Tokens=$tokens.ToArray()
        Complete=$unresolved.Count -eq 0;GrammarStatus=$status;PronunciationStatus=if($unresolved.Count -eq 0){'Resolved'}else{'UnsupportedOrPending'}
        Candidates=$viable;RetainedCandidates=$Context.Candidates;UnresolvedSpans=$unresolved.ToArray();OovSpans=@($unresolved | Where-Object Status -ceq 'UnknownLexicalIdentity')
        AmbiguousDecisions=@($tokens | Where-Object {$_.Roles.Count -gt 1 -or $_.Alternatives.Count -gt 1})
        Bindings=$Context.Trace.ToArray();Withdrawn=@($Context.Withdrawn.ToArray())+@($contextRejected.ToArray());Revision=$Context.Revision
        Pending=@($viable | Where-Object Status -ceq 'Pending' | ForEach-Object Need)
        Execution='SMA named parameter binding';ReferenceAssembly=$Context.Reference.Assembly.GetName().Name
    }
    if($null -ne $Context.Profile){Stop-EnglishMeasure $Context $projection}
}

function Add-EnglishContextEvidence {
    [CmdletBinding(DefaultParameterSetName='Entity')]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateRange(0,255)][int]$OccurrenceIdentity,
        [Parameter(Mandatory,ParameterSetName='Entity')][EnglishNominal]$Entity,
        [Parameter(Mandatory,ParameterSetName='Event')][EnglishClause]$Event,
        [Parameter(Mandatory)][ValidateLength(1,256)][string]$EvidenceIdentity
    )
    if($OccurrenceIdentity -ge $Context.Occurrences.Count){throw 'Evidence target is outside the active source.'}
    $occurrence=$Context.Occurrences[$OccurrenceIdentity]
    $referent=if($PSCmdlet.ParameterSetName -ceq 'Entity'){$Entity.Head}else{$Event.Predicate}
    if($occurrence.LexicalId -lt 0 -or $referent.LexicalId -ne $occurrence.LexicalId){throw 'Explicit lexical reference link is required.'}
    # The caller supplies a grounded link, not a proximity heuristic or POS guess.
    # Candidate graphs stay retained; withdrawing evidence restores alternatives.
    $Context.Evidence[$EvidenceIdentity]=[pscustomobject]@{Id=$EvidenceIdentity;OccurrenceIdentity=$OccurrenceIdentity;Referent=$referent;Roles=if($PSCmdlet.ParameterSetName -ceq 'Entity'){@(0)}else{@(1,3)}}
    Get-EnglishResult $Context
}

function Remove-EnglishContextEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$EvidenceIdentity)
    $Context.Evidence.Remove($EvidenceIdentity)
    Get-EnglishResult $Context
}

function Invoke-EnglishPhonemizer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,$Context=$null,[string]$ReferencePath=$AssemblyPath)
    $start=[Diagnostics.Stopwatch]::StartNew()
    if($null -eq $Context){
        $driver=Import-EnglishCoreDriver -ReferencePath $ReferencePath
        $result=$driver.Run.Invoke($Text)
        $result | Add-Member -NotePropertyName Timing -NotePropertyValue ([pscustomobject]@{TotalMs=$start.Elapsed.TotalMilliseconds;BinderInvocations=0})
        return $result
    }
    Add-EnglishText -Context $Context -Chunk $Text
    $result=Get-EnglishResult $Context
    $result | Add-Member -NotePropertyName Timing -NotePropertyValue ([pscustomobject]@{TotalMs=$start.Elapsed.TotalMilliseconds;BinderInvocations=$Context.Invocations})
    $result
}

function Get-EnglishCoreTemplate {
    @'
class CoreOccurrence {
    CoreOccurrence() {}
    [int]$Identity
    [int]$LexicalId
    [int]$Capabilities
    [string]$Text
    [int]$Start
    [int]$End
    [string]$Kind
}
class CoreNominal {
    CoreNominal() {}
    [CoreOccurrence]$Head
    [CoreOccurrence]$Determiner
    [CoreOccurrence[]]$Modifiers
    [int[]]$Dependencies
}
class CoreClause {
    CoreClause() {}
    [string]$Voice
    [string]$Tense
    [CoreNominal]$Subject
    [CoreOccurrence]$Predicate
    [CoreNominal]$Object
    [CoreOccurrence]$Auxiliary
    [CoreNominal]$Agent
    [CoreNominal]$Time
    [CoreClause]$Complement
    [int[]]$Dependencies
}
class CoreCandidate {
    [CoreNominal]$Subject
    [CoreOccurrence]$Determiner
    [CoreOccurrence[]]$Modifiers
    [CoreOccurrence]$Auxiliary
    [CoreOccurrence]$Predicate
    [CoreNominal]$Object
    [CoreClause]$Clause
    [CoreOccurrence]$Relation
    [int]$PredicateRole=1
    [string]$Tense='Unspecified'
    [string]$Phase='Subject'
    [string]$Voice='Active'
    [string]$Status='Pending'
    [string]$Need='Nominal'
    [int[]]$Choices
    CoreCandidate() {
        $this.Modifiers=[CoreOccurrence[]]::new(0)
        $this.Choices=[int[]]::new(256)
        for([int]$i=0;$i -lt 256;$i++){$this.Choices[$i]=-1}
    }
    [CoreCandidate] Copy() {
        [CoreCandidate]$c=[CoreCandidate]::new()
        $c.Subject=$this.Subject;$c.Determiner=$this.Determiner;$c.Modifiers=$this.Modifiers
        $c.Auxiliary=$this.Auxiliary;$c.Predicate=$this.Predicate;$c.Object=$this.Object
        $c.Clause=$this.Clause;$c.Relation=$this.Relation;$c.PredicateRole=$this.PredicateRole
        $c.Tense=$this.Tense;$c.Phase=$this.Phase;$c.Voice=$this.Voice;$c.Status=$this.Status;$c.Need=$this.Need
        [Array]::Copy($this.Choices,$c.Choices,256)
        return $c
    }
}
class CoreToken {
    CoreToken() {}
    [int]$Identity
    [int]$LexicalId
    [string]$Word
    [int]$SourceStart
    [int]$SourceEnd
    [string]$Pron
    [string]$PronunciationSource='CompiledLexicon'
    [int[]]$SymbolIds
    [int[]]$Roles
    [string[]]$Alternatives
    [string]$Status
    [System.Nullable[int]]$EmissionStart
    [System.Nullable[int]]$EmissionEnd
}
class CoreResult {
    CoreResult() {}
    [string]$OriginalText
    [string]$ProjectedText
    [bool]$Reversible=$true
    [string]$KokoroPhones
    [string]$SupportedPhones
    [int[]]$SymbolIds
    [CoreToken[]]$Tokens
    [bool]$Complete
    [string]$GrammarStatus
    [string]$PronunciationStatus
    [CoreCandidate[]]$Candidates
    [CoreCandidate[]]$RetainedCandidates
    [CoreToken[]]$UnresolvedSpans
    [CoreToken[]]$OovSpans
    [CoreToken[]]$AmbiguousDecisions
    [string[]]$Bindings
    [string[]]$Withdrawn
    [int]$Revision
    [string[]]$Pending
    [string]$Execution='CoreLib lowered typed pronunciation driver'
    [string]$ReferenceAssembly='@REFERENCE@'
}
class CoreEngine {
    [Collections.Generic.List[CoreOccurrence]]$Occurrences
    [CoreCandidate[]]$Candidates
    [Collections.Generic.List[string]]$Trace
    [Collections.Generic.List[string]]$Withdrawn
    [Collections.Generic.Dictionary[string,string]]$Corrections
    [bool]$Boundary
    CoreEngine() {
        $this.Occurrences=[Collections.Generic.List[CoreOccurrence]]::new()
        $this.Candidates=[CoreCandidate[]]::new(1);$this.Candidates[0]=[CoreCandidate]::new()
        $this.Trace=[Collections.Generic.List[string]]::new()
        $this.Withdrawn=[Collections.Generic.List[string]]::new()
        $this.Corrections=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        [CoreZiraChoice]$choice=$null
        foreach($choice in [CoreDriver]::Corrections()){
            if($choice.Admitted){$this.Corrections.Add($choice.Key,$choice.Pronunciation)}
        }
    }
    static [int[]] Join([int[]]$a,[int[]]$b) {
        [int[]]$r=[int[]]::new($a.Length+$b.Length)
        [Array]::Copy($a,0,$r,0,$a.Length);[Array]::Copy($b,0,$r,$a.Length,$b.Length)
        return $r
    }
    static [CoreClause] CopyClause([CoreClause]$from) {
        [CoreClause]$c=[CoreClause]::new()
        $c.Voice=$from.Voice;$c.Tense=$from.Tense;$c.Subject=$from.Subject;$c.Predicate=$from.Predicate
        $c.Object=$from.Object;$c.Auxiliary=$from.Auxiliary;$c.Agent=$from.Agent;$c.Time=$from.Time
        $c.Complement=$from.Complement;$c.Dependencies=$from.Dependencies
        return $c
    }
    [CoreNominal] Nominal([CoreCandidate]$c,[CoreOccurrence]$o) {
        if(($o.Capabilities -band 1) -eq 0){throw [ArgumentException]::new('Nominal capability required.')}
        [CoreNominal]$n=[CoreNominal]::new();$n.Head=$o;$n.Determiner=$c.Determiner;$n.Modifiers=$c.Modifiers
        [Collections.Generic.List[int]]$ids=[Collections.Generic.List[int]]::new();$ids.Add($o.Identity)
        [CoreOccurrence]$m=$null
        foreach($m in $c.Modifiers){
            if(($m.Capabilities -band 4) -eq 0){throw [ArgumentException]::new('Modifier capability required.')}
            $ids.Add($m.Identity);$c.Choices[$m.Identity]=2
        }
        $c.Choices[$o.Identity]=0
        if(-not [object]::ReferenceEquals($null,$c.Determiner)){
            if(($c.Determiner.Capabilities -band 32) -eq 0){throw [ArgumentException]::new('Determiner capability required.')}
            $ids.Add($c.Determiner.Identity);$c.Choices[$c.Determiner.Identity]=4
        }
        $n.Dependencies=$ids.ToArray();$c.Determiner=$null;$c.Modifiers=[CoreOccurrence[]]::new(0)
        $this.Trace.Add('CoreEngine.Nominal')
        return $n
    }
    [void] CompleteClause([CoreCandidate]$c) {
        [CoreClause]$clause=[CoreClause]::new();$clause.Voice=$c.Voice;$clause.Tense=$c.Tense
        $clause.Subject=$c.Subject;$clause.Predicate=$c.Predicate;$clause.Auxiliary=$c.Auxiliary
        [int]$role=$c.PredicateRole
        if($c.Voice -ceq 'Passive'){
            if(($c.Predicate.Capabilities -band 8) -eq 0 -or ($c.Auxiliary.Capabilities -band 64) -eq 0){throw [ArgumentException]::new('Passive operand capability failure.')}
            $role=3
        }elseif($c.Voice -ceq 'Stative'){
            if(($c.Predicate.Capabilities -band 4) -eq 0 -or ($c.Auxiliary.Capabilities -band 64) -eq 0){throw [ArgumentException]::new('Stative operand capability failure.')}
            $role=2
        }else{
            if(($c.Predicate.Capabilities -band 2) -eq 0 -or (($c.Predicate.Capabilities -band 1024) -ne 0 -and [object]::ReferenceEquals($null,$c.Object))){throw [ArgumentException]::new('Active operand capability failure.')}
            $clause.Object=$c.Object
            if(-not [object]::ReferenceEquals($null,$c.Auxiliary)){if(($c.Auxiliary.Capabilities -band 4096) -eq 0){throw [ArgumentException]::new('Perfect capability required.')};$role=3}
        }
        [int[]]$predicate=[int[]]::new(1);$predicate[0]=$c.Predicate.Identity
        $clause.Dependencies=[CoreEngine]::Join($c.Subject.Dependencies,$predicate)
        if(-not [object]::ReferenceEquals($null,$clause.Object)){$clause.Dependencies=[CoreEngine]::Join($clause.Dependencies,$clause.Object.Dependencies)}
        if(-not [object]::ReferenceEquals($null,$c.Auxiliary)){$predicate[0]=$c.Auxiliary.Identity;$clause.Dependencies=[CoreEngine]::Join($clause.Dependencies,$predicate);$c.Choices[$c.Auxiliary.Identity]=4}
        $c.Choices[$c.Predicate.Identity]=$role;$c.Clause=$clause;$c.Phase='Extension';$c.Status='Extensible';$c.Need='OptionalRelation'
        $this.Trace.Add('CoreEngine.CompleteClause')
    }
    [void] Add([CoreOccurrence]$o) {
        if($this.Occurrences.Count -ge 256){throw [ArgumentOutOfRangeException]::new('occurrences')}
        $o.Identity=$this.Occurrences.Count;$this.Occurrences.Add($o)
        if($o.Kind -ceq 'Boundary'){$this.Boundary=$o.Text -ceq '.' -or $o.Text -ceq '!' -or $o.Text -ceq '?';return}
        $this.Boundary=$false
        [Collections.Generic.List[CoreCandidate]]$next=[Collections.Generic.List[CoreCandidate]]::new()
        [CoreCandidate]$prior=$null
        foreach($prior in $this.Candidates){
            [CoreCandidate]$c=$prior.Copy()
            if($c.Status -ceq 'Unsupported' -or $c.Status -ceq 'Contradictory'){$next.Add($c);continue}
            [int]$f=$o.Capabilities
            if($o.LexicalId -lt 0){$c.Status='Unsupported';$c.Need='UnknownLexicalIdentity';$next.Add($c);continue}
            if($c.Phase -ceq 'Subject' -and $o.Identity -eq 0 -and $o.Text.ToLowerInvariant() -ceq 'please'){
                $c.Choices[$o.Identity]=4;$c.Need='ImperativePredicate';$next.Add($c);continue
            }
            if($c.Phase -ceq 'Subject' -and ($o.Identity -eq 0 -or ($o.Identity -eq 1 -and $this.Occurrences.get_Item(0).Text.ToLowerInvariant() -ceq 'please')) -and ($o.Text.ToLowerInvariant() -ceq 'play' -or $o.Text.ToLowerInvariant() -ceq 'push' -or $o.Text.ToLowerInvariant() -ceq 'press' -or $o.Text.ToLowerInvariant() -ceq 'record') -and ($f -band 2) -ne 0){
                [CoreOccurrence]$head=[CoreOccurrence]::new();$head.Identity=-1;$head.Text='you';$head.Capabilities=1
                [CoreNominal]$subject=[CoreNominal]::new();$subject.Head=$head;$subject.Modifiers=[CoreOccurrence[]]::new(0);$subject.Dependencies=[int[]]::new(0)
                $c.Subject=$subject;$c.Phase='Predicate';$c.Need='Predicate'
            }
            if($c.Phase -ceq 'Subject' -or $c.Phase -ceq 'Object' -or $c.Phase -ceq 'RelationComplement'){
                if(($f -band 32) -ne 0 -and [object]::ReferenceEquals($null,$c.Determiner)){
                    [CoreCandidate]$det=$c.Copy();$det.Determiner=$o;$det.Choices[$o.Identity]=4;$det.Status='Pending';$det.Need='NominalHead';$next.Add($det)
                    $this.Trace.Add('CoreEngine.DeterminerRequirement')
                }
                if(($f -band 4) -ne 0 -and -not [object]::ReferenceEquals($null,$c.Determiner)){
                    [CoreCandidate]$mod=$c.Copy();[CoreOccurrence[]]$mods=[CoreOccurrence[]]::new($c.Modifiers.Length+1)
                    [Array]::Copy($c.Modifiers,$mods,$c.Modifiers.Length);$mods[$mods.Length-1]=$o
                    $mod.Modifiers=$mods;$mod.Choices[$o.Identity]=2;$mod.Need='NominalHead';$next.Add($mod)
                }
                if(($f -band 1) -ne 0){
                    [CoreNominal]$nominal=$this.Nominal($c,$o)
                    if($c.Phase -ceq 'Subject'){$c.Subject=$nominal;$c.Phase='Predicate';$c.Status='Extensible';$c.Need='Predicate'}
                    elseif($c.Phase -ceq 'Object'){$c.Object=$nominal;$this.CompleteClause($c)}
                    else{
                        if(($f -band 512) -ne 0 -or (($f -band 256) -ne 0 -and $c.Voice -ceq 'Passive')){
                            [CoreClause]$relation=[CoreEngine]::CopyClause($c.Clause)
                            if(($f -band 512) -ne 0){$relation.Time=$nominal}else{$relation.Agent=$nominal}
                            [int[]]$rid=[int[]]::new(1);$rid[0]=$c.Relation.Identity
                            $relation.Dependencies=[CoreEngine]::Join([CoreEngine]::Join($relation.Dependencies,$nominal.Dependencies),$rid)
                            $c.Clause=$relation;$c.Phase='Extension';$c.Status='Extensible';$c.Need='OptionalRelation';$this.Trace.Add('CoreEngine.Relation')
                        }else{$c.Status='Unsupported';$c.Need='RelationSense';$this.Withdrawn.Add('UnsupportedRelationSense')}
                    }
                    $next.Add($c)
                }
                if(($f -band 37) -eq 0){$c.Status='Contradictory';$c.Need='NominalHead';$next.Add($c)}
            }elseif($c.Phase -ceq 'Predicate'){
                if(($f -band 4160) -ne 0){$c.Auxiliary=$o;$c.Choices[$o.Identity]=4;$c.Phase='AfterAuxiliary';$c.Status='Pending';$c.Need='Predicate';$next.Add($c);$this.Trace.Add('CoreEngine.AuxiliaryRequirement')}
                elseif(($f -band 2) -ne 0){
                    $c.Predicate=$o;$c.Choices[$o.Identity]=1;$this.Trace.Add('CoreEngine.OperationRequirement')
                    if(($f -band 1024) -ne 0){$c.Phase='Object';$c.Status='Pending';$c.Need='Object'}else{$this.CompleteClause($c)}
                    $next.Add($c)
                    if(($f -band 8192) -ne 0){[CoreCandidate]$past=$c.Copy();$past.PredicateRole=3;$past.Tense='Past';$past.Choices[$o.Identity]=3;$c.Tense='Present';if($past.Phase -ceq 'Extension'){$this.CompleteClause($past)};$next.Add($past)}
                }else{$c.Status='Contradictory';$c.Need='CallablePredicate';$next.Add($c)}
            }elseif($c.Phase -ceq 'AfterAuxiliary'){
                if(($c.Auxiliary.Capabilities -band 4096) -ne 0 -and ($f -band 8) -ne 0){$c.Predicate=$o;$c.Choices[$o.Identity]=3;if(($f -band 1024) -ne 0){$c.Phase='Object';$c.Need='Object'}else{$this.CompleteClause($c)};$next.Add($c)}
                elseif(($c.Auxiliary.Capabilities -band 64) -ne 0){
                    if(($f -band 8) -ne 0){[CoreCandidate]$passive=$c.Copy();$passive.Predicate=$o;$passive.Voice='Passive';$this.CompleteClause($passive);$next.Add($passive)}
                    if(($f -band 4) -ne 0){[CoreCandidate]$stative=$c.Copy();$stative.Predicate=$o;$stative.Voice='Stative';$this.CompleteClause($stative);$next.Add($stative)}
                    if(($f -band 12) -eq 0){$c.Status='Unsupported';$c.Need='CopularComplement';$next.Add($c)}
                }else{$c.Status='Contradictory';$c.Need='Participle';$next.Add($c)}
            }elseif($c.Phase -ceq 'Extension'){
                if(($f -band 128) -ne 0){$c.Relation=$o;$c.Choices[$o.Identity]=4;$c.Phase='RelationComplement';$c.Status='Pending';$c.Need='RelationComplement';$next.Add($c)}
                elseif(($c.Predicate.Capabilities -band 2048) -ne 0 -and ($f -band 2) -ne 0 -and ($f -band 1024) -eq 0){
                    [CoreCandidate]$embedded=[CoreCandidate]::new();$embedded.Subject=$c.Object;$embedded.Predicate=$o;$this.CompleteClause($embedded)
                    [CoreClause]$parent=[CoreEngine]::CopyClause($c.Clause);$parent.Complement=$embedded.Clause
                    $parent.Dependencies=[CoreEngine]::Join($parent.Dependencies,$embedded.Clause.Dependencies)
                    $c.Clause=$parent;$c.Choices[$o.Identity]=1;$next.Add($c)
                }else{$c.Status='Unsupported';$c.Need='AdditionalConstruction';$next.Add($c)}
            }
        }
        if($next.Count -gt 16){throw [ArgumentOutOfRangeException]::new('candidates')}
        $this.Candidates=$next.ToArray()
    }
    [void] Scan([string]$text) {
        if([object]::ReferenceEquals($null,$text) -or $text.Length -gt 8192){throw [ArgumentOutOfRangeException]::new('text')}
        [int]$at=0
        while($at -lt $text.Length){
            if([char]::IsWhiteSpace($text.get_Chars($at))){$at++;continue}
            [int]$start=$at;[string]$kind='Word'
            if([char]::IsLetterOrDigit($text.get_Chars($at)) -or $text.get_Chars($at) -ceq [Convert]::ToChar(36)){
                $at++
                while($at -lt $text.Length -and ([char]::IsLetterOrDigit($text.get_Chars($at)) -or $text.get_Chars($at) -ceq [Convert]::ToChar(39) -or $text.get_Chars($at) -ceq [Convert]::ToChar(8217))){$at++}
            }else{$kind='Boundary';$at++}
            [CoreOccurrence]$o=[CoreOccurrence]::new();$o.Text=$text.Substring($start,$at-$start);$o.Start=$start;$o.End=$at;$o.Kind=$kind;$o.LexicalId=-1
            if($kind -ceq 'Word'){$o.LexicalId=[Lexicon]::Find($o.Text);if($o.LexicalId -ge 0){$o.Capabilities=[Lexicon]::Capabilities($o.LexicalId)}}
            $this.Add($o)
        }
    }
    static [void] Alternatives([Collections.Generic.List[string]]$values,[int]$id,[int]$role) {
        [string[]]$parts=[Lexicon]::Phones($id,$role).Split([Convert]::ToChar(124),[StringSplitOptions]::RemoveEmptyEntries)
        [string]$part=''
        foreach($part in $parts){if(-not $values.Contains($part)){$values.Add($part)}}
    }
    [int] FollowingVowel([CoreOccurrence]$o) {
        if($o.Identity+1 -ge $this.Occurrences.Count){return 0}
        [CoreOccurrence]$next=$this.Occurrences.get_Item($o.Identity+1)
        if($next.Kind -ceq 'Boundary'){return 0}
        if($next.LexicalId -lt 0){return 2}
        [int]$answer=-1
        for([int]$role=0;$role -lt 5;$role++){
            [string[]]$values=[Lexicon]::Phones($next.LexicalId,$role).Split([Convert]::ToChar(124),[StringSplitOptions]::RemoveEmptyEntries)
            [string]$value=''
            foreach($value in $values){
                [int]$at=0;while($at -lt $value.Length -and ($value.get_Chars($at) -ceq [Convert]::ToChar(712) -or $value.get_Chars($at) -ceq [Convert]::ToChar(716))){$at++}
                if($at -ge $value.Length){return 2}
                [int]$vowel=0;if('AIOWYɑɔəæɛɜɪiʊuʌ'.IndexOf($value.get_Chars($at)) -ge 0){$vowel=1}
                if($answer -ge 0 -and $answer -ne $vowel){return 2};$answer=$vowel
            }
        }
        if($answer -lt 0){return 2};return $answer
    }
    [CoreResult] Result([string]$text) {
        [CoreResult]$r=[CoreResult]::new();$r.OriginalText=$text;$r.Revision=$this.Occurrences.Count
        [Collections.Generic.List[CoreCandidate]]$viable=[Collections.Generic.List[CoreCandidate]]::new()
        [Collections.Generic.List[string]]$pending=[Collections.Generic.List[string]]::new();[bool]$unsupported=$false
        [CoreCandidate]$c=$null
        foreach($c in $this.Candidates){
            if($c.Status -ceq 'Unsupported'){$unsupported=$true}
            elseif($c.Status -cne 'Contradictory'){$viable.Add($c);if($c.Status -ceq 'Pending'){$pending.Add($c.Need)}}
        }
        $r.Candidates=$viable.ToArray();$r.RetainedCandidates=$this.Candidates;$r.Pending=$pending.ToArray()
        $r.GrammarStatus='Contradictory'
        if($viable.Count -gt 1){$r.GrammarStatus='Ambiguous'}elseif($viable.Count -eq 1){$r.GrammarStatus=$viable.get_Item(0).Status;if($this.Boundary -and $viable.get_Item(0).Status -ceq 'Extensible' -and -not [object]::ReferenceEquals($null,$viable.get_Item(0).Clause)){$r.GrammarStatus='Resolved'}}elseif($unsupported){$r.GrammarStatus='Unsupported'}
        [Collections.Generic.List[CoreToken]]$tokens=[Collections.Generic.List[CoreToken]]::new()
        [Collections.Generic.List[CoreToken]]$unresolved=[Collections.Generic.List[CoreToken]]::new()
        [Collections.Generic.List[CoreToken]]$oov=[Collections.Generic.List[CoreToken]]::new()
        [Collections.Generic.List[CoreToken]]$ambiguous=[Collections.Generic.List[CoreToken]]::new()
        [Collections.Generic.List[int]]$ids=[Collections.Generic.List[int]]::new();[Text.StringBuilder]$phones=[Text.StringBuilder]::new()
        [CoreOccurrence]$o=$null
        foreach($o in $this.Occurrences.ToArray()){
            [CoreToken]$t=[CoreToken]::new();$t.Identity=$o.Identity;$t.LexicalId=$o.LexicalId;$t.Word=$o.Text;$t.SourceStart=$o.Start;$t.SourceEnd=$o.End
            [Collections.Generic.List[int]]$roles=[Collections.Generic.List[int]]::new()
            [Collections.Generic.List[string]]$alternatives=[Collections.Generic.List[string]]::new()
            [string]$phone=$null;[string]$reason=$null
            if($o.Kind -ceq 'Boundary'){if([Phonology]::SymbolId($o.Text.get_Chars(0)) -ge 0){$phone=$o.Text}else{$reason='UnsupportedSymbol'}}
            elseif($o.LexicalId -lt 0){$reason='UnknownLexicalIdentity'}
            elseif($viable.Count -eq 0){$reason='NoAdmittedRelationship'}
            else{
                foreach($c in $viable.ToArray()){[int]$role=$c.Choices[$o.Identity];if(-not $roles.Contains($role)){$roles.Add($role)}}
                $roles.Sort()
                if($roles.Contains(-1)){$reason='PendingRole'}else{
                    [int]$role=0
                    foreach($role in $roles.ToArray()){[CoreEngine]::Alternatives($alternatives,$o.LexicalId,$role)}
                    $alternatives.Sort()
                    if($alternatives.Count -eq 1){$phone=$alternatives.get_Item(0)}else{$reason='PronunciationAmbiguous'}
                }
            }
            if([object]::ReferenceEquals($null,$phone) -and $o.LexicalId -ge 0){
                [Collections.Generic.List[string]]$all=[Collections.Generic.List[string]]::new()
                for([int]$role=0;$role -lt 5;$role++){[CoreEngine]::Alternatives($all,$o.LexicalId,$role)}
                if($all.Count -eq 1){$phone=$all.get_Item(0);$reason=$null}
            }
            if($roles.Count -eq 1 -and $roles.get_Item(0) -ge 0 -and $this.Corrections.Count -gt 0){
                [string]$key=$o.Text.ToLowerInvariant()+':'+[Convert]::ToString($roles.get_Item(0))+':'+[Convert]::ToString($this.FollowingVowel($o))
                if($this.Corrections.ContainsKey($key)){$phone=$this.Corrections.get_Item($key);$reason=$null;$t.PronunciationSource='ZiraCorrection'}
            }
            [Collections.Generic.List[int]]$tokenIds=[Collections.Generic.List[int]]::new()
            if(-not [object]::ReferenceEquals($null,$phone)){
                if($phones.Length -gt 0){[void]$phones.Append(' ');$ids.Add(16)}
                $t.EmissionStart=[System.Nullable[int]]::new($phones.Length)
                [char]$ch=[Convert]::ToChar(0)
                foreach($ch in $phone.ToCharArray()){
                    [int]$symbol=[Phonology]::SymbolId($ch);if($symbol -lt 0){throw [ArgumentException]::new('Phone outside target vocabulary.')}
                    $ids.Add($symbol);$tokenIds.Add($symbol)
                }
                [void]$phones.Append($phone);$t.EmissionEnd=[System.Nullable[int]]::new($phones.Length);$t.Status='Valid'
            }else{$t.Status=$reason;$unresolved.Add($t);if($reason -ceq 'UnknownLexicalIdentity'){$oov.Add($t)}}
            $t.Pron=$phone;$t.Roles=$roles.ToArray();$t.Alternatives=$alternatives.ToArray();$t.SymbolIds=$tokenIds.ToArray()
            $tokens.Add($t);if($roles.Count -gt 1 -or $alternatives.Count -gt 1){$ambiguous.Add($t)}
        }
        $r.Tokens=$tokens.ToArray();$r.UnresolvedSpans=$unresolved.ToArray();$r.OovSpans=$oov.ToArray();$r.AmbiguousDecisions=$ambiguous.ToArray()
        $r.SymbolIds=$ids.ToArray();$r.SupportedPhones=$phones.ToString();$r.Complete=$unresolved.Count -eq 0
        $r.PronunciationStatus='UnsupportedOrPending';if($r.Complete){$r.KokoroPhones=$r.SupportedPhones;$r.PronunciationStatus='Resolved'}
        $r.Bindings=$this.Trace.ToArray();$r.Withdrawn=$this.Withdrawn.ToArray()
        return $r
    }
}
class CoreDriver {
    static [CoreZiraChoice[]]$CachedChoices
    static [CoreZiraChoice[]] Corrections() {
        if([object]::ReferenceEquals($null,[CoreDriver]::CachedChoices)){[CoreDriver]::CachedChoices=[CoreZiraCorpusData]::Choices([CoreZiraCorpusData]::Captures())}
        return [CoreDriver]::CachedChoices
    }
    static [string] NormalizeZira([string]$raw) {
        if([object]::ReferenceEquals($null,$raw) -or $raw.Length -gt 8192){throw [ArgumentOutOfRangeException]::new('raw')}
        return $raw.Replace('i͡ə','iə').Replace('t͡ʃ','ʧ').Replace('d͡ʒ','ʤ').Replace('a͡ɪ','I').Replace('e͡ɪ','A').Replace('o͡ʊ','O').Replace('a͡ʊ','W').Replace('ɔ͡ɪ','Y').Replace('a͡i','I').Replace('e͡i','A').Replace('o͡u','O').Replace('a͡u','W').Replace('ɔ͡i','Y').Replace('ɻ','ɹ').Replace('ɚ','əɹ').Replace('ɝ','ɜɹ').Replace('g','ɡ').Replace('tʃ','ʧ').Replace('dʒ','ʤ').Replace('aɪ','I').Replace('eɪ','A').Replace('oʊ','O').Replace('aʊ','W').Replace('ɔɪ','Y')
    }
    static [int[]] ZiraTokenIds([string]$raw) {
        [string]$phones=[CoreDriver]::NormalizeZira($raw)
        [int[]]$ids=[int[]]::new($phones.Length)
        for([int]$i=0;$i -lt $phones.Length;$i++){
            [int]$id=[Phonology]::SymbolId($phones.get_Chars($i))
            if($id -lt 0){throw [ArgumentException]::new('Zira phone outside Kokoro vocabulary.')}
            $ids[$i]=$id
        }
        return $ids
    }
    static [int] ZiraBatch([string]$raw,[int]$count) {
        if($count -lt 1 -or $count -gt 100000){throw [ArgumentOutOfRangeException]::new('count')}
        [int]$sum=0
        for([int]$i=0;$i -lt $count;$i++){$sum+=[CoreDriver]::ZiraTokenIds($raw).Length}
        return $sum
    }
    static [CoreResult] Run([string]$text) {
        [CoreEngine]$engine=[CoreEngine]::new();$engine.Scan($text);return $engine.Result($text)
    }
    static [int] Batch([string]$text,[int]$count) {
        if($count -lt 1 -or $count -gt 100000){throw [ArgumentOutOfRangeException]::new('count')}
        [int]$total=0
        for([int]$i=0;$i -lt $count;$i++){[CoreResult]$r=[CoreDriver]::Run($text);if(-not $r.Complete){throw [InvalidOperationException]::new('Benchmark phrase unresolved.')};$total=$total+$r.SymbolIds.Length}
        return $total
    }
    static [string] Literal([string]$text) {
        if([object]::ReferenceEquals($null,$text)){return '$null'}
        return "'"+$text.Replace("'","''")+"'"
    }
    static [string] DataFile([CoreResult]$r) {
        [Text.StringBuilder]$b=[Text.StringBuilder]::new()
        [void]$b.Append('@{Execution=''CoreLib lowered typed pronunciation driver'';Complete=')
        if($r.Complete){[void]$b.Append('$true')}else{[void]$b.Append('$false')}
        [void]$b.Append(';RuntimeSmaLoaded=')
        if([CoreDriver]::SmaLoaded()){[void]$b.Append('$true')}else{[void]$b.Append('$false')}
        [void]$b.Append(';OriginalText=');[void]$b.Append([CoreDriver]::Literal($r.OriginalText))
        [void]$b.Append(';KokoroPhones=');[void]$b.Append([CoreDriver]::Literal($r.KokoroPhones))
        [void]$b.Append(';GrammarStatus=');[void]$b.Append([CoreDriver]::Literal($r.GrammarStatus))
        [void]$b.Append(';SymbolIds=@(')
        for([int]$i=0;$i -lt $r.SymbolIds.Length;$i++){if($i -gt 0){[void]$b.Append(',')};[void]$b.Append([Convert]::ToString($r.SymbolIds[$i]))}
        [void]$b.Append(');Tokens=@(')
        for([int]$i=0;$i -lt $r.Tokens.Length;$i++){
            [CoreToken]$t=$r.Tokens[$i];if($i -gt 0){[void]$b.Append(',')}
            [void]$b.Append('@{Word=');[void]$b.Append([CoreDriver]::Literal($t.Word))
            [void]$b.Append(';SourceStart=');[void]$b.Append([Convert]::ToString($t.SourceStart))
            [void]$b.Append(';SourceEnd=');[void]$b.Append([Convert]::ToString($t.SourceEnd))
            [void]$b.Append(';Pron=');[void]$b.Append([CoreDriver]::Literal($t.Pron))
            [void]$b.Append(';Status=');[void]$b.Append([CoreDriver]::Literal($t.Status))
            [void]$b.Append(';PronunciationSource=');[void]$b.Append([CoreDriver]::Literal($t.PronunciationSource))
            [void]$b.Append(';Roles=@(')
            for([int]$j=0;$j -lt $t.Roles.Length;$j++){if($j -gt 0){[void]$b.Append(',')};[void]$b.Append([Convert]::ToString($t.Roles[$j]))}
            [void]$b.Append(')}')
        }
        [void]$b.Append(')}');return $b.ToString()
    }
    static [int] Main([string[]]$arguments) {
        if($arguments.Length -eq 3 -and $arguments[0] -ceq '--zira'){
            [CoreResult]$mapped=[CoreResult]::new();$mapped.OriginalText=$arguments[1]
            $mapped.KokoroPhones=[CoreDriver]::NormalizeZira($arguments[1]);$mapped.SymbolIds=[CoreDriver]::ZiraTokenIds($arguments[1])
            $mapped.Complete=$true;$mapped.GrammarStatus='ZiraEvents';$mapped.Tokens=[CoreToken[]]::new(1)
            [CoreToken]$token=[CoreToken]::new();$token.Word=$arguments[1];$token.SourceStart=0;$token.SourceEnd=$arguments[1].Length
            $token.Pron=$mapped.KokoroPhones;$token.PronunciationSource='ZiraEvents';$token.Status='Valid';$token.Roles=[int[]]::new(0)
            $mapped.Tokens[0]=$token
            [IO.File]::WriteAllText($arguments[2],[CoreDriver]::DataFile($mapped));return 0
        }
        if($arguments.Length -ne 2){return 2}
        [CoreResult]$result=[CoreDriver]::Run($arguments[0])
        [IO.File]::WriteAllText($arguments[1],[CoreDriver]::DataFile($result))
        if(-not $result.Complete){return 1};return 0
    }
    static [bool] SmaLoaded() {
        [System.Reflection.Assembly]$assembly=$null
        foreach($assembly in [AppDomain]::CurrentDomain.GetAssemblies()){
            if($assembly.GetName().Name -ceq 'System.Management.Automation'){return $true}
        }
        return $false
    }
}
'@
}

function Import-EnglishCoreDriver {
    [CmdletBinding()]
    param([string]$ReferencePath=$AssemblyPath)
    if($script:EnglishCoreCache.ContainsKey($ReferencePath)){return $script:EnglishCoreCache[$ReferencePath]}
    $reference=Import-EnglishReference $ReferencePath;$lex=$reference.Assembly.GetType('Lexicon',$true)
    $literal=@((Get-Command Build-EnglishReference).ScriptBlock.Ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('class Lexicon {')},$true))
    if($literal.Count -ne 1){throw 'Lexical lowering template identity failure.'}
    $source=$literal[0].Value
    foreach($pair in @(@('COUNT','Count'),@('FORMS','Forms'),@('FLAGS','Flags'),@('OFFSETS','Offsets'),@('ROLES','RoleIndexes'),@('ALTERNATES','Alternates'),@('PHONES','Sequences'))){
        $value=[string]$lex.GetMethod($pair[1]).Invoke($null,@());$source=$source.Replace('@'+$pair[0]+'@',$value.Replace("'","''"))
    }
    $vocabulary=$reference.Assembly.GetType('Phonology').GetMethod('Vocabulary').Invoke($null,@())
    $source=$source.Replace('@VOCAB@',$vocabulary.Replace("'","''"))
    $table=@{};$knowledge=New-EnglishZiraDataSource
    if(Test-Path -LiteralPath $CorrectionPath){$table=Import-EnglishCorrections $CorrectionPath;$corpus=Import-EnglishZiraCorpus $CorrectionPath;$knowledge=[IO.File]::ReadAllText($corpus.Source)}
    foreach($key in $table.Keys){foreach($ch in $table[$key].ToCharArray()){if($reference.SymbolId.Invoke($ch) -lt 0){throw 'Correction outside Kokoro vocabulary.'}}}
    $source+="`n"+$knowledge+"`n"+(Get-EnglishCoreTemplate).Replace('[Collections.Generic.','[System.Collections.Generic.').Replace('[void]','').Replace('@REFERENCE@',$reference.Assembly.GetName().Name)
    $identity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source)))
    $directory=Join-Path $env:LOCALAPPDATA ('Build\PSPerception\english\driver\'+$identity)
    $name='Dev.MansfieldPlumbing.English.Driver.'+$identity.Substring(0,16)
    $output=Join-Path $directory ($name+'.dll');$receiptPath=Join-Path $directory 'driver-receipt.psd1'
    if(-not(Test-Path -LiteralPath $receiptPath)){
        [void][IO.Directory]::CreateDirectory($directory);$input=Join-Path $directory 'driver.ps1'
        [IO.File]::WriteAllText($input,$source,[Text.UTF8Encoding]::new($false));Import-EnglishLowering
        $null=Export-LoweredAssembly -SourcePath $input -ClassName CoreDriver -EntryPoint Main -OutputPath $output -Deterministic
        $inspection=Test-LoweredAssembly -AssemblyPath $output
        if($inspection.AssemblyReferences.Count -ne 1 -or $inspection.AssemblyReferences[0] -cne 'System.Private.CoreLib'){throw 'Standalone driver is not CoreLib only.'}
        $runtimes=@(& $DotnetPath --list-runtimes);if($LASTEXITCODE){throw '.NET runtime discovery failed.'}
        $versions=@($runtimes | ForEach-Object {if($_ -match '^Microsoft.NETCore.App (\S+) ' -and $Matches[1].StartsWith([string][Environment]::Version.Major+'.')){$Matches[1]}})
        if(-not $versions.Count -or $versions[-1] -cnotmatch '^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$'){throw 'Matching .NET runtime required.'}
        # The .NET host requires this upstream configuration format; pronunciation data is typed source.
        $hostConfig='{"runtimeOptions":{"tfm":"net'+[Environment]::Version.Major+'.0","framework":{"name":"Microsoft.NETCore.App","version":"'+$versions[-1]+'"},"rollForward":"Disable"}}'
        [IO.File]::WriteAllText([IO.Path]::ChangeExtension($output,'.runtimeconfig.json'),$hostConfig,[Text.UTF8Encoding]::new($false))
        Write-EnglishBuildReceipt $receiptPath ([ordered]@{SourceSha256=$identity;AssemblySha256=(Get-FileHash $output).Hash;ReferenceSha256=(Get-FileHash $ReferencePath).Hash;CompilerCommit='1afabe056235a570da29e268824784557d4f6cdd';AssemblyReferences=$inspection.AssemblyReferences;EntryPoint='CoreDriver.Main';Output=$output;Corrections=$table.Count})
    }
    $receipt=Import-PowerShellDataFile -LiteralPath $receiptPath
    if($receipt.SourceSha256 -cne $identity -or (Get-FileHash -LiteralPath $output).Hash -cne $receipt.AssemblySha256){throw 'Standalone driver integrity failure.'}
    $assembly=[Reflection.Assembly]::LoadFrom($output);$dependencies=@($assembly.GetReferencedAssemblies())
    if($dependencies.Count -ne 1 -or $dependencies[0].Name -cne 'System.Private.CoreLib'){throw 'Unexpected standalone dependency.'}
    $type=$assembly.GetType('CoreDriver',$true)
    $driver=[pscustomobject]@{Assembly=$assembly;Run=[Func[string,object]]$type.GetMethod('Run').CreateDelegate([Func[string,object]]);Batch=[Func[string,int,int]]$type.GetMethod('Batch').CreateDelegate([Func[string,int,int]]);NormalizeZira=[Func[string,string]]$type.GetMethod('NormalizeZira').CreateDelegate([Func[string,string]]);ZiraTokenIds=[Func[string,int[]]]$type.GetMethod('ZiraTokenIds').CreateDelegate([Func[string,int[]]]);ZiraBatch=[Func[string,int,int]]$type.GetMethod('ZiraBatch').CreateDelegate([Func[string,int,int]]);Output=$output;Receipt=$receiptPath;SourceSha256=$identity;Corrections=$table.Count}
    $script:EnglishCoreCache[$ReferencePath]=$driver;$driver
}

function Get-EnglishCorrectionKey {
    param($Context,[EnglishOccurrence]$Occurrence,[int]$Role)
    $vowel=0
    if($Occurrence.Identity+1 -lt $Context.Occurrences.Count){
        $next=$Context.Occurrences[$Occurrence.Identity+1]
        if($next.Kind -ceq 'Word'){
            $vowel=2 # Unknown onset never matches an admitted correction.
            if($next.LexicalId -ge 0){
                if(-not $Context.Reference.Onsets.ContainsKey($next.LexicalId)){
                    $pronunciations=@(0..4 | ForEach-Object {$Context.Reference.Phones.Invoke($next.LexicalId,$_).Split('|',[StringSplitOptions]::RemoveEmptyEntries)} | Sort-Object -Unique -CaseSensitive)
                    $onsets=@($pronunciations | ForEach-Object {[int]($_.TrimStart([char[]]'ˈˌ')[0] -cin [char[]]'AIOWYɑɔəæɛɜɪiʊuʌ')} | Sort-Object -Unique)
                    $Context.Reference.Onsets[$next.LexicalId]=if($onsets.Count -eq 1){$onsets[0]}else{2}
                }
                $vowel=$Context.Reference.Onsets[$next.LexicalId]
            }
        }
    }
    $Occurrence.Text.ToLowerInvariant()+':'+$Role+':'+$vowel
}

function Import-EnglishCorrections {
    param([string]$Path)
    $info=Get-Item -LiteralPath $Path
    if($info.Length -gt 1048576){throw 'Correction manifest bound exceeded.'}
    $identity=$info.FullName+':'+$info.LastWriteTimeUtc.Ticks+':'+$info.Length
    if($script:EnglishCorrectionCache.ContainsKey($identity)){return $script:EnglishCorrectionCache[$identity]}
    $model=Import-EnglishZiraCorpus $Path;$entries=@{}
    foreach($entry in $model.Entries){
        if(-not $entry.Admitted){continue}
        if($entry.Key -cnotmatch "^[a-z][a-z'-]{0,63}:[0-4]:[01]$" -or $entry.Pronunciation.Length -lt 1 -or $entry.Pronunciation.Length -gt 128 -or $entries.ContainsKey($entry.Key)){throw 'Invalid admitted correction.'}
        $entries[$entry.Key]=[string]$entry.Pronunciation
    }
    $script:EnglishCorrectionCache=@{$identity=$entries};$entries
}

function Get-EnglishZiraReference {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateLength(1,8192)][string]$Text,[string]$Path=$SpeechAssemblyPath,[switch]$NoSave)
    if(-not $IsWindows){throw 'Zira reference capture requires Windows; inference does not.'}
    $Path=[IO.Path]::GetFullPath($Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw 'Installed System.Speech assembly is missing.'}
    $assembly=[Reflection.Assembly]::LoadFrom($Path)
    $synth=[System.Speech.Synthesis.SpeechSynthesizer]::new()
    $prefix='EnglishZira-'+[guid]::NewGuid().ToString('N')
    $sources=@("$prefix-phones","$prefix-words","$prefix-done")
    try{
        $inventory=@($synth.GetInstalledVoices())
        $installed=@($inventory | Where-Object {$_.Enabled -and $_.VoiceInfo.Name -ceq 'Microsoft Zira Desktop' -and $_.VoiceInfo.Culture.Name -ceq 'en-US'})
        if($installed.Count -ne 1){throw 'Microsoft Zira Desktop en-US is required for reproducible reference capture.'}
        $synth.SelectVoice($installed[0].VoiceInfo.Name);$synth.Rate=0;$synth.SetOutputToNull()
        $null=Register-ObjectEvent $synth PhonemeReached -SourceIdentifier $sources[0]
        $null=Register-ObjectEvent $synth SpeakProgress -SourceIdentifier $sources[1]
        $null=Register-ObjectEvent $synth SpeakCompleted -SourceIdentifier $sources[2]
        $prompt=$synth.SpeakAsync($Text)
        $done=Wait-Event -SourceIdentifier $sources[2] -Timeout 60
        if($null -eq $done){$synth.SpeakAsyncCancelAll();throw 'Zira reference capture timed out.'}
        if($null -ne $done.SourceEventArgs.Error){throw $done.SourceEventArgs.Error}
        $phones=@(Get-Event -SourceIdentifier $sources[0] -ErrorAction SilentlyContinue | Sort-Object EventIdentifier | ForEach-Object {
            $e=$_.SourceEventArgs
            $phone=[EnglishZiraPhone]::new();$phone.Phone=$e.Phoneme;$phone.Next=$e.NextPhoneme;$phone.Ticks=$e.AudioPosition.Ticks;$phone.DurationTicks=$e.Duration.Ticks;$phone.Emphasis=[int]$e.Emphasis;$phone.Event=$_.EventIdentifier;$phone
        })
        $words=@(Get-Event -SourceIdentifier $sources[1] -ErrorAction SilentlyContinue | Sort-Object EventIdentifier | ForEach-Object {
            $e=$_.SourceEventArgs
            $word=[EnglishZiraWord]::new();$word.Word=$e.Text;$word.Start=$e.CharacterPosition;$word.Length=$e.CharacterCount;$word.Ticks=$e.AudioPosition.Ticks;$word.Event=$_.EventIdentifier;$word.PhoneEvents=[EnglishZiraPhone[]]::new(0);$word.SymbolIds=[int[]]::new(0);$word.Roles=[int[]]::new(0);$word
        })
        if($phones.Count -eq 0 -or $words.Count -eq 0){throw 'Zira did not supply both reference event streams.'}
        $capture=[EnglishZiraUtterance]::new();$capture.Text=$Text;$capture.Voice=$synth.Voice.Name;$capture.AssemblySha256=(Get-FileHash -LiteralPath $Path).Hash;$capture.EngineSha256=(Get-FileHash -LiteralPath (Join-Path $env:WINDIR 'System32\speech\engines\tts\MSTTSEngine.dll')).Hash;$capture.CapturedAtTicks=[DateTime]::UtcNow.Ticks;$capture.Words=[EnglishZiraWord[]]$words;$capture.Phones=[EnglishZiraPhone[]]$phones;$capture.AlignedWords=[EnglishZiraWord[]]::new(0)
        $capture.Identity=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text+$capture.Voice+$capture.AssemblySha256+$capture.EngineSha256+$capture.CapturedAtTicks)))
        foreach($word in $capture.Words){$word.Utterance=$capture}
        $aligned=[Collections.Generic.List[EnglishZiraWord]]::new();$alignedCount=0
        $vocab=(Get-EnglishKokoroSpecification).vocab
        $audible=@($phones | Where-Object {$_.Phone.Length -gt 0 -and -not [char]::IsControl($_.Phone[0])})
        $valid=$true
        for($i=0;$i -lt $words.Count;$i++){
            $word=$words[$i]
            $limit=if($i+1 -lt $words.Count){$words[$i+1].Ticks}else{[long]::MaxValue}
            $selected=@($audible | Where-Object {$_.Ticks -ge $word.Ticks -and $_.Ticks -lt $limit})
            if($word.Start -lt 0 -or $word.Length -lt 1 -or $word.Start+$word.Length -gt $Text.Length -or $Text.Substring($word.Start,$word.Length) -cne $word.Word -or $selected.Count -eq 0 -or $selected[0].Ticks -ne $word.Ticks){$valid=$false;continue}
            if($i -gt 0 -and ($word.Start -lt $words[$i-1].Start+$words[$i-1].Length -or $word.Ticks -le $words[$i-1].Ticks)){$valid=$false;continue}
            $alignedCount+=$selected.Count
            $word.RawPhones=$selected.Phone -join '';$word.Phones=ConvertTo-EnglishKokoroPhones $word.RawPhones;$word.StressObserved=@($selected | Where-Object {($_.Emphasis -band 1) -ne 0}).Count;$word.FirstTicks=$word.Ticks;$word.PhoneCount=$selected.Count;$word.PhoneEvents=[EnglishZiraPhone[]]$selected
            $word.SymbolIds=[int[]]@(foreach($ch in $word.Phones.ToCharArray()){if($vocab.ContainsKey([string]$ch)){$vocab[[string]$ch]}else{-1}})
            $aligned.Add($word)
        }
        if($valid -and $alignedCount -eq $audible.Count){$capture.AlignedWords=$aligned.ToArray();$capture.Alignment='ExactSourceSpansAndWordOnsets'}
        if(-not $NoSave){$null=Save-EnglishZiraObservation -Capture $capture}
        $capture
    }finally{
        foreach($source in $sources){Unregister-Event -SourceIdentifier $source -ErrorAction SilentlyContinue;Get-Event -SourceIdentifier $source -ErrorAction SilentlyContinue | Remove-Event}
        $synth.Dispose()
    }
}

function ConvertTo-EnglishKokoroPhones {
    param([string]$Phones)
    $Phones.Replace('i͡ə','iə').Replace('t͡ʃ','ʧ').Replace('d͡ʒ','ʤ').Replace('a͡ɪ','I').Replace('e͡ɪ','A').Replace('o͡ʊ','O').Replace('a͡ʊ','W').Replace('ɔ͡ɪ','Y').Replace('a͡i','I').Replace('e͡i','A').Replace('o͡u','O').Replace('a͡u','W').Replace('ɔ͡i','Y').Replace('ɻ','ɹ').Replace('ɚ','əɹ').Replace('ɝ','ɜɹ').Replace('g','ɡ').Replace('tʃ','ʧ').Replace('dʒ','ʤ').Replace('aɪ','I').Replace('eɪ','A').Replace('oʊ','O').Replace('aʊ','W').Replace('ɔɪ','Y')
}

function Get-EnglishPhoneComparison {
    param([AllowNull()][string]$Phones)
    if($null -eq $Phones){return ''}
    (ConvertTo-EnglishKokoroPhones $Phones).Replace('ˈ','').Replace('ˌ','')
}

function Invoke-EnglishZiraDistillation {
    [CmdletBinding()]
    param([string]$TrainingFile=$CorpusPath,[string]$AdmissionFile=$ValidationCorpusPath)
    $training=if($TrainingFile){@([IO.File]::ReadAllLines($TrainingFile) | Where-Object {$_ -match '\S'})}else{@('Play the record.','Please record it.','Push record.')}
    $admission=if($AdmissionFile){@([IO.File]::ReadAllLines($AdmissionFile) | Where-Object {$_ -match '\S'})}else{@('They play the record.','They record it.','We record the record.')}
    if(-not $training.Count -or -not $admission.Count){throw 'Separate construction and held-out corpora required.'}
    foreach($text in $training){if($text -cin $admission){throw 'Construction and held-out sentences overlap.'}}
    $info=Get-Item -LiteralPath $ObservationPath
    if($info.Length -gt 134217728){throw 'Admission source exceeds 128 MiB bound.'}
    $data=Import-PowerShellDataFile -LiteralPath $info.FullName -SkipLimitCheck
    if($data.v -ne 1 -or $data.q -ne 1 -or $data.u.Count -gt 4096){throw 'Admission corpus contract failure.'}
    $captures=@(foreach($record in $data.u){$r=@{}+$record;$r.v=1;$r.q=1;$r.a=$data.a;$r.g=$data.g;Import-EnglishZiraObservation -Path $info.FullName -Data $r})
    foreach($text in @($training)+@($admission)){if(-not @($captures | Where-Object Text -ceq $text).Count){throw ('Emit this sentence before admission: '+$text)}}
    $reference=Import-EnglishReference $AssemblyPath;$rows=[Collections.Generic.List[object]]::new()
    foreach($capture in $captures){
        $partition=if($capture.Text -cin $training){'C'}elseif($capture.Text -cin $admission){'H'}else{'U'}
        $capture.Partition=$partition
        if($capture.Alignment -cne 'ExactSourceSpansAndWordOnsets'){continue}
        $context=New-EnglishContext -Corrections ''
        $result=Invoke-EnglishPhonemizer -Text $capture.Text -Context $context
        foreach($word in $capture.AlignedWords){
            $tokens=@($result.Tokens | Where-Object {$_.SourceStart -eq $word.Start -and $_.SourceEnd -eq $word.Start+$word.Length})
            if($tokens.Count -ne 1){continue};$token=$tokens[0];$word.Roles=[int[]]$token.Roles
            if($word.Roles.Count -eq 1 -and $word.Roles[0] -ge 0){$word.Role=$word.Roles[0]}else{continue}
            $key=Get-EnglishCorrectionKey $context $context.Occurrences[$token.Identity] $word.Role
            $rows.Add([pscustomobject]@{Partition=$partition;Key=$key;Word=$word;Capture=$capture;Token=$token})
        }
    }
    $choices=[Collections.Generic.List[object]]::new();$accepted=0;$rejected=0;$checks=0
    foreach($group in @($rows | Where-Object Partition -ceq 'C' | Group-Object Key)){
        $choice=[EnglishZiraChoice]::new();$choice.Key=$group.Name
        $values=@($group.Group.Word.Phones | Sort-Object -Unique -CaseSensitive)
        $choice.ConstructionSupport=@($group.Group.Capture.Text | Sort-Object -Unique -CaseSensitive).Count
        $held=@($rows | Where-Object {$_.Partition -ceq 'H' -and $_.Key -ceq $choice.Key})
        $choice.AdmissionCases=$held.Count
        $choice.Captures=[EnglishZiraUtterance[]]@(@($group.Group)+@($held) | ForEach-Object Capture | Sort-Object Identity -Unique)
        $choice.Reason='MissingHeldOutSupport';$choice.StressSource='Unproved'
        if($values.Count -ne 1){$choice.Reason='ConflictingTeacherObservations'}else{
            $choice.Pronunciation=$values[0]
            $valid=$choice.Key -cnotmatch ':2$' -and $held.Count -gt 0
            foreach($row in $held){
                $before=(Get-EnglishPhoneComparison $row.Token.Pron) -ceq $row.Word.Phones
                $after=$row.Word.Phones -ceq $values[0]
                if(-not $before -and $after){$choice.Fixes++}
                if($before -and -not $after){$choice.Regressions++}
                if(-not $after){$valid=$false;$choice.Reason='HeldOutTeacherConflict'}
            }
            if($choice.Key.EndsWith(':2')){$choice.Reason='UnknownFollowingOnset'}
            foreach($ch in $choice.Pronunciation.ToCharArray()){if($reference.SymbolId.Invoke($ch) -lt 0){$valid=$false;$choice.Reason='UnknownKokoroPhone'}}
            if($valid){
                # Retain earned lexical stress only when its unstressed phones equal the teacher.
                $token=$group.Group[0].Token
                $variants=@($reference.Phones.Invoke($token.LexicalId,$token.Roles[0]).Split('|',[StringSplitOptions]::RemoveEmptyEntries))
                $matching=@($variants | Where-Object {(Get-EnglishPhoneComparison $_) -ceq $values[0]})
                if($matching.Count -eq 1){$choice.Pronunciation=$matching[0];$choice.StressSource='ExistingLexicalStress';$choice.Admitted=$true;$choice.Reason='IndependentTeacherAgreement'}
                elseif(@($variants | Where-Object {$_ -match '[ˈˌ]'}).Count){$choice.Reason='ChangedPronunciationWithoutObservedStress'}
                else{$choice.Admitted=$true;$choice.Reason='IndependentTeacherAgreement'}
            }
            $choice.SymbolIds=[int[]]@($choice.Pronunciation.ToCharArray() | ForEach-Object {$reference.SymbolId.Invoke($_)})
        }
        if($choice.Admitted){$accepted++;$checks+=$held.Count}else{$rejected++}
        $choices.Add($choice)
    }
    # Preserve prior decisions and their complete observation graph.
    $all=[Collections.Generic.List[object]]::new();foreach($capture in $captures){$all.Add($capture)}
    if(Test-Path -LiteralPath $CorrectionPath){
        $previous=Import-EnglishZiraCorpus $CorrectionPath
        foreach($capture in $previous.Captures){if(-not @($all | Where-Object Identity -ceq $capture.Identity).Count){$all.Add($capture)}}
        foreach($choice in $previous.Entries){if(-not @($choices | Where-Object Key -ceq $choice.Key).Count){$choices.Add($choice)}}
    }
    # The single intermediary is updated with inferred role opcodes; raw evidence stays intact.
    Copy-Item -LiteralPath $ObservationPath -Destination ($ObservationPath+'.'+[guid]::NewGuid().ToString('N')+'.before')
    $writer=[IO.StreamWriter]::new($ObservationPath,$false,[Text.UTF8Encoding]::new($false))
    try{
        $writer.WriteLine('@{v=1;q=1;s='+(Get-EnglishTypedLiteral $data.s)+';u=@(')
        for($i=0;$i -lt $captures.Count;$i++){
            $capture=$captures[$i];if($i){$writer.WriteLine(',')}
            $literal=Save-EnglishZiraObservation $capture -SourceOnly
            $literal=$literal.Replace('v=1;q=1;','').Replace(';a='+(Get-EnglishTypedLiteral $capture.AssemblySha256),'').Replace(';g='+(Get-EnglishTypedLiteral $capture.EngineSha256),'')
            $writer.Write($literal.TrimEnd())
        }
        $writer.WriteLine(');a='+(Get-EnglishTypedLiteral $data.a)+';g='+(Get-EnglishTypedLiteral $data.g)+'}')
    }finally{$writer.Dispose()}
    $compiled=Export-EnglishZiraCorpus -Captures $all.ToArray() -Entries $choices.ToArray() -Pointer $CorrectionPath
    $script:EnglishCoreCache=@{};$script:EnglishCorrectionCache=@{}
    $driver=Import-EnglishCoreDriver;$runtimeChecks=0
    foreach($row in @($rows | Where-Object Partition -ceq 'H')){
        if(-not @($choices | Where-Object {$_.Admitted -and $_.Key -ceq $row.Key}).Count){continue}
        $r=$driver.Run.Invoke($row.Capture.Text);$tokens=@($r.Tokens | Where-Object {$_.SourceStart -eq $row.Word.Start -and $_.SourceEnd -eq $row.Word.Start+$row.Word.Length})
        Assert-EnglishContract 'admitted Zira knowledge reaches canonical driver' ($tokens.Count -eq 1 -and $tokens[0].PronunciationSource -ceq 'ZiraCorrection' -and (Get-EnglishPhoneComparison $tokens[0].Pron) -ceq $row.Word.Phones)
        $runtimeChecks++
    }
    [pscustomobject]@{Gate=if($runtimeChecks -gt 0){'ZIRA_CONTEXTUAL_ADMISSION=PASS'}else{'ZIRA_OBSERVATIONS_ONLY'};Captures=$all.Count;NewAdmitted=$accepted;Rejected=$rejected;HeldOutComparisons=$checks;CanonicalTeacherChecks=$runtimeChecks;Observation=$ObservationPath;TypedCorpus=$compiled.Output;Driver=$driver.Output;Stress='Retained only when independently matching teacher segmental phones';HillclimberUsed=$false}
}

function Initialize-EnglishKokoro {
    [CmdletBinding()]
    param([string]$Directory=$KokoroDirectory,[string]$VoiceName=$Voice)
    if(-not $IsWindows){throw 'The stock Kokoro reference adapter requires Windows.'}
    if($VoiceName -cnotin @('af_heart','am_michael')){throw 'Voice is not in the pinned stock input set.'}
    $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Build\PSPerception'))+'\'
    $Directory=[IO.Path]::GetFullPath($Directory)
    if(-not $Directory.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Kokoro acquisition must stay under the project build directory.'}
    [void][IO.Directory]::CreateDirectory($Directory)
    $revision='f3ff3571791e39611d31c381e3a41a3af07b4987'
    $pins=@{'kokoro-v1_0.pth'='496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4';'config.json'='5ABB01E2403B072BF03D04FDE160443E209D7A0DAD49A423BE15196B9B43C17F';'voices/af_heart.pt'='0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF';'voices/am_michael.pt'='9A443B79A4B22489A5B0AB7C651A0BCD1A30BEF675C28333F06971ABBD47BD37'}
    $inputs=@{}
    foreach($name in @('kokoro-v1_0.pth','config.json',"voices/$VoiceName.pt")){
        $local=Join-Path 'C:\models\Kokoro-82M' $name
        $path=if(Test-Path -LiteralPath $local){$local}else{Join-Path $Directory $name}
        if(-not(Test-Path -LiteralPath $path)){
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            Invoke-WebRequest -Uri "https://huggingface.co/hexgrad/Kokoro-82M/resolve/$revision/$name" -OutFile $path
        }
        if((Get-FileHash -LiteralPath $path).Hash -cne $pins[$name]){throw 'Pinned stock Kokoro input integrity failure.'}
        $inputs[$name]=@{Path=$path;Sha256=$pins[$name]}
    }
    $commit='dfb907a02bba8152ca444717ca5d78747ccb4bec'
    $source=Join-Path $Directory $commit
    $vendor='C:\Dev\.vendor\kokoro'
    if(-not(Test-Path -LiteralPath $source)){
        $archive=Join-Path $Directory 'stock-source.zip'
        & git -C $vendor archive --format=zip "--output=$archive" $commit kokoro
        if($LASTEXITCODE){throw 'Pinned upstream source acquisition failed.'}
        [IO.Compression.ZipFile]::ExtractToDirectory($archive,$source)
    }
    $files=@(foreach($file in Get-ChildItem -LiteralPath (Join-Path $source 'kokoro') -Filter '*.py' -File){
        $relative='kokoro/'+$file.Name
        $blob=(& git -C $vendor rev-parse "${commit}:$relative").Trim()
        if($LASTEXITCODE){throw 'Pinned stock source identity unavailable.'}
        $actual=(& git hash-object --no-filters -- $file.FullName).Trim()
        if($LASTEXITCODE -or $actual -cne $blob){throw 'Cached stock source differs from the immutable upstream commit.'}
        @{Path=$relative;Sha256=(Get-FileHash -LiteralPath $file.FullName).Hash}
    })
    [pscustomobject]@{Directory=$Directory;SourceRoot=$source;SourceCommit=$commit;SourceFiles=$files;Inputs=$inputs;ModelRevision=$revision}
}

function Invoke-EnglishZiraPhones {
    param([Parameter(Mandatory)][string]$Text)
    $capture=Get-EnglishZiraReference -Text $Text
    if($capture.Alignment -cne 'ExactSourceSpansAndWordOnsets'){throw 'Zira source alignment is unproved; direct teacher speech requires complete word spans.'}
    $driver=Import-EnglishCoreDriver
    $parts=[Collections.Generic.List[string]]::new();$tokens=[Collections.Generic.List[object]]::new();$at=0
    foreach($word in $capture.AlignedWords){
        $gap=$Text.Substring($at,$word.Start-$at)
        if($gap -match '[^\s.,!?;:()\-]'){throw 'Zira omitted a source span; synthesis refused.'}
        foreach($ch in $gap.ToCharArray()){if(-not [char]::IsWhiteSpace($ch)){$parts.Add([string]$ch)}}
        $phone=$driver.NormalizeZira.Invoke($word.RawPhones);$parts.Add($phone)
        $tokens.Add([pscustomobject]@{Word=$word.Word;Roles=@();Pron=$phone;PronunciationSource='ZiraEvents';SourceStart=$word.Start;SourceEnd=$word.Start+$word.Length})
        $at=$word.Start+$word.Length
    }
    $tail=$Text.Substring($at)
    if($tail -match '[^\s.,!?;:()\-]'){throw 'Zira omitted a trailing source span; synthesis refused.'}
    foreach($ch in $tail.ToCharArray()){if(-not [char]::IsWhiteSpace($ch)){$parts.Add([string]$ch)}}
    $phones=$parts.ToArray() -join ' '
    $ids=$driver.ZiraTokenIds.Invoke($phones)
    [pscustomobject]@{Complete=$true;KokoroPhones=$phones;SymbolIds=$ids;Tokens=$tokens.ToArray();Execution='Zira captured events mapped by lowered CoreLib driver';Capture=$capture.CapturePath;CaptureSha256=(Get-FileHash -LiteralPath $capture.CapturePath).Hash}
}

function Invoke-EnglishKokoroSpeech {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateLength(1,8192)][string]$Text)
    $result=if($UseZira){Invoke-EnglishZiraPhones -Text $Text}else{Invoke-EnglishPhonemizer -Text $Text}
    if(-not $result.Complete){throw ('Phonemizer cannot resolve the complete phrase: '+(($result.UnresolvedSpans | ForEach-Object {$_.Word+':'+$_.Status}) -join ', '))}
    if($result.KokoroPhones.Length -gt 510){throw 'Kokoro accepts at most 510 phones per utterance.'}
    $assets=Initialize-EnglishKokoro
    $run=Join-Path $assets.Directory ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($run)
    $spec=@{SourceRoot=$assets.SourceRoot;SourceCommit=$assets.SourceCommit;SourceFiles=$assets.SourceFiles;Inputs=$assets.Inputs;ModelRevision=$assets.ModelRevision;Voice=$Voice;Speed=$Speed;Text=$Text;Phonemes=$result.KokoroPhones;SymbolIds=$result.SymbolIds;Phonemizer=$result.Execution;AuthorSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;Output=$run;Tokens=@($result.Tokens | Select-Object Word,Roles,Pron,PronunciationSource)}
    $spec.CorrectionTableSha256=if(-not $UseZira -and (Test-Path -LiteralPath $CorrectionPath)){(Get-FileHash -LiteralPath $CorrectionPath).Hash}else{$null}
    if($UseZira){$spec.ZiraCapture=$result.Capture;$spec.ZiraCaptureSha256=$result.CaptureSha256}

    # Windows reference-only transport; the portable phonemizer never imports it.
    $adapter=@'
import hashlib, importlib, pathlib, sys, types, wave
spec = {'SourceRoot':sys.argv[1], 'Voice':sys.argv[9], 'Speed':float(sys.argv[7]), 'Phonemes':sys.argv[5], 'SymbolIds':[int(v) for v in sys.argv[6].split(',')], 'Output':sys.argv[8]}
spec['SourceFiles'] = [{'Path':v.rsplit('|',1)[0], 'Sha256':v.rsplit('|',1)[1]} for v in sys.argv[10:]]
spec['Inputs'] = {'kokoro-v1_0.pth':{'Path':sys.argv[2], 'Sha256':'496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4'}, 'config.json':{'Path':sys.argv[3], 'Sha256':'5ABB01E2403B072BF03D04FDE160443E209D7A0DAD49A423BE15196B9B43C17F'}, 'voices/'+spec['Voice']+'.pt':{'Path':sys.argv[4], 'Sha256':{'af_heart':'0AB5709B8FFAB19BFD849CD11D98F75B60AF7733253AD0D67B12382A102CB4FF', 'am_michael':'9A443B79A4B22489A5B0AB7C651A0BCD1A30BEF675C28333F06971ABBD47BD37'}[spec['Voice']]}}
root = pathlib.Path(spec['SourceRoot'])
def verify(path, expected):
    with open(path, 'rb') as f:
        if hashlib.file_digest(f, 'sha256').hexdigest().upper() != expected:
            raise ValueError('Stock reference integrity failure')
for item in spec['SourceFiles']:
    verify(root / item['Path'], item['Sha256'])
for item in spec['Inputs'].values():
    verify(item['Path'], item['Sha256'])
package = types.ModuleType('kokoro')
package.__path__ = [str(root / 'kokoro')]
sys.modules['kokoro'] = package
import torch
from loguru import logger
logger.remove()
torch.set_num_threads(4)
torch.manual_seed(17)
model = importlib.import_module('kokoro.model').KModel(repo_id='hexgrad/Kokoro-82M', config=spec['Inputs']['config.json']['Path'], model=spec['Inputs']['kokoro-v1_0.pth']['Path']).eval()
checkpoint = torch.load(spec['Inputs']['kokoro-v1_0.pth']['Path'], map_location='cpu', weights_only=True)
for component, values in checkpoint.items():
    loaded = getattr(model, component).state_dict()
    for original, expected in values.items():
        key = original.removeprefix('module.')
        if key not in loaded:
            key = key.replace('weight_g','parametrizations.weight.original0').replace('weight_v','parametrizations.weight.original1')
        if key not in loaded or not torch.equal(expected, loaded[key]):
            raise ValueError('Stock checkpoint parameter mismatch')
pack = torch.load(spec['Inputs']['voices/' + spec['Voice'] + '.pt']['Path'], map_location='cpu', weights_only=True)
phones = spec['Phonemes']
if not 1 <= len(phones) <= min(510, len(pack)) or any(p not in model.vocab for p in phones):
    raise ValueError('Invalid stock phoneme input')
if [model.vocab[p] for p in phones] != spec['SymbolIds']:
    raise ValueError('SMA and stock Kokoro token IDs disagree')
with torch.inference_mode():
    audio = model(phones, pack[len(phones)-1], speed=spec['Speed']).float().cpu().numpy()
import numpy as np
if not np.isfinite(audio).all() or len(audio) == 0 or np.max(np.abs(audio)) == 0:
    raise ValueError('Invalid stock waveform')
pcm = (np.clip(audio, -1, 1) * 32767).astype('<i2').tobytes()
output = pathlib.Path(spec['Output']) / 'speech.wav'
with wave.open(str(output), 'wb') as wav:
    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000); wav.writeframes(pcm)
print('Stock Kokoro WAV created: samples=' + str(len(audio)) + '; sample_rate=24000')
'@
    $adapterPath=Join-Path $run 'stock-reference.py'
    [IO.File]::WriteAllText($adapterPath,$adapter,[Text.UTF8Encoding]::new($false))
    $arguments=@($adapterPath,$assets.SourceRoot,$assets.Inputs['kokoro-v1_0.pth'].Path,$assets.Inputs['config.json'].Path,$assets.Inputs['voices/'+$Voice+'.pt'].Path,$result.KokoroPhones,($result.SymbolIds -join ','),$Speed.ToString([Globalization.CultureInfo]::InvariantCulture),$run,$Voice)+@($assets.SourceFiles | ForEach-Object {$_.Path+'|'+$_.Sha256})
    $messages=@(& $PythonPath @arguments)
    if($LASTEXITCODE){throw 'Stock Kokoro reference synthesis failed.'}
    $sampleMessages=@($messages | Where-Object {$_ -match '^Stock Kokoro WAV created: samples=([0-9]+); sample_rate=24000$'})
    if($sampleMessages.Count -ne 1 -or $sampleMessages[0] -notmatch 'samples=([0-9]+)'){throw 'Stock waveform sample receipt missing.'}
    $samples=[int]$Matches[1];$wave=Join-Path $run 'speech.wav'
    if($samples -le 0 -or (Get-Item -LiteralPath $wave).Length -ne 44+2L*$samples){throw 'Stock PCM waveform length disagreement.'}
    $stream=[IO.File]::OpenRead($wave);$reader=[IO.BinaryReader]::new($stream)
    try{
        if([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -cne 'RIFF'){throw 'Missing WAV RIFF header.'}
        $stream.Position=20
        if($reader.ReadUInt16() -ne 1 -or $reader.ReadUInt16() -ne 1 -or $reader.ReadUInt32() -ne 24000){throw 'Unexpected WAV encoding.'}
        $stream.Position=34;if($reader.ReadUInt16() -ne 16){throw 'Unexpected PCM bit depth.'}
    }finally{$reader.Dispose()}
    $metadata=[ordered]@{Gate='PHONEMIZER_TO_STOCK_KOKORO_WAV=PASS';Phonemizer=$result.Execution;Phonemes=$result.KokoroPhones;SymbolIds=$result.SymbolIds;Samples=$samples;SampleRate=24000;Seconds=$samples/24000.0;Wave=$wave;WaveSha256=(Get-FileHash -LiteralPath $wave).Hash;SourceCommit=$assets.SourceCommit;ModelRevision=$assets.ModelRevision;Voice=$Voice;AuthorSha256=$spec.AuthorSha256;TokenCount=$result.Tokens.Count}
    if($UseZira){$metadata.ZiraCapture=$result.Capture;$metadata.ZiraCaptureSha256=$result.CaptureSha256}
    $driver=Import-EnglishCoreDriver;$metadata.Driver=$driver.Output;$metadata.DriverSha256=(Get-FileHash -LiteralPath $driver.Output).Hash
    if(-not $UseZira -and (Test-Path -LiteralPath $CorrectionPath)){$metadata.CorrectionTableSha256=(Get-FileHash -LiteralPath $CorrectionPath).Hash}
    Write-EnglishBuildReceipt (Join-Path $run 'receipt.psd1') $metadata
    $receipt=[pscustomobject]$metadata
    if(-not $NoPlayback){
        $null=[Reflection.Assembly]::LoadFrom((Join-Path $PSHOME 'System.Windows.Extensions.dll'))
        $player=[System.Media.SoundPlayer]::new($receipt.Wave)
        try{$player.PlaySync()}finally{$player.Dispose()}
    }
    $receipt | Add-Member -NotePropertyName PlaybackRequested -NotePropertyValue (-not $NoPlayback)
    $receipt
}

function New-EnglishZiraCorpus {
    $directory=Join-Path $env:LOCALAPPDATA ('Build\PSPerception\english\corpora\'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $construction=[Collections.Generic.List[string]]::new();$heldout=[Collections.Generic.List[string]]::new()
    foreach($noun in @('record','present','permit','book','song','music','door','clock','apple','orange','elephant','actor','hour','university','idea','computer','buffer','file','number','date','voice','window','pipe','team','teacher','leaf','key')){
        $construction.Add('The '+$noun+' is here.');$construction.Add('I saw the '+$noun+'.')
        $heldout.Add('We saw the '+$noun+' today.')
    }
    foreach($verb in @('record','present','permit','close','wind','lead','read','write','watch','open','find')){
        $construction.Add('They '+$verb+' the book.');$construction.Add('We '+$verb+' the record.')
        $heldout.Add('They '+$verb+' the book every day.')
    }
    foreach($adj in @('live','closed','open','red','heavy','useful','new','old','small','large')){
        $construction.Add('The door is '+$adj+'.');$construction.Add('The book is '+$adj+'.')
        $heldout.Add('The record is '+$adj+'.')
    }
    foreach($n in @(0,1,12,64,1024)){
        $construction.Add('The value is '+$n+'.');$heldout.Add('The file is '+$n+' KB.')
    }
    foreach($phrase in @('The meeting is on October 8, 2026.','The total is $12.50.','The file is 12 MB.','They had read the book.','They will read the book tomorrow.','Alice cannot find her keys.')){$construction.Add($phrase)}
    foreach($phrase in @('The meeting is on November 9, 2027.','The total is $24.75.','The file is 32 MB.','We had read the record.','They read the book yesterday.','John cannot find his keys.')){$heldout.Add($phrase)}
    foreach($sentence in $construction){if($sentence -cin $heldout){throw 'Corpus partitions overlap.'}}
    $trainingPath=Join-Path $directory 'construction.txt';$heldoutPath=Join-Path $directory 'held-out.txt'
    [IO.File]::WriteAllLines($trainingPath,$construction.ToArray(),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($heldoutPath,$heldout.ToArray(),[Text.UTF8Encoding]::new($false))
    $receipt=[ordered]@{Version=1;Generator='PowerShell authored sentence templates';ConstructionSentences=$construction.Count;HeldOutSentences=$heldout.Count;Construction=$trainingPath;ConstructionSha256=(Get-FileHash -LiteralPath $trainingPath).Hash;HeldOut=$heldoutPath;HeldOutSha256=(Get-FileHash -LiteralPath $heldoutPath).Hash;Purpose='Zira contextual pronunciation capture and independent held-out context evaluation';Coverage='Seed corpus; not comprehensive English';AuthorSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash}
    Write-EnglishBuildReceipt (Join-Path $directory 'corpus.psd1') $receipt
    [pscustomobject]$receipt
}

function Test-EnglishZiraTokenParity {
    [CmdletBinding()]
    param([string]$Path=$CorpusPath)
    $driver=Import-EnglishCoreDriver
    $configPath=Join-Path $env:LOCALAPPDATA 'Build\PSPerception\kokoro-config.json'
    $configHash=(Get-FileHash -LiteralPath $configPath).Hash
    if($configHash -cne '5ABB01E2403B072BF03D04FDE160443E209D7A0DAD49A423BE15196B9B43C17F'){throw 'Kokoro vocabulary integrity failure.'}
    $config=Get-EnglishKokoroSpecification
    $vocab=$config.vocab
    $compiledSymbolId=[Func[char,int]]$driver.Assembly.GetType('Phonology',$true).GetMethod('SymbolId').CreateDelegate([Func[char,int]])
    foreach($symbol in $vocab.Keys){Assert-EnglishContract 'all compiled target vocabulary IDs independently match pinned config' ($compiledSymbolId.Invoke($symbol[0]) -eq $vocab[$symbol])}
    foreach($pair in @(@('ɻɚɝgtʃdʒaɪeɪoʊaʊɔɪ','ɹəɹɜɹɡʧʤIAOWY'),@('t͡ʃd͡ʒa͡ie͡io͡ua͡uɔ͡i','ʧʤIAOWY'),@('a͡idi͡ə','Idiə'),@('ðə ɻɛkəɻd','ðə ɹɛkəɹd'),@('ˈɛˌɪ','ˈɛˌɪ'))){
        Assert-EnglishContract 'fixed Zira symbol conversion specimen' ($driver.NormalizeZira.Invoke($pair[0]) -ceq $pair[1])
    }
    foreach($invalid in @('∑',([string][char]1),('x'*8193))){
        $rejected=$false;try{$null=$driver.ZiraTokenIds.Invoke($invalid)}catch{$rejected=$true}
        Assert-EnglishContract 'unsupported and over-bound raw phones are rejected' $rejected
    }
    if($Path){
        $info=Get-Item -LiteralPath $Path
        if($info.Length -gt 1048576){throw 'Corpus size bound exceeded.'}
        $sentences=@([IO.File]::ReadAllLines($info.FullName) | Where-Object {$_ -match '\S'})
        if($sentences.Count -lt 1 -or $sentences.Count -gt 4096){throw 'Corpus sentence bound exceeded.'}
        $captures=@(foreach($sentence in $sentences){Get-EnglishZiraReference -Text $sentence})
        $corpusHash=(Get-FileHash -LiteralPath $info.FullName).Hash
    }else{
        if(Test-Path -LiteralPath $ObservationPath){
            $info=Get-Item -LiteralPath $ObservationPath
            if($info.Length -gt 134217728){throw 'Parity source exceeds 128 MiB bound.'}
            $data=Import-PowerShellDataFile -LiteralPath $info.FullName -SkipLimitCheck
            if($data.v -ne 1 -or $data.q -ne 1 -or $data.u.Count -gt 4096){throw 'Parity corpus contract failure.'}
            $captures=@(foreach($record in $data.u){$r=@{}+$record;$r.v=1;$r.q=1;$r.a=$data.a;$r.g=$data.g;Import-EnglishZiraObservation -Path $info.FullName -Data $r})
        }else{
            $files=@(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Build\PSPerception\english\zira-captures') -Filter '*.psd1' -File)
            if($files.Count -lt 1 -or $files.Count -gt 4096){throw 'Capture inventory bound exceeded.'}
            $captures=@(foreach($file in $files){Import-EnglishZiraObservation -Path $file.FullName})
        }
        $corpusHash=$null
    }
    $rows=[Collections.Generic.List[object]]::new();$observations=[Collections.Generic.List[object]]::new();$totalIds=0;$excluded=0;$rawCases=[Collections.Generic.List[string]]::new()
    foreach($capture in $captures){
        if($capture.Version -ne 1 -or $capture.Voice -cne 'Microsoft Zira Desktop'){throw 'Unexpected capture contract or voice.'}
        $events=@($capture.Phones | Where-Object {$_.Phone.Length -gt 0 -and -not [char]::IsControl($_.Phone[0])})
        $excluded+=$capture.Phones.Count-$events.Count
        # Exact, captured word boundaries are useful; unproved alignment never supplies invented boundaries.
        $raw=if($capture.Alignment -ceq 'ExactSourceSpansAndWordOnsets'){@($capture.AlignedWords.RawPhones) -join ' '}else{$events.Phone -join ''}
        $normalized=$driver.NormalizeZira.Invoke($raw)
        $unsupported=@($normalized.ToCharArray() | Where-Object {-not $vocab.ContainsKey([string]$_)} | Sort-Object -Unique)
        if($unsupported.Count){throw ('Unmapped Zira phones in specimen "'+$capture.Text+'": '+(($unsupported | ForEach-Object {'U+'+[Convert]::ToInt32($_).ToString('X4')}) -join ', '))}
        $ids=$driver.ZiraTokenIds.Invoke($raw)
        $expected=[int[]]@(foreach($ch in $normalized.ToCharArray()){
            if(-not $vocab.ContainsKey([string]$ch)){throw 'Teacher phone outside pinned Kokoro vocabulary.'}
            $vocab[[string]$ch]
        })
        Assert-EnglishContract 'captured Zira mapping has no dropped symbols' ($ids.Length -eq $normalized.Length -and ($ids -join ',') -ceq ($expected -join ','))
        Assert-EnglishContract 'compiled map agrees with independently authored conversion fixtures and script map' ($normalized -ceq (ConvertTo-EnglishKokoroPhones $raw))
        Assert-EnglishContract 'Kokoro model context length' ($ids.Length+2 -le $config.plbert.max_position_embeddings)
        $totalIds+=$ids.Length;$rawCases.Add($raw)
        $rows.Add([pscustomobject]@{Text=$capture.Text;RawZiraPhones=$raw;KokoroPhones=$normalized;SymbolIds=$ids;ModelInputIds=([int[]]@(0)+$ids+[int[]]@(0));WordAlignment=$capture.Alignment;Capture=$capture.CapturePath;CaptureSha256=(Get-FileHash -LiteralPath $capture.CapturePath).Hash;LexicalSource='Zira captured events; no dictionary pronunciation lookup'})
        if($capture.Alignment -ceq 'ExactSourceSpansAndWordOnsets'){
            foreach($word in $capture.AlignedWords){
                $wordPhones=$driver.NormalizeZira.Invoke($word.RawPhones)
                $observations.Add([pscustomobject]@{Word=$word.Word.ToLowerInvariant();Text=$capture.Text;Start=$word.Start;End=$word.Start+$word.Length;RawZiraPhones=$word.RawPhones;KokoroPhones=$wordPhones;SymbolIds=$driver.ZiraTokenIds.Invoke($word.RawPhones);LexicalStress='Unproved';Role='Unassigned';Capture=$capture.CapturePath})
            }
        }
    }
    $directory=Join-Path $env:LOCALAPPDATA ('Build\PSPerception\english\token-parity\'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $externalPath=Join-Path $directory 'standalone.psd1'
    & $DotnetPath $driver.Output --zira $rawCases[0] $externalPath
    $status=$LASTEXITCODE;$external=Import-PowerShellDataFile -LiteralPath $externalPath
    Assert-EnglishContract 'standalone Zira token map has no SMA and preserves all IDs' ($status -eq 0 -and -not $external.RuntimeSmaLoaded -and $external.KokoroPhones -ceq $rows[0].KokoroPhones -and ($external.SymbolIds -join ',') -ceq ($rows[0].SymbolIds -join ','))
    $null=$driver.ZiraBatch.Invoke($rawCases[0],1000)
    $samples=[Collections.Generic.List[double]]::new();$runs=2000
    foreach($batch in 1..9){
        $watch=[Diagnostics.Stopwatch]::StartNew();$count=$driver.ZiraBatch.Invoke($rawCases[0],$runs);$watch.Stop()
        Assert-EnglishContract 'compiled token benchmark retains outputs' ($count -eq $rows[0].SymbolIds.Length*$runs)
        $samples.Add($watch.Elapsed.TotalMilliseconds*1000/$runs)
    }
    $ordered=@($samples | Sort-Object)
    $phonemizerSamples=[Collections.Generic.List[double]]::new();$null=$driver.Batch.Invoke('The record records the record.',200)
    foreach($batch in 1..9){
        $watch=[Diagnostics.Stopwatch]::StartNew();$null=$driver.Batch.Invoke('The record records the record.',500);$watch.Stop()
        $phonemizerSamples.Add($watch.Elapsed.TotalMilliseconds*1000/500)
    }
    $graphOrdered=@($phonemizerSamples | Sort-Object)
    $report=[ordered]@{Gate='ZIRA_TO_KOKORO_TOKEN_PARITY=PASS';Captures=$rows.Count;MappedSymbols=$totalIds;DroppedSymbols=0;PauseOrControlEventsExcluded=$excluded;VocabularySymbols=$vocab.Count;ConfigSha256=$configHash;ModelRevision='f3ff3571791e39611d31c381e3a41a3af07b4987';CorpusSha256=$corpusHash;ReferenceBoundary='KModel.forward pinned dfb907a02bba8152ca444717ca5d78747ccb4bec; config vocabulary IDs plus zero BOS/EOS';SeparateProcessSmaLoaded=$external.RuntimeSmaLoaded;TokenMapMedianBatchMeanUs=$ordered[4];TokenMapMaxBatchMeanUs=$ordered[8];TokenMapBatchMeansUs=$samples.ToArray();TokenMapFixture=$rows[0].Text;FullDriverMedianBatchMeanUs=$graphOrdered[4];FullDriverMaxBatchMeanUs=$graphOrdered[8];FullDriverBatchMeansUs=$phonemizerSamples.ToArray();FullDriverFixture='The record records the record.';FullDriverLexiconOrigin='Existing Moby plus admitted corrections; distinct from dictionary-free Zira token mapping';TimingBoundary='Warm compiled managed loops; 9 batches; excludes capture, build, process startup and synthesis';MachineCondition='Current observed Windows load; not an idle-machine baseline';Accuracy='Token parity only; contextual pronunciation quality, stress and unseen-word coverage need separate gates';Driver=$driver.Output;DriverSha256=(Get-FileHash -LiteralPath $driver.Output).Hash}
    $receipt=Join-Path $directory 'parity.psd1';Write-EnglishBuildReceipt $receipt $report
    [pscustomobject]$report | Add-Member -NotePropertyName Receipt -NotePropertyValue $receipt -PassThru
}

function Get-EnglishSymbolDistance {
    param([string]$Expected,[string]$Actual)
    $prior=[int[]]::new($Actual.Length+1)
    for($j=0;$j -le $Actual.Length;$j++){$prior[$j]=$j}
    for($i=1;$i -le $Expected.Length;$i++){
        $next=[int[]]::new($Actual.Length+1);$next[0]=$i
        for($j=1;$j -le $Actual.Length;$j++){
            $cost=if($Expected[$i-1] -ceq $Actual[$j-1]){0}else{1}
            $next[$j]=[Math]::Min([Math]::Min($prior[$j]+1,$next[$j-1]+1),$prior[$j-1]+$cost)
        }
        $prior=$next
    }
    $prior[$Actual.Length]
}

function Test-EnglishPronunciationCorpus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $Path=[IO.Path]::GetFullPath($Path)
    $info=Get-Item -LiteralPath $Path
    if($info.Length -gt 1048576){throw 'Evaluation corpus size bound exceeded.'}
    $sentences=@([IO.File]::ReadAllLines($Path) | Where-Object {$_ -match '\S'})
    if($sentences.Count -eq 0 -or $sentences.Count -gt 4096){throw 'Evaluation corpus sentence bound exceeded.'}
    $driver=Import-EnglishCoreDriver
    $rows=[Collections.Generic.List[object]]::new()
    $words=0;$supported=0;$compared=0;$matched=0;$edits=0;$symbols=0;$alignmentFailures=0;$complete=0
    foreach($sentence in $sentences){
        $capture=Get-EnglishZiraReference -Text $sentence
        $candidate=Invoke-EnglishPhonemizer -Text $sentence
        if($candidate.Complete){$complete++}
        $tokens=@($candidate.Tokens | Where-Object {$_.Word -match '[\p{L}\p{Nd}]'})
        $words+=$tokens.Count;$supported+=@($tokens | Where-Object Status -ceq 'Valid').Count
        if($capture.Alignment -cne 'ExactSourceSpansAndWordOnsets'){$alignmentFailures++}
        foreach($token in $tokens){
            $teacher=@($capture.AlignedWords | Where-Object {$_.Start -eq $token.SourceStart -and $_.Start+$_.Length -eq $token.SourceEnd})
            $expected=$null;$distance=$null;$agreement=$null
            if($capture.Alignment -ceq 'ExactSourceSpansAndWordOnsets' -and $teacher.Count -eq 1){
                $expected=[string]$teacher[0].Phones
                $actual=Get-EnglishPhoneComparison $token.Pron
                $distance=Get-EnglishSymbolDistance -Expected $expected -Actual $actual
                $agreement=$expected -ceq $actual
                $compared++;$symbols+=$expected.Length;$edits+=$distance
                if($agreement){$matched++}
            }
            $rows.Add([pscustomobject]@{Sentence=$sentence;Word=$token.Word;Start=$token.SourceStart;End=$token.SourceEnd;Status=$token.Status;PronunciationSource=$token.PronunciationSource;StudentPhones=$token.Pron;TeacherPhones=$expected;TeacherAgreement=$agreement;SymbolEdits=$distance;Capture=$capture.CapturePath})
        }
    }
    $directory=Join-Path $env:LOCALAPPDATA ('Build\PSPerception\english\audits\'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
        $detail=Join-Path $directory 'words.psd1'
    $b=[Text.StringBuilder]::new();[void]$b.AppendLine('@{v=1;r=@(')
    for($i=0;$i -lt $rows.Count;$i++){
        if($i){[void]$b.AppendLine(',')};$row=$rows[$i]
        $values=@(foreach($field in @('Sentence','Word','Start','End','Status','PronunciationSource','StudentPhones','TeacherPhones','TeacherAgreement','SymbolEdits','Capture')){Get-EnglishTypedLiteral $row.$field})
        [void]$b.Append('@('+($values -join ',')+')')
    }
    [void]$b.AppendLine(')}');[IO.File]::WriteAllText($detail,$b.ToString(),[Text.UTF8Encoding]::new($false))
    $lexicalReceipt=Import-Clixml -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($AssemblyPath)) 'build-receipt.clixml')
    $report=[ordered]@{Gate='PRONUNCIATION_AUDIT_RECORDED';CorpusSha256=(Get-FileHash -LiteralPath $Path).Hash;Sentences=$sentences.Count;CompleteSentences=$complete;InputWords=$words;SupportedWords=$supported;WordCoverage=if($words){$supported/$words}else{$null};ComparableTeacherWords=$compared;TeacherMatchedWords=$matched;TeacherWordAgreement=if($compared){$matched/$compared}else{$null};TeacherSymbols=$symbols;KokoroSymbolEditRate=if($symbols){$edits/$symbols}else{$null};AlignmentFailures=$alignmentFailures;LexiconOrigin=$lexicalReceipt.DataOrigin;Driver=$driver.Output;DriverSha256=(Get-FileHash -LiteralPath $driver.Output).Hash;StressAccuracy='Unmeasured: captured teacher phones do not establish lexical stress';IndependentAccuracy='Unmeasured: Zira agreement is teacher fidelity';AudioPreference='Unmeasured';Details=$detail}
    $destination=Join-Path $directory 'audit.psd1'
    Write-EnglishBuildReceipt $destination $report
    [pscustomobject]$report | Add-Member -NotePropertyName Receipt -NotePropertyValue $destination -PassThru
}

function Test-EnglishCoreDriver {
    [CmdletBinding()]
    param()
    $driver=Import-EnglishCoreDriver
    $fixtures=@('Play the record.','Please record it.','Push record.','The record records the record.','They present the present.','They permit the record.','They live.','The music is live.','They close the door.','They wind the clock.','They lead the cat.','They had read the record.','They read the record.','The door was closed by Alice.','The door was closed by noon.','I saw her duck.','I saw her shit.','The duck.','They duck.','the door was','The quuxblarg records the record.','The actor records the record.','The hour records the record.','The university records the record.','The one records the record.','')
    foreach($sentence in $fixtures){
        $legacy=Invoke-EnglishPhonemizer -Text $sentence -Context (New-EnglishContext)
        $native=Invoke-EnglishPhonemizer -Text $sentence
        Assert-EnglishContract 'canonical CoreLib path' ($native.Execution -ceq 'CoreLib lowered typed pronunciation driver')
        Assert-EnglishContract 'lowered phone and grammar equivalence' ($legacy.KokoroPhones -ceq $native.KokoroPhones -and $legacy.SupportedPhones -ceq $native.SupportedPhones -and $legacy.GrammarStatus -ceq $native.GrammarStatus -and $legacy.Complete -eq $native.Complete -and $legacy.Candidates.Count -eq $native.Candidates.Count -and ($legacy.SymbolIds -join ',') -ceq ($native.SymbolIds -join ','))
        $before=@($legacy.Tokens | ForEach-Object {$_.SourceStart.ToString()+':'+$_.SourceEnd+':'+$_.Status+':'+$_.Pron+':'+($_.Roles -join ',')}) -join '|'
        $after=@($native.Tokens | ForEach-Object {$_.SourceStart.ToString()+':'+$_.SourceEnd+':'+$_.Status+':'+$_.Pron+':'+($_.Roles -join ',')}) -join '|'
        Assert-EnglishContract 'lowered token extent, role and status equivalence' ($before -ceq $after)
    }
    $record=$driver.Run.Invoke('The record records the record.')
    foreach($case in @(@('Play the record.',0,'ɹˈɛkəɹd'),@('Please record it.',1,'ɹɪkˈɔɹd'),@('Push record.',0,'ɹˈɛkəɹd'))){
        $result=$driver.Run.Invoke($case[0]);$token=@($result.Tokens | Where-Object {$_.Word.ToLowerInvariant() -ceq 'record'})
        Assert-EnglishContract 'explicit imperative record role and pronunciation' ($result.Complete -and $token.Count -eq 1 -and $token[0].Roles.Length -eq 1 -and $token[0].Roles[0] -eq $case[1] -and $token[0].Pron -ceq $case[2])
        $legacy=Invoke-EnglishPhonemizer -Text $case[0] -Context (New-EnglishContext)
        Assert-EnglishContract 'imperative lowering equivalence' ($legacy.KokoroPhones -ceq $result.KokoroPhones -and $legacy.GrammarStatus -ceq $result.GrammarStatus)
    }
    Assert-EnglishContract 'independent fixed record fixture' ($record.KokoroPhones -ceq 'ðə ɹˈɛkəɹd ɹɪkˈɔɹdz ðə ɹˈɛkəɹd .')
    $unknown=$driver.Run.Invoke('The quuxblarg records the record.')
    Assert-EnglishContract 'standalone source coverage rejection' (-not $unknown.Complete -and $null -eq $unknown.KokoroPhones -and $unknown.OovSpans.Count -gt 0)
    $bounded=$false
    try{$null=$driver.Run.Invoke(('x'*8193))}catch{$bounded=$_.Exception.ToString().Contains('ArgumentOutOfRangeException')}
    Assert-EnglishContract 'standalone input bound' $bounded
    $directory=Join-Path ([IO.Path]::GetDirectoryName($driver.Output)) ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $externalCases=@('The record records the record.','The actor records the record.','They read the record.','The quuxblarg records the record.')
    for($i=0;$i -lt $externalCases.Count;$i++){
        $destination=Join-Path $directory ($i.ToString()+'.json')
        & $DotnetPath $driver.Output $externalCases[$i] $destination
        $status=$LASTEXITCODE
        $external=Import-PowerShellDataFile -LiteralPath $destination
        $expected=$driver.Run.Invoke($externalCases[$i])
        Assert-EnglishContract 'separate dotnet process without SMA' (-not $external.RuntimeSmaLoaded -and $external.Execution -ceq $expected.Execution)
        Assert-EnglishContract 'standalone exit code and phones' ((($status -eq 0 -and $external.Complete) -or ($status -eq 1 -and -not $external.Complete)) -and $external.KokoroPhones -ceq $expected.KokoroPhones -and ($external.SymbolIds -join ',') -ceq ($expected.SymbolIds -join ','))
    }
    $teacherChecks=0
    if(Test-Path -LiteralPath $CorrectionPath){
        $model=Import-EnglishZiraCorpus -Path $CorrectionPath
        foreach($capture in $model.Captures){
            if($capture.Alignment -cne 'ExactSourceSpansAndWordOnsets'){continue}
            $result=$driver.Run.Invoke($capture.Text)
            foreach($token in @($result.Tokens | Where-Object PronunciationSource -ceq 'ZiraCorrection')){
                $word=@($capture.AlignedWords | Where-Object {$_.Start -eq $token.SourceStart -and $_.Start+$_.Length -eq $token.SourceEnd})
                Assert-EnglishContract 'lowered corrections agree with recorded external teacher' ($word.Count -eq 1 -and (Get-EnglishPhoneComparison $token.Pron) -ceq $word[0].Phones)
                $teacherChecks++
            }
        }
        Assert-EnglishContract 'retained teacher corrections reached standalone execution' ($teacherChecks -gt 0)
    }
    $null=$driver.Batch.Invoke('The record records the record.',100)
    $runs=2000;$watch=[Diagnostics.Stopwatch]::StartNew()
    $count=$driver.Batch.Invoke('The record records the record.',$runs)
    $watch.Stop()
    Assert-EnglishContract 'native batch output count' ($count -eq $record.SymbolIds.Length*$runs)
    $report=[pscustomobject]@{Gate='CORELIB_STANDALONE_PHONEMIZER=PASS';Fixtures=$fixtures.Count;ExternalProcesses=$externalCases.Count;ExternalSmaLoaded=$false;TeacherCorrectionChecks=$teacherChecks;BatchRuns=$runs;MeanNativeSentenceUs=$watch.Elapsed.TotalMilliseconds*1000/$runs;BenchmarkBoundary='One managed batch call; includes scanning, lookup, roles, corrections, source spans, graph construction and token IDs; excludes build, process startup and audio';AssemblyReferences=@($driver.Assembly.GetReferencedAssemblies() | ForEach-Object Name);Driver=$driver.Output;BuildReceipt=$driver.Receipt}
    Write-EnglishBuildReceipt (Join-Path $directory 'verification.psd1') ([ordered]@{Gate=$report.Gate;Fixtures=$report.Fixtures;ExternalProcesses=$report.ExternalProcesses;ExternalSmaLoaded=$report.ExternalSmaLoaded;TeacherCorrectionChecks=$report.TeacherCorrectionChecks;BatchRuns=$report.BatchRuns;MeanNativeSentenceUs=$report.MeanNativeSentenceUs;AssemblyReferences=$report.AssemblyReferences;Driver=$report.Driver;BuildReceipt=$report.BuildReceipt})
    $report
}

function Assert-EnglishContract {
    param([string]$Name,[bool]$Condition)
    if(-not $Condition){throw ('English behavioral contract failed: '+$Name)}
}

function Test-EnglishPhonemizer {
    [CmdletBinding()]
    param([string]$ReferencePath=$AssemblyPath)
    $checks=[Collections.Generic.List[string]]::new()
    $reference=Import-EnglishReference $ReferencePath
    Assert-EnglishContract 'managed assembly identity' ($reference.Assembly.GetName().Name -ceq 'Dev.MansfieldPlumbing.English.Phonemizer')
    $references=@($reference.Assembly.GetReferencedAssemblies() | ForEach-Object Name)
    Assert-EnglishContract 'CoreLib only' ($references.Count -eq 1 -and $references[0] -ceq 'System.Private.CoreLib')
    Assert-EnglishContract 'no mutable data fields' (@($reference.Assembly.GetTypes() | ForEach-Object { $_.GetFields([Reflection.BindingFlags]'Public,NonPublic,Static,Instance') }).Count -eq 0)
    Assert-EnglishContract 'executable accessor' ($reference.Find.Invoke('record') -ge 0 -and $reference.Phones.Invoke($reference.Find.Invoke('record'),1) -ceq 'ɹɪkˈɔɹd')
    $checks.Add('Fresh process executable managed reference, immutable data, CoreLib only')
    $ctx=New-EnglishContext -ReferencePath $ReferencePath
    $states=[Collections.Generic.List[object]]::new()
    foreach($chunk in @('the ','door ','was ','closed')){
        Add-EnglishText $ctx $chunk;$r=Get-EnglishResult $ctx
        $states.Add([pscustomobject]@{Source=$ctx.Text;Status=$r.GrammarStatus;Pending=$r.Pending;Bindings=$r.Bindings.Count;Phones=$r.KokoroPhones})
    }
    Assert-EnglishContract 'determiner pending nominal head' ($states[0].Pending -contains 'NominalHead')
    Assert-EnglishContract 'native auxiliary deferred binding' ($states[2].Pending -contains 'Predicate' -and @($r.Bindings | Where-Object Command -ceq 'New-EnglishRequirement').Count -eq 2)
    Assert-EnglishContract 'closure retains passive and stative' ($r.Candidates.Count -eq 2 -and $r.Complete)
    Add-EnglishText $ctx ' by Alice.';$agent=Get-EnglishResult $ctx
    Assert-EnglishContract 'later agent evidence' ($agent.Candidates.Count -eq 1 -and $agent.Candidates[0].Clause.Agent.Head.Text -ceq 'Alice')
    $time=Invoke-EnglishPhonemizer -Text 'The door was closed by noon.' -ReferencePath $ReferencePath
    Assert-EnglishContract 'by time is not an agent' ($time.Candidates.Count -eq 2 -and @($time.Candidates | Where-Object {$null -ne $_.Clause.Agent}).Count -eq 0)
    $checks.Add('Cascading native calls, pending operands, later agent vs time binding')
    $record=Invoke-EnglishPhonemizer -Text 'The record records the record.' -ReferencePath $ReferencePath
    Assert-EnglishContract 'three distinct record occurrences' ($record.Tokens[1].Roles[0] -eq 0 -and $record.Tokens[2].Roles[0] -eq 1 -and $record.Tokens[4].Roles[0] -eq 0 -and $record.Tokens[1].Identity -ne $record.Tokens[4].Identity)
    Assert-EnglishContract 'record projection fixture' ($record.KokoroPhones -ceq 'ðə ɹˈɛkəɹd ɹɪkˈɔɹdz ðə ɹˈɛkəɹd .')
    $transfer=@(
        @('They present the present.','present',1,'pɹɪzˈɛnt'),
        @('They permit the record.','permit',1,'pəɹmˈɪt'),
        @('They live.','live',1,'lˈɪv'),
        @('The music is live.','live',2,'lˈIv'),
        @('They close the door.','close',1,'klˈOz'),
        @('They wind the clock.','wind',1,'wˈInd'),
        @('They lead the cat.','lead',1,'lˈid'),
        @('They had read the record.','read',3,'ɹˈɛd')
    )
    foreach($case in $transfer){
        $result=Invoke-EnglishPhonemizer -Text $case[0] -ReferencePath $ReferencePath
        $target=@($result.Tokens | Where-Object Word -ceq $case[1])[0]
        Assert-EnglishContract ('shared binding: '+$case[1]) ($result.Complete -and $target.Roles -contains $case[2] -and $target.Pron -ceq $case[3])
    }
    $tense=Invoke-EnglishPhonemizer -Text 'They read the record.' -ReferencePath $ReferencePath
    Assert-EnglishContract 'read tense ambiguity retained' (-not $tense.Complete -and $tense.Candidates.Count -eq 2 -and $null -eq $tense.KokoroPhones)
    $checks.Add('Role-sensitive projection shared across eight supported cross-word fixtures; unresolved read tense retained')
    $ambiguous=New-EnglishContext -ReferencePath $ReferencePath
    Add-EnglishText $ambiguous 'I saw her duck.';$a=Get-EnglishResult $ambiguous
    Assert-EnglishContract 'genuine ambiguity can finish phones' ($a.Candidates.Count -eq 2 -and $a.GrammarStatus -ceq 'Ambiguous' -and $a.Complete)
    $transferred=Invoke-EnglishPhonemizer -Text 'I saw her shit.' -ReferencePath $ReferencePath
    Assert-EnglishContract 'perception complement transfers to another nominal and verb' ($transferred.Candidates.Count -eq 2 -and $transferred.GrammarStatus -ceq 'Ambiguous' -and $transferred.Complete -and @($transferred.Candidates | Where-Object {$null -ne $_.Clause.Complement}).Count -eq 1)
    $entity=Invoke-EnglishPhonemizer -Text 'The duck.' -Context (New-EnglishContext -ReferencePath $ReferencePath)
    $target=@($ambiguous.Occurrences | Where-Object Text -ceq 'duck')[0].Identity
    $linked=Add-EnglishContextEvidence -Context $ambiguous -OccurrenceIdentity $target -Entity $entity.Candidates[0].Subject -EvidenceIdentity 'observed-nominal-link'
    Assert-EnglishContract 'linked nominal graph constrains reading' ($linked.Candidates.Count -eq 1 -and $null -eq $linked.Candidates[0].Clause.Complement)
    $restored=Remove-EnglishContextEvidence -Context $ambiguous -EvidenceIdentity 'observed-nominal-link'
    Assert-EnglishContract 'evidence withdrawal restores ambiguity' ($restored.Candidates.Count -eq 2 -and $restored.KokoroPhones -ceq $a.KokoroPhones)
    $event=Invoke-EnglishPhonemizer -Text 'They duck.' -Context (New-EnglishContext -ReferencePath $ReferencePath)
    $linked=Add-EnglishContextEvidence -Context $ambiguous -OccurrenceIdentity $target -Event $event.Candidates[0].Clause -EvidenceIdentity 'observed-event-link'
    Assert-EnglishContract 'linked event graph constrains reading' ($linked.Candidates.Count -eq 1 -and $null -ne $linked.Candidates[0].Clause.Complement)
    $checks.Add('Prior/later explicitly linked typed graphs constrain ambiguity; removing evidence restores alternatives')
    foreach($sentence in @('The record records the record.','The door was closed by Alice.','I saw her duck.','They had read the record.')){
        $whole=Invoke-EnglishPhonemizer -Text $sentence -ReferencePath $ReferencePath
        $incremental=New-EnglishContext -ReferencePath $ReferencePath
        $words=$sentence.Split(' ')
        for($i=0;$i -lt $words.Length;$i++){Add-EnglishText $incremental ($words[$i]+$(if($i -lt $words.Length-1){' '}else{''}))}
        $stream=Get-EnglishResult $incremental
        Assert-EnglishContract 'streaming phone and graph agreement' ($stream.KokoroPhones -ceq $whole.KokoroPhones -and $stream.Candidates.Count -eq $whole.Candidates.Count -and ($stream.Tokens.SourceStart -join ',') -ceq ($whole.Tokens.SourceStart -join ','))
        foreach($token in $stream.Tokens){Assert-EnglishContract 'source extent identity' ($sentence.Substring($token.SourceStart,$token.SourceEnd-$token.SourceStart) -ceq $token.Word)}
    }
    $checks.Add('Four whole vs lexical-boundary streaming comparisons; exact source extents')
    $unknown=Invoke-EnglishPhonemizer -Text 'The quuxblarg records the record.' -ReferencePath $ReferencePath
    Assert-EnglishContract 'uncovered input cannot produce successful shortened output' (-not $unknown.Complete -and $null -eq $unknown.KokoroPhones -and $unknown.OovSpans.Count -gt 0)
    $invalidNominal=New-EnglishContext -ReferencePath $ReferencePath
    Add-EnglishText $invalidNominal 'live'
    $bindingRejected=$false
    try{$null=New-EnglishNominal -Head $invalidNominal.Occurrences[0]}catch [Management.Automation.ParameterBindingException]{$bindingRejected=$true}
    Assert-EnglishContract 'SMA validates lexical operand capabilities' $bindingRejected
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput('1 +',[ref]$tokens,[ref]$errors)
    Assert-EnglishContract 'parser incomplete syntax differs from deferred command' (@($errors | Where-Object IncompleteInput).Count -gt 0)
    $checks.Add('Native parameter validation rejection, explicit source coverage failure, parser/binder distinction')
    $samples=[Collections.Generic.List[double]]::new();$allocated=[Collections.Generic.List[long]]::new()
    for($i=0;$i -lt 10;$i++){$null=Invoke-EnglishPhonemizer -Text 'The record records the record.' -ReferencePath $ReferencePath}
    for($i=0;$i -lt 30;$i++){
        $bytes=[GC]::GetAllocatedBytesForCurrentThread();$sw=[Diagnostics.Stopwatch]::StartNew()
        $null=Invoke-EnglishPhonemizer -Text 'The record records the record.' -ReferencePath $ReferencePath
        $samples.Add($sw.Elapsed.TotalMilliseconds);$allocated.Add([GC]::GetAllocatedBytesForCurrentThread()-$bytes)
    }
    $sorted=@($samples | Sort-Object);$allocation=@($allocated | Sort-Object)
    $lookupRuns=10000
    $lookupWatch=[Diagnostics.Stopwatch]::StartNew()
    for($i=0;$i -lt $lookupRuns;$i++){
        $id=$reference.Find.Invoke('record')
        $null=$reference.Phones.Invoke($id,1)
    }
    $lookupWatch.Stop()
    $receipt=[pscustomobject]@{Gate='CanonicalEnglishSmaExecution';Passed=$checks.ToArray();StreamingStates=$states.ToArray();Runtime=[Runtime.InteropServices.RuntimeInformation]::FrameworkDescription;PowerShell=$PSVersionTable.PSVersion.ToString();AssemblySha256=(Get-FileHash -LiteralPath $ReferencePath).Hash;AssemblyBytes=(Get-Item -LiteralPath $ReferencePath).Length;LexicalIdentities=$reference.Count;WarmFixture='The record records the record.';WarmRuns=$samples.Count;P50Ms=$sorted[14];P95Ms=$sorted[28];P50AllocatedBytes=$allocation[14];IndependentAccuracy='Not established by authored behavior fixtures';AutomaticDiscourseCoreference='Unsupported; graph links must be explicit';Unsupported=@('general grammar','arbitrary mid-token streaming','broad productive morphology','currency/date verbalization','automatic semantic sense resolution')}
    $receipt | Add-Member -NotePropertyName WarmCompiledLookupMeanUs -NotePropertyValue ($lookupWatch.Elapsed.TotalMilliseconds*1000/$lookupRuns)
    $receipt | Add-Member -NotePropertyName CompiledLookupRuns -NotePropertyValue $lookupRuns
    $receipt | Add-Member -NotePropertyName CompiledLookupBoundary -NotePropertyValue 'PowerShell loop plus managed Find and Phones delegates for one repeated word; excludes grammar and provenance'
    $receipt | Export-Clixml -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($ReferencePath)) 'verify-receipt.clixml')
    $receipt
}

if($Build){Build-EnglishReference -OutputPath $AssemblyPath -Source $LexicalSource}
elseif($Import){return}
elseif($Zira){
    if($CorpusPath){
        Write-EnglishZiraCorpus -InputPath $CorpusPath
    }else{Get-EnglishZiraReference -Text $Text | Select-Object Voice,Alignment,AlignedWords,CapturePath}
}
elseif($LowerCorpus){Convert-EnglishZiraCorpus -Path $ObservationPath}
elseif($Distill){Invoke-EnglishZiraDistillation}
elseif($BuildDriver){Import-EnglishCoreDriver | Select-Object Output,Receipt,SourceSha256,Corrections}
elseif($VerifyDriver){Test-EnglishCoreDriver}
elseif($GenerateCorpus){New-EnglishZiraCorpus}
elseif($Parity){Test-EnglishZiraTokenParity}
elseif($Audit){
    if(-not $ValidationCorpusPath){throw 'Audit requires -ValidationCorpusPath pointing to a frozen UTF-8 sentence corpus.'}
    Test-EnglishPronunciationCorpus -Path $ValidationCorpusPath
}
elseif($Speak){Invoke-EnglishKokoroSpeech -Text $Text}
elseif($Verify){Test-EnglishPhonemizer -ReferencePath $AssemblyPath}
else{Invoke-EnglishPhonemizer -Text $Text -ReferencePath $AssemblyPath}
