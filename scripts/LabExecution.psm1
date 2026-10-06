Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')

function Read-LabRun([string]$StatePath) {
    $path = Assert-ExternalLabPath $StatePath
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-LabState $state
    if ($state.runDirectory -ne [IO.Path]::GetDirectoryName($path)) { throw 'State location mismatch' }
    $null = Assert-ExternalLabPath $state.azureConfigDirectory
    return $state
}

function Save-LabRun([hashtable]$State, [string]$StatePath) {
    Assert-LabState $State
    $path = Assert-ExternalLabPath $StatePath
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $path, $true)
}

function Write-LabEvent([hashtable]$State, [string]$Event, [hashtable]$Details = @{}) {
    $entry = @{ timestamp=[DateTimeOffset]::UtcNow.ToString('o'); event=$Event; details=$Details }
    [IO.File]::AppendAllText((Join-Path $State.runDirectory 'events.jsonl'), (($entry | ConvertTo-Json -Depth 30 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Invoke-LabAz {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments, [Parameter(Mandatory)][string]$Label)
    if ($Label -notmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid command label' }
    $previous = $env:AZURE_CONFIG_DIR
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfff')
    $errorPath = Join-Path $State.runDirectory "$stamp-$Label.stderr.txt"
    try {
        $env:AZURE_CONFIG_DIR = $State.azureConfigDirectory
        $azPath = @(Get-Command az -CommandType Application)[0].Source
        $cliPython = Join-Path ([IO.Path]::GetDirectoryName($azPath)) '../python.exe'
        if ([IO.Path]::GetExtension($azPath) -eq '.cmd' -and (Test-Path $cliPython)) {
            $output = & $cliPython -IBm azure.cli @Arguments --subscription $State.subscriptionId --only-show-errors --output json 2> $errorPath
        } else {
            $output = & $azPath @Arguments --subscription $State.subscriptionId --only-show-errors --output json 2> $errorPath
        }
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"
        $outputPath = Join-Path $State.runDirectory "$stamp-$Label.json"
        [IO.File]::WriteAllText($outputPath, $text, [Text.UTF8Encoding]::new($false))
        Write-LabEvent $State $Label @{exitCode=$exitCode; elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,2); output=[IO.Path]::GetFileName($outputPath); error=[IO.Path]::GetFileName($errorPath)}
        if ($exitCode -ne 0) { throw "Azure command failed ($Label); private stderr: $([IO.Path]::GetFileName($errorPath))" }
        if ($text.Trim()) { return ($text | ConvertFrom-Json -AsHashtable -Depth 100) }
    } finally {
        $env:AZURE_CONFIG_DIR = $previous
        Write-Host "$Label elapsed: $([math]::Round($clock.Elapsed.TotalSeconds,1))s"
    }
}

function Confirm-LabRunContext([hashtable]$State) {
    $context = Invoke-LabAz $State @('account', 'show') 'context'
    Assert-LabContext $State $context
    $groups = @(Invoke-LabAz $State @('group', 'list') 'group-ownership')
    foreach ($group in $groups) {
        if ($group.name -in $State.resourceGroups) {
            if ($group.id -in $State.preexistingGroupIds) { throw 'Pre-existing group cannot be adopted' }
            Assert-LabGroupOwnership $State $group
        }
    }
    return @($groups | Where-Object { $_.name -in $State.resourceGroups })
}

function Assert-LabDeploymentIdle([hashtable]$State) {
    $roots = @(Invoke-LabAz $State @('deployment','sub','list') 'lifecycle-roots')
    foreach ($root in $roots) {
        if ($root.name -like "fgl-$($State.labId)-*" -and $root.properties.provisioningState -notin @('Succeeded','Failed','Canceled')) {
            throw "Deployment is still active: $($root.name). Reconcile Status; do not resubmit."
        }
    }
    foreach ($group in @(Confirm-LabRunContext $State)) {
        $nested = @(Invoke-LabAz $State @('deployment','group','list','--resource-group',$group.name) 'lifecycle-nested')
        if (@($nested | Where-Object { $_.properties.provisioningState -notin @('Succeeded','Failed','Canceled') }).Count) {
            throw "Nested deployment is still active in $($group.name)"
        }
    }
}

function Assert-LabActivationInfrastructure([hashtable]$State) {
    $root = Invoke-LabAz $State @('deployment','sub','show','--name',"fgl-$($State.labId)-lock") 'activation-lock'
    if ($root.properties.provisioningState -cne 'Succeeded') { throw 'Completed lock deployment required' }
    $lab = Get-Content -LiteralPath (Join-Path $State.runDirectory 'outputs.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    foreach ($target in @(Get-LabPrivateTargets $State $lab)) {
        $version = switch ($target.key) {
            'gateway' { '2024-05-01' }
            { $_ -like 'registry-*' } { '2023-07-01' }
            default { '2026-05-01' }
        }
        $resource = Invoke-LabAz $State @('resource','show','--ids',$target.resourceId,'--api-version',$version) 'activation-resource'
        if ($resource.id -ine $target.resourceId -or $resource.tags['fgl-owner'] -cne $State.ownershipId -or $resource.tags['fgl-lab'] -cne $State.labId -or $resource.properties.provisioningState -ine 'Succeeded' -or $resource.properties.publicNetworkAccess -cne 'Disabled') {
            throw 'Activation requires owned, provisioned services with public access disabled'
        }
        if ($target.key -eq 'models' -or $target.key -like 'case-*') {
            if ($resource.properties.disableLocalAuth -isnot [bool] -or -not $resource.properties.disableLocalAuth) { throw 'Foundry local authentication must remain disabled' }
        }
        $endpoint = Invoke-LabAz $State @('resource','show','--ids',$target.endpointId,'--api-version','2024-05-01') 'activation-endpoint'
        $connections = @($endpoint.properties.privateLinkServiceConnections)
        if ($endpoint.id -ine $target.endpointId -or $endpoint.tags['fgl-owner'] -cne $State.ownershipId -or $endpoint.tags['fgl-lab'] -cne $State.labId -or $endpoint.properties.provisioningState -ine 'Succeeded' -or $connections.Count -ne 1) { throw 'Owned provisioned private endpoint required' }
        if ($connections[0].properties.privateLinkServiceId -ine $target.resourceId -or $connections[0].properties.privateLinkServiceConnectionState.status -cne 'Approved' -or @($connections[0].properties.groupIds).Count -ne 1 -or $connections[0].properties.groupIds[0] -cne $target.groupId) { throw 'Private endpoint target or approval mismatch' }
    }
    Write-LabEvent $State 'activation-infrastructure' @{managementOnly=$true; runtimeTestPerformed=$false}
}

function Get-LabPrivateTargets([hashtable]$State, [hashtable]$Lab) {
    Assert-LabState $State
    $minimalPrompt = $State['minimalPrompt'] -eq $true
    if (($Lab.ContainsKey('minimalPrompt') -and $Lab.minimalPrompt -isnot [bool]) -or ($Lab['minimalPrompt'] -eq $true) -ne $minimalPrompt) { throw 'Output profile mismatch' }
    if (@($Lab.resourceGroups).Count -ne $State.resourceGroups.Count -or @(Compare-Object $Lab.resourceGroups $State.resourceGroups).Count) { throw 'Output group set mismatch' }
    $stem = "fgl-$($State.labId)"
    $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/rg-$stem"
    $modelPrefix = "$prefix-models/providers/Microsoft.CognitiveServices/accounts/aif-$stem-models-"
    if ($Lab.models -cnotmatch ('^' + [regex]::Escape($modelPrefix) + '([a-z0-9]{13})$')) { throw 'Unexpected models output' }
    $suffix = $Matches[1]
    if ($Lab.gateway -ine "$prefix-integration/providers/Microsoft.ApiManagement/service/apim-$stem-$suffix") { throw 'Unexpected gateway output' }
    $targets = @(
        @{resourceId=$Lab.gateway; group='integration'; key='gateway'; groupId='Gateway'; dnsSuffix='azure-api.net'},
        @{resourceId=$Lab.models; group='models'; key='models'; groupId='account'; dnsSuffix='openai.azure.com'}
    )
    $caseIds = @(if ($minimalPrompt) { 'a' } else { 'a','b' })
    $environments = @(if ($minimalPrompt) { 'dev' } else { 'dev','test' })
    if (@($Lab.cases).Count -ne $caseIds.Count) { throw 'Unexpected case count for profile' }
    foreach ($caseIndex in 0..($caseIds.Count - 1)) {
        $caseId = $caseIds[$caseIndex]
        $case = $Lab.cases[$caseIndex]
        $accountId = "$prefix-case-$caseId/providers/Microsoft.CognitiveServices/accounts/aif-$stem-$caseId-$suffix"
        if ($case.accountId -ine $accountId) { throw 'Unexpected case resource ID' }
        $projects = @($environments | ForEach-Object { "$accountId/projects/case-$caseId-$_" })
        $actualProjects = @($case.projects | ForEach-Object { $_.resourceId })
        if ($actualProjects.Count -ne $projects.Count -or @(Compare-Object $actualProjects $projects).Count) { throw 'Unexpected project set for profile' }
        $targets += @{resourceId=$accountId; group="case-$caseId"; key="case-$caseId"; groupId='account'; dnsSuffix='services.ai.azure.com'}
        if ($minimalPrompt) {
            if ($case.registryId -cne '') { throw 'Minimal prompt profile must not have a registry' }
        } else {
            if ($case.registryId -ine "$prefix-case-$caseId/providers/Microsoft.ContainerRegistry/registries/crfgl$($State.labId)$caseId$suffix") { throw 'Unexpected registry output' }
            $targets += @{resourceId=$case.registryId; group="case-$caseId"; key="registry-$caseId"; groupId='registry'; dnsSuffix='azurecr.io'}
        }
    }
    foreach ($target in $targets) {
        Assert-LabResourceId $State $target.resourceId
        $target.hostName = ($target.resourceId -split '/')[-1] + '.' + $target.dnsSuffix
        $target.endpointId = "$prefix-$($target.group)/providers/Microsoft.Network/privateEndpoints/pe-$stem-$($target.key)"
    }
    return $targets
}

function Assert-LabPrivateReport([array]$Targets, [hashtable]$Report, [hashtable]$Addresses) {
    $actual = @($Report.checks | ForEach-Object { $_.hostName })
    $expected = @($Targets | ForEach-Object { $_.hostName })
    if (-not $expected.Count -or $actual.Count -ne $expected.Count -or @(Compare-Object $actual $expected).Count -or $Report.gatewayStatus -ne 404) { throw 'Private probe coverage incomplete' }
    foreach ($check in $Report.checks) {
        if ($check.tcp443 -isnot [bool] -or -not $check.tcp443 -or $check.addresses -isnot [array] -or -not $check.addresses.Count -or -not $Addresses.ContainsKey($check.hostName)) { throw 'Private probe evidence incomplete' }
        foreach ($address in $check.addresses) {
            $parsed = $null
            if (-not [Net.IPAddress]::TryParse([string]$address, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $address -notmatch '^10\.76\.' -or $address -notin $Addresses[$check.hostName]) { throw 'DNS resolved outside the matching owned endpoint NICs' }
        }
    }
}

Export-ModuleMember -Function Read-LabRun, Save-LabRun, Write-LabEvent, Invoke-LabAz, Confirm-LabRunContext, Get-LabPrivateTargets, Assert-LabPrivateReport, Assert-LabDeploymentIdle, Assert-LabActivationInfrastructure