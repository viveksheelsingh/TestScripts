#Requires -Version 7.2
<#
.SYNOPSIS
    Standalone readiness repair/retry for an existing Ex4 recovery plan and drill.
.DESCRIPTION
    Downloads the existing, unchanged readiness implementation and Common.psm1.
    Normal setup is already integrated into New-ServiceGroupExtensions.ps1;
    this script is only needed to run readiness configuration independently.
    Requires Azure CLI signed in to the workload tenant/subscription, as before.
    Configures the existing recovery plan and drill; never starts a drill.
.EXAMPLE
    .\Initialize-ServiceGroupReadiness.ps1 -ServiceGroupId '<sg-id>' -RecoveryPlanId '<ro-id>' -DrillId '<drill-id>'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ServiceGroupId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RecoveryPlanId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DrillId,
    [ValidateNotNullOrEmpty()]
    [string]$PostDeploymentBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/IgniteTemplates/SGMSGSplitIgniteScripts'
)
$ErrorActionPreference = 'Stop'
$null = Get-Command az -ErrorAction Stop
$step3Params = @{
    ServiceGroupId = $ServiceGroupId
    RecoveryPlanId = $RecoveryPlanId
    DrillId = $DrillId
    RhubArmEndpoint = 'https://management.azure.com'
}
$step3Folder = Join-Path ([IO.Path]::GetTempPath()) ("Ex4-ZonalPostDeployment-" + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $step3Folder 'post-deployment')
    foreach ($relativePath in @('Common.psm1', 'post-deployment\Initialize-ZonalROAndDrill.ps1',
            'post-deployment\PostDeployment.ps1', 'post-deployment\NoOp.ps1')) {
        $sourceUri = $PostDeploymentBaseUri.TrimEnd('/') + '/' + $relativePath.Replace('\', '/')
        Write-Host "Downloading readiness dependency: $sourceUri" -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $sourceUri -OutFile (Join-Path $step3Folder $relativePath) -ErrorAction Stop
    }
    & (Join-Path $step3Folder 'post-deployment\Initialize-ZonalROAndDrill.ps1') @step3Params
} finally {
    if (Test-Path -LiteralPath $step3Folder) {
        Remove-Item -LiteralPath $step3Folder -Recurse -Force
    }
}
