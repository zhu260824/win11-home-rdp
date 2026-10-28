#Requires -Version 5.1
<#
.SYNOPSIS
    从 WinSxS 组件存储恢复被删除的终端服务命令行工具。

.DESCRIPTION
    精简版镜像常删掉 System32 下的 tscon.exe / quser.exe / qwinsta.exe 等，
    但 WinSxS 里的组件副本通常还在。System32 下的这些文件本质是指向 WinSxS 的
    硬链接，删掉链接不影响组件本身，可以直接复制回来。

    为避免遍历整个 WinSxS（几十万文件，很慢），这里只枚举顶层组件目录名中
    含 commandlinetool 的那几个，再从里面取文件。

.PARAMETER Force   已存在也覆盖
.PARAMETER DryRun  只报告，不复制
#>
[CmdletBinding()]
param([switch]$Force, [switch]$DryRun)

$ErrorActionPreference = 'Stop'
$Base   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Report = Join-Path $Base 'restore-sessiontools-log.txt'

function Say([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    try { Add-Content -Path $Report -Value $m -Encoding UTF8 } catch { }
}

# 任何未捕获异常都写进日志，别让窗口一闪而过
trap {
    Say ("FATAL: {0}" -f $_.Exception.Message) 'Red'
    Say ("  位置: {0}" -f $_.InvocationInfo.PositionMessage) 'Red'
    exit 1
}

function Get-SafeVersion([string]$s) {
    if (-not $s) { return [version]'0.0.0.0' }
    try { return [version]($s -replace ' .*', '') } catch { return [version]'0.0.0.0' }
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated -and -not $DryRun) {
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$PSCommandPath) -Verb RunAs | Out-Null
    exit 0
}

$tools = @('tscon.exe','tsdiscon.exe','tskill.exe','query.exe','quser.exe','qwinsta.exe')
$sys32 = Join-Path $env:SystemRoot 'System32'
$sxs   = Join-Path $env:SystemRoot 'WinSxS'

Say ('=' * 68)
Say "恢复终端服务命令行工具  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Say "管理员=$elevated  DryRun=$DryRun"
Say ('=' * 68)

# 只枚举顶层组件目录（快），排除 wow64 / x86 变体
Say '[*] 枚举 WinSxS 组件目录 ...'
$dirs = @(Get-ChildItem $sxs -Directory -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -like 'amd64_microsoft-windows-t*commandlinetool*' })
Say "    命中 $($dirs.Count) 个组件目录"
foreach ($d in $dirs) { Say "    - $($d.Name)" }

$restored = 0; $skipped = 0; $failed = 0

foreach ($t in $tools) {
    $dest = Join-Path $sys32 $t

    if ((Test-Path $dest) -and -not $Force) {
        Say ("[跳过] {0,-14} 已存在" -f $t)
        $skipped++
        continue
    }

    $cand = $null
    foreach ($d in $dirs) {
        $f = Join-Path $d.FullName $t
        if (Test-Path $f) {
            $ver = Get-SafeVersion (Get-Item $f).VersionInfo.FileVersion
            if (-not $cand -or $ver -gt $cand.Version) {
                $cand = [pscustomobject]@{ Path = $f; Version = $ver }
            }
        }
    }

    if (-not $cand) {
        Say ("[失败] {0,-14} 组件目录中找不到该文件" -f $t) 'Red'
        $failed++
        continue
    }

    if ($DryRun) {
        Say ("[计划] {0,-14} <- v{1}" -f $t, $cand.Version)
        continue
    }

    try {
        Copy-Item -Path $cand.Path -Destination $dest -Force -ErrorAction Stop
        if (Test-Path $dest) {
            Say ("[完成] {0,-14} <- v{1}" -f $t, $cand.Version) 'Green'
            $restored++
        } else {
            Say ("[失败] {0,-14} 复制后仍不存在" -f $t) 'Red'
            $failed++
        }
    } catch {
        Say ("[失败] {0,-14} {1}" -f $t, $_.Exception.Message) 'Red'
        $failed++
    }
}

Say ('-' * 68)
Say "恢复=$restored  跳过=$skipped  失败=$failed"

if (-not $DryRun) {
    Say ''
    Say '--- 验证 qwinsta ---'
    $q = Join-Path $sys32 'qwinsta.exe'
    if (Test-Path $q) {
        (& $q 2>&1) | ForEach-Object { Say "  $_" }
    } else {
        Say '  qwinsta.exe 仍不存在' 'Yellow'
    }
}
Say ('=' * 68)
exit ([int]($failed -gt 0))
