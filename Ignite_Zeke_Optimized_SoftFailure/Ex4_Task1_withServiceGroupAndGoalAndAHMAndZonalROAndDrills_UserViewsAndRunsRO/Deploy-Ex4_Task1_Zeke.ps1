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
    Only Ex4_Task1 creates AHM/usage plan/enrollment/RO/Drill and attempts readiness.
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
    requires adjacent files. Ex4 readiness is bundled and uses Az PowerShell, not az CLI.
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
$RecoveryPlanName = $ConfigurationTemplate.parameters.zonalRecoveryPlanName.defaultValue
$DrillName = $ConfigurationTemplate.parameters.zonalDrillName.defaultValue

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
        Invoke-SoftAction 'RO/Drill readiness' {
            $readinessParameters = @{
                ServiceGroupId = $ServiceGroupScope
                RecoveryPlanId = "$ServiceGroupScope/providers/Microsoft.AzureResilienceManagement/recoveryPlans/$RecoveryPlanName"
                DrillId = "$ServiceGroupScope/providers/Microsoft.AzureResilienceManagement/drills/$DrillName"
                RhubArmEndpoint = 'https://management.azure.com'
                AzureContext = Get-AzContext -ErrorAction Stop
            }
            $staging = Join-Path ([IO.Path]::GetTempPath()) ("IgniteOptimizedSoftReadiness-" + [guid]::NewGuid().ToString('N'))
            try {
                $null = New-Item -ItemType Directory -Path (Join-Path $staging 'post-deployment')
                $readinessFiles = [ordered]@{
'Common.psm1' = @'
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
        $profile = $Context.AzureContext
        if (!$profile -or !$profile.Account -or !$profile.Tenant.Id -or !$profile.Subscription.Id) {
            throw 'An authenticated Az PowerShell context is required. Sign in with Connect-AzAccount.'
        }
        if ($profile.Tenant.Id -ne $Context.TenantId -or $profile.Subscription.Id -ne $Context.SubscriptionId) {
            throw 'The Az PowerShell context does not match the readiness tenant and subscription.'
        }
        $data = Get-AzAccessToken -ResourceUrl $Audience -TenantId $Context.TenantId -DefaultProfile $profile -ErrorAction Stop
        if (!$data.ExpiresOn) { throw 'Az PowerShell returned a token without an expiry.' }
        $expiry = ([DateTimeOffset]$data.ExpiresOn).UtcDateTime
        $token = $data.Token
        if ($token -is [securestring]) { $token = [Net.NetworkCredential]::new('', $token).Password }
        if ([string]::IsNullOrWhiteSpace($token) -or $expiry -le [datetime]::UtcNow) {
            throw 'Az PowerShell returned an expired or empty token.'
        }
        $cached = @{ Token=$token; Expires=$expiry }
        $Context.Tokens[$Audience] = $cached
        $Context.Secrets += $token
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

Export-ModuleMember -Function Get-DemoValue,Get-DemoGuid,Test-DemoResourceOwnership,Test-DemoPermission,ConvertTo-DemoLocation,Get-DemoArmUri,Get-DemoToken,Protect-DemoMessage,Invoke-DemoArm,Get-DemoList,Save-DemoState,Add-DemoRecord,Wait-DemoResource,Set-DemoOwnedResource,Grant-DemoRole,Get-DemoProtectionDecision,New-DemoGoalPayload,Get-DemoDiscoveryQueries,ConvertFrom-DemoOperation,Invoke-DemoReadiness,Wait-DemoReadinessJob,Invoke-DemoArg,Get-DemoRoles,Complete-DemoTemplate
'@
'post-deployment\Initialize-ZonalROAndDrill.ps1' = @'
#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory)][string]$ServiceGroupId,
    [string]$RecoveryPlanId,
    [string]$DrillId,
    [string]$RunbookId,
    [string]$AutomationResourceGroupId,
    [string]$AutomationLocation,
    [Nullable[int]]$FaultDurationInMinutes,
    [string]$StatePath,
    [string]$RhubArmEndpoint='https://management.azure.com',
    [ValidateRange(2,120)][int]$TimeoutMinutes=45,
    $AzureContext
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PostDeployment.ps1')
$context = New-PostDeploymentContext -Mode Zonal -ServiceGroupId $ServiceGroupId -RecoveryPlanId $RecoveryPlanId `
    -DrillId $DrillId -RunbookId $RunbookId -AutomationResourceGroupId $AutomationResourceGroupId `
    -AutomationLocation $AutomationLocation -FaultDurationInMinutes $FaultDurationInMinutes `
    -StatePath $StatePath -RhubArmEndpoint $RhubArmEndpoint -TimeoutMinutes $TimeoutMinutes -AzureContext $AzureContext
Show-PostDeploymentPlan $context
if (!$PSCmdlet.ShouldProcess($context.Drill.id, 'Configure existing Zonal RO and Drill to Ready, using native faults where available and NoOp fallback; do not execute')) { return }
Invoke-PostDeploymentWorkflow $context
'@
'post-deployment\PostDeployment.ps1' = @'
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
        [Nullable[int]]$FaultDurationInMinutes, [string]$StatePath, [string]$RhubArmEndpoint, [int]$TimeoutMinutes,
        $AzureContext
    )
    $ServiceGroupId = $ServiceGroupId.TrimEnd('/')
    Assert-PostArmId $ServiceGroupId '^/providers/Microsoft\.Management/serviceGroups/[^/]+$' 'service group'
    $endpoint = [uri]$RhubArmEndpoint
    if ($endpoint.Scheme -ne 'https' -or !$endpoint.IsDefaultPort -or $endpoint.UserInfo -or $endpoint.Query -or
        $endpoint.Fragment -or $endpoint.AbsolutePath -ne '/' -or
        ($endpoint.Host -ne 'management.azure.com' -and $endpoint.Host -notlike '*.management.azure.com')) { throw 'Invalid RHub ARM endpoint.' }
    $account = if ($AzureContext) { $AzureContext } else { Get-AzContext -ErrorAction Stop }
    if (!$account.Account -or !$account.Subscription.Id -or !$account.Tenant.Id) {
        throw 'Sign in with Connect-AzAccount to the tenant and subscription containing the SG.'
    }
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
        SubscriptionId=$account.Subscription.Id; TenantId=$account.Tenant.Id; AzureContext=$account
        RhubEndpoint=$RhubArmEndpoint.TrimEnd('/'); Tokens=@{}; Secrets=@()
        TimeoutMinutes=$TimeoutMinutes; ReadinessTimeoutMinutes=$TimeoutMinutes; Roles=(Get-DemoRoles)}
    $null = Invoke-DemoArm $ctx -Path $ServiceGroupId -ApiVersion '2024-02-01-preview'
    $members = Get-PostMemberIds $ctx
    if (($members[0] -split '/')[2] -ne $ctx.SubscriptionId) {
        throw 'The SG member subscription does not match the selected Az PowerShell context.'
    }
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
'@
'post-deployment\NoOp.ps1' = @'
param(
    [string]$OperationName,
    [string]$AzureResourceId,
    [string]$FailoverDirection,
    [string]$SourceLocation,
    [string]$PreferredTargetLocations,
    [string]$ResourceIds,
    [string]$Duration,
    [string]$TargetZone,
    [string]$FaultLocation
)

Write-Output 'SIMULATION ONLY: no Azure resource, replication, availability or data has been changed.'
Write-Output ("NoOp operation '{0}' completed at {1:o}." -f $OperationName, [datetime]::UtcNow)
'@
}
                foreach ($relative in $readinessFiles.Keys) {
                    [IO.File]::WriteAllText((Join-Path $staging $relative), $readinessFiles[$relative], [Text.UTF8Encoding]::new($false))
                }
                & (Join-Path $staging 'post-deployment\Initialize-ZonalROAndDrill.ps1') @readinessParameters
            } finally {
                if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop }
            }
        }
    }
} finally {
    Disconnect-ScopedSP $session
}
Show-LabSummary
Write-Host "Service Group: $ServiceGroupScope. Shared resource RG: $SharedResourceGroupName"
if (-not $HasGoal) { Write-Host 'Next: create zonal and regional goals manually for this Service Group.' }
