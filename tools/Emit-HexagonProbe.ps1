#requires -Version 7.4
# Compatibility entrypoint; emission parameters, kernels and implementation belong to the owning application.
[CmdletBinding()]
param()
dynamicparam {
    & (Join-Path $PSScriptRoot '../Invoke-HexagonDevelopment.ps1') -Command EmissionParameters
}
end {
    & (Join-Path $PSScriptRoot '../Invoke-HexagonDevelopment.ps1') -Command Emit -Parameters $PSBoundParameters
}
