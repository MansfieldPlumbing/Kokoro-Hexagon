#requires -Version 7.7
[CmdletBinding()]
param(
    [string] $BankPath = (Join-Path $PSScriptRoot '../data/source-bank'),
    [string] $StateDirectory = (Join-Path $PSScriptRoot '../build'),
    [int] $WaitForScanPid = 0
)

$ErrorActionPreference = 'Stop'
$state = [IO.Directory]::CreateDirectory($StateDirectory).FullName
$lease = [IO.File]::Open((Join-Path $state 'student-field-loop.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    if ($WaitForScanPid) {
        $existing = Get-Process -Id $WaitForScanPid -ErrorAction SilentlyContinue
        if ($existing) { $existing.WaitForExit(); $existing.Dispose() }
    }
    while ($true) {
        Write-Information ("{0:u} Starting retained field pass." -f [datetime]::UtcNow) -InformationAction Continue
        try {
            $scanArgs = @{ BankPath=$BankPath; CheckpointDirectory=(Join-Path $state 'student-retained-checkpoints') }
            $field = & "$PSScriptRoot/Invoke-StudentRetainedField.ps1" @scanArgs
            Write-Information ("{0:u} Covered {1:N0} bytes; reused {2} file checks." -f
                [datetime]::UtcNow,$field.BytesRead,$field.FilesResumed) -InformationAction Continue
            $field = $null
            $huntArgs = @{ BankPath=$BankPath; CheckpointDirectory=(Join-Path $state 'student-recursive-checkpoints') }
            $report = & "$PSScriptRoot/Invoke-StudentRecursiveExperiment.ps1" @huntArgs
            Write-Information ("{0:u} Investigation pass complete; {1} findings checkpointed." -f
                [datetime]::UtcNow,$report.CompletedJudgments) -InformationAction Continue
            $report = $null
        } catch {
            Write-Warning ("{0:u} Pass interrupted: {1}" -f [datetime]::UtcNow,$_.Exception.Message)
        }
        Start-Sleep -Seconds 60
    }
} finally { $lease.Dispose() }
