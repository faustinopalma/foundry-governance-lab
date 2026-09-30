[CmdletBinding()]
param([Parameter(Mandatory)][string]$CompiledTemplatePath)

$timer = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
try {
    $template = Get-Content -LiteralPath $CompiledTemplatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $checks = 0
    function Check([bool]$Condition) {
        if (-not $Condition) { throw 'Expansion project template assertion failed' }
        $script:checks++
    }
    function Assert-ProjectTemplate([hashtable]$Document) {
        $resources = @($Document.resources)
        if ($resources.Count -ne 1) { throw 'Only the new project resource loop is allowed' }
        $project = $resources[0]
        if ($project.type -cne 'Microsoft.CognitiveServices/accounts/projects' -or $project.apiVersion -cne '2026-05-01') { throw 'Unexpected resource type or API' }
        if ($project.name -cne "[format('{0}/{1}', parameters('accountName'), format('case-{0}-{1}', parameters('caseId'), variables('environments')[copyIndex()]))]") { throw 'Unexpected project naming' }
        if ($Document.variables.environments -cne "[if(equals(parameters('caseId'), 'a'), createArray('test'), createArray('dev', 'test'))]") { throw 'Expansion must preserve case A dev and add both case B projects' }
        if ($project.copy.count -cne "[length(variables('environments'))]" -or $project.copy.name -cne 'projects') { throw 'Unexpected project loop' }
        if ($project.identity.type -cne 'SystemAssigned' -or $project.identity.Count -ne 1) { throw 'Unexpected project identity' }
        if ($project.location -cne "[parameters('location')]") { throw 'Unexpected project location' }
        if (@(Compare-Object @('a','b') @($Document.parameters.caseId.allowedValues)).Count -or @($Document.parameters.caseId.allowedValues).Count -ne 2) { throw 'Unexpected case choices' }
        if (@($Document.parameters.location.allowedValues).Count -ne 1 -or $Document.parameters.location.allowedValues[0] -cne 'swedencentral') { throw 'Unexpected region choices' }
        if ($project.tags -cne "[variables('tags')]" -or $Document.variables.tags['fgl-owner'] -cne "[parameters('ownershipId')]" -or $Document.variables.tags['fgl-lab'] -cne "[parameters('labId')]") { throw 'Ownership tags missing' }
        if ($Document.ContainsKey('outputs') -and @($Document.outputs.Keys).Count -ne 1) { throw 'Unexpected outputs' }
        if ($Document.outputs.projects.type -cne 'array') { throw 'Project inventory output missing' }
    }
    Assert-ProjectTemplate $template
    Check $true
    foreach ($mutation in @(
        { param($value) $value.resources += @{type='Microsoft.CognitiveServices/accounts';name='retained'} },
        { param($value) $value.resources += @{type='Microsoft.CognitiveServices/accounts/projects/capabilityHosts';name='retained/agents'} },
        { param($value) $value.resources[0].type='Microsoft.Authorization/roleAssignments' },
        { param($value) $value.variables.environments="[createArray('dev', 'test')]" },
        { param($value) $value.variables.environments="[if(equals(parameters('caseId'), 'a'), createArray('dev'), createArray('dev', 'test'))]" },
        { param($value) $value.resources[0].name="[format('{0}/case-a-dev', parameters('accountName'))]" },
        { param($value) $value.resources[0].copy.count=0 },
        { param($value) $value.resources[0].identity.type='None' },
        { param($value) $value.resources[0].identity.userAssignedIdentities=@{} },
        { param($value) $value.parameters.caseId.allowedValues += 'c' },
        { param($value) $value.parameters.location.allowedValues += 'eastus' },
        { param($value) $value.variables.tags['fgl-owner']='foreign' },
        { param($value) $value.resources[0].location='eastus' },
        { param($value) $value.resources=@() },
        { param($value) $value.outputs.projects.type='string' }
    )) {
        $altered = $template | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
        & $mutation $altered
        $rejected = $false
        try { Assert-ProjectTemplate $altered } catch { $rejected = $true }
        Check $rejected
    }
    Write-Output "PASS: $checks expansion project structural checks, including 15 deliberately broken templates; no Azure calls"
} finally {
    Write-Output "elapsed: $([math]::Round($timer.Elapsed.TotalSeconds,1))s"
}