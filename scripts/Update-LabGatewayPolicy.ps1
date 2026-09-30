[CmdletBinding()]
param([string]$StatePath, [ValidateSet('Preview','Deploy','Status','Attest')][string]$Action = 'Preview', [switch]$DefinitionsOnly)

function Get-GatewayPolicyNames([hashtable]$State) {
    $group = "rg-fgl-$($State.labId)-integration"
    $name = "fgl-$($State.labId)-gateway-policy-update"
    return @{group=$group;name=$name;deploymentId="/subscriptions/$($State.subscriptionId)/resourceGroups/$group/providers/Microsoft.Resources/deployments/$name"}
}

function Assert-GatewayPolicyState([hashtable]$State, [string]$SelectedAction) {
    Assert-StandardPrivateState $State
    if ($SelectedAction -cnotin @('Preview','Deploy','Status','Attest') -or ($State.standard.completedStages -join ',') -cne 'dependencies,account,project,access') { throw 'Complete Standard and a known action required' }
    Assert-CosmosNetworkState $State 'Status'
    if ($State.standard.cosmosNetwork.pending -or $State.standard.cosmosNetwork.verified -isnot [bool] -or -not $State.standard.cosmosNetwork.verified) { throw 'Verified idle Cosmos network required' }
    $receipt = $State.standard.gatewayPolicy
    if ($null -ne $receipt) {
        Assert-CosmosNetworkKeys $receipt @('pending','verified','name','group','review') @('evidence')
        $names = Get-GatewayPolicyNames $State
        if ($receipt.name -isnot [string] -or $receipt.name -cne $names.name -or $receipt.group -isnot [string] -or $receipt.group -cne $names.group -or $receipt.pending -isnot [bool] -or $receipt.verified -isnot [bool] -or $receipt.pending -eq $receipt.verified -or $receipt.review -isnot [hashtable]) { throw 'Invalid gateway policy receipt' }
        if ($SelectedAction -cne 'Status') { throw 'Policy submission already tracked; only Status is permitted' }
    } elseif ($SelectedAction -ceq 'Status') { throw 'No submitted gateway policy update' }
}

function ConvertTo-GatewayPolicyXml([string]$Value, [switch]$DecodeExpressions) {
    if (-not $Value -or $Value.Length -gt 32768) { throw 'Missing or excessive policy XML' }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 32768
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($Value.Replace("`r`n","`n")), $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        if ($document.DocumentElement.Name -cne 'policies' -or $document.DocumentElement.NamespaceURI) { throw 'Unexpected policy root' }
        if ($DecodeExpressions) {
            foreach ($node in $document.SelectNodes('//@* | //set-body/text()')) {
                if ($node.Value.StartsWith('@{') -or $node.Value.StartsWith('@(')) { $node.Value = [Net.WebUtility]::HtmlDecode($node.Value) }
            }
        }
        return $document.OuterXml
    } finally { $reader.Dispose() }
}

function Get-GatewayPolicyPair([string]$Source, [hashtable]$Binding) {
    $body = @'
@{
      var body = context.Request.Body.As&lt;JObject&gt;(preserveContent: true);
      body["max_tokens"] = 256;
      body["n"] = 1;
      if (body["stream"] == null) { body["stream"] = false; }
      if (body["stream"].Value&lt;bool&gt;() == false) { body.Remove("stream_options"); }
      body.Remove("max_completion_tokens");
      body.Remove("model");
      return body.ToString();
    }
'@
    $sourceText = $Source.Replace("`r`n","`n")
    $body = $body.Replace("`r`n","`n")
    $newStream = 'if (body["stream"] == null) { body["stream"] = false; }' + "`n      " + 'if (body["stream"].Value&lt;bool&gt;() == false) { body.Remove("stream_options"); }'
    if ([regex]::Matches($sourceText,[regex]::Escape("<set-body>$body</set-body>")).Count -ne 1) { throw 'Only the approved request body transform is accepted' }
    $replacements = @{'__TENANT__'=$Binding.tenantId;'__MODEL_ACCOUNT__'=$Binding.parameters.modelAccountName.value;'__CALLERS__'=($Binding.parameters.allowedPrincipalIds.value -join ',')}
    foreach ($key in $replacements.Keys) {
        if ([regex]::Matches($sourceText,[regex]::Escape($key)).Count -ne 1) { throw 'Policy placeholder coverage changed' }
        $sourceText = $sourceText.Replace($key,$replacements[$key])
    }
    return @{before=(ConvertTo-GatewayPolicyXml $sourceText.Replace($newStream,'body["stream"] = false;'));after=(ConvertTo-GatewayPolicyXml $sourceText)}
}

function Assert-GatewayPolicyDocument($Resource, [string]$Id, [string]$Expected) {
    $qualified = ($Id -split '/service/')[1].Replace('/apis/','/').Replace('/policies/','/')
    if ($Resource -isnot [hashtable] -or $Resource.id -isnot [string] -or $Resource.id -ine $Id -or $Resource.type -isnot [string] -or $Resource.type -ine 'Microsoft.ApiManagement/service/apis/policies' -or $Resource.name -isnot [string] -or $Resource.name -cnotin @('policy',$qualified)) { throw 'Unexpected policy child identity' }
    Assert-CosmosNetworkKeys $Resource.properties @('format','value')
    if ($Resource.properties.format -isnot [string] -or $Resource.properties.format -cnotin @('xml','rawxml') -or $Resource.properties.value -isnot [string] -or (ConvertTo-GatewayPolicyXml $Resource.properties.value -DecodeExpressions:($Resource.properties.format -ceq 'xml')) -cne $Expected) { throw 'Actual policy differs outside the approved stream change' }
}

function Assert-GatewayPolicyGuid($Value) {
    $parsed = [guid]::Empty
    if ($Value -isnot [string] -or -not [guid]::TryParseExact($Value,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'Explicit nonempty principal or tenant GUID required' }
}

function Get-GatewayPolicyBinding([hashtable]$State, [hashtable]$Lab, [hashtable]$Activation, [hashtable]$Resources, [array]$Roles) {
    $null = Get-LabPrivateTargets $State $Lab
    if ($Lab.phase -isnot [string] -or $Lab.phase -cne 'activate' -or $Lab.pendingPhase -or $Lab.identities -isnot [array] -or $Lab.identities.Count -ne 7 -or $Lab.identities[5].actor -cne 'client') { throw 'Original activated identity outputs required' }
    $standard = Get-StandardBindings $State $Lab $Resources.account $Resources.project $Resources.gateway
    $names = Get-GatewayPolicyNames $State
    $caller = $Lab.identities[5]
    $callerId = "/subscriptions/$($State.subscriptionId)/resourceGroups/$($names.group)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-$($State.labId)-client"
    if ($caller.resourceId -isnot [string] -or $caller.resourceId -ine $callerId -or @($Lab.identities | Where-Object actor -CEQ 'client').Count -ne 1) { throw 'Original caller identity mismatch' }
    foreach ($spec in @(@('account',$Lab.cases[0].accountId,'Microsoft.CognitiveServices/accounts'),@('project',$Lab.cases[0].projects[0].resourceId,'Microsoft.CognitiveServices/accounts/projects'),@('gateway',$Lab.gateway,'Microsoft.ApiManagement/service'),@('model',$Lab.models,'Microsoft.CognitiveServices/accounts'),@('caller',$callerId,'Microsoft.ManagedIdentity/userAssignedIdentities'))) {
        $resource = $Resources[$spec[0]]
        Assert-StandardOwned $State $resource $spec[1]
        if ($resource.type -isnot [string] -or $resource.type -ine $spec[2]) { throw 'Unexpected resource type' }
        if ($spec[0] -ne 'caller' -and ($resource.properties.provisioningState -isnot [string] -or $resource.properties.provisioningState -cne 'Succeeded')) { throw 'Existing resource must be Succeeded' }
        if ($spec[0] -in @('account','gateway','model') -and ($resource.properties.publicNetworkAccess -isnot [string] -or $resource.properties.publicNetworkAccess -cne 'Disabled')) { throw 'Existing resource must remain private' }
    }
    Assert-LabParameters $State $Activation.parameters
    if ($Activation.parameters.phase.value -cne 'activate' -or $Resources.gateway.identity.type -cne 'SystemAssigned' -or $Resources.project.identity.type -cne 'SystemAssigned' -or $Resources.model.kind -cne 'AIServices' -or $Resources.model.properties.customSubDomainName -cne ($Lab.models -split '/')[-1]) { throw 'Activation, identity or central model binding mismatch' }
    foreach ($identity in @($Resources.gateway.identity,$Resources.project.identity,$Resources.caller.properties)) {
        Assert-GatewayPolicyGuid $identity.principalId
        Assert-GatewayPolicyGuid $identity.tenantId
        if ($identity.tenantId -ine $State.tenantId) { throw 'Managed identity tenant mismatch' }
    }
    Assert-GatewayPolicyGuid $caller.principalId
    Assert-GatewayPolicyGuid $caller.clientId
    if ($Resources.gateway.identity.principalId -ine $Activation.parameters.gatewayPrincipalId.value -or $Resources.caller.properties.principalId -ine $caller.principalId -or $Resources.caller.properties.clientId -ine $caller.clientId -or $caller.principalId -ieq $standard.parameters.projectPrincipalId.value) { throw 'Managed identity changed since activation' }
    $rolePrefix = "$($Lab.models)/providers/Microsoft.Authorization/roleAssignments/"
    $definition = "/subscriptions/$($State.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"
    $inferenceRoles = @($Roles | Where-Object { $_.properties.scope -ieq $Lab.models -and $_.properties.principalId -ieq $Resources.gateway.identity.principalId -and $_.properties.roleDefinitionId -ieq $definition })
    if ($inferenceRoles.Count -ne 1 -or $inferenceRoles[0].id -isnot [string] -or -not $inferenceRoles[0].id.StartsWith($rolePrefix,[StringComparison]::OrdinalIgnoreCase) -or $inferenceRoles[0].properties.principalType -cne 'ServicePrincipal') { throw 'Original gateway inference role at central resource scope required' }
    Assert-GatewayPolicyGuid ($inferenceRoles[0].id.Substring($rolePrefix.Length))
    return @{names=$names;policyId="$($Lab.gateway)/apis/lab-inference/policies/policy";tenantId=$State.tenantId;accountId=$standard.accountId;projectId=$standard.projectId;gatewayId=$Lab.gateway;modelId=$Lab.models;callerId=$callerId;gatewayPrincipalId=$Resources.gateway.identity.principalId;callerClientId=$caller.clientId;inferenceRole=$inferenceRoles[0];ownership=@{account=$Resources.account.tags;project=$Resources.project.tags;gateway=$Resources.gateway.tags;model=$Resources.model.tags;caller=$Resources.caller.tags};parameters=@{gatewayName=@{value=($Lab.gateway -split '/')[-1]};modelAccountName=@{value=($Lab.models -split '/')[-1]};allowedPrincipalIds=@{value=@($Lab.cases[0].projects[0].principalId,$caller.principalId)}}}
}

function Get-GatewayPolicyLive([hashtable]$State, [string]$Source, [switch]$Updated) {
    Assert-StandardGroups $State @(Confirm-LabRunContext $State)
    $lab = Get-Content -LiteralPath (Assert-ExternalLabPath (Join-Path $State.runDirectory 'outputs.json')) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $activation = Get-Content -LiteralPath (Assert-ExternalLabPath (Join-Path $State.runDirectory 'activate.parameters.json')) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $null = Get-LabPrivateTargets $State $lab
    $activationId = "/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-$($State.labId)-activate"
    $original = Read-StandardArm $State $activationId '2022-09-01' 'policy-activation'
    if ($original.properties.provisioningState -isnot [string] -or $original.properties.provisioningState -cne 'Succeeded' -or $original.properties.mode -isnot [string] -or $original.properties.mode -cne 'Incremental' -or (Get-CosmosNetworkHash $original.properties.outputs.lab.value) -cne (Get-CosmosNetworkHash $lab)) { throw 'Original activation deployment does not match saved outputs' }
    Assert-GatewayPolicyDeploymentParameters @{gatewayPrincipalId=$original.properties.parameters.gatewayPrincipalId} @{gatewayPrincipalId=$activation.parameters.gatewayPrincipalId}
    $names = Get-GatewayPolicyNames $State
    $callerId = "/subscriptions/$($State.subscriptionId)/resourceGroups/$($names.group)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-fgl-$($State.labId)-client"
    $resources = @{}
    foreach ($spec in @(@('account',$lab.cases[0].accountId,'2026-05-01'),@('project',$lab.cases[0].projects[0].resourceId,'2026-05-01'),@('gateway',$lab.gateway,'2024-05-01'),@('model',$lab.models,'2026-05-01'),@('caller',$callerId,'2023-01-31'))) { $resources[$spec[0]] = Read-StandardArm $State $spec[1] $spec[2] "policy-$($spec[0])" }
    $roles = @(Read-StandardArm $State "$($lab.models)/providers/Microsoft.Authorization/roleAssignments" '2022-04-01' 'policy-roles' -List)
    $binding = Get-GatewayPolicyBinding $State $lab $activation $resources $roles
    $pair = Get-GatewayPolicyPair $Source $binding
    $policy = Invoke-LabAz $State @('rest','--method','get','--url',"https://management.azure.com$($binding.policyId)?api-version=2024-05-01",'--headers','Accept=application/json') 'standard-policy-current'
    $expected = if ($Updated) { $pair.after } else { $pair.before }
    Assert-GatewayPolicyDocument $policy $binding.policyId $expected
    return @{binding=$binding;pair=$pair;policyHash=(Get-CosmosNetworkHash $policy);policy=$policy}
}

function Assert-GatewayPolicyTemplate([hashtable]$Template, [string]$Source) {
    Assert-CosmosNetworkKeys $Template @('$schema','contentVersion','parameters','variables','resources') @('metadata','languageVersion')
    if ($Template.'$schema' -isnot [string] -or $Template.'$schema' -cne 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#' -or $Template.contentVersion -isnot [string] -or $Template.contentVersion -cne '1.0.0.0' -or ($Template.ContainsKey('languageVersion') -and ($Template.languageVersion -isnot [string] -or $Template.languageVersion -cne '2.0'))) { throw 'Bounded resource group template required' }
    Assert-CosmosNetworkKeys $Template.parameters @('gatewayName','modelAccountName','allowedPrincipalIds')
    foreach ($key in $Template.parameters.Keys) {
        Assert-CosmosNetworkKeys $Template.parameters[$key] @('type') @('metadata')
        $type = if ($key -ceq 'allowedPrincipalIds') { 'array' } else { 'string' }
        if ($Template.parameters[$key].type -isnot [string] -or $Template.parameters[$key].type -ine $type) { throw 'Unexpected template parameter' }
    }
    Assert-CosmosNetworkKeys $Template.variables @('callerIds','tenantPolicy','backendPolicy') @('$fxv#0')
    $textExpression = "'" + $Source.Replace("'","''") + "'"
    if ($Template.variables.ContainsKey('$fxv#0')) {
        if ($Template.variables.'$fxv#0' -isnot [string] -or $Template.variables.'$fxv#0' -cne $Source) { throw 'Compiled source policy changed' }
        $textExpression = "variables('`$fxv#0')"
    }
    $variables = @{callerIds="[join(parameters('allowedPrincipalIds'), ',')]";tenantPolicy="[replace($textExpression, '__TENANT__', tenant().tenantId)]";backendPolicy="[replace(variables('tenantPolicy'), '__MODEL_ACCOUNT__', parameters('modelAccountName'))]"}
    foreach ($key in $variables.Keys) { if ($Template.variables[$key] -isnot [string] -or $Template.variables[$key] -cne $variables[$key]) { throw 'Compiled policy binding expression changed' } }
    $resources = @()
    if ($Template.resources -is [Collections.IDictionary]) { $resources = @($Template.resources.Values) } elseif ($Template.resources -is [array]) { $resources = $Template.resources } else { throw 'Invalid template resource collection' }
    $seen = @{}; $deployed = 0
    foreach ($resource in $resources) {
        Assert-CosmosNetworkKeys $resource @('type','apiVersion','name') @('existing','properties')
        if ($resource.type -isnot [string] -or $seen.ContainsKey($resource.type) -or $resource.apiVersion -isnot [string] -or $resource.apiVersion -cne '2024-05-01' -or $resource.name -isnot [string]) { throw 'Duplicate or invalid compiled resource' }
        $seen[$resource.type] = $true
        switch -CaseSensitive ($resource.type) {
            'Microsoft.ApiManagement/service' { $allowedNames = @("[parameters('gatewayName')]") }
            'Microsoft.ApiManagement/service/apis' { $allowedNames = @("[format('{0}/{1}', parameters('gatewayName'), 'lab-inference')]", "[format('{0}/lab-inference', parameters('gatewayName'))]") }
            'Microsoft.ApiManagement/service/apis/policies' { $allowedNames = @("[format('{0}/{1}/{2}', parameters('gatewayName'), 'lab-inference', 'policy')]", "[format('{0}/lab-inference/policy', parameters('gatewayName'))]") }
            default { throw 'Unexpected resource in policy-only template' }
        }
        if ($resource.name -cnotin $allowedNames) { throw 'Compiled resource name changed' }
        if ($resource.type -ceq 'Microsoft.ApiManagement/service/apis/policies') {
            if ($resource.ContainsKey('existing') -or (Get-CosmosNetworkHash $resource.properties) -cne (Get-CosmosNetworkHash @{format='rawxml';value="[replace(variables('backendPolicy'), '__CALLERS__', variables('callerIds'))]"})) { throw 'Only exact policy properties can be deployed' }
            $deployed++
        } elseif ($resource.existing -isnot [bool] -or -not $resource.existing -or $resource.ContainsKey('properties')) { throw 'Parent redeployment forbidden' }
    }
    if ($deployed -ne 1 -or $resources.Count -gt 3) { throw 'Exactly one policy child must be deployed' }
}

function Assert-GatewayPolicyWhatIf([hashtable]$State, [hashtable]$Live, [hashtable]$Result) {
    if ($Result.status -isnot [string] -or $Result.status -cne 'Succeeded' -or $Result.changes -isnot [array] -or -not $Result.changes.Count) { throw 'Expanded successful what-if required' }
    $seen = @{}; $modified = 0
    foreach ($change in $Result.changes) {
        $id = $change.resourceId
        if ($id -isnot [string] -or $seen.ContainsKey($id)) { throw 'Duplicate or malformed what-if resource' }
        Assert-LabResourceId $State $id
        $seen[$id] = $true
        if ($change.changeType -ceq 'Ignore') {
            if ($id -ieq $Live.binding.policyId -or $change.before -isnot [hashtable] -or $change.before.id -isnot [string] -or $change.before.id -ine $id -or $change.before.type -isnot [string] -or -not $change.before.type -or @($change.delta).Where({$null -ne $_}).Count -or ($null -ne $change.after -and (Get-CosmosNetworkHash $change.before) -cne (Get-CosmosNetworkHash $change.after))) { throw 'Ignore must describe unchanged existing state' }
            continue
        }
        if ($id -ine $Live.binding.policyId -or $change.changeType -cne 'Modify') { throw 'Only the existing policy child may be modified' }
        Assert-GatewayPolicyDocument $change.before $id $Live.pair.before
        Assert-GatewayPolicyDocument $change.after $id $Live.pair.after
        if ($change.delta -isnot [array] -or $change.delta.Count -notin @(1,2)) { throw 'Exactly one policy value delta and optional inline format delta required' }
        $valueDeltas = @($change.delta | Where-Object path -CEQ 'properties.value')
        $formatDeltas = @($change.delta | Where-Object path -CEQ 'properties.format')
        if ($valueDeltas.Count -ne 1 -or $valueDeltas.Count + $formatDeltas.Count -ne $change.delta.Count) { throw 'Unexpected policy delta fields' }
        foreach ($formatDelta in $formatDeltas) {
            Assert-CosmosNetworkKeys $formatDelta @('path','propertyChangeType','before','after') @('children')
            if (@($formatDelta.children).Where({$null -ne $_}).Count) { throw 'Nested format delta forbidden' }
            if ($formatDelta.propertyChangeType -cne 'Modify' -or $formatDelta.before -cne 'xml' -or $formatDelta.after -cne 'rawxml') { throw 'Unexpected policy format delta' }
        }
        $delta = $valueDeltas[0]
        Assert-CosmosNetworkKeys $delta @('path','propertyChangeType','before','after') @('children')
        if (@($delta.children).Where({$null -ne $_}).Count) { throw 'Nested policy delta forbidden' }
        if ($delta.path -isnot [string] -or $delta.path -cne 'properties.value' -or $delta.propertyChangeType -isnot [string] -or $delta.propertyChangeType -cne 'Modify' -or $delta.before -isnot [string] -or $delta.after -isnot [string] -or (ConvertTo-GatewayPolicyXml $delta.before -DecodeExpressions:($change.before.properties.format -ceq 'xml')) -cne $Live.pair.before -or (ConvertTo-GatewayPolicyXml $delta.after -DecodeExpressions:($change.after.properties.format -ceq 'xml')) -cne $Live.pair.after) { throw 'Unexpected policy value delta' }
        $modified++
    }
    if ($modified -ne 1) { throw 'Policy Modify missing' }
}

function Get-GatewayPolicyStamp([hashtable]$State) {
    $copy = $State | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $copy.standard.Remove('gatewayPolicy')
    return Get-CosmosNetworkHash @{state=$copy;original=(Get-StandardPrivateStamp $State);activation=(Get-FileHash -LiteralPath (Assert-ExternalLabPath (Join-Path $State.runDirectory 'activate.parameters.json')) -Algorithm SHA256).Hash}
}

function Assert-GatewayPolicyDeploymentParameters($Actual, [hashtable]$Expected) {
    Assert-CosmosNetworkKeys $Actual @($Expected.Keys)
    foreach ($key in $Expected.Keys) {
        Assert-CosmosNetworkKeys $Actual[$key] @('value') @('type')
        $type = if ($key -ceq 'allowedPrincipalIds') { 'Array' } else { 'String' }
        if (($Actual[$key].Contains('type') -and ($Actual[$key].type -isnot [string] -or $Actual[$key].type -ine $type)) -or (Get-CosmosNetworkHash $Actual[$key].value) -cne (Get-CosmosNetworkHash $Expected[$key].value)) { throw 'Submitted deployment parameter mismatch' }
    }
}

function Get-GatewayPolicyPaths([hashtable]$State) {
    $paths = @{}
    foreach ($key in @('template','parameters','review','whatif','evidence')) { $paths[$key] = Assert-ExternalLabPath (Join-Path $State.runDirectory "gateway-policy-update.$key.json") }
    return $paths
}

function Confirm-GatewayPolicyAbsent([hashtable]$State) {
    $names = Get-GatewayPolicyNames $State
    $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/$($names.group)/providers/Microsoft.Resources/deployments"
    $seen = @{}
    foreach ($deployment in @(Read-StandardArm $State $prefix '2022-09-01' 'policy-deployments' -List)) {
        if ($deployment.name -isnot [string] -or -not $deployment.name -or $deployment.id -isnot [string] -or $deployment.id -ine "$prefix/$($deployment.name)" -or $seen.ContainsKey($deployment.id)) { throw 'Invalid deployment list' }
        $seen[$deployment.id] = $true
        if ($deployment.id -ieq $names.deploymentId) { throw 'Untracked policy deployment cannot be adopted or overwritten' }
    }
}

function Assert-GatewayPolicyReview([hashtable]$State, [hashtable]$Review, [hashtable]$Live, [hashtable]$Paths, [string]$SourcePath, [string]$PolicyPath, [switch]$Submitted) {
    Assert-CosmosNetworkKeys $Review @('checkedAt','templateHash','parametersHash','sourceHash','policySourceHash','whatifHash','bindingHash','binding','stateHash','beforeHash')
    $checkedAt = if ($Review.checkedAt -is [datetime]) { [DateTimeOffset]$Review.checkedAt } else { [DateTimeOffset]::Parse([string]$Review.checkedAt) }
    $age = [DateTimeOffset]::UtcNow - $checkedAt
    if ($age -lt [TimeSpan]::Zero -or (-not $Submitted -and $age -gt [TimeSpan]::FromHours(1))) { throw 'Preview stale or future dated' }
    foreach ($key in @('template','parameters','whatif')) { if ((Get-FileHash -LiteralPath $Paths[$key] -Algorithm SHA256).Hash -cne $Review["${key}Hash"]) { throw 'Reviewed artifact changed' } }
    if ((Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash -cne $Review.sourceHash -or (Get-FileHash -LiteralPath $PolicyPath -Algorithm SHA256).Hash -cne $Review.policySourceHash -or (Get-GatewayPolicyStamp $State) -cne $Review.stateHash -or (Get-CosmosNetworkHash $Live.binding) -cne $Review.bindingHash -or (Get-CosmosNetworkHash $Review.binding) -cne $Review.bindingHash -or (-not $Submitted -and $Live.policyHash -cne $Review.beforeHash)) { throw 'Reviewed source, state, identity or policy changed' }
    Assert-GatewayPolicyTemplate (Get-Content -LiteralPath $Paths.template -Raw | ConvertFrom-Json -AsHashtable -Depth 100) (Get-Content -LiteralPath $PolicyPath -Raw)
    $parameters = Get-Content -LiteralPath $Paths.parameters -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-CosmosNetworkKeys $parameters @('$schema','contentVersion','parameters')
    if ($parameters.'$schema' -cne 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#' -or $parameters.contentVersion -cne '1.0.0.0' -or (Get-CosmosNetworkHash $parameters.parameters) -cne (Get-CosmosNetworkHash $Live.binding.parameters)) { throw 'Parameter binding changed' }
    Assert-GatewayPolicyWhatIf $State $Live (Get-Content -LiteralPath $Paths.whatif -Raw | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Invoke-LabGatewayPolicy([string]$Path, [string]$SelectedAction) {
    $state = Read-LabRun $Path
    Assert-GatewayPolicyState $state $SelectedAction
    $lockPath = Assert-ExternalLabPath (Join-Path $state.runDirectory 'gateway-policy-update.lock')
    $lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $state = Read-LabRun $Path
        Assert-GatewayPolicyState $state $SelectedAction
        $stamp = Get-GatewayPolicyStamp $state
        $names = Get-GatewayPolicyNames $state; $paths = Get-GatewayPolicyPaths $state
        $source = Join-Path $PSScriptRoot '../infra/modules/gateway-policy-update.bicep'
        $policyPath = Join-Path $PSScriptRoot '../infra/policies/inference.xml'
        Assert-StandardGroups $state @(Confirm-LabRunContext $state)
        if ($SelectedAction -ceq 'Attest' -or ($SelectedAction -ceq 'Status' -and $state.standard.gatewayPolicy.review.source -ceq 'activation-policy-reuse')) {
            Confirm-StandardIdle $state
            Confirm-GatewayPolicyAbsent $state
            $sourceHash = (Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash
            $live = Get-GatewayPolicyLive $state (Get-Content -LiteralPath $policyPath -Raw) -Updated
            $fresh = Read-LabRun $Path
            Assert-GatewayPolicyState $fresh $SelectedAction
            $freshLive = Get-GatewayPolicyLive $fresh (Get-Content -LiteralPath $policyPath -Raw) -Updated
            Confirm-StandardIdle $fresh
            Confirm-GatewayPolicyAbsent $fresh
            if ((Get-GatewayPolicyStamp $fresh) -cne $stamp -or (Get-CosmosNetworkHash $fresh.standard.gatewayPolicy) -cne (Get-CosmosNetworkHash $state.standard.gatewayPolicy) -or (Get-CosmosNetworkHash $freshLive.binding) -cne (Get-CosmosNetworkHash $live.binding) -or $freshLive.policyHash -cne $live.policyHash -or (Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash -cne $sourceHash) { throw 'State, source, identity or policy changed during attestation' }
            $review = @{source='activation-policy-reuse';activationDeploymentId="/subscriptions/$($state.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-$($state.labId)-activate";policySourceHash=$sourceHash;stateHash=$stamp;bindingHash=(Get-CosmosNetworkHash $live.binding);binding=$live.binding;policyHash=$live.policyHash}
            if ($SelectedAction -ceq 'Status' -and (Get-CosmosNetworkHash $state.standard.gatewayPolicy.review) -cne (Get-CosmosNetworkHash $review)) { throw 'Attested provenance changed' }
            $evidence = @{verifiedAt=[DateTimeOffset]::UtcNow.ToString('o');source=$review.source;activationDeploymentId=$review.activationDeploymentId;policyId=$live.binding.policyId;policyHash=$live.policyHash;policySourceHash=$sourceHash;bindingHash=$review.bindingHash;controlPlaneVerified=$true;inferenceVerified=$false;policyDeploymentSubmitted=$false}
            Write-StandardJson $paths.evidence $evidence
            $fresh.standard.gatewayPolicy=@{pending=$false;verified=$true;name=$names.name;group=$names.group;review=$review;evidence=@{path=$paths.evidence;sha256=(Get-FileHash -LiteralPath $paths.evidence -Algorithm SHA256).Hash;verifiedAt=$evidence.verifiedAt}}
            Save-LabRun $fresh $Path
            Write-Output 'Final activation policy attested read-only; no policy deployment submitted. Inference remains a separate check.'
            return
        }
        if ($SelectedAction -ceq 'Status') {
            $deployment = Read-StandardArm $state $names.deploymentId '2022-09-01' 'policy-status'
            if ($deployment.name -cne $names.name -or $deployment.properties.mode -cne 'Incremental') { throw 'Policy deployment identity or mode mismatch' }
            $status = $deployment.properties.provisioningState
            if ($status -cin @('Accepted','Running','Creating','Updating')) { Write-Output 'Policy deployment active; use Status again.'; return }
            if ($status -isnot [string] -or $status -cne 'Succeeded') { throw 'Policy deployment not Succeeded; receipt retained, no replay' }
            Confirm-StandardIdle $state
            $live = Get-GatewayPolicyLive $state (Get-Content -LiteralPath $policyPath -Raw) -Updated
            Assert-GatewayPolicyReview $state $state.standard.gatewayPolicy.review $live $paths $source $policyPath -Submitted
            Assert-GatewayPolicyDeploymentParameters $deployment.properties.parameters $live.binding.parameters
            $actualTemplate = Invoke-LabAz $state @('deployment','group','export','--resource-group',$names.group,'--name',$names.name) 'policy-export'
            Assert-GatewayPolicyTemplate $actualTemplate (Get-Content -LiteralPath $policyPath -Raw)
            $fresh = Read-LabRun $Path
            Assert-GatewayPolicyState $fresh 'Status'
            if ((Get-GatewayPolicyStamp $fresh) -cne $stamp -or (Get-CosmosNetworkHash $fresh.standard.gatewayPolicy) -cne (Get-CosmosNetworkHash $state.standard.gatewayPolicy)) { throw 'State changed during verification' }
            $evidence = @{verifiedAt=[DateTimeOffset]::UtcNow.ToString('o');deploymentId=$names.deploymentId;policyId=$live.binding.policyId;policyHash=$live.policyHash;controlPlaneVerified=$true;inferenceVerified=$false}
            Write-StandardJson $paths.evidence $evidence
            $fresh.standard.gatewayPolicy.pending=$false; $fresh.standard.gatewayPolicy.verified=$true
            $fresh.standard.gatewayPolicy.evidence=@{path=$paths.evidence;sha256=(Get-FileHash -LiteralPath $paths.evidence -Algorithm SHA256).Hash;verifiedAt=$evidence.verifiedAt}
            Save-LabRun $fresh $Path
            Write-Output 'Existing gateway policy verified. Inference remains a separate check.'
            return
        }
        Confirm-StandardIdle $state
        Confirm-GatewayPolicyAbsent $state
        $live = Get-GatewayPolicyLive $state (Get-Content -LiteralPath $policyPath -Raw)
        $common = @('--resource-group',$names.group,'--name',$names.name,'--mode','Incremental','--template-file',$paths.template,'--parameters',"@$($paths.parameters)")
        if ($SelectedAction -ceq 'Preview') {
            & $state.bicepExecutable build $source --outfile $paths.template *> (Assert-ExternalLabPath (Join-Path $state.runDirectory 'gateway-policy-update.build.txt'))
            if ($LASTEXITCODE -ne 0) { throw 'Local Bicep compilation failed; inspect private build log' }
            Assert-GatewayPolicyTemplate (Get-Content -LiteralPath $paths.template -Raw | ConvertFrom-Json -AsHashtable -Depth 100) (Get-Content -LiteralPath $policyPath -Raw)
            Write-StandardJson $paths.parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$live.binding.parameters}
        } else {
            $review = Get-Content -LiteralPath $paths.review -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            Assert-GatewayPolicyReview $state $review $live $paths $source $policyPath
        }
        $validation = Invoke-LabAz $state (@('deployment','group','validate') + $common) 'policy-validate'
        if ($validation.error -or $validation.properties.provisioningState -cne 'Succeeded') { throw 'ARM validation must succeed' }
        $whatIf = Invoke-LabAz $state (@('deployment','group','what-if','--no-pretty-print') + $common) 'policy-whatif'
        Assert-GatewayPolicyWhatIf $state $live $whatIf
        Confirm-StandardIdle $state
        Confirm-GatewayPolicyAbsent $state
        $fresh = Read-LabRun $Path
        Assert-GatewayPolicyState $fresh $SelectedAction
        if ((Get-GatewayPolicyStamp $fresh) -cne $stamp) { throw 'State changed during review' }
        $freshLive = Get-GatewayPolicyLive $fresh (Get-Content -LiteralPath $policyPath -Raw)
        if ((Get-CosmosNetworkHash $freshLive.binding) -cne (Get-CosmosNetworkHash $live.binding) -or $freshLive.policyHash -cne $live.policyHash) { throw 'Ownership or policy changed immediately before submission' }
        if ($SelectedAction -ceq 'Preview') {
            Write-StandardJson $paths.whatif $whatIf
            $review = @{checkedAt=[DateTimeOffset]::UtcNow.ToString('o');templateHash=(Get-FileHash -LiteralPath $paths.template -Algorithm SHA256).Hash;parametersHash=(Get-FileHash -LiteralPath $paths.parameters -Algorithm SHA256).Hash;sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash;policySourceHash=(Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash;whatifHash=(Get-FileHash -LiteralPath $paths.whatif -Algorithm SHA256).Hash;bindingHash=(Get-CosmosNetworkHash $live.binding);binding=$live.binding;stateHash=$stamp;beforeHash=$live.policyHash}
            Assert-GatewayPolicyReview $fresh $review $freshLive $paths $source $policyPath
            Write-StandardJson $paths.review $review
            Write-Output 'Policy-only preview passed; private artifacts and current policy fingerprint recorded.'
            return
        }
        Assert-GatewayPolicyReview $fresh $review $freshLive $paths $source $policyPath
        $diskReview = Get-Content -LiteralPath $paths.review -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        if ((Get-CosmosNetworkHash $diskReview) -cne (Get-CosmosNetworkHash $review)) { throw 'Review changed before submission' }
        $latest = Read-LabRun $Path
        Assert-GatewayPolicyState $latest 'Deploy'
        if ((Get-GatewayPolicyStamp $latest) -cne $stamp) { throw 'State changed before submission' }
        $latest.standard.gatewayPolicy=@{pending=$true;verified=$false;name=$names.name;group=$names.group;review=$review}
        Save-LabRun $latest $Path
        $null = Invoke-LabAz $latest (@('deployment','group','create') + $common + @('--no-wait')) 'policy-start'
        Write-Output 'Existing policy update submitted; use Status. No parent deployment or rollback performed.'
    } finally { $lock.Dispose() }
}

if ($DefinitionsOnly) { return }
$gatewayPolicyStatePath = $StatePath; $gatewayPolicyAction = $Action
$ErrorActionPreference = 'Stop'
try {
    if (-not $gatewayPolicyStatePath) { throw 'StatePath is required' }
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
    . (Join-Path $PSScriptRoot 'Invoke-StandardStage.ps1') -DefinitionsOnly
    . (Join-Path $PSScriptRoot 'Test-StandardPrivate.ps1') -DefinitionsOnly
    . (Join-Path $PSScriptRoot 'Invoke-StandardCosmosNetwork.ps1') -DefinitionsOnly
    Invoke-LabGatewayPolicy $gatewayPolicyStatePath $gatewayPolicyAction
} catch { throw 'Gateway policy update stopped. Inspect private state and command logs; no rollback or resubmission was performed.' }