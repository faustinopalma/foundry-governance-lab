@description('Private endpoint name.')
param name string
@description('Deployment region.')
param location string
@description('Ownership tags.')
param tags object
@description('New lab target resource ID.')
param targetId string
@description('Target service group.')
param groupId string
@description('New lab subnet ID.')
param subnetId string
@description('New lab private DNS zone IDs.')
param zoneIds array

module endpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: name
  params: {
    name: name
    location: location
    tags: tags
    enableTelemetry: false
    subnetResourceId: subnetId
    privateLinkServiceConnections: [{
      name: name
      properties: {
        privateLinkServiceId: targetId
        groupIds: [groupId]
      }
    }]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [for zoneId in zoneIds: {
        name: last(split(zoneId, '/'))
        privateDnsZoneResourceId: zoneId
      }]
    }
  }
}

output resourceId string = endpoint.outputs.resourceId
