# DailyPostBox

Android, iOS, macOS, Windows용 Flutter 네이티브 메일 클라이언트 골격입니다.

## 역할 분리

- Flutter 앱: 계정 연결 UI, 받은편지함, 메일 읽기/쓰기, 푸시 수신, 로컬 캐시
- 서버: IMAP IDLE 실시간 감시, POP3 폴링, SMTP 발신, OAuth/비밀번호 보관, 푸시 발송

IMAP 실시간성은 서버가 책임지는 구조가 맞습니다. 모바일 앱이 직접 IMAP IDLE 연결을 오래 유지하면 OS 백그라운드 제한 때문에 iOS/Android에서 안정성이 크게 떨어집니다. 서버가 IMAP IDLE을 붙잡고, 앱은 FCM/APNs/데스크톱 알림으로 즉시 알림을 받는 쪽이 운영에 적합합니다.

## Flutter SDK가 있는 환경에서 플랫폼 폴더 생성

```bash
cd outputs/flutter-mail-client
flutter create --platforms=android,ios,macos,windows .
flutter pub get
flutter run --dart-define=MAIL_API_BASE_URL=https://api.dailypostbox.com
```

배포 앱은 `https://api.dailypostbox.com`의 HTTPS API만 사용합니다.

## 앱 구조

- `lib/main.dart`: 앱 시작점
- `lib/core/app_router.dart`: 라우팅
- `lib/core/app_theme.dart`: 공통 테마
- `lib/services/mail_api_client.dart`: 서버 API 클라이언트
- `lib/services/push_service.dart`: 푸시 토큰 등록/수신
- `lib/features/inbox`: 통합 받은편지함
- `lib/features/accounts`: 계정 추가/관리
- `lib/features/message`: 메일 읽기/쓰기

## 플랫폼 알림 전략

- Android: FCM + local notification
- iOS: APNs 또는 FCM 경유 APNs
- macOS: APNs/FCM 구성 또는 local notification 보조
- Windows: 서버 실시간 상태를 앱 실행 중 WebSocket/SSE로 받고, 백그라운드는 Windows toast 연동

## 실시간 수신 원칙

- IMAP 계정: 서버가 IMAP IDLE을 유지하고 새 메일을 즉시 푸시
- POP3 계정: 서버가 UIDL 기반으로 주기 폴링
- 앱 실행 중: 푸시 수신 후 받은편지함 API 재조회
- 앱 종료/백그라운드: OS 푸시 알림으로 사용자에게 전달

## 현재 구현된 앱 흐름

- 계정 목록 조회
- 제공자 목록 조회
- 계정 추가
- 받은편지함 조회
- 메시지 상세 조회
- 발신 계정 선택 후 SMTP 발신 API 호출
- 기기 푸시 토큰 등록
