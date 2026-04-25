@description('Deployment location for environment-specific resources')
param location string = resourceGroup().location

@description('Tags applied to environment-specific resources')
param tags object = {}

@description('Container Apps managed environment name')
@minLength(1)
@maxLength(63)
param containerAppEnvironmentName string

@description('Set to true when reusing an existing shared managed environment (e.g. UAT referencing the dev-created environment). When true, the managed environment is not created — only referenced.')
param containerAppEnvironmentExists bool = false

@description('Resource group name where the managed environment is located. Required when containerAppEnvironmentExists is true.')
param containerAppEnvironmentResourceGroupName string = resourceGroup().name

@description('Container App name')
@minLength(1)
@maxLength(63)
param containerAppName string

@description('Log Analytics workspace customer ID (GUID)')
param logAnalyticsWorkspaceCustomerId string

@description('Log Analytics workspace shared key')
@secure()
param logAnalyticsWorkspaceSharedKey string

@description('Container image to bootstrap the app. `azd deploy` will replace this with the built image.')
param bootstrapImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Target container port. Default 80 matches the bootstrap image (containerapps-helloworld). CI/CD pipeline updates this to 3000 via `az containerapp update --target-port 3000` when deploying the real application image.')
param containerPort int = 80

@description('Minimum replicas')
param minReplicas int = 0

@description('Maximum replicas')
param maxReplicas int = 2

@description('vCPU allocation per replica (string, e.g., "0.5")')
param cpu string = '0.5'

@description('Memory allocation per replica (string, e.g., "1.0Gi")')
param memory string = '1.0Gi'

@description('Azure Search endpoint exposed to the MCP server')
param azureSearchEndpoint string

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

@description('Number of worker processes')
param workers string = ''

@description('Kris+ API base URL')
param krisplusApiBaseUrl string = ''

@description('Kris+ country code')
param krisplusCountry string = ''

@description('Node environment')
param nodeEnv string = 'production'

@description('Comma-separated list of allowed CORS origins (e.g. https://chatgpt.com). Defaults to * when empty.')
param corsAllowedOrigins string = ''

@description('Resource ID of the infrastructure subnet for Container Apps VNet integration. When provided, the managed environment uses an internal load balancer (private, VNet-only). The subnet must be at least /27, must not have existing delegations, and must be delegated to Microsoft.App/environments before deployment. Leave empty to keep the current public configuration.')
param infrastructureSubnetId string = ''

@description('Log Analytics workspace resource ID for Application Insights')
param logAnalyticsWorkspaceResourceId string

// Application Insights for telemetry and monitoring
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${containerAppName}-insights'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceResourceId
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
    RetentionInDays: 90
    SamplingPercentage: 100
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' = if (!containerAppEnvironmentExists) {
  name: containerAppEnvironmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspaceCustomerId
        sharedKey: logAnalyticsWorkspaceSharedKey
      }
    }
    // When infrastructureSubnetId is provided the environment uses an internal load balancer.
    // Traffic from outside the VNet is blocked; the Application Gateway (same VNet) routes
    // to the Container App via its private FQDN: <containerAppName>.<defaultDomain>.
    // Requires a /27+ subnet delegated to Microsoft.App/environments in the same VNet as
    // the App Gateway (DEVUAT-APP-VNET). NOTE: VNet configuration cannot be added to an
    // existing environment in-place — the environment must be recreated on first enablement.
    vnetConfiguration: !empty(infrastructureSubnetId) ? {
      internal: true
      infrastructureSubnetId: infrastructureSubnetId
    } : null
  }
}

// When containerAppEnvironmentExists=true, reference the already-provisioned environment.
// This is the shared environment pattern: dev creates it, uat references it as existing.
// Same pattern as sharedContainerRegistryExists for the ACR.
// When reusing an existing environment in a different RG, use the full resource ID directly.
var effectiveManagedEnvironmentId = containerAppEnvironmentExists
  ? '/subscriptions/${subscription().subscriptionId}/resourceGroups/${containerAppEnvironmentResourceGroupName}/providers/Microsoft.App/managedEnvironments/${containerAppEnvironmentName}'
  : managedEnvironment.id

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'krisplus-mcp' })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: effectiveManagedEnvironmentId
    configuration: {
      ingress: {
        external: true
        targetPort: containerPort
        transport: 'Http'
        allowInsecure: false
      }
      // Registries intentionally left empty during Bicep provisioning.
      // The system-assigned identity does not have AcrPull when the first
      // revision is created (chicken-and-egg: AcrPull is granted by
      // acr-pull-rbac.bicep AFTER this resource exists). CI/CD adds the
      // registry before each deploy via `az containerapp registry set`.
      registries: []
      secrets: []
    }
    template: {
      containers: [
        {
          name: 'main'
          image: bootstrapImage
          env: [
            // Azure Search Configuration
            {
              name: 'AZURE_SEARCH_ENDPOINT'
              value: azureSearchEndpoint
            }
            {
              name: 'AZURE_SEARCH_DEALS_INDEX'
              value: azureSearchDealsIndex
            }
            {
              name: 'AZURE_SEARCH_MERCHANT_INDEX'
              value: azureSearchMerchantIndex
            }
            {
              name: 'AZURE_SEARCH_PRIVILEGE_INDEX'
              value: azureSearchPrivilegeIndex
            }
            {
              name: 'MIN_SCORE_THRESHOLD'
              value: minScoreThreshold
            }
            // Application Insights
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: applicationInsights.properties.ConnectionString
            }
            // Widget Configuration
            {
              name: 'WIDGET_DOMAIN'
              value: widgetDomain
            }
            {
              name: 'VITE_KRISPLUS_UNIVERSAL_LINK'
              value: viteKrisplusUniversalLink
            }
            {
              name: 'WIDGET_CSP_RESOURCE_DOMAINS'
              value: widgetCspResourceDomains
            }
            {
              name: 'WIDGET_CSP_CONNECT_DOMAINS'
              value: widgetCspConnectDomains
            }
            // Category Service
            {
              name: 'STATIC_API_URL'
              value: staticApiUrl
            }
            // Kris+ API Configuration (optional)
            {
              name: 'KRISPLUS_API_BASE_URL'
              value: krisplusApiBaseUrl
            }
            {
              name: 'KRISPLUS_COUNTRY'
              value: krisplusCountry
            }
            // Server Configuration
            {
              name: 'PORT'
              value: string(containerPort)
            }
            {
              name: 'NODE_ENV'
              value: nodeEnv
            }
            {
              name: 'CORS_ALLOWED_ORIGINS'
              value: corsAllowedOrigins
            }
            {
              name: 'WORKERS'
              value: workers
            }
          ]
          // Health probes are omitted during initial provision so that azd provision
          // succeeds with the bootstrap placeholder image, which only serves HTTP on
          // port 80. Azure's default system route (0.0.0.0/0 → Internet) provides
          // outbound internet for the bootstrap image pull — the same SNAT approach
          // used by all other subnets in DEVUAT-APP-VNET. Once CI/CD deploys the
          // real image (port 3000, /health), probes should be restored.
          probes: []
          resources: {
            cpu: json(cpu)
            memory: memory
          }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency-rule'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
          {
            name: 'cpu-utilization-rule'
            custom: {
              type: 'cpu'
              metadata: {
                type: 'Utilization'
                value: '70'
              }
            }
          }
          {
            name: 'memory-utilization-rule'
            custom: {
              type: 'memory'
              metadata: {
                type: 'Utilization'
                value: '75'
              }
            }
          }
        ]
      }
    }
  }
}

output CONTAINER_APP_FQDN string = containerApp.properties.configuration.ingress.fqdn
output CONTAINER_APP_RESOURCE_ID string = containerApp.id
output CONTAINER_APP_PRINCIPAL_ID string = containerApp.identity.principalId
// When VNet-integrated (internal), the App Gateway backend must use the private FQDN:
//   <containerAppName>.<MANAGED_ENVIRONMENT_DEFAULT_DOMAIN>
// This domain resolves via the private DNS zone provisioned by appgw-integration.bicep.
output MANAGED_ENVIRONMENT_DEFAULT_DOMAIN string = containerAppEnvironmentExists
  ? reference(effectiveManagedEnvironmentId, '2023-05-01').defaultDomain
  : managedEnvironment.properties.defaultDomain
output MANAGED_ENVIRONMENT_STATIC_IP string = containerAppEnvironmentExists
  ? reference(effectiveManagedEnvironmentId, '2023-05-01').staticIp
  : managedEnvironment.properties.staticIp
output APPLICATION_INSIGHTS_CONNECTION_STRING string = applicationInsights.properties.ConnectionString
output APPLICATION_INSIGHTS_INSTRUMENTATION_KEY string = applicationInsights.properties.InstrumentationKey
output APPLICATION_INSIGHTS_RESOURCE_ID string = applicationInsights.id
