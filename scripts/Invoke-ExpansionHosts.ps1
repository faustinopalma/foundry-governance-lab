[CmdletBinding()]
param(
    [string]$StatePath,
    [ValidateSet('a-test','b-dev','b-test')][string]$Project,
    [ValidateSet('account','project')][string]$Stage,
    [ValidateSet('Preview','Deploy','Status')][string]$Action = 'Preview',
    [string]$Compiler = 'bicep',
    [switch]$ApproveHosts,
    [switch]$DefinitionsOnly
)

$hostsInvocation=@{Path=$StatePath;Selector=$Project;SelectedStage=$Stage;SelectedAction=$Action;Compiler=$Compiler;Approved=[bool]$ApproveHosts}
$hostsDefinitions=[bool]$DefinitionsOnly
. (Join-Path $PSScriptRoot 'Invoke-ExpansionCosmosNetwork.ps1') -DefinitionsOnly
. (Join-Path $PSScriptRoot 'ExpansionArmReadSession.ps1')

function Get-ExpansionHostPaths([hashtable]$State, [string]$Selector, [string]$SelectedStage) {
    if ($Selector -cnotin @('a-test','b-dev','b-test') -or $SelectedStage -cnotin @('account','project')) { throw 'Exact host selector and stage required' }
    $key=if ($SelectedStage -ceq 'account') { 'account-'+$Selector.Substring(0,1) } else { "project-$Selector" }
    $paths=@{key=$key;lock=(Assert-ExternalLabPath (Join-Path $State.runDirectory 'expansion-standard.lock'))}
    foreach ($name in @('state','outputs','template','parameters','whatif')) { $paths[$name]=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-host-$key.$name.json") }
    $paths.evidence=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-host-$key-evidence")
    return $paths
}

function Get-ExpansionHostSources {
    $hashes=Get-ExpansionNetworkSources
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    foreach ($relative in @('scripts/Invoke-ExpansionHosts.ps1','tests/Test-ExpansionHosts.ps1','scripts/ExpansionArmReadSession.ps1','tests/Test-ExpansionArmReadSession.ps1')) { $hashes[$relative]=(Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash }
    return $hashes
}

function ConvertTo-ExpansionHostGuid($Value) {
    $parsed=[guid]::Empty
    if ($Value -isnot [string] -or -not ([guid]::TryParseExact($Value,'D',[ref]$parsed) -or [guid]::TryParseExact($Value,'N',[ref]$parsed)) -or $parsed -eq [guid]::Empty) { throw 'Project internalId must be a nonzero D or N GUID' }
    return $parsed.ToString('D')
}

function Get-ExpansionHostBinding([hashtable]$State, [hashtable]$Prerequisites, [string]$Selector, [string]$SelectedStage) {
    $paths=Get-ExpansionHostPaths $State $Selector $SelectedStage
    if ($SelectedStage -ceq 'account' -and $Selector -ceq 'b-test') { $Selector='b-dev' }
    $foundation=$Prerequisites.network.foundation
    $dependency=$Prerequisites.network.outputs[$Selector].standard
    $caseId=$Selector.Substring(0,1)
    $account=if ($caseId -ceq 'a') { $foundation.accountA } else { $foundation.accountB }
    $group="$($foundation.subscription)/resourceGroups/rg-fgl-$($State.labId)-case-$caseId"
    if ($account -isnot [string] -or $account -inotmatch ('^'+[regex]::Escape("$group/providers/Microsoft.CognitiveServices/accounts/aif-fgl-$($State.labId)-$caseId-")+'[a-z0-9]{13}$')) { throw 'Account escaped owned case scope' }
    Assert-FoundationText $dependency.accountId $account
    Assert-FoundationText $dependency.projectId "$account/projects/case-$Selector"
    Assert-FoundationText $dependency.resourceGroupId $group
    Assert-FoundationGuid $dependency.projectPrincipalId
    $parameters=@{accountName=@{value=($account -split '/')[-1]}}
    $binding=@{key=$paths.key;stage=$SelectedStage;selector=$Selector;case=$caseId;accountId=$account;group=$group;subnet="$($foundation.vnet)/subnets/snet-agent-$caseId";parameters=$parameters;hostId="$account/capabilityHosts/agents";type='Microsoft.CognitiveServices/accounts/capabilityHosts'}
    if ($SelectedStage -ceq 'project') {
        $binding.projectId=$dependency.projectId
        $binding.principalId=$dependency.projectPrincipalId
        $binding.hostId="$($dependency.projectId)/capabilityHosts/agents"
        $binding.type='Microsoft.CognitiveServices/accounts/projects/capabilityHosts'
        $parameters.projectName=@{value="case-$Selector"}
        foreach ($service in @('storage','search','cosmos')) {
            $connection=$dependency.connections[$service]
            if ($connection.name -isnot [string] -or $connection.name -cnotmatch '^[a-zA-Z0-9_.-]+$') { throw 'Connection name required, not a resource ID' }
            Assert-FoundationText $connection.id "$($dependency.projectId)/connections/$($connection.name)"
            Assert-FoundationEqual $connection.name $dependency[$service].name
            $parameters["${service}Name"]=@{value=$connection.name}
        }
    }
    $binding.root="$group/providers/Microsoft.Resources/deployments/fgl-$($State.labId)-exp-host-$($paths.key)"
    return $binding
}

function Assert-ExpansionHostResource([hashtable]$Binding, $Resource, [string]$ExpectedId, [switch]$Live) {
    if ($Resource -isnot [hashtable] -or $Resource.properties -isnot [hashtable]) { throw 'Host object required' }
    Assert-FoundationText $Resource.id $ExpectedId
    Assert-FoundationText $Resource.type $Binding.type
    if ($Live) { Assert-FoundationEqual $Resource.properties.provisioningState 'Succeeded' }
    if ($Binding.stage -ceq 'account') {
        Assert-FoundationEqual $Resource.properties.capabilityHostKind 'Agents'
        if ($Live) {
            $subnet=$Resource.properties.customerSubnet
            if ($subnet -is [hashtable]) { $subnet=$subnet.id }
            Assert-FoundationText $subnet $Binding.subnet
        }
    } else {
        foreach ($pair in @(@('storageConnections','storageName'),@('vectorStoreConnections','searchName'),@('threadStorageConnections','cosmosName'))) {
            Assert-FoundationEqual $Resource.properties[$pair[0]] @($Binding.parameters[$pair[1]].value)
        }
        if ($Resource.properties.ContainsKey('capabilityHostKind')) { Assert-FoundationEqual $Resource.properties.capabilityHostKind 'Agents' }
    }
    if ($Resource.properties.enablePublicHostingEnvironment) { throw 'Public hosting is forbidden' }
}

function Get-ExpansionAccountHostDecision([hashtable]$State, [hashtable]$Binding, [array]$Hosts, [hashtable]$Baseline, $OwnManifest) {
    if ($Hosts.Count -gt 1) { throw 'Ambiguous account host inventory' }
    if (-not $Hosts.Count) {
        if ($Binding.case -ceq 'a' -or ($OwnManifest -and ($OwnManifest.pending -or $OwnManifest.verified))) { throw 'Recorded account host missing; never recreate' }
        return @{mode='Create';id=$Binding.hostId}
    }
    $resource=$Hosts[0]
    Assert-ExpansionHostResource $Binding $resource $resource.id -Live
    $implicit="$($Binding.accountId)/capabilityHosts/$($Binding.parameters.accountName.value)@aml_aiagentservice"
    if ($Binding.case -ceq 'a') {
        Assert-FoundationText $resource.id $State.standard.accountHostId
        if (-not $Baseline.ContainsKey($resource.id)) { throw 'A host must already be in the original baseline' }
        Assert-FoundationEqual (Select-FoundationConfiguration $resource) $Baseline[$resource.id]
        if ($resource.id -ine $implicit -and ($resource.id -ine $Binding.hostId -or -not $State.standard.deploymentNames.ContainsKey('account'))) { throw 'A explicit host has no original deployment record' }
    } elseif ($resource.id -ine $implicit) {
        if ($resource.id -ine $Binding.hostId -or -not $OwnManifest -or (-not $OwnManifest.pending -and -not $OwnManifest.verified) -or $OwnManifest.mode -cne 'Create') { throw 'B explicit host requires its own persisted Create intent' }
        Assert-FoundationEqual $OwnManifest.binding $Binding
    }
    return @{mode='Reuse';id=$resource.id}
}

function Assert-ExpansionHostConnections([hashtable]$State, [hashtable]$Dependency, $Account, $ProjectResource, [array]$Connections) {
    Assert-FoundationOwned $State $Account $Dependency.accountId
    Assert-FoundationOwned $State $ProjectResource $Dependency.projectId
    foreach ($resource in @($Account,$ProjectResource)) {
        Assert-FoundationEqual $resource.properties.provisioningState 'Succeeded'
        Assert-FoundationEqual $resource.identity.type 'SystemAssigned'
        Assert-FoundationText $resource.identity.tenantId $State.tenantId
        Assert-FoundationGuid $resource.identity.principalId
        if ($resource.identity.userAssignedIdentities) { throw 'Unexpected user-assigned identity' }
    }
    Assert-FoundationText $Account.properties.publicNetworkAccess 'Disabled'
    Assert-FoundationEqual $Account.properties.disableLocalAuth $true
    Assert-FoundationText $ProjectResource.identity.principalId $Dependency.projectPrincipalId
    if ($ProjectResource.properties.ContainsKey('publicNetworkAccess')) { Assert-FoundationText $ProjectResource.properties.publicNetworkAccess 'Disabled' }
    $internalId=ConvertTo-ExpansionHostGuid $ProjectResource.properties.internalId
    Assert-FoundationSet @($Connections | ForEach-Object { $_.id }) @($Dependency.connections.Values | ForEach-Object { $_.id })
    foreach ($pair in @(@('storage','AzureStorageAccount','Microsoft.Storage/storageAccounts','blob.core.windows.net/'),@('search','CognitiveSearch','Microsoft.Search/searchServices','search.windows.net'),@('cosmos','CosmosDb','Microsoft.DocumentDB/databaseAccounts','documents.azure.com:443/'))) {
        $service=$pair[0]; $record=$Dependency[$service]; $connection=$Dependency.connections[$service]
        Assert-FoundationText $record.id "$($Dependency.resourceGroupId)/providers/$($pair[2])/$($record.name)"
        Assert-FoundationEqual $record.endpoint "https://$($record.name).$($pair[3])"
        Assert-FoundationEqual $connection.name $record.name
        Assert-FoundationText $connection.id "$($Dependency.projectId)/connections/$($connection.name)"
        $actual=@($Connections | Where-Object id -IEQ $connection.id)[0]
        Assert-FoundationText $actual.type 'Microsoft.CognitiveServices/accounts/projects/connections'
        Assert-ExpansionStandardSubset $actual.properties @{category=$pair[1];authType='AAD';target=$record.endpoint;isSharedToAll=$false;metadata=@{ApiType='Azure';ResourceId=$record.id;location='swedencentral'}}
        foreach ($field in @('credentials','apiKey','key','connectionString','managedIdentity')) { if ($actual.properties[$field]) { throw 'Unexpected connection credential or identity override' } }
    }
    return $internalId
}

function Assert-ExpansionHostBaseline([hashtable]$Baseline, [hashtable]$Original, [hashtable]$Cosmos, [hashtable]$LiveRules) {
    Assert-FoundationSet @($Cosmos.Keys) @('a-test','b-dev','b-test')
    $copy=Read-ExpansionStandardCopy $Baseline
    foreach ($selection in @('a-test','b-dev','b-test')) {
        $binding=$Cosmos[$selection].binding
        Assert-FoundationEqual $Cosmos[$selection].verified $true
        Assert-FoundationEqual $Cosmos[$selection].pending $false
        Assert-FoundationEqual $binding.selector $selection
        Assert-ExpansionCosmosNetworkRule $LiveRules[$selection] $binding -Succeeded
        $nsg=$binding.names.nsgId; $id=$binding.names.ruleId
        if (-not $copy.ContainsKey($nsg)) { throw 'Protected endpoint NSG missing' }
        $matching=@($copy[$nsg].properties.securityRules | Where-Object id -IEQ $id)
        if ($matching.Count -ne 1) { throw 'Validated Cosmos rule missing from full snapshot' }
        $projected=Select-FoundationConfiguration @{id=$nsg;type='Microsoft.Network/networkSecurityGroups';properties=@{securityRules=@($LiveRules[$selection])}}
        Assert-FoundationEqual $matching[0] $projected.properties.securityRules[0]
        $copy[$nsg].properties.securityRules=@($copy[$nsg].properties.securityRules | Where-Object id -INE $id)
    }
    Assert-FoundationEqual $copy $Original
}

function Get-ExpansionHostPrerequisites([hashtable]$State, [string]$OriginalPath) {
    $cosmos=@{}; $receipts=@{}; $files=@{}
    foreach ($selection in @('a-test','b-dev','b-test')) {
        $paths=Get-ExpansionNetworkPaths $State $selection
        $cosmos[$selection]=Read-FoundationJson $paths.state
        $receipts[$selection]=Read-FoundationJson $paths.outputs
        foreach ($key in @('state','outputs')) { $files[$paths[$key]]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
        Assert-FoundationEqual $cosmos[$selection].project $selection
        Assert-ExpansionNetworkReceipt $cosmos[$selection] $receipts[$selection] $files[$paths.outputs]
    }
    $foundation=$cosmos['a-test'].foundationBinding
    if ($foundation -isnot [hashtable] -or -not $foundation.Count) { throw 'Verified Cosmos foundation binding required; no compiler fallback' }
    $network=Get-ExpansionNetworkPrerequisites $State $OriginalPath '' $foundation
    $sources=Get-ExpansionNetworkSources
    foreach ($selection in $cosmos.Keys) {
        $manifest=$cosmos[$selection]
        Assert-ExpansionNetworkReview $manifest (Get-ExpansionNetworkPaths $State $selection) $network $sources -Submitted
        $submitted=[DateTimeOffset]::Parse([string]$manifest.submittedAt)
        if ($submitted -gt [DateTimeOffset]::UtcNow -or $submitted -lt [DateTimeOffset]::Parse([string]$manifest.review.checkedAt)) { throw 'Invalid Cosmos submission time' }
        foreach ($key in @('source','template','parameters','whatif')) {
            $file=(Get-ExpansionNetworkPaths $State $selection)[$key]
            $files[$file]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        }
    }
    foreach ($file in $network.files.Keys) { $files[$file]=$network.files[$file] }
    return @{network=$network;cosmos=$cosmos;receipts=$receipts;files=$files;networkSources=$sources}
}

function Assert-ExpansionHostInputs([hashtable]$State, [string]$OriginalPath, [hashtable]$Prerequisites, [hashtable]$Sources) {
    Assert-ExpansionNetworkInputs $State $OriginalPath $Prerequisites.network $Prerequisites.networkSources
    Assert-FoundationEqual (Get-ExpansionHostSources) $Sources
    foreach ($file in $Prerequisites.files.Keys) { Assert-FoundationEqual (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash $Prerequisites.files[$file] }
}

function Assert-ExpansionHostTransition([hashtable]$All, [string]$Key, [string]$SelectedAction, [bool]$Approved) {
    if ($Key -cnotin @('account-a','account-b','project-a-test','project-b-dev','project-b-test') -or $SelectedAction -cnotin @('Preview','Deploy','Status')) { throw 'Invalid host operation' }
    foreach ($other in $All.Keys) {
        $entry=$All[$other]
        if ($other -cnotin @('account-a','account-b','project-a-test','project-b-dev','project-b-test') -or $entry -isnot [hashtable]) { throw 'Unexpected host manifest' }
        Assert-FoundationEqual $entry.key $other
        Assert-FoundationEqual $entry.stage 'hosts'
        if ($entry.pending -isnot [bool] -or $entry.verified -isnot [bool] -or ($entry.pending -and $entry.verified)) { throw 'Invalid host intent flags' }
        if ($entry.pending -and $other -cne $Key) { throw 'Another host operation is pending' }
        if (-not $entry.pending -and -not $entry.verified -and ($entry.submittedAt -or $entry.deploymentId -or $entry.outputHash)) { throw 'Host intent cannot be reset' }
        if ($entry.verified -and ($entry.outputHash -isnot [string] -or $entry.outputHash -cnotmatch '^[A-F0-9]{64}$')) { throw 'Verified host output hash required' }
        if (-not $entry.verified -and $entry.ContainsKey('outputHash')) { throw 'Unverified host cannot have an output seal' }
    }
    Assert-FoundationTransition $All[$Key] $SelectedAction $Approved
}

function Get-ExpansionHostIntentHash([hashtable]$Manifest) {
    $intent=$Manifest.Clone(); $intent.pending=$true; $intent.verified=$false; $intent.Remove('outputHash')
    return Get-FoundationHash $intent
}

function Assert-ExpansionHostReceipt([hashtable]$Manifest, $Output, [string]$Hash) {
    Assert-FoundationEqual $Manifest.pending $false
    Assert-FoundationEqual $Manifest.verified $true
    if ($Hash -cnotmatch '^[A-F0-9]{64}$') { throw 'Host receipt hash required' }
    Assert-FoundationEqual $Manifest.outputHash $Hash
    Assert-CosmosNetworkKeys $Output @('stage','key','hostId','mode','controlPlaneVerified','runtimeVerified','inferenceVerified','completeLab','azureReadOnly','submissionWrites','verifiedAt','deploymentId','deploymentProof','hostHash','inputHashes','sourceHashes','intentHash')
    Assert-FoundationEqual $Output.stage 'hosts'
    foreach ($key in @('key','hostId','mode','deploymentId')) { Assert-FoundationEqual $Output[$key] $Manifest[$key] }
    foreach ($key in @('controlPlaneVerified','azureReadOnly')) { Assert-FoundationEqual $Output[$key] $true }
    foreach ($key in @('runtimeVerified','inferenceVerified','completeLab')) { Assert-FoundationEqual $Output[$key] $false }
    Assert-FoundationEqual $Output.inputHashes $Manifest.review.fileHashes
    Assert-FoundationEqual $Output.sourceHashes $Manifest.review.sourceHashes
    Assert-FoundationEqual $Output.intentHash (Get-ExpansionHostIntentHash $Manifest)
    if ($Output.hostHash -isnot [string] -or $Output.hostHash -cnotmatch '^[A-F0-9]{64}$') { throw 'Verified host configuration hash required' }
    if ($Manifest.mode -ceq 'Reuse') {
        Assert-FoundationEqual $Output.submissionWrites 0
        Assert-FoundationEqual $Output.deploymentProof @{}
        Assert-FoundationEqual $Manifest.deploymentId $null
    } elseif ($Manifest.mode -ceq 'Create') {
        Assert-FoundationEqual $Output.submissionWrites 1
        Assert-FoundationEqual $Manifest.deploymentId $Manifest.binding.root
        Assert-CosmosNetworkKeys $Output.deploymentProof @('deploymentHash','operationsHash')
        foreach ($value in $Output.deploymentProof.Values) { if ($value -isnot [string] -or $value -cnotmatch '^[A-F0-9]{64}$') { throw 'Deployment proof hashes required' } }
    } else { throw 'Invalid host receipt mode' }
    $verified=[DateTimeOffset]::Parse([string]$Output.verifiedAt)
    $submitted=[DateTimeOffset]::Parse([string]$Manifest.submittedAt)
    if ($verified -gt [DateTimeOffset]::UtcNow -or $verified -lt $submitted -or $submitted -lt [DateTimeOffset]::Parse([string]$Manifest.review.checkedAt)) { throw 'Invalid host receipt time' }
}

function Assert-ExpansionHostDeployment([hashtable]$Manifest, $Deployment, [array]$Operations) {
    $binding=$Manifest.binding; $root=$binding.root
    Assert-FoundationEqual $Manifest.mode 'Create'
    Assert-FoundationText $Manifest.deploymentId $root
    Assert-FoundationText $Deployment.id $root
    Assert-FoundationEqual $Deployment.name (($root -split '/')[-1])
    Assert-FoundationEqual $Deployment.properties.provisioningState 'Succeeded'
    Assert-FoundationEqual $Deployment.properties.mode 'Incremental'
    Assert-FoundationSet @($Deployment.properties.parameters.Keys) @($binding.parameters.Keys)
    foreach ($key in $binding.parameters.Keys) { Assert-FoundationEqual $Deployment.properties.parameters[$key].value $binding.parameters[$key].value }
    Assert-FoundationEqual $Deployment.properties.outputs @{resourceId=@{type='String';value=$binding.hostId}}
    if ($Deployment.properties.outputResources -isnot [array] -or $Deployment.properties.outputResources.Count -ne 1) { throw 'Exactly one host output resource required' }
    Assert-FoundationText $Deployment.properties.outputResources[0].id $binding.hostId
    $seen=@{}; $writes=0
    foreach ($operation in $Operations) {
        if ($operation.id -isnot [string] -or -not $operation.id.StartsWith("$root/operations/",[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($operation.id)) { throw 'Unbound or duplicate host operation' }
        $seen[$operation.id]=$true; $properties=$operation.properties
        Assert-FoundationEqual $properties.provisioningState 'Succeeded'
        if ($properties.provisioningOperation -ceq 'EvaluateDeploymentOutput' -and -not $properties.targetResource) { continue }
        Assert-FoundationEqual $properties.provisioningOperation 'Create'
        Assert-FoundationText $properties.targetResource.id $binding.hostId
        Assert-FoundationText $properties.targetResource.resourceType $binding.type
        $writes++
    }
    if ($writes -ne 1) { throw 'Exactly one successful immutable host Create required' }
}

function Get-ExpansionHostIdle([hashtable]$State, [hashtable]$Prerequisites, [hashtable]$All, [hashtable]$Receipts) {
    $hostRoots=@{}; $hostProof=@{}; $hostSeen=@{}
    $hostArmReader=(Get-Command Read-ExpansionNetworkArm).ScriptBlock
    foreach ($manifest in $All.Values) {
        if (($manifest.pending -or $manifest.verified) -and $manifest.mode -ceq 'Create') {
            $root=$manifest.binding.root
            if ($hostRoots.ContainsKey($root)) { throw 'Duplicate host deployment intent' }
            $deployment=& $hostArmReader $State $root '2022-09-01'
            $operations=@(& $hostArmReader $State "$root/operations" '2022-09-01' -List)
            Assert-ExpansionHostDeployment $manifest $deployment $operations
            $hostRoots[$root]=$deployment
            $hostProof[$root]=@{deploymentHash=(Get-FoundationHash $deployment);operationsHash=(Get-FoundationHash $operations)}
            if ($manifest.verified) { Assert-FoundationEqual $hostProof[$root] $Receipts[$manifest.key].deploymentProof }
        }
    }
    function Read-ExpansionNetworkArm([hashtable]$State, [string]$Id, [string]$Api, [switch]$List) {
        $result=& $hostArmReader $State $Id $Api -List:$List
        if ($List -and $Id.EndsWith('/providers/Microsoft.Resources/deployments',[StringComparison]::OrdinalIgnoreCase)) {
            foreach ($item in @($result)) {
                if ($hostRoots.ContainsKey($item.id)) {
                    Assert-FoundationText $item.id "$Id/$($item.name)"
                    Assert-FoundationEqual $item $hostRoots[$item.id]
                    if ($hostSeen.ContainsKey($item.id)) { throw 'Duplicate receipted host root in complete inventory' }
                    $hostSeen[$item.id]=$true
                }
                else { $item }
            }
        } else { return $result }
    }
    $graph=Get-ExpansionNetworkIdle $State $Prerequisites.network $Prerequisites.cosmos 'a-test' -Submitted -Receipts $Prerequisites.receipts
    Assert-FoundationSet @($hostSeen.Keys) @($hostRoots.Keys)
    foreach ($manifest in $Prerequisites.cosmos.Values) {
        foreach ($root in $manifest.idle.Keys) { Assert-FoundationEqual $graph[$root] $manifest.idle[$root] }
    }
    foreach ($root in $hostProof.Keys) { if ($graph.ContainsKey($root)) { throw 'Host root overlaps protected graph' }; $graph[$root]=$hostProof[$root] }
    return $graph
}

function Assert-ExpansionHostInventory([hashtable]$Known, [hashtable]$Inventory, [array]$Scopes) {
    foreach ($id in $Known.Keys) {
        foreach ($scope in $Scopes) {
            $prefix='^'+[regex]::Escape("$scope/providers/")
            if ($id -imatch ($prefix+'[^/]+/[^/]+/[^/]+$') -or $id -imatch ($prefix+'Microsoft.Compute/virtualMachines/[^/]+/extensions/[^/]+$')) {
                if (-not $Inventory.ContainsKey($id)) { throw 'Known resource missing from complete owned-group inventory' }
                Assert-FoundationText $Inventory[$id].type $Known[$id].type
            }
        }
    }
    foreach ($id in $Inventory.Keys) {
        if (-not $Known.ContainsKey($id) -or @($Scopes | Where-Object { $id.StartsWith("$_/providers/",[StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { throw 'Unknown inventory resource or foreign scope' }
    }
}

function Assert-ExpansionHostStorageTopic([hashtable]$Outputs, [hashtable]$Resource, [string]$Scope) {
    Assert-FoundationText $Resource.type 'Microsoft.EventGrid/systemTopics'
    Assert-FoundationText $Resource.location 'swedencentral'
    Assert-FoundationEqual $Resource.properties.provisioningState 'Succeeded'
    Assert-FoundationText $Resource.properties.topicType 'Microsoft.Storage.StorageAccounts'
    if ($Resource.identity) { throw 'Generated storage topic identity is not approved' }
    $matches=@($Outputs.Keys | Where-Object { $Outputs[$_].standard.storage.id -ieq $Resource.properties.source -and $Outputs[$_].standard.resourceGroupId -ieq $Scope })
    if ($matches.Count -ne 1) { throw 'Generated topic must belong to exactly one bound expansion Storage account' }
    $storage=$Outputs[$matches[0]].standard.storage
    $pattern='^'+[regex]::Escape("$Scope/providers/Microsoft.EventGrid/systemTopics/$($storage.name)-")+'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
    if ($Resource.id -inotmatch $pattern) { throw 'Generated topic name or scope mismatch' }
    Assert-FoundationGuid $Matches[1]
    Assert-FoundationText $Resource.name (($Resource.id -split '/')[-1])
    return $storage.id
}

function Get-ExpansionHostLive([hashtable]$State, [hashtable]$Prerequisites, [hashtable]$All, [hashtable]$Receipts) {
    $network=$Prerequisites.network; $foundation=$network.foundation
    Assert-LabContext $State (Invoke-ExpansionNetworkAz $State @('account','show'))
    $baseline=Get-FoundationLive $State $network.lab (Read-FoundationJson (Join-Path $State.runDirectory 'standard-outputs.json')) (Read-FoundationJson (Join-Path $State.runDirectory 'activate.parameters.json')) $foundation -After
    $rules=@{}
    foreach ($selection in $Prerequisites.cosmos.Keys) { $rules[$selection]=Read-ExpansionNetworkArm $State $Prerequisites.cosmos[$selection].binding.names.ruleId '2024-05-01' }
    Assert-ExpansionHostBaseline $baseline $network.seal.manifest.baseline $Prerequisites.cosmos $rules
    $protected=@{}; $known=@{}; $hosts=@{}; $decisions=@{}; $internalIds=@{}
    foreach ($dependency in $network.dependencies.Values) { foreach ($id in $dependency.known.Keys) { $known[$id]=$dependency.known[$id] } }
    $apiByKind=@{group='2025-04-01';account='2026-05-01';project='2026-05-01';workspace='2023-09-01';insights='2020-02-02';endpoint='2024-05-01';zoneGroup='2024-05-01';diagnostic='2021-05-01-preview';role='2022-04-01';link='2021-07-01-preview'}
    foreach ($id in $foundation.new.Keys) {
        $kind=$foundation.new[$id]
        if (-not $apiByKind.ContainsKey($kind)) { throw 'Unknown foundation resource kind' }
        $resource=Read-ExpansionNetworkArm $State $id $apiByKind[$kind]
        Assert-FoundationNewResource $State $foundation $resource $id -Live
        $known[$id]=$resource
        if ($kind -ceq 'diagnostic') { $protected[$id]=@{id=$resource.id;type=$resource.type;properties=$resource.properties} }
        else { $protected[$id]=Select-FoundationConfiguration $resource }
        if ($kind -ceq 'endpoint') {
            foreach ($nic in $resource.properties.networkInterfaces) {
                if ($nic.id -isnot [string] -or $nic.id -inotmatch ('^'+[regex]::Escape("$($foundation.groupB)/providers/Microsoft.Network/networkInterfaces/")+'[A-Za-z0-9_.-]+$')) { throw 'Foreign foundation endpoint NIC' }
                $known[$nic.id]=Read-ExpansionNetworkArm $State $nic.id '2024-05-01'
            }
        }
    }
    foreach ($caseId in @('a','b')) {
        $selector=if ($caseId -ceq 'a') { 'a-test' } else { 'b-dev' }
        $binding=Get-ExpansionHostBinding $State $Prerequisites $selector 'account'
        $account=Read-ExpansionNetworkArm $State $binding.accountId '2026-05-01'
        Assert-FoundationEqual $account.properties.networkInjections @(@{scenario='agent';subnetArmId=$binding.subnet;useMicrosoftManagedNetwork=$false})
        $accountHosts=@(Read-ExpansionNetworkArm $State "$($binding.accountId)/capabilityHosts" '2026-05-01' -List)
        $decisions[$binding.key]=Get-ExpansionAccountHostDecision $State $binding $accountHosts $baseline $All[$binding.key]
        foreach ($resource in $accountHosts) { $hosts[$resource.id]=Select-FoundationConfiguration $resource; $known[$resource.id]=$resource }
    }
    foreach ($selection in @('a-test','b-dev','b-test')) {
        $dependency=$network.outputs[$selection].standard
        $binding=Get-ExpansionHostBinding $State $Prerequisites $selection 'project'
        $account=Read-ExpansionNetworkArm $State $dependency.accountId '2026-05-01'
        $projectResource=Read-ExpansionNetworkArm $State $dependency.projectId '2026-05-01'
        $connections=@(Read-ExpansionNetworkArm $State "$($dependency.projectId)/connections" '2026-05-01' -List)
        $internalIds[$selection]=Assert-ExpansionHostConnections $State $dependency $account $projectResource $connections
        foreach ($resource in @($account,$projectResource)) { $protected[$resource.id]=Select-FoundationConfiguration $resource; $known[$resource.id]=$resource }
        $protected[$dependency.projectId].properties.internalId=$internalIds[$selection]
        foreach ($connection in $connections) { $protected[$connection.id]=@{id=$connection.id;type=$connection.type;properties=$connection.properties}; $known[$connection.id]=$connection }
        foreach ($pair in @(@('storage','2023-05-01'),@('search','2025-05-01'),@('cosmos','2024-11-15'))) {
            $resource=Read-ExpansionNetworkArm $State $dependency[$pair[0]].id $pair[1]
            Assert-FoundationOwned $State $resource $dependency[$pair[0]].id
            Assert-FoundationText $resource.properties.provisioningState 'Succeeded'
            Assert-FoundationText $resource.properties.publicNetworkAccess 'Disabled'
            if ($pair[0] -ceq 'storage') { Assert-FoundationEqual $resource.properties.allowSharedKeyAccess $false; Assert-FoundationEqual $resource.properties.allowBlobPublicAccess $false }
            else { Assert-FoundationEqual $resource.properties.disableLocalAuth $true }
            $protected[$resource.id]=Select-FoundationConfiguration $resource; $known[$resource.id]=$resource
        }
        foreach ($endpointId in $dependency.privateEndpointIds) {
            $endpoint=Read-ExpansionNetworkArm $State $endpointId '2024-05-01'
            Assert-FoundationOwned $State $endpoint $endpointId
            Assert-FoundationEqual $endpoint.properties.provisioningState 'Succeeded'
            $protected[$endpointId]=Select-FoundationConfiguration $endpoint; $known[$endpointId]=$endpoint
            foreach ($nic in $endpoint.properties.networkInterfaces) {
                if ($nic.id -isnot [string] -or $nic.id -inotmatch ('^'+[regex]::Escape("$($dependency.resourceGroupId)/providers/Microsoft.Network/networkInterfaces/")+'[A-Za-z0-9_.-]+$')) { throw 'Foreign dependency endpoint NIC' }
                $known[$nic.id]=Read-ExpansionNetworkArm $State $nic.id '2024-05-01'
            }
        }
        $projectHosts=@(Read-ExpansionNetworkArm $State "$($dependency.projectId)/capabilityHosts" '2026-05-01' -List)
        $manifest=$All[$binding.key]
        if ($manifest -and ($manifest.pending -or $manifest.verified)) {
            if ($projectHosts.Count -ne 1) { throw 'Submitted project requires exactly one host' }
            Assert-ExpansionHostResource $binding $projectHosts[0] $binding.hostId -Live
        } elseif ($projectHosts.Count) { throw 'Unreceipted project host appeared; no adoption or update' }
        foreach ($resource in $projectHosts) { $hosts[$resource.id]=Select-FoundationConfiguration $resource; $known[$resource.id]=$resource }
    }
    foreach ($manifest in $All.Values) {
        if ($manifest.pending -or $manifest.verified) {
            if (-not $hosts.ContainsKey($manifest.hostId)) { throw 'Receipted host missing' }
            if ($manifest.verified) { Assert-FoundationEqual (Get-FoundationHash $hosts[$manifest.hostId]) $Receipts[$manifest.key].hostHash }
        }
    }
    $inventory=@{}; $generatedTopicSources=@{}
    $scopes=@($State.resourceGroups | ForEach-Object { "$($foundation.subscription)/resourceGroups/$_" })+@($foundation.groupB)
    foreach ($scope in $scopes) {
        $group=Read-ExpansionNetworkArm $State $scope '2025-04-01'
        Assert-FoundationOwned $State $group $scope
        foreach ($resource in @(Read-ExpansionNetworkArm $State "$scope/resources" '2021-04-01' -List)) {
            $id=$resource.id
            if (-not $id.StartsWith("$scope/providers/",[StringComparison]::OrdinalIgnoreCase) -or $inventory.ContainsKey($id)) { throw 'Foreign or duplicate owned-group resource' }
            if (-not $known.ContainsKey($id)) {
                if ($resource.type -ine 'Microsoft.EventGrid/systemTopics') { throw 'Unknown owned-group resource' }
                $topic=Read-ExpansionNetworkArm $State $id '2025-02-15'
                $storageId=Assert-ExpansionHostStorageTopic $network.outputs $topic $scope
                if ($generatedTopicSources.ContainsKey($storageId)) { throw 'Duplicate generated topic for expansion Storage' }
                $generatedTopicSources[$storageId]=$id
                $known[$id]=$topic
                $protected[$id]=@{id=$topic.id;type=$topic.type;location=$topic.location;tags=$topic.tags;identity=$topic.identity;properties=$topic.properties}
            }
            Assert-FoundationText $resource.type $known[$id].type
            Assert-FoundationEqual $resource.tags $known[$id].tags
            $inventory[$id]=@{id=$id.ToLowerInvariant();name=$resource.name;type=$resource.type.ToLowerInvariant();location=$resource.location;kind=$resource.kind;sku=$resource.sku;tags=$resource.tags;identity=$resource.identity}
        }
    }
    Assert-ExpansionHostInventory $known $inventory $scopes
    return @{baseline=$baseline;protected=$protected;hosts=$hosts;inventory=$inventory;decisions=$decisions;internalIds=$internalIds}
}

function Assert-ExpansionHostPreserved([hashtable]$Manifest, [hashtable]$Live, [hashtable]$Idle, [hashtable]$All) {
    $snapshot=Read-ExpansionStandardCopy $Live; $graph=Read-ExpansionStandardCopy $Idle
    foreach ($entry in $All.Values) {
        if (($entry.pending -or $entry.verified) -and $entry.mode -ceq 'Create') {
            if (-not $Manifest.snapshot.hosts.ContainsKey($entry.hostId)) {
                if ($entry.key -cne $Manifest.key -and (-not $entry.verified -or [DateTimeOffset]::Parse([string]$entry.review.checkedAt) -lt [DateTimeOffset]::Parse([string]$Manifest.submittedAt))) { throw 'Only later verified hosts may extend a baseline' }
                $snapshot.hosts.Remove($entry.hostId)
                $snapshot.inventory.Remove($entry.hostId)
                if ($entry.binding.stage -ceq 'account') { $snapshot.decisions[$entry.key]=$Manifest.snapshot.decisions[$entry.key] }
            }
            if (-not $Manifest.idle.ContainsKey($entry.binding.root)) { $graph.Remove($entry.binding.root) }
        }
    }
    Assert-FoundationEqual $snapshot $Manifest.snapshot
    Assert-FoundationEqual $graph $Manifest.idle
}

function Assert-ExpansionHostCompiled($Template, [hashtable]$Binding) {
    Assert-CosmosNetworkKeys $Template @('$schema','contentVersion','metadata','parameters','resources','outputs')
    Assert-FoundationEqual $Template.'$schema' 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    Assert-FoundationEqual $Template.contentVersion '1.0.0.0'
    Assert-CosmosNetworkKeys $Template.metadata @('_generator')
    Assert-CosmosNetworkKeys $Template.metadata._generator @('name','version','templateHash')
    Assert-FoundationEqual $Template.metadata._generator.name 'bicep'
    Assert-FoundationSet @($Template.parameters.Keys) @($Binding.parameters.Keys)
    foreach ($parameter in $Template.parameters.Values) {
        Assert-CosmosNetworkKeys $parameter @('type') @('metadata')
        Assert-FoundationEqual $parameter.type 'string'
        if ($parameter.metadata) { Assert-CosmosNetworkKeys $parameter.metadata @('description') }
    }
    $properties=@{capabilityHostKind='Agents'}
    $names=@("[format('{0}/agents', parameters('accountName'))]","[format('{0}/{1}', parameters('accountName'), 'agents')]")
    $output="[resourceId('Microsoft.CognitiveServices/accounts/capabilityHosts', parameters('accountName'), 'agents')]"
    if ($Binding.stage -ceq 'project') {
        $names=@("[format('{0}/{1}/agents', parameters('accountName'), parameters('projectName'))]","[format('{0}/{1}/{2}', parameters('accountName'), parameters('projectName'), 'agents')]")
        $output="[resourceId('Microsoft.CognitiveServices/accounts/projects/capabilityHosts', parameters('accountName'), parameters('projectName'), 'agents')]"
        $properties=@{storageConnections=@("[parameters('storageName')]");vectorStoreConnections=@("[parameters('searchName')]");threadStorageConnections=@("[parameters('cosmosName')]")}
    }
    if ($Template.resources -isnot [array] -or $Template.resources.Count -ne 1 -or $Template.resources[0].name -isnot [string] -or $Template.resources[0].name -cnotin $names) { throw 'Exactly one directly compiled bound host required' }
    Assert-FoundationEqual $Template.resources @(@{type=$Binding.type;apiVersion='2026-05-01';name=$Template.resources[0].name;properties=$properties})
    Assert-FoundationEqual $Template.outputs @{resourceId=@{type='string';value=$output}}
}

function Assert-ExpansionHostWhatIf([hashtable]$Binding, [hashtable]$Known, $Result) {
    if ($Result -isnot [hashtable] -or $Result.status -cne 'Succeeded' -or $Result.changes -isnot [array]) { throw 'Complete successful FullResourcePayloads required' }
    $seen=@{}; $created=0
    foreach ($change in $Result.changes) {
        $id=$change.resourceId
        if ($id -isnot [string] -or -not $id -or $seen.ContainsKey($id) -or @($change.delta).Where({$null -ne $_}).Count -or @($change.diff).Where({$null -ne $_}).Count) { throw 'Duplicate or unexpanded host what-if' }
        $seen[$id]=$true
        if ($id -ieq $Binding.hostId) {
            Assert-FoundationEqual $change.changeType 'Create'
            if ($null -ne $change.before) { throw 'Existing immutable host cannot be updated' }
            Assert-ExpansionHostResource $Binding $change.after $Binding.hostId
            $expected=if ($Binding.stage -ceq 'account') { @{capabilityHostKind='Agents'} } else { @{storageConnections=@($Binding.parameters.storageName.value);vectorStoreConnections=@($Binding.parameters.searchName.value);threadStorageConnections=@($Binding.parameters.cosmosName.value)} }
            Assert-FoundationEqual $change.after.properties $expected
            $created++
        } else {
            Assert-FoundationEqual $change.changeType 'Ignore'
            if (-not $Known.ContainsKey($id) -or $change.before -isnot [hashtable] -or $change.after -isnot [hashtable]) { throw 'Ignore requires a known unchanged resource' }
            Assert-FoundationEqual $change.before $change.after
            Assert-FoundationText $change.before.id $id
            Assert-FoundationText $change.before.type $Known[$id].type
            $sparse=Read-ExpansionStandardCopy $change.before
            if ($sparse.ContainsKey('resourceGroup')) { Assert-FoundationText $sparse.resourceGroup ($id -split '/')[4]; $sparse.Remove('resourceGroup') }
            $full=Read-ExpansionStandardCopy $Known[$id]
            if ($sparse.ContainsKey('managedBy') -and -not $full.ContainsKey('managedBy')) {
                $manager=$sparse.managedBy
                if ($full.type -ine 'Microsoft.Network/networkInterfaces' -or $manager -isnot [string] -or -not $Known.ContainsKey($manager) -or $Known[$manager].type -ine 'Microsoft.Network/privateEndpoints') { throw 'NIC manager must be an independently known private endpoint' }
                $managerGroup=($manager -split '/providers/')[0]
                $managerName=($manager -split '/')[-1]
                $nicPattern='^'+[regex]::Escape("$managerGroup/providers/Microsoft.Network/networkInterfaces/$managerName.nic.")+'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
                if ($id -inotmatch $nicPattern) { throw 'Generated NIC name does not match its known endpoint manager' }
                Assert-FoundationGuid $Matches[1]
                $sparse.Remove('managedBy')
            }
            if ($full.type -iin @('Microsoft.Search/searchServices','Microsoft.DocumentDB/databaseAccounts')) {
                if ($full.location -ceq 'Sweden Central' -and $sparse.location -ceq 'swedencentral') { $full.location='swedencentral' }
                if ($full.type -ieq 'Microsoft.Search/searchServices' -and $full.properties.publicNetworkAccess -ceq 'Disabled' -and $sparse.properties.publicNetworkAccess -ceq 'disabled') { $full.properties.publicNetworkAccess='disabled' }
                if ($full.type -ieq 'Microsoft.DocumentDB/databaseAccounts') {
                    foreach ($location in $full.properties.locations) { if ($location.locationName -ceq 'Sweden Central') { $location.locationName='swedencentral' } }
                }
            }
            Assert-ExpansionStandardSubset $full $sparse
        }
    }
    if ($created -ne 1) { throw 'Exactly one expanded host Create required' }
}

function Get-ExpansionHostSourceRevisions([hashtable]$Manifest, [hashtable]$Paths, [hashtable]$Sources) {
    $previous=$Manifest.review.sourceHashes
    Assert-FoundationSet @($previous.Keys) @($Sources.Keys)
    $revisions=@{}
    foreach ($relative in $Sources.Keys) {
        if ($previous[$relative] -ceq $Sources[$relative]) { continue }
        if ($Manifest.verified -ne $true -or $Manifest.pending -ne $false -or $relative -cnotin @('scripts/Invoke-ExpansionHosts.ps1','tests/Test-ExpansionHosts.ps1')) { throw 'Only completed host validator sources may be reconciled from an exact archive' }
        $oldHash=$previous[$relative]
        if ($oldHash -isnot [string] -or $oldHash -cnotmatch '^[A-F0-9]{64}$') { throw 'Invalid historical validator hash' }
        $archive=Assert-ExternalLabPath (Join-Path ([IO.Path]::GetDirectoryName($Paths.state)) "host-validator-archive/$oldHash/$relative")
        Assert-FoundationEqual (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash $oldHash
        $revisions[$relative]=@{previous=$oldHash;current=$Sources[$relative];archiveHash=$oldHash}
    }
    return $revisions
}

function Assert-ExpansionHostReview([hashtable]$Manifest, [hashtable]$Binding, [hashtable]$Paths, [hashtable]$Prerequisites, [hashtable]$Sources, [switch]$Submitted, [switch]$Historical) {
    Assert-FoundationEqual $Manifest.version 1
    Assert-FoundationEqual $Manifest.stage 'hosts'
    Assert-FoundationEqual $Manifest.key $Binding.key
    Assert-FoundationEqual $Manifest.binding $Binding
    $review=$Manifest.review
    Assert-CosmosNetworkKeys $review @('approved','checkedAt','inputHashes','fileHashes','sourceHashes','artifactHashes','snapshotHash','idleHash','bindingHash')
    Assert-FoundationEqual $review.approved $true
    $age=[DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$review.checkedAt)
    if ($age -lt [TimeSpan]::Zero -or (-not $Submitted -and -not $Historical -and $age -gt [TimeSpan]::FromHours(1))) { throw 'Host Preview expired or future dated' }
    Assert-FoundationEqual $review.inputHashes $Prerequisites.network.inputs
    Assert-FoundationEqual $review.fileHashes $Prerequisites.files
    $null=Get-ExpansionHostSourceRevisions $Manifest $Paths $Sources
    foreach ($key in @('snapshot','idle','binding')) { Assert-FoundationEqual $review["${key}Hash"] (Get-FoundationHash $Manifest[$key]) }
    if ($Submitted) {
        $time=[DateTimeOffset]::Parse([string]$Manifest.submittedAt)
        if ($time -gt [DateTimeOffset]::UtcNow -or $time -lt [DateTimeOffset]::Parse([string]$review.checkedAt)) { throw 'Invalid persisted host submission time' }
        Assert-FoundationEqual $Manifest.deploymentId $(if ($Manifest.mode -ceq 'Create') { $Binding.root } else { $null })
    }
    if ($Manifest.mode -ceq 'Reuse') {
        Assert-FoundationEqual $Binding.stage 'account'
        Assert-FoundationEqual $Manifest.snapshot.decisions[$Binding.key] @{mode='Reuse';id=$Manifest.hostId}
        if (-not $Manifest.snapshot.hosts.ContainsKey($Manifest.hostId)) { throw 'Reuse requires the observed host snapshot' }
        Assert-FoundationEqual $review.artifactHashes @{}
    } elseif ($Manifest.mode -ceq 'Create') {
        if ($Binding.key -ceq 'account-a') { throw 'A creation is forbidden' }
        Assert-FoundationEqual $Manifest.hostId $Binding.hostId
        if ($Manifest.snapshot.hosts.ContainsKey($Manifest.hostId)) { throw 'Create Preview cannot contain the host' }
        if ($Binding.stage -ceq 'account') { Assert-FoundationEqual $Manifest.snapshot.decisions[$Binding.key] @{mode='Create';id=$Binding.hostId} }
        Assert-FoundationSet @($review.artifactHashes.Keys) @('template','parameters','whatif')
        foreach ($key in @('template','parameters','whatif')) { Assert-FoundationEqual (Get-FileHash -LiteralPath $Paths[$key] -Algorithm SHA256).Hash $review.artifactHashes[$key] }
        Assert-ExpansionHostCompiled (Read-FoundationJson $Paths.template) $Binding
        Assert-FoundationEqual (Read-FoundationJson $Paths.parameters) @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$Binding.parameters}
        Assert-ExpansionHostWhatIf $Binding (Get-ExpansionHostKnown $Manifest.snapshot) (Read-FoundationJson $Paths.whatif)
    } else { throw 'Unknown host review mode' }
}

function Get-ExpansionHostKnown([hashtable]$Snapshot) {
    $known=@{}
    foreach ($map in @($Snapshot.inventory,$Snapshot.baseline,$Snapshot.protected,$Snapshot.hosts)) {
        foreach ($id in $map.Keys) {
            if (-not $known.ContainsKey($id)) { $known[$id]=@{} }
            foreach ($key in $map[$id].Keys) { $known[$id][$key]=$map[$id][$key] }
        }
    }
    return $known
}

function Complete-ExpansionHostReceipt([hashtable]$Manifest, [hashtable]$Paths, [hashtable]$Snapshot, [hashtable]$Idle, $ExistingOutput, [scriptblock]$Guard) {
    $proof=if ($Manifest.mode -ceq 'Create') { $Idle[$Manifest.binding.root] } else { @{} }
    $hostHash=Get-FoundationHash $Snapshot.hosts[$Manifest.hostId]
    if ($ExistingOutput) {
        $completed=$Manifest.Clone(); $completed.pending=$false; $completed.verified=$true
        $completed.outputHash=(Get-FileHash -LiteralPath $Paths.outputs -Algorithm SHA256).Hash
        Assert-ExpansionHostReceipt $completed $ExistingOutput $completed.outputHash
        Assert-FoundationEqual $ExistingOutput.deploymentProof $proof
        Assert-FoundationEqual $ExistingOutput.hostHash $hostHash
        & $Guard
        Write-StandardJson $Paths.state $completed
        return $ExistingOutput
    }
    $output=@{stage='hosts';key=$Manifest.key;hostId=$Manifest.hostId;mode=$Manifest.mode;controlPlaneVerified=$true;runtimeVerified=$false;inferenceVerified=$false;completeLab=$false;azureReadOnly=$true;submissionWrites=$(if ($Manifest.mode -ceq 'Create') { 1 } else { 0 });verifiedAt=[DateTimeOffset]::UtcNow.ToString('o');deploymentId=$Manifest.deploymentId;deploymentProof=$proof;hostHash=$hostHash;inputHashes=$Manifest.review.fileHashes;sourceHashes=$Manifest.review.sourceHashes;intentHash=(Get-ExpansionHostIntentHash $Manifest)}
    $temporary=Assert-ExternalLabPath "$($Paths.outputs).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Write-StandardJson $temporary $output
        $completed=$Manifest.Clone(); $completed.outputHash=(Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash; $completed.pending=$false; $completed.verified=$true
        Assert-ExpansionHostReceipt $completed $output $completed.outputHash
        & $Guard
        [IO.File]::Move($temporary,$Paths.outputs)
        Write-StandardJson $Paths.state $completed
        return $output
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Invoke-ExpansionHosts([string]$Path, [string]$Selector, [string]$SelectedStage, [string]$SelectedAction, [string]$Compiler, [bool]$Approved) {
    $ErrorActionPreference='Stop'
    if (-not $Path -or $SelectedAction -cnotin @('Preview','Deploy','Status')) { throw 'StatePath and exact Action required' }
    $originalPath=Assert-ExternalLabPath $Path
    $originalHash=(Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
    $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
    $paths=Get-ExpansionHostPaths $state $Selector $SelectedStage
    $lock=$null; $prerequisites=$null; $sources=$null
    $hostReadTransport=@{session=$null}
    $hostCliTransport=(Get-Command Invoke-ExpansionNetworkAz).ScriptBlock
    function Invoke-ExpansionNetworkAz([hashtable]$State, [string[]]$Arguments, [switch]$Empty) {
        if ($Arguments.Count -eq 7 -and $Arguments[0] -ceq 'rest' -and $Arguments[1] -ceq '--method' -and $Arguments[2] -ceq 'get' -and $Arguments[3] -ceq '--url' -and $Arguments[5] -ceq '--headers' -and $Arguments[6] -ceq 'Accept=application/json' -and -not $Empty) {
            Assert-ExpansionArmReadUrl $State $Arguments[4]
            if (-not $hostReadTransport.session) { $hostReadTransport.session=New-ExpansionArmReadSession $State }
            return Invoke-ExpansionArmRead $hostReadTransport.session $State $Arguments[4]
        }
        return & $hostCliTransport $State $Arguments -Empty:$Empty
    }
    try {
        $lock=[IO.File]::Open($paths.lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
        $state.evidenceDirectory=$paths.evidence
        $null=[IO.Directory]::CreateDirectory($paths.evidence)
        function Invoke-FoundationAz([hashtable]$State, [string[]]$Arguments, [string]$Label) { return Invoke-ExpansionNetworkAz $State $Arguments }
        $prerequisites=Get-ExpansionHostPrerequisites $state $originalPath
        Assert-FoundationEqual $prerequisites.network.inputs.state $originalHash
        $sources=Get-ExpansionHostSources
        $binding=Get-ExpansionHostBinding $state $prerequisites $Selector $SelectedStage
        $all=@{}; $receipts=@{}; $observedFiles=@{}; $registryPaths=@{}
        foreach ($pair in @(@('a-test','account'),@('b-dev','account'),@('a-test','project'),@('b-dev','project'),@('b-test','project'))) {
            $other=Get-ExpansionHostPaths $state $pair[0] $pair[1]; $registryPaths[$other.key]=$other
            foreach ($name in @('state','outputs')) {
                $observedFiles[$other[$name]]=$null
                if (Test-Path -LiteralPath $other[$name]) { $observedFiles[$other[$name]]=(Get-FileHash -LiteralPath $other[$name] -Algorithm SHA256).Hash }
            }
            if ($observedFiles[$other.state]) { $all[$other.key]=Read-FoundationJson $other.state }
            if ($observedFiles[$other.outputs]) {
                $entry=$all[$other.key]
                if (-not $entry -or (-not $entry.verified -and ($SelectedAction -cne 'Status' -or $other.key -cne $binding.key -or -not $entry.pending))) { throw 'Only selected pending Status may reconcile an orphan output' }
                $receipts[$other.key]=Read-FoundationJson $other.outputs
            }
        }
        Assert-ExpansionHostTransition $all $binding.key $SelectedAction $Approved
        foreach ($entry in $all.Values) {
            $expected=Get-ExpansionHostBinding $state $prerequisites $entry.binding.selector $entry.binding.stage
            Assert-ExpansionHostReview $entry $expected $registryPaths[$entry.key] $prerequisites $sources -Submitted:($entry.pending -or $entry.verified) -Historical:($entry.key -cne $binding.key -or $SelectedAction -ceq 'Preview')
            if ($entry.verified) { Assert-ExpansionHostReceipt $entry $receipts[$entry.key] $observedFiles[$registryPaths[$entry.key].outputs] }
            $revisions=Get-ExpansionHostSourceRevisions $entry $registryPaths[$entry.key] $sources
            if ($revisions.Count) { Write-StandardJson (Join-Path $paths.evidence ('validator-revisions-'+[guid]::NewGuid().ToString('N')+'.json')) @{key=$entry.key;checkedAt=[DateTimeOffset]::UtcNow.ToString('o');manifestHash=$observedFiles[$registryPaths[$entry.key].state];outputHash=$observedFiles[$registryPaths[$entry.key].outputs];revisions=$revisions} }
        }
        if ($SelectedStage -ceq 'project') {
            $accountKey='account-'+$binding.case
            if (-not $all[$accountKey] -or -not $all[$accountKey].verified) { throw 'Verified case-shared account receipt required first' }
        }
        function Assert-HostsUnchanged {
            Assert-ExpansionHostInputs $state $originalPath $prerequisites $sources
            foreach ($file in $observedFiles.Keys) {
                if ($observedFiles[$file]) { Assert-FoundationEqual (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash $observedFiles[$file] }
                elseif (Test-Path -LiteralPath $file) { throw 'Host registry changed during collection' }
            }
        }
        $started=[DateTimeOffset]::UtcNow.ToString('o')
        $manifest=$all[$binding.key]
        $idle=Get-ExpansionHostIdle $state $prerequisites $all $receipts
        $live=Get-ExpansionHostLive $state $prerequisites $all $receipts
        if ($SelectedAction -ceq 'Status') {
            Assert-ExpansionHostPreserved $manifest $live $idle $all
            Assert-FoundationEqual (Get-ExpansionHostLive $state $prerequisites $all $receipts) $live
            Assert-FoundationEqual (Get-ExpansionHostIdle $state $prerequisites $all $receipts) $idle
            Assert-HostsUnchanged
            if ($manifest.verified) { return $receipts[$binding.key] }
            return Complete-ExpansionHostReceipt $manifest $paths $live $idle $receipts[$binding.key] { Assert-HostsUnchanged }
        }
        if ($SelectedAction -ceq 'Deploy') {
            Assert-ExpansionHostReview $manifest $binding $paths $prerequisites $sources
            Assert-FoundationEqual $live $manifest.snapshot
            Assert-FoundationEqual $idle $manifest.idle
        }
        $decision=if ($SelectedStage -ceq 'account') { $live.decisions[$binding.key] } else { @{mode='Create';id=$binding.hostId} }
        if ($SelectedAction -ceq 'Deploy') { Assert-FoundationEqual $decision @{mode=$manifest.mode;id=$manifest.hostId} }
        $artifacts=@{}
        if ($decision.mode -ceq 'Create') {
            if ($SelectedAction -ceq 'Preview') {
                $source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../infra/modules/standard-$SelectedStage-host.bicep"))
                $null=Invoke-ExpansionNetworkProcess $state $Compiler @('build',$source,'--no-restore','--outfile',$paths.template)
                Assert-ExpansionHostCompiled (Read-FoundationJson $paths.template) $binding
                Write-StandardJson $paths.parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$binding.parameters}
            }
            foreach ($key in @('template','parameters')) { $artifacts[$key]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
            $common=@('--resource-group',(($binding.group -split '/')[-1]),'--name',(($binding.root -split '/')[-1]),'--mode','Incremental','--template-file',$paths.template,'--parameters',"@$($paths.parameters)")
            $validation=Invoke-ExpansionNetworkAz $state (@('deployment','group','validate')+$common)
            if ($validation.error -or $validation.properties.provisioningState -cne 'Succeeded') { throw 'Host ARM validation failed' }
            $whatif=Invoke-ExpansionNetworkAz $state (@('deployment','group','what-if','--no-pretty-print','--result-format','FullResourcePayloads')+$common)
            Assert-ExpansionHostWhatIf $binding (Get-ExpansionHostKnown $live) $whatif
        }
        Assert-FoundationEqual (Get-ExpansionHostLive $state $prerequisites $all $receipts) $live
        Assert-FoundationEqual (Get-ExpansionHostIdle $state $prerequisites $all $receipts) $idle
        Assert-HostsUnchanged
        foreach ($key in $artifacts.Keys) { Assert-FoundationEqual (Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash $artifacts[$key] }
        if ($SelectedAction -ceq 'Preview') {
            if ($decision.mode -ceq 'Create') { Write-StandardJson $paths.whatif $whatif; $artifacts.whatif=(Get-FileHash -LiteralPath $paths.whatif -Algorithm SHA256).Hash }
            $manifest=@{version=1;stage='hosts';key=$binding.key;binding=$binding;mode=$decision.mode;hostId=$decision.id;pending=$false;verified=$false;snapshot=$live;idle=$idle;review=@{approved=$true;checkedAt=$started;inputHashes=$prerequisites.network.inputs;fileHashes=$prerequisites.files;sourceHashes=$sources;artifactHashes=$artifacts;snapshotHash=(Get-FoundationHash $live);idleHash=(Get-FoundationHash $idle);bindingHash=(Get-FoundationHash $binding)}}
            Assert-ExpansionHostReview $manifest $binding $paths $prerequisites $sources
            Write-StandardJson $paths.state $manifest
            return @{action='Preview';key=$binding.key;mode=$decision.mode;hostId=$decision.id;reviewPath=$paths.state;expiresAt=[DateTimeOffset]::Parse($started).AddHours(1).ToString('o')}
        }
        Assert-ExpansionHostReview $manifest $binding $paths $prerequisites $sources
        $manifest.pending=$true; $manifest.submittedAt=[DateTimeOffset]::UtcNow.ToString('o'); $manifest.deploymentId=$(if ($manifest.mode -ceq 'Create') { $binding.root } else { $null })
        Write-StandardJson $paths.state $manifest
        $observedFiles[$paths.state]=(Get-FileHash -LiteralPath $paths.state -Algorithm SHA256).Hash
        if ($manifest.mode -ceq 'Reuse') { return Complete-ExpansionHostReceipt $manifest $paths $live $idle $null { Assert-HostsUnchanged } }
        $null=Invoke-ExpansionNetworkAz $state (@('deployment','group','create')+$common+@('--no-wait')) -Empty
        return @{action='Deploy';key=$binding.key;pending=$true;deploymentId=$binding.root;intentPath=$paths.state}
    } finally {
        try {
            Assert-FoundationEqual (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash $originalHash
            if ($prerequisites -and $sources) { Assert-ExpansionHostInputs $state $originalPath $prerequisites $sources }
        } finally { Close-ExpansionArmReadSession $hostReadTransport.session; if ($lock) { $lock.Dispose() } }
    }
}

if ($hostsDefinitions) { return }
Invoke-ExpansionHosts @hostsInvocation