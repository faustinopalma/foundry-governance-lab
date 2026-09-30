[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$CleanupPath,
    [ValidateSet('Plan','Step','Status')][string]$Action = 'Status',
    [string]$ConfirmLabId,
    [switch]$ApproveDestroy,
    [ValidateRange(1,120)][int]$CallTimeoutSeconds = 60,
    [switch]$DefinitionsOnly
)

$customerArguments = $PSBoundParameters
. (Join-Path $PSScriptRoot 'Invoke-ExpansionWatchdog.ps1') -DefinitionsOnly
Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')

function Read-CustomerJson([string]$Path) {
    $options = @{AsHashtable=$true; Depth=100; NoEnumerate=$true}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind='String' }
    return ,([IO.File]::ReadAllText($Path) | ConvertFrom-Json @options)
}

function Write-CustomerJson([string]$Path, $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 100), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Get-CustomerBinding([string]$Original, [string]$Cleanup) {
    $originalPath = Assert-ExternalLabPath $Original
    $cleanupFile = Assert-ExternalLabPath $Cleanup
    $state = Read-CustomerJson $originalPath
    foreach ($field in @('labId','ownershipId','subscriptionId','tenantId')) { if ($state[$field] -isnot [string]) { throw 'Typed original ownership binding required' } }
    Assert-LabState $state
    if ($state.minimalPrompt -isnot [bool] -or -not $state.minimalPrompt -or $state.preexistingGroupIds -isnot [array] -or $state.runDirectory -ine [IO.Path]::GetDirectoryName($originalPath)) { throw 'Original minimalPrompt state and baseline required' }
    foreach ($id in $state.preexistingGroupIds) { if ($id -isnot [string] -or $id -inotmatch ('^/subscriptions/' + [regex]::Escape($state.subscriptionId) + '/resourceGroups/[a-zA-Z0-9_.()-]+$')) { throw 'Malformed preexisting group baseline' } }
    $run = [IO.Path]::GetFullPath($state.runDirectory).TrimEnd('\','/')
    if ($cleanupFile -ieq $run -or $cleanupFile.StartsWith("$run$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup must be outside the original run directory' }
    $null = Assert-ExternalLabPath $state.azureConfigDirectory
    $hashes = @{}; $hashes[$originalPath] = (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
    $scope = $state.Clone(); $roots = @()
    if ($state.deploymentName) { $roots += $state.deploymentName }
    if ($state.standard -and $state.standard.deploymentNames) { $roots += @($state.standard.deploymentNames.Values) }
    $foundationPath = Assert-ExternalLabPath (Join-Path $run 'expansion-foundation.state.json')
    $expanded = Test-Path -LiteralPath $foundationPath
    if ($expanded) {
        $foundation = Read-CustomerJson $foundationPath
        $groupB = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-$($state.labId)-case-b"
        $rootName = "fgl-$($state.labId)-expansion-foundation"
        if ($foundation.stage -isnot [string] -or $foundation.stage -cne 'foundation-only' -or $foundation.originalSha -isnot [string] -or $foundation.originalSha -cne $hashes[$originalPath] -or $foundation.baseline -isnot [hashtable] -or -not $foundation.baseline.Count -or $foundation.deploymentId -isnot [string] -or $foundation.deploymentId -ine "/subscriptions/$($state.subscriptionId)/providers/Microsoft.Resources/deployments/$rootName") { throw 'Submitted foundation manifest must bind the original state and root' }
        if ($foundation.baseline.ContainsKey($groupB) -or @($foundation.baseline.Values | Where-Object { $_.id -ieq $groupB }).Count) { throw 'Preexisting expansion group cannot be adopted' }
        $hashes[$foundationPath] = (Get-FileHash -LiteralPath $foundationPath -Algorithm SHA256).Hash
        $scope.minimalPrompt = $false; $scope.resourceGroups = @($state.resourceGroups) + "rg-fgl-$($state.labId)-case-b"
        $roots += $rootName
    }
    Assert-LabState $scope
    foreach ($name in $scope.resourceGroups) {
        if ("/subscriptions/$($scope.subscriptionId)/resourceGroups/$name" -iin $state.preexistingGroupIds) { throw 'Preexisting lab group cannot be adopted' }
    }
    foreach ($name in $roots) { if ($name -cnotmatch ('^fgl-' + [regex]::Escape($state.labId) + '-[a-z0-9-]+$')) { throw 'Unbound root deployment name' } }
    return @{state=$state; scope=$scope; statePath=$originalPath; cleanupPath=$cleanupFile; hashes=$hashes; expanded=[bool]$expanded; requiredRoots=@($roots | Sort-Object -Unique)}
}

function Invoke-CustomerAz([hashtable]$Binding, [string[]]$Arguments, [switch]$Empty, [switch]$AllowMissingModelWorkspace) {
    $application = @(Get-Command az -CommandType Application -ErrorAction Stop)[0].Source
    $prefix = @()
    if ([IO.Path]::GetExtension($application) -ieq '.cmd') {
        $application = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($application)) '../python.exe'))
        if (-not (Test-Path -LiteralPath $application -PathType Leaf)) { throw 'CLI executable missing; no shell fallback' }
        $prefix = @('-IBm','azure.cli')
    }
    $capture = Invoke-BoundedLabProcess -Executable $application -Arguments ($prefix + $Arguments + @('--subscription',$Binding.state.subscriptionId,'--output','json','--only-show-errors')) -LogPrefix (Join-Path $Binding.logDirectory ([guid]::NewGuid().ToString('N'))) -MaxSeconds $Binding.timeout -IdleSeconds $Binding.timeout -Environment @{AZURE_CONFIG_DIR=$Binding.state.azureConfigDirectory; AZURE_CORE_COLLECT_TELEMETRY='false'; AZURE_CORE_NO_COLOR='true'}
    if ($AllowMissingModelWorkspace -and -not $Empty -and $capture.reason -ceq 'Exited' -and $capture.exitCode -eq 1) {
        $modelPrefix = 'https://management.azure.com/subscriptions/' + $Binding.state.subscriptionId + '/resourceGroups/rg-fgl-' + $Binding.state.labId + '-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-' + $Binding.state.labId + '-models-'
        $modelUrl = '^' + [regex]::Escape($modelPrefix) + '[a-z0-9]{13}/capabilityHosts\?api-version=2026-05-01$'
        if ($Arguments.Count -eq 7 -and ($Arguments[0..3] -join ' ') -ceq 'rest --method get --url' -and $Arguments[4] -cmatch $modelUrl -and $Arguments[5] -ceq '--query' -and [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($capture.stdout)) -and [IO.File]::ReadAllText($capture.stderr).Trim() -ceq 'ERROR: Workspace not found.') {
            return @{value=@(); nextLink=$null}
        }
    }
    if ($capture.reason -cne 'Exited' -or $capture.exitCode -ne 0) { throw 'CLI failed or timed out; inspect private cleanup logs. No automatic retry.' }
    if ($Empty) { return }
    return Read-CustomerJson $capture.stdout
}

function Read-CustomerArm([hashtable]$Binding, [string]$Id, [string]$Api, [switch]$List, [switch]$AllowMissingModelWorkspace) {
    if (-not $Id.StartsWith("/subscriptions/$($Binding.state.subscriptionId)/", [StringComparison]::OrdinalIgnoreCase) -or $Id -match '[?#%\\\s]|/\.{1,2}(/|$)|//') { throw 'Foreign or malformed ARM read' }
    $selection = '{id:id,name:name,type:type,tags:tags,properties:{provisioningState:properties.provisioningState,linkedResourceId:properties.linkedResourceId,capabilityHostKind:properties.capabilityHostKind,storageConnections:properties.storageConnections,vectorStoreConnections:properties.vectorStoreConnections,threadStorageConnections:properties.threadStorageConnections}}'
    $query = if ($List) { "{value:value[].$selection,nextLink:nextLink}" } else { $selection }
    $result = Invoke-CustomerAz $Binding @('rest','--method','get','--url',"https://management.azure.com${Id}?api-version=$Api",'--query',$query) -AllowMissingModelWorkspace:$AllowMissingModelWorkspace
    if ($result -isnot [hashtable]) { throw 'ARM object required' }
    if (-not $List) { if ($result.id -isnot [string] -or $result.id -ine $Id) { throw 'ARM response ID mismatch' }; return $result }
    if ($result.value -isnot [array] -or $result.nextLink) { throw 'Complete unpaginated list required' }
    $seen = @{}
    foreach ($item in $result.value) {
        if ($item -isnot [hashtable] -or $item.id -isnot [string] -or -not $item.id -or $seen.ContainsKey($item.id)) { throw 'Malformed or duplicate inventory ID' }
        $seen[$item.id] = $true
    }
    return ,$result.value
}

function Assert-CustomerResource([hashtable]$Binding, $Resource, [string]$Id, [string]$Type, [switch]$Owned, [switch]$Terminal) {
    Assert-LabResourceId $Binding.scope $Id
    if ($Resource -isnot [hashtable] -or $Resource.id -isnot [string] -or $Resource.id -ine $Id -or $Resource.type -isnot [string] -or $Resource.type -ine $Type) { throw 'Resource ID or type mismatch' }
    $parts = ($Id -split '/providers/')[-1] -split '/'
    $names = @(($Id -split '/')[-1], (@(for ($index=2; $index -lt $parts.Count; $index+=2) { $parts[$index] }) -join '/'))
    if ($Resource.name -isnot [string] -or $Resource.name -cnotin $names) { throw 'Resource name mismatch' }
    foreach ($key in @('fgl-owner','fgl-lab')) {
        $expected = if ($key -eq 'fgl-owner') { $Binding.state.ownershipId } else { $Binding.state.labId }
        if ($Owned -or ($Resource.tags -and $Resource.tags.ContainsKey($key))) {
            if ($Resource.tags -isnot [hashtable] -or $Resource.tags[$key] -isnot [string] -or $Resource.tags[$key] -cne $expected) { throw 'Resource ownership mismatch' }
        }
    }
    if ($Terminal -and $Resource.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Active or unknown provisioning state blocks cleanup' }
}

function Get-CustomerSnapshot([hashtable]$Binding) {
    $state = $Binding.state; $scope = $Binding.scope; $subscription = "/subscriptions/$($state.subscriptionId)"
    Assert-LabContext $state (Invoke-CustomerAz $Binding @('account','show','--query','{id:id,tenantId:tenantId,state:state}'))
    $snapshot = @{}; $roots = @(Read-CustomerArm $Binding "$subscription/providers/Microsoft.Resources/deployments" '2022-09-01' -List | ForEach-Object { $_ } | Where-Object { $_.name -like "fgl-$($state.labId)-*" })
    foreach ($name in $Binding.requiredRoots) { if ($name -notin $roots.name) { throw 'Recorded root deployment missing' } }
    foreach ($root in $roots) {
        if ($root.name -notmatch '^[a-zA-Z0-9_.()-]+$' -or $root.id -ine "$subscription/providers/Microsoft.Resources/deployments/$($root.name)" -or $root.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Active or invalid root deployment' }
    }
    $groups = Read-CustomerArm $Binding "$subscription/resourceGroups" '2021-04-01' -List
    $unboundB = "rg-fgl-$($state.labId)-case-b"
    if (-not $Binding.expanded -and @($groups | Where-Object name -EQ $unboundB).Count) { throw 'Case B exists without a foundation binding' }
    foreach ($group in @($groups | Where-Object { $_.name -in $scope.resourceGroups })) {
        Assert-LabGroupOwnership $scope $group
        Assert-CustomerResource $Binding $group $group.id 'Microsoft.Resources/resourceGroups' -Owned
        $snapshot[$group.id] = @{kind='group'; resource=$group; parent=''}
        foreach ($deployment in (Read-CustomerArm $Binding "$($group.id)/providers/Microsoft.Resources/deployments" '2022-09-01' -List)) {
            if ($deployment.name -notmatch '^[a-zA-Z0-9_.()-]+$' -or $deployment.id -ine "$($group.id)/providers/Microsoft.Resources/deployments/$($deployment.name)" -or $deployment.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Active or invalid nested deployment' }
        }
        foreach ($resource in (Read-CustomerArm $Binding "$($group.id)/resources" '2021-04-01' -List)) {
            if (($resource.id -split '/providers/')[0] -ine $group.id) { throw 'Inventory escaped its group' }
            Assert-CustomerResource $Binding $resource $resource.id $resource.type
            $snapshot[$resource.id] = @{kind='resource'; resource=$resource; parent=$group.id}
        }
    }
    $stem = "fgl-$($state.labId)"; $integration = "$subscription/resourceGroups/rg-$stem-integration"
    $scopeId = "$integration/providers/Microsoft.Insights/privateLinkScopes/ampls-$stem"
    foreach ($entry in @($snapshot.Values | Where-Object { $_.resource.type -ieq 'Microsoft.Insights/privateLinkScopes' })) {
        Assert-CustomerResource $Binding $entry.resource $scopeId 'Microsoft.Insights/privateLinkScopes' -Owned
        foreach ($link in (Read-CustomerArm $Binding "$scopeId/scopedResources" '2021-07-01-preview' -List)) {
            if ($link.name -cnotmatch '^linked-([0-5])$') { throw 'Unknown AMPLS child' }
            $number = [int]$Matches[1]; $monitorGroup = @('integration','case-a','case-b')[[int][math]::Floor($number / 2)]
            $monitorType = @('Microsoft.OperationalInsights/workspaces','Microsoft.Insights/components')[$number % 2]
            $monitorName = @('log','appi')[$number % 2] + "-$stem-$monitorGroup"
            $target = "$subscription/resourceGroups/rg-$stem-$monitorGroup/providers/$monitorType/$monitorName"
            if ($link.properties.linkedResourceId -ine $target -or -not $snapshot.ContainsKey($target)) { throw 'Foreign or missing AMPLS target' }
            Assert-CustomerResource $Binding $snapshot[$target].resource $target $monitorType -Owned
            Assert-CustomerResource $Binding $link "$scopeId/scopedResources/linked-$number" 'Microsoft.Insights/privateLinkScopes/scopedResources'
            $snapshot[$link.id] = @{kind='link'; resource=$link; parent=$scopeId}
        }
    }
    $accounts = @($snapshot.Values | Where-Object { $_.resource.type -ieq 'Microsoft.CognitiveServices/accounts' })
    $accountGroups = @{}
    foreach ($entry in $accounts) {
        $account = $entry.resource; $case = ($entry.parent -split "rg-$stem-")[-1]; $code = @{models='models'; 'case-a'='a'; 'case-b'='b'}[$case]
        if (-not $code -or $account.name -cnotmatch ('^aif-' + [regex]::Escape($stem + '-' + $code) + '-[a-z0-9]{13}$') -or $accountGroups.ContainsKey($case)) { throw 'Unknown Foundry account' }
        $accountGroups[$case] = $true
        $account = Read-CustomerArm $Binding $account.id '2026-05-01'
        Assert-CustomerResource $Binding $account "$($entry.parent)/providers/Microsoft.CognitiveServices/accounts/$($account.name)" 'Microsoft.CognitiveServices/accounts' -Owned
        $snapshot[$account.id].resource = $account
        $projects = Read-CustomerArm $Binding "$($account.id)/projects" '2026-05-01' -List
        $parents = @(@{id=$account.id; type='Microsoft.CognitiveServices/accounts'; kind='accountHost'})
        foreach ($project in $projects) {
            $leaf = ($project.id -split '/')[-1]
            $allowed = @(); if ($case -eq 'case-a') { $allowed = @('case-a-dev'); if ($Binding.expanded) { $allowed += 'case-a-test' } }; if ($case -eq 'case-b') { $allowed = @('case-b-dev','case-b-test') }
            if ($leaf -cnotin $allowed) { throw 'Unknown Foundry project' }
            Assert-CustomerResource $Binding $project "$($account.id)/projects/$leaf" 'Microsoft.CognitiveServices/accounts/projects' -Owned
            $snapshot[$project.id] = @{kind='project'; resource=$project; parent=$account.id}
            $parents += @{id=$project.id; type='Microsoft.CognitiveServices/accounts/projects'; kind='projectHost'}
        }
        foreach ($parent in $parents) {
            $hosts = Read-CustomerArm $Binding "$($parent.id)/capabilityHosts" '2026-05-01' -List -AllowMissingModelWorkspace:($case -ceq 'models' -and $projects.Count -eq 0)
            if ($hosts.Count -gt 1 -or ($case -eq 'models' -and $hosts.Count)) { throw 'Unknown capability hosts' }
            foreach ($hostResource in $hosts) {
                $allowed = @("$($parent.id)/capabilityHosts/agents")
                if ($parent.kind -eq 'accountHost') { $allowed += "$($parent.id)/capabilityHosts/$($account.name)@aml_aiagentservice" }
                if ($hostResource.id -inotin $allowed -or $hostResource.properties.capabilityHostKind -cne 'Agents') { throw 'Unknown capability host' }
                Assert-CustomerResource $Binding $hostResource $hostResource.id "$($parent.type)/capabilityHosts"
                $snapshot[$hostResource.id] = @{kind=$parent.kind; resource=$hostResource; parent=$parent.id}
            }
        }
    }
    foreach ($entry in $snapshot.Values) {
        if ($entry.kind -eq 'resource' -and $entry.resource.type -imatch '/(projects|capabilityHosts|scopedResources)$') { throw 'Unresolved child resource in inventory' }
    }
    return $snapshot
}

function Get-CustomerNext([hashtable]$Binding, [hashtable]$Snapshot) {
    foreach ($entry in $Snapshot.Values) {
        if ($entry.kind -ne 'resource' -or $entry.resource.type -ieq 'Microsoft.CognitiveServices/accounts') {
            Assert-CustomerResource $Binding $entry.resource $entry.resource.id $entry.resource.type -Terminal
        }
    }
    $links = @($Snapshot.Values | Where-Object kind -EQ 'link' | Sort-Object { $_.resource.id })
    if ($links.Count) { return @{id=$links[0].resource.id; kind='link'; api='2021-07-01-preview'} }
    foreach ($suffix in @('case-a','case-b','models','integration')) {
        $groupId = "/subscriptions/$($Binding.state.subscriptionId)/resourceGroups/rg-fgl-$($Binding.state.labId)-$suffix"
        if (-not $Snapshot.ContainsKey($groupId)) { continue }
        foreach ($kind in @('projectHost','project','account')) {
            $candidates = @($Snapshot.Values | Where-Object { $_.resource.id.StartsWith("$groupId/", [StringComparison]::OrdinalIgnoreCase) -and ($_.kind -eq $kind -or ($kind -eq 'account' -and $_.resource.type -ieq 'Microsoft.CognitiveServices/accounts')) } | Sort-Object { $_.resource.id })
            if ($candidates.Count) { return @{id=$candidates[0].resource.id; kind=$kind; api='2026-05-01'} }
        }
        if ($suffix -eq 'integration') {
            $vnet = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-fgl-$($Binding.state.labId)"
            if ($Snapshot.ContainsKey($vnet)) {
                Assert-CustomerResource $Binding $Snapshot[$vnet].resource $vnet 'Microsoft.Network/virtualNetworks' -Owned
                foreach ($subnet in @('a','b')) {
                    $sal = Read-CustomerArm $Binding "$vnet/subnets/snet-agent-$subnet/serviceAssociationLinks" '2024-05-01' -List
                    if ($sal.Count) { throw 'Agent subnet serviceAssociationLinks block integration deletion; no force or manual host deletion' }
                }
            }
        }
        return @{id=$groupId; kind='group'; name="rg-fgl-$($Binding.state.labId)-$suffix"; api='2021-04-01'}
    }
    return $null
}

function Invoke-CustomerTeardown([string]$StatePath, [string]$CleanupPath, [ValidateSet('Plan','Step','Status')][string]$Action='Status', [string]$ConfirmLabId, [switch]$ApproveDestroy, [ValidateRange(1,120)][int]$CallTimeoutSeconds=60) {
    $ErrorActionPreference = 'Stop'
    $binding = Get-CustomerBinding $StatePath $CleanupPath
    if ($Action -eq 'Step' -and (-not $ApproveDestroy -or $ConfirmLabId -cne $binding.state.labId)) { throw 'Step requires fresh ApproveDestroy and exact ConfirmLabId' }
    $binding.timeout = $CallTimeoutSeconds
    $binding.logDirectory = Assert-ExternalLabPath "$($binding.cleanupPath).logs"
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($binding.cleanupPath))
    $lock = [IO.File]::Open((Assert-ExternalLabPath "$($binding.cleanupPath).lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $plan = $null
        if ($Action -eq 'Plan') { if (Test-Path -LiteralPath $binding.cleanupPath) { throw 'Cleanup manifest exists; use Status or Step' } }
        else {
            $plan = Read-CustomerJson $binding.cleanupPath
            foreach ($field in @('statePath','labId','ownershipId','subscriptionId','tenantId')) { if ($plan[$field] -isnot [string]) { throw 'Cleanup binding mismatch' } }
            if (($plan.version -isnot [int] -and $plan.version -isnot [long]) -or $plan.version -ne 1 -or $plan.statePath -cne $binding.statePath -or $plan.labId -cne $binding.state.labId -or $plan.ownershipId -cne $binding.state.ownershipId -or $plan.subscriptionId -cne $binding.state.subscriptionId -or $plan.tenantId -cne $binding.state.tenantId -or $plan.hashes -isnot [hashtable] -or $plan.hashes.Count -ne $binding.hashes.Count -or $plan.inventory -isnot [hashtable] -or -not $plan.inventory.Count -or $plan.completed -isnot [array] -or $plan.resourceGroups -isnot [array] -or ($plan.resourceGroups -join ',') -cne ($binding.scope.resourceGroups -join ',')) { throw 'Cleanup binding mismatch' }
            foreach ($path in $binding.hashes.Keys) { if ($plan.hashes[$path] -isnot [string] -or $plan.hashes[$path] -cne $binding.hashes[$path]) { throw 'Original state or foundation changed; cleanup blocked' } }
        }
        $live = Get-CustomerSnapshot $binding
        if ($plan) {
            foreach ($id in $live.Keys) {
                if (-not $plan.inventory.ContainsKey($id) -or $id -iin $plan.completed -or $live[$id].kind -cne $plan.inventory[$id].kind -or $live[$id].parent -ine $plan.inventory[$id].parent -or $live[$id].resource.type -ine $plan.inventory[$id].resource.type) { throw 'Unknown or reappeared resource after inventory' }
                foreach ($tag in @('fgl-owner','fgl-lab')) {
                    $current = if ($live[$id].resource.tags) { $live[$id].resource.tags[$tag] } else { $null }
                    $captured = if ($plan.inventory[$id].resource.tags) { $plan.inventory[$id].resource.tags[$tag] } else { $null }
                    if ($current -cne $captured) { throw 'Captured ownership tags changed' }
                }
                foreach ($field in @('linkedResourceId','capabilityHostKind','storageConnections','vectorStoreConnections','threadStorageConnections')) {
                    if ((ConvertTo-Json -InputObject $live[$id].resource.properties[$field] -Compress) -cne (ConvertTo-Json -InputObject $plan.inventory[$id].resource.properties[$field] -Compress)) { throw 'Captured dependency changed' }
                }
            }
            if ($plan.pending -and $live.ContainsKey($plan.pending.id)) { return @{status='Pending'; target=$plan.pending.id; message='Observe again; no deletion is retried while its target remains.'} }
            if ($plan.pending) { $plan.completed += $plan.pending.id; $plan.pending = $null }
        }
        $next = Get-CustomerNext $binding $live
        foreach ($path in $binding.hashes.Keys) { if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $binding.hashes[$path]) { throw 'Source changed during inspection' } }
        if ($Action -eq 'Plan') {
            if (-not $live.Count) { throw 'Empty inventory cannot authorize cleanup' }
            $plan = @{version=1; statePath=$binding.statePath; labId=$binding.state.labId; ownershipId=$binding.state.ownershipId; subscriptionId=$binding.state.subscriptionId; tenantId=$binding.state.tenantId; hashes=$binding.hashes; resourceGroups=$binding.scope.resourceGroups; inventory=$live; pending=$null; completed=@()}
            Write-CustomerJson $binding.cleanupPath $plan
            return @{status='Planned'; groups=$binding.scope.resourceGroups; next=$next}
        }
        if ($Action -eq 'Status') { return @{status=$(if ($next) { 'Ready' } else { 'Complete' }); next=$next} }
        if (-not $next) { Write-CustomerJson $binding.cleanupPath $plan; return @{status='Complete'} }
        $plan.pending = $next; Write-CustomerJson $binding.cleanupPath $plan
        Assert-LabResourceId $binding.scope $next.id
        if ($next.kind -eq 'group') { Invoke-CustomerAz $binding @('group','delete','--name',$next.name,'--yes','--no-wait') -Empty }
        else { Invoke-CustomerAz $binding @('rest','--method','delete','--url',"https://management.azure.com$($next.id)?api-version=$($next.api)") -Empty }
        return @{status='Submitted'; target=$next.id; message='Use Status to observe absence before another Step.'}
    } finally { $lock.Dispose() }
}

if (-not $customerArguments.DefinitionsOnly) { Invoke-CustomerTeardown @customerArguments }