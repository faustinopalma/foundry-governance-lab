[CmdletBinding()]
param([Alias('DefinitionsOnly')][switch]$ExpansionRuntimeDefinitionsOnly)

New-Module -Name ExpansionRuntimeAccess -ArgumentList $PSScriptRoot -ScriptBlock {
    param($ExpansionRuntimeHelperRoot)
    . (Join-Path $ExpansionRuntimeHelperRoot 'Invoke-ExpansionFoundation.ps1') -DefinitionsOnly

    function Assert-RuntimeKeys($Value, [string[]]$Required, [string[]]$Optional = @()) {
        if ($Value -isnot [hashtable]) { throw 'Object required' }
        foreach ($key in $Required) { if ($key -cnotin @($Value.Keys)) { throw 'Required field missing' } }
        foreach ($key in $Value.Keys) { if ($key -cnotin ($Required+$Optional)) { throw 'Unexpected field' } }
    }

    function Copy-RuntimeValue($Value) {
        $options=@{AsHashtable=$true;Depth=100;NoEnumerate=$true}
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind='String' }
        return ,(ConvertTo-Json -InputObject $Value -Depth 100 | ConvertFrom-Json @options)
    }

    function ConvertTo-ExpansionRuntimeAccessGuid($Value) {
        $parsed=[guid]::Empty
        if ($Value -isnot [string] -or $Value -cne $Value.Trim() -or -not ([guid]::TryParseExact($Value,'D',[ref]$parsed) -or [guid]::TryParseExact($Value,'N',[ref]$parsed)) -or $parsed -eq [guid]::Empty) { throw 'Nonzero D or N project internalId required' }
        return $parsed.ToString('D').ToLowerInvariant()
    }

    function Assert-RuntimeNoPagination($Value) {
        if ($Value -is [Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                if ($key -imatch '^(nextLink|@odata.nextLink|continuationToken|nextMarker|marker)$') { throw 'Pagination evidence is not a complete inventory' }
                Assert-RuntimeNoPagination $Value[$key]
            }
        } elseif ($Value -is [array]) { foreach ($item in $Value) { Assert-RuntimeNoPagination $item } }
    }

    function Get-ExpansionRuntimeAccessContainers([string]$StorageId, $InternalId, $Containers) {
        $workspace=ConvertTo-ExpansionRuntimeAccessGuid $InternalId
        if ($StorageId -cnotmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[a-zA-Z0-9_.-]+/providers/Microsoft.Storage/storageAccounts/[a-z0-9]{3,24}$') { throw 'Exact storage resource ID required' }
        Assert-FoundationGuid ($StorageId -split '/')[2]
        if ($Containers -isnot [array] -or $Containers.Count -lt 2) { throw 'Complete container array required' }
        Assert-RuntimeNoPagination $Containers
        $root="$StorageId/blobServices/default/containers"; $seen=@{}; $blobstores=@(); $agents=@()
        $agentPattern='^'+[regex]::Escape($workspace)+'-(?:[a-f0-9]{12}-)?azureml-agent$'
        foreach ($container in $Containers) {
            if ($container -isnot [hashtable] -or $container.name -isnot [string] -or $container.name -cnotmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' -or $container.name.Contains('--') -or $container.properties -isnot [hashtable]) { throw 'Complete canonical container required' }
            Assert-FoundationText $container.id "$root/$($container.name)"
            Assert-FoundationText $container.type 'Microsoft.Storage/storageAccounts/blobServices/containers'
            if ($seen.ContainsKey($container.id)) { throw 'Duplicate container ID' }
            $seen[$container.id]=$true
            if ($container.name -ceq "$workspace-azureml-blobstore") { $blobstores+=$container }
            if ($container.name -cmatch $agentPattern) { $agents+=$container }
        }
        if ($blobstores.Count -ne 1 -or $agents.Count -ne 1) { throw 'Existing blobstore and exactly one matching agent container required' }
        foreach ($container in @($blobstores[0],$agents[0])) {
            Assert-FoundationEqual $container.properties.publicAccess 'None'
            if ($container.properties.ContainsKey('provisioningState')) { Assert-FoundationEqual $container.properties.provisioningState 'Succeeded' }
        }
        return @{internalId=$workspace;blobstoreName=$blobstores[0].name;blobstoreId=$blobstores[0].id;agentContainerName=$agents[0].name;agentContainerId=$agents[0].id;inventory=(Copy-RuntimeValue @($Containers | Sort-Object id))}
    }

    function Assert-RuntimeHash($Value) {
        if ($Value -isnot [string] -or $Value -cnotmatch '^[A-F0-9]{64}$' -or $Value -ceq ('0'*64)) { throw 'Nonzero SHA256 seal required' }
    }

    function Assert-RuntimeReceipt($Receipt) {
        Assert-RuntimeKeys $Receipt @('manifest','output','outputHash')
        if ($Receipt.manifest -isnot [hashtable] -or $Receipt.output -isnot [hashtable]) { throw 'Verified receipt objects required' }
        Assert-RuntimeHash $Receipt.outputHash
        Assert-FoundationEqual $Receipt.manifest.outputHash $Receipt.outputHash
        Assert-FoundationEqual $Receipt.manifest.pending $false
        Assert-FoundationEqual $Receipt.manifest.verified $true
        Assert-FoundationEqual $Receipt.output.controlPlaneVerified $true
        Assert-FoundationEqual $Receipt.output.inferenceVerified $false
    }

    function Assert-RuntimeResource($Resource, [string]$Id, [string]$Type) {
        if ($Resource -isnot [hashtable] -or $Resource.properties -isnot [hashtable]) { throw 'Complete existing resource evidence required' }
        Assert-RuntimeNoPagination $Resource
        Assert-FoundationText $Resource.id $Id
        Assert-FoundationText $Resource.type $Type
        $leaf=($Id -split '/')[-1]
        $qualified=($Id -split '/providers/')[1] -split '/'
        $names=@(for ($index=2; $index -lt $qualified.Count; $index+=2) { $qualified[$index] }) -join '/'
        if ($Resource.name -isnot [string] -or $Resource.name -inotin @($leaf,$names)) { throw 'Resource name and ID disagree' }
        if ($Resource.properties.ContainsKey('provisioningState')) { Assert-FoundationEqual $Resource.properties.provisioningState 'Succeeded' }
    }

    function Get-RuntimeInventory($Items, [string]$SubscriptionId, [switch]$AllowInheritedRoles) {
        if ($Items -isnot [array]) { throw 'Complete inventory array required' }
        Assert-RuntimeNoPagination $Items
        $result=@{}; $prefix="/subscriptions/$SubscriptionId/"
        foreach ($item in $Items) {
            if ($item -isnot [hashtable] -or $item.id -isnot [string] -or $item.id -match '[?#%\\\s]|/\.{1,2}/|//' -or $item.type -isnot [string] -or $item.properties -isnot [hashtable] -or $result.ContainsKey($item.id)) { throw 'Foreign, duplicate or incomplete inventory resource' }
            if (-not $item.id.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                if (-not $AllowInheritedRoles -or $item.type -ine 'Microsoft.Authorization/roleAssignments' -or $item.id -inotmatch '^(/providers/Microsoft.Management/managementGroups/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}))/providers/Microsoft.Authorization/roleAssignments/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') { throw 'Foreign or malformed inherited role assignment' }
                $inheritedScope=$Matches[1]; $managementGroup=$Matches[2]; $assignment=$Matches[3]
                Assert-FoundationGuid $managementGroup
                Assert-FoundationGuid $assignment
                Assert-FoundationText $item.properties.scope $inheritedScope
                Assert-FoundationText $item.name $assignment
            }
            $result[$item.id]=Copy-RuntimeValue $item
        }
        return $result
    }

    function Get-ExpansionRuntimeAccessRole($Role, [string]$SubscriptionId) {
        $null=Get-RuntimeInventory @($Role) $SubscriptionId -AllowInheritedRoles
        Assert-FoundationGuid (($Role.id -split '/')[-1])
        $properties=$Role.properties
        Assert-FoundationGuid $properties.principalId
        if ($properties.scope -isnot [string] -or $properties.roleDefinitionId -isnot [string]) { throw 'Typed role scope and definition required' }
        $leaf=($Role.id -split '/')[-1]
        if ($Role.type -ieq 'Microsoft.Authorization/roleAssignments') {
            Assert-FoundationText $Role.id "$($properties.scope)/providers/Microsoft.Authorization/roleAssignments/$leaf"
            Assert-FoundationText $Role.name $leaf
            $definitionPrefix="/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/"
            if (-not $properties.roleDefinitionId.StartsWith($definitionPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Foreign Azure role definition' }
            Assert-FoundationGuid ($properties.roleDefinitionId.Substring($definitionPrefix.Length))
        } elseif ($Role.type -ieq 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments') {
            $parts=$Role.id -split '/sqlRoleAssignments/'
            if ($parts.Count -ne 2 -or $parts[0] -inotmatch '/providers/Microsoft.DocumentDB/databaseAccounts/[a-z0-9-]+$') { throw 'Invalid native Cosmos assignment ID' }
            Assert-RuntimeResource $Role $Role.id 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments'
            if (-not $properties.scope.StartsWith($parts[0],[StringComparison]::OrdinalIgnoreCase) -or -not $properties.roleDefinitionId.StartsWith("$($parts[0])/sqlRoleDefinitions/",[StringComparison]::OrdinalIgnoreCase)) { throw 'Foreign native Cosmos scope or definition' }
            Assert-FoundationGuid (($properties.roleDefinitionId -split '/')[-1])
        } else { throw 'Only Azure RBAC or Cosmos native assignments allowed' }
        return @{type=$Role.type.ToLowerInvariant();scope=$properties.scope.ToLowerInvariant();principalId=$properties.principalId.ToLowerInvariant();roleDefinitionId=$properties.roleDefinitionId.ToLowerInvariant()}
    }

    function Get-ExpansionRuntimeAccessBinding([hashtable]$State, [string]$Selector, [hashtable]$Evidence, [string]$Scope) {
        if ($Selector -cnotin @('a-test','b-dev','b-test')) { throw 'Expansion runtime selector required' }
        foreach ($key in @('subscriptionId','tenantId','ownershipId')) { Assert-FoundationGuid $State[$key] }
        if ($State.labId -isnot [string] -or $State.labId -cnotmatch '^[a-z0-9]{6,12}$') { throw 'Canonical lab name required' }
        Assert-RuntimeKeys $Evidence @('originalSha','foundation','dependency','hosts','resources','containers','roles','protectedResources')
        Assert-RuntimeHash $Evidence.originalSha
        foreach ($receipt in @($Evidence.foundation,$Evidence.dependency)) {
            Assert-RuntimeReceipt $receipt
            Assert-FoundationEqual $receipt.manifest.originalSha $Evidence.originalSha
            Assert-FoundationEqual $receipt.output.originalSha $Evidence.originalSha
        }
        $foundation=$Evidence.foundation.output.foundation; $dependency=$Evidence.dependency.output.standard
        if ($foundation -isnot [hashtable] -or $dependency -isnot [hashtable]) { throw 'Foundation and dependency outputs required' }
        Assert-FoundationEqual $Evidence.foundation.manifest.stage 'foundation-only'
        Assert-FoundationEqual $Evidence.foundation.manifest.completedStages @('foundation')
        Assert-FoundationEqual $foundation.stage 'foundation-only'
        Assert-FoundationEqual $foundation.completeLab $false
        Assert-FoundationEqual $Evidence.dependency.manifest.stage 'dependencies'
        Assert-FoundationEqual $Evidence.dependency.manifest.project $Selector
        Assert-FoundationEqual $Evidence.dependency.manifest.foundationOutputHash $Evidence.foundation.outputHash
        Assert-FoundationEqual $Evidence.dependency.output.foundationOutputHash $Evidence.foundation.outputHash
        Assert-FoundationEqual $Evidence.dependency.output.completeLab $false
        $caseId=$Selector.Substring(0,1); $stem="fgl-$($State.labId)"; $subscription="/subscriptions/$($State.subscriptionId)"
        $groupName="rg-$stem-case-$caseId"; $group="$subscription/resourceGroups/$groupName"
        Assert-FoundationText $Scope $group
        foreach ($pair in @(@('stage','dependencies'),@('projectSelector',$Selector),@('labId',$State.labId),@('ownershipId',$State.ownershipId),@('resourceGroupName',$groupName),@('resourceGroupId',$group),@('integrationResourceGroupName',"rg-$stem-integration"))) { Assert-FoundationEqual $dependency[$pair[0]] $pair[1] }
        Assert-FoundationEqual $dependency.completeLab $false
        $code=@{'a-test'='at';'b-dev'='bd';'b-test'='bt'}[$Selector]
        if ($dependency.storage -isnot [hashtable] -or $dependency.storage.name -isnot [string] -or $dependency.storage.name -cnotmatch ('^stfgx'+$code+'[a-z0-9]{13}$')) { throw 'Selected expansion storage name required' }
        $suffix=$dependency.storage.name.Substring(7)
        $account="$group/providers/Microsoft.CognitiveServices/accounts/aif-$stem-$caseId-$suffix"
        $project="$account/projects/case-$Selector"; $storage="$group/providers/Microsoft.Storage/storageAccounts/stfgx$code$suffix"
        $cosmosName="cosmos-$stem-exp-$code-$suffix"; $cosmos="$group/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosName"
        foreach ($pair in @(@('accountId',$account),@('projectId',$project))) { Assert-FoundationText $dependency[$pair[0]] $pair[1] }
        Assert-FoundationText $dependency.storage.id $storage
        Assert-FoundationEqual $dependency.cosmos.name $cosmosName
        Assert-FoundationText $dependency.cosmos.id $cosmos
        Assert-FoundationEqual $dependency.search.name "srch-$stem-exp-$Selector-$suffix"
        Assert-FoundationGuid $dependency.projectPrincipalId
        Assert-FoundationText $foundation.caseBAccountId "$subscription/resourceGroups/rg-$stem-case-b/providers/Microsoft.CognitiveServices/accounts/aif-$stem-b-$suffix"
        Assert-FoundationText $foundation.resourceGroupId "$subscription/resourceGroups/rg-$stem-case-b"
        Assert-FoundationText $foundation.workspaceId "$subscription/resourceGroups/rg-$stem-case-b/providers/Microsoft.OperationalInsights/workspaces/log-$stem-case-b"
        if ($foundation.projects -isnot [array] -or $foundation.projects.Count -ne 3) { throw 'Complete foundation project receipt array required' }
        $seen=@{}; $selected=$null
        foreach ($selection in @('a-test','b-dev','b-test')) {
            $case=$selection.Substring(0,1)
            $id="$subscription/resourceGroups/rg-$stem-case-$case/providers/Microsoft.CognitiveServices/accounts/aif-$stem-$case-$suffix/projects/case-$selection"
            $matches=@($foundation.projects | Where-Object { $_ -is [hashtable] -and $_.resourceId -is [string] -and $_.resourceId -ieq $id })
            if ($matches.Count -ne 1) { throw 'Missing or duplicate foundation project' }
            Assert-FoundationGuid $matches[0].principalId
            if ($seen.ContainsKey($matches[0].principalId)) { throw 'Distinct project managed identities required' }
            $seen[$matches[0].principalId]=$true
            if ($selection -ceq $Selector) { $selected=$matches[0] }
        }
        Assert-FoundationText $selected.principalId $dependency.projectPrincipalId
        $resources=$Evidence.resources
        Assert-RuntimeKeys $resources @('account','project','storage','cosmos','database','accountHost','projectHost')
        foreach ($spec in @(@('account',$account,'Microsoft.CognitiveServices/accounts'),@('project',$project,'Microsoft.CognitiveServices/accounts/projects'),@('storage',$storage,'Microsoft.Storage/storageAccounts'),@('cosmos',$cosmos,'Microsoft.DocumentDB/databaseAccounts'),@('database',"$cosmos/sqlDatabases/enterprise_memory",'Microsoft.DocumentDB/databaseAccounts/sqlDatabases'))) {
            Assert-RuntimeResource $resources[$spec[0]] $spec[1] $spec[2]
            if ($spec[0] -cne 'database') {
                Assert-FoundationOwned $State $resources[$spec[0]] $spec[1]
                Assert-FoundationEqual $resources[$spec[0]].properties.provisioningState 'Succeeded'
            }
        }
        Assert-FoundationEqual $resources.database.properties.resource.id 'enterprise_memory'
        foreach ($resource in @($resources.account,$resources.project)) {
            Assert-FoundationEqual $resource.identity.type 'SystemAssigned'
            Assert-FoundationGuid $resource.identity.principalId
            Assert-FoundationText $resource.identity.tenantId $State.tenantId
            if ($resource.identity.userAssignedIdentities) { throw 'Unexpected managed identity override' }
        }
        Assert-FoundationText $resources.project.identity.principalId $dependency.projectPrincipalId
        if ($resources.account.identity.principalId -ieq $dependency.projectPrincipalId) { throw 'Account identity is not the project identity' }
        foreach ($resource in @($resources.account,$resources.storage,$resources.cosmos)) { Assert-FoundationText $resource.properties.publicNetworkAccess 'Disabled' }
        foreach ($resource in @($resources.account,$resources.cosmos)) { Assert-FoundationEqual $resource.properties.disableLocalAuth $true }
        foreach ($field in @('allowSharedKeyAccess','allowBlobPublicAccess')) { Assert-FoundationEqual $resources.storage.properties[$field] $false }
        if ($resources.project.properties.ContainsKey('publicNetworkAccess')) { Assert-FoundationText $resources.project.properties.publicNetworkAccess 'Disabled' }
        $containers=Get-ExpansionRuntimeAccessContainers $storage $resources.project.properties.internalId $Evidence.containers
        Assert-RuntimeKeys $Evidence.hosts @('account','project')
        foreach ($stage in @('account','project')) {
            $receipt=$Evidence.hosts[$stage]; Assert-RuntimeReceipt $receipt
            $hostOutput=$receipt.output; $manifest=$receipt.manifest; $host=$resources["${stage}Host"]
            $hostParent=if ($stage -ceq 'account') { $account } else { $project }
            $hostKey=if ($stage -ceq 'account') { "account-$caseId" } else { "project-$Selector" }
            $hostType=if ($stage -ceq 'account') { 'Microsoft.CognitiveServices/accounts/capabilityHosts' } else { 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts' }
            $allowed=@("$hostParent/capabilityHosts/agents")
            if ($stage -ceq 'account') { $allowed+="$account/capabilityHosts/$(($account -split '/')[-1])@aml_aiagentservice" }
            if ($hostOutput.hostId -isnot [string] -or $hostOutput.hostId -inotin $allowed) { throw 'Host receipt escaped selected parent' }
            foreach ($pair in @(@('stage','hosts'),@('key',$hostKey),@('hostId',$hostOutput.hostId))) {
                Assert-FoundationEqual $hostOutput[$pair[0]] $pair[1]
                Assert-FoundationEqual $manifest[$pair[0]] $pair[1]
            }
            foreach ($flag in @('runtimeVerified','completeLab')) { Assert-FoundationEqual $hostOutput[$flag] $false }
            Assert-FoundationEqual $hostOutput.azureReadOnly $true
            if ($hostOutput.mode -cnotin @('Create','Reuse')) { throw 'Verified host mode required' }
            Assert-FoundationEqual $manifest.mode $hostOutput.mode
            Assert-FoundationEqual $hostOutput.deploymentId $manifest.deploymentId
            Assert-FoundationEqual $hostOutput.inputHashes $manifest.review.fileHashes
            Assert-FoundationEqual $hostOutput.sourceHashes $manifest.review.sourceHashes
            if ($hostOutput.inputHashes -isnot [hashtable] -or -not $hostOutput.inputHashes.Count -or $hostOutput.sourceHashes -isnot [hashtable] -or -not $hostOutput.sourceHashes.Count) { throw 'Host provenance required' }
            foreach ($value in @($hostOutput.inputHashes.Values)+@($hostOutput.sourceHashes.Values)) { Assert-RuntimeHash $value }
            Assert-FoundationEqual $manifest.review.inputHashes.state $Evidence.originalSha
            foreach ($hash in @($Evidence.foundation.outputHash,$Evidence.dependency.outputHash)) { if ($hash -cnotin @($hostOutput.inputHashes.Values)) { throw 'Host is not bound to supplied prerequisite seals' } }
            $intent=Copy-RuntimeValue $manifest; $intent.pending=$true; $intent.verified=$false; $intent.Remove('outputHash')
            Assert-FoundationEqual $hostOutput.intentHash (Get-FoundationHash $intent)
            if ($hostOutput.mode -ceq 'Create') {
                Assert-FoundationText $manifest.deploymentId "$group/providers/Microsoft.Resources/deployments/$stem-exp-host-$hostKey"
                Assert-FoundationEqual $hostOutput.submissionWrites 1
                Assert-RuntimeKeys $hostOutput.deploymentProof @('deploymentHash','operationsHash')
                foreach ($value in $hostOutput.deploymentProof.Values) { Assert-RuntimeHash $value }
            } else {
                Assert-FoundationEqual $manifest.deploymentId $null
                Assert-FoundationEqual $hostOutput.submissionWrites 0
                Assert-FoundationEqual $hostOutput.deploymentProof @{}
            }
            Assert-RuntimeResource $host $hostOutput.hostId $hostType
            Assert-FoundationEqual $host.properties.provisioningState 'Succeeded'
            if ($host.properties.ContainsKey('enablePublicHostingEnvironment')) { Assert-FoundationEqual $host.properties.enablePublicHostingEnvironment $false }
            Assert-RuntimeHash $hostOutput.hostHash
            Assert-FoundationEqual (Get-FoundationHash (Select-FoundationConfiguration $host)) $hostOutput.hostHash
            if ($stage -ceq 'account') {
                Assert-FoundationEqual $host.properties.capabilityHostKind 'Agents'
                $subnet=$host.properties.customerSubnet
                if ($subnet -is [hashtable]) { $subnet=$subnet.id }
                Assert-FoundationText $subnet "$subscription/resourceGroups/rg-$stem-integration/providers/Microsoft.Network/virtualNetworks/vnet-$stem/subnets/snet-agent-$caseId"
            } else {
                foreach ($pair in @(@('storageConnections','storage'),@('vectorStoreConnections','search'),@('threadStorageConnections','cosmos'))) { Assert-FoundationEqual $host.properties[$pair[0]] @($dependency[$pair[1]].name) }
            }
        }
        $protected=Get-RuntimeInventory $Evidence.protectedResources $State.subscriptionId
        if (-not $protected.Count) { throw 'Nonempty preservation inventory required' }
        foreach ($resource in $resources.Values) {
            if (-not $protected.ContainsKey($resource.id)) { throw 'Protected inventory omits a prerequisite' }
            Assert-FoundationEqual $protected[$resource.id] $resource
        }
        $grants=@(
            @{type='microsoft.authorization/roleassignments';scope=$containers.blobstoreId.ToLowerInvariant();principalId=$dependency.projectPrincipalId.ToLowerInvariant();roleDefinitionId="$subscription/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe".ToLowerInvariant()},
            @{type='microsoft.authorization/roleassignments';scope=$containers.agentContainerId.ToLowerInvariant();principalId=$dependency.projectPrincipalId.ToLowerInvariant();roleDefinitionId="$subscription/providers/Microsoft.Authorization/roleDefinitions/b7e6dc6d-f1e8-4753-8033-0f276bb0955b".ToLowerInvariant()},
            @{type='microsoft.documentdb/databaseaccounts/sqlroleassignments';scope="$cosmos/dbs/enterprise_memory".ToLowerInvariant();principalId=$dependency.projectPrincipalId.ToLowerInvariant();roleDefinitionId="$cosmos/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002".ToLowerInvariant()}
        )
        $roles=Get-RuntimeInventory $Evidence.roles $State.subscriptionId -AllowInheritedRoles
        foreach ($role in $roles.Values) {
            $tuple=Get-ExpansionRuntimeAccessRole $role $State.subscriptionId
            if ($tuple.principalId -ieq $dependency.projectPrincipalId -and $tuple.scope.StartsWith('/providers/microsoft.management/managementgroups/')) { throw 'Selected project has a preexisting inherited grant; no adoption' }
            if ($tuple.principalId -ieq $dependency.projectPrincipalId -and ($tuple.type -ceq 'microsoft.documentdb/databaseaccounts/sqlroleassignments' -or ($tuple.roleDefinitionId -split '/')[-1] -cin @('ba92f5b4-2d11-453d-a403-e96b0029c9fe','b7e6dc6d-f1e8-4753-8033-0f276bb0955b'))) { throw 'Existing runtime grant or broader data grant; no adoption' }
        }
        $parameters=@{storageName=@{value=$dependency.storage.name};cosmosName=@{value=$cosmosName};projectPrincipalId=@{value=$dependency.projectPrincipalId};workspaceId=@{value=$containers.internalId};agentContainerName=@{value=$containers.agentContainerName}}
        $plan=@{module='infra/modules/standard-access.bicep';parameters=$parameters;grants=$grants;containers=$containers;roles=$roles;protectedResources=$protected}
        return Copy-RuntimeValue @{version=1;selector=$Selector;scope=$Scope;state=$State;evidence=$Evidence;plan=$plan}
    }

    function Assert-RuntimeBinding($Binding, [string]$Scope) {
        Assert-RuntimeKeys $Binding @('version','selector','scope','state','evidence','plan')
        Assert-FoundationText $Binding.scope $Scope
        Assert-FoundationEqual $Binding (Get-ExpansionRuntimeAccessBinding $Binding.state $Binding.selector $Binding.evidence $Scope)
    }

    function Get-ExpansionRuntimeAccessParameters([hashtable]$Binding, [string]$Scope) {
        Assert-RuntimeBinding $Binding $Scope
        return Copy-RuntimeValue $Binding.plan.parameters
    }

    function Assert-ExpansionRuntimeAccessTemplate($Template, $Parameters, [hashtable]$Binding, [string]$Scope) {
        Assert-RuntimeBinding $Binding $Scope
        Assert-FoundationEqual $Parameters $Binding.plan.parameters
        Assert-RuntimeKeys $Template @('$schema','contentVersion','parameters','resources') @('metadata')
        Assert-FoundationEqual $Template.'$schema' 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        Assert-FoundationEqual $Template.contentVersion '1.0.0.0'
        Assert-RuntimeKeys $Template.parameters @('storageName','cosmosName','projectPrincipalId','workspaceId','agentContainerName')
        foreach ($key in $Template.parameters.Keys) {
            $optional=@('metadata'); $required=@('type')
            if ($key -ceq 'agentContainerName') { $required+=@('minLength','maxLength') }
            Assert-RuntimeKeys $Template.parameters[$key] $required $optional
            Assert-FoundationEqual $Template.parameters[$key].type 'string'
            if ($Template.parameters[$key].ContainsKey('metadata')) {
                Assert-RuntimeKeys $Template.parameters[$key].metadata @('description')
                if ($Template.parameters[$key].metadata.description -isnot [string]) { throw 'String parameter description required' }
            }
        }
        Assert-FoundationEqual $Template.parameters.agentContainerName.minLength 50
        Assert-FoundationEqual $Template.parameters.agentContainerName.maxLength 63
        if ($Template.resources -isnot [array] -or $Template.resources.Count -ne 3) { throw 'Exactly three compiled module resources required' }
        $blob="resourceId('Microsoft.Storage/storageAccounts/blobServices/containers', parameters('storageName'), 'default', format('{0}-azureml-blobstore', parameters('workspaceId')))"
        $agent="resourceId('Microsoft.Storage/storageAccounts/blobServices/containers', parameters('storageName'), 'default', parameters('agentContainerName'))"
        $cosmos="resourceId('Microsoft.DocumentDB/databaseAccounts', parameters('cosmosName'))"
        $expected=@()
        foreach ($pair in @(@($blob,'ba92f5b4-2d11-453d-a403-e96b0029c9fe'),@($agent,'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'))) {
            $expected+=@{type='Microsoft.Authorization/roleAssignments';apiVersion='2022-04-01';scope="[$($pair[0])]";name="[guid($($pair[0]), parameters('projectPrincipalId'), '$($pair[1])')]";properties=@{principalId="[parameters('projectPrincipalId')]";principalType='ServicePrincipal';roleDefinitionId="[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '$($pair[1])')]"}}
        }
        $expected+=@{type='Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments';apiVersion='2024-11-15';name="[format('{0}/{1}', parameters('cosmosName'), guid($cosmos, parameters('projectPrincipalId'), 'enterprise_memory', '00000000-0000-0000-0000-000000000002'))]";properties=@{principalId="[parameters('projectPrincipalId')]";roleDefinitionId="[format('{0}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002', $cosmos)]";scope="[format('{0}/dbs/enterprise_memory', $cosmos)]"}}
        Assert-FoundationEqual @($Template.resources | Sort-Object name) @($expected | Sort-Object name)
    }

    function Assert-ExpansionRuntimeAccessPreserved([hashtable]$Binding, [hashtable]$State, [hashtable]$Resources, $Containers, $Roles, $ProtectedResources) {
        Assert-RuntimeBinding $Binding $Binding.scope
        Assert-FoundationEqual $State $Binding.state
        Assert-FoundationEqual $Resources $Binding.evidence.resources
        $selected=Get-ExpansionRuntimeAccessContainers $Resources.storage.id $Resources.project.properties.internalId $Containers
        Assert-FoundationEqual $selected $Binding.plan.containers
        $protected=Get-RuntimeInventory $ProtectedResources $State.subscriptionId
        Assert-FoundationEqual $protected $Binding.plan.protectedResources
        $actual=Get-RuntimeInventory $Roles $State.subscriptionId -AllowInheritedRoles; $before=$Binding.plan.roles; $added=@()
        foreach ($id in $before.Keys) {
            if (-not $actual.ContainsKey($id)) { throw 'Preexisting role removed' }
            Assert-FoundationEqual $actual[$id] $before[$id]
        }
        foreach ($id in $actual.Keys) {
            if ($before.ContainsKey($id)) { continue }
            $role=$actual[$id]; $tuple=Get-ExpansionRuntimeAccessRole $role $State.subscriptionId
            $optional=@('provisioningState','createdOn','updatedOn','createdBy','updatedBy')
            $required=@('principalId','roleDefinitionId','scope')
            if ($tuple.type -ceq 'microsoft.authorization/roleassignments') {
                $required+='principalType'
                Assert-FoundationEqual $role.properties.principalType 'ServicePrincipal'
            }
            Assert-RuntimeKeys $role.properties $required $optional
            if ($role.properties.ContainsKey('provisioningState')) { Assert-FoundationEqual $role.properties.provisioningState 'Succeeded' }
            $added+=$tuple
        }
        if ($added.Count -ne 3) { throw 'Exactly three new runtime grants required' }
        Assert-FoundationEqual @($added | Sort-Object scope) @($Binding.plan.grants | Sort-Object scope)
    }

    Export-ModuleMember -Function *-ExpansionRuntimeAccess*
} | Import-Module