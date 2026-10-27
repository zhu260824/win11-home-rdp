# 为新版本取偏移

系统更新后 `termsrv.dll` 换了版本，配置表里没有对应段，需要重新定位那几个偏移。

## 先确认版本

**不要用文件属性判断**。看补丁工具自己报的版本：

```powershell
& "C:\Program Files\RDP Wrapper\RDPWInst.exe" -i
# [*] Terminal Services version: 10.0.26100.9549
```

这一行才是配置表的查表键。

## 路线一：自动工具（推荐）

[llccd/RDPWrapOffsetFinder](https://github.com/llccd/RDPWrapOffsetFinder) 读取 `termsrv.dll`，直接输出可粘贴进 ini 的段。

```powershell
# 64 位系统用 64bit 目录，需要同目录的 dbghelp.dll / symsrv.dll / Zydis.dll
.\RDPWrapOffsetFinder.exe C:\Windows\System32\termsrv.dll
```

它有两种模式：

| 可执行文件 | 原理 | 是否需要联网 |
|---|---|---|
| `RDPWrapOffsetFinder.exe` | 用 **PDB 符号**定位函数，再反汇编找指令 | 需要（微软符号服务器） |
| `RDPWrapOffsetFinder_nosymbol.exe` | 按**字节模式**搜索 | 不需要 |

### 符号模式的坑

符号服务器不可达时会直接失败：

```
Symbol not found
```

可以自己把 PDB 抓下来喂给它——PDB 的 GUID/AGE 藏在 PE 的 debug 目录里：

```python
import struct
d = open(r"C:\Windows\System32\termsrv.dll", "rb").read()
# 找到 CODEVIEW 记录里的 RSDS 结构，取 GUID + Age，
# URL 形如 https://msdl.microsoft.com/download/symbols/termsrv.pdb/<GUIDAGE>/termsrv.pdb
```

把下载的 PDB 放到 `<缓存目录>\termsrv.pdb\<GUIDAGE>\termsrv.pdb`，再设：

```powershell
$env:_NT_SYMBOL_PATH = "<缓存目录>"
```

### 模式模式的坑（重要）

`_nosymbol` 版本在找不到匹配模板时会**回退到某个参考版本的段**，输出看起来完全正常，但数字是别的 build 的。

判断方法：把它输出的段与上游 ini 里已有的段对比。**如果逐字节相同，它很可能只是回显了模板**，并不代表这些偏移适配你的二进制。

## 路线二：手工校验（必做）

无论偏移从哪来，落地前都要验。`tools/verify-offsets.py` 做三件事：

```bash
python tools/verify-offsets.py --dll C:\Windows\System32\termsrv.dll --ini offsets\10.0.26100.9949.ini
```

### 1. 代码补丁点必须落在 `.text` 且指令形态对得上

```python
# 读 PE 节表，把 RVA 映射到文件偏移
sec = pe.section_of(offset)
assert sec['name'] == '.text'
```

再看该处字节是否符合补丁语义。以 `DefPolicyPatch` 为例，补丁码是 `C7 87 38 06 00 00 01 00 00 EB`（`mov [rdi+638h], 1; jmp`），对应的**原始**代码应当是同一字段的比较：

```
44 8B 8F 38 06 00 00    mov r9d, [rdi+638h]
45 3B C1                cmp r8d, r9d
75 14                   jne +14h
```

看到 `38 06 00 00` 这个位移量在补丁码和原始指令里一致，就说明位置对了。

### 2. `SLInit` 的数据地址必须真的被代码引用

对每个声称的全局地址，在 `.text` 里找 RIP 相对寻址（`modrm & 0xC7 == 0x05`）：

```python
for i in range(len(text)):
    if (text[i] & 0xC7) != 0x05:      # mod=00, rm=101 -> disp32 相对 RIP
        continue
    disp = struct.unpack_from("<i", text, i + 1)[0]
    if (text_va + i) + 5 + disp == target_rva:
        hits += 1
```

一个「全局变量」如果全代码段无人引用，几乎必然是错地址。

### 3. 交叉验证：让初始化函数自己说话

`CSLQuery::Initialize`（`SLInitOffset` 指向的函数）会写这些全局变量。扫描它的函数体，看写操作的目标地址是否落在声称的地址上——命中越多越可信。

实测样例（`10.0.26100.9949`）：

```
bInitialized         0x131310  refs=9   OK
bServerSku           0x131314  refs=4   OK
lMaxUserSessions     0x131318  refs=2   OK
bAppServerAllowed    0x131320  refs=3   OK
bRemoteConnAllowed   0x13132c  refs=2   OK
bMultimonAllowed     0x131330  refs=1   OK
ulMaxDebugSessions   0x131338  refs=2   OK
bFUSEnabled          0x13133c  refs=2   OK
```

## 怎样判断「这段偏移是不是复用了邻近版本」

一个实用信号：**上游 ini 里相邻 build 的偏移是否相同**。

如果 `A` 与 `A+1` 两个版本的三个代码偏移完全一致，说明这次更新没有动 `termsrv.dll` 的代码布局，拿邻近版本的段通常安全；反之（偏移整体平移了几百字节）就说明代码重排了，不能复用。

## 提交给上游

验好之后，把段发到 [sebaxakerhtc/rdpwrap.ini](https://github.com/sebaxakerhtc/rdpwrap.ini) 的 issue，附上：

1. `termsrv.dll` 的完整版本号；
2. `RDPWInst -i` 输出的 `Terminal Services version` 那一行；
3. 你生成的段；
4. 你的校验结果（引用计数、命中情况）。

上游收录后，本地 `offsets/` 里的副本就可以删掉了。
