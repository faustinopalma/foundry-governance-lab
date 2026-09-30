[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{6,12}$')][string]$LabId,
    [switch]$MinimalPrompt
)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'LabSafety.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1') -Force
    $path = Assert-ExternalLabPath $StatePath
    $state = @{
        schemaVersion = 1
        labId = $LabId
        subscriptionId = $SubscriptionId.ToString()
        tenantId = $TenantId.ToString()
        ownershipId = [guid]::NewGuid().ToString()
        minimalPrompt = [bool]$MinimalPrompt
        resourceGroups = @(if ($MinimalPrompt) { 'models', 'integration', 'case-a' } else { 'models', 'integration', 'case-a', 'case-b' }) | ForEach-Object { "rg-fgl-$LabId-$_" }
        phase = 'not-deployed'
        deploymentAuthorized = $false
    }
    Assert-LabState $state
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 10))
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    Write-Output 'Private ownership state created. No Azure operation was performed.'
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}