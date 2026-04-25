targetScope = 'resourceGroup'

@description('Shared Azure Container Registry name')
@minLength(5)
@maxLength(50)
param sharedContainerRegistryName string

@description('Tags applied to shared resources')
param sharedTags object = {}

resource sharedContainerRegistry 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: sharedContainerRegistryName
  location: resourceGroup().location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    zoneRedundancy: 'Disabled'
    publicNetworkAccess: 'Enabled'
  }
  tags: sharedTags
}

output sharedContainerRegistryResourceId string = sharedContainerRegistry.id
output sharedContainerRegistryLoginServer string = sharedContainerRegistry.properties.loginServer
