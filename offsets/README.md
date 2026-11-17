# offsets/

这个目录用于存放**本机实测通过、且上游尚未收录**的 `rdpwrap.ini` 片段。

## 现在为什么是空的

v1.0.0 曾在这里放了一个 `10.0.26100.9949.ini`，标注为"本 build 的偏移段"。
后来发现这个假设是错的，v1.0.2 已删除：

**RDP Wrapper 查表用的是 PE 里的 `VS_FIXEDFILEINFO`（固定版本），不是文件属性里的
`FileVersion` 字符串。** 当时那台机器的固定版本其实是 `10.0.26100.9549`，
上游配置库早已收录；`9949` 这个键从头到尾没有匹配过，那个文件从未生效。

2026-11-12 系统静默替换了 `termsrv.dll`（大小 1,310,720 → 1,327,104 字节），
`FileVersion` 仍显示 `9949`，但固定版本变成了 `10.0.26100.9818`，
补丁随即失效。上游在 11-16 收录 9818 后恢复正常。

## 结论

- **优先使用上游配置库**：<https://github.com/sebaxakerhtc/rdpwrap.ini>
- 只有确认真实缺版本时，才往这里放片段
- 放之前必须用 `tools/verify-offsets.py` 校验（代码补丁点 + SLInit 全局引用）
- 片段里的 section 名必须是**固定版本**，不是 FileVersion

## 怎么看固定版本

```powershell
# 推荐：直接读 PE 资源
python tools/verify-offsets.py --dll C:\Windows\System32\termsrv.dll --version

# 或者看补丁工具自己报的版本（执行 -i 会重装，注意）
& "C:\Program Files\RDP Wrapper\RDPWInst.exe" -i
# [*] Terminal Services version: 10.0.26100.9818
```

拿系统更新的时间点对一下 `termsrv.dll` 的修改时间，能快速判断是不是它被换了。
