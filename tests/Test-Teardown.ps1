[CmdletBinding()]
param()

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ("fgl-teardown-test-$([guid]::NewGuid().ToString('N'))")
try {
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1')
    . (Join-Path $PSScriptRoot '../scripts/Remove-LabRun.ps1') -DefinitionsOnly
    $null = New-Item -ItemType Directory -Path $fixtureDirectory
    $script:passed = 0
    function Confirm-Equal($Actual, $Expected, [string]$Label) {
        if ($Actual -cne $Expected) { throw "Failed: $Label; expected $Expected, received $Actual" }
        $script:passed++
    }
    function az { throw 'Live Azure CLI is forbidden in local tests' }
    function Invoke-WebRequest { throw 'Live HTTP is forbidden in local tests' }
    function New-FixtureResource([string]$Id, [string]$Type) {
        return @{id=$Id; type=$Type; name=($Id -split '/')[-1]; tags=@{'fgl-owner'=$script:state.ownershipId; 'fgl-lab'=$script:state.labId}; properties=@{provisioningState='Succeeded'}}
    }
    function Save-FixtureEvidence {
        [IO.File]::WriteAllText($script:state.teardownEvidence.path, ($script:snapshot | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        $script:state.teardownEvidence.sha256 = (Get-FileHash -LiteralPath $script:state.teardownEvidence.path).Hash
    }
    function Reset-Fixture([switch]$MinimalPrompt) {
        $script:state = @{
            subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'; ownershipId='33333333-3333-4333-8333-333333333333'
            labId='sample01'; phase='activate'; pendingPhase=$null; deploymentName='fgl-sample01-activate'; deploymentAuthorized=$true; destroyAuthorized=$true
            resourceGroups=@('models','integration','case-a','case-b') | ForEach-Object { "rg-fgl-sample01-$_" }
            preexistingGroupIds=@(); teardownEvidence=@{path=(Join-Path $fixtureDirectory 'evidence.json'); sha256=''}
        }
        if ($MinimalPrompt) {
            $script:state.minimalPrompt = $true
            $script:state.resourceGroups = @($script:state.resourceGroups | Where-Object { $_ -ne 'rg-fgl-sample01-case-b' })
        }
        $script:prefix = "/subscriptions/$($script:state.subscriptionId)/resourceGroups"
        $script:groups = @($script:state.resourceGroups | ForEach-Object { New-FixtureResource "$script:prefix/$_" 'Microsoft.Resources/resourceGroups' })
        $script:scope = New-FixtureResource "$script:prefix/rg-fgl-sample01-integration/providers/Microsoft.Insights/privateLinkScopes/ampls-fgl-sample01" 'Microsoft.Insights/privateLinkScopes'
        $script:account = New-FixtureResource "$script:prefix/rg-fgl-sample01-case-a/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-a-synthetic" 'Microsoft.CognitiveServices/accounts'
        $script:links = @{value=@()}
        $script:projects = @{value=@('dev','test') | ForEach-Object { New-FixtureResource "$($script:account.id)/projects/case-a-$_" 'Microsoft.CognitiveServices/accounts/projects' }}
        if ($MinimalPrompt) { $script:projects.value = @($script:projects.value[0]) }
        $script:snapshot = @{groups=$script:groups; resources=@($script:scope,$script:account); deployments=@()}
        $index = 0
        foreach ($suffix in @('integration','case-a','case-b') | Where-Object { "rg-fgl-sample01-$_" -in $script:state.resourceGroups }) {
            foreach ($type in @('Microsoft.OperationalInsights/workspaces','Microsoft.Insights/components')) {
                $monitor = New-FixtureResource "$script:prefix/rg-fgl-sample01-$suffix/providers/$type/monitor-$index" $type
                $script:snapshot.resources += $monitor
                $link = New-FixtureResource "$($script:scope.id)/scopedResources/linked-$index" 'Microsoft.Insights/privateLinkScopes/scopedResources'
                $link.properties.linkedResourceId = $monitor.id
                $null = $link.Remove('tags')
                $script:links.value += $link
                $index++
            }
        }
        Save-FixtureEvidence
        $script:roots = @{items=@(@{name=$script:state.deploymentName; id="/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$($script:state.deploymentName)"; properties=@{provisioningState='Failed'}})}
        $script:nested = @{}
        foreach ($group in $script:groups) { $script:nested[$group.name] = @{items=@(@{id="$($group.id)/providers/Microsoft.Resources/deployments/nested"; name='nested'; properties=@{provisioningState='Succeeded'}})} }
        $script:inventory = @{items=@($script:snapshot.resources | Where-Object { ($_.id -split '/providers/')[0] -eq "$script:prefix/rg-fgl-sample01-case-a" })}
        $script:context = @{id=$script:state.subscriptionId; tenantId=$script:state.tenantId; state='Enabled'}
        $script:calls = [Collections.Generic.List[object]]::new()
        $script:saves = 0
        $script:guardCounters = @{acceptance=0; context=0}
        $script:acceptanceFailure = ''
        $script:standardRest = @{}
    }
    function Reset-StandardFixture([switch]$CreatedAccountHost) {
        Reset-Fixture -MinimalPrompt
        $script:state.runDirectory = $fixtureDirectory
        $script:state.standard = @{completedStages=@('dependencies','account','project','access'); pendingStage=$null; deploymentNames=@{dependencies='fgl-sample01-standard-dependencies'; project='fgl-sample01-standard-project'; access='fgl-sample01-standard-access'}}
        $script:state.standard.accountHostId = "$($script:account.id)/capabilityHosts/$($script:account.name)@aml_aiagentservice"
        if ($CreatedAccountHost) { $script:state.standard.deploymentNames.account = 'fgl-sample01-standard-account'; $script:state.standard.accountHostId = "$($script:account.id)/capabilityHosts/agents" }
        $script:standardBindingFixture = @{accountId=$script:account.id; projectId=$script:projects.value[0].id; connections=@{}; capabilityHosts=@{project="$($script:projects.value[0].id)/capabilityHosts/agents"}; vnetId="$script:prefix/rg-fgl-sample01-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01"}
        $script:standardBindingFixture.subnetId = "$($script:standardBindingFixture.vnetId)/subnets/snet-case-a-pe"
        $services = @{storage=@('stfglsample01abcdef','Microsoft.Storage/storageAccounts'); search=@('srch-fgl-sample01-standard','Microsoft.Search/searchServices'); cosmos=@('cosmos-fgl-sample01-standard','Microsoft.DocumentDB/databaseAccounts')}
        foreach ($key in $services.Keys) {
            $name, $type = $services[$key]
            $script:standardBindingFixture[$key] = @{name=$name; id="$script:prefix/rg-fgl-sample01-case-a/providers/$type/$name"}
            $script:standardBindingFixture.connections[$key] = @{name=$name; id="$($script:standardBindingFixture.projectId)/connections/$name"}
        }
        [IO.File]::WriteAllText((Join-Path $fixtureDirectory 'standard-outputs.json'), (@{dependencies=$script:standardBindingFixture} | ConvertTo-Json -Depth 30))
        $script:projectHostFixture = New-FixtureResource $script:standardBindingFixture.capabilityHosts.project 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts'
        $null = $script:projectHostFixture.Remove('tags')
        $script:projectHostFixture.properties.capabilityHostKind = 'Agents'
        $script:projectHostFixture.properties.storageConnections = @($services.storage[0])
        $script:projectHostFixture.properties.vectorStoreConnections = @($services.search[0])
        $script:projectHostFixture.properties.threadStorageConnections = @($services.cosmos[0])
        $accountHostFixture = New-FixtureResource $script:state.standard.accountHostId 'Microsoft.CognitiveServices/accounts/capabilityHosts'
        $null = $accountHostFixture.Remove('tags')
        $script:snapshot.children = @($script:projects.value[0],$script:projectHostFixture,$accountHostFixture)
        $script:snapshot.resources += New-FixtureResource $script:standardBindingFixture.vnetId 'Microsoft.Network/virtualNetworks'
        Save-FixtureEvidence
        $script:roots.items = @(@('bootstrap','lock','activate') | ForEach-Object { @{name="fgl-sample01-$_"; id="/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-sample01-$_"; properties=@{provisioningState='Succeeded'}} })
        foreach ($rootName in $script:state.standard.deploymentNames.Values) { $script:roots.items += @{name=$rootName; id="/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/$rootName"; properties=@{provisioningState='Succeeded'}} }
        $script:projectHostsUrl = "https://management.azure.com$($script:standardBindingFixture.projectId)/capabilityHosts?api-version=2026-05-01"
        $script:salUrl = "https://management.azure.com$($script:standardBindingFixture.vnetId)/subnets/snet-agent-a/serviceAssociationLinks?api-version=2024-05-01"
        $script:standardRest[$script:projectHostsUrl] = @{value=@($script:projectHostFixture)}
        $script:standardRest[$script:salUrl] = @{value=@()}
        $script:standardRest["https://management.azure.com$($script:account.id)/capabilityHosts?api-version=2026-05-01"] = @{value=@($accountHostFixture)}
        $script:standardRest["https://management.azure.com$($accountHostFixture.id)?api-version=2026-05-01"] = $accountHostFixture
        $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    }
    function Assert-MinimalTeardownAcceptance([hashtable]$State) {
        $script:guardCounters.acceptance++
        if ($script:acceptanceFailure) { throw $script:acceptanceFailure }
    }
    function Read-LabRun([string]$StatePath) { return $script:state }
    function Save-LabRun { $script:saves++ }
    function Confirm-LabRunContext([hashtable]$State) {
        $script:guardCounters.context++
        Assert-LabContext $State $script:context
        foreach ($group in $script:groups) { Assert-LabGroupOwnership $State $group }
        return $script:groups
    }
    function Invoke-LabAz([hashtable]$State, [string[]]$Arguments, [string]$Label) {
        if ($State.subscriptionId -ne '11111111-1111-4111-8111-111111111111') { throw 'Unexpected subscription' }
        $script:calls.Add(@{arguments=$Arguments; label=$Label})
        switch ($Label) {
            'teardown-roots' { return $script:roots }
            'teardown-group' { return @($script:groups | Where-Object name -eq $Arguments[3])[0] }
            'teardown-nested' { return $script:nested[$Arguments[4]] }
            'teardown-inventory' { return $script:inventory }
            'teardown-get' {
                $url = $Arguments[4]
                if ($script:standardRest.ContainsKey($url)) { return $script:standardRest[$url] }
                if ($url -ceq "https://management.azure.com$($script:scope.id)?api-version=2021-07-01-preview") { return $script:scope }
                if ($url -ceq "https://management.azure.com$($script:scope.id)/scopedResources?api-version=2021-07-01-preview") { return $script:links }
                if ($url -ceq "https://management.azure.com$($script:account.id)?api-version=2026-05-01") { return $script:account }
                if ($url -ceq "https://management.azure.com$($script:account.id)/projects?api-version=2026-05-01") { return $script:projects }
                throw "Unexpected ARM request: $url"
            }
            'teardown-delete' { return }
            { $_ -like 'evidence-*' } { return @($script:snapshot.resources | Where-Object { ($_.id -split '/providers/')[0] -eq "$script:prefix/$($Arguments[3])" }) }
            { $_ -like 'deployments-*' } { return @() }
            { $_ -in @('delete-rg-fgl-sample01-case-a','delete-rg-fgl-sample01-case-b','delete-rg-fgl-sample01-models','delete-rg-fgl-sample01-integration') } { return }
            default { throw "Unexpected command: $Label; no live execution allowed" }
        }
    }
    function Confirm-Blocked([string]$Action, [string]$Message) {
        $errorText = ''
        try { $null = Invoke-LabTeardown 'synthetic-state' $Action } catch { $errorText = $_.Exception.Message }
        Confirm-Equal ($errorText -like "*$Message*") $true "Expected blocker: $Message; received: $errorText"
        Confirm-Equal @($script:calls | Where-Object { $_.label -eq 'teardown-delete' -or $_.label -like 'delete-*' }).Count 0 'No delete on failed guard'
        Confirm-Equal $script:saves 0 'No state mutation on failed guard'
    }
    Reset-Fixture
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    $deletes = @($script:calls | Where-Object label -eq 'teardown-delete')
    Confirm-Equal $deletes.Count 1 'At most one dependency removed'
    Confirm-Equal ($deletes[0].arguments -join ' ') "rest --method delete --url https://management.azure.com$($script:scope.id)/scopedResources/linked-2?api-version=2021-07-01-preview" 'Only exact current-group link'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-nested').Count 4 'All four groups checked for active nested deployments'
    Confirm-Equal $script:saves 0 'Dependency deletion does not advance group lifecycle'
    Confirm-Equal $script:guardCounters.acceptance 0 'Full legacy profile does not require minimal acceptance'
    Reset-Fixture
    Confirm-Blocked 'Next' 'Run -Action Dependencies'
    Reset-Fixture
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    $deletes = @($script:calls | Where-Object label -eq 'teardown-delete')
    Confirm-Equal $deletes.Count 1 'Only one Foundry project removed'
    Confirm-Equal $deletes[0].arguments[4] "https://management.azure.com$($script:account.id)/projects/case-a-dev?api-version=2026-05-01" 'Exact project API and ID'
    Reset-Fixture
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    foreach ($project in $script:projects.value) { $project.name = "$($script:account.name)/$($project.name)" }
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete')[0].arguments[4] "https://management.azure.com$($script:account.id)/projects/case-a-dev?api-version=2026-05-01" 'Qualified service project names retain exact child ID'
    Reset-Fixture
    $script:projects.value[0].name = 'foreign-account/case-a-dev'
    Confirm-Blocked 'Dependencies' 'Unknown Foundry project'
    Reset-Fixture
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    $script:projects.value = @()
    Confirm-Blocked 'Next' 'Run -Action Dependencies'
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    $deletes = @($script:calls | Where-Object label -eq 'teardown-delete')
    Confirm-Equal $deletes.Count 1 'One account delete only after projects are absent'
    Confirm-Equal $deletes[0].arguments[4] "https://management.azure.com$($script:account.id)?api-version=2026-05-01" 'Exact captured account deletion before group'
    Confirm-Equal $script:saves 0 'Account deletion does not advance group lifecycle'
    Reset-Fixture
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    $script:inventory.items = @($script:inventory.items | Where-Object id -ne $script:account.id)
    $message = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    Confirm-Equal ($message -like 'Dependencies clear*') $true 'Ready dependency pass is read-only'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete').Count 0 'No deletion when dependencies clear'
    $null = Invoke-LabTeardown 'synthetic-state' 'Next'
    Confirm-Equal @($script:calls | Where-Object label -eq 'delete-rg-fgl-sample01-case-a').Count 1 'Group delete only after prerequisites'
    Confirm-Equal $script:state.phase 'destroy' 'Group lifecycle advances'
    foreach ($action in @('Dependencies','Next')) {
        Reset-Fixture
        $script:state.teardownEvidence.sha256 = 'tampered'
        Confirm-Blocked $action 'Intact external evidence'
        Reset-Fixture
        $script:roots.items[0].properties.provisioningState = 'Running'
        Confirm-Blocked $action 'Root deployment is still active'
        Reset-Fixture
        $script:nested['rg-fgl-sample01-integration'].items[0].properties.provisioningState = 'Running'
        Confirm-Blocked $action 'Nested deployment is still active'
        foreach ($status in @('Creating','Deleting','Updating','Unknown','')) {
            Reset-Fixture
            $script:account.properties.provisioningState = $status
            Confirm-Blocked $action 'Account state blocks teardown'
        }
        Reset-Fixture
        $script:projects.value[0].properties.provisioningState = 'Deleting'
        Confirm-Blocked $action 'Project state blocks teardown'
        Reset-Fixture
        $script:groups[2].properties.provisioningState = 'Deleting'
        Confirm-Blocked $action 'Group state blocks teardown'
        foreach ($list in @('links','projects','roots','inventory')) {
            Reset-Fixture
            (Get-Variable $list -Scope Script -ValueOnly).nextLink = 'https://example.invalid/next'
            Confirm-Blocked $action 'Incomplete teardown list'
        }
        Reset-Fixture
        $script:links.value = $script:links.value[0]
        Confirm-Blocked $action 'Incomplete teardown list'
        Reset-Fixture
        $script:roots.items = @()
        Confirm-Blocked $action 'Root deployment evidence is missing'
        Reset-Fixture
        $script:snapshot.resources = @()
        Save-FixtureEvidence
        Confirm-Blocked $action 'Empty teardown evidence'
        Reset-Fixture
        $script:context.tenantId = $script:state.subscriptionId
        Confirm-Blocked $action 'Azure context does not match'
        Reset-Fixture
        $script:state.destroyAuthorized = $false
        Confirm-Blocked $action 'Teardown authorization is missing'
        Reset-Fixture
        $script:groups[1].tags['fgl-owner'] = $script:state.tenantId
        Confirm-Blocked $action 'ownership record'
        Reset-Fixture
        $script:scope.tags['fgl-owner'] = $script:state.tenantId
        Confirm-Blocked $action 'Dependency resource ownership'
        Reset-Fixture
        $script:projects.value[0].tags['fgl-owner'] = $script:state.tenantId
        Confirm-Blocked $action 'Dependency resource ownership'
        Reset-Fixture
        $script:projects.value[0].name = 'unrelated'
        Confirm-Blocked $action 'Unknown Foundry project'
        Reset-Fixture
        $script:projects.value[0].id = $script:projects.value[0].id.Replace('case-a/providers','case-b/providers')
        Confirm-Blocked $action 'Dependency resource ownership'
        foreach ($field in @('id','type','name')) {
            Reset-Fixture
            $script:links.value[0][$field] += '-unknown'
            Confirm-Blocked $action 'Unknown AMPLS link'
        }
        Reset-Fixture
        $script:links.value[2].properties.linkedResourceId = $script:account.id
        Confirm-Blocked $action 'Unknown AMPLS link'
        Reset-Fixture
        $script:links.value[2].properties.linkedResourceId = $script:links.value[4].properties.linkedResourceId
        Confirm-Blocked $action 'declared lab mapping'
        Reset-Fixture
        $script:links.value[2].properties.linkedResourceId += '-unknown'
        Confirm-Blocked $action 'Unknown AMPLS link'
        Reset-Fixture
        $script:inventory.items += New-FixtureResource "$script:prefix/rg-fgl-sample01-case-a/providers/Example.Service/items/new" 'Example.Service/items'
        Confirm-Blocked $action 'Resource appeared after evidence capture'
        Reset-Fixture
        $script:snapshot.resources[0].id = $script:scope.id.Replace('rg-fgl-sample01-integration','foreign-group')
        Save-FixtureEvidence
        Confirm-Blocked $action 'outside the exact lab'
    }
    foreach ($action in @('Dependencies','Next')) {
        foreach ($list in @('links','projects','roots','inventory')) {
            Reset-Fixture
            $response = Get-Variable $list -Scope Script -ValueOnly
            $key = if ($list -in @('links','projects')) { 'value' } else { 'items' }
            $response[$key] = $null
            Confirm-Blocked $action 'Incomplete teardown list'
            Reset-Fixture
            $response = Get-Variable $list -Scope Script -ValueOnly
            $response[$key] += $response[$key][0]
            Confirm-Blocked $action 'Invalid or duplicate teardown list IDs'
        }
        Reset-Fixture
        $script:nested['rg-fgl-sample01-case-b'].nextLink = 'https://example.invalid/next'
        Confirm-Blocked $action 'Incomplete teardown list'
        Reset-Fixture
        $script:roots.items += @{id="/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-sample01-bootstrap"; name='fgl-sample01-bootstrap'; properties=@{provisioningState='Running'}}
        Confirm-Blocked $action 'Root deployment is still active'
        Reset-Fixture
        $script:roots.items[0].id = $script:roots.items[0].id.Replace($script:state.subscriptionId, $script:state.tenantId)
        Confirm-Blocked $action 'Unexpected root deployment ID'
        Reset-Fixture
        $script:state.preexistingGroupIds = @($script:groups[1].id)
        Confirm-Blocked $action 'Pre-existing group cannot be adopted'
        Reset-Fixture
        $script:snapshot.resources[0].tags['fgl-owner'] = $script:state.tenantId
        Save-FixtureEvidence
        Confirm-Blocked $action 'Snapshot resource ownership conflict'
        Reset-Fixture
        $script:snapshot.resources[0].type = 'Example.Service/items'
        Save-FixtureEvidence
        Confirm-Blocked $action 'Exactly one captured AMPLS'
        Reset-Fixture
        $script:links.value[2].properties.provisioningState = 'Deleting'
        Confirm-Blocked $action 'AMPLS link state blocks teardown'
        Reset-Fixture
        $script:projects.value[0].type = 'Microsoft.CognitiveServices/accounts/deployments'
        Confirm-Blocked $action 'Dependency resource ownership'
        Reset-Fixture
        $script:account.tags['fgl-lab'] = 'otherlab'
        Confirm-Blocked $action 'Dependency resource ownership'
        Reset-Fixture
        $script:inventory.items[1].tags['fgl-lab'] = 'otherlab'
        Confirm-Blocked $action 'Dependency resource ownership'
        Reset-Fixture
        $script:inventory.items[0] = New-FixtureResource $script:scope.id $script:scope.type
        Confirm-Blocked $action 'inventory scope/type changed'
    }
    Reset-Fixture
    & {
        function Import-Module([string]$Name, [switch]$Force) {
            if ([IO.Path]::GetFileName($Name) -notin @('LabExecution.psm1','LabSafety.psm1','PublicSource.psm1','MinimalTeardownAcceptance.psm1')) { throw 'Unexpected module import' }
        }
        $null = . (Join-Path $PSScriptRoot '../scripts/Remove-LabRun.ps1') -StatePath 'synthetic-state' -Action Dependencies
    }
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete').Count 1 'Actual script entry point uses the same guarded path with mocked module imports'
    Reset-Fixture
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    $script:projects.value = @($script:projects.value[1])
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete')[0].arguments[4] "https://management.azure.com$($script:account.id)/projects/case-a-test?api-version=2026-05-01" 'Remaining singleton project is deleted serially'
    Reset-Fixture
    $script:inventory.items = @($script:inventory.items | Where-Object id -ne $script:account.id)
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    $null = Invoke-LabTeardown 'synthetic-state' 'Next'
    Confirm-Equal @($script:calls | Where-Object label -eq 'delete-rg-fgl-sample01-case-a').Count 1 'Account absent from complete inventory needs no blind delete'
    Confirm-Equal @($script:calls | Where-Object { $_.arguments -contains "https://management.azure.com$($script:account.id)?api-version=2026-05-01" }).Count 0 'Absent account is not queried as though present'
    Reset-Fixture
    $script:inventory.items = @()
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete')[0].arguments[4] "https://management.azure.com$($script:scope.id)/scopedResources/linked-2?api-version=2021-07-01-preview" 'Residual link still removed when linked target is already absent'
    foreach ($suffix in @('case-b','models','integration')) {
        Reset-Fixture
        $remaining = switch ($suffix) { 'case-b' { @('case-b','models','integration') }; 'models' { @('models','integration') }; 'integration' { @('integration') } }
        $script:groups = @($script:groups | Where-Object { ($_.name -replace '^rg-fgl-sample01-', '') -in $remaining })
        $script:inventory.items = @($script:snapshot.resources | Where-Object { ($_.id -split '/providers/')[0] -eq "$script:prefix/rg-fgl-sample01-$suffix" })
        $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
        $deletes = @($script:calls | Where-Object label -eq 'teardown-delete')
        if ($suffix -eq 'models') {
            Confirm-Equal $deletes.Count 0 'Models group does not unlink another group'
        } else {
            $linkName = if ($suffix -eq 'case-b') { 'linked-4' } else { 'linked-0' }
            Confirm-Equal $deletes.Count 1 'Next group has only one dependency write'
            Confirm-Equal $deletes[0].arguments[4] "https://management.azure.com$($script:scope.id)/scopedResources/${linkName}?api-version=2021-07-01-preview" 'Deterministic current-group dependency selection'
        }
    }
    Reset-Fixture
    $script:groups = @($script:groups[1])
    $script:inventory.items = @()
    $null = Invoke-LabTeardown 'synthetic-state' 'Next'
    Confirm-Equal @($script:calls | Where-Object label -eq 'delete-rg-fgl-sample01-integration').Count 1 'Partially deleted final integration group permits an absent AMPLS'
    Reset-Fixture
    foreach ($badId in @("$($script:scope.id)/scopedResources/linked-2?redirect=other", "$($script:scope.id)/scopedResources/../other", $script:scope.id.Replace('management', 'other').Replace('rg-fgl-sample01-integration','foreign-group'))) {
        $rejected = $false
        try { $null = Invoke-TeardownRest $script:state $badId '2021-07-01-preview' 'delete' } catch { $rejected = $true }
        Confirm-Equal $rejected $true 'Malformed or foreign ARM delete ID rejected before transport'
    }
    Confirm-Equal $script:calls.Count 0 'Rejected URLs never reach ARM wrapper'
    Reset-Fixture -MinimalPrompt
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-nested').Count 3 'Minimal profile checks exactly three groups'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete')[0].arguments[4] "https://management.azure.com$($script:scope.id)/scopedResources/linked-2?api-version=2021-07-01-preview" 'Minimal case-a monitor unlink'
    Reset-Fixture -MinimalPrompt
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    $script:projects.value[0].name = "$($script:account.name)/case-a-dev"
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete').Count 1 'Minimal profile deletes only one dev project'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete')[0].arguments[4] "https://management.azure.com$($script:account.id)/projects/case-a-dev?api-version=2026-05-01" 'Minimal project exact ID'
    Reset-Fixture -MinimalPrompt
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    $script:projects.value = @()
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete')[0].arguments[4] "https://management.azure.com$($script:account.id)?api-version=2026-05-01" 'Minimal parent deletion requires absent dev project'
    Reset-Fixture -MinimalPrompt
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    $script:inventory.items = @($script:inventory.items | Where-Object id -ne $script:account.id)
    $null = Invoke-LabTeardown 'synthetic-state' 'Next'
    Confirm-Equal @($script:calls | Where-Object label -eq 'delete-rg-fgl-sample01-case-a').Count 1 'Minimal group deletion after dependencies'
    Reset-Fixture -MinimalPrompt
    $script:groups = @($script:groups[1])
    $script:inventory.items = @($script:snapshot.resources | Where-Object { ($_.id -split '/providers/')[0] -eq $script:groups[0].id })
    $script:links.value = @($script:links.value | Where-Object name -in @('linked-0','linked-1'))
    $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete')[0].arguments[4] "https://management.azure.com$($script:scope.id)/scopedResources/linked-0?api-version=2021-07-01-preview" 'Minimal final integration monitor mapping'
    foreach ($action in @('Dependencies','Next')) {
        Reset-Fixture -MinimalPrompt
        $script:projects.value += New-FixtureResource "$($script:account.id)/projects/case-a-test" 'Microsoft.CognitiveServices/accounts/projects'
        Confirm-Blocked $action 'Unknown Foundry project'
        Reset-Fixture -MinimalPrompt
        $script:links.value[0].name = 'linked-4'
        $script:links.value[0].id = "$($script:scope.id)/scopedResources/linked-4"
        Confirm-Blocked $action 'Unknown AMPLS link'
        Reset-Fixture -MinimalPrompt
        $script:links.value[2].properties.linkedResourceId = $script:links.value[0].properties.linkedResourceId
        Confirm-Blocked $action 'declared lab mapping'
        Reset-Fixture -MinimalPrompt
        $script:state.teardownEvidence.sha256 = 'tampered'
        Confirm-Blocked $action 'Intact external evidence'
        Reset-Fixture -MinimalPrompt
        $script:state.preexistingGroupIds = @($script:groups[2].id)
        Confirm-Blocked $action 'Pre-existing group cannot be adopted'
        Reset-Fixture -MinimalPrompt
        $script:projects.value[0].properties.provisioningState = 'Deleting'
        Confirm-Blocked $action 'Project state blocks teardown'
        Reset-Fixture -MinimalPrompt
        $script:state.phase = 'destroyed'
        Confirm-Blocked $action 'Forbidden lifecycle transition'
    }
    foreach ($deleteAction in @('Advance','Dependencies','Next')) {
        Reset-Fixture
        $script:state.lifecycleMode = 'independent'
        $script:state.destroyAuthorized = $false
        foreach ($approval in @(@($false,'sample01'), @($true,'wronglab'))) {
            $rejected = $false
            try { $null = Invoke-LabTeardown 'synthetic-state' $deleteAction $approval[0] $approval[1] } catch { $rejected = $_.Exception.Message -like '*fresh ApproveTeardown*' }
            Confirm-Equal $rejected $true 'Independent deletion requires exact current consent'
            Confirm-Equal $script:calls.Count 0 'Consent rejection precedes transport'
        }
    }
    Reset-Fixture
    $script:state.lifecycleMode = 'independent'
    $script:state.destroyAuthorized = $false
    $null = Invoke-LabTeardown 'synthetic-state' 'Advance' $true 'sample01'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete').Count 1 'Advance deletes at most one dependency without lab tests'
    Confirm-Equal $script:guardCounters.acceptance 0 'Independent teardown does not require inference acceptance'
    Confirm-Equal $script:state.destroyAuthorized $false 'Dependency deletion does not persist approval'
    Confirm-Equal $script:state.phase 'destroy' 'First deletion prevents a later Create'
    $pendingId = $script:state.teardownPending.id
    $script:calls.Clear()
    $null = Invoke-LabTeardown 'synthetic-state' 'Advance' $true 'sample01'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete').Count 0 'Repeated Advance does not replay a pending dependency'
    Confirm-Equal $script:state.teardownPending.id $pendingId 'Uncertain deletion keeps its exact target'
    $script:links.value = @($script:links.value | Where-Object id -ne $pendingId)
    $null = Invoke-LabTeardown 'synthetic-state' 'Status'
    Confirm-Equal $script:state.ContainsKey('teardownPending') $false 'Status reconciles exact dependency absence'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete').Count 0 'Status never starts the next deletion'
    Reset-Fixture
    $script:state.lifecycleMode = 'independent'
    $script:state.destroyAuthorized = $false
    $script:links.value = @($script:links.value | Where-Object name -notin @('linked-2','linked-3'))
    $script:inventory.items = @($script:inventory.items | Where-Object id -ne $script:account.id)
    $null = Invoke-LabTeardown 'synthetic-state' 'Advance' $true 'sample01'
    Confirm-Equal @($script:calls | Where-Object label -eq 'delete-rg-fgl-sample01-case-a').Count 1 'Advance deletes a group only after dependencies are absent'
    Confirm-Equal $script:state.destroyAuthorized $false 'Deletion does not persist consent for future calls'
    Reset-Fixture
    $script:state.lifecycleMode = 'independent'
    $script:state.destroyAuthorized = $false
    $script:snapshot.resources = @()
    $script:inventory.items = @()
    Save-FixtureEvidence
    $null = Invoke-LabTeardown 'synthetic-state' 'Advance' $true 'sample01'
    Confirm-Equal @($script:calls | Where-Object label -eq 'delete-rg-fgl-sample01-case-a').Count 1 'Partial failed provisioning can remove owned empty groups'
    foreach ($failure in @('Missing acceptance receipt','Tampered acceptance receipt')) {
        foreach ($scenario in @('Evidence','Dependencies','Next','Status','Direct')) {
            Reset-Fixture -MinimalPrompt
            $script:acceptanceFailure = $failure
            $message = ''
            try {
                if ($scenario -eq 'Direct') { $null = Get-TeardownPreparation $script:state $script:groups }
                else { $null = Invoke-LabTeardown 'synthetic-state' $scenario }
            } catch { $message = $_.Exception.Message }
            Confirm-Equal $message $failure 'Acceptance rejection propagated'
            Confirm-Equal $script:guardCounters.acceptance 1 'Acceptance checked first'
            Confirm-Equal $script:guardCounters.context 0 'No context before acceptance'
            Confirm-Equal $script:calls.Count 0 'No transport before acceptance'
            Confirm-Equal $script:saves 0 'No save before acceptance'
        }
    }
    Reset-Fixture -MinimalPrompt
    $script:acceptanceFailure = 'Missing acceptance receipt'
    $script:entryImports = [Collections.Generic.List[string]]::new()
    $entryFailure = ''
    try {
        & {
            function Import-Module([string]$Name, [switch]$Force) {
                $moduleName = [IO.Path]::GetFileName($Name)
                if ($moduleName -notin @('LabExecution.psm1','LabSafety.psm1','PublicSource.psm1','MinimalTeardownAcceptance.psm1')) { throw 'Unexpected module import' }
                $script:entryImports.Add($moduleName)
            }
            $null = . (Join-Path $PSScriptRoot '../scripts/Remove-LabRun.ps1') -StatePath 'synthetic-state' -Action Dependencies
        }
    } catch { $entryFailure = $_.Exception.Message }
    Confirm-Equal $entryFailure 'Missing acceptance receipt' 'Script entry propagates acceptance rejection'
    Confirm-Equal @($script:entryImports | Where-Object { $_ -ceq 'MinimalTeardownAcceptance.psm1' }).Count 1 'Script entry imports the real acceptance module'
    Confirm-Equal $script:guardCounters.acceptance 1 'Script entry checks minimal acceptance'
    Confirm-Equal $script:guardCounters.context 0 'Script entry rejects before context'
    Confirm-Equal $script:calls.Count 0 'Script entry rejects before transport'
    Confirm-Equal $script:saves 0 'Script entry rejects before saves'
    foreach ($created in @($false,$true)) {
        Reset-StandardFixture -CreatedAccountHost:$created
        $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
        Confirm-Equal $script:roots.items.Count $(if ($created) { 7 } else { 6 }) 'Exact root count with account creation or reuse'
        Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete').Count 1 'Single Standard delete'
        Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete')[0].arguments[4] "https://management.azure.com$($script:projectHostFixture.id)?api-version=2026-05-01" 'Untagged captured host precedes project'
        $script:calls.Clear()
        $script:standardRest[$script:projectHostsUrl].value = @()
        $null = Invoke-LabTeardown 'synthetic-state' 'Dependencies'
        Confirm-Equal @($script:calls | Where-Object { $_.label -eq 'teardown-get' -and $_.arguments[4] -eq $script:projectHostsUrl }).Count 1 'Fresh host absence checked on next action'
        Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete')[0].arguments[4] "https://management.azure.com$($script:standardBindingFixture.projectId)?api-version=2026-05-01" 'Project deleted only after fresh empty host collection'
    }
    foreach ($scenario in @('missing-root','active-root','extra-root','pending','partial','wrong-root','wrong-host-id','wrong-host-type','host-active','host-kind','storage-target','vector-target','thread-target','scalar-connections','new-host','new-project','host-page','account-host-binding')) {
        Reset-StandardFixture
        $blocker = switch ($scenario) {
            'missing-root' { $script:roots.items = @($script:roots.items | Where-Object name -ne 'fgl-sample01-lock'); 'root coverage' }
            'active-root' { $script:roots.items[-1].properties.provisioningState = 'Running'; 'Root deployment is still active' }
            'extra-root' { $script:roots.items += @{name='fgl-sample01-standard-account'; id="/subscriptions/$($script:state.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-sample01-standard-account"; properties=@{provisioningState='Running'}}; 'root coverage' }
            'pending' { $script:state.standard.pendingStage = 'access'; 'Complete Standard stages' }
            'partial' { $script:state.standard.completedStages = @('dependencies','account','project'); 'Complete Standard stages' }
            'wrong-root' { $script:state.standard.deploymentNames.project = 'foreign'; 'Unexpected Standard root name' }
            'wrong-host-id' { $script:projectHostFixture.id += '-foreign'; 'capability host ID' }
            'wrong-host-type' { $script:projectHostFixture.type = 'Example.Service/items'; 'capability host ID' }
            'host-active' { $script:projectHostFixture.properties.provisioningState = 'Deleting'; 'capability host ID' }
            'host-kind' { $script:projectHostFixture.properties.capabilityHostKind = 'Other'; 'host kind' }
            'storage-target' { $script:projectHostFixture.properties.storageConnections = @('foreign'); 'connection target' }
            'vector-target' { $script:projectHostFixture.properties.vectorStoreConnections = @('foreign'); 'connection target' }
            'thread-target' { $script:projectHostFixture.properties.threadStorageConnections = @('foreign'); 'connection target' }
            'scalar-connections' { $script:projectHostFixture.properties.storageConnections = $script:standardBindingFixture.storage.name; 'connection target' }
            'new-host' { $script:snapshot.children = @($script:snapshot.children | Where-Object id -ne $script:projectHostFixture.id); Save-FixtureEvidence; 'host appeared after evidence' }
            'new-project' { $script:snapshot.children = @($script:snapshot.children | Where-Object id -ne $script:standardBindingFixture.projectId); Save-FixtureEvidence; 'Project appeared after evidence' }
            'host-page' { $script:standardRest[$script:projectHostsUrl].nextLink = 'https://example.invalid/next'; 'Incomplete teardown list' }
            'account-host-binding' { $script:state.standard.accountHostId += '-other'; 'host binding mismatch' }
        }
        Confirm-Blocked 'Dependencies' $blocker
        if ($scenario -in @('pending','partial')) {
            $directFailure = ''
            try { $null = Get-TeardownPreparation $script:state $script:groups } catch { $directFailure = $_.Exception.Message }
            Confirm-Equal ($directFailure -like '*Complete Standard stages*') $true 'Pure preparation independently rejects incomplete Standard'
            Confirm-Equal $script:calls.Count 0 'Incomplete Standard rejected before transport'
        }
    }
    Reset-StandardFixture
    $null = Invoke-LabTeardown 'synthetic-state' 'Evidence'
    $savedSnapshot = Get-Content -LiteralPath $script:state.teardownEvidence.path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Confirm-Equal $savedSnapshot.children.Count 3 'Evidence explicitly captures project and both capability hosts'
    Confirm-Equal ($script:standardBindingFixture.projectId -in $savedSnapshot.children.id) $true 'Project child captured even when generic inventory omits it'
    Confirm-Equal ($script:projectHostFixture.id -in $savedSnapshot.children.id) $true 'Untagged project host captured separately'
    Confirm-Equal @($script:calls | Where-Object label -eq 'teardown-delete').Count 0 'Evidence never deletes'
    Reset-StandardFixture
    $null = Invoke-TeardownRest $script:state $script:state.standard.accountHostId '2026-05-01'
    $script:calls.Clear()
    $implicitDeleteRejected = $false
    try { $null = Invoke-TeardownRest $script:state $script:state.standard.accountHostId '2026-05-01' 'delete' } catch { $implicitDeleteRejected = $true }
    Confirm-Equal $implicitDeleteRejected $true 'Implicit account host allows GET but rejects DELETE'
    Confirm-Equal $script:calls.Count 0 'Implicit host delete never reaches transport'
    foreach ($salCase in @('residue','paginated','missing','empty')) {
        Reset-StandardFixture
        $script:groups = @($script:groups | Where-Object name -eq 'rg-fgl-sample01-integration')
        $script:inventory.items = @($script:snapshot.resources | Where-Object { ($_.id -split '/providers/')[0] -eq $script:groups[0].id })
        $script:links.value = @()
        switch ($salCase) {
            'residue' { $script:standardRest[$script:salUrl].value = @(@{id="$($script:standardBindingFixture.vnetId)/subnets/snet-agent-a/serviceAssociationLinks/managed"}) }
            'paginated' { $script:standardRest[$script:salUrl].nextLink = 'https://example.invalid/next' }
            'missing' { $script:standardRest[$script:salUrl].value = $null }
        }
        if ($salCase -eq 'empty') {
            $null = Invoke-LabTeardown 'synthetic-state' 'Next'
            Confirm-Equal @($script:calls | Where-Object label -eq 'delete-rg-fgl-sample01-integration').Count 1 'Empty SAL permits integration group deletion'
        } else { Confirm-Blocked 'Next' $(if ($salCase -eq 'residue') { 'serviceAssociationLinks residue' } else { 'Incomplete teardown list' }) }
        Confirm-Equal @($script:calls | Where-Object { $_.label -eq 'teardown-get' -and $_.arguments[4] -eq $script:salUrl }).Count 1 'Exact agent subnet SAL GET with network API'
    }
    Write-Output "PASS: $script:passed teardown assertions; synthetic evidence only; no Azure requests made"
} finally {
    if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}