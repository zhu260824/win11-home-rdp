#Requires -Version 5.1
<#
.SYNOPSIS
    把远程桌面会话交还给物理控制台（解决断开后物理屏黑屏）。

.DESCRIPTION
    RDP 断开后，远程会话会保持"已断开"状态，而物理控制台仍停在登录界面，
    导致插着 HDMI 的显示器没有画面。本脚本用 tscon 把该会话连到 console，
    画面立即回到物理屏。

    两种模式：
      默认       把指定会话（不指定则自动找当前用户的 RDP 会话）交还控制台
      -Auto      把所有处于"已断开"状态的 RDP 会话都交还控制台
                 （供计划任务在断开事件后调用）

.PARAMETER SessionId  目标会话 ID；0 表示自动
.PARAMETER Auto       自动模式：处理所有已断开的 RDP 会话
.PARAMETER List       只列出会话，不执行
#>
[CmdletBinding()]
param(
    [int]$SessionId = 0,
    [switch]$Auto,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path
$Log  = Join-Path $Base 'console-handoff.log'

function Say([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line
    try { Add-Content -Path $Log -Value $line -Encoding UTF8 } catch { }
}

# ---- WTS 会话枚举（不解析 qwinsta 文本，避免中文/列宽问题）
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WtsSess {
    [DllImport("wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool WTSEnumerateSessions(IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);
    [DllImport("wtsapi32.dll")]
    public static extern void WTSFreeMemory(IntPtr p);
    [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode)]
    public static extern bool WTSQuerySessionInformation(IntPtr hServer, int sessionId, int infoClass, out IntPtr ppBuffer, out int pBytesReturned);

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_SESSION_INFO { public int SessionId; public IntPtr pWinStationName; public int State; }

    public static string GetUser(int sessionId) {
        IntPtr buf; int len;
        if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, 5, out buf, out len)) return "";
        string s = Marshal.PtrToStringUni(buf);
        WTSFreeMemory(buf);
        return s == null ? "" : s;
    }

    public static string[] List() {
        IntPtr p; int count;
        if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out p, out count)) return new string[0];
        var res = new string[count];
        int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
        for (int i = 0; i < count; i++) {
            var si = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(p.ToInt64() + i * size), typeof(WTS_SESSION_INFO));
            string name = Marshal.PtrToStringUni(si.pWinStationName);
            res[i] = si.SessionId + "|" + (name == null ? "" : name) + "|" + si.State + "|" + GetUser(si.SessionId);
        }
        WTSFreeMemory(p);
        return res;
    }
}
'@

$stateName = @{ 0='Active'; 1='Connected'; 2='ConnectQuery'; 3='Shadow'; 4='Disconnected'; 5='Idle'; 6='Listen' }

function Get-Sessions {
    foreach ($line in [WtsSess]::List()) {
        $p = $line -split '\|'
        [pscustomobject]@{
            Id        = [int]$p[0]
            Name      = $p[1]
            State     = [int]$p[2]
            StateText = $stateName[[int]$p[2]]
            User      = $p[3]
        }
    }
}

$sessions = @(Get-Sessions)

if ($List) {
    $sessions | ForEach-Object { "{0,-6} {1,-16} {2,-14} {3}" -f $_.Id, $_.Name, $_.StateText, $_.User }
    exit 0
}

$me = $env:USERNAME
$targets = @()

if ($Auto) {
    # 断开态下 WTSUserName 可能是空串，会话名也可能变化，所以只按最稳的两条判定：
    #   1) 状态 = 已断开(4)
    #   2) 不是 0 号会话（Services 会话天然是断开态，必须排除）
    $targets = @($sessions | Where-Object {
        $_.State -eq 4 -and $_.Id -ne 0
    })
} elseif ($SessionId -gt 0) {
    $targets = @($sessions | Where-Object { $_.Id -eq $SessionId })
} else {
    $targets = @($sessions | Where-Object {
        $_.Name -match '^(rdp|RDP)' -and ($_.User -eq $me -or -not $_.User) -and ($_.State -eq 0 -or $_.State -eq 4)
    } | Select-Object -First 1)
}

if ($targets.Count -eq 0) {
    # 把每个会话的完整字段都记下来，便于下次诊断为什么没匹配
    Say '没有需要处理的会话。当前全部会话：'
    foreach ($s in $sessions) {
        Say ("  id={0,-6} name='{1}' state={2} user='{3}'" -f $s.Id, $s.Name, $s.StateText, $s.User)
    }
    exit 0
}

$tscon = Join-Path $env:SystemRoot 'System32\tscon.exe'
if (-not (Test-Path $tscon)) {
    Say 'tscon.exe 不存在，请先运行 Restore-SessionTools.ps1'
    exit 1
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) {
    Say '需要管理员权限，正在提权 ...'
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Auto) { $argList += '-Auto' }
    if ($SessionId -gt 0) { $argList += @('-SessionId', $SessionId) }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs | Out-Null
    exit 0
}

foreach ($s in $targets) {
    Say ("交还会话 {0} ({1}, {2}, 用户={3}) -> console" -f $s.Id, $s.Name, $s.StateText, $s.User)
    $out = & $tscon $s.Id /dest:console 2>&1
    if ($LASTEXITCODE -eq 0) { Say '  成功' }
    else { Say ("  失败 (exit=$LASTEXITCODE): $($out -join ' ')") }
}

Say '完成。'
