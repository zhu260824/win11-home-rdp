#Requires -Version 5.1
<#
.SYNOPSIS
    Repair an RDP Wrapper installation after a Windows update replaced termsrv.dll.

.DESCRIPTION
    Windows ships termsrv.dll with a version *string* that does not always match
    the binary's VS_FIXEDFILEINFO. RDP Wrapper looks up offsets by the FIXED
    version, so after an update the displayed FileVersion may look unchanged
    while the fixed version moved on - the patch silently stops applying and
    port 3389 stops listening.

    This script:
      1. reads the FIXED version straight out of the PE resource
      2. downloads the upstream offset table (with proxy / mirror fallbacks)
      3. checks whether that version is covered
      4. backs up and deploys the table
      5. restarts TermService and proves the server answers a real X.224 handshake

.PARAMETER Preflight
    Report only; change nothing.

.PARAMETER IniUrl
    Override the offset table URL (mirror).

.PARAMETER Proxy
    Optional HTTP proxy for the download, e.g. http://127.0.0.1:7890

.EXAMPLE
    .\Repair-RdpWrapper.ps1 -Preflight
    .\Repair-RdpWrapper.ps1
#>
[CmdletBinding()]
param(
    [switch]$Preflight,
    [string]$IniUrl,
    [string]$Proxy
)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:ProgramFiles 'RDP Wrapper'
$IniPath    = Join-Path $InstallDir 'rdpwrap.ini'
$DllPath    = Join-Path $env:SystemRoot 'System32\termsrv.dll'
$Report     = Join-Path $PSScriptRoot 'repair-report.txt'

$Mirrors = @(
    'https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini',
    'https://ghfast.top/https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini',
    'https://gh-proxy.com/https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini'
)

function Write-Report {
    param([string]$Message, [string]$Color = 'Gray')
    if ($Preflight) {
        Write-Host $Message -ForegroundColor $Color
    } else {
        Write-Host $Message -ForegroundColor $Color
        try { Add-Content -Path $Report -Value $Message -Encoding UTF8 } catch { }
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- fixed version
function Get-FixedFileVersion {
    <#
        Reads VS_FIXEDFILEINFO out of the PE image. This is the version RDP
        Wrapper actually keys its offset lookup on - the FileVersion string in
        the file properties can differ.
    #>
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sig = [byte[]](0xBD, 0x04, 0xEF, 0xFE)

    $at = -1
    for ($i = 0; $i -le $bytes.Length - 16; $i++) {
        if ($bytes[$i] -eq 0xBD -and $bytes[$i+1] -eq 0x04 -and
            $bytes[$i+2] -eq 0xEF -and $bytes[$i+3] -eq 0xFE) { $at = $i; break }
    }
    if ($at -lt 0) { throw 'VS_FIXEDFILEINFO not found in termsrv.dll' }

    # [+4] dwStrucVersion, [+8] dwFileVersionMS, [+12] dwFileVersionLS
    $ms = [BitConverter]::ToUInt32($bytes, $at + 8)
    $ls = [BitConverter]::ToUInt32($bytes, $at + 12)

    $major = ($ms -shr 16) -band 0xFFFF
    $minor = $ms -band 0xFFFF
    $build = ($ls -shr 16) -band 0xFFFF
    $rev   = $ls -band 0xFFFF

    [pscustomobject]@{
        Version      = "$major.$minor.$build.$rev"
        Major        = $major
        Minor        = $minor
        Build        = $build
        Revision     = $rev
    }
}

# ---------------------------------------------------------------- download
function Get-OffsetTable {
    param([string]$Destination)

    $urls = if ($IniUrl) { @($IniUrl) } else { $Mirrors }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($u in $urls) {
        try {
            $args = @{ Uri = $u; OutFile = $Destination; UseBasicParsing = $true; TimeoutSec = 90 }
            if ($Proxy) { $args['Proxy'] = $Proxy }
            Invoke-WebRequest @args | Out-Null
            if ((Get-Item $Destination).Length -gt 10000) { return $u }
        } catch {
            Write-Report "  download failed ($($_.Exception.Message)) - trying next source"
        }
        try {
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (Test-Path $curl) {
                $curlArgs = @('-sS','-L','--max-time','90','-o',$Destination)
                if ($Proxy) { $curlArgs += @('-x',$Proxy) }
                $curlArgs += $u
                & $curl $curlArgs 2>$null
                if ((Test-Path $Destination) -and (Get-Item $Destination).Length -gt 10000) { return "$u (curl)" }
            }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------- handshake
function Test-RdpHandshake {
    param([string]$HostName = '127.0.0.1', [int]$Port = 3389)

    # X.224 Connection Request with an RDP Negotiation Request (TLS)
    $cr = [byte[]](0x03,0x00,0x00,0x13,0x0e,0xe0,0x00,0x00,0x00,0x00,0x00,
                   0x01,0x00,0x08,0x00,0x03,0x00,0x00,0x00,0x00)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(4000)) { return $false }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $stream.Write($cr, 0, $cr.Length)
        $buf = New-Object byte[] 64
        $stream.ReadTimeout = 4000
        $n = $stream.Read($buf, 0, 64)
        # X.224 Connection Confirm = 0xD0 at offset 5
        return ($n -ge 11 -and $buf[5] -eq 0xD0)
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------- preflight
function Show-State {
    $fixed = Get-FixedFileVersion -Path $DllPath
    $strVer = (Get-Item $DllPath).VersionInfo.FileVersion

    Write-Report ('=' * 68)
    Write-Report "RDP Wrapper repair  $(if ($Preflight) { '(PREFLIGHT - read only)' })"
    Write-Report ('=' * 68)
    Write-Report "termsrv.dll size        : $((Get-Item $DllPath).Length) bytes"
    Write-Report "termsrv.dll FileVersion : $strVer   (display only)"
    Write-Report "termsrv.dll FIXED ver   : $($fixed.Version)   <-- offset lookup key" 'Cyan'

    $svcDll = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters' `
                -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
    Write-Report "TermService ServiceDll  : $svcDll"
    Write-Report "TermService state       : $((Get-Service TermService).Status)"

    $listen = @(Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)
    Write-Report "3389 listening          : $($listen.Count) socket(s)"

    $local = $null
    if (Test-Path $IniPath) {
        $lines = Get-Content $IniPath
        $local = ($lines | Where-Object { $_ -match '^Updated=' } | Select-Object -First 1)
        $covered = $lines -contains "[$($fixed.Version)]"
        Write-Report "local rdpwrap.ini       : $local"
        Write-Report "  covers $($fixed.Version)     : $covered"
    } else {
        Write-Report "local rdpwrap.ini       : MISSING"
    }

    $handshake = Test-RdpHandshake
    Write-Report "RDP handshake (loopback): $(if ($handshake) { 'answers' } else { 'NO RESPONSE' })"
    Write-Report ('-' * 68)

    return $fixed
}

# ---------------------------------------------------------------- main
if ($Preflight) {
    $null = Show-State
    exit 0
}

if (-not (Test-Admin)) {
    Write-Report 'Not elevated - raising UAC prompt, click Yes...' 'Yellow'
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath)
    if ($Proxy) { $a += @('-Proxy', $Proxy) }
    if ($IniUrl) { $a += @('-IniUrl', $IniUrl) }
    Start-Process powershell.exe -ArgumentList $a -Verb RunAs | Out-Null
    exit 0
}

Set-Content -Path $Report -Value '' -Encoding UTF8
$fixed = Show-State
$need  = $fixed.Version

# 1) download upstream table
Write-Report ''
Write-Report 'Downloading offset table ...'
$tmp = Join-Path $env:TEMP ('rdpwrap-' + [guid]::NewGuid().ToString('N') + '.ini')
$usedUrl = Get-OffsetTable -Destination $tmp
if (-not $usedUrl) {
    Write-Report 'FAILED: could not download the offset table from any source.' 'Red'
    Write-Report '        Download rdpwrap.ini manually and re-run with -IniUrl <path or URL>.' 'Yellow'
    exit 1
}
$table = Get-Content $tmp -Raw
$updated = ($table -split "`r?`n" | Where-Object { $_ -match '^Updated=' } | Select-Object -First 1)
Write-Report "  source : $usedUrl"
Write-Report "  size   : $((Get-Item $tmp).Length) bytes   $updated"

# 2) coverage
if ($table -notmatch ('\[' + [regex]::Escape($need) + '\]')) {
    Write-Report ''
    Write-Report "FAILED: upstream table has no section for $need." 'Red'
    Write-Report '        The build is not covered yet - offsets must be found first.' 'Yellow'
    Write-Report '        See docs/OFFSET-FINDING.md (RDPWrapOffsetFinder + verify-offsets.py).'
    exit 2
}
Write-Report "  covers $need : yes" 'Green'

# 3) backup + deploy
if (Test-Path $IniPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $IniPath "$IniPath.bak-$stamp" -Force
    Write-Report "  backup : rdpwrap.ini.bak-$stamp"
} else {
    Write-Report '  note   : no existing rdpwrap.ini to back up' 'Yellow'
}
Copy-Item $tmp $IniPath -Force
Write-Report "  deployed to $IniPath"

# 4) restart service
Write-Report ''
Write-Report 'Restarting TermService ...'
try { Stop-Service TermService -Force -ErrorAction Stop } catch { Write-Report "  stop: $($_.Exception.Message)" 'Yellow' }
Start-Sleep -Seconds 3
Start-Service TermService
Start-Sleep -Seconds 5
$state = (Get-Service TermService).Status
Write-Report "  TermService = $state"

# 5) verify
$listen = @(Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)
Write-Report "  3389 listening = $($listen.Count) socket(s)"

$loaded = $false
try {
    $pid_ = (Get-CimInstance Win32_Service -Filter "Name='TermService'").ProcessId
    $loaded = [bool]((Get-Process -Id $pid_).Modules | Where-Object { $_.ModuleName -like 'rdpwrap*' })
} catch { }
Write-Report "  rdpwrap.dll loaded = $loaded"

$handshake = Test-RdpHandshake
Write-Report "  RDP handshake = $(if ($handshake) { 'answers' } else { 'NO RESPONSE' })"

Write-Report ''
# A live X.224 handshake is the authoritative signal; the socket count from
# Get-NetTCPConnection is unavailable in some restricted contexts, so it is
# reported but not required for success.
if ($state -eq 'Running' -and $handshake) {
    Write-Report 'SUCCESS - RDP is serving again.' 'Green'
    Write-Report "  connect with: mstsc /v:<this-machine-ip>"
    exit 0
} else {
    Write-Report 'FAILED - the service did not come back cleanly.' 'Red'
    Write-Report "  roll back with the rdpwrap.ini.bak-* copy and see docs/TROUBLESHOOTING.md"
    exit 1
}
