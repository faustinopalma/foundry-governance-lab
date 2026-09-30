@description('Existing owned case-a Foundry resource. Coordinator must confirm no capability host already exists; hosts cannot be updated.')
param accountName string

resource account 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: accountName
}

resource host 'Microsoft.CognitiveServices/accounts/capabilityHosts@2026-05-01' = {
  parent: account
  name: 'agents'
  properties: {
    capabilityHostKind: 'Agents'
  }
}

output resourceId string = host.id
