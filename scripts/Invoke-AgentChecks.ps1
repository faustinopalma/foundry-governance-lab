<#
.SYNOPSIS
Bounded disposable-agent CRUD, invocation and consumer authorization checks on the private runner.
.DESCRIPTION
RunLive requires external activated state, outputs and a new external results file. Without RunLive there is no input, output-file, DNS or HTTP I/O. Standard output is one sanitized JSON report.
Only dev-a, dev-b and consumer-a UAMIs use IMDS tokens for https://ai.azure.com. No operator, Owner, CLI, connection mutation or hosted runtime is used.
At most 40 HTTP attempts including IMDS, with six slots reserved for finally cleanup; 20-second connection/read timeouts, no proxy, redirects or retries. PowerShell 7.4+ is required for explicit read timeouts. DNS is counted separately (two lookups, five seconds each).
T and C are random per-run names. Mutations require prior absence; deletion additionally requires a fresh exact-name GET with the current run marker in versions.latest.metadata. No discovered names or response URLs are followed. Cleanup is best effort, not an atomic ownership lock or a guarantee after process termination.
Each actor makes at most one Responses POST, three total, against the existing GET-verified disposable agent before deletion. The exact version is pinned; max_output_tokens is 256, store/stream/background are false and truncation is disabled. No conversation, response polling, retry or persistent fallback is created. Baseline: 33 HTTP attempts, including three IMDS and five finally-cleanup requests.
The parent provisions governed-models/lab-chat through the approved account-level ApiManagement/AAD connection, independently of capability hosts; its private APIM limits remain 20/minute and 200/day. These checks do not provision services or prove gateway attribution or the runtime identity. Hosted execution remains BLOCKED until private image/runtime qualification.
Identity helpers are imported with DefinitionsOnly when available; older public sources use top-level function ASTs only. This does not execute the identity harness body.
Sources verified 2026-09-20: https://learn.microsoft.com/rest/api/microsoft-foundry/aiproject and https://learn.microsoft.com/azure/foundry/agents/how-to/configure-agent.
Responses: https://learn.microsoft.com/rest/api/microsoft-foundry/aiproject#responses and https://learn.microsoft.com/azure/foundry/agents/concepts/runtime-components#generate-a-response-without-storing.
SDK route/audience: https://github.com/Azure/azure-sdk-for-python/blob/main/sdk/ai/azure-ai-projects/azure/ai/projects/_patch.py (_resolve_openai_base_url, _resolve_openai_query_params, _get_openai_api_key). Current project route is /openai/v1/responses without api-version, not /openai/responses?api-version=2025-11-15-preview.
#>
[CmdletBinding()]
param([string]$StatePath, [string]$OutputsPath, [string]$ResultsPath, [switch]$RunLive, [switch]$DefinitionsOnly)

function Use-AgentRequestBudget {
    param([hashtable]$Budget, [switch]$Cleanup)
    $limit = if ($Cleanup) { 40 } else { 34 }
    if ($Budget.requests -ge $limit) { throw 'Agent request budget exhausted' }
    $Budget.requests++
    if ($Cleanup) { $Budget.cleanupRequests++ }
}

function Get-AgentPrivateDns {
    param([string]$HostName)
    Get-IdentityPrivateDns $HostName
}

function Get-AgentContext {
    param([hashtable]$State, [hashtable]$Lab)
    Assert-LabState $State
    if ($State.phase -cne 'activate' -or $Lab.phase -cne 'activate') { throw 'Activated lab required' }
    if (@($Lab.resourceGroups).Count -ne 4 -or @(Compare-Object $State.resourceGroups $Lab.resourceGroups).Count) { throw 'Group mismatch' }
    foreach ($resourceId in @($Lab.models, $Lab.gateway, $Lab.runner)) { Assert-LabResourceId $State $resourceId }
    $actors = @{}
    $required = @('dev-a', 'consumer-a', 'dev-b', 'publisher-a', 'publisher-b', 'client', 'denied')
    if (@($Lab.identities).Count -ne 7) { throw 'Seven explicit actors required' }
    foreach ($actor in $Lab.identities) {
        Assert-LabResourceId $State $actor.resourceId
        $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/"
        if ($actor.actor -cnotin $required -or $actors.ContainsKey($actor.actor) -or -not $actor.resourceId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $actor.resourceId.Substring($prefix.Length) -cnotmatch '^[a-z0-9-]+$') { throw 'Invalid actor' }
        foreach ($field in @('clientId', 'principalId')) { if ([guid]::Parse($actor[$field]) -eq [guid]::Empty) { throw 'Invalid actor identifier' } }
        $actors[$actor.actor] = $actor
    }
    foreach ($field in @('clientId', 'principalId', 'resourceId')) {
        if (@($Lab.identities | ForEach-Object { $_[$field].ToLowerInvariant() } | Select-Object -Unique).Count -ne 7) { throw 'Actors must be distinct' }
    }
    if (@($Lab.cases).Count -ne 2) { throw 'Two cases required' }
    $targets = @{}
    foreach ($index in 0..1) {
        $label = @('a', 'b')[$index]
        $case = $Lab.cases[$index]
        Assert-LabResourceId $State $case.accountId
        Assert-LabResourceId $State $case.registryId
        $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-case-$label/providers/"
        if ($case.accountId -notmatch '/providers/Microsoft.CognitiveServices/accounts/([a-z0-9-]+)$') { throw 'Invalid Foundry resource' }
        $accountName = $Matches[1]
        if ($case.accountId -ine "${prefix}Microsoft.CognitiveServices/accounts/$accountName") { throw 'Invalid Foundry parent' }
        if ($case.registryId -notmatch '/providers/Microsoft.ContainerRegistry/registries/([a-z0-9]+)$' -or $case.registryId -ine "${prefix}Microsoft.ContainerRegistry/registries/$($Matches[1])") { throw 'Invalid registry parent' }
        if (@($case.projects).Count -ne 2) { throw 'Two environments required' }
        foreach ($environment in @('dev', 'test')) {
            $projects = @($case.projects | Where-Object { $_.name -ceq "case-$label-$environment" })
            if ($projects.Count -ne 1 -or $projects[0].resourceId -ine "$($case.accountId)/projects/case-$label-$environment") { throw 'Project mismatch' }
            Assert-LabResourceId $State $projects[0].resourceId
        }
        $foundryHost = $accountName + '.services.ai.azure.com'
        $targets[$label] = @{hostName=$foundryHost; endpoint="https://$foundryHost/api/projects/case-$label-dev"}
    }
    if ($targets.a.hostName -eq $targets.b.hostName) { throw 'Foundry resources must be distinct' }
    return @{actors=$actors; targets=$targets}
}

function Send-AgentRequest {
    param([hashtable]$Target, [ValidateSet('Get', 'Post', 'Delete')][string]$Method, [string]$Name, [string]$Token, [hashtable]$Budget, [hashtable]$Body, [switch]$Cleanup)
    $endpointPattern = '^https://[a-z0-9-]+' + [regex]::Escape('.services.ai.azure.com') + '/api/projects/case-[ab]-dev$'
    if (-not $Token -or $Target.endpoint -cnotmatch $endpointPattern) { throw 'Invalid agent target or token' }
    if ($Name -and ($Name -cnotin $Target.names -or $Name -cnotmatch '^fgl-[tc]-[a-f0-9]{32}$')) { throw 'Unregistered disposable name' }
    if (-not $Name -and ($Method -ne 'Post' -or $Body.name -cnotin $Target.names)) { throw 'Only named disposable creation is allowed' }
    if ($Cleanup -and $Method -eq 'Post') { throw 'Cleanup cannot create or update' }
    $uri = "$($Target.endpoint)/agents"
    if ($Name) { $uri += "/$Name" }
    $uri += '?api-version=v1'
    Use-AgentRequestBudget $Budget -Cleanup:$Cleanup
    if ($Method -eq 'Get') { return Send-IdentityRequest $uri $Token @{requests=0} }
    try {
        $parameters = @{Uri=$uri; Method=$Method; Headers=@{Authorization="Bearer $Token"; Accept='application/json'}; NoProxy=$true; TimeoutSec=20; OperationTimeoutSeconds=20; MaximumRedirection=0; MaximumRetryCount=0; SkipHttpErrorCheck=$true; Verbose=$false; Debug=$false; WarningAction='SilentlyContinue'; ErrorAction='Stop'}
        if ($Method -eq 'Post') { $parameters.ContentType = 'application/json'; $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress }
        $response = Invoke-WebRequest @parameters
        $content = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        return ConvertTo-IdentityProbe ([int]$response.StatusCode) $content
    } catch { return ConvertTo-IdentityProbe 0 '' }
}

function Send-AgentInvocation {
    param([hashtable]$Target, [string]$Name, [string]$Marker, [hashtable]$OwnedAgent, [ValidateSet('dev-a', 'dev-b', 'consumer-a')][string]$Actor, [string]$Token, [hashtable]$Budget)
    $label = if ($Actor -ceq 'dev-b') { 'b' } else { 'a' }
    $endpointPattern = '^https://[a-z0-9-]+' + [regex]::Escape('.services.ai.azure.com') + "/api/projects/case-$label-dev$"
    if (-not $Token -or $Target.endpoint -cnotmatch $endpointPattern -or $Name -cnotin $Target.names -or $Name -cnotmatch '^fgl-t-[a-f0-9]{32}$' -or -not (Test-AgentDefinition $OwnedAgent $Name $Marker 'Return only OK.')) { throw 'Invocation requires a verified owned disposable agent and actor target' }
    if ($Budget.inferenceRequests -ge 3 -or $Budget.inferenceActors.ContainsKey($Actor)) { throw 'One inference per actor, three total' }
    $body = @{input='Return only OK.'; agent_reference=@{name=$Name; type='agent_reference'; version=$OwnedAgent.data.versions.latest.version}; max_output_tokens=256; store=$false; stream=$false; background=$false; truncation='disabled'}
    Use-AgentRequestBudget $Budget
    $Budget.inferenceRequests++
    $Budget.inferenceActors[$Actor] = $true
    try {
        $parameters = @{Uri="$($Target.endpoint)/openai/v1/responses"; Method='Post'; Headers=@{Authorization="Bearer $Token"; Accept='application/json'}; ContentType='application/json'; Body=($body | ConvertTo-Json -Depth 8 -Compress); NoProxy=$true; TimeoutSec=20; OperationTimeoutSeconds=20; MaximumRedirection=0; MaximumRetryCount=0; SkipHttpErrorCheck=$true; Verbose=$false; Debug=$false; WarningAction='SilentlyContinue'; ErrorAction='Stop'}
        $response = Invoke-WebRequest @parameters
        $content = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        return ConvertTo-IdentityProbe ([int]$response.StatusCode) $content
    } catch { return ConvertTo-IdentityProbe 0 '' }
}

function Get-AgentInvocationError {
    param($ErrorObject)
    if ($ErrorObject -isnot [hashtable]) { return @{blocked=$false; reason='serviceCode=unavailable; structuralReason=missing or invalid error object'} }
    $knownCodes = @('UserError', 'ForbiddenError', 'PermissionDenied', 'AuthorizationFailed', 'Forbidden', 'Unauthorized', 'NotFound', 'ResourceNotFound', 'AgentNotFound', 'ModelNotFound', 'DeploymentNotFound', 'ConnectionNotFound', 'UnsupportedModel', 'InvalidModel', 'BadRequest', 'InvalidRequest', 'InvalidRequestError', 'InvalidParameter', 'UnsupportedParameter', 'InvalidConnection', 'InvalidConnectionConfiguration', 'RuntimeError', 'InternalServerError', 'ServiceUnavailable', 'TooManyRequests', 'RateLimitExceeded', 'PublicNetworkAccessDisabled', 'invalid_request_error', 'invalid_payload', 'unsupported_parameter', 'invalid_parameter', 'server_error', 'rate_limit_exceeded', 'model_not_found', 'connection_not_found', 'content_filter', 'max_output_tokens', 'insufficient_quota', 'not_found', 'agent_not_found')
    $inner = if ($ErrorObject.innerError -is [hashtable]) { $ErrorObject.innerError } elseif ($ErrorObject.inner_error -is [hashtable]) { $ErrorObject.inner_error } else { @{} }
    $code = if ($ErrorObject.code -is [string] -and $ErrorObject.code -cin $knownCodes) { $ErrorObject.code } else { 'redacted-or-unavailable' }
    $innerCode = if ($inner.code -is [string] -and $inner.code -cin $knownCodes) { $inner.code } else { 'redacted-or-unavailable' }
    $diagnostic = "$($ErrorObject.code) $($ErrorObject.message) $($inner.code) $($inner.message)"
    $structural = if ($diagnostic -match '(?i)(network|firewall|private endpoint)') { 'network restriction or connectivity' }
        elseif ($diagnostic -match '(?i)(store|stream|background|max_output_tokens|truncation|agent_reference|api.version)' -and $diagnostic -match '(?i)(invalid|unsupported|not supported|not allowed|unrecognized)') { 'request parameter or protocol incompatibility; no retry or persistent fallback' }
        elseif ($diagnostic -match '(?i)connection') { 'connection resolution, authentication or compatibility failure; parent investigation required' }
        elseif ($diagnostic -match '(?i)(runtime|capability|hosted)') { 'runtime incompatibility; parent investigation required' }
        elseif ($diagnostic -match '(?i)(model|deployment)') { 'model deployment resolution or compatibility failure; parent investigation required' }
        elseif ($diagnostic -match '(?i)(permission|authoriz|forbidden|credential|token)') { 'authentication or authorization failure' }
        elseif ($diagnostic -match '(?i)(rate.limit|quota|too.many)') { 'rate or quota limit' }
        else { 'service error; private details suppressed' }
    return @{blocked=($structural -match 'incompatibility|compatibility|resolution'); reason="serviceCode=$code; innerCode=$innerCode; structuralReason=$structural"}
}

function Get-AgentInvocationVerdict {
    param([hashtable]$Probe, [string]$Name, [string]$Version)
    $data = $Probe.data
    if ($Probe.status -ne 200 -or ($data -is [hashtable] -and $null -ne $data.error)) {
        $errorObject = if ($data -is [hashtable]) { $data.error } else { $null }
        $errorInfo = Get-AgentInvocationError $errorObject
        $status = if ($Probe.status -ge 200 -and $Probe.status -lt 300) { 'FAIL' } elseif ($errorInfo.blocked) { 'BLOCKED' } else { 'INCONCLUSIVE' }
        return @{status=$status; reason=('Invocation not established; ' + $errorInfo.reason)}
    }
    if ($data -isnot [hashtable] -or $data.object -isnot [string] -or $data.object -cne 'response' -or $data.id -isnot [string] -or [string]::IsNullOrWhiteSpace($data.id) -or $data.status -isnot [string] -or $data.status -cne 'completed' -or -not $data.ContainsKey('error') -or -not $data.ContainsKey('incomplete_details') -or $null -ne $data.incomplete_details -or $null -ne $data.errors) {
        return @{status='FAIL'; reason='Invalid response schema, non-completed response, error or incomplete output; HTTP 200 alone is not inference evidence'}
    }
    $reference = $data.agent_reference
    if ($reference -isnot [hashtable] -or $reference.type -isnot [string] -or $reference.type -cne 'agent_reference' -or $reference.name -isnot [string] -or $reference.name -cne $Name -or $reference.version -isnot [string] -or $reference.version -cne $Version) { return @{status='FAIL'; reason='Response does not identify the requested disposable agent and pinned version'} }
    if (($data.ContainsKey('store') -and ($data.store -isnot [bool] -or $data.store)) -or $null -ne $data.conversation -or $null -ne $data.previous_response_id -or ($data.ContainsKey('background') -and ($data.background -isnot [bool] -or $data.background)) -or ($data.ContainsKey('truncation') -and ($data.truncation -isnot [string] -or $data.truncation -cne 'disabled'))) { return @{status='FAIL'; reason='Response contradicts the requested non-stored synchronous no-truncation contract; no returned response ID or URL followed'} }
    if ($data.output -isnot [array] -or $data.output.Count -ne 1) { return @{status='FAIL'; reason='Expected one assistant output message; missing, malformed or unexpected output items'} }
    $message = $data.output[0]
    if ($message -isnot [hashtable] -or $message.type -isnot [string] -or $message.type -cne 'message' -or $message.role -isnot [string] -or $message.role -cne 'assistant' -or $message.status -isnot [string] -or $message.status -cne 'completed' -or $message.id -isnot [string] -or [string]::IsNullOrWhiteSpace($message.id) -or $message.content -isnot [array] -or $message.content.Count -eq 0) { return @{status='FAIL'; reason='Assistant message schema, role, completion status or content invalid'} }
    $text = ''
    foreach ($part in $message.content) {
        if ($part -isnot [hashtable] -or $part.type -isnot [string] -or $part.type -cne 'output_text' -or $part.text -isnot [string]) { return @{status='FAIL'; reason='Assistant output contains a refusal, non-text or malformed content'} }
        $text += $part.text
    }
    if ($text.Trim() -cne 'OK') { return @{status='FAIL'; reason='Completed assistant text did not equal the expected OK; content suppressed'} }
    if ($null -ne $data.usage -and ($data.usage -isnot [hashtable] -or ($data.usage.output_tokens -isnot [int] -and $data.usage.output_tokens -isnot [long]) -or $data.usage.output_tokens -lt 0 -or $data.usage.output_tokens -gt 256)) { return @{status='FAIL'; reason='Reported output token usage is malformed or exceeds 256'} }
    $storageEcho = if ($data.ContainsKey('store')) { 'store=false echoed' } else { 'store not echoed' }
    return @{status='PASS'; reason="Completed pinned-agent response with assistant text OK, no error or incomplete output; $storageEcho; not proof of retention, gateway attribution or runtime identity"}
}

function Test-AgentAbsent {
    param([hashtable]$Probe)
    return $Probe.status -eq 404 -and $Probe.data -is [hashtable] -and $Probe.data.error -is [hashtable] -and $Probe.data.error.code -cin @('NotFound', 'ResourceNotFound', 'AgentNotFound', 'not_found', 'agent_not_found')
}

function Test-AgentOwned {
    param([hashtable]$Probe, [string]$Name, [string]$Marker)
    if (-not $Marker -or -not $Name -or $Probe.status -ne 200 -or $Probe.data -isnot [hashtable]) { return $false }
    $agent = $Probe.data
    if ($agent.object -cne 'agent' -or $agent.name -cne $Name -or $agent.id -isnot [string] -or -not $agent.id -or $agent.versions -isnot [hashtable] -or $agent.versions.latest -isnot [hashtable]) { return $false }
    $latest = $agent.versions.latest
    return $latest.object -ceq 'agent.version' -and $latest.name -ceq $Name -and $latest.id -is [string] -and [bool]$latest.id -and $latest.version -is [string] -and [bool]$latest.version -and $latest.metadata -is [hashtable] -and $latest.metadata['fgl-agent-run'] -ceq $Marker -and $latest.metadata['fgl-agent-name'] -ceq $Name
}

function Test-AgentDefinition {
    param([hashtable]$Probe, [string]$Name, [string]$Marker, [string]$Instructions)
    if (-not (Test-AgentOwned $Probe $Name $Marker)) { return $false }
    $definition = $Probe.data.versions.latest.definition
    return $definition -is [hashtable] -and $definition.kind -ceq 'prompt' -and $definition.model -ceq 'governed-models/lab-chat' -and $definition.instructions -ceq $Instructions
}

function New-AgentBody {
    param([string]$Name, [string]$Marker, [string]$Instructions, [switch]$Create)
    $body = @{definition=@{kind='prompt'; model='governed-models/lab-chat'; instructions=$Instructions}; metadata=@{'fgl-agent-run'=$Marker; 'fgl-agent-name'=$Name}}
    if ($Create) { $body.name = $Name }
    return $body
}

function Get-AgentPositiveVerdict {
    param([hashtable]$Probe, [bool]$Valid)
    if ($Valid) { return @{status='PASS'; reason='Validated disposable agent operation; not invocation evidence'} }
    $errorObject = $Probe.data.error
    if ($Probe.status -in @(400, 404, 422) -and $errorObject -is [hashtable] -and
        ([string]$errorObject.code -match '(?i)^(ModelNotFound|DeploymentNotFound|ConnectionNotFound|UnsupportedModel|InvalidModel)$' -or
        ([string]$errorObject.message -match '(?i)(model|deployment|connection)' -and [string]$errorObject.message -match '(?i)(not found|does not exist|unsupported|not supported|invalid|missing|cannot find)'))) {
        return @{status='BLOCKED'; reason='Provider rejected the governed-models/lab-chat CRUD fixture: model or connection missing, invalid or unsupported; no RBAC or invocation proof'}
    }
    if ($Probe.status -ge 200 -and $Probe.status -lt 300) { return @{status='FAIL'; reason='Success response did not establish the expected agent, definition, version or deletion'} }
    return @{status='INCONCLUSIVE'; reason='Operation not established; transport, authentication, authorization and service failures are not positive controls'}
}

function Get-AgentNegativeVerdict {
    param([bool]$PositiveReady, [hashtable]$Probe)
    if ($Probe.code -ceq 'DENIED') { return $(if ($PositiveReady) { 'INCONCLUSIVE' } else { 'BLOCKED' }) }
    return Get-IdentityNegativeVerdict $PositiveReady $Probe
}

function Add-AgentResult {
    param([System.Collections.Generic.List[object]]$Results, [string]$Test, [string]$Status, [string]$Reason, [hashtable]$Probe)
    $Results.Add([pscustomobject]@{test=$Test; status=$Status; reason=$Reason; plane='FoundryData'; httpStatus=$(if ($Probe) { $Probe.status } else { 0 }); category=$(if ($Probe) { $Probe.category } else { 'Prerequisite' })})
}

function Remove-OwnedAgent {
    param([hashtable]$Target, [string]$Name, [string]$Marker, [string]$Token, [hashtable]$Budget, [switch]$Cleanup)
    $read = Send-AgentRequest $Target Get $Name $Token $Budget -Cleanup:$Cleanup
    if (Test-AgentAbsent $read) { return @{absent=$true; deleted=$false; probe=$read; reason='Disposable name is absent; no DELETE control established'} }
    if (-not (Test-AgentOwned $read $Name $Marker)) { return @{absent=$false; deleted=$false; probe=$read; reason='Fresh ownership proof missing; DELETE suppressed and cleanup unresolved'} }
    $delete = Send-AgentRequest $Target Delete $Name $Token $Budget -Cleanup:$Cleanup
    $after = Send-AgentRequest $Target Get $Name $Token $Budget -Cleanup:$Cleanup
    $valid = $delete.status -eq 200 -and $delete.data.object -ceq 'agent.deleted' -and $delete.data.name -ceq $Name -and $delete.data.deleted -is [bool] -and $delete.data.deleted
    $absent = Test-AgentAbsent $after
    return @{absent=$absent; deleted=($valid -and $absent); probe=$delete; reason=$(if ($absent) { 'Final GET confirms absence; DELETE control additionally requires a valid deletion response' } else { 'Final GET did not confirm absence; cleanup unresolved and no DELETE control' })}
}

function Invoke-AgentCase {
    param([string]$Label, [hashtable]$Target, [string]$DeveloperToken, [string]$ConsumerToken, [hashtable]$Budget, [System.Collections.Generic.List[object]]$Results)
    $marker = [guid]::NewGuid().ToString('N')
    $targetName = 'fgl-t-' + [guid]::NewGuid().ToString('N')
    $consumerName = 'fgl-c-' + [guid]::NewGuid().ToString('N')
    $Target.names = @($targetName)
    if ($ConsumerToken) { $Target.names += $consumerName }
    $attempted = @{}
    $prefix = 'DEV-' + $Label.ToUpperInvariant()
    $createInstructions = 'Return only OK.'
    $updateInstructions = 'Return only OK. Do not add punctuation.'
    try {
        foreach ($name in $Target.names) {
            $probe = Send-AgentRequest $Target Get $name $DeveloperToken $Budget
            if (-not (Test-AgentAbsent $probe)) {
                Add-AgentResult $Results "$prefix-ABSENCE" 'BLOCKED' 'Both generated names must be absent before any mutation; existing or ambiguous objects are untouched' $probe
                return
            }
        }
        Add-AgentResult $Results "$prefix-ABSENCE" 'PASS' 'Generated disposable names returned typed HTTP 404 before any mutation' $probe
        $attempted[$targetName] = $true
        $created = Send-AgentRequest $Target Post '' $DeveloperToken $Budget (New-AgentBody $targetName $marker $createInstructions -Create)
        $createValid = Test-AgentDefinition $created $targetName $marker $createInstructions
        $verdict = Get-AgentPositiveVerdict $created $createValid
        Add-AgentResult $Results "$prefix-CREATE" $verdict.status $verdict.reason $created
        if (-not $createValid) { return }
        $read = Send-AgentRequest $Target Get $targetName $DeveloperToken $Budget
        $readValid = (Test-AgentDefinition $read $targetName $marker $createInstructions) -and $read.data.id -ceq $created.data.id -and $read.data.versions.latest.version -ceq $created.data.versions.latest.version
        $verdict = Get-AgentPositiveVerdict $read $readValid
        Add-AgentResult $Results "$prefix-READ" $verdict.status $verdict.reason $read
        if (-not $readValid) { return }
        $invokeActors = @("dev-$Label")
        if ($ConsumerToken) { $invokeActors += 'consumer-a' }
        foreach ($actor in $invokeActors) {
            $token = if ($actor -ceq 'consumer-a') { $ConsumerToken } else { $DeveloperToken }
            $test = if ($actor -ceq 'consumer-a') { 'CONSUMER-INVOKE' } else { "$prefix-INVOKE" }
            $probe = Send-AgentInvocation $Target $targetName $marker $read $actor $token $Budget
            $verdict = Get-AgentInvocationVerdict $probe $targetName $read.data.versions.latest.version
            Add-AgentResult $Results $test $verdict.status $verdict.reason $probe
        }
        if ($ConsumerToken) {
            $attempted[$consumerName] = $true
            $probe = Send-AgentRequest $Target Post '' $ConsumerToken $Budget (New-AgentBody $consumerName $marker $createInstructions -Create)
            Add-AgentResult $Results 'CONSUMER-CREATE-DENIAL' (Get-AgentNegativeVerdict $true $probe) 'Same project and validated create payload, distinct absent name; only an explicit RBAC 403 is denial evidence' $probe
        }
        $updated = Send-AgentRequest $Target Post $targetName $DeveloperToken $Budget (New-AgentBody $targetName $marker $updateInstructions)
        $updateValid = (Test-AgentDefinition $updated $targetName $marker $updateInstructions) -and $updated.data.id -ceq $read.data.id -and $updated.data.versions.latest.version -cne $read.data.versions.latest.version
        if ($updateValid) {
            $read = Send-AgentRequest $Target Get $targetName $DeveloperToken $Budget
            $updateValid = (Test-AgentDefinition $read $targetName $marker $updateInstructions) -and $read.data.id -ceq $updated.data.id -and $read.data.versions.latest.version -ceq $updated.data.versions.latest.version
            $updateProbe = $read
        } else { $updateProbe = $updated }
        $verdict = Get-AgentPositiveVerdict $updateProbe $updateValid
        Add-AgentResult $Results "$prefix-UPDATE" $verdict.status $verdict.reason $updateProbe
        if ($ConsumerToken -and $updateValid) {
            $probe = Send-AgentRequest $Target Post $targetName $ConsumerToken $Budget (New-AgentBody $targetName $marker $createInstructions)
            Add-AgentResult $Results 'CONSUMER-UPDATE-DENIAL' (Get-AgentNegativeVerdict $true $probe) 'Existing owned target after verified developer version change; consumer submits the already validated initial definition' $probe
        }
        $removed = Remove-OwnedAgent $Target $targetName $marker $DeveloperToken $Budget
        $verdict = Get-AgentPositiveVerdict $removed.probe $removed.deleted
        Add-AgentResult $Results "$prefix-DELETE" $verdict.status ($verdict.reason + '; ' + $removed.reason) $removed.probe
        if ($ConsumerToken -and $removed.deleted) {
            $created = Send-AgentRequest $Target Post '' $DeveloperToken $Budget (New-AgentBody $targetName $marker $createInstructions -Create)
            $ready = Test-AgentDefinition $created $targetName $marker $createInstructions
            if ($ready) {
                $read = Send-AgentRequest $Target Get $targetName $DeveloperToken $Budget
                $ready = (Test-AgentDefinition $read $targetName $marker $createInstructions) -and $read.data.id -ceq $created.data.id -and $read.data.versions.latest.version -ceq $created.data.versions.latest.version
            }
            Add-AgentResult $Results "$prefix-RECREATE" $(if ($ready) { 'PASS' } else { 'BLOCKED' }) 'DELETE negative requires a recreated, GET-verified owned object after the developer DELETE positive' $created
            if ($ready) {
                $probe = Send-AgentRequest $Target Delete $targetName $ConsumerToken $Budget
                Add-AgentResult $Results 'CONSUMER-DELETE-DENIAL' (Get-AgentNegativeVerdict $true $probe) 'Same-operation developer deletion succeeded first; consumer targets the recreated GET-verified object, never the absent name' $probe
            }
        }
    } finally {
        foreach ($name in $Target.names) {
            if (-not $attempted.ContainsKey($name)) { continue }
            $suffix = if ($name -ceq $targetName) { 'T' } else { 'C' }
            try {
                $removed = Remove-OwnedAgent $Target $name $marker $DeveloperToken $Budget -Cleanup
                Add-AgentResult $Results "$prefix-CLEANUP-$suffix" $(if ($removed.absent) { 'PASS' } else { 'INCONCLUSIVE' }) $removed.reason $removed.probe
            } catch { Add-AgentResult $Results "$prefix-CLEANUP-$suffix" 'INCONCLUSIVE' 'Cleanup could not finish within its reserved budget; no unproven deletion is allowed' $null }
        }
    }
}

function Invoke-AgentChecksCore {
    param([string]$InputStatePath, [string]$InputOutputsPath, [string]$OutputResultsPath)
    $agentTimer = [Diagnostics.Stopwatch]::StartNew()
    $ErrorActionPreference = 'Stop'
    $VerbosePreference = 'SilentlyContinue'
    $DebugPreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'
    $agentResults = [System.Collections.Generic.List[object]]::new()
    $agentBudget = @{requests=0; cleanupRequests=0; dnsQueries=0; inferenceRequests=0; inferenceActors=@{}}
    $agentTokens = @{}
    $destination = $null
    try {
        if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -lt [version]'7.4') { throw 'PowerShell Core 7.4 or later required' }
        Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1') -Force -Verbose:$false
        Import-Module (Join-Path $PSScriptRoot 'TestResults.psm1') -Force -Verbose:$false
        Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1') -Force -Verbose:$false
        $identityPath = Join-Path $PSScriptRoot 'Invoke-IdentityChecks.ps1'
        $identityParseTokens = $null
        $identityParseErrors = $null
        $identityAst = [Management.Automation.Language.Parser]::ParseFile($identityPath, [ref]$identityParseTokens, [ref]$identityParseErrors)
        if ($identityParseErrors.Count) { throw 'Identity helper syntax invalid' }
        if ('DefinitionsOnly' -in $identityAst.ParamBlock.Parameters.Name.VariablePath.UserPath) {
            . $identityPath -DefinitionsOnly
        } else {
            foreach ($definition in $identityAst.EndBlock.Statements) {
                if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($definition.Extent.Text)) }
            }
        }
        if (-not $InputStatePath -or -not $InputOutputsPath -or -not $OutputResultsPath) { throw 'Three external paths required' }
        $inputState = Assert-ExternalLabPath $InputStatePath
        $inputOutputs = Assert-ExternalLabPath $InputOutputsPath
        $candidate = Assert-ExternalLabPath $OutputResultsPath
        if ($candidate -ieq $inputState -or $candidate -ieq $inputOutputs -or $inputState -ieq $inputOutputs -or (Test-Path -LiteralPath $candidate) -or -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($candidate)) -PathType Container)) { throw 'Distinct inputs and new external results file required' }
        $destination = $candidate
        $agentState = Get-Content -LiteralPath $inputState -Raw | ConvertFrom-Json -AsHashtable
        $agentLab = Get-Content -LiteralPath $inputOutputs -Raw | ConvertFrom-Json -AsHashtable
        $context = Get-AgentContext $agentState $agentLab
        foreach ($label in @('a', 'b')) {
            $target = $context.targets[$label]
            $agentBudget.dnsQueries++
            $dns = Get-AgentPrivateDns $target.hostName
            Add-AgentResult $agentResults "DNS-FOUNDRY-$($label.ToUpperInvariant())" $dns 'All DNS answers must be private; not proof of endpoint ownership or RBAC' $null
            if ($dns -ne 'PASS') { continue }
            $actorName = "dev-$label"
            Use-AgentRequestBudget $agentBudget
            $agentTokens[$actorName] = Get-IdentityToken $context.actors[$actorName] $agentState.tenantId 'https://ai.azure.com' @{requests=0}
            if (-not $agentTokens[$actorName]) { continue }
            if ($label -eq 'a') {
                Use-AgentRequestBudget $agentBudget
                $agentTokens['consumer-a'] = Get-IdentityToken $context.actors['consumer-a'] $agentState.tenantId 'https://ai.azure.com' @{requests=0}
            }
            $consumerToken = if ($label -eq 'a') { $agentTokens['consumer-a'] } else { '' }
            Invoke-AgentCase $label $target $agentTokens[$actorName] $consumerToken $agentBudget $agentResults
        }
    } catch { Add-AgentResult $agentResults 'HARNESS' 'BLOCKED' 'Prerequisite validation, helper compatibility or request budget failed; private diagnostics suppressed' $null }
    finally {
        $agentTokens.Clear()
        foreach ($label in @('A', 'B')) {
            foreach ($operation in @('ABSENCE', 'CREATE', 'READ', 'UPDATE', 'DELETE')) {
                $test = "DEV-$label-$operation"
                if ($test -notin $agentResults.test) { Add-AgentResult $agentResults $test 'BLOCKED' 'Required validated inputs, private DNS, token or preceding positive was not established; probe suppressed' $null }
            }
            $rows = @($agentResults | Where-Object { $_.test -in @("DEV-$label-CREATE", "DEV-$label-READ", "DEV-$label-UPDATE", "DEV-$label-DELETE") })
            $status = if ('FAIL' -in $rows.status) { 'FAIL' } elseif (@($rows | Where-Object status -ne 'PASS').Count -eq 0) { 'PASS' } else { 'BLOCKED' }
            Add-AgentResult $agentResults "DEV-$label-CRUD" $status 'Aggregate of semantic CREATE, READ, new-version UPDATE and verified DELETE; never invocation evidence' $null
        }
        foreach ($operation in @('CREATE', 'UPDATE', 'DELETE')) {
            $test = "CONSUMER-$operation-DENIAL"
            if ($test -notin $agentResults.test) { Add-AgentResult $agentResults $test 'BLOCKED' 'Consumer token, disposable fixture or corresponding developer positive missing; no negative probe made' $null }
        }
        foreach ($test in @('DEV-A-INVOKE', 'DEV-B-INVOKE', 'CONSUMER-INVOKE')) {
            if ($test -notin $agentResults.test) { Add-AgentResult $agentResults $test 'BLOCKED' 'Private DNS, actor token or GET-verified owned disposable agent missing; no inference attempted' $null }
        }
        $invocations = @($agentResults | Where-Object { $_.test -in @('DEV-A-INVOKE', 'DEV-B-INVOKE', 'CONSUMER-INVOKE') })
        $inferenceStatus = if ('FAIL' -in $invocations.status) { 'FAIL' } elseif ('BLOCKED' -in $invocations.status) { 'BLOCKED' } elseif ('INCONCLUSIVE' -in $invocations.status) { 'INCONCLUSIVE' } else { 'PASS' }
        Add-AgentResult $agentResults 'PROMPT-INFERENCE' $inferenceStatus 'Aggregate of the three actor invocation results; CRUD, gateway attribution and runtime identity are separate evidence' $null
        Add-AgentResult $agentResults 'HOSTED-EXECUTION' 'BLOCKED' 'Private image and hosted runtime remain unqualified; a governed-model connection or prompt response does not qualify hosted execution' $null
        $report = [ordered]@{schemaVersion=1; runLive=$true; requests=$agentBudget.requests; requestLimit=40; cleanupReserve=6; cleanupRequests=$agentBudget.cleanupRequests; inferenceRequests=$agentBudget.inferenceRequests; inferenceLimit=3; dnsQueries=$agentBudget.dnsQueries; timeoutSeconds=20; elapsedSeconds=[math]::Round($agentTimer.Elapsed.TotalSeconds,1); tests=$agentResults.ToArray()}
        if ($destination) {
            try {
                $json = $report | ConvertTo-Json -Depth 8
                Assert-PublicText $json
                $null = Assert-ExternalLabPath $destination
                $json | Out-File -LiteralPath $destination -Encoding utf8 -NoClobber -ErrorAction Stop
            } catch {
                Add-AgentResult $agentResults 'RESULTS' 'BLOCKED' 'External result persistence failed; private diagnostics suppressed' $null
                $report.tests = $agentResults.ToArray()
            }
        }
        $report | ConvertTo-Json -Depth 8
    }
}

if ($DefinitionsOnly) { return }
if (-not $RunLive) {
    [ordered]@{schemaVersion=1; runLive=$false; requests=0; requestLimit=40; cleanupReserve=6; cleanupRequests=0; inferenceRequests=0; inferenceLimit=3; dnsQueries=0; timeoutSeconds=20; elapsedSeconds=0; tests=@(@{test='LIVE'; status='BLOCKED'; reason='Explicit RunLive required; no filesystem, DNS or HTTP I/O'; plane='Harness'; httpStatus=0; category='Prerequisite'})} | ConvertTo-Json -Depth 8
    return
}
Invoke-AgentChecksCore $StatePath $OutputsPath $ResultsPath