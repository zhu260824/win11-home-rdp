# 断开 RDP 后物理显示器黑屏

## 现象

用了几天远程桌面后出现：关闭 RDP 连接、隔一夜再回到机器前，接 HDMI 的显示器黑屏无信号，
插拔几次线才恢复。

## 原因

客户端 SKU 的 RDP 会话与物理控制台是**两个独立会话**。断开连接后：

```
services          0   Disconnected
RDP-Tcp#0         1   Disconnected   ← 你的桌面还在这里，被保留以便重连
Console           2   Connected      ← 物理控制台，停在登录界面
RDP-Tcp       65536   Listen
```

会话 1 保留在"已断开"状态，而物理控制台是会话 2。
**没有任何东西把会话 1 重新接到物理显示输出上**，所以显示器没有内容可显示。
插拔 HDMI 会产生显示配置变更事件，触发控制台重新接管，这就是"插拔几下就好了"的原因。

> 这不是显示器、线材或显卡故障。本项目作者的机器上 `VIDEOIDLE` 与 `STANDBYIDLE`
> 均已设为"从不"，排除了节能熄屏的可能，事件日志里也没有显卡错误或睡眠事件。

## 解决

核心命令只有一条：

```cmd
tscon <会话ID> /dest:console
```

把指定会话连到 console，画面立刻回到物理显示器。

### 1. 先把被精简掉的工具补回来

不少精简版镜像删除了 `System32\tscon.exe`、`quser.exe`、`qwinsta.exe` 等，
但 `WinSxS` 里的组件副本通常还在（System32 下这些文件本质是指向 WinSxS 的硬链接）。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Restore-SessionTools.ps1 -DryRun   # 先看会做什么
powershell -ExecutionPolicy Bypass -File .\scripts\Restore-SessionTools.ps1           # 实际恢复
```

恢复 `tscon` / `tsdiscon` / `tskill` / `query` / `quser` / `qwinsta`，已存在的不覆盖。
只枚举 WinSxS 顶层组件目录（不做整库递归，否则要扫几十万文件）。

### 2. 手动交还

```powershell
# 断开前执行，立即把画面交还物理屏
powershell -ExecutionPolicy Bypass -File .\scripts\Send-SessionToConsole.ps1

# 只看会话
powershell -ExecutionPolicy Bypass -File .\scripts\Send-SessionToConsole.ps1 -List
```

### 3. 自动交还（推荐）

注册计划任务，在 RDP 断开事件后自动交还：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-ConsoleHandoffTask.ps1
```

- **触发**：`Microsoft-Windows-TerminalServices-LocalSessionManager/Operational` 事件 ID **24**（会话断开）
- **延迟**：45 秒，给短暂掉线重连留余地；重连成功则会话不再是断开态，脚本自动跳过
- **身份**：`SYSTEM`（任务计划器要求）
- **动作**：`Send-SessionToConsole.ps1 -Auto`

卸载：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-ConsoleHandoffTask.ps1 -Uninstall
```

## 实现要点（踩过的坑）

### 判定条件不能依赖会话名和用户名

`Send-SessionToConsole.ps1 -Auto` 第一版要求「会话名以 RDP 开头」且「用户名非空」，
结果一次都没命中。日志显示断开态下这两个字段都是空的：

```
交还会话 1 (, Disconnected, 用户=ZL) -> console
              ↑ 会话名为空
```

稳定可用的判定只有两条：

```powershell
$_.State -eq 4 -and $_.Id -ne 0
```

即「状态 = 已断开」且「不是 0 号会话」——0 号 Services 会话天然是断开态，必须排除。

### WTS API 必须声明 Unicode

用 P/Invoke 枚举会话时，`WTSEnumerateSessions` 不声明 `CharSet.Unicode` 会绑定到 ANSI 版本，
拿到的会话名会被当作 UTF-16 读取，变成一堆乱码（`敓癲捩獥` 这种），
后续按名称匹配全部失效。

```csharp
[DllImport("wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool WTSEnumerateSessions(...);
```

### 不要整库递归 WinSxS

`Get-ChildItem C:\Windows\WinSxS -Recurse` 要扫几十万文件，在提权窗口里会卡到看起来像"闪退"。
改成只枚举顶层目录名匹配 `*commandlinetool*` 的组件，秒级完成。

## 验证方法

断开 RDP，等约 1 分钟，观察事件日志：

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -MaxEvents 10 |
  Where-Object Id -in 24,25
```

成功时依次出现：

```
[断开] 会话 1 已断开连接，原因代码为 5
[45s后] tscon 执行，脚本日志记录 "交还会话 1 ... -> console / 成功"
[随即] 事件 25：会话 1 重新连接，源网络地址：本地     ← 会话已回到控制台
```

之后重连 RDP，会看到控制台再次被抢回（这是预期行为，不是故障）。

## 附：临时应急

如果脚本还没装好，遇到黑屏可以在物理机前试：

1. `Win + Ctrl + Shift + B` — 重启显卡驱动
2. `Ctrl + Alt + Del` — 触发控制台重绘
3. `Win + L` — 锁屏再解锁，强制会话仲裁

这三招都比重插 HDMI 快，且不需要动线材。
