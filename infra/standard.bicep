targetScope = 'subscription'

@description('Lowercase alphanumeric lab identifier, validated by the coordinator.')
@minLength(6)
@maxLength(12)
param labId string
@description('Ownership GUID from private lab state, verified by the coordinator.')
@minLength(36)
@maxLength(36)
param ownershipId string
@description('Approved region. Azure public cloud only.')
@allowed(['swedencentral'])
param location string = 'swedencentral'
@description('Existing owned case-a Foundry resource with private agent network injection already configured.')
@minLength(2)
@maxLength(64)
param accountName string
@description('Existing owned case-a project; never created or updated by this extension.')
param projectName string = 'case-a-dev'
@description('Verified managed identity object ID of the existing project. No other identity receives roles.')
@minLength(36)
@maxLength(36)
param projectPrincipalId string
@description('Verified Foundry project workspace GUID, not the Log Analytics workspace ID. Required for service-created container names.')
@minLength(32)
@maxLength(36)
param workspaceId string
@description('Exact existing agent container name discovered by the coordinator. Empty before the project stage completes; required for access.')
@maxLength(63)
param agentContainerName string = ''
@description('Run stages separately in order. Before either host stage, verify no implicit or explicit host exists. Never replay a host stage.')
@allowed(['dependencies', 'account', 'project', 'access'])
param stage string

var stem = 'fgl-${labId}'
var caseGroupName = 'rg-${stem}-case-a'
var integrationGroupName = 'rg-${stem}-integration'
var storageName = 'stfgl${labId}${take(uniqueString(subscription().subscriptionId, labId), 6)}'
var searchName = 'srch-fgl-${labId}-standard'
var cosmosName = 'cosmos-fgl-${labId}-standard'
var compactWorkspaceId = replace(toLower(workspaceId), '-', '')
var containerWorkspaceId = '${substring(compactWorkspaceId, 0, 8)}-${substring(compactWorkspaceId, 8, 4)}-${substring(compactWorkspaceId, 12, 4)}-${substring(compactWorkspaceId, 16, 4)}-${substring(compactWorkspaceId, 20, 12)}'
var tags = { 'fgl-lab': labId, 'fgl-owner': ownershipId, purpose: 'synthetic-governance-lab' }
var vnetId = resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/virtualNetworks', 'vnet-${stem}')
var subnetId = '${vnetId}/subnets/snet-case-a-pe'
var storageId = resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.Storage/storageAccounts', storageName)
var searchId = resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.Search/searchServices', searchName)
var cosmosId = resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.DocumentDB/databaseAccounts', cosmosName)
var accountId = resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.CognitiveServices/accounts', accountName)
var projectId = '${accountId}/projects/${projectName}'
var dnsZoneIds = {
  blob: resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.blob.${environment().suffixes.storage}')
  search: resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')
  cosmos: resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com')
}
var privateEndpointIds = [for service in ['blob', 'search', 'cosmos']: resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.Network/privateEndpoints', 'pe-${stem}-standard-${service}')]

module dns 'modules/standard-dns.bicep' = if (stage == 'dependencies') {
  name: '${stem}-standard-dns'
  scope: resourceGroup(integrationGroupName)
  params: { labId: labId, tags: tags }
}

module dependencies 'modules/standard-dependencies.bicep' = if (stage == 'dependencies') {
  name: '${stem}-standard-dependencies'
  scope: resourceGroup(caseGroupName)
  params: {
    labId: labId
    location: location
    tags: tags
    accountName: accountName
    projectName: projectName
    projectPrincipalId: projectPrincipalId
    storageName: storageName
    searchName: searchName
    cosmosName: cosmosName
    subnetId: subnetId
    dnsZoneIds: dnsZoneIds
  }
  dependsOn: [dns]
}

module accountHost 'modules/standard-account-host.bicep' = if (stage == 'account') {
  name: '${stem}-standard-account'
  scope: resourceGroup(caseGroupName)
  params: { accountName: accountName }
}

module projectHost 'modules/standard-project-host.bicep' = if (stage == 'project') {
  name: '${stem}-standard-project'
  scope: resourceGroup(caseGroupName)
  params: {
    accountName: accountName
    projectName: projectName
    storageName: storageName
    searchName: searchName
    cosmosName: cosmosName
  }
}

module access 'modules/standard-access.bicep' = if (stage == 'access') {
  name: '${stem}-standard-access'
  scope: resourceGroup(caseGroupName)
  params: {
    storageName: storageName
    cosmosName: cosmosName
    projectPrincipalId: projectPrincipalId
    workspaceId: containerWorkspaceId
    agentContainerName: agentContainerName
  }
}

@description('Intended identifiers, not evidence that resources exist or a stage succeeded. containers.agent is empty until discovery binds its exact name. Host and connection IDs remain valid in every stage without runtime references.')
output standard object = {
  labId: labId
  ownershipId: ownershipId
  stage: stage
  location: location
  resourceGroups: { caseA: caseGroupName, integration: integrationGroupName }
  accountId: accountId
  projectId: projectId
  projectPrincipalId: projectPrincipalId
  workspaceId: toLower(workspaceId)
  projectEndpoint: 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
  storage: { name: storageName, id: storageId, endpoint: 'https://${storageName}.blob.${environment().suffixes.storage}/' }
  search: { name: searchName, id: searchId, endpoint: 'https://${searchName}.search.windows.net' }
  cosmos: { name: cosmosName, id: cosmosId, endpoint: 'https://${cosmosName}.documents.azure.com:443/', databaseScope: '${cosmosId}/dbs/enterprise_memory' }
  connections: {
    storage: { name: storageName, id: '${projectId}/connections/${storageName}' }
    search: { name: searchName, id: '${projectId}/connections/${searchName}' }
    cosmos: { name: cosmosName, id: '${projectId}/connections/${cosmosName}' }
  }
  capabilityHosts: { account: '${accountId}/capabilityHosts/agents', project: '${projectId}/capabilityHosts/agents' }
  vnetId: vnetId
  subnetId: subnetId
  dnsZoneIds: dnsZoneIds
  reusedBlobDnsZone: true
  privateEndpointIds: privateEndpointIds
  containers: {
    blobstore: '${storageId}/blobServices/default/containers/${containerWorkspaceId}-azureml-blobstore'
    agent: empty(agentContainerName) ? '' : '${storageId}/blobServices/default/containers/${agentContainerName}'
  }
}
