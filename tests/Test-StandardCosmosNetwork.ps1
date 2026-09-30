[CmdletBinding()]
param([string]$BicepExecutable = 'bicep')

$ErrorActionPreference = 'Stop'
$testScript = Join-Path $PSScriptRoot '../scripts/Invoke-StandardCosmosNetwork.ps1'
$modulePath = Join-Path $PSScriptRoot '../infra/modules/standard-cosmos-network.bicep'
$testRoot = $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot '../scripts/LabExecution.psm1')
Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1')
. (Join-Path $PSScriptRoot '../scripts/Invoke-StandardStage.ps1') -DefinitionsOnly
. (Join-Path $PSScriptRoot '../scripts/Test-StandardPrivate.ps1') -DefinitionsOnly
. $testScript -DefinitionsOnly
$checks = @{count=0}
function Check([bool]$Condition) { if (-not $Condition) { throw 'Cosmos network assertion failed' }; $checks.count++ }
function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed }
function Clone($Value) { return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 }
function Invoke-LabAz { throw 'Offline test forbids Azure commands' }

$fixtureState=@{subscriptionId='11111111-1111-4111-8111-111111111111';tenantId='22222222-2222-4222-8222-222222222222';ownershipId='33333333-3333-4333-8333-333333333333';labId='sample01';phase='activate';pendingPhase=$null;minimalPrompt=$true;privateAccessVerified=$true;deploymentAuthorized=$true;preexistingGroupIds=@();resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" });standard=@{completedStages=@('dependencies');pendingStage=$null;deploymentNames=@{dependencies='fgl-sample01-standard-dependencies'}}}
$fixtureNames=Get-CosmosNetworkNames $fixtureState
$fixturePrefix="/subscriptions/$($fixtureState.subscriptionId)/resourceGroups/rg-fgl-sample01"
$fixtureVnet="$fixturePrefix-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01"
$fixtureSubnet="$fixtureVnet/subnets/snet-case-a-pe"
$fixtureAgentNsg="$fixturePrefix-integration/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-sample01-agent-0"
$fixtureCosmos="$fixturePrefix-case-a/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-fgl-sample01-standard"
$fixtureEndpoint="$fixturePrefix-case-a/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-standard-cosmos"
$fixtureNic="$fixturePrefix-case-a/providers/Microsoft.Network/networkInterfaces/nic-cosmos"
$fixtureHost='cosmos-fgl-sample01-standard.documents.azure.com'
$fixtureRegional='cosmos-fgl-sample01-standard-swedencentral.documents.azure.com'
$fixtureTags=@{'fgl-owner'=$fixtureState.ownershipId;'fgl-lab'=$fixtureState.labId}
$fixturePrivate=@{vnetId=$fixtureVnet;subnetId=$fixtureSubnet;targets=@(@{service='cosmos';id=$fixtureCosmos;endpointId=$fixtureEndpoint;name='cosmos-fgl-sample01-standard';hostName=$fixtureHost})}
$fixtureResources=@{}
foreach ($spec in @(@('nsg',$fixtureNames.nsgId,'Microsoft.Network/networkSecurityGroups'),@('agentNsg',$fixtureAgentNsg,'Microsoft.Network/networkSecurityGroups'),@('vnet',$fixtureVnet,'Microsoft.Network/virtualNetworks'),@('subnet',$fixtureSubnet,'Microsoft.Network/virtualNetworks/subnets'),@('agentSubnet',"$fixtureVnet/subnets/snet-agent-a",'Microsoft.Network/virtualNetworks/subnets'),@('cosmos',$fixtureCosmos,'Microsoft.DocumentDB/databaseAccounts'),@('endpoint',$fixtureEndpoint,'Microsoft.Network/privateEndpoints'),@('nic',$fixtureNic,'Microsoft.Network/networkInterfaces'))) {
    $fixtureResources[$spec[0]]=@{id=$spec[1];type=$spec[2];tags=(Clone $fixtureTags);properties=@{provisioningState='Succeeded'}}
}
foreach ($key in @('subnet','agentSubnet','nic')) { $fixtureResources[$key].Remove('tags') }
$fixtureResources.subnet.properties+=@{addressPrefix='10.76.6.0/27';networkSecurityGroup=@{id=$fixtureNames.nsgId};privateEndpointNetworkPolicies='NetworkSecurityGroupEnabled'}
$fixtureResources.agentSubnet.properties+=@{addressPrefix='10.76.1.0/24';networkSecurityGroup=@{id=$fixtureAgentNsg}}
$fixtureResources.vnet.properties.subnets=@((Clone $fixtureResources.subnet),(Clone $fixtureResources.agentSubnet))
$fixtureResources.nsg.properties.securityRules=@()
$fixtureResources.agentNsg.properties.securityRules=@()
$fixtureResources.nsg.properties.defaultSecurityRules=@()
$fixtureResources.agentNsg.properties.defaultSecurityRules=@()
$fixtureLocation=@{locationName='Sweden Central';documentEndpoint="https://${fixtureRegional}:443/"}
$fixtureResources.cosmos.properties+=@{publicNetworkAccess='Disabled';disableLocalAuth=$true;documentEndpoint="https://${fixtureHost}:443/";readLocations=@((Clone $fixtureLocation));writeLocations=@((Clone $fixtureLocation))}
$fixtureResources.endpoint.properties+=@{subnet=@{id=$fixtureSubnet};privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$fixtureCosmos;groupIds=@('Sql');privateLinkServiceConnectionState=@{status='Approved'}}});networkInterfaces=@(@{id=$fixtureNic})}
$fixtureResources.nic.properties+=@{privateEndpoint=@{id=$fixtureEndpoint};ipConfigurations=@()}
foreach ($pair in @(@($fixtureHost,'10.76.6.8'),@($fixtureRegional,'10.76.6.9'))) { $fixtureResources.nic.properties.ipConfigurations+=@{properties=@{privateIPAddress=$pair[1];privateIPAddressVersion='IPv4';subnet=@{id=$fixtureSubnet};privateLinkConnectionProperties=@{groupId='Sql';fqdns=@($pair[0])}}} }
$fixtureLive=Get-CosmosNetworkBinding $fixtureState $fixturePrivate $fixtureResources
$fixtureBinding=$fixtureLive.binding
Check ($fixtureBinding.addresses.Count -eq 2 -and -not $fixtureLive.rule)
Assert-CosmosNetworkState $fixtureState 'Preview'; Check $true
$allStages=Clone $fixtureState; $allStages.standard.completedStages=@('dependencies','account','project','access'); $allStages.standard.deploymentNames.project='fgl-sample01-standard-project'; $allStages.standard.deploymentNames.access='fgl-sample01-standard-access'
Assert-CosmosNetworkState $allStages 'Preview'; Check $true
foreach ($mutation in @({param($value) $value.minimalPrompt=$false},{param($value) $value.minimalPrompt='true'},{param($value) $value.resourceGroups+='rg-foreign'},{param($value) $value.phase='lock'},{param($value) $value.pendingPhase='activate'},{param($value) $value.standard.pendingStage='account'},{param($value) $value.standard.completedStages=@()},{param($value) $value.standard.deploymentNames.dependencies='foreign'})) {
    $value=Clone $fixtureState; & $mutation $value; Reject { Assert-CosmosNetworkState $value 'Preview' }
}
foreach ($mutation in @(
    {param($value) $value.endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId+='foreign'},
    {param($value) $value.endpoint.properties.privateLinkServiceConnections[0].properties.groupIds=@('MongoDB')},
    {param($value) $value.endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status='Pending'},
    {param($value) $value.endpoint.properties.privateLinkServiceConnections+=$value.endpoint.properties.privateLinkServiceConnections[0]},
    {param($value) $value.endpoint.properties.subnet.id=$value.endpoint.properties.subnet.id.Replace('case-a','case-b')},
    {param($value) $value.nic.properties.privateEndpoint.id+='foreign'},
    {param($value) $value.nic.properties.ipConfigurations[1].properties.privateIPAddress='10.76.7.9'},
    {param($value) $value.nic.properties.ipConfigurations[1].properties.privateIPAddress='10.76.6.32'},
    {param($value) $value.nic.properties.ipConfigurations[1].properties.privateIPAddress='10.76.6.31'},
    {param($value) $value.nic.properties.ipConfigurations[1].properties.privateIPAddress='10.76.6.3'},
    {param($value) $value.nic.properties.ipConfigurations[1].properties.privateIPAddress='10.76.6.8'},
    {param($value) $value.nic.properties.ipConfigurations=@($value.nic.properties.ipConfigurations[0])},
    {param($value) $value.nic.properties.ipConfigurations[1].properties.privateLinkConnectionProperties.fqdns=@('foreign.documents.azure.com')},
    {param($value) $value.nic.properties.ipConfigurations[1].properties.privateLinkConnectionProperties.fqdns=$value.nic.properties.ipConfigurations[0].properties.privateLinkConnectionProperties.fqdns},
    {param($value) $value.agentSubnet.properties.addressPrefix='10.76.0.0/16'},
    {param($value) $value.agentSubnet.properties.networkSecurityGroup.id+='foreign'},
    {param($value) $value.subnet.properties.privateEndpointNetworkPolicies='Disabled'},
    {param($value) $value.subnet.properties.networkSecurityGroup.id+='foreign'},
    {param($value) $value.nsg.tags['fgl-owner']='66666666-6666-4666-8666-666666666666'},
    {param($value) $value.vnet.tags['fgl-lab']='foreign'},
    {param($value) $value.cosmos.properties.publicNetworkAccess='Enabled'},
    {param($value) $value.cosmos.properties.disableLocalAuth='true'},
    {param($value) $value.cosmos.properties.readLocations=@()},
    {param($value) $value.cosmos.properties.readLocations[0].documentEndpoint='https://foreign.documents.azure.com:443/'},
    {param($value) $value.nsg.properties.securityRules=$null}
)) { $value=Clone $fixtureResources; & $mutation $value; Reject { Get-CosmosNetworkBinding $fixtureState $fixturePrivate $value } }
$fixtureRule=@{id=$fixtureNames.ruleId;name='allow-case-a-cosmos-direct';type='Microsoft.Network/networkSecurityGroups/securityRules';properties=(Get-CosmosNetworkRuleProperties $fixtureBinding.addresses)}
$fixtureRule.properties.provisioningState='Succeeded'
Assert-CosmosNetworkRule $fixtureRule $fixtureNames $fixtureBinding.addresses -Succeeded; Check $true
foreach ($mutation in @({param($value) $value.properties.sourceAddressPrefix='10.76.0.0/16'},{param($value) $value.properties.sourceAddressPrefix='10.76.2.0/24'},{param($value) $value.properties.sourcePortRange='443'},{param($value) $value.properties.destinationPortRange='443'},{param($value) $value.properties.protocol='*'},{param($value) $value.properties.protocol='Udp'},{param($value) $value.properties.priority=126},{param($value) $value.properties.priority=$true},{param($value) $value.properties.direction='Outbound'},{param($value) $value.properties.destinationAddressPrefixes=@('10.76.6.0/27')},{param($value) $value.properties.destinationAddressPrefixes=@('10.76.6.8/32')},{param($value) $value.properties.destinationAddressPrefixes=@('10.76.6.8/32','10.76.6.8/32')},{param($value) $value.properties.destinationAddressPrefix='*'},{param($value) $value.properties.sourceAddressPrefixes=@('*')})) { $value=Clone $fixtureRule; & $mutation $value; Reject { Assert-CosmosNetworkRule $value $fixtureNames $fixtureBinding.addresses } }
$value=Clone $fixtureResources; $value.nsg.properties.securityRules=@($fixtureRule)
Reject { Get-CosmosNetworkBinding $fixtureState $fixturePrivate $value }
$collision=Clone $fixtureResources; $collisionRule=Clone $fixtureRule; $collisionRule.id=$collisionRule.id.Replace('allow-case-a-cosmos-direct','foreign'); $collision.nsg.properties.securityRules=@($collisionRule)
Reject { Get-CosmosNetworkBinding $fixtureState $fixturePrivate $collision }
$fixtureWhatIf=@{status='Succeeded';changes=@(@{resourceId=$fixtureNames.ruleId;changeType='Create';after=(Clone $fixtureRule)})}
Assert-CosmosNetworkWhatIf $fixtureState $fixtureBinding $fixtureWhatIf; Check $true
foreach ($mutation in @({param($value) $value.status='Failed'},{param($value) $value.changes=@()},{param($value) $value.changes+=$value.changes[0]},{param($value) $value.changes[0].changeType='Modify'},{param($value) $value.changes[0].changeType='Delete'},{param($value) $value.changes[0].changeType='Unsupported'},{param($value) $value.changes[0].changeType='NoChange'},{param($value) $value.changes[0].resourceId=$fixtureNames.nsgId},{param($value) $value.changes[0].after.properties.destinationPortRange='443'},{param($value) $value.changes[0].delta=@(@{path='properties';propertyChangeType='Modify'})})) { $value=Clone $fixtureWhatIf; & $mutation $value; Reject { Assert-CosmosNetworkWhatIf $fixtureState $fixtureBinding $value } }
$unchanged=@{id=$fixtureNames.nsgId;properties=@{same=$true}}
$ignored=Clone $fixtureWhatIf; $ignored.changes+=@{resourceId=$fixtureNames.nsgId;changeType='Ignore';before=(Clone $unchanged);after=(Clone $unchanged)}
Assert-CosmosNetworkWhatIf $fixtureState $fixtureBinding $ignored; Check $true
$ignored.changes[1].after.properties.same=$false; Reject { Assert-CosmosNetworkWhatIf $fixtureState $fixtureBinding $ignored }
$ignored.changes[1].Remove('after'); Reject { Assert-CosmosNetworkWhatIf $fixtureState $fixtureBinding $ignored }

$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) "cosmos-network-$([guid]::NewGuid().ToString('N'))"
$null=[IO.Directory]::CreateDirectory($fixtureRoot)
try {
    $fixtureState.runDirectory=$fixtureRoot; $fixtureState.azureConfigDirectory=Join-Path $fixtureRoot 'az'
    $fixturePaths=Get-CosmosNetworkPaths $fixtureState
    & $BicepExecutable build $modulePath --outfile $fixturePaths.template
    if ($LASTEXITCODE -ne 0) { throw 'Local Bicep compile failed' }
    $compiled=Get-Content -LiteralPath $fixturePaths.template -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-CosmosNetworkTemplate $compiled; Check $true
    foreach ($mutation in @({param($value) $value.resources=@(@{type='Microsoft.Network/networkSecurityGroups';apiVersion='2024-05-01';name='foreign';properties=@{securityRules=@()}})},{param($value) $value.resources=@()},{param($value) $value.parameters.cosmosPrivateAddresses.maxLength=6},{param($value) $value.parameters.cosmosPrivateAddresses.defaultValue=@('*')},{param($value) $value.variables.endpointNsgName=$true},{param($value) $value.outputs.ruleId.value='foreign'})) { $value=Clone $compiled; & $mutation $value; Reject { Assert-CosmosNetworkTemplate $value } }
    foreach ($mutation in @({param($value) $value.condition=$false},{param($value) $value.scope='foreign'},{param($value) $value.properties.destinationPortRange='443'},{param($value) $value.properties.sourceAddressPrefix='*'},{param($value) $value.properties.destinationAddressPrefixes=@('*')},{param($value) $value.properties.protocol='*'})) {
        $value=Clone $compiled
        $resources=if ($value.resources -is [Collections.IDictionary]) { @($value.resources.Values) } else { @($value.resources) }
        $child=@($resources | Where-Object type -CEQ 'Microsoft.Network/networkSecurityGroups/securityRules')[0]
        & $mutation $child; Reject { Assert-CosmosNetworkTemplate $value }
    }
    foreach ($file in @($testScript,$modulePath,(Join-Path $testRoot 'Test-StandardCosmosNetwork.ps1'))) { Assert-PublicText (Get-Content -LiteralPath $file -Raw); Check $true }
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($testScript,[ref]$tokens,[ref]$errors); Check ($errors.Count -eq 0)
    & {
        function Import-Module { throw 'DefinitionsOnly imported a module' }
        function Read-LabRun { throw 'DefinitionsOnly read state' }
        function Invoke-LabAz { throw 'DefinitionsOnly called Azure' }
        & $testScript -DefinitionsOnly
    }
    Check $true
    Write-StandardJson (Join-Path $fixtureRoot 'outputs.json') @{synthetic=$true}
    Write-StandardJson (Join-Path $fixtureRoot 'standard-outputs.json') @{synthetic=$true}
    Write-StandardJson $fixturePaths.parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=@{labId=@{value=$fixtureState.labId};cosmosPrivateAddresses=@{value=@('10.76.6.8/32','10.76.6.9/32')}}}
    Write-StandardJson $fixturePaths.whatif $fixtureWhatIf
    $fixtureReview=@{checkedAt=[DateTimeOffset]::UtcNow.ToString('o');templateHash=(Get-FileHash $fixturePaths.template).Hash;parametersHash=(Get-FileHash $fixturePaths.parameters).Hash;sourceHash=(Get-FileHash $modulePath).Hash;whatifHash=(Get-FileHash $fixturePaths.whatif).Hash;bindingHash=(Get-CosmosNetworkHash $fixtureBinding);binding=$fixtureBinding;stateHash=(Get-StandardPrivateStamp $fixtureState)}
    Assert-CosmosNetworkReview $fixtureState $fixtureReview $fixtureBinding $fixturePaths $modulePath; Check $true
    foreach ($mutation in @({param($value) $value.checkedAt=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')},{param($value) $value.checkedAt=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')},{param($value) $value.templateHash='stale'},{param($value) $value.sourceHash='stale'},{param($value) $value.parametersHash='stale'},{param($value) $value.whatifHash='stale'},{param($value) $value.binding.addresses=@('10.76.6.8')})) { $value=Clone $fixtureReview; & $mutation $value; Reject { Assert-CosmosNetworkReview $fixtureState $value $fixtureBinding $fixturePaths $modulePath } }
    $tracked=Clone $fixtureState; $tracked.standard.cosmosNetwork=@{name=$fixtureNames.name;group=$fixtureNames.group;ruleId=$fixtureNames.ruleId;pending=$true;verified=$false;review=(Clone $fixtureReview)}
    Assert-CosmosNetworkState $tracked 'Status'; Check $true
    Reject { Assert-CosmosNetworkState $tracked 'Deploy' }; Reject { Assert-CosmosNetworkState $tracked 'Preview' }
    $owned=Clone $fixtureResources; $owned.nsg.properties.securityRules=@((Clone $fixtureRule))
    $ownedLive=Get-CosmosNetworkBinding $tracked $fixturePrivate $owned
    Check ((Get-CosmosNetworkHash $ownedLive.binding) -ceq (Get-CosmosNetworkHash $fixtureBinding))
    $unbound=Clone $tracked; $unbound.standard.cosmosNetwork.review.bindingHash='stale'
    Reject { Get-CosmosNetworkBinding $unbound $fixturePrivate $owned }
    $unbound=Clone $tracked; $unbound.standard.cosmosNetwork.ruleId+='foreign'
    Reject { Get-CosmosNetworkBinding $unbound $fixturePrivate $owned }
    $noChange=Clone $fixtureWhatIf; $noChange.changes[0].changeType='NoChange'; $noChange.changes[0].before=Clone $fixtureRule
    Assert-CosmosNetworkWhatIf $tracked $fixtureBinding $noChange; Check $true
    $rootNames=@('bootstrap','lock','activate','standard-dependencies')
    $fixtureRoots=@($rootNames | ForEach-Object { @{name="fgl-sample01-$_";id="/subscriptions/$($fixtureState.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-sample01-$_";properties=@{provisioningState='Succeeded'}} })
    $fixtureNested=@{}
    foreach ($group in $fixtureState.resourceGroups) { $fixtureNested[$group]=@(@{name='nested';id="/subscriptions/$($fixtureState.subscriptionId)/resourceGroups/$group/providers/Microsoft.Resources/deployments/nested";properties=@{provisioningState='Succeeded'}}) }
    $fixtureNested[$fixtureNames.group]+=@{name=$fixtureNames.name;id=$fixtureNames.deploymentId;properties=@{provisioningState='Running'}}
    Reject { Assert-StandardTerminal $tracked $fixtureRoots $fixtureNested }
    $fixtureNested[$fixtureNames.group][1].properties.provisioningState='Succeeded'; Assert-StandardTerminal $tracked $fixtureRoots $fixtureNested; Check $true
    & {
        function Invoke-LabAz { param($State,$Arguments,$Label) return @{value=@();nextLink='more'} }
        Reject { Confirm-CosmosNetworkDeploymentAbsent $fixtureState }
    }
    & {
        function Invoke-LabAz { param($State,$Arguments,$Label) return @{value=@(@{id=$fixtureNames.deploymentId;name=$fixtureNames.name})} }
        Reject { Confirm-CosmosNetworkDeploymentAbsent $fixtureState }
    }
    Write-StandardJson $fixturePaths.review $fixtureReview
    foreach ($scenario in @('deploy','start-failure','stale-live','idle-failure','changed-state','status-running','status-failed','status-success','status-retry','status-wrong-rule')) {
        $scenarioData=@{state=(Clone $fixtureState);calls=[Collections.Generic.List[object]]::new();saves=0;liveReads=0;idleReads=0;stateReads=0}
        if ($scenario -like 'status-*') { $scenarioData.state=Clone $tracked }
        if ($scenario -eq 'status-retry') { $scenarioData.state.standard.cosmosNetwork.pending=$false; $scenarioData.state.standard.cosmosNetwork.verified=$true }
        $originalStages=Get-CosmosNetworkHash $scenarioData.state.standard.completedStages; $originalNames=Get-CosmosNetworkHash $scenarioData.state.standard.deploymentNames
        & {
            function Read-LabRun {
                param($StatePath)
                $scenarioData.stateReads++
                if ($scenarioData.stateReads -eq 3) {
                    $scenarioData.state.concurrentField='preserved'
                    if ($scenario -eq 'changed-state') { $scenarioData.state.standard.pendingStage='account' }
                }
                return Clone $scenarioData.state
            }
            function Save-LabRun { param($State,$StatePath) $scenarioData.saves++; $scenarioData.state=Clone $State }
            function Confirm-LabRunContext { param($State) foreach ($groupName in $State.resourceGroups) { @{name=$groupName;id="/subscriptions/$($State.subscriptionId)/resourceGroups/$groupName";tags=(Clone $fixtureTags)} } }
            function Confirm-StandardIdle { param($State) $scenarioData.idleReads++; if ($scenario -eq 'idle-failure' -and $scenarioData.idleReads -eq 2) { throw 'Concurrent nested deployment' } }
            function Read-StandardArm { param($State,$Id,$Api,$Label,[switch]$List) if (-not $List -or $Label -cne 'cosmos-deployments') { throw 'Unexpected offline read' }; return @() }
            function Get-CosmosNetworkLive {
                param($State)
                $scenarioData.liveReads++; $reply=Clone $fixtureLive
                if ($scenario -like 'status-*') { $reply.rule=Clone $fixtureRule }
                if ($scenario -eq 'stale-live' -and $scenarioData.liveReads -eq 2) { $reply.binding.addresses=@('10.76.6.8','10.76.6.10') }
                if ($scenario -eq 'status-wrong-rule') { $reply.rule.properties.destinationPortRange='443' }
                return $reply
            }
            function Invoke-LabAz {
                param($State,$Arguments,$Label)
                $scenarioData.calls.Add(@($Arguments))
                switch ($Label) {
                    'cosmos-network-validate' { Check (($Arguments[0..2] -join ',') -ceq 'deployment,group,validate'); return @{properties=@{provisioningState='Succeeded'}} }
                    'cosmos-network-whatif' { Check (($Arguments[0..2] -join ',') -ceq 'deployment,group,what-if'); return Clone $fixtureWhatIf }
                    'cosmos-network-start' {
                        Check ($scenarioData.saves -eq 1 -and $scenarioData.state.standard.cosmosNetwork.pending -and -not $scenarioData.state.standard.cosmosNetwork.verified)
                        Check (($Arguments[0..2] -join ',') -ceq 'deployment,group,create' -and $Arguments[-1] -ceq '--no-wait' -and $Arguments[4] -ceq $fixtureNames.group -and $Arguments[6] -ceq $fixtureNames.name -and $Arguments[8] -ceq 'Incremental')
                        if ($scenario -eq 'start-failure') { throw 'Submission transport failed' }; return $null
                    }
                    'cosmos-network-status' {
                        Check (($Arguments[0..2] -join ',') -ceq 'deployment,group,show')
                        $status=if ($scenario -eq 'status-running') { 'Running' } elseif ($scenario -eq 'status-failed') { 'Failed' } else { 'Succeeded' }
                        return @{id=$fixtureNames.deploymentId;name=$fixtureNames.name;properties=@{mode='Incremental';provisioningState=$status;outputs=@{ruleId=@{value=$fixtureNames.ruleId}}}}
                    }
                    default { throw 'Offline fixture forbids this command' }
                }
            }
            $failed=$false
            try { $null=Invoke-StandardCosmosNetwork (Join-Path $fixtureRoot 'state.json') $(if ($scenario -like 'status-*') { 'Status' } else { 'Deploy' }) } catch { if ($scenario -cin @('deploy','status-running','status-success','status-retry')) { throw }; $failed=$true }
            Check ($failed -eq ($scenario -cin @('start-failure','stale-live','idle-failure','changed-state','status-failed','status-wrong-rule')))
        }
        Check ((Get-CosmosNetworkHash $scenarioData.state.standard.completedStages) -ceq $originalStages -and (Get-CosmosNetworkHash $scenarioData.state.standard.deploymentNames) -ceq $originalNames)
        $creates=@($scenarioData.calls.ToArray() | Where-Object { $_[0] -eq 'deployment' -and $_[2] -eq 'create' })
        Check ($creates.Count -eq [int]($scenario -in @('deploy','start-failure')))
        if ($scenario -in @('status-success','status-retry')) { Check (-not $scenarioData.state.standard.cosmosNetwork.pending -and $scenarioData.state.standard.cosmosNetwork.verified -and (Test-Path $fixturePaths.evidence)) }
        if ($scenario -in @('deploy','start-failure','status-failed','status-running','status-wrong-rule')) { Check $scenarioData.state.standard.cosmosNetwork.pending }
        if ($scenario -in @('stale-live','idle-failure','changed-state')) { Check ($scenarioData.saves -eq 0) }
        if ($scenario -in @('deploy','start-failure')) { Check ($scenarioData.state.concurrentField -ceq 'preserved') }
    }
    Write-Output "Standard Cosmos network offline checks passed: $($checks.count). No Azure calls performed."
} finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }