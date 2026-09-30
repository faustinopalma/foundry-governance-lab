<#
.SYNOPSIS
Push and pull a fixed scratch OCI fixture with the two private lab publishers.
.DESCRIPTION
Requires PowerShell Core 7.4+, RunLive, external StatePath and OutputsPath, and a new external ResultsPath with an existing parent directory. Without RunLive there is no file, DNS or HTTP I/O.
Requires activated, deployment-authorized, privateAccessVerified state and the existing two private Premium ACR registries in AbacRepositoryPermissions mode, ARM-audience authentication disabled, and publisher-a/b UAMIs attached to the private runner. Each publisher needs only Container Registry Repository Writer conditioned on its own case-a/test or case-b/test repository. Registry configuration and role assignments are preconditions, not revalidated with operator credentials here.
At most 40 combined HTTP requests (including IMDS) and explicit DNS resolutions. Registry HTTP uses HttpClient with a 20-second deadline including body reads, a 65,536-byte response limit, and no automatic redirects, proxy, cookies or retries. Only same-host HTTPS upload Locations are accepted. A config GET may follow one HTTP 307 to the exact Sweden Central dedicated data host derived from the registry label, HTTPS/443, root path and nine unique query keys t,h,c,r,d,p,s,v,l within 2,048 query characters, without Authorization. All data-host DNS answers must be RFC1918; this is not private endpoint ownership proof. IMDS retains 20-second connection and per-read timeouts.
The fixture is an empty filesystem (zero layers), one config and one manifest, without an executable. The fixed fgl-fixture tag is reserved for this test and may be overwritten. No image is executed; this is not hosted-agent or project-identity proof. Artifacts remain in the owned registry until lab resource-group teardown; no DELETE permissions are needed.
Sources verified 2026-09-20:
https://github.com/Azure/acr/blob/main/docs/AAD-OAuth.md
https://learn.microsoft.com/azure/container-registry/container-registry-rbac-abac-repository-permissions
https://github.com/opencontainers/distribution-spec/blob/v1.1.0/spec.md
https://github.com/opencontainers/image-spec/blob/v1.1.0/config.md
https://github.com/opencontainers/oci-conformance/blob/main/distribution-spec/v1.1/azurecontainerregistry/report.html
#>
[CmdletBinding()]
param([string]$StatePath, [string]$OutputsPath, [string]$ResultsPath, [switch]$RunLive)

function Use-RegistryRequestBudget {
    param([hashtable]$Budget, [switch]$Dns)

    if ($Budget.requests + $Budget.dnsQueries -ge 40) { throw 'HTTP and DNS operation budget exhausted' }
    if ($Dns) { $Budget.dnsQueries++ } else { $Budget.requests++ }
}

function Get-RegistryDigest {
    param([byte[]]$Bytes)

    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function New-RegistryFixture {
    $config = [ordered]@{architecture='amd64'; os='linux'; config=[ordered]@{}; rootfs=[ordered]@{type='layers'; diff_ids=@()}}
    $configBytes = [Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json -Depth 8 -Compress))
    $configDigest = Get-RegistryDigest $configBytes
    $manifest = [ordered]@{
        schemaVersion=2; mediaType='application/vnd.oci.image.manifest.v1+json'
        config=[ordered]@{mediaType='application/vnd.oci.image.config.v1+json'; digest=$configDigest; size=$configBytes.Length}
        layers=@()
    }
    $manifestBytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 8 -Compress))
    return @{configBytes=$configBytes; configDigest=$configDigest; manifestBytes=$manifestBytes; manifestDigest=(Get-RegistryDigest $manifestBytes); tag='fgl-fixture'}
}

function Resolve-RegistryUploadLocation {
    param([string]$Location, [string]$HostName, [string]$Repository, [string]$Digest)

    if ($HostName -cnotmatch '^[a-z0-9]{5,50}\.azurecr\.io$' -or $Repository -cnotin @('case-a/test', 'case-b/test') -or $Digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Invalid upload target' }
    if (-not $Location -or $Location.Length -gt 2048 -or $Location -match '[\s\\#]') { throw 'Invalid upload Location' }
    $pattern = '^(?:https://' + [regex]::Escape($HostName) + ')?(/v2/' + [regex]::Escape($Repository) + '/blobs/uploads/[a-zA-Z0-9_-]{1,128})(\?[^#]+)?$'
    if ($Location -cnotmatch $pattern) { throw 'Upload Location escaped the exact registry or repository' }
    $queryText = $Matches[2]
    if ($queryText) {
        if ($queryText -match '%(?![0-9a-fA-F]{2})') { throw 'Malformed upload query encoding' }
        $queryParameters = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($parameter in $queryText.Substring(1).Split('&')) {
            $parts = $parameter.Split('=', 2)
            if ($parts.Count -ne 2 -or $parts[0] -cnotin @('_state', '_nouploadcache') -or -not $queryParameters.TryAdd($parts[0], $parts[1])) { throw 'Unsupported or duplicate upload query parameter' }
            if ($parts[0] -ceq '_nouploadcache') {
                if ($parts[1] -cnotin @('true', 'false')) { throw 'Invalid upload cache flag' }
            } else {
                if ($parts[1] -cnotmatch '\A[a-zA-Z0-9._~%+/-]{1,1536}={0,2}\z' -or [uri]::UnescapeDataString($parts[1]) -cnotmatch '\A[a-zA-Z0-9._~+/-]{1,1536}={0,2}\z') { throw 'Unsupported upload state query' }
            }
        }
        if (-not $queryParameters.ContainsKey('_state')) { throw 'Upload state query required' }
    }
    $absolute = if ($Location.StartsWith('/')) { "https://$HostName$Location" } else { $Location }
    $target = [uri]$absolute
    if ($target.Scheme -cne 'https' -or $target.Host -cne $HostName -or $target.Port -ne 443 -or $target.UserInfo -or $target.Fragment) { throw 'Unsafe upload URI' }
    $separator = if ($queryText) { '&' } else { '?' }
    return $absolute + $separator + 'digest=' + [uri]::EscapeDataString($Digest)
}

function Resolve-RegistryDataLocation {
    param([string]$Location, [string]$HostName)

    if ($HostName -cnotmatch '\A([a-z0-9]{5,50})\.azurecr\.io\z') { throw 'Invalid registry label' }
    $dataHost = $Matches[1] + '.swedencentral.data.' + 'azurecr.io'
    if (-not $Location -or $Location.Length -gt 2304 -or $Location -match '[^\x21-\x7e]|[\\#]') { throw 'Invalid data Location' }
    $pattern = '\Ahttps://' + [regex]::Escape($dataHost) + '(?::443)?/?\?([^#]+)\z'
    if ($Location -cnotmatch $pattern) { throw 'Data Location escaped the exact regional host or root path' }
    $query = $Matches[1]
    if ($query.Length -gt 2048 -or $query -match '%(?![0-9a-fA-F]{2})') { throw 'Invalid data query size or encoding' }
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($parameter in $query.Split('&')) {
        $parts = $parameter.Split('=', 2)
        if ($parts.Count -ne 2 -or $parts[0] -cnotin @('t','h','c','r','d','p','s','v','l') -or -not $keys.Add($parts[0])) { throw 'Unexpected or duplicate data query key' }
        if ($parts[1] -cnotmatch '\A[a-zA-Z0-9._~%+/:=-]*\z' -or [uri]::UnescapeDataString($parts[1]) -match '[\x00-\x20\x7f]') { throw 'Invalid data query value' }
    }
    if ($keys.Count -ne 9) { throw 'Incomplete data query' }
    $address = [uri]$Location
    if ($address.Scheme -cne 'https' -or $address.Host -cne $dataHost -or $address.Port -ne 443 -or $address.UserInfo -or $address.Fragment -or $address.AbsolutePath -cne '/') { throw 'Unsafe data URI' }
    return $Location
}

function Get-RegistryDataDns {
    param([string]$HostName, [hashtable]$Budget)

    try {
        Use-RegistryRequestBudget $Budget -Dns
        $lookup = [Net.Dns]::GetHostAddressesAsync($HostName)
        if (-not $lookup.Wait(5000)) { return 'INCONCLUSIVE' }
        $addresses = @($lookup.GetAwaiter().GetResult())
        if (-not $addresses.Count) { return 'INCONCLUSIVE' }
        foreach ($address in $addresses) {
            if ($address.IsIPv4MappedToIPv6) { $address = $address.MapToIPv4() }
            $bytes = $address.GetAddressBytes()
            if ($bytes.Length -ne 4 -or -not ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168))) { return 'FAIL' }
        }
        return 'PASS'
    } catch { return 'INCONCLUSIVE' }
}

function Get-RegistryTargets {
    param([hashtable]$State, [hashtable]$Lab)

    Assert-LabState $State
    if ($State.phase -cne 'activate' -or $Lab.phase -cne 'activate' -or $State.deploymentAuthorized -isnot [bool] -or -not $State.deploymentAuthorized -or $State.privateAccessVerified -isnot [bool] -or -not $State.privateAccessVerified -or $State.pendingPhase) { throw 'Authorized activated private lab required' }
    if (@($Lab.resourceGroups).Count -ne 4 -or @(Compare-Object $State.resourceGroups $Lab.resourceGroups).Count) { throw 'Group set mismatch' }
    if ($Lab.cases -isnot [array] -or $Lab.cases.Count -ne 2 -or $Lab.identities -isnot [array]) { throw 'Two cases and explicit identities required' }
    $targets = @{}
    foreach ($caseIndex in 0..1) {
        $label = @('a', 'b')[$caseIndex]
        $case = $Lab.cases[$caseIndex]
        Assert-LabResourceId $State $case.registryId
        $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)"
        $registryPattern = '^' + [regex]::Escape("$prefix-case-$label/providers/Microsoft.ContainerRegistry/registries/") + '([a-z0-9]{5,50})$'
        if ($case.registryId -cnotmatch $registryPattern) { throw 'Unexpected registry parent or name' }
        $hostName = $Matches[1] + '.azurecr.io'
        if ($case.ContainsKey('registryLoginServer') -and $case.registryLoginServer -cne $hostName) { throw 'Unexpected registry login server' }
        $publishers = @($Lab.identities | Where-Object { $_.actor -ceq "publisher-$label" })
        if ($publishers.Count -ne 1) { throw 'Exactly one publisher per case required' }
        $actor = $publishers[0]
        Assert-LabResourceId $State $actor.resourceId
        if ($actor.resourceId -cnotmatch ('^' + [regex]::Escape("$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/") + '[a-z0-9-]+$')) { throw 'Unexpected publisher parent' }
        foreach ($field in @('clientId', 'principalId')) {
            $identifier = [guid]::Empty
            if (-not [guid]::TryParse([string]$actor[$field], [ref]$identifier) -or $identifier -eq [guid]::Empty) { throw 'Invalid publisher identifier' }
        }
        foreach ($field in @('clientId', 'principalId', 'resourceId')) {
            if (@($Lab.identities | Where-Object { $_[$field] -ieq $actor[$field] }).Count -ne 1) { throw 'Publishers must have distinct identities' }
        }
        $targets[$label] = @{hostName=$hostName; repository="case-$label/test"; actor=$actor; ready=$false}
    }
    if ($targets.a.hostName -ceq $targets.b.hostName) { throw 'Registries must be distinct' }
    return $targets
}

function Get-RegistryEntraToken {
    param([hashtable]$Actor, [string]$TenantId, [hashtable]$Budget)

    try {
        $audience = 'https://containerregistry.azure.net'
        $query = 'api-version=2018-02-01&resource=' + [uri]::EscapeDataString($audience) + '&client_id=' + [uri]::EscapeDataString($Actor.clientId)
        Use-RegistryRequestBudget $Budget
        $response = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?$query" -Headers @{Metadata='true'} -NoProxy -TimeoutSec 20 -OperationTimeoutSeconds 20 -MaximumRedirection 0 -MaximumRetryCount 0 -Verbose:$false -Debug:$false -WarningAction SilentlyContinue -ErrorAction Stop
        if ($response.access_token -isnot [string] -or $response.token_type -isnot [string]) { return $null }
        $claims = Read-IdentityClaims $response.access_token
        if ($response.token_type -ine 'Bearer' -or -not $claims -or $claims.aud -cne $audience -or $claims.tid -ine $TenantId -or $claims.oid -ine $Actor.principalId) { return $null }
        foreach ($field in @('tid', 'oid')) { if ($claims[$field] -isnot [string]) { return $null } }
        foreach ($field in @('appid', 'azp', 'xms_mirid')) { if ($claims.ContainsKey($field) -and $claims[$field] -isnot [string]) { return $null } }
        if (-not $claims.appid -and -not $claims.azp) { return $null }
        if (($claims.appid -and $claims.appid -ine $Actor.clientId) -or ($claims.azp -and $claims.azp -ine $Actor.clientId) -or ($claims.xms_mirid -and $claims.xms_mirid -ine $Actor.resourceId)) { return $null }
        return [string]$response.access_token
    } catch { return $null }
}

function Send-RegistryHttpRequest {
    param([string]$Uri, [string]$Method, [hashtable]$Headers, [object]$Body, [string]$ContentType)

    $handler = $client = $request = $response = $stream = $content = $cancellation = $null
    try {
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.UseProxy = $false
        $handler.UseCookies = $false
        $handler.MaxResponseHeadersLength = 16
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(20))
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method.ToUpperInvariant()), $Uri)
        foreach ($key in $Headers.Keys) { $request.Headers.Add($key, [string]$Headers[$key]) }
        if ($Body -is [hashtable]) {
            $form = [Collections.Generic.Dictionary[string,string]]::new()
            foreach ($key in $Body.Keys) { $form.Add($key, [string]$Body[$key]) }
            $request.Content = [Net.Http.FormUrlEncodedContent]::new($form)
        } elseif ($null -ne $Body) {
            $request.Content = [Net.Http.ByteArrayContent]::new([byte[]]$Body)
            $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new($ContentType)
        }
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
        $responseHeaders = @{}
        foreach ($header in $response.Headers.NonValidated) { $responseHeaders[$header.Key] = @($header.Value) }
        foreach ($header in $response.Content.Headers.NonValidated) { $responseHeaders[$header.Key] = @($header.Value) }
        $result = @{StatusCode=[int]$response.StatusCode; Headers=$responseHeaders; Content=[byte[]]@()}
        if ($Method -ceq 'Head' -or ($result.StatusCode -ge 300 -and $result.StatusCode -lt 400)) { return $result }
        if ($response.Content.Headers.ContentLength -gt 65536) { $result.category='Protocol'; return $result }
        $stream = $response.Content.ReadAsStreamAsync($cancellation.Token).GetAwaiter().GetResult()
        $content = [IO.MemoryStream]::new()
        $buffer = [byte[]]::new(8192)
        while ($true) {
            $count = $stream.ReadAsync($buffer, 0, [int][math]::Min($buffer.Length, 65537 - $content.Length), $cancellation.Token).GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            if ($content.Length + $count -gt 65536) { $result.category='Protocol'; return $result }
            $content.Write($buffer, 0, $count)
        }
        $result.Content = $content.ToArray()
        return $result
    } catch { return @{StatusCode=0; category='Transport'; Content=[byte[]]@(); Headers=@{}} }
    finally {
        foreach ($resource in @($stream, $content, $response, $request, $client, $handler, $cancellation)) {
            if ($null -ne $resource) { $resource.Dispose() }
        }
    }
}

function ConvertTo-RegistryResponseProbe {
    param([hashtable]$Response)

    if ($Response.category) { return @{status=[int]$Response.StatusCode; category=$Response.category; data=$null} }
    [byte[]]$content = $Response.Content
    if ($content.Length -gt 65536) { return @{status=[int]$Response.StatusCode; category='Protocol'; data=$null} }
    $probe = ConvertTo-IdentityProbe ([int]$Response.StatusCode) ([Text.Encoding]::UTF8.GetString($content))
    $probe.digest = [string](@($Response.Headers['Docker-Content-Digest'])[0])
    $locations = @($Response.Headers['Location'])
    $probe.location = if ($locations.Count -eq 1) { [string]$locations[0] } else { '' }
    $probe.length = [string](@($Response.Headers['Content-Length'])[0])
    $probe.mediaType = ([string](@($Response.Headers['Content-Type'])[0])).Split(';')[0].Trim()
    $probe.bodyHash = Get-RegistryDigest $content
    $probe.bodySize = $content.Length
    return $probe
}

function Read-RegistryConfigRedirect {
    param([hashtable]$Target, [string]$Location, [hashtable]$Budget)

    try {
        if (-not $Budget.targets.ContainsKey($Target.hostName) -or $Budget.targets[$Target.hostName] -cne $Target.repository) { throw 'Target not allowlisted' }
        $uri = Resolve-RegistryDataLocation $Location $Target.hostName
    } catch { return @{status=307; category='Boundary'; data=$null} }
    if ((Get-RegistryDataDns ([uri]$uri).Host $Budget) -cne 'PASS') { return @{status=0; category='PrivateDns'; data=$null} }
    try {
        Use-RegistryRequestBudget $Budget
        $response = Send-RegistryHttpRequest -Uri $uri -Method Get -Headers @{Accept='application/octet-stream'}
        $probe = ConvertTo-RegistryResponseProbe $response
        $probe.location = $null
        return $probe
    } catch { return @{status=0; category='Transport'; data=$null} }
}

function Send-RegistryRequest {
    param([hashtable]$Target, [string]$Uri, [ValidateSet('Get', 'Head', 'Post', 'Put')][string]$Method, [hashtable]$Budget, [string]$Token, [hashtable]$Form, [byte[]]$Bytes)

    try {
        $hostName = $Target.hostName
        $repository = $Target.repository
        if (-not $Budget.targets.ContainsKey($hostName) -or $Budget.targets[$hostName] -cne $repository) { throw 'Target not allowlisted' }
        $address = [uri]$Uri
        if ($address.Scheme -cne 'https' -or $address.Host -cne $hostName -or $address.Port -ne 443 -or $address.UserInfo -or $address.Fragment -or $Uri -cne "https://$hostName$($address.AbsolutePath)$($address.Query)") { throw 'Unsafe service URI' }
        $image = $Budget.image
        $root = "/v2/$repository"
        $parameters = @{Uri=$Uri; Method=$Method; Headers=@{Accept='application/json'}}
        if ($Form) {
            if ($Method -cne 'Post' -or $Token -or $Bytes -or $address.Query -or $Form.service -cne $hostName -or $Form.Count -ne 4) { throw 'Unsafe OAuth request' }
            if ($address.AbsolutePath -ceq '/oauth2/exchange') {
                if ($Form.grant_type -cne 'access_token' -or -not $Form.access_token -or -not $Form.tenant) { throw 'Invalid exchange form' }
            } elseif ($address.AbsolutePath -ceq '/oauth2/token') {
                if ($Form.grant_type -cne 'refresh_token' -or -not $Form.refresh_token -or $Form.scope -cnotin @("repository:${repository}:pull", "repository:${repository}:pull,push")) { throw 'Invalid token scope' }
            } else { throw 'Unknown OAuth route' }
            $parameters.ContentType = 'application/x-www-form-urlencoded'
            $parameters.Body = $Form
        } else {
            if (-not $Token) { throw 'Registry access token required' }
            $claims = Read-IdentityClaims $Token
            if (-not $claims -or $claims.aud -cne $hostName -or $claims.grant_type -isnot [string] -or $claims.grant_type -cne 'access_token' -or $claims.access -isnot [array]) { throw 'Invalid registry bearer' }
            $parameters.Headers.Authorization = "Bearer $Token"
            if ($Method -ceq 'Post' -and $address.AbsolutePath -ceq "$root/blobs/uploads/" -and -not $address.Query -and $Bytes.Length -eq 0) {
                $parameters.ContentType = 'application/octet-stream'
                $parameters.Body = [byte[]]@()
            } elseif ($Method -ceq 'Put' -and $address.AbsolutePath.StartsWith("$root/blobs/uploads/")) {
                $suffix = 'digest=' + [uri]::EscapeDataString($image.configDigest)
                if ($Uri -cnotmatch ('[?&]' + [regex]::Escape($suffix) + '$')) { throw 'Unexpected upload digest' }
                $location = $Uri.Substring(0, $Uri.Length - $suffix.Length - 1)
                if ((Resolve-RegistryUploadLocation $location $hostName $repository $image.configDigest) -cne $Uri -or $Bytes.Length -ne $image.configBytes.Length -or (Get-RegistryDigest $Bytes) -cne $image.configDigest) { throw 'Unexpected upload content' }
                $parameters.ContentType = 'application/octet-stream'
                $parameters.Body = $Bytes
            } elseif ($Method -ceq 'Put' -and $address.AbsolutePath -ceq "$root/manifests/fgl-fixture" -and -not $address.Query) {
                if ($Bytes.Length -ne $image.manifestBytes.Length -or (Get-RegistryDigest $Bytes) -cne $image.manifestDigest) { throw 'Unexpected manifest content' }
                $parameters.ContentType = 'application/vnd.oci.image.manifest.v1+json'
                $parameters.Body = $Bytes
            } elseif (-not $Bytes -and -not $address.Query -and (($Method -ceq 'Head' -and $address.AbsolutePath -ceq "$root/manifests/fgl-fixture") -or ($Method -ceq 'Get' -and $address.AbsolutePath -ceq "$root/manifests/$($image.manifestDigest)"))) {
                $parameters.Headers.Accept = 'application/vnd.oci.image.manifest.v1+json'
            } elseif (-not $Bytes -and -not $address.Query -and $Method -ceq 'Get' -and $address.AbsolutePath -ceq "$root/blobs/$($image.configDigest)") {
                $parameters.Headers.Accept = 'application/octet-stream'
            } else { throw 'Unapproved registry operation' }
        }
    } catch { return @{status=0; category='Boundary'; data=$null} }
    try {
        Use-RegistryRequestBudget $Budget
        $response = Send-RegistryHttpRequest @parameters
        return ConvertTo-RegistryResponseProbe $response
    } catch { return @{status=0; category='Transport'; data=$null} }
}

function Get-RegistryAccessToken {
    param([hashtable]$Target, [string]$EntraToken, [string]$TenantId, [ValidateSet('pull', 'pull,push')][string]$Actions, [hashtable]$Budget)

    $exchange = Send-RegistryRequest $Target "https://$($Target.hostName)/oauth2/exchange" Post $Budget -Form @{grant_type='access_token'; service=$Target.hostName; tenant=$TenantId; access_token=$EntraToken}
    if ($exchange.status -ne 200 -or $exchange.data.refresh_token -isnot [string] -or -not $exchange.data.refresh_token) { return @{token=$null; probe=$exchange} }
    $probe = Send-RegistryRequest $Target "https://$($Target.hostName)/oauth2/token" Post $Budget -Form @{grant_type='refresh_token'; service=$Target.hostName; scope="repository:$($Target.repository):$Actions"; refresh_token=$exchange.data.refresh_token}
    $exchange = $null
    $claims = Read-IdentityClaims $probe.data.access_token
    if ($probe.status -ne 200 -or $probe.data.access_token -isnot [string] -or -not $claims -or $claims.aud -cne $Target.hostName -or $claims.grant_type -isnot [string] -or $claims.grant_type -cne 'access_token' -or $claims.access -isnot [array]) { return @{token=$null; probe=$probe} }
    return @{token=[string]$probe.data.access_token; probe=$probe}
}

function Get-RegistryPositiveVerdict {
    param([hashtable]$Probe, [bool]$Valid)

    if ($Valid) { return 'PASS' }
    if ($Probe.status -ge 200 -and $Probe.status -lt 300) { return 'FAIL' }
    return 'INCONCLUSIVE'
}

function Get-RegistryNegativeVerdict {
    param([bool]$PositiveReady, [hashtable]$Probe)

    if (-not $PositiveReady) { return 'BLOCKED' }
    if ($Probe.status -ge 200 -and $Probe.status -lt 300) { return 'FAIL' }
    if ($Probe.status -eq 403 -and $Probe.category -ceq 'Authorization' -and $Probe.code -ceq 'DENIED') { return 'PASS' }
    return 'INCONCLUSIVE'
}

function Push-RegistryFixture {
    param([hashtable]$Target, [string]$Token, [hashtable]$Budget)

    $image = $Budget.image
    $root = "https://$($Target.hostName)/v2/$($Target.repository)"
    $probe = Send-RegistryRequest $Target "$root/blobs/uploads/" Post $Budget $Token -Bytes ([byte[]]@())
    if ($probe.status -ne 202) { return @{valid=$false; probe=$probe} }
    try { $uploadUri = Resolve-RegistryUploadLocation $probe.location $Target.hostName $Target.repository $image.configDigest } catch { $probe.category='Boundary'; return @{valid=$false; probe=$probe} }
    $probe = Send-RegistryRequest $Target $uploadUri Put $Budget $Token -Bytes $image.configBytes
    if ($probe.status -ne 201 -or $probe.digest -cne $image.configDigest) { return @{valid=$false; probe=$probe} }
    $probe = Send-RegistryRequest $Target "$root/manifests/fgl-fixture" Put $Budget $Token -Bytes $image.manifestBytes
    return @{valid=($probe.status -eq 201 -and $probe.digest -ceq $image.manifestDigest); probe=$probe}
}

function Test-RegistryManifest {
    param([hashtable]$Probe, [hashtable]$Image)

    $data = $Probe.data
    return $Probe.status -eq 200 -and $Probe.digest -ceq $Image.manifestDigest -and $Probe.bodyHash -ceq $Image.manifestDigest -and $Probe.bodySize -eq $Image.manifestBytes.Length -and $Probe.mediaType -ceq 'application/vnd.oci.image.manifest.v1+json' -and $data.schemaVersion -eq 2 -and $data.mediaType -ceq 'application/vnd.oci.image.manifest.v1+json' -and $data.config.mediaType -ceq 'application/vnd.oci.image.config.v1+json' -and $data.config.digest -ceq $Image.configDigest -and $data.config.size -eq $Image.configBytes.Length -and $data.layers -is [array] -and $data.layers.Count -eq 0
}

function Test-RegistryConfig {
    param([hashtable]$Probe, [hashtable]$Image)

    $data = $Probe.data
    return $Probe.status -eq 200 -and $Probe.bodyHash -ceq $Image.configDigest -and $Probe.bodySize -eq $Image.configBytes.Length -and (-not $Probe.digest -or $Probe.digest -ceq $Image.configDigest) -and $data.architecture -ceq 'amd64' -and $data.os -ceq 'linux' -and $data.config -is [hashtable] -and $data.config.Count -eq 0 -and $data.rootfs.type -ceq 'layers' -and $data.rootfs.diff_ids -is [array] -and $data.rootfs.diff_ids.Count -eq 0
}

function Read-RegistryFixture {
    param([hashtable]$Target, [string]$Token, [hashtable]$Budget)

    $image = $Budget.image
    $root = "https://$($Target.hostName)/v2/$($Target.repository)"
    $probe = Send-RegistryRequest $Target "$root/manifests/fgl-fixture" Head $Budget $Token
    if ($probe.status -ne 200 -or $probe.digest -cne $image.manifestDigest -or $probe.length -cne [string]$image.manifestBytes.Length) { return @{valid=$false; probe=$probe} }
    $probe = Send-RegistryRequest $Target "$root/manifests/$($image.manifestDigest)" Get $Budget $Token
    if (-not (Test-RegistryManifest $probe $image)) { return @{valid=$false; probe=$probe} }
    $probe = Send-RegistryRequest $Target "$root/blobs/$($image.configDigest)" Get $Budget $Token
    if ($probe.status -eq 307) { $probe = Read-RegistryConfigRedirect $Target $probe.location $Budget }
    return @{valid=(Test-RegistryConfig $probe $image); probe=$probe}
}

function Add-RegistryResult {
    param([System.Collections.Generic.List[object]]$Results, [string]$Test, [ValidateSet('PASS', 'FAIL', 'BLOCKED', 'INCONCLUSIVE')][string]$Status, [string]$Reason, [hashtable]$Probe, [string]$Plane='RegistryData')

    $Results.Add([pscustomobject]@{test=$Test; status=$Status; reason=$Reason; plane=$Plane; httpStatus=$(if ($Probe) { $Probe.status } else { 0 }); category=$(if ($Probe) { $Probe.category } else { 'Prerequisite' })})
}

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$budget = @{requests=0; dnsQueries=0; targets=@{}}
$results = [System.Collections.Generic.List[object]]::new()
$tokens = @{}
$destination = $null
try {
    if (-not $RunLive) { Add-RegistryResult $results 'LIVE' 'BLOCKED' 'Explicit RunLive required; no file, DNS or HTTP I/O performed' $null 'Harness'; return }
    if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -lt [version]'7.4') { throw 'PowerShell Core 7.4 or later required' }
    if (-not $StatePath -or -not $OutputsPath -or -not $ResultsPath) { throw 'Three explicit external paths required' }
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1') -Force -Verbose:$false
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1') -Force -Verbose:$false
    $candidate = Assert-ExternalLabPath $ResultsPath
    if ((Test-Path -LiteralPath $candidate) -or -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($candidate)) -PathType Container)) { throw 'Results require a new external file with an existing parent' }
    foreach ($inputPath in @($StatePath, $OutputsPath)) {
        if ($candidate.Equals([IO.Path]::GetFullPath($inputPath), [StringComparison]::OrdinalIgnoreCase)) { throw 'Results cannot replace inputs' }
    }
    $destination = $candidate
    $stateFile = Assert-ExternalLabPath $StatePath
    $outputsFile = Assert-ExternalLabPath $OutputsPath
    if ($stateFile.Equals($outputsFile, [StringComparison]::OrdinalIgnoreCase)) { throw 'Distinct inputs required' }
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $lab = Get-Content -LiteralPath $outputsFile -Raw | ConvertFrom-Json -AsHashtable
    $targets = Get-RegistryTargets $state $lab
    $parseTokens = $null
    $parseErrors = $null
    $identityAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-IdentityChecks.ps1'), [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Identity helper syntax invalid' }
    foreach ($helperName in @('Read-IdentityClaims', 'Get-IdentityPrivateDns', 'ConvertTo-IdentityProbe')) {
        $definitions = @($identityAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $helperName }, $true))
        if ($definitions.Count -ne 1) { throw 'Expected identity helper missing' }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $budget.image = New-RegistryFixture
    foreach ($label in @('a', 'b')) { $budget.targets[$targets[$label].hostName] = $targets[$label].repository }
    foreach ($label in @('a', 'b')) {
        $target = $targets[$label]
        $key = $label.ToUpperInvariant()
        Use-RegistryRequestBudget $budget -Dns
        $dns = Get-IdentityPrivateDns $target.hostName
        Add-RegistryResult $results "DNS-ACR-$key" $dns 'All registry DNS answers must be private; endpoint ownership is a prerequisite' $null 'Network'
        if ($dns -cne 'PASS') { continue }
        $tokens[$label] = Get-RegistryEntraToken $target.actor $state.tenantId $budget
        Add-RegistryResult $results "ACR-$key-IMDS" $(if ($tokens[$label]) { 'PASS' } else { 'BLOCKED' }) 'Explicit publisher client ID; ACR audience, tenant, principal, client and lifetime claims checked; not independent JWT signature verification' $null 'Identity'
        if (-not $tokens[$label]) { continue }
        $auth = Get-RegistryAccessToken $target $tokens[$label] $state.tenantId 'pull,push' $budget
        if (-not $auth.token) { Add-RegistryResult $results "ACR-$key-PUSH" 'BLOCKED' 'OAuth exchange did not establish an ACR access token; no push attempted' $auth.probe; continue }
        $pushed = Push-RegistryFixture $target $auth.token $budget
        Add-RegistryResult $results "ACR-$key-PUSH" (Get-RegistryPositiveVerdict $pushed.probe $pushed.valid) 'Fixed config blob and zero-layer OCI manifest pushed under the reserved fixture tag with matching digests' $pushed.probe
        if (-not $pushed.valid) { continue }
        $pulled = Read-RegistryFixture $target $auth.token $budget
        $target.ready = $pulled.valid
        Add-RegistryResult $results "ACR-$key-PULL" (Get-RegistryPositiveVerdict $pulled.probe $pulled.valid) 'HEAD and digest-pinned manifest/config bytes, sizes and semantics checked; optional one-hop config redirect requires exact regional host and all RFC1918 DNS answers, not endpoint ownership proof' $pulled.probe
        $auth = $null
    }
    if ($targets.a.ready -and $targets.b.ready) {
        foreach ($label in @('a', 'b')) {
            $other = if ($label -ceq 'a') { 'b' } else { 'a' }
            $target = $targets[$other]
            $test = "ACR-$($label.ToUpperInvariant())-CROSS-READ"
            $auth = Get-RegistryAccessToken $target $tokens[$label] $state.tenantId 'pull' $budget
            if (-not $auth.token) { Add-RegistryResult $results $test 'BLOCKED' 'Cross-registry OAuth failed before the read; not an authorization-denial proof' $auth.probe; continue }
            $probe = Send-RegistryRequest $target "https://$($target.hostName)/v2/$($target.repository)/manifests/$($budget.image.manifestDigest)" Get $budget $auth.token
            Add-RegistryResult $results $test (Get-RegistryNegativeVerdict $true $probe) 'Counterpart digest read after both complete positive cycles; only explicit HTTP 403 DENIED is proof, not same-registry ABAC or write isolation' $probe
        }
    }
} catch {
    Add-RegistryResult $results 'HARNESS' 'BLOCKED' 'Prerequisite validation or local execution failed; private diagnostics suppressed' $null 'Harness'
} finally {
    $tokens.Clear()
    $auth = $null
    $probe = $null
    $pushed = $null
    $pulled = $null
    if ($RunLive) {
        foreach ($label in @('A', 'B')) {
            foreach ($test in @("DNS-ACR-$label", "ACR-$label-IMDS", "ACR-$label-PUSH", "ACR-$label-PULL", "ACR-$label-CROSS-READ")) {
                if ($test -notin $results.test) { Add-RegistryResult $results $test 'BLOCKED' 'Required validated inputs, private DNS, publisher token or complete positive cycle missing; request suppressed' $null }
            }
            Add-RegistryResult $results "ACR-$label-ABAC-WRITE" 'BLOCKED' 'No same-registry outside-condition fixture with an authorized same-operation positive; no out-of-repository write attempted and no permissions broadened' $null
        }
        Add-RegistryResult $results 'ACR-PROJECT-PULL' 'BLOCKED' 'Publisher UAMIs do not impersonate project identities; project-runtime pull not tested' $null
        Add-RegistryResult $results 'ACR-HOSTED-PROOF' 'BLOCKED' 'Synthetic scratch image has no executable; no hosted-agent deployment or execution attempted' $null
    }
    if ($destination) {
        try {
            $report = [ordered]@{schemaVersion=1; runLive=$true; requests=$budget.requests; requestLimit=40; requestScope='HTTP including IMDS, OAuth and config redirect; HTTP and explicit DNS share the 40-operation limit'; dnsQueries=$budget.dnsQueries; operations=($budget.requests + $budget.dnsQueries); operationLimit=40; elapsedSeconds=[math]::Round($timer.Elapsed.TotalSeconds,1); tests=$results.ToArray()}
            $json = $report | ConvertTo-Json -Depth 8
            Assert-PublicText $json
            $null = Assert-ExternalLabPath $destination
            $json | Out-File -LiteralPath $destination -Encoding utf8 -NoClobber -ErrorAction Stop
        } catch { Add-RegistryResult $results 'RESULTS' 'BLOCKED' 'New external report could not be persisted; private diagnostics suppressed' $null 'Harness' }
    }
    $results.ToArray()
    Write-Output "operations: $($budget.requests + $budget.dnsQueries)/40 (HTTP including IMDS: $($budget.requests); DNS resolutions: $($budget.dnsQueries))"
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}