// =============================================================================
// App Gateway backend pool update — az cli deployment script
//
// This module runs in the Container App's resource group AFTER appgw-rbac.bicep
// has granted the UAMI Network Contributor on the App Gateway. It executes a
// short az cli script that creates (if missing) or updates the backend pool's
// FQDN to the Container App's private FQDN:
//   <containerAppName>.<managedEnvironmentDefaultDomain>
//
// Idempotency: az network application-gateway address-pool update is a PUT
// that replaces the pool's server list. Re-running azd provision re-executes
// the script (forceUpdateTag = utcNow()) and sets the pool to the same FQDN —
// safe no-op if the pool is already correct.
//
// Storage account: Azure automatically provisions a temporary storage account
// for the script container. No explicit storageAccountSettings are required;
// the ARM deployment service principal creates it in this resource group.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region for the deployment script resource')
param location string = resourceGroup().location

@description('Tags applied to the deployment script resource')
param tags object = {}

@description('Resource ID of the UAMI (from appgw-integration.bicep) that has Network Contributor on the App Gateway')
param uamiId string

@description('Resource group containing the App Gateway (e.g., "DEVUAT-ASE-RG")')
param appGatewayResourceGroup string

@description('Name of the App Gateway (e.g., "DEVUAT-ASE-APPGWV2-03")')
param appGatewayName string

@description('Name of the backend pool to update (e.g., "DEV-KRISPLUS-CHATGPT-POOL")')
param appGatewayBackendPoolName string

@description('Private FQDN of the Container App: <containerAppName>.<managedEnvironmentDefaultDomain>')
param containerAppPrivateFqdn string

@description('Name of the HTTP settings to upsert (e.g., "DEV-KRISPLUS-CHATGPT-HTTPSetting"). Leave empty to skip HTTP settings/listener/rule creation.')
param appGatewayHttpSettingsName string = ''

@description('Name of the HTTPS listener to upsert (e.g., "DEV-KRISPLUS-CHATGPT-LISTENER")')
param appGatewayListenerName string = ''

@description('Name of the routing rule to upsert (e.g., "DEV-KRISPLUS-CHATGPT-RULE")')
param appGatewayRuleName string = ''

@description('Name of the existing SSL certificate on the App Gateway')
param appGatewaySslCertName string = ''

@description('Public hostname for the HTTPS listener (e.g., "dev-chatgpt.nonprod-krispay.com")')
param appGatewayHostname string = ''

@description('Forces re-execution on every azd provision. Defaults to current UTC time.')
param forceUpdateTag string = utcNow()

resource backendPoolUpdate 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'update-appgw-backend-pool'
  location: location
  kind: 'AzureCLI'
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiId}': {}
    }
  }
  properties: {
    azCliVersion: '2.60.0'
    timeout: 'PT10M'
    retentionInterval: 'PT1H'
    cleanupPreference: 'Always'
    forceUpdateTag: forceUpdateTag
    environmentVariables: [
      { name: 'APPGW_RG', value: appGatewayResourceGroup }
      { name: 'APPGW_NAME', value: appGatewayName }
      { name: 'POOL_NAME', value: appGatewayBackendPoolName }
      { name: 'PRIVATE_FQDN', value: containerAppPrivateFqdn }
      { name: 'HTTP_SETTINGS_NAME', value: appGatewayHttpSettingsName }
      { name: 'LISTENER_NAME', value: appGatewayListenerName }
      { name: 'RULE_NAME', value: appGatewayRuleName }
      { name: 'SSL_CERT_NAME', value: appGatewaySslCertName }
      { name: 'HOSTNAME', value: appGatewayHostname }
    ]
    scriptContent: loadTextContent('./scripts/update-appgw-backend-pool.sh')
  }
}
