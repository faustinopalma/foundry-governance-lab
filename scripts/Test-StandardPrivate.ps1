[CmdletBinding()]
param([string]$StatePath, [switch]$DefinitionsOnly)

function Assert-StandardPrivateState([hashtable]$State) {
    Assert-LabState $State
    foreach ($flag in @('minimalPrompt','privateAccessVerified','deploymentAuthorized')) {
        if ($State[$flag] -isnot [bool] -or -not $State[$flag]) { throw "Required boolean: $flag" }
    }
    if ($State.phase -isnot [string] -or $State.phase -cne 'activate' -or $State.pendingPhase) { throw 'Activated Minimal with no pending main phase required' }
    $standard = $State.standard; $sequence = @('dependencies','account','project','access')
    if ($standard -isnot [hashtable] -or $standard.completedStages -isnot [array] -or $standard.deploymentNames -isnot [hashtable] -or $standard.pendingStage) { throw 'Completed, idle Standard dependencies required' }
    $completed = $standard.completedStages
    if ($completed.Count -lt 1 -or $completed.Count -gt 4 -or ($completed -join ',') -cne (($sequence | Select-Object -First $completed.Count) -join ',')) { throw 'Invalid Standard stage sequence' }
    foreach ($entry in $standard.deploymentNames.GetEnumerator()) {
        if ($entry.Key -cnotin $completed -or $entry.Value -isnot [string] -or $entry.Value -cne "fgl-$($State.labId)-standard-$($entry.Key)") { throw 'Unbound Standard deployment' }
    }
    foreach ($done in $completed) { if ($done -ne 'account' -and -not $standard.deploymentNames.ContainsKey($done)) { throw 'Completed stage has no recorded deployment' } }
}

function Get-StandardPrivateBinding([hashtable]$State, [hashtable]$Lab, [hashtable]$Outputs) {
    Assert-StandardPrivateState $State
    $original = @(Get-LabPrivateTargets $State $Lab)
    $dependency = $Outputs.dependencies; $stem = "fgl-$($State.labId)"
    $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-$stem"
    $integration = "$prefix-integration"; $casePrefix = "$prefix-case-a"
    $vnet = "$integration/providers/Microsoft.Network/virtualNetworks/vnet-$stem"
    $runner = "$integration/providers/Microsoft.Compute/virtualMachines/vm-$stem-runner"
    $account = ($original | Where-Object key -eq 'case-a').resourceId; $project = "$account/projects/case-a-dev"
    $expected = @{labId=$State.labId; ownershipId=$State.ownershipId; stage='dependencies'; location='swedencentral'; accountId=$account; projectId=$project; vnetId=$vnet; subnetId="$vnet/subnets/snet-case-a-pe"; projectEndpoint="https://$(($account -split '/')[-1]).services.ai.azure.com/api/projects/case-a-dev"}
    if ($dependency -isnot [hashtable] -or $Lab.runner -isnot [string] -or $Lab.runner -ine $runner) { throw 'Missing dependencies or unexpected runner output' }
    foreach ($key in $expected.Keys) { if ($dependency[$key] -isnot [string] -or $dependency[$key] -ine $expected[$key]) { throw "Dependency output mismatch: $key" } }
    if ($dependency.resourceGroups.caseA -isnot [string] -or $dependency.resourceGroups.integration -isnot [string] -or $dependency.resourceGroups.caseA -cne "rg-$stem-case-a" -or $dependency.resourceGroups.integration -cne "rg-$stem-integration") { throw 'Dependency groups mismatch' }
    foreach ($key in @('projectPrincipalId','workspaceId')) {
        $parsed = [guid]::Empty
        if ($dependency[$key] -isnot [string] -or -not ([guid]::TryParseExact($dependency[$key], 'D', [ref]$parsed) -or ($key -eq 'workspaceId' -and [guid]::TryParseExact($dependency[$key], 'N', [ref]$parsed))) -or $parsed -eq [guid]::Empty) { throw "Invalid dependency GUID: $key" }
    }
    $storage = $dependency.storage.name
    if ($storage -isnot [string] -or $storage -cnotmatch ('^stfgl' + [regex]::Escape($State.labId) + '[a-z0-9]{6}$')) { throw 'Invalid output storage name' }
    $targets = @()
    foreach ($spec in @(@('storage','blob',$storage,'Microsoft.Storage/storageAccounts','blob.core.windows.net','blob','2023-05-01'), @('search','search',"srch-$stem-standard",'Microsoft.Search/searchServices','search.windows.net','searchService','2025-05-01'), @('cosmos','cosmos',"cosmos-$stem-standard",'Microsoft.DocumentDB/databaseAccounts','documents.azure.com','Sql','2024-11-15'))) {
        $hostName = "$($spec[2]).$($spec[4])"; $id = "$casePrefix/providers/$($spec[3])/$($spec[2])"
        $endpoint = switch ($spec[0]) { 'storage' { "https://$hostName/" } 'cosmos' { "https://${hostName}:443/" } default { "https://$hostName" } }
        $zone = "$integration/providers/Microsoft.Network/privateDnsZones/privatelink.$($spec[4])"
        $value = $dependency[$spec[0]]
        if ($value.name -isnot [string] -or $value.name -cne $spec[2] -or $value.id -isnot [string] -or $value.id -ine $id -or $value.endpoint -isnot [string] -or $value.endpoint -cne $endpoint -or $dependency.dnsZoneIds[$spec[1]] -isnot [string] -or $dependency.dnsZoneIds[$spec[1]] -ine $zone) { throw 'Service or DNS output binding mismatch' }
        $targets += @{service=$spec[0]; id=$id; name=$spec[2]; hostName=$hostName; endpoint=$endpoint; groupId=$spec[5]; api=$spec[6]; zoneId=$zone; endpointId="$casePrefix/providers/Microsoft.Network/privateEndpoints/pe-$stem-standard-$($spec[1])"}
    }
    if ($dependency.privateEndpointIds -isnot [array] -or $dependency.privateEndpointIds.Count -ne 3 -or @(Compare-Object $dependency.privateEndpointIds $targets.endpointId).Count -or $dependency.dnsZoneIds.Count -ne 3) { throw 'Exactly three bound PEs and zones required' }
    return @{runnerId=$runner; accountId=$account; projectId=$project; projectPrincipalId=$dependency.projectPrincipalId; workspaceId=$dependency.workspaceId; vnetId=$vnet; subnetId=$expected.subnetId; targets=$targets}
}

function Assert-StandardPrivateProbe([hashtable]$Binding, [hashtable]$Probe, [hashtable]$Addresses) {
    if ($Probe.checks -isnot [array] -or $Probe.checks.Count -ne 3 -or @(Compare-Object @($Probe.checks.hostName) @($Binding.targets.hostName)).Count) { throw 'Probe coverage mismatch' }
    foreach ($check in $Probe.checks) {
        $owned = @($Addresses[$check.hostName])
        if ($check.tls443 -isnot [bool] -or -not $check.tls443 -or $check.addresses -isnot [array] -or -not $check.addresses.Count -or -not $owned.Count -or @($check.addresses | Select-Object -Unique).Count -ne $check.addresses.Count -or @(Compare-Object $check.addresses $owned).Count) { throw 'DNS must exactly match the corresponding PE NICs and TLS must succeed' }
        foreach ($address in $check.addresses) {
            $parsed = $null
            if ($address -isnot [string] -or $address -cnotmatch '^10\.76\.6\.(?:[1-9][0-9]{0,2})$' -or -not [Net.IPAddress]::TryParse($address, [ref]$parsed) -or $parsed.ToString() -cne $address) { throw 'Noncanonical or foreign PE address' }
        }
    }
}

function Get-StandardPrivateAddresses([hashtable]$State, [hashtable]$Binding) {
    $addresses = @{}
    foreach ($target in $Binding.targets) {
        $service = Read-StandardArm $State $target.id $target.api 'private-service'; Assert-StandardOwned $State $service $target.id
        $properties = $service.properties; $auth = if ($target.service -eq 'storage') { $properties.allowSharedKeyAccess } else { $properties.disableLocalAuth }
        if ($service.name -isnot [string] -or $service.name -cne $target.name -or $properties.provisioningState -isnot [string] -or $properties.provisioningState -ine 'Succeeded' -or $properties.publicNetworkAccess -isnot [string] -or $properties.publicNetworkAccess -ine 'Disabled' -or $auth -isnot [bool] -or $auth -ne ($target.service -ne 'storage')) { throw 'Dependency identity, provisioning, public access or local authentication mismatch' }
        $endpoint = Read-StandardArm $State $target.endpointId '2024-05-01' 'private-pe'; Assert-StandardOwned $State $endpoint $target.endpointId
        $properties = $endpoint.properties; $connections = $properties.privateLinkServiceConnections
        if ($properties.provisioningState -isnot [string] -or $properties.provisioningState -cne 'Succeeded' -or $properties.subnet.id -isnot [string] -or $properties.subnet.id -ine $Binding.subnetId -or $connections -isnot [array] -or $connections.Count -ne 1 -or @($properties.manualPrivateLinkServiceConnections).Where({ $null -ne $_ }).Count) { throw 'PE state, subnet or connection coverage mismatch' }
        $connection = $connections[0].properties
        if ($connection.privateLinkServiceId -isnot [string] -or $connection.privateLinkServiceId -ine $target.id -or $connection.groupIds -isnot [array] -or $connection.groupIds.Count -ne 1 -or $connection.groupIds[0] -isnot [string] -or $connection.groupIds[0] -cne $target.groupId -or $connection.privateLinkServiceConnectionState.status -isnot [string] -or $connection.privateLinkServiceConnectionState.status -cne 'Approved') { throw 'PE service target or approval mismatch' }
        if ($properties.networkInterfaces -isnot [array] -or $properties.networkInterfaces.Count -ne 1) { throw 'Exactly one owned PE NIC required' }
        $nicId = $properties.networkInterfaces[0].id; $nicPrefix = ($target.id -split '/providers/')[0] + '/providers/Microsoft.Network/networkInterfaces/'
        if ($nicId -isnot [string] -or $nicId -inotmatch ('^' + [regex]::Escape($nicPrefix) + '[a-zA-Z0-9_.-]+$')) { throw 'PE NIC scope mismatch' }
        Assert-LabResourceId $State $nicId
        $nic = Read-StandardArm $State $nicId '2024-05-01' 'private-nic'
        if ($nic.properties.privateEndpoint.id -isnot [string] -or $nic.properties.privateEndpoint.id -ine $target.endpointId -or $nic.properties.provisioningState -isnot [string] -or $nic.properties.provisioningState -cne 'Succeeded' -or $nic.properties.ipConfigurations -isnot [array] -or -not $nic.properties.ipConfigurations.Count) { throw 'PE NIC ownership or state mismatch' }
        $owned = @($nic.properties.ipConfigurations | ForEach-Object { if ($_.properties.subnet.id -isnot [string] -or $_.properties.subnet.id -ine $Binding.subnetId) { throw 'NIC subnet mismatch' }; $_.properties.privateIPAddress })
        foreach ($address in $owned) { if ($address -isnot [string] -or $address -cnotmatch '^10\.76\.6\.(?:[4-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$') { throw 'PE NIC address outside owned subnet' } }
        if (@($owned | Select-Object -Unique).Count -ne $owned.Count) { throw 'Duplicate NIC addresses' }
        $matching = @($nic.properties.ipConfigurations | Where-Object { $_.properties.privateLinkConnectionProperties.fqdns -icontains $target.hostName })
        if (-not $matching.Count) { throw 'PE NIC has no IP explicitly associated with the service hostname' }
        foreach ($configuration in $matching) { if ($configuration.properties.privateLinkConnectionProperties.groupId -cne $target.groupId) { throw 'NIC hostname group mismatch' } }
        $addresses[$target.hostName] = @($matching | ForEach-Object { $_.properties.privateIPAddress })
        $zoneGroups = @(Read-StandardArm $State "$($target.endpointId)/privateDnsZoneGroups" '2024-05-01' 'private-zonegroups' -List)
        if ($zoneGroups.Count -ne 1 -or $zoneGroups[0].id -isnot [string] -or $zoneGroups[0].id -ine "$($target.endpointId)/privateDnsZoneGroups/default" -or $zoneGroups[0].properties.provisioningState -isnot [string] -or $zoneGroups[0].properties.provisioningState -cne 'Succeeded') { throw 'Unexpected PE DNS zone groups' }
        $configs = $zoneGroups[0].properties.privateDnsZoneConfigs
        if ($configs -isnot [array] -or $configs.Count -ne 1 -or $configs[0].properties.privateDnsZoneId -isnot [string] -or $configs[0].properties.privateDnsZoneId -ine $target.zoneId) { throw 'PE DNS zone mismatch' }
        $zone = Read-StandardArm $State $target.zoneId '2024-06-01' 'private-zone'; Assert-StandardOwned $State $zone $target.zoneId
        $links = @(Read-StandardArm $State "$($target.zoneId)/virtualNetworkLinks" '2024-06-01' 'private-links' -List)
        $linkName = if ($target.service -eq 'storage') { 'lab-only' } else { 'standard-lab-only' }
        if ($links.Count -ne 1 -or $links[0].id -isnot [string] -or $links[0].id -ine "$($target.zoneId)/virtualNetworkLinks/$linkName" -or $links[0].properties.provisioningState -isnot [string] -or $links[0].properties.provisioningState -cne 'Succeeded' -or $links[0].properties.virtualNetwork.id -isnot [string] -or $links[0].properties.virtualNetwork.id -ine $Binding.vnetId -or $links[0].properties.registrationEnabled -isnot [bool] -or $links[0].properties.registrationEnabled) { throw 'DNS VNet link mismatch' }
    }
    return $addresses
}

function New-StandardPrivateShell([hashtable]$Addresses, [string]$Nonce) {
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{hosts=$Addresses;nonce=$Nonce} | ConvertTo-Json -Depth 10 -Compress)))
    return (@'
set -eu
timeout -s KILL 60s python3 -B - <<'FGL_PY'
import base64, gzip, json, signal, socket, ssl
payload = json.loads(base64.b64decode('__PAYLOAD__'))
socket.setdefaulttimeout(10)
def dns_timeout(signum, frame):
    raise TimeoutError('DNS timeout')
signal.signal(signal.SIGALRM, dns_timeout)
checks = []
context = ssl.create_default_context()
for hostname, owned in payload['hosts'].items():
    check = dict(hostName=hostname, addresses=[], tls443=False)
    try:
        signal.alarm(10)
        try:
            addresses = sorted({entry[4][0] for entry in socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)})
        finally:
            signal.alarm(0)
        check['addresses'] = addresses
        if not addresses or set(addresses) != set(owned):
            raise ValueError('DNS mismatch')
        for address in addresses:
            with socket.create_connection((address, 443), timeout=5) as connection:
                with context.wrap_socket(connection, server_hostname=hostname):
                    pass
        check['tls443'] = True
    except Exception as error:
        check['error'] = type(error).__name__
    checks.append(check)
packed = gzip.compress(json.dumps(dict(nonce=payload['nonce'], checks=checks), separators=(',', ':')).encode())
if len(packed) >= 2600:
    raise ValueError('Result too large')
print('FGL_STANDARD_BEGIN_' + payload['nonce'] + '\n' + base64.b64encode(packed).decode() + '\nFGL_STANDARD_END_' + payload['nonce'])
FGL_PY
'@).Replace('__PAYLOAD__', $payload).Replace("`r", '')
}

function Read-StandardPrivateFrame([hashtable]$Response, [string]$Nonce) {
    if ($Nonce -cnotmatch '^[a-f0-9]{32}$' -or $Response.value -isnot [array] -or -not $Response.value.Count) { throw 'Missing RunCommand response' }
    foreach ($entry in $Response.value) { if ($entry.code -isnot [string] -or $entry.code -cnotmatch '^(?:ProvisioningState|ComponentStatus/Std(?:Out|Err))/succeeded$' -or $entry.message -isnot [string]) { throw 'RunCommand did not succeed' } }
    $message = ($Response.value.message -join "`n"); $pattern = '(?m)^FGL_STANDARD_BEGIN_' + $Nonce + '\r?\n([A-Za-z0-9+/=]+)\r?\nFGL_STANDARD_END_' + $Nonce + '\r?$'
    $frames = [regex]::Matches($message, $pattern)
    if ($message.Length -gt 12000 -or $frames.Count -ne 1 -or [regex]::Matches($message, 'FGL_STANDARD_BEGIN_').Count -ne 1 -or [regex]::Matches($message, 'FGL_STANDARD_END_').Count -ne 1) { throw 'Missing, duplicate or truncated result frame' }
    $bytes = [Convert]::FromBase64String($frames[0].Groups[1].Value)
    if ($bytes.Length -ge 2600) { throw 'Compressed result too large' }
    $stream = [IO.MemoryStream]::new($bytes); $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress); $reader = [IO.StreamReader]::new($gzip)
    try { $buffer = [char[]]::new(16385); $count = $reader.ReadBlock($buffer, 0, $buffer.Length); if ($count -gt 16384) { throw 'Expanded result too large' }; $probe = ([string]::new($buffer, 0, $count)) | ConvertFrom-Json -AsHashtable -Depth 20 } finally { $reader.Dispose(); $gzip.Dispose(); $stream.Dispose() }
    if ($probe -isnot [hashtable] -or $probe.nonce -isnot [string] -or $probe.nonce -cne $Nonce) { throw 'Result nonce mismatch' }
    return $probe
}

function Get-StandardPrivateStamp([hashtable]$State) {
    $parts = @($State.subscriptionId,$State.tenantId,$State.ownershipId,$State.labId,$State.runDirectory,$State.azureConfigDirectory,$State.phase,($State.resourceGroups -join ','),($State.preexistingGroupIds -join ','),($State.standard.completedStages -join ','))
    foreach ($entry in ($State.standard.deploymentNames.GetEnumerator() | Sort-Object Key)) { $parts += "$($entry.Key)=$($entry.Value)" }
    foreach ($name in @('outputs.json','standard-outputs.json')) { $parts += (Get-FileHash -LiteralPath (Join-Path $State.runDirectory $name) -Algorithm SHA256).Hash }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))))
}

function Invoke-StandardPrivateVerification([string]$Path) {
    $initial = Read-LabRun $Path
    $reportPath = Join-Path $initial.runDirectory "standard-private-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfff'))-$([guid]::NewGuid().ToString('N')).json"
    $report = @{success=$false; verifiedAt=$null; checkedAt=[DateTimeOffset]::UtcNow.ToString('o'); actionNeeded='Reconcile state and dependency outputs'; binding=$null; bindingSha256=$null; managementVerified=$false; ownedAddresses=@{}; checks=@(); reportPath=$reportPath}
    try {
        $state = Read-LabRun $Path
        if ($state.runDirectory -cne $initial.runDirectory -or $state.standard -isnot [hashtable]) { throw 'State changed or Standard state missing' }
        $state.standard.privateDependenciesVerified = $false; $state.standard.Remove('privateDependenciesEvidence'); Save-LabRun $state $Path
        $stamp = Get-StandardPrivateStamp $state
        $lab = Get-Content -LiteralPath (Join-Path $state.runDirectory 'outputs.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $outputs = Get-Content -LiteralPath (Join-Path $state.runDirectory 'standard-outputs.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $binding = Get-StandardPrivateBinding $state $lab $outputs; $report.binding=$binding; $report.bindingSha256=$stamp
        $report.actionNeeded='Reconcile ownership, project identity and nonterminal deployments'
        Assert-LabContext $state (Invoke-LabAz $state @('account','show') 'standard-private-context')
        $groups = @($state.resourceGroups | ForEach-Object { Invoke-LabAz $state @('group','show','--name',$_) 'standard-private-group' }); Assert-StandardGroups $state $groups
        $live = Get-StandardBindings $state $lab (Read-StandardArm $state $binding.accountId '2026-05-01' 'private-account') (Read-StandardArm $state $binding.projectId '2026-05-01' 'private-project') (Read-StandardArm $state $lab.gateway '2024-05-01' 'private-gateway')
        if ($live.parameters.projectPrincipalId.value -ine $binding.projectPrincipalId -or $live.parameters.workspaceId.value -ine $binding.workspaceId) { throw 'Live project identity mismatch' }
        $roots=@(); $nested=@{}
        foreach ($name in (@('bootstrap','lock','activate' | ForEach-Object { "fgl-$($state.labId)-$_" }) + @($state.standard.deploymentNames.Values))) { $roots += Invoke-LabAz $state @('deployment','sub','show','--name',$name) 'standard-private-root' }
        foreach ($group in $state.resourceGroups) { $nested[$group] = @(Invoke-LabAz $state @('deployment','group','list','--resource-group',$group) 'standard-private-nested') }
        foreach ($deployment in (@($roots) + @($nested.Values | ForEach-Object { $_ }))) { foreach ($text in @($deployment.id,$deployment.name,$deployment.properties.provisioningState)) { if ($text -isnot [string]) { throw 'Malformed deployment evidence' } } }
        Assert-StandardTerminal $state $roots $nested
        foreach ($root in $roots) { if ($root.properties.provisioningState -isnot [string] -or $root.properties.provisioningState -cne 'Succeeded') { throw 'Completed deployment root must have succeeded' } }
        $report.actionNeeded='Inspect the owned runner and dependency PE, NIC, DNS or service configuration'
        $runner = Read-StandardArm $state $binding.runnerId '2024-07-01' 'private-runner'; Assert-StandardOwned $state $runner $binding.runnerId
        if ($runner.properties.provisioningState -isnot [string] -or $runner.properties.provisioningState -cne 'Succeeded' -or $runner.properties.storageProfile.osDisk.osType -isnot [string] -or $runner.properties.storageProfile.osDisk.osType -cne 'Linux') { throw 'Succeeded Linux runner required' }
        $addresses = Get-StandardPrivateAddresses $state $binding; $report.ownedAddresses=$addresses; $report.managementVerified=$true
        $report.actionNeeded='Inspect runner DNS and TLS, Python 3 availability or the bounded RunCommand result'
        $nonce = [guid]::NewGuid().ToString('N'); $shell = New-StandardPrivateShell $addresses $nonce
        if ([Text.Encoding]::UTF8.GetByteCount($shell) -gt 12000) { throw 'Inline probe exceeds transfer limit' }
        $response = Invoke-LabAz $state @('vm','run-command','invoke','--ids',$binding.runnerId,'--command-id','RunShellScript','--scripts',$shell) 'standard-private-probe'
        $probe = Read-StandardPrivateFrame $response $nonce; $report.checks=$probe.checks
        Assert-StandardPrivateProbe $binding $probe $addresses
        $report.actionNeeded='Rerun verification after reconciling changed state or outputs'
        $fresh = Read-LabRun $Path; Assert-StandardPrivateState $fresh
        if ((Get-StandardPrivateStamp $fresh) -cne $stamp) { throw 'Verification bindings changed' }
        $report.success=$true; $report.verifiedAt=[DateTimeOffset]::UtcNow.ToString('o'); $report.actionNeeded=$null
        Write-StandardJson $reportPath $report
        $fresh.standard.privateDependenciesVerified=$true; $fresh.standard.privateDependenciesEvidence=@{path=$reportPath; sha256=(Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash; bindingSha256=$stamp; verifiedAt=$report.verifiedAt}
        Save-LabRun $fresh $Path
        return $report
    } catch {
        $report.success=$false; $report.verifiedAt=$null
        if (-not $report.actionNeeded) { $report.actionNeeded='Inspect the local report and state write failure; rerun verification' }
        Write-StandardJson $reportPath $report
        throw "Standard private verification failed. Action needed: $($report.actionNeeded). Private report: $reportPath"
    }
}

if ($DefinitionsOnly) { return }
$timer = [Diagnostics.Stopwatch]::StartNew(); $ErrorActionPreference = 'Stop'
try {
    if (-not $StatePath) { throw 'StatePath required unless DefinitionsOnly' }
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    $verificationStatePath = $StatePath
    . (Join-Path $PSScriptRoot 'Invoke-StandardStage.ps1') -DefinitionsOnly
    Invoke-StandardPrivateVerification $verificationStatePath | ConvertTo-Json -Depth 30
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }