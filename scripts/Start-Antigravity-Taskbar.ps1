#Requires -Version 5.1
[CmdletBinding()]
param([uri] $ProxyUri = 'http://127.0.0.1:15236')

$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'
$gate = [Threading.Mutex]::new($false, 'Local\AntigravityProxyTaskbar')
$locked = $false
try {
    try { $locked = $gate.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { return }
    if ($ProxyUri.Scheme -ne 'http' -or -not $ProxyUri.IsLoopback -or
        $ProxyUri.UserInfo -or $ProxyUri.PathAndQuery -ne '/' -or $ProxyUri.Fragment) {
        throw 'Choose a local HTTP proxy URI, for example http://127.0.0.1:15236.'
    }
    $proxy = $ProxyUri.GetLeftPart([UriPartial]::Authority)
    $proxyArgument = [regex]::Escape("--proxy-server=$proxy")

    $session = (Get-Process -Id $PID).SessionId
    $running = Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe' AND SessionId=$session" |
        Where-Object {
            $_.ExecutablePath -eq $app -and
            $_.CommandLine -notmatch '(?:^|\s)--(?:import|type)(?:\s|=|$)'
        } | Select-Object -First 1
    if ($running) {
        if ($running.CommandLine -notmatch "(?:^|\s)$proxyArgument(?:\s|$)") {
            throw 'Antigravity is open without its proxy. Close that window, then click Antigravity Proxy again.'
        }
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.AppActivate([int]$running.ProcessId)
        return
    }

    $client = [Net.Sockets.TcpClient]::new()
    try {
        if (-not $client.ConnectAsync($ProxyUri.DnsSafeHost, $ProxyUri.Port).Wait(1800)) { throw 'Timeout' }
    } catch {
        throw "The proxy is unavailable at $($ProxyUri.Authority). Connect it, then click Antigravity Proxy again."
    } finally {
        $client.Dispose()
    }

    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $app
    $start.WorkingDirectory = Split-Path -Parent $app
    $start.Arguments = "--proxy-server=$proxy --disable-quic"
    $start.UseShellExecute = $false
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','GRPC_PROXY') {
        $start.EnvironmentVariables[$name] = $proxy
    }
    $start.EnvironmentVariables['NO_PROXY'] = 'localhost,127.0.0.1,::1'
    $start.EnvironmentVariables['NO_GRPC_PROXY'] = 'localhost,127.0.0.1,::1'
    $start.EnvironmentVariables['NODE_USE_ENV_PROXY'] = '1'
    $process = [Diagnostics.Process]::Start($start)
    $process.Dispose()
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Antigravity Proxy',
        [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning)
} finally {
    if ($locked) { $gate.ReleaseMutex() }
    $gate.Dispose()
}
