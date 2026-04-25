@description('Name of the Azure Cognitive Search service')
param searchServiceName string

@description('Principal ID of the Container App system-assigned managed identity')
param containerAppPrincipalId string

resource searchService 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: searchServiceName
}

// Search Index Data Reader — allows the Container App MSI to query search indexes
// without storing an API key. Required because DefaultAzureCredential is used.
// Role definition: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning#search-index-data-reader
var searchIndexDataReaderRoleId = '1407120a-92aa-4202-b7e9-c0e197c71c8f'

resource searchIndexDataReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, containerAppPrincipalId, searchIndexDataReaderRoleId)
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataReaderRoleId)
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}
