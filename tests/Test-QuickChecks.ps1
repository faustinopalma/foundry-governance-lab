$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../scripts/Invoke-QuickChecks.ps1') -DefinitionsOnly
Initialize-QuickHelpers
$count=0
function Check($Condition) { if (-not $Condition) { throw 'Quick test assertion failed' }; $script:count++ }
Check ((Get-QuickVerdict $true @{status=403;data=@{code='CallerNotAllowed'}} 403 'CallerNotAllowed') -ceq 'PASS')
Check ((Get-QuickVerdict $false @{status=403;data=@{code='CallerNotAllowed'}} 403 'CallerNotAllowed') -ceq 'BLOCKED')
Check ((Get-QuickVerdict $true @{status=200;data=@{}} 403 '') -ceq 'FAIL')
foreach ($status in @(0,401,429,500)) { Check ((Get-QuickVerdict $true @{status=$status;data=@{}} 403 '') -ceq 'INCONCLUSIVE') }
Check ((Get-QuickVerdict $true @{status=403;data=@{code='Firewall'}} 403 'CallerNotAllowed') -ceq 'INCONCLUSIVE')
$script:calls=[Collections.Generic.List[object]]::new()
function Invoke-MinimalHttp($Uri,$Method,$Headers,$Body) { $script:calls.Add(@{uri=$Uri;method=$Method;body=$Body}); return @{status=404;body='{}';headers=@{}} }
function Write-MinimalPrivateFile($Path,$Text) { return 'synthetic-hash' }
$context=@{gateway='https://gateway.invalid';project='https://account.invalid/api/projects/case-a-dev';name='owned-agent';hosts=@{gateway='gateway.invalid';'case-a'='account.invalid'}}
$session=@{clock=[Diagnostics.Stopwatch]::StartNew();requests=0;inferenceRequests=0;rawDirectory='synthetic';secrets=[Collections.Generic.List[string]]::new();evidence=[Collections.Generic.List[object]]::new()}
foreach ($number in 2..10) { $null=Send-QuickRequest $context $session ('Q{0:D2}' -f $number) 'synthetic-token' }
Check ($calls.Count -eq 9)
Check (@($calls | Where-Object method -NotIn @('GET','POST')).Count -eq 0)
Check (@($calls | Where-Object { $_.method -eq 'POST' -and $_.uri -match '/agents(?:\?|/|$)' }).Count -eq 0)
$invocation=$calls[-1].body | ConvertFrom-Json -AsHashtable
Check ($invocation.agent_reference.version -ceq '1' -and $invocation.store -eq $false)
Check ($session.requests -eq 9)
$before=$calls.Count
try { $null=Send-QuickRequest $context $session 'CREATE' 'synthetic-token'; throw 'Expected rejection' } catch { Check ($_.Exception.Message -ceq 'Unknown quick test') }
Check ($calls.Count -eq $before)
function Get-IdentityPrivateDns { return 'PASS' }
function Get-MinimalToken { return 'synthetic-token' }
function Send-QuickRequest($Context,$Session,$Test,$Token) { $script:calls.Add($Test); return @{status=404;data=@{};listValid=$false;category='NotFound';elapsedSeconds=0} }
$session.tests=[Collections.Generic.List[object]]::new()
$calls.Clear()
Invoke-QuickSequence $context @{tenantId='synthetic'} $session
Check ('Q10' -cnotin $calls)
Check (@($session.tests | Where-Object { $_.test -ceq 'Q09' -and $_.status -ceq 'BLOCKED' }).Count -eq 1)
$accepted=@{tests=@(1..11 | ForEach-Object { @{test=('Q{0:D2}' -f $_);status='PASS'} })}
Assert-QuickAcceptance $accepted
Check ($true)
foreach ($verdict in @('FAIL','BLOCKED','INCONCLUSIVE')) {
	$accepted.tests[0].status=$verdict
	try { Assert-QuickAcceptance $accepted; throw 'Expected rejection' } catch { Check ($_.Exception.Message.StartsWith('Acceptance failed:')) }
}
$accepted.tests[0].status='PASS'
$accepted.tests[0].test='Q02'
try { Assert-QuickAcceptance $accepted; throw 'Expected rejection' } catch { Check ($_.Exception.Message.StartsWith('Acceptance failed:')) }
$accepted.tests=@($accepted.tests | Select-Object -Skip 1)
try { Assert-QuickAcceptance $accepted; throw 'Expected rejection' } catch { Check ($_.Exception.Message.StartsWith('Acceptance failed:')) }
Write-Output "PASS: $count focused quick-check assertions; no network or filesystem writes."