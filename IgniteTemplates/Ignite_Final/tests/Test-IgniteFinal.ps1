#Requires -Version 7.2
[CmdletBinding()]
param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$global:IgniteFinalTestState = $null
$testCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Reset-Mocks {
    $sg = '/providers/Microsoft.Management/serviceGroups/custom-lab-sg'
    $rg = '/subscriptions/test-sub/resourceGroups/custom-rg'
    $global:IgniteFinalTestState = @{
        ServiceGroupId = $sg
        HealthModelId = "$rg/providers/Microsoft.CloudHealth/healthmodels/custom-health-model"
        EnrollmentId = "$rg/providers/Microsoft.AzureResilienceManagement/usagePlans/rhqtUsagePlan01/enrollments/rhqtEnrollment01"
        Requests = [Collections.Generic.List[object]]::new()
        Deployments = [Collections.Generic.List[object]]::new()
        Sleeps = [Collections.Generic.List[int]]::new()
        Resources = @{}
        Reads = @{}
        OperationReads = @{}
        HealthModelCount = 1
        HealthModelLookups = 0
        GoalListMode = 'normal'
        StaleGoalRead = $false
        OperationMode = 'resource'
        FailPutType = ''
        FailedResourceType = ''
        FailStep2 = $false
        NoRest = $false
        Downloads = 0
        AllowReadiness = $false
        FailReadiness = $false
        DownloadedFiles = [Collections.Generic.List[string]]::new()
    }
}

function Set-AzContext { param($SubscriptionId) }
function Get-AzContext { [pscustomobject]@{ Subscription = @{ Id = 'test-sub' } } }
function Get-AzResourceGroup { param($Name) [pscustomobject]@{ Location = 'test-location' } }
function Get-AzAccessToken { param($ResourceUrl) @{ Token = 'mock'; ExpiresOn = 'mock' } }
function Start-Sleep {
    param([int]$Seconds)
    $global:IgniteFinalTestState.Sleeps.Add($Seconds)
}
function Get-Command {
    param($Name)
    if ($Name -ne 'az') { throw "Unexpected command lookup: $Name" }
    [pscustomobject]@{ Name = 'az'; Source = 'mock-az' }
}
function Invoke-WebRequest {
    param($Uri, $OutFile)
    $m = $global:IgniteFinalTestState
    $m.Downloads++
    if ($m.AllowReadiness) {
        Assert-True ($Uri -like 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/IgniteTemplates/SGMSGSplitIgniteScripts/*') 'Readiness no longer targets its unchanged implementation.'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\Record-Readiness.ps1') -Destination $OutFile
        $m.DownloadedFiles.Add($OutFile)
        return
    }
    throw 'No readiness download is allowed during ARM deployment or extension creation.'
}
function Get-MockOutputs {
    $m = $global:IgniteFinalTestState
    $outputs = @{
        serviceGroupId = @{ Value = $m.ServiceGroupId }
        healthModelId = @{ Value = $m.HealthModelId }
        enrollmentId = @{ Value = $m.EnrollmentId }
        usagePlanId = @{ Value = '/subscriptions/test-sub/resourceGroups/custom-rg/providers/Microsoft.AzureResilienceManagement/usagePlans/custom-plan' }
    }
    foreach ($name in @('vnet', 'publicIp', 'loadBalancer', 'webVm1', 'webVm2', 'appVm1', 'appVm2', 'postgres', 'storage')) {
        $outputs["${name}Id"] = @{ Value = "/subscriptions/test-sub/resourceGroups/custom-rg/providers/mock/$name" }
    }
    return $outputs
}
function Get-AzResourceGroupDeployment {
    throw 'Follow-on scripts must not query deployment history.'
}
function Get-AzResource {
    param($ResourceGroupName, $ResourceType)
    $m = $global:IgniteFinalTestState
    $m.HealthModelLookups++
    Assert-True ($ResourceGroupName -eq 'custom-rg' -and $ResourceType -eq 'Microsoft.CloudHealth/healthmodels') 'Health Model lookup used the wrong RG or resource type.'
    for ($i = 0; $i -lt $m.HealthModelCount; $i++) {
        [pscustomobject]@{ Name = ($m.HealthModelId -split '/')[-1] }
    }
}
function New-AzResourceGroupDeployment {
    param($ResourceGroupName, $Name, $TemplateFile, $TemplateUri, $TemplateParameterObject)
    $m = $global:IgniteFinalTestState
    Assert-True ($ResourceGroupName -eq 'custom-rg') 'Custom RG did not flow to ARM deployment.'
    Assert-True (-not $TemplateParameterObject.ContainsKey('deployGoalAssignment')) 'ARM runner still supplies removed goal parameters.'
    $template = if ($TemplateFile) {
        Get-Content -LiteralPath $TemplateFile -Raw | ConvertFrom-Json
    } else {
        Assert-True ($TemplateUri -match '/IgniteTemplates/Ignite_Final/Ex[34]_Task') 'Runner still targets the original GitHub templates.'
        $folder = Get-ChildItem -LiteralPath $Root -Directory | Where-Object { $TemplateUri.Contains("/$($_.Name)/") }
        Get-Content -LiteralPath (Join-Path $folder.FullName ($TemplateUri.Split('/')[-1])) -Raw | ConvertFrom-Json
    }
    foreach ($key in $TemplateParameterObject.Keys) {
        Assert-True ($null -ne $template.parameters.PSObject.Properties[$key]) "Runner parameter '$key' is missing from its template."
    }
    $m.ServiceGroupId = "/providers/Microsoft.Management/serviceGroups/$($TemplateParameterObject.serviceGroupName)"
    $m.Deployments.Add(@{ Name = $Name; Template = $template })
    if ($m.FailStep2 -and $Name -like 'step2-*') { throw 'Mock step2 failure' }
    [pscustomobject]@{ Outputs = Get-MockOutputs; ProvisioningState = 'Succeeded' }
}

function Invoke-AzRestMethod {
    param($Method, $Path, $Uri, $Payload)
    $m = $global:IgniteFinalTestState
    if ($m.NoRest) { throw 'The ARM runner must not issue extension REST calls.' }
    if ($Uri) { $Path = $Uri }
    $id = ($Path -split '\?', 2)[0]
    $m.Requests.Add(@{ Method = $Method; Path = $Path; Id = $id; Payload = $Payload })
    if ($id -like '*/operations/*') {
        $m.OperationReads[$id]++
        $status = if ($m.OperationMode -eq 'failed') { 'Failed' } elseif ($m.OperationReads[$id] -lt 2) { 'Running' } else { 'Succeeded' }
        if ($m.OperationMode -eq 'location') {
            return @{ StatusCode = if ($status -eq 'Running') { 202 } else { 204 }; Content = '' }
        }
        return @{ StatusCode = 200; Content = (@{ status = $status } | ConvertTo-Json -Compress) }
    }
    if ($id -eq $m.EnrollmentId) {
        return @{ StatusCode = 200; Content = (@{ properties = @{ serviceGroupId = $m.ServiceGroupId; provisioningState = 'Succeeded' } } | ConvertTo-Json -Depth 10) }
    }
    if ($id -like '*/goalAssignments') {
        $goals = @($m.Resources.Keys | Where-Object { $_ -like '*/goalAssignments/*' } | ForEach-Object { $m.Resources[$_] })
        if ($m.GoalListMode -eq 'malformed') { return @{ StatusCode = 200; Content = '{}' } }
        $list = @{ value = $goals }
        if ($m.GoalListMode -eq 'paged') { $list.nextLink = 'https://management.azure.com/more' }
        return @{ StatusCode = 200; Content = ($list | ConvertTo-Json -Depth 30) }
    }
    if ($Method -eq 'PUT') {
        if ($id -like "*$($m.FailPutType)*" -and $m.FailPutType) {
            return @{ StatusCode = 503; Content = '{"error":{"code":"MockFailure"}}' }
        }
        $resource = $Payload | ConvertFrom-Json -AsHashtable
        $resource.id = $id
        $resource.name = ($id -split '/')[-1]
        $resource.properties.provisioningState = 'Creating'
        if ($id -like '*/goalAssignments/*') { $resource.properties.requireZonalResiliency = $true }
        $m.Resources[$id] = $resource
        $headers = @{}
        if ($m.OperationMode -ne 'resource') {
            $header = if ($m.OperationMode -eq 'location') { 'Location' } else { 'Azure-AsyncOperation' }
            $headers[$header] = "https://management.azure.com/operations/$($resource.name)"
            $headers['Retry-After'] = '7'
        }
        return @{ StatusCode = 202; Content = ($resource | ConvertTo-Json -Depth 30); Headers = $headers }
    }
    if ($m.Resources.ContainsKey($id)) {
        if ($m.StaleGoalRead -and $id -like '*/goalAssignments/*') {
            return @{ StatusCode = 404; Content = '{"error":{"code":"ResourceNotFound"}}' }
        }
        $m.Reads[$id]++
        $resource = $m.Resources[$id]
        if ($resource.properties.provisioningState -eq 'Creating' -and $m.Reads[$id] -ge 2) {
            $resource.properties.provisioningState = 'Succeeded'
        }
        if ($m.FailedResourceType -and $id -like "*$($m.FailedResourceType)*") {
            $resource.properties.provisioningState = 'Failed'
        }
        return @{ StatusCode = 200; Content = ($resource | ConvertTo-Json -Depth 30) }
    }
    return @{ StatusCode = 404; Content = '{"error":{"code":"ResourceNotFound"}}' }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    Reset-Mocks
    & $Body
    $script:testCount++
    Write-Host "PASS $Name" -ForegroundColor Green
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $caught = $false
    try { & $Body | Out-Null } catch {
        $caught = $true
        Assert-True ($_.Exception.Message -like "*$Pattern*") "Unexpected failure: $($_.Exception.Message)"
    }
    Assert-True $caught "Expected failure containing '$Pattern'."
}

try {
    $ex3 = (Get-ChildItem -LiteralPath $Root -Directory | Where-Object Name -Like 'Ex3_Task4*').FullName
    $ex4 = (Get-ChildItem -LiteralPath $Root -Directory | Where-Object Name -Like 'Ex4_Task1*').FullName
    $ex3Script = Join-Path $ex3 'New-ServiceGroupExtensions.ps1'
    $ex4Script = Join-Path $ex4 'New-ServiceGroupExtensions.ps1'
    $scriptArgs = @{ SubscriptionId = 'test-sub'; ResourceGroupName = 'custom-rg'; ServiceGroupName = 'custom-lab-sg'; PollIntervalSeconds = 1 }

    Invoke-Case 'All JSON/PowerShell files parse; ARM has no SG-scoped extensions' {
        foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File) {
            if ($file.Extension -eq '.json') {
                $template = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100
                $removed = @($template.resources | Where-Object {
                    $_.type -in @('Microsoft.AzureResilienceManagement/goalAssignments', 'Microsoft.AzureResilienceManagement/recoveryPlans', 'Microsoft.AzureResilienceManagement/drills')
                })
                Assert-True ($removed.Count -eq 0) "SG extension left in $($file.Name)."
            }
            if ($file.Extension -eq '.ps1') {
                $tokens = $null
                $parseErrors = $null
                $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
                Assert-True (@($parseErrors).Count -eq 0) "PowerShell parse error in $($file.Name)."
            }
        }
        foreach ($scenario in @($ex3, $ex4)) {
            $step2 = Get-ChildItem -LiteralPath $scenario -Filter '*step2.json'
            $template = Get-Content -LiteralPath $step2.FullName -Raw | ConvertFrom-Json
            Assert-True (@($template.resources | Where-Object type -eq 'Microsoft.Relationships/serviceGroupMember').Count -eq 9) 'Memberships must remain in ARM.'
            if ($scenario -eq $ex4) {
                Assert-True (@($template.resources | Where-Object type -eq 'Microsoft.AzureResilienceManagement/usagePlans').Count -eq 1) 'Usage plan was removed.'
                Assert-True (@($template.resources | Where-Object type -eq 'Microsoft.AzureResilienceManagement/usagePlans/enrollments').Count -eq 1) 'Enrollment was removed.'
            }
        }
    }
    foreach ($mode in @('resource', 'async', 'location')) {
        Invoke-Case "Ex4 creates goal -> recovery plan -> drill using explicit names ($mode)" {
            $m = $global:IgniteFinalTestState
            $m.OperationMode = $mode
            $result = & $ex4Script @scriptArgs
            Assert-True ($result.ServiceGroupId -eq $m.ServiceGroupId) 'Explicit SG name was not used.'
            $puts = @($m.Requests | Where-Object Method -eq 'PUT')
            Assert-True ($puts.Count -eq 3) 'Expected exactly three SG extension PUTs.'
            Assert-True ($puts[0].Id -like '*/goalAssignments/*' -and $puts[1].Id -like '*/recoveryPlans/*' -and $puts[2].Id -like '*/drills/*') 'Extension creation order changed.'
            foreach ($request in $puts) {
                Assert-True ($request.Id.StartsWith($m.ServiceGroupId + '/providers/')) 'Extension did not target the configured SG name.'
                $body = $request.Payload | ConvertFrom-Json -AsHashtable
                Assert-True (-not $body.ContainsKey('scope') -and -not $body.ContainsKey('dependsOn')) 'ARM expressions leaked into a REST payload.'
            }
            $goal = $puts[0].Payload | ConvertFrom-Json -AsHashtable
            Assert-True (-not $goal.properties.ContainsKey('requireZonalResiliency')) 'Goal request must preserve the supported omitted default.'
            Assert-True ($goal.properties.goalTemplateId -eq $m.ServiceGroupId) 'Goal template ID did not follow the SG.'
            $drill = $puts[2].Payload | ConvertFrom-Json
            Assert-True ($drill.properties.healthModelMonitoringProperties.healthModelId -eq $m.HealthModelId) 'Health Model ID did not resolve from the configured RG.'
            Assert-True ($drill.properties.drillAssetProperties.subscription -eq 'test-sub') 'Drill subscription did not follow the context.'
            foreach ($i in @(1, 2)) {
                $currentIndex = $m.Requests.IndexOf($puts[$i])
                $previousId = $puts[$i - 1].Id
                $priorGets = @($m.Requests.GetRange(0, $currentIndex) | Where-Object { $_.Method -eq 'GET' -and $_.Id -eq $previousId })
                Assert-True ($priorGets.Count -ge 3) 'Dependent PUT happened before resource polling completed.'
            }
            if ($mode -ne 'resource') {
                Assert-True ($m.Sleeps.Contains(7)) 'Retry-After header was not honored.'
                Assert-True ($m.OperationReads.Values.Count -eq 3) 'Each async operation must be polled.'
            }
            Assert-True ($m.Downloads -eq 0) 'Extension creation must not start readiness.'
            $before = $m.Resources | ConvertTo-Json -Depth 30 -Compress
            $m.Requests.Clear()
            $null = & $ex4Script @scriptArgs
            Assert-True (@($m.Requests | Where-Object Method -eq 'PUT').Count -eq 0) 'Rerun must not PUT existing goals/plans/drills.'
            Assert-True (($m.Resources | ConvertTo-Json -Depth 30 -Compress) -eq $before) 'Rerun changed an existing resource.'
        }
    }
    Invoke-Case 'Ex3_Task4 creates only a goal' {
        $result = & $ex3Script @scriptArgs
        $puts = @($global:IgniteFinalTestState.Requests | Where-Object Method -eq 'PUT')
        Assert-True ($puts.Count -eq 1 -and $puts[0].Id -like '*/goalAssignments/*') 'Ex3_Task4 must create only a goal.'
        Assert-True ($result.ServiceGroupId -eq $global:IgniteFinalTestState.ServiceGroupId) 'Ex3 SG output changed.'
    }
    foreach ($scenario in @($ex3, $ex4)) {
        Invoke-Case "Per-lab SG defaults match the ARM runner without deployment history ($([IO.Path]::GetFileName($scenario)))" {
            $m = $global:IgniteFinalTestState
            $runner = Get-ChildItem -LiteralPath $scenario -Filter 'SGMSGSplit_*Deploy*.ps1'
            $arguments = @{ SubscriptionId = 'test-sub'; LabInstanceId = 'lab-123'; ResourceGroupName = 'custom-rg' }
            $m.NoRest = $true
            & $runner.FullName @arguments -UseLocalFiles
            $m.NoRest = $false
            $result = & (Join-Path $scenario 'New-ServiceGroupExtensions.ps1') @arguments -PollIntervalSeconds 1
            Assert-True ($result.ServiceGroupId -eq $m.ServiceGroupId) 'Follow-on SG default does not match the ARM runner.'
        }
    }
    Invoke-Case 'Ex4 explicit prerequisite names bypass Health Model discovery' {
        $m = $global:IgniteFinalTestState
        $m.EnrollmentId = '/subscriptions/test-sub/resourceGroups/custom-rg/providers/Microsoft.AzureResilienceManagement/usagePlans/custom-plan/enrollments/custom-enrollment'
        $m.HealthModelCount = 0
        $null = & $ex4Script @scriptArgs -UsagePlanName 'custom-plan' -EnrollmentName 'custom-enrollment' -HealthModelName 'custom-health-model'
        Assert-True ($m.HealthModelLookups -eq 0) 'Explicit Health Model name still triggered discovery.'
        Assert-True ($m.Requests[0].Id -eq $m.EnrollmentId) 'Explicit usage plan/enrollment names were not used.'
    }
    foreach ($count in @(0, 2)) {
        Invoke-Case "Ex4 refuses missing or ambiguous Health Models (count=$count)" {
            $m = $global:IgniteFinalTestState
            $m.HealthModelCount = $count
            Assert-Throws { & $ex4Script @scriptArgs } 'Pass -HealthModelName explicitly'
            Assert-True (@($m.Requests | Where-Object Method -eq 'PUT').Count -eq 0) 'Ambiguous Health Model lookup caused extension creation.'
        }
    }
    foreach ($mode in @('malformed', 'paged')) {
        Invoke-Case "Incomplete goal discovery is rejected ($mode)" {
            $global:IgniteFinalTestState.GoalListMode = $mode
            Assert-Throws { & $ex3Script @scriptArgs } 'incomplete response'
            Assert-True (@($global:IgniteFinalTestState.Requests | Where-Object Method -eq 'PUT').Count -eq 0) 'Incomplete discovery caused a PUT.'
        }
    }
    Invoke-Case 'Failed existing goal is not overwritten' {
        $m = $global:IgniteFinalTestState
        $m.Resources["$($m.ServiceGroupId)/providers/Microsoft.AzureResilienceManagement/goalAssignments/zonal-ha-assign"] = @{
            name = 'zonal-ha-assign'; properties = @{ provisioningState = 'Failed'; requireZonalResiliency = $true }
        }
        Assert-Throws { & $ex3Script @scriptArgs } 'not a successful zonal goal'
        Assert-True (@($m.Requests | Where-Object Method -eq 'PUT').Count -eq 0) 'Failed goal was overwritten.'
    }
    Invoke-Case 'Successful goal list prevents a PUT even if individual GET is stale' {
        $m = $global:IgniteFinalTestState
        $m.StaleGoalRead = $true
        $m.Resources["$($m.ServiceGroupId)/providers/Microsoft.AzureResilienceManagement/goalAssignments/zonal-ha-assign"] = @{
            name = 'zonal-ha-assign'; properties = @{ provisioningState = 'Succeeded'; requireZonalResiliency = $true; sli = 'keep-existing' }
        }
        $null = & $ex3Script @scriptArgs
        Assert-True (@($m.Requests | Where-Object Method -eq 'PUT').Count -eq 0) 'Stale individual GET overwrote a known successful goal.'
    }
    Invoke-Case 'Uncertain PUT failure is not blindly retried' {
        $m = $global:IgniteFinalTestState
        $m.FailPutType = '/goalAssignments/'
        Assert-Throws { & $ex4Script @scriptArgs } 'HTTP 503'
        Assert-True (@($m.Requests | Where-Object Method -eq 'PUT').Count -eq 1) 'Failed goal PUT was retried or a dependent was created.'
    }
    Invoke-Case 'Failed async goal operation blocks recovery plan and drill' {
        $m = $global:IgniteFinalTestState
        $m.OperationMode = 'failed'
        Assert-Throws { & $ex4Script @scriptArgs } 'Provisioning failed'
        Assert-True (@($m.Requests | Where-Object Method -eq 'PUT').Count -eq 1) 'Dependent resources ran after async goal failure.'
    }
    Invoke-Case 'Failed recovery plan blocks drill creation' {
        $m = $global:IgniteFinalTestState
        $m.FailedResourceType = '/recoveryPlans/'
        Assert-Throws { & $ex4Script @scriptArgs } 'Provisioning failed'
        Assert-True (@($m.Requests | Where-Object Method -eq 'PUT').Count -eq 2) 'Drill ran after recovery plan failure.'
    }
    foreach ($failure in @($false, $true)) {
        Invoke-Case "Separate Ex4 readiness wrapper passes actual IDs and cleans up (failure=$failure)" {
            $m = $global:IgniteFinalTestState
            $m.AllowReadiness = $true
            $m.FailReadiness = $failure
            $arguments = @{
                ServiceGroupId = $m.ServiceGroupId
                RecoveryPlanId = "$($m.ServiceGroupId)/providers/Microsoft.AzureResilienceManagement/recoveryPlans/custom-ro"
                DrillId = "$($m.ServiceGroupId)/providers/Microsoft.AzureResilienceManagement/drills/custom-drill"
            }
            $invoke = { & (Join-Path $ex4 'Initialize-ServiceGroupReadiness.ps1') @arguments }
            if ($failure) { Assert-Throws $invoke 'Mock readiness failure' } else { & $invoke }
            foreach ($key in $arguments.Keys) {
                Assert-True ($m.ReadinessArguments[$key] -eq $arguments[$key]) "Readiness lost the actual $key."
            }
            Assert-True ($m.ReadinessArguments.RhubArmEndpoint -eq 'https://management.azure.com') 'Readiness ARM endpoint changed.'
            Assert-True ($m.DownloadedFiles.Count -eq 4) 'Readiness dependencies were not all downloaded.'
            foreach ($path in $m.DownloadedFiles) {
                Assert-True (-not (Test-Path -LiteralPath $path)) 'Temporary readiness files were not cleaned up.'
            }
        }
    }
    $armRunners = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter 'SGMSGSplit_*Deploy*.ps1')
    foreach ($runner in $armRunners) {
        foreach ($local in @($false, $true)) {
            Invoke-Case "$($runner.Name) preserves ARM setup without extension calls (local=$local)" {
                $m = $global:IgniteFinalTestState
                $m.NoRest = $true
                $args = @{ SubscriptionId = 'test-sub'; LabInstanceId = 'custom-lab'; ResourceGroupName = 'custom-rg' }
                if ($local) { $args.UseLocalFiles = $true }
                & $runner.FullName @args
                Assert-True ($m.Deployments.Count -eq 2) 'Expected step1 and step2 ARM deployments.'
                Assert-True ($m.Requests.Count -eq 0 -and $m.Downloads -eq 0) 'ARM runner still performs extensions or readiness.'
            }
        }
    }
    Invoke-Case 'ARM step2 failure retries three times and never runs extensions' {
        $m = $global:IgniteFinalTestState
        $m.NoRest = $true
        $m.FailStep2 = $true
        $runner = Get-ChildItem -LiteralPath $ex4 -Filter 'SGMSGSplit_*Deploy*.ps1'
        Assert-Throws { & $runner.FullName -SubscriptionId 'test-sub' -LabInstanceId 'custom-lab' -ResourceGroupName 'custom-rg' -UseLocalFiles } 'Mock step2 failure'
        Assert-True (@($m.Deployments | Where-Object Name -Like 'step2-*').Count -eq 3) 'Step2 retry count changed.'
        Assert-True ($m.Requests.Count -eq 0 -and $m.Downloads -eq 0) 'Failed runner performed extension or readiness work.'
    }
    Write-Host "Passed $testCount offline test cases. No Azure operations were performed." -ForegroundColor Green
} finally {
    Remove-Variable -Name IgniteFinalTestState -Scope Global
}
