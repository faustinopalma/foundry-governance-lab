[CmdletBinding()]
param()
$timer=[Diagnostics.Stopwatch]::StartNew(); $ErrorActionPreference='Stop'
try {
    . (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionStandard.ps1') -DefinitionsOnly
    . (Join-Path $PSScriptRoot '../scripts/Test-ExpansionPrivate.ps1') -DefinitionsOnly
    $checks=@{count=0}
    function Check([bool]$Value) { if (-not $Value) { throw 'Private expansion assertion failed' }; $checks.count++ }
    function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed }
    $fixture=@{subscriptionId='11111111-1111-4111-8111-111111111111';labId='sample01';ownershipId='33333333-3333-4333-8333-333333333333'}
    $prefix="/subscriptions/$($fixture.subscriptionId)/resourceGroups/rg-fgl-sample01"
    $lab=@{runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner"}
    foreach ($selector in @('a-test','b-dev','b-test')) {
        $caseId=$selector.Substring(0,1)
        $binding=@{project=$selector;group="$prefix-case-$caseId";new=@{};specs=@{};output=@{subnetId="$prefix-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01/subnets/snet-case-$caseId-pe";vnetId="$prefix-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01";dnsZoneIds=@{}}}
        foreach ($spec in @(@('storage','blob','Microsoft.Storage/storageAccounts','blob.core.windows.net'),@('search','search','Microsoft.Search/searchServices','search.windows.net'),@('cosmos','cosmos','Microsoft.DocumentDB/databaseAccounts','documents.azure.com'))) {
            $id="$($binding.group)/providers/$($spec[2])/synthetic-$($spec[0])"
            $endpoint="$($binding.group)/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-exp-$selector-$($spec[1])"
            $binding.output[$spec[0]]=@{id=$id;name="synthetic-$($spec[0])"}; $binding.new[$id]=$spec[0]; $binding.new[$endpoint]='endpoint'
            $binding.output.dnsZoneIds[$spec[1]]="$prefix-integration/providers/Microsoft.Network/privateDnsZones/privatelink.$($spec[3])"
        }
        $network=Get-ExpansionPrivateBinding $fixture $lab $binding
        Check ($network.targets.Count -eq 3 -and $network.runnerId -ceq $lab.runner)
        $octet=if ($caseId -ceq 'a') { 6 } else { 7 }
        Check ($network.addressPrefix -ceq "10.76.$octet.")
        $addresses=@{}; $probe=@{checks=@()}
        foreach ($index in 0..2) { $hostName=$network.targets[$index].hostName; $address="10.76.$octet.$($index+4)"; $addresses[$hostName]=@($address); $probe.checks+=@{hostName=$hostName;addresses=@($address);tls443=$true} }
        Assert-ExpansionPrivateProbe $network $probe $addresses; Check $true
        foreach ($address in @('10.76.5.4',"10.76.$octet.0","10.76.$octet.3","10.76.$octet.31","10.76.$octet.32",'127.0.0.1','::1','10.76.6.004',42)) { Reject { Assert-ExpansionPrivateAddress $network $address } }
        foreach ($mutation in @({param($value) $value.checks[0].tls443=$false},{param($value) $value.checks[0].tls443='true'},{param($value) $value.checks[0].addresses=@()},{param($value) $value.checks[0].addresses+= $value.checks[0].addresses[0]},{param($value) $value.checks[0].addresses=@('10.76.5.4')},{param($value) $value.checks[0].hostName=$value.checks[1].hostName},{param($value) $value.checks=@($value.checks[0])})) {
            $bad=Read-ExpansionStandardCopy $probe; & $mutation $bad; Reject { Assert-ExpansionPrivateProbe $network $bad $addresses }
        }
        $responses=@{}
        $tags=@{'fgl-owner'=$fixture.ownershipId;'fgl-lab'=$fixture.labId;purpose='synthetic-governance-lab'}
        foreach ($target in $network.targets) {
            $nicId="$($binding.group)/providers/Microsoft.Network/networkInterfaces/nic-$($target.service)"
            $responses[$target.id]=@{id=$target.id;properties=@{}}
            $responses[$target.endpointId]=@{id=$target.endpointId;properties=@{networkInterfaces=@(@{id=$nicId})}}
            $binding.specs[$target.id]=@{api='test'}; $binding.specs[$target.endpointId]=@{api='test'}
            $configuration=@{properties=@{subnet=@{id=$network.subnetId};privateIPAddress=$addresses[$target.hostName][0];privateLinkConnectionProperties=@{fqdns=@($target.hostName);groupId=$target.groupId}}}
            $responses[$nicId]=@{id=$nicId;properties=@{provisioningState='Succeeded';privateEndpoint=@{id=$target.endpointId};ipConfigurations=@($configuration)}}
            if ($target.service -ceq 'cosmos') { $regional=Read-ExpansionStandardCopy $configuration; $regional.properties.privateIPAddress="10.76.$octet.10"; $regional.properties.privateLinkConnectionProperties.fqdns=@('regional.example'); $responses[$nicId].properties.ipConfigurations+= $regional }
            $responses["$($target.endpointId)/privateDnsZoneGroups"]=@(@{id="$($target.endpointId)/privateDnsZoneGroups/default"})
            $responses[$target.zoneId]=@{id=$target.zoneId;tags=$tags}
            $linkName=if ($target.service -ceq 'storage') { 'lab-only' } else { 'standard-lab-only' }
            $responses["$($target.zoneId)/virtualNetworkLinks"]=@(@{id="$($target.zoneId)/virtualNetworkLinks/$linkName";properties=@{provisioningState='Succeeded';virtualNetwork=@{id=$network.vnetId};registrationEnabled=$false}})
        }
        & {
            function Read-ExpansionPrivateArm { param($State,$Id,$Api,[switch]$List); if (-not $responses.ContainsKey($Id)) { throw 'Unexpected target' }; return $responses[$Id] }
            function Assert-ExpansionStandardResource { param($State,$Binding,$Resource,$Id,[switch]$Live); Check ($Live -and $Resource.id -ceq $Id) }
            $actual=Get-ExpansionPrivateAddresses $fixture $binding $network
            Assert-ExpansionPrivateProbe $network $probe $actual; Check $true
            $nicId="$($binding.group)/providers/Microsoft.Network/networkInterfaces/nic-storage"
            $saved=Read-ExpansionStandardCopy $responses[$nicId]
            foreach ($mutation in @({param($value) $value.properties.privateEndpoint.id+='-foreign'},{param($value) $value.properties.ipConfigurations[0].properties.subnet.id+='-foreign'},{param($value) $value.properties.ipConfigurations[0].properties.privateIPAddress='10.76.5.4'},{param($value) $value.properties.ipConfigurations[0].properties.privateLinkConnectionProperties.fqdns=@('other.example')},{param($value) $value.properties.ipConfigurations[0].properties.privateLinkConnectionProperties.groupId='wrong'},{param($value) $value.properties.ipConfigurations+= $value.properties.ipConfigurations[0]})) {
                $responses[$nicId]=Read-ExpansionStandardCopy $saved; & $mutation $responses[$nicId]; Reject { Get-ExpansionPrivateAddresses $fixture $binding $network }
            }
        }
    }
    & {
        function Invoke-ExpansionPrivateCommand { return @{value=@();nextLink='more'} }
        Reject { Read-ExpansionPrivateArm $fixture "$prefix-case-a/providers/test/test" 'test' -List }
        Reject { Read-ExpansionPrivateArm $fixture '/subscriptions/foreign/resourceGroups/test' 'test' }
    }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/Test-ExpansionPrivate.ps1'),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0)
    $forbidden=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cin @('Save-LabRun','Invoke-StandardPrivateVerification')},$true))
    Check ($forbidden.Count -eq 0)
    Write-Output "PASS: $($checks.count) expansion private checks."
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }