[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [Parameter(Mandatory)][string]$AzureConfigDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{6,12}$')][string]$LabId,
    [Parameter(Mandatory)][string]$BicepExecutable,
    [switch]$ApproveDeployment,
    [switch]$ApproveDestroy,
    [switch]$MinimalPrompt
)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$previous = $env:AZURE_CONFIG_DIR
try {
    Import-Module (Join-Path $PSScriptRoot 'LabExecution.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1')
    if (-not $ApproveDeployment -or -not $ApproveDestroy) { throw 'This full-cycle initializer requires explicit deployment and teardown approval' }
    $directory = Assert-ExternalLabPath $RunDirectory
    $config = Assert-ExternalLabPath $AzureConfigDirectory
    if (Test-Path -LiteralPath $directory) { throw 'Run directory already exists; use its existing state instead' }
    $env:AZURE_CONFIG_DIR = $config
    $contextText = & az account show --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read explicit CLI context' }
    $context = $contextText | ConvertFrom-Json -AsHashtable
    $null = & az account get-access-token --subscription $context.id --resource 'https://management.azure.com/' --query expires_on -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'ARM token acquisition failed' }
    $null = New-Item -ItemType Directory -Path $directory
    if ($IsWindows) {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $null = & icacls $directory /inheritance:r /grant:r "*${currentSid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F'
        if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict private run directory permissions' }
    }
    $statePath = Join-Path $directory 'state.json'
    & (Join-Path $PSScriptRoot 'New-LabState.ps1') -StatePath $statePath -SubscriptionId $context.id -TenantId $context.tenantId -LabId $LabId -MinimalPrompt:$MinimalPrompt
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
    $state.runDirectory = $directory
    $state.azureConfigDirectory = $config
    $state.bicepExecutable = (Get-Command $BicepExecutable -CommandType Application).Source
    $state.deploymentAuthorized = $true
    $state.destroyAuthorized = $true
    $state.authorizedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $state.privateAccessVerified = $false
    $state.pendingPhase = $null
    $state.preexistingGroupIds = @()
    $groups = @(Invoke-LabAz $state @('group', 'list') 'baseline-groups')
    if (@($groups | Where-Object { $_.name -in $state.resourceGroups }).Count) { throw 'Target name collision; no resource can be adopted' }
    $state.preexistingGroupIds = @($groups.id)
    Save-LabRun $state $statePath
    $null = Invoke-LabAz $state @('resource', 'list') 'baseline-resources'
    $keyPath = Join-Path $directory 'runner-key'
    $keyArguments = @('-t', 'ed25519', '-N', '', '-C', 'synthetic-lab', '-f', $keyPath, '-q')
    & ssh-keygen @keyArguments
    if ($LASTEXITCODE -ne 0) { throw 'Cannot generate private runner key' }
    $null = & ssh-keygen -y -P '' -f $keyPath
    if ($LASTEXITCODE -ne 0) { throw 'Generated runner key cannot be used non-interactively' }
    if ($context.user.type -ne 'user' -or $context.user.name -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'Supply a reviewed external publisher email; context is not a user email' }
    $parameters = @{
        '$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion='1.0.0.0'
        parameters=@{
            labId=@{value=$LabId}; ownershipId=@{value=$state.ownershipId}; location=@{value='swedencentral'}
            phase=@{value='bootstrap'}; publisherEmail=@{value=$context.user.name}
            sshPublicKey=@{value=(Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim()}
            enableExperimentalAgents=@{value=$false}
            minimalPrompt=@{value=[bool]$MinimalPrompt}
        }
    }
    [IO.File]::WriteAllText((Join-Path $directory 'parameters.json'), ($parameters | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Write-LabEvent $state 'initialized' @{existingGroupCount=$groups.Count; cloudMutations=0}
    Write-Output 'Run initialized. Private inputs and baseline saved; no Azure resource created.'
} finally {
    $env:AZURE_CONFIG_DIR = $previous
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}