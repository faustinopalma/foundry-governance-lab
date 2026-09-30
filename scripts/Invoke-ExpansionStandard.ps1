[CmdletBinding()]
param(
    [string]$StatePath,
    [ValidateSet('a-test','b-dev','b-test')][string]$Project,
    [ValidateSet('Preview','Deploy','Status')][string]$Action = 'Preview',
    [string]$BicepExecutable = 'bicep',
    [switch]$ApproveDependencies,
    [switch]$ApproveValidatorRevision,
    [switch]$DefinitionsOnly
)

$dependencyInvocation=@{Path=$StatePath;Selector=$Project;SelectedAction=$Action;Compiler=$BicepExecutable;Approved=[bool]$ApproveDependencies;ValidatorRevisionApproved=[bool]$ApproveValidatorRevision}
$dependencyDefinitions=[bool]$DefinitionsOnly
Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
foreach ($dependencyHelper in @('Invoke-ExpansionFoundation.ps1','Invoke-StandardStage.ps1','Test-StandardPrivate.ps1','Invoke-StandardCosmosNetwork.ps1','Update-LabGatewayPolicy.ps1')) { . (Join-Path $PSScriptRoot $dependencyHelper) -DefinitionsOnly }

function Get-ExpansionStandardPaths([hashtable]$State, [string]$Selector) {
    if ($Selector -cnotin @('a-test','b-dev','b-test')) { throw 'Expansion project selector required' }
    $paths=@{lock=(Assert-ExternalLabPath (Join-Path $State.runDirectory 'expansion-standard.lock'))}
    foreach ($key in @('state','template','parameters','whatif','deploy-whatif','outputs','build','validation','names','computed','failure')) { $paths[$key]=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-standard-$Selector.$key.json") }
    $paths.names=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-standard-$Selector.names.bicepparam")
    $paths.evidence=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-standard-$Selector-evidence")
    return $paths
}

function Invoke-ExpansionStandardAz([hashtable]$State, [string[]]$Arguments, [string]$Label) {
    $context=$State.Clone()
    $context.runDirectory=Assert-ExternalLabPath $State.evidenceDirectory
    $null=[IO.Directory]::CreateDirectory($context.runDirectory)
    return Invoke-LabAz $context $Arguments "exp-standard-$Label"
}

function Get-ExpansionStandardSources {
    $hashes=Get-FoundationSourceHashes
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    foreach ($relative in @('scripts/Invoke-ExpansionStandard.ps1','tests/Test-ExpansionStandard.ps1','tests/Test-ExpansionStandardCoordinator.ps1')) { $hashes[$relative]=(Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash }
    return $hashes
}

function Assert-ExpansionStandardSeal($Manifest, $Output, [hashtable]$Inputs, [hashtable]$Foundation, [string]$OutputHash) {
    if ($Manifest -isnot [hashtable] -or $Output -isnot [hashtable]) { throw 'Sealed foundation receipt required' }
    Assert-FoundationEqual $Manifest.pending $false
    Assert-FoundationEqual $Manifest.verified $true
    Assert-FoundationEqual $Manifest.completedStages @('foundation')
    Assert-FoundationEqual $Manifest.originalSha $Inputs.state
    Assert-FoundationEqual $Manifest.outputHash $OutputHash
    Assert-FoundationEqual $Manifest.scopeHash (Get-FoundationHash $Foundation)
    Assert-FoundationText $Manifest.deploymentId $Foundation.root
    Assert-FoundationEqual $Manifest.review.inputHashes $Inputs
    Assert-FoundationEqual $Manifest.review.authorization.approved $true
    Assert-FoundationEqual $Manifest.review.authorization.originalSha $Inputs.state
    Assert-FoundationEqual $Manifest.review.authorization.scopeHash $Manifest.scopeHash
    if ($Manifest.baseline -isnot [hashtable] -or -not $Manifest.baseline.Count) { throw 'Full original preservation baseline required' }
    Assert-FoundationEqual $Manifest.review.baselineHash (Get-FoundationHash $Manifest.baseline)
    Assert-FoundationEqual $Output.baselineHash $Manifest.review.baselineHash
    Assert-FoundationEqual $Output.originalSha $Inputs.state
    Assert-FoundationEqual $Output.controlPlaneVerified $true
    Assert-FoundationEqual $Output.inferenceVerified $false
    Assert-FoundationEqual $Output.foundation.stage 'foundation-only'
    Assert-FoundationEqual $Output.foundation.completeLab $false
    Assert-FoundationText $Output.foundation.caseBAccountId $Foundation.accountB
    Assert-FoundationText $Output.foundation.resourceGroupId $Foundation.groupB
    Assert-FoundationSet @($Output.foundation.projects | ForEach-Object { $_.resourceId }) $Foundation.projects
    foreach ($projectReceipt in $Output.foundation.projects) { Assert-FoundationGuid $projectReceipt.principalId }
    if ($Output.environmentEvents -isnot [array] -or $Output.validationSourceHashes -isnot [hashtable] -or -not $Output.validationSourceHashes.Count -or $Output.validatorRevision -isnot [hashtable]) { throw 'Foundation validation provenance missing' }
}

function Assert-ExpansionStandardTransition($Manifest, [hashtable]$All, [string]$Selector, [string]$SelectedAction, [bool]$Approved) {
    if ($SelectedAction -cnotin @('Preview','Deploy','Status')) { throw 'Unknown dependencies action' }
    if ($SelectedAction -cne 'Status' -and -not $Approved) { throw 'ApproveDependencies required for Preview and Deploy' }
    $pending=0
    foreach ($key in $All.Keys) {
        $entry=$All[$key]
        if ($key -cnotin @('a-test','b-dev','b-test') -or $entry -isnot [hashtable] -or $entry.project -cne $key -or $entry.pending -isnot [bool] -or $entry.verified -isnot [bool] -or ($entry.pending -and $entry.verified)) { throw 'Invalid dependencies manifest' }
        if ($entry.pending) { $pending++; if ($key -cne $Selector) { throw 'Another expansion dependency is pending' } }
        if (-not $entry.pending -and -not $entry.verified -and ($entry.deploymentId -or $entry.submittedAt)) { throw 'Submission intent cannot be reset or replayed' }
    }
    if ($pending -gt 1) { throw 'Multiple pending dependencies' }
    Assert-FoundationTransition $Manifest $SelectedAction $Approved
}

function Get-ExpansionStandardBinding([hashtable]$State, [hashtable]$Foundation, [hashtable]$Receipt, [string]$Selector, [string]$Compiler, [hashtable]$Paths) {
    Assert-FoundationOriginal $State
    foreach ($key in @('subscriptionId','tenantId','ownershipId')) { Assert-FoundationGuid $State[$key] }
    if ($Selector -cnotin @('a-test','b-dev','b-test')) { throw 'Unknown expansion project' }
    $caseId=$Selector.Substring(0,1); $code=@{'a-test'='at';'b-dev'='bd';'b-test'='bt'}[$Selector]
    $account=if ($caseId -ceq 'a') { $Foundation.accountA } else { $Foundation.accountB }
    $projectId="$account/projects/case-$Selector"
    $selected=@($Receipt.foundation.projects | Where-Object resourceId -IEQ $projectId)
    if ($selected.Count -ne 1) { throw 'Selected project is not in sealed foundation outputs' }
    $principal=$selected[0].principalId; Assert-FoundationGuid $principal
    $prefix="/subscriptions/$($State.subscriptionId)"; $stem="fgl-$($State.labId)"; $group="$prefix/resourceGroups/rg-$stem-case-$caseId"
    $source=@'
using none
var suffix = uniqueString('__PREFIX__', '__LAB__')
var storage = 'stfgx__CODE__${suffix}'
var search = 'srch-__STEM__-exp-__SELECTOR__-${suffix}'
var cosmos = 'cosmos-__STEM__-exp-__CODE__-${suffix}'
param names = {
  suffix: suffix
  storage: storage
  search: search
  cosmos: cosmos
  roles: [
    guid('__GROUP__/providers/Microsoft.Storage/storageAccounts/${storage}', '__PRINCIPAL__', '17d1049b-9a84-46fb-8f53-869881c3d3ab')
    guid('__GROUP__/providers/Microsoft.Search/searchServices/${search}', '__PRINCIPAL__', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
    guid('__GROUP__/providers/Microsoft.Search/searchServices/${search}', '__PRINCIPAL__', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
    guid('__GROUP__/providers/Microsoft.DocumentDB/databaseAccounts/${cosmos}', '__PRINCIPAL__', '230815da-be43-4aae-9cb4-875f7bd000aa')
  ]
  dns: [uniqueString('pe-__STEM__-exp-__SELECTOR__-blob'), uniqueString('pe-__STEM__-exp-__SELECTOR__-search'), uniqueString('pe-__STEM__-exp-__SELECTOR__-cosmos')]
}
'@
    foreach ($replacement in @{PREFIX=$prefix;LAB=$State.labId;CODE=$code;STEM=$stem;SELECTOR=$Selector;GROUP=$group;PRINCIPAL=$principal}.GetEnumerator()) { $source=$source.Replace("__$($replacement.Key)__",$replacement.Value) }
    [IO.File]::WriteAllText($Paths.names,$source)
    & $Compiler build-params $Paths.names --no-restore --outfile $Paths.computed *> $Paths.build
    if ($LASTEXITCODE -ne 0) { throw 'Local Bicep deterministic name evaluation failed' }
    $names=(Read-FoundationJson $Paths.computed).parameters.names.value
    if ($names.suffix -isnot [string] -or $names.suffix -cnotmatch '^[a-z0-9]{13}$') { throw 'Invalid local suffix evaluation' }
    Assert-FoundationText $account "$group/providers/Microsoft.CognitiveServices/accounts/aif-$stem-$caseId-$($names.suffix)"
    $binding=@{project=$Selector;principal=$principal;group=$group;account=$account;projectId=$projectId;name="$stem-exp-standard-$Selector";new=@{};nested=@{};roles=@{};specs=@{};foundationHash=(Get-FoundationHash $Receipt)}
    $binding.root="$prefix/providers/Microsoft.Resources/deployments/$($binding.name)"
    $binding.agentSubnet="$($Foundation.vnet)/subnets/snet-agent-$caseId"
    $binding.parameters=@{labId=@{value=$State.labId};ownershipId=@{value=$State.ownershipId};location=@{value='swedencentral'};projectSelector=@{value=$Selector};projectPrincipalId=@{value=$principal}}
    $output=@{stage='dependencies';completeLab=$false;labId=$State.labId;ownershipId=$State.ownershipId;location='swedencentral';projectSelector=$Selector;resourceGroupName="rg-$stem-case-$caseId";resourceGroupId=$group;integrationResourceGroupName="rg-$stem-integration";accountId=$account;projectId=$projectId;projectPrincipalId=$principal;connections=@{};vnetId=$Foundation.vnet;subnetId="$($Foundation.vnet)/subnets/snet-case-$caseId-pe";privateEndpointIds=@();dnsZoneIds=@{};roleAssignmentIds=@()}
    $tags=@{'fgl-lab'=$State.labId;'fgl-owner'=$State.ownershipId;purpose='synthetic-governance-lab'}
    $serviceSpecs=@(@('storage','Microsoft.Storage/storageAccounts','2023-05-01','blob','blob','privatelink.blob.core.windows.net','AzureStorageAccount'),@('search','Microsoft.Search/searchServices','2025-05-01','search','searchService','privatelink.search.windows.net','CognitiveSearch'),@('cosmos','Microsoft.DocumentDB/databaseAccounts','2024-11-15','cosmos','Sql','privatelink.documents.azure.com','CosmosDb'))
    $index=0
    foreach ($spec in $serviceSpecs) {
        $service=$spec[0]; $name=$names[$service]; $id="$group/providers/$($spec[1])/$name"
        $endpoint= switch ($service) { storage { "https://$name.blob.core.windows.net/" } search { "https://$name.search.windows.net" } cosmos { "https://$name.documents.azure.com:443/" } }
        $output[$service]=@{name=$name;id=$id;endpoint=$endpoint}
        $connectionId="$projectId/connections/$name"; $output.connections[$service]=@{name=$name;id=$connectionId}
        $zone="$($Foundation.integration)/providers/Microsoft.Network/privateDnsZones/$($spec[5])"; $output.dnsZoneIds[$spec[3]]=$zone
        $peName="pe-$stem-exp-$Selector-$($spec[3])"; $peId="$group/providers/Microsoft.Network/privateEndpoints/$peName"; $output.privateEndpointIds+=$peId
        $binding.new[$id]=$service; $binding.new[$connectionId]='connection'; $binding.new[$peId]='endpoint'; $binding.new["$peId/privateDnsZoneGroups/default"]='zoneGroup'
        $binding.specs[$id]=@{api=$spec[2];resource=@{id=$id;type=$spec[1];location='swedencentral';tags=$tags;properties=@{}}}
        $binding.specs[$connectionId]=@{api='2026-05-01';resource=@{id=$connectionId;type='Microsoft.CognitiveServices/accounts/projects/connections';properties=@{category=$spec[6];target=$endpoint;authType='AAD';isSharedToAll=$false;metadata=@{ApiType='Azure';ResourceId=$id;location='swedencentral'}}}}
        $binding.specs[$peId]=@{api='2024-05-01';resource=@{id=$peId;type='Microsoft.Network/privateEndpoints';location='swedencentral';tags=$tags;properties=@{subnet=@{id=$output.subnetId};privateLinkServiceConnections=@(@{name=$peName;properties=@{privateLinkServiceId=$id;groupIds=@($spec[4])}})}}}
        $binding.specs["$peId/privateDnsZoneGroups/default"]=@{api='2024-05-01';resource=@{id="$peId/privateDnsZoneGroups/default";type='Microsoft.Network/privateEndpoints/privateDnsZoneGroups';properties=@{privateDnsZoneConfigs=@(@{properties=@{privateDnsZoneId=$zone}})}}}
        foreach ($nestedName in @("$peName-endpoint",$peName,"$($names.dns[$index])-PrivateEndpoint-PrivateDnsZoneGroup")) { $binding.nested["$group/providers/Microsoft.Resources/deployments/$nestedName"]=$nestedName }
        $index++
    }
    $storage=$binding.specs[$output.storage.id].resource; $storage.kind='StorageV2'; $storage.sku=@{name='Standard_LRS'}
    $storage.properties=@{minimumTlsVersion='TLS1_2';supportsHttpsTrafficOnly=$true;allowBlobPublicAccess=$false;allowSharedKeyAccess=$false;defaultToOAuthAuthentication=$true;allowCrossTenantReplication=$false;publicNetworkAccess='Disabled';networkAcls=@{bypass='None';defaultAction='Deny';ipRules=@();virtualNetworkRules=@()}}
    $search=$binding.specs[$output.search.id].resource; $search.sku=@{name='basic'}; $search.identity=@{type='SystemAssigned'}
    $search.properties=@{disableLocalAuth=$true;publicNetworkAccess='disabled';partitionCount=1;replicaCount=1;hostingMode='Default';semanticSearch='disabled';networkRuleSet=@{bypass='None';ipRules=@()}}
    $cosmos=$binding.specs[$output.cosmos.id].resource; $cosmos.kind='GlobalDocumentDB'
    $cosmos.properties=@{databaseAccountOfferType='Standard';disableLocalAuth=$true;publicNetworkAccess='Disabled';networkAclBypass='None';ipRules=@();virtualNetworkRules=@();enableFreeTier=$false;enableAutomaticFailover=$false;enableMultipleWriteLocations=$false;capacity=@{totalThroughputLimit=5000};consistencyPolicy=@{defaultConsistencyLevel='Session'};locations=@(@{locationName='swedencentral';failoverPriority=0;isZoneRedundant=$false})}
    $roleSpecs=@(@('storage','17d1049b-9a84-46fb-8f53-869881c3d3ab'),@('search','8ebe5a00-799e-43f5-93ac-243d3dce84a7'),@('search','7ca78c08-252a-4471-8644-bb5ff32d4ba0'),@('cosmos','230815da-be43-4aae-9cb4-875f7bd000aa'))
    foreach ($roleIndex in 0..3) {
        Assert-FoundationGuid $names.roles[$roleIndex]
        $scope=$output[$roleSpecs[$roleIndex][0]].id; $id="$scope/providers/Microsoft.Authorization/roleAssignments/$($names.roles[$roleIndex])"
        $properties=@{scope=$scope;principalId=$principal;principalType='ServicePrincipal';roleDefinitionId="$prefix/providers/Microsoft.Authorization/roleDefinitions/$($roleSpecs[$roleIndex][1])"}
        $binding.roles[$id]=$properties; $binding.new[$id]='role'; $output.roleAssignmentIds+=$id
        $binding.specs[$id]=@{api='2022-04-01';resource=@{id=$id;type='Microsoft.Authorization/roleAssignments';properties=$properties}}
    }
    $binding.nested["$group/providers/Microsoft.Resources/deployments/$($binding.name)"]=$binding.name
    $binding.output=$output
    if ($binding.new.Count -ne 16 -or $binding.nested.Count -ne 10) { throw 'Incomplete dependencies binding' }
    return $binding
}

function Assert-ExpansionStandardSubset($Actual, $Expected, [string]$Key = '') {
    if ($Expected -is [Collections.IDictionary]) {
        if ($Actual -isnot [Collections.IDictionary]) { throw "Missing configuration object: $Key" }
        foreach ($field in $Expected.Keys) {
            if (-not $Actual.Contains($field)) { throw "Missing configuration field: $Key/$field" }
            Assert-ExpansionStandardSubset $Actual[$field] $Expected[$field] $field
        }
    } elseif ($Expected -is [array]) {
        if ($Actual -isnot [array] -or $Actual.Count -ne $Expected.Count) { throw "Configuration array mismatch: $Key" }
        for ($index=0; $index -lt $Expected.Count; $index++) { Assert-ExpansionStandardSubset $Actual[$index] $Expected[$index] $Key }
    } elseif ($Key -cin @('id','type','ResourceId','privateLinkServiceId','privateDnsZoneId','scope','roleDefinitionId','principalId')) { Assert-FoundationText $Actual $Expected }
    else { Assert-FoundationEqual $Actual $Expected }
}

function Assert-ExpansionStandardResource([hashtable]$State, [hashtable]$Binding, $Resource, [string]$Id, [switch]$Live) {
    if (-not $Binding.new.ContainsKey($Id) -or $Resource -isnot [hashtable]) { throw 'Unexpected dependencies resource' }
    $kind=$Binding.new[$Id]; $actual=Read-ExpansionStandardCopy $Resource; $expected=Read-ExpansionStandardCopy $Binding.specs[$Id].resource
    if ($Live -and $kind -cin @('cosmos','search')) {
        if ($actual.location -is [string] -and $actual.location -ieq 'Sweden Central') { $actual.location='swedencentral' }
    }
    if ($Live -and $kind -ceq 'search' -and $actual.properties.publicNetworkAccess -is [string] -and $actual.properties.publicNetworkAccess -ieq 'Disabled') { $actual.properties.publicNetworkAccess='disabled' }
    if ($Live -and $kind -ceq 'cosmos') {
        foreach ($region in $actual.properties.locations) {
            if ($region.locationName -is [string] -and $region.locationName -ieq 'Sweden Central') { $region.locationName='swedencentral' }
        }
    }
    if (-not $Live) {
        foreach ($aclName in @('networkAcls','networkRuleSet')) {
            if ($expected.properties[$aclName] -is [hashtable] -and $actual.properties[$aclName] -is [hashtable]) {
                foreach ($field in @('ipRules','virtualNetworkRules')) { if ($expected.properties[$aclName].ContainsKey($field) -and -not $actual.properties[$aclName].ContainsKey($field)) { $actual.properties[$aclName][$field]=@() } }
            }
        }
        if ($kind -ceq 'cosmos') { foreach ($field in @('ipRules','virtualNetworkRules')) { if (-not $actual.properties.ContainsKey($field)) { $actual.properties[$field]=@() } } }
        if ($kind -ceq 'role') { foreach ($field in @('principalType','scope')) { if (-not $actual.properties.ContainsKey($field)) { $expected.properties.Remove($field) } } }
    }
    Assert-ExpansionStandardSubset $actual $expected
    foreach ($aclName in @('networkAcls','networkRuleSet')) {
        if ($expected.properties[$aclName] -is [hashtable]) {
            foreach ($field in @('resourceAccessRules','trustedServiceAccessEnabled')) { if ($actual.properties[$aclName][$field]) { throw 'Unexpected network access exception' } }
        }
    }
    if ($kind -cin @('storage','search','cosmos','endpoint')) { Assert-FoundationOwned $State $Resource $Id }
    if ($Live -and $kind -cin @('storage','search','cosmos','endpoint','zoneGroup')) { Assert-FoundationText $Resource.properties.provisioningState 'Succeeded' }
    if ($kind -ceq 'search' -and $Live) { Assert-FoundationGuid $Resource.identity.principalId; Assert-FoundationText $Resource.identity.tenantId $State.tenantId }
    if ($kind -ceq 'cosmos' -and @($Resource.properties.capabilities).Where({$null -ne $_}).Count) { throw 'Unexpected Cosmos capability' }
    foreach ($field in @('credentials','apiKey','key','connectionString','networkAclBypassResourceIds','allowedFqdnList','manualPrivateLinkServiceConnections','condition','conditionVersion','delegatedManagedIdentityResourceId')) { if ($Resource.properties[$field]) { throw "Forbidden configuration: $field" } }
    if ($kind -ceq 'endpoint' -and $Live) { Assert-FoundationEqual $Resource.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status 'Approved' }
}

function Read-ExpansionStandardCopy($Value) { return ,(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100) -AsHashtable -Depth 100 -NoEnumerate) }

function Assert-ExpansionStandardWhatIf([hashtable]$State, [hashtable]$Binding, [hashtable]$Known, $Result) {
    if ($Result -isnot [hashtable] -or $Result.status -cne 'Succeeded' -or $Result.changes -isnot [array] -or -not $Result.changes.Count) { throw 'Expanded successful FullResourcePayloads what-if required' }
    $seen=@{}; $created=@{}
    foreach ($change in $Result.changes) {
        $id=$change.resourceId
        if ($id -isnot [string] -or $seen.ContainsKey($id)) { throw 'Invalid or repeated what-if ID' }; $seen[$id]=$true
        if ($change.changeType -ceq 'Ignore') {
            if ($change.before -isnot [hashtable] -or $change.after -isnot [hashtable] -or $change.before.id -ine $id -or $change.after.id -ine $id -or @($change.delta).Where({$null -ne $_}).Count) { throw 'Ignore requires identical before and after' }
            if (-not $Known.ContainsKey($id)) {
                $generated=$change.before.type
                if ($generated -inotin @('Microsoft.Network/networkInterfaces','Microsoft.EventGrid/systemTopics') -or @($Known.Keys | Where-Object { $_ -match '/resourceGroups/[^/]+$' -and $id.StartsWith("$_/providers/$generated/",[StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { throw 'Ignore outside known resources and owned generated resources' }
            }
            Assert-FoundationEqual $change.before $change.after
            continue
        }
        if ($change.changeType -cne 'Create' -or $change.before -or $change.after -isnot [hashtable]) { throw 'Only exact new Creates allowed' }
        if ($Binding.nested.ContainsKey($id)) {
            Assert-FoundationText $change.after.id $id; Assert-FoundationText $change.after.type 'Microsoft.Resources/deployments'; Assert-FoundationEqual $change.after.properties.mode 'Incremental'
        } else { Assert-ExpansionStandardResource $State $Binding $change.after $id; $created[$id]=$true }
    }
    Assert-FoundationSet @($created.Keys) @($Binding.new.Keys)
}

function Assert-ExpansionStandardGroups([hashtable]$State, [hashtable]$Foundation, [array]$Groups) {
    $expected=@($State.resourceGroups | ForEach-Object { "/subscriptions/$($State.subscriptionId)/resourceGroups/$_" })+@($Foundation.groupB)
    foreach ($id in $expected) {
        $name=($id -split '/')[-1]
        $matched=@($Groups | Where-Object { $_.id -ieq $id -or $_.name -ieq $name })
        if ($matched.Count -ne 1 -or $matched[0].name -cne $name) { throw 'Exact four-group coverage missing or ambiguous' }
        Assert-FoundationOwned $State $matched[0] $id
        Assert-FoundationEqual $matched[0].location 'swedencentral'
        Assert-FoundationEqual $matched[0].properties.provisioningState 'Succeeded'
        if ($id -iin $State.preexistingGroupIds) { throw 'Preexisting group cannot be adopted' }
    }
}

function Get-ExpansionStandardLive([hashtable]$State, [hashtable]$Lab, [hashtable]$Standard, [hashtable]$Activation, [hashtable]$Foundation, [hashtable]$Seal, [hashtable]$Binding, [switch]$After) {
    $baseline=Get-FoundationLive $State $Lab $Standard $Activation $Foundation -After
    Assert-FoundationEqual $baseline $Seal.manifest.baseline
    $groups=@(Read-FoundationArm $State "$($Foundation.subscription)/resourceGroups" '2025-04-01' -List)
    Assert-ExpansionStandardGroups $State $Foundation $groups
    Confirm-FoundationOutputs $State $Foundation $Seal.output.foundation
    $known=$baseline.Clone()
    foreach ($id in $Foundation.new.Keys) { $known[$id]=@{id=$id} }
    $account=Read-FoundationArm $State $Binding.account '2026-05-01'
    $projectResource=Read-FoundationArm $State $Binding.projectId '2026-05-01'
    foreach ($resource in @($account,$projectResource)) {
        Assert-FoundationOwned $State $resource $resource.id
        Assert-FoundationEqual $resource.location 'swedencentral'
        Assert-FoundationEqual $resource.properties.provisioningState 'Succeeded'
        Assert-FoundationEqual $resource.identity.type 'SystemAssigned'
        Assert-FoundationGuid $resource.identity.principalId
        Assert-FoundationText $resource.identity.tenantId $State.tenantId
        if ($resource.identity.userAssignedIdentities) { throw 'Unexpected user-assigned identity' }
    }
    Assert-FoundationText $projectResource.identity.principalId $Binding.principal
    Assert-FoundationEqual $account.properties.publicNetworkAccess 'Disabled'
    Assert-FoundationEqual $account.properties.disableLocalAuth $true
    Assert-FoundationEqual $account.properties.networkInjections @(@{scenario='agent';subnetArmId=$Binding.agentSubnet;useMicrosoftManagedNetwork=$false})
    if ($projectResource.properties.ContainsKey('publicNetworkAccess')) { Assert-FoundationEqual $projectResource.properties.publicNetworkAccess 'Disabled' }
    $peSubnet=Read-FoundationArm $State $Binding.output.subnetId '2024-05-01'
    Assert-FoundationEqual $peSubnet.properties.privateEndpointNetworkPolicies 'NetworkSecurityGroupEnabled'
    Assert-FoundationText $peSubnet.properties.networkSecurityGroup.id "$($Foundation.integration)/providers/Microsoft.Network/networkSecurityGroups/nsg-$($Foundation.stem)-endpoints"
    $agentSubnet=Read-FoundationArm $State $Binding.agentSubnet '2024-05-01'
    if ($agentSubnet.properties.delegations -isnot [array] -or $agentSubnet.properties.delegations.Count -ne 1) { throw 'Exactly one agent delegation required' }
    Assert-FoundationEqual $agentSubnet.properties.delegations[0].properties.serviceName 'Microsoft.App/environments'
    foreach ($zone in $Binding.output.dnsZoneIds.Values) {
        $zoneResource=Read-FoundationArm $State $zone '2024-06-01'; Assert-FoundationOwned $State $zoneResource $zone
        $zoneLinks=@(Read-FoundationArm $State "$zone/virtualNetworkLinks" '2024-06-01' -List)
        $linkName=if ($zone -ilike '*/privatelink.blob.core.windows.net') { 'lab-only' } else { 'standard-lab-only' }
        Assert-FoundationSet @($zoneLinks | ForEach-Object { $_.id }) @("$zone/virtualNetworkLinks/$linkName")
        Assert-FoundationOwned $State $zoneLinks[0] "$zone/virtualNetworkLinks/$linkName"
        Assert-FoundationText $zoneLinks[0].properties.virtualNetwork.id $Foundation.vnet
        Assert-FoundationEqual $zoneLinks[0].properties.registrationEnabled $false
        Assert-FoundationEqual $zoneLinks[0].properties.provisioningState 'Succeeded'
        $known[$zone]=Select-FoundationConfiguration $zoneResource; $known[$zoneLinks[0].id]=Select-FoundationConfiguration $zoneLinks[0]
    }
    $inventory=@{}
    foreach ($groupId in @($State.resourceGroups | ForEach-Object { "$($Foundation.subscription)/resourceGroups/$_" })+@($Foundation.groupB)) {
        $resources=@(Read-FoundationArm $State "$groupId/resources" '2021-04-01' -List)
        foreach ($resource in $resources) {
            if (-not $resource.id.StartsWith("$groupId/providers/",[StringComparison]::OrdinalIgnoreCase)) { throw 'Resource inventory escaped the group' }
            $inventory[$resource.id]=$resource
        }
    }
    foreach ($connection in @(Read-FoundationArm $State "$($Binding.projectId)/connections" '2026-05-01' -List)) { $inventory[$connection.id]=$connection }
    foreach ($role in @(Read-FoundationArm $State "$($Foundation.subscription)/providers/Microsoft.Authorization/roleAssignments" '2022-04-01' -List)) {
        if ($role.id.StartsWith("$($Binding.group)/providers/",[StringComparison]::OrdinalIgnoreCase)) { $inventory[$role.id]=$role }
    }
    if (-not $After) { foreach ($id in $Binding.new.Keys) { if ($inventory.ContainsKey($id)) { throw 'Selected dependency already exists; no adoption' } } }
    foreach ($id in $inventory.Keys) { if (-not $Binding.new.ContainsKey($id)) { $known[$id]=$inventory[$id] } }
    return $known
}

function Assert-ExpansionStandardOperations([hashtable]$Binding, [string]$DeploymentId, [array]$Operations, [hashtable]$Writes) {
    if (-not $Operations.Count) { throw 'Deployment operations coverage missing' }
    foreach ($operation in $Operations) {
        $properties=$operation.properties; $target=$properties.targetResource
        if ($properties.provisioningState -cne 'Succeeded') { throw 'Nonterminal or failed dependencies operation' }
        if ($properties.provisioningOperation -ceq 'EvaluateDeploymentOutput' -and -not $target) { continue }
        if ($target.id -isnot [string]) { throw 'Operation target missing' }
        if ($properties.provisioningOperation -ceq 'Read') {
            if ($Binding.nested.ContainsKey($target.id)) {
                Assert-FoundationText $target.resourceType 'Microsoft.Resources/deployments'
                continue
            }
            if ($target.id -iin @($Binding.account,$Binding.projectId) -or $Binding.new.ContainsKey($target.id)) { continue }
            throw 'Unknown read operation target'
        }
        if ($properties.provisioningOperation -cne 'Create') { throw 'Unexpected write or delete operation' }
        if ($DeploymentId -ieq $Binding.root) {
            if ($target.id -ine "$($Binding.group)/providers/Microsoft.Resources/deployments/$($Binding.name)") { throw 'Root operation escaped selected module' }
        } elseif (-not $Binding.new.ContainsKey($target.id) -and -not $Binding.nested.ContainsKey($target.id)) { throw 'Nested operation escaped exact dependencies envelope' }
        $expectedType=if ($Binding.nested.ContainsKey($target.id)) { 'Microsoft.Resources/deployments' } else { $Binding.specs[$target.id].resource.type }
        Assert-FoundationText $target.resourceType $expectedType
        $Writes[$target.id]=$true
    }
}

function Assert-ExpansionStandardHistoricalAlert([hashtable]$Foundation, [hashtable]$Seal, [hashtable]$Child, [array]$Operations, [string]$Scope = $Foundation.integration) {
    if ($Scope -inotin @($Foundation.integration,$Foundation.groupA)) { throw 'Historical alert scope is outside the original groups' }
    $component=if ($Scope -ieq $Foundation.integration) { 'integration' } else { 'case-a' }
    $prefix="$Scope/providers/Microsoft.Resources/deployments/"
    $insights="$Scope/providers/Microsoft.Insights/components/appi-$($Foundation.stem)-$component"
    $targetId="$Scope/providers/Microsoft.AlertsManagement/smartDetectorAlertRules/Failure Anomalies - appi-$($Foundation.stem)-$component"
    $created=[DateTimeOffset]::MinValue
    if (-not $Seal.manifest.baseline.ContainsKey($insights) -or $Child.name -cnotmatch '^Failure-Anomalies-Alert-Rule-Deployment-[0-9a-f]{8}$' -or $Child.id -ine "$prefix$($Child.name)" -or $Child.properties.mode -cne 'Incremental' -or $Child.properties.provisioningState -cne 'Failed' -or @($Child.properties.outputResources).Where({$null -ne $_}).Count -or -not [DateTimeOffset]::TryParse([string]$Child.properties.timestamp,[ref]$created) -or $created -ge [DateTimeOffset]::Parse($Seal.output.verifiedAt)) { throw 'Historical integration alert requires effect review' }
    $targets=0
    foreach ($operation in $Operations) {
        $properties=$operation.properties
        if ($properties.provisioningState -cne 'Failed') { throw 'Historical alert operation has possible successful effects' }
        if ($properties.provisioningOperation -ceq 'EvaluateDeploymentOutput' -and -not $properties.targetResource) { continue }
        if ($properties.provisioningOperation -cne 'Create' -or $properties.targetResource.id -ine $targetId -or $properties.targetResource.resourceType -ine 'Microsoft.AlertsManagement/smartDetectorAlertRules') { throw 'Historical alert target is outside the sealed integration component' }
        $targets++
    }
    if ($targets -ne 1) { throw 'Exactly one failed historical alert resource operation required' }
    return @{deploymentId=$Child.id;kind='automatic-alert';state='Failed';targetId=$targetId;deploymentHash=(Get-FoundationHash $Child);operationsHash=(Get-FoundationHash $Operations)}
}

function Get-ExpansionStandardIdle([hashtable]$State, [hashtable]$Foundation, [hashtable]$Binding, [hashtable]$Seal, [hashtable]$All, [switch]$Submitted) {
    $scopes=@($Foundation.subscription)+@($State.resourceGroups | ForEach-Object { "$($Foundation.subscription)/resourceGroups/$_" })+@($Foundation.groupB)
    $inventories=@{}; $deployments=@{}
    foreach ($scope in $scopes) {
        $inventories[$scope]=@(Read-FoundationArm $State "$scope/providers/Microsoft.Resources/deployments" '2022-09-01' -List)
        foreach ($child in $inventories[$scope]) {
            if ($child.name -isnot [string] -or $child.id -ine "$scope/providers/Microsoft.Resources/deployments/$($child.name)" -or $deployments.ContainsKey($child.id)) { throw 'Malformed or duplicate deployment inventory entry' }
            $deployments[$child.id]=$child
        }
    }
    $knownDeployments=@{}; $queue=[Collections.Generic.Queue[string]]::new()
    foreach ($id in @((Get-FoundationRootIds $State))+@($Foundation.root)) { $queue.Enqueue($id) }
    foreach ($entry in $All.Values) {
        if ($entry.verified -and $entry.project -cne $Binding.project) {
            Assert-FoundationEqual $entry.originalSha $Seal.manifest.originalSha
            Assert-FoundationEqual $entry.foundationOutputHash $Seal.manifest.outputHash
            if ($entry.deploymentId -ine "$($Foundation.subscription)/providers/Microsoft.Resources/deployments/$($Foundation.stem)-exp-standard-$($entry.project)") { throw 'Other project root is unbound' }
            $queue.Enqueue($entry.deploymentId)
        }
    }
    while ($queue.Count) {
        $id=$queue.Dequeue(); if ($knownDeployments.ContainsKey($id)) { continue }
        if ($knownDeployments.Count -gt 300) { throw 'Deployment graph exceeds bounded lab envelope' }
        if (-not $deployments.ContainsKey($id)) { throw 'Expected deployment absent from complete inventory' }
        $deployment=$deployments[$id]
        if ($deployment.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Existing deployment is active' }
        if ($id -ieq $Foundation.root -or $id -iin @($State.standard.deploymentNames.Values | ForEach-Object { "$($Foundation.subscription)/providers/Microsoft.Resources/deployments/$_" })) { Assert-FoundationEqual $deployment.properties.provisioningState 'Succeeded' }
        $knownDeployments[$id]=@{state=$deployment.properties.provisioningState;mode=$deployment.properties.mode}
        foreach ($operation in @(Read-FoundationArm $State "$id/operations" '2022-09-01' -List)) {
            if ($operation.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Existing nested operation is active' }
            $target=$operation.properties.targetResource
            if ($target.resourceType -ieq 'Microsoft.Resources/deployments') {
                if ($target.id -isnot [string] -or @(@($State.resourceGroups | ForEach-Object { "$($Foundation.subscription)/resourceGroups/$_/providers/Microsoft.Resources/deployments/" })+@("$($Foundation.groupB)/providers/Microsoft.Resources/deployments/") | Where-Object { $target.id.StartsWith($_,[StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { throw 'Existing nested deployment escaped owned groups' }
                $queue.Enqueue($target.id)
            }
        }
    }
    $events=@(); $seen=@{}; $writes=@{}
    foreach ($scope in $scopes) {
        foreach ($child in $inventories[$scope]) {
            if ($scope -ieq $Foundation.subscription -and $child.id -ine $Binding.root -and -not $knownDeployments.ContainsKey($child.id)) {
                if ($child.name -like "$($Foundation.stem)*") { throw 'Unknown lab subscription deployment' }; continue
            }
            if ($child.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Deployment inventory contains active work' }
            if ($child.id -ieq $Binding.root -or $Binding.nested.ContainsKey($child.id)) {
                if (-not $Submitted) { throw 'Dependency deployment already exists; no replay' }
                $full=$child
                Assert-FoundationEqual $full.properties.mode 'Incremental'; Assert-FoundationEqual $full.properties.provisioningState 'Succeeded'
                Assert-ExpansionStandardOperations $Binding $child.id @(Read-FoundationArm $State "$($child.id)/operations" '2022-09-01' -List) $writes
                $seen[$child.id]=$true
            } elseif (-not $knownDeployments.ContainsKey($child.id)) {
                if ($scope -ieq $Foundation.integration -or ($scope -ieq $Foundation.groupA -and $child.name -cmatch '^Failure-Anomalies-Alert-Rule-Deployment-[0-9a-f]{8}$')) {
                    $full=$child
                    $event=Assert-ExpansionStandardHistoricalAlert $Foundation $Seal $full @(Read-FoundationArm $State "$($child.id)/operations" '2022-09-01' -List) $scope
                    $targets=@(Read-FoundationArm $State "$scope/resources" '2021-04-01' -List)
                    if (@($targets | Where-Object id -IEQ $event.targetId).Count) { throw 'Historical integration alert has effects' }
                    $event.targetAbsent=$true; $events+=$event
                    continue
                }
                $externalBinding=$Foundation
                $modelsGroup="$($Foundation.subscription)/resourceGroups/rg-$($Foundation.stem)-models"
                if ($scope -ieq $Foundation.groupA -or $scope -ieq $modelsGroup) {
                    $created=[DateTimeOffset]::MinValue
                    if (-not [DateTimeOffset]::TryParse([string]$child.properties.timestamp,[ref]$created) -or $created -ge [DateTimeOffset]::Parse($Seal.output.verifiedAt)) { throw 'Unknown new external deployment in an original group' }
                    $externalBinding=$Foundation.Clone(); $externalBinding.groupB=$scope; $externalBinding.accountB=$Foundation.accountA
                    if ($scope -ieq $modelsGroup) {
                        $accounts=@($Seal.manifest.baseline.Keys | Where-Object { $_ -imatch ('^'+[regex]::Escape("$modelsGroup/providers/Microsoft.CognitiveServices/accounts/")+'[^/]+$') })
                        if ($accounts.Count -ne 1 -or $child.name -cnotmatch '^PolicyDeployment_[0-9]+$') { throw 'Historical model diagnostics requires one sealed account' }
                        $externalBinding.accountB=$accounts[0]
                    }
                    $externalBinding.diagnostic="$($externalBinding.accountB)/providers/Microsoft.Insights/diagnosticSettings/metrics-only"
                } elseif ($scope -ine $Foundation.groupB) { throw 'Unknown deployment outside reviewed foundation case groups' }
                $full=$child
                $event=Assert-FoundationEnvironmentDeployment $externalBinding $full @(Read-FoundationArm $State "$($child.id)/operations" '2022-09-01' -List)
                $targets=@(Read-FoundationArm $State "$scope/resources" '2021-04-01' -List)+@(Read-FoundationArm $State "$($externalBinding.accountB)/providers/Microsoft.Insights/diagnosticSettings" '2021-05-01-preview' -List)
                if (@($targets | Where-Object id -IEQ $event.targetId).Count) { throw 'External failed deployment has effects' }
                $event.targetAbsent=$true; $events+=$event
            }
        }
    }
    if ($Submitted) {
        Assert-FoundationSet @($seen.Keys) (@($Binding.nested.Keys)+@($Binding.root))
        Assert-FoundationSet @($writes.Keys) (@($Binding.nested.Keys)+@($Binding.new.Keys))
    }
    return @{deployments=$knownDeployments;environmentEvents=@($events | Sort-Object deploymentId)}
}

function Assert-ExpansionStandardValidatorRevision([hashtable]$Original, [hashtable]$Current, [string]$RunDirectory, [string]$Selector) {
    if ($Selector -cnotin @('a-test','b-dev','b-test')) { throw 'Validator revision requires an exact project selector' }
    Assert-FoundationSet @($Current.Keys) @($Original.Keys)
    $allowed=@('scripts/Invoke-ExpansionStandard.ps1','tests/Test-ExpansionStandardCoordinator.ps1')
    $changed=@{}
    foreach ($key in $Original.Keys) {
        if ($Current[$key] -ceq $Original[$key]) { continue }
        if ($key -cnotin $allowed) { throw 'Only the dependency validator and its test may change during reconciliation' }
        $archive=Assert-ExternalLabPath (Join-Path (Join-Path $RunDirectory "standard-$Selector-validator-submitted") $key)
        if (-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $Original[$key]) { throw 'Submitted dependency validator archive missing or changed' }
        $changed[$key]=@{submitted=$Original[$key];current=$Current[$key]}
    }
    if (-not $changed.Count) { throw 'No dependency validator revision to approve' }
    return $changed
}

function Assert-ExpansionStandardReview([hashtable]$State, [hashtable]$Binding, [hashtable]$Manifest, [hashtable]$Paths, [hashtable]$Inputs, [hashtable]$Seal, [switch]$Submitted, [switch]$ValidatorRevisionApproved) {
    Assert-FoundationEqual $Manifest.originalSha $Inputs.state
    Assert-FoundationEqual $Manifest.foundationOutputHash $Seal.manifest.outputHash
    Assert-FoundationEqual $Manifest.scopeHash (Get-FoundationHash $Binding)
    Assert-FoundationEqual $Manifest.project $Binding.project
    $review=$Manifest.review
    if ($review -isnot [hashtable]) { throw 'Dependencies Preview required' }
    Assert-FoundationEqual $review.approved $true
    Assert-FoundationEqual $review.inputHashes $Inputs
    $currentSources=Get-ExpansionStandardSources
    if ($Submitted -and $ValidatorRevisionApproved) { $null=Assert-ExpansionStandardValidatorRevision $review.sourceHashes $currentSources $State.runDirectory $Binding.project }
    else { Assert-FoundationEqual $review.sourceHashes $currentSources }
    Assert-FoundationEqual $review.baselineHash (Get-FoundationHash $Manifest.baseline)
    Assert-FoundationEqual $Manifest.baseline $Seal.manifest.baseline
    Assert-FoundationEqual $review.knownHash (Get-FoundationHash $Manifest.known)
    Assert-FoundationEqual $review.idleHash (Get-FoundationHash $Manifest.idle)
    $age=[DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$review.checkedAt)
    if ($age -lt [TimeSpan]::Zero -or (-not $Submitted -and $age -gt [TimeSpan]::FromHours(1))) { throw 'Dependencies Preview expired or future dated' }
    foreach ($key in @('template','parameters','whatif')) { Assert-FoundationEqual (Get-FileHash -LiteralPath $Paths[$key] -Algorithm SHA256).Hash $review.artifactHashes[$key] }
    Assert-FoundationEqual (Read-FoundationJson $Paths.parameters) @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$Binding.parameters}
    Assert-ExpansionStandardWhatIf $State $Binding $Manifest.known (Read-FoundationJson $Paths.whatif)
    if ($Submitted) { Assert-FoundationText $Manifest.deploymentId $Binding.root }
}

function Confirm-ExpansionStandardResources([hashtable]$State, [hashtable]$Binding, $Output) {
    Assert-ExpansionStandardSubset $Output $Binding.output
    Assert-FoundationSet @($Output.Keys) @($Binding.output.Keys)
    foreach ($id in $Binding.new.Keys) { Assert-ExpansionStandardResource $State $Binding (Read-FoundationArm $State $id $Binding.specs[$id].api) $id -Live }
    foreach ($service in @('storage','search','cosmos')) {
        $scope=$Binding.output[$service].id
        $roles=@(Read-FoundationArm $State "$scope/providers/Microsoft.Authorization/roleAssignments" '2022-04-01' -List -Query '&$filter=atScope()')
        $direct=@($roles | Where-Object { $_.id.StartsWith("$scope/providers/Microsoft.Authorization/roleAssignments/",[StringComparison]::OrdinalIgnoreCase) })
        Assert-FoundationSet @($direct | ForEach-Object { $_.id }) @($Binding.roles.Keys | Where-Object { $Binding.roles[$_].scope -ieq $scope })
        foreach ($role in $direct) { Assert-ExpansionStandardResource $State $Binding $role $role.id -Live }
    }
}

function Invoke-ExpansionStandard([string]$Path, [string]$Selector, [string]$SelectedAction, [string]$Compiler, [bool]$Approved, [bool]$ValidatorRevisionApproved = $false) {
    if ($ValidatorRevisionApproved -and $SelectedAction -cne 'Status') { throw 'Dependency validator revision is read-only Status only' }
    if (-not $Path -or $Selector -cnotin @('a-test','b-dev','b-test')) { throw 'Original StatePath and expansion Project required' }
    $originalPath=Assert-ExternalLabPath $Path
    $originalSha=(Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
    $lock=$null
    try {
        $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
        $paths=Get-ExpansionStandardPaths $state $Selector
        $lock=[IO.File]::Open($paths.lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
        $state.evidenceDirectory=$paths.evidence
        function Invoke-FoundationAz([hashtable]$State, [string[]]$Arguments, [string]$Label) { Invoke-ExpansionStandardAz $State $Arguments $Label }
        $inputs=Get-FoundationInputHashes $state $originalPath; Assert-FoundationEqual $inputs.state $originalSha
        $all=@{}
        foreach ($selection in @('a-test','b-dev','b-test')) { $otherPaths=Get-ExpansionStandardPaths $state $selection; if (Test-Path -LiteralPath $otherPaths.state) { $all[$selection]=Read-FoundationJson $otherPaths.state } }
        $manifest=$all[$Selector]
        Assert-ExpansionStandardTransition $manifest $all $Selector $SelectedAction $Approved
        $lab=Read-FoundationJson (Join-Path $state.runDirectory 'outputs.json'); $standard=Read-FoundationJson (Join-Path $state.runDirectory 'standard-outputs.json'); $activation=Read-FoundationJson (Join-Path $state.runDirectory 'activate.parameters.json')
        $foundation=Get-FoundationBinding $state $lab $Compiler
        $foundationPaths=Get-FoundationPaths $state
        $seal=@{manifest=(Read-FoundationJson $foundationPaths.state);output=(Read-FoundationJson $foundationPaths.outputs)}
        $sealHashes=@{state=(Get-FileHash -LiteralPath $foundationPaths.state -Algorithm SHA256).Hash;outputs=(Get-FileHash -LiteralPath $foundationPaths.outputs -Algorithm SHA256).Hash}
        Assert-ExpansionStandardSeal $seal.manifest $seal.output $inputs $foundation $sealHashes.outputs
        $binding=Get-ExpansionStandardBinding $state $foundation $seal.output $Selector $Compiler $paths
        $sources=Get-ExpansionStandardSources
        $startedAt=[DateTimeOffset]::UtcNow.ToString('o')
        $common=@('--name',$binding.name,'--location','swedencentral','--template-file',$paths.template,'--parameters',"@$($paths.parameters)")
        function Assert-DependencyUnchanged {
            Assert-FoundationEqual (Get-FoundationInputHashes $state $originalPath) $inputs
            Assert-FoundationEqual (Get-ExpansionStandardSources) $sources
            foreach ($key in $sealHashes.Keys) { Assert-FoundationEqual (Get-FileHash -LiteralPath $foundationPaths[$key] -Algorithm SHA256).Hash $sealHashes[$key] }
        }
        if ($SelectedAction -ceq 'Status') {
            Assert-ExpansionStandardReview $state $binding $manifest $paths $inputs $seal -Submitted -ValidatorRevisionApproved:$ValidatorRevisionApproved
            Assert-LabContext $state (Invoke-ExpansionStandardAz $state @('account','show') 'context')
            $deployment=Read-FoundationArm $state $binding.root '2022-09-01'
            Assert-FoundationEqual $deployment.properties.mode 'Incremental'
            Assert-FoundationSet @($deployment.properties.parameters.Keys) @($binding.parameters.Keys)
            foreach ($key in $binding.parameters.Keys) { Assert-FoundationEqual $deployment.properties.parameters[$key].value $binding.parameters[$key].value }
            if ($deployment.properties.provisioningState -cne 'Succeeded') { throw 'Dependencies not Succeeded; pending intent retained. No retry or cleanup.' }
            $before=Get-ExpansionStandardLive $state $lab $standard $activation $foundation $seal $binding -After
            $idle=Get-ExpansionStandardIdle $state $foundation $binding $seal $all -Submitted
            Assert-FoundationEqual $idle.deployments $manifest.idle.deployments
            Confirm-ExpansionStandardResources $state $binding $deployment.properties.outputs.standard.value
            $after=Get-ExpansionStandardLive $state $lab $standard $activation $foundation $seal $binding -After
            Assert-FoundationEqual $before $after
            Assert-FoundationEqual (Get-ExpansionStandardIdle $state $foundation $binding $seal $all -Submitted) $idle
            Assert-DependencyUnchanged
            Assert-ExpansionStandardReview $state $binding $manifest $paths $inputs $seal -Submitted -ValidatorRevisionApproved:$ValidatorRevisionApproved
            $revision=@{}
            if ($ValidatorRevisionApproved) { $revision=Assert-ExpansionStandardValidatorRevision $manifest.review.sourceHashes $sources $state.runDirectory $Selector }
            $output=@{standard=$deployment.properties.outputs.standard.value;controlPlaneVerified=$true;inferenceVerified=$false;dnsTlsVerified=$false;completeLab=$false;originalSha=$originalSha;foundationOutputHash=$sealHashes.outputs;verifiedAt=[DateTimeOffset]::UtcNow.ToString('o');environmentEvents=$idle.environmentEvents;validationSourceHashes=$sources;validatorRevision=$revision}
            Write-StandardJson $paths.outputs $output
            $manifest.outputHash=(Get-FileHash -LiteralPath $paths.outputs -Algorithm SHA256).Hash; $manifest.pending=$false; $manifest.verified=$true
            Write-StandardJson $paths.state $manifest
            Write-Output 'Dependencies control plane verified. Original Minimal state and foundation seal preserved. DNS/TLS, inference, hosts and full lab are not verified.'
            return
        }
        $manifestHash=if ($manifest) { Get-FoundationHash $manifest } else { $null }
        if ($SelectedAction -ceq 'Deploy') { Assert-ExpansionStandardReview $state $binding $manifest $paths $inputs $seal }
        $known=Get-ExpansionStandardLive $state $lab $standard $activation $foundation $seal $binding
        $idle=Get-ExpansionStandardIdle $state $foundation $binding $seal $all
        if ($manifest -and $SelectedAction -ceq 'Deploy') { Assert-FoundationEqual $known $manifest.known; Assert-FoundationEqual $idle $manifest.idle }
        $compilePath=if ($SelectedAction -ceq 'Preview') { $paths.template } else { Join-Path $paths.evidence 'fresh-template.json' }
        $null=[IO.Directory]::CreateDirectory($paths.evidence)
        & $Compiler build (Join-Path $PSScriptRoot '../infra/expansion-standard.bicep') --no-restore --outfile $compilePath *> $paths.build
        if ($LASTEXITCODE -ne 0) { throw 'Offline dependencies compilation failed' }
        & (Join-Path $PSScriptRoot '../tests/Test-ExpansionStandard.ps1') -BicepExecutable $Compiler *> $paths.validation
        if ($SelectedAction -ceq 'Deploy') { Assert-FoundationEqual (Get-FileHash -LiteralPath $compilePath -Algorithm SHA256).Hash $manifest.review.artifactHashes.template }
        else { Write-StandardJson $paths.parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$binding.parameters} }
        $artifactHashes=@{}; foreach ($key in @('template','parameters')) { $artifactHashes[$key]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
        $whatif=Invoke-ExpansionStandardAz $state (@('deployment','sub','what-if','--no-pretty-print','--result-format','FullResourcePayloads')+$common) 'whatif'
        Assert-ExpansionStandardWhatIf $state $binding $known $whatif
        Assert-FoundationEqual (Get-ExpansionStandardLive $state $lab $standard $activation $foundation $seal $binding) $known
        Assert-FoundationEqual (Get-ExpansionStandardIdle $state $foundation $binding $seal $all) $idle
        Assert-DependencyUnchanged
        foreach ($key in @('template','parameters')) { Assert-FoundationEqual (Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash $artifactHashes[$key] }
        if ($manifestHash) { Assert-FoundationEqual (Get-FoundationHash (Read-FoundationJson $paths.state)) $manifestHash }
        elseif (Test-Path -LiteralPath $paths.state) { throw 'Dependencies manifest appeared during review' }
        if ($SelectedAction -ceq 'Preview') {
            Write-StandardJson $paths.whatif $whatif; $artifactHashes.whatif=(Get-FileHash -LiteralPath $paths.whatif -Algorithm SHA256).Hash
            $manifest=@{version=1;stage='dependencies';project=$Selector;originalSha=$originalSha;foundationOutputHash=$sealHashes.outputs;scopeHash=(Get-FoundationHash $binding);baseline=$seal.manifest.baseline;known=$known;idle=$idle;pending=$false;verified=$false;review=@{approved=$true;checkedAt=$startedAt;sourceHashes=$sources;inputHashes=$inputs;artifactHashes=$artifactHashes;baselineHash=(Get-FoundationHash $seal.manifest.baseline);knownHash=(Get-FoundationHash $known);idleHash=(Get-FoundationHash $idle)}}
            Assert-ExpansionStandardReview $state $binding $manifest $paths $inputs $seal
            Write-StandardJson $paths.state $manifest
            Write-Output 'Dependencies Preview sealed for one hour. Deploy requires ApproveDependencies again.'; return
        }
        Assert-ExpansionStandardReview $state $binding $manifest $paths $inputs $seal
        Write-StandardJson $paths.'deploy-whatif' $whatif
        $manifest.pending=$true; $manifest.submittedAt=[DateTimeOffset]::UtcNow.ToString('o'); $manifest.deploymentId=$binding.root
        Write-StandardJson $paths.state $manifest
        $null=Invoke-ExpansionStandardAz $state (@('deployment','sub','create')+$common+@('--no-wait')) 'submit'
        Write-Output 'Dependencies intent persisted and submitted. Use Status; submission transport failure also retains intent.'
    } finally {
        if ($lock) { $lock.Dispose() }
        if ((Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash -cne $originalSha) { throw 'Original state SHA changed; no restoration or cleanup attempted' }
    }
}

if ($dependencyDefinitions) { return }
$ErrorActionPreference='Stop'
$dependencyTimer=[Diagnostics.Stopwatch]::StartNew()
try { Invoke-ExpansionStandard @dependencyInvocation } finally { $dependencyTimer.Stop(); Write-Host ('Dependencies elapsed: {0:N3}s' -f $dependencyTimer.Elapsed.TotalSeconds) }