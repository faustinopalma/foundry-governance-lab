[CmdletBinding()]
param([string]$StatePath, [ValidateSet('a-test','b-dev','b-test')][string]$Project, [string]$BicepExecutable='bicep', [switch]$DefinitionsOnly)

function Get-ExpansionPrivateBinding([hashtable]$State, [hashtable]$Lab, [hashtable]$Binding) {
    $selector=$Binding.project
    if ($selector -cnotin @('a-test','b-dev','b-test')) { throw 'Expansion project required' }
    $caseId=$selector.Substring(0,1)
    $prefix="/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)"
    $runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-$($State.labId)-runner"
    Assert-FoundationText $Lab.runner $runner
    $targets=@()
    foreach ($spec in @(@('storage','blob','blob.core.windows.net','blob'),@('search','search','search.windows.net','searchService'),@('cosmos','cosmos','documents.azure.com','Sql'))) {
        $service=$spec[0]; $resource=$Binding.output[$service]
        $endpoint="$prefix-case-$caseId/providers/Microsoft.Network/privateEndpoints/pe-fgl-$($State.labId)-exp-$selector-$($spec[1])"
        Assert-FoundationEqual $Binding.new[$resource.id] $service
        Assert-FoundationEqual $Binding.new[$endpoint] 'endpoint'
        $targets+=@{service=$service;id=$resource.id;hostName="$($resource.name).$($spec[2])";endpointId=$endpoint;groupId=$spec[3];zoneId=$Binding.output.dnsZoneIds[$spec[1]]}
    }
    return @{runnerId=$runner;targets=$targets;subnetId=$Binding.output.subnetId;vnetId=$Binding.output.vnetId;addressPrefix=$(if ($caseId -ceq 'a') { '10.76.6.' } else { '10.76.7.' })}
}

function Assert-ExpansionPrivateAddress([hashtable]$Network, $Address) {
    $parsed=$null
    if ($Address -isnot [string] -or -not [Net.IPAddress]::TryParse($Address,[ref]$parsed) -or $parsed.ToString() -cne $Address) { throw 'Canonical IPv4 required' }
    if ($Network.addressPrefix -cnotin @('10.76.6.','10.76.7.') -or -not $Address.StartsWith($Network.addressPrefix,[StringComparison]::Ordinal)) { throw 'Foreign case address' }
    $last=[int]($Address.Split('.')[-1])
    if ($last -lt 4 -or $last -gt 30) { throw 'Address outside owned /27 subnet' }
}

function Get-ExpansionPrivateAddresses([hashtable]$State, [hashtable]$Binding, [hashtable]$Network) {
    $addresses=@{}
    foreach ($target in $Network.targets) {
        foreach ($id in @($target.id,$target.endpointId)) {
            $resource=Read-ExpansionPrivateArm $State $id $Binding.specs[$id].api
            Assert-ExpansionStandardResource $State $Binding $resource $id -Live
            if ($id -ceq $target.endpointId) { $endpoint=$resource }
        }
        $interfaces=$endpoint.properties.networkInterfaces
        if ($interfaces -isnot [array] -or $interfaces.Count -ne 1) { throw 'One PE NIC required' }
        $nicId=$interfaces[0].id
        $nicPrefix="$($Binding.group)/providers/Microsoft.Network/networkInterfaces/"
        if ($nicId -isnot [string] -or $nicId -inotmatch ('^'+[regex]::Escape($nicPrefix)+'[a-zA-Z0-9_.-]+$')) { throw 'Foreign NIC scope' }
        $nic=Read-ExpansionPrivateArm $State $nicId '2024-05-01'
        Assert-FoundationText $nic.id $nicId
        Assert-FoundationText $nic.properties.privateEndpoint.id $target.endpointId
        Assert-FoundationText $nic.properties.provisioningState 'Succeeded'
        if ($nic.properties.ipConfigurations -isnot [array] -or -not $nic.properties.ipConfigurations.Count) { throw 'Missing NIC configurations' }
        $all=@(); $matching=@()
        foreach ($configuration in $nic.properties.ipConfigurations) {
            Assert-FoundationText $configuration.properties.subnet.id $Network.subnetId
            $address=$configuration.properties.privateIPAddress
            Assert-ExpansionPrivateAddress $Network $address
            $all+=$address
            $link=$configuration.properties.privateLinkConnectionProperties
            if ($link.fqdns -icontains $target.hostName) { Assert-FoundationEqual $link.groupId $target.groupId; $matching+=$address }
        }
        if (@($all | Select-Object -Unique).Count -ne $all.Count -or -not $matching.Count) { throw 'Duplicate addresses or missing exact hostname mapping' }
        $addresses[$target.hostName]=$matching
        $zoneGroups=@(Read-ExpansionPrivateArm $State "$($target.endpointId)/privateDnsZoneGroups" '2024-05-01' -List)
        if ($zoneGroups.Count -ne 1) { throw 'Exactly one DNS zone group required' }
        Assert-ExpansionStandardResource $State $Binding $zoneGroups[0] "$($target.endpointId)/privateDnsZoneGroups/default" -Live
        $zone=Read-ExpansionPrivateArm $State $target.zoneId '2024-06-01'
        Assert-FoundationOwned $State $zone $target.zoneId
        $links=@(Read-ExpansionPrivateArm $State "$($target.zoneId)/virtualNetworkLinks" '2024-06-01' -List)
        if ($links.Count -ne 1) { throw 'Exactly one DNS VNet link required' }
        $name=if ($target.service -ceq 'storage') { 'lab-only' } else { 'standard-lab-only' }
        Assert-FoundationText $links[0].id "$($target.zoneId)/virtualNetworkLinks/$name"
        Assert-FoundationText $links[0].properties.provisioningState 'Succeeded'
        Assert-FoundationText $links[0].properties.virtualNetwork.id $Network.vnetId
        Assert-FoundationEqual $links[0].properties.registrationEnabled $false
    }
    return $addresses
}

function Assert-ExpansionPrivateProbe([hashtable]$Network, $Probe, [hashtable]$Addresses) {
    if ($Probe.checks -isnot [array] -or $Probe.checks.Count -ne 3) { throw 'Three checks required' }
    Assert-FoundationSet @($Addresses.Keys) @($Network.targets.hostName)
    Assert-FoundationSet @($Probe.checks.hostName) @($Network.targets.hostName)
    foreach ($check in $Probe.checks) {
        Assert-FoundationEqual $check.tls443 $true
        if ($check.addresses -isnot [array] -or -not $check.addresses.Count) { throw 'Missing DNS addresses' }
        Assert-FoundationSet $check.addresses $Addresses[$check.hostName]
        foreach ($address in $check.addresses) { Assert-ExpansionPrivateAddress $Network $address }
    }
}

function Invoke-ExpansionPrivateCommand([hashtable]$State, [string[]]$Arguments, [int]$Budget=60) {
    $azPath=@(Get-Command az -CommandType Application)[0].Source
    $executable=$azPath; $prefix=@()
    if ([IO.Path]::GetExtension($azPath) -eq '.cmd') {
        $executable=Join-Path ([IO.Path]::GetDirectoryName($azPath)) '../python.exe'
        if (-not (Test-Path $executable)) { throw 'CLI Python missing; no shell fallback' }
        $prefix=@('-IBm','azure.cli')
    }
    $capture=Invoke-BoundedLabProcess -Executable $executable -Arguments ($prefix+$Arguments+@('--subscription',$State.subscriptionId,'--output','json','--only-show-errors')) -LogPrefix (Join-Path $State.evidenceDirectory ([guid]::NewGuid().ToString('N'))) -MaxSeconds $Budget -IdleSeconds ([math]::Min($Budget,120)) -Environment @{AZURE_CONFIG_DIR=$State.azureConfigDirectory;AZURE_CORE_NO_COLOR='true'}
    if ($capture.reason -cne 'Exited' -or $capture.exitCode -ne 0) { throw "Bounded command failed; private stderr: $($capture.stderr)" }
    return Read-FoundationJson $capture.stdout
}

function Read-ExpansionPrivateArm([hashtable]$State, [string]$Id, [string]$Api, [switch]$List) {
    if (-not $Id.StartsWith("/subscriptions/$($State.subscriptionId)/",[StringComparison]::OrdinalIgnoreCase) -or $Id -match '[?#]') { throw 'Foreign or malformed ARM target' }
    $response=Invoke-ExpansionPrivateCommand $State @('rest','--method','get','--url',"https://management.azure.com${Id}?api-version=$Api",'--headers','Accept=application/json')
    if ($List) {
        if ($response.value -isnot [array] -or $response.nextLink) { throw 'Complete array response required' }
        return $response.value
    }
    return $response
}

function Invoke-ExpansionPrivateVerification([string]$Path, [string]$Selector, [string]$Compiler) {
    $state=Read-LabRun $Path
    $paths=Get-ExpansionStandardPaths $state $Selector
    $lock=[IO.File]::Open($paths.lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $directory=Assert-ExternalLabPath (Join-Path $state.runDirectory ("expansion-private-$Selector-"+[guid]::NewGuid().ToString('N')))
    $null=[IO.Directory]::CreateDirectory($directory)
    $report=@{success=$false;project=$Selector;checkedAt=[DateTimeOffset]::UtcNow.ToString('o');runtimeVerified=$false;inferenceVerified=$false;scope='runner DNS and TLS only';reportPath=(Join-Path $directory 'receipt.json')}
    try {
        $state.evidenceDirectory=$directory
        $inputs=Get-FoundationInputHashes $state $Path
        $lab=Read-FoundationJson (Join-Path $state.runDirectory 'outputs.json')
        $foundation=Get-FoundationBinding $state $lab $Compiler
        $foundationPaths=Get-FoundationPaths $state
        $seal=@{manifest=(Read-FoundationJson $foundationPaths.state);output=(Read-FoundationJson $foundationPaths.outputs)}
        Assert-ExpansionStandardSeal $seal.manifest $seal.output $inputs $foundation (Get-FileHash $foundationPaths.outputs -Algorithm SHA256).Hash
        $binding=Get-ExpansionStandardBinding $state $foundation $seal.output $Selector $Compiler $paths
        $manifest=Read-FoundationJson $paths.state; $output=Read-FoundationJson $paths.outputs
        Assert-FoundationEqual $manifest.pending $false; Assert-FoundationEqual $manifest.verified $true
        Assert-FoundationEqual $manifest.outputHash (Get-FileHash $paths.outputs -Algorithm SHA256).Hash
        Assert-FoundationEqual $output.originalSha $inputs.state
        Assert-FoundationEqual $output.foundationOutputHash (Get-FileHash $foundationPaths.outputs -Algorithm SHA256).Hash
        Assert-FoundationEqual $output.controlPlaneVerified $true
        Assert-FoundationEqual $output.standard $binding.output
        Assert-FoundationEqual $output.validationSourceHashes (Get-ExpansionStandardSources)
        $protected=@($Path,$paths.state,$paths.outputs,$foundationPaths.state,$foundationPaths.outputs)
        $hashes=@{}; foreach ($file in $protected) { $hashes[$file]=(Get-FileHash $file -Algorithm SHA256).Hash }
        $sources=Get-ExpansionStandardSources
        foreach ($name in @('Test-ExpansionPrivate.ps1','Invoke-ExpansionWatchdog.ps1')) { $sources["scripts/$name"]=(Get-FileHash (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash }
        foreach ($selection in @('a-test','b-dev','b-test')) {
            $other=Get-ExpansionStandardPaths $state $selection
            if ((Test-Path $other.state) -and (Read-FoundationJson $other.state).pending) { throw 'Dependency operation pending' }
        }
        Assert-LabContext $state (Invoke-ExpansionPrivateCommand $state @('account','show'))
        $deployment=Read-ExpansionPrivateArm $state $binding.root '2022-09-01'
        Assert-FoundationText $deployment.id $binding.root
        Assert-FoundationText $deployment.properties.provisioningState 'Succeeded'
        $project=Read-ExpansionPrivateArm $state $binding.projectId '2026-05-01'
        Assert-FoundationOwned $state $project $binding.projectId
        Assert-FoundationText $project.identity.principalId $binding.principal
        Assert-FoundationText $project.properties.provisioningState 'Succeeded'
        $network=Get-ExpansionPrivateBinding $state $lab $binding
        $runner=Read-ExpansionPrivateArm $state $network.runnerId '2024-07-01'
        Assert-FoundationOwned $state $runner $network.runnerId
        Assert-FoundationText $runner.properties.provisioningState 'Succeeded'
        Assert-FoundationEqual $runner.properties.storageProfile.osDisk.osType 'Linux'
        $addresses=Get-ExpansionPrivateAddresses $state $binding $network
        $nonce=[guid]::NewGuid().ToString('N')
        $shell=New-StandardPrivateShell $addresses $nonce
        if ([Text.Encoding]::UTF8.GetByteCount($shell) -gt 12000) { throw 'Probe transfer limit exceeded' }
        $response=Invoke-ExpansionPrivateCommand $state @('vm','run-command','invoke','--ids',$network.runnerId,'--command-id','RunShellScript','--scripts',$shell) 180
        $probe=Read-StandardPrivateFrame $response $nonce
        Assert-ExpansionPrivateProbe $network $probe $addresses
        Assert-FoundationEqual (Get-ExpansionPrivateAddresses $state $binding $network) $addresses
        Assert-FoundationEqual (Get-FoundationInputHashes $state $Path) $inputs
        foreach ($file in $protected) { Assert-FoundationEqual (Get-FileHash $file -Algorithm SHA256).Hash $hashes[$file] }
        $current=Get-ExpansionStandardSources
        foreach ($name in @('Test-ExpansionPrivate.ps1','Invoke-ExpansionWatchdog.ps1')) { $current["scripts/$name"]=(Get-FileHash (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash }
        Assert-FoundationEqual $current $sources
        $report.success=$true; $report.verifiedAt=[DateTimeOffset]::UtcNow.ToString('o'); $report.checks=$probe.checks; $report.nonce=$nonce; $report.binding=$network; $report.ownedAddresses=$addresses; $report.inputHashes=$hashes; $report.sourceHashes=$sources
        Write-StandardJson $report.reportPath $report
        return $report
    } catch {
        $report.error=$_.Exception.Message
        Write-StandardJson $report.reportPath $report
        throw
    } finally { $lock.Dispose() }
}

if ($DefinitionsOnly) { return }
$privateInvocation=@{Path=$StatePath;Selector=$Project;Compiler=$BicepExecutable}
$timer=[Diagnostics.Stopwatch]::StartNew(); $ErrorActionPreference='Stop'
try {
    . (Join-Path $PSScriptRoot 'Invoke-ExpansionStandard.ps1') -DefinitionsOnly
    . (Join-Path $PSScriptRoot 'Invoke-ExpansionWatchdog.ps1') -DefinitionsOnly
    Invoke-ExpansionPrivateVerification @privateInvocation | ConvertTo-Json -Depth 30
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }