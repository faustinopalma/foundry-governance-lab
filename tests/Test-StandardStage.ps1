[CmdletBinding()]
param()
$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    $scriptPath = Join-Path $PSScriptRoot '../scripts/Invoke-StandardStage.ps1'
    $tokens = $null; $errors = $null
    $harnessAst = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors.Message -join '; ') }
    . $scriptPath -DefinitionsOnly
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabExecution.psm1')
    $checks = 0
    function Check([bool]$Condition) { if (-not $Condition) { throw 'Assertion failed' }; $script:checks++ }
    function Reject([scriptblock]$Probe) { $rejected = $false; try { & $Probe } catch { $rejected = $true }; Check $rejected }
    function Fixture {
        $state = @{subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'; ownershipId='33333333-3333-4333-8333-333333333333'; labId='sample01'; phase='activate'; minimalPrompt=$true; privateAccessVerified=$true; deploymentAuthorized=$true; pendingPhase=$null; preexistingGroupIds=@(); resourceGroups=@('models','integration','case-a') | ForEach-Object { "rg-fgl-sample01-$_" }; standard=@{completedStages=@(); pendingStage=$null; deploymentNames=@{}; review=$null}}
        return $state
    }
    $state = Fixture
    Assert-StandardState $state 'dependencies' 'Preview'; Check $true
    foreach ($mutation in @({param($value) $value.minimalPrompt=$false}, {param($value) $value.deploymentAuthorized='true'}, {param($value) $value.privateAccessVerified=$false}, {param($value) $value.pendingPhase='activate'}, {param($value) $value.phase='lock'}, {param($value) $value.standard.completedStages=@('account')}, {param($value) $value.standard.pendingStage='dependencies'}, {param($value) $value.standard.deploymentNames.account='wrong'})) {
        $state = Fixture; & $mutation $state; Reject { Assert-StandardState $state 'dependencies' 'Deploy' }
    }
    $state = Fixture
    $prefix = "/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01"
    $binding = @{casePrefix="$prefix-case-a"; integration="$prefix-integration"; accountId="$prefix-case-a/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-a-abcdefghijklm"; parameters=@{accountName=@{value='aif-fgl-sample01-a-abcdefghijklm'}; projectPrincipalId=@{value='44444444-4444-4444-8444-444444444444'}; workspaceId=@{value='55555555-5555-4555-8555-555555555555'}}}
    $binding.projectId = "$($binding.accountId)/projects/case-a-dev"; $binding.subnet = "$prefix-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01/subnets/snet-agent-a"
    $implicit = @{id="$($binding.accountId)/capabilityHosts/$($binding.parameters.accountName.value)@aml_aiagentservice"; properties=@{capabilityHostKind='Agents'; provisioningState='Succeeded'; customerSubnet=$binding.subnet}}
    Assert-StandardHosts $state $binding 'account' @($implicit) @() 'stfglsample01abcdef'; Check $true
    Assert-StandardHosts $state $binding 'account' @() @() 'stfglsample01abcdef'; Check $true
    $implicit.properties.customerSubnet += '-foreign'; Reject { Assert-StandardHosts $state $binding 'account' @($implicit) @() 'stfglsample01abcdef' }; $implicit.properties.customerSubnet = $binding.subnet
    Reject { Assert-StandardHosts $state $binding 'project' @() @() 'stfglsample01abcdef' }
    Reject { Assert-StandardHosts $state $binding 'account' @($implicit,$implicit) @() 'stfglsample01abcdef' }
    Reject { Assert-StandardHosts $state $binding 'project' @($implicit) @(@{id='unexpected'}) 'stfglsample01abcdef' }
    Reject { Assert-StandardGroups $state @() }; Reject { Assert-StandardTerminal $state @() @{} }
    $storageId = "$prefix-case-a/providers/Microsoft.Storage/storageAccounts/stfglsample01abcdef"
    $resource = @{id=$storageId; tags=@{'fgl-owner'=$state.ownershipId; 'fgl-lab'=$state.labId}; properties=@{publicNetworkAccess='Disabled';allowSharedKeyAccess=$false}}
    $change = @{resourceId=$storageId; changeType='Create'; after=$resource}
    $result = @{status='Succeeded'; changes=@($change)}
    Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef'; Check $true
    foreach ($type in @('Delete','Unsupported','Deploy','Ignore')) { $change.changeType=$type; Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' } }
    $change.changeType='Modify'; $change.before=$resource
    Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef'; Check $true
    $change.before=@{id=$storageId}; Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }
    foreach ($id in @($binding.accountId,$binding.projectId,"$prefix-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01","$storageId/unknown/child")) { $change.resourceId=$id; Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' } }
    Reject { Assert-StandardWhatIf $state $binding 'dependencies' @{status='Succeeded';changes=@()} 'stfglsample01abcdef' }
    $groups = @($state.resourceGroups | ForEach-Object { @{name=$_; id="/subscriptions/$($state.subscriptionId)/resourceGroups/$_";tags=@{'fgl-owner'=$state.ownershipId;'fgl-lab'=$state.labId}} })
    Assert-StandardGroups $state $groups; Check $true
    Reject { Assert-StandardGroups $state @($groups[0],$groups[0],$groups[1]) }
    $groups[0].tags['fgl-owner']='foreign'; Reject { Assert-StandardGroups $state $groups }; $groups[0].tags['fgl-owner']=$state.ownershipId
    $roots = @('bootstrap','lock','activate' | ForEach-Object { @{name="fgl-sample01-$_"; id="/subscriptions/$($state.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-sample01-$_"; properties=@{provisioningState='Succeeded'}} })
    $nested = @{}; foreach ($group in $state.resourceGroups) { $nested[$group]=@(@{name='nested';id="/subscriptions/$($state.subscriptionId)/resourceGroups/$group/providers/Microsoft.Resources/deployments/nested";properties=@{provisioningState='Succeeded'}}) }
    Assert-StandardTerminal $state $roots $nested; Check $true
    $roots[0].properties.provisioningState='Running'; Reject { Assert-StandardTerminal $state $roots $nested }; $roots[0].properties.provisioningState='Succeeded'
    $nested[$state.resourceGroups[0]][0].properties.provisioningState='Accepted'; Reject { Assert-StandardTerminal $state $roots $nested }; $nested[$state.resourceGroups[0]][0].properties.provisioningState='Succeeded'
    $state.standard.deploymentNames.dependencies='fgl-sample01-standard-dependencies'; Reject { Assert-StandardTerminal $state $roots $nested }; $state.standard.deploymentNames=@{}
    $nested[$state.resourceGroups[0]]=@(); Reject { Assert-StandardTerminal $state $roots $nested }
    $lab = @{minimalPrompt=$true;resourceGroups=$state.resourceGroups;models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-abcdefghijklm";gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-abcdefghijklm";cases=@(@{accountId=$binding.accountId;registryId='';projects=@(@{resourceId=$binding.projectId;principalId=$binding.parameters.projectPrincipalId.value})})}
    $account = @{id=$binding.accountId;kind='AIServices';location='swedencentral';tags=$resource.tags;properties=@{provisioningState='Succeeded';publicNetworkAccess='Disabled';networkInjections=@(@{scenario='agent';subnetArmId=$binding.subnet;useMicrosoftManagedNetwork=$false})}}
    $project = @{id=$binding.projectId;tags=$resource.tags;identity=@{principalId=$binding.parameters.projectPrincipalId.value};properties=@{provisioningState='Succeeded';internalId=$binding.parameters.workspaceId.value}}
    $gateway = @{id=$lab.gateway;tags=$resource.tags;properties=@{provisioningState='Succeeded';publicNetworkAccess='Disabled'}}
    $actualBinding = Get-StandardBindings $state $lab $account $project $gateway
    Check ($actualBinding.parameters.accountName.value -ceq $binding.parameters.accountName.value -and $actualBinding.parameters.workspaceId.value -ceq $project.properties.internalId)
    Check ($actualBinding.parameters.Count -eq 8 -and $actualBinding.parameters.agentContainerName.value -ceq '')
    $project.properties.internalId = $project.properties.internalId.Replace('-', '')
    $compactBinding = Get-StandardBindings $state $lab $account $project $gateway
    Check ($compactBinding.parameters.workspaceId.value -ceq $project.properties.internalId -and $compactBinding.parameters.workspaceId.value.Length -eq 32)
    $project.properties.internalId = $binding.parameters.workspaceId.value
    foreach ($mutation in @({param($value) $value.project.identity.principalId='invalid'}, {param($value) $value.project.identity.principalId='66666666-6666-4666-8666-666666666666'}, {param($value) $value.project.properties.internalId=[guid]::Empty.ToString()}, {param($value) $value.account.id+='foreign'}, {param($value) $value.gateway.properties.publicNetworkAccess='Enabled'}, {param($value) $value.account.properties.networkInjections[0].subnetArmId+='foreign'}, {param($value) $value.project.properties.provisioningState=$true})) {
        $fixture = @{account=$account;project=$project;gateway=$gateway} | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        & $mutation $fixture; Reject { Get-StandardBindings $state $lab $fixture.account $fixture.project $fixture.gateway }
    }
    $state.standard.accountHostId=$implicit.id; $state.standard.completedStages=@('dependencies','account')
    $state.standard.deploymentNames.dependencies='fgl-sample01-standard-dependencies'
    Assert-StandardState $state 'project' 'Deploy'; Check $true
    $projectHost = @{id="$($binding.projectId)/capabilityHosts/agents";properties=@{provisioningState='Succeeded';storageConnections=@('stfglsample01abcdef');vectorStoreConnections=@('srch-fgl-sample01-standard');threadStorageConnections=@('cosmos-fgl-sample01-standard')}}
    Assert-StandardHosts $state $binding 'access' @($implicit) @($projectHost) 'stfglsample01abcdef'; Check $true
    $projectHost.properties.storageConnections += 'foreign'; Reject { Assert-StandardHosts $state $binding 'access' @($implicit) @($projectHost) 'stfglsample01abcdef' }; $projectHost.properties.storageConnections=@('stfglsample01abcdef')
    Reject { Assert-StandardHosts $state $binding 'project' @($implicit) @($projectHost) 'stfglsample01abcdef' }
    $change = @{resourceId=$storageId;changeType='Create';after=$resource}; $result.changes=@($change)
    $ignore = @{resourceId=$binding.accountId;changeType='Ignore';before=$account}
    $result.changes=@($change,$ignore); Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef'; Check $true
    $ignore.delta=@(@{path='properties';propertyChangeType='Modify'}); Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }; $ignore.Remove('delta')
    $result.changes=@($ignore); Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }
    $ignore.changeType=$true; Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }
    $roleId="$storageId/providers/Microsoft.Authorization/roleAssignments/66666666-6666-4666-8666-666666666666"
    $role = @{id=$roleId;properties=@{principalId=$binding.parameters.projectPrincipalId.value;principalType='ServicePrincipal';roleDefinitionId="/subscriptions/$($state.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/17d1049b-9a84-46fb-8f53-869881c3d3ab"}}
    $result.changes=@(@{resourceId=$roleId;changeType='Create';after=$role}); Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef'; Check $true
    $role.properties.Remove('principalType'); Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef'; Check $true
    $role.properties.principalType='User'; Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }; $role.properties.principalType='ServicePrincipal'
    $role.properties.scope='/'; Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }; $role.properties.Remove('scope')
    $role.properties.principalId='foreign'; Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }
    $result.changes=@(@{resourceId="$($binding.projectId)/capabilityHosts/agents";changeType='Modify';after=$projectHost}); Reject { Assert-StandardWhatIf $state $binding 'project' $result 'stfglsample01abcdef' }
    $endpointId="$prefix-case-a/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-standard-blob"
    $endpoint=@{id=$endpointId;tags=$resource.tags;properties=@{subnet=@{id="$prefix-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01/subnets/snet-case-a-pe"};privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$storageId;groupIds=@('blob')}})}}
    $result.changes=@(@{resourceId=$endpointId;changeType='Create';after=$endpoint}); Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef'; Check $true
    $endpoint.properties.subnet.id+='foreign'; Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }
    $connectionId="$($binding.projectId)/connections/stfglsample01abcdef"
    $connection=@{id=$connectionId;properties=@{metadata=@{ResourceId=$storageId};authType='AAD';isSharedToAll=$false}}
    $result.changes=@(@{resourceId=$connectionId;changeType='Create';after=$connection}); Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef'; Check $true
    $connection.properties.metadata.ResourceId+='foreign'; Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }
    $deploymentId="$prefix-case-a/providers/Microsoft.Resources/deployments/fgl-sample01-standard-dependencies"
    $nestedChange=@{resourceId=$deploymentId;changeType='Modify';after=@{id=$deploymentId;properties=@{mode='Incremental'}}}
    $state.standard.deploymentNames=@{}; $result.changes=@(@{resourceId=$storageId;changeType='Create';after=$resource},$nestedChange)
    Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }
    foreach ($forbidden in @("$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-abcdefghijklm","$prefix-integration/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net","$prefix-models/providers/Microsoft.Storage/storageAccounts/stfglsample01abcdef")) {
        $result.changes=@(@{resourceId=$forbidden;changeType='Modify';before=$resource;after=$resource}); Reject { Assert-StandardWhatIf $state $binding 'dependencies' $result 'stfglsample01abcdef' }
    }
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "standard-stage-$([guid]::NewGuid().ToString('N'))"
    $null = [IO.Directory]::CreateDirectory($fixtureRoot)
    try {
        $templatePath=Join-Path $fixtureRoot 'template.json'; $parametersPath=Join-Path $fixtureRoot 'parameters.json'
        $actualBinding.parameters.stage=@{value='dependencies'}
        Check ($actualBinding.parameters.Count -eq 9)
        Write-StandardJson $templatePath @{resources=@()}; Write-StandardJson $parametersPath @{parameters=$actualBinding.parameters}
        $review=@{stage='dependencies';checkedAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');templateHash=(Get-FileHash $templatePath).Hash;parametersHash=(Get-FileHash $parametersPath).Hash}
        Assert-StandardReview $review 'dependencies' $templatePath $parametersPath $actualBinding.parameters; Check $true
        $review.checkedAt=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o'); Reject { Assert-StandardReview $review 'dependencies' $templatePath $parametersPath $actualBinding.parameters }
        Assert-StandardReview $review 'dependencies' $templatePath $parametersPath $actualBinding.parameters -Submitted; Check $true
        $review.checkedAt=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o'); Reject { Assert-StandardReview $review 'dependencies' $templatePath $parametersPath $actualBinding.parameters }
        $review.checkedAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        foreach ($key in $actualBinding.parameters.Keys) {
            $altered=$actualBinding.parameters | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable; $altered[$key].value='foreign'
            Reject { Assert-StandardReview $review 'dependencies' $templatePath $parametersPath $altered }
        }
        Write-StandardJson $templatePath @{resources=@('changed')}; Reject { Assert-StandardReview $review 'dependencies' $templatePath $parametersPath $actualBinding.parameters }
        $review.templateHash=(Get-FileHash $templatePath).Hash; Write-StandardJson $parametersPath @{parameters=@{}}
        Reject { Assert-StandardReview $review 'dependencies' $templatePath $parametersPath $actualBinding.parameters }
    } finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    $responses=@{value=@()}
    function Invoke-LabAz { param($State,$Arguments,$Label) if ($Arguments[0] -ne 'rest' -or $Arguments[2] -ne 'get') { throw 'Offline harness forbids mutation' }; return $responses }
    Check (@(Read-StandardArm $state "$($binding.projectId)/capabilityHosts" '2026-05-01' 'fixture' -List).Count -eq 0)
    $responses=@{}; Reject { Read-StandardArm $state "$($binding.projectId)/capabilityHosts" '2026-05-01' 'fixture' -List }
    $responses=@{value=@();nextLink='more'}; Reject { Read-StandardArm $state "$($binding.projectId)/capabilityHosts" '2026-05-01' 'fixture' -List }
    & {
        $containerRoot = "$storageId/blobServices/default/containers"
        $workspace = ([guid]$compactBinding.parameters.workspaceId.value).ToString('D')
        $blobName = "$workspace-azureml-blobstore"; $agentName = "$workspace-abcdef123456-azureml-agent"
        $dependencyFixture = @{labId=$state.labId;ownershipId=$state.ownershipId;accountId=$binding.accountId;projectId=$binding.projectId;projectPrincipalId=$project.identity.principalId;workspaceId=$compactBinding.parameters.workspaceId.value;storage=@{name='stfglsample01abcdef';id=$storageId}}
        $storageFixture = @{id=$storageId;type='Microsoft.Storage/storageAccounts';tags=$resource.tags;properties=@{provisioningState='Succeeded';publicNetworkAccess='Disabled';allowSharedKeyAccess=$false;allowBlobPublicAccess=$false}}
        $listFixture = @{value=@($blobName,$agentName | ForEach-Object { @{name=$_;id="$containerRoot/$_";type='Microsoft.Storage/storageAccounts/blobServices/containers'} })}
        function Invoke-LabAz {
            param($State,$Arguments,$Label)
            if ($Arguments[0] -ne 'rest' -or $Arguments[2] -ne 'get') { throw 'Offline discovery forbids mutation' }
            if ($Arguments[4] -ceq "https://management.azure.com${storageId}?api-version=2023-05-01") { return $storageFixture }
            if ($Arguments[4] -ceq "https://management.azure.com${containerRoot}?api-version=2023-05-01") { return $listFixture }
            throw 'Unexpected discovery URL'
        }
        Check ((Resolve-StandardContainers $state $compactBinding $dependencyFixture) -ceq $agentName -and $agentName.Length -eq 63)
        $baselineList = $listFixture | ConvertTo-Json -Depth 20
        foreach ($mutation in @(
            { param($value) $value.value=@() },
            { param($value) $value.value=@($value.value[0]) },
            { param($value) $value.value=@($value.value[1]) },
            { param($value) $value.value += $value.value[1] },
            { param($value) $value.value += $value.value[0] },
            { param($value) $value.value=$value.value[0] },
            { param($value) $value.nextLink='https://management.azure.com/next' },
            { param($value) $value.nextLink=$false },
            { param($value) $value.value[1].type='Microsoft.Storage/storageAccounts' },
            { param($value) $value.value[1].id=$value.value[1].id.Replace('stfglsample01abcdef','stfglsample01fedcba') },
            { param($value) $value.value[1].name=$value.value[1].name.Replace('55555555','66666666'); $value.value[1].id="$containerRoot/$($value.value[1].name)" },
            { param($value) $value.value[1].name=$value.value[1].name.Replace('abcdef123456','ABCDEF123456'); $value.value[1].id="$containerRoot/$($value.value[1].name)" },
            { param($value) $value.value[1].name=$value.value[1].name.Replace('abcdef123456','abc123'); $value.value[1].id="$containerRoot/$($value.value[1].name)" },
            { param($value) $value.value += @{name="$workspace-azureml-agent";id="$containerRoot/$workspace-azureml-agent";type='Microsoft.Storage/storageAccounts/blobServices/containers'} }
        )) {
            $listFixture = $baselineList | ConvertFrom-Json -AsHashtable; & $mutation $listFixture
            Reject { Resolve-StandardContainers $state $compactBinding $dependencyFixture }
        }
        $listFixture = $baselineList | ConvertFrom-Json -AsHashtable
        $listFixture.value[1].name="$workspace-azureml-agent"; $listFixture.value[1].id="$containerRoot/$workspace-azureml-agent"
        Check ((Resolve-StandardContainers $state $compactBinding $dependencyFixture) -ceq "$workspace-azureml-agent")
        $storageFixture.properties.allowSharedKeyAccess=$true; Reject { Resolve-StandardContainers $state $compactBinding $dependencyFixture }; $storageFixture.properties.allowSharedKeyAccess=$false
        $storageFixture.tags=@{'fgl-owner'='foreign';'fgl-lab'=$state.labId}; Reject { Resolve-StandardContainers $state $compactBinding $dependencyFixture }; $storageFixture.tags=$resource.tags
        foreach ($key in @('accountId','projectId','projectPrincipalId','workspaceId')) {
            $altered = $dependencyFixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable; $altered[$key]='foreign'
            Reject { Resolve-StandardContainers $state $compactBinding $altered }
        }
        $accessBinding=$compactBinding | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $accessBinding.parameters.agentContainerName.value=$agentName
        $accessRoleId="$containerRoot/$agentName/providers/Microsoft.Authorization/roleAssignments/66666666-6666-4666-8666-666666666666"
        $accessWhatIf=@{status='Succeeded';changes=@(@{resourceId=$accessRoleId;changeType='Create';after=@{id=$accessRoleId;properties=@{principalId=$project.identity.principalId;roleDefinitionId="/subscriptions/$($state.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/b7e6dc6d-f1e8-4753-8033-0f276bb0955b"}}})}
        Assert-StandardWhatIf $state $accessBinding 'access' $accessWhatIf 'stfglsample01abcdef'; Check $true
        $accessWhatIf.changes[0].resourceId=$accessRoleId.Replace('abcdef123456','123456abcdef'); $accessWhatIf.changes[0].after.id=$accessWhatIf.changes[0].resourceId
        Reject { Assert-StandardWhatIf $state $accessBinding 'access' $accessWhatIf 'stfglsample01abcdef' }
        $accessBinding.parameters.agentContainerName.value=''; Reject { Assert-StandardWhatIf $state $accessBinding 'access' $accessWhatIf 'stfglsample01abcdef' }
        $storageFixture.properties.provisioningState=$true; Reject { Resolve-StandardContainers $state $compactBinding $dependencyFixture }; $storageFixture.properties.provisioningState='Succeeded'
        $storageFixture.properties.publicNetworkAccess=$true; Reject { Resolve-StandardContainers $state $compactBinding $dependencyFixture }; $storageFixture.properties.publicNetworkAccess='Disabled'
        $liveState=$state | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $liveState.runDirectory=Join-Path ([IO.Path]::GetTempPath()) 'standard-discovery-memory-only'
        $liveProject=$project | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $liveProject.properties.internalId=$compactBinding.parameters.workspaceId.value
        $discoveryReads=@{outputs=0;lists=0;urls=[Collections.Generic.List[string]]::new()}
        function Confirm-LabRunContext { return $groups }
        function Get-Content {
            param($LiteralPath,[switch]$Raw)
            if ($LiteralPath -cne (Join-Path $liveState.runDirectory 'standard-outputs.json')) { throw 'Unexpected offline file read' }
            $discoveryReads.outputs++
            return (@{dependencies=$dependencyFixture} | ConvertTo-Json -Depth 20)
        }
        function Invoke-LabAz {
            param($State,$Arguments,$Label)
            if ($Arguments[0] -ne 'rest' -or $Arguments[2] -ne 'get') { throw 'Offline binding forbids mutation' }
            $discoveryReads.urls.Add($Arguments[4])
            switch ($Label) {
                'standard-account' { return $account }
                'standard-project' { return $liveProject }
                'standard-gateway' { return $gateway }
                'standard-container-storage' { return $storageFixture }
                'standard-containers' { $discoveryReads.lists++; return $listFixture }
                default { throw 'Unexpected live binding read' }
            }
        }
        $listFixture=$baselineList | ConvertFrom-Json -AsHashtable
        $beforeProject=Get-StandardLiveBindings $liveState $lab
        Check ($beforeProject.parameters.agentContainerName.value -ceq '' -and $discoveryReads.outputs -eq 0 -and $discoveryReads.lists -eq 0)
        $liveState.standard.completedStages += 'project'
        $firstLive=Get-StandardLiveBindings $liveState $lab
        Check ($firstLive.parameters.agentContainerName.value -ceq $agentName -and $firstLive.parameters.workspaceId.value -ceq $compactBinding.parameters.workspaceId.value)
        $listFixture.value[1].name=$agentName.Replace('abcdef123456','123456abcdef'); $listFixture.value[1].id="$containerRoot/$($listFixture.value[1].name)"
        $secondLive=Get-StandardLiveBindings $liveState $lab
        Check ($secondLive.parameters.agentContainerName.value -ceq $listFixture.value[1].name -and $secondLive.parameters.agentContainerName.value -cne $firstLive.parameters.agentContainerName.value -and $discoveryReads.outputs -eq 2 -and $discoveryReads.lists -eq 2)
        Check (@($discoveryReads.urls | Where-Object { $_ -ceq "https://management.azure.com${containerRoot}?api-version=2023-05-01" }).Count -eq 2)
    }
    $entrypoint = [scriptblock]::Create('param([string]$PSScriptRoot)' + "`n" + (($harnessAst.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text }) -join "`n"))
    function Invoke-OfflineLifecycle([string]$SelectedStage, [string]$SelectedAction, [string]$Status = 'Succeeded', [switch]$SubmitFails, [switch]$AgentChanges) {
        $simulation = @{state=(Fixture);calls=[Collections.Generic.List[string]]::new();status=$Status;submitFails=[bool]$SubmitFails;savedPending=$null;bindingReads=0;agentChanges=[bool]$AgentChanges}
        $simulation.state.runDirectory=Join-Path ([IO.Path]::GetTempPath()) "standard-lifecycle-$([guid]::NewGuid().ToString('N'))"
        $null = [IO.Directory]::CreateDirectory($simulation.state.runDirectory)
        try {
            $StatePath=Join-Path $simulation.state.runDirectory 'state.json'; $Stage=$SelectedStage; $Action=$SelectedAction; $DefinitionsOnly=$false
            $simulation.binding=$actualBinding | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            $simulation.binding.parameters.stage.value=$Stage
            if ($Stage -eq 'access') { $simulation.binding.parameters.agentContainerName.value='55555555-5555-4555-8555-555555555555-abcdef123456-azureml-agent' }
            $simulation.output=@{labId=$simulation.state.labId;ownershipId=$simulation.state.ownershipId;stage=$Stage;accountId=$binding.accountId;projectId=$binding.projectId;projectPrincipalId=$project.identity.principalId;workspaceId=$project.properties.internalId;storage=@{name='stfglsample01abcdef';id=$storageId};capabilityHosts=@{account="$($binding.accountId)/capabilityHosts/agents"}}
            if ($Stage -eq 'account') { $simulation.state.standard.completedStages=@('dependencies'); $simulation.state.standard.deploymentNames.dependencies='fgl-sample01-standard-dependencies' }
            if ($Stage -eq 'access') { $simulation.state.standard.completedStages=@('dependencies','account','project'); foreach ($done in @('dependencies','project')) { $simulation.state.standard.deploymentNames[$done]="fgl-sample01-standard-$done" }; $simulation.state.standard.accountHostId=$implicit.id }
            if ($Action -eq 'Status') { $simulation.state.standard.pendingStage=$Stage; $simulation.state.standard.deploymentNames[$Stage]="fgl-sample01-standard-$Stage" }
            $templatePath=Join-Path $simulation.state.runDirectory "standard-$Stage.template.json"; $parametersPath=Join-Path $simulation.state.runDirectory "standard-$Stage.parameters.json"
            Write-StandardJson $templatePath @{resources=@()}; Write-StandardJson $parametersPath @{parameters=$simulation.binding.parameters}
            $simulation.state.standard.review=@{stage=$Stage;checkedAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');templateHash=(Get-FileHash $templatePath).Hash;parametersHash=(Get-FileHash $parametersPath).Hash;storageName='stfglsample01abcdef';reusedHostId=$(if ($Stage -eq 'account') { $implicit.id } else { $null })}
            $originalPath=Join-Path $simulation.state.runDirectory 'outputs.json'; Write-StandardJson $originalPath $lab
            $originalHash=(Get-FileHash $originalPath).Hash
            Write-StandardJson (Join-Path $simulation.state.runDirectory 'standard-outputs.json') @{dependencies=$simulation.output}
            function Import-Module {}
            function Read-LabRun { return $simulation.state }
            function Save-LabRun { param($State,$StatePath) $simulation.savedPending=$State.standard.pendingStage; $simulation.calls.Add('save') }
            function Get-StandardLiveBindings {
                $simulation.bindingReads++
                if ($simulation.agentChanges -and $simulation.bindingReads -eq 2) { $simulation.binding.parameters.agentContainerName.value=$simulation.binding.parameters.agentContainerName.value.Replace('abcdef123456','123456abcdef') }
                return $simulation.binding
            }
            function Confirm-StandardIdle { $simulation.calls.Add('idle') }
            function Confirm-StandardPrerequisites { param($State,$Binding,$SelectedStage,$StorageName,[switch]$Reconcile) $simulation.calls.Add('prerequisites'); if ($SelectedStage -eq 'account') { return $implicit.id } }
            function Invoke-LabAz {
                param($State,$Arguments,$Label)
                $simulation.calls.Add($Label)
                switch ($Label) {
                    'standard-validate' { return @{status='Succeeded'} }
                    'standard-whatif' {
                        if ($Stage -eq 'access') {
                            $roleId="$storageId/blobServices/default/containers/$($simulation.binding.parameters.agentContainerName.value)/providers/Microsoft.Authorization/roleAssignments/66666666-6666-4666-8666-666666666666"
                            return @{status='Succeeded';changes=@(@{resourceId=$roleId;changeType='Create';after=@{id=$roleId;properties=@{principalId=$project.identity.principalId;roleDefinitionId="/subscriptions/$($State.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/b7e6dc6d-f1e8-4753-8033-0f276bb0955b"}}})}
                        }
                        return @{status='Succeeded';changes=@(@{resourceId=$storageId;changeType='Create';after=$resource})}
                    }
                    'standard-start' { Check ($Arguments -contains '--no-wait' -and $simulation.savedPending -ceq $Stage -and $State.standard.deploymentNames[$Stage] -ceq "fgl-sample01-standard-$Stage"); if ($simulation.submitFails) { throw 'Simulated submission failure' }; return }
                    'standard-status' { return @{id="/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-sample01-standard-$Stage";properties=@{provisioningState=$simulation.status;outputs=@{standard=@{value=$simulation.output}}}} }
                    'standard-failed-operations' { return @() }
                    'standard-failed-nested' { return @() }
                    default { throw "Offline harness forbids unexpected command: $Label" }
                }
            }
            $failed=$false; try { $null = & $entrypoint (Split-Path $scriptPath) } catch { if (-not $simulation.submitFails -and $simulation.status -ne 'Failed' -and -not ($simulation.agentChanges -and $_.Exception.Message -ceq 'Parameter binding changed: agentContainerName')) { throw }; $failed=$true }
            Check ($failed -eq ($simulation.submitFails -or $simulation.status -eq 'Failed' -or $simulation.agentChanges))
            Check ($simulation.state.phase -ceq 'activate' -and -not $simulation.state.pendingPhase -and (Get-FileHash $originalPath).Hash -ceq $originalHash)
            if ($simulation.agentChanges) { Check ($simulation.bindingReads -eq 2 -and 'standard-start' -cnotin $simulation.calls -and 'save' -cnotin $simulation.calls -and -not $simulation.state.standard.pendingStage) }
            elseif ($Action -eq 'Status' -and $Status -eq 'Succeeded') { Check ($Stage -cin $simulation.state.standard.completedStages -and -not $simulation.state.standard.pendingStage) }
            elseif ($Stage -eq 'account') { Check ($simulation.state.standard.accountHostId -ceq $implicit.id -and 'account' -cin $simulation.state.standard.completedStages -and -not @($simulation.calls | Where-Object { $_ -like 'standard-*' }).Count -and -not $simulation.state.standard.deploymentNames.ContainsKey('account')) }
            else { Check ($simulation.state.standard.pendingStage -ceq $Stage -and $Stage -cnotin $simulation.state.standard.completedStages) }
            if ($Status -eq 'Failed') { Check ('standard-failed-operations' -cin $simulation.calls) }
            if ($Stage -eq 'dependencies' -and $Action -eq 'Deploy') { Check (@($simulation.calls | Where-Object { $_ -eq 'idle' }).Count -eq 2) }
        } finally { Remove-Item -LiteralPath $simulation.state.runDirectory -Recurse -Force }
    }
    Invoke-OfflineLifecycle 'dependencies' 'Deploy'
    Invoke-OfflineLifecycle 'dependencies' 'Deploy' -SubmitFails
    Invoke-OfflineLifecycle 'dependencies' 'Status'
    Invoke-OfflineLifecycle 'dependencies' 'Status' 'Failed'
    Invoke-OfflineLifecycle 'dependencies' 'Status' 'Running'
    Invoke-OfflineLifecycle 'account' 'Deploy'
    Invoke-OfflineLifecycle 'access' 'Deploy'
    Invoke-OfflineLifecycle 'access' 'Deploy' -AgentChanges
    Invoke-OfflineLifecycle 'access' 'Status'
    Write-Output "Standard stage offline checks passed: $checks"
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }