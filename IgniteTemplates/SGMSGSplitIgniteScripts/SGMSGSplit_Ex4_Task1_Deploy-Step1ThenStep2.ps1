<#
.SYNOPSIS
    SGMSGSplit variant: Creates the target resource group if needed, deploys step1 (Service
    Group + Public IP + AHM health model/discovery-rule infra, WITHOUT any
    Service-Group-member relationships or spurious SG dependsOn), then deploys step2 (the 9
    Service-Group-member relationships + Goal Assignment + Usage Plan/Enrollment + Zonal
    Recovery Plan + AHM-monitored Drill).

.DESCRIPTION
    Structural fix for the "Microsoft.Management/serviceGroups/read" AuthorizationFailed race:
    the original template created the tenant-scoped Service Group and then, in the SAME
    deployment, every infra module (via a spurious dependsOn) and all 9
    Microsoft.Relationships/serviceGroupMember resources re-read it before ARM's self-granted
    RBAC on the newly created SG had propagated. This variant moves all 9 serviceGroupMember
    resources (and removes the spurious dependsOn from the 14 infra modules) into step2, which
    already runs after the existing 120s sleep + forced token refresh below - the same gap that
    step2's goal/usage-plan/recovery-plan/drill extension resources already rely on
    successfully today. The AHM resources in step1 (healthmodels, authenticationsettings,
    discoveryrules, Reader roleAssignment) are untouched - they discover Service Group
    membership asynchronously via a Resource Graph query, not via dependsOn, so they were never
    part of this race.

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

.PARAMETER LabInstanceId
    Per-user lab instance identifier, appended as a suffix to the Service Group name below.
    Defaults to '@lab.LabInstance.Id' - the Skillable lab placeholder that gets substituted
    with a value unique to each learner's lab instance at runtime. Service Groups
    (Microsoft.Management/serviceGroups) are a TENANT-scoped resource, not subscription-scoped,
    so a fixed name would collide across concurrent learners sharing the same AAD tenant even
    though each learner gets their own subscription. Suffixing with -LabInstanceId makes the
    name unique per learner.

.PARAMETER TemplateBaseUri
    Base raw-GitHub URI the two templates are fetched from. Defaults to the
    SGMSGSplitIgniteScripts folder pushed to https://github.com/viveksheelsingh/TestScripts
    (the SGM-split variant of the templates - distinct from the original IgniteTemplates
    folder, which is left untouched).

.PARAMETER UseLocalFiles
    Switch. If set, uses the local SGMSGSplit_*.json template files in this script's folder
    instead of fetching them from GitHub via -TemplateUri.
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
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/IgniteTemplates/SGMSGSplitIgniteScripts',

    [switch] $UseLocalFiles
)

# Service Group name, unique per lab instance (see -LabInstanceId above). Passed explicitly
# to BOTH step1 and step2 below so the two templates always agree on the name - they no
# longer rely on their independent JSON defaults happening to match.
$script:ServiceGroupName = "CaldovaPayApp_Ex4_Task1_SG_$LabInstanceId"

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
$step1Name = "step1-$(Get-Date -Format yyyyMMddHHmmss)"
$step1Result = Invoke-Deployment -DeploymentName $step1Name -TemplateUriOrPath $step1Template -IsUri $isUri -TemplateParameterObject @{ serviceGroupName = $script:ServiceGroupName }

# serviceGroupName is passed explicitly to both step1 and step2 (see -LabInstanceId above),
# so the two templates always agree on the name regardless of their independent JSON
# defaults. Same applies to the Health Model name ("ahm-{uniqueString(resourceGroup().id)}"),
# reused by step2 to wire the Drill's healthModelMonitoringProperties.
$serviceGroupId = $step1Result.Outputs.serviceGroupId.Value
$healthModelId = $step1Result.Outputs.healthModelId.Value
Write-Host "Service Group created : $serviceGroupId" -ForegroundColor Green
Write-Host "Health Model created  : $healthModelId" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Wait for RBAC propagation before step2.
# Gives Azure time to propagate the Service Group's self-granted role
# assignments, and the Health Model's Reader role assignment, before step2
# relies on them (e.g. enrollment's linked-scope read check on
# Microsoft.Management/serviceGroups, the Drill's healthModelId reference, and
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
# step1 to avoid the RBAC race) + Goal Assignment + Usage Plan/Enrollment +
# Zonal Recovery Plan + AHM-monitored Drill
# ---------------------------------------------------------------------------
$step2Params = @{
    serviceGroupName = $script:ServiceGroupName
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
$step2Name = "step2-$(Get-Date -Format yyyyMMddHHmmss)"
$step2Result = Invoke-Deployment -DeploymentName $step2Name -TemplateUriOrPath $step2Template -IsUri $isUri -TemplateParameterObject $step2Params

Write-Host "`n=== All deployments complete ===" -ForegroundColor Cyan
Write-Host "Service Group          : $serviceGroupId"
Write-Host "Health Model           : $healthModelId"
Write-Host "Goal Assignment ID     : $($step2Result.Outputs.goalAssignmentId.Value)"
Write-Host "Usage Plan ID          : $($step2Result.Outputs.usagePlanId.Value)"
Write-Host "Enrollment ID          : $($step2Result.Outputs.enrollmentId.Value)"
Write-Host "Zonal Recovery Plan ID : $($step2Result.Outputs.recoveryPlanId.Value)"
Write-Host "Drill ID               : $($step2Result.Outputs.drillId.Value)"
Write-Host "Service Group membership for vnet/publicIp/lb/webVm1/webVm2/appVm1/appVm2/postgres/storage created in step2." -ForegroundColor Green
