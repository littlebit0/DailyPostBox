import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/accounts/accounts_page.dart';
import 'package:daily_postbox/features/message/linked_message_body.dart';
import 'package:daily_postbox/main.dart';
import 'package:daily_postbox/services/mail_api_client.dart';

void main() {
  testWidgets('renders mail app shell', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const []),
          providersProvider.overrideWith((ref) async => const []),
        ],
        child: const DailyPostBoxApp(),
      ),
    );

    await tester.pump();

    expect(find.text('계정관리'), findsWidgets);
  });

  testWidgets('shows a friendly server connection error',
      (WidgetTester tester) async {
    final error = DioException.connectionError(
      requestOptions: RequestOptions(path: '/accounts'),
      reason: 'Failed host lookup',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) => Future.error(error)),
          providersProvider.overrideWith((ref) => Future.error(error)),
        ],
        child: const DailyPostBoxApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('메일 서버에 연결할 수 없습니다'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    expect(find.textContaining('DioException'), findsNothing);
  });

  testWidgets('opens a connected account mailbox from the sidebar',
      (WidgetTester tester) async {
    const account = MailAccountSummary(
      id: 'account-1',
      providerId: 'gmail',
      emailAddress: 'mailbox@example.com',
      incomingProtocol: 'imap',
      authMode: 'oauth2',
      syncStatus: 'idle',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'now',
    );
    const message = MailSummary(
      id: 'message-1',
      sender: 'sender@example.com',
      subject: '사이드바 계정 메일',
      snippet: '계정 메뉴에서 연 메일입니다.',
      receivedAtLabel: 'now',
      unread: true,
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith(
            (ref, accountId) async =>
                accountId == account.id ? const [message] : const [],
          ),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(message.subject), findsNothing);
    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    expect(find.text(message.subject), findsOneWidget);
    expect(find.text(account.emailAddress), findsWidgets);
  });

  testWidgets('shows a progressive loading state during account sync',
      (WidgetTester tester) async {
    const account = MailAccountSummary(
      id: 'syncing-account',
      providerId: 'naver',
      emailAddress: 'syncing@example.com',
      incomingProtocol: 'imap',
      authMode: 'app-password',
      syncStatus: 'syncing',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'never',
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider
              .overrideWith((ref, accountId) async => const []),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(account.emailAddress).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('메일을 가져오는 중입니다'), findsOneWidget);
    expect(find.text('최신 메일부터 차례로 표시됩니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keeps the syncing mailbox when an account refresh fails',
      (WidgetTester tester) async {
    const account = MailAccountSummary(
      id: 'syncing-account',
      providerId: 'naver',
      emailAddress: 'syncing@example.com',
      incomingProtocol: 'imap',
      authMode: 'app-password',
      syncStatus: 'syncing',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'never',
    );
    var accountLoads = 0;
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async {
            accountLoads += 1;
            if (accountLoads > 1) throw Exception('server unavailable');
            return const [account];
          }),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider
              .overrideWith((ref, accountId) async => const []),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(account.emailAddress).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();

    expect(accountLoads, greaterThan(1));
    expect(find.text('메일을 가져오는 중입니다'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reloads mail once more when account sync finishes',
      (WidgetTester tester) async {
    const syncing = MailAccountSummary(
      id: 'syncing-account',
      providerId: 'naver',
      emailAddress: 'syncing@example.com',
      incomingProtocol: 'imap',
      authMode: 'app-password',
      syncStatus: 'syncing',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'never',
    );
    const idle = MailAccountSummary(
      id: 'syncing-account',
      providerId: 'naver',
      emailAddress: 'syncing@example.com',
      incomingProtocol: 'imap',
      authMode: 'app-password',
      syncStatus: 'idle',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'now',
    );
    var accountLoads = 0;
    var messageLoads = 0;
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async {
            accountLoads += 1;
            return accountLoads == 1 ? const [syncing] : const [idle];
          }),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith((ref, accountId) async {
            messageLoads += 1;
            return const [];
          }),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(syncing.emailAddress).first);
    await tester.pump();
    final loadsBeforePoll = messageLoads;
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    await tester.pump();

    // One poll plus one reload after the status leaves syncing.
    expect(messageLoads, loadsBeforePoll + 2);
    expect(find.text('이 계정에 표시할 메일이 없습니다'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 4));
    expect(messageLoads, loadsBeforePoll + 2);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('explains an authentication failure in the mailbox',
      (WidgetTester tester) async {
    const account = MailAccountSummary(
      id: 'auth-failed-account',
      providerId: 'naver',
      emailAddress: 'expired@example.com',
      incomingProtocol: 'imap',
      authMode: 'app-password',
      syncStatus: 'error',
      syncError: 'Command failed',
      syncErrorCode: 'authentication',
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: '9/11',
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider
              .overrideWith((ref, accountId) async => const []),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('로그인 정보가 만료됐거나 올바르지 않아'),
      findsOneWidget,
    );
    expect(find.text('Command failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reconnects an app password account from the mailbox banner',
      (WidgetTester tester) async {
    const account = MailAccountSummary(
      id: 'auth-failed-account',
      providerId: 'naver',
      emailAddress: 'expired@example.com',
      incomingProtocol: 'imap',
      authMode: 'app-password',
      syncStatus: 'error',
      syncError: 'Command failed',
      syncErrorCode: 'authentication',
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: '9/11',
    );
    final api = _CredentialRecordingApi();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailApiClientProvider.overrideWithValue(api),
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider
              .overrideWith((ref, accountId) async => const []),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, '다시 연결'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'new-app-password');
    await tester.tap(find.widgetWithText(FilledButton, '다시 연결'));
    await tester.pumpAndSettle();

    expect(api.updates, [('auth-failed-account', 'new-app-password')]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('다시 연결했습니다. 메일을 가져오는 중입니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps account management readable at the default window size',
      (WidgetTester tester) async {
    const accounts = [
      MailAccountSummary(
        id: 'account-1',
        providerId: 'gmail',
        emailAddress: 'primary@example.com',
        incomingProtocol: 'imap',
        authMode: 'oauth2',
        syncStatus: 'idle',
        syncError: null,
        initialSync: InitialSyncOption.recommended,
        lastSyncedAtLabel: 'now',
      ),
      MailAccountSummary(
        id: 'account-2',
        providerId: 'gmail',
        emailAddress: 'secondary@example.com',
        incomingProtocol: 'imap',
        authMode: 'oauth2',
        syncStatus: 'idle',
        syncError: null,
        initialSync: InitialSyncOption.recommended,
        lastSyncedAtLabel: 'now',
      ),
    ];
    const providers = [
      MailProviderSummary(
        id: 'gmail',
        displayName: 'Gmail',
        authModes: ['oauth2'],
        defaultProtocol: 'imap',
        supportsOAuth: true,
      ),
    ];
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => accounts),
          providersProvider.overrideWith((ref) async => providers),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('계정 목록'), findsOneWidget);
    expect(find.text('primary@example.com'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('guides Naver setup through an application password',
      (WidgetTester tester) async {
    const providers = [
      MailProviderSummary(
        id: 'naver',
        displayName: 'Naver Mail',
        authModes: ['app-password'],
        defaultProtocol: 'imap',
        supportsOAuth: false,
      ),
    ];
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const []),
          providersProvider.overrideWith((ref) async => providers),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '계정 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Naver Mail'));
    await tester.pumpAndSettle();

    expect(find.text('네이버 메일 연결 준비'), findsOneWidget);
    expect(find.text('애플리케이션 비밀번호'), findsOneWidget);
    expect(find.text('앱 비밀번호 안내'), findsOneWidget);
    expect(find.text('app-password'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('uses the loopback API during local development', () {
    expect(
      resolveMailApiBaseUrl(configured: '', isRelease: false),
      'http://127.0.0.1:4000',
    );
  });

  test('replaces a long mail link with its anchor title', () {
    const url = 'https://example.com/very/long/path?tracking=123';
    final segments = parseMessageBody(
      body: '설정을 완료하려면 시작하기<$url>',
      links: const [
        MessageLink(
          url: 'https://example.com/a/different/html-tracking-link',
          label: '시작하기',
        ),
      ],
    );

    expect(segments.map((item) => item.text).join(), '설정을 완료하려면 시작하기');
    expect(segments.where((item) => item.uri != null).single.text, '시작하기');
    expect(
        segments.where((item) => item.uri != null).single.uri.toString(), url);
  });

  test('uses a domain label for a bare URL and preserves punctuation', () {
    final segments = parseMessageBody(
      body: '문서: https://docs.example.com/guide.',
      links: const [],
    );

    expect(segments.map((item) => item.text).join(), '문서: docs.example.com.');
    expect(segments.where((item) => item.uri != null).single.text,
        'docs.example.com');
  });

  testWidgets('opens a rendered mail link with the external launcher',
      (WidgetTester tester) async {
    const url = 'https://example.com/account/setup';
    Uri? openedUri;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkedMessageBody(
            body: '시작하기<$url>',
            links: const [MessageLink(url: url, label: '시작하기')],
            linkLauncher: (uri) async {
              openedUri = uri;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('linked-message-body-text')));
    await tester.pump();

    expect(openedUri, Uri.parse(url));
  });

  test('merges word boxes into one continuous underline per line', () {
    final merged = mergeLinkUnderlineBoxes(const [
      TextBox.fromLTRBD(0, 0, 42, 20, TextDirection.ltr),
      TextBox.fromLTRBD(50, 2, 88, 18, TextDirection.ltr),
      TextBox.fromLTRBD(0, 24, 36, 44, TextDirection.ltr),
    ]);

    expect(merged, const [
      Rect.fromLTRB(0, 0, 88, 20),
      Rect.fromLTRB(0, 24, 36, 44),
    ]);
  });
}

class _CredentialRecordingApi extends MailApiClient {
  _CredentialRecordingApi() : super(baseUrl: 'http://127.0.0.1:1');

  final updates = <(String, String)>[];

  @override
  Future<void> updateAccountCredentials({
    required String accountId,
    required String secret,
  }) async {
    updates.add((accountId, secret));
  }
}
