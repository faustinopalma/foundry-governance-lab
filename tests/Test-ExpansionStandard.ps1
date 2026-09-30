[CmdletBinding()]
param([string]$BicepExecutable = 'bicep')

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$statistics = @{ Assertions = 0 }
try {
    function Assert-Same($Actual, $Expected, [string]$Message) {
        $statistics.Assertions++
        if ((ConvertTo-Json -InputObject $Actual -Depth 100 -Compress) -cne (ConvertTo-Json -InputObject $Expected -Depth 100 -Compress)) { throw $Message }
    }
    function Assert-Keys($Value, [string[]]$Keys, [string]$Message) {
        Assert-Same (@($Value.Keys | Sort-Object) -join ',') (@($Keys | Sort-Object) -join ',') $Message
    }
    function Get-Resources($Template) {
        if ($Template.resources -is [Collections.IDictionary]) { $Template.resources.Values } else { $Template.resources }
    }
    function Get-One($Template, [string]$Type) {
        $matches = @(Get-Resources $Template | Where-Object type -CEQ $Type)
        Assert-Same $matches.Count 1 "Expected exactly one $Type"
        return $matches[0]
    }
    function Get-Dependencies($Template) { (Get-One $Template 'Microsoft.Resources/deployments').properties.template }
    function Get-Avm($Template) {
        $helper = (Get-One (Get-Dependencies $Template) 'Microsoft.Resources/deployments').properties.template
        (Get-One $helper 'Microsoft.Resources/deployments').properties.template
    }
    function Assert-ChildBoundaries($Template) {
        $allowedTypes = @('Microsoft.Resources/deployments', 'Microsoft.Storage/storageAccounts', 'Microsoft.Search/searchServices', 'Microsoft.DocumentDB/databaseAccounts', 'Microsoft.CognitiveServices/accounts/projects/connections', 'Microsoft.Authorization/roleAssignments', 'Microsoft.Authorization/locks', 'Microsoft.Network/privateEndpoints', 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')
        foreach ($resource in @(Get-Resources $Template)) {
            Assert-Same ($resource.type -cin $allowedTypes) $true "Forbidden resource type: $($resource.type)"
            foreach ($escape in @('subscriptionId', 'resourceGroup')) { Assert-Same $resource.Contains($escape) $false "Nested resource escapes assigned scope: $escape" }
            if ($resource.type -eq 'Microsoft.Resources/deployments') {
                Assert-Same $resource.properties.mode 'Incremental' 'Destructive deployment mode'
                Assert-Same $resource.Contains('scope') $false 'Nested deployment scope override'
                Assert-Same $resource.properties.Contains('templateLink') $false 'Linked template is outside the checked graph'
                if ($resource.properties.Contains('expressionEvaluationOptions')) {
                    Assert-Same $resource.properties.expressionEvaluationOptions.scope 'inner' 'Nested expressions must use inner scope'
                } else {
                    Assert-Same $resource.condition "[parameters('enableTelemetry')]" 'Only disabled telemetry wrappers may omit expression scope'
                    Assert-Same @(Get-Resources $resource.properties.template).Count 0 'Telemetry wrapper must have no resources'
                }
                Assert-ChildBoundaries $resource.properties.template
            } elseif ($resource.type -notin @('Microsoft.Authorization/roleAssignments', 'Microsoft.Authorization/locks')) {
                Assert-Same $resource.Contains('scope') $false 'Unexpected resource scope override'
            }
        }
    }
    function Assert-EndpointHelper($Helper) {
        Assert-Same @(Get-Resources $Helper).Count 1 'PE helper gained resources'
        $deployment = Get-One $Helper 'Microsoft.Resources/deployments'
        Assert-Same $deployment.name "[parameters('name')]" 'PE AVM deployment name must remain project-specific'
        $arguments = $deployment.properties.parameters
        Assert-Keys $arguments @('name', 'location', 'tags', 'enableTelemetry', 'subnetResourceId', 'privateLinkServiceConnections', 'privateDnsZoneGroup') 'Unexpected PE AVM inputs'
        foreach ($name in @('name', 'location', 'tags')) { Assert-Same $arguments[$name].value "[parameters('$name')]" 'PE ownership/location routing changed' }
        Assert-Same $arguments.enableTelemetry.value $false 'PE telemetry enabled'
        Assert-Same $arguments.subnetResourceId.value "[parameters('subnetId')]" 'PE subnet not forwarded'
        Assert-Same @($arguments.privateLinkServiceConnections.value).Count 1 'Exactly one PE connection required'
        $connection = $arguments.privateLinkServiceConnections.value[0]
        Assert-Keys $connection @('name', 'properties') 'Unexpected PE connection input'
        Assert-Same $connection.name "[parameters('name')]" 'PE connection name changed'
        Assert-Keys $connection.properties @('privateLinkServiceId', 'groupIds') 'Unexpected PE connection properties'
        Assert-Same $connection.properties.privateLinkServiceId "[parameters('targetId')]" 'PE target not forwarded'
        Assert-Same $connection.properties.groupIds @("[parameters('groupId')]") 'PE service group not forwarded'
        Assert-Keys $arguments.privateDnsZoneGroup.value @('name', 'copy') 'Unexpected DNS group inputs'
        Assert-Same $arguments.privateDnsZoneGroup.value.name 'default' 'DNS group name changed'
        $zoneConfig = $arguments.privateDnsZoneGroup.value.copy
        Assert-Same @($zoneConfig).Count 1 'Unexpected DNS config loop count'
        Assert-Same $zoneConfig[0].name 'privateDnsZoneGroupConfigs' 'DNS config property changed'
        Assert-Same $zoneConfig[0].count "[length(parameters('zoneIds'))]" 'DNS config count changed'
        Assert-Same $zoneConfig[0].input.privateDnsZoneResourceId "[parameters('zoneIds')[copyIndex('privateDnsZoneGroupConfigs')]]" 'DNS zone not forwarded'
        $avm = $deployment.properties.template
        Assert-Keys $avm.resources @('avmTelemetry', 'privateEndpoint', 'privateEndpoint_lock', 'privateEndpoint_roleAssignments', 'privateEndpoint_privateDnsZoneGroup') 'AVM resource envelope changed'
        foreach ($optional in @('roleAssignments', 'lock', 'manualPrivateLinkServiceConnections', 'applicationSecurityGroupResourceIds', 'customDnsConfigs', 'ipConfigurations')) {
            Assert-Same $avm.parameters[$optional].defaultValue $null 'Unsafe AVM optional default'
            Assert-Same $avm.parameters[$optional].nullable $true 'AVM optional input is not nullable'
        }
        Assert-Same $avm.resources.avmTelemetry.condition "[parameters('enableTelemetry')]" 'AVM telemetry guard changed'
        Assert-Same $avm.resources.privateEndpoint_lock.condition "[and(not(empty(coalesce(parameters('lock'), createObject()))), not(equals(tryGet(parameters('lock'), 'kind'), 'None')))]" 'AVM lock guard changed'
        Assert-Same @($avm.variables.copy).Count 1 'AVM variable loop changed'
        Assert-Same $avm.variables.copy[0].name 'formattedRoleAssignments' 'AVM role expansion changed'
        Assert-Same $avm.variables.copy[0].count "[length(coalesce(parameters('roleAssignments'), createArray()))]" 'AVM empty role input changed'
        Assert-Same $avm.resources.privateEndpoint_roleAssignments.copy.count "[length(coalesce(variables('formattedRoleAssignments'), createArray()))]" 'AVM empty role loop changed'
        $endpoint = $avm.resources.privateEndpoint
        Assert-Same $endpoint.type 'Microsoft.Network/privateEndpoints' 'Unexpected endpoint type'
        foreach ($name in @('name', 'location', 'tags')) { Assert-Same $endpoint[$name] "[parameters('$name')]" 'Endpoint ownership/location changed' }
        Assert-Same $endpoint.Contains('condition') $false 'Private endpoint unexpectedly conditional'
        Assert-Same $endpoint.Contains('existing') $false 'Private endpoint must be new'
        Assert-Same $endpoint.properties.subnet.id "[parameters('subnetResourceId')]" 'Endpoint subnet changed'
        Assert-Same $endpoint.properties.privateLinkServiceConnections "[coalesce(parameters('privateLinkServiceConnections'), createArray())]" 'Endpoint target changed'
        Assert-Same $endpoint.properties.manualPrivateLinkServiceConnections "[coalesce(parameters('manualPrivateLinkServiceConnections'), createArray())]" 'Manual PE target introduced'
        $zoneDeployment = $avm.resources.privateEndpoint_privateDnsZoneGroup
        Assert-Same $zoneDeployment.condition "[not(empty(parameters('privateDnsZoneGroup')))]" 'DNS group guard changed'
        Assert-Same $zoneDeployment.properties.parameters.privateEndpointName.value "[parameters('name')]" 'DNS group parent changed'
        Assert-Same $zoneDeployment.properties.parameters.privateDnsZoneConfigs.value "[parameters('privateDnsZoneGroup').privateDnsZoneGroupConfigs]" 'DNS configs changed'
        Assert-Same $avm.variables.enableReferencedModulesTelemetry $false 'Nested telemetry enabled'
        Assert-Same $zoneDeployment.properties.parameters.enableTelemetry.value "[variables('enableReferencedModulesTelemetry')]" 'DNS telemetry routing changed'
        $zoneTemplate = $zoneDeployment.properties.template
        Assert-Keys $zoneTemplate.resources @('privateEndpoint', 'avmTelemetry', 'privateDnsZoneGroup') 'DNS group resource envelope changed'
        Assert-Same $zoneTemplate.resources.privateEndpoint.existing $true 'DNS group must not rewrite PE parent'
        Assert-Same $zoneTemplate.resources.privateEndpoint.name "[parameters('privateEndpointName')]" 'DNS group existing parent changed'
        Assert-Same $zoneTemplate.resources.avmTelemetry.condition "[parameters('enableTelemetry')]" 'DNS telemetry guard changed'
        $zoneGroup = $zoneTemplate.resources.privateDnsZoneGroup
        Assert-Same $zoneGroup.type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' 'DNS zone parent or link write introduced'
        Assert-Same @($zoneGroup.properties.copy).Count 1 'DNS association loop changed'
        Assert-Same $zoneGroup.properties.copy[0].count "[length(parameters('privateDnsZoneConfigs'))]" 'DNS association count changed'
        Assert-Same $zoneGroup.properties.copy[0].input.properties.privateDnsZoneId "[parameters('privateDnsZoneConfigs')[copyIndex('privateDnsZoneConfigs')].privateDnsZoneResourceId]" 'DNS association target changed'
    }
    function Assert-ExpansionStandard($Template) {
        Assert-Same $Template.'$schema' 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#' 'Entrypoint must use subscription scope'
        Assert-Keys $Template.parameters @('labId', 'ownershipId', 'location', 'projectSelector', 'projectPrincipalId') 'Entrypoint accepts unsafe or unexpected input'
        foreach ($name in $Template.parameters.Keys) { Assert-Same $Template.parameters[$name].type 'string' 'Unexpected input type' }
        Assert-Same $Template.parameters.labId.minLength 6 'Lab ID minimum changed'
        Assert-Same $Template.parameters.labId.maxLength 12 'Lab ID maximum changed'
        Assert-Same $Template.parameters.location.allowedValues @('swedencentral') 'Region widened'
        Assert-Same $Template.parameters.location.defaultValue 'swedencentral' 'Default region changed'
        Assert-Same $Template.parameters.projectSelector.allowedValues @('a-test', 'b-dev', 'b-test') 'Selector must exclude retained A-dev'
        foreach ($name in @('labId', 'ownershipId', 'projectPrincipalId', 'projectSelector')) { Assert-Same $Template.parameters[$name].Contains('defaultValue') $false 'Ownership/project/identity input must be explicit' }
        foreach ($name in @('ownershipId', 'projectPrincipalId')) {
            Assert-Same $Template.parameters[$name].minLength 36 'D-format GUID contract missing'
            Assert-Same $Template.parameters[$name].maxLength 36 'D-format GUID contract missing'
        }
        $expectedVariables = [ordered]@{
            stem = "[format('fgl-{0}', parameters('labId'))]"
            uniqueSuffix = "[uniqueString(subscription().id, parameters('labId'))]"
            selection = "[createObject('a-test', createObject('caseId', 'a', 'projectName', 'case-a-test', 'code', 'at'), 'b-dev', createObject('caseId', 'b', 'projectName', 'case-b-dev', 'code', 'bd'), 'b-test', createObject('caseId', 'b', 'projectName', 'case-b-test', 'code', 'bt'))[parameters('projectSelector')]]"
            caseGroupName = "[format('rg-{0}-case-{1}', variables('stem'), variables('selection').caseId)]"
            integrationGroupName = "[format('rg-{0}-integration', variables('stem'))]"
            accountName = "[format('aif-{0}-{1}-{2}', variables('stem'), variables('selection').caseId, variables('uniqueSuffix'))]"
            projectName = "[variables('selection').projectName]"
            accountId = "[resourceId(subscription().subscriptionId, variables('caseGroupName'), 'Microsoft.CognitiveServices/accounts', variables('accountName'))]"
            projectId = "[resourceId(subscription().subscriptionId, variables('caseGroupName'), 'Microsoft.CognitiveServices/accounts/projects', variables('accountName'), variables('projectName'))]"
            storageName = "[format('stfgx{0}{1}', variables('selection').code, variables('uniqueSuffix'))]"
            searchName = "[format('srch-{0}-exp-{1}-{2}', variables('stem'), parameters('projectSelector'), variables('uniqueSuffix'))]"
            cosmosName = "[format('cosmos-{0}-exp-{1}-{2}', variables('stem'), variables('selection').code, variables('uniqueSuffix'))]"
            storageEndpoint = "[format('https://{0}.blob.{1}/', variables('storageName'), environment().suffixes.storage)]"
            searchEndpoint = "[format('https://{0}.search.windows.net', variables('searchName'))]"
            cosmosEndpoint = "[format('https://{0}.documents.azure.com:443/', variables('cosmosName'))]"
            vnetId = "[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/virtualNetworks', format('vnet-{0}', variables('stem')))]"
            subnetId = "[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/virtualNetworks/subnets', format('vnet-{0}', variables('stem')), format('snet-case-{0}-pe', variables('selection').caseId))]"
            endpointStem = "[format('pe-{0}-exp-{1}', variables('stem'), parameters('projectSelector'))]"
        }
        foreach ($name in $expectedVariables.Keys) { Assert-Same $Template.variables[$name] $expectedVariables[$name] "Derived identity/scope changed: $name" }
        Assert-Keys $Template.variables.tags @('fgl-lab', 'fgl-owner', 'purpose') 'Ownership tags changed'
        Assert-Same $Template.variables.tags.'fgl-lab' "[parameters('labId')]" 'Lab ownership lost'
        Assert-Same $Template.variables.tags.'fgl-owner' "[parameters('ownershipId')]" 'Owner binding lost'
        Assert-Same $Template.variables.tags.purpose 'synthetic-governance-lab' 'Lab purpose changed'
        Assert-Keys $Template.variables.dnsZoneIds @('blob', 'search', 'cosmos') 'Unexpected DNS zone input'
        $zoneNames = @{ blob = "format('privatelink.blob.{0}', environment().suffixes.storage)"; search = "'privatelink.search.windows.net'"; cosmos = "'privatelink.documents.azure.com'" }
        foreach ($service in $zoneNames.Keys) { Assert-Same $Template.variables.dnsZoneIds[$service] "[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/privateDnsZones', $($zoneNames[$service]))]" 'DNS zone must be the existing integration-group zone' }
        Assert-Same @(Get-Resources $Template).Count 1 'Only one selected-project deployment allowed; empty graph rejected'
        $deployment = Get-One $Template 'Microsoft.Resources/deployments'
        Assert-Same $deployment.name "[format('{0}-exp-standard-{1}', variables('stem'), parameters('projectSelector'))]" 'Deployment name must be unique per selected project'
        Assert-Same $deployment.resourceGroup "[variables('caseGroupName')]" 'Deployment group redirected'
        Assert-Same $deployment.subscriptionId '[subscription().subscriptionId]' 'Deployment subscription redirected'
        foreach ($field in @('scope', 'condition', 'copy')) { Assert-Same $deployment.Contains($field) $false 'Root must deploy exactly one fixed-scope dependencies module' }
        Assert-Same $deployment.properties.mode 'Incremental' 'Root deployment must be additive'
        Assert-Same $deployment.properties.expressionEvaluationOptions.scope 'inner' 'Root module scope must be inner'
        Assert-Same $deployment.properties.Contains('templateLink') $false 'Root linked template is not allowed'
        $dependencies = $deployment.properties.template
        $argumentNames = @('location', 'tags', 'accountName', 'projectName', 'projectPrincipalId', 'storageName', 'searchName', 'cosmosName', 'endpointStem', 'subnetId', 'dnsZoneIds')
        Assert-Keys $deployment.properties.parameters $argumentNames 'Unexpected dependency arguments'
        Assert-Keys $dependencies.parameters $argumentNames 'Unexpected dependency inputs'
        foreach ($name in $argumentNames) {
            $expected = if ($name -in @('location', 'projectPrincipalId')) { "[parameters('$name')]" } else { "[variables('$name')]" }
            Assert-Same $deployment.properties.parameters[$name].value $expected "Dependency argument redirected: $name"
            Assert-Same $dependencies.parameters[$name].Contains('defaultValue') $false 'Dependency input default masks missing routing'
        }
        Assert-Same $dependencies.parameters.projectName.allowedValues @('case-a-test', 'case-b-dev', 'case-b-test') 'Internal module accepts A-dev'
        Assert-Same $dependencies.parameters.location.allowedValues @('swedencentral') 'Internal region constraint changed'
        foreach ($limit in @('minLength', 'maxLength')) { Assert-Same $dependencies.parameters.projectPrincipalId[$limit] 36 'Internal project identity GUID contract changed' }
        Assert-Same @(Get-Resources $dependencies).Count 10 'Dependency envelope changed'
        Assert-ChildBoundaries $dependencies
        foreach ($resource in @(Get-Resources $dependencies)) {
            foreach ($field in @('condition', 'existing', 'resources')) { Assert-Same $resource.Contains($field) $false 'Dependency omitted or hidden child resource introduced' }
        }
        $serviceTypes = [ordered]@{ storage = 'Microsoft.Storage/storageAccounts'; search = 'Microsoft.Search/searchServices'; cosmos = 'Microsoft.DocumentDB/databaseAccounts' }
        $apis = @{ storage = '2023-05-01'; search = '2025-05-01'; cosmos = '2024-11-15' }
        $services = @{}
        foreach ($service in $serviceTypes.Keys) {
            $resource = Get-One $dependencies $serviceTypes[$service]
            $services[$service] = $resource
            Assert-Same $resource.apiVersion $apis[$service] 'Dependency API changed'
            Assert-Same $resource.name "[parameters('${service}Name')]" 'Service name redirected'
            Assert-Same $resource.location "[parameters('location')]" 'Service region redirected'
            Assert-Same $resource.tags "[parameters('tags')]" 'Service ownership lost'
            Assert-Same $resource.Contains('copy') $false 'Extra service instances introduced'
            Assert-Same $resource.properties.publicNetworkAccess $(if ($service -eq 'search') { 'disabled' } else { 'Disabled' }) 'Public network enabled'
            Assert-Same $Template.variables["${service}Id"] "[resourceId(subscription().subscriptionId, variables('caseGroupName'), '$($serviceTypes[$service])', variables('${service}Name'))]" 'Unscoped or redirected service ID'
        }
        $storage = $services.storage
        Assert-Same $storage.kind 'StorageV2' 'Storage kind changed'
        Assert-Same $storage.sku.name 'Standard_LRS' 'Storage SKU changed'
        Assert-Keys $storage.properties @('minimumTlsVersion', 'supportsHttpsTrafficOnly', 'allowBlobPublicAccess', 'allowSharedKeyAccess', 'defaultToOAuthAuthentication', 'allowCrossTenantReplication', 'publicNetworkAccess', 'networkAcls') 'Unexpected storage properties'
        foreach ($property in @('allowSharedKeyAccess', 'allowBlobPublicAccess', 'allowCrossTenantReplication')) { Assert-Same $storage.properties[$property] $false 'Storage key/public/cross-tenant access enabled' }
        foreach ($property in @('supportsHttpsTrafficOnly', 'defaultToOAuthAuthentication')) { Assert-Same $storage.properties[$property] $true 'Storage HTTPS/OAuth missing' }
        Assert-Same $storage.properties.minimumTlsVersion 'TLS1_2' 'Storage TLS downgraded'
        Assert-Keys $storage.properties.networkAcls @('bypass', 'defaultAction', 'ipRules', 'virtualNetworkRules') 'Unexpected storage firewall input'
        Assert-Same $storage.properties.networkAcls.bypass 'None' 'Storage bypass enabled'
        Assert-Same $storage.properties.networkAcls.defaultAction 'Deny' 'Storage firewall opened'
        Assert-Same $storage.properties.networkAcls.ipRules @() 'Storage IP exception'
        Assert-Same $storage.properties.networkAcls.virtualNetworkRules @() 'Storage service-endpoint exception'
        $search = $services.search
        Assert-Same $search.sku.name 'basic' 'Search SKU changed'
        Assert-Same $search.identity.type 'SystemAssigned' 'Search identity missing'
        Assert-Keys $search.properties @('disableLocalAuth', 'publicNetworkAccess', 'partitionCount', 'replicaCount', 'hostingMode', 'semanticSearch', 'networkRuleSet') 'Unexpected Search properties or key fallback'
        Assert-Same $search.properties.disableLocalAuth $true 'Search local auth enabled'
        Assert-Same $search.properties.partitionCount 1 'Search partition count changed'
        Assert-Same $search.properties.replicaCount 1 'Search replica count changed'
        Assert-Same $search.properties.hostingMode 'Default' 'Search hosting mode changed'
        Assert-Same $search.properties.semanticSearch 'disabled' 'Search semantic tier changed'
        Assert-Keys $search.properties.networkRuleSet @('bypass', 'ipRules') 'Unexpected Search network input'
        Assert-Same $search.properties.networkRuleSet.bypass 'None' 'Search bypass enabled'
        Assert-Same $search.properties.networkRuleSet.ipRules @() 'Search IP exception'
        $cosmos = $services.cosmos
        Assert-Same $cosmos.kind 'GlobalDocumentDB' 'Cosmos must use NoSQL'
        Assert-Keys $cosmos.properties @('databaseAccountOfferType', 'capacity', 'disableLocalAuth', 'publicNetworkAccess', 'networkAclBypass', 'ipRules', 'virtualNetworkRules', 'enableFreeTier', 'enableAutomaticFailover', 'enableMultipleWriteLocations', 'consistencyPolicy', 'locations') 'Unexpected Cosmos properties or serverless capability'
        Assert-Same $cosmos.properties.databaseAccountOfferType 'Standard' 'Cosmos offer changed'
        Assert-Keys $cosmos.properties.capacity @('totalThroughputLimit') 'Unexpected Cosmos capacity properties'
        Assert-Same $cosmos.properties.capacity.totalThroughputLimit 5000 'Cosmos provisioned throughput limit changed'
        Assert-Same $cosmos.properties.disableLocalAuth $true 'Cosmos local auth enabled'
        Assert-Same $cosmos.properties.networkAclBypass 'None' 'Cosmos bypass enabled'
        foreach ($property in @('ipRules', 'virtualNetworkRules')) { Assert-Same $cosmos.properties[$property] @() 'Cosmos network exception' }
        foreach ($property in @('enableFreeTier', 'enableAutomaticFailover', 'enableMultipleWriteLocations')) { Assert-Same $cosmos.properties[$property] $false 'Cosmos single-region configuration changed' }
        Assert-Same $cosmos.properties.consistencyPolicy.defaultConsistencyLevel 'Session' 'Cosmos consistency changed'
        Assert-Same @($cosmos.properties.locations).Count 1 'Cosmos must be single-region'
        Assert-Keys $cosmos.properties.locations[0] @('locationName', 'failoverPriority', 'isZoneRedundant') 'Unexpected Cosmos region input'
        Assert-Same $cosmos.properties.locations[0].locationName "[parameters('location')]" 'Cosmos region mismatch'
        Assert-Same $cosmos.properties.locations[0].failoverPriority 0 'Cosmos primary priority changed'
        Assert-Same $cosmos.properties.locations[0].isZoneRedundant $false 'Cosmos zone setting changed'
        $connections = @(Get-Resources $dependencies | Where-Object type -CEQ 'Microsoft.CognitiveServices/accounts/projects/connections')
        Assert-Same $connections.Count 3 'Exactly three project connections required'
        $categories = @{ storage = 'AzureStorageAccount'; search = 'CognitiveSearch'; cosmos = 'CosmosDb' }
        $targets = @{ storage = "[format('https://{0}.blob.{1}/', parameters('storageName'), environment().suffixes.storage)]"; search = "[format('https://{0}.search.windows.net', parameters('searchName'))]"; cosmos = "[format('https://{0}.documents.azure.com:443/', parameters('cosmosName'))]" }
        foreach ($service in $serviceTypes.Keys) {
            $matchingConnections = @($connections | Where-Object { $_.properties.category -ceq $categories[$service] })
            Assert-Same $matchingConnections.Count 1 'Connection category mismatch'
            $connection = $matchingConnections[0]
            Assert-Same $connection.apiVersion '2026-05-01' 'Connection API changed'
            Assert-Same $connection.name "[format('{0}/{1}/{2}', parameters('accountName'), parameters('projectName'), parameters('${service}Name'))]" 'Connection redirected outside selected project'
            Assert-Same $connection.Contains('copy') $false 'Extra connections introduced'
            Assert-Keys $connection.properties @('category', 'target', 'authType', 'isSharedToAll', 'metadata') 'Unexpected connection credentials/properties'
            Assert-Same $connection.properties.authType 'AAD' 'Connection local auth enabled'
            Assert-Same $connection.properties.isSharedToAll $false 'Connection shared beyond project'
            Assert-Same $connection.properties.target $targets[$service] 'Connection target redirected'
            Assert-Keys $connection.properties.metadata @('ApiType', 'ResourceId', 'location') 'Unexpected connection metadata'
            Assert-Same $connection.properties.metadata.ApiType 'Azure' 'Connection API type changed'
            Assert-Same $connection.properties.metadata.ResourceId "[resourceId('$($serviceTypes[$service])', parameters('${service}Name'))]" 'Connection service ID redirected'
            Assert-Same $connection.properties.metadata.location "[parameters('location')]" 'Connection region changed'
            Assert-Same $connection.dependsOn @("[resourceId('$($serviceTypes[$service])', parameters('${service}Name'))]") 'Connection must follow its new service'
        }
        $roleIds = @{ storage = '17d1049b-9a84-46fb-8f53-869881c3d3ab'; searchService = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'; searchData = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'; cosmos = '230815da-be43-4aae-9cb4-875f7bd000aa' }
        $roles = @(Get-Resources $dependencies | Where-Object type -CEQ 'Microsoft.Authorization/roleAssignments')
        Assert-Same $roles.Count 3 'Exactly three role declarations (four instances) required'
        Assert-Same $dependencies.variables.searchRoleIds @($roleIds.searchService, $roleIds.searchData) 'Unexpected Search role'
        foreach ($service in $serviceTypes.Keys) {
            $scope = "[resourceId('$($serviceTypes[$service])', parameters('${service}Name'))]"
            $matchingRoles = @($roles | Where-Object scope -CEQ $scope)
            Assert-Same $matchingRoles.Count 1 'Provisioning role scope changed'
            $role = $matchingRoles[0]
            Assert-Same $role.apiVersion '2022-04-01' 'Role API changed'
            Assert-Keys $role.properties @('principalId', 'principalType', 'roleDefinitionId') 'Unexpected role properties'
            Assert-Same $role.properties.principalId "[parameters('projectPrincipalId')]" 'Role must target only selected project MI'
            Assert-Same $role.properties.principalType 'ServicePrincipal' 'Role principal type changed'
            $definition = if ($service -eq 'search') { "variables('searchRoleIds')[copyIndex()]" } else { "'$($roleIds[$service])'" }
            Assert-Same $role.properties.roleDefinitionId "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', $definition)]" 'Unexpected provisioning role'
            Assert-Same $role.name "[guid(resourceId('$($serviceTypes[$service])', parameters('${service}Name')), parameters('projectPrincipalId'), $definition)]" 'Role assignment name changed'
            Assert-Same $role.dependsOn @($scope) 'Role must depend on its new service'
            if ($service -eq 'search') { Assert-Same $role.copy.count "[length(variables('searchRoleIds'))]" 'Search role loop changed' } else { Assert-Same $role.Contains('copy') $false 'Extra role instances introduced' }
        }
        $endpointDefinitions = $dependencies.variables.endpointDefinitions
        Assert-Same @($endpointDefinitions).Count 3 'Exactly three PE definitions required'
        $endpointServices = @('blob', 'search', 'cosmos')
        $endpointGroups = @('blob', 'searchService', 'Sql')
        $targetServices = @('storage', 'search', 'cosmos')
        foreach ($index in 0..2) {
            $service = $targetServices[$index]
            $definition = $endpointDefinitions[$index]
            Assert-Keys $definition @('service', 'targetId', 'groupId', 'zoneId') 'Unexpected endpoint definition'
            Assert-Same $definition.service $endpointServices[$index] 'PE name service changed'
            Assert-Same $definition.groupId $endpointGroups[$index] 'PE service group changed'
            Assert-Same $definition.targetId "[resourceId('$($serviceTypes[$service])', parameters('${service}Name'))]" 'PE service target changed'
            Assert-Same $definition.zoneId "[parameters('dnsZoneIds').$($endpointServices[$index])]" 'PE zone target changed'
        }
        $endpoints = Get-One $dependencies 'Microsoft.Resources/deployments'
        Assert-Same $endpoints.name "[format('{0}-{1}-endpoint', parameters('endpointStem'), variables('endpointDefinitions')[copyIndex()].service)]" 'PE deployment naming collides with another project'
        Assert-Same $endpoints.copy.count "[length(variables('endpointDefinitions'))]" 'PE loop count changed'
        $arguments = $endpoints.properties.parameters
        Assert-Keys $arguments @('name', 'location', 'tags', 'targetId', 'groupId', 'subnetId', 'zoneIds') 'Unexpected PE helper input'
        Assert-Same $arguments.name.value "[format('{0}-{1}', parameters('endpointStem'), variables('endpointDefinitions')[copyIndex()].service)]" 'PE naming changed'
        foreach ($name in @('location', 'tags', 'subnetId')) { Assert-Same $arguments[$name].value "[parameters('$name')]" 'PE ownership/subnet/region routing changed' }
        Assert-Same $arguments.targetId.value "[variables('endpointDefinitions')[copyIndex()].targetId]" 'PE target routing changed'
        Assert-Same $arguments.groupId.value "[variables('endpointDefinitions')[copyIndex()].groupId]" 'PE group routing changed'
        Assert-Same $arguments.zoneIds.value @("[variables('endpointDefinitions')[copyIndex()].zoneId]") 'PE DNS routing changed'
        Assert-EndpointHelper $endpoints.properties.template
        Assert-Keys $Template.outputs @('standard') 'Unexpected output contract'
        $output = $Template.outputs.standard.value
        Assert-Keys $output @('stage', 'completeLab', 'labId', 'ownershipId', 'location', 'projectSelector', 'resourceGroupName', 'resourceGroupId', 'integrationResourceGroupName', 'accountId', 'projectId', 'projectPrincipalId', 'storage', 'search', 'cosmos', 'connections', 'vnetId', 'subnetId', 'privateEndpointIds', 'dnsZoneIds', 'roleAssignmentIds') 'Stable coordinator output contract changed'
        Assert-Same $output.stage 'dependencies' 'Incorrect stage output'
        Assert-Same $output.completeLab $false 'Dependencies must not claim a complete lab'
        foreach ($name in @('labId', 'ownershipId', 'location', 'projectSelector', 'projectPrincipalId')) { Assert-Same $output[$name] "[parameters('$name')]" 'Output input binding changed' }
        foreach ($name in @('accountId', 'projectId', 'vnetId', 'subnetId', 'privateEndpointIds', 'dnsZoneIds', 'roleAssignmentIds')) { Assert-Same $output[$name] "[variables('$name')]" 'Output resource binding changed' }
        Assert-Same $output.resourceGroupName "[variables('caseGroupName')]" 'Output group changed'
        Assert-Same $output.resourceGroupId "[subscriptionResourceId('Microsoft.Resources/resourceGroups', variables('caseGroupName'))]" 'Output group ID changed'
        Assert-Same $output.integrationResourceGroupName "[variables('integrationGroupName')]" 'Output integration group changed'
        Assert-Keys $output.connections @('storage', 'search', 'cosmos') 'Output connections changed'
        foreach ($service in $serviceTypes.Keys) {
            Assert-Keys $output[$service] @('name', 'id', 'endpoint') 'Output service shape changed'
            foreach ($field in @('name', 'id', 'endpoint')) { Assert-Same $output[$service][$field] "[variables('$service$((Get-Culture).TextInfo.ToTitleCase($field))')]" 'Output service binding changed' }
            Assert-Keys $output.connections[$service] @('name', 'id') 'Output connection shape changed'
            Assert-Same $output.connections[$service].name "[variables('${service}Name')]" 'Output connection name changed'
            Assert-Same $output.connections[$service].id "[format('{0}/connections/{1}', variables('projectId'), variables('${service}Name'))]" 'Output connection ID changed'
        }
        Assert-Same @($Template.variables.copy).Count 2 'Unexpected output ID loops'
        Assert-Same $Template.variables.copy[0].name 'privateEndpointIds' 'PE output loop changed'
        Assert-Same $Template.variables.copy[0].count "[length(createArray('blob', 'search', 'cosmos'))]" 'PE output count changed'
        Assert-Same $Template.variables.copy[0].input "[resourceId(subscription().subscriptionId, variables('caseGroupName'), 'Microsoft.Network/privateEndpoints', format('{0}-{1}', variables('endpointStem'), createArray('blob', 'search', 'cosmos')[copyIndex('privateEndpointIds')]))]" 'PE output ID scope changed'
        Assert-Same @($Template.variables.provisioningRoles).Count 4 'Role output count changed'
        $outputRoleServices = @('storage', 'search', 'search', 'cosmos')
        $outputRoleIds = @($roleIds.storage, $roleIds.searchService, $roleIds.searchData, $roleIds.cosmos)
        foreach ($index in 0..3) {
            Assert-Keys $Template.variables.provisioningRoles[$index] @('resourceId', 'roleId') 'Role output definition changed'
            Assert-Same $Template.variables.provisioningRoles[$index].resourceId "[variables('$($outputRoleServices[$index])Id')]" 'Role output scope changed'
            Assert-Same $Template.variables.provisioningRoles[$index].roleId $outputRoleIds[$index] 'Role output permission changed'
        }
        Assert-Same $Template.variables.copy[1].name 'roleAssignmentIds' 'Role output loop changed'
        Assert-Same $Template.variables.copy[1].count "[length(variables('provisioningRoles'))]" 'Role output loop count changed'
        Assert-Same $Template.variables.copy[1].input "[extensionResourceId(variables('provisioningRoles')[copyIndex('roleAssignmentIds')].resourceId, 'Microsoft.Authorization/roleAssignments', guid(variables('provisioningRoles')[copyIndex('roleAssignmentIds')].resourceId, parameters('projectPrincipalId'), variables('provisioningRoles')[copyIndex('roleAssignmentIds')].roleId))]" 'Role output ID binding changed'
        $serialized = $Template | ConvertTo-Json -Depth 100 -Compress
        Assert-Same ($serialized -match '(?i)\blist(Keys|AccountSas|ServiceSas|ConnectionStrings)\(') $false 'Secret/key retrieval introduced'
        Assert-Same (($output | ConvertTo-Json -Depth 100 -Compress) -match '(?i)\breference\(') $false 'Outputs must not claim runtime evidence'
    }
    function Get-NameFormat([string]$Expression) {
        if ($Expression -notmatch "^\[format\('([^']+)',") { throw 'Expected an already structurally validated naming expression' }
        return $Matches[1]
    }
    function Assert-NameMatrix($Template) {
        $codes = @{ 'a-test' = 'at'; 'b-dev' = 'bd'; 'b-test' = 'bt' }
        foreach ($lab in @('lab123', 'lab123456789')) {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($selector in $Template.parameters.projectSelector.allowedValues) {
                $stem = (Get-NameFormat $Template.variables.stem) -f $lab
                $suffix = 'a1b2c3d4e5f6g'
                $storageName = (Get-NameFormat $Template.variables.storageName) -f $codes[$selector], $suffix
                $searchName = (Get-NameFormat $Template.variables.searchName) -f $stem, $selector, $suffix
                $cosmosName = (Get-NameFormat $Template.variables.cosmosName) -f $stem, $codes[$selector], $suffix
                Assert-Same ($storageName -cmatch '^stfgx[a-z0-9]{15}$') $true 'Storage naming limit or retained-name collision'
                Assert-Same ($searchName -cmatch '^[a-z0-9][a-z0-9-]{0,58}[a-z0-9]$') $true 'Search naming limit'
                Assert-Same ($cosmosName -cmatch '^[a-z0-9][a-z0-9-]{1,42}[a-z0-9]$') $true 'Cosmos naming limit'
                foreach ($name in @($storageName, $searchName, $cosmosName)) { Assert-Same $names.Add($name) $true 'Cross-project service name collision' }
                Assert-Same ($searchName -ceq "srch-fgl-$lab-standard") $false 'Search reuses retained A-dev service'
                Assert-Same ($cosmosName -ceq "cosmos-fgl-$lab-standard") $false 'Cosmos reuses retained A-dev service'
                $endpointStem = (Get-NameFormat $Template.variables.endpointStem) -f $stem, $selector
                foreach ($service in @('blob', 'search', 'cosmos')) {
                    $endpointName = "$endpointStem-$service"
                    Assert-Same $names.Add($endpointName) $true 'Cross-project PE collision'
                    Assert-Same ($endpointName -ceq "pe-$stem-standard-$service") $false 'PE reuses retained A-dev name'
                    Assert-Same $names.Add("$endpointName-endpoint") $true 'Cross-project PE module collision'
                    Assert-Same ($endpointName.Length -le 64) $true 'PE name exceeds its limit'
                }
                $deploymentName = (Get-NameFormat (Get-One $Template 'Microsoft.Resources/deployments').name) -f $stem, $selector
                Assert-Same $names.Add($deploymentName) $true 'Cross-project root deployment collision'
            }
            Assert-Same $names.Count 30 'Naming matrix omitted a project or resource'
        }
    }

    $compiler = (Get-Command -Name $BicepExecutable -CommandType Application -ErrorAction Stop).Source
    $source = Join-Path $PSScriptRoot '../infra/expansion-standard.bicep'
    $compileTimer = [Diagnostics.Stopwatch]::StartNew()
    $compiled = & $compiler build $source --no-restore --stdout
    if ($LASTEXITCODE -ne 0) { throw "Offline Bicep compilation failed (exit $LASTEXITCODE); required AVM packages must already be cached. No restore was attempted." }
    $document = ($compiled -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -Depth 100
    $compileTimer.Stop()
    Assert-ExpansionStandard $document
    Assert-NameMatrix $document
    $baselineAssertions = $statistics.Assertions
    $baseline = $document | ConvertTo-Json -Depth 100 -Compress
    $mutations = @(
        @{ Name = 'empty-root'; Change = { param($template) $template.resources = @() } },
        @{ Name = 'extra-rg-input'; Change = { param($template) $template.parameters.resourceGroupName = @{ type = 'string' } } },
        @{ Name = 'A-dev-selector'; Change = { param($template) $template.parameters.projectSelector.allowedValues += 'a-dev' } },
        @{ Name = 'wrong-project'; Change = { param($template) $template.variables.projectName = 'case-a-dev' } },
        @{ Name = 'wrong-account-hash'; Change = { param($template) $template.variables.uniqueSuffix = "[uniqueString(subscription().subscriptionId, parameters('labId'))]" } },
        @{ Name = 'wrong-subnet'; Change = { param($template) $template.variables.subnetId = "[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/virtualNetworks/subnets', format('vnet-{0}', variables('stem')), 'snet-agent-a')]" } },
        @{ Name = 'unscoped-subnet'; Change = { param($template) $template.variables.subnetId = "[resourceId(variables('integrationGroupName'), 'Microsoft.Network/virtualNetworks/subnets', format('vnet-{0}', variables('stem')), 'snet-case-a-pe')]" } },
        @{ Name = 'unscoped-zone'; Change = { param($template) $template.variables.dnsZoneIds.search = "[resourceId('Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')]" } },
        @{ Name = 'unscoped-service'; Change = { param($template) $template.variables.storageId = "[resourceId('Microsoft.Storage/storageAccounts', variables('storageName'))]" } },
        @{ Name = 'unscoped-project'; Change = { param($template) $template.variables.projectId = '/projects/case-b-dev' } },
        @{ Name = 'wrong-group'; Change = { param($template) (Get-One $template 'Microsoft.Resources/deployments').resourceGroup = 'unowned-group' } },
        @{ Name = 'wrong-subscription'; Change = { param($template) (Get-One $template 'Microsoft.Resources/deployments').subscriptionId = 'other-subscription' } },
        @{ Name = 'destructive-mode'; Change = { param($template) (Get-One $template 'Microsoft.Resources/deployments').properties.mode = 'Complete' } },
        @{ Name = 'wrong-principal-routing'; Change = { param($template) (Get-One $template 'Microsoft.Resources/deployments').properties.parameters.projectPrincipalId.value = 'other-principal' } },
        @{ Name = 'empty-dependencies'; Change = { param($template) (Get-Dependencies $template).resources = @() } },
        @{ Name = 'public-storage'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.Storage/storageAccounts').properties.publicNetworkAccess = 'Enabled' } },
        @{ Name = 'public-search'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.Search/searchServices').properties.publicNetworkAccess = 'enabled' } },
        @{ Name = 'public-cosmos'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.DocumentDB/databaseAccounts').properties.publicNetworkAccess = 'Enabled' } },
        @{ Name = 'storage-key-auth'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.Storage/storageAccounts').properties.allowSharedKeyAccess = $true } },
        @{ Name = 'storage-public-blob'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.Storage/storageAccounts').properties.allowBlobPublicAccess = $true } },
        @{ Name = 'storage-tls'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.Storage/storageAccounts').properties.minimumTlsVersion = 'TLS1_0' } },
        @{ Name = 'storage-network-bypass'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.Storage/storageAccounts').properties.networkAcls.bypass = 'AzureServices' } },
        @{ Name = 'search-key-auth'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.Search/searchServices').properties.disableLocalAuth = $false } },
        @{ Name = 'cosmos-key-auth'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.DocumentDB/databaseAccounts').properties.disableLocalAuth = $false } },
        @{ Name = 'cosmos-serverless'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.DocumentDB/databaseAccounts').properties.capabilities = @(@{ name = 'EnableServerless' }) } },
        @{ Name = 'cosmos-throughput-limit'; Change = { param($template) (Get-One (Get-Dependencies $template) 'Microsoft.DocumentDB/databaseAccounts').properties.capacity.totalThroughputLimit = 10000 } },
        @{ Name = 'bad-role'; Change = { param($template) (Get-Dependencies $template).variables.searchRoleIds[0] = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' } },
        @{ Name = 'premature-blob-data-role'; Change = { param($template) @(Get-Resources (Get-Dependencies $template) | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')[0].properties.roleDefinitionId = "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')]" } },
        @{ Name = 'role-scope-widened'; Change = { param($template) @(Get-Resources (Get-Dependencies $template) | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')[0].scope = '/' } },
        @{ Name = 'developer-role'; Change = { param($template) @(Get-Resources (Get-Dependencies $template) | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')[0].properties.principalId = 'developer-principal' } },
        @{ Name = 'connection-api-key'; Change = { param($template) @(Get-Resources (Get-Dependencies $template) | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/projects/connections')[0].properties.authType = 'ApiKey' } },
        @{ Name = 'connection-shared'; Change = { param($template) @(Get-Resources (Get-Dependencies $template) | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/projects/connections')[0].properties.isSharedToAll = $true } },
        @{ Name = 'connection-A-dev'; Change = { param($template) @(Get-Resources (Get-Dependencies $template) | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/projects/connections')[0].name = "[format('{0}/case-a-dev/{1}', parameters('accountName'), parameters('storageName'))]" } },
        @{ Name = 'connection-wrong-resource'; Change = { param($template) @(Get-Resources (Get-Dependencies $template) | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/projects/connections')[0].properties.metadata.ResourceId = '/external/storage' } },
        @{ Name = 'PE-wrong-zone'; Change = { param($template) (Get-Dependencies $template).variables.endpointDefinitions[0].zoneId = "[parameters('dnsZoneIds').cosmos]" } },
        @{ Name = 'PE-name-collision'; Change = { param($template) $template.variables.endpointStem = "[format('pe-{0}-standard', variables('stem'))]" } },
        @{ Name = 'PE-unscoped-target'; Change = { param($template) (Get-Dependencies $template).variables.endpointDefinitions[0].targetId = 'storage-only' } },
        @{ Name = 'AVM-telemetry'; Change = { param($template) (Get-Avm $template).resources.avmTelemetry.condition = $true } },
        @{ Name = 'AVM-extra-roles'; Change = { param($template) (Get-Avm $template).resources.privateEndpoint_roleAssignments.copy.count = 1 } },
        @{ Name = 'AVM-lock'; Change = { param($template) (Get-Avm $template).resources.privateEndpoint_lock.condition = $true } },
        @{ Name = 'AVM-redirect-subnet'; Change = { param($template) (Get-Avm $template).resources.privateEndpoint.properties.subnet.id = '/external/subnet' } },
        @{ Name = 'DNS-parent-write'; Change = { param($template) (Get-Dependencies $template).resources += @{ type = 'Microsoft.Network/privateDnsZones'; name = 'forbidden' } } },
        @{ Name = 'DNS-link-write'; Change = { param($template) (Get-Dependencies $template).resources += @{ type = 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; name = 'forbidden/link' } } },
        @{ Name = 'VNet-write'; Change = { param($template) (Get-Dependencies $template).resources += @{ type = 'Microsoft.Network/virtualNetworks'; name = 'forbidden' } } },
        @{ Name = 'subnet-write'; Change = { param($template) (Get-Dependencies $template).resources += @{ type = 'Microsoft.Network/virtualNetworks/subnets'; name = 'forbidden/subnet' } } },
        @{ Name = 'host-write'; Change = { param($template) (Get-Dependencies $template).resources += @{ type = 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts'; name = 'forbidden' } } },
        @{ Name = 'account-write'; Change = { param($template) (Get-Dependencies $template).resources += @{ type = 'Microsoft.CognitiveServices/accounts'; name = 'forbidden' } } },
        @{ Name = 'NSG-write'; Change = { param($template) (Get-Dependencies $template).resources += @{ type = 'Microsoft.Network/networkSecurityGroups'; name = 'forbidden' } } },
        @{ Name = 'APIM-write'; Change = { param($template) (Get-Dependencies $template).resources += @{ type = 'Microsoft.ApiManagement/service'; name = 'forbidden' } } },
        @{ Name = 'policy-write'; Change = { param($template) (Get-Dependencies $template).resources += @{ type = 'Microsoft.Authorization/policyAssignments'; name = 'forbidden' } } },
        @{ Name = 'false-completion'; Change = { param($template) $template.outputs.standard.value.completeLab = $true } },
        @{ Name = 'wrong-output-role'; Change = { param($template) $template.variables.provisioningRoles[0].roleId = 'wrong-role' } }
    )
    foreach ($mutation in $mutations) {
        $altered = $baseline | ConvertFrom-Json -AsHashtable -Depth 100
        & $mutation.Change $altered
        $rejected = $false
        try { Assert-ExpansionStandard $altered } catch { $rejected = $true }
        if (-not $rejected) { throw "Negative control was accepted: $($mutation.Name)" }
    }
    Write-Output "PASS: $baselineAssertions baseline assertions; six naming cases; $($mutations.Count) deliberate regressions rejected."
    Write-Output 'Envelope per selector: 3 services + 3 private endpoints + 3 PE DNS zone groups + 3 AAD connections + 4 provisioning roles = 16 resource instances, excluding deployment wrappers. No DNS zone/link, VNet/subnet, Foundry parent, host, runtime-access, policy, NSG or APIM writes.'
    Write-Output ('Offline compile: {0:N3}s; checks: {1:N3}s. Structural validation only, not ARM evaluation or live readiness. GUID syntax and project-MI ownership must be verified by the later coordinator.' -f $compileTimer.Elapsed.TotalSeconds, ($timer.Elapsed.TotalSeconds - $compileTimer.Elapsed.TotalSeconds))
} finally {
    $timer.Stop()
    Write-Output ('elapsed: {0:N3}s' -f $timer.Elapsed.TotalSeconds)
}