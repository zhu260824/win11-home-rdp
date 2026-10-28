#Requires -Version 5.1
<#
.SYNOPSIS
    注册/卸载"RDP 断开后自动把会话交还物理控制台"的计划任务。

.DESCRIPTION
    任务由 TerminalServices-LocalSessionManager 的事件 24（会话断开）触发，
    延迟 45 秒后运行 Send-SessionToConsole.ps1 -Auto：
    若届时仍有已断开的 RDP 会话，就用 tscon 把它连到 console，
    使物理显示器恢复画面。

    45 秒的延迟是为了给"短暂掉线后重连"留余地；重连成功后会话不再是
    断开状态，脚本会什么都不做。

.PARAMETER Uninstall  删除该任务
.PARAMETER Delay      延迟秒数，默认 45
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [int]$Delay = 45
)

$ErrorActionPreference = 'Stop'
$Base      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Worker    = Join-Path $Base 'Send-SessionToConsole.ps1'
$TaskName  = 'RDP-SessionHandoffToConsole'
$Log       = Join-Path $Base 'console-handoff-task.log'

function Say([string]$m) {
    Write-Host $m
    try { Add-Content -Path $Log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch { }
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Uninstall) { $a += '-Uninstall' }
    Start-Process powershell.exe -ArgumentList $a -Verb RunAs | Out-Null
    exit 0
}

if ($Uninstall) {
    $r = schtasks /Delete /TN $TaskName /F 2>&1
    Say ("卸载结果: $r")
    exit 0
}

if (-not (Test-Path $Worker)) { Say "找不到 $Worker"; exit 1 }

# EventTrigger 的订阅：会话断开事件 24
$subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">' +
                '<Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">' +
                '*[System[EventID=24]]</Select></Query></QueryList>'

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>RDP 会话断开后把会话交还物理控制台，避免 HDMI 显示器黑屏</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$([System.Security.SecurityElement]::Escape($subscription))</Subscription>
      <Delay>PT${Delay}S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$Worker" -Auto</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$tmp = Join-Path $env:TEMP 'rdp-handoff-task.xml'
[System.IO.File]::WriteAllText($tmp, $xml, (New-Object System.Text.UnicodeEncoding($false, $true)))

Say "注册计划任务 $TaskName（延迟 ${Delay}s）..."
$out = schtasks /Create /TN $TaskName /XML $tmp /F 2>&1
Say ("  $out")
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

Say ''
Say '--- 任务状态 ---'
schtasks /Query /TN $TaskName /V /FO LIST 2>&1 | Select-String -Pattern '任务名|状态|下次运行|上次运行|要运行的任务' | ForEach-Object { Say "  $($_.Line.Trim())" }

Say ''
Say '安装完成。断开 RDP 后若 45 秒内没有重连，会话会自动交还物理控制台。'
Say '卸载：powershell -ExecutionPolicy Bypass -File .\Install-ConsoleHandoffTask.ps1 -Uninstall'
