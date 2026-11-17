# win11-home-rdp

在 **Windows 11 家庭版**（无 RDP 服务端授权）上启用原生远程桌面服务端，使用 RDP Wrapper + 精确偏移补丁。

> 家庭版被微软从授权层面移除了「被远程桌面连接」的能力：`termsrv.dll` 仍然存在、`TermService` 仍在运行，但 `CDefPolicy::Query` 会对非服务器 SKU 返回「拒绝」。本项目把这个策略检查在内存中改写掉，让 3389 正常接受标准 RDP 连接。

## ⚠️ 先读这一段

| 事项 | 说明 |
|---|---|
| **不是破解授权** | 家庭版与服务端的差异由 SKU 策略决定，本项目只改运行时内存，不修改系统文件、不绕过激活 |
| **脆弱** | 偏移与 `termsrv.dll` 版本严格绑定。**每次 Windows 累积更新都可能失效**，需要重新取偏移 |
| **非生产可用** | 属于非官方支持路径。重要环境请升级专业版或使用第三方方案 |
| **安全** | 默认单会话；**绝不要**把 3389 直接暴露到公网，配合 WireGuard / Tailscale 等组网使用 |
| **杀软** | `rdpwrap.dll` 常被 Defender 误报，安装脚本会添加排除项 |

## 支持范围

已验证：

| 系统 | `termsrv.dll` | 结果 |
|---|---|---|
| Windows 11 家庭中文版 26H2（`26300.9711`） | `10.0.26100.9949` | ✅ 可用（偏移见 `offsets/`） |

未验证但理论上适用：Windows 10 / 11 各家庭版，只要 `offsets/` 或上游配置库中存在对应版本段。

## 快速开始

```powershell
# 1. 预检：只读，不修改任何东西
powershell -ExecutionPolicy Bypass -File .\scripts\Install-RdpWrap.ps1 -Preflight

# 2. 安装（会弹 UAC）
powershell -ExecutionPolicy Bypass -File .\scripts\Install-RdpWrap.ps1

# 3. 卸载 / 还原
powershell -ExecutionPolicy Bypass -File .\scripts\Install-RdpWrap.ps1 -Uninstall
```

连接：

```
mstsc /v:<本机IP>
```

iPad / Android 用 **Windows App**（原 Microsoft Remote Desktop），地址填同一 IP。

**登录账户必须设置了密码。** 空密码账户默认禁止网络登录；本项目的立场是不去放宽这条策略——请为账户设置密码。

## 工作原理（三处内存补丁）

RDP Wrapper 把 `TermService` 的 `ServiceDll` 从 `termsrv.dll` 换成自己的 `rdpwrap.dll`，后者在服务启动时按 ini 中的**文件偏移**改写 `termsrv.dll` 的三处逻辑，并接管策略全局变量：

| 补丁 | 目标 | 作用 |
|---|---|---|
| `SingleUserPatch` | 单会话限制检查 | 允许同一会话被远程接管 |
| `DefPolicyPatch` | `CDefPolicy::Query` | 让 SKU 策略查询返回「允许远程连接」 |
| `SLInitHook` + `SLInitFunc` | `CSLQuery::Initialize` | 接管策略全局变量（`bServerSku`、`bRemoteConnAllowed` 等） |
| `LocalOnlyPatch` | 本地连接限制 | 允许非本机来源连接 |

细节见 [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)。

## 偏移从哪来

**优先用上游配置库** [sebaxakerhtc/rdpwrap.ini](https://github.com/sebaxakerhtc/rdpwrap.ini)，
它维护了数百个版本段，绝大多数情况直接覆盖。只有确认真实缺版本时，才自己生成片段放进
`offsets/`，方法见 [docs/OFFSET-FINDING.md](docs/OFFSET-FINDING.md)。

### 版本号陷阱（本项目踩过）

RDP Wrapper 查表用的是 PE 里的 **`VS_FIXEDFILEINFO`（固定版本）**，
不是文件属性里显示的 `FileVersion` 字符串。Windows 更新可以把固定版本改掉而字符串不变：

```
文件属性 FileVersion    : 10.0.26100.9949    ← 看着没变
固定版本（查表键）      : 10.0.26100.9818    ← 实际变了，补丁失效
```

结果就是 `TermService` 正常、`ServiceDll` 正常，但 **3389 不再监听**。

自己判断时用这个（不依赖补丁工具）：

```bash
python tools/verify-offsets.py --version
```

## 系统更新后 RDP 失效？

典型症状：3389 不监听，`TermService` 却在运行。一条命令修复：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Repair-RdpWrapper.ps1
```

它会读固定版本 → 下载上游配置库（含镜像回退）→ 检查覆盖 → 备份 → 部署 →
重启服务 → 用真实的 X.224 握手验证。加 `-Preflight` 只诊断不改动。

## 目录结构

```
scripts/   安装、检测、诊断、修复、会话交还脚本（PowerShell 5.1+，需管理员）
offsets/   本机实测且上游未收录的片段（当前为空，原因见该目录 README）
tools/     偏移校验与版本查询工具（Python）
docs/      原理、偏移定位方法、故障排查
```

## 断开后物理屏黑屏？

RDP 断开后会话保留在「已断开」状态，物理控制台停在登录界面，HDMI 显示器会没有画面。
这不是显示器或显卡故障，`tscon` 一句命令就能把画面交还控制台，
本项目提供了恢复工具与自动化的计划任务：见 **[docs/CONSOLE-HANDOFF.md](docs/CONSOLE-HANDOFF.md)**。

## 校验偏移是否可信

不要盲信任何来源的偏移。`tools/verify-offsets.py` 会解析 `termsrv.dll` 的 PE 结构，检查：

1. 三个代码补丁点是否落在 `.text` 且指令形态与补丁语义相符；
2. `SLInit` 段里的 8 个全局变量地址是否真的被代码以 RIP 相对寻址引用。

```bash
python tools/verify-offsets.py --dll C:\Windows\System32\termsrv.dll --ini offsets/10.0.26100.9949.ini
```

## 许可

[MIT](LICENSE)。RDP Wrapper 本体版权归 Stas'M，本项目不分发其二进制文件，安装时从官方发布页获取。第三方组件与免责说明见 [THIRD-PARTY.md](THIRD-PARTY.md)。

## English

Enable the native Remote Desktop **server** on Windows 11 **Home**, via RDP Wrapper plus a verified offset table. Home SKUs ship `termsrv.dll` and a running `TermService`, but the SKU policy check refuses remote connections; the wrapper patches that check in memory at service start.

Scripts are PowerShell 5.1+ and require elevation. `offsets/` holds build-specific ini fragments that upstream does not ship yet. `tools/verify-offsets.py` re-derives and validates the patch sites from the PE image before you trust them.

Offsets are bound to an exact `termsrv.dll` build and can break on any cumulative update. This is an unsupported path — do not use it on machines you cannot afford to repair, and never expose port 3389 to the internet.
