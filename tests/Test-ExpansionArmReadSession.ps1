$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../scripts/Invoke-ExpansionHosts.ps1') -DefinitionsOnly
. (Join-Path $PSScriptRoot '../scripts/ExpansionArmReadSession.ps1')
$checks=0
function Check([bool]$Condition) { if (-not $Condition) { throw "ARM read session assertion failed after $script:checks checks" }; $script:checks++ }
function Reject([scriptblock]$Probe) { $failed=$false; try { & $Probe } catch { $failed=$true }; Check $failed }
$state=@{subscriptionId='11111111-1111-4111-8111-111111111111';tenantId='22222222-2222-4222-8222-222222222222'}
$url="https://management.azure.com/subscriptions/$($state.subscriptionId)/resourceGroups/rg-fgl-sample01-case-a/providers/Microsoft.CognitiveServices/accounts/sample/capabilityHosts/sample@aml_aiagentservice?api-version=2026-05-01"
Assert-ExpansionArmReadUrl $state $url; Check $true
foreach ($bad in @($url.Replace('https:','http:'),$url.Replace('management.azure.com','example.org'),$url.Replace($state.subscriptionId,$state.tenantId),$url.Replace('/resourceGroups/','/../resourceGroups/'),$url.Replace('/resourceGroups/','/%2e%2e/resourceGroups/'),($url+'&extra=true'),($url+'#fragment'),$url.Replace('2026-05-01','invalid'),$url.Replace('azure.com/','azure.com:443/'))) { Reject { Assert-ExpansionArmReadUrl $state $bad } }
$root=Assert-ExternalLabPath (Join-Path ([IO.Path]::GetTempPath()) ('arm-read-tests-'+[guid]::NewGuid().ToString('N')))
$null=[IO.Directory]::CreateDirectory($root)
$state.evidenceDirectory=$root
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class ExpansionArmFixtureHandler : HttpMessageHandler {
    public int Calls;
    public int Status = 200;
    public string Body = "{\"value\":[],\"properties\":{\"provisioningState\":\"Succeeded\"}}";
    public bool ValidRequest;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Calls++;
        ValidRequest = request.Method == HttpMethod.Get && request.Headers.Authorization.Scheme == "Bearer" && request.Headers.Authorization.Parameter == "synthetic-token";
        return Task.FromResult(new HttpResponseMessage((HttpStatusCode)Status) { Content = new StringContent(Body) });
    }
}
'@
$handler=[ExpansionArmFixtureHandler]::new()
$session=@{client=[Net.Http.HttpClient]::new($handler);token='synthetic-token';expires=[DateTimeOffset]::UtcNow.AddHours(1);subscription=$state.subscriptionId;tenant=$state.tenantId;count=0;seconds=0.0}
try {
    $first=Invoke-ExpansionArmRead $session $state $url
    $second=Invoke-ExpansionArmRead $session $state $url
    Check ($handler.Calls -eq 2 -and $handler.ValidRequest -and $session.count -eq 2)
    Check ($first.properties.provisioningState -ceq 'Succeeded' -and $second.value.Count -eq 0)
    foreach ($status in @(301,401,403,404,429,500)) { $handler.Status=$status; Reject { Invoke-ExpansionArmRead $session $state $url }; Check ($handler.Calls -eq $session.count) }
    $handler.Status=200; $handler.Body='not-json'; Reject { Invoke-ExpansionArmRead $session $state $url }
    $before=$handler.Calls
    $session.expires=[DateTimeOffset]::UtcNow; Reject { Invoke-ExpansionArmRead $session $state $url }
    $session.expires=[DateTimeOffset]::UtcNow.AddHours(1); $session.tenant=$state.subscriptionId; Reject { Invoke-ExpansionArmRead $session $state $url }
    Check ($handler.Calls -eq $before)
    $files=@(Get-ChildItem $root -File)
    Check ($files.Count -eq 18)
    foreach ($file in $files) { Check (-not ([IO.File]::ReadAllText($file.FullName).Contains('synthetic-token'))) }
} finally { Close-ExpansionArmReadSession $session; Remove-Item $root -Recurse -Force }
Check ($null -eq $session.token)
Write-Output "PASS: $checks ARM read transport checks; repeated reads remain fresh, errors fail closed, tokens are not persisted"