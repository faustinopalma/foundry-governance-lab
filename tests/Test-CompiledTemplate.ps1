[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    if ($document.ContainsKey('template')) {
        if (-not $document.success -or @($document.diagnostics | Where-Object level -eq 'Error').Count) { throw 'Compiler reported errors' }
        $document = $document.template | ConvertFrom-Json -AsHashtable -Depth 100
    }
    function Find-Modules([hashtable]$Template, [string]$Name) {
        $resources = if ($Template.resources -is [Collections.IDictionary]) { $Template.resources.Values } else { $Template.resources }
        foreach ($resource in $resources) {
            if ($resource.type -eq 'Microsoft.Resources/deployments') {
                if ($resource.name -eq $Name) { $resource }
                if ($resource.properties.ContainsKey('template')) { Find-Modules $resource.properties.template $Name }
            }
        }
    }
    function Get-OneModule([hashtable]$Template, [string]$Name) {
        $matches = @(Find-Modules $Template $Name)
        if ($matches.Count -ne 1) { throw "Expected exactly one compiled module: $Name" }
        return $matches[0]
    }
    function Assert-CompiledProfiles([hashtable]$Template) {
        if ($Template.parameters.minimalPrompt.type -ne 'bool' -or $Template.parameters.minimalPrompt.defaultValue -ne $false) { throw 'Full topology must remain the default' }
        if ($Template.variables.groupSuffixes -cne "[if(parameters('minimalPrompt'), createArray('models', 'integration', 'case-a'), createArray('models', 'integration', 'case-a', 'case-b'))]") { throw 'Unexpected profile group sets' }
        if ($Template.variables.caseIds -cne "[if(parameters('minimalPrompt'), createArray('a'), createArray('a', 'b'))]") { throw 'Unexpected profile case sets' }
        $groups = @($Template.resources | Where-Object type -eq 'Microsoft.Resources/resourceGroups')
        if ($groups.Count -ne 1 -or $groups[0].copy.count -ne "[length(variables('groupSuffixes'))]") { throw 'Unexpected profile group loop' }
        foreach ($loopName in @('cases','caseEndpoints','registryEndpoints','agentCandidates')) {
            $loop = @($Template.resources | Where-Object { $_.copy.name -eq $loopName })
            if ($loop.Count -ne 1 -or $loop[0].copy.count -ne "[length(variables('caseIds'))]") { throw "Unexpected case loop: $loopName" }
            if ($loopName -eq 'registryEndpoints' -and ($loop[0].condition -isnot [string] -or $loop[0].condition -ne "[not(parameters('minimalPrompt'))]")) { throw 'Minimal registry endpoint is not excluded' }
            if ($loopName -in @('cases','agentCandidates') -and $loop[0].properties.parameters.minimalPrompt.value -ne "[parameters('minimalPrompt')]") { throw 'Profile not forwarded to child module' }
        }
        $monitoring = @($Template.resources | Where-Object { $_.copy.name -eq 'monitoring' })
        if ($monitoring.Count -ne 1 -or $monitoring[0].copy.count -ne "[length(range(0, add(length(variables('caseIds')), 1)))]") { throw 'Monitoring must match integration plus active cases' }
        $case = @($Template.resources | Where-Object { $_.copy.name -eq 'cases' })[0].properties.template
        if ($case.parameters.minimalPrompt.defaultValue -ne $false -or $case.variables.environments -ne "[if(parameters('minimalPrompt'), createArray('dev'), createArray('dev', 'test'))]") { throw 'Unexpected project environment sets' }
        $caseResources = if ($case.resources -is [Collections.IDictionary]) { $case.resources.Values } else { $case.resources }
        $projects = @($caseResources | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/projects')
        if ($projects.Count -ne 1 -or $projects[0].copy.count -ne "[length(variables('environments'))]" -or $case.outputs.projects.copy.count -ne "[length(range(0, length(variables('environments'))))]") { throw 'Project loop or outputs exceed profile' }
        $registry = Get-OneModule $case 'case-registry'
        if ($registry.condition -isnot [string] -or $registry.condition -ne "[not(parameters('minimalPrompt'))]" -or $case.outputs.registryId.value -ne "[if(parameters('minimalPrompt'), '', reference('registry').outputs.resourceId.value)]" -or $case.outputs.registryLoginServer.value -ne "[if(parameters('minimalPrompt'), '', reference('registry').outputs.loginServer.value)]") { throw 'Minimal registry or output is not excluded' }
        $candidate = @($Template.resources | Where-Object { $_.copy.name -eq 'agentCandidates' })[0].properties.template
        $hosts = @($candidate.resources | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts')
        if ($hosts.Count -ne 1 -or $hosts[0].condition -isnot [string] -or $hosts[0].condition -ne "[and(parameters('enableCapabilityHosts'), not(parameters('minimalPrompt')))]") { throw 'Hosted capability hosts must be excluded from minimal profile' }
        $scope = @($Template.resources | Where-Object { $_.name -like '*{0}-monitor-scope*' })[0]
        $links = $scope.properties.parameters.linkedResourceIds.value
        $branches = $links.Split("if(parameters('minimalPrompt'), createArray(), ", [StringSplitOptions]::None)
        if ($branches.Count -ne 2 -or [regex]::Matches($branches[0], '\.outputs\.(workspaceId|insightsId)\.value').Count -ne 4 -or [regex]::Matches($branches[1], '\.outputs\.(workspaceId|insightsId)\.value').Count -ne 2) { throw 'Monitor link branches must contain four minimal and six full links' }
        $api = @($Template.resources | Where-Object { $_.name -like '*{0}-gateway-api*' })[0]
        $callers = $api.properties.parameters.allowedPrincipalIds.value
        $branches = $callers.Split("if(parameters('minimalPrompt'), createArray(), ", [StringSplitOptions]::None)
        $optionalCaseIndex = "variables('caseIds')[min(1, sub(length(variables('caseIds')), 1))]"
        if ($branches.Count -ne 2 -or $branches[0].Contains($optionalCaseIndex) -or -not $branches[1].Contains($optionalCaseIndex) -or -not $callers.Contains('.outputs.actors.value[5].principalId') -or $callers.Contains('.outputs.actors.value[6].principalId')) { throw 'Gateway allowlist must retain client and exclude denied and absent case callers' }
        if ($Template.outputs.lab.value.minimalPrompt -ne "[parameters('minimalPrompt')]" -or -not $Template.outputs.lab.value.cases.Contains("if(parameters('minimalPrompt'), createArray(), ")) { throw 'Output topology must retain the selected profile' }
    }
    function Assert-CompiledBoundaries([hashtable]$Template) {
        foreach ($resource in $Template.resources) {
            if (-not $resource.ContainsKey('copy') -and $resource.type -eq 'Microsoft.Resources/deployments') {
                $outerProperties = @{name=$resource.name; scope=$resource.resourceGroup; parameters=$resource.properties.parameters; dependsOn=$resource.dependsOn} | ConvertTo-Json -Depth 100 -Compress
                if ($outerProperties -match 'copyIndex\(') { throw 'Loop index escaped into a non-loop deployment' }
            }
        }
        if ($Template.parameters.phase.defaultValue -ne 'bootstrap' -or $Template.parameters.enableExperimentalAgents.defaultValue -ne $false) { throw 'Unsafe deployment defaults' }
        Assert-CompiledProfiles $Template
        if (@($Template.resources | Where-Object { $_.type -notin @('Microsoft.Resources/resourceGroups', 'Microsoft.Resources/deployments') }).Count) { throw 'Unexpected subscription-level mutation' }
        $models = (Get-OneModule $Template 'models-account').properties.parameters
        if ($models.publicNetworkAccess.value -ne 'Disabled' -or $models.disableLocalAuth.value -ne $true -or $models.allowProjectManagement.value -ne $false) { throw 'Central model boundary missing' }
        if (@($models.deployments.value).Count -ne 1 -or $models.deployments.value[0].sku.capacity -ne 10) { throw 'Unexpected model allocation' }
        $account = (Get-OneModule $Template 'case-account').properties.parameters
        if ($account.publicNetworkAccess.value -ne 'Disabled' -or $account.disableLocalAuth.value -ne $true -or @($account.deployments.value).Count -ne 0) { throw 'Case model boundary missing' }
        if ($account.networkInjections.value.scenario -ne 'agent' -or $account.networkInjections.value.useMicrosoftManagedNetwork -ne $false) { throw 'Creation-time private runtime network injection missing' }
        $registry = (Get-OneModule $Template 'case-registry').properties.parameters
        if ($registry.acrSku.value -ne 'Premium' -or $registry.roleAssignmentMode.value -ne 'AbacRepositoryPermissions') { throw 'Registry ABAC/private-link mismatch' }
        if ($registry.publicNetworkAccess.value -ne 'Disabled' -or $registry.acrAdminUserEnabled.value -ne $false -or $registry.anonymousPullEnabled.value -ne $false -or $registry.networkRuleBypassOptions.value -ne 'None') { throw 'Registry exposure' }
        $runner = (Get-OneModule $Template 'runner').properties.parameters
        if ($runner.disablePasswordAuthentication.value -ne $true -or $runner.securityType.value -ne 'TrustedLaunch') { throw 'Runner auth configuration changed' }
        if ($runner.nicConfigurations.value[0].ipConfigurations[0].ContainsKey('pipConfiguration')) { throw 'Runner public IP configured' }
        $gateway = (Get-OneModule $Template 'gateway').properties.parameters
        if ($gateway.sku.value -ne 'StandardV2' -or $gateway.skuCapacity.value -ne 1) { throw 'Gateway cost/network pairing changed' }
        $lockdown = $gateway.publicNetworkAccess
        $validLockdown = if ($lockdown -is [string]) {
            $lockdown -eq "[if(parameters('privateOnly'), createObject('value', 'Disabled'), createObject('value', 'Enabled'))]"
        } else {
            $lockdown.value -eq "[if(parameters('privateOnly'), 'Disabled', 'Enabled')]"
        }
        if (-not $validLockdown) { throw 'Gateway lockdown switch changed' }
        $apiModules = @($Template.resources | Where-Object { $_.name -like '*{0}-gateway-api*' })
        if ($apiModules.Count -ne 1 -or $apiModules[0].condition -ne "[equals(parameters('phase'), 'activate')]") { throw 'Inference API exists before activation' }
        $schemas = @($apiModules[0].properties.template.resources | Where-Object type -eq 'Microsoft.ApiManagement/service/schemas')
        if ($schemas.Count -ne 1 -or $schemas[0].properties.ContainsKey('value') -or -not $schemas[0].properties.ContainsKey('document')) { throw 'JSON schema must use document, not value' }
        $operations = @($apiModules[0].properties.template.resources | Where-Object type -eq 'Microsoft.ApiManagement/service/apis/operations')
        if ($operations.Count -ne 1 -or $operations[0].properties.request.representations[0].contentType -ne 'application/json') { throw 'Approved JSON request representation missing' }
        $privateNetwork = (Get-OneModule $Template 'network').properties.parameters
        if (@($privateNetwork.peerings.value).Count -ne 0 -or $privateNetwork.addressPrefixes.value[0] -ne '10.76.0.0/16') { throw 'Lab network boundary changed' }
        $endpointRules = (Get-OneModule $Template 'endpoint-nsg').properties.parameters.securityRules.value
        if (@($endpointRules | Where-Object { $_.name -eq 'deny-other-inbound' -and $_.properties.access -eq 'Deny' -and $_.properties.priority -lt 65000 }).Count -ne 1) { throw 'Private endpoint NSG relies on default AllowVNet' }
        $runnerRules = (Get-OneModule $Template 'runner-nsg').properties.parameters.securityRules.value
        if ($runnerRules[0].properties.access -ne 'Deny' -or $runnerRules[0].properties.direction -ne 'Inbound') { throw 'Runner inbound isolation missing' }
        return 21
    }
    $checks = Assert-CompiledBoundaries $document
    $baseline = $document | ConvertTo-Json -Depth 100 -Compress
    $mutations = @(
        { param($template) (Get-OneModule $template 'models-account').properties.parameters.publicNetworkAccess.value = 'Enabled' },
        { param($template) $template.parameters.minimalPrompt.defaultValue = $true },
        { param($template) $template.variables.groupSuffixes = @('models','integration','case-a','case-b') },
        { param($template) (Get-OneModule $template 'case-registry').condition = $true },
        { param($template) @($template.resources | Where-Object { $_.copy.name -eq 'registryEndpoints' })[0].condition = $true },
        { param($template) @($template.resources | Where-Object { $_.copy.name -eq 'cases' })[0].properties.parameters.minimalPrompt.value = $false },
        { param($template) @($template.resources | Where-Object { $_.copy.name -eq 'cases' })[0].properties.template.variables.environments = @('dev','test') },
        { param($template) @($template.resources | Where-Object { $_.copy.name -eq 'monitoring' })[0].copy.count = 3 },
        { param($template) (Get-OneModule $template 'case-account').properties.parameters.networkInjections = @{value=$null} },
        { param($template) @($template.resources | Where-Object { $_.copy.name -eq 'agentCandidates' })[0].properties.parameters.minimalPrompt.value = $false }
    )
    foreach ($mutation in $mutations) {
        $altered = $baseline | ConvertFrom-Json -AsHashtable -Depth 100
        & $mutation $altered
        $rejected = $false
        try { $null = Assert-CompiledBoundaries $altered } catch { $rejected = $true }
        if (-not $rejected) { throw "Compiled-template negative control failed: $mutation" }
    }
    Write-Output "PASS: compiled boundaries and both topology branches checked; $($mutations.Count) deliberate regressions rejected (structural validation, not ARM execution)"
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}