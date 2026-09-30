[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    $harnessPath = Join-Path $PSScriptRoot '../scripts/Invoke-RegistryChecks.ps1'
    $parseTokens = $null
    $parseErrors = $null
    $harnessAst = [Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Registry harness syntax is invalid' }
    foreach ($helper in $harnessAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        . ([scriptblock]::Create($helper.Extent.Text))
    }
    $checks = 0
    $image = New-RegistryFixture
    $second = New-RegistryFixture
    $config = [Text.Encoding]::UTF8.GetString($image.configBytes) | ConvertFrom-Json -AsHashtable
    $manifest = [Text.Encoding]::UTF8.GetString($image.manifestBytes) | ConvertFrom-Json -AsHashtable
    if ($image.configDigest -cne $second.configDigest -or $image.manifestDigest -cne $second.manifestDigest -or $image.configBytes.Length -gt 256 -or $image.manifestBytes.Length -gt 512) { throw 'Fixture is not small and deterministic' }
    if ($config.architecture -cne 'amd64' -or $config.os -cne 'linux' -or $config.rootfs.type -cne 'layers' -or $config.rootfs.diff_ids -isnot [array] -or $config.rootfs.diff_ids.Count -or $config.config.Count) { throw 'Invalid scratch image config' }
    if ($manifest.schemaVersion -ne 2 -or $manifest.config.size -ne $image.configBytes.Length -or $manifest.config.digest -cne (Get-RegistryDigest $image.configBytes) -or $manifest.layers -isnot [array] -or $manifest.layers.Count) { throw 'Invalid image manifest' }
    $checks++
    $hostName = 'syntheticregistrya' + '.azurecr.io'
    $uploadPath = '/v2/case-a/test/blobs/uploads/synthetic-upload-01'
    foreach ($location in @($uploadPath, "https://$hostName$uploadPath", "$uploadPath`?_state=opaque%2Bstate%3D")) {
        $resolved = Resolve-RegistryUploadLocation $location $hostName 'case-a/test' $image.configDigest
        if (-not $resolved.StartsWith("https://$hostName$uploadPath") -or -not $resolved.EndsWith('digest=' + [uri]::EscapeDataString($image.configDigest))) { throw 'Upload URI construction failed' }
        if ($location.Contains('_state=') -and -not $resolved.Contains('?_state=opaque%2Bstate%3D&digest=')) { throw 'Upload state was lost or changed' }
        $checks++
    }
    $acrUploadPath = '/v2/case-a/test/blobs/uploads/11111111-1111-4111-8111-111111111111'
    $acrLocations = foreach ($cacheValue in @('false', 'true')) {
        foreach ($queryText in @("_nouploadcache=$cacheValue&_state=opaque%2Bstate%3D", "_state=opaque%2Bstate%3D&_nouploadcache=$cacheValue")) {
            foreach ($prefix in @('', "https://$hostName")) { "$prefix$acrUploadPath`?$queryText" }
        }
    }
    foreach ($location in $acrLocations) {
        $absolute = if ($location.StartsWith('/')) { "https://$hostName$location" } else { $location }
        $resolved = Resolve-RegistryUploadLocation $location $hostName 'case-a/test' $image.configDigest
        if ($resolved -cne ($absolute + '&digest=' + [uri]::EscapeDataString($image.configDigest))) { throw 'ACR upload query was rejected or changed' }
        $checks++
    }
    $invalidQueries = @(
        '_nouploadcache=false', '_nouploadcache=', '_state=', '_state=opaque&_nouploadcache='
        '_state=opaque&_nouploadcache=1', '_state=opaque&_nouploadcache=0', '_state=opaque&_nouploadcache=True', '_state=opaque&_nouploadcache=FALSE'
        '_state=opaque&_nouploadcache=%74rue', '_state=opaque&_nouploadcache=true=false', '_state=opaque&_nouploadcache=false;other=true'
        '_state=opaque&_nouploadcache=true&_nouploadcache=false', '_state=opaque&_nouploadcache=false&_state=other'
        '_state=opaque&_nouploadcache=false&unknown=true', '_state=opaque&_nouploadcache=false&digest=anything'
        '_state=opaque&_NoUploadCache=false', '_state=opaque&%5Fnouploadcache=false', '_state=opaque&%5Fstate=other'
        '_state=opaque&_nouploadcache=false&', '&_state=opaque&_nouploadcache=false', '_state=opaque&&_nouploadcache=false'
        '_state=opaque&_nouploadcache', '_state=opaque&=false', '_state=opaque&_nouploadcache=false?other=true'
        '_state=%', '_state=%2', '_state=%GG', '_state=%FF', '_state=%C0%AF', '_state=%00', '_state=%0D%0A'
        '_state=opaque%26digest%3Dother', '_state=opaque%2526other', '_state=opaque%23fragment', '_state=opaque%20state'
        ('_state=' + ('x' * 1537))
    )
    foreach ($queryText in $invalidQueries) {
        $rejected = $false
        try { $null = Resolve-RegistryUploadLocation "$acrUploadPath`?$queryText" $hostName 'case-a/test' $image.configDigest } catch { $rejected = $true }
        if (-not $rejected) { throw "Unsafe upload query accepted: $queryText" }
        $checks++
    }
    foreach ($location in @('', '//attacker.invalid/upload', "http://$hostName$uploadPath", "https://$hostName.attacker.invalid$uploadPath", "https://$hostName`:444$uploadPath", "https://user@$hostName$uploadPath", "$uploadPath#fragment", "$uploadPath`?digest=anything", "$uploadPath`?mount=anything&from=other", "$uploadPath`?_state=one&_state=two", "$uploadPath`?_state=%ZZ", "$uploadPath`?_state=value&access_token=secret", '/v2/case-b/test/blobs/uploads/id', '/v2/case-a/test/../test/blobs/uploads/id', '/v2/case-a%2Ftest/blobs/uploads/id', '/v2/case-a/test/blobs/uploads/../../manifests/tag', ($uploadPath + "`r`nInjected: value"), ($uploadPath + ('x' * 2048)))) {
        $rejected = $false
        try { $null = Resolve-RegistryUploadLocation $location $hostName 'case-a/test' $image.configDigest } catch { $rejected = $true }
        if (-not $rejected) { throw 'Unsafe Location accepted' }
        $checks++
    }
    $budget = @{requests=0}
    foreach ($attempt in 1..40) { Use-RegistryRequestBudget $budget }
    $rejected = $false
    try { Use-RegistryRequestBudget $budget } catch { $rejected = $true }
    if (-not $rejected -or $budget.requests -ne 40) { throw 'Request budget exceeded' }
    $checks++

    $identityTokens = $null
    $identityErrors = $null
    $identityAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/Invoke-IdentityChecks.ps1'), [ref]$identityTokens, [ref]$identityErrors)
    if ($identityErrors.Count) { throw 'Identity helper syntax invalid' }
    foreach ($helperName in @('Read-IdentityClaims', 'ConvertTo-IdentityProbe')) {
        $definition = $identityAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $helperName }, $true)
        if (-not $definition) { throw 'Expected identity helper missing' }
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    foreach ($status in @(0, 200, 201, 204, 202, 301, 302, 307, 308, 400, 401, 403, 404, 408, 429, 500, 503)) {
        $probe = ConvertTo-IdentityProbe $status '{"errors":[{"code":"DENIED","message":"requested access to the resource is denied"}]}'
        $expected = if ($status -ge 200 -and $status -lt 300) { 'FAIL' } elseif ($status -eq 403) { 'PASS' } else { 'INCONCLUSIVE' }
        if ((Get-RegistryNegativeVerdict $true $probe) -cne $expected -or (Get-RegistryNegativeVerdict $false $probe) -cne 'BLOCKED') { throw 'Negative read proof misclassified' }
        $checks++
    }

    function New-RegistryTestToken([hashtable]$Claims) {
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Claims | ConvertTo-Json -Depth 8 -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return "synthetic.$payload.signature"
    }
    function Get-RegistryTestHash([byte[]]$Bytes) {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { return 'sha256:' + [Convert]::ToHexString($algorithm.ComputeHash($Bytes)).ToLowerInvariant() } finally { $algorithm.Dispose() }
    }
    $expectedConfig = '{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":[]}}'
    if ([Text.Encoding]::UTF8.GetString($image.configBytes) -cne $expectedConfig -or $image.configDigest -cne (Get-RegistryTestHash ([Text.Encoding]::UTF8.GetBytes($expectedConfig)))) { throw 'Fixture byte representation changed' }
    $checks++
    $manifestProbe = @{status=200; digest=$image.manifestDigest; bodyHash=$image.manifestDigest; bodySize=$image.manifestBytes.Length; mediaType='application/vnd.oci.image.manifest.v1+json'; data=$manifest}
    $configProbe = @{status=200; digest=$image.configDigest; bodyHash=$image.configDigest; bodySize=$image.configBytes.Length; data=$config}
    if (-not (Test-RegistryManifest $manifestProbe $image) -or -not (Test-RegistryConfig $configProbe $image)) { throw 'Semantic positive rejected' }
    $checks++
    foreach ($field in @('size', 'digest', 'mediaType')) {
        $altered = $manifestProbe | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        $altered.data.config[$field] = if ($field -ceq 'size') { 999 } else { 'invalid' }
        if (Test-RegistryManifest $altered $image) { throw 'Semantic config descriptor mismatch accepted' }
        $checks++
    }
    foreach ($change in @(@{architecture='invalid'}, @{os='invalid'}, @{config=@{Cmd=@('unexpected')}}, @{rootfs=@{type='layers'; diff_ids=@('unexpected')}})) {
        $altered = $configProbe | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        foreach ($key in $change.Keys) { $altered.data[$key] = $change[$key] }
        if (Test-RegistryConfig $altered $image) { throw 'Invalid config semantics accepted' }
        $checks++
    }
    $boundaryChecks = & {
        $networkCalls = [System.Collections.Generic.List[string]]::new()
        function Send-RegistryHttpRequest { $networkCalls.Add('unexpected'); throw 'Unexpected HTTP at boundary' }
        $boundaryBudget = @{requests=0; targets=@{$hostName='case-a/test'}; image=$image}
        $target = @{hostName=$hostName; repository='case-a/test'}
        $bearer = New-RegistryTestToken @{aud=$hostName; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600; grant_type='access_token'; access=@()}
        $unsafeUris = @("http://$hostName/v2/case-a/test/manifests/fgl-fixture", 'https://attacker.invalid/v2/case-a/test/manifests/fgl-fixture', "https://$hostName.attacker.invalid/v2/case-a/test/manifests/fgl-fixture", "https://$hostName`:443/v2/case-a/test/manifests/fgl-fixture", "https://$hostName/v2/case-b/test/manifests/fgl-fixture", "https://$hostName/v2/case-a/test/manifests/fgl-fixture?access_token=secret", "https://$hostName/v2/case-a/test/../test/manifests/fgl-fixture", "https://$hostName/v2/_catalog")
        foreach ($unsafeUri in $unsafeUris) {
            $probe = Send-RegistryRequest $target $unsafeUri Head $boundaryBudget $bearer
            if ($probe.category -cne 'Boundary') { throw 'HTTP URI allowlist failed' }
        }
        $unlisted = @{hostName=('unlistedregistry' + '.azurecr.io'); repository='case-a/test'}
        $probe = Send-RegistryRequest $unlisted "https://$($unlisted.hostName)/v2/case-a/test/manifests/fgl-fixture" Head $boundaryBudget $bearer
        if ($probe.category -cne 'Boundary') { throw 'Unlisted host accepted' }
        $probe = Send-RegistryRequest $target "https://$hostName/oauth2/token" Post $boundaryBudget -Form @{grant_type='refresh_token'; service=$hostName; scope='repository:case-b/test:pull,push'; refresh_token='secret'}
        if ($probe.category -cne 'Boundary') { throw 'Wrong repository scope accepted' }
        $probe = Send-RegistryRequest $target "https://$hostName/v2/case-a/test/manifests/fgl-fixture" Put $boundaryBudget $bearer -Bytes ([Text.Encoding]::UTF8.GetBytes('{}'))
        if ($probe.category -cne 'Boundary') { throw 'Arbitrary manifest accepted' }
        if ($boundaryBudget.requests -or $networkCalls.Count) { throw 'Disallowed request reached HTTP' }
        $boundaryBudget.requests = 40
        $probe = Send-RegistryRequest $target "https://$hostName/v2/case-a/test/manifests/fgl-fixture" Head $boundaryBudget $bearer
        if ($probe.status -ne 0 -or $boundaryBudget.requests -ne 40 -or $networkCalls.Count) { throw 'Exhausted budget reached HTTP' }
        return $unsafeUris.Count + 4
    }
    $checks += $boundaryChecks
    if (-not ('RegistryRedirectTestHandler' -as [type])) {
        Add-Type -TypeDefinition @'
public class RegistryRedirectTestHandler : System.Net.Http.HttpClientHandler {
    public System.Func<System.Net.Http.HttpRequestMessage, System.Net.Http.HttpResponseMessage> Respond;
    public bool WasDisposed;
    protected override System.Threading.Tasks.Task<System.Net.Http.HttpResponseMessage> SendAsync(System.Net.Http.HttpRequestMessage request, System.Threading.CancellationToken cancellationToken) {
        if (!cancellationToken.CanBeCanceled) throw new System.InvalidOperationException("Missing cancellation");
        return System.Threading.Tasks.Task.FromResult(Respond(request));
    }
    protected override void Dispose(bool disposing) { WasDisposed = true; base.Dispose(disposing); }
}
public class RegistryOfflineStream : System.IO.MemoryStream {
    public int BytesRead;
    public bool CancelRead;
    public bool WasDisposed;
    public RegistryOfflineStream(byte[] bytes) : base(bytes) { }
    public override bool CanSeek { get { return false; } }
    public override System.Threading.Tasks.Task<int> ReadAsync(byte[] buffer, int offset, int count, System.Threading.CancellationToken cancellationToken) {
        if (!cancellationToken.CanBeCanceled) throw new System.InvalidOperationException("Missing body cancellation");
        if (CancelRead) return System.Threading.Tasks.Task.FromCanceled<int>(new System.Threading.CancellationToken(true));
        cancellationToken.ThrowIfCancellationRequested();
        int actual = base.Read(buffer, offset, count);
        BytesRead += actual;
        return System.Threading.Tasks.Task.FromResult(actual);
    }
    protected override void Dispose(bool disposing) { WasDisposed = true; base.Dispose(disposing); }
}
'@
    }
    $harnessRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts'))
    $dnsStub = @'
function Get-IdentityPrivateDns {
    param([string]$HostName)
    if ($HostName -cnotin $fixture.hosts) { $fixture.errors.Add('Unexpected DNS target'); throw 'Unexpected DNS target' }
    $fixture.dns.Add($HostName)
    if ($HostName -ceq $fixture.hosts[0]) { return $fixture.dnsVerdict }
    return 'PASS'
}
'@
    $null = [scriptblock]::Create($dnsStub)
    $loadStatement = '. ([scriptblock]::Create($definitions[0].Extent.Text))'
    if ([regex]::Matches($harnessAst.Extent.Text, [regex]::Escape($loadStatement)).Count -ne 1) { throw 'Identity helper injection boundary changed' }
    $mockedHarness = [scriptblock]::Create($harnessAst.Extent.Text.Replace($loadStatement, '. ([scriptblock]::Create($(if ($helperName -ceq ''Get-IdentityPrivateDns'') { $dnsStub } else { $definitions[0].Extent.Text })))').Replace('$PSScriptRoot', '$harnessRoot'))
    $handlerConstructor = '$handler = [Net.Http.HttpClientHandler]::new()'
    if ([regex]::Matches($harnessAst.Extent.Text, [regex]::Escape($handlerConstructor)).Count -ne 1) { throw 'HTTP handler injection boundary changed' }
    $mockedHarness = [scriptblock]::Create($mockedHarness.ToString().Replace($handlerConstructor, '$handler = New-RegistryMockHandler'))
    $dnsConstructor = '$lookup = [Net.Dns]::GetHostAddressesAsync($HostName)'
    if ([regex]::Matches($harnessAst.Extent.Text, [regex]::Escape($dnsConstructor)).Count -ne 1) { throw 'Data DNS injection boundary changed' }
    $mockedHarness = [scriptblock]::Create($mockedHarness.ToString().Replace($dnsConstructor, '$lookup = Get-RegistryMockDnsTask $HostName'))

    function New-RegistryTestDataLocation([string]$RegistryHost) {
        $dataHost = $RegistryHost.Split('.')[0] + '.swedencentral.data.' + 'azurecr.io'
        return "https://$dataHost/?t=PRIVATE-SENTINEL%2Bsigned%3D&h=synthetic&c=config&r=repository&d=digest&p=path&s=signature&v=1&l=location"
    }

    function Invoke-RegistryOffline([hashtable]$Options = @{}) {
        $state = @{
            subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'
            ownershipId='33333333-3333-4333-8333-333333333333'; labId='sample01'; phase='activate'; deploymentAuthorized=$true; privateAccessVerified=$true
            resourceGroups=@('models', 'integration', 'case-a', 'case-b') | ForEach-Object { "rg-fgl-sample01-$_" }
        }
        $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01"
        $lab = @{
            phase='activate'; resourceGroups=$state.resourceGroups
            identities=@('publisher-a', 'publisher-b') | ForEach-Object {
                @{actor=$_; resourceId="$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/synthetic-$_"; clientId=[guid]::NewGuid().ToString(); principalId=[guid]::NewGuid().ToString()}
            }
            cases=@('a', 'b') | ForEach-Object { @{registryId="$prefix-case-$_/providers/Microsoft.ContainerRegistry/registries/syntheticregistry$_"} }
        }
        $fixture = @{
            state=$state; lab=$lab; hosts=@('a', 'b') | ForEach-Object { "syntheticregistry$_" + '.azurecr.io' }
            reads=0; imports=0; savedJson=$null; dnsVerdict='PASS'; issued=@{}; stored=@{}; pulled=@{}
            statePath=(Join-Path ([IO.Path]::GetTempPath()) "registry-$([guid]::NewGuid().ToString('N'))-state.json")
            outputsPath=(Join-Path ([IO.Path]::GetTempPath()) "registry-$([guid]::NewGuid().ToString('N'))-outputs.json")
            resultsPath=(Join-Path ([IO.Path]::GetTempPath()) "registry-$([guid]::NewGuid().ToString('N'))-results.json")
            http=[System.Collections.Generic.List[object]]::new(); imds=[System.Collections.Generic.List[object]]::new(); dns=[System.Collections.Generic.List[string]]::new()
            errors=[System.Collections.Generic.List[string]]::new(); secrets=[System.Collections.Generic.List[string]]::new()
            imdsClaim=''; imdsValue=$null; imdsType='Bearer'; malformedImds=$false; oauthFailure=''; oauthClaim=''; oauthValue=$null; refreshAsAccess=$false
            location=$null; faultStep=''; faultStatus=0; badDigest=''; badHeadSize=$false; badManifest=$false; badConfig=$false; badMediaType=$false
            redirect=$true; dataLocation=$null; dataStatus=200; dataAddresses=@('10.0.0.4', '172.16.0.5', '192.168.1.6'); throwDataDns=$false
            duplicateDataLocation=$false; dataBodySize=0; dataDeclaredSize=0; cancelDataRead=$false; throwDataHttp=$false; omitDataDigest=$false; sameSizeBadConfig=$false
            streams=[Collections.Generic.List[object]]::new(); handlers=[Collections.Generic.List[object]]::new()
            negativeStatus=403; negativeCode='DENIED'; negativeMessage='requested access to the resource is denied'
            throwHttp=$false; throwImds=$false; throwRead=$false; writeFails=$false
        }
        foreach ($key in $Options.Keys) { $fixture[$key] = $Options[$key] }
        if ($Options.badPhase) { $state.phase = 'lock' }
        if ($Options.badLabPhase) { $lab.phase = 'lock' }
        if ($Options.pendingPhase) { $state.pendingPhase = 'activate' }
        if ($Options.unauthorized) { $state.deploymentAuthorized = $false }
        if ($Options.unverified) { $state.privateAccessVerified = $false }
        if ($Options.stringAuthorization) { $state.deploymentAuthorized = 'true' }
        if ($Options.badGroups) { $lab.resourceGroups = @('unowned') }
        if ($Options.badOwnership) { $state.ownershipId = [guid]::Empty.ToString() }
        if ($Options.badCase) { $lab.cases[0].registryId = $lab.cases[1].registryId }
        if ($Options.outsideScope) { $lab.cases[0].registryId = $lab.cases[0].registryId.Replace('case-a', 'outside') }
        if ($Options.badHost) { $lab.cases[0].registryId += '.attacker.invalid' }
        if ($Options.badLoginServer) { $lab.cases[0].registryLoginServer = 'attacker.invalid' }
        if ($Options.duplicateActor) { $lab.identities[1] = $lab.identities[0] }
        if ($Options.duplicateClient) { $lab.identities[1].clientId = $lab.identities[0].clientId }
        if ($Options.duplicatePrincipal) { $lab.identities[1].principalId = $lab.identities[0].principalId }
        if ($Options.emptyPrincipal) { $lab.identities[0].principalId = [guid]::Empty.ToString() }
        if ($Options.badIdentityParent) { $lab.identities[0].resourceId = $lab.identities[0].resourceId.Replace('integration', 'case-a') }
        if ($Options.internalState) { $fixture.statePath = Join-Path $harnessRoot 'synthetic-state.json' }
        if ($Options.internalOutputs) { $fixture.outputsPath = Join-Path $harnessRoot 'synthetic-outputs.json' }
        if ($Options.internalResults) { $fixture.resultsPath = Join-Path $harnessRoot 'synthetic-results.json' }
        if ($Options.collidingResults) { $fixture.resultsPath = $fixture.statePath }
        if ($Options.existingResults) { $fixture.resultsPath = $harnessPath }
        if ($Options.sameInputs) { $fixture.outputsPath = $fixture.statePath }
        if ($Options.missingResults) { $fixture.resultsPath = '' }
        if ($Options.missingParent) { $fixture.resultsPath = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString('N'))/results.json" }

        function Assert-RegistryMock([bool]$Condition, [string]$Message) {
            if (-not $Condition) { $fixture.errors.Add($Message); throw $Message }
        }
        function Import-Module {
            [CmdletBinding()]
            param([string]$Name, [switch]$Force)
            $fixture.imports++
            Microsoft.PowerShell.Core\Import-Module @PSBoundParameters
        }
        function Get-Content {
            [CmdletBinding()]
            param([string]$LiteralPath, [switch]$Raw)
            $fixture.reads++
            if ($fixture.throwRead) { throw 'PRIVATE-SENTINEL' }
            if ($LiteralPath -eq $fixture.statePath) { return $fixture.state | ConvertTo-Json -Depth 12 }
            if ($LiteralPath -eq $fixture.outputsPath) { return $fixture.lab | ConvertTo-Json -Depth 12 }
            Assert-RegistryMock $false 'Unexpected file read'
        }
        function Invoke-RestMethod {
            [CmdletBinding()]
            param([uri]$Uri, [hashtable]$Headers, [switch]$NoProxy, [int]$TimeoutSec, [int]$OperationTimeoutSeconds, [int]$MaximumRedirection, [int]$MaximumRetryCount)
            Assert-RegistryMock ($Uri.Scheme -ceq 'http' -and $Uri.Host -ceq '169.254.169.254' -and $Uri.Port -eq 80 -and $Uri.AbsolutePath -ceq '/metadata/identity/oauth2/token' -and $Headers.Count -eq 1 -and $Headers.Metadata -ceq 'true') 'Unexpected IMDS request'
            Assert-RegistryMock ($NoProxy -and $TimeoutSec -eq 20 -and $OperationTimeoutSeconds -eq 20 -and $PSBoundParameters.ContainsKey('MaximumRedirection') -and $MaximumRedirection -eq 0 -and $PSBoundParameters.ContainsKey('MaximumRetryCount') -and $MaximumRetryCount -eq 0 -and -not $PSBoundParameters.Verbose -and -not $PSBoundParameters.Debug) 'Unsafe IMDS options'
            $query = [Web.HttpUtility]::ParseQueryString($Uri.Query)
            $actors = @($lab.identities | Where-Object { $_.clientId -ceq $query['client_id'] })
            Assert-RegistryMock ($query.Count -eq 3 -and $query['api-version'] -ceq '2018-02-01' -and $query['resource'] -ceq 'https://containerregistry.azure.net' -and $actors.Count -eq 1) 'Wrong IMDS selector or audience'
            $actor = $actors[0]
            $fixture.imds.Add(@{actor=$actor.actor; audience=$query['resource']})
            if ($fixture.throwImds) { throw 'PRIVATE-SENTINEL' }
            $claims = @{tid=$state.tenantId; oid=$actor.principalId; appid=$actor.clientId; xms_mirid=$actor.resourceId; aud=$query['resource']; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600; nbf=0}
            if ($fixture.imdsClaim) { $claims[$fixture.imdsClaim] = $fixture.imdsValue }
            $token = if ($fixture.malformedImds) { 'PRIVATE-SENTINEL' } else { New-RegistryTestToken $claims }
            $fixture.issued[$token] = @{kind='Entra'; actor=$actor.actor}
            $fixture.secrets.Add($token)
            return @{token_type=$fixture.imdsType; access_token=$token}
        }
        function New-RegistryMockResponse([int]$Status, [object]$Content='', [hashtable]$Headers=@{}) {
            return @{StatusCode=$Status; Content=$Content; Headers=$Headers}
        }
        function Get-RegistryMockDnsTask([string]$HostName) {
            $expectedHosts = @($fixture.hosts | ForEach-Object { $_.Split('.')[0] + '.swedencentral.data.' + 'azurecr.io' })
            Assert-RegistryMock ($HostName -cin $expectedHosts) 'Unexpected data DNS target'
            $fixture.dns.Add($HostName)
            if ($fixture.throwDataDns) { throw 'PRIVATE-SENTINEL' }
            [Net.IPAddress[]]$addresses = @($fixture.dataAddresses | ForEach-Object { [Net.IPAddress]::Parse($_) })
            return [Threading.Tasks.Task]::FromResult($addresses)
        }
        function New-RegistryMockHandler {
            $handler = [RegistryRedirectTestHandler]::new()
            $fixture.handlers.Add($handler)
            $handler.Respond = {
                param($Request)
                Assert-RegistryMock (-not $handler.AllowAutoRedirect -and -not $handler.UseProxy -and -not $handler.UseCookies -and $handler.MaxResponseHeadersLength -eq 16 -and $client.Timeout.TotalSeconds -eq 20) 'Unsafe HttpClient configuration'
                $headers = @{}
                foreach ($header in $Request.Headers) { $headers[$header.Key] = [string]($header.Value -join ', ') }
                $parameters = @{Uri=$Request.RequestUri; Method=(Get-Culture).TextInfo.ToTitleCase($Request.Method.Method.ToLowerInvariant()); Headers=$headers}
                if ($null -ne $Request.Content) {
                    $parameters.ContentType = $Request.Content.Headers.ContentType.MediaType
                    if ($parameters.ContentType -ceq 'application/x-www-form-urlencoded') {
                        $query = [Web.HttpUtility]::ParseQueryString($Request.Content.ReadAsStringAsync().GetAwaiter().GetResult())
                        $parameters.Body = @{}
                        foreach ($key in $query.AllKeys) { $parameters.Body[$key] = $query[$key] }
                    } else { $parameters.Body = $Request.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() }
                }
                $mock = Invoke-RegistryMockRequest @parameters
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$mock.StatusCode)
                [byte[]]$bytes = @()
                if ($mock.Content -is [byte[]]) { $bytes = $mock.Content } else { $bytes = [Text.Encoding]::UTF8.GetBytes([string]$mock.Content) }
                $stream = [RegistryOfflineStream]::new([byte[]]$bytes)
                $isData = $Request.RequestUri.Host.EndsWith('.swedencentral.data.' + 'azurecr.io')
                $stream.CancelRead = $isData -and $fixture.cancelDataRead
                $fixture.streams.Add(@{stream=$stream; isData=$isData; method=$parameters.Method; status=$mock.StatusCode})
                $response.Content = [Net.Http.StreamContent]::new($stream)
                foreach ($key in $mock.Headers.Keys) {
                    if (-not $response.Headers.TryAddWithoutValidation($key, [string[]]$mock.Headers[$key])) { $null = $response.Content.Headers.TryAddWithoutValidation($key, [string[]]$mock.Headers[$key]) }
                }
                return $response
            }
            return $handler
        }
        function Invoke-RegistryMockRequest {
            [CmdletBinding()]
            param([uri]$Uri, [string]$Method, [hashtable]$Headers, [object]$Body, [string]$ContentType)
            $dataHosts = @($fixture.hosts | ForEach-Object { $_.Split('.')[0] + '.swedencentral.data.' + 'azurecr.io' })
            if ($Uri.Host -cin $dataHosts) {
                $label = if ($Uri.Host -ceq $dataHosts[0]) { 'a' } else { 'b' }
                $expectedLocation = if ($null -ne $fixture.dataLocation -and $label -ceq 'a') { $fixture.dataLocation } else { New-RegistryTestDataLocation $fixture.hosts[$dataHosts.IndexOf($Uri.Host)] }
                Assert-RegistryMock ($Uri.AbsoluteUri -ceq ([uri]$expectedLocation).AbsoluteUri -and $Uri.Query -ceq ([uri]$expectedLocation).Query -and $Method -ceq 'Get' -and $Headers.Count -eq 1 -and $Headers.Accept -ceq 'application/octet-stream' -and $null -eq $Body -and -not $ContentType -and $fixture.dns.Contains($Uri.Host)) 'Unsafe redirected config request or forwarded credentials'
                Assert-RegistryMock ($fixture.stored.ContainsKey("$label-config") -and $fixture.stored.ContainsKey("$label-manifest")) 'Data GET preceded publication'
                $fixture.http.Add(@{host=$Uri.Host; path=$Uri.AbsolutePath; query=$Uri.Query; method=$Method; actor=$null})
                Assert-RegistryMock ($fixture.http.Count + $fixture.imds.Count + $fixture.dns.Count -le 40) 'Combined operation limit exceeded'
                if ($fixture.throwDataHttp) { throw 'PRIVATE-SENTINEL' }
                if ($fixture.dataStatus -ne 200) { return New-RegistryMockResponse $fixture.dataStatus 'PRIVATE-SENTINEL' @{Location=$expectedLocation} }
                $fixture.pulled[$label] = $true
                [byte[]]$bytes = if ($fixture.badConfig) { [Text.Encoding]::UTF8.GetBytes('{"private":"PRIVATE-SENTINEL"}') } else { $fixture.stored["$label-config"] }
                if ($fixture.dataBodySize) { $bytes = [byte[]]::new($fixture.dataBodySize) }
                if ($fixture.sameSizeBadConfig) { $bytes = $bytes.Clone(); $bytes[0] = [byte][char]'[' }
                $digest = if ($fixture.badDigest -ceq 'config') { 'sha256:' + ('0' * 64) } else { $image.configDigest }
                $responseHeaders = @{}
                if (-not $fixture.omitDataDigest) { $responseHeaders['Docker-Content-Digest'] = $digest }
                if ($fixture.dataDeclaredSize) { $responseHeaders['Content-Length'] = [string]$fixture.dataDeclaredSize }
                return New-RegistryMockResponse 200 $bytes $responseHeaders
            }
            Assert-RegistryMock ($Uri.Scheme -ceq 'https' -and $Uri.Host -cin $fixture.hosts -and $Uri.Port -eq 443 -and -not $Uri.UserInfo -and -not $Uri.Fragment) 'Unsafe registry target'
            $label = if ($Uri.Host -ceq $fixture.hosts[0]) { 'a' } else { 'b' }
            $repository = "case-$label/test"
            $root = "/v2/$repository"
            $token = ([string]$Headers.Authorization) -replace '^Bearer ', ''
            $identity = if ($token) { $fixture.issued[$token] } else { $null }
            $fixture.http.Add(@{host=$Uri.Host; path=$Uri.AbsolutePath; query=$Uri.Query; method=$Method; actor=$identity.actor})
            Assert-RegistryMock ($fixture.http.Count + $fixture.imds.Count + $fixture.dns.Count -le 40) 'Combined operation limit exceeded'
            if ($fixture.throwHttp) { throw 'PRIVATE-SENTINEL' }
            if ($Uri.AbsolutePath.StartsWith('/oauth2/')) {
                Assert-RegistryMock ($Method -ceq 'Post' -and $ContentType -ceq 'application/x-www-form-urlencoded' -and -not $token -and -not $Uri.Query -and $Body -is [hashtable] -and $Body.Count -eq 4 -and $Body.service -ceq $Uri.Host) 'Unsafe OAuth form'
                if ($Uri.AbsolutePath -ceq '/oauth2/exchange') {
                    $source = $fixture.issued[$Body.access_token]
                    Assert-RegistryMock ($source.kind -ceq 'Entra' -and $Body.grant_type -ceq 'access_token' -and $Body.tenant -ceq $state.tenantId) 'OAuth exchange did not use Entra access token'
                    $cross = $source.actor -cne "publisher-$label"
                    if ($cross) { Assert-RegistryMock ($fixture.pulled.a -and $fixture.pulled.b) 'Cross OAuth preceded both complete positive cycles' }
                    if ($fixture.oauthFailure -ceq 'exchange' -or ($cross -and $fixture.oauthFailure -ceq 'cross-exchange')) { return New-RegistryMockResponse 403 '{"errors":[{"code":"DENIED","message":"requested access to the resource is denied"}]}' }
                    $refreshToken = New-RegistryTestToken @{aud=$Uri.Host; sub=$source.actor; grant_type='refresh_token'; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600}
                    $fixture.issued[$refreshToken] = @{kind='Refresh'; host=$Uri.Host; actor=$source.actor}
                    $fixture.secrets.Add($refreshToken)
                    return New-RegistryMockResponse 200 (@{refresh_token=$refreshToken} | ConvertTo-Json -Compress)
                }
                $source = $fixture.issued[$Body.refresh_token]
                $cross = $source.actor -cne "publisher-$label"
                $actions = if ($cross) { 'pull' } else { 'pull,push' }
                Assert-RegistryMock ($Uri.AbsolutePath -ceq '/oauth2/token' -and $source.kind -ceq 'Refresh' -and $source.host -ceq $Uri.Host -and $Body.grant_type -ceq 'refresh_token' -and $Body.scope -ceq "repository:${repository}:$actions") 'Refresh token or OAuth scope invalid'
                if ($fixture.oauthFailure -ceq 'token' -or ($cross -and $fixture.oauthFailure -ceq 'cross-token')) { return New-RegistryMockResponse 403 '{"errors":[{"code":"DENIED","message":"requested access to the resource is denied"}]}' }
                $access = @()
                if (-not $cross) { $access = @(@{type='repository'; name=$repository; actions=@('pull', 'push')}) }
                $claims = @{aud=$Uri.Host; sub=$source.actor; grant_type='access_token'; access=$access; exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600}
                if ($fixture.oauthClaim) { $claims[$fixture.oauthClaim] = $fixture.oauthValue }
                $accessToken = if ($fixture.refreshAsAccess) { $Body.refresh_token } else { New-RegistryTestToken $claims }
                if (-not $fixture.refreshAsAccess) { $fixture.issued[$accessToken] = @{kind='Access'; host=$Uri.Host; actor=$source.actor} }
                $fixture.secrets.Add($accessToken)
                return New-RegistryMockResponse 200 (@{access_token=$accessToken} | ConvertTo-Json -Depth 8 -Compress)
            }
            Assert-RegistryMock ($identity.kind -ceq 'Access' -and $identity.host -ceq $Uri.Host -and $Headers.Authorization -ceq "Bearer $token") 'Non-access or wrong-host bearer used'
            if ($identity.actor -cne "publisher-$label") {
                Assert-RegistryMock ($fixture.pulled.a -and $fixture.pulled.b -and $Method -ceq 'Get' -and $Uri.AbsolutePath -ceq "$root/manifests/$($image.manifestDigest)" -and -not $Uri.Query -and $null -eq $Body -and $Headers.Accept -ceq 'application/vnd.oci.image.manifest.v1+json') 'Cross read lacks same-operation positive or pinned target'
                return New-RegistryMockResponse $fixture.negativeStatus (@{errors=@(@{code=$fixture.negativeCode; message=$fixture.negativeMessage; detail='PRIVATE-SENTINEL'})} | ConvertTo-Json -Depth 5 -Compress)
            }
            $step = if ($Method -ceq 'Post') { 'start' } elseif ($Method -ceq 'Put' -and $Uri.AbsolutePath.Contains('/blobs/uploads/')) { 'upload' } elseif ($Method -ceq 'Put') { 'publish' } elseif ($Method -ceq 'Head') { 'head' } elseif ($Uri.AbsolutePath.Contains('/manifests/')) { 'manifest' } else { 'config' }
            if ($fixture.faultStep -ceq $step) { return New-RegistryMockResponse $fixture.faultStatus 'PRIVATE-SENTINEL' @{Location='https://attacker.invalid/PRIVATE-SENTINEL'} }
            if ($step -ceq 'start') {
                Assert-RegistryMock ($Uri.AbsolutePath -ceq "$root/blobs/uploads/" -and -not $Uri.Query -and $Body -is [byte[]] -and $Body.Length -eq 0 -and $ContentType -ceq 'application/octet-stream') 'Invalid upload POST or unwanted mount'
                $location = if ($null -ne $fixture.location -and $label -ceq 'a') { $fixture.location } else { "$root/blobs/uploads/synthetic-upload-01?_state=opaque%2Bstate%3D" }
                return New-RegistryMockResponse 202 '' @{Location=$location}
            }
            if ($step -ceq 'upload') {
                $query = [Web.HttpUtility]::ParseQueryString($Uri.Query)
                $expectedLocation = if ($null -ne $fixture.location -and $label -ceq 'a') { $fixture.location } else { "$root/blobs/uploads/synthetic-upload-01?_state=opaque%2Bstate%3D" }
                $expectedAbsolute = if ($expectedLocation.StartsWith('/')) { "https://$($Uri.Host)$expectedLocation" } else { $expectedLocation }
                Assert-RegistryMock ($Uri.OriginalString -ceq ($expectedAbsolute + '&digest=' + [uri]::EscapeDataString($image.configDigest)) -and $query['_state'] -ceq 'opaque+state=' -and $query['digest'] -ceq $image.configDigest -and $Body -is [byte[]] -and $ContentType -ceq 'application/octet-stream') 'Unsafe blob upload request'
                Assert-RegistryMock ([Text.Encoding]::UTF8.GetString($Body) -ceq $expectedConfig -and (Get-RegistryTestHash $Body) -ceq $query['digest']) 'Blob bytes or digest incorrect'
                $fixture.stored["$label-config"] = $Body
                $digest = if ($fixture.badDigest -ceq 'upload') { 'sha256:' + ('0' * 64) } else { Get-RegistryTestHash $Body }
                return New-RegistryMockResponse 201 '' @{'Docker-Content-Digest'=$digest}
            }
            if ($step -ceq 'publish') {
                Assert-RegistryMock ($Uri.AbsolutePath -ceq "$root/manifests/fgl-fixture" -and -not $Uri.Query -and $ContentType -ceq 'application/vnd.oci.image.manifest.v1+json' -and $Body -is [byte[]] -and $fixture.stored.ContainsKey("$label-config")) 'Manifest PUT before config or wrong request'
                $manifest = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -AsHashtable
                Assert-RegistryMock ($manifest.schemaVersion -eq 2 -and $manifest.config.digest -ceq (Get-RegistryTestHash $fixture.stored["$label-config"]) -and $manifest.config.size -eq $fixture.stored["$label-config"].Length -and $manifest.layers -is [array] -and $manifest.layers.Count -eq 0 -and (Get-RegistryTestHash $Body) -ceq $image.manifestDigest) 'Manifest/config contract invalid'
                $fixture.stored["$label-manifest"] = $Body
                $digest = if ($fixture.badDigest -ceq 'publish') { 'sha256:' + ('0' * 64) } else { Get-RegistryTestHash $Body }
                return New-RegistryMockResponse 201 '' @{'Docker-Content-Digest'=$digest}
            }
            Assert-RegistryMock ($null -eq $Body -and -not $Uri.Query -and $fixture.stored.ContainsKey("$label-manifest")) 'Unexpected read body or pull before publish'
            if ($step -cin @('head', 'manifest')) {
                Assert-RegistryMock ($Headers.Accept -ceq 'application/vnd.oci.image.manifest.v1+json') 'Manifest Accept header missing'
                $digest = if ($fixture.badDigest -ceq $step) { 'sha256:' + ('0' * 64) } else { $image.manifestDigest }
                $length = if ($fixture.badHeadSize) { 9999 } else { $image.manifestBytes.Length }
                $responseHeaders = @{'Docker-Content-Digest'=$digest; 'Content-Length'=[string]$length; 'Content-Type'='application/vnd.oci.image.manifest.v1+json'}
                if ($fixture.badMediaType) { $responseHeaders['Content-Type'] = 'text/html' }
                if ($step -ceq 'head') {
                    Assert-RegistryMock ($Uri.AbsolutePath -ceq "$root/manifests/fgl-fixture") 'Unexpected HEAD reference'
                    return New-RegistryMockResponse 200 '' $responseHeaders
                }
                Assert-RegistryMock ($Uri.AbsolutePath -ceq "$root/manifests/$($image.manifestDigest)") 'Manifest GET not digest pinned'
                [byte[]]$bytes = if ($fixture.badManifest) { [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":2,"layers":[],"private":"PRIVATE-SENTINEL"}') } else { $fixture.stored["$label-manifest"] }
                return New-RegistryMockResponse 200 $bytes $responseHeaders
            }
            Assert-RegistryMock ($Method -ceq 'Get' -and $Uri.AbsolutePath -ceq "$root/blobs/$($image.configDigest)" -and $Headers.Accept -ceq 'application/octet-stream') 'Config GET not digest pinned'
            if ($fixture.redirect) {
                $location = if ($null -ne $fixture.dataLocation -and $label -ceq 'a') { $fixture.dataLocation } else { New-RegistryTestDataLocation $Uri.Host }
                $fixture.secrets.Add($location)
                $fixture.secrets.Add(([uri]$location).Query)
                if ($fixture.duplicateDataLocation -and $label -ceq 'a') { return New-RegistryMockResponse 307 '' @{Location=@($location, $location)} }
                return New-RegistryMockResponse 307 '' @{Location=$location}
            }
            $fixture.pulled[$label] = $true
            [byte[]]$bytes = if ($fixture.badConfig) { [Text.Encoding]::UTF8.GetBytes('{"private":"PRIVATE-SENTINEL"}') } else { $fixture.stored["$label-config"] }
            $digest = if ($fixture.badDigest -ceq 'config') { 'sha256:' + ('0' * 64) } else { $image.configDigest }
            return New-RegistryMockResponse 200 $bytes @{'Docker-Content-Digest'=$digest}
        }
        function Out-File {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, [string]$LiteralPath, [string]$Encoding, [switch]$NoClobber)
            process {
                Assert-RegistryMock ($LiteralPath -ceq $fixture.resultsPath -and $Encoding -ceq 'utf8' -and $NoClobber) 'Unsafe report persistence'
                if ($fixture.writeFails) { throw 'PRIVATE-SENTINEL' }
                $fixture.savedJson = [string]$InputObject
            }
        }
        $arguments = @{StatePath=$fixture.statePath; OutputsPath=$fixture.outputsPath; ResultsPath=$fixture.resultsPath; RunLive=(-not $Options.noLive); Verbose=$true; Debug=$true}
        $captured = @(& $mockedHarness @arguments *>&1)
        if ($fixture.errors.Count) { throw ($fixture.errors -join '; ') }
        $text = ($captured | ConvertTo-Json -Depth 15 -Compress) + $fixture.savedJson
        $dataHosts = @($fixture.hosts | ForEach-Object { $_.Split('.')[0] + '.swedencentral.data.' + 'azurecr.io' })
        foreach ($secret in @('PRIVATE-SENTINEL', 'opaque+state=', 'opaque%2Bstate%3D') + $fixture.hosts + $dataHosts + $fixture.secrets.ToArray() + @($lab.identities.clientId) + @($lab.identities.principalId) + @($state.subscriptionId, $state.tenantId, $state.ownershipId, $fixture.statePath, $fixture.outputsPath, $fixture.resultsPath)) {
            if ($secret -and ($text.Contains($secret) -or $text.Contains(($secret | ConvertTo-Json -Compress).Trim('"')))) { throw 'Private evidence escaped the registry harness' }
        }
        $fixture.rows = @($captured | Where-Object { $_ -isnot [string] -and $_.PSObject.Properties.Name -contains 'test' })
        if ($fixture.savedJson) {
            $fixture.report = $fixture.savedJson | ConvertFrom-Json -AsHashtable
            if ($fixture.report.requests -ne $fixture.http.Count + $fixture.imds.Count -or $fixture.report.requests -gt 40 -or $fixture.report.requestLimit -ne 40 -or $fixture.report.dnsQueries -ne $fixture.dns.Count) { throw 'Request accounting mismatch' }
            if ($fixture.report.operations -ne $fixture.report.requests + $fixture.report.dnsQueries -or $fixture.report.operations -gt 40 -or $fixture.report.operationLimit -ne 40) { throw 'Combined HTTP and DNS accounting mismatch' }
            if ($fixture.report.tests.Count -ne $fixture.rows.Count -or @($fixture.report.tests | Where-Object { $_.status -cnotin @('PASS', 'FAIL', 'BLOCKED', 'INCONCLUSIVE') }).Count) { throw 'Invalid report checks' }
        }
        foreach ($handler in $fixture.handlers) { if (-not $handler.WasDisposed) { throw 'HTTP handler leaked' } }
        foreach ($entry in $fixture.streams) {
            if (-not $entry.stream.WasDisposed -or $entry.stream.BytesRead -gt 65537) { throw 'Response stream leaked or exceeded bounded overflow detection' }
            if (($entry.method -ceq 'Head' -or ($entry.status -ge 300 -and $entry.status -lt 400)) -and $entry.stream.BytesRead) { throw 'HEAD or redirect body was consumed' }
        }
        return $fixture
    }

    function Assert-RegistryRow([hashtable]$Run, [string]$Test, [string]$Status) {
        $rows = @($Run.rows | Where-Object { $_.test -ceq $Test })
        if ($rows.Count -ne 1 -or $rows[0].status -cne $Status) { throw "Unexpected verdict for $Test; expected $Status; actual: $($Run.rows | ConvertTo-Json -Compress)" }
    }
    $positive = Invoke-RegistryOffline
    if ($positive.report.requests -ne 26 -or $positive.imds.Count -ne 2 -or $positive.http.Count -ne 24 -or $positive.dns.Count -ne 4 -or $positive.report.operations -ne 30 -or $positive.rows.Count -ne 14 -or @($positive.rows | Where-Object status -CEQ 'PASS').Count -ne 10 -or @($positive.rows | Where-Object status -CEQ 'BLOCKED').Count -ne 4) { throw "Positive cycle counts wrong: $($positive.rows | ConvertTo-Json -Compress)" }
    foreach ($label in @('A', 'B')) {
        foreach ($operation in @('IMDS', 'PUSH', 'PULL', 'CROSS-READ')) { Assert-RegistryRow $positive "ACR-$label-$operation" 'PASS' }
        Assert-RegistryRow $positive "ACR-$label-ABAC-WRITE" 'BLOCKED'
    }
    Assert-RegistryRow $positive 'ACR-PROJECT-PULL' 'BLOCKED'
    Assert-RegistryRow $positive 'ACR-HOSTED-PROOF' 'BLOCKED'
    $checks++
    foreach ($location in $acrLocations) {
        $run = Invoke-RegistryOffline @{location=$location}
        foreach ($label in @('A', 'B')) {
            foreach ($operation in @('PUSH', 'PULL', 'CROSS-READ')) { Assert-RegistryRow $run "ACR-$label-$operation" 'PASS' }
        }
        if ($run.report.requests -ne 26) { throw 'ACR upload query changed the request count' }
        $checks++
    }
    foreach ($queryText in $invalidQueries) {
        $run = Invoke-RegistryOffline @{location="$acrUploadPath`?$queryText"}
        Assert-RegistryRow $run 'ACR-A-PUSH' 'FAIL'
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
        if (@($run.http | Where-Object { $_.host -ceq $run.hosts[0] -and $_.method -ceq 'Put' }).Count) { throw 'Unsafe upload query reached HTTP' }
        $checks++
    }
    $noLive = Invoke-RegistryOffline @{noLive=$true}
    if ($noLive.reads -or $noLive.imports -or $noLive.http.Count -or $noLive.imds.Count -or $noLive.dns.Count -or $noLive.savedJson -or $noLive.rows.Count -ne 1) { throw 'I/O occurred without RunLive' }
    Assert-RegistryRow $noLive 'LIVE' 'BLOCKED'
    $checks++
    foreach ($option in @('badPhase', 'badLabPhase', 'pendingPhase', 'unauthorized', 'unverified', 'stringAuthorization', 'badGroups', 'badOwnership', 'badCase', 'outsideScope', 'badHost', 'badLoginServer', 'duplicateActor', 'duplicateClient', 'duplicatePrincipal', 'emptyPrincipal', 'badIdentityParent', 'internalState', 'internalOutputs', 'internalResults', 'collidingResults', 'existingResults', 'sameInputs', 'missingResults', 'missingParent', 'throwRead')) {
        $run = Invoke-RegistryOffline @{$option=$true}
        Assert-RegistryRow $run 'HARNESS' 'BLOCKED'
        if ($run.http.Count -or $run.imds.Count -or $run.dns.Count) { throw 'Invalid prerequisite reached network' }
        $checks++
    }
    foreach ($change in @(@{aud='https://management.azure.com/'}, @{tid='wrong'}, @{tid=@('22222222-2222-4222-8222-222222222222')}, @{oid='wrong'}, @{appid='wrong'}, @{appid=$null}, @{azp='wrong'}, @{azp=@()}, @{xms_mirid='wrong'}, @{xms_mirid=$null}, @{exp=0}, @{exp=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+30)}, @{nbf=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600)}, @{aud=@('https://containerregistry.azure.net')})) {
        $claim = @($change.Keys)[0]
        $run = Invoke-RegistryOffline @{imdsClaim=$claim; imdsValue=$change[$claim]}
        Assert-RegistryRow $run 'ACR-A-IMDS' 'BLOCKED'
        if ($run.http.Count -or $run.imds.Count -ne 2) { throw 'Invalid IMDS token reached registry' }
        $checks++
    }
    foreach ($options in @(@{malformedImds=$true}, @{imdsType='Basic'}, @{throwImds=$true}, @{oauthFailure='exchange'}, @{oauthFailure='token'}, @{oauthClaim='aud'; oauthValue='wrong'}, @{oauthClaim='grant_type'; oauthValue='refresh_token'}, @{oauthClaim='grant_type'; oauthValue=@('access_token')}, @{oauthClaim='exp'; oauthValue=0}, @{oauthClaim='access'; oauthValue=@{}}, @{refreshAsAccess=$true}, @{throwHttp=$true})) {
        $run = Invoke-RegistryOffline $options
        Assert-RegistryRow $run 'ACR-A-PUSH' 'BLOCKED'
        if (@($run.http | Where-Object { $_.path.StartsWith('/v2/') }).Count) { throw 'Invalid OAuth token reached OCI endpoint' }
        $checks++
    }
    foreach ($dnsVerdict in @('FAIL', 'INCONCLUSIVE')) {
        $run = Invoke-RegistryOffline @{dnsVerdict=$dnsVerdict}
        Assert-RegistryRow $run 'DNS-ACR-A' $dnsVerdict
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
        if (@($run.http | Where-Object host -CEQ $run.hosts[0]).Count -or $run.imds.Count -ne 1) { throw 'Nonprivate DNS reached registry or IMDS' }
        $checks++
    }
    foreach ($options in @(@{badDigest='upload'}, @{badDigest='publish'}, @{location='https://attacker.invalid/PRIVATE-SENTINEL'}, @{location='/v2/case-b/test/blobs/uploads/synthetic-upload-01'}, @{location='/v2/case-a/test/blobs/uploads/id?digest=other'})) {
        $run = Invoke-RegistryOffline $options
        Assert-RegistryRow $run 'ACR-A-PUSH' 'FAIL'
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
        if ($options.location -and @($run.http | Where-Object { $_.host -ceq $run.hosts[0] -and $_.method -ceq 'Put' }).Count) { throw 'Unsafe Location followed' }
        $checks++
    }
    foreach ($options in @(@{badDigest='head'}, @{badDigest='manifest'}, @{badDigest='config'}, @{badHeadSize=$true}, @{badManifest=$true}, @{badConfig=$true}, @{badMediaType=$true})) {
        $run = Invoke-RegistryOffline $options
        Assert-RegistryRow $run 'ACR-A-PULL' 'FAIL'
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
        $checks++
    }
    foreach ($step in @('start', 'upload', 'publish', 'head', 'manifest', 'config')) {
        foreach ($status in @(302, 404, 429, 503)) {
            $run = Invoke-RegistryOffline @{faultStep=$step; faultStatus=$status}
            $operation = if ($step -cin @('start', 'upload', 'publish')) { 'PUSH' } else { 'PULL' }
            Assert-RegistryRow $run "ACR-A-$operation" 'INCONCLUSIVE'
            Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
            $checks++
        }
    }
    foreach ($options in @(@{negativeStatus=404}, @{negativeStatus=401}, @{negativeStatus=302}, @{negativeStatus=429}, @{negativeStatus=500}, @{negativeMessage='Forbidden'}, @{negativeMessage='requested access to the resource is denied; firewall'}, @{negativeCode='UNAUTHORIZED'})) {
        $run = Invoke-RegistryOffline $options
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'INCONCLUSIVE'
        Assert-RegistryRow $run 'ACR-B-CROSS-READ' 'INCONCLUSIVE'
        $checks++
    }
    foreach ($status in @(200, 201, 204, 206)) {
        $run = Invoke-RegistryOffline @{negativeStatus=$status}
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'FAIL'
        Assert-RegistryRow $run 'ACR-B-CROSS-READ' 'FAIL'
        $checks++
    }
    foreach ($failure in @('cross-exchange', 'cross-token')) {
        $run = Invoke-RegistryOffline @{oauthFailure=$failure}
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
        Assert-RegistryRow $run 'ACR-B-CROSS-READ' 'BLOCKED'
        $checks++
    }
    $run = Invoke-RegistryOffline @{writeFails=$true}
    Assert-RegistryRow $run 'RESULTS' 'BLOCKED'
    if ($run.savedJson) { throw 'Failed persistence reported success' }
    $checks++
    if ($checks -ne 256) { throw 'Original Registry check coverage changed' }

    $dataLocation = New-RegistryTestDataLocation $hostName
    $dataHost = ([uri]$dataLocation).Host
    $dataQuery = ([uri]$dataLocation).Query.Substring(1)
    $queryTail = '&h=synthetic&c=config&r=repository&d=digest&p=path&s=signature&v=1&l=location'
    $boundedQuery = 't=' + ('x' * (2048 - 2 - $queryTail.Length)) + $queryTail
    $reverseQuery = ($dataQuery.Split('&')[8..0]) -join '&'
    foreach ($location in @($dataLocation, $dataLocation.Replace('/?', ':443/?'), "https://$dataHost/?$reverseQuery", "https://$dataHost/?$boundedQuery", "https://$dataHost`?$dataQuery")) {
        if ((Resolve-RegistryDataLocation $location $hostName) -cne $location) { throw 'Valid data Location changed or rejected' }
        $run = Invoke-RegistryOffline @{dataLocation=$location}
        Assert-RegistryRow $run 'ACR-A-PULL' 'PASS'
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'PASS'
        if ($run.report.operations -ne 30) { throw 'Redirect added unexpected operations' }
        $checks++
    }
    $invalidDataQueries = @(
        '', $dataQuery.Replace('&l=location', ''), ($dataQuery + '&x=unexpected'), ($dataQuery + '&t=duplicate')
        $dataQuery.Replace('&l=location', '&t=duplicate'), $dataQuery.Replace('t=', 'T='), $dataQuery.Replace('t=', '%74=')
        ($dataQuery + '&'), ('&' + $dataQuery), $dataQuery.Replace('&h=', '&&h='), $dataQuery.Replace('t=', 't')
        $dataQuery.Replace('&h=synthetic', '&=synthetic'), $dataQuery.Replace('t=', 't=%'), $dataQuery.Replace('t=', 't=%GG')
        $dataQuery.Replace('t=', 't=%0d%0a'), $dataQuery.Replace('t=', 't=%00'), $dataQuery.Replace('t=', 't=%20')
        $dataQuery.Replace('&h=', ';h='), $dataQuery.Replace('t=', 't=?'), ($boundedQuery + 'x')
    )
    $invalidDataLocations = @(
        '', '//attacker.invalid/', 'https://attacker.invalid/', "http://$dataHost/?$dataQuery", "ftp://$dataHost/?$dataQuery"
        "https://$dataHost.attacker.invalid/?$dataQuery", "https://sub.$dataHost/?$dataQuery", "https://$dataHost./?$dataQuery"
        $dataLocation.Replace('syntheticregistrya', 'syntheticregistryb'), $dataLocation.Replace('swedencentral', 'swedensouth'), $dataLocation.Replace('swedencentral', 'eastus')
        "https://$hostName/?$dataQuery", "https://$dataHost`:444/?$dataQuery", "https://$dataHost`:80/?$dataQuery"
        "https://user@$dataHost/?$dataQuery", "https://user:password@$dataHost/?$dataQuery", ($dataLocation + '#'), ($dataLocation + '#fragment')
        "https://$dataHost/other?$dataQuery", "https://$dataHost//?$dataQuery", "https://$dataHost/./?$dataQuery", "https://$dataHost/path/../?$dataQuery"
        "https://$dataHost/%2f?$dataQuery", "https://$dataHost/%2e/?$dataQuery"
        $dataLocation.Replace('/?', '\?'), ($dataLocation + "`r`nInjected:value"), ($dataLocation + ('x' * 2305))
    ) + @($invalidDataQueries | ForEach-Object { "https://$dataHost/?$_" })
    foreach ($location in $invalidDataLocations) {
        $rejected = $false
        try { $null = Resolve-RegistryDataLocation $location $hostName } catch { $rejected = $true }
        if (-not $rejected) { throw 'Unsafe data Location accepted' }
        $run = Invoke-RegistryOffline @{dataLocation=$location}
        Assert-RegistryRow $run 'ACR-A-PULL' 'INCONCLUSIVE'
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
        if ($run.dns.Contains($dataHost) -or @($run.http | Where-Object host -CEQ $dataHost).Count) { throw 'Unsafe data Location reached DNS or HTTP' }
        $checks++
    }
    foreach ($invalidHost in @('other.invalid', ('tiny' + '.azurecr.io'), $dataHost, ($hostName + '.attacker.invalid'))) {
        $rejected = $false
        try { $null = Resolve-RegistryDataLocation $dataLocation $invalidHost } catch { $rejected = $true }
        if (-not $rejected) { throw 'Unvalidated registry label accepted' }
        $checks++
    }
    $run = Invoke-RegistryOffline @{duplicateDataLocation=$true}
    Assert-RegistryRow $run 'ACR-A-PULL' 'INCONCLUSIVE'
    if ($run.dns.Contains($dataHost)) { throw 'Multiple Location headers reached data DNS' }
    $checks++
    foreach ($options in @(@{redirect=$false}, @{omitDataDigest=$true}, @{dataAddresses=@('::ffff:10.0.0.4', '172.31.255.255', '192.168.255.255')})) {
        $run = Invoke-RegistryOffline $options
        foreach ($label in @('A', 'B')) { Assert-RegistryRow $run "ACR-$label-PULL" 'PASS' }
        if ($options.ContainsKey('redirect') -and ($run.report.requests -ne 24 -or $run.report.dnsQueries -ne 2 -or $run.report.operations -ne 26)) { throw 'Direct-config cycle changed' }
        $checks++
    }
    foreach ($address in @('8.8.8.8', '127.0.0.1', '169.254.169.254', '0.0.0.0', '100.64.0.1', '172.15.255.255', '172.32.0.0', '192.169.0.1', '224.0.0.1', '::1', 'fc00::1', 'fe80::1', '2001:4860:4860::8888', '::ffff:8.8.8.8')) {
        $run = Invoke-RegistryOffline @{dataAddresses=@('10.0.0.4', $address)}
        Assert-RegistryRow $run 'ACR-A-PULL' 'INCONCLUSIVE'
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
        if (@($run.http | Where-Object { $_.host.EndsWith('.data.' + 'azurecr.io') }).Count) { throw 'Non-RFC1918 DNS answer reached data HTTP' }
        $checks++
    }
    foreach ($options in @(@{dataAddresses=@()}, @{throwDataDns=$true})) {
        $run = Invoke-RegistryOffline $options
        Assert-RegistryRow $run 'ACR-A-PULL' 'INCONCLUSIVE'
        if (@($run.http | Where-Object { $_.host.EndsWith('.data.' + 'azurecr.io') }).Count) { throw 'Unresolved data DNS reached HTTP' }
        $checks++
    }
    foreach ($status in @(301, 302, 303, 307, 308, 401, 403, 404, 429, 500)) {
        $run = Invoke-RegistryOffline @{dataStatus=$status}
        Assert-RegistryRow $run 'ACR-A-PULL' 'INCONCLUSIVE'
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
        if (@($run.http | Where-Object { $_.host.EndsWith('.data.' + 'azurecr.io') }).Count -ne 2 -or $run.report.dnsQueries -ne 4) { throw 'Data response caused another hop or retry' }
        $checks++
    }
    foreach ($step in @('start', 'upload', 'publish', 'head', 'manifest')) {
        $run = Invoke-RegistryOffline @{faultStep=$step; faultStatus=307}
        $operation = if ($step -cin @('start', 'upload', 'publish')) { 'PUSH' } else { 'PULL' }
        Assert-RegistryRow $run "ACR-A-$operation" 'INCONCLUSIVE'
        if ($run.dns.Contains($dataHost)) { throw 'Non-config redirect followed' }
        $checks++
    }
    foreach ($options in @(@{dataBodySize=65536}, @{dataBodySize=65537}, @{dataBodySize=100000}, @{dataDeclaredSize=65537}, @{sameSizeBadConfig=$true}, @{cancelDataRead=$true}, @{throwDataHttp=$true})) {
        $run = Invoke-RegistryOffline $options
        $expected = if ($options.cancelDataRead -or $options.throwDataHttp) { 'INCONCLUSIVE' } else { 'FAIL' }
        Assert-RegistryRow $run 'ACR-A-PULL' $expected
        Assert-RegistryRow $run 'ACR-A-CROSS-READ' 'BLOCKED'
        $dataStreams = @($run.streams | Where-Object isData)
        if ($options.dataDeclaredSize -and @($dataStreams | Where-Object { $_.stream.BytesRead }).Count) { throw 'Oversized declared body was read' }
        if ($options.dataBodySize -and @($dataStreams | Where-Object { $_.stream.BytesRead -ne [math]::Min(65537, $options.dataBodySize) }).Count) { throw 'Unknown-length response limit was not enforced at the boundary' }
        $checks++
    }
    $run = Invoke-RegistryOffline @{negativeStatus=401; negativeCode='UNAUTHORIZED'; negativeMessage='insufficient_scope'}
    foreach ($label in @('A', 'B')) { Assert-RegistryRow $run "ACR-$label-CROSS-READ" 'INCONCLUSIVE' }
    $checks++

    $budgetChecks = & {
        $calls = @{dns=0; http=0}
        $dnsDefinition = $harnessAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-RegistryDataDns' }, $true)
        . ([scriptblock]::Create($dnsDefinition.Extent.Text.Replace($dnsConstructor, '$lookup = Get-RegistryMockDnsTask $HostName')))
        function Get-RegistryMockDnsTask([string]$HostName) {
            if ($HostName -cne $dataHost) { throw 'Unexpected budget-test DNS target' }
            $calls.dns++
            return [Threading.Tasks.Task]::FromResult([Net.IPAddress[]]@([Net.IPAddress]::Parse('10.0.0.4')))
        }
        function Send-RegistryHttpRequest {
            $calls.http++
            return @{StatusCode=200; Content=$image.configBytes; Headers=@{}}
        }
        $target = @{hostName=$hostName; repository='case-a/test'}
        foreach ($initial in @(38, 39, 40)) {
            $calls.dns = $calls.http = 0
            $budget = @{requests=($initial - 2); dnsQueries=2; targets=@{$hostName='case-a/test'}}
            $probe = Read-RegistryConfigRedirect $target $dataLocation $budget
            if ($budget.requests + $budget.dnsQueries -ne 40 -or $calls.dns -ne [int]($initial -lt 40) -or $calls.http -ne [int]($initial -lt 39)) { throw 'DNS and HTTP did not share the exact operation boundary' }
            if (($probe.status -eq 200) -ne ($initial -eq 38)) { throw 'Exhausted combined budget allowed config success' }
        }
        $calls.dns = $calls.http = 0
        $budget = @{requests=0; dnsQueries=0; targets=@{$hostName='case-b/test'}}
        $probe = Read-RegistryConfigRedirect $target $dataLocation $budget
        if ($probe.category -cne 'Boundary' -or $calls.dns -or $calls.http) { throw 'Unallowlisted redirect consumed I/O' }
        return 4
    }
    $checks += $budgetChecks
    $noLive = Invoke-RegistryOffline @{noLive=$true}
    if ($noLive.reads -or $noLive.imports -or $noLive.http.Count -or $noLive.imds.Count -or $noLive.dns.Count -or $noLive.handlers.Count -or $noLive.savedJson) { throw 'Dry run performed I/O or initialized HTTP transport' }
    $checks++
    Write-Output "Registry offline checks passed: $checks"
    Write-Output "Nominal mock cycle: 26 requests (2 IMDS + 24 registry/data HTTP), 4 DNS, 30/40 operations, 14 checks (10 PASS + 4 BLOCKED); no cloud or private files used"
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}