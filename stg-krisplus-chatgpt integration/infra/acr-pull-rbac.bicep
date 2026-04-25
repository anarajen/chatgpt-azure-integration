@description('Name of the shared Azure Container Registry')
param containerRegistryName string

@description('Principal ID of the Container App system-assigned managed identity')
param containerAppPrincipalId string

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' existing = {
  name: containerRegistryName
}

// AcrPull built-in role — allows pulling images from the registry
var acrPullRoleDefinitionId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, containerAppPrincipalId, acrPullRoleDefinitionId)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleDefinitionId)
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}
