[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot '../scripts/TestResults.psm1') -Force
    $cases = @(
        @{positive=200; negative=403; code='CallerNotAllowed'; expected='PASS'},
        @{positive=200; negative=200; code=''; expected='FAIL'},
        @{positive=200; negative=201; code=''; expected='FAIL'},
        @{positive=500; negative=403; code='CallerNotAllowed'; expected='BLOCKED'},
        @{positive=0; negative=403; code='CallerNotAllowed'; expected='BLOCKED'},
        @{positive=200; negative=401; code='ExpiredToken'; expected='INCONCLUSIVE'},
        @{positive=200; negative=404; code='NotFound'; expected='INCONCLUSIVE'},
        @{positive=200; negative=429; code='RateLimit'; expected='INCONCLUSIVE'},
        @{positive=200; negative=0; code='TransportFailure'; expected='INCONCLUSIVE'},
        @{positive=200; negative=403; code='PublicNetworkAccessDisabled'; expected='INCONCLUSIVE'}
    )
    foreach ($case in $cases) {
        $verdict = Get-AuthorizationVerdict $case.positive $case.negative $case.code
        if ($verdict -ne $case.expected) { throw 'Authorization verdict misclassified a negative control' }
    }
    $harnessPath = Join-Path $PSScriptRoot '../scripts/Invoke-GatewayChecks.ps1'
    $parseTokens = $null
    $parseErrors = $null
    $harnessAst = [Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Gateway harness syntax is invalid' }
    $helperNames = @('ConvertTo-GatewayProbeResult', 'Get-GatewayNegativeVerdict', 'Get-PrivateAddressVerdict', 'Test-GatewayTokenClaims', 'Use-GatewayRequestBudget', 'New-GatewayProbeBody', 'Get-GatewayBoundaryVerdict')
    $helpers = @($harnessAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $helperNames }, $true))
    if ($helpers.Count -ne $helperNames.Count) { throw 'Missing pure gateway helpers' }
    foreach ($helper in $helpers) { . ([scriptblock]::Create($helper.Extent.Text)) }
    $checks = $cases.Count
    $validChat = @{object='chat.completion'; choices=@(@{message=@{role='assistant'; content='OK'}; finish_reason='stop'})} | ConvertTo-Json -Depth 8 -Compress
    if (-not (ConvertTo-GatewayProbeResult 200 $validChat).chatValid) { throw 'Valid positive chat was rejected' }
    $checks++
    foreach ($body in @('', 'not-json', '{}', '[]', '{"choices":[]}', '{"code":"CallerNotAllowed"}', '{"object":"chat.completion","choices":[{"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}')) {
        if ((ConvertTo-GatewayProbeResult 200 $body).chatValid) { throw 'Invalid positive chat was accepted' }
        $checks++
    }
    foreach ($kind in @('Caller', 'Authentication', 'Bypass')) {
        foreach ($status in 200..299) {
            $probe = ConvertTo-GatewayProbeResult $status '{}'
            if ((Get-GatewayNegativeVerdict $true $probe $kind) -ne 'FAIL') { throw 'A successful negative was not a failure' }
            if ((Get-GatewayNegativeVerdict $false $probe $kind) -ne 'BLOCKED') { throw 'Missing positive control did not block verdict' }
            $checks += 2
        }
    }
    $denial = ConvertTo-GatewayProbeResult 403 '{"error":{"code":"PermissionDenied","message":"The principal lacks the required data action."}}'
    if ((Get-GatewayNegativeVerdict $true $denial 'Bypass') -ne 'PASS') { throw 'Authorization denial was not recognized' }
    $checks++
    $permissionDeniedBody = '{"error":{"code":"PermissionDenied","message":"Principal does not have access to API/Operation."}}'
    $permissionDenied = ConvertTo-GatewayProbeResult 401 $permissionDeniedBody
    if ((Get-GatewayNegativeVerdict $true $permissionDenied 'Bypass') -ne 'PASS' -or (Get-GatewayNegativeVerdict $false $permissionDenied 'Bypass') -ne 'BLOCKED' -or (Get-GatewayNegativeVerdict $true $permissionDenied 'Caller') -ne 'INCONCLUSIVE') { throw 'Verified HTTP 401 bypass contract or scope misclassified' }
    $checks++
    if ((Get-AuthorizationVerdict 200 401 'PermissionDenied' @('PermissionDenied')) -ne 'INCONCLUSIVE') { throw 'Shared authorization helper accepted HTTP 401' }
    $checks++
    $unverifiedBypassBodies = @(
        '{"error":{"code":"AuthorizationFailed","message":"Principal does not have access to API/Operation."}}',
        '{"error":{"code":"permissiondenied","message":"Principal does not have access to API/Operation."}}',
        '{"error":{"code":"ExpiredToken","message":"Principal does not have access to API/Operation."}}',
        '{"error":{"code":"PermissionDenied","message":"principal does not have access to API/Operation."}}',
        '{"error":{"code":"PermissionDenied","message":"Principal does not have access to API/Operation"}}',
        '{"error":{"code":"PermissionDenied","message":"Principal does not have access to API/Operation. "}}',
        '{"error":{"code":"PermissionDenied","message":"Principal does not have access to API/Operation. Public network access is disabled."}}',
        '{"error":{"code":"PermissionDenied","message":"The principal lacks the required data action."}}',
        '{"error":{"code":"PermissionDenied","message":"Token expired or audience is invalid."}}',
        '{"error":{"code":"PermissionDenied","message":"Access denied due to Virtual Network/Firewall rules."}}',
        '{"error":{"code":"PermissionDenied"}}',
        '{"code":"PermissionDenied","message":"Principal does not have access to API/Operation."}',
        '{}',
        '<html/>'
    )
    foreach ($body in $unverifiedBypassBodies) {
        $probe = ConvertTo-GatewayProbeResult 401 $body
        if ((Get-GatewayNegativeVerdict $true $probe 'Bypass') -ne 'INCONCLUSIVE') { throw 'Unverified HTTP 401 proved a bypass denial' }
        $checks++
    }
    foreach ($status in @(0, 200, 201, 204, 299, 301, 403, 404, 429, 500, 503)) {
        $probe = ConvertTo-GatewayProbeResult $status $permissionDeniedBody
        $expected = if ($status -ge 200 -and $status -lt 300) { 'FAIL' } else { 'INCONCLUSIVE' }
        if ((Get-GatewayNegativeVerdict $true $probe 'Bypass') -ne $expected -or (Get-GatewayNegativeVerdict $false $probe 'Bypass') -ne 'BLOCKED') { throw 'Exact PermissionDenied body overrode HTTP status or positive prerequisite' }
        $checks++
    }
    foreach ($message in @('Access denied due to Virtual Network/Firewall rules.', 'Public network access is disabled.', 'The principal lacks the required data action; IP address is blocked.', 'Forbidden')) {
        $probe = ConvertTo-GatewayProbeResult 403 (@{error=@{code='PermissionDenied'; message=$message}} | ConvertTo-Json -Compress)
        if ((Get-GatewayNegativeVerdict $true $probe 'Bypass') -ne 'INCONCLUSIVE') { throw 'Non-authorization failure proved a bypass denial' }
        $checks++
    }
    foreach ($dnsCase in @(
        @{addresses=@('10.1.2.3', '172.16.0.1', '172.31.255.254', '192.168.1.1', 'fd00::1', '::ffff:10.1.2.3'); expected='PASS'},
        @{addresses=@('10.1.2.3', '8.8.8.8'); expected='FAIL'},
        @{addresses=@('172.15.255.255'); expected='FAIL'},
        @{addresses=@('172.32.0.1'); expected='FAIL'},
        @{addresses=@('127.0.0.1'); expected='FAIL'},
        @{addresses=@('169.254.169.254'); expected='FAIL'},
        @{addresses=@('::1'); expected='FAIL'},
        @{addresses=@('fe80::1'); expected='FAIL'},
        @{addresses=@(); expected='INCONCLUSIVE'},
        @{addresses=@('invalid'); expected='INCONCLUSIVE'}
    )) {
        if ((Get-PrivateAddressVerdict $dnsCase.addresses) -ne $dnsCase.expected) { throw 'Private DNS address verdict is incorrect' }
        $checks++
    }
    $result = @(& (Join-Path $PSScriptRoot '../scripts/Invoke-GatewayChecks.ps1')) | Where-Object { $_ -isnot [string] }
    if ($result.Count -ne 1 -or $result[0].status -ne 'BLOCKED' -or $result[0].requests -ne 0) { throw 'Live checks are not disabled by default' }
    $checks++
    $requestBudget = @{requests=0}
    foreach ($attempt in 1..45) { Use-GatewayRequestBudget $requestBudget }
    $rejected = $false
    try { Use-GatewayRequestBudget $requestBudget } catch { $rejected = $true }
    if (-not $rejected -or $requestBudget.requests -ne 45) { throw 'HTTP budget did not stop the forty-sixth attempt' }
    $checks++
    $requestBudget = @{requests=0; inferenceCandidates=0}
    foreach ($attempt in 1..20) { Use-GatewayRequestBudget $requestBudget -InferenceCandidate }
    $rejected = $false
    try { Use-GatewayRequestBudget $requestBudget -InferenceCandidate } catch { $rejected = $true }
    if (-not $rejected -or $requestBudget.requests -ne 20 -or $requestBudget.inferenceCandidates -ne 20) { throw 'Inference budget did not stop the twenty-first candidate' }
    Use-GatewayRequestBudget $requestBudget
    if ($requestBudget.requests -ne 21 -or $requestBudget.inferenceCandidates -ne 20) { throw 'Non-inference request was miscounted' }
    $checks += 2
    $oversizeBody = New-GatewayProbeBody 'Oversize'
    if ([Text.Encoding]::UTF8.GetByteCount($oversizeBody) -ne 16385 -or ($oversizeBody | ConvertFrom-Json -AsHashtable).messages[0].content -cne 'Reply with OK') { throw 'Oversize control is not a bounded valid chat plus padding' }
    $checks++
    foreach ($expectedStatus in @(400, 404, 429)) {
        foreach ($status in @(0, 200, 204, 299, 400, 401, 403, 404, 413, 415, 429, 500, 502, 503)) {
            $probe = ConvertTo-GatewayProbeResult $status '{}'
            $expected = if ($status -eq $expectedStatus) { 'PASS' } elseif ($status -in @(0, 401, 403, 429) -or ($expectedStatus -eq 429 -and $status -eq 400)) { 'INCONCLUSIVE' } else { 'FAIL' }
            if ((Get-GatewayBoundaryVerdict $true $probe $expectedStatus) -ne $expected -or (Get-GatewayBoundaryVerdict $false $probe $expectedStatus) -ne 'BLOCKED') { throw 'Boundary verdict accepted an incorrect status or missing prerequisite' }
            $checks += 2
        }
    }

    function New-SyntheticToken([hashtable]$Claims) {
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return "synthetic.$payload.signature"
    }
    $tokenClaims = @{tid='22222222-2222-4222-8222-222222222222'; oid='33333333-3333-4333-8333-333333333333'; aud='https://cognitiveservices.azure.com'; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600}
    if (-not (Test-GatewayTokenClaims (New-SyntheticToken $tokenClaims) $tokenClaims.tid $tokenClaims.oid @($tokenClaims.aud))) { throw 'Expected token claims rejected' }
    $checks++
    foreach ($claimCase in @(
        @{field='tid'; value='11111111-1111-4111-8111-111111111111'},
        @{field='oid'; value='11111111-1111-4111-8111-111111111111'},
        @{field='aud'; value='https://management.azure.com/'},
        @{field='aud'; value=@('https://cognitiveservices.azure.com')},
        @{field='exp'; value=0},
        @{field='exp'; value=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+30)},
        @{field='nbf'; value=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600)}
    )) {
        $changedClaims = $tokenClaims.Clone()
        $changedClaims[$claimCase.field] = $claimCase.value
        if (Test-GatewayTokenClaims (New-SyntheticToken $changedClaims) $tokenClaims.tid $tokenClaims.oid @($tokenClaims.aud)) { throw 'Unexpected token claims accepted' }
        $checks++
    }
    foreach ($badToken in @('', 'invalid', 'synthetic.!.signature', 'synthetic..signature')) {
        if (Test-GatewayTokenClaims $badToken $tokenClaims.tid $tokenClaims.oid @($tokenClaims.aud)) { throw 'Malformed token accepted' }
        $checks++
    }
    foreach ($chatChange in @('role', 'content', 'finish_reason', 'object')) {
        $changedChat = $validChat | ConvertFrom-Json -AsHashtable
        switch ($chatChange) {
            'role' { $changedChat.choices[0].message.role = 'user' }
            'content' { $changedChat.choices[0].message.content = 'Unexpected answer' }
            'finish_reason' { $changedChat.choices[0].finish_reason = 'length' }
            'object' { $changedChat.object = 'error' }
        }
        if ((ConvertTo-GatewayProbeResult 200 ($changedChat | ConvertTo-Json -Depth 8 -Compress)).chatValid) { throw 'Unexpected chat response accepted' }
        $checks++
    }
    $dnsDefinition = $harnessAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GatewayDnsVerdict' }, $true)
    if (-not $dnsDefinition) { throw 'DNS boundary missing' }
    $dnsStub = @'
function Get-GatewayDnsVerdict {
    param([string]$HostName)
    if ($HostName -notin $fixture.expectedHosts) { throw 'Unexpected synthetic DNS target' }
    $fixture.dns.Add($HostName)
    return $fixture.dnsVerdict
}
'@
    $harnessRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts'))
    $mockedHarness = [scriptblock]::Create($harnessAst.Extent.Text.Replace($dnsDefinition.Extent.Text, $dnsStub).Replace('$PSScriptRoot', '$harnessRoot'))
    [xml]$policy = Get-Content -LiteralPath (Join-Path $harnessRoot '../infra/policies/inference.xml') -Raw
    $inboundNames = @($policy.policies.inbound.ChildNodes | ForEach-Object { $_.LocalName })
    $ratePolicy = $policy.SelectSingleNode('/policies/inbound/rate-limit-by-key')
    $validationPolicy = $policy.SelectSingleNode('/policies/inbound/validate-content')
    $quotaPolicy = $policy.SelectSingleNode('/policies/inbound/quota-by-key')
    if ($inboundNames.IndexOf('rate-limit-by-key') -ge $inboundNames.IndexOf('validate-content') -or $ratePolicy.calls -ne '20' -or $ratePolicy.'renewal-period' -ne '60' -or $ratePolicy.HasAttribute('increment-condition') -or $ratePolicy.HasAttribute('increment-count') -or $quotaPolicy.calls -ne '200' -or $quotaPolicy.'renewal-period' -ne '86400') { throw 'Rate replay fixtures no longer match the unconditional inbound policy ordering and budgets' }
    if ($validationPolicy.'max-size' -ne '16384' -or $validationPolicy.'size-exceeded-action' -ne 'prevent' -or $validationPolicy.content.action -ne 'prevent') { throw 'Body boundary fixtures no longer match the validation policy' }
    $schema = Get-Content -LiteralPath (Join-Path $harnessRoot '../infra/policies/chat.schema.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($schema.properties.messages.minItems -ne 1 -or ($schema.ContainsKey('additionalProperties') -and $schema.additionalProperties -ne $true) -or $validationPolicy.content.'allow-additional-properties' -eq 'false') { throw 'Schema boundary and additional-field limitations need to be reevaluated' }
    $checks += 3

    function Invoke-OfflineHarness([hashtable]$Options = @{}) {
        $fixtureState = @{
            subscriptionId='11111111-1111-4111-8111-111111111111'
            tenantId='22222222-2222-4222-8222-222222222222'
            ownershipId='33333333-3333-4333-8333-333333333333'
            labId='sample01'
            phase='activate'
            resourceGroups=@('models', 'integration', 'case-a', 'case-b') | ForEach-Object { "rg-fgl-sample01-$_" }
        }
        $prefix = "/subscriptions/$($fixtureState.subscriptionId)/resourceGroups/rg-fgl-sample01"
        $fixtureLab = @{
            phase='activate'; resourceGroups=$fixtureState.resourceGroups
            models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/synthetic-models"
            gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/synthetic-gateway"
            runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/synthetic-runner"
            identities=@('dev-a', 'consumer-a', 'dev-b', 'publisher-a', 'publisher-b', 'client', 'denied') | ForEach-Object {
                @{actor=$_; clientId=[guid]::NewGuid().ToString(); principalId=[guid]::NewGuid().ToString(); resourceId="$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/synthetic-$_"}
            }
            cases=@('a', 'b') | ForEach-Object { @{accountId="$prefix-case-$_/providers/Microsoft.CognitiveServices/accounts/synthetic-case-$_"; registryId="$prefix-case-$_/providers/Microsoft.ContainerRegistry/registries/syntheticregistry$_"} }
        }
        $hostValues = @(('synthetic-gateway' + '.azure-api.net'), ('synthetic-models' + '.openai.azure.com'))
        $hostValues += @('a', 'b') | ForEach-Object { 'synthetic-case-' + $_ + '.services.ai.azure.com'; 'syntheticregistry' + $_ + '.azurecr.io' }
        $fixture = @{
            state=$fixtureState; lab=$fixtureLab; expectedHosts=$hostValues
            statePath=(Join-Path ([IO.Path]::GetTempPath()) "fgl-fixture-$([guid]::NewGuid().ToString('N'))-state.json")
            outputsPath=(Join-Path ([IO.Path]::GetTempPath()) "fgl-fixture-$([guid]::NewGuid().ToString('N'))-outputs.json")
            resultsPath=(Join-Path ([IO.Path]::GetTempPath()) "fgl-fixture-$([guid]::NewGuid().ToString('N'))-results.json")
            dnsVerdict='PASS'; positiveStatus=200; positiveBody=$validChat; negativeStatus=403
            bypassStatus=$null; bypassBody='{"error":{"code":"PermissionDenied","message":"The principal lacks the required data action. PRIVATE-DATA-SENTINEL"}}'
            authenticationStatus=401; tokenClaim=''; tokenActor=''; throwToken=$false; throwHttp=$false
            writeFails=$false; savedJson=$null; reads=0; readFailsAt=0
            boundaryStatuses=@{Route=404; Oversize=400; InvalidSchema=400; InvalidJson=400}
            rateCount=0; invalidJsonRequests=0; rateStatus=0; rateSequence=@(); readErrorKind=''; readErrorStatus=400
            dns=[System.Collections.Generic.List[string]]::new()
            imds=[System.Collections.Generic.List[object]]::new()
            http=[System.Collections.Generic.List[object]]::new()
            issued=@{}
        }
        foreach ($key in $Options.Keys) { $fixture[$key] = $Options[$key] }
        if ($Options.badPhase) { $fixtureState.phase = 'lock' }
        if ($Options.duplicateActor) { $fixtureLab.identities[1] = $fixtureLab.identities[0] }
        if ($Options.outsideScope) { $fixtureLab.cases[0].accountId = "$prefix-other/providers/Microsoft.CognitiveServices/accounts/synthetic-other" }
        if ($Options.internalState) { $fixture.statePath = Join-Path $harnessRoot 'synthetic-state.json' }
        if ($Options.internalOutputs) { $fixture.outputsPath = Join-Path $harnessRoot 'synthetic-outputs.json' }
        if ($Options.internalResults) { $fixture.resultsPath = Join-Path $harnessRoot 'synthetic-results.json' }
        if ($Options.collidingResults) { $fixture.resultsPath = $fixture.statePath }

        function Get-Content {
            [CmdletBinding()]
            param([string]$LiteralPath, [switch]$Raw)
            $fixture.reads++
            if ($fixture.reads -eq $fixture.readFailsAt) { throw 'PRIVATE-DATA-SENTINEL' }
            if ($LiteralPath -eq $fixture.statePath) { return $fixture.state | ConvertTo-Json -Depth 12 }
            if ($LiteralPath -eq $fixture.outputsPath) { return $fixture.lab | ConvertTo-Json -Depth 12 }
            throw 'Unexpected file read in offline harness'
        }
        function Invoke-RestMethod {
            [CmdletBinding()]
            param([uri]$Uri, [hashtable]$Headers, [switch]$NoProxy, [int]$TimeoutSec, [int]$MaximumRedirection, [int]$MaximumRetryCount)
            if ($Uri.Host -ne '169.254.169.254' -or $Uri.AbsolutePath -ne '/metadata/identity/oauth2/token' -or $Headers.Metadata -ne 'true' -or -not $NoProxy -or $TimeoutSec -ne 20 -or $MaximumRedirection -ne 0 -or $MaximumRetryCount -ne 0) { throw 'Unsafe IMDS request configuration' }
            $query = @{}
            foreach ($part in $Uri.Query.TrimStart('?').Split('&')) { $pair = $part.Split('=', 2); $query[$pair[0]] = [uri]::UnescapeDataString($pair[1]) }
            $actor = @($fixture.lab.identities | Where-Object { $_.clientId -eq $query.client_id })
            if ($actor.Count -ne 1 -or $query['api-version'] -ne '2018-02-01') { throw 'Explicit actor selector missing' }
            $fixture.imds.Add(@{actor=$actor[0].actor; audience=$query.resource})
            if ($fixture.throwToken -and $actor[0].actor -eq $fixture.tokenActor) { throw 'PRIVATE-DATA-SENTINEL' }
            $claims = @{tid=$fixture.state.tenantId; oid=$actor[0].principalId; aud=$query.resource; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600}
            if ($fixture.tokenClaim -and $actor[0].actor -eq $fixture.tokenActor) { $claims[$fixture.tokenClaim] = 'unexpected' }
            $token = New-SyntheticToken $claims
            $fixture.issued[$token] = @{actor=$actor[0].actor; audience=$query.resource}
            return @{access_token=$token; token_type='Bearer'}
        }
        function Invoke-WebRequest {
            [CmdletBinding()]
            param([uri]$Uri, [string]$Method, [hashtable]$Headers, [string]$ContentType, [string]$Body, [switch]$NoProxy, [int]$TimeoutSec, [int]$MaximumRedirection, [int]$MaximumRetryCount, [switch]$SkipHttpErrorCheck)
            if (-not $NoProxy -or $TimeoutSec -ne 30 -or $MaximumRedirection -ne 0 -or $MaximumRetryCount -ne 0 -or -not $SkipHttpErrorCheck -or $Method -ne 'Post' -or $ContentType -ne 'application/json' -or $Uri.Scheme -ne 'https') { throw 'Unsafe probe configuration' }
            $bodyKind = 'Chat'
            if ($Body -ceq '{"messages":[') { $bodyKind = 'InvalidJson' }
            elseif ($Body -ceq '{"messages":[]}') { $bodyKind = 'InvalidSchema' }
            else {
                $request = $Body | ConvertFrom-Json -AsHashtable
                if ($request.max_tokens -ne 64 -or $request.n -ne 1 -or $request.stream -ne $false -or $request.messages.Count -ne 1 -or $request.messages[0].content -cne 'Reply with OK') { throw 'Unbounded or unexpected chat body' }
                if ([Text.Encoding]::UTF8.GetByteCount($Body) -eq 16385) { $bodyKind = 'Oversize' }
                elseif ([Text.Encoding]::UTF8.GetByteCount($Body) -gt 256) { throw 'Unexpected chat size' }
            }
            $token = ([string]$Headers.Authorization) -replace '^Bearer ', ''
            $identity = $fixture.issued[$token]
            $kind = ''
            if ($Uri.Host -eq $fixture.expectedHosts[0]) {
                if ($Uri.Query) { throw 'Unexpected gateway query' }
                if ($Uri.AbsolutePath -eq '/openai/deployments/unapproved-deployment/chat/completions') {
                    if ($identity.actor -ne 'client' -or $identity.audience -cne 'https://cognitiveservices.azure.com' -or $bodyKind -ne 'Chat') { throw 'Route boundary did not use the allowed client and a bounded body' }
                    $kind = 'Route'
                } else {
                    if ($Uri.AbsolutePath -ne '/openai/deployments/lab-chat/chat/completions') { throw 'Unexpected gateway route' }
                    $kind = if (-not $token) { 'Anonymous' } elseif ($token -ceq 'synthetic-invalid-token') { 'Invalid' } elseif ($identity.audience -ceq 'https://management.azure.com/') { 'Audience' } elseif ($identity.actor -eq 'client') { 'Positive' } elseif ($identity.actor -eq 'denied') { 'Caller' } else { throw 'Unexpected gateway identity' }
                    if ($kind -eq 'Positive') {
                        $fixture.rateCount++
                        if ($bodyKind -ne 'Chat') { $kind = $bodyKind }
                        if ($bodyKind -eq 'InvalidJson') {
                            $fixture.invalidJsonRequests++
                            if ($fixture.invalidJsonRequests -gt 1) { $kind = 'Rate' }
                        }
                    } elseif ($bodyKind -ne 'Chat') { throw 'Boundary body used with the wrong identity' }
                }
            } elseif ($Uri.Host -eq $fixture.expectedHosts[1]) {
                if ($Uri.AbsolutePath -ne '/openai/deployments/lab-chat/chat/completions' -or $Uri.Query -ne '?api-version=2024-10-21' -or -not $identity -or $identity.audience -cne 'https://cognitiveservices.azure.com' -or $bodyKind -ne 'Chat') { throw 'Unexpected central model request' }
                $kind = 'Bypass'
            } else { throw 'Unexpected HTTP target' }
            $fixture.http.Add(@{kind=$kind; actor=$identity.actor; token=$token; body=$Body; uri=$Uri.AbsoluteUri; inferenceCandidate=($bodyKind -ne 'InvalidJson')})
            if ($fixture.throwHttp) { throw 'PRIVATE-DATA-SENTINEL' }
            if ($fixture.readErrorKind -eq $kind) {
                $readError = [IO.IOException]::new('PRIVATE-DATA-SENTINEL')
                $readError | Add-Member -NotePropertyName Response -NotePropertyValue @{StatusCode=$fixture.readErrorStatus}
                throw $readError
            }
            if ($fixture.boundaryStatuses.ContainsKey($kind)) { return @{StatusCode=$fixture.boundaryStatuses[$kind]; Content='{"message":"PRIVATE-DATA-SENTINEL"}'} }
            switch ($kind) {
                'Positive' { return @{StatusCode=$fixture.positiveStatus; Content=$fixture.positiveBody} }
                'Caller' { return @{StatusCode=$fixture.negativeStatus; Content='{"code":"CallerNotAllowed","message":"PRIVATE-DATA-SENTINEL"}'} }
                'Bypass' {
                    $status = if ($null -ne $fixture.bypassStatus) { $fixture.bypassStatus } else { $fixture.negativeStatus }
                    return @{StatusCode=$status; Content=$fixture.bypassBody}
                }
                'Rate' {
                    $rateIndex = $fixture.invalidJsonRequests - 2
                    $status = if ($rateIndex -lt $fixture.rateSequence.Count) { $fixture.rateSequence[$rateIndex] } elseif ($fixture.rateStatus) { $fixture.rateStatus } elseif ($fixture.rateCount -gt 20) { 429 } else { 400 }
                    return @{StatusCode=$status; Content='{"message":"PRIVATE-DATA-SENTINEL"}'}
                }
                default { return @{StatusCode=$fixture.authenticationStatus; Content='{"error":{"message":"PRIVATE-DATA-SENTINEL"}}'} }
            }
        }
        function Out-File {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, [string]$LiteralPath, [string]$Encoding, [switch]$NoClobber)
            process {
                if ($fixture.writeFails) { throw 'PRIVATE-DATA-SENTINEL' }
                if (-not $NoClobber -or $Encoding -ne 'utf8' -or $LiteralPath -ne $fixture.resultsPath) { throw 'Unsafe results write' }
                $fixture.savedJson = [string]$InputObject
            }
        }
        $arguments = @{StatePath=$fixture.statePath; OutputsPath=$fixture.outputsPath; ResultsPath=$fixture.resultsPath; RunLive=(-not $Options.noLive)}
        $captured = @(& $mockedHarness @arguments *>&1)
        $text = $captured | ConvertTo-Json -Depth 12 -Compress
        if ($text -match 'PRIVATE-DATA-SENTINEL' -or $fixture.savedJson -match 'PRIVATE-DATA-SENTINEL') { throw 'Private response or exception text escaped the harness' }
        foreach ($privateValue in @($fixture.expectedHosts) + @($fixture.issued.Keys) + @($fixtureLab.identities.clientId) + @($fixtureLab.identities.principalId) + @($fixtureState.subscriptionId, $fixtureState.tenantId)) {
            if ($text.Contains($privateValue) -or ($fixture.savedJson -and $fixture.savedJson.Contains($privateValue))) { throw 'Private endpoint, identity or token escaped the harness' }
        }
        if ($fixture.savedJson) {
            $report = $fixture.savedJson | ConvertFrom-Json -AsHashtable
            if ($report.requests -ne $fixture.imds.Count + $fixture.http.Count -or $report.requests -gt 45 -or $report.requestLimit -ne 45 -or $report.inferenceCandidateLimit -ne 20 -or $report.inferenceCandidateRequests -gt 20 -or $report.dnsQueries -ne $fixture.dns.Count) { throw 'Request accounting mismatch' }
            if ($report.inferenceCandidateRequests -ne @($fixture.http | Where-Object { $_.inferenceCandidate }).Count -or $report.rateReplayLimit -ne 20) { throw 'Inference candidate or replay accounting mismatch' }
            if (@($report.tests | Where-Object { $_.status -notin @('PASS', 'FAIL', 'BLOCKED', 'INCONCLUSIVE') }).Count) { throw 'Invalid persisted status' }
            $fixture.report = $report
        }
        $fixture.rows = @($captured | Where-Object { $_ -isnot [string] -and $_.PSObject.Properties.Name -contains 'test' })
        return $fixture
    }

    $complete = Invoke-OfflineHarness
    if (-not $complete.savedJson -or $complete.report.requests -ne 41 -or $complete.imds.Count -ne 8 -or $complete.http.Count -ne 33 -or $complete.dns.Count -ne 6 -or $complete.http[0].kind -ne 'Positive' -or $complete.report.inferenceCandidateRequests -ne 15) { throw 'Complete offline cycle failed or exceeded its bounds' }
    if (@($complete.rows | Where-Object { $_.test -like 'BYPASS-*' -and $_.status -eq 'PASS' }).Count -ne 7) { throw 'Seven explicit bypass actors were not checked' }
    if (@($complete.http | Where-Object { $_.kind -eq 'Bypass' } | ForEach-Object { $_.actor } | Select-Object -Unique).Count -ne 7) { throw 'Bypass actor coverage is incomplete' }
    $verifiedBypassOptions = @{bypassStatus=401; bypassBody=$permissionDeniedBody}
    $verifiedBypass = Invoke-OfflineHarness $verifiedBypassOptions
    if (@($verifiedBypass.rows | Where-Object { $_.test -eq 'GATEWAY-POSITIVE' -and $_.status -eq 'PASS' -and $_.httpStatus -eq 200 }).Count -ne 1 -or @($verifiedBypass.rows | Where-Object { $_.test -like 'BYPASS-*' -and $_.status -eq 'PASS' -and $_.httpStatus -eq 401 }).Count -ne 7) { throw 'Observed bypass contract failed with semantic APIM positive and explicit IMDS identities' }
    $checks++
    $positiveRequest = $verifiedBypass.http[0]
    $clientBypass = @($verifiedBypass.http | Where-Object { $_.kind -eq 'Bypass' -and $_.actor -eq 'client' })
    if ($positiveRequest.kind -ne 'Positive' -or $clientBypass.Count -ne 1 -or $clientBypass[0].token -cne $positiveRequest.token -or $clientBypass[0].body -cne $positiveRequest.body -or ([uri]$clientBypass[0].uri).AbsolutePath -cne ([uri]$positiveRequest.uri).AbsolutePath) { throw 'Client bypass changed the positive token, body or operation' }
    $checks++
    foreach ($request in @($verifiedBypass.http | Where-Object { $_.kind -eq 'Bypass' })) {
        $actor = @($verifiedBypass.lab.identities | Where-Object { $_.actor -ceq $request.actor })[0]
        if (-not (Test-GatewayTokenClaims $request.token $verifiedBypass.state.tenantId $actor.principalId @('https://cognitiveservices.azure.com')) -or ([uri]$request.uri).Host -cne $verifiedBypass.expectedHosts[1]) { throw 'Bypass used unverified claims or a different central endpoint' }
        $checks++
    }
    foreach ($row in @($verifiedBypass.report.tests | Where-Object { $_.test -like 'BYPASS-*' })) {
        if (-not $row.reason.Contains('HTTP 403') -or -not $row.reason.Contains('HTTP 401 PermissionDenied') -or -not $row.reason.Contains('Principal does not have access to API/Operation.')) { throw 'Bypass reason does not describe the explicit HTTP 401 contract' }
        $checks++
    }
    foreach ($body in $unverifiedBypassBodies) {
        $inconclusive = Invoke-OfflineHarness @{bypassStatus=401; bypassBody=$body}
        if (@($inconclusive.rows | Where-Object { $_.test -like 'BYPASS-*' -and $_.status -eq 'INCONCLUSIVE' -and $_.httpStatus -eq 401 }).Count -ne 7) { throw 'Unverified HTTP 401 passed the full bypass harness' }
        $checks++
    }
    foreach ($change in @(@{positiveStatus=503}, @{positiveBody='{}'}, @{dnsVerdict='INCONCLUSIVE'})) {
        $options = $verifiedBypassOptions.Clone()
        foreach ($key in $change.Keys) { $options[$key] = $change[$key] }
        $blocked = Invoke-OfflineHarness $options
        if (@($blocked.rows | Where-Object { $_.test -like 'BYPASS-*' -and $_.status -eq 'BLOCKED' }).Count -ne 7 -or @($blocked.http | Where-Object { $_.kind -eq 'Bypass' }).Count) { throw 'Observed HTTP 401 bypass ran without the positive or DNS prerequisite' }
        $checks++
    }
    foreach ($actorName in @('client', 'dev-a')) {
        foreach ($field in @('tid', 'oid', 'aud', 'exp')) {
            $options = $verifiedBypassOptions.Clone()
            $options.tokenActor = $actorName
            $options.tokenClaim = $field
            $blocked = Invoke-OfflineHarness $options
            $testName = 'BYPASS-' + $actorName.ToUpperInvariant()
            if (@($blocked.rows | Where-Object { $_.test -eq $testName -and $_.status -eq 'BLOCKED' }).Count -ne 1 -or @($blocked.http | Where-Object { $_.actor -eq $actorName }).Count) { throw 'Observed bypass contract bypassed IMDS claim validation' }
            $checks++
        }
    }
    $unreadableBypass = Invoke-OfflineHarness @{bypassStatus=401; bypassBody=$permissionDeniedBody; readErrorKind='Bypass'; readErrorStatus=401}
    if (@($unreadableBypass.rows | Where-Object { $_.test -like 'BYPASS-*' -and $_.status -eq 'INCONCLUSIVE' -and $_.httpStatus -eq 0 }).Count -ne 7) { throw 'Response read failure proved the HTTP 401 bypass contract' }
    $checks++
    foreach ($pending in @('DEV', 'CONSUMER', 'ACR', 'PROMPT', 'HOSTED', 'NETWORK', 'TELEMETRY', 'DNS-PUBLIC')) {
        if (@($complete.rows | Where-Object { $_.test -eq $pending -and $_.status -eq 'BLOCKED' }).Count -ne 1) { throw 'Higher scenario was claimed by model probes' }
        $checks++
    }
    $checks += 3
    foreach ($boundary in @('C07-DEPLOYMENT-ROUTE', 'C07-BODY-SIZE', 'C07-INVALID-SCHEMA', 'C07-INVALID-JSON', 'C07-RATE-LIMIT')) {
        if (@($complete.rows | Where-Object { $_.test -eq $boundary -and $_.status -eq 'PASS' }).Count -ne 1) { throw 'Boundary coverage is incomplete' }
        $checks++
    }
    foreach ($limitation in @('C07-ADDITIONAL-FIELDS', 'C07-MODEL-BODY')) {
        if (@($complete.rows | Where-Object { $_.test -eq $limitation -and $_.status -eq 'BLOCKED' }).Count -ne 1) { throw 'Unprovable body or model behavior was claimed' }
        $checks++
    }
    if (@($complete.http | Where-Object { $_.kind -eq 'Positive' }).Count -ne 1 -or @($complete.http | Where-Object { $_.kind -eq 'Rate' }).Count -ne 17) { throw 'Rate check repeated inference or used an unexpected number of probes' }
    $positiveUri = $complete.http[0].uri
    foreach ($request in @($complete.http | Where-Object { $_.kind -in @('InvalidSchema', 'InvalidJson', 'Rate') })) {
        if ($request.uri -cne $positiveUri -or $request.actor -ne 'client' -or ($request.kind -eq 'Rate' -and $request.body -cne '{"messages":[')) { throw 'Rate controls changed operation, caller or malformed body' }
        $checks++
    }
    $bounded = Invoke-OfflineHarness @{rateStatus=400}
    if ($bounded.report.requests -ne 44 -or @($bounded.http | Where-Object { $_.kind -eq 'Rate' }).Count -ne 20 -or @($bounded.rows | Where-Object { $_.test -eq 'C07-RATE-LIMIT' -and $_.status -eq 'INCONCLUSIVE' }).Count -ne 1) { throw 'Non-throttling service exceeded the bounded replay budget or passed without 429' }
    $checks++
    $disabled = Invoke-OfflineHarness @{noLive=$true}
    if ($disabled.reads -ne 0 -or $disabled.report.requests -ne 0 -or $disabled.dns.Count -ne 0 -or $disabled.rows.Count -ne 1 -or $disabled.rows[0].status -ne 'BLOCKED') { throw 'Default persistence enabled live work or read private input' }
    $checks++
    foreach ($failure in @(@{positiveStatus=503}, @{positiveStatus=429}, @{positiveBody='{}'}, @{throwHttp=$true})) {
        $blocked = Invoke-OfflineHarness $failure
        if ($blocked.report.requests -ne 2 -or $blocked.http.Count -ne 1 -or @($blocked.rows | Where-Object { ($_.test -like 'BYPASS-*' -or $_.test -like 'C07-*' -or $_.test -in @('GATEWAY', 'GATEWAY-ANONYMOUS', 'GATEWAY-AUDIENCE', 'GATEWAY-INVALID-TOKEN')) -and $_.status -ne 'BLOCKED' }).Count) { throw 'Failed positive control did not suppress every negative probe' }
        $checks++
    }
    foreach ($dnsFailure in @('FAIL', 'INCONCLUSIVE')) {
        $blocked = Invoke-OfflineHarness @{dnsVerdict=$dnsFailure}
        if ($blocked.report.requests -ne 0 -or $blocked.dns.Count -ne 6) { throw 'DNS failure did not suppress HTTP work' }
        $checks++
    }
    foreach ($tokenField in @('tid', 'oid', 'aud')) {
        $blocked = Invoke-OfflineHarness @{tokenActor='client'; tokenClaim=$tokenField}
        if ($blocked.report.requests -ne 1 -or $blocked.http.Count -ne 0) { throw 'Unexpected token claims reached an endpoint' }
        $checks++
    }
    $missingActorToken = Invoke-OfflineHarness @{tokenActor='denied'; throwToken=$true}
    if (@($missingActorToken.imds | Where-Object { $_.actor -eq 'denied' }).Count -ne 1 -or @($missingActorToken.http | Where-Object { $_.actor -eq 'denied' }).Count -ne 0 -or $missingActorToken.report.requests -ne 39) { throw 'Missing actor token was retried or used anonymously' }
    $checks++
    $unexpectedSuccess = Invoke-OfflineHarness @{negativeStatus=204; authenticationStatus=299}
    if (@($unexpectedSuccess.rows | Where-Object { $_.status -eq 'FAIL' }).Count -ne 11) { throw 'Successful negative probes did not all fail' }
    $checks++
    foreach ($boundaryKind in @('Route', 'Oversize', 'InvalidSchema', 'InvalidJson')) {
        foreach ($status in @(200, 204, 401, 403, 404, 413, 429, 500)) {
            $statuses = @{Route=404; Oversize=400; InvalidSchema=400; InvalidJson=400}
            $statuses[$boundaryKind] = $status
            $observed = Invoke-OfflineHarness @{boundaryStatuses=$statuses}
            $testName = @{Route='C07-DEPLOYMENT-ROUTE'; Oversize='C07-BODY-SIZE'; InvalidSchema='C07-INVALID-SCHEMA'; InvalidJson='C07-INVALID-JSON'}[$boundaryKind]
            $expected = if ($boundaryKind -eq 'Route' -and $status -eq 404) { 'PASS' } elseif ($status -in @(401, 403, 429)) { 'INCONCLUSIVE' } else { 'FAIL' }
            if (@($observed.rows | Where-Object { $_.test -eq $testName -and $_.status -eq $expected }).Count -ne 1) { throw 'Boundary response was misclassified' }
            if ($boundaryKind -in @('InvalidSchema', 'InvalidJson') -and ($observed.report.requests -ne 24 -or @($observed.http | Where-Object { $_.kind -eq 'Rate' }).Count -ne 0 -or @($observed.rows | Where-Object { $_.test -eq 'C07-RATE-LIMIT' -and $_.status -eq 'BLOCKED' }).Count -ne 1)) { throw 'Rate replay ran without both earlier same-operation 400 controls' }
            $checks += 2
        }
    }
    foreach ($rateStatus in @(200, 204, 299, 401, 403, 404, 429, 500, 503)) {
        $observed = Invoke-OfflineHarness @{rateSequence=@(400, $rateStatus, 429)}
        $expected = if ($rateStatus -eq 429) { 'PASS' } elseif ($rateStatus -in @(401, 403)) { 'INCONCLUSIVE' } else { 'FAIL' }
        if ($observed.report.requests -ne 26 -or @($observed.http | Where-Object { $_.kind -eq 'Rate' }).Count -ne 2 -or @($observed.rows | Where-Object { $_.test -eq 'C07-RATE-LIMIT' -and $_.status -eq $expected -and $_.httpStatus -eq $rateStatus }).Count -ne 1) { throw 'Rate replay retried an unexpected response or passed without explicit HTTP 429' }
        $checks++
    }
    foreach ($readFailure in @(
        @{kind='Positive'; status=200; requests=2},
        @{kind='Route'; status=404; requests=41},
        @{kind='Oversize'; status=400; requests=41},
        @{kind='InvalidSchema'; status=400; requests=24},
        @{kind='InvalidJson'; status=400; requests=24},
        @{kind='Rate'; status=429; requests=25}
    )) {
        $observed = Invoke-OfflineHarness @{readErrorKind=$readFailure.kind; readErrorStatus=$readFailure.status}
        $testName = @{Positive='GATEWAY-POSITIVE'; Route='C07-DEPLOYMENT-ROUTE'; Oversize='C07-BODY-SIZE'; InvalidSchema='C07-INVALID-SCHEMA'; InvalidJson='C07-INVALID-JSON'; Rate='C07-RATE-LIMIT'}[$readFailure.kind]
        if ($observed.report.requests -ne $readFailure.requests -or @($observed.rows | Where-Object { $_.test -eq $testName -and $_.status -eq 'INCONCLUSIVE' -and $_.httpStatus -eq 0 }).Count -ne 1) { throw 'Response read failure was miscounted or treated as a completed response' }
        $checks++
    }
    foreach ($readNumber in 1..2) {
        $observed = Invoke-OfflineHarness @{readFailsAt=$readNumber}
        if ($observed.reads -ne $readNumber -or $observed.report.requests -ne 0 -or $observed.dns.Count -ne 0 -or @($observed.rows | Where-Object { $_.test -eq 'HARNESS' -and $_.status -eq 'BLOCKED' }).Count -ne 1) { throw 'Input read failure did not block probes' }
        $disabledRead = Invoke-OfflineHarness @{noLive=$true; readFailsAt=$readNumber}
        if ($disabledRead.reads -ne 0 -or $disabledRead.report.requests -ne 0 -or $disabledRead.rows.Count -ne 1) { throw 'NoRunLive attempted input reads' }
        $checks += 2
    }
    foreach ($guard in @('badPhase', 'duplicateActor', 'outsideScope', 'internalState', 'internalOutputs', 'internalResults', 'collidingResults')) {
        $blocked = Invoke-OfflineHarness @{$guard=$true}
        if ($blocked.imds.Count -or $blocked.http.Count -or $blocked.dns.Count -or @($blocked.rows | Where-Object { $_.test -eq 'HARNESS' -and $_.status -eq 'BLOCKED' }).Count -ne 1) { throw 'A prerequisite guard allowed probes' }
        if ($guard -in @('internalResults', 'collidingResults') -and $blocked.savedJson) { throw 'Unsafe results path was written' }
        $checks++
    }
    $failedWrite = Invoke-OfflineHarness @{noLive=$true; writeFails=$true}
    if ($failedWrite.savedJson -or @($failedWrite.rows | Where-Object { $_.test -eq 'RESULTS' -and $_.status -eq 'BLOCKED' }).Count -ne 1) { throw 'Persistence failure was hidden' }
    $checks++
    Write-Output "PASS: $checks offline classification, token, request budget, DNS gating, persistence and live opt-in checks (no network or fixture files)"
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}