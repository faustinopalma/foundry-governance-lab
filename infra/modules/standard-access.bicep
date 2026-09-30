@description('New Standard storage account name in case-a.')
param storageName string
@description('New Standard Cosmos DB account name in case-a.')
param cosmosName string
@description('Verified existing project managed identity object ID.')
param projectPrincipalId string
@description('Lowercase Foundry workspace GUID. Coordinator must first verify the service-created containers and enterprise_memory database exist.')
param workspaceId string
@description('Exact service-created agent container name verified by the coordinator; never guessed or created by this module.')
@minLength(50)
@maxLength(63)
param agentContainerName string

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storage
  name: 'default'
}

resource blobstore 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: blobService
  name: '${workspaceId}-azureml-blobstore'
}

resource agent 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: blobService
  name: agentContainerName
}

resource blobstoreContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: blobstore
  name: guid(blobstore.id, projectPrincipalId, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

resource agentOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: agent
  name: guid(agent.id, projectPrincipalId, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  }
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosName
}

resource cosmosDataContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, projectPrincipalId, 'enterprise_memory', '00000000-0000-0000-0000-000000000002')
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: '${cosmos.id}/dbs/enterprise_memory'
  }
}
