[CmdletBinding()]
param([string]$BicepExecutable = 'bicep')
$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    $compiler=$BicepExecutable
    . (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionFoundation.ps1') -DefinitionsOnly
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1')
    foreach ($file in @('Invoke-StandardStage.ps1','Test-StandardPrivate.ps1','Invoke-StandardCosmosNetwork.ps1','Update-LabGatewayPolicy.ps1')) { . (Join-Path $PSScriptRoot "../scripts/$file") -DefinitionsOnly }
    $checks = @{count=0}
    function Check([bool]$Condition) { if (-not $Condition) { throw 'Foundation assertion failed' }; $checks.count++ }
    function Reject([scriptblock]$Probe) { $failed=$false; try { $null = & $Probe } catch { $failed=$true }; Check $failed }
    function Copy-Fixture($Value) { return ($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100) }
    function New-FoundationFixture {
        $state = @{subscriptionId='11111111-1111-4111-8111-111111111111';tenantId='22222222-2222-4222-8222-222222222222';ownershipId='33333333-3333-4333-8333-333333333333';labId='sample01';minimalPrompt=$true;phase='activate';pendingPhase=$null;deploymentAuthorized=$true;privateAccessVerified=$true;preexistingGroupIds=@();resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" });standard=@{completedStages=@('dependencies','account','project','access');pendingStage=$null;deploymentNames=@{}}}
        foreach ($stage in @('dependencies','project','access')) { $state.standard.deploymentNames[$stage]="fgl-sample01-standard-$stage" }
        foreach ($spec in @(@('cosmosNetwork','standard-cosmos-network'),@('gatewayPolicy','gateway-policy-update'))) { $state.standard[$spec[0]]=@{name="fgl-sample01-$($spec[1])";group='rg-fgl-sample01-integration';pending=$false;verified=$true;review=@{};evidence=@{}} }
        return $state
    }
    $fixture = New-FoundationFixture
    Assert-FoundationOriginal $fixture; Check $true
    foreach ($mutation in @({param($value) $value.minimalPrompt=$false},{param($value) $value.pendingPhase='activate'},{param($value) $value.standard.pendingStage='access'},{param($value) $value.standard.completedStages=@('dependencies','account','project')},{param($value) $value.standard.gatewayPolicy.pending=$true},{param($value) $value.standard.cosmosNetwork.verified='true'},{param($value) $value.standard.deploymentNames.access='foreign'})) {
        $altered=Copy-Fixture $fixture; & $mutation $altered; Reject { Assert-FoundationOriginal $altered }
    }
    Assert-FoundationTransition $null 'Preview' $true; Check $true
    Reject { Assert-FoundationTransition $null 'Preview' $false }
    Reject { Assert-FoundationTransition $null 'Deploy' $true }
    Reject { Assert-FoundationTransition $null 'Status' $false }
    $manifest=@{pending=$false;verified=$false;review=@{}}
    Assert-FoundationTransition $manifest 'Deploy' $true; Check $true
    Reject { Assert-FoundationTransition $manifest 'Deploy' $false }
    $manifest.pending=$true
    Reject { Assert-FoundationTransition $manifest 'Deploy' $true }
    Reject { Assert-FoundationTransition $manifest 'Preview' $true }
    Assert-FoundationTransition $manifest 'Status' $false; Check $true
    Check ((Get-FoundationHash @{alpha=1;beta=@('x','y')}) -ceq (Get-FoundationHash @{beta=@('x','y');alpha=1}))
    Check ((Get-FoundationHash @{enabled=$true}) -cne (Get-FoundationHash @{enabled='true'}))
    function New-FoundationLab([hashtable]$Original) {
        $prefix="/subscriptions/$($Original.subscriptionId)/resourceGroups/rg-fgl-$($Original.labId)"
        $account="$prefix-case-a/providers/Microsoft.CognitiveServices/accounts/aif-fgl-$($Original.labId)-a-abcdefghijklm"
        return @{minimalPrompt=$true;phase='activate';resourceGroups=$Original.resourceGroups;models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-$($Original.labId)-models-abcdefghijklm";gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-$($Original.labId)-abcdefghijklm";cases=@(@{accountId=$account;registryId='';projects=@(@{resourceId="$account/projects/case-a-dev";principalId='44444444-4444-4444-8444-444444444444'})});identities=@('dev-a','consumer-a','dev-b','publisher-a','publisher-b','client','denied' | ForEach-Object { @{actor=$_;resourceId="$prefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-$($Original.labId)-$_";principalId='55555555-5555-4555-8555-555555555555';clientId='66666666-6666-4666-8666-666666666666'} })}
    }
    $labFixture=New-FoundationLab $fixture
    $bindingFixture=Get-FoundationBinding $fixture $labFixture $compiler
    Check ($bindingFixture.new.Count -eq 14 -and $bindingFixture.nested.Count -eq 11)
    Check ($bindingFixture.new[$bindingFixture.accountA] -eq $null -and $bindingFixture.new[$bindingFixture.devA] -eq $null)
    Check ($bindingFixture.accountB.EndsWith('-b-abcdefghijklm') -and $fixture.resourceGroups.Count -eq 3)
    $externalFixtures=@(
        @{name='PolicyDeployment_12345';type='Microsoft.CognitiveServices/accounts/providers/diagnosticSettings';target="$($bindingFixture.accountB)/providers/Microsoft.Insights/diagnosticSettings/external-policy"},
        @{name='Failure-Anomalies-Alert-Rule-Deployment-12345';type='Microsoft.AlertsManagement/smartDetectorAlertRules';target="$($bindingFixture.groupB)/providers/Microsoft.AlertsManagement/smartDetectorAlertRules/automatic-alert"}
    )
    foreach ($external in $externalFixtures) {
        $child=@{id="$($bindingFixture.groupB)/providers/Microsoft.Resources/deployments/$($external.name)";name=$external.name;properties=@{mode='Incremental';provisioningState='Failed'}}
        $operations=@(@{properties=@{provisioningOperation='Create';provisioningState='Failed';targetResource=@{id=$external.target;resourceType=$external.type}}})
        $finding=Assert-FoundationEnvironmentDeployment $bindingFixture $child $operations
        Check ($finding.state -ceq 'Failed' -and $finding.targetId -ceq $external.target -and $finding.operationsHash.Length -eq 64)
        foreach ($mutation in @({param($value) $value.properties.provisioningState='Succeeded'},{param($value) $value.properties.provisioningState='Running'},{param($value) $value.properties.mode='Complete'},{param($value) $value.properties.outputResources=@(@{id='created'})},{param($value) $value.name='Unknown';$value.id="$($bindingFixture.groupB)/providers/Microsoft.Resources/deployments/Unknown"},{param($value) $value.id=$value.id.Replace('case-b','unrelated')})) {
            $bad=Copy-Fixture $child; & $mutation $bad
            Reject { Assert-FoundationEnvironmentDeployment $bindingFixture $bad $operations }
        }
        foreach ($mutation in @({param($value) $value[0].properties.provisioningState='Succeeded'},{param($value) $value[0].properties.provisioningState='Running'},{param($value) $value[0].properties.provisioningOperation='Delete'},{param($value) $value[0].properties.targetResource.id=$value[0].properties.targetResource.id.Replace('case-b','case-a')},{param($value) $value[0].properties.targetResource.resourceType='Microsoft.Storage/storageAccounts'})) {
            $bad=@(Copy-Fixture $operations); & $mutation $bad
            Reject { Assert-FoundationEnvironmentDeployment $bindingFixture $child $bad }
        }
        Reject { Assert-FoundationEnvironmentDeployment $bindingFixture $child @() }
        Reject { Assert-FoundationEnvironmentDeployment $bindingFixture $child @($operations+$operations) }
    }
    Reject { Invoke-ExpansionFoundation '' 'Deploy' $compiler $true $true }
    function New-FoundationResources([hashtable]$Original, [hashtable]$Bound) {
        $resources=@{}
        $types=@{group='Microsoft.Resources/resourceGroups';account='Microsoft.CognitiveServices/accounts';project='Microsoft.CognitiveServices/accounts/projects';workspace='Microsoft.OperationalInsights/workspaces';insights='Microsoft.Insights/components';endpoint='Microsoft.Network/privateEndpoints';zoneGroup='Microsoft.Network/privateEndpoints/privateDnsZoneGroups';diagnostic='Microsoft.Insights/diagnosticSettings';role='Microsoft.Authorization/roleAssignments';link='Microsoft.Insights/privateLinkScopes/scopedResources'}
        foreach ($id in $Bound.new.Keys) {
            $kind=$Bound.new[$id]
            $resource=@{id=$id;type=$types[$kind];name=($id -split '/')[-1];location='swedencentral';tags=@{'fgl-lab'=$Original.labId;'fgl-owner'=$Original.ownershipId;purpose='synthetic-governance-lab'};properties=@{provisioningState='Succeeded'}}
            switch ($kind) {
                'account' { $resource.kind='AIServices'; $resource.sku=@{name='S0'}; $resource.properties+=@{publicNetworkAccess='Disabled';disableLocalAuth=$true;allowProjectManagement=$true;restrictOutboundNetworkAccess=$false;customSubDomainName=$resource.name;networkAcls=@{defaultAction='Deny';bypass='None';ipRules=@();virtualNetworkRules=@()};networkInjections=@(@{scenario='agent';subnetArmId=$Bound.agentSubnet;useMicrosoftManagedNetwork=$false})} }
                'workspace' { $resource.properties+=@{publicNetworkAccessForIngestion='Disabled';publicNetworkAccessForQuery='Disabled';features=@{disableLocalAuth=$true}} }
                'insights' { $resource.properties+=@{publicNetworkAccessForIngestion='Disabled';publicNetworkAccessForQuery='Disabled';DisableLocalAuth=$true;WorkspaceResourceId=$Bound.workspace} }
                'endpoint' { $resource.properties+=@{subnet=@{id=$Bound.peSubnet};privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$Bound.accountB;groupIds=@('account');privateLinkServiceConnectionState=@{status='Approved'}}})} }
                'zoneGroup' { $resource.properties.privateDnsZoneConfigs=@($Bound.zones | ForEach-Object { @{properties=@{privateDnsZoneId=$_}} }) }
                'link' { $resource.properties.linkedResourceId=if ($id -eq $Bound.links[0]) { $Bound.workspace } else { $Bound.insights } }
                'role' { $resource.properties=Copy-Fixture $Bound.roles[$id] }
                'diagnostic' { $resource.properties+=@{workspaceId=$Bound.workspace;metrics=@(@{category='AllMetrics';enabled=$true});logs=@()} }
            }
            if ($kind -in @('account','project')) { $resource.identity=@{type='SystemAssigned';principalId='44444444-4444-4444-8444-444444444444';tenantId=$Original.tenantId} }
            $resources[$id]=$resource
        }
        return $resources
    }
    $newFixture=New-FoundationResources $fixture $bindingFixture
    $selection=Select-FoundationConfiguration $newFixture[$bindingFixture.accountB]
    Check ($selection.properties.networkInjections -is [array] -and $selection.properties.networkInjections.Count -eq 1)
    Check ($selection.properties.networkAcls.ipRules -is [array] -and $selection.properties.networkAcls.ipRules.Count -eq 0)
    Assert-FoundationEqual $selection (Copy-Fixture $selection); Check $true
    $whatIfFixture=@{status='Succeeded';changes=@(foreach ($id in $newFixture.Keys) { @{resourceId=$id;changeType='Create';after=$newFixture[$id]} })}
    Assert-FoundationWhatIf $fixture $bindingFixture @{} $whatIfFixture; Check $true
    $projected=Copy-Fixture $newFixture
    $projected[$bindingFixture.accountB].properties.networkAcls.Remove('ipRules'); $projected[$bindingFixture.accountB].properties.networkAcls.Remove('virtualNetworkRules')
    $projected[$bindingFixture.workspace].properties.Remove('features')
    $projected[$bindingFixture.diagnostic].properties.Remove('logs')
    foreach ($id in $bindingFixture.roles.Keys) { $projected[$id].properties.Remove('principalType'); $projected[$id].properties.principalId="[reference('$($bindingFixture.developerId)', '2023-01-31').principalId]" }
    Assert-FoundationWhatIf $fixture $bindingFixture @{} @{status='Succeeded';changes=@(foreach ($id in $projected.Keys) { @{resourceId=$id;changeType='Create';after=$projected[$id]} })}; Check $true
    Reject { Assert-FoundationNewResource $fixture $bindingFixture $projected[$bindingFixture.workspace] $bindingFixture.workspace -Live }
    foreach ($id in $bindingFixture.roles.Keys) {
        Reject { Assert-FoundationNewResource $fixture $bindingFixture $projected[$id] $id -Live }
        $projected[$id].properties.principalId="[reference('$($bindingFixture.developerId)-other', '2023-01-31').principalId]"
        Reject { Assert-FoundationNewResource $fixture $bindingFixture $projected[$id] $id }
    }
    foreach ($id in $bindingFixture.new.Keys) {
        Assert-FoundationNewResource $fixture $bindingFixture $newFixture[$id] $id -Live; Check $true
        $altered=Copy-Fixture $whatIfFixture; $altered.changes=@($altered.changes | Where-Object resourceId -INE $id)
        Reject { Assert-FoundationWhatIf $fixture $bindingFixture @{} $altered }
        foreach ($type in @('Modify','Delete','Unsupported','NoChange','Ignore')) {
            $altered=Copy-Fixture $whatIfFixture; @($altered.changes | Where-Object resourceId -IEQ $id)[0].changeType=$type
            Reject { Assert-FoundationWhatIf $fixture $bindingFixture @{} $altered }
        }
    }
    foreach ($id in @($bindingFixture.accountA,$bindingFixture.devA,$bindingFixture.vnet,$bindingFixture.agentSubnet,$bindingFixture.developerId,$bindingFixture.zones[0],$bindingFixture.ampls,$labFixture.models,$labFixture.gateway,"$($bindingFixture.accountB)/projects/case-b-extra")) {
        $altered=Copy-Fixture $whatIfFixture; $altered.changes+=@{resourceId=$id;changeType='Create';after=@{id=$id;type='Microsoft.CognitiveServices/accounts';properties=@{}}}
        Reject { Assert-FoundationWhatIf $fixture $bindingFixture @{} $altered }
    }
    foreach ($mutation in @(
        {param($items,$bound) $items[$bound.accountB].properties.publicNetworkAccess='Enabled'},
        {param($items,$bound) $items[$bound.accountB].properties.disableLocalAuth='true'},
        {param($items,$bound) $items[$bound.accountB].properties.networkInjections[0].subnetArmId=$bound.agentSubnet.Replace('agent-b','agent-a')},
        {param($items,$bound) $items[$bound.accountB].tags['fgl-owner']='foreign'},
        {param($items,$bound) $items[$bound.workspace].properties.publicNetworkAccessForQuery='Enabled'},
        {param($items,$bound) $items[$bound.insights].properties.WorkspaceResourceId='foreign'},
        {param($items,$bound) $items[$bound.endpoint].properties.subnet.id='foreign'},
        {param($items,$bound) $items[$bound.endpoint].properties.privateLinkServiceConnections[0].properties.privateLinkServiceId=$bound.accountA},
        {param($items,$bound) $items[$bound.zoneGroup].properties.privateDnsZoneConfigs=@()},
        {param($items,$bound) $items[$bound.links[0]].properties.linkedResourceId=$bound.insights},
        {param($items,$bound) $items[$bound.diagnostic].properties.logs=@(@{category='RequestResponse';enabled=$true})}
    )) {
        $altered=Copy-Fixture $newFixture; & $mutation $altered $bindingFixture
        Reject { Assert-FoundationWhatIf $fixture $bindingFixture @{} @{status='Succeeded';changes=@(foreach ($id in $altered.Keys) { @{resourceId=$id;changeType='Create';after=$altered[$id]} })} }
    }
    foreach ($id in $bindingFixture.roles.Keys) {
        foreach ($key in @('principalId','principalType','roleDefinitionId','scope')) { $badRole=Copy-Fixture $newFixture[$id]; $badRole.properties[$key]='foreign'; Reject { Assert-FoundationNewResource $fixture $bindingFixture $badRole $id } }
    }
    foreach ($spec in @(@($bindingFixture.accountB,'publicNetworkAccess'),@($bindingFixture.workspace,'publicNetworkAccessForIngestion'),@($bindingFixture.insights,'publicNetworkAccessForQuery'))) {
        $bad=Copy-Fixture $newFixture[$spec[0]]; $bad.properties[$spec[1]]=$true
        Reject { Assert-FoundationNewResource $fixture $bindingFixture $bad $spec[0] }
    }
    Reject { Assert-FoundationWhatIf $fixture $bindingFixture @{} @{status=$true;changes=$whatIfFixture.changes} }
    $protectedResource=Copy-Fixture $newFixture[$bindingFixture.accountB]; $protectedResource.id=$bindingFixture.accountA
    $baselineFixture=@{}; $baselineFixture[$protectedResource.id]=Select-FoundationConfiguration $protectedResource
    $ignored=@{resourceId=$protectedResource.id;changeType='Ignore';before=$protectedResource;after=(Copy-Fixture $protectedResource)}
    $ignored.after.properties.provisioningState='Updating'; $ignored.after.etag='changed'; $ignored.after.systemData=@{lastModifiedAt='later'}
    Assert-FoundationWhatIf $fixture $bindingFixture $baselineFixture @{status='Succeeded';changes=($whatIfFixture.changes+@($ignored))}; Check $true
    $ignored.after.properties.publicNetworkAccess='Enabled'
    Reject { Assert-FoundationWhatIf $fixture $bindingFixture $baselineFixture @{status='Succeeded';changes=($whatIfFixture.changes+@($ignored))} }
    $sparseIgnore=Copy-Fixture $ignored
    $sparseIgnore.before.Remove('properties'); $sparseIgnore.after.Remove('properties')
    Assert-FoundationWhatIf $fixture $bindingFixture $baselineFixture @{status='Succeeded';changes=($whatIfFixture.changes+@($sparseIgnore))}; Check $true
    $sparseIgnore.after.identity.type='None'
    Reject { Assert-FoundationWhatIf $fixture $bindingFixture $baselineFixture @{status='Succeeded';changes=($whatIfFixture.changes+@($sparseIgnore))} }
    $ignored.Remove('after'); $ignored.delta=@(@{path='properties.publicNetworkAccess'})
    Reject { Assert-FoundationWhatIf $fixture $bindingFixture $baselineFixture @{status='Succeeded';changes=($whatIfFixture.changes+@($ignored))} }
    $ignored.Remove('delta'); $ignored.resourceId+='-unknown'; $ignored.before.id=$ignored.resourceId
    Reject { Assert-FoundationWhatIf $fixture $bindingFixture $baselineFixture @{status='Succeeded';changes=($whatIfFixture.changes+@($ignored))} }
    foreach ($type in @('Microsoft.Network/networkInterfaces','Microsoft.EventGrid/systemTopics')) {
        $resource=@{id="$($bindingFixture.groupA)/providers/$type/generated";type=$type}
        $generated=@{resourceId=$resource.id;changeType='Ignore';before=$resource;after=(Copy-Fixture $resource)}
        Assert-FoundationWhatIf $fixture $bindingFixture $baselineFixture @{status='Succeeded';changes=($whatIfFixture.changes+@($generated))}; Check $true
        foreach ($mutation in @({param($value) $value.after.properties=@{enabled=$true}},{param($value) $value.delta=@(@{path='properties'})},{param($value) $value.resourceId=$value.resourceId.Replace('case-a','unrelated');$value.before.id=$value.resourceId;$value.after.id=$value.resourceId},{param($value) $value.changeType='Modify'})) {
            $bad=Copy-Fixture $generated; & $mutation $bad
            Reject { Assert-FoundationWhatIf $fixture $bindingFixture $baselineFixture @{status='Succeeded';changes=($whatIfFixture.changes+@($bad))} }
            }
    }
    foreach ($id in $bindingFixture.nested.Keys) {
        $child=@{resourceId=$id;changeType='Create';after=@{id=$id;type='Microsoft.Resources/deployments';properties=@{mode='Incremental'}}}
        Assert-FoundationWhatIf $fixture $bindingFixture @{} @{status='Succeeded';changes=($whatIfFixture.changes+@($child))}; Check $true
        $child.after.properties.mode='Complete'; Reject { Assert-FoundationWhatIf $fixture $bindingFixture @{} @{status='Succeeded';changes=($whatIfFixture.changes+@($child))} }
    }
    $fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('foundation-coordinator-test-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($fixtureRoot)
    try {
        $fixture.runDirectory=$fixtureRoot; $fixture.azureConfigDirectory=Join-Path $fixtureRoot 'synthetic-az-config'
        $archive=Join-Path $fixtureRoot 'foundation-validator-submitted/scripts/Invoke-ExpansionFoundation.ps1'
        $null=[IO.Directory]::CreateDirectory((Split-Path $archive)); [IO.File]::WriteAllText($archive,'submitted synthetic validator')
        $sourceHashes=@{'scripts\Invoke-ExpansionFoundation.ps1'=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash;'infra\expansion-foundation.bicep'='unchanged'}
        $updatedHashes=Copy-Fixture $sourceHashes; $updatedHashes['scripts\Invoke-ExpansionFoundation.ps1']='revised'
        $changes=Assert-FoundationValidatorRevision $sourceHashes $updatedHashes $fixtureRoot; Check ($changes.Count -eq 1)
        Reject { Assert-FoundationValidatorRevision $sourceHashes $sourceHashes $fixtureRoot }
        foreach ($mutation in @({param($value) $value['infra\expansion-foundation.bicep']='changed'},{param($value) $value['new']='extra'},{param($value) $value.Remove('infra\expansion-foundation.bicep')})) {
            $bad=Copy-Fixture $updatedHashes; & $mutation $bad
            Reject { Assert-FoundationValidatorRevision $sourceHashes $bad $fixtureRoot }
        }
        [IO.File]::WriteAllText($archive,'corrupted submitted validator')
        Reject { Assert-FoundationValidatorRevision $sourceHashes $updatedHashes $fixtureRoot }
        & {
            $responseFixture=@{value=@()}; $transportCalls=@{count=0}
            function Invoke-LabAz {
                param($State,$Arguments,$Label)
                if ($Arguments[0] -cne 'rest' -or $Arguments[2] -cne 'get' -or $Arguments.Count -ne 7 -or $Arguments[5] -cne '--headers' -or $Arguments[6] -cne 'Accept=application/json' -or $State.subscriptionId -cne $fixture.subscriptionId -or $State.azureConfigDirectory -cne $fixture.azureConfigDirectory -or $State.runDirectory -cne (Join-Path $fixtureRoot 'expansion-foundation-evidence')) { throw 'Offline read transport contract mismatch' }
                $transportCalls.count++; return $responseFixture
            }
            Check (@(Read-FoundationArm $fixture '/synthetic/list' '2022-09-01' -List).Count -eq 0)
            foreach ($bad in @(@{},@{value=$null},@{value=@{}},@{value=@();nextLink='next'},@{value=@();nextLink=$false},@{value=@(@{id='same'},@{id='same'})},@{value=@(@{})})) { $responseFixture=$bad; Reject { Read-FoundationArm $fixture '/synthetic/list' '2022-09-01' -List } }
            $responseFixture=@{id='/synthetic/other'}; Reject { Read-FoundationArm $fixture '/synthetic/exact' '2022-09-01' }
            Check ($transportCalls.count -eq 9)
        }
        $groupFixtures=@($fixture.resourceGroups | ForEach-Object { @{id="$($bindingFixture.subscription)/resourceGroups/$_";name=$_;type='Microsoft.Resources/resourceGroups';location='swedencentral';tags=$newFixture[$bindingFixture.groupB].tags;properties=@{provisioningState='Succeeded'}} })
        $projectFixtures=@(@{id=$bindingFixture.devA})
        $linkFixtures=@(0..3 | ForEach-Object { @{id="$($bindingFixture.ampls)/scopedResources/linked-$_"} })
        Assert-FoundationAbsence $fixture $bindingFixture $groupFixtures $projectFixtures $linkFixtures; Check $true
        Reject { Assert-FoundationAbsence $fixture $bindingFixture @($groupFixtures+$newFixture[$bindingFixture.groupB]) $projectFixtures $linkFixtures }
        Reject { Assert-FoundationAbsence $fixture $bindingFixture $groupFixtures @($projectFixtures+$newFixture[$bindingFixture.projects[0]]) $linkFixtures }
        foreach ($id in $bindingFixture.links) { Reject { Assert-FoundationAbsence $fixture $bindingFixture $groupFixtures $projectFixtures @($linkFixtures+@{id=$id}) } }
        Reject { Assert-FoundationAbsence $fixture $bindingFixture @($groupFixtures[0],$groupFixtures[0],$groupFixtures[2]) $projectFixtures $linkFixtures }
        & {
            $idleFixture=@{}; $rootIds=@(Get-FoundationRootIds $fixture)
            Check ($rootIds.Count -eq 8 -and @($rootIds | Where-Object { $_ -match 'standard-cosmos-network|gateway-policy-update' }).Count -eq 2)
            foreach ($id in $rootIds) { $idleFixture[$id]=@{id=$id;properties=@{provisioningState='Succeeded'}} }
            $idleFixture["$($bindingFixture.subscription)/providers/Microsoft.Resources/deployments"]=@()
            foreach ($group in $fixture.resourceGroups) { $root="$($bindingFixture.subscription)/resourceGroups/$group/providers/Microsoft.Resources/deployments"; $idleFixture[$root]=@(@{id="$root/original";name='original';properties=@{provisioningState='Succeeded'}}) }
            function Read-FoundationArm { param($State,$Id,$Api,[switch]$List) if (-not $idleFixture.ContainsKey($Id)) { throw 'Unexpected offline idle read' }; return $idleFixture[$Id] }
            Confirm-FoundationIdle $fixture $bindingFixture; Check $true
            foreach ($id in $rootIds) { $idleFixture[$id].properties.provisioningState='Running'; Reject { Confirm-FoundationIdle $fixture $bindingFixture }; $idleFixture[$id].properties.provisioningState='Succeeded' }
            $idleFixture["$($bindingFixture.subscription)/providers/Microsoft.Resources/deployments"]=@(@{id=$bindingFixture.root})
            Reject { Confirm-FoundationIdle $fixture $bindingFixture }
            $idleFixture["$($bindingFixture.subscription)/providers/Microsoft.Resources/deployments"]=@()
            $root="$($bindingFixture.groupA)/providers/Microsoft.Resources/deployments"
            $idleFixture[$root][0].properties.provisioningState='Updating'; Reject { Confirm-FoundationIdle $fixture $bindingFixture }; $idleFixture[$root][0].properties.provisioningState='Succeeded'
            $nestedId=@($bindingFixture.nested.Keys | Where-Object { $_.StartsWith($root+'/') })[0]
            $idleFixture[$root]+=@{id=$nestedId;name=$bindingFixture.nested[$nestedId];properties=@{provisioningState='Succeeded'}}
            Reject { Confirm-FoundationIdle $fixture $bindingFixture }
        }
        & {
            $outputFixture=@{stage='foundation-only';completeLab=$false;resourceGroupId=$bindingFixture.groupB;workspaceId=$bindingFixture.workspace;insightsId=$bindingFixture.insights;caseBAccountId=$bindingFixture.accountB;privateEndpointId=$bindingFixture.endpoint;privateDnsZoneGroupId=$bindingFixture.zoneGroup;accountDiagnosticSettingId=$bindingFixture.diagnostic;monitoringLinkIds=$bindingFixture.links;roleAssignmentIds=@($bindingFixture.roles.Keys);limitations=@('Control plane only');projects=@($bindingFixture.projects | ForEach-Object { @{name=($_ -split '/')[-1];resourceId=$_;principalId=$newFixture[$_].identity.principalId} })}
            $newFixture[$bindingFixture.accountB].properties.privateEndpointConnections=@(@{properties=@{privateEndpoint=@{id=$bindingFixture.endpoint};privateLinkServiceConnectionState=@{status='Approved'}}})
            $monitorScope='77777777-7777-4777-8777-777777777777'
            $newFixture[$bindingFixture.workspace].properties.privateLinkScopedResources=@(@{scopeId=$monitorScope;resourceId=$bindingFixture.links[0]})
            $newFixture[$bindingFixture.insights].properties.PrivateLinkScopedResources=@(@{ScopeId=$monitorScope;ResourceId=$bindingFixture.links[1]})
            $resourceFixture=Copy-Fixture $newFixture; $extraRole=$null; $roleQueries=@{count=0}
            function Read-FoundationArm {
                param($State,$Id,$Api,[switch]$List,$Query)
                if ($Id -ieq $bindingFixture.ampls) { return @{id=$Id;properties=@{scopeId=$monitorScope}} }
                if ($List) {
                    if ($Query -cne '&$filter=atScope()') { throw 'Exact scope filter required' }
                    $roleQueries.count++; $scope=$Id.Substring(0,$Id.Length-('/providers/Microsoft.Authorization/roleAssignments').Length)
                    $direct=@(foreach ($roleId in $bindingFixture.roles.Keys) { if ($bindingFixture.roles[$roleId].scope -ieq $scope) { $resourceFixture[$roleId] } })
                    if ($extraRole) { $direct+=@{id="$scope/providers/Microsoft.Authorization/roleAssignments/$extraRole";properties=@{scope=$scope}} }
                    return $direct
                }
                if (-not $resourceFixture.ContainsKey($Id)) { throw 'Unexpected offline post-verification read' }
                return $resourceFixture[$Id]
            }
            Confirm-FoundationOutputs $fixture $bindingFixture $outputFixture; Check ($roleQueries.count -eq 4)
            foreach ($mutation in @({param($value) $value.completeLab=$true},{param($value) $value.caseBAccountId='foreign'},{param($value) $value.projects=$value.projects[0]},{param($value) $value.projects[0].principalId=[guid]::Empty.ToString()},{param($value) $value.roleAssignmentIds=@()})) { $bad=Copy-Fixture $outputFixture; & $mutation $bad; Reject { Confirm-FoundationOutputs $fixture $bindingFixture $bad } }
            $extraRole='66666666-6666-4666-8666-666666666666'; Reject { Confirm-FoundationOutputs $fixture $bindingFixture $outputFixture }; $extraRole=$null
            $resourceFixture[$bindingFixture.endpoint].properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status='Pending'; Reject { Confirm-FoundationOutputs $fixture $bindingFixture $outputFixture }
            $resourceFixture=Copy-Fixture $newFixture; $resourceFixture[$bindingFixture.projects[0]].identity.principalId=[guid]::Empty.ToString(); Reject { Confirm-FoundationOutputs $fixture $bindingFixture $outputFixture }
            foreach ($mutation in @({param($items) $items[$bindingFixture.accountB].properties.privateEndpointConnections[0].properties.privateLinkServiceConnectionState.status='Pending'},{param($items) $items[$bindingFixture.workspace].properties.privateLinkScopedResources=@()},{param($items) $items[$bindingFixture.insights].properties.PrivateLinkScopedResources[0].ScopeId='foreign'},{param($items) $items[$bindingFixture.insights].properties.PrivateLinkScopedResources[0].ResourceId=$bindingFixture.links[0]},{param($items) $items[@($bindingFixture.roles.Keys)[0]].properties.scope=$bindingFixture.accountA})) {
                $resourceFixture=Copy-Fixture $newFixture; & $mutation $resourceFixture
                Reject { Confirm-FoundationOutputs $fixture $bindingFixture $outputFixture }
            }
        }
        & {
            $liveState=Copy-Fixture $fixture; $liveLab=Copy-Fixture $labFixture
            $liveLab.runner="$($bindingFixture.integration)/providers/Microsoft.Compute/virtualMachines/vm-$($bindingFixture.stem)-runner"
            $storageName='stfglsample01abcdef'
            $workspaceGuid='55555555-5555-4555-8555-555555555555'
            $liveState.standard.accountHostId="$($bindingFixture.accountA)/capabilityHosts/$(($bindingFixture.accountA -split '/')[-1])@aml_aiagentservice"
            $liveState.standard.cosmosNetwork.ruleId=(Get-CosmosNetworkNames $liveState).ruleId
            $liveState.standard.cosmosNetwork.review.binding=@{addresses=@('10.76.6.4')}
            $dependencies=@{labId=$liveState.labId;ownershipId=$liveState.ownershipId;stage='dependencies';location='swedencentral';accountId=$bindingFixture.accountA;projectId=$bindingFixture.devA;vnetId=$bindingFixture.vnet;subnetId="$($bindingFixture.vnet)/subnets/snet-case-a-pe";projectEndpoint="https://$(($bindingFixture.accountA -split '/')[-1]).services.ai.azure.com/api/projects/case-a-dev";projectPrincipalId=$liveLab.cases[0].projects[0].principalId;workspaceId=$workspaceGuid;resourceGroups=@{caseA='rg-fgl-sample01-case-a';integration='rg-fgl-sample01-integration'};dnsZoneIds=@{};privateEndpointIds=@()}
            $endpointSpecs=@{}
            foreach ($spec in @(@('storage','blob',$storageName,'Microsoft.Storage/storageAccounts','blob.core.windows.net','blob'),@('search','search','srch-fgl-sample01-standard','Microsoft.Search/searchServices','search.windows.net','searchService'),@('cosmos','cosmos','cosmos-fgl-sample01-standard','Microsoft.DocumentDB/databaseAccounts','documents.azure.com','Sql'))) {
                $serviceEndpoint=if ($spec[0] -ceq 'storage') { "https://$($spec[2]).$($spec[4])/" } elseif ($spec[0] -ceq 'cosmos') { "https://$($spec[2]).$($spec[4]):443/" } else { "https://$($spec[2]).$($spec[4])" }
                $dependencies[$spec[0]]=@{id="$($bindingFixture.groupA)/providers/$($spec[3])/$($spec[2])";name=$spec[2];endpoint=$serviceEndpoint}
                $dependencies.dnsZoneIds[$spec[1]]="$($bindingFixture.integration)/providers/Microsoft.Network/privateDnsZones/privatelink.$($spec[4])"
                $endpointId="$($bindingFixture.groupA)/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-standard-$($spec[1])"
                $dependencies.privateEndpointIds+=$endpointId
                $endpointSpecs[$endpointId]=@{target=$dependencies[$spec[0]].id;group=$spec[5];subnet=$dependencies.subnetId;zones=@($dependencies.dnsZoneIds[$spec[1]])}
            }
            foreach ($target in @(Get-LabPrivateTargets $liveState $liveLab)) {
                $subnetName=if ($target.key -ceq 'gateway') { 'integration' } else { $target.key }
                $endpointSpecs[$target.endpointId]=@{target=$target.resourceId;group=$target.groupId;subnet="$($bindingFixture.vnet)/subnets/snet-$subnetName-pe";zones=$bindingFixture.zones}
            }
            $liveStandard=@{dependencies=$dependencies}
            $liveActivation=@{parameters=@{minimalPrompt=@{value=$true};labId=@{value=$liveState.labId};ownershipId=@{value=$liveState.ownershipId};phase=@{value='activate'};gatewayPrincipalId=@{value='66666666-6666-4666-8666-666666666666'}}}
            $armFixture=@{}; $providerFixture=@{registrationState='Registered'}
            function Existing-Resource([string]$Id,[string]$Type) { return @{id=$Id;name=($Id -split '/')[-1];type=$Type;location='swedencentral';tags=(Copy-Fixture $newFixture[$bindingFixture.groupB].tags);properties=@{provisioningState='Succeeded'}} }
            foreach ($id in @($bindingFixture.accountA,$liveLab.models)) {
                $resource=Copy-Fixture $newFixture[$bindingFixture.accountB]; $resource.id=$id; $resource.name=($id -split '/')[-1]; $resource.properties.customSubDomainName=$resource.name; $resource.properties.networkInjections=@()
                if ($id -ieq $bindingFixture.accountA) { $resource.properties.networkInjections=@(@{scenario='agent';subnetArmId="$($bindingFixture.vnet)/subnets/snet-agent-a";useMicrosoftManagedNetwork=$false}) }
                $armFixture[$id]=$resource
            }
            $resource=Copy-Fixture $newFixture[$bindingFixture.projects[0]]; $resource.id=$bindingFixture.devA; $resource.name='case-a-dev'; $resource.properties.internalId=$workspaceGuid; $armFixture[$resource.id]=$resource
            $gateway=Existing-Resource $liveLab.gateway 'Microsoft.ApiManagement/service'; $gateway.properties.publicNetworkAccess='Disabled'; $gateway.identity=@{type='SystemAssigned';principalId=$liveActivation.parameters.gatewayPrincipalId.value;tenantId=$liveState.tenantId}; $armFixture[$gateway.id]=$gateway
            foreach ($id in $bindingFixture.identities.Keys) { $resource=Existing-Resource $id 'Microsoft.ManagedIdentity/userAssignedIdentities'; $resource.properties+=@{principalId=$bindingFixture.identities[$id].principalId;clientId=$bindingFixture.identities[$id].clientId;tenantId=$liveState.tenantId}; $armFixture[$id]=$resource }
            $subnetSpecs=@(@('agent-a','10.76.1.0/24','agent-0'),@('agent-b','10.76.2.0/24','agent-1'),@('apim','10.76.3.0/26','apim'),@('runner','10.76.4.0/27','runner'),@('models-pe','10.76.5.0/27','endpoints'),@('case-a-pe','10.76.6.0/27','endpoints'),@('case-b-pe','10.76.7.0/27','endpoints'),@('integration-pe','10.76.8.0/27','endpoints'))
            foreach ($spec in $subnetSpecs) {
                $id="$($bindingFixture.vnet)/subnets/snet-$($spec[0])"; $resource=Existing-Resource $id 'Microsoft.Network/virtualNetworks/subnets'
                $resource.properties+=@{addressPrefix=$spec[1];networkSecurityGroup=@{id="$($bindingFixture.integration)/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-sample01-$($spec[2])"};delegations=@();ipConfigurations=@();serviceAssociationLinks=@();privateEndpointNetworkPolicies='NetworkSecurityGroupEnabled'}
                if ($spec[0] -like 'agent-*') { $resource.properties.delegations=@(@{properties=@{serviceName='Microsoft.App/environments'}}) }
                $armFixture[$id]=$resource
            }
            $vnet=Existing-Resource $bindingFixture.vnet 'Microsoft.Network/virtualNetworks'; $vnet.properties.subnets=@($subnetSpecs | ForEach-Object { $armFixture["$($bindingFixture.vnet)/subnets/snet-$($_[0])"] }); $armFixture[$vnet.id]=$vnet
            foreach ($name in @('agent-0','agent-1','endpoints','apim','runner')) { $id="$($bindingFixture.integration)/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-sample01-$name"; $resource=Existing-Resource $id 'Microsoft.Network/networkSecurityGroups'; $resource.properties.securityRules=@(); $resource.properties.defaultSecurityRules=@(); $armFixture[$id]=$resource }
            $ampls=Existing-Resource $bindingFixture.ampls 'Microsoft.Insights/privateLinkScopes'; $ampls.properties.accessModeSettings=@{ingestionAccessMode='PrivateOnly';queryAccessMode='PrivateOnly';exclusions=@()}; $armFixture[$ampls.id]=$ampls
            foreach ($zone in @($bindingFixture.zones)+@($dependencies.dnsZoneIds.Values)) {
                $armFixture[$zone]=Existing-Resource $zone 'Microsoft.Network/privateDnsZones'
                $link=Existing-Resource "$zone/virtualNetworkLinks/lab-only" 'Microsoft.Network/privateDnsZones/virtualNetworkLinks'; $link.properties+=@{virtualNetwork=@{id=$bindingFixture.vnet};registrationEnabled=$false}; $armFixture[$link.id]=$link
            }
            foreach ($id in $endpointSpecs.Keys) {
                $spec=$endpointSpecs[$id]; $endpoint=Existing-Resource $id 'Microsoft.Network/privateEndpoints'; $endpoint.properties+=@{subnet=@{id=$spec.subnet};privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$spec.target;groupIds=@($spec.group);privateLinkServiceConnectionState=@{status='Approved'}}})}; $armFixture[$id]=$endpoint
                $zoneGroup=Existing-Resource "$id/privateDnsZoneGroups/default" 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'; $zoneGroup.properties.privateDnsZoneConfigs=@($spec.zones | ForEach-Object { @{properties=@{privateDnsZoneId=$_}} }); $armFixture[$zoneGroup.id]=$zoneGroup
            }
            foreach ($spec in @(@('storage','Microsoft.Storage/storageAccounts'),@('search','Microsoft.Search/searchServices'),@('cosmos','Microsoft.DocumentDB/databaseAccounts'))) { $resource=Existing-Resource $dependencies[$spec[0]].id $spec[1]; $resource.properties+=@{publicNetworkAccess='Disabled';disableLocalAuth=$true;allowSharedKeyAccess=$false}; $armFixture[$resource.id]=$resource }
            $monitorLinks=@()
            foreach ($index in 0..3) {
                $suffix=if ($index -lt 2) { 'integration' } else { 'case-a' }; $group="$($bindingFixture.subscription)/resourceGroups/rg-fgl-sample01-$suffix"
                if ($index % 2 -eq 0) { $resource=Existing-Resource "$group/providers/Microsoft.OperationalInsights/workspaces/log-fgl-sample01-$suffix" 'Microsoft.OperationalInsights/workspaces' } else { $resource=Existing-Resource "$group/providers/Microsoft.Insights/components/appi-fgl-sample01-$suffix" 'Microsoft.Insights/components' }
                $resource.properties+=@{publicNetworkAccessForIngestion='Disabled';publicNetworkAccessForQuery='Disabled'}; $armFixture[$resource.id]=$resource
                $link=Existing-Resource "$($bindingFixture.ampls)/scopedResources/linked-$index" 'Microsoft.Insights/privateLinkScopes/scopedResources'; $link.properties.linkedResourceId=$resource.id; $monitorLinks+=$link
            }
            $accountHost=Existing-Resource $liveState.standard.accountHostId 'Microsoft.CognitiveServices/accounts/capabilityHosts'; $accountHost.properties+=@{capabilityHostKind='Agents';customerSubnet="$($bindingFixture.vnet)/subnets/snet-agent-a"}
            $projectHost=Existing-Resource "$($bindingFixture.devA)/capabilityHosts/agents" 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts'; $projectHost.properties+=@{capabilityHostKind='Agents';storageConnections=@($storageName);vectorStoreConnections=@('srch-fgl-sample01-standard');threadStorageConnections=@('cosmos-fgl-sample01-standard')}
            $policyBindings=@{tenantId=$liveState.tenantId;parameters=@{modelAccountName=@{value=($liveLab.models -split '/')[-1]};allowedPrincipalIds=@{value=@($liveLab.cases[0].projects[0].principalId,$liveLab.identities[5].principalId)}}}
            $policy=Existing-Resource "$($liveLab.gateway)/apis/lab-inference/policies/policy" 'Microsoft.ApiManagement/service/apis/policies'; $policy.properties=@{format='rawxml';value=(Get-GatewayPolicyPair (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../infra/policies/inference.xml') -Raw) $policyBindings).after}; $armFixture[$policy.id]=$policy
            $rule=Existing-Resource $liveState.standard.cosmosNetwork.ruleId 'Microsoft.Network/networkSecurityGroups/securityRules'; $rule.properties+=(Get-CosmosNetworkRuleProperties @('10.76.6.4')); $armFixture[$rule.id]=$rule
            $armFixture["$($bindingFixture.subscription)/resourceGroups"]=@{value=$groupFixtures}
            $armFixture["$($bindingFixture.accountA)/projects"]=@{value=@($armFixture[$bindingFixture.devA])}
            $armFixture["$($bindingFixture.ampls)/scopedResources"]=@{value=$monitorLinks}
            $armFixture["$($bindingFixture.accountA)/capabilityHosts"]=@{value=@($accountHost)}
            $armFixture["$($bindingFixture.devA)/capabilityHosts"]=@{value=@($projectHost)}
            $armFixture["$($bindingFixture.subscription)/providers/Microsoft.CognitiveServices/accounts"]=@{value=@($armFixture[$bindingFixture.accountA],$armFixture[$liveLab.models])}
            $activationId="$($bindingFixture.subscription)/providers/Microsoft.Resources/deployments/fgl-sample01-activate"
            $armFixture[$activationId]=@{id=$activationId;properties=@{mode='Incremental';provisioningState='Succeeded';parameters=$liveActivation.parameters;outputs=@{lab=@{value=$liveLab}}}}
            $liveCalls=@{count=0}
            function Invoke-LabAz {
                param($State,$Arguments,$Label)
                $liveCalls.count++
                if (($Arguments -join ' ') -ceq 'account show') { return @{id=$State.subscriptionId;tenantId=$State.tenantId;state='Enabled'} }
                if (($Arguments[0..1] -join ' ') -ceq 'provider show') { return @{namespace=$Arguments[3];registrationState=$providerFixture.registrationState} }
                if ($Arguments[0] -cne 'rest' -or $Arguments[2] -cne 'get') { throw 'Full live fixture forbids any mutation' }
                $id=([uri]$Arguments[4]).AbsolutePath
                if (-not $armFixture.ContainsKey($id)) { throw 'Unexpected fixture ARM read' }
                return $armFixture[$id]
            }
            $liveBaseline=Get-FoundationLive $liveState $liveLab $liveStandard $liveActivation $bindingFixture
            Check ($liveBaseline.Count -gt 40 -and $liveCalls.count -gt 50)
            foreach ($status in @('Registering','NotRegistered',$true)) { $providerFixture.registrationState=$status; Reject { Get-FoundationLive $liveState $liveLab $liveStandard $liveActivation $bindingFixture } }
            $providerFixture.registrationState='Registered'
            foreach ($mutation in @(
                {param($map) $map[$bindingFixture.agentSubnet].properties.delegations[0].properties.serviceName='Microsoft.Web/serverFarms'},
                {param($map) $map[$bindingFixture.agentSubnet].properties.serviceAssociationLinks=@(@{id='occupied'})},
                {param($map) $map[$bindingFixture.agentSubnet].properties.ipConfigurations=@(@{id='occupied'})},
                {param($map) $map[$bindingFixture.peSubnet].properties.addressPrefix='10.76.6.0/27'},
                {param($map) $map[$bindingFixture.ampls].properties.accessModeSettings.queryAccessMode='Open'},
                {param($map) $map[$bindingFixture.ampls].tags['fgl-owner']='foreign'},
                {param($map) $map[$bindingFixture.zones[0]].tags['fgl-lab']='foreign'},
                {param($map) $map[$bindingFixture.developerId].properties.principalId=[guid]::Empty.ToString()},
                {param($map) $map[$bindingFixture.accountA].properties.publicNetworkAccess='Enabled'},
                {param($map) $map[$bindingFixture.devA].identity.principalId=[guid]::Empty.ToString()},
                {param($map) $map["$($bindingFixture.devA)/capabilityHosts"].value[0].properties.storageConnections=@('foreign')},
                {param($map) $map["$($bindingFixture.subscription)/providers/Microsoft.CognitiveServices/accounts"].value+=@{id='occupied';properties=@{networkInjections=@(@{subnetArmId=$bindingFixture.agentSubnet})}}},
                {param($map) $map["$($bindingFixture.accountA)/projects"].nextLink='more'}
            )) {
                $originalMap=$armFixture; $armFixture=Copy-Fixture $originalMap; & $mutation $armFixture
                Reject { Get-FoundationLive $liveState $liveLab $liveStandard $liveActivation $bindingFixture }
                $armFixture=$originalMap
            }
            $originalMap=$armFixture; $armFixture=Copy-Fixture $originalMap
            $armFixture[$liveLab.models].identity.principalId='66666666-6666-4666-8666-666666666666'
            Reject { Assert-FoundationEqual (Get-FoundationLive $liveState $liveLab $liveStandard $liveActivation $bindingFixture) $liveBaseline }
            $armFixture=$originalMap
            $armFixture["$($bindingFixture.subscription)/resourceGroups"].value+= $newFixture[$bindingFixture.groupB]
            $armFixture["$($bindingFixture.accountA)/projects"].value+= $newFixture[$bindingFixture.projects[0]]
            $armFixture["$($bindingFixture.ampls)/scopedResources"].value+= @($newFixture[$bindingFixture.links[0]],$newFixture[$bindingFixture.links[1]])
            $armFixture["$($bindingFixture.subscription)/providers/Microsoft.CognitiveServices/accounts"].value+=$newFixture[$bindingFixture.accountB]
            Assert-FoundationEqual (Get-FoundationLive $liveState $liveLab $liveStandard $liveActivation $bindingFixture -After) $liveBaseline; Check $true
        }
        & {
            $lifecycle=Join-Path $fixtureRoot 'lifecycle'; $null=[IO.Directory]::CreateDirectory($lifecycle)
            $originalFixture=Copy-Fixture $fixture; $originalFixture.runDirectory=$lifecycle; $originalFixture.azureConfigDirectory=Join-Path $lifecycle 'synthetic-config'
            $stateFile=Join-Path $lifecycle 'state.json'
            Write-StandardJson (Join-Path $lifecycle 'outputs.json') $labFixture
            Write-StandardJson (Join-Path $lifecycle 'standard-outputs.json') @{}
            Write-StandardJson (Join-Path $lifecycle 'activate.parameters.json') @{}
            foreach ($spec in @(@('cosmosNetwork','standard-cosmos-network.evidence.json'),@('gatewayPolicy','gateway-policy-update.evidence.json'))) {
                $evidencePath=Join-Path $lifecycle $spec[1]; Write-StandardJson $evidencePath @{synthetic=$true}
                $originalFixture.standard[$spec[0]].evidence=@{path=$evidencePath;sha256=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash}
            }
            Write-StandardJson $stateFile $originalFixture
            $originalDigest=(Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash
            $simulation=@{calls=[Collections.Generic.List[string]]::new();submitted=0;live=0;idle=0;failSubmit=$false;status='Running';changeBaseline=$false;collision=$false;idleBlocked=$false;postFails=$false;whatif=$whatIfFixture;mutateDuringWhatIf=''}
            $lifecycleBinding=Copy-Fixture $bindingFixture
            function Get-FoundationBinding { return $lifecycleBinding }
            function Get-FoundationLive {
                param($State,$Lab,$Standard,$Activation,$Binding,[switch]$After)
                $simulation.live++
                if ($simulation.collision -and -not $After) { throw 'Synthetic target collision' }
                $configuration=@{protected=@{setting='private';principal='retained'}}
                if ($simulation.changeBaseline) { $configuration.protected.setting='changed' }
                return $configuration
            }
            function Confirm-FoundationIdle { param($State,$Binding,[switch]$Submitted) $simulation.idle++; if ($simulation.idleBlocked) { throw 'Synthetic active root' } }
            function Confirm-FoundationOutputs { if ($simulation.postFails) { throw 'Synthetic post-verification failure' } }
            function Invoke-LabAz {
                param($State,$Arguments,$Label)
                if ($State.subscriptionId -cne $originalFixture.subscriptionId -or $State.azureConfigDirectory -cne $originalFixture.azureConfigDirectory -or $State.runDirectory -cne (Join-Path $lifecycle 'expansion-foundation-evidence')) { throw 'Unisolated synthetic transport' }
                $simulation.calls.Add(($Arguments -join ' '))
                if (($Arguments[0..2] -join ' ') -ceq 'deployment sub what-if') {
                    if ('--result-format' -cnotin $Arguments -or 'FullResourcePayloads' -cnotin $Arguments) { throw 'Expanded what-if required' }
                    if ($simulation.mutateDuringWhatIf) { [IO.File]::AppendAllText($pathsFixture[$simulation.mutateDuringWhatIf],' ') }
                    return $simulation.whatif
                }
                if (($Arguments[0..2] -join ' ') -ceq 'deployment sub create') {
                    $pending=Read-FoundationJson (Join-Path $lifecycle 'expansion-foundation.state.json')
                    if (-not $pending.pending -or $pending.verified -or $pending.deploymentId -cne $bindingFixture.root -or '--no-wait' -cnotin $Arguments -or $Arguments[4] -cne $bindingFixture.name) { throw 'Pending intent must precede the one exact asynchronous mutation' }
                    $simulation.submitted++
                    if ($simulation.failSubmit) { throw 'Synthetic transport failed after submit' }
                    return
                }
                if (($Arguments -join ' ') -ceq 'account show') { return @{id=$originalFixture.subscriptionId;tenantId=$originalFixture.tenantId;state='Enabled'} }
                if ($Arguments[0] -ceq 'rest' -and $Arguments[2] -ceq 'get') {
                    $uri=[uri]$Arguments[4]
                    if ($uri.AbsolutePath -ceq $bindingFixture.root) { return @{id=$bindingFixture.root;properties=@{mode='Incremental';provisioningState=$simulation.status;parameters=$bindingFixture.parameters;outputs=@{foundation=@{value=@{synthetic=$true}}}}} }
                    if ($uri.AbsolutePath -ceq "$($bindingFixture.root)/operations") { return @{value=@()} }
                }
                throw 'Unexpected offline lifecycle transport operation'
            }
            Reject { Invoke-ExpansionFoundation $stateFile 'Preview' $compiler $false }
            Check ($simulation.calls.Count -eq 0)
            $null=Invoke-ExpansionFoundation $stateFile 'Preview' $compiler $true
            $pathsFixture=Get-FoundationPaths $originalFixture; $reviewed=Read-FoundationJson $pathsFixture.state
            Check (-not $reviewed.pending -and -not $reviewed.verified -and $reviewed.review.authorization.approved -eq $true -and $simulation.live -eq 2 -and $simulation.idle -eq 2)
            foreach ($offset in @(-61,5)) {
                $altered=Copy-Fixture $reviewed; $altered.review.checkedAt=[DateTimeOffset]::UtcNow.AddMinutes($offset).ToString('o'); Write-StandardJson $pathsFixture.state $altered
                Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }; Check ($simulation.submitted -eq 0)
            }
            Write-StandardJson $pathsFixture.state $reviewed
            Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $false }; Check ($simulation.submitted -eq 0)
            foreach ($key in @('template','parameters','whatif')) {
                $previous=[IO.File]::ReadAllBytes($pathsFixture[$key]); [IO.File]::AppendAllText($pathsFixture[$key],' ')
                Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }; Check ($simulation.submitted -eq 0)
                [IO.File]::WriteAllBytes($pathsFixture[$key],$previous)
            }
            foreach ($key in @('template','parameters')) {
                $previous=[IO.File]::ReadAllBytes($pathsFixture[$key]); $simulation.mutateDuringWhatIf=$key
                try {
                    Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }
                    Check ($simulation.submitted -eq 0 -and -not (Read-FoundationJson $pathsFixture.state).pending)
                    $failure=Read-FoundationJson (Join-Path $lifecycle 'expansion-foundation.failure.json')
                    Check ($failure.message -ceq 'Foundation artifact changed during what-if')
                } finally { $simulation.mutateDuringWhatIf=''; [IO.File]::WriteAllBytes($pathsFixture[$key],$previous) }
            }
            $altered=Copy-Fixture $reviewed; $sourceKey=@($altered.review.sourceHashes.Keys)[0]; $altered.review.sourceHashes[$sourceKey]='changed'; Write-StandardJson $pathsFixture.state $altered
            Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }
            Write-StandardJson $pathsFixture.state $reviewed
            foreach ($key in @('collision','idleBlocked','changeBaseline')) {
                $simulation[$key]=$true; Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }; Check ($simulation.submitted -eq 0)
                Reject { Invoke-ExpansionFoundation $stateFile 'Preview' $compiler $true }
                Check ((Get-FoundationHash (Read-FoundationJson $pathsFixture.state).baseline) -ceq (Get-FoundationHash $reviewed.baseline))
                $simulation[$key]=$false
            }
            $simulation.whatif=@{status='Succeeded';changes=@()}; Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }; Check ($simulation.submitted -eq 0); $simulation.whatif=$whatIfFixture
            $simulation.failSubmit=$true; Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }
            $pending=Read-FoundationJson $pathsFixture.state
            Check ($simulation.submitted -eq 1 -and $pending.pending -and -not $pending.verified -and -not (Test-Path -LiteralPath $pathsFixture.outputs))
            Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }
            Reject { Invoke-ExpansionFoundation $stateFile 'Preview' $compiler $true }
            Check ($simulation.submitted -eq 1)
            $null=Invoke-ExpansionFoundation $stateFile 'Status' $compiler $false
            Check ((Read-FoundationJson $pathsFixture.state).pending -and $simulation.submitted -eq 1)
            $simulation.status='Failed'; Reject { Invoke-ExpansionFoundation $stateFile 'Status' $compiler $false }
            Check ((Read-FoundationJson $pathsFixture.state).pending)
            $simulation.status='Succeeded'; $simulation.postFails=$true; Reject { Invoke-ExpansionFoundation $stateFile 'Status' $compiler $false }
            Check ((Read-FoundationJson $pathsFixture.state).pending -and -not (Test-Path -LiteralPath $pathsFixture.outputs))
            $simulation.postFails=$false; $simulation.changeBaseline=$true; Reject { Invoke-ExpansionFoundation $stateFile 'Status' $compiler $false }; $simulation.changeBaseline=$false
            $pending=Read-FoundationJson $pathsFixture.state; $pending.review.checkedAt=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o'); Write-StandardJson $pathsFixture.state $pending
            $null=Invoke-ExpansionFoundation $stateFile 'Status' $compiler $false
            $completed=Read-FoundationJson $pathsFixture.state; $completionOutput=Read-FoundationJson $pathsFixture.outputs
            Check ($completed.verified -and -not $completed.pending -and ($completed.completedStages -join ',') -ceq 'foundation' -and $completionOutput.inferenceVerified -eq $false)
            Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }
            Check ($simulation.submitted -eq 1 -and (Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash -ceq $originalDigest)
            Write-StandardJson $pathsFixture.state $reviewed
            $lockProbe=[IO.File]::Open($pathsFixture.lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try { Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }; Check ($simulation.submitted -eq 1) } finally { $lockProbe.Dispose() }
            $originalChanged=Copy-Fixture $originalFixture; $originalChanged.externalChange=$true; Write-StandardJson $stateFile $originalChanged
            Reject { Invoke-ExpansionFoundation $stateFile 'Deploy' $compiler $true }; Check ($simulation.submitted -eq 1)
            Check (@($simulation.calls | Where-Object { $_ -match '(?i)delete|register|revoke|deployment group create' }).Count -eq 0)
        }
    } finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    Write-Output "Expansion coordinator offline checks passed: $($checks.count)."
} finally { Write-Host "Expansion coordinator tests elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,2))s" }