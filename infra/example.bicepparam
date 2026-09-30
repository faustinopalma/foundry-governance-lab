using './main.bicep'

param labId = 'sample01'
param ownershipId = '33333333-3333-4333-8333-333333333333'
param publisherEmail = 'operator@example.invalid'
param sshPublicKey = 'REPLACE_WITH_PUBLIC_KEY_IN_EXTERNAL_PARAMETERS'
param location = 'swedencentral'
param phase = 'bootstrap'
param enableExperimentalAgents = false
