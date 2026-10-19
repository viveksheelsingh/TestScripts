<#
.SYNOPSIS
    Creates the target resource group if needed, deploys step1 (Service Group + Public IP +
    AHM health model/discovery-rule infra), forces an explicit access-token refresh, then
    deploys step2 (Goal Assignment + Usage Plan/Enrollment + Zonal Recovery Plan + AHM-monitored
    Drill).

.DESCRIPTION
    Investigates whether forcing a fresh AAD access token between step1 and step2 clears the
    "Microsoft.Management/serviceGroups/read" / stale-credential authorization failures seen
    when step2 is deployed immediately after step1 creates the Service Group.

    Uses the Az PowerShell module (Set-AzContext / New-AzResourceGroupDeployment / Get-AzAccessToken)
    to match the tooling already used by the other LAB 721 Skillable scripts (e.g. "Infect").

.PARAMETER ResourceGroupName
    Resource group both templates deploy into. Created automatically if it doesn't already
    exist. Defaults to "CaldovaPayApp_Ex4_Task1".

.PARAMETER Location
    Azure region used to create -ResourceGroupName if it doesn't already exist. Defaults to
    "southcentralus".

.PARAMETER SubscriptionId
    Subscription to target. Defaults to '@lab.CloudSubscription.Id' - the Skillable lab
    placeholder that gets substituted with the lab instance's assigned subscription GUID
    at runtime (same pattern as the "Infect" script in LAB 721).

.PARAMETER TemplateBaseUri
    Base raw-GitHub URI the two templates are fetched from. Defaults to the IgniteTemplates
    folder pushed to https://github.com/viveksheelsingh/TestScripts.

.PARAMETER UseLocalFiles
    Switch. If set, uses the local template files in this script's folder instead of fetching
    them from GitHub via -TemplateUri.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex4_Task1',

    [ValidateNotNullOrEmpty()]
    [string] $Location = 'southcentralus',

    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',

    [ValidateNotNullOrEmpty()]
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/IgniteTemplates',

    [switch] $UseLocalFiles
)

$ErrorActionPreference = "Stop"
$scriptFolder = $PSScriptRoot

function Invoke-Deployment {
    param(
        [string]$DeploymentName,
        [string]$TemplateUriOrPath,
        [bool]$IsUri
    )

    $deployArgs = @{
        ResourceGroupName = $ResourceGroupName
        Name              = $DeploymentName
        ErrorAction       = 'Stop'
    }

    if ($IsUri) {
        $deployArgs["TemplateUri"] = $TemplateUriOrPath
    } else {
        $deployArgs["TemplateFile"] = $TemplateUriOrPath
    }

    Write-Host "`n=== Deploying '$DeploymentName' ===" -ForegroundColor Cyan
    Write-Host "New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $DeploymentName $(if ($IsUri) {"-TemplateUri $TemplateUriOrPath"} else {"-TemplateFile $TemplateUriOrPath"})" -ForegroundColor DarkGray

    try {
        $result = New-AzResourceGroupDeployment @deployArgs
    } catch {
        Write-Host "Deployment '$DeploymentName' FAILED:" -ForegroundColor Red
        Write-Host $_.Exception.Message
        throw
    }

    Write-Host "Deployment '$DeploymentName' succeeded." -ForegroundColor Green
    return $result
}

Write-Host "Setting subscription context to $SubscriptionId ..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# ---------------------------------------------------------------------------
# Ensure the target resource group exists before deploying into it.
# ---------------------------------------------------------------------------
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "`n=== Creating resource group '$ResourceGroupName' in '$Location' ===" -ForegroundColor Cyan
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
    Write-Host "Resource group '$ResourceGroupName' created." -ForegroundColor Green
} else {
    Write-Host "Resource group '$ResourceGroupName' already exists (location: $($rg.Location))." -ForegroundColor Yellow
}

# Resolve template locations (local file vs raw GitHub URI)
if ($UseLocalFiles) {
    $step1Template = Join-Path $scriptFolder "Ex4_Task1_CommonSGSetup.json"
    $step2Template = Join-Path $scriptFolder "ZonalROAndDrillsUserViewsAndRunsRO_step2.json"
    $isUri = $false
} else {
    $step1Template = "$TemplateBaseUri/Ex4_Task1_CommonSGSetup.json"
    $step2Template = "$TemplateBaseUri/ZonalROAndDrillsUserViewsAndRunsRO_step2.json"
    $isUri = $true
}

# ---------------------------------------------------------------------------
# Step 1: Deploy the Service Group + infra + Public IP + membership + AHM
# (Health Model, authentication settings, discovery rule, Reader role assignment)
# ---------------------------------------------------------------------------
$step1Name = "step1-$(Get-Date -Format yyyyMMddHHmmss)"
$step1Result = Invoke-Deployment -DeploymentName $step1Name -TemplateUriOrPath $step1Template -IsUri $isUri

# Both templates derive the same Service Group name from the same default formula
# ("CaldovaPayApp_Ex4_Task1_SG"), so no explicit parameter needs to be
# passed to step2 - just read step1's serviceGroupId back for display. Same applies to
# the Health Model name ("ahm-{uniqueString(resourceGroup().id)}"), reused by step2 to
# wire the Drill's healthModelMonitoringProperties.
$serviceGroupId = $step1Result.Outputs.serviceGroupId.Value
$healthModelId = $step1Result.Outputs.healthModelId.Value
Write-Host "Service Group created : $serviceGroupId" -ForegroundColor Green
Write-Host "Health Model created  : $healthModelId" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Wait for RBAC propagation before step2.
# Gives Azure time to propagate the Service Group's self-granted role
# assignments, and the Health Model's Reader role assignment, before step2
# relies on them (e.g. enrollment's linked-scope read check on
# Microsoft.Management/serviceGroups, and the Drill's healthModelId reference).
# ---------------------------------------------------------------------------
$delaySeconds = 120
Write-Host "`n=== Waiting $delaySeconds seconds for RBAC propagation before step2 ===" -ForegroundColor Cyan
Start-Sleep -Seconds $delaySeconds

# ---------------------------------------------------------------------------
# Force an explicit access-token refresh before step2.
# This re-acquires a fresh access token for ARM, so step2 does not run on a
# token that was issued/cached before the Service Group (and its self-granted
# RBAC) existed.
# ---------------------------------------------------------------------------
Write-Host "`n=== Forcing an explicit access token refresh ===" -ForegroundColor Cyan
$tokenInfo = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
if (-not $tokenInfo.Token) {
    throw "Failed to acquire a fresh access token before step2."
}
Write-Host "New token acquired (expires on: $($tokenInfo.ExpiresOn))" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 2: Deploy Goal Assignment + Usage Plan/Enrollment + Zonal Recovery Plan
# + AHM-monitored Drill
# ---------------------------------------------------------------------------
$step2Name = "step2-$(Get-Date -Format yyyyMMddHHmmss)"
$step2Result = Invoke-Deployment -DeploymentName $step2Name -TemplateUriOrPath $step2Template -IsUri $isUri

Write-Host "`n=== All deployments complete ===" -ForegroundColor Cyan
Write-Host "Service Group          : $serviceGroupId"
Write-Host "Health Model           : $healthModelId"
Write-Host "Goal Assignment ID     : $($step2Result.Outputs.goalAssignmentId.Value)"
Write-Host "Usage Plan ID          : $($step2Result.Outputs.usagePlanId.Value)"
Write-Host "Enrollment ID          : $($step2Result.Outputs.enrollmentId.Value)"
Write-Host "Zonal Recovery Plan ID : $($step2Result.Outputs.recoveryPlanId.Value)"
Write-Host "Drill ID               : $($step2Result.Outputs.drillId.Value)"
