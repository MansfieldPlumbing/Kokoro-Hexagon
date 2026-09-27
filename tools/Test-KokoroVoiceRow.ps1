#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string] $VoicePath)

$ErrorActionPreference = 'Stop'
$reader = Join-Path $PSScriptRoot '../src/models/Read-KokoroVoiceRow.ps1'
[float[]]$row = & $reader -VoicePath $VoicePath -PhonemeCount 1
if ($row.Length -ne 256) { throw 'Stock voice row length differs.' }
$different = $false
for ($i = 0; $i -lt $row.Length; $i++) {
    if ($row[$i] -ne 0) { $different = $true; break }
}
if (-not $different) { throw 'Stock voice row is unexpectedly all zero.' }
$rejected = $false
try { $null = & $reader -VoicePath $VoicePath -PhonemeCount 511 } catch { $rejected = $true }
if (-not $rejected) { throw 'Voice reader accepted a count beyond the table.' }
Write-Output 'PASS: pinned voice row selection and bounds'
