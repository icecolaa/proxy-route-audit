---
name: proxy-route-audit
description: Audit Windows proxy routing for Antigravity, its language server, and related CLI tools. Use for 代理巡检, OAuth 超时, IPv4/IPv6 直连, 智能与全局模式对比, or unexpected public egress IP changes.
metadata:
  skillhub:
    slug: icecolaa-proxy-route-audit
    version: 1.0.1
    displayName: Windows 代理线路巡检
    summary: 备份 Windows 网络状态，核对 Antigravity、CLI 与代理出口。
    tags: [windows, proxy, networking, antigravity]
---

# Windows 代理线路巡检

1. 从 WinINET、监听端口所属进程和代理界面确认当前软件、HTTP 监听地址、模式和线路。记录用户预期的公网出口 IP。首次验收时，从已确认选中的线路测得出口，经用户确认后作为后续基线。Veee 常用回环 HTTP 端口为 15236，现场核对端口与进程。
2. 用 PowerShell 7 运行 [巡检脚本](scripts/Invoke-ProxyRouteAudit.ps1)。每次调用先导出 WinINET、WinHTTP、DNS 和路由快照，再执行显式代理探测和进程连接采样。将输出放在本地非发布目录。代理配置可能含订阅、口令和令牌。涉及变更时，先额外备份相关客户端配置、应用设置、启动入口及待改的环境变量，记录原值和恢复方式。

   ```powershell
   pwsh -NoProfile -File ./scripts/Invoke-ProxyRouteAudit.ps1 -ProxyUri http://127.0.0.1:15236 -Mode global -ExpectedEgress <已确认的IP> -OutputDirectory ./work/audit
   ```

3. 在采样期间触发 Antigravity 的正常请求。将实际 CLI 可执行文件名加入 `-ProcessName`；通用运行时按 PID、父子关系和请求时间核对，避免把其他程序的 Node 或 Python 流量算进去。对全局和智能或规则模式分别采样，保持同一线路，完成后恢复原模式。登记实测模式、线路名、两种模式的出口与命中基线情况、TCP 非回环目的地、UDP 观察和 OAuth 状态。
4. 诊断时区分应用到回环代理、代理的中继连接、公开回显站看到的出口。Windows 系统代理和代理软件的全局模式覆盖范围取决于客户端和代理机制。回环 TCP、双栈路由和 UDP 端点快照均有观测局限。OAuth 空 POST 返回 HTTP 400 且 CONNECT 200 说明端点可达。登录后出现 `Error Loading Models` 时，核对 `daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`。未带凭据的请求返回 HTTP 401 且 CONNECT 200 说明该接口经代理可达，模型可用性以客户端实际加载为准。
5. 如果需要修复且用户已授权，优先在受影响的应用与 CLI 启动入口设置显式 HTTP 代理。可用 [作用域启动器](scripts/Start-WithProxy.ps1) 设置子进程环境，Antigravity 入口可使用 `-Electron` 指定代理并关闭 QUIC。完整关闭旧实例后再启动，对比前后的真实连接。应用和工具可能忽略环境变量，自带网络栈、OAuth 浏览器、DNS 和 UDP 需要单独核验。强制防直连需要适用的 TUN 或出站策略以及断开代理后的验证。中继 IP 与公网出口分开记录，跨重连固定出口需要线路提供方支持并重复实测。

定期巡检可重复运行同一条命令，带上先前确认的 `-ExpectedEgress`。按模式保留各次报告，报告中的地址、快照和日志留在本机。

如果重开应用后又出现直连，用 [入口检查脚本](scripts/Get-AntigravityLaunchState.ps1) 对照桌面、开始菜单和任务栏的快捷方式，以及当前 Windows 会话里的进程。重点检查实际使用的入口。桌面快捷方式指向裸 EXE 时，即使开始菜单入口已经修复，仍可能启动未继承代理环境的实例。先备份将编辑的快捷方式，再保留原图标和工作目录并改为调用代理启动器。正常关闭应用后，用修好的入口打开，核对新主进程的代理参数、语言服务的 TCP 去向，以及模型选择器是否真能显示模型。`--import` 辅助进程可以保留。

任务栏固定入口可能被 Windows 重建。再次看到它指向裸 EXE 时，从已验证的桌面或开始菜单入口启动，并把任务栏入口单独记录为未通过。
