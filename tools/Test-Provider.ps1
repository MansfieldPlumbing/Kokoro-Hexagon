#requires -Version 7.4
[CmdletBinding()]
param([string]$OutputDirectory = ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'Build', 'Kokoro-QNN', 'provider-gate'))))
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'src', 'appliance', 'provider', 'Gate', 'Kokoro.Provider.Gate.csproj'))
$profile = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'src', 'appliance', 'provider', 'Gate', 'gate-profile.ps1'))
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
Copy-Item -LiteralPath $profile -Destination ([IO.Path]::Combine($OutputDirectory, 'gate-profile.ps1')) -Force
$artifactsArgument = "-p:ArtifactsPath=$([IO.Path]::Combine($OutputDirectory, 'artifacts'))"
& dotnet run --project $project --configuration Release $artifactsArgument -- $OutputDirectory
if ($LASTEXITCODE) { throw "Provider gate exited $LASTEXITCODE." }
