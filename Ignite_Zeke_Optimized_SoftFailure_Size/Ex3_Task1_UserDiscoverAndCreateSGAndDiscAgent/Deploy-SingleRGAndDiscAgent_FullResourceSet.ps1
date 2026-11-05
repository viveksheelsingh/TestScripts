#Requires -Version 7.2
<#
.SYNOPSIS
    Ex3_Task1: GitHub-only templates with best-effort deployment continuation.
.DESCRIPTION
    Creates independent infrastructure, then attempts discovery-agent RG, agent and Reader setup.
    Infrastructure gets three attempts in the selected/existing RG region; no regional fallback.
    Templates are always downloaded from TemplateBaseUri (GitHub by default).
    No embedded or adjacent-file fallback. Template/authentication/input failures
    remain fatal; resource/stage failures finish with warnings. Uses Az PowerShell only.
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
$OwnsInfrastructure = $true

$ErrorActionPreference = 'Stop'
$Failures = [Collections.Generic.List[object]]::new()
$Deployment = @{ Location = $Location }
$AllocationErrors = 'OverconstrainedZonalAllocationRequest|OverconstrainedAllocationRequest|ZonalAllocationFailed|AllocationFailed|SkuNotAvailable'
$GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

function Invoke-SoftAction {
    param([string] $Stage, [scriptblock] $Action)
    Write-Host "`n=== $Stage ===" -ForegroundColor Cyan
    try { & $Action }
    catch {
        $Failures.Add([pscustomobject]@{ Stage = $Stage; Message = $_.Exception.Message })
        Write-Warning "${Stage}: $($_.Exception.Message). Continuing with remaining stages."
    }
}

function Invoke-WithRetry {
    param([scriptblock] $Action, [int] $MaxAttempts = 3, [int] $DelaySeconds = 30)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try { return & $Action }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning "Attempt $attempt failed: $($_.Exception.Message). Retrying."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-LabTemplate {
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($TemplateBaseUri)) {
        throw "TemplateBaseUri is required. Supply the GitHub folder containing '$Name'."
    }
    Invoke-WithRetry {
        $template = Invoke-RestMethod -Uri "$($TemplateBaseUri.TrimEnd('/'))/$Name" -ErrorAction Stop |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        if ($template -isnot [Collections.IDictionary] -or -not $template.Contains('$schema') -or
                $template.parameters -isnot [Collections.IDictionary] -or $template.resources -isnot [array]) {
            throw "Downloaded '$Name' is not an ARM template."
        }
        return $template
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

function Invoke-LabDeployment {
    param([string] $Stage, [hashtable] $Template, [hashtable] $Parameters,
        [int] $MaxAttempts = 3, [int] $DelaySeconds = 30, [switch] $StopOnAllocationError)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $name = "$TaskName-$Stage-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $deployment = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $name `
                -TemplateObject $Template -TemplateParameterObject $Parameters -Mode Incremental -ErrorAction Stop
            if ($deployment.ProvisioningState -ne 'Succeeded') {
                throw "Deployment ended in state '$($deployment.ProvisioningState)'."
            }
            return $deployment
        } catch {
            $failure = $_.Exception.Message
            try {
                $operations = @(Get-AzResourceGroupDeploymentOperation -ResourceGroupName $ResourceGroupName `
                    -DeploymentName $name -ErrorAction Stop |
                    Where-Object ProvisioningState -eq 'Failed' |
                    ForEach-Object { "$($_.TargetResource): $($_.StatusMessage)" })
                if ($operations.Count) { $failure += " $($operations -join ' | ')" }
            } catch { Write-Warning 'Failed deployment-operation details could not be read.' }
            if (($StopOnAllocationError -and $failure -match $AllocationErrors) -or $attempt -ge $MaxAttempts) {
                throw $failure
            }
            Write-Warning "$Stage attempt $attempt failed: $failure"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Invoke-Infrastructure {
    param([hashtable] $Template, [hashtable] $Parameters)
    $existing = Get-LabResourceGroup $ResourceGroupName
    $region = if ($existing) { $existing.Location } else { $Location }
    if (-not $existing) {
        $null = New-LabResourceGroup -Name $ResourceGroupName -Region $region `
            -Tags @{ IgniteSoftFailureRunId = [guid]::NewGuid().ToString() }
    }
    $Parameters.location = $region
    $Deployment.Location = $region
    try {
        $null = Invoke-LabDeployment -Stage 'Infrastructure' -Template $Template -Parameters $Parameters `
            -MaxAttempts 3 -DelaySeconds 180
    } catch {
        $Failures.Add([pscustomobject]@{ Stage = "Infrastructure/$region"; Message = $_.Exception.Message })
        Write-Warning "Infrastructure in '$region' failed: $($_.Exception.Message). Remaining stages will still be attempted."
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
    Write-Host "`n$TaskName finished. Resource group: $ResourceGroupName" -ForegroundColor Green
    if ($Failures.Count) {
        Write-Warning "$($Failures.Count) stage(s) failed. The script completed successfully with warnings; partial resources were retained."
        foreach ($failure in $Failures) { Write-Warning "$($failure.Stage): $($failure.Message)" }
    } else { Write-Host 'All requested stages succeeded.' -ForegroundColor Green }
}

if ($SubscriptionId -notmatch $GuidPattern -or [string]::IsNullOrWhiteSpace($ResourceGroupName) -or
        [string]::IsNullOrWhiteSpace($Location)) {
    throw 'Supply a valid subscription ID, resource group name and location.'
}
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
$context = Get-AzContext -ErrorAction Stop
if (-not $context.Account -or $context.Subscription.Id -ne $SubscriptionId) {
    throw 'Az PowerShell must be signed in to the selected subscription.'
}
if ($TaskName -eq 'Ex3_Task1') { Start-Sleep -Seconds 60 }
$token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
if (-not $token.Token) { throw 'Failed to acquire an ARM access token.' }
$token = $null
if ($OwnsInfrastructure -and -not $AdministratorPassword) {
    $labPassword = @'
@lab.CloudPortalCredential(User1).Password
'@
    if ($labPassword.StartsWith('@lab.')) { throw 'Supply -AdministratorPassword as a SecureString outside Skillable.' }
    $AdministratorPassword = ConvertTo-SecureString $labPassword -AsPlainText -Force
    $labPassword = $null
}
if ($OwnsInfrastructure) { $InfrastructureTemplate = Get-LabTemplate "${TaskName}_Infrastructure.json" }

Invoke-SoftAction 'Infrastructure' {
    $null = Invoke-Infrastructure -Template $InfrastructureTemplate `
        -Parameters @{ location = $Location; administratorPassword = $AdministratorPassword }
}
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
} else { Write-Host 'User-assigned identity: its Reader grant remains externally managed.' }
Show-LabSummary
Write-Host "Discovery agent: $agentResourceId"
Write-Host 'No Service Group is created in Ex3_Task1; discover the deployed resources and create it manually.'
