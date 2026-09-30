[CmdletBinding()]
param()
$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('minimal-acceptance-offline-' + [guid]::NewGuid().ToString('N'))
try {
    Import-Module (Join-Path $PSScriptRoot '../scripts/MinimalTeardownAcceptance.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1')
    . (Join-Path $PSScriptRoot '../scripts/Test-StandardPrivate.ps1') -DefinitionsOnly
    $checks = 0; $remote = @{calls=0}
    function Check([bool]$Condition, [string]$Message = 'Assertion failed') { if (-not $Condition) { throw $Message }; $script:checks++ }
    function Reject([scriptblock]$Probe) { $blocked=$false; try { $null = & $Probe } catch { $blocked=$true }; Check $blocked 'Expected rejection' }
    function Clone($Value) { return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 }
    function Write-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false)) }
    function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    function az { $remote.calls++; throw 'No remote calls permitted' }
    function Invoke-LabAz { $remote.calls++; throw 'No remote calls permitted' }
    function Confirm-LabRunContext { $remote.calls++; throw 'No remote calls permitted' }
    function Frame([string]$Json, [string]$Nonce) {
        $memory=[IO.MemoryStream]::new(); $zip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionLevel]::Optimal,$true)
        try { $bytes=[Text.Encoding]::UTF8.GetBytes($Json); $zip.Write($bytes); $zip.Dispose(); $encoded=[Convert]::ToBase64String($memory.ToArray()) } finally { $zip.Dispose(); $memory.Dispose() }
        return @{value=@(@{code='ComponentStatus/StdOut/succeeded';message="FGL_RESULT_BEGIN_$Nonce`n$encoded`nFGL_RESULT_END_$Nonce"})}
    }
    function Fixture([switch]$Standard, [scriptblock]$Mutate) {
        $root=Join-Path $scratch ([guid]::NewGuid().ToString('N')); $null=[IO.Directory]::CreateDirectory($root)
        $fixtureState=@{subscriptionId='11111111-1111-4111-8111-111111111111';tenantId='22222222-2222-4222-8222-222222222222';ownershipId='33333333-3333-4333-8333-333333333333';labId='sample01';phase='activate';minimalPrompt=$true;privateAccessVerified=$true;pendingPhase=$null;deploymentAuthorized=$true;preexistingGroupIds=@();runDirectory=$root;azureConfigDirectory=(Join-Path $root 'credentials');resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" })}
        $prefix="/subscriptions/$($fixtureState.subscriptionId)/resourceGroups/rg-fgl-sample01"
        $account="$prefix-case-a/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-a-abcdefghijklm"; $project="$account/projects/case-a-dev"
        $identities=@(); $ordinal=4
        foreach($actor in @('dev-a','client')) { $identities+=@{actor=$actor;clientId=('{0}{0}{0}{0}{0}{0}{0}{0}-{0}{0}{0}{0}-4{0}{0}{0}-8{0}{0}{0}-{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}' -f $ordinal);principalId=('{0}{0}{0}{0}{0}{0}{0}{0}-{0}{0}{0}{0}-4{0}{0}{0}-8{0}{0}{0}-{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}' -f ($ordinal+1));resourceId="$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-sample01-$actor"}; $ordinal+=2 }
        $fixtureLab=@{minimalPrompt=$true;phase='activate';resourceGroups=$fixtureState.resourceGroups;models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-abcdefghijklm";gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-abcdefghijklm";runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner";cases=@(@{accountId=$account;registryId='';projects=@(@{name='case-a-dev';resourceId=$project})});identities=$identities}
        Write-Json (Join-Path $root 'outputs.json') $fixtureLab
        Write-Json (Join-Path $root 'parameters.json') @{parameters=@{minimalPrompt=@{value=$true};labId=@{value=$fixtureState.labId};ownershipId=@{value=$fixtureState.ownershipId}}}
        if($Standard) {
            $fixtureState.standard=@{completedStages=@('dependencies','account','project','access');pendingStage=$null;deploymentNames=@{dependencies='fgl-sample01-standard-dependencies';project='fgl-sample01-standard-project';access='fgl-sample01-standard-access'};privateDependenciesVerified=$true}
            $vnet="$prefix-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01"
            $dependency=@{labId='sample01';ownershipId=$fixtureState.ownershipId;stage='dependencies';location='swedencentral';accountId=$account;projectId=$project;projectPrincipalId='44444444-4444-4444-8444-444444444444';workspaceId='55555555-5555-4555-8555-555555555555';projectEndpoint=('https://aif-fgl-sample01-a-abcdefghijklm.'+'services.ai.azure.com/api/projects/case-a-dev');resourceGroups=@{caseA='rg-fgl-sample01-case-a';integration='rg-fgl-sample01-integration'};vnetId=$vnet;subnetId="$vnet/subnets/snet-case-a-pe";privateEndpointIds=@('blob','search','cosmos' | ForEach-Object { "$prefix-case-a/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-standard-$_" });dnsZoneIds=@{}}
            foreach($spec in @(@('storage','blob','stfglsample01abcdef','Microsoft.Storage/storageAccounts','blob.core.windows.net','/'),@('search','search','srch-fgl-sample01-standard','Microsoft.Search/searchServices','search.windows.net',''),@('cosmos','cosmos','cosmos-fgl-sample01-standard','Microsoft.DocumentDB/databaseAccounts','documents.azure.com',':443/'))) { $dependency[$spec[0]]=@{id="$prefix-case-a/providers/$($spec[3])/$($spec[2])";name=$spec[2];endpoint="https://$($spec[2]).$($spec[4])$($spec[5])"}; $dependency.dnsZoneIds[$spec[1]]="$prefix-integration/providers/Microsoft.Network/privateDnsZones/privatelink.$($spec[4])" }
            $outputs=@{dependencies=$dependency}; Write-Json (Join-Path $root 'standard-outputs.json') $outputs
            $binding=Get-StandardPrivateBinding $fixtureState $fixtureLab $outputs; $stamp=Get-StandardPrivateStamp $fixtureState
            $private=@{success=$true;managementVerified=$true;binding=$binding;bindingSha256=$stamp;verifiedAt=[DateTimeOffset]::UtcNow.ToString('o');ownedAddresses=@{};checks=@()}; $addressIndex=4
            foreach($target in $binding.targets) { $addresses=@("10.76.6.$addressIndex"); $addressIndex++; $private.ownedAddresses[$target.hostName]=$addresses; $private.checks+=@{hostName=$target.hostName;addresses=$addresses;tls443=$true} }
            $privatePath=Join-Path $root 'standard-private-fixture.json'; Write-Json $privatePath $private
            $fixtureState.standard.privateDependenciesEvidence=@{path=$privatePath;sha256=(Hash $privatePath);bindingSha256=$stamp;verifiedAt=$private.verifiedAt}
            foreach($change in @('cosmosNetwork','gatewayPolicy')) {
                $proof=@{controlPlaneVerified=$true;verifiedAt=[DateTimeOffset]::UtcNow.ToString('o')}
                $proofPath=Join-Path $root "$change.evidence.json"; Write-Json $proofPath $proof
                $fixtureState.standard[$change]=@{pending=$false;verified=$true;evidence=@{path=$proofPath;sha256=(Hash $proofPath);verifiedAt=$proof.verifiedAt}}
            }
        }
        $attempt=New-MinimalInvocationAttempt $fixtureState '1'
        $shell=Join-Path $root "runner-MinimalPrompt-$($attempt.nonce).sh"; [IO.File]::WriteAllText($shell,'synthetic shell')
        Save-MinimalInvocationAttempt $fixtureState $attempt $shell
        $name='fgl-min-sample01'; $reference=@{type='agent_reference';name=$name;version='1'}
        $agent=@{object='agent';name=$name;id='synthetic-agent';versions=@{latest=@{object='agent.version';name=$name;id='synthetic-version';version='1';metadata=@{'fgl-agent-run'=$fixtureState.ownershipId;'fgl-agent-name'=$name};definition=@{kind='prompt';model='governed-models/lab-chat';instructions='Return only OK.'}}}}
        $response=@{object='response';id='synthetic-response';status='completed';error=$null;incomplete_details=$null;store=$false;agent_reference=$reference;output=@(@{type='message';role='assistant';status='completed';id='synthetic-message';content=@(@{type='output_text';text='OK'})})}
        $request=@{input='Return only OK.';agent_reference=$reference;max_output_tokens=256;store=$false;stream=$false;background=$false;truncation='disabled'}
        $raw=@(@{operation='AGENT-GET';method='GET';requestUri=($attempt.binding.project+"/agents/${name}?api-version=v1");requestBody='';httpStatus=200;transportFailure=$false;timestamp=[DateTimeOffset]::UtcNow.ToString('o');responseBody=($agent|ConvertTo-Json -Depth 30 -Compress)},@{operation='INVOKE';method='POST';requestUri=($attempt.binding.project+'/openai/v1/responses');requestBody=($request|ConvertTo-Json -Depth 30 -Compress);httpStatus=200;transportFailure=$false;timestamp=[DateTimeOffset]::UtcNow.ToString('o');responseBody=($response|ConvertTo-Json -Depth 30 -Compress)})
        $summary=@{schemaVersion=1;runLive=$true;invocationSucceeded=$true;requests=2;rawDirectory=('/var/lib/fgl-private/minimal-'+('a'*32));tests=@(@{test='INVOKE';status='PASS'});evidence=@()}
        $fixture=@{state=$fixtureState;lab=$fixtureLab;attempt=$attempt;raw=$raw;summary=$summary;root=$root}
        if($Mutate) { & $Mutate $fixture }
        $directory=Join-Path $root ('minimal-evidence-'+[guid]::NewGuid().ToString('N')); $null=[IO.Directory]::CreateDirectory($directory); $fixture.directory=$directory
        $manifest=@(); $total=0; $rawIndex=0
        foreach($record in $fixture.raw) { $rawIndex++; $filename='{0:D2}-{1}.json' -f $rawIndex,$record.operation.ToLowerInvariant(); $path=Join-Path $directory $filename; Write-Json $path $record; $length=(Get-Item $path).Length; $total+=$length; $summary.evidence+=@{file=$filename;sha256=(Hash $path)}; $manifest+=@{file=$filename;sha256=(Hash $path);bytes=$length} }
        $summaryPath=Join-Path $root 'summary.json'; Write-Json $summaryPath $summary; Write-Json (Join-Path $directory 'summary.json') $summary
        $packet=Frame ([IO.File]::ReadAllText($summaryPath)) $attempt.nonce; Save-MinimalInvocationReport $fixtureState $attempt $summaryPath $packet
        Write-Json (Join-Path $directory 'export-complete.json') @{schemaVersion=1;complete=$true;summarySha256=(Hash $summaryPath);evidence=$manifest;totalBytes=$total}
        return $fixture
    }
    foreach($standard in @($false,$true)) {
        $fixture=Fixture -Standard:$standard
        $null=New-MinimalTeardownAcceptance $fixture.state $fixture.directory
        foreach($phase in @('activate','destroy','destroyed')) { $fixture.state.phase=$phase; Assert-MinimalTeardownAcceptance $fixture.state; Check $true }
        $fixture.state.phase='destroy'; $fixture.state.pendingPhase='destroy'; Assert-MinimalTeardownAcceptance $fixture.state; Check $true
    }
    foreach($mutation in @(
        {param($fixture) $fixture.summary.runLive='true'},
        {param($fixture) $fixture.summary.invocationSucceeded=$false},
        {param($fixture) $fixture.summary.invocationSucceeded='true'},
        {param($fixture) $fixture.summary.tests[0].status='FAIL'},
        {param($fixture) $fixture.summary.tests+=@{test='RESULTS';status='BLOCKED'}},
        {param($fixture) $fixture.raw[1].responseBody=$fixture.raw[1].responseBody.Replace('"OK"','"NO"')},
        {param($fixture) $fixture.raw[1].responseBody=$fixture.raw[1].responseBody.Replace('fgl-min-sample01','fgl-min-foreign1')},
        {param($fixture) $fixture.raw[0].responseBody=$fixture.raw[0].responseBody.Replace('33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444')},
        {param($fixture) $fixture.raw[0].responseBody=$fixture.raw[0].responseBody.Replace('"version":"1"','"version":"2"')},
        {param($fixture) $fixture.raw[0].requestUri+='/foreign'},
        {param($fixture) $fixture.raw[0].timestamp='2000-01-01T00:00:00Z'}
    )) { $fixture=Fixture -Mutate $mutation; Reject { New-MinimalTeardownAcceptance $fixture.state $fixture.directory } }
    $fixture=Fixture; $null=New-MinimalTeardownAcceptance $fixture.state $fixture.directory
    foreach($mutation in @({param($value) $value.ownershipId='44444444-4444-4444-8444-444444444444'}, {param($value) $value.subscriptionId='44444444-4444-4444-8444-444444444444'}, {param($value) $value.pendingPhase='activate'})) { $changed=Clone $fixture.state; & $mutation $changed; Reject { Assert-MinimalTeardownAcceptance $changed } }
    $changed=Clone $fixture.lab; $changed.identities[0].principalId='66666666-6666-4666-8666-666666666666'; Write-Json (Join-Path $fixture.root 'outputs.json') $changed; Reject { Assert-MinimalTeardownAcceptance $fixture.state }; Write-Json (Join-Path $fixture.root 'outputs.json') $fixture.lab
    $evidencePath=Join-Path $fixture.directory '02-invoke.json'; [IO.File]::AppendAllText($evidencePath,' '); Reject { Assert-MinimalTeardownAcceptance $fixture.state }
    $fixture=Fixture; Remove-Item (Join-Path $fixture.root "minimal-received-$($fixture.attempt.nonce).json"); Reject { New-MinimalTeardownAcceptance $fixture.state $fixture.directory }
    $fixture=Fixture; $receiptPath=Join-Path $fixture.directory 'export-complete.json'; $receipt=Get-Content $receiptPath -Raw|ConvertFrom-Json -AsHashtable; $receipt.complete=$false; Write-Json $receiptPath $receipt; Reject { New-MinimalTeardownAcceptance $fixture.state $fixture.directory }
    $fixture=Fixture; $null=New-MinimalTeardownAcceptance $fixture.state $fixture.directory; $receiptPath=Join-Path $fixture.root 'minimal-teardown-acceptance.json'; $receipt=Get-Content $receiptPath -Raw|ConvertFrom-Json -AsHashtable; $receipt.accepted='true'; Write-Json $receiptPath $receipt; Reject { Assert-MinimalTeardownAcceptance $fixture.state }
    $fixture=Fixture; $null=New-MinimalTeardownAcceptance $fixture.state $fixture.directory; $next=New-MinimalInvocationAttempt $fixture.state '1'; Save-MinimalInvocationAttempt $fixture.state $next (Join-Path $fixture.root "runner-MinimalPrompt-$($fixture.attempt.nonce).sh"); Reject { Assert-MinimalTeardownAcceptance $fixture.state }
    $fixture=Fixture -Standard
    foreach($change in @('cosmosNetwork','gatewayPolicy')) {
        Check ($fixture.attempt.binding.standard.ContainsKey($change)) 'Tracked change omitted from attempt binding'
        foreach($field in @('pending','verified','sha256','timestamp','proof')) {
            $changed=Clone $fixture.state
            switch($field) {
                'pending' { $changed.standard[$change].pending=$true }
                'verified' { $changed.standard[$change].verified=$false }
                'sha256' { $changed.standard[$change].evidence.sha256=('0'*64) }
                'timestamp' { $changed.standard[$change].evidence.verifiedAt='2000-01-01T00:00:00Z' }
                'proof' { $path=Join-Path $fixture.root 'invalid-proof.json'; Write-Json $path @{controlPlaneVerified=$false;verifiedAt=$changed.standard[$change].evidence.verifiedAt}; $changed.standard[$change].evidence.path=$path; $changed.standard[$change].evidence.sha256=Hash $path }
            }
            Reject { New-MinimalInvocationAttempt $changed '1' }
        }
        $changed=Clone $fixture.state; $changed.standard.Remove($change)
        Check ($null -ne (New-MinimalInvocationAttempt $changed '1')) 'Fresh deployments must not require a retained-run repair receipt'
    }
    foreach($mutation in @({param($value) $value.standard.completedStages=@('dependencies')}, {param($value) $value.standard.pendingStage='access'}, {param($value) $value.standard.privateDependenciesVerified=$false}, {param($value) $value.standard.privateDependenciesEvidence.sha256=('0'*64)}, {param($value) $value.standard.privateDependenciesEvidence.path=Join-Path $scratch 'foreign.json'})) {
        $changed=Clone $fixture.state; & $mutation $changed
        Reject { New-MinimalInvocationAttempt $changed '1' }
        Write-Json (Join-Path $fixture.root 'state.json') $changed
        Reject { & (Join-Path $PSScriptRoot '../scripts/Invoke-LabRunner.ps1') -StatePath (Join-Path $fixture.root 'state.json') -Action MinimalPrompt -ExpectedAgentVersion '1' }
    }
    $frame=Frame '{}' ('a'*32); Reject { Assert-MinimalAttemptFrame $frame ('b'*32) }; $frame.value[0].message+=$frame.value[0].message; Reject { Assert-MinimalAttemptFrame $frame ('a'*32) }
    Check ($remote.calls -eq 0) 'Guard failure reached remote code'
    Write-Output "PASS: $checks acceptance assertions; zero remote calls."
} finally { if(Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }; Write-Output ('elapsed: {0:N2}s' -f $timer.Elapsed.TotalSeconds) }