# 故障排查

先跑一遍诊断，它会把该看的都收集起来：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Get-RdpDiagnostics.ps1
```

报告写到 `rdp-diagnostics.txt`。

## 版本对不上

最容易踩的坑：`termsrv.dll` 的**文件属性版本**与**补丁实际查表的版本**不一致。

```
文件属性 FileVersion          : 10.0.26100.9949
RDPWInst 报的 Terminal Services version : 10.0.26100.9549   ← 以这个为准
```

判断该用哪个偏移段，永远看 `RDPWInst -i` 的输出。用 `FileVersion` 去查表会得出「不支持」的错误结论。

## 装了但没有生效

### 症状：`RDPWInst -i` 打印 `This version of Terminal Services is not supported`

配置表里没有这个 build 的段。先确认上游是否已更新：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Check-RdpWrapSupport.ps1
```

没有就自己取偏移：[OFFSET-FINDING.md](OFFSET-FINDING.md)。

### 症状：3389 在监听，但连接被立即断开

`rdpwrap.dll` 可能没被加载，或加载了但 patch 没打上。检查：

```powershell
# 1. ServiceDll 是否指向 wrapper
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters' -Name ServiceDll).ServiceDll

# 2. wrapper 是否真的在服务进程里
$p = (Get-CimInstance Win32_Service -Filter "Name='TermService'").ProcessId
(Get-Process -Id $p).Modules | Where-Object { $_.ModuleName -like 'rdpwrap*' }
```

第 1 项对、第 2 项空，通常是 TermService 没重启，或 DLL 被安全软件删了。

## 连接走到凭据框但登录失败

看安全日志里的 4625 事件，`SubStatus` 直接给出原因：

| SubStatus | 含义 | 处置 |
|---|---|---|
| `0xC0000064` | 用户名不存在 | 检查是否用了别的机器的账户名 |
| `0xC000006A` | 密码错误 | 注意 `DOMAIN\user` 前缀是否指向了错误的主机 |
| `0xC000006E` | 该账户不允许这种登录类型 | 见下面「权限」 |
| `0xC000015B` | 缺少「允许通过远程桌面服务登录」权限 | 见下面「权限」 |
| `0xC0000413` | 被空密码策略拦截 | 给账户设密码，或 `LimitBlankPasswordUse=0`（不推荐） |
| `0xC0000234` | 账户已锁定 | 等锁定时长结束（默认 10 分钟）；已登录的会话不受影响 |

### 权限

管理员账户默认拥有远程登录权限。**标准用户**需要被授予「允许通过远程桌面服务登录」，否则报 `0xC000015B`。

部分精简系统镜像里 `Remote Desktop Users` 组（SID `S-1-5-32-555`）根本不存在，表现为 `net localgroup` 报 `System error 1376`。这种情况下不要按组授权，直接给用户授予权利：

```powershell
# 用 secedit 或本地安全策略（secpol.msc）授予 SeRemoteInteractiveLogonRight
```

### 账户锁定

客户端反复重试会累计失败次数。客户端 SKU 默认 **10 次 / 10 分钟**：

```powershell
net accounts          # 查看 Lockout threshold
```

注意：**改锁定策略会立即重新评估**已累计的失败次数。把阈值临时调高再调回，可能让计数已超阈值的账户立刻被锁。安全做法是等观察窗口（默认 10 分钟）过去，计数自然清零。

## 连上后本地被锁屏

这是**预期行为**，不是 bug。客户端 SKU 的 RDP 是单会话：远程接管桌面时，本地会话被锁。

想多人同时在线需要多会话补丁生效（`bAppServerAllowed` + `lMaxUserSessions`），在不同版本上可用性不一致，且不受官方支持。

## NLA 相关

脚本默认关闭 NLA（`UserAuthentication=0`）以兼容更多客户端。若你的客户端都支持 NLA（现代 Windows、Windows App、Remmina 新版本），建议打开：

```powershell
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
  -Name UserAuthentication -Value 1 -Type DWord
Restart-Service TermService -Force
```

## 安全软件删掉 rdpwrap.dll

`rdpwrap.dll` 属于「注入型」补丁，常被误报。安装脚本会添加安装目录的排除项；如果仍然被删：

```powershell
Add-MpPreference -ExclusionPath "$env:ProgramFiles\RDP Wrapper"
```

## 系统更新后失效

这是常态。特征：`3389` 仍在监听但没有补丁效果，`RDPWInst -i` 报版本不支持。

处置流程：

1. `Check-RdpWrapSupport.ps1` 看上游有没有新段；
2. 没有就按 [OFFSET-FINDING.md](OFFSET-FINDING.md) 自己取；
3. 重新安装（脚本会重新部署 ini 并重启服务）。

如果这台机器承担关键用途，考虑换掉这条路线——见 README 开头的说明。

## 卸载没干净

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-RdpWrap.ps1 -Uninstall
```

该命令把 `ServiceDll` 还原为默认值、删除防火墙规则和 Defender 排除项。彻底清理还要：

```powershell
Remove-Item "$env:ProgramFiles\RDP Wrapper" -Recurse -Force
Restart-Service TermService -Force
```

`rdpwrap.dll` 在服务重启前仍被进程占用，删目录前先停服务或重启系统。
