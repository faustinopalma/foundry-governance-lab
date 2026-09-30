@description('Globally unique account name.')
param name string
@description('Deployment region.')
param location string
@description('Ownership tags.')
param tags object
@description('Lab operational metrics workspace.')
param workspaceId string

module account 'br/public:avm/res/cognitive-services/account:0.19.1' = {
  name: 'models-account'
  params: {
    name: name
    location: location
    tags: tags
    enableTelemetry: false
    kind: 'AIServices'
    sku: 'S0'
    customSubDomainName: name
    allowProjectManagement: false
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    restrictOutboundNetworkAccess: true
    managedIdentities: { systemAssigned: true }
    networkAcls: { defaultAction: 'Deny', bypass: 'None', ipRules: [], virtualNetworkRules: [] }
    deployments: [{
      name: 'lab-chat'
      model: { format: 'OpenAI', name: 'gpt-4.1-mini', version: '2025-04-14' }
      sku: { name: 'GlobalStandard', capacity: 10 }
      versionUpgradeOption: 'NoAutoUpgrade'
    }]
    diagnosticSettings: [{
      name: 'metrics-only'
      workspaceResourceId: workspaceId
      metricCategories: [{ category: 'AllMetrics', enabled: true }]
      logCategoriesAndGroups: []
    }]
  }
}

output resourceId string = account.outputs.resourceId
output name string = account.outputs.name
