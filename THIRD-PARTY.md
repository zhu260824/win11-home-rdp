# 第三方组件说明

本项目**不分发**下列组件的二进制文件或数据，安装脚本在运行时从各自官方地址获取。
它们遵循各自的许可协议，不在本项目 MIT 许可范围内。

| 组件 | 用途 | 来源 |
|---|---|---|
| RDP Wrapper Library | `rdpwrap.dll` / `RDPWInst.exe`，负责加载代理与内存补丁 | [stascorp/rdpwrap](https://github.com/stascorp/rdpwrap)（v1.6.2，© Stas'M Corp.） |
| rdpwrap.ini | 社区维护的偏移配置库 | [sebaxakerhtc/rdpwrap.ini](https://github.com/sebaxakerhtc/rdpwrap.ini) |
| RDPWrapOffsetFinder | 定位新版本偏移的开发工具（文档中引用，未分发） | [llccd/RDPWrapOffsetFinder](https://github.com/llccd/RDPWrapOffsetFinder) |

## 免责

本项目通过修改 `TermService` 进程内的运行时行为来启用家庭版不具备的能力。这属于非官方支持路径：

- 可能违反 Microsoft 软件许可条款中关于版本功能限制的约定；
- 系统更新可能导致失效，甚至引起远程桌面服务异常；
- 使用风险由使用者自行承担。

请勿将 3389 端口直接暴露到公网。
