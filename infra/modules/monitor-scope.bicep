@description('Lab naming stem.')
param stem string
@description('Ownership tags.')
param tags object
@description('Three lab workspaces and three lab Application Insights resources.')
param linkedResourceIds array

module scope 'br/public:avm/res/insights/private-link-scope:0.7.3' = {
  name: 'monitor-scope'
  params: {
    name: 'ampls-${stem}'
    tags: tags
    enableTelemetry: false
    accessModeSettings: { ingestionAccessMode: 'PrivateOnly', queryAccessMode: 'PrivateOnly' }
    scopedResources: [for (resourceId, resourceIndex) in linkedResourceIds: {
      name: 'linked-${resourceIndex}'
      linkedResourceId: resourceId
    }]
  }
}

output resourceId string = scope.outputs.resourceId
