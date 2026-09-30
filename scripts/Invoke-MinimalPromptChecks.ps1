<#
.SYNOPSIS
Bounded minimum prompt diagnostic with a retained, ownership-verified agent.
.DESCRIPTION
Without RunLive, no filesystem, DNS or HTTP I/O is performed. DefinitionsOnly exports functions without importing dependencies.
Live execution requires the activated minimalPrompt profile, verified private access and explicit synthetic dev-a/client managed identities. No operator credentials, connection mutations or agent deletion are used.
At most 20 HTTP attempts including IMDS and three inference POSTs total. HttpClient has a 30-second total request deadline, no proxy, redirects, cookies, default credentials or retries, and a 2 MiB response buffer ceiling. DNS uses the existing bounded private-address helper.
Each attempt records its timestamp, client request GUID, request body and response body with credential redaction, plus allowlisted correlation headers, under /var/lib/fgl-private/minimal-<random>/. IMDS token values are never persisted. Linux execution requires a private parent directory; new files inherit umask 077 from the runner and explicitly use mode 0600, directories 0700.
The compressed summary must be below 2600 bytes; it contains no response bodies, resource identifiers or service hostnames. Raw evidence is private, not a publication artifact.
Agent CRUD uses /agents?api-version=v1 and the existing versions.latest schema. Connection discovery uses /connections/governed-models?api-version=v1 without requesting credentials; HTTP 200 alone is not visibility evidence. Responses uses /openai/v1/responses with an exact pinned agent version and no persistence, streaming, background execution or truncation.
The deterministic agent is retained for intervention, including after failed invocation or ambiguous creation. Reuse requires a fresh exact definition and ownership GET; creation requires a typed absent 404. Discovery failures do not prevent an otherwise ownership-verified diagnostic invocation. Direct-central status is separate evidence, not an RBAC isolation verdict without an operator positive control.
#>
[CmdletBinding()]
param([string]$StatePath, [string]$OutputsPath, [string]$ResultsPath, [string]$ExpectedAgentVersion, [switch]$RunLive, [switch]$DefinitionsOnly)

function Get-MinimalPromptContext {
    param([hashtable]$State, [hashtable]$Lab)
    Assert-LabState $State
    if ($State.minimalPrompt -isnot [bool] -or -not $State.minimalPrompt -or $Lab.minimalPrompt -isnot [bool] -or -not $Lab.minimalPrompt) { throw 'Minimal profile required in state and outputs' }
    if ($State.phase -isnot [string] -or $State.phase -cne 'activate' -or $Lab.phase -isnot [string] -or $Lab.phase -cne 'activate' -or $State.pendingPhase -or $Lab.pendingPhase -or $State.privateAccessVerified -isnot [bool] -or -not $State.privateAccessVerified) { throw 'Completed activation and verified private access required' }
    $targets = @(Get-LabPrivateTargets $State $Lab)
    if ($targets.Count -ne 3 -or $Lab.cases[0].accountId -isnot [string] -or $Lab.cases[0].projects[0].name -isnot [string] -or $Lab.cases[0].projects[0].name -cne 'case-a-dev') { throw 'One case-a dev project required' }
    $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-integration/providers/"
    if ($Lab.runner -ine "${prefix}Microsoft.Compute/virtualMachines/vm-fgl-$($State.labId)-runner") { throw 'Runner mismatch' }
    Assert-LabResourceId $State $Lab.runner
    $actors = @{}
    $identityPrefix = "${prefix}Microsoft.ManagedIdentity/userAssignedIdentities/"
    $allowed = @('dev-a','consumer-a','dev-b','publisher-a','publisher-b','client','denied')
    if ($Lab.identities -isnot [array] -or $Lab.identities.Count -lt 2 -or $Lab.identities.Count -gt 7) { throw 'Explicit actors required' }
    foreach ($actor in $Lab.identities) {
        if ($actor -isnot [hashtable] -or $actor.actor -isnot [string] -or $actor.actor -cnotin $allowed -or $actors.ContainsKey($actor.actor)) { throw 'Invalid actor' }
        Assert-LabResourceId $State $actor.resourceId
        if ($actor.resourceId -ine "${identityPrefix}id-fgl-$($State.labId)-$($actor.actor)") { throw 'Actor identity type, name or scope mismatch' }
        foreach ($field in @('clientId','principalId')) {
            $parsed = [guid]::Empty
            if ($actor[$field] -isnot [string] -or -not [guid]::TryParse($actor[$field], [ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'Invalid actor identifier' }
        }
        $actors[$actor.actor] = $actor
    }
    foreach ($field in @('clientId','principalId','resourceId')) {
        if (@($Lab.identities | ForEach-Object { $_[$field].ToLowerInvariant() } | Select-Object -Unique).Count -ne $Lab.identities.Count) { throw 'Distinct actors required' }
    }
    if (-not $actors.ContainsKey('dev-a') -or -not $actors.ContainsKey('client')) { throw 'Developer and client required' }
    $hosts = @{}
    foreach ($target in $targets) { $hosts[$target.key] = $target.hostName }
    return @{actors=$actors; hosts=$hosts; project="https://$($hosts['case-a'])/api/projects/case-a-dev"; gateway="https://$($hosts.gateway)"; central="https://$($hosts.models)"; connectionIds=@("$($Lab.cases[0].accountId)/connections/governed-models", "$($Lab.cases[0].projects[0].resourceId)/connections/governed-models"); name="fgl-min-$($State.labId)"; marker=$State.ownershipId}
}

function Use-MinimalRequestBudget {
    param([hashtable]$Budget, [switch]$Inference)
    if ($Budget.requests -ge 20 -or ($Inference -and $Budget.inferenceRequests -ge 3)) { throw 'Minimum diagnostic budget exhausted' }
    $Budget.requests++
    if ($Inference) { $Budget.inferenceRequests++ }
}

function Protect-MinimalText {
    param([AllowEmptyString()][string]$Text, [string[]]$Secrets, [switch]$TokenResponse)
    $safe = $Text
    try {
        $value = ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 100 -ErrorAction Stop
        if ($TokenResponse -and $value -isnot [hashtable]) { return '[redacted token response]' }
        $redact = {
            param($node)
            if ($node -is [System.Collections.IDictionary]) {
                foreach ($key in @($node.Keys)) {
                    if ($key -match '(?i)^(authorization|proxy-authorization|access[_-]?token|refresh[_-]?token|id[_-]?token|token|client[_-]?secret|client_assertion|password|api[_-]?key|accountkey|sharedaccesssignature|credentials)$') { $node[$key] = '[redacted]' }
                    else { & $redact $node[$key] }
                }
            } elseif ($node -is [array]) { foreach ($item in $node) { & $redact $item } }
        }
        & $redact $value
        $safe = ConvertTo-Json -InputObject $value -Depth 100 -Compress
    } catch { if ($TokenResponse) { return '[redacted token response]' } }
    foreach ($secret in $Secrets) {
        if ($secret) {
            $safe = $safe.Replace($secret, '[redacted]').Replace([uri]::EscapeDataString($secret), '[redacted]')
            $encoded = ConvertTo-Json -InputObject $secret -Compress
            $safe = $safe.Replace($encoded.Substring(1, $encoded.Length - 2), '[redacted]')
        }
    }
    $safe = [regex]::Replace($safe, '(?i)Bearer\s+[^\s"<>]+', 'Bearer [redacted]')
    $safe = [regex]::Replace($safe, '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[redacted]')
    return $safe
}

function New-MinimalEvidenceDirectory {
    if (-not $IsLinux) { throw 'Private Linux runner required' }
    $parent = Assert-ExternalLabPath '/var/lib/fgl-private'
    if (-not [IO.Directory]::Exists($parent) -or [IO.File]::GetUnixFileMode($parent) -ne [IO.UnixFileMode]448) { throw 'Private parent must have mode 0700' }
    $directory = Join-Path $parent ('minimal-' + [guid]::NewGuid().ToString('N'))
    if ([IO.Directory]::Exists($directory)) { throw 'Evidence directory collision' }
    $null = [IO.Directory]::CreateDirectory($directory, [IO.UnixFileMode]448)
    return $directory
}

function Write-MinimalPrivateFile {
    param([string]$Path, [string]$Text)
    $null = Assert-ExternalLabPath $Path
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    $options.UnixCreateMode = [IO.UnixFileMode]384
    $stream = [IO.FileStream]::new($Path, $options)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Invoke-MinimalHttp {
    param([string]$Uri, [string]$Method, [hashtable]$Headers, [string]$Body)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $client.MaxResponseContentBufferSize = 2097152
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
    $response = $null
    try {
        foreach ($key in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($key, [string]$Headers[$key]) }
        if ($Body) { $request.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/json') }
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseContentRead).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $correlation = @{}
        foreach ($key in @('request-id','x-request-id','apim-request-id','x-ms-request-id','x-ms-correlation-request-id','x-ms-client-request-id','traceparent','date')) {
            if ($response.Headers.Contains($key)) { $correlation[$key] = $response.Headers.GetValues($key) -join ', ' }
        }
        return @{status=[int]$response.StatusCode; body=$content; headers=$correlation}
    } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
}

function Send-MinimalRequest {
    param([hashtable]$Context, [hashtable]$Session, [ValidateSet('TOKEN-AI','TOKEN-CLIENT','TOKEN-DIRECT','GATEWAY','DIRECT-CENTRAL','CONTROL','CONNECTION','AGENT-GET','AGENT-CREATE','INVOKE')][string]$Operation, [string]$Token, [hashtable]$Body)
    $method = 'GET'
    $inference = $Operation -cin @('GATEWAY','DIRECT-CENTRAL','INVOKE')
    $tokenRequest = $Operation.StartsWith('TOKEN-', [StringComparison]::Ordinal)
    $chatRoute = '/openai/deployments/lab-chat/chat/completions?api-version=2024-10-21'
    $uri = switch ($Operation) {
        'GATEWAY' { $Context.gateway + $chatRoute }
        'DIRECT-CENTRAL' { $Context.central + $chatRoute }
        'CONTROL' { $Context.project + '/agents?api-version=v1&limit=1' }
        'CONNECTION' { $Context.project + '/connections/governed-models?api-version=v1' }
        'AGENT-GET' { $Context.project + '/agents/' + $Context.name + '?api-version=v1' }
        'AGENT-CREATE' { $Context.project + '/agents?api-version=v1' }
        'INVOKE' { $Context.project + '/openai/v1/responses' }
        default {
            $actor = if ($Operation -ceq 'TOKEN-CLIENT') { $Context.actors.client } else { $Context.actors['dev-a'] }
            $audience = if ($Operation -ceq 'TOKEN-AI') { 'https://ai.azure.com' } else { 'https://cognitiveservices.azure.com' }
            'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + [uri]::EscapeDataString($audience) + '&client_id=' + [uri]::EscapeDataString($actor.clientId)
        }
    }
    if ($inference -or $Operation -ceq 'AGENT-CREATE') { $method = 'POST' }
    if (-not $tokenRequest -and -not $Token) { throw 'Explicit managed identity token required' }
    if ($inference -and $Session.inferenceOperations.ContainsKey($Operation)) { throw 'Inference operation already attempted' }
    Use-MinimalRequestBudget $Session -Inference:$inference
    if ($inference) { $Session.inferenceOperations[$Operation] = $true }
    $stamp = [DateTimeOffset]::UtcNow.ToString('o')
    $clientRequestId = [guid]::NewGuid().ToString()
    $headers = @{Accept='application/json'; 'x-ms-client-request-id'=$clientRequestId; 'x-ms-date'=[DateTimeOffset]::UtcNow.ToString('R')}
    if ($tokenRequest) { $headers.Metadata = 'true' } else { $headers.Authorization = "Bearer $Token" }
    $requestBody = if ($Body) { $Body | ConvertTo-Json -Depth 12 -Compress } else { '' }
    $response = @{status=0; body=''; headers=@{}}
    $transport = $false
    try { $response = Invoke-MinimalHttp $uri $method $headers $requestBody } catch { $transport = $true }
    $probe = ConvertTo-IdentityProbe $response.status $response.body
    if ($tokenRequest -and $probe.data.access_token -is [string]) { $Session.secrets.Add($probe.data.access_token) }
    $safeHeaders = @{}
    foreach ($key in @('request-id','x-request-id','apim-request-id','x-ms-request-id','x-ms-correlation-request-id','x-ms-client-request-id','traceparent','date')) {
        if ($response.headers.ContainsKey($key)) { $safeHeaders[$key] = Protect-MinimalText ([string]$response.headers[$key]) $Session.secrets.ToArray() }
    }
    $entry = @{operation=$Operation; timestamp=$stamp; clientRequestId=$clientRequestId; method=$method; requestUri=$uri; requestBody=$requestBody; httpStatus=$response.status; transportFailure=$transport; responseHeaders=$safeHeaders; responseBody=(Protect-MinimalText $response.body $Session.secrets.ToArray() -TokenResponse:$tokenRequest)}
    $file = '{0:D2}-{1}.json' -f $Session.requests, $Operation.ToLowerInvariant()
    $hash = Write-MinimalPrivateFile (Join-Path $Session.rawDirectory $file) ($entry | ConvertTo-Json -Depth 15 -Compress)
    $Session.evidence.Add(@{file=$file; sha256=$hash})
    return $probe
}

function Get-MinimalToken {
    param([hashtable]$Context, [hashtable]$Session, [string]$Operation, [string]$TenantId)
    $probe = Send-MinimalRequest $Context $Session $Operation
    $actor = if ($Operation -ceq 'TOKEN-CLIENT') { $Context.actors.client } else { $Context.actors['dev-a'] }
    $audience = if ($Operation -ceq 'TOKEN-AI') { 'https://ai.azure.com' } else { 'https://cognitiveservices.azure.com' }
    $claims = Read-IdentityClaims $probe.data.access_token
    if ($probe.status -ne 200 -or $probe.data.token_type -isnot [string] -or $probe.data.token_type -ine 'Bearer' -or -not $claims -or $claims.tid -isnot [string] -or $claims.tid -ine $TenantId -or $claims.oid -isnot [string] -or $claims.oid -ine $actor.principalId -or $claims.aud -cne $audience) { return $null }
    return [string]$probe.data.access_token
}

function Test-MinimalOwnedAgent {
    param([hashtable]$Probe, [hashtable]$Context)
    if (-not (Test-AgentDefinition $Probe $Context.name $Context.marker 'Return only OK.')) { return $false }
    $latest = $Probe.data.versions.latest
    foreach ($value in @($Probe.data.object, $Probe.data.name, $latest.object, $latest.name, $latest.metadata['fgl-agent-run'], $latest.metadata['fgl-agent-name'], $latest.definition.kind, $latest.definition.model, $latest.definition.instructions)) {
        if ($value -isnot [string]) { return $false }
    }
    return $null -eq $Probe.data.error -and $latest.definition.Count -eq 3 -and $latest.version -cmatch '^[A-Za-z0-9._-]{1,64}$'
}

function Test-MinimalConnection {
    param([hashtable]$Probe, [hashtable]$Context)
    $data = $Probe.data
    return $Probe.status -eq 200 -and $data -is [hashtable] -and $null -eq $data.error -and $data.id -is [string] -and $data.id -iin $Context.connectionIds -and $data.name -is [string] -and $data.name -ceq 'governed-models' -and $data.target -is [string] -and $data.target.TrimEnd('/') -ceq ($Context.gateway + '/openai')
}

function Test-MinimalChat {
    param([hashtable]$Probe)
    $data = $Probe.data
    if ($Probe.status -ne 200 -or $data -isnot [hashtable] -or $null -ne $data.error -or $data.object -isnot [string] -or $data.object -cne 'chat.completion' -or $data.choices -isnot [array] -or $data.choices.Count -ne 1) { return $false }
    $choice = $data.choices[0]
    return $choice -is [hashtable] -and $choice.finish_reason -is [string] -and $choice.finish_reason -ceq 'stop' -and $choice.message -is [hashtable] -and $choice.message.role -is [string] -and $choice.message.role -ceq 'assistant' -and $choice.message.content -is [string] -and $choice.message.content.Trim() -ceq 'OK'
}

function Add-MinimalResult {
    param([hashtable]$Session, [string]$Test, [string]$Status, [string]$Reason, [hashtable]$Probe)
    $detail = if ($Probe -and $Probe.data -is [hashtable] -and $null -ne $Probe.data.error) { (Get-AgentInvocationError $Probe.data.error).reason } else { '' }
    $Session.tests.Add(@{test=$Test; status=$Status; httpStatus=$(if ($Probe) { $Probe.status } else { 0 }); reason=$Reason; error=$detail})
}

function Invoke-MinimalSequence {
    param([hashtable]$Context, [hashtable]$State, [hashtable]$Session, [hashtable]$Dns, [string]$ExpectedVersion)
    if ($ExpectedVersion -cnotmatch '\A[A-Za-z0-9._-]{1,64}\z') { throw 'Explicit expected agent version required before any request' }
    $tokens = @{}
    try {
        foreach ($operation in @('TOKEN-AI','TOKEN-CLIENT','TOKEN-DIRECT')) {
            $tokens[$operation] = Get-MinimalToken $Context $Session $operation $State.tenantId
            Add-MinimalResult $Session $operation $(if ($tokens[$operation]) { 'PASS' } else { 'BLOCKED' }) 'Explicit IMDS identity, tenant, audience and token lifetime validation; token not persisted' $null
        }
        $chat = @{messages=@(@{role='user'; content='Return only OK.'}); max_tokens=32; stream=$false}
        if ($tokens['TOKEN-CLIENT'] -and $Dns.gateway -eq 'PASS') {
            $probe = Send-MinimalRequest $Context $Session 'GATEWAY' $tokens['TOKEN-CLIENT'] $chat
            Add-MinimalResult $Session 'GATEWAY' $(if (Test-MinimalChat $probe) { 'PASS' } else { 'INCONCLUSIVE' }) 'Synthetic client positive requires a complete chat completion with assistant text OK' $probe
        }
        if ($tokens['TOKEN-DIRECT'] -and $Dns.models -eq 'PASS') {
            $probe = Send-MinimalRequest $Context $Session 'DIRECT-CENTRAL' $tokens['TOKEN-DIRECT'] $chat
            $status = if ($probe.status -ge 200 -and $probe.status -lt 300) { 'FAIL' } else { 'INCONCLUSIVE' }
            Add-MinimalResult $Session 'DIRECT-CENTRAL' $status ('Developer direct-central status only; no same-target operator positive control, therefore no isolation PASS; category=' + $probe.category) $probe
        }
        if (-not $tokens['TOKEN-AI'] -or $Dns['case-a'] -ne 'PASS') { return }
        $probe = Send-MinimalRequest $Context $Session 'CONTROL' $tokens['TOKEN-AI']
        Add-MinimalResult $Session 'CONTROL' $(if ($probe.listValid -and $null -eq $probe.data.error) { 'PASS' } else { 'INCONCLUSIVE' }) 'First-page agent discovery only; no returned names or links followed' $probe
        $probe = Send-MinimalRequest $Context $Session 'CONNECTION' $tokens['TOKEN-AI']
        Add-MinimalResult $Session 'CONNECTION' $(if (Test-MinimalConnection $probe $Context) { 'PASS' } else { 'INCONCLUSIVE' }) 'Visibility requires the exact connection identity, name and approved gateway target; no connection mutation' $probe
        $owned = Send-MinimalRequest $Context $Session 'AGENT-GET' $tokens['TOKEN-AI']
        if (Test-AgentAbsent $owned) {
            $Session.agentDisposition = 'creation-attempted; retained if created'
            $created = Send-MinimalRequest $Context $Session 'AGENT-CREATE' $tokens['TOKEN-AI'] (New-AgentBody $Context.name $Context.marker 'Return only OK.' -Create)
            Add-MinimalResult $Session 'CREATE' $(if (Test-MinimalOwnedAgent $created $Context) { 'PASS' } else { 'INCONCLUSIVE' }) 'Typed absence preceded creation; no cleanup or retry, even on ambiguous creation' $created
            $owned = Send-MinimalRequest $Context $Session 'AGENT-GET' $tokens['TOKEN-AI']
        } else { $Session.agentDisposition = 'existing or ambiguous; untouched' }
        if (-not (Test-MinimalOwnedAgent $owned $Context)) {
            Add-MinimalResult $Session 'OWNERSHIP' 'BLOCKED' 'Fresh exact name, ownership marker, prompt definition and version were not established; no invocation or deletion' $owned
            return
        }
        $Session.agentDisposition = 'verified agent retained for intervention'
        if ($owned.data.versions.latest.version -cne $ExpectedVersion) {
            Add-MinimalResult $Session 'OWNERSHIP' 'BLOCKED' 'Owned agent version differs from the explicit pin; no invocation, update or deletion' $owned
            return
        }
        Add-MinimalResult $Session 'OWNERSHIP' 'PASS' 'Fresh GET verified the exact owned prompt agent; retained for intervention' $owned
        $body = @{input='Return only OK.'; agent_reference=@{name=$Context.name; type='agent_reference'; version=$owned.data.versions.latest.version}; max_output_tokens=256; store=$false; stream=$false; background=$false; truncation='disabled'}
        $probe = Send-MinimalRequest $Context $Session 'INVOKE' $tokens['TOKEN-AI'] $body
        $verdict = Get-AgentInvocationVerdict $probe $Context.name $owned.data.versions.latest.version
        $Session.invocationSucceeded = $verdict.status -ceq 'PASS'
        Add-MinimalResult $Session 'INVOKE' $verdict.status $verdict.reason $probe
    } finally { $tokens.Clear() }
}

function ConvertTo-MinimalSummary {
    param([hashtable]$Report)
    $json = $Report | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $memory = [IO.MemoryStream]::new()
    $gzip = [IO.Compression.GZipStream]::new($memory, [IO.Compression.CompressionLevel]::Optimal, $true)
    try {
        $gzip.Write($bytes, 0, $bytes.Length)
        $gzip.Dispose()
        if ($memory.Length -ge 2600) { throw 'Summary exceeds return budget' }
    } finally { $gzip.Dispose(); $memory.Dispose() }
    return $json
}

function Invoke-MinimalPromptChecksCore {
    param([string]$InputStatePath, [string]$InputOutputsPath, [string]$OutputResultsPath, [string]$ExpectedVersion)
    $ErrorActionPreference = 'Stop'
    $VerbosePreference = 'SilentlyContinue'
    $DebugPreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $session = @{requests=0; inferenceRequests=0; inferenceOperations=@{}; secrets=[Collections.Generic.List[string]]::new(); evidence=[Collections.Generic.List[object]]::new(); tests=[Collections.Generic.List[object]]::new(); rawDirectory=$null; invocationSucceeded=$false; agentDisposition='not observed'}
    $destination = $null
    try {
        if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw 'PowerShell 7.4 or later required' }
        Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1') -Verbose:$false
        Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1') -Verbose:$false
        Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1') -Verbose:$false
        . (Join-Path $PSScriptRoot 'Invoke-AgentChecks.ps1') -DefinitionsOnly
        $parseTokens = $null
        $parseErrors = $null
        $identityAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-IdentityChecks.ps1'), [ref]$parseTokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw 'Identity helpers invalid' }
        foreach ($definition in $identityAst.EndBlock.Statements) {
            if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($definition.Extent.Text)) }
        }
        $inputState = Assert-ExternalLabPath $InputStatePath
        $inputOutputs = Assert-ExternalLabPath $InputOutputsPath
        $candidate = Assert-ExternalLabPath $OutputResultsPath
        if ($candidate -ieq $inputState -or $candidate -ieq $inputOutputs -or $inputState -ieq $inputOutputs -or (Test-Path -LiteralPath $candidate) -or -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($candidate)) -PathType Container)) { throw 'Distinct inputs and new external result required' }
        $destination = $candidate
        $state = Get-Content -LiteralPath $inputState -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $lab = Get-Content -LiteralPath $inputOutputs -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $context = Get-MinimalPromptContext $state $lab
        $session.rawDirectory = New-MinimalEvidenceDirectory
        $dns = @{}
        foreach ($key in @('gateway','models','case-a')) {
            $dns[$key] = Get-IdentityPrivateDns $context.hosts[$key]
            Add-MinimalResult $session "DNS-$key" $dns[$key] 'All resolved addresses must be private; prior private endpoint ownership verification remains required' $null
        }
        Invoke-MinimalSequence $context $state $session $dns $ExpectedVersion
    } catch { Add-MinimalResult $session 'HARNESS' 'BLOCKED' 'Prerequisite, budget or private evidence persistence failed; exception details suppressed' $null }
    finally { $session.secrets.Clear() }
    foreach ($test in @('GATEWAY','DIRECT-CENTRAL','CONTROL','CONNECTION','OWNERSHIP','INVOKE')) {
        if ($test -cnotin $session.tests.test) { Add-MinimalResult $session $test 'BLOCKED' 'Required prerequisite missing; no request attempted' $null }
    }
    $report = @{schemaVersion=1; runLive=$true; invocationSucceeded=$session.invocationSucceeded; agentDisposition=$session.agentDisposition; requests=$session.requests; requestLimit=20; inferenceRequests=$session.inferenceRequests; inferenceLimit=3; timeoutSeconds=30; rawDirectory=$session.rawDirectory; evidence=$session.evidence.ToArray(); elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,1); tests=$session.tests.ToArray()}
    try {
        $json = ConvertTo-MinimalSummary $report
        Assert-PublicText $json
        if ($destination) { $null = Write-MinimalPrivateFile $destination $json }
    } catch {
        $report.tests = @(@{test='RESULTS'; status='BLOCKED'; reason='Summary persistence or size validation failed; consult private evidence'})
        $json = ConvertTo-MinimalSummary $report
    }
    Write-Output $json
}

if ($DefinitionsOnly) { return }
if (-not $RunLive) {
    @{schemaVersion=1; runLive=$false; invocationSucceeded=$false; requests=0; inferenceRequests=0; tests=@(@{test='LIVE'; status='BLOCKED'; reason='Explicit RunLive required; no filesystem, DNS or HTTP I/O'})} | ConvertTo-Json -Depth 6 -Compress
    return
}
Invoke-MinimalPromptChecksCore $StatePath $OutputsPath $ResultsPath $ExpectedAgentVersion