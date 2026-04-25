// =============================================================================
// App Gateway RBAC — role assignments for the deployment script UAMI
//
// This module runs in DEVUAT-ASE-RG (the App Gateway's resource group).
// It grants the UAMI (from appgw-integration.bicep) the minimum permissions
// needed to update the App Gateway backend pool via az cli.
//
// Background — why multiple roles are required:
//
//   `az network application-gateway address-pool update` has no PATCH support.
//   The Azure Application Gateway REST API only exposes a full PUT for the
//   entire resource (confirmed: Microsoft REST API reference 2024-10-01).
//   The CLI does a GET → mutate pool → PUT cycle. ARM validates the caller's
//   permissions against EVERY resource referenced in the PUT body. This
//   produces a cascade of "linked authorization" checks beyond simple write
//   access to the App Gateway itself.
//
// -----------------------------------------------------------------------------
// Role 1 — Network Contributor on DEVUAT-ASE-APPGWV2-03
// -----------------------------------------------------------------------------
// Scope   : The App Gateway resource (not the whole RG)
// Allows  : Microsoft.Network/* on the App Gateway — required to write it
//
// -----------------------------------------------------------------------------
// Role 2 — Managed Identity Operator on KP_NonProd_AppGw_KV_MI
// -----------------------------------------------------------------------------
// Scope   : The specific existing UAMI resource (not the whole RG)
// Why     : The App Gateway has KP_NonProd_AppGw_KV_MI in its identity block.
//           Any PUT that carries a UAMI reference triggers ARM's linked
//           authorization check: the caller must have assign/action on every
//           UAMI in the body. Managed Identity Operator (f1a07417-...) grants
//           exactly Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action.
//           Controlled by param appGatewayExistingUamiName (optional).
//
// -----------------------------------------------------------------------------
// Role 3 — Network Contributor on DEVUAT-APPGWV2-SUBNET
// -----------------------------------------------------------------------------
// Scope   : The specific subnet the App Gateway's gateway IP config references
// Why     : The PUT body includes gatewayIPConfigurations[*].properties.subnet.id.
//           ARM requires Microsoft.Network/virtualNetworks/subnets/join/action
//           on any subnet referenced in a network resource PUT. Network
//           Contributor on the App Gateway resource alone does NOT propagate
//           to the subnet. This role is scoped to the one subnet only.
//           Controlled by params appGatewayVnetName + appGatewaySubnetName (optional).
//
// Requires: the deployment principal must have Owner on DEVUAT-ASE-RG or
// subscription to create role assignments (confirmed: Owner-level access).
// =============================================================================

targetScope = 'resourceGroup'

@description('Name of the existing Application Gateway (e.g., "DEVUAT-ASE-APPGWV2-03")')
param appGatewayName string

@description('Principal ID of the UAMI created by appgw-integration.bicep')
param uamiPrincipalId string

@description('Name of an existing User-Assigned Managed Identity already attached to the App Gateway (e.g., "KP_NonProd_AppGw_KV_MI"). When set, grants our UAMI Managed Identity Operator on it so that the full GET+PUT passes the linked authorization check. Leave empty if the App Gateway has no attached UAMIs.')
param appGatewayExistingUamiName string = ''

@description('Name of the VNet containing the App Gateway (e.g., "DEVUAT-APP-VNET"). Required when appGatewaySubnetName is set.')
param appGatewayVnetName string = ''

@description('Name of the subnet the App Gateway is attached to (e.g., "DEVUAT-APPGWV2-SUBNET"). When set, grants our UAMI Network Contributor on it — required because the App Gateway PUT body references this subnet, triggering a join/action check. Leave empty if not needed.')
param appGatewaySubnetName string = ''

// Built-in role IDs
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'
var managedIdentityOperatorRoleId = 'f1a07417-d97a-45cb-824c-7a7467783830'

var enableManagedIdentityOperator = !empty(appGatewayExistingUamiName)
var enableSubnetNetworkContributor = !empty(appGatewayVnetName) && !empty(appGatewaySubnetName)

// ---------------------------------------------------------------------------
// Referenced resources (existing)
// ---------------------------------------------------------------------------
resource appGateway 'Microsoft.Network/applicationGateways@2023-05-01' existing = {
  name: appGatewayName
}

resource existingAppGwUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (enableManagedIdentityOperator) {
  name: enableManagedIdentityOperator ? appGatewayExistingUamiName : 'placeholder'
}

resource appGatewayVnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing = if (enableSubnetNetworkContributor) {
  name: enableSubnetNetworkContributor ? appGatewayVnetName : 'placeholder'
}

resource appGatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' existing = if (enableSubnetNetworkContributor) {
  parent: appGatewayVnet
  name: enableSubnetNetworkContributor ? appGatewaySubnetName : 'placeholder'
}

// ---------------------------------------------------------------------------
// Role 1 — Network Contributor on the App Gateway resource
// ---------------------------------------------------------------------------
resource networkContributorOnAppGw 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appGateway
  name: guid(appGateway.id, uamiPrincipalId, networkContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: uamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Role 2 — Managed Identity Operator on the pre-existing App Gateway UAMI
// Required to pass the linked auth check when the PUT body carries that UAMI.
// ---------------------------------------------------------------------------
resource managedIdentityOperatorOnUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableManagedIdentityOperator) {
  scope: existingAppGwUami
  name: guid(existingAppGwUami.id, uamiPrincipalId, managedIdentityOperatorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperatorRoleId)
    principalId: uamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Role 3 — Network Contributor on the App Gateway subnet
// Required because gatewayIPConfigurations references this subnet in the PUT
// body, triggering a join/action linked authorization check.
// ---------------------------------------------------------------------------
resource networkContributorOnSubnet 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableSubnetNetworkContributor) {
  scope: appGatewaySubnet
  name: guid(appGatewaySubnet.id, uamiPrincipalId, networkContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: uamiPrincipalId
    principalType: 'ServicePrincipal'
  }
}
