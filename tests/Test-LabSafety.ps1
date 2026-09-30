[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1') -Force
    $state = @{
        subscriptionId = '11111111-1111-4111-8111-111111111111'
        tenantId = '22222222-2222-4222-8222-222222222222'
        ownershipId = '33333333-3333-4333-8333-333333333333'
        labId = 'sample01'
        resourceGroups = @('models', 'integration', 'case-a', 'case-b') | ForEach-Object { "rg-fgl-sample01-$_" }
    }
    $script:passed = 0
    function Confirm-Accepted([scriptblock]$Action) {
        & $Action
        $script:passed++
    }
    function Confirm-Rejected([scriptblock]$Action) {
        $rejected = $false
        try { & $Action } catch { $rejected = $true }
        if (-not $rejected) { throw 'Safety test accepted a forbidden operation' }
        $script:passed++
    }
    $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01-models"
    $resource = "$prefix/providers/Microsoft.CognitiveServices/accounts/synthetic"
    Confirm-Accepted { Assert-LabState $state }
    Confirm-Accepted { Assert-LabContext $state @{id=$state.subscriptionId; tenantId=$state.tenantId; state='Enabled'} }
    Confirm-Accepted { Assert-LabResourceId $state $prefix }
    Confirm-Accepted { Assert-LabResourceId $state $resource.ToUpperInvariant() }
    Confirm-Accepted { Assert-LabResourceId $state "$resource/deployments/model" }
    Confirm-Accepted { Assert-LabResourceId $state "$resource/providers/Microsoft.Insights/diagnosticSettings/metrics" }
    Confirm-Accepted { Assert-LabResourceId $state "$resource/projects/dev/providers/Microsoft.Authorization/roleAssignments/synthetic" }
    Confirm-Rejected { Assert-LabResourceId $state "$resource/providers/Microsoft.Insights/diagnosticSettings" }
    Confirm-Rejected { Assert-LabResourceId $state "$prefix/providers/Microsoft.Insights/diagnosticSettings/" }
    Confirm-Rejected { Assert-LabContext $state @{id=$state.tenantId; tenantId=$state.tenantId; state='Enabled'} }
    Confirm-Rejected { Assert-LabContext $state @{id=$state.subscriptionId; tenantId=$state.ownershipId; state='Enabled'} }
    Confirm-Rejected { Assert-LabContext $state @{id=$state.subscriptionId; tenantId=$state.tenantId; state='Disabled'} }
    foreach ($invalidId in @(
        "/subscriptions/$($state.tenantId)/resourceGroups/rg-fgl-sample01-models",
        "$prefix-other/providers/Microsoft.Network/virtualNetworks/other",
        "/subscriptions/$($state.subscriptionId)/providers/Microsoft.Authorization/roleAssignments/other",
        "$resource/../other", "$resource%2fother", "$resource?api-version=1", "$prefix/providers/"
    )) { Confirm-Rejected { Assert-LabResourceId $state $invalidId } }
    $group = @{id=$prefix; name='rg-fgl-sample01-models'; tags=@{'fgl-owner'=$state.ownershipId; 'fgl-lab'=$state.labId}}
    Confirm-Accepted { Assert-LabGroupOwnership $state $group }
    $group.tags['fgl-owner'] = $state.tenantId
    Confirm-Rejected { Assert-LabGroupOwnership $state $group }
    $group.tags = @{}
    Confirm-Rejected { Assert-LabGroupOwnership $state $group }
    Confirm-Accepted { Assert-LabWhatIf $state @{status='Succeeded'; changes=@(@{resourceId=$resource; changeType='Create'})} }
    foreach ($changeType in @('Delete', 'Ignore', 'Deploy', 'Unsupported', 'FutureValue')) {
        Confirm-Rejected { Assert-LabWhatIf $state @{status='Succeeded'; changes=@(@{resourceId=$resource; changeType=$changeType})} }
    }
    Confirm-Rejected { Assert-LabWhatIf $state @{status='Succeeded'; changes=@()} }
    Confirm-Rejected { Assert-LabWhatIf $state @{status='Failed'; changes=@(@{resourceId=$resource; changeType='Create'})} }
    Confirm-Rejected { Assert-LabWhatIf $state @{status='Succeeded'; changes=@(@{resourceId="$prefix-other"; changeType='Create'})} }
    $parentId = "$prefix/providers/Microsoft.Network/privateEndpoints/synthetic"
    $parentChange = @{resourceId=$parentId; changeType='NoChange'; before=@{tags=@{'fgl-owner'=$state.ownershipId; 'fgl-lab'=$state.labId}}}
    $managedChange = @{resourceId="$prefix/providers/Microsoft.Network/networkInterfaces/synthetic"; changeType='Ignore'; before=@{type='Microsoft.Network/networkInterfaces'; managedBy=$parentId}}
    Confirm-Accepted { Assert-LabWhatIf $state @{status='Succeeded'; changes=@($parentChange,$managedChange)} }
    Confirm-Rejected { Assert-LabWhatIf $state @{status='Succeeded'; changes=@($managedChange)} }
    $parentChange.before.tags['fgl-owner'] = $state.tenantId
    Confirm-Rejected { Assert-LabWhatIf $state @{status='Succeeded'; changes=@($parentChange,$managedChange)} }
    $parentChange.before.tags['fgl-owner'] = $state.ownershipId
    $managedChange.before.type = 'Microsoft.Network/virtualNetworks'
    Confirm-Rejected { Assert-LabWhatIf $state @{status='Succeeded'; changes=@($parentChange,$managedChange)} }
    $vmId = "$prefix/providers/Microsoft.Compute/virtualMachines/synthetic"
    $vmChange = @{resourceId=$vmId; changeType='NoChange'; before=@{tags=@{'fgl-owner'=$state.ownershipId; 'fgl-lab'=$state.labId}}}
    $extensionChange = @{resourceId="$vmId/extensions/MDE.Linux"; changeType='Ignore'; before=@{type='Microsoft.Compute/virtualMachines/extensions'}}
    Confirm-Accepted { Assert-LabWhatIf $state @{status='Succeeded'; changes=@($vmChange,$extensionChange)} }
    Confirm-Rejected { Assert-LabWhatIf $state @{status='Succeeded'; changes=@($extensionChange)} }
    $vmChange.before.tags['fgl-owner'] = $state.tenantId
    Confirm-Rejected { Assert-LabWhatIf $state @{status='Succeeded'; changes=@($vmChange,$extensionChange)} }
    $vmChange.before.tags['fgl-owner'] = $state.ownershipId
    $extensionChange.resourceId = "$vmId/extensions/unknown"
    Confirm-Rejected { Assert-LabWhatIf $state @{status='Succeeded'; changes=@($vmChange,$extensionChange)} }
    $state.phase = 'not-deployed'
    $state.deploymentAuthorized = $false
    Confirm-Rejected { Assert-LabTransition $state 'bootstrap' }
    $state.deploymentAuthorized = $true
    $state.destroyAuthorized = $true
    Confirm-Accepted { Assert-LabTransition $state 'bootstrap' }
    Confirm-Rejected { Assert-LabTransition $state 'activate' }
    $state.pendingPhase = 'bootstrap'
    Confirm-Rejected { Assert-LabTransition $state 'lock' }
    Confirm-Accepted { Assert-LabTransition $state 'destroy' }
    $state.pendingPhase = $null
    $state.phase = 'bootstrap'
    Confirm-Accepted { Assert-LabTransition $state 'lock' }
    $state.phase = 'lock'
    $state.privateAccessVerified = $false
    Confirm-Rejected { Assert-LabTransition $state 'activate' }
    Confirm-Rejected { Assert-LabTransition $state 'bootstrap' }
    $state.privateAccessVerified = $true
    Confirm-Accepted { Assert-LabTransition $state 'activate' }
    $state.phase = 'activate'
    Confirm-Accepted { Assert-LabTransition $state 'activate' }
    Confirm-Rejected { Assert-LabTransition $state 'lock' }
    Confirm-Rejected { Assert-LabTransition $state 'bootstrap' }
    $state.destroyAuthorized = $false
    Confirm-Rejected { Assert-LabTransition $state 'destroy' }
    $state.destroyAuthorized = $true
    $state.phase = 'destroyed'
    Confirm-Rejected { Assert-LabTransition $state 'bootstrap' }
    $parameters = @{labId=@{value=$state.labId}; ownershipId=@{value=$state.ownershipId}}
    Confirm-Accepted { Assert-LabParameters $state $parameters }
    $minimal = $state.Clone()
    $minimal.minimalPrompt = $true
    $minimal.resourceGroups = @('models', 'integration', 'case-a') | ForEach-Object { "rg-fgl-$($state.labId)-$_" }
    Confirm-Accepted { Assert-LabState $minimal }
    Confirm-Rejected { Assert-LabParameters $minimal $parameters }
    $parameters.minimalPrompt = @{value=$true}
    Confirm-Accepted { Assert-LabParameters $minimal $parameters }
    Confirm-Rejected { Assert-LabParameters $state $parameters }
    foreach ($invalid in @('true', 1, $null)) {
        $parameters.minimalPrompt.value = $invalid
        Confirm-Rejected { Assert-LabParameters $minimal $parameters }
        $invalidState = $minimal.Clone()
        $invalidState.minimalPrompt = $invalid
        Confirm-Rejected { Assert-LabState $invalidState }
    }
    $parameters.minimalPrompt.value = $true
    $parameters.enableExperimentalAgents = @{value=$true}
    Confirm-Rejected { Assert-LabParameters $minimal $parameters }
    Confirm-Rejected { Assert-LabTransition $minimal 'bootstrap' }
    $minimal.phase = 'lock'
    $minimal.privateAccessVerified = $false
    Confirm-Rejected { Assert-LabTransition $minimal 'activate' }
    $minimal.privateAccessVerified = $true
    Confirm-Accepted { Assert-LabTransition $minimal 'activate' }
    Confirm-Accepted { Assert-LabResourceId $minimal $resource }
    $caseB = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-$($state.labId)-case-b"
    Confirm-Rejected { Assert-LabResourceId $minimal $caseB }
    Confirm-Rejected { Assert-LabWhatIf $minimal @{status='Succeeded'; changes=@(@{resourceId=$caseB; changeType='Create'})} }
    Confirm-Rejected { Assert-LabContext $minimal @{id=$state.tenantId; tenantId=$state.tenantId; state='Enabled'} }
    $minimal.resourceGroups += 'rg-fgl-sample01-case-b'
    Confirm-Rejected { Assert-LabState $minimal }
    $minimal.resourceGroups = @('rg-fgl-sample01-models', 'rg-fgl-sample01-integration', 'rg-fgl-sample01-integration')
    Confirm-Rejected { Assert-LabState $minimal }
    $minimal.resourceGroups = @('rg-fgl-sample01-models', 'rg-fgl-sample01-integration', 'rg-unrelated')
    Confirm-Rejected { Assert-LabState $minimal }
    $state.resourceGroups += 'rg-unrelated'
    Confirm-Rejected { Assert-LabState $state }
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabExecution.psm1') -Force
    foreach ($minimalPrompt in @($false, $true)) {
        $profileState = $state.Clone()
        $profileState.minimalPrompt = $minimalPrompt
        $profileState.phase = 'lock'
        $profileState.pendingPhase = $null
        $profileState.privateAccessVerified = $false
        $profileState.resourceGroups = @(if ($minimalPrompt) { 'models','integration','case-a' } else { 'models','integration','case-a','case-b' }) | ForEach-Object { "rg-fgl-sample01-$_" }
        $profilePrefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01"
        $lab = @{minimalPrompt=$minimalPrompt;resourceGroups=$profileState.resourceGroups;models="$profilePrefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-123456789abcd";gateway="$profilePrefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-123456789abcd";runner="$profilePrefix-integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner";cases=@()}
        foreach ($caseId in @(if ($minimalPrompt) { 'a' } else { 'a','b' })) {
            $accountId = "$profilePrefix-case-$caseId/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-$caseId-123456789abcd"
            $case = @{accountId=$accountId; registryId=''; projects=@()}
            if (-not $minimalPrompt) { $case.registryId = "$profilePrefix-case-$caseId/providers/Microsoft.ContainerRegistry/registries/crfglsample01${caseId}123456789abcd" }
            foreach ($environment in @(if ($minimalPrompt) { 'dev' } else { 'dev','test' })) { $case.projects += @{resourceId="$accountId/projects/case-$caseId-$environment"} }
            $lab.cases += $case
        }
        $targets = @(Get-LabPrivateTargets $profileState $lab)
        $expectedCount = if ($minimalPrompt) { 3 } else { 6 }
        Confirm-Accepted { if ($targets.Count -ne $expectedCount) { throw 'Wrong private target count' } }
        $report = @{gatewayStatus=404;checks=@()}
        $fixtureAddresses = @{}
        foreach ($targetIndex in 0..($targets.Count - 1)) {
            $hostName = $targets[$targetIndex].hostName
            $fixtureAddresses[$hostName] = @("10.76.8.$($targetIndex + 4)")
            $report.checks += @{hostName=$hostName; addresses=$fixtureAddresses[$hostName]; tcp443=$true}
        }
        Confirm-Accepted { Assert-LabPrivateReport $targets $report $fixtureAddresses }
        $badReport = $report | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $badReport.checks[0].hostName = $badReport.checks[1].hostName
        Confirm-Rejected { Assert-LabPrivateReport $targets $badReport $fixtureAddresses }
        foreach ($invalidAddresses in @(@(), @('10.76.8.5'), @('203.0.113.1'))) {
            $badReport = $report | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            $badReport.checks[0].addresses = $invalidAddresses
            Confirm-Rejected { Assert-LabPrivateReport $targets $badReport $fixtureAddresses }
        }
        $badLab = $lab | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $badLab.minimalPrompt = -not $minimalPrompt
        Confirm-Rejected { $null = Get-LabPrivateTargets $profileState $badLab }
        $badLab = $lab | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $badLab.cases[0].projects += @{resourceId="$($badLab.cases[0].accountId)/projects/case-a-extra"}
        Confirm-Rejected { $null = Get-LabPrivateTargets $profileState $badLab }
        if ($minimalPrompt) {
            $badLab = $lab | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            $badLab.cases[0].registryId = "$profilePrefix-case-a/providers/Microsoft.ContainerRegistry/registries/unexpected"
            Confirm-Rejected { $null = Get-LabPrivateTargets $profileState $badLab }
        } else {
            $legacyLab = $lab.Clone()
            $legacyLab.Remove('minimalPrompt')
            $legacyState = $profileState.Clone()
            $legacyState.Remove('minimalPrompt')
            Confirm-Accepted { $null = Get-LabPrivateTargets $legacyState $legacyLab }
        }
        $fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ("fgl-runner-test-$([guid]::NewGuid().ToString('N'))")
        $null = New-Item -ItemType Directory -Path $fixtureDirectory
        try {
            $profileState.runDirectory = $fixtureDirectory
            [IO.File]::WriteAllText((Join-Path $fixtureDirectory 'outputs.json'), ($lab | ConvertTo-Json -Depth 30))
            $statePath = Join-Path $fixtureDirectory 'state.json'
            & (Join-Path $PSScriptRoot '../scripts/New-LabState.ps1') -StatePath $statePath -SubscriptionId $state.subscriptionId -TenantId $state.tenantId -LabId $state.labId -MinimalPrompt:$minimalPrompt
            $newState = Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable
            Confirm-Accepted { Assert-LabState $newState; if ($newState.minimalPrompt -ne $minimalPrompt) { throw 'New state lost profile' } }
            $originalHash = (Get-FileHash $statePath).Hash
            Confirm-Rejected { & (Join-Path $PSScriptRoot '../scripts/New-LabState.ps1') -StatePath $statePath -SubscriptionId $state.subscriptionId -TenantId $state.tenantId -LabId $state.labId -MinimalPrompt:$minimalPrompt }
            Confirm-Accepted { if ((Get-FileHash $statePath).Hash -ne $originalHash) { throw 'Existing state overwritten' } }
            foreach ($scenario in @('valid','foreign-endpoint','foreign-nic','wrong-target','missing-endpoint','unapproved','public-gateway')) {
                & {
                    function Import-Module { }
                    function az { throw 'Live Azure CLI forbidden' }
                    function Invoke-WebRequest { throw 'Live HTTP forbidden' }
                    function Read-LabRun { return $profileState.Clone() }
                    function Confirm-LabRunContext { Assert-LabState $profileState }
                    function Save-LabRun { $runnerCounter.saves++ }
                    function Invoke-LabAz([hashtable]$State, [string[]]$Arguments, [string]$Label) {
                        if ($State.subscriptionId -ne $profileState.subscriptionId) { throw 'Unexpected subscription' }
                        switch ($Label) {
                            'runner-VerifyPrivate' {
                                $buffer = [IO.MemoryStream]::new()
                                $zip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionMode]::Compress, $true)
                                $bytes = [Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 30 -Compress))
                                $zip.Write($bytes, 0, $bytes.Length)
                                $zip.Dispose()
                                $encoded = [Convert]::ToBase64String($buffer.ToArray())
                                $buffer.Dispose()
                                return @{value=@(@{message="FGL_RESULT_BEGIN`n$encoded`nFGL_RESULT_END"})}
                            }
                            'private-verify-endpoints' {
                                foreach ($target in $targets | Where-Object { $_.endpointId -like "*/resourceGroups/$($Arguments[4])/providers/*" }) {
                                    if ($scenario -eq 'missing-endpoint' -and $target.key -eq 'gateway') { continue }
                                    $owner = if ($scenario -eq 'foreign-endpoint') { $State.tenantId } else { $State.ownershipId }
                                    $status = if ($scenario -eq 'unapproved') { 'Pending' } else { 'Approved' }
                                    $targetId = if ($scenario -eq 'wrong-target') { $lab.runner } else { $target.resourceId }
                                    @{id=$target.endpointId;tags=@{'fgl-owner'=$owner;'fgl-lab'=$State.labId};privateLinkServiceConnections=@(@{privateLinkServiceId=$targetId;groupIds=@($target.groupId);privateLinkServiceConnectionState=@{status=$status}});networkInterfaces=@(@{id=$target.endpointId.Replace('/privateEndpoints/','/networkInterfaces/')})}
                                }
                                return
                            }
                            'private-verify-nic' {
                                $endpointId = $Arguments[4].Replace('/networkInterfaces/','/privateEndpoints/')
                                $target = @($targets | Where-Object endpointId -eq $endpointId)[0]
                                if ($scenario -eq 'foreign-nic') { $endpointId = $lab.runner }
                                return @{id=$Arguments[4];privateEndpoint=@{id=$endpointId};ipConfigurations=@(@{privateIPAddress=$fixtureAddresses[$target.hostName][0]})}
                            }
                            'private-verify-gateway' {
                                return @{id=$lab.gateway;tags=@{'fgl-owner'=$State.ownershipId;'fgl-lab'=$State.labId};publicNetworkAccess=$(if ($scenario -eq 'public-gateway') { 'Enabled' } else { 'Disabled' })}
                            }
                            default { throw "Unexpected transport: $Label" }
                        }
                    }
                    $runnerCounter = @{saves=0}
                    $failure = $null
                    try { $null = & (Join-Path $PSScriptRoot '../scripts/Invoke-LabRunner.ps1') -StatePath $statePath -Action VerifyPrivate } catch { $failure = $_ }
                    if ($scenario -eq 'valid') {
                        Confirm-Accepted { if ($failure) { throw $failure }; if ($runnerCounter.saves -ne 1) { throw 'Private evidence not saved' } }
                    } else {
                        Confirm-Accepted { if (-not $failure -or $runnerCounter.saves -ne 0) { throw "Unsafe runner acceptance: $scenario" } }
                    }
                }
            }
        } finally { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
    }
    Write-Output "PASS: $script:passed local safety checks (synthetic identifiers only)"
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}