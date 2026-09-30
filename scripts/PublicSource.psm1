Set-StrictMode -Version Latest

function Assert-ExternalLabPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith("$root$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Private files must be outside the public source root'
    }
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked private paths are not accepted' }
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    return $full
}

function Assert-PublicText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $publicGuids = @(
        '53ca6127-db72-4b80-b1b0-d745d6d5456d', 'eed3b665-ab3a-47b6-8f48-c9382fb1dad6',
        '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd', 'b93aa761-3e63-49ed-ac28-beffa264f7ac',
        '2a1e307c-b015-4ebd-883e-5b7698a07328', 'acdd72a7-3385-48ef-bd42-f606fba81ae7',
        '17d1049b-9a84-46fb-8f53-869881c3d3ab', '230815da-be43-4aae-9cb4-875f7bd000aa',
        '8ebe5a00-799e-43f5-93ac-243d3dce84a7', '7ca78c08-252a-4471-8644-bb5ff32d4ba0',
        'ba92f5b4-2d11-453d-a403-e96b0029c9fe', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b',
        '00000000-0000-0000-0000-000000000002', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635',
        '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222',
        '33333333-3333-4333-8333-333333333333', '44444444-4444-4444-8444-444444444444',
        '55555555-5555-4555-8555-555555555555', '66666666-6666-4666-8666-666666666666',
        '77777777-7777-4777-8777-777777777777', '88888888-8888-4888-8888-888888888888',
        '11111111-1111-1111-1111-111111111111'
    )
    foreach ($match in [regex]::Matches($Text, '(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b')) {
        if ($match.Value -notin $publicGuids) { throw 'Non-public GUID in publication candidate' }
    }
    $patterns = @(
        '-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',
        '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}',
        '(?i)\b(?:AccountKey|SharedAccessSignature|client_secret)\s*[=:]\s*["'']?[A-Za-z0-9+/=_-]{16,}',
        '(?i)\b(?:ghp_|github_pat_|sk-proj-)[A-Za-z0-9_]{15,}',
        '(?i)[A-Z0-9._%+-]+@(?!example\.invalid\b)[A-Z0-9.-]+\.[A-Z]{2,}'
    )
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) { throw 'Credential, private endpoint, or contact information in publication candidate' }
    }
    foreach ($match in [regex]::Matches($Text, '(?i)\b[a-z0-9][a-z0-9-]{2,}\.(?:openai\.azure\.com|services\.ai\.azure\.com|azurecr\.io|azure-api\.net)\b')) {
        if ($match.Value -notmatch '^privatelink\.') { throw 'Private service hostname in publication candidate' }
    }
}

function Get-PublicSourceFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $rootPath = [IO.Path]::GetFullPath($Root)
    $manifest = Get-Content -LiteralPath (Join-Path $rootPath 'public-files.json') -Raw | ConvertFrom-Json
    if (@($manifest.files).Count -eq 0) { throw 'Empty publication allowlist' }
    if (@($manifest.files | Select-Object -Unique).Count -ne @($manifest.files).Count) { throw 'Duplicate publication path' }
    foreach ($relative in $manifest.files) {
        if ($relative -match '(^/|\\|(^|/)\.\.(/|$)|:|(^|/)(\.azure|\.local|results|artifacts)(/|$))') { throw 'Invalid publication path' }
        $full = [IO.Path]::GetFullPath((Join-Path $rootPath $relative))
        if (-not $full.StartsWith("$rootPath$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) { throw 'Publication path escaped root' }
        $item = Get-Item -LiteralPath $full -Force
        if ($item.PSIsContainer) { throw 'Only individual source files may be published' }
        if ($item.Name -ne '.gitignore' -and $item.Extension -notin @('.md', '.ps1', '.psm1', '.json', '.bicep', '.bicepparam', '.xml')) { throw 'Non-source file type in publication allowlist' }
        $ancestor = $full
        while ($ancestor -and $ancestor -ne [IO.Path]::GetDirectoryName($rootPath)) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked publication files are not accepted' }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
        Assert-PublicText (Get-Content -LiteralPath $full -Raw)
        $item
    }
}

Export-ModuleMember -Function Assert-ExternalLabPath, Assert-PublicText, Get-PublicSourceFiles