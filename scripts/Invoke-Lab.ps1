[CmdletBinding()]
param(
    [ValidateSet('Create','Status','Test','Teardown')][string]$Action = 'Status',
    [string]$StatePath,
    [string]$AzureConfigDirectory,
    [ValidatePattern('^[a-z0-9]{6,12}$')][string]$LabId,
    [string]$BicepExecutable = 'bicep',
    [switch]$ApproveDeployment,
    [ValidateSet('PrivateNetwork','ControlPlane','Gateway','Identity','Agent','Registry','PublicAccess','AfterTeardown','RetainedRecords')][string[]]$TestGroup,
    [switch]$ApproveTests,
    [ValidateSet('Evidence','Advance','Status')][string]$TeardownStep = 'Evidence',
    [switch]$ApproveTeardown,
    [string]$ConfirmLabId,
    [switch]$DefinitionsOnly
)

function Get-LabNextCreationPhase([hashtable]$State) {
    if ($State.pendingPhase) { throw 'Reconcile the pending deployment before selecting another phase' }
    switch ($State.phase) {
        'not-deployed' { return 'bootstrap' }
        'bootstrap' { return 'lock' }
        'lock' { return 'activate' }
        'activate' { return $null }
        default { throw 'This run cannot be recreated. Use a new LabId and a new external state path.' }
    }
}

function Assert-LabLifecycleRequest([string]$RequestedAction, [bool]$DeploymentApproved, [bool]$TestsApproved, [bool]$TeardownApproved, [string[]]$Groups, [string]$RemovalStep) {
    if ($RequestedAction -ne 'Create' -and $DeploymentApproved) { throw 'ApproveDeployment belongs only to Create' }
    if ($RequestedAction -ne 'Test' -and ($TestsApproved -or $Groups.Count)) { throw 'Test consent and groups belong only to Test' }
    if ($RequestedAction -ne 'Teardown' -and ($TeardownApproved -or $RemovalStep -ne 'Evidence')) { throw 'Teardown consent and steps belong only to Teardown' }
    if ($RequestedAction -eq 'Create' -and -not $DeploymentApproved) { throw 'Create requires ApproveDeployment from the current request' }
    if ($RequestedAction -eq 'Test' -and (-not $TestsApproved -or -not $Groups.Count)) { throw 'Test requires ApproveTests and explicit TestGroup; there is no default test suite' }
    if ($RequestedAction -eq 'Teardown' -and $RemovalStep -eq 'Advance' -and -not $TeardownApproved) { throw 'Teardown Advance requires ApproveTeardown from the current request' }
}

if ($DefinitionsOnly) { return }
$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$operationLock = $null
try {
    $requestedGroups = @($TestGroup | Where-Object { $_ })
    Assert-LabLifecycleRequest $Action ([bool]$ApproveDeployment) ([bool]$ApproveTests) ([bool]$ApproveTeardown) $requestedGroups $TeardownStep
    if (-not $StatePath) { throw 'StatePath is required and must be outside the public repository' }
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
    $StatePath = Assert-ExternalLabPath $StatePath
    if ([IO.Path]::GetFileName($StatePath) -cne 'state.json') { throw 'Use an external run directory with a state.json file' }
    if (-not (Test-Path -LiteralPath $StatePath)) {
        if ($Action -ne 'Create') { throw 'Run state does not exist; no resource can be adopted' }
        if (-not $LabId -or -not $AzureConfigDirectory) { throw 'First Create requires LabId and AzureConfigDirectory for the authenticated CLI session' }
        & (Join-Path $PSScriptRoot 'Initialize-LabRun.ps1') -RunDirectory ([IO.Path]::GetDirectoryName($StatePath)) -AzureConfigDirectory $AzureConfigDirectory -LabId $LabId -BicepExecutable $BicepExecutable -ApproveDeployment
    }
    $operationLock = [IO.File]::Open("$StatePath.operation.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $state = Read-LabRun $StatePath
    if ($state['lifecycleMode'] -cne 'independent' -or $state['minimalPrompt'] -eq $true -or $state.ContainsKey('standard')) {
        throw 'This entry point supports new independent full-profile runs only. Do not migrate historical or expanded state; use its recorded coordinator.'
    }
    if ($LabId -and $LabId -cne $state.labId) { throw 'LabId differs from the saved run' }
    if ($AzureConfigDirectory -and [IO.Path]::GetFullPath($AzureConfigDirectory) -ine [IO.Path]::GetFullPath($state.azureConfigDirectory)) { throw 'CLI cache differs from the saved run' }
    $groups = @(Confirm-LabRunContext $state)
    if ($Action -eq 'Status') {
        if ($state.pendingPhase) {
            & (Join-Path $PSScriptRoot 'Invoke-LabStage.ps1') -StatePath $StatePath -Phase $state.pendingPhase -Action Status
            $state = Read-LabRun $StatePath
        }
        [pscustomobject]@{labId=$state.labId; subscriptionId=$state.subscriptionId; phase=$state.phase; pendingPhase=$state.pendingPhase; existingGroups=$groups.Count; expectedGroups=$state.resourceGroups.Count; privateNetworkTestPassed=($state.privateAccessVerified -eq $true); statePath=$StatePath}
        return
    }
    if ($Action -eq 'Create') {
        if ($state.pendingPhase) {
            & (Join-Path $PSScriptRoot 'Invoke-LabStage.ps1') -StatePath $StatePath -Phase $state.pendingPhase -Action Status
            $state = Read-LabRun $StatePath
            if ($state.pendingPhase) { Write-Output 'Provisioning is pending. Observe Status before the next Create; no resubmission performed.'; return }
        }
        $phase = Get-LabNextCreationPhase $state
        if (-not $phase) {
            if ($groups.Count -ne $state.resourceGroups.Count) { throw 'An owned group is missing; do not recreate it implicitly' }
            Assert-LabDeploymentIdle $state
            Assert-LabActivationInfrastructure $state
            Write-Output 'Infrastructure provisioned (full core profile). No lab tests or hosted workload deployment were requested or performed by Create.'
            return
        }
        & (Join-Path $PSScriptRoot 'Invoke-LabStage.ps1') -StatePath $StatePath -Phase $phase -Action Preview
        & (Join-Path $PSScriptRoot 'Invoke-LabStage.ps1') -StatePath $StatePath -Phase $phase -Action Deploy
        Write-Output "Submitted $phase once. Use Status to observe ARM completion, then repeat Create to continue. Resources remain active; no automatic teardown."
        return
    }
    if ($Action -eq 'Test') {
        $selected = @($TestGroup | Select-Object -Unique)
        $afterRemoval = @('AfterTeardown','RetainedRecords')
        if ($state.pendingPhase) { throw 'Do not run tests while provisioning is pending' }
        foreach ($selectedGroup in $selected) {
            if ($selectedGroup -in $afterRemoval) {
                if ($state.phase -ne 'destroyed') { throw "$selectedGroup requires completed teardown" }
            } elseif ($state.phase -ne 'activate' -or $groups.Count -ne $state.resourceGroups.Count) { throw 'This test group requires the complete activated infrastructure' }
        }
        $remoteGroups = @('PrivateNetwork','Gateway','Identity','Agent','Registry')
        $runtimeGroups = @($selected | Where-Object { $_ -in @('Gateway','Identity','Agent','Registry') })
        if ($runtimeGroups.Count -and $state.privateAccessVerified -ne $true -and 'PrivateNetwork' -notin $selected) {
            throw 'Explicitly request PrivateNetwork first or include it in TestGroup; no unrequested test will run'
        }
        if ($state.phase -ne 'destroyed') { Assert-LabDeploymentIdle $state }
        Write-LabEvent $state 'tests-requested' @{groups=$selected; automaticTeardown=$false}
        if (@($selected | Where-Object { $_ -in $remoteGroups }).Count) {
            & (Join-Path $PSScriptRoot 'Invoke-LabRunner.ps1') -StatePath $StatePath -Action Prepare
        }
        if ('PrivateNetwork' -in $selected) {
            & (Join-Path $PSScriptRoot 'Invoke-LabRunner.ps1') -StatePath $StatePath -Action VerifyPrivate
        }
        foreach ($selectedGroup in $selected | Where-Object { $_ -ne 'PrivateNetwork' }) {
            switch ($selectedGroup) {
                'ControlPlane' { & (Join-Path $PSScriptRoot 'Test-LabControlPlane.ps1') -StatePath $StatePath -Phase activate }
                { $_ -in @('PublicAccess','AfterTeardown','RetainedRecords') } { & (Join-Path $PSScriptRoot 'Test-LabExternal.ps1') -StatePath $StatePath -Action $selectedGroup }
                default { & (Join-Path $PSScriptRoot 'Invoke-LabRunner.ps1') -StatePath $StatePath -Action $selectedGroup }
            }
        }
        Write-Output 'Selected groups finished. Inspect each report verdict; command completion is not a PASS. No lab teardown performed.'
        return
    }
    if ($TeardownStep -eq 'Advance' -and $ConfirmLabId -cne $state.labId) { throw 'ConfirmLabId must exactly match the lab to delete' }
    if ($TeardownStep -eq 'Advance' -and @($groups | Where-Object { $_.properties.provisioningState -notin @('Succeeded','Failed','Canceled') }).Count) {
        Write-Output 'An owned group operation is pending. Use Teardown Status; no deletion resubmitted.'
        return
    }
    if ($TeardownStep -eq 'Advance' -and $groups.Count -and -not $state['teardownEvidence']) {
        & (Join-Path $PSScriptRoot 'Remove-LabRun.ps1') -StatePath $StatePath -Action Evidence
    }
    $removalAction = if ($TeardownStep -eq 'Advance' -and -not $groups.Count) { 'Status' } else { $TeardownStep }
    & (Join-Path $PSScriptRoot 'Remove-LabRun.ps1') -StatePath $StatePath -Action $removalAction -ApproveTeardown:$ApproveTeardown -ConfirmLabId $ConfirmLabId
} finally {
    if ($operationLock) { $operationLock.Dispose() }
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}