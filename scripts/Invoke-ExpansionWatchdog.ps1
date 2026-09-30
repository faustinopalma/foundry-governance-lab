[CmdletBinding()]
param(
    [string]$StatePath,
    [ValidateSet('a-test','b-dev','b-test')][string]$Project,
    [ValidateSet('Inspect','Observe','Preview','Deploy','Status')][string]$Action = 'Inspect',
    [string]$BicepExecutable = 'bicep',
    [switch]$ApproveDependencies,
    [switch]$ApproveValidatorRevision,
    [ValidateRange(1,1200)][int]$MaxSeconds = 1200,
    [ValidateRange(1,120)][int]$IdleSeconds = 120,
    [switch]$DefinitionsOnly
)

Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')

if ($IsWindows -and -not ('ExpansionWatchdogJob' -as [type])) {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class ExpansionWatchdogJob : SafeHandleZeroOrMinusOneIsInvalid
{
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits
    {
        public BasicLimits Basic;
        public ulong ReadOperations, WriteOperations, OtherOperations;
        public ulong ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(ExpansionWatchdogJob job, int infoClass, ref ExtendedLimits limits, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(ExpansionWatchdogJob job, SafeProcessHandle process);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    public ExpansionWatchdogJob() : base(true)
    {
        SetHandle(CreateJobObjectW(IntPtr.Zero, null));
        if (IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");
        var limits = new ExtendedLimits();
        limits.Basic.Flags = 0x00002000;
        if (!SetInformationJobObject(this, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>()))
        {
            int error = Marshal.GetLastWin32Error();
            Dispose();
            throw new Win32Exception(error, "Kill-on-close job configuration failed");
        }
    }
    public void Assign(SafeProcessHandle process)
    {
        if (!AssignProcessToJobObject(this, process))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Job assignment failed; supervision refused");
    }
    protected override bool ReleaseHandle() { return CloseHandle(handle); }
}
'@
}

function Invoke-BoundedLabProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$LogPrefix,
        [ValidateRange(1,1200)][int]$MaxSeconds = 1200,
        [ValidateRange(1,120)][int]$IdleSeconds = 120,
        [ValidateRange(1,30)][int]$HeartbeatSeconds = 30,
        [hashtable]$Environment = @{}
    )
    $ErrorActionPreference='Stop'
    if (-not $IsWindows) { throw 'Windows Job Object containment is required; this platform is unsupported' }
    $prefix=Assert-ExternalLabPath $LogPrefix
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($prefix))
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $process=[Diagnostics.Process]::new()
    $streams=@(); $copies=@(); $started=$false; $job=$null; $reason='Exited'; $lastBytes=0; $lastOutput=0.0; $nextHeartbeat=0.0
    try {
        $job=[ExpansionWatchdogJob]::new()
        $process.StartInfo.FileName=$Executable
        $process.StartInfo.UseShellExecute=$false
        $process.StartInfo.RedirectStandardOutput=$true
        $process.StartInfo.RedirectStandardError=$true
        $process.StartInfo.RedirectStandardInput=$true
        $process.StartInfo.CreateNoWindow=$true
        foreach ($argument in $Arguments) { $process.StartInfo.ArgumentList.Add($argument) }
        foreach ($key in $Environment.Keys) { $process.StartInfo.Environment[$key]=[string]$Environment[$key] }
        foreach ($suffix in @('stdout','stderr')) { $streams+= [IO.FileStream]::new("$prefix.$suffix.txt",[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,$true) }
        # Start is not suspended: descendants created before assignment are NOT guaranteed contained.
        $started=$process.Start()
        $job.Assign($process.SafeHandle)
        $process.StandardInput.Close()
        $copies+= $process.StandardOutput.BaseStream.CopyToAsync($streams[0])
        $copies+= $process.StandardError.BaseStream.CopyToAsync($streams[1])
        while (-not $process.HasExited) {
            $elapsed=$clock.Elapsed.TotalSeconds
            $bytes=(Get-Item -LiteralPath "$prefix.stdout.txt").Length+(Get-Item -LiteralPath "$prefix.stderr.txt").Length
            if ($bytes -ne $lastBytes) { $lastBytes=$bytes; $lastOutput=$elapsed }
            if ($elapsed -ge $MaxSeconds) { $reason='Deadline'; break }
            if ($elapsed-$lastOutput -ge $IdleSeconds) { $reason='NoOutput'; break }
            if ($elapsed -ge $nextHeartbeat) {
                Write-Host ('WATCHDOG {0:HH:mm:ss} elapsed={1:N1}s limit={2}s idle={3:N1}s bytes={4}' -f [DateTimeOffset]::Now,$elapsed,$MaxSeconds,($elapsed-$lastOutput),$bytes)
                $nextHeartbeat=$elapsed+$HeartbeatSeconds
            }
            $wait=[math]::Max(1,[math]::Min(1000,[math]::Min(($MaxSeconds-$elapsed)*1000,($IdleSeconds-($elapsed-$lastOutput))*1000)))
            $null=$process.WaitForExit([int]$wait)
        }
        if (-not $process.HasExited) {
            Write-Host "WATCHDOG $reason; terminating only members of the supervised local job. Azure is not canceled or retried."
        }
        $job.Dispose()
        if (-not $process.WaitForExit(5000)) { throw 'Supervised process did not terminate within five seconds' }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$copies,5000)) { throw 'Output drain exceeded five seconds' }
        return @{reason=$reason;exitCode=$process.ExitCode;processId=$process.Id;elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,3);stdout="$prefix.stdout.txt";stderr="$prefix.stderr.txt";maxSeconds=$MaxSeconds;idleSeconds=$IdleSeconds;azureCanceled=$false;retried=$false}
    } finally {
        try {
            if ($null -ne $job) { $job.Dispose() }
            if ($started -and -not $process.HasExited) {
                $process.Kill()
                if (-not $process.WaitForExit(5000)) { throw 'Supervised process cleanup exceeded five seconds' }
            }
        } finally {
            foreach ($stream in $streams) { $stream.Dispose() }
            $process.Dispose()
        }
    }
}

function Get-ExpansionWatchdogDiagnosis([hashtable]$State, [string]$Selector, [string]$Directory) {
    $manifestPath=Join-Path $State.runDirectory "expansion-standard-$Selector.state.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { return @{state='NotSubmitted';readOnly=$true} }
    $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    if (-not $manifest.deploymentId) { return @{state='NotSubmitted';readOnly=$true;pending=$manifest.pending;verified=$manifest.verified} }
    $expected="/subscriptions/$($State.subscriptionId)/providers/Microsoft.Resources/deployments/fgl-$($State.labId)-exp-standard-$Selector"
    if ($manifest.deploymentId -ine $expected) { throw 'Diagnostic deployment ID is outside the selected owned root' }
    $azPath=@(Get-Command az -CommandType Application)[0].Source
    $cliPython=Join-Path ([IO.Path]::GetDirectoryName($azPath)) '../python.exe'
    $prefix=@(); $executable=$azPath
    if ([IO.Path]::GetExtension($azPath) -eq '.cmd') {
        if (-not (Test-Path -LiteralPath $cliPython)) { throw 'Azure CLI Python executable not found; no shell fallback' }
        $executable=$cliPython; $prefix=@('-IBm','azure.cli')
    }
    $diagnosis=@{state='Unknown';readOnly=$true;pending=$manifest.pending;verified=$manifest.verified;checkedAt=[DateTimeOffset]::UtcNow.ToString('o');reads=@()}
    foreach ($item in @(@{name='root';suffix=''},@{name='operations';suffix='/operations'})) {
        $arguments=$prefix+@('rest','--method','get','--url',"https://management.azure.com$expected$($item.suffix)?api-version=2022-09-01",'--headers','Accept=application/json','--subscription',$State.subscriptionId,'--only-show-errors','--output','json')
        $result=Invoke-BoundedLabProcess -Executable $executable -Arguments $arguments -LogPrefix (Join-Path $Directory $item.name) -MaxSeconds 60 -IdleSeconds 60 -Environment @{AZURE_CONFIG_DIR=$State.azureConfigDirectory;AZURE_CORE_NO_COLOR='true'}
        $diagnosis.reads+=@($result)
        if ($result.reason -cne 'Exited' -or $result.exitCode -ne 0) { $diagnosis.state='ProbeFailed'; break }
        $response=Get-Content -LiteralPath $result.stdout -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        if ($item.name -ceq 'root') {
            if ($response.id -ine $expected) { throw 'Diagnostic root response ID mismatch' }
            $diagnosis.state=$response.properties.provisioningState; $diagnosis.error=$response.properties.error
        } else {
            $diagnosis.operations=@($response.value | ForEach-Object { @{state=$_.properties.provisioningState;operation=$_.properties.provisioningOperation;target=$_.properties.targetResource;error=$_.properties.statusMessage} })
            $diagnosis.operationsComplete=-not [bool]$response.nextLink
        }
    }
    return $diagnosis
}

function Invoke-ExpansionWatchdog([string]$Path,[string]$Selector,[string]$SelectedAction,[string]$Compiler,[bool]$Approved,[int]$Budget,[int]$IdleBudget,[bool]$ValidatorRevisionApproved=$false) {
    if ($ValidatorRevisionApproved -and $SelectedAction -cne 'Status') { throw 'Validator revision approval is Status only' }
    if (-not $Path -or $Selector -cnotin @('a-test','b-dev','b-test') -or $SelectedAction -cnotin @('Inspect','Observe','Preview','Deploy','Status')) { throw 'Explicit StatePath, Project and valid Action required' }
    if ($Budget -lt 1 -or $Budget -gt 1200 -or $IdleBudget -lt 1 -or $IdleBudget -gt 120) { throw 'Invalid watchdog budget' }
    if ($SelectedAction -cin @('Preview','Deploy') -and -not $Approved) { throw 'ApproveDependencies required; watchdog grants no deployment authorization' }
    $state=Read-LabRun $Path
    $originalHash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $directory=Assert-ExternalLabPath (Join-Path $state.runDirectory ('watchdog-'+$Selector+'-'+[DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfff')+'-'+[guid]::NewGuid().ToString('N')))
    $null=[IO.Directory]::CreateDirectory($directory)
    $receipt=@{action=$SelectedAction;project=$Selector;startedAt=[DateTimeOffset]::UtcNow.ToString('o');maxSeconds=$Budget;idleSeconds=$IdleBudget;outcome='Started';originalSha=$originalHash;azureCanceled=$false;retried=$false}
    $receiptPath=Join-Path $directory 'receipt.json'
    try {
        if ($SelectedAction -ceq 'Inspect') { $receipt.diagnosis=Get-ExpansionWatchdogDiagnosis $state $Selector $directory; $receipt.outcome='Inspected' }
        elseif ($SelectedAction -ceq 'Observe') {
            $observationClock=[Diagnostics.Stopwatch]::StartNew()
            $receipt.observations=@(); $observation=0
            do {
                $observation++
                $observationDirectory=Join-Path $directory "observation-$observation"
                $receipt.diagnosisAttempted=$true
                $receipt.diagnosis=Get-ExpansionWatchdogDiagnosis $state $Selector $observationDirectory
                $receipt.observations+=@($receipt.diagnosis)
                Write-Host "AZURE OBSERVATION $observation state=$($receipt.diagnosis.state) elapsed=$([math]::Round($observationClock.Elapsed.TotalSeconds,1))s budget=${Budget}s"
                if ($receipt.diagnosis.state -ceq 'Succeeded') { $receipt.outcome='AzureSucceeded'; break }
                if ($receipt.diagnosis.state -cnotin @('Running','Accepted','Creating','Updating')) { $receipt.outcome='ObservationStopped'; break }
                $remaining=[math]::Floor($Budget-$observationClock.Elapsed.TotalSeconds)
                if ($remaining -lt 1 -or $receipt.observationInterrupted) { $receipt.outcome='CloudDeadline'; break }
                $azPath=@(Get-Command az -CommandType Application)[0].Source
                $cliPython=Join-Path ([IO.Path]::GetDirectoryName($azPath)) '../python.exe'
                if (-not (Test-Path -LiteralPath $cliPython)) { throw 'Azure CLI Python executable not found' }
                $slice=[int][math]::Min(120,$remaining)
                $arguments=@('-IBm','azure.cli','deployment','sub','wait','--name',"fgl-$($state.labId)-exp-standard-$Selector",'--subscription',$state.subscriptionId,'--created','--timeout',[string][math]::Max(1,[math]::Min(90,$slice-10)),'--interval','15','--only-show-errors')
                $receipt.waitProcess=Invoke-BoundedLabProcess -Executable $cliPython -Arguments $arguments -LogPrefix (Join-Path $observationDirectory 'wait') -MaxSeconds $slice -IdleSeconds ([math]::Min($IdleBudget,$slice)) -Environment @{AZURE_CONFIG_DIR=$state.azureConfigDirectory}
                $receipt.observationInterrupted=$receipt.waitProcess.reason -cne 'Exited' -or $receipt.waitProcess.exitCode -ne 0
            } while ($true)
        }
        else {
            $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'Invoke-ExpansionStandard.ps1'),'-StatePath',$Path,'-Project',$Selector,'-Action',$SelectedAction,'-BicepExecutable',$Compiler)
            if ($Approved) { $arguments+='-ApproveDependencies' }
            if ($ValidatorRevisionApproved) { $arguments+='-ApproveValidatorRevision' }
            $receipt.process=Invoke-BoundedLabProcess -Executable ([Environment]::ProcessPath) -Arguments $arguments -LogPrefix (Join-Path $directory 'phase') -MaxSeconds $Budget -IdleSeconds $IdleBudget
            if ($receipt.process.reason -ceq 'Exited' -and $receipt.process.exitCode -eq 0) { $receipt.outcome='Completed' }
            else {
                $receipt.outcome=$receipt.process.reason
                if ($receipt.outcome -ceq 'Exited') { $receipt.outcome='Failed' }
                $receipt.diagnosisAttempted=$true
                $receipt.diagnosis=Get-ExpansionWatchdogDiagnosis $state $Selector $directory
            }
        }
    } catch {
        $receipt.outcome='Error'; $receipt.error=$_.Exception.Message
        if ($SelectedAction -cne 'Inspect' -and -not $receipt.ContainsKey('diagnosisAttempted')) {
            $receipt.diagnosisAttempted=$true
            try { $receipt.diagnosis=Get-ExpansionWatchdogDiagnosis $state $Selector $directory }
            catch { $receipt.diagnosisError=$_.Exception.Message }
        }
    }
    finally {
        $receipt.finishedAt=[DateTimeOffset]::UtcNow.ToString('o')
        try {
            $receipt.originalUnchanged=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ceq $originalHash
            if (-not $receipt.originalUnchanged) { $receipt.outcome='OriginalStateChanged' }
        } catch {
            $receipt.originalUnchanged=$null; $receipt.originalCheckError=$_.Exception.Message
            $receipt.outcome='OriginalStateUnverifiable'
        }
        [IO.File]::WriteAllText($receiptPath,($receipt | ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
        Write-Host "VERDICT: $($receipt.outcome); Azure=$($receipt.diagnosis.state); private receipt=$receiptPath"
    }
    return $receipt
}

if ($DefinitionsOnly) { return }
$ErrorActionPreference='Stop'
$timer=[Diagnostics.Stopwatch]::StartNew()
try {
    $result=Invoke-ExpansionWatchdog $StatePath $Project $Action $BicepExecutable ([bool]$ApproveDependencies) $MaxSeconds $IdleSeconds ([bool]$ApproveValidatorRevision)
    if ($result.outcome -cnotin @('Completed','Inspected','AzureSucceeded') -or ($result.outcome -ceq 'Inspected' -and $result.diagnosis.state -cin @('ProbeFailed','Unknown'))) { throw 'Watchdog stopped or diagnostics failed; inspect its private receipt. No automatic deployment replay.' }
} finally { Write-Host ('elapsed: {0:N1}s' -f $timer.Elapsed.TotalSeconds) }