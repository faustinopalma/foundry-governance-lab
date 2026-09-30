[CmdletBinding()]
param(
    [string]$StatePath,
    [ValidateSet('PublicAccess', 'AfterTeardown', 'RetainedRecords')][string]$Action,
    [switch]$DefinitionsOnly
)

function Get-ExternalStatus([object[]]$Statuses) {
    if ('FAIL' -in $Statuses) { return 'FAIL' }
    if ('BLOCKED' -in $Statuses) { return 'BLOCKED' }
    if ($Statuses.Count -eq 0 -or @($Statuses | Where-Object { $_ -ne 'PASS' }).Count) { return 'INCONCLUSIVE' }
    return 'PASS'
}

function Test-ExternalPublicAddress([string]$Address) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.IsIPv4MappedToIPv6) { return Test-ExternalPublicAddress $parsed.MapToIPv4().ToString() }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -eq 4) {
        if ($bytes[0] -in @(0, 10, 127) -or $bytes[0] -ge 224) { return $false }
        if ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return $false }
        if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }
        if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $false }
        if ($bytes[0] -eq 192 -and (($bytes[1] -eq 168) -or ($bytes[1] -eq 0 -and $bytes[2] -in @(0, 2)) -or ($bytes[1] -eq 88 -and $bytes[2] -eq 99))) { return $false }
        if ($bytes[0] -eq 198 -and ($bytes[1] -in @(18, 19) -or ($bytes[1] -eq 51 -and $bytes[2] -eq 100))) { return $false }
        if ($bytes[0] -eq 203 -and $bytes[1] -eq 0 -and $bytes[2] -eq 113) { return $false }
        return $true
    }
    if (($bytes[0] -band 0xE0) -ne 0x20) { return $false }
    if ($bytes[0] -eq 0x20 -and $bytes[1] -eq 0x01 -and ($bytes[2] -lt 2 -or ($bytes[2] -eq 0x0D -and $bytes[3] -eq 0xB8))) { return $false }
    if ($bytes[0] -eq 0x20 -and $bytes[1] -eq 0x02) { return $false }
    if ($bytes[0] -eq 0x3F -and ($bytes[1] -band 0xF0) -eq 0xF0) { return $false }
    return $true
}

function Get-ExternalPlan([hashtable]$State, [hashtable]$Lab) {
    Assert-LabState $State
    if ($State.phase -ne 'activate' -or $State.pendingPhase -or $Lab.phase -ne 'activate') { throw 'Completed activation is required' }
    if (@($Lab.resourceGroups).Count -ne 4 -or @($Lab.resourceGroups | Sort-Object -Unique).Count -ne 4 -or @(Compare-Object $State.resourceGroups $Lab.resourceGroups).Count) { throw 'Output group mismatch' }
    $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)"
    $modelPrefix = "$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-$($State.labId)-models-"
    if ([string]$Lab.models -cnotmatch ('^' + [regex]::Escape($modelPrefix) + '([a-z0-9]{13})$')) { throw 'Unexpected Foundry output' }
    $suffix = $Matches[1]
    $expectedGateway = "$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-$($State.labId)-$suffix"
    if ($Lab.gateway -cne $expectedGateway -or @($Lab.cases).Count -ne 2) { throw 'Unexpected gateway or case outputs' }
    $endpoints = @(@{key='models'; provider='Foundry'; id=$Lab.models})
    foreach ($index in 0..1) {
        $case = @('a', 'b')[$index]
        $account = "$prefix-case-$case/providers/Microsoft.CognitiveServices/accounts/aif-fgl-$($State.labId)-$case-$suffix"
        $registry = "$prefix-case-$case/providers/Microsoft.ContainerRegistry/registries/crfgl$($State.labId)$case$suffix"
        if ($Lab.cases[$index].accountId -cne $account -or $Lab.cases[$index].registryId -cne $registry) { throw 'Unexpected case outputs' }
        $endpoints += @{key="case-$case"; provider='Foundry'; id=$account}
        $endpoints += @{key="registry-$case"; provider='ACR'; id=$registry}
    }
    $endpoints += @{key='gateway'; provider='APIM'; id=$Lab.gateway}
    foreach ($endpoint in $endpoints) {
        Assert-LabResourceId $State $endpoint.id
        $name = ($endpoint.id -split '/')[-1]
        $domain = switch ($endpoint.provider) { 'Foundry' { 'openai.azure.com' } 'ACR' { 'azurecr.io' } 'APIM' { 'azure-api.net' } }
        $path = switch ($endpoint.provider) { 'Foundry' { '/openai/v1/models' } 'ACR' { '/v2/' } 'APIM' { '/openai/deployments/lab-chat/chat/completions?api-version=2024-10-21' } }
        $endpoint.hostName = "$name.$domain"
        $endpoint.uri = "https://$($endpoint.hostName)$path"
        $endpoint.method = if ($endpoint.provider -eq 'APIM') { 'POST' } else { 'GET' }
        $endpoint.body = if ($endpoint.provider -eq 'APIM') { '{"messages":[],"max_tokens":1}' } else { $null }
    }
    return ,$endpoints
}

function Get-ExternalProbeVerdict([hashtable]$Probe) {
    $addresses = @($Probe.addresses)
    if ($Probe.dnsError -or $addresses.Count -eq 0 -or @($addresses | Where-Object { -not (Test-ExternalPublicAddress $_) }).Count) { return @{status='INCONCLUSIVE'; reason='DNS_NOT_ALL_PUBLIC'} }
    if ([string]$Probe.localAddress -match '^10\.76\.') { return @{status='INCONCLUSIVE'; reason='LAB_VNET_SOURCE_ADDRESS'} }
    if ($Probe.transportError -or -not $Probe.connectedAddress -or $Probe.connectedAddress -notin $addresses -or $Probe.bodyTruncated) { return @{status='INCONCLUSIVE'; reason='TRANSPORT_INCOMPLETE'} }
    $status = [int]$Probe.httpStatus
    if ($status -ge 200 -and $status -lt 300) { return @{status='FAIL'; reason='PUBLIC_HTTPS_ACCEPTED'} }
    if ($status -ne 403) { return @{status='INCONCLUSIVE'; reason='NO_EXPLICIT_NETWORK_DENIAL'} }
    try { $body = $Probe.body | ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop } catch { return @{status='INCONCLUSIVE'; reason='UNRECOGNIZED_PROVIDER_BODY'} }
    if ($body -isnot [hashtable]) { return @{status='INCONCLUSIVE'; reason='UNRECOGNIZED_PROVIDER_BODY'} }
    $messages = @()
    if ($body.error -is [hashtable]) { $messages += @{code=[string]$body.error.code; message=[string]$body.error.message} }
    if ($body.ContainsKey('statusCode') -and $body.statusCode -eq 403) { $messages += @{code='403'; message=[string]$body.message} }
    foreach ($entry in @($body.errors)) {
        if ($entry -is [hashtable]) { $messages += @{code=[string]$entry.code; message=[string]$entry.message} }
    }
    foreach ($entry in $messages) {
        $match = switch ($Probe.provider) {
            'Foundry' { $entry.code -in @('403', 'Forbidden', 'AccessDenied') -and $entry.message -match '(?i)^(Access denied due to Virtual Network/Firewall rules\.|Public (?:network )?access is disabled[.!])' }
            'APIM' {
                if ($entry.code -in @('403', 'Forbidden', 'AccessDenied') -and $entry.message -match '(?i)^(Public network access is disabled[.!]|Access denied because public network access is disabled[.!])') { $true }
                elseif ($body.statusCode -eq 403 -and $entry.message -ceq $body.message -and $entry.message -match '(?i)^Request originated from client public IP address [0-9a-f:.]+, public network access on this `Microsoft\.ApiManagement/service/(?<service>[a-z0-9][a-z0-9-]*)` is disabled\. To connect to `Microsoft\.ApiManagement/service/\k<service>`, please use the Private Endpoint from inside your virtual network\. To learn more https://aka\.ms/apim-privateendpoint ?\z') {
                    -not $Probe.hostName -or $Probe.hostName -ieq "$($Matches.service).azure-api.net"
                } else { $false }
            }
            'ACR' { $entry.code -eq 'DENIED' -and $entry.message -match '(?i)^client with IP [''\"][0-9a-f:.]+[''\"] is not allowed access[.,] Refer https://aka\.ms/acr/firewall\b' }
            default { $false }
        }
        if ($match) { return @{status='PASS'; reason='PROVIDER_EXPLICIT_NETWORK_DENIAL'} }
    }
    return @{status='INCONCLUSIVE'; reason='NO_EXPLICIT_NETWORK_DENIAL'}
}

function Get-ExternalGroup([hashtable]$State, [string]$Id) {
    $prefix = '^/subscriptions/' + [regex]::Escape($State.subscriptionId) + '/resourceGroups/([^/]+)(?:/|$)'
    if ($Id -match $prefix -and $Id -notmatch '(%|\\|\?|#|//|/\.{1,2}(/|$))') { return $Matches[1] }
    return ''
}

function Get-ExternalInventoryReport([hashtable]$State, [object[]]$Baseline, [object[]]$Groups, [object[]]$Resources) {
    Assert-LabState $State
    if (-not $State.ContainsKey('preexistingGroupIds') -or $State.preexistingGroupIds -isnot [array]) { throw 'Missing group baseline' }
    $groupIds = @($Groups | ForEach-Object { $_.id })
    $resourceIds = @($Resources | ForEach-Object { $_.id })
    foreach ($identifier in @($State.preexistingGroupIds) + @($Baseline | ForEach-Object { $_.id }) + $groupIds + $resourceIds) {
        $pattern = '^/subscriptions/' + [regex]::Escape($State.subscriptionId) + '/(?:resourceGroups/[^/]+(?:/providers/[^/]+/[^/]+/[^/]+(?:/[^/]+/[^/]+)*)?|providers/[^/]+/[^/]+/[^/]+(?:/[^/]+/[^/]+)*)$'
        if ($identifier -notmatch $pattern -or $identifier -match '(%|\\|\?|#|//|/\.{1,2}(/|$))') { throw 'Invalid inventory ID or subscription' }
    }
    foreach ($identifier in @($State.preexistingGroupIds) + $groupIds) {
        if ($identifier -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+$') { throw 'Group inventory contains a non-group ID' }
    }
    foreach ($identifiers in @(@($State.preexistingGroupIds), @($Baseline | ForEach-Object { $_.id }), $groupIds, $resourceIds)) {
        if (@($identifiers | Sort-Object -Unique).Count -ne $identifiers.Count) { throw 'Duplicate inventory IDs' }
    }
    $ownedGroups = @($State.resourceGroups | ForEach-Object { "/subscriptions/$($State.subscriptionId)/resourceGroups/$_" })
    $remainingGroups = @($groupIds | Where-Object { $_ -in $ownedGroups })
    $residuals = @($Resources | Where-Object { (Get-ExternalGroup $State $_.id) -in $State.resourceGroups -or ($_.tags -is [hashtable] -and ($_.tags['fgl-owner'] -eq $State.ownershipId -or $_.tags['fgl-lab'] -eq $State.labId)) } | ForEach-Object { $_.id })
    $baselineIds = @($Baseline | ForEach-Object { $_.id } | Where-Object { (Get-ExternalGroup $State $_) -notin $State.resourceGroups })
    $currentIds = @($resourceIds | Where-Object { (Get-ExternalGroup $State $_) -notin $State.resourceGroups })
    $removed = @($baselineIds | Where-Object { $_ -notin $currentIds })
    $added = @($currentIds | Where-Object { $_ -notin $baselineIds })
    $removedGroups = @($State.preexistingGroupIds | Where-Object { $_ -notin $groupIds })
    $addedGroups = @($groupIds | Where-Object { $_ -notin $State.preexistingGroupIds -and $_ -notin $ownedGroups })
    $absence = if ($remainingGroups.Count -or $residuals.Count) { 'FAIL' } else { 'PASS' }
    $preserved = if ($removed.Count -or $removedGroups.Count) { 'FAIL' } else { 'PASS' }
    $drift = if ($removed.Count -or $removedGroups.Count) { 'FAIL' } elseif ($added.Count -or $addedGroups.Count) { 'INCONCLUSIVE' } else { 'PASS' }
    return @{
        checks=@(@{test='EXACT-FOUR-GROUPS-AND-RESOURCES-ABSENT'; status=$absence}, @{test='BASELINE-IDS-PRESERVED'; status=$preserved}, @{test='BASELINE-ID-SET'; status=$drift})
        remainingGroupIds=$remainingGroups; residualIds=$residuals; removedResourceIds=$removed; addedResourceIds=$added; removedGroupIds=$removedGroups; addedGroupIds=$addedGroups
        configurationComparison='NOT_AVAILABLE'; comparisonScope='ARM inventory ID membership only; baseline is not a full configuration snapshot.'
    }
}

function Get-ExternalActivityReport([hashtable]$State, [object[]]$Events, [bool]$Truncated, [string]$EndTime, [bool]$VerifiedCollectionComplete = $false) {
    $start = [DateTimeOffset]::Parse($State.authorizedAt)
    $end = [DateTimeOffset]::Parse($EndTime)
    if ($start -gt $end) { throw 'Invalid activity window' }
    $prefix = "/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-$($State.labId)-"
    $deploymentIds = @('bootstrap', 'lock', 'activate' | ForEach-Object { "$prefix$_" })
    $writes = @()
    $unknown = @()
    foreach ($activityEvent in $Events) {
        $timestamp = [DateTimeOffset]::MinValue
        if ($activityEvent -isnot [hashtable] -or -not [DateTimeOffset]::TryParse([string]$activityEvent.eventTimestamp, [ref]$timestamp)) { $unknown += $activityEvent; continue }
        if ($timestamp -lt $start -or $timestamp -gt $end) { continue }
        $operation = if ($activityEvent.operationName -is [hashtable]) { [string]$activityEvent.operationName.value } else { '' }
        if (-not $operation) { $unknown += $activityEvent; continue }
        if ($operation -notmatch '(?i)/(write|delete|action)$') { continue }
        if (-not ([string]$activityEvent.resourceId).StartsWith("/subscriptions/$($State.subscriptionId)/", [StringComparison]::OrdinalIgnoreCase) -or ($activityEvent.subscriptionId -and $activityEvent.subscriptionId -ine $State.subscriptionId)) { $unknown += $activityEvent; continue }
        $writes += $activityEvent
    }
    $operatorEvidence = @($writes | Where-Object { $_.resourceId -in $deploymentIds -and $_.operationName.value -ieq 'Microsoft.Resources/deployments/write' -and $_.status -is [hashtable] -and $_.status.value -ieq 'Succeeded' -and $_.caller })
    $callers = @($operatorEvidence | ForEach-Object { ([string]$_.caller).Trim().ToLowerInvariant() } | Sort-Object -Unique)
    $operator = if ($callers.Count -eq 1) { $callers[0] } else { $null }
    $outside = @()
    $coordinator = @()
    foreach ($activityEvent in $writes) {
        if (-not $activityEvent.resourceId) { $unknown += $activityEvent; continue }
        if ((Get-ExternalGroup $State $activityEvent.resourceId) -in $State.resourceGroups) { continue }
        if ($activityEvent.resourceId -in $deploymentIds -and $activityEvent.operationName.value -in @('Microsoft.Resources/deployments/write', 'Microsoft.Resources/deployments/validate/action', 'Microsoft.Resources/deployments/whatIf/action')) { $coordinator += $activityEvent; continue }
        $outside += $activityEvent
    }
    $attributed = @($outside | Where-Object { $operator -and ([string]$_.caller).Trim() -ieq $operator })
    $unattributed = @($outside | Where-Object { -not $operator -or -not $_.caller })
    $others = @($outside | Where-Object { $operator -and $_.caller -and ([string]$_.caller).Trim() -ine $operator })
    $retentionGap = $start -lt $end.AddDays(-90)
    $Truncated = $Truncated -or (-not $VerifiedCollectionComplete -and $Events.Count -ge 5000)
    $complete = -not $Truncated -and $unknown.Count -eq 0 -and -not $retentionGap
    $status = if ($attributed.Count) { 'FAIL' } elseif (-not $complete -or -not $operator -or $unattributed.Count) { 'INCONCLUSIVE' } else { 'PASS' }
    return @{
        status=$status; complete=$complete; truncated=$Truncated; retentionGap=$retentionGap; operatorCaller=$operator; operatorEvidence=$operatorEvidence
        operatorSource='Unique caller of successful exact lab subscription deployment writes in the queried window; no saved operator identity exists in initializer state.'
        outsideOwnedGroups=$outside; attributedEvents=$attributed; otherCallerEvents=$others; unattributedEvents=$unattributed; malformedEvents=$unknown; coordinatorEvents=$coordinator
        startTime=$State.authorizedAt; endTime=$EndTime; eventCount=$Events.Count
        limitation='Activity logs can arrive late and cover control-plane events only. Caller correlation does not identify a person behind a shared principal.'
    }
}

function Initialize-ExternalTransport {
    if ('LabExternal.Transport' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace LabExternal {
    public static class Transport {
        public static SocketsHttpHandler CreateHandler() {
            return new SocketsHttpHandler {
                UseProxy = false, Proxy = null, Credentials = null, PreAuthenticate = false,
                AllowAutoRedirect = false, UseCookies = false, MaxConnectionsPerServer = 1,
                ConnectTimeout = TimeSpan.FromSeconds(20), MaxResponseHeadersLength = 64,
                AutomaticDecompression = DecompressionMethods.None
            };
        }
        public static HttpRequestMessage CreateRequest(Uri uri, string method, string body) {
            if (uri.Scheme != "https" || uri.Port != 443 || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0)
                throw new ArgumentException("Only credential-free HTTPS is allowed");
            if (method != "GET" && method != "POST") throw new ArgumentException("Unexpected method");
            var request = new HttpRequestMessage(new HttpMethod(method), uri) {
                Version = HttpVersion.Version11, VersionPolicy = HttpVersionPolicy.RequestVersionExact
            };
            request.Headers.ConnectionClose = true;
            if (body != null) request.Content = new StringContent(body, Encoding.UTF8, "application/json");
            return request;
        }
        public static async Task<Dictionary<string, object>> ReadResponseAsync(HttpResponseMessage response, CancellationToken cancellation) {
            var result = new Dictionary<string, object>();
            result["httpStatus"] = (int)response.StatusCode;
            var headers = new Dictionary<string, string[]>();
            foreach (var header in response.Headers) headers[header.Key] = new List<string>(header.Value).ToArray();
            foreach (var header in response.Content.Headers) headers[header.Key] = new List<string>(header.Value).ToArray();
            result["headers"] = headers;
            using (var stream = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false)) {
                var buffer = new byte[65537];
                int length = 0;
                while (length < buffer.Length) {
                    int count = await stream.ReadAsync(buffer.AsMemory(length, buffer.Length - length), cancellation).ConfigureAwait(false);
                    if (count == 0) break;
                    length += count;
                }
                result["bodyTruncated"] = length > 65536;
                result["body"] = Encoding.UTF8.GetString(buffer, 0, Math.Min(length, 65536));
            }
            return result;
        }
        public static async Task<string> SendAsync(Uri uri, string address, string method, string body, CancellationToken cancellation) {
            var result = new Dictionary<string, object>();
            int attempts = 0;
            using (var handler = CreateHandler()) {
                handler.ConnectCallback = async (context, token) => {
                    if (Interlocked.Increment(ref attempts) != 1) throw new IOException("Retries are disabled");
                    if (!context.DnsEndPoint.Host.Equals(uri.Host, StringComparison.OrdinalIgnoreCase) || context.DnsEndPoint.Port != 443)
                        throw new IOException("Unexpected connection destination");
                    var endpoint = new IPEndPoint(IPAddress.Parse(address), 443);
                    var socket = new Socket(endpoint.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                    try {
                        await socket.ConnectAsync(endpoint, token).ConfigureAwait(false);
                        result["connectedAddress"] = ((IPEndPoint)socket.RemoteEndPoint).Address.ToString();
                        result["localAddress"] = ((IPEndPoint)socket.LocalEndPoint).Address.ToString();
                        return new NetworkStream(socket, ownsSocket: true);
                    } catch { socket.Dispose(); throw; }
                };
                using (var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan })
                using (var request = CreateRequest(uri, method, body)) {
                    try {
                        using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false)) {
                            result["httpStatus"] = (int)response.StatusCode;
                            foreach (var item in await ReadResponseAsync(response, cancellation).ConfigureAwait(false)) result[item.Key] = item.Value;
                        }
                    } catch (Exception exception) {
                        result["transportError"] = cancellation.IsCancellationRequested ? "TIMEOUT" : exception.GetType().Name;
                        result["privateError"] = exception.ToString();
                    }
                }
            }
            result["connectionAttempts"] = attempts;
            return JsonSerializer.Serialize(result);
        }
    }
}
'@
}

function Resolve-ExternalAddresses([string]$HostName, [Threading.CancellationToken]$Cancellation) {
    return ,@([Net.Dns]::GetHostAddressesAsync($HostName, $Cancellation).GetAwaiter().GetResult() | ForEach-Object { $_.ToString() } | Select-Object -Unique)
}

function Invoke-ExternalHttp([hashtable]$Endpoint, [string]$Address, [Threading.CancellationToken]$Cancellation) {
    return ([LabExternal.Transport]::SendAsync([uri]$Endpoint.uri, $Address, $Endpoint.method, $Endpoint.body, $Cancellation).GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -Depth 50)
}

function Invoke-ExternalProbe([hashtable]$Endpoint) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(20))
    $probe = @{key=$Endpoint.key; provider=$Endpoint.provider; hostName=$Endpoint.hostName; uri=$Endpoint.uri; method=$Endpoint.method; addresses=@(); startedAt=[DateTimeOffset]::UtcNow.ToString('o')}
    try {
        try { $probe.addresses = Resolve-ExternalAddresses $Endpoint.hostName $cancellation.Token } catch { $probe.dnsError=$_.Exception.ToString() }
        if (-not $probe.dnsError -and $probe.addresses.Count -gt 0 -and @($probe.addresses | Where-Object { -not (Test-ExternalPublicAddress $_) }).Count -eq 0) {
            $http = Invoke-ExternalHttp $Endpoint $probe.addresses[0] $cancellation.Token
            foreach ($key in $http.Keys) { $probe[$key] = $http[$key] }
        }
    } catch { $probe.transportError=$_.Exception.ToString() } finally {
        $cancellation.Dispose()
        $probe.elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,3)
    }
    $probe.verdict = Get-ExternalProbeVerdict $probe
    return $probe
}

function Read-ExternalOutputs([hashtable]$State) {
    $path = Assert-ExternalLabPath (Join-Path $State.runDirectory 'outputs.json')
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Read-ExternalBaseline([hashtable]$State) {
    $files = @(Get-ChildItem -LiteralPath $State.runDirectory -Filter '*-baseline-resources.json' -File)
    if ($files.Count -ne 1 -or $files[0].Name -notmatch '^\d{8}T\d{9}-baseline-resources\.json$') { throw 'Exactly one initializer resource baseline is required' }
    $path = Assert-ExternalLabPath $files[0].FullName
    $baseline = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw) -AsHashtable -Depth 100 -NoEnumerate
    if ($baseline -isnot [array]) { throw 'Baseline must be an array, including when empty' }
    return @{path=$path; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; items=$baseline}
}

function Get-ExternalList([hashtable]$Envelope) {
    if ($Envelope.nextLink -or $Envelope.continuationToken -or $Envelope.skipToken) { throw 'Incomplete paginated inventory' }
    if ($Envelope.items -isnot [array]) { throw 'Missing or malformed inventory array' }
    return ,$Envelope.items
}

function Read-ExternalTeardownEvidence([hashtable]$State) {
    if ($State.teardownEvidence -isnot [hashtable] -or $State.teardownEvidence.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Original teardown evidence hash is required' }
    $path = Assert-ExternalLabPath $State.teardownEvidence.path
    $bytes = [IO.File]::ReadAllBytes($path)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if ($hash -ine $State.teardownEvidence.sha256) { throw 'Original teardown evidence hash mismatch' }
    $snapshot = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 100
    if ($snapshot -isnot [hashtable]) { throw 'Invalid teardown evidence' }
    return @{path=$path; sha256=$hash; snapshot=$snapshot}
}

function Get-ExternalRetainedPlan([hashtable]$State, [hashtable]$Lab, [hashtable]$Evidence) {
    Assert-LabState $State
    if ($State.phase -ne 'destroyed' -or $State.pendingPhase) { throw 'Reconciled destroyed state is required' }
    if ($State.teardownEvidence.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $Evidence.sha256 -ine $State.teardownEvidence.sha256) { throw 'Original teardown evidence hash mismatch' }
    $snapshot = $Evidence.snapshot
    $resources = Get-ExternalList @{items=$snapshot.resources}
    $groups = Get-ExternalList @{items=$snapshot.groups}
    if (-not $resources.Count -or $groups.Count -ne 4 -or @($groups.id | Sort-Object -Unique).Count -ne 4) { throw 'Incomplete teardown snapshot' }
    foreach ($group in $groups) {
        Assert-LabGroupOwnership $State $group
        if ($group.id -in $State.preexistingGroupIds) { throw 'Pre-existing group cannot be adopted' }
    }
    foreach ($resource in $resources) {
        if ($resource -isnot [hashtable] -or $resource.id -isnot [string] -or $resource.type -isnot [string]) { throw 'Malformed snapshot resource' }
        Assert-LabResourceId $State $resource.id
        if (($resource.id -split '(?i)/providers/')[0] -notin $groups.id) { throw 'Snapshot resource has no captured parent group' }
        if ($resource.tags -and ($resource.tags -isnot [hashtable] -or ($resource.tags.ContainsKey('fgl-owner') -and $resource.tags['fgl-owner'] -ne $State.ownershipId) -or ($resource.tags.ContainsKey('fgl-lab') -and $resource.tags['fgl-lab'] -ne $State.labId))) { throw 'Snapshot resource ownership conflict' }
    }
    if (@($resources.id | Sort-Object -Unique).Count -ne $resources.Count) { throw 'Duplicate snapshot IDs' }
    $activationState = $State.Clone()
    $activationState.phase = 'activate'
    $outputs = Get-ExternalPlan $activationState $Lab
    $plan = @(
        @{key='Foundry'; type='Microsoft.CognitiveServices/accounts'; targetIds=@($outputs | Where-Object provider -eq 'Foundry' | ForEach-Object id); count=3},
        @{key='APIM'; type='Microsoft.ApiManagement/service'; targetIds=@($Lab.gateway); count=1},
        @{key='LAW'; type='Microsoft.OperationalInsights/workspaces'; targetIds=@($resources | Where-Object type -eq 'Microsoft.OperationalInsights/workspaces' | ForEach-Object id); count=3}
    )
    foreach ($entry in $plan) {
        $captured = @($resources | Where-Object type -eq $entry.type | ForEach-Object id)
        if ($captured.Count -ne $entry.count -or $entry.targetIds.Count -ne $entry.count -or @(Compare-Object $captured $entry.targetIds).Count) { throw 'Output targets must match original snapshot IDs and cardinality' }
        $pattern = '^/subscriptions/' + [regex]::Escape($State.subscriptionId) + '/resourceGroups/[^/]+/providers/' + [regex]::Escape($entry.type) + '/[^/]+$'
        if (@($captured | Where-Object { $_ -notmatch $pattern }).Count) { throw 'Snapshot resource type and original ID mismatch' }
    }
    $rootNames = @('bootstrap', 'lock', 'activate' | ForEach-Object { "fgl-$($State.labId)-$_" })
    if ($State.deploymentName -and $State.deploymentName -notin $rootNames) { throw 'Unknown root deployment name' }
    $plan += @{key='RootDeployments'; type='Microsoft.Resources/deployments'; targetIds=@($rootNames | ForEach-Object { "/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/$_" }); count=3}
    return ,$plan
}

function Get-ExternalRetainedListReport([hashtable]$State, [hashtable]$Target, [hashtable]$Envelope) {
    $result = @{status='INCONCLUSIVE'; complete=$false; targetCount=$Target.count; matchedIds=@(); reason='INCOMPLETE_LIST'}
    try { $items = Get-ExternalList $Envelope } catch { return $result }
    if ($items.Count -gt 10000) { $result.reason='RECORD_BUDGET'; return $result }
    $pattern = '^/subscriptions/' + [regex]::Escape($State.subscriptionId)
    $pattern += if ($Target.key -eq 'RootDeployments') { '/providers/' } else { '/resourceGroups/[^/]+/providers/' }
    $pattern += [regex]::Escape($Target.type) + '/[^/]+$'
    $deletedAccountPattern = '^/subscriptions/(?<subscription>[^/\s]+)/providers/Microsoft\.CognitiveServices/locations/(?<location>[^/\s]+)/resourceGroups/(?<group>[^/\s]+)/deletedAccounts/(?<name>[a-z0-9][a-z0-9_.-]{1,63})\z'
    $seen = @{}
    $ambiguous = $false
    foreach ($item in $items) {
        if ($item -isnot [hashtable]) { $ambiguous=$true; continue }
        $identifier = $item.id
        if ($Target.key -eq 'APIM') {
            if ($null -ne $item.properties -and $item.properties -isnot [hashtable]) { $ambiguous=$true; continue }
            $hasServiceId = $item.ContainsKey('serviceId')
            $hasNestedServiceId = $item.properties -is [hashtable] -and $item.properties.ContainsKey('serviceId')
            if ($hasServiceId -and $hasNestedServiceId -and ($item.serviceId -isnot [string] -or $item.properties.serviceId -isnot [string] -or $item.serviceId -ine $item.properties.serviceId)) { $ambiguous=$true; continue }
            $identifier = if ($hasServiceId) { $item.serviceId } elseif ($hasNestedServiceId) { $item.properties.serviceId } else { $null }
        } elseif ($Target.key -eq 'Foundry' -and $identifier -is [string] -and $identifier -match $deletedAccountPattern) {
            $deletedParts = $Matches.Clone()
            if ($identifier -match '(%|\\|\?|#|//|/\.{1,2}(/|$))' -or $item.name -isnot [string] -or $item.name -cne $deletedParts.name) { $ambiguous=$true; continue }
            if ($item.ContainsKey('location') -and ($item.location -isnot [string] -or $item.location -ine $deletedParts.location)) { $ambiguous=$true; continue }
            $identifier = "/subscriptions/$($deletedParts.subscription)/resourceGroups/$($deletedParts.group)/providers/Microsoft.CognitiveServices/accounts/$($deletedParts.name)"
        }
        if ($identifier -isnot [string] -or $identifier -notmatch $pattern -or $identifier -match '(%|\\|\?|#|//|/\.{1,2}(/|$))') { $ambiguous=$true; continue }
        if ($seen.ContainsKey($identifier)) { $ambiguous=$true; continue }
        $seen[$identifier]=$true
        if ($Target.key -eq 'RootDeployments' -and ($identifier -notin $Target.targetIds -or $item.name -cne ($identifier -split '/')[-1])) { $ambiguous=$true; continue }
        if ($identifier -in $Target.targetIds) { $result.matchedIds += $identifier }
    }
    $result.complete = -not $ambiguous
    $result.status = if ($ambiguous) { 'INCONCLUSIVE' } else { 'PASS' }
    $result.reason = if ($ambiguous) { 'AMBIGUOUS_OR_DUPLICATE_OR_WRONG_SCOPE_RECORD' } else { 'OBSERVED_COUNTS_ONLY' }
    return $result
}

function Invoke-ExternalRetainedRead([hashtable]$State, [string[]]$Arguments, [string]$Label) {
    $job = Start-Job -ScriptBlock {
        param($RunState, $CommandArguments, $CommandLabel, $ModulePath)
        $ErrorActionPreference = 'Stop'
        Import-Module $ModulePath
        Invoke-LabAz -State $RunState -Arguments $CommandArguments -Label $CommandLabel
    } -ArgumentList $State, $Arguments, $Label, (Join-Path $PSScriptRoot 'LabExecution.psm1')
    try {
        if (-not (Wait-Job -Job $job -Timeout 60)) { throw 'Bounded read exceeded 60 seconds; no partial result accepted' }
        if ($job.State -ne 'Completed') { throw 'Bounded read did not complete' }
        $received = Receive-Job -Job $job -ErrorAction Stop
        return (ConvertTo-Json -InputObject $received -Depth 100 -ErrorAction Stop -WarningAction Stop | ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate -ErrorAction Stop)
    } finally {
        if ($job.State -eq 'Running') { Stop-Job -Job $job }
        Remove-Job -Job $job -Force
    }
}

function Get-ExternalActivityCollection([hashtable]$State, [string]$EndTime) {
    $start = [DateTimeOffset]::Parse($State.authorizedAt)
    $end = [DateTimeOffset]::Parse($EndTime)
    if ($start -gt $end -or $end -gt [DateTimeOffset]::UtcNow) { throw 'Invalid activity collection window' }
    $pending = [Collections.Generic.Stack[hashtable]]::new()
    $pending.Push(@{startTime=$State.authorizedAt; endTime=$EndTime})
    $windows = [Collections.Generic.List[object]]::new()
    $seen = @{}
    $leafIds = @{}
    $sourceCount = 0
    $duplicates = 0
    $conflicts = 0
    $invalid = 0
    $budgetReason = ''
    while ($pending.Count) {
        if ($windows.Count -ge 32) { $budgetReason='CALL_BUDGET'; break }
        if ($sourceCount -gt (100000 - 5000)) { $budgetReason='EVENT_BUDGET'; break }
        $window = $pending.Pop()
        $window.call = $windows.Count + 1
        $window.sourceEventCount = 0
        $window.complete = $false
        $window.truncated = $true
        $window.split = $false
        $window.duplicateEventCount = 0
        $windows.Add($window)
        try {
            $windowStart = [DateTimeOffset]::Parse($window.startTime)
            $windowEnd = [DateTimeOffset]::Parse($window.endTime)
            $arguments = @('monitor', 'activity-log', 'list', '--start-time', $window.startTime, '--end-time', $window.endTime, '--max-events', '5000', '--resource-group', '', '--query', '{items:@}')
            $envelope = Invoke-ExternalRetainedRead $State $arguments ('external-activity-{0:d2}' -f $window.call)
            $window.raw = $envelope
            if ($envelope -isnot [hashtable]) { throw 'Missing activity envelope' }
            $page = $envelope
            $events = $envelope.items
            if ($events -is [hashtable]) { $page=$events; $events=$page.value }
            if ($events -isnot [array]) { throw 'Missing activity event array' }
            $window.sourceEventCount = $events.Count
            $sourceCount += $events.Count
            if ($events.Count -gt 5000) { throw 'Activity read exceeded requested event limit' }
            $continuation = [bool]($envelope.nextLink -or $envelope.continuationToken -or $envelope.skipToken -or $page.nextLink -or $page.continuationToken -or $page.skipToken)
            $window.truncated = $continuation -or $events.Count -ge 5000
            $valid = $true
            foreach ($activityEvent in $events) {
                $identifier = [guid]::Empty
                $timestamp = [DateTimeOffset]::MinValue
                $rawTimestamp = if ($activityEvent -is [hashtable]) { $activityEvent.eventTimestamp } else { $null }
                $timestampText = if ($rawTimestamp -is [DateTimeOffset] -or ($rawTimestamp -is [DateTime] -and $rawTimestamp.Kind -ne [DateTimeKind]::Unspecified)) { $rawTimestamp.ToString('o') } elseif ($rawTimestamp -is [string]) { $rawTimestamp } else { '' }
                if ($activityEvent -isnot [hashtable] -or $activityEvent.eventDataId -isnot [string] -or -not [guid]::TryParseExact($activityEvent.eventDataId, 'D', [ref]$identifier) -or $identifier -eq [guid]::Empty -or $timestampText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$' -or -not [DateTimeOffset]::TryParse($timestampText, [ref]$timestamp) -or $timestamp -lt $windowStart -or $timestamp -gt $windowEnd -or ($activityEvent.subscriptionId -and $activityEvent.subscriptionId -ine $State.subscriptionId)) {
                    $invalid++; $valid=$false; continue
                }
                $key = $identifier.ToString('D')
                $comparable = $activityEvent.Clone()
                $comparable.eventDataId = $key
                $comparable.eventTimestamp = $timestamp.ToUniversalTime().ToString('o')
                $json = ConvertTo-Json -InputObject $comparable -Depth 100 -Compress -WarningAction Stop -ErrorAction Stop
                if ($seen.ContainsKey($key)) {
                    $duplicates++; $window.duplicateEventCount++
                    if ($seen[$key].json -cne $json) {
                        $previousNode = [Text.Json.Nodes.JsonNode]::Parse($seen[$key].json, $null, [Text.Json.JsonDocumentOptions]::new())
                        $currentNode = [Text.Json.Nodes.JsonNode]::Parse($json, $null, [Text.Json.JsonDocumentOptions]::new())
                        if (-not [Text.Json.Nodes.JsonNode]::DeepEquals($previousNode, $currentNode)) { $conflicts++; $valid=$false }
                    }
                } else { $seen[$key]=@{event=$comparable; json=$json} }
                if (-not $window.truncated) { $leafIds[$key]=$true }
            }
            if (-not $valid) { throw 'Invalid activity identity, timestamp, scope or conflicting duplicate' }
            if ($continuation) { throw 'Activity continuation is not followed' }
            if ($window.truncated) {
                $halfTicks = [long][math]::Floor(($windowEnd - $windowStart).Ticks / 2)
                if ($halfTicks -lt 1) { throw 'Saturated activity interval cannot be split further' }
                $midpoint = $windowStart.AddTicks($halfTicks).ToString('o')
                $pending.Push(@{startTime=$midpoint; endTime=$window.endTime})
                $pending.Push(@{startTime=$window.startTime; endTime=$midpoint})
                $window.split = $true
            } else { $window.complete=$true }
        } catch { $window.error=$_.Exception.ToString() }
    }
    $uncovered = $seen.Count - $leafIds.Count
    $truncated = $pending.Count -gt 0 -or @($windows | Where-Object { -not $_.split -and $_.truncated }).Count -gt 0
    $complete = $windows.Count -gt 0 -and -not $truncated -and @($windows | Where-Object error).Count -eq 0 -and $uncovered -eq 0
    return @{
        events=@($seen.Values | ForEach-Object { $_.event }); windows=$windows.ToArray(); complete=$complete; truncated=$truncated
        calls=$windows.Count; windowCount=$windows.Count; completeWindowCount=@($windows | Where-Object complete).Count; pendingWindowCount=$pending.Count
        eventCount=$seen.Count; sourceEventCount=$sourceCount; duplicateEventCount=$duplicates; conflictCount=$conflicts; invalidEventCount=$invalid; uncoveredEventCount=$uncovered
        callBudget=32; timeoutSecondsPerRead=60; maximumEventsPerRead=5000; maximumSourceEvents=100000; budgetReason=$budgetReason
    }
}

function Get-ExternalReport([hashtable]$State, [string]$Mode) {
    $report = @{schemaVersion=1; action=$Mode; startedAt=[DateTimeOffset]::UtcNow.ToString('o'); checks=@(); probes=@(); errors=@(); limitations=@()}
    try {
        Assert-LabState $State
        if ($Mode -notin @('PublicAccess', 'AfterTeardown', 'RetainedRecords')) { throw 'Unknown external action' }
        if ($Mode -eq 'PublicAccess') {
            $plan = Get-ExternalPlan $State (Read-ExternalOutputs $State)
            $report.checks += @{test='LIFECYCLE'; status='PASS'}
            Initialize-ExternalTransport
            foreach ($endpoint in $plan) {
                $probe = Invoke-ExternalProbe $endpoint
                $report.probes += $probe
                $report.checks += @{test="PUBLIC-$($endpoint.key)"; status=$probe.verdict.status}
            }
            $report.transport = @{authentication='None'; noProxy=$true; timeoutSeconds=20; maximumRedirects=0; retryCount=0; requestBudget=6; dnsPinned=$true; tlsCertificateValidation=$true}
            $report.limitations += 'Run on the operator outside the lab VNet. Public DNS and a pinned public peer establish the observed public route, not the physical location of the operator.'
            $report.limitations += 'One public IP and one service route per output resource are sampled; other service aliases and all DNS addresses are not exhaustively probed.'
        } elseif ($Mode -eq 'RetainedRecords') {
            if ($State.phase -ne 'destroyed' -or $State.pendingPhase -or -not $State.destroyedAt) { throw 'Reconciled destroyed state is required' }
            $start = [DateTimeOffset]::Parse($State.authorizedAt)
            $destroyed = [DateTimeOffset]::Parse($State.destroyedAt)
            if ($start -gt $destroyed -or $destroyed -gt [DateTimeOffset]::UtcNow) { throw 'Invalid lifecycle timestamps' }
            $report.checks += @{test='LIFECYCLE'; status='PASS'}
            $evidence = Read-ExternalTeardownEvidence $State
            $targets = Get-ExternalRetainedPlan $State (Read-ExternalOutputs $State) $evidence
            $report.snapshot=@{path=$evidence.path; sha256=$evidence.sha256; resourceCount=$evidence.snapshot.resources.Count}
            $report.checks += @{test='RETAINED-SNAPSHOT'; status='PASS'}
            $context = Invoke-ExternalRetainedRead $State @('account', 'show') 'external-retained-context'
            Assert-LabContext $State $context
            if ($context.environmentName -ne 'AzureCloud') { throw 'Public Azure cloud context required' }
            $report.checks += @{test='CONTEXT'; status='PASS'}
            $rootNames = @($targets[-1].targetIds | ForEach-Object { ($_ -split '/')[-1] })
            $filter = ($rootNames | ForEach-Object { "name=='$_'" }) -join ' || '
            $commands = @{
                Foundry=@('cognitiveservices', 'account', 'list-deleted', '--query', '{items:@}')
                APIM=@('apim', 'deletedservice', 'list', '--query', '{items:@}')
                LAW=@('rest', '--method', 'GET', '--url', "https://management.azure.com/subscriptions/$($State.subscriptionId)/providers/Microsoft.OperationalInsights/deletedWorkspaces?api-version=2022-10-01", '--query', '{items:value,nextLink:nextLink,continuationToken:continuationToken,skipToken:skipToken}')
                RootDeployments=@('deployment', 'sub', 'list', '--query', "{items:[?$filter],nextLink:nextLink,continuationToken:continuationToken,skipToken:skipToken}")
            }
            $report.retainedRecords=@{}
            foreach ($target in $targets) {
                try {
                    $envelope = Invoke-ExternalRetainedRead $State $commands[$target.key] "external-retained-$($target.key)"
                    if ($envelope -isnot [hashtable]) { throw 'Retained list response is not an envelope' }
                    $result = Get-ExternalRetainedListReport $State $target $envelope
                } catch {
                    $result=@{status='INCONCLUSIVE'; complete=$false; targetCount=$target.count; matchedIds=@(); reason='READ_UNAVAILABLE'}
                    $report.errors += $_.Exception.ToString()
                }
                $report.retainedRecords[$target.key]=$result
                $report.checks += @{test="RETAINED-$($target.key)"; status=$result.status}
            }
            $report.collection=@{commandBudget=5; timeoutSecondsPerCommand=60; maximumRecordsPerList=10000; additionalAttempts=0}
            $report.limitations += 'Optional observation after AfterTeardown; does not change its inventory, activity or absence checks. No purge, restore or Azure mutation is performed.'
            $report.limitations += 'Counts match original ARM IDs from hash-verified teardown evidence and preserved outputs; root history is limited to the exact bootstrap, lock and activate subscription deployment IDs.'
            $report.limitations += 'PASS means the returned lists could be classified, not that records must be retained. Zero is an observation, not proof of purge, supported soft deletion, recoverability or a retention guarantee.'
            $report.limitations += 'CLI paging occurs within each timed command. Visible continuation markers, unknown original-ID shapes, duplicate IDs, wrong subscription responses and read failures are inconclusive; lists are not an atomic snapshot.'
        } else {
            if ($State.phase -ne 'destroyed' -or $State.pendingPhase -or -not $State.destroyedAt) { throw 'Reconciled destroyed state is required' }
            $start = [DateTimeOffset]::Parse($State.authorizedAt)
            $destroyed = [DateTimeOffset]::Parse($State.destroyedAt)
            $end = [DateTimeOffset]::UtcNow
            if ($start -gt $destroyed -or $destroyed -gt $end) { throw 'Invalid lifecycle timestamps' }
            $report.checks += @{test='LIFECYCLE'; status='PASS'}
            $context = Invoke-LabAz $State @('account', 'show') 'external-context'
            Assert-LabContext $State $context
            if ($context.environmentName -ne 'AzureCloud') { throw 'Public Azure cloud context required' }
            $report.context=$context
            $report.checks += @{test='CONTEXT'; status='PASS'}
            try {
                $groups = Invoke-LabAz $State @('group', 'list', '--query', '{items:@}') 'external-groups'
                $resources = Invoke-LabAz $State @('resource', 'list', '--resource-group', '', '--query', '{items:@}') 'external-resources'
                $report.groups=$groups
                $report.resources=$resources
                $groupItems = Get-ExternalList $groups
                $resourceItems = Get-ExternalList $resources
                $absence = Get-ExternalInventoryReport $State @() $groupItems $resourceItems
                $report.checks += $absence.checks[0]
                $report.absence=@{remainingGroupIds=$absence.remainingGroupIds; residualIds=$absence.residualIds}
                $baseline = Read-ExternalBaseline $State
                $report.baseline=@{path=$baseline.path; sha256=$baseline.sha256; resourceCount=$baseline.items.Count}
                $report.inventory=Get-ExternalInventoryReport $State $baseline.items $groupItems $resourceItems
                $report.checks += $report.inventory.checks[1..2]
            } catch {
                $report.checks += @{test='INVENTORY-EVIDENCE'; status='INCONCLUSIVE'}
                $report.errors += $_.Exception.ToString()
            }
            try {
                $endTime = [DateTimeOffset]::UtcNow.ToString('o')
                $activity = Get-ExternalActivityCollection $State $endTime
                $report.rawActivity=$activity
                $report.activity=Get-ExternalActivityReport $State $activity.events $activity.truncated $endTime -VerifiedCollectionComplete $activity.complete
                if (-not $activity.complete) {
                    $report.activity.complete=$false
                    if ($report.activity.status -eq 'PASS' -or $activity.conflictCount) { $report.activity.status='INCONCLUSIVE' }
                }
                $report.checks += @{test='OUTSIDE-LAB-ACTIVITY'; status=$report.activity.status}
            } catch {
                $report.checks += @{test='OUTSIDE-LAB-ACTIVITY'; status='INCONCLUSIVE'}
                $report.errors += $_.Exception.ToString()
            }
            $report.limitations += 'Baseline comparison covers ARM resource and group ID membership only, not significant configuration, deleted-and-recreated resources, or data-plane state.'
            $report.limitations += 'Group and resource inventory reads are not an atomic snapshot.'
            $report.limitations += 'Activity attribution needs one unique caller on successful exact lab deployment writes; missing or ambiguous attribution and truncated logs are inconclusive.'
            $report.limitations += 'Exact lab subscription deployment write, validate and what-if events are recorded separately as coordinator operations; they are not out-of-scope mutations.'
            $report.limitations += 'Activity logs may arrive late, have 90-day retention, and cannot distinguish people sharing a principal. Results cover only the queried interval and returned control-plane events.'
            $report.limitations += 'Soft-deleted service records and subscription deployment history are not ARM inventory residuals and are not purged.'
        }
    } catch {
        $report.checks += @{test='PREREQUISITES'; status='BLOCKED'}
        $report.errors += $_.Exception.ToString()
    }
    $report.status=Get-ExternalStatus @($report.checks.status)
    $report.completedAt=[DateTimeOffset]::UtcNow.ToString('o')
    return $report
}

function ConvertTo-ExternalSummary([hashtable]$Report) {
    $allowedTests = @('LIFECYCLE', 'CONTEXT', 'PREREQUISITES', 'INVENTORY-EVIDENCE', 'EXACT-FOUR-GROUPS-AND-RESOURCES-ABSENT', 'BASELINE-IDS-PRESERVED', 'BASELINE-ID-SET', 'OUTSIDE-LAB-ACTIVITY', 'REPORT-WRITE') + @('models', 'case-a', 'case-b', 'registry-a', 'registry-b', 'gateway' | ForEach-Object { "PUBLIC-$_" })
    if ($Report.action -eq 'RetainedRecords') { $allowedTests += @('SNAPSHOT', 'Foundry', 'APIM', 'LAW', 'RootDeployments' | ForEach-Object { "RETAINED-$_" }) }
    $checks = @($Report.checks | ForEach-Object {
        if ($_.test -notin $allowedTests -or $_.status -notin @('PASS', 'FAIL', 'INCONCLUSIVE', 'BLOCKED')) { throw 'Unsafe summary check' }
        @{test=$_.test; status=$_.status}
    })
    $probes = @($Report.probes | ForEach-Object {
        if ("PUBLIC-$($_.key)" -notin $allowedTests) { throw 'Unsafe probe key' }
        $evidence = (Get-ExternalProbeVerdict $_).reason
        @{test="PUBLIC-$($_.key)"; evidence=$evidence; httpStatus=[int]$_.httpStatus; dnsAddressCount=@($_.addresses).Count; dnsAllPublic=(@($_.addresses).Count -gt 0 -and @($_.addresses | Where-Object { -not (Test-ExternalPublicAddress $_) }).Count -eq 0); elapsedSeconds=[double]$_.elapsedSeconds}
    })
    $summary = @{schemaVersion=1; action=$Report.action; status=(Get-ExternalStatus @($checks.status)); checks=$checks; probes=$probes}
    if ($Report.action -eq 'AfterTeardown') {
        $summary.configurationComparison='NOT_AVAILABLE'
        if ($Report.absence) { $summary.absence=@{remainingGroups=@($Report.absence.remainingGroupIds).Count; residualResources=@($Report.absence.residualIds).Count} }
        if ($Report.inventory) {
            $summary.inventory=@{remainingGroups=@($Report.inventory.remainingGroupIds).Count; residualResources=@($Report.inventory.residualIds).Count; addedResources=@($Report.inventory.addedResourceIds).Count; removedResources=@($Report.inventory.removedResourceIds).Count; addedGroups=@($Report.inventory.addedGroupIds).Count; removedGroups=@($Report.inventory.removedGroupIds).Count}
        }
        if ($Report.activity) { $summary.activity=@{eventCount=$Report.activity.eventCount; complete=$Report.activity.complete; truncated=$Report.activity.truncated; retentionGap=$Report.activity.retentionGap; operatorAttributed=[bool]$Report.activity.operatorCaller; coordinatorEventCount=@($Report.activity.coordinatorEvents).Count; malformedEventCount=@($Report.activity.malformedEvents).Count; attributedCount=@($Report.activity.attributedEvents).Count; otherCallerCount=@($Report.activity.otherCallerEvents).Count; unattributedCount=@($Report.activity.unattributedEvents).Count} }
        if ($Report.rawActivity) {
            $summary.activityCollection=@{complete=[bool]$Report.rawActivity.complete; truncated=[bool]$Report.rawActivity.truncated}
            foreach ($key in @('calls', 'windowCount', 'completeWindowCount', 'pendingWindowCount', 'eventCount', 'sourceEventCount', 'duplicateEventCount', 'conflictCount', 'invalidEventCount', 'uncoveredEventCount', 'callBudget', 'timeoutSecondsPerRead', 'maximumEventsPerRead', 'maximumSourceEvents')) {
                $summary.activityCollection[$key]=[int]$Report.rawActivity[$key]
            }
        }
    }
    $summary.scope = if ($Report.action -eq 'PublicAccess') { 'Six operator-side public-route samples; physical outside-VNet location is not attested.' } else { 'ID membership and returned control-plane events only; no configuration-equivalence or data-plane claim.' }
    if ($Report.action -eq 'RetainedRecords') {
        $summary.scope='Owned retained-record counts only; PASS is list completeness, not a retention guarantee. Zero does not prove purge or recoverability. Independent of AfterTeardown.'
        if ($Report.snapshot) { $summary.snapshotResourceCount=[int]$Report.snapshot.resourceCount }
        $summary.retainedRecords=@{}
        foreach ($key in @('Foundry', 'APIM', 'LAW', 'RootDeployments')) {
            if ($Report.retainedRecords -and $Report.retainedRecords.ContainsKey($key)) {
                $result=$Report.retainedRecords[$key]
                if ($result.status -notin @('PASS', 'INCONCLUSIVE') -or $result.complete -isnot [bool]) { throw 'Unsafe retained summary' }
                $summary.retainedRecords[$key]=@{status=$result.status; complete=$result.complete; targetCount=[int]$result.targetCount; observedCount=@($result.matchedIds).Count}
            }
        }
    }
    Assert-PublicText ($summary | ConvertTo-Json -Depth 30)
    return $summary
}

function Save-ExternalReport([hashtable]$State, [hashtable]$Report) {
    $stamp=[DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffff')
    $prefix="external-$($Report.action)-$stamp"
    $privatePath=Assert-ExternalLabPath (Join-Path $State.runDirectory "$prefix.private.json")
    $summaryPath=Assert-ExternalLabPath (Join-Path $State.runDirectory "$prefix.summary.json")
    $summary=ConvertTo-ExternalSummary $Report
    [IO.File]::WriteAllText($privatePath, ($Report | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    return $summary
}

if ($DefinitionsOnly) { return }
$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
    if (-not $StatePath -or -not $Action) { throw 'StatePath and Action are required' }
    $state = Read-LabRun $StatePath
    $report = Get-ExternalReport $state $Action
    try { $summary = Save-ExternalReport $state $report } catch {
        $report.checks += @{test='REPORT-WRITE'; status='BLOCKED'}
        $summary = ConvertTo-ExternalSummary $report
    }
    Write-Output ($summary | ConvertTo-Json -Depth 30)
} catch {
    Write-Output (@{schemaVersion=1; status='BLOCKED'; checks=@(@{test='PREREQUISITES'; status='BLOCKED'})} | ConvertTo-Json -Depth 10)
} finally {
    Write-Host "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}