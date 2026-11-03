#Requires -Version 5.1
<#
.SYNOPSIS
    install.ps1 이 만든 서비스, 예약 작업, 방화벽 규칙을 지웁니다.
    금고 데이터와 설정 파일(설치 폴더)은 지우지 않습니다. 폴더까지 지우려면 확인 후 직접 지우세요.
#>
[CmdletBinding()]
param([string]$InstallDir = 'C:\vaultwarden')

$ErrorActionPreference = 'Stop'

function Invoke-Exe([string]$FilePath, [string[]]$ArgumentList) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $FilePath @ArgumentList 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '관리자 권한 PowerShell 에서 실행하세요.' -ForegroundColor Red
    exit 1
}

foreach ($svc in @(@('vaultwarden-caddy', 'caddy-service'), @('vaultwarden', 'vaultwarden-service'))) {
    $s = Get-Service -Name $svc[0] -ErrorAction SilentlyContinue
    if (-not $s) { continue }
    if ($s.Status -ne 'Stopped') { Stop-Service -Name $svc[0] -Force }
    $wrapper = Join-Path $InstallDir "$($svc[1]).exe"
    if (Test-Path -LiteralPath $wrapper) { Invoke-Exe $wrapper @('uninstall') } else { Invoke-Exe 'sc.exe' @('delete', $svc[0]) }
    for ($i = 0; $i -lt 30 -and (Get-Service -Name $svc[0] -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
    Write-Host "서비스 삭제: $($svc[0])"
}
foreach ($task in 'Vaultwarden Backup', 'Vaultwarden Backup Copy') {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
        Write-Host "예약 작업 삭제: $task"
    }
}
Get-NetFirewallRule -DisplayName 'Vaultwarden HTTPS (office LAN)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Write-Host "완료. 금고 데이터와 설정은 $InstallDir 에 남아 있습니다."
exit 0
