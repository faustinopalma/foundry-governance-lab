[CmdletBinding()]
param(
    [string]$StatePath,
    [ValidateSet('Evidence','Dependencies','Next','Status')][string]$Action = 'Status',
    [switch]$DefinitionsOnly
)

function Get-TeardownItems($Response, [string]$Key) {
    if ($Response -isnot [System.Collections.IDictionary] -or $Response[$Key] -isnot [array] -or $Response.nextLink) { throw 'Incomplete teardown list: expected an array without pagination' }
    $items = @($Response[$Key])
    if (@($items | Where-Object { $_ -isnot [System.Collections.IDictionary] -or -not $_.id }).Count -or @($items.id | Sort-Object -Unique).Count -ne $items.Count) { throw 'Invalid or duplicate teardown list IDs' }
    return ,$items
}

function Invoke-TeardownRest([hashtable]$State, [string]$Id, [string]$Version, [string]$Method = 'get') {
    $resourceId = $Id
    if ($Method -eq 'get' -and $Id -match '/(projects|scopedResources|capabilityHosts|serviceAssociationLinks)$') { $resourceId = $Id.Substring(0, $Id.LastIndexOf('/')) }
    Assert-LabResourceId $State $resourceId
    $implicitRead = $Method -eq 'get' -and $Version -eq '2026-05-01' -and $Id -ceq $State.standard.accountHostId -and $Id -cmatch '/accounts/([a-zA-Z0-9-]+)/capabilityHosts/\1@aml_aiagentservice$'
    $salRead = $Method -eq 'get' -and $Version -eq '2024-05-01' -and $Id -ceq "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-$($State.labId)/subnets/snet-agent-a/serviceAssociationLinks"
    if ((-not $implicitRead -and $Id -notmatch '^/subscriptions/[a-zA-Z0-9-]+/resourceGroups/[a-zA-Z0-9-]+/providers/[a-zA-Z0-9./_-]+$') -or $Method -notin @('get','delete') -or ($Version -notin @('2021-07-01-preview','2026-05-01') -and -not $salRead) -or ($Id -match '/serviceAssociationLinks$' -and -not $salRead)) { throw 'Invalid teardown ARM request' }
    Invoke-LabAz $State @('rest','--method',$Method,'--url',"https://management.azure.com${Id}?api-version=$Version") "teardown-$Method"
}

function Get-StandardTeardownBinding([hashtable]$State) {
    if (-not $State.ContainsKey('standard')) { return $null }
    $standard = $State.standard
    if ($State.minimalPrompt -ne $true -or $standard -isnot [hashtable] -or $standard.completedStages -isnot [array] -or ($standard.completedStages -join ',') -cne 'dependencies,account,project,access' -or $standard.pendingStage -or $State.pendingPhase -or $standard.deploymentNames -isnot [hashtable]) { throw 'Complete Standard stages with no pending operation required' }
    foreach ($entry in $standard.deploymentNames.GetEnumerator()) {
        if ($entry.Key -cnotin @('dependencies','account','project','access') -or $entry.Value -isnot [string] -or $entry.Value -cne "fgl-$($State.labId)-standard-$($entry.Key)") { throw 'Unexpected Standard root name' }
    }
    foreach ($stage in @('dependencies','project','access')) { if (-not $standard.deploymentNames.ContainsKey($stage)) { throw 'Missing Standard root name' } }
    $path = Assert-ExternalLabPath (Join-Path $State.runDirectory 'standard-outputs.json')
    $outputs = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -Depth 100
    $binding = $outputs.dependencies
    $casePrefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-case-a"
    $vnetId = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-$($State.labId)"
    if ($binding -isnot [hashtable] -or $binding.accountId -isnot [string]) { throw 'Missing Standard dependency outputs' }
    $accountName = ($binding.accountId -split '/')[-1]
    if ($accountName -cnotmatch '^[a-zA-Z0-9-]+$' -or $binding.accountId -ine "$casePrefix/providers/Microsoft.CognitiveServices/accounts/$accountName" -or $binding.projectId -ine "$($binding.accountId)/projects/case-a-dev" -or $binding.vnetId -ine $vnetId -or $binding.subnetId -ine "$vnetId/subnets/snet-case-a-pe") { throw 'Standard target binding mismatch' }
    $types = @{storage='Microsoft.Storage/storageAccounts'; search='Microsoft.Search/searchServices'; cosmos='Microsoft.DocumentDB/databaseAccounts'}
    foreach ($key in $types.Keys) {
        $name = $binding[$key].name
        $expectedName = if ($key -eq 'storage') { '^stfgl' + [regex]::Escape($State.labId) + '[a-z0-9]{6}$' } else { '^' + [regex]::Escape("$(if ($key -eq 'search') { 'srch' } else { 'cosmos' })-fgl-$($State.labId)-standard") + '$' }
        if ($name -isnot [string] -or $name -cnotmatch $expectedName -or $binding[$key].id -ine "$casePrefix/providers/$($types[$key])/$name" -or $binding.connections[$key].name -cne $name -or $binding.connections[$key].id -ine "$($binding.projectId)/connections/$name") { throw 'Standard dependency connection binding mismatch' }
    }
    $hostId = if ($standard.deploymentNames.ContainsKey('account')) { "$($binding.accountId)/capabilityHosts/agents" } else { "$($binding.accountId)/capabilityHosts/$accountName@aml_aiagentservice" }
    if ($standard.accountHostId -isnot [string] -or $standard.accountHostId -cne $hostId -or $binding.capabilityHosts.project -ine "$($binding.projectId)/capabilityHosts/agents") { throw 'Standard host binding mismatch' }
    return $binding
}

function Assert-StandardTeardownHost([hashtable]$State, $Resource, [hashtable]$Binding, [switch]$Account) {
    $id = if ($Account) { $State.standard.accountHostId } else { "$($Binding.projectId)/capabilityHosts/agents" }
    $type = if ($Account) { 'Microsoft.CognitiveServices/accounts/capabilityHosts' } else { 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts' }
    $leaf = ($id -split '/')[-1]
    $qualifiedName = ($id -split '/accounts/')[1] -replace '/projects/','/' -replace '/capabilityHosts/','/'
    if ($Resource -isnot [hashtable] -or $Resource.id -ine $id -or $Resource.type -ine $type -or $Resource.name -cnotin @($leaf,$qualifiedName) -or $Resource.properties.provisioningState -cne 'Succeeded') { throw 'Standard capability host ID, type, name or state mismatch' }
    if ($Resource.properties.ContainsKey('capabilityHostKind') -and $Resource.properties.capabilityHostKind -cne 'Agents') { throw 'Standard capability host kind mismatch' }
    if ($Resource.tags -and (($Resource.tags.ContainsKey('fgl-owner') -and $Resource.tags['fgl-owner'] -cne $State.ownershipId) -or ($Resource.tags.ContainsKey('fgl-lab') -and $Resource.tags['fgl-lab'] -cne $State.labId))) { throw 'Standard capability host ownership conflict' }
    if (-not $Account) {
        $keys = @{storageConnections='storage'; vectorStoreConnections='search'; threadStorageConnections='cosmos'}
        foreach ($key in $keys.Keys) {
            $actual = $Resource.properties[$key]
            if ($actual -isnot [array] -or $actual.Count -ne 1 -or $actual[0] -isnot [string] -or $actual[0] -cne $Binding.connections[$keys[$key]].name) { throw 'Standard capability host connection target mismatch' }
        }
    }
}

function Assert-TeardownOwned([hashtable]$State, $Resource, [string]$Id, [string]$Type) {
    Assert-LabResourceId $State $Id
    $names = @(($Id -split '/')[-1])
    if ($Type -eq 'Microsoft.CognitiveServices/accounts/projects') { $names += (($Id -split '/')[8] + '/' + $names[0]) }
    if ($Resource -isnot [System.Collections.IDictionary] -or $Resource.id -ine $Id -or $Resource.type -ine $Type -or $Resource.name -cnotin $names -or $Resource.tags['fgl-owner'] -ne $State.ownershipId -or $Resource.tags['fgl-lab'] -ne $State.labId) { throw 'Dependency resource ownership, type, name or ID mismatch' }
}

function Get-TeardownPreparation([hashtable]$State, [array]$Groups) {
    if ($State['minimalPrompt'] -eq $true) { Assert-MinimalTeardownAcceptance $State }
    $standardBinding = Get-StandardTeardownBinding $State
    Assert-LabTransition $State 'destroy'
    $minimalPrompt = $State['minimalPrompt'] -eq $true
    $monitorGroups = if ($minimalPrompt) { @('integration','case-a') } else { @('integration','case-a','case-b') }
    $linkNames = @(0..($monitorGroups.Count * 2 - 1) | ForEach-Object { "linked-$_" })
    if (-not $State.teardownEvidence) { throw 'Intact external evidence is required before deletion' }
    $path = Assert-ExternalLabPath $State.teardownEvidence.path
    $text = [IO.File]::ReadAllText($path)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
    if ($hash -ne $State.teardownEvidence.sha256) { throw 'Intact external evidence is required before deletion' }
    $snapshot = $text | ConvertFrom-Json -AsHashtable -Depth 100
    $resources = Get-TeardownItems @{items=$snapshot.resources} 'items'
    $capturedGroups = Get-TeardownItems @{items=$snapshot.groups} 'items'
    $children = @()
    if ($standardBinding) {
        $children = Get-TeardownItems @{items=$snapshot.children} 'items'
        foreach ($child in $children) {
            if ($child.id -ieq $standardBinding.projectId) { Assert-TeardownOwned $State $child $standardBinding.projectId 'Microsoft.CognitiveServices/accounts/projects' }
            else { Assert-StandardTeardownHost $State $child $standardBinding -Account:($child.id -ieq $State.standard.accountHostId) }
        }
    }
    if (-not $resources.Count -or -not $capturedGroups.Count) { throw 'Empty teardown evidence cannot authorize deletion' }
    foreach ($group in $capturedGroups) {
        Assert-LabGroupOwnership $State $group
        if ($group.id -in $State.preexistingGroupIds) { throw 'Pre-existing group cannot be adopted' }
    }
    foreach ($resource in $resources) {
        Assert-LabResourceId $State $resource.id
        if (($resource.id -split '/providers/')[0] -notin $capturedGroups.id) { throw 'Snapshot resource has no captured parent group' }
        if ($resource.tags -and $resource.tags.ContainsKey('fgl-owner') -and $resource.tags['fgl-owner'] -ne $State.ownershipId) { throw 'Snapshot resource ownership conflict' }
    }
    $rootNames = @('bootstrap','lock','activate') | ForEach-Object { "fgl-$($State.labId)-$_" }
    if ($State.deploymentName -and $State.deploymentName -notin $rootNames) { throw 'Unknown root deployment name' }
    if ($standardBinding) { $rootNames += @($State.standard.deploymentNames.Values) }
    $filter = ($rootNames | ForEach-Object { "name=='$_'" }) -join ' || '
    if ($standardBinding) { $filter = "starts_with(name, 'fgl-$($State.labId)-')" }
    $roots = Get-TeardownItems (Invoke-LabAz $State @('deployment','sub','list','--query',"{items:[?$filter]}") 'teardown-roots') 'items'
    if (-not $roots.Count -or ($State.deploymentName -and $State.deploymentName -notin $roots.name)) { throw 'Root deployment evidence is missing' }
    if ($standardBinding -and ($roots.Count -ne $rootNames.Count -or @($roots.name | Sort-Object -Unique).Count -ne $rootNames.Count)) { throw 'Complete exact Standard root coverage required' }
    foreach ($deployment in $roots) {
        if ($deployment.name -notin $rootNames -or $deployment.id -ine "/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/$($deployment.name)") { throw 'Unexpected root deployment ID' }
        if ($deployment.properties.provisioningState -notin @('Succeeded','Failed','Canceled')) { throw "Root deployment is still active: $($deployment.name) $($deployment.properties.provisioningState)" }
    }
    $freshGroups = @{}
    foreach ($group in $Groups) {
        Assert-LabGroupOwnership $State $group
        if ($group.id -notin $capturedGroups.id) { throw 'Group appeared after evidence capture' }
        $fresh = Invoke-LabAz $State @('group','show','--name',$group.name) 'teardown-group'
        Assert-LabGroupOwnership $State $fresh
        if ($fresh.id -ine $group.id) { throw 'Fresh group ID mismatch' }
        $freshGroups[$group.name] = $fresh
        $nested = Get-TeardownItems (Invoke-LabAz $State @('deployment','group','list','--resource-group',$group.name,'--query','{items:@}') 'teardown-nested') 'items'
        foreach ($deployment in $nested) {
            Assert-LabResourceId $State $deployment.id
            if ($deployment.name -notmatch '^[a-zA-Z0-9_.()-]+$' -or $deployment.id -ine "$($group.id)/providers/Microsoft.Resources/deployments/$($deployment.name)") { throw 'Unexpected nested deployment ID' }
            if ($deployment.properties.provisioningState -notin @('Succeeded','Failed','Canceled')) { throw "Nested deployment is still active: $($deployment.name) $($deployment.properties.provisioningState)" }
        }
    }
    $next = $null
    foreach ($suffix in @('case-a','case-b','models','integration')) {
        if ($freshGroups.ContainsKey("rg-fgl-$($State.labId)-$suffix")) { $next = $freshGroups["rg-fgl-$($State.labId)-$suffix"]; break }
    }
    if (-not $next) { throw 'No groups remain; run Status to verify final absence' }
    if ($next.properties.provisioningState -notin @('Succeeded','Failed','Canceled')) { throw "Group state blocks teardown: $($next.name) $($next.properties.provisioningState). Run Status and retry later." }
    $inventory = Get-TeardownItems (Invoke-LabAz $State @('resource','list','--resource-group',$next.name,'--query','{items:@}') 'teardown-inventory') 'items'
    foreach ($resource in $inventory) {
        Assert-LabResourceId $State $resource.id
        $captured = @($resources | Where-Object id -eq $resource.id)
        if (($resource.id -split '/providers/')[0] -ine $next.id -or $captured.Count -ne 1 -or $resource.type -ine $captured[0].type) { throw 'Resource appeared after evidence capture or inventory scope/type changed' }
        if ($resource.tags -and $resource.tags.ContainsKey('fgl-owner') -and $resource.tags['fgl-owner'] -ne $State.ownershipId) { throw 'Resource ownership conflict inside lab group' }
    }
    $dependencies = @()
    $scopeType = 'Microsoft.Insights/privateLinkScopes'
    $scopeId = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-integration/providers/$scopeType/ampls-fgl-$($State.labId)"
    $scopes = @($resources | Where-Object type -eq $scopeType)
    if ($scopes.Count -ne 1) { throw 'Exactly one captured AMPLS parent is required' }
    Assert-TeardownOwned $State $scopes[0] $scopeId $scopeType
    $integrationIsNext = $next.name -eq "rg-fgl-$($State.labId)-integration"
    if ($freshGroups.ContainsKey("rg-fgl-$($State.labId)-integration") -and (-not $integrationIsNext -or $scopeId -in $inventory.id)) {
        $scope = Invoke-TeardownRest $State $scopeId '2021-07-01-preview'
        Assert-TeardownOwned $State $scope $scopeId $scopeType
        $links = Get-TeardownItems (Invoke-TeardownRest $State "$scopeId/scopedResources" '2021-07-01-preview') 'value'
        foreach ($link in $links) {
            $target = @($resources | Where-Object id -eq $link.properties.linkedResourceId)
            if ($link.name -cnotin $linkNames -or $link.type -ine "$scopeType/scopedResources" -or $link.id -ine "$scopeId/scopedResources/$($link.name)" -or $target.Count -ne 1 -or $target[0].type -notin @('Microsoft.OperationalInsights/workspaces','Microsoft.Insights/components')) { throw 'Unknown AMPLS link ID, name, type or target' }
            Assert-TeardownOwned $State $target[0] $link.properties.linkedResourceId $target[0].type
            $index = [int]$link.name.Substring(7)
            $targetGroup = $monitorGroups[[int][math]::Floor($index / 2)]
            $targetType = @('Microsoft.OperationalInsights/workspaces','Microsoft.Insights/components')[$index % 2]
            $targetPrefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-$targetGroup/providers/$targetType/"
            if ($target[0].id -ine "$targetPrefix$($target[0].name)") { throw 'AMPLS link target does not match its declared lab mapping' }
            if ($next.name -eq "rg-fgl-$($State.labId)-$targetGroup") {
                foreach ($liveTarget in @($inventory | Where-Object id -eq $target[0].id)) { Assert-TeardownOwned $State $liveTarget $target[0].id $targetType }
                if ($link.properties.provisioningState -notin @('Succeeded','Failed','Canceled')) { throw "AMPLS link state blocks teardown: $($link.name) $($link.properties.provisioningState)" }
                $dependencies += @{id=$link.id; version='2021-07-01-preview'; kind='AMPLS link'}
            }
        }
    } elseif (-not $integrationIsNext) { throw 'AMPLS parent group is absent before its dependent groups' }
    foreach ($account in @($inventory | Where-Object type -eq 'Microsoft.CognitiveServices/accounts')) {
        $captured = @($resources | Where-Object id -eq $account.id)[0]
        Assert-TeardownOwned $State $captured $account.id 'Microsoft.CognitiveServices/accounts'
        if ($account.id -ine "$($next.id)/providers/Microsoft.CognitiveServices/accounts/$($account.name)") { throw 'Invalid account parent ID' }
        $fresh = Invoke-TeardownRest $State $account.id '2026-05-01'
        Assert-TeardownOwned $State $fresh $account.id 'Microsoft.CognitiveServices/accounts'
        if ($fresh.properties.provisioningState -notin @('Succeeded','Failed','Canceled')) { throw "Account state blocks teardown: $($account.name) $($fresh.properties.provisioningState). Query again later; no forced deletion." }
        $projects = Get-TeardownItems (Invoke-TeardownRest $State "$($account.id)/projects" '2026-05-01') 'value'
        if ($standardBinding -and $account.id -ieq $standardBinding.accountId) {
            Assert-TeardownOwned $State $account $standardBinding.accountId 'Microsoft.CognitiveServices/accounts'
            $accountHosts = Get-TeardownItems (Invoke-TeardownRest $State "$($account.id)/capabilityHosts" '2026-05-01') 'value'
            foreach ($accountHost in $accountHosts) {
                Assert-StandardTeardownHost $State $accountHost $standardBinding -Account
                if ($accountHost.id -notin $children.id) { throw 'Capability host appeared after evidence capture' }
            }
        } elseif ($standardBinding -and $next.name -eq "rg-fgl-$($State.labId)-case-a") { throw 'Standard account target mismatch' }
        $caseId = $next.name -replace "^rg-fgl-$($State.labId)-", ''
        $projectNames = if ($minimalPrompt) { @('case-a-dev') } else { @("$caseId-dev","$caseId-test") }
        foreach ($project in $projects) {
            $projectName = ($project.id -split '/')[-1]
            if ($caseId -notin @('case-a','case-b') -or $projectName -cnotin $projectNames -or $project.name -cnotin @($projectName,"$($account.name)/$projectName")) { throw 'Unknown Foundry project name or parent group' }
            Assert-TeardownOwned $State $project "$($account.id)/projects/$projectName" 'Microsoft.CognitiveServices/accounts/projects'
            if ($project.properties.provisioningState -notin @('Succeeded','Failed','Canceled')) { throw "Project state blocks teardown: $($project.name) $($project.properties.provisioningState). Query again later." }
            if ($standardBinding) {
                if ($project.id -ine $standardBinding.projectId -or $project.id -notin $children.id) { throw 'Project appeared after evidence capture or Standard target changed' }
                $hosts = Get-TeardownItems (Invoke-TeardownRest $State "$($project.id)/capabilityHosts" '2026-05-01') 'value'
                foreach ($hostResource in $hosts) {
                    Assert-StandardTeardownHost $State $hostResource $standardBinding
                    if ($hostResource.id -notin $children.id) { throw 'Capability host appeared after evidence capture' }
                    $dependencies += @{id=$hostResource.id; version='2026-05-01'; kind='project capability host'}
                }
                if ($hosts.Count) { continue }
            }
            $dependencies += @{id=$project.id; version='2026-05-01'; kind='Foundry project'}
        }
        if (-not $projects.Count) { $dependencies += @{id=$account.id; version='2026-05-01'; kind='Foundry account'} }
    }
    if ($standardBinding -and $integrationIsNext -and $standardBinding.vnetId -in $inventory.id) {
        foreach ($vnet in @($resources + $inventory | Where-Object id -eq $standardBinding.vnetId)) { Assert-TeardownOwned $State $vnet $standardBinding.vnetId 'Microsoft.Network/virtualNetworks' }
        $sal = Get-TeardownItems (Invoke-TeardownRest $State "$($standardBinding.vnetId)/subnets/snet-agent-a/serviceAssociationLinks" '2024-05-01') 'value'
        if ($sal.Count) { throw 'Agent subnet serviceAssociationLinks residue blocks VNet deletion; no forced deletion' }
    }
    return @{group=$next; dependencies=$dependencies}
}

function Invoke-LabTeardown([string]$StatePath, [string]$Action) {
    $state = Read-LabRun $StatePath
    if ($state['minimalPrompt'] -eq $true) { Assert-MinimalTeardownAcceptance $state }
    $standardBinding = Get-StandardTeardownBinding $state
    $groups = @(Confirm-LabRunContext $state)
    if ($Action -eq 'Evidence') {
        $snapshot = @{capturedAt=[DateTimeOffset]::UtcNow.ToString('o'); groups=$groups; resources=@(); deployments=@(); children=@()}
        foreach ($group in $groups) {
            $resources = @(Invoke-LabAz $state @('resource','list','--resource-group',$group.name) "evidence-$($group.name)")
            foreach ($resource in $resources) { Assert-LabResourceId $state $resource.id }
            $snapshot.resources += $resources
            $snapshot.deployments += @(Invoke-LabAz $state @('deployment','group','list','--resource-group',$group.name) "deployments-$($group.name)")
        }
        if ($standardBinding) {
            foreach ($parent in @($snapshot.resources | Where-Object id -eq $standardBinding.accountId)) {
                Assert-TeardownOwned $state $parent $standardBinding.accountId 'Microsoft.CognitiveServices/accounts'
                $projectChildren = Get-TeardownItems (Invoke-TeardownRest $state "$($parent.id)/projects" '2026-05-01') 'value'
                $accountHosts = Get-TeardownItems (Invoke-TeardownRest $state "$($parent.id)/capabilityHosts" '2026-05-01') 'value'
                foreach ($accountHost in $accountHosts) { Assert-StandardTeardownHost $state $accountHost $standardBinding -Account; $snapshot.children += $accountHost }
                foreach ($projectChild in $projectChildren) {
                    Assert-TeardownOwned $state $projectChild $standardBinding.projectId 'Microsoft.CognitiveServices/accounts/projects'
                    $snapshot.children += $projectChild
                    $hostChildren = Get-TeardownItems (Invoke-TeardownRest $state "$($projectChild.id)/capabilityHosts" '2026-05-01') 'value'
                    foreach ($hostChild in $hostChildren) { Assert-StandardTeardownHost $state $hostChild $standardBinding; $snapshot.children += $hostChild }
                }
            }
        }
        $snapshotPath = Join-Path $state.runDirectory "evidence-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfff')).json"
        [IO.File]::WriteAllText($snapshotPath, ($snapshot | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        $state.teardownEvidence = @{path=$snapshotPath; sha256=(Get-FileHash $snapshotPath).Hash}
        Save-LabRun $state $StatePath
        Write-Output "Evidence captured outside Azure: $($groups.Count) owned groups; $($snapshot.resources.Count) resources."
    } elseif ($Action -in @('Dependencies','Next')) {
        $plan = Get-TeardownPreparation $state $groups
        $next = $plan.group
        if ($plan.dependencies.Count) {
            if ($Action -eq 'Next') { throw "Dependencies remain for $($next.name). Run -Action Dependencies before -Action Next." }
            $dependency = $plan.dependencies[0]
            $null = Invoke-TeardownRest $state $dependency.id $dependency.version 'delete'
            Write-Output "Deletion submitted for one exact owned $($dependency.kind). Run Dependencies again to recheck completion before Next."
            return
        }
        if ($Action -eq 'Dependencies') { Write-Output "Dependencies clear for $($next.name). Run -Action Next; all guards will be checked again."; return }
        $state.phase = 'destroy'
        $state.pendingPhase = $null
        Save-LabRun $state $StatePath
        $null = Invoke-LabAz $state @('group','delete','--name',$next.name,'--yes','--no-wait') "delete-$($next.name)"
        Write-Output "Deletion submitted for one exact owned group: $($next.name)."
    } else {
        Write-Output "Remaining owned groups: $($groups.Count)"
        foreach ($group in $groups) { Write-Output "$($group.name): $($group.properties.provisioningState)" }
        if ($groups.Count -eq 0) {
            $remaining = @(Invoke-LabAz $state @('resource','list') 'final-inventory')
            $residuals = @($remaining | Where-Object { $_.resourceGroup -in $state.resourceGroups })
            if ($residuals.Count) { throw 'Owned resource residuals remain' }
            $state.phase = 'destroyed'
            $state.pendingPhase = $null
            $state.destroyedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Save-LabRun $state $StatePath
            Write-LabEvent $state 'teardown-resource-absence' @{groups=0; resources=0}
            Write-Output "PASS: $($state.resourceGroups.Count) exact groups and their ARM resources are absent. Soft-deleted service records and activity attribution require separate review."
        }
    }
}

if ($DefinitionsOnly) { return }
$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    if (-not $StatePath) { throw 'StatePath is required' }
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
    Import-Module (Join-Path $PSScriptRoot 'MinimalTeardownAcceptance.psm1')
    Invoke-LabTeardown $StatePath $Action
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}