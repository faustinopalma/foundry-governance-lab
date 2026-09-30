@description('Globally unique gateway name.')
param name string
@description('Deployment region.')
param location string
@description('Ownership tags.')
param tags object
@description('New Standard v2 outbound integration subnet.')
param subnetId string
@description('Publisher contact supplied through external private parameters.')
param publisherEmail string
@description('True only in the lockdown and activation stages, after private endpoint approval.')
param privateOnly bool
@description('Gateway workspace for metrics only; payload logging is not enabled.')
param workspaceId string

module gateway 'br/public:avm/res/api-management/service:0.14.4' = {
  name: 'gateway'
  params: {
    name: name
    location: location
    tags: tags
    enableTelemetry: false
    publisherEmail: publisherEmail
    publisherName: 'Foundry Governance Lab'
    sku: 'StandardV2'
    skuCapacity: 1
    managedIdentities: { systemAssigned: true }
    subnetResourceId: subnetId
    virtualNetworkType: 'External'
    availabilityZones: []
    customProperties: {}
    enableDeveloperPortal: false
    publicNetworkAccess: privateOnly ? 'Disabled' : 'Enabled'
    diagnosticSettings: [{
      name: 'metrics-only'
      workspaceResourceId: workspaceId
      metricCategories: [{ category: 'AllMetrics', enabled: true }]
      logCategoriesAndGroups: []
    }]
  }
}

output resourceId string = gateway.outputs.resourceId
output principalId string = gateway.outputs.systemAssignedMIPrincipalId!
