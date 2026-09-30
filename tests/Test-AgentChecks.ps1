[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    $harnessPath = Join-Path $PSScriptRoot '../scripts/Invoke-AgentChecks.ps1'
    $harnessRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts'))
    $parseTokens = $null
    $parseErrors = $null
    $harnessAst = [Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Agent harness syntax invalid' }
    . $harnessPath -DefinitionsOnly
    $dnsDefinition = $harnessAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AgentPrivateDns' }, $true)
    if (-not $dnsDefinition) { throw 'DNS boundary missing' }
    $dnsStub = @'
function Get-AgentPrivateDns {
    param([string]$HostName)
    Assert-AgentMock ($HostName -in $fixture.hosts) 'Unknown DNS target'
    $fixture.dns++
    return $fixture.dnsStatus
}
'@
    $mockedHarness = [scriptblock]::Create($harnessAst.Extent.Text.Replace($dnsDefinition.Extent.Text, $dnsStub).Replace('$PSScriptRoot', '$harnessRoot'))
    $checks = 0

    function Invoke-AgentOffline([hashtable]$Options = @{}, [scriptblock]$Harness = $mockedHarness) {
        $state = @{subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'; ownershipId='33333333-3333-4333-8333-333333333333'; labId='sample01'; phase='activate'; resourceGroups=@('models', 'integration', 'case-a', 'case-b') | ForEach-Object { "rg-fgl-sample01-$_" }}
        $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01"
        $lab = @{
            phase='activate'; resourceGroups=$state.resourceGroups
            models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/synthetic-models"
            gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/synthetic-gateway"
            runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/synthetic-runner"
            identities=@('dev-a', 'consumer-a', 'dev-b', 'publisher-a', 'publisher-b', 'client', 'denied') | ForEach-Object { @{actor=$_; resourceId="$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/synthetic-$_"; clientId=[guid]::NewGuid().ToString(); principalId=[guid]::NewGuid().ToString()} }
            cases=@('a', 'b') | ForEach-Object {
                $label = $_
                $accountId = "$prefix-case-$label/providers/Microsoft.CognitiveServices/accounts/synthetic-case-$label"
                @{accountId=$accountId; registryId="$prefix-case-$label/providers/Microsoft.ContainerRegistry/registries/syntheticregistry$label"; projects=@('dev', 'test') | ForEach-Object { @{name="case-$label-$_"; resourceId="$accountId/projects/case-$label-$_"} }}
            }
        }
        $fixture = @{
            state=$state; lab=$lab; reads=0; writes=0; dns=0; saved=$null; dnsStatus='PASS'
            statePath=(Join-Path ([IO.Path]::GetTempPath()) 'agent-synthetic-state.json'); outputsPath=(Join-Path ([IO.Path]::GetTempPath()) 'agent-synthetic-outputs.json'); resultsPath=(Join-Path ([IO.Path]::GetTempPath()) ('agent-' + [guid]::NewGuid().ToString('N') + '.json'))
            hosts=@('a', 'b') | ForEach-Object { 'synthetic-case-' + $_ + '.services.ai.azure.com' }
            requests=[System.Collections.Generic.List[object]]::new(); errors=[System.Collections.Generic.List[string]]::new(); issued=@{}; objects=@{}; absences=@{}; created=@{}; markers=@{}; positives=@{}; lastOwned=@{}; verified=@{}; awaitingDeletion=@{}
            negativeStatus=403; negativeMessage='The principal lacks the required data action.'; negativeCode='PermissionDenied'; createStatus=200; updateStatus=200; tokenClaim=''; tokenActor='dev-a'; badCreate=$false; staleVersion=$false; collision=$false; writeFails=$false
            inferenceStatus=200; inferenceCode='InvalidRequest'; inferenceMessage='PRIVATE-SENTINEL'; inferenceInnerCode=''; inferenceInnerMessage=''; inferenceActor=''; inferenceMutation=$null; inferenceTransport=$false; inferenceHtml=$false; inferenceBytes=$false
        }
        foreach ($key in $Options.Keys) { $fixture[$key] = $Options[$key] }
        if ($Options.badPhase) { $state.phase = 'lock' }
        if ($Options.badGroups) { $lab.resourceGroups = @('invalid') }
        if ($Options.duplicateActor) { $lab.identities[1] = $lab.identities[0] }
        if ($Options.duplicateClient) { $lab.identities[1].clientId = $lab.identities[0].clientId }
        if ($Options.wrongProject) { $lab.cases[0].projects[0].resourceId = $lab.cases[1].projects[0].resourceId }
        if ($Options.outsideScope) { $lab.cases[0].accountId = "$prefix-outside/providers/Microsoft.CognitiveServices/accounts/synthetic-case-a" }
        if ($Options.internalResults) { $fixture.resultsPath = Join-Path $harnessRoot 'no-write.json' }
        if ($Options.collidingResults) { $fixture.resultsPath = $fixture.statePath }

        function Assert-AgentMock([bool]$Condition, [string]$Message) {
            if (-not $Condition) { $fixture.errors.Add($Message); throw $Message }
        }
        function Get-Content {
            [CmdletBinding()]
            param([string]$LiteralPath, [switch]$Raw)
            $fixture.reads++
            if ($LiteralPath -eq $fixture.statePath) { return $fixture.state | ConvertTo-Json -Depth 12 }
            if ($LiteralPath -eq $fixture.outputsPath) { return $fixture.lab | ConvertTo-Json -Depth 12 }
            Assert-AgentMock $false 'Unexpected file read'
        }
        function Invoke-RestMethod {
            [CmdletBinding()]
            param([uri]$Uri, [hashtable]$Headers, [switch]$NoProxy, [int]$TimeoutSec, [int]$OperationTimeoutSeconds, [int]$MaximumRedirection, [int]$MaximumRetryCount)
            Assert-AgentMock ($Uri.Scheme -ceq 'http' -and $Uri.Host -ceq '169.254.169.254' -and $Uri.AbsolutePath -ceq '/metadata/identity/oauth2/token' -and $Headers.Metadata -ceq 'true') 'Wrong IMDS target'
            Assert-AgentMock ($NoProxy -and $TimeoutSec -eq 20 -and $OperationTimeoutSeconds -eq 20 -and $MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0 -and -not $PSBoundParameters.Verbose -and -not $PSBoundParameters.Debug) 'Unsafe IMDS options'
            $query = @{}
            foreach ($part in $Uri.Query.TrimStart('?').Split('&')) { $pair = $part.Split('=', 2); $query[$pair[0]] = [uri]::UnescapeDataString($pair[1]) }
            $actors = @($lab.identities | Where-Object { $_.clientId -eq $query.client_id })
            Assert-AgentMock ($query.Count -eq 3 -and $query['api-version'] -ceq '2018-02-01' -and $query.resource -ceq 'https://ai.azure.com' -and $actors.Count -eq 1 -and $actors[0].actor -cin @('dev-a', 'dev-b', 'consumer-a')) 'Wrong IMDS actor or audience'
            $actor = $actors[0]
            $fixture.requests.Add(@{kind='IMDS'; actor=$actor.actor})
            $claims = @{aud=$query.resource; tid=$state.tenantId; oid=$actor.principalId; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600}
            if ($fixture.tokenClaim -and $actor.actor -ceq $fixture.tokenActor) { $claims[$fixture.tokenClaim] = 'invalid' }
            if ($Options.expired -and $actor.actor -ceq $fixture.tokenActor) { $claims.exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-1 }
            if ($Options.futureToken -and $actor.actor -ceq $fixture.tokenActor) { $claims.nbf = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600 }
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
            $token = "synthetic.$payload.signature"
            $fixture.issued[$token] = $actor.actor
            if ($Options.imdsFailure -and $actor.actor -ceq $fixture.tokenActor) { throw 'PRIVATE-SENTINEL' }
            return @{token_type=$(if ($Options.wrongTokenType) { 'Basic' } else { 'Bearer' }); access_token=$token}
        }
        function New-AgentResponse([int]$Status, $Data) {
            return @{StatusCode=$Status; Content=($Data | ConvertTo-Json -Depth 12 -Compress); Headers=@{Location='https://attacker.invalid/PRIVATE-SENTINEL'}}
        }
        function Invoke-WebRequest {
            [CmdletBinding()]
            param([uri]$Uri, [string]$Method, [hashtable]$Headers, [string]$Body, [string]$ContentType, [switch]$NoProxy, [int]$TimeoutSec, [int]$OperationTimeoutSeconds, [int]$MaximumRedirection, [int]$MaximumRetryCount, [switch]$SkipHttpErrorCheck)
            Assert-AgentMock ($Uri.Scheme -ceq 'https' -and $Uri.Port -eq 443 -and $Uri.Host -in $fixture.hosts -and -not $Uri.UserInfo -and -not $Uri.Fragment) 'Unsafe service target'
            Assert-AgentMock ($NoProxy -and $TimeoutSec -eq 20 -and $OperationTimeoutSeconds -eq 20 -and $MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0 -and $SkipHttpErrorCheck -and -not $PSBoundParameters.Verbose -and -not $PSBoundParameters.Debug) 'Unsafe service options'
            $actor = $fixture.issued[([string]$Headers.Authorization).Replace('Bearer ', '')]
            $label = if ($Uri.Host -ceq $fixture.hosts[0]) { 'a' } else { 'b' }
            Assert-AgentMock ($actor -ceq "dev-$label" -or ($label -ceq 'a' -and $actor -ceq 'consumer-a')) 'Wrong project identity'
            if ($Uri.AbsolutePath -ceq "/api/projects/case-$label-dev/openai/v1/responses") {
                Assert-AgentMock ($Uri.Query -ceq '' -and $Method -ceq 'Post' -and $ContentType -ceq 'application/json' -and $Headers.Accept -ceq 'application/json') 'Incorrect Responses transport'
                $requestBody = $Body | ConvertFrom-Json -AsHashtable
                $reference = $requestBody.agent_reference
                $name = $reference.name
                Assert-AgentMock ($requestBody.Count -eq 7 -and $requestBody.input -ceq 'Return only OK.' -and $requestBody.max_output_tokens -is [long] -and $requestBody.max_output_tokens -eq 256 -and $requestBody.store -is [bool] -and -not $requestBody.store -and $requestBody.stream -is [bool] -and -not $requestBody.stream -and $requestBody.background -is [bool] -and -not $requestBody.background -and $requestBody.truncation -ceq 'disabled') 'Unsafe Responses body or persistence'
                Assert-AgentMock ($reference -is [hashtable] -and $reference.Count -eq 3 -and $reference.type -ceq 'agent_reference' -and $name -cmatch '^fgl-t-[a-f0-9]{32}$' -and $fixture.objects.ContainsKey($name) -and $fixture.lastOwned[$name] -and $reference.version -is [string] -and $reference.version -ceq $fixture.objects[$name].versions.latest.version) 'Invocation without an existing GET-verified pinned disposable agent'
                Assert-AgentMock (@($fixture.requests | Where-Object { $_.operation -eq 'invoke' -and $_.actor -ceq $actor }).Count -eq 0 -and @($fixture.requests | Where-Object operation -eq 'invoke').Count -lt 3) 'Repeated or excessive inference'
                Assert-AgentMock (@($fixture.requests | Where-Object { $_.name -ceq $name -and $_.operation -in @('update', 'delete') }).Count -eq 0) 'Invocation after fixture mutation or deletion'
                $fixture.requests.Add(@{kind='HTTP'; actor=$actor; operation='invoke'; name=$name; body=$requestBody; label=$label})
                Assert-AgentMock ($fixture.requests.Count -le 34) 'Inference consumed cleanup reserve'
                $affected = -not $fixture.inferenceActor -or $fixture.inferenceActor -ceq $actor
                if ($affected -and $fixture.inferenceTransport) { throw 'PRIVATE-SENTINEL' }
                if ($affected -and $fixture.inferenceHtml) { return @{StatusCode=200; Content='<html>PRIVATE-SENTINEL</html>'} }
                if ($affected -and $fixture.inferenceStatus -ne 200) { return New-AgentResponse $fixture.inferenceStatus @{error=@{code=$fixture.inferenceCode; message=$fixture.inferenceMessage; innerError=@{code=$fixture.inferenceInnerCode; message=$fixture.inferenceInnerMessage}}} }
                $responseData = @{object='response'; id='resp_synthetic'; status='completed'; agent_reference=@{name=$reference.name; type=$reference.type; version=$reference.version}; store=$false; background=$false; truncation='disabled'; conversation=$null; previous_response_id=$null; error=$null; incomplete_details=$null; usage=@{output_tokens=1}; output=@(@{type='message'; id='msg_synthetic'; role='assistant'; status='completed'; content=@(@{type='output_text'; text='OK'; annotations=@()})})}
                if ($affected -and $fixture.inferenceMutation) { & $fixture.inferenceMutation $responseData }
                if ($fixture.inferenceBytes) { return @{StatusCode=200; Content=[Text.Encoding]::UTF8.GetBytes(($responseData | ConvertTo-Json -Depth 12 -Compress))} }
                return New-AgentResponse 200 $responseData
            }
            Assert-AgentMock ($Uri.Query -ceq '?api-version=v1') 'Wrong CRUD version or unexpected invocation route'
            Assert-AgentMock ($Uri.AbsolutePath -cmatch "^/api/projects/case-$label-dev/agents(?:/(fgl-[tc]-[a-f0-9]{32}))?$") 'Unexpected agent route'
            $name = $Matches[1]
            $requestBody = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { $null }
            if ($Method -ceq 'Post') {
                Assert-AgentMock ($ContentType -ceq 'application/json' -and $requestBody.definition.kind -ceq 'prompt' -and $requestBody.definition.model -ceq 'governed-models/lab-chat' -and $requestBody.definition.instructions -cin @('Return only OK.', 'Return only OK. Do not add punctuation.')) 'Invalid prompt definition'
                $operation = if ($name) { 'update' } else { 'create' }
                if (-not $name) { $name = $requestBody.name; Assert-AgentMock ($name -cmatch '^fgl-[tc]-[a-f0-9]{32}$' -and $fixture.absences.ContainsKey($name) -and -not $fixture.objects.ContainsKey($name)) 'Creation without exact absence' }
                Assert-AgentMock ($requestBody.Count -eq $(if ($operation -eq 'create') { 3 } else { 2 }) -and $requestBody.definition.Count -eq 3 -and $requestBody.metadata.Count -eq 2 -and $requestBody.metadata['fgl-agent-run'] -cmatch '^[a-f0-9]{32}$' -and $requestBody.metadata['fgl-agent-name'] -ceq $name) 'Invalid metadata or unexpected request fields'
                if ($operation -eq 'update') { Assert-AgentMock ($fixture.objects.ContainsKey($name)) 'Update target absent' }
            } elseif ($Method -ceq 'Delete') { $operation = 'delete'; Assert-AgentMock (-not $Body -and $fixture.lastOwned[$name]) 'DELETE without fresh ownership GET' }
            else { $operation = 'get'; Assert-AgentMock ($Method -ceq 'Get' -and -not $Body -and $name) 'Unexpected request method' }
            $fixture.requests.Add(@{kind='HTTP'; actor=$actor; operation=$operation; name=$name; body=$requestBody; label=$label})
            Assert-AgentMock ($fixture.requests.Count -le 40) 'Total HTTP cap exceeded'
            if ($operation -eq 'get') {
                if ($fixture.collision -and -not $fixture.created.ContainsKey($name)) { return New-AgentResponse 200 @{object='agent'; name=$name; metadata=@{'fgl-agent-run'='foreign'}} }
                if (-not $fixture.objects.ContainsKey($name)) {
                    if ($Options.html404) { return @{StatusCode=404; Content='<html>PRIVATE-SENTINEL</html>'; Headers=@{}} }
                    $fixture.absences[$name]=$true
                    if ($fixture.awaitingDeletion[$name] -and $actor -ceq 'dev-a') { $fixture.verified.delete = $true }
                    return New-AgentResponse 404 @{error=@{code='NotFound'; message='PRIVATE-SENTINEL'}}
                }
                $returned = $fixture.objects[$name] | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
                if ($Options.lostMarker) { $returned.versions.latest.metadata.Remove('fgl-agent-run') }
                if ($Options.foreignMarker) { $returned.versions.latest.metadata['fgl-agent-run'] = 'foreign' }
                if ($Options.wrongName) { $returned.name = 'foreign-agent' }
                if ($Options.wrongObject) { $returned.object = 'agent.version' }
                if ($Options.wrongLatestName) { $returned.versions.latest.name = 'foreign-agent' }
                if ($Options.missingLatest) { $returned.versions.Remove('latest') }
                if ($Options.ownershipReadFails -and $fixture.verified.update) { throw 'PRIVATE-SENTINEL' }
                $fixture.lastOwned[$name] = $returned.name -ceq $name -and $returned.object -ceq 'agent' -and $returned.versions.latest.name -ceq $name -and $returned.versions.latest.metadata['fgl-agent-run'] -ceq $fixture.markers[$name]
                if ($fixture.lastOwned[$name] -and $actor -ceq 'dev-a') {
                    $fixture.verified.create = $true
                    if ($returned.versions.latest.version -ceq '2') { $fixture.verified.update = $true }
                }
                return New-AgentResponse 200 $returned
            }
            if ($actor -ceq 'consumer-a') {
                Assert-AgentMock ($fixture.positives[$operation] -and $fixture.verified[$operation]) 'Consumer probe before corresponding GET-verified developer positive'
                if ($Options.negativeTransport) { throw 'PRIVATE-SENTINEL' }
                if ($fixture.negativeStatus -notin 200..299) { return New-AgentResponse $fixture.negativeStatus @{error=@{code=$fixture.negativeCode; message=$fixture.negativeMessage; detail='PRIVATE-SENTINEL'}} }
            }
            if ($operation -eq 'delete') {
                if ($Options.deleteFailure -and $actor -ne 'consumer-a') { return New-AgentResponse 403 @{error=@{code='Forbidden'; message='PRIVATE-SENTINEL'}} }
                if ($Options.cleanupFailure -and $fixture.verified.delete) { return New-AgentResponse 500 @{error=@{code='Failure'; message='PRIVATE-SENTINEL'}} }
                if ($Options.deleteNoEffect) { return New-AgentResponse 200 @{object='agent.deleted'; name=$name; deleted=$true} }
                $null = $fixture.objects.Remove($name)
                $fixture.lastOwned[$name] = $false
                $fixture.awaitingDeletion[$name] = $true
                if ($actor -ceq 'dev-a') { $fixture.positives.delete = $true }
                if ($Options.malformedDelete) { return New-AgentResponse 200 @{object='agent.deleted'; name=$name; deleted='true'} }
                if ($Options.throwAfterDelete) { throw 'PRIVATE-SENTINEL' }
                return New-AgentResponse 200 @{object='agent.deleted'; name=$name; deleted=$true}
            }
            $status = if ($operation -eq 'create') { $fixture.createStatus } else { $fixture.updateStatus }
            if ($status -ne 200) { return New-AgentResponse $status @{error=@{code='ModelNotFound'; message='Model connection not found: PRIVATE-SENTINEL'}} }
            $version = '1'
            if ($fixture.objects.ContainsKey($name)) { $version = ([int]$fixture.objects[$name].versions.latest.version + $(if ($fixture.staleVersion) { 0 } else { 1 })).ToString() }
            $object = @{object='agent'; name=$name; id="agent-$name"; versions=@{latest=@{object='agent.version'; name=$name; id="${name}:$version"; version=$version; created_at=1; metadata=$requestBody.metadata; definition=$requestBody.definition}}; private='PRIVATE-SENTINEL'}
            $fixture.objects[$name] = $object
            $fixture.markers[$name] = $requestBody.metadata['fgl-agent-run']
            $fixture.created[$name] = $true
            $fixture.lastOwned[$name] = $false
            if ($actor -ceq 'dev-a') { $fixture.positives[$operation] = $true }
            if ($Options.throwAfterCreate -and $operation -eq 'create' -and $actor -ne 'consumer-a') { throw 'PRIVATE-SENTINEL' }
            if ($Options.throwAfterUpdate -and $operation -eq 'update' -and $actor -ne 'consumer-a') { throw 'PRIVATE-SENTINEL' }
            if ($Options.throwAfterConsumerCreate -and $actor -ceq 'consumer-a' -and $operation -eq 'create') { throw 'PRIVATE-SENTINEL' }
            if ($fixture.badCreate -and $operation -eq 'create') { return New-AgentResponse 200 @{object='agent'; name=$name} }
            if ($actor -ceq 'consumer-a') { return New-AgentResponse $fixture.negativeStatus $object }
            return New-AgentResponse 200 $object
        }
        function Out-File {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, [string]$LiteralPath, [string]$Encoding, [switch]$NoClobber)
            process {
                Assert-AgentMock ($LiteralPath -eq $fixture.resultsPath -and $NoClobber -and $Encoding -ceq 'utf8') 'Unsafe result write'
                $fixture.writes++
                if ($fixture.writeFails) { throw 'PRIVATE-SENTINEL' }
                if ($Options.persistResults) {
                    $written = $false
                    try {
                        $InputObject | Microsoft.PowerShell.Utility\Out-File -LiteralPath $LiteralPath -Encoding $Encoding -NoClobber:$NoClobber -ErrorAction Stop
                        $written = $true
                        $fixture.saved = (Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw).TrimEnd("`r", "`n")
                    } finally {
                        if ($written) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force }
                    }
                } else { $fixture.saved = [string]$InputObject }
            }
        }
        $captured = @(& $Harness -StatePath $fixture.statePath -OutputsPath $fixture.outputsPath -ResultsPath $fixture.resultsPath -RunLive:(-not $Options.noLive) -Verbose -Debug *>&1)
        if ($fixture.errors.Count) { throw ($fixture.errors -join '; ') }
        if ($captured.Count -ne 1 -or $captured[0] -isnot [string]) { throw 'Expected exactly one JSON output and no diagnostic streams' }
        $fixture.report = $captured[0] | ConvertFrom-Json -AsHashtable
        if ($fixture.report.requests -ne $fixture.requests.Count -or $fixture.report.requests -gt 40 -or $fixture.report.dnsQueries -ne $fixture.dns) { throw 'Wrong request accounting' }
        if ($fixture.report.inferenceRequests -ne @($fixture.requests | Where-Object operation -eq 'invoke').Count -or $fixture.report.inferenceRequests -gt 3) { throw 'Wrong inference accounting' }
        if ($fixture.saved -and $fixture.saved -cne $captured[0]) { throw 'External and stdout report differ' }
        $text = $captured[0] + $fixture.saved
        foreach ($secret in @('PRIVATE-SENTINEL', 'resp_synthetic', 'msg_synthetic', $state.subscriptionId, $state.tenantId, $fixture.statePath, $fixture.outputsPath, $fixture.resultsPath) + $fixture.hosts + @($fixture.issued.Keys) + @($fixture.created.Keys) + @($fixture.markers.Values) + @($lab.identities.clientId) + @($lab.identities.principalId)) {
            if ($secret -and $text.Contains($secret)) { throw 'Private data in report' }
        }
        return $fixture
    }

    function Assert-AgentRow([hashtable]$Fixture, [string]$Test, [string]$Expected) {
        $rows = @($Fixture.report.tests | Where-Object { $_.test -ceq $Test })
        if ($rows.Count -ne 1 -or $rows[0].status -cne $Expected) { throw "Wrong ${Test}: expected $Expected; report: $($Fixture.report.tests | ConvertTo-Json -Depth 5 -Compress)" }
    }

    $complete = Invoke-AgentOffline
    foreach ($label in @('A', 'B')) {
        foreach ($operation in @('ABSENCE', 'CREATE', 'READ', 'UPDATE', 'DELETE', 'CRUD', 'CLEANUP-T', 'INVOKE')) { Assert-AgentRow $complete "DEV-$label-$operation" 'PASS'; $checks++ }
    }
    foreach ($operation in @('CREATE', 'UPDATE', 'DELETE')) { Assert-AgentRow $complete "CONSUMER-$operation-DENIAL" 'PASS'; $checks++ }
    foreach ($test in @('CONSUMER-INVOKE', 'PROMPT-INFERENCE')) { Assert-AgentRow $complete $test 'PASS'; $checks++ }
    Assert-AgentRow $complete 'HOSTED-EXECUTION' 'BLOCKED'
    $checks++
    if ($complete.objects.Count -or $complete.requests.Count -ne 33 -or $complete.report.inferenceRequests -ne 3 -or $complete.report.cleanupRequests -ne 5 -or $complete.writes -ne 1) { throw "Baseline accounting/cleanup mismatch: $($complete.requests.Count) requests, $($complete.report.cleanupRequests) cleanup" }
    $checks++
    foreach ($actor in @('dev-a', 'consumer-a', 'dev-b')) {
        if (@($complete.requests | Where-Object { $_.operation -eq 'invoke' -and $_.actor -ceq $actor }).Count -ne 1) { throw 'Missing actor invocation' }
        $checks++
    }
    $valid = Invoke-AgentOffline @{inferenceBytes=$true; inferenceMutation={ param($response) $response.output[0].content = @(@{type='output_text'; text=" O"; annotations=@()}, @{type='output_text'; text="K `n"; annotations=@()}) }}
    Assert-AgentRow $valid 'PROMPT-INFERENCE' 'PASS'
    $checks++
    foreach ($actor in @('dev-a', 'consumer-a', 'dev-b')) {
        foreach ($option in @('inferenceTransport', 'inferenceHtml')) {
            $failed = Invoke-AgentOffline @{inferenceActor=$actor; $option=$true}
            $test = if ($actor -ceq 'consumer-a') { 'CONSUMER-INVOKE' } else { $actor.ToUpperInvariant() + '-INVOKE' }
            Assert-AgentRow $failed $test $(if ($option -eq 'inferenceHtml') { 'FAIL' } else { 'INCONCLUSIVE' })
            foreach ($label in @('A', 'B')) { Assert-AgentRow $failed "DEV-$label-CRUD" 'PASS'; Assert-AgentRow $failed "DEV-$label-CLEANUP-T" 'PASS' }
            if ($failed.objects.Count -or $failed.report.inferenceRequests -ne 3 -or $failed.report.requests -ne 33) { throw 'Invocation failure changed CRUD, cleanup or retry accounting' }
            $checks++
        }
    }
    foreach ($status in @(201, 204, 301, 400, 401, 403, 404, 422, 429, 500, 503)) {
        $failed = Invoke-AgentOffline @{inferenceStatus=$status}
        foreach ($test in @('DEV-A-INVOKE', 'DEV-B-INVOKE', 'CONSUMER-INVOKE', 'PROMPT-INFERENCE')) { Assert-AgentRow $failed $test $(if ($status -in 200..299) { 'FAIL' } else { 'INCONCLUSIVE' }) }
        if ($failed.objects.Count -or $failed.report.requests -ne 33) { throw 'HTTP error triggered retry or bypassed cleanup' }
        $checks++
    }
    foreach ($failure in @(
        @{code='ConnectionNotFound'; message=('Connection https://' + 'synthetic-case-a' + '.services.ai.azure.com PRIVATE-SENTINEL not found'); structural='connection resolution'},
        @{code='InvalidRequest'; message='store false is not supported for PRIVATE-SENTINEL'; structural='request parameter or protocol incompatibility'},
        @{code='UnsupportedModel'; message='Model PRIVATE-SENTINEL is unsupported'; structural='model deployment resolution'},
        @{code='UserError'; inner='RuntimeError'; message='Runtime capability PRIVATE-SENTINEL unavailable'; structural='runtime incompatibility'}
    )) {
        $failed = Invoke-AgentOffline @{inferenceStatus=400; inferenceCode=$failure.code; inferenceMessage=$failure.message; inferenceInnerCode=$failure.inner}
        Assert-AgentRow $failed 'PROMPT-INFERENCE' 'BLOCKED'
        $row = $failed.report.tests | Where-Object test -eq 'DEV-A-INVOKE'
        if (-not $row.reason.Contains("serviceCode=$($failure.code);") -or -not $row.reason.Contains($failure.structural) -or ($failure.inner -and -not $row.reason.Contains("innerCode=$($failure.inner);"))) { throw 'Sanitized service diagnosis missing' }
        if ($failed.objects.Count -or $failed.report.inferenceRequests -ne 3 -or $failed.report.requests -ne 33) { throw 'Provider incompatibility caused retry, persistence fallback or lost cleanup' }
        $checks++
    }
    foreach ($privateCode in @('PRIVATE-SENTINEL', ('synthetic-case-a' + '.services.ai.azure.com'), '11111111-1111-4111-8111-111111111111')) {
        $failed = Invoke-AgentOffline @{inferenceStatus=500; inferenceCode=$privateCode; inferenceMessage=$privateCode; inferenceInnerCode=$privateCode; inferenceInnerMessage=$privateCode}
        $row = $failed.report.tests | Where-Object test -eq 'DEV-A-INVOKE'
        if (-not $row.reason.Contains('serviceCode=redacted-or-unavailable; innerCode=redacted-or-unavailable;')) { throw 'Unrecognized service code was not redacted' }
        $checks++
    }
    $withoutStoreEcho = Invoke-AgentOffline @{inferenceMutation={ param($response) $null = $response.Remove('store') }}
    foreach ($test in @('DEV-A-INVOKE', 'DEV-B-INVOKE', 'CONSUMER-INVOKE', 'PROMPT-INFERENCE')) { Assert-AgentRow $withoutStoreEcho $test 'PASS' }
    if (-not ($withoutStoreEcho.report.tests | Where-Object test -eq 'DEV-A-INVOKE').reason.Contains('store not echoed; not proof of retention')) { throw 'Missing store echo overstated retention evidence' }
    $checks++
    $invalidResponses = @(
        { param($response) $response.object = 'chat.completion' },
        { param($response) $response.object = @('response') },
        { param($response) $response.id = '' },
        { param($response) $response.status = 'in_progress' },
        { param($response) $response.status = 'failed' },
        { param($response) $response.status = @('completed') },
        { param($response) $response.error = @{code='server_error'; message='PRIVATE-SENTINEL'} },
        { param($response) $response.error = 'PRIVATE-SENTINEL' },
        { param($response) $null = $response.Remove('error') },
        { param($response) $response.incomplete_details = @{reason='max_output_tokens'} },
        { param($response) $null = $response.Remove('incomplete_details') },
        { param($response) $response.errors = @(@{code='server_error'; message='PRIVATE-SENTINEL'}) },
        { param($response) $response.agent_reference = $null },
        { param($response) $response.agent_reference.type = @('agent_reference') },
        { param($response) $response.agent_reference.name = 'PRIVATE-SENTINEL' },
        { param($response) $response.agent_reference.name = @($response.agent_reference.name) },
        { param($response) $response.agent_reference.version = '2' },
        { param($response) $response.agent_reference.version = 1 },
        { param($response) $response.store = $true },
        { param($response) $response.store = 'false' },
        { param($response) $response.store = $null },
        { param($response) $response.background = $true },
        { param($response) $response.truncation = 'auto' },
        { param($response) $response.truncation = @('disabled') },
        { param($response) $response.conversation = @{id='PRIVATE-SENTINEL'} },
        { param($response) $response.previous_response_id = 'PRIVATE-SENTINEL' },
        { param($response) $response.output = @() },
        { param($response) $response.output = $response.output[0] },
        { param($response) $response.output += @{type='function_call'; id='PRIVATE-SENTINEL'; status='in_progress'} },
        { param($response) $response.output[0].id = '' },
        { param($response) $response.output[0].type = @('message') },
        { param($response) $response.output[0].role = 'user' },
        { param($response) $response.output[0].role = @('assistant') },
        { param($response) $response.output[0].status = 'incomplete' },
        { param($response) $response.output[0].status = @('completed') },
        { param($response) $response.output[0].content = @() },
        { param($response) $response.output[0].content = $response.output[0].content[0] },
        { param($response) $response.output[0].content[0].type = 'refusal' },
        { param($response) $response.output[0].content[0].type = @('output_text') },
        { param($response) $response.output[0].content[0].text = @('OK') },
        { param($response) $response.output[0].content[0].text = 'PRIVATE-SENTINEL' },
        { param($response) $response.output[0].content[0].text = 'OK.' },
        { param($response) $response.output[0].content[0].text = 'ok' },
        { param($response) $response.output[0].content[0].text = ''; $response.output_text = 'OK' },
        { param($response) $response.usage.output_tokens = 257 },
        { param($response) $response.usage.output_tokens = '1' }
    )
    foreach ($mutation in $invalidResponses) {
        $failed = Invoke-AgentOffline @{inferenceMutation=$mutation}
        foreach ($test in @('DEV-A-INVOKE', 'DEV-B-INVOKE', 'CONSUMER-INVOKE', 'PROMPT-INFERENCE')) { Assert-AgentRow $failed $test 'FAIL' }
        if ($failed.objects.Count -or $failed.report.requests -ne 33) { throw 'Malformed response changed bounded cleanup behavior' }
        $checks++
    }
    $persisted = Invoke-AgentOffline @{persistResults=$true}
    if ($persisted.writes -ne 1 -or -not $persisted.saved -or 'RESULTS' -in $persisted.report.tests.test -or (Test-Path -LiteralPath $persisted.resultsPath)) { throw 'Native result persistence or temporary report cleanup failed' }
    $checks++
    $disabled = Invoke-AgentOffline @{noLive=$true}
    Assert-AgentRow $disabled 'LIVE' 'BLOCKED'
    if ($disabled.reads -or $disabled.writes -or $disabled.dns -or $disabled.requests.Count -or $disabled.report.tests.Count -ne 1) { throw 'Non-RunLive performed I/O' }
    $checks++
    foreach ($option in @('badPhase', 'badGroups', 'duplicateActor', 'duplicateClient', 'wrongProject', 'outsideScope', 'internalResults', 'collidingResults')) {
        $failed = Invoke-AgentOffline @{$option=$true}
        Assert-AgentRow $failed 'HARNESS' 'BLOCKED'
        if ($failed.requests.Count -or $failed.dns) { throw 'Invalid inputs reached the network' }
        $checks++
    }
    foreach ($claim in @('tid', 'oid', 'aud', 'exp', 'nbf')) {
        $failed = Invoke-AgentOffline @{tokenClaim=$claim}
        Assert-AgentRow $failed 'DEV-A-CREATE' 'BLOCKED'
        if (@($failed.requests | Where-Object { $_.kind -eq 'HTTP' -and $_.label -eq 'a' }).Count) { throw 'Invalid token used' }
        $checks++
    }
    foreach ($status in @(200, 201, 204, 301, 401, 404, 429, 500)) {
        $failed = Invoke-AgentOffline @{negativeStatus=$status}
        $expected = if ($status -in 200..299) { 'FAIL' } else { 'INCONCLUSIVE' }
        foreach ($operation in @('CREATE', 'UPDATE', 'DELETE')) { Assert-AgentRow $failed "CONSUMER-$operation-DENIAL" $expected; $checks++ }
        if ($failed.objects.Count) { throw 'Unexpected consumer write not cleaned up' }
    }
    foreach ($message in @('Forbidden', 'Public network access is disabled', 'The principal lacks the required data action; firewall blocked')) {
        $failed = Invoke-AgentOffline @{negativeMessage=$message}
        Assert-AgentRow $failed 'CONSUMER-CREATE-DENIAL' 'INCONCLUSIVE'
        $checks++
    }
    $failed = Invoke-AgentOffline @{createStatus=400}
    Assert-AgentRow $failed 'DEV-A-CREATE' 'BLOCKED'
    Assert-AgentRow $failed 'CONSUMER-CREATE-DENIAL' 'BLOCKED'
    if (@($failed.requests | Where-Object actor -eq 'consumer-a').Count -ne 1 -or $failed.objects.Count) { throw 'Invalid create used as consumer positive' }
    $checks++
    $failed = Invoke-AgentOffline @{badCreate=$true}
    Assert-AgentRow $failed 'DEV-A-CREATE' 'FAIL'
    if ($failed.objects.Count) { throw 'Malformed creation response prevented owned cleanup' }
    $checks++
    $failed = Invoke-AgentOffline @{staleVersion=$true}
    Assert-AgentRow $failed 'DEV-A-UPDATE' 'FAIL'
    Assert-AgentRow $failed 'CONSUMER-UPDATE-DENIAL' 'BLOCKED'
    $checks++
    $failed = Invoke-AgentOffline @{collision=$true}
    Assert-AgentRow $failed 'DEV-A-ABSENCE' 'BLOCKED'
    if (@($failed.requests | Where-Object { $_.kind -eq 'HTTP' -and $_.operation -ne 'get' }).Count) { throw 'Collision mutated' }
    $checks++
    foreach ($option in @('expired', 'futureToken', 'imdsFailure', 'wrongTokenType')) {
        $failed = Invoke-AgentOffline @{$option=$true}
        Assert-AgentRow $failed 'DEV-A-CREATE' 'BLOCKED'
        if (@($failed.requests | Where-Object { $_.kind -eq 'HTTP' -and $_.label -eq 'a' }).Count) { throw 'Invalid IMDS result reached Foundry' }
        $checks++
    }
    $failed = Invoke-AgentOffline @{tokenClaim='oid'; tokenActor='consumer-a'}
    Assert-AgentRow $failed 'DEV-A-CRUD' 'PASS'
    Assert-AgentRow $failed 'CONSUMER-CREATE-DENIAL' 'BLOCKED'
    Assert-AgentRow $failed 'CONSUMER-INVOKE' 'BLOCKED'
    Assert-AgentRow $failed 'DEV-A-INVOKE' 'PASS'
    Assert-AgentRow $failed 'DEV-B-INVOKE' 'PASS'
    if ($failed.report.inferenceRequests -ne 2) { throw 'Invalid consumer token reached inference' }
    $checks++
    foreach ($dnsStatus in @('FAIL', 'INCONCLUSIVE')) {
        $failed = Invoke-AgentOffline @{dnsStatus=$dnsStatus}
        Assert-AgentRow $failed 'DEV-A-CRUD' 'BLOCKED'
        if ($failed.requests.Count) { throw 'Unproven private DNS reached IMDS' }
        $checks++
    }
    $failed = Invoke-AgentOffline @{html404=$true}
    Assert-AgentRow $failed 'DEV-A-ABSENCE' 'BLOCKED'
    if (@($failed.requests | Where-Object { $_.kind -eq 'HTTP' -and $_.operation -ne 'get' }).Count) { throw 'Untyped 404 authorized creation' }
    $checks++
    foreach ($option in @('lostMarker', 'foreignMarker', 'wrongName', 'wrongObject', 'wrongLatestName', 'missingLatest')) {
        $failed = Invoke-AgentOffline @{$option=$true}
        Assert-AgentRow $failed 'DEV-A-CLEANUP-T' 'INCONCLUSIVE'
        if (@($failed.requests | Where-Object operation -eq 'delete').Count -or $failed.objects.Count -ne 2) { throw 'Unowned or malformed object deleted' }
        $checks++
    }
    foreach ($option in @('throwAfterCreate', 'throwAfterUpdate', 'throwAfterDelete', 'malformedDelete')) {
        $failed = Invoke-AgentOffline @{$option=$true}
        Assert-AgentRow $failed 'DEV-A-CLEANUP-T' 'PASS'
        if ($failed.objects.Count) { throw 'Uncertain write not reconciled by cleanup' }
        if ($option -eq 'malformedDelete') { Assert-AgentRow $failed 'DEV-A-DELETE' 'FAIL'; Assert-AgentRow $failed 'CONSUMER-DELETE-DENIAL' 'BLOCKED' }
        $checks++
    }
    $failed = Invoke-AgentOffline @{negativeStatus=200; throwAfterConsumerCreate=$true}
    Assert-AgentRow $failed 'CONSUMER-CREATE-DENIAL' 'INCONCLUSIVE'
    Assert-AgentRow $failed 'DEV-A-CLEANUP-C' 'PASS'
    if ($failed.objects.Count) { throw 'Uncertain consumer create not cleaned up' }
    $checks++
    foreach ($option in @('deleteFailure', 'deleteNoEffect', 'cleanupFailure', 'ownershipReadFails')) {
        $failed = Invoke-AgentOffline @{$option=$true}
        Assert-AgentRow $failed 'DEV-A-CLEANUP-T' 'INCONCLUSIVE'
        if (-not $failed.objects.Count) { throw 'Cleanup failure fixture did not retain an object' }
        $checks++
    }
    $failed = Invoke-AgentOffline @{negativeTransport=$true}
    foreach ($operation in @('CREATE', 'UPDATE', 'DELETE')) { Assert-AgentRow $failed "CONSUMER-$operation-DENIAL" 'INCONCLUSIVE'; $checks++ }
    $failed = Invoke-AgentOffline @{negativeCode='DENIED'; negativeMessage='requested access to the resource is denied.'}
    Assert-AgentRow $failed 'CONSUMER-CREATE-DENIAL' 'INCONCLUSIVE'
    $checks++
    $failed = Invoke-AgentOffline @{updateStatus=422}
    Assert-AgentRow $failed 'DEV-A-UPDATE' 'BLOCKED'
    Assert-AgentRow $failed 'CONSUMER-UPDATE-DENIAL' 'BLOCKED'
    $checks++
    $failed = Invoke-AgentOffline @{writeFails=$true}
    Assert-AgentRow $failed 'RESULTS' 'BLOCKED'
    if ($failed.objects.Count) { throw 'Report failure bypassed cleanup' }
    $checks++
    $mutations = @(
        @{old='$NoProxy=$true'; new='$NoProxy=$false'; options=@{}},
        @{old="NoProxy=`$true; TimeoutSec=20; OperationTimeoutSeconds=20"; new="NoProxy=`$false; TimeoutSec=20; OperationTimeoutSeconds=20"; options=@{}},
        @{old="`$latest.metadata['fgl-agent-run'] -ceq `$Marker"; new='$true'; options=@{foreignMarker=$true}},
        @{old="'https://ai.azure.com' @{requests=0}"; new="'https://management.azure.com' @{requests=0}"; options=@{}},
        @{old='/openai/v1/responses'; new='/openai/responses?api-version=2025-11-15-preview'; options=@{}},
        @{old='max_output_tokens=256'; new='max_output_tokens=512'; options=@{}},
        @{old='store=$false; stream=$false'; new='store=$true; stream=$false'; options=@{}},
        @{old='version=$OwnedAgent.data.versions.latest.version'; new="version='latest'"; options=@{}},
        @{old='MaximumRetryCount=0'; new='MaximumRetryCount=1'; options=@{}},
        @{old="`$data.status -cne 'completed'"; new='$false'; options=@{inferenceMutation={ param($response) $response.status='failed' }}; test='PROMPT-INFERENCE'}
    )
    $negativeControls = 0
    foreach ($mutation in $mutations) {
        if (-not $mockedHarness.ToString().Contains($mutation.old)) { continue }
        $mutant = [scriptblock]::Create($mockedHarness.ToString().Replace($mutation.old, $mutation.new))
        $rejected = $false
        try {
            $mutantResult = Invoke-AgentOffline $mutation.options $mutant
            if ($mutation.test) { Assert-AgentRow $mutantResult $mutation.test 'FAIL' }
        } catch { $rejected=$true }
        if (-not $rejected) { throw 'Deliberately unsafe mutation survived the fixture checks' }
        $negativeControls++
        $checks++
    }
    if ($negativeControls -ne 9) { throw 'Expected nine executable negative controls' }
    $budget = @{requests=0; cleanupRequests=0}
    foreach ($attempt in 1..34) { Use-AgentRequestBudget $budget }
    $rejected = $false
    try { Use-AgentRequestBudget $budget } catch { $rejected=$true }
    if (-not $rejected -or $budget.requests -ne 34) { throw 'Cleanup reserve consumed' }
    foreach ($attempt in 1..6) { Use-AgentRequestBudget $budget -Cleanup }
    $rejected = $false
    try { Use-AgentRequestBudget $budget -Cleanup } catch { $rejected=$true }
    if (-not $rejected -or $budget.requests -ne 40 -or $budget.cleanupRequests -ne 6) { throw 'Hard cap exceeded' }
    $checks++
    Write-Output "PASS: $checks agent checks including $negativeControls executable negative controls; baseline 33 HTTP requests (3 IMDS, 27 CRUD/cleanup, 3 inference), 5 finally-cleanup requests; all fixtures offline"
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }