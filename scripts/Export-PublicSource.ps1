[CmdletBinding()]
param([Parameter(Mandatory)][string]$DestinationPath)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'PublicSource.psm1') -Force
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $destination = Assert-ExternalLabPath $DestinationPath
    if (Test-Path -LiteralPath $destination) { throw 'Export destination must not exist' }
    $files = @(Get-PublicSourceFiles -Root $root)
    $null = New-Item -ItemType Directory -Path $destination
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName)
        $target = Join-Path $destination $relative
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
    $exported = @(Get-PublicSourceFiles -Root $destination)
    if ($exported.Count -ne $files.Count) { throw 'Export file count mismatch' }
    foreach ($file in $files) {
        $target = Join-Path $destination ([IO.Path]::GetRelativePath($root, $file.FullName))
        if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw 'Source changed during export' }
    }
    Write-Output "PASS: $($exported.Count) source files exported and rescanned. Nothing was published."
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}