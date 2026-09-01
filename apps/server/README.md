# DailyPostBox Server

DailyPostBox 네이티브 클라이언트를 위한 Fastify 및 TypeScript 기반 메일 API와
동기화 워커입니다. 모바일 운영체제가 백그라운드 IMAP 연결을 안정적으로 유지하기
어렵기 때문에 서버가 IMAP IDLE 연결과 OAuth 토큰 갱신을 담당합니다.

## 현재 구현

- Gmail, Outlook, 네이버, 다음, 사용자 지정 메일 제공자 레지스트리
- Gmail/Outlook OAuth 2.0 Authorization Code + PKCE 흐름
- OAuth 액세스 토큰 만료 전 갱신 및 개발 저장소 반영
- 계정 추가 전 IMAP 수신과 SMTP 발신 연결 검증
- IMAP 최신 메일 조회, IDLE 감시, 지수 백오프 재연결
- IMAP 본문 지연 조회, HTML 텍스트 변환 및 링크 제목 추출
- SMTP 연결 검증과 메일 발송
- 계정별 초기 동기화 범위와 수동 동기화
- 개발용 로컬 JSON 계정/메시지 저장소
- 네이버 일반 비밀번호 차단 및 애플리케이션 비밀번호 강제

## 실행

```bash
cp .env.example .env
corepack enable
pnpm install
pnpm dev
```

기본 주소는 `http://127.0.0.1:4000`입니다.

```bash
curl http://127.0.0.1:4000/health
```

개발 환경에서는 별도 `DATA_FILE_PATH`가 없으면 `.data/local-state.json`에 계정과
메일 메타데이터를 저장합니다. 이 파일에는 개발용 인증 정보가 포함될 수 있으며
Git에서 제외됩니다.

## 환경변수

| 변수 | 설명 |
| --- | --- |
| `PORT` | API 포트, 기본값 `4000` |
| `HOST` | 바인딩 주소, 기본값 `0.0.0.0` |
| `DATA_FILE_PATH` | 개발용 로컬 상태 파일 경로 |
| `OAUTH_REDIRECT_BASE_URL` | OAuth 콜백을 제공하는 공개 API 기준 URL |
| `GOOGLE_OAUTH_CLIENT_ID` | Google OAuth 클라이언트 ID |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Google OAuth 클라이언트 보안 비밀 |
| `OUTLOOK_OAUTH_CLIENT_ID` | Microsoft OAuth 클라이언트 ID |
| `OUTLOOK_OAUTH_CLIENT_SECRET` | Microsoft OAuth 클라이언트 보안 비밀 |
| `DATABASE_URL` | 운영 데이터베이스 연결용 예약 변수 |
| `ENCRYPTION_MASTER_KEY` | 운영 암호화 저장소 연결용 예약 변수 |
| `PUSH_PROVIDER` | 푸시 제공자 선택, 현재 기본값 `noop` |

`.env`의 실제 값은 절대 커밋하지 마세요.

## Gmail OAuth 설정

Google Cloud Console에서 Web application 유형의 OAuth 클라이언트를 생성하고 아래
리디렉션 URI를 승인 목록에 등록합니다.

```text
https://<API 도메인>/auth/gmail/callback
```

```bash
OAUTH_REDIRECT_BASE_URL=https://<API 도메인>
GOOGLE_OAUTH_CLIENT_ID=...
GOOGLE_OAUTH_CLIENT_SECRET=...
```

OAuth 동의 화면이 테스트 상태라면 등록된 테스트 사용자만 로그인할 수 있습니다.
Gmail 전체 메일 접근 권한으로 공개 배포하려면 Google의 OAuth 앱 검증을 통과해야
합니다.

## 네이버 연결

네이버 메일은 2단계 인증과 애플리케이션 비밀번호가 필요합니다. 사용자는 네이버
메일 환경설정에서 IMAP/SMTP를 활성화한 뒤 일반 로그인 비밀번호 대신 발급한
애플리케이션 비밀번호를 입력해야 합니다.

- IMAP: `imap.naver.com:993`, SSL
- SMTP: `smtp.naver.com:587`, STARTTLS

서버는 네이버 계정에 `password` 인증 방식이 전달되면 메일 서버에 연결하기 전에
`400 Bad Request`로 거절합니다.

## 현재 API

- `GET /health`
- `GET /providers`
- `GET /accounts`
- `POST /accounts`
- `POST /accounts/validate`
- `DELETE /accounts/:id`
- `POST /accounts/:id/validate`
- `POST /accounts/:id/sync`
- `GET /accounts/:id/messages`
- `GET /accounts/:accountId/messages/:messageId`
- `POST /auth/:providerId/start`
- `GET /auth/:providerId/callback`
- `GET /auth/sessions/:state`
- `POST /auth/sessions/:state/complete`
- `GET /mail/inbox`
- `GET /mail/messages/:id`
- `POST /mail/send`
- `POST /devices/push-token`

## 검증 및 빌드

```bash
pnpm typecheck
pnpm build
pnpm start
```

## 배포 전 필수 작업

- `demo-user` 대신 실제 사용자 인증과 계정 소유권 검사 도입
- 영구 데이터베이스 기반 `AccountRepository` 구현
- Vault/KMS와 envelope encryption 기반 비밀정보 저장
- OAuth 세션의 공유 저장소와 만료 정리
- POP3 UIDL 기반 실제 수신 구현
- FCM, APNs 및 Windows 푸시 제공자 구현
- 첨부파일 저장, 크기 제한 및 악성 파일 검사
- API CORS 제한, rate limit, 감사 로그 및 운영 모니터링

현재 `DevelopmentSecretResolver`, 로컬 파일 저장소, 인메모리 OAuth 세션 및
`NoopPushNotifier`는 개발 전용입니다. `Dockerfile`과 `cloudbuild.yaml`은 Cloud
Run 배포 골격이지만 위 항목을 완료하기 전에는 운영 서비스로 배포하면 안 됩니다.
