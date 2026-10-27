# 变更记录

## v1.0.0 — 2026-10-27

首次发布。在 Windows 11 家庭版（26H2 / `26300.9711`）上启用原生 RDP 服务端，
并在作者本机验证可用（远程登录正常）。

### 内容

- **`scripts/Install-RdpWrap.ps1`** — 安装 / 预检 / 自动回滚 / 卸载
  - `-Preflight` 只读检查，不改任何东西
  - 失败时自动把 `TermService` 的 `ServiceDll` 还原
  - 安装后校验 `rdpwrap.dll` 是否真的加载进服务进程
- **`scripts/Check-RdpWrapSupport.ps1`** — 查当前 `termsrv.dll` 是否被偏移表覆盖
- **`scripts/Get-RdpDiagnostics.ps1`** — 收集状态并把失败登录的 `SubStatus` 译成原因
- **`offsets/10.0.26100.9949.ini`** — 该 build 的偏移段（上游尚未收录）
- **`tools/verify-offsets.py`** — 解析 PE，校验补丁点与 `SLInit` 全局地址
- **`docs/`** — 原理、偏移定位、故障排查

### 已知限制

- 偏移与 `termsrv.dll` 的构建严格绑定，**每次累积更新都可能失效**
- 单会话：远程连入会把本地会话挤到锁屏
- 非官方支持路径，不建议用于无法承担故障的机器
- 安装脚本是验证过程的整理版本；偏移数据与机制在作者机器上实测通过

### 注意

`termsrv.dll` 的 `FileVersion` 可能是 `10.0.26100.9949`，而 `RDPWInst` 报
`Terminal Services version: 10.0.26100.9549`。**判断该用哪个偏移段以 RDPWInst
输出为准**，不要看文件属性。
