// =============================================================================
// App Gateway Integration — User-Assigned Managed Identity + DNS zone
//
// This module runs in the Container App's resource group (DEV-KRISPLUS-CHATGPT-RG).
// It provisions three resources:
//
// 1. UAMI (User-Assigned Managed Identity): used by the deployment script in
//    appgw-backend-update.bicep to call az cli against the App Gateway. The
//    Network Contributor role assignment is handled by appgw-rbac.bicep.
//
// 2. Private DNS zone: Azure does NOT auto-create this zone. It must be
//    provisioned explicitly (per Microsoft docs: aka.ms/aca-vnet-custom).
//    The zone name equals managedEnvironmentDefaultDomain. A wildcard A record
//    (*) pointing to the managed environment's static IP is added so that any
//    Container App FQDN in this environment resolves to the internal LB.
//
// 3. VNet link: links the DNS zone to DEVUAT-APP-VNET so that
//    DEVUAT-ASE-APPGWV2-03 can resolve the Container App's private FQDN
//    (<containerAppName>.<managedEnvironmentDefaultDomain>).
//
// Execution order: must run AFTER environmentResources (enforced by
// dependsOn in main.bicep) so that staticIp is known.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region for the UAMI')
param location string = resourceGroup().location

@description('Tags to apply to created resources')
param tags object = {}

@description('Container App name — used to name the UAMI')
param containerAppName string

@description('Default domain of the Container Apps managed environment — used as the private DNS zone name (e.g., "agreeablepebble-2234ef59.southeastasia.azurecontainerapps.io").')
param managedEnvironmentDefaultDomain string

@description('Static IP of the Container Apps managed environment internal load balancer (e.g., "10.164.0.16"). Used as the wildcard A record target.')
param managedEnvironmentStaticIp string

@description('Resource ID of the App Gateway VNet (DEVUAT-APP-VNET) to link the private DNS zone to')
param appGatewayVnetId string

// ---------------------------------------------------------------------------
// User-Assigned Managed Identity (UAMI)
// The deployment script in appgw-backend-update.bicep uses this identity.
// appgw-rbac.bicep grants it Network Contributor on the App Gateway.
// ---------------------------------------------------------------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${containerAppName}-appgw-uami'
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Private DNS zone
// Azure does NOT auto-create this zone for internal Container Apps environments.
// The zone name equals the managed environment's defaultDomain. All Container
// App FQDNs in this environment are <appName>.<defaultDomain>, so a single
// wildcard A record covers the entire environment.
// Reference: https://learn.microsoft.com/azure/container-apps/vnet-custom
// ---------------------------------------------------------------------------
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: managedEnvironmentDefaultDomain
  location: 'global'
}

// Wildcard A record — resolves *.defaultDomain to the managed env's static IP.
// This covers dev-krisplus-chatgpt-app.<defaultDomain> and any future apps in
// the same environment without additional DNS changes.
resource wildcardARecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: privateDnsZone
  name: '*'
  properties: {
    ttl: 3600
    aRecords: [
      {
        ipv4Address: managedEnvironmentStaticIp
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VNet link — DEVUAT-APP-VNET
// Enables the App Gateway (in DEVUAT-APP-VNET) to resolve the Container App's
// private FQDN via the zone above. Without this link, App Gateway health probes
// and backend requests fail with DNS resolution errors.
// ---------------------------------------------------------------------------
resource dnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'link-to-appgw-vnet'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: appGatewayVnetId
    }
    registrationEnabled: false
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output uamiId string = uami.id
output uamiPrincipalId string = uami.properties.principalId
