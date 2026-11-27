import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage {
  korean(Locale('ko'), '한국어'),
  english(Locale('en'), 'English');

  const AppLanguage(this.locale, this.label);

  final Locale locale;
  final String label;
}

const _languagePreferenceKey = 'app_language';

/// Reads the saved language; Korean when nothing valid is saved or the
/// store cannot be read.
Future<AppLanguage> loadSavedLanguage() async {
  try {
    final saved = (await SharedPreferences.getInstance())
        .getString(_languagePreferenceKey);
    return AppLanguage.values.firstWhere(
      (language) => language.name == saved,
      orElse: () => AppLanguage.korean,
    );
  } catch (_) {
    return AppLanguage.korean;
  }
}

/// The language loaded before the app starts; main() overrides it.
final initialLanguageProvider = Provider<AppLanguage>((ref) {
  return AppLanguage.korean;
});

final languageControllerProvider =
    NotifierProvider<LanguageController, AppLanguage>(LanguageController.new);

class LanguageController extends Notifier<AppLanguage> {
  @override
  AppLanguage build() => ref.read(initialLanguageProvider);

  Future<void> setLanguage(AppLanguage language) async {
    state = language;
    try {
      await (await SharedPreferences.getInstance())
          .setString(_languagePreferenceKey, language.name);
    } catch (_) {
      // The choice still applies for this run if it cannot be saved.
    }
  }
}

final appStringsProvider = Provider<AppStrings>((ref) {
  return AppStrings(ref.watch(languageControllerProvider));
});

class AppStrings {
  const AppStrings(this.currentLanguage);

  final AppLanguage currentLanguage;

  bool get _ko => currentLanguage == AppLanguage.korean;

  String get appTitle => 'Daily Postbox';
  String get inbox => _ko ? '받은편지함' : 'Inbox';
  String get accounts => _ko ? '계정' : 'Accounts';
  String get accountManagement => _ko ? '계정관리' : 'Account Management';
  String get settings => _ko ? '설정' : 'Settings';
  String get compose => _ko ? '메일 쓰기' : 'Compose';
  String get refresh => _ko ? '새로고침' : 'Refresh';
  String get shortcutHelp => _ko ? '단축키 도움말' : 'Keyboard shortcuts';
  String get shortcutNextMessage => _ko ? '다음 메일 선택' : 'Select next message';
  String get shortcutPreviousMessage =>
      _ko ? '이전 메일 선택' : 'Select previous message';
  String get shortcutOpenMessage => _ko ? '선택한 메일 열기' : 'Open selected message';
  String get shortcutFocusSearch => _ko ? '메일 검색' : 'Search mail';
  String get mailMenu => _ko ? '메일' : 'Mail';
  String get editMenu => _ko ? '편집' : 'Edit';
  String get windowMenu => _ko ? '윈도우' : 'Window';
  String get close => _ko ? '닫기' : 'Close';
  String get send => _ko ? '보내기' : 'Send';
  String get message => _ko ? '메일' : 'Message';
  String get reply => _ko ? '답장' : 'Reply';
  String get snooze => _ko ? '다시 알림' : 'Snooze';
  String get snoozeTonight => _ko ? '오늘 저녁 (오후 6시)' : 'This evening (6 PM)';
  String get snoozeTomorrow =>
      _ko ? '내일 아침 (오전 9시)' : 'Tomorrow morning (9 AM)';
  String get snoozeNextWeek =>
      _ko ? '다음 주 (월요일 오전 9시)' : 'Next week (Mon 9 AM)';
  String get snoozeCustom => _ko ? '직접 지정...' : 'Pick date and time...';
  String get snoozeFailed =>
      _ko ? '다시 알림을 설정하지 못했습니다' : 'Could not set the snooze';
  String snoozed(String when) =>
      _ko ? '$when에 다시 알려드립니다' : 'Snoozed until $when';
  String get markUnread => _ko ? '읽지 않음으로 표시' : 'Mark as unread';
  String get markRead => _ko ? '읽음으로 표시' : 'Mark as read';
  String get addStar => _ko ? '별표 표시' : 'Add star';
  String get removeStar => _ko ? '별표 해제' : 'Remove star';
  String get flagUpdateFailed => _ko
      ? '메일 상태를 서버에 반영하지 못했습니다.'
      : 'Could not update the message on the server.';
  String get replyAll => _ko ? '전체 답장' : 'Reply all';
  String get cc => _ko ? '참조' : 'Cc';

  /// Absolute local date-time for the reply quote header.
  String quoteDate(DateTime time) => _ko
      ? DateFormat('yyyy-MM-dd (E) HH:mm', 'ko').format(time)
      : DateFormat("E, MMM d, y 'at' HH:mm", 'en').format(time);
  String quoteHeader(String date, String sender) =>
      _ko ? '$date $sender 님이 작성:' : 'On $date, $sender wrote:';
  String get back => _ko ? '뒤로' : 'Back';
  String get unsubscribe => _ko ? '수신 거부' : 'Unsubscribe';
  String get unsubscribeConfirmTitle =>
      _ko ? '수신 거부 메일을 보낼까요?' : 'Send an unsubscribe email?';
  String unsubscribeConfirmBody(String address) => _ko
      ? '$address 로 수신 거부 메일을 보냅니다.'
      : 'An unsubscribe email will be sent to $address.';
  String get unsubscribeSent =>
      _ko ? '수신 거부 메일을 보냈습니다' : 'Unsubscribe email sent';
  String get unsubscribeFailed =>
      _ko ? '수신 거부를 처리하지 못했습니다' : 'Could not unsubscribe';
  String get from => _ko ? '보낸 사람' : 'From';
  String get to => _ko ? '받는 사람' : 'To';
  String get recipientRequired =>
      _ko ? '받는 사람을 입력하세요.' : 'Enter at least one recipient.';
  String sendFailed(String reason) =>
      _ko ? '메일을 보내지 못했습니다: $reason' : 'Could not send the mail: $reason';
  String get subject => _ko ? '제목' : 'Subject';
  String get body => _ko ? '내용' : 'Message';
  String get emptyInboxTitle => _ko ? '받은 메일이 없습니다' : 'No messages yet';
  String get emptyInboxDescription => _ko
      ? '계정을 추가하면 IMAP 실시간 수신 또는 POP3 동기화로 새 메일이 여기에 표시됩니다.'
      : 'Add an account to show new mail here through IMAP realtime sync or POP3 polling.';
  String get connectedAccounts => _ko ? '연결된 계정' : 'Connected Accounts';
  String get noAccountsYet => _ko ? '아직 계정이 없습니다' : 'No accounts yet';
  String get addRealtimeAccountHint => _ko
      ? '실시간 푸시 알림을 받으려면 IMAP 계정을 추가하세요.'
      : 'Add an IMAP account to receive realtime push notifications.';
  String get addAccount => _ko ? '계정 추가' : 'Add Account';
  String get provider => _ko ? '제공자' : 'Provider';
  String get emailAddress => _ko ? '이메일 주소' : 'Email address';
  String get secretLabel =>
      _ko ? '비밀번호, 앱 비밀번호 또는 토큰' : 'Password, app password, or token';
  String get applicationPassword =>
      _ko ? '애플리케이션 비밀번호' : 'Application password';
  String get naverSetupTitle => _ko ? '네이버 메일 연결 준비' : 'Prepare Naver Mail';
  String get naverSetupDescription => _ko
      ? '네이버 메일은 외부 앱 연결에 일반 로그인 비밀번호를 사용할 수 없습니다.'
      : 'Naver Mail does not allow your regular sign-in password in external apps.';
  String get naverTwoFactorStep => _ko
      ? '네이버 계정에서 2단계 인증을 켭니다.'
      : 'Turn on two-step verification for your Naver account.';
  String get naverAppPasswordStep => _ko
      ? 'DailyPostBox용 애플리케이션 비밀번호를 발급합니다.'
      : 'Create an application password for DailyPostBox.';
  String get naverImapStep => _ko
      ? '네이버 메일 환경설정에서 IMAP/SMTP 사용을 켭니다.'
      : 'Enable IMAP/SMTP in Naver Mail settings.';
  String get naverAppPasswordGuide => _ko ? '앱 비밀번호 안내' : 'App password guide';
  String get naverImapGuide =>
      _ko ? 'IMAP/SMTP 설정 안내' : 'IMAP/SMTP setup guide';
  String get naverGuideCouldNotOpen => _ko
      ? '네이버 공식 도움말 페이지를 열 수 없습니다.'
      : 'Could not open the official Naver help page.';
  String get naverAppPasswordHelper => _ko
      ? '네이버 로그인 비밀번호가 아닌, 외부 앱용으로 발급한 비밀번호를 입력하세요.'
      : 'Enter the password issued for an external app, not your Naver sign-in password.';
  String get browserLogin => _ko ? '브라우저로 로그인' : 'Sign in with browser';
  String get browserLoginDescription => _ko
      ? 'Gmail과 Outlook은 비밀번호 대신 공식 로그인 페이지에서 권한을 승인합니다.'
      : 'Gmail and Outlook approve access on the official sign-in page instead of asking for a password.';
  String get chooseMailService => _ko ? '로그인할 메일 선택' : 'Choose a mail service';
  String get chooseMailServiceDescription => _ko
      ? '연동할 이메일 서비스를 선택하세요.'
      : 'Choose the email service you want to connect.';
  String get connectedAs => _ko ? '로그인 계정' : 'Signed in as';
  String get finishSetup => _ko ? '연동 설정' : 'Connection setup';
  String get finishSetupDescription => _ko
      ? '메일을 얼마나 가져올지 선택하면 연결을 시작합니다.'
      : 'Choose how much mail to import, then start connecting.';
  String get startConnection => _ko ? '연동 시작' : 'Start connecting';
  String get waitingBrowserLogin =>
      _ko ? '브라우저에서 로그인을 완료하는 중...' : 'Waiting for browser sign-in...';
  String get checkBrowserLogin => _ko ? '로그인 다시 확인' : 'Check sign-in again';
  String get browserCouldNotOpen => _ko
      ? '브라우저를 열 수 없습니다. 아래 로그인 주소를 직접 열어주세요.'
      : 'Could not open the browser. Open the login URL manually.';
  String get oauthClientMissing => _ko
      ? 'OAuth 클라이언트 설정이 필요합니다. Google Cloud 또는 Microsoft 앱 등록에서 redirect URL을 등록하세요.'
      : 'OAuth client setup is required. Register the redirect URL in Google Cloud or Microsoft app registration.';
  String get addAccountButton => _ko ? '계정 추가' : 'Add account';
  String get addFirstAccount => _ko ? '첫 계정 추가' : 'Add first account';
  String get accountList => _ko ? '계정 목록' : 'Accounts';
  String get accountDetails => _ko ? '계정 상세' : 'Account Details';
  String get accountMessages => _ko ? '계정별 메일' : 'Account Mail';
  String get syncNow => _ko ? '동기화' : 'Sync';
  String get validateConnection => _ko ? '연결 테스트' : 'Test connection';
  String get accountNotifications =>
      _ko ? '이 계정의 새 메일 알림' : 'New mail notifications for this account';
  String get deleteAccount => _ko ? '삭제' : 'Delete';
  String get more => _ko ? '더보기' : 'More';
  String get serverSettings => _ko ? '서버 설정' : 'Server settings';
  String get incomingServer =>
      _ko ? '받는 메일 서버 (IMAP)' : 'Incoming mail server (IMAP)';
  String get outgoingServer =>
      _ko ? '보내는 메일 서버 (SMTP)' : 'Outgoing mail server (SMTP)';
  String get serverHost => _ko ? '서버 주소' : 'Server address';
  String get serverPort => _ko ? '포트' : 'Port';
  String get serverUsesSsl => _ko ? 'SSL/TLS 사용' : 'Use SSL/TLS';
  String get customServerRequired => _ko
      ? '받는·보내는 서버 주소와 포트(1~65535)를 입력하세요.'
      : 'Enter both server addresses and ports (1-65535).';
  String get syncRange => _ko ? '동기화 범위' : 'Sync range';
  String get comingSoon => _ko ? '준비 중' : 'Coming soon';
  String get noAccountSelected => _ko ? '계정을 선택하세요' : 'Select an account';
  String get categoryAll => _ko ? '전체' : 'All';
  String get categoryPerson => _ko ? '사람' : 'People';
  String get categoryNotification => _ko ? '알림' : 'Notifications';
  String get categoryNewsletter => _ko ? '뉴스레터' : 'Newsletters';
  String get searchMail => _ko ? '메일 검색' : 'Search mail';
  String get searchHint => _ko
      ? '검색: 제목·보낸 사람, from: subject: after: before:'
      : 'Search subject or sender, from: subject: after: before:';
  String get clearSearch => _ko ? '검색 지우기' : 'Clear search';
  String get noSearchResults => _ko ? '검색 결과가 없습니다' : 'No messages found';
  String get searchFailedTitle => _ko ? '검색하지 못했습니다' : 'Search failed';
  String get noMessagesForAccount =>
      _ko ? '이 계정에 표시할 메일이 없습니다' : 'No mail for this account yet';
  String get loadingAccountMail => _ko ? '메일을 가져오는 중입니다' : 'Importing mail';
  String get loadingAccountMailDescription =>
      _ko ? '최신 메일부터 차례로 표시됩니다.' : 'Newest messages will appear first.';
  String get reconnectAccount => _ko ? '다시 연결' : 'Reconnect';
  String get reconnectPasswordDescription => _ko
      ? '새 비밀번호를 확인한 뒤 저장합니다. 저장된 메일과 설정은 그대로 유지됩니다.'
      : 'The new password is checked before saving. Stored mail and settings are kept.';
  String get reconnectSucceeded =>
      _ko ? '다시 연결했습니다. 메일을 가져오는 중입니다.' : 'Reconnected. Fetching mail now.';
  String remoteImagesBlocked(int count) =>
      _ko ? '원격 이미지 $count개 차단됨' : '$count remote images blocked';
  String get showImagesOnce => _ko ? '이번만 보기' : 'Show this time';
  String get attachments => _ko ? '첨부파일' : 'Attachments';
  String get saveAttachment => _ko ? '저장' : 'Save';
  String attachmentSaved(String path) =>
      _ko ? '$path에 저장했습니다' : 'Saved to $path';
  String get attachmentSaveFailed =>
      _ko ? '첨부파일을 저장하지 못했습니다' : 'Could not save the attachment';
  String get messageLoadFailedTitle =>
      _ko ? '메일 본문을 불러오지 못했습니다' : 'Could not open this message';
  String syncFailure(String? code, String? error) {
    if (code == 'authentication') {
      return _ko
          ? '로그인 정보가 만료됐거나 올바르지 않아 메일을 가져올 수 없습니다. 계정을 다시 연결해야 합니다.'
          : 'Sign-in expired or is invalid, so mail cannot be fetched. Reconnect this account.';
    }
    final detail = error ?? '';
    return _ko ? '메일을 가져오지 못했습니다. $detail' : 'Could not fetch mail. $detail';
  }

  String get mailLoadFailedTitle =>
      _ko ? '메일 목록을 불러오지 못했습니다' : 'Could not load mail';
  String get importPreviousMail => _ko ? '이전 이메일 가져오기' : 'Import previous mail';
  String get import100 =>
      _ko ? '최근 100개 가져오기 (추천)' : 'Latest 100 messages (Recommended)';
  String get import500 => _ko ? '최근 500개 가져오기' : 'Latest 500 messages';
  String get import1000 => _ko ? '최근 1,000개 가져오기' : 'Latest 1,000 messages';
  String get importAll => _ko ? '전부 가져오기' : 'Import everything';
  String get importNone =>
      _ko ? '이전 이메일 가져오지 않기' : 'Do not import previous mail';
  String get importAllWarning => _ko
      ? '계정 크기에 따라 오래 걸릴 수 있습니다.'
      : 'This may take a long time for large mailboxes.';
  String get checkingCredentials =>
      _ko ? '계정 인증 정보를 확인하는 중...' : 'Checking account credentials...';
  String get checkingSync =>
      _ko ? '동기화 상태를 확인하는 중...' : 'Checking sync status...';
  String get startingBrowserLogin =>
      _ko ? '공식 로그인 페이지를 여는 중...' : 'Opening the official sign-in page...';
  String get accountAdded => _ko ? '계정이 추가되었습니다' : 'Account added';
  String get connectionFailed => _ko ? '연결 확인 실패' : 'Connection check failed';
  String get serverUnavailableTitle =>
      _ko ? '메일 서버에 연결할 수 없습니다' : 'Cannot connect to the mail server';
  String get serverUnavailableDescription => _ko
      ? '서버 연결을 확인한 뒤 다시 시도해 주세요.'
      : 'Check the server connection and try again.';
  String get accountLoadFailedTitle =>
      _ko ? '계정 정보를 불러오지 못했습니다' : 'Could not load accounts';
  String get tryAgain => _ko ? '다시 시도' : 'Try again';
  String get emailAndSecretRequired =>
      _ko ? '이메일과 비밀번호를 입력하세요.' : 'Enter email and password.';
  String get naverCredentialsRequired => _ko
      ? '네이버 이메일 주소와 애플리케이션 비밀번호를 입력하세요.'
      : 'Enter your Naver email address and application password.';
  String get emailRequired =>
      _ko ? '이메일 주소를 입력하세요.' : 'Enter the email address.';
  String get confirmDeleteAccount =>
      _ko ? '이 계정을 삭제할까요?' : 'Delete this account?';
  String get deleteAccountDescription => _ko
      ? '이 앱에 저장된 계정과 동기화된 메일 목록이 삭제됩니다.'
      : 'This removes the account and synced mail list from this app.';
  String get signature => _ko ? '서명' : 'Signature';
  String get signatureHint => _ko
      ? '새 메일 끝에 자동으로 붙습니다. 비워 두면 서명을 붙이지 않습니다.'
      : 'Added to the end of new messages. Leave empty for no signature.';
  String get signatureSaved => _ko ? '서명을 저장했습니다.' : 'Signature saved.';
  String get save => _ko ? '저장' : 'Save';
  String get cancel => _ko ? '취소' : 'Cancel';
  String get statusIdle => _ko ? '대기' : 'Idle';
  String get statusValidating => _ko ? '검증 중' : 'Validating';
  String get statusSyncing => _ko ? '동기화 중' : 'Syncing';
  String get statusError => _ko ? '오류' : 'Error';
  String get lastSynced => _ko ? '마지막 동기화' : 'Last synced';
  String get neverSynced => _ko ? '아직 없음' : 'Never';
  String get receiveMode => _ko ? '수신 방식' : 'Receive mode';
  String get receiveRealtime => _ko ? '실시간(IDLE)' : 'Realtime (IDLE)';
  String get receivePolling => _ko ? '주기 확인' : 'Periodic check';
  String get receiveUnknown => _ko ? '확인 전' : 'Not checked yet';
  String get capabilitiesChecked => _ko ? '확인' : 'checked';
  String get protocol => _ko ? '수신 방식' : 'Protocol';
  String get authMode => _ko ? '인증 방식' : 'Auth mode';
  String authModeLabel(String mode) => switch (mode) {
        'oauth2' => _ko ? '브라우저 로그인' : 'Browser sign-in',
        'app-password' => _ko ? '앱 비밀번호' : 'App password',
        'password' => _ko ? '비밀번호' : 'Password',
        _ => mode,
      };
  String get threadView => _ko ? '대화 보기' : 'Conversation view';
  String get threadViewDescription => _ko
      ? '같은 대화의 메일을 한 줄로 묶어 보여줍니다.'
      : 'Group mail from the same conversation into one row.';
  String get thread => _ko ? '대화' : 'Conversation';
  String threadMessageCount(int count) => _ko ? '$count통' : '$count';
  String get mailSending => _ko ? '메일을 보내는 중입니다.' : 'Sending mail...';
  String get undoSend => _ko ? '보내기 취소' : 'Undo send';
  String get sendCancelled =>
      _ko ? '보내기를 취소했습니다.' : 'Sending was cancelled.';
  String get sendAlreadySent =>
      _ko ? '이미 발송되어 취소할 수 없습니다.' : 'Already sent; it cannot be cancelled.';
  String get sendCancelFailed =>
      _ko ? '취소하지 못했습니다. 메일이 발송될 수 있습니다.' : 'Could not cancel; the mail may be sent.';
  String sendDeliveryFailed(String reason) => _ko
      ? '메일을 보내지 못했습니다: $reason'
      : 'The mail could not be delivered: $reason';
  String get sendFailedShort => _ko ? '발송에 실패했습니다.' : 'Sending failed.';
  String failedSendsCount(int n) => _ko ? '발송 실패 $n건' : '$n failed to send';
  String pendingSendsCount(int n) => _ko ? '보내기 대기 $n건' : '$n waiting to send';
  String get viewPendingSends => _ko ? '보기' : 'View';
  String get viewFailedSends => _ko ? '보기' : 'View';
  String get deleteFailedSend => _ko ? '삭제' : 'Delete';
  String get rewriteMail => _ko ? '다시 작성' : 'Rewrite';
  String get undoSendSetting => _ko ? '보내기 취소 시간' : 'Undo send delay';
  String get undoSendSettingDescription => _ko
      ? '보낸 메일을 이 시간 동안 서버가 보관하며 취소할 수 있습니다.'
      : 'The server holds sent mail for this long so you can cancel it.';
  String secondsLabel(int seconds) =>
      seconds == 0 ? (_ko ? '끔' : 'Off') : (_ko ? '$seconds초' : '${seconds}s');
  String get registerThisDevice => _ko ? '이 기기 등록' : 'Register this device';
  String get registerThisDeviceDescription => _ko
      ? '플랫폼 푸시 토큰을 메일 서버에 등록합니다.'
      : 'Send the platform push token to the mail server.';
  String get pushRegistered => _ko
      ? '이 기기를 등록했습니다. 새 메일이 오면 알림을 보냅니다.'
      : 'This device is registered. New mail will send a notification.';
  String get pushUnsupported => _ko
      ? '이 플랫폼은 아직 푸시 알림을 지원하지 않습니다.'
      : 'Push notifications are not supported on this platform yet.';
  String get pushPermissionDenied => _ko
      ? '알림 권한이 꺼져 있습니다. 시스템 설정 > 알림에서 DailyPostBox를 허용하세요.'
      : 'Notifications are off. Allow DailyPostBox in System Settings > Notifications.';
  String pushRegistrationFailed(String detail) =>
      _ko ? '기기 등록에 실패했습니다: $detail' : 'Device registration failed: $detail';
  String get languageSetting => _ko ? '언어' : 'Language';
  String get languageDescription => _ko
      ? '앱에서 사용할 표시 언어를 선택합니다.'
      : 'Choose the display language for the app.';
  String failedToLoadInbox(Object error) =>
      _ko ? '받은편지함을 불러오지 못했습니다: $error' : 'Failed to load inbox: $error';
  String authFailureWarning(List<String> failures) {
    final names = failures.map((name) => name.toUpperCase()).join(', ');
    return _ko
        ? '발신자 인증 실패($names): 보낸 사람을 사칭한 메일일 수 있습니다. 링크와 첨부를 열지 마세요.'
        : 'Sender authentication failed ($names): this message may be spoofed. Do not open links or attachments.';
  }
}
