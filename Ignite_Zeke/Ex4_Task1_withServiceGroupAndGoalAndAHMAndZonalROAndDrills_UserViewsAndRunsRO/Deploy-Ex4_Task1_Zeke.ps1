#Requires -Version 7.2
<#
.SYNOPSIS
    Ex4_Task1: separate exercise deployment RG with shared Ex3_Task3 infrastructure.
.DESCRIPTION
    Each exercise creates its own deployment RG and a separate Service Group.
    Only Ex3_Task3 deploys the shared infrastructure in CaldovaPayApp_Ex3_Task3:
    PostgreSQL Standard_B1ms/Burstable with HA disabled, and Standard_LRS storage.
    Initial Ex3_Task3 provisioning retains RG retries and rotated regional fallback.
    Only an RG created and tagged by the current failed provisioning run can be recreated
    in another region. An existing shared RG is never deleted. Later exercises create
    their own RGs with retries and retry configuration in place, never deleting the
    shared RG. Existing non-optimized copies are unchanged.
    Ex3_Task4 and Ex4_Task1 use SharedResourceGroupName to compute the nine member IDs,
    independently of their own ResourceGroupName. They also attempt step2 when the
    shared RG is missing or partial. They pass all nine
    expected IDs to step2 without checking member existence or requiring a success marker.
    Step2 makes three attempts and retains partial success. Goals and usage plans do not
    wait for all memberships; enrollment -> recovery plan -> drill ordering is retained.
    The infrastructure-state tag is diagnostic only. Ex4 creates the Service Group,
    memberships, goal, AHM, usage plan/enrollment, recovery plan and Drill.
    It does not configure RO/Drill resources or run their readiness checks.
    Local templates beside the .ps1 are preferred. Inline lifecycle actions without a
    script folder load the fresh templates from Ignite_Zeke unless UseLocalFiles is set.

    Requires a Skillable scoped deployment app with rights on the exercise RG, shared RG
    and Service Groups, and Graph rights for the temporary-secret/user-lookup workflow.
    The lab user receives Service Group Administrator. Ex4 also grants its AHM identity
    Service Group Reader and Reader on the shared RG. A shared-RG Reader failure is
    reported after step2 has still been attempted.

    Ex3_Task3 accepts AdministratorPassword as a SecureString for the PostgreSQL server
    and lab VMs. In Skillable it defaults to the User1 password placeholder; outside the
    lab supply the parameter explicitly. No password is written to disk or printed.

    Ex4 uses Az PowerShell for account and token access; Azure CLI is not required.
    No readiness helpers, NoOp automation assets or post-deployment RO/Drill
    configuration are run. It does not start a drill or perform recovery actions.
#>
[CmdletBinding()]
param(
    [string] $TenantId = '@lab.CloudSubscription.TenantId',
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',
    [string] $LabInstanceId = '@lab.LabInstance.Id',
    [string] $UserUpn = '@lab.CloudPortalCredential(User1).Username',
    [string] $ScopedAppId = '@lab.Variable(SGDeployAppId)',
    [string] $ScopedAppObjectId = '@lab.Variable(SGDeployAppObjectId)',
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex4_Task1',
    [string] $SharedResourceGroupName = 'CaldovaPayApp_Ex3_Task3',
    [string] $Location = 'southcentralus',
    [string[]] $Regions = @('southcentralus','centralus','eastus2'),
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/Ignite_Zeke/Ex4_Task1_withServiceGroupAndGoalAndAHMAndZonalROAndDrills_UserViewsAndRunsRO',
    [securestring] $AdministratorPassword,
    [switch] $UseLocalFiles
)
$ErrorActionPreference = 'Stop'
$TaskName = 'Ex4_Task1'
$OwnsInfrastructure = $false
$HasGoal = $true
$HasHealthModel = $true
$PreferredLocationWasSpecified = $PSBoundParameters.ContainsKey('Location')
$AllocationErrors = 'OverconstrainedZonalAllocationRequest|OverconstrainedAllocationRequest|ZonalAllocationFailed|AllocationFailed|SkuNotAvailable'
$ServiceGroupName = "CaldovaPayApp_${TaskName}_SG_$LabInstanceId"
$ServiceGroupScope = "/providers/Microsoft.Management/serviceGroups/$ServiceGroupName"
$HealthModelName = 'ahm-ex4-task1'
$RecoveryPlanName = 'zonal-recovery-plan'
$DrillName = 'zonal-drill-01'
$GuidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

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

function Test-ExistingGoal {
    param([hashtable] $Parameters)
    $path = "$ServiceGroupScope/providers/Microsoft.AzureResilienceManagement/goalAssignments?api-version=2026-08-31-preview"
    $response = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
    if ($response.StatusCode -ne 200) { throw "Goal lookup returned HTTP $($response.StatusCode)." }
    $goals = $response.Content | ConvertFrom-Json -ErrorAction Stop
    if (-not $goals.PSObject.Properties['value'] -or $goals.value -isnot [array] -or $goals.nextLink) {
        throw 'Goal lookup was incomplete; refusing to overwrite an existing goal.'
    }
    $existing = @($goals.value)
    if ($existing.Count -gt 1 -or ($existing.Count -eq 1 -and $existing[0].name -ne 'zonal-ha-assign')) {
        throw 'Existing goal assignments do not match zonal-ha-assign.'
    }
    if ($existing.Count -and ($existing[0].properties.provisioningState -ne 'Succeeded' -or
            $existing[0].properties.requireZonalResiliency -isnot [bool] -or
            $existing[0].properties.requireZonalResiliency -ne $true)) {
        throw 'The existing goal is not a successful zonal goal; resolve it before retrying.'
    }
    $Parameters['deployGoalAssignment'] = $existing.Count -eq 0
}

function Invoke-Deployment {
    param([string] $Prefix, [string] $Template, [hashtable] $Parameters,
        [int] $MaxAttempts = 3, [int] $RetryDelaySeconds = 180, [switch] $StopOnAllocationError)
    $localPath = $null
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $localPath = Join-Path $PSScriptRoot $Template
    }
    $arguments = @{ ResourceGroupName = $ResourceGroupName; TemplateParameterObject = $Parameters; ErrorAction = 'Stop' }
    if ($localPath -and (Test-Path -LiteralPath $localPath)) {
        $arguments.TemplateFile = $localPath
    } elseif ($UseLocalFiles) {
        throw "Required local template is missing: $Template. Run the .ps1 from its template folder, or omit -UseLocalFiles to use GitHub."
    } else {
        $arguments.TemplateUri = "$($TemplateBaseUri.TrimEnd('/'))/$Template"
    }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $arguments.Name = "$TaskName-$Prefix-$(Get-Date -Format yyyyMMddHHmmss)"
        try {
            if ($Prefix -eq 'step2' -and $HasGoal) { Test-ExistingGoal $Parameters }
            $deployment = New-AzResourceGroupDeployment @arguments
            if ($deployment.ProvisioningState -ne 'Succeeded') {
                throw "Deployment ended in state '$($deployment.ProvisioningState)'."
            }
            return $deployment
        } catch {
            $failure = $_.Exception.Message
            if ($Prefix -eq 'step1' -and $OwnsInfrastructure) {
                $operations = @(Get-AzResourceGroupDeploymentOperation -ResourceGroupName $ResourceGroupName `
                    -DeploymentName $arguments.Name -ErrorAction SilentlyContinue |
                    Where-Object ProvisioningState -eq 'Failed' |
                    ForEach-Object { "$($_.TargetResource): $($_.StatusMessage)" })
                $failure += " $($operations -join ' | ')"
            }
            if (($StopOnAllocationError -and $failure -match $AllocationErrors) -or $attempt -ge $MaxAttempts) {
                throw $failure
            }
            Write-Warning "$TaskName $Prefix attempt $attempt failed: $failure"
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Invoke-SharedSetupWithRegionFallback {
    param([hashtable] $Parameters)
    if (-not $OwnsInfrastructure) { throw 'Only Ex3_Task3 can provision shared infrastructure.' }
    if (-not $Regions.Count -or @($Regions | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
        throw 'Supply at least one valid fallback region.'
    }
    $start = [int]([int64]$LabInstanceId % $Regions.Count)
    $orderedRegions = @(0..($Regions.Count - 1) | ForEach-Object { $Regions[($start + $_) % $Regions.Count] })
    if ($PreferredLocationWasSpecified) {
        $orderedRegions = @($Location) + @($orderedRegions | Where-Object { $_ -ne $Location })
    }
    if ($deploymentGroup) { $orderedRegions = @($deploymentGroup.Location) }
    $provisioningId = [guid]::NewGuid().ToString()
    $createdThisRun = $false
    foreach ($region in $orderedRegions) {
        if ($createdThisRun) {
            $current = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
            if ($current.Tags.IgniteZekeProvisioningId -ne $provisioningId) {
                throw 'Refusing to delete a shared RG not owned by this provisioning attempt.'
            }
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    Remove-AzResourceGroup -Name $ResourceGroupName -Force -ErrorAction Stop | Out-Null
                    break
                } catch {
                    if ($attempt -ge 3) { throw }
                    Start-Sleep -Seconds 30
                }
            }
            $createdThisRun = $false
        }
        if (-not $deploymentGroup) {
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    New-AzResourceGroup -Name $ResourceGroupName -Location $region `
                        -Tag @{ IgniteZekeProvisioningId = $provisioningId; IgniteZekeInfrastructureState = 'Provisioning' } `
                        -ErrorAction Stop | Out-Null
                    $createdThisRun = $true
                    break
                } catch {
                    if ($attempt -ge 3) { throw }
                    Start-Sleep -Seconds 30
                }
            }
        }
        $Parameters.location = $region
        try {
            return Invoke-Deployment -Prefix 'step1' -Template "${TaskName}_Setup.json" -Parameters $Parameters `
                -MaxAttempts 2 -RetryDelaySeconds 120 -StopOnAllocationError
        } catch {
            $lastFailure = $_.Exception.Message
            Write-Warning "Shared setup in $region failed: $lastFailure"
        }
    }
    if ($deploymentGroup) {
        throw "Shared setup failed in existing RG '$ResourceGroupName'; it was not deleted or moved. $lastFailure"
    }
    throw "Shared setup failed across $($orderedRegions -join ', '): $lastFailure"
}

function Grant-ScopedRole {
    param([string] $PrincipalId, [string] $RoleId, [ValidateSet('User','ServicePrincipal')][string] $PrincipalType,
        [string] $Scope = $ServiceGroupScope)
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
    } } | ConvertTo-Json -Depth 3
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $response = Invoke-AzRestMethod -Method PUT -Payload $body -ErrorAction Stop `
                -Path "$Scope/providers/Microsoft.Authorization/roleAssignments/${assignment}?api-version=2022-04-01"
            if ($response.StatusCode -in 200,201 -or $response.Content -match 'RoleAssignmentExists') { return }
            throw "Role assignment returned HTTP $($response.StatusCode): $($response.Content)"
        } catch {
            if ("$($_.ErrorDetails.Message) $($_.Exception.Message)" -match 'RoleAssignmentExists') { return }
            if ($attempt -ge 6) { throw }
            Start-Sleep -Seconds 30
        }
    }
}

foreach ($value in @($TenantId, $SubscriptionId, $ScopedAppId, $ScopedAppObjectId)) {
    if ($value -notmatch $GuidPattern) {
        throw "Resolve the Skillable tenant/subscription/scoped-app placeholders or supply explicit parameters. Check 'Create Scoped Deploy SP'."
    }
}
if ($OwnsInfrastructure) { $SharedResourceGroupName = $ResourceGroupName }
if ($LabInstanceId -notmatch '^[a-zA-Z0-9_-]+$' -or
        [string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($SharedResourceGroupName)) {
    throw 'Supply a valid lab instance ID, deployment RG name and shared resource RG name.'
}
if (-not $OwnsInfrastructure -and $ResourceGroupName -eq $SharedResourceGroupName) {
    throw 'Use a separate deployment RG; only Ex3_Task3 may deploy into the shared infrastructure RG.'
}
if ($OwnsInfrastructure -and $LabInstanceId -notmatch '^[0-9]+$') {
    throw 'Ex3_Task3 regional rotation requires a numeric Skillable lab instance ID.'
}
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
if ($HasHealthModel) {
    $account = Get-AzContext -ErrorAction Stop
    if (!$account.Account -or $account.Tenant.Id -ne $TenantId -or $account.Subscription.Id -ne $SubscriptionId) {
        throw 'Az PowerShell must be signed in to the workload tenant and subscription.'
    }
}
try {
    $deploymentGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
} catch {
    $details = "$($_.FullyQualifiedErrorId) $($_.ErrorDetails.Message) $($_.Exception.Message)"
    if ($_.Exception.Response.StatusCode -ne 404 -and
            $details -notmatch 'ResourceGroupNotFound|Provided resource group does not exist\.') { throw }
    $deploymentGroup = $null
}

$userId = (Invoke-RestMethod -Headers (Get-GraphHeader) `
    -Uri "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($UserUpn))?`$select=id" -ErrorAction Stop).id
if ($userId -notmatch $GuidPattern) { throw "Lab user '$UserUpn' was not found in Entra ID." }
$sgAdminRole = Get-BuiltInRoleId -RoleName 'Service Group Administrator'
$sgReaderRole = if ($HasHealthModel) { Get-BuiltInRoleId -RoleName 'Service Group Reader' } else { $null }

$session = $null
try {
    $session = Connect-ScopedSP -SecretLifetimeMinutes 90
    if ($OwnsInfrastructure) {
        if (-not $AdministratorPassword) {
            $labPassword = @'
@lab.CloudPortalCredential(User1).Password
'@
            if ($labPassword.StartsWith('@lab.')) {
                throw 'Supply -AdministratorPassword as a SecureString outside Skillable.'
            }
            $AdministratorPassword = ConvertTo-SecureString $labPassword -AsPlainText -Force
            $labPassword = $null
        }
        if ($deploymentGroup) {
            Update-AzTag -ResourceId "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" `
                -Operation Merge -Tag @{ IgniteZekeInfrastructureState = 'Provisioning' } -ErrorAction Stop | Out-Null
        }
    } else {
        if ($deploymentGroup) {
            $Location = $deploymentGroup.Location
        } else {
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
                    break
                } catch {
                    if ($attempt -ge 3) { throw }
                    Start-Sleep -Seconds 30
                }
            }
        }
    }
    $setupParameters = @{ serviceGroupName = $ServiceGroupName; location = $Location }
    if ($OwnsInfrastructure) { $setupParameters.administratorPassword = $AdministratorPassword }
    else { $setupParameters.sharedResourceGroupName = $SharedResourceGroupName }
    if ($HasHealthModel) { $setupParameters.healthModelName = $HealthModelName }
    Start-Sleep -Seconds 60
    $null = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
    $setup = if ($OwnsInfrastructure) {
        Invoke-SharedSetupWithRegionFallback -Parameters $setupParameters
    } else {
        Invoke-Deployment -Prefix 'step1' -Template "${TaskName}_Setup.json" -Parameters $setupParameters
    }
    if ($setup.Outputs.serviceGroupId.Value -ne $ServiceGroupScope) { throw 'Unexpected Service Group output from setup.' }

    $memberTypes = [ordered]@{
        vnetId = 'Microsoft.Network/virtualNetworks'
        publicIpId = 'Microsoft.Network/publicIPAddresses'
        loadBalancerId = 'Microsoft.Network/loadBalancers'
        webVm1Id = 'Microsoft.Compute/virtualMachines'
        webVm2Id = 'Microsoft.Compute/virtualMachines'
        appVm1Id = 'Microsoft.Compute/virtualMachines'
        appVm2Id = 'Microsoft.Compute/virtualMachines'
        postgresId = 'Microsoft.DBforPostgreSQL/flexibleServers'
        storageId = 'Microsoft.Storage/storageAccounts'
    }
    $step2Parameters = @{ serviceGroupName = $ServiceGroupName }
    $expectedScope = "/subscriptions/$SubscriptionId/resourceGroups/$SharedResourceGroupName/providers/"
    foreach ($name in $memberTypes.Keys) {
        $id = [string]$setup.Outputs.$name.Value
        $prefix = "$expectedScope$($memberTypes[$name])/"
        if (-not $id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $id.Substring($prefix.Length) -match '[/\s?#\\]' -or $id.Length -le $prefix.Length) {
            throw "Invalid shared member output '$name'; refusing to attach resources outside the shared RG."
        }
        $step2Parameters[$name] = $id
    }
    if ($OwnsInfrastructure) {
        Update-AzTag -ResourceId "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" `
            -Operation Merge -Tag @{ IgniteZekeInfrastructureState = 'Succeeded' } -ErrorAction Stop | Out-Null
    }
    Start-Sleep -Seconds 120
    $null = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
    Grant-ScopedRole -PrincipalId $userId -RoleId $sgAdminRole -PrincipalType User
    $sourceReaderError = $null
    if ($HasHealthModel) {
        Grant-ScopedRole -PrincipalId $setup.Outputs.healthModelPrincipalId.Value -RoleId $sgReaderRole -PrincipalType ServicePrincipal
        try {
            Grant-ScopedRole -PrincipalId $setup.Outputs.healthModelPrincipalId.Value `
                -RoleId 'acdd72a7-3385-48ef-bd42-f606fba81ae7' -PrincipalType ServicePrincipal `
                -Scope "/subscriptions/$SubscriptionId/resourceGroups/$SharedResourceGroupName"
        } catch {
            $sourceReaderError = "AHM Reader assignment on shared RG failed: $($_.Exception.Message)"
            Write-Warning "$sourceReaderError. Continuing with step2 resource creation."
        }
        $step2Parameters.healthModelName = $HealthModelName
        $step2Parameters.zonalRecoveryPlanName = $RecoveryPlanName
        $step2Parameters.zonalDrillName = $DrillName
    }
    $step2Error = $null
    try {
        $extensions = Invoke-Deployment -Prefix 'step2' -Template "${TaskName}_MembershipsAndExtensions.json" -Parameters $step2Parameters
    } catch {
        if (-not $HasHealthModel) { throw }
        $step2Error = $_.Exception.Message
        Write-Warning "Ex4 step2 exhausted its retries; partial deployment resources were retained: $step2Error"
    }

    if ($step2Error -or $sourceReaderError) {
        $priorFailures = @(
            if ($sourceReaderError) { $sourceReaderError }
            if ($step2Error) { "Step2 failed after all retries: $step2Error" }
        ) -join '. '
        throw "$priorFailures. Partial deployment resources were retained; no RO/Drill configuration was run."
    }
    Write-Host "$TaskName complete. Service Group: $ServiceGroupScope" -ForegroundColor Green
    Write-Host 'Creation only: RO/Drill configuration and readiness checks were not run.'
    Write-Host "Deployment RG: $ResourceGroupName. Shared resources: $SharedResourceGroupName. Existing shared resource groups are never deleted."
    if (-not $HasGoal) { Write-Host 'Next: create the zonal and regional goals manually for this Service Group.' }
} finally {
    Disconnect-ScopedSP $session
}
