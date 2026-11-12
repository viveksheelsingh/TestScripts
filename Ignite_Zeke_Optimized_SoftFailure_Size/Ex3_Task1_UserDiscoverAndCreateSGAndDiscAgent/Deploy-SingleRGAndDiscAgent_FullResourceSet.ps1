#Requires -Version 7.2
<#
.SYNOPSIS
    Ex3_Task1: Discovery-agent-only setup with best-effort continuation.
.DESCRIPTION
    Creates the discovery-agent RG and agent, then grants its system-assigned identity Reader
    on ResourceGroupName. The source RG and raw resources are deployed separately.
    A missing source RG skips the Reader grant with a warning; agent creation is independent.
    No infrastructure templates are downloaded or deployed. Location, TemplateBaseUri and
    AdministratorPassword are retained only for compatibility with existing invocations.
    Authentication/input failures remain fatal; stage failures finish with warnings.
    Emits no status output by default for Skillable lifecycle actions.
    Use -Verbose only for manual diagnostics, including soft-failure details.
    Uses Az PowerShell only.
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex3_Task1',
    [string] $Location = 'southcentralus',
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/Ignite_Zeke_Optimized_SoftFailure_Size/Ex3_Task1_UserDiscoverAndCreateSGAndDiscAgent',
    [securestring] $AdministratorPassword,
    [string] $AgentResourceGroupName = 'CaldovaPayApp_Ex3_Task1_DiscoveryAgent',
    [string] $AgentResourceGroupLocation = 'southcentralus',
    [string] $AgentName = 'app-discovery-ex3task1',
    [string] $AgentLocation = 'global',
    [string] $ApiVersion = '2026-09-01-preview',
    [string] $ModelRef = 'responsesgpt5mini;gpt-5-mini-infra',
    [string] $UserAssignedIdentity = '',
    [ValidateRange(1,20)][int] $RoleAssignmentMaxAttempts = 6,
    [ValidateRange(0,300)][int] $RoleAssignmentRetryDelaySeconds = 15
)
$TaskName = 'Ex3_Task1'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = if ($PSBoundParameters['Verbose']) { 'Continue' } else { 'SilentlyContinue' }
$Failures = [Collections.Generic.List[object]]::new()
$GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

function Invoke-SoftAction {
    param([string] $Stage, [scriptblock] $Action)
    Write-Verbose "=== $Stage ==="
    try { & $Action }
    catch {
        $Failures.Add([pscustomobject]@{ Stage = $Stage; Message = $_.Exception.Message })
        Write-Verbose "WARNING: ${Stage}: $($_.Exception.Message). Continuing with remaining stages."
    }
}

function Invoke-WithRetry {
    param([scriptblock] $Action, [int] $MaxAttempts = 3, [int] $DelaySeconds = 30)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try { return & $Action }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Verbose "WARNING: Attempt $attempt failed: $($_.Exception.Message). Retrying."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-LabResourceGroup {
    param([string] $Name)
    try { Get-AzResourceGroup -Name $Name -ErrorAction Stop }
    catch {
        $details = "$($_.FullyQualifiedErrorId) $($_.ErrorDetails.Message) $($_.Exception.Message)"
        if ($_.Exception.Response.StatusCode -ne 404 -and
                $details -notmatch 'ResourceGroupNotFound|Provided resource group does not exist\.') { throw }
        return $null
    }
}

function New-LabResourceGroup {
    param([string] $Name, [string] $Region, [hashtable] $Tags = @{})
    Invoke-WithRetry {
        New-AzResourceGroup -Name $Name -Location $Region -Tag $Tags -ErrorAction Stop
    }
}

function Grant-LabRole {
    param([string] $PrincipalId, [string] $RoleId, [string] $Scope,
        [ValidateSet('User','ServicePrincipal')][string] $PrincipalType)
    if ($PrincipalId -notmatch $GuidPattern -or $RoleId -notmatch $GuidPattern) {
        throw 'A valid principal and role ID are required for role assignment.'
    }
    $bytes = [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes("$Scope|$PrincipalId|$RoleId".ToLowerInvariant()))
    $assignment = [guid]::new([byte[]]$bytes[0..15]).ToString()
    $roleScope = if ($Scope -like '/subscriptions/*') { "/subscriptions/$SubscriptionId" } else { '' }
    $body = @{ properties = @{
        roleDefinitionId = "$roleScope/providers/Microsoft.Authorization/roleDefinitions/$RoleId"
        principalId = $PrincipalId
        principalType = $PrincipalType
    } } | ConvertTo-Json -Depth 5
    Invoke-WithRetry -MaxAttempts 6 -DelaySeconds 30 {
        try {
            $response = Invoke-AzRestMethod -Method PUT -Payload $body -ErrorAction Stop `
                -Path "$Scope/providers/Microsoft.Authorization/roleAssignments/${assignment}?api-version=2022-04-01"
            if ($response.StatusCode -in 200,201 -or $response.Content -match 'RoleAssignmentExists') { return }
            throw "Role assignment returned HTTP $($response.StatusCode): $($response.Content)"
        } catch {
            if ("$($_.ErrorDetails.Message) $($_.Exception.Message)" -match 'RoleAssignmentExists') { return }
            throw
        }
    }
}

function Show-LabSummary {
    Write-Verbose "$TaskName finished. Resource group: $ResourceGroupName"
    if ($Failures.Count) {
        Write-Verbose "WARNING: $($Failures.Count) stage(s) failed. The script completed successfully with warnings; partial resources were retained."
        foreach ($failure in $Failures) { Write-Verbose "WARNING: $($failure.Stage): $($failure.Message)" }
    } else { Write-Verbose 'All requested stages succeeded.' }
}

if ($SubscriptionId -notmatch $GuidPattern -or [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    throw 'Supply a valid subscription ID and source resource group name.'
}
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
$context = Get-AzContext -ErrorAction Stop
if (-not $context.Account -or $context.Subscription.Id -ne $SubscriptionId) {
    throw 'Az PowerShell must be signed in to the selected subscription.'
}
$token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
if (-not $token.Token) { throw 'Failed to acquire an ARM access token.' }
$token = $null
$agentResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$AgentResourceGroupName/providers/Microsoft.ResourceIntelligence/appDiscoveryAgents/$AgentName"
Invoke-SoftAction 'Discovery agent RG' {
    if (-not (Get-LabResourceGroup $AgentResourceGroupName)) {
        $null = New-LabResourceGroup -Name $AgentResourceGroupName -Region $AgentResourceGroupLocation
    }
}
Invoke-SoftAction 'Discovery agent' {
    $identity = if ([string]::IsNullOrWhiteSpace($UserAssignedIdentity)) {
        @{ type = 'SystemAssigned' }
    } else {
        @{ type = 'UserAssigned'; userAssignedIdentities = @{ $UserAssignedIdentity = @{} } }
    }
    $body = @{
        location = $AgentLocation
        identity = $identity
        properties = @{
            displayName = 'App discovery agent'
            description = 'Finds the application boundaries in a scope: groups resources into applications and the services that support them.'
            definition = @{ modelDeploymentRef = $ModelRef }
        }
    } | ConvertTo-Json -Depth 10
    Invoke-WithRetry {
        $response = Invoke-AzRestMethod -Method PUT -Path "${agentResourceId}?api-version=$ApiVersion" -Payload $body -ErrorAction Stop
        if ($response.StatusCode -notin 200,201,202) { throw "Agent creation returned HTTP $($response.StatusCode)." }
    }
}
if ([string]::IsNullOrWhiteSpace($UserAssignedIdentity)) {
    Invoke-SoftAction 'Discovery agent Reader' {
        if (-not (Get-LabResourceGroup $ResourceGroupName)) {
            throw "Source resource group '$ResourceGroupName' does not exist. Deploy the separate resource template, then rerun this script to grant Reader."
        }
        $principal = Invoke-WithRetry -MaxAttempts $RoleAssignmentMaxAttempts -DelaySeconds $RoleAssignmentRetryDelaySeconds {
            $response = Invoke-AzRestMethod -Method GET -Path "${agentResourceId}?api-version=$ApiVersion" -ErrorAction Stop
            if ($response.StatusCode -ne 200) { throw "Agent lookup returned HTTP $($response.StatusCode)." }
            $principal = ($response.Content | ConvertFrom-Json).identity.principalId
            if ($principal -notmatch $GuidPattern) { throw 'The discovery agent identity is not yet available.' }
            return $principal
        }
        Grant-LabRole -PrincipalId $principal -RoleId 'acdd72a7-3385-48ef-bd42-f606fba81ae7' `
            -Scope "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" -PrincipalType ServicePrincipal
    }
} else { Write-Verbose 'User-assigned identity: its Reader grant remains externally managed.' }
Show-LabSummary
Write-Verbose "Discovery agent: $agentResourceId"
Write-Verbose 'No raw resources or Service Group are created by this script; discover the separately deployed resources and create the Service Group manually.'
