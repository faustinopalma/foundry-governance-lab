[CmdletBinding()]
param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][ValidateSet('Prepare','VerifyPrivate','Gateway','Identity','Agent','Registry','MinimalPrompt')][string]$Action, [string]$ExpectedAgentVersion)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    $state = Read-LabRun $StatePath
    if ($state['minimalPrompt'] -eq $true -and $Action -notin @('Prepare','VerifyPrivate','MinimalPrompt')) { throw 'This action requires the full profile; use the dedicated minimal prompt diagnostic harness' }
    if ($state.phase -notin @('bootstrap','lock','activate') -or $state.pendingPhase) { throw 'A completed deployment phase is required' }
    $lab = Get-Content (Join-Path $state.runDirectory 'outputs.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    if ($lab['minimalPrompt'] -eq $true -and $Action -notin @('Prepare','VerifyPrivate','MinimalPrompt')) { throw 'Full diagnostic actions are prohibited for minimal outputs' }
    Assert-LabResourceId $state $lab.runner
    $runnerName = "vm-fgl-$($state.labId)-runner"
    $runnerGroup = "rg-fgl-$($state.labId)-integration"
    if ($lab.runner -ine "/subscriptions/$($state.subscriptionId)/resourceGroups/$runnerGroup/providers/Microsoft.Compute/virtualMachines/$runnerName") { throw 'Runner identity mismatch' }
    if ($Action -eq 'MinimalPrompt') {
        $requestedAgentVersion = $ExpectedAgentVersion
        . (Join-Path $PSScriptRoot 'Invoke-MinimalPromptChecks.ps1') -DefinitionsOnly
        $ExpectedAgentVersion = $requestedAgentVersion
        $null = Get-MinimalPromptContext $state $lab
        Import-Module (Join-Path $PSScriptRoot 'MinimalTeardownAcceptance.psm1')
        $attempt = New-MinimalInvocationAttempt $state $ExpectedAgentVersion
    }
    $null = Confirm-LabRunContext $state
    $shell = [Collections.Generic.List[string]]::new()
    $shell.Add('set -eu')
    $shell.Add('umask 077')
    $shell.Add('mkdir -p /opt/fgl/scripts /var/lib/fgl-private')
    $shell.Add('chmod 700 /var/lib/fgl-private')
    if ($Action -eq 'Prepare') {
        $shell.Add('export DEBIAN_FRONTEND=noninteractive')
        $shell.Add('if ! command -v pwsh >/dev/null 2>&1; then')
        $shell.Add('timeout 180 apt-get update -qq')
        $shell.Add('timeout 180 apt-get install -y -qq wget ca-certificates apt-transport-https')
        $shell.Add('. /etc/os-release')
        $shell.Add('test "$VERSION_ID" = "24.04"')
        $shell.Add('wget -q --timeout=30 https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O /var/lib/fgl-private/packages.deb')
        $shell.Add('dpkg -i /var/lib/fgl-private/packages.deb >/dev/null')
        $shell.Add('timeout 180 apt-get update -qq')
        $shell.Add('timeout 300 apt-get install -y -qq powershell')
        $shell.Add('fi')
    }
    $uploads = @{}
    foreach ($name in @('Invoke-GatewayChecks.ps1','Invoke-IdentityChecks.ps1','Invoke-AgentChecks.ps1','Invoke-RegistryChecks.ps1','Invoke-MinimalPromptChecks.ps1','LabExecution.psm1','PublicSource.psm1','LabSafety.psm1','TestResults.psm1')) {
        $uploads["/opt/fgl/scripts/$name"] = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $name))
    }
    $remoteState = @{}
    foreach ($key in @('subscriptionId','tenantId','ownershipId','labId','resourceGroups','phase','deploymentAuthorized','privateAccessVerified','pendingPhase')) { $remoteState[$key] = $state[$key] }
    if ($state.ContainsKey('minimalPrompt')) { $remoteState.minimalPrompt = $state.minimalPrompt }
    $uploads['/var/lib/fgl-private/state.json'] = [Text.Encoding]::UTF8.GetBytes(($remoteState | ConvertTo-Json -Depth 20))
    $uploads['/var/lib/fgl-private/outputs.json'] = [Text.Encoding]::UTF8.GetBytes(($lab | ConvertTo-Json -Depth 100))
    if ($Action -eq 'VerifyPrivate') {
        if ($state.phase -ne 'lock') { throw 'Private verification requires completed lock phase' }
        $targets = @(Get-LabPrivateTargets $state $lab)
        $uploads['/var/lib/fgl-private/targets.json'] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $targets -Depth 20))
        $privateProbe = @'
$ErrorActionPreference = 'Stop'
$targets = Get-Content '/var/lib/fgl-private/targets.json' -Raw | ConvertFrom-Json -AsHashtable
$hosts = @($targets | ForEach-Object { $_.hostName })
$checks = @()
foreach ($hostName in $hosts) {
    $addresses = @([Net.Dns]::GetHostAddressesAsync($hostName).WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult() | ForEach-Object { $_.ToString() })
    if (-not $addresses.Count -or @($addresses | Where-Object { $_ -notmatch '^10\.76\.' }).Count) { throw 'DNS is not in the lab address range' }
    $client = [Net.Sockets.TcpClient]::new()
    try { $client.ConnectAsync($hostName,443).WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult() } finally { $client.Dispose() }
    $checks += @{hostName=$hostName; addresses=$addresses; tcp443=$true}
}
$response = Invoke-WebRequest -Uri ('https://' + $hosts[0] + '/fgl-private-probe') -SkipHttpErrorCheck -TimeoutSec 20 -MaximumRedirection 0
if ([int]$response.StatusCode -ne 404) { throw 'Expected private gateway response was not obtained' }
@{checks=$checks; gatewayStatus=[int]$response.StatusCode} | ConvertTo-Json -Depth 10 | Set-Content '/var/lib/fgl-private/result.json' -Encoding utf8
'@
        $uploads['/var/lib/fgl-private/probe.ps1'] = [Text.Encoding]::UTF8.GetBytes($privateProbe)
    }
    foreach ($entry in $uploads.GetEnumerator()) {
        $payload = [IO.MemoryStream]::new()
        $compressor = [IO.Compression.GZipStream]::new($payload, [IO.Compression.CompressionLevel]::Optimal, $true)
        try {
            $compressor.Write($entry.Value, 0, $entry.Value.Length)
            $compressor.Dispose()
            $shell.Add("printf '%s' '$([Convert]::ToBase64String($payload.ToArray()))' | base64 -d | gzip -d > '$($entry.Key)'")
        } finally { $compressor.Dispose(); $payload.Dispose() }
    }
    if ($Action -eq 'Prepare') {
        $shell.Add('pwsh -NoProfile -Command ''$PSVersionTable.PSVersion.ToString()''')
        $shell.Add('printf "FGL_PREPARE_OK\n"')
    } else {
        $shell.Add('rm -f /var/lib/fgl-private/result.json')
        if ($Action -eq 'VerifyPrivate') { $shell.Add('timeout 180 pwsh -NoProfile -File /var/lib/fgl-private/probe.ps1 > /var/lib/fgl-private/probe.log 2>&1') }
        else {
            if ($state.phase -ne 'activate') { throw 'Gateway tests require activation' }
            $harnessName = switch ($Action) { 'Identity' { 'Invoke-IdentityChecks.ps1' } 'Agent' { 'Invoke-AgentChecks.ps1' } 'Registry' { 'Invoke-RegistryChecks.ps1' } 'MinimalPrompt' { 'Invoke-MinimalPromptChecks.ps1' } default { 'Invoke-GatewayChecks.ps1' } }
            $runnerTimeout = if ($Action -eq 'MinimalPrompt') { 660 } else { 480 }
            $versionArgument = if ($Action -eq 'MinimalPrompt') { " -ExpectedAgentVersion '$ExpectedAgentVersion'" } else { '' }
            $shell.Add("timeout $runnerTimeout pwsh -NoProfile -File /opt/fgl/scripts/$harnessName -RunLive -StatePath /var/lib/fgl-private/state.json -OutputsPath /var/lib/fgl-private/outputs.json -ResultsPath /var/lib/fgl-private/result.json$versionArgument > /var/lib/fgl-private/probe.log 2>&1")
        }
        $shell.Add('test -s /var/lib/fgl-private/result.json')
        $shell.Add('gzip -c /var/lib/fgl-private/result.json > /var/lib/fgl-private/result.gz')
        $shell.Add('test $(wc -c < /var/lib/fgl-private/result.gz) -lt 2600')
        $frameSuffix = if ($Action -eq 'MinimalPrompt') { '_' + $attempt.nonce } else { '' }
        $shell.Add('printf "FGL_RESULT_BEGIN' + $frameSuffix + '\n"; base64 -w0 /var/lib/fgl-private/result.gz; printf "\nFGL_RESULT_END' + $frameSuffix + '\n"')
    }
    $scriptName = if ($Action -eq 'MinimalPrompt') { "runner-MinimalPrompt-$($attempt.nonce).sh" } else { "runner-$Action.sh" }
    $scriptPath = Join-Path $state.runDirectory $scriptName
    $scriptText = ($shell -join "`n").Replace("`r",'') + "`n"
    if ([Text.Encoding]::UTF8.GetByteCount($scriptText) -gt 120000) { throw 'Runner command exceeds the bounded 120000-byte transfer size' }
    [IO.File]::WriteAllText($scriptPath, $scriptText, [Text.UTF8Encoding]::new($false))
    if ($Action -eq 'MinimalPrompt') { Save-MinimalInvocationAttempt $state $attempt $scriptPath }
    $response = Invoke-LabAz $state @('vm','run-command','invoke','--resource-group',$runnerGroup,'--name',$runnerName,'--command-id','RunShellScript','--scripts',"@$scriptPath") "runner-$Action"
    $message = ($response.value | ForEach-Object { $_.message }) -join "`n"
    if ($Action -eq 'Prepare') {
        if ($message -notmatch 'FGL_PREPARE_OK') { throw 'Runner installation failed; inspect private Run Command output' }
        Write-Output 'PASS: runner tools installed and public test scripts uploaded; operator credentials were not transferred.'
    } else {
        if ($Action -eq 'MinimalPrompt') {
            $json = Assert-MinimalAttemptFrame $response $attempt.nonce
        } else {
        if ($message -notmatch '(?s)FGL_RESULT_BEGIN\s+([A-Za-z0-9+/=]+)\s+FGL_RESULT_END') { throw 'Runner result is missing or truncated; inspect private Run Command output' }
        $compressed = [IO.MemoryStream]::new([Convert]::FromBase64String($Matches[1]))
        $gzip = [IO.Compression.GZipStream]::new($compressed,[IO.Compression.CompressionMode]::Decompress)
        $reader = [IO.StreamReader]::new($gzip)
        try { $json = $reader.ReadToEnd() } finally { $reader.Dispose(); $gzip.Dispose(); $compressed.Dispose() }
        }
        $report = $json | ConvertFrom-Json -AsHashtable -Depth 100
        $resultPath = Join-Path $state.runDirectory "runner-$Action-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfff')).json"
        [IO.File]::WriteAllText($resultPath,$json,[Text.UTF8Encoding]::new($false))
        if ($Action -eq 'MinimalPrompt') { Save-MinimalInvocationReport $state $attempt $resultPath $response }
        if ($Action -eq 'VerifyPrivate') {
            $addresses = @{}
            foreach ($group in $state.resourceGroups) {
                $endpoints = @(Invoke-LabAz $state @('network','private-endpoint','list','--resource-group',$group) 'private-verify-endpoints')
                foreach ($endpoint in $endpoints) {
                    Assert-LabResourceId $state $endpoint.id
                    $target = @($targets | Where-Object endpointId -eq $endpoint.id)
                    if ($endpoint.tags['fgl-owner'] -ne $state.ownershipId -or $endpoint.tags['fgl-lab'] -ne $state.labId) { throw 'Private endpoint ownership mismatch' }
                    $connections = @($endpoint.privateLinkServiceConnections)
                    if (-not $connections.Count -or @($connections | Where-Object { $_.privateLinkServiceConnectionState.status -ne 'Approved' }).Count) { throw 'Unapproved private endpoint' }
                    if ($target.Count -and ($target.Count -ne 1 -or $addresses.ContainsKey($target[0].hostName) -or $connections.Count -ne 1 -or $connections[0].privateLinkServiceId -ine $target[0].resourceId -or @($connections[0].groupIds).Count -ne 1 -or $connections[0].groupIds[0] -cne $target[0].groupId)) { throw 'Private endpoint target or approval mismatch' }
                    if (@($endpoint.networkInterfaces).Count -ne 1) { throw 'Private endpoint NIC evidence missing' }
                    $ownedIps = @()
                    foreach ($nic in $endpoint.networkInterfaces) {
                        Assert-LabResourceId $state $nic.id
                        $nicPrefix = ($endpoint.id -split '/providers/')[0] + '/providers/Microsoft.Network/networkInterfaces/'
                        if (-not $nic.id.StartsWith($nicPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Private endpoint NIC scope mismatch' }
                        $nicData = Invoke-LabAz $state @('network','nic','show','--ids',$nic.id) 'private-verify-nic'
                        if ($nicData.id -ine $nic.id -or $nicData.privateEndpoint.id -ine $endpoint.id -or -not @($nicData.ipConfigurations).Count) { throw 'Private endpoint NIC ownership mismatch' }
                        $ownedIps += @($nicData.ipConfigurations.privateIPAddress)
                    }
                    if ($target.Count) { $addresses[$target[0].hostName] = $ownedIps }
                }
            }
            Assert-LabPrivateReport $targets $report $addresses
            $gateway = Invoke-LabAz $state @('apim','show','--resource-group',$runnerGroup,'--name',(($lab.gateway -split '/')[-1])) 'private-verify-gateway'
            if ($gateway.id -ine $lab.gateway -or $gateway.tags['fgl-owner'] -ne $state.ownershipId -or $gateway.tags['fgl-lab'] -ne $state.labId -or $gateway.publicNetworkAccess -ne 'Disabled') { throw 'Owned gateway public access remains unverified' }
            $state.privateAccessVerified = $true
            $state.privateRunnerEvidence = @{path=$resultPath; sha256=(Get-FileHash $resultPath).Hash; verifiedAt=[DateTimeOffset]::UtcNow.ToString('o')}
            Save-LabRun $state $StatePath
            Write-Output "PASS: $($targets.Count) service names resolve to owned private endpoints; TCP and gateway TLS response verified; public gateway disabled."
        } else {
            $report.tests | Group-Object status | ForEach-Object { Write-Output "$($_.Name): $($_.Count)" }
            Write-Output "HTTP requests: $($report.requests); report saved outside public source."
        }
    }
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }