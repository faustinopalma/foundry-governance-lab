[CmdletBinding()]
param([Parameter(Mandatory)][string]$StatePath, [switch]$RunLive)

$ErrorActionPreference='Stop'
$timer=[Diagnostics.Stopwatch]::StartNew()
$quickStatePath=$StatePath
$original=$null; $session=$null; $previous=$env:AZURE_CONFIG_DIR
try {
    if (-not $RunLive) { throw 'Explicit RunLive required; this invokes the existing private runner' }
    . (Join-Path $PSScriptRoot 'Invoke-ExpansionRuntimeAccess.ps1') -DefinitionsOnly
    $state=Read-LabRun $quickStatePath
    $original=(Get-FileHash -LiteralPath $quickStatePath).Hash
    $lab=Read-FoundationJson (Join-Path $state.runDirectory 'outputs.json')
    . (Join-Path $PSScriptRoot 'Invoke-QuickChecks.ps1') -DefinitionsOnly
    Initialize-QuickHelpers
    $null=Get-MinimalPromptContext $state $lab
    $nonce=[guid]::NewGuid().ToString('N')
    $directory=Join-Path $state.runDirectory "quick-$nonce"
    $null=[IO.Directory]::CreateDirectory($directory)
    $state.evidenceDirectory=$directory
    $session=New-ExpansionArmReadSession $state
    $groupId=($lab.runner -split '/providers/')[0]
    $group=Invoke-ExpansionArmRead $session $state "https://management.azure.com${groupId}?api-version=2022-09-01"
    Assert-LabGroupOwnership $state $group
    $vm=Invoke-ExpansionArmRead $session $state "https://management.azure.com$($lab.runner)?api-version=2024-07-01"
    Assert-FoundationText $vm.id $lab.runner
    $projectId=$lab.cases[0].projects[0].resourceId
    $testId=$projectId -replace '/case-a-dev$','/case-a-test'
    if ($testId -ceq $projectId) { throw 'Exact sibling test project required' }
    $testProject=Invoke-ExpansionArmRead $session $state "https://management.azure.com${testId}?api-version=2026-05-01"
    Assert-FoundationText $testProject.id $testId
    $runtime=@{test='Q11';status='BLOCKED';reason='No recorded A-test runtime submission';elapsedSeconds=0}
    $runtimePath=Join-Path $state.runDirectory 'expansion-runtime-a-test.state.json'
    if (Test-Path -LiteralPath $runtimePath) {
        $checkClock=[Diagnostics.Stopwatch]::StartNew()
        $manifest=Read-FoundationJson $runtimePath
        if ($manifest.pending -or $manifest.verified) {
            $root=Invoke-ExpansionArmRead $session $state "https://management.azure.com$($manifest.deploymentId)?api-version=2022-09-01"
            Assert-FoundationEqual $root.properties.provisioningState 'Succeeded'
            $grants=Get-ExpansionRuntimeGrantResources $manifest.binding
            Assert-FoundationSet @($root.properties.outputResources | ForEach-Object id) @($grants.Keys)
            foreach ($grant in $grants.Values) {
                $api=if ($grant.type -ieq 'Microsoft.Authorization/roleAssignments') { '2022-04-01' } else { '2024-11-15' }
                $actual=ConvertTo-ExpansionRuntimeRole (Invoke-ExpansionArmRead $session $state "https://management.azure.com$($grant.id)?api-version=$api")
                foreach ($field in @('id','type')) { Assert-FoundationText $actual[$field] $grant[$field] }
                foreach ($field in $grant.properties.Keys) { Assert-FoundationText $actual.properties[$field] $grant.properties[$field] }
            }
            $runtime=@{test='Q11';status='PASS';reason='Succeeded deployment and exact three role IDs, principals, definitions and scopes; control plane only';elapsedSeconds=[math]::Round($checkClock.Elapsed.TotalSeconds,3);azureProvisioningDuration=$root.properties.duration;formalCoordinatorReceiptUnchanged=$true}
        }
    }
    Close-ExpansionArmReadSession $session; $session=$null
    $remote="/var/lib/fgl-private/quick-$nonce"
    $remoteCode="/opt/fgl/quick-$nonce"
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('set -eu'); $lines.Add('umask 077'); $lines.Add("mkdir -m 700 '$remote' '$remoteCode'")
    $uploads=@{}; $sourceHashes=@{}
    foreach ($name in @('Invoke-QuickChecks.ps1','Invoke-MinimalPromptChecks.ps1','Invoke-AgentChecks.ps1','Invoke-IdentityChecks.ps1','LabExecution.psm1','LabSafety.psm1','PublicSource.psm1','TestResults.psm1')) {
        $path=Join-Path $PSScriptRoot $name
        $uploads[$name]=[IO.File]::ReadAllBytes($path)
        $sourceHashes[$name]=(Get-FileHash -LiteralPath $path).Hash
    }
    $reduced=@{}
    foreach ($key in @('subscriptionId','tenantId','ownershipId','labId','resourceGroups','phase','deploymentAuthorized','privateAccessVerified','pendingPhase','minimalPrompt')) { $reduced[$key]=$state[$key] }
    $uploads['state.json']=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $reduced -Depth 20 -Compress))
    $uploads['outputs.json']=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $lab -Depth 100 -Compress))
    foreach ($name in $uploads.Keys) {
        $memory=[IO.MemoryStream]::new()
        $gzip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionLevel]::Optimal,$true)
        try { $gzip.Write($uploads[$name],0,$uploads[$name].Length); $gzip.Dispose(); $payload=[Convert]::ToBase64String($memory.ToArray()) }
        finally { $gzip.Dispose(); $memory.Dispose() }
        $destination=if ($name -match '\.ps(m)?1$') { $remoteCode } else { $remote }
        $lines.Add("printf '%s' '$payload' | base64 -d | gzip -d > '$destination/$name'")
    }
    $lines.Add("timeout 200 pwsh -NoProfile -NonInteractive -File '$remoteCode/Invoke-QuickChecks.ps1' -RunLive -StatePath '$remote/state.json' -OutputsPath '$remote/outputs.json' -ResultsPath '$remote/result.json' > '$remote/probe.log' 2>&1")
    $lines.Add("gzip -c '$remote/result.json' > '$remote/result.gz'")
    $lines.Add('test $(wc -c < '''+$remote+'/result.gz'') -lt 2600')
    $lines.Add("printf 'QUICK_BEGIN_$nonce\n'; base64 -w0 '$remote/result.gz'; printf '\nQUICK_END_$nonce\n'")
    $shell=Join-Path $directory 'run.sh'
    [IO.File]::WriteAllText($shell,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    if ((Get-Item $shell).Length -gt 120000) { throw 'Transfer budget exceeded' }
    $az=@(Get-Command az -CommandType Application)[0].Source
    $python=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($az)) '../python.exe'))
    if (-not (Test-Path -LiteralPath $python)) { throw 'Windows Azure CLI bundled Python required' }
    $env:AZURE_CONFIG_DIR=$state.azureConfigDirectory
    $arguments=@('-IBm','azure.cli','vm','run-command','invoke','--resource-group',($groupId -split '/')[-1],'--name',($lab.runner -split '/')[-1],'--command-id','RunShellScript','--scripts',"@$shell",'--subscription',$state.subscriptionId,'--only-show-errors','--output','json')
    $capture=Invoke-BoundedLabProcess -Executable $python -Arguments $arguments -LogPrefix (Join-Path $directory 'run-command') -MaxSeconds 300 -IdleSeconds 120
    Write-StandardJson (Join-Path $directory 'process.json') $capture
    if ($capture.reason -cne 'Exited' -or $capture.exitCode -ne 0) { throw 'Bounded Run Command failed; no retry' }
    $response=Read-FoundationJson $capture.stdout
    $message=($response.value | ForEach-Object message) -join "`n"
    if ($message -notmatch "(?s)QUICK_BEGIN_$nonce\s+([A-Za-z0-9+/=]+)\s+QUICK_END_$nonce") { throw 'Missing or truncated nonce-bound result; inspect private runner probe.log' }
    $memory=[IO.MemoryStream]::new([Convert]::FromBase64String($Matches[1]))
    $gzip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionMode]::Decompress)
    $reader=[IO.StreamReader]::new($gzip)
    try { $report=ConvertFrom-Json $reader.ReadToEnd() -AsHashtable -Depth 100 } finally { $reader.Dispose(); $gzip.Dispose(); $memory.Dispose() }
    if ($report.profile -cne 'quick-retained' -or $report.requests -gt 20 -or $report.tests.Count -lt 10) { throw 'Incomplete quick result' }
    $report.tests+=@($runtime)
    $report.sourceHashes=$sourceHashes; $report.stateHash=$original; $report.totalElapsedSeconds=[math]::Round($timer.Elapsed.TotalSeconds,3)
    Write-StandardJson (Join-Path $directory 'report.json') $report
    $report.tests | Select-Object test,status,httpStatus,reason | Format-Table -AutoSize
    Write-Output "Requests: $($report.requests); runner: $($report.elapsedSeconds)s; total: $($report.totalElapsedSeconds)s"
    Write-Output "Report: $(Join-Path $directory 'report.json')"
    Assert-QuickAcceptance $report
} finally {
    if ($session) { Close-ExpansionArmReadSession $session }
    $env:AZURE_CONFIG_DIR=$previous
    if ($original -and (Get-FileHash -LiteralPath $quickStatePath).Hash -cne $original) { throw 'Original state changed' }
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}