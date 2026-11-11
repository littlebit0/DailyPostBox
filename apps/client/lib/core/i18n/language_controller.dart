import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppLanguage {
  korean(Locale('ko'), '한국어'),
  english(Locale('en'), 'English');

  const AppLanguage(this.locale, this.label);

  final Locale locale;
  final String label;
}

final languageControllerProvider =
    NotifierProvider<LanguageController, AppLanguage>(LanguageController.new);

class LanguageController extends Notifier<AppLanguage> {
  @override
  AppLanguage build() => AppLanguage.korean;

  void setLanguage(AppLanguage language) {
    state = language;
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
  String get close => _ko ? '닫기' : 'Close';
  String get send => _ko ? '보내기' : 'Send';
  String get message => _ko ? '메일' : 'Message';
  String get reply => _ko ? '답장' : 'Reply';
  String get archive => _ko ? '보관' : 'Archive';
  String get back => _ko ? '뒤로' : 'Back';
  String get from => _ko ? '보낸 사람' : 'From';
  String get to => _ko ? '받는 사람' : 'To';
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
  String get deleteAccount => _ko ? '삭제' : 'Delete';
  String get more => _ko ? '더보기' : 'More';
  String get serverSettings => _ko ? '서버 설정' : 'Server settings';
  String get syncRange => _ko ? '동기화 범위' : 'Sync range';
  String get comingSoon => _ko ? '준비 중' : 'Coming soon';
  String get noAccountSelected => _ko ? '계정을 선택하세요' : 'Select an account';
  String get noMessagesForAccount =>
      _ko ? '이 계정에 표시할 메일이 없습니다' : 'No mail for this account yet';
  String get loadingAccountMail => _ko ? '메일을 가져오는 중입니다' : 'Importing mail';
  String get loadingAccountMailDescription =>
      _ko ? '최신 메일부터 차례로 표시됩니다.' : 'Newest messages will appear first.';
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
  String get cancel => _ko ? '취소' : 'Cancel';
  String get statusIdle => _ko ? '대기' : 'Idle';
  String get statusValidating => _ko ? '검증 중' : 'Validating';
  String get statusSyncing => _ko ? '동기화 중' : 'Syncing';
  String get statusError => _ko ? '오류' : 'Error';
  String get lastSynced => _ko ? '마지막 동기화' : 'Last synced';
  String get neverSynced => _ko ? '아직 없음' : 'Never';
  String get protocol => _ko ? '수신 방식' : 'Protocol';
  String get authMode => _ko ? '인증 방식' : 'Auth mode';
  String authModeLabel(String mode) => switch (mode) {
        'oauth2' => _ko ? '브라우저 로그인' : 'Browser sign-in',
        'app-password' => _ko ? '앱 비밀번호' : 'App password',
        'password' => _ko ? '비밀번호' : 'Password',
        _ => mode,
      };
  String get pushNotifications => _ko ? '푸시 알림' : 'Push notifications';
  String get pushNotificationsDescription => _ko
      ? '새 IMAP 메일은 서버 푸시를 통해 즉시 전달됩니다.'
      : 'New IMAP messages are delivered immediately through server push.';
  String get registerThisDevice => _ko ? '이 기기 등록' : 'Register this device';
  String get registerThisDeviceDescription => _ko
      ? '플랫폼 푸시 토큰을 메일 서버에 등록합니다.'
      : 'Send the platform push token to the mail server.';
  String get languageSetting => _ko ? '언어' : 'Language';
  String get languageDescription => _ko
      ? '앱에서 사용할 표시 언어를 선택합니다.'
      : 'Choose the display language for the app.';
  String failedToLoadInbox(Object error) =>
      _ko ? '받은편지함을 불러오지 못했습니다: $error' : 'Failed to load inbox: $error';
}
