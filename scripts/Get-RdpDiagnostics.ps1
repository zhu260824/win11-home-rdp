#Requires -Version 5.1
<#
.SYNOPSIS
    Collect RDP-related diagnostics: wrapper state, policy values, listeners,
    and recent failed-logon events (4625) with the Status/SubStatus decoded.

.DESCRIPTION
    Must run elevated (Security log). Writes rdp-diagnostics.txt next to itself.
    Use this when a connection reaches the credential prompt but is rejected.
#>
[CmdletBinding()]
param([string]$OutFile)

$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutFile) { $OutFile = Join-Path (Split-Path -Parent $Base) 'rdp-diagnostics.txt' }

function Say([string]$m) { Write-Host $m; Add-Content -Path $OutFile -Value $m -Encoding UTF8 }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass',
        '-File',$PSCommandPath) -Verb RunAs | Out-Null
    exit 0
}

$reasons = @{
    '0xC000006A' = 'wrong password'
    '0xC0000064' = 'user name does not exist'
    '0xC000006D' = 'bad user name or password (generic)'
    '0xC000006E' = 'account restriction: logon type not allowed for this account'
    '0xC000006F' = 'logon outside permitted hours'
    '0xC0000070' = 'workstation restriction'
    '0xC0000071' = 'password expired'
    '0xC0000072' = 'account disabled'
    '0xC000015B' = 'SeRemoteInteractiveLogonRight not granted to this user'
    '0xC0000193' = 'account expired'
    '0xC0000224' = 'password must be changed before first logon'
    '0xC0000234' = 'account locked out'
    '0xC0000413' = 'blocked by blank-password policy (LimitBlankPasswordUse=1)'
}

$kv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Say ('=' * 70)
Say ("rdp-diagnostics  {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ("host {0}   {1} {2}.{3}" -f $env:COMPUTERNAME, $kv.ProductName, $kv.CurrentBuild, $kv.UBR)
Say ('=' * 70)

Say '--- termsrv / wrapper ---'
$dll = Join-Path $env:SystemRoot 'System32\termsrv.dll'
Say ("termsrv.dll FileVersion : {0}" -f (Get-Item $dll).VersionInfo.FileVersion)
$svcDll = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters' -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
Say ("TermService ServiceDll  : {0}" -f $svcDll)
$svc = Get-CimInstance Win32_Service -Filter "Name='TermService'"
Say ("TermService state / pid : {0} / {1}" -f $svc.State, $svc.ProcessId)
try {
    $m = (Get-Process -Id $svc.ProcessId).Modules | Where-Object { $_.ModuleName -like 'rdpwrap*' }
    Say ("rdpwrap.dll loaded      : {0}" -f $(if ($m) { $m[0].FileName } else { 'NO' }))
} catch { Say "rdpwrap.dll loaded      : unknown ($($_.Exception.Message))" }

Say ''
Say '--- policy values ---'
Say ("fDenyTSConnections      : {0}" -f (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections)
$rt = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue
Say ("UserAuthentication      : {0}   (0 = NLA off)" -f $rt.UserAuthentication)
Say ("SecurityLayer           : {0}" -f $rt.SecurityLayer)
Say ("LimitBlankPasswordUse   : {0}   (1 = blank passwords console-only)" -f (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa').LimitBlankPasswordUse)

Say ''
Say '--- listeners / firewall ---'
$l = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
Say ("3389 listening          : {0} socket(s)" -f @($l).Count)
Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'RDP|Remote Desktop' } |
    ForEach-Object { Say ("rule: {0} enabled={1} direction={2}" -f $_.DisplayName, $_.Enabled, $_.Direction) }

Say ''
Say '--- recent failed logons (4625, last 24h) ---'
$events = @()
try {
    $events = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=(Get-Date).AddHours(-24)} -ErrorAction Stop
} catch { Say "could not read Security log: $($_.Exception.Message)" }
Say ("count: {0}" -f @($events).Count)

foreach ($e in ($events | Select-Object -Last 20)) {
    $d = @{}
    try { foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d[$n.Name] = $n.'#text' } } catch { }
    $sub = $d['SubStatus']
    $why = if ($sub -and $reasons.ContainsKey($sub)) { $reasons[$sub] } else { 'unknown' }
    Say ("{0}  {1}\{2}  type={3} from={4}  Status={5} SubStatus={6} -> {7}" -f `
        $e.TimeCreated.ToString('MM-dd HH:mm:ss'), $d['TargetDomainName'], $d['TargetUserName'],
        $d['LogonType'], $d['IpAddress'], $d['Status'], $sub, $why)
}

Say ''
Say '--- wrapper log ---'
foreach ($c in @('C:\rdpwrap.txt','C:\Windows\rdpwrap.txt',
                 (Join-Path $env:ProgramFiles 'RDP Wrapper\rdpwrap.txt'))) {
    if (Test-Path $c) {
        Say "found: $c"
        Get-Content $c -Tail 20 | ForEach-Object { Say "  | $_" }
        break
    }
}
Say ('=' * 70)
Say "report: $OutFile"
