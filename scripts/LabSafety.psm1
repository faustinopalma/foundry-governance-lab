Set-StrictMode -Version Latest

function Assert-LabState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    foreach ($field in @('subscriptionId', 'tenantId', 'ownershipId')) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse([string]$State[$field], [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw "Invalid state field: $field"
        }
    }
    if ($State.labId -cnotmatch '^[a-z0-9]{6,12}$') { throw 'Invalid lab identifier' }
    if ($State.ContainsKey('lifecycleMode') -and ($State.lifecycleMode -isnot [string] -or $State.lifecycleMode -cne 'independent')) { throw 'Unknown lifecycle mode' }
    if ($State.ContainsKey('minimalPrompt') -and $State.minimalPrompt -isnot [bool]) { throw 'minimalPrompt must be a boolean' }
    $suffixes = if ($State['minimalPrompt'] -eq $true) { @('models', 'integration', 'case-a') } else { @('models', 'integration', 'case-a', 'case-b') }
    $expected = @($suffixes | ForEach-Object { "rg-fgl-$($State.labId)-$_" })
    $actual = @($State.resourceGroups)
    if ($actual.Count -ne $expected.Count -or @(Compare-Object $expected $actual).Count -ne 0) {
        throw 'State must contain exactly the derived resource groups for its profile'
    }
}

function Assert-LabParameters {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Parameters)

    Assert-LabState $State
    if ($Parameters.labId.value -ne $State.labId -or $Parameters.ownershipId.value -ne $State.ownershipId) { throw 'Parameter ownership mismatch' }
    $minimalPrompt = $false
    if ($Parameters.ContainsKey('minimalPrompt')) {
        $minimalPrompt = $Parameters.minimalPrompt.value
        if ($minimalPrompt -isnot [bool]) { throw 'minimalPrompt parameter must be a boolean' }
    }
    if ($minimalPrompt -ne ($State['minimalPrompt'] -eq $true)) { throw 'Parameter profile mismatch' }
    if ($minimalPrompt -and $Parameters.ContainsKey('enableExperimentalAgents') -and $Parameters.enableExperimentalAgents.value -ne $false) { throw 'Minimal prompt profile cannot enable hosted capability hosts' }
}

function Assert-LabContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Context)

    Assert-LabState $State
    if ($Context.id -ne $State.subscriptionId -or $Context.tenantId -ne $State.tenantId -or $Context.state -ne 'Enabled') {
        throw 'Azure context does not match the explicit lab state'
    }
}

function Assert-LabResourceId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$ResourceId)

    Assert-LabState $State
    foreach ($group in $State.resourceGroups) {
        $prefix = "/subscriptions/$($State.subscriptionId)/resourceGroups/$group"
        if ($ResourceId -ieq $prefix) { return }
        if ($ResourceId.StartsWith("$prefix/providers/", [StringComparison]::OrdinalIgnoreCase) -and
            $ResourceId -notmatch '(%|\\|\?|#|/\.{1,2}(/|$)|//)') {
            $segments = $ResourceId.Substring($prefix.Length) -split '(?i)/providers/'
            $valid = $segments[0] -eq ''
            foreach ($segment in $segments[1..($segments.Count - 1)]) {
                $parts = $segment.Split('/')
                if ($parts.Count -lt 3 -or $parts.Count % 2 -ne 1 -or '' -in $parts) { $valid = $false }
            }
            if ($valid) { return }
        }
    }
    throw 'Resource is outside the exact lab resource groups or has an invalid ID'
}

function Assert-LabGroupOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Group)

    Assert-LabState $State
    Assert-LabResourceId -State $State -ResourceId $Group.id
    if ($Group.name -notin $State.resourceGroups -or
        $Group.id -ine "/subscriptions/$($State.subscriptionId)/resourceGroups/$($Group.name)" -or
        $Group.tags['fgl-owner'] -ne $State.ownershipId -or
        $Group.tags['fgl-lab'] -ne $State.labId) {
        throw 'Existing resource group has no matching lab ownership record'
    }
}

function Assert-LabWhatIf {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Result)

    Assert-LabState $State
    if ($Result.status -ne 'Succeeded' -or @($Result.changes).Count -eq 0) {
        throw 'What-if must succeed and contain expanded resource changes'
    }
    foreach ($change in $Result.changes) {
        Assert-LabResourceId -State $State -ResourceId $change.resourceId
        if ($change.changeType -eq 'Ignore' -and $change.ContainsKey('before')) {
            $before = $change.before
            $managedBy = [string]$before['managedBy']
            $defenderExtension = $before.type -ieq 'Microsoft.Compute/virtualMachines/extensions' -and $change.resourceId -imatch '/providers/Microsoft.Compute/virtualMachines/[^/]+/extensions/MDE.Linux$'
            if ($defenderExtension) { $managedBy = $change.resourceId.Substring(0, $change.resourceId.LastIndexOf('/extensions/', [StringComparison]::OrdinalIgnoreCase)) }
            if ($managedBy) {
                Assert-LabResourceId $State $managedBy
                $parents = @($Result.changes | Where-Object { $_.resourceId -ieq $managedBy -and $_.changeType -in @('Modify','NoChange') })
                $validPair = ($before.type -ieq 'Microsoft.Network/networkInterfaces' -and $managedBy -match '/providers/Microsoft.Network/privateEndpoints/[^/]+$') -or
                    ($before.type -ieq 'Microsoft.Compute/disks' -and $managedBy -match '/providers/Microsoft.Compute/virtualMachines/[^/]+$') -or $defenderExtension
                if ($validPair -and $parents.Count -eq 1 -and $parents[0].before.tags['fgl-owner'] -eq $State.ownershipId -and $parents[0].before.tags['fgl-lab'] -eq $State.labId) { continue }
            }
        }
        if ($change.changeType -notin @('Create', 'Modify', 'NoChange')) {
            throw 'What-if contains deletion, unexpanded deployment, ignored scope, or unsupported change'
        }
    }
}

function Assert-LabTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Target)

    Assert-LabState $State
    if ($State.deploymentAuthorized -ne $true) { throw 'Execution authorization is missing' }
    $allowed = @{
        'not-deployed' = @('bootstrap', 'destroy')
        'bootstrap' = @('bootstrap', 'lock', 'destroy')
        'lock' = @('lock', 'activate', 'destroy')
        'activate' = @('activate', 'destroy')
        'destroy' = @('destroy')
        'destroyed' = @()
    }
    if (-not $allowed.ContainsKey([string]$State.phase) -or $Target -notin $allowed[$State.phase]) { throw 'Forbidden lifecycle transition' }
    if ($State.ContainsKey('pendingPhase') -and $State.pendingPhase -and $Target -notin @($State.pendingPhase, 'destroy')) { throw 'Unfinished phase must be reconciled before advancing' }
    if ($Target -eq 'activate' -and $State.phase -eq 'lock' -and $State['lifecycleMode'] -cne 'independent' -and $State.privateAccessVerified -ne $true) { throw 'Private access has not been verified' }
    if ($Target -eq 'destroy' -and $State.destroyAuthorized -ne $true) { throw 'Teardown authorization is missing' }
}

Export-ModuleMember -Function Assert-LabState, Assert-LabParameters, Assert-LabContext, Assert-LabResourceId, Assert-LabGroupOwnership, Assert-LabWhatIf, Assert-LabTransition