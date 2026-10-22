<#
.SYNOPSIS
    Creates the target resource group if needed, deploys step1 (Service Group + Public IP +
    infra), forces an explicit access-token refresh, then deploys step2 (an intentional no-op
    placeholder template - automation's job ends at step1; the user creates the zonal and
    regional resilience goals manually afterwards, e.g. via the portal).

.DESCRIPTION
    Investigates whether forcing a fresh AAD access token between step1 and step2 clears the
    "Microsoft.Management/serviceGroups/read" / stale-credential authorization failures seen
    when step2 is deployed immediately after step1 creates the Service Group.

    Uses the Az PowerShell module (Set-AzContext / New-AzResourceGroupDeployment / Get-AzAccessToken)
    to match the tooling already used by the other LAB 721 Skillable scripts (e.g. "Infect").

.PARAMETER ResourceGroupName
    Resource group both templates deploy into. Created automatically if it doesn't already
    exist. Defaults to "CaldovaPayApp_Ex3_Task3".

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
    Base raw-GitHub URI the two templates are fetched from. Defaults to the IgniteTemplates
    folder pushed to https://github.com/viveksheelsingh/TestScripts.

.PARAMETER UseLocalFiles
    Switch. If set, uses the local template files in this script's folder instead of fetching
    them from GitHub via -TemplateUri.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex3_Task3',

    [ValidateNotNullOrEmpty()]
    [string] $Location = 'southcentralus',

    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',

    [ValidateNotNullOrEmpty()]
    [string] $LabInstanceId = '@lab.LabInstance.Id',

    [ValidateNotNullOrEmpty()]
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/IgniteTemplates',

    [switch] $UseLocalFiles
)

# Service Group name, unique per lab instance (see -LabInstanceId above). Passed explicitly
# to BOTH step1 and step2 below so the two templates always agree on the name - they no
# longer rely on their independent JSON defaults happening to match.
$script:ServiceGroupName = "CaldovaPayApp_Ex3_Task3_SG_$LabInstanceId"

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
    $step1Template = Join-Path $scriptFolder "Ex3_Task3_CommonSGSetup.json"
    $step2Template = Join-Path $scriptFolder "NoOpStep2_UserCreatesGoalsManually.json"
    $isUri = $false
} else {
    $step1Template = "$TemplateBaseUri/Ex3_Task3_CommonSGSetup.json"
    $step2Template = "$TemplateBaseUri/NoOpStep2_UserCreatesGoalsManually.json"
    $isUri = $true
}

# ---------------------------------------------------------------------------
# Wait 5 minutes before the pre-step1 access-token refresh.
# ---------------------------------------------------------------------------
Write-Host "`n=== Waiting 5 minutes before the pre-step1 token refresh ===" -ForegroundColor Cyan
Start-Sleep -Seconds 300

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
# Step 1: Deploy the Service Group + infra + Public IP + membership
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
        $step1Result = Invoke-Deployment -DeploymentName $step1Name -TemplateUriOrPath $step1Template -IsUri $isUri -TemplateParameterObject @{ serviceGroupName = $script:ServiceGroupName }
        break
    } catch {
        if ($step1Attempt -ge $maxStep1Attempts) {
            Write-Host "Step1 failed after $step1Attempt attempt(s). No more retries left." -ForegroundColor Red
            throw
        }
        Write-Host "Step1 attempt $step1Attempt of $maxStep1Attempts failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Retrying step1 (attempt $($step1Attempt + 1) of $maxStep1Attempts) after a short delay ..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60
    }
}

# serviceGroupName is passed explicitly to both step1 and step2 (see -LabInstanceId above),
# so the two templates always agree on the name regardless of their independent JSON
# defaults - just read step1's serviceGroupId back for display.
$serviceGroupId = $step1Result.Outputs.serviceGroupId.Value
Write-Host "Service Group created: $serviceGroupId" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Wait for RBAC propagation before step2.
# Gives Azure time to propagate the Service Group's self-granted role
# assignments before step2 relies on them.
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
# Step 2: Deploy the intentional no-op placeholder template.
# Automation's scope ends here - the user creates the zonal and regional
# resilience goals manually afterwards (e.g. via the portal), against the
# Service Group created above. There is nothing further for ARM to deploy.
# ---------------------------------------------------------------------------
# Retry step2 up to 2 times (3 attempts total) if the deployment fails. Safe to
# retry for the same reasons as step1: Incremental mode + deterministic naming
# mean an already-applied step2 is a no-op on re-run, and only the failed part
# (if any) is retried.
$maxStep2Attempts = 3
$step2Result = $null
for ($step2Attempt = 1; $step2Attempt -le $maxStep2Attempts; $step2Attempt++) {
    try {
        $step2Name = "step2-$(Get-Date -Format yyyyMMddHHmmss)"
        $step2Result = Invoke-Deployment -DeploymentName $step2Name -TemplateUriOrPath $step2Template -IsUri $isUri -TemplateParameterObject @{ serviceGroupName = $script:ServiceGroupName }
        break
    } catch {
        if ($step2Attempt -ge $maxStep2Attempts) {
            Write-Host "Step2 failed after $step2Attempt attempt(s). No more retries left." -ForegroundColor Red
            throw
        }
        Write-Host "Step2 attempt $step2Attempt of $maxStep2Attempts failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Retrying step2 (attempt $($step2Attempt + 1) of $maxStep2Attempts) after a short delay ..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60
    }
}

Write-Host "`n=== All deployments complete ===" -ForegroundColor Cyan
Write-Host "Service Group : $serviceGroupId"
Write-Host "Step2 deployed no resources (intentional no-op)." -ForegroundColor Yellow
Write-Host "Next: create the zonal and regional resilience goals manually (e.g. via the portal) against the Service Group above." -ForegroundColor Yellow
