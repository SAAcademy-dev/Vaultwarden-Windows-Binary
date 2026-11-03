# office-kit: 사무실 윈도우 PC용 Vaultwarden 설치 스크립트

사무실 안에서만 쓰는 비밀번호 금고를 윈도우 PC 한 대에 설치합니다.

- **Vaultwarden과 Caddy를 윈도우 서비스로 등록합니다.** PC가 켜지면 Windows에 로그인하지 않아도 자동으로 돌아갑니다.
- **인터넷 쪽 포트는 열지 않습니다.** 방화벽은 같은 사내 네트워크에서 오는 443번만 허용합니다.
- **인증서는 Let's Encrypt DNS-01 방식입니다.**
  - 도메인 DNS 업체에 API가 없어도 됩니다.
  - `_acme-challenge` 레코드 하나를 [DuckDNS](https://www.duckdns.org/)로 넘기면(CNAME) Caddy가 인증서를 받고 자동으로 갱신합니다.
- **백업은 두 단계입니다.**
  - 매일 03:00 SYSTEM 권한으로 `C:\vaultwarden\backups`에 백업합니다.
  - `-BackupRoot`를 주면 로그인한 사용자 권한으로 그 폴더(예: Google Drive)에 복사합니다.
  - 두 단계로 나눈 이유: Google Drive 드라이브 문자(G:)는 관리자 권한 프로그램에서 안 보일 수 있습니다.

`vaultwarden.exe`는 이 저장소의 Actions가 공식 소스(dani-garcia/vaultwarden 릴리스 태그)를 Windows로 빌드한 파일입니다. Vaultwarden은 Windows를 공식 지원하지 않습니다.

## 준비

1. **이 PC의 내부 IP를 공유기에서 고정합니다.** 공유기의 DHCP 주소 예약 메뉴에서 합니다.
2. **duckdns.org에서 이름 하나를 만들고 token을 복사해 둡니다.** 예: `example-vault`
3. **도메인 DNS에 레코드 두 개를 추가합니다.** 가비아라면 호스트 칸에 도메인을 붙이지 않고, CNAME 값 끝에 점(.)을 붙입니다.

   | 타입 | 호스트 | 값 |
   |---|---|---|
   | A | `vault` | 이 PC 내부 IP |
   | CNAME | `_acme-challenge.vault` | `example-vault.duckdns.org.` |

## 설치

관리자 권한 Windows PowerShell(ISE 아님)에서 실행합니다. 스크립트를 메모장에 붙여 넣어 저장하지 말고, 아래 명령으로 받으세요. 한글이 깨지지 않게 하려면 그대로 받아야 합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
$k = "$env:TEMP\office-kit"; New-Item -ItemType Directory -Force $k | Out-Null
foreach ($f in 'install.ps1','uninstall.ps1') { Invoke-WebRequest -UseBasicParsing -OutFile "$k\$f" "https://raw.githubusercontent.com/SAAcademy-dev/Vaultwarden-Windows-Binary/main/office-kit/$f" }
& "$k\install.ps1" -Domain vault.example.co.kr -DuckDnsName example-vault -BackupRoot "G:\내 드라이브\vaultwarden-backup"
```

스크립트가 차례로 하는 일입니다.
1. DNS 레코드를 확인합니다. 없으면 넣어야 할 값을 보여 주고 멈춥니다(종료 코드 2).
2. DuckDNS token을 입력받습니다.
3. 관리자 페이지 비밀번호를 두 번 입력받습니다.
4. 설치하고, 마지막에 HTTPS 응답을 확인합니다.

| 종료 코드 | 뜻 |
|---|---|
| 0 | 완료 |
| 1 | 오류로 중단 |
| 2 | DNS 레코드를 먼저 넣어야 함 |
| 3 | 설치는 됐지만 아직 HTTPS 응답이 없음. Caddy가 계속 다시 시도합니다 |

## 다시 실행·업데이트·복원

- **같은 명령을 다시 실행하면** 금고 데이터와 저장된 비밀값은 그대로 두고 프로그램과 설정만 다시 씁니다. 시작 전에 자동으로 백업합니다.
- **업데이트:** 같은 명령에 `-Version 1.38.0`처럼 버전을 붙입니다.
  - 그 버전의 Windows 빌드가 이 저장소 Releases에 있어야 합니다.
  - 없으면 Actions에서 *Build and Release Vaultwarden Windows Binary*를 실행합니다.
- **새 PC로 옮기거나 되살릴 때:**
  1. 백업 날짜 폴더를 먼저 `C:\` 아래로 복사합니다. G:는 관리자 PowerShell에서 안 보일 수 있습니다.
  2. 같은 명령에 `-RestoreFrom C:\restore\20261104-030000`처럼 그 폴더를 붙입니다.
  3. 이미 금고 데이터가 있으면 덮어쓰지 않고 멈춥니다.
- **지우기:** `uninstall.ps1`은 서비스, 예약 작업, 방화벽 규칙만 지웁니다. 데이터는 남깁니다.

## 만들어지는 것

| 무엇 | 위치·이름 |
|---|---|
| 프로그램·설정 | `C:\vaultwarden` (관리자와 SYSTEM만 접근) |
| 금고 데이터 | `C:\vaultwarden\data` |
| 서비스 | `vaultwarden`, `vaultwarden-caddy` |
| 예약 작업 | `Vaultwarden Backup` (SYSTEM, 03:00), `Vaultwarden Backup Copy` (사용자, 03:15·로그인 5분 뒤) |
| 방화벽 규칙 | `Vaultwarden HTTPS (office LAN)` |
| 로그 | 설치 폴더의 `*-service.*.log`, `backups\backup.log`, `%LOCALAPPDATA%\VaultwardenBackupCopy\copy.log` |

`.github/workflows/test-office-kit.yml`은 이 스크립트를 GitHub Windows 러너에서 처음부터 끝까지 돌려 봅니다. 설치, 관리자 로그인, 백업, 한글 경로 복사, 재설치, 복원 순서입니다.
