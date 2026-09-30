[CmdletBinding()]
param([string]$StatePath, [ValidateSet('Preview','Deploy','Status')][string]$Action = 'Preview', [switch]$DefinitionsOnly)

function ConvertTo-CosmosNetworkCanonical($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $parts = @(foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { (ConvertTo-Json -InputObject ([string]$key) -Compress) + ':' + (ConvertTo-CosmosNetworkCanonical $Value[$key]) })
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [array]) { return '[' + (@(foreach ($item in $Value) { ConvertTo-CosmosNetworkCanonical $item }) -join ',') + ']' }
    return ConvertTo-Json -InputObject $Value -Depth 100 -Compress
}

function Get-CosmosNetworkHash($Value) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-CosmosNetworkCanonical $Value))))
}

function Assert-CosmosNetworkKeys($Value, [string[]]$Required, [string[]]$Optional = @()) {
    if ($Value -isnot [Collections.IDictionary]) { throw 'Expected an object' }
    foreach ($key in $Required) { if (-not $Value.Contains($key)) { throw 'Required property missing' } }
    foreach ($key in $Value.Keys) { if ($key -cnotin ($Required + $Optional)) { throw 'Unexpected property' } }
}

function Get-CosmosNetworkNames([hashtable]$State) {
    $group = "rg-fgl-$($State.labId)-integration"
    $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/$group"
    $nsg = "$prefix/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-$($State.labId)-endpoints"
    return @{group=$group; name="fgl-$($State.labId)-standard-cosmos-network"; nsgId=$nsg; ruleId="$nsg/securityRules/allow-case-a-cosmos-direct"; deploymentId="$prefix/providers/Microsoft.Resources/deployments/fgl-$($State.labId)-standard-cosmos-network"}
}

function Assert-CosmosNetworkState([hashtable]$State, [string]$SelectedAction) {
    Assert-StandardPrivateState $State
    if ($SelectedAction -cnotin @('Preview','Deploy','Status')) { throw 'Unknown network action' }
    $receipt = $State.standard.cosmosNetwork
    if ($null -ne $receipt) {
        Assert-CosmosNetworkKeys $receipt @('name','group','ruleId','pending','verified','review') @('evidence')
        $names = Get-CosmosNetworkNames $State
        foreach ($key in @('name','group','ruleId')) { if ($receipt[$key] -isnot [string] -or $receipt[$key] -cne $names[$key]) { throw 'Unbound network receipt' } }
        if ($receipt.pending -isnot [bool] -or $receipt.verified -isnot [bool] -or $receipt.pending -eq $receipt.verified -or $receipt.review -isnot [hashtable]) { throw 'Invalid network receipt state' }
        if ($SelectedAction -cne 'Status') { throw 'Tracked network step must use Status; resubmission is forbidden' }
    } elseif ($SelectedAction -ceq 'Status') { throw 'No network submission receipt' }
}

function Assert-CosmosNetworkAddresses($Addresses) {
    if ($Addresses -isnot [array] -or $Addresses.Count -lt 1 -or $Addresses.Count -gt 5 -or @($Addresses | Select-Object -Unique).Count -ne $Addresses.Count) { throw 'Missing, duplicate or excessive Cosmos addresses' }
    foreach ($address in $Addresses) { if ($address -isnot [string] -or $address -cnotmatch '^10\.76\.6\.(?:[4-9]|[12][0-9]|30)$') { throw 'Cosmos address outside usable case-A /27' } }
}

function Get-CosmosNetworkRuleProperties([array]$Addresses) {
    Assert-CosmosNetworkAddresses $Addresses
    return @{priority=125;direction='Inbound';access='Allow';protocol='Tcp';sourceAddressPrefix='10.76.1.0/24';sourcePortRange='*';destinationAddressPrefixes=@($Addresses | Sort-Object | ForEach-Object { "$_/32" });destinationPortRange='*'}
}

function Assert-CosmosNetworkRule($Rule, [hashtable]$Names, [array]$Addresses, [switch]$Succeeded) {
    $qualifiedName = ($(($Names.nsgId -split '/')[-1]) + '/allow-case-a-cosmos-direct')
    if ($Rule -isnot [hashtable] -or $Rule.id -isnot [string] -or $Rule.id -ine $Names.ruleId -or $Rule.name -isnot [string] -or $Rule.name -cnotin @('allow-case-a-cosmos-direct',$qualifiedName) -or $Rule.type -isnot [string] -or $Rule.type -ine 'Microsoft.Network/networkSecurityGroups/securityRules') { throw 'Unexpected security rule identity' }
    $expected = Get-CosmosNetworkRuleProperties $Addresses
    $properties = $Rule.properties
    Assert-CosmosNetworkKeys $properties @($expected.Keys) @('provisioningState','sourceAddressPrefixes','sourcePortRanges','destinationAddressPrefix','destinationPortRanges','sourceApplicationSecurityGroups','destinationApplicationSecurityGroups','description')
    foreach ($key in @('sourceAddressPrefixes','sourcePortRanges','destinationPortRanges','sourceApplicationSecurityGroups','destinationApplicationSecurityGroups')) {
        if ($properties.ContainsKey($key) -and ($properties[$key] -isnot [array] -or $properties[$key].Count)) { throw 'Alternate rule selectors forbidden' }
    }
    foreach ($key in @('destinationAddressPrefix','description')) { if ($properties.ContainsKey($key) -and $null -ne $properties[$key] -and $properties[$key] -cne '') { throw 'Unexpected singular selector or description' } }
    foreach ($key in $expected.Keys) {
        if ($key -eq 'destinationAddressPrefixes') {
            if ($properties[$key] -isnot [array] -or $properties[$key].Count -ne $expected[$key].Count -or @($properties[$key] | Where-Object { $_ -isnot [string] }).Count -or @($properties[$key] | Select-Object -Unique).Count -ne $properties[$key].Count -or @(Compare-Object $properties[$key] $expected[$key]).Count) { throw 'Rule must target exactly all Cosmos /32 addresses' }
        } elseif ((ConvertTo-CosmosNetworkCanonical $properties[$key]) -cne (ConvertTo-CosmosNetworkCanonical $expected[$key])) { throw 'Rule permissions changed' }
    }
    if ($Succeeded -and ($properties.provisioningState -isnot [string] -or $properties.provisioningState -cne 'Succeeded')) { throw 'Rule is not succeeded' }
}

function Assert-CosmosNetworkResource([hashtable]$State, $Resource, [string]$Id, [string]$Type, [switch]$Inherited) {
    if ($Resource -isnot [hashtable] -or $Resource.id -isnot [string] -or $Resource.id -ine $Id -or $Resource.type -isnot [string] -or $Resource.type -ine $Type -or $Resource.properties.provisioningState -isnot [string] -or $Resource.properties.provisioningState -cne 'Succeeded') { throw 'Network resource identity, type or state mismatch' }
    Assert-LabResourceId $State $Id
    if (-not $Inherited -or ($Resource.tags -is [hashtable] -and $Resource.tags.Count)) { Assert-StandardOwned $State $Resource $Id }
}

function Assert-CosmosNetworkSubnet($Subnet, [string]$Prefix, [string]$NsgId) {
    $properties = $Subnet.properties
    $prefixes = @()
    if ($properties.addressPrefix -is [string] -and $properties.addressPrefix) { $prefixes += $properties.addressPrefix }
    if ($properties.ContainsKey('addressPrefixes')) {
        if ($properties.addressPrefixes -isnot [array]) { throw 'Invalid subnet address prefixes' }
        $prefixes += $properties.addressPrefixes
    }
    if ($prefixes.Count -ne 1 -or $prefixes[0] -isnot [string] -or $prefixes[0] -cne $Prefix -or $properties.networkSecurityGroup.id -isnot [string] -or $properties.networkSecurityGroup.id -ine $NsgId) { throw 'Subnet prefix or NSG binding mismatch' }
}

function Get-CosmosNetworkBinding([hashtable]$State, [hashtable]$PrivateBinding, [hashtable]$Resources) {
    $names = Get-CosmosNetworkNames $State
    $targets = @($PrivateBinding.targets | Where-Object service -CEQ 'cosmos')
    if ($targets.Count -ne 1) { throw 'Exactly one Cosmos target required' }
    $target = $targets[0]; $stem = "fgl-$($State.labId)"
    $integration = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-$stem-integration"
    $casePrefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-$stem-case-a"
    $vnetId = "$integration/providers/Microsoft.Network/virtualNetworks/vnet-$stem"
    $subnetId = "$vnetId/subnets/snet-case-a-pe"; $agentSubnetId = "$vnetId/subnets/snet-agent-a"
    $agentNsgId = "$integration/providers/Microsoft.Network/networkSecurityGroups/nsg-$stem-agent-0"
    $cosmosId = "$casePrefix/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-$stem-standard"
    $endpointId = "$casePrefix/providers/Microsoft.Network/privateEndpoints/pe-$stem-standard-cosmos"
    if ($PrivateBinding.vnetId -ine $vnetId -or $PrivateBinding.subnetId -ine $subnetId -or $target.id -ine $cosmosId -or $target.endpointId -ine $endpointId -or $target.name -cne "cosmos-$stem-standard" -or $target.hostName -cne "cosmos-$stem-standard.documents.azure.com") { throw 'Unexpected Cosmos binding target' }
    foreach ($spec in @(@('nsg',$names.nsgId,'Microsoft.Network/networkSecurityGroups'),@('vnet',$vnetId,'Microsoft.Network/virtualNetworks'),@('subnet',$subnetId,'Microsoft.Network/virtualNetworks/subnets'),@('agentSubnet',$agentSubnetId,'Microsoft.Network/virtualNetworks/subnets'),@('agentNsg',$agentNsgId,'Microsoft.Network/networkSecurityGroups'),@('cosmos',$cosmosId,'Microsoft.DocumentDB/databaseAccounts'),@('endpoint',$endpointId,'Microsoft.Network/privateEndpoints'))) {
        Assert-CosmosNetworkResource $State $Resources[$spec[0]] $spec[1] $spec[2] -Inherited:($spec[0] -in @('subnet','agentSubnet'))
    }
    Assert-CosmosNetworkSubnet $Resources.subnet '10.76.6.0/27' $names.nsgId
    Assert-CosmosNetworkSubnet $Resources.agentSubnet '10.76.1.0/24' $agentNsgId
    if ($Resources.subnet.properties.privateEndpointNetworkPolicies -isnot [string] -or $Resources.subnet.properties.privateEndpointNetworkPolicies -cne 'NetworkSecurityGroupEnabled') { throw 'PE subnet NSG policies must be enabled' }
    $vnetSubnets = $Resources.vnet.properties.subnets
    if ($vnetSubnets -isnot [array] -or @($vnetSubnets.id | Select-Object -Unique).Count -ne $vnetSubnets.Count) { throw 'Incomplete VNet subnet evidence' }
    foreach ($subnet in @($Resources.subnet,$Resources.agentSubnet)) {
        $matching = @($vnetSubnets | Where-Object id -IEQ $subnet.id)
        if ($matching.Count -ne 1) { throw 'Subnet not present on the owned VNet' }
        foreach ($key in @('addressPrefix','addressPrefixes','networkSecurityGroup','privateEndpointNetworkPolicies')) { if ((Get-CosmosNetworkHash $matching[0].properties[$key]) -cne (Get-CosmosNetworkHash $subnet.properties[$key])) { throw 'VNet and direct subnet reads disagree' } }
    }
    $cosmos = $Resources.cosmos.properties
    if ($cosmos.publicNetworkAccess -isnot [string] -or $cosmos.publicNetworkAccess -cne 'Disabled' -or $cosmos.disableLocalAuth -isnot [bool] -or -not $cosmos.disableLocalAuth -or $cosmos.documentEndpoint -isnot [string] -or $cosmos.documentEndpoint -cne "https://$($target.hostName):443/") { throw 'Cosmos must remain private and keyless with the expected endpoint' }
    if ($cosmos.readLocations -isnot [array] -or $cosmos.readLocations.Count -lt 1 -or $cosmos.readLocations.Count -gt 4 -or $cosmos.writeLocations -isnot [array] -or -not $cosmos.writeLocations.Count) { throw 'Complete bounded Cosmos region evidence required' }
    $regional = @{}; $hosts = @($target.hostName)
    foreach ($location in $cosmos.readLocations) {
        if ($location.locationName -isnot [string] -or $location.locationName -cnotmatch '^[A-Za-z][A-Za-z0-9 ]+$') { throw 'Invalid Cosmos location' }
        $region = $location.locationName.ToLowerInvariant().Replace(' ','')
        $hostName = "$($target.name)-$region.documents.azure.com"
        if ($regional.ContainsKey($region) -or $location.documentEndpoint -isnot [string] -or $location.documentEndpoint -cne "https://${hostName}:443/") { throw 'Duplicate or foreign Cosmos regional endpoint' }
        $regional[$region] = $location.documentEndpoint; $hosts += $hostName
    }
    $writers = @{}
    foreach ($location in $cosmos.writeLocations) {
        if ($location.locationName -isnot [string]) { throw 'Missing write region' }
        $region = $location.locationName.ToLowerInvariant().Replace(' ','')
        if (-not $regional.ContainsKey($region) -or $writers.ContainsKey($region) -or $location.documentEndpoint -isnot [string] -or $location.documentEndpoint -cne $regional[$region]) { throw 'Write region not bound to a read region' }
        $writers[$region] = $true
    }
    $endpoint = $Resources.endpoint.properties; $links = $endpoint.privateLinkServiceConnections
    if ($endpoint.subnet.id -isnot [string] -or $endpoint.subnet.id -ine $subnetId -or $links -isnot [array] -or $links.Count -ne 1 -or @($endpoint.manualPrivateLinkServiceConnections).Where({ $null -ne $_ }).Count) { throw 'PE subnet or connection coverage mismatch' }
    $link = $links[0].properties
    if ($link.privateLinkServiceId -isnot [string] -or $link.privateLinkServiceId -ine $cosmosId -or $link.groupIds -isnot [array] -or $link.groupIds.Count -ne 1 -or $link.groupIds[0] -isnot [string] -or $link.groupIds[0] -cne 'Sql' -or $link.privateLinkServiceConnectionState.status -isnot [string] -or $link.privateLinkServiceConnectionState.status -cne 'Approved') { throw 'PE must have one approved Sql connection to the owned Cosmos resource' }
    if ($endpoint.networkInterfaces -isnot [array] -or $endpoint.networkInterfaces.Count -ne 1) { throw 'Exactly one PE NIC required' }
    $nicId = $endpoint.networkInterfaces[0].id
    if ($nicId -isnot [string] -or $nicId -inotmatch ('^' + [regex]::Escape("$casePrefix/providers/Microsoft.Network/networkInterfaces/") + '[a-zA-Z0-9_.-]+$')) { throw 'Foreign NIC scope' }
    Assert-CosmosNetworkResource $State $Resources.nic $nicId 'Microsoft.Network/networkInterfaces' -Inherited
    $nic = $Resources.nic.properties
    if ($nic.privateEndpoint.id -isnot [string] -or $nic.privateEndpoint.id -ine $endpointId -or $nic.ipConfigurations -isnot [array] -or $nic.ipConfigurations.Count -ne $hosts.Count) { throw 'NIC parent or global/regional address coverage mismatch' }
    $addresses = @(); $mapping = @{}
    foreach ($configuration in $nic.ipConfigurations) {
        $properties = $configuration.properties; $connection = $properties.privateLinkConnectionProperties
        if ($properties.subnet.id -isnot [string] -or $properties.subnet.id -ine $subnetId -or $properties.privateIPAddressVersion -cne 'IPv4' -or $properties.publicIPAddress -or $connection.groupId -isnot [string] -or $connection.groupId -cne 'Sql' -or $connection.fqdns -isnot [array] -or $connection.fqdns.Count -ne 1) { throw 'NIC subnet, protocol or FQDN mapping mismatch' }
        $hostName = $connection.fqdns[0]
        if ($hostName -isnot [string] -or $hostName -cnotin $hosts -or $mapping.ContainsKey($hostName)) { throw 'Foreign or duplicate Cosmos FQDN mapping' }
        $addresses += $properties.privateIPAddress; $mapping[$hostName] = $properties.privateIPAddress
    }
    Assert-CosmosNetworkAddresses $addresses
    $otherRules = @(); $actualRule = $null; $seen = @{}
    foreach ($nsg in @($Resources.nsg,$Resources.agentNsg)) {
        foreach ($key in @('securityRules','defaultSecurityRules')) { if ($nsg.properties[$key] -isnot [array]) { throw 'Incomplete NSG rules' } }
    }
    foreach ($rule in $Resources.nsg.properties.securityRules) {
        if ($rule.id -isnot [string] -or $rule.id -inotmatch ('^' + [regex]::Escape($names.nsgId) + '/securityRules/[^/]+$') -or $seen.ContainsKey($rule.id) -or ($rule.properties.priority -isnot [int] -and $rule.properties.priority -isnot [long])) { throw 'Malformed or duplicate NSG rule' }
        $seen[$rule.id] = $true
        if ($rule.id -ieq $names.ruleId) {
            if ($State.standard.cosmosNetwork -isnot [hashtable]) { throw 'Existing untracked rule must not be adopted' }
            Assert-CosmosNetworkState $State 'Status'
            Assert-CosmosNetworkRule $rule $names $addresses -Succeeded
            $actualRule = $rule
        } else {
            if ($rule.properties.priority -eq 125) { throw 'Priority 125 is occupied' }
            $otherRules += @{id=$rule.id;properties=$rule.properties}
        }
    }
    $binding = @{names=$names;cosmosId=$cosmosId;endpointId=$endpointId;nicId=$nicId;vnetId=$vnetId;subnetId=$subnetId;agentSubnetId=$agentSubnetId;agentNsgId=$agentNsgId;addresses=@($addresses | Sort-Object);fqdnAddresses=$mapping;otherRules=@($otherRules | Sort-Object id);agentRules=@($Resources.agentNsg.properties.securityRules | Sort-Object id | ForEach-Object { @{id=$_.id;properties=$_.properties} });endpointDefaultRules=@($Resources.nsg.properties.defaultSecurityRules | Sort-Object id | ForEach-Object { @{id=$_.id;properties=$_.properties} });agentDefaultRules=@($Resources.agentNsg.properties.defaultSecurityRules | Sort-Object id | ForEach-Object { @{id=$_.id;properties=$_.properties} });ownership=@{};regions=@($regional.Values | Sort-Object);writeRegions=@($writers.Keys | Sort-Object)}
    foreach ($key in @('nsg','agentNsg','vnet','cosmos','endpoint')) { $binding.ownership[$key] = $Resources[$key].tags }
    if ($actualRule -and ((Get-CosmosNetworkHash $binding) -cne $State.standard.cosmosNetwork.review.bindingHash -or (Get-CosmosNetworkHash $State.standard.cosmosNetwork.review.binding) -cne $State.standard.cosmosNetwork.review.bindingHash)) { throw 'Existing rule does not match its tracked binding receipt' }
    return @{binding=$binding;rule=$actualRule}
}

function Get-CosmosNetworkLive([hashtable]$State) {
    Assert-StandardGroups $State @(Confirm-LabRunContext $State)
    $lab = Get-Content -LiteralPath (Join-Path $State.runDirectory 'outputs.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $outputs = Get-Content -LiteralPath (Join-Path $State.runDirectory 'standard-outputs.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $private = Get-StandardPrivateBinding $State $lab $outputs
    $target = @($private.targets | Where-Object service -CEQ 'cosmos')[0]; $names = Get-CosmosNetworkNames $State
    $resources = @{}
    foreach ($spec in @(@('nsg',$names.nsgId),@('vnet',$private.vnetId),@('subnet',$private.subnetId),@('agentSubnet',"$($private.vnetId)/subnets/snet-agent-a"),@('agentNsg',"/subscriptions/$($State.subscriptionId)/resourceGroups/$($names.group)/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-$($State.labId)-agent-0"),@('cosmos',$target.id),@('endpoint',$target.endpointId))) {
        $api = if ($spec[0] -eq 'cosmos') { '2024-11-15' } else { '2024-05-01' }
        $resources[$spec[0]] = Read-StandardArm $State $spec[1] $api "cosmos-$($spec[0])"
    }
    $nics = $resources.endpoint.properties.networkInterfaces
    if ($nics -isnot [array] -or $nics.Count -ne 1 -or $nics[0].id -isnot [string]) { throw 'Incomplete PE NIC reference' }
    $nicPrefix = ($target.id -split '/providers/')[0] + '/providers/Microsoft.Network/networkInterfaces/'
    if ($nics[0].id -inotmatch ('^' + [regex]::Escape($nicPrefix) + '[a-zA-Z0-9_.-]+$')) { throw 'Foreign PE NIC reference' }
    $resources.nic = Read-StandardArm $State $nics[0].id '2024-05-01' 'cosmos-nic'
    return Get-CosmosNetworkBinding $State $private $resources
}

function Assert-CosmosNetworkTemplate([hashtable]$Template) {
    Assert-CosmosNetworkKeys $Template @('$schema','contentVersion','parameters','variables','resources','outputs') @('metadata','languageVersion')
    if ($Template.'$schema' -cne 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#' -or $Template.contentVersion -cne '1.0.0.0') { throw 'Group template required' }
    Assert-CosmosNetworkKeys $Template.parameters @('labId','cosmosPrivateAddresses')
    foreach ($spec in @(@('labId','string',6,12),@('cosmosPrivateAddresses','array',1,5))) {
        $parameter = $Template.parameters[$spec[0]]
        Assert-CosmosNetworkKeys $parameter @('type','minLength','maxLength') @('metadata')
        if ($parameter.type -isnot [string] -or $parameter.type -cne $spec[1] -or (ConvertTo-CosmosNetworkCanonical $parameter.minLength) -cne ([string]$spec[2]) -or (ConvertTo-CosmosNetworkCanonical $parameter.maxLength) -cne ([string]$spec[3])) { throw 'Unexpected parameter contract' }
    }
    Assert-CosmosNetworkKeys $Template.variables @('endpointNsgName')
    if ($Template.variables.endpointNsgName -isnot [string] -or $Template.variables.endpointNsgName -cne "[format('nsg-fgl-{0}-endpoints', parameters('labId'))]") { throw 'NSG name changed' }
    $resources = @()
    if ($Template.resources -is [Collections.IDictionary]) { $resources = @($Template.resources.Values) } elseif ($Template.resources -is [array]) { $resources = $Template.resources } else { throw 'Invalid resource collection' }
    $children = @()
    foreach ($resource in $resources) {
        if ($resource.Contains('existing')) {
            Assert-CosmosNetworkKeys $resource @('type','apiVersion','name','existing')
            if ($resource.existing -isnot [bool] -or -not $resource.existing -or $resource.type -cne 'Microsoft.Network/networkSecurityGroups' -or $resource.apiVersion -cne '2024-05-01' -or $resource.name -isnot [string] -or $resource.name -cne "[variables('endpointNsgName')]") { throw 'Unexpected existing resource' }
        } else { $children += $resource }
    }
    if ($children.Count -ne 1 -or $resources.Count -gt 2) { throw 'Exactly one deployed child rule required' }
    $rule = $children[0]; Assert-CosmosNetworkKeys $rule @('type','apiVersion','name','properties')
    $allowedNames = @("[format('{0}/{1}', variables('endpointNsgName'), 'allow-case-a-cosmos-direct')]", "[format('{0}/allow-case-a-cosmos-direct', variables('endpointNsgName'))]")
    if ($rule.type -isnot [string] -or $rule.type -cne 'Microsoft.Network/networkSecurityGroups/securityRules' -or $rule.apiVersion -cne '2024-05-01' -or $rule.name -isnot [string] -or $rule.name -cnotin $allowedNames) { throw 'Template can deploy only the intended child' }
    $expected = Get-CosmosNetworkRuleProperties @('10.76.6.4')
    $expected.destinationAddressPrefixes = "[parameters('cosmosPrivateAddresses')]"
    if ((Get-CosmosNetworkHash $rule.properties) -cne (Get-CosmosNetworkHash $expected)) { throw 'Compiled rule permissions changed' }
    Assert-CosmosNetworkKeys $Template.outputs @('ruleId')
    Assert-CosmosNetworkKeys $Template.outputs.ruleId @('type','value')
    if ($Template.outputs.ruleId.type -cne 'string' -or $Template.outputs.ruleId.value -isnot [string] -or $Template.outputs.ruleId.value -cne "[resourceId('Microsoft.Network/networkSecurityGroups/securityRules', variables('endpointNsgName'), 'allow-case-a-cosmos-direct')]") { throw 'Unexpected rule output' }
}

function Assert-CosmosNetworkWhatIf([hashtable]$State, [hashtable]$Binding, [hashtable]$Result) {
    if ($Result.status -isnot [string] -or $Result.status -cne 'Succeeded' -or $Result.changes -isnot [array] -or -not $Result.changes.Count) { throw 'Complete successful what-if required' }
    $seen = @{}; $count = 0
    foreach ($change in $Result.changes) {
        $id = $change.resourceId
        if ($id -isnot [string] -or $seen.ContainsKey($id) -or $change.changeType -isnot [string]) { throw 'Duplicate or malformed what-if change' }
        Assert-LabResourceId $State $id; $seen[$id] = $true
        if ($change.changeType -ceq 'Ignore') {
            if ($id -ieq $Binding.names.ruleId -or $change.before -isnot [hashtable] -or $change.after -isnot [hashtable] -or $change.before.id -isnot [string] -or $change.before.id -ine $id -or @($change.delta).Where({ $null -ne $_ }).Count -or (Get-CosmosNetworkHash $change.before) -cne (Get-CosmosNetworkHash $change.after)) { throw 'Ignore must prove unchanged existing state' }
            continue
        }
        if ($id -ine $Binding.names.ruleId -or $change.changeType -cnotin @('Create','NoChange') -or @($change.delta).Where({ $null -ne $_ }).Count) { throw 'Only exact child Create or NoChange allowed' }
        Assert-CosmosNetworkRule $change.after $Binding.names $Binding.addresses
        if ($change.changeType -ceq 'Create') {
            if ($change.before -or $State.standard.cosmosNetwork) { throw 'Create cannot overwrite or replay a tracked rule' }
        } else {
            if (-not $State.standard.cosmosNetwork) { throw 'Untracked NoChange rule cannot be adopted' }
            Assert-CosmosNetworkRule $change.before $Binding.names $Binding.addresses -Succeeded
        }
        $count++
    }
    if ($count -ne 1) { throw 'Expanded child rule missing' }
}

function Get-CosmosNetworkPaths([hashtable]$State) {
    $paths = @{}
    foreach ($key in @('template','parameters','review','whatif','evidence')) { $paths[$key] = Assert-ExternalLabPath (Join-Path $State.runDirectory "standard-cosmos-network.$key.json") }
    return $paths
}

function Confirm-CosmosNetworkDeploymentAbsent([hashtable]$State) {
    $names = Get-CosmosNetworkNames $State
    $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/$($names.group)/providers/Microsoft.Resources/deployments"
    $deployments = @(Read-StandardArm $State $prefix '2022-09-01' 'cosmos-deployments' -List)
    $seen = @{}
    foreach ($deployment in $deployments) {
        if ($deployment.name -isnot [string] -or -not $deployment.name -or $deployment.id -isnot [string] -or $deployment.id -ine "$prefix/$($deployment.name)" -or $seen.ContainsKey($deployment.id)) { throw 'Malformed or duplicate deployment list evidence' }
        $seen[$deployment.id] = $true
        if ($deployment.name -ieq $names.name -or $deployment.id -ieq $names.deploymentId) { throw 'Existing untracked network deployment cannot be adopted' }
    }
}

function Assert-CosmosNetworkReview([hashtable]$State, [hashtable]$Review, [hashtable]$Binding, [hashtable]$Paths, [string]$SourcePath, [switch]$Submitted) {
    Assert-CosmosNetworkKeys $Review @('checkedAt','templateHash','parametersHash','sourceHash','whatifHash','bindingHash','binding','stateHash')
    $checkedAt = if ($Review.checkedAt -is [datetime]) { [DateTimeOffset]$Review.checkedAt } else { [DateTimeOffset]::Parse([string]$Review.checkedAt) }
    $age = [DateTimeOffset]::UtcNow - $checkedAt
    if ($age -lt [TimeSpan]::Zero -or (-not $Submitted -and $age -gt [TimeSpan]::FromHours(1))) { throw 'Preview stale or future dated' }
    foreach ($key in @('template','parameters','whatif')) { if ((Get-FileHash -LiteralPath $Paths[$key] -Algorithm SHA256).Hash -cne $Review["${key}Hash"]) { throw 'Reviewed artifact changed' } }
    if ((Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash -cne $Review.sourceHash -or (Get-StandardPrivateStamp $State) -cne $Review.stateHash -or (Get-CosmosNetworkHash $Binding) -cne $Review.bindingHash -or (Get-CosmosNetworkHash $Review.binding) -cne $Review.bindingHash) { throw 'Reviewed source, state or live binding changed' }
    $template = Get-Content -LiteralPath $Paths.template -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-CosmosNetworkTemplate $template
    $parameters = Get-Content -LiteralPath $Paths.parameters -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $expected = @{labId=@{value=$State.labId};cosmosPrivateAddresses=@{value=@($Binding.addresses | ForEach-Object { "$_/32" })}}
    Assert-CosmosNetworkKeys $parameters @('$schema','contentVersion','parameters')
    if ($parameters.'$schema' -cne 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#' -or $parameters.contentVersion -cne '1.0.0.0' -or (Get-CosmosNetworkHash $parameters.parameters) -cne (Get-CosmosNetworkHash $expected)) { throw 'Parameters not bound to the verified addresses' }
}

function Invoke-StandardCosmosNetwork([string]$Path, [string]$SelectedAction) {
    $state = Read-LabRun $Path; Assert-CosmosNetworkState $state $SelectedAction
    $names = Get-CosmosNetworkNames $state; $paths = Get-CosmosNetworkPaths $state
    $source = Join-Path $PSScriptRoot '../infra/modules/standard-cosmos-network.bicep'
    $stateHash = Get-StandardPrivateStamp $state
    Assert-StandardGroups $state @(Confirm-LabRunContext $state)
    if ($SelectedAction -ceq 'Status') {
        $deployment = Invoke-LabAz $state @('deployment','group','show','--resource-group',$names.group,'--name',$names.name) 'cosmos-network-status'
        if ($deployment.id -isnot [string] -or $deployment.id -ine $names.deploymentId -or $deployment.name -cne $names.name -or $deployment.properties.mode -cne 'Incremental' -or $deployment.properties.provisioningState -isnot [string]) { throw 'Network deployment identity mismatch' }
        $status = $deployment.properties.provisioningState
        if ($status -cin @('Failed','Canceled')) { throw 'Network deployment failed or canceled; receipt retained, no resubmission or rollback' }
        if ($status -cne 'Succeeded') {
            if ($status -cnotin @('Accepted','Running','Creating','Updating')) { throw 'Unknown network deployment status' }
            Write-Output 'Network deployment still active; use Status again.'; return
        }
        Confirm-StandardIdle $state
        $live = Get-CosmosNetworkLive $state
        $review = $state.standard.cosmosNetwork.review
        Assert-CosmosNetworkReview $state $review $live.binding $paths $source -Submitted
        if ($deployment.properties.outputs.ruleId.value -isnot [string] -or $deployment.properties.outputs.ruleId.value -ine $names.ruleId) { throw 'Network deployment output mismatch' }
        Assert-CosmosNetworkRule $live.rule $names $live.binding.addresses -Succeeded
        $fresh = Read-LabRun $Path; Assert-CosmosNetworkState $fresh 'Status'
        if ((Get-StandardPrivateStamp $fresh) -cne $stateHash -or (Get-CosmosNetworkHash $fresh.standard.cosmosNetwork) -cne (Get-CosmosNetworkHash $state.standard.cosmosNetwork)) { throw 'State changed during network verification' }
        $evidence = @{verifiedAt=[DateTimeOffset]::UtcNow.ToString('o');deploymentId=$names.deploymentId;binding=$live.binding;rule=$live.rule;review=$review;controlPlaneVerified=$true;agentInferenceVerified=$false}
        Write-StandardJson $paths.evidence $evidence
        $fresh.standard.cosmosNetwork.pending=$false; $fresh.standard.cosmosNetwork.verified=$true
        $fresh.standard.cosmosNetwork.evidence=@{path=$paths.evidence;sha256=(Get-FileHash -LiteralPath $paths.evidence -Algorithm SHA256).Hash;verifiedAt=$evidence.verifiedAt}
        Save-LabRun $fresh $Path
        Write-Output 'Cosmos Direct network rule verified. Agent inference remains a separate check.'; return
    }
    Confirm-StandardIdle $state
    Confirm-CosmosNetworkDeploymentAbsent $state
    $live = Get-CosmosNetworkLive $state; $binding = $live.binding
    $common = @('--resource-group',$names.group,'--name',$names.name,'--mode','Incremental','--template-file',$paths.template,'--parameters',"@$($paths.parameters)")
    if ($SelectedAction -ceq 'Preview') {
        & $state.bicepExecutable build $source --outfile $paths.template *> (Assert-ExternalLabPath (Join-Path $state.runDirectory 'standard-cosmos-network.build.txt'))
        if ($LASTEXITCODE -ne 0) { throw 'Local Bicep compilation failed; inspect the private build log' }
        Assert-CosmosNetworkTemplate (Get-Content -LiteralPath $paths.template -Raw | ConvertFrom-Json -AsHashtable -Depth 100)
        Write-StandardJson $paths.parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=@{labId=@{value=$state.labId};cosmosPrivateAddresses=@{value=@($binding.addresses | ForEach-Object { "$_/32" })}}}
    } else {
        $review = Get-Content -LiteralPath $paths.review -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        Assert-CosmosNetworkReview $state $review $binding $paths $source
    }
    $validation = Invoke-LabAz $state (@('deployment','group','validate') + $common) 'cosmos-network-validate'
    if ($validation.error -or $validation.properties.provisioningState -cne 'Succeeded') { throw 'ARM validation did not succeed' }
    $whatIf = Invoke-LabAz $state (@('deployment','group','what-if','--no-pretty-print') + $common) 'cosmos-network-whatif'
    Assert-CosmosNetworkWhatIf $state $binding $whatIf
    $fresh = Read-LabRun $Path; Assert-CosmosNetworkState $fresh $SelectedAction
    if ((Get-StandardPrivateStamp $fresh) -cne $stateHash) { throw 'State or dependency outputs changed' }
    $freshLive = Get-CosmosNetworkLive $fresh
    if ((Get-CosmosNetworkHash $freshLive.binding) -cne (Get-CosmosNetworkHash $binding)) { throw 'Network binding changed during review' }
    Confirm-StandardIdle $fresh
    Confirm-CosmosNetworkDeploymentAbsent $fresh
    if ($SelectedAction -ceq 'Preview') {
        Write-StandardJson $paths.whatif $whatIf
        $review = @{checkedAt=[DateTimeOffset]::UtcNow.ToString('o');templateHash=(Get-FileHash -LiteralPath $paths.template -Algorithm SHA256).Hash;parametersHash=(Get-FileHash -LiteralPath $paths.parameters -Algorithm SHA256).Hash;sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash;whatifHash=(Get-FileHash -LiteralPath $paths.whatif -Algorithm SHA256).Hash;bindingHash=(Get-CosmosNetworkHash $binding);binding=$binding;stateHash=$stateHash}
        Write-StandardJson $paths.review $review
        Write-Output 'Cosmos Direct network preview passed; private artifacts and binding hashed.'; return
    }
    Assert-CosmosNetworkReview $fresh $review $freshLive.binding $paths $source
    $diskReview = Get-Content -LiteralPath $paths.review -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    if ((Get-CosmosNetworkHash $diskReview) -cne (Get-CosmosNetworkHash $review)) { throw 'Review changed before submission' }
    $latest = Read-LabRun $Path; Assert-CosmosNetworkState $latest 'Deploy'
    Assert-CosmosNetworkReview $latest $review $freshLive.binding $paths $source
    $latest.standard.cosmosNetwork=@{name=$names.name;group=$names.group;ruleId=$names.ruleId;pending=$true;verified=$false;review=$review}
    Save-LabRun $latest $Path
    $null = Invoke-LabAz $latest (@('deployment','group','create') + $common + @('--no-wait')) 'cosmos-network-start'
    Write-Output 'Cosmos Direct network deployment submitted; use Status. No rollback or delete performed.'
}

if ($DefinitionsOnly) { return }
$networkStatePath = $StatePath; $networkAction = $Action
$ErrorActionPreference = 'Stop'
try {
    if (-not $networkStatePath) { throw 'StatePath is required' }
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
    . (Join-Path $PSScriptRoot 'Invoke-StandardStage.ps1') -DefinitionsOnly
    . (Join-Path $PSScriptRoot 'Test-StandardPrivate.ps1') -DefinitionsOnly
    Invoke-StandardCosmosNetwork $networkStatePath $networkAction
} catch { throw 'Cosmos Direct network step stopped. Review private state, review artifacts and command logs; no rollback or resubmission was performed.' }