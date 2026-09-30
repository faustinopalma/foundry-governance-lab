[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot '../scripts/TestResults.psm1') -Force
    $harnessPath = Join-Path $PSScriptRoot '../scripts/Invoke-IdentityChecks.ps1'
    $parseTokens = $null
    $parseErrors = $null
    $harnessAst = [Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Identity harness syntax is invalid' }
    foreach ($helper in $harnessAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        . ([scriptblock]::Create($helper.Extent.Text))
    }
    $checks = 0
    $validList = '{"object":"list","data":[],"has_more":false}'
    if (-not (ConvertTo-IdentityProbe 200 $validList).listValid) { throw 'Empty but valid agent list rejected' }
    $checks++
    foreach ($body in @('{}', '[]', '<html/>', '', '{"object":"list","data":{}}', '{"object":"list","data":[{}]}', '{"object":"list","data":["invalid"]}', '{"object":"list","data":[{"object":"agent","name":"first"},{"object":"agent","name":"second"}]}')) {
        if ((ConvertTo-IdentityProbe 200 $body).listValid) { throw 'Invalid list accepted' }
        $checks++
    }
    foreach ($status in 200..299) {
        $probe = ConvertTo-IdentityProbe $status '{}'
        if ((Get-IdentityNegativeVerdict $true $probe) -ne 'FAIL' -or (Get-IdentityNegativeVerdict $false $probe) -ne 'BLOCKED') { throw 'Positive prerequisite or successful negative misclassified' }
        $checks++
    }
    foreach ($status in @(0, 301, 401, 404, 429, 500, 503)) {
        $probe = ConvertTo-IdentityProbe $status '{"error":{"code":"PermissionDenied","message":"The principal lacks the required data action."}}'
        if ((Get-IdentityNegativeVerdict $true $probe) -ne 'INCONCLUSIVE') { throw 'Non-403 accepted as authorization proof' }
        $checks++
    }
    foreach ($body in @('{"error":{"code":"PermissionDenied","message":"The principal lacks the required data action."}}', '{"errors":[{"code":"DENIED","message":"requested access to the resource is denied"}]}')) {
        $probe = ConvertTo-IdentityProbe 403 $body
        if ((Get-IdentityNegativeVerdict $true $probe) -ne 'PASS' -or (Get-IdentityNegativeVerdict $false $probe) -ne 'BLOCKED') { throw 'Explicit denial or prerequisite misclassified' }
        $checks++
    }
    foreach ($message in @('Forbidden', 'Public network access is disabled', 'The principal lacks the required data action; IP address blocked', 'Access denied due to Virtual Network/Firewall rules')) {
        $probe = ConvertTo-IdentityProbe 403 (@{error=@{code='PermissionDenied'; message=$message}} | ConvertTo-Json -Compress)
        if ((Get-IdentityNegativeVerdict $true $probe) -ne 'INCONCLUSIVE') { throw 'Ambiguous or network denial accepted' }
        $checks++
    }
    $foundryMessage = 'Identity(object id: 33333333-3333-4333-8333-333333333333) does not have permissions for Microsoft.CognitiveServices/accounts/AIServices/agents/read actions. Please refer to https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry to fix the permissions issue.'
    $foundryError = @{code='UserError'; innerError=@{code='ForbiddenError'}; message=$foundryMessage}
    foreach ($action in @('read', 'write', 'delete')) {
        $errorBody = $foundryError.Clone()
        $errorBody.message = $foundryMessage.Replace('/read actions.', "/$action actions.")
        $probe = ConvertTo-IdentityProbe 403 (@{error=$errorBody} | ConvertTo-Json -Depth 5 -Compress)
        if ($probe.category -cne 'Authorization' -or $probe.code -cne 'Forbidden' -or (Get-IdentityNegativeVerdict $true $probe) -ne 'PASS' -or (Get-IdentityNegativeVerdict $false $probe) -ne 'BLOCKED') { throw 'Foundry action denial or positive prerequisite misclassified' }
        $checks++
    }
    foreach ($change in @(
        @{code='OtherError'},
        @{code='usererror'},
        @{innerError=@{code='AuthenticationError'}},
        @{innerError=@{code='forbiddenerror'}},
        @{innerError=$null},
        @{innerError='ForbiddenError'},
        @{message=$foundryMessage.Replace('does not have permissions', 'has permissions')},
        @{message=$foundryMessage.Replace('Microsoft.CognitiveServices/accounts/AIServices/', '')},
        @{message=$foundryMessage.Replace('Microsoft.CognitiveServices', 'Microsoft.OtherServices')},
        @{message=$foundryMessage.Replace('Microsoft.CognitiveServices', 'MicrosoftXCognitiveServices')},
        @{message=$foundryMessage.Replace('/agents/read', '/models/read')},
        @{message=$foundryMessage.Replace('/agents/read', '/agents/reader')},
        @{message=$foundryMessage.Replace('/agents/read', '/agents/read/extra')},
        @{message=$foundryMessage.Replace('33333333-3333-4333-8333-333333333333', 'invalid')},
        @{message='Forbidden'},
        @{message='Token authentication failed'},
        @{message=($foundryMessage + ' Public network access is disabled')}
    )) {
        $errorBody = $foundryError.Clone()
        foreach ($key in $change.Keys) { $errorBody[$key] = $change[$key] }
        $probe = ConvertTo-IdentityProbe 403 (@{error=$errorBody} | ConvertTo-Json -Depth 5 -Compress)
        if ((Get-IdentityNegativeVerdict $true $probe) -ne 'INCONCLUSIVE') { throw 'Unverified Foundry error accepted as action denial' }
        $checks++
    }
    foreach ($status in @(0, 301, 401, 404, 429, 500, 503)) {
        $probe = ConvertTo-IdentityProbe $status (@{error=$foundryError} | ConvertTo-Json -Depth 5 -Compress)
        if ((Get-IdentityNegativeVerdict $true $probe) -ne 'INCONCLUSIVE') { throw 'Foundry denial body proved authorization without HTTP 403' }
        $checks++
    }
    $budget = @{requests=0}
    foreach ($attempt in 1..30) { Use-IdentityRequestBudget $budget }
    $rejected = $false
    try { Use-IdentityRequestBudget $budget } catch { $rejected = $true }
    if (-not $rejected -or $budget.requests -ne 30) { throw 'Request limit exceeded' }
    $checks++

    function New-IdentitySyntheticToken([hashtable]$Claims) {
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Claims | ConvertTo-Json -Depth 8 -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return "synthetic.$payload.signature"
    }
    $baseClaims = @{aud='https://ai.azure.com'; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600}
    if (-not (Read-IdentityClaims (New-IdentitySyntheticToken $baseClaims))) { throw 'Current token rejected' }
    foreach ($change in @(@{exp=0}, @{exp=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+30)}, @{aud=@('https://ai.azure.com')}, @{nbf=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600)})) {
        $claims = $baseClaims.Clone()
        foreach ($key in $change.Keys) { $claims[$key] = $change[$key] }
        if (Read-IdentityClaims (New-IdentitySyntheticToken $claims)) { throw 'Invalid claims accepted' }
        $checks++
    }
    foreach ($malformed in @('', 'invalid', 'synthetic.!.signature', 'synthetic..signature', '.e30.signature')) {
        if (Read-IdentityClaims $malformed) { throw 'Malformed token accepted' }
        $checks++
    }
    $dnsDefinition = $harnessAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-IdentityPrivateDns' }, $true)
    if (-not $dnsDefinition) { throw 'Missing DNS boundary' }
    $dnsStub = @'
function Get-IdentityPrivateDns {
    param([string]$HostName)
    if ($HostName -notin $fixture.hosts) { $fixture.errors.Add('Unexpected DNS target'); throw 'Unexpected DNS target' }
    $fixture.dns.Add($HostName)
    return $fixture.dnsVerdict
}
'@
    $harnessRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts'))
    $mockedHarness = [scriptblock]::Create($harnessAst.Extent.Text.Replace($dnsDefinition.Extent.Text, $dnsStub).Replace('$PSScriptRoot', '$harnessRoot'))

    function Invoke-IdentityOffline([hashtable]$Options = @{}) {
        $state = @{
            subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'
            ownershipId='33333333-3333-4333-8333-333333333333'; labId='sample01'; phase='activate'
            resourceGroups=@('models', 'integration', 'case-a', 'case-b') | ForEach-Object { "rg-fgl-sample01-$_" }
        }
        $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01"
        $lab = @{
            phase='activate'; resourceGroups=$state.resourceGroups
            models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/synthetic-models"
            gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/synthetic-gateway"
            runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/synthetic-runner"
            identities=@('dev-a', 'consumer-a', 'dev-b', 'publisher-a', 'publisher-b', 'client', 'denied') | ForEach-Object {
                @{actor=$_; resourceId="$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/synthetic-$_"; clientId=[guid]::NewGuid().ToString(); principalId=[guid]::NewGuid().ToString()}
            }
            cases=@('a', 'b') | ForEach-Object {
                $accountId = "$prefix-case-$_/providers/Microsoft.CognitiveServices/accounts/synthetic-case-$_"
                $label = $_
                @{accountId=$accountId; registryId="$prefix-case-$_/providers/Microsoft.ContainerRegistry/registries/syntheticregistry$_"; projects=@('dev', 'test') | ForEach-Object { @{name="case-$label-$_"; resourceId="$accountId/projects/case-$label-$_"} }}
            }
        }
        $hosts = @('a', 'b') | ForEach-Object { 'synthetic-case-' + $_ + '.services.ai.azure.com'; 'syntheticregistry' + $_ + '.azurecr.io' }
        $fixture = @{
            state=$state; lab=$lab; hosts=$hosts; dnsVerdict='PASS'; reads=0; savedJson=$null
            statePath=(Join-Path ([IO.Path]::GetTempPath()) "identity-$([guid]::NewGuid().ToString('N'))-state.json")
            outputsPath=(Join-Path ([IO.Path]::GetTempPath()) "identity-$([guid]::NewGuid().ToString('N'))-outputs.json")
            resultsPath=(Join-Path ([IO.Path]::GetTempPath()) "identity-$([guid]::NewGuid().ToString('N'))-results.json")
            imds=[System.Collections.Generic.List[object]]::new(); http=[System.Collections.Generic.List[object]]::new()
            dns=[System.Collections.Generic.List[string]]::new(); errors=[System.Collections.Generic.List[string]]::new()
            issued=@{}; privateTokens=[System.Collections.Generic.List[string]]::new()
            positiveStatus=200; negativeStatus=403; listBody=$null; emptyAgents=$false; badAgentName=$false; badAgentRead=$false
            consumerStatus=200; negativeMessage='The principal lacks the required data action.'; negativeCode='PermissionDenied'; negativeInnerCode=''
            registryEmpty=$false; tagsStatus=200; manifestStatus=200; badDigest=$false; badManifest=$false; registryNegativeStatus=403
            registryNegativeCode='DENIED'; registryNegativeMessage='requested access to the resource is denied'
            oauthFailure=''; oauthWrongAudience=$false; tokenActor=''; tokenClaim=''; throwToken=$false; throwHttp=$false; writeFails=$false
        }
        foreach ($key in $Options.Keys) { $fixture[$key] = $Options[$key] }
        if ($Options.badPhase) { $state.phase = 'lock' }
        if ($Options.badGroups) { $lab.resourceGroups = @('unexpected') }
        if ($Options.duplicateActor) { $lab.identities[1] = $lab.identities[0] }
        if ($Options.duplicateClient) { $lab.identities[1].clientId = $lab.identities[0].clientId }
        if ($Options.emptyGuid) { $lab.identities[1].principalId = [guid]::Empty.ToString() }
        if ($Options.outsideScope) { $lab.cases[0].accountId = "$prefix-outside/providers/Microsoft.CognitiveServices/accounts/synthetic-case-a" }
        if ($Options.wrongProject) { $lab.cases[0].projects[0].resourceId = $lab.cases[1].projects[0].resourceId }
        if ($Options.wrongCase) { $lab.cases[0].registryId = $lab.cases[1].registryId }
        if ($Options.badHost) { $lab.cases[0].registryId += '.attacker.invalid' }
        if ($Options.internalState) { $fixture.statePath = Join-Path $harnessRoot 'synthetic-state.json' }
        if ($Options.internalOutputs) { $fixture.outputsPath = Join-Path $harnessRoot 'synthetic-outputs.json' }
        if ($Options.internalResults) { $fixture.resultsPath = Join-Path $harnessRoot 'synthetic-results.json' }
        if ($Options.collidingResults) { $fixture.resultsPath = $fixture.statePath }
        if ($Options.existingResults) { $fixture.resultsPath = $harnessPath }
        if ($Options.missingResults) { $fixture.resultsPath = '' }

        function Assert-IdentityMock([bool]$Condition, [string]$Message) {
            if (-not $Condition) { $fixture.errors.Add($Message); throw $Message }
        }
        function Get-Content {
            [CmdletBinding()]
            param([string]$LiteralPath, [switch]$Raw)
            $fixture.reads++
            if ($LiteralPath -eq $fixture.statePath) { return $fixture.state | ConvertTo-Json -Depth 12 }
            if ($LiteralPath -eq $fixture.outputsPath) { return $fixture.lab | ConvertTo-Json -Depth 12 }
            $fixture.errors.Add('Unexpected file read'); throw 'Unexpected file read'
        }
        function Invoke-RestMethod {
            [CmdletBinding()]
            param([uri]$Uri, [hashtable]$Headers, [switch]$NoProxy, [int]$TimeoutSec, [int]$OperationTimeoutSeconds, [int]$MaximumRedirection, [int]$MaximumRetryCount)
            Assert-IdentityMock ($Uri.Scheme -eq 'http' -and $Uri.Host -eq '169.254.169.254' -and $Uri.AbsolutePath -eq '/metadata/identity/oauth2/token' -and $Headers.Metadata -eq 'true') 'Unexpected IMDS target'
            Assert-IdentityMock ($NoProxy -and $TimeoutSec -eq 20 -and $MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0 -and -not $PSBoundParameters.Verbose -and -not $PSBoundParameters.Debug) 'Unsafe IMDS options'
            Assert-IdentityMock ($PSVersionTable.PSVersion -lt [version]'7.4' -or $OperationTimeoutSeconds -eq 20) 'Unbounded IMDS response read'
            $query = @{}
            foreach ($part in $Uri.Query.TrimStart('?').Split('&')) { $pair = $part.Split('=', 2); $query[$pair[0]] = [uri]::UnescapeDataString($pair[1]) }
            $actor = @($fixture.lab.identities | Where-Object { $_.clientId -eq $query.client_id })
            Assert-IdentityMock ($actor.Count -eq 1 -and $query['api-version'] -eq '2018-02-01' -and $query.resource -cin @('https://ai.azure.com', 'https://containerregistry.azure.net')) 'Invalid IMDS selector or audience'
            $fixture.imds.Add(@{actor=$actor[0].actor; audience=$query.resource})
            if ($fixture.throwToken -and $actor[0].actor -eq $fixture.tokenActor) { throw 'PRIVATE-SENTINEL' }
            $claims = @{tid=$fixture.state.tenantId; oid=$actor[0].principalId; aud=$query.resource; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600}
            if ($fixture.tokenClaim -and $actor[0].actor -eq $fixture.tokenActor) { $claims[$fixture.tokenClaim] = 'unexpected' }
            $token = New-IdentitySyntheticToken $claims
            $fixture.issued[$token] = @{actor=$actor[0].actor; audience=$query.resource; kind='Entra'}
            $fixture.privateTokens.Add($token)
            return @{token_type='Bearer'; access_token=$token}
        }
        function New-MockIdentityResponse([int]$Status, [string]$Content, [hashtable]$Headers = @{}) {
            return @{StatusCode=$Status; Content=$Content; Headers=$Headers}
        }
        function Invoke-WebRequest {
            [CmdletBinding()]
            param([uri]$Uri, [string]$Method, [hashtable]$Headers, [hashtable]$Body, [string]$ContentType, [switch]$NoProxy, [int]$TimeoutSec, [int]$OperationTimeoutSeconds, [int]$MaximumRedirection, [int]$MaximumRetryCount, [switch]$SkipHttpErrorCheck)
            Assert-IdentityMock ($Uri.Scheme -eq 'https' -and $Uri.Host -in $fixture.hosts -and $NoProxy -and $TimeoutSec -eq 20 -and $MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0 -and $SkipHttpErrorCheck -and -not $PSBoundParameters.Verbose -and -not $PSBoundParameters.Debug) 'Unsafe HTTP request options or target'
            Assert-IdentityMock ($PSVersionTable.PSVersion -lt [version]'7.4' -or $OperationTimeoutSeconds -eq 20) 'Unbounded service response read'
            $token = ([string]$Headers.Authorization) -replace '^Bearer ', ''
            $identity = if ($token) { $fixture.issued[$token] } else { $null }
            $fixture.http.Add(@{host=$Uri.Host; path=$Uri.AbsolutePath; query=$Uri.Query; method=$Method; actor=$identity.actor})
            Assert-IdentityMock ($fixture.http.Count + $fixture.imds.Count -le 30) 'Request budget exceeded'
            if ($fixture.throwHttp) { throw 'PRIVATE-SENTINEL' }
            $caseLabel = if ($Uri.Host -in @($fixture.hosts[0], $fixture.hosts[1])) { 'a' } else { 'b' }
            if ($Uri.AbsolutePath.StartsWith('/oauth2/')) {
                Assert-IdentityMock ($Method -eq 'Post' -and $ContentType -eq 'application/x-www-form-urlencoded' -and -not $token -and $Body.service -ceq $Uri.Host) 'Unsafe OAuth form'
                if ($Uri.AbsolutePath -eq '/oauth2/exchange') {
                    $source = $fixture.issued[$Body.access_token]
                    Assert-IdentityMock ($source.kind -eq 'Entra' -and $source.audience -ceq 'https://containerregistry.azure.net' -and $Body.grant_type -ceq 'access_token' -and $Body.tenant -eq $fixture.state.tenantId) 'Invalid OAuth exchange'
                    if ($fixture.oauthFailure -eq 'exchange' -or ($fixture.oauthFailure -eq 'cross' -and $source.actor -cne "publisher-$caseLabel")) { return New-MockIdentityResponse 403 '{"errors":[{"code":"DENIED","message":"PRIVATE-SENTINEL"}]}' }
                    $refreshToken = 'private-refresh-' + [guid]::NewGuid().ToString('N')
                    $fixture.issued[$refreshToken] = @{actor=$source.actor; kind='Refresh'; host=$Uri.Host}
                    $fixture.privateTokens.Add($refreshToken)
                    return New-MockIdentityResponse 200 (@{refresh_token=$refreshToken} | ConvertTo-Json -Compress)
                }
                Assert-IdentityMock ($Uri.AbsolutePath -eq '/oauth2/token' -and $Body.grant_type -ceq 'refresh_token' -and $Body.scope -ceq "repository:case-$caseLabel/test:pull") 'Wrong OAuth repository scope'
                $source = $fixture.issued[$Body.refresh_token]
                Assert-IdentityMock ($source.kind -eq 'Refresh' -and $source.host -ceq $Uri.Host) 'Refresh token reused across registries'
                if ($fixture.oauthFailure -eq 'token') { return New-MockIdentityResponse 401 '{"error":"PRIVATE-SENTINEL"}' }
                $audience = if ($fixture.oauthWrongAudience) { 'wrong.invalid' } else { $Uri.Host }
                $accessToken = New-IdentitySyntheticToken @{aud=$audience; sub=$source.actor; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600; access=@()}
                $fixture.issued[$accessToken] = @{actor=$source.actor; kind='Registry'; host=$Uri.Host}
                $fixture.privateTokens.Add($accessToken)
                return New-MockIdentityResponse 200 (@{access_token=$accessToken} | ConvertTo-Json -Compress)
            }
            Assert-IdentityMock ($Method -eq 'Get' -and $null -eq $Body -and $identity) 'Unexpected write or missing bearer token'
            if ($Uri.AbsolutePath.StartsWith('/api/projects/')) {
                Assert-IdentityMock ($identity.kind -eq 'Entra' -and $identity.audience -ceq 'https://ai.azure.com' -and $Uri.AbsolutePath.StartsWith("/api/projects/case-$caseLabel-dev/agents")) 'Wrong project route or audience'
                if ($Uri.AbsolutePath.EndsWith('/agents')) {
                    Assert-IdentityMock ($Uri.Query -ceq '?api-version=v1&limit=1') 'Unbounded agent list or guessed API'
                    if ($identity.actor -cnotin @("dev-$caseLabel", $(if ($caseLabel -eq 'a') { 'consumer-a' }))) {
                        return New-MockIdentityResponse $fixture.negativeStatus (@{error=@{code=$fixture.negativeCode; innerError=@{code=$fixture.negativeInnerCode}; message=$fixture.negativeMessage; private='PRIVATE-SENTINEL'}} | ConvertTo-Json -Depth 5 -Compress)
                    }
                    $status = if ($identity.actor -eq 'consumer-a') { $fixture.consumerStatus } else { $fixture.positiveStatus }
                    if ($null -ne $fixture.listBody) { return New-MockIdentityResponse $status $fixture.listBody }
                    $name = if ($fixture.badAgentName) { '../other?secret=PRIVATE-SENTINEL' } else { 'synthetic-agent' }
                    $data = @()
                    if (-not $fixture.emptyAgents) { $data = @(@{object='agent'; name=$name}) }
                    return New-MockIdentityResponse $status (@{object='list'; data=$data; has_more=$true; nextLink='https://attacker.invalid/PRIVATE-SENTINEL'} | ConvertTo-Json -Depth 6 -Compress)
                }
                Assert-IdentityMock ($caseLabel -eq 'a' -and $Uri.AbsolutePath -ceq '/api/projects/case-a-dev/agents/synthetic-agent' -and $Uri.Query -ceq '?api-version=v1') 'Unsafe discovered agent route'
                $name = if ($fixture.badAgentRead) { 'different-agent' } else { 'synthetic-agent' }
                return New-MockIdentityResponse 200 (@{object='agent'; name=$name; instructions='PRIVATE-SENTINEL'} | ConvertTo-Json -Compress)
            }
            Assert-IdentityMock ($identity.kind -eq 'Registry' -and $identity.host -ceq $Uri.Host) 'Registry bearer from wrong exchange'
            $repo = "case-$caseLabel/test"
            if ($Uri.AbsolutePath -ceq "/v2/$repo/tags/list") {
                Assert-IdentityMock ($Uri.Query -ceq '?n=1' -and $identity.actor -ceq "publisher-$caseLabel") 'Unbounded tag enumeration'
                $tags = @()
                if (-not $fixture.registryEmpty) { $tags = @('synthetic-v1') }
                return New-MockIdentityResponse $fixture.tagsStatus (@{name=$repo; tags=$tags} | ConvertTo-Json -Compress) @{Link='<https://attacker.invalid/PRIVATE-SENTINEL>; rel="next"'}
            }
            Assert-IdentityMock ($Uri.AbsolutePath.StartsWith("/v2/$repo/manifests/") -and -not $Uri.Query -and $Headers.Accept -match 'application/vnd.oci.image.manifest.v1\+json') 'Unknown registry route or manifest accept header'
            if ($identity.actor -cne "publisher-$caseLabel") {
                Assert-IdentityMock ($Uri.AbsolutePath -cmatch '/manifests/sha256:[a-f0-9]{64}$') 'Negative manifest not pinned to positive digest'
                return New-MockIdentityResponse $fixture.registryNegativeStatus (@{errors=@(@{code=$fixture.registryNegativeCode; message=$fixture.registryNegativeMessage; detail='PRIVATE-SENTINEL'})} | ConvertTo-Json -Depth 5 -Compress)
            }
            Assert-IdentityMock ($Uri.AbsolutePath.EndsWith('/synthetic-v1')) 'Invented positive tag'
            $manifest = @{schemaVersion=2; mediaType='application/vnd.oci.image.manifest.v1+json'; config=@{digest=('sha256:' + ('a' * 64))}; layers=@(); annotations=@{private='PRIVATE-SENTINEL'}}
            if ($fixture.badManifest) { $manifest.schemaVersion = 1 }
            $content = $manifest | ConvertTo-Json -Depth 8 -Compress
            $digest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($content))).ToLowerInvariant()
            if ($fixture.badDigest) { $digest = 'sha256:' + ('b' * 64) }
            return New-MockIdentityResponse $fixture.manifestStatus $content @{'Docker-Content-Digest'=@($digest)}
        }
        function Out-File {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, [string]$LiteralPath, [string]$Encoding, [switch]$NoClobber)
            process {
                Assert-IdentityMock ($LiteralPath -eq $fixture.resultsPath -and $Encoding -eq 'utf8' -and $NoClobber) 'Unsafe persistence'
                if ($fixture.writeFails) { throw 'PRIVATE-SENTINEL' }
                $fixture.savedJson = [string]$InputObject
            }
        }
        $arguments = @{StatePath=$fixture.statePath; OutputsPath=$fixture.outputsPath; ResultsPath=$fixture.resultsPath; RunLive=(-not $Options.noLive); Verbose=$true; Debug=$true}
        $captured = @(& $mockedHarness @arguments *>&1)
        if ($fixture.errors.Count) { throw ($fixture.errors -join '; ') }
        $text = ($captured | ConvertTo-Json -Depth 15 -Compress) + $fixture.savedJson
        foreach ($privateValue in @('PRIVATE-SENTINEL', 'synthetic-agent', 'synthetic-v1') + $hosts + @($fixture.privateTokens.ToArray()) + @($lab.identities.clientId) + @($lab.identities.principalId) + @($state.subscriptionId, $state.tenantId)) {
            if ($text.Contains($privateValue)) { throw 'Private evidence escaped the runner' }
        }
        $fixture.rows = @($captured | Where-Object { $_ -isnot [string] -and $_.PSObject.Properties.Name -contains 'test' })
        if ($fixture.savedJson) {
            $fixture.report = $fixture.savedJson | ConvertFrom-Json -AsHashtable
            if ($fixture.report.requests -ne $fixture.imds.Count + $fixture.http.Count -or $fixture.report.requests -gt 30 -or $fixture.report.dnsQueries -ne $fixture.dns.Count) { throw 'Request accounting mismatch' }
            if (@($fixture.report.tests | Where-Object { $_.status -notin @('PASS', 'FAIL', 'BLOCKED', 'INCONCLUSIVE') }).Count) { throw 'Invalid status persisted' }
        }
        return $fixture
    }
    function Assert-IdentityRow([hashtable]$Fixture, [string]$Test, [string]$Expected) {
        $rows = @($Fixture.rows | Where-Object { $_.test -ceq $Test })
        if ($rows.Count -ne 1 -or $rows[0].status -cne $Expected) { throw "Wrong verdict for ${Test}: expected $Expected" }
    }
    $complete = Invoke-IdentityOffline
    if (-not $complete.savedJson -or $complete.report.requests -ne 29 -or $complete.imds.Count -ne 6 -or $complete.http.Count -ne 23 -or $complete.dns.Count -ne 4) { throw "Complete offline cycle failed: $($complete.report.requests) requests" }
    foreach ($test in @('DEV-A-LIST', 'DEV-B-LIST', 'DEV-A-CROSS', 'DEV-B-CROSS', 'DENIED-PROJECT', 'CONSUMER-LIST', 'CONSUMER-CROSS', 'DEV-A-AGENT-READ', 'CONSUMER-AGENT-READ', 'ACR-A-MANIFEST', 'ACR-B-MANIFEST', 'ACR-A-CROSS', 'ACR-B-CROSS')) {
        Assert-IdentityRow $complete $test 'PASS'
        $checks++
    }
    foreach ($test in @('DEV-A-CRUD', 'DEV-B-CRUD', 'DEV-A-TEST', 'DEV-B-TEST', 'DEV-A-ACCOUNT-ADMIN', 'DEV-B-ACCOUNT-ADMIN', 'DEV-A-MODEL-ADMIN', 'DEV-B-MODEL-ADMIN', 'ACR-A-ABAC', 'ACR-B-ABAC', 'CONSUMER-INVOKE', 'CONSUMER-WRITE-DENIAL', 'ACR-PROJECT-PULL')) {
        Assert-IdentityRow $complete $test 'BLOCKED'
        $checks++
    }
    $foundryOptions = @{negativeCode='UserError'; negativeInnerCode='ForbiddenError'; negativeMessage=$foundryMessage}
    $foundry = Invoke-IdentityOffline $foundryOptions
    foreach ($test in @('DEV-A-CROSS', 'DEV-B-CROSS', 'DENIED-PROJECT', 'CONSUMER-CROSS')) {
        Assert-IdentityRow $foundry $test 'PASS'
        $row = @($foundry.rows | Where-Object { $_.test -ceq $test })[0]
        if ($row.httpStatus -ne 403 -or $row.category -cne 'Authorization') { throw 'Observed Foundry denial lost its HTTP status or category' }
        $checks++
    }
    foreach ($change in @(@{positiveStatus=503}, @{listBody='{}'}, @{tokenActor='dev-a'; tokenClaim='aud'}, @{tokenActor='dev-a'; tokenClaim='oid'}, @{tokenActor='dev-a'; tokenClaim='tid'})) {
        $options = $foundryOptions.Clone()
        foreach ($key in $change.Keys) { $options[$key] = $change[$key] }
        $blocked = Invoke-IdentityOffline $options
        foreach ($test in @('DEV-A-CROSS', 'DEV-B-CROSS', 'DENIED-PROJECT', 'CONSUMER-CROSS')) { Assert-IdentityRow $blocked $test 'BLOCKED'; $checks++ }
    }
    foreach ($change in @(@{negativeStatus=401}, @{negativeCode='OtherError'}, @{negativeInnerCode='AuthenticationError'}, @{negativeMessage='Forbidden'}, @{negativeMessage=($foundryMessage + ' Firewall denied access')})) {
        $options = $foundryOptions.Clone()
        foreach ($key in $change.Keys) { $options[$key] = $change[$key] }
        $inconclusive = Invoke-IdentityOffline $options
        foreach ($test in @('DEV-A-CROSS', 'DEV-B-CROSS', 'DENIED-PROJECT', 'CONSUMER-CROSS')) { Assert-IdentityRow $inconclusive $test 'INCONCLUSIVE'; $checks++ }
    }
    $disabled = Invoke-IdentityOffline @{noLive=$true}
    if ($disabled.report.requests -ne 0 -or $disabled.reads -or $disabled.dns.Count -or $disabled.rows.Count -ne 1) { throw 'Default run performed work' }
    Assert-IdentityRow $disabled 'LIVE' 'BLOCKED'
    $checks++
    $empty = Invoke-IdentityOffline @{emptyAgents=$true; registryEmpty=$true}
    Assert-IdentityRow $empty 'DEV-A-LIST' 'PASS'
    Assert-IdentityRow $empty 'DEV-A-CROSS' 'PASS'
    foreach ($test in @('DEV-A-AGENT-READ', 'CONSUMER-AGENT-READ', 'ACR-A-MANIFEST', 'ACR-A-CROSS', 'ACR-B-CROSS')) { Assert-IdentityRow $empty $test 'BLOCKED'; $checks++ }
    foreach ($options in @(@{positiveStatus=503}, @{positiveStatus=404}, @{listBody='{}'}, @{listBody='<html/>'}, @{throwHttp=$true})) {
        $failed = Invoke-IdentityOffline $options
        foreach ($test in @('DEV-A-CROSS', 'DEV-B-CROSS', 'DENIED-PROJECT', 'CONSUMER-CROSS', 'CONSUMER-AGENT-READ')) { Assert-IdentityRow $failed $test 'BLOCKED'; $checks++ }
        if (@($failed.imds | Where-Object { $_.actor -eq 'consumer-a' }).Count) { throw 'Consumer queried without developer positive' }
    }
    foreach ($dns in @('FAIL', 'INCONCLUSIVE')) {
        $failed = Invoke-IdentityOffline @{dnsVerdict=$dns}
        if ($failed.imds.Count -or $failed.http.Count -or $failed.dns.Count -ne 4) { throw 'DNS gate failed' }
        $checks++
    }
    foreach ($field in @('aud', 'oid', 'tid', 'exp')) {
        $failed = Invoke-IdentityOffline @{tokenActor='dev-a'; tokenClaim=$field}
        Assert-IdentityRow $failed 'DEV-A-LIST' 'BLOCKED'
        Assert-IdentityRow $failed 'DEV-B-CROSS' 'BLOCKED'
        if (@($failed.http | Where-Object { $_.actor -eq 'dev-a' }).Count) { throw 'Bad token used for HTTP' }
        $checks++
    }
    $failedToken = Invoke-IdentityOffline @{tokenActor='dev-a'; throwToken=$true}
    if (@($failedToken.imds | Where-Object { $_.actor -eq 'dev-a' }).Count -ne 1) { throw 'IMDS retried' }
    Assert-IdentityRow $failedToken 'DEV-A-CROSS' 'BLOCKED'
    $checks++
    foreach ($status in @(0, 301, 401, 404, 429, 503)) {
        $failed = Invoke-IdentityOffline @{negativeStatus=$status; registryNegativeStatus=$status}
        foreach ($test in @('DEV-A-CROSS', 'DEV-B-CROSS', 'DENIED-PROJECT', 'CONSUMER-CROSS', 'ACR-A-CROSS', 'ACR-B-CROSS')) { Assert-IdentityRow $failed $test 'INCONCLUSIVE'; $checks++ }
    }
    foreach ($status in @(200, 201, 204, 299)) {
        $failed = Invoke-IdentityOffline @{negativeStatus=$status; registryNegativeStatus=$status}
        foreach ($test in @('DEV-A-CROSS', 'DEV-B-CROSS', 'DENIED-PROJECT', 'CONSUMER-CROSS', 'ACR-A-CROSS', 'ACR-B-CROSS')) { Assert-IdentityRow $failed $test 'FAIL'; $checks++ }
    }
    $networkDenied = Invoke-IdentityOffline @{negativeMessage='Public network access is disabled'; registryNegativeMessage='client IP address is not allowed'}
    foreach ($test in @('DEV-A-CROSS', 'CONSUMER-CROSS', 'ACR-A-CROSS')) {
        Assert-IdentityRow $networkDenied $test 'INCONCLUSIVE'
        if (@($networkDenied.rows | Where-Object { $_.test -eq $test })[0].category -ne 'Network') { throw 'Network plane hidden' }
        $checks++
    }
    foreach ($options in @(@{registryEmpty=$true}, @{tagsStatus=404}, @{tagsStatus=429}, @{manifestStatus=404}, @{badDigest=$true}, @{badManifest=$true}, @{oauthFailure='exchange'}, @{oauthFailure='token'}, @{oauthWrongAudience=$true})) {
        $failed = Invoke-IdentityOffline $options
        foreach ($test in @('ACR-A-CROSS', 'ACR-B-CROSS')) { Assert-IdentityRow $failed $test 'BLOCKED'; $checks++ }
    }
    $crossOAuth = Invoke-IdentityOffline @{oauthFailure='cross'}
    Assert-IdentityRow $crossOAuth 'ACR-A-CROSS' 'BLOCKED'
    Assert-IdentityRow $crossOAuth 'ACR-B-CROSS' 'BLOCKED'
    $checks += 2
    $badAgent = Invoke-IdentityOffline @{badAgentName=$true}
    Assert-IdentityRow $badAgent 'DEV-A-AGENT-READ' 'BLOCKED'
    Assert-IdentityRow $badAgent 'CONSUMER-AGENT-READ' 'BLOCKED'
    $wrongAgent = Invoke-IdentityOffline @{badAgentRead=$true}
    Assert-IdentityRow $wrongAgent 'DEV-A-AGENT-READ' 'FAIL'
    Assert-IdentityRow $wrongAgent 'CONSUMER-AGENT-READ' 'BLOCKED'
    $checks += 4
    $consumerDenied = Invoke-IdentityOffline @{consumerStatus=403}
    Assert-IdentityRow $consumerDenied 'CONSUMER-LIST' 'INCONCLUSIVE'
    Assert-IdentityRow $consumerDenied 'CONSUMER-CROSS' 'BLOCKED'
    $checks += 2
    foreach ($guard in @('badPhase', 'badGroups', 'duplicateActor', 'duplicateClient', 'emptyGuid', 'outsideScope', 'wrongProject', 'wrongCase', 'badHost', 'internalState', 'internalOutputs', 'internalResults', 'collidingResults', 'existingResults', 'missingResults')) {
        $failed = Invoke-IdentityOffline @{$guard=$true}
        if ($failed.imds.Count -or $failed.http.Count -or $failed.dns.Count) { throw 'Input guard permitted requests' }
        Assert-IdentityRow $failed 'HARNESS' 'BLOCKED'
        if ($guard -in @('internalResults', 'collidingResults', 'existingResults', 'missingResults') -and $failed.savedJson) { throw 'Unsafe result destination used' }
        $checks++
    }
    $writeFailure = Invoke-IdentityOffline @{writeFails=$true; noLive=$true}
    Assert-IdentityRow $writeFailure 'RESULTS' 'BLOCKED'
    $checks++
    Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1') -Force
    Assert-PublicText ([IO.File]::ReadAllText($harnessPath))
    Assert-PublicText ([IO.File]::ReadAllText($PSCommandPath))
    Write-Output "PASS: $checks offline identity checks"
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}