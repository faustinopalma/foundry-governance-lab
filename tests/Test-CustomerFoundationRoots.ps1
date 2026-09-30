[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionFoundation.ps1') -DefinitionsOnly
$checks=@{count=0}
function Check([bool]$Condition) { if (-not $Condition) { throw 'Foundation roots assertion failed' }; $checks.count++ }
function Reject([scriptblock]$Probe) { $failed=$false; try { $null=& $Probe } catch { $failed=$true }; Check $failed }
function Clone($Value) { return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 }
function Assert-LabState { }
function Invoke-FoundationAz { throw 'Offline test forbids Azure' }
function Invoke-LabAz { throw 'Offline test forbids Azure' }
function CheckRoots([hashtable]$State, [array]$Expected) {
    Assert-FoundationOriginal $State
    $actual=@(Get-FoundationRootIds $State)
    Check ($actual.Count -eq $Expected.Count)
    Check ((($actual | Sort-Object -CaseSensitive) -join "`n") -ceq (($Expected | Sort-Object -CaseSensitive) -join "`n"))
}

$fixtureState=@{subscriptionId='11111111-1111-4111-8111-111111111111';labId='sample01';minimalPrompt=$true;privateAccessVerified=$true;deploymentAuthorized=$true;phase='activate';pendingPhase=$null;standard=@{pendingStage=$null;completedStages=@('dependencies','account','project','access');deploymentNames=@{}}}
foreach ($stage in @('dependencies','account','project','access')) { $fixtureState.standard.deploymentNames[$stage]="fgl-sample01-standard-$stage" }
foreach ($spec in @(@('cosmosNetwork','standard-cosmos-network'),@('gatewayPolicy','gateway-policy-update'))) {
    $fixtureState.standard[$spec[0]]=@{pending=$false;verified=$true;name="fgl-sample01-$($spec[1])";group='rg-fgl-sample01-integration';review=@{};evidence=@{}}
}
$fixturePrefix="/subscriptions/$($fixtureState.subscriptionId)"
$fixtureExpected=@('bootstrap','lock','activate','standard-dependencies','standard-account','standard-project','standard-access' | ForEach-Object { "$fixturePrefix/providers/Microsoft.Resources/deployments/fgl-sample01-$_" })
$fixtureCosmos="$fixturePrefix/resourceGroups/rg-fgl-sample01-integration/providers/Microsoft.Resources/deployments/fgl-sample01-standard-cosmos-network"
$fixtureUpdate="$fixturePrefix/resourceGroups/rg-fgl-sample01-integration/providers/Microsoft.Resources/deployments/fgl-sample01-gateway-policy-update"
$fixtureActivation="$fixturePrefix/providers/Microsoft.Resources/deployments/fgl-sample01-activate"
CheckRoots $fixtureState @($fixtureExpected + $fixtureCosmos + $fixtureUpdate)
$fixtureAttested=Clone $fixtureState
$fixtureAttested.standard.gatewayPolicy.review=@{source='activation-policy-reuse';activationDeploymentId=$fixtureActivation}
CheckRoots $fixtureAttested @($fixtureExpected + $fixtureCosmos)

foreach ($mutation in @(
    {param($value) $value.standard.gatewayPolicy.review.source='unknown'},
    {param($value) $value.standard.gatewayPolicy.review.source='Activation-policy-reuse'},
    {param($value) $value.standard.gatewayPolicy.review.source=$null},
    {param($value) $value.standard.gatewayPolicy.review.source=$true},
    {param($value) $value.standard.gatewayPolicy.review.source=@('activation-policy-reuse')},
    {param($value) $value.standard.gatewayPolicy.review.Remove('source')},
    {param($value) $value.standard.gatewayPolicy.review.activationDeploymentId+='-foreign'},
    {param($value) $value.standard.gatewayPolicy.review.activationDeploymentId=$fixtureActivation.Replace('sample01','other01')},
    {param($value) $value.standard.gatewayPolicy.review.activationDeploymentId=$fixtureActivation.Replace('11111111','99999999')},
    {param($value) $value.standard.gatewayPolicy.review.activationDeploymentId=$fixtureUpdate},
    {param($value) $value.standard.gatewayPolicy.review.activationDeploymentId=$true},
    {param($value) $value.standard.gatewayPolicy.review.Remove('activationDeploymentId')},
    {param($value) $value.standard.gatewayPolicy.review=@()},
    {param($value) $value.standard.gatewayPolicy.pending=$true},
    {param($value) $value.standard.gatewayPolicy.pending='false'},
    {param($value) $value.standard.gatewayPolicy.verified=$false},
    {param($value) $value.standard.gatewayPolicy.verified='true'},
    {param($value) $value.standard.gatewayPolicy.name='fgl-other01-gateway-policy-update'},
    {param($value) $value.standard.gatewayPolicy.group='rg-fgl-other01-integration'},
    {param($value) $value.standard.gatewayPolicy.evidence=$null},
    {param($value) $value.standard.cosmosNetwork.pending=$true},
    {param($value) $value.standard.cosmosNetwork.group='rg-fgl-other01-integration'},
    {param($value) $value.standard.deploymentNames.access='foreign'}
)) {
    $invalid=Clone $fixtureAttested
    $null=& $mutation $invalid
    Reject { Assert-FoundationOriginal $invalid }
    Reject { Get-FoundationRootIds $invalid }
}

foreach ($candidate in @($fixtureState,$fixtureAttested)) {
    $withoutAccount=Clone $candidate
    $withoutAccount.standard.deploymentNames.Remove('account')
    $expectedWithoutAccount=@($fixtureExpected | Where-Object { $_ -cne "$fixturePrefix/providers/Microsoft.Resources/deployments/fgl-sample01-standard-account" }) + $fixtureCosmos
    if (-not $candidate.standard.gatewayPolicy.review.ContainsKey('source')) { $expectedWithoutAccount += $fixtureUpdate }
    CheckRoots $withoutAccount $expectedWithoutAccount
}
Write-Output "PASS: $($checks.count) foundation root assertions (offline)"