[CmdletBinding()]
param([string]$StatePath, [ValidateSet('dependencies','account','project','access')][string]$Stage, [ValidateSet('Preview','Deploy','Status')][string]$Action = 'Preview', [switch]$DefinitionsOnly)

function Assert-StandardState([hashtable]$State, [string]$SelectedStage, [string]$SelectedAction) {
    Assert-LabState $State
    foreach ($flag in @('minimalPrompt','privateAccessVerified','deploymentAuthorized')) {
        if ($State[$flag] -isnot [bool] -or -not $State[$flag]) { throw "Required boolean: $flag" }
    }
    if ($State.phase -isnot [string] -or $State.phase -cne 'activate' -or $State.pendingPhase) { throw 'Activated Minimal with no pending phase required' }
    $sequence = @('dependencies','account','project','access')
    $standard = $State.standard
    if ($standard -isnot [hashtable] -or $standard.completedStages -isnot [array] -or $standard.deploymentNames -isnot [hashtable]) { throw 'Invalid Standard state' }
    $completed = @($standard.completedStages)
    if ($completed.Count -gt 4 -or ($completed -join ',') -cne (($sequence | Select-Object -First $completed.Count) -join ',')) { throw 'Standard stages must be an ordered prefix' }
    foreach ($entry in $standard.deploymentNames.GetEnumerator()) {
        if ($entry.Key -cnotin $sequence -or $entry.Value -isnot [string] -or $entry.Value -cne "fgl-$($State.labId)-standard-$($entry.Key)") { throw 'Unexpected recorded deployment name' }
    }
    foreach ($done in $completed) { if ($done -ne 'account' -and -not $standard.deploymentNames.ContainsKey($done)) { throw 'Completed stage has no recorded root' } }
    if ($standard.pendingStage -and ($standard.pendingStage -isnot [string] -or $standard.pendingStage -cnotin $sequence)) { throw 'Invalid pending stage' }
    if ($SelectedStage -cnotin $sequence -or $completed.Count -eq 4 -or $SelectedStage -cne $sequence[$completed.Count]) { throw 'Stage replay or out-of-order transition' }
    if ($SelectedAction -eq 'Status') {
        if ($standard.pendingStage -cne $SelectedStage -or -not $standard.deploymentNames.ContainsKey($SelectedStage)) { throw 'No matching pending Standard deployment' }
    } elseif ($standard.pendingStage) { throw 'Reconcile the pending Standard deployment; immutable hosts must never be replayed' }
}

function Assert-StandardOwned([hashtable]$State, $Resource, [string]$Id) {
    if (-not $Resource -or $Resource.id -isnot [string] -or $Resource.id -ine $Id -or $Resource.tags['fgl-owner'] -isnot [string] -or $Resource.tags['fgl-owner'] -cne $State.ownershipId -or $Resource.tags['fgl-lab'] -isnot [string] -or $Resource.tags['fgl-lab'] -cne $State.labId) { throw "Resource ownership mismatch: $Id" }
}

function Assert-StandardGroups([hashtable]$State, [array]$Groups) {
    if ($Groups.Count -ne 3 -or @($Groups.name | Select-Object -Unique).Count -ne 3) { throw 'Exactly three existing owned groups required' }
    foreach ($group in $Groups) {
        Assert-LabGroupOwnership $State $group
        if ($group.id -in $State.preexistingGroupIds) { throw 'Pre-existing group cannot be adopted' }
    }
}

function Get-StandardBindings([hashtable]$State, [hashtable]$Lab, [hashtable]$Account, [hashtable]$Project, [hashtable]$Gateway) {
    $targets = @(Get-LabPrivateTargets $State $Lab)
    $accountId = ($targets | Where-Object key -eq 'case-a').resourceId
    $projectId = $Lab.cases[0].projects[0].resourceId
    Assert-StandardOwned $State $Account $accountId
    Assert-StandardOwned $State $Project $projectId
    Assert-StandardOwned $State $Gateway $Lab.gateway
    foreach ($resource in @($Account,$Project,$Gateway)) {
        if ($resource.properties.provisioningState -isnot [string] -or $resource.properties.provisioningState -cne 'Succeeded') { throw 'Existing resources must have succeeded' }
    }
    if ($Account.location -isnot [string] -or $Account.location -ine 'swedencentral' -or $Account.kind -isnot [string] -or $Account.kind -cne 'AIServices' -or $Account.properties.publicNetworkAccess -isnot [string] -or $Account.properties.publicNetworkAccess -ine 'Disabled' -or $Gateway.properties.publicNetworkAccess -isnot [string] -or $Gateway.properties.publicNetworkAccess -ine 'Disabled') { throw 'Existing Foundry resource and gateway must be private' }
    if ($Project.properties.ContainsKey('publicNetworkAccess') -and ($Project.properties.publicNetworkAccess -isnot [string] -or $Project.properties.publicNetworkAccess -ine 'Disabled')) { throw 'Project is not private' }
    foreach ($value in @($Project.identity.principalId,$Project.properties.internalId)) {
        $parsed = [guid]::Empty
        if ($value -isnot [string] -or -not ([guid]::TryParseExact($value, 'D', [ref]$parsed) -or [guid]::TryParseExact($value, 'N', [ref]$parsed)) -or $parsed -eq [guid]::Empty) { throw 'Verified project principalId and internalId GUIDs required' }
    }
    if ($Project.identity.principalId -ine $Lab.cases[0].projects[0].principalId) { throw 'Project managed identity changed since activation' }
    $casePrefix = $accountId.Substring(0, $accountId.IndexOf('/providers/', [StringComparison]::OrdinalIgnoreCase))
    $integration = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-integration"
    $injections = @($Account.properties.networkInjections)
    if ($injections.Count -ne 1 -or $injections[0].scenario -cne 'agent' -or $injections[0].subnetArmId -ine "$integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-$($State.labId)/subnets/snet-agent-a" -or $injections[0].useMicrosoftManagedNetwork -isnot [bool] -or $injections[0].useMicrosoftManagedNetwork) { throw 'Existing agent subnet injection mismatch' }
    return @{accountId=$accountId; projectId=$projectId; casePrefix=$casePrefix; integration=$integration; subnet="$integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-$($State.labId)/subnets/snet-agent-a"; parameters=@{labId=@{value=$State.labId}; ownershipId=@{value=$State.ownershipId}; location=@{value='swedencentral'}; accountName=@{value=($accountId -split '/')[-1]}; projectName=@{value='case-a-dev'}; projectPrincipalId=@{value=$Project.identity.principalId}; workspaceId=@{value=$Project.properties.internalId.ToLowerInvariant()}; agentContainerName=@{value=''}}}
}

function Assert-StandardTerminal([hashtable]$State, [array]$Roots, [hashtable]$Nested) {
    $expected = @('bootstrap','lock','activate' | ForEach-Object { "fgl-$($State.labId)-$_" }) + @($State.standard.deploymentNames.Values)
    if ($Roots.Count -ne $expected.Count -or @($Roots.name | Select-Object -Unique).Count -ne $expected.Count) { throw 'Missing or duplicate deployment roots' }
    foreach ($root in $Roots) {
        if ($root.name -cnotin $expected -or $root.id -ine "/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/$($root.name)" -or $root.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Unexpected or active root deployment' }
    }
    foreach ($group in $State.resourceGroups) {
        if (-not $Nested.ContainsKey($group) -or @($Nested[$group]).Count -eq 0) { throw 'Nested deployment coverage missing' }
        foreach ($deployment in $Nested[$group]) {
            if (-not $deployment.name -or $deployment.id -ine "/subscriptions/$($State.subscriptionId)/resourceGroups/$group/providers/Microsoft.Resources/deployments/$($deployment.name)" -or $deployment.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Unexpected or active nested deployment' }
        }
    }
}

function Assert-StandardHosts([hashtable]$State, [hashtable]$Binding, [string]$SelectedStage, [array]$AccountHosts, [array]$ProjectHosts, [string]$StorageName, [switch]$Reconcile) {
    if ($AccountHosts.Count -gt 1) { throw 'Multiple account hosts' }
    if ($AccountHosts.Count -eq 1) {
        $hostResource = $AccountHosts[0]
        $implicitId = "$($Binding.accountId)/capabilityHosts/$($Binding.parameters.accountName.value)@aml_aiagentservice"
        $recordedId = $State.standard.accountHostId
        if ($recordedId -and ($recordedId -notin @($implicitId,"$($Binding.accountId)/capabilityHosts/agents") -or ($recordedId -ne $implicitId -and -not $State.standard.deploymentNames.ContainsKey('account')))) { throw 'Unbound recorded account host' }
        if ($hostResource.id -ine $implicitId -and (-not $recordedId -or $hostResource.id -ine $recordedId)) { throw 'Unexpected immutable account host' }
        $subnet = $hostResource.properties.customerSubnet
        if ($subnet -is [Collections.IDictionary]) { $subnet = $subnet.id }
        if ($hostResource.properties.provisioningState -isnot [string] -or $hostResource.properties.provisioningState -cne 'Succeeded' -or $hostResource.properties.capabilityHostKind -isnot [string] -or $hostResource.properties.capabilityHostKind -cne 'Agents' -or $subnet -isnot [string] -or $subnet -ine $Binding.subnet) { throw 'Account host kind, state or customerSubnet mismatch' }
    }
    if ($SelectedStage -in @('project','access') -and ($AccountHosts.Count -ne 1 -or $AccountHosts[0].id -ine $State.standard.accountHostId)) { throw 'Completed account host must still exist and match' }
    if ($SelectedStage -eq 'access' -or ($Reconcile -and $SelectedStage -eq 'project')) {
        if ($ProjectHosts.Count -ne 1 -or $ProjectHosts[0].id -isnot [string] -or $ProjectHosts[0].id -ine "$($Binding.projectId)/capabilityHosts/agents" -or $ProjectHosts[0].properties.provisioningState -isnot [string] -or $ProjectHosts[0].properties.provisioningState -cne 'Succeeded') { throw 'Expected succeeded project host required' }
        $connections = @{storageConnections=$StorageName; vectorStoreConnections="srch-fgl-$($State.labId)-standard"; threadStorageConnections="cosmos-fgl-$($State.labId)-standard"}
        foreach ($key in $connections.Keys) {
            $actual = $ProjectHosts[0].properties[$key]
            if ($actual -isnot [array] -or $actual.Count -ne 1 -or $actual[0] -isnot [string] -or $actual[0] -cne $connections[$key]) { throw 'Project host connections mismatch' }
        }
    } elseif ($ProjectHosts.Count) { throw 'Unexpected project host; never replay immutable host creation' }
}

function Assert-StandardReview([hashtable]$Review, [string]$SelectedStage, [string]$TemplatePath, [string]$ParametersPath, [hashtable]$Expected, [switch]$Submitted) {
    if (-not $Review -or $Review.stage -isnot [string] -or $Review.stage -cne $SelectedStage) { throw 'Matching preview required' }
    $age = [DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($Review.checkedAt)
    if ($age -lt [TimeSpan]::Zero -or (-not $Submitted -and $age -gt [TimeSpan]::FromHours(1))) { throw 'Preview stale or future dated' }
    if ((Get-FileHash $TemplatePath).Hash -cne $Review.templateHash -or (Get-FileHash $ParametersPath).Hash -cne $Review.parametersHash) { throw 'Reviewed artifacts changed' }
    $actual = (Get-Content -LiteralPath $ParametersPath -Raw | ConvertFrom-Json -AsHashtable).parameters
    if ($actual.Count -ne $Expected.Count) { throw 'Unexpected parameter set' }
    foreach ($key in $Expected.Keys) {
        if ($actual[$key] -isnot [hashtable] -or $actual[$key].Count -ne 1 -or $actual[$key].value -isnot [string] -or $actual[$key].value -cne $Expected[$key].value) { throw "Parameter binding changed: $key" }
    }
}

function Assert-StandardWhatIf([hashtable]$State, [hashtable]$Binding, [string]$SelectedStage, [hashtable]$Result, [string]$StorageName) {
    if ($Result.status -isnot [string] -or $Result.status -cne 'Succeeded' -or $Result.changes -isnot [array] -or -not $Result.changes.Count) { throw 'Expanded nonempty successful what-if required' }
    if ($StorageName -cnotmatch ('^stfgl' + [regex]::Escape($State.labId) + '[a-z0-9]{6}$')) { throw 'Invalid Standard storage name' }
    $casePrefix = $Binding.casePrefix; $integration = $Binding.integration; $stem = "fgl-$($State.labId)"
    $storage = "$casePrefix/providers/Microsoft.Storage/storageAccounts/$StorageName"
    $search = "$casePrefix/providers/Microsoft.Search/searchServices/srch-$stem-standard"
    $cosmos = "$casePrefix/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-$stem-standard"
    $allowed = @{}; $roleScopes = @{}
    if ($SelectedStage -eq 'dependencies') {
        foreach ($id in @($storage,$search,$cosmos)) { $allowed[$id] = 'owned'; $allowed["$($Binding.projectId)/connections/$(($id -split '/')[-1])"] = 'child' }
        foreach ($service in @('blob','search','cosmos')) {
            $endpoint = "$casePrefix/providers/Microsoft.Network/privateEndpoints/pe-$stem-standard-$service"
            $allowed[$endpoint] = 'owned'; $allowed["$endpoint/privateDnsZoneGroups/default"] = 'child'
            foreach ($name in @("$stem-standard-$service-endpoint","pe-$stem-standard-$service")) { $allowed["$casePrefix/providers/Microsoft.Resources/deployments/$name"] = 'deployment' }
        }
        foreach ($zone in @('privatelink.search.windows.net','privatelink.documents.azure.com')) {
            $id = "$integration/providers/Microsoft.Network/privateDnsZones/$zone"; $allowed[$id] = 'owned'; $allowed["$id/virtualNetworkLinks/standard-lab-only"] = 'owned'
        }
        $allowed["$integration/providers/Microsoft.Resources/deployments/$stem-standard-dns"] = 'deployment'
        $roleScopes[$storage] = @('17d1049b-9a84-46fb-8f53-869881c3d3ab'); $roleScopes[$cosmos] = @('230815da-be43-4aae-9cb4-875f7bd000aa'); $roleScopes[$search] = @('8ebe5a00-799e-43f5-93ac-243d3dce84a7','7ca78c08-252a-4471-8644-bb5ff32d4ba0')
    } elseif ($SelectedStage -in @('account','project')) {
        $parent = if ($SelectedStage -eq 'account') { $Binding.accountId } else { $Binding.projectId }
        $allowed["$parent/capabilityHosts/agents"] = 'immutable'
    } else {
        $workspace = ([guid]$Binding.parameters.workspaceId.value).ToString('D')
        $agentName = $Binding.parameters.agentContainerName.value
        if ($agentName -isnot [string] -or $agentName -cnotmatch ('^' + [regex]::Escape($workspace) + '-(?:[a-f0-9]{12}-)?azureml-agent$')) { throw 'Invalid bound agent container name' }
        $roleScopes["$storage/blobServices/default/containers/$workspace-azureml-blobstore"] = @('ba92f5b4-2d11-453d-a403-e96b0029c9fe')
        $roleScopes["$storage/blobServices/default/containers/$agentName"] = @('b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    }
    $allowed["$casePrefix/providers/Microsoft.Resources/deployments/$stem-standard-$SelectedStage"] = 'deployment'
    $seen = @{}; $expanded = 0
    foreach ($change in $Result.changes) {
        $id = $change.resourceId; Assert-LabResourceId $State $id
        if ($change.changeType -isnot [string]) { throw 'Invalid what-if change type' }
        if ($seen.ContainsKey($id)) { throw 'Duplicate what-if resource' }; $seen[$id] = $true
        if ($change.changeType -ceq 'Ignore') {
            if (-not $change.before -or $change.before.id -ine $id -or @($change.delta).Where({ $null -ne $_ }).Count -or ($change.after -and ($change.before | ConvertTo-Json -Depth 100 -Compress) -cne ($change.after | ConvertTo-Json -Depth 100 -Compress))) { throw 'Ignore is not unchanged existing state' }
            continue
        }
        if ($change.changeType -cnotin @('Create','Modify','NoChange')) { throw 'Delete or unsupported what-if change' }
        $kind = $allowed[$id]
        if ($SelectedStage -eq 'dependencies' -and $id -match ('^' + [regex]::Escape($casePrefix) + '/providers/Microsoft.Resources/deployments/[a-z0-9]{13}-PrivateEndpoint-PrivateDnsZoneGroup$')) {
            $arguments = $change.after.properties.parameters
            if ($arguments.privateEndpointName.value -cnotin @('blob','search','cosmos' | ForEach-Object { "pe-$stem-standard-$_" }) -or $arguments.name.value -cne 'default' -or $arguments.enableTelemetry.value -isnot [bool] -or $arguments.enableTelemetry.value) { throw 'Unbound nested DNS deployment' }
            $kind = 'deployment'
        }
        if ($id -match '^(.*)/providers/Microsoft.Authorization/roleAssignments/([0-9a-f-]{36})$' -and $roleScopes.ContainsKey($Matches[1])) {
            $scope = $Matches[1]; $properties = $change.after.properties
            $definitions = @($roleScopes[$scope] | ForEach-Object { "/subscriptions/$($State.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$_" })
            $roleGuid = [guid]::Empty
            if (-not [guid]::TryParseExact(($id -split '/')[-1], 'D', [ref]$roleGuid) -or $roleGuid -eq [guid]::Empty -or $properties.principalId -ine $Binding.parameters.projectPrincipalId.value -or $properties.roleDefinitionId -inotin $definitions -or ($properties.ContainsKey('principalType') -and $properties.principalType -cne 'ServicePrincipal') -or ($properties.scope -and $properties.scope -ine $scope)) { throw 'Role identity, scope or definition mismatch' }
            $kind = 'child'
        }
        if ($SelectedStage -eq 'access' -and $id -match ('^' + [regex]::Escape($cosmos) + '/sqlRoleAssignments/[0-9a-f-]{36}$')) {
            $properties = $change.after.properties
            if ($properties.principalId -ine $Binding.parameters.projectPrincipalId.value -or $properties.roleDefinitionId -ine "$cosmos/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002" -or $properties.scope -ine "$cosmos/dbs/enterprise_memory") { throw 'Cosmos role scope or identity mismatch' }; $kind = 'child'
        }
        if (-not $kind -or ($kind -eq 'immutable' -and $change.changeType -cne 'Create')) { throw "Forbidden Standard target or immutable replay: $id" }
        if ($change.after.id -isnot [string] -or $change.after.id -ine $id -or ($change.changeType -eq 'Create' -and $change.before)) { throw 'What-if resource identity or create mismatch' }
        if ($kind -eq 'deployment' -and $change.changeType -ne 'Create' -and -not $State.standard.deploymentNames.ContainsKey($SelectedStage)) { throw 'Unrecorded existing nested deployment cannot be adopted' }
        if ($change.changeType -cne 'Create' -and $kind -ne 'deployment') { Assert-StandardOwned $State $change.before $id }
        if ($kind -eq 'owned') { Assert-StandardOwned $State $change.after $id }
        if ($id -in @($storage,$search,$cosmos) -and ($change.after.properties.publicNetworkAccess -isnot [string] -or $change.after.properties.publicNetworkAccess -ine 'Disabled')) { throw 'Public Standard dependency' }
        if ($id -in @($storage,$search,$cosmos) -and (($id -eq $storage -and ($change.after.properties.allowSharedKeyAccess -isnot [bool] -or $change.after.properties.allowSharedKeyAccess)) -or ($id -ne $storage -and ($change.after.properties.disableLocalAuth -isnot [bool] -or -not $change.after.properties.disableLocalAuth)))) { throw 'Local dependency authentication enabled' }
        if ($id -match ('^' + [regex]::Escape($Binding.projectId) + '/connections/([^/]+)$')) {
            $connectionName = $Matches[1]; $connection = $change.after.properties
            $target = @($storage,$search,$cosmos | Where-Object { ($_ -split '/')[-1] -ceq $connectionName })
            if ($target.Count -ne 1 -or $connection.metadata.ResourceId -ine $target[0] -or $connection.authType -cne 'AAD' -or $connection.isSharedToAll -isnot [bool] -or $connection.isSharedToAll) { throw 'Project connection binding mismatch' }
        }
        if ($id -match ('^' + [regex]::Escape($casePrefix) + '/providers/Microsoft.Network/privateEndpoints/pe-' + $stem + '-standard-(blob|search|cosmos)$')) {
            $service = $Matches[1]; $targets = @{blob=$storage; search=$search; cosmos=$cosmos}; $groups = @{blob='blob';search='searchService';cosmos='Sql'}
            $links = @($change.after.properties.privateLinkServiceConnections)
            if ($links.Count -ne 1 -or $links[0].properties.privateLinkServiceId -ine $targets[$service] -or ($links[0].properties.groupIds -join ',') -cne $groups[$service] -or $change.after.properties.subnet.id -ine "$integration/providers/Microsoft.Network/virtualNetworks/vnet-$stem/subnets/snet-case-a-pe") { throw 'PE target or subnet mismatch' }
        }
        if ($kind -eq 'deployment' -and $change.after.properties.mode -cne 'Incremental') { throw 'Unsafe nested deployment mode' }
        if ($kind -ne 'deployment') { $expanded++ }
    }
    if (-not $expanded) { throw 'What-if has no expanded Standard resources' }
}

function Read-StandardArm([hashtable]$State, [string]$Id, [string]$Api, [string]$Label, [switch]$List) {
    $response = Invoke-LabAz $State @('rest','--method','get','--url',"https://management.azure.com${Id}?api-version=$Api") "standard-$Label"
    if ($response -isnot [hashtable]) { throw 'Missing ARM response' }
    if ($List) {
        if ($response.value -isnot [array] -or ($null -ne $response.nextLink -and ($response.nextLink -isnot [string] -or $response.nextLink.Length -gt 0))) { throw 'Incomplete ARM list; do not infer absence' }
        return $response.value
    }
    if ($response.id -isnot [string] -or $response.id -ine $Id) { throw "ARM identity mismatch: $Label" }
    return $response
}

function Confirm-StandardIdle([hashtable]$State) {
    $roots = @(); $nested = @{}
    foreach ($name in (@('bootstrap','lock','activate' | ForEach-Object { "fgl-$($State.labId)-$_" }) + @($State.standard.deploymentNames.Values))) { $roots += Invoke-LabAz $State @('deployment','sub','show','--name',$name) 'standard-root' }
    foreach ($group in $State.resourceGroups) { $nested[$group] = @(Invoke-LabAz $State @('deployment','group','list','--resource-group',$group) 'standard-nested') }
    Assert-StandardTerminal $State $roots $nested
}

function Get-StandardLiveBindings([hashtable]$State, [hashtable]$Lab) {
    Assert-StandardGroups $State @(Confirm-LabRunContext $State)
    $null = Get-LabPrivateTargets $State $Lab
    $account = Read-StandardArm $State $Lab.cases[0].accountId '2026-05-01' 'account'
    $project = Read-StandardArm $State $Lab.cases[0].projects[0].resourceId '2026-05-01' 'project'
    $gateway = Read-StandardArm $State $Lab.gateway '2024-05-01' 'gateway'
    $binding = Get-StandardBindings $State $Lab $account $project $gateway
    if ('project' -cin $State.standard.completedStages) {
        $outputs = Get-Content -LiteralPath (Join-Path $State.runDirectory 'standard-outputs.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $binding.parameters.agentContainerName.value = Resolve-StandardContainers $State $binding $outputs.dependencies
    }
    return $binding
}

function Resolve-StandardContainers([hashtable]$State, [hashtable]$Binding, [hashtable]$Dependencies) {
    $storageName = $Dependencies.storage.name
    $storageId = "$($Binding.casePrefix)/providers/Microsoft.Storage/storageAccounts/$storageName"
    if ($storageName -isnot [string] -or $storageName -cnotmatch ('^stfgl' + [regex]::Escape($State.labId) + '[a-z0-9]{6}$') -or $Dependencies.storage.id -isnot [string] -or $Dependencies.storage.id -ine $storageId) { throw 'Missing or inconsistent completed dependency storage' }
    foreach ($key in @('accountId','projectId')) {
        if ($Dependencies[$key] -isnot [string] -or $Dependencies[$key] -ine $Binding[$key]) { throw 'Dependency resource binding mismatch' }
    }
    foreach ($key in @('labId','ownershipId','projectPrincipalId','workspaceId')) {
        if ($Dependencies[$key] -isnot [string] -or $Dependencies[$key] -ine $Binding.parameters[$key].value) { throw 'Dependency project binding mismatch' }
    }
    $storage = Read-StandardArm $State $storageId '2023-05-01' 'container-storage'
    Assert-StandardOwned $State $storage $storageId
    if ($storage.type -isnot [string] -or $storage.type -ine 'Microsoft.Storage/storageAccounts' -or $storage.properties.provisioningState -isnot [string] -or $storage.properties.provisioningState -cne 'Succeeded' -or $storage.properties.publicNetworkAccess -isnot [string] -or $storage.properties.publicNetworkAccess -cne 'Disabled' -or $storage.properties.allowSharedKeyAccess -isnot [bool] -or $storage.properties.allowSharedKeyAccess -or $storage.properties.allowBlobPublicAccess -isnot [bool] -or $storage.properties.allowBlobPublicAccess) { throw 'Private succeeded keyless storage required' }
    $containerRoot = "$storageId/blobServices/default/containers"
    $containers = @(Read-StandardArm $State $containerRoot '2023-05-01' 'containers' -List)
    $workspace = ([guid]$Binding.parameters.workspaceId.value).ToString('D')
    $agentPattern = '^' + [regex]::Escape($workspace) + '-(?:[a-f0-9]{12}-)?azureml-agent$'
    $seen = @{}; $agents = @(); $blobstores = @()
    foreach ($container in $containers) {
        if ($container -isnot [hashtable] -or $container.name -isnot [string] -or $container.name -cnotmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' -or $container.id -isnot [string] -or $container.id -ine "$containerRoot/$($container.name)" -or $container.type -isnot [string] -or $container.type -ine 'Microsoft.Storage/storageAccounts/blobServices/containers') { throw 'Invalid container identity or type' }
        if ($seen.ContainsKey($container.id)) { throw 'Duplicate container in ARM list' }; $seen[$container.id] = $true
        if ($container.name -ceq "$workspace-azureml-blobstore") { $blobstores += $container }
        if ($container.name -cmatch $agentPattern) { $agents += $container }
    }
    if ($blobstores.Count -ne 1 -or $agents.Count -ne 1) { throw 'Expected existing blobstore and unique workspace agent container' }
    return $agents[0].name
}

function Confirm-StandardPrerequisites([hashtable]$State, [hashtable]$Binding, [string]$SelectedStage, [string]$StorageName, [switch]$Reconcile) {
    if ($SelectedStage -eq 'dependencies' -and -not $Reconcile) {
        foreach ($namespace in @('Microsoft.Search','Microsoft.Storage','Microsoft.DocumentDB','Microsoft.CognitiveServices','Microsoft.Network')) {
            $provider = Invoke-LabAz $State @('provider','show','--namespace',$namespace) 'standard-provider'
            if ($provider.namespace -cne $namespace -or $provider.registrationState -cne 'Registered') { throw "Provider must already be Registered: $namespace; no registration performed" }
        }
    } else {
        $services = @(@{type='Microsoft.Storage/storageAccounts';name=$StorageName;api='2023-05-01'}, @{type='Microsoft.Search/searchServices';name="srch-fgl-$($State.labId)-standard";api='2025-05-01'}, @{type='Microsoft.DocumentDB/databaseAccounts';name="cosmos-fgl-$($State.labId)-standard";api='2024-11-15'})
        foreach ($service in $services) {
            $id = "$($Binding.casePrefix)/providers/$($service.type)/$($service.name)"
            $actual = Read-StandardArm $State $id $service.api 'dependency'; Assert-StandardOwned $State $actual $id
            if ($actual.properties.provisioningState -isnot [string] -or $actual.properties.provisioningState -ine 'Succeeded' -or $actual.properties.publicNetworkAccess -isnot [string] -or $actual.properties.publicNetworkAccess -ine 'Disabled') { throw 'Private succeeded dependency required; runner connectivity remains a separate check' }
        }
    }
    $accountHosts = @(Read-StandardArm $State "$($Binding.accountId)/capabilityHosts" '2026-05-01' 'account-hosts' -List)
    $projectHosts = @(Read-StandardArm $State "$($Binding.projectId)/capabilityHosts" '2026-05-01' 'project-hosts' -List)
    Assert-StandardHosts $State $Binding $SelectedStage $accountHosts $projectHosts $StorageName -Reconcile:$Reconcile
    if ($SelectedStage -eq 'access') {
        $containerWorkspace = ([guid]$Binding.parameters.workspaceId.value).ToString('D')
        $agentName = $Binding.parameters.agentContainerName.value
        if ($agentName -isnot [string] -or $agentName -cnotmatch ('^' + [regex]::Escape($containerWorkspace) + '-(?:[a-f0-9]{12}-)?azureml-agent$')) { throw 'Invalid bound agent container name' }
        foreach ($containerName in @("$containerWorkspace-azureml-blobstore",$agentName)) { $null = Read-StandardArm $State "$($Binding.casePrefix)/providers/Microsoft.Storage/storageAccounts/$StorageName/blobServices/default/containers/$containerName" '2023-05-01' 'container-scope' }
        $null = Read-StandardArm $State "$($Binding.casePrefix)/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-fgl-$($State.labId)-standard/sqlDatabases/enterprise_memory" '2024-11-15' 'database'
    }
    if ($accountHosts.Count -eq 1) { return $accountHosts[0].id }
}

function Write-StandardJson([string]$Path, $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $Path, $true)
}

if ($DefinitionsOnly) { return }
$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    if (-not $StatePath -or -not $Stage) { throw 'StatePath and Stage required unless DefinitionsOnly' }
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    $state = Read-LabRun $StatePath
    if (-not $state.ContainsKey('standard')) { $state.standard = @{completedStages=@(); pendingStage=$null; deploymentNames=@{}; review=$null} }
    Assert-StandardState $state $Stage $Action
    $lab = Get-Content -LiteralPath (Join-Path $state.runDirectory 'outputs.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $binding = Get-StandardLiveBindings $state $lab
    $binding.parameters.stage = @{value=$Stage}
    $deploymentName = "fgl-$($state.labId)-standard-$Stage"
    $templatePath = Join-Path $state.runDirectory "standard-$Stage.template.json"
    $parametersPath = Join-Path $state.runDirectory "standard-$Stage.parameters.json"
    $outputsPath = Join-Path $state.runDirectory 'standard-outputs.json'
    $outputs = @{}; $storageName = $null
    if (Test-Path -LiteralPath $outputsPath) { $outputs = Get-Content -LiteralPath $outputsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 }
    if ($Stage -ne 'dependencies') {
        $storageName = $outputs.dependencies.storage.name
        if ($storageName -isnot [string] -or $storageName -cnotmatch ('^stfgl' + [regex]::Escape($state.labId) + '[a-z0-9]{6}$') -or $outputs.dependencies.storage.id -ine "$($binding.casePrefix)/providers/Microsoft.Storage/storageAccounts/$storageName" -or $outputs.dependencies.projectId -ine $binding.projectId -or $outputs.dependencies.projectPrincipalId -ine $binding.parameters.projectPrincipalId.value -or $outputs.dependencies.workspaceId -ine $binding.parameters.workspaceId.value) { throw 'Missing or inconsistent completed dependency outputs' }
    }
    if ($Action -eq 'Status') {
        $deployment = Invoke-LabAz $state @('deployment','sub','show','--name',$deploymentName) 'standard-status'
        if ($deployment.id -ine "/subscriptions/$($state.subscriptionId)/providers/Microsoft.Resources/deployments/$deploymentName") { throw 'Deployment identity mismatch' }
        $status = $deployment.properties.provisioningState
        if ($status -isnot [string] -or -not $status) { throw 'Missing deployment provisioning state' }
        if ($status -in @('Failed','Canceled')) {
            $null = Invoke-LabAz $state @('deployment','operation','sub','list','--name',$deploymentName) 'standard-failed-operations'
            foreach ($group in $state.resourceGroups) {
                $nested = @(Invoke-LabAz $state @('deployment','group','list','--resource-group',$group) 'standard-failed-nested')
                foreach ($child in @($nested | Where-Object { $_.properties.provisioningState -in @('Failed','Canceled') })) { $null = Invoke-LabAz $state @('deployment','operation','group','list','--resource-group',$group,'--name',$child.name) 'standard-failed-child-operations' }
            }
            throw "Deployment $status; pending retained; no retry or teardown authorized by this script"
        }
        if ($status -cne 'Succeeded') { Write-Output "Standard $Stage provisioning: $status; pending retained"; return }
        Confirm-StandardIdle $state
        Assert-StandardReview $state.standard.review $Stage $templatePath $parametersPath $binding.parameters -Submitted
        $actualOutput = $deployment.properties.outputs.standard.value
        foreach ($key in @('labId','ownershipId','stage','projectPrincipalId','workspaceId')) { if ($actualOutput[$key] -isnot [string] -or $actualOutput[$key] -cne $binding.parameters[$key].value) { throw 'Deployment output binding mismatch' } }
        if ($actualOutput.accountId -ine $binding.accountId -or $actualOutput.projectId -ine $binding.projectId -or $actualOutput.storage.name -cne $state.standard.review.storageName) { throw 'Deployment output resource mismatch' }
        $storageName = $actualOutput.storage.name
        $hostId = Confirm-StandardPrerequisites $state $binding $Stage $storageName -Reconcile
        if ($Stage -eq 'account') { if (-not $hostId) { throw 'Account host missing after success' }; $state.standard.accountHostId = $hostId; $actualOutput.capabilityHosts.account = $hostId }
        $outputs[$Stage] = $actualOutput
        Write-StandardJson $outputsPath $outputs
        $state.standard.completedStages += $Stage; $state.standard.pendingStage = $null
        Save-LabRun $state $StatePath
        Write-Output "Standard $Stage succeeded. Private runner verification and actual agent inference remain separate."
        return
    }
    Confirm-StandardIdle $state
    $hostId = Confirm-StandardPrerequisites $state $binding $Stage $storageName
    $reuse = $Stage -eq 'account' -and [bool]$hostId
    $common = @('--location','swedencentral','--name',$deploymentName,'--template-file',$templatePath,'--parameters',"@$parametersPath")
    if ($Action -eq 'Preview') {
        & $state.bicepExecutable build (Join-Path $PSScriptRoot '../infra/standard.bicep') --outfile $templatePath
        if ($LASTEXITCODE -ne 0) { throw 'Standard Bicep compilation failed' }
        & (Join-Path $PSScriptRoot '../tests/Test-StandardTemplate.ps1') -Path $templatePath
        Write-StandardJson $parametersPath @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion='1.0.0.0'; parameters=$binding.parameters}
    } else { Assert-StandardReview $state.standard.review $Stage $templatePath $parametersPath $binding.parameters; $storageName = $state.standard.review.storageName }
    if ($reuse) {
        if ($Action -eq 'Deploy') {
            $freshBinding = Get-StandardLiveBindings $state $lab; $freshBinding.parameters.stage = @{value=$Stage}
            Assert-StandardReview $state.standard.review $Stage $templatePath $parametersPath $freshBinding.parameters
            $hostId = Confirm-StandardPrerequisites $state $freshBinding $Stage $storageName
            Confirm-StandardIdle $state
            if ($state.standard.review.reusedHostId -ine $hostId) { throw 'Account host changed since verification preview' }
            $state.standard.accountHostId = $hostId; $state.standard.completedStages += 'account'
            $outputs.account = @{stage='account'; reused=$true; capabilityHosts=@{account=$hostId}}
            Write-StandardJson $outputsPath $outputs
        }
    } else {
        if ($Action -eq 'Deploy' -and $state.standard.review.reusedHostId) { throw 'Previously verified immutable host disappeared' }
        $null = Invoke-LabAz $state (@('deployment','sub','validate') + $common) 'standard-validate'
        $preview = Invoke-LabAz $state (@('deployment','sub','what-if','--no-pretty-print') + $common) 'standard-whatif'
        if ($Stage -eq 'dependencies' -and $Action -eq 'Preview') {
            $storageChanges = @($preview.changes | Where-Object { $_.resourceId -match ('^' + [regex]::Escape($binding.casePrefix) + '/providers/Microsoft.Storage/storageAccounts/stfgl' + [regex]::Escape($state.labId) + '[a-z0-9]{6}$') -and $_.changeType -in @('Create','Modify','NoChange') })
            if ($storageChanges.Count -ne 1) { throw 'ARM-evaluated Standard storage name missing or ambiguous' }
            $storageName = ($storageChanges[0].resourceId -split '/')[-1]
        }
        Assert-StandardWhatIf $state $binding $Stage $preview $storageName
        if ($Action -eq 'Deploy') {
            $freshBinding = Get-StandardLiveBindings $state $lab; $freshBinding.parameters.stage = @{value=$Stage}
            Assert-StandardReview $state.standard.review $Stage $templatePath $parametersPath $freshBinding.parameters
            $freshHost = Confirm-StandardPrerequisites $state $freshBinding $Stage $storageName
            if ($Stage -eq 'account' -and $freshHost) { throw 'Account host appeared; creation blocked' }
            Confirm-StandardIdle $state
            $state.standard.pendingStage = $Stage; $state.standard.deploymentNames[$Stage] = $deploymentName
            if ($Stage -eq 'account') { $state.standard.accountHostId = "$($binding.accountId)/capabilityHosts/agents" }
            Save-LabRun $state $StatePath
            $null = Invoke-LabAz $state (@('deployment','sub','create') + $common + @('--no-wait')) 'standard-start'
            Write-Output 'Standard deployment submitted; use Status. No teardown performed.'
            return
        }
    }
    if ($Action -eq 'Preview') { $state.standard.review = @{stage=$Stage; checkedAt=[DateTimeOffset]::UtcNow.ToString('o'); templateHash=(Get-FileHash $templatePath).Hash; parametersHash=(Get-FileHash $parametersPath).Hash; storageName=$storageName; reusedHostId=$(if ($reuse) { $hostId } else { $null })} }
    Save-LabRun $state $StatePath
    Write-Output $(if ($reuse) { 'Account host verification only: no ARM PUT, DELETE, or deployment submission.' } else { 'Standard preview passed; template and parameters hashed.' })
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }