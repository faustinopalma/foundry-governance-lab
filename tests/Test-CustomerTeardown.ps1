[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot '../scripts/Remove-CustomerLab.ps1') -DefinitionsOnly
$originalCustomerAz = (Get-Command Invoke-CustomerAz).ScriptBlock
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('customer-teardown-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'original'))
$checks = @{passed=0; deletes=0; reads=0; timeout=$false}
function Confirm-Test($Condition, [string]$Label) {
    if (-not $Condition) { throw "Failed: $Label" }
    $checks.passed++
    if ($timer.Elapsed.TotalSeconds -gt 30) { throw 'Offline test budget exceeded' }
}
function az { throw 'Live Azure forbidden' }
function Invoke-WebRequest { throw 'Live HTTP forbidden' }
function Invoke-RestMethod { throw 'Live HTTP forbidden' }
function Invoke-BoundedLabProcess { throw 'Unmocked process forbidden' }
function Assert-MinimalTeardownAcceptance { throw 'Governance acceptance must not be consulted' }
function Save-LabRun { throw 'Original state must not be written' }
function Write-LabEvent { throw 'Original logs must not be written' }
function Invoke-LabAz { throw 'Unbounded CLI must not be used' }
function New-TestResource([string]$Id, [string]$Type) {
    return @{id=$Id; name=($Id -split '/')[-1]; type=$Type; tags=@{'fgl-owner'=$fixtureState.ownershipId; 'fgl-lab'=$fixtureState.labId}; properties=@{provisioningState='Succeeded'; linkedResourceId=$null; capabilityHostKind=$null; storageConnections=$null; vectorStoreConnections=$null; threadStorageConnections=$null}}
}
function Reset-TestFixture([switch]$Expanded) {
    $script:fixtureStatePath = Join-Path $fixtureRoot 'original/state.json'
    $script:fixtureCleanup = Join-Path $fixtureRoot 'cleanup.json'
    if (Test-Path $fixtureCleanup) { Remove-Item $fixtureCleanup }
    $script:fixtureState = @{labId='sample01'; subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'; ownershipId='33333333-3333-4333-8333-333333333333'; minimalPrompt=$true; resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" }); preexistingGroupIds=@(); runDirectory=(Join-Path $fixtureRoot 'original'); azureConfigDirectory=(Join-Path $fixtureRoot 'azure'); deploymentName='fgl-sample01-activate'; pendingPhase='activate'; destroyAuthorized=$false}
    Write-CustomerJson $fixtureStatePath $fixtureState
    $script:fixtureSubscription = "/subscriptions/$($fixtureState.subscriptionId)"
    $script:fixtureResources = @{}; $script:fixtureGroups = @{}; $script:fixtureNested = @{}; $script:fixtureSal = @{a=@(); b=@()}
    $script:fixtureRoots = @((New-TestResource "$fixtureSubscription/providers/Microsoft.Resources/deployments/fgl-sample01-activate" 'Microsoft.Resources/deployments'))
    $suffixes = @('models','integration','case-a'); if ($Expanded) { $suffixes += 'case-b' }
    foreach ($suffix in $suffixes) {
        $groupId = "$fixtureSubscription/resourceGroups/rg-fgl-sample01-$suffix"
        $fixtureGroups[$groupId] = New-TestResource $groupId 'Microsoft.Resources/resourceGroups'
        $fixtureNested[$groupId] = @()
        if ($suffix -ne 'integration') {
            $code = @{models='models'; 'case-a'='a'; 'case-b'='b'}[$suffix]
            $accountId = "$groupId/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-$code-abcdefghijklm"
            $fixtureResources[$accountId] = New-TestResource $accountId 'Microsoft.CognitiveServices/accounts'
            if ($suffix -ne 'models') {
                $environments = @('dev'); if ($Expanded) { $environments += 'test' }
                foreach ($environment in $environments) {
                    $projectId = "$accountId/projects/$suffix-$environment"
                    $fixtureResources[$projectId] = New-TestResource $projectId 'Microsoft.CognitiveServices/accounts/projects'
                    $fixtureResources[$projectId].name = (($accountId -split '/')[-1]) + '/' + ($projectId -split '/')[-1]
                    $hostId = "$projectId/capabilityHosts/agents"
                    $fixtureResources[$hostId] = New-TestResource $hostId 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts'
                    $fixtureResources[$hostId].properties.capabilityHostKind = 'Agents'
                    $fixtureResources[$hostId].tags = $null
                }
                $hostId = "$accountId/capabilityHosts/$(($accountId -split '/')[-1])@aml_aiagentservice"
                $fixtureResources[$hostId] = New-TestResource $hostId 'Microsoft.CognitiveServices/accounts/capabilityHosts'
                $fixtureResources[$hostId].properties.capabilityHostKind = 'Agents'
                $fixtureResources[$hostId].tags = $null
            }
        }
    }
    $script:fixtureIntegration = "$fixtureSubscription/resourceGroups/rg-fgl-sample01-integration"
    $script:fixtureScope = "$fixtureIntegration/providers/Microsoft.Insights/privateLinkScopes/ampls-fgl-sample01"
    $script:fixtureVnet = "$fixtureIntegration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01"
    $fixtureResources[$fixtureScope] = New-TestResource $fixtureScope 'Microsoft.Insights/privateLinkScopes'
    $fixtureResources[$fixtureVnet] = New-TestResource $fixtureVnet 'Microsoft.Network/virtualNetworks'
    $number = 0
    foreach ($suffix in @($suffixes | Where-Object { $_ -ne 'models' })) {
        foreach ($spec in @(@('log','Microsoft.OperationalInsights/workspaces'),@('appi','Microsoft.Insights/components'))) {
            $monitorId = "$fixtureSubscription/resourceGroups/rg-fgl-sample01-$suffix/providers/$($spec[1])/$($spec[0])-fgl-sample01-$suffix"
            $fixtureResources[$monitorId] = New-TestResource $monitorId $spec[1]
            $linkId = "$fixtureScope/scopedResources/linked-$number"
            $fixtureResources[$linkId] = New-TestResource $linkId 'Microsoft.Insights/privateLinkScopes/scopedResources'
            $fixtureResources[$linkId].properties.linkedResourceId = $monitorId
            $number++
        }
    }
    $foundationPath = Join-Path $fixtureState.runDirectory 'expansion-foundation.state.json'
    if (Test-Path $foundationPath) { Remove-Item $foundationPath }
    if ($Expanded) {
        $rootId = "$fixtureSubscription/providers/Microsoft.Resources/deployments/fgl-sample01-expansion-foundation"
        $script:fixtureRoots += New-TestResource $rootId 'Microsoft.Resources/deployments'
        Write-CustomerJson $foundationPath @{stage='foundation-only'; originalSha=(Get-FileHash $fixtureStatePath).Hash; baseline=@{($fixtureIntegration)=$fixtureGroups[$fixtureIntegration]}; deploymentId=$rootId; pending=$false; verified=$true}
    }
    $checks.deletes=0; $checks.reads=0; $checks.timeout=$false; $checks.pagination=$false; $checks.duplicates=$false; $checks.wrongContext=$false
    $script:fixtureHistory = [Collections.Generic.List[string]]::new()
}
function Invoke-CustomerAz([hashtable]$Binding, [string[]]$Arguments, [switch]$Empty, [switch]$AllowMissingModelWorkspace) {
    Confirm-Test ($Binding.state.subscriptionId -ceq $fixtureState.subscriptionId -and $Binding.timeout -eq 60) 'bound CLI call'
    if ($Arguments[0] -eq 'account') { return @{id=$(if ($checks.wrongContext) { 'foreign' } else { $fixtureState.subscriptionId }); tenantId=$fixtureState.tenantId; state='Enabled'} }
    if ($Empty) {
        $checks.deletes++
        $target = if ($Arguments[0] -eq 'group') { "$fixtureSubscription/resourceGroups/$($Arguments[3])" } else { ([uri]$Arguments[4]).AbsolutePath }
        Confirm-Test ($Arguments -notcontains '--force-deletion-types') 'no force'
        $fixtureHistory.Add($target)
        if ($checks.timeout) { throw 'Synthetic timeout' }
        foreach ($id in @($fixtureResources.Keys)) { if ($id -ieq $target -or $id.StartsWith("$target/", [StringComparison]::OrdinalIgnoreCase)) { $fixtureResources.Remove($id) } }
        $fixtureGroups.Remove($target)
        return
    }
    $checks.reads++
    $id = ([uri]$Arguments[4]).AbsolutePath
    if ($fixtureResources.ContainsKey($id)) { return $fixtureResources[$id] }
    $values = @()
    if ($id -eq "$fixtureSubscription/resourceGroups") { $values = @($fixtureGroups.Values) }
    elseif ($id -eq "$fixtureSubscription/providers/Microsoft.Resources/deployments") { $values = $fixtureRoots }
    elseif ($id.EndsWith('/providers/Microsoft.Resources/deployments')) { $values = $fixtureNested[$id -replace '/providers/Microsoft.Resources/deployments$',''] }
    elseif ($id.EndsWith('/serviceAssociationLinks')) { $values = $fixtureSal[($id -split 'snet-agent-')[1].Substring(0,1)] }
    elseif ($id.EndsWith('/resources')) {
        $group = $id -replace '/resources$',''
        $values = @($fixtureResources.Values | Where-Object { ($_.id -split '/providers/')[0] -eq $group -and $_.type -notmatch '/(projects|capabilityHosts|scopedResources)$' })
    } elseif ($id -match '/(projects|capabilityHosts|scopedResources)$') { $values = @($fixtureResources.Values | Where-Object { $_.id.StartsWith("$id/", [StringComparison]::OrdinalIgnoreCase) -and $_.id.Substring($id.Length+1) -notmatch '/' }) }
    else { throw "Unmocked read: $id" }
    if ($checks.duplicates -and $values.Count) { $values += $values[0] }
    return @{value=@($values); nextLink=$(if ($checks.pagination) { 'https://example.invalid/next' } else { $null })}
}
function Invoke-TestAction([string]$Action, [switch]$Approved) {
    Invoke-CustomerTeardown -StatePath $fixtureStatePath -CleanupPath $fixtureCleanup -Action $Action -ApproveDestroy:$Approved -ConfirmLabId sample01
}
function Confirm-Blocked([scriptblock]$Body, [string]$Message) {
    $before = $checks.deletes; $caught = $false
    try { & $Body | Out-Null } catch { $caught = $true; Confirm-Test ($_.Exception.Message -like "*$Message*") "expected guard: $Message ($($_.Exception.Message))" }
    Confirm-Test $caught "blocked: $Message"
    Confirm-Test ($checks.deletes -eq $before) 'zero destructive calls'
}
try {
    Reset-TestFixture -Expanded
    $runtimePath=Join-Path $fixtureState.runDirectory 'expansion-runtime-a-test.state.json'
    Write-CustomerJson $runtimePath @{pending=$true; verified=$false; deploymentId="$fixtureSubscription/providers/Microsoft.Resources/deployments/fgl-sample01-expansion-runtime-a-test"}
    $script:fixtureRoots += New-TestResource "$fixtureSubscription/providers/Microsoft.Resources/deployments/fgl-sample01-expansion-runtime-a-test" 'Microsoft.Resources/deployments'
    $initialHashes = @{}; Get-ChildItem $fixtureState.runDirectory -File | ForEach-Object { $initialHashes[$_.FullName]=(Get-FileHash $_.FullName).Hash }
    Confirm-Test ((Invoke-TestAction Plan).groups.Count -eq 4) 'expanded plan'
    Confirm-Test ($checks.reads -lt 35) 'bounded targeted inventory, not individual generic resource reads'
    Confirm-Blocked { Invoke-TestAction Step } 'fresh ApproveDestroy'
    $status = Invoke-TestAction Status
    Confirm-Test ($status.next.kind -eq 'link') 'AMPLS first'
    $iterations = 0
    do {
        $before = $checks.deletes; $result = Invoke-TestAction Step -Approved; $iterations++
        Confirm-Test (($checks.deletes-$before) -le 1) 'one destructive call per Step'
        if ($iterations -gt 25) { throw 'Cleanup did not finish' }
    } while ($result.status -ne 'Complete')
    Confirm-Test ($checks.deletes -eq 21) 'six links, eight project operations, three accounts, four groups'
    Confirm-Test ($fixtureHistory[$fixtureHistory.Count-1] -eq $fixtureIntegration) 'integration last'
    Confirm-Test (@($fixtureHistory | Where-Object { $_ -match '/accounts/[^/]+/capabilityHosts/' }).Count -eq 0) 'account hosts never manually removed'
    $expectedOrder=@(0..5 | ForEach-Object { "$fixtureScope/scopedResources/linked-$_" })
    foreach ($suffix in @('case-a','case-b','models')) {
        $code=@{'case-a'='a'; 'case-b'='b'; models='models'}[$suffix]
        $accountId="$fixtureSubscription/resourceGroups/rg-fgl-sample01-$suffix/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-$code-abcdefghijklm"
        if ($suffix -ne 'models') {
            foreach ($environment in @('dev','test')) { $expectedOrder+="$accountId/projects/$suffix-$environment/capabilityHosts/agents" }
            foreach ($environment in @('dev','test')) { $expectedOrder+="$accountId/projects/$suffix-$environment" }
        }
        $expectedOrder+=$accountId; $expectedOrder+="$fixtureSubscription/resourceGroups/rg-fgl-sample01-$suffix"
    }
    $expectedOrder+=$fixtureIntegration
    Confirm-Test (($fixtureHistory.ToArray() -join '|') -ceq ($expectedOrder -join '|')) 'exact expanded dependency order'
    Confirm-Test ((Invoke-TestAction Status).status -eq 'Complete') 'fresh final absence'
    foreach ($path in $initialHashes.Keys) { Confirm-Test ((Get-FileHash $path).Hash -ceq $initialHashes[$path]) 'source bytes preserved' }
    Reset-TestFixture
    Confirm-Test ((Invoke-TestAction Plan).groups.Count -eq 3) 'minimal plan'
    Confirm-Blocked { Invoke-TestAction Plan } 'manifest exists'
    $checks.timeout=$true
    try { Invoke-TestAction Step -Approved | Out-Null } catch { Confirm-Test ($_.Exception.Message -eq 'Synthetic timeout') 'timeout surfaced' }
    $before=$checks.deletes
    Confirm-Test ((Invoke-TestAction Step -Approved).status -eq 'Pending') 'ambiguous deletion not replayed'
    Confirm-Test ($checks.deletes -eq $before) 'no retry'
    Reset-TestFixture
    $fixtureState.preexistingGroupIds=@($fixtureIntegration); Write-CustomerJson $fixtureStatePath $fixtureState
    Confirm-Blocked { Invoke-TestAction Plan } 'Preexisting'
    Reset-TestFixture
    $fixtureGroups[$fixtureIntegration].tags['fgl-owner']='foreign'
    Confirm-Blocked { Invoke-TestAction Plan } 'ownership'
    Reset-TestFixture
    $fixtureRoots[0].properties.provisioningState='Running'
    Confirm-Blocked { Invoke-TestAction Plan } 'root deployment'
    Reset-TestFixture
    $deployment=New-TestResource "$fixtureIntegration/providers/Microsoft.Resources/deployments/nested" 'Microsoft.Resources/deployments'
    $deployment.properties.provisioningState='Running'; $fixtureNested[$fixtureIntegration]=@($deployment)
    Confirm-Blocked { Invoke-TestAction Plan } 'nested deployment'
    Reset-TestFixture
    $fixtureResources["$fixtureScope/scopedResources/linked-0"].properties.linkedResourceId='/subscriptions/foreign/monitor'
    Confirm-Blocked { Invoke-TestAction Plan } 'AMPLS target'
    Reset-TestFixture
    $null=Invoke-TestAction Plan
    $unknown="$fixtureIntegration/providers/Microsoft.Storage/storageAccounts/unexpected"
    $fixtureResources[$unknown]=New-TestResource $unknown 'Microsoft.Storage/storageAccounts'
    Confirm-Blocked { Invoke-TestAction Step -Approved } 'after inventory'
    Reset-TestFixture
    $checks.wrongContext=$true
    Confirm-Blocked { Invoke-TestAction Plan } 'context'
    Reset-TestFixture
    $checks.pagination=$true
    Confirm-Blocked { Invoke-TestAction Plan } 'unpaginated'
    Reset-TestFixture
    $checks.duplicates=$true
    Confirm-Blocked { Invoke-TestAction Plan } 'duplicate'
    Reset-TestFixture
    $null=Invoke-TestAction Plan
    Confirm-Blocked { Invoke-CustomerTeardown -StatePath $fixtureStatePath -CleanupPath $fixtureCleanup -Action Step -ApproveDestroy -ConfirmLabId SAMPLE01 } 'exact ConfirmLabId'
    foreach ($badValue in @('foreign',$true)) {
        foreach ($field in @('labId','ownershipId','subscriptionId','tenantId','statePath','resourceGroups','version')) {
            Reset-TestFixture
            $null=Invoke-TestAction Plan
            $manifest=Read-CustomerJson $fixtureCleanup
            $manifest[$field]=$badValue; Write-CustomerJson $fixtureCleanup $manifest
            Confirm-Blocked { Invoke-TestAction Step -Approved } 'binding mismatch'
        }
    }
    Reset-TestFixture
    $null=Invoke-TestAction Plan
    $fixtureState.pendingPhase=$null; Write-CustomerJson $fixtureStatePath $fixtureState
    Confirm-Blocked { Invoke-TestAction Step -Approved } 'state or foundation changed'
    Reset-TestFixture -Expanded
    $foundationPath=Join-Path $fixtureState.runDirectory 'expansion-foundation.state.json'
    $foundation=Read-CustomerJson $foundationPath
    $groupB="$fixtureSubscription/resourceGroups/rg-fgl-sample01-case-b"
    $foundation.baseline[$groupB]=$fixtureGroups[$groupB]; Write-CustomerJson $foundationPath $foundation
    Confirm-Blocked { Invoke-TestAction Plan } 'Preexisting expansion'
    Reset-TestFixture -Expanded
    $foundation=Read-CustomerJson $foundationPath; $foundation.originalSha='foreign'; Write-CustomerJson $foundationPath $foundation
    Confirm-Blocked { Invoke-TestAction Plan } 'foundation manifest'
    Reset-TestFixture -Expanded
    Remove-Item $foundationPath
    Confirm-Blocked { Invoke-TestAction Plan } 'without a foundation'
    Reset-TestFixture
    Confirm-Blocked { Invoke-CustomerTeardown -StatePath $fixtureStatePath -CleanupPath (Join-Path $fixtureState.runDirectory 'cleanup.json') -Action Plan } 'outside the original'
    Confirm-Blocked { Invoke-CustomerTeardown -StatePath $fixtureStatePath -CleanupPath (Join-Path $PSScriptRoot 'cleanup.json') -Action Plan } 'outside the public'
    foreach ($after in @($false,$true)) {
        foreach ($kind in @('project','accountHost','projectHost','link')) {
            Reset-TestFixture
            if ($after) { $null=Invoke-TestAction Plan }
            $accountId=@($fixtureResources.Keys | Where-Object { $_ -match '/accounts/aif-fgl-sample01-a-[a-z]+$' })[0]
            $projectId="$accountId/projects/case-a-dev"
            $target=switch ($kind) { project { "$accountId/projects/foreign" }; accountHost { "$accountId/capabilityHosts/foreign" }; projectHost { "$projectId/capabilityHosts/foreign" }; link { "$fixtureScope/scopedResources/foreign" } }
            $type=switch ($kind) { project { 'Microsoft.CognitiveServices/accounts/projects' }; accountHost { 'Microsoft.CognitiveServices/accounts/capabilityHosts' }; projectHost { 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts' }; link { 'Microsoft.Insights/privateLinkScopes/scopedResources' } }
            $fixtureResources[$target]=New-TestResource $target $type
            Confirm-Blocked { if ($after) { Invoke-TestAction Step -Approved } else { Invoke-TestAction Plan } } 'Unknown'
        }
    }
    foreach ($tag in @('fgl-owner','fgl-lab')) {
        Reset-TestFixture
        $null=Invoke-TestAction Plan
        $fixtureResources[$fixtureVnet].tags[$tag]='foreign'
        Confirm-Blocked { Invoke-TestAction Step -Approved } 'ownership'
    }
    Reset-TestFixture
    $null=Invoke-TestAction Plan
    $fixtureResources[$fixtureVnet].tags=@{}
    Confirm-Blocked { Invoke-TestAction Step -Approved } 'ownership tags changed'
    Reset-TestFixture
    $fixtureState.preexistingGroupIds=@($true); Write-CustomerJson $fixtureStatePath $fixtureState
    Confirm-Blocked { Invoke-TestAction Plan } 'Malformed preexisting'
    Reset-TestFixture
    $fixtureResources[$fixtureVnet].type=$true
    Confirm-Blocked { Invoke-TestAction Plan } 'type mismatch'
    foreach ($subnet in @('a','b')) {
        Reset-TestFixture
        $null=Invoke-TestAction Plan
        do { $result=Invoke-TestAction Step -Approved; $status=Invoke-TestAction Status } while ($status.next.id -ne $fixtureIntegration)
        $fixtureSal[$subnet]=@((New-TestResource "$fixtureVnet/subnets/snet-agent-$subnet/serviceAssociationLinks/service" 'Microsoft.Network/virtualNetworks/subnets/serviceAssociationLinks'))
        Confirm-Blocked { Invoke-TestAction Step -Approved } 'serviceAssociationLinks'
        Confirm-Test ($fixtureGroups.ContainsKey($fixtureIntegration)) 'integration retained for SAL residue'
        $fixtureSal[$subnet]=@()
        Confirm-Test ((Invoke-TestAction Step -Approved).target -eq $fixtureIntegration) 'integration proceeds after empty SAL'
        Confirm-Test ((Invoke-TestAction Status).status -eq 'Complete') 'minimal teardown completes'
    }
    Reset-TestFixture
    $null=Invoke-TestAction Plan
    $linkId="$fixtureScope/scopedResources/linked-0"
    $null=Invoke-TestAction Step -Approved
    $null=Invoke-TestAction Step -Approved
    $fixtureResources[$linkId]=New-TestResource $linkId 'Microsoft.Insights/privateLinkScopes/scopedResources'
    $fixtureResources[$linkId].properties.linkedResourceId="$fixtureIntegration/providers/Microsoft.OperationalInsights/workspaces/log-fgl-sample01-integration"
    Confirm-Blocked { Invoke-TestAction Step -Approved } 'reappeared'
    & {
        function Get-Command([string]$Name, $CommandType, $ErrorAction) { if ($Name -eq 'az') { return @{Source=(Join-Path $PSHOME 'pwsh.exe')} }; Microsoft.PowerShell.Core\Get-Command $Name }
        function Invoke-BoundedLabProcess($Executable, $Arguments, $LogPrefix, $MaxSeconds, $IdleSeconds, $Environment) {
            Confirm-Test ($MaxSeconds -eq 37 -and $IdleSeconds -eq 37) 'supervisor bounds each CLI call'
            Confirm-Test ($Environment.AZURE_CONFIG_DIR -eq $fixtureState.azureConfigDirectory) 'isolated CLI context'
            Confirm-Test ($Arguments -contains $fixtureState.subscriptionId -and $Arguments -contains '--subscription') 'explicit subscription on every CLI call'
            Confirm-Test ($LogPrefix.StartsWith("$fixtureCleanup.logs")) 'logs outside original run'
            $stdout=Join-Path $fixtureRoot 'mock-stdout.json'; Write-CustomerJson $stdout @{ok=$true}
            $stderr=Join-Path $fixtureRoot 'mock-stderr.txt'; [IO.File]::WriteAllText($stderr, '')
            if ($checks.workspaceError) { [IO.File]::WriteAllText($stdout, ''); [IO.File]::WriteAllText($stderr, $checks.workspaceError) }
            return @{reason=$(if ($checks.timeout) { 'Deadline' } else { 'Exited' }); exitCode=$(if ($checks.workspaceError) { 1 } else { 0 }); stdout=$stdout; stderr=$stderr}
        }
        $probeBinding=Get-CustomerBinding $fixtureStatePath $fixtureCleanup
        $probeBinding.timeout=37; $probeBinding.logDirectory="$fixtureCleanup.logs"
        $checks.timeout=$false
        Confirm-Test ((& $originalCustomerAz $probeBinding @('account','show')).ok) 'actual wrapper parses supervised output'
        $modelUrl="https://management.azure.com$fixtureSubscription/resourceGroups/rg-fgl-sample01-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-abcdefghijklm/capabilityHosts?api-version=2026-05-01"
        $modelArguments=@('rest','--method','get','--url',$modelUrl,'--query','{value:value,nextLink:nextLink}')
        $checks.workspaceError='ERROR: Workspace not found.'
        Confirm-Test ((& $originalCustomerAz $probeBinding $modelArguments -AllowMissingModelWorkspace).value.Count -eq 0) 'model-only missing workspace is an empty host collection'
        Confirm-Blocked { & $originalCustomerAz $probeBinding $modelArguments } 'CLI failed'
        $foreignArguments=$modelArguments.Clone(); $foreignArguments[4]=$modelUrl.Replace('-models','-case-a')
        Confirm-Blocked { & $originalCustomerAz $probeBinding $foreignArguments -AllowMissingModelWorkspace } 'CLI failed'
        $checks.workspaceError='ERROR: AuthorizationFailed'
        Confirm-Blocked { & $originalCustomerAz $probeBinding $modelArguments -AllowMissingModelWorkspace } 'CLI failed'
        $checks.workspaceError='ERROR: Workspace not found.'; $checks.timeout=$true
        Confirm-Blocked { & $originalCustomerAz $probeBinding $modelArguments -AllowMissingModelWorkspace } 'CLI failed'
        $checks.workspaceError=$null
        $checks.timeout=$true
        Confirm-Blocked { & $originalCustomerAz $probeBinding @('account','show') } 'timed out'
    }
    Write-Output "Customer teardown: $($checks.passed) assertions passed; mocked only."
} finally { if (Test-Path $fixtureRoot) { Remove-Item $fixtureRoot -Recurse -Force } }