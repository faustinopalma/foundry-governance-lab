metadata description = 'Foundation stage only. Invoke account mode in the new case-b group or monitor-links mode in the existing integration group; never replay retained parents.'

@description('The root fixes both mode and resource group. The link-only invocation must not create an account, projects or roles.')
@allowed(['account', 'monitor-links'])
param mode string

@minLength(6)
@maxLength(12)
param labId string

@description('Original ownership GUID; externally verified before any separately authorized deployment.')
param ownershipId string

@allowed(['swedencentral'])
param location string = 'swedencentral'

var stem = 'fgl-${labId}'
var uniqueSuffix = uniqueString(subscription().id, labId)
var accountName = 'aif-${stem}-b-${uniqueSuffix}'
var integrationGroupName = 'rg-${stem}-integration'
var caseBGroupName = 'rg-${stem}-case-b'
var tags = { 'fgl-lab': labId, 'fgl-owner': ownershipId, purpose: 'synthetic-governance-lab' }
var workspaceId = resourceId(caseBGroupName, 'Microsoft.OperationalInsights/workspaces', 'log-${stem}-case-b')
var insightsId = resourceId(caseBGroupName, 'Microsoft.Insights/components', 'appi-${stem}-case-b')

resource developer 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: 'id-${stem}-dev-b'
  scope: resourceGroup(integrationGroupName)
}

module account 'br/public:avm/res/cognitive-services/account:0.19.1' = if (mode == 'account') {
  name: 'expansion-case-account'
  params: {
    name: accountName
    location: location
    tags: tags
    enableTelemetry: false
    kind: 'AIServices'
    sku: 'S0'
    customSubDomainName: accountName
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    restrictOutboundNetworkAccess: false
    managedIdentities: { systemAssigned: true }
    networkAcls: { defaultAction: 'Deny', bypass: 'None', ipRules: [], virtualNetworkRules: [] }
    networkInjections: {
      scenario: 'agent'
      subnetResourceId: resourceId(integrationGroupName, 'Microsoft.Network/virtualNetworks/subnets', 'vnet-${stem}', 'snet-agent-b')
      useMicrosoftManagedNetwork: false
    }
    deployments: []
    roleAssignments: [{
      name: guid(accountName, 'developer-reader')
      principalId: developer.properties.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionIdOrName: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    }]
    diagnosticSettings: [{
      name: 'metrics-only'
      workspaceResourceId: workspaceId
      metricCategories: [{ category: 'AllMetrics', enabled: true }]
      logCategoriesAndGroups: []
    }]
  }
}

module newProjects 'expansion-projects.bicep' = if (mode == 'account') {
  name: 'expansion-projects-b'
  params: { accountName: accountName, caseId: 'b', labId: labId, ownershipId: ownershipId, location: location }
  dependsOn: [account]
}

resource accountReference 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: accountName
}

resource devProject 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' existing = {
  parent: accountReference
  name: 'case-b-dev'
}

resource developerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (mode == 'account') {
  name: guid(accountName, 'b', 'dev-foundry-user')
  scope: devProject
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
    principalId: developer.properties.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [newProjects]
}

resource monitorScope 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' existing = {
  name: 'ampls-${stem}'
}

resource workspaceLink 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = if (mode == 'monitor-links') {
  parent: monitorScope
  name: 'linked-4'
  properties: { linkedResourceId: workspaceId }
}

resource insightsLink 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = if (mode == 'monitor-links') {
  parent: monitorScope
  name: 'linked-5'
  properties: { linkedResourceId: insightsId }
}

output accountId string = mode == 'account' ? account!.outputs.resourceId : ''
output projects array = mode == 'account' ? newProjects!.outputs.projects : []
output monitoringLinkIds array = mode == 'monitor-links' ? [workspaceLink!.id, insightsLink!.id] : []
output roleAssignmentIds array = mode == 'account' ? [
  extensionResourceId(accountReference.id, 'Microsoft.Authorization/roleAssignments', guid(accountName, 'developer-reader'))
  developerRole!.id
] : []
