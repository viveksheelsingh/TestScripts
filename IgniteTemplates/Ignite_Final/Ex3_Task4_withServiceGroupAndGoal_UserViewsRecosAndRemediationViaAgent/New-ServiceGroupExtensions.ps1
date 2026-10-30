#Requires -Version 7.2
<#
.SYNOPSIS
    Create the SG-scoped goal AFTER the ARM runner.
.DESCRIPTION
    Uses Az PowerShell ARM REST calls, not ARM deployments or Azure CLI.
    Requires a successful Ignite_Final step2 deployment for the same Service Group.
    Memberships remain in the ARM templates.
    Waits for each resource to finish before proceeding. Reuses existing resources
    without PUT so reruns do not reset goals, SLI, recovery groups or drill setup.
    Retains the tested payloads/API versions from the original templates.
    Does not configure readiness or execute any drill.
.PARAMETER DeploymentName
    Completed step2 deployment to use. Defaults to the latest step2-* deployment;
    a failed latest deployment stops this script rather than falling back.
.EXAMPLE
    .\New-ServiceGroupExtensions.ps1 -SubscriptionId '<subscription>' -ResourceGroupName '<same-RG-as-ARM>'
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId = '@lab.CloudSubscription.Id',
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName = 'CaldovaPayApp_Ex3_Task4',
    [string]$ServiceGroupName,
    [string]$DeploymentName,
    [ValidatePattern('^[^/]+$')]
    [string]$ZonalGoalAssignmentName = 'zonal-ha-assign',
    [string]$GoalApiVersion = '2026-08-31-preview',
    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 45,
    [ValidateRange(1, 300)]
    [int]$PollIntervalSeconds = 15
)

$ErrorActionPreference = 'Stop'

function Invoke-ArmRequest {
    param([string]$Method = 'GET', [string]$Path, [string]$Payload, [switch]$AllowNotFound)
    $arguments = @{ Method = $Method; ErrorAction = 'Stop' }
    if ($Path.StartsWith('/')) {
        $arguments.Path = $Path
    } else {
        $uri = [uri]$Path
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com') {
            throw "Unexpected ARM polling URL: $Path"
        }
        $arguments.Uri = $Path
    }
    if ($Payload) { $arguments.Payload = $Payload }
    $response = Invoke-AzRestMethod @arguments
    if ($AllowNotFound -and $response.StatusCode -eq 404) { return $response }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "$Method $Path returned HTTP $($response.StatusCode): $($response.Content)"
    }
    return $response
}

function Wait-ArmResource {
    param([string]$ResourceId, [string]$ApiVersion, $InitialResponse)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $operationUri = $null
    $asyncOperation = $false
    $delay = $PollIntervalSeconds
    if ($InitialResponse -and $InitialResponse.Headers) {
        $operationUri = [string](@($InitialResponse.Headers['Azure-AsyncOperation'])[0])
        $asyncOperation = -not [string]::IsNullOrWhiteSpace($operationUri)
        if (-not $operationUri) {
            $operationUri = [string](@($InitialResponse.Headers['Location'])[0])
        }
        $retryAfter = 0
        if ([int]::TryParse([string](@($InitialResponse.Headers['Retry-After'])[0]), [ref]$retryAfter) -and $retryAfter -gt 0) {
            $delay = $retryAfter
        }
    }
    while ($timer.Elapsed.TotalMinutes -lt $TimeoutMinutes) {
        if ($operationUri) {
            Start-Sleep -Seconds $delay
            if ($timer.Elapsed.TotalMinutes -ge $TimeoutMinutes) { break }
            $response = Invoke-ArmRequest -Path $operationUri
            $operation = if ($response.Content) { $response.Content | ConvertFrom-Json } else { $null }
            $state = if ($operation.status) { $operation.status } else { $operation.properties.provisioningState }
            if ($state -in @('Failed', 'Canceled', 'Cancelled')) {
                throw "Provisioning failed for ${ResourceId}: $($response.Content)"
            }
            if ($state -eq 'Succeeded' -or (-not $asyncOperation -and -not $state -and $response.StatusCode -in @(200, 201, 204))) {
                $operationUri = $null
            } else {
                continue
            }
        }
        $response = Invoke-ArmRequest -Path "${ResourceId}?api-version=$ApiVersion" -AllowNotFound
        if ($response.StatusCode -ne 404) {
            $resource = $response.Content | ConvertFrom-Json
            $state = $resource.properties.provisioningState
            if ($state -in @('Failed', 'Canceled', 'Cancelled')) {
                throw "Provisioning failed for ${ResourceId}: $($response.Content)"
            }
            if ($response.StatusCode -eq 200 -and ($state -eq 'Succeeded' -or -not $state)) {
                return $resource
            }
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "Timed out waiting for $ResourceId. No dependent resource was created; rerun to inspect/resume without another PUT."
}

function New-ArmResourceIfMissing {
    param([string]$ResourceId, [string]$ApiVersion, [hashtable]$Body)
    $path = "${ResourceId}?api-version=$ApiVersion"
    $response = Invoke-ArmRequest -Path $path -AllowNotFound
    if ($response.StatusCode -eq 404) {
        Write-Host "Creating $ResourceId" -ForegroundColor Cyan
        # Do not blindly retry PUT: a failed client request can still create the resource.
        $response = Invoke-ArmRequest -Method PUT -Path $path -Payload ($Body | ConvertTo-Json -Depth 30)
        return Wait-ArmResource -ResourceId $ResourceId -ApiVersion $ApiVersion -InitialResponse $response
    }
    Write-Host "Reusing $ResourceId without PUT." -ForegroundColor Cyan
    return Wait-ArmResource -ResourceId $ResourceId -ApiVersion $ApiVersion
}

$null = Set-AzContext -SubscriptionId $SubscriptionId
if (-not $DeploymentName) {
    $latest = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName |
        Where-Object { $_.DeploymentName -like 'step2-*' } |
        Sort-Object Timestamp -Descending | Select-Object -First 1
    if (-not $latest) { throw 'Run the Ignite_Final ARM runner successfully before creating SG extensions.' }
    $DeploymentName = $latest.DeploymentName
}
$deployment = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $DeploymentName
$serviceGroupId = $deployment.Outputs.serviceGroupId.Value
if ($deployment.ProvisioningState -ne 'Succeeded' -or $serviceGroupId -notmatch '^/providers/Microsoft\.Management/serviceGroups/[^/]+$') {
    throw "Deployment '$DeploymentName' must be a successful Ignite_Final step2 with a valid Service Group output."
}
if ($ServiceGroupName -and $serviceGroupId -ne "/providers/Microsoft.Management/serviceGroups/$ServiceGroupName") {
    throw "Deployment '$DeploymentName' does not target the requested Service Group '$ServiceGroupName'."
}

$goalCollection = "$serviceGroupId/providers/Microsoft.AzureResilienceManagement/goalAssignments"
$response = Invoke-ArmRequest -Path "${goalCollection}?api-version=$GoalApiVersion"
$goals = $response.Content | ConvertFrom-Json
if (-not $goals.PSObject.Properties['value'] -or $goals.value -isnot [array] -or $goals.nextLink) {
    throw 'Goal discovery returned an incomplete response; refusing to guess whether to create a goal.'
}
$existing = @($goals.value)
if ($existing.Count -gt 1 -or ($existing.Count -eq 1 -and $existing[0].name -ne $ZonalGoalAssignmentName)) {
    throw "Existing goal assignments do not match '$ZonalGoalAssignmentName'."
}
if ($existing.Count -eq 1 -and ($existing[0].properties.provisioningState -ne 'Succeeded' -or
        $existing[0].properties.requireZonalResiliency -isnot [bool] -or $existing[0].properties.requireZonalResiliency -ne $true)) {
    throw 'The existing goal is not a successful zonal goal; resolve it before retrying.'
}
$goalId = "$goalCollection/$ZonalGoalAssignmentName"
$goal = if ($existing.Count) {
    Write-Host "Reusing $goalId without PUT." -ForegroundColor Cyan
    $existing[0]
} else {
    New-ArmResourceIfMissing -ResourceId $goalId -ApiVersion $GoalApiVersion -Body @{
        properties = @{
            goalAssignmentType = 'Resiliency'
            goalTemplateId = $serviceGroupId
        }
    }
}
if ($goal.properties.requireZonalResiliency -isnot [bool] -or $goal.properties.requireZonalResiliency -ne $true) {
    throw 'The goal did not return the expected requireZonalResiliency=true default.'
}

Write-Host 'SG goal complete; no recovery plan or drill is created in this scenario.' -ForegroundColor Green
[pscustomobject]@{
    ServiceGroupId = $serviceGroupId
    GoalAssignmentId = $goalId
}
