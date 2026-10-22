$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.psm1') -Force -DisableNameChecking

function Assert-PostArmId {
    param([string]$Id, [string]$Pattern, [string]$Description)
    if (!$Id -or $Id -match '[\s?#\\]|(?:^|/)\.{1,2}(?:/|$)' -or $Id -notmatch $Pattern) { throw "Invalid $Description ARM ID: $Id" }
}

function Select-PostScenarioResource {
    param([object[]]$Resources, [string]$Id, [string]$Mode, [string]$TypeProperty, [string]$Description)
    $matching = @($Resources | Where-Object { (Get-DemoValue $_ "properties.$TypeProperty") -eq $Mode })
    if ($Id) {
        $matching = @($matching | Where-Object { $_.id -eq $Id.TrimEnd('/') })
        if ($matching.Count -ne 1) { throw "$Description must be an existing $Mode resource under the supplied SG." }
    } elseif ($matching.Count -ne 1) {
        throw "Expected exactly one $Mode $Description under the SG; found $($matching.Count). Supply its explicit ARM ID if ambiguous."
    }
    if ((Get-DemoValue $matching[0] 'properties.provisioningState') -ne 'Succeeded') {
        throw "$Description creation has not succeeded. Finish deployment before running post-deployment operations."
    }
    return $matching[0]
}

function Get-PostMemberIds {
    param($Context)
    $sg = $Context.State.serviceGroupId.Replace("'", "''")
    $children = Invoke-DemoArg $Context "resourcecontainers | where type =~ 'microsoft.management/servicegroups' | where properties.parent.resourceId =~ '$sg' | project id"
    if ($children.count -gt 0) { throw 'These template-specific scripts require direct resource membership, not a hierarchy of child SGs.' }
    $query = "relationshipresources | where type =~ 'microsoft.relationships/servicegroupmember' | where tostring(coalesce(properties.TargetId, properties.targetId)) =~ '$sg' | project id"
    $result = Invoke-DemoArg $Context $query
    if ($result.'$skipToken' -or $result.resultTruncated -eq 'true') { throw 'SG membership query was truncated; refusing a partial resource set.' }
    $ids = @($result.data | ForEach-Object {
        $suffix = '/providers/Microsoft.Relationships/serviceGroupMember/'
        $index = $_.id.LastIndexOf($suffix, [StringComparison]::OrdinalIgnoreCase)
        if ($index -lt 1) { throw 'SG membership returned an unexpected relationship ID.' }
        $id = $_.id.Substring(0, $index)
        Assert-PostArmId $id '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/[^/]+/.+$' 'direct member resource'
        $id
    } | Sort-Object -Unique)
    if (!$ids.Count) { throw 'No direct SG members are visible in ARG yet. Check access and indexing, then retry.' }
    $subscriptions = @($ids | ForEach-Object { ($_ -split '/')[2] } | Sort-Object -Unique)
    if ($subscriptions.Count -ne 1) { throw 'SG members span subscriptions. These scripts require the single-subscription template layout.' }
    return ,$ids
}

function Get-PostMemberMetadata {
    param($Context, [string[]]$Ids)
    $result = @()
    for ($i=0; $i -lt $Ids.Count; $i+=25) {
        $batch = $Ids[$i..([Math]::Min($i+24, $Ids.Count-1))]
        $literals = @($batch | ForEach-Object { "'$($_.Replace("'","''"))'" }) -join ','
        $response = Invoke-DemoArg $Context "resources | where id in~ ($literals) | project id, name, type, location, resourceGroup, subscriptionId"
        $result += @($response.data)
    }
    if (@($result.id | Sort-Object -Unique).Count -ne $Ids.Count -or @($Ids | Where-Object { $_ -notin $result.id }).Count) {
        throw 'Some SG members are not visible in ARG. No partial setup will be performed.'
    }
    return ,$result
}

function Assert-PostResourceSet {
    param([object[]]$Resources, [string[]]$Expected, [string]$Description)
    $ids = @($Resources | ForEach-Object { $_.properties.resourceId })
    if ($ids.Count -ne @($ids | Sort-Object -Unique).Count -or
        @($Expected | Where-Object { $_ -notin $ids }).Count -or @($ids | Where-Object { $_ -notin $Expected }).Count) {
        throw "$Description discovery does not match the SG membership. Resolve missing, stale or excluded-by-discovery members before continuing."
    }
}

function New-PostDeploymentContext {
    param(
        [ValidateSet('Regional','Zonal')][string]$Mode, [string]$ServiceGroupId, [string]$RecoveryPlanId,
        [string]$DrillId, [string]$RunbookId, [string]$AutomationResourceGroupId, [string]$AutomationLocation,
        [Nullable[int]]$FaultDurationInMinutes, [string]$StatePath, [string]$RhubArmEndpoint, [int]$TimeoutMinutes
    )
    $ServiceGroupId = $ServiceGroupId.TrimEnd('/')
    Assert-PostArmId $ServiceGroupId '^/providers/Microsoft\.Management/serviceGroups/[^/]+$' 'service group'
    $endpoint = [uri]$RhubArmEndpoint
    if ($endpoint.Scheme -ne 'https' -or !$endpoint.IsDefaultPort -or $endpoint.UserInfo -or $endpoint.Query -or
        $endpoint.Fragment -or $endpoint.AbsolutePath -ne '/' -or
        ($endpoint.Host -ne 'management.azure.com' -and $endpoint.Host -notlike '*.management.azure.com')) { throw 'Invalid RHub ARM endpoint.' }
    $accountJson = & az account show --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw 'Sign in with Azure CLI to the tenant containing the SG.' }
    $account = ($accountJson -join "`n") | ConvertFrom-Json -AsHashtable
    $demoId = Get-DemoGuid "ignite-post-deployment|$ServiceGroupId"
    if (!$StatePath) { $StatePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "DrillPostDeployment\$demoId\$Mode.json" }
    $StatePath = [IO.Path]::GetFullPath($StatePath)
    $stateHash = if (Test-Path -LiteralPath $StatePath) { (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash } else { $null }
    $state = if ($stateHash) { Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable } else {
        @{postDeploymentSchemaVersion=1; mode=$Mode; demoId=$demoId; serviceGroupId=$ServiceGroupId
          inputs=@{rhubArmEndpoint=$RhubArmEndpoint.TrimEnd('/')}; resources=@(); operations=@(); status='Planned'}
    }
    if ($state.postDeploymentSchemaVersion -ne 1 -or $state.mode -ne $Mode -or $state.serviceGroupId -ne $ServiceGroupId -or
        $state.inputs.rhubArmEndpoint -ne $RhubArmEndpoint.TrimEnd('/')) { throw 'State belongs to another workflow, SG or endpoint.' }
    $ctx = @{Mode=$Mode; State=$state; StatePath=$StatePath; InitialStateHash=$stateHash; ScriptRoot=$PSScriptRoot
        SubscriptionId=$account.id; RhubEndpoint=$RhubArmEndpoint.TrimEnd('/'); Tokens=@{}; Secrets=@()
        TimeoutMinutes=$TimeoutMinutes; ReadinessTimeoutMinutes=$TimeoutMinutes; Roles=(Get-DemoRoles)}
    $null = Invoke-DemoArm $ctx -Path $ServiceGroupId -ApiVersion '2024-02-01-preview'
    $members = Get-PostMemberIds $ctx
    $ctx.SubscriptionId = ($members[0] -split '/')[2]
    $ctx.Tokens.Clear()
    $null = Get-DemoToken $ctx
    if ($state.memberIds -and @(Compare-Object @($state.memberIds) $members).Count) { throw 'SG membership changed since this workflow began. Review before resuming.' }
    $state.memberIds = $members
    $state.inputs.subscriptionId = $ctx.SubscriptionId
    $ctx.Members = Get-PostMemberMetadata $ctx $members
    $plans = @(Get-DemoList $ctx "$ServiceGroupId/providers/Microsoft.AzureResilienceManagement/recoveryPlans" '2026-06-01-preview')
    $ctx.Plan = Select-PostScenarioResource $plans $RecoveryPlanId $Mode 'planType' 'Recovery Plan'
    if ($state.planId -and $state.planId -ne $ctx.Plan.id) { throw 'Selected Recovery Plan differs from the saved workflow.' }
    $state.planId = $ctx.Plan.id
    if (!$ctx.Plan.identity.principalId) { throw 'The existing Recovery Plan must have its system-assigned identity provisioned.' }
    $groups = @($ctx.Plan.properties.recoveryGroupsSetting.defaultGroup) + @($ctx.Plan.properties.recoveryGroupsSetting.additionalGroups | Where-Object { $_ })
    if (!$groups[0].properties.groupUniqueId) { throw 'The existing RO plan must contain its default recovery group.' }
    if ($Mode -eq 'Regional' -and @($groups | Where-Object { $_.properties.preActions -or $_.properties.postActions }).Count) {
        throw 'Regional execution refuses recovery-group pre/post actions: only the verified NoOp resource actions may execute.'
    }
    $ctx.DefaultGroupId = $groups[0].properties.groupUniqueId
    $ctx.RecoveryResources = @(Get-DemoList $ctx "$($ctx.Plan.id)/recoveryResources" '2026-06-01-preview')
    Assert-PostResourceSet $ctx.RecoveryResources $members 'RO'
    if ($Mode -eq 'Zonal') {
        $drills = @(Get-DemoList $ctx "$ServiceGroupId/providers/Microsoft.AzureResilienceManagement/drills" '2026-09-30-preview')
        $ctx.Drill = Select-PostScenarioResource $drills $DrillId 'Zonal' 'drillType' 'Drill'
        if ($state.drillId -and $state.drillId -ne $ctx.Drill.id) { throw 'Selected Drill differs from the saved workflow.' }
        $state.drillId = $ctx.Drill.id
        $linkedPlan = $ctx.Drill.properties.recoveryPlanProperties.recoveryPlanId
        if ($linkedPlan -and $linkedPlan -ne $ctx.Plan.id) { throw 'The existing zonal Drill references a different Recovery Plan.' }
        if (!$linkedPlan -and @($plans | Where-Object { $_.properties.planType -eq 'Zonal' }).Count -gt 1) {
            throw 'The Drill has no unambiguous association with the selected zonal RO plan. Finish that prerequisite first.'
        }
        if ($ctx.Drill.properties.executionState -ne 'NotRunning') { throw 'The zonal Drill must be NotRunning; this script never stops or changes a running Drill.' }
        if ($ctx.Drill.properties.attentionReason.monitoringSourceNotConfigured -eq $true) { throw 'The existing Drill is missing monitoring configuration. Complete that prerequisite outside this script.' }
        $duration = if ($null -ne $FaultDurationInMinutes) { [int]$FaultDurationInMinutes } elseif ($ctx.Drill.properties.chaosResourceProperties.faultDurationInMin) {
            [int]$ctx.Drill.properties.chaosResourceProperties.faultDurationInMin
        } else { 5 }
        if ($duration -lt 1) { throw 'FaultDurationInMinutes must be positive.' }
        if ($state.inputs.faultDurationInMinutes -and $state.inputs.faultDurationInMinutes -ne $duration) { throw 'Fault duration differs from the saved workflow.' }
        $state.inputs.faultDurationInMinutes = $duration
    }
    $groupIds = @($members | ForEach-Object { ($_ -split '/')[0..4] -join '/' } | Sort-Object -Unique)
    if ($AutomationResourceGroupId) {
        $AutomationResourceGroupId = $AutomationResourceGroupId.TrimEnd('/')
        if ($AutomationResourceGroupId -notin $groupIds) { throw 'AutomationResourceGroupId must be an existing RG containing an SG member.' }
        $groupIds = @($AutomationResourceGroupId)
    } elseif ($state.automationGroupId) { $groupIds = @($state.automationGroupId) }
    foreach ($groupId in $groupIds) {
        $group = Invoke-DemoArm $ctx -Path $groupId -ApiVersion '2024-03-01'
        if ($group.managedBy) { continue }
        $locks = @(Get-DemoList $ctx "$groupId/providers/Microsoft.Authorization/locks" '2016-09-01')
        if ($locks.Count) { continue }
        $ctx.AutomationGroup = $group
        break
    }
    if (!$ctx.AutomationGroup) { throw 'No non-managed, unlocked member RG is available for the NoOp Automation account.' }
    $state.automationGroupId = $ctx.AutomationGroup.id
    $location = if ($AutomationLocation) { ConvertTo-DemoLocation $AutomationLocation } else { ConvertTo-DemoLocation $ctx.AutomationGroup.location }
    if ($state.automationLocation -and $state.automationLocation -ne $location) { throw 'Automation location differs from saved state.' }
    $state.automationLocation = $location
    $ctx.Tags = @{DrillDemoId=$demoId; Purpose='IgnitePostDeploymentNoOp'}
    if ($ctx.AutomationGroup.tags) {
        foreach ($key in $ctx.AutomationGroup.tags.Keys) { if ($key -notin @('DrillDemoId','Purpose')) { $ctx.Tags[$key]=$ctx.AutomationGroup.tags[$key] } }
    }
    $accountName = "ignite-post-$(($demoId -replace '-','').Substring(0,12))"
    $ctx.AutomationId = "$($ctx.AutomationGroup.id)/providers/Microsoft.Automation/automationAccounts/$accountName"
    $ctx.RunbookId = if ($RunbookId) { $RunbookId.TrimEnd('/') } elseif ($state.runbookId) { $state.runbookId } else { "$($ctx.AutomationId)/runbooks/Ignite-NoOp" }
    Assert-PostArmId $ctx.RunbookId "^/subscriptions/$($ctx.SubscriptionId)/resourceGroups/[^/]+/providers/Microsoft\.Automation/automationAccounts/[^/]+/runbooks/[^/]+$" 'NoOp runbook'
    if ($state.runbookId -and $state.runbookId -ne $ctx.RunbookId) { throw 'Runbook differs from saved workflow.' }
    $ctx.CreateRunbook = !$RunbookId -and !($state.reusedRunbook -eq $true)
    if (!$ctx.CreateRunbook) {
        $ctx.AutomationId=$ctx.RunbookId.Substring(0,$ctx.RunbookId.LastIndexOf('/runbooks/',[StringComparison]::OrdinalIgnoreCase))
        $ctx.AutomationGroup=Invoke-DemoArm $ctx -Path (($ctx.RunbookId -split '/')[0..4] -join '/') -ApiVersion '2024-03-01'
        $state.automationGroupId=$ctx.AutomationGroup.id
        Assert-PostNoOpContent $ctx
    } else {
        $provider=Invoke-DemoArm $ctx -Path "/subscriptions/$($ctx.SubscriptionId)/providers/Microsoft.Automation" -ApiVersion '2021-04-01'
        $accountType=@($provider.resourceTypes | Where-Object resourceType -eq 'automationAccounts')
        $locations=@($accountType.locations | ForEach-Object { ConvertTo-DemoLocation $_ })
        if ($provider.registrationState -ne 'Registered' -or $location -notin $locations) {
            throw "Automation accounts are not available in $location for this subscription. Register the provider or supply a supported AutomationLocation."
        }
    }
    $state.runbookId = $ctx.RunbookId
    $state.reusedRunbook = !$ctx.CreateRunbook
    $ctx.RecoveryDecisions = @(Get-PostRecoveryDecisions $ctx.RecoveryResources $ctx.RunbookId)
    Assert-PostNoActiveJobs $ctx
    return $ctx
}

function Get-PostRecoveryDecisions {
    param([object[]]$Resources, [string]$RunbookId)
    foreach ($resource in $Resources) {
        $decision = Get-DemoProtectionDecision $resource $false
        if ($decision -eq 'Unknown') { throw "Unknown or conflicting protection posture: $($resource.properties.resourceId). No forced inclusion is permitted." }
        if ($decision -eq 'IncludeCustom' -and $resource.properties.selectedProtectionSolutionType -eq 'CustomRunbook') {
            foreach ($name in @('failoverAction','failoverCommitAction','reprotectAction')) {
                $existing = Get-DemoValue $resource "properties.selectedProtectionSolutionSetting.$name.resourceId"
                if ($existing -and $existing -ne $RunbookId) { throw "Existing custom recovery configuration differs for $($resource.properties.resourceId); refusing to overwrite it." }
            }
        }
        @{id=$resource.id;resourceId=$resource.properties.resourceId;decision=$decision}
    }
}

function Assert-PostNoActiveJobs {
    param($Context)
    $ownJobs = @($Context.State.operations | Where-Object { $_.jobId } | ForEach-Object { $_.jobId })
    $jobs = @(Get-DemoList $Context "$($Context.Plan.id)/recoveryJobs" '2026-06-01-preview')
    foreach ($job in $jobs) {
        if ($job.properties.status -notin @('Completed','Failed','Canceled','Cancelled','CompletedWithWarnings') -and $job.id -notin $ownJobs) {
            throw "An unrelated/nonterminal recovery job exists: $($job.id). Resolve it before changing the plan."
        }
    }
}

function Show-PostDeploymentPlan {
    param($Context)
    Write-Host "Scenario: $($Context.Mode); SG: $($Context.State.serviceGroupId)"
    Write-Host "Subscription: $($Context.SubscriptionId); existing RO: $($Context.Plan.id)"
    if ($Context.Drill) { Write-Host "Existing zonal Drill: $($Context.Drill.id); it will NOT be started." }
    Write-Host "Automation RG: $($Context.AutomationGroup.id); location: $($Context.State.automationLocation)"
    Write-Host "Automation account: $($Context.AutomationId); NoOp runbook: $($Context.RunbookId)"
    Write-Host "NoOp assets: $(if ($Context.CreateRunbook) { 'create/reuse this script-owned account and runbook' } else { 'verify the supplied published NoOp' })"
    Write-Host "Members: $($Context.State.memberIds.Count); native-HA exclusions: $(@($Context.RecoveryDecisions | Where-Object decision -eq 'ExcludeNativeHA').Count)"
    Write-Host "State: $($Context.StatePath)"
    Write-Warning 'NoOp recovery simulates orchestration only; its timing is not real application RPO/RTO.'
    if ($Context.Mode -eq 'Zonal') { Write-Warning 'Native faults will be selected where available. A later human-started Drill can disrupt resources.' }
}

function Assert-PostNoOpContent {
    param($Context)
    $runbook = Invoke-DemoArm $Context -Path $Context.RunbookId -ApiVersion '2023-11-01'
    if ($runbook.properties.state -ne 'Published') { throw 'The NoOp runbook is not published.' }
    $actual = Invoke-DemoArm $Context -Path "$($Context.RunbookId)/content" -ApiVersion '2023-11-01'
    if ($actual -is [byte[]]) { $actual=[Text.UTF8Encoding]::new($false,$true).GetString($actual) }
    $expected = [IO.File]::ReadAllText((Join-Path $Context.ScriptRoot 'NoOp.ps1'))
    if ($actual -isnot [string] -or ($actual.TrimStart([char]0xfeff) -replace "`r`n","`n").Trim() -cne ($expected -replace "`r`n","`n").Trim()) {
        throw 'Runbook content differs from the bundled NoOp. Refusing to execute or associate potentially disruptive custom code.'
    }
}

function Grant-PostAutomationRole {
    param($Context, [string]$PrincipalId, [string]$RoleId)
    if (!$PrincipalId) { throw 'A required execution identity has not been provisioned.' }
    $assignments = @(Get-DemoList $Context "$($Context.AutomationId)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()")
    $existing = @($assignments | Where-Object {
        $_.properties.principalId -eq $PrincipalId -and $_.properties.roleDefinitionId -like "*/$RoleId" -and
        ($_.properties.scope -eq $Context.AutomationId -or $Context.AutomationId.StartsWith("$($_.properties.scope)/",[StringComparison]::OrdinalIgnoreCase))
    })
    if (!$existing.Count) { Grant-DemoRole $Context $PrincipalId $RoleId $Context.AutomationId }
}

function Initialize-PostNoOpAssets {
    param($Context)
    if ($Context.CreateRunbook) {
        $account = Invoke-DemoArm $Context -Path $Context.AutomationId -ApiVersion '2023-11-01' -AllowNotFound
        if ($account -and (Get-DemoValue $account 'tags.DrillDemoId') -ne $Context.State.demoId) { throw 'An unrelated Automation account occupies the generated name.' }
        if (!$account) {
            $null = Set-DemoOwnedResource $Context $Context.AutomationId '2023-11-01' @{
                location=$Context.State.automationLocation;properties=@{sku=@{name='Basic'};disableLocalAuth=$true}
            }
        } else { $null = Wait-DemoResource $Context $Context.AutomationId '2023-11-01' }
        $existing = Invoke-DemoArm $Context -Path $Context.RunbookId -ApiVersion '2023-11-01' -AllowNotFound
        if ($existing) {
            if ((Get-DemoValue $existing 'tags.DrillDemoId') -ne $Context.State.demoId) { throw 'An unrelated runbook occupies the NoOp name.' }
            if ($existing.properties.state -eq 'Published') { Assert-PostNoOpContent $Context }
        }
        if (!$existing -or $existing.properties.state -ne 'Published') {
            $null = Set-DemoOwnedResource $Context $Context.RunbookId '2023-11-01' @{
                location=$Context.State.automationLocation;properties=@{runbookType='PowerShell';logProgress=$false;logVerbose=$false
                    description='Ignite simulation only; does not modify Azure resources.';draft=@{}}
            }
            $source = [IO.File]::ReadAllText((Join-Path $Context.ScriptRoot 'NoOp.ps1'))
            $null = Invoke-DemoArm $Context -Method PUT -Path "$($Context.RunbookId)/draft/content" -ApiVersion '2023-11-01' -ContentType 'text/powershell' -Body $source
            $null = Invoke-DemoArm $Context -Method POST -Path "$($Context.RunbookId)/publish" -ApiVersion '2023-11-01'
        }
    }
    Assert-PostNoOpContent $Context
    foreach ($role in @($Context.Roles.Reader,$Context.Roles.AutomationJobOperator)) {
        Grant-PostAutomationRole $Context $Context.Plan.identity.principalId $role
    }
}

function Assert-PostActionAllowed {
    param($Context, [string]$TargetId, [string]$Action)
    $setup = @('updateResources','finalize','checkReadiness')
    $regional = @('failover','failoverCommit','reprotect','validateForFailover','validateForFailoverCommit','validateForReprotect')
    if ($TargetId -eq $Context.Plan.id -and ($Action -in $setup -or ($Context.Mode -eq 'Regional' -and $Action -in $regional))) { return }
    if ($Context.Mode -eq 'Zonal' -and $TargetId -eq $Context.Drill.id -and
        $Action -in @('addOrUpdateResources','resyncReadinessCheck')) { return }
    throw "Operation is not allowed in the $($Context.Mode) post-deployment workflow: $TargetId/$Action"
}

function Wait-PostRecoveryJob {
    param($Context, [string]$JobId)
    if (!$JobId.StartsWith("$($Context.Plan.id)/recoveryJobs/",[StringComparison]::OrdinalIgnoreCase)) { throw 'Returned recovery job belongs to a different plan.' }
    $deadline=[datetime]::UtcNow.AddMinutes($Context.TimeoutMinutes)
    do {
        $job=Invoke-DemoArm $Context -Path $JobId -ApiVersion '2026-06-01-preview' -AllowNotFound
        $status=Get-DemoValue $job 'properties.status'
        if ($status -eq 'Completed') { return $job }
        if ($status -in @('Failed','Canceled','Cancelled','CompletedWithWarnings','Paused','Suspended','WaitingForUserInput')) {
            throw "Recovery job is not successfully completed: $JobId; status=$status; error=$(ConvertTo-Json -InputObject $job.properties.errorDetails -Depth 15 -Compress)"
        }
        if ([datetime]::UtcNow -ge $deadline) { throw "Recovery job still pending: $JobId. Resume this state file; do not start another cycle." }
        Start-Sleep -Seconds 10
    } while ($true)
}

function Invoke-PostRecordedAction {
    param($Context, [string]$Key, [string]$TargetId, [string]$Action, $Body, [switch]$RecoveryJob)
    Assert-PostActionAllowed $Context $TargetId $Action
    $version = if ($TargetId -eq $Context.Plan.id) { '2026-06-01-preview' } else { '2026-09-30-preview' }
    $entry=@($Context.State.operations | Where-Object key -eq $Key)
    if ($entry.Count -gt 1) { throw "Duplicate journal entry: $Key" }
    if ($entry.Count) {
        $entry=$entry[0]
        if ($entry.targetId -ne $TargetId -or $entry.action -ne $Action) { throw "Saved operation differs: $Key" }
        if ($entry.status -eq 'Completed') { return }
        if (!$entry.jobId -and !$entry.serverResult -and $Context.State.lastError -like 'Operation failed: {*') {
            $reported=$Context.State.lastError.Substring('Operation failed: '.Length) | ConvertFrom-Json -AsHashtable
            $pattern='^/providers/Microsoft\.AzureResilienceManagement/locations/[^/]+/operationStatuses/[^/]+$'
            if ($reported.status -eq 'Failed' -and $reported.resourceId -eq $TargetId -and $reported.id -match $pattern -and
                $reported.startTime -and [datetimeoffset]$reported.startTime -ge [datetimeoffset]$entry.startedAtUtc -and
                [datetimeoffset]$reported.startTime -le ([datetimeoffset]$entry.startedAtUtc).AddMinutes(5)) {
                $confirmed=Invoke-DemoArm $Context -Path $reported.id -ApiVersion $version
                if ($confirmed.status -eq 'Failed' -and $confirmed.resourceId -eq $TargetId -and $confirmed.id -eq $reported.id) {
                    $entry.serverResult=$confirmed
                    $entry.status='Failed'
                    Save-DemoState $Context
                }
            }
        }
        if ($entry.status -eq 'Failed') { throw "Recorded $Key operation failed: $(ConvertTo-Json -InputObject $entry.serverResult.error -Depth 15 -Compress)" }
        if (!$entry.jobId) { throw "Outcome of $Key is unknown (operation $($entry.operationId)). Inspect the server operation before retrying; this script will not repeat it blindly." }
    } else {
        $entry=@{key=$Key;targetId=$TargetId;action=$Action;operationId=[guid]::NewGuid().ToString();status='Submitting';startedAtUtc=[datetime]::UtcNow.ToString('o')}
        $Context.State.operations += $entry
        Save-DemoState $Context
        Write-Host "POST $TargetId/$Action (operation $($entry.operationId))"
        $path="$TargetId/$Action`?api-version=$version&operationId=$($entry.operationId)"
        try {
            $result=Invoke-DemoArm $Context -Method POST -Path $path -Body $Body -OperationId $entry.operationId -OperationResult
        } catch {
            $operationResult=$_.Exception.Data['ArmOperationResult']
            if ($operationResult -and $operationResult.resourceId -eq $TargetId) {
                $entry.serverResult=$operationResult
                $entry.status='Failed'
                Save-DemoState $Context
            }
            throw
        }
        $result=ConvertFrom-DemoOperation $result
        if ($RecoveryJob) {
            $jobId=Get-DemoValue $result 'jobId'
            if (!$jobId) { throw "$Action did not return a recovery job ID; outcome must be inspected before retry." }
            if (!$jobId.StartsWith('/')) {
                $null=[guid]$jobId
                $jobId="$TargetId/recoveryJobs/$jobId"
            }
            $entry.jobId=$jobId
            $entry.status='WaitingForJob'
            Save-DemoState $Context
        }
    }
    if ($RecoveryJob) {
        $job=Wait-PostRecoveryJob $Context $entry.jobId
        $entry.jobStatus=$job.properties.status
    }
    $entry.status='Completed'
    $entry.completedAtUtc=[datetime]::UtcNow.ToString('o')
    Save-DemoState $Context
}

function Get-PostRecoveryUpdate {
    param($Context, [object[]]$Resources)
    $decisions=@(Get-PostRecoveryDecisions $Resources $Context.RunbookId)
    $updates=@(foreach ($resource in $Resources) {
        $decision=@($decisions | Where-Object id -eq $resource.id)[0]
        if (!$resource.properties.recoveryResourceUniqueId) { throw 'RO discovery omitted a recovery-resource unique ID.' }
        $properties=@{recoveryResourceUniqueId=$resource.properties.recoveryResourceUniqueId}
        if ($decision.decision -eq 'ExcludeNativeHA') {
            $properties.inclusionState='Excluded'
        } else {
            $properties.inclusionState='Included'
            $properties.recoveryGroupId=if ($resource.properties.recoveryGroupId) { $resource.properties.recoveryGroupId } else { $Context.DefaultGroupId }
            $properties.associatedIdentity=@{type='SystemAssigned'}
            $properties.selectedProtectionSolutionType='CustomRunbook'
            $properties.selectedProtectionSolutionSetting=@{protectionSolutionType='CustomRunbook'}
            foreach ($action in @('failoverAction','failoverCommitAction','reprotectAction')) {
                $properties.selectedProtectionSolutionSetting[$action]=@{resourceId=$Context.RunbookId}
            }
        }
        @{id=$resource.id;properties=$properties}
    })
    if (!@($decisions | Where-Object decision -eq 'IncludeCustom').Count) { throw 'No eligible non-HA resource exists for the RO scenario.' }
    return @{resourcesToUpdate=$updates;resourcesToRemove=@()}
}

function Assert-PostRecoveryConfiguration {
    param($Context, [switch]$RequireReady)
    $plan=Invoke-DemoArm $Context -Path $Context.Plan.id -ApiVersion '2026-06-01-preview'
    if ($plan.properties.planType -ne $Context.Mode) { throw 'RO plan type changed; workflow stopped.' }
    $groups = @($plan.properties.recoveryGroupsSetting.defaultGroup) + @($plan.properties.recoveryGroupsSetting.additionalGroups | Where-Object { $_ })
    if ($Context.Mode -eq 'Regional' -and @($groups | Where-Object { $_.properties.preActions -or $_.properties.postActions }).Count) {
        throw 'Recovery-group pre/post actions changed. Only the verified resource NoOps may execute.'
    }
    if ($RequireReady -and $plan.properties.planState -ne 'Ready') { throw "RO plan is not Ready: $($plan.properties.planState)" }
    $resources=@(Get-DemoList $Context "$($plan.id)/recoveryResources" '2026-06-01-preview')
    Assert-PostResourceSet $resources $Context.State.memberIds 'RO'
    $decisions=@(Get-PostRecoveryDecisions $resources $Context.RunbookId)
    foreach ($decision in $decisions) {
        $resource=@($resources | Where-Object id -eq $decision.id)[0]
        if ($decision.decision -eq 'ExcludeNativeHA') {
            if ($resource.properties.inclusionState -ne 'Excluded') { throw "Native-HA resource is not excluded: $($decision.resourceId)" }
        } else {
            if ($resource.properties.inclusionState -ne 'Included' -or $resource.properties.selectedProtectionSolutionType -ne 'CustomRunbook' -or
                $resource.properties.associatedIdentity.type -ne 'SystemAssigned') { throw "Expected NoOp protection is missing: $($decision.resourceId)" }
            foreach ($action in @('failoverAction','failoverCommitAction','reprotectAction')) {
                if ((Get-DemoValue $resource "properties.selectedProtectionSolutionSetting.$action.resourceId") -ne $Context.RunbookId) { throw "NoOp $action changed: $($decision.resourceId)" }
            }
        }
        if ($RequireReady -and $resource.properties.needsAttention) { throw "Recovery resource still needs attention: $($decision.resourceId)" }
    }
    $Context.RecoveryResources=$resources
    $Context.RecoveryDecisions=$decisions
}

function Initialize-PostRecoveryPlan {
    param($Context)
    $cycleStarted = $Context.Mode -eq 'Regional' -and @($Context.State.operations | Where-Object { $_.key -match '^(failover|failback)\.' }).Count -gt 0
    if ($cycleStarted) {
        if (!@($Context.State.operations | Where-Object { $_.key -eq 'ro.readiness' -and $_.status -eq 'Completed' }).Count) {
            throw 'Recovery-cycle journal has no completed initial readiness step.'
        }
        Assert-PostRecoveryConfiguration $Context
        return
    }
    $update=Get-PostRecoveryUpdate $Context $Context.RecoveryResources
    Invoke-PostRecordedAction $Context 'ro.configure' $Context.Plan.id 'updateResources' $update
    Invoke-PostRecordedAction $Context 'ro.finalize' $Context.Plan.id 'finalize' $null
    Invoke-PostRecordedAction $Context 'ro.readiness' $Context.Plan.id 'checkReadiness' $null -RecoveryJob
    Assert-PostRecoveryConfiguration $Context -RequireReady
}

function New-PostFailoverBody {
    param([object[]]$Resources)
    $included=@($Resources | Where-Object { $_.properties.inclusionState -eq 'Included' })
    if (!$included.Count) { throw 'No included recovery resources are available for failover.' }
    if (@($included | Where-Object { !$_.id }).Count) { throw 'An included recovery resource is missing its ARM ID.' }
    # The API accepts selected IDs without sourceLocations, avoiding logical/physical
    # zone formatting guesses when zonal resources belong to a Regional plan.
    return @{failoverDirection='FromSpecificLocations';failoverRequestProperties=@{selectedResourceIds=@($included.id)}}
}

function Assert-PostQualification {
    param($Context, [string]$Action, $Body, [string[]]$SelectedIds)
    Assert-PostActionAllowed $Context $Context.Plan.id $Action
    $operationId=[guid]::NewGuid().ToString()
    $path="$($Context.Plan.id)/$Action`?api-version=2026-06-01-preview&operationId=$operationId"
    $response=Invoke-DemoArm $Context -Method POST -Path $path -Body $Body -OperationId $operationId
    foreach ($id in $SelectedIds) {
        $qualification=@($response.recoveryResourceQualifications | Where-Object { $_.recoveryResource.id -eq $id })
        if ($qualification.Count -ne 1 -or $qualification[0].operationQualificationDetails.qualificationState -ne 'Qualified') {
            throw "$Action did not qualify $id : $(ConvertTo-Json -InputObject $qualification -Depth 20 -Compress)"
        }
    }
}

function Invoke-PostRegionalRoundTrip {
    param($Context)
    if ($Context.Mode -ne 'Regional') { throw 'Regional execution is forbidden in the zonal readiness workflow.' }
    foreach ($leg in @('failover','failback')) {
        foreach ($action in @('failover','failoverCommit','reprotect')) {
            $key="$leg.$action"
            if (@($Context.State.operations | Where-Object { $_.key -eq $key -and $_.status -eq 'Completed' }).Count) { continue }
            Assert-PostRecoveryConfiguration $Context
            Assert-PostNoOpContent $Context
            $included=@($Context.RecoveryResources | Where-Object { $_.properties.inclusionState -eq 'Included' })
            $body = switch ($action) {
                'failover' { New-PostFailoverBody $Context.RecoveryResources }
                'reprotect' { @{reprotectRequestProperties=@{selectedResourceIds=@($included.id)}} }
                default { $null }
            }
            $validation = switch ($action) {
                'failover' { 'validateForFailover' }
                'failoverCommit' { 'validateForFailoverCommit' }
                'reprotect' { 'validateForReprotect' }
            }
            if (!@($Context.State.operations | Where-Object key -eq $key).Count) { Assert-PostQualification $Context $validation $body @($included.id) }
            Invoke-PostRecordedAction $Context $key $Context.Plan.id $action $body -RecoveryJob
        }
    }
    Invoke-PostRecordedAction $Context 'regional.final-readiness' $Context.Plan.id 'checkReadiness' $null -RecoveryJob
    Assert-PostRecoveryConfiguration $Context -RequireReady
}

function Get-PostDrillUpdate {
    param([object[]]$Resources, [string]$RunbookId, [int]$Duration)
    $include=@();$update=@();$selections=@()
    foreach ($resource in $Resources) {
        $faults=$resource.properties.faultProperties
        $candidates=@($faults.defaultFault,$faults.overriddenDefaultFault) + @($faults.availableFaults)
        $native=@($candidates | Where-Object {
            $_ -and $_.faultUrn -and $_.faultUrn -ne 'urn:csci:microsoft:automation:startRunbook/1.0' -and
            $_.targetResourceId -notmatch '/Microsoft\.Automation/automationAccounts/'
        } | Select-Object -First 1)
        if ($native.Count) {
            $properties=@{defaultFault=$native[0];overriddenDefaultFault=$null;customFault=$null}
            $selections+=@{id=$resource.id;resourceId=$resource.properties.resourceId;kind='Native';faultUrn=$native[0].faultUrn;targetResourceId=$native[0].targetResourceId}
        } else {
            if ($faults.customFault.scriptResourceId -and $faults.customFault.scriptResourceId -ne $RunbookId) {
                throw "Existing custom fault differs for $($resource.properties.resourceId); refusing to replace it."
            }
            $properties=@{defaultFault=$null;overriddenDefaultFault=$null;customFault=@{faultName='Ignite-NoOp';scriptResourceId=$RunbookId}}
            $selections+=@{id=$resource.id;resourceId=$resource.properties.resourceId;kind='NoOp'}
        }
        $item=@{id=$resource.id;faultProperties=$properties}
        if ($resource.properties.inclusionState -eq 'Included') { $update+=$item } else { $include+=$item }
    }
    return @{body=@{faultDurationInMin=$Duration;forceInclusionAndUpdate='Disable';resourceLists=@{includeResources=$include;updateResources=$update;excludeResources=@()}};selections=$selections}
}

function Get-PostChaosPrincipal {
    param($Context, $Drill)
    $identity=$Drill.properties.chaosResourceProperties.identity
    if ($identity.type -eq 'UserAssigned') {
        $id=$identity.userAssignedIdentity
        Assert-PostArmId $id '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$' 'Chaos managed identity'
        $mi=Invoke-DemoArm $Context -Path $id -ApiVersion '2023-01-31'
        return $mi.properties.principalId
    }
    if ($identity.type -ne 'SystemAssigned') { throw 'Chaos execution identity is not configured on the existing Drill.' }
    $id=$Drill.properties.chaosResourceProperties.chaosResourceId
    if (!$id) { $id=$Drill.properties.chaosExperimentProperties.chaosExperimentId }
    Assert-PostArmId $id '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Chaos/[^/]+/[^/]+$' 'existing Chaos resource'
    $result=Invoke-DemoArg $Context "resources | where id =~ '$($id.Replace("'","''"))' | project identity"
    if ($result.count -ne 1 -or !$result.data[0].identity.principalId) { throw 'Existing Chaos resource identity is not visible. Finish its setup before running this script.' }
    return $result.data[0].identity.principalId
}

function Initialize-PostZonalDrill {
    param($Context)
    if ($Context.Mode -ne 'Zonal') { throw 'Drill setup is only allowed in the zonal workflow.' }
    Invoke-PostRecordedAction $Context 'drill.resync' $Context.Drill.id 'resyncReadinessCheck' $null
    $drill=Invoke-DemoArm $Context -Path $Context.Drill.id -ApiVersion '2026-09-30-preview'
    if ($drill.properties.executionState -ne 'NotRunning') { throw 'Drill is running; no changes will be made.' }
    $resources=@(Get-DemoList $Context "$($drill.id)/drillResources" '2026-09-30-preview')
    Assert-PostResourceSet $resources $Context.State.memberIds 'Drill'
    $configuration=Get-PostDrillUpdate $resources $Context.RunbookId $Context.State.inputs.faultDurationInMinutes
    if (@($configuration.selections | Where-Object kind -eq 'NoOp').Count) {
        $principal=Get-PostChaosPrincipal $Context $drill
        Grant-PostAutomationRole $Context $principal 'd3881f73-407a-4167-8283-e981cbba0404'
        Grant-PostAutomationRole $Context $principal $Context.Roles.Reader
    }
    $Context.State.faultSelections=$configuration.selections
    Save-DemoState $Context
    try {
        Invoke-PostRecordedAction $Context 'drill.configure' $drill.id 'addOrUpdateResources' $configuration.body
    } catch {
        $entry=@($Context.State.operations | Where-Object key -eq 'drill.configure')
        if ($entry.Count -ne 1 -or $entry[0].status -ne 'Failed' -or
            $entry[0].serverResult.error.code -ne 'RHDSUserErrorChaosResourceDiscoveryPermissionError') { throw }
        Assert-PostAppliedDrillConfiguration $Context $configuration.selections
        Assert-PostChaosSgReader $Context $drill
        Write-Warning 'Resource settings were applied, but Chaos discovery reported an access failure despite the SG grant. Keeping the failure receipt and refreshing readiness; no duplicate configuration or new permission grant.'
    }
    $null=Invoke-PostDrillReadiness $Context $drill
    Assert-PostAppliedDrillConfiguration $Context $configuration.selections
    $entry=@($Context.State.operations | Where-Object key -eq 'drill.configure')
    if ($entry.Count -eq 1 -and $entry[0].status -eq 'Failed') {
        $entry[0].configurationVerifiedAfterRefresh=$true
    }
    $Context.State.drillReadiness='Ready'
}

function Assert-PostAppliedDrillConfiguration {
    param($Context, [object[]]$Selections)
    $resources=@(Get-DemoList $Context "$($Context.Drill.id)/drillResources" '2026-09-30-preview')
    Assert-PostResourceSet $resources $Context.State.memberIds 'Drill'
    foreach ($selection in $Selections) {
        $resource=@($resources | Where-Object id -eq $selection.id)[0]
        if ($resource.properties.inclusionState -ne 'Included') { throw "Drill resource configuration was not applied: $($selection.resourceId)" }
        if ($selection.kind -eq 'NoOp') {
            if ($resource.properties.faultState -ne 'CustomScript' -or $resource.properties.faultProperties.customFault.scriptResourceId -ne $Context.RunbookId) {
                throw "NoOp fallback was not applied: $($selection.resourceId)"
            }
        } else {
            $effective = if ($resource.properties.faultProperties.overriddenDefaultFault) { $resource.properties.faultProperties.overriddenDefaultFault } else { $resource.properties.faultProperties.defaultFault }
            if ($resource.properties.faultState -ne 'SystemNative' -or $selection.faultUrn -ne $effective.faultUrn -or
                $selection.targetResourceId -ne $effective.targetResourceId -or $resource.properties.faultProperties.customFault) {
                throw "Native fault selection was not applied: $($selection.resourceId)"
            }
        }
    }
}

function Assert-PostChaosSgReader {
    param($Context, $Drill)
    $principal=Get-PostChaosPrincipal $Context $Drill
    $sg=$Context.State.serviceGroupId
    $assignments=@(Get-DemoList $Context "$sg/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()")
    $reader=@($assignments | Where-Object {
        $_.properties.principalId -eq $principal -and
        $_.properties.roleDefinitionId -like '*/de754d53-652d-4c75-a67f-1e48d8b49c97' -and
        ($_.properties.scope -eq $sg -or $_.properties.scope -eq '/')
    })
    if (!$reader.Count) { throw "Chaos workspace identity $principal lacks the Service Group Reader prerequisite on $sg. No extra SG permission was granted." }
}

function Get-PostZonalReadiness {
    param($Context)
    $drill=Invoke-DemoArm $Context -Path $Context.Drill.id -ApiVersion '2026-09-30-preview'
    if ($drill.properties.executionState -ne 'NotRunning') { throw 'Drill execution state changed; this workflow never starts or stops it.' }
    $resources=@(Get-DemoList $Context "$($drill.id)/drillResources" '2026-09-30-preview')
    Assert-PostResourceSet $resources $Context.State.memberIds 'Drill'
    $pending=@($resources | Where-Object { $_.properties.inclusionState -ne 'Included' -or $_.properties.readinessState -ne 'Ready' })
    return @{drill=$drill;pendingResources=$pending;ready=($drill.properties.executionReadinessState -eq 'Ready' -and !$pending.Count)}
}

function Invoke-PostDrillReadiness {
    param($Context, $Drill)
    $legacy=@($Context.State.operations | Where-Object { $_.key -eq 'drill.readiness' -and $_.action -eq 'refreshReadinessState' })
    if ($legacy.Count -gt 1) { throw 'Duplicate legacy readiness receipts.' }
    if ($legacy.Count -eq 1 -and $legacy[0].status -eq 'Submitting') {
        $rejectionPrefix="POST $($Drill.id)/refreshReadinessState returned 412:"
        $lastError=[string]$Context.State.lastError
        if (!$lastError.StartsWith($rejectionPrefix,[StringComparison]::OrdinalIgnoreCase) -or
            $lastError -notmatch '"code"\s*:\s*"HttpPayloadAPISpecValidationFailed"') {
            throw 'The legacy readiness request has an unknown outcome. Inspect it before submitting another action.'
        }
        $legacy[0].status='Rejected'
        $legacy[0].requestValidationError=$Context.State.lastError
        Save-DemoState $Context
    }
    for ($attempt=0; $attempt -lt 3; $attempt++) {
        $key=if ($attempt -eq 0) { 'drill.readiness-resync' } else { "drill.readiness-resync-retry-$attempt" }
        $snapshot=$null
        try {
            Invoke-PostRecordedAction $Context $key $Drill.id 'resyncReadinessCheck' $null
        } catch {
            $entry=@($Context.State.operations | Where-Object key -eq $key)
            if ($entry.Count -ne 1 -or $entry[0].status -ne 'Failed' -or
                $entry[0].serverResult.error.code -ne 'RHDSUserErrorChaosResourceDiscoveryPermissionError') { throw }
            if ($attempt -eq 2) { throw }
            Assert-PostChaosSgReader $Context $Drill
            Write-Warning 'Chaos discovery still reports an access failure despite the existing SG grant. Waiting 60 seconds before the next bounded readiness refresh.'
            Start-Sleep -Seconds 60
            continue
        }
        $snapshot=Get-PostZonalReadiness $Context
        if ($snapshot.ready) { return $snapshot }
        $attention=$snapshot.drill.properties.attentionReason
        $knownDiscoveryFailure=@($Context.State.operations | Where-Object {
            $_.key -eq 'drill.configure' -and $_.serverResult.error.code -eq 'RHDSUserErrorChaosResourceDiscoveryPermissionError'
        }).Count -eq 1
        $chaosStillBlocked=$attention.chaosResource -eq 'NotExists' -and
            @($attention.chaosResourceCreationFailureReasons | Where-Object { $_ -like 'Chaos workspace discovery or scenario configuration failed*' }).Count -gt 0
        if (!$knownDiscoveryFailure -or !$chaosStillBlocked -or $attempt -eq 2) {
            throw "Zonal Drill is not Ready after completed readiness checks. Attention: $(ConvertTo-Json -InputObject $attention -Depth 20 -Compress)"
        }
        Assert-PostAppliedDrillConfiguration $Context $Context.State.faultSelections
        Assert-PostChaosSgReader $Context $snapshot.drill
        Write-Warning 'The readiness operation succeeded, but the Drill still reports the known Chaos discovery failure. Waiting 60 seconds, then triggering another bounded resync.'
        Start-Sleep -Seconds 60
    }
}

function Invoke-PostDeploymentWorkflow {
    param($Context)
    $parent=Split-Path -Parent $Context.StatePath
    $null=New-Item -ItemType Directory -Path $parent -Force
    $lock=[IO.File]::Open("$($Context.StatePath).lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $actualHash=if (Test-Path -LiteralPath $Context.StatePath) { (Get-FileHash -LiteralPath $Context.StatePath -Algorithm SHA256).Hash } else { $null }
    if ($actualHash -ne $Context.InitialStateHash) {
        $lock.Dispose()
        throw 'State changed while preflight was running. Re-run to load the current operation journal; no actions were submitted.'
    }
    try {
        $currentMembers=Get-PostMemberIds $Context
        if (@(Compare-Object @($Context.State.memberIds) $currentMembers).Count) { throw 'SG membership changed after preflight; no actions were submitted.' }
        Save-DemoState $Context
        Assert-PostNoActiveJobs $Context
        Initialize-PostNoOpAssets $Context
        Initialize-PostRecoveryPlan $Context
        if ($Context.Mode -eq 'Regional') { Invoke-PostRegionalRoundTrip $Context } else { Initialize-PostZonalDrill $Context }
        Assert-PostRecoveryConfiguration $Context -RequireReady
        $Context.State.status='Completed'
        $Context.State.completedAtUtc=[datetime]::UtcNow.ToString('o')
        $Context.State.Remove('lastError')
        Save-DemoState $Context
        Write-Host "$($Context.Mode) workflow completed. Existing RO plan is Ready."
        if ($Context.Mode -eq 'Zonal') { Write-Host 'Existing zonal Drill is Ready and NotRunning. No Drill, fault, failover or reprotect was executed.' }
        else { Write-Host 'Six NoOp recovery actions completed and their jobs were verified. No physical failover/failback or application recovery occurred.' }
        Write-Host "Operation receipts and created NoOp asset IDs: $($Context.StatePath)"
    } catch {
        $Context.State.status='Failed'
        $Context.State.lastError=Protect-DemoMessage $Context $_.Exception.Message
        Save-DemoState $Context
        throw
    } finally { $lock.Dispose() }
}
