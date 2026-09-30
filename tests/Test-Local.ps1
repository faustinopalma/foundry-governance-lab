[CmdletBinding()]
param([string]$CompiledTemplatePath, [string]$BicepExecutable = 'bicep')

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$temporaryTemplate = $null
$temporaryStandardTemplate = $null
$temporaryExpansionProjects = $null
$temporaryExpansionFoundation = $null
try {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $sources = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    if ($sources.Count -eq 0) { throw 'No PowerShell sources checked' }
    foreach ($source in $sources) {
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "PowerShell parse errors in $($source.Name)" }
    }
    & (Join-Path $PSScriptRoot 'Test-LabSafety.ps1')
    & (Join-Path $PSScriptRoot 'Test-Teardown.ps1')
    & (Join-Path $PSScriptRoot 'Test-CustomerFoundationRoots.ps1')
    & (Join-Path $PSScriptRoot 'Test-CustomerTeardown.ps1')
    & (Join-Path $PSScriptRoot 'Test-PublicSource.ps1') -ScanSource
    & (Join-Path $PSScriptRoot 'Test-Results.ps1')
    & (Join-Path $PSScriptRoot 'Test-ControlPlane.ps1')
    & (Join-Path $PSScriptRoot 'Test-IdentityChecks.ps1')
    & (Join-Path $PSScriptRoot 'Test-External.ps1')
    & (Join-Path $PSScriptRoot 'Test-AgentChecks.ps1')
    & (Join-Path $PSScriptRoot 'Test-RegistryChecks.ps1')
    & (Join-Path $PSScriptRoot 'Test-QuickChecks.ps1')
    & (Join-Path $PSScriptRoot 'Test-MinimalPromptChecks.ps1')
    & (Join-Path $PSScriptRoot 'Test-MinimalTeardownAcceptance.ps1')
    & (Join-Path $PSScriptRoot 'Test-StandardStage.ps1')
    & (Join-Path $PSScriptRoot 'Test-StandardPrivate.ps1')
    & (Join-Path $PSScriptRoot 'Test-StandardCosmosNetwork.ps1') -BicepExecutable $BicepExecutable
    & (Join-Path $PSScriptRoot 'Test-GatewayPolicyUpdate.ps1') -BicepExecutable $BicepExecutable
    $compiler = Get-Command $BicepExecutable -CommandType Application -ErrorAction Stop
    if (-not $CompiledTemplatePath) {
        $temporaryTemplate = Join-Path ([IO.Path]::GetTempPath()) ("fgl-build-$([guid]::NewGuid().ToString('N')).json")
        & $compiler.Source build (Join-Path $root 'infra/main.bicep') --outfile $temporaryTemplate
        if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed' }
        $CompiledTemplatePath = $temporaryTemplate
    }
    & (Join-Path $PSScriptRoot 'Test-CompiledTemplate.ps1') -Path $CompiledTemplatePath
    $temporaryStandardTemplate = Join-Path ([IO.Path]::GetTempPath()) ("fgl-standard-build-$([guid]::NewGuid().ToString('N')).json")
    & $compiler.Source build (Join-Path $root 'infra/standard.bicep') --outfile $temporaryStandardTemplate
    if ($LASTEXITCODE -ne 0) { throw 'Standard Bicep compilation failed' }
    & (Join-Path $PSScriptRoot 'Test-StandardTemplate.ps1') -Path $temporaryStandardTemplate
    $temporaryExpansionProjects = Join-Path ([IO.Path]::GetTempPath()) ("fgl-expansion-projects-$([guid]::NewGuid().ToString('N')).json")
    & $compiler.Source build (Join-Path $root 'infra/modules/expansion-projects.bicep') --outfile $temporaryExpansionProjects
    if ($LASTEXITCODE -ne 0) { throw 'Expansion project compilation failed' }
    & (Join-Path $PSScriptRoot 'Test-ExpansionProjects.ps1') -CompiledTemplatePath $temporaryExpansionProjects
    $temporaryExpansionFoundation = Join-Path ([IO.Path]::GetTempPath()) ("fgl-expansion-foundation-$([guid]::NewGuid().ToString('N')).json")
    & $compiler.Source build (Join-Path $root 'infra/expansion-foundation.bicep') --outfile $temporaryExpansionFoundation
    if ($LASTEXITCODE -ne 0) { throw 'Expansion foundation compilation failed' }
    & (Join-Path $PSScriptRoot 'Test-ExpansionFoundation.ps1') -CompiledTemplatePath $temporaryExpansionFoundation -BicepExecutable $BicepExecutable
    & (Join-Path $PSScriptRoot 'Test-ExpansionCoordinator.ps1') -BicepExecutable $BicepExecutable
    $policy = [xml](Get-Content -LiteralPath (Join-Path $root 'infra/policies/inference.xml') -Raw)
    if ($policy.policies.inbound.'validate-content'.content.'schema-id' -ne 'lab-chat-body') { throw 'Policy schema reference missing' }
    if ($policy.policies.inbound.choose.when.'return-response'.'set-status'.code -ne '403') { throw 'Explicit caller denial missing' }
    $schemaPath = Join-Path $root 'infra/policies/chat.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
    if ($schema.'$schema' -ne 'http://json-schema.org/draft-04/schema#') { throw 'Unexpected APIM schema dialect' }
    $schema['$schema'] = 'https://json-schema.org/draft/2020-12/schema'
    $localSchema = $schema | ConvertTo-Json -Depth 20
    if (-not (Test-Json -Json '{"messages":[{"role":"user","content":"OK"}]}' -Schema $localSchema)) { throw 'Valid synthetic message rejected' }
    if (Test-Json -Json '{"messages":[]}' -Schema $localSchema -ErrorAction SilentlyContinue) { throw 'Empty message negative control accepted' }
    Write-Output "PASS: $($sources.Count) PowerShell files parsed; policy XML and schema controls passed; no Azure requests made"
} finally {
    if ($temporaryTemplate -and (Test-Path -LiteralPath $temporaryTemplate)) { Remove-Item -LiteralPath $temporaryTemplate }
    if ($temporaryStandardTemplate -and (Test-Path -LiteralPath $temporaryStandardTemplate)) { Remove-Item -LiteralPath $temporaryStandardTemplate }
    if ($temporaryExpansionProjects -and (Test-Path -LiteralPath $temporaryExpansionProjects)) { Remove-Item -LiteralPath $temporaryExpansionProjects }
    if ($temporaryExpansionFoundation -and (Test-Path -LiteralPath $temporaryExpansionFoundation)) { Remove-Item -LiteralPath $temporaryExpansionFoundation }
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}