[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    function Assert-Same($Actual, $Expected, [string]$Message) {
        if (($Actual | ConvertTo-Json -Depth 100 -Compress) -cne ($Expected | ConvertTo-Json -Depth 100 -Compress)) { throw $Message }
    }
    function Assert-Keys($Value, [string[]]$Keys, [string]$Message) {
        Assert-Same (@($Value.Keys | Sort-Object) -join ',') (@($Keys | Sort-Object) -join ',') $Message
    }
    function Get-Resources($Template) {
        if ($Template.resources -is [Collections.IDictionary]) { $Template.resources.Values } else { $Template.resources }
    }
    function Get-One($Template, [string]$Type) {
        $matchingResources = @(Get-Resources $Template | Where-Object type -eq $Type)
        Assert-Same $matchingResources.Count 1 "Expected one $Type"
        return $matchingResources[0]
    }
    function Get-StageModule($Template, [string]$Suffix) {
        $expected = "[format('{0}-standard-$Suffix', variables('stem'))]"
        $matchingModules = @(Get-Resources $Template | Where-Object name -CEQ $expected)
        Assert-Same $matchingModules.Count 1 "Expected one stage module: $Suffix"
        return $matchingModules[0]
    }
    function Assert-Role($Role, [string]$Scope, [string]$Definition) {
        Assert-Same $Role.type 'Microsoft.Authorization/roleAssignments' 'Unexpected ARM role type'
        Assert-Same $Role.apiVersion '2022-04-01' 'Unexpected ARM role API'
        Assert-Same $Role.scope $Scope 'Role scope widened or redirected'
        Assert-Keys $Role.properties @('principalId', 'principalType', 'roleDefinitionId') 'Unexpected role properties'
        Assert-Same $Role.properties.principalId "[parameters('projectPrincipalId')]" 'Role assigned to another identity'
        Assert-Same $Role.properties.principalType 'ServicePrincipal' 'Unexpected principal type'
        Assert-Same $Role.properties.roleDefinitionId $Definition 'Unexpected role definition'
    }
    function Assert-ChildBoundaries($Template) {
        foreach ($resource in @(Get-Resources $Template)) {
            if ($resource.Contains('resourceGroup') -or $resource.Contains('subscriptionId')) { throw 'Nested resource escapes its assigned group/subscription' }
            if ($resource.type -eq 'Microsoft.Resources/deployments') {
                Assert-Same $resource.properties.mode 'Incremental' 'Destructive deployment mode'
                if ($resource.Contains('scope') -or $resource.properties.Contains('templateLink')) { throw 'Unexpected nested deployment target' }
                Assert-ChildBoundaries $resource.properties.template
            } elseif ($resource.type -notin @('Microsoft.Authorization/roleAssignments', 'Microsoft.Authorization/locks') -and $resource.Contains('scope')) {
                throw 'Unexpected resource scope override'
            }
        }
    }
    function Assert-EndpointHelper($Helper) {
        Assert-Same @(Get-Resources $Helper).Count 1 'PE helper gained a resource'
        $deployment = Get-One $Helper 'Microsoft.Resources/deployments'
        $arguments = $deployment.properties.parameters
        Assert-Keys $arguments @('name', 'location', 'tags', 'enableTelemetry', 'subnetResourceId', 'privateLinkServiceConnections', 'privateDnsZoneGroup') 'Unexpected PE AVM arguments'
        foreach ($name in @('name', 'location', 'tags')) { Assert-Same $arguments[$name].value "[parameters('$name')]" 'PE identity/location/tags changed' }
        Assert-Same $arguments.enableTelemetry.value $false 'PE telemetry enabled'
        Assert-Same $arguments.subnetResourceId.value "[parameters('subnetId')]" 'PE subnet not forwarded'
        Assert-Same @($arguments.privateLinkServiceConnections.value).Count 1 'Unexpected PE connection count'
        $connection = $arguments.privateLinkServiceConnections.value[0]
        Assert-Same $connection.properties.privateLinkServiceId "[parameters('targetId')]" 'PE target not forwarded'
        Assert-Same $connection.properties.groupIds @("[parameters('groupId')]") 'PE group not forwarded'
        $zoneConfig = $arguments.privateDnsZoneGroup.value.copy
        Assert-Same @($zoneConfig).Count 1 'Unexpected DNS config loop count'
        Assert-Same $zoneConfig[0].count "[length(parameters('zoneIds'))]" 'DNS config count changed'
        Assert-Same $zoneConfig[0].input.privateDnsZoneResourceId "[parameters('zoneIds')[copyIndex('privateDnsZoneGroupConfigs')]]" 'PE zone not forwarded'
        $avm = $deployment.properties.template
        Assert-Keys $avm.resources @('avmTelemetry', 'privateEndpoint', 'privateEndpoint_lock', 'privateEndpoint_roleAssignments', 'privateEndpoint_privateDnsZoneGroup') 'PE AVM graph changed'
        foreach ($optional in @('roleAssignments', 'lock', 'manualPrivateLinkServiceConnections', 'applicationSecurityGroupResourceIds', 'customDnsConfigs', 'ipConfigurations')) {
            Assert-Same $avm.parameters[$optional].defaultValue $null 'Unsafe AVM optional default'
            Assert-Same $avm.parameters[$optional].nullable $true 'AVM optional input no longer nullable'
        }
        Assert-Same $avm.resources.avmTelemetry.condition "[parameters('enableTelemetry')]" 'AVM telemetry guard changed'
        Assert-Same $avm.resources.privateEndpoint_lock.condition "[and(not(empty(coalesce(parameters('lock'), createObject()))), not(equals(tryGet(parameters('lock'), 'kind'), 'None')))]" 'AVM lock guard changed'
        Assert-Same $avm.variables.copy[0].name 'formattedRoleAssignments' 'Unexpected AVM role expansion'
        Assert-Same $avm.variables.copy[0].count "[length(coalesce(parameters('roleAssignments'), createArray()))]" 'AVM empty roles no longer empty'
        Assert-Same $avm.resources.privateEndpoint_roleAssignments.copy.count "[length(coalesce(variables('formattedRoleAssignments'), createArray()))]" 'AVM role loop no longer empty'
        $endpoint = $avm.resources.privateEndpoint
        Assert-Same $endpoint.type 'Microsoft.Network/privateEndpoints' 'Unexpected endpoint resource'
        Assert-Same $endpoint.name "[parameters('name')]" 'Endpoint name changed'
        Assert-Same $endpoint.tags "[parameters('tags')]" 'Endpoint ownership lost'
        Assert-Same $endpoint.properties.subnet.id "[parameters('subnetResourceId')]" 'Endpoint subnet changed'
        Assert-Same $endpoint.properties.privateLinkServiceConnections "[coalesce(parameters('privateLinkServiceConnections'), createArray())]" 'Endpoint target binding changed'
        Assert-Same $endpoint.properties.manualPrivateLinkServiceConnections "[coalesce(parameters('manualPrivateLinkServiceConnections'), createArray())]" 'Manual endpoint connection introduced'
        $zoneDeployment = $avm.resources.privateEndpoint_privateDnsZoneGroup
        Assert-Same $zoneDeployment.condition "[not(empty(parameters('privateDnsZoneGroup')))]" 'DNS group guard changed'
        Assert-Same $zoneDeployment.properties.parameters.privateEndpointName.value "[parameters('name')]" 'DNS parent changed'
        Assert-Same $zoneDeployment.properties.parameters.privateDnsZoneConfigs.value "[parameters('privateDnsZoneGroup').privateDnsZoneGroupConfigs]" 'DNS group configs changed'
        Assert-Same $avm.variables.enableReferencedModulesTelemetry $false 'Nested telemetry enabled'
        Assert-Same $zoneDeployment.properties.parameters.enableTelemetry.value "[variables('enableReferencedModulesTelemetry')]" 'Nested telemetry override'
        $zoneTemplate = $zoneDeployment.properties.template
        Assert-Keys $zoneTemplate.resources @('privateEndpoint', 'avmTelemetry', 'privateDnsZoneGroup') 'DNS group graph changed'
        Assert-Same $zoneTemplate.resources.privateEndpoint.existing $true 'DNS group redeclares endpoint'
        Assert-Same $zoneTemplate.resources.avmTelemetry.condition "[parameters('enableTelemetry')]" 'DNS telemetry guard changed'
        $zoneGroup = $zoneTemplate.resources.privateDnsZoneGroup
        Assert-Same $zoneGroup.type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' 'Unexpected DNS group type'
        Assert-Same $zoneGroup.properties.copy[0].count "[length(parameters('privateDnsZoneConfigs'))]" 'DNS group loop changed'
        Assert-Same $zoneGroup.properties.copy[0].input.properties.privateDnsZoneId "[parameters('privateDnsZoneConfigs')[copyIndex('privateDnsZoneConfigs')].privateDnsZoneResourceId]" 'DNS zone group association changed'
    }
    function Assert-Standard($Template) {
        Assert-Same $Template.'$schema' 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#' 'Entrypoint must be subscription-scoped'
        Assert-Keys $Template.parameters @('labId', 'ownershipId', 'location', 'accountName', 'projectName', 'projectPrincipalId', 'workspaceId', 'agentContainerName', 'stage') 'Parameter contract changed'
        Assert-Same $Template.parameters.agentContainerName.type 'string' 'Agent container must be a string'
        Assert-Same $Template.parameters.agentContainerName.defaultValue '' 'Prior stages must not guess an agent container'
        Assert-Same $Template.parameters.agentContainerName.maxLength 63 'Agent container exceeds Storage naming limit'
        Assert-Same $Template.parameters.stage.allowedValues @('dependencies', 'account', 'project', 'access') 'Four stages required'
        if ($Template.parameters.stage.Contains('defaultValue')) { throw 'Stage must be explicit' }
        Assert-Same $Template.parameters.location.defaultValue 'swedencentral' 'Unexpected default location'
        Assert-Same $Template.parameters.projectName.defaultValue 'case-a-dev' 'Unexpected project default'
        Assert-Same $Template.parameters.labId.minLength 6 'Lab ID minimum changed'
        Assert-Same $Template.parameters.labId.maxLength 12 'Storage name could exceed 23 characters'
        foreach ($name in @('ownershipId', 'projectPrincipalId', 'workspaceId')) {
            Assert-Same $Template.parameters[$name].minLength $(if ($name -eq 'workspaceId') { 32 } else { 36 }) 'GUID contract missing'
            Assert-Same $Template.parameters[$name].maxLength 36 'GUID contract missing'
        }
        Assert-Same $Template.variables.stem "[format('fgl-{0}', parameters('labId'))]" 'Lab stem changed'
        Assert-Same $Template.variables.caseGroupName "[format('rg-{0}-case-a', variables('stem'))]" 'Unexpected case group'
        Assert-Same $Template.variables.integrationGroupName "[format('rg-{0}-integration', variables('stem'))]" 'Unexpected integration group'
        Assert-Same $Template.variables.storageName "[format('stfgl{0}{1}', parameters('labId'), take(uniqueString(subscription().subscriptionId, parameters('labId')), 6))]" 'Storage naming contract changed'
        Assert-Same $Template.variables.searchName "[format('srch-fgl-{0}-standard', parameters('labId'))]" 'Search naming contract changed'
        Assert-Same $Template.variables.cosmosName "[format('cosmos-fgl-{0}-standard', parameters('labId'))]" 'Cosmos naming contract changed'
        Assert-Same $Template.variables.compactWorkspaceId "[replace(toLower(parameters('workspaceId')), '-', '')]" 'Workspace normalization changed'
        Assert-Same $Template.variables.containerWorkspaceId "[format('{0}-{1}-{2}-{3}-{4}', substring(variables('compactWorkspaceId'), 0, 8), substring(variables('compactWorkspaceId'), 8, 4), substring(variables('compactWorkspaceId'), 12, 4), substring(variables('compactWorkspaceId'), 16, 4), substring(variables('compactWorkspaceId'), 20, 12))]" 'Container workspace must use GUID D format'
        Assert-Same $Template.variables.tags.'fgl-lab' "[parameters('labId')]" 'Lab tag missing'
        Assert-Same $Template.variables.tags.'fgl-owner' "[parameters('ownershipId')]" 'Ownership tag missing'
        Assert-Same $Template.variables.vnetId "[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/virtualNetworks', format('vnet-{0}', variables('stem')))]" 'Wrong existing VNet'
        Assert-Same $Template.variables.subnetId "[format('{0}/subnets/snet-case-a-pe', variables('vnetId'))]" 'Wrong case-a PE subnet'
        Assert-Same $Template.variables.dnsZoneIds.blob "[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/privateDnsZones', format('privatelink.blob.{0}', environment().suffixes.storage))]" 'Wrong reused Blob zone'
        Assert-Same $Template.variables.dnsZoneIds.search "[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')]" 'Wrong Search zone'
        Assert-Same $Template.variables.dnsZoneIds.cosmos "[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com')]" 'Wrong Cosmos zone'
        Assert-Same @(Get-Resources $Template).Count 5 'Unexpected subscription-level resource'
        $modules = @{}
        foreach ($suffix in @('dns', 'dependencies', 'account', 'project', 'access')) {
            $module = Get-StageModule $Template $suffix
            $modules[$suffix] = $module
            $expectedStage = if ($suffix -eq 'dns') { 'dependencies' } else { $suffix }
            $expectedGroup = if ($suffix -eq 'dns') { 'integrationGroupName' } else { 'caseGroupName' }
            Assert-Same $module.type 'Microsoft.Resources/deployments' 'Only nested deployments may be emitted at subscription scope'
            Assert-Same $module.condition "[equals(parameters('stage'), '$expectedStage')]" 'Stage condition missing or broadened'
            Assert-Same $module.resourceGroup "[variables('$expectedGroup')]" 'Deployment escapes the two owned groups'
            if ($module.Contains('subscriptionId') -or $module.Contains('scope')) { throw 'Cross-subscription deployment not allowed' }
            Assert-Same $module.properties.mode 'Incremental' 'Destructive deployment mode'
            Assert-Same $module.properties.expressionEvaluationOptions.scope 'inner' 'Module scope must be inner'
            Assert-Keys $module.properties.parameters @($module.properties.template.parameters.Keys) 'Module parameter contract mismatch'
            foreach ($name in $module.properties.parameters.Keys) {
                $expected = if ($name -eq 'workspaceId') { "[variables('containerWorkspaceId')]" } elseif ($name -in @('tags', 'storageName', 'searchName', 'cosmosName', 'subnetId', 'dnsZoneIds')) { "[variables('$name')]" } else { "[parameters('$name')]" }
                Assert-Same $module.properties.parameters[$name].value $expected "Parameter routing changed: $suffix/$name"
            }
            Assert-ChildBoundaries $module.properties.template
        }
        foreach ($stage in @('dependencies', 'account', 'project', 'access')) {
            $selected = @(Get-Resources $Template | Where-Object condition -CEQ "[equals(parameters('stage'), '$stage')]")
            Assert-Same $selected.Count $(if ($stage -eq 'dependencies') { 2 } else { 1 }) "Wrong graph for stage $stage"
        }
        $dns = $modules.dns.properties.template
        Assert-Same @(Get-Resources $dns).Count 2 'DNS stage must not recreate VNet or Blob zone'
        Assert-Same $dns.variables.zoneNames @('privatelink.search.windows.net', 'privatelink.documents.azure.com') 'Only two new DNS zones allowed'
        $zones = Get-One $dns 'Microsoft.Network/privateDnsZones'
        $links = Get-One $dns 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
        foreach ($resource in @($zones, $links)) {
            Assert-Same $resource.copy.count "[length(variables('zoneNames'))]" 'Wrong DNS count'
            Assert-Same $resource.tags "[parameters('tags')]" 'DNS ownership missing'
            Assert-Same $resource.location 'global' 'Wrong DNS location'
        }
        Assert-Same $zones.name "[variables('zoneNames')[copyIndex()]]" 'Wrong zone names'
        Assert-Same $links.name "[format('{0}/{1}', variables('zoneNames')[copyIndex()], 'standard-lab-only')]" 'Wrong zone-link names'
        Assert-Same $links.properties.registrationEnabled $false 'DNS registration must be disabled'
        Assert-Same $links.properties.virtualNetwork.id "[resourceId('Microsoft.Network/virtualNetworks', format('vnet-fgl-{0}', parameters('labId')))]" 'DNS linked to another network'
        $dependencies = $modules.dependencies.properties.template
        Assert-Same @(Get-Resources $dependencies).Count 10 'Unexpected dependency resources'
        Assert-Same $modules.dependencies.dependsOn @("[extensionResourceId(format('/subscriptions/{0}/resourceGroups/{1}', subscription().subscriptionId, variables('integrationGroupName')), 'Microsoft.Resources/deployments', format('{0}-standard-dns', variables('stem')))]") 'DNS must precede dependencies'
        $serviceTypes = @{ storage = 'Microsoft.Storage/storageAccounts'; search = 'Microsoft.Search/searchServices'; cosmos = 'Microsoft.DocumentDB/databaseAccounts' }
        $services = @{}
        foreach ($service in $serviceTypes.Keys) {
            $resource = Get-One $dependencies $serviceTypes[$service]
            $services[$service] = $resource
            Assert-Same $resource.name "[parameters('${service}Name')]" 'Service name changed'
            Assert-Same $resource.location "[parameters('location')]" 'Service location changed'
            Assert-Same $resource.tags "[parameters('tags')]" 'Service ownership missing'
            Assert-Same $resource.properties.publicNetworkAccess $(if ($service -eq 'search') { 'disabled' } else { 'Disabled' }) 'Public service access enabled'
            if ($resource.Contains('condition')) { throw 'Dependency unexpectedly conditional' }
        }
        $storage = $services.storage
        Assert-Same $storage.sku.name 'Standard_LRS' 'Storage SKU changed'
        foreach ($property in @('allowSharedKeyAccess', 'allowBlobPublicAccess', 'allowCrossTenantReplication')) { Assert-Same $storage.properties[$property] $false 'Storage key/public/cross-tenant access enabled' }
        Assert-Same $storage.properties.supportsHttpsTrafficOnly $true 'Storage HTTPS required'
        Assert-Same $storage.properties.minimumTlsVersion 'TLS1_2' 'Storage TLS minimum changed'
        Assert-Same $storage.properties.networkAcls.bypass 'None' 'Storage network bypass enabled'
        Assert-Same $storage.properties.networkAcls.defaultAction 'Deny' 'Storage firewall opened'
        Assert-Same @($storage.properties.networkAcls.ipRules).Count 0 'Storage IP exception'
        Assert-Same @($storage.properties.networkAcls.virtualNetworkRules).Count 0 'Storage service endpoint exception'
        $search = $services.search
        Assert-Same $search.sku.name 'basic' 'Search SKU changed'
        Assert-Same $search.identity.type 'SystemAssigned' 'Search SMI missing'
        Assert-Same $search.properties.disableLocalAuth $true 'Search local authentication enabled'
        if ($search.properties.Contains('authOptions')) { throw 'Search API-key fallback must not be configured' }
        Assert-Same $search.properties.networkRuleSet.bypass 'None' 'Search network bypass enabled'
        Assert-Same @($search.properties.networkRuleSet.ipRules).Count 0 'Search IP exception'
        $cosmos = $services.cosmos
        Assert-Same $cosmos.kind 'GlobalDocumentDB' 'Cosmos must be NoSQL'
        Assert-Same $cosmos.properties.disableLocalAuth $true 'Cosmos local authentication enabled'
        Assert-Same $cosmos.properties.networkAclBypass 'None' 'Cosmos network bypass enabled'
        Assert-Same $cosmos.properties.capacity.totalThroughputLimit 5000 'Expected capacity for five 1000-RU/s containers'
        if ($cosmos.properties.Contains('capabilities')) { Assert-Same @($cosmos.properties.capabilities).Count 0 'Unexpected Cosmos capability such as Serverless' }
        Assert-Same @($cosmos.properties.ipRules).Count 0 'Cosmos IP exception'
        Assert-Same @($cosmos.properties.virtualNetworkRules).Count 0 'Cosmos service endpoint exception'
        $connections = @(Get-Resources $dependencies | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/projects/connections')
        Assert-Same $connections.Count 3 'Exactly three project connections required'
        $categories = @{ storage = 'AzureStorageAccount'; search = 'CognitiveSearch'; cosmos = 'CosmosDb' }
        $targets = @{ storage = "[reference(resourceId('Microsoft.Storage/storageAccounts', parameters('storageName')), '2023-05-01').primaryEndpoints.blob]"; search = "[format('https://{0}.search.windows.net', parameters('searchName'))]"; cosmos = "[reference(resourceId('Microsoft.DocumentDB/databaseAccounts', parameters('cosmosName')), '2024-11-15').documentEndpoint]" }
        foreach ($service in $categories.Keys) {
            $matchingConnections = @($connections | Where-Object { $_.properties.category -ceq $categories[$service] })
            Assert-Same $matchingConnections.Count 1 'Connection category mismatch'
            $connection = $matchingConnections[0]
            Assert-Same $connection.apiVersion '2026-05-01' 'Unexpected connection API'
            Assert-Same $connection.name "[format('{0}/{1}/{2}', parameters('accountName'), parameters('projectName'), parameters('${service}Name'))]" 'Connection escaped existing project'
            Assert-Keys $connection.properties @('category', 'target', 'authType', 'isSharedToAll', 'metadata') 'Unexpected connection properties or credentials'
            Assert-Same $connection.properties.authType 'AAD' 'Connection is not Entra authenticated'
            Assert-Same $connection.properties.isSharedToAll $false 'Connection shared beyond project'
            Assert-Same $connection.properties.target $targets[$service] 'Connection target redirected'
            Assert-Same $connection.properties.metadata.ApiType 'Azure' 'Connection ApiType mismatch'
            Assert-Same $connection.properties.metadata.ResourceId "[resourceId('$($serviceTypes[$service])', parameters('${service}Name'))]" 'Connection resource mismatch'
            Assert-Same $connection.properties.metadata.location "[parameters('location')]" 'Connection location mismatch'
        }
        $roles = @(Get-Resources $dependencies | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
        Assert-Same $roles.Count 3 'Unexpected dependency role definitions'
        Assert-Role $roles[0] "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageName'))]" "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab')]"
        Assert-Role $roles[1] "[resourceId('Microsoft.DocumentDB/databaseAccounts', parameters('cosmosName'))]" "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '230815da-be43-4aae-9cb4-875f7bd000aa')]"
        Assert-Role $roles[2] "[resourceId('Microsoft.Search/searchServices', parameters('searchName'))]" "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', variables('searchRoleIds')[copyIndex()])]"
        Assert-Same $dependencies.variables.searchRoleIds @('8ebe5a00-799e-43f5-93ac-243d3dce84a7', '7ca78c08-252a-4471-8644-bb5ff32d4ba0') 'Unexpected Search permissions'
        Assert-Same $roles[2].copy.count "[length(variables('searchRoleIds'))]" 'Search role loop changed'
        $endpointDefinitions = $dependencies.variables.endpointDefinitions
        Assert-Same @($endpointDefinitions).Count 3 'Exactly three PEs required'
        $endpointGroups = @('blob', 'searchService', 'Sql')
        $endpointServices = @('blob', 'search', 'cosmos')
        $targetServices = @('storage', 'search', 'cosmos')
        foreach ($index in 0..2) {
            $definition = $endpointDefinitions[$index]
            $service = $targetServices[$index]
            Assert-Same $definition.service $endpointServices[$index] 'PE name service mismatch'
            Assert-Same $definition.groupId $endpointGroups[$index] 'Wrong PE service group'
            Assert-Same $definition.targetId "[resourceId('$($serviceTypes[$service])', parameters('${service}Name'))]" 'Wrong PE target'
            Assert-Same $definition.zoneId "[parameters('dnsZoneIds').$($endpointServices[$index])]" 'Wrong PE DNS zone'
        }
        $endpoints = Get-One $dependencies 'Microsoft.Resources/deployments'
        Assert-Same $endpoints.copy.count "[length(variables('endpointDefinitions'))]" 'PE loop count changed'
        $arguments = $endpoints.properties.parameters
        Assert-Same $arguments.name.value "[format('pe-fgl-{0}-standard-{1}', parameters('labId'), variables('endpointDefinitions')[copyIndex()].service)]" 'PE ownership naming changed'
        Assert-Same $arguments.subnetId.value "[parameters('subnetId')]" 'PE subnet routing changed'
        Assert-Same $arguments.targetId.value "[variables('endpointDefinitions')[copyIndex()].targetId]" 'PE target routing changed'
        Assert-Same $arguments.groupId.value "[variables('endpointDefinitions')[copyIndex()].groupId]" 'PE group routing changed'
        Assert-Same $arguments.zoneIds.value @("[variables('endpointDefinitions')[copyIndex()].zoneId]") 'PE zone routing changed'
        Assert-Same $arguments.tags.value "[parameters('tags')]" 'PE ownership routing changed'
        Assert-EndpointHelper $endpoints.properties.template
        $account = $modules.account.properties.template
        $project = $modules.project.properties.template
        Assert-Same @(Get-Resources $account).Count 1 'Account stage must create only its host'
        Assert-Same @(Get-Resources $project).Count 1 'Project stage must create only its host'
        $accountHost = Get-One $account 'Microsoft.CognitiveServices/accounts/capabilityHosts'
        $projectHost = Get-One $project 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts'
        foreach ($hostResource in @($accountHost, $projectHost)) { Assert-Same $hostResource.apiVersion '2026-05-01' 'Host API changed' }
        Assert-Same $accountHost.name "[format('{0}/{1}', parameters('accountName'), 'agents')]" 'Account host parent/name changed'
        Assert-Keys $accountHost.properties @('capabilityHostKind') 'Account host must contain only Agents kind'
        Assert-Same $accountHost.properties.capabilityHostKind 'Agents' 'Wrong capability host kind'
        Assert-Same $projectHost.name "[format('{0}/{1}/{2}', parameters('accountName'), parameters('projectName'), 'agents')]" 'Project host parent/name changed'
        Assert-Keys $projectHost.properties @('storageConnections', 'vectorStoreConnections', 'threadStorageConnections') 'Project host must contain only the three connections'
        Assert-Same $projectHost.properties.storageConnections @("[parameters('storageName')]") 'Wrong host storage connection'
        Assert-Same $projectHost.properties.vectorStoreConnections @("[parameters('searchName')]") 'Wrong host search connection'
        Assert-Same $projectHost.properties.threadStorageConnections @("[parameters('cosmosName')]") 'Wrong host Cosmos connection'
        $access = $modules.access.properties.template
        Assert-Keys $access.parameters @('storageName','cosmosName','projectPrincipalId','workspaceId','agentContainerName') 'Access parameter contract changed'
        Assert-Same $access.parameters.agentContainerName.minLength 50 'Exact agent container name required'
        Assert-Same $access.parameters.agentContainerName.maxLength 63 'Agent container name limit changed'
        if ($access.parameters.agentContainerName.Contains('defaultValue')) { throw 'Access must require the discovered agent container' }
        Assert-Same @(Get-Resources $access).Count 3 'Access stage must contain only granular roles'
        $blobRoles = @(Get-Resources $access | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
        Assert-Same $blobRoles.Count 2 'Exactly two container roles required'
        Assert-Role $blobRoles[0] "[resourceId('Microsoft.Storage/storageAccounts/blobServices/containers', parameters('storageName'), 'default', format('{0}-azureml-blobstore', parameters('workspaceId')))]" "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')]"
        Assert-Role $blobRoles[1] "[resourceId('Microsoft.Storage/storageAccounts/blobServices/containers', parameters('storageName'), 'default', parameters('agentContainerName'))]" "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')]"
        $cosmosRole = Get-One $access 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments'
        Assert-Keys $cosmosRole.properties @('principalId', 'roleDefinitionId', 'scope') 'Unexpected native role properties'
        Assert-Same $cosmosRole.properties.principalId "[parameters('projectPrincipalId')]" 'Native role assigned to another identity'
        Assert-Same $cosmosRole.properties.roleDefinitionId "[format('{0}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002', resourceId('Microsoft.DocumentDB/databaseAccounts', parameters('cosmosName')))]" 'Wrong native role'
        Assert-Same $cosmosRole.properties.scope "[format('{0}/dbs/enterprise_memory', resourceId('Microsoft.DocumentDB/databaseAccounts', parameters('cosmosName')))]" 'Native scope must cover the database, not account or Classic-only containers'
        Assert-Keys $Template.outputs @('standard') 'Unexpected outputs'
        $output = $Template.outputs.standard.value
        Assert-Same $output.workspaceId "[toLower(parameters('workspaceId'))]" 'Output workspace ID must preserve its original GUID format'
        Assert-Same $output.containers.blobstore "[format('{0}/blobServices/default/containers/{1}-azureml-blobstore', variables('storageId'), variables('containerWorkspaceId'))]" 'Blobstore output binding changed'
        Assert-Same $output.containers.agent "[if(empty(parameters('agentContainerName')), '', format('{0}/blobServices/default/containers/{1}', variables('storageId'), parameters('agentContainerName')))]" 'Agent output must use exact discovery or be empty'
        foreach ($service in @('storage', 'search', 'cosmos')) {
            Assert-Same $output[$service].name "[variables('${service}Name')]" 'Output name differs from deployed name'
            Assert-Same $output[$service].id "[variables('${service}Id')]" 'Output ID differs from deployed ID'
            Assert-Same $Template.variables["${service}Id"] "[resourceId(subscription().subscriptionId, variables('caseGroupName'), '$($serviceTypes[$service])', variables('${service}Name'))]" 'Output ID escapes case-a'
            Assert-Same $output.connections[$service].name "[variables('${service}Name')]" 'Output connection name differs'
        }
        Assert-Same $output.dnsZoneIds "[variables('dnsZoneIds')]" 'Output DNS zones differ'
        Assert-Same $output.subnetId "[variables('subnetId')]" 'Output subnet differs'
        Assert-Same $output.reusedBlobDnsZone $true 'Blob DNS reuse must be explicit'
        $serialized = $Template | ConvertTo-Json -Depth 100 -Compress
        if ($serialized -match '(?i)\blist(Keys|AccountSas|ServiceSas|ConnectionStrings)\(') { throw 'Secret/key retrieval in template' }
        $outputText = $output | ConvertTo-Json -Depth 100 -Compress
        if ($outputText -match '(?i)\breference\(') { throw 'Outputs must not reference skipped stages' }
    }

    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    if ($document.Contains('template')) {
        if (-not $document.success -or @($document.diagnostics | Where-Object level -eq 'Error').Count) { throw 'Compiler reported errors' }
        $document = $document.template | ConvertFrom-Json -AsHashtable -Depth 100
    }
    Assert-Standard $document
    $baseline = $document | ConvertTo-Json -Depth 100 -Compress
    $mutations = @(
        { param($template) $template.parameters.Remove('agentContainerName') },
        { param($template) $template.parameters.agentContainerName.defaultValue = 'guessed-agent' },
        { param($template) (Get-StageModule $template 'access').properties.parameters.agentContainerName.value = "[parameters('workspaceId')]" },
        { param($template) @(Get-Resources (Get-StageModule $template 'access').properties.template | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')[1].scope = "[resourceId('Microsoft.Storage/storageAccounts/blobServices/containers', parameters('storageName'), 'default', format('{0}-azureml-agent', parameters('workspaceId')))]" },
        { param($template) $template.outputs.standard.value.containers.agent = 'guessed-agent' },
        { param($template) $template.variables.containerWorkspaceId = "[parameters('workspaceId')]" },
        { param($template) (Get-StageModule $template 'account').condition = $true },
        { param($template) (Get-StageModule $template 'project').condition = "[equals(parameters('stage'), 'account')]" },
        { param($template) (Get-StageModule $template 'access').resourceGroup = 'unowned-group' },
        { param($template) (Get-StageModule $template 'dependencies').subscriptionId = 'other-subscription' },
        { param($template) (Get-StageModule $template 'dependencies').properties.mode = 'Complete' },
        { param($template) $template.variables.subnetId = '/external/subnets/snet-pe-a' },
        { param($template) $template.variables.storageName = 'unownedstorage' },
        { param($template) (Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.Storage/storageAccounts').properties.publicNetworkAccess = 'Enabled' },
        { param($template) (Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.Search/searchServices').properties.publicNetworkAccess = 'enabled' },
        { param($template) (Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.DocumentDB/databaseAccounts').properties.publicNetworkAccess = 'Enabled' },
        { param($template) (Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.Storage/storageAccounts').properties.allowSharedKeyAccess = $true },
        { param($template) (Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.Storage/storageAccounts').properties.networkAcls.bypass = 'AzureServices' },
        { param($template) (Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.Search/searchServices').properties.disableLocalAuth = $false },
        { param($template) (Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.DocumentDB/databaseAccounts').properties.disableLocalAuth = $false },
        { param($template) (Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.DocumentDB/databaseAccounts').properties.capacity.totalThroughputLimit = 3000 },
        { param($template) (Get-StageModule $template 'dns').properties.template.variables.zoneNames += 'privatelink.blob.core.windows.net' },
        { param($template) (Get-One (Get-StageModule $template 'dns').properties.template 'Microsoft.Network/privateDnsZones/virtualNetworkLinks').properties.virtualNetwork.id = '/external/vnet' },
        { param($template) (Get-StageModule $template 'dependencies').properties.template.variables.endpointDefinitions[0].zoneId = "[parameters('dnsZoneIds').search]" },
        { param($template) (Get-StageModule $template 'dependencies').properties.template.variables.searchRoleIds += '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' },
        { param($template) @(Get-Resources (Get-StageModule $template 'dependencies').properties.template | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/projects/connections')[0].properties.authType = 'ApiKey' },
        { param($template) @(Get-Resources (Get-StageModule $template 'dependencies').properties.template | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/projects/connections')[0].properties.isSharedToAll = $true },
        { param($template) @(Get-Resources (Get-StageModule $template 'access').properties.template | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')[0].scope = "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageName'))]" },
        { param($template) @(Get-Resources (Get-StageModule $template 'access').properties.template | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')[1].properties.principalId = 'other-principal' },
        { param($template) (Get-One (Get-StageModule $template 'access').properties.template 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments').properties.scope = '/' },
        { param($template) (Get-One (Get-StageModule $template 'access').properties.template 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments').properties.scope += '/colls/thread-message-store' },
        { param($template) (Get-One (Get-StageModule $template 'project').properties.template 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts').properties.storageConnections = @('unowned-storage') },
        { param($template) (Get-StageModule $template 'account').properties.template.resources += @{ type = 'Microsoft.CognitiveServices/accounts'; name = 'forbidden' } },
        { param($template) $template.outputs.standard.value.storage.id = '/external/storage' },
        { param($template) $endpoint = Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.Resources/deployments'; (Get-One $endpoint.properties.template 'Microsoft.Resources/deployments').properties.parameters.enableTelemetry.value = $true },
        { param($template) $endpoint = Get-One (Get-StageModule $template 'dependencies').properties.template 'Microsoft.Resources/deployments'; (Get-One $endpoint.properties.template 'Microsoft.Resources/deployments').properties.template.resources.privateEndpoint_roleAssignments.copy.count = 1 }
    )
    foreach ($mutation in $mutations) {
        $altered = $baseline | ConvertFrom-Json -AsHashtable -Depth 100
        & $mutation $altered
        $rejected = $false
        try { Assert-Standard $altered } catch { $rejected = $true }
        if (-not $rejected) { throw "Negative control was accepted: $mutation" }
    }
    Write-Output "PASS: four Standard stage graphs, two-group boundary, private services, DNS/PE bindings, AAD connections and narrowed project-MI roles; $($mutations.Count) deliberate regressions rejected. Structural validation only; no ARM evaluation or runtime proof."
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"
}