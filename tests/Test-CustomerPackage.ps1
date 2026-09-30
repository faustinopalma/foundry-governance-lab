[CmdletBinding()]
param([string]$BicepExecutable = 'bicep')

$ErrorActionPreference = 'Stop'
$packageTimer = [Diagnostics.Stopwatch]::StartNew()
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$packageTemporaryRoot = $null

function Invoke-CustomerPackageCompile {
    param([string]$SourcePath, [string]$OutputPath)

    $remainingMilliseconds = 180000 - [int]$packageTimer.ElapsedMilliseconds
    if ($remainingMilliseconds -le 0) { throw 'Customer package gate exceeded its 180-second budget' }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $packageCompiler.Source
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    foreach ($argument in @('build', $SourcePath, '--no-restore', '--outfile', $OutputPath)) {
        $process.StartInfo.ArgumentList.Add($argument)
    }
    try {
        if (-not $process.Start()) { throw 'Could not start the local Bicep compiler' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit([math]::Min(90000, $remainingMilliseconds))) {
            throw "Local Bicep compile timed out: $([IO.Path]::GetFileName($SourcePath)); no restore attempted"
        }
        $output = $stdout.GetAwaiter().GetResult()
        $diagnostics = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Local Bicep compile failed: $([IO.Path]::GetFileName($SourcePath)). Missing AVM cache requires a separate restore; this gate never restores. $output $diagnostics"
        }
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -or (Get-Item -LiteralPath $OutputPath).Length -eq 0) {
            throw 'Bicep returned no compiled template'
        }
        if ($output) { Write-Output $output.TrimEnd() }
        if ($diagnostics) { Write-Output $diagnostics.TrimEnd() }
    } finally {
        try {
            if ($process.Id -and -not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) { throw 'Local Bicep process did not terminate after tree kill' }
            }
        } finally { $process.Dispose() }
    }
}

function Invoke-CustomerGatewayCompiler {
    if ($args.Count -ne 4 -or $args[0] -cne 'build' -or $args[2] -cne '--outfile' -or
        [IO.Path]::GetFullPath($args[1]) -ne $packageGatewaySource) {
        throw 'Unexpected compiler invocation in the gateway policy fixture'
    }
    if (-not (Test-Path -LiteralPath $packageGatewayTemplate)) {
        Invoke-CustomerPackageCompile -SourcePath $packageGatewaySource -OutputPath $packageGatewayTemplate
    }
    Copy-Item -LiteralPath $packageGatewayTemplate -Destination $args[3] -Force
    $global:LASTEXITCODE = 0
}

try {
    $packageSources = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Force | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    if ($packageSources.Count -eq 0) { throw 'No PowerShell sources checked' }
    foreach ($source in $packageSources) {
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "PowerShell parse errors in $($source.FullName): $parseErrors" }
    }
    Write-Output "PASS: $($packageSources.Count) PowerShell files parsed"
    & (Join-Path $PSScriptRoot 'Test-PublicSource.ps1') -ScanSource
    & (Join-Path $PSScriptRoot 'Test-QuickChecks.ps1')
    & (Join-Path $PSScriptRoot 'Test-CustomerFoundationRoots.ps1')
    & (Join-Path $PSScriptRoot 'Test-CustomerTeardown.ps1')

    $packageCompiler = Get-Command $BicepExecutable -CommandType Application -ErrorAction Stop
    $packageTemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('customer-package-' + [guid]::NewGuid().ToString('N'))
    $packageTemporaryRoot = Assert-ExternalLabPath $packageTemporaryRoot
    $null = [IO.Directory]::CreateDirectory($packageTemporaryRoot)
    foreach ($entrypoint in @('main', 'standard', 'expansion-foundation', 'expansion-standard')) {
        $compiledPath = Join-Path $packageTemporaryRoot "$entrypoint.json"
        Invoke-CustomerPackageCompile -SourcePath (Join-Path $packageRoot "infra/$entrypoint.bicep") -OutputPath $compiledPath
        Write-Output "PASS: $entrypoint.bicep compiled with --no-restore"
        if ($entrypoint -ceq 'main') { & (Join-Path $PSScriptRoot 'Test-CompiledTemplate.ps1') -Path $compiledPath }
        if ($entrypoint -ceq 'standard') { & (Join-Path $PSScriptRoot 'Test-StandardTemplate.ps1') -Path $compiledPath }
    }
    $packageGatewaySource = [IO.Path]::GetFullPath((Join-Path $packageRoot 'infra/modules/gateway-policy-update.bicep'))
    $packageGatewayTemplate = Join-Path $packageTemporaryRoot 'gateway-policy-update.json'
    & (Join-Path $PSScriptRoot 'Test-GatewayPolicyUpdate.ps1') -BicepExecutable 'Invoke-CustomerGatewayCompiler'
    if ($packageTimer.Elapsed.TotalSeconds -gt 180) { throw 'Customer package gate exceeded its 180-second budget' }
    Write-Output 'PASS: focused customer package gate; four entrypoint builds plus the cached gateway fixture build; no restore or Azure requests'
} finally {
    if ($packageTemporaryRoot -and (Test-Path -LiteralPath $packageTemporaryRoot)) {
        Remove-Item -LiteralPath $packageTemporaryRoot -Recurse -Force
    }
    Write-Output "elapsed: $([math]::Round($packageTimer.Elapsed.TotalSeconds, 1))s"
}