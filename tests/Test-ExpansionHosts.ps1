[CmdletBinding()]
param([string]$Compiler = 'bicep')

$ErrorActionPreference='Stop'
$hostTestCompiler=$Compiler
. (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionHosts.ps1') -DefinitionsOnly
$hostTestSourceHashes=Get-ExpansionHostSources
$hostChecks=@{count=0}
function Check([bool]$Condition) { if (-not $Condition) { throw 'Expansion host assertion failed' }; $hostChecks.count++ }
function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed }
function Invoke-LabAz { throw 'Offline tests forbid Azure' }
function Invoke-ExpansionNetworkAz { throw 'Unmocked host transport' }
function Invoke-ExpansionNetworkProcess { throw 'Unmocked coordinator processes are forbidden' }
function Save-LabRun { throw 'Original state must never be written' }

function New-HostTemplateFixture([hashtable]$Binding) {
    $parameters=@{}
    foreach ($key in $Binding.parameters.Keys) { $parameters[$key]=@{type='string'} }
    $properties=@{capabilityHostKind='Agents'}
    $name="[format('{0}/agents', parameters('accountName'))]"
    $output="[resourceId('Microsoft.CognitiveServices/accounts/capabilityHosts', parameters('accountName'), 'agents')]"
    if ($Binding.stage -ceq 'project') {
        $name="[format('{0}/{1}/agents', parameters('accountName'), parameters('projectName'))]"
        $output="[resourceId('Microsoft.CognitiveServices/accounts/projects/capabilityHosts', parameters('accountName'), parameters('projectName'), 'agents')]"
        $properties=@{storageConnections=@("[parameters('storageName')]");vectorStoreConnections=@("[parameters('searchName')]");threadStorageConnections=@("[parameters('cosmosName')]")}
    }
    return @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#';contentVersion='1.0.0.0';metadata=@{_generator=@{name='bicep';version='fixture';templateHash='fixture'}};parameters=$parameters;resources=@(@{type=$Binding.type;apiVersion='2026-05-01';name=$name;properties=$properties});outputs=@{resourceId=@{type='string';value=$output}}}
}

function New-HostResourceFixture([hashtable]$Binding) {
    $properties=@{provisioningState='Succeeded';capabilityHostKind='Agents';customerSubnet=$Binding.subnet}
    if ($Binding.stage -ceq 'project') { $properties=@{provisioningState='Succeeded';storageConnections=@($Binding.parameters.storageName.value);vectorStoreConnections=@($Binding.parameters.searchName.value);threadStorageConnections=@($Binding.parameters.cosmosName.value)} }
    return @{id=$Binding.hostId;type=$Binding.type;properties=$properties}
}

$hostFixtureState=@{labId='sample01';subscriptionId='11111111-1111-4111-8111-111111111111';tenantId='22222222-2222-4222-8222-222222222222';ownershipId='33333333-3333-4333-8333-333333333333';standard=@{deploymentNames=@{}}}
$hostFixtureSubscription="/subscriptions/$($hostFixtureState.subscriptionId)"
$hostFixtureFoundation=@{subscription=$hostFixtureSubscription;vnet="$hostFixtureSubscription/resourceGroups/rg-fgl-sample01-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01"}
foreach ($caseId in @('a','b')) { $hostFixtureFoundation["account$($caseId.ToUpperInvariant())"]="$hostFixtureSubscription/resourceGroups/rg-fgl-sample01-case-$caseId/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-$caseId-abcdefghijklm" }
$hostFixturePrerequisites=@{network=@{foundation=$hostFixtureFoundation;outputs=@{}}}
foreach ($selection in @('a-test','b-dev','b-test')) {
    $account=$hostFixtureFoundation["account$($selection.Substring(0,1).ToUpperInvariant())"]
    $dependency=@{accountId=$account;projectId="$account/projects/case-$selection";projectPrincipalId='44444444-4444-4444-8444-444444444444';resourceGroupId=($account -split '/providers/')[0];connections=@{}}
    foreach ($pair in @(@('storage','Microsoft.Storage/storageAccounts','blob.core.windows.net/'),@('search','Microsoft.Search/searchServices','search.windows.net'),@('cosmos','Microsoft.DocumentDB/databaseAccounts','documents.azure.com:443/'))) {
        $name="$($pair[0])-$selection"
        $dependency[$pair[0]]=@{id="$($dependency.resourceGroupId)/providers/$($pair[1])/$name";name=$name;endpoint="https://$name.$($pair[2])"}
        $dependency.connections[$pair[0]]=@{name=$name;id="$($dependency.projectId)/connections/$name"}
    }
    $hostFixturePrerequisites.network.outputs[$selection]=@{standard=$dependency}
}

$hostFixtureRoot=Assert-ExternalLabPath (Join-Path ([IO.Path]::GetTempPath()) ('expansion-host-test-'+[guid]::NewGuid().ToString('N')))
$null=[IO.Directory]::CreateDirectory($hostFixtureRoot)
try {
    $hostFixtureState.runDirectory=$hostFixtureRoot
    $revisionRelative='scripts/Invoke-ExpansionHosts.ps1'
    $oldText='historical-validator-fixture'
    $oldHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($oldText)))
    $oldSources=@{}; $oldSources[$revisionRelative]=$oldHash
    $newSources=@{}; $newSources[$revisionRelative]=('A'*64)
    $revisionManifest=@{verified=$true;pending=$false;review=@{sourceHashes=$oldSources}}
    $revisionPaths=@{state=(Join-Path $hostFixtureRoot 'historical.state.json')}
    Reject { Get-ExpansionHostSourceRevisions $revisionManifest $revisionPaths $newSources }
    $archive=Join-Path $hostFixtureRoot "host-validator-archive/$oldHash/$revisionRelative"
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($archive))
    [IO.File]::WriteAllText($archive,$oldText,[Text.UTF8Encoding]::new($false))
    $reconciled=Get-ExpansionHostSourceRevisions $revisionManifest $revisionPaths $newSources
    Check ($reconciled.Count -eq 1 -and $reconciled[$revisionRelative].archiveHash -ceq $oldHash)
    Check ($revisionManifest.review.sourceHashes[$revisionRelative] -ceq $oldHash)
    foreach ($field in @('verified','pending')) { $bad=Read-ExpansionStandardCopy $revisionManifest; $bad[$field]=-not $bad[$field]; Reject { Get-ExpansionHostSourceRevisions $bad $revisionPaths $newSources } }
    $badSources=$newSources.Clone(); $badSources['infra/foreign.bicep']=('B'*64)
    Reject { Get-ExpansionHostSourceRevisions $revisionManifest $revisionPaths $badSources }
    [IO.File]::WriteAllText($archive,'tampered')
    Reject { Get-ExpansionHostSourceRevisions $revisionManifest $revisionPaths $newSources }
    [IO.File]::WriteAllText($archive,$oldText,[Text.UTF8Encoding]::new($false))
    $buildRoot=Assert-ExternalLabPath (Join-Path $hostFixtureRoot 'compiled')
    $null=[IO.Directory]::CreateDirectory($buildRoot)
    foreach ($compiledStage in @('account','project')) {
        $modulePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../infra/modules/standard-$compiledStage-host.bicep"))
        $compiledPath=Join-Path $buildRoot "$compiledStage.json"
        $buildInfo=[Diagnostics.ProcessStartInfo]::new()
        $buildInfo.FileName=$hostTestCompiler
        $buildInfo.WorkingDirectory=$buildRoot
        $buildInfo.UseShellExecute=$false
        $buildInfo.CreateNoWindow=$true
        $buildInfo.RedirectStandardOutput=$true
        $buildInfo.RedirectStandardError=$true
        foreach ($argument in @('build',$modulePath,'--no-restore','--outfile',$compiledPath)) { $buildInfo.ArgumentList.Add($argument) }
        $buildProcess=[Diagnostics.Process]::new()
        $buildProcess.StartInfo=$buildInfo
        try {
            if (-not $buildProcess.Start()) { throw "Could not start compiler for $compiledStage host" }
            $buildStdout=$buildProcess.StandardOutput.ReadToEndAsync()
            $buildStderr=$buildProcess.StandardError.ReadToEndAsync()
            if (-not $buildProcess.WaitForExit(30000)) {
                $buildProcess.Kill($true)
                $null=$buildProcess.WaitForExit(5000)
                throw "Compiler timed out for $compiledStage host"
            }
            if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($buildStdout,$buildStderr),5000)) { throw "Compiler output timed out for $compiledStage host" }
            if ($buildProcess.ExitCode -ne 0) { throw "Compiler failed for $compiledStage host: $($buildStderr.Result) $($buildStdout.Result)" }
        } finally { $buildProcess.Dispose() }
        Check ((Test-Path -LiteralPath $compiledPath -PathType Leaf) -and (Get-Item -LiteralPath $compiledPath).Length -gt 0)
        $actualCompiled=Read-FoundationJson $compiledPath
        foreach ($compiledSelector in @('a-test','b-dev','b-test')) {
            $compiledBinding=Get-ExpansionHostBinding $hostFixtureState $hostFixturePrerequisites $compiledSelector $compiledStage
            Assert-ExpansionHostCompiled $actualCompiled $compiledBinding; Check $true
            $otherStage=if ($compiledStage -ceq 'account') { 'project' } else { 'account' }
            $otherBinding=Get-ExpansionHostBinding $hostFixtureState $hostFixturePrerequisites $compiledSelector $otherStage
            Reject { Assert-ExpansionHostCompiled $actualCompiled $otherBinding }
        }
        $unboundCompiled=Read-ExpansionStandardCopy $actualCompiled
        $unboundCompiled.resources[0].name='unbound'
        Reject { Assert-ExpansionHostCompiled $unboundCompiled $compiledBinding }
        $unboundCompiled=Read-ExpansionStandardCopy $actualCompiled
        if ($compiledStage -ceq 'account') { $unboundCompiled.resources[0].properties.capabilityHostKind='wrong' }
        else { $unboundCompiled.resources[0].properties.storageConnections=@("[parameters('cosmosName')]") }
        Reject { Assert-ExpansionHostCompiled $unboundCompiled $compiledBinding }
    }
    Assert-FoundationSet @(Get-ChildItem -LiteralPath $buildRoot -File | ForEach-Object Name) @('account.json','project.json'); Check $true
    Assert-FoundationEqual (Get-ExpansionHostSources) $hostTestSourceHashes; Check $true
    foreach ($selection in @('a-test','b-dev','b-test')) {
        $binding=Get-ExpansionHostBinding $hostFixtureState $hostFixturePrerequisites $selection 'account'
        $implicit="$($binding.accountId)/capabilityHosts/$($binding.parameters.accountName.value)@aml_aiagentservice"
        $resource=@{id=$implicit;type=$binding.type;properties=@{provisioningState='Succeeded';capabilityHostKind='Agents';customerSubnet=@{id=$binding.subnet}}}
        $baseline=@{}; $baseline[$implicit]=Select-FoundationConfiguration $resource
        $hostFixtureState.standard.accountHostId=$implicit
        Check ((Get-ExpansionAccountHostDecision $hostFixtureState $binding @($resource) $baseline $null).mode -ceq 'Reuse')
        Reject { Get-ExpansionAccountHostDecision $hostFixtureState $binding @($resource,$resource) $baseline $null }
        if ($selection -ceq 'a-test') {
            Reject { Get-ExpansionAccountHostDecision $hostFixtureState $binding @() $baseline $null }
            Reject { Get-ExpansionAccountHostDecision $hostFixtureState $binding @($resource) @{} $null }
        } else { Check ((Get-ExpansionAccountHostDecision $hostFixtureState $binding @() $baseline $null).mode -ceq 'Create') }
        foreach ($field in @('customerSubnet','capabilityHostKind','provisioningState')) {
            $bad=Read-ExpansionStandardCopy $resource; $bad.properties[$field]='wrong'
            Reject { Get-ExpansionAccountHostDecision $hostFixtureState $binding @($bad) $baseline $null }
        }
        $explicit=Read-ExpansionStandardCopy $resource; $explicit.id=$binding.hostId
        Reject { Get-ExpansionAccountHostDecision $hostFixtureState $binding @($explicit) $baseline $null }
        if ($selection -cne 'a-test') {
            $intent=@{pending=$true;verified=$false;mode='Create';binding=$binding}
            Check ((Get-ExpansionAccountHostDecision $hostFixtureState $binding @($explicit) $baseline $intent).id -ceq $binding.hostId)
        }
        $projectBinding=Get-ExpansionHostBinding $hostFixtureState $hostFixturePrerequisites $selection 'project'
        $projectHost=@{id=$projectBinding.hostId;type=$projectBinding.type;properties=@{provisioningState='Succeeded';storageConnections=@("storage-$selection");vectorStoreConnections=@("search-$selection");threadStorageConnections=@("cosmos-$selection")}}
        Assert-ExpansionHostResource $projectBinding $projectHost $projectBinding.hostId -Live; Check $true
        $bad=Read-ExpansionStandardCopy $projectHost; $bad.properties.storageConnections=@($hostFixturePrerequisites.network.outputs[$selection].standard.storage.id)
        Reject { Assert-ExpansionHostResource $projectBinding $bad $projectBinding.hostId -Live }
    }
    Assert-FoundationEqual (Get-ExpansionHostBinding $hostFixtureState $hostFixturePrerequisites 'b-dev' 'account') (Get-ExpansionHostBinding $hostFixtureState $hostFixturePrerequisites 'b-test' 'account'); Check $true
    Check ((Get-ExpansionHostPaths $hostFixtureState 'b-dev' 'account').state -ceq (Get-ExpansionHostPaths $hostFixtureState 'b-test' 'account').state)
    Check ((ConvertTo-ExpansionHostGuid '55555555555545558555555555555555') -ceq '55555555-5555-4555-8555-555555555555')
    Reject { ConvertTo-ExpansionHostGuid 'not-a-project-internal-id' }
    foreach ($selection in @('a-test','b-dev','b-test')) {
        $dependency=$hostFixturePrerequisites.network.outputs[$selection].standard
        $tags=@{'fgl-owner'=$hostFixtureState.ownershipId;'fgl-lab'=$hostFixtureState.labId;purpose='synthetic-governance-lab'}
        $account=@{id=$dependency.accountId;tags=$tags;identity=@{type='SystemAssigned';principalId='66666666-6666-4666-8666-666666666666';tenantId=$hostFixtureState.tenantId};properties=@{provisioningState='Succeeded';publicNetworkAccess='Disabled';disableLocalAuth=$true}}
        $projectResource=@{id=$dependency.projectId;tags=$tags;identity=@{type='SystemAssigned';principalId=$dependency.projectPrincipalId;tenantId=$hostFixtureState.tenantId};properties=@{provisioningState='Succeeded';internalId='55555555555545558555555555555555';workspaceId='not-the-internal-id'}}
        $connections=@(foreach ($pair in @(@('storage','AzureStorageAccount'),@('search','CognitiveSearch'),@('cosmos','CosmosDb'))) { @{id=$dependency.connections[$pair[0]].id;type='Microsoft.CognitiveServices/accounts/projects/connections';properties=@{category=$pair[1];authType='AAD';isSharedToAll=$false;target=$dependency[$pair[0]].endpoint;metadata=@{ApiType='Azure';ResourceId=$dependency[$pair[0]].id;location='swedencentral'}}} })
        Check ((Assert-ExpansionHostConnections $hostFixtureState $dependency $account $projectResource $connections) -ceq '55555555-5555-4555-8555-555555555555')
        foreach ($mutation in @(
            {param($value) $value.identity.principalId='66666666-6666-4666-8666-666666666666'},
            {param($value) $value.identity.tenantId='66666666-6666-4666-8666-666666666666'},
            {param($value) $value.properties.Remove('internalId')},
            {param($value) $value.properties.internalId=$value.properties.workspaceId},
            {param($value) $value.id+='/wrong'},
            {param($value) $value.properties.provisioningState='Creating'}
        )) { $bad=Read-ExpansionStandardCopy $projectResource; & $mutation $bad; Reject { Assert-ExpansionHostConnections $hostFixtureState $dependency $account $bad $connections } }
        foreach ($serviceIndex in 0..2) {
            foreach ($mutation in @(
                {param($value) $value.properties.authType='ApiKey'},
                {param($value) $value.properties.metadata.ResourceId+='/wrong'},
                {param($value) $value.properties.target='https://wrong.invalid'},
                {param($value) $value.properties.category='wrong'},
                {param($value) $value.properties.isSharedToAll=$true},
                {param($value) $value.properties.credentials=@{key='synthetic'}},
                {param($value) $value.id+='/wrong'}
            )) { $bad=Read-ExpansionStandardCopy $connections; & $mutation $bad[$serviceIndex]; Reject { Assert-ExpansionHostConnections $hostFixtureState $dependency $account $projectResource $bad } }
        }
        Reject { Assert-ExpansionHostConnections $hostFixtureState $dependency $account $projectResource @($connections[0],$connections[1]) }
        foreach ($stage in @('account','project')) {
            $binding=Get-ExpansionHostBinding $hostFixtureState $hostFixturePrerequisites $selection $stage
            $compiled=New-HostTemplateFixture $binding
            Assert-ExpansionHostCompiled $compiled $binding; Check $true
            $expandedName=Read-ExpansionStandardCopy $compiled
            $expandedName.resources[0].name=if ($stage -ceq 'account') { "[format('{0}/{1}', parameters('accountName'), 'agents')]" } else { "[format('{0}/{1}/{2}', parameters('accountName'), parameters('projectName'), 'agents')]" }
            Assert-ExpansionHostCompiled $expandedName $binding; Check $true
            foreach ($mutation in @(
                {param($value) $value.resources+=$value.resources[0]},
                {param($value) $value.resources[0].condition=$true},
                {param($value) $value.resources[0].type='Microsoft.Authorization/roleAssignments'},
                {param($value) $value.resources[0].name='unbound'},
                {param($value) $value.resources[0].properties.extraWrite=$true},
                {param($value) $value.outputs.resourceId.value='wrong'},
                {param($value) $value.parameters.accountName.defaultValue='foreign'},
                {param($value) $value.variables=@{unexpected='value'}}
            )) { $bad=Read-ExpansionStandardCopy $compiled; & $mutation $bad; Reject { Assert-ExpansionHostCompiled $bad $binding } }
            $resource=New-HostResourceFixture $binding
            $resource.properties.Remove('provisioningState'); $resource.properties.Remove('customerSubnet')
            $whatif=@{status='Succeeded';changes=@(@{resourceId=$binding.hostId;changeType='Create';after=$resource})}
            Assert-ExpansionHostWhatIf $binding @{} $whatif; Check $true
            foreach ($changeType in @('Modify','NoChange','Delete','Ignore','Unsupported')) {
                $bad=Read-ExpansionStandardCopy $whatif; $bad.changes[0].changeType=$changeType
                Reject { Assert-ExpansionHostWhatIf $binding @{} $bad }
            }
            $bad=Read-ExpansionStandardCopy $whatif; $bad.changes[0].before=$resource
            Reject { Assert-ExpansionHostWhatIf $binding @{} $bad }
            $bad=Read-ExpansionStandardCopy $whatif; $bad.changes+=@{resourceId="$($binding.group)/providers/Microsoft.Storage/storageAccounts/foreign";changeType='Create';after=@{}}
            Reject { Assert-ExpansionHostWhatIf $binding @{} $bad }
            $known=@{}; $known[$binding.accountId]=@{id=$binding.accountId;type='Microsoft.CognitiveServices/accounts';properties=@{untouched=$true}}
            $ignored=Read-ExpansionStandardCopy $whatif; $ignored.changes+=@{resourceId=$binding.accountId;changeType='Ignore';before=$known[$binding.accountId];after=$known[$binding.accountId]}
            Assert-ExpansionHostWhatIf $binding $known $ignored; Check $true
            Reject { Assert-ExpansionHostWhatIf $binding @{} $ignored }
            $bad=Read-ExpansionStandardCopy $ignored; $bad.changes[1].before.properties.untouched=$false; $bad.changes[1].after.properties.untouched=$false
            Reject { Assert-ExpansionHostWhatIf $binding $known $bad }
            $searchId="$($binding.group)/providers/Microsoft.Search/searchServices/example"
            $searchSparse=@{id=$searchId;type='Microsoft.Search/searchServices';location='swedencentral';properties=@{publicNetworkAccess='disabled'}}
            $searchKnown=@{}; $searchKnown[$searchId]=Read-ExpansionStandardCopy $searchSparse
            $searchKnown[$searchId].location='Sweden Central'; $searchKnown[$searchId].properties.publicNetworkAccess='Disabled'
            $searchWhatIf=Read-ExpansionStandardCopy $whatif; $searchWhatIf.changes+=@{resourceId=$searchId;changeType='Ignore';before=$searchSparse;after=$searchSparse}
            Assert-ExpansionHostWhatIf $binding $searchKnown $searchWhatIf; Check $true
            Check ($searchKnown[$searchId].location -ceq 'Sweden Central')
            $bad=Read-ExpansionStandardCopy $searchKnown; $bad[$searchId].location='westeurope'; Reject { Assert-ExpansionHostWhatIf $binding $bad $searchWhatIf }
            $bad=Read-ExpansionStandardCopy $searchKnown; $bad[$searchId].properties.publicNetworkAccess='Enabled'; Reject { Assert-ExpansionHostWhatIf $binding $bad $searchWhatIf }
            $endpointId="$($binding.group)/providers/Microsoft.Network/privateEndpoints/known-endpoint"
            $nicId="$($binding.group)/providers/Microsoft.Network/networkInterfaces/known-endpoint.nic.11111111-1111-1111-1111-111111111111"
            $nicKnown=@{}; $nicKnown[$endpointId]=@{id=$endpointId;type='Microsoft.Network/privateEndpoints'}
            $nicKnown[$nicId]=@{id=$nicId;type='Microsoft.Network/networkInterfaces'}
            $nicSparse=Read-ExpansionStandardCopy $nicKnown[$nicId]; $nicSparse.managedBy=$endpointId
            $nicWhatIf=Read-ExpansionStandardCopy $whatif; $nicWhatIf.changes+=@{resourceId=$nicId;changeType='Ignore';before=$nicSparse;after=$nicSparse}
            Assert-ExpansionHostWhatIf $binding $nicKnown $nicWhatIf; Check $true
            Check (-not $nicKnown[$nicId].ContainsKey('managedBy'))
            $bad=Read-ExpansionStandardCopy $nicKnown; $bad.Remove($endpointId); Reject { Assert-ExpansionHostWhatIf $binding $bad $nicWhatIf }
            $bad=Read-ExpansionStandardCopy $nicKnown; $bad[$endpointId].type='Microsoft.Storage/storageAccounts'; Reject { Assert-ExpansionHostWhatIf $binding $bad $nicWhatIf }
            $bad=Read-ExpansionStandardCopy $nicWhatIf; $bad.changes[1].before.managedBy="$endpointId-foreign"; $bad.changes[1].after.managedBy="$endpointId-foreign"
            $badKnown=Read-ExpansionStandardCopy $nicKnown; $badKnown["$endpointId-foreign"]=@{id="$endpointId-foreign";type='Microsoft.Network/privateEndpoints'}
            Reject { Assert-ExpansionHostWhatIf $binding $badKnown $bad }
            $deployment=@{id=$binding.root;name=($binding.root -split '/')[-1];properties=@{provisioningState='Succeeded';mode='Incremental';parameters=$binding.parameters;outputs=@{resourceId=@{type='String';value=$binding.hostId}};outputResources=@(@{id=$binding.hostId})}}
            $operations=@(@{id="$($binding.root)/operations/one";properties=@{provisioningState='Succeeded';provisioningOperation='Create';targetResource=@{id=$binding.hostId;resourceType=$binding.type}}})
            $intent=@{mode='Create';binding=$binding;deploymentId=$binding.root}
            Assert-ExpansionHostDeployment $intent $deployment $operations; Check $true
            foreach ($mutation in @(
                {param($value) $value.properties.targetResource.id+='/wrong'},
                {param($value) $value.properties.targetResource.resourceType='Microsoft.Resources/deployments'},
                {param($value) $value.properties.provisioningOperation='Update'},
                {param($value) $value.properties.provisioningState='Running'},
                {param($value) $value.id='foreign'}
            )) { $bad=Read-ExpansionStandardCopy $operations; & $mutation $bad[0]; Reject { Assert-ExpansionHostDeployment $intent $deployment $bad } }
            Reject { Assert-ExpansionHostDeployment $intent $deployment @() }
            $bad=Read-ExpansionStandardCopy $deployment; $bad.properties.outputs.resourceId.value='wrong'
            Reject { Assert-ExpansionHostDeployment $intent $bad $operations }
        }
    }
    $cosmos=@{}; $liveRules=@{}
    $scope="$hostFixtureSubscription/resourceGroups/rg-fgl-sample01-integration"
    $nsgId="$scope/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-sample01-endpoints"
    $retained=@{id="$nsgId/securityRules/allow-cosmos-direct";name='allow-cosmos-direct';type='Microsoft.Network/networkSecurityGroups/securityRules';properties=@{priority=125;preserved='A-dev'}}
    foreach ($selection in @('a-test','b-dev','b-test')) {
        $ruleBinding=$hostFixtureState.Clone(); $ruleBinding.selector=$selection; $ruleBinding.names=Get-ExpansionCosmosNetworkNames $hostFixtureState $selection $scope
        $ruleBinding.addresses=if ($selection -ceq 'a-test') { @('10.76.6.12','10.76.6.13') } else { @('10.76.7.8','10.76.7.9') }
        $cosmos[$selection]=@{pending=$false;verified=$true;binding=$ruleBinding}
        $properties=Get-ExpansionCosmosNetworkRuleProperties $selection $ruleBinding.addresses; $properties.provisioningState='Succeeded'
        $liveRules[$selection]=@{id=$ruleBinding.names.ruleId;name=$ruleBinding.names.ruleName;type='Microsoft.Network/networkSecurityGroups/securityRules';properties=$properties}
    }
    $original=@{}; $original[$nsgId]=Select-FoundationConfiguration @{id=$nsgId;type='Microsoft.Network/networkSecurityGroups';properties=@{securityRules=@($retained)}}
    $full=@{}; $full[$nsgId]=Select-FoundationConfiguration @{id=$nsgId;type='Microsoft.Network/networkSecurityGroups';properties=@{securityRules=@($retained)+@($liveRules.Values)}}
    $fullBefore=Get-FoundationHash $full
    Assert-ExpansionHostBaseline $full $original $cosmos $liveRules; Check $true
    Check ((Get-FoundationHash $full) -ceq $fullBefore)
    $bad=Read-ExpansionStandardCopy $full; @($bad[$nsgId].properties.securityRules | Where-Object { $_.properties.priority -eq 125 })[0].properties.preserved='changed'
    Reject { Assert-ExpansionHostBaseline $bad $original $cosmos $liveRules }
    foreach ($selection in $cosmos.Keys) {
        $bad=Read-ExpansionStandardCopy $liveRules; $bad[$selection].properties.provisioningState='Running'
        Reject { Assert-ExpansionHostBaseline $full $original $cosmos $bad }
        $bad=Read-ExpansionStandardCopy $cosmos; $bad[$selection].pending=$true
        Reject { Assert-ExpansionHostBaseline $full $original $bad $liveRules }
    }
    $inventoryKnown=@{}
    $inventoryKnown[$nsgId]=@{id=$nsgId;type='Microsoft.Network/networkSecurityGroups'}
    $extensionId="$scope/providers/Microsoft.Compute/virtualMachines/runner/extensions/fixture"
    $inventoryKnown[$extensionId]=@{id=$extensionId;type='Microsoft.Compute/virtualMachines/extensions'}
    $inventoryFull=Read-ExpansionStandardCopy $inventoryKnown
    Assert-ExpansionHostInventory $inventoryKnown $inventoryFull @($scope); Check $true
    foreach ($id in $inventoryKnown.Keys) {
        $bad=Read-ExpansionStandardCopy $inventoryFull; $bad.Remove($id)
        Reject { Assert-ExpansionHostInventory $inventoryKnown $bad @($scope) }
    }
    $bad=Read-ExpansionStandardCopy $inventoryFull; $bad["$scope/providers/Microsoft.Storage/storageAccounts/unknown"]=@{type='Microsoft.Storage/storageAccounts'}
    Reject { Assert-ExpansionHostInventory $inventoryKnown $bad @($scope) }
    Reject { Assert-ExpansionHostInventory $inventoryKnown $inventoryFull @("$scope-wrong") }
    foreach ($key in @('account-a','account-b','project-a-test','project-b-dev','project-b-test')) {
        Assert-ExpansionHostTransition @{} $key 'Preview' $true; Check $true
        Reject { Assert-ExpansionHostTransition @{} $key 'Preview' $false }
        Reject { Assert-ExpansionHostTransition @{} $key 'Deploy' $true }
        Reject { Assert-ExpansionHostTransition @{} $key 'Status' $false }
        $intent=@{key=$key;stage='hosts';pending=$true;verified=$false}
        Assert-ExpansionHostTransition @{$key=$intent} $key 'Status' $false; Check $true
        Reject { Assert-ExpansionHostTransition @{$key=$intent} $key 'Deploy' $true }
        foreach ($other in @('account-a','account-b','project-a-test','project-b-dev','project-b-test' | Where-Object { $_ -cne $key })) { Reject { Assert-ExpansionHostTransition @{$key=$intent} $other 'Preview' $true } }
    }
} finally { Remove-Item -LiteralPath $hostFixtureRoot -Recurse -Force }
& {
    $collectorRoot=Assert-ExternalLabPath (Join-Path ([IO.Path]::GetTempPath()) ('expansion-host-collector-'+[guid]::NewGuid().ToString('N')))
    $null=[IO.Directory]::CreateDirectory($collectorRoot)
    try {
        foreach ($pair in @(@('Get-ExpansionHostLive','Invoke-ExpansionHosts.ps1'),@('Get-FoundationLive','Invoke-ExpansionFoundation.ps1'),@('Read-ExpansionNetworkArm','Invoke-ExpansionCosmosNetwork.ps1'),@('Read-FoundationArm','Invoke-ExpansionFoundation.ps1'))) {
            Assert-FoundationText (Get-Command $pair[0]).ScriptBlock.File ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../scripts/$($pair[1])"))); Check $true
        }
        $collectorState=Read-ExpansionStandardCopy $hostFixtureState
        $collectorState.runDirectory=$collectorRoot
        $collectorState.minimalPrompt=$true; $collectorState.privateAccessVerified=$true; $collectorState.deploymentAuthorized=$true
        $collectorState.phase='activate'; $collectorState.pendingPhase=$null; $collectorState.preexistingGroupIds=@()
        $collectorState.resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" })
        $collectorState.standard=@{completedStages=@('dependencies','account','project','access');pendingStage=$null;deploymentNames=@{}}
        foreach ($stageName in @('dependencies','project','access')) { $collectorState.standard.deploymentNames[$stageName]="fgl-sample01-standard-$stageName" }
        foreach ($pair in @(@('cosmosNetwork','standard-cosmos-network'),@('gatewayPolicy','gateway-policy-update'))) {
            $evidencePath=Join-Path $collectorRoot "$($pair[1]).evidence.json"
            Write-StandardJson $evidencePath @{synthetic=$true}
            $collectorState.standard[$pair[0]]=@{name="fgl-sample01-$($pair[1])";group='rg-fgl-sample01-integration';pending=$false;verified=$true;review=@{};evidence=@{path=$evidencePath;sha256=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash}}
        }
        $collectorPrerequisites=Read-ExpansionStandardCopy $hostFixturePrerequisites
        $collectorFoundation=$collectorPrerequisites.network.foundation
        $collectorFoundation.stem='fgl-sample01'
        $collectorFoundation.integration="$hostFixtureSubscription/resourceGroups/rg-fgl-sample01-integration"
        $collectorFoundation.groupA="$hostFixtureSubscription/resourceGroups/rg-fgl-sample01-case-a"
        $collectorFoundation.groupB="$hostFixtureSubscription/resourceGroups/rg-fgl-sample01-case-b"
        $collectorFoundation.groupName='rg-fgl-sample01-case-b'
        $collectorFoundation.devA="$($collectorFoundation.accountA)/projects/case-a-dev"
        $collectorFoundation.agentSubnet="$($collectorFoundation.vnet)/subnets/snet-agent-b"
        $collectorFoundation.peSubnet="$($collectorFoundation.vnet)/subnets/snet-case-b-pe"
        $collectorFoundation.ampls="$($collectorFoundation.integration)/providers/Microsoft.Insights/privateLinkScopes/ampls-fgl-sample01"
        $collectorFoundation.projects=@('a-test','b-dev','b-test' | ForEach-Object { $collectorPrerequisites.network.outputs[$_].standard.projectId })
        $collectorFoundation.zones=@('cognitiveservices.azure.com','openai.azure.com','services.ai.azure.com' | ForEach-Object { "$($collectorFoundation.integration)/providers/Microsoft.Network/privateDnsZones/privatelink.$_" })
        $collectorFoundation.links=@(4..5 | ForEach-Object { "$($collectorFoundation.ampls)/scopedResources/linked-$_" })
        $collectorFoundation.new=@{}; $collectorFoundation.identities=@{}
        $collectorLab=@{minimalPrompt=$true;phase='activate';resourceGroups=$collectorState.resourceGroups;models="$hostFixtureSubscription/resourceGroups/rg-fgl-sample01-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-abcdefghijklm";gateway="$($collectorFoundation.integration)/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-abcdefghijklm";runner="$($collectorFoundation.integration)/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner";cases=@(@{accountId=$collectorFoundation.accountA;registryId='';projects=@(@{resourceId=$collectorFoundation.devA;principalId='44444444-4444-4444-8444-444444444444'})});identities=@()}
        foreach ($actor in @('dev-a','consumer-a','dev-b','publisher-a','publisher-b','client','denied')) {
            $identity=@{actor=$actor;resourceId="$($collectorFoundation.integration)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-sample01-$actor";principalId='55555555-5555-4555-8555-555555555555';clientId='66666666-6666-4666-8666-666666666666'}
            $collectorLab.identities+=$identity; $collectorFoundation.identities[$identity.resourceId]=$identity
        }
        $collectorState.standard.accountHostId="$($collectorFoundation.accountA)/capabilityHosts/$(($collectorFoundation.accountA -split '/')[-1])@aml_aiagentservice"
        $collectorState.standard.cosmosNetwork.ruleId=(Get-CosmosNetworkNames $collectorState).ruleId
        $collectorState.standard.cosmosNetwork.review.binding=@{addresses=@('10.76.6.4')}
        $collectorActivation=@{parameters=@{minimalPrompt=@{value=$true};labId=@{value=$collectorState.labId};ownershipId=@{value=$collectorState.ownershipId};phase=@{value='activate'};gatewayPrincipalId=@{value='66666666-6666-4666-8666-666666666666'}}}
        $collectorOriginalDependency=@{labId=$collectorState.labId;ownershipId=$collectorState.ownershipId;stage='dependencies';location='swedencentral';accountId=$collectorFoundation.accountA;projectId=$collectorFoundation.devA;vnetId=$collectorFoundation.vnet;subnetId="$($collectorFoundation.vnet)/subnets/snet-case-a-pe";projectEndpoint="https://$(($collectorFoundation.accountA -split '/')[-1]).services.ai.azure.com/api/projects/case-a-dev";projectPrincipalId=$collectorLab.cases[0].projects[0].principalId;workspaceId='55555555-5555-4555-8555-555555555555';resourceGroups=@{caseA='rg-fgl-sample01-case-a';integration='rg-fgl-sample01-integration'};dnsZoneIds=@{};privateEndpointIds=@()}
        $collectorArm=@{}; $collectorApis=@{}; $collectorCounters=@{reads=0}
        function Add-CollectorResource([string]$Id,[string]$Type,[string]$Api,[hashtable]$Properties=@{}) {
            $value=@{id=$Id.Replace('/resourceGroups/','/resourcegroups/');name=($Id -split '/')[-1];type=$Type;location='swedencentral';tags=@{'fgl-owner'=$collectorState.ownershipId;'fgl-lab'=$collectorState.labId;purpose='synthetic-governance-lab'};properties=@{provisioningState='Succeeded'}}
            foreach ($property in $Properties.Keys) { $value.properties[$property]=$Properties[$property] }
            $collectorArm[$Id]=$value; $collectorApis[$Id]=$Api
            return $value
        }
        function Add-CollectorList([string]$Id,[string]$Api,[array]$Items) { $collectorArm[$Id]=@{value=$Items}; $collectorApis[$Id]=$Api }
        foreach ($group in @($collectorState.resourceGroups)+@($collectorFoundation.groupName)) { $null=Add-CollectorResource "$hostFixtureSubscription/resourceGroups/$group" 'Microsoft.Resources/resourceGroups' '2025-04-01' }
        $collectorFoundation.new[$collectorFoundation.groupB]='group'
        foreach ($accountId in @($collectorFoundation.accountA,$collectorFoundation.accountB,$collectorLab.models)) {
            $resource=Add-CollectorResource $accountId 'Microsoft.CognitiveServices/accounts' '2026-05-01' @{publicNetworkAccess='Disabled';disableLocalAuth=$true;allowProjectManagement=$true;restrictOutboundNetworkAccess=$false;customSubDomainName=($accountId -split '/')[-1];networkAcls=@{defaultAction='Deny';bypass='None';ipRules=@();virtualNetworkRules=@()};networkInjections=@()}
            $resource.kind='AIServices'; $resource.sku=@{name='S0'}
            $resource.identity=@{type='SystemAssigned';principalId='66666666-6666-4666-8666-666666666666';tenantId=$collectorState.tenantId}
            if ($accountId -ine $collectorLab.models) {
                $caseId=if ($accountId -ieq $collectorFoundation.accountA) { 'a' } else { 'b' }
                $resource.properties.networkInjections=@(@{scenario='agent';subnetArmId="$($collectorFoundation.vnet)/subnets/snet-agent-$caseId";useMicrosoftManagedNetwork=$false})
            }
        }
        $collectorFoundation.new[$collectorFoundation.accountB]='account'
        foreach ($projectId in @($collectorFoundation.devA)+@($collectorFoundation.projects)) {
            $resource=Add-CollectorResource $projectId 'Microsoft.CognitiveServices/accounts/projects' '2026-05-01' @{internalId='55555555555545558555555555555555';workspaceId='not-the-internal-id'}
            $resource.identity=@{type='SystemAssigned';principalId=$collectorLab.cases[0].projects[0].principalId;tenantId=$collectorState.tenantId}
            if ($projectId -ine $collectorFoundation.devA) { $collectorFoundation.new[$projectId]='project' }
        }
        $resource=Add-CollectorResource $collectorLab.gateway 'Microsoft.ApiManagement/service' '2024-05-01' @{publicNetworkAccess='Disabled'}
        $resource.identity=@{type='SystemAssigned';principalId=$collectorActivation.parameters.gatewayPrincipalId.value;tenantId=$collectorState.tenantId}
        foreach ($identity in $collectorLab.identities) { $null=Add-CollectorResource $identity.resourceId 'Microsoft.ManagedIdentity/userAssignedIdentities' '2023-01-31' @{principalId=$identity.principalId;clientId=$identity.clientId;tenantId=$collectorState.tenantId} }
        $collectorSubnets=@(@('agent-a','10.76.1.0/24','agent-0'),@('agent-b','10.76.2.0/24','agent-1'),@('apim','10.76.3.0/26','apim'),@('runner','10.76.4.0/27','runner'),@('models-pe','10.76.5.0/27','endpoints'),@('case-a-pe','10.76.6.0/27','endpoints'),@('case-b-pe','10.76.7.0/27','endpoints'),@('integration-pe','10.76.8.0/27','endpoints'))
        foreach ($spec in $collectorSubnets) {
            $resource=Add-CollectorResource "$($collectorFoundation.vnet)/subnets/snet-$($spec[0])" 'Microsoft.Network/virtualNetworks/subnets' '2024-05-01' @{addressPrefix=$spec[1];networkSecurityGroup=@{id="$($collectorFoundation.integration)/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-sample01-$($spec[2])"};delegations=@();privateEndpointNetworkPolicies='NetworkSecurityGroupEnabled'}
            if ($spec[0] -like 'agent-*') { $resource.properties.delegations=@(@{properties=@{serviceName='Microsoft.App/environments'}}) }
        }
        $null=Add-CollectorResource $collectorFoundation.vnet 'Microsoft.Network/virtualNetworks' '2024-05-01' @{subnets=@($collectorSubnets | ForEach-Object { $collectorArm["$($collectorFoundation.vnet)/subnets/snet-$($_[0])"] })}
        foreach ($name in @('agent-0','agent-1','endpoints','apim','runner')) { $null=Add-CollectorResource "$($collectorFoundation.integration)/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-sample01-$name" 'Microsoft.Network/networkSecurityGroups' '2024-05-01' @{securityRules=@();defaultSecurityRules=@()} }
        $null=Add-CollectorResource $collectorFoundation.ampls 'Microsoft.Insights/privateLinkScopes' '2021-07-01-preview' @{accessModeSettings=@{ingestionAccessMode='PrivateOnly';queryAccessMode='PrivateOnly';exclusions=@()}}
        $collectorMonitorLinks=@()
        foreach ($index in 0..5) {
            $suffix=if ($index -lt 2) { 'integration' } elseif ($index -lt 4) { 'case-a' } else { 'case-b' }
            $monitorGroup="$hostFixtureSubscription/resourceGroups/rg-fgl-sample01-$suffix"
            $workspaceId="$monitorGroup/providers/Microsoft.OperationalInsights/workspaces/log-fgl-sample01-$suffix"
            if ($index % 2 -eq 0) { $resource=Add-CollectorResource $workspaceId 'Microsoft.OperationalInsights/workspaces' '2023-09-01' @{publicNetworkAccessForIngestion='Disabled';publicNetworkAccessForQuery='Disabled';features=@{disableLocalAuth=$true}} }
            else { $resource=Add-CollectorResource "$monitorGroup/providers/Microsoft.Insights/components/appi-fgl-sample01-$suffix" 'Microsoft.Insights/components' '2020-02-02' @{publicNetworkAccessForIngestion='Disabled';publicNetworkAccessForQuery='Disabled';DisableLocalAuth=$true;WorkspaceResourceId=$workspaceId} }
            $link=Add-CollectorResource "$($collectorFoundation.ampls)/scopedResources/linked-$index" 'Microsoft.Insights/privateLinkScopes/scopedResources' '2021-07-01-preview' @{linkedResourceId=$resource.id}
            $collectorMonitorLinks+=$link
            if ($index -ge 4) {
                $kind=if ($index -eq 4) { 'workspace' } else { 'insights' }
                $collectorFoundation[$kind]=$resource.id; $collectorFoundation.new[$resource.id]=$kind; $collectorFoundation.new[$link.id]='link'
            }
        }
        $collectorEndpointSpecs=@{}
        foreach ($spec in @(@('storage','blob','stfglsample01abcdef','Microsoft.Storage/storageAccounts','blob.core.windows.net','blob','2023-05-01'),@('search','search','srch-fgl-sample01-standard','Microsoft.Search/searchServices','search.windows.net','searchService','2025-05-01'),@('cosmos','cosmos','cosmos-fgl-sample01-standard','Microsoft.DocumentDB/databaseAccounts','documents.azure.com','Sql','2024-11-15'))) {
            $endpoint=if ($spec[0] -ceq 'storage') { "https://$($spec[2]).$($spec[4])/" } elseif ($spec[0] -ceq 'cosmos') { "https://$($spec[2]).$($spec[4]):443/" } else { "https://$($spec[2]).$($spec[4])" }
            $record=@{id="$($collectorFoundation.groupA)/providers/$($spec[3])/$($spec[2])";name=$spec[2];endpoint=$endpoint}
            $collectorOriginalDependency[$spec[0]]=$record
            $collectorOriginalDependency.dnsZoneIds[$spec[1]]="$($collectorFoundation.integration)/providers/Microsoft.Network/privateDnsZones/privatelink.$($spec[4])"
            $endpointId="$($collectorFoundation.groupA)/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-standard-$($spec[1])"
            $collectorOriginalDependency.privateEndpointIds+=$endpointId
            $collectorEndpointSpecs[$endpointId]=@{target=$record.id;group=$spec[5];subnet=$collectorOriginalDependency.subnetId;zones=@($collectorOriginalDependency.dnsZoneIds[$spec[1]])}
            $null=Add-CollectorResource $record.id $spec[3] $spec[6] @{publicNetworkAccess='Disabled';allowSharedKeyAccess=$false;allowBlobPublicAccess=$false;disableLocalAuth=$true}
        }
        foreach ($target in @(Get-LabPrivateTargets $collectorState $collectorLab)) {
            $subnetName=if ($target.key -ceq 'gateway') { 'integration' } else { $target.key }
            $collectorEndpointSpecs[$target.endpointId]=@{target=$target.resourceId;group=$target.groupId;subnet="$($collectorFoundation.vnet)/subnets/snet-$subnetName-pe";zones=$collectorFoundation.zones}
        }
        $collectorFoundation.endpoint="$($collectorFoundation.groupB)/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-case-b"
        $collectorFoundation.zoneGroup="$($collectorFoundation.endpoint)/privateDnsZoneGroups/default"
        $collectorFoundation.new[$collectorFoundation.endpoint]='endpoint'; $collectorFoundation.new[$collectorFoundation.zoneGroup]='zoneGroup'
        $collectorEndpointSpecs[$collectorFoundation.endpoint]=@{target=$collectorFoundation.accountB;group='account';subnet=$collectorFoundation.peSubnet;zones=$collectorFoundation.zones}
        foreach ($zone in @($collectorFoundation.zones)+@($collectorOriginalDependency.dnsZoneIds.Values)) {
            $null=Add-CollectorResource $zone 'Microsoft.Network/privateDnsZones' '2024-06-01'
            $null=Add-CollectorResource "$zone/virtualNetworkLinks/lab-only" 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' '2024-06-01' @{virtualNetwork=@{id=$collectorFoundation.vnet};registrationEnabled=$false}
        }
        foreach ($endpointId in $collectorEndpointSpecs.Keys) {
            $spec=$collectorEndpointSpecs[$endpointId]
            $nicId=($endpointId -split '/providers/')[0]+"/providers/Microsoft.Network/networkInterfaces/$(($endpointId -split '/')[-1])-nic"
            $networkBytes=([Net.IPAddress]::Parse(($collectorArm[$spec.subnet].properties.addressPrefix -split '/')[0])).GetAddressBytes()
            $networkBytes[3]=4
            $null=Add-CollectorResource $nicId 'Microsoft.Network/networkInterfaces' '2024-05-01' @{privateEndpoint=@{id=$endpointId};ipConfigurations=@(@{properties=@{subnet=@{id=$spec.subnet};privateIPAddress=([Net.IPAddress]::new($networkBytes).ToString())}})}
            $null=Add-CollectorResource $endpointId 'Microsoft.Network/privateEndpoints' '2024-05-01' @{subnet=@{id=$spec.subnet};privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$spec.target;groupIds=@($spec.group);privateLinkServiceConnectionState=@{status='Approved'}}});networkInterfaces=@(@{id=$nicId})}
            $null=Add-CollectorResource "$endpointId/privateDnsZoneGroups/default" 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' '2024-05-01' @{privateDnsZoneConfigs=@($spec.zones | ForEach-Object { @{properties=@{privateDnsZoneId=$_}} })}
        }
        $collectorAccountHost=Add-CollectorResource $collectorState.standard.accountHostId 'Microsoft.CognitiveServices/accounts/capabilityHosts' '2026-05-01' @{capabilityHostKind='Agents';customerSubnet="$($collectorFoundation.vnet)/subnets/snet-agent-a"}
        $collectorRetainedHost=Add-CollectorResource "$($collectorFoundation.devA)/capabilityHosts/agents" 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts' '2026-05-01' @{capabilityHostKind='Agents';customerSubnet=$null;storageConnections=@($collectorOriginalDependency.storage.name);vectorStoreConnections=@($collectorOriginalDependency.search.name);threadStorageConnections=@($collectorOriginalDependency.cosmos.name)}
        $policyBinding=@{tenantId=$collectorState.tenantId;parameters=@{modelAccountName=@{value=($collectorLab.models -split '/')[-1]};allowedPrincipalIds=@{value=@($collectorLab.cases[0].projects[0].principalId,$collectorLab.identities[5].principalId)}}}
        $null=Add-CollectorResource "$($collectorLab.gateway)/apis/lab-inference/policies/policy" 'Microsoft.ApiManagement/service/apis/policies' '2024-05-01' @{format='rawxml';value=(Get-GatewayPolicyPair (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../infra/policies/inference.xml') -Raw) $policyBinding).after}
        $collectorArm["$($collectorLab.gateway)/apis/lab-inference/policies/policy"].properties.Remove('provisioningState')
        $collectorRetainedRule=Add-CollectorResource $collectorState.standard.cosmosNetwork.ruleId 'Microsoft.Network/networkSecurityGroups/securityRules' '2024-05-01' (Get-CosmosNetworkRuleProperties @('10.76.6.4'))
        $collectorArm[$nsgId].properties.securityRules=@($collectorRetainedRule)
        Add-CollectorList "$hostFixtureSubscription/resourceGroups" '2025-04-01' @(@($collectorState.resourceGroups)+@($collectorFoundation.groupName) | ForEach-Object { $collectorArm["$hostFixtureSubscription/resourceGroups/$_"] })
        Add-CollectorList "$($collectorFoundation.accountA)/projects" '2026-05-01' @($collectorArm[$collectorFoundation.devA],$collectorArm[$collectorFoundation.projects[0]])
        Add-CollectorList "$($collectorFoundation.ampls)/scopedResources" '2021-07-01-preview' $collectorMonitorLinks
        Add-CollectorList "$hostFixtureSubscription/providers/Microsoft.CognitiveServices/accounts" '2026-05-01' @($collectorArm[$collectorFoundation.accountA],$collectorArm[$collectorFoundation.accountB],$collectorArm[$collectorLab.models])
        Add-CollectorList "$($collectorFoundation.accountA)/capabilityHosts" '2026-05-01' @($collectorAccountHost)
        Add-CollectorList "$($collectorFoundation.accountB)/capabilityHosts" '2026-05-01' @()
        Add-CollectorList "$($collectorFoundation.devA)/capabilityHosts" '2026-05-01' @($collectorRetainedHost)
        $activationId="$hostFixtureSubscription/providers/Microsoft.Resources/deployments/fgl-sample01-activate"
        $null=Add-CollectorResource $activationId 'Microsoft.Resources/deployments' '2022-09-01' @{mode='Incremental';parameters=$collectorActivation.parameters;outputs=@{lab=@{value=$collectorLab}}}
        function Invoke-FoundationAz([hashtable]$State,[string[]]$Arguments,[string]$Label) {
            $collectorCounters.reads++
            if ($collectorCounters.reads -gt 2500) { throw 'Collector fixture read budget exceeded' }
            if (($Arguments -join ' ') -ceq 'account show') { return @{id=$State.subscriptionId;tenantId=$State.tenantId;state='Enabled'} }
            if ($Arguments.Count -eq 4 -and ($Arguments[0..2] -join ' ') -ceq 'provider show --namespace' -and $Arguments[3] -cin @('Microsoft.ContainerService','Microsoft.MachineLearningServices')) { return @{namespace=$Arguments[3];registrationState='Registered'} }
            if ($Arguments.Count -ne 7 -or ($Arguments[0..3] -join ' ') -cne 'rest --method get --url' -or $Arguments[5] -cne '--headers' -or $Arguments[6] -cne 'Accept=application/json') { throw 'Collector forbids writes and unexpected transport' }
            $uri=[uri]$Arguments[4]; $lookup=$uri.AbsolutePath
            $matches=@($collectorArm.Keys | Where-Object { [string]::Equals($_,$lookup,[StringComparison]::OrdinalIgnoreCase) })
            if ($uri.Host -cne 'management.azure.com' -or $matches.Count -ne 1 -or $uri.Query -cne "?api-version=$($collectorApis[$lookup])") { throw "Unmapped collector ARM read: $lookup" }
            return Read-ExpansionStandardCopy $collectorArm[$matches[0]]
        }
        function Invoke-ExpansionNetworkAz([hashtable]$State,[string[]]$Arguments,[switch]$Empty) {
            if ($Empty) { throw 'Collector must never submit a write' }
            return Invoke-FoundationAz $State $Arguments 'collector-network'
        }
        $collectorStandard=@{dependencies=$collectorOriginalDependency}
        $collectorBaseline=Get-FoundationLive $collectorState $collectorLab $collectorStandard $collectorActivation $collectorFoundation -After
        Check ($collectorBaseline.Count -gt 40 -and -not $collectorState.standard.deploymentNames.ContainsKey('account'))
        $collectorPrerequisites.network.lab=$collectorLab
        $collectorPrerequisites.network.seal=@{manifest=@{baseline=$collectorBaseline}}
        $collectorPrerequisites.cosmos=Read-ExpansionStandardCopy $cosmos
        foreach ($selection in @('a-test','b-dev','b-test')) {
            $rule=$liveRules[$selection]
            $null=Add-CollectorResource $rule.id $rule.type '2024-05-01' $rule.properties
            $collectorArm[$nsgId].properties.securityRules+=@($collectorArm[$rule.id])
            $dependency=$collectorPrerequisites.network.outputs[$selection].standard
            $caseId=$selection.Substring(0,1); $code=@{'a-test'='at';'b-dev'='bd';'b-test'='bt'}[$selection]
            $dependency.subnetId="$($collectorFoundation.vnet)/subnets/snet-case-$caseId-pe"
            $dependency.privateEndpointIds=@()
            $serviceNames=@{storage="stfgx${code}abcdefghijklm";search="srch-fgl-sample01-exp-$selection-abcdefghijklm";cosmos="cosmos-fgl-sample01-exp-$code-abcdefghijklm"}
            $connections=@()
            foreach ($spec in @(@('storage','AzureStorageAccount','Microsoft.Storage/storageAccounts','2023-05-01','blob.core.windows.net/','blob','blob'),@('search','CognitiveSearch','Microsoft.Search/searchServices','2025-05-01','search.windows.net','search','searchService'),@('cosmos','CosmosDb','Microsoft.DocumentDB/databaseAccounts','2024-11-15','documents.azure.com:443/','cosmos','Sql'))) {
                $serviceName=$serviceNames[$spec[0]]
                $dependency[$spec[0]]=@{id="$($dependency.resourceGroupId)/providers/$($spec[2])/$serviceName";name=$serviceName;endpoint="https://$serviceName.$($spec[4])"}
                $dependency.connections[$spec[0]]=@{id="$($dependency.projectId)/connections/$serviceName";name=$serviceName}
                $service=$dependency[$spec[0]]; $connection=$dependency.connections[$spec[0]]
                $null=Add-CollectorResource $service.id $spec[2] $spec[3] @{publicNetworkAccess='Disabled';allowSharedKeyAccess=$false;allowBlobPublicAccess=$false;disableLocalAuth=$true}
                $connections+=Add-CollectorResource $connection.id 'Microsoft.CognitiveServices/accounts/projects/connections' '2026-05-01' @{category=$spec[1];authType='AAD';isSharedToAll=$false;target=$service.endpoint;metadata=@{ApiType='Azure';ResourceId=$service.id;location='swedencentral'}}
                $endpointId="$($dependency.resourceGroupId)/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-exp-$selection-$($spec[5])"
                $nicId="$($dependency.resourceGroupId)/providers/Microsoft.Network/networkInterfaces/pe-fgl-sample01-exp-$selection-$($spec[5])-nic"
                $dependency.privateEndpointIds+=$endpointId
                $nicAddress=if ($caseId -ceq 'a') { '10.76.6.12' } else { '10.76.7.8' }
                $null=Add-CollectorResource $nicId 'Microsoft.Network/networkInterfaces' '2024-05-01' @{privateEndpoint=@{id=$endpointId};ipConfigurations=@(@{properties=@{subnet=@{id=$dependency.subnetId};privateIPAddress=$nicAddress}})}
                $null=Add-CollectorResource $endpointId 'Microsoft.Network/privateEndpoints' '2024-05-01' @{subnet=@{id=$dependency.subnetId};privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$service.id;groupIds=@($spec[6]);privateLinkServiceConnectionState=@{status='Approved'}}});networkInterfaces=@(@{id=$nicId})}
            }
            Add-CollectorList "$($dependency.projectId)/connections" '2026-05-01' $connections
            Add-CollectorList "$($dependency.projectId)/capabilityHosts" '2026-05-01' @()
        }
        $collectorKnown=@{}
        foreach ($resource in $collectorArm.Values) { if ($resource.id -and $resource.type -cne 'Microsoft.Resources/deployments') { $collectorKnown[$resource.id]=$resource } }
        $collectorPrerequisites.network.dependencies=@{'a-test'=@{known=$collectorKnown};'b-dev'=@{known=@{}};'b-test'=@{known=@{}}}
        foreach ($group in @($collectorState.resourceGroups)+@($collectorFoundation.groupName)) {
            $groupId="$hostFixtureSubscription/resourceGroups/$group"
            Add-CollectorList "$groupId/resources" '2021-04-01' @($collectorKnown.Values | Where-Object { $_.id -imatch ('^'+[regex]::Escape("$groupId/providers/")+'[^/]+/[^/]+/[^/]+$') })
        }
        $topicDependency=$collectorPrerequisites.network.outputs['a-test'].standard
        $topicScope=$topicDependency.resourceGroupId
        $topicId="$topicScope/providers/Microsoft.EventGrid/systemTopics/$($topicDependency.storage.name)-33333333-3333-4333-8333-333333333333"
        $topic=Add-CollectorResource $topicId 'Microsoft.EventGrid/systemTopics' '2025-02-15' @{source=$topicDependency.storage.id;topicType='microsoft.storage.storageaccounts'}
        $collectorArm["$topicScope/resources"].value+=@($topic)
        Check (-not $collectorKnown.ContainsKey($topicId))
        Check ((Assert-ExpansionHostStorageTopic $collectorPrerequisites.network.outputs $topic $topicScope) -ieq $topicDependency.storage.id)
        foreach ($property in @('source','topicType','provisioningState')) {
            $bad=Read-ExpansionStandardCopy $topic; $bad.properties[$property]='wrong'
            Reject { Assert-ExpansionHostStorageTopic $collectorPrerequisites.network.outputs $bad $topicScope }
        }
        foreach ($property in @('id','type','name','location','identity')) {
            $bad=Read-ExpansionStandardCopy $topic; $bad[$property]='wrong'
            Reject { Assert-ExpansionHostStorageTopic $collectorPrerequisites.network.outputs $bad $topicScope }
        }
        Reject { Assert-ExpansionHostStorageTopic $collectorPrerequisites.network.outputs $topic ($topicScope+'-foreign') }
        $collectorOriginalPath=Join-Path $collectorRoot 'original.json'
        Write-StandardJson $collectorOriginalPath $collectorState
        Write-StandardJson (Join-Path $collectorRoot 'outputs.json') $collectorLab
        Write-StandardJson (Join-Path $collectorRoot 'standard-outputs.json') $collectorStandard
        Write-StandardJson (Join-Path $collectorRoot 'activate.parameters.json') $collectorActivation
        $collectorPrerequisitesPath=Join-Path $collectorRoot 'protected-bindings.json'
        Write-StandardJson $collectorPrerequisitesPath $collectorPrerequisites
        $collectorPrerequisites=Read-FoundationJson $collectorPrerequisitesPath
        $collectorState=Read-FoundationJson $collectorOriginalPath
        $collectorInputHashes=Get-FoundationInputHashes $collectorState $collectorOriginalPath
        $collectorFiles=@{}; foreach ($file in Get-ChildItem -LiteralPath $collectorRoot -File) { $collectorFiles[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        Check ($collectorPrerequisites.GetType().FullName -ceq 'System.Management.Automation.OrderedHashtable')
        Check ($collectorPrerequisites.network.dependencies['a-test'].known.GetType().FullName -ceq 'System.Management.Automation.OrderedHashtable')
        $collectorLive=Get-ExpansionHostLive $collectorState $collectorPrerequisites @{} @{}
        Check ($collectorLive.decisions['account-a'].mode -ceq 'Reuse' -and $collectorLive.decisions['account-a'].id -ieq $collectorState.standard.accountHostId)
        Check ($collectorLive.decisions['account-b'].mode -ceq 'Create' -and $collectorLive.hosts.Count -eq 1)
        Check ($collectorLive.inventory.Count -gt 20 -and $collectorLive.protected.Count -gt 15)
        Check ($collectorLive.protected.ContainsKey($topicId) -and $collectorLive.inventory.ContainsKey($topicId))
        foreach ($selection in @('a-test','b-dev','b-test')) {
            Check ($collectorLive.internalIds[$selection] -ceq '55555555-5555-4555-8555-555555555555')
            $projectId=$collectorPrerequisites.network.outputs[$selection].standard.projectId
            Check ($collectorLive.protected[$projectId].properties.internalId -ceq $collectorLive.internalIds[$selection])
        }
        $collectorIntents=@{}; $collectorReceipts=@{}
        foreach ($selection in @('a-test','b-dev','b-test')) {
            $binding=Get-ExpansionHostBinding $collectorState $collectorPrerequisites $selection 'project'
            $resource=Add-CollectorResource $binding.hostId $binding.type '2026-05-01' @{capabilityHostKind='Agents';customerSubnet=$null;storageConnections=@($binding.parameters.storageName.value);vectorStoreConnections=@($binding.parameters.searchName.value);threadStorageConnections=@($binding.parameters.cosmosName.value)}
            Add-CollectorList "$($binding.projectId)/capabilityHosts" '2026-05-01' @($resource)
            $collectorIntents[$binding.key]=@{key=$binding.key;pending=$false;verified=$true;hostId=$binding.hostId;mode='Create';binding=$binding}
            $collectorReceipts[$binding.key]=@{hostHash=(Get-FoundationHash (Select-FoundationConfiguration $resource))}
        }
        $binding=Get-ExpansionHostBinding $collectorState $collectorPrerequisites 'b-dev' 'account'
        $collectorImplicitB="$($binding.accountId)/capabilityHosts/$($binding.parameters.accountName.value)@aml_aiagentservice"
        $resource=Add-CollectorResource $collectorImplicitB $binding.type '2026-05-01' @{capabilityHostKind='Agents';customerSubnet=$binding.subnet}
        Add-CollectorList "$($binding.accountId)/capabilityHosts" '2026-05-01' @($resource)
        $collectorArm=Read-ExpansionStandardCopy $collectorArm
        $collectorIntents=Read-ExpansionStandardCopy $collectorIntents
        $collectorReceipts=Read-ExpansionStandardCopy $collectorReceipts
        Check ($collectorArm.GetType().FullName -ceq 'System.Management.Automation.OrderedHashtable')
        Check ($collectorArm[$collectorFoundation.accountA].id -cne $collectorFoundation.accountA -and $collectorArm[$collectorFoundation.accountA].id -ieq $collectorFoundation.accountA)
        $collectorArmHash=Get-FoundationHash $collectorArm
        $collectorLive=Get-ExpansionHostLive $collectorState $collectorPrerequisites $collectorIntents $collectorReceipts
        Check ($collectorLive.hosts.Count -eq 5 -and $collectorLive.decisions['account-b'].mode -ceq 'Reuse')
        foreach ($entry in $collectorIntents.Values) {
            Check ($collectorLive.hosts[$entry.hostId].properties.capabilityHostKind -ceq 'Agents' -and $null -eq $collectorLive.hosts[$entry.hostId].properties.customerSubnet)
            Assert-FoundationEqual (Get-FoundationHash $collectorLive.hosts[$entry.hostId]) $collectorReceipts[$entry.key].hostHash; Check $true
        }
        foreach ($selection in @('a-test','b-dev','b-test')) {
            $savedRule=$collectorArm[$collectorPrerequisites.cosmos[$selection].binding.names.ruleId]
            $savedRule.properties.provisioningState='Running'
            Reject { Get-ExpansionHostLive $collectorState $collectorPrerequisites $collectorIntents $collectorReceipts }
            $savedRule.properties.provisioningState='Succeeded'
        }
        foreach ($mutate in @(
            { $collectorArm["$($collectorFoundation.accountA)/capabilityHosts"].value[0].properties.customerSubnet='foreign' },
            { $collectorArm["$($collectorFoundation.devA)/capabilityHosts"].value[0].properties.storageConnections=@('foreign') },
            { $collectorArm[$collectorLab.models].identity.principalId='44444444-4444-4444-8444-444444444444' },
            { $collectorArm[$nsgId].properties.securityRules[0].properties.priority=126 },
            { $collectorArm["$($collectorFoundation.projects[0])/connections"].value[0].properties.authType='ApiKey' },
            { $collectorArm["$($collectorFoundation.projects[0])/capabilityHosts"].value[0].properties.storageConnections=@($collectorPrerequisites.network.outputs['a-test'].standard.storage.id) },
            { $collectorArm["$($collectorFoundation.projects[1])/capabilityHosts"].value=@() },
            { $collectorArm["$($collectorFoundation.projects[2])/connections"].nextLink='https://management.azure.com/next' },
            { $collectorArm[$collectorPrerequisites.network.outputs['b-dev'].standard.privateEndpointIds[0]].properties.networkInterfaces[0].id="$($collectorFoundation.groupA)/providers/Microsoft.Network/networkInterfaces/foreign" },
            { $collectorArm["$($collectorFoundation.groupB)/resources"].value+=@{id="$($collectorFoundation.groupB)/providers/Microsoft.Storage/storageAccounts/unknown";type='Microsoft.Storage/storageAccounts'} }
        )) {
            $savedArm=$collectorArm; $collectorArm=Read-ExpansionStandardCopy $savedArm
            try { & $mutate; Reject { Get-ExpansionHostLive $collectorState $collectorPrerequisites $collectorIntents $collectorReceipts } }
            finally { $collectorArm=$savedArm }
        }
        Reject { Get-ExpansionHostLive $collectorState $collectorPrerequisites @{} @{} }
        Assert-FoundationEqual (Get-ExpansionHostLive $collectorState $collectorPrerequisites $collectorIntents $collectorReceipts) $collectorLive; Check $true
        Assert-FoundationEqual (Get-FoundationHash $collectorArm) $collectorArmHash; Check $true
        Assert-FoundationEqual (Get-FoundationInputHashes $collectorState $collectorOriginalPath) $collectorInputHashes; Check $true
        Assert-FoundationSet @(Get-ChildItem -LiteralPath $collectorRoot -Recurse -File | ForEach-Object FullName) @($collectorFiles.Keys); Check $true
        foreach ($file in $collectorFiles.Keys) { Check ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ceq $collectorFiles[$file]) }
        Check ($collectorCounters.reads -gt 100 -and $collectorCounters.reads -lt 2500)
    } finally { Remove-Item -LiteralPath $collectorRoot -Recurse -Force }
}
foreach ($workflowSelector in @('a-test','b-dev','b-test')) {
    & {
        $workflowRoot=Join-Path ([IO.Path]::GetTempPath()) ('expansion-host-workflow-'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($workflowRoot)
        try {
            $workflowState=Read-ExpansionStandardCopy $hostFixtureState
            $workflowState.runDirectory=$workflowRoot
            $workflowState.azureConfigDirectory=Join-Path $workflowRoot 'unused-cache'
            $workflowState.resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" })
            $workflowState.minimalPrompt=$true; $workflowState.privateAccessVerified=$true; $workflowState.deploymentAuthorized=$true
            $workflowState.phase='activate'; $workflowState.pendingPhase=$null; $workflowState.preexistingGroupIds=@()
            $workflowState.standard=@{completedStages=@('dependencies','account','project','access');pendingStage=$null;deploymentNames=@{}}
            foreach ($stageName in @('dependencies','project','access')) { $workflowState.standard.deploymentNames[$stageName]="fgl-sample01-standard-$stageName" }
            foreach ($pair in @(@('cosmosNetwork','standard-cosmos-network'),@('gatewayPolicy','gateway-policy-update'))) {
                $file=Join-Path $workflowRoot "$($pair[1]).evidence.json"
                Write-StandardJson $file @{synthetic=$true}
                $workflowState.standard[$pair[0]]=@{name="fgl-sample01-$($pair[1])";group='rg-fgl-sample01-integration';pending=$false;verified=$true;review=@{};evidence=@{path=$file;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}}
            }
            foreach ($name in @('outputs.json','standard-outputs.json','activate.parameters.json')) { Write-StandardJson (Join-Path $workflowRoot $name) @{synthetic=$true} }
            $workflowOriginal=Join-Path $workflowRoot 'original.json'
            Write-StandardJson $workflowOriginal $workflowState
            $workflowOriginalHash=(Get-FileHash -LiteralPath $workflowOriginal -Algorithm SHA256).Hash
            $workflowPrerequisites=Read-ExpansionStandardCopy $hostFixturePrerequisites
            $workflowPrerequisites.network.inputs=Get-FoundationInputHashes $workflowState $workflowOriginal
            $workflowPrerequisites.networkSources=@{fixture='sealed'}
            $workflowPrerequisites.files=@{}
            foreach ($name in @('foundation','dependency-a-test','dependency-b-dev','dependency-b-test','cosmos-a-test','cosmos-b-dev','cosmos-b-test')) {
                $file=Join-Path $workflowRoot "$name.json"
                Write-StandardJson $file @{fixture=$name;verified=$true;pending=$false}
                $workflowPrerequisites.files[$file]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            }
            $workflowLive=@{baseline=@{retainedADev=@{version='unchanged';priority=125}};protected=@{dependencies='unchanged'};inventory=@{};hosts=@{};decisions=@{};internalIds=@{}}
            $workflowGraph=@{retainedRoot=@{deploymentHash=('A'*64);operationsHash=('B'*64)}}
            $workflowControl=@{submits=0;compiles=0;azCalls=0;failSubmit=$false;statusOnly=$false;failAfterOutput=$false;race=$false;tamperProtected=$false;wrongLive=$false;changedSources=$false}
            $workflowWriter=(Get-Command Write-StandardJson).ScriptBlock
            $workflowRealSources=(Get-Command Get-ExpansionHostSources).ScriptBlock
            $workflowSources=& $workflowRealSources
            function Get-ExpansionHostSources { $value=$workflowSources.Clone(); if ($workflowControl.changedSources) { $value['fixture-change']='changed' }; return $value }
            function Get-ExpansionHostPrerequisites { param($State,$OriginalPath) return Read-ExpansionStandardCopy $workflowPrerequisites }
            function Assert-ExpansionNetworkInputs {
                param($State,$OriginalPath,$Prerequisites,$Sources)
                Assert-FoundationEqual (Get-FoundationInputHashes $State $OriginalPath) $workflowPrerequisites.network.inputs
            }
            function Get-ExpansionHostLive {
                param($State,$Prerequisites,$All,$Receipts)
                $value=Read-ExpansionStandardCopy $workflowLive
                if ($workflowControl.wrongLive) { $value.baseline.retainedADev.version='changed' }
                return $value
            }
            function Get-ExpansionHostIdle { param($State,$Prerequisites,$All,$Receipts) return Read-ExpansionStandardCopy $workflowGraph }
            function Write-StandardJson {
                param($Path,$Value)
                if ($workflowControl.failAfterOutput -and $Path -ceq $workflowPaths.state -and $Value.verified -eq $true) {
                    Check (Test-Path -LiteralPath $workflowPaths.outputs)
                    $workflowControl.failAfterOutput=$false
                    throw 'Synthetic interruption after atomic output, before completed manifest'
                }
                & $workflowWriter $Path $Value
            }
            function Invoke-ExpansionNetworkProcess {
                param($State,$Executable,$Arguments,$Budget)
                Check (-not $workflowControl.statusOnly)
                Check ($Executable -ceq 'mock-compiler' -and $Arguments[0] -ceq 'build' -and $Arguments[2] -ceq '--no-restore')
                Check ($Arguments[1] -ceq [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../infra/modules/standard-$($workflowBinding.stage)-host.bicep")))
                Check ($Arguments[4] -ceq $workflowPaths.template)
                $workflowControl.compiles++
                Write-StandardJson $Arguments[4] (New-HostTemplateFixture $workflowBinding)
                return @{reason='Exited';exitCode=0}
            }
            function Invoke-ExpansionNetworkAz {
                param($State,$Arguments,[switch]$Empty)
                Check (-not $workflowControl.statusOnly)
                $workflowControl.azCalls++
                Check ($Arguments[0] -ceq 'deployment' -and $Arguments[1] -ceq 'group')
                if ($Arguments[2] -ceq 'validate') { return @{properties=@{provisioningState='Succeeded'}} }
                if ($Arguments[2] -ceq 'what-if') {
                    $resource=New-HostResourceFixture $workflowBinding
                    $resource.properties.Remove('provisioningState'); $resource.properties.Remove('customerSubnet')
                    if ($workflowControl.race) { $workflowLive.hosts[$workflowBinding.hostId]=Select-FoundationConfiguration (New-HostResourceFixture $workflowBinding) }
                    if ($workflowControl.tamperProtected) { [IO.File]::AppendAllText((Join-Path $workflowRoot 'cosmos-b-test.json'),' '); $workflowControl.tamperProtected=$false }
                    return @{status='Succeeded';changes=@(@{resourceId=$workflowBinding.hostId;changeType='Create';after=$resource})}
                }
                if ($Arguments[2] -cne 'create') { throw 'Unmocked Azure command' }
                $persisted=Read-FoundationJson $workflowPaths.state
                Check ($persisted.pending -and -not $persisted.verified -and $persisted.deploymentId -ceq $workflowBinding.root)
                Check (@($Arguments | Where-Object { $_ -ceq '--no-wait' }).Count -eq 1)
                Check ($Arguments -contains $workflowPaths.template -and $Arguments -contains "@$($workflowPaths.parameters)")
                $workflowControl.submits++
                $workflowLive.hosts[$workflowBinding.hostId]=Select-FoundationConfiguration (New-HostResourceFixture $workflowBinding)
                if ($workflowBinding.stage -ceq 'account') { $workflowLive.decisions[$workflowBinding.key]=@{mode='Reuse';id=$workflowBinding.hostId} }
                $workflowGraph[$workflowBinding.root]=@{deploymentHash=('C'*64);operationsHash=('D'*64)}
                if ($workflowControl.failSubmit) { throw 'Synthetic CLI failure after intent; deployment must never be replayed' }
            }
            function Invoke-HostFixtureStatus {
                $workflowControl.statusOnly=$true
                $before=@($workflowControl.submits,$workflowControl.compiles,$workflowControl.azCalls)
                try { Invoke-ExpansionHosts $workflowOriginal $workflowSelector $workflowBinding.stage 'Status' 'forbidden-compiler' $false }
                finally { $workflowControl.statusOnly=$false; Assert-FoundationEqual @($workflowControl.submits,$workflowControl.compiles,$workflowControl.azCalls) $before }
            }
            $workflowBinding=Get-ExpansionHostBinding $workflowState $workflowPrerequisites $workflowSelector 'account'
            $workflowPaths=Get-ExpansionHostPaths $workflowState $workflowSelector 'account'
            Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'project' 'Preview' 'mock-compiler' $true }
            Check ($workflowControl.compiles -eq 0 -and $workflowControl.azCalls -eq 0)
            $reuse=$workflowSelector -cne 'b-dev'
            if ($reuse) {
                $resource=New-HostResourceFixture $workflowBinding
                $resource.id="$($workflowBinding.accountId)/capabilityHosts/$($workflowBinding.parameters.accountName.value)@aml_aiagentservice"
                $workflowLive.hosts[$resource.id]=Select-FoundationConfiguration $resource
                $workflowLive.decisions[$workflowBinding.key]=@{mode='Reuse';id=$resource.id}
            } else { $workflowLive.decisions[$workflowBinding.key]=@{mode='Create';id=$workflowBinding.hostId} }
            $null=Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'account' 'Preview' 'mock-compiler' $true
            $preview=Read-FoundationJson $workflowPaths.state
            $preview.review.checkedAt=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
            Write-StandardJson $workflowPaths.state $preview
            Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'account' 'Deploy' 'mock-compiler' $true }
            Check ($workflowControl.submits -eq 0)
            $null=Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'account' 'Preview' 'mock-compiler' $true
            $workflowControl.failAfterOutput=$true
            if ($reuse) {
                Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'account' 'Deploy' 'mock-compiler' $true }
                Check ($workflowControl.submits -eq 0 -and $workflowControl.compiles -eq 0 -and $workflowControl.azCalls -eq 0)
            } else {
                $workflowControl.failSubmit=$true
                Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'account' 'Deploy' 'mock-compiler' $true }
                Check ((Read-FoundationJson $workflowPaths.state).pending -and $workflowControl.submits -eq 1)
                Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'account' 'Deploy' 'mock-compiler' $true }
                $workflowControl.failSubmit=$false
                Reject { Invoke-HostFixtureStatus }
            }
            Check ((Read-FoundationJson $workflowPaths.state).pending -and (Test-Path -LiteralPath $workflowPaths.outputs))
            $orphan=Read-FoundationJson $workflowPaths.outputs
            $bad=Read-ExpansionStandardCopy $orphan; $bad.intentHash='F'*64
            Write-StandardJson $workflowPaths.outputs $bad
            Reject { Invoke-HostFixtureStatus }
            Check ((Read-FoundationJson $workflowPaths.state).pending)
            Write-StandardJson $workflowPaths.outputs $orphan
            $null=Invoke-HostFixtureStatus
            Check ((Read-FoundationJson $workflowPaths.state).verified -and -not (Read-FoundationJson $workflowPaths.state).pending)
            $completeHash=(Get-FileHash -LiteralPath $workflowPaths.state -Algorithm SHA256).Hash
            $null=Invoke-HostFixtureStatus
            Check ((Get-FileHash -LiteralPath $workflowPaths.state -Algorithm SHA256).Hash -ceq $completeHash)
            $beforeSubmits=$workflowControl.submits
            if ($workflowSelector -cne 'a-test') {
                $otherSelector=if ($workflowSelector -ceq 'b-dev') { 'b-test' } else { 'b-dev' }
                Reject { Invoke-ExpansionHosts $workflowOriginal $otherSelector 'account' 'Deploy' 'mock-compiler' $true }
                $null=Invoke-ExpansionHosts $workflowOriginal $otherSelector 'account' 'Status' 'forbidden-compiler' $false
                Check ($workflowControl.submits -eq $beforeSubmits)
            }
            $workflowBinding=Get-ExpansionHostBinding $workflowState $workflowPrerequisites $workflowSelector 'project'
            $workflowPaths=Get-ExpansionHostPaths $workflowState $workflowSelector 'project'
            $null=Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'project' 'Preview' 'mock-compiler' $true
            $workflowControl.wrongLive=$true
            Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'project' 'Deploy' 'mock-compiler' $true }
            $workflowControl.wrongLive=$false
            $workflowControl.changedSources=$true
            Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'project' 'Deploy' 'mock-compiler' $true }
            $workflowControl.changedSources=$false
            $templateText=[IO.File]::ReadAllText($workflowPaths.template)
            [IO.File]::AppendAllText($workflowPaths.template,' ')
            Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'project' 'Deploy' 'mock-compiler' $true }
            [IO.File]::WriteAllText($workflowPaths.template,$templateText,[Text.UTF8Encoding]::new($false))
            $workflowControl.race=$true
            Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'project' 'Deploy' 'mock-compiler' $true }
            Check ($workflowControl.submits -eq $beforeSubmits)
            $workflowLive.hosts.Remove($workflowBinding.hostId); $workflowControl.race=$false
            $file=Join-Path $workflowRoot 'cosmos-b-test.json'; $protectedText=[IO.File]::ReadAllText($file)
            $workflowControl.tamperProtected=$true
            Reject { Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'project' 'Deploy' 'mock-compiler' $true }
            Check ($workflowControl.submits -eq $beforeSubmits)
            [IO.File]::WriteAllText($file,$protectedText,[Text.UTF8Encoding]::new($false))
            $null=Invoke-ExpansionHosts $workflowOriginal $workflowSelector 'project' 'Deploy' 'mock-compiler' $true
            Check ($workflowControl.submits -eq $beforeSubmits+1)
            $null=Invoke-HostFixtureStatus
            Check ((Read-FoundationJson $workflowPaths.state).verified)
            $workflowControl.wrongLive=$true
            Reject { Invoke-HostFixtureStatus }
            $workflowControl.wrongLive=$false
            Check ((Get-FileHash -LiteralPath $workflowOriginal -Algorithm SHA256).Hash -ceq $workflowOriginalHash)
            foreach ($file in $workflowPrerequisites.files.Keys) { Check ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ceq $workflowPrerequisites.files[$file]) }
        } finally { Remove-Item -LiteralPath $workflowRoot -Recurse -Force }
    }
}
& {
    $gateRoot=Join-Path ([IO.Path]::GetTempPath()) ('expansion-host-gates-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($gateRoot)
    try {
        $gateState=Read-ExpansionStandardCopy $hostFixtureState; $gateState.runDirectory=$gateRoot
        $gateNetwork=Read-ExpansionStandardCopy $hostFixturePrerequisites.network
        $gateNetwork.inputs=@{state=('A'*64)}; $gateNetwork.files=@{}
        $gateNetworkSources=Get-ExpansionNetworkSources
        $gateCosmos=@{}; $gateOutputs=@{}
        foreach ($selection in @('a-test','b-dev','b-test')) {
            $paths=Get-ExpansionNetworkPaths $gateState $selection
            $binding=$cosmos[$selection].binding
            [IO.File]::WriteAllText($paths.source,(New-ExpansionNetworkBicep $binding),[Text.UTF8Encoding]::new($false))
            $template=New-ExpansionCosmosNetworkTemplate $binding $binding.names.scope
            $template.metadata=@{_generator=@{name='bicep';version='fixture';templateHash='fixture'}}
            Write-StandardJson $paths.template $template
            Write-StandardJson $paths.parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=@{}}
            Write-StandardJson $paths.whatif @{status='Succeeded';changes=@(@{resourceId=$binding.names.ruleId;changeType='Create';after=$liveRules[$selection]})}
            $artifacts=@{}; foreach ($key in @('source','template','parameters','whatif')) { $artifacts[$key]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
            $manifest=@{stage='cosmos-network';project=$selection;pending=$true;verified=$false;binding=$binding;known=@{};baseline=@{};idle=@{};foundationBinding=$gateNetwork.foundation;submittedAt=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o');deploymentId=(Get-ExpansionNetworkDeploymentId $binding);review=@{approved=$true;checkedAt=[DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o');inputHashes=$gateNetwork.inputs;fileHashes=@{};sourceHashes=$gateNetworkSources;artifactHashes=$artifacts;bindingHash=(Get-FoundationHash $binding);knownHash=(Get-FoundationHash @{});baselineHash=(Get-FoundationHash @{});idleHash=(Get-FoundationHash @{})}}
            $output=@{stage='cosmos-network';project=$selection;controlPlaneVerified=$true;runtimeVerified=$false;inferenceVerified=$false;completeLab=$false;verifiedAt=[DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o');deploymentId=$manifest.deploymentId;ruleId=$binding.names.ruleId;inputHashes=$gateNetwork.inputs;sourceHashes=$gateNetworkSources;intentHash=(Get-ExpansionNetworkIntentHash $manifest);deploymentProof=@{deploymentHash=('B'*64);operationsHash=('C'*64)};azureReadOnly=$true}
            Write-StandardJson $paths.outputs $output
            $manifest.outputHash=(Get-FileHash -LiteralPath $paths.outputs -Algorithm SHA256).Hash; $manifest.pending=$false; $manifest.verified=$true
            Write-StandardJson $paths.state $manifest
            $gateCosmos[$selection]=$manifest; $gateOutputs[$selection]=$output
        }
        function Get-ExpansionNetworkPrerequisites { param($State,$OriginalPath,$Compiler,$FoundationBinding) Check ($Compiler -ceq ''); Assert-FoundationEqual $FoundationBinding $gateNetwork.foundation; return $gateNetwork }
        $verified=Get-ExpansionHostPrerequisites $gateState 'unused-original-path'
        Check ($verified.cosmos.Count -eq 3 -and $verified.receipts.Count -eq 3)
        foreach ($selection in @('a-test','b-dev','b-test')) {
            $paths=Get-ExpansionNetworkPaths $gateState $selection
            foreach ($mutation in @(
                {param($value) $value.pending=$true},
                {param($value) $value.verified=$false},
                {param($value) $value.outputHash='D'*64},
                {param($value) $value.review.approved=$false},
                {param($value) $value.review.sourceHashes=@{wrong='changed'}},
                {param($value) $value.binding.names.ruleId+='-wrong'}
            )) {
                $bad=Read-ExpansionStandardCopy $gateCosmos[$selection]; & $mutation $bad
                Write-StandardJson $paths.state $bad
                Reject { Get-ExpansionHostPrerequisites $gateState 'unused-original-path' }
                Write-StandardJson $paths.state $gateCosmos[$selection]
            }
            $bad=Read-ExpansionStandardCopy $gateOutputs[$selection]; $bad.intentHash='F'*64
            Write-StandardJson $paths.outputs $bad
            $altered=Read-ExpansionStandardCopy $gateCosmos[$selection]; $altered.outputHash=(Get-FileHash -LiteralPath $paths.outputs -Algorithm SHA256).Hash
            Write-StandardJson $paths.state $altered
            Reject { Get-ExpansionHostPrerequisites $gateState 'unused-original-path' }
            Write-StandardJson $paths.outputs $gateOutputs[$selection]
            Write-StandardJson $paths.state $gateCosmos[$selection]
        }
        $hostBinding=Get-ExpansionHostBinding $gateState $hostFixturePrerequisites 'b-dev' 'account'
        $hostIntent=@{key='account-b';mode='Create';pending=$true;verified=$false;binding=$hostBinding;deploymentId=$hostBinding.root}
        $gateDeployment=@{id=$hostBinding.root;name=($hostBinding.root -split '/')[-1];properties=@{provisioningState='Succeeded';mode='Incremental';parameters=$hostBinding.parameters;outputs=@{resourceId=@{type='String';value=$hostBinding.hostId}};outputResources=@(@{id=$hostBinding.hostId})}}
        $gateOperations=@(@{id="$($hostBinding.root)/operations/one";properties=@{provisioningState='Succeeded';provisioningOperation='Create';targetResource=@{id=$hostBinding.hostId;resourceType=$hostBinding.type}}})
        $oldDeployment=@{id="$($hostBinding.group)/providers/Microsoft.Resources/deployments/old-root";name='old-root';properties=@{provisioningState='Succeeded';mode='Incremental'}}
        $gateInventory=@($oldDeployment,$gateDeployment)
        $oldProof=@{deploymentHash=(Get-FoundationHash $oldDeployment);operationsHash=('A'*64)}
        $gateGraph=@{}; $gateGraph[$oldDeployment.id]=$oldProof
        $idlePrerequisites=@{network=@{};cosmos=@{receipt=@{idle=$gateGraph}};receipts=@{}}
        function Read-ExpansionNetworkArm {
            param($State,$Id,$Api,[switch]$List)
            if ($Id -ceq $hostBinding.root -and -not $List) { return Read-ExpansionStandardCopy $gateDeployment }
            if ($Id -ceq "$($hostBinding.root)/operations" -and $List) { return Read-ExpansionStandardCopy $gateOperations }
            if ($Id -ceq "$($hostBinding.group)/providers/Microsoft.Resources/deployments" -and $List) { return Read-ExpansionStandardCopy $gateInventory }
            throw 'Unexpected idle transport target'
        }
        function Get-ExpansionNetworkIdle {
            param($State,$Prerequisites,$All,$Selector,[switch]$Submitted,$Receipts)
            Check ([bool]$Submitted)
            $inventory=@(Read-ExpansionNetworkArm $State "$($hostBinding.group)/providers/Microsoft.Resources/deployments" '2022-09-01' -List)
            Assert-FoundationEqual $inventory @($oldDeployment)
            return Read-ExpansionStandardCopy $gateGraph
        }
        $graph=Get-ExpansionHostIdle $gateState $idlePrerequisites @{'account-b'=$hostIntent} @{}
        Check ($graph.Count -eq 2 -and $graph.ContainsKey($hostBinding.root) -and $graph.ContainsKey($oldDeployment.id))
        $hostIntent.pending=$false; $hostIntent.verified=$true
        $hostReceipt=@{deploymentProof=$graph[$hostBinding.root]}
        $null=Get-ExpansionHostIdle $gateState $idlePrerequisites @{'account-b'=$hostIntent} @{'account-b'=$hostReceipt}; Check $true
        $bad=@{deploymentProof=@{deploymentHash=('F'*64);operationsHash=('F'*64)}}
        Reject { Get-ExpansionHostIdle $gateState $idlePrerequisites @{'account-b'=$hostIntent} @{'account-b'=$bad} }
        $gateDeployment.properties.provisioningState='Running'
        Reject { Get-ExpansionHostIdle $gateState $idlePrerequisites @{'account-b'=$hostIntent} @{'account-b'=$hostReceipt} }
        $gateDeployment.properties.provisioningState='Succeeded'
        $gateInventory=@($oldDeployment)
        Reject { Get-ExpansionHostIdle $gateState $idlePrerequisites @{'account-b'=$hostIntent} @{'account-b'=$hostReceipt} }
        $gateInventory=@($oldDeployment,$gateDeployment,$gateDeployment)
        Reject { Get-ExpansionHostIdle $gateState $idlePrerequisites @{'account-b'=$hostIntent} @{'account-b'=$hostReceipt} }
        $gateInventory=@($oldDeployment,$gateDeployment,@{id="$($hostBinding.group)/providers/Microsoft.Resources/deployments/unknown";name='unknown';properties=@{provisioningState='Running'}})
        Reject { Get-ExpansionHostIdle $gateState $idlePrerequisites @{'account-b'=$hostIntent} @{'account-b'=$hostReceipt} }
    } finally { Remove-Item -LiteralPath $gateRoot -Recurse -Force }
}
Assert-FoundationEqual (Get-ExpansionHostSources) $hostTestSourceHashes; Check $true
Write-Output "Expansion hosts: $($hostChecks.count) offline assertions passed."