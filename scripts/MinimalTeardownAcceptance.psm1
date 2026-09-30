Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
. (Join-Path $PSScriptRoot 'Invoke-MinimalPromptChecks.ps1') -DefinitionsOnly
. (Join-Path $PSScriptRoot 'Invoke-AgentChecks.ps1') -DefinitionsOnly
. (Join-Path $PSScriptRoot 'Test-StandardPrivate.ps1') -DefinitionsOnly

function Get-AcceptanceHash([string]$Path) {
    $null = Assert-ExternalLabPath $Path
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Resolve-AcceptancePath([hashtable]$State, [string]$Path) {
    $root = (Assert-ExternalLabPath $State.runDirectory).TrimEnd('/','\')
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Absolute private receipt path required' }
    $full = Assert-ExternalLabPath $Path
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Receipt must be inside this private run directory' }
    return $full
}

function Read-AcceptanceJson([hashtable]$State, [string]$Path) {
    $full = Resolve-AcceptancePath $State $Path
    $item = Get-Item -LiteralPath $full -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -lt 1 -or $item.Length -gt 2097152) { throw 'Invalid receipt size' }
    $jsonOptions = @{AsHashtable=$true; Depth=100; ErrorAction='Stop'}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
    $value = Get-Content -LiteralPath $full -Raw -ErrorAction Stop | ConvertFrom-Json @jsonOptions
    if ($value -isnot [hashtable]) { throw 'Receipt object required' }
    return $value
}

function Write-AcceptanceJson([hashtable]$State, [string]$Path, [hashtable]$Value, [switch]$Replace) {
    $full = Resolve-AcceptancePath $State $Path
    $temporary = Resolve-AcceptancePath $State ($full + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew; $options.Access = [IO.FileAccess]::Write; $options.Share = [IO.FileShare]::None
    if ($IsLinux) { $options.UnixCreateMode = [IO.UnixFileMode]384 }
    $stream = [IO.FileStream]::new($temporary, $options)
    try { $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 100)); $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    [IO.File]::Move($temporary, $full, $Replace.IsPresent)
}

function ConvertTo-AcceptanceCanonical($Value) {
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object -CaseSensitive)) { $ordered[$key] = ConvertTo-AcceptanceCanonical $Value[$key] }
        return $ordered
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-AcceptanceCanonical $_ }) }
    return $Value
}

function Get-AcceptanceObjectHash($Value) {
    $text = ConvertTo-Json -InputObject (ConvertTo-AcceptanceCanonical $Value) -Depth 100 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
}

function Get-MinimalAcceptanceBinding([hashtable]$State, [string]$Version) {
    if ($Version -cnotmatch '\A[A-Za-z0-9._-]{1,64}\z') { throw 'Explicit expected agent version required' }
    if ($State.phase -cnotin @('activate','destroy','destroyed') -or ($State.pendingPhase -and -not ($State.phase -ceq 'destroy' -and $State.pendingPhase -ceq 'destroy'))) { throw 'Acceptance requires a completed activation or teardown phase' }
    $active = $State.Clone(); $active.phase = 'activate'; $active.pendingPhase = $null
    $lab = Read-AcceptanceJson $State (Join-Path $State.runDirectory 'outputs.json')
    $context = Get-MinimalPromptContext $active $lab
    if ($State.deploymentAuthorized -isnot [bool] -or -not $State.deploymentAuthorized) { throw 'Authorized run required' }
    $files = @{}
    foreach ($name in @('outputs.json','parameters.json')) { $files[$name] = Get-AcceptanceHash (Resolve-AcceptancePath $State (Join-Path $State.runDirectory $name)) }
    foreach ($file in Get-ChildItem -LiteralPath $State.runDirectory -Filter '*.parameters.json' -File) { $files[$file.Name] = Get-AcceptanceHash $file.FullName }
    $standard = $null
    if ($State.ContainsKey('standard')) {
        Assert-StandardPrivateState $active
        if (($State.standard.completedStages -join ',') -cne 'dependencies,account,project,access' -or $State.standard.privateDependenciesVerified -isnot [bool] -or -not $State.standard.privateDependenciesVerified) { throw 'All four Standard stages and verified private dependencies required' }
        $outputsPath = Resolve-AcceptancePath $State (Join-Path $State.runDirectory 'standard-outputs.json')
        $outputs = Read-AcceptanceJson $State $outputsPath
        $binding = Get-StandardPrivateBinding $active $lab $outputs
        $evidence = $State.standard.privateDependenciesEvidence
        if ($evidence -isnot [hashtable] -or $evidence.path -isnot [string] -or $evidence.sha256 -isnot [string]) { throw 'Private dependencies receipt required' }
        $receipt = Read-AcceptanceJson $State $evidence.path
        $hash = Get-AcceptanceHash $evidence.path
        $stamp = Get-StandardPrivateStamp $active
        if ($hash -cne $evidence.sha256) { throw 'Private dependencies receipt hash mismatch' }
        if ($receipt.success -isnot [bool] -or -not $receipt.success -or $receipt.managementVerified -isnot [bool] -or -not $receipt.managementVerified) { throw 'Private dependencies receipt did not succeed' }
        if ($receipt.bindingSha256 -cne $stamp -or $evidence.bindingSha256 -cne $stamp) { throw 'Private dependencies state stamp mismatch' }
        if ($receipt.verifiedAt -isnot [string] -or -not $evidence.verifiedAt -or [DateTimeOffset]::Parse($receipt.verifiedAt) -ne [DateTimeOffset]$evidence.verifiedAt) { throw 'Private dependencies receipt timestamp mismatch' }
        if ((Get-AcceptanceObjectHash $receipt.binding) -cne (Get-AcceptanceObjectHash $binding)) { throw 'Private dependencies configuration mismatch' }
        Assert-StandardPrivateProbe $binding $receipt $receipt.ownedAddresses
        $files['standard-outputs.json'] = Get-AcceptanceHash $outputsPath
        $standard = @{completedStages=$State.standard.completedStages; deploymentNames=$State.standard.deploymentNames; receiptPath=$evidence.path; receiptSha256=$hash; binding=$binding}
        foreach ($change in @('cosmosNetwork','gatewayPolicy')) {
            if (-not $State.standard.ContainsKey($change)) { continue }
            $entry = $State.standard[$change]
            if ($entry -isnot [hashtable] -or $entry.pending -isnot [bool] -or $entry.pending -or $entry.verified -isnot [bool] -or -not $entry.verified -or $entry.evidence -isnot [hashtable]) { throw 'Tracked Standard change must be idle and verified' }
            $proof = Read-AcceptanceJson $State $entry.evidence.path
            if ($entry.evidence.sha256 -isnot [string] -or (Get-AcceptanceHash $entry.evidence.path) -cne $entry.evidence.sha256 -or $proof.controlPlaneVerified -isnot [bool] -or -not $proof.controlPlaneVerified -or $proof.verifiedAt -isnot [string] -or -not $entry.evidence.verifiedAt -or [DateTimeOffset]::Parse($proof.verifiedAt) -ne [DateTimeOffset]$entry.evidence.verifiedAt) { throw 'Tracked Standard change evidence mismatch' }
            $standard[$change] = $entry
        }
    }
    $sources = @{}
    foreach ($name in @('Invoke-LabRunner.ps1','MinimalTeardownAcceptance.psm1','Invoke-MinimalPromptChecks.ps1','Invoke-AgentChecks.ps1','Invoke-IdentityChecks.ps1','Export-MinimalPromptEvidence.ps1','Test-StandardPrivate.ps1','Invoke-StandardStage.ps1','Invoke-StandardCosmosNetwork.ps1','Update-LabGatewayPolicy.ps1','LabExecution.psm1','LabSafety.psm1','PublicSource.psm1','TestResults.psm1')) {
        $sources[$name] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../infra') -File -Recurse) { $sources['infra/' + [IO.Path]::GetRelativePath((Join-Path $PSScriptRoot '../infra'), $file.FullName)] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
    return @{schemaVersion=1; labId=$State.labId; ownershipId=$State.ownershipId; subscriptionId=$State.subscriptionId; tenantId=$State.tenantId; resourceGroups=$State.resourceGroups; preexistingGroupIds=$State.preexistingGroupIds; runDirectory=$State.runDirectory; azureConfigDirectory=$State.azureConfigDirectory; runner=$lab.runner; projectId=$lab.cases[0].projects[0].resourceId; project=$context.project; actors=$context.actors; agent=$context.name; version=$Version; definition=@{kind='prompt'; model='governed-models/lab-chat'; instructions='Return only OK.'}; files=$files; sources=$sources; standard=$standard}
}

function New-MinimalInvocationAttempt([hashtable]$State, [string]$Version) {
    if ($State.phase -cne 'activate' -or $State.pendingPhase) { throw 'New attempts require completed activation' }
    return @{schemaVersion=1; nonce=[guid]::NewGuid().ToString('N'); startedAt=[DateTimeOffset]::UtcNow.ToString('o'); binding=(Get-MinimalAcceptanceBinding $State $Version)}
}

function Save-MinimalInvocationAttempt([hashtable]$State, [hashtable]$Attempt, [string]$ShellPath) {
    $Attempt.shellPath = Resolve-AcceptancePath $State $ShellPath
    $Attempt.shellSha256 = Get-AcceptanceHash $ShellPath
    $path = Join-Path $State.runDirectory "minimal-attempt-$($Attempt.nonce).json"
    Write-AcceptanceJson $State $path $Attempt
    Write-AcceptanceJson $State (Join-Path $State.runDirectory 'minimal-current-attempt.json') @{path=$path; sha256=(Get-AcceptanceHash $path)} -Replace
}

function Assert-MinimalAttemptFrame([hashtable]$Response, [string]$Nonce) {
    if ($Nonce -cnotmatch '\A[0-9a-f]{32}\z' -or $Response.value -isnot [array] -or -not $Response.value.Count) { throw 'Missing attempt response' }
    foreach ($part in $Response.value) { if ($part.code -isnot [string] -or $part.code -cnotmatch '\A(?:ProvisioningState|ComponentStatus/(?:StdOut|StdErr))/succeeded\z' -or $part.message -isnot [string]) { throw 'Unsuccessful attempt response' } }
    $message = $Response.value.message -join "`n"
    $pattern = '(?m)^FGL_RESULT_BEGIN_' + $Nonce + '\r?\n([A-Za-z0-9+/=]+)\r?\nFGL_RESULT_END_' + $Nonce + '\r?$'
    $frames = [regex]::Matches($message, $pattern)
    if ($message.Length -gt 16000 -or $frames.Count -ne 1 -or [regex]::Matches($message,'FGL_RESULT_BEGIN').Count -ne 1 -or [regex]::Matches($message,'FGL_RESULT_END').Count -ne 1) { throw 'Missing, duplicate or foreign attempt frame' }
    $bytes = [Convert]::FromBase64String($frames[0].Groups[1].Value)
    if ($bytes.Length -ge 2600) { throw 'Oversized summary' }
    $stream = [IO.MemoryStream]::new($bytes); $gzip = [IO.Compression.GZipStream]::new($stream,[IO.Compression.CompressionMode]::Decompress); $reader = [IO.StreamReader]::new($gzip)
    try { $buffer = [char[]]::new(65537); $count = $reader.ReadBlock($buffer,0,$buffer.Length); if ($count -gt 65536) { throw 'Oversized expanded summary' }; return [string]::new($buffer,0,$count) } finally { $reader.Dispose(); $gzip.Dispose(); $stream.Dispose() }
}

function Save-MinimalInvocationReport([hashtable]$State, [hashtable]$Attempt, [string]$SummaryPath, [hashtable]$Response) {
    $json = Assert-MinimalAttemptFrame $Response $Attempt.nonce
    if ($json -cne [IO.File]::ReadAllText((Resolve-AcceptancePath $State $SummaryPath))) { throw 'Summary association mismatch' }
    $responsePath = Join-Path $State.runDirectory "minimal-response-$($Attempt.nonce).json"
    Write-AcceptanceJson $State $responsePath $Response
    Write-AcceptanceJson $State (Join-Path $State.runDirectory "minimal-received-$($Attempt.nonce).json") @{nonce=$Attempt.nonce; receivedAt=[DateTimeOffset]::UtcNow.ToString('o'); attemptSha256=(Get-AcceptanceHash (Join-Path $State.runDirectory "minimal-attempt-$($Attempt.nonce).json")); summaryPath=$SummaryPath; summarySha256=(Get-AcceptanceHash $SummaryPath); responsePath=$responsePath; responseSha256=(Get-AcceptanceHash $responsePath)}
}

function Test-MinimalAcceptanceEvidence([hashtable]$State, [string]$ExportDirectory) {
    $pointer = Read-AcceptanceJson $State (Join-Path $State.runDirectory 'minimal-current-attempt.json')
    $attempt = Read-AcceptanceJson $State $pointer.path
    if ($attempt.nonce -isnot [string] -or $attempt.nonce -cnotmatch '\A[0-9a-f]{32}\z' -or $pointer.path -cne (Join-Path $State.runDirectory "minimal-attempt-$($attempt.nonce).json") -or (Get-AcceptanceHash $pointer.path) -cne $pointer.sha256) { throw 'Unbound invocation attempt' }
    if ((Get-AcceptanceObjectHash (Get-MinimalAcceptanceBinding $State $attempt.binding.version)) -cne (Get-AcceptanceObjectHash $attempt.binding) -or (Get-AcceptanceHash (Resolve-AcceptancePath $State $attempt.shellPath)) -cne $attempt.shellSha256) { throw 'Invocation configuration changed' }
    $receivedPath = Join-Path $State.runDirectory "minimal-received-$($attempt.nonce).json"
    $received = Read-AcceptanceJson $State $receivedPath
    $response = Read-AcceptanceJson $State $received.responsePath
    $summary = Read-AcceptanceJson $State $received.summaryPath
    if ($received.nonce -cne $attempt.nonce -or $received.attemptSha256 -cne $pointer.sha256 -or (Get-AcceptanceHash $received.summaryPath) -cne $received.summarySha256 -or (Get-AcceptanceHash $received.responsePath) -cne $received.responseSha256 -or (Assert-MinimalAttemptFrame $response $attempt.nonce) -cne [IO.File]::ReadAllText($received.summaryPath)) { throw 'Unbound received summary' }
    $start = [DateTimeOffset]::Parse($attempt.startedAt); $end = [DateTimeOffset]::Parse($received.receivedAt)
    if ($end -lt $start) { throw 'Invalid attempt interval' }
    $directory = Resolve-AcceptancePath $State $ExportDirectory
    if ([IO.Path]::GetDirectoryName($directory) -cne $State.runDirectory -or [IO.Path]::GetFileName($directory) -cnotmatch '\Aminimal-evidence-[a-f0-9]{32}\z') { throw 'Expected private export directory' }
    $exportPath = Join-Path $directory 'export-complete.json'; $export = Read-AcceptanceJson $State $exportPath
    if ($export.complete -isnot [bool] -or -not $export.complete -or $export.summarySha256 -isnot [string] -or $export.summarySha256 -ine $received.summarySha256 -or (Get-AcceptanceHash (Join-Path $directory 'summary.json')) -ine $received.summarySha256) { throw 'Incomplete or foreign export' }
    if ($summary.schemaVersion -ne 1 -or $summary.runLive -isnot [bool] -or -not $summary.runLive -or $summary.invocationSucceeded -isnot [bool] -or -not $summary.invocationSucceeded -or $summary.rawDirectory -isnot [string] -or $summary.rawDirectory -cnotmatch '\A/var/lib/fgl-private/minimal-[a-f0-9]{32}\z') { throw 'Actual live success required' }
    $invoked = @($summary.tests | Where-Object { $_.test -ceq 'INVOKE' })
    if ($summary.tests -isnot [array] -or $invoked.Count -ne 1 -or $invoked[0].status -isnot [string] -or $invoked[0].status -cne 'PASS' -or @($summary.tests | Where-Object { $_.test -cin @('HARNESS','RESULTS') }).Count) { throw 'Exact invocation PASS and successful persistence required' }
    if ($summary.evidence -isnot [array] -or $summary.evidence.Count -lt 2 -or $summary.evidence.Count -gt 20 -or $summary.requests -isnot [long] -and $summary.requests -isnot [int] -or $summary.requests -ne $summary.evidence.Count -or $export.evidence -isnot [array] -or $export.evidence.Count -ne $summary.evidence.Count) { throw 'Incomplete request coverage' }
    $records = @(); $total = 0; $index = 0
    foreach ($entry in $summary.evidence) {
        $index++
        if ($entry.file -isnot [string] -or $entry.file -cnotmatch ('\A' + ('{0:D2}' -f $index) + '-(?:token-ai|token-client|token-direct|gateway|direct-central|control|connection|agent-get|agent-create|invoke)\.json\z') -or $entry.sha256 -isnot [string] -or $entry.sha256 -cnotmatch '\A[0-9A-Fa-f]{64}\z') { throw 'Invalid evidence manifest' }
        $path = Join-Path $directory $entry.file; $exported = $export.evidence[$index-1]
        $record = Read-AcceptanceJson $State $path; $length = (Get-Item -LiteralPath $path).Length
        if ((Get-AcceptanceHash $path) -ine $entry.sha256 -or $exported.file -cne $entry.file -or $exported.sha256 -ine $entry.sha256 -or $exported.bytes -ne $length -or $record.operation -cne $entry.file.Substring(3,$entry.file.Length-8).ToUpperInvariant()) { throw 'Evidence hash, size or operation mismatch' }
        $stamp = [DateTimeOffset]::Parse($record.timestamp)
        if ($stamp -lt $start -or $stamp -gt $end) { throw 'Evidence outside this attempt' }
        $total += $length; $records += $record
    }
    if ($total -ne $export.totalBytes) { throw 'Incomplete exported bytes' }
    $invocations = @($records | Where-Object operation -CEQ 'INVOKE')
    if ($invocations.Count -ne 1) { throw 'Exactly one invocation required' }
    $invoke = $invocations[0]; $gets = @($records | Where-Object { $_.operation -ceq 'AGENT-GET' -and [DateTimeOffset]::Parse($_.timestamp) -le [DateTimeOffset]::Parse($invoke.timestamp) })
    if (-not $gets.Count) { throw 'Fresh ownership GET missing' }
    $owned = $gets[-1]; $context = @{name=$attempt.binding.agent; marker=$State.ownershipId}
    foreach ($raw in @($owned,$invoke)) { if ($raw.transportFailure -isnot [bool] -or $raw.transportFailure -or $raw.httpStatus -isnot [int] -and $raw.httpStatus -isnot [long]) { throw 'Invalid transport evidence' } }
    if ($owned.method -cne 'GET' -or $owned.requestUri -cne ($attempt.binding.project + '/agents/' + $context.name + '?api-version=v1') -or $invoke.method -cne 'POST' -or $invoke.requestUri -cne ($attempt.binding.project + '/openai/v1/responses')) { throw 'Wrong agent or project request' }
    $agentProbe = @{status=$owned.httpStatus; data=($owned.responseBody | ConvertFrom-Json -AsHashtable -Depth 100)}
    if (-not (Test-MinimalOwnedAgent $agentProbe $context) -or $agentProbe.data.versions.latest.version -cne $attempt.binding.version) { throw 'Exact owned definition and pinned version not established' }
    $body = $invoke.requestBody | ConvertFrom-Json -AsHashtable -Depth 100
    $expected = @{input='Return only OK.'; agent_reference=@{name=$context.name; type='agent_reference'; version=$attempt.binding.version}; max_output_tokens=256; store=$false; stream=$false; background=$false; truncation='disabled'}
    if ((Get-AcceptanceObjectHash $body) -cne (Get-AcceptanceObjectHash $expected)) { throw 'Invocation request contract mismatch' }
    $verdict = Get-AgentInvocationVerdict @{status=$invoke.httpStatus; data=($invoke.responseBody | ConvertFrom-Json -AsHashtable -Depth 100)} $context.name $attempt.binding.version
    if ($verdict.status -cne 'PASS') { throw 'Raw invocation did not pass' }
    return @{schemaVersion=1; accepted=$true; nonce=$attempt.nonce; attemptSha256=$pointer.sha256; receivedSha256=(Get-AcceptanceHash $receivedPath); bindingSha256=(Get-AcceptanceObjectHash $attempt.binding); exportDirectory=$directory; exportSha256=(Get-AcceptanceHash $exportPath); version=$attempt.binding.version}
}

function New-MinimalTeardownAcceptance([hashtable]$State, [string]$ExportDirectory) {
    if ($State.phase -cne 'activate' -or $State.pendingPhase) { throw 'Acceptance creation requires activation' }
    $receipt = Test-MinimalAcceptanceEvidence $State $ExportDirectory
    Write-AcceptanceJson $State (Join-Path $State.runDirectory 'minimal-teardown-acceptance.json') $receipt -Replace
    return $receipt
}

function Assert-MinimalTeardownAcceptance([hashtable]$State) {
    Assert-LabState $State
    if ($State.minimalPrompt -ne $true) { return }
    $receipt = Read-AcceptanceJson $State (Join-Path $State.runDirectory 'minimal-teardown-acceptance.json')
    $expected = Test-MinimalAcceptanceEvidence $State $receipt.exportDirectory
    if ((Get-AcceptanceObjectHash $receipt) -cne (Get-AcceptanceObjectHash $expected)) { throw 'Invalid teardown acceptance receipt' }
}

Export-ModuleMember -Function New-MinimalInvocationAttempt, Save-MinimalInvocationAttempt, Assert-MinimalAttemptFrame, Save-MinimalInvocationReport, New-MinimalTeardownAcceptance, Assert-MinimalTeardownAcceptance