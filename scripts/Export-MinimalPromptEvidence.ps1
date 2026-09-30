<#
.SYNOPSIS
Export the current minimal prompt attempt records to a new private local directory.
.DESCRIPTION
Requires absolute external StatePath and SummaryPath, activated minimal outputs and current group/runner ownership. Uses only Invoke-LabAz and RunShellScript; the runner receives no credentials. Each saved shell script reads one bounded chunk using Linux python3, timeout and descriptor-relative no-follow opens. Remote files are never changed or executed.
MaxTotalBytes defaults to 262144 (256 KiB) and cannot exceed 1048576 (1 MiB), across at most 20 files. Each response carries at most 1800 raw bytes (2400 base64 characters). Oversized files fail with their exact size and remaining limit, never truncation; a near-2-MiB harness record needs a separately reviewed export path. Summary input is limited to 65536 bytes.
Results are placed under State.runDirectory/minimal-evidence-<random> outside public source. The directory retains the summary snapshot, all saved commands and Invoke-LabAz response/error artifacts, including after failure. Files are created exclusively and evidence is written only after whole-file SHA256 verification. Only export-complete.json indicates complete export; verified files from an interrupted export are retained. No automatic retry, remote cleanup, teardown or state update occurs.
The destination inherits the existing private run directory ACL on Windows; use an access-restricted private run directory. Linux directories/files use 0700/0600. Path checks reject existing symlinks/junctions; the local directory must not be writable by untrusted concurrent processes. Anonymous summaries bind bytes by hash on the owned runner, not by a signed lab identity. Console output contains only counts, limits and timings.
.EXAMPLE
./Export-MinimalPromptEvidence.ps1 -StatePath C:/private/run/state.json -SummaryPath C:/private/run/runner-MinimalPrompt.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$SummaryPath,
    [ValidateRange(1,1048576)][int]$MaxTotalBytes = 262144
)

function Read-MinimalExportJson([string]$Path, [int]$Limit) {
    try {
        $path = Assert-ExternalLabPath $Path
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($stream.Length -lt 1 -or $stream.Length -gt $Limit) { throw 'Input size' }
            $bytes = [byte[]]::new([int]$stream.Length)
            $stream.ReadExactly($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xfeff)
        $value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100 -ErrorAction Stop
        if ($value -isnot [hashtable]) { throw 'Input object' }
        return @{value=$value; bytes=$bytes}
    } catch { throw "Invalid private JSON input (limit $Limit bytes); details suppressed" }
}

function Write-MinimalExportBytes([string]$Path, [byte[]]$Bytes) {
    $null = Assert-ExternalLabPath $Path
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    if ($IsLinux) { $options.UnixCreateMode = [IO.UnixFileMode]384 }
    $stream = [IO.FileStream]::new($Path, $options)
    try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
}

function Test-MinimalExportInteger($Value) { return $Value -is [int] -or $Value -is [long] }

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1')
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1')
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
    if (-not [IO.Path]::IsPathFullyQualified($StatePath) -or -not [IO.Path]::IsPathFullyQualified($SummaryPath)) { throw 'Absolute private input paths required' }
    $null = Read-MinimalExportJson $StatePath 65536
    try { $state = Read-LabRun $StatePath } catch { throw 'Invalid private lab state; details suppressed' }
    $lab = (Read-MinimalExportJson (Join-Path $state.runDirectory 'outputs.json') 262144).value
    . (Join-Path $PSScriptRoot 'Invoke-MinimalPromptChecks.ps1') -DefinitionsOnly
    $null = Get-MinimalPromptContext $state $lab
    if ($state.deploymentAuthorized -isnot [bool] -or -not $state.deploymentAuthorized -or $lab.runner -isnot [string]) { throw 'Authorized minimal runner required' }
    $source = Read-MinimalExportJson $SummaryPath 65536
    $summary = $source.value
    if (-not (Test-MinimalExportInteger $summary.schemaVersion) -or $summary.schemaVersion -ne 1 -or $summary.runLive -isnot [bool] -or -not $summary.runLive -or $summary.rawDirectory -isnot [string] -or $summary.rawDirectory -cnotmatch '\A/var/lib/fgl-private/minimal-[0-9a-f]{32}\z') { throw 'Invalid live minimal evidence summary' }
    if ($summary.evidence -isnot [array] -or $summary.evidence.Count -lt 1 -or $summary.evidence.Count -gt 20) { throw 'Evidence count must be between 1 and 20' }
    if (-not (Test-MinimalExportInteger $summary.requests) -or $summary.requests -ne $summary.evidence.Count) { throw 'Evidence must cover every recorded request' }
    $ordinal = 0
    foreach ($entry in $summary.evidence) {
        $ordinal++
        $pattern = '\A' + ('{0:D2}' -f $ordinal) + '-(?:token-ai|token-client|token-direct|gateway|direct-central|control|connection|agent-get|agent-create|invoke)\.json\z'
        if ($entry -isnot [hashtable] -or $entry.Count -ne 2 -or $entry.file -isnot [string] -or $entry.file -cnotmatch $pattern -or $entry.sha256 -isnot [string] -or $entry.sha256 -cnotmatch '\A[0-9a-fA-F]{64}\z') { throw 'Invalid evidence filename, sequence or SHA256' }
    }
    $directory = Assert-ExternalLabPath (Join-Path $state.runDirectory ('minimal-evidence-' + [guid]::NewGuid().ToString('N')))
    if (Test-Path -LiteralPath $directory) { throw 'Export directory already exists' }
    if ($IsLinux) { $null = [IO.Directory]::CreateDirectory($directory, [IO.UnixFileMode]448) }
    else { $null = [IO.Directory]::CreateDirectory($directory) }
    Write-MinimalExportBytes (Join-Path $directory 'summary.json') $source.bytes
    $exportState = $state.Clone()
    $exportState.runDirectory = $directory
    $groups = @(Confirm-LabRunContext $exportState)
    if ($groups.Count -ne $state.resourceGroups.Count -or @(Compare-Object @($groups.name) $state.resourceGroups).Count) { throw 'All owned lab groups must still exist' }
    foreach ($group in $groups) { Assert-LabGroupOwnership $state $group }
    $runnerGroup = "rg-fgl-$($state.labId)-integration"
    $runnerName = "vm-fgl-$($state.labId)-runner"
    $runner = Invoke-LabAz $exportState @('vm','show','--resource-group',$runnerGroup,'--name',$runnerName) 'evidence-runner'
    if ($runner.id -isnot [string] -or $runner.id -ine $lab.runner -or $runner.tags['fgl-owner'] -isnot [string] -or $runner.tags['fgl-owner'] -cne $state.ownershipId -or $runner.tags['fgl-lab'] -isnot [string] -or $runner.tags['fgl-lab'] -cne $state.labId -or $runner.storageProfile.osDisk.osType -cne 'Linux') { throw 'Owned Linux runner verification failed' }
    $verified = [Collections.Generic.List[object]]::new()
    $totalBytes = 0
    foreach ($entry in $summary.evidence) {
        $offset = 0
        $size = 0
        $signature = $null
        $buffer = $null
        $remaining = $MaxTotalBytes - $totalBytes
        do {
            $marker = 'FGL_EVIDENCE_' + [guid]::NewGuid().ToString('N')
            $request = @{directory=$summary.rawDirectory.Substring('/var/lib/fgl-private/'.Length); file=$entry.file; offset=$offset; limit=$remaining; marker=$marker}
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Compress)))
            $shell = @'
set -eu
umask 077
timeout 20 python3 - <<'FGL_READER'
import base64, hashlib, json, os, stat
request = json.loads(base64.b64decode('__REQUEST__'))
def read_chunk():
    directory = None
    descriptor = None
    try:
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        directory = os.open('/', flags)
        for component in ('var', 'lib', 'fgl-private', request['directory']):
            child = os.open(component, flags, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(request['file'], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError()
        if before.st_size > request['limit']:
            return {'status': 'limit', 'size': before.st_size, 'limit': request['limit']}
        if before.st_size < 1 or request['offset'] < 0 or request['offset'] >= before.st_size:
            raise ValueError()
        identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        payload = os.pread(descriptor, min(1800, before.st_size - request['offset']), request['offset'])
        if identity(before) != identity(os.fstat(descriptor)):
            raise ValueError()
        signature = hashlib.sha256(repr(identity(before)).encode('ascii')).hexdigest()
        return {'status': 'ok', 'size': before.st_size, 'offset': request['offset'], 'signature': signature, 'data': base64.b64encode(payload).decode('ascii')}
    except Exception:
        return {'status': 'blocked'}
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if directory is not None:
            os.close(directory)
packet = read_chunk()
print(request['marker'] + '_BEGIN')
print(json.dumps(packet, separators=(',', ':')))
print(request['marker'] + '_END')
FGL_READER
'@
            $label = 'evidence-{0:D2}-{1:D6}' -f ($verified.Count + 1), $offset
            $scriptPath = Join-Path $directory "$label.sh"
            Write-MinimalExportBytes $scriptPath ([Text.Encoding]::UTF8.GetBytes(($shell.Replace('__REQUEST__', $encoded).Replace("`r", '') + "`n")))
            $response = Invoke-LabAz $exportState @('vm','run-command','invoke','--resource-group',$runnerGroup,'--name',$runnerName,'--command-id','RunShellScript','--scripts',"@$scriptPath") $label
            if ($response.value -isnot [array] -or $response.value.Count -lt 1 -or $response.value.Count -gt 4) { throw 'Invalid Run Command result; private artifacts retained' }
            foreach ($part in $response.value) {
                if ($part.code -isnot [string] -or $part.code -cnotmatch '\A(?:ProvisioningState|ComponentStatus/(?:StdOut|StdErr))/succeeded\z' -or $part.message -isnot [string] -or $part.message.Length -gt 8192) { throw 'Run Command failed or output exceeded its bound; private artifacts retained' }
            }
            $message = ($response.value | ForEach-Object { $_.message }) -join "`n"
            $frames = [regex]::Matches($message, "(?m)^${marker}_BEGIN\r?\n([^\r\n]{1,3000})\r?\n${marker}_END\r?$" )
            if ($frames.Count -ne 1 -or [regex]::Matches($message, [regex]::Escape($marker + '_BEGIN')).Count -ne 1 -or [regex]::Matches($message, [regex]::Escape($marker + '_END')).Count -ne 1) { throw 'Missing, duplicate or truncated evidence frame; private artifacts retained' }
            try { $packet = ConvertFrom-Json -InputObject $frames[0].Groups[1].Value -AsHashtable -Depth 10 -ErrorAction Stop } catch { throw 'Invalid evidence frame JSON; details suppressed' }
            if ($packet -isnot [hashtable] -or $packet.status -isnot [string]) { throw 'Invalid evidence packet' }
            if ($packet.status -ceq 'limit' -and (Test-MinimalExportInteger $packet.size) -and (Test-MinimalExportInteger $packet.limit) -and $packet.limit -eq $remaining -and $packet.size -gt $remaining) { throw "Evidence file size $($packet.size) bytes exceeds remaining limit $remaining bytes; MaxTotalBytes=$MaxTotalBytes bytes, hard maximum 1048576 bytes. Nothing truncated; private artifacts retained" }
            if ($packet.status -cne 'ok' -or $packet.Count -ne 5 -or -not (Test-MinimalExportInteger $packet.size) -or $packet.size -lt 1 -or $packet.size -gt $remaining -or -not (Test-MinimalExportInteger $packet.offset) -or $packet.offset -ne $offset -or $packet.signature -isnot [string] -or $packet.signature -cnotmatch '\A[0-9a-f]{64}\z') { throw 'Remote evidence blocked or invalid size, offset or signature; private artifacts retained' }
            if ($offset -eq 0) {
                $size = [int]$packet.size
                $signature = $packet.signature
                $buffer = [byte[]]::new($size)
            } elseif ($packet.size -ne $size -or $packet.signature -cne $signature) { throw 'Remote evidence changed during export; private artifacts retained' }
            $length = [math]::Min(1800, $size - $offset)
            if ($packet.data -isnot [string] -or $packet.data.Length -ne (4 * [math]::Ceiling($length / 3))) { throw 'Evidence chunk length mismatch' }
            try { $chunk = [Convert]::FromBase64String($packet.data) } catch { throw 'Invalid evidence base64; details suppressed' }
            if ($chunk.Length -ne $length -or [Convert]::ToBase64String($chunk) -cne $packet.data) { throw 'Noncanonical or incomplete evidence chunk' }
            [Array]::Copy($chunk, 0, $buffer, $offset, $length)
            $offset += $length
        } while ($offset -lt $size)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($buffer)).ToLowerInvariant()
        if ($hash -cne $entry.sha256.ToLowerInvariant()) { throw 'Evidence SHA256 mismatch; unverified file not written, private artifacts retained' }
        Write-MinimalExportBytes (Join-Path $directory $entry.file) $buffer
        $verified.Add(@{file=$entry.file; sha256=$hash; bytes=$size})
        $totalBytes += $size
    }
    $receipt = @{schemaVersion=1; complete=$true; summarySha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source.bytes)).ToLowerInvariant(); evidence=$verified.ToArray(); totalBytes=$totalBytes; maxTotalBytes=$MaxTotalBytes; chunkBytes=1800}
    Write-MinimalExportBytes (Join-Path $directory 'export-complete.json') ([Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 10)))
    Write-Output "PASS: $($verified.Count) evidence files, $totalBytes bytes verified; new export saved under the private run directory."
} finally { Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s" }