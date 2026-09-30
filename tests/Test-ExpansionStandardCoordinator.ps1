[CmdletBinding()]
param([string]$BicepExecutable = 'bicep')
$testCompiler=$BicepExecutable
$timer=[Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference='Stop'
$checks=@{count=0}
try {
    . (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionStandard.ps1') -DefinitionsOnly
    function Check([bool]$Condition) { if (-not $Condition) { throw 'Dependencies assertion failed' }; $checks.count++ }
    function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed }
    function Invoke-LabAz { throw 'Offline test attempted unmocked transport' }
    $fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('expansion-dependencies-test-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($fixtureRoot)
    $fixture=@{subscriptionId='11111111-1111-4111-8111-111111111111';tenantId='22222222-2222-4222-8222-222222222222';ownershipId='33333333-3333-4333-8333-333333333333';labId='sample01';minimalPrompt=$true;phase='activate';pendingPhase=$null;deploymentAuthorized=$true;privateAccessVerified=$true;preexistingGroupIds=@();resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" });standard=@{completedStages=@('dependencies','account','project','access');pendingStage=$null;deploymentNames=@{}};runDirectory=$fixtureRoot;azureConfigDirectory=(Join-Path $fixtureRoot 'unused-config')}
    foreach ($stage in @('dependencies','project','access')) { $fixture.standard.deploymentNames[$stage]="fgl-sample01-standard-$stage" }
    foreach ($spec in @(@('cosmosNetwork','standard-cosmos-network'),@('gatewayPolicy','gateway-policy-update'))) { $fixture.standard[$spec[0]]=@{name="fgl-sample01-$($spec[1])";group='rg-fgl-sample01-integration';pending=$false;verified=$true;review=@{};evidence=@{}} }
    $prefix="/subscriptions/$($fixture.subscriptionId)"; $stem='fgl-sample01'
    $suffixSource=Join-Path $fixtureRoot 'fixture.bicepparam'; $suffixOutput=Join-Path $fixtureRoot 'fixture.json'
    [IO.File]::WriteAllText($suffixSource,"using none`nparam suffix = uniqueString('$prefix', 'sample01')")
    & $testCompiler build-params $suffixSource --no-restore --outfile $suffixOutput
    if ($LASTEXITCODE -ne 0) { throw 'Offline fixture compiler failed' }
    $suffix=(Read-FoundationJson $suffixOutput).parameters.suffix.value
    $foundation=@{accountA="$prefix/resourceGroups/rg-$stem-case-a/providers/Microsoft.CognitiveServices/accounts/aif-$stem-a-$suffix";accountB="$prefix/resourceGroups/rg-$stem-case-b/providers/Microsoft.CognitiveServices/accounts/aif-$stem-b-$suffix";integration="$prefix/resourceGroups/rg-$stem-integration";vnet="$prefix/resourceGroups/rg-$stem-integration/providers/Microsoft.Network/virtualNetworks/vnet-$stem"}
    $receipt=@{foundation=@{projects=@(@{resourceId="$($foundation.accountA)/projects/case-a-test";principalId='44444444-4444-4444-8444-444444444444'},@{resourceId="$($foundation.accountB)/projects/case-b-dev";principalId='55555555-5555-4555-8555-555555555555'},@{resourceId="$($foundation.accountB)/projects/case-b-test";principalId='66666666-6666-4666-8666-666666666666'})}}
    $bindings=@{}
    foreach ($selector in @('a-test','b-dev','b-test')) {
        $bound=Get-ExpansionStandardBinding $fixture $foundation $receipt $selector $testCompiler (Get-ExpansionStandardPaths $fixture $selector)
        $bindings[$selector]=$bound
        Check ($bound.new.Count -eq 16 -and $bound.nested.Count -eq 10)
        $whatif=@{status='Succeeded';changes=@(foreach ($id in $bound.new.Keys) { @{resourceId=$id;changeType='Create';after=(Read-ExpansionStandardCopy $bound.specs[$id].resource)} })}
        Assert-ExpansionStandardWhatIf $fixture $bound @{} $whatif; Check $true
        foreach ($id in $bound.new.Keys) {
            foreach ($changeType in @('Delete','Modify','Unsupported','Deploy','NoChange','Ignore')) {
                $bad=Read-ExpansionStandardCopy $whatif; @($bad.changes | Where-Object resourceId -IEQ $id)[0].changeType=$changeType
                Reject { Assert-ExpansionStandardWhatIf $fixture $bound @{} $bad }
            }
        }
        foreach ($spec in @(@('storage','allowSharedKeyAccess',$true),@('storage','publicNetworkAccess','Enabled'),@('search','disableLocalAuth',$false),@('cosmos','disableLocalAuth',$false),@('cosmos','capabilities',@(@{name='EnableServerless'})))) {
            $bad=Read-ExpansionStandardCopy $whatif; @($bad.changes | Where-Object resourceId -IEQ $bound.output[$spec[0]].id)[0].after.properties[$spec[1]]=$spec[2]
            Reject { Assert-ExpansionStandardWhatIf $fixture $bound @{} $bad }
        }
        foreach ($roleId in $bound.roles.Keys) {
            foreach ($field in @('principalId','principalType','roleDefinitionId','scope')) { $bad=Read-ExpansionStandardCopy $bound.specs[$roleId].resource; $bad.properties[$field]='wrong'; Reject { Assert-ExpansionStandardResource $fixture $bound $bad $roleId } }
        }
    }
    Check (@($bindings.Values | ForEach-Object { $_.new.Keys } | Sort-Object -Unique).Count -eq 48)
    Check ($fixture.minimalPrompt -eq $true -and $fixture.resourceGroups.Count -eq 3)
    Check ((Get-FoundationHash @{flag=$true}) -cne (Get-FoundationHash @{flag='true'}))
    Reject { Get-ExpansionStandardBinding $fixture $foundation $receipt 'a-dev' $testCompiler (Get-ExpansionStandardPaths $fixture 'a-test') }
    $badReceipt=Read-ExpansionStandardCopy $receipt; $badReceipt.foundation.projects[0].resourceId+='-wrong'
    Reject { Get-ExpansionStandardBinding $fixture $foundation $badReceipt 'a-test' $testCompiler (Get-ExpansionStandardPaths $fixture 'a-test') }
    $bound=$bindings['a-test']
    & {
        $revisionKey='scripts/Invoke-ExpansionStandard.ps1'
        $archive=Join-Path $fixtureRoot "standard-a-test-validator-submitted/$revisionKey"
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($archive))
        [IO.File]::WriteAllText($archive,'synthetic original validator')
        $original=@{$revisionKey=(Get-FileHash $archive -Algorithm SHA256).Hash;'infra/unchanged.bicep'='same'}
        $current=$original.Clone(); $current[$revisionKey]='revised'
        $revision=Assert-ExpansionStandardValidatorRevision $original $current $fixtureRoot 'a-test'
        Check ($revision.Count -eq 1 -and $revision[$revisionKey].submitted -ceq $original[$revisionKey])
        Reject { Assert-ExpansionStandardValidatorRevision $original $original $fixtureRoot 'a-test' }
        Reject { Assert-ExpansionStandardValidatorRevision $original $current $fixtureRoot 'b-dev' }
        Reject { Assert-ExpansionStandardValidatorRevision $original $current $fixtureRoot '../a-test' }
        $bad=$current.Clone(); $bad['infra/unchanged.bicep']='changed'
        Reject { Assert-ExpansionStandardValidatorRevision $original $bad $fixtureRoot 'a-test' }
        $bad=$current.Clone(); $bad['extra']='changed'
        Reject { Assert-ExpansionStandardValidatorRevision $original $bad $fixtureRoot 'a-test' }
        [IO.File]::AppendAllText($archive,'changed')
        Reject { Assert-ExpansionStandardValidatorRevision $original $current $fixtureRoot 'a-test' }
        foreach ($action in @('Preview','Deploy')) { Reject { Invoke-ExpansionStandard 'unused' 'a-test' $action $testCompiler $true $true } }
    }
    foreach ($id in $bound.new.Keys) {
        $liveResource=Read-ExpansionStandardCopy $bound.specs[$id].resource
        $liveResource.properties.provisioningState='Succeeded'
        if ($bound.new[$id] -ceq 'search') { $liveResource.identity.principalId='77777777-7777-4777-8777-777777777777'; $liveResource.identity.tenantId=$fixture.tenantId }
        if ($bound.new[$id] -ceq 'endpoint') { $liveResource.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState=@{status='Approved'} }
        Assert-ExpansionStandardResource $fixture $bound $liveResource $id -Live; Check $true
        if ($bound.new[$id] -ceq 'cosmos') {
            $displayRegion=Read-ExpansionStandardCopy $liveResource; $displayRegion.location='Sweden Central'; $displayRegion.properties.locations[0].locationName='Sweden Central'
            Assert-ExpansionStandardResource $fixture $bound $displayRegion $id -Live; Check $true
            Reject { Assert-ExpansionStandardResource $fixture $bound $displayRegion $id }
            $bad=Read-ExpansionStandardCopy $displayRegion; $bad.location='Sweden South'
            Reject { Assert-ExpansionStandardResource $fixture $bound $bad $id -Live }
            $bad=Read-ExpansionStandardCopy $displayRegion; $bad.properties.locations[0].locationName='Sweden South'
            Reject { Assert-ExpansionStandardResource $fixture $bound $bad $id -Live }
        }
        if ($bound.new[$id] -ceq 'search') {
            $displaySearch=Read-ExpansionStandardCopy $liveResource; $displaySearch.location='Sweden Central'; $displaySearch.properties.publicNetworkAccess='Disabled'
            Assert-ExpansionStandardResource $fixture $bound $displaySearch $id -Live; Check $true
            Reject { Assert-ExpansionStandardResource $fixture $bound $displaySearch $id }
            $bad=Read-ExpansionStandardCopy $displaySearch; $bad.location='Sweden South'
            Reject { Assert-ExpansionStandardResource $fixture $bound $bad $id -Live }
            $bad=Read-ExpansionStandardCopy $displaySearch; $bad.properties.publicNetworkAccess='Enabled'
            Reject { Assert-ExpansionStandardResource $fixture $bound $bad $id -Live }
            $lowercase=Read-ExpansionStandardCopy $liveResource; $lowercase.properties.provisioningState='succeeded'
            Assert-ExpansionStandardResource $fixture $bound $lowercase $id -Live; Check $true
            $lowercase.properties.provisioningState='failed'
            Reject { Assert-ExpansionStandardResource $fixture $bound $lowercase $id -Live }
        }
        $bad=Read-ExpansionStandardCopy $liveResource; $bad.id=$bad.id.Replace($fixture.subscriptionId,'88888888-8888-4888-8888-888888888888')
        Reject { Assert-ExpansionStandardResource $fixture $bound $bad $id -Live }
        if ($bound.new[$id] -cin @('storage','search','cosmos','endpoint')) { $bad=Read-ExpansionStandardCopy $liveResource; $bad.tags['fgl-owner']='wrong'; Reject { Assert-ExpansionStandardResource $fixture $bound $bad $id -Live } }
    }
    $previewRole=Read-ExpansionStandardCopy $bound.specs[@($bound.roles.Keys)[0]].resource; $previewRole.properties.Remove('principalType'); $previewRole.properties.Remove('scope')
    Assert-ExpansionStandardResource $fixture $bound $previewRole $previewRole.id; Check $true
    Reject { Assert-ExpansionStandardResource $fixture $bound $previewRole $previewRole.id -Live }
    $previewRole.properties.principalId="[reference('identity').principalId]"
    Reject { Assert-ExpansionStandardResource $fixture $bound $previewRole $previewRole.id }
    $groupFixtures=@(foreach ($name in @($fixture.resourceGroups)+@('rg-fgl-sample01-case-b')) { @{id="$prefix/resourceGroups/$name";name=$name;location='swedencentral';tags=@{'fgl-lab'=$fixture.labId;'fgl-owner'=$fixture.ownershipId;purpose='synthetic-governance-lab'};properties=@{provisioningState='Succeeded'}} })
    $foundation.groupB="$prefix/resourceGroups/rg-fgl-sample01-case-b"
    Assert-ExpansionStandardGroups $fixture $foundation $groupFixtures; Check $true
    foreach ($field in @('id','name','location')) { $bad=Read-ExpansionStandardCopy $groupFixtures; $bad[3][$field]='wrong'; Reject { Assert-ExpansionStandardGroups $fixture $foundation $bad } }
    $bad=Read-ExpansionStandardCopy $groupFixtures; $bad[3].tags['fgl-owner']='wrong'
    Reject { Assert-ExpansionStandardGroups $fixture $foundation $bad }
    $previewManifest=@{project='a-test';pending=$false;verified=$false;review=@{}}
    Assert-ExpansionStandardTransition $previewManifest @{'a-test'=$previewManifest} 'a-test' 'Deploy' $true; Check $true
    Reject { Assert-ExpansionStandardTransition $previewManifest @{'a-test'=$previewManifest} 'a-test' 'Deploy' $false }
    $bad=Read-ExpansionStandardCopy $previewManifest; $bad.submittedAt='already submitted'
    Reject { Assert-ExpansionStandardTransition $bad @{'a-test'=$bad} 'a-test' 'Deploy' $true }
    $other=@{project='b-dev';pending=$true;verified=$false}
    Reject { Assert-ExpansionStandardTransition $previewManifest @{'a-test'=$previewManifest;'b-dev'=$other} 'a-test' 'Preview' $true }
    $writes=@{}
    $rootOperation=@(@{properties=@{provisioningState='Succeeded';provisioningOperation='Create';targetResource=@{id="$($bound.group)/providers/Microsoft.Resources/deployments/$($bound.name)";resourceType='Microsoft.Resources/deployments'}}})
    Assert-ExpansionStandardOperations $bound $bound.root $rootOperation $writes; Check ($writes.Count -eq 1)
    foreach ($mutation in @({param($value) $value[0].properties.provisioningState='Running'},{param($value) $value[0].properties.provisioningOperation='Delete'},{param($value) $value[0].properties.targetResource.id+='/unknown'},{param($value) $value[0].properties.targetResource.resourceType='Microsoft.Storage/storageAccounts'})) { $bad=Read-ExpansionStandardCopy $rootOperation; & $mutation $bad; Reject { Assert-ExpansionStandardOperations $bound $bound.root $bad @{} } }
    Reject { Assert-ExpansionStandardOperations $bound $bound.root @() @{} }
    foreach ($nestedId in $bound.nested.Keys) {
        $readOperation=@(@{properties=@{provisioningState='Succeeded';provisioningOperation='Read';targetResource=@{id=$nestedId;resourceType='Microsoft.Resources/deployments'}}})
        $readWrites=@{}
        Assert-ExpansionStandardOperations $bound $bound.root $readOperation $readWrites; Check ($readWrites.Count -eq 0)
        foreach ($mutation in @({param($value) $value[0].properties.targetResource.id+='-foreign'},{param($value) $value[0].properties.targetResource.resourceType='Microsoft.Network/privateEndpoints'},{param($value) $value[0].properties.provisioningState='Running'})) {
            $bad=Read-ExpansionStandardCopy $readOperation; & $mutation $bad
            Reject { Assert-ExpansionStandardOperations $bound $bound.root $bad @{} }
        }
    }
    & {
        $environmentFoundation=Read-ExpansionStandardCopy $foundation
        $environmentFoundation.subscription=$prefix; $environmentFoundation.stem=$stem; $environmentFoundation.groupA="$prefix/resourceGroups/rg-$stem-case-a"
        $environmentFoundation.root="$prefix/providers/Microsoft.Resources/deployments/$stem-expansion-foundation"
        $environmentFoundation.diagnostic="$($environmentFoundation.accountB)/providers/Microsoft.Insights/diagnosticSettings/metrics-only"
        $environmentSeal=@{output=@{verifiedAt=[DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')}}
        $environmentRoots=@(Get-FoundationRootIds $fixture)+@($environmentFoundation.root)
        $environmentMode=@{group=$environmentFoundation.groupB;account=$environmentFoundation.accountB;name='PolicyDeployment_12345';state='Failed';operationState='Failed';operation='Create';hasEffects=$false;time=[DateTimeOffset]::UtcNow.AddDays(-2).ToString('o');type='Microsoft.CognitiveServices/accounts/providers/diagnosticSettings'}
        function Read-FoundationArm {
            param($State,$Id,$Api,[switch]$List,$Query)
            $externalId="$($environmentMode.group)/providers/Microsoft.Resources/deployments/$($environmentMode.name)"
            $target=if ($environmentMode.type -ceq 'Microsoft.AlertsManagement/smartDetectorAlertRules') { "$($environmentMode.group)/providers/Microsoft.AlertsManagement/smartDetectorAlertRules/automatic-alert" } else { "$($environmentMode.account)/providers/Microsoft.Insights/diagnosticSettings/automatic-diagnostics" }
            if ($environmentMode.group -ieq $environmentFoundation.integration -or $environmentMode.component) {
                $component=if ($environmentMode.component) { $environmentMode.component } else { 'integration' }
                $target="$($environmentMode.group)/providers/Microsoft.AlertsManagement/smartDetectorAlertRules/Failure Anomalies - appi-$stem-$component$($environmentMode.targetSuffix)"
            }
            $external=@{id=$externalId;name=$environmentMode.name;properties=@{mode='Incremental';provisioningState=$environmentMode.state;timestamp=$environmentMode.time}}
            if ($Id -ieq $externalId) { return $external }
            if ($Id -ieq "$externalId/operations") { return @(@{id="$Id/one";properties=@{provisioningState=$environmentMode.operationState;provisioningOperation=$environmentMode.operation;targetResource=@{id=$target;resourceType=$environmentMode.type}}}) }
            if ($Id -iin $environmentRoots) { throw 'Deployment inventory must replace redundant point reads' }
            if ($List -and $Id -like '*/providers/Microsoft.Resources/deployments') {
                $entries=@(foreach ($rootId in $environmentRoots) { if ($rootId.StartsWith("$Id/",[StringComparison]::OrdinalIgnoreCase) -and -not $environmentMode.omitRoot) { @{id=$rootId;name=($rootId -split '/')[-1];properties=@{provisioningState=$(if ($environmentMode.rootState) { $environmentMode.rootState } else { 'Succeeded' });mode='Incremental'}} } })
                if ($Id -ieq "$($environmentMode.group)/providers/Microsoft.Resources/deployments") { $entries+=@($external); if ($environmentMode.duplicate) { $entries+=@($external) } }
                return $entries
            }
            if ($Id -like '*/resources' -or $Id -like '*/diagnosticSettings') { if ($environmentMode.hasEffects) { return @(@{id=$target}) }; return @() }
            if ($List) { return @() }
            throw 'Unexpected environment fixture read'
        }
        $environmentResult=Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{}
        Check ($environmentResult.environmentEvents.Count -eq 1 -and $environmentResult.environmentEvents[0].targetAbsent -eq $true)
        foreach ($spec in @(@('state','Running'),@('operationState','Succeeded'),@('operation','Delete'),@('hasEffects',$true),@('name','UnknownDeployment'),@('omitRoot',$true),@('duplicate',$true),@('rootState','Running'))) {
            $saved=$environmentMode[$spec[0]]; $environmentMode[$spec[0]]=$spec[1]
            Reject { Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{} }
            $environmentMode[$spec[0]]=$saved
        }
        $environmentMode.type='Microsoft.AlertsManagement/smartDetectorAlertRules'; $environmentMode.name='Failure-Anomalies-Alert-Rule-Deployment-12345'
        $environmentResult=Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{}
        Check ($environmentResult.environmentEvents.Count -eq 1)
        $environmentMode.group=$environmentFoundation.groupA; $environmentMode.account=$environmentFoundation.accountA
        $environmentResult=Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{}
        Check ($environmentResult.environmentEvents.Count -eq 1)
        $environmentMode.time=[DateTimeOffset]::UtcNow.ToString('o')
        Reject { Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{} }
        $environmentMode.time=$null
        Reject { Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{} }
        $environmentMode.group="$prefix/resourceGroups/rg-$stem-models"; $environmentMode.account="$($environmentMode.group)/providers/Microsoft.CognitiveServices/accounts/aif-$stem-models-$suffix"
        $environmentSeal.manifest=@{baseline=@{}}; $environmentSeal.manifest.baseline[$environmentMode.account]=@{id=$environmentMode.account}
        $environmentMode.type='Microsoft.CognitiveServices/accounts/providers/diagnosticSettings'; $environmentMode.name='PolicyDeployment_12345'; $environmentMode.time=[DateTimeOffset]::UtcNow.AddDays(-2).ToString('o')
        $environmentResult=Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{}
        Check ($environmentResult.environmentEvents.Count -eq 1 -and $environmentResult.environmentEvents[0].targetAbsent -eq $true)
        foreach ($spec in @(@('state','Running'),@('operationState','Succeeded'),@('hasEffects',$true),@('account',"$($environmentMode.account)-foreign"),@('time',[DateTimeOffset]::UtcNow.ToString('o')))) {
            $saved=$environmentMode[$spec[0]]; $environmentMode[$spec[0]]=$spec[1]
            Reject { Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{} }
            $environmentMode[$spec[0]]=$saved
        }
        $environmentSeal.manifest.baseline=@{}
        Reject { Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{} }
        $environmentMode.group=$environmentFoundation.integration; $environmentMode.name='Failure-Anomalies-Alert-Rule-Deployment-c1de8755'; $environmentMode.type='Microsoft.AlertsManagement/smartDetectorAlertRules'
        $environmentSeal.manifest.baseline["$($environmentFoundation.integration)/providers/Microsoft.Insights/components/appi-$stem-integration"]=@{}
        $environmentResult=Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{}
        Check ($environmentResult.environmentEvents.Count -eq 1 -and $environmentResult.environmentEvents[0].targetAbsent -eq $true)
        foreach ($spec in @(@('state','Succeeded'),@('operationState','Succeeded'),@('operation','Delete'),@('hasEffects',$true),@('targetSuffix','-foreign'),@('name','Failure-Anomalies-Alert-Rule-Deployment-nothex00'),@('time',[DateTimeOffset]::UtcNow.ToString('o')))) {
            $saved=$environmentMode[$spec[0]]; $environmentMode[$spec[0]]=$spec[1]
            Reject { Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{} }
            $environmentMode[$spec[0]]=$saved
        }
        $environmentSeal.manifest.baseline=@{}
        Reject { Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{} }
        $environmentMode.group=$environmentFoundation.groupA; $environmentMode.component='case-a'; $environmentMode.name='Failure-Anomalies-Alert-Rule-Deployment-49cd8907'
        $environmentSeal.manifest.baseline["$($environmentFoundation.groupA)/providers/Microsoft.Insights/components/appi-$stem-case-a"]=@{}
        $environmentResult=Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{}
        Check ($environmentResult.environmentEvents.Count -eq 1 -and $environmentResult.environmentEvents[0].targetAbsent -eq $true)
        $environmentMode.component='integration'
        Reject { Get-ExpansionStandardIdle $fixture $environmentFoundation $bound $environmentSeal @{} }
    }
    & {
        $workflowState=Read-ExpansionStandardCopy $fixture
        $workflowPath=Join-Path $fixtureRoot 'original.json'
        foreach ($spec in @(@('cosmosNetwork','standard-cosmos-network.evidence.json'),@('gatewayPolicy','gateway-policy-update.evidence.json'))) {
            $evidencePath=Join-Path $fixtureRoot $spec[1]; Write-StandardJson $evidencePath @{synthetic=$true}
            $workflowState.standard[$spec[0]].evidence=@{path=$evidencePath;sha256=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash}
        }
        Write-StandardJson $workflowPath $workflowState
        $workflowSha=(Get-FileHash -LiteralPath $workflowPath -Algorithm SHA256).Hash
        $workflowFoundation=Read-ExpansionStandardCopy $foundation
        $workflowFoundation.subscription=$prefix; $workflowFoundation.stem=$stem; $workflowFoundation.groupA="$prefix/resourceGroups/rg-$stem-case-a"
        $workflowFoundation.root="$prefix/providers/Microsoft.Resources/deployments/$stem-expansion-foundation"
        $workflowFoundation.projects=@($receipt.foundation.projects | ForEach-Object { $_.resourceId }); $workflowFoundation.new=@{}; $workflowFoundation.nested=@{}
        $workflowBaseline=@{'synthetic-original-preservation'=@{original=$true}}
        foreach ($name in @('outputs.json','standard-outputs.json','activate.parameters.json')) { Write-StandardJson (Join-Path $fixtureRoot $name) @{synthetic=$true} }
        $workflowInputs=Get-FoundationInputHashes $workflowState $workflowPath
        $workflowOutput=Read-ExpansionStandardCopy $receipt
        $workflowOutput.foundation.stage='foundation-only'; $workflowOutput.foundation.completeLab=$false; $workflowOutput.foundation.caseBAccountId=$workflowFoundation.accountB; $workflowOutput.foundation.resourceGroupId=$workflowFoundation.groupB
        $workflowOutput.originalSha=$workflowSha; $workflowOutput.controlPlaneVerified=$true; $workflowOutput.inferenceVerified=$false; $workflowOutput.baselineHash=Get-FoundationHash $workflowBaseline
        $workflowOutput.environmentEvents=@(); $workflowOutput.validatorRevision=@{}; $workflowOutput.validationSourceHashes=@{historical='old-sources-not-current'}; $workflowOutput.verifiedAt=[DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        $foundationPaths=Get-FoundationPaths $workflowState
        Write-StandardJson $foundationPaths.outputs $workflowOutput
        $workflowSeal=@{pending=$false;verified=$true;completedStages=@('foundation');originalSha=$workflowSha;scopeHash=(Get-FoundationHash $workflowFoundation);deploymentId=$workflowFoundation.root;baseline=$workflowBaseline;outputHash=(Get-FileHash -LiteralPath $foundationPaths.outputs -Algorithm SHA256).Hash;review=@{inputHashes=$workflowInputs;authorization=@{approved=$true;originalSha=$workflowSha;scopeHash=(Get-FoundationHash $workflowFoundation)};baselineHash=(Get-FoundationHash $workflowBaseline);sourceHashes=@{old='historical'}}}
        Write-StandardJson $foundationPaths.state $workflowSeal
        Assert-ExpansionStandardSeal $workflowSeal $workflowOutput $workflowInputs $workflowFoundation $workflowSeal.outputHash; Check $true
        foreach ($mutation in @({param($value) $value.pending=$true},{param($value) $value.verified='true'},{param($value) $value.originalSha='wrong'},{param($value) $value.outputHash='wrong'},{param($value) $value.baseline.extra=$true},{param($value) $value.review.inputHashes.state='wrong'})) { $bad=Read-ExpansionStandardCopy $workflowSeal; & $mutation $bad; Reject { Assert-ExpansionStandardSeal $bad $workflowOutput $workflowInputs $workflowFoundation $workflowSeal.outputHash } }
        $workflowPaths=Get-ExpansionStandardPaths $workflowState 'a-test'
        $workflowBinding=Get-ExpansionStandardBinding $workflowState $workflowFoundation $workflowOutput 'a-test' $testCompiler $workflowPaths
        $workflowResources=@{}
        foreach ($id in $workflowBinding.new.Keys) {
            $resource=Read-ExpansionStandardCopy $workflowBinding.specs[$id].resource; $resource.properties.provisioningState='Succeeded'
            if ($workflowBinding.new[$id] -ceq 'cosmos') { $resource.location='Sweden Central'; $resource.properties.locations[0].locationName='Sweden Central' }
            if ($workflowBinding.new[$id] -ceq 'search') { $resource.identity.principalId='77777777-7777-4777-8777-777777777777'; $resource.identity.tenantId=$workflowState.tenantId }
            if ($workflowBinding.new[$id] -ceq 'endpoint') { $resource.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState=@{status='Approved'} }
            $workflowResources[$id]=$resource
        }
        $workflowMode=@{submitted=$false;failSubmit=$true;rootState='Succeeded';calls=0;submits=0;baselineCalls=0;wrongMI=$false;extraNested=$false;listIncomplete=$false;wrongContext=$false;sourceRevision=0}
        $workflowGroups=Read-ExpansionStandardCopy $groupFixtures
        function Get-FoundationBinding { param($State,$Lab,$Compiler) Assert-FoundationOriginal $State; return $workflowFoundation }
        function Get-FoundationLive { param($State,$Lab,$Standard,$Activation,$Binding,[switch]$After) Check ($State.minimalPrompt -eq $true -and $State.resourceGroups.Count -eq 3 -and $After); $workflowMode.baselineCalls++; return $workflowBaseline }
        function Confirm-FoundationOutputs { param($State,$Binding,$Output) Assert-FoundationEqual $Output $workflowOutput.foundation }
        $workflowSourceHashes=Get-ExpansionStandardSources
        function Get-ExpansionStandardSources { $result=$workflowSourceHashes.Clone(); if ($workflowMode.sourceRevision) { $result['synthetic-source-change']=$workflowMode.sourceRevision }; return $result }
        function Get-ExpansionStandardBinding { param($State,$Foundation,$Receipt,$Selector,$Compiler,$Paths) if ($Selector -cne 'a-test') { throw 'Unexpected test selector' }; return $workflowBinding }
        function Invoke-LabAz {
            param($State,$Arguments,$Label)
            $workflowMode.calls++
            Check ($State.runDirectory -ceq $workflowPaths.evidence -and $State.azureConfigDirectory -ceq $workflowState.azureConfigDirectory -and $State.minimalPrompt -eq $true -and $State.resourceGroups.Count -eq 3)
            if (($Arguments -join ' ') -match '(?i)login|register|list-keys|delete|cloudshell') { throw 'Forbidden transport operation in offline test' }
            if ($Arguments[0] -ceq 'account') { return @{id=$(if ($workflowMode.wrongContext) { 'wrong' } else { $workflowState.subscriptionId });tenantId=$workflowState.tenantId;state='Enabled'} }
            if ($Arguments[0] -ceq 'deployment') {
                if ($Arguments[2] -ceq 'what-if') {
                    Check ('FullResourcePayloads' -cin $Arguments)
                    return @{status='Succeeded';changes=@(foreach ($id in $workflowBinding.new.Keys) { @{resourceId=$id;changeType='Create';after=(Read-ExpansionStandardCopy $workflowBinding.specs[$id].resource)} })}
                }
                if ($Arguments[2] -ceq 'create') {
                    $intent=Read-FoundationJson $workflowPaths.state
                    Check ($intent.pending -eq $true -and $intent.verified -eq $false -and $intent.deploymentId -ceq $workflowBinding.root -and '--no-wait' -cin $Arguments)
                    $workflowMode.submits++; $workflowMode.submitted=$true
                    if ($workflowMode.failSubmit) { throw 'Simulated submit transport failure' }; return
                }
                throw 'Unexpected deployment command'
            }
            if ($Arguments[0] -cne 'rest' -or $Arguments[2] -cne 'get' -or $Arguments.Count -ne 7) { throw 'Unexpected offline transport command' }
            $url=[uri]$Arguments[4]; $id=$url.AbsolutePath
            if ($id -ieq "$prefix/resourceGroups") { return @{value=$workflowGroups} }
            if ($id -ieq $workflowBinding.account -or $id -ieq $workflowBinding.projectId) {
                return @{id=$id;type=$(if ($id -ieq $workflowBinding.account) { 'Microsoft.CognitiveServices/accounts' } else { 'Microsoft.CognitiveServices/accounts/projects' });location='swedencentral';tags=$workflowGroups[0].tags;identity=@{type='SystemAssigned';principalId=$(if ($workflowMode.wrongMI) { '88888888-8888-4888-8888-888888888888' } else { $workflowBinding.principal });tenantId=$workflowState.tenantId};properties=@{provisioningState='Succeeded';publicNetworkAccess='Disabled';disableLocalAuth=$true;networkInjections=@(@{scenario='agent';subnetArmId=$workflowBinding.agentSubnet;useMicrosoftManagedNetwork=$false})}}
            }
            if ($id -ieq $workflowBinding.output.subnetId) { return @{id=$id;properties=@{privateEndpointNetworkPolicies='NetworkSecurityGroupEnabled';networkSecurityGroup=@{id="$($workflowFoundation.integration)/providers/Microsoft.Network/networkSecurityGroups/nsg-$stem-endpoints"}}} }
            if ($id -ieq $workflowBinding.agentSubnet) { return @{id=$id;properties=@{delegations=@(@{properties=@{serviceName='Microsoft.App/environments'}})}} }
            if ($id -iin $workflowBinding.output.dnsZoneIds.Values) { return @{id=$id;type='Microsoft.Network/privateDnsZones';tags=$workflowGroups[0].tags;properties=@{}} }
            if ($id -like '*/virtualNetworkLinks') {
                $linkName=if ($id -ilike '*/privatelink.blob.core.windows.net/virtualNetworkLinks') { 'lab-only' } else { 'standard-lab-only' }
                return @{value=@(@{id="$id/$linkName";type='Microsoft.Network/privateDnsZones/virtualNetworkLinks';tags=$workflowGroups[0].tags;properties=@{virtualNetwork=@{id=$workflowFoundation.vnet};registrationEnabled=$false;provisioningState='Succeeded'}})}
            }
            if ($id -like '*/resources' -or $id -like '*/connections') {
                if ($workflowMode.listIncomplete) { return @{value=@();nextLink='next-page'} }
                return @{value=@()}
            }
            if ($id -like '*/providers/Microsoft.Authorization/roleAssignments') {
                $scope=$id.Substring(0,$id.Length-('/providers/Microsoft.Authorization/roleAssignments').Length)
                return @{value=@(if ($workflowMode.submitted) { foreach ($roleId in $workflowBinding.roles.Keys) { if ($scope -ieq $prefix -or $workflowBinding.roles[$roleId].scope -ieq $scope) { $workflowResources[$roleId] } } })}
            }
            if ($workflowResources.ContainsKey($id)) { return $workflowResources[$id] }
            $isRoot=$id -ieq $workflowBinding.root
            $baseRoots=@(Get-FoundationRootIds $workflowState)+@($workflowFoundation.root)
            if ($id -iin $baseRoots) { throw 'Deployment inventory must replace redundant point reads' }
            if ($id -like '*/operations') {
                $parent=$id.Substring(0,$id.Length-11)
                if ($parent -iin $baseRoots) { return @{value=@()} }
                $targets=if ($parent -ieq $workflowBinding.root) { @("$($workflowBinding.group)/providers/Microsoft.Resources/deployments/$($workflowBinding.name)") } elseif ($parent -ieq "$($workflowBinding.group)/providers/Microsoft.Resources/deployments/$($workflowBinding.name)") { @($workflowBinding.new.Keys)+@($workflowBinding.nested.Keys | Where-Object { $_ -ine $parent }) } else { @() }
                $operations=@(foreach ($targetId in $targets) { @{id="$id/$([guid]::NewGuid())";properties=@{provisioningState='Succeeded';provisioningOperation='Create';targetResource=@{id=$targetId;resourceType=$(if ($workflowBinding.nested.ContainsKey($targetId)) { 'Microsoft.Resources/deployments' } else { $workflowBinding.specs[$targetId].resource.type })}}} })
                if (-not $operations.Count) { $operations=@(@{id="$id/output";properties=@{provisioningState='Succeeded';provisioningOperation='EvaluateDeploymentOutput'}}) }
                return @{value=$operations}
            }
            if ($id -like '*/providers/Microsoft.Resources/deployments') {
                $items=@(foreach ($rootId in $baseRoots) { if ($rootId.StartsWith("$id/",[StringComparison]::OrdinalIgnoreCase)) { @{id=$rootId;name=($rootId -split '/')[-1];properties=@{mode='Incremental';provisioningState='Succeeded'}} } })
                if ($workflowMode.submitted) {
                    foreach ($deploymentId in @($workflowBinding.root)+@($workflowBinding.nested.Keys)) { if ($deploymentId.StartsWith("$id/",[StringComparison]::OrdinalIgnoreCase)) { $items+=@{id=$deploymentId;name=($deploymentId -split '/')[-1];properties=@{mode='Incremental';provisioningState=$workflowMode.rootState}} } }
                }
                if ($workflowMode.extraNested -and $id.StartsWith($workflowBinding.group+'/')) { $items+=@{id="$id/unknown";name='unknown';properties=@{provisioningState='Succeeded'}} }
                return @{value=$items}
            }
            if ($isRoot -or $workflowBinding.nested.ContainsKey($id)) {
                $reportedParameters=Read-ExpansionStandardCopy $workflowBinding.parameters
                foreach ($key in $reportedParameters.Keys) { $reportedParameters[$key].type='String' }
                return @{id=$id;properties=@{mode='Incremental';provisioningState=$workflowMode.rootState;parameters=$reportedParameters;outputs=@{standard=@{value=$workflowBinding.output}}}}
            }
            throw "Unexpected fixture GET: $id"
        }
        Invoke-ExpansionStandard $workflowPath 'a-test' 'Preview' $testCompiler $true
        $reviewed=Read-FoundationJson $workflowPaths.state
        Check ($reviewed.pending -eq $false -and $reviewed.verified -eq $false -and $workflowMode.submits -eq 0)
        $workflowMode.sourceRevision=1
        Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Deploy' $testCompiler $true }; $workflowMode.sourceRevision=0
        $bad=Read-ExpansionStandardCopy $reviewed; $bad.review.checkedAt=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o'); Write-StandardJson $workflowPaths.state $bad
        Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Deploy' $testCompiler $true }; Write-StandardJson $workflowPaths.state $reviewed
        $savedTemplate=[IO.File]::ReadAllBytes($workflowPaths.template); [IO.File]::AppendAllText($workflowPaths.template,' ')
        Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Deploy' $testCompiler $true }; [IO.File]::WriteAllBytes($workflowPaths.template,$savedTemplate)
        $workflowMode.wrongMI=$true; Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Deploy' $testCompiler $true }; $workflowMode.wrongMI=$false
        $workflowMode.listIncomplete=$true; Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Deploy' $testCompiler $true }; $workflowMode.listIncomplete=$false
        $workflowMode.extraNested=$true; Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Deploy' $testCompiler $true }; $workflowMode.extraNested=$false
        $externalLock=[IO.File]::Open($workflowPaths.lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Deploy' $testCompiler $true } } finally { $externalLock.Dispose() }
        Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Deploy' $testCompiler $true }
        Check ($workflowMode.submits -eq 1 -and (Read-FoundationJson $workflowPaths.state).pending -eq $true)
        Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Deploy' $testCompiler $true }
        Check ($workflowMode.submits -eq 1)
        foreach ($status in @('Failed','Canceled','Running')) { $workflowMode.rootState=$status; Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Status' $testCompiler $false }; Check ((Read-FoundationJson $workflowPaths.state).pending -eq $true) }
        $workflowMode.rootState='Succeeded'; $workflowMode.wrongContext=$true
        Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Status' $testCompiler $false }; $workflowMode.wrongContext=$false
        $revisionKey='scripts/Invoke-ExpansionStandard.ps1'
        $revisionArchive=Join-Path $fixtureRoot "standard-a-test-validator-submitted/$revisionKey"
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($revisionArchive))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionStandard.ps1') -Destination $revisionArchive -Force
        $workflowSourceHashes[$revisionKey]='synthetic-current-validator-hash'
        $pendingBeforeRevision=Read-FoundationJson $workflowPaths.state
        $reviewBeforeRevision=Get-FoundationHash $pendingBeforeRevision.review
        Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Status' $testCompiler $false }
        Invoke-ExpansionStandard $workflowPath 'a-test' 'Status' $testCompiler $false $true
        $completed=Read-FoundationJson $workflowPaths.state; $completedOutput=Read-FoundationJson $workflowPaths.outputs
        Check ((Get-FoundationHash $completed.review) -ceq $reviewBeforeRevision)
        Check ($completedOutput.validatorRevision.Count -eq 1 -and $completedOutput.validatorRevision[$revisionKey].current -ceq $workflowSourceHashes[$revisionKey])
        Check ($completed.pending -eq $false -and $completed.verified -eq $true -and $completedOutput.controlPlaneVerified -eq $true -and $completedOutput.inferenceVerified -eq $false -and $completedOutput.dnsTlsVerified -eq $false)
        Check ($completed.outputHash -ceq (Get-FileHash -LiteralPath $workflowPaths.outputs -Algorithm SHA256).Hash)
        Check ($workflowSha -ceq (Get-FileHash -LiteralPath $workflowPath -Algorithm SHA256).Hash)
        Check ($workflowMode.baselineCalls -ge 4 -and $workflowMode.submits -eq 1)
        Reject { Invoke-ExpansionStandard $workflowPath 'a-test' 'Preview' $testCompiler $true }
        Assert-FoundationEqual (Read-FoundationJson $foundationPaths.state) $workflowSeal; Check $true
        Write-Output "Mocked workflow: $($workflowMode.calls) transport calls; $($workflowMode.submits) submission; $($workflowMode.baselineCalls) original-baseline checks."
    }
    Write-Output "PASS: $($checks.count) offline dependencies checks."
} finally {
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    $timer.Stop(); Write-Output ('elapsed: {0:N3}s' -f $timer.Elapsed.TotalSeconds)
}