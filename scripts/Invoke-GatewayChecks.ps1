[CmdletBinding()]
param([string]$StatePath, [string]$OutputsPath, [switch]$RunLive, [string]$ResultsPath)

function ConvertTo-GatewayProbeResult {
    param([int]$Status, [AllowEmptyString()][string]$Body)

    $result = @{ status = $Status; code = ''; chatValid = $false; authorizationDenied = $false; apiOperationDenied = $false }
    try {
        $content = ConvertFrom-Json -InputObject $Body -AsHashtable -ErrorAction Stop
        if ($content -isnot [hashtable]) { return $result }
        $code = if ($content.error -is [hashtable]) { $content.error.code } else { $content.code }
        if ($code -in @('CallerNotAllowed', 'PermissionDenied', 'AuthorizationFailed')) { $result.code = [string]$code }
        if ($content.error -is [hashtable] -and $content.error.message -is [string]) {
            $message = $content.error.message
            $result.apiOperationDenied = $content.error.code -ceq 'PermissionDenied' -and $message -ceq 'Principal does not have access to API/Operation.'
            $result.authorizationDenied = $result.code -in @('PermissionDenied', 'AuthorizationFailed') -and
                $message -match '(?i)(lacks? (?:the )?required (?:data )?action|does not have authorization to perform (?:the )?action|not authorized to perform (?:the )?action)' -and
                $message -notmatch '(?i)(virtual network|firewall|public network|ip address|network access)'
        }
        if ($Status -eq 200 -and $content.object -ceq 'chat.completion' -and $content.choices -is [array] -and $content.choices.Count -eq 1) {
            $choice = $content.choices[0]
            $result.chatValid = $choice -is [hashtable] -and $choice.message -is [hashtable] -and
                $choice.message.role -ceq 'assistant' -and $choice.message.content -is [string] -and
                $choice.message.content.Trim() -ceq 'OK' -and $choice.finish_reason -ceq 'stop'
        }
    } catch { return $result }
    return $result
}

function Get-GatewayNegativeVerdict {
    param([bool]$PositiveReady, [hashtable]$Probe, [ValidateSet('Caller', 'Authentication', 'Bypass')][string]$Kind)

    if (-not $PositiveReady) { return 'BLOCKED' }
    if ($Probe.status -ge 200 -and $Probe.status -lt 300) { return 'FAIL' }
    if ($Kind -eq 'Authentication') {
        if ($Probe.status -eq 401) { return 'PASS' }
        return 'INCONCLUSIVE'
    }
    if ($Kind -eq 'Bypass') {
        if ($Probe.status -eq 401 -and $Probe.code -ceq 'PermissionDenied' -and $Probe.apiOperationDenied) { return 'PASS' }
        if (-not $Probe.authorizationDenied) { return 'INCONCLUSIVE' }
        return Get-AuthorizationVerdict 200 $Probe.status $Probe.code @('PermissionDenied', 'AuthorizationFailed')
    }
    return Get-AuthorizationVerdict 200 $Probe.status $Probe.code
}

function Get-PrivateAddressVerdict {
    param([string[]]$Addresses)

    if (@($Addresses).Count -eq 0) { return 'INCONCLUSIVE' }
    foreach ($address in $Addresses) {
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse($address, [ref]$parsed)) { return 'INCONCLUSIVE' }
        if ($parsed.IsIPv4MappedToIPv6) { $parsed = $parsed.MapToIPv4() }
        $bytes = $parsed.GetAddressBytes()
        $private = if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
            $bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
        } else {
            ($bytes[0] -band 254) -eq 252
        }
        if (-not $private) { return 'FAIL' }
    }
    return 'PASS'
}

function Test-GatewayTokenClaims {
    param([string]$Token, [string]$TenantId, [string]$PrincipalId, [string[]]$Audiences)

    try {
        $segments = $Token.Split('.')
        if ($segments.Count -ne 3 -or -not $segments[0] -or -not $segments[2]) { return $false }
        $segment = $segments[1].Replace('-', '+').Replace('_', '/')
        $segment = $segment.PadRight($segment.Length + (4 - $segment.Length % 4) % 4, '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($segment)) | ConvertFrom-Json -AsHashtable
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        return $claims -is [hashtable] -and $claims.tid -eq $TenantId -and $claims.oid -eq $PrincipalId -and
            $claims.aud -is [string] -and $claims.aud -cin $Audiences -and [long]$claims.exp -gt $now + 60 -and
            (-not $claims.ContainsKey('nbf') -or [long]$claims.nbf -le $now)
    } catch { return $false }
}

function Use-GatewayRequestBudget {
    param([hashtable]$Budget, [switch]$InferenceCandidate)

    if ($Budget.requests -ge 45) { throw 'HTTP request budget exhausted' }
    if ($InferenceCandidate -and $Budget.inferenceCandidates -ge 20) { throw 'Inference candidate budget exhausted' }
    $Budget.requests++
    if ($InferenceCandidate) { $Budget.inferenceCandidates++ }
}

function New-GatewayProbeBody {
    param([ValidateSet('Chat', 'Oversize', 'InvalidJson', 'InvalidSchema')][string]$Kind = 'Chat')

    if ($Kind -eq 'InvalidJson') { return '{"messages":[' }
    if ($Kind -eq 'InvalidSchema') { return '{"messages":[]}' }
    $body = @{messages=@(@{role='user'; content='Reply with OK'}); max_tokens=64; n=1; stream=$false} | ConvertTo-Json -Depth 5 -Compress
    if ($Kind -eq 'Oversize') { $body += ' ' * (16385 - [Text.Encoding]::UTF8.GetByteCount($body)) }
    return $body
}

function Get-GatewayBoundaryVerdict {
    param([bool]$PositiveReady, [hashtable]$Probe, [ValidateSet(400, 404, 429)][int]$ExpectedStatus)

    if (-not $PositiveReady) { return 'BLOCKED' }
    if ($Probe.status -eq $ExpectedStatus) { return 'PASS' }
    if ($Probe.status -in @(0, 401, 403, 429) -or ($ExpectedStatus -eq 429 -and $Probe.status -eq 400)) { return 'INCONCLUSIVE' }
    return 'FAIL'
}

function Get-GatewayActorToken {
    param([hashtable]$Actor, [string]$TenantId, [string]$Audience, [hashtable]$Budget)

    $query = 'api-version=2018-02-01&resource=' + [uri]::EscapeDataString($Audience) + '&client_id=' + [uri]::EscapeDataString($Actor.clientId)
    try {
        Use-GatewayRequestBudget $Budget
        $response = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?$query" -Headers @{Metadata='true'} -NoProxy -TimeoutSec 20 -MaximumRedirection 0 -MaximumRetryCount 0 -Verbose:$false -Debug:$false -WarningAction SilentlyContinue -ErrorAction Stop
        $audiences = if ($Audience -ceq 'https://management.azure.com/') { @($Audience, 'https://management.core.windows.net/') } else { @($Audience) }
        if ($response.token_type -ine 'Bearer' -or -not (Test-GatewayTokenClaims $response.access_token $TenantId $Actor.principalId $audiences)) { return $null }
        return [string]$response.access_token
    } catch { return $null }
}

function Send-GatewayProbe {
    param([string]$Uri, [AllowEmptyString()][string]$Token, [hashtable]$Budget, [ValidateSet('Chat', 'Oversize', 'InvalidJson', 'InvalidSchema')][string]$BodyKind = 'Chat')

    $headers = @{}
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    $body = New-GatewayProbeBody $BodyKind
    try {
        Use-GatewayRequestBudget $Budget -InferenceCandidate:($BodyKind -ne 'InvalidJson')
        $response = Invoke-WebRequest -Uri $Uri -Method Post -Headers $headers -ContentType 'application/json' -Body $body -NoProxy -TimeoutSec 30 -MaximumRedirection 0 -MaximumRetryCount 0 -SkipHttpErrorCheck -Verbose:$false -Debug:$false -WarningAction SilentlyContinue -ErrorAction Stop
        $content = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        return ConvertTo-GatewayProbeResult ([int]$response.StatusCode) $content
    } catch {
        return ConvertTo-GatewayProbeResult 0 ''
    }
}

function Get-GatewayDnsVerdict {
    param([string]$HostName)

    try {
        $lookup = [Net.Dns]::GetHostAddressesAsync($HostName)
        if (-not $lookup.Wait(5000)) { return 'INCONCLUSIVE' }
        return Get-PrivateAddressVerdict @($lookup.GetAwaiter().GetResult() | ForEach-Object { $_.ToString() })
    } catch { return 'INCONCLUSIVE' }
}

function Add-GatewayResult {
    param(
        [System.Collections.Generic.List[object]]$Results,
        [string]$Test,
        [ValidateSet('PASS', 'FAIL', 'BLOCKED', 'INCONCLUSIVE')][string]$Status,
        [string]$Reason,
        [int]$HttpStatus = 0
    )

    $Results.Add([pscustomobject]@{test=$Test; status=$Status; reason=$Reason; httpStatus=$HttpStatus})
}

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$results = [System.Collections.Generic.List[object]]::new()
$budget = @{requests=0; dnsQueries=0; inferenceCandidates=0}
$tokens = @{}
$armToken = $null
$resultsDestination = $null
$requiredActors = @('dev-a', 'consumer-a', 'dev-b', 'publisher-a', 'publisher-b', 'client', 'denied')
$negativeTests = @('GATEWAY', 'GATEWAY-ANONYMOUS', 'GATEWAY-AUDIENCE', 'GATEWAY-INVALID-TOKEN') + @($requiredActors | ForEach-Object { 'BYPASS-' + $_.ToUpperInvariant() })
$boundaryTests = @('C07-DEPLOYMENT-ROUTE', 'C07-BODY-SIZE', 'C07-INVALID-SCHEMA', 'C07-INVALID-JSON', 'C07-RATE-LIMIT', 'C07-ADDITIONAL-FIELDS', 'C07-MODEL-BODY')
$dnsTests = @('DNS-GATEWAY', 'DNS-MODELS', 'DNS-FOUNDRY-A', 'DNS-FOUNDRY-B', 'DNS-REGISTRY-A', 'DNS-REGISTRY-B')
try {
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1') -Force -Verbose:$false
    if ($ResultsPath) {
        $destination = Assert-ExternalLabPath $ResultsPath
        if ((Test-Path -LiteralPath $destination) -or -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($destination)) -PathType Container)) { throw 'Results require a new file in an existing external directory' }
        foreach ($inputPath in @($StatePath, $OutputsPath)) {
            if ($inputPath -and $destination.Equals([IO.Path]::GetFullPath($inputPath), [StringComparison]::OrdinalIgnoreCase)) { throw 'Results cannot replace inputs' }
        }
        $resultsDestination = $destination
    }
    if (-not $RunLive) {
        $results.Add([pscustomobject]@{test='LIVE'; status='BLOCKED'; reason='Explicit RunLive switch and separate authorization required'; requests=0})
        return
    }
    if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell Core 7 or later is required' }
    if (-not $StatePath -or -not $OutputsPath) { throw 'External state and lab output paths are required' }
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1') -Force -Verbose:$false
    Import-Module (Join-Path $PSScriptRoot 'TestResults.psm1') -Force -Verbose:$false
    $state = Get-Content -LiteralPath (Assert-ExternalLabPath $StatePath) -Raw | ConvertFrom-Json -AsHashtable
    $lab = Get-Content -LiteralPath (Assert-ExternalLabPath $OutputsPath) -Raw | ConvertFrom-Json -AsHashtable
    Assert-LabState $state
    if ($state.phase -ne 'activate' -or $lab.phase -ne 'activate') { throw 'Private gateway activation has not been recorded' }
    if (@($lab.resourceGroups).Count -ne 4 -or @(Compare-Object $state.resourceGroups $lab.resourceGroups).Count) { throw 'Lab output group set does not match state' }
    foreach ($resourceId in @($lab.models, $lab.gateway, $lab.runner)) { Assert-LabResourceId $state $resourceId }
    if ($lab.models -notmatch '/providers/Microsoft.CognitiveServices/accounts/([a-z0-9-]+)$') { throw 'Invalid model resource output' }
    $modelName = $Matches[1]
    if ($lab.gateway -notmatch '/providers/Microsoft.ApiManagement/service/([a-z0-9-]+)$') { throw 'Invalid gateway output' }
    $gatewayName = $Matches[1]
    $hosts = [ordered]@{'DNS-GATEWAY'="${gatewayName}.azure-api.net"; 'DNS-MODELS'="${modelName}.openai.azure.com"}
    if (@($lab.cases).Count -ne 2) { throw 'Two use cases are required' }
    foreach ($caseIndex in 0..1) {
        $caseLabel = @('A', 'B')[$caseIndex]
        $useCase = $lab.cases[$caseIndex]
        Assert-LabResourceId $state $useCase.accountId
        Assert-LabResourceId $state $useCase.registryId
        if ($useCase.accountId -notmatch '/providers/Microsoft.CognitiveServices/accounts/([a-z0-9-]+)$') { throw 'Invalid Foundry resource output' }
        $hosts["DNS-FOUNDRY-$caseLabel"] = "$($Matches[1]).services.ai.azure.com"
        if ($useCase.registryId -notmatch '/providers/Microsoft.ContainerRegistry/registries/([a-z0-9]+)$') { throw 'Invalid registry output' }
        $hosts["DNS-REGISTRY-$caseLabel"] = "$($Matches[1]).azurecr.io"
    }
    if (@($hosts.Values | Select-Object -Unique).Count -ne 6) { throw 'Service hosts must be distinct' }
    $actors = @{}
    if (@($lab.identities).Count -ne $requiredActors.Count) { throw 'Exactly seven test actors are required' }
    foreach ($actor in $lab.identities) {
        Assert-LabResourceId $state $actor.resourceId
        if ($actor.resourceId -notmatch '/providers/Microsoft.ManagedIdentity/userAssignedIdentities/[a-z0-9-]+$') { throw 'Explicit user-assigned identity required' }
        if ($actor.actor -cnotin $requiredActors -or $actors.ContainsKey($actor.actor)) { throw 'Unexpected or duplicate test actor' }
        foreach ($field in @('clientId', 'principalId')) {
            if ([guid]::Parse($actor[$field]) -eq [guid]::Empty) { throw 'Empty test identity identifier' }
        }
        $actors[$actor.actor] = $actor
    }
    foreach ($field in @('clientId', 'principalId', 'resourceId')) {
        if (@($lab.identities | ForEach-Object { $_[$field].ToLowerInvariant() } | Select-Object -Unique).Count -ne 7) { throw 'Actors must use distinct identities' }
    }
    $dnsReady = $true
    foreach ($entry in $hosts.GetEnumerator()) {
        $budget.dnsQueries++
        $verdict = Get-GatewayDnsVerdict $entry.Value
        Add-GatewayResult $results $entry.Key $verdict 'Private addresses required for every answer; private endpoint ownership and public DNS are not established'
        if ($verdict -ne 'PASS') { $dnsReady = $false }
    }
    if (-not $dnsReady) {
        Add-GatewayResult $results 'GATEWAY-POSITIVE' 'BLOCKED' 'Private DNS prerequisites were not established; HTTP probes suppressed'
        return
    }
    $audience = 'https://cognitiveservices.azure.com'
    $gatewayUri = "https://${gatewayName}.azure-api.net/openai/deployments/lab-chat/chat/completions"
    $modelUri = "https://${modelName}.openai.azure.com/openai/deployments/lab-chat/chat/completions?api-version=2024-10-21"
    $tokens.client = Get-GatewayActorToken $actors.client $state.tenantId $audience $budget
    if (-not $tokens.client) {
        Add-GatewayResult $results 'GATEWAY-POSITIVE' 'BLOCKED' 'Expected IMDS identity, audience and token lifetime could not be established'
        return
    }
    $positive = Send-GatewayProbe $gatewayUri $tokens.client $budget
    $positiveVerdict = if ($positive.chatValid) { 'PASS' } elseif ($positive.status -ge 200 -and $positive.status -lt 300) { 'FAIL' } else { 'INCONCLUSIVE' }
    Add-GatewayResult $results 'GATEWAY-POSITIVE' $positiveVerdict 'Requires HTTP 200 and one completed assistant chat reply containing exactly OK' $positive.status
    if ($positiveVerdict -ne 'PASS') { return }

    $tokens.denied = Get-GatewayActorToken $actors.denied $state.tenantId $audience $budget
    if ($tokens.denied) {
        $probe = Send-GatewayProbe $gatewayUri $tokens.denied $budget
        Add-GatewayResult $results 'GATEWAY' (Get-GatewayNegativeVerdict $true $probe 'Caller') 'Requires CallerNotAllowed authorization denial after the positive control' $probe.status
    } else { Add-GatewayResult $results 'GATEWAY' 'BLOCKED' 'Expected IMDS identity, audience and token lifetime could not be established' }
    $probe = Send-GatewayProbe $gatewayUri '' $budget
    Add-GatewayResult $results 'GATEWAY-ANONYMOUS' (Get-GatewayNegativeVerdict $true $probe 'Authentication') 'Requires HTTP 401 for an anonymous request after the positive control' $probe.status
    $armToken = Get-GatewayActorToken $actors.client $state.tenantId 'https://management.azure.com/' $budget
    if ($armToken) {
        $probe = Send-GatewayProbe $gatewayUri $armToken $budget
        Add-GatewayResult $results 'GATEWAY-AUDIENCE' (Get-GatewayNegativeVerdict $true $probe 'Authentication') 'Requires HTTP 401 for a current ARM-audience IMDS token after the positive control' $probe.status
    } else { Add-GatewayResult $results 'GATEWAY-AUDIENCE' 'BLOCKED' 'A current ARM-audience IMDS token for the expected client identity could not be established' }
    $armToken = $null
    $probe = Send-GatewayProbe $gatewayUri 'synthetic-invalid-token' $budget
    Add-GatewayResult $results 'GATEWAY-INVALID-TOKEN' (Get-GatewayNegativeVerdict $true $probe 'Authentication') 'Requires HTTP 401 for a synthetic invalid bearer token after the positive control' $probe.status
    foreach ($actorName in $requiredActors) {
        $test = 'BYPASS-' + $actorName.ToUpperInvariant()
        if (-not $tokens.ContainsKey($actorName)) { $tokens[$actorName] = Get-GatewayActorToken $actors[$actorName] $state.tenantId $audience $budget }
        if (-not $tokens[$actorName]) {
            Add-GatewayResult $results $test 'BLOCKED' 'Expected IMDS identity, audience and token lifetime could not be established'
            continue
        }
        $probe = Send-GatewayProbe $modelUri $tokens[$actorName] $budget
        Add-GatewayResult $results $test (Get-GatewayNegativeVerdict $true $probe 'Bypass') 'Requires an explicit HTTP 403 action denial or HTTP 401 PermissionDenied with exactly "Principal does not have access to API/Operation."; requires verified IMDS claims and the same central endpoint positive through APIM; other network, authentication and availability failures are inconclusive' $probe.status
    }

    $wrongDeploymentUri = "https://${gatewayName}.azure-api.net/openai/deployments/unapproved-deployment/chat/completions"
    $probe = Send-GatewayProbe $wrongDeploymentUri $tokens.client $budget
    Add-GatewayResult $results 'C07-DEPLOYMENT-ROUTE' (Get-GatewayBoundaryVerdict $true $probe 404) 'Requires HTTP 404 for an allowed client selecting an unregistered deployment route; no matching operation is configured; backend non-invocation is not independently observed' $probe.status
    $probe = Send-GatewayProbe $gatewayUri $tokens.client $budget 'Oversize'
    Add-GatewayResult $results 'C07-BODY-SIZE' (Get-GatewayBoundaryVerdict $true $probe 400) 'Requires HTTP 400 for a valid chat body padded to 16385 UTF-8 bytes, one byte beyond the 16384-byte limit; HTTP 500 is a failure' $probe.status
    $invalidSchema = Send-GatewayProbe $gatewayUri $tokens.client $budget 'InvalidSchema'
    Add-GatewayResult $results 'C07-INVALID-SCHEMA' (Get-GatewayBoundaryVerdict $true $invalidSchema 400) 'Requires HTTP 400 for an empty messages array on the positive-control operation; minItems is 1' $invalidSchema.status
    $invalidJson = Send-GatewayProbe $gatewayUri $tokens.client $budget 'InvalidJson'
    Add-GatewayResult $results 'C07-INVALID-JSON' (Get-GatewayBoundaryVerdict $true $invalidJson 400) 'Requires HTTP 400 for syntactically invalid JSON on the positive-control operation' $invalidJson.status
    Add-GatewayResult $results 'C07-ADDITIONAL-FIELDS' 'BLOCKED' 'The current schema permits additional properties including tools; no disallowed-field assertion or inference probe is made'
    Add-GatewayResult $results 'C07-MODEL-BODY' 'BLOCKED' 'The current schema permits model and the policy removes it; response status or private backend headers cannot establish the selected backend model'
    if ($invalidJson.status -eq 400 -and $invalidSchema.status -eq 400) {
        $rateVerdict = 'INCONCLUSIVE'
        $rateStatus = 0
        $rateAttempts = 0
        foreach ($attempt in 1..20) {
            $probe = Send-GatewayProbe $gatewayUri $tokens.client $budget 'InvalidJson'
            $rateAttempts++
            $rateStatus = $probe.status
            if ($probe.status -ne 400) {
                $rateVerdict = Get-GatewayBoundaryVerdict $true $probe 429
                break
            }
        }
        Add-GatewayResult $results 'C07-RATE-LIMIT' $rateVerdict "Requires explicit HTTP 429 after same-operation OK and schema/JSON HTTP 400 controls; $rateAttempts of at most 20 malformed-body replays; shared 20/minute and 200/day counters persist across runs; coordinator must wait before another run, with no automatic retry or reset; exact threshold and backend non-invocation are not independently observed" $rateStatus
    } else {
        Add-GatewayResult $results 'C07-RATE-LIMIT' 'BLOCKED' 'Same-operation schema and malformed-JSON HTTP 400 controls were not both established; no rate replays, wait or automatic retry'
    }
} catch {
    Add-GatewayResult $results 'HARNESS' 'BLOCKED' 'Prerequisite validation or local execution failed; private diagnostics are not retained'
} finally {
    $tokens.Clear()
    $armToken = $null
    if ($RunLive) {
        foreach ($test in ($dnsTests + @('GATEWAY-POSITIVE') + $negativeTests + $boundaryTests)) {
            if ($test -notin $results.test) { Add-GatewayResult $results $test 'BLOCKED' 'Required prerequisites or semantic positive control were not established; probe suppressed' }
        }
        foreach ($pending in @('DEV', 'CONSUMER', 'ACR', 'PROMPT', 'HOSTED', 'NETWORK', 'TELEMETRY', 'DNS-PUBLIC')) {
            Add-GatewayResult $results $pending 'BLOCKED' 'Requires a dedicated scenario; DNS and model probes do not establish agent, runtime or registry authorization'
        }
    }
    if ($resultsDestination) {
        try {
            $report = [ordered]@{
                schemaVersion=1
                runLive=[bool]$RunLive
                requests=$budget.requests
                requestLimit=45
                inferenceCandidateRequests=$budget.inferenceCandidates
                inferenceCandidateLimit=20
                requestScope='IMDS token requests and HTTP probes; inference candidates exclude IMDS and syntactically invalid JSON; DNS resolutions counted separately'
                rateReplayLimit=20
                dnsQueries=$budget.dnsQueries
                elapsedSeconds=[math]::Round($timer.Elapsed.TotalSeconds,1)
                tests=$results.ToArray()
            }
            $json = $report | ConvertTo-Json -Depth 8
            Assert-PublicText $json
            $null = Assert-ExternalLabPath $resultsDestination
            $json | Out-File -LiteralPath $resultsDestination -Encoding utf8 -NoClobber -ErrorAction Stop
        } catch { Add-GatewayResult $results 'RESULTS' 'BLOCKED' 'External result persistence failed; no private diagnostics are emitted' }
    }
    $results.ToArray()
    Write-Output "requests: $($budget.requests)/45 (IMDS and HTTP); inference candidates: $($budget.inferenceCandidates)/20; DNS resolutions: $($budget.dnsQueries)/6"
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}