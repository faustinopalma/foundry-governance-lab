[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$testRoot=$PSScriptRoot
$testScript=Join-Path $testRoot '../scripts/ExpansionCosmosNetwork.ps1'
$checks=@{count=0}
function Check([bool]$Value) { if (-not $Value) { throw 'Expansion Cosmos network assertion failed' }; $checks.count++ }
function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed }
function Clone($Value) { return ,(ConvertTo-Json -InputObject $Value -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate) }
function Invoke-LabAz { throw 'Offline test forbids Azure calls' }
function Read-LabRun { throw 'Offline test forbids reading execution state' }
function Save-LabRun { throw 'Offline test forbids writing execution state' }

$StatePath='caller-state'; $Project='b-test'; $Action='Status'; $BicepExecutable='caller-compiler'; $DefinitionsOnly=$false
$ApproveFoundationCreation=$true; $ApproveValidatorRevision=$true
. $testScript -DefinitionsOnly
Check ($StatePath -ceq 'caller-state' -and $Project -ceq 'b-test' -and $Action -ceq 'Status' -and $BicepExecutable -ceq 'caller-compiler' -and -not $DefinitionsOnly -and $ApproveFoundationCreation -and $ApproveValidatorRevision)

function New-FixtureRule([string]$NsgId, [string]$Name, [int]$Priority, [switch]$Default) {
    $child=if ($Default) { 'defaultSecurityRules' } else { 'securityRules' }
    return @{id="$NsgId/$child/$Name";name=$Name;type="Microsoft.Network/networkSecurityGroups/$child";properties=@{provisioningState='Succeeded';priority=$Priority;direction='Inbound';access='Allow';protocol='*';sourceAddressPrefix='VirtualNetwork';sourcePortRange='*';destinationAddressPrefix='VirtualNetwork';destinationPortRange='*'}}
}

function New-NetworkFixture([string]$Selection) {
    $state=@{subscriptionId='11111111-1111-4111-8111-111111111111';ownershipId='33333333-3333-4333-8333-333333333333';labId='sample01'}
    $scope="/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01-integration"
    $names=Get-ExpansionCosmosNetworkNames $state $Selection $scope
    $caseId=$Selection.Substring(0,1); $octet=if ($caseId -ceq 'a') { 6 } else { 7 }; $agentIndex=if ($caseId -ceq 'a') { 0 } else { 1 }
    $groupName="rg-fgl-sample01-case-$caseId"; $group="/subscriptions/$($state.subscriptionId)/resourceGroups/$groupName"
    $vnet="$scope/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01"; $subnet="$vnet/subnets/snet-case-$caseId-pe"
    $agentSubnet="$vnet/subnets/snet-agent-$caseId"; $agentNsg="$scope/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-sample01-agent-$agentIndex"
    $code=@{'a-test'='at';'b-dev'='bd';'b-test'='bt'}[$Selection]
    $cosmosName="cosmos-fgl-sample01-exp-$code-abcdefghijklm"; $cosmos="$group/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosName"
    $endpoint="$group/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-exp-$Selection-cosmos"; $nic="$group/providers/Microsoft.Network/networkInterfaces/nic-exp-$Selection-cosmos"
    $hostName="$cosmosName.documents.azure.com"; $regional="$cosmosName-swedencentral.documents.azure.com"
    $account="$group/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-$caseId-abcdefghijklm"
    $output=@{controlPlaneVerified=$true;completeLab=$false;standard=@{stage='dependencies';completeLab=$false;labId=$state.labId;ownershipId=$state.ownershipId;projectSelector=$Selection;projectPrincipalId='44444444-4444-4444-8444-444444444444';resourceGroupName=$groupName;resourceGroupId=$group;integrationResourceGroupName=$names.group;accountId=$account;projectId="$account/projects/case-$Selection";cosmos=@{id=$cosmos;name=$cosmosName;endpoint="https://${hostName}:443/"};vnetId=$vnet;subnetId=$subnet;privateEndpointIds=@('blob','search','cosmos' | ForEach-Object { "$group/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-exp-$Selection-$_" })}}
    $tags=@{'fgl-owner'=$state.ownershipId;'fgl-lab'=$state.labId;purpose='synthetic-governance-lab'}; $resources=@{}
    foreach ($spec in @(@('nsg',$names.nsgId,'Microsoft.Network/networkSecurityGroups'),@('agentNsg',$agentNsg,'Microsoft.Network/networkSecurityGroups'),@('vnet',$vnet,'Microsoft.Network/virtualNetworks'),@('subnet',$subnet,'Microsoft.Network/virtualNetworks/subnets'),@('agentSubnet',$agentSubnet,'Microsoft.Network/virtualNetworks/subnets'),@('cosmos',$cosmos,'Microsoft.DocumentDB/databaseAccounts'),@('endpoint',$endpoint,'Microsoft.Network/privateEndpoints'),@('nic',$nic,'Microsoft.Network/networkInterfaces'))) {
        $resources[$spec[0]]=@{id=$spec[1];type=$spec[2];tags=(Clone $tags);properties=@{provisioningState='Succeeded'}}
    }
    foreach ($key in @('subnet','agentSubnet','nic')) { $resources[$key].Remove('tags') }
    $resources.subnet.properties+=@{addressPrefix=$names.destinationPrefix;networkSecurityGroup=@{id=$names.nsgId};privateEndpointNetworkPolicies='NetworkSecurityGroupEnabled'}
    $resources.agentSubnet.properties+=@{addressPrefix=$names.sourcePrefix;networkSecurityGroup=@{id=$agentNsg}}
    $resources.vnet.properties.subnets=@((Clone $resources.subnet),(Clone $resources.agentSubnet))
    $location=@{locationName='Sweden Central';documentEndpoint="https://${regional}:443/"}
    $resources.cosmos.properties+=@{publicNetworkAccess='Disabled';disableLocalAuth=$true;documentEndpoint="https://${hostName}:443/";readLocations=@((Clone $location));writeLocations=@((Clone $location))}
    $resources.endpoint.properties+=@{subnet=@{id=$subnet};privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$cosmos;groupIds=@('Sql');privateLinkServiceConnectionState=@{status='Approved'}}});networkInterfaces=@(@{id=$nic})}
    $resources.nic.properties+=@{privateEndpoint=@{id=$endpoint};ipConfigurations=@()}
    $first=@{'a-test'=12;'b-dev'=8;'b-test'=10}[$Selection]
    foreach ($pair in @(@($hostName,"10.76.$octet.$first"),@($regional,"10.76.$octet.$($first+1)"))) {
        $resources.nic.properties.ipConfigurations+=@{properties=@{privateIPAddress=$pair[1];privateIPAddressVersion='IPv4';subnet=@{id=$subnet};privateLinkConnectionProperties=@{groupId='Sql';fqdns=@($pair[0])}}}
    }
    $original=New-FixtureRule $names.nsgId 'allow-case-a-cosmos-direct' 125
    $original.properties.protocol='Tcp'; $original.properties.sourceAddressPrefix='10.76.1.0/24'; $original.properties.Remove('destinationAddressPrefix'); $original.properties.destinationAddressPrefixes=@('10.76.6.8/32','10.76.6.9/32')
    $sibling=if ($Selection -ceq 'b-dev') { 'a-test' } else { 'b-dev' }
    $siblingNames=Get-ExpansionCosmosNetworkNames $state $sibling $scope
    $siblingRule=New-FixtureRule $names.nsgId $siblingNames.ruleName $siblingNames.priority
    $siblingAddresses=if ($sibling -ceq 'a-test') { @('10.76.6.12','10.76.6.13') } else { @('10.76.7.8','10.76.7.9') }
    $siblingRule.properties=Get-ExpansionCosmosNetworkRuleProperties $sibling $siblingAddresses; $siblingRule.properties.provisioningState='Succeeded'
    $deny=New-FixtureRule $names.nsgId 'deny-other' 4096; $deny.properties.access='Deny'
    $resources.nsg.properties.securityRules=@($original,$siblingRule,$deny)
    $resources.nsg.properties.defaultSecurityRules=@((New-FixtureRule $names.nsgId 'AllowVnetInBound' 65000 -Default))
    $resources.agentNsg.properties.securityRules=@((New-FixtureRule $agentNsg 'agent-only' 200))
    $resources.agentNsg.properties.defaultSecurityRules=@((New-FixtureRule $agentNsg 'AllowVnetInBound' 65000 -Default))
    return @{state=$state;scope=$scope;output=$output;resources=$resources}
}

foreach ($selector in @('a-test','b-dev','b-test')) {
    $fixture=New-NetworkFixture $selector
    $unchanged=ConvertTo-Json -InputObject $fixture -Depth 100 -Compress
    $binding=Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $fixture.resources $fixture.scope
    Check ((ConvertTo-Json -InputObject $fixture -Depth 100 -Compress) -ceq $unchanged)
    Check ($binding.names.priority -eq @{'a-test'=126;'b-dev'=135;'b-test'=136}[$selector])
    Check ($binding.addresses.Count -eq 2 -and $binding.fqdnAddresses.Count -eq 2 -and $binding.otherRules.Count -eq 3)
    $source=if ($selector -ceq 'a-test') { '10.76.1.0/24' } else { '10.76.2.0/24' }
    $octet=if ($selector -ceq 'a-test') { 6 } else { 7 }
    Check ($binding.names.sourcePrefix -ceq $source -and $binding.names.destinationPrefix -ceq "10.76.$octet.0/27")
    Check ($binding.names.nsgId -ceq "$($fixture.scope)/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-sample01-endpoints")
    foreach ($configuration in $fixture.resources.nic.properties.ipConfigurations) { Check ($binding.fqdnAddresses[$configuration.properties.privateLinkConnectionProperties.fqdns[0]] -ceq $configuration.properties.privateIPAddress) }

    $template=New-ExpansionCosmosNetworkTemplate $binding $fixture.scope
    Assert-ExpansionCosmosNetworkTemplate (Clone $template) $binding $fixture.scope; Check $true
    Check ($template.resources -is [array] -and $template.resources.Count -eq 1 -and $template.resources[0].type -ceq 'Microsoft.Network/networkSecurityGroups/securityRules')
    Check ($template.resources[0].name -ceq "nsg-fgl-sample01-endpoints/allow-exp-$selector-cosmos-direct")
    $properties=$template.resources[0].properties
    Check ($properties.sourceAddressPrefix -ceq $source -and $properties.protocol -ceq 'Tcp' -and $properties.sourcePortRange -ceq '*' -and $properties.destinationPortRange -ceq '*')
    Check ($properties.destinationAddressPrefixes.Count -eq 2 -and @(Compare-Object $properties.destinationAddressPrefixes @($binding.addresses | ForEach-Object { "$_/32" })).Count -eq 0)
    $rule=@{id=$binding.names.ruleId;name=$binding.names.ruleName;type=$template.resources[0].type;properties=(Clone $properties)}; $rule.properties.provisioningState='Succeeded'
    Assert-ExpansionCosmosNetworkRule $rule $binding -Succeeded; Check $true
    $represented=Clone $rule; $represented.name=$template.resources[0].name; $represented.type=$represented.type.ToLowerInvariant(); $represented.properties.protocol='tcp'; $represented.properties.direction='inbound'; $represented.properties.access='allow'; $represented.properties.priority=[long]$represented.properties.priority
    $represented.properties.destinationAddressPrefixes=@($represented.properties.destinationAddressPrefixes[1],$represented.properties.destinationAddressPrefixes[0])
    foreach ($key in @('sourceAddressPrefixes','sourcePortRanges','destinationPortRanges','sourceApplicationSecurityGroups','destinationApplicationSecurityGroups')) { $represented.properties[$key]=@() }
    $represented.properties.destinationAddressPrefix=''; $represented.properties.description=$null
    Assert-ExpansionCosmosNetworkRule $represented $binding -Succeeded; Check $true

    foreach ($mutation in @(
        {param($value) $value.controlPlaneVerified=$false},
        {param($value) $value.controlPlaneVerified='true'},
        {param($value) $value.completeLab=$true},
        {param($value) $value.standard.stage='foundation-only'},
        {param($value) $value.standard.completeLab='false'},
        {param($value) $value.standard.projectSelector='a-dev'},
        {param($value) $value.standard.labId='other01'},
        {param($value) $value.standard.ownershipId='66666666-6666-4666-8666-666666666666'},
        {param($value) $value.standard.projectPrincipalId=$true},
        {param($value) $value.standard.cosmos.name+='x'},
        {param($value) $value.standard.cosmos.id+='-other'},
        {param($value) $value.standard.cosmos.endpoint='https://foreign.documents.azure.com:443/'},
        {param($value) $value.standard.resourceGroupId+='-other'},
        {param($value) $value.standard.resourceGroupName+='-other'},
        {param($value) $value.standard.integrationResourceGroupName+='-other'},
        {param($value) $value.standard.subnetId+='-other'},
        {param($value) $value.standard.vnetId+='-other'},
        {param($value) $value.standard.accountId+='-other'},
        {param($value) $value.standard.projectId+='-other'},
        {param($value) $value.standard.privateEndpointIds=@()},
        {param($value) $value.standard.privateEndpointIds[2]=$value.standard.privateEndpointIds[0]}
    )) { $bad=Clone $fixture.output; & $mutation $bad; Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $bad $fixture.resources $fixture.scope } }

    foreach ($mutation in @(
        {param($value) $value.endpoint.properties.subnet.id+='-other'},
        {param($value) $value.endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId+='-other'},
        {param($value) $value.endpoint.properties.privateLinkServiceConnections[0].properties.groupIds=@('MongoDB')},
        {param($value) $value.endpoint.properties.privateLinkServiceConnections[0].properties.groupIds=@('Sql','Sql')},
        {param($value) $value.endpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status='Pending'},
        {param($value) $value.endpoint.properties.privateLinkServiceConnections+=$value.endpoint.properties.privateLinkServiceConnections[0]},
        {param($value) $value.endpoint.properties.manualPrivateLinkServiceConnections=@(@{name='manual'})},
        {param($value) $value.endpoint.properties.networkInterfaces=@()},
        {param($value) $value.endpoint.properties.networkInterfaces+=$value.endpoint.properties.networkInterfaces[0]},
        {param($value) $value.endpoint.properties.networkInterfaces[0].id=$value.endpoint.properties.networkInterfaces[0].id.Replace('/networkInterfaces/','/virtualMachines/')},
        {param($value) $value.endpoint.properties.networkInterfaces[0].id=$value.endpoint.properties.networkInterfaces[0].id.Replace('/resourceGroups/rg-fgl-sample01-case-','/resourceGroups/foreign-')},
        {param($value) $value.nic.properties.privateEndpoint.id+='-other'},
        {param($value) $value.nic.properties.ipConfigurations=@()},
        {param($value) $value.nic.properties.ipConfigurations=@($value.nic.properties.ipConfigurations[0])},
        {param($value) $value.nic.properties.ipConfigurations=@($value.nic.properties.ipConfigurations[1])},
        {param($value) $value.nic.properties.ipConfigurations+=$value.nic.properties.ipConfigurations[1]},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.privateIPAddress=$value.nic.properties.ipConfigurations[0].properties.privateIPAddress},
        {param($value) $value.nic.properties.ipConfigurations[0].properties.privateLinkConnectionProperties.fqdns=@('foreign.documents.azure.com')},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.privateLinkConnectionProperties.fqdns=@('foreign.documents.azure.com')},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.privateLinkConnectionProperties.fqdns=$value.nic.properties.ipConfigurations[0].properties.privateLinkConnectionProperties.fqdns},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.privateLinkConnectionProperties.fqdns=@()},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.privateLinkConnectionProperties.fqdns+='foreign.documents.azure.com'},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.privateLinkConnectionProperties.groupId='sql'},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.subnet.id+='-other'},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.privateIPAddressVersion='IPv6'},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.publicIPAddress=@{id='public'}},
        {param($value) $value.nic.properties.ipConfigurations[1].properties.publicIPAddress=@{}},
        {param($value) $value.subnet.properties.privateEndpointNetworkPolicies='Disabled'},
        {param($value) $value.subnet.properties.networkSecurityGroup.id=$value.agentNsg.id},
        {param($value) $value.subnet.properties.addressPrefix='10.76.0.0/16'},
        {param($value) $value.agentSubnet.properties.addressPrefix='10.76.0.0/16'},
        {param($value) $value.agentSubnet.properties.networkSecurityGroup.id=$value.nsg.id},
        {param($value) $value.vnet.properties.subnets=@()},
        {param($value) $value.vnet.properties.subnets+=$value.vnet.properties.subnets[0]},
        {param($value) $value.vnet.properties.subnets[0].properties.privateEndpointNetworkPolicies='Disabled'},
        {param($value) $value.cosmos.properties.publicNetworkAccess='Enabled'},
        {param($value) $value.cosmos.properties.disableLocalAuth='true'},
        {param($value) $value.cosmos.properties.documentEndpoint='https://foreign.documents.azure.com:443/'},
        {param($value) $value.cosmos.properties.readLocations=@()},
        {param($value) $value.cosmos.properties.writeLocations=@()},
        {param($value) $value.cosmos.properties.readLocations+=$value.cosmos.properties.readLocations[0]},
        {param($value) $value.cosmos.properties.writeLocations+=$value.cosmos.properties.writeLocations[0]},
        {param($value) $value.cosmos.properties.readLocations[0].documentEndpoint='https://foreign.documents.azure.com:443/'},
        {param($value) $value.cosmos.properties.writeLocations[0].locationName='West Europe'},
        {param($value) $value.cosmos.properties.writeLocations[0].documentEndpoint='https://foreign.documents.azure.com:443/'},
        {param($value) $value.nsg.properties.securityRules=$null},
        {param($value) $value.nsg.properties.defaultSecurityRules=$null},
        {param($value) $value.agentNsg.properties.securityRules=$null},
        {param($value) $value.agentNsg.properties.defaultSecurityRules=$null},
        {param($value) $value.nsg.properties.securityRules[0].properties.priority=124},
        {param($value) $value.nsg.properties.securityRules=@($value.nsg.properties.securityRules[1],$value.nsg.properties.securityRules[2])},
        {param($value) $value.nsg.properties.securityRules[0].name='other'},
        {param($value) $value.nsg.properties.securityRules[0].properties.priority=$true},
        {param($value) $value.nsg.properties.securityRules[0].properties.priority='125'},
        {param($value) $value.nsg.properties.securityRules+=$value.nsg.properties.securityRules[0]}
    )) { $bad=Clone $fixture.resources; & $mutation $bad; Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $bad $fixture.scope } }

    foreach ($key in @('nsg','agentNsg','vnet','subnet','agentSubnet','cosmos','endpoint','nic')) {
        $bad=Clone $fixture.resources; $bad[$key].id+='-foreign'; Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $bad $fixture.scope }
        $bad=Clone $fixture.resources; $bad[$key].type='Microsoft.Network/virtualNetworks'; if ($key -ceq 'vnet') { $bad[$key].type='Microsoft.Network/networkInterfaces' }; Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $bad $fixture.scope }
        $bad=Clone $fixture.resources; $bad[$key].properties.provisioningState='Running'; Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $bad $fixture.scope }
        $bad=Clone $fixture.resources; $bad[$key].tags=@{'fgl-owner'='66666666-6666-4666-8666-666666666666';'fgl-lab'='sample01';purpose='synthetic-governance-lab'}; Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $bad $fixture.scope }
    }
    foreach ($address in @('*','Internet','0.0.0.0/0','8.8.8.8','127.0.0.1','::1','::ffff:10.76.6.4','10.76.5.4',"10.76.$octet.0","10.76.$octet.3","10.76.$octet.31","10.76.$octet.32","10.76.$octet.004","10.76.$octet.4/32","10.76.$octet.0/27",' 10.76.6.4',42,$true,$null)) {
        foreach ($configurationIndex in 0..1) {
            $bad=Clone $fixture.resources; $bad.nic.properties.ipConfigurations[$configurationIndex].properties.privateIPAddress=$address
            Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $bad $fixture.scope }
        }
    }
    $foreignAddress=if ($octet -eq 6) { '10.76.7.4' } else { '10.76.6.4' }
    Reject { Get-ExpansionCosmosNetworkRuleProperties $selector @($binding.addresses[0],$foreignAddress) }
    $boundary=Get-ExpansionCosmosNetworkRuleProperties $selector @("10.76.$octet.4","10.76.$octet.30")
    Check ($boundary.destinationAddressPrefixes -contains "10.76.$octet.4/32" -and $boundary.destinationAddressPrefixes -contains "10.76.$octet.30/32")
    foreach ($addresses in @(@(),@($binding.addresses[0]),@($binding.addresses[0],$binding.addresses[0]),@('10.76.6.4','10.76.6.5','10.76.6.6','10.76.6.7','10.76.6.8','10.76.6.9'))) { Reject { Get-ExpansionCosmosNetworkRuleProperties $selector $addresses } }

    $multi=Clone $fixture.resources
    $extraRegion=@{locationName='West Europe';documentEndpoint="https://$($fixture.output.standard.cosmos.name)-westeurope.documents.azure.com:443/"}
    $multi.cosmos.properties.readLocations+=$extraRegion; $multi.cosmos.properties.writeLocations+=(Clone $extraRegion)
    $extraConfiguration=Clone $multi.nic.properties.ipConfigurations[1]; $extraConfiguration.properties.privateIPAddress="10.76.$octet.20"; $extraConfiguration.properties.privateLinkConnectionProperties.fqdns=@("$($fixture.output.standard.cosmos.name)-westeurope.documents.azure.com")
    $multi.nic.properties.ipConfigurations+=$extraConfiguration
    $multiBinding=Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $multi $fixture.scope
    Check ($multiBinding.addresses.Count -eq 3 -and $multiBinding.fqdnAddresses.Count -eq 3)
    $multi.nic.properties.ipConfigurations=@($multi.nic.properties.ipConfigurations[0],$multi.nic.properties.ipConfigurations[1])
    Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $multi $fixture.scope }

    $plural=Clone $fixture.resources
    foreach ($subnet in @($plural.subnet,$plural.agentSubnet)) { $subnet.properties.addressPrefixes=@($subnet.properties.addressPrefix); $subnet.properties.Remove('addressPrefix') }
    $plural.vnet.properties.subnets=@((Clone $plural.subnet),(Clone $plural.agentSubnet))
    $null=Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $plural $fixture.scope; Check $true
    foreach ($collision in @('exact','name','priority','outbound-priority')) {
        $bad=Clone $fixture.resources; $conflict=Clone $rule
        if ($collision -eq 'name') { $conflict.properties.priority=300 }
        if ($collision -like '*priority') { $conflict.id=$conflict.id.Replace($binding.names.ruleName,'unrelated'); $conflict.name='unrelated' }
        if ($collision -eq 'outbound-priority') { $conflict.properties.direction='Outbound' }
        $bad.nsg.properties.securityRules+=$conflict
        Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $bad $fixture.scope }
    }

    foreach ($mutation in @(
        {param($value) $value.resources=@()},
        {param($value) $value.resources+=$value.resources[0]},
        {param($value) $value.resources=@{child=$value.resources[0]}},
        {param($value) $value.resources[0].type='Microsoft.Network/networkSecurityGroups'},
        {param($value) $value.resources[0].name='foreign/child'},
        {param($value) $value.resources[0].apiVersion='2020-01-01'},
        {param($value) $value.resources[0].scope='foreign'},
        {param($value) $value.resources[0].condition=$false},
        {param($value) $value.resources[0].dependsOn=@('parent')},
        {param($value) $value.parameters=@{}},
        {param($value) $value.outputs=@{}},
        {param($value) $value.'$schema'='foreign'},
        {param($value) $value.contentVersion='2.0.0.0'}
    )) { $bad=Clone $template; & $mutation $bad; Reject { Assert-ExpansionCosmosNetworkTemplate $bad $binding $fixture.scope } }
    foreach ($mutation in @(
        {param($value) $value.sourceAddressPrefix='*'},
        {param($value) $value.sourceAddressPrefix='10.76.0.0/16'},
        {param($value) $value.sourceAddressPrefix=$true},
        {param($value) $value.sourcePortRange='443'},
        {param($value) $value.destinationPortRange='443'},
        {param($value) $value.destinationPortRange='1024-65535'},
        {param($value) $value.protocol='*'},
        {param($value) $value.protocol='Udp'},
        {param($value) $value.priority=125},
        {param($value) $value.priority=$true},
        {param($value) $value.priority=[string]$value.priority},
        {param($value) $value.priority=[double]$value.priority},
        {param($value) $value.direction='Outbound'},
        {param($value) $value.access='Deny'},
        {param($value) $value.destinationAddressPrefixes=@('*')},
        {param($value) $value.destinationAddressPrefixes=@('8.8.8.8/32')},
        {param($value) $value.destinationAddressPrefixes=@('10.76.6.0/27')},
        {param($value) $value.destinationAddressPrefixes=@($value.destinationAddressPrefixes[0])},
        {param($value) $value.destinationAddressPrefixes=@($value.destinationAddressPrefixes[0],$value.destinationAddressPrefixes[0])},
        {param($value) $value.destinationAddressPrefixes[0]=$value.destinationAddressPrefixes[0].Replace('/32','')},
        {param($value) $value.destinationAddressPrefix='*'},
        {param($value) $value.sourceAddressPrefixes=@('*')},
        {param($value) $value.sourcePortRanges=@('*')},
        {param($value) $value.destinationPortRanges=@('*')},
        {param($value) $value.sourceApplicationSecurityGroups=@(@{id='foreign'})},
        {param($value) $value.destinationApplicationSecurityGroups=@(@{id='foreign'})},
        {param($value) $value.description='unexpected'},
        {param($value) $value.extra=$true}
    )) {
        $bad=Clone $template; & $mutation $bad.resources[0].properties; Reject { Assert-ExpansionCosmosNetworkTemplate $bad $binding $fixture.scope }
        $bad=Clone $rule; & $mutation $bad.properties; Reject { Assert-ExpansionCosmosNetworkRule $bad $binding }
    }
    foreach ($scope in @("$($fixture.scope)-foreign",$binding.names.nsgId,$fixture.scope.Replace($fixture.state.subscriptionId,'55555555-5555-4555-8555-555555555555'))) {
        Reject { Get-ExpansionCosmosNetworkBinding $fixture.state $selector $fixture.output $fixture.resources $scope }
        Reject { New-ExpansionCosmosNetworkTemplate $binding $scope }
        Reject { Assert-ExpansionCosmosNetworkTemplate $template $binding $scope }
    }
    foreach ($mutation in @({param($value) $value.id+='-foreign'},{param($value) $value.name='foreign'},{param($value) $value.type='Microsoft.Network/networkSecurityGroups'},{param($value) $value.properties.provisioningState='Running'})) {
        $bad=Clone $rule; & $mutation $bad; Reject { Assert-ExpansionCosmosNetworkRule $bad $binding -Succeeded }
    }

    $after=Clone $fixture.resources; $after.nsg.properties.securityRules+=$represented
    Assert-ExpansionCosmosNetworkPreserved $binding $after.nsg $after.agentNsg; Check $true
    $after.nsg.properties.securityRules=@($after.nsg.properties.securityRules | Sort-Object id -Descending)
    Assert-ExpansionCosmosNetworkPreserved $binding $after.nsg $after.agentNsg; Check $true
    Reject { Assert-ExpansionCosmosNetworkPreserved $binding $fixture.resources.nsg $fixture.resources.agentNsg }
    foreach ($spec in @(@('nsg','securityRules'),@('nsg','defaultSecurityRules'),@('agentNsg','securityRules'),@('agentNsg','defaultSecurityRules'))) {
        $originalRules=$fixture.resources[$spec[0]].properties[$spec[1]]
        foreach ($originalRule in $originalRules) {
            $bad=Clone $after; $target=@($bad[$spec[0]].properties[$spec[1]] | Where-Object id -EQ $originalRule.id)[0]; $target.properties.description='changed'
            Reject { Assert-ExpansionCosmosNetworkPreserved $binding $bad.nsg $bad.agentNsg }
            $bad=Clone $after; $bad[$spec[0]].properties[$spec[1]]=@($bad[$spec[0]].properties[$spec[1]] | Where-Object id -NE $originalRule.id)
            Reject { Assert-ExpansionCosmosNetworkPreserved $binding $bad.nsg $bad.agentNsg }
        }
        $bad=Clone $after; $extra=Clone $originalRules[0]; $extra.id+='-extra'; $extra.name+='-extra'; $extra.properties.priority=if ($spec[1] -eq 'defaultSecurityRules') { 65001 } else { 301 }; $bad[$spec[0]].properties[$spec[1]]+=$extra
        Reject { Assert-ExpansionCosmosNetworkPreserved $binding $bad.nsg $bad.agentNsg }
    }
    $bad=Clone $after; $added=@($bad.nsg.properties.securityRules | Where-Object id -EQ $binding.names.ruleId)[0]; $added.properties.destinationPortRange='443'
    Reject { Assert-ExpansionCosmosNetworkPreserved $binding $bad.nsg $bad.agentNsg }
    $bad=Clone $after; $bad.nsg.tags.purpose='foreign'; Reject { Assert-ExpansionCosmosNetworkPreserved $binding $bad.nsg $bad.agentNsg }
    $detached=ConvertTo-Json -InputObject $binding -Depth 100 -Compress
    $fixture.resources.nsg.properties.securityRules[0].properties.description='input mutated after binding'; $fixture.resources.nsg.tags.purpose='input mutated after binding'
    Check ((ConvertTo-Json -InputObject $binding -Depth 100 -Compress) -ceq $detached)
}

foreach ($selector in @('a-dev','b-prod','A-test','',$null)) { Reject { Get-ExpansionCosmosNetworkNames $fixture.state $selector $fixture.scope }; Reject { Get-ExpansionCosmosNetworkRuleProperties $selector @('10.76.6.4','10.76.6.5') } }
Import-Module (Join-Path $testRoot '../scripts/PublicSource.psm1')
foreach ($file in @($testScript,(Join-Path $testRoot 'Test-ExpansionCosmosNetwork.ps1'))) {
    Assert-PublicText (Get-Content -LiteralPath $file -Raw); Check $true
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors); Check ($errors.Count -eq 0)
    if ($file -eq $testScript) {
        $forbidden=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cin @('Invoke-LabAz','Save-LabRun','Read-LabRun','Read-FoundationArm','Read-StandardArm','Read-ExpansionPrivateArm','Get-Content','Set-Content','Out-File','New-Item','Remove-Item','Start-Process','Invoke-RestMethod','Invoke-WebRequest','az','bicep')},$true))
        Check ($forbidden.Count -eq 0)
        $dotSources=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot},$true))
        Check ($dotSources.Count -eq 1 -and $dotSources[0].Extent.Text -match '-DefinitionsOnly$')
    }
}
Write-Output "PASS: $($checks.count) expansion Cosmos network offline checks. No Azure calls or execution-state writes."