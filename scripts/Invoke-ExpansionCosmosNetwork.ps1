[CmdletBinding()]
param(
    [string]$StatePath,
    [ValidateSet('a-test','b-dev','b-test')][string]$Project,
    [ValidateSet('Preview','Deploy','Status')][string]$Action = 'Preview',
    [string]$BicepExecutable = 'bicep',
    [switch]$ApproveNetwork,
    [switch]$DefinitionsOnly
)

$networkInvocation=@{Path=$StatePath;Selector=$Project;SelectedAction=$Action;Compiler=$BicepExecutable;Approved=[bool]$ApproveNetwork}
$networkDefinitions=[bool]$DefinitionsOnly
foreach ($networkHelper in @('Invoke-ExpansionStandard.ps1','ExpansionCosmosNetwork.ps1','Test-ExpansionPrivate.ps1','Invoke-ExpansionWatchdog.ps1')) { . (Join-Path $PSScriptRoot $networkHelper) -DefinitionsOnly }

function Get-ExpansionNetworkPaths([hashtable]$State, [string]$Selector) {
    if ($Selector -cnotin @('a-test','b-dev','b-test')) { throw 'Exact expansion selector required' }
    $paths=@{lock=(Assert-ExternalLabPath (Join-Path $State.runDirectory 'expansion-standard.lock'))}
    foreach ($key in @('state','template','parameters','whatif','deploy-whatif','outputs')) { $paths[$key]=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-cosmos-$Selector.$key.json") }
    $paths.source=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-cosmos-$Selector.bicep")
    $paths.evidence=Assert-ExternalLabPath (Join-Path $State.runDirectory "expansion-cosmos-$Selector-evidence")
    return $paths
}

function Get-ExpansionNetworkSources {
    $hashes=Get-ExpansionStandardSources
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    foreach ($relative in @('scripts/ExpansionCosmosNetwork.ps1','scripts/Invoke-ExpansionCosmosNetwork.ps1','scripts/Test-ExpansionPrivate.ps1','scripts/Invoke-ExpansionWatchdog.ps1','tests/Test-ExpansionCosmosNetwork.ps1','tests/Test-ExpansionCosmosNetworkCoordinator.ps1')) { $hashes[$relative]=(Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash }
    return $hashes
}

function Assert-ExpansionNetworkTransition($Manifest, [hashtable]$All, [hashtable]$Dependencies, [string]$Selector, [string]$SelectedAction, [bool]$Approved) {
    if ($Selector -cnotin @('a-test','b-dev','b-test') -or $SelectedAction -cnotin @('Preview','Deploy','Status')) { throw 'Invalid network action or selector' }
    Assert-FoundationSet @($Dependencies.Keys) @('a-test','b-dev','b-test')
    foreach ($selection in $Dependencies.Keys) {
        $dependency=$Dependencies[$selection]
        Assert-FoundationEqual $dependency.project $selection
        Assert-FoundationEqual $dependency.stage 'dependencies'
        Assert-FoundationEqual $dependency.pending $false
        Assert-FoundationEqual $dependency.verified $true
    }
    foreach ($selection in $All.Keys) {
        $entry=$All[$selection]
        if ($selection -cnotin @('a-test','b-dev','b-test') -or $entry -isnot [hashtable]) { throw 'Unexpected network manifest' }
        Assert-FoundationEqual $entry.project $selection
        Assert-FoundationEqual $entry.stage 'cosmos-network'
        if ($entry.pending -isnot [bool] -or $entry.verified -isnot [bool] -or ($entry.pending -and $entry.verified)) { throw 'Invalid network intent' }
        if ($entry.verified -and ($entry.outputHash -isnot [string] -or $entry.outputHash -cnotmatch '^[A-F0-9]{64}$')) { throw 'Verified network receipt hash required' }
        if (-not $entry.verified -and $entry.ContainsKey('outputHash')) { throw 'Unverified network intent cannot have an output seal' }
        if ($entry.pending -and $selection -cne $Selector) { throw 'Another expansion network operation is pending' }
        if (-not $entry.pending -and -not $entry.verified -and ($entry.deploymentId -or $entry.submittedAt)) { throw 'Submission intent cannot be cleared' }
    }
    if ($SelectedAction -cne 'Status' -and -not $Approved) { throw 'ApproveNetwork required' }
    if ($SelectedAction -ceq 'Status') {
        if ($Manifest -isnot [hashtable] -or (-not $Manifest.pending -and -not $Manifest.verified)) { throw 'Status requires persisted submission intent' }
    } elseif ($Manifest -and ($Manifest.pending -or $Manifest.verified)) { throw 'Submitted network step cannot be replayed' }
    elseif ($SelectedAction -ceq 'Deploy' -and $Manifest -isnot [hashtable]) { throw 'Preview required before Deploy' }
}

function New-ExpansionNetworkBicep([hashtable]$Binding) {
    $template=New-ExpansionCosmosNetworkTemplate $Binding $Binding.names.scope
    Assert-ExpansionCosmosNetworkTemplate $template $Binding $Binding.names.scope
    $rule=$template.resources[0]; $properties=$rule.properties
    $addresses=(@($properties.destinationAddressPrefixes | ForEach-Object { "    '$_'" }) -join "`n")
    return @"
targetScope = 'resourceGroup'
resource cosmosDirect 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  name: '$($rule.name)'
  properties: {
    priority: $($properties.priority)
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: '$($properties.sourceAddressPrefix)'
    sourcePortRange: '*'
    destinationAddressPrefixes: [
$addresses
    ]
    destinationPortRange: '*'
  }
}
"@
}

function Assert-ExpansionNetworkCompiled($Template, [hashtable]$Binding) {
    Assert-CosmosNetworkKeys $Template @('$schema','contentVersion','resources') @('metadata')
    $copy=Read-ExpansionStandardCopy $Template
    if ($copy.ContainsKey('metadata')) {
        Assert-CosmosNetworkKeys $copy.metadata @('_generator')
        Assert-CosmosNetworkKeys $copy.metadata._generator @('name','version','templateHash')
        Assert-FoundationEqual $copy.metadata._generator.name 'bicep'
        foreach ($key in @('version','templateHash')) { if ($copy.metadata._generator[$key] -isnot [string] -or -not $copy.metadata._generator[$key]) { throw 'Bicep generator metadata missing' } }
        $copy.Remove('metadata')
    } else { throw 'Compiled Bicep provenance required' }
    Assert-ExpansionCosmosNetworkTemplate $copy $Binding $Binding.names.scope
}

function Assert-ExpansionNetworkWhatIf([hashtable]$Binding, [hashtable]$Known, $Result) {
    if ($Result -isnot [hashtable] -or $Result.status -cne 'Succeeded' -or $Result.changes -isnot [array] -or -not $Result.changes.Count) { throw 'Successful FullResourcePayloads what-if required' }
    function Assert-NetworkKnownFields($Sparse, $Full) {
        if ($Sparse -is [hashtable]) {
            if ($Full -isnot [hashtable]) { throw 'Known resource object required' }
            foreach ($key in $Sparse.Keys) {
                if (-not $Full.ContainsKey($key)) { throw 'Unknown Ignore field' }
                Assert-NetworkKnownFields $Sparse[$key] $Full[$key]
            }
        } else { Assert-FoundationEqual $Sparse $Full }
    }
    $seen=@{}; $created=0
    foreach ($change in $Result.changes) {
        $id=$change.resourceId
        if ($change -isnot [hashtable] -or $id -isnot [string] -or [string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id) -or @($change.delta).Where({$null -ne $_}).Count -or @($change.diff).Where({$null -ne $_}).Count) { throw 'Duplicate or unexpanded change' }
        $seen[$id]=$true
        if ($id -ieq $Binding.names.ruleId) {
            Assert-FoundationEqual $change.changeType 'Create'
            if ($null -ne $change.before) { throw 'Existing rule cannot be adopted' }
            Assert-ExpansionCosmosNetworkRule $change.after $Binding
            $created++
        } else {
            Assert-FoundationEqual $change.changeType 'Ignore'
            if (-not $Known.ContainsKey($id) -or $change.before -isnot [hashtable] -or $change.after -isnot [hashtable]) { throw 'Ignore requires an exact known snapshot' }
            $record=$Known[$id]
            if ($record -isnot [hashtable] -or $record.type -isnot [string] -or [string]::IsNullOrWhiteSpace($record.type)) { throw 'Known Ignore type required' }
            Assert-FoundationText $record.id $id
            Assert-FoundationText $change.before.id $id
            Assert-FoundationText $change.before.type $record.type
            Assert-FoundationEqual $change.before $change.after
            if ($record.tags -is [hashtable] -and $record.tags.Count) { Assert-FoundationOwned $Binding $record $id }
            if ($change.before.ContainsKey('tags') -and $record.tags -is [hashtable] -and $record.tags.Count) { Assert-FoundationOwned $Binding $change.before $id }
            $sparse=$change.before.Clone(); $sparse.Remove('id'); $sparse.Remove('type')
            if ($sparse.ContainsKey('resourceGroup')) { Assert-FoundationText $sparse.resourceGroup ($id -split '/')[4]; $sparse.Remove('resourceGroup') }
            Assert-NetworkKnownFields $sparse $record
        }
    }
    if ($created -ne 1) { throw 'Exactly one expanded NSG child Create required' }
}

function Invoke-ExpansionNetworkProcess([hashtable]$State, [string]$Executable, [string[]]$Arguments, [int]$Budget = 90) {
    $capture=Invoke-BoundedLabProcess -Executable $Executable -Arguments $Arguments -LogPrefix (Join-Path $State.evidenceDirectory ([guid]::NewGuid().ToString('N'))) -MaxSeconds $Budget -IdleSeconds ([math]::Min($Budget,120)) -Environment @{AZURE_CONFIG_DIR=$State.azureConfigDirectory;AZURE_CORE_NO_COLOR='true';AZURE_CORE_COLLECT_TELEMETRY='false'}
    if ($capture.reason -cne 'Exited' -or $capture.exitCode -ne 0) { throw "Bounded network process failed; intent retained. Private stderr: $($capture.stderr)" }
    return $capture
}

function Invoke-ExpansionNetworkAz([hashtable]$State, [string[]]$Arguments, [switch]$Empty) {
    $application=@(Get-Command az -CommandType Application -ErrorAction Stop)[0].Source
    $prefix=@()
    if ([IO.Path]::GetExtension($application) -ieq '.cmd') {
        $application=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($application)) '../python.exe'))
        if (-not (Test-Path -LiteralPath $application -PathType Leaf)) { throw 'CLI executable missing; no shell fallback' }
        $prefix=@('-IBm','azure.cli')
    }
    $capture=Invoke-ExpansionNetworkProcess $State $application ($prefix+$Arguments+@('--subscription',$State.subscriptionId,'--output','json','--only-show-errors'))
    $text=[IO.File]::ReadAllText($capture.stdout)
    if ($Empty -and [string]::IsNullOrWhiteSpace($text)) { return }
    return Read-FoundationJson $capture.stdout
}

function Read-ExpansionNetworkArm([hashtable]$State, [string]$Id, [string]$Api, [switch]$List) {
    if (-not $Id.StartsWith("/subscriptions/$($State.subscriptionId)/",[StringComparison]::OrdinalIgnoreCase) -or $Id -match '[?#%\\]' -or $Id.Contains('/../')) { throw 'Foreign or malformed ARM target' }
    $result=Invoke-ExpansionNetworkAz $State @('rest','--method','get','--url',"https://management.azure.com${Id}?api-version=$Api",'--headers','Accept=application/json')
    if ($result -isnot [hashtable]) { throw 'Complete ARM object required' }
    if ($List) {
        if ($result.value -isnot [array] -or $result.nextLink) { throw 'Complete unpaginated ARM list required' }
        $seen=@{}
        foreach ($item in $result.value) {
            if ($item -isnot [hashtable] -or $item.id -isnot [string] -or -not $item.id -or $seen.ContainsKey($item.id)) { throw 'Malformed or duplicate ARM list item' }
            $seen[$item.id]=$true
        }
        return $result.value
    }
    Assert-FoundationText $result.id $Id
    return $result
}

function Get-ExpansionNetworkPrivateReceipt([hashtable]$State, [string]$Selector, [hashtable]$ExpectedInputs, [hashtable]$ExpectedSources, [hashtable]$Output) {
    $candidates=@()
    foreach ($directory in @(Get-ChildItem -LiteralPath $State.runDirectory -Directory -Filter "expansion-private-$Selector-*")) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Private receipt directory cannot be a link' }
        $file=Assert-ExternalLabPath (Join-Path $directory.FullName 'receipt.json')
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $receipt=Read-FoundationJson $file
        if ($receipt.success -isnot [bool]) { throw 'Malformed private receipt' }
        if (-not $receipt.success) { continue }
        $verified=[DateTimeOffset]::Parse([string]$receipt.verifiedAt)
        $checked=[DateTimeOffset]::Parse([string]$receipt.checkedAt)
        if ($verified -gt [DateTimeOffset]::UtcNow -or $checked -gt $verified) { throw 'Invalid private receipt time' }
        $candidates+=@{path=$file;receipt=$receipt;time=$verified}
    }
    if (-not $candidates.Count) { throw 'Successful separate private receipt required for every dependency' }
    $ordered=@($candidates | Sort-Object time -Descending)
    if ($ordered.Count -gt 1 -and $ordered[0].time -eq $ordered[1].time) { throw 'Ambiguous latest private receipt' }
    $latest=$ordered[0]; $receipt=$latest.receipt
    Assert-FoundationEqual $receipt.project $Selector
    Assert-FoundationText $receipt.reportPath $latest.path
    Assert-FoundationEqual $receipt.runtimeVerified $false
    Assert-FoundationEqual $receipt.inferenceVerified $false
    Assert-FoundationEqual $receipt.scope 'runner DNS and TLS only'
    Assert-FoundationEqual $receipt.inputHashes $ExpectedInputs
    Assert-FoundationEqual $receipt.sourceHashes $ExpectedSources
    if ($latest.time -lt [DateTimeOffset]::Parse([string]$Output.verifiedAt)) { throw 'Private receipt predates dependency verification' }
    if ($receipt.binding -isnot [hashtable] -or $receipt.ownedAddresses -isnot [hashtable] -or -not $receipt.ownedAddresses.Count -or $receipt.checks -isnot [array] -or -not $receipt.checks.Count) { throw 'Private evidence incomplete' }
    return @{path=$latest.path;sha256=(Get-FileHash -LiteralPath $latest.path -Algorithm SHA256).Hash;receipt=$receipt}
}

function Get-ExpansionNetworkPrerequisites([hashtable]$State, [string]$OriginalPath, [string]$Compiler, [hashtable]$FoundationBinding) {
    $inputs=Get-FoundationInputHashes $State $OriginalPath
    $dependencies=@{}; $outputs=@{}; $files=@{}; $private=@{}
    foreach ($selection in @('a-test','b-dev','b-test')) {
        $paths=Get-ExpansionStandardPaths $State $selection
        $dependencies[$selection]=Read-FoundationJson $paths.state
        $outputs[$selection]=Read-FoundationJson $paths.outputs
        foreach ($key in @('state','outputs')) { $files[$paths[$key]]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
    }
    Assert-ExpansionNetworkTransition $null @{} $dependencies 'a-test' 'Preview' $true
    $lab=Read-FoundationJson (Join-Path $State.runDirectory 'outputs.json')
    function Get-FoundationComputedNames([string]$AccountName, [string]$EndpointName, [string]$Compiler) {
        if ($AccountName -cnotmatch '^aif-fgl-[a-z0-9]{6,12}-b-[a-z0-9]{13}$' -or $EndpointName -cnotmatch '^pe-fgl-[a-z0-9]{6,12}-case-b$') { throw 'Invalid deterministic naming input' }
        $source=Assert-ExternalLabPath (Join-Path $State.evidenceDirectory ('names-'+[guid]::NewGuid().ToString('N')+'.bicepparam'))
        $output="$source.json"
        [IO.File]::WriteAllText($source,"using none`nparam dns = uniqueString('$EndpointName')`nparam reader = guid('$AccountName', 'developer-reader')`nparam user = guid('$AccountName', 'b', 'dev-foundry-user')`n")
        $null=Invoke-ExpansionNetworkProcess $State $Compiler @('build-params',$source,'--no-restore','--outfile',$output)
        $values=(Read-FoundationJson $output).parameters
        if ($values.dns.value -isnot [string] -or $values.dns.value -cnotmatch '^[a-z0-9]{13}$') { throw 'Invalid compiled DNS name' }
        Assert-FoundationGuid $values.reader.value; Assert-FoundationGuid $values.user.value
        return @{dns=$values.dns.value;reader=$values.reader.value;user=$values.user.value}
    }
    $foundation=$FoundationBinding
    if (-not $foundation) { $foundation=Get-FoundationBinding $State $lab $Compiler }
    $foundationPaths=Get-FoundationPaths $State
    $seal=@{manifest=(Read-FoundationJson $foundationPaths.state);output=(Read-FoundationJson $foundationPaths.outputs)}
    foreach ($key in @('state','outputs')) { $files[$foundationPaths[$key]]=(Get-FileHash -LiteralPath $foundationPaths[$key] -Algorithm SHA256).Hash }
    Assert-ExpansionStandardSeal $seal.manifest $seal.output $inputs $foundation $files[$foundationPaths.outputs]
    $currentValidationSourceHashes=Get-ExpansionStandardSources
    $privateSources=$currentValidationSourceHashes.Clone()
    foreach ($name in @('Test-ExpansionPrivate.ps1','Invoke-ExpansionWatchdog.ps1')) { $privateSources["scripts/$name"]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash }
    foreach ($selection in $dependencies.Keys) {
        $manifest=$dependencies[$selection]; $output=$outputs[$selection]; $paths=Get-ExpansionStandardPaths $State $selection
        Assert-FoundationEqual $manifest.originalSha $inputs.state
        Assert-FoundationEqual $manifest.foundationOutputHash $seal.manifest.outputHash
        Assert-FoundationEqual $manifest.outputHash $files[$paths.outputs]
        Assert-FoundationEqual $manifest.review.inputHashes $inputs
        Assert-FoundationEqual $manifest.review.approved $true
        Assert-FoundationEqual $manifest.baseline $seal.manifest.baseline
        Assert-FoundationEqual $manifest.review.baselineHash (Get-FoundationHash $manifest.baseline)
        Assert-FoundationEqual $manifest.review.idleHash (Get-FoundationHash $manifest.idle)
        Assert-FoundationEqual $output.originalSha $inputs.state
        Assert-FoundationEqual $output.foundationOutputHash $seal.manifest.outputHash
        Assert-FoundationEqual $output.controlPlaneVerified $true
        Assert-FoundationEqual $output.completeLab $false
        Assert-FoundationEqual $output.validationSourceHashes $currentValidationSourceHashes
        Assert-FoundationEqual $output.standard.stage 'dependencies'
        Assert-FoundationEqual $output.standard.completeLab $false
        Assert-FoundationEqual $output.standard.projectSelector $selection
        Assert-FoundationEqual $output.standard.labId $State.labId
        Assert-FoundationEqual $output.standard.ownershipId $State.ownershipId
        $project=@($seal.output.foundation.projects | Where-Object resourceId -IEQ $output.standard.projectId)
        if ($project.Count -ne 1) { throw 'Dependency project missing from sealed foundation' }
        Assert-FoundationText $output.standard.projectPrincipalId $project[0].principalId
        Assert-FoundationText $manifest.deploymentId "$($foundation.subscription)/providers/Microsoft.Resources/deployments/$($foundation.stem)-exp-standard-$selection"
        $expected=@{}; $expected[$OriginalPath]=$inputs.state
        foreach ($file in @($paths.state,$paths.outputs,$foundationPaths.state,$foundationPaths.outputs)) { $expected[$file]=$files[$file] }
        $private[$selection]=Get-ExpansionNetworkPrivateReceipt $State $selection $expected $privateSources $output
        $network=$private[$selection].receipt.binding
        Assert-FoundationText $network.vnetId $output.standard.vnetId
        Assert-FoundationText $network.subnetId $output.standard.subnetId
        Assert-FoundationText $network.runnerId $lab.runner
        Assert-FoundationEqual $network.addressPrefix $(if ($selection -ceq 'a-test') { '10.76.6.' } else { '10.76.7.' })
        if ($network.targets -isnot [array] -or $network.targets.Count -ne 3) { throw 'Exact private target coverage required' }
        foreach ($spec in @(@('storage','blob','blob.core.windows.net','blob'),@('search','search','search.windows.net','searchService'),@('cosmos','cosmos','documents.azure.com','Sql'))) {
            $target=@($network.targets | Where-Object service -CEQ $spec[0])
            if ($target.Count -ne 1) { throw 'Missing private service target' }
            Assert-FoundationText $target[0].id $output.standard[$spec[0]].id
            Assert-FoundationText $target[0].hostName "$($output.standard[$spec[0]].name).$($spec[2])"
            Assert-FoundationText $target[0].zoneId $output.standard.dnsZoneIds[$spec[1]]
            Assert-FoundationText $target[0].endpointId "$($output.standard.resourceGroupId)/providers/Microsoft.Network/privateEndpoints/pe-$($foundation.stem)-exp-$selection-$($spec[1])"
            Assert-FoundationEqual $target[0].groupId $spec[3]
        }
        Assert-ExpansionPrivateProbe $network $private[$selection].receipt $private[$selection].receipt.ownedAddresses
        $files[$private[$selection].path]=$private[$selection].sha256
    }
    return @{inputs=$inputs;files=$files;dependencies=$dependencies;outputs=$outputs;private=$private;foundation=$foundation;seal=$seal;lab=$lab;currentValidationSourceHashes=$currentValidationSourceHashes}
}

function Assert-ExpansionNetworkInputs([hashtable]$State, [string]$OriginalPath, [hashtable]$Prerequisites, [hashtable]$Sources) {
    Assert-FoundationEqual (Get-FoundationInputHashes $State $OriginalPath) $Prerequisites.inputs
    Assert-FoundationEqual (Get-ExpansionNetworkSources) $Sources
    foreach ($file in $Prerequisites.files.Keys) { Assert-FoundationEqual (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash $Prerequisites.files[$file] }
    $privateSources=$Prerequisites.currentValidationSourceHashes.Clone()
    foreach ($name in @('Test-ExpansionPrivate.ps1','Invoke-ExpansionWatchdog.ps1')) { $privateSources["scripts/$name"]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash }
    foreach ($selection in $Prerequisites.dependencies.Keys) {
        $receipt=$Prerequisites.private[$selection]
        $latest=Get-ExpansionNetworkPrivateReceipt $State $selection $receipt.receipt.inputHashes $privateSources $Prerequisites.outputs[$selection]
        Assert-FoundationEqual $latest $receipt
    }
}

function Assert-ExpansionNetworkReview([hashtable]$Manifest, [hashtable]$Paths, [hashtable]$Prerequisites, [hashtable]$Sources, [switch]$Submitted) {
    $review=$Manifest.review
    Assert-CosmosNetworkKeys $review @('checkedAt','approved','inputHashes','fileHashes','sourceHashes','artifactHashes','bindingHash','knownHash','baselineHash','idleHash')
    Assert-FoundationEqual $review.approved $true
    $age=[DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$review.checkedAt)
    if ($age -lt [TimeSpan]::Zero -or (-not $Submitted -and $age -gt [TimeSpan]::FromHours(1))) { throw 'Network Preview expired or future dated' }
    Assert-FoundationEqual $review.inputHashes $Prerequisites.inputs
    Assert-FoundationEqual $review.fileHashes $Prerequisites.files
    Assert-FoundationEqual $review.sourceHashes $Sources
    foreach ($key in @('binding','known','baseline','idle')) { Assert-FoundationEqual $review["${key}Hash"] (Get-FoundationHash $Manifest[$key]) }
    Assert-FoundationEqual $Manifest.project $Manifest.binding.selector
    Assert-FoundationEqual $Manifest.stage 'cosmos-network'
    Assert-FoundationEqual $Manifest.foundationBinding $Prerequisites.foundation
    foreach ($key in @('source','template','parameters','whatif')) { Assert-FoundationEqual (Get-FileHash -LiteralPath $Paths[$key] -Algorithm SHA256).Hash $review.artifactHashes[$key] }
    Assert-FoundationEqual ([IO.File]::ReadAllText($Paths.source)) (New-ExpansionNetworkBicep $Manifest.binding)
    Assert-ExpansionNetworkCompiled (Read-FoundationJson $Paths.template) $Manifest.binding
    Assert-FoundationEqual (Read-FoundationJson $Paths.parameters) @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=@{}}
    Assert-ExpansionNetworkWhatIf $Manifest.binding $Manifest.known (Read-FoundationJson $Paths.whatif)
}

function Get-ExpansionNetworkDeploymentId([hashtable]$Binding) {
    return "$($Binding.names.scope)/providers/Microsoft.Resources/deployments/fgl-$($Binding.labId)-exp-cosmos-$($Binding.selector)"
}

function Get-ExpansionNetworkIntentHash([hashtable]$Manifest) {
    $intent=$Manifest.Clone()
    $intent.pending=$true; $intent.verified=$false
    $intent.Remove('outputHash')
    return Get-FoundationHash $intent
}

function Assert-ExpansionNetworkReceipt([hashtable]$Manifest, $Output, [string]$OutputHash) {
    Assert-FoundationEqual $Manifest.pending $false
    Assert-FoundationEqual $Manifest.verified $true
    if ($OutputHash -cnotmatch '^[A-F0-9]{64}$') { throw 'Network output SHA256 required' }
    Assert-FoundationEqual $Manifest.outputHash $OutputHash
    Assert-CosmosNetworkKeys $Output @('stage','project','controlPlaneVerified','runtimeVerified','inferenceVerified','completeLab','verifiedAt','deploymentId','ruleId','inputHashes','sourceHashes','intentHash','deploymentProof','azureReadOnly')
    Assert-FoundationEqual $Output.stage 'cosmos-network'
    Assert-FoundationEqual $Output.project $Manifest.project
    foreach ($key in @('controlPlaneVerified','azureReadOnly')) { Assert-FoundationEqual $Output[$key] $true }
    foreach ($key in @('runtimeVerified','inferenceVerified','completeLab')) { Assert-FoundationEqual $Output[$key] $false }
    Assert-FoundationEqual $Output.deploymentId (Get-ExpansionNetworkDeploymentId $Manifest.binding)
    Assert-FoundationEqual $Output.deploymentId $Manifest.deploymentId
    Assert-FoundationEqual $Output.ruleId $Manifest.binding.names.ruleId
    Assert-FoundationEqual $Output.inputHashes $Manifest.review.inputHashes
    Assert-FoundationEqual $Output.sourceHashes $Manifest.review.sourceHashes
    Assert-FoundationEqual $Output.intentHash (Get-ExpansionNetworkIntentHash $Manifest)
    Assert-CosmosNetworkKeys $Output.deploymentProof @('deploymentHash','operationsHash')
    foreach ($key in @('deploymentHash','operationsHash')) { if ($Output.deploymentProof[$key] -isnot [string] -or $Output.deploymentProof[$key] -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Network deployment proof required' } }
    $verified=[DateTimeOffset]::Parse([string]$Output.verifiedAt)
    if ($verified -gt [DateTimeOffset]::UtcNow -or $verified -lt [DateTimeOffset]::Parse([string]$Manifest.submittedAt)) { throw 'Invalid network verification timestamp' }
}

function Assert-ExpansionNetworkDeployment([hashtable]$Manifest, $Deployment, $Operations) {
    $binding=$Manifest.binding; $root=Get-ExpansionNetworkDeploymentId $binding
    Assert-FoundationText $Manifest.deploymentId $root
    Assert-FoundationText $Deployment.id $root
    Assert-FoundationEqual $Deployment.name (($root -split '/')[-1])
    Assert-FoundationEqual $Deployment.properties.mode 'Incremental'
    Assert-FoundationText $Deployment.properties.provisioningState 'Succeeded'
    if ($Deployment.properties.parameters -and $Deployment.properties.parameters.Count) { throw 'Unexpected root parameters' }
    if ($Deployment.properties.outputs -and $Deployment.properties.outputs.Count) { throw 'Unexpected root outputs' }
    if ($Deployment.properties.outputResources -isnot [array] -or $Deployment.properties.outputResources.Count -ne 1) { throw 'Exactly one root output resource required' }
    Assert-FoundationText $Deployment.properties.outputResources[0].id $binding.names.ruleId
    if ($Operations -isnot [array] -or -not $Operations.Count) { throw 'Complete root operations required' }
    $writes=0; $seen=@{}
    foreach ($operation in $Operations) {
        if ($operation.id -isnot [string] -or -not $operation.id.StartsWith("$root/operations/",[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($operation.id)) { throw 'Unbound or duplicate operation' }
        $seen[$operation.id]=$true; $properties=$operation.properties
        Assert-FoundationText $properties.provisioningState 'Succeeded'
        if ($properties.provisioningOperation -ceq 'EvaluateDeploymentOutput' -and -not $properties.targetResource) { continue }
        Assert-FoundationEqual $properties.provisioningOperation 'Create'
        Assert-FoundationText $properties.targetResource.id $binding.names.ruleId
        Assert-FoundationText $properties.targetResource.resourceType 'Microsoft.Network/networkSecurityGroups/securityRules'
        $writes++
    }
    if ($writes -ne 1) { throw 'Exactly one successful child write required' }
}

function Get-ExpansionNetworkIdle([hashtable]$State, [hashtable]$Prerequisites, [hashtable]$All, [string]$Selector, [switch]$Submitted, [hashtable]$Receipts = @{}) {
    $foundation=$Prerequisites.foundation
    $scopes=@($foundation.subscription)+@($State.resourceGroups | ForEach-Object { "$($foundation.subscription)/resourceGroups/$_" })+@($foundation.groupB)
    $inventory=@{}; $known=@{}; $events=@{}
    foreach ($manifest in $Prerequisites.dependencies.Values) {
        foreach ($id in $manifest.idle.deployments.Keys) {
            if ($known.ContainsKey($id)) { Assert-FoundationEqual $known[$id] $manifest.idle.deployments[$id] }
            $known[$id]=$manifest.idle.deployments[$id]
        }
    }
    foreach ($output in @($Prerequisites.seal.output)+@($Prerequisites.outputs.Values)) {
        foreach ($event in $output.environmentEvents) {
            Assert-FoundationEqual $event.targetAbsent $true
            if ($events.ContainsKey($event.deploymentId)) { Assert-FoundationEqual $events[$event.deploymentId] $event }
            $events[$event.deploymentId]=$event
        }
    }
    foreach ($scope in $scopes) {
        foreach ($deployment in @(Read-ExpansionNetworkArm $State "$scope/providers/Microsoft.Resources/deployments" '2022-09-01' -List)) {
            if ($deployment.name -isnot [string] -or $deployment.name -notmatch '^[A-Za-z0-9_.()-]+$' -or $inventory.ContainsKey($deployment.id)) { throw 'Malformed deployment inventory' }
            Assert-FoundationText $deployment.id "$scope/providers/Microsoft.Resources/deployments/$($deployment.name)"
            if ($deployment.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Scoped deployment inventory contains active work' }
            $inventory[$deployment.id]=$deployment
        }
    }
    $selectedNames=Get-ExpansionCosmosNetworkNames $State $Selector $foundation.integration
    $selectedRoot="$($selectedNames.scope)/providers/Microsoft.Resources/deployments/fgl-$($State.labId)-exp-cosmos-$Selector"
    if (-not $Submitted -and $inventory.ContainsKey($selectedRoot)) { throw 'Existing network root cannot be adopted' }
    $expectedRoots=@(Get-FoundationRootIds $State)+@($foundation.root)+@($Prerequisites.dependencies.Values | ForEach-Object { $_.deploymentId })
    $queue=[Collections.Generic.Queue[string]]::new()
    foreach ($root in $expectedRoots) { $queue.Enqueue($root) }
    $graph=@{}; $operations=@{}
    while ($queue.Count) {
        $root=$queue.Dequeue()
        if ($graph.ContainsKey($root)) { continue }
        if ($graph.Count -ge 300 -or -not $inventory.ContainsKey($root)) { throw 'Expected deployment graph missing or too large' }
        $deployment=$inventory[$root]
        if ($known.ContainsKey($root)) {
            Assert-FoundationEqual @{state=$deployment.properties.provisioningState;mode=$deployment.properties.mode} $known[$root]
        } else { Assert-FoundationEqual $deployment.properties.provisioningState 'Succeeded'; Assert-FoundationEqual $deployment.properties.mode 'Incremental' }
        if ($root -iin @($foundation.root)+@($Prerequisites.dependencies.Values | ForEach-Object { $_.deploymentId })) { Assert-FoundationEqual $deployment.properties.provisioningState 'Succeeded' }
        $children=@(Read-ExpansionNetworkArm $State "$root/operations" '2022-09-01' -List)
        foreach ($operation in $children) {
            if ($operation.properties.provisioningState -cnotin @('Succeeded','Failed','Canceled')) { throw 'Dependency graph has an active operation' }
            $target=$operation.properties.targetResource
            if ($target.resourceType -ieq 'Microsoft.Resources/deployments') {
                if ($target.id -isnot [string] -or @($scopes | Where-Object { $target.id.StartsWith("$_/providers/Microsoft.Resources/deployments/",[StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { throw 'Deployment graph escaped scopes' }
                $queue.Enqueue($target.id)
            }
        }
        $operations[$root]=$children
        $graph[$root]=@{deploymentHash=(Get-FoundationHash $deployment);operationsHash=(Get-FoundationHash $children)}
    }
    foreach ($selection in $All.Keys) {
        $manifest=$All[$selection]
        if (-not $manifest.pending -and -not $manifest.verified) { continue }
        if ($selection -ceq $Selector -and -not $Submitted) { throw 'Selected intent already exists' }
        $root=Get-ExpansionNetworkDeploymentId $manifest.binding
        if (-not $inventory.ContainsKey($root)) { throw 'Persisted network intent missing from inventory; do not resubmit' }
        $children=@(Read-ExpansionNetworkArm $State "$root/operations" '2022-09-01' -List)
        Assert-ExpansionNetworkDeployment $manifest $inventory[$root] $children
        $graph[$root]=@{deploymentHash=(Get-FoundationHash $inventory[$root]);operationsHash=(Get-FoundationHash $children)}
        if ($manifest.verified) { Assert-FoundationEqual $graph[$root] $Receipts[$selection].deploymentProof }
    }
    foreach ($root in $inventory.Keys) {
        if ($graph.ContainsKey($root)) { continue }
        if ($events.ContainsKey($root)) {
            $event=$events[$root]
            Assert-FoundationEqual (Get-FoundationHash $inventory[$root]) $event.deploymentHash
            $children=@(Read-ExpansionNetworkArm $State "$root/operations" '2022-09-01' -List)
            Assert-FoundationEqual (Get-FoundationHash $children) $event.operationsHash
            $targetScope=($event.targetId -split '/providers/')[0]
            if ($targetScope -cnotin $scopes) { throw 'Sealed environment target escaped scopes' }
            $targets=@(Read-ExpansionNetworkArm $State "$targetScope/resources" '2021-04-01' -List)
            if ($event.targetId -match '/providers/Microsoft.Insights/diagnosticSettings/') {
                $parent=$event.targetId.Substring(0,$event.targetId.LastIndexOf('/providers/Microsoft.Insights/diagnosticSettings/',[StringComparison]::OrdinalIgnoreCase))
                $targets+=@(Read-ExpansionNetworkArm $State "$parent/providers/Microsoft.Insights/diagnosticSettings" '2021-05-01-preview' -List)
            }
            if (@($targets | Where-Object id -IEQ $event.targetId).Count) { throw 'Previously failed environment deployment now has effects' }
            $graph[$root]=@{deploymentHash=$event.deploymentHash;operationsHash=$event.operationsHash}
        } elseif ($root.StartsWith("$($foundation.subscription)/providers/Microsoft.Resources/deployments/",[StringComparison]::OrdinalIgnoreCase) -and -not $inventory[$root].name.StartsWith($foundation.stem,[StringComparison]::OrdinalIgnoreCase)) {
            $graph[$root]=@{deploymentHash=(Get-FoundationHash $inventory[$root]);unrelatedTerminal=$true}
        } else { throw 'Unknown deployment is not covered by sealed evidence' }
    }
    foreach ($root in $known.Keys) { if (-not $graph.ContainsKey($root)) { throw 'Sealed dependency deployment missing' } }
    return $graph
}

function Get-ExpansionNetworkResources([hashtable]$State, [string]$Selector, [hashtable]$Output) {
    $scope="/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-integration"
    $names=Get-ExpansionCosmosNetworkNames $State $Selector $scope
    $caseId=$Selector.Substring(0,1); $index=if ($caseId -ceq 'a') { 0 } else { 1 }
    $vnet="$scope/providers/Microsoft.Network/virtualNetworks/vnet-fgl-$($State.labId)"
    $group="/subscriptions/$($State.subscriptionId)/resourceGroups/rg-fgl-$($State.labId)-case-$caseId"
    if ($Output.standard.cosmos.id -isnot [string] -or -not $Output.standard.cosmos.id.StartsWith("$group/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-fgl-$($State.labId)-exp-",[StringComparison]::OrdinalIgnoreCase)) { throw 'Foreign Cosmos target' }
    $resources=@{}
    foreach ($spec in @(@('nsg',$names.nsgId),@('agentNsg',"$scope/providers/Microsoft.Network/networkSecurityGroups/nsg-fgl-$($State.labId)-agent-$index"),@('vnet',$vnet),@('subnet',"$vnet/subnets/snet-case-$caseId-pe"),@('agentSubnet',"$vnet/subnets/snet-agent-$caseId"),@('cosmos',$Output.standard.cosmos.id),@('endpoint',"$group/providers/Microsoft.Network/privateEndpoints/pe-fgl-$($State.labId)-exp-$Selector-cosmos"))) {
        $api=if ($spec[0] -ceq 'cosmos') { '2024-11-15' } else { '2024-05-01' }
        $resources[$spec[0]]=Read-ExpansionNetworkArm $State $spec[1] $api
    }
    $nics=$resources.endpoint.properties.networkInterfaces
    if ($nics -isnot [array] -or $nics.Count -ne 1 -or $nics[0].id -isnot [string] -or $nics[0].id -inotmatch ('^'+[regex]::Escape("$group/providers/Microsoft.Network/networkInterfaces/")+'[a-zA-Z0-9_.-]+$')) { throw 'Exact private endpoint NIC required' }
    $resources.nic=Read-ExpansionNetworkArm $State $nics[0].id '2024-05-01'
    $project=Read-ExpansionNetworkArm $State $Output.standard.projectId '2026-05-01'
    Assert-FoundationOwned $State $project $Output.standard.projectId
    Assert-FoundationText $project.identity.principalId $Output.standard.projectPrincipalId
    Assert-FoundationText $project.identity.tenantId $State.tenantId
    Assert-FoundationText $project.properties.provisioningState 'Succeeded'
    return $resources
}

function Get-ExpansionNetworkLive([hashtable]$State, [hashtable]$Prerequisites, [hashtable]$All, [string]$Selector, [switch]$Submitted) {
    Assert-LabContext $State (Invoke-ExpansionNetworkAz $State @('account','show'))
    $resources=Get-ExpansionNetworkResources $State $Selector $Prerequisites.outputs[$Selector]
    $before=Read-ExpansionStandardCopy $resources
    $accepted=@{}; $laterRules=@{}
    foreach ($selection in $All.Keys) {
        $manifest=$All[$selection]
        if (-not $manifest.pending -and -not $manifest.verified) { continue }
        $binding=$manifest.binding
        if ($selection -ceq $Selector -and -not $Submitted) { throw 'Submitted intent cannot be adopted' }
        $rule=@($resources.nsg.properties.securityRules | Where-Object id -IEQ $binding.names.ruleId)
        if ($rule.Count -ne 1) { throw 'Reviewed earlier addition is missing' }
        Assert-ExpansionCosmosNetworkRule $rule[0] $binding -Succeeded
        $accepted[$binding.names.ruleId]=$true
        if ($Submitted -and $selection -cne $Selector -and $binding.names.ruleId -inotin @($All[$Selector].binding.otherRules.id)) {
            if (-not $manifest.verified -or $All[$Selector].idle.ContainsKey((Get-ExpansionNetworkDeploymentId $binding)) -or [DateTimeOffset]::Parse([string]$manifest.review.checkedAt) -lt [DateTimeOffset]::Parse([string]$All[$Selector].submittedAt)) { throw 'Only later verified additions may be reconciled' }
            $laterRules[$binding.names.ruleId]=$true
        }
    }
    if ($Submitted) {
        $before.nsg.properties.securityRules=@($before.nsg.properties.securityRules | Where-Object { -not $laterRules.ContainsKey($_.id) })
        Assert-ExpansionCosmosNetworkPreserved $All[$Selector].binding $before.nsg $before.agentNsg
        $before.nsg.properties.securityRules=@($before.nsg.properties.securityRules | Where-Object id -INE $All[$Selector].binding.names.ruleId)
    }
    $binding=Get-ExpansionCosmosNetworkBinding $State $Selector $Prerequisites.outputs[$Selector] $before $Prerequisites.foundation.integration
    $private=$Prerequisites.private[$Selector].receipt
    $hostName=$Prerequisites.outputs[$Selector].standard.cosmos.name+'.documents.azure.com'
    Assert-FoundationSet $private.ownedAddresses[$hostName] @($binding.fqdnAddresses[$hostName])
    $binding.projectId=$Prerequisites.outputs[$Selector].standard.projectId
    $binding.projectPrincipalId=$Prerequisites.outputs[$Selector].standard.projectPrincipalId
    $baseline=Get-FoundationLive $State $Prerequisites.lab (Read-FoundationJson (Join-Path $State.runDirectory 'standard-outputs.json')) (Read-FoundationJson (Join-Path $State.runDirectory 'activate.parameters.json')) $Prerequisites.foundation -After
    $normalized=Read-ExpansionStandardCopy $baseline
    $nsgId=$binding.names.nsgId
    if (-not $normalized.ContainsKey($nsgId)) { throw 'Original NSG preservation baseline missing' }
    $normalized[$nsgId].properties.securityRules=@($normalized[$nsgId].properties.securityRules | Where-Object { -not $accepted.ContainsKey($_.id) })
    Assert-FoundationEqual $normalized $Prerequisites.seal.manifest.baseline
    if ($Submitted) { $baseline[$nsgId].properties.securityRules=@($baseline[$nsgId].properties.securityRules | Where-Object { $_.id -ine $binding.names.ruleId -and -not $laterRules.ContainsKey($_.id) }) }
    $known=@{}
    $reviewed=$Prerequisites.dependencies[$Selector].known
    if ($reviewed -isnot [hashtable]) { throw 'Sealed dependency resource inventory required' }
    foreach ($resource in @(Read-ExpansionNetworkArm $State "$($binding.names.scope)/resources" '2021-04-01' -List)) {
        if ($resource.id -isnot [string] -or -not $resource.id.StartsWith("$($binding.names.scope)/providers/",[StringComparison]::OrdinalIgnoreCase)) { throw 'Unreviewed integration inventory resource' }
        $reviewedIds=@($reviewed.Keys | Where-Object { [string]::Equals($_,$resource.id,[StringComparison]::OrdinalIgnoreCase) })
        if ($reviewedIds.Count -ne 1) { throw 'Missing or ambiguous reviewed integration resource' }
        $record=$reviewed[$reviewedIds[0]]
        if ($record -isnot [hashtable] -or $record.type -isnot [string] -or [string]::IsNullOrWhiteSpace($record.type)) { throw 'Sealed inventory type required' }
        Assert-FoundationText $record.id $resource.id
        Assert-FoundationText $resource.type $record.type
        Assert-FoundationEqual $resource.tags $record.tags
        if ($record.tags -is [hashtable] -and $record.tags.Count) { Assert-FoundationOwned $State $resource $record.id }
        $known[$resource.id]=$resource
    }
    foreach ($resource in $before.Values) { $known[$resource.id]=$resource }
    return @{binding=$binding;baseline=$baseline;known=$known}
}

function Invoke-ExpansionCosmosNetwork([string]$Path, [string]$Selector, [string]$SelectedAction, [string]$Compiler, [bool]$Approved) {
    $ErrorActionPreference='Stop'
    if (-not $Path -or $Selector -cnotin @('a-test','b-dev','b-test') -or $SelectedAction -cnotin @('Preview','Deploy','Status')) { throw 'Original StatePath, exact Project and Action required' }
    $originalPath=Assert-ExternalLabPath $Path
    $originalHash=(Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
    $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
    $paths=Get-ExpansionNetworkPaths $state $Selector
    $lock=$null
    try {
        $lock=[IO.File]::Open($paths.lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $state=Read-LabRun $originalPath; Assert-FoundationOriginal $state
        $state.evidenceDirectory=$paths.evidence
        $null=[IO.Directory]::CreateDirectory($state.evidenceDirectory)
        $all=@{}; $manifestHashes=@{}; $outputHashes=@{}; $receipts=@{}; $dependencies=@{}
        foreach ($selection in @('a-test','b-dev','b-test')) {
            $other=Get-ExpansionNetworkPaths $state $selection
            if (Test-Path -LiteralPath $other.state) {
                $all[$selection]=Read-FoundationJson $other.state
                $manifestHashes[$other.state]=(Get-FileHash -LiteralPath $other.state -Algorithm SHA256).Hash
            }
            if (Test-Path -LiteralPath $other.outputs) {
                if (-not $all.ContainsKey($selection)) { throw 'Network output requires persisted intent' }
                if (-not $all[$selection].verified -and ($SelectedAction -cne 'Status' -or $selection -cne $Selector -or $all[$selection].pending -isnot [bool] -or -not $all[$selection].pending -or $all[$selection].verified -isnot [bool] -or $all[$selection].ContainsKey('outputHash'))) { throw 'Only selected pending Status may reconcile an unsealed output' }
                $outputHashes[$other.outputs]=(Get-FileHash -LiteralPath $other.outputs -Algorithm SHA256).Hash
                $receipts[$selection]=Read-FoundationJson $other.outputs
            }
            if ($all.ContainsKey($selection) -and $all[$selection].verified) { Assert-ExpansionNetworkReceipt $all[$selection] $receipts[$selection] $outputHashes[$other.outputs] }
            $dependencyPaths=Get-ExpansionStandardPaths $state $selection
            $dependencies[$selection]=Read-FoundationJson $dependencyPaths.state
        }
        $manifest=$all[$Selector]
        Assert-ExpansionNetworkTransition $manifest $all $dependencies $Selector $SelectedAction $Approved
        $foundationBinding=$null
        if ($manifest) { $foundationBinding=$manifest.foundationBinding }
        if ($SelectedAction -ceq 'Status' -and -not $foundationBinding) { throw 'Submitted foundation binding required; Status never compiles' }
        $prerequisites=Get-ExpansionNetworkPrerequisites $state $originalPath $Compiler $foundationBinding
        Assert-FoundationEqual $prerequisites.inputs.state $originalHash
        $sources=Get-ExpansionNetworkSources
        function Invoke-FoundationAz([hashtable]$State, [string[]]$Arguments, [string]$Label) { return Invoke-ExpansionNetworkAz $State $Arguments }
        function Assert-NetworkUnchanged {
            Assert-ExpansionNetworkInputs $state $originalPath $prerequisites $sources
            foreach ($selection in @('a-test','b-dev','b-test')) {
                $other=Get-ExpansionNetworkPaths $state $selection
                if ($manifestHashes.ContainsKey($other.state)) { Assert-FoundationEqual (Get-FileHash -LiteralPath $other.state -Algorithm SHA256).Hash $manifestHashes[$other.state] }
                elseif (Test-Path -LiteralPath $other.state) { throw 'Network manifest appeared during collection' }
                if ($outputHashes.ContainsKey($other.outputs)) { Assert-FoundationEqual (Get-FileHash -LiteralPath $other.outputs -Algorithm SHA256).Hash $outputHashes[$other.outputs] }
                elseif (Test-Path -LiteralPath $other.outputs) { throw 'Network output appeared during collection' }
            }
        }
        foreach ($selection in $all.Keys) {
            if ($all[$selection].pending -or $all[$selection].verified) {
                Assert-ExpansionNetworkReview $all[$selection] (Get-ExpansionNetworkPaths $state $selection) $prerequisites $sources -Submitted
                $submitted=[DateTimeOffset]::Parse([string]$all[$selection].submittedAt)
                if ($submitted -gt [DateTimeOffset]::UtcNow -or $submitted -lt [DateTimeOffset]::Parse([string]$all[$selection].review.checkedAt)) { throw 'Invalid submission timestamp' }
            }
        }
        $startedAt=[DateTimeOffset]::UtcNow.ToString('o')
        Assert-LabContext $state (Invoke-ExpansionNetworkAz $state @('account','show'))
        if ($SelectedAction -ceq 'Status') {
            Assert-ExpansionNetworkReview $manifest $paths $prerequisites $sources -Submitted
            $idle=Get-ExpansionNetworkIdle $state $prerequisites $all $Selector -Submitted -Receipts $receipts
            $live=Get-ExpansionNetworkLive $state $prerequisites $all $Selector -Submitted
            Assert-FoundationEqual $live.binding $manifest.binding
            Assert-FoundationEqual $live.baseline $manifest.baseline
            $withoutRoot=Read-ExpansionStandardCopy $idle
            $withoutRoot.Remove((Get-ExpansionNetworkDeploymentId $manifest.binding))
            foreach ($selection in $all.Keys) {
                if ($selection -cne $Selector -and $all[$selection].verified) {
                    $otherRoot=Get-ExpansionNetworkDeploymentId $all[$selection].binding
                    if (-not $manifest.idle.ContainsKey($otherRoot)) { $withoutRoot.Remove($otherRoot) }
                }
            }
            Assert-FoundationEqual $withoutRoot $manifest.idle
            $again=Get-ExpansionNetworkLive $state $prerequisites $all $Selector -Submitted
            Assert-FoundationEqual $again $live
            Assert-FoundationEqual (Get-ExpansionNetworkIdle $state $prerequisites $all $Selector -Submitted -Receipts $receipts) $idle
            Assert-NetworkUnchanged
            Assert-ExpansionNetworkReview $manifest $paths $prerequisites $sources -Submitted
            $root=Get-ExpansionNetworkDeploymentId $manifest.binding
            if ($manifest.verified) {
                Assert-FoundationEqual $receipts[$Selector].deploymentProof $idle[$root]
                return $receipts[$Selector]
            }
            if ($outputHashes.ContainsKey($paths.outputs)) {
                $output=$receipts[$Selector]
                Assert-FoundationEqual $output.intentHash (Get-FoundationHash $manifest)
                $completed=$manifest.Clone()
                $completed.outputHash=$outputHashes[$paths.outputs]; $completed.pending=$false; $completed.verified=$true
                Assert-ExpansionNetworkReceipt $completed $output $completed.outputHash
                Assert-FoundationEqual $output.deploymentProof $idle[$root]
                Assert-NetworkUnchanged
                Write-StandardJson $paths.state $completed
                return $output
            }
            $output=@{stage='cosmos-network';project=$Selector;controlPlaneVerified=$true;runtimeVerified=$false;inferenceVerified=$false;completeLab=$false;verifiedAt=[DateTimeOffset]::UtcNow.ToString('o');deploymentId=$manifest.deploymentId;ruleId=$manifest.binding.names.ruleId;inputHashes=$prerequisites.inputs;sourceHashes=$sources;intentHash=(Get-ExpansionNetworkIntentHash $manifest);deploymentProof=$idle[$root];azureReadOnly=$true}
            $temporary=Assert-ExternalLabPath "$($paths.outputs).$([guid]::NewGuid().ToString('N')).tmp"
            try {
                Write-StandardJson $temporary $output
                $manifest.outputHash=(Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash; $manifest.pending=$false; $manifest.verified=$true
                Assert-ExpansionNetworkReceipt $manifest $output $manifest.outputHash
                Assert-NetworkUnchanged
                [IO.File]::Move($temporary,$paths.outputs)
                Write-StandardJson $paths.state $manifest
            } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
            return $output
        }
        if ($SelectedAction -ceq 'Deploy') { Assert-ExpansionNetworkReview $manifest $paths $prerequisites $sources }
        $idle=Get-ExpansionNetworkIdle $state $prerequisites $all $Selector -Receipts $receipts
        $live=Get-ExpansionNetworkLive $state $prerequisites $all $Selector
        if ($SelectedAction -ceq 'Deploy') {
            foreach ($key in @('binding','baseline','known')) { Assert-FoundationEqual $live[$key] $manifest[$key] }
            Assert-FoundationEqual $idle $manifest.idle
        } else {
            [IO.File]::WriteAllText($paths.source,(New-ExpansionNetworkBicep $live.binding),[Text.UTF8Encoding]::new($false))
            $null=Invoke-ExpansionNetworkProcess $state $Compiler @('build',$paths.source,'--no-restore','--outfile',$paths.template)
            Assert-ExpansionNetworkCompiled (Read-FoundationJson $paths.template) $live.binding
            Write-StandardJson $paths.parameters @{'$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=@{}}
        }
        $artifactHashes=@{}
        foreach ($key in @('source','template','parameters')) { $artifactHashes[$key]=(Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash }
        $root=Get-ExpansionNetworkDeploymentId $live.binding
        $common=@('--resource-group',$live.binding.names.group,'--name',(($root -split '/')[-1]),'--mode','Incremental','--template-file',$paths.template,'--parameters',"@$($paths.parameters)")
        $validation=Invoke-ExpansionNetworkAz $state (@('deployment','group','validate')+$common)
        if ($validation.error -or $validation.properties.provisioningState -cne 'Succeeded') { throw 'ARM validation failed' }
        $whatif=Invoke-ExpansionNetworkAz $state (@('deployment','group','what-if','--no-pretty-print','--result-format','FullResourcePayloads')+$common)
        Assert-ExpansionNetworkWhatIf $live.binding $live.known $whatif
        Assert-FoundationEqual (Get-ExpansionNetworkLive $state $prerequisites $all $Selector) $live
        Assert-FoundationEqual (Get-ExpansionNetworkIdle $state $prerequisites $all $Selector -Receipts $receipts) $idle
        Assert-NetworkUnchanged
        foreach ($key in $artifactHashes.Keys) { Assert-FoundationEqual (Get-FileHash -LiteralPath $paths[$key] -Algorithm SHA256).Hash $artifactHashes[$key] }
        if ($SelectedAction -ceq 'Preview') {
            Write-StandardJson $paths.whatif $whatif
            $artifactHashes.whatif=(Get-FileHash -LiteralPath $paths.whatif -Algorithm SHA256).Hash
            $manifest=@{version=1;stage='cosmos-network';project=$Selector;pending=$false;verified=$false;foundationBinding=$prerequisites.foundation;binding=$live.binding;known=$live.known;baseline=$live.baseline;idle=$idle;review=@{approved=$true;checkedAt=$startedAt;inputHashes=$prerequisites.inputs;fileHashes=$prerequisites.files;sourceHashes=$sources;artifactHashes=$artifactHashes;bindingHash=(Get-FoundationHash $live.binding);knownHash=(Get-FoundationHash $live.known);baselineHash=(Get-FoundationHash $live.baseline);idleHash=(Get-FoundationHash $idle)}}
            Assert-ExpansionNetworkReview $manifest $paths $prerequisites $sources
            Write-StandardJson $paths.state $manifest
            return @{stage='cosmos-network';project=$Selector;action='Preview';reviewPath=$paths.state;expiresAt=[DateTimeOffset]::Parse($startedAt).AddHours(1).ToString('o');ruleId=$live.binding.names.ruleId}
        }
        Assert-ExpansionNetworkReview $manifest $paths $prerequisites $sources
        Write-StandardJson $paths.'deploy-whatif' $whatif
        $manifest.pending=$true; $manifest.submittedAt=[DateTimeOffset]::UtcNow.ToString('o'); $manifest.deploymentId=$root
        Write-StandardJson $paths.state $manifest
        $null=Invoke-ExpansionNetworkAz $state (@('deployment','group','create')+$common+@('--no-wait')) -Empty
        return @{stage='cosmos-network';project=$Selector;action='Deploy';pending=$true;deploymentId=$root;intentPath=$paths.state}
    } finally {
        if ($lock) { $lock.Dispose() }
        Assert-FoundationEqual (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash $originalHash
    }
}

if ($networkDefinitions) { return }
Invoke-ExpansionCosmosNetwork @networkInvocation