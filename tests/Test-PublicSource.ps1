[CmdletBinding()]
param([switch]$ScanSource)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
$temporaryRoot = $null

function Assert-CopilotSkillPackage([string]$Root) {
    $packageRoot = [IO.Path]::GetFullPath($Root)
    $skillRelative = '.github/skills/foundry-governance-lab/SKILL.md'
    $instructionRelative = '.github/copilot-instructions.md'
    $skillPath = Join-Path $packageRoot $skillRelative
    $skillText = Get-Content -LiteralPath $skillPath -Raw
    $header = [regex]::Match($skillText, '\A---\r?\nname: (?<name>[a-z0-9]+(?:-[a-z0-9]+)*)\r?\ndescription: ''(?<description>[^''\r\n]+)''\r?\nuser-invocable: true\r?\n---(?:\r?\n|$)')
    if (-not $header.Success -or $header.Groups['name'].Value -cne [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($skillPath)) -or $header.Groups['name'].Length -gt 64 -or $header.Groups['description'].Length -gt 1024) { throw 'Invalid packaged skill frontmatter contract' }
    $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'public-files.json') -Raw | ConvertFrom-Json
    $linkCount = 0
    foreach ($relative in @($skillRelative, $instructionRelative)) {
        if ($relative -cnotin $manifest.files) { throw 'Copilot customization missing from public allowlist' }
        $file = Join-Path $packageRoot $relative
        $content = Get-Content -LiteralPath $file -Raw
        $links = [regex]::Matches($content, '\[[^\]\r\n]+\]\((?<target>[^\s)]+)\)')
        if ($links.Count -eq 0) { throw 'Copilot customization contains no resource links' }
        foreach ($link in $links) {
            $target = $link.Groups['target'].Value
            if ($target -match '^https://') { continue }
            $resolved = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($file)) $target))
            if (-not $resolved.StartsWith("$packageRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw 'Copilot resource link is missing or escapes package' }
            $linkCount++
        }
    }
    if ($linkCount -lt 15) { throw 'Insufficient packaged skill link coverage' }
}

try {
    Import-Module (Join-Path $PSScriptRoot '../scripts/PublicSource.psm1') -Force
    $checks = 0
    Assert-PublicText 'Synthetic lab content without identifiers.'
    $checks++
    Assert-PublicText '17d1049b-9a84-46fb-8f53-869881c3d3ab 00000000-0000-0000-0000-000000000002 44444444-4444-4444-8444-444444444444'
    $checks++
    $fixtures = @(
        [guid]::NewGuid().ToString(),
        ('-----BEGIN ' + 'PRIVATE KEY-----'),
        ('eyJ' + ('a' * 30) + '.' + ('b' * 30) + '.' + ('c' * 30)),
        ('AccountKey=' + ('z' * 32)),
        ('https://private-lab.azure' + 'cr.io'),
        ('contact@' + 'private.example.org')
    )
    foreach ($fixture in $fixtures) {
        $rejected = $false
        try { Assert-PublicText $fixture } catch { $rejected = $true }
        if (-not $rejected) { throw 'Confidentiality negative control was accepted' }
        $checks++
    }
    $rejected = $false
    try { $null = Assert-ExternalLabPath (Join-Path $PSScriptRoot '../private-state.json') } catch { $rejected = $true }
    if (-not $rejected) { throw 'Private state path inside source was accepted' }
    $checks++
    if ($ScanSource) {
        $files = @(Get-PublicSourceFiles -Root (Join-Path $PSScriptRoot '..'))
        if ($files.Count -eq 0) { throw 'Scanner checked zero files' }
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("fgl-publication-$([guid]::NewGuid().ToString('N'))")
        $null = New-Item -ItemType Directory -Path $temporaryRoot
        $destination = Join-Path $temporaryRoot 'source'
        $null = & (Join-Path $PSScriptRoot '../scripts/Export-PublicSource.ps1') -DestinationPath $destination
        $exported = @(Get-ChildItem -LiteralPath $destination -Recurse -File -Force)
        if ($exported.Count -ne $files.Count) { throw 'Export contains missing or extra files' }
        $checks++
        Assert-CopilotSkillPackage $destination
        $checks++
        $skillPath = Join-Path $destination '.github/skills/foundry-governance-lab/SKILL.md'
        $skillText = [IO.File]::ReadAllText($skillPath)
        $skillFixtures = @(
            $skillText.Replace('name: foundry-governance-lab', 'name: mismatched-name'),
            $skillText.Replace('user-invocable: true', 'user-invocable: false'),
            $skillText.Replace('../../../docs/Lifecycle.md', '../../../docs/missing.md'),
            $skillText.Replace('../../../docs/Lifecycle.md', '../../../../outside.md')
        )
        try {
            foreach ($fixture in $skillFixtures) {
                if ($fixture -ceq $skillText) { throw 'Skill negative control did not change its fixture' }
                [IO.File]::WriteAllText($skillPath, $fixture)
                $rejected = $false
                try { Assert-CopilotSkillPackage $destination } catch { $rejected = $true }
                if (-not $rejected) { throw 'Invalid skill or nonportable resource link accepted' }
                $checks++
            }
        } finally { [IO.File]::WriteAllText($skillPath, $skillText) }
        Assert-CopilotSkillPackage $destination
        Write-Output 'PASS: exported Copilot skill, frontmatter contract and package-local resource links; four negative controls'
        $rejected = $false
        try { $null = & (Join-Path $PSScriptRoot '../scripts/Export-PublicSource.ps1') -DestinationPath $destination } catch { $rejected = $true }
        if (-not $rejected) { throw 'Existing export destination accepted' }
        $checks++
        $statePath = Join-Path $temporaryRoot 'private-state.json'
        $arguments = @{ StatePath=$statePath; SubscriptionId='11111111-1111-4111-8111-111111111111'; TenantId='22222222-2222-4222-8222-222222222222'; LabId='sample01' }
        $null = & (Join-Path $PSScriptRoot '../scripts/New-LabState.ps1') @arguments
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.phase -ne 'not-deployed' -or $state.deploymentAuthorized -ne $false -or @($state.resourceGroups).Count -ne 4) { throw 'Unexpected initial private state' }
        $checks++
        $rejected = $false
        try { $null = & (Join-Path $PSScriptRoot '../scripts/New-LabState.ps1') @arguments } catch { $rejected = $true }
        if (-not $rejected) { throw 'Existing private state overwritten' }
        $checks++
        Write-Output "PASS: $($files.Count) allowlisted files scanned"
    }
    Write-Output "PASS: $checks publication safety checks"
} finally {
    if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}