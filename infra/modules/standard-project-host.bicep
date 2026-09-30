@description('Existing owned case-a Foundry resource.')
param accountName string
@description('Existing project. Coordinator must confirm no capability host already exists and the account host has succeeded.')
param projectName string
@description('Project-scoped AzureStorageAccount connection name, not a resource ID.')
param storageName string
@description('Project-scoped CognitiveSearch connection name, not a resource ID.')
param searchName string
@description('Project-scoped CosmosDb connection name, not a resource ID.')
param cosmosName string

resource account 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' existing = {
  parent: account
  name: projectName
}

resource host 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2026-05-01' = {
  parent: project
  name: 'agents'
  properties: {
    storageConnections: [storageName]
    vectorStoreConnections: [searchName]
    threadStorageConnections: [cosmosName]
  }
}

output resourceId string = host.id
