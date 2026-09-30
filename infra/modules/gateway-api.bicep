@description('Lab gateway name.')
param gatewayName string
@description('Central lab model account name.')
param modelAccountName string
@description('Four project object IDs and the explicit gateway test client object ID.')
param allowedPrincipalIds array

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: gatewayName
}

resource bodySchema 'Microsoft.ApiManagement/service/schemas@2024-05-01' = {
  parent: gateway
  name: 'lab-chat-body'
  properties: {
    schemaType: 'json'
    document: loadJsonContent('../policies/chat.schema.json')
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: gateway
  name: 'lab-inference'
  properties: {
    displayName: 'Lab inference'
    path: 'openai'
    protocols: ['https']
    subscriptionRequired: false
    apiType: 'http'
  }
}

resource operation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'chat'
  properties: {
    displayName: 'Approved deployment chat'
    method: 'POST'
    urlTemplate: '/deployments/lab-chat/chat/completions'
    request: {
      representations: [{ contentType: 'application/json' }]
    }
    responses: []
  }
}

var callerIds = join(allowedPrincipalIds, ',')
var tenantPolicy = replace(loadTextContent('../policies/inference.xml'), '__TENANT__', tenant().tenantId)
var backendPolicy = replace(tenantPolicy, '__MODEL_ACCOUNT__', modelAccountName)

resource policy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(backendPolicy, '__CALLERS__', callerIds)
  }
  dependsOn: [operation, bodySchema]
}
