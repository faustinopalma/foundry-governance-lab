[CmdletBinding()]
param(
    [string]$StatePath,
    [ValidateSet('a-test','b-dev','b-test')][string]$Project,
    [ValidateSet('Preview','Deploy','Status')][string]$Action = 'Preview',
    [string]$Compiler = 'bicep',
    [switch]$ApproveRuntimeAccess,
    [switch]$DefinitionsOnly
)

$runtimeInvocation=@{Path=$StatePath;Selector=$Project;SelectedAction=$Action;Compiler=$Compiler;Approved=[bool]$ApproveRuntimeAccess}
$runtimeDefinitions=[bool]$DefinitionsOnly
. (Join-Path $PSScriptRoot 'ExpansionRuntimeAccess.ps1') -DefinitionsOnly
. (Join-Path $PSScriptRoot 'Invoke-ExpansionHosts.ps1') -DefinitionsOnly

function Get-ExpansionRuntimePaths([hashtable]$State, [string]$Selector) {
    if ($Selector -cnotin @('a-test','b-dev','b-test')) { throw 'Exact expansion runtime selector required' }
    $paths=@{lock=(Assert-ExternalLabPath (Join-Path $State.runDirectory 'expansion-standard.lock'))}
    foreach ($name in @('state','outputs','template','parameters','whatif')) { $paths[$name]=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-runtime-$Selector.$name.json") }
    $paths.evidence=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-runtime-$Selector-evidence")
    return $paths
}

function Get-ExpansionRuntimeSources {
    $sources=Get-ExpansionHostSources
    foreach ($relative in @('scripts/ExpansionRuntimeAccess.ps1','scripts/Invoke-ExpansionRuntimeAccess.ps1','tests/Test-ExpansionRuntimeAccess.ps1','tests/Test-ExpansionRuntimeAccessCoordinator.ps1','infra/modules/standard-access.bicep')) {
        $sources[$relative]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot "../$relative") -Algorithm SHA256).Hash
    }
    return $sources
}

function Get-ExpansionRuntimeGuid([string[]]$Parts) {
    if (-not $Parts.Count -or @($Parts | Where-Object { [string]::IsNullOrEmpty($_) }).Count) { throw 'Nonempty deterministic GUID inputs required' }
    $namespace=[Convert]::FromHexString('11fb06fb712d4ddd98c7e71bbd588830')
    $name=[Text.Encoding]::UTF8.GetBytes(($Parts -join '-'))
    $hash=[Security.Cryptography.SHA1]::HashData([byte[]]($namespace+$name))
    $hash[6]=($hash[6] -band 15) -bor 80
    $hash[8]=($hash[8] -band 63) -bor 128
    return ([guid]::ParseExact([Convert]::ToHexString([byte[]]$hash[0..15]),'N')).ToString('D')
}

function Get-ExpansionRuntimeGrantResources([hashtable]$Binding) {
    $parameters=Get-ExpansionRuntimeAccessParameters $Binding $Binding.scope
    $result=@{}
    foreach ($spec in @(@($Binding.plan.containers.blobstoreId,'ba92f5b4-2d11-453d-a403-e96b0029c9fe'),@($Binding.plan.containers.agentContainerId,'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'))) {
        $name=Get-ExpansionRuntimeGuid @($spec[0],$parameters.projectPrincipalId.value,$spec[1])
        $id="$($spec[0])/providers/Microsoft.Authorization/roleAssignments/$name"
        $result[$id]=@{id=$id;name=$name;type='Microsoft.Authorization/roleAssignments';properties=@{scope=$spec[0];principalId=$parameters.projectPrincipalId.value;principalType='ServicePrincipal';roleDefinitionId="/subscriptions/$($Binding.state.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$($spec[1])"}}
    }
    $cosmos=$Binding.evidence.resources.cosmos.id
    $name=Get-ExpansionRuntimeGuid @($cosmos,$parameters.projectPrincipalId.value,'enterprise_memory','00000000-0000-0000-0000-000000000002')
    $id="$cosmos/sqlRoleAssignments/$name"
    $result[$id]=@{id=$id;name=$name;type='Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments';properties=@{scope="$cosmos/dbs/enterprise_memory";principalId=$parameters.projectPrincipalId.value;roleDefinitionId="$cosmos/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"}}
    return $result
}

function Assert-ExpansionRuntimeTransition([hashtable]$All, [string]$Selector, [string]$SelectedAction, [bool]$Approved) {
    if ($Selector -cnotin @('a-test','b-dev','b-test') -or $SelectedAction -cnotin @('Preview','Deploy','Status')) { throw 'Exact runtime operation required' }
    foreach ($key in $All.Keys) {
        $entry=$All[$key]
        if ($key -cnotin @('a-test','b-dev','b-test') -or $entry -isnot [hashtable]) { throw 'Invalid runtime registry' }
        Assert-FoundationEqual $entry.stage 'runtime-access'
        Assert-FoundationEqual $entry.project $key
        if ($entry.pending -isnot [bool] -or $entry.verified -isnot [bool] -or ($entry.pending -and $entry.verified)) { throw 'Invalid runtime intent flags' }
        if ($entry.pending -and $key -cne $Selector) { throw 'Another runtime operation is pending' }
        if (-not $entry.pending -and -not $entry.verified -and ($entry.submittedAt -or $entry.deploymentId -or $entry.outputHash)) { throw 'Runtime intent cannot be reset' }
        if ($entry.verified -and ($entry.outputHash -isnot [string] -or $entry.outputHash -cnotmatch '^[A-F0-9]{64}$')) { throw 'Runtime receipt seal required' }
        if (-not $entry.verified -and $entry.ContainsKey('outputHash')) { throw 'Unverified runtime cannot have an output seal' }
    }
    Assert-FoundationTransition $All[$Selector] $SelectedAction $Approved
}

function Get-ExpansionRuntimePrerequisites([hashtable]$State, [string]$OriginalPath) {
    $base=Get-ExpansionHostPrerequisites $State $OriginalPath
    $all=@{}; $receipts=@{}; $files=$base.files.Clone(); $hostSources=Get-ExpansionHostSources
    foreach ($pair in @(@('a-test','account'),@('b-dev','account'),@('a-test','project'),@('b-dev','project'),@('b-test','project'))) {
        $paths=Get-ExpansionHostPaths $State $pair[0] $pair[1]
        $entry=Read-FoundationJson $paths.state; $output=Read-FoundationJson $paths.outputs
        $binding=Get-ExpansionHostBinding $State $base $pair[0] $pair[1]
        Assert-ExpansionHostReview $entry $binding $paths $base $hostSources -Submitted
        foreach ($key in @('state','outputs')) { $files[$paths[$key]]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
        Assert-ExpansionHostReceipt $entry $output $files[$paths.outputs]
        if ($entry.mode -ceq 'Create') {
            foreach ($key in @('template','parameters','whatif')) { $files[$paths[$key]]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
        }
        $all[$binding.key]=$entry; $receipts[$binding.key]=$output
    }
    return @{host=$base;all=$all;receipts=$receipts;files=$files;hostSources=$hostSources}
}

function Assert-ExpansionRuntimeInputs([hashtable]$State, [string]$OriginalPath, [hashtable]$Prerequisites, [hashtable]$Sources) {
    Assert-ExpansionHostInputs $State $OriginalPath $Prerequisites.host $Prerequisites.hostSources
    Assert-FoundationEqual (Get-ExpansionRuntimeSources) $Sources
    foreach ($file in $Prerequisites.files.Keys) { Assert-FoundationEqual (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash $Prerequisites.files[$file] }
}

function Read-ExpansionRuntimeArm([hashtable]$State, [string]$Id, [string]$Api, [switch]$List, [switch]$AtScope) {
    if (-not $Id.StartsWith("/subscriptions/$($State.subscriptionId)/",[StringComparison]::OrdinalIgnoreCase) -or $Id -match '[?#%\\\s]' -or $Id.Contains('/../')) { throw 'Foreign or malformed runtime ARM target' }
    if ($AtScope -and (-not $List -or -not $Id.EndsWith('/providers/Microsoft.Authorization/roleAssignments',[StringComparison]::OrdinalIgnoreCase))) { throw 'Inherited role query only' }
    $query=if ($AtScope) { '&$filter=atScope()' } else { '' }
    $result=Invoke-ExpansionNetworkAz $State @('rest','--method','get','--url',"https://management.azure.com${Id}?api-version=$Api$query",'--headers','Accept=application/json')
    if ($result -isnot [hashtable]) { throw 'Complete runtime ARM response required' }
    if (-not $List) { Assert-FoundationText $result.id $Id; return $result }
    if ($result.value -isnot [array]) { throw 'Explicit complete runtime list required' }
    foreach ($key in $result.Keys) {
        if ($key -imatch '^(nextLink|@odata.nextLink|continuationToken|nextMarker|marker)$' -and $null -ne $result[$key] -and ($result[$key] -isnot [string] -or $result[$key].Length)) { throw 'Incomplete runtime inventory; no pagination adoption' }
    }
    $seen=@{}
    foreach ($item in $result.value) {
        if ($item -isnot [hashtable] -or $item.id -isnot [string] -or -not $item.id -or $seen.ContainsKey($item.id)) { throw 'Malformed or duplicate runtime inventory entry' }
        $seen[$item.id]=$true
    }
    return $result.value
}

function Get-ExpansionRuntimeRoles([hashtable]$State, [hashtable]$Prerequisites) {
    $roles=@{}; $subscription="/subscriptions/$($State.subscriptionId)"
    $lists=@(@{id="$subscription/providers/Microsoft.Authorization/roleAssignments";api='2022-04-01';inherited=$false})
    $cosmos=@{}
    foreach ($entry in $Prerequisites.host.network.dependencies.Values) {
        foreach ($resource in $entry.known.Values) { if ($resource.type -ieq 'Microsoft.DocumentDB/databaseAccounts') { $cosmos[$resource.id]=$true } }
    }
    foreach ($output in $Prerequisites.host.network.outputs.Values) {
        $cosmos[$output.standard.cosmos.id]=$true
        $lists+=@{id="$($output.standard.storage.id)/providers/Microsoft.Authorization/roleAssignments";api='2022-04-01';inherited=$true}
    }
    foreach ($id in $cosmos.Keys) { $lists+=@{id="$id/sqlRoleAssignments";api='2024-11-15';inherited=$false} }
    foreach ($request in $lists) {
        foreach ($role in @(Read-ExpansionRuntimeArm $State $request.id $request.api -List -AtScope:$request.inherited)) {
            if ($role.properties -isnot [hashtable] -or $role.properties.scope -isnot [string]) { throw 'Role properties and scope required' }
            if ($request.id.EndsWith('/sqlRoleAssignments',[StringComparison]::OrdinalIgnoreCase)) {
                Assert-FoundationText $role.type 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments'
                if (-not $role.id.StartsWith("$($request.id)/",[StringComparison]::OrdinalIgnoreCase)) { throw 'Native role escaped parent' }
                $role=ConvertTo-ExpansionRuntimeRole $role
            } else { Assert-FoundationText $role.type 'Microsoft.Authorization/roleAssignments' }
            $null=Get-ExpansionRuntimeAccessRole $role $State.subscriptionId
            if ($roles.ContainsKey($role.id)) { Assert-FoundationEqual $roles[$role.id] $role } else { $roles[$role.id]=$role }
        }
    }
    return $roles
}

function Get-ExpansionRuntimeEvidence([hashtable]$State, [hashtable]$Prerequisites, [string]$Selector, [hashtable]$HostLive, [hashtable]$Roles) {
    $network=$Prerequisites.host.network; $dependency=$network.outputs[$Selector].standard
    $resources=@{}
    foreach ($spec in @(@('account',$dependency.accountId,'2026-05-01'),@('project',$dependency.projectId,'2026-05-01'),@('storage',$dependency.storage.id,'2023-05-01'),@('cosmos',$dependency.cosmos.id,'2024-11-15'),@('database',"$($dependency.cosmos.id)/sqlDatabases/enterprise_memory",'2024-11-15'))) {
        $resources[$spec[0]]=Read-ExpansionRuntimeArm $State $spec[1] $spec[2]
    }
    $connections=@(Read-ExpansionRuntimeArm $State "$($dependency.projectId)/connections" '2026-05-01' -List)
    $internal=Assert-ExpansionHostConnections $State $dependency $resources.account $resources.project $connections
    Assert-FoundationEqual (ConvertTo-ExpansionRuntimeAccessGuid $resources.project.properties.internalId) $internal
    Assert-FoundationEqual $internal $HostLive.internalIds[$Selector]
    $containers=@(Read-ExpansionRuntimeArm $State "$($dependency.storage.id)/blobServices/default/containers" '2023-05-01' -List)
    $null=Get-ExpansionRuntimeAccessContainers $dependency.storage.id $resources.project.properties.internalId $containers
    $hostReceipts=@{}
    foreach ($stage in @('account','project')) {
        $key=if ($stage -ceq 'account') { 'account-'+$Selector.Substring(0,1) } else { "project-$Selector" }
        $paths=Get-ExpansionHostPaths $State $Selector $stage
        $manifest=$Prerequisites.all[$key]; $output=$Prerequisites.receipts[$key]
        $resources["${stage}Host"]=Read-ExpansionRuntimeArm $State $output.hostId '2026-05-01'
        Assert-FoundationEqual (Select-FoundationConfiguration $resources["${stage}Host"]) $HostLive.hosts[$output.hostId]
        $hostReceipts[$stage]=@{manifest=$manifest;output=$output;outputHash=$Prerequisites.files[$paths.outputs]}
    }
    $protected=@{}
    foreach ($record in (Get-ExpansionHostKnown $HostLive).Values) { if ($record.properties -is [hashtable]) { $protected[$record.id]=$record } }
    foreach ($record in @($resources.Values)+$connections) { $protected[$record.id]=$record }
    $foundationPaths=Get-FoundationPaths $State; $dependencyPaths=Get-ExpansionStandardPaths $State $Selector
    return @{originalSha=$network.inputs.state;foundation=@{manifest=$network.seal.manifest;output=$network.seal.output;outputHash=$Prerequisites.files[$foundationPaths.outputs]};dependency=@{manifest=$network.dependencies[$Selector];output=$network.outputs[$Selector];outputHash=$Prerequisites.files[$dependencyPaths.outputs]};hosts=$hostReceipts;resources=$resources;containers=$containers;roles=@($Roles.Values | Sort-Object id);protectedResources=@($protected.Values | Sort-Object id)}
}

function Assert-ExpansionRuntimeGrant($Actual, [hashtable]$Expected, [switch]$Payload) {
    if ($Actual -isnot [hashtable] -or $Actual.properties -isnot [hashtable]) { throw 'Expanded grant required' }
    $Actual=ConvertTo-ExpansionRuntimeRole $Actual
    Assert-FoundationText $Actual.id $Expected.id
    Assert-FoundationText $Actual.type $Expected.type
    $properties=$Expected.properties.Clone()
    if ($Payload -and $Expected.type -ieq 'Microsoft.Authorization/roleAssignments') {
        $properties.Remove('scope')
        if (-not $Actual.properties.ContainsKey('principalType')) { $properties.Remove('principalType') }
    }
    foreach ($key in $properties.Keys) { Assert-FoundationText $Actual.properties[$key] $properties[$key] }
    foreach ($key in $Actual.properties.Keys) {
        if ($properties.ContainsKey($key)) { continue }
        if (-not $Payload -and $key -cin @('createdOn','updatedOn','createdBy','updatedBy')) { continue }
        if (-not $Payload -and $Expected.type -ieq 'Microsoft.Authorization/roleAssignments' -and $key -cin @('condition','conditionVersion','delegatedManagedIdentityResourceId','description') -and $null -eq $Actual.properties[$key]) { continue }
        if (-not $Payload -and $key -ceq 'provisioningState') { Assert-FoundationEqual $Actual.properties[$key] 'Succeeded'; continue }
        if ($Payload -and $key -ceq 'scope') { Assert-FoundationText $Actual.properties[$key] $Expected.properties.scope; continue }
        throw 'Unexpected runtime grant property'
    }
}

function ConvertTo-ExpansionRuntimeRole([hashtable]$Role) {
    $copy=Read-ExpansionStandardCopy $Role
    if ($copy.type -ieq 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments') {
        $parts=$copy.id -split '/sqlRoleAssignments/'
        if ($parts.Count -ne 2) { throw 'Exact native role parent required' }
        if ($copy.properties.scope -ceq '/' -or $copy.properties.scope -cmatch '^/dbs/[A-Za-z0-9_.-]+(?:/colls/[A-Za-z0-9_.-]+)?$') {
            $copy.properties.scope=$parts[0]+$copy.properties.scope.TrimEnd('/')
        }
    }
    return $copy
}

function Get-ExpansionRuntimeRoot([hashtable]$Binding) {
    return "$($Binding.scope)/providers/Microsoft.Resources/deployments/fgl-$($Binding.state.labId)-exp-runtime-$($Binding.selector)"
}

function Assert-ExpansionRuntimeWhatIf([hashtable]$Binding, [hashtable]$Known, $Result) {
    if ($Result -isnot [hashtable] -or $Result.status -cne 'Succeeded' -or $Result.changes -isnot [array]) { throw 'Complete successful FullResourcePayloads required' }
    $grants=Get-ExpansionRuntimeGrantResources $Binding; $seen=@{}; $created=0
    foreach ($change in $Result.changes) {
        $id=$change.resourceId
        if ($id -isnot [string] -or -not $id -or $seen.ContainsKey($id) -or @($change.delta).Where({$null -ne $_}).Count -or @($change.diff).Where({$null -ne $_}).Count) { throw 'Duplicate or unexpanded runtime what-if' }
        $seen[$id]=$true
        if ($grants.ContainsKey($id)) {
            Assert-FoundationEqual $change.changeType 'Create'
            if ($null -ne $change.before) { throw 'No runtime grant adoption' }
            Assert-ExpansionRuntimeGrant $change.after $grants[$id] -Payload
            $created++
            continue
        }
        Assert-FoundationEqual $change.changeType 'Ignore'
        if (-not $Known.ContainsKey($id) -or $change.before -isnot [hashtable] -or $change.after -isnot [hashtable]) { throw 'Ignore requires a known unchanged resource' }
        Assert-FoundationEqual $change.before $change.after
        Assert-FoundationText $change.before.id $id
        Assert-FoundationText $change.before.type $Known[$id].type
        $sparse=Read-ExpansionStandardCopy $change.before; $full=Read-ExpansionStandardCopy $Known[$id]
        if ($sparse.ContainsKey('resourceGroup')) { Assert-FoundationText $sparse.resourceGroup ($id -split '/')[4]; $sparse.Remove('resourceGroup') }
        if ($sparse.ContainsKey('managedBy') -and -not $full.ContainsKey('managedBy')) {
            $manager=$sparse.managedBy
            if ($full.type -ine 'Microsoft.Network/networkInterfaces' -or $manager -isnot [string] -or -not $Known.ContainsKey($manager) -or $Known[$manager].type -ine 'Microsoft.Network/privateEndpoints') { throw 'NIC manager must be a known private endpoint' }
            $pattern='^'+[regex]::Escape("$(($manager -split '/providers/')[0])/providers/Microsoft.Network/networkInterfaces/$(($manager -split '/')[-1]).nic.")+'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
            if ($id -inotmatch $pattern) { throw 'NIC does not match its endpoint manager' }
            Assert-FoundationGuid $Matches[1]
            $sparse.Remove('managedBy')
        }
        if ($full.type -iin @('Microsoft.Search/searchServices','Microsoft.DocumentDB/databaseAccounts')) {
            if ($full.location -ceq 'Sweden Central' -and $sparse.location -ceq 'swedencentral') { $full.location='swedencentral' }
            if ($full.type -ieq 'Microsoft.Search/searchServices' -and $full.properties.publicNetworkAccess -ceq 'Disabled' -and $sparse.properties.publicNetworkAccess -ceq 'disabled') { $full.properties.publicNetworkAccess='disabled' }
            if ($full.type -ieq 'Microsoft.DocumentDB/databaseAccounts') { foreach ($location in $full.properties.locations) { if ($location.locationName -ceq 'Sweden Central') { $location.locationName='swedencentral' } } }
        }
        Assert-ExpansionStandardSubset $full $sparse
    }
    if ($created -ne 3) { throw 'Exactly three expanded runtime Creates required' }
}

function Assert-ExpansionRuntimeDeployment([hashtable]$Manifest, $Deployment, [array]$Operations) {
    $binding=$Manifest.binding; $root=Get-ExpansionRuntimeRoot $binding; $grants=Get-ExpansionRuntimeGrantResources $binding
    Assert-FoundationText $Manifest.deploymentId $root
    Assert-FoundationText $Deployment.id $root
    Assert-FoundationEqual $Deployment.name (($root -split '/')[-1])
    Assert-FoundationEqual $Deployment.properties.provisioningState 'Succeeded'
    Assert-FoundationEqual $Deployment.properties.mode 'Incremental'
    Assert-FoundationSet @($Deployment.properties.parameters.Keys) @($binding.plan.parameters.Keys)
    foreach ($key in $binding.plan.parameters.Keys) {
        Assert-CosmosNetworkKeys $Deployment.properties.parameters[$key] @('value') @('type')
        Assert-FoundationEqual $Deployment.properties.parameters[$key].value $binding.plan.parameters[$key].value
        if ($Deployment.properties.parameters[$key].ContainsKey('type')) { Assert-FoundationText $Deployment.properties.parameters[$key].type 'String' }
    }
    if ($Deployment.properties.outputs -and $Deployment.properties.outputs.Count) { throw 'Runtime module has no outputs' }
    if ($Deployment.properties.outputResources -isnot [array]) { throw 'Complete grant output resources required' }
    Assert-FoundationSet @($Deployment.properties.outputResources | ForEach-Object id) @($grants.Keys)
    $seen=@{}; $writes=@{}
    foreach ($operation in $Operations) {
        if ($operation.id -isnot [string] -or -not $operation.id.StartsWith("$root/operations/",[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($operation.id)) { throw 'Unbound or duplicate runtime operation' }
        $seen[$operation.id]=$true; $properties=$operation.properties
        Assert-FoundationEqual $properties.provisioningState 'Succeeded'
        if ($properties.provisioningOperation -ceq 'EvaluateDeploymentOutput' -and -not $properties.targetResource) { continue }
        Assert-FoundationEqual $properties.provisioningOperation 'Create'
        $id=$properties.targetResource.id
        if ($id -isnot [string] -or -not $grants.ContainsKey($id) -or $writes.ContainsKey($id)) { throw 'Only one Create per exact runtime grant allowed' }
        Assert-FoundationText $properties.targetResource.resourceType $grants[$id].type
        $writes[$id]=$true
    }
    Assert-FoundationSet @($writes.Keys) @($grants.Keys)
}

function Get-ExpansionRuntimeIdle([hashtable]$State, [hashtable]$Prerequisites, [hashtable]$All, [hashtable]$Receipts) {
    $runtimeRoots=@{}; $runtimeProof=@{}; $runtimeSeen=@{}
    $runtimeArmReader=(Get-Command Read-ExpansionNetworkArm).ScriptBlock
    foreach ($entry in $All.Values) {
        if (-not $entry.pending -and -not $entry.verified) { continue }
        $root=Get-ExpansionRuntimeRoot $entry.binding
        if ($runtimeRoots.ContainsKey($root)) { throw 'Duplicate runtime deployment root' }
        $deployment=& $runtimeArmReader $State $root '2022-09-01'
        $operations=@(& $runtimeArmReader $State "$root/operations" '2022-09-01' -List)
        Assert-ExpansionRuntimeDeployment $entry $deployment $operations
        $runtimeRoots[$root]=$deployment
        $runtimeProof[$root]=@{deploymentHash=(Get-FoundationHash $deployment);operationsHash=(Get-FoundationHash $operations)}
        if ($entry.verified) { Assert-FoundationEqual $runtimeProof[$root] $Receipts[$entry.project].deploymentProof }
    }
    function Read-ExpansionNetworkArm([hashtable]$State, [string]$Id, [string]$Api, [switch]$List) {
        $result=& $runtimeArmReader $State $Id $Api -List:$List
        if ($List -and $Id.EndsWith('/providers/Microsoft.Resources/deployments',[StringComparison]::OrdinalIgnoreCase)) {
            foreach ($item in @($result)) {
                if ($runtimeRoots.ContainsKey($item.id)) {
                    Assert-FoundationText $item.id "$Id/$($item.name)"
                    Assert-FoundationEqual $item $runtimeRoots[$item.id]
                    if ($runtimeSeen.ContainsKey($item.id)) { throw 'Duplicate runtime root in inventory' }
                    $runtimeSeen[$item.id]=$true
                } else { $item }
            }
        } else { return $result }
    }
    $graph=Get-ExpansionHostIdle $State $Prerequisites.host $Prerequisites.all $Prerequisites.receipts
    Assert-FoundationSet @($runtimeSeen.Keys) @($runtimeRoots.Keys)
    foreach ($root in $runtimeProof.Keys) { if ($graph.ContainsKey($root)) { throw 'Runtime root overlaps protected graph' }; $graph[$root]=$runtimeProof[$root] }
    return $graph
}

function Get-ExpansionRuntimeLive([hashtable]$State, [hashtable]$Prerequisites, [hashtable]$All) {
    $runtimeInventoryReader=(Get-Command Read-ExpansionNetworkArm).ScriptBlock
    $runtimeGrants=@{}
    foreach ($entry in $All.Values) {
        if ($entry.pending -or $entry.verified) { foreach ($grant in (Get-ExpansionRuntimeGrantResources $entry.binding).Values) { $runtimeGrants[$grant.id]=$grant } }
    }
    function Read-ExpansionNetworkArm([hashtable]$State, [string]$Id, [string]$Api, [switch]$List) {
        $result=& $runtimeInventoryReader $State $Id $Api -List:$List
        if ($List -and $Id.EndsWith('/resources',[StringComparison]::OrdinalIgnoreCase)) {
            foreach ($item in @($result)) {
                if ($runtimeGrants.ContainsKey($item.id)) { Assert-FoundationText $item.type $runtimeGrants[$item.id].type }
                else { $item }
            }
        } else { return $result }
    }
    return Get-ExpansionHostLive $State $Prerequisites.host $Prerequisites.all $Prerequisites.receipts
}

function Get-ExpansionRuntimeKnown([hashtable]$Snapshot, [hashtable]$Binding) {
    $known=Get-ExpansionHostKnown $Snapshot
    foreach ($record in @($Binding.evidence.protectedResources)+@($Binding.evidence.containers)+@($Binding.evidence.roles)) { $known[$record.id]=$record }
    return $known
}

function Assert-ExpansionRuntimeReview([hashtable]$Manifest, [hashtable]$State, [hashtable]$Paths, [hashtable]$Prerequisites, [hashtable]$Sources, [switch]$Historical) {
    Assert-CosmosNetworkKeys $Manifest @('version','stage','project','binding','snapshot','idle','pending','verified','review') @('submittedAt','deploymentId','outputHash')
    Assert-FoundationEqual $Manifest.version 1
    Assert-FoundationEqual $Manifest.stage 'runtime-access'
    Assert-FoundationEqual $Manifest.project $Manifest.binding.selector
    Assert-FoundationEqual $Paths (Get-ExpansionRuntimePaths $State $Manifest.project)
    $boundState=Read-ExpansionStandardCopy $State; $boundState.evidenceDirectory=$Paths.evidence
    Assert-FoundationEqual $Manifest.binding.state $boundState
    Assert-FoundationEqual $Manifest.binding.scope $Prerequisites.host.network.outputs[$Manifest.project].standard.resourceGroupId
    $review=$Manifest.review
    Assert-CosmosNetworkKeys $review @('approved','checkedAt','fileHashes','sourceHashes','artifactHashes','bindingHash','snapshotHash','idleHash')
    Assert-FoundationEqual $review.approved $true
    Assert-FoundationEqual $review.fileHashes $Prerequisites.files
    Assert-FoundationEqual $review.sourceHashes $Sources
    foreach ($key in @('binding','snapshot','idle')) { Assert-FoundationEqual $review["${key}Hash"] (Get-FoundationHash $Manifest[$key]) }
    $checked=[DateTimeOffset]::Parse([string]$review.checkedAt); $age=[DateTimeOffset]::UtcNow-$checked
    if ($age -lt [TimeSpan]::Zero -or (-not $Historical -and -not $Manifest.pending -and -not $Manifest.verified -and $age -gt [TimeSpan]::FromHours(1))) { throw 'Runtime Preview expired or future dated' }
    if ($Manifest.pending -or $Manifest.verified) {
        $submitted=[DateTimeOffset]::Parse([string]$Manifest.submittedAt)
        if ($submitted -lt $checked -or $submitted -gt [DateTimeOffset]::UtcNow) { throw 'Invalid runtime submission time' }
        Assert-FoundationEqual $Manifest.deploymentId (Get-ExpansionRuntimeRoot $Manifest.binding)
    }
    Assert-FoundationSet @($review.artifactHashes.Keys) @('template','parameters','whatif')
    foreach ($key in @('template','parameters','whatif')) { Assert-FoundationEqual (Get-FileHash -LiteralPath $Paths[$key] -Algorithm SHA256).Hash $review.artifactHashes[$key] }
    $parameters=Get-ExpansionRuntimeAccessParameters $Manifest.binding $Manifest.binding.scope
    Assert-ExpansionRuntimeAccessTemplate (Read-FoundationJson $Paths.template) $parameters $Manifest.binding $Manifest.binding.scope
    Assert-FoundationEqual (Read-FoundationJson $Paths.parameters) @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$parameters}
    Assert-ExpansionRuntimeWhatIf $Manifest.binding (Get-ExpansionRuntimeKnown $Manifest.snapshot $Manifest.binding) (Read-FoundationJson $Paths.whatif)
}

function Assert-ExpansionRuntimePreserved([hashtable]$Manifest, [hashtable]$Evidence, [hashtable]$Live, [hashtable]$Idle, [hashtable]$All) {
    Assert-FoundationEqual $Live $Manifest.snapshot
    $roles=@{}; foreach ($role in $Evidence.roles) { if ($roles.ContainsKey($role.id)) { throw 'Duplicate role' }; $roles[$role.id]=$role }
    $graph=Read-ExpansionStandardCopy $Idle
    foreach ($entry in $All.Values) {
        if (-not $entry.pending -and -not $entry.verified) { continue }
        $root=Get-ExpansionRuntimeRoot $entry.binding
        if (-not $Manifest.idle.ContainsKey($root)) { $graph.Remove($root) }
        foreach ($grant in (Get-ExpansionRuntimeGrantResources $entry.binding).Values) {
            if (-not $roles.ContainsKey($grant.id)) { throw 'Receipted runtime grant missing' }
            Assert-ExpansionRuntimeGrant $roles[$grant.id] $grant
            if ($entry.project -cne $Manifest.project -and -not $Manifest.binding.plan.roles.ContainsKey($grant.id)) { $roles.Remove($grant.id) }
        }
    }
    Assert-FoundationEqual $graph $Manifest.idle
    Assert-ExpansionRuntimeAccessPreserved $Manifest.binding $Manifest.binding.state $Evidence.resources $Evidence.containers @($roles.Values) $Evidence.protectedResources
}

function Assert-ExpansionRuntimeReceipt([hashtable]$Manifest, $Output, [string]$Hash) {
    Assert-FoundationEqual $Manifest.pending $false
    Assert-FoundationEqual $Manifest.verified $true
    Assert-FoundationEqual $Manifest.outputHash $Hash
    if ($Hash -cnotmatch '^[A-F0-9]{64}$') { throw 'Runtime receipt seal required' }
    Assert-CosmosNetworkKeys $Output @('stage','project','controlPlaneVerified','runtimeVerified','inferenceVerified','completeLab','azureReadOnly','submissionWrites','verifiedAt','deploymentId','deploymentProof','inputHashes','sourceHashes','intentHash','grantHash')
    foreach ($key in @('stage','project','deploymentId')) { Assert-FoundationEqual $Output[$key] $Manifest[$key] }
    foreach ($key in @('controlPlaneVerified','azureReadOnly')) { Assert-FoundationEqual $Output[$key] $true }
    foreach ($key in @('runtimeVerified','inferenceVerified','completeLab')) { Assert-FoundationEqual $Output[$key] $false }
    Assert-FoundationEqual $Output.submissionWrites 1
    Assert-FoundationEqual $Output.inputHashes $Manifest.review.fileHashes
    Assert-FoundationEqual $Output.sourceHashes $Manifest.review.sourceHashes
    Assert-FoundationEqual $Output.intentHash (Get-ExpansionHostIntentHash $Manifest)
    Assert-CosmosNetworkKeys $Output.deploymentProof @('deploymentHash','operationsHash')
    foreach ($value in @($Output.deploymentProof.Values)+@($Output.grantHash)) { if ($value -isnot [string] -or $value -cnotmatch '^[A-F0-9]{64}$') { throw 'Runtime postcondition hashes required' } }
    $verified=[DateTimeOffset]::Parse([string]$Output.verifiedAt)
    if ($verified -lt [DateTimeOffset]::Parse([string]$Manifest.submittedAt) -or $verified -gt [DateTimeOffset]::UtcNow) { throw 'Invalid runtime receipt time' }
}

function Get-ExpansionRuntimeGrantHash([hashtable]$Manifest, [hashtable]$Roles) {
    $actual=@{}
    foreach ($grant in (Get-ExpansionRuntimeGrantResources $Manifest.binding).Values) {
        Assert-ExpansionRuntimeGrant $Roles[$grant.id] $grant
        $actual[$grant.id]=$Roles[$grant.id]
    }
    return Get-FoundationHash $actual
}

function Complete-ExpansionRuntimeReceipt([hashtable]$Manifest, [hashtable]$Paths, [hashtable]$Roles, [hashtable]$Idle, $ExistingOutput, [scriptblock]$Guard) {
    $proof=$Idle[$Manifest.deploymentId]; $grantHash=Get-ExpansionRuntimeGrantHash $Manifest $Roles
    if ($ExistingOutput) {
        $completed=$Manifest.Clone(); $completed.pending=$false; $completed.verified=$true; $completed.outputHash=(Get-FileHash -LiteralPath $Paths.outputs -Algorithm SHA256).Hash
        Assert-ExpansionRuntimeReceipt $completed $ExistingOutput $completed.outputHash
        Assert-FoundationEqual $ExistingOutput.deploymentProof $proof
        Assert-FoundationEqual $ExistingOutput.grantHash $grantHash
        & $Guard
        Write-StandardJson $Paths.state $completed
        return $ExistingOutput
    }
    $output=@{stage='runtime-access';project=$Manifest.project;controlPlaneVerified=$true;runtimeVerified=$false;inferenceVerified=$false;completeLab=$false;azureReadOnly=$true;submissionWrites=1;verifiedAt=[DateTimeOffset]::UtcNow.ToString('o');deploymentId=$Manifest.deploymentId;deploymentProof=$proof;inputHashes=$Manifest.review.fileHashes;sourceHashes=$Manifest.review.sourceHashes;intentHash=(Get-ExpansionHostIntentHash $Manifest);grantHash=$grantHash}
    $temporary=Assert-ExternalLabPath "$($Paths.outputs).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Write-StandardJson $temporary $output
        $completed=$Manifest.Clone(); $completed.outputHash=(Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash; $completed.pending=$false; $completed.verified=$true
        Assert-ExpansionRuntimeReceipt $completed $output $completed.outputHash
        & $Guard
        [IO.File]::Move($temporary,$Paths.outputs)
        Write-StandardJson $Paths.state $completed
        return $output
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Invoke-ExpansionRuntimeAccess([string]$Path, [string]$Selector, [string]$SelectedAction, [string]$Compiler, [bool]$Approved) {
    $ErrorActionPreference='Stop'
    if (-not $Path -or $SelectedAction -cnotin @('Preview','Deploy','Status')) { throw 'StatePath and exact Action required' }
    $originalPath=Assert-ExternalLabPath $Path; $originalHash=(Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
    $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
    $paths=Get-ExpansionRuntimePaths $state $Selector
    $lock=$null; $prerequisites=$null; $sources=$null; $runtimeReadTransport=@{session=$null}
    $runtimeCliTransport=(Get-Command Invoke-ExpansionNetworkAz).ScriptBlock
    function Invoke-ExpansionNetworkAz([hashtable]$State, [string[]]$Arguments, [switch]$Empty) {
        if ($Arguments.Count -eq 7 -and $Arguments[0] -ceq 'rest' -and $Arguments[1] -ceq '--method' -and $Arguments[2] -ceq 'get' -and $Arguments[3] -ceq '--url' -and $Arguments[5] -ceq '--headers' -and $Arguments[6] -ceq 'Accept=application/json' -and -not $Empty -and -not $Arguments[4].EndsWith('&$filter=atScope()',[StringComparison]::Ordinal)) {
            Assert-ExpansionArmReadUrl $State $Arguments[4]
            if (-not $runtimeReadTransport.session) { $runtimeReadTransport.session=New-ExpansionArmReadSession $State }
            return Invoke-ExpansionArmRead $runtimeReadTransport.session $State $Arguments[4]
        }
        return & $runtimeCliTransport $State $Arguments -Empty:$Empty
    }
    function Invoke-FoundationAz([hashtable]$State, [string[]]$Arguments, [string]$Label) { return Invoke-ExpansionNetworkAz $State $Arguments }
    try {
        $lock=[IO.File]::Open($paths.lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
        $state.evidenceDirectory=$paths.evidence; $null=[IO.Directory]::CreateDirectory($paths.evidence)
        $prerequisites=Get-ExpansionRuntimePrerequisites $state $originalPath
        Assert-FoundationEqual $prerequisites.host.network.inputs.state $originalHash
        $sources=Get-ExpansionRuntimeSources
        $all=@{}; $receipts=@{}; $observedFiles=@{}; $registryPaths=@{}
        foreach ($selection in @('a-test','b-dev','b-test')) {
            $other=Get-ExpansionRuntimePaths $state $selection; $registryPaths[$selection]=$other
            foreach ($name in @('state','outputs')) { $observedFiles[$other[$name]]=$null; if (Test-Path -LiteralPath $other[$name]) { $observedFiles[$other[$name]]=(Get-FileHash -LiteralPath $other[$name] -Algorithm SHA256).Hash } }
            if ($observedFiles[$other.state]) { $all[$selection]=Read-FoundationJson $other.state }
            if ($observedFiles[$other.outputs]) {
                $entry=$all[$selection]
                if (-not $entry -or (-not $entry.verified -and ($SelectedAction -cne 'Status' -or $selection -cne $Selector -or -not $entry.pending))) { throw 'Only selected pending Status may recover an orphan output' }
                $receipts[$selection]=Read-FoundationJson $other.outputs
            }
        }
        Assert-ExpansionRuntimeTransition $all $Selector $SelectedAction $Approved
        foreach ($entry in $all.Values) {
            Assert-ExpansionRuntimeReview $entry $state $registryPaths[$entry.project] $prerequisites $sources -Historical:($entry.project -cne $Selector -or $SelectedAction -ceq 'Preview')
            if ($entry.verified) { Assert-ExpansionRuntimeReceipt $entry $receipts[$entry.project] $observedFiles[$registryPaths[$entry.project].outputs] }
        }
        function Assert-RuntimeUnchanged {
            Assert-ExpansionRuntimeInputs $state $originalPath $prerequisites $sources
            foreach ($file in $observedFiles.Keys) {
                if ($observedFiles[$file]) { Assert-FoundationEqual (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash $observedFiles[$file] }
                elseif (Test-Path -LiteralPath $file) { throw 'Runtime registry changed during collection' }
            }
        }
        $started=[DateTimeOffset]::UtcNow.ToString('o'); $manifest=$all[$Selector]
        $idle=Get-ExpansionRuntimeIdle $state $prerequisites $all $receipts
        $live=Get-ExpansionRuntimeLive $state $prerequisites $all
        $roles=Get-ExpansionRuntimeRoles $state $prerequisites
        $evidence=Get-ExpansionRuntimeEvidence $state $prerequisites $Selector $live $roles
        foreach ($entry in $all.Values) {
            if (-not $entry.verified -and -not $entry.pending) { continue }
            $entryEvidence=if ($entry.project -ceq $Selector) { $evidence } else { Get-ExpansionRuntimeEvidence $state $prerequisites $entry.project $live $roles }
            Assert-ExpansionRuntimePreserved $entry $entryEvidence $live $idle $all
            if ($entry.verified) { Assert-FoundationEqual (Get-ExpansionRuntimeGrantHash $entry $roles) $receipts[$entry.project].grantHash }
        }
        if ($SelectedAction -ceq 'Status') {
            Assert-FoundationEqual (Get-ExpansionRuntimeLive $state $prerequisites $all) $live
            Assert-FoundationEqual (Get-ExpansionRuntimeIdle $state $prerequisites $all $receipts) $idle
            Assert-FoundationEqual (Get-ExpansionRuntimeRoles $state $prerequisites) $roles
            Assert-FoundationEqual (Get-ExpansionRuntimeEvidence $state $prerequisites $Selector $live $roles) $evidence
            Assert-RuntimeUnchanged
            if ($manifest.verified) { return $receipts[$Selector] }
            return Complete-ExpansionRuntimeReceipt $manifest $paths $roles $idle $receipts[$Selector] { Assert-RuntimeUnchanged }
        }
        $binding=Get-ExpansionRuntimeAccessBinding $state $Selector $evidence $prerequisites.host.network.outputs[$Selector].standard.resourceGroupId
        if ($SelectedAction -ceq 'Deploy') {
            Assert-ExpansionRuntimeReview $manifest $state $paths $prerequisites $sources
            Assert-FoundationEqual $binding $manifest.binding
            Assert-FoundationEqual $live $manifest.snapshot
            Assert-FoundationEqual $idle $manifest.idle
        } else {
            $source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../infra/modules/standard-access.bicep'))
            $null=Invoke-ExpansionNetworkProcess $state $Compiler @('build',$source,'--no-restore','--outfile',$paths.template)
            $parameters=Get-ExpansionRuntimeAccessParameters $binding $binding.scope
            Assert-ExpansionRuntimeAccessTemplate (Read-FoundationJson $paths.template) $parameters $binding $binding.scope
            Write-StandardJson $paths.parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$parameters}
        }
        $artifacts=@{}; foreach ($key in @('template','parameters')) { $artifacts[$key]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
        $root=Get-ExpansionRuntimeRoot $binding
        $common=@('--resource-group',(($binding.scope -split '/')[-1]),'--name',(($root -split '/')[-1]),'--mode','Incremental','--template-file',$paths.template,'--parameters',"@$($paths.parameters)")
        $validation=Invoke-ExpansionNetworkAz $state (@('deployment','group','validate')+$common)
        if ($validation.error -or $validation.properties.provisioningState -cne 'Succeeded') { throw 'Runtime ARM validation failed' }
        $whatif=Invoke-ExpansionNetworkAz $state (@('deployment','group','what-if','--no-pretty-print','--result-format','FullResourcePayloads')+$common)
        Assert-ExpansionRuntimeWhatIf $binding (Get-ExpansionRuntimeKnown $live $binding) $whatif
        Assert-FoundationEqual (Get-ExpansionRuntimeLive $state $prerequisites $all) $live
        Assert-FoundationEqual (Get-ExpansionRuntimeIdle $state $prerequisites $all $receipts) $idle
        Assert-FoundationEqual (Get-ExpansionRuntimeRoles $state $prerequisites) $roles
        Assert-FoundationEqual (Get-ExpansionRuntimeEvidence $state $prerequisites $Selector $live $roles) $evidence
        Assert-RuntimeUnchanged
        foreach ($key in $artifacts.Keys) { Assert-FoundationEqual (Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash $artifacts[$key] }
        if ($SelectedAction -ceq 'Preview') {
            Write-StandardJson $paths.whatif $whatif; $artifacts.whatif=(Get-FileHash -LiteralPath $paths.whatif -Algorithm SHA256).Hash
            $manifest=@{version=1;stage='runtime-access';project=$Selector;binding=$binding;snapshot=$live;idle=$idle;pending=$false;verified=$false;review=@{approved=$true;checkedAt=$started;fileHashes=$prerequisites.files;sourceHashes=$sources;artifactHashes=$artifacts;bindingHash=(Get-FoundationHash $binding);snapshotHash=(Get-FoundationHash $live);idleHash=(Get-FoundationHash $idle)}}
            Assert-ExpansionRuntimeReview $manifest $state $paths $prerequisites $sources
            Write-StandardJson $paths.state $manifest
            return @{action='Preview';project=$Selector;reviewPath=$paths.state;expiresAt=[DateTimeOffset]::Parse($started).AddHours(1).ToString('o')}
        }
        Assert-ExpansionRuntimeReview $manifest $state $paths $prerequisites $sources
        $manifest.pending=$true; $manifest.submittedAt=[DateTimeOffset]::UtcNow.ToString('o'); $manifest.deploymentId=$root
        Write-StandardJson $paths.state $manifest
        $null=Invoke-ExpansionNetworkAz $state (@('deployment','group','create')+$common+@('--no-wait')) -Empty
        return @{action='Deploy';project=$Selector;pending=$true;deploymentId=$root;intentPath=$paths.state}
    } finally {
        try {
            Assert-FoundationEqual (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash $originalHash
            if ($prerequisites -and $sources) { Assert-ExpansionRuntimeInputs $state $originalPath $prerequisites $sources }
        } finally { try { Close-ExpansionArmReadSession $runtimeReadTransport.session } finally { if ($lock) { $lock.Dispose() } } }
    }
}

if ($runtimeDefinitions) { return }
Invoke-ExpansionRuntimeAccess @runtimeInvocation