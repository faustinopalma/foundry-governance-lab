@description('Lab naming stem.')
param stem string
@description('Deployment region.')
param location string
@description('Ownership tags.')
param tags object

module publicIp 'br/public:avm/res/network/public-ip-address:0.13.0' = {
  name: 'egress-ip'
  params: {
    name: 'pip-${stem}'
    location: location
    tags: tags
    enableTelemetry: false
    availabilityZones: []
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
  }
}

module nat 'br/public:avm/res/network/nat-gateway:2.1.1' = {
  name: 'nat'
  params: {
    name: 'nat-${stem}'
    location: location
    tags: tags
    enableTelemetry: false
    availabilityZone: -1
    natGatewaySku: 'Standard'
    publicIpResourceIds: [publicIp.outputs.resourceId]
  }
}

var agentRules = [for caseIndex in range(0, 2): [
  {
    name: 'deny-other-case'
    properties: {
      priority: 100
      direction: 'Outbound'
      access: 'Deny'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: '*'
      destinationAddressPrefixes: caseIndex == 0 ? ['10.76.2.0/24', '10.76.7.0/27'] : ['10.76.1.0/24', '10.76.6.0/27']
    }
  }
  {
    name: 'deny-central-and-runner'
    properties: {
      priority: 110
      direction: 'Outbound'
      access: 'Deny'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: '*'
      destinationAddressPrefixes: ['10.76.4.0/27', '10.76.5.0/27']
    }
  }
]]

module agentNsg 'br/public:avm/res/network/network-security-group:0.5.3' = [for caseIndex in range(0, 2): {
  name: 'agent-nsg-${caseIndex}'
  params: {
    name: 'nsg-${stem}-agent-${caseIndex}'
    location: location
    tags: tags
    enableTelemetry: false
    securityRules: agentRules[caseIndex]
  }
}]

module endpointNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'endpoint-nsg'
  params: {
    name: 'nsg-${stem}-endpoints'
    location: location
    tags: tags
    enableTelemetry: false
    securityRules: [
      {
        name: 'allow-runner'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '10.76.4.0/27'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'allow-gateway-to-models'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '10.76.3.0/26'
          destinationAddressPrefixes: ['10.76.5.0/27', '10.76.8.0/27']
        }
      }
      {
        name: 'allow-case-a'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '10.76.1.0/24'
          destinationAddressPrefixes: ['10.76.6.0/27', '10.76.8.0/27']
        }
      }
      {
        name: 'allow-case-b'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '10.76.2.0/24'
          destinationAddressPrefixes: ['10.76.7.0/27', '10.76.8.0/27']
        }
      }
      {
        name: 'deny-other-inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

module runnerNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'runner-nsg'
  params: {
    name: 'nsg-${stem}-runner'
    location: location
    tags: tags
    enableTelemetry: false
    securityRules: [{
      name: 'deny-inbound'
      properties: {
        priority: 100
        direction: 'Inbound'
        access: 'Deny'
        protocol: '*'
        sourcePortRange: '*'
        destinationPortRange: '*'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
      }
    }]
  }
}

module apimNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'apim-nsg'
  params: {
    name: 'nsg-${stem}-apim'
    location: location
    tags: tags
    enableTelemetry: false
    securityRules: [{
      name: 'deny-case-endpoints'
      properties: {
        priority: 100
        direction: 'Outbound'
        access: 'Deny'
        protocol: '*'
        sourcePortRange: '*'
        destinationPortRange: '*'
        sourceAddressPrefix: '*'
        destinationAddressPrefixes: ['10.76.6.0/27', '10.76.7.0/27']
      }
    }]
  }
}

var subnetDefinitions = [
  { name: 'snet-agent-a', addressPrefix: '10.76.1.0/24', delegation: 'Microsoft.App/environments', networkSecurityGroupResourceId: agentNsg[0].outputs.resourceId, natGatewayResourceId: nat.outputs.resourceId }
  { name: 'snet-agent-b', addressPrefix: '10.76.2.0/24', delegation: 'Microsoft.App/environments', networkSecurityGroupResourceId: agentNsg[1].outputs.resourceId, natGatewayResourceId: nat.outputs.resourceId }
  { name: 'snet-apim', addressPrefix: '10.76.3.0/26', delegation: 'Microsoft.Web/serverFarms', networkSecurityGroupResourceId: apimNsg.outputs.resourceId }
  { name: 'snet-runner', addressPrefix: '10.76.4.0/27', networkSecurityGroupResourceId: runnerNsg.outputs.resourceId, natGatewayResourceId: nat.outputs.resourceId, defaultOutboundAccess: false }
  { name: 'snet-models-pe', addressPrefix: '10.76.5.0/27', networkSecurityGroupResourceId: endpointNsg.outputs.resourceId, privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled' }
  { name: 'snet-case-a-pe', addressPrefix: '10.76.6.0/27', networkSecurityGroupResourceId: endpointNsg.outputs.resourceId, privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled' }
  { name: 'snet-case-b-pe', addressPrefix: '10.76.7.0/27', networkSecurityGroupResourceId: endpointNsg.outputs.resourceId, privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled' }
  { name: 'snet-integration-pe', addressPrefix: '10.76.8.0/27', networkSecurityGroupResourceId: endpointNsg.outputs.resourceId, privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled' }
]

module network 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'network'
  params: {
    name: 'vnet-${stem}'
    location: location
    tags: tags
    enableTelemetry: false
    addressPrefixes: ['10.76.0.0/16']
    subnets: subnetDefinitions
    peerings: []
  }
}

var zoneNames = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
  'privatelink.azurecr.io'
  'privatelink.azure-api.net'
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}'
]

module zones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [for (zoneName, zoneIndex) in zoneNames: {
  name: 'dns-${zoneIndex}'
  params: {
    name: zoneName
    tags: tags
    enableTelemetry: false
    virtualNetworkLinks: [{
      name: 'lab-only'
      virtualNetworkResourceId: network.outputs.resourceId
      registrationEnabled: false
      resolutionPolicy: 'Default'
    }]
  }
}]

output subnetIds object = toObject(subnetDefinitions, subnet => subnet.name, subnet => '${network.outputs.resourceId}/subnets/${subnet.name}')
output dnsZoneIds array = [for (zoneName, zoneIndex) in zoneNames: zones[zoneIndex].outputs.resourceId]
