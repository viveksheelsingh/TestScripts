#Requires -Version 7.2
<#
.SYNOPSIS
    Ignite_Final: deploy infrastructure, Service Group and memberships using ARM.
.DESCRIPTION
    Uses the SGMSGSplit templates, with existing waits and deployment retries.
    SG-scoped goal assignments, recovery plans and drills are NOT deployed here.
    Run New-ServiceGroupExtensions.ps1 separately after this script succeeds,
    using the same SubscriptionId, LabInstanceId and ResourceGroupName, plus
    ServiceGroupName if overridden. Ex4 usage plans/enrollments remain in ARM.
    The follow-on script configures RO/Drill readiness automatically after creation.
.PARAMETER TemplateBaseUri
    Defaults to this scenario's IgniteTemplates/Ignite_Final folder on GitHub.
.PARAMETER UseLocalFiles
    Use the JSON templates next to this script instead of GitHub.
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
    [string] $LabInstanceId = '@lab.LabInstance.Id',

    [ValidateNotNullOrEmpty()]
    [string] $ServiceGroupName = "CaldovaPayApp_Ex4_Task1_SG_$LabInstanceId",

    [ValidateNotNullOrEmpty()]
    [string] $HealthModelName = 'ahm-ex4-task1',

    [ValidateNotNullOrEmpty()]
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/IgniteTemplates/Ignite_Final/Ex4_Task1_withServiceGroupAndGoalAndAHMAndZonalROAndDrills_UserViewsAndRunsRO',

    [switch] $UseLocalFiles
)

# Service Group name, unique per lab instance (see -LabInstanceId above). Passed explicitly
# to BOTH step1 and step2 below so the two templates always agree on the name - they no
# longer rely on their independent JSON defaults happening to match.
$script:ServiceGroupName = $ServiceGroupName

$ErrorActionPreference = "Stop"
$scriptFolder = $PSScriptRoot

function Invoke-Deployment {
    param(
        [string]$DeploymentName,
        [string]$TemplateUriOrPath,
        [bool]$IsUri,
        [hashtable]$TemplateParameterObject
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

    if ($TemplateParameterObject) {
        $deployArgs["TemplateParameterObject"] = $TemplateParameterObject
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
    $step1Template = Join-Path $scriptFolder "SGMSGSplit_Ex4_Task1_CommonSGSetup.json"
    $step2Template = Join-Path $scriptFolder "SGMSGSplit_ZonalROAndDrillsUserViewsAndRunsRO_step2.json"
    $isUri = $false
} else {
    $step1Template = "$TemplateBaseUri/SGMSGSplit_Ex4_Task1_CommonSGSetup.json"
    $step2Template = "$TemplateBaseUri/SGMSGSplit_ZonalROAndDrillsUserViewsAndRunsRO_step2.json"
    $isUri = $true
}

# ---------------------------------------------------------------------------
# Wait 1 minute before the pre-step1 access-token refresh.
# ---------------------------------------------------------------------------
Write-Host "`n=== Waiting 1 minute before the pre-step1 token refresh ===" -ForegroundColor Cyan
Start-Sleep -Seconds 60

# ---------------------------------------------------------------------------
# Force an explicit access-token refresh before step1.
# Re-acquires a fresh access token for ARM before the very first deployment,
# so step1 does not run on a token that was issued/cached before
# Set-AzContext switched subscription context above.
# ---------------------------------------------------------------------------
Write-Host "`n=== Forcing an explicit access token refresh before step1 ===" -ForegroundColor Cyan
$step1TokenInfo = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
if (-not $step1TokenInfo.Token) {
    throw "Failed to acquire a fresh access token before step1."
}
Write-Host "New token acquired (expires on: $($step1TokenInfo.ExpiresOn))" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 1: Deploy the Service Group + infra + Public IP (NO Service-Group-member
# relationships here anymore - those moved to step2, see .DESCRIPTION above) +
# AHM (Health Model, authentication settings, discovery rule, Reader role assignment)
# ---------------------------------------------------------------------------
# Retry step1 up to 2 times (3 attempts total) if the deployment fails. Safe to
# retry: step1 deploys with Incremental mode and deterministic resource names
# (uniqueString(resourceGroup().id)), so resources that already succeeded are
# left untouched / no-op'd by ARM on the next attempt - only the resource(s)
# that actually failed (e.g. a transient VM capacity error) get retried.
$maxStep1Attempts = 3
$step1Result = $null
for ($step1Attempt = 1; $step1Attempt -le $maxStep1Attempts; $step1Attempt++) {
    try {
        $step1Name = "step1-$(Get-Date -Format yyyyMMddHHmmss)"
        $step1Result = Invoke-Deployment -DeploymentName $step1Name -TemplateUriOrPath $step1Template -IsUri $isUri -TemplateParameterObject @{ serviceGroupName = $script:ServiceGroupName; healthModelName = $HealthModelName }
        break
    } catch {
        if ($step1Attempt -ge $maxStep1Attempts) {
            Write-Host "Step1 failed after $step1Attempt attempt(s). No more retries left." -ForegroundColor Red
            throw
        }
        Write-Host "Step1 attempt $step1Attempt of $maxStep1Attempts failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Retrying step1 (attempt $($step1Attempt + 1) of $maxStep1Attempts) after a short delay ..." -ForegroundColor Yellow
        Start-Sleep -Seconds 180
    }
}

# serviceGroupName is passed explicitly to both step1 and step2 (see -LabInstanceId above),
# so the two templates always agree on the name regardless of their independent JSON
# defaults. The fixed Health Model name is also passed explicitly to both steps;
# pass the same name to the follow-on script if overriding it here.
$serviceGroupId = $step1Result.Outputs.serviceGroupId.Value
$healthModelId = $step1Result.Outputs.healthModelId.Value
Write-Host "Service Group created : $serviceGroupId" -ForegroundColor Green
Write-Host "Health Model created  : $healthModelId" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Wait for RBAC propagation before step2.
# Gives Azure time to propagate the Service Group's self-granted role
# assignments, and the Health Model's Reader role assignment, before step2
# relies on them (e.g. enrollment's linked-scope read check on
# Microsoft.Management/serviceGroups, and
# the 9 new Service-Group-member relationships that also now live in step2).
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
# Step 2: Deploy the 9 Service-Group-member relationships (moved here from
# step1 to avoid the RBAC race) + Usage Plan/Enrollment.
# Goals, Recovery Plan, Drill and readiness setup run separately afterwards.
# ---------------------------------------------------------------------------
$step2Params = @{
    serviceGroupName = $script:ServiceGroupName
    healthModelName  = $HealthModelName
    vnetId           = $step1Result.Outputs.vnetId.Value
    publicIpId       = $step1Result.Outputs.publicIpId.Value
    loadBalancerId   = $step1Result.Outputs.loadBalancerId.Value
    webVm1Id         = $step1Result.Outputs.webVm1Id.Value
    webVm2Id         = $step1Result.Outputs.webVm2Id.Value
    appVm1Id         = $step1Result.Outputs.appVm1Id.Value
    appVm2Id         = $step1Result.Outputs.appVm2Id.Value
    postgresId       = $step1Result.Outputs.postgresId.Value
    storageId        = $step1Result.Outputs.storageId.Value
}
# Retry step2 up to 2 times (3 attempts total) if deployment fails.
# Memberships and any usage plan/enrollment stay in Incremental mode.
# SG-scoped extensions are created by the separate follow-on script.
$maxStep2Attempts = 3
$step2Result = $null
for ($step2Attempt = 1; $step2Attempt -le $maxStep2Attempts; $step2Attempt++) {
    try {
        $step2Name = "step2-$(Get-Date -Format yyyyMMddHHmmss)"
        $step2Result = Invoke-Deployment -DeploymentName $step2Name -TemplateUriOrPath $step2Template -IsUri $isUri -TemplateParameterObject $step2Params
        break
    } catch {
        if ($step2Attempt -ge $maxStep2Attempts) {
            Write-Host "Step2 failed after $step2Attempt attempt(s). No more retries left." -ForegroundColor Red
            throw
        }
        Write-Host "Step2 attempt $step2Attempt of $maxStep2Attempts failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Retrying step2 (attempt $($step2Attempt + 1) of $maxStep2Attempts) after a short delay ..." -ForegroundColor Yellow
        Start-Sleep -Seconds 180
    }
}

Write-Host "`n=== ARM deployments complete ===" -ForegroundColor Cyan
Write-Host "Service Group : $serviceGroupId"
Write-Host "Health Model  : $healthModelId"
Write-Host "Usage Plan    : $($step2Result.Outputs.usagePlanId.Value)"
Write-Host "Enrollment    : $($step2Result.Outputs.enrollmentId.Value)"

Write-Host "Next: run New-ServiceGroupExtensions.ps1 separately with the same SubscriptionId, LabInstanceId and ResourceGroupName, plus ServiceGroupName if overridden." -ForegroundColor Yellow
