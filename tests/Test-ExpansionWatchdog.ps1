[CmdletBinding()]
param([ValidateSet('Success','Failure','Blocked','Busy','TreeExit','TreeBlocked','Grandchild')][string]$Fixture,[string]$PrivatePidPath)

if ($Fixture) {
    $ErrorActionPreference='Stop'
    if ($Fixture -ceq 'Grandchild') {
        [IO.File]::WriteAllText("$PrivatePidPath.ready",'ready')
        $gate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset)
        $null=$gate.WaitOne()
        exit 0
    }
    if ($Fixture -cin @('TreeExit','TreeBlocked')) {
        $grandchild=[Diagnostics.Process]::new()
        $grandchild.StartInfo.FileName=[Environment]::ProcessPath
        $grandchild.StartInfo.UseShellExecute=$false
        foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Fixture','Grandchild','-PrivatePidPath',$PrivatePidPath)) { $grandchild.StartInfo.ArgumentList.Add($argument) }
        $null=$grandchild.Start()
        [IO.File]::WriteAllText($PrivatePidPath,(@{processId=$grandchild.Id;startTicks=$grandchild.StartTime.ToUniversalTime().Ticks} | ConvertTo-Json))
        $readyClock=[Diagnostics.Stopwatch]::StartNew()
        $gate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset)
        while (-not (Test-Path -LiteralPath "$PrivatePidPath.ready")) {
            if ($readyClock.Elapsed.TotalSeconds -gt 5) { throw 'Grandchild startup exceeded five seconds' }
            $null=$gate.WaitOne(20)
        }
        [Console]::Out.WriteLine('grandchild ready')
        if ($Fixture -ceq 'TreeExit') { exit 0 }
        $null=$gate.WaitOne()
        exit 0
    }
    switch ($Fixture) {
        'Success' { [Console]::Out.WriteLine('synthetic output'); [Console]::Error.WriteLine('synthetic stderr'); exit 0 }
        'Failure' { [Console]::Error.WriteLine('synthetic failure'); exit 7 }
        'Blocked' { $gate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset); $null=$gate.WaitOne(); exit 0 }
        'Busy' { $counter=0; while ($true) { $counter++; if ($counter % 100000 -eq 0) { [Console]::Out.WriteLine('still running') } } }
    }
}
$ErrorActionPreference='Stop'
$timer=[Diagnostics.Stopwatch]::StartNew()
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('expansion-watchdog-test-'+[guid]::NewGuid().ToString('N'))
$checks=0
try {
    . (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionWatchdog.ps1') -DefinitionsOnly
    function Assert-Watchdog($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
    foreach ($scenario in @(@{name='Success';max=10;idle=5;reason='Exited';code=0},@{name='Failure';max=10;idle=5;reason='Exited';code=7},@{name='Blocked';max=10;idle=1;reason='NoOutput'},@{name='Busy';max=2;idle=5;reason='Deadline'})) {
        $result=Invoke-BoundedLabProcess -Executable ([Environment]::ProcessPath) -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Fixture',$scenario.name) -LogPrefix (Join-Path $testDirectory $scenario.name) -MaxSeconds $scenario.max -IdleSeconds $scenario.idle -HeartbeatSeconds 1
        Assert-Watchdog ($result.reason -ceq $scenario.reason) "Wrong verdict for $($scenario.name)"
        if ($scenario.ContainsKey('code')) { Assert-Watchdog ($result.exitCode -eq $scenario.code) 'Exit code lost' }
        Assert-Watchdog ($result.elapsedSeconds -lt $scenario.max+6) 'Deadline overrun'
        Assert-Watchdog (-not $result.azureCanceled -and -not $result.retried) 'Unexpected cloud action'
        Assert-Watchdog (-not (Get-Process -Id $result.processId -ErrorAction SilentlyContinue)) 'Supervised process remains alive'
        if ($scenario.name -ceq 'Success') { Assert-Watchdog ((Get-Content $result.stdout -Raw).Contains('synthetic output') -and (Get-Content $result.stderr -Raw).Contains('synthetic stderr')) 'Redirected output incomplete' }
    }
    foreach ($scenario in @(@{name='TreeExit';reason='Exited'},@{name='TreeBlocked';reason='Deadline'})) {
        $privatePidPath=Join-Path $testDirectory "$($scenario.name).pid.json"
        try {
            $result=Invoke-BoundedLabProcess -Executable ([Environment]::ProcessPath) -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Fixture',$scenario.name,'-PrivatePidPath',$privatePidPath) -LogPrefix (Join-Path $testDirectory $scenario.name) -MaxSeconds 8 -IdleSeconds 10 -HeartbeatSeconds 1
            Assert-Watchdog ($result.reason -ceq $scenario.reason) "Wrong tree verdict for $($scenario.name)"
            if ($scenario.name -ceq 'TreeExit') { Assert-Watchdog ($result.exitCode -eq 0) 'Tree parent did not exit normally' }
            Assert-Watchdog (Test-Path -LiteralPath "$privatePidPath.ready") 'Grandchild never reached its blocking fixture'
            $identity=Get-Content -LiteralPath $privatePidPath -Raw | ConvertFrom-Json
            $owned=Get-Process -Id $identity.processId -ErrorAction SilentlyContinue
            try {
                $gone=$null -eq $owned -or $owned.StartTime.ToUniversalTime().Ticks -ne $identity.startTicks -or $owned.WaitForExit(5000)
                Assert-Watchdog $gone "Owned grandchild survived $($scenario.name)"
            } finally { if ($null -ne $owned) { $owned.Dispose() } }
            Assert-Watchdog (-not (Get-Process -Id $result.processId -ErrorAction SilentlyContinue)) 'Tree parent remains alive'
        } finally {
            if (Test-Path -LiteralPath $privatePidPath) {
                $identity=Get-Content -LiteralPath $privatePidPath -Raw | ConvertFrom-Json
                $owned=Get-Process -Id $identity.processId -ErrorAction SilentlyContinue
                if ($null -ne $owned) {
                    try {
                        if ($owned.StartTime.ToUniversalTime().Ticks -eq $identity.startTicks -and -not $owned.HasExited) { $owned.Kill(); if (-not $owned.WaitForExit(5000)) { throw 'Owned fixture cleanup failed' } }
                    } finally { $owned.Dispose() }
                }
            }
        }
    }
    & {
        $stateFile=Join-Path $testDirectory 'original.json'; [IO.File]::WriteAllText($stateFile,'{"synthetic":true}')
        $mode=@{reason='NoOutput';exitCode=-1;diagnoses=0;submits=0;supervisorError=$false;diagnosticError=$false;removeState=$false;azureState='Running'}
        function Read-LabRun { return @{runDirectory=$testDirectory} }
        function Invoke-BoundedLabProcess { param($Executable,$Arguments,$LogPrefix,$MaxSeconds,$IdleSeconds); $mode.arguments=$Arguments; $mode.submits++; if ($mode.supervisorError) { throw 'synthetic supervisor error' }; if ($mode.removeState) { Remove-Item -LiteralPath $stateFile }; return @{reason=$mode.reason;exitCode=$mode.exitCode} }
        function Get-ExpansionWatchdogDiagnosis { $mode.diagnoses++; if ($mode.diagnosticError) { throw 'synthetic diagnostic error' }; return @{state=$mode.azureState;readOnly=$true} }
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Status' 'unused' $false 10 2
        Assert-Watchdog ($result.outcome -ceq 'NoOutput' -and $mode.diagnoses -eq 1 -and $mode.submits -eq 1) 'Timeout did not diagnose exactly once'
        Assert-Watchdog ($result.originalUnchanged -and -not $result.retried) 'Timeout changed state or replayed work'
        $mode.reason='Exited'; $mode.exitCode=0
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Status' 'unused' $false 10 2
        Assert-Watchdog ($result.outcome -ceq 'Completed' -and $mode.diagnoses -eq 1) 'Successful phase unexpectedly diagnosed'
        Assert-Watchdog ('-ApproveValidatorRevision' -cnotin $mode.arguments) 'Implicit validator revision approval'
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Status' 'unused' $false 10 2 $true
        Assert-Watchdog ($result.outcome -ceq 'Completed' -and '-ApproveValidatorRevision' -cin $mode.arguments -and '-ApproveDependencies' -cnotin $mode.arguments) 'Read-only validator approval was not forwarded precisely'
        foreach ($action in @('Inspect','Observe','Preview','Deploy')) {
            $rejected=$false
            try { Invoke-ExpansionWatchdog $stateFile 'a-test' $action 'unused' $true 10 2 $true } catch { $rejected=$true }
            Assert-Watchdog $rejected 'Validator revision accepted outside Status'
        }
        $rejected=$false
        try { Invoke-ExpansionWatchdog $stateFile 'a-test' 'Deploy' 'unused' $false 10 2 } catch { $rejected=$true }
        Assert-Watchdog $rejected 'Unapproved deployment accepted'
        $mode.supervisorError=$true
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Status' 'unused' $false 10 2
        Assert-Watchdog ($result.outcome -ceq 'Error' -and $result.error -ceq 'synthetic supervisor error' -and $mode.diagnoses -eq 2) 'Supervisor exception skipped diagnosis'
        $mode.diagnosticError=$true
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Status' 'unused' $false 10 2
        Assert-Watchdog ($result.error -ceq 'synthetic supervisor error' -and $result.diagnosisError -ceq 'synthetic diagnostic error' -and $mode.diagnoses -eq 3) 'Independent errors lost or diagnosis retried'
        $mode.supervisorError=$false; $mode.reason='Deadline'
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Status' 'unused' $false 10 2
        Assert-Watchdog ($mode.diagnoses -eq 4 -and $result.error -ceq 'synthetic diagnostic error') 'Failed diagnosis was retried'
        $mode.diagnosticError=$false; $mode.reason='Exited'; $mode.removeState=$true
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Status' 'unused' $false 10 2
        Assert-Watchdog ($result.outcome -ceq 'OriginalStateUnverifiable' -and $null -eq $result.originalUnchanged -and $result.originalCheckError) 'Unavailable original state lost receipt'
        $saved=@(Get-ChildItem -LiteralPath $testDirectory -Filter receipt.json -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable })
        Assert-Watchdog (@($saved | Where-Object outcome -CEQ 'OriginalStateUnverifiable').Count -eq 1) 'Unavailable-state receipt was not persisted'
        [IO.File]::WriteAllText($stateFile,'{"synthetic":true}')
        $mode.removeState=$false; $mode.azureState='Succeeded'
        $before=$mode.submits
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Observe' 'unused' $false 10 2
        Assert-Watchdog ($result.outcome -ceq 'AzureSucceeded' -and $mode.submits -eq $before) 'Observation launched work despite completed Azure deployment'
        $mode.azureState='Running'; $mode.reason='Deadline'; $mode.exitCode=-1
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Observe' 'unused' $false 10 2
        Assert-Watchdog ($result.outcome -ceq 'CloudDeadline' -and $result.observations.Count -eq 2 -and $mode.submits -eq $before+1) 'Observation timeout did not make exactly one final diagnosis'
        $mode.azureState='Failed'
        $result=Invoke-ExpansionWatchdog $stateFile 'a-test' 'Observe' 'unused' $false 10 2
        Assert-Watchdog ($result.outcome -ceq 'ObservationStopped' -and $mode.submits -eq $before+1) 'Failed Azure deployment was retried or waited on'
    }
    Write-Output "PASS: $checks watchdog checks; real silent/busy children and normal-exit/timeout grandchildren terminated; failure diagnosis mocked without Azure access."
} finally {
    if (Test-Path -LiteralPath $testDirectory) { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
    Write-Output ('elapsed: {0:N2}s' -f $timer.Elapsed.TotalSeconds)
}