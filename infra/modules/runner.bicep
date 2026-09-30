@description('Lab naming stem.')
param stem string
@description('Deployment region.')
param location string
@description('Ownership tags.')
param tags object
@description('Private runner subnet.')
param subnetId string
@description('Seven synthetic test identity resource IDs.')
param identityIds array
@description('SSH public key from external private parameters; never a private key.')
param sshPublicKey string

module runner 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'runner'
  params: {
    name: 'vm-${stem}-runner'
    location: location
    tags: tags
    enableTelemetry: false
    vmSize: 'Standard_D2s_v5'
    availabilityZone: -1
    osType: 'Linux'
    adminUsername: 'labadmin'
    disablePasswordAuthentication: true
    publicKeys: [{ keyData: sshPublicKey, path: '/home/labadmin/.ssh/authorized_keys' }]
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    bootDiagnostics: true
    imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
    osDisk: {
      createOption: 'FromImage'
      diskSizeGB: 32
      caching: 'ReadWrite'
      deleteOption: 'Detach'
      managedDisk: { storageAccountType: 'StandardSSD_LRS' }
    }
    managedIdentities: { userAssignedResourceIds: identityIds }
    nicConfigurations: [{
      name: 'nic-${stem}-runner'
      enableAcceleratedNetworking: true
      enableIPForwarding: false
      deleteOption: 'Detach'
      ipConfigurations: [{ name: 'private', subnetResourceId: subnetId, privateIPAllocationMethod: 'Dynamic' }]
    }]
  }
}

output resourceId string = runner.outputs.resourceId
