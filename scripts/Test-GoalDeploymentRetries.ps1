<#
.SYNOPSIS
    Offline regression checks for conditional goal assignments and inline runner guards.
.DESCRIPTION
    Extracts only Invoke-Deployment from each runner and mocks its Azure calls.
    No runner entry point or Azure operation is executed.
.PARAMETER Roots
    Template/script directories to check. Defaults to this repository's published labs.
#>
param(
    [string[]]$Roots = @(
        (Join-Path $PSScriptRoot '..\IgniteTemplates'),
        (Join-Path $PSScriptRoot '..\IgniteTest')
    )
)

$ErrorActionPreference = 'Stop'
$runnerCount = 0
$templateCount = 0

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

foreach ($root in $Roots) {
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
        if ($file.Extension -eq '.json') {
            $template = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            foreach ($goal in @($template.resources | Where-Object type -eq 'Microsoft.AzureResilienceManagement/goalAssignments')) {
                Assert-True ($template.parameters.deployGoalAssignment.type -eq 'bool') "$file`: missing goal switch."
                Assert-True ($template.parameters.deployGoalAssignment.defaultValue -eq $true) "$file`: fresh creation must remain enabled."
                Assert-True ($goal.condition -eq "[parameters('deployGoalAssignment')]") "$file`: unconditional goal."
                $templateCount++
            }
            continue
        }
        if ($file.Extension -ne '.ps1') { continue }
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -notmatch '\[switch\]\$IncludesGoalAssignment') { continue }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "$file`: PowerShell syntax errors."
        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Deployment'
        }, $true)
        Assert-True ($null -ne $functionAst) "$file`: missing deployment function."
        $commands = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Deployment'
        }, $true)
        foreach ($command in $commands) {
            if ($command.Extent.Text -match '\$step2Name') {
                Assert-True ($command.Extent.Text -match '-IncludesGoalAssignment') "$file`: step 2 bypasses goal discovery."
            } else {
                Assert-True ($command.Extent.Text -notmatch '-IncludesGoalAssignment') "$file`: step 1 must not check goals."
            }
        }

        & {
            param($Definition, $Label)
            . ([scriptblock]::Create($Definition))
            $ResourceGroupName = 'offline-rg'
            $serviceGroupId = '/providers/Microsoft.Management/serviceGroups/offline-sg'
            $serviceGroupName = 'offline-sg'
            $script:Calls = [System.Collections.Generic.List[object]]::new()
            $script:DiscoveryCalls = 0
            $script:StatusCode = 200
            $script:DiscoveryFailure = $false
            $script:DeploymentFailure = $false
            $script:Content = '{"value":[]}'

            function Write-Host {}
            function Invoke-AzRestMethod {
                [CmdletBinding()]
                param($Method, $Path)
                $script:DiscoveryCalls++
                $script:LastPath = $Path
                if ($script:DiscoveryFailure) { throw 'Discovery failure' }
                [pscustomobject]@{ StatusCode = $script:StatusCode; Content = $script:Content }
            }
            function New-AzResourceGroupDeployment {
                [CmdletBinding()]
                param($ResourceGroupName, $Name, $TemplateFile, $TemplateUri, $TemplateParameterObject)
                $script:Calls.Add([pscustomobject]@{
                    Parameters = if ($TemplateParameterObject) { $TemplateParameterObject.Clone() } else { @{} }
                    TemplateFile = $TemplateFile
                    TemplateUri = $TemplateUri
                })
                if ($script:DeploymentFailure) { throw 'Another resource failed' }
                [pscustomobject]@{ ProvisioningState = 'Succeeded' }
            }
            function Expect-Failure([string]$ExpectedMessage) {
                $before = $script:Calls.Count
                $failure = $null
                try { $null = Invoke-Deployment @argsForGoal } catch { $failure = $_ }
                Assert-True ($null -ne $failure -and $failure.Exception.Message -like "*$ExpectedMessage*") "$Label`: expected $ExpectedMessage; got $failure"
                Assert-True ($script:Calls.Count -eq $before) "$Label`: ARM deployment invoked after failed discovery."
            }

            $argsForGoal = @{ DeploymentName = 'step2'; TemplateUriOrPath = 'offline.json'; IsUri = $false; IncludesGoalAssignment = $true }
            $null = Invoke-Deployment @argsForGoal -TemplateParameterObject @{ customParameter = 'preserved' }
            Assert-True ($script:Calls[-1].Parameters.deployGoalAssignment -eq $true) "$Label`: missing goal not created."
            Assert-True ($script:Calls[-1].Parameters.customParameter -eq 'preserved') "$Label`: caller parameter lost."
            Assert-True ($script:Calls[-1].Parameters.serviceGroupName -eq 'offline-sg') "$Label`: SG not forwarded."
            Assert-True ($script:Calls[-1].TemplateFile -eq 'offline.json') "$Label`: local template lost."

            $script:Content = '{"value":[{"name":"zonal-ha-assign","properties":{"provisioningState":"Succeeded","requireZonalResiliency":true}}]}'
            $validContent = $script:Content
            $null = Invoke-Deployment @argsForGoal
            Assert-True ($script:Calls[-1].Parameters.deployGoalAssignment -eq $false) "$Label`: successful goal redeployed."

            $script:Content = '{"value":[]}'
            $script:DeploymentFailure = $true
            $failed = $false
            try { $null = Invoke-Deployment @argsForGoal } catch { $failed = $true }
            Assert-True $failed "$Label`: deployment failure swallowed."
            Assert-True ($script:Calls[-1].Parameters.deployGoalAssignment -eq $true) "$Label`: first retry case did not request creation."
            $script:DeploymentFailure = $false
            $script:Content = $validContent
            $null = Invoke-Deployment @argsForGoal
            Assert-True ($script:Calls[-1].Parameters.deployGoalAssignment -eq $false) "$Label`: retry did not rediscover successful goal."

            foreach ($state in @('Failed', 'Pending', 'Creating')) {
                $script:Content = $validContent.Replace('Succeeded', $state)
                Expect-Failure 'not a successful zonal goal'
            }
            foreach ($zonalValue in @('false', '"true"', 'null')) {
                $script:Content = $validContent.Replace(':true', ":$zonalValue")
                Expect-Failure 'not a successful zonal goal'
            }
            $script:Content = $validContent.Replace('zonal-ha-assign', 'different-goal')
            Expect-Failure 'do not match'
            $script:Content = '{"value":[{"name":"zonal-ha-assign"},{"name":"other"}]}'
            Expect-Failure 'do not match'
            foreach ($badResponse in @('{}', '{"value":null}', '{"value":{}}', '{"value":[],"nextLink":"more"}')) {
                $script:Content = $badResponse
                Expect-Failure 'incomplete response'
            }
            $script:Content = 'not-json'
            Expect-Failure 'JSON'
            $script:StatusCode = 403
            Expect-Failure 'HTTP 403'
            $script:StatusCode = 200
            $script:DiscoveryFailure = $true
            Expect-Failure 'Discovery failure'
            $script:DiscoveryFailure = $false

            $serviceGroupId = ''
            $serviceGroupName = ''
            Expect-Failure 'valid Service Group resource ID'
            $serviceGroupName = 'name-only-sg'
            $script:Content = '{"value":[]}'
            $null = Invoke-Deployment @argsForGoal
            Assert-True ($script:Calls[-1].Parameters.serviceGroupName -eq 'name-only-sg') "$Label`: name-only step-1 output unsupported."
            $uriArgs = $argsForGoal.Clone()
            $uriArgs.IsUri = $true
            $uriArgs.TemplateUriOrPath = 'https://example.invalid/template.json'
            $null = Invoke-Deployment @uriArgs -TemplateParameterObject @{ serviceGroupName = 'explicit-sg'; zonalGoalAssignmentName = 'custom-goal'; goalApiVersion = 'custom-version' }
            Assert-True ($script:LastPath -eq '/providers/Microsoft.Management/serviceGroups/explicit-sg/providers/Microsoft.AzureResilienceManagement/goalAssignments?api-version=custom-version') "$Label`: discovery overrides ignored."
            Assert-True ($script:Calls[-1].TemplateUri -eq $uriArgs.TemplateUriOrPath) "$Label`: remote template lost."
            $discoveryBefore = $script:DiscoveryCalls
            $null = Invoke-Deployment -DeploymentName 'step1' -TemplateUriOrPath 'step1.json' -IsUri $false
            Assert-True ($script:DiscoveryCalls -eq $discoveryBefore) "$Label`: step 1 queried goals."
            Assert-True (-not $script:Calls[-1].Parameters.ContainsKey('deployGoalAssignment')) "$Label`: step 1 received goal parameter."
        } $functionAst.Extent.Text $file.FullName
        $runnerCount++
    }
}
Assert-True ($runnerCount -gt 0 -and $templateCount -gt 0) 'No goal templates/runners found.'
Write-Output "PASS: $templateCount goal templates; $runnerCount runners; create/reuse/retry and error cases."
