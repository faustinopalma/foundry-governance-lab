[CmdletBinding()]
param([Alias('DefinitionsOnly')][switch]$ExpansionCosmosDefinitionsOnly)

New-Module -Name ExpansionCosmosNetwork -ArgumentList $PSScriptRoot -ScriptBlock {
    param($ExpansionCosmosHelperRoot)
    foreach ($helper in @('Invoke-ExpansionFoundation.ps1','Invoke-StandardCosmosNetwork.ps1','Test-ExpansionPrivate.ps1')) { . (Join-Path $ExpansionCosmosHelperRoot $helper) -DefinitionsOnly }

    function Get-ExpansionCosmosNetworkNames([hashtable]$State, [string]$Selector, [string]$Scope) {
        if ($Selector -cnotin @('a-test','b-dev','b-test')) { throw 'Expansion Cosmos selector required' }
        foreach ($key in @('subscriptionId','ownershipId')) { Assert-FoundationGuid $State[$key] }
        if ($State.labId -isnot [string] -or $State.labId -cnotmatch '^[a-z0-9]{6,12}$') { throw 'Canonical lab name required' }
        $stem="fgl-$($State.labId)"; $group="rg-$stem-integration"
        $expectedScope="/subscriptions/$($State.subscriptionId)/resourceGroups/$group"
        Assert-FoundationText $Scope $expectedScope
        $caseId=$Selector.Substring(0,1)
        $nsgId="$expectedScope/providers/Microsoft.Network/networkSecurityGroups/nsg-$stem-endpoints"
        $ruleName="allow-exp-$Selector-cosmos-direct"
        return @{scope=$expectedScope;group=$group;nsgId=$nsgId;ruleName=$ruleName;ruleId="$nsgId/securityRules/$ruleName";priority=@{'a-test'=126;'b-dev'=135;'b-test'=136}[$Selector];sourcePrefix=$(if ($caseId -ceq 'a') { '10.76.1.0/24' } else { '10.76.2.0/24' });destinationPrefix=$(if ($caseId -ceq 'a') { '10.76.6.0/27' } else { '10.76.7.0/27' })}
    }

    function Get-ExpansionCosmosNetworkRuleProperties([string]$Selector, $Addresses) {
        if ($Selector -cnotin @('a-test','b-dev','b-test')) { throw 'Expansion Cosmos selector required' }
        if ($Addresses -isnot [array] -or $Addresses.Count -lt 2 -or $Addresses.Count -gt 5 -or @($Addresses | Select-Object -Unique).Count -ne $Addresses.Count) { throw 'Unique global and regional Cosmos addresses required' }
        $caseA=$Selector -ceq 'a-test'
        $network=@{addressPrefix=$(if ($caseA) { '10.76.6.' } else { '10.76.7.' })}
        foreach ($address in $Addresses) { Assert-ExpansionPrivateAddress $network $address }
        return @{priority=@{'a-test'=126;'b-dev'=135;'b-test'=136}[$Selector];direction='Inbound';access='Allow';protocol='Tcp';sourceAddressPrefix=$(if ($caseA) { '10.76.1.0/24' } else { '10.76.2.0/24' });sourcePortRange='*';destinationAddressPrefixes=@($Addresses | Sort-Object | ForEach-Object { "$_/32" });destinationPortRange='*'}
    }

    function Assert-ExpansionCosmosNetworkRule($Rule, [hashtable]$Binding, [switch]$Succeeded) {
        $names=Get-ExpansionCosmosNetworkNames $Binding $Binding.selector $Binding.names.scope
        Assert-FoundationEqual $Binding.names $names
        if ($Rule -isnot [hashtable]) { throw 'Rule object required' }
        Assert-FoundationText $Rule.id $names.ruleId
        Assert-FoundationText $Rule.type 'Microsoft.Network/networkSecurityGroups/securityRules'
        $qualifiedName=($names.nsgId -split '/')[-1]+'/'+$names.ruleName
        if ($Rule.name -isnot [string] -or $Rule.name -inotin @($names.ruleName,$qualifiedName)) { throw 'Rule name and identity disagree' }
        $expected=Get-ExpansionCosmosNetworkRuleProperties $Binding.selector $Binding.addresses
        $properties=$Rule.properties
        Assert-CosmosNetworkKeys $properties @($expected.Keys) @('provisioningState','sourceAddressPrefixes','sourcePortRanges','destinationAddressPrefix','destinationPortRanges','sourceApplicationSecurityGroups','destinationApplicationSecurityGroups','description')
        if ($properties.priority -isnot [int] -and $properties.priority -isnot [long]) { throw 'Integer ARM rule priority required' }
        foreach ($key in @('sourceAddressPrefixes','sourcePortRanges','destinationPortRanges','sourceApplicationSecurityGroups','destinationApplicationSecurityGroups')) {
            if ($properties.Contains($key) -and ($properties[$key] -isnot [array] -or $properties[$key].Count)) { throw 'Alternate rule selectors forbidden' }
        }
        foreach ($key in @('destinationAddressPrefix','description')) { if ($properties.Contains($key) -and $null -ne $properties[$key] -and $properties[$key] -cne '') { throw 'Unexpected singular selector or description' } }
        foreach ($key in $expected.Keys) {
            if ($key -ceq 'destinationAddressPrefixes') {
                Assert-FoundationSet $properties[$key] $expected[$key]
            } elseif ($key -cin @('direction','access','protocol')) {
                Assert-FoundationText $properties[$key] $expected[$key]
            } else { Assert-FoundationEqual $properties[$key] $expected[$key] }
        }
        if ($Succeeded) { Assert-FoundationText $properties.provisioningState 'Succeeded' }
    }

    function New-ExpansionCosmosNetworkTemplate([hashtable]$Binding, [string]$Scope) {
        $names=Get-ExpansionCosmosNetworkNames $Binding $Binding.selector $Scope
        Assert-FoundationEqual $Binding.names $names
        $rule=@{type='Microsoft.Network/networkSecurityGroups/securityRules';apiVersion='2024-05-01';name=(($names.nsgId -split '/')[-1]+'/'+$names.ruleName);properties=(Get-ExpansionCosmosNetworkRuleProperties $Binding.selector $Binding.addresses)}
        return @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#';contentVersion='1.0.0.0';resources=@($rule)}
    }

    function Assert-ExpansionCosmosNetworkTemplate($Template, [hashtable]$Binding, [string]$Scope) {
        Assert-FoundationEqual $Template (New-ExpansionCosmosNetworkTemplate $Binding $Scope)
    }

    function Assert-ExpansionCosmosNetworkResource([hashtable]$State, $Resource, [string]$Id, [string]$Type, [switch]$Inherited) {
        if ($Resource -isnot [hashtable] -or $Resource.properties -isnot [hashtable]) { throw 'Complete network resource required' }
        Assert-FoundationText $Resource.id $Id
        Assert-FoundationText $Resource.type $Type
        Assert-FoundationText $Resource.properties.provisioningState 'Succeeded'
        if (-not $Inherited -or ($null -ne $Resource.tags -and ($Resource.tags -isnot [hashtable] -or $Resource.tags.Count))) { Assert-FoundationOwned $State $Resource $Id }
    }

    function Get-ExpansionCosmosNetworkRules([string]$NsgId, $Rules, [switch]$Defaults) {
        if ($Rules -isnot [array]) { throw 'Complete NSG rule array required' }
        $childType=if ($Defaults) { 'defaultSecurityRules' } else { 'securityRules' }
        $prefix="$NsgId/$childType/"; $seen=@{}; $priorities=@{}; $snapshot=@()
        foreach ($rule in $Rules) {
            if ($rule -isnot [hashtable] -or $rule.id -isnot [string] -or $rule.id -inotmatch ('^'+[regex]::Escape($prefix)+'[a-zA-Z0-9_.-]+$') -or $seen.ContainsKey($rule.id) -or $rule.properties -isnot [hashtable]) { throw 'Foreign, malformed or duplicate NSG rule' }
            $leaf=($rule.id -split '/')[-1]; $qualified=($NsgId -split '/')[-1]+'/'+$leaf
            if ($rule.name -isnot [string] -or $rule.name -inotin @($leaf,$qualified)) { throw 'NSG rule name and ID disagree' }
            Assert-FoundationText $rule.type "Microsoft.Network/networkSecurityGroups/$childType"
            $priority=$rule.properties.priority; $direction=$rule.properties.direction
            if (($priority -isnot [int] -and $priority -isnot [long]) -or $direction -isnot [string] -or $direction -inotin @('Inbound','Outbound')) { throw 'Typed NSG priority and direction required' }
            if (($Defaults -and ($priority -lt 65000 -or $priority -gt 65500)) -or (-not $Defaults -and ($priority -lt 100 -or $priority -gt 4096))) { throw 'NSG priority outside its range' }
            $priorityKey="$direction/$priority"
            if ($priorities.ContainsKey($priorityKey)) { throw 'NSG priority collision' }
            $seen[$rule.id]=$true; $priorities[$priorityKey]=$true
            $snapshot+=@{id=$rule.id;name=$leaf;type=$rule.type;properties=$rule.properties}
        }
        return ,@($snapshot | Sort-Object id)
    }

    function Get-ExpansionCosmosNetworkBinding([hashtable]$State, [string]$Selector, [hashtable]$DependencyOutput, [hashtable]$Resources, [string]$Scope) {
        $names=Get-ExpansionCosmosNetworkNames $State $Selector $Scope
        Assert-FoundationEqual $DependencyOutput.controlPlaneVerified $true
        Assert-FoundationEqual $DependencyOutput.completeLab $false
        $output=$DependencyOutput.standard
        if ($output -isnot [hashtable]) { throw 'Verified dependency output required' }
        foreach ($spec in @(@('stage','dependencies'),@('projectSelector',$Selector),@('labId',$State.labId),@('ownershipId',$State.ownershipId),@('integrationResourceGroupName',$names.group))) { Assert-FoundationEqual $output[$spec[0]] $spec[1] }
        Assert-FoundationEqual $output.completeLab $false
        Assert-FoundationGuid $output.projectPrincipalId
        $stem="fgl-$($State.labId)"; $caseId=$Selector.Substring(0,1); $code=@{'a-test'='at';'b-dev'='bd';'b-test'='bt'}[$Selector]
        $groupName="rg-$stem-case-$caseId"; $group="/subscriptions/$($State.subscriptionId)/resourceGroups/$groupName"
        $vnetId="$($names.scope)/providers/Microsoft.Network/virtualNetworks/vnet-$stem"
        $subnetId="$vnetId/subnets/snet-case-$caseId-pe"; $agentSubnetId="$vnetId/subnets/snet-agent-$caseId"
        $agentIndex=if ($caseId -ceq 'a') { 0 } else { 1 }
        $agentNsgId="$($names.scope)/providers/Microsoft.Network/networkSecurityGroups/nsg-$stem-agent-$agentIndex"
        foreach ($spec in @(@('resourceGroupName',$groupName),@('resourceGroupId',$group),@('vnetId',$vnetId),@('subnetId',$subnetId))) { Assert-FoundationText $output[$spec[0]] $spec[1] }
        if ($output.cosmos -isnot [hashtable] -or $output.cosmos.name -isnot [string] -or $output.cosmos.name -cnotmatch ('^'+[regex]::Escape("cosmos-$stem-exp-$code-")+'[a-z0-9]{13}$')) { throw 'Cosmos name not bound to the selected dependency' }
        $cosmosName=$output.cosmos.name; $suffix=($cosmosName -split '-')[-1]
        $cosmosId="$group/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosName"
        $hostName="$cosmosName.documents.azure.com"; $endpointId="$group/providers/Microsoft.Network/privateEndpoints/pe-$stem-exp-$Selector-cosmos"
        Assert-FoundationText $output.cosmos.id $cosmosId
        Assert-FoundationEqual $output.cosmos.endpoint "https://${hostName}:443/"
        Assert-FoundationText $output.accountId "$group/providers/Microsoft.CognitiveServices/accounts/aif-$stem-$caseId-$suffix"
        Assert-FoundationText $output.projectId "$($output.accountId)/projects/case-$Selector"
        Assert-FoundationSet $output.privateEndpointIds @('blob','search','cosmos' | ForEach-Object { "$group/providers/Microsoft.Network/privateEndpoints/pe-$stem-exp-$Selector-$_" })
        foreach ($spec in @(@('nsg',$names.nsgId,'Microsoft.Network/networkSecurityGroups'),@('agentNsg',$agentNsgId,'Microsoft.Network/networkSecurityGroups'),@('vnet',$vnetId,'Microsoft.Network/virtualNetworks'),@('subnet',$subnetId,'Microsoft.Network/virtualNetworks/subnets'),@('agentSubnet',$agentSubnetId,'Microsoft.Network/virtualNetworks/subnets'),@('cosmos',$cosmosId,'Microsoft.DocumentDB/databaseAccounts'),@('endpoint',$endpointId,'Microsoft.Network/privateEndpoints'))) {
            Assert-ExpansionCosmosNetworkResource $State $Resources[$spec[0]] $spec[1] $spec[2] -Inherited:($spec[0] -cin @('subnet','agentSubnet'))
        }
        Assert-CosmosNetworkSubnet $Resources.subnet $names.destinationPrefix $names.nsgId
        Assert-CosmosNetworkSubnet $Resources.agentSubnet $names.sourcePrefix $agentNsgId
        Assert-FoundationEqual $Resources.subnet.properties.privateEndpointNetworkPolicies 'NetworkSecurityGroupEnabled'
        $subnets=$Resources.vnet.properties.subnets
        if ($subnets -isnot [array] -or @($subnets.id | Select-Object -Unique).Count -ne $subnets.Count) { throw 'Complete unique VNet subnet evidence required' }
        foreach ($subnet in @($Resources.subnet,$Resources.agentSubnet)) {
            $matching=@($subnets | Where-Object id -IEQ $subnet.id)
            if ($matching.Count -ne 1) { throw 'Subnet missing from owned VNet' }
            foreach ($key in @('addressPrefix','addressPrefixes','networkSecurityGroup','privateEndpointNetworkPolicies')) { Assert-FoundationEqual $matching[0].properties[$key] $subnet.properties[$key] }
        }
        $cosmos=$Resources.cosmos.properties
        Assert-FoundationEqual $cosmos.publicNetworkAccess 'Disabled'
        Assert-FoundationEqual $cosmos.disableLocalAuth $true
        Assert-FoundationEqual $cosmos.documentEndpoint "https://${hostName}:443/"
        if ($cosmos.readLocations -isnot [array] -or $cosmos.readLocations.Count -lt 1 -or $cosmos.readLocations.Count -gt 4 -or $cosmos.writeLocations -isnot [array] -or $cosmos.writeLocations.Count -lt 1 -or $cosmos.writeLocations.Count -gt 4) { throw 'Bounded read and write region evidence required' }
        $regional=@{}; $hosts=@($hostName); $writers=@{}
        foreach ($location in $cosmos.readLocations) {
            if ($location.locationName -isnot [string] -or $location.locationName -cnotmatch '^[A-Za-z][A-Za-z0-9 ]+$') { throw 'Invalid Cosmos region' }
            $region=$location.locationName.ToLowerInvariant().Replace(' ',''); $regionalHost="$cosmosName-$region.documents.azure.com"
            if ($regional.ContainsKey($region)) { throw 'Duplicate Cosmos region' }
            Assert-FoundationEqual $location.documentEndpoint "https://${regionalHost}:443/"
            $regional[$region]=$location.documentEndpoint; $hosts+=$regionalHost
        }
        foreach ($location in $cosmos.writeLocations) {
            if ($location.locationName -isnot [string]) { throw 'Write region name required' }
            $region=$location.locationName.ToLowerInvariant().Replace(' ','')
            if (-not $regional.ContainsKey($region) -or $writers.ContainsKey($region)) { throw 'Duplicate or foreign write region' }
            Assert-FoundationEqual $location.documentEndpoint $regional[$region]
            $writers[$region]=$true
        }
        $endpoint=$Resources.endpoint.properties; $links=$endpoint.privateLinkServiceConnections
        Assert-FoundationText $endpoint.subnet.id $subnetId
        if ($links -isnot [array] -or $links.Count -ne 1 -or @($endpoint.manualPrivateLinkServiceConnections).Where({$null -ne $_}).Count) { throw 'Exactly one automatic PE connection required' }
        $link=$links[0].properties
        Assert-FoundationText $link.privateLinkServiceId $cosmosId
        Assert-FoundationEqual $link.groupIds @('Sql')
        Assert-FoundationEqual $link.privateLinkServiceConnectionState.status 'Approved'
        if ($endpoint.networkInterfaces -isnot [array] -or $endpoint.networkInterfaces.Count -ne 1) { throw 'Exactly one Cosmos PE NIC required' }
        $nicId=$endpoint.networkInterfaces[0].id
        if ($nicId -isnot [string] -or $nicId -inotmatch ('^'+[regex]::Escape("$group/providers/Microsoft.Network/networkInterfaces/")+'[a-zA-Z0-9_.-]+$')) { throw 'Foreign PE NIC scope' }
        Assert-ExpansionCosmosNetworkResource $State $Resources.nic $nicId 'Microsoft.Network/networkInterfaces' -Inherited
        $nic=$Resources.nic.properties
        Assert-FoundationText $nic.privateEndpoint.id $endpointId
        if ($nic.ipConfigurations -isnot [array] -or $nic.ipConfigurations.Count -ne $hosts.Count) { throw 'Exact global and regional NIC coverage required' }
        $addresses=@(); $mapping=@{}
        foreach ($configuration in $nic.ipConfigurations) {
            $properties=$configuration.properties; $connection=$properties.privateLinkConnectionProperties
            Assert-FoundationText $properties.subnet.id $subnetId
            Assert-FoundationEqual $properties.privateIPAddressVersion 'IPv4'
            if ($null -ne $properties.publicIPAddress) { throw 'Public IP forbidden on the Cosmos NIC' }
            Assert-FoundationEqual $connection.groupId 'Sql'
            if ($connection.fqdns -isnot [array] -or $connection.fqdns.Count -ne 1) { throw 'One FQDN per Cosmos IP required' }
            $fqdn=$connection.fqdns[0]
            if ($fqdn -isnot [string] -or $fqdn -cnotin $hosts -or $mapping.ContainsKey($fqdn)) { throw 'Foreign or duplicate Cosmos FQDN' }
            $addresses+=$properties.privateIPAddress; $mapping[$fqdn]=$properties.privateIPAddress
        }
        $null=Get-ExpansionCosmosNetworkRuleProperties $Selector $addresses
        $rules=Get-ExpansionCosmosNetworkRules $names.nsgId $Resources.nsg.properties.securityRules
        foreach ($rule in $rules) { if ($rule.id -ieq $names.ruleId -or $rule.properties.priority -eq $names.priority) { throw 'Expansion rule name or priority already occupied; no adoption' } }
        $original=@($rules | Where-Object id -IEQ "$($names.nsgId)/securityRules/allow-case-a-cosmos-direct")
        if ($original.Count -ne 1 -or $original[0].properties.priority -ne 125) { throw 'Original A-dev rule at priority 125 required' }
        $binding=@{subscriptionId=$State.subscriptionId;ownershipId=$State.ownershipId;labId=$State.labId;selector=$Selector;names=$names;cosmosId=$cosmosId;endpointId=$endpointId;nicId=$nicId;vnetId=$vnetId;subnetId=$subnetId;agentSubnetId=$agentSubnetId;agentNsgId=$agentNsgId;addresses=@($addresses | Sort-Object);fqdnAddresses=$mapping;regions=@($regional.Values | Sort-Object);writeRegions=@($writers.Keys | Sort-Object);otherRules=$rules;endpointDefaultRules=(Get-ExpansionCosmosNetworkRules $names.nsgId $Resources.nsg.properties.defaultSecurityRules -Defaults);agentRules=(Get-ExpansionCosmosNetworkRules $agentNsgId $Resources.agentNsg.properties.securityRules);agentDefaultRules=(Get-ExpansionCosmosNetworkRules $agentNsgId $Resources.agentNsg.properties.defaultSecurityRules -Defaults);ownership=@{nsg=$Resources.nsg.tags;agentNsg=$Resources.agentNsg.tags}}
        return $binding | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    }

    function Assert-ExpansionCosmosNetworkPreserved([hashtable]$Binding, [hashtable]$Nsg, [hashtable]$AgentNsg) {
        $names=Get-ExpansionCosmosNetworkNames $Binding $Binding.selector $Binding.names.scope
        Assert-FoundationEqual $Binding.names $names
        foreach ($spec in @(@('nsg',$Nsg,$names.nsgId),@('agentNsg',$AgentNsg,$Binding.agentNsgId))) {
            Assert-ExpansionCosmosNetworkResource $Binding $spec[1] $spec[2] 'Microsoft.Network/networkSecurityGroups'
            Assert-FoundationEqual $spec[1].tags $Binding.ownership[$spec[0]]
        }
        $rules=Get-ExpansionCosmosNetworkRules $names.nsgId $Nsg.properties.securityRules
        $added=@($rules | Where-Object id -IEQ $names.ruleId)
        if ($added.Count -ne 1) { throw 'Exactly one expansion rule must be present' }
        Assert-ExpansionCosmosNetworkRule $added[0] $Binding -Succeeded
        $other=@($rules | Where-Object id -INE $names.ruleId)
        if (@($other | Where-Object { $_.properties.priority -eq $names.priority }).Count) { throw 'Expansion priority collision' }
        Assert-FoundationEqual $other $Binding.otherRules
        Assert-FoundationEqual (Get-ExpansionCosmosNetworkRules $names.nsgId $Nsg.properties.defaultSecurityRules -Defaults) $Binding.endpointDefaultRules
        Assert-FoundationEqual (Get-ExpansionCosmosNetworkRules $Binding.agentNsgId $AgentNsg.properties.securityRules) $Binding.agentRules
        Assert-FoundationEqual (Get-ExpansionCosmosNetworkRules $Binding.agentNsgId $AgentNsg.properties.defaultSecurityRules -Defaults) $Binding.agentDefaultRules
    }

    Export-ModuleMember -Function *-ExpansionCosmosNetwork*
} | Import-Module