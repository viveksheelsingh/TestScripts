#Requires -Version 7.2
<#
.SYNOPSIS
    Ex4_Task1: resource-reuse optimization with best-effort soft failure.
.DESCRIPTION
    Ex3_Task1 remains an independent full-resource deployment plus discovery-agent setup.
    Only Ex3_Task3 provisions the shared infrastructure used by Ex3_Task3, Ex3_Task4
    and Ex4_Task1. Later exercises create their own deployment RG and Service Group,
    but neither deploy nor delete shared infrastructure. SharedResourceGroupName selects
    the source RG; for Ex3_Task3 it follows ResourceGroupName.

    Every infrastructure module is attempted separately in dependency order, preserving
    the copied resource definitions, SKUs and native prerequisites. Each membership
    is a separate attempt in a nested deployment scoped to the shared source RG.
    Missing resources or a missing source RG do not gate goals or later configuration.
    Ex3_Task3 leaves goal creation to the learner. Ex3_Task4 attempts its zonal goal.
    Only Ex4_Task1 creates AHM/usage plan/enrollment/RO/Drill. It stops after creation.
    AHM lives in Ex4's own RG; its Reader assignment targets the shared source RG.
    Existing goals are checked before every attempt and are not overwritten.

    Resource/RBAC/configuration failures produce warnings and a final failure summary,
    not an aggregate script failure. Authentication, invalid inputs and missing/invalid
    templates remain fatal. Existing/partial RGs are never deleted or moved. Regional
    fallback may only remove a confirmed-empty RG created and tagged by this run.
    Successful resources are retained. The script does not execute a recovery or drill.

    Exactly one entry-point PS1 per exercise. Local templates are preferred; inline
    execution downloads ONLY this version's templates from Ignite_Zeke_Optimized_SoftFailure by default.
    Set TemplateBaseUri to an empty string to use bundled copies instead. UseLocalFiles
    requires adjacent files. Uses Az PowerShell, not az CLI.
    No post-creation RO/Drill configuration, runbook, NoOp or readiness workflow runs.
    Outside Skillable, infrastructure-owning exercises require AdministratorPassword
    as a SecureString. Later exercises do not require or pass that password.
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = '@lab.CloudSubscription.Id',
    [string] $ResourceGroupName = 'CaldovaPayApp_Ex4_Task1',
    [string] $Location = 'southcentralus',
    [string] $TemplateBaseUri = 'https://raw.githubusercontent.com/viveksheelsingh/TestScripts/main/Ignite_Zeke_Optimized_SoftFailure/Ex4_Task1_withServiceGroupAndGoalAndAHMAndZonalROAndDrills_UserViewsAndRunsRO',
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
$TaskName = 'Ex4_Task1'
$OwnsInfrastructure = $false
$LocationWasSpecified = $PSBoundParameters.ContainsKey('Location')

$EmbeddedTemplates = @{
'Ex4_Task1_Configuration.json' = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "metadata": {
    "description": "Independent shared-RG memberships and best-effort configuration phases; no all-membership success gate."
  },
  "parameters": {
    "location": {
      "type": "string",
      "defaultValue": "southcentralus"
    },
    "tags": {
      "type": "object",
      "defaultValue": {}
    },
    "serviceGroupName": {
      "type": "string",
      "minLength": 1,
      "defaultValue": "CaldovaPayApp_Ex4_Task1_SG",
      "metadata": {
        "description": "Name of the already-existing Service Group (created by step1) to assign a resilience goal to. Default matches step1's default naming formula so both templates chain together in the same resource group with no parameters."
      }
    },
    "serviceGroupDisplayName": {
      "type": "string",
      "defaultValue": "[parameters('serviceGroupName')]"
    },
    "serviceGroupParentId": {
      "type": "string",
      "defaultValue": "",
      "metadata": {
        "description": "Optional parent Service Group resource ID. Leave empty for a root-level Service Group (defaults to the tenant-root Service Group)."
      }
    },
    "healthModelName": {
      "type": "string",
      "defaultValue": "ahm-ex4-task1",
      "metadata": {
        "description": "Name of the Azure Health Model created by step1. Default matches step1's naming formula. Used to build the Health Model's own resourceId referenced by the Drill's healthModelMonitoringProperties.healthModelId."
      }
    },
    "sharedResourceGroupName": {
      "type": "string",
      "defaultValue": "CaldovaPayApp_Ex3_Task3"
    },
    "deployGoalAssignment": {
      "type": "bool",
      "defaultValue": true,
      "metadata": {
        "description": "Create the goal assignment. On retries or redeployment, set false only after verifying the existing goal has provisioningState Succeeded and requireZonalResiliency true. The PowerShell runners check this on every attempt and reuse the existing goal without another PUT."
      }
    },
    "zonalGoalAssignmentName": {
      "type": "string",
      "defaultValue": "zonal-ha-assign",
      "metadata": {
        "description": "Name of the goal assignment. Only one goalAssignment is allowed per Service Group."
      }
    },
    "goalAssignmentType": {
      "type": "string",
      "defaultValue": "Resiliency",
      "metadata": {
        "description": "Only 'Resiliency' is accepted."
      }
    },
    "goalApiVersion": {
      "type": "string",
      "defaultValue": "2026-08-31-preview",
      "metadata": {
        "description": "No separate goalTemplates resource is needed on this apiVersion or later. A standalone goalTemplates resource's write is hard-blocked (DisallowedResourceOperation) on every apiVersion - do not add one. goalTemplateId instead points at the Service Group's own resource ID. Do not set requireZonalResiliency explicitly - both true and false are currently rejected (RHUBUserErrorInvalidRequestParameter); omitting it yields the only supported default (true)."
      }
    },
    "usagePlanName": {
      "type": "string",
      "minLength": 3,
      "maxLength": 24,
      "defaultValue": "rhqtUsagePlan01",
      "metadata": {
        "description": "Name of the Standard Usage Plan (RG + subscription scoped)."
      }
    },
    "enrollmentName": {
      "type": "string",
      "defaultValue": "rhqtEnrollment01",
      "metadata": {
        "description": "Name of the enrollment child resource binding the Service Group to the Usage Plan."
      }
    },
    "zonalRecoveryPlanName": {
      "type": "string",
      "minLength": 5,
      "maxLength": 24,
      "defaultValue": "zonal-recovery-plan"
    },
    "zonalRecoveryPlanDescription": {
      "type": "string",
      "defaultValue": "Zonal recovery plan for Service Group",
      "minLength": 5,
      "maxLength": 50
    },
    "zonalRecoveryPlanGroupDescription": {
      "type": "string",
      "defaultValue": "Default recovery group",
      "minLength": 5,
      "maxLength": 50
    },
    "roApiVersion": {
      "type": "string",
      "defaultValue": "2026-06-01-preview",
      "metadata": {
        "description": "apiVersion for usagePlans/enrollments/recoveryPlans. A Usage Plan + Enrollment must exist before a recoveryPlans resource can be created against the Service Group (RHBLUserErrorNotEnrolled otherwise)."
      }
    },
    "zonalDrillName": {
      "type": "string",
      "minLength": 3,
      "maxLength": 24,
      "defaultValue": "zonal-drill-01",
      "metadata": {
        "description": "Name of the Drill. Pattern: letters, numbers, hyphens only, 3-24 chars."
      }
    },
    "drillRegion": {
      "type": "string",
      "defaultValue": "westcentralus",
      "metadata": {
        "description": "Region where the Drill's internal (Chaos/monitoring) resources are created. Must match an allowed region; hardcoded here like the IRM resource group."
      }
    },
    "drillApiVersion": {
      "type": "string",
      "defaultValue": "2026-10-01",
      "metadata": {
        "description": "2026-10-01 (GA) or 2026-09-30-preview. Do NOT use 2026-08-31-preview: its swagger declares healthModelMonitoringProperties.discoveryRuleId as the required field, but the backend actually serializes/expects healthModelId - causing GET to fail with HttpResponsePayloadAPISpecValidationFailed on that apiVersion once healthModelMonitoringProperties is set. The field is healthModelMonitoringProperties.healthModelId (the Health Model resource's own ARM Id) - NOT a discoveryRuleId as MS Learn's reference docs state. A Recovery Plan must already exist on the Service Group before the Drill can succeed. drillAssetProperties.resourceGroup MUST be set to an existing, tag-policy-compliant resource group (e.g. 'IRM')."
      }
    },
    "phase": {
      "type": "string",
      "defaultValue": "ServiceGroup",
      "allowedValues": [
        "ServiceGroup",
        "HealthModel",
        "Goal",
        "UsagePlan",
        "Enrollment",
        "RecoveryPlan",
        "Drill",
        "Membership"
      ]
    },
    "memberKey": {
      "type": "string",
      "defaultValue": "",
      "allowedValues": [
        "",
        "vnetId",
        "publicIpId",
        "loadBalancerId",
        "webVm1Id",
        "webVm2Id",
        "appVm1Id",
        "appVm2Id",
        "postgresId",
        "storageId"
      ]
    }
  },
  "variables": {
    "serviceGroupResourceId": "[format('/providers/Microsoft.Management/serviceGroups/{0}', parameters('serviceGroupName'))]",
    "serviceGroupRelationshipId": "[format('default{0}', parameters('serviceGroupName'))]",
    "vnetNameValue": "[format('vnet-{0}', uniqueString(variables('sharedResourceGroupId')))]",
    "publicIpNameValue": "[format('pubip-{0}', uniqueString(variables('sharedResourceGroupId')))]",
    "lbNameValue": "[format('web-lb-{0}', uniqueString(variables('sharedResourceGroupId')))]",
    "webVm1NameValue": "[format('web-vm-1-{0}', uniqueString(variables('sharedResourceGroupId')))]",
    "webVm2NameValue": "[format('web-vm-2-{0}', uniqueString(variables('sharedResourceGroupId')))]",
    "appVm1NameValue": "[format('app-vm-1-{0}', uniqueString(variables('sharedResourceGroupId')))]",
    "appVm2NameValue": "[format('app-vm-2-{0}', uniqueString(variables('sharedResourceGroupId')))]",
    "pgServerNameValue": "[format('pg-flex-{0}', uniqueString(variables('sharedResourceGroupId')))]",
    "storageNameValue": "[format('st{0}', uniqueString(variables('sharedResourceGroupId')))]",
    "healthModelNameValue": "[parameters('healthModelName')]",
    "sharedResourceGroupId": "[format('/subscriptions/{0}/resourceGroups/{1}', subscription().subscriptionId, parameters('sharedResourceGroupName'))]",
    "serviceGroupId": "[tenantResourceId('Microsoft.Management/serviceGroups', parameters('serviceGroupName'))]",
    "vnetId": "[resourceId(subscription().subscriptionId, parameters('sharedResourceGroupName'), 'Microsoft.Network/virtualNetworks', format('vnet-{0}', uniqueString(variables('sharedResourceGroupId'))))]",
    "publicIpId": "[resourceId(subscription().subscriptionId, parameters('sharedResourceGroupName'), 'Microsoft.Network/publicIPAddresses', format('pubip-{0}', uniqueString(variables('sharedResourceGroupId'))))]",
    "loadBalancerId": "[resourceId(subscription().subscriptionId, parameters('sharedResourceGroupName'), 'Microsoft.Network/loadBalancers', format('web-lb-{0}', uniqueString(variables('sharedResourceGroupId'))))]",
    "webVm1Id": "[resourceId(subscription().subscriptionId, parameters('sharedResourceGroupName'), 'Microsoft.Compute/virtualMachines', format('web-vm-1-{0}', uniqueString(variables('sharedResourceGroupId'))))]",
    "webVm2Id": "[resourceId(subscription().subscriptionId, parameters('sharedResourceGroupName'), 'Microsoft.Compute/virtualMachines', format('web-vm-2-{0}', uniqueString(variables('sharedResourceGroupId'))))]",
    "appVm1Id": "[resourceId(subscription().subscriptionId, parameters('sharedResourceGroupName'), 'Microsoft.Compute/virtualMachines', format('app-vm-1-{0}', uniqueString(variables('sharedResourceGroupId'))))]",
    "appVm2Id": "[resourceId(subscription().subscriptionId, parameters('sharedResourceGroupName'), 'Microsoft.Compute/virtualMachines', format('app-vm-2-{0}', uniqueString(variables('sharedResourceGroupId'))))]",
    "postgresId": "[resourceId(subscription().subscriptionId, parameters('sharedResourceGroupName'), 'Microsoft.DBforPostgreSQL/flexibleServers', format('pg-flex-{0}', uniqueString(variables('sharedResourceGroupId'))))]",
    "storageId": "[resourceId(subscription().subscriptionId, parameters('sharedResourceGroupName'), 'Microsoft.Storage/storageAccounts', format('st{0}', uniqueString(variables('sharedResourceGroupId'))))]"
  },
  "resources": [
    {
      "type": "Microsoft.Management/serviceGroups",
      "apiVersion": "2024-02-01-preview",
      "scope": "/",
      "name": "[parameters('serviceGroupName')]",
      "properties": "[createObject('displayName', parameters('serviceGroupDisplayName'), 'parent', createObject('resourceId', if(empty(parameters('serviceGroupParentId')), format('/providers/Microsoft.Management/serviceGroups/{0}', tenant().tenantId), parameters('serviceGroupParentId'))))]",
      "condition": "[equals(parameters('phase'), 'ServiceGroup')]"
    },
    {
      "type": "Microsoft.CloudHealth/healthmodels",
      "apiVersion": "2026-05-01-preview",
      "name": "[variables('healthModelNameValue')]",
      "location": "[parameters('location')]",
      "identity": {
        "type": "SystemAssigned"
      },
      "tags": "[parameters('tags')]",
      "properties": {},
      "condition": "[equals(parameters('phase'), 'HealthModel')]"
    },
    {
      "type": "Microsoft.CloudHealth/healthmodels/authenticationsettings",
      "apiVersion": "2026-05-01-preview",
      "name": "[format('{0}/default-auth', variables('healthModelNameValue'))]",
      "properties": {
        "displayName": "Default Authentication",
        "authenticationKind": "ManagedIdentity",
        "managedIdentityName": "SystemAssigned"
      },
      "dependsOn": [
        "[resourceId('Microsoft.CloudHealth/healthmodels', variables('healthModelNameValue'))]"
      ],
      "condition": "[equals(parameters('phase'), 'HealthModel')]"
    },
    {
      "type": "Microsoft.CloudHealth/healthmodels/discoveryrules",
      "apiVersion": "2026-05-01-preview",
      "name": "[format('{0}/{1}', variables('healthModelNameValue'), variables('healthModelNameValue'))]",
      "properties": {
        "displayName": "Discover Service Group Resources",
        "authenticationSetting": "default-auth",
        "discoverRelationships": "Enabled",
        "addRecommendedSignals": "Enabled",
        "addResourceHealthSignal": "Enabled",
        "specification": {
          "kind": "ResourceGraphQuery",
          "resourceGraphQuery": "[format('relationshipresources | where type =~ ''microsoft.relationships/servicegroupmember'' | where tostring(properties.TargetId) =~ ''{0}'' | project id=tostring(properties.SourceId) | union (resourcecontainers | where id =~ ''{0}'' | project id)', variables('serviceGroupResourceId'))]"
        }
      },
      "dependsOn": [
        "[resourceId('Microsoft.CloudHealth/healthmodels', variables('healthModelNameValue'))]",
        "[resourceId('Microsoft.CloudHealth/healthmodels/authenticationsettings', variables('healthModelNameValue'), 'default-auth')]"
      ],
      "condition": "[equals(parameters('phase'), 'HealthModel')]"
    },
    {
      "type": "Microsoft.AzureResilienceManagement/goalAssignments",
      "condition": "[and(equals(parameters('phase'), 'Goal'), parameters('deployGoalAssignment'))]",
      "apiVersion": "[parameters('goalApiVersion')]",
      "name": "[parameters('zonalGoalAssignmentName')]",
      "scope": "[variables('serviceGroupId')]",
      "properties": {
        "goalAssignmentType": "[parameters('goalAssignmentType')]",
        "goalTemplateId": "[variables('serviceGroupId')]"
      }
    },
    {
      "type": "Microsoft.AzureResilienceManagement/usagePlans",
      "apiVersion": "[parameters('roApiVersion')]",
      "name": "[parameters('usagePlanName')]",
      "location": "global",
      "tags": {},
      "properties": {
        "planType": "Standard"
      },
      "condition": "[equals(parameters('phase'), 'UsagePlan')]"
    },
    {
      "type": "Microsoft.AzureResilienceManagement/usagePlans/enrollments",
      "apiVersion": "[parameters('roApiVersion')]",
      "name": "[format('{0}/{1}', parameters('usagePlanName'), parameters('enrollmentName'))]",
      "properties": {
        "serviceGroupId": "[variables('serviceGroupId')]"
      },
      "dependsOn": [
        "[resourceId('Microsoft.AzureResilienceManagement/usagePlans', parameters('usagePlanName'))]"
      ],
      "condition": "[equals(parameters('phase'), 'Enrollment')]"
    },
    {
      "type": "Microsoft.AzureResilienceManagement/recoveryPlans",
      "apiVersion": "[parameters('roApiVersion')]",
      "name": "[parameters('zonalRecoveryPlanName')]",
      "scope": "[variables('serviceGroupId')]",
      "identity": {
        "type": "SystemAssigned"
      },
      "properties": {
        "planType": "Zonal",
        "planDescription": "[parameters('zonalRecoveryPlanDescription')]",
        "recoveryGroupsSetting": {
          "defaultGroup": {
            "properties": {
              "groupUniqueId": "[guid(parameters('serviceGroupName'), parameters('zonalRecoveryPlanName'), 'defaultGroup')]",
              "description": "[parameters('zonalRecoveryPlanGroupDescription')]",
              "orderId": 0
            }
          },
          "additionalGroups": []
        }
      },
      "dependsOn": [
        "[resourceId('Microsoft.AzureResilienceManagement/usagePlans/enrollments', parameters('usagePlanName'), parameters('enrollmentName'))]"
      ],
      "condition": "[equals(parameters('phase'), 'RecoveryPlan')]"
    },
    {
      "type": "Microsoft.AzureResilienceManagement/drills",
      "apiVersion": "[parameters('drillApiVersion')]",
      "name": "[parameters('zonalDrillName')]",
      "scope": "[variables('serviceGroupId')]",
      "identity": {
        "type": "SystemAssigned"
      },
      "properties": {
        "drillType": "Zonal",
        "rbacSetupMode": "AutomatedBuiltinRoles",
        "drillAssetProperties": {
          "region": "[parameters('drillRegion')]",
          "resourceGroup": "IRM",
          "subscription": "[subscription().subscriptionId]"
        },
        "chaosResourceProperties": {
          "chaosResourceIdentityForFaults": {
            "type": "SystemAssigned"
          },
          "identity": {
            "type": "SystemAssigned"
          }
        },
        "recoveryPlanProperties": {
          "identity": {
            "type": "SystemAssigned"
          }
        },
        "monitoringProperties": {
          "identity": {
            "type": "SystemAssigned"
          }
        },
        "healthModelMonitoringProperties": {
          "healthModelId": "[resourceId('Microsoft.CloudHealth/healthmodels', variables('healthModelNameValue'))]",
          "identity": {
            "type": "SystemAssigned"
          }
        }
      },
      "dependsOn": [
        "[extensionResourceId(variables('serviceGroupId'), 'Microsoft.AzureResilienceManagement/recoveryPlans', parameters('zonalRecoveryPlanName'))]"
      ],
      "condition": "[equals(parameters('phase'), 'Drill')]"
    },
    {
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2025-04-01",
      "name": "[format('shared-membership-{0}-{1}', parameters('memberKey'), uniqueString(parameters('serviceGroupName')))]",
      "condition": "[equals(parameters('phase'), 'Membership')]",
      "subscriptionId": "[subscription().subscriptionId]",
      "resourceGroup": "[parameters('sharedResourceGroupName')]",
      "properties": {
        "mode": "Incremental",
        "expressionEvaluationOptions": {
          "scope": "inner"
        },
        "parameters": {
          "serviceGroupName": {
            "value": "[parameters('serviceGroupName')]"
          },
          "memberKey": {
            "value": "[parameters('memberKey')]"
          },
          "vnetId": {
            "value": "[variables('vnetId')]"
          },
          "publicIpId": {
            "value": "[variables('publicIpId')]"
          },
          "loadBalancerId": {
            "value": "[variables('loadBalancerId')]"
          },
          "webVm1Id": {
            "value": "[variables('webVm1Id')]"
          },
          "webVm2Id": {
            "value": "[variables('webVm2Id')]"
          },
          "appVm1Id": {
            "value": "[variables('appVm1Id')]"
          },
          "appVm2Id": {
            "value": "[variables('appVm2Id')]"
          },
          "postgresId": {
            "value": "[variables('postgresId')]"
          },
          "storageId": {
            "value": "[variables('storageId')]"
          }
        },
        "template": {
          "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
          "contentVersion": "1.0.0.0",
          "parameters": {
            "serviceGroupName": {
              "type": "string"
            },
            "memberKey": {
              "type": "string"
            },
            "vnetId": {
              "type": "string"
            },
            "publicIpId": {
              "type": "string"
            },
            "loadBalancerId": {
              "type": "string"
            },
            "webVm1Id": {
              "type": "string"
            },
            "webVm2Id": {
              "type": "string"
            },
            "appVm1Id": {
              "type": "string"
            },
            "appVm2Id": {
              "type": "string"
            },
            "postgresId": {
              "type": "string"
            },
            "storageId": {
              "type": "string"
            }
          },
          "variables": {
            "serviceGroupId": "[tenantResourceId('Microsoft.Management/serviceGroups', parameters('serviceGroupName'))]",
            "serviceGroupRelationshipId": "[format('default{0}', parameters('serviceGroupName'))]"
          },
          "resources": [
            {
              "type": "Microsoft.Relationships/serviceGroupMember",
              "apiVersion": "2023-09-01-preview",
              "name": "[variables('serviceGroupRelationshipId')]",
              "scope": "[parameters('vnetId')]",
              "properties": {
                "targetId": "[variables('serviceGroupId')]"
              },
              "condition": "[equals(parameters('memberKey'), 'vnetId')]"
            },
            {
              "type": "Microsoft.Relationships/serviceGroupMember",
              "apiVersion": "2023-09-01-preview",
              "name": "[variables('serviceGroupRelationshipId')]",
              "scope": "[parameters('publicIpId')]",
              "properties": {
                "targetId": "[variables('serviceGroupId')]"
              },
              "condition": "[equals(parameters('memberKey'), 'publicIpId')]"
            },
            {
              "type": "Microsoft.Relationships/serviceGroupMember",
              "apiVersion": "2023-09-01-preview",
              "name": "[variables('serviceGroupRelationshipId')]",
              "scope": "[parameters('loadBalancerId')]",
              "properties": {
                "targetId": "[variables('serviceGroupId')]"
              },
              "condition": "[equals(parameters('memberKey'), 'loadBalancerId')]"
            },
            {
              "type": "Microsoft.Relationships/serviceGroupMember",
              "apiVersion": "2023-09-01-preview",
              "name": "[variables('serviceGroupRelationshipId')]",
              "scope": "[parameters('webVm1Id')]",
              "properties": {
                "targetId": "[variables('serviceGroupId')]"
              },
              "condition": "[equals(parameters('memberKey'), 'webVm1Id')]"
            },
            {
              "type": "Microsoft.Relationships/serviceGroupMember",
              "apiVersion": "2023-09-01-preview",
              "name": "[variables('serviceGroupRelationshipId')]",
              "scope": "[parameters('webVm2Id')]",
              "properties": {
                "targetId": "[variables('serviceGroupId')]"
              },
              "condition": "[equals(parameters('memberKey'), 'webVm2Id')]"
            },
            {
              "type": "Microsoft.Relationships/serviceGroupMember",
              "apiVersion": "2023-09-01-preview",
              "name": "[variables('serviceGroupRelationshipId')]",
              "scope": "[parameters('appVm1Id')]",
              "properties": {
                "targetId": "[variables('serviceGroupId')]"
              },
              "condition": "[equals(parameters('memberKey'), 'appVm1Id')]"
            },
            {
              "type": "Microsoft.Relationships/serviceGroupMember",
              "apiVersion": "2023-09-01-preview",
              "name": "[variables('serviceGroupRelationshipId')]",
              "scope": "[parameters('appVm2Id')]",
              "properties": {
                "targetId": "[variables('serviceGroupId')]"
              },
              "condition": "[equals(parameters('memberKey'), 'appVm2Id')]"
            },
            {
              "type": "Microsoft.Relationships/serviceGroupMember",
              "apiVersion": "2023-09-01-preview",
              "name": "[variables('serviceGroupRelationshipId')]",
              "scope": "[parameters('postgresId')]",
              "properties": {
                "targetId": "[variables('serviceGroupId')]"
              },
              "condition": "[equals(parameters('memberKey'), 'postgresId')]"
            },
            {
              "type": "Microsoft.Relationships/serviceGroupMember",
              "apiVersion": "2023-09-01-preview",
              "name": "[variables('serviceGroupRelationshipId')]",
              "scope": "[parameters('storageId')]",
              "properties": {
                "targetId": "[variables('serviceGroupId')]"
              },
              "condition": "[equals(parameters('memberKey'), 'storageId')]"
            }
          ]
        }
      }
    }
  ],
  "outputs": {
    "serviceGroupId": {
      "type": "string",
      "value": "[tenantResourceId('Microsoft.Management/serviceGroups', parameters('serviceGroupName'))]"
    },
    "vnetId": {
      "type": "string",
      "value": "[variables('vnetId')]"
    },
    "publicIpId": {
      "type": "string",
      "value": "[variables('publicIpId')]"
    },
    "loadBalancerId": {
      "type": "string",
      "value": "[variables('loadBalancerId')]"
    },
    "webVm1Id": {
      "type": "string",
      "value": "[variables('webVm1Id')]"
    },
    "webVm2Id": {
      "type": "string",
      "value": "[variables('webVm2Id')]"
    },
    "appVm1Id": {
      "type": "string",
      "value": "[variables('appVm1Id')]"
    },
    "appVm2Id": {
      "type": "string",
      "value": "[variables('appVm2Id')]"
    },
    "postgresId": {
      "type": "string",
      "value": "[variables('postgresId')]"
    },
    "storageId": {
      "type": "string",
      "value": "[variables('storageId')]"
    }
  }
}
'@
}

$HasGoal = $true
$HasHealthModel = $true
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
            if ($Stage -eq 'Goal') { Invoke-SoftGoalGuard -Parameters $Parameters }
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
        foreach ($module in $Template.resources) {
            # Cross-module ordering is now handled here; output references still enforce prerequisites.
            $unit = $Template.Clone()
            $resource = $module.Clone()
            $resource.Remove('dependsOn')
            $unit.resources = @($resource)
            $arguments = @{ Stage = "Infrastructure-$($module.name)"; Template = $unit; Parameters = $Parameters }
            if ($TaskName -eq 'Ex3_Task1') { $arguments.MaxAttempts = 3; $arguments.DelaySeconds = 180 }
            else { $arguments.MaxAttempts = 2; $arguments.DelaySeconds = 120; $arguments.StopOnAllocationError = $true }
            try { $null = Invoke-LabDeployment @arguments }
            catch {
                $regionFailures.Add([pscustomobject]@{
                    Stage = "Infrastructure/$($module.name)"
                    Message = $_.Exception.Message
                })
                Write-Warning "$($module.name) in '$region' failed: $($_.Exception.Message). Continuing with the next module."
            }
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
$HealthModelName = $ConfigurationTemplate.parameters.healthModelName.defaultValue

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

function Invoke-SoftGoalGuard {
    param([hashtable] $Parameters)
    $api = $ConfigurationTemplate.parameters.goalApiVersion.defaultValue
    $name = $ConfigurationTemplate.parameters.zonalGoalAssignmentName.defaultValue
    $response = Invoke-AzRestMethod -Method GET `
        -Path "$ServiceGroupScope/providers/Microsoft.AzureResilienceManagement/goalAssignments?api-version=$api" -ErrorAction Stop
    if ($response.StatusCode -ne 200) { throw "Goal lookup returned HTTP $($response.StatusCode)." }
    $goals = $response.Content | ConvertFrom-Json -ErrorAction Stop
    if (-not $goals.PSObject.Properties['value'] -or $goals.value -isnot [array] -or $goals.nextLink) {
        throw 'Goal lookup was incomplete; refusing to overwrite an existing goal.'
    }
    $existing = @($goals.value)
    if ($existing.Count -gt 1 -or ($existing.Count -eq 1 -and $existing[0].name -ne $name)) {
        throw 'An unexpected goal already exists; refusing to overwrite it.'
    }
    if ($existing.Count -and ($existing[0].properties.provisioningState -ne 'Succeeded' -or
            $existing[0].properties.requireZonalResiliency -isnot [bool] -or
            $existing[0].properties.requireZonalResiliency -ne $true)) {
        throw 'The existing goal is not a successful zonal goal; refusing to overwrite it.'
    }
    $Parameters.deployGoalAssignment = $existing.Count -eq 0
}

function Get-HealthModelPrincipal {
    Invoke-WithRetry {
        $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.CloudHealth/healthmodels/${HealthModelName}?api-version=2026-05-01-preview"
        $response = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
        if ($response.StatusCode -ne 200) { throw "Health model lookup returned HTTP $($response.StatusCode)." }
        $principal = ($response.Content | ConvertFrom-Json).identity.principalId
        if ($principal -notmatch $GuidPattern) { throw 'The health model identity is not yet available.' }
        return $principal
    }
}

foreach ($value in @($TenantId, $ScopedAppId, $ScopedAppObjectId)) {
    if ($value -notmatch $GuidPattern) { throw 'Resolve the Skillable tenant/scoped-app placeholders or supply explicit parameters.' }
}
if ($context.Tenant.Id -ne $TenantId -or $LabInstanceId -notmatch '^[0-9]+$' -or
        -not $Regions.Count -or @($Regions | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
    throw 'Supply the signed-in tenant, numeric lab instance ID and valid fallback regions.'
}
if ($OwnsInfrastructure) { $SharedResourceGroupName = $ResourceGroupName }
if ([string]::IsNullOrWhiteSpace($SharedResourceGroupName) -or
        (-not $OwnsInfrastructure -and $ResourceGroupName -eq $SharedResourceGroupName)) {
    throw 'Later exercises require a separate deployment RG and a nonempty shared source RG name.'
}
$identities = @{ UserId = $null; AdministratorRole = $null; ReaderRole = $null }
Invoke-SoftAction 'Learner lookup' {
    $identities.UserId = (Invoke-RestMethod -Headers (Get-GraphHeader) `
        -Uri "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($UserUpn))?`$select=id" -ErrorAction Stop).id
    if ($identities.UserId -notmatch $GuidPattern) { throw 'The lab user was not found in Entra ID.' }
}
Invoke-SoftAction 'Administrator role lookup' {
    $identities.AdministratorRole = Get-BuiltInRoleId -RoleName 'Service Group Administrator'
}
if ($HasHealthModel) {
    Invoke-SoftAction 'Reader role lookup' {
        $identities.ReaderRole = Get-BuiltInRoleId -RoleName 'Service Group Reader'
    }
}
$session = $null
try {
    $session = Connect-ScopedSP -SecretLifetimeMinutes 90
    Start-Sleep -Seconds 60
    $token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
    if (-not $token.Token) { throw 'Failed to refresh the scoped ARM access token.' }
    $token = $null
    if ($OwnsInfrastructure) {
        Invoke-SoftAction 'Infrastructure' {
            $null = Invoke-Infrastructure -Template $InfrastructureTemplate `
                -Parameters @{ location = $Location; administratorPassword = $AdministratorPassword }
        }
    } else {
        Invoke-SoftAction 'Deployment RG' {
            $group = Get-LabResourceGroup $ResourceGroupName
            if ($group) { $Deployment.Location = $group.Location }
            else { $null = New-LabResourceGroup -Name $ResourceGroupName -Region $Location }
        }
    }
    Invoke-SoftAction 'Service Group' { $null = Invoke-Configuration 'ServiceGroup' }
    Start-Sleep -Seconds 120
    $token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop
    if (-not $token.Token) { throw 'Failed to refresh the scoped ARM access token.' }
    $token = $null
    Invoke-SoftAction 'Learner SG Administrator' {
        Grant-LabRole -PrincipalId $identities.UserId -RoleId $identities.AdministratorRole -Scope $ServiceGroupScope -PrincipalType User
    }
    if ($HasHealthModel) {
        Invoke-SoftAction 'Application Health Model' { $null = Invoke-Configuration 'HealthModel' }
        Invoke-SoftAction 'AHM shared RG Reader' {
            Grant-LabRole -PrincipalId (Get-HealthModelPrincipal) -RoleId 'acdd72a7-3385-48ef-bd42-f606fba81ae7' `
                -Scope "/subscriptions/$SubscriptionId/resourceGroups/$SharedResourceGroupName" -PrincipalType ServicePrincipal
        }
        Invoke-SoftAction 'AHM SG Reader' {
            Grant-LabRole -PrincipalId (Get-HealthModelPrincipal) -RoleId $identities.ReaderRole `
                -Scope $ServiceGroupScope -PrincipalType ServicePrincipal
        }
    }
    foreach ($member in 'vnetId','publicIpId','loadBalancerId','webVm1Id','webVm2Id','appVm1Id','appVm2Id','postgresId','storageId') {
        Invoke-SoftAction "Membership $member" { $null = Invoke-Configuration -Phase 'Membership' -Member $member }
    }
    if ($HasGoal) {
        Invoke-SoftAction 'Goal' { $null = Invoke-Configuration 'Goal' }
    }
    if ($HasHealthModel) {
        foreach ($phase in 'UsagePlan','Enrollment','RecoveryPlan','Drill') {
            Invoke-SoftAction $phase { $null = Invoke-Configuration $phase }
        }
    }
} finally {
    Disconnect-ScopedSP $session
}
Show-LabSummary
Write-Host "Service Group: $ServiceGroupScope. Shared resource RG: $SharedResourceGroupName"
if (-not $HasGoal) { Write-Host 'Next: create zonal and regional goals manually for this Service Group.' }
