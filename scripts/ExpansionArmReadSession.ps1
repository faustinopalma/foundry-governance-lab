function Assert-ExpansionArmReadUrl([hashtable]$State, [string]$Url) {
    $prefix='https://management.azure.com/subscriptions/'+$State.subscriptionId+'/'
    if ($Url -inotmatch ('^'+[regex]::Escape($prefix)+'[a-zA-Z0-9_./@()-]+\?api-version=[0-9]{4}-[0-9]{2}-[0-9]{2}(-preview)?$') -or $Url.Contains('/../') -or $Url.Contains('/./') -or $Url.Contains('//subscriptions')) { throw 'Only bound subscription ARM GET URLs are accepted' }
}

function New-ExpansionArmReadSession([hashtable]$State) {
    $application=@(Get-Command az -CommandType Application -ErrorAction Stop)[0].Source
    $arguments=@()
    if ([IO.Path]::GetExtension($application) -ieq '.cmd') {
        $application=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($application)) '../python.exe'))
        $arguments=@('-IBm','azure.cli')
    }
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$application
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.RedirectStandardInput=$true
    $info.Environment['AZURE_CONFIG_DIR']=$State.azureConfigDirectory
    $info.Environment['AZURE_CORE_COLLECT_TELEMETRY']='false'
    foreach ($argument in ($arguments+@('account','get-access-token','--resource','https://management.azure.com/','--subscription',$State.subscriptionId,'--output','json','--only-show-errors'))) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$info
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw 'ARM token process could not start' }
        $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill($true); $null=$process.WaitForExit(5000); throw 'ARM token acquisition exceeded 60 seconds' }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),5000)) { throw 'ARM token stream deadline exceeded' }
        if ($process.ExitCode -ne 0) { throw 'Existing isolated CLI authentication failed; no automatic login attempted' }
        $token=$stdout.Result | ConvertFrom-Json -AsHashtable -Depth 10
        if ($token.tenant -ine $State.tenantId -or $token.subscription -ine $State.subscriptionId -or $token.tokenType -ine 'Bearer' -or [string]::IsNullOrWhiteSpace($token.accessToken)) { throw 'ARM token context mismatch' }
        $expires=[DateTimeOffset]::FromUnixTimeSeconds([long]$token.expires_on)
        if ($expires -lt [DateTimeOffset]::UtcNow.AddMinutes(2)) { throw 'ARM token has insufficient remaining validity' }
        $handler=[Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect=$false
        $handler.UseCookies=$false
        $client=[Net.Http.HttpClient]::new($handler,$true)
        $client.Timeout=[TimeSpan]::FromSeconds(60)
        $client.MaxResponseContentBufferSize=32MB
        return @{client=$client;token=$token.accessToken;expires=$expires;subscription=$State.subscriptionId;tenant=$State.tenantId;count=0;seconds=0.0}
    } finally {
        $token=$null; $stdout=$null; $stderr=$null
        $process.Dispose()
        Write-Host "ARM authentication elapsed: $([math]::Round($clock.Elapsed.TotalSeconds,2))s"
    }
}

function Invoke-ExpansionArmRead([hashtable]$Session, [hashtable]$State, [string]$Url) {
    Assert-ExpansionArmReadUrl $State $Url
    if ($Session.subscription -ine $State.subscriptionId -or $Session.tenant -ine $State.tenantId -or $Session.expires -lt [DateTimeOffset]::UtcNow.AddSeconds(65)) { throw 'ARM read session context or validity changed' }
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Url)
    $request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Session.token)
    $request.Headers.Accept.ParseAdd('application/json')
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $response=$null
    $record=@{method='GET';url=$Url;startedAt=[DateTimeOffset]::UtcNow.ToString('o');success=$false}
    $stem=Assert-ExternalLabPath (Join-Path $State.evidenceDirectory ('arm-read-'+[guid]::NewGuid().ToString('N')))
    try {
        $response=$Session.client.SendAsync($request).GetAwaiter().GetResult()
        $record.status=[int]$response.StatusCode
        $text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        [IO.File]::WriteAllText("$stem.response.json",$text,[Text.UTF8Encoding]::new($false))
        if (-not $response.IsSuccessStatusCode) { throw "ARM read returned HTTP $($record.status); private response: $stem.response.json" }
        $result=Read-FoundationJson "$stem.response.json"
        $record.success=$true
        return $result
    } finally {
        $record.elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,3)
        $Session.count++
        $Session.seconds+=$clock.Elapsed.TotalSeconds
        [IO.File]::WriteAllText("$stem.receipt.json",($record | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        if ($response) { $response.Dispose() }
        $request.Dispose()
        Write-Host "ARM GET $($Session.count) elapsed: $($record.elapsedSeconds)s"
    }
}

function Close-ExpansionArmReadSession([hashtable]$Session) {
    if ($Session) {
        $Session.client.Dispose()
        $Session.token=$null
        Write-Host "ARM read session: $($Session.count) fresh requests, $([math]::Round($Session.seconds,2))s HTTP time"
    }
}