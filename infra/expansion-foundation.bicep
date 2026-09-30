targetScope = 'subscription'

metadata description = 'Additive foundation stage only, not a complete governance lab. Local preparation does not release the observation hold or approve security prerequisites.'

@description('Confirms review of foundation creation only. This value is not evidence of authorization, release of the observation hold, or approval of security prerequisites. Mandatory; no default.')
@allowed([true])
param reviewedFoundationCreation bool

@description('Original lowercase alphanumeric lab identifier. Verify against owned existing resources before any later deployment.')
@minLength(6)
@maxLength(12)
param labId string

@description('Original ownership GUID. Deployment requires separate verification against the existing lab; no private state is read by this template.')
param ownershipId string

@allowed(['swedencentral'])
param location string = 'swedencentral'

var stem = 'fgl-${labId}'
var uniqueSuffix = uniqueString(subscription().id, labId)
var tags = { 'fgl-lab': labId, 'fgl-owner': ownershipId, purpose: 'synthetic-governance-lab' }
var integrationGroupName = 'rg-${stem}-integration'
var caseAGroupName = 'rg-${stem}-case-a'
var caseBGroupName = 'rg-${stem}-case-b'
var caseAAccountName = 'aif-${stem}-a-${uniqueSuffix}'
var zoneNames = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
]

resource caseBGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = if (reviewedFoundationCreation) {
  name: caseBGroupName
  location: location
  tags: tags
}

module monitoringB 'modules/monitoring.bicep' = if (reviewedFoundationCreation) {
  name: '${stem}-expansion-monitor-b'
  scope: resourceGroup(caseBGroupName)
  params: { stem: '${stem}-case-b', location: location, tags: tags }
  dependsOn: [caseBGroup]
}

module caseB 'modules/expansion-case-account.bicep' = if (reviewedFoundationCreation) {
  name: '${stem}-expansion-case-b'
  scope: resourceGroup(caseBGroupName)
  params: { mode: 'account', labId: labId, ownershipId: ownershipId, location: location }
  dependsOn: [caseBGroup, monitoringB]
}

module projectATest 'modules/expansion-projects.bicep' = if (reviewedFoundationCreation) {
  name: '${stem}-expansion-project-a-test'
  scope: resourceGroup(caseAGroupName)
  params: {
    accountName: caseAAccountName
    caseId: 'a'
    labId: labId
    ownershipId: ownershipId
    location: location
  }
}

module caseBEndpoint 'modules/private-endpoint.bicep' = if (reviewedFoundationCreation) {
  name: '${stem}-expansion-case-b-endpoint'
  scope: resourceGroup(caseBGroupName)
  params: {
    name: 'pe-${stem}-case-b'
    location: location
    tags: tags
    targetId: caseB!.outputs.accountId
    groupId: 'account'
    subnetId: resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/virtualNetworks/subnets', 'vnet-${stem}', 'snet-case-b-pe')
    zoneIds: [for zoneName in zoneNames: resourceId(subscription().subscriptionId, integrationGroupName, 'Microsoft.Network/privateDnsZones', zoneName)]
  }
  dependsOn: [caseBGroup]
}

module monitorLinksB 'modules/expansion-case-account.bicep' = if (reviewedFoundationCreation) {
  name: '${stem}-expansion-monitor-links-b'
  scope: resourceGroup(integrationGroupName)
  params: { mode: 'monitor-links', labId: labId, ownershipId: ownershipId, location: location }
  dependsOn: [monitoringB]
}

output foundation object = {
  stage: 'foundation-only'
  completeLab: false
  resourceGroupId: caseBGroup!.id
  workspaceId: monitoringB!.outputs.workspaceId
  insightsId: monitoringB!.outputs.insightsId
  caseBAccountId: caseB!.outputs.accountId
  projects: concat(projectATest!.outputs.projects, caseB!.outputs.projects)
  privateEndpointId: caseBEndpoint!.outputs.resourceId
  privateDnsZoneGroupId: '${caseBEndpoint!.outputs.resourceId}/privateDnsZoneGroups/default'
  monitoringLinkIds: monitorLinksB!.outputs.monitoringLinkIds
  roleAssignmentIds: caseB!.outputs.roleAssignmentIds
  accountDiagnosticSettingId: '${caseB!.outputs.accountId}/providers/Microsoft.Insights/diagnosticSettings/metrics-only'
  limitations: [
    'Observation hold remains active; prerequisite approvals must be recorded separately from this review flag.'
    'Before any later deployment, verify original subscription, lab identifier, ownership, retained resource identities and absence of every intended new resource, including AMPLS linked-4 and linked-5.'
    'Verify exclusive delegated snet-agent-b, existing snet-case-b-pe, private DNS zones, existing AMPLS private-only settings, and synthetic dev-b UAMI before creation.'
    'No retained parent updates, ACRs, models, project connections, capability hosts, Standard dependencies, APIM allowlist updates or runtime readiness are included.'
    'Creation-time network injection and private configuration are template intent only; effective isolation, DNS, RBAC propagation, monitoring and agent operation require separately authorized live checks.'
  ]
}
