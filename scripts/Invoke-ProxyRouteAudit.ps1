#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [uri] $ProxyUri,
    [Parameter(Mandatory)] [ValidateSet('global','rule','smart','unknown')] [string] $Mode,
    [ipaddress] $ExpectedEgress,
    [string[]] $ProcessName = @('Antigravity', 'language_server', 'agy'),
    [ValidateRange(1,120)] [int] $SampleSeconds = 12,
    [string] $OutputDirectory = (Join-Path (Get-Location) 'proxy-audit')
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This audit requires Windows.' }
if ($ProxyUri.Scheme -ne 'http' -or -not $ProxyUri.IsLoopback -or
    $ProxyUri.UserInfo -or $ProxyUri.PathAndQuery -ne '/' -or $ProxyUri.Fragment) {
    throw 'Specify a local HTTP proxy URI such as http://127.0.0.1:15236.'
}

$run = Join-Path $OutputDirectory ("{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $Mode)
New-Item -ItemType Directory -Path $run -Force | Out-Null
$registryKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
& reg.exe export $registryKey (Join-Path $run 'WinINET.reg') /y | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'WinINET backup failed.' }
$network = [ordered]@{
    Routes = @(Get-NetRoute | Select-Object InterfaceAlias,DestinationPrefix,NextHop,RouteMetric,PolicyStore)
    DNS = @(Get-DnsClientServerAddress | Select-Object InterfaceAlias,AddressFamily,ServerAddresses)
    WinHTTP = @(& netsh.exe winhttp dump)
}
if ($LASTEXITCODE -ne 0) { throw 'WinHTTP backup failed.' }
$network | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $run 'network.json')

$targets = [ordered]@{
    Ipify = 'https://api.ipify.org'
    AWS = 'https://checkip.amazonaws.com'
    OAuth = 'https://oauth2.googleapis.com/token'
    Accounts = 'https://accounts.google.com/.well-known/openid-configuration'
    Antigravity = 'https://antigravity.googleapis.com/'
    LoadCodeAssist = 'https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist'
    CloudCode = 'https://cloudcode-pa.googleapis.com/'
    Gemini = 'https://generativelanguage.googleapis.com/'
}
$job = Start-ThreadJob -ArgumentList $targets, $ProxyUri.AbsoluteUri -ScriptBlock {
    param($urls,$proxy)
    foreach ($name in $urls.Keys) {
        $isIpProbe = $name -in 'Ipify','AWS'
        $options = @('--disable','--noproxy','','--proxy',$proxy,'--max-time','6','--silent')
        if (-not $isIpProbe) { $options += @('--output','NUL') }
        if ($name -eq 'OAuth') { $options += @('--request','POST','--header','Content-Length: 0') }
        if ($name -eq 'LoadCodeAssist') { $options += @('--header','Content-Type: application/json','--data','{}') }
        $response = & curl.exe @options --write-out '\n%{http_code} %{http_connect}' $urls[$name]
        $exitCode = $LASTEXITCODE
        $status = ([string]($response | Select-Object -Last 1)).Trim() -split '\s+'
        $address = $null
        if ($isIpProbe -and $exitCode -eq 0 -and $status[0] -eq '200') {
            $ip = $null
            if ([ipaddress]::TryParse(([string]($response | Select-Object -First 1)).Trim(), [ref]$ip)) {
                $address = $ip.IPAddressToString
            }
        }
        [pscustomobject]@{
            Name = $name; Destination = $urls[$name]; HTTP = $status[0]
            CONNECT = $status[1]; CurlExit = $exitCode; Egress = $address
        }
    }
}

$seen = @{}
$nonLoopbackTcp = @{}
$udpEndpoints = @{}
try {
    $deadline = (Get-Date).AddSeconds($SampleSeconds)
    do {
        $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
        $active = @{}
        foreach ($process in $processes) {
            $active[[int]$process.Id] = $process.ProcessName
            $seen[[int]$process.Id] = $process.ProcessName
        }
        foreach ($line in (& netstat.exe -ano)) {
            if ($line -match '^\s*(TCP|UDP)\s+(\S+)\s+(\S+)(?:\s+(\S+))?\s+(\d+)\s*$' -and
                $active.ContainsKey([int]$Matches[5])) {
                $protocol, $local, $remote, $state, $pidValue = $Matches[1..5]
                [pscustomobject]@{
                    Time = (Get-Date).ToString('o')
                    Protocol = $protocol; PID = [int]$pidValue; Process = $active[[int]$pidValue]
                    Local = $local; Remote = $remote; State = $state
                } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $run 'sockets.jsonl')
                $ownerName = $active[[int]$pidValue]
                if ($protocol -eq 'UDP') {
                    $udpEndpoints["$ownerName $pidValue $local"] = $true
                } else {
                    $remoteIp = $null
                    $remoteHost = ($remote -replace ':\d+$', '').Trim('[',']')
                    if ([ipaddress]::TryParse($remoteHost, [ref]$remoteIp)) {
                        if ($remoteIp.IsIPv4MappedToIPv6) { $remoteIp = $remoteIp.MapToIPv4() }
                        if (-not [ipaddress]::IsLoopback($remoteIp) -and $remoteIp -notin [ipaddress]::Any,[ipaddress]::IPv6Any) {
                            $nonLoopbackTcp["$ownerName $pidValue $remote $state"] = $true
                        }
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    $checks = @(Receive-Job -Job $job -Wait -ErrorAction Stop)
} finally {
    Remove-Job -Job $job -Force
}

$observed = @($checks | Where-Object Egress | ForEach-Object Egress | Sort-Object -Unique)
$ipProbeCount = @($checks | Where-Object Egress).Count
$baseline = if ($observed.Count -gt 1) { 'different-egress-observed' }
    elseif ($ExpectedEgress -and $observed.Count -and $observed[0] -ne $ExpectedEgress.IPAddressToString) { 'mismatch' }
    elseif ($ipProbeCount -lt 2) { 'incomplete-probes' }
    elseif ($ExpectedEgress) { 'matched' }
    else { 'no-baseline' }
$report = [ordered]@{
    Time = (Get-Date).ToString('o'); Mode = $Mode; Proxy = $ProxyUri.AbsoluteUri
    ExpectedEgress = $ExpectedEgress.IPAddressToString; ObservedEgress = $observed; Baseline = $baseline
    ProcessCount = $seen.Count
    NonLoopbackTcp = @($nonLoopbackTcp.Keys | Sort-Object)
    UdpLocalEndpoints = @($udpEndpoints.Keys | Sort-Object)
    Probes = $checks | Select-Object Name,Destination,HTTP,CONNECT,CurlExit,Egress
}
$report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $run 'report.json')
Get-Content -LiteralPath (Join-Path $run 'report.json')
Write-Host "Audit files: $run"
