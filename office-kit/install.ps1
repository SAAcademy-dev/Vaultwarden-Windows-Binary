#Requires -Version 5.1
<#
.SYNOPSIS
    사무실 윈도우 PC에 Vaultwarden(금고 서버)과 Caddy(HTTPS)를 윈도우 서비스로 설치합니다.

.DESCRIPTION
    사무실 안에서만 쓰는 구성입니다.
    - 인터넷 쪽 포트는 열지 않습니다. 방화벽은 같은 사내 네트워크에서 오는 443번만 허용합니다.
    - 인증서는 Let's Encrypt DNS-01 방식입니다. _acme-challenge 레코드를 DuckDNS로 넘겨(CNAME) 받습니다.
    - 매일 03:00 SYSTEM 권한으로 PC 안에 백업합니다. -BackupRoot 를 주면 로그인한 사용자 권한으로
      그 폴더(예: Google Drive)에 복사합니다. G: 드라이브는 관리자 권한 프로그램에서 안 보일 수 있어서 두 단계로 나눕니다.
    - 다시 실행하면 금고 데이터와 비밀값(.env, caddy.env)은 그대로 두고 프로그램과 설정만 다시 씁니다.
      업데이트도 같은 방법이며, 시작 전에 자동으로 백업합니다.

.EXAMPLE
    .\install.ps1 -Domain vault.example.co.kr -DuckDnsName example-vault -BackupRoot "G:\내 드라이브\vaultwarden-backup"

.EXAMPLE
    # 새 버전으로 업데이트 (그 버전의 Windows 빌드가 이 저장소 릴리스에 있어야 함)
    .\install.ps1 -Domain vault.example.co.kr -DuckDnsName example-vault -BackupRoot "G:\내 드라이브\vaultwarden-backup" -Version 1.38.0

.EXAMPLE
    # 새 PC로 옮기거나 고장 난 PC를 되살릴 때 (백업 폴더는 먼저 C:\ 아래로 복사)
    .\install.ps1 -Domain vault.example.co.kr -DuckDnsName example-vault -BackupRoot "G:\내 드라이브\vaultwarden-backup" -RestoreFrom C:\restore\20261104-030000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Domain,
    [string]$DuckDnsName,
    [string]$BackupRoot,
    [string]$Version = '1.37.5',
    [string]$InstallDir = 'C:\vaultwarden',
    [string]$DriveCopyUser,
    [string]$RestoreFrom,
    [string]$VaultwardenExe,
    [string]$CaddyExe,
    [string]$AdminTokenHash,
    [string]$DuckDnsToken,
    [switch]$SkipDnsCheck,
    [switch]$TestMode
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ------------------------------------------------------------------ 고정값
# 기본 버전은 체크섬을 고정해 둡니다. 다른 버전은 공식 저장소에서 짝 웹 금고 버전과 체크섬을 찾아옵니다.
$Pinned = @{
    '1.37.5' = @{
        WebVault    = 'v2026.10.1'
        WebVaultSha = '354de9056c871e48db84975985e7d57c111ac6537bd4e4720488019e8638060f'
        VwSha       = ''
    }
}
$ReleaseRepo  = 'SAAcademy-dev/Vaultwarden-Windows-Binary'
$WinSwUrl     = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
$WinSwSha     = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'
$CaddyUrl     = 'https://caddyserver.com/api/download?os=windows&arch=amd64&p=github.com%2Fcaddy-dns%2Fduckdns'
$SvcVw        = 'vaultwarden'
$SvcCaddy     = 'vaultwarden-caddy'
$TaskBackup   = 'Vaultwarden Backup'
$TaskCopy     = 'Vaultwarden Backup Copy'
$FwRule       = 'Vaultwarden HTTPS (office LAN)'
$CurlExe      = Join-Path $env:SystemRoot 'System32\curl.exe'
$TarExe       = Join-Path $env:SystemRoot 'System32\tar.exe'
$PsExe        = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ------------------------------------------------------------------ 도우미
function Write-Step([string]$Message) { Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Warn([string]$Message) { Write-Host "    [주의] $Message" -ForegroundColor Yellow }
function Stop-Install([string]$Message, [int]$Code = 1) {
    Write-Host ''
    Write-Host "[중단] $Message" -ForegroundColor Red
    exit $Code
}

# 외부 프로그램 실행. Windows PowerShell 5.1 에서 stderr 출력이 오류로 바뀌어 멈추는 것을 막습니다.
function Invoke-Exe {
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$ArgumentList = @(), [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = (@($lines) -join "`n").Trim()
    if (-not $AllowFail -and $code -ne 0) {
        throw "실행 실패 (종료 코드 $code): $(Split-Path -Leaf $FilePath)`n$text"
    }
    [pscustomobject]@{ Code = $code; Out = $text }
}

# 파일 쓰기: 설정 파일은 BOM 없는 UTF-8(LF), PowerShell 스크립트는 BOM 있는 UTF-8 (5.1 이 한글 경로를 바르게 읽도록)
function Write-TextFile([string]$Path, [string]$Text, [switch]$Bom) {
    $enc = New-Object System.Text.UTF8Encoding($Bom.IsPresent)
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), $enc)
}

function Get-Download([string]$Source, [string]$Destination, [string]$Sha256) {
    if ($Source -match '^https?://') {
        $r = Invoke-Exe $CurlExe @('-fsSL', '--retry', '3', '--retry-delay', '3', '--max-time', '600', '-o', $Destination, $Source) -AllowFail
        if ($r.Code -ne 0) { Stop-Install "받기 실패: $Source`n    $($r.Out)" }
    } else {
        if (-not (Test-Path -LiteralPath $Source)) { Stop-Install "파일이 없습니다: $Source" }
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
    $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Sha256 -and $hash -ne $Sha256.ToLowerInvariant()) {
        Stop-Install "체크섬이 다릅니다: $(Split-Path -Leaf $Destination)`n    기대값 $Sha256`n    실제값 $hash"
    }
    $mark = if ($Sha256) { '체크섬 일치' } else { 'sha256' }
    Write-Info ('{0,-22} {1} {2}' -f (Split-Path -Leaf $Destination), $mark, $hash)
}

function Get-VersionInfo([string]$Ver) {
    if ($Pinned.ContainsKey($Ver)) { return $Pinned[$Ver] }
    $yaml = Invoke-Exe $CurlExe @('-fsSL', "https://raw.githubusercontent.com/dani-garcia/vaultwarden/$Ver/docker/DockerSettings.yaml") -AllowFail
    $m = [regex]::Match($yaml.Out, 'vault_version:\s*"?(v[0-9][0-9.]*)"?')
    if (-not $m.Success) { Stop-Install "Vaultwarden $Ver 에 맞는 웹 금고 버전을 찾지 못했습니다. 버전 번호를 확인하세요." }
    $wv = $m.Groups[1].Value
    $sums = Invoke-Exe $CurlExe @('-fsSL', "https://github.com/dani-garcia/bw_web_builds/releases/download/$wv/sha256sums.txt") -AllowFail
    $line = @($sums.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match ('\s\*?bw_web_' + [regex]::Escape($wv) + '\.tar\.gz$') })[0]
    if (-not $line) { Stop-Install "웹 금고 $wv 의 체크섬을 찾지 못했습니다." }
    return @{ WebVault = $wv; WebVaultSha = ($line -split '\s+')[0]; VwSha = '' }
}

function Read-EnvValue([string]$Path, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*)$')) {
            $v = $Matches[1].Trim()
            if ($v.Length -ge 2 -and (($v[0] -eq "'" -and $v[-1] -eq "'") -or ($v[0] -eq '"' -and $v[-1] -eq '"'))) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            return $v
        }
    }
    return $null
}

function Get-LanIPv4 {
    $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    if ($cfg) { return (@($cfg.IPv4Address)[0]).IPAddress }
    return $null
}

function Resolve-Record([string]$Name, [string]$Type) {
    foreach ($server in @('8.8.8.8', '')) {
        try {
            if ($server) { return Resolve-DnsName -Name $Name -Type $Type -Server $server -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop }
            return Resolve-DnsName -Name $Name -Type $Type -DnsOnly -NoHostsFile -ErrorAction Stop
        } catch { }
    }
    return $null
}

# 가비아 호스트 칸에 넣을 앞부분 (vault.example.co.kr → vault)
function Get-HostLabel([string]$Fqdn) {
    $parts = $Fqdn.Split('.')
    $zoneLen = 2
    if ($parts.Count -ge 3 -and $parts[-1] -eq 'kr' -and @('co', 'or', 'go', 'ne', 're', 'pe', 'ac') -contains $parts[-2]) { $zoneLen = 3 }
    if ($parts.Count -le $zoneLen) { return '@' }
    return ($parts[0..($parts.Count - $zoneLen - 1)] -join '.')
}

function Test-PortFree([System.Net.IPAddress]$Address, [int]$Port) {
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener($Address, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { $listener.Stop() }
    }
}

function Remove-KitService([string]$Name, [string]$Wrapper) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    Write-Info "기존 서비스 정리: $Name"
    if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force }
    if (Test-Path -LiteralPath $Wrapper) { Invoke-Exe $Wrapper @('uninstall') -AllowFail | Out-Null }
    else { Invoke-Exe 'sc.exe' @('delete', $Name) -AllowFail | Out-Null }
    for ($i = 0; $i -lt 30 -and (Get-Service -Name $Name -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        Stop-Install "서비스 $Name 를 지우지 못했습니다. 서비스 관리 창(services.msc)이 열려 있으면 닫고 다시 실행하세요."
    }
}

function Wait-Http([string]$Url, [string[]]$Extra, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $r = Invoke-Exe $CurlExe (@('-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', '10') + $Extra + @($Url)) -AllowFail
        if ($r.Out -eq '200') { return $true }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Show-LogTail([string]$Path, [int]$Lines = 30) {
    if (Test-Path -LiteralPath $Path) {
        Write-Host "    --- $Path (마지막 $Lines 줄)"
        Get-Content -LiteralPath $Path -Tail $Lines | ForEach-Object { Write-Host "    $_" }
    }
}

# ------------------------------------------------------------------ 0. 기본 검사
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Stop-Install '관리자 권한 PowerShell 에서 실행하세요. (시작 메뉴에서 Windows PowerShell 우클릭 → 관리자 권한으로 실행)'
}
if (-not [Environment]::Is64BitOperatingSystem) { Stop-Install '64비트 Windows 만 지원합니다.' }
foreach ($tool in @($CurlExe, $TarExe)) {
    if (-not (Test-Path -LiteralPath $tool)) { Stop-Install "Windows 기본 도구가 없습니다: $tool (Windows 10 1803 이상 필요)" }
}

$Domain = $Domain.Trim().ToLowerInvariant()
if ($Domain -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { Stop-Install "도메인 형식이 아닙니다: $Domain" }
if ($DuckDnsName) { $DuckDnsName = $DuckDnsName.Trim().ToLowerInvariant() -replace '\.duckdns\.org\.?$', '' }
if (-not $DuckDnsName) {
    if ($TestMode) { $DuckDnsName = 'kit-test' } else { Stop-Install '-DuckDnsName 이 필요합니다 (duckdns.org 에서 만든 이름, 예: example-vault).' }
}
if (-not $DriveCopyUser) {
    $console = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    $DriveCopyUser = if ($console) { $console } else { "$env:USERDOMAIN\$env:USERNAME" }
}
$InstallDir = $InstallDir.TrimEnd('\')
$dataDir = Join-Path $InstallDir 'data'
if ($RestoreFrom) {
    if (-not (Test-Path -LiteralPath (Join-Path $RestoreFrom 'db.sqlite3'))) {
        Stop-Install ("복원할 백업 폴더에 db.sqlite3 가 없습니다: $RestoreFrom`n" +
            '    Google Drive(G:)는 관리자 PowerShell 에서 안 보일 수 있습니다. 백업 날짜 폴더를 먼저 C:\ 아래로 복사해 그 경로를 넣으세요.')
    }
    if (Test-Path -LiteralPath (Join-Path $dataDir 'db.sqlite3')) {
        Stop-Install "이미 금고 데이터가 있어 덮어쓰지 않습니다: $dataDir`n    정말 바꾸려면 data 폴더 이름을 바꾼 뒤 다시 실행하세요."
    }
}

# ------------------------------------------------------------------ 1. DNS 확인
if (-not $TestMode -and -not $SkipDnsCheck) {
    Write-Step "DNS 확인: $Domain"
    $lanIp = Get-LanIPv4
    $label = Get-HostLabel $Domain
    $wantCname = "$DuckDnsName.duckdns.org"
    $aRec = @(Resolve-Record $Domain 'A' | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
    $cRec = @(Resolve-Record "_acme-challenge.$Domain" 'CNAME' | Where-Object { $_.Type -eq 'CNAME' } | ForEach-Object { $_.NameHost.TrimEnd('.').ToLowerInvariant() })
    $problems = @()
    if ($aRec.Count -eq 0) { $problems += "A 레코드가 없습니다: $Domain" }
    elseif ($lanIp -and ($aRec -notcontains $lanIp)) { $problems += "A 레코드($($aRec -join ', '))가 이 PC 주소($lanIp)와 다릅니다." }
    if ($cRec -notcontains $wantCname) {
        $now = if ($cRec.Count) { $cRec -join ', ' } else { '없음' }
        $problems += "_acme-challenge.$Domain CNAME 이 $wantCname 이 아닙니다 (지금: $now)."
    }
    if ($problems.Count) {
        $problems | ForEach-Object { Write-Warn $_ }
        $ipText = if ($lanIp) { $lanIp } else { '<이 PC 내부 IP>' }
        Write-Host ''
        Write-Host '    가비아 DNS 관리툴에 아래 두 레코드를 넣고, 몇 분 뒤 다시 실행하세요.'
        Write-Host ('    타입 A      호스트 {0,-26} 값 {1}' -f $label, $ipText)
        Write-Host ('    타입 CNAME  호스트 {0,-26} 값 {1}.' -f "_acme-challenge.$label", $wantCname)
        Write-Host '    호스트 칸에는 도메인을 붙이지 않고, CNAME 값 끝에는 점(.)을 붙입니다.'
        Write-Host '    A 레코드가 일부러 다른 IP라면 -SkipDnsCheck 를 붙여 실행합니다.'
        exit 2
    }
    Write-Info "A $($aRec -join ', ') / _acme-challenge → $wantCname"
}

# ------------------------------------------------------------------ 2. DuckDNS token
$caddyEnvPath = Join-Path $InstallDir 'caddy.env'
$vwEnvPath = Join-Path $InstallDir '.env'
if (-not $DuckDnsToken) { $DuckDnsToken = Read-EnvValue $caddyEnvPath 'DUCKDNS_API_TOKEN' }
if (-not $DuckDnsToken) {
    Write-Step 'DuckDNS token 입력'
    $sec = Read-Host -AsSecureString '    duckdns.org 화면 위쪽의 token 을 붙여 넣고 Enter (화면에 안 보임)'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $DuckDnsToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
$DuckDnsToken = "$DuckDnsToken".Trim()
if ($DuckDnsToken -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
    Stop-Install 'DuckDNS token 형식이 아닙니다 (8-4-4-4-12 자리 형태). 다시 복사해 주세요.'
}
if (-not $TestMode) {
    $ok = $false
    try {
        $resp = Invoke-RestMethod -UseBasicParsing -TimeoutSec 20 -Uri ('https://www.duckdns.org/update?domains={0}&token={1}&ip=127.0.0.1' -f $DuckDnsName, $DuckDnsToken)
        $ok = ("$resp".Trim() -eq 'OK')
    } catch { }
    if (-not $ok) { Stop-Install "DuckDNS 가 token 또는 이름($DuckDnsName)을 받아들이지 않았습니다. duckdns.org 화면의 token 과 sub domain 을 확인하세요." }
    Write-Info "DuckDNS $DuckDnsName.duckdns.org 확인 (IP 는 127.0.0.1 로 둠)"
}

# ------------------------------------------------------------------ 3. 프로그램 받기
Write-Step "프로그램 받기 (Vaultwarden $Version)"
$info = Get-VersionInfo $Version
$stage = Join-Path $env:TEMP ('vw-kit-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    $vwSrc = if ($VaultwardenExe) { $VaultwardenExe } else { "https://github.com/$ReleaseRepo/releases/download/$Version-windows/vaultwarden-$Version-windows-x64.exe" }
    $vwSha = if ($VaultwardenExe) { '' } else { $info.VwSha }
    if (-not $VaultwardenExe) {
        $probe = Invoke-Exe $CurlExe @('-fsSL', '-r', '0-0', '-o', 'NUL', $vwSrc) -AllowFail
        if ($probe.Code -ne 0) {
            Stop-Install ("Vaultwarden $Version 의 Windows 빌드가 아직 없습니다.`n" +
                "    GitHub $ReleaseRepo → Actions → Build and Release Vaultwarden Windows Binary → Run workflow 로 만든 뒤 다시 실행하세요.")
        }
    }
    Get-Download $vwSrc (Join-Path $stage 'vaultwarden.exe') $vwSha
    $wvFile = Join-Path $stage 'web-vault.tar.gz'
    Get-Download "https://github.com/dani-garcia/bw_web_builds/releases/download/$($info.WebVault)/bw_web_$($info.WebVault).tar.gz" $wvFile $info.WebVaultSha
    Get-Download $WinSwUrl (Join-Path $stage 'winsw.exe') $WinSwSha
    $caddySrc = if ($CaddyExe) { $CaddyExe } else { $CaddyUrl }
    Get-Download $caddySrc (Join-Path $stage 'caddy.exe') ''

    Invoke-Exe $TarExe @('-xzf', $wvFile, '-C', $stage) | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'web-vault\index.html'))) { Stop-Install '웹 금고 압축을 풀지 못했습니다.' }
    $mods = Invoke-Exe (Join-Path $stage 'caddy.exe') @('list-modules') -AllowFail
    if ($mods.Out -notmatch 'dns\.providers\.duckdns') { Stop-Install 'caddy.exe 에 DuckDNS 플러그인이 없습니다. -CaddyExe 로 플러그인이 든 파일을 지정하세요.' }
    $cv = Invoke-Exe (Join-Path $stage 'caddy.exe') @('version') -AllowFail
    Write-Info "caddy $(@($cv.Out -split "`n")[0]) / 웹 금고 $($info.WebVault)"

    # -------------------------------------------------------------- 4. 관리자 비밀번호
    if (-not $AdminTokenHash) { $AdminTokenHash = Read-EnvValue $vwEnvPath 'ADMIN_TOKEN' }
    if (-not $AdminTokenHash) {
        Write-Step '관리자 페이지 비밀번호 정하기'
        Write-Info '8자 이상으로 두 번 입력합니다. 화면에 표시되지 않습니다. 금고가 완성되면 이 비밀번호를 금고에 보관하세요.'
        for ($i = 0; $i -lt 3 -and -not $AdminTokenHash; $i++) {
            $h = Invoke-Exe (Join-Path $stage 'vaultwarden.exe') @('hash') -AllowFail
            $m = [regex]::Match($h.Out, "ADMIN_TOKEN='([^']+)'")
            if ($m.Success) { $AdminTokenHash = $m.Groups[1].Value } else { Write-Warn ($h.Out -replace "`n", ' ') }
        }
        if (-not $AdminTokenHash) { Stop-Install '관리자 비밀번호를 정하지 못했습니다. 일반 PowerShell 창(ISE 아님)에서 다시 실행하세요.' }
    }
    if ($AdminTokenHash -notmatch '^\$argon2id\$') { Write-Warn '관리자 토큰이 argon2id 해시가 아닙니다. 그대로 쓰지만 해시로 바꾸는 것을 권장합니다.' }

    # -------------------------------------------------------------- 5. 업데이트 전 백업, 기존 서비스 정리
    # 443번을 다른 프로그램이 쓰고 있으면 기존 서비스를 건드리기 전에 멈춥니다
    $ourCaddy = Join-Path $InstallDir 'caddy.exe'
    foreach ($l in @(Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue)) {
        $proc = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
        if (-not $proc -or $proc.Path -ne $ourCaddy) {
            $pname = if ($proc) { $proc.ProcessName } else { "PID $($l.OwningProcess)" }
            Stop-Install "443번 포트를 다른 프로그램($pname)이 쓰고 있습니다. 그 프로그램을 끄거나 설정을 바꾼 뒤 다시 실행하세요."
        }
    }
    $backupPs1 = Join-Path $InstallDir 'backup.ps1'
    if ((Test-Path -LiteralPath $backupPs1) -and (Test-Path -LiteralPath (Join-Path $dataDir 'db.sqlite3')) -and
        (Get-Service -Name $SvcVw -ErrorAction SilentlyContinue)) {
        Write-Step '바꾸기 전에 백업'
        $b = Invoke-Exe $PsExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backupPs1) -AllowFail
        if ($b.Code -ne 0) { Stop-Install "업데이트 전 백업이 실패해 멈춥니다. $InstallDir\backups\backup.log 를 확인하세요." }
        Write-Info "백업 완료: $InstallDir\backups"
    }
    Write-Step '기존 서비스 정리'
    Remove-KitService $SvcCaddy (Join-Path $InstallDir 'caddy-service.exe')
    Remove-KitService $SvcVw (Join-Path $InstallDir 'vaultwarden-service.exe')

    $VwPort = $null
    foreach ($p in 8000, 8090, 18000, 28000, 38000) {
        if (Test-PortFree ([System.Net.IPAddress]::Loopback) $p) { $VwPort = $p; break }
    }
    if (-not $VwPort) { Stop-Install 'Vaultwarden 이 쓸 내부 포트를 찾지 못했습니다 (8000, 8090, 18000, 28000, 38000 모두 사용 중).' }

    # -------------------------------------------------------------- 6. 파일 배치
    Write-Step "설치 폴더: $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    # 관리자와 SYSTEM 만 접근 (서비스가 SYSTEM 으로 돌므로 실행 파일을 바꿔치기하지 못하게)
    Invoke-Exe 'icacls.exe' @($InstallDir, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F') | Out-Null
    Copy-Item -LiteralPath (Join-Path $stage 'vaultwarden.exe') -Destination $InstallDir -Force
    Copy-Item -LiteralPath (Join-Path $stage 'caddy.exe') -Destination $InstallDir -Force
    Copy-Item -LiteralPath (Join-Path $stage 'winsw.exe') -Destination (Join-Path $InstallDir 'vaultwarden-service.exe') -Force
    Copy-Item -LiteralPath (Join-Path $stage 'winsw.exe') -Destination (Join-Path $InstallDir 'caddy-service.exe') -Force
    $wvDir = Join-Path $InstallDir 'web-vault'
    if (Test-Path -LiteralPath $wvDir) { Remove-Item -LiteralPath $wvDir -Recurse -Force }
    Move-Item -LiteralPath (Join-Path $stage 'web-vault') -Destination $wvDir
    Get-ChildItem -LiteralPath $InstallDir -Filter *.exe | Unblock-File
    Write-Info 'vaultwarden.exe, caddy.exe, web-vault, 서비스 래퍼(WinSW) 배치'

    if ($RestoreFrom) {
        Write-Step "백업에서 복원: $RestoreFrom"
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        Get-ChildItem -LiteralPath $RestoreFrom | Copy-Item -Destination $dataDir -Recurse -Force
        Write-Info '금고 데이터 복원 완료'
    }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ 7. 설정 파일
Write-Step '설정 파일 쓰기'
$managed = [ordered]@{
    'DOMAIN'             = "https://$Domain"
    'ROCKET_ADDRESS'     = '127.0.0.1'
    'ROCKET_PORT'        = "$VwPort"
    'SIGNUPS_ALLOWED'    = 'false'
    'ORG_EVENTS_ENABLED' = 'true'
    'ORG_GROUPS_ENABLED' = 'true'
    'ADMIN_TOKEN'        = "'$AdminTokenHash'"
}
$keep = @()
if (Test-Path -LiteralPath $vwEnvPath) {
    # 직접 추가한 설정(예: 메일 SMTP_*)은 그대로 둡니다
    $keep = @([System.IO.File]::ReadAllLines($vwEnvPath) | Where-Object {
            $k = ($_ -split '=', 2)[0].Trim()
            $_.Trim() -and -not $managed.Contains($k) -and $_ -notlike '# install.ps1*'
        })
}
$envLines = @('# install.ps1 이 관리하는 값입니다. 아래쪽에 직접 추가한 설정은 다시 설치해도 남습니다.')
foreach ($k in $managed.Keys) { $envLines += "$k=$($managed[$k])" }
$envLines += $keep
Write-TextFile $vwEnvPath (($envLines -join "`n") + "`n")
Write-TextFile $caddyEnvPath "DUCKDNS_API_TOKEN=$DuckDnsToken`n"

$caddyProd = @"
{
	auto_https disable_redirects
}

$Domain {
	tls {
		dns duckdns {env.DUCKDNS_API_TOKEN} {
			override_domain $DuckDnsName.duckdns.org
		}
	}
	reverse_proxy 127.0.0.1:$VwPort {
		header_up X-Real-IP {remote_host}
	}
}
"@
$caddyProd = $caddyProd.Replace("`r`n", "`n")
$caddyFile = Join-Path $InstallDir 'Caddyfile'
$caddy = Join-Path $InstallDir 'caddy.exe'
$env:XDG_DATA_HOME = Join-Path $InstallDir 'caddy-data'
$env:XDG_CONFIG_HOME = Join-Path $InstallDir 'caddy-config'
Write-TextFile $caddyFile $caddyProd
$v = Invoke-Exe $caddy @('validate', '--config', $caddyFile, '--envfile', $caddyEnvPath) -AllowFail
if ($v.Code -ne 0) { Stop-Install "Caddyfile 검사 실패:`n$($v.Out)" }
if ($TestMode) {
    # CI 전용: DuckDNS 설정 검사는 위에서 끝냈고, 실제 실행은 Caddy 자체 인증서로 합니다
    Write-TextFile $caddyFile ($caddyProd -replace '(?s)\ttls \{.*?\n\t\}\n', "`ttls internal`n")
    $v = Invoke-Exe $caddy @('validate', '--config', $caddyFile, '--envfile', $caddyEnvPath) -AllowFail
    if ($v.Code -ne 0) { Stop-Install "테스트용 Caddyfile 검사 실패:`n$($v.Out)" }
}
Write-Info ".env, caddy.env, Caddyfile (Vaultwarden 내부 포트 $VwPort)"

$vwXml = @"
<service>
  <id>$SvcVw</id>
  <name>Vaultwarden</name>
  <description>Vaultwarden password server (office LAN only)</description>
  <executable>$InstallDir\vaultwarden.exe</executable>
  <workingdirectory>$InstallDir</workingdirectory>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
</service>
"@
$caddyXml = @"
<service>
  <id>$SvcCaddy</id>
  <name>Vaultwarden HTTPS (Caddy)</name>
  <description>HTTPS for Vaultwarden (office LAN only)</description>
  <executable>$InstallDir\caddy.exe</executable>
  <arguments>run --config "$caddyFile" --envfile "$caddyEnvPath"</arguments>
  <workingdirectory>$InstallDir</workingdirectory>
  <env name="XDG_DATA_HOME" value="$InstallDir\caddy-data"/>
  <env name="XDG_CONFIG_HOME" value="$InstallDir\caddy-config"/>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
</service>
"@
Write-TextFile (Join-Path $InstallDir 'vaultwarden-service.xml') $vwXml
Write-TextFile (Join-Path $InstallDir 'caddy-service.xml') $caddyXml

# ------------------------------------------------------------------ 8. 서비스 등록·시작
Write-Step '서비스 등록·시작'
Invoke-Exe (Join-Path $InstallDir 'vaultwarden-service.exe') @('install') | Out-Null
Invoke-Exe (Join-Path $InstallDir 'caddy-service.exe') @('install') | Out-Null
Start-Service -Name $SvcVw
if (-not (Wait-Http "http://127.0.0.1:$VwPort/alive" @() 120)) {
    Show-LogTail (Join-Path $InstallDir 'vaultwarden-service.out.log')
    Show-LogTail (Join-Path $InstallDir 'vaultwarden-service.err.log')
    Stop-Install 'Vaultwarden 이 응답하지 않습니다. 위 로그를 확인하세요.'
}
Write-Info "Vaultwarden 응답 확인 (127.0.0.1:$VwPort)"
Start-Service -Name $SvcCaddy

Get-NetFirewallRule -DisplayName $FwRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $FwRule -Direction Inbound -Protocol TCP -LocalPort 443 -RemoteAddress LocalSubnet `
    -Program $caddy -Action Allow -Profile Any | Out-Null
Write-Info '방화벽: 같은 사내 네트워크에서 오는 443번만 허용 (공유기 포트포워딩 없음)'

# ------------------------------------------------------------------ 9. 백업 예약 작업
Write-Step '백업 설정'
$backupDir = Join-Path $InstallDir 'backups'
$copyDir = Join-Path $InstallDir 'drive-copy'
New-Item -ItemType Directory -Force -Path $backupDir, $copyDir | Out-Null

$backupScript = @'
# Vaultwarden 백업. 예약 작업 "Vaultwarden Backup" 이 SYSTEM 권한으로 매일 03:00 에 실행합니다 (install.ps1 이 만듦).
$ErrorActionPreference = 'Stop'
$InstallDir = '__INSTALL_DIR__'
$Local = Join-Path $InstallDir 'backups'
$LogFile = Join-Path $Local 'backup.log'
function Write-Log([string]$m) { Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format s), $m) -Encoding UTF8 }
try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dst = Join-Path $Local $stamp
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $out = Join-Path $Local ".vw-backup-$stamp.out"
    $p = Start-Process -FilePath (Join-Path $InstallDir 'vaultwarden.exe') -ArgumentList 'backup' -WorkingDirectory $InstallDir `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $text = ((Get-Content -LiteralPath $out -Raw), (Get-Content -LiteralPath "$out.err" -Raw)) -join "`n"
    Remove-Item -LiteralPath $out, "$out.err" -Force -ErrorAction SilentlyContinue
    $m = [regex]::Match($text, "Backup to '(.+?)' was successful")
    if ($p.ExitCode -ne 0 -or -not $m.Success) { throw "vaultwarden backup 실패: $text" }
    $file = $m.Groups[1].Value
    if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path $InstallDir $file }
    Move-Item -LiteralPath $file -Destination (Join-Path $dst 'db.sqlite3')
    foreach ($name in 'rsa_key.pem', 'rsa_key.der', 'rsa_key.pub.der', 'config.json', 'attachments', 'sends') {
        $src = Join-Path (Join-Path $InstallDir 'data') $name
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force }
    }
    # 최신 7개는 항상 남기고, 그 밖에 30일 지난 것만 지움
    $limit = (Get-Date).AddDays(-30).ToString('yyyyMMdd')
    Get-ChildItem -LiteralPath $Local -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
        Sort-Object Name -Descending | Select-Object -Skip 7 |
        Where-Object { $_.Name.Substring(0, 8) -lt $limit } | Remove-Item -Recurse -Force
    Write-Log "OK $stamp"
} catch {
    Write-Log "FAIL $($_.Exception.Message)"
    exit 1
}
'@
Write-TextFile $backupPs1 $backupScript.Replace('__INSTALL_DIR__', $InstallDir.Replace("'", "''")) -Bom

$psArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName $TaskBackup -Force `
    -Action (New-ScheduledTaskAction -Execute $PsExe -Argument ($psArgs -f $backupPs1)) `
    -Trigger (New-ScheduledTaskTrigger -Daily -At '03:00') `
    -Principal (New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest) `
    -Settings $settings | Out-Null
Write-Info "매일 03:00 PC 안에 백업 → $backupDir (최신 7개는 항상, 그 밖은 30일 보관)"

if ($BackupRoot) {
    $copyScript = @'
# PC 안의 백업을 Google Drive 등 바깥 폴더로 복사합니다.
# 예약 작업 "Vaultwarden Backup Copy" 가 로그인한 사용자 권한으로 매일 03:15 와 로그인 5분 뒤에 실행합니다 (install.ps1 이 만듦).
$ErrorActionPreference = 'Stop'
$Src = '__BACKUP_DIR__'
$Dst = '__BACKUP_ROOT__'
$LogDir = Join-Path $env:LOCALAPPDATA 'VaultwardenBackupCopy'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir 'copy.log'
function Write-Log([string]$m) { Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format s), $m) -Encoding UTF8 }
try {
    if ($Dst -match '^[A-Za-z]:' -and -not (Test-Path -LiteralPath ($Dst.Substring(0, 2) + '\'))) {
        throw "드라이브 $($Dst.Substring(0, 2)) 가 없습니다. Google Drive 가 켜져 있는지 확인하세요."
    }
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    $out = & robocopy.exe $Src $Dst /E /R:2 /W:5 /NP /NFL /NDL /NJH /NJS /XF backup.log .vw-backup-*
    if ($LASTEXITCODE -ge 8) { throw "robocopy 실패 ($LASTEXITCODE): $($out -join ' ')" }
    $limit = (Get-Date).AddDays(-30).ToString('yyyyMMdd')
    Get-ChildItem -LiteralPath $Dst -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
        Sort-Object Name -Descending | Select-Object -Skip 7 |
        Where-Object { $_.Name.Substring(0, 8) -lt $limit } | Remove-Item -Recurse -Force
    Write-Log 'OK'
    exit 0
} catch {
    Write-Log "FAIL $($_.Exception.Message)"
    exit 1
}
'@
    $copyPs1 = Join-Path $copyDir 'copy-to-drive.ps1'
    $copyText = $copyScript.Replace('__BACKUP_DIR__', $backupDir.Replace("'", "''")).Replace('__BACKUP_ROOT__', $BackupRoot.Replace("'", "''"))
    Write-TextFile $copyPs1 $copyText -Bom
    foreach ($d in @($backupDir, $copyDir)) { Invoke-Exe 'icacls.exe' @($d, '/grant', "${DriveCopyUser}:(OI)(CI)RX") | Out-Null }
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $DriveCopyUser
    $logon.Delay = 'PT5M'
    Register-ScheduledTask -TaskName $TaskCopy -Force `
        -Action (New-ScheduledTaskAction -Execute $PsExe -Argument (('-WindowStyle Hidden ' + $psArgs) -f $copyPs1)) `
        -Trigger @((New-ScheduledTaskTrigger -Daily -At '03:15'), $logon) `
        -Principal (New-ScheduledTaskPrincipal -UserId $DriveCopyUser -LogonType Interactive -RunLevel Limited) `
        -Settings $settings | Out-Null
    Write-Info "매일 03:15 와 로그인 5분 뒤 바깥 폴더로 복사 → $BackupRoot ($DriveCopyUser 권한)"
} else {
    if (Get-ScheduledTask -TaskName $TaskCopy -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $TaskCopy -Confirm:$false }
    Write-Warn '-BackupRoot 가 없어 바깥 복사는 설정하지 않았습니다. PC 디스크가 고장 나면 백업도 함께 사라집니다.'
}

# ------------------------------------------------------------------ 10. HTTPS 확인
Write-Step "HTTPS 확인: https://$Domain"
$tlsArgs = @('--resolve', "${Domain}:443:127.0.0.1", '--ssl-no-revoke')
if ($TestMode) { $tlsArgs += '-k' } else { Write-Info '인증서 발급에 1~2분 걸릴 수 있습니다.' }
$httpsOk = Wait-Http "https://$Domain/alive" $tlsArgs 240
if (-not $httpsOk) {
    Show-LogTail (Join-Path $InstallDir 'caddy-service.err.log')
    Write-Warn '아직 HTTPS 로 응답하지 않습니다. Caddy 는 계속 다시 시도합니다.'
    Write-Warn '가비아 CNAME(값 끝의 점 포함)과 DuckDNS token 을 확인하고, 몇 분 뒤 다른 PC에서 주소를 열어 보세요.'
    exit 3
}
Write-Info 'HTTPS 응답 확인'

Write-Host ''
Write-Host '설치 완료' -ForegroundColor Green
Write-Info "금고 주소      https://$Domain"
Write-Info "관리자 페이지  https://$Domain/admin  (방금 정한 관리자 비밀번호)"
Write-Info "설치 폴더      $InstallDir  (서비스: $SvcVw, $SvcCaddy)"
Write-Info '다음: 다른 사무실 PC에서 금고 주소가 열리는지 보고, 관리자 페이지에서 첫 사용자를 초대하세요.'
exit 0
