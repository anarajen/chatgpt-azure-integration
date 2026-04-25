targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Environment name used when composing resource names')
param environmentName string

@minLength(1)
@description('Primary Azure region for environment-specific resources')
param location string

@description('Resource group name that hosts environment-specific resources')
@minLength(1)
param resourceGroupName string

@description('Shared resource group name (used for reusable resources such as the container registry)')
@minLength(1)
param sharedResourceGroupName string

@description('Azure region for shared resources')
param sharedLocation string = location

@description('Shared Azure Container Registry name')
param sharedContainerRegistryName string

@description('Set to true when reusing an existing shared container registry')
param sharedContainerRegistryExists bool = false

@description('Container Apps managed environment name')
param containerAppEnvironmentName string

@description('Set to true when reusing an existing shared managed environment (e.g. UAT referencing the dev-created environment). See ADR-004.')
param containerAppEnvironmentExists bool = false

@description('Resource group name where the managed environment is located. Required when containerAppEnvironmentExists is true.')
param containerAppEnvironmentResourceGroupName string = resourceGroupName

@description('Container App name')
param containerAppName string

@description('Log Analytics workspace resource group')
param logAnalyticsWorkspaceResourceGroupName string

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string

@description('Bootstrap container image')
param bootstrapImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Azure Search endpoint URL')
param azureSearchEndpoint string

@description('Name of the Azure Cognitive Search service (e.g. "dev-kp-search"). When set, Bicep grants the Container App MSI Search Index Data Reader on this service automatically.')
param azureSearchServiceName string = ''

@description('Resource group that contains the Azure Search service (e.g. "KP_SEARCH"). Required when azureSearchServiceName is set.')
param azureSearchServiceResourceGroupName string = ''

@description('Azure Search deals index name')
param azureSearchDealsIndex string

@description('Azure Search merchant index name')
param azureSearchMerchantIndex string

@description('Azure Search privilege index name')
param azureSearchPrivilegeIndex string

@description('Vite Krisplus Universal Link')
param viteKrisplusUniversalLink string

@description('Widget CSP Resource Domains')
param widgetCspResourceDomains string

@description('Widget CSP Connect Domains')
param widgetCspConnectDomains string = ''

@description('Widget domain for MCP Apps sandbox (full HTTPS URL, e.g. https://myapp.example.com). Required for app submission.')
param widgetDomain string = ''

@description('Static API URL for category data')
param staticApiUrl string = ''

@description('Minimum score threshold for Azure Search results')
param minScoreThreshold string = '0.01'

@description('Number of worker processes (defaults to CPU count if empty)')
param workers string = ''

@description('Kris+ API base URL')
param krisplusApiBaseUrl string = ''

@description('Kris+ country code')
param krisplusCountry string = ''

@description('Node environment')
param nodeEnv string = 'production'

@description('Comma-separated list of allowed CORS origins (e.g. https://chatgpt.com). Defaults to * when empty.')
param corsAllowedOrigins string = ''

// ---------------------------------------------------------------------------
// VNet integration parameters
// Set CONTAINER_APP_SUBNET_NAME (and the other VNET_* variables) to let Bicep
// create a delegated subnet inside the existing App Gateway VNet and wire up
// the Container Apps managed environment to it automatically.
// Leave all empty for a fully public (non-VNet-integrated) configuration.
// ---------------------------------------------------------------------------

@description('Name for the new Container Apps subnet to create inside the App Gateway VNet (e.g., "KRISPLUS-CHATGPT-DEV-SUBNET"). Leave empty to skip VNet provisioning.')
param containerAppSubnetName string = ''

@description('Address prefix for the Container Apps infrastructure subnet (must be /27 or larger, e.g., "10.163.144.128/27"). Required when containerAppSubnetName is set.')
param containerAppSubnetAddressPrefix string = ''

@description('Name of the existing App Gateway VNet that will host the new Container Apps subnet (e.g., "DEVUAT-APP-VNET"). Required when containerAppSubnetName is set.')
param appGatewayVnetName string = ''

@description('Resource group of the existing App Gateway VNet (e.g., "DEVUAT-ASE-RG"). Required when containerAppSubnetName is set.')
param appGatewayVnetResourceGroupName string = ''

@description('Resource ID of an existing infrastructure subnet (advanced use — bypasses subnet creation). Ignored when containerAppSubnetName is set.')
param infrastructureSubnetId string = ''

@description('Name of the existing Application Gateway to update (e.g., "DEVUAT-ASE-APPGWV2-03"). When set together with containerAppSubnetName, Bicep links the private DNS zone to the App Gateway VNet and updates the backend pool automatically.')
param appGatewayName string = ''

@description('Name of the existing App Gateway backend pool to update with the Container App private FQDN (e.g., "DEV-KRISPLUS-CHATGPT-POOL"). Required when appGatewayName is set.')
param appGatewayBackendPoolName string = ''

@description('Name of an existing User-Assigned Managed Identity already attached to the App Gateway (e.g., "KP_NonProd_AppGw_KV_MI"). When set, appgw-rbac.bicep grants our deployment UAMI Managed Identity Operator on it — required because az network application-gateway address-pool update does a full GET+PUT that carries the existing UAMI in the body, triggering a linked authorization check. Leave empty if the App Gateway has no attached UAMIs.')
param appGatewayExistingUamiName string = ''

@description('Name of the subnet the App Gateway is attached to (e.g., "DEVUAT-APPGWV2-SUBNET"). When set, appgw-rbac.bicep grants our UAMI Network Contributor on it — required because the App Gateway PUT body references this subnet, triggering a join/action check. Leave empty if not needed.')
param appGatewaySubnetName string = ''

@description('Name of the HTTP settings to create/update on the App Gateway (e.g., "DEV-KRISPLUS-CHATGPT-HTTPSetting"). Required when appGatewayName is set.')
param appGatewayHttpSettingsName string = ''

@description('Name of the HTTPS listener to create/update on the App Gateway (e.g., "DEV-KRISPLUS-CHATGPT-LISTENER"). Required when appGatewayName is set.')
param appGatewayListenerName string = ''

@description('Name of the routing rule to create/update on the App Gateway (e.g., "DEV-KRISPLUS-CHATGPT-RULE"). Required when appGatewayName is set.')
param appGatewayRuleName string = ''

@description('Name of the existing SSL certificate on the App Gateway (e.g., "nonprodkrispaydotcom-sectigo-Expiry-2026"). Required when appGatewayListenerName is set.')
param appGatewaySslCertName string = ''

@description('Public hostname for the HTTPS listener (e.g., "dev-chatgpt.nonprod-krispay.com"). Required when appGatewayListenerName is set.')
param appGatewayHostname string = ''

@description('Minimum container replicas')
param minReplicas int = 0

@description('Maximum container replicas')
param maxReplicas int = 2

@description('Container CPU allocation (string, e.g., "0.5")')
param cpu string = '0.5'

@description('Container memory allocation (string, e.g., "1.0Gi")')
param memory string = '1.0Gi'

param containerPort int = 3000

var tags = {
  'azd-env-name': environmentName
}

// Enable IaC-managed VNet integration when a subnet name or explicit subnet ID is provided.
var enableVnetIntegration = !empty(containerAppSubnetName) || !empty(infrastructureSubnetId)

// Enable App Gateway integration when VNet integration is active and both App
// Gateway params are provided. Controls the appgw-integration, appgw-rbac, and
// appgw-backend-update modules.
var enableAppGwIntegration = enableVnetIntegration && !empty(appGatewayName) && !empty(appGatewayBackendPoolName)

// Fall back to a safe RG so module scopes resolve even when VNet integration is disabled.
var effectiveAppGwVnetRg = !empty(appGatewayVnetResourceGroupName) ? appGatewayVnetResourceGroupName : resourceGroupName

// Resource ID of the App Gateway VNet — needed by the DNS zone VNet link.
var appGatewayVnetId = resourceId(subscription().subscriptionId, effectiveAppGwVnetRg, 'Microsoft.Network/virtualNetworks', appGatewayVnetName)

// Resolved subnet ID: prefers the shared-vnet-subnet module output (IaC-created subnet),
// falls back to the manually-supplied infrastructureSubnetId (pre-existing subnet bypass).
var resolvedInfrastructureSubnetId = !empty(containerAppSubnetName) ? sharedVnetSubnet.outputs.subnetId : infrastructureSubnetId

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

resource sharedResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: sharedResourceGroupName
  location: sharedLocation
  tags: tags
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logAnalyticsWorkspaceName
  scope: resourceGroup(logAnalyticsWorkspaceResourceGroupName)
}

module sharedResources './shared.bicep' = if (!sharedContainerRegistryExists) {
  name: 'shared-resources'
  scope: sharedResourceGroup
  params: {
    sharedContainerRegistryName: sharedContainerRegistryName
    sharedTags: tags
  }
}

resource sharedContainerRegistryExisting 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' existing = if (sharedContainerRegistryExists) {
  scope: sharedResourceGroup
  name: sharedContainerRegistryName
}

var sharedRegistryResourceId = sharedContainerRegistryExists ? sharedContainerRegistryExisting.id : sharedResources.outputs.sharedContainerRegistryResourceId
var sharedRegistryLoginServer = sharedContainerRegistryExists ? sharedContainerRegistryExisting.properties.loginServer : sharedResources.outputs.sharedContainerRegistryLoginServer

// ---------------------------------------------------------------------------
// Shared VNet subnet — creates a delegated /27 subnet inside the existing
// App Gateway VNet (DEVUAT-APP-VNET) for the Container Apps managed environment.
// Runs in the App Gateway VNet's resource group (DEVUAT-ASE-RG).
// No VNet peering is required — App Gateway and Container Apps share the same VNet.
// ---------------------------------------------------------------------------
module sharedVnetSubnet './shared-vnet-subnet.bicep' = if (!empty(containerAppSubnetName) && !empty(appGatewayVnetName)) {
  name: 'shared-vnet-subnet'
  scope: resourceGroup(effectiveAppGwVnetRg)
  params: {
    vnetName: appGatewayVnetName
    subnetName: containerAppSubnetName
    subnetAddressPrefix: containerAppSubnetAddressPrefix
  }
}

module environmentResources './resources.bicep' = {
  name: 'environment-resources'
  scope: environmentResourceGroup
  params: {
    location: location
    tags: tags
    containerAppEnvironmentName: containerAppEnvironmentName
    containerAppEnvironmentExists: containerAppEnvironmentExists
    containerAppEnvironmentResourceGroupName: containerAppEnvironmentResourceGroupName
    containerAppName: containerAppName
    logAnalyticsWorkspaceCustomerId: logAnalyticsWorkspace.properties.customerId
    logAnalyticsWorkspaceSharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
    bootstrapImage: bootstrapImage
    azureSearchEndpoint: azureSearchEndpoint
    azureSearchDealsIndex: azureSearchDealsIndex
    azureSearchMerchantIndex: azureSearchMerchantIndex
    azureSearchPrivilegeIndex: azureSearchPrivilegeIndex
    viteKrisplusUniversalLink: viteKrisplusUniversalLink
    widgetDomain: widgetDomain
    widgetCspResourceDomains: widgetCspResourceDomains
    widgetCspConnectDomains: widgetCspConnectDomains
    staticApiUrl: staticApiUrl
    minScoreThreshold: minScoreThreshold
    workers: workers
    krisplusApiBaseUrl: krisplusApiBaseUrl
    krisplusCountry: krisplusCountry
    nodeEnv: nodeEnv
    corsAllowedOrigins: corsAllowedOrigins
    infrastructureSubnetId: resolvedInfrastructureSubnetId
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    cpu: cpu
    memory: memory
    containerPort: containerPort
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// ---------------------------------------------------------------------------
// ACR Pull RBAC — grants the Container App's system-assigned managed identity
// the AcrPull role on the shared registry. Runs in the shared resource group.
// This allows the Container App to pull images without storing ACR credentials.
// ---------------------------------------------------------------------------
module acrPullRbac './acr-pull-rbac.bicep' = {
  name: 'acr-pull-rbac'
  scope: sharedResourceGroup
  params: {
    containerRegistryName: sharedContainerRegistryName
    containerAppPrincipalId: environmentResources.outputs.CONTAINER_APP_PRINCIPAL_ID
  }
}

// ---------------------------------------------------------------------------
// Azure Search RBAC — grants the Container App MSI Search Index Data Reader
// on the Azure Search service so DefaultAzureCredential works without API keys.
// Runs in the search service's resource group (may differ from env RG).
// Set AZURE_SEARCH_SERVICE_NAME + AZURE_SEARCH_RESOURCE_GROUP in the env file
// to enable. Safe to skip on first provision — grant manually if forgotten, then
// re-run azd provision to idempotently assign via IaC going forward.
// ---------------------------------------------------------------------------
module azureSearchRbac './azure-search-rbac.bicep' = if (!empty(azureSearchServiceName)) {
  name: 'azure-search-rbac'
  scope: resourceGroup(!empty(azureSearchServiceResourceGroupName) ? azureSearchServiceResourceGroupName : resourceGroupName)
  params: {
    searchServiceName: azureSearchServiceName
    containerAppPrincipalId: environmentResources.outputs.CONTAINER_APP_PRINCIPAL_ID
  }
}

// ---------------------------------------------------------------------------
// App Gateway integration — DNS zone link + UAMI
// Runs in the environment RG after the managed environment exists (dependsOn).
// The private DNS zone is auto-created by Azure alongside the managed env.
// ---------------------------------------------------------------------------
module appGwIntegration './appgw-integration.bicep' = if (enableAppGwIntegration) {
  name: 'appgw-integration'
  scope: environmentResourceGroup
  params: {
    location: location
    tags: tags
    containerAppName: containerAppName
    managedEnvironmentDefaultDomain: environmentResources.outputs.MANAGED_ENVIRONMENT_DEFAULT_DOMAIN
    managedEnvironmentStaticIp: environmentResources.outputs.MANAGED_ENVIRONMENT_STATIC_IP
    appGatewayVnetId: appGatewayVnetId
  }
}

// ---------------------------------------------------------------------------
// App Gateway RBAC — grants UAMI Network Contributor on the App Gateway
// Runs in DEVUAT-ASE-RG; scoped to the App Gateway resource (not the whole RG).
// ---------------------------------------------------------------------------
module appGwRbac './appgw-rbac.bicep' = if (enableAppGwIntegration) {
  name: 'appgw-rbac'
  scope: resourceGroup(effectiveAppGwVnetRg)
  params: {
    appGatewayName: appGatewayName
    uamiPrincipalId: appGwIntegration.outputs.uamiPrincipalId
    appGatewayExistingUamiName: appGatewayExistingUamiName
    appGatewayVnetName: appGatewayVnetName
    appGatewaySubnetName: appGatewaySubnetName
  }
}

// ---------------------------------------------------------------------------
// App Gateway backend pool update — az cli deployment script
// Runs AFTER appgw-rbac so the UAMI has the required Network Contributor role.
// Updates DEV-KRISPLUS-CHATGPT-POOL to the Container App's private FQDN.
// ---------------------------------------------------------------------------
module appGwBackendUpdate './appgw-backend-update.bicep' = if (enableAppGwIntegration) {
  name: 'appgw-backend-update'
  scope: environmentResourceGroup
  dependsOn: [appGwRbac]
  params: {
    location: location
    tags: tags
    uamiId: appGwIntegration.outputs.uamiId
    appGatewayResourceGroup: effectiveAppGwVnetRg
    appGatewayName: appGatewayName
    appGatewayBackendPoolName: appGatewayBackendPoolName
    containerAppPrivateFqdn: '${containerAppName}.${environmentResources.outputs.MANAGED_ENVIRONMENT_DEFAULT_DOMAIN}'
    appGatewayHttpSettingsName: appGatewayHttpSettingsName
    appGatewayListenerName: appGatewayListenerName
    appGatewayRuleName: appGatewayRuleName
    appGatewaySslCertName: appGatewaySslCertName
    appGatewayHostname: appGatewayHostname
  }
}

output SHARED_CONTAINER_REGISTRY_RESOURCE_ID string = sharedRegistryResourceId
output SHARED_CONTAINER_REGISTRY_LOGIN_SERVER string = sharedRegistryLoginServer
output AZURE_RESOURCE_OPENAI_APPS_POC_ID string = environmentResources.outputs.CONTAINER_APP_RESOURCE_ID
output CONTAINER_APP_FQDN string = environmentResources.outputs.CONTAINER_APP_FQDN
// When VNet-integrated, the App Gateway backend pool private FQDN is:
//   <CONTAINER_APP_NAME>.<MANAGED_ENVIRONMENT_DEFAULT_DOMAIN>
// This is updated automatically by appgw-backend-update when APP_GATEWAY_NAME
// and APP_GATEWAY_BACKEND_POOL_NAME are set in the env file.
output MANAGED_ENVIRONMENT_DEFAULT_DOMAIN string = environmentResources.outputs.MANAGED_ENVIRONMENT_DEFAULT_DOMAIN
output APPLICATION_INSIGHTS_CONNECTION_STRING string = environmentResources.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
output APPLICATION_INSIGHTS_INSTRUMENTATION_KEY string = environmentResources.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
