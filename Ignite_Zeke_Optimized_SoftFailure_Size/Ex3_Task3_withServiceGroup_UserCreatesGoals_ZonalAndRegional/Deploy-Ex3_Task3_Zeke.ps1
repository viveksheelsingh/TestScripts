#Requires -Version 7.2
<#
.SYNOPSIS
    Ex3_Task3: GitHub-only templates with best-effort deployment continuation.
.DESCRIPTION
    Creates shared infrastructure, then independently attempts the SG and its membership batch.
    Goals remain a learner step. Regional fallback only removes a confirmed-empty
    RG created/tagged by this run; existing or partial RGs are retained.
    All six SG memberships are submitted together per attempt; a failed batch
    is logged and subsequent stages are still attempted.
    Templates are always downloaded from TemplateBaseUri (GitHub by default).
    No embedded or adjacent-file fallback. Template/authentication/input failures
    remain fatal; resource/stage failures finish with warnings. Uses Az PowerShell only.
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex3_Task3',
    [string] $Location = 'southcentralus',
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/Ignite_Zeke_Optimized_SoftFailure_Size/Ex3_Task3_withServiceGroup_UserCreatesGoals_ZonalAndRegional',
    [securestring] $AdministratorPassword,
    [string] $TenantId = '@lab.CloudSubscription.TenantId',
    [string] $LabInstanceId = '@lab.LabInstance.Id',
    [string] $UserUpn = '@lab.CloudPortalCredential(User1).Username',
    [string] $ScopedAppId = '@lab.Variable(SGDeployAppId)',
    [string] $ScopedAppObjectId = '@lab.Variable(SGDeployAppObjectId)',
    [string] $SharedResourceGroupName = 'CaldovaPayApp_Ex3_Task3',
    [string[]] $Regions = @('southcentralus','centralus','eastus2')
)
$TaskName = 'Ex3_Task3'
$OwnsInfrastructure = $true
$LocationWasSpecified = $PSBoundParameters.ContainsKey('Location')

#region Scoped-SP helpers
function Get-GraphHeader {
    $t = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -ErrorAction Stop).Token
    if ($t -is [securestring]) { $t = [System.Net.NetworkCredential]::new('', $t).Password }
    @{ Authorization = "Bearer $t" }
}

function Connect-ScopedSP {
    # Adds a short-lived secret to the scoped app (as the Skillable SP), then signs in as the scoped SP.
    param([int]$SecretLifetimeMinutes = 90)
    $mainContext = Get-AzContext
    $body = @{ passwordCredential = @{
                displayName = "lca-$TaskName-$(Get-Date -Format yyyyMMddHHmmss)"
                endDateTime = (Get-Date).ToUniversalTime().AddMinutes($SecretLifetimeMinutes).ToString('o') } } |
            ConvertTo-Json -Depth 3

    # The sibling LCAs write to the same app object; Entra rejects simultaneous writes
    # (Directory_ConcurrencyViolation), so retry with jitter.
    for ($i = 1; ; $i++) {
        try {
            $pw = Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/applications/$ScopedAppObjectId/addPassword" `
                      -Headers (Get-GraphHeader) -ContentType 'application/json' -Body $body
            break
        } catch {
            $msg = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
            if ($i -ge 8 -or $msg -notmatch 'ConcurrencyViolation|concurrent|429|Throttl|503') { throw "addPassword failed: $msg" }
            Start-Sleep -Seconds (Get-Random -Minimum 5 -Maximum 25)
        }
    }

    $cred = [pscredential]::new($ScopedAppId, (ConvertTo-SecureString $pw.secretText -AsPlainText -Force))
    for ($i = 1; ; $i++) {   # new secrets take a moment to become usable
        try {
            Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Subscription $SubscriptionId -Credential $cred `
                -ContextName "scoped-$ScopedAppId-$TaskName" -Scope Process -Force -ErrorAction Stop | Out-Null
            break
        } catch {
            if ($i -ge 10) {
                Disconnect-ScopedSP ([pscustomobject]@{ MainContext = $mainContext; KeyId = $pw.keyId })
                throw "Could not sign in as scoped SP ${ScopedAppId}: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 30
        }
    }
    if ((Get-AzContext).Account.Id -ne $ScopedAppId) { throw "Az context is not the scoped SP." }
    [pscustomobject]@{ MainContext = $mainContext; KeyId = $pw.keyId }
}

function Disconnect-ScopedSP {
    # Back to the Skillable SP; remove the temporary secret (best effort - it expires anyway).
    param($Session)
    if (-not $Session) { return }
    Set-AzContext -Context $Session.MainContext -ErrorAction SilentlyContinue | Out-Null
    Remove-AzContext -Name "scoped-$ScopedAppId-$TaskName" -Force -ErrorAction SilentlyContinue | Out-Null
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/applications/$ScopedAppObjectId/removePassword" `
                -Headers (Get-GraphHeader) -ContentType 'application/json' -Body (@{ keyId = $Session.KeyId } | ConvertTo-Json) | Out-Null
            return
        } catch { Start-Sleep -Seconds (Get-Random -Minimum 5 -Maximum 15) }
    }
}
#endregion

function Get-BuiltInRoleId {
    param([string]$RoleName)
    $filter = [uri]::EscapeDataString("roleName eq '$RoleName'")
    foreach ($scope in "/providers/Microsoft.Management/serviceGroups/$TenantId", '', "/subscriptions/$SubscriptionId") {
        $r = Invoke-AzRestMethod -Method GET -Path "$scope/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&`$filter=$filter"
        if ($r.StatusCode -eq 200) {
            $def = @(($r.Content | ConvertFrom-Json).value) | Select-Object -First 1
            if ($def) { return $def.name }
        }
    }
    throw "Role definition '$RoleName' not found."
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
    $regionsToTry = @($Location)
    if ($TaskName -ne 'Ex3_Task1') {
        $start = [int]([int64]$LabInstanceId % $Regions.Count)
        $regionsToTry = @(0..($Regions.Count - 1) | ForEach-Object { $Regions[($start + $_) % $Regions.Count] })
        if ($LocationWasSpecified) {
            $regionsToTry = @($Location) + @($regionsToTry | Where-Object { $_ -ne $Location })
        }
    }
    if ($existing) { $regionsToTry = @($existing.Location) }
    $runId = [guid]::NewGuid().ToString()
    $regionFailures = [Collections.Generic.List[object]]::new()
    foreach ($region in $regionsToTry) {
        if (-not $existing) {
            $existing = New-LabResourceGroup -Name $ResourceGroupName -Region $region `
                -Tags @{ IgniteSoftFailureRunId = $runId }
        }
        $Parameters.location = $region
        $Deployment.Location = $region
        $regionFailures.Clear()
        $arguments = @{ Stage = 'Infrastructure'; Template = $Template; Parameters = $Parameters }
        if ($TaskName -eq 'Ex3_Task1') { $arguments.MaxAttempts = 3; $arguments.DelaySeconds = 180 }
        else { $arguments.MaxAttempts = 2; $arguments.DelaySeconds = 120; $arguments.StopOnAllocationError = $true }
        try { $null = Invoke-LabDeployment @arguments }
        catch {
            $regionFailures.Add([pscustomobject]@{
                Stage = "Infrastructure/$region"
                Message = $_.Exception.Message
            })
            Write-Warning "Infrastructure in '$region' failed: $($_.Exception.Message). Remaining stages will still be attempted."
        }
        if (-not $regionFailures.Count) { return }
        if ($region -eq $regionsToTry[-1]) { break }
        # A partial application is more useful than an empty RG in another region.
        if ($existing.Tags.IgniteSoftFailureRunId -ne $runId) { break }
        try { $resources = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop) }
        catch { Write-Warning 'Cannot confirm that the RG is empty; retaining it.'; break }
        if ($resources.Count) { Write-Warning 'Partial resources retained; no cross-region deletion.'; break }
        $current = Get-LabResourceGroup $ResourceGroupName
        if ($current.Tags.IgniteSoftFailureRunId -ne $runId) { break }
        Invoke-WithRetry { Remove-AzResourceGroup -Name $ResourceGroupName -Force -ErrorAction Stop | Out-Null }
        $existing = $null
    }
    foreach ($failure in $regionFailures) { $Failures.Add($failure) }
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

$ConfigurationTemplate = Get-LabTemplate "${TaskName}_Configuration.json"
$ServiceGroupName = "CaldovaPayApp_${TaskName}_SG_$LabInstanceId"
$ServiceGroupScope = "/providers/Microsoft.Management/serviceGroups/$ServiceGroupName"

function Invoke-Configuration {
    param([string] $Phase, [string] $Member = '')
    $parameters = @{
        serviceGroupName = $ServiceGroupName
        sharedResourceGroupName = $SharedResourceGroupName
        location = $Deployment.Location
        phase = $Phase
        memberKey = $Member
    }
    Invoke-LabDeployment -Stage "$Phase$(if ($Member) { "-$Member" })" `
        -Template $ConfigurationTemplate -Parameters $parameters
}

foreach ($value in @($TenantId, $ScopedAppId, $ScopedAppObjectId)) {
    if ($value -notmatch $GuidPattern) { throw 'Resolve the Skillable tenant/scoped-app placeholders or supply explicit parameters.' }
}
if ($context.Tenant.Id -ne $TenantId -or $LabInstanceId -notmatch '^[0-9]+$' -or
        -not $Regions.Count -or @($Regions | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
    throw 'Supply the signed-in tenant, numeric lab instance ID and valid fallback regions.'
}
$SharedResourceGroupName = $ResourceGroupName
$identities = @{ UserId = $null; AdministratorRole = $null }
Invoke-SoftAction 'Learner lookup' {
    $identities.UserId = (Invoke-RestMethod -Headers (Get-GraphHeader) `
        -Uri "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($UserUpn))?`$select=id" -ErrorAction Stop).id
    if ($identities.UserId -notmatch $GuidPattern) { throw 'The lab user was not found in Entra ID.' }
}
Invoke-SoftAction 'Administrator role lookup' {
    $identities.AdministratorRole = Get-BuiltInRoleId -RoleName 'Service Group Administrator'
}
$session = $null
try {
    $session = Connect-ScopedSP -SecretLifetimeMinutes 90
    Start-Sleep -Seconds 60
    $token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
    if (-not $token.Token) { throw 'Failed to refresh the scoped ARM access token.' }
    $token = $null
    Invoke-SoftAction 'Infrastructure' {
        $null = Invoke-Infrastructure -Template $InfrastructureTemplate `
            -Parameters @{ location = $Location; administratorPassword = $AdministratorPassword }
    }
    Invoke-SoftAction 'Service Group' { $null = Invoke-Configuration 'ServiceGroup' }
    Start-Sleep -Seconds 120
    $token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
    if (-not $token.Token) { throw 'Failed to refresh the scoped ARM access token.' }
    $token = $null
    Invoke-SoftAction 'Learner SG Administrator' {
        Grant-LabRole -PrincipalId $identities.UserId -RoleId $identities.AdministratorRole -Scope $ServiceGroupScope -PrincipalType User
    }
    Invoke-SoftAction 'SG memberships' {
        $null = Invoke-Configuration -Phase 'Membership' -Member 'All'
    }
} finally {
    Disconnect-ScopedSP $session
}
Show-LabSummary
Write-Host "Service Group: $ServiceGroupScope. Shared resource RG: $SharedResourceGroupName"
Write-Host 'Next: create zonal and regional goals manually for this Service Group.'
