<#
.SYNOPSIS
    Checks that the Ex4 entry point and runners use production ARM for step 3.
.DESCRIPTION
    Parses scripts and exercises URI construction offline. No Azure calls are made.
#>
param(
    [string]$TemplateRoot = (Join-Path $PSScriptRoot '..\IgniteTemplates')
)

$ErrorActionPreference = 'Stop'
$splitRoot = Join-Path $TemplateRoot 'SGMSGSplitIgniteScripts'
$entryPoint = Join-Path $splitRoot 'post-deployment\Initialize-ZonalROAndDrill.ps1'
$production = 'https://management.azure.com'

function Read-ScriptAst([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}

$entryAst = Read-ScriptAst $entryPoint
$endpointParameter = @($entryAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RhubArmEndpoint' })
if ($endpointParameter.Count -ne 1 -or $endpointParameter[0].DefaultValue.SafeGetValue() -ne $production) {
    throw 'Step-3 entry point does not default to production ARM.'
}

$serviceGroupId = '/providers/Microsoft.Management/serviceGroups/offline-sg'
$step2Result = @{
    Outputs = @{
        recoveryPlanId = @{ Value = "$serviceGroupId/providers/Microsoft.AzureResilienceManagement/recoveryPlans/plan" }
        drillId = @{ Value = "$serviceGroupId/providers/Microsoft.AzureResilienceManagement/drills/drill" }
    }
}
foreach ($relative in @('Ex4_Task1_Deploy-Step1ThenStep2.ps1', 'SGMSGSplitIgniteScripts\SGMSGSplit_Ex4_Task1_Deploy-Step1ThenStep2.ps1')) {
    $ast = Read-ScriptAst (Join-Path $TemplateRoot $relative)
    $assignment = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq 'step3Params'
    }, $true))
    if ($assignment.Count -ne 1) { throw "$relative`: expected one step-3 parameter map." }
    $parameters = & ([scriptblock]::Create($assignment[0].Right.Extent.Text))
    if ($parameters.RhubArmEndpoint -ne $production -or
        $parameters.ServiceGroupId -ne $serviceGroupId -or
        $parameters.RecoveryPlanId -ne $step2Result.Outputs.recoveryPlanId.Value -or
        $parameters.DrillId -ne $step2Result.Outputs.drillId.Value) {
        throw "$relative`: step-3 production endpoint or deployed IDs are incorrect."
    }
}

Import-Module (Join-Path $splitRoot 'Common.psm1') -Force -DisableNameChecking
$context = @{ RhubEndpoint = $production }
$planPath = "$serviceGroupId/providers/Microsoft.AzureResilienceManagement/recoveryPlans/plan"
$uri = Get-DemoArmUri $context $planPath '2026-06-01-preview'
if ($uri.AbsoluteUri -ne "$production$planPath`?api-version=2026-06-01-preview") {
    throw 'RHub requests do not resolve to production ARM.'
}
$resourcePath = '/subscriptions/offline/resourceGroups/offline'
$uri = Get-DemoArmUri $context $resourcePath '2024-03-01'
if ($uri.Host -ne 'management.azure.com') { throw 'Non-RHub requests changed endpoint.' }
Write-Output 'PASS: Ex4 entry point, both runners and ARM URI routing use production.'
