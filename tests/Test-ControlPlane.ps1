[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot '../scripts/Test-LabControlPlane.ps1') -DefinitionsOnly
    $script:passed = 0
    function Confirm-Equal($Actual, $Expected, [string]$Label) {
        if ($Actual -cne $Expected) { throw "Failed: $Label" }
        $script:passed++
    }
    Confirm-Equal (Test-ControlPlaneAddress '10.76.8.4' '10.76.8.0/27') $true 'Owned subnet address'
    Confirm-Equal (Test-ControlPlaneAddress '10.76.7.4' '10.76.8.0/27') $false 'Other private subnet'
    Confirm-Equal (Test-ControlPlaneAddress '10.76.8.3' '10.76.8.0/27') $false 'Reserved address'
    Confirm-Equal (Test-ControlPlaneAddress '10.76.8.31' '10.76.8.0/27') $false 'Broadcast address'
    Confirm-Equal (Test-ControlPlaneAddress '8.8.8.8' '8.8.8.0/24') $false 'Public address'
    Confirm-Equal (Test-ControlPlaneAddress 'invalid' '10.76.8.0/27') $false 'Malformed address'
    Confirm-Equal (Get-ControlPlaneStatus @()) 'INCONCLUSIVE' 'No empty pass'
    Confirm-Equal (Get-ControlPlaneStatus @('PASS', 'BLOCKED')) 'BLOCKED' 'Blocked aggregation'
    Confirm-Equal (Test-ControlPlaneContextSafety { Invoke-LabAz $State @('group', 'list') 'ownership' }) $true 'Read-only ownership inventory with exact group filtering'
    Confirm-Equal (Test-ControlPlaneContextSafety { Invoke-LabAz $State @('account', 'show') 'context' }) $true 'Context metadata'
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1')
    function az { throw 'Live Azure CLI is forbidden in local tests' }
    function Copy-Fixture([hashtable]$Value) { return ($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100) }
    function Confirm-Rejected([scriptblock]$Action, [string]$Label) {
        $rejected = $false
        try { $null = & $Action } catch { $rejected = $true }
        Confirm-Equal $rejected $true $Label
    }
    function Confirm-Check([hashtable]$Report, [string]$Name, [string]$Status) {
        $entries = @($Report.checks | Where-Object { $_.test -ceq $Name })
        Confirm-Equal $entries.Count 1 "$Name appears once"
        Confirm-Equal $entries[0].status $Status "$Name verdict"
    }
    $state = @{
        subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'; ownershipId='33333333-3333-4333-8333-333333333333'
        labId='sample01'; phase='lock'; pendingPhase=$null; preexistingGroupIds=@(); privateAccessVerified=$false
        resourceGroups=@('models', 'integration', 'case-a', 'case-b') | ForEach-Object { "rg-fgl-sample01-$_" }
    }
    $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01"
    $lab = @{
        phase='lock'; resourceGroups=$state.resourceGroups
        models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-abcdefghijklm"
        gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-abcdefghijklm"
        runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner"
        cases=@(); identities=@()
    }
    foreach ($caseId in @('a', 'b')) {
        $accountId = "$prefix-case-$caseId/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-$caseId-abcdefghijklm"
        $lab.cases += @{accountId=$accountId; registryId="$prefix-case-$caseId/providers/Microsoft.ContainerRegistry/registries/crfglsample01$($caseId)abcdefghijklm"; projects=@('dev', 'test') | ForEach-Object { @{resourceId="$accountId/projects/case-$caseId-$_"} }}
    }
    $actorIndex = 1
    foreach ($actor in @('dev-a', 'consumer-a', 'dev-b', 'publisher-a', 'publisher-b', 'client', 'denied')) {
        $lab.identities += @{actor=$actor; resourceId="$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-sample01-$actor"; principalId=([guid]::new([byte[]](1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $actorIndex))).ToString(); clientId=([guid]::new([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $actorIndex))).ToString()}
        $actorIndex++
    }
    $plan = Get-ControlPlanePlan $state $lab 'lock'
    Confirm-Equal $plan.endpoints.Count 7 'Seven exact endpoints'
    Confirm-Equal (Test-ControlPlaneIdSet @() @()) $true 'Empty list equality'
    Confirm-Equal (Test-ControlPlaneIdSet @('first', 'first') @('first', 'second')) $false 'Duplicate IDs rejected'
    $badLab = Copy-Fixture $lab
    $badLab.gateway += '-other'
    Confirm-Rejected { Get-ControlPlanePlan $state $badLab 'lock' } 'Wrong gateway ID'
    $badLab = Copy-Fixture $lab
    $badLab.identities[1].principalId = $badLab.identities[0].principalId
    Confirm-Rejected { Get-ControlPlanePlan $state $badLab 'lock' } 'Duplicate principals'
    Confirm-Rejected { Get-ControlPlanePlan $state $lab 'activate' } 'Phase mismatch'
    $fixture = @{}
    foreach ($entry in $plan.groups.GetEnumerator()) {
        $fixture["group-$($entry.Key)"] = @{status='PASS'; data=@{id=$entry.Value; name=($entry.Value -split '/')[-1]; tags=@{'fgl-lab'=$state.labId; 'fgl-owner'=$state.ownershipId}}}
        $inventory = @($plan.resources.Values | Where-Object { $_.id.StartsWith("$($entry.Value)/", [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { @{id=$_.id; type=$_.type} })
        $inventory += @($plan.endpoints | Where-Object { $_.id.StartsWith("$($entry.Value)/", [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { @{id=$_.id; type='Microsoft.Network/privateEndpoints'} })
        $fixture["inventory-$($entry.Key)"] = @{status='PASS'; data=@{value=$inventory}}
    }
    foreach ($entry in $plan.resources.GetEnumerator()) {
        $properties = @{provisioningState='Succeeded'; publicNetworkAccess='Disabled'; disableLocalAuth=$true; allowProjectManagement=($entry.Key -ne 'models'); adminUserEnabled=$false; anonymousPullEnabled=$false; roleAssignmentMode='AbacRepositoryPermissions'; principalId=$entry.Value.principalId; clientId=$entry.Value.clientId}
        $fixture[$entry.Key] = @{status='PASS'; data=@{id=$entry.Value.id; type=$entry.Value.type; kind='AIServices'; properties=$properties; identity=@{principalId=$state.ownershipId}}}
    }
    foreach ($key in @('models', 'case-a', 'case-b')) {
        $projectItems = if ($key -eq 'models') { @() } else { @($plan.projects[$key] | ForEach-Object { @{id=$_} }) }
        $deploymentItems = if ($key -eq 'models') { @(@{id="$($plan.resources.models.id)/deployments/lab-chat"}) } else { @() }
        $fixture["$key-projects"] = @{status='PASS'; data=@{value=@($projectItems)}}
        $fixture["$key-deployments"] = @{status='PASS'; data=@{value=@($deploymentItems)}}
    }
    $fixture.network.data.properties.subnets = @()
    $fixture.peerings = @{status='PASS'; data=@{value=@()}}
    $addressCounter = @{}
    foreach ($endpoint in $plan.endpoints) {
        if (-not $addressCounter.ContainsKey($endpoint.prefix)) {
            $addressCounter[$endpoint.prefix] = 4
            $fixture.network.data.properties.subnets += @{id=$endpoint.subnetId; properties=@{addressPrefix=$endpoint.prefix}}
        }
        $address = ($endpoint.prefix -replace '0/27$', [string]$addressCounter[$endpoint.prefix])
        $addressCounter[$endpoint.prefix]++
        $nicId = ($endpoint.id -split '/providers/')[0] + "/providers/Microsoft.Network/networkInterfaces/nic-$($endpoint.key)"
        $fixture["pe-$($endpoint.key)"] = @{status='PASS'; data=@{id=$endpoint.id; properties=@{provisioningState='Succeeded'; subnet=@{id=$endpoint.subnetId}; networkInterfaces=@(@{id=$nicId}); privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$endpoint.targetId; groupIds=@($endpoint.groupId); privateLinkServiceConnectionState=@{status='Approved'}}}); manualPrivateLinkServiceConnections=@(); customDnsConfigs=@(@{fqdn="$($endpoint.key).example.invalid"; ipAddresses=@($address)})}}}
        $fixture[$nicId] = @{status='PASS'; data=@{id=$nicId; properties=@{privateEndpoint=@{id=$endpoint.id}; ipConfigurations=@(@{properties=@{privateIPAddress=$address; subnet=@{id=$endpoint.subnetId}}})}}}
        $fixture["connections-$($endpoint.key)"] = @{status='PASS'; data=@{value=@(@{id="$($endpoint.targetId)/privateEndpointConnections/approved"; properties=@{privateEndpoint=@{id=$endpoint.id}; privateLinkServiceConnectionState=@{status='Approved'}}})}}
    }
    $runnerNic = "$prefix-integration/providers/Microsoft.Network/networkInterfaces/nic-runner"
    $fixture.runner.data.properties.networkProfile = @{networkInterfaces=@(@{id=$runnerNic})}
    $fixture[$runnerNic] = @{status='PASS'; data=@{id=$runnerNic; properties=@{virtualMachine=@{id=$plan.resources.runner.id}; ipConfigurations=@(@{properties=@{privateIPAddress='10.76.4.4'; subnet=@{id="$($plan.resources.network.id)/subnets/snet-runner"}}})}}}
    $fixture.roleScopes = @($plan.groups.Values) + @('models', 'case-a', 'case-b', 'registry-a', 'registry-b', 'gateway', 'runner', 'network' | ForEach-Object { $plan.resources[$_].id }) + @($plan.projects.Values | ForEach-Object { $_ })
    foreach ($scope in $fixture.roleScopes) { $fixture["roles-$scope"] = @{status='PASS'; data=@{value=@()}} }
    $fixture['central-roles'] = @{status='PASS'; data=@{value=@()}}
    $report = Get-ControlPlaneReport $state $plan $fixture
    Confirm-Equal $report.privateAccessEvidence.prerequisiteStatus 'PASS' 'C03 prerequisites from complete lock fixture'
    Confirm-Equal $report.privateAccessEvidence.endpoints.Count 7 'Seven persisted endpoint proofs'
    Confirm-Equal $state.privateAccessVerified $false 'Pure evaluator cannot grant activation'
    Confirm-Equal ($report.privateAccessEvidence.ContainsKey('privateAccessVerified')) $false 'Evidence does not grant activation'
    Confirm-Check $report 'C03' 'BLOCKED'
    Confirm-Check $report 'CENTRAL-OPENAI-ASSIGNMENTS' 'PASS'
    foreach ($actor in $plan.actors) { Confirm-Check $report "EFFECTIVE-INHERITED-$actor" 'INCONCLUSIVE' }
    foreach ($check in @($report.checks | Where-Object { $_.test -ne 'C03' -and $_.test -notmatch 'EFFECTIVE' })) { Confirm-Check $report $check.test 'PASS' }
    function Confirm-Mutation([scriptblock]$Mutation, [string]$Check, [string]$Status = 'FAIL') {
        $changed = Copy-Fixture $fixture
        & $Mutation $changed
        Confirm-Check (Get-ControlPlaneReport $state $plan $changed) $Check $Status
    }
    Confirm-Mutation { param($changed) $changed.gateway.data.properties.publicNetworkAccess='Enabled' } 'GATEWAY-PRIVATE'
    Confirm-Mutation { param($changed) $changed.models.data.properties.disableLocalAuth=$false } 'FOUNDRY-models'
    Confirm-Mutation { param($changed) $changed.models.data.properties.Remove('disableLocalAuth') } 'FOUNDRY-models' 'INCONCLUSIVE'
    Confirm-Mutation { param($changed) $changed['case-a-deployments'].data.value=@(@{id="$($plan.resources['case-a'].id)/deployments/local"}) } 'DEPLOYMENTS-case-a'
    Confirm-Mutation { param($changed) $changed['case-b-projects'].data.value=@() } 'PROJECTS-case-b'
    Confirm-Mutation { param($changed) $changed['models-projects'].data.value=@(@{id="$($plan.resources.models.id)/projects/unexpected"}) } 'PROJECTS-models'
    Confirm-Mutation { param($changed) $changed['models-deployments'].data.value=@() } 'DEPLOYMENTS-models'
    foreach ($field in @('adminUserEnabled', 'anonymousPullEnabled')) { Confirm-Mutation { param($changed) $changed['registry-a'].data.properties[$field]=$true } 'ACR-registry-a' }
    Confirm-Mutation { param($changed) $changed['registry-b'].data.properties.roleAssignmentMode='LegacyRegistryPermissions' } 'ACR-registry-b'
    Confirm-Mutation { param($changed) $changed[$runnerNic].data.properties.ipConfigurations[0].properties.publicIPAddress=@{id='unexpected'} } 'RUNNER-PRIVATE'
    Confirm-Mutation { param($changed) $changed[$runnerNic].data.properties.virtualMachine.id+='-other' } 'RUNNER-PRIVATE'
    Confirm-Mutation { param($changed) $changed.peerings.data.value=@(@{id="$($plan.resources.network.id)/virtualNetworkPeerings/other"}) } 'VNET-NO-PEERING'
    Confirm-Mutation { param($changed) $changed['inventory-models'].data.value+=@{id="$($plan.resources.models.id)-other"; type='Microsoft.CognitiveServices/accounts'} } 'INVENTORY'
    Confirm-Mutation { param($changed) $changed['inventory-models']=@{status='INCONCLUSIVE'; reason='Truncated page'} } 'INVENTORY' 'INCONCLUSIVE'
    Confirm-Mutation { param($changed) $changed['pe-gateway'].data.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status='Pending' } 'PE-gateway'
    Confirm-Mutation { param($changed) $changed['connections-gateway'].data.value[0].properties.privateLinkServiceConnectionState.status='Rejected' } 'PE-gateway'
    Confirm-Mutation { param($changed) $changed['connections-gateway'].data.value=@() } 'PE-gateway'
    Confirm-Mutation { param($changed) $changed['pe-gateway'].data.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId=$plan.resources.models.id } 'PE-gateway'
    $gatewayNic = $fixture['pe-gateway'].data.properties.networkInterfaces[0].id
    Confirm-Mutation { param($changed) $changed[$gatewayNic].data.properties.privateEndpoint.id+='-other' } 'PE-gateway'
    Confirm-Mutation { param($changed) $changed[$gatewayNic].data.properties.ipConfigurations[0].properties.privateIPAddress='10.76.7.4' } 'PE-gateway'
    Confirm-Mutation { param($changed) $changed[$gatewayNic].data.properties.ipConfigurations[0].properties.privateIPAddress='8.8.8.8' } 'PE-gateway'
    Confirm-Mutation { param($changed) $changed[$gatewayNic].data.properties.ipConfigurations=@() } 'PE-gateway'
    Confirm-Mutation { param($changed) $changed['pe-gateway'].data.properties.customDnsConfigs[0].ipAddresses=@('10.76.8.30') } 'PE-gateway'
    Confirm-Mutation { param($changed) $changed[$gatewayNic]=@{status='BLOCKED'} } 'PE-gateway' 'BLOCKED'
    Confirm-Mutation { param($changed) $changed['connections-gateway']=@{status='INCONCLUSIVE'} } 'PE-gateway' 'INCONCLUSIVE'
    $centralRole = @{properties=@{principalId=$state.ownershipId; roleDefinitionId="/providers/Microsoft.Authorization/roleDefinitions/5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"; scope=$plan.resources.models.id; condition=$null}}
    Confirm-Mutation { param($changed) $changed['central-roles'].data.value=@($centralRole) } 'CENTRAL-OPENAI-ASSIGNMENTS'
    $activatePlan = Copy-Fixture $plan
    $activatePlan.phase='activate'
    $activated = Copy-Fixture $fixture
    $activated['central-roles'].data.value=@($centralRole)
    Confirm-Check (Get-ControlPlaneReport $state $activatePlan $activated) 'CENTRAL-OPENAI-ASSIGNMENTS' 'PASS'
    Confirm-Check (Get-ControlPlaneReport $state $activatePlan $fixture) 'CENTRAL-OPENAI-ASSIGNMENTS' 'FAIL'
    $activated['central-roles'].data.value[0].properties.principalId=$lab.identities[0].principalId
    Confirm-Check (Get-ControlPlaneReport $state $activatePlan $activated) 'CENTRAL-OPENAI-ASSIGNMENTS' 'FAIL'
    $definitionId = "/providers/Microsoft.Authorization/roleDefinitions/$($state.ownershipId)"
    Confirm-Mutation {
        param($changed)
        $changed["roles-$($plan.groups.models)"].data.value=@(@{properties=@{principalId=$lab.identities[0].principalId; scope=$plan.groups.models; roleDefinitionId=$definitionId}})
        $changed[$definitionId]=@{status='PASS'; data=@{properties=@{roleName='Custom broad role'; permissions=@(@{actions=@('*'); notActions=@(); dataActions=@(); notDataActions=@()})}}}
    } 'DIRECT-INHERITED-dev-a'
    Confirm-Mutation { param($changed) $changed["roles-$($plan.groups.models)"]=@{status='BLOCKED'} } 'DIRECT-INHERITED-dev-a' 'BLOCKED'
    Confirm-Mutation { param($changed) $changed.roleScopes=@($plan.groups.models) } 'DIRECT-INHERITED-dev-a' 'INCONCLUSIVE'
    Confirm-Mutation { param($changed) $changed['group-models'].data.tags['fgl-owner']=$state.tenantId } 'GROUP-models'
    Confirm-Mutation { param($changed) $changed['models-projects'].data.nextLink='https://example.invalid/next' } 'PROJECTS-models' 'INCONCLUSIVE'
    Confirm-Mutation {
        param($changed)
        $monitorNic = $changed['pe-monitor'].data.properties.networkInterfaces[0].id
        $duplicateAddress = $changed[$gatewayNic].data.properties.ipConfigurations[0].properties.privateIPAddress
        $changed[$monitorNic].data.properties.ipConfigurations[0].properties.privateIPAddress=$duplicateAddress
        $changed['pe-monitor'].data.properties.customDnsConfigs[0].ipAddresses=@($duplicateAddress)
    } 'PE-UNIQUE-IP'
    Confirm-Equal (Get-ControlPlaneRoleRisk @{properties=@{roleName='Custom reader'; permissions=@(@{actions=@('*/read'); notActions=@(); dataActions=@(); notDataActions=@()})}}) 'PASS' 'Read-only role permission proof'
    Confirm-Equal (Get-ControlPlaneRoleRisk @{properties=@{roleName='Custom unknown'; permissions=@(@{actions=@('Example.Service/items/write'); notActions=@(); dataActions=@(); notDataActions=@()})}}) 'INCONCLUSIVE' 'Unknown privilege cannot pass'
    Confirm-Equal (Test-ControlPlaneContextSafety { Invoke-LabAz $State @('group', 'show', '--name', $groupName) 'ownership' }) $true 'Exact group context contract'
    Confirm-Equal (Test-ControlPlaneContextSafety { Invoke-LabAz $State $arguments 'ownership' }) $false 'Dynamic context arguments require review'
    $script:mockCalls = [System.Collections.Generic.List[object]]::new()
    $script:mockResponse = @{value=@()}
    $script:mockRoutes = $null
    $script:mockThrow = $false
    function Invoke-LabAz([hashtable]$State, [string[]]$Arguments, [string]$Label) {
        $script:mockCalls.Add(@{arguments=$Arguments; label=$Label; state=$State})
        if ($Arguments[0] -ne 'rest' -or $Arguments[1] -ne '--method' -or $Arguments[2] -ne 'GET') { throw 'Only GET is allowed' }
        if ($script:mockThrow) { throw 'Synthetic denied request; never echo raw errors' }
        if ($null -ne $script:mockRoutes) {
            $resourcePath = ([uri]$Arguments[4]).AbsolutePath
            if (-not $script:mockRoutes.ContainsKey($resourcePath)) { throw 'Request has no exact fixture' }
            return $script:mockRoutes[$resourcePath]
        }
        return $script:mockResponse
    }
    foreach ($resourceId in @($plan.resources.models.id, "$($plan.resources.models.id)/projects", "$($plan.resources.models.id)/deployments", "$($plan.groups.models)/resources", "$($plan.resources.network.id)/virtualNetworkPeerings", "$($plan.resources.gateway.id)/privateEndpointConnections", "$($plan.groups.models)/providers/Microsoft.Authorization/roleAssignments")) {
        Confirm-Equal (Invoke-ControlPlaneGet $state $resourceId '2022-04-01' 'mock-get' '{value:value}').status 'PASS' 'Allowed exact GET'
    }
    $before = $script:mockCalls.Count
    foreach ($invalidId in @("/subscriptions/$($state.subscriptionId)/resources", "$($plan.groups.models)-other/resources", "$($plan.resources.models.id)?override=1", "$($plan.resources.models.id)/unknownCollection")) {
        Confirm-Equal (Invoke-ControlPlaneGet $state $invalidId '2022-04-01' 'mock-denied' '{value:value}').status 'BLOCKED' 'Out of scope read rejected'
    }
    Confirm-Equal $script:mockCalls.Count $before 'Rejected IDs never reach Azure wrapper'
    $script:mockResponse=@{value=@(); nextLink='https://example.invalid/unapproved'}
    Confirm-Equal (Invoke-ControlPlaneGet $state "$($plan.resources.models.id)/projects" '2026-05-01' 'mock-pages' '{value:value,nextLink:nextLink}').status 'INCONCLUSIVE' 'No pass on first page only'
    $script:mockResponse=@{value=@()}
    $null = Invoke-ControlPlaneGet $state "$($plan.groups.models)/providers/Microsoft.Authorization/roleAssignments" '2022-04-01' 'mock-inherited' '{value:value,nextLink:nextLink}' -AtScope
    Confirm-Equal ($script:mockCalls[-1].arguments[4].EndsWith('&$filter=atScope()')) $true 'Explicit inherited scope filter'
    Confirm-Equal (Invoke-ControlPlaneGet $state $definitionId '2022-04-01' 'mock-definition' '{id:id}' -Inherited).status 'PASS' 'Exact inherited role definition read'
    $before = $script:mockCalls.Count
    Confirm-Equal (Invoke-ControlPlaneGet $state '/providers/Microsoft.Authorization/roleDefinitions' '2022-04-01' 'mock-definition-list' '{value:value}' -Inherited).status 'BLOCKED' 'Reject role definition inventory'
    Confirm-Equal $script:mockCalls.Count $before 'Definition inventory never reaches wrapper'
    $script:mockThrow=$true
    Confirm-Equal (Invoke-ControlPlaneGet $state $plan.resources.models.id '2026-05-01' 'mock-denied' '{id:id}').status 'BLOCKED' 'Authorization failure is blocked'
    $script:mockThrow=$false
    $script:mockCalls.Clear()
    $script:mockRoutes=@{}
    foreach ($entry in $plan.groups.GetEnumerator()) {
        $script:mockRoutes[$entry.Value]=$fixture["group-$($entry.Key)"].data
        $script:mockRoutes["$($entry.Value)/resources"]=$fixture["inventory-$($entry.Key)"].data
    }
    foreach ($entry in $plan.resources.GetEnumerator()) { $script:mockRoutes[$entry.Value.id]=$fixture[$entry.Key].data }
    foreach ($key in @('models', 'case-a', 'case-b')) {
        foreach ($child in @('projects', 'deployments')) { $script:mockRoutes["$($plan.resources[$key].id)/$child"]=$fixture["$key-$child"].data }
    }
    $script:mockRoutes["$($plan.resources.network.id)/virtualNetworkPeerings"]=$fixture.peerings.data
    foreach ($endpoint in $plan.endpoints) {
        $script:mockRoutes[$endpoint.id]=$fixture["pe-$($endpoint.key)"].data
        $script:mockRoutes["$($endpoint.targetId)/privateEndpointConnections"]=$fixture["connections-$($endpoint.key)"].data
        foreach ($reference in $fixture["pe-$($endpoint.key)"].data.properties.networkInterfaces) { $script:mockRoutes[$reference.id]=$fixture[$reference.id].data }
    }
    $script:mockRoutes[$runnerNic]=$fixture[$runnerNic].data
    foreach ($scope in $fixture.roleScopes) { $script:mockRoutes["$scope/providers/Microsoft.Authorization/roleAssignments"]=@{value=@()} }
    $collected = Get-ControlPlaneSnapshot $state $plan
    $collectedReport = Get-ControlPlaneReport $state $plan $collected
    Confirm-Equal $collectedReport.privateAccessEvidence.prerequisiteStatus 'PASS' 'Full mocked collection proves C03 control-plane prerequisites'
    Confirm-Equal $script:mockCalls.Count 70 'Collector must read the complete expected topology'
    foreach ($call in $script:mockCalls) {
        Confirm-Equal $call.arguments.Count 7 'Only REST GET URL and projection arguments'
        Confirm-Equal $call.arguments[0] 'rest' 'Read-only REST entry'
        Confirm-Equal $call.arguments[2] 'GET' 'GET method only'
        Confirm-Equal ([uri]$call.arguments[4]).Host 'management.azure.com' 'Pinned public-cloud ARM host'
        Confirm-Equal $call.arguments[5] '--query' 'Minimal metadata projection'
        Confirm-Equal $call.state.subscriptionId $state.subscriptionId 'Wrapper receives exact isolated state'
    }
    $script:mockCalls.Clear()
    $script:mockRoutes[$plan.groups.models] = @{id=$plan.groups.models; name=($plan.groups.models -split '/')[-1]; tags=@{'fgl-lab'=$state.labId; 'fgl-owner'=$state.tenantId}}
    Confirm-Rejected { Get-ControlPlaneSnapshot $state $plan } 'Unowned group stops collection'
    Confirm-Equal @($script:mockCalls | Where-Object { $_.label -notlike 'cp-group-*' }).Count 0 'No resources read before ownership succeeds'
    $script:mockRoutes=$null
    foreach ($path in @((Join-Path $PSScriptRoot '../scripts/Test-LabControlPlane.ps1'), $PSCommandPath)) {
        $source = Get-Content -LiteralPath $path -Raw
        Confirm-Equal ([regex]::IsMatch($source, '[^\x00-\x7F]')) $false 'ASCII source'
        Assert-PublicText $source
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
        Confirm-Equal @($parseErrors).Count 0 'PowerShell parser'
        Confirm-Equal @($tokens | Where-Object { $_.Kind -eq 'Comment' }).Count 0 'No inline comments'
    }
    Write-Output "PASS: $script:passed local control-plane checks (mocked fixtures; no cloud calls)"
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}