@description('Lab naming stem.')
param stem string
@description('Deployment region.')
param location string
@description('Ownership tags.')
param tags object

var actors = ['dev-a', 'consumer-a', 'dev-b', 'publisher-a', 'publisher-b', 'client', 'denied']

module identities 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = [for actor in actors: {
  name: 'identity-${actor}'
  params: {
    name: 'id-${stem}-${actor}'
    location: location
    tags: tags
    enableTelemetry: false
  }
}]

output actors array = [for (actor, actorIndex) in actors: {
  actor: actor
  resourceId: identities[actorIndex].outputs.resourceId
  principalId: identities[actorIndex].outputs.principalId
  clientId: identities[actorIndex].outputs.clientId
}]
