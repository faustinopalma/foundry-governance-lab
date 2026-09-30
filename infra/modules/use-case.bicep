@description('Globally unique Foundry account name.')
param accountName string
@description('Globally unique alphanumeric registry name.')
param registryName string
@description('Case identifier.')
@allowed(['a', 'b'])
param caseId string
@description('Deployment region.')
param location string
@description('Ownership tags.')
param tags object
@description('Exclusive new agent subnet.')
param agentSubnetId string
@description('Case operational metrics workspace.')
param workspaceId string
@description('Developer managed identity object ID.')
param developerPrincipalId string
@description('Publisher managed identity object ID.')
param publisherPrincipalId string
@description('Consumer object ID; empty for the case without a consumer test actor.')
param consumerPrincipalId string = ''

param minimalPrompt bool = false

var environments = minimalPrompt ? ['dev'] : ['dev', 'test']
var repository = 'case-${caseId}/test'
var readerCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${repository}\'))'
var writerCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/write\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/write\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${repository}\'))'

module account 'br/public:avm/res/cognitive-services/account:0.19.1' = {
  name: 'case-account'
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
      subnetResourceId: agentSubnetId
      useMicrosoftManagedNetwork: false
    }
    deployments: []
    roleAssignments: [{
      name: guid(accountName, 'developer-reader')
      principalId: developerPrincipalId
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

resource accountReference 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: accountName
}

resource projects 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' = [for projectEnvironment in environments: {
  parent: accountReference
  name: 'case-${caseId}-${projectEnvironment}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Case ${caseId} ${projectEnvironment}'
    description: 'Synthetic governance lab project.'
  }
  dependsOn: [account]
}]

resource developerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(accountName, caseId, 'dev-foundry-user')
  scope: projects[0]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
    principalId: developerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource consumerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(consumerPrincipalId)) {
  name: guid(accountName, caseId, 'dev-agent-consumer')
  scope: projects[0]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6')
    principalId: consumerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

var projectReaderRoles = minimalPrompt ? [] : [
  {
    name: guid(registryName, 'dev-image-reader')
    principalId: projects[0].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: 'b93aa761-3e63-49ed-ac28-beffa264f7ac'
    conditionVersion: '2.0'
    condition: readerCondition
  }
  {
    name: guid(registryName, 'test-image-reader')
    principalId: projects[min(1, length(environments) - 1)].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: 'b93aa761-3e63-49ed-ac28-beffa264f7ac'
    conditionVersion: '2.0'
    condition: readerCondition
  }
]

module registry 'br/public:avm/res/container-registry/registry:0.13.1' = if (!minimalPrompt) {
  name: 'case-registry'
  params: {
    name: registryName
    location: location
    tags: tags
    enableTelemetry: false
    acrSku: 'Premium'
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    roleAssignmentMode: 'AbacRepositoryPermissions'
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'None'
    networkRuleBypassAllowedForTasks: false
    networkRuleSetDefaultAction: 'Deny'
    networkRuleSetIpRules: []
    zoneRedundancy: 'Disabled'
    retentionPolicyStatus: 'disabled'
    exportPolicyStatus: 'disabled'
    azureADAuthenticationAsArmPolicyStatus: 'disabled'
    roleAssignments: concat([{
      name: guid(registryName, 'image-publisher')
      principalId: publisherPrincipalId
      principalType: 'ServicePrincipal'
      roleDefinitionIdOrName: '2a1e307c-b015-4ebd-883e-5b7698a07328'
      conditionVersion: '2.0'
      condition: writerCondition
    }], projectReaderRoles)
    diagnosticSettings: [{
      name: 'registry-audit'
      workspaceResourceId: workspaceId
      metricCategories: []
      logCategoriesAndGroups: [
        { category: 'ContainerRegistryLoginEvents', enabled: true }
        { category: 'ContainerRegistryRepositoryEvents', enabled: true }
      ]
    }]
  }
}

output accountId string = account.outputs.resourceId
output registryId string = minimalPrompt ? '' : registry!.outputs.resourceId
output registryLoginServer string = minimalPrompt ? '' : registry!.outputs.loginServer
output projects array = [for projectIndex in range(0, length(environments)): {
  name: projects[projectIndex].name
  resourceId: projects[projectIndex].id
  principalId: projects[projectIndex].identity.principalId
}]
