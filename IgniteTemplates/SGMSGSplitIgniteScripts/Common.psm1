$ErrorActionPreference = 'Stop'

function Get-DemoValue {
    param($Object, [string]$Path)
    $value = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $value) { return $null }
        if ($value -is [Collections.IDictionary]) {
            if (!$value.Contains($part)) { return $null }
            $value = $value[$part]
        } else {
            $property = $value.PSObject.Properties[$part]
            if (!$property) { return $null }
            $value = $property.Value
        }
    }
    return $value
}

function Get-DemoGuid([string]$Text) {
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant()))
    return [guid]::new([byte[]]$bytes[0..15]).ToString()
}

function Test-DemoResourceOwnership {
    param($State, $Resource)
    if ((Get-DemoValue $Resource 'tags.DrillDemoId') -eq $State.demoId) { return $true }
    foreach ($entry in $State.resources) {
        if ($entry.ownership -ne 'Created') { continue }
        if ($entry.id -eq $Resource.id) { return $true }
        if ($entry.id -ne $State.resourceGroupId -and $entry.kind -in @('TaggedResource','DeployedResource') -and
            $Resource.id.StartsWith("$($entry.id)/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    return $false
}

function Test-DemoPermission {
    param($Permissions, [string]$Action)
    foreach ($entry in $Permissions) {
        $allowed = @($entry.actions | Where-Object { $Action -like $_ }).Count -gt 0
        $excluded = @($entry.notActions | Where-Object { $Action -like $_ }).Count -gt 0
        if ($allowed -and !$excluded) { return $true }
    }
    return $false
}

function ConvertTo-DemoLocation([string]$Location) {
    return ($Location.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Get-DemoArmUri {
    param($Context, [string]$Path, [string]$ApiVersion)
    if ($Path.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        $uri = [uri]$Path
    } else {
        $endpoint = if ($Path -match '/providers/Microsoft\.AzureResilienceManagement(?:/|$)') {
            $Context.RhubEndpoint
        } else { 'https://management.azure.com' }
        $uri = [uri]("$endpoint$Path" + $(if ($ApiVersion) { "?api-version=$ApiVersion" } else { '' }))
    }
    $allowed = @('management.azure.com', ([uri]$Context.RhubEndpoint).Host)
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin $allowed -or $uri.UserInfo -or $uri.Fragment -or !$uri.IsDefaultPort) {
        throw "Refusing credential forwarding to an unexpected ARM endpoint: $($uri.Host)"
    }
    return $uri
}

function Get-DemoToken {
    param($Context, [string]$Audience = 'https://management.azure.com/')
    $cached = $Context.Tokens[$Audience]
    if (!$cached -or [datetime]::UtcNow.AddMinutes(3) -ge $cached.Expires) {
        $raw = & az account get-access-token --subscription $Context.SubscriptionId --resource $Audience --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Azure CLI authentication failed for $Audience." }
        $data = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
        $expiry = [DateTimeOffset]::FromUnixTimeSeconds([long]$data.expires_on).UtcDateTime
        if (!$data.accessToken -or $expiry -le [datetime]::UtcNow) { throw 'Azure CLI returned an expired or empty token.' }
        $cached = @{ Token=$data.accessToken; Expires=$expiry }
        $Context.Tokens[$Audience] = $cached
    }
    return $cached.Token
}

function Protect-DemoMessage {
    param($Context, [string]$Message)
    foreach ($secret in $Context.Secrets) {
        if ($secret) {
            $Message = $Message.Replace($secret, '[redacted]')
            $escaped = (ConvertTo-Json -InputObject $secret -Compress).Trim('"')
            $Message = $Message.Replace($escaped, '[redacted]')
        }
    }
    return ($Message -replace '(https://[^\s?"]+)\?[^\s"]+', '$1?[redacted]')
}

function Send-DemoArm {
    param($Context, [string]$Method, [uri]$Uri, $Body, [string]$ContentType = 'application/json', [switch]$AllowNotFound, [string]$OperationId)
    $headers = @{ Authorization="Bearer $(Get-DemoToken $Context)" }
    if ($Method -notin @('GET','HEAD') -and $Uri.AbsolutePath -match '/providers/Microsoft\.AzureResilienceManagement/') {
        $headers['operation-id'] = if ($OperationId) { ([guid]$OperationId).ToString() } else { [guid]::NewGuid().ToString() }
    }
    $arguments = @{ Uri=$Uri; Method=$Method; Headers=$headers; TimeoutSec=180; MaximumRedirection=0; SkipHttpErrorCheck=$true }
    if ($Method -notin @('GET','HEAD')) { $arguments.ContentType = $ContentType }
    if ($null -ne $Body) {
        $arguments.Body = if ($ContentType -eq 'application/json') { ConvertTo-Json -InputObject $Body -Depth 100 -Compress } else { $Body }
    }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try { $response = Invoke-WebRequest @arguments }
        catch [System.Threading.Tasks.TaskCanceledException] {
            if ($Method -notin @('GET','PUT','DELETE') -or $attempt -eq 4) { throw }
            Write-Warning "$Method $($Uri.AbsolutePath) timed out; retrying the idempotent request."
            Start-Sleep -Seconds (5 * $attempt)
            continue
        }
        if ($response.StatusCode -eq 404 -and $AllowNotFound) { return $null }
        if ($response.StatusCode -eq 401 -and $attempt -lt 4 -and $response.Content -match 'ExpiredAuthenticationToken') {
            $Context.Tokens.Remove('https://management.azure.com/')
            $arguments.Headers.Authorization = "Bearer $(Get-DemoToken $Context)"
            continue
        }
        if ($Method -in @('GET','PUT','DELETE') -and $response.StatusCode -in @(408,429,500,502,503,504) -and $attempt -lt 4) {
            Write-Warning "$Method $($Uri.AbsolutePath) returned $($response.StatusCode); retry $attempt/4."
            Start-Sleep -Seconds (5 * $attempt)
            continue
        }
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            $message = Protect-DemoMessage $Context $response.Content
            throw "$Method $($Uri.AbsolutePath) returned $($response.StatusCode): $message"
        }
        $content = $response.Content
        if ($response.Content -and $response.Headers['Content-Type'] -match 'json') {
            $content = $response.Content | ConvertFrom-Json -AsHashtable
        }
        return @{
            StatusCode=[int]$response.StatusCode; Body=$content
            AsyncUrl=[string]($response.Headers['Azure-AsyncOperation'] | Select-Object -First 1)
            Location=[string]($response.Headers['Location'] | Select-Object -First 1)
        }
    }
    throw 'ARM request exhausted its retry limit.'
}

function ConvertFrom-DemoOperation {
    param($Operation)
    $properties = Get-DemoValue $Operation 'properties'
    if ($properties -is [string] -and ![string]::IsNullOrWhiteSpace($properties)) {
        return $properties | ConvertFrom-Json -AsHashtable
    }
    if ($properties -is [Collections.IDictionary]) { return $properties }
    return $Operation
}

function Invoke-DemoArm {
    param($Context, [string]$Method = 'GET', [Parameter(Mandatory)][string]$Path,
        [string]$ApiVersion, $Body, [string]$ContentType = 'application/json',
        [switch]$AllowNotFound, [switch]$NoWait, [switch]$OperationResult, [string]$OperationId)
    $uri = Get-DemoArmUri $Context $Path $ApiVersion
    $response = Send-DemoArm $Context $Method $uri $Body $ContentType -AllowNotFound:$AllowNotFound -OperationId $OperationId
    if ($null -eq $response) { return $null }
    $statusDocument = !!$response.AsyncUrl
    $pollUrl = if ($statusDocument) { $response.AsyncUrl } elseif ($response.StatusCode -eq 202) { $response.Location } else { $null }
    if (!$NoWait -and $Method -notin @('GET','HEAD') -and $pollUrl) {
        $deadline = [datetime]::UtcNow.AddMinutes($Context.TimeoutMinutes)
        do {
            Start-Sleep -Seconds 10
            $pollUri = Get-DemoArmUri $Context $pollUrl
            $poll = Send-DemoArm $Context 'GET' $pollUri $null
            $status = Get-DemoValue $poll.Body 'status'
            if (!$status) { $status = Get-DemoValue $poll.Body 'properties.provisioningState' }
            if ($status -in @('Failed','Canceled','Cancelled')) {
                $error = [InvalidOperationException]::new((Protect-DemoMessage $Context "Operation failed: $(ConvertTo-Json -InputObject $poll.Body -Depth 30 -Compress)"))
                $error.Data['ArmOperationResult'] = $poll.Body
                throw $error
            }
            if ($status -eq 'Succeeded' -or (!$statusDocument -and !$status -and $poll.StatusCode -in @(200,201,204))) {
                if ($OperationResult) { return ConvertFrom-DemoOperation $poll.Body }
                return $poll.Body
            }
            if ([datetime]::UtcNow -ge $deadline) { throw "Operation deadline exceeded: $($pollUri.AbsolutePath). The Azure operation may still be running; resume rather than create a duplicate." }
        } while ($true)
    }
    if (!$NoWait -and $Method -notin @('GET','HEAD') -and $response.StatusCode -eq 202 -and !$pollUrl) {
        throw "Accepted operation has no polling URL: $($uri.AbsolutePath). Read back its state before retrying."
    }
    if ($response.Body -is [byte[]]) { return ,$response.Body }
    return $response.Body
}

function Get-DemoList {
    param($Context, [string]$Path, [string]$ApiVersion)
    $page = Invoke-DemoArm $Context -Path $Path -ApiVersion $ApiVersion
    $seen = [Collections.Generic.HashSet[string]]::new()
    while ($true) {
        if ($page -isnot [Collections.IDictionary] -or !$page.Contains('value')) { throw "Invalid list response: $Path" }
        foreach ($entry in $page.value) { $entry }
        if (!$page.nextLink) { break }
        if (!$seen.Add($page.nextLink)) { throw "Repeated pagination URL: $Path" }
        $next = [uri]$page.nextLink
        if ($next.AbsolutePath -match '/providers/Microsoft\.AzureResilienceManagement/') {
            $next = [uri]("$($Context.RhubEndpoint)$($next.PathAndQuery)")
        }
        $page = Invoke-DemoArm $Context -Path $next.AbsoluteUri
    }
}

function Save-DemoState {
    param($Context)
    $Context.State.updatedAtUtc = [datetime]::UtcNow.ToString('o')
    $parent = Split-Path -Parent $Context.StatePath
    $null = New-Item -ItemType Directory -Path $parent -Force
    $temporary = "$($Context.StatePath).tmp"
    $json = ConvertTo-Json -InputObject $Context.State -Depth 100
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $Context.StatePath, $true)
}

function Add-DemoRecord {
    param($Context, [string]$Id, [string]$Kind, [string]$ApiVersion, [string]$Ownership = 'Created')
    if (!@($Context.State.resources | Where-Object { $_.id -eq $Id }).Count) {
        $Context.State.resources += @{ id=$Id; kind=$Kind; apiVersion=$ApiVersion; ownership=$Ownership; recordedAtUtc=[datetime]::UtcNow.ToString('o') }
        Save-DemoState $Context
    }
}

function Wait-DemoResource {
    param($Context, [string]$Id, [string]$Version)
    $deadline = [datetime]::UtcNow.AddMinutes($Context.TimeoutMinutes)
    do {
        $resource = Invoke-DemoArm $Context -Path $Id -ApiVersion $Version
        $state = Get-DemoValue $resource 'properties.provisioningState'
        if ($state -in @('Failed','Canceled','Cancelled')) { throw "Resource provisioning failed: $Id" }
        if (!$state -or $state -eq 'Succeeded') { return $resource }
        if ([datetime]::UtcNow -ge $deadline) { throw "Resource did not finish provisioning: $Id ($state)" }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Set-DemoOwnedResource {
    param($Context, [string]$Id, [string]$Version, [hashtable]$Body)
    $existing = Invoke-DemoArm $Context -Path $Id -ApiVersion $Version -AllowNotFound
    if ($existing -and (Get-DemoValue $existing 'tags.DrillDemoId') -ne $Context.State.demoId) {
        throw "Refusing to replace a resource not owned by this deployment: $Id"
    }
    $Body.tags = $Context.Tags
    if (!$existing) { Add-DemoRecord $Context $Id 'TaggedResource' $Version }
    Write-Host "Ensuring $Id"
    $null = Invoke-DemoArm $Context -Method PUT -Path $Id -ApiVersion $Version -Body $Body
    return Wait-DemoResource $Context $Id $Version
}

function Grant-DemoRole {
    param($Context, [string]$PrincipalId, [string]$RoleId, [string]$Scope, [string]$PrincipalType = 'ServicePrincipal')
    if (!$PrincipalId) { throw "Cannot grant a role without a principal: $Scope" }
    $guid = Get-DemoGuid "$($Context.State.demoId)|$PrincipalId|$RoleId|$Scope"
    $id = "$Scope/providers/Microsoft.Authorization/roleAssignments/$guid"
    $existing = Invoke-DemoArm $Context -Path $id -ApiVersion '2022-04-01' -AllowNotFound
    if ($existing) {
        if ($existing.properties.principalId -ne $PrincipalId -or $existing.properties.roleDefinitionId -notlike "*/$RoleId") { throw "Conflicting role assignment: $id" }
        return
    }
    Add-DemoRecord $Context $id 'RoleAssignment' '2022-04-01'
    $null = Invoke-DemoArm $Context -Method PUT -Path $id -ApiVersion '2022-04-01' -Body @{
        properties=@{ principalId=$PrincipalId; principalType=$PrincipalType; roleDefinitionId="/subscriptions/$($Context.SubscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$RoleId" }
    }
}

function Get-DemoProtectionDecision {
    param($RecoveryResource, [bool]$ExpectedHA)
    $solutions = @(Get-DemoValue $RecoveryResource 'properties.resourceProtectionSolutions')
    foreach ($solution in $solutions) {
        $auto = Get-DemoValue $solution 'isAutoFailover'
        if ($auto -is [bool] -and $auto) { return 'ExcludeNativeHA' }
    }
    if ($ExpectedHA) { return 'WaitForNativeHA' }
    $status = Get-DemoValue $RecoveryResource 'properties.protectionStatus'
    $selected = Get-DemoValue $RecoveryResource 'properties.selectedProtectionSolutionType'
    if ($status -eq 'NotProtected' -or ($status -eq 'Protected' -and $selected -eq 'CustomRunbook')) {
        return 'IncludeCustom'
    }
    return 'Unknown'
}

function New-DemoGoalPayload {
    return @{ properties=@{ requireZonalResiliency=$true } }
}

function Get-DemoDiscoveryQueries {
    param([string[]]$ResourceIds, [string]$ServiceGroupId)
    $chunks = [Collections.Generic.List[object]]::new()
    $current = [Collections.Generic.List[string]]::new()
    $length = 0
    foreach ($id in @($ResourceIds | Sort-Object -Unique)) {
        $literal = "'$($id.Replace("'","''"))'"
        if ($literal.Length -gt 4000) { throw 'A resource ID is too long for a safe discovery query.' }
        if ($current.Count -and $length + $literal.Length + 1 -gt 4000) {
            $chunks.Add(@($current))
            $current = [Collections.Generic.List[string]]::new()
            $length = 0
        }
        $current.Add($literal)
        $length += $literal.Length + 1
    }
    if ($current.Count) { $chunks.Add(@($current)) }
    if (!$chunks.Count) { throw 'Health discovery requires at least one target.' }
    for ($index = 0; $index -lt $chunks.Count; $index++) {
        $query = "resources | where id in~ ($($chunks[$index] -join ',')) | project id"
        if ($index -eq 0) { $query += " | union (resourcecontainers | where id =~ '$($ServiceGroupId.Replace("'","''"))' | project id)" }
        if ($query.Length -gt 5000) { throw 'Discovery query exceeds the service limit.' }
        $query
    }
}

function Wait-DemoReadinessJob {
    param($Context, [string]$PlanId, [string]$JobId, [switch]$AllowNewResources)
    $path = if ($JobId.StartsWith('/')) { $JobId } else {
        $parsed = [guid]::Empty
        if (![guid]::TryParse($JobId, [ref]$parsed)) { throw 'Readiness did not return a valid job ID.' }
        "$PlanId/recoveryJobs/$JobId"
    }
    if (!$path.StartsWith("$PlanId/recoveryJobs/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Readiness job belongs to a different plan.' }
    $deadline = [datetime]::UtcNow.AddMinutes($Context.ReadinessTimeoutMinutes)
    Write-Host "Waiting for actual readiness job: $path"
    do {
        $job = Invoke-DemoArm $Context -Path $path -ApiVersion '2026-06-01-preview' -AllowNotFound
        $status = Get-DemoValue $job 'properties.status'
        if ($status -eq 'Completed') { return $job }
        if ($status -in @('Failed','Canceled','Cancelled','CompletedWithWarnings')) {
            if ($AllowNewResources -and (Get-DemoValue $job 'properties.errorDetails.errorCode') -eq 'RHUBUserErrorAzureResourceAddedToServiceGroup') {
                Write-Warning 'Readiness discovered new resources; their inclusion/protection must be configured.'
                return $job
            }
            throw (Protect-DemoMessage $Context "Readiness job failed: $(ConvertTo-Json -InputObject $job.properties.errorDetails -Depth 20 -Compress)")
        }
        if ([datetime]::UtcNow -ge $deadline) { throw "Readiness job deadline exceeded: $path" }
        Start-Sleep -Seconds 10
    } while ($true)
}

function Invoke-DemoReadiness {
    param($Context, [string]$PlanId, [switch]$AllowNewResources)
    $result = Invoke-DemoArm $Context -Method POST -Path "$PlanId/checkReadiness" -ApiVersion '2026-06-01-preview' -OperationResult
    $jobId = Get-DemoValue $result 'jobId'
    if (!$jobId) { throw 'The readiness action did not return a jobId.' }
    return Wait-DemoReadinessJob $Context $PlanId $jobId -AllowNewResources:$AllowNewResources
}

function Invoke-DemoArg {
    param($Context, [string]$Query)
    return Invoke-DemoArm $Context -Method POST -Path '/providers/Microsoft.ResourceGraph/resources' -ApiVersion '2022-10-01' -Body @{
        query=$Query; options=@{ resultFormat='objectArray' }
    }
}

function Get-DemoRoles {
    return @{
        Reader='acdd72a7-3385-48ef-bd42-f606fba81ae7'
        ServiceGroupReader='de754d53-652d-4c75-a67f-1e48d8b49c97'
        MonitoringReader='43d0d8ad-25c7-4714-9337-8ba259a9fe05'
        MonitoringDataReader='b0d8363b-8ddd-447d-831f-62ca05bff136'
        MetricsPublisher='3913510d-42f4-4e42-8a64-420c390055eb'
        BlobContributor='ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        BlobOwner='b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
        QueueContributor='974c5e8b-45b9-4653-ba55-5f855dd0fb88'
        AutomationJobOperator='4fe576fe-1146-4730-92eb-48519fa6bf9f'
    }
}

function Invoke-DemoTemplate {
    param($Context, [string]$Name, [hashtable]$Parameters, [switch]$StartOnly, [switch]$ValidateOnly, [string]$DeploymentName=$Name)
    $jsonPath = Join-Path $Context.ScriptRoot "templates\$Name.json"
    if (Test-Path -LiteralPath $jsonPath) {
        $template = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -AsHashtable
    } else {
        $file = Join-Path $Context.ScriptRoot "templates\$Name.bicep"
        $compiled = Join-Path (Split-Path -Parent $Context.StatePath) "$Name.compiled.json"
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $compiled) -Force
        & az bicep build --file $file --outfile $compiled --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Template compilation failed: $Name" }
        $template = Get-Content -LiteralPath $compiled -Raw | ConvertFrom-Json -AsHashtable
    }
    $values = @{}
    foreach ($key in $Parameters.Keys) { $values[$key] = @{ value=$Parameters[$key] } }
    $id = "$($Context.State.resourceGroupId)/providers/Microsoft.Resources/deployments/$($Context.State.prefix)-$DeploymentName"
    $existing = Invoke-DemoArm $Context -Path $id -ApiVersion '2022-09-01' -AllowNotFound
    $existingStatus = Get-DemoValue $existing 'properties.provisioningState'
    if ($existingStatus -in @('Accepted','Running','Creating','Updating')) {
        Write-Host "Resuming the existing in-flight $Name deployment; no duplicate deployment is submitted."
        if ($ValidateOnly) { return }
        if ($StartOnly) { return @{ id=$id; name=$DeploymentName } }
        return Complete-DemoTemplate $Context $DeploymentName $id
    }
    if ($Name -eq 'network' -and $existingStatus -eq 'Succeeded') {
        $vnetId = Get-DemoValue $existing 'properties.outputs.vnetId.value'
        $vnet = if ($vnetId) { Invoke-DemoArm $Context -Path $vnetId -ApiVersion '2024-05-01' -AllowNotFound } else { $null }
        if ($vnet -and (Get-DemoValue $vnet 'tags.DrillDemoId') -eq $Context.State.demoId) {
            # ASE/SQL MI can add service-managed subnet policies; do not overwrite those on resume.
            Write-Host 'Preserving the existing owned network and its service-managed subnet configuration.'
            return Complete-DemoTemplate $Context $DeploymentName $id
        }
    }
    if ($Name -eq 'application' -and $existingStatus -eq 'Succeeded') {
        $targets = @(Get-DemoValue $existing 'properties.outputs.targets.value')
        if ($targets.Count -ne 9) { throw 'The successful application deployment has unexpected target outputs.' }
        foreach ($target in $targets) {
            if (!$target.id.StartsWith("$($Context.State.resourceGroupId)/providers/", [StringComparison]::OrdinalIgnoreCase) -or
                !$Context.Catalog.ContainsKey($target.kind)) { throw 'The existing application has an unexpected target ID or kind.' }
            $resource = Invoke-DemoArm $Context -Path $target.id -ApiVersion $Context.Catalog[$target.kind].ApiVersion -AllowNotFound
            if (!$resource -or (Get-DemoValue $resource 'tags.DrillDemoId') -ne $Context.State.demoId) {
                throw "A successful application's target is missing or no longer owned: $($target.id). Refusing to redeploy its network automatically."
            }
        }
        Write-Host 'Preserving the successful application deployment and its policy-managed network settings.'
        if ($ValidateOnly) { return }
        if ($StartOnly) { return @{ id=$id; name=$DeploymentName } }
        return Complete-DemoTemplate $Context $DeploymentName $id
    }
    if ($Name -eq 'application') {
        $networkId = "$($Context.State.resourceGroupId)/providers/Microsoft.Resources/deployments/$($Parameters.prefix)-vnetModule"
        $network = Invoke-DemoArm $Context -Path $networkId -ApiVersion '2022-09-01' -AllowNotFound
        if ((Get-DemoValue $network 'properties.provisioningState') -eq 'Succeeded') {
            $vnetId = Get-DemoValue $network 'properties.outputs.vnetId.value'
            if (!$vnetId -or !$vnetId.StartsWith("$($Context.State.resourceGroupId)/providers/Microsoft.Network/virtualNetworks/", [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Existing application network deployment returned an unexpected VNet ID.'
            }
            $vnet = Invoke-DemoArm $Context -Path $vnetId -ApiVersion '2024-05-01' -AllowNotFound
            if ($vnet) {
                if ((Get-DemoValue $vnet 'tags.DrillDemoId') -ne $Context.State.demoId) { throw 'Existing application network is not owned by this deployment.' }
                if ((Get-DemoValue $vnet 'properties.provisioningState') -ne 'Succeeded') { throw 'Existing application network has not finished provisioning; retry after it settles.' }
                $module = @($template.resources | Where-Object { $_.name -eq "[format('{0}-vnetModule', parameters('prefix'))]" })
                if ($module.Count -ne 1) { throw 'Application template has an unexpected network module.' }
                $module[0].condition = $false
                Write-Host 'Reusing the completed application network; preserving its policy-managed subnet settings during partial resume.'
            }
        }
    }
    Add-DemoRecord $Context $id 'Deployment' '2022-09-01'
    $body = @{ properties=@{ mode='Incremental'; template=$template; parameters=$values } }
    $null = Invoke-DemoArm $Context -Method POST -Path "$id/validate" -ApiVersion '2022-09-01' -Body $body
    if ($ValidateOnly) { return }
    $null = Invoke-DemoArm $Context -Method PUT -Path $id -ApiVersion '2022-09-01' -NoWait:$StartOnly -Body $body
    if ($StartOnly) { return @{ id=$id; name=$DeploymentName } }
    return Complete-DemoTemplate $Context $DeploymentName $id
}

function Complete-DemoTemplate {
    param($Context, [string]$Name, [string]$Id)
    $deployment = Wait-DemoResource $Context $Id '2022-09-01'
    $pending = [Collections.Generic.Queue[string]]::new()
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending.Enqueue($Id)
    while ($pending.Count) {
        $deploymentId = $pending.Dequeue()
        if (!$visited.Add($deploymentId)) { continue }
        foreach ($operation in @(Get-DemoList $Context "$deploymentId/operations" '2022-09-01')) {
            $resourceId = Get-DemoValue $operation 'properties.targetResource.id'
            if (!$resourceId) { $resourceId = Get-DemoValue $operation 'properties.targetResource.resourceId' }
            if ($resourceId -and $resourceId.StartsWith("$($Context.State.resourceGroupId)/", [StringComparison]::OrdinalIgnoreCase)) {
                Add-DemoRecord $Context $resourceId 'DeployedResource' ''
                if ((Get-DemoValue $operation 'properties.targetResource.resourceType') -eq 'Microsoft.Resources/deployments') {
                    $pending.Enqueue($resourceId)
                }
            }
        }
    }
    $outputs = @{}
    foreach ($key in $deployment.properties.outputs.Keys) { $outputs[$key] = $deployment.properties.outputs[$key].value }
    $Context.State.deployments[$Name] = @{ id=$Id; outputs=$outputs; verifiedAtUtc=[datetime]::UtcNow.ToString('o') }
    Save-DemoState $Context
    return $outputs
}

Export-ModuleMember -Function Get-DemoValue,Get-DemoGuid,Test-DemoResourceOwnership,Test-DemoPermission,ConvertTo-DemoLocation,Get-DemoArmUri,Get-DemoToken,Protect-DemoMessage,Invoke-DemoArm,Get-DemoList,Save-DemoState,Add-DemoRecord,Wait-DemoResource,Set-DemoOwnedResource,Grant-DemoRole,Get-DemoProtectionDecision,New-DemoGoalPayload,Get-DemoDiscoveryQueries,ConvertFrom-DemoOperation,Invoke-DemoReadiness,Wait-DemoReadinessJob,Invoke-DemoArg,Get-DemoRoles,Invoke-DemoTemplate,Complete-DemoTemplate
