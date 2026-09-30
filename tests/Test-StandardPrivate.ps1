[CmdletBinding()]
param([string]$PythonExecutable = 'python')
$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    $scriptPath = Join-Path $PSScriptRoot '../scripts/Test-StandardPrivate.ps1'
    . $scriptPath -DefinitionsOnly
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot '../scripts/LabExecution.psm1')
    $checks = 0
    function Check([bool]$Condition) { if (-not $Condition) { throw 'Assertion failed' }; $script:checks++ }
    function Reject([scriptblock]$Probe) { $rejected = $false; try { $null = & $Probe } catch { $rejected = $true }; Check $rejected }
    function Clone($Value) { return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 }
    $fixtureState = @{subscriptionId='11111111-1111-4111-8111-111111111111'; tenantId='22222222-2222-4222-8222-222222222222'; ownershipId='33333333-3333-4333-8333-333333333333'; labId='sample01'; phase='activate'; minimalPrompt=$true; privateAccessVerified=$true; deploymentAuthorized=$true; pendingPhase=$null; preexistingGroupIds=@(); resourceGroups=@('models','integration','case-a' | ForEach-Object { "rg-fgl-sample01-$_" }); standard=@{completedStages=@('dependencies'); pendingStage=$null; deploymentNames=@{dependencies='fgl-sample01-standard-dependencies'}}}
    $prefix = "/subscriptions/$($fixtureState.subscriptionId)/resourceGroups/rg-fgl-sample01"
    $accountId = "$prefix-case-a/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-a-abcdefghijklm"
    $projectId = "$accountId/projects/case-a-dev"
    $vnetId = "$prefix-integration/providers/Microsoft.Network/virtualNetworks/vnet-fgl-sample01"
    $fixtureLab = @{minimalPrompt=$true; resourceGroups=$fixtureState.resourceGroups; models="$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-fgl-sample01-models-abcdefghijklm"; gateway="$prefix-integration/providers/Microsoft.ApiManagement/service/apim-fgl-sample01-abcdefghijklm"; runner="$prefix-integration/providers/Microsoft.Compute/virtualMachines/vm-fgl-sample01-runner"; cases=@(@{accountId=$accountId; registryId=''; projects=@(@{resourceId=$projectId;principalId='44444444-4444-4444-8444-444444444444'})})}
    $dependency = @{labId='sample01';ownershipId=$fixtureState.ownershipId;stage='dependencies';location='swedencentral';accountId=$accountId;projectId=$projectId;projectPrincipalId='44444444-4444-4444-8444-444444444444';workspaceId='55555555-5555-4555-8555-555555555555';projectEndpoint=('https://aif-fgl-sample01-a-abcdefghijklm.' + 'services.ai.azure.com/api/projects/case-a-dev');resourceGroups=@{caseA='rg-fgl-sample01-case-a';integration='rg-fgl-sample01-integration'};vnetId=$vnetId;subnetId="$vnetId/subnets/snet-case-a-pe";privateEndpointIds=@('blob','search','cosmos' | ForEach-Object { "$prefix-case-a/providers/Microsoft.Network/privateEndpoints/pe-fgl-sample01-standard-$_" });dnsZoneIds=@{}}
    foreach ($spec in @(@('storage','blob','stfglsample01abcdef','Microsoft.Storage/storageAccounts','blob.core.windows.net','/'),@('search','search','srch-fgl-sample01-standard','Microsoft.Search/searchServices','search.windows.net',''),@('cosmos','cosmos','cosmos-fgl-sample01-standard','Microsoft.DocumentDB/databaseAccounts','documents.azure.com',':443/'))) {
        $dependency[$spec[0]]=@{id="$prefix-case-a/providers/$($spec[3])/$($spec[2])";name=$spec[2];endpoint="https://$($spec[2]).$($spec[4])$($spec[5])"}
        $dependency.dnsZoneIds[$spec[1]]="$prefix-integration/providers/Microsoft.Network/privateDnsZones/privatelink.$($spec[4])"
    }
    $fixtureOutputs = @{dependencies=$dependency}
    $fixtureBinding = Get-StandardPrivateBinding $fixtureState $fixtureLab $fixtureOutputs
    Check ($fixtureBinding.targets.Count -eq 3)
    foreach ($mutation in @({param($value) $value.minimalPrompt=$false}, {param($value) $value.deploymentAuthorized='true'}, {param($value) $value.pendingPhase='activate'}, {param($value) $value.standard.pendingStage='account'}, {param($value) $value.standard.completedStages=@()}, {param($value) $value.standard.completedStages=@('account','dependencies')}, {param($value) $value.resourceGroups+= 'foreign'}, {param($value) $value.standard.deploymentNames.dependencies='wrong'})) {
        $value=Clone $fixtureState; & $mutation $value; Reject { Get-StandardPrivateBinding $value $fixtureLab $fixtureOutputs }
    }
    foreach ($mutation in @({param($value) $value.dependencies.storage.name='foreign'}, {param($value) $value.dependencies.storage.id=$value.dependencies.storage.id.Replace('case-a','models')}, {param($value) $value.dependencies.search.endpoint+=';id'}, {param($value) $value.dependencies.projectPrincipalId='invalid'}, {param($value) $value.dependencies.workspaceId=[guid]::Empty.ToString()}, {param($value) $value.dependencies.privateEndpointIds[0]=$value.dependencies.privateEndpointIds[1]}, {param($value) $value.dependencies.dnsZoneIds.blob+='foreign'}, {param($value) $value.dependencies.subnetId+='foreign'})) {
        $value=Clone $fixtureOutputs; & $mutation $value; Reject { Get-StandardPrivateBinding $fixtureState $fixtureLab $value }
    }
    foreach ($mutation in @({param($value) $value.models+='foreign'}, {param($value) $value.runner+='foreign'}, {param($value) $value.cases[0].projects[0].resourceId+='foreign'})) {
        $value=Clone $fixtureLab; & $mutation $value; Reject { Get-StandardPrivateBinding $fixtureState $value $fixtureOutputs }
    }
    $fixtureAddresses=@{}; $fixtureProbe=@{checks=@()}
    foreach ($index in 0..2) {
        $hostName=$fixtureBinding.targets[$index].hostName; $addresses=@("10.76.6.$($index + 4)")
        $fixtureAddresses[$hostName]=$addresses; $fixtureProbe.checks+=@{hostName=$hostName;addresses=$addresses;tls443=$true}
    }
    Assert-StandardPrivateProbe $fixtureBinding $fixtureProbe $fixtureAddresses; Check $true
    foreach ($mutation in @({param($value) $value.checks[0].addresses=@('10.76.6.99')}, {param($value) $value.checks[0].addresses+= '10.76.6.99'}, {param($value) $value.checks[0].addresses=@()}, {param($value) $value.checks[0].tls443='true'}, {param($value) $value.checks[0].tls443=$false}, {param($value) $value.checks[0].hostName=$value.checks[1].hostName}, {param($value) $value.checks=@($value.checks[0])})) {
        $value=Clone $fixtureProbe; & $mutation $value; Reject { Assert-StandardPrivateProbe $fixtureBinding $value $fixtureAddresses }
    }
    . (Join-Path $PSScriptRoot '../scripts/Invoke-StandardStage.ps1') -DefinitionsOnly
    $fixtureTags=@{'fgl-owner'=$fixtureState.ownershipId;'fgl-lab'=$fixtureState.labId}
    $fixtureArm=@{}
    foreach ($target in $fixtureBinding.targets) {
        $fixtureArm[$target.id]=@{id=$target.id;name=$target.name;tags=(Clone $fixtureTags);properties=@{provisioningState='Succeeded';publicNetworkAccess='Disabled';allowSharedKeyAccess=$false;disableLocalAuth=$true}}
        if ($target.service -eq 'search') { $fixtureArm[$target.id].properties.provisioningState='succeeded' }
        $nicId="$prefix-case-a/providers/Microsoft.Network/networkInterfaces/nic-$($target.service)"
        $fixtureArm[$target.endpointId]=@{id=$target.endpointId;tags=(Clone $fixtureTags);properties=@{provisioningState='Succeeded';subnet=@{id=$dependency.subnetId};privateLinkServiceConnections=@(@{properties=@{privateLinkServiceId=$target.id;groupIds=@($target.groupId);privateLinkServiceConnectionState=@{status='Approved'}}});networkInterfaces=@(@{id=$nicId})}}
        $fixtureArm[$nicId]=@{id=$nicId;properties=@{provisioningState='Succeeded';privateEndpoint=@{id=$target.endpointId};ipConfigurations=@(@{properties=@{privateIPAddress=$fixtureAddresses[$target.hostName][0];subnet=@{id=$dependency.subnetId};privateLinkConnectionProperties=@{groupId=$target.groupId;fqdns=@($target.hostName)}}})}}
        if ($target.service -eq 'cosmos') { $regional=Clone $fixtureArm[$nicId].properties.ipConfigurations[0]; $regional.properties.privateIPAddress='10.76.6.10'; $regional.properties.privateLinkConnectionProperties.fqdns=@('regional.' + 'documents.azure.com'); $fixtureArm[$nicId].properties.ipConfigurations += $regional }
        $fixtureArm["$($target.endpointId)/privateDnsZoneGroups"]=@{value=@(@{id="$($target.endpointId)/privateDnsZoneGroups/default";properties=@{provisioningState='Succeeded';privateDnsZoneConfigs=@(@{properties=@{privateDnsZoneId=$target.zoneId}})}})}
        $fixtureArm[$target.zoneId]=@{id=$target.zoneId;tags=(Clone $fixtureTags)}
        $linkName=if ($target.service -eq 'storage') { 'lab-only' } else { 'standard-lab-only' }
        $fixtureArm["$($target.zoneId)/virtualNetworkLinks"]=@{value=@(@{id="$($target.zoneId)/virtualNetworkLinks/$linkName";properties=@{provisioningState='Succeeded';virtualNetwork=@{id=$vnetId};registrationEnabled=$false}})}
    }
    $armResponses=Clone $fixtureArm; $armCalls=[Collections.Generic.List[string]]::new()
    function Invoke-LabAz {
        param($State,$Arguments,$Label)
        if (($Arguments[0..3] -join ',') -cne 'rest,--method,get,--url') { throw 'Offline harness forbids unexpected command' }
        $uri=[uri]$Arguments[4]; $id=$uri.AbsolutePath
        if ($uri.Host -cne 'management.azure.com' -or -not $armResponses.ContainsKey($id)) { throw 'Unexpected ARM scope' }
        $armCalls.Add($id); return $armResponses[$id]
    }
    $actualAddresses=Get-StandardPrivateAddresses $fixtureState $fixtureBinding
    Assert-StandardPrivateProbe $fixtureBinding $fixtureProbe $actualAddresses; Check ($armCalls.Count -eq 18)
    foreach ($target in $fixtureBinding.targets) {
        foreach ($mutation in @({param($value) $value.id+='foreign'}, {param($value) $value.tags['fgl-owner']='foreign'}, {param($value) $value.properties.publicNetworkAccess='Enabled'}, {param($value) $value.properties.provisioningState='Updating'}, {param($value) $value.properties.allowSharedKeyAccess=$true; $value.properties.disableLocalAuth=$false}, {param($value) $value.properties.allowSharedKeyAccess='false'; $value.properties.disableLocalAuth='true'})) {
            $armResponses=Clone $fixtureArm; & $mutation $armResponses[$target.id]; Reject { Get-StandardPrivateAddresses $fixtureState $fixtureBinding }
        }
    }
    $target=$fixtureBinding.targets[0]; $nicId="$prefix-case-a/providers/Microsoft.Network/networkInterfaces/nic-storage"
    foreach ($mutation in @({param($value) $value.properties.subnet.id+='foreign'}, {param($value) $value.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId+='foreign'}, {param($value) $value.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status='Pending'}, {param($value) $value.properties.networkInterfaces[0].id=$value.properties.networkInterfaces[0].id.Replace('case-a','models')}, {param($value) $value.properties.privateLinkServiceConnections+= $value.properties.privateLinkServiceConnections[0]})) {
        $armResponses=Clone $fixtureArm; & $mutation $armResponses[$target.endpointId]; Reject { Get-StandardPrivateAddresses $fixtureState $fixtureBinding }
    }
    foreach ($mutation in @({param($value) $value.properties.privateEndpoint.id+='foreign'}, {param($value) $value.properties.ipConfigurations[0].properties.privateIPAddress='10.76.7.4'}, {param($value) $value.properties.ipConfigurations=@()}, {param($value) $value.properties.ipConfigurations[0].properties.subnet.id+='foreign'})) {
        $armResponses=Clone $fixtureArm; & $mutation $armResponses[$nicId]; Reject { Get-StandardPrivateAddresses $fixtureState $fixtureBinding }
    }
    foreach ($mutation in @({param($value) $value.value[0].properties.virtualNetwork.id+='foreign'}, {param($value) $value.value[0].properties.registrationEnabled=$true}, {param($value) $value.value[0].properties.registrationEnabled='false'}, {param($value) $value.value=@()}, {param($value) $value.nextLink='more'})) {
        $armResponses=Clone $fixtureArm; & $mutation $armResponses["$($target.zoneId)/virtualNetworkLinks"]; Reject { Get-StandardPrivateAddresses $fixtureState $fixtureBinding }
    }
    $armResponses=Clone $fixtureArm; $armResponses["$($target.endpointId)/privateDnsZoneGroups"].value[0].properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId=$fixtureBinding.targets[1].zoneId
    Reject { Get-StandardPrivateAddresses $fixtureState $fixtureBinding }
    function Frame($Probe, [string]$Nonce) {
        $stream=[IO.MemoryStream]::new(); $gzip=[IO.Compression.GZipStream]::new($stream,[IO.Compression.CompressionLevel]::Optimal,$true)
        try { $bytes=[Text.Encoding]::UTF8.GetBytes(($Probe | ConvertTo-Json -Depth 20 -Compress)); $gzip.Write($bytes,0,$bytes.Length); $gzip.Dispose(); $encoded=[Convert]::ToBase64String($stream.ToArray()) } finally { $gzip.Dispose(); $stream.Dispose() }
        return @{value=@(@{code='ProvisioningState/succeeded';message="[stdout]`nFGL_STANDARD_BEGIN_$Nonce`n$encoded`nFGL_STANDARD_END_$Nonce`n[stderr]`n"})}
    }
    $nonce='12345678123456781234567812345678'; $fixtureProbe.nonce=$nonce
    $response=Frame $fixtureProbe $nonce
    Assert-StandardPrivateProbe $fixtureBinding (Read-StandardPrivateFrame $response $nonce) $fixtureAddresses; Check $true
    foreach ($mutation in @({param($value) $value.value[0].message+=$value.value[0].message}, {param($value) $value.value[0].message=$value.value[0].message.Replace('FGL_STANDARD_END_','TRUNCATED_')}, {param($value) $value.value[0].code='ComponentStatus/StdOut/failed'})) {
        $value=Clone $response; & $mutation $value; Reject { Read-StandardPrivateFrame $value $nonce }
    }
    Reject { Read-StandardPrivateFrame $response ('a' * 32) }
    $value=Clone $fixtureProbe; $value.nonce='wrong'; Reject { Read-StandardPrivateFrame (Frame $value $nonce) $nonce }
    Reject { Read-StandardPrivateFrame (Frame @{nonce=$nonce;data=('a' * 20000)} $nonce) $nonce }
    $oversize=[Convert]::ToBase64String([byte[]]::new(2600))
    Reject { Read-StandardPrivateFrame @{value=@(@{code='ComponentStatus/StdOut/succeeded';message="FGL_STANDARD_BEGIN_$nonce`n$oversize`nFGL_STANDARD_END_$nonce"})} $nonce }
    $value=Clone $response; $value.value[0].message=$value.value[0].message.Replace("`n","`r`n")
    Assert-StandardPrivateProbe $fixtureBinding (Read-StandardPrivateFrame $value $nonce) $fixtureAddresses; Check $true
    $multiple=Clone $fixtureAddresses; $multiple[$fixtureBinding.targets[0].hostName]+='10.76.6.90'
    Reject { Assert-StandardPrivateProbe $fixtureBinding $fixtureProbe $multiple }
    $value=Clone $fixtureProbe; $value.checks[0].addresses+= '10.76.6.90'
    Assert-StandardPrivateProbe $fixtureBinding $value $multiple; Check $true
    $fixtureArm[$accountId]=@{id=$accountId;tags=(Clone $fixtureTags);kind='AIServices';location='swedencentral';properties=@{provisioningState='Succeeded';publicNetworkAccess='Disabled';networkInjections=@(@{scenario='agent';subnetArmId="$vnetId/subnets/snet-agent-a";useMicrosoftManagedNetwork=$false})}}
    $fixtureArm[$projectId]=@{id=$projectId;tags=(Clone $fixtureTags);identity=@{principalId=$dependency.projectPrincipalId};properties=@{provisioningState='Succeeded';internalId=$dependency.workspaceId}}
    $fixtureArm[$fixtureLab.gateway]=@{id=$fixtureLab.gateway;tags=(Clone $fixtureTags);properties=@{provisioningState='Succeeded';publicNetworkAccess='Disabled'}}
    $fixtureArm[$fixtureLab.runner]=@{id=$fixtureLab.runner;tags=(Clone $fixtureTags);properties=@{provisioningState='Succeeded';storageProfile=@{osDisk=@{osType='Linux'}}}}
    $tokens=$null; $parseErrors=$null
    $harnessAst=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    Check ($parseErrors.Count -eq 0)
    Check ([IO.File]::ReadAllLines($scriptPath).Length -le 230)
    & {
        function Invoke-LabAz { throw 'DefinitionsOnly must not call Azure' }
        function Import-Module { throw 'DefinitionsOnly must not import modules' }
        function Read-LabRun { throw 'DefinitionsOnly must not read state' }
        function Save-LabRun { throw 'DefinitionsOnly must not save state' }
        & $scriptPath -DefinitionsOnly
    }
    Check $true
    $entrypoint=[scriptblock]::Create('param([string]$PSScriptRoot)' + "`n" + (($harnessAst.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text }) -join "`n"))
    function Lifecycle([string]$Scenario='pass') {
        $scenarioData=@{state=(Clone $fixtureState);arm=(Clone $fixtureArm);calls=[Collections.Generic.List[object]]::new();reads=0;saves=0;probes=0;roots=@{};nested=@{};groups=@{};context=@{id=$fixtureState.subscriptionId;tenantId=$fixtureState.tenantId;state='Enabled'}}
        $scenarioData.state.runDirectory=Join-Path ([IO.Path]::GetTempPath()) "standard-private-$([guid]::NewGuid().ToString('N'))"
        $scenarioData.state.azureConfigDirectory=Join-Path $scenarioData.state.runDirectory 'isolated-az'
        $scenarioData.state.operatorToken='PRIVATE_operator_fixture'; $scenarioData.state.clientSecret='PRIVATE_secret_fixture'; $scenarioData.state.standard.privateDependenciesVerified=$true; $scenarioData.state.standard.privateDependenciesEvidence=@{sha256='stale'}
        $null=[IO.Directory]::CreateDirectory($scenarioData.state.runDirectory)
        try {
            $lifecyclePath=Join-Path $scenarioData.state.runDirectory 'state.json'
            Write-StandardJson (Join-Path $scenarioData.state.runDirectory 'outputs.json') $fixtureLab
            Write-StandardJson (Join-Path $scenarioData.state.runDirectory 'standard-outputs.json') $fixtureOutputs
            foreach ($name in @('bootstrap','lock','activate','standard-dependencies')) { $scenarioData.roots["fgl-sample01-$name"]=@{name="fgl-sample01-$name";id="/subscriptions/$($fixtureState.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-sample01-$name";properties=@{provisioningState='Succeeded'}} }
            foreach ($groupName in $fixtureState.resourceGroups) {
                $groupId="/subscriptions/$($fixtureState.subscriptionId)/resourceGroups/$groupName"
                $scenarioData.groups[$groupName]=@{name=$groupName;id=$groupId;tags=(Clone $fixtureTags)}
                $scenarioData.nested[$groupName]=@(@{name='nested';id="$groupId/providers/Microsoft.Resources/deployments/nested";properties=@{provisioningState='Succeeded'}})
            }
            switch ($Scenario) {
                'pending' { $scenarioData.state.standard.pendingStage='account' }
                'tenant' { $scenarioData.context.tenantId='foreign' }
                'group' { $scenarioData.groups[$fixtureState.resourceGroups[0]].tags['fgl-owner']='foreign' }
                'missing-group' { $scenarioData.groups.Remove($fixtureState.resourceGroups[0]) }
                'preexisting' { $scenarioData.state.preexistingGroupIds=@($scenarioData.groups[$fixtureState.resourceGroups[0]].id) }
                'project-identity' { $scenarioData.arm[$projectId].identity.principalId='66666666-6666-4666-8666-666666666666' }
                'runner-id' { $scenarioData.arm[$fixtureLab.runner].id+='foreign' }
                'runner-tags' { $scenarioData.arm[$fixtureLab.runner].tags['fgl-owner']='foreign' }
                'runner-os' { $scenarioData.arm[$fixtureLab.runner].properties.storageProfile.osDisk.osType='Windows' }
                'runner-boolean' { $scenarioData.arm[$fixtureLab.runner].properties.storageProfile.osDisk.osType=$true }
                'root-active' { $scenarioData.roots['fgl-sample01-activate'].properties.provisioningState='Running' }
                'root-failed' { $scenarioData.roots['fgl-sample01-standard-dependencies'].properties.provisioningState='Failed' }
                'nested-active' { $scenarioData.nested[$fixtureState.resourceGroups[0]][0].properties.provisioningState='Accepted' }
                'nested-id' { $scenarioData.nested[$fixtureState.resourceGroups[0]][0].id=$true }
                'pe-boolean' { $scenarioData.arm[$fixtureBinding.targets[0].endpointId].properties.provisioningState=$true }
                'service' { $scenarioData.arm[$fixtureBinding.targets[0].id].properties.allowSharedKeyAccess=$true }
            }
            function Import-Module {}
            function Read-LabRun {
                param($StatePath)
                Check ($StatePath -ceq $lifecyclePath); $scenarioData.reads++
                if ($scenarioData.reads -eq 3) {
                    $scenarioData.state.concurrentField='preserved'; $scenarioData.state.standard.concurrentField='also preserved'
                    if ($Scenario -eq 'changed-state') { $scenarioData.state.phase='destroy' }
                    if ($Scenario -eq 'changed-output') { Write-StandardJson (Join-Path $scenarioData.state.runDirectory 'standard-outputs.json') @{dependencies=@{changed=$true}} }
                }
                return Clone $scenarioData.state
            }
            function Save-LabRun {
                param($State,$StatePath)
                Check ($StatePath -ceq $lifecyclePath); $scenarioData.saves++
                if ($Scenario -eq 'save-failure' -and $scenarioData.saves -eq 2) { throw 'Simulated write failure' }
                $scenarioData.state=Clone $State
            }
            function Invoke-LabAz {
                param($State,$Arguments,$Label)
                $scenarioData.calls.Add(@($Arguments))
                if ($Arguments[0] -eq 'rest') {
                    Check (($Arguments[0..3] -join ',') -ceq 'rest,--method,get,--url')
                    $uri=[uri]$Arguments[4]; Check ($uri.Host -ceq 'management.azure.com' -and $scenarioData.arm.ContainsKey($uri.AbsolutePath))
                    return $scenarioData.arm[$uri.AbsolutePath]
                }
                switch ($Label) {
                    'standard-private-context' { Check (($Arguments -join ',') -ceq 'account,show'); return $scenarioData.context }
                    'standard-private-group' { Check (($Arguments[0..2] -join ',') -ceq 'group,show,--name' -and $Arguments[3] -cin $fixtureState.resourceGroups); return $scenarioData.groups[$Arguments[3]] }
                    'standard-private-root' { Check (($Arguments[0..3] -join ',') -ceq 'deployment,sub,show,--name' -and $scenarioData.roots.ContainsKey($Arguments[4])); return $scenarioData.roots[$Arguments[4]] }
                    'standard-private-nested' { Check (($Arguments[0..3] -join ',') -ceq 'deployment,group,list,--resource-group' -and $Arguments[4] -cin $fixtureState.resourceGroups); return $scenarioData.nested[$Arguments[4]] }
                    'standard-private-probe' {
                        Check (($Arguments[0..3] -join ',') -ceq 'vm,run-command,invoke,--ids' -and $Arguments[4] -ceq $fixtureLab.runner -and ($Arguments[5..7] -join ',') -ceq '--command-id,RunShellScript,--scripts' -and $Arguments.Count -eq 9)
                        Check (-not $scenarioData.state.standard.privateDependenciesVerified -and -not $scenarioData.state.standard.ContainsKey('privateDependenciesEvidence'))
                        $scenarioData.probes++
                        if ($Scenario -eq 'run-failure') { throw 'Simulated RunCommand failure' }
                        $payloadMatch=[regex]::Match($Arguments[8], "b64decode\('([A-Za-z0-9+/=]+)'\)")
                        $request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadMatch.Groups[1].Value)) | ConvertFrom-Json -AsHashtable
                        Check ($request.Count -eq 2 -and $request.ContainsKey('hosts') -and $request.ContainsKey('nonce') -and $request.hosts.Count -eq 3)
                        foreach ($hostname in $request.hosts.Keys) { Check ($fixtureAddresses.ContainsKey($hostname) -and -not @(Compare-Object $request.hosts[$hostname] $fixtureAddresses[$hostname]).Count) }
                        $resultProbe=Clone $fixtureProbe; $resultProbe.nonce=$request.nonce
                        if ($Scenario -eq 'dns') { $resultProbe.checks[0].addresses=@('10.76.6.99') }
                        if ($Scenario -eq 'tls') { $resultProbe.checks[0].tls443=$false }
                        $reply=Frame $resultProbe $request.nonce
                        if ($Scenario -eq 'truncated') { $reply.value[0].message=$reply.value[0].message.Replace('FGL_STANDARD_END_','TRUNCATED_') }
                        return $reply
                    }
                    default { throw "Unexpected offline command: $Label" }
                }
            }
            $failed=$false
            try { $StatePath=$lifecyclePath; $DefinitionsOnly=$false; $null=& $entrypoint (Split-Path $scriptPath) } catch { if ($Scenario -eq 'pass') { throw }; $failed=$true }
            Check ($failed -eq ($Scenario -ne 'pass'))
            $reports=@(Get-ChildItem -LiteralPath $scenarioData.state.runDirectory -Filter 'standard-private-*.json'); Check ($reports.Count -eq 1)
            $report=Get-Content -LiteralPath $reports[0].FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            Check ($report.success -is [bool] -and $report.success -eq (-not $failed))
            if ($failed) {
                Check (-not $scenarioData.state.standard.privateDependenciesVerified -and -not $scenarioData.state.standard.ContainsKey('privateDependenciesEvidence') -and $null -eq $report.verifiedAt -and [bool]$report.actionNeeded)
                Check ($scenarioData.probes -eq [int]($Scenario -in @('dns','tls','truncated','run-failure','changed-state','changed-output','save-failure')))
            } else {
                $receipt=$scenarioData.state.standard.privateDependenciesEvidence
                Check ($scenarioData.state.standard.privateDependenciesVerified -and $receipt.sha256 -ceq (Get-FileHash -LiteralPath $reports[0].FullName -Algorithm SHA256).Hash -and $receipt.bindingSha256 -ceq $report.bindingSha256 -and $receipt.bindingSha256 -ceq (Get-StandardPrivateStamp $scenarioData.state))
                Check ($receipt.verifiedAt -ceq $report.verifiedAt -and $null -eq $report.actionNeeded -and $report.managementVerified -and $report.checks.Count -eq 3)
                Check ($scenarioData.state.concurrentField -ceq 'preserved' -and $scenarioData.state.standard.concurrentField -ceq 'also preserved' -and $scenarioData.saves -eq 2)
            }
            $serialized=@($scenarioData.calls.ToArray(),$report) | ConvertTo-Json -Depth 100 -Compress
            foreach ($secret in @('PRIVATE_operator_fixture','PRIVATE_secret_fixture')) { Check (-not $serialized.Contains($secret)) }
        } finally { Remove-Item -LiteralPath $scenarioData.state.runDirectory -Recurse -Force }
    }
    foreach ($scenario in @('pass','pending','tenant','group','missing-group','preexisting','project-identity','runner-id','runner-tags','runner-os','runner-boolean','root-active','root-failed','nested-active','nested-id','pe-boolean','service','dns','tls','truncated','run-failure','changed-state','changed-output','save-failure')) { Lifecycle $scenario }
    $shell = New-StandardPrivateShell $fixtureAddresses $nonce
    Check ($shell.StartsWith("set -eu`ntimeout -s KILL 60s python3 -B - <<'FGL_PY'`n") -and -not $shell.Contains("`r"))
    $pythonSource=[regex]::Match($shell, "(?s)<<'FGL_PY'\n(.*?)\nFGL_PY$").Groups[1].Value
    Check ([bool]$pythonSource)
    $pythonTest = @'
import ast, base64, builtins, contextlib, gzip, io, json, ssl, sys, types
from unittest.mock import patch
source = sys.stdin.read()
tree = ast.parse(source)
imports = {alias.name for node in ast.walk(tree) if isinstance(node, ast.Import) for alias in node.names}
assert imports == {'base64', 'gzip', 'json', 'signal', 'socket', 'ssl'}
assert not any(isinstance(node, ast.ImportFrom) for node in ast.walk(tree))
encoded = next(node.args[0].value for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'b64decode')
request = json.loads(base64.b64decode(encoded))
assert set(request) == {'hosts', 'nonce'} and len(request['hosts']) == 3
original_context = ssl.create_default_context
for scenario in ('pass', 'foreign', 'ipv6', 'subset', 'dns-timeout', 'tcp-failure', 'tls-failure'):
    calls, alarms, handlers, defaults = [], [], {}, []
    expected = json.loads(json.dumps(request))
    if scenario == 'subset':
        for addresses in expected['hosts'].values():
            addresses.append('10.76.6.90')
    current = source.replace(encoded, base64.b64encode(json.dumps(expected).encode()).decode())
    def resolve(hostname, port, **kwargs):
        assert hostname in expected['hosts'] and port == 443 and kwargs == {'type': 1}
        if scenario == 'dns-timeout':
            handlers[14](14, None)
        addresses = expected['hosts'][hostname]
        if scenario == 'foreign':
            addresses = ['203.0.113.4']
        if scenario == 'ipv6':
            addresses = ['::1']
        if scenario == 'subset':
            addresses = addresses[:1]
        return [(2, 1, 6, '', (address, port)) for address in addresses]
    def connect(destination, timeout):
        assert destination[1] == 443 and timeout == 5
        assert destination[0] in {address for addresses in expected['hosts'].values() for address in addresses}
        calls.append(('tcp', destination))
        if scenario == 'tcp-failure':
            raise TimeoutError('TCP')
        return contextlib.nullcontext(destination)
    class Context:
        def wrap_socket(self, connection, server_hostname):
            assert server_hostname in expected['hosts'] and connection[0] in expected['hosts'][server_hostname]
            calls.append(('tls', server_hostname))
            if scenario == 'tls-failure':
                raise ssl.SSLCertVerificationError('certificate')
            return contextlib.nullcontext()
    def create_context():
        actual = original_context()
        assert actual.check_hostname and actual.verify_mode == ssl.CERT_REQUIRED
        return Context()
    fake_socket = types.SimpleNamespace(setdefaulttimeout=defaults.append, getaddrinfo=resolve, create_connection=connect, SOCK_STREAM=1)
    fake_signal = types.SimpleNamespace(SIGALRM=14, signal=lambda number, handler: handlers.update({number: handler}), alarm=alarms.append)
    output = io.StringIO()
    real_import = builtins.__import__
    def restricted_import(name, *args, **kwargs):
        assert name in imports, 'Unapproved import: ' + name
        return real_import(name, *args, **kwargs)
    environment = {'__builtins__': {**vars(builtins), '__import__': restricted_import, 'open': lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError('No file access'))}}
    with patch.dict(sys.modules, {'socket': fake_socket, 'signal': fake_signal, 'ssl': types.SimpleNamespace(create_default_context=create_context)}), contextlib.redirect_stdout(output):
        exec(compile(current, '<generated-probe>', 'exec'), environment)
    lines = output.getvalue().splitlines()
    assert len(lines) == 3 and lines[0] == 'FGL_STANDARD_BEGIN_' + request['nonce'] and lines[2] == 'FGL_STANDARD_END_' + request['nonce']
    packed = base64.b64decode(lines[1], validate=True)
    assert len(packed) < 2600 and defaults == [10] and alarms == [10, 0] * 3
    result = json.loads(gzip.decompress(packed))
    assert result['nonce'] == request['nonce'] and len(result['checks']) == 3
    assert all(check['tls443'] == (scenario == 'pass') for check in result['checks'])
    if scenario in ('foreign', 'ipv6', 'subset', 'dns-timeout'):
        assert not calls
    elif scenario == 'tcp-failure':
        assert len(calls) == 3 and all(call[0] == 'tcp' for call in calls)
    else:
        assert len(calls) == 6
print('Generated Python probe: 7 offline network/TLS scenarios passed')
'@
    $pythonOutput = $pythonSource | & $PythonExecutable -I -B -c $pythonTest
    Check ($LASTEXITCODE -eq 0); Write-Output $pythonOutput
    Write-Output "Standard private offline checks passed: $checks"
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }