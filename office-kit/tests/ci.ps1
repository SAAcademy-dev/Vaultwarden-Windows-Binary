# CI 전용: GitHub Actions Windows 러너에서 install.ps1 / uninstall.ps1 을 처음부터 끝까지 돌려 봅니다.
# 실제 인증서 대신 Caddy 자체 인증서(-TestMode)를 쓰고, 나머지(서비스, 방화벽, 백업, 복사, 재설치, 복원)는 실제와 같습니다.
param(
    [string]$VaultwardenExe = '',   # 비우면 install.ps1 기본값(이 저장소 릴리스 + 고정 체크섬)
    [Parameter(Mandatory = $true)][string]$AdminHash,
    [Parameter(Mandatory = $true)][string]$AdminPassword
)
$ErrorActionPreference = 'Stop'

$Domain = 'vault.kit-test.local'
$Kit = Split-Path -Parent $PSScriptRoot
$Install = 'C:\vaultwarden'
$Ko = -join ([char[]](0xBC31, 0xC5C5, 0x20, 0xD14C, 0xC2A4, 0xD2B8))   # 한글 경로 확인용 (BOM 없는 스크립트면 깨짐)
$DriveRoot = "C:\$Ko\vw"
$Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$Ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Email = 'kit-test@example.com'
$Me = "$env:USERDOMAIN\$env:USERNAME"

function Check([bool]$Cond, [string]$Msg) {
    if (-not $Cond) { throw "FAIL: $Msg" }
    Write-Host "  ok - $Msg" -ForegroundColor Green
}
function Invoke-Curl([string[]]$A) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $o = & $Curl @A 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
    (@($o) -join "`n").Trim()
}
function Invoke-Https([string]$Path, [string[]]$Extra = @()) {
    Invoke-Curl (@('-sk', '--resolve', "${Domain}:443:127.0.0.1") + $Extra + @("https://$Domain$Path"))
}
function Invoke-Install([string[]]$Extra) {
    $base = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Kit 'install.ps1'),
        '-Domain', $Domain, '-DuckDnsName', 'kit-test', '-TestMode', '-BackupRoot', $DriveRoot,
        '-DriveCopyUser', $Me)
    if ($VaultwardenExe) { $base += @('-VaultwardenExe', $VaultwardenExe) }
    & $Ps @($base + $Extra)
    Check ($LASTEXITCODE -eq 0) "install.ps1 종료 코드 0 ($($Extra -join ' ' -replace '\$argon2id\$\S+', '<hash>'))"
}
function Connect-Admin {
    $jar = Join-Path $env:TEMP ('jar-' + [guid]::NewGuid().ToString('N') + '.txt')
    $code = Invoke-Https '/admin' @('-o', 'NUL', '-w', '%{http_code}', '-c', $jar, '--data-urlencode', "token=$AdminPassword")
    # 리다이렉트 값 없이 로그인하면 Vaultwarden 은 200 + 관리자 화면 + 쿠키를 돌려줍니다 (틀리면 401)
    Check ($code -eq '200') "관리자 로그인 → 200 (받은 값 $code)"
    Check ((Get-Content -LiteralPath $jar -Raw) -match 'VW_ADMIN') '관리자 쿠키 발급'
    return $jar
}
function Get-InvitedCount([string]$Jar) {
    $users = (Invoke-Https '/admin/users' @('-b', $Jar)) | ConvertFrom-Json
    return @($users | Where-Object { $_.email -eq $Email }).Count
}
function Wait-Task([string]$Name, [datetime]$Since) {
    $deadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 3
        $t = Get-ScheduledTask -TaskName $Name
        $i = Get-ScheduledTaskInfo -TaskName $Name
    } while (($t.State -eq 'Running' -or $i.LastRunTime -lt $Since) -and (Get-Date) -lt $deadline)
    return $i
}

Write-Host '[1] 처음 설치'
Invoke-Install @('-AdminTokenHash', $AdminHash, '-DuckDnsToken', '00000000-0000-0000-0000-000000000000')
foreach ($s in 'vaultwarden', 'vaultwarden-caddy') {
    $svc = Get-Service -Name $s
    Check ($svc.Status -eq 'Running') "$s 서비스 실행 중"
    Check ($svc.StartType -eq 'Automatic') "$s 자동 시작"
}
Check ((Invoke-Https '/alive' @('-o', 'NUL', '-w', '%{http_code}')) -eq '200') 'HTTPS /alive → 200'
Check ((Invoke-Https '/') -match '<html') '웹 금고 화면 응답'
$vwPort = [int]((Get-Content -LiteralPath "$Install\.env" | Where-Object { $_ -like 'ROCKET_PORT=*' }) -replace 'ROCKET_PORT=', '')
$listen = @(Get-NetTCPConnection -LocalPort $vwPort -State Listen)
Check ($listen.Count -gt 0 -and -not ($listen | Where-Object { $_.LocalAddress -ne '127.0.0.1' })) "Vaultwarden 은 127.0.0.1:$vwPort 에서만 받음"
$caddyIds = @(Get-Process -Name caddy | ForEach-Object { $_.Id })
Check (@(Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue | Where-Object { $caddyIds -contains $_.OwningProcess }).Count -eq 0) 'Caddy 가 80번을 열지 않음'
$filter = Get-NetFirewallRule -DisplayName 'Vaultwarden HTTPS (office LAN)' | Get-NetFirewallAddressFilter
Check (@($filter.RemoteAddress) -contains 'LocalSubnet') '방화벽: 같은 네트워크(LocalSubnet)만 허용'
Check ([System.IO.File]::ReadAllBytes("$Install\.env")[0] -ne 0xEF) '.env 에 BOM 없음'
Check ([System.IO.File]::ReadAllBytes("$Install\backup.ps1")[0] -eq 0xEF) 'backup.ps1 은 BOM 있는 UTF-8'
Check ((Get-ScheduledTask -TaskName 'Vaultwarden Backup').Principal.UserId -match 'SYSTEM') '백업 작업은 SYSTEM 권한'
Check (@((Get-ScheduledTask -TaskName 'Vaultwarden Backup Copy').Triggers).Count -eq 2) '복사 작업: 매일 + 로그인 트리거'
$acl = (Get-Acl -LiteralPath "$Install\backups").Access | Where-Object { $_.IdentityReference -like "*\$env:USERNAME" }
Check ($null -ne $acl) '백업 폴더: 복사 담당 사용자 읽기 권한'

Write-Host '[2] 관리자 로그인, 사용자 초대'
$jar = Connect-Admin
$invite = Join-Path $env:TEMP 'invite.json'
[System.IO.File]::WriteAllText($invite, ('{"email":"' + $Email + '"}'))
$res = Invoke-Https '/admin/invite' @('-b', $jar, '-H', 'Content-Type: application/json', '--data-binary', "@$invite")
Check ($res -match [regex]::Escape($Email)) '관리자 초대로 사용자 생성'
Check ((Get-InvitedCount $jar) -eq 1) '사용자 목록에 있음'

Write-Host '[3] 백업 (SYSTEM 예약 작업)'
$t0 = (Get-Date).AddSeconds(-2)
Start-ScheduledTask -TaskName 'Vaultwarden Backup'
$info = Wait-Task 'Vaultwarden Backup' $t0
Check ($info.LastTaskResult -eq 0) "백업 작업 결과 0 (받은 값 $($info.LastTaskResult))"
$latest = Get-ChildItem -LiteralPath "$Install\backups" -Directory | Sort-Object Name -Descending | Select-Object -First 1
Check ($null -ne $latest) "백업 폴더 생성 ($($latest.Name))"
Check ((Get-Item -LiteralPath (Join-Path $latest.FullName 'db.sqlite3')).Length -gt 0) '백업에 db.sqlite3'
Check (Test-Path -LiteralPath (Join-Path $latest.FullName 'rsa_key.pem')) '백업에 rsa_key.pem'

Write-Host '[4] 바깥 폴더로 복사 (한글 경로)'
& $Ps -NoProfile -ExecutionPolicy Bypass -File "$Install\drive-copy\copy-to-drive.ps1"
Check ($LASTEXITCODE -eq 0) 'copy-to-drive.ps1 종료 코드 0'
$copied = Join-Path $DriveRoot $latest.Name
Check (Test-Path -LiteralPath (Join-Path $copied 'db.sqlite3')) "한글 경로로 복사됨"

Write-Host '[5] 다시 설치 (업데이트 경로, 저장된 비밀값 재사용)'
Invoke-Install @()
$jar = Connect-Admin
Check ((Get-InvitedCount $jar) -eq 1) '다시 설치 후에도 사용자 유지'
Check (@(Get-Content -LiteralPath "$Install\.env" | Where-Object { $_ -like '# install.ps1*' }).Count -eq 1) '.env 머리 주석이 쌓이지 않음'

Write-Host '[6] 재해 복구: 서비스 지우고 데이터 없앤 뒤 바깥 폴더 백업에서 복원'
& $Ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Kit 'uninstall.ps1')
Check ($LASTEXITCODE -eq 0) 'uninstall.ps1 종료 코드 0'
Check (-not (Get-Service -Name 'vaultwarden' -ErrorAction SilentlyContinue)) '서비스 삭제됨'
Rename-Item -LiteralPath "$Install\data" -NewName 'data.lost'
Invoke-Install @('-RestoreFrom', $copied)
$jar = Connect-Admin
Check ((Get-InvitedCount $jar) -eq 1) '복원 후 사용자 있음'

Write-Host ''
Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
