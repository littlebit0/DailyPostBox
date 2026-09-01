# DailyPostBox Client

Android, iOS, macOS, Windows를 대상으로 하는 Flutter 네이티브 메일
클라이언트입니다. 앱은 메일 서버에 직접 장기 연결하지 않고 DailyPostBox API를
통해 계정, 메일 목록, 본문 및 발신 기능을 사용합니다.

## 현재 구현

- 계정관리와 연결된 계정별 사이드바
- 계정별 메일 목록, 본문 조회 및 메일 작성
- Gmail 및 Outlook OAuth 브라우저 로그인 흐름
- 네이버 애플리케이션 비밀번호 설정 안내
- 계정 연결 검증, 동기화, 삭제 및 초기 가져오기 범위 선택
- 메일 본문의 링크 제목 표시와 외부 브라우저 열기
- 한국어와 영어 설정
- 좁은 화면용 Drawer 및 데스크톱 사이드바
- 서버 연결 실패를 사용자가 이해할 수 있는 상태로 표시

## 실행

먼저 `apps/server`에서 API를 실행한 뒤 클라이언트를 시작합니다.

```bash
flutter pub get
flutter run -d macos \
  --dart-define=MAIL_API_BASE_URL=http://127.0.0.1:4000
```

개발 빌드에서 `MAIL_API_BASE_URL`을 생략하면 `http://127.0.0.1:4000`을
사용합니다. 릴리스 빌드의 기본값은 `https://api.dailypostbox.com`이며, 실제 배포
환경에 맞는 HTTPS 주소를 명시하는 것을 권장합니다.

## 검증

```bash
flutter analyze
flutter test
flutter build macos --debug
```

## 앱 구조

- `lib/main.dart`: 앱 시작점
- `lib/core/app_router.dart`: 계정, 메일, 작성 및 설정 라우팅
- `lib/core/i18n`: 한국어/영어 문자열과 언어 상태
- `lib/services/mail_api_client.dart`: 서버 API 클라이언트
- `lib/services/browser_launcher.dart`: OAuth와 메일 링크 외부 브라우저 실행
- `lib/features/accounts`: 계정관리와 계정별 메일함
- `lib/features/message`: 메일 본문 표시와 작성
- `lib/features/settings`: 언어 및 알림 설정
- `lib/widgets/app_shell.dart`: 반응형 계정 사이드바

## 계정 연결 흐름

1. 계정관리에서 메일 제공자를 선택합니다.
2. Gmail과 Outlook은 시스템 브라우저에서 OAuth 로그인을 진행합니다.
3. 네이버는 2단계 인증과 애플리케이션 비밀번호 및 IMAP/SMTP 사용 설정을
   완료합니다.
4. 이전 메일을 100개, 500개, 1,000개, 전체 또는 가져오지 않기로 선택합니다.
5. IMAP 계정은 서버가 수신과 발신 연결을 모두 검증한 뒤 추가합니다.

## 실시간 수신 구조

- IMAP 계정: 서버가 IMAP IDLE 연결을 유지합니다.
- 앱 실행 중: 계정별 메일 목록 API를 다시 조회합니다.
- 앱 백그라운드: 향후 FCM, APNs 및 Windows 알림으로 새 메일을 전달합니다.
- POP3 계정: UI와 API 계약은 존재하지만 실제 UIDL 폴링 수신기는 아직 구현
  예정입니다.

## 플랫폼 상태

macOS 개발 빌드에서 현재 UI와 주요 메일 흐름을 검증하고 있습니다. Android, iOS,
Windows 플랫폼 폴더는 포함되어 있지만 배포 서명, OAuth 플랫폼 설정 및 운영용
푸시 알림 구성은 아직 필요합니다.
