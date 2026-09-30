@description('Central model account name.')
param accountName string
@description('APIM system-assigned object ID. No other direct inference principal is accepted by the root template.')
param principalId string

resource account 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: accountName
}

resource inference 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, principalId, 'central-inference')
  scope: account
  properties: {
    principalType: 'ServicePrincipal'
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
  }
}
