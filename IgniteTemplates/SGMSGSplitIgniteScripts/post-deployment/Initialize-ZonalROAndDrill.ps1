#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory)][string]$ServiceGroupId,
    [string]$RecoveryPlanId,
    [string]$DrillId,
    [string]$RunbookId,
    [string]$AutomationResourceGroupId,
    [string]$AutomationLocation,
    [Nullable[int]]$FaultDurationInMinutes,
    [string]$StatePath,
    [string]$RhubArmEndpoint='https://eastus2euap.management.azure.com',
    [ValidateRange(2,120)][int]$TimeoutMinutes=45
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PostDeployment.ps1')
$context = New-PostDeploymentContext -Mode Zonal -ServiceGroupId $ServiceGroupId -RecoveryPlanId $RecoveryPlanId `
    -DrillId $DrillId -RunbookId $RunbookId -AutomationResourceGroupId $AutomationResourceGroupId `
    -AutomationLocation $AutomationLocation -FaultDurationInMinutes $FaultDurationInMinutes `
    -StatePath $StatePath -RhubArmEndpoint $RhubArmEndpoint -TimeoutMinutes $TimeoutMinutes
Show-PostDeploymentPlan $context
if (!$PSCmdlet.ShouldProcess($context.Drill.id, 'Configure existing Zonal RO and Drill to Ready, using native faults where available and NoOp fallback; do not execute')) { return }
Invoke-PostDeploymentWorkflow $context
