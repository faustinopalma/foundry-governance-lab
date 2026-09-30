targetScope = 'subscription'

metadata description = 'Additive Standard dependencies for one existing expansion project. No hosts, runtime access or retained parent updates.'

@description('Original lowercase alphanumeric lab identifier, verified by the coordinator against the owned lab.')
@minLength(6)
@maxLength(12)
param labId string

@description('Original ownership GUID in D format, verified by the coordinator. Length constraints do not validate GUID syntax.')
@minLength(36)
@maxLength(36)
param ownershipId string

@description('Approved Azure public cloud region.')
@allowed(['swedencentral'])
param location string = 'swedencentral'

@description('Exactly one existing expansion project. The retained case-a-dev project cannot be selected.')
@allowed(['a-test', 'b-dev', 'b-test'])
param projectSelector string

@description('Existing selected project system-assigned identity object GUID in D format. The coordinator must validate syntax and bind it to the exact existing project ID before deployment.')
@minLength(36)
@maxLength(36)
param projectPrincipalId string

var stem = 'fgl-${labId}'
var uniqueSuffix = uniqueString(subscription().id, labId)
var selection = {
  'a-test': { caseId: 'a', projectName: 'case-a-test', code: 'at' }
  'b-dev': { caseId: 'b', projectName: 'case-b-dev', code: 'bd' }
  'b-test': { caseId: 'b', projectName: 'case-b-test', code: 'bt' }
}[projectSelector]
var caseGroupName = 'rg-${stem}-case-${selection.caseId}'
var integrationGroupName = 'rg-${stem}-integration'
var accountName = 'aif-${stem}-${selection.caseId}-${uniqueSuffix}'
var projectName = selection.projectName
var accountId = resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.CognitiveServices/accounts', accountName)
var projectId = resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.CognitiveServices/accounts/projects', accountName, projectName)
var tags = { 'fgl-lab': labId, 'fgl-owner': ownershipId, purpose: 'synthetic-governance-lab' }
var storageName = 'stfgx${selection.code}${uniqueSuffix}'
var searchName = 'srch-${stem}-exp-${projectSelector}-${uniqueSuffix}'
var cosmosName = 'cosmos-${stem}-exp-${selection.code}-${uniqueSuffix}'
var storageId = resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.Storage/storageAccounts', storageName)
var searchId = resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.Search/searchServices', searchName)
var cosmosId = resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.DocumentDB/databaseAccounts', cosmosName)
var storageEndpoint = 'https://${storageName}.blob.${environment().suffixes.storage}/'
var searchEndpoint = 'https://${searchName}.search.windows.net'
var cosmosEndpoint = 'https://${cosmosName}.documents.azure.com:443/'
var vnetId = resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/virtualNetworks', 'vnet-${stem}')
var subnetId = resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/virtualNetworks/subnets', 'vnet-${stem}', 'snet-case-${selection.caseId}-pe')
var dnsZoneIds = {
  blob: resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.blob.${environment().suffixes.storage}')
  search: resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')
  cosmos: resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com')
}
var endpointStem = 'pe-${stem}-exp-${projectSelector}'
var privateEndpointIds = [for service in ['blob', 'search', 'cosmos']: resourceId(subscription().subscriptionId, caseGroupName, 'Microsoft.Network/privateEndpoints', '${endpointStem}-${service}')]
var provisioningRoles = [
  { resourceId: storageId, roleId: '17d1049b-9a84-46fb-8f53-869881c3d3ab' }
  { resourceId: searchId, roleId: '8ebe5a00-799e-43f5-93ac-243d3dce84a7' }
  { resourceId: searchId, roleId: '7ca78c08-252a-4471-8644-bb5ff32d4ba0' }
  { resourceId: cosmosId, roleId: '230815da-be43-4aae-9cb4-875f7bd000aa' }
]
var roleAssignmentIds = [for role in provisioningRoles: extensionResourceId(role.resourceId, 'Microsoft.Authorization/roleAssignments', guid(role.resourceId, projectPrincipalId, role.roleId))]

module dependencies 'modules/expansion-standard-dependencies.bicep' = {
  name: '${stem}-exp-standard-${projectSelector}'
  scope: resourceGroup(subscription().subscriptionId, caseGroupName)
  params: {
    location: location
    tags: tags
    accountName: accountName
    projectName: projectName
    projectPrincipalId: projectPrincipalId
    storageName: storageName
    searchName: searchName
    cosmosName: cosmosName
    endpointStem: endpointStem
    subnetId: subnetId
    dnsZoneIds: dnsZoneIds
  }
}

@description('Deterministic intended identifiers, not evidence of existence, authorization, ownership, successful provisioning or runtime readiness. All DNS zones are reused unchanged. Deploy only after exact project/identity, scope, ownership and new-resource absence checks by the coordinator.')
output standard object = {
  stage: 'dependencies'
  completeLab: false
  labId: labId
  ownershipId: ownershipId
  location: location
  projectSelector: projectSelector
  resourceGroupName: caseGroupName
  resourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', caseGroupName)
  integrationResourceGroupName: integrationGroupName
  accountId: accountId
  projectId: projectId
  projectPrincipalId: projectPrincipalId
  storage: { name: storageName, id: storageId, endpoint: storageEndpoint }
  search: { name: searchName, id: searchId, endpoint: searchEndpoint }
  cosmos: { name: cosmosName, id: cosmosId, endpoint: cosmosEndpoint }
  connections: {
    storage: { name: storageName, id: '${projectId}/connections/${storageName}' }
    search: { name: searchName, id: '${projectId}/connections/${searchName}' }
    cosmos: { name: cosmosName, id: '${projectId}/connections/${cosmosName}' }
  }
  vnetId: vnetId
  subnetId: subnetId
  privateEndpointIds: privateEndpointIds
  dnsZoneIds: dnsZoneIds
  roleAssignmentIds: roleAssignmentIds
}
