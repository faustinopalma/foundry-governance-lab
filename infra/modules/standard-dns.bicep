@description('Lab identifier. This module must be scoped to the existing integration resource group.')
param labId string
@description('Lab ownership tags.')
param tags object

resource network 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: 'vnet-fgl-${labId}'
}

var zoneNames = ['privatelink.search.windows.net', 'privatelink.documents.azure.com']

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zoneName in zoneNames: {
  name: zoneName
  location: 'global'
  tags: tags
}]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zoneName, zoneIndex) in zoneNames: {
  parent: zones[zoneIndex]
  name: 'standard-lab-only'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: network.id }
  }
}]
