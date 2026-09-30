[CmdletBinding()]
param([string]$StatePath, [string]$OutputsPath, [string]$ResultsPath, [switch]$RunLive, [switch]$DefinitionsOnly)

function Initialize-QuickHelpers {
    foreach ($module in @('PublicSource','LabSafety','LabExecution','TestResults')) { Import-Module (Join-Path $PSScriptRoot "$module.psm1") }
    . (Join-Path $PSScriptRoot 'Invoke-AgentChecks.ps1') -DefinitionsOnly
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-IdentityChecks.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Identity helper syntax invalid' }
    foreach ($definition in $ast.EndBlock.Statements) {
        if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) { Set-Item "Function:script:$($definition.Name)" ([scriptblock]::Create($definition.Body.Extent.Text.Substring(1,$definition.Body.Extent.Text.Length-2))) }
    }
    . (Join-Path $PSScriptRoot 'Invoke-MinimalPromptChecks.ps1') -DefinitionsOnly
    foreach ($command in Get-Command -CommandType Function | Where-Object { $_.ScriptBlock.File -and $_.ScriptBlock.File.StartsWith($PSScriptRoot,[StringComparison]::OrdinalIgnoreCase) }) {
        Set-Item "Function:script:$($command.Name)" $command.ScriptBlock
    }
}

function Get-QuickVerdict([bool]$PositiveReady, [hashtable]$Probe, [int]$ExpectedStatus, [string]$ExpectedCode) {
    if (-not $PositiveReady) { return 'BLOCKED' }
    if ($ExpectedStatus -ge 400 -and $Probe.status -ge 200 -and $Probe.status -lt 300) { return 'FAIL' }
    if ($Probe.status -ne $ExpectedStatus) { return 'INCONCLUSIVE' }
    if ($ExpectedCode -and $Probe.data.code -cne $ExpectedCode) { return 'INCONCLUSIVE' }
    return 'PASS'
}

function Assert-QuickAcceptance([hashtable]$Report) {
    $expected=@(1..11 | ForEach-Object { 'Q{0:D2}' -f $_ })
    if ($Report.tests.Count -ne $expected.Count -or (@($Report.tests.test | Sort-Object) -join ',') -cne ($expected -join ',') -or @($Report.tests | Where-Object { $_.status -cne 'PASS' }).Count) {
        throw 'Acceptance failed: all eleven distinct assertions must be PASS; inspect the private report'
    }
}

function Send-QuickRequest([hashtable]$Context, [hashtable]$Session, [string]$Test, [string]$Token) {
    if ($Session.clock.Elapsed.TotalSeconds -gt 150) { throw 'Quick run deadline reached' }
    $chat='/openai/deployments/lab-chat/chat/completions?api-version=2024-10-21'
    $uri=switch ($Test) {
        { $_ -cin @('Q02','Q03','Q04','Q05') } { $Context.gateway+$chat }
        'Q06' { $Context.gateway+'/openai/deployments/not-allowed/chat/completions?api-version=2024-10-21' }
        'Q07' { $Context.project+'/agents?api-version=v1&limit=1' }
        'Q08' { $Context.project.Replace('/case-a-dev','/case-a-test')+'/agents?api-version=v1&limit=1' }
        'Q09' { $Context.project+'/agents/'+$Context.name+'?api-version=v1' }
        'Q10' { $Context.project+'/openai/v1/responses' }
        default { throw 'Unknown quick test' }
    }
    $method=if ($Test -cin @('Q07','Q08','Q09')) { 'GET' } else { 'POST' }
    if ($Test -cne 'Q03' -and -not $Token) { throw 'Explicit synthetic identity required' }
    $body=if ($Test -ceq 'Q10') {
        @{input='Return only OK.';agent_reference=@{name=$Context.name;type='agent_reference';version='1'};max_output_tokens=256;store=$false;stream=$false;background=$false;truncation='disabled'}
    } elseif ($method -ceq 'POST') { @{messages=@(@{role='user';content='Return only OK.'});max_tokens=32;stream=$false} } else { $null }
    Use-MinimalRequestBudget $Session
    $headers=@{Accept='application/json';'x-ms-client-request-id'=[guid]::NewGuid().ToString('D')}
    if ($Token) { $headers.Authorization="Bearer $Token" }
    $json=if ($body) { ConvertTo-Json $body -Depth 10 -Compress } else { '' }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $response=@{status=0;body='';headers=@{}}
    try { $response=Invoke-MinimalHttp $uri $method $headers $json } catch { }
    $entry=@{test=$Test;timestamp=[DateTimeOffset]::UtcNow.ToString('o');method=$method;uri=$uri;requestBody=$json;clientRequestId=$headers['x-ms-client-request-id'];httpStatus=$response.status;elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,3);responseBody=(Protect-MinimalText $response.body $Session.secrets.ToArray());responseHeaders=$response.headers}
    $file="quick-$Test.json"
    $hash=Write-MinimalPrivateFile (Join-Path $Session.rawDirectory $file) (ConvertTo-Json $entry -Depth 20 -Compress)
    $Session.evidence.Add(@{file=$file;sha256=$hash})
    $probe=ConvertTo-IdentityProbe $response.status $response.body
    $probe.elapsedSeconds=$entry.elapsedSeconds
    return $probe
}

function Invoke-QuickSequence([hashtable]$Context, [hashtable]$State, [hashtable]$Session) {
    $gatewayDns=Get-IdentityPrivateDns $Context.hosts.gateway
    $projectDns=Get-IdentityPrivateDns $Context.hosts['case-a']
    Add-MinimalResult $Session 'Q01' $(if ($gatewayDns -ceq 'PASS' -and $projectDns -ceq 'PASS') { 'PASS' } else { 'INCONCLUSIVE' }) 'Gateway and case A names resolve exclusively to private addresses; not a runtime network-isolation test' $null
    $tokens=@{}
    try {
        foreach ($operation in @('TOKEN-AI','TOKEN-CLIENT','TOKEN-DIRECT')) { $tokens[$operation]=Get-MinimalToken $Context $Session $operation $State.tenantId }
        $gatewayReady=$false; $projectReady=$false; $ownedReady=$false
        foreach ($test in @('Q02','Q03','Q04','Q05','Q06','Q07','Q08','Q09','Q10')) {
            $token=switch ($test) { 'Q03' { '' }; 'Q04' { $tokens['TOKEN-DIRECT'] }; { $_ -cin @('Q05','Q07','Q08','Q09','Q10') } { $tokens['TOKEN-AI'] }; default { $tokens['TOKEN-CLIENT'] } }
            $networkReady=if ($test -cin @('Q02','Q03','Q04','Q05','Q06')) { $gatewayDns -ceq 'PASS' } else { $projectDns -ceq 'PASS' }
            if (-not $networkReady -or ($test -cne 'Q03' -and -not $token) -or ($test -ceq 'Q10' -and -not $ownedReady)) { continue }
            $probe=Send-QuickRequest $Context $Session $test $token
            $status=switch ($test) {
                'Q02' { $gatewayReady=Test-MinimalChat $probe; if ($gatewayReady) { 'PASS' } else { 'INCONCLUSIVE' } }
                'Q03' { Get-QuickVerdict $gatewayReady $probe 401 '' }
                'Q04' { Get-QuickVerdict $gatewayReady $probe 403 'CallerNotAllowed' }
                'Q05' { Get-QuickVerdict $gatewayReady $probe 401 '' }
                'Q06' { Get-QuickVerdict $gatewayReady $probe 404 '' }
                'Q07' { $projectReady=$probe.listValid; if ($projectReady) { 'PASS' } else { 'INCONCLUSIVE' } }
                'Q08' { Get-IdentityNegativeVerdict $projectReady $probe }
                'Q09' { $ownedReady=(Test-MinimalOwnedAgent $probe $Context) -and $probe.data.versions.latest.version -ceq '1'; if ($ownedReady) { 'PASS' } else { 'BLOCKED' } }
                'Q10' { (Get-AgentInvocationVerdict $probe $Context.name '1').status }
            }
            Add-MinimalResult $Session $test $status "Single attempt; elapsed $($probe.elapsedSeconds)s; authenticated positive controls required for denial verdicts" $probe
        }
    } finally { $tokens.Clear() }
}

if ($DefinitionsOnly) { return }
if (-not $RunLive) { throw 'Explicit RunLive required' }
$ErrorActionPreference='Stop'
$saved=@{state=$StatePath;outputs=$OutputsPath;results=$ResultsPath}
Initialize-QuickHelpers
$clock=[Diagnostics.Stopwatch]::StartNew()
$session=@{clock=$clock;requests=0;inferenceRequests=0;inferenceOperations=@{};secrets=[Collections.Generic.List[string]]::new();evidence=[Collections.Generic.List[object]]::new();tests=[Collections.Generic.List[object]]::new();rawDirectory=(New-MinimalEvidenceDirectory)}
try {
    $state=Get-Content (Assert-ExternalLabPath $saved.state) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $lab=Get-Content (Assert-ExternalLabPath $saved.outputs) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Invoke-QuickSequence (Get-MinimalPromptContext $state $lab) $state $session
} catch { Add-MinimalResult $session 'RUN' 'BLOCKED' 'Prerequisite or deadline failed; no retry or resource mutation' $null }
finally { $session.secrets.Clear() }
foreach ($number in 1..10) {
    $test='Q{0:D2}' -f $number
    if ($test -cnotin $session.tests.test) { Add-MinimalResult $session $test 'BLOCKED' 'Prerequisite missing or run deadline reached; not attempted' $null }
}
$report=@{schemaVersion=1;profile='quick-retained';timestamp=[DateTimeOffset]::UtcNow.ToString('o');requests=$session.requests;requestLimit=20;elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,3);rawDirectory=$session.rawDirectory;evidence=$session.evidence.ToArray();tests=$session.tests.ToArray();agentVersion='1';resourceMutations=0}
$null=Write-MinimalPrivateFile (Assert-ExternalLabPath $saved.results) (ConvertTo-Json $report -Depth 20 -Compress)