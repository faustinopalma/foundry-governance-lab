@description('Existing owned Foundry account. The expansion coordinator must verify its identity and private networking before deployment.')
param accountName string

@description('Case A retains its existing dev project; case B receives both projects.')
@allowed(['a', 'b'])
param caseId string

@allowed(['swedencentral'])
param location string = 'swedencentral'

@minLength(6)
@maxLength(12)
param labId string

@description('Ownership GUID from the original private lab state.')
param ownershipId string

var environments = caseId == 'a' ? ['test'] : ['dev', 'test']
var tags = { 'fgl-lab': labId, 'fgl-owner': ownershipId, purpose: 'synthetic-governance-lab' }

resource account 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: accountName
}

resource projects 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' = [for projectEnvironment in environments: {
  parent: account
  name: 'case-${caseId}-${projectEnvironment}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Case ${caseId} ${projectEnvironment}'
    description: 'Synthetic governance lab project.'
  }
}]

output projects array = [for projectIndex in range(0, length(environments)): {
  name: projects[projectIndex].name
  resourceId: projects[projectIndex].id
  principalId: projects[projectIndex].identity.principalId
}]
