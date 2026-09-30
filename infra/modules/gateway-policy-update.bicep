@description('Existing owned lab gateway name.')
param gatewayName string
@description('Existing private central model account name.')
param modelAccountName string
@description('Original project principals followed by the original gateway test client principal; no added callers.')
param allowedPrincipalIds array

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: gatewayName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' existing = {
  parent: gateway
  name: 'lab-inference'
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
}
