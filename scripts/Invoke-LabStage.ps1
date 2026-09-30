[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][ValidateSet('bootstrap','lock','activate')][string]$Phase,
    [ValidateSet('Preview','Deploy','Status')][string]$Action = 'Preview'
)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1') -Force
    $state = Read-LabRun $StatePath
    $null = Confirm-LabRunContext $state
    Assert-LabTransition $state $Phase
    $deploymentName = "fgl-$($state.labId)-$Phase"
    $templatePath = Join-Path $state.runDirectory "$Phase.template.json"
    $parametersPath = Join-Path $state.runDirectory "$Phase.parameters.json"
    if ($Action -eq 'Preview') {
        & $state.bicepExecutable build (Join-Path $PSScriptRoot '../infra/main.bicep') --outfile $templatePath
        if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed' }
        & (Join-Path $PSScriptRoot '../tests/Test-CompiledTemplate.ps1') -Path $templatePath
        $parameters = Get-Content -LiteralPath (Join-Path $state.runDirectory 'parameters.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-LabParameters $state $parameters.parameters
        $parameters.parameters.phase.value = $Phase
        if ($Phase -eq 'activate') {
            $lab = Get-Content (Join-Path $state.runDirectory 'outputs.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            Assert-LabResourceId $state $lab.gateway
            $gateway = Invoke-LabAz $state @('resource','show','--ids',$lab.gateway,'--api-version','2024-05-01') 'activation-gateway-identity'
            if ($gateway.properties.publicNetworkAccess -ne 'Disabled' -or $gateway.tags['fgl-owner'] -ne $state.ownershipId -or -not $gateway.identity.principalId) { throw 'Owned private gateway identity must exist before activation' }
            $parameters.parameters.gatewayPrincipalId = @{value=$gateway.identity.principalId}
        }
        [IO.File]::WriteAllText($parametersPath, ($parameters | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $common = @('--location','swedencentral','--name',$deploymentName,'--template-file',$templatePath,'--parameters',"@$parametersPath")
        $null = Invoke-LabAz $state (@('deployment','sub','validate') + $common) "$Phase-validate"
        $preview = Invoke-LabAz $state (@('deployment','sub','what-if','--no-pretty-print') + $common) "$Phase-whatif"
        Assert-LabWhatIf $state $preview
        $state.review = @{phase=$Phase; templateHash=(Get-FileHash $templatePath).Hash; parametersHash=(Get-FileHash $parametersPath).Hash; checkedAt=[DateTimeOffset]::UtcNow.ToString('o')}
        Save-LabRun $state $StatePath
        Write-Output 'Preview passed exact scope checks; artifacts hashed. No resources deployed.'
    } elseif ($Action -eq 'Deploy') {
        if ($state.pendingPhase) {
            $pending = Invoke-LabAz $state @('deployment','sub','show','--name',$state.deploymentName) "$Phase-retry-state"
            if ($pending.properties.provisioningState -notin @('Succeeded','Failed','Canceled')) { throw 'An active deployment cannot be overwritten; reconcile Status first' }
            foreach ($groupName in $state.resourceGroups) {
                $nested = @(Invoke-LabAz $state @('deployment','group','list','--resource-group',$groupName) "$Phase-retry-nested")
                if (@($nested | Where-Object { $_.properties.provisioningState -notin @('Succeeded','Failed','Canceled') }).Count) { throw 'A nested deployment is still active; retry is not permitted' }
            }
        }
        if (-not $state.ContainsKey('review') -or $state.review.phase -ne $Phase) { throw 'Successful matching preview required' }
        if ((Get-FileHash $templatePath).Hash -ne $state.review.templateHash -or (Get-FileHash $parametersPath).Hash -ne $state.review.parametersHash) { throw 'Reviewed deployment artifacts changed' }
        $parameters = Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-LabParameters $state $parameters.parameters
        if ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($state.review.checkedAt) -gt [TimeSpan]::FromHours(1)) { throw 'Preview is stale' }
        $state.pendingPhase = $Phase
        $state.deploymentName = $deploymentName
        Save-LabRun $state $StatePath
        $null = Invoke-LabAz $state @('deployment','sub','create','--location','swedencentral','--name',$deploymentName,'--template-file',$templatePath,'--parameters',"@$parametersPath",'--no-wait') "$Phase-start"
        Write-Output 'Deployment submitted. Run Status to reconcile actual provisioning before advancing.'
    } else {
        if ($state.pendingPhase -ne $Phase) { throw 'No matching submitted phase to reconcile' }
        $deployment = Invoke-LabAz $state @('deployment','sub','show','--name',$deploymentName) "$Phase-status"
        $status = $deployment.properties.provisioningState
        if ($status -eq 'Succeeded') {
            $state.phase = $Phase
            $state.pendingPhase = $null
            Save-LabRun $state $StatePath
            [IO.File]::WriteAllText((Join-Path $state.runDirectory 'outputs.json'), ($deployment.properties.outputs.lab.value | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        } elseif ($status -in @('Failed','Canceled')) {
            $null = Invoke-LabAz $state @('deployment','operation','sub','list','--name',$deploymentName) "$Phase-failed-operations"
            throw "Deployment $status; pending stage retained for controlled repair or teardown"
        }
        Write-Output "Phase: $Phase; provisioning: $status"
    }
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}