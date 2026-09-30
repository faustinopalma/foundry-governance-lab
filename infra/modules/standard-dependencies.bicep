@description('Lab identifier. Scope this module only to the existing case-a resource group.')
param labId string
param location string
param tags object
param accountName string
param projectName string
@description('Verified existing project managed identity object ID.')
param projectPrincipalId string
param storageName string
param searchName string
param cosmosName string
@description('Existing integration VNet snet-case-a-pe resource ID, derived by standard.bicep.')
param subnetId string
@description('Blob zone is reused unchanged. Search and Cosmos zones are created by standard-dns.bicep.')
param dnsZoneIds object

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Disabled'
    networkAcls: { bypass: 'None', defaultAction: 'Deny', ipRules: [], virtualNetworkRules: [] }
  }
}

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchName
  location: location
  tags: tags
  sku: { name: 'basic' }
  identity: { type: 'SystemAssigned' }
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: 'disabled'
    partitionCount: 1
    replicaCount: 1
    hostingMode: 'Default'
    semanticSearch: 'disabled'
    networkRuleSet: { bypass: 'None', ipRules: [] }
  }
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    networkAclBypass: 'None'
    ipRules: []
    virtualNetworkRules: []
    enableFreeTier: false
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    capacity: { totalThroughputLimit: 5000 }
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [{ locationName: location, failoverPriority: 0, isZoneRedundant: false }]
  }
}

var endpointDefinitions = [
  { service: 'blob', targetId: storage.id, groupId: 'blob', zoneId: dnsZoneIds.blob }
  { service: 'search', targetId: search.id, groupId: 'searchService', zoneId: dnsZoneIds.search }
  { service: 'cosmos', targetId: cosmos.id, groupId: 'Sql', zoneId: dnsZoneIds.cosmos }
]

module endpoints 'private-endpoint.bicep' = [for endpoint in endpointDefinitions: {
  name: 'fgl-${labId}-standard-${endpoint.service}-endpoint'
  params: {
    name: 'pe-fgl-${labId}-standard-${endpoint.service}'
    location: location
    tags: tags
    targetId: endpoint.targetId
    groupId: endpoint.groupId
    subnetId: subnetId
    zoneIds: [endpoint.zoneId]
  }
}]

resource account 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' existing = {
  parent: account
  name: projectName
}

resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-05-01' = {
  parent: project
  name: storageName
  properties: {
    category: 'AzureStorageAccount'
    target: storage.properties.primaryEndpoints.blob
    authType: 'AAD'
    isSharedToAll: false
    metadata: { ApiType: 'Azure', ResourceId: storage.id, location: location }
  }
}

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-05-01' = {
  parent: project
  name: searchName
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${searchName}.search.windows.net'
    authType: 'AAD'
    isSharedToAll: false
    metadata: { ApiType: 'Azure', ResourceId: search.id, location: location }
  }
}

resource cosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-05-01' = {
  parent: project
  name: cosmosName
  properties: {
    category: 'CosmosDb'
    target: cosmos.properties.documentEndpoint
    authType: 'AAD'
    isSharedToAll: false
    metadata: { ApiType: 'Azure', ResourceId: cosmos.id, location: location }
  }
}

resource storageContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, projectPrincipalId, '17d1049b-9a84-46fb-8f53-869881c3d3ab')
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab')
  }
}

resource cosmosOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cosmos
  name: guid(cosmos.id, projectPrincipalId, '230815da-be43-4aae-9cb4-875f7bd000aa')
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '230815da-be43-4aae-9cb4-875f7bd000aa')
  }
}

var searchRoleIds = ['8ebe5a00-799e-43f5-93ac-243d3dce84a7', '7ca78c08-252a-4471-8644-bb5ff32d4ba0']

resource searchRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in searchRoleIds: {
  scope: search
  name: guid(search.id, projectPrincipalId, roleId)
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
  }
}]
