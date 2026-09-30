[CmdletBinding()]
param([string]$BicepExecutable = 'bicep')

$ErrorActionPreference = 'Stop'
$fixtureScript = Join-Path $PSScriptRoot '../scripts/Update-LabGatewayPolicy.ps1'
$fixtureModule = Join-Path $PSScriptRoot '../infra/modules/gateway-policy-update.bicep'
$fixturePolicyPath = Join-Path $PSScriptRoot '../infra/policies/inference.xml'
$fixtureTestPath = $PSCommandPath
Import-Module (Join-Path $PSScriptRoot '../scripts/LabExecution.psm1')
Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1')
. (Join-Path $PSScriptRoot '../scripts/Invoke-StandardStage.ps1') -DefinitionsOnly
. (Join-Path $PSScriptRoot '../scripts/Test-StandardPrivate.ps1') -DefinitionsOnly
. (Join-Path $PSScriptRoot '../scripts/Invoke-StandardCosmosNetwork.ps1') -DefinitionsOnly
. $fixtureScript -DefinitionsOnly
$checks = @{count=0}
function Check([bool]$Condition) { if (-not $Condition) { throw 'Gateway policy assertion failed' }; $checks.count++ }
function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed }
function Clone($Value) { return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 }
function Invoke-LabAz { throw 'Offline test forbids Azure' }

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "gateway-policy-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($fixtureRoot)
try {
    $fixtureState = @{subscriptionId='11111111-1111-4111-8111-111111111111';tenantId='22222222-2222-4222-8222-222222222222';ownershipId='33333333-3333-4333-8333-333333333333';labId='sample01';phase='activate';pendingPhase=$null;minimalPrompt=$true;privateAccessVerified=$true;deploymentAuthorized=$true;preexistingGroupIds=@();resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" });runDirectory=$fixtureRoot;azureConfigDirectory=(Join-Path $fixtureRoot 'az');bicepExecutable=$BicepExecutable;standard=@{completedStages=@('dependencies','account','project','access');pendingStage=$null;deploymentNames=@{dependencies='fgl-sample01-standard-dependencies';project='fgl-sample01-standard-project';access='fgl-sample01-standard-access'}}}
    $fixtureNetwork = Get-CosmosNetworkNames $fixtureState
    $fixtureState.standard.cosmosNetwork = @{name=$fixtureNetwork.name;group=$fixtureNetwork.group;ruleId=$fixtureNetwork.ruleId;pending=$false;verified=$true;review=@{}}
    $fixtureNames = Get-GatewayPolicyNames $fixtureState
    $fixturePrefix = "/subscriptions/$($fixtureState.subscriptionId)/resourceGroups/rg-fgl-sample01"
    $fixtureSuffix = 'abc123def456g'
    $fixtureAccount = "$fixturePrefix-case-a/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-a-$fixtureSuffix"
    $fixtureProject = "$fixtureAccount/projects/case-a-dev"
    $fixtureModel = "$fixturePrefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-$fixtureSuffix"
    $fixtureGateway = "$fixturePrefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-$fixtureSuffix"
    $fixtureCaller = "$fixturePrefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-sample01-client"
    $fixtureProjectPrincipal = '44444444-4444-4444-8444-444444444444'
    $fixtureCallerPrincipal = '55555555-5555-4555-8555-555555555555'
    $fixtureGatewayPrincipal = '66666666-6666-4666-8666-666666666666'
    $fixtureTags = @{'fgl-owner'=$fixtureState.ownershipId;'fgl-lab'=$fixtureState.labId}
    $fixtureLab = @{phase='activate';minimalPrompt=$true;resourceGroups=$fixtureState.resourceGroups;models=$fixtureModel;gateway=$fixtureGateway;runner="$fixturePrefix-integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner";cases=@(@{accountId=$fixtureAccount;registryId='';projects=@(@{name='case-a-dev';resourceId=$fixtureProject;principalId=$fixtureProjectPrincipal})});identities=@()}
    foreach ($actor in @('dev-a','consumer-a','dev-b','publisher-a','publisher-b','client','denied')) { $fixtureLab.identities += @{actor=$actor;resourceId="$fixturePrefix-integration/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-sample01-$actor";principalId=$fixtureCallerPrincipal;clientId=$fixtureProjectPrincipal} }
    $fixtureActivation = @{parameters=@{phase=@{value='activate'};minimalPrompt=@{value=$true};labId=@{value=$fixtureState.labId};ownershipId=@{value=$fixtureState.ownershipId};gatewayPrincipalId=@{value=$fixtureGatewayPrincipal}}}
    $fixtureResources = @{}
    foreach ($spec in @(@('account',$fixtureAccount,'Microsoft.CognitiveServices/accounts'),@('project',$fixtureProject,'Microsoft.CognitiveServices/accounts/projects'),@('model',$fixtureModel,'Microsoft.CognitiveServices/accounts'),@('gateway',$fixtureGateway,'Microsoft.ApiManagement/service'),@('caller',$fixtureCaller,'Microsoft.ManagedIdentity/userAssignedIdentities'))) {
        $fixtureResources[$spec[0]] = @{id=$spec[1];type=$spec[2];location='swedencentral';kind='AIServices';tags=(Clone $fixtureTags);properties=@{provisioningState='Succeeded';publicNetworkAccess='Disabled'}}
    }
    $fixtureResources.account.properties.networkInjections = @(@{scenario='agent';subnetArmId="$fixturePrefix-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01/subnets/snet-agent-a";useMicrosoftManagedNetwork=$false})
    $fixtureResources.project.properties.internalId = $fixtureProjectPrincipal
    $fixtureResources.project.identity = @{type='SystemAssigned';principalId=$fixtureProjectPrincipal;tenantId=$fixtureState.tenantId}
    $fixtureResources.gateway.identity = @{type='SystemAssigned';principalId=$fixtureGatewayPrincipal;tenantId=$fixtureState.tenantId}
    $fixtureResources.caller.properties += @{principalId=$fixtureCallerPrincipal;clientId=$fixtureProjectPrincipal;tenantId=$fixtureState.tenantId}
    $fixtureResources.model.properties.customSubDomainName = ($fixtureModel -split '/')[-1]
    $fixtureRole = @{id="$fixtureModel/providers/Microsoft.Authorization/roleAssignments/$fixtureProjectPrincipal";properties=@{scope=$fixtureModel;principalId=$fixtureGatewayPrincipal;principalType='ServicePrincipal';roleDefinitionId="/subscriptions/$($fixtureState.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"}}
    $fixtureBinding = Get-GatewayPolicyBinding $fixtureState $fixtureLab $fixtureActivation $fixtureResources @($fixtureRole)
    Check ($fixtureBinding.parameters.allowedPrincipalIds.value.Count -eq 2 -and $fixtureBinding.parameters.allowedPrincipalIds.value[0] -ceq $fixtureProjectPrincipal -and $fixtureBinding.parameters.allowedPrincipalIds.value[1] -ceq $fixtureCallerPrincipal)
    Assert-GatewayPolicyState $fixtureState 'Preview'; Check $true
    foreach ($mutation in @({param($value) $value.minimalPrompt=$false},{param($value) $value.pendingPhase='activate'},{param($value) $value.standard.completedStages=@('dependencies')},{param($value) $value.standard.pendingStage='access'},{param($value) $value.standard.cosmosNetwork.verified='true'},{param($value) $value.standard.cosmosNetwork.pending=$true})) {
        $value=Clone $fixtureState; & $mutation $value; Reject { Assert-GatewayPolicyState $value 'Preview' }
    }
    foreach ($mutation in @({param($value) $value.gateway.properties.publicNetworkAccess='Enabled'},{param($value) $value.account.properties.provisioningState='Updating'},{param($value) $value.model.id+='foreign'},{param($value) $value.model.tags['fgl-owner']=$fixtureProjectPrincipal},{param($value) $value.project.identity.principalId=$fixtureCallerPrincipal},{param($value) $value.caller.properties.tenantId=$fixtureProjectPrincipal})) {
        $value=Clone $fixtureResources; & $mutation $value; Reject { Get-GatewayPolicyBinding $fixtureState $fixtureLab $fixtureActivation $value @($fixtureRole) }
    }
    $fixtureSource = Get-Content -LiteralPath $fixturePolicyPath -Raw
    $fixturePair = Get-GatewayPolicyPair $fixtureSource $fixtureBinding
    $fixtureBefore = @{id=$fixtureBinding.policyId;name='policy';type='Microsoft.ApiManagement/service/apis/policies';properties=@{format='rawxml';value=$fixturePair.before}}
    $fixtureAfter = Clone $fixtureBefore; $fixtureAfter.properties.value=$fixturePair.after
    Assert-GatewayPolicyDocument $fixtureBefore $fixtureBinding.policyId $fixturePair.before; Check $true
    Assert-GatewayPolicyDocument $fixtureAfter $fixtureBinding.policyId $fixturePair.after; Check $true
    $value=Clone $fixtureBefore; $value.properties.format='xml'; Assert-GatewayPolicyDocument $value $fixtureBinding.policyId $fixturePair.before; Check $true
    $value.properties.format='xml-link'; Reject { Assert-GatewayPolicyDocument $value $fixtureBinding.policyId $fixturePair.before }
    Check ($fixturePair.before.Contains('body["stream"] = false;') -and -not $fixturePair.before.Contains('stream_options') -and $fixturePair.after.Contains('body.Remove("stream_options")'))
    Reject { Get-GatewayPolicyPair ($fixtureSource.Replace('body["max_tokens"] = 256;','body["max_tokens"] = 257;')) $fixtureBinding }
    $value=Clone $fixtureBefore; $value.properties.value=$value.properties.value.Replace('calls="20"','calls="21"'); Reject { Assert-GatewayPolicyDocument $value $fixtureBinding.policyId $fixturePair.before }
    Reject { ConvertTo-GatewayPolicyXml '<!DOCTYPE policies [<!ENTITY external SYSTEM "file:///missing">]><policies>&external;</policies>' }
    $fixtureLive = @{binding=$fixtureBinding;pair=$fixturePair;policyHash=(Get-CosmosNetworkHash $fixtureBefore);policy=$fixtureBefore}
    $fixtureWhatIf = @{status='Succeeded';changes=@(@{resourceId=$fixtureBinding.policyId;changeType='Modify';before=$fixtureBefore;after=$fixtureAfter;delta=@(@{path='properties.value';propertyChangeType='Modify';before=$fixturePair.before;after=$fixturePair.after})})}
    Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $fixtureWhatIf; Check $true
    $value=Clone $fixtureWhatIf
    $encoded=[xml]$fixturePair.before
    foreach ($node in $encoded.SelectNodes('//@* | //set-body/text()')) { if ($node.Value.StartsWith('@{') -or $node.Value.StartsWith('@(')) { $node.Value=[Net.WebUtility]::HtmlEncode($node.Value) } }
    $value.changes[0].before.properties.format='xml'
    $value.changes[0].before.properties.value=$encoded.OuterXml
    $value.changes[0].delta[0].before=$encoded.OuterXml
    $value.changes[0].delta+=@{path='properties.format';propertyChangeType='Modify';before='xml';after='rawxml'}
    Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value; Check $true
    foreach ($delta in $value.changes[0].delta) { $delta.children=$null }
    Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value; Check $true
    $value.changes[0].delta[0].children=@(@{path='unexpected'}); Reject { Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value }
    $value.changes[0].delta[0].children=@()
    $value.changes[0].delta[1].children=@(@{path='unexpected'}); Reject { Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value }
    $value.changes[0].delta[1].children=@()
    $value.changes[0].delta[1].after='xml-link'; Reject { Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value }
    $value=Clone $fixtureWhatIf; $value.changes+=@{resourceId=$fixtureGateway;changeType='Ignore';before=(Clone $fixtureResources.gateway)}
    Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value; Check $true
    $value.changes[1].after=Clone $fixtureResources.gateway
    Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value; Check $true
    $value.changes[1].after.properties.publicNetworkAccess='Enabled'; Reject { Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value }
    $value=Clone $fixtureWhatIf
    $summary=@{id=$fixtureGateway;type='Microsoft.ApiManagement/service';name='synthetic';tags=(Clone $fixtureTags)}
    $value.changes+=@{resourceId=$fixtureGateway;changeType='Ignore';before=$summary;after=(Clone $summary);delta=@()}
    Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value; Check $true
    $value.changes[1].after.tags['fgl-owner']=$fixtureProjectPrincipal; Reject { Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value }
    $value.changes[1].after=Clone $summary
    $value.changes[1].delta=@(@{path='tags';propertyChangeType='Modify'}); Reject { Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value }
    $value.changes[1].delta=@()
    $value.changes[1].before.id+='foreign'; Reject { Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value }
    foreach ($mutation in @({param($value) $value.changes[0].changeType='Create'},{param($value) $value.changes[0].changeType='NoChange'},{param($value) $value.changes[0].resourceId=$fixtureGateway},{param($value) $value.changes+=$value.changes[0]},{param($value) $value.changes[0].delta[0].path='properties.format'},{param($value) $value.changes[0].after.properties.value=$fixturePair.before})) {
        $value=Clone $fixtureWhatIf; & $mutation $value; Reject { Assert-GatewayPolicyWhatIf $fixtureState $fixtureLive $value }
    }
    $fixturePaths = Get-GatewayPolicyPaths $fixtureState
    & $BicepExecutable build $fixtureModule --outfile $fixturePaths.template
    if ($LASTEXITCODE -ne 0) { throw 'Local Bicep compile failed' }
    $fixtureCompiled = Get-Content -LiteralPath $fixturePaths.template -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-GatewayPolicyTemplate $fixtureCompiled $fixtureSource; Check $true
    $value=Clone $fixtureCompiled
    foreach ($key in $value.parameters.Keys) { $value.parameters[$key].type=if ($key -ceq 'allowedPrincipalIds') { 'Array' } else { 'String' } }
    Assert-GatewayPolicyTemplate $value $fixtureSource; Check $true
    $value.parameters.gatewayName.type='SecureString'; Reject { Assert-GatewayPolicyTemplate $value $fixtureSource }
    foreach ($mutation in @({param($value) $value.resources=@()},{param($value) $value.parameters.gatewayName.defaultValue='foreign'},{param($value) $value.variables.callerIds=$true},{param($value) $value.variables.tenantPolicy='foreign'},{param($value) $value.outputs=@{extra=@{type='string';value='foreign'}}})) {
        $value=Clone $fixtureCompiled; & $mutation $value; Reject { Assert-GatewayPolicyTemplate $value $fixtureSource }
    }
    foreach ($mutation in @({param($child) $child.condition=$true},{param($child) $child.type='Microsoft.ApiManagement/service'},{param($child) $child.name='foreign'},{param($child) $child.properties.value='foreign'},{param($child) $child.dependsOn=@('foreign')})) {
        $value=Clone $fixtureCompiled
        $resources=if ($value.resources -is [Collections.IDictionary]) { @($value.resources.Values) } else { @($value.resources) }
        $child=@($resources | Where-Object type -CEQ 'Microsoft.ApiManagement/service/apis/policies')[0]
        & $mutation $child; Reject { Assert-GatewayPolicyTemplate $value $fixtureSource }
    }
    foreach ($file in @($fixtureScript,$fixtureModule,$fixtureTestPath)) { Assert-PublicText (Get-Content -LiteralPath $file -Raw); Check $true }
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($fixtureScript,[ref]$tokens,[ref]$errors); Check ($errors.Count -eq 0)
    & {
        function Import-Module { throw 'DefinitionsOnly imported dependencies' }
        function Read-LabRun { throw 'DefinitionsOnly read state' }
        function Invoke-LabAz { throw 'DefinitionsOnly called Azure' }
        & $fixtureScript -DefinitionsOnly
    }
    Check $true
    $fixtureStatePath = Join-Path $fixtureRoot 'state.json'
    Write-StandardJson (Join-Path $fixtureRoot 'outputs.json') $fixtureLab
    Write-StandardJson (Join-Path $fixtureRoot 'standard-outputs.json') @{synthetic=$true}
    Write-StandardJson (Join-Path $fixtureRoot 'activate.parameters.json') $fixtureActivation
    $fixtureRuntime = @{calls=[Collections.Generic.List[object]]::new();currentPolicy=(Clone $fixtureBefore);submitted=0;status='Running';drift=$false;failStart=$false;untracked=$false}
    function Confirm-LabRunContext($State) {
        Assert-LabContext $State @{id=$fixtureState.subscriptionId;tenantId=$fixtureState.tenantId;state='Enabled'}
        return @($fixtureState.resourceGroups | ForEach-Object { @{name=$_;id="/subscriptions/$($fixtureState.subscriptionId)/resourceGroups/$_";tags=(Clone $fixtureTags)} })
    }
    function Invoke-LabAz($State, $Arguments, $Label) {
        $fixtureRuntime.calls.Add(@{arguments=$Arguments;label=$Label})
        if ($Label -ceq 'standard-root') { return @{name=$Arguments[-1];id="/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/$($Arguments[-1])";properties=@{provisioningState='Succeeded'}} }
        if ($Label -ceq 'standard-nested') {
            $nested=@(@{name='original';id="/subscriptions/$($State.subscriptionId)/resourceGroups/$($Arguments[-1])/providers/Microsoft.Resources/deployments/original";properties=@{provisioningState='Succeeded'}})
            if ($fixtureRuntime.submitted -and $Arguments[-1] -ceq $fixtureNames.group) { $nested+=@{id=$fixtureNames.deploymentId;name=$fixtureNames.name;properties=@{provisioningState=$fixtureRuntime.status}} }
            return $nested
        }
        if ($Label -ceq 'standard-policy-activation') { return @{id="/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-$($State.labId)-activate";properties=@{mode='Incremental';provisioningState='Succeeded';outputs=@{lab=@{value=$fixtureLab}};parameters=@{gatewayPrincipalId=@{type='String';value=$fixtureGatewayPrincipal}}}} }
        foreach ($key in $fixtureResources.Keys) { if ($Label -ceq "standard-policy-$key") { return Clone $fixtureResources[$key] } }
        if ($Label -ceq 'standard-policy-roles') { return @{value=@((Clone $fixtureRole))} }
        if ($Label -ceq 'standard-policy-current') {
            Check ($Arguments[4] -ceq "https://management.azure.com$($fixtureBinding.policyId)?api-version=2024-05-01" -and $Arguments[-2] -ceq '--headers' -and $Arguments[-1] -ceq 'Accept=application/json')
            return Clone $fixtureRuntime.currentPolicy
        }
        if ($Label -ceq 'standard-policy-deployments') {
            $items=@()
            if ($fixtureRuntime.untracked -or $fixtureRuntime.submitted) { $items=@(@{id=$fixtureNames.deploymentId;name=$fixtureNames.name}) }
            return @{value=$items}
        }
        if ($Label -ceq 'standard-policy-status') {
            $parameters=Clone $fixtureBinding.parameters
            foreach ($key in $parameters.Keys) { $parameters[$key].type=if ($key -ceq 'allowedPrincipalIds') { 'Array' } else { 'String' } }
            return @{id=$fixtureNames.deploymentId;name=$fixtureNames.name;properties=@{mode='Incremental';provisioningState=$fixtureRuntime.status;parameters=$parameters}}
        }
        if ($Label -ceq 'policy-export') { return Clone $fixtureCompiled }
        if ($Label -ceq 'policy-validate') { return @{properties=@{provisioningState='Succeeded'}} }
        if ($Label -ceq 'policy-whatif') {
            if ($fixtureRuntime.drift) { $fixtureRuntime.currentPolicy.properties.value=$fixturePair.before.Replace('calls="20"','calls="21"') }
            return Clone $fixtureWhatIf
        }
        if ($Label -ceq 'policy-start') {
            $saved=Read-LabRun $fixtureStatePath
            Check ($saved.standard.gatewayPolicy.pending -and -not $saved.standard.gatewayPolicy.verified)
            Check (($Arguments[0..2] -join ' ') -ceq 'deployment group create' -and $Arguments[4] -ceq $fixtureNames.group -and $Arguments[6] -ceq $fixtureNames.name -and $Arguments[-1] -ceq '--no-wait')
            $fixtureRuntime.submitted++
            if ($fixtureRuntime.failStart) { throw 'Simulated ambiguous submission failure' }
            return
        }
        throw "Unexpected offline Azure call: $Label"
    }
    function Reset-GatewayFixture {
        $fixtureRuntime.calls.Clear(); $fixtureRuntime.currentPolicy=Clone $fixtureBefore; $fixtureRuntime.submitted=0; $fixtureRuntime.status='Running'; $fixtureRuntime.drift=$false; $fixtureRuntime.failStart=$false; $fixtureRuntime.untracked=$false
        Save-LabRun (Clone $fixtureState) $fixtureStatePath
    }
    Reset-GatewayFixture
    Invoke-LabGatewayPolicy $fixtureStatePath 'Preview'
    Check (-not (Read-LabRun $fixtureStatePath).standard.gatewayPolicy -and $fixtureRuntime.submitted -eq 0)
    $fixtureReview = Get-Content -LiteralPath $fixturePaths.review -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    foreach ($mutation in @({param($value) $value.checkedAt=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')},{param($value) $value.beforeHash='changed'},{param($value) $value.binding.parameters.allowedPrincipalIds.value+= $fixtureGatewayPrincipal})) {
        $value=Clone $fixtureReview; & $mutation $value; Reject { Assert-GatewayPolicyReview $fixtureState $value $fixtureLive $fixturePaths $fixtureModule $fixturePolicyPath }
    }
    Invoke-LabGatewayPolicy $fixtureStatePath 'Deploy'
    Check ($fixtureRuntime.submitted -eq 1)
    Invoke-LabGatewayPolicy $fixtureStatePath 'Status'
    Check ((Read-LabRun $fixtureStatePath).standard.gatewayPolicy.pending)
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Deploy' }
    $fixtureRuntime.status='Succeeded'
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Status' }
    Check (-not (Read-LabRun $fixtureStatePath).standard.gatewayPolicy.verified)
    $fixtureRuntime.currentPolicy=Clone $fixtureAfter
    Invoke-LabGatewayPolicy $fixtureStatePath 'Status'
    $verified=Read-LabRun $fixtureStatePath
    Check ($verified.standard.gatewayPolicy.verified -and -not $verified.standard.gatewayPolicy.pending -and $verified.phase -ceq 'activate' -and $verified.standard.deploymentNames.Count -eq $fixtureState.standard.deploymentNames.Count)
    Invoke-LabGatewayPolicy $fixtureStatePath 'Status'
    Check ($fixtureRuntime.submitted -eq 1)
    Reset-GatewayFixture
    $fixtureRuntime.drift=$true
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Deploy' }
    Check ($fixtureRuntime.submitted -eq 0 -and -not (Read-LabRun $fixtureStatePath).standard.gatewayPolicy)
    Reset-GatewayFixture
    $fixtureRuntime.untracked=$true
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Deploy' }
    Check ($fixtureRuntime.submitted -eq 0)
    Reset-GatewayFixture
    $fixtureRuntime.failStart=$true
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Deploy' }
    Check ($fixtureRuntime.submitted -eq 1 -and (Read-LabRun $fixtureStatePath).standard.gatewayPolicy.pending)
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Deploy' }
    $fixtureRuntime.status='Failed'
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Status' }
    Check ((Read-LabRun $fixtureStatePath).standard.gatewayPolicy.pending)
    Reset-GatewayFixture
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Attest' }
    Check (-not (Read-LabRun $fixtureStatePath).standard.gatewayPolicy)
    $fixtureRuntime.currentPolicy=Clone $fixtureAfter
    Invoke-LabGatewayPolicy $fixtureStatePath 'Attest'
    $attested=Read-LabRun $fixtureStatePath
    Check ($attested.standard.gatewayPolicy.verified -and -not $attested.standard.gatewayPolicy.pending -and $attested.standard.gatewayPolicy.review.source -ceq 'activation-policy-reuse')
    $attestation=Get-Content -LiteralPath $fixturePaths.evidence -Raw | ConvertFrom-Json -AsHashtable
    Check ($attestation.policyDeploymentSubmitted -eq $false -and -not $attestation.ContainsKey('deploymentId') -and $attestation.activationDeploymentId.EndsWith('/fgl-sample01-activate'))
    & {
        . (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionFoundation.ps1') -DefinitionsOnly
        $attested.standard.cosmosNetwork.evidence=@{}
        Assert-FoundationOriginal $attested
    }
    Check $true
    Invoke-LabGatewayPolicy $fixtureStatePath 'Status'
    Check ($fixtureRuntime.submitted -eq 0 -and @($fixtureRuntime.calls | Where-Object { $_.label -in @('policy-validate','policy-whatif','policy-start','policy-export','standard-policy-status') }).Count -eq 0)
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Deploy' }
    $fixtureRuntime.currentPolicy.properties.value=$fixturePair.after.Replace('calls="20"','calls="21"')
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Status' }
    Reset-GatewayFixture
    $fixtureRuntime.currentPolicy=Clone $fixtureAfter
    $fixtureRuntime.untracked=$true
    Reject { Invoke-LabGatewayPolicy $fixtureStatePath 'Attest' }
    Check (-not (Read-LabRun $fixtureStatePath).standard.gatewayPolicy -and $fixtureRuntime.submitted -eq 0)
    Write-Output "Gateway policy offline checks passed: $($checks.count) assertions. No Azure calls or inference."
} finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }