[CmdletBinding()]
param([string]$CompiledModulePath)

$ErrorActionPreference='Stop'
$testRoot=$PSScriptRoot
$testScript=Join-Path $testRoot '../scripts/ExpansionRuntimeAccess.ps1'
$checks=@{count=0;positive=0;rejected=0;selectors=0}
function Check([bool]$Value) { if (-not $Value) { throw 'Expansion runtime access assertion failed' }; $checks.count++ }
function Positive([scriptblock]$Probe) { $null=& $Probe; $checks.positive++; Check $true }
function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed; $checks.rejected++ }
function Clone($Value) {
    $options=@{AsHashtable=$true;Depth=100;NoEnumerate=$true}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind='String' }
    return ,(ConvertTo-Json -InputObject $Value -Depth 100 | ConvertFrom-Json @options)
}
function Hash($Value) { return & (Get-Module ExpansionRuntimeAccess) { param($InputValue) Get-FoundationHash $InputValue } $Value }
function Invoke-LabAz { throw 'Offline test forbids Azure calls' }
function Read-LabRun { throw 'Offline test forbids reading execution state' }
function Save-LabRun { throw 'Offline test forbids writing execution state' }

$StatePath='caller-state'; $Project='b-test'; $Action='Status'; $BicepExecutable='caller-compiler'; $DefinitionsOnly=$false
. $testScript -DefinitionsOnly
Check ($StatePath -ceq 'caller-state' -and $Project -ceq 'b-test' -and $Action -ceq 'Status' -and $BicepExecutable -ceq 'caller-compiler' -and -not $DefinitionsOnly)

function New-Resource([string]$Id, [string]$Type, [hashtable]$Properties) {
    return @{id=$Id;name=($Id -split '/')[-1];type=$Type;properties=$Properties}
}

function New-RuntimeFixture([string]$Selector, [switch]$HashedAgent) {
    $state=@{subscriptionId='11111111-1111-4111-8111-111111111111';tenantId='22222222-2222-4222-8222-222222222222';ownershipId='33333333-3333-4333-8333-333333333333';labId='sample01';standard=@{completedStages=@('dependencies','account','project','access')}}
    $principals=@{'a-test'='44444444-4444-4444-8444-444444444444';'b-dev'='55555555-5555-4555-8555-555555555555';'b-test'='66666666-6666-4666-8666-666666666666'}
    $subscription="/subscriptions/$($state.subscriptionId)"; $case=$Selector.Substring(0,1); $code=@{'a-test'='at';'b-dev'='bd';'b-test'='bt'}[$Selector]
    $groupName="rg-fgl-sample01-case-$case"; $scope="$subscription/resourceGroups/$groupName"
    $account="$scope/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-$case-abcdefghijklm"
    $projectId="$account/projects/case-$Selector"; $principal=$principals[$Selector]
    $storageName="stfgx${code}abcdefghijklm"; $storage="$scope/providers/Microsoft.Storage/storageAccounts/$storageName"
    $cosmosName="cosmos-fgl-sample01-exp-$code-abcdefghijklm"; $cosmos="$scope/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosName"
    $searchName="srch-fgl-sample01-exp-$Selector-abcdefghijklm"; $internal='22222222-2222-4222-8222-222222222222'
    $foundation=@{stage='foundation-only';completeLab=$false;resourceGroupId="$subscription/resourceGroups/rg-fgl-sample01-case-b";caseBAccountId="$subscription/resourceGroups/rg-fgl-sample01-case-b/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-b-abcdefghijklm";workspaceId="$subscription/resourceGroups/rg-fgl-sample01-case-b/providers/Microsoft.OperationalInsights/workspaces/log-fgl-sample01-case-b";projects=@()}
    foreach ($selection in @('a-test','b-dev','b-test')) {
        $caseLetter=$selection.Substring(0,1)
        $foundation.projects+=@{name="case-$selection";resourceId="$subscription/resourceGroups/rg-fgl-sample01-case-$caseLetter/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-$caseLetter-abcdefghijklm/projects/case-$selection";principalId=$principals[$selection]}
    }
    $dependency=@{stage='dependencies';completeLab=$false;projectSelector=$Selector;labId=$state.labId;ownershipId=$state.ownershipId;resourceGroupName=$groupName;resourceGroupId=$scope;integrationResourceGroupName='rg-fgl-sample01-integration';accountId=$account;projectId=$projectId;projectPrincipalId=$principal;storage=@{name=$storageName;id=$storage};cosmos=@{name=$cosmosName;id=$cosmos};search=@{name=$searchName}}
    $evidence=@{originalSha=('A'*64);foundation=@{manifest=@{stage='foundation-only';pending=$false;verified=$true;originalSha=('A'*64);outputHash=('B'*64);completedStages=@('foundation')};output=@{foundation=$foundation;originalSha=('A'*64);controlPlaneVerified=$true;inferenceVerified=$false};outputHash=('B'*64)};dependency=@{manifest=@{stage='dependencies';project=$Selector;pending=$false;verified=$true;originalSha=('A'*64);outputHash=('C'*64);foundationOutputHash=('B'*64)};output=@{standard=$dependency;originalSha=('A'*64);foundationOutputHash=('B'*64);controlPlaneVerified=$true;inferenceVerified=$false;completeLab=$false};outputHash=('C'*64)};hosts=@{};resources=@{};containers=@();roles=@();protectedResources=@()}
    $resources=$evidence.resources
    $resources.account=New-Resource $account 'Microsoft.CognitiveServices/accounts' @{provisioningState='Succeeded';publicNetworkAccess='Disabled';disableLocalAuth=$true}
    $resources.account.identity=@{type='SystemAssigned';tenantId=$state.tenantId;principalId=$state.ownershipId}
    $resources.project=New-Resource $projectId 'Microsoft.CognitiveServices/accounts/projects' @{provisioningState='Succeeded';internalId=$internal;publicNetworkAccess='Disabled'}
    $resources.project.identity=@{type='SystemAssigned';tenantId=$state.tenantId;principalId=$principal}
    $resources.storage=New-Resource $storage 'Microsoft.Storage/storageAccounts' @{provisioningState='Succeeded';publicNetworkAccess='Disabled';allowSharedKeyAccess=$false;allowBlobPublicAccess=$false}
    $resources.cosmos=New-Resource $cosmos 'Microsoft.DocumentDB/databaseAccounts' @{provisioningState='Succeeded';publicNetworkAccess='Disabled';disableLocalAuth=$true}
    $resources.database=New-Resource "$cosmos/sqlDatabases/enterprise_memory" 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases' @{resource=@{id='enterprise_memory'}}
    foreach ($key in @('account','project','storage','cosmos')) { $resources[$key].tags=@{'fgl-owner'=$state.ownershipId;'fgl-lab'=$state.labId;purpose='synthetic-governance-lab'} }
    $resources.accountHost=New-Resource "$account/capabilityHosts/agents" 'Microsoft.CognitiveServices/accounts/capabilityHosts' @{provisioningState='Succeeded';capabilityHostKind='Agents';customerSubnet="$subscription/resourceGroups/rg-fgl-sample01-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01/subnets/snet-agent-$case"}
    $resources.projectHost=New-Resource "$projectId/capabilityHosts/agents" 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts' @{provisioningState='Succeeded';storageConnections=@($storageName);vectorStoreConnections=@($searchName);threadStorageConnections=@($cosmosName)}
    foreach ($stage in @('account','project')) {
        $hostResource=$resources["${stage}Host"]; $hostKey=if ($stage -ceq 'account') { "account-$case" } else { "project-$Selector" }
        $manifest=@{stage='hosts';key=$hostKey;hostId=$hostResource.id;mode='Reuse';deploymentId=$null;pending=$false;verified=$true;outputHash=('D'*64);review=@{inputHashes=@{state=('A'*64)};fileHashes=@{foundation=('B'*64);dependency=('C'*64)};sourceHashes=@{hosts=('E'*64)}}}
        $intent=Clone $manifest; $intent.pending=$true; $intent.verified=$false; $intent.Remove('outputHash')
        $hostHash=& (Get-Module ExpansionRuntimeAccess) { param($HostResource) Get-FoundationHash (Select-FoundationConfiguration $HostResource) } $hostResource
        $output=@{stage='hosts';key=$hostKey;hostId=$hostResource.id;mode='Reuse';deploymentId=$null;controlPlaneVerified=$true;runtimeVerified=$false;inferenceVerified=$false;completeLab=$false;azureReadOnly=$true;submissionWrites=0;deploymentProof=@{};inputHashes=(Clone $manifest.review.fileHashes);sourceHashes=(Clone $manifest.review.sourceHashes);intentHash=(Hash $intent);hostHash=$hostHash}
        $evidence.hosts[$stage]=@{manifest=$manifest;output=$output;outputHash=('D'*64)}
    }
    $agentName=if ($HashedAgent) { "$internal-abcdef123456-azureml-agent" } else { "$internal-azureml-agent" }
    foreach ($name in @("$internal-azureml-blobstore",$agentName,'unrelated-container')) {
        $evidence.containers+=(New-Resource "$storage/blobServices/default/containers/$name" 'Microsoft.Storage/storageAccounts/blobServices/containers' @{publicAccess='None'})
    }
    $otherRoleId="$account/providers/Microsoft.Authorization/roleAssignments/11111111-1111-4111-8111-111111111111"
    $evidence.roles=@((New-Resource $otherRoleId 'Microsoft.Authorization/roleAssignments' @{scope=$account;principalId=$state.ownershipId;principalType='ServicePrincipal';roleDefinitionId="$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"}))
    $evidence.protectedResources=@($resources.Values | ForEach-Object { Clone $_ })
    $evidence.protectedResources+=(New-Resource "$subscription/resourceGroups/rg-fgl-sample01-integration/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-sample01-endpoints" 'Microsoft.Network/networkSecurityGroups' @{securityRules=@(@{name='allow-case-a-cosmos-direct';properties=@{priority=125}})})
    return @{state=$state;selector=$Selector;scope=$scope;evidence=$evidence}
}

function New-CompiledFixture {
    $template=@{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#';contentVersion='1.0.0.0';parameters=@{};resources=@()}
    foreach ($parameter in @('storageName','cosmosName','projectPrincipalId','workspaceId','agentContainerName')) { $template.parameters[$parameter]=@{type='string';metadata=@{description='Synthetic module contract'}} }
    $template.parameters.agentContainerName.minLength=50; $template.parameters.agentContainerName.maxLength=63
    $blob="resourceId('Microsoft.Storage/storageAccounts/blobServices/containers', parameters('storageName'), 'default', format('{0}-azureml-blobstore', parameters('workspaceId')))"
    $agent="resourceId('Microsoft.Storage/storageAccounts/blobServices/containers', parameters('storageName'), 'default', parameters('agentContainerName'))"
    $cosmos="resourceId('Microsoft.DocumentDB/databaseAccounts', parameters('cosmosName'))"
    foreach ($pair in @(@($blob,'ba92f5b4-2d11-453d-a403-e96b0029c9fe'),@($agent,'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'))) {
        $template.resources+=@{type='Microsoft.Authorization/roleAssignments';apiVersion='2022-04-01';scope="[$($pair[0])]";name="[guid($($pair[0]), parameters('projectPrincipalId'), '$($pair[1])')]";properties=@{principalId="[parameters('projectPrincipalId')]";principalType='ServicePrincipal';roleDefinitionId="[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '$($pair[1])')]"}}
    }
    $template.resources+=@{type='Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments';apiVersion='2024-11-15';name="[format('{0}/{1}', parameters('cosmosName'), guid($cosmos, parameters('projectPrincipalId'), 'enterprise_memory', '00000000-0000-0000-0000-000000000002'))]";properties=@{principalId="[parameters('projectPrincipalId')]";scope="[format('{0}/dbs/enterprise_memory', $cosmos)]";roleDefinitionId="[format('{0}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002', $cosmos)]"}}
    return $template
}

function New-GrantedRoles($Binding) {
    $identifiers=@('44444444-4444-4444-8444-444444444444','55555555-5555-4555-8555-555555555555','66666666-6666-4666-8666-666666666666'); $result=@(); $index=0
    foreach ($grant in $Binding.plan.grants) {
        $properties=@{scope=$grant.scope;principalId=$grant.principalId;roleDefinitionId=$grant.roleDefinitionId}
        if ($grant.type -ceq 'microsoft.authorization/roleassignments') {
            $id="$($grant.scope)/providers/Microsoft.Authorization/roleAssignments/$($identifiers[$index])"; $properties.principalType='ServicePrincipal'
        } else { $id="$($Binding.evidence.resources.cosmos.id)/sqlRoleAssignments/$($identifiers[$index])" }
        $result+=(New-Resource $id $grant.type $properties); $index++
    }
    return ,$result
}

function New-InheritedRuntimeRole([string]$SubscriptionId) {
    $scope='/providers/Microsoft.Management/managementGroups/22222222-2222-4222-8222-222222222222'
    return New-Resource "$scope/providers/Microsoft.Authorization/roleAssignments/11111111-1111-4111-8111-111111111111" 'Microsoft.Authorization/roleAssignments' @{scope=$scope;principalId='33333333-3333-4333-8333-333333333333';principalType='Group';roleDefinitionId="/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/66666666-6666-4666-8666-666666666666";condition=$null;description='Preserve inherited evidence';createdOn='2026-09-20T00:00:00Z'}
}

& {
    $fixture=New-RuntimeFixture 'a-test'
    $inherited=New-InheritedRuntimeRole $fixture.state.subscriptionId
    $fixture.evidence.roles+=$inherited
    $original=Hash $fixture
    $binding=Get-ExpansionRuntimeAccessBinding $fixture.state 'a-test' $fixture.evidence $fixture.scope
    Check ((Hash $fixture) -ceq $original -and (Hash $binding.plan.roles[$inherited.id]) -ceq (Hash $inherited))
    $after=@($fixture.evidence.roles)+(New-GrantedRoles $binding)
    Positive { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $after $fixture.evidence.protectedResources }
    $missing=@($after | Where-Object id -NE $inherited.id)
    Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $missing $fixture.evidence.protectedResources }
    $extra=Clone $inherited; $extra.name='55555555-5555-4555-8555-555555555555'; $extra.id="$($extra.properties.scope)/providers/Microsoft.Authorization/roleAssignments/$($extra.name)"
    Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers @($after+$extra) $fixture.evidence.protectedResources }
    foreach ($field in @('description','principalId','roleDefinitionId','condition','createdOn')) {
        $changed=Clone $after; $changed[1].properties[$field]='changed'
        Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $changed $fixture.evidence.protectedResources }
    }
    foreach ($mutation in @(
        {param($role) $role.properties.scope=$role.properties.scope.Replace('22222222-2222-4222-8222-222222222222','55555555-5555-4555-8555-555555555555')},
        {param($role) $role.id=$role.id.Replace('22222222-2222-4222-8222-222222222222','55555555-5555-4555-8555-555555555555')},
        {param($role) $role.id+='/extra'},
        {param($role) $role.id=$role.id.Replace('managementGroups/','managementGroups/%')},
        {param($role) $role.id=$role.id.Replace('22222222-2222-4222-8222-222222222222','malformed')},
        {param($role) $role.name='55555555-5555-4555-8555-555555555555'},
        {param($role) $role.type='Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments'},
        {param($role) $role.properties.roleDefinitionId=$role.properties.roleDefinitionId.Replace('11111111-1111-4111-8111-111111111111','55555555-5555-4555-8555-555555555555')},
        {param($role) $role.properties.scope='/subscriptions/55555555-5555-4555-8555-555555555555'; $role.id="$($role.properties.scope)/providers/Microsoft.Authorization/roleAssignments/$($role.name)"},
        {param($role) $role.properties.principalId='44444444-4444-4444-8444-444444444444'}
    )) {
        $bad=Clone $fixture.evidence; & $mutation $bad.roles[1]
        Reject { Get-ExpansionRuntimeAccessBinding $fixture.state 'a-test' $bad $fixture.scope }
    }
    $bad=Clone $fixture.evidence; $bad.protectedResources+=$inherited
    Reject { Get-ExpansionRuntimeAccessBinding $fixture.state 'a-test' $bad $fixture.scope }
}

foreach ($selector in @('a-test','b-dev','b-test')) {
    $checks.selectors++
    foreach ($hashed in @($false,$true)) {
        $fixture=New-RuntimeFixture $selector -HashedAgent:$hashed
        $unchanged=Hash $fixture
        $binding=Get-ExpansionRuntimeAccessBinding $fixture.state $selector $fixture.evidence $fixture.scope
        Check ((Hash $fixture) -ceq $unchanged)
        Check ($binding.plan.grants.Count -eq 3 -and $binding.plan.roles.Count -gt 0 -and $binding.plan.protectedResources.Count -ge 8)
        $parameters=Get-ExpansionRuntimeAccessParameters $binding $fixture.scope
        Check ($parameters.Count -eq 5 -and $parameters.projectPrincipalId.value -ceq $fixture.evidence.resources.project.identity.principalId)
        Check ($parameters.workspaceId.value -ceq '22222222-2222-4222-8222-222222222222' -and $parameters.workspaceId.value -cne $fixture.evidence.foundation.output.foundation.workspaceId)
        Check ($parameters.agentContainerName.value -ceq $fixture.evidence.containers[1].name)
        Check ($binding.plan.grants[0].scope -ieq $fixture.evidence.containers[0].id -and $binding.plan.grants[1].scope -ieq $fixture.evidence.containers[1].id)
        Check ($binding.plan.grants[2].scope -ieq "$($fixture.evidence.resources.cosmos.id)/dbs/enterprise_memory")
        Check ($binding.plan.grants[0].roleDefinitionId.EndsWith('/ba92f5b4-2d11-453d-a403-e96b0029c9fe') -and $binding.plan.grants[1].roleDefinitionId.EndsWith('/b7e6dc6d-f1e8-4753-8033-0f276bb0955b') -and $binding.plan.grants[2].roleDefinitionId.EndsWith('/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002',[StringComparison]::OrdinalIgnoreCase))
        $template=New-CompiledFixture
        Positive { Assert-ExpansionRuntimeAccessTemplate $template $parameters $binding $fixture.scope }
        if ($CompiledModulePath) {
            $compiled=Get-Content -LiteralPath $CompiledModulePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            Positive { Assert-ExpansionRuntimeAccessTemplate $compiled $parameters $binding $fixture.scope }
        }
        $newRoles=New-GrantedRoles $binding; $afterRoles=@($fixture.evidence.roles)+$newRoles
        Positive { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $afterRoles $fixture.evidence.protectedResources }
        Positive { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources @($fixture.evidence.containers | Sort-Object id -Descending) @($afterRoles | Sort-Object id -Descending) @($fixture.evidence.protectedResources | Sort-Object id -Descending) }
        Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $fixture.evidence.roles $fixture.evidence.protectedResources }

        foreach ($mutation in @(
            {param($value) $value.originalSha='invalid'},
            {param($value) $value.foundation.manifest.pending=$true},
            {param($value) $value.foundation.manifest.verified='true'},
            {param($value) $value.foundation.output.controlPlaneVerified='true'},
            {param($value) $value.foundation.output.originalSha=('F'*64)},
            {param($value) $value.foundation.outputHash=('F'*64)},
            {param($value) $value.foundation.output.foundation.completeLab=$true},
            {param($value) $value.foundation.output.foundation.workspaceId=$value.resources.project.properties.internalId},
            {param($value) $value.foundation.output.foundation.projects=@()},
            {param($value) $value.foundation.output.foundation.projects[1]=$value.foundation.output.foundation.projects[0]},
            {param($value) $selected=@($value.foundation.output.foundation.projects | Where-Object resourceId -IEQ $value.resources.project.id)[0]; $selected.principalId=$value.resources.account.identity.principalId},
            {param($value) $value.dependency.manifest.pending=$true},
            {param($value) $value.dependency.output.inferenceVerified=$true},
            {param($value) $value.dependency.output.foundationOutputHash=('F'*64)},
            {param($value) $value.dependency.output.standard.projectSelector='a-dev'},
            {param($value) $value.dependency.output.standard.projectPrincipalId=$value.resources.account.identity.principalId},
            {param($value) $value.dependency.output.standard.storage.name+='x'},
            {param($value) $value.dependency.output.standard.cosmos.id+='-foreign'},
            {param($value) $value.dependency.output.standard.accountId+='-foreign'},
            {param($value) $value.dependency.output.standard.projectId+='-foreign'},
            {param($value) $value.dependency.output.standard.resourceGroupId+='-foreign'},
            {param($value) $value.dependency.output.standard.ownershipId=$true},
            {param($value) $value.resources.project.identity.principalId=$value.resources.account.identity.principalId},
            {param($value) $value.resources.project.identity.type='UserAssigned'},
            {param($value) $value.resources.project.identity.tenantId=$value.resources.account.identity.principalId},
            {param($value) $value.resources.project.properties.internalId=$value.foundation.output.foundation.workspaceId},
            {param($value) $value.resources.project.properties.Remove('internalId'); $value.resources.project.properties.workspaceId='22222222-2222-4222-8222-222222222222'},
            {param($value) $value.resources.storage.properties.allowSharedKeyAccess='false'},
            {param($value) $value.resources.cosmos.properties.disableLocalAuth=$false},
            {param($value) $value.resources.database=$null},
            {param($value) $value.resources.database.properties.resource.id='other'},
            {param($value) $value.containers=@{value=$value.containers;nextLink='next-page'}},
            {param($value) $value.containers=@($value.containers[1])},
            {param($value) $value.containers+=$value.containers[0]},
            {param($value) $value.containers[0].nextLink=$null},
            {param($value) $value.containers[0].properties.publicAccess='Blob'},
            {param($value) $value.containers[1].id+='-foreign'},
            {param($value) $value.containers[1].name=$value.containers[1].name.ToUpperInvariant()},
            {param($value) $value.containers[1].type='Microsoft.Storage/storageAccounts'},
            {param($value) $value.containers[2].id=$value.containers[2].id.Replace('stfgx','stother')},
            {param($value) $value.roles=@{value=$value.roles}},
            {param($value) $value.roles+=$value.roles[0]},
            {param($value) $value.protectedResources=@()},
            {param($value) $value.protectedResources+=$value.protectedResources[0]},
            {param($value) $value.extra=$true}
        )) { $bad=Clone $fixture.evidence; & $mutation $bad; Reject { Get-ExpansionRuntimeAccessBinding $fixture.state $selector $bad $fixture.scope } }

        foreach ($stage in @('account','project')) {
            foreach ($mutation in @(
                {param($value) $value.manifest.verified=$false},
                {param($value) $value.manifest.pending='false'},
                {param($value) $value.output.hostId+='-foreign'},
                {param($value) $value.output.key='project-a-dev'},
                {param($value) $value.output.runtimeVerified=$true},
                {param($value) $value.output.inputHashes=@{}},
                {param($value) $value.manifest.review.inputHashes.state=('F'*64)},
                {param($value) $value.output.intentHash=('F'*64)},
                {param($value) $value.output.hostHash=('F'*64)},
                {param($value) $value.output.submissionWrites=1},
                {param($value) $value.outputHash=('0'*64)}
            )) { $bad=Clone $fixture.evidence; & $mutation $bad.hosts[$stage]; Reject { Get-ExpansionRuntimeAccessBinding $fixture.state $selector $bad $fixture.scope } }
        }
        foreach ($key in $fixture.evidence.resources.Keys) {
            foreach ($field in @('id','name','type')) {
                $bad=Clone $fixture.evidence; $bad.resources[$key][$field]+='-foreign'
                Reject { Get-ExpansionRuntimeAccessBinding $fixture.state $selector $bad $fixture.scope }
            }
        }
        foreach ($name in @('agentContainerName','storageName','cosmosName','projectPrincipalId','workspaceId')) {
            foreach ($wrong in @($true,'foreign','',[guid]::Empty.ToString('D'))) {
                $bad=Clone $parameters; $bad[$name].value=$wrong
                Reject { Assert-ExpansionRuntimeAccessTemplate $template $bad $binding $fixture.scope }
            }
        }
        foreach ($mutation in @(
            {param($value) $value.resources=@()},
            {param($value) $value.resources+=$value.resources[0]},
            {param($value) $value.resources=@{role=$value.resources[0]}},
            {param($value) $value.resources[0].scope="[resourceId('Microsoft.Storage/storageAccounts', parameters('storageName'))]"},
            {param($value) $value.resources[0].name='unbound'},
            {param($value) $value.resources[0].condition=$true},
            {param($value) $value.resources[0].properties.principalId=$true},
            {param($value) $value.resources[0].properties.roleDefinitionId=$value.resources[1].properties.roleDefinitionId},
            {param($value) $value.resources[1].properties.principalType='User'},
            {param($value) $value.resources[2].properties.scope='/'},
            {param($value) $value.resources[2].properties.roleDefinitionId+='-other'},
            {param($value) $value.resources[2].type='Microsoft.DocumentDB/databaseAccounts/sqlDatabases'},
            {param($value) $value.resources[2].apiVersion='2020-01-01'},
            {param($value) $value.resources[2].properties.extra=$true},
            {param($value) $value.'$schema'='foreign'},
            {param($value) $value.contentVersion=$true},
            {param($value) $value.languageVersion='2.0'},
            {param($value) $value.variables=@{}},
            {param($value) $value.outputs=@{}},
            {param($value) $value.parameters.workspaceId.defaultValue='fallback'},
            {param($value) $value.parameters.projectPrincipalId.type='bool'},
            {param($value) $value.parameters.agentContainerName.maxLength='63'},
            {param($value) $value.parameters.agentContainerName.minLength=49},
            {param($value) $value.parameters.extra=@{type='string'}}
        )) { $bad=Clone $template; & $mutation $bad; Reject { Assert-ExpansionRuntimeAccessTemplate $bad $parameters $binding $fixture.scope } }

        foreach ($scope in @("$($fixture.scope)-foreign",$fixture.evidence.resources.account.id,$fixture.scope.Replace($fixture.state.subscriptionId,'66666666-6666-4666-8666-666666666666'))) {
            Reject { Get-ExpansionRuntimeAccessBinding $fixture.state $selector $fixture.evidence $scope }
            Reject { Assert-ExpansionRuntimeAccessTemplate $template $parameters $binding $scope }
        }
        foreach ($index in 0..2) {
            foreach ($field in @('scope','principalId','roleDefinitionId')) {
                $bad=Clone $afterRoles; $bad[$index+1].properties[$field]='foreign'
                Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $bad $fixture.evidence.protectedResources }
            }
            $bad=@($fixture.evidence.roles)+@($newRoles | Where-Object id -NE $newRoles[$index].id)
            Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $bad $fixture.evidence.protectedResources }
            $bad=Clone $afterRoles; $bad[$index+1].properties.condition='unexpected'
            Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $bad $fixture.evidence.protectedResources }
        }
        $bad=Clone $afterRoles; $bad[0].properties.principalId=$parameters.projectPrincipalId.value
        Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $bad $fixture.evidence.protectedResources }
        $extra=Clone $newRoles[0]; $extra.id=$extra.id.Replace('44444444-4444-4444-8444-444444444444','22222222-2222-4222-8222-222222222222'); $extra.name='22222222-2222-4222-8222-222222222222'
        Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers @($afterRoles+$extra) $fixture.evidence.protectedResources }
        $wide=Clone $extra; $wide.properties.scope=$fixture.evidence.resources.storage.id; $wide.id="$($wide.properties.scope)/providers/Microsoft.Authorization/roleAssignments/$($wide.name)"
        Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers @($afterRoles+$wide) $fixture.evidence.protectedResources }
        $bad=Clone $fixture.evidence; $bad.roles+=$wide
        Reject { Get-ExpansionRuntimeAccessBinding $fixture.state $selector $bad $fixture.scope }
        $bad=Clone $fixture.state; $bad.standard.completedStages=@()
        Reject { Assert-ExpansionRuntimeAccessPreserved $binding $bad $fixture.evidence.resources $fixture.evidence.containers $afterRoles $fixture.evidence.protectedResources }
        $bad=Clone $fixture.evidence.protectedResources; $bad[-1].properties.securityRules[0].properties.priority=126
        Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $afterRoles $bad }
        $bad=Clone $fixture.evidence.containers; $bad[2].properties.publicAccess='Blob'
        Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $bad $afterRoles $fixture.evidence.protectedResources }
        $bad=Clone $binding; $bad.plan.parameters.workspaceId.value='foreign'
        Reject { Get-ExpansionRuntimeAccessParameters $bad $fixture.scope }

        $compact=Clone $fixture.evidence; $compact.resources.project.properties.internalId=([guid]$parameters.workspaceId.value).ToString('N')
        foreach ($resource in $compact.protectedResources) { if ($resource.id -ieq $compact.resources.project.id) { $resource.properties.internalId=$compact.resources.project.properties.internalId } }
        $compactBinding=Get-ExpansionRuntimeAccessBinding $fixture.state $selector $compact $fixture.scope
        Check ($compactBinding.plan.parameters.workspaceId.value -ceq $parameters.workspaceId.value)
        $created=Clone $fixture.evidence
        foreach ($stage in @('account','project')) {
            $receipt=$created.hosts[$stage]; $manifest=$receipt.manifest; $output=$receipt.output
            $manifest.mode='Create'; $manifest.deploymentId="$($fixture.scope)/providers/Microsoft.Resources/deployments/fgl-sample01-exp-host-$($manifest.key)"
            $output.mode='Create'; $output.deploymentId=$manifest.deploymentId; $output.submissionWrites=1; $output.deploymentProof=@{deploymentHash=('E'*64);operationsHash=('F'*64)}
            $intent=Clone $manifest; $intent.pending=$true; $intent.verified=$false; $intent.Remove('outputHash'); $output.intentHash=Hash $intent
        }
        Positive { Get-ExpansionRuntimeAccessBinding $fixture.state $selector $created $fixture.scope }
        $second=Clone $fixture.evidence; $other=Clone $second.containers[1]
        $other.name=if ($hashed) { "$($parameters.workspaceId.value)-azureml-agent" } else { "$($parameters.workspaceId.value)-abcdef123456-azureml-agent" }
        $other.id="$($second.resources.storage.id)/blobServices/default/containers/$($other.name)"; $second.containers+=$other
        Reject { Get-ExpansionRuntimeAccessBinding $fixture.state $selector $second $fixture.scope }
        $sealed=Hash $binding; $fixture.evidence.resources.database.properties.resource.id='changed'; $fixture.state.standard.completedStages=@()
        Check ((Hash $binding) -ceq $sealed)
    }
}

foreach ($value in @($null,$true,42,'','not-a-guid',[guid]::Empty.ToString('D'),[guid]::Empty.ToString('N'),'{22222222-2222-4222-8222-222222222222}',' 22222222-2222-4222-8222-222222222222')) { Reject { ConvertTo-ExpansionRuntimeAccessGuid $value } }
$alphaGuid=('22222222-2222-4222-8222-222222222222').Replace('2','a')
Check ((ConvertTo-ExpansionRuntimeAccessGuid $alphaGuid.ToUpperInvariant()) -ceq $alphaGuid)
Check ((ConvertTo-ExpansionRuntimeAccessGuid ($alphaGuid.Replace('-','').ToUpperInvariant())) -ceq $alphaGuid)
$fixture=New-RuntimeFixture 'a-test'
foreach ($selector in @('a-dev','b-prod','A-test','',$null)) { Reject { Get-ExpansionRuntimeAccessBinding $fixture.state $selector $fixture.evidence $fixture.scope } }
Import-Module (Join-Path $testRoot '../scripts/PublicSource.psm1')
foreach ($file in @($testScript,(Join-Path $testRoot 'Test-ExpansionRuntimeAccess.ps1'))) {
    $text=Get-Content -LiteralPath $file -Raw
    Assert-PublicText $text; Check $true
    Check ($text -cnotmatch '[^\x00-\x7F]')
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    Check ($null -ne $ast -and $tokens.Count -gt 0 -and $errors.Count -eq 0)
    if ($file -eq $testScript) {
        $forbidden=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cin @('Invoke-LabAz','Save-LabRun','Read-LabRun','Read-FoundationArm','Get-Content','Get-FileHash','Set-Content','Out-File','New-Item','Remove-Item','Start-Process','Invoke-RestMethod','Invoke-WebRequest','az','bicep')},$true))
        Check ($forbidden.Count -eq 0)
        $dotSources=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot},$true))
        Check ($dotSources.Count -eq 1 -and $dotSources[0].Extent.Text -match '-DefinitionsOnly$')
    }
}
Check ($checks.selectors -eq 3 -and $checks.positive -ge 18 -and $checks.rejected -gt 100 -and $checks.count -gt 100)
Write-Output "PASS: $($checks.count) expansion runtime access offline checks; $($checks.positive) positive checks and $($checks.rejected) rejections. No Azure calls or execution-state writes."
if (-not $CompiledModulePath) { Write-Output 'Actual Bicep compilation was not checked; supply -CompiledModulePath with the existing standard-access module compiled to an external file.' }