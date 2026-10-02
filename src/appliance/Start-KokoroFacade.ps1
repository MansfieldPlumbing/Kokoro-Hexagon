#requires -Version 7.4
# Device Profile.ps1 entry point staged by Build-KokoroFacadePackage.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$activity = Get-Variable -Name NativeActivityHandle -ValueOnly -ErrorAction Stop
if ([IntPtr]$activity -eq [IntPtr]::Zero) { throw 'NativeActivityHandle is unavailable.' }
$modules = [IO.Path]::Combine($PSScriptRoot, 'modules')
Import-Module ([IO.Path]::Combine($modules, 'Kokoro.Facade.psm1')) -Force
Import-Module ([IO.Path]::Combine($modules, 'Kokoro.SpeechSession.psm1')) -Force
$global:KokoroSpeechSession = New-KokoroSpeechSession
$initial = ConvertTo-KokoroFacadeState $global:KokoroSpeechSession
$global:KokoroFacade = Start-KokoroFacade -NativeActivity ([IntPtr]$activity) `
    -AndroidCanvasModulePath ([IO.Path]::Combine($modules, 'AndroidCanvas.psm1')) `
    -InitialState $initial -OnActivate {
        param($Current)
        $next = ConvertTo-KokoroFacadeState $global:KokoroSpeechSession
        & $global:KokoroFacade.SetState $next
    }
