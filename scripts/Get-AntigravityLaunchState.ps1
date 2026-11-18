#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This inspection requires Windows.' }

$shell = New-Object -ComObject WScript.Shell
$locations = [ordered]@{
    Desktop = [Environment]::GetFolderPath('DesktopDirectory')
    PublicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    StartMenu = [Environment]::GetFolderPath('Programs')
    CommonStartMenu = [Environment]::GetFolderPath('CommonPrograms')
    Taskbar = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
}

$shortcuts = @(foreach ($location in $locations.Keys) {
    $folder = $locations[$location]
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
    $recurse = $location -in 'StartMenu','CommonStartMenu'
    foreach ($file in (Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -File -Recurse:$recurse)) {
        $link = $shell.CreateShortcut($file.FullName)
        if ($file.BaseName -notmatch 'Antigravity' -and
            $link.TargetPath -notmatch 'Antigravity\.exe$' -and
            $link.Arguments -notmatch '(?:Antigravity\.exe|Start-Antigravity-Proxy\.ps1)') { continue }
        [pscustomobject]@{
            Location = $location
            Path = $file.FullName
            Target = $link.TargetPath
            KnownProxyLauncher = $link.Arguments -match '(?:Start-Antigravity-Proxy|Start-WithProxy)\.ps1'
            BrowserProxyFlag = $link.Arguments -match '(?:^|\s)--proxy-server(?:=|\s)'
        }
    }
})

$sessionId = (Get-Process -Id $PID).SessionId
$app = Get-CimInstance Win32_Process -Filter "SessionId=$sessionId AND (Name='Antigravity.exe' OR Name='language_server.exe')"
$processes = @($app | ForEach-Object {
    [pscustomobject]@{
        Name = $_.Name
        PID = $_.ProcessId
        ParentPID = $_.ParentProcessId
        ImportHelper = $_.Name -eq 'Antigravity.exe' -and $_.CommandLine -match '(?:^|\s)--import(?:\s|=|$)'
        BrowserProxyFlag = $_.CommandLine -match '(?:^|\s)--proxy-server(?:=|\s)'
    }
})

[pscustomobject]@{ Shortcuts = $shortcuts; Processes = $processes } | ConvertTo-Json -Depth 4
