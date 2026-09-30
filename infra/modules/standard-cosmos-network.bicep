targetScope = 'resourceGroup'

@minLength(6)
@maxLength(12)
param labId string

@description('All and only the verified Cosmos private endpoint NIC IPv4 addresses, each with /32.')
@minLength(1)
@maxLength(5)
param cosmosPrivateAddresses array

var endpointNsgName = 'nsg-fgl-${labId}-endpoints'

resource endpointNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = {
  name: endpointNsgName
}

resource cosmosDirect 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  parent: endpointNsg
  name: 'allow-case-a-cosmos-direct'
  properties: {
    priority: 125
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: '10.76.1.0/24'
    sourcePortRange: '*'
    destinationAddressPrefixes: cosmosPrivateAddresses
    destinationPortRange: '*'
  }
}

output ruleId string = resourceId('Microsoft.Network/networkSecurityGroups/securityRules', endpointNsg.name, 'allow-case-a-cosmos-direct')
