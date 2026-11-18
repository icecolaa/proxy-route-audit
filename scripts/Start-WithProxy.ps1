#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [uri] $ProxyUri,
    [Parameter(Mandatory)] [string] $Command,
    [switch] $Electron,
    [Parameter(ValueFromRemainingArguments)] [string[]] $ToolArguments
)

$ErrorActionPreference = 'Stop'
if ($ProxyUri.Scheme -ne 'http' -or -not $ProxyUri.IsLoopback -or
    $ProxyUri.UserInfo -or $ProxyUri.PathAndQuery -ne '/' -or $ProxyUri.Fragment) {
    throw 'Specify a local HTTP proxy URI such as http://127.0.0.1:15236.'
}
$client = [Net.Sockets.TcpClient]::new()
try {
    if (-not $client.ConnectAsync($ProxyUri.DnsSafeHost, $ProxyUri.Port).Wait(1500)) {
        throw 'Timed out connecting to the local proxy.'
    }
} catch {
    throw "The local proxy at $($ProxyUri.Authority) is unavailable. Connect it and retry."
} finally {
    $client.Dispose()
}

$tool = Get-Command $Command -CommandType Application,ExternalScript | Select-Object -First 1
$proxy = $ProxyUri.GetLeftPart([UriPartial]::Authority)
if ($Electron) {
    if ($tool.CommandType -ne 'Application' -or [IO.Path]::GetExtension($tool.Source) -ne '.exe') {
        throw 'Select the Electron application executable.'
    }
    $name = [IO.Path]::GetFileNameWithoutExtension($tool.Source)
    if (Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object Path -eq $tool.Source) {
        throw 'Close the running Electron application before starting it with proxy settings.'
    }
    $ToolArguments = @("--proxy-server=$proxy", '--disable-quic') + $ToolArguments
}

$variables = @{
    HTTP_PROXY = $proxy; HTTPS_PROXY = $proxy; ALL_PROXY = $proxy; GRPC_PROXY = $proxy
    NO_PROXY = 'localhost,127.0.0.1,::1'; NO_GRPC_PROXY = 'localhost,127.0.0.1,::1'
    NODE_USE_ENV_PROXY = '1'
}
$previous = @{}
try {
    foreach ($name in $variables.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $variables[$name], 'Process')
    }
    & $tool @ToolArguments
    $toolExitCode = $LASTEXITCODE
} finally {
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
}
if ($null -ne $toolExitCode) { exit $toolExitCode }
