<#
.SYNOPSIS
    Creates the target resource group if needed, then deploys the standalone infra template
    (VNet, Load Balancer, Public IP, VMs, Postgres, Storage) with no Service Group - the user
    is expected to discover the resources afterwards and create a Service Group manually via
    the portal/agent.

.DESCRIPTION
    Single-template scenario (no step1/step2 split, no pre-existing Service Group). Uses the
    Az PowerShell module (Set-AzContext / New-AzResourceGroupDeployment) to match the tooling
    already used by the other LAB 721 Skillable scripts (e.g. "Infect").

.PARAMETER ResourceGroupName
    Resource group the template deploys into. Created automatically if it doesn't already
    exist. Defaults to "CaldovaPayApp_Ex3_Task1".

.PARAMETER Location
    Azure region used to create -ResourceGroupName if it doesn't already exist, and passed
    through as the template's own 'location' parameter. Defaults to "southcentralus".

.PARAMETER SubscriptionId
    Subscription to target. Defaults to '@lab.CloudSubscription.Id' - the Skillable lab
    placeholder that gets substituted with the lab instance's assigned subscription GUID
    at runtime (same pattern as the "Infect" script in LAB 721).

.PARAMETER TemplateBaseUri
    Base raw-GitHub URI the template is fetched from. Defaults to the IgniteTemplates folder
    pushed to https://github.com/viveksheelsingh/TestScripts.

.PARAMETER UseLocalFiles
    Switch. If set, uses the local template file in this script's folder instead of fetching
    it from GitHub via -TemplateUri.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex3_Task1',

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
        location          = $Location
        ErrorAction       = 'Stop'
    }

    if ($IsUri) {
        $deployArgs["TemplateUri"] = $TemplateUriOrPath
    } else {
        $deployArgs["TemplateFile"] = $TemplateUriOrPath
    }

    Write-Host "`n=== Deploying '$DeploymentName' ===" -ForegroundColor Cyan
    Write-Host "New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $DeploymentName -location $Location $(if ($IsUri) {"-TemplateUri $TemplateUriOrPath"} else {"-TemplateFile $TemplateUriOrPath"})" -ForegroundColor DarkGray

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

# Resolve template location (local file vs raw GitHub URI)
if ($UseLocalFiles) {
    $template = Join-Path $scriptFolder "DiscoverAndCreateSG.json"
    $isUri = $false
} else {
    $template = "$TemplateBaseUri/DiscoverAndCreateSG.json"
    $isUri = $true
}

# ---------------------------------------------------------------------------
# Deploy the standalone infra (no Service Group yet - that's the point of
# this scenario: the user discovers these resources and creates a Service
# Group around them afterwards, via the portal or the agent).
# ---------------------------------------------------------------------------
$deploymentName = "discover-$(Get-Date -Format yyyyMMddHHmmss)"
$result = Invoke-Deployment -DeploymentName $deploymentName -TemplateUriOrPath $template -IsUri $isUri

Write-Host "`n=== Deployment complete ===" -ForegroundColor Cyan
Write-Host "VNet           : $($result.Outputs.vnetId.Value)"
Write-Host "Public IP      : $($result.Outputs.publicIpId.Value)"
Write-Host "Load Balancer  : $($result.Outputs.loadBalancerId.Value)"
Write-Host "Web VM 1       : $($result.Outputs.webVm1Id.Value)"
Write-Host "Web VM 2       : $($result.Outputs.webVm2Id.Value)"
Write-Host "App VM 1       : $($result.Outputs.appVm1Id.Value)"
Write-Host "App VM 2       : $($result.Outputs.appVm2Id.Value)"
Write-Host "Postgres       : $($result.Outputs.postgresId.Value)"
Write-Host "Storage        : $($result.Outputs.storageId.Value)"
Write-Host "`nNo Service Group was created by this template. Discover these resources and" -ForegroundColor Yellow
Write-Host "create a Service Group around them manually (portal or agent) to continue the scenario." -ForegroundColor Yellow
