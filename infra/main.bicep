targetScope = 'subscription'

@description('Existing gateway system identity verified by the activation coordinator; empty in earlier stages.')
param gatewayPrincipalId string = ''

@description('Lowercase alphanumeric lab identifier, validated by the local safety scripts.')
@minLength(6)
@maxLength(12)
param labId string
@description('Ownership GUID stored in external private state. Not a credential.')
param ownershipId string
@description('Approved lab region. Azure public cloud only.')
@allowed(['swedencentral'])
param location string = 'swedencentral'
@description('Explicit staged provisioning. Bootstrap has no inference API; lock verifies private access before activate.')
@allowed(['bootstrap', 'lock', 'activate'])
param phase string = 'bootstrap'
@description('Publisher contact from external private parameters.')
param publisherEmail string
@description('SSH public key from external private parameters.')
param sshPublicKey string
@description('Optional preview capability hosts. The governed model connection is created during activation independently.')
param enableExperimentalAgents bool = false

@description('Opt-in prompt-only topology: case a dev only, no registries or hosted capability hosts.')
param minimalPrompt bool = false

var stem = 'fgl-${labId}'
var uniqueSuffix = uniqueString(subscription().id, labId)
var tags = { 'fgl-lab': labId, 'fgl-owner': ownershipId, purpose: 'synthetic-governance-lab' }
var groupSuffixes = minimalPrompt ? ['models', 'integration', 'case-a'] : ['models', 'integration', 'case-a', 'case-b']
var modelName = 'aif-${stem}-models-${uniqueSuffix}'
var gatewayName = 'apim-${stem}-${uniqueSuffix}'
var caseNames = ['aif-${stem}-a-${uniqueSuffix}', 'aif-${stem}-b-${uniqueSuffix}']
var registryNames = ['crfgl${labId}a${uniqueSuffix}', 'crfgl${labId}b${uniqueSuffix}']
var caseIds = minimalPrompt ? ['a'] : ['a', 'b']

resource groups 'Microsoft.Resources/resourceGroups@2025-04-01' = [for suffix in groupSuffixes: {
  name: 'rg-${stem}-${suffix}'
  location: location
  tags: tags
}]

module network 'modules/network.bicep' = {
  name: '${stem}-network'
  scope: resourceGroup('rg-${stem}-integration')
  params: { stem: stem, location: location, tags: tags }
  dependsOn: [groups]
}

module identities 'modules/identities.bicep' = {
  name: '${stem}-identities'
  scope: resourceGroup('rg-${stem}-integration')
  params: { stem: stem, location: location, tags: tags }
  dependsOn: [groups]
}

module monitoring 'modules/monitoring.bicep' = [for monitorIndex in range(0, length(caseIds) + 1): {
  name: '${stem}-monitor-${monitorIndex}'
  scope: resourceGroup('rg-${stem}-${groupSuffixes[monitorIndex + 1]}')
  params: { stem: '${stem}-${groupSuffixes[monitorIndex + 1]}', location: location, tags: tags }
  dependsOn: [groups]
}]

module models 'modules/models.bicep' = {
  name: '${stem}-models'
  scope: resourceGroup('rg-${stem}-models')
  params: {
    name: modelName
    location: location
    tags: tags
    workspaceId: monitoring[0].outputs.workspaceId
  }
}

module cases 'modules/use-case.bicep' = [for (caseId, caseIndex) in caseIds: {
  name: '${stem}-case-${caseId}'
  scope: resourceGroup('rg-${stem}-case-${caseId}')
  params: {
    accountName: caseNames[caseIndex]
    minimalPrompt: minimalPrompt
    registryName: registryNames[caseIndex]
    caseId: caseId
    location: location
    tags: tags
    agentSubnetId: network.outputs.subnetIds['snet-agent-${caseId}']
    workspaceId: monitoring[caseIndex + 1].outputs.workspaceId
    developerPrincipalId: identities.outputs.actors[caseIndex == 0 ? 0 : 2].principalId
    consumerPrincipalId: caseIndex == 0 ? identities.outputs.actors[1].principalId : ''
    publisherPrincipalId: identities.outputs.actors[caseIndex + 3].principalId
  }
  dependsOn: [groups]
}]

module gateway 'modules/gateway.bicep' = {
  name: '${stem}-gateway'
  scope: resourceGroup('rg-${stem}-integration')
  params: {
    name: gatewayName
    location: location
    tags: tags
    subnetId: network.outputs.subnetIds['snet-apim']
    publisherEmail: publisherEmail
    privateOnly: phase != 'bootstrap'
    workspaceId: monitoring[0].outputs.workspaceId
  }
}

module monitorScope 'modules/monitor-scope.bicep' = {
  name: '${stem}-monitor-scope'
  scope: resourceGroup('rg-${stem}-integration')
  params: {
    stem: stem
    tags: tags
    linkedResourceIds: concat([
      monitoring[0].outputs.workspaceId
      monitoring[0].outputs.insightsId
      monitoring[1].outputs.workspaceId
      monitoring[1].outputs.insightsId
    ], minimalPrompt ? [] : [monitoring[min(2, length(caseIds))].outputs.workspaceId, monitoring[min(2, length(caseIds))].outputs.insightsId])
  }
}

module modelEndpoint 'modules/private-endpoint.bicep' = {
  name: '${stem}-model-endpoint'
  scope: resourceGroup('rg-${stem}-models')
  params: {
    name: 'pe-${stem}-models'
    location: location
    tags: tags
    targetId: models.outputs.resourceId
    groupId: 'account'
    subnetId: network.outputs.subnetIds['snet-models-pe']
    zoneIds: take(network.outputs.dnsZoneIds, 3)
  }
}

module caseEndpoints 'modules/private-endpoint.bicep' = [for (caseId, caseIndex) in caseIds: {
  name: '${stem}-case-${caseId}-endpoint'
  scope: resourceGroup('rg-${stem}-case-${caseId}')
  params: {
    name: 'pe-${stem}-case-${caseId}'
    location: location
    tags: tags
    targetId: cases[caseIndex].outputs.accountId
    groupId: 'account'
    subnetId: network.outputs.subnetIds['snet-case-${caseId}-pe']
    zoneIds: take(network.outputs.dnsZoneIds, 3)
  }
}]

module registryEndpoints 'modules/private-endpoint.bicep' = [for (caseId, caseIndex) in caseIds: if (!minimalPrompt) {
  name: '${stem}-registry-${caseId}-endpoint'
  scope: resourceGroup('rg-${stem}-case-${caseId}')
  params: {
    name: 'pe-${stem}-registry-${caseId}'
    location: location
    tags: tags
    targetId: cases[caseIndex].outputs.registryId
    groupId: 'registry'
    subnetId: network.outputs.subnetIds['snet-case-${caseId}-pe']
    zoneIds: [network.outputs.dnsZoneIds[3]]
  }
}]

module gatewayEndpoint 'modules/private-endpoint.bicep' = {
  name: '${stem}-gateway-endpoint'
  scope: resourceGroup('rg-${stem}-integration')
  params: {
    name: 'pe-${stem}-gateway'
    location: location
    tags: tags
    targetId: gateway.outputs.resourceId
    groupId: 'Gateway'
    subnetId: network.outputs.subnetIds['snet-integration-pe']
    zoneIds: [network.outputs.dnsZoneIds[4]]
  }
}

module monitorEndpoint 'modules/private-endpoint.bicep' = {
  name: '${stem}-monitor-endpoint'
  scope: resourceGroup('rg-${stem}-integration')
  params: {
    name: 'pe-${stem}-monitor'
    location: location
    tags: tags
    targetId: monitorScope.outputs.resourceId
    groupId: 'azuremonitor'
    subnetId: network.outputs.subnetIds['snet-integration-pe']
    zoneIds: skip(network.outputs.dnsZoneIds, 5)
  }
}

module runner 'modules/runner.bicep' = {
  name: '${stem}-runner'
  scope: resourceGroup('rg-${stem}-integration')
  params: {
    stem: stem
    location: location
    tags: tags
    subnetId: network.outputs.subnetIds['snet-runner']
    sshPublicKey: sshPublicKey
    identityIds: map(identities.outputs.actors, actor => actor.resourceId)
  }
}

module inferenceRole 'modules/inference-role.bicep' = if (phase == 'activate') {
  name: '${stem}-inference-role'
  scope: resourceGroup('rg-${stem}-models')
  params: { accountName: modelName, principalId: gatewayPrincipalId }
  dependsOn: [models]
}

module gatewayApi 'modules/gateway-api.bicep' = if (phase == 'activate') {
  name: '${stem}-gateway-api'
  scope: resourceGroup('rg-${stem}-integration')
  params: {
    gatewayName: gatewayName
    modelAccountName: modelName
    allowedPrincipalIds: concat(
      map(cases[0].outputs.projects, project => project.principalId),
      minimalPrompt ? [] : map(cases[min(1, length(caseIds) - 1)].outputs.projects, project => project.principalId),
      [identities.outputs.actors[5].principalId]
    )
  }
  dependsOn: [gatewayEndpoint, inferenceRole]
}

module agentCandidates 'modules/agent-candidate.bicep' = [for (caseId, caseIndex) in caseIds: if (phase == 'activate') {
  name: '${stem}-agent-candidate-${caseId}'
  scope: resourceGroup('rg-${stem}-case-${caseId}')
  params: {
    accountName: caseNames[caseIndex]
    caseId: caseId
    gatewayHost: '${gatewayName}.azure-api.net'
    minimalPrompt: minimalPrompt
    enableCapabilityHosts: enableExperimentalAgents
  }
  dependsOn: [cases, gatewayApi, caseEndpoints, registryEndpoints]
}]

output lab object = {
  phase: phase
  minimalPrompt: minimalPrompt
  resourceGroups: map(groupSuffixes, suffix => 'rg-${stem}-${suffix}')
  models: models.outputs.resourceId
  gateway: gateway.outputs.resourceId
  runner: runner.outputs.resourceId
  identities: identities.outputs.actors
  cases: concat([
    { accountId: cases[0].outputs.accountId, registryId: cases[0].outputs.registryId, projects: cases[0].outputs.projects }
  ], minimalPrompt ? [] : [
    { accountId: cases[min(1, length(caseIds) - 1)].outputs.accountId, registryId: cases[min(1, length(caseIds) - 1)].outputs.registryId, projects: cases[min(1, length(caseIds) - 1)].outputs.projects }
  ])
}
