[CmdletBinding()]
param([string]$BicepExecutable = 'bicep')

$ErrorActionPreference='Stop'
$networkTestCompiler=$BicepExecutable
. (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionCosmosNetwork.ps1') -DefinitionsOnly
$networkChecks=@{count=0}
function Check([bool]$Condition) { if (-not $Condition) { throw 'Network coordinator assertion failed' }; $networkChecks.count++ }
function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed }
function Invoke-LabAz { throw 'Offline tests forbid unmocked Azure transport' }
function Save-LabRun { throw 'Original state must never be written' }

function New-IgnoreInventoryFixture([hashtable]$State, [string]$Scope) {
    $tags=@{'fgl-lab'=$State.labId;'fgl-owner'=$State.ownershipId;purpose='synthetic-governance-lab'}
    $group=($Scope -split '/')[4]; $runner="$Scope/providers/Microsoft.Compute/virtualMachines/vm-fgl-$($State.labId)-runner"
    $identities=@{}
    foreach ($actor in @('client','consumer-a','denied','dev-a','dev-b','publisher-a','publisher-b')) { $identities["$Scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-$($State.labId)-$actor"]=@{} }
    return @(
        @{id="$Scope/providers/Microsoft.ApiManagement/service/apim-fgl-$($State.labId)-abcdefghijklm";identity=@{type='SystemAssigned'};location='swedencentral';name="apim-fgl-$($State.labId)-abcdefghijklm";resourceGroup=$group;sku=@{capacity=1;name='StandardV2'};tags=$tags;type='Microsoft.ApiManagement/service'},
        @{id="$($Scope.Replace($group,$group.ToUpperInvariant()))/providers/Microsoft.Compute/disks/vm-fgl-$($State.labId)-runner-disk-os-01";location='swedencentral';managedBy=$runner;name="vm-fgl-$($State.labId)-runner-disk-os-01";resourceGroup=$group.ToUpperInvariant();sku=@{name='StandardSSD_LRS';tier='Standard'};tags=$tags;type='Microsoft.Compute/disks'},
        @{id=$runner;identity=@{type='UserAssigned';userAssignedIdentities=$identities};location='swedencentral';name="vm-fgl-$($State.labId)-runner";resourceGroup=$group;tags=$tags;type='Microsoft.Compute/virtualMachines'},
        @{id="$($runner.Replace($group,$group.ToUpperInvariant()))/extensions/MDE.Linux";location='swedencentral';name="vm-fgl-$($State.labId)-runner/MDE.Linux";resourceGroup=$group.ToUpperInvariant();type='Microsoft.Compute/virtualMachines/extensions'}
    )
}

$dependencies=@{}
foreach ($selection in @('a-test','b-dev','b-test')) { $dependencies[$selection]=@{stage='dependencies';project=$selection;pending=$false;verified=$true} }
foreach ($selection in @('a-test','b-dev','b-test')) {
    $state=@{labId='sample01';subscriptionId='11111111-1111-4111-8111-111111111111';ownershipId='33333333-3333-4333-8333-333333333333'}
    $scope="/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01-integration"
    $binding=$state.Clone(); $binding.selector=$selection; $binding.names=Get-ExpansionCosmosNetworkNames $state $selection $scope
    $binding.addresses=if ($selection -ceq 'a-test') { @('10.76.6.12','10.76.6.13') } else { @('10.76.7.8','10.76.7.9') }
    $source=New-ExpansionNetworkBicep $binding
    Check ($source.Contains("resource cosmosDirect 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01'"))
    Check ($source.Contains("priority: $($binding.names.priority)"))
    $template=New-ExpansionCosmosNetworkTemplate $binding $scope
    Reject { Assert-ExpansionNetworkCompiled $template $binding }
    $template.metadata=@{_generator=@{name='bicep';version='synthetic';templateHash='synthetic'}}
    Assert-ExpansionNetworkCompiled $template $binding; Check $true
    $bad=Read-ExpansionStandardCopy $template; $bad.resources[0].properties.priority=125
    Reject { Assert-ExpansionNetworkCompiled $bad $binding }
    $rule=@{id=$binding.names.ruleId;name=$binding.names.ruleName;type='Microsoft.Network/networkSecurityGroups/securityRules';properties=(Get-ExpansionCosmosNetworkRuleProperties $selection $binding.addresses)}
    $whatif=@{status='Succeeded';changes=@(@{resourceId=$rule.id;changeType='Create';after=$rule})}
    Assert-ExpansionNetworkWhatIf $binding @{} $whatif; Check $true
    foreach ($kind in @('Modify','Delete','Ignore','NoChange','Deploy','Unsupported')) {
        $bad=Read-ExpansionStandardCopy $whatif; $bad.changes[0].changeType=$kind
        Reject { Assert-ExpansionNetworkWhatIf $binding @{} $bad }
    }
    $known=@{}; $known[$binding.names.nsgId]=@{id=$binding.names.nsgId;type='Microsoft.Network/networkSecurityGroups';properties=@{untouched=$true}}
    $ignored=Read-ExpansionStandardCopy $whatif
    $ignored.changes+=@{resourceId=$binding.names.nsgId;changeType='Ignore';before=$known[$binding.names.nsgId];after=$known[$binding.names.nsgId]}
    Assert-ExpansionNetworkWhatIf $binding $known $ignored; Check $true
    Reject { Assert-ExpansionNetworkWhatIf $binding @{} $ignored }
    $bad=Read-ExpansionStandardCopy $ignored; $bad.changes[1].after.properties.untouched=$false
    Reject { Assert-ExpansionNetworkWhatIf $binding $known $bad }
    foreach ($sparse in @(New-IgnoreInventoryFixture $state $scope)) {
        $full=Read-ExpansionStandardCopy $sparse
        $full.Remove('resourceGroup'); $full.properties=@{protectedSetting='unchanged'}
        if ($full.identity) {
            $full.identity.tenantId='22222222-2222-4222-8222-222222222222'
            if ($full.identity.type -ceq 'SystemAssigned') { $full.identity.principalId='44444444-4444-4444-8444-444444444444' }
            else { foreach ($identityId in @($full.identity.userAssignedIdentities.Keys)) { $full.identity.userAssignedIdentities[$identityId]=@{principalId='44444444-4444-4444-8444-444444444444';clientId='55555555-5555-4555-8555-555555555555'} } }
        }
        $known[$full.id]=$full
        $captured=Read-ExpansionStandardCopy $whatif
        $captured.changes+=@{resourceId=$sparse.id;changeType='Ignore';before=$sparse;after=$sparse;delta=$null;deploymentId=$null;extension=$null;identifiers=$null;symbolicName=$null;unsupportedReason=$null}
        Assert-ExpansionNetworkWhatIf $binding $known $captured; Check $true
        foreach ($mutation in @(
            {param($value) $value.changes[1].after.location='foreign'},
            {param($value) $value.changes[1].before.location='foreign'; $value.changes[1].after.location='foreign'},
            {param($value) $value.changes[1].before.type='Microsoft.Unknown/resources'; $value.changes[1].after.type='Microsoft.Unknown/resources'},
            {param($value) $value.changes[1].before.id+='-foreign'; $value.changes[1].after.id+='-foreign'},
            {param($value) $value.changes[1].resourceId+='-foreign'; $value.changes[1].before.id=$value.changes[1].resourceId; $value.changes[1].after.id=$value.changes[1].resourceId},
            {param($value) $value.changes[1].resourceId=$value.changes[1].resourceId.Replace('/resourceGroups/','/resourceGroups/foreign-'); $value.changes[1].before.id=$value.changes[1].resourceId; $value.changes[1].after.id=$value.changes[1].resourceId},
            {param($value) $value.changes[1].before.resourceGroup='foreign'; $value.changes[1].after.resourceGroup='foreign'},
            {param($value) $value.changes[1].before.tags=@{'fgl-owner'='foreign'}; $value.changes[1].after.tags=@{'fgl-owner'='foreign'}},
            {param($value) $value.changes[1].before.properties=@{protectedSetting='changed'}; $value.changes[1].after.properties=@{protectedSetting='changed'}},
            {param($value) $value.changes[1].before.Remove('id'); $value.changes[1].after.Remove('id')},
            {param($value) $value.changes[1].before.Remove('type'); $value.changes[1].after.Remove('type')},
            {param($value) $value.changes[1].before=@{}; $value.changes[1].after=@{}; $value.changes[1].resourceId=''},
            {param($value) $value.changes[1].after=$null},
            {param($value) $value.changes[1].before=$null},
            {param($value) $value.changes[1].delta=@(@{propertyChangeType='Modify';path='properties'})},
            {param($value) $value.changes[1].diff=@(@{path='properties'})},
            {param($value) $value.changes[1].changeType='Create'; $value.changes[1].before=$null},
            {param($value) $value.changes[1].changeType='Modify'},
            {param($value) $value.changes+=$value.changes[0]},
            {param($value) $value.changes=@($value.changes[1])}
        )) { $bad=Read-ExpansionStandardCopy $captured; & $mutation $bad; Reject { Assert-ExpansionNetworkWhatIf $binding $known $bad } }
    }
    Assert-ExpansionNetworkTransition $null @{} $dependencies $selection 'Preview' $true; Check $true
    foreach ($other in $dependencies.Keys) {
        $bad=Read-ExpansionStandardCopy $dependencies; $bad[$other].pending=$true
        Reject { Assert-ExpansionNetworkTransition $null @{} $bad $selection 'Preview' $true }
    }
    Reject { Assert-ExpansionNetworkTransition $null @{} $dependencies $selection 'Deploy' $true }
    Reject { Assert-ExpansionNetworkTransition $null @{} $dependencies $selection 'Status' $true }
    Reject { Assert-ExpansionNetworkTransition $null @{} $dependencies $selection 'Preview' $false }
    $intent=@{stage='cosmos-network';project=$selection;pending=$true;verified=$false}
    Assert-ExpansionNetworkTransition $intent @{$selection=$intent} $dependencies $selection 'Status' $false; Check $true
    Reject { Assert-ExpansionNetworkTransition $intent @{$selection=$intent} $dependencies $selection 'Deploy' $true }
    $other=@('a-test','b-dev','b-test' | Where-Object { $_ -cne $selection })[0]
    Reject { Assert-ExpansionNetworkTransition $null @{$selection=$intent} $dependencies $other 'Preview' $true }
}
$fixtureTokens=$null; $fixtureErrors=$null
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-ExpansionCosmosNetwork.ps1'),[ref]$fixtureTokens,[ref]$fixtureErrors)
Check ($fixtureErrors.Count -eq 0)
$fixtureFunctions=@($fixtureAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -cin @('New-FixtureRule','New-NetworkFixture')},$true))
Check ($fixtureFunctions.Count -eq 2)
foreach ($definition in $fixtureFunctions) { . ([scriptblock]::Create($definition.Extent.Text)) }
function Clone($Value) { return Read-ExpansionStandardCopy $Value }

foreach ($workflowSelector in @('a-test','b-dev','b-test')) {
    & {
        $fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('expansion-network-test-'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($fixtureRoot)
        try {
            $workflowPath=Join-Path $fixtureRoot 'original.json'
            $workflowState=@{labId='sample01';subscriptionId='11111111-1111-4111-8111-111111111111';tenantId='22222222-2222-4222-8222-222222222222';ownershipId='33333333-3333-4333-8333-333333333333';runDirectory=$fixtureRoot;azureConfigDirectory=(Join-Path $fixtureRoot 'unused-cache');minimalPrompt=$true;privateAccessVerified=$true;deploymentAuthorized=$true;phase='activate';pendingPhase=$null;preexistingGroupIds=@();resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" });standard=@{completedStages=@('dependencies','account','project','access');pendingStage=$null;deploymentNames=@{}}}
            foreach ($stage in @('dependencies','project','access')) { $workflowState.standard.deploymentNames[$stage]="fgl-sample01-standard-$stage" }
            foreach ($pair in @(@('cosmosNetwork','standard-cosmos-network'),@('gatewayPolicy','gateway-policy-update'))) {
                $evidencePath=Join-Path $fixtureRoot "$($pair[1]).evidence.json"
                Write-StandardJson $evidencePath @{synthetic=$true}
                $workflowState.standard[$pair[0]]=@{name="fgl-sample01-$($pair[1])";group='rg-fgl-sample01-integration';pending=$false;verified=$true;review=@{};evidence=@{path=$evidencePath;sha256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash}}
            }
            Write-StandardJson $workflowPath $workflowState
            $workflowOriginalHash=(Get-FileHash $workflowPath -Algorithm SHA256).Hash
            $prefix="/subscriptions/$($workflowState.subscriptionId)"
            $integration="$prefix/resourceGroups/rg-fgl-sample01-integration"
            $workflowFoundation=@{subscription=$prefix;stem='fgl-sample01';integration=$integration;vnet="$integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01";root="$prefix/providers/Microsoft.Resources/deployments/fgl-sample01-expansion-foundation";groupA="$prefix/resourceGroups/rg-fgl-sample01-case-a";groupB="$prefix/resourceGroups/rg-fgl-sample01-case-b";accountA="$prefix/resourceGroups/rg-fgl-sample01-case-a/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-a-abcdefghijklm";accountB="$prefix/resourceGroups/rg-fgl-sample01-case-b/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-b-abcdefghijklm";projects=@()}
            $workflowLab=@{runner="$integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner"}
            Write-StandardJson (Join-Path $fixtureRoot 'outputs.json') $workflowLab
            foreach ($fileName in @('standard-outputs.json','activate.parameters.json')) { Write-StandardJson (Join-Path $fixtureRoot $fileName) @{synthetic=$true} }
            $workflowInputs=Get-FoundationInputHashes $workflowState $workflowPath
            $workflowFixtures=@{}; $workflowBaseline=@{}; $workflowResources=@{}; $workflowProjects=@()
            foreach ($selection in @('a-test','b-dev','b-test')) {
                $fixture=New-NetworkFixture $selection
                $fixture.resources.nsg.properties.securityRules=@($fixture.resources.nsg.properties.securityRules | Where-Object { $_.name -notlike 'allow-exp-*' })
                $workflowFixtures[$selection]=$fixture
                $workflowFoundation.projects+=$fixture.output.standard.projectId
                $workflowProjects+=@{resourceId=$fixture.output.standard.projectId;principalId=$fixture.output.standard.projectPrincipalId}
                foreach ($resource in $fixture.resources.Values) { $workflowResources[$resource.id]=$resource }
                foreach ($resource in @($fixture.resources.nsg,$fixture.resources.agentNsg)) { $workflowBaseline[$resource.id]=Select-FoundationConfiguration $resource }
                $workflowResources[$fixture.output.standard.projectId]=@{id=$fixture.output.standard.projectId;tags=$fixture.resources.nsg.tags;identity=@{principalId=$fixture.output.standard.projectPrincipalId;tenantId=$workflowState.tenantId};properties=@{provisioningState='Succeeded'}}
            }
            $workflowResources[$workflowFoundation.vnet].properties.subnets=@($workflowResources.Values | Where-Object type -CEQ 'Microsoft.Network/virtualNetworks/subnets')
            $workflowInventory=@{}
            foreach ($resource in @(New-IgnoreInventoryFixture $workflowState $integration)) { $workflowInventory[$resource.id]=$resource }
            $workflowBaseline['protected-original-agent-version']=@{version='unchanged';agent='synthetic'}
            $workflowBaseline['protected-original-policy']=@{policy='unchanged'}
            $foundationOutput=@{foundation=@{stage='foundation-only';completeLab=$false;caseBAccountId=$workflowFoundation.accountB;resourceGroupId=$workflowFoundation.groupB;projects=$workflowProjects};baselineHash=(Get-FoundationHash $workflowBaseline);originalSha=$workflowOriginalHash;controlPlaneVerified=$true;inferenceVerified=$false;environmentEvents=@();validationSourceHashes=@{synthetic='historical'};validatorRevision=@{};verifiedAt=[DateTimeOffset]::UtcNow.AddMinutes(-20).ToString('o')}
            $foundationPaths=Get-FoundationPaths $workflowState
            Write-StandardJson $foundationPaths.outputs $foundationOutput
            $foundationOutputHash=(Get-FileHash $foundationPaths.outputs -Algorithm SHA256).Hash
            $foundationManifest=@{pending=$false;verified=$true;completedStages=@('foundation');originalSha=$workflowOriginalHash;outputHash=$foundationOutputHash;scopeHash=(Get-FoundationHash $workflowFoundation);deploymentId=$workflowFoundation.root;baseline=$workflowBaseline;review=@{inputHashes=$workflowInputs;baselineHash=(Get-FoundationHash $workflowBaseline);authorization=@{approved=$true;originalSha=$workflowOriginalHash;scopeHash=(Get-FoundationHash $workflowFoundation)}}}
            Write-StandardJson $foundationPaths.state $foundationManifest
            $dependencySources=@{'synthetic-validator'='current'}
            function Get-ExpansionStandardSources { return $dependencySources.Clone() }
            $privateSources=$dependencySources.Clone()
            foreach ($name in @('Test-ExpansionPrivate.ps1','Invoke-ExpansionWatchdog.ps1')) { $privateSources["scripts/$name"]=(Get-FileHash (Join-Path $PSScriptRoot "../scripts/$name") -Algorithm SHA256).Hash }
            $workflowDeployments=@{}; $workflowOperations=@{}
            foreach ($root in @(Get-FoundationRootIds $workflowState)+@($workflowFoundation.root)) {
                $workflowDeployments[$root]=@{id=$root;name=($root -split '/')[-1];properties=@{provisioningState='Succeeded';mode='Incremental'}}
                $workflowOperations[$root]=@()
            }
            $workflowPrivatePaths=@{}
            foreach ($selection in @('a-test','b-dev','b-test')) {
                $fixture=$workflowFixtures[$selection]; $standard=$fixture.output.standard
                $standard.dnsZoneIds=@{}
                foreach ($pair in @(@('storage','blob','blob.core.windows.net'),@('search','search','search.windows.net'),@('cosmos','cosmos','documents.azure.com'))) {
                    if ($pair[0] -cne 'cosmos') { $standard[$pair[0]]=@{id="$($standard.resourceGroupId)/providers/synthetic/$($pair[0])";name="synthetic-$selection-$($pair[0])"} }
                    $standard.dnsZoneIds[$pair[1]]="$integration/providers/Microsoft.Network/privateDnsZones/privatelink.$($pair[2])"
                }
                $dependencyOutput=Clone $fixture.output
                $dependencyOutput.originalSha=$workflowOriginalHash; $dependencyOutput.foundationOutputHash=$foundationOutputHash; $dependencyOutput.validationSourceHashes=$dependencySources; $dependencyOutput.verifiedAt=[DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o'); $dependencyOutput.environmentEvents=@()
                $dependencyPaths=Get-ExpansionStandardPaths $workflowState $selection
                Write-StandardJson $dependencyPaths.outputs $dependencyOutput
                $root="$prefix/providers/Microsoft.Resources/deployments/fgl-sample01-exp-standard-$selection"
                $dependencyManifest=@{stage='dependencies';project=$selection;pending=$false;verified=$true;deploymentId=$root;originalSha=$workflowOriginalHash;foundationOutputHash=$foundationOutputHash;outputHash=(Get-FileHash $dependencyPaths.outputs -Algorithm SHA256).Hash;baseline=$workflowBaseline;known=(Clone $workflowInventory);idle=@{deployments=@{}};review=@{approved=$true;inputHashes=$workflowInputs;baselineHash=(Get-FoundationHash $workflowBaseline);idleHash=(Get-FoundationHash @{deployments=@{}})}}
                $dependencyManifest.known=@{}
                foreach ($resource in $workflowInventory.Values) { $dependencyManifest.known[$resource.id.ToUpperInvariant()]=Clone $resource }
                Write-StandardJson $dependencyPaths.state $dependencyManifest
                $workflowDeployments[$root]=@{id=$root;name=($root -split '/')[-1];properties=@{mode='Incremental';provisioningState='Succeeded'}}
                $workflowOperations[$root]=@()
                $receiptPath=Join-Path $fixtureRoot "expansion-private-$selection-synthetic/receipt.json"
                $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($receiptPath))
                $receiptInputs=@{}; $receiptInputs[$workflowPath]=$workflowOriginalHash
                foreach ($file in @($dependencyPaths.state,$dependencyPaths.outputs,$foundationPaths.state,$foundationPaths.outputs)) { $receiptInputs[$file]=(Get-FileHash $file -Algorithm SHA256).Hash }
                $network=@{runnerId=$workflowLab.runner;vnetId=$standard.vnetId;subnetId=$standard.subnetId;addressPrefix=$(if ($selection -ceq 'a-test') { '10.76.6.' } else { '10.76.7.' });targets=@()}
                $addresses=@{}; $checks=@()
                foreach ($pair in @(@('storage','blob','blob.core.windows.net','blob'),@('search','search','search.windows.net','searchService'),@('cosmos','cosmos','documents.azure.com','Sql'))) {
                    $hostName="$($standard[$pair[0]].name).$($pair[2])"
                    $network.targets+=@{service=$pair[0];id=$standard[$pair[0]].id;hostName=$hostName;zoneId=$standard.dnsZoneIds[$pair[1]];endpointId="$($standard.resourceGroupId)/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-exp-$selection-$($pair[1])";groupId=$pair[3]}
                    $address=if ($pair[0] -ceq 'cosmos') { $fixture.resources.nic.properties.ipConfigurations[0].properties.privateIPAddress } else { $network.addressPrefix+'4' }
                    $addresses[$hostName]=@($address); $checks+=@{hostName=$hostName;tls443=$true;addresses=@($address)}
                }
                Write-StandardJson $receiptPath @{success=$true;project=$selection;reportPath=$receiptPath;checkedAt=[DateTimeOffset]::UtcNow.AddMinutes(-6).ToString('o');verifiedAt=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o');runtimeVerified=$false;inferenceVerified=$false;scope='runner DNS and TLS only';binding=$network;ownedAddresses=$addresses;checks=$checks;inputHashes=$receiptInputs;sourceHashes=$privateSources}
                $workflowPrivatePaths[$selection]=$receiptPath
            }
            $workflowMode=@{submits=0;calls=0;failSubmit=$true;sourceChange=$false;baselineChange=$false;compileCalls=0;wrongContext=$false;environmentTarget=$null;environmentEffects=$false;statusOnly=$false;statusWrites=0;statusCompiles=0;failEndSeal=$false;sourceReads=0;tamperOutputPath=$null;failAfterMove=$false;completionWrites=0}
            $workflowJsonWriter=(Get-Command Write-StandardJson).ScriptBlock
            function Write-StandardJson {
                param($Path,$Value)
                $completion=$workflowMode.statusOnly -and $Path -ceq $workflowPaths.state -and $Value.verified -eq $true
                if ($completion -and $workflowMode.failAfterMove) {
                    Check (Test-Path -LiteralPath $workflowPaths.outputs -PathType Leaf)
                    $workflowMode.failAfterMove=$false
                    throw 'Synthetic failure after output Move and before manifest save'
                }
                & $workflowJsonWriter $Path $Value
                if ($completion) { $workflowMode.completionWrites++ }
            }
            $workflowSources=Get-ExpansionNetworkSources
            function Get-ExpansionNetworkSources { $workflowMode.sourceReads++; $value=$workflowSources.Clone(); if ($workflowMode.sourceChange -or ($workflowMode.failEndSeal -and $workflowMode.sourceReads -gt 1)) { $value['synthetic-validator']='changed' }; return $value }
            function Invoke-WorkflowStatus {
                $workflowMode.statusOnly=$true
                try { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Status' $networkTestCompiler $false }
                finally { $workflowMode.statusOnly=$false }
            }
            function Get-FoundationBinding { param($State,$Lab,$Compiler) Assert-FoundationOriginal $State; return $workflowFoundation }
            function Get-FoundationLive {
                param($State,$Lab,$Standard,$Activation,$Binding,[switch]$After)
                Check ([bool]$After)
                $value=Clone $workflowBaseline
                $nsgId=$workflowFixtures[$workflowSelector].resources.nsg.id
                $value[$nsgId]=Select-FoundationConfiguration $workflowResources[$nsgId]
                if ($workflowMode.baselineChange) { $value['protected-original-agent-version'].version='changed' }
                return $value
            }
            function Read-ExpansionNetworkArm {
                param($State,$Id,$Api,[switch]$List)
                $workflowMode.calls++
                Check ($State.azureConfigDirectory -ceq $workflowState.azureConfigDirectory -and $State.subscriptionId -ceq $workflowState.subscriptionId)
                if ($workflowMode.tamperOutputPath) { [IO.File]::AppendAllText($workflowMode.tamperOutputPath,' '); $workflowMode.tamperOutputPath=$null }
                if ($List -and $Id -like '*/providers/Microsoft.Resources/deployments') { return @($workflowDeployments.Values | Where-Object { $_.id.StartsWith("$Id/",[StringComparison]::OrdinalIgnoreCase) }) }
                if ($List -and $Id -like '*/operations') {
                    $root=$Id.Substring(0,$Id.Length-11)
                    if (-not $workflowOperations.ContainsKey($root)) { throw 'Unmocked deployment operation read' }
                    return $workflowOperations[$root]
                }
                if ($List -and $Id -like '*/resources') {
                    if ($workflowMode.environmentEffects) { return @(@{id=$workflowMode.environmentTarget}) }
                    if ($Id -ieq "$integration/resources") { return @(foreach ($resource in $workflowInventory.Values) { Clone $resource }) }
                    return @()
                }
                if ($workflowResources.ContainsKey($Id)) { return Clone $workflowResources[$Id] }
                throw "Unmocked network read: $Id"
            }
            $workflowPaths=Get-ExpansionNetworkPaths $workflowState $workflowSelector
            function Invoke-ExpansionNetworkProcess {
                param($State,$Executable,$Arguments,$Budget)
                if ($workflowMode.statusOnly) { $workflowMode.statusCompiles++; throw 'Status must not invoke the compiler' }
                Check ($Executable -ceq $networkTestCompiler -and $Arguments[0] -ceq 'build' -and $Arguments[1] -ceq $workflowPaths.source -and $Arguments -contains '--no-restore')
                $workflowMode.compileCalls++
                & $Executable @Arguments
                if ($LASTEXITCODE -ne 0) { throw 'Offline Bicep compilation failed' }
                return @{reason='Exited';exitCode=0}
            }
            function Invoke-ExpansionNetworkAz {
                param($State,$Arguments,[switch]$Empty)
                $workflowMode.calls++
                Check ($State.azureConfigDirectory -ceq $workflowState.azureConfigDirectory -and $State.evidenceDirectory -ceq $workflowPaths.evidence)
                if (($Arguments[0..1] -join '/') -ceq 'account/show') {
                    return @{id=$(if ($workflowMode.wrongContext) { '55555555-5555-4555-8555-555555555555' } else { $State.subscriptionId });tenantId=$State.tenantId;state='Enabled'}
                }
                if ($workflowMode.statusOnly) { $workflowMode.statusWrites++; throw 'Status permits only Azure reads' }
                Check (($Arguments[0..1] -join '/') -ceq 'deployment/group')
                if ($Arguments[2] -ceq 'validate') { return @{properties=@{provisioningState='Succeeded'}} }
                if ($Arguments[2] -ceq 'what-if') {
                    Check ($Arguments -contains 'FullResourcePayloads')
                    $template=Read-FoundationJson $workflowPaths.template
                    $rule=$template.resources[0]
                    $rule.id="$integration/providers/Microsoft.Network/networkSecurityGroups/$($rule.name -replace '/', '/securityRules/')"
                    $changes=@(@{resourceId=$rule.id;changeType='Create';after=$rule})
                    foreach ($resource in $workflowInventory.Values) { $changes+=@{resourceId=$resource.id;changeType='Ignore';before=(Clone $resource);after=(Clone $resource);delta=$null;deploymentId=$null;extension=$null;identifiers=$null;symbolicName=$null;unsupportedReason=$null} }
                    return @{status='Succeeded';changes=$changes}
                }
                if ($Arguments[2] -ceq 'create') {
                    Check ($Empty -and $Arguments -contains '--no-wait')
                    $intent=Read-FoundationJson $workflowPaths.state
                    Check ($intent.pending -eq $true -and $intent.verified -eq $false -and $intent.deploymentId -ceq (Get-ExpansionNetworkDeploymentId $intent.binding))
                    $workflowMode.submits++
                    if ($workflowMode.failSubmit) { throw 'Synthetic lost submission response' }
                    return
                }
                throw 'Unmocked CLI operation'
            }
            $protected=@{}; foreach ($file in @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File)) { $protected[$file.FullName]=(Get-FileHash $file.FullName -Algorithm SHA256).Hash }
            $prerequisites=Get-ExpansionNetworkPrerequisites $workflowState $workflowPath $networkTestCompiler
            & {
                $historicalRoot="$integration/providers/Microsoft.Resources/deployments/sealed-failed"
                $workflowMode.environmentTarget="$integration/providers/Microsoft.AlertsManagement/smartDetectorAlertRules/synthetic-alert"
                $workflowDeployments[$historicalRoot]=@{id=$historicalRoot;name='sealed-failed';properties=@{mode='Incremental';provisioningState='Failed'}}
                $workflowOperations[$historicalRoot]=@(@{id="$historicalRoot/operations/one";properties=@{provisioningState='Failed';provisioningOperation='Create';targetResource=@{id=$workflowMode.environmentTarget}}})
                $sealed=Clone $prerequisites
                $sealed.seal.output.environmentEvents=@(@{deploymentId=$historicalRoot;targetId=$workflowMode.environmentTarget;targetAbsent=$true;deploymentHash=(Get-FoundationHash $workflowDeployments[$historicalRoot]);operationsHash=(Get-FoundationHash $workflowOperations[$historicalRoot])})
                try {
                    $null=Get-ExpansionNetworkIdle $workflowState $sealed @{} $workflowSelector; Check $true
                    Reject { Get-ExpansionNetworkIdle $workflowState $prerequisites @{} $workflowSelector }
                    $workflowMode.environmentEffects=$true
                    Reject { Get-ExpansionNetworkIdle $workflowState $sealed @{} $workflowSelector }
                    $workflowMode.environmentEffects=$false
                    $workflowOperations[$historicalRoot][0].properties.provisioningState='Succeeded'
                    Reject { Get-ExpansionNetworkIdle $workflowState $sealed @{} $workflowSelector }
                } finally {
                    $workflowDeployments.Remove($historicalRoot); $workflowOperations.Remove($historicalRoot)
                    $workflowMode.environmentTarget=$null; $workflowMode.environmentEffects=$false
                }
            }
            & {
                $oldPath=$workflowPrivatePaths[$workflowSelector]
                $latestPath=Join-Path $fixtureRoot "expansion-private-$workflowSelector-newer/receipt.json"
                $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($latestPath))
                $latest=Read-FoundationJson $oldPath; $latest.reportPath=$latestPath; $latest.verifiedAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
                $latest.sourceHashes['synthetic-validator']='stale'
                try {
                    Write-StandardJson $latestPath $latest
                    Reject { Get-ExpansionNetworkPrerequisites $workflowState $workflowPath $networkTestCompiler }
                } finally { Remove-Item -LiteralPath ([IO.Path]::GetDirectoryName($latestPath)) -Recurse -Force }
            }
            foreach ($selection in @('a-test','b-dev','b-test')) {
                $dependencyPaths=Get-ExpansionStandardPaths $workflowState $selection
                foreach ($mutation in @({param($value) $value.pending=$true},{param($value) $value.outputHash='tampered'},{param($value) $value.review.inputHashes.state='tampered'})) {
                    $saved=[IO.File]::ReadAllText($dependencyPaths.state); $bad=Read-FoundationJson $dependencyPaths.state; & $mutation $bad
                    try { Write-StandardJson $dependencyPaths.state $bad; Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Preview' $networkTestCompiler $true } }
                    finally { [IO.File]::WriteAllText($dependencyPaths.state,$saved) }
                }
                foreach ($mutation in @({param($value) $value.sourceHashes.extra='tampered'},{param($value) $value.inputHashes.extra='tampered'},{param($value) $value.success=$false},{param($value) $value.checks[0].tls443=$false})) {
                    $receiptPath=$workflowPrivatePaths[$selection]; $saved=[IO.File]::ReadAllText($receiptPath); $bad=Read-FoundationJson $receiptPath; & $mutation $bad
                    try { Write-StandardJson $receiptPath $bad; Reject { Get-ExpansionNetworkPrerequisites $workflowState $workflowPath $networkTestCompiler } }
                    finally { [IO.File]::WriteAllText($receiptPath,$saved) }
                }
            }
            $preview=Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Preview' $networkTestCompiler $true
            Check ($preview.action -ceq 'Preview' -and $workflowMode.submits -eq 0 -and $workflowMode.compileCalls -eq 1)
            $manifest=Read-FoundationJson $workflowPaths.state
            Assert-ExpansionNetworkReview $manifest $workflowPaths $prerequisites $workflowSources; Check $true
            foreach ($resource in $workflowInventory.Values) { Assert-FoundationEqual $manifest.known[$resource.id] $resource; Check $true }
            $savedInventory=Clone $workflowInventory
            foreach ($mutation in @(
                { $resource=Clone @($workflowInventory.Values)[0]; $resource.id+='-unknown'; $workflowInventory[$resource.id]=$resource },
                { $resource=Clone @($workflowInventory.Values)[0]; $resource.id=$resource.id.Replace('/resourceGroups/','/resourceGroups/foreign-'); $workflowInventory[$resource.id]=$resource },
                { @($workflowInventory.Values)[0].type='Microsoft.Unknown/resources' },
                { $resource=@($workflowInventory.Values | Where-Object { $_.tags })[0]; $resource.tags['fgl-owner']='foreign' }
            )) {
                try { & $mutation; Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true } }
                finally { $workflowInventory=Clone $savedInventory }
            }
            foreach ($mutation in @({param($value) $value.review.checkedAt=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')},{param($value) $value.review.checkedAt=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')},{param($value) $value.review.sourceHashes.extra='tampered'},{param($value) $value.binding.addresses[0]='10.76.6.30'},{param($value) $value.baseline.extra='tampered'},{param($value) $value.review.artifactHashes.template='tampered'})) {
                $bad=Read-FoundationJson $workflowPaths.state; & $mutation $bad
                Reject { Assert-ExpansionNetworkReview $bad $workflowPaths $prerequisites $workflowSources }
            }
            foreach ($key in @('source','template','parameters','whatif')) {
                $saved=[IO.File]::ReadAllText($workflowPaths[$key])
                try { [IO.File]::AppendAllText($workflowPaths[$key],' '); Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true } }
                finally { [IO.File]::WriteAllText($workflowPaths[$key],$saved) }
            }
            foreach ($key in @('sourceChange','baselineChange','wrongContext')) {
                $workflowMode[$key]=$true
                try { Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true } }
                finally { $workflowMode[$key]=$false }
            }
            $foreignRoot="$integration/providers/Microsoft.Resources/deployments/unknown-active"
            $workflowDeployments[$foreignRoot]=@{id=$foreignRoot;name='unknown-active';properties=@{provisioningState='Running';mode='Incremental'}}
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true }
            $workflowDeployments.Remove($foreignRoot)
            $other=@('a-test','b-dev','b-test' | Where-Object { $_ -cne $workflowSelector })[0]
            $otherPaths=Get-ExpansionNetworkPaths $workflowState $other
            Write-StandardJson $otherPaths.state @{project=$other;stage='cosmos-network';pending=$true;verified=$false}
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true }
            Remove-Item -LiteralPath $otherPaths.state
            Check ($workflowMode.submits -eq 0)
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true }
            Check ($workflowMode.submits -eq 1)
            $intent=Read-FoundationJson $workflowPaths.state
            Check ($intent.pending -eq $true -and $intent.verified -eq $false)
            $intentHash=(Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true }
            Reject { Invoke-WorkflowStatus }
            Check ($workflowMode.submits -eq 1 -and (Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $intentHash)
            Check (-not (Test-Path -LiteralPath $workflowPaths.outputs))
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $other 'Preview' $networkTestCompiler $true }
            foreach ($mutation in @({param($value) $value.pending=$false},{param($value) $value.pending=$false; $value.verified=$true},{param($value) $value.pending=$false; $value.verified=$true; $value.outputHash='A'*64})) {
                $saved=[IO.File]::ReadAllText($workflowPaths.state); $bad=Clone $intent; & $mutation $bad
                try {
                    Write-StandardJson $workflowPaths.state $bad
                    Reject { Invoke-WorkflowStatus }
                    Reject { Invoke-ExpansionCosmosNetwork $workflowPath $other 'Preview' $networkTestCompiler $true }
                } finally { [IO.File]::WriteAllText($workflowPaths.state,$saved) }
            }
            $binding=$intent.binding; $root=$intent.deploymentId
            $rule=@{id=$binding.names.ruleId;name=$binding.names.ruleName;type='Microsoft.Network/networkSecurityGroups/securityRules';properties=(Get-ExpansionCosmosNetworkRuleProperties $workflowSelector $binding.addresses)}
            $rule.properties.provisioningState='Succeeded'
            $workflowResources[$binding.names.nsgId].properties.securityRules+=$rule
            $workflowDeployments[$root]=@{id=$root;name=($root -split '/')[-1];properties=@{mode='Incremental';provisioningState='Succeeded';parameters=@{};outputs=@{};outputResources=@(@{id=$rule.id})}}
            $workflowOperations[$root]=@(@{id="$root/operations/one";properties=@{provisioningState='Succeeded';provisioningOperation='Create';targetResource=@{id=$rule.id;resourceType=$rule.type}}})
            $workflowMode.failEndSeal=$true; $workflowMode.sourceReads=0
            try { Reject { Invoke-WorkflowStatus } } finally { $workflowMode.failEndSeal=$false }
            Check ((Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $intentHash -and -not (Test-Path -LiteralPath $workflowPaths.outputs))
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $other 'Preview' $networkTestCompiler $true }
            Write-StandardJson $workflowPaths.outputs @{unsealed='protected'}
            $orphanHash=(Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash
            try {
                Reject { Invoke-WorkflowStatus }
                Check ((Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash -ceq $orphanHash -and (Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $intentHash)
            } finally { Remove-Item -LiteralPath $workflowPaths.outputs }
            $workflowMode.failAfterMove=$true
            Reject { Invoke-WorkflowStatus }
            Check (-not $workflowMode.failAfterMove -and $workflowMode.completionWrites -eq 0 -and (Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $intentHash)
            $orphanBytes=[IO.File]::ReadAllBytes($workflowPaths.outputs)
            $orphanHash=(Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash
            $orphan=Read-FoundationJson $workflowPaths.outputs
            Assert-FoundationEqual $orphan.intentHash (Get-FoundationHash $intent); Check $true
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Preview' $networkTestCompiler $true }
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true }
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $other 'Status' $networkTestCompiler $false }
            foreach ($mutation in @({param($value) $value.extra='unexpected'},{param($value) $value.project='foreign'},{param($value) $value.controlPlaneVerified=$false},{param($value) $value.runtimeVerified=$true},{param($value) $value.azureReadOnly='true'},{param($value) $value.intentHash='A'*64},{param($value) $value.ruleId+='-foreign'},{param($value) $value.deploymentId+='-foreign'},{param($value) $value.inputHashes.state='tampered'},{param($value) $value.sourceHashes.extra='tampered'},{param($value) $value.verifiedAt=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')},{param($value) $value.verifiedAt=[DateTimeOffset]::Parse($intent.submittedAt).AddSeconds(-1).ToString('o')},{param($value) $value.deploymentProof.operationsHash='A'*64},{param($value) $value.deploymentProof.deploymentHash='A'*64})) {
                $bad=Clone $orphan; & $mutation $bad
                try {
                    Write-StandardJson $workflowPaths.outputs $bad
                    $badHash=(Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash
                    Reject { Invoke-WorkflowStatus }
                    Check ((Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash -ceq $badHash -and (Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $intentHash -and $workflowMode.completionWrites -eq 0)
                } finally { [IO.File]::WriteAllBytes($workflowPaths.outputs,$orphanBytes) }
            }
            foreach ($key in @('sourceChange','baselineChange','wrongContext')) {
                $workflowMode[$key]=$true
                try { Reject { Invoke-WorkflowStatus } } finally { $workflowMode[$key]=$false }
            }
            $savedOperation=Clone $workflowOperations[$root]
            try {
                $workflowOperations[$root][0].properties.provisioningOperation='Delete'
                Reject { Invoke-WorkflowStatus }
            } finally { $workflowOperations[$root]=$savedOperation }
            $workflowMode.tamperOutputPath=$workflowPaths.outputs
            try { Reject { Invoke-WorkflowStatus } }
            finally { $workflowMode.tamperOutputPath=$null; [IO.File]::WriteAllBytes($workflowPaths.outputs,$orphanBytes) }
            Check ((Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $intentHash -and $workflowMode.completionWrites -eq 0)
            $orphanTime=(Get-Item $workflowPaths.outputs).LastWriteTimeUtc.Ticks
            $status=Invoke-WorkflowStatus
            Assert-FoundationEqual $status $orphan; Check $true
            Check ((Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash -ceq $orphanHash -and (Get-Item $workflowPaths.outputs).LastWriteTimeUtc.Ticks -eq $orphanTime -and $workflowMode.completionWrites -eq 1)
            Check ($status.controlPlaneVerified -eq $true -and $status.azureReadOnly -eq $true -and -not $status.runtimeVerified -and -not $status.inferenceVerified -and -not $status.completeLab)
            $verifiedManifest=Read-FoundationJson $workflowPaths.state
            $verifiedHash=(Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash
            $verifiedOutputHash=(Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash
            $expectedManifest=$intent.Clone(); $expectedManifest.pending=$false; $expectedManifest.verified=$true; $expectedManifest.outputHash=$verifiedOutputHash
            Assert-FoundationEqual $verifiedManifest $expectedManifest; Check $true
            Assert-FoundationEqual (Read-FoundationJson $workflowPaths.outputs) $status; Check $true
            Assert-ExpansionNetworkReceipt $verifiedManifest $status $verifiedOutputHash; Check $true
            Check ($workflowMode.submits -eq 1 -and $workflowMode.compileCalls -eq 1 -and $verifiedHash -cne $intentHash)
            $verifiedTimes=@((Get-Item $workflowPaths.state).LastWriteTimeUtc.Ticks,(Get-Item $workflowPaths.outputs).LastWriteTimeUtc.Ticks)
            Assert-FoundationEqual (Invoke-WorkflowStatus) $status; Check $true
            Check ($workflowMode.completionWrites -eq 1)
            Assert-FoundationEqual @((Get-Item $workflowPaths.state).LastWriteTimeUtc.Ticks,(Get-Item $workflowPaths.outputs).LastWriteTimeUtc.Ticks) $verifiedTimes; Check $true
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Preview' $networkTestCompiler $true }
            Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true }
            foreach ($mutation in @({param($value) $value.properties.provisioningState='Running'},{param($value) $value.properties.provisioningState='Failed'},{param($value) $value.properties.outputResources+=@{id='unknown'}},{param($value) $value.id+='-foreign'})) {
                $saved=$workflowDeployments[$root]; $bad=Clone $saved; & $mutation $bad; $workflowDeployments[$root]=$bad
                try { Reject { Invoke-WorkflowStatus } }
                finally { $workflowDeployments[$root]=$saved }
            }
            foreach ($mutation in @({param($value) $value[0].properties.provisioningOperation='Delete'},{param($value) $value[0].properties.provisioningState='Failed'},{param($value) $value[0].properties.targetResource.id+='-foreign'})) {
                $saved=$workflowOperations[$root]; $bad=Clone $saved; & $mutation $bad; $workflowOperations[$root]=$bad
                try { Reject { Invoke-WorkflowStatus } }
                finally { $workflowOperations[$root]=$saved }
            }
            foreach ($nsgId in @($binding.names.nsgId,$binding.agentNsgId)) {
                $saved=Clone $workflowResources[$nsgId]
                try {
                    $workflowResources[$nsgId].properties.securityRules[0].properties.access='Deny'
                    Reject { Invoke-WorkflowStatus }
                } finally { $workflowResources[$nsgId]=$saved }
            }
            $savedNsg=Clone $workflowResources[$binding.names.nsgId]
            try {
                $workflowResources[$binding.names.nsgId].properties.securityRules+=New-FixtureRule $binding.names.nsgId 'unreviewed-addition' 250
                Reject { Invoke-WorkflowStatus }
            } finally { $workflowResources[$binding.names.nsgId]=$savedNsg }
            & {
                $workflowFirstSelector=$workflowSelector; $workflowFirstPaths=$workflowPaths; $workflowFirstRoot=$root; $workflowFirstRuleId=$binding.names.ruleId
                $workflowSelector=@{'a-test'='b-dev';'b-dev'='b-test';'b-test'='a-test'}[$workflowFirstSelector]
                $workflowPaths=Get-ExpansionNetworkPaths $workflowState $workflowSelector
                $savedProof=[IO.File]::ReadAllText($workflowFirstPaths.outputs)
                $savedManifest=[IO.File]::ReadAllText($workflowFirstPaths.state)
                try {
                    [IO.File]::AppendAllText($workflowFirstPaths.outputs,' ')
                    $tamperedHash=(Get-FileHash $workflowFirstPaths.outputs -Algorithm SHA256).Hash
                    Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Preview' $networkTestCompiler $true }
                    Check ((Get-FileHash $workflowFirstPaths.outputs -Algorithm SHA256).Hash -ceq $tamperedHash)
                } finally { [IO.File]::WriteAllText($workflowFirstPaths.outputs,$savedProof) }
                foreach ($mutation in @({param($value) $value.controlPlaneVerified=$false},{param($value) $value.runtimeVerified=$true},{param($value) $value.azureReadOnly='true'},{param($value) $value.intentHash='A'*64},{param($value) $value.ruleId+='-foreign'},{param($value) $value.inputHashes.state='tampered'},{param($value) $value.sourceHashes.extra='tampered'},{param($value) $value.verifiedAt=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')},{param($value) $value.deploymentProof.operationsHash='A'*64})) {
                    $badProof=Read-FoundationJson $workflowFirstPaths.outputs; & $mutation $badProof
                    try {
                        Write-StandardJson $workflowFirstPaths.outputs $badProof
                        $badManifest=Read-FoundationJson $workflowFirstPaths.state; $badManifest.outputHash=(Get-FileHash $workflowFirstPaths.outputs -Algorithm SHA256).Hash
                        Write-StandardJson $workflowFirstPaths.state $badManifest
                        Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Preview' $networkTestCompiler $true }
                    } finally { [IO.File]::WriteAllText($workflowFirstPaths.outputs,$savedProof); [IO.File]::WriteAllText($workflowFirstPaths.state,$savedManifest) }
                }
                $preview=Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Preview' $networkTestCompiler $true
                Check ($preview.action -ceq 'Preview' -and $workflowMode.compileCalls -eq 2)
                $secondReview=Read-FoundationJson $workflowPaths.state
                Check ($secondReview.binding.names.nsgId -ceq $binding.names.nsgId -and @($secondReview.binding.otherRules | Where-Object id -IEQ $workflowFirstRuleId).Count -eq 1)
                Check (@($secondReview.baseline[$binding.names.nsgId].properties.securityRules | Where-Object id -IEQ $workflowFirstRuleId).Count -eq 1)
                $workflowMode.failSubmit=$false
                $submitted=Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Deploy' $networkTestCompiler $true
                Check ($submitted.pending -eq $true -and $workflowMode.submits -eq 2)
                $secondIntent=Read-FoundationJson $workflowPaths.state
                $secondIntentHash=(Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash
                Reject { Invoke-WorkflowStatus }
                Check ((Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $secondIntentHash -and -not (Test-Path -LiteralPath $workflowPaths.outputs))
                & {
                    $workflowSelector=$workflowFirstSelector; $workflowPaths=$workflowFirstPaths
                    Reject { Invoke-WorkflowStatus }
                }
                $secondBinding=$secondIntent.binding; $secondRoot=$secondIntent.deploymentId
                $secondRule=@{id=$secondBinding.names.ruleId;name=$secondBinding.names.ruleName;type='Microsoft.Network/networkSecurityGroups/securityRules';properties=(Get-ExpansionCosmosNetworkRuleProperties $workflowSelector $secondBinding.addresses)}
                $secondRule.properties.provisioningState='Succeeded'
                $workflowResources[$secondBinding.names.nsgId].properties.securityRules+=$secondRule
                $workflowDeployments[$secondRoot]=@{id=$secondRoot;name=($secondRoot -split '/')[-1];properties=@{mode='Incremental';provisioningState='Succeeded';parameters=@{};outputs=@{};outputResources=@(@{id=$secondRule.id})}}
                $workflowOperations[$secondRoot]=@(@{id="$secondRoot/operations/one";properties=@{provisioningState='Succeeded';provisioningOperation='Create';targetResource=@{id=$secondRule.id;resourceType=$secondRule.type}}})
                $workflowMode.tamperOutputPath=$workflowFirstPaths.outputs
                try {
                    Reject { Invoke-WorkflowStatus }
                    Check ((Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $secondIntentHash -and -not (Test-Path -LiteralPath $workflowPaths.outputs))
                } finally { $workflowMode.tamperOutputPath=$null; [IO.File]::WriteAllText($workflowFirstPaths.outputs,$savedProof) }
                $secondStatus=Invoke-WorkflowStatus
                Check ($secondStatus.controlPlaneVerified -eq $true -and $secondStatus.azureReadOnly -eq $true)
                $secondManifest=Read-FoundationJson $workflowPaths.state
                Check ($secondManifest.pending -eq $false -and $secondManifest.verified -eq $true)
                $secondHash=(Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash
                $secondOutputHash=(Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash
                $secondTimes=@((Get-Item $workflowPaths.state).LastWriteTimeUtc.Ticks,(Get-Item $workflowPaths.outputs).LastWriteTimeUtc.Ticks)
                Assert-FoundationEqual $secondManifest.review $secondReview.review; Check $true
                Assert-FoundationEqual (Invoke-WorkflowStatus) $secondStatus; Check $true
                Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Preview' $networkTestCompiler $true }
                $savedEarlierDeployment=Clone $workflowDeployments[$workflowFirstRoot]
                try {
                    $workflowDeployments[$workflowFirstRoot].properties.unreviewed='changed'
                    Reject { Invoke-WorkflowStatus }
                } finally { $workflowDeployments[$workflowFirstRoot]=$savedEarlierDeployment }
                $savedSharedNsg=Clone $workflowResources[$secondBinding.names.nsgId]
                try {
                    $earlierRule=@($workflowResources[$secondBinding.names.nsgId].properties.securityRules | Where-Object id -IEQ $workflowFirstRuleId)[0]
                    $earlierRule.properties.destinationAddressPrefixes=@('*')
                    Reject { Invoke-WorkflowStatus }
                } finally { $workflowResources[$secondBinding.names.nsgId]=$savedSharedNsg }
                & {
                    $workflowSelector=$workflowFirstSelector; $workflowPaths=$workflowFirstPaths
                    $firstTimes=@((Get-Item $workflowPaths.state).LastWriteTimeUtc.Ticks,(Get-Item $workflowPaths.outputs).LastWriteTimeUtc.Ticks)
                    Assert-FoundationEqual (Invoke-WorkflowStatus) $status; Check $true
                    Assert-FoundationEqual @((Get-Item $workflowPaths.state).LastWriteTimeUtc.Ticks,(Get-Item $workflowPaths.outputs).LastWriteTimeUtc.Ticks) $firstTimes; Check $true
                    Reject { Invoke-ExpansionCosmosNetwork $workflowPath $workflowSelector 'Preview' $networkTestCompiler $true }
                    $savedLaterNsg=Clone $workflowResources[$secondBinding.names.nsgId]
                    try {
                        $laterRule=@($workflowResources[$secondBinding.names.nsgId].properties.securityRules | Where-Object id -IEQ $secondRule.id)[0]
                        $laterRule.properties.destinationAddressPrefixes=@('*')
                        Reject { Invoke-WorkflowStatus }
                    } finally { $workflowResources[$secondBinding.names.nsgId]=$savedLaterNsg }
                }
                Assert-FoundationEqual @((Get-Item $workflowPaths.state).LastWriteTimeUtc.Ticks,(Get-Item $workflowPaths.outputs).LastWriteTimeUtc.Ticks) $secondTimes; Check $true
                Check ((Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $secondHash -and (Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash -ceq $secondOutputHash)
                foreach ($selection in @($workflowFirstSelector,$workflowSelector)) {
                    $sealedPaths=Get-ExpansionNetworkPaths $workflowState $selection
                    $sealedManifest=Read-FoundationJson $sealedPaths.state
                    Check ($sealedManifest.pending -eq $false -and $sealedManifest.verified -eq $true)
                    Assert-ExpansionNetworkReceipt $sealedManifest (Read-FoundationJson $sealedPaths.outputs) (Get-FileHash $sealedPaths.outputs -Algorithm SHA256).Hash; Check $true
                }
            }
            foreach ($file in $protected.Keys) { Check ((Get-FileHash $file -Algorithm SHA256).Hash -ceq $protected[$file]) }
            Check ((Get-FileHash $workflowPaths.state -Algorithm SHA256).Hash -ceq $verifiedHash -and (Get-FileHash $workflowPaths.outputs -Algorithm SHA256).Hash -ceq $verifiedOutputHash)
            Check ($workflowMode.submits -eq 2 -and $workflowMode.compileCalls -eq 2 -and $workflowMode.statusWrites -eq 0 -and $workflowMode.statusCompiles -eq 0)
        } finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    }
}

& {
    $transportRoot=Join-Path ([IO.Path]::GetTempPath()) ('expansion-network-transport-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($transportRoot)
    try {
        $transportState=@{subscriptionId='11111111-1111-4111-8111-111111111111';azureConfigDirectory=(Join-Path $transportRoot 'isolated-cache');evidenceDirectory=$transportRoot}
        $transportMode=@{response=@{value=@()};reason='Exited';exitCode=0;empty=$false;calls=0}
        function Get-Command {
            param($Name,$CommandType,$ErrorAction)
            if ($Name -ceq 'az') { return @{Source=(Join-Path $transportRoot 'az.exe')} }
            return Microsoft.PowerShell.Core\Get-Command $Name
        }
        function Invoke-BoundedLabProcess {
            param($Executable,$Arguments,$LogPrefix,$MaxSeconds,$IdleSeconds,$Environment)
            $transportMode.calls++
            Check ($Executable -ceq (Join-Path $transportRoot 'az.exe'))
            Check ($MaxSeconds -eq 90 -and $IdleSeconds -eq 90)
            Check ($Environment.AZURE_CONFIG_DIR -ceq $transportState.azureConfigDirectory -and $Environment.AZURE_CORE_COLLECT_TELEMETRY -ceq 'false')
            $subscriptionIndex=[array]::IndexOf($Arguments,'--subscription')
            Check ($subscriptionIndex -ge 0 -and $Arguments[$subscriptionIndex+1] -ceq $transportState.subscriptionId)
            $stdout="$LogPrefix.stdout.txt"; $stderr="$LogPrefix.stderr.txt"
            if ($transportMode.empty) { [IO.File]::WriteAllText($stdout,'') } else { Write-StandardJson $stdout $transportMode.response }
            [IO.File]::WriteAllText($stderr,'synthetic private stderr')
            return @{reason=$transportMode.reason;exitCode=$transportMode.exitCode;stdout=$stdout;stderr=$stderr}
        }
        $scope="/subscriptions/$($transportState.subscriptionId)/resourceGroups/synthetic"
        $result=@(Read-ExpansionNetworkArm $transportState "$scope/resources" '2021-04-01' -List)
        Check ($result.Count -eq 0)
        $transportMode.response=@{value=@();nextLink='unexpected'}
        Reject { Read-ExpansionNetworkArm $transportState "$scope/resources" '2021-04-01' -List }
        $transportMode.response=@{value=@(@{id='duplicate'},@{id='duplicate'})}
        Reject { Read-ExpansionNetworkArm $transportState "$scope/resources" '2021-04-01' -List }
        $transportMode.response=@{id="$scope/foreign"}
        Reject { Read-ExpansionNetworkArm $transportState "$scope/resource" '2021-04-01' }
        foreach ($reason in @('Deadline','NoOutput')) {
            $transportMode.reason=$reason
            $count=$transportMode.calls
            Reject { Invoke-ExpansionNetworkAz $transportState @('account','show') }
            Check ($transportMode.calls -eq $count+1)
        }
        $transportMode.reason='Exited'; $transportMode.exitCode=1
        Reject { Invoke-ExpansionNetworkAz $transportState @('account','show') }
        $transportMode.exitCode=0; $transportMode.empty=$true
        $null=Invoke-ExpansionNetworkAz $transportState @('deployment','group','create','--no-wait') -Empty; Check $true
        Check (@(Get-ChildItem -LiteralPath $transportRoot -File -Filter '*.stderr.txt').Count -ge 5)
    } finally { Remove-Item -LiteralPath $transportRoot -Recurse -Force }
}

$tokens=$null; $errors=$null
$coordinatorAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionCosmosNetwork.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
Check (@($coordinatorAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cin @('Save-LabRun','Invoke-LabAz','Invoke-ExpansionStandard','Invoke-StandardCosmosNetwork')},$true)).Count -eq 0)
Write-Output "Expansion Cosmos network coordinator: $($networkChecks.count) offline checks passed."