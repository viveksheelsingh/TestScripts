#Requires -Version 7.2
<#
.SYNOPSIS
    Ex3_Task3: full-template infrastructure with best-effort continuation.
.DESCRIPTION
    Creates shared infrastructure, then independently attempts the SG and each membership.
    Goals remain a learner step; no AHM, usage plan, RO or Drill work runs.
    Regional fallback only removes a confirmed-empty RG created/tagged by this run.
    ARM handles parallelism/dependencies in one full-template submission per attempt.
    Partial resources are retained. Resource/stage failures finish with warnings;
    authentication, input and template errors remain fatal. Uses Az PowerShell only.
    Local JSON is preferred, otherwise TemplateBaseUri is used. Set it empty for
    bundled GZip-compressed JSON; UseLocalFiles requires adjacent templates.
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex3_Task3',
    [string] $Location = 'southcentralus',
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/Ignite_Zeke_Optimized_SoftFailure/Ex3_Task3_withServiceGroup_UserCreatesGoals_ZonalAndRegional',
    [securestring] $AdministratorPassword,
    [switch] $UseLocalFiles,
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
'Ex3_Task3_Configuration.json' = (Expand-LabTemplate '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')
'Ex3_Task3_Infrastructure.json' = (Expand-LabTemplate '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')
}

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
    foreach ($member in 'vnetId','publicIpId','loadBalancerId','webVm1Id','webVm2Id','appVm1Id','appVm2Id','postgresId','storageId') {
        Invoke-SoftAction "Membership $member" { $null = Invoke-Configuration -Phase 'Membership' -Member $member }
    }
} finally {
    Disconnect-ScopedSP $session
}
Show-LabSummary
Write-Host "Service Group: $ServiceGroupScope. Shared resource RG: $SharedResourceGroupName"
Write-Host 'Next: create zonal and regional goals manually for this Service Group.'
