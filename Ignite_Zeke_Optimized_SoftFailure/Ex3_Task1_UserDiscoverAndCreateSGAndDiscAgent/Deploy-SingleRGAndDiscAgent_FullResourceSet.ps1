#Requires -Version 7.2
<#
.SYNOPSIS
    Ex3_Task1: full-template infrastructure with best-effort continuation.
.DESCRIPTION
    Creates independent infrastructure, then attempts discovery-agent RG, agent and Reader setup.
    Infrastructure gets three attempts in the selected/existing RG region; no regional fallback.
    ARM handles parallelism/dependencies in one full-template submission per attempt.
    Partial resources are retained. Resource/stage failures finish with warnings;
    authentication, input and template errors remain fatal. Uses Az PowerShell only.
    Local JSON is preferred, otherwise TemplateBaseUri is used. Set it empty for
    bundled GZip-compressed JSON; UseLocalFiles requires adjacent templates.
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex3_Task1',
    [string] $Location = 'southcentralus',
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/Ignite_Zeke_Optimized_SoftFailure/Ex3_Task1_UserDiscoverAndCreateSGAndDiscAgent',
    [securestring] $AdministratorPassword,
    [switch] $UseLocalFiles,
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

function Expand-LabTemplate {
    param([string] $Data)
    $stream = [IO.MemoryStream]::new([Convert]::FromBase64String($Data))
    try {
        $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
        $reader = [IO.StreamReader]::new($gzip, [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

$EmbeddedTemplates = @{
'Ex3_Task1_Infrastructure.json' = (Expand-LabTemplate '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')
}

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
    $localPath = $null
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $localPath = Join-Path $PSScriptRoot $Name
    }
    if ($localPath -and (Test-Path -LiteralPath $localPath)) {
        return Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json -AsHashtable
    }
    if ($UseLocalFiles) {
        throw "Required template '$Name' is missing. Run the .ps1 from its template folder, or omit -UseLocalFiles and supply a published -TemplateBaseUri."
    }
    if ([string]::IsNullOrWhiteSpace($TemplateBaseUri)) {
        return $EmbeddedTemplates[$Name] | ConvertFrom-Json -AsHashtable
    }
    Invoke-WithRetry {
        Invoke-RestMethod -Uri "$($TemplateBaseUri.TrimEnd('/'))/$Name" -ErrorAction Stop |
            ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
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
