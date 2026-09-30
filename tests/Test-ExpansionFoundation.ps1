[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CompiledTemplatePath,
    [string]$BicepExecutable = 'bicep'
)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    $labRoot = Split-Path $PSScriptRoot -Parent
    $template = Get-Content -LiteralPath $CompiledTemplatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100

    function Require([bool]$Condition, [string]$Message) {
        if (-not $Condition) { throw "Foundation boundary: $Message" }
    }
    function Equal($Actual, $Expected, [string]$Path) {
        if ($null -eq $Expected) { Require ($null -eq $Actual) "$Path must be null"; return }
        if ($Expected -is [Collections.IDictionary]) {
            Require ($Actual -is [Collections.IDictionary]) "$Path must be an object"
            $expectedKeys = @($Expected.Keys | Where-Object { $_ -cne '_generator' } | Sort-Object)
            $actualKeys = @($Actual.Keys | Where-Object { $_ -cne '_generator' } | Sort-Object)
            Equal $actualKeys $expectedKeys "$Path keys"
            foreach ($key in $expectedKeys) { Equal $Actual[$key] $Expected[$key] "$Path.$key" }
        } elseif ($Expected -is [array]) {
            Require ($Actual -is [array]) "$Path must be an array"
            Require ($Actual.Count -eq $Expected.Count) "$Path count"
            for ($index = 0; $index -lt $Expected.Count; $index++) { Equal $Actual[$index] $Expected[$index] "$Path[$index]" }
        } else {
            Require ($null -ne $Actual -and $Actual.GetType() -eq $Expected.GetType()) "$Path scalar type"
            Require ($Actual -ceq $Expected) "$Path value"
        }
    }
    function Resources([hashtable]$Document) {
        if ($Document.resources -is [Collections.IDictionary]) { $Document.resources.Values } else { $Document.resources }
    }
    function One([hashtable]$Document, [string]$Name) {
        $matches = @(Resources $Document | Where-Object { $_.name -ceq $Name })
        Require ($matches.Count -eq 1) "exactly one resource named $Name"
        return $matches[0]
    }
    function RootModule([hashtable]$Document, [string]$Suffix) {
        One $Document ("[format('{0}-expansion-" + $Suffix + "', variables('stem'))]")
    }
    function ReferenceTemplate([string]$Name) {
        $source = Join-Path $labRoot "infra\modules\$Name.bicep"
        $text = & $BicepExecutable build $source --no-restore --stdout
        if ($LASTEXITCODE -ne 0) { throw "Offline reference compilation failed: $Name" }
        return ($text -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -Depth 100
    }
    function ParameterValues([hashtable]$Values) {
        $result = @{}
        foreach ($key in $Values.Keys) { $result[$key] = @{ value = $Values[$key] } }
        return $result
    }
    function Envelope([hashtable]$Resource, [string]$Name, [string]$Condition, [hashtable]$Parameters, [string]$Group = '', [array]$Dependencies = @()) {
        $expected = @{
            type = 'Microsoft.Resources/deployments'; apiVersion = '2025-04-01'; name = $Name
            properties = @{ expressionEvaluationOptions = @{ scope = 'inner' }; mode = 'Incremental'; parameters = $Parameters }
        }
        if ($Condition) { $expected.condition = $Condition }
        if ($Group) { $expected.resourceGroup = $Group }
        if ($Dependencies.Count) { $expected.dependsOn = $Dependencies }
        $actual = @{}
        foreach ($key in $Resource.Keys) { $actual[$key] = $Resource[$key] }
        $actual.properties = @{}
        foreach ($key in $Resource.properties.Keys) { if ($key -cne 'template') { $actual.properties[$key] = $Resource.properties[$key] } }
        Equal $actual $expected "deployment $Name"
        Require ($Resource.properties.template -is [Collections.IDictionary]) "inline template $Name"
    }
    function EffectiveValue([hashtable]$Module, [string]$Name) {
        if ($Module.properties.parameters.ContainsKey($Name)) { return ,$Module.properties.parameters[$Name].value }
        $definition = $Module.properties.template.parameters[$Name]
        Require ($null -ne $definition) "AVM parameter $Name exists"
        if ($definition.ContainsKey('defaultValue')) { return ,$definition.defaultValue }
        Require ($definition.nullable -eq $true) "AVM parameter $Name must be supplied or nullable"
        return $null
    }
    function ActiveAvmWrites([hashtable]$Module, [string[]]$ExpectedTypes) {
        $active = [Collections.Generic.List[string]]::new()
        foreach ($resource in (Resources $Module.properties.template)) {
            if ($resource.existing -eq $true) { continue }
            $count = 1
            if ($resource.ContainsKey('copy')) {
                $expression = $resource.copy.count
                Require ($expression -is [string]) 'AVM loop count must remain a checked expression'
                if ($expression -cmatch "^\[length\(coalesce\(parameters\('([^']+)'\), createArray\(\)\)\)\]$") {
                    $value = EffectiveValue $Module $Matches[1]
                } elseif ($expression -ceq "[length(coalesce(variables('formattedRoleAssignments'), createArray()))]") {
                    $value = EffectiveValue $Module 'roleAssignments'
                } else { throw "Unchecked AVM loop: $expression" }
                Require ($null -eq $value -or $value -is [array]) 'AVM loop input must be null or array'
                $count = if ($null -eq $value) { 0 } else { $value.Count }
            }
            if ($count -eq 0) { continue }
            if ($resource.ContainsKey('condition')) {
                $condition = $resource.condition
                Require ($condition -is [string]) 'AVM condition must remain a checked expression'
                switch -CaseSensitive ($condition) {
                    "[parameters('enableTelemetry')]" { Equal (EffectiveValue $Module 'enableTelemetry') $false 'telemetry'; continue }
                    "[and(not(empty(coalesce(parameters('lock'), createObject()))), not(equals(tryGet(parameters('lock'), 'kind'), 'None')))]" { Equal (EffectiveValue $Module 'lock') $null 'lock'; continue }
                    "[not(equals(parameters('enableDefenderForAI'), null()))]" { Equal (EffectiveValue $Module 'enableDefenderForAI') $null 'Defender'; continue }
                    "[not(equals(parameters('secretsExportConfiguration'), null()))]" { Equal (EffectiveValue $Module 'secretsExportConfiguration') $null 'secret export'; continue }
                    "[not(empty(parameters('linkedStorageAccountResourceId')))]" { Equal (EffectiveValue $Module 'linkedStorageAccountResourceId') $null 'linked storage'; continue }
                    "[and(not(empty(filter(coalesce(parameters('gallerySolutions'), createArray()), lambda('item', startsWith(lambdaVariables('item').name, 'SecurityInsights'))))), parameters('onboardWorkspaceToSentinel'))]" { Equal (EffectiveValue $Module 'gallerySolutions') $null 'Sentinel gallery'; continue }
                    "[not(empty(parameters('privateDnsZoneGroup')))]" { Require ($resource.type -ceq 'Microsoft.Resources/deployments') 'DNS child deployment only' }
                    default { throw "Unchecked AVM condition: $condition" }
                }
                if ($condition -cne "[not(empty(parameters('privateDnsZoneGroup')))]") { continue }
            }
            for ($index = 0; $index -lt $count; $index++) { $active.Add($resource.type) }
        }
        Equal @($active.ToArray() | Sort-Object) @($ExpectedTypes | Sort-Object) 'active AVM resource types'
    }

    $referenceMonitor = ReferenceTemplate 'monitoring'
    $referenceEndpoint = ReferenceTemplate 'private-endpoint'
    $referenceCase = ReferenceTemplate 'use-case'
    $referenceProjects = ReferenceTemplate 'expansion-projects'

    function ModuleId([string]$GroupVariable, [string]$Suffix) {
        return "[extensionResourceId(format('/subscriptions/{0}/resourceGroups/{1}', subscription().subscriptionId, variables('$GroupVariable')), 'Microsoft.Resources/deployments', format('{0}-expansion-$Suffix', variables('stem')))]"
    }
    function ModuleOutput([string]$GroupVariable, [string]$Suffix, [string]$OutputName) {
        $identifier = ModuleId $GroupVariable $Suffix
        return "[reference($($identifier.Substring(1, $identifier.Length - 2)), '2025-04-01').outputs.$OutputName.value]"
    }
    function Assert-Parameters([hashtable]$Document, [bool]$Root) {
        $names = if ($Root) { @('labId','location','ownershipId','reviewedFoundationCreation') } else { @('labId','location','mode','ownershipId') }
        Equal @($Document.parameters.Keys | Sort-Object) $names 'parameter surface'
        foreach ($name in @('labId','ownershipId')) {
            Equal $Document.parameters[$name].type 'string' "$name type"
            Require (-not $Document.parameters[$name].ContainsKey('defaultValue')) "$name is mandatory"
        }
        Require ($Document.parameters.labId.minLength -eq 6 -and $Document.parameters.labId.maxLength -eq 12) 'canonical lab ID length 6..12'
        Equal $Document.parameters.location.allowedValues @('swedencentral') 'region allowlist'
        Equal $Document.parameters.location.defaultValue 'swedencentral' 'default region'
        if ($Root) {
            Equal $Document.parameters.reviewedFoundationCreation.type 'bool' 'review flag type'
            Equal $Document.parameters.reviewedFoundationCreation.allowedValues @($true) 'review flag allowlist'
            Require (-not $Document.parameters.reviewedFoundationCreation.ContainsKey('defaultValue')) 'review flag has no default'
            Require ($Document.parameters.reviewedFoundationCreation.metadata.description.Contains('not evidence of authorization')) 'review is not authorization'
        } else {
            Equal $Document.parameters.mode.allowedValues @('account','monitor-links') 'mode allowlist'
            Require (-not $Document.parameters.mode.ContainsKey('defaultValue')) 'mode is mandatory'
        }
        Require (-not $Document.ContainsKey('functions') -and -not $Document.ContainsKey('definitions')) 'no custom ARM functions or type definitions'
    }
    function Assert-Foundation([hashtable]$Document) {
        Equal $Document.'$schema' 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#' 'subscription scope'
        Assert-Parameters $Document $true
        Require ($Document.metadata.description.Contains('stage only') -and $Document.metadata.description.Contains('not a complete')) 'stage-only description'
        $tags = @{ 'fgl-lab'="[parameters('labId')]"; 'fgl-owner'="[parameters('ownershipId')]"; purpose='synthetic-governance-lab' }
        $baseVariables = @{
            stem="[format('fgl-{0}', parameters('labId'))]"
            uniqueSuffix="[uniqueString(subscription().id, parameters('labId'))]"
            tags=$tags
            integrationGroupName="[format('rg-{0}-integration', variables('stem'))]"
            caseBGroupName="[format('rg-{0}-case-b', variables('stem'))]"
        }
        $rootVariables = $baseVariables.Clone()
        $rootVariables.caseAGroupName="[format('rg-{0}-case-a', variables('stem'))]"
        $rootVariables.caseAAccountName="[format('aif-{0}-a-{1}', variables('stem'), variables('uniqueSuffix'))]"
        $rootVariables.zoneNames=@('privatelink.cognitiveservices.azure.com','privatelink.openai.azure.com','privatelink.services.ai.azure.com')
        Equal $Document.variables $rootVariables 'root naming, tags and DNS zones'
        Require (@(Resources $Document).Count -eq 6) 'root contains one RG and five deployments only'
        $review="[parameters('reviewedFoundationCreation')]"
        $groupId="[subscriptionResourceId('Microsoft.Resources/resourceGroups', variables('caseBGroupName'))]"
        Equal (One $Document "[variables('caseBGroupName')]") @{
            condition=$review; type='Microsoft.Resources/resourceGroups'; apiVersion='2025-04-01'
            name="[variables('caseBGroupName')]"; location="[parameters('location')]"; tags="[variables('tags')]"
        } 'only case B RG creation'
        $monitor = RootModule $Document 'monitor-b'
        $case = RootModule $Document 'case-b'
        $projectA = RootModule $Document 'project-a-test'
        $endpoint = RootModule $Document 'case-b-endpoint'
        $links = RootModule $Document 'monitor-links-b'
        $common = @{ labId="[parameters('labId')]"; ownershipId="[parameters('ownershipId')]"; location="[parameters('location')]" }
        $caseValues=$common.Clone(); $caseValues.mode='account'
        $linkValues=$common.Clone(); $linkValues.mode='monitor-links'
        $projectValues=$common.Clone(); $projectValues.accountName="[variables('caseAAccountName')]"; $projectValues.caseId='a'
        Envelope $monitor $monitor.name $review (ParameterValues @{stem="[format('{0}-case-b', variables('stem'))]";location="[parameters('location')]";tags="[variables('tags')]"}) "[variables('caseBGroupName')]" @($groupId)
        Envelope $case $case.name $review (ParameterValues $caseValues) "[variables('caseBGroupName')]" @($groupId,(ModuleId 'caseBGroupName' 'monitor-b'))
        Envelope $projectA $projectA.name $review (ParameterValues $projectValues) "[variables('caseAGroupName')]"
        Envelope $links $links.name $review (ParameterValues $linkValues) "[variables('integrationGroupName')]" @((ModuleId 'caseBGroupName' 'monitor-b'))
        $endpointValues = ParameterValues @{
            name="[format('pe-{0}-case-b', variables('stem'))]"; location="[parameters('location')]"; tags="[variables('tags')]"
            targetId=(ModuleOutput 'caseBGroupName' 'case-b' 'accountId'); groupId='account'
            subnetId="[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/virtualNetworks/subnets', format('vnet-{0}', variables('stem')), 'snet-case-b-pe')]"
        }
        $endpointValues.zoneIds=@{copy=@(@{name='value';count="[length(variables('zoneNames'))]";input="[resourceId(subscription().subscriptionId, variables('integrationGroupName'), 'Microsoft.Network/privateDnsZones', variables('zoneNames')[copyIndex('value')])]"})}
        Envelope $endpoint $endpoint.name $review $endpointValues "[variables('caseBGroupName')]" @((ModuleId 'caseBGroupName' 'case-b'),$groupId)
        Equal $monitor.properties.template $referenceMonitor 'immutable monitoring module including all nested writes'
        Equal $endpoint.properties.template $referenceEndpoint 'immutable endpoint module including all nested writes'
        Equal $projectA.properties.template $referenceProjects 'immutable A-test project module'
        Equal $referenceProjects.variables.environments "[if(equals(parameters('caseId'), 'a'), createArray('test'), createArray('dev', 'test'))]" 'exact A-test and B-dev/test environment contract'
        Require (@(Resources $referenceProjects).Count -eq 1) 'project-only module'
        $projectResource=@(Resources $referenceProjects)[0]
        Equal $projectResource.type 'Microsoft.CognitiveServices/accounts/projects' 'only projects'
        Equal $projectResource.name "[format('{0}/{1}', parameters('accountName'), format('case-{0}-{1}', parameters('caseId'), variables('environments')[copyIndex()]))]" 'project names'
        Equal $projectResource.copy @{name='projects';count="[length(variables('environments'))]"} 'project loop'
        Equal $projectResource.identity @{type='SystemAssigned'} 'project system identity'
        Equal $projectResource.tags "[variables('tags')]" 'project tags'
        Equal $referenceProjects.variables.tags $tags 'project ownership'

        $workspaceModule=One $referenceMonitor 'workspace'
        $insightsModule=One $referenceMonitor 'insights'
        foreach ($module in @($workspaceModule,$insightsModule)) {
            Equal $module.properties.parameters.enableTelemetry.value $false 'monitor telemetry disabled'
            Equal $module.properties.parameters.publicNetworkAccessForIngestion.value 'Disabled' 'private ingestion'
            Equal $module.properties.parameters.publicNetworkAccessForQuery.value 'Disabled' 'private query'
        }
        Equal $workspaceModule.properties.parameters.features.value.disableLocalAuth $true 'workspace local auth disabled'
        Equal $insightsModule.properties.parameters.disableLocalAuth.value $true 'insights local auth disabled'
        ActiveAvmWrites $workspaceModule @('Microsoft.OperationalInsights/workspaces')
        ActiveAvmWrites $insightsModule @('Microsoft.Insights/components')
        $endpointModule=@(Resources $referenceEndpoint)[0]
        ActiveAvmWrites $endpointModule @('Microsoft.Network/privateEndpoints','Microsoft.Resources/deployments')
        $dnsModule=$endpointModule.properties.template.resources.privateEndpoint_privateDnsZoneGroup
        Equal $dnsModule.properties.parameters.privateEndpointName.value "[parameters('name')]" 'DNS group belongs to new endpoint'
        Equal $endpointModule.properties.template.variables.enableReferencedModulesTelemetry $false 'DNS module telemetry disabled'
        $dnsWrites=@(Resources $dnsModule.properties.template | Where-Object { $_.existing -ne $true -and $_.type -ne 'Microsoft.Resources/deployments' })
        Require ($dnsWrites.Count -eq 1) 'one DNS zone group write only'
        Equal $dnsWrites[0].type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' 'DNS zones are referenced, never written'

        $owner=$case.properties.template
        Equal $links.properties.template $owner 'both explicit mode invocations use identical wrapper'
        Assert-Parameters $owner $false
        $ownerVariables=$baseVariables.Clone()
        $ownerVariables.accountName="[format('aif-{0}-b-{1}', variables('stem'), variables('uniqueSuffix'))]"
        $ownerVariables.workspaceId="[resourceId(variables('caseBGroupName'), 'Microsoft.OperationalInsights/workspaces', format('log-{0}-case-b', variables('stem')))]"
        $ownerVariables.insightsId="[resourceId(variables('caseBGroupName'), 'Microsoft.Insights/components', format('appi-{0}-case-b', variables('stem')))]"
        Equal $owner.variables $ownerVariables 'case B exact naming and references'
        Equal @($owner.resources.Keys | Sort-Object) @('account','accountReference','developer','developerRole','devProject','insightsLink','monitorScope','newProjects','workspaceLink') 'wrapper surfaces'
        Equal $owner.resources.developer @{existing=$true;type='Microsoft.ManagedIdentity/userAssignedIdentities';apiVersion='2023-01-31';resourceGroup="[variables('integrationGroupName')]";name="[format('id-{0}-dev-b', variables('stem'))]"} 'existing synthetic B developer only'
        Equal $owner.resources.accountReference @{existing=$true;type='Microsoft.CognitiveServices/accounts';apiVersion='2026-05-01';name="[variables('accountName')]"} 'account reference, not a second PUT'
        Equal $owner.resources.devProject @{existing=$true;type='Microsoft.CognitiveServices/accounts/projects';apiVersion='2026-05-01';name="[format('{0}/{1}', variables('accountName'), 'case-b-dev')]"} 'B-dev role scope reference'
        Equal $owner.resources.monitorScope @{existing=$true;type='microsoft.insights/privateLinkScopes';apiVersion='2021-07-01-preview';name="[format('ampls-{0}', variables('stem'))]"} 'existing exact AMPLS parent'
        $accountCondition="[equals(parameters('mode'), 'account')]"
        $linksCondition="[equals(parameters('mode'), 'monitor-links')]"
        foreach ($entry in @(@{key='workspaceLink';leaf='linked-4';target='workspaceId'},@{key='insightsLink';leaf='linked-5';target='insightsId'})) {
            Equal $owner.resources[$entry.key] @{
                condition=$linksCondition;type='Microsoft.Insights/privateLinkScopes/scopedResources';apiVersion='2021-07-01-preview'
                name="[format('{0}/{1}', format('ampls-{0}', variables('stem')), '$($entry.leaf)')]"
                properties=@{linkedResourceId="[variables('$($entry.target)')]"}
            } 'only new B monitoring child link'
        }
        Equal $owner.resources.developerRole @{
            condition=$accountCondition;type='Microsoft.Authorization/roleAssignments';apiVersion='2022-04-01'
            name="[guid(variables('accountName'), 'b', 'dev-foundry-user')]"
            scope="[resourceId('Microsoft.CognitiveServices/accounts/projects', variables('accountName'), 'case-b-dev')]"
            properties=@{roleDefinitionId="[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')]";principalId="[reference('developer').principalId]";principalType='ServicePrincipal'}
            dependsOn=@('developer','newProjects')
        } 'only synthetic B developer Foundry User at B-dev'
        $accountValues=@{
            name="[variables('accountName')]";location="[parameters('location')]";tags="[variables('tags')]";enableTelemetry=$false
            kind='AIServices';sku='S0';customSubDomainName="[variables('accountName')]";allowProjectManagement=$true
            disableLocalAuth=$true;publicNetworkAccess='Disabled';restrictOutboundNetworkAccess=$false
            managedIdentities=@{systemAssigned=$true}
            networkAcls=@{defaultAction='Deny';bypass='None';ipRules=@();virtualNetworkRules=@()}
            networkInjections=@{scenario='agent';subnetResourceId="[resourceId(variables('integrationGroupName'), 'Microsoft.Network/virtualNetworks/subnets', format('vnet-{0}', variables('stem')), 'snet-agent-b')]";useMicrosoftManagedNetwork=$false}
            deployments=@()
            roleAssignments=@(@{name="[guid(variables('accountName'), 'developer-reader')]";principalId="[reference('developer').principalId]";principalType='ServicePrincipal';roleDefinitionIdOrName='acdd72a7-3385-48ef-bd42-f606fba81ae7'})
            diagnosticSettings=@(@{name='metrics-only';workspaceResourceId="[variables('workspaceId')]";metricCategories=@(@{category='AllMetrics';enabled=$true});logCategoriesAndGroups=@()})
        }
        Envelope $owner.resources.account 'expansion-case-account' $accountCondition (ParameterValues $accountValues) '' @('developer')
        Equal $owner.resources.account.properties.template (One $referenceCase 'case-account').properties.template 'pinned account AVM including every nested write'
        ActiveAvmWrites $owner.resources.account @('Microsoft.CognitiveServices/accounts','Microsoft.Insights/diagnosticSettings','Microsoft.Authorization/roleAssignments')
        $projectBValues=$common.Clone(); $projectBValues.accountName="[variables('accountName')]"; $projectBValues.caseId='b'
        Envelope $owner.resources.newProjects 'expansion-projects-b' $accountCondition (ParameterValues $projectBValues) '' @('account')
        Equal $owner.resources.newProjects.properties.template $referenceProjects 'immutable B-dev/test project module'
        Equal @($owner.outputs.Keys | Sort-Object) @('accountId','monitoringLinkIds','projects','roleAssignmentIds') 'wrapper resource inventory'
        Equal $owner.outputs.accountId @{type='string';value="[if(equals(parameters('mode'), 'account'), reference('account').outputs.resourceId.value, '')]"} 'B account output'
        Equal $owner.outputs.projects @{type='array';value="[if(equals(parameters('mode'), 'account'), reference('newProjects').outputs.projects.value, createArray())]"} 'B project output'
        foreach ($name in @('monitoringLinkIds','roleAssignmentIds')) {
            Equal $owner.outputs[$name].type 'array' "$name inventory type"
            Require ($owner.outputs[$name].value -is [string] -and $owner.outputs[$name].value.StartsWith('[if(equals(')) "$name mode guarded inventory"
        }
        Equal @($Document.outputs.Keys) @('foundation') 'foundation output only'
        Equal $Document.outputs.foundation.type 'object' 'foundation output type'
        $inventory=$Document.outputs.foundation.value
        Equal @($inventory.Keys | Sort-Object) @('accountDiagnosticSettingId','caseBAccountId','completeLab','insightsId','limitations','monitoringLinkIds','privateDnsZoneGroupId','privateEndpointId','projects','resourceGroupId','roleAssignmentIds','stage','workspaceId') 'added resource inventory keys'
        Equal $inventory.stage 'foundation-only' 'stage label'
        Equal $inventory.completeLab $false 'not a complete lab'
        Equal $inventory.resourceGroupId $groupId 'new RG inventory'
        foreach ($entry in @(
            @{key='workspaceId';module='monitor-b';output='workspaceId'},@{key='insightsId';module='monitor-b';output='insightsId'},
            @{key='caseBAccountId';module='case-b';output='accountId'},@{key='privateEndpointId';module='case-b-endpoint';output='resourceId'},
            @{key='roleAssignmentIds';module='case-b';output='roleAssignmentIds'}
        )) { Equal $inventory[$entry.key] (ModuleOutput 'caseBGroupName' $entry.module $entry.output) "$($entry.key) output" }
        Equal $inventory.monitoringLinkIds (ModuleOutput 'integrationGroupName' 'monitor-links-b' 'monitoringLinkIds') 'monitor link output'
        $projectAOutput=ModuleOutput 'caseAGroupName' 'project-a-test' 'projects'
        $projectBOutput=ModuleOutput 'caseBGroupName' 'case-b' 'projects'
        Equal $inventory.projects ("[concat(" + $projectAOutput.Substring(1,$projectAOutput.Length-2) + ', ' + $projectBOutput.Substring(1,$projectBOutput.Length-2) + ')]') 'exact three-project inventory'
        Require ($inventory.limitations -is [array] -and $inventory.limitations.Count -ge 5) 'remaining gates disclosed'
    }

    Assert-Foundation $template
    $serialized=$template | ConvertTo-Json -Depth 100 -Compress
    $mutations = [ordered]@{
        'root account A PUT' = { param($document) $document.resources += @{type='Microsoft.CognitiveServices/accounts';name='accountA'} }
        'retained RG creation' = { param($document) (One $document "[variables('caseBGroupName')]").name="[variables('caseAGroupName')]" }
        'review default' = { param($document) $document.parameters.reviewedFoundationCreation.defaultValue=$true }
        'review accepts false' = { param($document) $document.parameters.reviewedFoundationCreation.allowedValues+= $false }
        'review condition unconditional' = { param($document) (RootModule $document 'case-b').condition=$true }
        'noncanonical suffix' = { param($document) $document.variables.uniqueSuffix="[uniqueString(resourceGroup().id)]" }
        'lab ID range drift' = { param($document) $document.parameters.labId.minLength=3 }
        'region drift' = { param($document) $document.parameters.location.allowedValues+= 'eastus' }
        'ownership drift' = { param($document) $document.variables.tags['fgl-owner']='foreign' }
        'B deployed into retained A group' = { param($document) (RootModule $document 'case-b').resourceGroup="[variables('caseAGroupName')]" }
        'link deployment account mode' = { param($document) (RootModule $document 'monitor-links-b').properties.parameters.mode.value='account' }
        'Complete deployment mode' = { param($document) (RootModule $document 'case-b').properties.mode='Complete' }
        'subscription override' = { param($document) (RootModule $document 'case-b').subscriptionId='foreign' }
        'A dev replay' = { param($document) (RootModule $document 'project-a-test').properties.template.variables.environments=@('dev','test') }
        'A contract changed to B' = { param($document) (RootModule $document 'project-a-test').properties.parameters.caseId.value='b' }
        'B only test' = { param($document) (RootModule $document 'case-b').properties.template.resources.newProjects.properties.parameters.caseId.value='a' }
        'B account renamed A' = { param($document) (RootModule $document 'case-b').properties.template.variables.accountName="[format('aif-{0}-a-{1}', variables('stem'), variables('uniqueSuffix'))]" }
        'AMPLS parent PUT' = { param($document) (RootModule $document 'monitor-links-b').properties.template.resources.monitorScope.Remove('existing') }
        'AMPLS retained link overwrite' = { param($document) (RootModule $document 'monitor-links-b').properties.template.resources.workspaceLink.name='ampls-retained/linked-0' }
        'AMPLS foreign target' = { param($document) (RootModule $document 'monitor-links-b').properties.template.resources.workspaceLink.properties.linkedResourceId='foreign' }
        'existing identity PUT' = { param($document) (RootModule $document 'case-b').properties.template.resources.developer.Remove('existing') }
        'operator role principal' = { param($document) (RootModule $document 'case-b').properties.template.resources.developerRole.properties.principalId='11111111-1111-4111-8111-111111111111' }
        'role broadened to account' = { param($document) (RootModule $document 'case-b').properties.template.resources.developerRole.scope="[resourceId('Microsoft.CognitiveServices/accounts', variables('accountName'))]" }
        'account Owner grant' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.parameters.roleAssignments.value[0].roleDefinitionIdOrName='8e3af657-a8ff-443c-a75c-2fe8c4bcb635' }
        'extra account role' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.parameters.roleAssignments.value+=@{principalId='operator'} }
        'public account' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.parameters.publicNetworkAccess.value='Enabled' }
        'shared agent subnet A' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.parameters.networkInjections.value.subnetResourceId='snet-agent-a' }
        'managed network enabled' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.parameters.networkInjections.value.useMicrosoftManagedNetwork=$true }
        'model deployment added' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.parameters.deployments.value=@(@{name='model'}) }
        'wrong PE subnet' = { param($document) (RootModule $document 'case-b-endpoint').properties.parameters.subnetId.value='snet-case-a-pe' }
        'ambiguous subscription subnet ID' = { param($document) (RootModule $document 'case-b-endpoint').properties.parameters.subnetId.value="[resourceId(variables('integrationGroupName'), 'Microsoft.Network/virtualNetworks/subnets', format('vnet-{0}', variables('stem')), 'snet-case-b-pe')]" }
        'ambiguous subscription DNS ID' = { param($document) (RootModule $document 'case-b-endpoint').properties.parameters.zoneIds.copy[0].input="[resourceId(variables('integrationGroupName'), 'Microsoft.Network/privateDnsZones', variables('zoneNames')[copyIndex('value')])]" }
        'extra DNS zone' = { param($document) $document.variables.zoneNames+='privatelink.azurecr.io' }
        'missing account dependency' = { param($document) (RootModule $document 'case-b').properties.template.resources.newProjects.dependsOn=@() }
        'hidden nested APIM PUT' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.template.resources.injected=@{type='Microsoft.ApiManagement/service';name='retained'} }
        'hidden nested network PUT' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.template.resources.injected=@{type='Microsoft.Network/virtualNetworks';name='retained'} }
        'hidden nested account A PUT' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.template.resources.injected=@{type='Microsoft.CognitiveServices/accounts';name='accountA'} }
        'hidden nested role' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.template.resources.injected=@{type='Microsoft.Authorization/roleAssignments';name='operator'} }
        'hidden NSG write' = { param($document) (RootModule $document 'monitor-b').properties.template.resources.injected=@{type='Microsoft.Network/networkSecurityGroups';name='retained'} }
        'hidden project host' = { param($document) (RootModule $document 'project-a-test').properties.template.resources+=@{type='Microsoft.CognitiveServices/accounts/projects/capabilityHosts';name='host'} }
        'hidden ACR' = { param($document) (RootModule $document 'project-a-test').properties.template.resources+=@{type='Microsoft.ContainerRegistry/registries';name='registry'} }
        'AVM optional model loop forced' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.template.resources.cognitiveService_deployments.copy.count=1 }
        'AVM account public property' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.template.resources.cognitiveService.properties.publicNetworkAccess='Enabled' }
        'AVM role scope injection' = { param($document) (RootModule $document 'case-b').properties.template.resources.account.properties.template.resources.cognitiveService_roleAssignments.scope='retained-account-a' }
        'false complete lab claim' = { param($document) $document.outputs.foundation.value.completeLab=$true }
    }
    foreach ($entry in $mutations.GetEnumerator()) {
        $altered=$serialized | ConvertFrom-Json -AsHashtable -Depth 100
        $null = & $entry.Value $altered
        $rejected=$false
        try { Assert-Foundation $altered } catch { $rejected=$true }
        Require $rejected "negative control was not rejected: $($entry.Key)"
    }
    Write-Output "PASS: additive foundation structural boundaries; $($mutations.Count) deliberately corrupted templates rejected; cached AVM reference comparison; no Azure calls"
    Write-Output 'Scope: one new case-b RG, private B resource and monitoring, A-test/B-dev/B-test, B PE/DNS group, two AMPLS child links, exactly two synthetic B developer roles. Offline structural validation only; not ARM what-if or runtime proof.'
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds, 2))s"
}