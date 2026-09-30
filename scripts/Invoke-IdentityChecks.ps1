<#
.SYNOPSIS
Read-only identity checks from the private runner using explicit synthetic UAMIs.
.DESCRIPTION
Requires external state, outputs and a new results file, PowerShell 7.2+ and RunLive.
No CLI, operator login, key retrieval, image generation or resource mutation.
At most 30 HTTP requests including IMDS; 20-second connection and read timeouts
(read timeout explicitly set on PowerShell 7.4+), no redirects/retries.
Lists only the first agent/tag page. Negative PASS requires a semantic positive
on the exact target and an explicit HTTP 403 action denial, never just a 403.
ACR cross-registry isolation is not proof of same-registry ABAC conditions.
CRUD, test-project isolation, administration, invocation and same-registry ABAC
remain BLOCKED without safe fixtures and suitable same-operation controls.
Sources verified 2026-09-20:
https://learn.microsoft.com/rest/api/microsoft-foundry/aiproject
https://learn.microsoft.com/azure/foundry/agents/how-to/configure-agent
https://github.com/Azure/acr/blob/main/docs/AAD-OAuth.md
https://learn.microsoft.com/azure/container-registry/container-registry-rbac-abac-repository-permissions
https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/invoke-webrequest
#>
[CmdletBinding()]
param([string]$StatePath, [string]$OutputsPath, [string]$ResultsPath, [switch]$RunLive)

function Use-IdentityRequestBudget {
    param([hashtable]$Budget)

    if ($Budget.requests -ge 30) { throw 'HTTP request budget exhausted' }
    $Budget.requests++
}

function ConvertTo-IdentityProbe {
    param([int]$Status, [AllowEmptyString()][string]$Body)

    $probe = @{status=$Status; data=$null; category='Http'; code=''; listValid=$false}
    if ($Status -eq 0) { $probe.category = 'Transport'; return $probe }
    try {
        $data = ConvertFrom-Json -InputObject $Body -AsHashtable -ErrorAction Stop
        if ($data -is [hashtable]) { $probe.data = $data }
    } catch { }
    if ($probe.data) {
        $probe.listValid = $Status -eq 200 -and $data.object -ceq 'list' -and $data.data -is [array]
        if ($probe.listValid) {
            $probe.listValid = $data.data.Count -le 1
            foreach ($agent in $data.data) {
                if ($agent -isnot [hashtable] -or $agent.object -cne 'agent' -or $agent.name -isnot [string] -or -not $agent.name) { $probe.listValid = $false }
            }
        }
        $errorObject = if ($data.error -is [hashtable]) { $data.error } elseif ($data.errors -is [array] -and $data.errors.Count -eq 1) { $data.errors[0] } else { $null }
        if ($errorObject -is [hashtable]) {
            $code = [string]$errorObject.code
            $message = [string]$errorObject.message
            if ($code -match '(?i)(network|firewall|ipaddress)' -or $message -match '(?i)(virtual network|firewall|public network|ip address|network access)') {
                $probe.category = 'Network'
            } elseif ($Status -eq 403 -and $data.error -is [hashtable] -and $code -ceq 'UserError' -and
                $errorObject.innerError -is [hashtable] -and $errorObject.innerError.code -ceq 'ForbiddenError' -and
                $message -cmatch '\AIdentity\(object id: [0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\) does not have permissions for Microsoft\.CognitiveServices/accounts/AIServices/agents/(?:read|write|delete) actions\.(?: Please refer to https://learn\.microsoft\.com/(?:en-us/)?azure/foundry/concepts/rbac-foundry to fix the permissions issue\.)?\z') {
                $probe.category = 'Authorization'; $probe.code = 'Forbidden'
            } elseif ($code -cin @('PermissionDenied', 'AuthorizationFailed', 'Forbidden') -and $message -match '(?i)(lacks? (?:the )?required (?:data )?action|does not have authorization to perform (?:the )?action|not authorized to perform (?:the )?action)') {
                $probe.category = 'Authorization'; $probe.code = $code
            } elseif ($code -ceq 'DENIED' -and $message -cmatch '^requested access to the resource is denied\.?$') {
                $probe.category = 'Authorization'; $probe.code = $code
            }
        }
    }
    if ($Status -eq 401) { $probe.category = 'Authentication' }
    if ($Status -eq 404) { $probe.category = 'NotFound' }
    if ($Status -eq 429) { $probe.category = 'Throttled' }
    if ($Status -ge 300 -and $Status -lt 400) { $probe.category = 'Redirect' }
    return $probe
}

function Get-IdentityNegativeVerdict {
    param([bool]$PositiveReady, [hashtable]$Probe)

    if (-not $PositiveReady) { return 'BLOCKED' }
    if ($Probe.status -ge 200 -and $Probe.status -lt 300) { return 'FAIL' }
    if ($Probe.category -ne 'Authorization') { return 'INCONCLUSIVE' }
    return Get-AuthorizationVerdict 200 $Probe.status $Probe.code @('PermissionDenied', 'AuthorizationFailed', 'Forbidden', 'DENIED')
}

function Read-IdentityClaims {
    param([string]$Token)

    try {
        $parts = $Token.Split('.')
        if ($parts.Count -ne 3 -or -not $parts[0] -or -not $parts[2]) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($claims -isnot [hashtable] -or $claims.aud -isnot [string] -or [long]$claims.exp -le $now + 60 -or ($claims.ContainsKey('nbf') -and [long]$claims.nbf -gt $now)) { return $null }
        return $claims
    } catch { return $null }
}

function Get-IdentityToken {
    param([hashtable]$Actor, [string]$TenantId, [string]$Audience, [hashtable]$Budget)

    try {
        Use-IdentityRequestBudget $Budget
        $query = 'api-version=2018-02-01&resource=' + [uri]::EscapeDataString($Audience) + '&client_id=' + [uri]::EscapeDataString($Actor.clientId)
        $timeouts = @{TimeoutSec=20}
        if ($PSVersionTable.PSVersion -ge [version]'7.4') { $timeouts.OperationTimeoutSeconds = 20 }
        $response = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?$query" -Headers @{Metadata='true'} -NoProxy @timeouts -MaximumRedirection 0 -MaximumRetryCount 0 -Verbose:$false -Debug:$false -WarningAction SilentlyContinue -ErrorAction Stop
        $claims = Read-IdentityClaims $response.access_token
        if ($response.token_type -ine 'Bearer' -or -not $claims -or $claims.tid -ne $TenantId -or $claims.oid -ne $Actor.principalId -or $claims.aud -cne $Audience) { return $null }
        return [string]$response.access_token
    } catch { return $null }
}

function Send-IdentityRequest {
    param([string]$Uri, [string]$Token, [hashtable]$Budget, [hashtable]$Form)

    try {
        $target = [uri]$Uri
        if ($target.Scheme -cne 'https' -or $target.Port -ne 443 -or $target.UserInfo -or $target.Fragment) { throw 'Invalid service URI' }
        $parameters = @{Uri=$Uri; Method='Get'; Headers=@{Accept='application/json'}; NoProxy=$true; TimeoutSec=20; MaximumRedirection=0; MaximumRetryCount=0; SkipHttpErrorCheck=$true; Verbose=$false; Debug=$false; WarningAction='SilentlyContinue'; ErrorAction='Stop'}
        if ($PSVersionTable.PSVersion -ge [version]'7.4') { $parameters.OperationTimeoutSeconds = 20 }
        if ($Token) { $parameters.Headers.Authorization = "Bearer $Token" }
        if ($Form) {
            if ($target.AbsolutePath -cnotin @('/oauth2/exchange', '/oauth2/token')) { throw 'Only OAuth POST is permitted' }
            $parameters.Method = 'Post'
            $parameters.ContentType = 'application/x-www-form-urlencoded'
            $parameters.Body = $Form
        }
        if ($target.AbsolutePath -match '/manifests/') { $parameters.Headers.Accept = 'application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' }
        Use-IdentityRequestBudget $Budget
        $response = Invoke-WebRequest @parameters
        $bytes = if ($response.Content -is [byte[]]) { $response.Content } else { [Text.Encoding]::UTF8.GetBytes([string]$response.Content) }
        $probe = ConvertTo-IdentityProbe ([int]$response.StatusCode) ([Text.Encoding]::UTF8.GetString($bytes))
        $probe.digest = [string](@($response.Headers['Docker-Content-Digest'])[0])
        $probe.bodyHash = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        return $probe
    } catch { return ConvertTo-IdentityProbe 0 '' }
}

function Get-IdentityPrivateDns {
    param([string]$HostName)

    try {
        $lookup = [Net.Dns]::GetHostAddressesAsync($HostName)
        if (-not $lookup.Wait(5000)) { return 'INCONCLUSIVE' }
        $addresses = @($lookup.GetAwaiter().GetResult())
        if (-not $addresses.Count) { return 'INCONCLUSIVE' }
        foreach ($address in $addresses) {
            if ($address.IsIPv4MappedToIPv6) { $address = $address.MapToIPv4() }
            $bytes = $address.GetAddressBytes()
            $private = if ($bytes.Length -eq 4) {
                $bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
            } else { ($bytes[0] -band 254) -eq 252 }
            if (-not $private) { return 'FAIL' }
        }
        return 'PASS'
    } catch { return 'INCONCLUSIVE' }
}

function Get-IdentityRegistryToken {
    param([string]$HostName, [string]$Repository, [string]$EntraToken, [string]$TenantId, [hashtable]$Budget)

    $exchange = Send-IdentityRequest "https://$HostName/oauth2/exchange" '' $Budget @{grant_type='access_token'; service=$HostName; tenant=$TenantId; access_token=$EntraToken}
    if ($exchange.status -ne 200 -or $exchange.data.refresh_token -isnot [string] -or -not $exchange.data.refresh_token) { return @{token=$null; probe=$exchange} }
    $response = Send-IdentityRequest "https://$HostName/oauth2/token" '' $Budget @{grant_type='refresh_token'; service=$HostName; scope="repository:${Repository}:pull"; refresh_token=$exchange.data.refresh_token}
    $exchange = $null
    $claims = Read-IdentityClaims $response.data.access_token
    if ($response.status -ne 200 -or -not $claims -or $claims.aud -cne $HostName) { return @{token=$null; probe=$response} }
    return @{token=[string]$response.data.access_token; probe=$response}
}

function Test-IdentityManifest {
    param([hashtable]$Probe)

    if ($Probe.status -ne 200 -or $Probe.digest -cnotmatch '^sha256:[a-f0-9]{64}$' -or $Probe.digest -cne $Probe.bodyHash -or $Probe.data.schemaVersion -ne 2) { return $false }
    $data = $Probe.data
    if ($data.mediaType -cin @('application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json')) {
        return $data.config -is [hashtable] -and $data.config.digest -cmatch '^sha256:[a-f0-9]{64}$' -and $data.layers -is [array]
    }
    if ($data.mediaType -cin @('application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json')) { return $data.manifests -is [array] -and $data.manifests.Count -gt 0 }
    return $false
}

function Add-IdentityResult {
    param([System.Collections.Generic.List[object]]$Results, [string]$Test, [ValidateSet('PASS', 'FAIL', 'BLOCKED', 'INCONCLUSIVE')][string]$Status, [string]$Reason, [hashtable]$Probe, [string]$Plane='FoundryData')

    $httpStatus = if ($Probe) { $Probe.status } else { 0 }
    $category = if ($Probe) { $Probe.category } else { 'Prerequisite' }
    $Results.Add([pscustomobject]@{test=$Test; status=$Status; reason=$Reason; plane=$Plane; httpStatus=$httpStatus; category=$category})
}

function Get-IdentityReadVerdict {
    param([hashtable]$Probe, [bool]$Valid)

    if ($Valid) { return 'PASS' }
    if ($Probe.status -eq 404) { return 'BLOCKED' }
    if ($Probe.status -ge 200 -and $Probe.status -lt 300) { return 'FAIL' }
    return 'INCONCLUSIVE'
}

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$budget = @{requests=0; dnsQueries=0}
$results = [System.Collections.Generic.List[object]]::new()
$tokens = @{}
$registryTokens = @{}
$destination = $null
$requiredActors = @('dev-a', 'consumer-a', 'dev-b', 'publisher-a', 'publisher-b', 'client', 'denied')
$expected = @('DEV-A-LIST', 'DEV-B-LIST', 'DEV-A-CROSS', 'DEV-B-CROSS', 'DENIED-PROJECT', 'CONSUMER-LIST', 'CONSUMER-CROSS', 'DEV-A-AGENT-READ', 'CONSUMER-AGENT-READ', 'ACR-A-MANIFEST', 'ACR-B-MANIFEST', 'ACR-A-CROSS', 'ACR-B-CROSS')
try {
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1') -Force -Verbose:$false
    if ($ResultsPath) {
        $candidate = Assert-ExternalLabPath $ResultsPath
        if ((Test-Path -LiteralPath $candidate) -or -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($candidate)) -PathType Container)) { throw 'Results require a new external file' }
        foreach ($inputPath in @($StatePath, $OutputsPath)) {
            if ($inputPath -and $candidate.Equals([IO.Path]::GetFullPath($inputPath), [StringComparison]::OrdinalIgnoreCase)) { throw 'Results cannot replace inputs' }
        }
        $destination = $candidate
    }
    if (-not $RunLive) { Add-IdentityResult $results 'LIVE' 'BLOCKED' 'Explicit RunLive switch required; no inputs read or requests made' $null 'Harness'; return }
    if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -lt [version]'7.2') { throw 'PowerShell Core 7.2 or later required' }
    if (-not $StatePath -or -not $OutputsPath -or -not $destination) { throw 'Three external paths required' }
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1') -Force -Verbose:$false
    Import-Module (Join-Path $PSScriptRoot 'TestResults.psm1') -Force -Verbose:$false
    $state = Get-Content -LiteralPath (Assert-ExternalLabPath $StatePath) -Raw | ConvertFrom-Json -AsHashtable
    $lab = Get-Content -LiteralPath (Assert-ExternalLabPath $OutputsPath) -Raw | ConvertFrom-Json -AsHashtable
    Assert-LabState $state
    if ($state.phase -ne 'activate' -or $lab.phase -ne 'activate') { throw 'Activated private lab required' }
    if (@($lab.resourceGroups).Count -ne 4 -or @(Compare-Object $state.resourceGroups $lab.resourceGroups).Count) { throw 'Group set mismatch' }
    foreach ($resourceId in @($lab.models, $lab.gateway, $lab.runner)) { Assert-LabResourceId $state $resourceId }
    $actors = @{}
    if (@($lab.identities).Count -ne 7) { throw 'Seven explicit actors required' }
    foreach ($actor in $lab.identities) {
        Assert-LabResourceId $state $actor.resourceId
        if ($actor.actor -cnotin $requiredActors -or $actors.ContainsKey($actor.actor) -or $actor.resourceId -notmatch '/providers/Microsoft.ManagedIdentity/userAssignedIdentities/[a-z0-9-]+$') { throw 'Invalid actor' }
        foreach ($field in @('clientId', 'principalId')) { if ([guid]::Parse($actor[$field]) -eq [guid]::Empty) { throw 'Empty actor identifier' } }
        $actors[$actor.actor] = $actor
    }
    foreach ($field in @('clientId', 'principalId', 'resourceId')) {
        if (@($lab.identities | ForEach-Object { $_[$field].ToLowerInvariant() } | Select-Object -Unique).Count -ne 7) { throw 'Actors must be distinct' }
    }
    if (@($lab.cases).Count -ne 2) { throw 'Two cases required' }
    $targets = @{}
    foreach ($caseIndex in 0..1) {
        $label = @('a', 'b')[$caseIndex]
        $case = $lab.cases[$caseIndex]
        Assert-LabResourceId $state $case.accountId
        Assert-LabResourceId $state $case.registryId
        $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-$($state.labId)-case-$label/providers/"
        if (-not $case.accountId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $case.accountId -notmatch '/providers/Microsoft.CognitiveServices/accounts/([a-z0-9-]+)$') { throw 'Invalid case resource' }
        if ($case.accountId -ine "${prefix}Microsoft.CognitiveServices/accounts/$($Matches[1])") { throw 'Unexpected resource parent' }
        $foundryHost = $Matches[1] + '.services.ai.azure.com'
        if (-not $case.registryId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $case.registryId -notmatch '/providers/Microsoft.ContainerRegistry/registries/([a-z0-9]+)$') { throw 'Invalid registry' }
        if ($case.registryId -ine "${prefix}Microsoft.ContainerRegistry/registries/$($Matches[1])") { throw 'Unexpected registry parent' }
        $registryHost = $Matches[1] + '.azurecr.io'
        if (@($case.projects).Count -ne 2) { throw 'Two environments required' }
        foreach ($environment in @('dev', 'test')) {
            $project = @($case.projects | Where-Object { $_.name -ceq "case-$label-$environment" })
            if ($project.Count -ne 1 -or $project[0].resourceId -ine "$($case.accountId)/projects/case-$label-$environment") { throw 'Project parent mismatch' }
            Assert-LabResourceId $state $project[0].resourceId
        }
        $targets[$label] = @{foundryHost=$foundryHost; registryHost=$registryHost; endpoint="https://$foundryHost/api/projects/case-$label-dev"; repository="case-$label/test"; listReady=$false; manifestReady=$false}
    }
    if ($targets.a.foundryHost -eq $targets.b.foundryHost -or $targets.a.registryHost -eq $targets.b.registryHost) { throw 'Service hosts must be distinct' }
    foreach ($label in @('a', 'b')) {
        $target = $targets[$label]
        foreach ($service in @('foundry', 'registry')) {
            $budget.dnsQueries++
            $dns = Get-IdentityPrivateDns $target["${service}Host"]
            $target["${service}Ready"] = $dns -eq 'PASS'
            Add-IdentityResult $results "DNS-$($service.ToUpperInvariant())-$($label.ToUpperInvariant())" $dns 'All DNS answers must be private; this does not prove private endpoint ownership or RBAC' $null 'Network'
        }
        if (-not $target.foundryReady) { continue }
        $actorName = "dev-$label"
        $tokens[$actorName] = Get-IdentityToken $actors[$actorName] $state.tenantId 'https://ai.azure.com' $budget
        if (-not $tokens[$actorName]) { continue }
        $probe = Send-IdentityRequest "$($target.endpoint)/agents?api-version=v1&limit=1" $tokens[$actorName] $budget
        $target.listReady = $probe.listValid
        $target.firstAgent = if ($probe.listValid -and $probe.data.data.Count -gt 0) { $probe.data.data[0].name } else { $null }
        Add-IdentityResult $results "DEV-$($label.ToUpperInvariant())-LIST" (Get-IdentityReadVerdict $probe $probe.listValid) 'First-page project agent list; an empty typed list proves read access, not CRUD or invocation' $probe
    }
    if ($targets.a.listReady -and $targets.b.listReady) {
        foreach ($label in @('a', 'b')) {
            $other = if ($label -eq 'a') { 'b' } else { 'a' }
            $probe = Send-IdentityRequest "$($targets[$other].endpoint)/agents?api-version=v1&limit=1" $tokens["dev-$label"] $budget
            Add-IdentityResult $results "DEV-$($label.ToUpperInvariant())-CROSS" (Get-IdentityNegativeVerdict $true $probe) 'Cross-project list denial after both developers succeeded on their own exact target' $probe
        }
    }
    if ($targets.a.listReady) {
        $tokens.denied = Get-IdentityToken $actors.denied $state.tenantId 'https://ai.azure.com' $budget
        if ($tokens.denied) {
            $probe = Send-IdentityRequest "$($targets.a.endpoint)/agents?api-version=v1&limit=1" $tokens.denied $budget
            Add-IdentityResult $results 'DENIED-PROJECT' (Get-IdentityNegativeVerdict $true $probe) 'Roleless UAMI on the exact project list already verified by dev-a' $probe
        }
        $tokens['consumer-a'] = Get-IdentityToken $actors['consumer-a'] $state.tenantId 'https://ai.azure.com' $budget
        if ($tokens['consumer-a']) {
            $probe = Send-IdentityRequest "$($targets.a.endpoint)/agents?api-version=v1&limit=1" $tokens['consumer-a'] $budget
            Add-IdentityResult $results 'CONSUMER-LIST' (Get-IdentityReadVerdict $probe $probe.listValid) 'Consumer first-page agent list only; not invocation or modification permission' $probe
            if ($probe.listValid -and $targets.b.listReady) {
                $probe = Send-IdentityRequest "$($targets.b.endpoint)/agents?api-version=v1&limit=1" $tokens['consumer-a'] $budget
                Add-IdentityResult $results 'CONSUMER-CROSS' (Get-IdentityNegativeVerdict $true $probe) 'Consumer cross-project list denial after own read and exact target developer positive' $probe
            }
            $agentName = $targets.a.firstAgent
            if ($agentName -is [string] -and $agentName -cmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$') {
                $agentUri = "$($targets.a.endpoint)/agents/${agentName}?api-version=v1"
                $probe = Send-IdentityRequest $agentUri $tokens['dev-a'] $budget
                $ready = $probe.status -eq 200 -and $probe.data.object -ceq 'agent' -and $probe.data.name -ceq $agentName
                Add-IdentityResult $results 'DEV-A-AGENT-READ' (Get-IdentityReadVerdict $probe $ready) 'Read the exact agent discovered in the first page; no agent is created or modified' $probe
                if ($ready) {
                    $probe = Send-IdentityRequest $agentUri $tokens['consumer-a'] $budget
                    $valid = $probe.status -eq 200 -and $probe.data.object -ceq 'agent' -and $probe.data.name -ceq $agentName
                    Add-IdentityResult $results 'CONSUMER-AGENT-READ' (Get-IdentityReadVerdict $probe $valid) 'Consumer read of the same existing agent verified by the developer; invocation remains untested' $probe
                }
            }
        }
    }
    foreach ($label in @('a', 'b')) {
        $target = $targets[$label]
        if (-not $target.registryReady) { continue }
        $actorName = "publisher-$label"
        $tokens[$actorName] = Get-IdentityToken $actors[$actorName] $state.tenantId 'https://containerregistry.azure.net' $budget
        if (-not $tokens[$actorName]) { continue }
        $auth = Get-IdentityRegistryToken $target.registryHost $target.repository $tokens[$actorName] $state.tenantId $budget
        if (-not $auth.token) { Add-IdentityResult $results "ACR-$($label.ToUpperInvariant())-MANIFEST" 'BLOCKED' 'Registry OAuth prerequisite unavailable; no manifest authorization verdict' $auth.probe 'RegistryData'; continue }
        $registryTokens[$label] = $auth.token
        $probe = Send-IdentityRequest "https://$($target.registryHost)/v2/$($target.repository)/tags/list?n=1" $auth.token $budget
        if ($probe.status -ne 200 -or $probe.data.name -cne $target.repository -or $probe.data.tags -isnot [array] -or $probe.data.tags.Count -eq 0 -or $probe.data.tags[0] -isnot [string] -or $probe.data.tags[0] -cnotmatch '^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$') {
            Add-IdentityResult $results "ACR-$($label.ToUpperInvariant())-MANIFEST" 'BLOCKED' 'No existing tag established in the exact allowed repository; no image is generated and no pagination is followed' $probe 'RegistryData'
            continue
        }
        $tag = $probe.data.tags[0]
        $probe = Send-IdentityRequest "https://$($target.registryHost)/v2/$($target.repository)/manifests/$tag" $auth.token $budget
        $target.manifestReady = Test-IdentityManifest $probe
        $target.digest = if ($target.manifestReady) { $probe.digest } else { $null }
        Add-IdentityResult $results "ACR-$($label.ToUpperInvariant())-MANIFEST" (Get-IdentityReadVerdict $probe $target.manifestReady) 'Existing manifest GET with schema and SHA256 digest verification; no layers downloaded' $probe 'RegistryData'
    }
    if ($targets.a.manifestReady -and $targets.b.manifestReady) {
        foreach ($label in @('a', 'b')) {
            $other = if ($label -eq 'a') { 'b' } else { 'a' }
            $target = $targets[$other]
            $auth = Get-IdentityRegistryToken $target.registryHost $target.repository $tokens["publisher-$label"] $state.tenantId $budget
            if (-not $auth.token) { Add-IdentityResult $results "ACR-$($label.ToUpperInvariant())-CROSS" 'BLOCKED' 'Cross-registry OAuth failed before the known manifest probe; not ABAC proof' $auth.probe 'RegistryData'; continue }
            $probe = Send-IdentityRequest "https://$($target.registryHost)/v2/$($target.repository)/manifests/$($target.digest)" $auth.token $budget
            Add-IdentityResult $results "ACR-$($label.ToUpperInvariant())-CROSS" (Get-IdentityNegativeVerdict $true $probe) 'Other publisher against the positively verified target digest; cross-registry isolation only, not same-registry ABAC' $probe 'RegistryData'
        }
    }
} catch {
    Add-IdentityResult $results 'HARNESS' 'BLOCKED' 'Prerequisite validation or local execution failed; private diagnostics are suppressed' $null 'Harness'
} finally {
    $tokens.Clear()
    $registryTokens.Clear()
    $auth = $null
    $probe = $null
    if ($RunLive) {
        foreach ($test in $expected) {
            if ($test -notin $results.test) { Add-IdentityResult $results $test 'BLOCKED' 'Required private DNS, validated IMDS token, same-target positive or existing agent was not established; probe suppressed' $null $(if ($test -like 'ACR-*') { 'RegistryData' } else { 'FoundryData' }) }
        }
        foreach ($label in @('A', 'B')) {
            Add-IdentityResult $results "DEV-$label-CRUD" 'BLOCKED' 'No verified model-backed disposable agent fixture in outputs; no create, update or delete attempted' $null
            Add-IdentityResult $results "DEV-$label-TEST" 'BLOCKED' 'No synthetic actor has positive agent-list access to the test project; dev-project success cannot prove a test-project denial' $null
            foreach ($operation in @('ACCOUNT-ADMIN', 'MODEL-ADMIN')) { Add-IdentityResult $results "DEV-$label-$operation" 'BLOCKED' 'No same-operation authorized control or safe write fixture; no ARM mutation or Owner assumption' $null 'Management' }
            Add-IdentityResult $results "ACR-$label-ABAC" 'BLOCKED' 'No verified outside-condition repository plus authorized same-registry control; cross-registry isolation does not establish the repository condition' $null 'RegistryData'
        }
        Add-IdentityResult $results 'CONSUMER-INVOKE' 'BLOCKED' 'No approved invocable agent/version and bounded response fixture supplied; read access is not invocation proof' $null
        Add-IdentityResult $results 'CONSUMER-WRITE-DENIAL' 'BLOCKED' 'No disposable agent with successful developer write control; existing agents are never modified' $null
        Add-IdentityResult $results 'ACR-PROJECT-PULL' 'BLOCKED' 'Project system-assigned identities are not the seven runner UAMIs; no impersonation or identity elevation' $null 'RegistryData'
    }
    if ($destination) {
        try {
            $report = [ordered]@{schemaVersion=1; runLive=[bool]$RunLive; requests=$budget.requests; requestLimit=30; requestScope='IMDS and service HTTP including OAuth; DNS counted separately'; dnsQueries=$budget.dnsQueries; elapsedSeconds=[math]::Round($timer.Elapsed.TotalSeconds,1); tests=$results.ToArray()}
            $json = $report | ConvertTo-Json -Depth 8
            Assert-PublicText $json
            $null = Assert-ExternalLabPath $destination
            $json | Out-File -LiteralPath $destination -Encoding utf8 -NoClobber -ErrorAction Stop
        } catch { Add-IdentityResult $results 'RESULTS' 'BLOCKED' 'External result persistence failed; private diagnostics are suppressed' $null 'Harness' }
    }
    $results.ToArray()
    Write-Output "requests: $($budget.requests)/30 (IMDS and HTTP); DNS resolutions: $($budget.dnsQueries)/4"
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}