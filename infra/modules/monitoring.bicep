@description('Lab naming stem.')
param stem string

@description('Deployment region.')
param location string

@description('Ownership tags.')
param tags object

module workspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'workspace'
  params: {
    name: 'log-${stem}'
    location: location
    tags: tags
    enableTelemetry: false
    skuName: 'PerGB2018'
    dataRetention: 30
    dailyQuotaGb: '0.1'
    forceCmkForQuery: false
    features: {
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: false
    }
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

module insights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'insights'
  params: {
    name: 'appi-${stem}'
    location: location
    tags: tags
    enableTelemetry: false
    kind: 'web'
    workspaceResourceId: workspace.outputs.resourceId
    disableLocalAuth: true
    disableIpMasking: false
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

output workspaceId string = workspace.outputs.resourceId
output insightsId string = insights.outputs.resourceId
