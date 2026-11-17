#Requires -Version 5.1
<#
.SYNOPSIS
    Report whether the RDP Wrapper offset table covers this machine's termsrv.dll.

.DESCRIPTION
    Read-only. Downloads the community offset table (and reads any local fragments)
    and checks whether the exact termsrv.dll version is present.
    Exit codes: 0 = covered, 2 = not covered, 3 = could not obtain the table.

.PARAMETER IniPath
    Use a local rdpwrap.ini instead of downloading.

.PARAMETER Proxy
    Optional HTTP proxy for the download.
#>
[CmdletBinding()]
param(
    [string]$IniPath,
    [string]$OffsetDir,
    [string]$Proxy,
    [string]$IniUrl = 'https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini'
)

$ErrorActionPreference = 'Stop'
$Base     = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $Base
if (-not $OffsetDir) { $OffsetDir = Join-Path $RepoRoot 'offsets' }

$dll = Join-Path $env:SystemRoot 'System32\termsrv.dll'

# RDP Wrapper keys offsets on VS_FIXEDFILEINFO, not on the FileVersion string.
$bytes = [System.IO.File]::ReadAllBytes($dll)
$ver = $null
for ($i = 0; $i -le $bytes.Length - 16; $i++) {
    if ($bytes[$i] -eq 0xBD -and $bytes[$i+1] -eq 0x04 -and
        $bytes[$i+2] -eq 0xEF -and $bytes[$i+3] -eq 0xFE) {
        $ms = [BitConverter]::ToUInt32($bytes, $i + 8)
        $ls = [BitConverter]::ToUInt32($bytes, $i + 12)
        $ver = '{0}.{1}.{2}.{3}' -f (($ms -shr 16) -band 0xFFFF), ($ms -band 0xFFFF),
                                      (($ls -shr 16) -band 0xFFFF), ($ls -band 0xFFFF)
        break
    }
}
if (-not $ver) { $ver = (Get-Item $dll).VersionInfo.FileVersion.Split(' ')[0] }
$strVer = (Get-Item $dll).VersionInfo.FileVersion

$kv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

Write-Host ''
Write-Host ('=' * 70)
Write-Host " edition     : $($kv.ProductName) ($($kv.EditionID))"
Write-Host " build       : $($kv.CurrentBuild).$($kv.UBR)"
Write-Host " fixed ver   : $ver        <-- lookup key used by rdpwrap" -ForegroundColor Cyan
Write-Host " display ver : $strVer     (cosmetic, can differ)"
Write-Host ('=' * 70)

$sources = @()

if ($IniPath) {
    if (-not (Test-Path $IniPath)) { Write-Host " [!] $IniPath not found"; exit 3 }
    $sources += $IniPath
} else {
    $tmp = Join-Path $env:TEMP 'rdpwrap-check.ini'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $urls = @(
        $IniUrl,
        'https://ghfast.top/https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini',
        'https://gh-proxy.com/https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini'
    )
    $got = $false
    foreach ($u in ($urls | Select-Object -Unique)) {
        $a = @{ Uri = $u; OutFile = $tmp; UseBasicParsing = $true; TimeoutSec = 90 }
        if ($Proxy) { $a['Proxy'] = $Proxy }
        try {
            Invoke-WebRequest @a | Out-Null
            if ((Get-Item $tmp).Length -gt 10000) { $sources += $tmp; $got = $true; break }
        } catch {
            Write-Host " [!] $u -> $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if (-not $got) {
        Write-Host '     All sources failed. Download rdpwrap.ini manually and pass -IniPath.'
    }
}

foreach ($f in Get-ChildItem $OffsetDir -Filter '*.ini' -File -ErrorAction SilentlyContinue) {
    $sources += $f.FullName
}

if ($sources.Count -eq 0) { Write-Host ' [!] no offset table available'; exit 3 }

$covered = $false
foreach ($src in $sources) {
    $lines = Get-Content $src
    $sections = @($lines | Where-Object { $_ -match '^\[10\.\d+\.\d+\.\d+\]$' })
    $updated  = ($lines | Where-Object { $_ -match '^Updated=' } | Select-Object -First 1)
    Write-Host (" source      : {0}  {1}  ({2} builds)" -f (Split-Path $src -Leaf), $updated, $sections.Count)
    if ($lines -contains "[$ver]") { $covered = $true; Write-Host "   -> contains [$ver]" -ForegroundColor Green }
}

Write-Host ''
if ($covered) {
    Write-Host " RESULT: $ver is covered - safe to install." -ForegroundColor Green
    exit 0
}

Write-Host " RESULT: $ver is NOT covered by any table above." -ForegroundColor Yellow
Write-Host '         Find or generate offsets first; see docs/OFFSET-FINDING.md'

$parts = $ver.Split('.')
$major = $parts[0..2] -join '.'
$revs  = @()
foreach ($src in $sources) {
    foreach ($l in (Get-Content $src)) {
        if ($l -match ('^\[' + [regex]::Escape($major) + '\.(\d+)\]$')) {
            $revs += [int]$Matches[1]
        }
    }
}
$below = $revs | Where-Object { $_ -lt [int]$parts[3] } | Sort-Object -Unique | Select-Object -Last 5
if ($below) { Write-Host " nearest listed builds below yours: $($below -join ', ')" }
exit 2
