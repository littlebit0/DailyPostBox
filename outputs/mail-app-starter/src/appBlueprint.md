# 메일 앱 제품 뼈대

## 1차 MVP

- 계정 추가: Gmail, Outlook OAuth / Naver, Daum 앱 비밀번호 / 기타 수동 설정
- 통합 받은편지함
- 메일 읽기, 보내기, 답장, 전달
- 새 메일 푸시 알림
- 첨부파일 다운로드

## 핵심 도메인

- User
- MailAccount
- Mailbox
- Message
- Attachment
- DevicePushToken
- SyncCursor

## 수신 전략

- IMAP: 서버 워커에서 IDLE 연결 유지, 끊김 시 exponential backoff 재연결
- IMAP 실시간성: 모바일/데스크톱 앱이 직접 장시간 IMAP 연결을 유지하지 않고 서버가 IDLE 이벤트를 받아 즉시 푸시
- POP3: UIDL 기반 중복 방지, 1분 이상 폴링 권장
- OAuth 계정: refresh token으로 access token 갱신
- 비밀번호 계정: 앱 비밀번호 우선 안내

## 푸시 전략

- Android: FCM
- iOS: FCM 또는 APNs 직접 연동
- Web: Web Push
- 알림 페이로드: sender, subject, messageId 정도만 포함
- 본문 전체는 앱이 API로 다시 조회

## 꼭 필요한 운영 기능

- 계정별 동기화 상태 표시
- IMAP 연결 끊김 감지
- provider rate limit 대응
- 중복 메일 방지 키: accountId + mailbox + providerMessageId
- 스팸/휴지통/보낸편지함 폴더 매핑
- 장애 계정 격리: 한 계정 실패가 전체 워커를 멈추지 않게 처리
