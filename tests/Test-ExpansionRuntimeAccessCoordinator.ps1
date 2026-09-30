[CmdletBinding()]
param([string]$Compiler='bicep')

$ErrorActionPreference='Stop'
$runtimeTestCompiler=$Compiler
$runtimeTestRoot=$PSScriptRoot
Remove-Module ExpansionRuntimeAccess -ErrorAction SilentlyContinue
. (Join-Path $runtimeTestRoot '../scripts/Invoke-ExpansionRuntimeAccess.ps1') -DefinitionsOnly
$runtimeChecks=@{count=0}
function Check([bool]$Condition) { if (-not $Condition) { throw 'Runtime coordinator assertion failed' }; $runtimeChecks.count++ }
function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed }
function Invoke-LabAz { throw 'Offline test forbids Azure' }
function Invoke-ExpansionNetworkAz { throw 'Offline test forbids unmocked transport' }
function New-ExpansionArmReadSession { throw 'Offline test forbids authentication' }
function Invoke-ExpansionNetworkProcess { throw 'Offline test forbids unmocked processes' }
function Save-LabRun { throw 'Offline test forbids original state writes' }

$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $runtimeTestRoot 'Test-ExpansionRuntimeAccess.ps1'),[ref]$null,[ref]$null)
foreach ($name in @('Clone','Hash','New-Resource','New-RuntimeFixture','New-InheritedRuntimeRole')) {
    $definition=@($fixtureAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false))
    Check ($definition.Count -eq 1)
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$runtimeFixtureRoot=Assert-ExternalLabPath (Join-Path ([IO.Path]::GetTempPath()) ('runtime-coordinator-'+[guid]::NewGuid().ToString('N')))
$null=[IO.Directory]::CreateDirectory($runtimeFixtureRoot)
try {
    $compiledPath=Join-Path $runtimeFixtureRoot 'standard-access.json'
    & $runtimeTestCompiler build (Join-Path $runtimeTestRoot '../infra/modules/standard-access.bicep') --no-restore --outfile $compiledPath
    if ($LASTEXITCODE -ne 0) { throw 'Offline Bicep compilation failed' }
    $compiled=Read-FoundationJson $compiledPath
    & {
        $fixture=New-RuntimeFixture 'a-test'
        $inherited=New-InheritedRuntimeRole $fixture.state.subscriptionId
        $payload=@{value=@($fixture.evidence.roles)+@($inherited)}
        $before=Hash $payload
        $reads=@{subscription=0;inherited=0}
        function Invoke-ExpansionNetworkAz($State,$Arguments) {
            if ($Arguments[0] -cne 'rest' -or $Arguments[2] -cne 'get') { throw 'Only mocked reads permitted' }
            if ($Arguments[4].EndsWith('&$filter=atScope()')) { $reads.inherited++ } else { $reads.subscription++ }
            return Clone $payload
        }
        $prerequisites=@{host=@{network=@{dependencies=@{};outputs=@{selected=@{standard=@{storage=@{id=$fixture.evidence.resources.storage.id};cosmos=@{id=$fixture.evidence.resources.cosmos.id}}}}}}}
        function Read-ExpansionRuntimeArm($State,$Id,$Api,[switch]$List,[switch]$AtScope) {
            if ($Id.EndsWith('/sqlRoleAssignments')) { return @() }
            $query=if ($AtScope) { '&$filter=atScope()' } else { '' }
            return (Invoke-ExpansionNetworkAz $State @('rest','--method','get','--url',"https://management.azure.com${Id}?api-version=$Api$query")).value
        }
        $roles=Get-ExpansionRuntimeRoles $fixture.state $prerequisites
        Check ($roles.Count -eq 2 -and $reads.subscription -eq 1 -and $reads.inherited -eq 1 -and (Hash $payload) -ceq $before -and (Hash $roles[$inherited.id]) -ceq (Hash $inherited))
        $fixture.evidence.roles=@($roles.Values)
        $binding=Get-ExpansionRuntimeAccessBinding $fixture.state 'a-test' $fixture.evidence $fixture.scope
        $grants=Get-ExpansionRuntimeGrantResources $binding
        Check ($grants.Count -eq 3 -and -not $grants.ContainsKey($inherited.id))
        Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers (@($roles.Values)+@($grants.Values)) $fixture.evidence.protectedResources; Check $true
        foreach ($kind in @('Create','Modify','Delete','NoChange')) {
            $whatif=@{status='Succeeded';changes=@($grants.Values | ForEach-Object { @{resourceId=$_.id;changeType='Create';after=$_} })+@(@{resourceId=$inherited.id;changeType=$kind;before=$inherited;after=$inherited})}
            Reject { Assert-ExpansionRuntimeWhatIf $binding $roles $whatif }
        }
        foreach ($mutation in @(
            {param($role) $role.properties.scope+='/foreign'},
            {param($role) $role.id+='/foreign'},
            {param($role) $role.properties.scope='/subscriptions/55555555-5555-4555-8555-555555555555'; $role.id="$($role.properties.scope)/providers/Microsoft.Authorization/roleAssignments/$($role.name)"}
        )) { $payload.value=@(Clone $inherited); & $mutation $payload.value[0]; Reject { Get-ExpansionRuntimeRoles $fixture.state $prerequisites } }
    }
    foreach ($selection in @('a-test','b-dev','b-test')) {
        $fixture=New-RuntimeFixture $selection -HashedAgent
        $fixture.state.runDirectory=$runtimeFixtureRoot
        $binding=Get-ExpansionRuntimeAccessBinding $fixture.state $selection $fixture.evidence $fixture.scope
        Assert-ExpansionRuntimeAccessTemplate $compiled (Get-ExpansionRuntimeAccessParameters $binding $binding.scope) $binding $binding.scope; Check $true
        $paths=Get-ExpansionRuntimePaths $fixture.state $selection
        Check ($paths.lock -ceq (Get-ExpansionHostPaths $fixture.state $selection 'project').lock)
        Check ($paths.state.EndsWith("expansion-runtime-$selection.state.json"))
        Reject { Get-ExpansionRuntimePaths $fixture.state '../foreign' }
        $grants=Get-ExpansionRuntimeGrantResources $binding
        Check ($grants.Count -eq 3)
        $whatif=@{status='Succeeded';changes=@($grants.Values | ForEach-Object { @{resourceId=$_.id;changeType='Create';after=(Clone $_)} })}
        Assert-ExpansionRuntimeWhatIf $binding @{} $whatif; Check $true
        $sparseWhatIf=Clone $whatif
        foreach ($change in $sparseWhatIf.changes | Where-Object { $_.after.type -ieq 'Microsoft.Authorization/roleAssignments' }) { $change.after.properties.Remove('scope'); $change.after.properties.Remove('principalType') }
        Assert-ExpansionRuntimeWhatIf $binding @{} $sparseWhatIf; Check $true
        $azureGrant=@($grants.Values | Where-Object type -IEQ 'Microsoft.Authorization/roleAssignments')[0]
        $liveGrant=Clone $azureGrant
        foreach ($field in @('condition','conditionVersion','delegatedManagedIdentityResourceId','description')) { $liveGrant.properties[$field]=$null }
        Assert-ExpansionRuntimeGrant $liveGrant $azureGrant; Check $true
        $liveGrant.properties.Remove('principalType')
        Reject { Assert-ExpansionRuntimeGrant $liveGrant $azureGrant }
        foreach ($field in @('condition','conditionVersion','delegatedManagedIdentityResourceId','description','principalType')) {
            $badGrant=Clone $azureGrant; $badGrant.properties[$field]='unexpected'
            Reject { Assert-ExpansionRuntimeGrant $badGrant $azureGrant }
        }
        $badGrant=Clone $azureGrant; $badGrant.properties.principalType='User'
        Reject { Assert-ExpansionRuntimeGrant $badGrant $azureGrant -Payload }
        foreach ($kind in @('Modify','NoChange','Delete','Ignore','Unsupported')) { $bad=Clone $whatif; $bad.changes[0].changeType=$kind; Reject { Assert-ExpansionRuntimeWhatIf $binding @{} $bad } }
        $bad=Clone $whatif; $bad.changes[0].after.properties.scope=$fixture.scope
        Reject { Assert-ExpansionRuntimeWhatIf $binding @{} $bad }
        $bad=Clone $whatif; $bad.changes+=$bad.changes[0]
        Reject { Assert-ExpansionRuntimeWhatIf $binding @{} $bad }
        $bad=Clone $whatif; $bad.changes[0].before=$bad.changes[0].after
        Reject { Assert-ExpansionRuntimeWhatIf $binding @{} $bad }
        $native=@($grants.Values | Where-Object type -IEQ 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments')[0]
        $relative=Clone $native; $relative.properties.scope='/dbs/enterprise_memory'
        Assert-ExpansionRuntimeGrant $relative $native; Check $true
        $relative.properties.scope='/'
        Reject { Assert-ExpansionRuntimeGrant $relative $native }
        $roles=@($fixture.evidence.roles)+@($grants.Values)
        Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $roles $fixture.evidence.protectedResources; Check $true
        $bad=Clone $roles; $bad[0].properties.principalId=$fixture.state.tenantId
        Reject { Assert-ExpansionRuntimeAccessPreserved $binding $fixture.state $fixture.evidence.resources $fixture.evidence.containers $bad $fixture.evidence.protectedResources }
        $bad=Clone $fixture.evidence; $bad.roles=$roles
        Reject { Get-ExpansionRuntimeAccessBinding $fixture.state $selection $bad $fixture.scope }
    }
    Assert-ExpansionRuntimeTransition @{} 'a-test' 'Preview' $true; Check $true
    Reject { Assert-ExpansionRuntimeTransition @{} 'a-test' 'Preview' $false }
    Reject { Assert-ExpansionRuntimeTransition @{} 'a-test' 'Deploy' $true }
    Reject { Assert-ExpansionRuntimeTransition @{} 'a-test' 'Status' $false }
    foreach ($flags in @(@{pending=$true;verified=$false},@{pending=$false;verified=$true;outputHash=('A'*64)})) {
        $entry=@{stage='runtime-access';project='a-test'}+$flags
        foreach ($operation in @('Preview','Deploy')) { Reject { Assert-ExpansionRuntimeTransition @{'a-test'=$entry} 'a-test' $operation $true } }
        Assert-ExpansionRuntimeTransition @{'a-test'=$entry} 'a-test' 'Status' $false; Check $true
    }
    Reject { Assert-ExpansionRuntimeTransition @{'b-dev'=@{stage='runtime-access';project='b-dev';pending=$true;verified=$false}} 'a-test' 'Preview' $true }
    Reject { Assert-ExpansionRuntimeTransition @{'a-test'=@{stage='runtime-access';project='a-test';pending=$false;verified=$false;submittedAt='retained'}} 'a-test' 'Preview' $true }

    & {
        $hostFixture=New-RuntimeFixture 'a-test'; $hostFixture.state.runDirectory=Join-Path $runtimeFixtureRoot 'host-prerequisites'
        $null=[IO.Directory]::CreateDirectory($hostFixture.state.runDirectory)
        $hostValidation=@{reviews=0;receipts=0}
        function Get-ExpansionHostPrerequisites { return @{files=@{}} }
        function Get-ExpansionHostSources { return @{fixture=('A'*64)} }
        function Get-ExpansionHostBinding($State,$Base,$Selector,$Stage) { return @{key=(Get-ExpansionHostPaths $State $Selector $Stage).key} }
        function Assert-ExpansionHostReview($Entry,$Binding,$Paths,$Base,$Sources,[switch]$Submitted) { Check ([bool]$Submitted); Check ($Entry.verified -and -not $Entry.pending); $hostValidation.reviews++ }
        function Assert-ExpansionHostReceipt { $hostValidation.receipts++ }
        foreach ($pair in @(@('a-test','account'),@('b-dev','account'),@('a-test','project'),@('b-dev','project'),@('b-test','project'))) {
            $hostPaths=Get-ExpansionHostPaths $hostFixture.state $pair[0] $pair[1]
            Write-StandardJson $hostPaths.state @{verified=$true;pending=$false;mode='Reuse'}
            Write-StandardJson $hostPaths.outputs @{fixture=$true}
        }
        $allHosts=Get-ExpansionRuntimePrerequisites $hostFixture.state 'unused'
        Check ($allHosts.all.Count -eq 5 -and $allHosts.receipts.Count -eq 5 -and $allHosts.files.Count -eq 10 -and $hostValidation.reviews -eq 5 -and $hostValidation.receipts -eq 5)
        Remove-Item -LiteralPath $hostPaths.outputs
        Reject { Get-ExpansionRuntimePrerequisites $hostFixture.state 'unused' }
    }

    & {
        $fixture=New-RuntimeFixture 'a-test' -HashedAgent
        $binding=Get-ExpansionRuntimeAccessBinding $fixture.state 'a-test' $fixture.evidence $fixture.scope
        $grants=Get-ExpansionRuntimeGrantResources $binding
        $known=@{}
        $search=New-Resource "$($fixture.scope)/providers/Microsoft.Search/searchServices/fixture" 'Microsoft.Search/searchServices' @{publicNetworkAccess='Disabled'}
        $search.location='Sweden Central'; $known[$search.id]=$search
        $sparse=Clone $search; $sparse.location='swedencentral'; $sparse.properties.publicNetworkAccess='disabled'
        $endpoint="$($fixture.scope)/providers/Microsoft.Network/privateEndpoints/fixture"
        $known[$endpoint]=New-Resource $endpoint 'Microsoft.Network/privateEndpoints' @{}
        $nic=New-Resource "$($fixture.scope)/providers/Microsoft.Network/networkInterfaces/fixture.nic.11111111-1111-4111-8111-111111111111" 'Microsoft.Network/networkInterfaces' @{}
        $known[$nic.id]=$nic
        $sparseNic=Clone $nic; $sparseNic.managedBy=$endpoint
        $whatif=@{status='Succeeded';changes=@($grants.Values | ForEach-Object { @{resourceId=$_.id;changeType='Create';after=(Clone $_)} })}
        foreach ($resource in @($sparse,$sparseNic)) { $whatif.changes+=@{resourceId=$resource.id;changeType='Ignore';before=(Clone $resource);after=(Clone $resource)} }
        Assert-ExpansionRuntimeWhatIf $binding $known $whatif; Check $true
        $bad=Clone $whatif; $bad.changes[-1].before.managedBy+='/foreign'; $bad.changes[-1].after=Clone $bad.changes[-1].before
        Reject { Assert-ExpansionRuntimeWhatIf $binding $known $bad }
        $bad=Clone $whatif; $bad.changes[-2].before.properties.publicNetworkAccess='enabled'; $bad.changes[-2].after=Clone $bad.changes[-2].before
        Reject { Assert-ExpansionRuntimeWhatIf $binding $known $bad }
        $bad=Clone $whatif; $bad.changes[-1].resourceId+='/foreign'
        Reject { Assert-ExpansionRuntimeWhatIf $binding $known $bad }
    }

    & {
        $fixture=New-RuntimeFixture 'a-test' -HashedAgent
        $binding=Get-ExpansionRuntimeAccessBinding $fixture.state 'a-test' $fixture.evidence $fixture.scope
        $grants=Get-ExpansionRuntimeGrantResources $binding; $root=Get-ExpansionRuntimeRoot $binding
        $manifest=@{binding=$binding;deploymentId=$root;pending=$true;verified=$false}
        $deployment=@{id=$root;name=($root -split '/')[-1];properties=@{provisioningState='Succeeded';mode='Incremental';parameters=$binding.plan.parameters;outputs=@{};outputResources=@($grants.Keys | ForEach-Object { @{id=$_} })}}
        $operations=@(); $index=0
        foreach ($grant in $grants.Values) { $operations+=@{id="$root/operations/$index";properties=@{provisioningState='Succeeded';provisioningOperation='Create';targetResource=@{id=$grant.id;resourceType=$grant.type}}}; $index++ }
        Assert-ExpansionRuntimeDeployment $manifest $deployment $operations; Check $true
        $typed=Clone $deployment; foreach ($parameter in $typed.properties.parameters.Values) { $parameter.type='String' }
        Assert-ExpansionRuntimeDeployment $manifest $typed $operations; Check $true
        $typed.properties.parameters.workspaceId.type='Object'
        Reject { Assert-ExpansionRuntimeDeployment $manifest $typed $operations }
        $bad=Clone $operations; $bad[0].properties.targetResource.id=$fixture.scope
        Reject { Assert-ExpansionRuntimeDeployment $manifest $deployment $bad }
        $bad=Clone $operations; $bad[0].properties.provisioningOperation='Delete'
        Reject { Assert-ExpansionRuntimeDeployment $manifest $deployment $bad }
        Reject { Assert-ExpansionRuntimeDeployment $manifest $deployment @($operations[0],$operations[1]) }
        $bad=Clone $deployment; $bad.properties.provisioningState='Running'
        Reject { Assert-ExpansionRuntimeDeployment $manifest $bad $operations }
        $graphFixture=@{deployment=$deployment;operations=$operations;hide=$false;foreign=$false}
        function Read-ExpansionNetworkArm($State,$Id,$Api,[switch]$List) {
            if ($Id -ceq $root) { return $graphFixture.deployment }
            if ($Id -ceq "$root/operations") { return $graphFixture.operations }
            if ($Id -ceq "$($binding.scope)/providers/Microsoft.Resources/deployments") {
                if (-not $graphFixture.hide) { $graphFixture.deployment }
                if ($graphFixture.foreign) { @{id="$root-foreign";name='foreign'} }
                return
            }
            throw 'Unexpected offline graph read'
        }
        function Get-ExpansionHostIdle($State,$Prerequisites,$All,$Receipts) {
            $remaining=@(Read-ExpansionNetworkArm $State "$($binding.scope)/providers/Microsoft.Resources/deployments" '2022-09-01' -List)
            if ($remaining.Count) { throw 'Unknown deployment in host graph' }
            return @{}
        }
        $graph=Get-ExpansionRuntimeIdle $fixture.state @{host=@{};all=@{};receipts=@{}} @{'a-test'=$manifest} @{}
        Check ($graph.Count -eq 1 -and $graph.ContainsKey($root))
        $graphFixture.hide=$true
        Reject { Get-ExpansionRuntimeIdle $fixture.state @{host=@{};all=@{};receipts=@{}} @{'a-test'=$manifest} @{} }
        $graphFixture.hide=$false; $graphFixture.foreign=$true
        Reject { Get-ExpansionRuntimeIdle $fixture.state @{host=@{};all=@{};receipts=@{}} @{'a-test'=$manifest} @{} }
    }

    & {
        $fixtures=@{}; foreach ($selection in @('a-test','b-dev','b-test')) { $fixtures[$selection]=New-RuntimeFixture $selection -HashedAgent; $fixtures[$selection].state.runDirectory=$runtimeFixtureRoot }
        $mock=@{writes=0;failSubmit=$true;failCompletion=$false;source=('A'*64);reads=0;closed=0;http=0;fallback=0;probe=$false;roles=@{};live=@{baseline=@{};protected=@{};hosts=@{};inventory=@{}}}
        foreach ($selection in @('a-test','b-dev')) { foreach ($role in $fixtures[$selection].evidence.roles) { $mock.roles[$role.id]=$role } }
        $originalPath=Join-Path $runtimeFixtureRoot 'original.json'
        Write-StandardJson $originalPath $fixtures['a-test'].state
        $inputHash=(Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
        $prereq=@{host=@{network=@{inputs=@{state=$inputHash};outputs=@{}}};files=@{};all=@{};receipts=@{}}
        $prereq.files[$originalPath]=$inputHash
        foreach ($selection in $fixtures.Keys) { $prereq.host.network.outputs[$selection]=@{standard=@{resourceGroupId=$fixtures[$selection].scope}} }
        function Read-LabRun($Path) { return Read-FoundationJson $Path }
        function Assert-FoundationOriginal { }
        function Get-ExpansionRuntimePrerequisites { return $prereq }
        function Assert-ExpansionHostInputs { }
        function Get-ExpansionRuntimeSources { return @{coordinator=$mock.source} }
        function Get-ExpansionRuntimeLive { $mock.reads++; return Clone $mock.live }
        function Get-ExpansionRuntimeRoles { return Clone $mock.roles }
        function Get-ExpansionRuntimeEvidence($State,$Prerequisites,$Selector,$HostLive,$Roles) { $value=Clone $fixtures[$Selector].evidence; $value.roles=@($Roles.Values); return $value }
        function Get-ExpansionRuntimeIdle($State,$Prerequisites,$All,$Receipts) {
            if ($mock.probe) {
                $url="https://management.azure.com/subscriptions/$($State.subscriptionId)/resourceGroups?api-version=2025-04-01"
                $null=Invoke-ExpansionNetworkAz $State @('rest','--method','get','--url',$url,'--headers','Accept=application/json')
                $null=Invoke-FoundationAz $State @('rest','--method','get','--url',$url,'--headers','Accept=application/json') 'fixture'
                $null=Invoke-ExpansionNetworkAz $State @('rest','--method','get','--url',($url+'&$filter=atScope()'),'--headers','Accept=application/json')
            }
            $graph=@{}; foreach ($entry in $All.Values) { if ($entry.pending -or $entry.verified) { $graph[(Get-ExpansionRuntimeRoot $entry.binding)]=@{deploymentHash=('B'*64);operationsHash=('C'*64)} } }; return $graph
        }
        function New-ExpansionArmReadSession { return @{synthetic=$true} }
        function Invoke-ExpansionArmRead { $mock.http++; return @{value=@()} }
        function Close-ExpansionArmReadSession($Session) { if ($Session) { Check $Session.synthetic; $mock.closed++ } }
        function Invoke-ExpansionNetworkProcess($State,$Executable,$Arguments) { Assert-FoundationEqual $Executable $runtimeTestCompiler; Write-StandardJson $Arguments[-1] $compiled }
        function Invoke-ExpansionNetworkAz($State,$Arguments,[switch]$Empty) {
            if ($Arguments[0] -ceq 'rest' -and $Arguments[4].EndsWith('&$filter=atScope()')) { $mock.fallback++; return @{value=@()} }
            if ($Arguments[0] -cne 'deployment' -or $Arguments[1] -cne 'group') { throw 'Unapproved synthetic CLI command' }
            if ($Arguments[2] -ceq 'validate') { return @{properties=@{provisioningState='Succeeded'}} }
            if ($Arguments[2] -ceq 'what-if') {
                Check ($Arguments -ccontains 'FullResourcePayloads')
                $selection=($Arguments[([array]::IndexOf($Arguments,'--name')+1)] -replace '^fgl-sample01-exp-runtime-','')
                $value=Clone $fixtures[$selection].evidence; $value.roles=@($mock.roles.Values)
                $expected=Get-ExpansionRuntimeAccessBinding $State $selection $value $fixtures[$selection].scope
                return @{status='Succeeded';changes=@((Get-ExpansionRuntimeGrantResources $expected).Values | ForEach-Object { @{resourceId=$_.id;changeType='Create';after=$_} })}
            }
            if ($Arguments[2] -ceq 'create') {
                Check ([bool]$Empty -and $Arguments -ccontains '--no-wait')
                $selection=($Arguments[([array]::IndexOf($Arguments,'--name')+1)] -replace '^fgl-sample01-exp-runtime-','')
                $intent=Read-FoundationJson (Get-ExpansionRuntimePaths $State $selection).state
                Check ($intent.pending -and -not $intent.verified -and $intent.deploymentId -ceq (Get-ExpansionRuntimeRoot $intent.binding))
                $mock.writes++
                if ($mock.failSubmit) { throw 'Synthetic interrupted no-wait submit' }
                return
            }
            throw 'Unexpected synthetic CLI command'
        }
        $jsonWriter=(Get-Command Write-StandardJson).ScriptBlock
        function Write-StandardJson($Path,$Value) {
            if ($mock.failCompletion -and $Path.EndsWith('.state.json') -and $Value.verified) { throw 'Synthetic failure after output move' }
            & $jsonWriter $Path $Value
        }
        $arguments=@{Path=$originalPath;Selector='a-test';SelectedAction='Preview';Compiler=$runtimeTestCompiler;Approved=$true}
        $sharedLock=[IO.File]::Open((Get-ExpansionRuntimePaths $fixtures['a-test'].state 'a-test').lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Reject { Invoke-ExpansionRuntimeAccess @arguments }; Check ($mock.writes -eq 0) } finally { $sharedLock.Dispose() }
        $mock.probe=$true
        $preview=Invoke-ExpansionRuntimeAccess @arguments
        Check ($preview.action -ceq 'Preview' -and $mock.writes -eq 0 -and $mock.http -eq 4 -and $mock.fallback -eq 2 -and $mock.closed -eq 1)
        $previewPaths=Get-ExpansionRuntimePaths $fixtures['a-test'].state 'a-test'; $previewManifest=Read-FoundationJson $previewPaths.state
        $wrongPaths=Clone $previewPaths; $wrongPaths.state=Join-Path $runtimeFixtureRoot 'foreign.state.json'
        Reject { Assert-ExpansionRuntimeReview $previewManifest $previewManifest.binding.state $wrongPaths $prereq (Get-ExpansionRuntimeSources) }
        $mock.probe=$false
        $arguments.SelectedAction='Deploy'; $mock.source=('D'*64)
        Reject { Invoke-ExpansionRuntimeAccess @arguments }
        Check ($mock.writes -eq 0)
        $mock.source=('A'*64)
        Reject { Invoke-ExpansionRuntimeAccess @arguments }
        Check ($mock.writes -eq 1)
        Reject { Invoke-ExpansionRuntimeAccess @arguments }
        Check ($mock.writes -eq 1)
        $paths=Get-ExpansionRuntimePaths $fixtures['a-test'].state 'a-test'
        $pending=Read-FoundationJson $paths.state
        foreach ($grant in (Get-ExpansionRuntimeGrantResources $pending.binding).Values) { $mock.roles[$grant.id]=$grant }
        $arguments.SelectedAction='Status'; $arguments.Approved=$false; $mock.failCompletion=$true
        Reject { Invoke-ExpansionRuntimeAccess @arguments }
        Check ((Test-Path -LiteralPath $paths.outputs) -and (Read-FoundationJson $paths.state).pending -and $mock.writes -eq 1)
        $orphanHash=(Get-FileHash -LiteralPath $paths.outputs -Algorithm SHA256).Hash
        $mock.failCompletion=$false
        $receipt=Invoke-ExpansionRuntimeAccess @arguments
        Check ($receipt.controlPlaneVerified -and -not $receipt.runtimeVerified -and -not $receipt.inferenceVerified -and -not $receipt.completeLab)
        Check ((Read-FoundationJson $paths.state).verified -and $orphanHash -ceq (Get-FileHash -LiteralPath $paths.outputs -Algorithm SHA256).Hash)
        $readCount=$mock.reads
        $null=Invoke-ExpansionRuntimeAccess @arguments
        Check ($mock.reads -gt $readCount -and $mock.writes -eq 1)
        $arguments.Selector='b-dev'; $arguments.SelectedAction='Preview'; $arguments.Approved=$true
        $null=Invoke-ExpansionRuntimeAccess @arguments
        $arguments.SelectedAction='Deploy'; $mock.failSubmit=$false
        $null=Invoke-ExpansionRuntimeAccess @arguments
        $second=Read-FoundationJson (Get-ExpansionRuntimePaths $fixtures['b-dev'].state 'b-dev').state
        foreach ($grant in (Get-ExpansionRuntimeGrantResources $second.binding).Values) { $mock.roles[$grant.id]=$grant }
        $arguments.SelectedAction='Status'; $arguments.Approved=$false
        $null=Invoke-ExpansionRuntimeAccess @arguments
        Check ($mock.writes -eq 2)
        $arguments.Selector='a-test'
        $null=Invoke-ExpansionRuntimeAccess @arguments
        Check ($mock.writes -eq 2 -and $orphanHash -ceq (Get-FileHash -LiteralPath $paths.outputs -Algorithm SHA256).Hash)
        $originalRole=$fixtures['a-test'].evidence.roles[0].id; $mock.roles[$originalRole].properties.principalId=$fixtures['a-test'].state.tenantId
        Reject { Invoke-ExpansionRuntimeAccess @arguments }
        Check ($inputHash -ceq (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash)
    }
} finally { Remove-Item -LiteralPath $runtimeFixtureRoot -Recurse -Force }
Write-Output "PASS: $($runtimeChecks.count) runtime coordinator offline checks; no Azure calls."