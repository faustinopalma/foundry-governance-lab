[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    $harnessPath = Join-Path $PSScriptRoot '../scripts/Invoke-MinimalPromptChecks.ps1'
    $parseTokens = $null
    $parseErrors = $null
    $harnessAst = [Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Minimal harness syntax invalid' }
    . $harnessPath -DefinitionsOnly
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
    $checks = 0
    function Assert-Minimal([bool]$Condition, [string]$Message) {
        if (-not $Condition) { throw $Message }
    }
    function New-MinimalFixture {
        $state = @{subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'; ownershipId='33333333-3333-4333-8333-333333333333'; labId='sample01'; phase='activate'; minimalPrompt=$true; privateAccessVerified=$true; pendingPhase=$null; resourceGroups=@('models','integration','case-a') | ForEach-Object { "rg-fgl-sample01-$_" }}
        $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01"
        $account = "$prefix-case-a/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-a-abcdefghijklm"
        $lab = @{minimalPrompt=$true; phase='activate'; resourceGroups=$state.resourceGroups; models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-abcdefghijklm"; gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-abcdefghijklm"; runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner"; cases=@(@{accountId=$account; registryId=''; projects=@(@{name='case-a-dev'; resourceId="$account/projects/case-a-dev"})}); identities=@('dev-a','client') | ForEach-Object { @{actor=$_; clientId=[guid]::NewGuid().ToString(); principalId=[guid]::NewGuid().ToString(); resourceId="$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-sample01-$_"} }}
        return @{state=$state; lab=$lab}
    }
    $fixture = New-MinimalFixture
    $context = Get-MinimalPromptContext $fixture.state $fixture.lab
    Assert-Minimal ($context.name -ceq 'fgl-min-sample01' -and $context.marker -ceq $fixture.state.ownershipId -and $context.hosts.Count -eq 3) 'Valid minimum context rejected'
    $checks++
    foreach ($mutation in @(
        { param($fixture) $fixture.state.minimalPrompt = $false },
        { param($fixture) $fixture.lab.minimalPrompt = 'true' },
        { param($fixture) $fixture.state.phase = 'bootstrap' },
        { param($fixture) $fixture.state.phase = $true },
        { param($fixture) $fixture.lab.phase = $true },
        { param($fixture) $fixture.lab.phase = 'lock' },
        { param($fixture) $fixture.state.pendingPhase = 'activate' },
        { param($fixture) $fixture.state.privateAccessVerified = 'true' },
        { param($fixture) $fixture.state.privateAccessVerified = $false },
        { param($fixture) $fixture.lab.resourceGroups += 'foreign' },
        { param($fixture) $fixture.lab.cases += $fixture.lab.cases[0] },
        { param($fixture) $fixture.lab.cases[0].registryId = 'foreign' },
        { param($fixture) $fixture.lab.cases[0].accountId = $true },
        { param($fixture) $fixture.lab.cases[0].projects[0].name = $true },
        { param($fixture) $fixture.lab.cases[0].projects[0].name = 'case-a-test' },
        { param($fixture) $fixture.lab.runner += '/extensions/foreign' },
        { param($fixture) $fixture.lab.identities[0].resourceId = $fixture.lab.runner },
        { param($fixture) $fixture.lab.identities[0].resourceId += '/children/foreign' },
        { param($fixture) $fixture.lab.identities[0].principalId = $fixture.lab.identities[1].principalId },
        { param($fixture) $fixture.lab.identities[0].clientId = [guid]::Empty.ToString() },
        { param($fixture) $fixture.lab.identities[0].actor = 'denied' }
    )) {
        $fixture = New-MinimalFixture
        & $mutation $fixture
        $blocked = $false
        try { $null = Get-MinimalPromptContext $fixture.state $fixture.lab } catch { $blocked = $true }
        Assert-Minimal $blocked 'Invalid minimum context accepted'
        $checks++
    }
    $dry = & {
        function Get-Content { throw 'Unexpected filesystem read' }
        function Import-Module { throw 'Unexpected module read' }
        function Invoke-WebRequest { throw 'Unexpected HTTP' }
        & $harnessPath -StatePath 'missing' -OutputsPath 'missing' -ResultsPath 'missing'
    } | ConvertFrom-Json -AsHashtable
    Assert-Minimal (-not $dry.runLive -and -not $dry.invocationSucceeded -and $dry.requests -eq 0) 'Dry run performed work'
    $checks++

    . (Join-Path $PSScriptRoot '../scripts/Invoke-AgentChecks.ps1') -DefinitionsOnly
    $identityAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/Invoke-IdentityChecks.ps1'), [ref]$parseTokens, [ref]$parseErrors)
    foreach ($definition in $identityAst.EndBlock.Statements) {
        if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($definition.Extent.Text)) }
    }
    function New-MinimalSession {
        return @{requests=0; inferenceRequests=0; inferenceOperations=@{}; secrets=[Collections.Generic.List[string]]::new(); evidence=[Collections.Generic.List[object]]::new(); tests=[Collections.Generic.List[object]]::new(); rawDirectory='/var/lib/fgl-private/minimal-00000000000000000000000000000000'; invocationSucceeded=$false; agentDisposition='not observed'}
    }
    function New-MinimalAgent([hashtable]$Context) {
        $body = New-AgentBody $Context.name $Context.marker 'Return only OK.' -Create
        return @{object='agent'; name=$Context.name; id='agent-private'; versions=@{latest=@{object='agent.version'; name=$Context.name; id='version-private'; version='1'; metadata=$body.metadata; definition=$body.definition}}}
    }
    function Invoke-MinimalOffline([hashtable]$Options = @{}) {
        $sourceFixture = New-MinimalFixture
        $simulation = @{state=$sourceFixture.state; context=(Get-MinimalPromptContext $sourceFixture.state $sourceFixture.lab); session=(New-MinimalSession); calls=[Collections.Generic.List[object]]::new(); files=@{}; issued=@{}; errors=[Collections.Generic.List[string]]::new(); options=$Options; agent=$null; absent=$false; verified=$false}
        if ($Options.reuse -or $Options.ownershipMutation) { $simulation.agent = New-MinimalAgent $simulation.context }
        if ($Options.ownershipMutation) { & $Options.ownershipMutation $simulation.agent }
        function Assert-MinimalWire([bool]$Condition, [string]$Message) {
            if (-not $Condition) { $simulation.errors.Add($Message); throw $Message }
        }
        function Write-MinimalPrivateFile([string]$Path, [string]$Text) {
            $Path = $Path.Replace('\','/')
            Assert-MinimalWire ($Path.StartsWith($simulation.session.rawDirectory + '/') -and -not $simulation.files.ContainsKey($Path)) 'Evidence must be new and private'
            if ($simulation.options.writeFailure) { throw 'PRIVATE-SENTINEL' }
            $simulation.files[$Path] = $Text
            return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
        }
        function Invoke-MinimalHttp([string]$Uri, [string]$Method, [hashtable]$Headers, [string]$Body) {
            $address = [uri]$Uri
            $requestGuid = [guid]::Empty
            Assert-MinimalWire ([guid]::TryParse($Headers['x-ms-client-request-id'], [ref]$requestGuid) -and $requestGuid -ne [guid]::Empty -and [DateTimeOffset]::Parse($Headers['x-ms-date']) -gt [DateTimeOffset]::UtcNow.AddMinutes(-1)) 'Missing correlation headers'
            Assert-MinimalWire ($Headers['x-ms-client-request-id'] -cnotin $simulation.calls.clientRequestId) 'Repeated client request ID'
            $payload = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { $null }
            $call = @{uri=$Uri; method=$Method; body=$payload; clientRequestId=$Headers['x-ms-client-request-id']; operation=''}
            $simulation.calls.Add($call)
            $status = 200
            $data = @{}
            if ($address.Host -ceq '169.254.169.254') {
                Assert-MinimalWire ($address.Scheme -ceq 'http' -and $Method -ceq 'GET' -and $address.AbsolutePath -ceq '/metadata/identity/oauth2/token' -and $Headers.Metadata -ceq 'true' -and -not $Headers.Authorization -and -not $Body) 'Wrong IMDS transport'
                $query = @{}
                foreach ($part in $address.Query.TrimStart('?').Split('&')) { $pair = $part.Split('=', 2); $query[$pair[0]] = [uri]::UnescapeDataString($pair[1]) }
                $selected = @($simulation.context.actors.Values | Where-Object { $_.clientId -ceq $query.client_id })
                Assert-MinimalWire ($query.Count -eq 3 -and $query['api-version'] -ceq '2018-02-01' -and $selected.Count -eq 1 -and $query.resource -cin @('https://ai.azure.com','https://cognitiveservices.azure.com')) 'Wrong IMDS actor or audience'
                $call.operation = if ($query.resource -ceq 'https://ai.azure.com') { 'TOKEN-AI' } elseif ($selected[0].actor -ceq 'client') { 'TOKEN-CLIENT' } else { 'TOKEN-DIRECT' }
                Assert-MinimalWire ($selected[0].actor -ceq $(if ($call.operation -ceq 'TOKEN-CLIENT') { 'client' } else { 'dev-a' })) 'Unexpected token actor'
                $claims = @{tid=$simulation.state.tenantId; oid=$selected[0].principalId; aud=$query.resource; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600}
                if ($simulation.options.claim -and $call.operation -ceq 'TOKEN-AI') { $claims[$simulation.options.claim] = $simulation.options.claimValue }
                $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
                $issuedToken = "synthetic.$encoded.signature"
                $simulation.issued[$issuedToken] = @{actor=$selected[0].actor; audience=$query.resource}
                $data = @{access_token=$issuedToken; refresh_token='refresh-private'; token_type='Bearer'; expires_on=$claims.exp}
            } else {
                $usedToken = $Headers.Authorization.Substring(7)
                $identity = $simulation.issued[$usedToken]
                Assert-MinimalWire ($address.Scheme -ceq 'https' -and $address.Port -eq 443 -and -not $address.UserInfo -and -not $address.Fragment -and $identity) 'Invalid service target or token'
                if ($Uri.StartsWith($simulation.context.gateway) -or $Uri.StartsWith($simulation.context.central)) {
                    $call.operation = if ($Uri.StartsWith($simulation.context.gateway)) { 'GATEWAY' } else { 'DIRECT-CENTRAL' }
                    Assert-MinimalWire ($Method -ceq 'POST' -and $address.PathAndQuery -ceq '/openai/deployments/lab-chat/chat/completions?api-version=2024-10-21' -and $payload.Count -eq 3 -and $payload.messages.Count -eq 1 -and $payload.messages[0].role -ceq 'user' -and $payload.messages[0].content -ceq 'Return only OK.' -and $payload.max_tokens -eq 32 -and $payload.stream -is [bool] -and -not $payload.stream) 'Incorrect chat request'
                    Assert-MinimalWire ($identity.audience -ceq 'https://cognitiveservices.azure.com' -and $identity.actor -ceq $(if ($call.operation -ceq 'GATEWAY') { 'client' } else { 'dev-a' })) 'Incorrect chat actor'
                    if ($call.operation -ceq 'GATEWAY') { $data = @{object='chat.completion'; choices=@(@{finish_reason='stop'; message=@{role='assistant'; content='OK'}})} }
                    else { $status = 403; $data = @{error=@{code='PermissionDenied'; message='The principal lacks the required data action. PRIVATE-SENTINEL'}} }
                } else {
                    Assert-MinimalWire ($Uri.StartsWith($simulation.context.project + '/') -and $identity.actor -ceq 'dev-a' -and $identity.audience -ceq 'https://ai.azure.com') 'Incorrect project actor or target'
                    $route = $Uri.Substring($simulation.context.project.Length)
                    switch -CaseSensitive ($route) {
                        '/agents?api-version=v1&limit=1' {
                            Assert-MinimalWire ($Method -ceq 'GET' -and -not $Body) 'Control must be read-only'
                            $call.operation = 'CONTROL'; $data = @{object='list'; data=@()}
                        }
                        '/connections/governed-models?api-version=v1' {
                            Assert-MinimalWire ($Method -ceq 'GET' -and -not $Body) 'Connection must be read-only'
                            $call.operation = 'CONNECTION'; $data = @{id=$simulation.context.connectionIds[0]; name='governed-models'; target=($simulation.context.gateway + '/openai')}
                        }
                        '/agents?api-version=v1' {
                            Assert-MinimalWire ($Method -ceq 'POST' -and $simulation.absent -and -not $simulation.agent -and $payload.name -ceq $simulation.context.name -and $payload.metadata['fgl-agent-run'] -ceq $simulation.state.ownershipId -and $payload.definition.kind -ceq 'prompt' -and $payload.definition.model -ceq 'governed-models/lab-chat' -and $payload.definition.instructions -ceq 'Return only OK.') 'Creation without typed absence or exact ownership/definition'
                            $call.operation = 'AGENT-CREATE'; $simulation.agent = New-MinimalAgent $simulation.context; $data = $simulation.agent
                        }
                        '/openai/v1/responses' {
                            Assert-MinimalWire ($Method -ceq 'POST' -and $simulation.verified -and 'CONTROL' -cin $simulation.calls.operation -and 'CONNECTION' -cin $simulation.calls.operation) 'Invocation before fresh ownership or discovery'
                            Assert-MinimalWire ($payload.Count -eq 7 -and $payload.input -ceq 'Return only OK.' -and $payload.agent_reference.Count -eq 3 -and $payload.agent_reference.type -ceq 'agent_reference' -and $payload.agent_reference.name -ceq $simulation.context.name -and $payload.agent_reference.version -ceq '1' -and $payload.max_output_tokens -eq 256 -and $payload.store -is [bool] -and -not $payload.store -and $payload.stream -is [bool] -and -not $payload.stream -and $payload.background -is [bool] -and -not $payload.background -and $payload.truncation -ceq 'disabled') 'Unsafe Responses body'
                            $call.operation = 'INVOKE'
                            $data = @{object='response'; id='resp-private'; status='completed'; error=$null; incomplete_details=$null; agent_reference=$payload.agent_reference; store=$false; background=$false; truncation='disabled'; output=@(@{id='message-private'; type='message'; role='assistant'; status='completed'; content=@(@{type='output_text'; text='OK'})}); usage=@{output_tokens=1}}
                        }
                        default {
                            Assert-MinimalWire ($route -ceq "/agents/$($simulation.context.name)?api-version=v1" -and $Method -ceq 'GET' -and -not $Body) 'Unexpected route, update or DELETE'
                            $call.operation = 'AGENT-GET'
                            if ($simulation.agent) { $data = $simulation.agent; $simulation.verified = $true }
                            else { $status = 404; $data = @{error=@{code='NotFound'}}; $simulation.absent = $true }
                        }
                    }
                }
            }
            if ($call.operation -ceq $simulation.options.operation) {
                if ($simulation.options.transport) { throw 'PRIVATE-SENTINEL' }
                if ($simulation.options.ContainsKey('status')) { $status = $simulation.options.status }
                if ($simulation.options.ContainsKey('data')) { $data = $simulation.options.data }
                if ($simulation.options.mutation) { & $simulation.options.mutation $data }
            }
            return @{status=$status; body=($data | ConvertTo-Json -Depth 30 -Compress); headers=@{'x-ms-request-id'='correlation-private'; 'Authorization'='Bearer must-not-persist'; 'Set-Cookie'='must-not-persist'; 'Location'='https://private.invalid/must-not-persist'}}
        }
        $caught = $false
        $expectedVersion = if ($Options.ContainsKey('expectedVersion')) { $Options.expectedVersion } else { '1' }
        try { Invoke-MinimalSequence $simulation.context $simulation.state $simulation.session @{gateway='PASS'; models='PASS'; 'case-a'='PASS'} $expectedVersion } catch { $caught = $true }
        Assert-Minimal ($simulation.errors.Count -eq 0) ($simulation.errors -join '; ')
        Assert-Minimal ($caught -eq ([bool]$Options.writeFailure -or $expectedVersion -cnotmatch '\A[A-Za-z0-9._-]{1,64}\z')) 'Unexpected sequence exception'
        Assert-Minimal ($simulation.session.requests -eq $simulation.calls.Count -and $simulation.calls.Count -le 20) 'Wrong total request budget'
        Assert-Minimal ($simulation.session.inferenceRequests -eq @($simulation.calls | Where-Object operation -cin @('GATEWAY','DIRECT-CENTRAL','INVOKE')).Count -and $simulation.session.inferenceRequests -le 3) 'Wrong inference accounting'
        if (-not $Options.writeFailure) { Assert-Minimal ($simulation.files.Count -eq $simulation.calls.Count -and $simulation.session.evidence.Count -eq $simulation.calls.Count) 'Missing per-attempt evidence' }
        foreach ($privateText in $simulation.files.Values) {
            $record = $privateText | ConvertFrom-Json -AsHashtable
            $correlationValid = if ($record.transportFailure) { $record.responseHeaders.Count -eq 0 } else { $record.responseHeaders.Count -eq 1 -and $record.responseHeaders['x-ms-request-id'] -ceq 'correlation-private' }
            Assert-Minimal (-not $privateText.Contains('must-not-persist') -and -not $privateText.Contains('refresh-private') -and $correlationValid -and $record.timestamp -and $record.clientRequestId) 'Unsafe raw evidence or lost correlation'
            foreach ($issued in $simulation.issued.Keys) { Assert-Minimal (-not $privateText.Contains($issued)) 'Token persisted in raw evidence' }
        }
        $summary = ConvertTo-MinimalSummary @{invocationSucceeded=$simulation.session.invocationSucceeded; rawDirectory=$simulation.session.rawDirectory; evidence=$simulation.session.evidence.ToArray(); tests=$simulation.session.tests.ToArray()}
        foreach ($secret in @('PRIVATE-SENTINEL','correlation-private','resp-private','message-private',$simulation.context.name,$simulation.state.ownershipId,$simulation.state.tenantId,$simulation.state.subscriptionId) + @($simulation.context.hosts.Values) + @($simulation.issued.Keys)) { Assert-Minimal (-not $summary.Contains($secret)) 'Private information in summary' }
        return $simulation
    }
    $success = Invoke-MinimalOffline
    Assert-Minimal ($success.session.invocationSucceeded -and $success.agent -and $success.calls.Count -eq 11 -and $success.session.inferenceRequests -eq 3 -and $success.session.agentDisposition -ceq 'verified agent retained for intervention') 'Expected retained successful invocation'
    Assert-Minimal (@($success.session.tests | Where-Object { $_.test -ceq 'DIRECT-CENTRAL' -and $_.status -ceq 'INCONCLUSIVE' }).Count -eq 1) 'Direct-central denial overstated'
    $checks++
    $reused = Invoke-MinimalOffline @{reuse=$true}
    Assert-Minimal ($reused.session.invocationSucceeded -and $reused.agent -and $reused.calls.Count -eq 9 -and 'AGENT-CREATE' -cnotin $reused.calls.operation) 'Owned agent not reused safely'
    $checks++
    $withoutStoreEcho = Invoke-MinimalOffline @{operation='INVOKE'; mutation={ param($response) $null = $response.Remove('store') }}
    Assert-Minimal ($withoutStoreEcho.session.invocationSucceeded -and $withoutStoreEcho.agent -and @($withoutStoreEcho.calls | Where-Object operation -ceq 'INVOKE').Count -eq 1) 'Missing store echo incorrectly failed functional inference or caused retry'
    $checks++
    foreach ($mutation in @(
        { param($agent) $agent.name = 'foreign' },
        { param($agent) $agent.versions.latest.metadata['fgl-agent-run'] = 'foreign' },
        { param($agent) $agent.versions.latest.metadata['fgl-agent-name'] = 'foreign' },
        { param($agent) $agent.versions.latest.definition.model = 'unapproved' },
        { param($agent) $agent.versions.latest.definition.instructions = 'Different' },
        { param($agent) $agent.versions.latest.definition.tools = @() },
        { param($agent) $agent.versions.latest.version = '' }
    )) {
        $unowned = Invoke-MinimalOffline @{ownershipMutation=$mutation}
        Assert-Minimal (-not $unowned.session.invocationSucceeded -and $unowned.agent -and 'AGENT-CREATE' -cnotin $unowned.calls.operation -and 'INVOKE' -cnotin $unowned.calls.operation) 'Unowned agent was mutated or invoked'
        $checks++
    }
    foreach ($reuse in @($false,$true)) {
        $mismatch = Invoke-MinimalOffline @{reuse=$reuse; expectedVersion='2'}
        Assert-Minimal (-not $mismatch.session.invocationSucceeded -and $mismatch.agent -and 'INVOKE' -cnotin $mismatch.calls.operation) 'Version mismatch reached invocation'
        $checks++
    }
    foreach ($version in @('', ' ', '1;exit', ('a'*65))) {
        $invalidPin = Invoke-MinimalOffline @{expectedVersion=$version}
        Assert-Minimal (-not $invalidPin.session.invocationSucceeded -and $invalidPin.calls.Count -eq 0) 'Invalid version pin reached network'
        $checks++
    }
    foreach ($mutation in @(
        { param($response) $response.status = 'incomplete' },
        { param($response) $response.status = 'queued' },
        { param($response) $response.error = @{code='InvalidRequest'; message='PRIVATE-SENTINEL'} },
        { param($response) $response.incomplete_details = @{reason='max_output_tokens'} },
        { param($response) $response.agent_reference.version = '2' },
        { param($response) $response.store = $true },
        { param($response) $response.store = 'false' },
        { param($response) $response.store = $null },
        { param($response) $response.output[0].content[0].text = 'Not OK' },
        { param($response) $response.output[0].content[0].type = 'refusal' },
        { param($response) $response.output = @() }
    )) {
        $failed = Invoke-MinimalOffline @{operation='INVOKE'; mutation=$mutation}
        Assert-Minimal (-not $failed.session.invocationSucceeded -and $failed.agent -and @($failed.calls | Where-Object operation -ceq 'INVOKE').Count -eq 1) 'Malformed response reported success or retried'
        $checks++
    }
    foreach ($status in @(400,401,403,404,429,500)) {
        $failed = Invoke-MinimalOffline @{operation='INVOKE'; status=$status; data=@{error=@{code='ConnectionNotFound'; message='Connection PRIVATE-SENTINEL https://private.invalid/ missing'}}}
        $row = @($failed.session.tests | Where-Object test -ceq 'INVOKE')[0]
        Assert-Minimal (-not $failed.session.invocationSucceeded -and $failed.agent -and $row.httpStatus -eq $status -and $row.error.Contains('ConnectionNotFound') -and $row.error.Contains('connection resolution')) 'Service error, status or retention lost'
        $checks++
    }
    foreach ($operation in @('INVOKE','CONNECTION','AGENT-CREATE')) {
        $failed = Invoke-MinimalOffline @{operation=$operation; transport=$true}
        Assert-Minimal ($failed.agent -and @($failed.calls | Where-Object operation -ceq 'INVOKE').Count -eq 1 -and $failed.session.invocationSucceeded -eq ($operation -cne 'INVOKE')) 'Ambiguous creation or discovery was not recorded or retained'
        $checks++
    }
    foreach ($field in @('id','name','target')) {
        $connection = @{id=$success.context.connectionIds[0]; name='governed-models'; target=$success.context.gateway}
        $connection.Remove($field)
        $failed = Invoke-MinimalOffline @{operation='CONNECTION'; data=$connection}
        Assert-Minimal ($failed.session.invocationSucceeded -and @($failed.session.tests | Where-Object { $_.test -ceq 'CONNECTION' -and $_.status -ceq 'INCONCLUSIVE' }).Count -eq 1) 'Incomplete connection mistaken for visibility or suppressed invocation'
        $checks++
    }
    foreach ($badAbsence in @(@{}, @{error=@{code='DeploymentNotFound'}}, @{error=@{code='NotFound'}})) {
        $failed = Invoke-MinimalOffline @{operation='AGENT-GET'; status=$(if ($badAbsence.error.code -ceq 'NotFound') { 200 } else { 404 }); data=$badAbsence}
        Assert-Minimal (-not $failed.agent -and 'AGENT-CREATE' -cnotin $failed.calls.operation -and -not $failed.session.invocationSucceeded) 'Untyped or wrong-status absence allowed creation'
        $checks++
    }
    foreach ($claim in @('tid','oid','aud','exp','nbf')) {
        $value = if ($claim -ceq 'exp') { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-1 } elseif ($claim -ceq 'nbf') { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600 } else { 'invalid' }
        $failed = Invoke-MinimalOffline @{claim=$claim; claimValue=$value}
        Assert-Minimal (-not $failed.session.invocationSucceeded -and -not $failed.agent -and 'CONTROL' -cnotin $failed.calls.operation) 'Invalid token claims allowed project access'
        $checks++
    }
    $failed = Invoke-MinimalOffline @{writeFailure=$true}
    Assert-Minimal ($failed.calls.Count -eq 1 -and -not $failed.session.invocationSucceeded -and -not $failed.agent) 'Evidence write failure did not stop HTTP'
    $checks++
    foreach ($mutation in @(
        { param($chat) $chat.object = $true },
        { param($chat) $chat.choices[0].finish_reason = $true },
        { param($chat) $chat.choices[0].message.role = $true }
    )) {
        $failed = Invoke-MinimalOffline @{operation='GATEWAY'; mutation=$mutation}
        Assert-Minimal (@($failed.session.tests | Where-Object { $_.test -ceq 'GATEWAY' -and $_.status -ceq 'INCONCLUSIVE' }).Count -eq 1) 'Boolean chat fields accepted as positive evidence'
        $checks++
    }
    $failed = Invoke-MinimalOffline @{operation='TOKEN-AI'; mutation={ param($token) $token.token_type = $true }}
    Assert-Minimal (-not $failed.session.invocationSucceeded -and 'CONTROL' -cnotin $failed.calls.operation) 'Boolean token type accepted'
    $checks++
    $budget = New-MinimalSession
    foreach ($index in 1..20) { Use-MinimalRequestBudget $budget -Inference:($index -le 3) }
    $blocked = $false
    try { Use-MinimalRequestBudget $budget } catch { $blocked = $true }
    Assert-Minimal ($blocked -and $budget.requests -eq 20 -and $budget.inferenceRequests -eq 3) 'HTTP budget not hard bounded'
    $budget = New-MinimalSession
    foreach ($index in 1..3) { Use-MinimalRequestBudget $budget -Inference }
    $blocked = $false
    try { Use-MinimalRequestBudget $budget -Inference } catch { $blocked = $true }
    Assert-Minimal ($blocked -and $budget.requests -eq 3 -and $budget.inferenceRequests -eq 3) 'Inference budget not hard bounded'
    $checks += 2
    $safe = Protect-MinimalText '{"nested":{"access_token":"secret-value","credentials":{"key":"hidden"}},"error":{"message":"Bearer secret-value"}}' @('secret-value')
    Assert-Minimal (-not $safe.Contains('secret-value') -and -not $safe.Contains('hidden')) 'Nested token redaction failed'
    Assert-Minimal ((Protect-MinimalText 'opaque-imds-secret' @() -TokenResponse) -ceq '[redacted token response]') 'Malformed IMDS body persisted'
    $checks += 2
    $httpDefinition = $harnessAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-MinimalHttp' }, $true).Extent.Text
    foreach ($guard in @('$handler.UseProxy = $false', '$handler.AllowAutoRedirect = $false', '$handler.UseCookies = $false', '$handler.UseDefaultCredentials = $false', '$client.Timeout = [TimeSpan]::FromSeconds(30)', '[Net.Http.HttpCompletionOption]::ResponseContentRead')) { Assert-Minimal ($httpDefinition.Contains($guard)) 'HTTP transport safety option missing' }
    $checks++

    $runnerPath = Join-Path $PSScriptRoot '../scripts/Invoke-LabRunner.ps1'
    Import-Module (Join-Path $PSScriptRoot '../scripts/MinimalTeardownAcceptance.psm1')
    $null = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$parseTokens, [ref]$parseErrors)
    Assert-Minimal ($parseErrors.Count -eq 0) 'Runner syntax invalid'
    function Invoke-MinimalRunnerOffline([string]$Action, [scriptblock]$Mutation, [switch]$Full) {
        $sourceFixture = New-MinimalFixture
        $runnerFixture = @{state=$sourceFixture.state; lab=$sourceFixture.lab; confirmed=0; runCommands=0; uploads=$null; shell=''; error=''}
        if ($Full) {
            $runnerFixture.state.minimalPrompt = $false
            $runnerFixture.lab.minimalPrompt = $false
            $runnerFixture.state.resourceGroups += 'rg-fgl-sample01-case-b'
            $runnerFixture.lab.resourceGroups = $runnerFixture.state.resourceGroups
            $caseA = $runnerFixture.lab.cases[0]
            $caseA.projects += @{name='case-a-test'; resourceId="$($caseA.accountId)/projects/case-a-test"}
            $caseA.registryId = "/subscriptions/$($runnerFixture.state.subscriptionId)/resourceGroups/rg-fgl-sample01-case-a/providers/Microsoft.ContainerRegistry/registries/crfglsample01aabcdefghijklm"
            $caseB = ($caseA | ConvertTo-Json -Depth 10).Replace('case-a','case-b').Replace('sample01-a-','sample01-b-').Replace('sample01aabcdefghijklm','sample01babcdefghijklm') | ConvertFrom-Json -AsHashtable
            $runnerFixture.lab.cases += $caseB
        }
        if ($Action -ceq 'VerifyPrivate') { $runnerFixture.state.phase = 'lock'; $runnerFixture.lab.phase = 'lock' }
        if ($Action -ceq 'Prepare') { $runnerFixture.state.phase = 'bootstrap'; $runnerFixture.lab.phase = 'bootstrap' }
        if ($Mutation) { & $Mutation $runnerFixture }
        $scratch = Join-Path ([IO.Path]::GetTempPath()) ('minimal-runner-offline-' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($scratch)
        $runnerFixture.state.runDirectory = $scratch
        $runnerFixture.state.azureConfigDirectory = 'OPERATOR-CREDENTIALS-MUST-NOT-TRANSFER'
        $runnerFixture.state.deploymentAuthorized = $true
        [IO.File]::WriteAllText((Join-Path $scratch 'outputs.json'), ($runnerFixture.lab | ConvertTo-Json -Depth 20))
        [IO.File]::WriteAllText((Join-Path $scratch 'parameters.json'), '{}')
        function Import-Module { }
        function Read-LabRun { return $runnerFixture.state }
        function Confirm-LabRunContext { $runnerFixture.confirmed++ }
        function Get-Content { return $runnerFixture.lab | ConvertTo-Json -Depth 20 }
        function Invoke-LabAz {
            param($State, $Arguments, $Label)
            Assert-Minimal ($Label -ceq "runner-$Action") 'Unexpected Azure command'
            $runnerFixture.runCommands++
            $runnerFixture.uploads = $uploads
            $runnerFixture.shell = $shell -join "`n"
            throw 'STOP-OFFLINE-RUNNER'
        }
        try {
            try { $null = & $runnerPath -StatePath (Join-Path $scratch 'unused-state.json') -Action $Action -ExpectedAgentVersion '1' } catch { $runnerFixture.error = $_.Exception.Message }
        } finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
        return $runnerFixture
    }
    $wired = Invoke-MinimalRunnerOffline 'MinimalPrompt'
    Assert-Minimal ($wired.error -ceq 'STOP-OFFLINE-RUNNER' -and $wired.confirmed -eq 1 -and $wired.runCommands -eq 1) 'Minimum runner failed local validation'
    Assert-Minimal ($wired.shell.Contains('umask 077') -and $wired.shell.Contains('timeout 660 pwsh -NoProfile -File /opt/fgl/scripts/Invoke-MinimalPromptChecks.ps1 -RunLive') -and $wired.shell.Contains('-lt 2600')) 'Minimum shell limits missing'
    Assert-Minimal ($wired.shell.Contains("-ExpectedAgentVersion '1'")) 'Expected version was not sent to the runner'
    $checks++
    foreach ($name in @('Invoke-MinimalPromptChecks.ps1','Invoke-AgentChecks.ps1','Invoke-IdentityChecks.ps1','Invoke-GatewayChecks.ps1','Invoke-RegistryChecks.ps1','PublicSource.psm1','LabSafety.psm1','LabExecution.psm1','TestResults.psm1')) { Assert-Minimal ($wired.uploads.ContainsKey("/opt/fgl/scripts/$name")) 'Runner dependency upload missing' }
    $transfers = [regex]::Matches($wired.shell, "printf '%s' '([A-Za-z0-9+/=]+)' \| base64 -d \| gzip -d > '([^']+)'")
    Assert-Minimal ($transfers.Count -eq $wired.uploads.Count -and [Text.Encoding]::UTF8.GetByteCount($wired.shell) -lt 120000) 'Compressed transfer coverage or size invalid'
    foreach ($transfer in $transfers) {
        $compressed = [IO.MemoryStream]::new([Convert]::FromBase64String($transfer.Groups[1].Value))
        $decompressor = [IO.Compression.GZipStream]::new($compressed, [IO.Compression.CompressionMode]::Decompress)
        $restored = [IO.MemoryStream]::new()
        try {
            $decompressor.CopyTo($restored)
            Assert-Minimal ([Convert]::ToBase64String($restored.ToArray()) -ceq [Convert]::ToBase64String($wired.uploads[$transfer.Groups[2].Value])) 'Compressed upload changed bytes'
        } finally { $restored.Dispose(); $decompressor.Dispose(); $compressed.Dispose() }
        $checks++
    }
    $remoteStateText = [Text.Encoding]::UTF8.GetString($wired.uploads['/var/lib/fgl-private/state.json'])
    $remoteState = $remoteStateText | ConvertFrom-Json -AsHashtable
    Assert-Minimal ($remoteState.minimalPrompt -eq $true -and $remoteState.privateAccessVerified -eq $true -and -not $remoteState.ContainsKey('azureConfigDirectory') -and -not $remoteStateText.Contains('OPERATOR-CREDENTIALS')) 'Credentials transferred or profile gate lost'
    $checks++
    foreach ($mutation in @(
        { param($fixture) $fixture.state.minimalPrompt = $false },
        { param($fixture) $fixture.lab.minimalPrompt = $false },
        { param($fixture) $fixture.state.phase = 'bootstrap' },
        { param($fixture) $fixture.lab.phase = 'lock' },
        { param($fixture) $fixture.state.privateAccessVerified = $false },
        { param($fixture) $fixture.state.pendingPhase = 'activate' },
        { param($fixture) $fixture.lab.runner += '-foreign' }
    )) {
        $blockedRunner = Invoke-MinimalRunnerOffline 'MinimalPrompt' $mutation
        Assert-Minimal ($blockedRunner.error -and $blockedRunner.confirmed -eq 0 -and $blockedRunner.runCommands -eq 0) 'Runner gate made a context or Run Command call'
        $checks++
    }
    foreach ($action in @('Gateway','Identity','Agent','Registry')) {
        $blockedRunner = Invoke-MinimalRunnerOffline $action
        Assert-Minimal ($blockedRunner.error -and $blockedRunner.confirmed -eq 0 -and $blockedRunner.runCommands -eq 0) 'Full diagnostic allowed on minimum profile'
        $fullRunner = Invoke-MinimalRunnerOffline $action -Full
        Assert-Minimal ($fullRunner.error -ceq 'STOP-OFFLINE-RUNNER' -and $fullRunner.shell.Contains('timeout 480 pwsh')) 'Full diagnostic wiring regressed'
        $checks += 2
    }
    foreach ($full in @($false,$true)) {
        $prepare = Invoke-MinimalRunnerOffline 'Prepare' -Full:$full
        Assert-Minimal ($prepare.error -ceq 'STOP-OFFLINE-RUNNER' -and $prepare.shell.Contains('FGL_PREPARE_OK')) 'Prepare wiring regressed'
        $verify = Invoke-MinimalRunnerOffline 'VerifyPrivate' -Full:$full
        Assert-Minimal ($verify.error -ceq 'STOP-OFFLINE-RUNNER' -and $verify.uploads.ContainsKey('/var/lib/fgl-private/probe.ps1')) 'VerifyPrivate wiring regressed'
        $targets = [Text.Encoding]::UTF8.GetString($verify.uploads['/var/lib/fgl-private/targets.json']) | ConvertFrom-Json -AsHashtable
        Assert-Minimal ($targets.Count -eq $(if ($full) { 6 } else { 3 })) 'Private target coverage changed'
        $checks += 2
    }
    function Test-MinimalEvidenceExport {
        $scratch = Join-Path ([IO.Path]::GetTempPath()) ('minimal-export-offline-' + [guid]::NewGuid().ToString('N'))
        try {
            Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1')
            $exporter = Join-Path $PSScriptRoot '../scripts/Export-MinimalPromptEvidence.ps1'
            $tokens = $null
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($exporter, [ref]$tokens, [ref]$errors)
            if ($errors.Count) { throw 'Evidence exporter syntax invalid' }
            $checks = 0
            function Assert-Export([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
            function Get-ExportHash([byte[]]$Bytes) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
            function Invoke-ExportOffline([hashtable]$Options = @{}) {
                $fixtureRoot = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
                $null = [IO.Directory]::CreateDirectory($fixtureRoot)
                $sourceFixture = New-MinimalFixture
                $state = $sourceFixture.state
                $lab = $sourceFixture.lab
                $state.deploymentAuthorized = $true
                $state.preexistingGroupIds = @()
                $state.runDirectory = $fixtureRoot
                $state.azureConfigDirectory = Join-Path $fixtureRoot 'OPERATOR-CREDENTIALS'
                $bodies = @([Text.Encoding]::UTF8.GetBytes(('{"responseBody":"PRIVATE-SENTINEL' + ('a' * 3580) + '"}')), [Text.Encoding]::UTF8.GetBytes('{"operation":"INVOKE","httpStatus":400,"responseBody":"PRIVATE-SENTINEL"}'))
                if ($Options.bodies) { $bodies = $Options.bodies }
                $entries = @()
                foreach ($index in 0..($bodies.Count - 1)) { $entries += @{file=('{0:D2}-invoke.json' -f ($index+1)); sha256=(Get-ExportHash $bodies[$index])} }
                $summary = @{schemaVersion=1; runLive=$true; requests=$entries.Count; invocationSucceeded=$false; rawDirectory='/var/lib/fgl-private/minimal-00000000000000000000000000000000'; evidence=$entries}
                $simulation = @{home=$fixtureRoot; state=$state; lab=$lab; summary=$summary; bodies=$bodies; confirmed=0; calls=0; chunks=0; maximumMessage=0; options=$Options; output=''; error=''; directory=$null; arguments=@(); scriptTexts=[Collections.Generic.List[string]]::new(); chunkRequests=[Collections.Generic.List[object]]::new()}
                if ($Options.mutate) { & $Options.mutate $simulation }
                $statePath = Join-Path $fixtureRoot 'state.json'
                $summaryPath = Join-Path $fixtureRoot 'report.json'
                [IO.File]::WriteAllText($statePath, ($simulation.state | ConvertTo-Json -Depth 30))
                [IO.File]::WriteAllText((Join-Path $fixtureRoot 'outputs.json'), ($simulation.lab | ConvertTo-Json -Depth 30))
                [IO.File]::WriteAllText($summaryPath, ($simulation.summary | ConvertTo-Json -Depth 30))
                if ($Options.summaryText) { [IO.File]::WriteAllText($summaryPath, $Options.summaryText) }
                if ($Options.publicSummary) { $summaryPath = $exporter }
                if ($Options.relativeState) { $statePath = 'state.json' }
                if ($Options.relativeSummary) { $summaryPath = 'report.json' }
                $link = $null
                if ($Options.linkedSummary -or $Options.linkedState) {
                    $link = Join-Path $fixtureRoot 'linked-input'
                    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
                    $null = New-Item -ItemType $linkType -Path $link -Target $fixtureRoot
                    if ($Options.linkedSummary) { $summaryPath = Join-Path $link 'report.json' }
                    if ($Options.linkedState) { $statePath = Join-Path $link 'state.json' }
                }
                function Import-Module { }
                function az { throw 'Unexpected real Azure CLI' }
                function Confirm-LabRunContext($State) {
                    $simulation.confirmed++
                    $simulation.directory = $State.runDirectory
                    if ($simulation.options.ownershipFailure) { throw 'OFFLINE-OWNERSHIP-BLOCKED' }
                    $groups = @($State.resourceGroups | ForEach-Object { @{name=$_; id="/subscriptions/$($State.subscriptionId)/resourceGroups/$_"; tags=@{'fgl-owner'=$State.ownershipId; 'fgl-lab'=$State.labId}} })
                    if ($simulation.options.missingGroup) { return $groups[0] }
                    if ($simulation.options.foreignGroup) { $groups[0].tags['fgl-owner'] = 'foreign' }
                    return $groups
                }
                function Invoke-LabAz($State, $Arguments, $Label) {
                    $simulation.calls++
                    $simulation.arguments += ,$Arguments
                    Assert-Export ($State.runDirectory -eq $simulation.directory -and $State.runDirectory -ne $simulation.home) 'Responses not isolated in export directory'
                    if ($Label -ceq 'evidence-runner') {
                        Assert-Export (($Arguments -join '|') -ceq 'vm|show|--resource-group|rg-fgl-sample01-integration|--name|vm-fgl-sample01-runner') 'Unexpected VM verification'
                        $result = @{id=$simulation.lab.runner; tags=@{'fgl-owner'=$State.ownershipId; 'fgl-lab'=$State.labId}; storageProfile=@{osDisk=@{osType='Linux'}}}
                        if ($simulation.options.runnerMutation) { & $simulation.options.runnerMutation $result }
                    } else {
                        Assert-Export ($Arguments.Count -eq 11 -and ($Arguments[0..9] -join '|') -ceq 'vm|run-command|invoke|--resource-group|rg-fgl-sample01-integration|--name|vm-fgl-sample01-runner|--command-id|RunShellScript|--scripts') 'Unexpected runner operation'
                        $simulation.chunks++
                        $scriptText = [IO.File]::ReadAllText($Arguments[-1].Substring(1))
                        $simulation.scriptTexts.Add($scriptText)
                        $encodedMatch = [regex]::Match($scriptText, "request = json.loads\(base64.b64decode\('([A-Za-z0-9+/=]+)'\)\)")
                        Assert-Export $encodedMatch.Success 'Missing inert reader request'
                        $requestData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedMatch.Groups[1].Value)) | ConvertFrom-Json -AsHashtable
                        $simulation.chunkRequests.Add($requestData)
                        Assert-Export ($requestData.Count -eq 5 -and $requestData.directory -ceq 'minimal-00000000000000000000000000000000' -and $requestData.limit -ge 0 -and $requestData.limit -le 1048576 -and $requestData.offset -ge 0) 'Unsafe reader parameters'
                        $bodyIndex = [int]$requestData.file.Substring(0,2) - 1
                        $bodyBytes = $simulation.bodies[$bodyIndex]
                        $packetData = @{status='limit'; size=$bodyBytes.Length; limit=$requestData.limit}
                        if ($bodyBytes.Length -le $requestData.limit) {
                            $count = [math]::Min(1800, $bodyBytes.Length-$requestData.offset)
                            $packetData = @{status='ok'; size=$bodyBytes.Length; offset=$requestData.offset; signature=('b' * 64); data=[Convert]::ToBase64String($bodyBytes, $requestData.offset, $count)}
                        }
                        if ($simulation.options.packetMutation) { & $simulation.options.packetMutation $packetData $requestData }
                        $messageText = $requestData.marker + "_BEGIN`n" + ($packetData | ConvertTo-Json -Compress -Depth 10) + "`n" + $requestData.marker + '_END'
                        if ($simulation.options.frameMutation) { $messageText = & $simulation.options.frameMutation $messageText }
                        $result = @{value=@(@{code='ProvisioningState/succeeded'; message="Enable succeeded: `n[stdout]`n$messageText`n[stderr]`n"})}
                        $simulation.maximumMessage = [math]::Max($simulation.maximumMessage, $result.value[0].message.Length)
                        if ($simulation.options.responseMutation) { & $simulation.options.responseMutation $result }
                        if ($simulation.options.collision) { [IO.File]::WriteAllText((Join-Path $State.runDirectory $requestData.file), 'EXISTING-DO-NOT-OVERWRITE') }
                    }
                    [IO.File]::WriteAllText((Join-Path $State.runDirectory "$Label-response.json"), ($result | ConvertTo-Json -Depth 15))
                    if ($simulation.options.commandFailure -and $Label -cne 'evidence-runner') { throw 'OFFLINE-COMMAND-FAILED' }
                    return $result
                }
                $parameters = @{StatePath=$statePath; SummaryPath=$summaryPath}
                if ($Options.ContainsKey('limit')) { $parameters.MaxTotalBytes = $Options.limit }
                $observed = [Collections.Generic.List[string]]::new()
                try { & $exporter @parameters 6>&1 | ForEach-Object { $observed.Add([string]$_) } } catch { $simulation.error = $_.Exception.Message }
                finally { if ($link) { Remove-Item -LiteralPath $link -Force } }
                $simulation.output = $observed -join "`n"
                Assert-Export (-not $simulation.output.Contains('PRIVATE-SENTINEL') -and -not $simulation.error.Contains('PRIVATE-SENTINEL') -and -not $simulation.output.Contains($state.subscriptionId) -and -not $simulation.output.Contains($state.ownershipId) -and -not $simulation.output.Contains([string]$summary.rawDirectory)) 'Private content printed'
                Assert-Export ([IO.File]::ReadAllText((Join-Path $fixtureRoot 'state.json')) -ceq ($simulation.state | ConvertTo-Json -Depth 30)) 'State was modified'
                return $simulation
            }
            $success = Invoke-ExportOffline
            Assert-Export (-not $success.error -and $success.confirmed -eq 1 -and $success.chunks -eq 4 -and $success.maximumMessage -lt 3000) 'Valid multichunk export failed'
            $receipt = [IO.File]::ReadAllText((Join-Path $success.directory 'export-complete.json')) | ConvertFrom-Json -AsHashtable
            Assert-Export ($receipt.complete -and $receipt.evidence.Count -eq 2 -and $receipt.totalBytes -eq ($success.bodies[0].Length + $success.bodies[1].Length) -and $receipt.summarySha256 -ceq (Get-ExportHash ([IO.File]::ReadAllBytes((Join-Path $success.directory 'summary.json'))))) 'Incomplete receipt'
            foreach ($index in 0..1) { Assert-Export ((Get-ExportHash ([IO.File]::ReadAllBytes((Join-Path $success.directory $success.summary.evidence[$index].file)))) -ceq (Get-ExportHash $success.bodies[$index])) 'Evidence bytes changed' }
            Assert-Export (@(Get-ChildItem -LiteralPath $success.directory -Filter '*-response.json').Count -eq $success.calls) 'Private response artifacts lost'
            foreach ($guard in @('set -eu', 'umask 077', 'timeout 20 python3', 'os.O_DIRECTORY | os.O_NOFOLLOW', 'dir_fd=directory', 'os.O_NOFOLLOW | os.O_NONBLOCK', 'stat.S_ISREG(before.st_mode)', 'before.st_nlink != 1', 'os.pread(descriptor, min(1800', 'identity(before) != identity(os.fstat(descriptor))')) { Assert-Export ($success.scriptTexts[0].Contains($guard)) 'Remote filesystem guard missing' }
            Assert-Export (-not ($success.scriptTexts -join '').Contains('OPERATOR-CREDENTIALS') -and -not ($success.scriptTexts -join '').Contains($success.state.ownershipId) -and -not $success.scriptTexts[0].Contains("`r")) 'Remote script leaked credentials, identity or CRLF'
            $checks++
            $component = Invoke-ExportOffline @{responseMutation={param($response) $response.value[0].code='ComponentStatus/StdOut/succeeded'; $response.value += @{code='ComponentStatus/StdErr/succeeded'; message=''}}}
            Assert-Export (-not $component.error -and $component.chunks -eq 4) 'Separate stdout and stderr envelope rejected'
            $checks++
            foreach ($options in @(
                @{publicSummary=$true}, @{relativeState=$true}, @{relativeSummary=$true}, @{linkedSummary=$true}, @{linkedState=$true}, @{summaryText='{PRIVATE-SENTINEL'}, @{summaryText=(' ' * 65537)}, @{limit=1048577}, @{limit=0},
                @{mutate={param($fixture) $fixture.state.minimalPrompt=$false}},
                @{mutate={param($fixture) $fixture.state.pendingPhase='destroy'}},
                @{mutate={param($fixture) $fixture.state.deploymentAuthorized='true'}},
                @{mutate={param($fixture) $fixture.state.privateAccessVerified=$false}},
                @{mutate={param($fixture) $fixture.lab.runner += '/extensions/foreign'}},
                @{mutate={param($fixture) $fixture.lab.phase='lock'}},
                @{mutate={param($fixture) $fixture.summary.rawDirectory += '/..'}},
                @{mutate={param($fixture) $fixture.summary.rawDirectory += "`n"}},
                @{mutate={param($fixture) $fixture.summary.rawDirectory='/var/lib/fgl-private/minimal-' + ('A' * 32)}},
                @{mutate={param($fixture) $fixture.summary.rawDirectory=$true}},
                @{mutate={param($fixture) $fixture.summary.schemaVersion=$true}},
                @{mutate={param($fixture) $fixture.summary.runLive='true'}},
                @{mutate={param($fixture) $fixture.summary.requests=$true}},
                @{mutate={param($fixture) $fixture.summary.requests=1}},
                @{mutate={param($fixture) $fixture.summary.evidence=@()}},
                @{mutate={param($fixture) $fixture.summary.evidence=$fixture.summary.evidence[0]}},
                @{mutate={param($fixture) $fixture.summary.evidence=@($fixture.summary.evidence[0]) * 21}},
                @{mutate={param($fixture) $fixture.summary.evidence[1]=$fixture.summary.evidence[0]}},
                @{mutate={param($fixture) $fixture.summary.evidence[0].file='../01-invoke.json'}},
                @{mutate={param($fixture) $fixture.summary.evidence[0].file="01-invoke.json'\nwhoami"}},
                @{mutate={param($fixture) $fixture.summary.evidence[0].file += "`n"}},
                @{mutate={param($fixture) $fixture.summary.evidence[0].file='01-unknown.json'}},
                @{mutate={param($fixture) $fixture.summary.evidence[0].sha256=$true}},
                @{mutate={param($fixture) $fixture.summary.evidence[0].sha256 += "`n"}},
                @{mutate={param($fixture) $fixture.summary.evidence[0].extra='unexpected'}}
            )) {
                $result = Invoke-ExportOffline $options
                Assert-Export ($result.error -and $result.confirmed -eq 0 -and $result.calls -eq 0) 'Invalid input reached Azure boundary'
                $checks++
            }
            foreach ($options in @(
                @{ownershipFailure=$true}, @{missingGroup=$true}, @{foreignGroup=$true},
                @{runnerMutation={param($runner) $runner.tags['fgl-owner']='foreign'}},
                @{runnerMutation={param($runner) $runner.tags['fgl-lab']=$true}},
                @{runnerMutation={param($runner) $runner.id += '-foreign'}},
                @{runnerMutation={param($runner) $runner.storageProfile.osDisk.osType='Windows'}}
            )) {
                $result = Invoke-ExportOffline $options
                Assert-Export ($result.error -and $result.confirmed -eq 1 -and $result.chunks -eq 0 -and -not (Test-Path (Join-Path $result.directory 'export-complete.json'))) 'Unowned runner allowed export'
                $checks++
            }
            foreach ($options in @(
                @{packetMutation={param($packet) $packet.status='blocked'}},
                @{packetMutation={param($packet) $packet.size=$true}},
                @{packetMutation={param($packet) $packet.size=0}},
                @{packetMutation={param($packet) $packet.size=1048577}},
                @{packetMutation={param($packet) $packet.offset=$true}},
                @{packetMutation={param($packet) $packet.offset++}},
                @{packetMutation={param($packet) $packet.data='?' * $packet.data.Length}},
                @{packetMutation={param($packet) $packet.data=$packet.data.Substring(4)}},
                @{packetMutation={param($packet) $packet.data=[Convert]::ToBase64String([byte[]]::new(1800))}},
                @{packetMutation={param($packet,$request) if ($request.offset -gt 0) { $packet.signature='c' * 64 }}},
                @{packetMutation={param($packet,$request) if ($request.offset -gt 0) { $packet.size++ }}},
                @{frameMutation={param($message) $message.Substring(0,$message.Length-5)}},
                @{frameMutation={param($message) $message + "`n" + $message}},
                @{frameMutation={param($message) $message.Replace('FGL_EVIDENCE_', 'WRONG_MARKER_')}},
                @{responseMutation={param($response) $response.value[0].code='ComponentStatus/StdOut/failed'}},
                @{responseMutation={param($response) $response.value[0].code='ProvisioningState/failed'}},
                @{responseMutation={param($response) $response.value[0].message='x' * 8193}},
                @{commandFailure=$true},
                @{mutate={param($fixture) $fixture.summary.evidence[0].sha256='0' * 64}}
            )) {
                $result = Invoke-ExportOffline $options
                Assert-Export ($result.error -and $result.chunks -gt 0 -and -not (Test-Path (Join-Path $result.directory '01-invoke.json')) -and -not (Test-Path (Join-Path $result.directory 'export-complete.json'))) 'Bad transfer persisted unverified evidence'
                Assert-Export (@(Get-ChildItem -LiteralPath $result.directory -Filter '*-response.json').Count -eq $result.calls) 'Failed response artifacts discarded'
                $checks++
            }
            $tooBig = Invoke-ExportOffline @{bodies=@(,[byte[]]::new(2097152))}
            Assert-Export ($tooBig.error.Contains('2097152 bytes') -and $tooBig.error.Contains('262144 bytes') -and $tooBig.chunks -eq 1 -and -not (Test-Path (Join-Path $tooBig.directory '01-invoke.json'))) 'Oversize record truncated or limit not exact'
            $checks++
            $partial = Invoke-ExportOffline @{limit=$success.bodies[0].Length}
            Assert-Export ($partial.error.Contains('remaining limit 0 bytes') -and (Test-Path (Join-Path $partial.directory '01-invoke.json')) -and -not (Test-Path (Join-Path $partial.directory '02-invoke.json')) -and -not (Test-Path (Join-Path $partial.directory 'export-complete.json'))) 'Cumulative limit lost earlier evidence or reported completion'
            $checks++
            $collision = Invoke-ExportOffline @{collision=$true}
            Assert-Export ($collision.error -and [IO.File]::ReadAllText((Join-Path $collision.directory '01-invoke.json')) -ceq 'EXISTING-DO-NOT-OVERWRITE' -and -not (Test-Path (Join-Path $collision.directory 'export-complete.json'))) 'Existing destination overwritten'
            $checks++
            $exact = Invoke-ExportOffline @{bodies=@(,[Text.Encoding]::UTF8.GetBytes('{}')); limit=2}
            Assert-Export (-not $exact.error -and $exact.chunks -eq 1) 'Exact limit or singleton evidence rejected'
            $checks++
            $maximum = Invoke-ExportOffline @{bodies=@(1..20 | ForEach-Object { ,[Text.Encoding]::UTF8.GetBytes('{}') }); limit=1048576}
            Assert-Export (-not $maximum.error -and $maximum.chunks -eq 20 -and $maximum.chunkRequests[0].limit -eq 1048576 -and $maximum.chunkRequests[-1].limit -eq (1048576-38)) 'Maximum count or explicit cumulative limit rejected'
            $checks++
            return $checks
        } finally {
            if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
        }
    }
    $checks += (Test-MinimalEvidenceExport)
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../public-files.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($path in @('scripts/Invoke-MinimalPromptChecks.ps1','scripts/Export-MinimalPromptEvidence.ps1','tests/Test-MinimalPromptChecks.ps1')) { Assert-Minimal (@($manifest.files | Where-Object { $_ -ceq $path }).Count -eq 1) 'Public manifest entry missing or duplicated' }
    $checks++
    Write-Output "PASS: $checks focused minimum prompt checks; offline only."
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }