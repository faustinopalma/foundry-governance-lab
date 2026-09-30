[CmdletBinding()]
param(
    [string]$StatePath,
    [ValidateSet('lock', 'activate')][string]$Phase,
    [switch]$DefinitionsOnly
)

function Test-ControlPlaneContextSafety {
    param([scriptblock]$Command)

    $calls = @($Command.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-LabAz'
    }, $true))
    if ($calls.Count -eq 0) { return $false }
    foreach ($call in $calls) {
        $arrays = @($call.FindAll({ param($node) $node -is [Management.Automation.Language.ArrayExpressionAst] }, $true))
        if ($arrays.Count -ne 1) { return $false }
        $arguments = @($arrays[0].FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
        if ($arguments.Count -eq 2 -and $arguments[0] -eq 'account' -and $arguments[1] -eq 'show') { continue }
        if ($arguments.Count -eq 2 -and $arguments[0] -eq 'group' -and $arguments[1] -eq 'list') { continue }
        if ($arguments.Count -eq 3 -and $arguments[0] -eq 'group' -and $arguments[1] -eq 'show' -and $arguments[2] -eq '--name' -and $arrays[0].Extent.Text -cmatch '--name''\s*,\s*\$groupName\s*\)') { continue }
        return $false
    }
    return $true
}

function Test-ControlPlaneAddress {
    param([string]$Address, [string]$Prefix)

    $parsedAddress = $null
    $parsedNetwork = $null
    $parts = $Prefix.Split('/')
    if ($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($Address, [ref]$parsedAddress) -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$parsedNetwork)) { return $false }
    if ($parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsedNetwork.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $bits = 0
    if (-not [int]::TryParse($parts[1], [ref]$bits) -or $bits -lt 1 -or $bits -gt 30) { return $false }
    $addressBytes = $parsedAddress.GetAddressBytes()
    $networkBytes = $parsedNetwork.GetAddressBytes()
    $private = $addressBytes[0] -eq 10 -or ($addressBytes[0] -eq 172 -and $addressBytes[1] -ge 16 -and $addressBytes[1] -le 31) -or ($addressBytes[0] -eq 192 -and $addressBytes[1] -eq 168)
    if (-not $private) { return $false }
    [uint64]$addressNumber = 0
    [uint64]$networkNumber = 0
    foreach ($index in 0..3) {
        $addressNumber = ($addressNumber -shl 8) + $addressBytes[$index]
        $networkNumber = ($networkNumber -shl 8) + $networkBytes[$index]
    }
    $size = [uint64][math]::Pow(2, 32 - $bits)
    return [math]::Floor($addressNumber / $size) -eq [math]::Floor($networkNumber / $size) -and $addressNumber % $size -ge 4 -and $addressNumber % $size -lt $size - 1
}

function Get-ControlPlaneStatus {
    param([object[]]$Statuses)

    if ('FAIL' -in $Statuses) { return 'FAIL' }
    if ('BLOCKED' -in $Statuses) { return 'BLOCKED' }
    if ($Statuses.Count -eq 0 -or @($Statuses | Where-Object { $_ -ne 'PASS' }).Count) { return 'INCONCLUSIVE' }
    return 'PASS'
}

function Test-ControlPlaneIdSet {
    param([object[]]$Actual, [object[]]$Expected)

    if ($Actual.Count -ne $Expected.Count -or @($Actual | Sort-Object -Unique).Count -ne $Actual.Count) { return $false }
    if ($Actual.Count -eq 0) { return $true }
    return @(Compare-Object $Actual $Expected).Count -eq 0
}

function Get-ControlPlanePlan {
    param([hashtable]$State, [hashtable]$Lab, [string]$ExpectedPhase)

    Assert-LabState $State
    if ($ExpectedPhase -notin @('lock', 'activate') -or $State.phase -ne $ExpectedPhase -or $Lab.phase -ne $ExpectedPhase -or $State.pendingPhase) { throw 'A completed matching lock or activate phase is required' }
    if (-not (Test-ControlPlaneIdSet @($Lab.resourceGroups) @($State.resourceGroups))) { throw 'Output group set mismatch' }
    $stem = "fgl-$($State.labId)"
    $groupIds = @{}
    foreach ($suffix in @('models', 'integration', 'case-a', 'case-b')) { $groupIds[$suffix] = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-$stem-$suffix" }
    $modelPrefix = "$($groupIds.models)/providers/Microsoft.CognitiveServices/accounts/aif-$stem-models-"
    if ($Lab.models -notmatch ('^' + [regex]::Escape($modelPrefix) + '([a-z0-9]{13})$')) { throw 'Unexpected central Foundry resource ID' }
    $uniqueSuffix = $Matches[1]
    $resources = [ordered]@{
        models = @{ id=$Lab.models; api='2026-05-01'; type='Microsoft.CognitiveServices/accounts' }
        gateway = @{ id="$($groupIds.integration)/providers/Microsoft.ApiManagement/service/apim-$stem-$uniqueSuffix"; api='2024-05-01'; type='Microsoft.ApiManagement/service' }
        runner = @{ id="$($groupIds.integration)/providers/Microsoft.Compute/virtualMachines/vm-$stem-runner"; api='2024-07-01'; type='Microsoft.Compute/virtualMachines' }
        network = @{ id="$($groupIds.integration)/providers/Microsoft.Network/virtualNetworks/vnet-$stem"; api='2024-05-01'; type='Microsoft.Network/virtualNetworks' }
        monitor = @{ id="$($groupIds.integration)/providers/Microsoft.Insights/privateLinkScopes/ampls-$stem"; api='2021-07-01-preview'; type='Microsoft.Insights/privateLinkScopes' }
    }
    if ($Lab.gateway -ine $resources.gateway.id -or $Lab.runner -ine $resources.runner.id -or @($Lab.cases).Count -ne 2) { throw 'Unexpected gateway, runner or case outputs' }
    $projects = @{}
    foreach ($caseIndex in 0..1) {
        $caseId = @('a', 'b')[$caseIndex]
        $caseOutput = $Lab.cases[$caseIndex]
        $accountId = "$($groupIds["case-$caseId"])/providers/Microsoft.CognitiveServices/accounts/aif-$stem-$caseId-$uniqueSuffix"
        $registryId = "$($groupIds["case-$caseId"])/providers/Microsoft.ContainerRegistry/registries/crfgl$($State.labId)$caseId$uniqueSuffix"
        if ($caseOutput.accountId -ine $accountId -or $caseOutput.registryId -ine $registryId) { throw 'Unexpected case resource IDs' }
        $projects["case-$caseId"] = @('dev', 'test') | ForEach-Object { "$accountId/projects/case-$caseId-$_" }
        if (-not (Test-ControlPlaneIdSet @($caseOutput.projects | ForEach-Object { $_.resourceId }) $projects["case-$caseId"])) { throw 'Unexpected project outputs' }
        $resources["case-$caseId"] = @{id=$accountId; api='2026-05-01'; type='Microsoft.CognitiveServices/accounts'}
        $resources["registry-$caseId"] = @{id=$registryId; api='2025-11-01'; type='Microsoft.ContainerRegistry/registries'}
    }
    $actors = @('dev-a', 'consumer-a', 'dev-b', 'publisher-a', 'publisher-b', 'client', 'denied')
    if (-not (Test-ControlPlaneIdSet @($Lab.identities | ForEach-Object { $_.actor }) $actors)) { throw 'Exactly seven named test identities are required' }
    foreach ($actor in $actors) {
        $actorOutput = @($Lab.identities | Where-Object { $_.actor -eq $actor })[0]
        $identityId = "$($groupIds.integration)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-$stem-$actor"
        if ($actorOutput.resourceId -ine $identityId) { throw 'Unexpected test identity resource ID' }
        foreach ($field in @('principalId', 'clientId')) {
            $parsed = [guid]::Empty
            if (-not [guid]::TryParse([string]$actorOutput[$field], [ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'Invalid identity output' }
        }
        $resources["identity-$actor"] = @{id=$identityId; api='2023-01-31'; type='Microsoft.ManagedIdentity/userAssignedIdentities'; principalId=$actorOutput.principalId; clientId=$actorOutput.clientId}
    }
    foreach ($field in @('principalId', 'clientId')) {
        if (@($Lab.identities | ForEach-Object { $_[$field] } | Sort-Object -Unique).Count -ne 7) { throw 'Test identities must be distinct' }
    }
    $endpoints = @()
    foreach ($entry in @(
        @('models', 'models', 'account', 'snet-models-pe', '10.76.5.0/27'),
        @('case-a', 'case-a', 'account', 'snet-case-a-pe', '10.76.6.0/27'),
        @('case-b', 'case-b', 'account', 'snet-case-b-pe', '10.76.7.0/27'),
        @('registry-a', 'case-a', 'registry', 'snet-case-a-pe', '10.76.6.0/27'),
        @('registry-b', 'case-b', 'registry', 'snet-case-b-pe', '10.76.7.0/27'),
        @('gateway', 'integration', 'Gateway', 'snet-integration-pe', '10.76.8.0/27'),
        @('monitor', 'integration', 'azuremonitor', 'snet-integration-pe', '10.76.8.0/27')
    )) {
        $endpoints += @{key=$entry[0]; id="$($groupIds[$entry[1]])/providers/Microsoft.Network/privateEndpoints/pe-$stem-$($entry[0])"; targetId=$resources[$entry[0]].id; groupId=$entry[2]; subnetId="$($resources.network.id)/subnets/$($entry[3])"; prefix=$entry[4]}
    }
    foreach ($resource in $resources.Values) { Assert-LabResourceId $State $resource.id }
    return @{resources=$resources; groups=$groupIds; projects=$projects; actors=$actors; endpoints=$endpoints; phase=$ExpectedPhase}
}

function Invoke-ControlPlaneGet {
    param([hashtable]$State, [string]$Id, [string]$Api, [string]$Label, [string]$Query, [switch]$Inherited, [switch]$AtScope)

    try {
        if ($Inherited) {
            $definitionPattern = '^(/subscriptions/' + [regex]::Escape($State.subscriptionId) + '|/providers/Microsoft.Management/managementGroups/[a-zA-Z0-9_.()-]+)?/providers/Microsoft.Authorization/roleDefinitions/[0-9a-fA-F-]{36}$'
            if ($Id -notmatch $definitionPattern) { throw 'Unexpected inherited role definition scope' }
        } else {
            $parentId = $Id
            if ($Id -match '^(.*)/providers/Microsoft.Authorization/roleAssignments$') {
                $parentId = $Matches[1]
            } elseif ($Id -match '^(.*?/resourceGroups/[^/]+)/resources$') {
                $parentId = $Matches[1]
            } elseif ($Id -match '^(.*?/providers/Microsoft.CognitiveServices/accounts/[^/]+)/(projects|deployments|privateEndpointConnections)$') {
                $parentId = $Matches[1]
            } elseif ($Id -match '^(.*?/providers/Microsoft.Network/virtualNetworks/[^/]+)/virtualNetworkPeerings$') {
                $parentId = $Matches[1]
            } elseif ($Id -match '^(.*?/providers/(Microsoft.ContainerRegistry/registries|Microsoft.ApiManagement/service|Microsoft.Insights/privateLinkScopes)/[^/]+)/privateEndpointConnections$') {
                $parentId = $Matches[1]
            }
            Assert-LabResourceId $State $parentId
        }
        if ($Api -notmatch '^\d{4}-\d{2}-\d{2}(-preview)?$' -or -not $Query) { throw 'Invalid read specification' }
        $url = "https://management.azure.com${Id}?api-version=$Api"
        if ($AtScope) { $url += '&$filter=atScope()' }
        $data = Invoke-LabAz $State @('rest', '--method', 'GET', '--url', $url, '--query', $Query) $Label
        if ($null -eq $data) { return @{status='INCONCLUSIVE'; reason='ARM response was empty'} }
        if ($data -is [hashtable] -and $data.nextLink) { return @{status='INCONCLUSIVE'; reason='Response is paginated; complete enumeration was not established'} }
        return @{status='PASS'; data=$data}
    } catch {
        return @{status='BLOCKED'; reason='Exact ARM GET could not be completed; inspect the private command log'}
    }
}

function Get-ControlPlaneData {
    param([hashtable]$Snapshot, [string]$Key, [switch]$List)

    if (-not $Snapshot.ContainsKey($Key)) { throw 'BLOCKED' }
    $entry = $Snapshot[$Key]
    if ($entry.status -ne 'PASS') { throw $entry.status }
    if ($entry.data -is [hashtable] -and $entry.data.nextLink) { throw 'INCONCLUSIVE' }
    if ($List) {
        if ($entry.data -isnot [hashtable] -or -not $entry.data.ContainsKey('value') -or $null -eq $entry.data.value -or $entry.data.value -isnot [array]) { throw 'INCONCLUSIVE' }
        return ,$entry.data.value
    }
    if ($entry.data -isnot [hashtable]) { throw 'INCONCLUSIVE' }
    return $entry.data
}

function Assert-ControlPlaneFields {
    param($Object, [string[]]$Names)

    if ($Object -isnot [hashtable]) { throw 'INCONCLUSIVE' }
    foreach ($name in $Names) { if (-not $Object.ContainsKey($name) -or $null -eq $Object[$name]) { throw 'INCONCLUSIVE' } }
}

function Add-ControlPlaneCheck {
    param([System.Collections.Generic.List[object]]$Checks, [string]$Name, [string]$Reason, [scriptblock]$Test)

    try {
        $outcome = & $Test
        $status = if ($outcome -is [bool]) { if ($outcome) { 'PASS' } else { 'FAIL' } } else { 'INCONCLUSIVE' }
    } catch { $status = if ($_.Exception.Message -in @('BLOCKED', 'INCONCLUSIVE')) { $_.Exception.Message } else { 'INCONCLUSIVE' } }
    $Checks.Add(@{test=$Name; status=$status; reason=$Reason})
}

function Get-ControlPlaneSnapshot {
    param([hashtable]$State, [hashtable]$Plan)

    $snapshot = @{}
    $resourceQuery = '{id:id,type:type,tags:tags,kind:kind,identity:{principalId:identity.principalId},properties:{provisioningState:properties.provisioningState,publicNetworkAccess:properties.publicNetworkAccess,disableLocalAuth:properties.disableLocalAuth,allowProjectManagement:properties.allowProjectManagement,adminUserEnabled:properties.adminUserEnabled,anonymousPullEnabled:properties.anonymousPullEnabled,roleAssignmentMode:properties.roleAssignmentMode,networkProfile:properties.networkProfile,subnets:properties.subnets,principalId:properties.principalId,clientId:properties.clientId}}'
    foreach ($entry in $Plan.groups.GetEnumerator()) {
        $snapshot["group-$($entry.Key)"] = Invoke-ControlPlaneGet $State $entry.Value '2025-04-01' "cp-group-$($entry.Key)" '{id:id,name:name,tags:tags}'
        $group = Get-ControlPlaneData $snapshot "group-$($entry.Key)"
        Assert-LabGroupOwnership $State $group
        if ($group.id -in $State.preexistingGroupIds) { throw 'Pre-existing group cannot be inspected as an owned lab group' }
    }
    foreach ($entry in $Plan.groups.GetEnumerator()) {
        $snapshot["inventory-$($entry.Key)"] = Invoke-ControlPlaneGet $State "$($entry.Value)/resources" '2021-04-01' "cp-inventory-$($entry.Key)" '{value:value[].{id:id,type:type},nextLink:nextLink}'
    }
    foreach ($entry in $Plan.resources.GetEnumerator()) {
        $snapshot[$entry.Key] = Invoke-ControlPlaneGet $State $entry.Value.id $entry.Value.api "cp-$($entry.Key)" $resourceQuery
    }
    foreach ($key in @('models', 'case-a', 'case-b')) {
        foreach ($child in @('projects', 'deployments')) {
            $snapshot["$key-$child"] = Invoke-ControlPlaneGet $State "$($Plan.resources[$key].id)/$child" '2026-05-01' "cp-$key-$child" '{value:value[].{id:id,name:name},nextLink:nextLink}'
        }
    }
    $snapshot.peerings = Invoke-ControlPlaneGet $State "$($Plan.resources.network.id)/virtualNetworkPeerings" '2024-05-01' 'cp-peerings' '{value:value[].{id:id},nextLink:nextLink}'
    foreach ($endpoint in $Plan.endpoints) {
        $snapshot["pe-$($endpoint.key)"] = Invoke-ControlPlaneGet $State $endpoint.id '2024-05-01' "cp-pe-$($endpoint.key)" '{id:id,properties:{provisioningState:properties.provisioningState,subnet:properties.subnet,privateLinkServiceConnections:properties.privateLinkServiceConnections,manualPrivateLinkServiceConnections:properties.manualPrivateLinkServiceConnections,networkInterfaces:properties.networkInterfaces,customDnsConfigs:properties.customDnsConfigs}}'
        $target = $Plan.resources[$endpoint.key]
        $snapshot["connections-$($endpoint.key)"] = Invoke-ControlPlaneGet $State "$($target.id)/privateEndpointConnections" $target.api "cp-connections-$($endpoint.key)" '{value:value[].{id:id,properties:{privateEndpoint:properties.privateEndpoint,privateLinkServiceConnectionState:properties.privateLinkServiceConnectionState}},nextLink:nextLink}'
        try {
            $resource = Get-ControlPlaneData $snapshot "pe-$($endpoint.key)"
            foreach ($nic in @($resource.properties.networkInterfaces)) {
                if ($nic.id -notmatch ('^' + [regex]::Escape(($endpoint.id -split '/providers/')[0]) + '/providers/Microsoft.Network/networkInterfaces/[^/%?#\\]+$')) { throw 'Invalid NIC scope' }
                $snapshot[$nic.id] = Invoke-ControlPlaneGet $State $nic.id '2024-05-01' "cp-nic-$($endpoint.key)" '{id:id,properties:{privateEndpoint:properties.privateEndpoint,ipConfigurations:properties.ipConfigurations}}'
            }
        } catch { $snapshot["nic-error-$($endpoint.key)"] = @{status='BLOCKED'} }
    }
    try {
        $runner = Get-ControlPlaneData $snapshot 'runner'
        foreach ($nic in @($runner.properties.networkProfile.networkInterfaces)) {
            if ($nic.id -notmatch ('^' + [regex]::Escape($Plan.groups.integration) + '/providers/Microsoft.Network/networkInterfaces/[^/%?#\\]+$')) { throw 'Invalid runner NIC scope' }
            $snapshot[$nic.id] = Invoke-ControlPlaneGet $State $nic.id '2024-05-01' 'cp-runner-nic' '{id:id,properties:{virtualMachine:properties.virtualMachine,ipConfigurations:properties.ipConfigurations}}'
        }
    } catch { $snapshot['nic-error-runner'] = @{status='BLOCKED'} }
    $roleScopes = Get-ControlPlaneRoleScopes $Plan
    $actorFilter = @($Plan.actors | ForEach-Object { "properties.principalId=='$($Plan.resources["identity-$_"].principalId)'" }) -join ' || '
    $roleQuery = "{value:value[?$actorFilter].{id:id,properties:{scope:properties.scope,principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,condition:properties.condition}},nextLink:nextLink}"
    $roleIndex = 0
    foreach ($scope in $roleScopes) {
        $snapshot["roles-$scope"] = Invoke-ControlPlaneGet $State "$scope/providers/Microsoft.Authorization/roleAssignments" '2022-04-01' "cp-roles-$roleIndex" $roleQuery -AtScope
        $roleIndex++
    }
    $snapshot.roleScopes = $roleScopes
    $openAiRole = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    $centralQuery = "{value:value[?ends_with(properties.roleDefinitionId, '/$openAiRole')].{id:id,properties:{scope:properties.scope,principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,condition:properties.condition}},nextLink:nextLink}"
    $snapshot['central-roles'] = Invoke-ControlPlaneGet $State "$($Plan.resources.models.id)/providers/Microsoft.Authorization/roleAssignments" '2022-04-01' 'cp-central-roles' $centralQuery -AtScope
    $definitionIndex = 0
    foreach ($scope in $roleScopes) {
        try {
            foreach ($assignment in (Get-ControlPlaneData $snapshot "roles-$scope" -List)) {
                $definitionId = [string]$assignment.properties.roleDefinitionId
                if ($definitionId -and -not $snapshot.ContainsKey($definitionId)) {
                    $snapshot[$definitionId] = Invoke-ControlPlaneGet $State $definitionId '2022-04-01' "cp-role-definition-$definitionIndex" '{id:id,properties:{roleName:properties.roleName,permissions:properties.permissions}}' -Inherited
                    $definitionIndex++
                }
            }
        } catch { continue }
    }
    return $snapshot
}

function Get-ControlPlaneRoleScopes {
    param([hashtable]$Plan)

    return @($Plan.groups.Values) + @('models', 'case-a', 'case-b', 'registry-a', 'registry-b', 'gateway', 'runner', 'network' | ForEach-Object { $Plan.resources[$_].id }) + @($Plan.projects.Values | ForEach-Object { $_ })
}

function Get-ControlPlaneEndpointEvidence {
    param([hashtable]$Plan, [hashtable]$Snapshot, [hashtable]$Endpoint)

    $resource = Get-ControlPlaneData $Snapshot "pe-$($Endpoint.key)"
    Assert-ControlPlaneFields $resource @('id', 'properties')
    Assert-ControlPlaneFields $resource.properties @('provisioningState', 'subnet', 'networkInterfaces', 'privateLinkServiceConnections')
    $connections = @($resource.properties.privateLinkServiceConnections) + @($resource.properties.manualPrivateLinkServiceConnections | Where-Object { $null -ne $_ })
    $valid = $resource.id -ieq $Endpoint.id -and $resource.properties.provisioningState -eq 'Succeeded' -and $resource.properties.subnet.id -ieq $Endpoint.subnetId -and $connections.Count -eq 1
    foreach ($connection in $connections) {
        Assert-ControlPlaneFields $connection.properties @('privateLinkServiceId', 'groupIds', 'privateLinkServiceConnectionState')
        Assert-ControlPlaneFields $connection.properties.privateLinkServiceConnectionState @('status')
        $valid = $valid -and $connection.properties.privateLinkServiceId -ieq $Endpoint.targetId -and (Test-ControlPlaneIdSet @($connection.properties.groupIds) @($Endpoint.groupId)) -and $connection.properties.privateLinkServiceConnectionState.status -eq 'Approved'
    }
    $targetConnections = Get-ControlPlaneData $Snapshot "connections-$($Endpoint.key)" -List
    $matched = @($targetConnections | Where-Object { $_.properties.privateEndpoint.id -ieq $Endpoint.id })
    $valid = $valid -and $matched.Count -eq 1
    foreach ($connection in $matched) {
        Assert-ControlPlaneFields $connection.properties.privateLinkServiceConnectionState @('status')
        $valid = $valid -and $connection.id.StartsWith("$($Endpoint.targetId)/privateEndpointConnections/", [StringComparison]::OrdinalIgnoreCase) -and $connection.properties.privateLinkServiceConnectionState.status -eq 'Approved'
    }
    $network = Get-ControlPlaneData $Snapshot 'network'
    Assert-ControlPlaneFields $network.properties @('subnets')
    $subnets = @($network.properties.subnets | Where-Object { $_.id -ieq $Endpoint.subnetId })
    $valid = $valid -and $subnets.Count -eq 1
    foreach ($subnet in $subnets) {
        $prefixes = @($subnet.properties.addressPrefix | Where-Object { $_ }) + @($subnet.properties.addressPrefixes | Where-Object { $_ })
        if (-not $prefixes.Count) { throw 'INCONCLUSIVE' }
        $valid = $valid -and (Test-ControlPlaneIdSet $prefixes @($Endpoint.prefix))
    }
    $addresses = @()
    $nicIds = @()
    $valid = $valid -and @($resource.properties.networkInterfaces).Count -eq 1
    foreach ($reference in @($resource.properties.networkInterfaces)) {
        $nic = Get-ControlPlaneData $Snapshot $reference.id
        Assert-ControlPlaneFields $nic.properties @('privateEndpoint', 'ipConfigurations')
        $valid = $valid -and $nic.id -ieq $reference.id -and $nic.properties.privateEndpoint.id -ieq $Endpoint.id -and @($nic.properties.ipConfigurations).Count -gt 0
        $nicIds += $nic.id
        foreach ($configuration in @($nic.properties.ipConfigurations)) {
            Assert-ControlPlaneFields $configuration.properties @('privateIPAddress', 'subnet')
            $valid = $valid -and -not $configuration.properties.publicIPAddress -and $configuration.properties.subnet.id -ieq $Endpoint.subnetId -and (Test-ControlPlaneAddress $configuration.properties.privateIPAddress $Endpoint.prefix)
            $addresses += $configuration.properties.privateIPAddress
        }
    }
    $dns = @()
    foreach ($configuration in @($resource.properties.customDnsConfigs | Where-Object { $null -ne $_ })) {
        Assert-ControlPlaneFields $configuration @('fqdn', 'ipAddresses')
        if (-not @($configuration.ipAddresses).Count) { throw 'INCONCLUSIVE' }
        foreach ($address in $configuration.ipAddresses) { $valid = $valid -and $address -in $addresses }
        $dns += @{fqdn=$configuration.fqdn; addresses=@($configuration.ipAddresses)}
    }
    $valid = $valid -and $addresses.Count -gt 0 -and @($addresses | Sort-Object -Unique).Count -eq $addresses.Count
    return @{status=$(if ($valid) { 'PASS' } else { 'FAIL' }); endpointId=$Endpoint.id; targetId=$Endpoint.targetId; subnetId=$Endpoint.subnetId; prefix=$Endpoint.prefix; nicIds=$nicIds; addresses=$addresses; serviceDns=$dns; ownershipSource='ARM private endpoint, target connection, NIC backlink and subnet'; dnsResolutionVerified=$false}
}

function Get-ControlPlaneRoleRisk {
    param([hashtable]$Definition)

    Assert-ControlPlaneFields $Definition.properties @('roleName', 'permissions')
    if ($Definition.properties.roleName -in @('Owner', 'Contributor', 'User Access Administrator', 'Role Based Access Control Administrator', 'Cognitive Services Contributor', 'Cognitive Services OpenAI User', 'Azure AI Owner', 'Foundry Account Owner', 'Foundry Project Manager')) { return 'FAIL' }
    if (-not @($Definition.properties.permissions).Count) { return 'INCONCLUSIVE' }
    foreach ($permission in $Definition.properties.permissions) {
        Assert-ControlPlaneFields $permission @('actions', 'dataActions', 'notActions', 'notDataActions')
        if ('*' -in $permission.actions -and @($permission.notActions).Count -eq 0) { return 'FAIL' }
        if (@($permission.dataActions).Count -or @($permission.actions | Where-Object { $_ -notmatch '/read$' }).Count) { return 'INCONCLUSIVE' }
    }
    return 'PASS'
}

function Get-ControlPlaneReport {
    param([hashtable]$State, [hashtable]$Plan, [hashtable]$Snapshot)

    $checks = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Plan.groups.GetEnumerator()) {
        Add-ControlPlaneCheck $checks "GROUP-$($entry.Key)" 'Exact owned resource group and ownership tags' {
            $group = Get-ControlPlaneData $Snapshot "group-$($entry.Key)"
            Assert-ControlPlaneFields $group @('id', 'name', 'tags')
            try { Assert-LabGroupOwnership $State $group } catch { return $false }
            return $group.id -ieq $entry.Value -and $group.id -notin $State.preexistingGroupIds
        }
    }
    Add-ControlPlaneCheck $checks 'INVENTORY' 'Four owned groups contain exactly three Foundry resources, two registries, one gateway, one runner, one VNet, seven UAMI and seven private endpoints' {
        $inventory = @()
        foreach ($key in $Plan.groups.Keys) { $inventory += Get-ControlPlaneData $Snapshot "inventory-$key" -List }
        foreach ($resource in $inventory) { Assert-LabResourceId $State $resource.id }
        foreach ($type in @('Microsoft.CognitiveServices/accounts', 'Microsoft.ContainerRegistry/registries', 'Microsoft.ApiManagement/service', 'Microsoft.Compute/virtualMachines', 'Microsoft.Network/virtualNetworks', 'Microsoft.ManagedIdentity/userAssignedIdentities', 'Microsoft.Network/privateEndpoints')) {
            $expected = if ($type -eq 'Microsoft.Network/privateEndpoints') { @($Plan.endpoints | ForEach-Object { $_.id }) } else { @($Plan.resources.Values | Where-Object { $_.type -eq $type } | ForEach-Object { $_.id }) }
            if (-not (Test-ControlPlaneIdSet @($inventory | Where-Object { $_.type -eq $type } | ForEach-Object { $_.id }) $expected)) { return $false }
        }
        return $true
    }
    foreach ($key in @('models', 'case-a', 'case-b')) {
        Add-ControlPlaneCheck $checks "FOUNDRY-$key" 'AIServices resource has public access disabled and local authentication disabled' {
            $resource = Get-ControlPlaneData $Snapshot $key
            Assert-ControlPlaneFields $resource.properties @('publicNetworkAccess', 'disableLocalAuth', 'allowProjectManagement', 'provisioningState')
            return $resource.id -ieq $Plan.resources[$key].id -and $resource.kind -eq 'AIServices' -and $resource.properties.provisioningState -eq 'Succeeded' -and $resource.properties.publicNetworkAccess -eq 'Disabled' -and $resource.properties.disableLocalAuth -ceq $true -and $resource.properties.allowProjectManagement -ceq ($key -ne 'models')
        }
        Add-ControlPlaneCheck $checks "PROJECTS-$key" 'Central resource has no projects; each case has exactly its dev and test projects' {
            $projects = Get-ControlPlaneData $Snapshot "$key-projects" -List
            $expected = if ($key -eq 'models') { @() } else { $Plan.projects[$key] }
            return Test-ControlPlaneIdSet @($projects | ForEach-Object { $_.id }) @($expected)
        }
        Add-ControlPlaneCheck $checks "DEPLOYMENTS-$key" 'Only the central resource has exactly one lab-chat model deployment' {
            $deployments = Get-ControlPlaneData $Snapshot "$key-deployments" -List
            $expected = if ($key -eq 'models') { @("$($Plan.resources.models.id)/deployments/lab-chat") } else { @() }
            return Test-ControlPlaneIdSet @($deployments | ForEach-Object { $_.id }) @($expected)
        }
    }
    foreach ($key in @('registry-a', 'registry-b')) {
        Add-ControlPlaneCheck $checks "ACR-$key" 'Registry is private, admin and anonymous pull are disabled, repository ABAC is enabled' {
            $resource = Get-ControlPlaneData $Snapshot $key
            Assert-ControlPlaneFields $resource.properties @('publicNetworkAccess', 'adminUserEnabled', 'anonymousPullEnabled', 'roleAssignmentMode', 'provisioningState')
            return $resource.id -ieq $Plan.resources[$key].id -and $resource.properties.provisioningState -eq 'Succeeded' -and $resource.properties.publicNetworkAccess -eq 'Disabled' -and $resource.properties.adminUserEnabled -ceq $false -and $resource.properties.anonymousPullEnabled -ceq $false -and $resource.properties.roleAssignmentMode -eq 'AbacRepositoryPermissions'
        }
    }
    Add-ControlPlaneCheck $checks 'GATEWAY-PRIVATE' 'Gateway ARM property disables public ingress; this is not a private runner reachability test' {
        $gateway = Get-ControlPlaneData $Snapshot 'gateway'
        Assert-ControlPlaneFields $gateway.properties @('publicNetworkAccess', 'provisioningState')
        return $gateway.id -ieq $Plan.resources.gateway.id -and $gateway.properties.publicNetworkAccess -eq 'Disabled' -and $gateway.properties.provisioningState -eq 'Succeeded'
    }
    Add-ControlPlaneCheck $checks 'VNET-NO-PEERING' 'Exact owned VNet has no peerings' {
        $network = Get-ControlPlaneData $Snapshot 'network'
        $peerings = Get-ControlPlaneData $Snapshot 'peerings' -List
        return $network.id -ieq $Plan.resources.network.id -and $peerings.Count -eq 0
    }
    Add-ControlPlaneCheck $checks 'RUNNER-PRIVATE' 'Every runner NIC belongs to this VM, uses its private subnet and has no public IP association' {
        $runner = Get-ControlPlaneData $Snapshot 'runner'
        Assert-ControlPlaneFields $runner.properties.networkProfile @('networkInterfaces')
        $references = @($runner.properties.networkProfile.networkInterfaces)
        if ($references.Count -ne 1) { return $false }
        foreach ($reference in $references) {
            $nic = Get-ControlPlaneData $Snapshot $reference.id
            Assert-ControlPlaneFields $nic.properties @('virtualMachine', 'ipConfigurations')
            if ($nic.id -ine $reference.id -or $nic.properties.virtualMachine.id -ine $runner.id -or @($nic.properties.ipConfigurations).Count -eq 0) { return $false }
            foreach ($configuration in $nic.properties.ipConfigurations) {
                Assert-ControlPlaneFields $configuration.properties @('privateIPAddress', 'subnet')
                if ($configuration.properties.publicIPAddress -or $configuration.properties.subnet.id -ine "$($Plan.resources.network.id)/subnets/snet-runner" -or -not (Test-ControlPlaneAddress $configuration.properties.privateIPAddress '10.76.4.0/27')) { return $false }
            }
        }
        return $runner.id -ieq $Plan.resources.runner.id
    }
    $endpointEvidence = @()
    foreach ($endpoint in $Plan.endpoints) {
        try { $evidence = Get-ControlPlaneEndpointEvidence $Plan $Snapshot $endpoint } catch { $evidence = @{endpointId=$endpoint.id; status=$(if ($_.Exception.Message -eq 'BLOCKED') { 'BLOCKED' } else { 'INCONCLUSIVE' }); addresses=@()} }
        $endpointEvidence += $evidence
        $checks.Add(@{test="PE-$($endpoint.key)"; status=$evidence.status; reason='Both connection approvals, exact target and subnet, NIC backlink and actual IP ownership required'})
    }
    Add-ControlPlaneCheck $checks 'PE-UNIQUE-IP' 'Seven endpoint proofs must succeed and cannot claim the same IP' {
        if (@($endpointEvidence | Where-Object { $_.status -ne 'PASS' }).Count) { throw 'BLOCKED' }
        $addresses = @($endpointEvidence | ForEach-Object { $_.addresses })
        return $endpointEvidence.Count -eq 7 -and @($addresses | Sort-Object -Unique).Count -eq $addresses.Count
    }
    foreach ($actor in $Plan.actors) {
        Add-ControlPlaneCheck $checks "IDENTITY-$actor" 'Actual UAMI identifiers match the recorded deployment outputs' {
            $identity = Get-ControlPlaneData $Snapshot "identity-$actor"
            Assert-ControlPlaneFields $identity.properties @('principalId', 'clientId')
            return $identity.id -ieq $Plan.resources["identity-$actor"].id -and $identity.properties.principalId -eq $Plan.resources["identity-$actor"].principalId -and $identity.properties.clientId -eq $Plan.resources["identity-$actor"].clientId
        }
        Add-ControlPlaneCheck $checks "DIRECT-INHERITED-$actor" 'Checks direct principal assignments at exact lab scopes and ancestors; group-derived access is excluded' {
            if (@($checks | Where-Object { $_.test -eq "IDENTITY-$actor" -and $_.status -ne 'PASS' }).Count) { throw 'BLOCKED' }
            if (-not (Test-ControlPlaneIdSet @($Snapshot.roleScopes) @(Get-ControlPlaneRoleScopes $Plan))) { throw 'INCONCLUSIVE' }
            $unknown = $false
            foreach ($scope in $Snapshot.roleScopes) {
                foreach ($assignment in (Get-ControlPlaneData $Snapshot "roles-$scope" -List)) {
                    Assert-ControlPlaneFields $assignment.properties @('principalId', 'roleDefinitionId', 'scope')
                    if ($assignment.properties.principalId -ne $Plan.resources["identity-$actor"].principalId) { continue }
                    $risk = Get-ControlPlaneRoleRisk (Get-ControlPlaneData $Snapshot $assignment.properties.roleDefinitionId)
                    if ($risk -eq 'FAIL' -and -not $assignment.properties.condition) { return $false }
                    if ($risk -ne 'PASS') { $unknown = $true }
                }
            }
            if ($unknown) { throw 'INCONCLUSIVE' }
            return $true
        }
        $checks.Add(@{test="EFFECTIVE-INHERITED-$actor"; status='INCONCLUSIVE'; reason='Transitive Entra group membership and all effective authorization paths are not established by these ARM reads'})
    }
    Add-ControlPlaneCheck $checks 'CENTRAL-OPENAI-ASSIGNMENTS' 'Cognitive Services OpenAI User assignments at central resource and ancestors: absent in lock, exactly unconditional gateway MI at central scope in activate' {
        $assignments = Get-ControlPlaneData $Snapshot 'central-roles' -List
        if ($Plan.phase -eq 'lock') { return $assignments.Count -eq 0 }
        $gateway = Get-ControlPlaneData $Snapshot 'gateway'
        Assert-ControlPlaneFields $gateway.identity @('principalId')
        if (-not $gateway.identity.principalId -or $assignments.Count -ne 1) { return $false }
        $assignment = $assignments[0]
        Assert-ControlPlaneFields $assignment.properties @('principalId', 'scope', 'roleDefinitionId')
        return $assignment.properties.principalId -eq $gateway.identity.principalId -and $assignment.properties.scope -ieq $Plan.resources.models.id -and $assignment.properties.roleDefinitionId.EndsWith('/5e0bd9bd-7b93-4f28-af87-19fc36ad61bd', [StringComparison]::OrdinalIgnoreCase) -and -not $assignment.properties.condition
    }
    $checks.Add(@{test='CENTRAL-EFFECTIVE-INFERENCE'; status='INCONCLUSIVE'; reason='The named built-in role check does not prove absence of custom roles or other inference authorization paths'})
    $prerequisites = @($checks | Where-Object { $_.test -match '^(GROUP-|INVENTORY$|FOUNDRY-|ACR-|GATEWAY-PRIVATE$|VNET-NO-PEERING$|RUNNER-PRIVATE$|PE-)' })
    $privateEvidence = @{schemaVersion=1; phase=$Plan.phase; observedAt=[DateTimeOffset]::UtcNow.ToString('o'); prerequisiteStatus=(Get-ControlPlaneStatus @($prerequisites | ForEach-Object { $_.status })); gatewayId=$Plan.resources.gateway.id; runnerId=$Plan.resources.runner.id; endpoints=$endpointEvidence; checks=$prerequisites; privateRunnerPositiveRequired=$true; dnsResolutionVerified=$false}
    $checks.Add(@{test='C03'; status='BLOCKED'; reason='Control-plane prerequisites are recorded in privateAccessEvidence; a private runner positive and DNS-to-owned-IP comparison are still required'})
    return @{schemaVersion=1; phase=$Plan.phase; observedAt=[DateTimeOffset]::UtcNow.ToString('o'); status=(Get-ControlPlaneStatus @($checks | ForEach-Object { $_.status })); checks=$checks.ToArray(); privateAccessEvidence=$privateEvidence; limitations=@('Sequential ARM observations are not an atomic snapshot', 'No private runner connection, live DNS resolution or data-plane access was tested', 'No transitive group membership or complete effective RBAC proof', 'Paginated collections are inconclusive; continuation URLs are not followed')}
}

function Save-ControlPlaneReport {
    param([hashtable]$State, [string]$Path, [hashtable]$Report)

    $name = "control-plane-$($Report.phase)-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N')).json"
    $destination = Assert-ExternalLabPath (Join-Path $State.runDirectory $name)
    $Report.privateAccessEvidence.reportFile = $name
    $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        try { $writer.Write(($Report | ConvertTo-Json -Depth 100)) } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
    $State.privateAccessEvidence = $Report.privateAccessEvidence
    Save-LabRun $State $Path
    Write-Output "Control-plane status: $($Report.status); private report: $name"
}

if ($DefinitionsOnly) { return }
$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    if (-not $StatePath -or -not $Phase) { throw 'StatePath and Phase (lock or activate) are required' }
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or later is required' }
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
    $state = Read-LabRun $StatePath
    $report = @{schemaVersion=1; phase=$Phase; observedAt=[DateTimeOffset]::UtcNow.ToString('o'); status='BLOCKED'; checks=@(); privateAccessEvidence=@{schemaVersion=1; phase=$Phase; prerequisiteStatus='BLOCKED'; endpoints=@(); privateRunnerPositiveRequired=$true; dnsResolutionVerified=$false}}
    try {
        if (-not (Test-ControlPlaneContextSafety (Get-Command Confirm-LabRunContext -Module LabExecution).ScriptBlock)) {
            throw 'Confirm-LabRunContext must use exact group show reads; its current inventory implementation is not permitted'
        }
        $null = Confirm-LabRunContext $state
        $outputsPath = Assert-ExternalLabPath (Join-Path $state.runDirectory 'outputs.json')
        $lab = Get-Content -LiteralPath $outputsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $plan = Get-ControlPlanePlan $state $lab $Phase
        $snapshot = Get-ControlPlaneSnapshot $state $plan
        $report = Get-ControlPlaneReport $state $plan $snapshot
    } catch {
        $report.checks = @(@{test='CONTEXT-AND-INPUTS'; status='BLOCKED'; reason='Exact context confirmation, ownership or validated phase outputs were unavailable; no control-plane PASS is asserted'})
        $report.privateAccessEvidence.reason = 'An exact-scope Confirm-LabRunContext implementation and matching completed phase outputs are required'
    }
    Save-ControlPlaneReport $state $StatePath $report
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}