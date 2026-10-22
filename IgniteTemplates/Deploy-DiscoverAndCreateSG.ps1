<#
.SYNOPSIS
    Combines "..\Ex3_Task1_UserDiscoverAndCreateSG" and "..\Ex3_Task1_DiscoveryAgent" into one
    script: deploys a trimmed-down infra (Load Balancer + Public IP only - no VNet, VMs,
    Postgres, or Storage, and no Service Group) into the target resource group, then creates
    the appDiscoveryAgents resource (in its own, separate resource group) and grants it
    Reader on the target resource group - in that order, in a single run.

.DESCRIPTION
    Step 1 (resources): Creates -ResourceGroupName if needed and deploys
    "DiscoverAndCreateSG_LBAndIPOnly.json" into it - a separate, trimmed-down template
    (this folder also keeps the original, untouched "DiscoverAndCreateSG.json" from
    "..\Ex3_Task1_UserDiscoverAndCreateSG\Deploy-DiscoverAndCreateSG.ps1" for reference) that
    retains only the Public IP and Load Balancer modules (VNet, NICs, VMs, Postgres flexible
    server, private DNS zone, and Storage account were removed). No Service Group is created
    here - the user is expected to discover the resources afterwards and create one manually
    via the portal/agent.

    Step 2 (discovery agent): Creates a Microsoft.ResourceIntelligence/appDiscoveryAgents
    resource (system-assigned identity by default) via a direct ARM REST PUT
    (Invoke-AzRestMethod - this resource type has no Az PowerShell cmdlet), in its own
    dedicated -AgentResourceGroupName so the agent isn't itself a resource the discovery run
    would surface when analyzing -ResourceGroupName. Then grants that identity Reader on
    -ResourceGroupName so it can query Azure Resource Graph over the resources deployed in
    step 1 (same logic as "..\Ex3_Task1_DiscoveryAgent\Deploy-CreateDiscoveryAgent.ps1",
    which in turn follows "..\DiscoveryAgentPUT\00-create-agent.ps1" / "_shared.ps1").

    Role assignment uses a direct ARM REST call (Invoke-AzRestMethod), not
    New-AzRoleAssignment / Get-AzRoleAssignment, because those Az PowerShell cmdlets resolve
    the principal through Microsoft Graph first, which requires an interactive/WAM-capable
    login not available in a Skillable lab (or any non-interactive runner). Uses only Az
    PowerShell cmdlets + ARM REST - no az CLI, no Graph.

.PARAMETER ResourceGroupName
    Resource group the infra template deploys into, and the scope the discovery agent is
    granted Reader on. Created automatically if it doesn't already exist. Defaults to
    "CaldovaPayApp_Ex3_Task1".

.PARAMETER Location
    Azure region used to create -ResourceGroupName if it doesn't already exist, and passed
    through as the infra template's own 'location' parameter. Defaults to "southcentralus".

.PARAMETER AgentResourceGroupName
    Resource group the appDiscoveryAgents resource itself is created in. Created
    automatically if it doesn't already exist. Defaults to
    "CaldovaPayApp_Ex3_Task1_DiscoveryAgent" - deliberately separate from -ResourceGroupName.

.PARAMETER AgentResourceGroupLocation
    Azure region used to create -AgentResourceGroupName if it doesn't already exist. This is
    the resource group's own location, not the agent resource's 'location' property (which is
    fixed to 'global' - see -AgentLocation). Defaults to "southcentralus".

.PARAMETER AgentName
    Name of the appDiscoveryAgents resource. Defaults to "app-discovery-ex3task1", following
    the "app-discovery-<alias>" convention from "_shared.ps1".

.PARAMETER AgentLocation
    ARM offers only 'global' for this resource type; naming a region is rejected with
    LocationNotAvailableForResourceType (same note as in "_shared.ps1"). Defaults to "global".

.PARAMETER SubscriptionId
    Subscription to target. Defaults to '@lab.CloudSubscription.Id' - the Skillable lab
    placeholder that gets substituted with the lab instance's assigned subscription GUID at
    runtime (same pattern as the other LAB 721 Skillable scripts).

.PARAMETER TemplateBaseUri
    Base raw-GitHub URI the infra template is fetched from. Defaults to the IgniteTemplates
    folder pushed to https://github.com/viveksheelsingh/TestScripts.

.PARAMETER UseLocalFiles
    Switch. If set, uses the local template file in this script's folder instead of fetching
    it from GitHub.

.PARAMETER ApiVersion
    ARM api-version for the appDiscoveryAgents resource type. Defaults to
    "2026-09-01-preview", matching "_shared.ps1".

.PARAMETER ModelRef
    Model the agent reasons with, stored at properties.definition.modelDeploymentRef as a
    '<route>;<deployment>' reference (no host name - the service picks the EU or
    rest-of-world endpoint from the subscription's data boundary). Defaults to
    "responsesgpt5mini;gpt-5-mini-infra", matching "_shared.ps1".

.PARAMETER UserAssignedIdentity
    Optional full resource ID of a user-assigned managed identity. When set, the agent uses
    it instead of a system-assigned identity, and this script skips the role-assignment step
    (grant Reader on the UAMI once, outside this script, and every agent using it inherits
    that grant).

.PARAMETER RoleAssignmentMaxAttempts
    New-AzRoleAssignment can fail with "PrincipalNotFound" for a few seconds right after the
    agent's system-assigned identity is created (AAD replication lag). This script retries
    with a delay rather than failing the whole run on that transient error. Defaults to 6
    attempts.

.PARAMETER RoleAssignmentRetryDelaySeconds
    Delay between role-assignment retry attempts. Defaults to 15 seconds.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex3_Task1',

    [ValidateNotNullOrEmpty()]
    [string] $Location = 'southcentralus',

    [ValidateNotNullOrEmpty()]
    [string] $AgentResourceGroupName = 'CaldovaPayApp_Ex3_Task1_DiscoveryAgent',

    [ValidateNotNullOrEmpty()]
    [string] $AgentResourceGroupLocation = 'southcentralus',

    [ValidateNotNullOrEmpty()]
    [string] $AgentName = 'app-discovery-ex3task1',

    [ValidateNotNullOrEmpty()]
    [string] $AgentLocation = 'global',

    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',

    [ValidateNotNullOrEmpty()]
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/IgniteTemplates',

    [switch] $UseLocalFiles,

    [ValidateNotNullOrEmpty()]
    [string] $ApiVersion = '2026-09-01-preview',

    [ValidateNotNullOrEmpty()]
    [string] $ModelRef = 'responsesgpt5mini;gpt-5-mini-infra',

    [string] $UserAssignedIdentity = '',

    [int] $RoleAssignmentMaxAttempts = 6,

    [int] $RoleAssignmentRetryDelaySeconds = 15
)

$ErrorActionPreference = "Stop"
$scriptFolder = $PSScriptRoot
$Provider = 'Microsoft.ResourceIntelligence'
$ResourceType = 'appDiscoveryAgents'

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
$resolvedSubId = (Get-AzContext).Subscription.Id

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

# ===========================================================================
# STEP 1 - Resources: create the target resource group and deploy the infra
# template into it (VNet, Load Balancer, Public IP, VMs, Postgres, Storage).
# No Service Group is created here.
# ===========================================================================
Write-Host "`n########## STEP 1: Deploying resources into '$ResourceGroupName' ##########" -ForegroundColor Magenta

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "`n=== Creating resource group '$ResourceGroupName' in '$Location' ===" -ForegroundColor Cyan
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
    Write-Host "Resource group '$ResourceGroupName' created." -ForegroundColor Green
} else {
    Write-Host "Resource group '$ResourceGroupName' already exists (location: $($rg.Location))." -ForegroundColor Yellow
}

if ($UseLocalFiles) {
    $template = Join-Path $scriptFolder "DiscoverAndCreateSG_LBAndIPOnly.json"
    $isUri = $false
} else {
    $template = "$TemplateBaseUri/DiscoverAndCreateSG_LBAndIPOnly.json"
    $isUri = $true
}

# Retry step1 up to 2 times (3 attempts total) if the deployment fails. Safe to
# retry: step1 deploys with Incremental mode and deterministic resource names
# (uniqueString(resourceGroup().id)), so resources that already succeeded are
# left untouched / no-op'd by ARM on the next attempt - only the resource(s)
# that actually failed (e.g. a transient VM capacity error) get retried.
$maxStep1Attempts = 3
$result = $null
for ($step1Attempt = 1; $step1Attempt -le $maxStep1Attempts; $step1Attempt++) {
    try {
        $deploymentName = "discover-$(Get-Date -Format yyyyMMddHHmmss)"
        $result = Invoke-Deployment -DeploymentName $deploymentName -TemplateUriOrPath $template -IsUri $isUri
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

Write-Host "`n=== Step 1 deployment complete ===" -ForegroundColor Cyan
Write-Host "Public IP      : $($result.Outputs.publicIpId.Value)"
Write-Host "Load Balancer  : $($result.Outputs.loadBalancerId.Value)"

# ===========================================================================
# STEP 2 - Discovery agent: create the appDiscoveryAgents resource (its own,
# separate resource group) and grant it Reader on -ResourceGroupName so it
# can analyze the resources deployed in step 1.
# ===========================================================================
Write-Host "`n########## STEP 2: Creating discovery agent '$AgentName' ##########" -ForegroundColor Magenta

$agentRg = Get-AzResourceGroup -Name $AgentResourceGroupName -ErrorAction SilentlyContinue
if (-not $agentRg) {
    Write-Host "`n=== Creating resource group '$AgentResourceGroupName' in '$AgentResourceGroupLocation' ===" -ForegroundColor Cyan
    New-AzResourceGroup -Name $AgentResourceGroupName -Location $AgentResourceGroupLocation | Out-Null
    Write-Host "Resource group '$AgentResourceGroupName' created." -ForegroundColor Green
} else {
    Write-Host "Agent resource group '$AgentResourceGroupName' already exists (location: $($agentRg.Location))." -ForegroundColor Yellow
}

$agentResourceId = "/subscriptions/$resolvedSubId/resourceGroups/$AgentResourceGroupName/providers/$Provider/$ResourceType/$AgentName"

$agent = [ordered]@{
    id       = $agentResourceId
    name     = $AgentName
    type     = "$Provider/$ResourceType"
    location = $AgentLocation
    identity = if ([string]::IsNullOrWhiteSpace($UserAssignedIdentity)) {
        [ordered]@{ type = 'SystemAssigned' }
    } else {
        [ordered]@{
            type                   = 'UserAssigned'
            userAssignedIdentities = [ordered]@{ $UserAssignedIdentity = @{} }
        }
    }
    properties = [ordered]@{
        displayName = 'App discovery agent'
        description = 'Finds the application boundaries in a scope: groups resources into applications and the services that support them.'
        definition  = [ordered]@{
            modelDeploymentRef = $ModelRef
        }
    }
}

$body = $agent | ConvertTo-Json -Depth 50
$putPath = "${agentResourceId}?api-version=$ApiVersion"

Write-Host "`n=== Creating agent '$AgentName' ===" -ForegroundColor Cyan
Write-Host "PUT $putPath"
Write-Host "Model: $ModelRef"

$response = Invoke-AzRestMethod -Path $putPath -Method PUT -Payload $body
if ($response.StatusCode -ge 300) {
    Write-Host "Agent creation FAILED (HTTP $($response.StatusCode)):" -ForegroundColor Red
    Write-Host $response.Content
    throw "PUT $putPath failed with HTTP $($response.StatusCode)."
}
Write-Host "Agent creation succeeded (HTTP $($response.StatusCode))." -ForegroundColor Green

$agentResult = $response.Content | ConvertFrom-Json
Write-Host "Agent resource ID : $($agentResult.id)"

# ---------------------------------------------------------------------------
# Grant the agent's identity Reader on the resource group deployed in step 1
# - required before the first run, or any conversation ends Failed with an
# AccessDenied error from Resource Graph.
# ---------------------------------------------------------------------------
$rgScope = "/subscriptions/$resolvedSubId/resourceGroups/$ResourceGroupName"

if (-not [string]::IsNullOrWhiteSpace($UserAssignedIdentity)) {
    Write-Host "`nUser-assigned identity in use ($UserAssignedIdentity) - skipping role assignment." -ForegroundColor Yellow
    Write-Host "Grant it Reader on $rgScope once; every agent using it inherits that grant." -ForegroundColor Yellow
} else {
    $principalId = $agentResult.identity.principalId
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        Write-Host "`nNo principalId returned on the agent's identity yet - skipping role assignment." -ForegroundColor Yellow
        Write-Host "Re-run this script, or grant Reader manually once the identity is available." -ForegroundColor Yellow
    } else {
        Write-Host "`n=== Granting Reader on '$rgScope' to principal '$principalId' ===" -ForegroundColor Cyan

        # Role assignment is done via a direct ARM REST call (Invoke-AzRestMethod) rather
        # than New-AzRoleAssignment / Get-AzRoleAssignment deliberately: those Az PowerShell
        # cmdlets resolve the principal through Microsoft Graph first, which requires an
        # interactive/WAM-capable login. That isn't available in a Skillable lab (or any
        # non-interactive runner) - and az CLI may not be available there either, so this
        # stays on Az PowerShell's ARM-only Invoke-AzRestMethod (same approach already used
        # above to create the agent resource).
        $readerRoleDefinitionId = "/subscriptions/$resolvedSubId/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
        $roleAssignmentApiVersion = '2022-04-01'

        $existing = $null
        try {
            $filter = [uri]::EscapeDataString("principalId eq '$principalId'")
            $listPath = "$rgScope/providers/Microsoft.Authorization/roleAssignments?api-version=$roleAssignmentApiVersion&`$filter=$filter"
            $listResponse = Invoke-AzRestMethod -Method GET -Path $listPath -ErrorAction Stop
            if ($listResponse.StatusCode -eq 200) {
                $listResult = $listResponse.Content | ConvertFrom-Json
                $existing = $listResult.value | Where-Object { $_.properties.roleDefinitionId -eq $readerRoleDefinitionId }
            }
        } catch {
            Write-Host "Could not list existing role assignments (continuing to attempt creation): $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        if ($existing) {
            Write-Host "Role assignment already exists - nothing to do." -ForegroundColor Yellow
        } else {
            $assigned = $false
            for ($attempt = 1; $attempt -le $RoleAssignmentMaxAttempts; $attempt++) {
                $roleAssignmentName = [guid]::NewGuid().ToString()
                $putPath = "$rgScope/providers/Microsoft.Authorization/roleAssignments/${roleAssignmentName}?api-version=$roleAssignmentApiVersion"
                $raBody = @{
                    properties = @{
                        roleDefinitionId = $readerRoleDefinitionId
                        principalId      = $principalId
                        principalType    = 'ServicePrincipal'
                    }
                } | ConvertTo-Json -Depth 5

                $raResponse = Invoke-AzRestMethod -Method PUT -Path $putPath -Payload $raBody

                if ($raResponse.StatusCode -eq 200 -or $raResponse.StatusCode -eq 201) {
                    $assigned = $true
                    break
                }

                $raContent = $raResponse.Content | Out-String

                # A system-assigned identity created moments ago is not resolvable in AAD yet
                # (replication lag), which fails this call with "PrincipalNotFound". Retry
                # rather than abandon the whole run on that specific, transient error.
                if ($raContent -match 'PrincipalNotFound' -and $attempt -lt $RoleAssignmentMaxAttempts) {
                    Write-Host "Attempt $attempt of $RoleAssignmentMaxAttempts : principal not yet resolvable, retrying in ${RoleAssignmentRetryDelaySeconds}s ..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds $RoleAssignmentRetryDelaySeconds
                    continue
                }

                throw "Role assignment PUT failed with HTTP $($raResponse.StatusCode): $raContent"
            }

            if ($assigned) {
                Write-Host "Reader granted on '$rgScope'." -ForegroundColor Green
            } else {
                Write-Host "Could not confirm the role assignment after $RoleAssignmentMaxAttempts attempts." -ForegroundColor Red
                Write-Host "Grant it manually (PowerShell, ARM REST - no Graph lookup needed):" -ForegroundColor Yellow
                Write-Host "`$body = @{ properties = @{ roleDefinitionId = '$readerRoleDefinitionId'; principalId = '$principalId'; principalType = 'ServicePrincipal' } } | ConvertTo-Json -Depth 5"
                Write-Host "Invoke-AzRestMethod -Method PUT -Path '$rgScope/providers/Microsoft.Authorization/roleAssignments/<new-guid>?api-version=$roleAssignmentApiVersion' -Payload `$body"
            }
        }

        Write-Host "`nA new role assignment takes a few minutes to reach Resource Graph:" -ForegroundColor Yellow
        Write-Host "wait about 5 minutes before starting the first conversation/run." -ForegroundColor Yellow
    }
}

Write-Host "`n########## Done ##########" -ForegroundColor Magenta
Write-Host "Resources RG    : $ResourceGroupName"
Write-Host "Agent           : $AgentName"
Write-Host "Agent resource  : $agentResourceId"
Write-Host "Agent RG        : $AgentResourceGroupName"
Write-Host "Analyzes RG     : $ResourceGroupName"
Write-Host "`nTo run a discovery conversation against this agent, use the DiscoveryAgentPUT" -ForegroundColor Yellow
Write-Host "toolkit (01-put-conversation.ps1 ... 05-download-artifacts.ps1), pointing ARIS_RG" -ForegroundColor Yellow
Write-Host "at '$AgentResourceGroupName' and ARIS_AGENT at '$AgentName' (and passing" -ForegroundColor Yellow
Write-Host "-ResourceGroup $ResourceGroupName to 01-put-conversation.ps1 as the scope to analyze)." -ForegroundColor Yellow
