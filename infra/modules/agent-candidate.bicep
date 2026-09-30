@description('New use-case account name.')
param accountName string
@description('Case identifier.')
@allowed(['a', 'b'])
param caseId string
@description('New lab APIM hostname, without protocol.')
param gatewayHost string
@description('Optional preview capability hosts, independent of the governed model connection.')
param enableCapabilityHosts bool = false
param minimalPrompt bool = false

resource account 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: accountName
}

resource connection 'Microsoft.CognitiveServices/accounts/connections@2026-05-01' = if (!minimalPrompt) {
  parent: account
  name: 'governed-models'
  properties: {
    category: 'ApiManagement'
    authType: 'AAD'
    target: 'https://${gatewayHost}/openai'
    isSharedToAll: true
    metadata: {
      deploymentInPath: 'true'
      inferenceAPIVersion: '2024-10-21'
      models: string([{
        name: 'lab-chat'
        properties: { model: { name: 'gpt-4.1-mini', version: '2025-04-14', format: 'OpenAI' } }
      }])
    }
  }
}

var environments = minimalPrompt ? ['dev'] : ['dev', 'test']

resource projects 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' existing = [for projectEnvironment in environments: {
  parent: account
  name: 'case-${caseId}-${projectEnvironment}'
}]

resource projectConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (minimalPrompt) {
  parent: projects[0]
  name: 'governed-models'
  properties: {
    category: 'ApiManagement'
    authType: 'ProjectManagedIdentity'
    audience: 'https://cognitiveservices.azure.com'
    target: 'https://${gatewayHost}/openai'
    isSharedToAll: false
    credentials: {}
    metadata: {
      deploymentInPath: 'true'
      inferenceAPIVersion: '2024-10-21'
      models: string([{
        name: 'lab-chat'
        properties: { model: { name: 'gpt-4.1-mini', version: '2025-04-14', format: 'OpenAI' } }
      }])
    }
  }
}

@batchSize(1)
resource capabilityHosts 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = [for projectIndex in range(0, length(environments)): if (enableCapabilityHosts && !minimalPrompt) {
  parent: projects[projectIndex]
  name: 'agents'
  properties: {
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
  }
  dependsOn: [connection]
}]
