// =============================================================================
// Shared VNet Subnet — creates a delegated subnet for Container Apps
// inside an existing VNet (e.g., DEVUAT-APP-VNET).
//
// Scoped to the resource group that owns the VNet (e.g., DEVUAT-ASE-RG).
// Must be run after the network team has freed sufficient CIDR space.
//
// Delegation is subnet-scoped (Microsoft.App/environments) — no other subnets
// in the VNet are affected. Pattern documented at:
// https://learn.microsoft.com/azure/container-apps/vnet-custom
// =============================================================================

targetScope = 'resourceGroup'

@description('Name of the existing VNet to add the subnet to (e.g., "DEVUAT-APP-VNET")')
param vnetName string

@description('Name for the new Container Apps subnet (e.g., "KRISPLUS-CHATGPT-DEV-SUBNET")')
param subnetName string

@description('CIDR address prefix for the new subnet (min /27, e.g. "10.163.144.128/27"). Cannot be changed after the Container Apps managed environment is attached.')
param subnetAddressPrefix string

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing = {
  name: vnetName
}

resource containerAppsSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: subnetAddressPrefix
    delegations: [
      {
        name: 'Microsoft.App.environments'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
    privateEndpointNetworkPolicies: 'Disabled'
    privateLinkServiceNetworkPolicies: 'Disabled'
  }
}

output subnetId string = containerAppsSubnet.id
output subnetName string = containerAppsSubnet.name
