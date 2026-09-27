#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroPhonemeToPcm.ps1'
$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    [IO.Path]::GetFullPath($stage), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Phoneme-to-PCM composition does not parse.' }

$weights = [pscustomobject]@{ TensorCount = 0 }
$arguments = @{
    TokenIds = [int[]]@(0, 43, 0)
    VoiceRow = [float[]]::new(256)
    Speed = 1.0
    AcousticWeights = $weights
    DecoderWeights = $weights
    GeneratorWeights = $weights
}
$rejected = $false
try { $null = & $stage @arguments } catch { $rejected = $true }
if (-not $rejected) { throw 'Incomplete model-weight map was admitted.' }
$arguments.TokenIds = [int[]]@(43, 0)
$rejected = $false
try { $null = & $stage @arguments } catch { $rejected = $true }
if (-not $rejected) { throw 'Missing leading boundary token was admitted.' }

Write-Output 'PASS: phoneme-to-PCM AST and admission guards; full forward unverified'
