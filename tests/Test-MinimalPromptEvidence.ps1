[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('minimal-export-offline-' + [guid]::NewGuid().ToString('N'))
try {
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
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
        $state = @{subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'; ownershipId='33333333-3333-4333-8333-333333333333'; labId='sample01'; phase='activate'; minimalPrompt=$true; privateAccessVerified=$true; pendingPhase=$null; deploymentAuthorized=$true; preexistingGroupIds=@(); runDirectory=$fixtureRoot; azureConfigDirectory=(Join-Path $fixtureRoot 'OPERATOR-CREDENTIALS'); resourceGroups=@('models','integration','case-a') | ForEach-Object { "rg-fgl-sample01-$_" }}
        $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01"
        $account = "$prefix-case-a/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-a-abcdefghijklm"
        $lab = @{minimalPrompt=$true; phase='activate'; resourceGroups=$state.resourceGroups; models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-abcdefghijklm"; gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-abcdefghijklm"; runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner"; cases=@(@{accountId=$account; registryId=''; projects=@(@{name='case-a-dev'; resourceId="$account/projects/case-a-dev"})}); identities=@('dev-a','client') | ForEach-Object { @{actor=$_; clientId=[guid]::NewGuid().ToString(); principalId=[guid]::NewGuid().ToString(); resourceId="$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-sample01-$_"} }}
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
                Assert-Export (($Arguments[0..9] -join '|') -ceq 'vm|run-command|invoke|--resource-group|rg-fgl-sample01-integration|--name|vm-fgl-sample01-runner|--command-id|RunShellScript|--scripts') 'Unexpected runner operation'
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
                $simulation.maximumMessage = [math]::Max($simulation.maximumMessage, $messageText.Length)
                $result = @{value=@(@{code='ComponentStatus/StdOut/succeeded'; message=$messageText})}
                if ($simulation.options.responseMutation) { & $simulation.options.responseMutation $result }
                if ($simulation.options.collision) { [IO.File]::WriteAllText((Join-Path $State.runDirectory $requestData.file), 'EXISTING-DO-NOT-OVERWRITE') }
            }
            [IO.File]::WriteAllText((Join-Path $State.runDirectory "$Label-response.json"), ($result | ConvertTo-Json -Depth 15))
            if ($simulation.options.commandFailure -and $Label -cne 'evidence-runner') { throw 'OFFLINE-COMMAND-FAILED' }
            return $result
        }
        $parameters = @{StatePath=$statePath; SummaryPath=$summaryPath}
        if ($Options.ContainsKey('limit')) { $parameters.MaxTotalBytes = $Options.limit }
        try { $simulation.output = (& $exporter @parameters 6>&1 | Out-String) } catch { $simulation.error = $_.Exception.Message }
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
    foreach ($options in @(
        @{publicSummary=$true}, @{relativeState=$true}, @{relativeSummary=$true}, @{summaryText='{PRIVATE-SENTINEL'}, @{summaryText=(' ' * 65537)}, @{limit=1048577}, @{limit=0},
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
    Write-Output "PASS: $checks offline minimal evidence export scenarios; no Azure calls"
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}