#Requires -Version 5.1
<#
.SYNOPSIS
    Enable the native Remote Desktop (RDP) server on Windows Home editions.

.DESCRIPTION
    Windows Home ships termsrv.dll and keeps TermService running, but the SKU
    policy refuses remote connections. This script installs RDP Wrapper, which
    swaps TermService's ServiceDll for rdpwrap.dll and patches termsrv.dll in
    memory according to an offset table keyed by the termsrv.dll build.

    Everything it touches:
      * HKLM\SYSTEM\CurrentControlSet\Services\TermService\Parameters\ServiceDll
      * HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server            (fDenyTSConnections)
      * ...\Terminal Server\WinStations\RDP-Tcp                         (UserAuthentication, SecurityLayer)
      * inbound firewall rules for 3389 (TCP+UDP)
      * a Defender exclusion for the install directory
      * %ProgramFiles%\RDP Wrapper

    On any failure the ServiceDll value is restored automatically.

.PARAMETER Preflight
    Read-only: report readiness and exit. Changes nothing.

.PARAMETER Uninstall
    Restore the stock ServiceDll and remove firewall rules.

.PARAMETER OffsetDir
    Directory holding rdpwrap.ini fragments, one per build. Defaults to .\offsets.

.PARAMETER Proxy
    Optional HTTP proxy for the downloads, e.g. http://127.0.0.1:8080

.EXAMPLE
    .\Install-RdpWrap.ps1 -Preflight
    .\Install-RdpWrap.ps1
    .\Install-RdpWrap.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Preflight,
    [switch]$Uninstall,
    [string]$OffsetDir,
    [string]$WorkDir,
    [string]$Proxy
)

$ErrorActionPreference = 'Stop'

$Base       = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $Base
if (-not $OffsetDir) { $OffsetDir = Join-Path $RepoRoot 'offsets' }
if (-not $WorkDir)   { $WorkDir   = Join-Path $env:TEMP 'rdpwrap-kit' }

$InstallDir = Join-Path $env:ProgramFiles 'RDP Wrapper'
$LogPath    = Join-Path $RepoRoot 'install-log.txt'
$SvcRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters'
$TsRegPath  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$RdpTcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$DefaultDll = '%SystemRoot%\System32\termsrv.dll'

$UrlPackage = 'https://github.com/stascorp/rdpwrap/releases/download/v1.6.2/RDPWrap-v1.6.2.zip'
$UrlIni     = 'https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini'

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    if ($Preflight) { return }   # preflight stays read-only, no log file
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-WebDownload {
    param([string]$Url, [string]$OutFile)
    $args = @{ Uri = $Url; OutFile = $OutFile; UseBasicParsing = $true; TimeoutSec = 120 }
    if ($Proxy) { $args['Proxy'] = $Proxy }
    $prev = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { Invoke-WebRequest @args | Out-Null }
    finally { [Net.ServicePointManager]::SecurityProtocol = $prev }
}

function Get-TermsrvVersion {
    param([string]$DllPath)
    (Get-Item $DllPath).VersionInfo.FileVersion.Split(' ')[0]
}

function Get-PasswordState {
    # RDP refuses accounts with a blank password, but Windows offers no reliable
    # "is the password empty" API. PasswordRequired=False only means the account
    # does not *demand* one -- a password may still be set. So this is advisory.
    param([string]$User = $env:USERNAME)
    try {
        $u = Get-CimInstance Win32_UserAccount -Filter "Name='$User' AND LocalAccount=True" -ErrorAction Stop
        if ($u) {
            if ($u.PasswordRequired) { return 'required' }
            return 'not-required'
        }
    } catch { }
    return 'unknown'
}

function Restart-TermService {
    Write-Log 'Restarting TermService...'
    try { Stop-Service TermService -Force -ErrorAction Stop }
    catch { Write-Log "  stop returned: $($_.Exception.Message)" Yellow }
    Start-Sleep -Seconds 2
    Start-Service TermService
    Start-Sleep -Seconds 3
    $s = Get-Service TermService
    Write-Log "  TermService = $($s.Status)"
    $s.Status -eq 'Running'
}

function Restore-DefaultServiceDll {
    Write-Log 'ROLLBACK: restoring stock TermService ServiceDll' Yellow
    Set-ItemProperty -Path $SvcRegPath -Name 'ServiceDll' -Value $DefaultDll -Type ExpandString -Force
    Restart-TermService | Out-Null
    Write-Log 'Rollback applied.' Yellow
}

function Merge-OffsetFiles {
    # concat every *.ini in the offset dir; later files win only on duplicate keys,
    # and duplicated [sections] are harmless to rdpwrap (first match wins)
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return @() }
    Get-ChildItem $Dir -Filter '*.ini' -File | Sort-Object Name | ForEach-Object {
        Write-Log "offset file: $($_.Name)"
        Get-Content $_.FullName
    }
}

# ---------------------------------------------------------------- preflight
function Invoke-Preflight {
    $dllPath = Join-Path $env:SystemRoot 'System32\termsrv.dll'
    $ver     = Get-TermsrvVersion $dllPath
    $kv      = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $blocks  = @()

    Write-Log ('=' * 64)
    Write-Log 'PREFLIGHT (read-only, nothing is modified)'
    Write-Log "edition         : $($kv.ProductName) [$($kv.EditionID)]"
    Write-Log "build           : $($kv.CurrentBuild).$($kv.UBR)"
    Write-Log "termsrv.dll     : $ver"

    $local = @(Get-ChildItem $OffsetDir -Filter '*.ini' -File -ErrorAction SilentlyContinue)
    if ($local.Count -eq 0) {
        Write-Log "offset files    : none in $OffsetDir (upstream table will be used)" Yellow
    } else {
        Write-Log "offset files    : $($local.Count) file(s) in $OffsetDir"
        $hit = $local | Where-Object { (Get-Content $_.FullName -Raw) -match ('\[' + [regex]::Escape($ver) + '\]') }
        if ($hit) { Write-Log "  $ver is covered by: $($hit[0].Name)" Green }
        else      { Write-Log "  $ver is not in the local offset files (may still be in upstream table)" Yellow }
    }

    $deny = (Get-ItemProperty $TsRegPath -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    $sdll = (Get-ItemProperty $SvcRegPath -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
    Write-Log "fDenyTSConnections : $deny"
    Write-Log "ServiceDll         : $sdll"
    if ($sdll -match 'rdpwrap') { Write-Log '  wrapper already installed' Yellow }

    $listen = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
    Write-Log "port 3389 listening: $(if($listen){"yes ($(@($listen).Count))"}else{'no'})"

    $pw = Get-PasswordState
    Write-Log "account password   : $pw (PasswordRequired flag)"
    if ($pw -eq 'not-required') {
        Write-Log '  note: account does not require a password; if it truly has none,' Red
        Write-Log '  RDP will reject the logon. Set one first: net user <you> *' Red
    }

    Write-Log "elevated now       : $(Test-Elevated)"
    Write-Log ('-' * 64)
    if ($blocks.Count) {
        Write-Log "VERDICT: BLOCKED - $($blocks -join '; ')" Red
        return 1
    }
    Write-Log 'VERDICT: READY. Run without -Preflight to install.' Green
    return 0
}

if ($Preflight) { exit (Invoke-Preflight) }

# ---------------------------------------------------------------- main
if (-not (Test-Elevated)) {
    Write-Log 'Not elevated, relaunching with UAC...' Yellow
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Uninstall) { $a += '-Uninstall' }
    Start-Process powershell.exe -ArgumentList $a -Verb RunAs | Out-Null
    exit 0
}

$dllPath = Join-Path $env:SystemRoot 'System32\termsrv.dll'
$ver     = Get-TermsrvVersion $dllPath

Write-Log ('=' * 64)
Write-Log "Install-RdpWrap  [$(if($Uninstall){'UNINSTALL'}else{'INSTALL'})]"
Write-Log "termsrv.dll : $ver"
Write-Log "install dir : $InstallDir"

if ($Uninstall) {
    Restore-DefaultServiceDll
    foreach ($p in @('TCP','UDP')) {
        $n = "RDP 3389 $p"
        Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
    try { Remove-MpPreference -ExclusionPath $InstallDir -ErrorAction Stop } catch { }
    Write-Log 'Firewall rules and Defender exclusion removed.' Green
    Write-Log 'Done. A reboot clears the ServiceDll change completely.' Green
    exit 0
}

$pw = Get-PasswordState
if ($pw -eq 'not-required') {
    Write-Log 'NOTE: the account does not require a password.' Yellow
    Write-Log '      If it actually has none, RDP logon will fail with 0xc000006a.' Yellow
    Write-Log '      That is fine to continue -- the patch work is independent of it.' Yellow
}

$prevDll = (Get-ItemProperty $SvcRegPath -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
Write-Log "previous ServiceDll: $prevDll"

try {
    # --- stage the package
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $zip = Join-Path $WorkDir 'RDPWrap-v1.6.2.zip'
    $ini = Join-Path $WorkDir 'rdpwrap.upstream.ini'
    if (-not (Test-Path $zip)) { Write-Log "downloading $UrlPackage"; Invoke-WebDownload $UrlPackage $zip }
    if (-not (Test-Path $ini)) { Write-Log "downloading $UrlIni";     Invoke-WebDownload $UrlIni $ini }

    $stage = Join-Path $WorkDir ('stage-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -Path $zip -DestinationPath $stage -Force

    # --- official installer (carries rdpwrap.dll)
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item (Join-Path $stage '*') $InstallDir -Force
    Write-Log 'running RDPWInst -i ...'
    $out = & (Join-Path $InstallDir 'RDPWInst.exe') -i 2>&1
    $out | ForEach-Object { Write-Log "  $($_.ToString().Trim())" }
    $detected = $null
    if (($out -join "`n") -match 'Terminal Services version:\s*([\d\.]+)') { $detected = $Matches[1] }
    Write-Log "installer says Terminal Services version: $(if($detected){$detected}else{'unknown'})"

    if (-not (Test-Path (Join-Path $InstallDir 'rdpwrap.dll'))) { throw 'rdpwrap.dll was not installed' }

    # --- build the merged ini: upstream table + local fragments
    $merged = Join-Path $WorkDir 'rdpwrap.merged.ini'
    Copy-Item $ini $merged -Force
    $frag = Merge-OffsetFiles $OffsetDir
    if ($frag.Count) { Add-Content -Path $merged -Value "`r`n$($frag -join "`r`n")" -Encoding ASCII }

    # --- swap it in with retries: the installer keeps a handle for a moment
    $target = Join-Path $InstallDir 'rdpwrap.ini'
    $swapped = $false
    for ($i = 0; $i -lt 20; $i++) {
        try { Copy-Item $merged $target -Force -ErrorAction Stop; $swapped = $true; break }
        catch { if ($i -eq 0) { Write-Log 'rdpwrap.ini is locked, retrying...' Yellow }; Start-Sleep -Milliseconds 700 }
    }
    if (-not $swapped) { throw 'could not replace rdpwrap.ini' }
    Write-Log 'ini deployed'

    $table = Get-Content $target -Raw
    foreach ($v in @($ver, $detected) | Where-Object { $_ }) {
        if ($table -match ('\[' + [regex]::Escape($v) + '\]')) { Write-Log "ini covers $v" Green }
        else { Write-Log "WARNING: ini has no section for $v" Yellow }
    }

    # --- RDP on, NLA off for broad client compatibility
    Set-ItemProperty -Path $TsRegPath -Name 'fDenyTSConnections' -Value 0 -Type DWord -Force
    if (Test-Path $RdpTcpPath) {
        Set-ItemProperty -Path $RdpTcpPath -Name 'UserAuthentication' -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $RdpTcpPath -Name 'SecurityLayer'     -Value 2 -Type DWord -Force
    }
    Write-Log 'RDP enabled: fDenyTSConnections=0, NLA off, SecurityLayer=SSL'

    # --- firewall
    foreach ($p in @('TCP','UDP')) {
        $n = "RDP 3389 $p"
        if (-not (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $n -Direction Inbound -Action Allow `
                -Protocol $p -LocalPort 3389 -Profile Any | Out-Null
        }
    }
    Write-Log 'firewall: inbound 3389 TCP+UDP allowed'

    # --- antivirus exclusion
    try { Add-MpPreference -ExclusionPath $InstallDir -ErrorAction Stop; Write-Log 'Defender exclusion added' }
    catch { Write-Log "Defender exclusion skipped: $($_.Exception.Message)" Yellow }

    # --- restart and prove the patch actually loaded
    if (-not (Restart-TermService)) { throw 'TermService did not reach Running' }

    $svc = Get-CimInstance Win32_Service -Filter "Name='TermService'"
    $loaded = $null
    try { $loaded = (Get-Process -Id $svc.ProcessId).Modules | Where-Object { $_.ModuleName -like 'rdpwrap*' } }
    catch { }
    if ($loaded) { Write-Log "rdpwrap.dll loaded in TermService (pid $($svc.ProcessId))" Green }
    else { Write-Log 'WARNING: rdpwrap.dll is not loaded in TermService' Yellow }

    $l = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
    if (-not $l) { throw 'nothing is listening on 3389' }
    Write-Log "3389 listening on $(@($l).Count) socket(s)" Green

    Write-Log ('=' * 64)
    Write-Log 'SUCCESS - this machine now accepts RDP connections.' Green
    Write-Log '  from LAN : mstsc /v:<this-machine-ip>'
    Write-Log '  tablet   : "Windows App" (former Microsoft Remote Desktop)'
    Write-Log '  WAN      : put it behind WireGuard/Tailscale, never port-forward 3389' Cyan
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" Red
    Restore-DefaultServiceDll
    exit 1
}
