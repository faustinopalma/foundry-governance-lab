[CmdletBinding()]
param(
    [string]$StatePath,
    [ValidateSet('Preview','Deploy','Status')][string]$Action = 'Preview',
    [string]$BicepExecutable = 'bicep',
    [switch]$ApproveFoundationCreation,
    [switch]$ApproveValidatorRevision,
    [switch]$DefinitionsOnly
)

function ConvertTo-FoundationCanonical($Value) {
    if ($Value -is [Collections.IDictionary]) {
        return '{' + (@(foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { (ConvertTo-Json -InputObject ([string]$key) -Compress) + ':' + (ConvertTo-FoundationCanonical $Value[$key]) }) -join ',') + '}'
    }
    if ($Value -is [array]) { return '[' + (@(foreach ($item in $Value) { ConvertTo-FoundationCanonical $item }) -join ',') + ']' }
    return ConvertTo-Json -InputObject $Value -Depth 100 -Compress
}

function Get-FoundationHash($Value) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-FoundationCanonical $Value))))
}

function Assert-FoundationOriginal([hashtable]$State) {
    Assert-LabState $State
    foreach ($flag in @('minimalPrompt','privateAccessVerified','deploymentAuthorized')) {
        if ($State[$flag] -isnot [bool] -or -not $State[$flag]) { throw 'Activated private Minimal authorization required' }
    }
    if ($State.phase -isnot [string] -or $State.phase -cne 'activate' -or $State.pendingPhase -or $State.standard -isnot [hashtable] -or $State.standard.pendingStage) { throw 'Original deployment must be activated and idle' }
    if ($State.standard.completedStages -isnot [array] -or ($State.standard.completedStages -join ',') -cne 'dependencies,account,project,access' -or $State.standard.deploymentNames -isnot [hashtable]) { throw 'All four Standard stages required' }
    foreach ($entry in $State.standard.deploymentNames.GetEnumerator()) {
        if ($entry.Key -cnotin @('dependencies','account','project','access') -or $entry.Value -isnot [string] -or $entry.Value -cne "fgl-$($State.labId)-standard-$($entry.Key)") { throw 'Unbound Standard root' }
    }
    foreach ($stage in @('dependencies','project','access')) { if (-not $State.standard.deploymentNames.ContainsKey($stage)) { throw 'Missing Standard root' } }
    foreach ($spec in @(@('cosmosNetwork','standard-cosmos-network'),@('gatewayPolicy','gateway-policy-update'))) {
        $receipt = $State.standard[$spec[0]]
        if ($receipt -isnot [hashtable] -or $receipt.pending -isnot [bool] -or $receipt.pending -or $receipt.verified -isnot [bool] -or -not $receipt.verified -or $receipt.name -isnot [string] -or $receipt.name -cne "fgl-$($State.labId)-$($spec[1])" -or $receipt.group -isnot [string] -or $receipt.group -cne "rg-fgl-$($State.labId)-integration" -or $receipt.review -isnot [hashtable] -or $receipt.evidence -isnot [hashtable]) { throw 'Verified idle narrow change receipts required' }
    }
    $review=$State.standard.gatewayPolicy.review
    if ($review.ContainsKey('source')) {
        $activationId="/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-$($State.labId)-activate"
        if ($review.source -isnot [string] -or $review.source -cne 'activation-policy-reuse' -or $review.activationDeploymentId -isnot [string] -or $review.activationDeploymentId -cne $activationId) { throw 'Invalid gateway activation provenance' }
    } elseif ($review.ContainsKey('activationDeploymentId')) { throw 'Gateway activation provenance requires an explicit source' }
}

function Assert-FoundationTransition($Manifest, [string]$SelectedAction, [bool]$Approved) {
    if ($SelectedAction -cnotin @('Preview','Deploy','Status')) { throw 'Unknown foundation action' }
    if ($SelectedAction -cne 'Status' -and -not $Approved) { throw 'Explicit ApproveFoundationCreation opt-in required on Preview and Deploy' }
    if ($null -ne $Manifest) {
        if ($Manifest -isnot [hashtable] -or $Manifest.pending -isnot [bool] -or $Manifest.verified -isnot [bool] -or ($Manifest.pending -and $Manifest.verified)) { throw 'Invalid foundation manifest' }
        if ($SelectedAction -cne 'Status' -and ($Manifest.pending -or $Manifest.verified)) { throw 'Foundation intent already recorded; use Status, never replay' }
    }
    if ($SelectedAction -ceq 'Status' -and ($null -eq $Manifest -or (-not $Manifest.pending -and -not $Manifest.verified))) { throw 'No foundation submission to reconcile' }
    if ($SelectedAction -ceq 'Deploy' -and ($null -eq $Manifest -or $Manifest.review -isnot [hashtable])) { throw 'Confirmed Preview required' }
}

function Read-FoundationJson([string]$Path) {
    $options = @{AsHashtable=$true;Depth=100}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind='String' }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @options
}

function Assert-FoundationGuid($Value) {
    $parsed=[guid]::Empty
    if ($Value -isnot [string] -or -not [guid]::TryParseExact($Value,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'Nonzero canonical GUID required' }
}

function Get-FoundationComputedNames([string]$AccountName, [string]$EndpointName, [string]$Compiler) {
    if ($AccountName -cnotmatch '^aif-fgl-[a-z0-9]{6,12}-b-[a-z0-9]{13}$' -or $EndpointName -cnotmatch '^pe-fgl-[a-z0-9]{6,12}-case-b$') { throw 'Invalid naming input' }
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('foundation-names-'+[guid]::NewGuid().ToString('N'))
    try {
        $null=[IO.Directory]::CreateDirectory($scratch)
        $source=Join-Path $scratch 'names.bicepparam'; $output=Join-Path $scratch 'names.json'
        [IO.File]::WriteAllText($source, "using none`nparam dns = uniqueString('$EndpointName')`nparam reader = guid('$AccountName', 'developer-reader')`nparam user = guid('$AccountName', 'b', 'dev-foundry-user')`n")
        & $Compiler build-params $source --no-restore --outfile $output *> (Join-Path $scratch 'build.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Local deterministic name compilation failed' }
        $values=(Read-FoundationJson $output).parameters
        if ($values.dns.value -isnot [string] -or $values.dns.value -cnotmatch '^[a-z0-9]{13}$') { throw 'Invalid compiled DNS name' }
        Assert-FoundationGuid $values.reader.value; Assert-FoundationGuid $values.user.value
        return @{dns=$values.dns.value;reader=$values.reader.value;user=$values.user.value}
    } finally { if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force } }
}

function Get-FoundationBinding([hashtable]$State, [hashtable]$Lab, [string]$Compiler) {
    Assert-FoundationOriginal $State
    $null=Get-LabPrivateTargets $State $Lab
    Assert-FoundationText $Lab.phase 'activate'
    if ($Lab.phase -cne 'activate' -or $Lab.pendingPhase -or $Lab.identities -isnot [array] -or $Lab.identities.Count -ne 7) { throw 'Original activation outputs required' }
    $stem="fgl-$($State.labId)"; $subscription="/subscriptions/$($State.subscriptionId)"
    $integration="$subscription/resourceGroups/rg-$stem-integration"; $groupA="$subscription/resourceGroups/rg-$stem-case-a"; $groupB="$subscription/resourceGroups/rg-$stem-case-b"
    $suffix=($Lab.models -split '-')[-1]; $accountName="aif-$stem-b-$suffix"; $endpointName="pe-$stem-case-b"
    $computed=Get-FoundationComputedNames $accountName $endpointName $Compiler
    $accountB="$groupB/providers/Microsoft.CognitiveServices/accounts/$accountName"; $endpoint="$groupB/providers/Microsoft.Network/privateEndpoints/$endpointName"
    $binding=@{subscription=$subscription;stem=$stem;groupA=$groupA;groupB=$groupB;integration=$integration;groupName="rg-$stem-case-b";name="$stem-expansion-foundation";accountA=$Lab.cases[0].accountId;devA=$Lab.cases[0].projects[0].resourceId;accountB=$accountB;endpoint=$endpoint;zoneGroup="$endpoint/privateDnsZoneGroups/default";workspace="$groupB/providers/Microsoft.OperationalInsights/workspaces/log-$stem-case-b";insights="$groupB/providers/Microsoft.Insights/components/appi-$stem-case-b";ampls="$integration/providers/Microsoft.Insights/privateLinkScopes/ampls-$stem";vnet="$integration/providers/Microsoft.Network/virtualNetworks/vnet-$stem";roles=@{};new=@{};nested=@{};identities=@{}}
    $binding.root="$subscription/providers/Microsoft.Resources/deployments/$($binding.name)"
    $binding.agentSubnet="$($binding.vnet)/subnets/snet-agent-b"; $binding.peSubnet="$($binding.vnet)/subnets/snet-case-b-pe"
    $binding.projects=@("$($binding.accountA)/projects/case-a-test","$accountB/projects/case-b-dev","$accountB/projects/case-b-test")
    $binding.zones=@('cognitiveservices.azure.com','openai.azure.com','services.ai.azure.com' | ForEach-Object { "$integration/providers/Microsoft.Network/privateDnsZones/privatelink.$_" })
    $binding.links=@("$($binding.ampls)/scopedResources/linked-4","$($binding.ampls)/scopedResources/linked-5")
    $binding.diagnostic="$accountB/providers/Microsoft.Insights/diagnosticSettings/metrics-only"
    foreach ($actor in @('dev-a','consumer-a','dev-b','publisher-a','publisher-b','client','denied')) {
        $identity=@($Lab.identities | Where-Object actor -CEQ $actor)
        if ($identity.Count -ne 1 -or $identity[0].resourceId -isnot [string] -or $identity[0].resourceId -ine "$integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-$stem-$actor") { throw 'Original synthetic identity binding mismatch' }
        Assert-FoundationGuid $identity[0].principalId; Assert-FoundationGuid $identity[0].clientId
        $binding.identities[$identity[0].resourceId]=$identity[0]
        if ($actor -ceq 'dev-b') { $binding.developerId=$identity[0].resourceId; $binding.developerPrincipal=$identity[0].principalId }
    }
    foreach ($spec in @(@($accountB,$computed.reader,'acdd72a7-3385-48ef-bd42-f606fba81ae7'),@($binding.projects[1],$computed.user,'53ca6127-db72-4b80-b1b0-d745d6d5456d'))) {
        $binding.roles["$($spec[0])/providers/Microsoft.Authorization/roleAssignments/$($spec[1])"]=@{scope=$spec[0];roleDefinitionId="$subscription/providers/Microsoft.Authorization/roleDefinitions/$($spec[2])";principalId=$binding.developerPrincipal;principalType='ServicePrincipal'}
    }
    foreach ($spec in @(@($groupB,'group'),@($accountB,'account'),@($binding.workspace,'workspace'),@($binding.insights,'insights'),@($endpoint,'endpoint'),@($binding.zoneGroup,'zoneGroup'),@($binding.diagnostic,'diagnostic'))) { $binding.new[$spec[0]]=$spec[1] }
    foreach ($id in $binding.projects) { $binding.new[$id]='project' }
    foreach ($id in $binding.links) { $binding.new[$id]='link' }
    foreach ($id in $binding.roles.Keys) { $binding.new[$id]='role' }
    foreach ($spec in @(@($groupB,"$stem-expansion-monitor-b"),@($groupB,"$stem-expansion-case-b"),@($groupA,"$stem-expansion-project-a-test"),@($groupB,"$stem-expansion-case-b-endpoint"),@($integration,"$stem-expansion-monitor-links-b"),@($groupB,'workspace'),@($groupB,'insights'),@($groupB,'expansion-case-account'),@($groupB,'expansion-projects-b'),@($groupB,$endpointName),@($groupB,"$($computed.dns)-PrivateEndpoint-PrivateDnsZoneGroup"))) { $binding.nested["$($spec[0])/providers/Microsoft.Resources/deployments/$($spec[1])"]=$spec[1] }
    $binding.parameters=@{reviewedFoundationCreation=@{value=$true};labId=@{value=$State.labId};ownershipId=@{value=$State.ownershipId};location=@{value='swedencentral'}}
    return $binding
}

function Assert-FoundationOwned([hashtable]$State, $Resource, [string]$Id) {
    if ($Resource -isnot [hashtable] -or $Resource.id -isnot [string] -or $Resource.id -ine $Id -or $Resource.tags -isnot [hashtable] -or $Resource.tags['fgl-owner'] -cne $State.ownershipId -or $Resource.tags['fgl-lab'] -cne $State.labId -or $Resource.tags.purpose -cne 'synthetic-governance-lab') { throw 'Exact resource identity and owned tags required' }
    foreach ($key in @('fgl-owner','fgl-lab','purpose')) { if ($Resource.tags[$key] -isnot [string]) { throw 'String ownership tags required' } }
}

function Assert-FoundationText($Actual, [string]$Expected) {
    if ($Actual -isnot [string] -or $Actual -ine $Expected) { throw 'Exact string configuration required' }
}

function Assert-FoundationEqual($Actual, $Expected) {
    if ((Get-FoundationHash $Actual) -cne (Get-FoundationHash $Expected)) { throw 'Foundation configuration mismatch' }
}

function Assert-FoundationSet($Actual, [array]$Expected) {
    if ($Actual -isnot [array] -or $Actual.Count -ne $Expected.Count -or @($Actual | Where-Object { $_ -isnot [string] }).Count -or @($Actual | Select-Object -Unique).Count -ne $Actual.Count -or @(Compare-Object $Actual $Expected).Count) { throw 'Exact unique resource coverage required' }
}

function Assert-FoundationNewResource([hashtable]$State, [hashtable]$Binding, $Resource, [string]$Id, [switch]$Live) {
    $kind=$Binding.new[$Id]
    $types=@{group='Microsoft.Resources/resourceGroups';account='Microsoft.CognitiveServices/accounts';project='Microsoft.CognitiveServices/accounts/projects';workspace='Microsoft.OperationalInsights/workspaces';insights='Microsoft.Insights/components';endpoint='Microsoft.Network/privateEndpoints';zoneGroup='Microsoft.Network/privateEndpoints/privateDnsZoneGroups';diagnostic='Microsoft.Insights/diagnosticSettings';role='Microsoft.Authorization/roleAssignments';link='Microsoft.Insights/privateLinkScopes/scopedResources'}
    if (-not $kind -or $Resource -isnot [hashtable] -or $Resource.id -isnot [string] -or $Resource.id -ine $Id -or $Resource.type -isnot [string] -or $Resource.type -ine $types[$kind] -or ($Resource.properties -isnot [hashtable] -and ($kind -cne 'group' -or $Live))) { throw 'Unexpected foundation resource' }
    $properties=$Resource.properties
    if ($kind -cin @('group','account','project','workspace','insights','endpoint')) {
        Assert-FoundationOwned $State $Resource $Id
        if ($Resource.location -isnot [string] -or $Resource.location -cne 'swedencentral') { throw 'Unexpected foundation location' }
    }
    if ($Live -and $kind -cin @('group','account','project','workspace','insights','endpoint','zoneGroup','link')) { Assert-FoundationText $properties.provisioningState 'Succeeded' }
    switch ($kind) {
        'account' {
            Assert-FoundationText $Resource.kind 'AIServices'; Assert-FoundationText $Resource.sku.name 'S0'; Assert-FoundationText $properties.publicNetworkAccess 'Disabled'; Assert-FoundationText $properties.customSubDomainName ($Id -split '/')[-1]
            if ($Resource.kind -cne 'AIServices' -or $Resource.sku.name -cne 'S0' -or $properties.publicNetworkAccess -cne 'Disabled' -or $properties.customSubDomainName -cne ($Id -split '/')[-1]) { throw 'Private AIServices S0 resource required' }
            Assert-FoundationEqual $properties.disableLocalAuth $true; Assert-FoundationEqual $properties.allowProjectManagement $true; Assert-FoundationEqual $properties.restrictOutboundNetworkAccess $false
            if ($properties.networkAcls -isnot [hashtable]) { throw 'Network ACLs required' }
            $acls=$properties.networkAcls.Clone()
            foreach ($key in @('ipRules','virtualNetworkRules')) { if (-not $acls.ContainsKey($key)) { $acls[$key]=@() } }
            Assert-FoundationEqual $acls @{defaultAction='Deny';bypass='None';ipRules=@();virtualNetworkRules=@()}
            Assert-FoundationEqual $properties.networkInjections @(@{scenario='agent';subnetArmId=$Binding.agentSubnet;useMicrosoftManagedNetwork=$false})
        }
        'project' {
            if ($properties.ContainsKey('publicNetworkAccess')) { Assert-FoundationText $properties.publicNetworkAccess 'Disabled' }
        }
        'workspace' {
            Assert-FoundationText $properties.publicNetworkAccessForIngestion 'Disabled'; Assert-FoundationText $properties.publicNetworkAccessForQuery 'Disabled'
            if ($Live -or $properties.ContainsKey('features')) { Assert-FoundationEqual $properties.features.disableLocalAuth $true }
            if ($properties.publicNetworkAccessForIngestion -cne 'Disabled' -or $properties.publicNetworkAccessForQuery -cne 'Disabled') { throw 'Private workspace required' }
        }
        'insights' {
            Assert-FoundationText $properties.publicNetworkAccessForIngestion 'Disabled'; Assert-FoundationText $properties.publicNetworkAccessForQuery 'Disabled'; Assert-FoundationText $properties.WorkspaceResourceId $Binding.workspace
            Assert-FoundationEqual $properties.DisableLocalAuth $true
            if ($properties.publicNetworkAccessForIngestion -cne 'Disabled' -or $properties.publicNetworkAccessForQuery -cne 'Disabled' -or $properties.WorkspaceResourceId -ine $Binding.workspace) { throw 'Private workspace-bound insights required' }
        }
        'endpoint' {
            Assert-FoundationText $properties.subnet.id $Binding.peSubnet
            if ($properties.subnet.id -ine $Binding.peSubnet -or $properties.privateLinkServiceConnections -isnot [array] -or $properties.privateLinkServiceConnections.Count -ne 1 -or @($properties.manualPrivateLinkServiceConnections).Where({$null -ne $_}).Count) { throw 'Exact B PE subnet and one automatic connection required' }
            $connection=$properties.privateLinkServiceConnections[0].properties
            Assert-FoundationText $connection.privateLinkServiceId $Binding.accountB
            if ($connection.privateLinkServiceId -ine $Binding.accountB) { throw 'PE target mismatch' }
            Assert-FoundationEqual $connection.groupIds @('account')
            if ($Live) { Assert-FoundationText $connection.privateLinkServiceConnectionState.status 'Approved' }
        }
        'zoneGroup' {
            if ($properties.privateDnsZoneConfigs -isnot [array]) { throw 'DNS configurations required' }
            Assert-FoundationSet @($properties.privateDnsZoneConfigs | ForEach-Object { $_.properties.privateDnsZoneId }) $Binding.zones
        }
        'link' {
            $target=if ($Id -ieq $Binding.links[0]) { $Binding.workspace } else { $Binding.insights }
            if ($properties.linkedResourceId -isnot [string] -or $properties.linkedResourceId -ine $target) { throw 'AMPLS link target mismatch' }
        }
        'role' {
            $principals=@($Binding.roles[$Id].principalId)
            if (-not $Live) { $principals+="[reference('$($Binding.developerId)', '2023-01-31').principalId]" }
            if ($properties.principalId -isnot [string] -or $properties.principalId -inotin $principals -or $properties.roleDefinitionId -isnot [string] -or $properties.roleDefinitionId -ine $Binding.roles[$Id].roleDefinitionId) { throw 'Incorrect role principal or definition' }
            if (($Live -or $properties.ContainsKey('principalType')) -and ($properties.principalType -isnot [string] -or $properties.principalType -cne 'ServicePrincipal')) { throw 'Incorrect role principal type' }
            if (($Live -or $properties.ContainsKey('scope')) -and ($properties.scope -isnot [string] -or $properties.scope -ine $Binding.roles[$Id].scope)) { throw 'Incorrect role scope' }
            foreach ($key in @('condition','conditionVersion','delegatedManagedIdentityResourceId')) { if ($properties[$key]) { throw 'Unexpected role permissions' } }
        }
        'diagnostic' {
            Assert-FoundationText $properties.workspaceId $Binding.workspace
            if ($properties.workspaceId -ine $Binding.workspace -or $properties.storageAccountId -or $properties.eventHubAuthorizationRuleId -or $properties.eventHubName -or $properties.marketplacePartnerId) { throw 'Metrics destination mismatch' }
            if ($properties.metrics -isnot [array] -or $properties.metrics.Count -ne 1 -or $properties.metrics[0].category -cne 'AllMetrics') { throw 'Exactly AllMetrics required' }
            Assert-FoundationText $properties.metrics[0].category 'AllMetrics'
            Assert-FoundationEqual $properties.metrics[0].enabled $true
            if ($properties.ContainsKey('logs') -and ($properties.logs -isnot [array] -or @($properties.logs | Where-Object { $_.enabled -isnot [bool] -or $_.enabled }).Count)) { throw 'Prompt logging forbidden' }
        }
    }
    if ($kind -cin @('account','project')) {
        Assert-FoundationText $Resource.identity.type 'SystemAssigned'
        if ($Resource.identity.type -cne 'SystemAssigned' -or $Resource.identity.userAssignedIdentities) { throw 'Only a system identity is allowed' }
        if ($Live) { Assert-FoundationGuid $Resource.identity.principalId; Assert-FoundationText $Resource.identity.tenantId $State.tenantId }
    }
}

function Select-FoundationConfiguration($Resource) {
    $fields=@{
        'Microsoft.Resources/resourceGroups'=@()
        'Microsoft.CognitiveServices/accounts'=@('publicNetworkAccess','disableLocalAuth','allowProjectManagement','customSubDomainName','networkInjections','networkAcls','restrictOutboundNetworkAccess','allowedFqdnList','encryption','userOwnedStorage')
        'Microsoft.CognitiveServices/accounts/projects'=@('publicNetworkAccess','internalId','displayName','description')
        'Microsoft.CognitiveServices/accounts/capabilityHosts'=@('capabilityHostKind','customerSubnet','storageConnections','vectorStoreConnections','threadStorageConnections','enablePublicHostingEnvironment')
        'Microsoft.CognitiveServices/accounts/projects/capabilityHosts'=@('capabilityHostKind','customerSubnet','storageConnections','vectorStoreConnections','threadStorageConnections','enablePublicHostingEnvironment')
        'Microsoft.ManagedIdentity/userAssignedIdentities'=@('principalId','clientId','tenantId')
        'Microsoft.Network/virtualNetworks'=@('addressSpace','dhcpOptions','enableDdosProtection','virtualNetworkPeerings')
        'Microsoft.Network/virtualNetworks/subnets'=@('addressPrefix','addressPrefixes','networkSecurityGroup','natGateway','routeTable','delegations','privateEndpointNetworkPolicies','privateLinkServiceNetworkPolicies','serviceEndpoints','defaultOutboundAccess')
        'Microsoft.Network/networkSecurityGroups'=@('securityRules','defaultSecurityRules')
        'Microsoft.Network/privateDnsZones'=@('maxNumberOfRecordSets','maxNumberOfVirtualNetworkLinks')
        'Microsoft.Insights/privateLinkScopes'=@('accessModeSettings')
        'Microsoft.ApiManagement/service'=@('publicNetworkAccess','virtualNetworkType','virtualNetworkConfiguration','customProperties','hostnameConfigurations','disableGateway','enableClientCertificate')
        'Microsoft.ApiManagement/service/apis/policies'=@('format','value')
        'Microsoft.Storage/storageAccounts'=@('publicNetworkAccess','allowSharedKeyAccess','allowBlobPublicAccess','minimumTlsVersion','supportsHttpsTrafficOnly','networkAcls')
        'Microsoft.Search/searchServices'=@('publicNetworkAccess','disableLocalAuth','networkRuleSet')
        'Microsoft.DocumentDB/databaseAccounts'=@('publicNetworkAccess','disableLocalAuth','ipRules','isVirtualNetworkFilterEnabled','virtualNetworkRules','networkAclBypass','networkAclBypassResourceIds')
        'Microsoft.Network/privateEndpoints'=@('subnet','privateLinkServiceConnections','manualPrivateLinkServiceConnections')
        'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'=@('privateDnsZoneConfigs')
        'Microsoft.Network/privateDnsZones/virtualNetworkLinks'=@('virtualNetwork','registrationEnabled','resolutionPolicy')
        'Microsoft.Insights/privateLinkScopes/scopedResources'=@('linkedResourceId')
        'Microsoft.OperationalInsights/workspaces'=@('publicNetworkAccessForIngestion','publicNetworkAccessForQuery','features','retentionInDays','workspaceCapping')
        'Microsoft.Insights/components'=@('publicNetworkAccessForIngestion','publicNetworkAccessForQuery','DisableLocalAuth','WorkspaceResourceId','RetentionInDays')
        'Microsoft.Authorization/roleAssignments'=@('scope','principalId','principalType','roleDefinitionId','condition','conditionVersion')
    }
    if ($Resource -isnot [hashtable] -or $Resource.type -isnot [string] -or -not $fields.ContainsKey($Resource.type)) { throw 'Unknown protected configuration type' }
    function Remove-FoundationVolatile($Value) {
        if ($Value -is [Collections.IDictionary]) { $result=@{}; foreach ($key in $Value.Keys) { if ($key -notin @('etag','provisioningState','createdAt','lastModifiedAt','systemData','resourceGuid')) { $result[$key]=Remove-FoundationVolatile $Value[$key] } }; return $result }
        if ($Value -is [array]) { return ,@(@(foreach ($item in $Value) { Remove-FoundationVolatile $item }) | Sort-Object { ConvertTo-FoundationCanonical $_ }) }
        return $Value
    }
    $selected=@{id=$Resource.id.ToLowerInvariant();type=$Resource.type.ToLowerInvariant();location=$Resource.location;kind=$Resource.kind;sku=$Resource.sku;identity=$Resource.identity;tags=$Resource.tags;properties=@{}}
    $properties=@{}
    if ($Resource.properties -is [hashtable]) { $properties=$Resource.properties }
    foreach ($key in $fields[$Resource.type]) { $selected.properties[$key]=$properties[$key] }
    return Remove-FoundationVolatile $selected
}

function Assert-FoundationWhatIf([hashtable]$State, [hashtable]$Binding, [hashtable]$Baseline, [hashtable]$Result) {
    if ($Result.status -isnot [string] -or $Result.status -cne 'Succeeded' -or $Result.changes -isnot [array] -or -not $Result.changes.Count) { throw 'Expanded successful what-if required' }
    $seen=@{}; $created=@{}
    foreach ($change in $Result.changes) {
        $id=$change.resourceId
        if ($id -isnot [string] -or $seen.ContainsKey($id) -or $change.changeType -isnot [string]) { throw 'Malformed or duplicate what-if resource' }
        $seen[$id]=$true
        if ($change.changeType -ceq 'Ignore') {
            if (-not $Baseline.ContainsKey($id) -and $change.before.type -cin @('Microsoft.Network/networkInterfaces','Microsoft.EventGrid/systemTopics')) {
                $ownedPrefixes=@($State.resourceGroups | ForEach-Object { "$($Binding.subscription)/resourceGroups/$_/providers/$($change.before.type)/" })
                if (@($ownedPrefixes | Where-Object { $id.StartsWith($_,[StringComparison]::OrdinalIgnoreCase) }).Count -ne 1 -or $change.before.id -ine $id -or $change.after -isnot [hashtable] -or @($change.delta).Where({$null -ne $_}).Count) { throw 'Unbound generated resource Ignore' }
                Assert-FoundationEqual $change.before $change.after
                continue
            }
            if (-not $Baseline.ContainsKey($id) -or $change.before -isnot [hashtable] -or $change.before.id -ine $id -or @($change.delta).Where({$null -ne $_}).Count) { throw 'Ignore is not a known unchanged protected resource' }
            if ($null -ne $change.after) {
                Assert-FoundationEqual (Select-FoundationConfiguration $change.after) (Select-FoundationConfiguration $change.before)
            }
            continue
        }
        if ($change.changeType -cne 'Create' -or $change.before -or $change.after -isnot [hashtable] -or $change.after.id -ine $id) { throw 'Only new exact Create operations are allowed' }
        if ($Binding.nested.ContainsKey($id)) {
            Assert-FoundationText $change.after.type 'Microsoft.Resources/deployments'; Assert-FoundationText $change.after.properties.mode 'Incremental'
        } else {
            Assert-FoundationNewResource $State $Binding $change.after $id
            $created[$id]=$true
        }
    }
    Assert-FoundationSet @($created.Keys) @($Binding.new.Keys)
}

function Invoke-FoundationAz([hashtable]$State, [string[]]$Arguments, [string]$Label) {
    $context=$State.Clone()
    $context.runDirectory=Assert-ExternalLabPath (Join-Path $State.runDirectory 'expansion-foundation-evidence')
    $null=[IO.Directory]::CreateDirectory($context.runDirectory)
    return Invoke-LabAz $context $Arguments "foundation-$Label"
}

function Read-FoundationArm([hashtable]$State, [string]$Id, [string]$Api, [switch]$List, [string]$Query = '') {
    if ($Query -cnotin @('','&$filter=atScope()')) { throw 'Unexpected ARM query' }
    $response=Invoke-FoundationAz $State @('rest','--method','get','--url',"https://management.azure.com${Id}?api-version=$Api$Query",'--headers','Accept=application/json') 'read'
    if ($response -isnot [hashtable]) { throw 'Missing ARM evidence' }
    if ($List) {
        if ($response.value -isnot [array] -or ($null -ne $response.nextLink -and ($response.nextLink -isnot [string] -or $response.nextLink.Length))) { throw 'Incomplete ARM list; absence cannot be inferred' }
        $seen=@{}
        foreach ($item in $response.value) {
            if ($item -isnot [hashtable] -or $item.id -isnot [string] -or -not $item.id -or $seen.ContainsKey($item.id)) { throw 'Malformed or duplicate ARM list entry' }
            $seen[$item.id]=$true
        }
        return $response.value
    }
    if ($response.id -isnot [string] -or $response.id -ine $Id) { throw 'ARM response identity mismatch' }
    return $response
}

function Get-FoundationRootIds([hashtable]$State) {
    Assert-FoundationOriginal $State
    $prefix="/subscriptions/$($State.subscriptionId)"
    $roots=@('bootstrap','lock','activate' | ForEach-Object { "$prefix/providers/Microsoft.Resources/deployments/fgl-$($State.labId)-$_" })
    $roots+=@($State.standard.deploymentNames.Values | ForEach-Object { "$prefix/providers/Microsoft.Resources/deployments/$_" })
    foreach ($key in @('cosmosNetwork','gatewayPolicy')) {
        $receipt=$State.standard[$key]
        if ($key -ceq 'gatewayPolicy' -and $receipt.review.source -ceq 'activation-policy-reuse') { continue }
        $roots+="$prefix/resourceGroups/$($receipt.group)/providers/Microsoft.Resources/deployments/$($receipt.name)"
    }
    return $roots
}

function Assert-FoundationEnvironmentDeployment([hashtable]$Binding, [hashtable]$Child, [array]$Operations) {
    $prefix="$($Binding.groupB)/providers/Microsoft.Resources/deployments/"
    if ($Child.name -isnot [string] -or $Child.id -ine "$prefix$($Child.name)" -or $Child.properties.mode -cne 'Incremental' -or $Child.properties.provisioningState -cne 'Failed' -or @($Child.properties.outputResources).Where({$null -ne $_}).Count -or -not $Operations.Count) { throw 'External deployment requires effect review' }
    $kind=if ($Child.name -cmatch '^PolicyDeployment_[0-9]+$') { 'inherited-diagnostics' } elseif ($Child.name -cmatch '^Failure-Anomalies-Alert-Rule-Deployment-[0-9]+$') { 'automatic-alert' } else { throw 'Unrecognized external deployment' }
    $targets=@()
    foreach ($operation in $Operations) {
        $properties=$operation.properties
        if ($properties.provisioningState -cne 'Failed') { throw 'External operation is active or has possible successful effects' }
        if ($properties.provisioningOperation -ceq 'EvaluateDeploymentOutput' -and -not $properties.targetResource) { continue }
        $target=$properties.targetResource
        if ($properties.provisioningOperation -cne 'Create' -or $target.id -isnot [string]) { throw 'Unrecognized external operation' }
        if ($kind -ceq 'inherited-diagnostics') {
            $expectedPrefix="$($Binding.accountB)/providers/Microsoft.Insights/diagnosticSettings/"
            if ($target.resourceType -ine 'Microsoft.CognitiveServices/accounts/providers/diagnosticSettings' -or -not $target.id.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase) -or $target.id.Substring($expectedPrefix.Length) -notmatch '^[^/]+$' -or $target.id -ieq $Binding.diagnostic) { throw 'External diagnostic target is outside the new account' }
        } else {
            $expectedPrefix="$($Binding.groupB)/providers/Microsoft.AlertsManagement/smartDetectorAlertRules/"
            if ($target.resourceType -ine 'Microsoft.AlertsManagement/smartDetectorAlertRules' -or -not $target.id.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase) -or $target.id.Substring($expectedPrefix.Length) -notmatch '^[^/]+$') { throw 'External alert target is outside the new group' }
        }
        $targets+=$target.id
    }
    if ($targets.Count -ne 1) { throw 'Exactly one failed external resource operation required' }
    return @{deploymentId=$Child.id;kind=$kind;state='Failed';targetId=$targets[0];deploymentHash=(Get-FoundationHash $Child);operationsHash=(Get-FoundationHash $Operations)}
}

function Confirm-FoundationIdle([hashtable]$State, [hashtable]$Binding, [switch]$Submitted, [switch]$IncludeEnvironmentEvidence) {
    $environmentEvidence=@()
    foreach ($id in @(Get-FoundationRootIds $State)) {
        $root=Read-FoundationArm $State $id '2022-09-01'
        if ($root.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Original or narrow root is active' }
        if ($id -notin @('bootstrap','lock' | ForEach-Object { "$($Binding.subscription)/providers/Microsoft.Resources/deployments/$($Binding.stem)-$_" })) { Assert-FoundationText $root.properties.provisioningState 'Succeeded' }
    }
    $roots=@(Read-FoundationArm $State "$($Binding.subscription)/providers/Microsoft.Resources/deployments" '2022-09-01' -List)
    $matching=@($roots | Where-Object id -IEQ $Binding.root)
    if (-not $Submitted -and $matching.Count) { throw 'Existing foundation root cannot be adopted' }
    $groups=@($State.resourceGroups)
    if ($Submitted) { $groups+=$Binding.groupName }
    $seen=@{}
    foreach ($group in $groups) {
        $prefix="$($Binding.subscription)/resourceGroups/$group/providers/Microsoft.Resources/deployments"
        $nested=@(Read-FoundationArm $State $prefix '2022-09-01' -List)
        if (-not $nested.Count) { throw 'Nested deployment coverage missing' }
        foreach ($child in $nested) {
            if ($child.name -isnot [string] -or $child.id -ine "$prefix/$($child.name)" -or $child.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Nested deployment is malformed or active' }
            if ($Binding.nested.ContainsKey($child.id)) {
                if (-not $Submitted) { throw 'Existing expansion nested deployment cannot be adopted' }
                Assert-FoundationText $child.properties.mode 'Incremental'; Assert-FoundationText $child.properties.provisioningState 'Succeeded'
                $seen[$child.id]=$true
            } elseif ($group -ceq $Binding.groupName) {
                $operations=@(Read-FoundationArm $State "$($child.id)/operations" '2022-09-01' -List)
                $finding=Assert-FoundationEnvironmentDeployment $Binding $child $operations
                $actual=@(Read-FoundationArm $State "$($Binding.groupB)/resources" '2021-04-01' -List)
                $diagnostics=@(Read-FoundationArm $State "$($Binding.accountB)/providers/Microsoft.Insights/diagnosticSettings" '2021-05-01-preview' -List)
                if (@(@($actual)+@($diagnostics) | Where-Object id -IEQ $finding.targetId).Count) { throw 'External resource exists; configuration review required' }
                $finding.targetAbsent=$true
                $environmentEvidence+=$finding
            }
        }
    }
    if ($Submitted) { Assert-FoundationSet @($seen.Keys) @($Binding.nested.Keys) }
    if ($IncludeEnvironmentEvidence) { return $environmentEvidence }
}

function Assert-FoundationAbsence([hashtable]$State, [hashtable]$Binding, [array]$Groups, [array]$Projects, [array]$Links, [switch]$After) {
    Assert-StandardGroups $State @($Groups | Where-Object { $_.name -in $State.resourceGroups })
    $newGroup=@($Groups | Where-Object { $_.id -ieq $Binding.groupB -or $_.name -ieq $Binding.groupName })
    if (-not $After -and $newGroup.Count) { throw 'Case B group collision; no adoption' }
    if ($After -and $newGroup.Count -ne 1) { throw 'New group missing' }
    $expected=@($Binding.devA)
    if ($After) { $expected+=$Binding.projects[0] }
    Assert-FoundationSet @($Projects | ForEach-Object { $_.id }) $expected
    $expectedLinks=@(0..3 | ForEach-Object { "$($Binding.ampls)/scopedResources/linked-$_" })
    if ($After) { $expectedLinks+=$Binding.links }
    Assert-FoundationSet @($Links | ForEach-Object { $_.id }) $expectedLinks
}

function Get-FoundationLive([hashtable]$State, [hashtable]$Lab, [hashtable]$Standard, [hashtable]$Activation, [hashtable]$Binding, [switch]$After) {
    Assert-FoundationOriginal $State
    Assert-LabContext $State (Invoke-FoundationAz $State @('account','show') 'context')
    $groups=@(Read-FoundationArm $State "$($Binding.subscription)/resourceGroups" '2025-04-01' -List)
    $projects=@(Read-FoundationArm $State "$($Binding.accountA)/projects" '2026-05-01' -List)
    $links=@(Read-FoundationArm $State "$($Binding.ampls)/scopedResources" '2021-07-01-preview' -List)
    Assert-FoundationAbsence $State $Binding $groups $projects $links -After:$After
    foreach ($namespace in @('Microsoft.ContainerService','Microsoft.MachineLearningServices')) {
        $provider=Invoke-FoundationAz $State @('provider','show','--namespace',$namespace) 'provider'
        Assert-FoundationText $provider.namespace $namespace; Assert-FoundationText $provider.registrationState 'Registered'
        if ($provider.namespace -cne $namespace -or $provider.registrationState -cne 'Registered') { throw 'Both approved providers must already be Registered; no registration is performed' }
    }
    $accounts=@(Read-FoundationArm $State "$($Binding.subscription)/providers/Microsoft.CognitiveServices/accounts" '2026-05-01' -List)
    $injected=@($accounts | Where-Object { @($_.properties.networkInjections | Where-Object subnetArmId -IEQ $Binding.agentSubnet).Count })
    $expectedInjected=@(); if ($After) { $expectedInjected=@($Binding.accountB) }
    Assert-FoundationSet @($injected | ForEach-Object { $_.id }) $expectedInjected
    $original=Read-FoundationArm $State "$($Binding.subscription)/providers/Microsoft.Resources/deployments/$($Binding.stem)-activate" '2022-09-01'
    Assert-FoundationText $original.properties.provisioningState 'Succeeded'; Assert-FoundationText $original.properties.mode 'Incremental'
    Assert-FoundationEqual $original.properties.outputs.lab.value $Lab
    Assert-LabParameters $State $Activation.parameters
    Assert-FoundationEqual $original.properties.parameters.gatewayPrincipalId.value $Activation.parameters.gatewayPrincipalId.value
    $privateBinding=Get-StandardPrivateBinding $State $Lab $Standard
    $specifications=@{}
    foreach ($spec in @(@($Binding.accountA,'2026-05-01'),@($Binding.devA,'2026-05-01'),@($Lab.models,'2026-05-01'),@($Lab.gateway,'2024-05-01'),@($Binding.vnet,'2024-05-01'),@($Binding.ampls,'2021-07-01-preview'))) { $specifications[$spec[0]]=@{api=$spec[1];owned=$true} }
    foreach ($id in $Binding.identities.Keys) { $specifications[$id]=@{api='2023-01-31';owned=$true} }
    foreach ($subnet in @('agent-a','agent-b','apim','runner','models-pe','case-a-pe','case-b-pe','integration-pe')) { $specifications["$($Binding.vnet)/subnets/snet-$subnet"]=@{api='2024-05-01';owned=$false} }
    foreach ($nsg in @('agent-0','agent-1','endpoints','apim','runner')) { $specifications["$($Binding.integration)/providers/Microsoft.Network/networkSecurityGroups/nsg-$($Binding.stem)-$nsg"]=@{api='2024-05-01';owned=$true} }
    foreach ($zone in $Binding.zones) { $specifications[$zone]=@{api='2024-06-01';owned=$true}; $specifications["$zone/virtualNetworkLinks/lab-only"]=@{api='2024-06-01';owned=$true} }
    foreach ($monitorSuffix in @('integration','case-a')) {
        $monitorGroup="$($Binding.subscription)/resourceGroups/rg-$($Binding.stem)-$monitorSuffix"
        $specifications["$monitorGroup/providers/Microsoft.OperationalInsights/workspaces/log-$($Binding.stem)-$monitorSuffix"]=@{api='2023-09-01';owned=$true}
        $specifications["$monitorGroup/providers/Microsoft.Insights/components/appi-$($Binding.stem)-$monitorSuffix"]=@{api='2020-02-02';owned=$true}
    }
    foreach ($target in $privateBinding.targets) {
        $specifications[$target.id]=@{api=$target.api;owned=$true}
        $specifications[$target.zoneId]=@{api='2024-06-01';owned=$true}
        $specifications[$target.endpointId]=@{api='2024-05-01';owned=$true}
        $specifications["$($target.endpointId)/privateDnsZoneGroups/default"]=@{api='2024-05-01';owned=$false}
    }
    foreach ($target in @(Get-LabPrivateTargets $State $Lab)) { $specifications[$target.endpointId]=@{api='2024-05-01';owned=$true}; $specifications["$($target.endpointId)/privateDnsZoneGroups/default"]=@{api='2024-05-01';owned=$false} }
    $resources=@{}; $baseline=@{}
    foreach ($id in $specifications.Keys) {
        $resource=Read-FoundationArm $State $id $specifications[$id].api
        if ($specifications[$id].owned) { Assert-FoundationOwned $State $resource $id }
        if ($resource.type -in @('Microsoft.OperationalInsights/workspaces','Microsoft.Insights/components')) { Assert-FoundationText $resource.properties.publicNetworkAccessForIngestion 'Disabled'; Assert-FoundationText $resource.properties.publicNetworkAccessForQuery 'Disabled' }
        if ($resource.properties.ContainsKey('provisioningState')) { Assert-FoundationText $resource.properties.provisioningState 'Succeeded' }
        $resources[$id]=$resource; $baseline[$id]=Select-FoundationConfiguration $resource
    }
    foreach ($group in @($groups | Where-Object { $_.name -in $State.resourceGroups })) { $baseline[$group.id]=Select-FoundationConfiguration $group }
    $account=$resources[$Binding.accountA]; $project=$resources[$Binding.devA]; $gateway=$resources[$Lab.gateway]; $model=$resources[$Lab.models]
    $standardBinding=Get-StandardBindings $State $Lab $account $project $gateway
    foreach ($resource in @($account,$model)) { Assert-FoundationEqual $resource.properties.disableLocalAuth $true; Assert-FoundationText $resource.properties.publicNetworkAccess 'Disabled' }
    foreach ($resource in @($account,$project,$gateway,$model)) { Assert-FoundationGuid $resource.identity.principalId; Assert-FoundationText $resource.identity.tenantId $State.tenantId }
    if ($gateway.identity.principalId -ine $Activation.parameters.gatewayPrincipalId.value) { throw 'Original gateway principal changed' }
    foreach ($id in $Binding.identities.Keys) {
        foreach ($key in @('principalId','clientId')) { Assert-FoundationText $resources[$id].properties[$key] $Binding.identities[$id][$key] }
        Assert-FoundationText $resources[$id].properties.tenantId $State.tenantId
    }
    $accountHosts=@(Read-FoundationArm $State "$($Binding.accountA)/capabilityHosts" '2026-05-01' -List)
    $projectHosts=@(Read-FoundationArm $State "$($Binding.devA)/capabilityHosts" '2026-05-01' -List)
    Assert-StandardHosts $State $standardBinding 'access' $accountHosts $projectHosts $Standard.dependencies.storage.name
    foreach ($resource in @($accountHosts)+@($projectHosts)) { $baseline[$resource.id]=Select-FoundationConfiguration $resource }
    Assert-FoundationSet @($resources[$Binding.vnet].properties.subnets | ForEach-Object { $_.id }) @($specifications.Keys | Where-Object { $_.StartsWith("$($Binding.vnet)/subnets/",[StringComparison]::OrdinalIgnoreCase) })
    $agent=$resources[$Binding.agentSubnet]; $pe=$resources[$Binding.peSubnet]
    Assert-CosmosNetworkSubnet $agent '10.76.2.0/24' "$($Binding.integration)/providers/Microsoft.Network/networkSecurityGroups/nsg-$($Binding.stem)-agent-1"
    Assert-CosmosNetworkSubnet $pe '10.76.7.0/27' "$($Binding.integration)/providers/Microsoft.Network/networkSecurityGroups/nsg-$($Binding.stem)-endpoints"
    if ($agent.properties.delegations -isnot [array] -or $agent.properties.delegations.Count -ne 1 -or $agent.properties.delegations[0].properties.serviceName -cne 'Microsoft.App/environments' -or $pe.properties.privateEndpointNetworkPolicies -cne 'NetworkSecurityGroupEnabled') { throw 'B subnet delegation or PE policies mismatch' }
    Assert-FoundationText $agent.properties.delegations[0].properties.serviceName 'Microsoft.App/environments'; Assert-FoundationText $pe.properties.privateEndpointNetworkPolicies 'NetworkSecurityGroupEnabled'
    if (-not $After) { foreach ($key in @('serviceAssociationLinks','ipConfigurations','privateEndpoints','resourceNavigationLinks')) { if (@($agent.properties[$key]).Where({$null -ne $_}).Count) { throw 'B agent subnet is not exclusive and unused' } } }
    $access=$resources[$Binding.ampls].properties.accessModeSettings
    Assert-FoundationText $access.ingestionAccessMode 'PrivateOnly'; Assert-FoundationText $access.queryAccessMode 'PrivateOnly'
    if ($access.ingestionAccessMode -cne 'PrivateOnly' -or $access.queryAccessMode -cne 'PrivateOnly' -or @($access.exclusions).Where({$null -ne $_}).Count) { throw 'Owned AMPLS must remain private-only without exclusions' }
    foreach ($link in @($links | Where-Object { $_.id -notin $Binding.links })) {
        $index=[int](($link.id -split '-')[-1]); $monitorGroup=if ($index -lt 2) { $Binding.integration } else { $Binding.groupA }; $monitorSuffix=if ($index -lt 2) { 'integration' } else { 'case-a' }
        $target=if ($index % 2 -eq 0) { "$monitorGroup/providers/Microsoft.OperationalInsights/workspaces/log-$($Binding.stem)-$monitorSuffix" } else { "$monitorGroup/providers/Microsoft.Insights/components/appi-$($Binding.stem)-$monitorSuffix" }
        if ($link.properties.linkedResourceId -ine $target) { throw 'Original AMPLS link changed' }
        $baseline[$link.id]=Select-FoundationConfiguration $link
    }
    foreach ($target in $privateBinding.targets) {
        $properties=$resources[$target.id].properties
        Assert-FoundationText $properties.publicNetworkAccess 'Disabled'
        if ($target.service -ceq 'storage') { Assert-FoundationEqual $properties.allowSharedKeyAccess $false } else { Assert-FoundationEqual $properties.disableLocalAuth $true }
    }
    $endpointTargets=@($privateBinding.targets | ForEach-Object { @{endpointId=$_.endpointId;targetId=$_.id;groupId=$_.groupId;subnetId=$privateBinding.subnetId} })
    foreach ($target in @(Get-LabPrivateTargets $State $Lab)) {
        $subnetName=if ($target.key -ceq 'gateway') { 'integration' } else { $target.key }
        $endpointTargets+=@{endpointId=$target.endpointId;targetId=$target.resourceId;groupId=$target.groupId;subnetId="$($Binding.vnet)/subnets/snet-$subnetName-pe"}
    }
    foreach ($target in $endpointTargets) {
        $properties=$resources[$target.endpointId].properties
        if ($properties.subnet.id -ine $target.subnetId -or $properties.privateLinkServiceConnections -isnot [array] -or $properties.privateLinkServiceConnections.Count -ne 1 -or @($properties.manualPrivateLinkServiceConnections).Where({$null -ne $_}).Count) { throw 'Original PE binding changed' }
        $connection=$properties.privateLinkServiceConnections[0].properties
        if ($connection.privateLinkServiceId -ine $target.targetId -or $connection.privateLinkServiceConnectionState.status -cne 'Approved') { throw 'Original PE target or approval mismatch' }
        Assert-FoundationEqual $connection.groupIds @($target.groupId)
    }
    foreach ($zone in $Binding.zones) {
        $link=$resources["$zone/virtualNetworkLinks/lab-only"]
        if ($link.properties.virtualNetwork.id -ine $Binding.vnet) { throw 'Referenced DNS zone VNet binding mismatch' }
        Assert-FoundationEqual $link.properties.registrationEnabled $false
    }
    $policyId="$($Lab.gateway)/apis/lab-inference/policies/policy"
    $policy=Read-FoundationArm $State $policyId '2024-05-01'
    $caller=@($Lab.identities | Where-Object actor -CEQ 'client')[0]
    $policyBinding=@{tenantId=$State.tenantId;parameters=@{modelAccountName=@{value=($Lab.models -split '/')[-1]};allowedPrincipalIds=@{value=@($project.identity.principalId,$caller.principalId)}}}
    $pair=Get-GatewayPolicyPair (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../infra/policies/inference.xml') -Raw) $policyBinding
    Assert-GatewayPolicyDocument $policy $policyId $pair.after
    $baseline[$policyId]=Select-FoundationConfiguration $policy
    $rule=Read-FoundationArm $State $State.standard.cosmosNetwork.ruleId '2024-05-01'
    Assert-CosmosNetworkRule $rule (Get-CosmosNetworkNames $State) $State.standard.cosmosNetwork.review.binding.addresses -Succeeded
    return $baseline
}

function Get-FoundationPaths([hashtable]$State) {
    $paths=@{}
    foreach ($key in @('state','template','parameters','whatif','outputs','deploy-whatif','build','validation','lock')) { $paths[$key]=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-foundation.$key.json") }
    return $paths
}

function Get-FoundationInputHashes([hashtable]$State, [string]$OriginalPath) {
    $paths=@{state=$OriginalPath}
    foreach ($name in @('outputs.json','standard-outputs.json','activate.parameters.json')) { $paths[$name]=Assert-ExternalLabPath (Join-Path $State.runDirectory $name) }
    foreach ($spec in @(@('cosmosNetwork','standard-cosmos-network.evidence.json'),@('gatewayPolicy','gateway-policy-update.evidence.json'))) {
        $expected=Assert-ExternalLabPath (Join-Path $State.runDirectory $spec[1]); $evidence=$State.standard[$spec[0]].evidence
        if ($evidence.path -isnot [string] -or $evidence.path -ine $expected -or $evidence.sha256 -isnot [string] -or (Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash -cne $evidence.sha256) { throw 'Original narrow evidence missing or changed' }
        $paths[$spec[0]]=$expected
    }
    $hashes=@{}; foreach ($key in $paths.Keys) { $hashes[$key]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
    return $hashes
}

function Get-FoundationSourceHashes {
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $files=@(Get-ChildItem -LiteralPath (Join-Path $root 'infra') -Recurse -File | Where-Object { $_.Extension -in @('.bicep','.xml') } | ForEach-Object { $_.FullName })
    foreach ($name in @('Invoke-ExpansionFoundation.ps1','Invoke-StandardStage.ps1','Test-StandardPrivate.ps1','Invoke-StandardCosmosNetwork.ps1','Update-LabGatewayPolicy.ps1','LabExecution.psm1','LabSafety.psm1','PublicSource.psm1')) { $files+=Join-Path $PSScriptRoot $name }
    foreach ($name in @('Test-ExpansionCoordinator.ps1','Test-ExpansionFoundation.ps1','Test-ExpansionProjects.ps1')) { $files+=Join-Path $root "tests/$name" }
    $hashes=@{}; foreach ($file in $files) { $hashes[[IO.Path]::GetRelativePath($root,$file)]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
    if ($hashes.Count -lt 12) { throw 'Source coverage missing' }
    return $hashes
}

function Assert-FoundationValidatorRevision([hashtable]$Original, [hashtable]$Current, [string]$RunDirectory) {
    Assert-FoundationSet @($Current.Keys) @($Original.Keys)
    $allowed=@('scripts\Invoke-ExpansionFoundation.ps1','tests\Test-ExpansionCoordinator.ps1')
    $changed=@{}
    foreach ($key in $Original.Keys) {
        if ($Current[$key] -ceq $Original[$key]) { continue }
        if ($key -cnotin $allowed) { throw 'Only the foundation validator and its test may change during reconciliation' }
        $archive=Join-Path (Join-Path $RunDirectory 'foundation-validator-submitted') $key
        if (-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $Original[$key]) { throw 'Submitted validator source archive missing or changed' }
        $changed[$key]=@{submitted=$Original[$key];current=$Current[$key]}
    }
    if (-not $changed.Count) { throw 'No validator revision to approve' }
    return $changed
}

function Assert-FoundationReview([hashtable]$State, [hashtable]$Binding, [hashtable]$Manifest, [hashtable]$Paths, [hashtable]$InputHashes, [switch]$Submitted, [switch]$ValidatorRevisionApproved) {
    $review=$Manifest.review
    if ($review -isnot [hashtable] -or $Manifest.originalSha -cne $InputHashes.state -or $Manifest.scopeHash -cne (Get-FoundationHash $Binding) -or $review.authorization.originalSha -cne $InputHashes.state -or $review.authorization.scopeHash -cne $Manifest.scopeHash) { throw 'Review not bound to the original state and exact foundation IDs' }
    Assert-FoundationEqual $review.authorization.approved $true
    $age=[DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$review.checkedAt)
    if ($age -lt [TimeSpan]::Zero -or (-not $Submitted -and $age -gt [TimeSpan]::FromHours(1))) { throw 'Foundation preview expired or future dated' }
    Assert-FoundationEqual $review.inputHashes $InputHashes
    $currentSources=Get-FoundationSourceHashes
    if ($Submitted -and $ValidatorRevisionApproved) { $null=Assert-FoundationValidatorRevision $review.sourceHashes $currentSources $State.runDirectory } else { Assert-FoundationEqual $review.sourceHashes $currentSources }
    if ($review.baselineHash -cne (Get-FoundationHash $Manifest.baseline)) { throw 'Original protection baseline changed' }
    foreach ($key in @('template','parameters','whatif')) { if ((Get-FileHash -LiteralPath $Paths[$key] -Algorithm SHA256).Hash -cne $review.artifactHashes[$key]) { throw 'Reviewed foundation artifact changed' } }
    $parameters=Read-FoundationJson $Paths.parameters
    Assert-FoundationEqual $parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$Binding.parameters}
    Assert-FoundationWhatIf $State $Binding $Manifest.baseline (Read-FoundationJson $Paths.whatif)
}

function Confirm-FoundationOutputs([hashtable]$State, [hashtable]$Binding, $Output) {
    if ($Output -isnot [hashtable] -or $Output.stage -isnot [string] -or $Output.stage -cne 'foundation-only') { throw 'Foundation output required' }
    Assert-CosmosNetworkKeys $Output @('stage','completeLab','resourceGroupId','workspaceId','insightsId','caseBAccountId','privateEndpointId','privateDnsZoneGroupId','accountDiagnosticSettingId','monitoringLinkIds','roleAssignmentIds','projects','limitations')
    Assert-FoundationEqual $Output.completeLab $false
    foreach ($spec in @(@('resourceGroupId','groupB'),@('workspaceId','workspace'),@('insightsId','insights'),@('caseBAccountId','accountB'),@('privateEndpointId','endpoint'),@('privateDnsZoneGroupId','zoneGroup'),@('accountDiagnosticSettingId','diagnostic'))) { if ($Output[$spec[0]] -isnot [string] -or $Output[$spec[0]] -ine $Binding[$spec[1]]) { throw 'Unexpected foundation output ID' } }
    Assert-FoundationSet $Output.monitoringLinkIds $Binding.links; Assert-FoundationSet $Output.roleAssignmentIds @($Binding.roles.Keys)
    if ($Output.projects -isnot [array]) { throw 'Project output coverage required' }
    Assert-FoundationSet @($Output.projects | ForEach-Object { $_.resourceId }) $Binding.projects
    $ampls=Read-FoundationArm $State $Binding.ampls '2021-07-01-preview'
    Assert-FoundationGuid $ampls.properties.scopeId
    $apis=@{group='2025-04-01';account='2026-05-01';project='2026-05-01';workspace='2023-09-01';insights='2020-02-02';endpoint='2024-05-01';zoneGroup='2024-05-01';link='2021-07-01-preview';role='2022-04-01';diagnostic='2021-05-01-preview'}
    foreach ($id in $Binding.new.Keys) {
        $actual=Read-FoundationArm $State $id $apis[$Binding.new[$id]]
        Assert-FoundationNewResource $State $Binding $actual $id -Live
        if ($Binding.new[$id] -ceq 'project') {
            $reported=@($Output.projects | Where-Object resourceId -IEQ $id)[0]
            Assert-FoundationGuid $reported.principalId
            $qualified=($id -split '/accounts/')[1].Replace('/projects/','/')
            if ($reported.name -isnot [string] -or $reported.name -cnotin @(($id -split '/')[-1],$qualified)) { throw 'New project output name mismatch' }
            if ($reported.principalId -ine $actual.identity.principalId) { throw 'New project output principal mismatch' }
        }
        if ($Binding.new[$id] -ceq 'account') {
            $connections=$actual.properties.privateEndpointConnections
            if ($connections -isnot [array] -or $connections.Count -ne 1) { throw 'Exactly one account-side private endpoint approval required' }
            Assert-FoundationText $connections[0].properties.privateEndpoint.id $Binding.endpoint
            Assert-FoundationText $connections[0].properties.privateLinkServiceConnectionState.status 'Approved'
        }
        if ($Binding.new[$id] -cin @('workspace','insights')) {
            $fields=if ($Binding.new[$id] -ceq 'workspace') { @('privateLinkScopedResources','scopeId','resourceId') } else { @('PrivateLinkScopedResources','ScopeId','ResourceId') }
            $scopes=$actual.properties[$fields[0]]
            if ($scopes -isnot [array] -or $scopes.Count -ne 1) { throw 'Exactly one private monitoring scope required' }
            $linkId=if ($Binding.new[$id] -ceq 'workspace') { $Binding.links[0] } else { $Binding.links[1] }
            Assert-FoundationText $scopes[0][$fields[1]] $ampls.properties.scopeId
            Assert-FoundationText $scopes[0][$fields[2]] $linkId
        }
    }
    foreach ($scope in @($Binding.accountB)+$Binding.projects) {
        $roles=@(Read-FoundationArm $State "$scope/providers/Microsoft.Authorization/roleAssignments" '2022-04-01' -List -Query '&$filter=atScope()')
        $direct=@($roles | Where-Object { $_.id.StartsWith("$scope/providers/Microsoft.Authorization/roleAssignments/",[StringComparison]::OrdinalIgnoreCase) })
        $expected=@($Binding.roles.Keys | Where-Object { $Binding.roles[$_].scope -ieq $scope })
        Assert-FoundationSet @($direct | ForEach-Object { $_.id }) $expected
        foreach ($role in $direct) { Assert-FoundationNewResource $State $Binding $role $role.id -Live }
    }
}

function Invoke-ExpansionFoundation([string]$Path, [string]$SelectedAction, [string]$Compiler, [bool]$Approved, [bool]$ValidatorRevisionApproved = $false) {
    if ($ValidatorRevisionApproved -and $SelectedAction -cne 'Status') { throw 'Validator revision approval is read-only Status only' }
    $originalPath=Assert-ExternalLabPath $Path
    $originalSha=(Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
    $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
    $paths=Get-FoundationPaths $state
    $lock=[IO.File]::Open($paths.lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
        $manifest=$null; if (Test-Path -LiteralPath $paths.state) { $manifest=Read-FoundationJson $paths.state }
        Assert-FoundationTransition $manifest $SelectedAction $Approved
        $inputs=Get-FoundationInputHashes $state $originalPath
        if ($inputs.state -cne $originalSha) { throw 'Original state changed while acquiring coordinator lock' }
        $lab=Read-FoundationJson (Join-Path $state.runDirectory 'outputs.json'); $standard=Read-FoundationJson (Join-Path $state.runDirectory 'standard-outputs.json'); $activation=Read-FoundationJson (Join-Path $state.runDirectory 'activate.parameters.json')
        $binding=Get-FoundationBinding $state $lab $Compiler
        if ($manifest -and ($manifest.originalSha -cne $originalSha -or $manifest.scopeHash -cne (Get-FoundationHash $binding))) { throw 'Expansion belongs to a different original state or scope' }
        if ($manifest -and ($manifest.pending -or $manifest.verified)) { Assert-FoundationText $manifest.deploymentId $binding.root }
        $common=@('--name',$binding.name,'--location','swedencentral','--template-file',$paths.template,'--parameters',"@$($paths.parameters)")
        if ($SelectedAction -ceq 'Status') {
            $validationSources=Get-FoundationSourceHashes
            Assert-FoundationReview $state $binding $manifest $paths $inputs -Submitted -ValidatorRevisionApproved:$ValidatorRevisionApproved
            Assert-LabContext $state (Invoke-FoundationAz $state @('account','show') 'context')
            $deployment=Read-FoundationArm $state $binding.root '2022-09-01'
            Assert-FoundationText $deployment.properties.mode 'Incremental'
            foreach ($key in $binding.parameters.Keys) { Assert-FoundationEqual $deployment.properties.parameters[$key].value $binding.parameters[$key].value }
            $status=$deployment.properties.provisioningState
            if ($status -cin @('Accepted','Running','Creating','Updating','Failed','Canceled')) {
                $operations=@(Read-FoundationArm $state "$($binding.root)/operations" '2022-09-01' -List)
                foreach ($operation in $operations) {
                    $target=$operation.properties.targetResource.id
                    if ($target -and $binding.nested.ContainsKey($target)) { $null=Read-FoundationArm $state $target '2022-09-01' }
                }
                if ($status -cin @('Failed','Canceled')) { throw 'Foundation failed or canceled; pending intent retained for reconciliation' }
                Write-Output 'Foundation still active; use Status. No replay performed.'; return
            }
            Assert-FoundationText $status 'Succeeded'
            $environmentEvidence=@(Confirm-FoundationIdle $state $binding -Submitted -IncludeEnvironmentEvidence)
            $live=Get-FoundationLive $state $lab $standard $activation $binding -After
            Assert-FoundationEqual $live $manifest.baseline
            Confirm-FoundationOutputs $state $binding $deployment.properties.outputs.foundation.value
            Assert-FoundationEqual (Get-FoundationLive $state $lab $standard $activation $binding -After) $manifest.baseline
            Assert-FoundationEqual @(Confirm-FoundationIdle $state $binding -Submitted -IncludeEnvironmentEvidence) $environmentEvidence
            Assert-FoundationEqual (Get-FoundationSourceHashes) $validationSources
            Assert-FoundationReview $state $binding $manifest $paths (Get-FoundationInputHashes $state $originalPath) -Submitted -ValidatorRevisionApproved:$ValidatorRevisionApproved
            $revision=@{}
            if ($ValidatorRevisionApproved) { $revision=Assert-FoundationValidatorRevision $manifest.review.sourceHashes $validationSources $state.runDirectory }
            $output=@{foundation=$deployment.properties.outputs.foundation.value;verifiedAt=[DateTimeOffset]::UtcNow.ToString('o');controlPlaneVerified=$true;inferenceVerified=$false;originalSha=$originalSha;baselineHash=(Get-FoundationHash $live);environmentEvents=$environmentEvidence;validatorRevision=$revision;validationSourceHashes=$validationSources}
            Write-StandardJson $paths.outputs $output
            $manifest.pending=$false; $manifest.verified=$true; $manifest.completedStages=@('foundation'); $manifest.outputHash=(Get-FileHash -LiteralPath $paths.outputs -Algorithm SHA256).Hash
            Write-StandardJson $paths.state $manifest
            Write-Output 'Foundation control-plane verification complete. Original state preserved; no inference or full-expansion readiness claim.'; return
        }
        if ($SelectedAction -ceq 'Deploy') { Assert-FoundationReview $state $binding $manifest $paths $inputs }
        Confirm-FoundationIdle $state $binding
        $live=Get-FoundationLive $state $lab $standard $activation $binding
        if ($manifest) { Assert-FoundationEqual $live $manifest.baseline } else {
            $manifest=@{version=1;stage='foundation-only';originalSha=$originalSha;scopeHash=(Get-FoundationHash $binding);baseline=$live;pending=$false;verified=$false;review=$null;completedStages=@()}
            Write-StandardJson $paths.state $manifest
        }
        $manifestHash=Get-FoundationHash $manifest
        $sources=Get-FoundationSourceHashes
        $reviewStartedAt=[DateTimeOffset]::UtcNow.ToString('o')
        if ($SelectedAction -ceq 'Preview') {
            & $Compiler build (Join-Path $PSScriptRoot '../infra/expansion-foundation.bicep') --no-restore --outfile $paths.template *> $paths.build
            if ($LASTEXITCODE -ne 0) { throw 'Foundation compilation failed; inspect private build evidence' }
            & (Join-Path $PSScriptRoot '../tests/Test-ExpansionFoundation.ps1') -CompiledTemplatePath $paths.template -BicepExecutable $Compiler *> $paths.validation
            Write-StandardJson $paths.parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$binding.parameters}
        }
        $hashes=@{}; foreach ($key in @('template','parameters')) { $hashes[$key]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
        $whatIf=Invoke-FoundationAz $state (@('deployment','sub','what-if','--no-pretty-print','--result-format','FullResourcePayloads')+$common) 'whatif'
        Assert-FoundationWhatIf $state $binding $manifest.baseline $whatIf
        Assert-FoundationEqual $sources (Get-FoundationSourceHashes)
        Confirm-FoundationIdle $state $binding
        $freshLive=Get-FoundationLive $state $lab $standard $activation $binding
        Assert-FoundationEqual $freshLive $manifest.baseline
        Assert-FoundationEqual $inputs (Get-FoundationInputHashes $state $originalPath)
        foreach ($key in @('template','parameters')) { if ((Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash -cne $hashes[$key]) { throw 'Foundation artifact changed during what-if' } }
        if ((Get-FoundationHash (Read-FoundationJson $paths.state)) -cne $manifestHash) { throw 'Expansion manifest changed during review' }
        if ($SelectedAction -ceq 'Preview') {
            Write-StandardJson $paths.whatif $whatIf
            $hashes.whatif=(Get-FileHash -LiteralPath $paths.whatif -Algorithm SHA256).Hash
            $manifest.review=@{checkedAt=$reviewStartedAt;inputHashes=$inputs;sourceHashes=$sources;artifactHashes=$hashes;baselineHash=(Get-FoundationHash $manifest.baseline);authorization=@{approved=$true;originalSha=$originalSha;scopeHash=$manifest.scopeHash}}
            Assert-FoundationReview $state $binding $manifest $paths $inputs
            Write-StandardJson $paths.state $manifest
            Write-Output 'Foundation Preview confirmed for one hour. Deploy requires explicit ApproveFoundationCreation again.'; return
        }
        Assert-FoundationReview $state $binding $manifest $paths $inputs
        Write-StandardJson $paths.'deploy-whatif' $whatIf
        $manifest.pending=$true; $manifest.submittedAt=[DateTimeOffset]::UtcNow.ToString('o'); $manifest.deploymentId=$binding.root
        Write-StandardJson $paths.state $manifest
        $null=Invoke-FoundationAz $state (@('deployment','sub','create')+$common+@('--no-wait')) 'submit'
        Write-Output 'Foundation intent saved and submitted. Use Status; transport failures also retain pending intent.'
    } catch {
        $failure=@{failedAt=[DateTimeOffset]::UtcNow.ToString('o');action=$SelectedAction;message=$_.Exception.Message;stack=$_.ScriptStackTrace;pendingRetained=$true}
        Write-StandardJson (Assert-ExternalLabPath (Join-Path $state.runDirectory 'expansion-foundation.failure.json')) $failure
        throw
    } finally {
        $lock.Dispose()
        if ((Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash -cne $originalSha) { throw 'Original state SHA changed externally; no restoration attempted' }
    }
}

if ($DefinitionsOnly) { return }
$invocation=@{Path=$StatePath;SelectedAction=$Action;Compiler=$BicepExecutable;Approved=[bool]$ApproveFoundationCreation;ValidatorRevisionApproved=[bool]$ApproveValidatorRevision}
$ErrorActionPreference='Stop'
$timer=[Diagnostics.Stopwatch]::StartNew()
try {
    if (-not $invocation.Path) { throw 'StatePath required' }
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
    foreach ($file in @('Invoke-StandardStage.ps1','Test-StandardPrivate.ps1','Invoke-StandardCosmosNetwork.ps1','Update-LabGatewayPolicy.ps1')) { . (Join-Path $PSScriptRoot $file) -DefinitionsOnly }
    Invoke-ExpansionFoundation @invocation
} catch {
    throw 'Foundation coordinator stopped; no automatic retry or cleanup. Inspect private foundation evidence and reconcile any pending intent.'
} finally { Write-Host "Foundation elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,2))s" }