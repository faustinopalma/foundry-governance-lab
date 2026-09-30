[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot '../scripts/Test-LabExternal.ps1') -DefinitionsOnly
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1')
    $script:passed = 0
    function Confirm-Equal($Actual, $Expected, [string]$Label) {
        if ($Actual -cne $Expected) { throw "Failed: $Label; expected $Expected, received $Actual" }
        $script:passed++
    }
    function Copy-Fixture([hashtable]$Value) { return ($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100) }
    function Confirm-Rejected([scriptblock]$Operation, [string]$Label) {
        $rejected = $false
        try { $null = & $Operation } catch { $rejected = $true }
        Confirm-Equal $rejected $true $Label
    }
    function az { throw 'Live Azure CLI is forbidden in local tests' }
    function Invoke-WebRequest { throw 'Live HTTP is forbidden in local tests' }
    $bindingTokens = $null
    $bindingErrors = $null
    $executionAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/LabExecution.psm1'), [ref]$bindingTokens, [ref]$bindingErrors)
    $cliFunction = $executionAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-LabAz' }, $true)
    $bindingProbe = [scriptblock]::Create($cliFunction.Body.ParamBlock.Extent.Text + '; return ,$Arguments')
    $bound = & $bindingProbe -State @{} -Arguments @('resource','list','--resource-group','') -Label 'synthetic-binding'
    Confirm-Equal $bound.Count 4 'Real CLI parameter binder preserves explicit empty argument'
    Confirm-Equal $bound[3] '' 'Subscription inventory can override default resource group'
    Confirm-Rejected { & $bindingProbe -State @{} -Arguments $null -Label 'synthetic-binding' } 'Null command arguments remain invalid'
    foreach ($address in @('10.0.0.4', '172.16.1.1', '192.168.1.1', '100.64.0.1', '127.0.0.1', '169.254.169.254', '0.0.0.0', '198.18.1.1', '192.0.2.1', '203.0.113.5', '224.1.1.1', '::1', 'fc00::1', 'fe80::1', '2001:db8::1', '2002::1', '::ffff:10.1.1.1', 'invalid')) { Confirm-Equal (Test-ExternalPublicAddress $address) $false 'Nonpublic DNS rejected' }
    foreach ($address in @('8.8.8.8', '1.1.1.1', '2606:4700:4700::1111')) { Confirm-Equal (Test-ExternalPublicAddress $address) $true 'Public DNS accepted' }
    $state = @{
        subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'; ownershipId='33333333-3333-4333-8333-333333333333'
        labId='sample01'; phase='activate'; pendingPhase=$null; authorizedAt='2026-09-20T10:00:00Z'
        resourceGroups=@('models', 'integration', 'case-a', 'case-b') | ForEach-Object { "rg-fgl-sample01-$_" }
        preexistingGroupIds=@('/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/existing')
    }
    $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01"
    $lab = @{phase='activate'; resourceGroups=$state.resourceGroups; models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-abcdefghijklm"; gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-abcdefghijklm"; cases=@()}
    foreach ($case in @('a', 'b')) { $lab.cases += @{accountId="$prefix-case-$case/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-$case-abcdefghijklm"; registryId="$prefix-case-$case/providers/Microsoft.ContainerRegistry/registries/crfglsample01$($case)abcdefghijklm"} }
    $plan = Get-ExternalPlan $state $lab
    Confirm-Equal $plan.Count 6 'Exactly six output endpoints'
    Confirm-Equal @($plan | Where-Object provider -eq 'Foundry').Count 3 'Three Foundry endpoints'
    Confirm-Equal @($plan | Where-Object provider -eq 'ACR').Count 2 'Two ACR endpoints'
    $bad = Copy-Fixture $lab
    $bad.gateway += '-other'
    Confirm-Rejected { Get-ExternalPlan $state $bad } 'Changed hostname rejected'
    $bad = Copy-Fixture $state
    $bad.pendingPhase='activate'
    Confirm-Rejected { Get-ExternalPlan $bad $lab } 'Pending activation rejected'
    $probe = @{provider='Foundry'; addresses=@('8.8.8.8'); connectedAddress='8.8.8.8'; httpStatus=403; body='{"error":{"code":"403","message":"Access denied due to Virtual Network/Firewall rules."}}'}
    Confirm-Equal (Get-ExternalProbeVerdict $probe).status 'PASS' 'Explicit Foundry network denial'
    foreach ($status in @(401, 404, 302, 429, 500)) {
        $changed = Copy-Fixture $probe
        $changed.httpStatus=$status
        Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'Status alone is not network proof'
    }
    $changed = Copy-Fixture $probe
    $changed.httpStatus=200
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'FAIL' 'Negative control: public acceptance breaks pass'
    $changed = Copy-Fixture $probe
    $changed.body='{"error":{"code":"403","message":"Caller is not authorized"}}'
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'RBAC denial is not network proof'
    $changed = Copy-Fixture $probe
    $changed.addresses+= '10.0.0.4'
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'Mixed DNS is not an external test'
    $changed = Copy-Fixture $probe
    $changed.transportError='timeout'
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'Timeout is not denial'
    $changed = Copy-Fixture $probe
    $changed.connectedAddress='1.1.1.1'
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'DNS and peer must match'
    $changed = Copy-Fixture $probe
    $changed.provider='ACR'
    $changed.body='{"errors":[{"code":"DENIED","message":"client with IP ''8.8.8.8'' is not allowed access. Refer https://aka.ms/acr/firewall to grant access."}]}'
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'PASS' 'Explicit ACR firewall denial'
    $changed.provider='APIM'
    $changed.body='{"statusCode":403,"message":"Public network access is disabled."}'
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'PASS' 'Explicit APIM network denial'
    $acrProbe = Copy-Fixture $probe
    $acrProbe.provider='ACR'
    $acrProbe.body='{"errors":[{"code":"DENIED","message":"client with IP ''203.0.113.10'' is not allowed access, refer https://aka.ms/acr/firewall to grant access"}]}'
    $apimName = ($lab.gateway -split '/')[-1]
    $apimMessage = 'Request originated from client public IP address 203.0.113.10, public network access on this `Microsoft.ApiManagement/service/{0}` is disabled. To connect to `Microsoft.ApiManagement/service/{0}`, please use the Private Endpoint from inside your virtual network. To learn more https://aka.ms/apim-privateendpoint ' -f $apimName
    $apimProbe = Copy-Fixture $probe
    $apimProbe.provider='APIM'
    $apimProbe.hostName=$plan[-1].hostName
    $apimProbe.body=@{statusCode=403; message=$apimMessage} | ConvertTo-Json -Compress
    foreach ($networkProbe in @($acrProbe, $apimProbe)) {
        $verdict = Get-ExternalProbeVerdict $networkProbe
        Confirm-Equal $verdict.status 'PASS' 'Observed explicit provider network denial'
        Confirm-Equal $verdict.reason 'PROVIDER_EXPLICIT_NETWORK_DENIAL' 'Recognized denial reason'
        foreach ($status in @(401, 404, 302, 429, 500)) {
            $changed = Copy-Fixture $networkProbe
            $changed.httpStatus=$status
            Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'Network denial body requires HTTP 403'
        }
        $changed = Copy-Fixture $networkProbe
        $changed.httpStatus=200
        Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'FAIL' 'Successful response cannot pass with a denial body'
        foreach ($body in @('Forbidden', 'null', '[]', '{}', '{')) {
            $changed = Copy-Fixture $networkProbe
            $changed.body=$body
            Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'Wrong or malformed provider body cannot pass'
        }
        foreach ($badField in @('bodyTruncated', 'dnsError', 'transportError')) {
            $changed = Copy-Fixture $networkProbe
            $changed[$badField]=$true
            Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'Observed denial still requires complete transport evidence'
        }
    }
    foreach ($body in @(
        '{"errors":[{"code":"DENIED","message":"Caller is not authorized"}]}',
        '{"errors":[{"code":"DENIED","message":"Invalid credentials; refer https://aka.ms/acr/firewall"}]}',
        $acrProbe.body.Replace('DENIED', 'UNAUTHORIZED'),
        $acrProbe.body.Replace('is not allowed access', 'is allowed access')
    )) {
        $changed = Copy-Fixture $acrProbe
        $changed.body=$body
        Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'ACR needs DENIED and the explicit network denial phrase'
    }
    foreach ($body in @(
        '{"statusCode":403,"message":"Caller is not authorized"}',
        '{"statusCode":403,"message":"Invalid subscription key; check public network access settings"}',
        (@{statusCode=401; message=$apimMessage} | ConvertTo-Json -Compress),
        (@{message=$apimMessage} | ConvertTo-Json -Compress),
        (@{error=@{code='403'; message=$apimMessage}} | ConvertTo-Json -Compress),
        (@{statusCode=403; message=$apimMessage.Replace('is disabled.', 'is enabled.')} | ConvertTo-Json -Compress),
        (@{statusCode=403; message=$apimMessage.Replace('To connect to `Microsoft.ApiManagement/service/' + $apimName, 'To connect to `Microsoft.ApiManagement/service/' + $apimName + '-other')} | ConvertTo-Json -Compress),
        (@{statusCode=403; message=$apimMessage.Replace($apimName, $apimName + '-other')} | ConvertTo-Json -Compress)
    )) {
        $changed = Copy-Fixture $apimProbe
        $changed.body=$body
        Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'APIM needs statusCode 403 and explicit denial for the same target'
    }
    $changed = Copy-Fixture $apimProbe
    $changed.hostName=$plan[0].hostName
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'APIM response for another target cannot pass'
    $changed = Copy-Fixture $apimProbe
    $null = $changed.Remove('hostName')
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'PASS' 'Explicit APIM denial recognized without optional target metadata'
    $existing = "$($state.preexistingGroupIds[0])/providers/Example.Service/items/existing"
    $groups = @(@{id=$state.preexistingGroupIds[0]})
    $baseline = @(@{id=$existing})
    $report = Get-ExternalInventoryReport $state $baseline $groups $baseline
    Confirm-Equal (Get-ExternalStatus @($report.checks.status)) 'PASS' 'Unchanged ID inventory'
    Confirm-Equal $report.configurationComparison 'NOT_AVAILABLE' 'Never claim unchanged configuration'
    $report = Get-ExternalInventoryReport $state $baseline $groups @()
    Confirm-Equal (Get-ExternalStatus @($report.checks.status)) 'FAIL' 'Removed baseline resource'
    $report = Get-ExternalInventoryReport $state $baseline $groups ($baseline + @{id="$existing-other"})
    Confirm-Equal (Get-ExternalStatus @($report.checks.status)) 'INCONCLUSIVE' 'Added resource is drift without attribution'
    Confirm-Equal $report.addedResourceIds.Count 1 'Added IDs recorded'
    $report = Get-ExternalInventoryReport $state $baseline $groups ($baseline + @{id=$lab.models})
    Confirm-Equal $report.checks[0].status 'FAIL' 'Lab residual despite absent groups'
    $end = '2026-09-20T11:00:00Z'
    $deployment = @{eventDataId=[guid]::NewGuid().ToString('D'); eventTimestamp='2026-09-20T10:01:00Z'; resourceId="/subscriptions/$($state.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-sample01-activate"; operationName=@{value='Microsoft.Resources/deployments/write'}; status=@{value='Succeeded'}; caller='operator@example.invalid'}
    $outside = @{eventDataId=[guid]::NewGuid().ToString('D'); eventTimestamp='2026-09-20T10:02:00Z'; resourceId=$existing; operationName=@{value='Example.Service/items/write'}; caller='operator@example.invalid'}
    Confirm-Equal (Get-ExternalActivityReport $state @($deployment) $false $end).status 'PASS' 'Exact coordinator event allowed'
    Confirm-Equal (Get-ExternalActivityReport $state @($deployment, $outside) $false $end).status 'FAIL' 'Operator write outside lab fails'
    $changed = Copy-Fixture $outside
    $changed.caller='other@example.invalid'
    Confirm-Equal (Get-ExternalActivityReport $state @($deployment, $changed) $false $end).status 'PASS' 'Another caller is not attributed to operator'
    Confirm-Equal (Get-ExternalActivityReport $state @($changed) $false $end).status 'INCONCLUSIVE' 'Without operator evidence other events cannot fail'
    Confirm-Equal (Get-ExternalActivityReport $state @() $false $end).status 'INCONCLUSIVE' 'Empty log cannot establish operator'
    Confirm-Equal (Get-ExternalActivityReport $state @($deployment) $true $end).status 'INCONCLUSIVE' 'Pagination cannot pass'
    Confirm-Equal (Get-ExternalActivityReport $state (@($deployment) * 5000) $false $end).status 'INCONCLUSIVE' '5000 events may be truncated'
    Initialize-ExternalTransport
    $handler = [LabExternal.Transport]::CreateHandler()
    try {
        Confirm-Equal $handler.UseProxy $false 'Explicit NoProxy'
        Confirm-Equal $handler.AllowAutoRedirect $false 'Zero redirects'
        Confirm-Equal ($null -eq $handler.Credentials) $true 'No credentials'
        Confirm-Equal $handler.PreAuthenticate $false 'No preauthentication'
        Confirm-Equal $handler.UseCookies $false 'No cookies'
        Confirm-Equal ($null -eq $handler.SslOptions.RemoteCertificateValidationCallback) $true 'Normal TLS certificate validation'
    } finally { $handler.Dispose() }
    $request = [LabExternal.Transport]::CreateRequest([uri]$plan[-1].uri, $plan[-1].method, $plan[-1].body)
    try {
        Confirm-Equal $request.Method.Method 'POST' 'Probe uses existing APIM operation'
        Confirm-Equal ($null -eq $request.Headers.Authorization) $true 'No authorization header'
        Confirm-Equal $request.Version.Major 1 'No HTTP version negotiation retry'
    } finally { $request.Dispose() }
    Confirm-Rejected { [LabExternal.Transport]::CreateRequest([uri]'https://user:password@example.invalid/', 'GET', $null) } 'No URI credentials'
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden)
    $response.Content = [Net.Http.StringContent]::new('x' * 65537)
    try {
        $parsed = [LabExternal.Transport]::ReadResponseAsync($response, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        Confirm-Equal $parsed['bodyTruncated'] $true 'Bounded response body'
        Confirm-Equal $parsed['body'].Length 65536 'Body limit enforced'
    } finally { $response.Dispose() }
    $script:callLog = [Collections.Generic.List[object]]::new()
    $script:dns = @('8.8.8.8')
    $script:httpStatus = 403
    $script:foundryUnauthorized = $false
    $script:context = @{id=$state.subscriptionId; tenantId=$state.tenantId; state='Enabled'; environmentName='AzureCloud'}
    $script:groupEnvelope=@{items=$groups}
    $script:resourceEnvelope=@{items=$baseline}
    $script:activityEnvelope=@{items=@($deployment)}
    $script:activitySource=$null
    $boundedRead = ${function:Invoke-ExternalRetainedRead}
    function Invoke-ExternalRetainedRead([hashtable]$State, [string[]]$Arguments, [string]$Label) {
        Invoke-LabAz -State $State -Arguments $Arguments -Label $Label
    }
    $script:baselineFixture=@{path='synthetic-baseline'; sha256='synthetic'; items=$baseline}
    function Read-ExternalOutputs { return $lab }
    function Read-ExternalBaseline {
        if ($null -eq $script:baselineFixture) { throw 'Synthetic missing baseline' }
        return $script:baselineFixture
    }
    function Resolve-ExternalAddresses([string]$HostName, [Threading.CancellationToken]$Cancellation) {
        $script:callLog.Add(@{kind='dns'; hostName=$HostName; canCancel=$Cancellation.CanBeCanceled})
        return ,$script:dns
    }
    function Invoke-ExternalHttp([hashtable]$Endpoint, [string]$Address, [Threading.CancellationToken]$Cancellation) {
        $script:callLog.Add(@{kind='http'; endpoint=$Endpoint; address=$Address; canCancel=$Cancellation.CanBeCanceled})
        $body = switch ($Endpoint.provider) {
            'Foundry' { '{"error":{"code":"403","message":"Access denied due to Virtual Network/Firewall rules."}}' }
            'APIM' { $apimProbe.body }
            'ACR' { $acrProbe.body }
        }
        if ($Endpoint.provider -eq 'Foundry' -and $script:foundryUnauthorized) {
            return @{httpStatus=401; body='{"error":{"code":"401","message":"Caller is not authorized"}}'; connectedAddress=$Address}
        }
        return @{httpStatus=$script:httpStatus; body=$body; connectedAddress=$Address}
    }
    function Invoke-LabAz([hashtable]$State, [string[]]$Arguments, [string]$Label) {
        $script:callLog.Add(@{kind='azure'; arguments=$Arguments; label=$Label; state=$State})
        switch ($Label) {
            'external-context' { return $script:context }
            'external-retained-context' { return $script:context }
            { $_ -in @('external-retained-Foundry', 'external-retained-APIM', 'external-retained-LAW', 'external-retained-RootDeployments') } {
                if ($script:retainedFailureLabel -eq $Label) { throw 'Synthetic unavailable or timed-out read' }
                return $retainedEnvelopes[$Label.Substring('external-retained-'.Length)]
            }
            'external-groups' { return $script:groupEnvelope }
            'external-resources' { return $script:resourceEnvelope }
            { $_ -match '^external-activity-\d{2}$' } {
                if ($script:activitySource) { return (& $script:activitySource $Arguments $Label) }
                return $script:activityEnvelope
            }
            default { throw 'Unexpected command; live Azure is forbidden' }
        }
    }
    $report = Get-ExternalReport $state 'PublicAccess'
    Confirm-Equal $report.status 'PASS' 'Six explicit provider denials pass mocked collection'
    Confirm-Equal @($script:callLog | Where-Object kind -eq 'azure').Count 0 'Public probes use no Azure credentials or reads'
    Confirm-Equal @($script:callLog | Where-Object kind -eq 'dns').Count 6 'Exactly six DNS observations'
    Confirm-Equal @($script:callLog | Where-Object kind -eq 'http').Count 6 'Exactly six HTTPS requests'
    Confirm-Equal @($script:callLog | Where-Object { -not $_.canCancel }).Count 0 'One cancellable deadline reaches DNS and HTTP'
    $summary = ConvertTo-ExternalSummary $report
    $summaryText=$summary | ConvertTo-Json -Depth 30
    foreach ($endpoint in $plan) { Confirm-Equal $summaryText.Contains($endpoint.hostName) $false 'Public summary contains no endpoint hostname' }
    Confirm-Equal $summaryText.Contains('8.8.8.8') $false 'No DNS addresses in public summary'
    foreach ($privateValue in @('203.0.113.10', $apimName, $apimMessage)) { Confirm-Equal $summaryText.Contains($privateValue) $false 'Public summary omits provider response IP and service name' }
    $script:foundryUnauthorized=$true
    $report = Get-ExternalReport $state 'PublicAccess'
    Confirm-Equal $report.status 'INCONCLUSIVE' 'Observed network denials cannot turn Foundry 401 into an overall pass'
    Confirm-Equal @($report.probes | Where-Object { $_.provider -eq 'ACR' -and $_.verdict.status -eq 'PASS' }).Count 2 'Both observed ACR denials pass mocked collection'
    Confirm-Equal @($report.probes | Where-Object { $_.provider -eq 'APIM' -and $_.verdict.status -eq 'PASS' }).Count 1 'Observed APIM denial passes with the exact planned target'
    Confirm-Equal @($report.probes | Where-Object { $_.provider -eq 'Foundry' -and $_.verdict.status -eq 'INCONCLUSIVE' }).Count 3 'All three Foundry 401 responses stay inconclusive'
    $script:foundryUnauthorized=$false
    $script:callLog.Clear()
    $script:dns=@('8.8.8.8', '10.0.0.4')
    Confirm-Equal (Get-ExternalReport $state 'PublicAccess').status 'INCONCLUSIVE' 'Mixed DNS blocks all HTTPS attempts'
    Confirm-Equal @($script:callLog | Where-Object kind -eq 'http').Count 0 'No connection to nonpublic DNS answers'
    $script:dns=@('8.8.8.8')
    $script:httpStatus=401
    Confirm-Equal (Get-ExternalReport $state 'PublicAccess').status 'INCONCLUSIVE' 'End-to-end 401 negative control'
    $script:httpStatus=200
    Confirm-Equal (Get-ExternalReport $state 'PublicAccess').status 'FAIL' 'End-to-end reachable endpoint negative control'
    $script:httpStatus=403
    $destroyedState=Copy-Fixture $state
    $destroyedState.phase='destroyed'
    $fixtureStart=[DateTimeOffset]::UtcNow.AddHours(-1)
    $destroyedState.authorizedAt=$fixtureStart.ToString('o')
    $destroyedState.destroyedAt=$fixtureStart.AddMinutes(30).ToString('o')
    $deployment.eventTimestamp=$fixtureStart.AddMinutes(1).ToString('o')
    $outside.eventTimestamp=$fixtureStart.AddMinutes(2).ToString('o')
    $script:callLog.Clear()
    $report=Get-ExternalReport $destroyedState 'AfterTeardown'
    Confirm-Equal $report.status 'PASS' 'Mocked completed teardown with preserved inventory and attributable log'
    Confirm-Equal $script:callLog.Count 4 'Only four read-only CLI calls'
    Confirm-Equal ($script:callLog[0].arguments -join ' ') 'account show' 'Context is read before inventory'
    Confirm-Equal ($script:callLog[1].arguments -join ' ') 'group list --query {items:@}' 'Read-only group inventory with array envelope'
    Confirm-Equal ($script:callLog[2].arguments -join ' ') 'resource list --resource-group  --query {items:@}' 'Read-only subscription inventory overrides any CLI default group'
    $activityCall=$script:callLog[3].arguments
    Confirm-Equal ($activityCall[0..2] -join ' ') 'monitor activity-log list' 'Read-only activity list'
    Confirm-Equal $activityCall[4] $destroyedState.authorizedAt 'Activity starts at exact authorization timestamp'
    Confirm-Equal $activityCall[8] '5000' 'Explicit activity cap'
    Confirm-Equal $activityCall[9] '--resource-group' 'Override any default activity resource group'
    Confirm-Equal $activityCall[10] '' 'Activity query is subscription-wide'
    $script:context.tenantId=$state.subscriptionId
    $script:callLog.Clear()
    Confirm-Equal (Get-ExternalReport $destroyedState 'AfterTeardown').status 'BLOCKED' 'Different tenant blocks collection'
    Confirm-Equal $script:callLog.Count 1 'Context mismatch stops before inventory'
    $script:context.tenantId=$state.tenantId
    $script:activityEnvelope=@{items=@()}
    Confirm-Equal (Get-ExternalReport $destroyedState 'AfterTeardown').status 'INCONCLUSIVE' 'Missing caller cannot prove noninterference'
    $script:activityEnvelope=@{items=@($deployment); nextLink='https://example.invalid/next'}
    Confirm-Equal (Get-ExternalReport $destroyedState 'AfterTeardown').status 'INCONCLUSIVE' 'Truncated activity never passes collector'
    $script:activityEnvelope=@{items=@($deployment, $outside)}
    $report=Get-ExternalReport $destroyedState 'AfterTeardown'
    Confirm-Equal $report.status 'FAIL' 'Attributable out-of-scope write fails full collector'
    $summaryText=(ConvertTo-ExternalSummary $report) | ConvertTo-Json -Depth 30
    foreach ($privateValue in @($state.subscriptionId, $state.tenantId, $state.ownershipId, $existing, 'operator@example.invalid', 'synthetic-baseline')) { Confirm-Equal $summaryText.Contains($privateValue) $false 'Teardown summary omits private identifiers' }
    $script:activityEnvelope=@{items=@($deployment)}
    $script:resourceEnvelope=@{items=($baseline + @{id=$lab.models})}
    $script:baselineFixture=$null
    $report=Get-ExternalReport $destroyedState 'AfterTeardown'
    Confirm-Equal $report.status 'FAIL' 'A missing baseline cannot hide a known residual'
    Confirm-Equal @($report.checks | Where-Object { $_.test -eq 'INVENTORY-EVIDENCE' -and $_.status -eq 'INCONCLUSIVE' }).Count 1 'Missing baseline is explicitly inconclusive'
    $script:resourceEnvelope=@{items=$baseline}
    Confirm-Equal (Get-ExternalReport $destroyedState 'AfterTeardown').status 'INCONCLUSIVE' 'Absent baseline never claims preservation'
    $script:baselineFixture=@{path='synthetic-baseline'; sha256='synthetic'; items=$baseline}
    $script:resourceEnvelope=@{items=$baseline; nextLink='https://example.invalid/next'}
    Confirm-Equal (Get-ExternalReport $destroyedState 'AfterTeardown').status 'INCONCLUSIVE' 'Truncated inventory cannot pass'
    $script:resourceEnvelope=@{items=$baseline}
    foreach ($operation in @('delete', 'listKeys/action')) {
        $changed=Copy-Fixture $outside
        $changed.operationName.value="Example.Service/items/$operation"
        Confirm-Equal (Get-ExternalActivityReport $destroyedState @($deployment, $changed) $false ([DateTimeOffset]::UtcNow.ToString('o'))).status 'FAIL' 'Attributable deletes and actions are detected'
    }
    $ambiguous=Copy-Fixture $deployment
    $ambiguous.caller='other@example.invalid'
    Confirm-Equal (Get-ExternalActivityReport $destroyedState @($deployment, $ambiguous, $outside) $false ([DateTimeOffset]::UtcNow.ToString('o'))).status 'INCONCLUSIVE' 'Multiple deployment callers make attribution inconclusive'
    $changed=Copy-Fixture $outside
    $null=$changed.Remove('caller')
    Confirm-Equal (Get-ExternalActivityReport $destroyedState @($deployment, $changed) $false ([DateTimeOffset]::UtcNow.ToString('o'))).status 'INCONCLUSIVE' 'Missing caller is not a violation proof'
    $changed=Copy-Fixture $outside
    $changed.resourceId="$prefix-models-other/providers/Example.Service/items/other"
    Confirm-Equal (Get-ExternalActivityReport $destroyedState @($deployment, $changed) $false ([DateTimeOffset]::UtcNow.ToString('o'))).status 'FAIL' 'Similar group prefix is not owned'
    $changed.resourceId=$lab.models
    Confirm-Equal (Get-ExternalActivityReport $destroyedState @($deployment, $changed) $false ([DateTimeOffset]::UtcNow.ToString('o'))).status 'PASS' 'Exact owned group event excluded'
    $changed=Copy-Fixture $outside
    $changed.operationName=@{localizedValue='Localized write'}
    Confirm-Equal (Get-ExternalActivityReport $destroyedState @($deployment, $changed) $false ([DateTimeOffset]::UtcNow.ToString('o'))).status 'INCONCLUSIVE' 'Unknown canonical operation cannot pass'
    $oldState=Copy-Fixture $destroyedState
    $oldState.authorizedAt=$fixtureStart.AddDays(-91).ToString('o')
    Confirm-Equal (Get-ExternalActivityReport $oldState @($deployment) $false ([DateTimeOffset]::UtcNow.ToString('o'))).status 'INCONCLUSIVE' 'Activity retention gap cannot pass'
    $report=Get-ExternalInventoryReport $state $baseline @() $baseline
    Confirm-Equal $report.checks[1].status 'FAIL' 'Pre-existing group disappearance detected'
    $report=Get-ExternalInventoryReport $state $baseline ($groups + @{id="$prefix-models"}) $baseline
    Confirm-Equal $report.checks[0].status 'FAIL' 'Any one of the exact four remaining groups fails absence'
    $report=Get-ExternalInventoryReport $state ($baseline + @{id=$lab.models}) $groups $baseline
    Confirm-Equal $report.checks[2].status 'PASS' 'Lab IDs excluded from baseline comparison'
    $report=Get-ExternalInventoryReport $state $baseline $groups ($baseline + @{id="$existing-extra"; tags=@{'fgl-owner'=$state.ownershipId}})
    Confirm-Equal $report.checks[0].status 'FAIL' 'Tagged lab resource outside owned groups is still a residual'
    $subscriptionResource=@{id="/subscriptions/$($state.subscriptionId)/providers/Example.Service/items/subscription-scoped"}
    $report=Get-ExternalInventoryReport $state @($subscriptionResource) $groups @($subscriptionResource)
    Confirm-Equal $report.checks[2].status 'PASS' 'Subscription-scoped baseline resource retained'
    Confirm-Rejected { Get-ExternalInventoryReport $state ($baseline + $baseline) $groups $baseline } 'Duplicate baseline IDs cannot pass'
    Confirm-Rejected { Get-ExternalList @{items=@{}; nextLink=$null} } 'Malformed list cannot be treated as empty'
    Confirm-Equal @(Get-ExternalList @{items=@()}).Count 1 'Empty list is returned as one array object'
    foreach ($badField in @('bodyTruncated', 'dnsError', 'transportError')) {
        $changed=Copy-Fixture $probe
        $changed[$badField]=$true
        Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'Incomplete probe cannot pass'
    }
    $changed=Copy-Fixture $probe
    $changed.localAddress='10.76.4.4'
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'A known lab VNet source cannot count as external'
    $changed=Copy-Fixture $probe
    $changed.addresses=@()
    Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'No empty DNS pass'
    foreach ($body in @('Forbidden', '{"error":{"code":"CallerNotAllowed","message":"Access denied due to Virtual Network/Firewall rules."}}', '{"error":{"code":"403","message":"Invalid API key; check firewall settings"}}')) {
        $changed=Copy-Fixture $probe
        $changed.body=$body
        Confirm-Equal (Get-ExternalProbeVerdict $changed).status 'INCONCLUSIVE' 'Arbitrary 403 and firewall hints are not provider network denial'
    }
    $script:dns=@()
    $script:callLog.Clear()
    Confirm-Equal (Get-ExternalReport $state 'PublicAccess').status 'INCONCLUSIVE' 'Empty DNS report is inconclusive'
    Confirm-Equal @($script:callLog | Where-Object kind -eq 'http').Count 0 'Empty DNS sends zero requests'
    $script:dns=@('8.8.8.8')
    $badState=Copy-Fixture $state
    $badState.phase='lock'
    $script:callLog.Clear()
    Confirm-Equal (Get-ExternalReport $badState 'PublicAccess').status 'BLOCKED' 'Pre-activation public test blocked'
    Confirm-Equal $script:callLog.Count 0 'No network calls before lifecycle checks'
    $report=Get-ExternalReport $state 'PublicAccess'
    $report.errors=@('host.example.invalid/secret', $state.subscriptionId)
    $report.probes[0].body='private provider response'
    $report.probes[0].headers=@{'Set-Cookie'='private cookie'}
    $summaryText=(ConvertTo-ExternalSummary $report) | ConvertTo-Json -Depth 30
    foreach ($privateValue in @('host.example.invalid', 'private provider response', 'private cookie', $state.subscriptionId)) { Confirm-Equal $summaryText.Contains($privateValue) $false 'Whitelisted summary excludes raw errors, bodies and headers' }
    $collectionEnd=$fixtureStart.AddHours(1).ToString('o')
    $script:activityFixture=@($deployment) + @(0..5999 | ForEach-Object {
        @{eventDataId=[guid]::NewGuid().ToString('D'); eventTimestamp=$fixtureStart.AddTicks([long]($_ * [TimeSpan]::TicksPerMinute / 100)).ToString('o'); resourceId=$existing; operationName=@{value='Example.Service/items/read'}}
    })
    $partitionSource={
        param($Arguments, $Label)
        $lower=[DateTimeOffset]::Parse($Arguments[4])
        $upper=[DateTimeOffset]::Parse($Arguments[6])
        return @{items=@($script:activityFixture | Where-Object { [DateTimeOffset]::Parse($_.eventTimestamp) -ge $lower -and [DateTimeOffset]::Parse($_.eventTimestamp) -le $upper } | Select-Object -First 5000)}
    }
    $script:activitySource=$partitionSource
    $script:callLog.Clear()
    $collection=Get-ExternalActivityCollection $destroyedState $collectionEnd
    Confirm-Equal $collection.complete $true 'Partitioned collection verifies all terminal windows'
    Confirm-Equal $collection.truncated $false 'Saturated parent is resolved by complete children'
    Confirm-Equal $collection.calls 3 'Whole interval followed by exactly two halves'
    Confirm-Equal $collection.windowCount 3 'Private windows include the parent read'
    Confirm-Equal $collection.completeWindowCount 2 'Only terminal unsaturated windows count as complete'
    Confirm-Equal $collection.pendingWindowCount 0 'No unqueried interval remains'
    Confirm-Equal $collection.eventCount 6001 'Unique event IDs merged across parent and children'
    Confirm-Equal $collection.sourceEventCount 11002 'Source count includes parent and duplicated boundary event'
    Confirm-Equal $collection.duplicateEventCount 5001 'Parent overlap plus inclusive midpoint deduplicated'
    Confirm-Equal $collection.uncoveredEventCount 0 'Every parent event is also present in complete leaves'
    Confirm-Equal $collection.windows[0].raw.items.Count 5000 'Raw saturated parent is retained privately'
    Confirm-Equal $collection.windows[1].raw.items.Count 3002 'Raw first child retained with original cardinality'
    Confirm-Equal $collection.windows[2].raw.items.Count 3000 'Raw second child retains the boundary duplicate'
    Confirm-Equal $collection.windows[0].startTime $destroyedState.authorizedAt 'Exact authorization timestamp preserved'
    Confirm-Equal $collection.windows[0].endTime $collectionEnd 'One fixed end timestamp for the collection'
    Confirm-Equal $collection.windows[1].endTime $collection.windows[2].startTime 'Inclusive halves have no temporal gap'
    Confirm-Equal $collection.windows[1].startTime $collection.windows[0].startTime 'First half starts at parent start'
    Confirm-Equal $collection.windows[2].endTime $collection.windows[0].endTime 'Second half ends at parent end'
    foreach ($call in $script:callLog) {
        Confirm-Equal ($call.arguments[0..2] -join ' ') 'monitor activity-log list' 'Partitions remain read-only activity queries'
        Confirm-Equal $call.arguments[8] '5000' 'Every read keeps the 5000-event cap'
        Confirm-Equal $call.arguments[10] '' 'Partitions override any default resource group'
        Confirm-Equal $call.arguments[12] '{items:@}' 'No event fields are filtered out'
        Confirm-Equal ([object]::ReferenceEquals($call.state, $destroyedState)) $true 'Partitions preserve the explicit state context'
    }
    Confirm-Equal (Get-ExternalActivityReport $destroyedState $collection.events $false $collectionEnd).status 'INCONCLUSIVE' 'Large batches require explicit verification opt-in'
    Confirm-Equal (Get-ExternalActivityReport $destroyedState $collection.events $false $collectionEnd -VerifiedCollectionComplete $true).status 'PASS' 'Verified large batch can pass attribution'
    Confirm-Equal (Get-ExternalActivityReport $destroyedState $collection.events $true $collectionEnd -VerifiedCollectionComplete $true).status 'INCONCLUSIVE' 'Opt-in never overrides explicit truncation'
    $malformed=Copy-Fixture $deployment
    $null=$malformed.Remove('operationName')
    Confirm-Equal (Get-ExternalActivityReport $destroyedState @($malformed) $false $collectionEnd -VerifiedCollectionComplete $true).status 'INCONCLUSIVE' 'Opt-in never overrides malformed event content'
    $report=Get-ExternalReport $destroyedState 'AfterTeardown'
    Confirm-Equal $report.status 'PASS' 'Full collector can pass more than 5000 unique events'
    $summary=ConvertTo-ExternalSummary $report
    Confirm-Equal $summary.activity.eventCount 6001 'Public unique count matches the classified batch'
    Confirm-Equal $summary.activity.complete $true 'Public activity completeness comes from verified collection'
    Confirm-Equal $summary.activity.truncated $false 'Merged size alone does not imply truncation'
    Confirm-Equal $summary.activityCollection.calls 3 'Public summary states actual read count'
    Confirm-Equal $summary.activityCollection.windowCount 3 'Public summary states queried window count'
    Confirm-Equal $summary.activityCollection.completeWindowCount 2 'Public summary distinguishes terminal windows'
    Confirm-Equal $summary.activityCollection.eventCount 6001 'Public collection count is unique events'
    Confirm-Equal $summary.activityCollection.callBudget 32 'Public summary states finite call budget'
    Confirm-Equal $summary.activityCollection.timeoutSecondsPerRead 60 'Public summary states per-read deadline'
    Confirm-Equal $summary.activityCollection.maximumSourceEvents 100000 'Source budget includes all raw reads'
    $summaryText=$summary | ConvertTo-Json -Depth 30
    foreach ($privateValue in @($deployment.eventDataId, $existing, $state.subscriptionId, $destroyedState.authorizedAt, 'operator@example.invalid', 'eventTimestamp', 'startTime', 'rawActivity')) {
        Confirm-Equal $summaryText.Contains($privateValue) $false 'Activity summary omits raw events, timestamps and private identifiers'
    }
    $script:activitySource=$null
    foreach ($mutation in @('missing-id', 'null-id', 'invalid-id', 'empty-guid', 'array-id', 'id-fallback', 'missing-time', 'invalid-time', 'no-timezone', 'before-start', 'after-end', 'wrong-subscription')) {
        $changed=Copy-Fixture $deployment
        switch ($mutation) {
            'missing-id' { $null=$changed.Remove('eventDataId') }
            'null-id' { $changed.eventDataId=$null }
            'invalid-id' { $changed.eventDataId='not-an-event-guid' }
            'empty-guid' { $changed.eventDataId=[guid]::Empty.ToString('D') }
            'array-id' { $changed.eventDataId=@($deployment.eventDataId) }
            'id-fallback' { $changed.id="$($changed.resourceId)/events/$($changed.eventDataId)/ticks/1"; $null=$changed.Remove('eventDataId') }
            'missing-time' { $null=$changed.Remove('eventTimestamp') }
            'invalid-time' { $changed.eventTimestamp='not-a-timestamp' }
            'no-timezone' { $changed.eventTimestamp=$fixtureStart.ToString('yyyy-MM-ddTHH:mm:ss') }
            'before-start' { $changed.eventTimestamp=$fixtureStart.AddTicks(-1).ToString('o') }
            'after-end' { $changed.eventTimestamp=[DateTimeOffset]::UtcNow.AddDays(1).ToString('o') }
            'wrong-subscription' { $changed.subscriptionId=$state.tenantId }
        }
        $script:activityEnvelope=@{items=@($deployment, $changed)}
        $report=Get-ExternalReport $destroyedState 'AfterTeardown'
        Confirm-Equal $report.status 'INCONCLUSIVE' "Malformed activity cannot pass: $mutation"
        Confirm-Equal $report.activity.complete $false 'Valid operator evidence cannot hide invalid collection records'
        Confirm-Equal $report.rawActivity.invalidEventCount 1 'Invalid record is counted without inventing identity'
        Confirm-Equal $report.rawActivity.windows[0].raw.items.Count 2 'Invalid evidence retained in the private raw response'
    }
    $reordered=[ordered]@{}
    foreach ($key in @($deployment.Keys | Sort-Object -Descending)) { $reordered[$key]=$deployment[$key] }
    $reordered.eventDataId=$deployment.eventDataId.ToUpperInvariant()
    $script:activityEnvelope=@{items=@($deployment, ($reordered | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100))}
    $collection=Get-ExternalActivityCollection $destroyedState $collectionEnd
    Confirm-Equal $collection.complete $true 'Identical JSON values deduplicate regardless of key order or GUID case'
    Confirm-Equal $collection.eventCount 1 'Identical duplicate counted once'
    Confirm-Equal $collection.duplicateEventCount 1 'Duplicate source record remains accounted for'
    foreach ($mutation in @('caller', 'operation', 'nested-property')) {
        $changed=Copy-Fixture $deployment
        switch ($mutation) {
            'caller' { $changed.caller='other@example.invalid' }
            'operation' { $changed.operationName.value='Example.Service/items/delete' }
            'nested-property' { $changed.properties=@{details=@{values=@(1, 2, 3)}} }
        }
        $script:activityEnvelope=@{items=@($deployment, $changed)}
        $report=Get-ExternalReport $destroyedState 'AfterTeardown'
        Confirm-Equal $report.status 'INCONCLUSIVE' 'Same event GUID with conflicting content cannot pass'
        Confirm-Equal $report.rawActivity.conflictCount 1 'Conflicting duplicate explicitly counted'
        Confirm-Equal $report.activity.complete $false 'Conflicting duplicate invalidates completeness'
    }
    foreach ($field in @('nextLink', 'continuationToken', 'skipToken')) {
        foreach ($nested in @($false, $true)) {
            $script:activityEnvelope=@{items=@($deployment)}
            if ($nested) { $script:activityEnvelope.items=@{value=@($deployment)}; $script:activityEnvelope.items[$field]='synthetic-next-page' }
            else { $script:activityEnvelope[$field]='synthetic-next-page' }
            $report=Get-ExternalReport $destroyedState 'AfterTeardown'
            Confirm-Equal $report.status 'INCONCLUSIVE' 'Outer or inner continuation always prevents a pass'
            Confirm-Equal $report.rawActivity.calls 1 'No continuation requests or retries are issued'
            Confirm-Equal $report.rawActivity.truncated $true 'Continuation is explicit truncation evidence'
        }
    }
    $script:activityEnvelope=@{items=@{value=@($deployment); nextLink=$null; continuationToken=$null; skipToken=$null}}
    Confirm-Equal (Get-ExternalReport $destroyedState 'AfterTeardown').status 'PASS' 'Complete nested event array remains supported'
    foreach ($envelope in @(@{}, @{items=$null}, @{items=@{}}, @{items=$deployment}, @{items=@{value=$deployment}}, @{items=@($null)}, @{items=(@($deployment) * 5001)})) {
        $script:activityEnvelope=$envelope
        Confirm-Equal (Get-ExternalReport $destroyedState 'AfterTeardown').status 'INCONCLUSIVE' 'Malformed shape or over-limit response cannot pass'
    }
    $script:activitySource={ param($Arguments, $Label) throw 'Synthetic failed or timed-out activity read' }
    $report=Get-ExternalReport $destroyedState 'AfterTeardown'
    Confirm-Equal $report.status 'INCONCLUSIVE' 'Failed activity read cannot become an empty successful batch'
    Confirm-Equal $report.rawActivity.calls 1 'Failed read is counted and never retried'
    Confirm-Equal $report.rawActivity.complete $false 'Read failure never claims collection completeness'
    Confirm-Equal ([bool]$report.rawActivity.windows[0].error) $true 'Read failure retained in private window evidence'
    $script:activitySource={
        param($Arguments, $Label)
        if ($Label -eq 'external-activity-01') { return @{items=(@($deployment) * 5000)} }
        return @{items=@()}
    }
    $report=Get-ExternalReport $destroyedState 'AfterTeardown'
    Confirm-Equal $report.status 'INCONCLUSIVE' 'Parent observations missing from all complete children cannot pass'
    Confirm-Equal $report.rawActivity.uncoveredEventCount 1 'Disappeared parent event explicitly counted'
    Confirm-Equal $report.rawActivity.calls 3 'Parent consistency checked after reading both children'
    $script:activitySource={
        param($Arguments, $Label)
        if ($Label -eq 'external-activity-01') { return @{items=(@($deployment) * 5000)} }
        return @{items=@($deployment)}
    }
    $collection=Get-ExternalActivityCollection $destroyedState $collectionEnd
    Confirm-Equal $collection.complete $false 'Event in wrong child interval invalidates the partition'
    Confirm-Equal $collection.invalidEventCount 1 'Child bounds checked even when event is inside the whole interval'
    $script:activitySource=$null
    $script:activityEnvelope=@{items=@()}
    $collection=Get-ExternalActivityCollection $destroyedState $destroyedState.authorizedAt
    Confirm-Equal $collection.calls 1 'Zero-width interval still executes one read'
    Confirm-Equal $collection.complete $true 'Empty zero-width interval is complete collection but supplies no operator'
    Confirm-Equal (Get-ExternalActivityReport $destroyedState $collection.events $false $destroyedState.authorizedAt -VerifiedCollectionComplete $collection.complete).status 'INCONCLUSIVE' 'Complete empty interval cannot prove attribution'
    $instant=Copy-Fixture $deployment
    $instant.eventTimestamp=$destroyedState.authorizedAt
    $script:activityEnvelope=@{items=(@($instant) * 5000)}
    $collection=Get-ExternalActivityCollection $destroyedState $destroyedState.authorizedAt
    Confirm-Equal $collection.calls 1 'Unsplittable saturated interval stops immediately'
    Confirm-Equal $collection.complete $false 'Deduplication never hides a saturated source count'
    Confirm-Equal $collection.truncated $true 'Unsplittable interval remains truncated'
    $script:callLog.Clear()
    Confirm-Rejected { Get-ExternalActivityCollection $destroyedState $fixtureStart.AddTicks(-1).ToString('o') } 'Reversed collection interval rejected'
    Confirm-Rejected { Get-ExternalActivityCollection $destroyedState ([DateTimeOffset]::UtcNow.AddDays(1).ToString('o')) } 'Future collection endpoint rejected'
    Confirm-Equal $script:callLog.Count 0 'Invalid intervals execute no reads'
    $script:activitySource={
        param($Arguments, $Label)
        $number=[int]($Label -split '-')[-1]
        if ($number % 2 -eq 0) { return @{items=@()} }
        $entry=Copy-Fixture $deployment
        $entry.eventDataId=[guid]::NewGuid().ToString('D')
        $entry.eventTimestamp=$Arguments[4]
        return @{items=(@($entry) * 5000)}
    }
    $collection=Get-ExternalActivityCollection $destroyedState $collectionEnd
    Confirm-Equal $collection.calls 32 'Adaptive reads never exceed 32 calls'
    Confirm-Equal $collection.budgetReason 'CALL_BUDGET' 'Call exhaustion distinguished from event exhaustion'
    Confirm-Equal $collection.sourceEventCount 80000 'Raw parent counts are not lost through deduplication'
    Confirm-Equal $collection.complete $false 'Pending window at call budget cannot pass'
    Confirm-Equal $collection.truncated $true 'Call budget leaves explicitly truncated coverage'
    Confirm-Equal ($collection.pendingWindowCount -gt 0) $true 'Unqueried windows remain visible'
    $script:activitySource={ param($Arguments, $Label) return @{items=(@($instant) * 5000)} }
    $collection=Get-ExternalActivityCollection $destroyedState $collectionEnd
    Confirm-Equal $collection.calls 20 'All-saturated fixture stops at source event budget before call budget'
    Confirm-Equal $collection.sourceEventCount 100000 'No more than 100000 requested source events'
    Confirm-Equal $collection.budgetReason 'EVENT_BUDGET' 'Source event exhaustion is explicit'
    Confirm-Equal $collection.complete $false 'Unresolved saturated windows cannot pass at event budget'
    Confirm-Equal $collection.truncated $true 'Event budget truncation remains visible'
    $script:activitySource=$null
    $script:activityEnvelope=@{items=@($deployment)}
    $retainedState = Copy-Fixture $destroyedState
    $retainedState.teardownEvidence=@{path='synthetic-original-evidence'; sha256=('A' * 64)}
    $snapshotGroups = @($state.resourceGroups | ForEach-Object { @{id="/subscriptions/$($state.subscriptionId)/resourceGroups/$_"; name=$_; tags=@{'fgl-owner'=$state.ownershipId; 'fgl-lab'=$state.labId}} })
    $snapshotResources = @($plan | Where-Object provider -in @('Foundry', 'APIM') | ForEach-Object { @{id=$_.id; type=($_.id -split '/providers/')[1].Substring(0, ($_.id -split '/providers/')[1].LastIndexOf('/'))} })
    $workspaceIds = @('models', 'case-a', 'case-b' | ForEach-Object { "$prefix-$_/providers/Microsoft.OperationalInsights/workspaces/law-fgl-sample01-$_" })
    $snapshotResources += @($workspaceIds | ForEach-Object { @{id=$_; type='Microsoft.OperationalInsights/workspaces'} })
    $snapshotResources += @(1..63 | ForEach-Object { @{id="$prefix-integration/providers/Example.Service/items/captured-$_"; type='Example.Service/items'} })
    $evidence = @{path=$retainedState.teardownEvidence.path; sha256=$retainedState.teardownEvidence.sha256; snapshot=@{groups=$snapshotGroups; resources=$snapshotResources}}
    $retainedPlan = Get-ExternalRetainedPlan $retainedState $lab $evidence
    Confirm-Equal $snapshotResources.Count 70 'Original synthetic snapshot contains 70 resources'
    Confirm-Equal $retainedState.phase 'destroyed' 'Output validation never changes destroyed state'
    Confirm-Equal (($retainedPlan | ForEach-Object { $_.count }) -join ',') '3,1,3,3' 'Only three Foundry, one APIM, three LAW and three root targets'
    $retainedEnvelopes = @{}
    foreach ($target in $retainedPlan) {
        $items = @($target.targetIds | ForEach-Object {
            if ($target.key -eq 'APIM') { @{id="/subscriptions/$($state.subscriptionId)/providers/Microsoft.ApiManagement/locations/westus/deletedservices/synthetic"; properties=@{serviceId=$_}} }
            else { @{id=$_; name=($_ -split '/')[-1]} }
        })
        $retainedEnvelopes[$target.key]=@{items=$items}
        $observed = Get-ExternalRetainedListReport $retainedState $target $retainedEnvelopes[$target.key]
        Confirm-Equal $observed.status 'PASS' 'Documented original ID shape recognized'
        Confirm-Equal $observed.matchedIds.Count $target.count 'Owned count matches exact original IDs'
        $observed = Get-ExternalRetainedListReport $retainedState $target @{items=@()}
        Confirm-Equal $observed.status 'PASS' 'Missing records are not a retention promise failure'
        Confirm-Equal $observed.matchedIds.Count 0 'Empty list counts zero owned records'
        foreach ($field in @('nextLink', 'continuationToken', 'skipToken')) {
            $changed = Copy-Fixture $retainedEnvelopes[$target.key]
            $changed[$field]='synthetic-next-page'
            Confirm-Equal (Get-ExternalRetainedListReport $retainedState $target $changed).status 'INCONCLUSIVE' 'Incomplete pagination cannot establish retained list completeness'
        }
        foreach ($invalidItems in @(@{items=@{value=$items; nextLink='synthetic-next-page'}}, @{items=@{}}, @{items=@(@{name='unknown'})}, @{items=@($null)}, @{items=($items + $items)})) {
            Confirm-Equal (Get-ExternalRetainedListReport $retainedState $target $invalidItems).status 'INCONCLUSIVE' 'Unknown, wrapped, null and duplicate records cannot pass'
        }
        $wrongScope = Copy-Fixture $retainedEnvelopes[$target.key]
        foreach ($item in $wrongScope.items) {
            if ($target.key -eq 'APIM') { $item.properties.serviceId=$item.properties.serviceId.Replace($state.subscriptionId, $state.tenantId) }
            else { $item.id=$item.id.Replace($state.subscriptionId, $state.tenantId) }
        }
        $observed=Get-ExternalRetainedListReport $retainedState $target $wrongScope
        Confirm-Equal $observed.status 'INCONCLUSIVE' 'Wrong subscription response is incomplete evidence'
        Confirm-Equal $observed.matchedIds.Count 0 'Wrong subscription records never counted'
        $uncaptured = Copy-Fixture $retainedEnvelopes[$target.key]
        foreach ($item in $uncaptured.items) {
            if ($target.key -eq 'APIM') { $item.properties.serviceId += '-uncaptured' }
            else { $item.id += '-uncaptured'; $item.name += '-uncaptured' }
        }
        $observed=Get-ExternalRetainedListReport $retainedState $target $uncaptured
        Confirm-Equal $observed.matchedIds.Count 0 'Uncaptured resources and similarly prefixed deployments never counted'
        Confirm-Equal $observed.status $(if ($target.key -eq 'RootDeployments') { 'INCONCLUSIVE' } else { 'PASS' }) 'Service lists may contain other resources but filtered root lists may not'
        if ($target.key -ne 'RootDeployments') {
            $wrongGroup=Copy-Fixture $retainedEnvelopes[$target.key]
            foreach ($item in $wrongGroup.items) {
                if ($target.key -eq 'APIM') { $item.properties.serviceId=$item.properties.serviceId -replace '/resourceGroups/[^/]+/', '/resourceGroups/another-group/' }
                else { $item.id=$item.id -replace '/resourceGroups/[^/]+/', '/resourceGroups/another-group/' }
            }
            Confirm-Equal (Get-ExternalRetainedListReport $retainedState $target $wrongGroup).matchedIds.Count 0 'Same resource names in another group never establish ownership'
            $deletedPath=Copy-Fixture $retainedEnvelopes[$target.key]
            foreach ($item in $deletedPath.items) {
                $item.id="/subscriptions/$($state.subscriptionId)/providers/$($target.type.Split('/')[0])/locations/westus/deletedAccounts/unknown"
                $null=$item.Remove('properties')
            }
            $observed=Get-ExternalRetainedListReport $retainedState $target $deletedPath
            Confirm-Equal $observed.status 'INCONCLUSIVE' 'Deleted-record path is not an original ARM ID'
            Confirm-Equal $observed.matchedIds.Count 0 'Never reconstruct original provenance from a deleted-record name'
        }
        $overBudget=@{items=(@(@{id=$target.targetIds[0]}) * 10001)}
        Confirm-Equal (Get-ExternalRetainedListReport $retainedState $target $overBudget).reason 'RECORD_BUDGET' 'Record classification budget is enforced'
    }
    $apimTarget=$retainedPlan | Where-Object key -eq 'APIM'
    $flatApim=Copy-Fixture $retainedEnvelopes.APIM
    $flatApim.items[0].serviceId=$flatApim.items[0].properties.serviceId
    $null=$flatApim.items[0].Remove('properties')
    $flatApim.items[0].name=$apimName
    $flatApim.items[0].location='westus'
    $flatApim.items[0].type='Microsoft.ApiManagement/deletedservices'
    $flatApim.items[0].deletionDate='2026-09-20T10:30:00Z'
    $flatApim.items[0].scheduledPurgeDate='2026-09-23T10:30:00Z'
    $flatApim.items[0].id="/subscriptions/$($state.subscriptionId)/providers/Microsoft.ApiManagement/locations/westus/deletedservices/$apimName"
    Confirm-Equal (($flatApim.items[0].Keys | Sort-Object) -join ',') 'deletionDate,id,location,name,scheduledPurgeDate,serviceId,type' 'Synthetic APIM CLI fixture has the observed flattened keys'
    foreach ($shape in @('flat', 'nested', 'both', 'both-case-insensitive')) {
        $changed=Copy-Fixture $flatApim
        if ($shape -ne 'flat') { $changed.items[0].properties=@{serviceId=$lab.gateway} }
        if ($shape -eq 'nested') { $null=$changed.items[0].Remove('serviceId') }
        if ($shape -eq 'both-case-insensitive') { $changed.items[0].properties.serviceId=$lab.gateway.ToUpperInvariant() }
        $observed=Get-ExternalRetainedListReport $retainedState $apimTarget $changed
        Confirm-Equal $observed.status 'PASS' 'APIM supports flattened CLI and nested REST serviceId without conflicts'
        Confirm-Equal $observed.matchedIds[0] $lab.gateway 'APIM serviceId maps only the exact captured original ID'
    }
    foreach ($invalidId in @($null, '', 1, @($lab.gateway), ($lab.gateway + '-other'), ($lab.gateway.Replace($state.subscriptionId, $state.tenantId)))) {
        foreach ($field in @('flat', 'nested')) {
            $changed=Copy-Fixture $flatApim
            $changed.items[0].properties=@{serviceId=$lab.gateway}
            if ($field -eq 'flat') { $changed.items[0].serviceId=$invalidId } else { $changed.items[0].properties.serviceId=$invalidId }
            $observed=Get-ExternalRetainedListReport $retainedState $apimTarget $changed
            Confirm-Equal $observed.status 'INCONCLUSIVE' 'Conflicting or malformed APIM original ID fields cannot pass'
            Confirm-Equal $observed.matchedIds.Count 0 'No fallback to the other APIM original ID on conflict'
        }
    }
    foreach ($invalidProperties in @('invalid', @(@{serviceId=$lab.gateway}))) {
        $changed=Copy-Fixture $flatApim
        $changed.items[0].properties=$invalidProperties
        Confirm-Equal (Get-ExternalRetainedListReport $retainedState $apimTarget $changed).status 'INCONCLUSIVE' 'Malformed APIM properties cannot hide conflicting provenance'
    }
    $observed=Get-ExternalRetainedListReport $retainedState $apimTarget @{items=@($flatApim.items[0], $retainedEnvelopes.APIM.items[0])}
    Confirm-Equal $observed.status 'INCONCLUSIVE' 'Flat and nested APIM aliases are duplicate original records'
    Confirm-Equal $observed.matchedIds.Count 1 'APIM aliases do not double count ownership'
    $foundryTarget=$retainedPlan | Where-Object key -eq 'Foundry'
    $deletedFoundry=Copy-Fixture $retainedEnvelopes.Foundry
    foreach ($item in $deletedFoundry.items) {
        $originalParts=$item.id -split '/'
        $item.id="/subscriptions/$($originalParts[2])/providers/Microsoft.CognitiveServices/locations/swedencentral/resourceGroups/$($originalParts[4])/deletedAccounts/$($originalParts[-1])"
        $item.location='swedencentral'
    }
    Confirm-Equal $retainedState.ContainsKey('location') $false 'Deleted account mapping does not need a state region'
    $observed=Get-ExternalRetainedListReport $retainedState $foundryTarget $deletedFoundry
    Confirm-Equal $observed.status 'PASS' 'Complete documented deleted account path recognized'
    Confirm-Equal ($observed.matchedIds -join ',') ($foundryTarget.targetIds -join ',') 'Deleted account scope and name reconstruct exact snapshot IDs'
    foreach ($region in @('westus', 'swedencentral')) {
        $changed=Copy-Fixture $deletedFoundry
        foreach ($item in $changed.items) { $item.id=$item.id.Replace('/locations/swedencentral/', "/locations/$region/"); $null=$item.Remove('location') }
        Confirm-Equal (Get-ExternalRetainedListReport $retainedState $foundryTarget $changed).status 'PASS' 'Complete path has its own nonempty region when location metadata is absent'
    }
    $changed=Copy-Fixture $deletedFoundry
    foreach ($item in $changed.items) { $item.location='SwedenCentral' }
    Confirm-Equal (Get-ExternalRetainedListReport $retainedState $foundryTarget $changed).status 'PASS' 'Location comparison is case insensitive'
    foreach ($mutation in @('missing-name', 'null-name', 'wrong-name', 'qualified-name', 'full-id-name', 'wrong-region', 'empty-region', 'null-region', 'array-region', 'missing-path-region', 'wrong-subscription', 'missing-group', 'wrong-provider', 'extra-segment', 'trailing-newline', 'encoded-region', 'traversal-region', 'backslash-region', 'query-region', 'fragment-region')) {
        $changed=@{items=@((Copy-Fixture $deletedFoundry.items[0]))}
        $item=$changed.items[0]
        switch ($mutation) {
            'missing-name' { $null=$item.Remove('name') }
            'null-name' { $item.name=$null }
            'wrong-name' { $item.name += '-other' }
            'qualified-name' { $item.name="swedencentral/$($item.name)" }
            'full-id-name' { $item.name=$item.id }
            'wrong-region' { $item.location='westus' }
            'empty-region' { $item.location='' }
            'null-region' { $item.location=$null }
            'array-region' { $item.location=@('swedencentral') }
            'missing-path-region' { $item.id=$item.id.Replace('/locations/swedencentral/', '/locations//'); $null=$item.Remove('location') }
            'wrong-subscription' { $item.id=$item.id.Replace($state.subscriptionId, $state.tenantId) }
            'missing-group' { $item.id=$item.id -replace '/resourceGroups/[^/]+/', '/' }
            'wrong-provider' { $item.id=$item.id.Replace('Microsoft.CognitiveServices', 'Example.Service') }
            'extra-segment' { $item.id += '/extra' }
            'trailing-newline' { $item.id += "`n" }
            'encoded-region' { $item.id=$item.id.Replace('swedencentral', '%73wedencentral'); $null=$item.Remove('location') }
            'traversal-region' { $item.id=$item.id.Replace('swedencentral', '..'); $null=$item.Remove('location') }
            'backslash-region' { $item.id=$item.id.Replace('swedencentral', 'sweden\central'); $null=$item.Remove('location') }
            'query-region' { $item.id=$item.id.Replace('swedencentral', 'swedencentral?query'); $null=$item.Remove('location') }
            'fragment-region' { $item.id=$item.id.Replace('swedencentral', 'swedencentral#fragment'); $null=$item.Remove('location') }
        }
        $observed=Get-ExternalRetainedListReport $retainedState $foundryTarget $changed
        Confirm-Equal $observed.status 'INCONCLUSIVE' "Deleted account rejects $mutation"
        Confirm-Equal $observed.matchedIds.Count 0 'Malformed or conflicting deleted path does not establish ownership'
    }
    foreach ($mutation in @('another-group', 'uncaptured-name')) {
        $changed=Copy-Fixture $deletedFoundry
        foreach ($item in $changed.items) {
            if ($mutation -eq 'another-group') { $item.id=$item.id -replace '/resourceGroups/[^/]+/', '/resourceGroups/another-group/' }
            else { $item.id += '-other'; $item.name += '-other' }
        }
        $observed=Get-ExternalRetainedListReport $retainedState $foundryTarget $changed
        Confirm-Equal $observed.status 'PASS' 'Other well-formed deleted accounts remain classifiable'
        Confirm-Equal $observed.matchedIds.Count 0 'Name or lab prefix alone never establishes deleted account ownership'
    }
    $observed=Get-ExternalRetainedListReport $retainedState $foundryTarget @{items=@($deletedFoundry.items[0], $retainedEnvelopes.Foundry.items[0])}
    Confirm-Equal $observed.status 'INCONCLUSIVE' 'Original and deleted account paths are duplicate original records'
    Confirm-Equal $observed.matchedIds.Count 1 'Deleted account aliases never double count ownership'
    $retainedEnvelopes.APIM=$flatApim
    $retainedEnvelopes.Foundry=$deletedFoundry
    $changed=Copy-Fixture $evidence
    $changed.sha256='B' * 64
    Confirm-Rejected { Get-ExternalRetainedPlan $retainedState $lab $changed } 'Changed original evidence hash rejected'
    $changed=Copy-Fixture $evidence
    $changed.snapshot.resources[0].id += '-uncaptured'
    Confirm-Rejected { Get-ExternalRetainedPlan $retainedState $lab $changed } 'Outputs cannot adopt a resource absent from original snapshot'
    $changed=Copy-Fixture $evidence
    $changed.snapshot.resources += $changed.snapshot.resources[0]
    Confirm-Rejected { Get-ExternalRetainedPlan $retainedState $lab $changed } 'Duplicate snapshot resource rejected'
    $changed=Copy-Fixture $evidence
    $changed.snapshot.groups[0].tags['fgl-owner']=$state.tenantId
    Confirm-Rejected { Get-ExternalRetainedPlan $retainedState $lab $changed } 'Snapshot group ownership required'
    foreach ($change in @('foreign-resource', 'wrong-type', 'missing-workspace', 'wrong-resource-owner')) {
        $changed=Copy-Fixture $evidence
        switch ($change) {
            'foreign-resource' { $changed.snapshot.resources[-1].id=$existing }
            'wrong-type' { $changed.snapshot.resources[0].type='Example.Service/items' }
            'missing-workspace' { $changed.snapshot.resources=@($changed.snapshot.resources | Where-Object id -ne $workspaceIds[0]) }
            'wrong-resource-owner' { $changed.snapshot.resources[0].tags=@{'fgl-owner'=$state.tenantId} }
        }
        Confirm-Rejected { Get-ExternalRetainedPlan $retainedState $lab $changed } 'Snapshot provenance cannot be widened or incomplete'
    }
    $syntheticDirectory=Join-Path ([IO.Path]::GetTempPath()) ('fgl-retained-test-' + [guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($syntheticDirectory)
    try {
        $syntheticPath=Join-Path $syntheticDirectory 'synthetic-evidence.json'
        [IO.File]::WriteAllText($syntheticPath, ($evidence.snapshot | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        $fileState=Copy-Fixture $retainedState
        $fileState.teardownEvidence=@{path=$syntheticPath; sha256=(Get-FileHash -LiteralPath $syntheticPath -Algorithm SHA256).Hash}
        $loaded=Read-ExternalTeardownEvidence $fileState
        Confirm-Equal $loaded.sha256 $fileState.teardownEvidence.sha256 'Reader hashes exact original file bytes'
        Confirm-Equal $loaded.snapshot.resources.Count 70 'Reader preserves entire original snapshot'
        Confirm-Equal (Get-ExternalRetainedPlan $fileState $lab $loaded).Count 4 'Disk-loaded synthetic evidence validates'
        [IO.File]::AppendAllText($syntheticPath, ' ')
        Confirm-Rejected { Read-ExternalTeardownEvidence $fileState } 'Even a whitespace change invalidates original hash'
        $fileState.teardownEvidence.sha256='not-a-hash'
        Confirm-Rejected { Read-ExternalTeardownEvidence $fileState } 'Malformed evidence hash rejected'
    } finally { Remove-Item -LiteralPath $syntheticDirectory -Recurse -Force }
    function Read-ExternalTeardownEvidence {
        if ($script:retainedEvidenceUnavailable) { throw 'Synthetic missing or tampered original snapshot' }
        return $evidence
    }
    $script:retainedFailureLabel=''
    $script:retainedEvidenceUnavailable=$false
    $script:callLog.Clear()
    $report=Get-ExternalReport $retainedState 'RetainedRecords'
    Confirm-Equal $report.status 'PASS' 'Full retained collector recognizes documented shapes'
    Confirm-Equal $script:callLog.Count 5 'Exactly five read-only CLI invocations including context'
    Confirm-Equal $report.collection.timeoutSecondsPerCommand 60 'Each command has a finite timeout'
    Confirm-Equal $report.collection.additionalAttempts 0 'No collector retries'
    Confirm-Equal ($script:callLog[0].arguments -join ' ') 'account show' 'Retained context read first'
    Confirm-Equal ($script:callLog[1].arguments -join ' ') 'cognitiveservices account list-deleted --query {items:@}' 'Documented Foundry deleted list with array wrapper'
    Confirm-Equal ($script:callLog[2].arguments -join ' ') 'apim deletedservice list --query {items:@}' 'Documented APIM deleted list with array wrapper'
    Confirm-Equal ($script:callLog[3].arguments -join ' ') "rest --method GET --url https://management.azure.com/subscriptions/$($state.subscriptionId)/providers/Microsoft.OperationalInsights/deletedWorkspaces?api-version=2022-10-01 --query {items:value,nextLink:nextLink,continuationToken:continuationToken,skipToken:skipToken}" 'LAW uses documented subscription REST list with continuation metadata'
    Confirm-Equal $script:callLog[3].arguments[2] 'GET' 'LAW is strictly read-only'
    Confirm-Equal ($script:callLog[4].arguments -join ' ') "deployment sub list --query {items:[?name=='fgl-sample01-bootstrap' || name=='fgl-sample01-lock' || name=='fgl-sample01-activate'],nextLink:nextLink,continuationToken:continuationToken,skipToken:skipToken}" 'Root filter contains only three exact names and preserves pagination metadata'
    foreach ($call in $script:callLog) {
        Confirm-Equal ([object]::ReferenceEquals($call.state, $retainedState)) $true 'Every Invoke-LabAz uses explicit state and subscription'
        Confirm-Equal @($call.arguments | Where-Object { $_ -in @('delete', 'purge', 'recover', 'restore', 'create', 'update', 'set') }).Count 0 'Read-only command allowlist'
    }
    $summary=ConvertTo-ExternalSummary $report
    Confirm-Equal $summary.snapshotResourceCount 70 'Sanitized summary preserves original snapshot resource count'
    foreach ($target in $retainedPlan) { Confirm-Equal $summary.retainedRecords[$target.key].observedCount $target.count 'Sanitized owned count' }
    $report.errors += 'sensitive synthetic failure details'
    $report.retainedRecords.Foundry.extra='sensitive synthetic extra'
    $summaryText=(ConvertTo-ExternalSummary $report) | ConvertTo-Json -Depth 30
    foreach ($privateValue in @($state.subscriptionId, $state.tenantId, $state.ownershipId, $state.labId, $retainedState.teardownEvidence.path, $retainedState.teardownEvidence.sha256, 'sensitive synthetic', 'matchedIds', 'serviceId') + @($retainedPlan | ForEach-Object targetIds)) {
        Confirm-Equal $summaryText.Contains($privateValue) $false 'Retained summary exposes no identifiers, paths, hashes, raw properties or errors'
    }
    foreach ($target in $retainedPlan) {
        $savedEnvelope=$retainedEnvelopes[$target.key]
        $retainedEnvelopes[$target.key]=@{items=@()}
        $report=Get-ExternalReport $retainedState 'RetainedRecords'
        Confirm-Equal $report.status 'PASS' 'Empty retained list does not change teardown expectations'
        Confirm-Equal (ConvertTo-ExternalSummary $report).retainedRecords[$target.key].observedCount 0 'Missing retained records reported as zero'
        $retainedEnvelopes[$target.key]=@{items=@(@{name='unknown'; properties=@{resourceId=$target.targetIds[0]}})}
        $report=Get-ExternalReport $retainedState 'RetainedRecords'
        Confirm-Equal $report.status 'INCONCLUSIVE' 'Undocumented resourceId fallback cannot establish provenance'
        Confirm-Equal $report.retainedRecords[$target.key].complete $false 'Unknown original ID makes completeness false'
        $retainedEnvelopes[$target.key]=Copy-Fixture $savedEnvelope
        $retainedEnvelopes[$target.key].nextLink='synthetic-next-page'
        $report=Get-ExternalReport $retainedState 'RetainedRecords'
        Confirm-Equal $report.status 'INCONCLUSIVE' 'Collector rejects incomplete retained pagination'
        Confirm-Equal (ConvertTo-ExternalSummary $report).retainedRecords[$target.key].complete $false 'Summary never calls partial list complete'
        $retainedEnvelopes[$target.key]=$savedEnvelope
        $script:retainedFailureLabel="external-retained-$($target.key)"
        $script:callLog.Clear()
        $report=Get-ExternalReport $retainedState 'RetainedRecords'
        Confirm-Equal $report.status 'INCONCLUSIVE' 'Unsupported API or timeout is not zero or failure'
        Confirm-Equal $report.retainedRecords[$target.key].complete $false 'Unavailable read has no completeness claim'
        Confirm-Equal $script:callLog.Count 5 'Read failure neither retries nor skips independent lists'
        $script:retainedFailureLabel=''
    }
    foreach ($badState in @($state, (Copy-Fixture $retainedState))) {
        if ($badState.phase -eq 'destroyed') { $badState.pendingPhase='destroy' }
        $script:callLog.Clear()
        Confirm-Equal (Get-ExternalReport $badState 'RetainedRecords').status 'BLOCKED' 'Retained records require reconciled destroyed state'
        Confirm-Equal $script:callLog.Count 0 'Invalid lifecycle performs no reads'
    }
    $script:retainedEvidenceUnavailable=$true
    $script:callLog.Clear()
    Confirm-Equal (Get-ExternalReport $retainedState 'RetainedRecords').status 'BLOCKED' 'Missing original evidence blocks collection'
    Confirm-Equal $script:callLog.Count 0 'No CLI reads without original snapshot'
    $script:retainedEvidenceUnavailable=$false
    $script:context.tenantId=$state.subscriptionId
    $script:callLog.Clear()
    Confirm-Equal (Get-ExternalReport $retainedState 'RetainedRecords').status 'BLOCKED' 'Retained collection rejects wrong tenant'
    Confirm-Equal $script:callLog.Count 1 'Wrong context blocks all four lists'
    $script:context.tenantId=$state.tenantId
    $savedLab=Copy-Fixture $lab
    $lab.models += '-uncaptured'
    $script:callLog.Clear()
    Confirm-Equal (Get-ExternalReport $retainedState 'RetainedRecords').status 'BLOCKED' 'Output mismatch blocks retained collector'
    Confirm-Equal $script:callLog.Count 0 'Uncaptured output issues no CLI reads'
    $lab=$savedLab
    & {
        $script:jobMode='Completed'
        $script:jobStops=0
        $script:jobRemovals=0
        $script:expectedReadArguments=@('account', 'show')
        $script:expectedReadLabel='external-retained-context'
        function Start-Job($ScriptBlock, $ArgumentList) {
            Confirm-Equal $ArgumentList[0].subscriptionId $retainedState.subscriptionId 'Timed job receives explicit subscription'
            if ($ArgumentList[2] -match '^external-activity-\d{2}$') {
                Confirm-Equal ($ArgumentList[1][0..2] -join ' ') 'monitor activity-log list' 'Real bounded worker receives activity read'
                Confirm-Equal $ArgumentList[1][8] '5000' 'Real bounded worker preserves activity limit'
                Confirm-Equal $ArgumentList[1][10] '' 'Real bounded worker preserves empty group override'
            } else {
                Confirm-Equal ($ArgumentList[1] -join ' ') ($script:expectedReadArguments -join ' ') 'Timed job preserves command arguments'
                Confirm-Equal $ArgumentList[2] $script:expectedReadLabel 'Timed job preserves fixed label'
            }
            Confirm-Equal ([IO.Path]::GetFileName($ArgumentList[3])) 'LabExecution.psm1' 'Timed job imports existing CLI helper'
            $script:jobBody=$ScriptBlock
            $script:jobArguments=$ArgumentList
            return [pscustomobject]@{State=$script:jobMode}
        }
        function Wait-Job($Job, $Timeout) {
            Confirm-Equal $Timeout 60 'Real wrapper enforces 60-second wait'
            if ($Job.State -ne 'Running') { return $Job }
        }
        function Receive-Job($Job) {
            function Import-Module($Name) { Confirm-Equal ([IO.Path]::GetFileName($Name)) 'LabExecution.psm1' 'Worker only loads CLI helper' }
            $workerResult = & $script:jobBody @script:jobArguments
            $script:receivedJobResult = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($workerResult, 100))
            return $script:receivedJobResult
        }
        function Stop-Job($Job) { $script:jobStops++ }
        function Remove-Job($Job, [switch]$Force) { $script:jobRemovals++ }
        $result=& $boundedRead $retainedState @('account', 'show') 'external-retained-context'
        Confirm-Equal $result.id $retainedState.subscriptionId 'Timed worker returns complete CLI result'
        foreach ($mode in @('Running', 'Failed')) {
            $script:jobMode=$mode
            Confirm-Rejected { & $boundedRead $retainedState @('account', 'show') 'external-retained-context' } 'Timeout or failed worker rejects partial output'
        }
        Confirm-Equal $script:jobStops 1 'Timed-out worker stopped'
        Confirm-Equal $script:jobRemovals 3 'All workers removed'
        $script:jobMode='Completed'
        foreach ($target in $retainedPlan) {
            $savedEnvelope=$retainedEnvelopes[$target.key]
            $script:expectedReadArguments=@('synthetic', 'list', '--query', '{items:@}')
            $script:expectedReadLabel="external-retained-$($target.key)"
            foreach ($fixture in @($savedEnvelope, @{items=@($savedEnvelope.items[0])}, @{items=@()})) {
                $retainedEnvelopes[$target.key]=$fixture
                $result=& $boundedRead $retainedState $script:expectedReadArguments $script:expectedReadLabel
                Confirm-Equal ($script:receivedJobResult.items -is [Collections.ArrayList]) $true 'Actual PowerShell serialization changes arrays to ArrayList'
                Confirm-Equal (Get-ExternalRetainedListReport $retainedState $target $script:receivedJobResult).status 'INCONCLUSIVE' 'Negative control: deserialized arrays fail the strict classifier without normalization'
                Confirm-Equal ($result.items -is [array]) $true 'Received result restores JSON array type including empty and singleton arrays'
                Confirm-Equal $result.items.Count $fixture.items.Count 'Serialization and normalization preserve exact cardinality'
                $observed=Get-ExternalRetainedListReport $retainedState $target $result
                Confirm-Equal $observed.status 'PASS' 'Actual serialized worker output passes retained classification'
                Confirm-Equal $observed.matchedIds.Count $fixture.items.Count 'Original IDs survive serialization and normalization'
            }
            foreach ($fixture in @(@{items=$null}, @{items=@{}}, @{items=$savedEnvelope.items[0]}, @{items=$savedEnvelope.items; nextLink='synthetic-next-page'})) {
                $retainedEnvelopes[$target.key]=$fixture
                $result=& $boundedRead $retainedState $script:expectedReadArguments $script:expectedReadLabel
                Confirm-Equal (Get-ExternalRetainedListReport $retainedState $target $result).status 'INCONCLUSIVE' 'Normalization does not invent arrays or discard pagination'
            }
            $retainedEnvelopes[$target.key]=$savedEnvelope
        }
        Confirm-Equal $script:jobRemovals 31 'Serialized fixture workers are all removed'
        function Invoke-ExternalRetainedRead([hashtable]$State, [string[]]$Arguments, [string]$Label) {
            & $boundedRead $State $Arguments $Label
        }
        foreach ($fixture in @(@{items=@($deployment)}, @{items=@()}, @{items=@{value=@($deployment)}})) {
            $script:activityEnvelope=$fixture
            $collection=Get-ExternalActivityCollection $destroyedState $collectionEnd
            Confirm-Equal $collection.complete $true 'Real worker serialization preserves complete activity shapes'
            Confirm-Equal ($collection.events -is [array]) $true 'Merged events remain an array including singleton and empty'
            Confirm-Equal $collection.calls 1 'Small serialized fixtures require one bounded read'
        }
        $script:activitySource=$partitionSource
        $report=Get-ExternalReport $destroyedState 'AfterTeardown'
        Confirm-Equal $report.status 'PASS' 'Over-5000 collection works through actual job serialization and normalization'
        Confirm-Equal $report.activity.eventCount 6001 'Serialized adaptive merge preserves every unique event'
        Confirm-Equal $report.rawActivity.calls 3 'Serialized adaptive collection invokes only the required windows'
        $script:activitySource=$null
        $script:activityEnvelope=@{items=@($deployment); nextLink='synthetic-next-page'}
        $report=Get-ExternalReport $destroyedState 'AfterTeardown'
        Confirm-Equal $report.status 'INCONCLUSIVE' 'Real serialization cannot erase activity continuation'
        $script:activityEnvelope=@{items=@($deployment)}
        foreach ($mode in @('Running', 'Failed')) {
            $script:jobMode=$mode
            $report=Get-ExternalReport $destroyedState 'AfterTeardown'
            Confirm-Equal $report.status 'INCONCLUSIVE' 'Actual bounded activity timeout or failed job cannot pass'
            Confirm-Equal $report.rawActivity.calls 1 'Failed bounded activity job is not retried'
        }
        Confirm-Equal $script:jobStops 2 'Both retained and activity timed-out workers are stopped'
        Confirm-Equal $script:jobRemovals 40 'All retained and activity serialized workers are removed'
    }
    foreach ($path in @((Join-Path $PSScriptRoot '../scripts/Test-LabExternal.ps1'), $PSCommandPath)) {
        $source = Get-Content -LiteralPath $path -Raw
        Assert-PublicText $source
        Confirm-Equal ([regex]::IsMatch($source, '[^\x00-\x7F]')) $false 'ASCII public source'
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
        Confirm-Equal @($parseErrors).Count 0 'Valid PowerShell syntax'
    }
    Write-Output "PASS: $script:passed local external checks (synthetic fixtures; no network or private files)"
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}