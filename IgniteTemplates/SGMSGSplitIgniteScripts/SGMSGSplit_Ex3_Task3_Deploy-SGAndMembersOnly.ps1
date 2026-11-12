#Requires -Version 7.2
<#
.SYNOPSIS
    Creates only a Service Group and nine memberships for existing Task3 resources.
.DESCRIPTION
    Requires an existing signed-in Az context and resource group. Does not create RGs or
    application resources. Uses the original templates from GitHub by default, or adjacent
    files with UseLocalFiles. Step1 filters the original template to the SG resource only,
    and returns resource IDs using the original ARM naming formulas. Step2 receives those
    IDs and deploys the original nine-member template.
    SG creation allows three total attempts with 10-second delays. Membership deployment
    retains three total attempts with 180-second delays. The original 60-second pre-step1
    wait, ARM token calls and 120-second RBAC propagation wait are retained.
    Uses the current identity; does not create scoped-SP secrets or assign learner roles.
.PARAMETER ServiceGroupName
    Required exact Service Group name. No lab-instance suffix is added automatically.
.PARAMETER ResourceGroupName
    Existing RG containing resources deployed with the original Task3 naming formulas.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ServiceGroupName,

    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex3_Task3',

    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',

    [ValidateNotNullOrEmpty()]
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/IgniteTemplates/SGMSGSplitIgniteScripts',

    [switch] $UseLocalFiles
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-SourceTemplate {
    param([string] $Name)
    if ($UseLocalFiles) {
        return Get-Content -LiteralPath (Join-Path $PSScriptRoot $Name) -Raw |
            ConvertFrom-Json -AsHashtable
    }
    return Invoke-RestMethod -Uri "$($TemplateBaseUri.TrimEnd('/'))/$Name" -ErrorAction Stop |
        ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
}

function Invoke-StageDeployment {
    param([string] $Stage, [hashtable] $Template, [hashtable] $Parameters, [int] $RetryDelaySeconds)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $name = "$Stage-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            [Console]::WriteLine("Deploying $Stage (attempt $attempt of 3).")
            $result = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $name `
                -TemplateObject $Template -TemplateParameterObject $Parameters -Mode Incremental -ErrorAction Stop
            if ($result.ProvisioningState -ne 'Succeeded') {
                throw "$Stage returned provisioning state '$($result.ProvisioningState)'."
            }
            return $result
        } catch {
            if ($attempt -ge 3) { throw }
            [Console]::WriteLine("WARNING: $Stage attempt $attempt failed: $($_.Exception.Message). Retrying in $RetryDelaySeconds seconds.")
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
$null = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
$step1Template = Get-SourceTemplate 'SGMSGSplit_Ex3_Task3_CommonSGSetup.json'
$step2Template = Get-SourceTemplate 'SGMSGSplit_NoOpStep2_UserCreatesGoalsManually.json'

$serviceGroups = @($step1Template.resources | Where-Object type -eq 'Microsoft.Management/serviceGroups')
if ($serviceGroups.Count -ne 1 -or $step2Template.resources.Count -ne 9 -or
        @($step2Template.resources | Where-Object type -ne 'Microsoft.Relationships/serviceGroupMember').Count) {
    throw 'Expected one source SG resource and exactly nine membership resources.'
}
$step1Template.resources = $serviceGroups
$step1Template.outputs = @{
    serviceGroupId = @{
        type = 'string'
        value = "[tenantResourceId('Microsoft.Management/serviceGroups', parameters('serviceGroupName'))]"
    }
}
$members = [ordered]@{
    vnetId = @('Microsoft.Network/virtualNetworks', 'vnetNameValue')
    publicIpId = @('Microsoft.Network/publicIPAddresses', 'publicIpNameValue')
    loadBalancerId = @('Microsoft.Network/loadBalancers', 'lbNameValue')
    webVm1Id = @('Microsoft.Compute/virtualMachines', 'webVm1NameValue')
    webVm2Id = @('Microsoft.Compute/virtualMachines', 'webVm2NameValue')
    appVm1Id = @('Microsoft.Compute/virtualMachines', 'appVm1NameValue')
    appVm2Id = @('Microsoft.Compute/virtualMachines', 'appVm2NameValue')
    postgresId = @('Microsoft.DBforPostgreSQL/flexibleServers', 'pgServerNameValue')
    storageId = @('Microsoft.Storage/storageAccounts', 'storageNameValue')
}
foreach ($key in $members.Keys) {
    $resourceType, $nameVariable = $members[$key]
    if (-not $step1Template.variables.Contains($nameVariable)) {
        throw "Source template is missing naming variable '$nameVariable'."
    }
    $step1Template.outputs[$key] = @{
        type = 'string'
        value = "[resourceId('$resourceType', variables('$nameVariable'))]"
    }
}

Start-Sleep -Seconds 60
$token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
if (-not $token.Token) { throw 'Failed to acquire an ARM access token before step1.' }
$token = $null
$step1Result = Invoke-StageDeployment -Stage 'step1-sg' -Template $step1Template `
    -Parameters @{ serviceGroupName = $ServiceGroupName } -RetryDelaySeconds 10

$step2Parameters = @{ serviceGroupName = $ServiceGroupName }
foreach ($key in $members.Keys) {
    $id = $step1Result.Outputs[$key].Value
    if ([string]::IsNullOrWhiteSpace($id)) { throw "Step1 did not return resource ID '$key'." }
    $step2Parameters[$key] = $id
}
Start-Sleep -Seconds 120
$token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
if (-not $token.Token) { throw 'Failed to acquire an ARM access token before step2.' }
$token = $null
$null = Invoke-StageDeployment -Stage 'step2-members' -Template $step2Template `
    -Parameters $step2Parameters -RetryDelaySeconds 180

[Console]::WriteLine("Service Group '$ServiceGroupName' and nine memberships deployed for existing RG '$ResourceGroupName'.")
[Console]::WriteLine('No resource groups or raw application resources were created. Goals remain a manual step.')
