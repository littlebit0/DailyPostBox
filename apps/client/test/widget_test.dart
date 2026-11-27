import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:daily_postbox/features/accounts/accounts_page.dart';
import 'package:daily_postbox/features/message/compose_page.dart';
import 'package:daily_postbox/features/message/linked_message_body.dart';
import 'package:daily_postbox/features/message/message_page.dart';
import 'package:daily_postbox/core/i18n/language_controller.dart';
import 'package:daily_postbox/features/message/reply_draft.dart';
import 'package:daily_postbox/main.dart';
import 'package:daily_postbox/services/mail_api_client.dart';

void main() {
  test(
    'failed attachment download keeps the existing destination file',
    () async {
      final dir = Directory.systemTemp.createTempSync('dl');
      addTearDown(() => dir.deleteSync(recursive: true));
      final target = File('${dir.path}/a.txt')..writeAsStringSync('keep');
      final client = MailApiClient(baseUrl: 'http://127.0.0.1:1');
      await expectLater(
        client.downloadAttachment(
          accountId: 'a',
          messageId: 'm',
          part: '1',
          savePath: target.path,
        ),
        throwsA(isA<DioException>()),
      );
      expect(target.readAsStringSync(), 'keep');
      expect(File('${target.path}.part').existsSync(), isFalse);
    },
  );

  test(
    'successful attachment download writes destination, leaves no temp',
    () async {
      final httpOverrides = HttpOverrides.current;
      HttpOverrides.global = null; // test binding stubs HTTP with 400
      addTearDown(() => HttpOverrides.global = httpOverrides);
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) {
        req.response.add([1, 2, 3]);
        req.response.close();
      });
      final dir = Directory.systemTemp.createTempSync('dl');
      addTearDown(() => dir.deleteSync(recursive: true));
      final target = File('${dir.path}/a.bin')..writeAsStringSync('old');
      final sibling = File('${dir.path}/a.bin.part')
        ..writeAsStringSync('other');
      final client = MailApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
      await client.downloadAttachment(
        accountId: 'a',
        messageId: 'm',
        part: '1',
        savePath: target.path,
      );
      expect(target.readAsBytesSync(), [1, 2, 3]);
      expect(sibling.readAsStringSync(), 'other');
      expect(dir.listSync().length, 2);
    },
  );

  test('replySubject adds Re: once', () {
    expect(replySubject('Hello'), 'Re: Hello');
    expect(replySubject('Re: Hello'), 'Re: Hello');
    expect(replySubject('RE: Hello'), 'RE: Hello');
  });

  test('ReplyDraft quote header uses absolute local date-time', () async {
    await initializeDateFormatting();
    final iso = DateTime(2026, 11, 20, 17, 12).toIso8601String();
    final message = MessageDetail.fromJson({
      'id': '1',
      'from': 'a@x.com',
      'body': 'hi',
      'receivedAt': iso,
    });
    expect(
      ReplyDraft.from(message, AppStrings(AppLanguage.korean), all: false).body,
      contains('2026-11-20 (금) 17:12 a@x.com 님이 작성:'),
    );
    expect(
      ReplyDraft.from(
        message,
        AppStrings(AppLanguage.english),
        all: false,
      ).body,
      contains('On Fri, Nov 20, 2026 at 17:12, a@x.com wrote:'),
    );
  });

  test('ReplyDraft quotes the original and keeps thread ids', () {
    final message = MessageDetail.fromJson({
      'id': '1',
      'from': 'a@x.com',
      'subject': 'Hi',
      'body': 'line1\nline2',
      'messageId': '<m1@x>',
      'references': ['<r0@x>'],
      'replyTo': ['a@x.com'],
      'replyAllTo': ['a@x.com', 'b@x.com'],
      'replyAllCc': ['c@x.com'],
    });
    final strings = AppStrings(AppLanguage.english);
    final all = ReplyDraft.from(message, strings, all: true);
    expect(all.to, ['a@x.com', 'b@x.com']);
    expect(all.cc, ['c@x.com']);
    expect(all.subject, 'Re: Hi');
    expect(all.body, contains('> line1\n> line2'));
    expect(all.inReplyTo, '<m1@x>');
    expect(ReplyDraft.from(message, strings, all: false).cc, isEmpty);
  });

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

  testWidgets('shows a friendly server connection error', (
    WidgetTester tester,
  ) async {
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

  testWidgets('opens a connected account mailbox from the sidebar', (
    WidgetTester tester,
  ) async {
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

  testWidgets('clears search results when switching to another account', (
    WidgetTester tester,
  ) async {
    const first = MailAccountSummary(
      id: 'account-a',
      providerId: 'gmail',
      emailAddress: 'first@example.com',
      incomingProtocol: 'imap',
      authMode: 'oauth2',
      syncStatus: 'idle',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'now',
    );
    const second = MailAccountSummary(
      id: 'account-b',
      providerId: 'gmail',
      emailAddress: 'second@example.com',
      incomingProtocol: 'imap',
      authMode: 'oauth2',
      syncStatus: 'idle',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'now',
    );
    final api = _SearchApi();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailApiClientProvider.overrideWithValue(api),
          accountsProvider.overrideWith((ref) async => const [first, second]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => const [],
          ),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(first.emailAddress).first);
    await tester.pumpAndSettle();
    final searchField = find.descendant(
      of: find.byType(Scaffold).last,
      matching: find.byType(TextField),
    );
    await tester.enterText(searchField.first, 'invoice');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text(_SearchApi.resultSubject), findsOneWidget);

    await tester.tap(find.text(second.emailAddress).first);
    await tester.pumpAndSettle();

    expect(find.text(_SearchApi.resultSubject), findsNothing);
    expect(find.text('invoice'), findsNothing);
  });

  testWidgets('category chips also filter search results', (
    WidgetTester tester,
  ) async {
    const account = MailAccountSummary(
      id: 'account-a',
      providerId: 'gmail',
      emailAddress: 'first@example.com',
      incomingProtocol: 'imap',
      authMode: 'oauth2',
      syncStatus: 'idle',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'now',
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailApiClientProvider.overrideWithValue(_SearchApi()),
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => const [],
          ),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(Scaffold).last,
            matching: find.byType(TextField),
          )
          .first,
      'invoice',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text(_SearchApi.resultSubject), findsOneWidget);

    // The result is unclassified, so the newsletter chip hides it.
    await tester.tap(find.byType(ChoiceChip).at(3));
    await tester.pumpAndSettle();
    expect(find.text(_SearchApi.resultSubject), findsNothing);
  });

  testWidgets('shows loading instead of previous results for a new search', (
    WidgetTester tester,
  ) async {
    const account = MailAccountSummary(
      id: 'account-a',
      providerId: 'gmail',
      emailAddress: 'first@example.com',
      incomingProtocol: 'imap',
      authMode: 'oauth2',
      syncStatus: 'idle',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'now',
    );
    final api = _DelayedSearchApi();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailApiClientProvider.overrideWithValue(api),
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => const [],
          ),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();
    final searchField = find
        .descendant(
          of: find.byType(Scaffold).last,
          matching: find.byType(TextField),
        )
        .first;
    await tester.enterText(searchField, 'invoice');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    api.pending.removeAt(0).complete(const [_DelayedSearchApi.firstResult]);
    await tester.pumpAndSettle();
    expect(find.text(_DelayedSearchApi.firstResult.subject), findsOneWidget);

    await tester.enterText(searchField, 'receipt');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(find.text(_DelayedSearchApi.firstResult.subject), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    api.pending.removeAt(0).complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets('moves mailbox selection with j/k and shows shortcut help', (
    WidgetTester tester,
  ) async {
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
    const messages = [
      MailSummary(
        id: 'm1',
        sender: 'a@example.com',
        subject: '첫째 메일',
        snippet: '',
        receivedAtLabel: 'now',
        unread: true,
      ),
      MailSummary(
        id: 'm2',
        sender: 'b@example.com',
        subject: '둘째 메일',
        snippet: '',
        receivedAtLabel: 'now',
        unread: true,
      ),
    ];
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => messages,
          ),
          messageProvider.overrideWith(
            (ref, request) async => MessageDetail.fromJson({
              'id': request.messageId,
              'accountId': request.accountId,
              'from': 'a@example.com',
              'subject': '열린 메일',
              'body': 'hi',
              'seen': true,
            }),
          ),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    bool selected(String subject) => tester
        .widget<ListTile>(find.widgetWithText(ListTile, subject))
        .selected;

    Future<void> press(LogicalKeyboardKey key, String character) async {
      await tester.sendKeyDownEvent(key, character: character);
      await tester.sendKeyUpEvent(key);
      await tester.pump();
    }

    await press(LogicalKeyboardKey.keyJ, 'j');
    expect(selected('첫째 메일'), isTrue);
    await press(LogicalKeyboardKey.keyJ, 'j');
    await tester.pump();
    expect(selected('둘째 메일'), isTrue);
    await press(LogicalKeyboardKey.keyK, 'k');
    expect(selected('첫째 메일'), isTrue);

    await press(LogicalKeyboardKey.slash, '?');
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('둘째 메일'), findsNothing);
  });

  testWidgets('slash focuses mailbox search and typing there skips j/k', (
    WidgetTester tester,
  ) async {
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
    const messages = [
      MailSummary(
        id: 'm1',
        sender: 'a@example.com',
        subject: '첫째 메일',
        snippet: '',
        receivedAtLabel: 'now',
        unread: true,
      ),
    ];
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => messages,
          ),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.slash, character: '/');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNotNull,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ, character: 'j');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '첫째 메일')).selected,
      isFalse,
    );
  });

  testWidgets('keeps the native menu bar after leaving the mailbox', (
    WidgetTester tester,
  ) async {
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
    final menuCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.menu,
      (call) async {
        menuCalls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.menu, null),
    );
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => const <MailSummary>[],
          ),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    String lastMenus() => menuCalls
        .lastWhere((call) => call.method == 'Menu.setMenus')
        .arguments
        .toString();
    final quitId = PlatformProvidedMenuItemType.quit.index;
    expect(lastMenus(), contains('메일 쓰기'));
    expect(lastMenus(), contains('platformProvidedMenu: $quitId'));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyC, character: 'c');
    await tester.pumpAndSettle();

    expect(find.byType(PlatformMenuBar), findsOneWidget);
    expect(lastMenus(), contains('platformProvidedMenu: $quitId'));
    expect(lastMenus(), isNot(contains('메일 쓰기')));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Enter on a Tab-focused button activates it, not the message', (
    WidgetTester tester,
  ) async {
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
    const messages = [
      MailSummary(
        id: 'm1',
        sender: 'a@example.com',
        subject: '첫째 메일',
        snippet: '',
        receivedAtLabel: 'now',
        unread: true,
      ),
    ];
    var loads = 0;
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith((ref, accountId) async {
            loads++;
            return messages;
          }),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ, character: 'j');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();

    // Tab until the refresh FAB holds focus.
    for (var i = 0;
        i < 20 &&
            FocusManager.instance.primaryFocus?.context
                    ?.findAncestorWidgetOfExactType<IconButton>() ==
                null;
        i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<IconButton>(),
      isNotNull,
    );

    final before = loads;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    // Refresh handler ran; the selected message was not opened.
    expect(loads, greaterThan(before));
    expect(find.text('첫째 메일'), findsOneWidget);
  });

  testWidgets('keeps the j/k selected mailbox row visible', (
    WidgetTester tester,
  ) async {
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
    final messages = [
      for (var i = 0; i < 30; i++)
        MailSummary(
          id: 'm$i',
          sender: 'a@example.com',
          subject: '메일 $i',
          snippet: '',
          receivedAtLabel: 'now',
          unread: true,
        ),
    ];
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [account]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => messages,
          ),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    for (var i = 0; i < 15; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ, character: 'j');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
      await tester.pumpAndSettle();
    }
    final rect = tester.getRect(find.widgetWithText(ListTile, '메일 14'));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(600));
  });

  testWidgets('shows a progressive loading state during account sync', (
    WidgetTester tester,
  ) async {
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
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => const [],
          ),
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

  testWidgets('shows the receive mode from IMAP capabilities', (
    WidgetTester tester,
  ) async {
    final json = {
      'id': 'a',
      'providerId': 'naver',
      'emailAddress': 'a@example.com',
      'incomingProtocol': 'imap',
    };
    final polling = MailAccountSummary.fromJson({
      ...json,
      'incomingCapabilities': {
        'idle': false,
        'checkedAt': '2020-01-01T00:00:00Z',
      },
    });
    final unknown = MailAccountSummary.fromJson(json);
    expect(polling.idleSupported, isFalse);
    expect(unknown.idleSupported, isNull);

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => [polling]),
          providersProvider.overrideWith((ref) async => const []),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('계정관리').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('주기 확인'), findsOneWidget);
  });

  testWidgets('keeps the syncing mailbox when an account refresh fails', (
    WidgetTester tester,
  ) async {
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
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => const [],
          ),
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

  testWidgets('reloads mail once more when account sync finishes', (
    WidgetTester tester,
  ) async {
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

  testWidgets('keeps polling and reloads mail when thread backfill finishes', (
    WidgetTester tester,
  ) async {
    const syncing = MailAccountSummary(
      id: 'syncing-account',
      providerId: 'naver',
      emailAddress: 'syncing@example.com',
      incomingProtocol: 'imap',
      authMode: 'app-password',
      syncStatus: 'idle',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'never',
      threadBackfilling: true,
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

  testWidgets('explains an authentication failure in the mailbox', (
    WidgetTester tester,
  ) async {
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
          accountMessagesProvider.overrideWith(
            (ref, accountId) async => const [],
          ),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    expect(find.textContaining('로그인 정보가 만료됐거나 올바르지 않아'), findsOneWidget);
    expect(find.text('Command failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reconnects an app password account from the mailbox banner', (
    WidgetTester tester,
  ) async {
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
    var messageLoads = 0;
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailApiClientProvider.overrideWithValue(api),
          accountsProvider.overrideWith((ref) async => const [account]),
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
    await tester.tap(find.text(account.emailAddress).first);
    await tester.pumpAndSettle();

    final loadsBeforeReconnect = messageLoads;
    await tester.tap(find.widgetWithText(TextButton, '다시 연결'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'new-app-password',
    );
    await tester.tap(find.widgetWithText(FilledButton, '다시 연결'));
    await tester.pumpAndSettle();

    expect(api.updates, [('auth-failed-account', 'new-app-password')]);
    expect(messageLoads, greaterThan(loadsBeforeReconnect));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('다시 연결했습니다. 메일을 가져오는 중입니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps account management readable at the default window size', (
    WidgetTester tester,
  ) async {
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

  testWidgets('guides Naver setup through an application password', (
    WidgetTester tester,
  ) async {
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

  test('parses attachments and formats their size', () {
    final detail = MessageDetail.fromJson({
      'attachments': [
        {
          'part': '2',
          'filename': '보고서.pdf',
          'contentType': 'application/pdf',
          'size': 1536,
        },
      ],
    });

    expect(detail.attachments.single.filename, '보고서.pdf');
    expect(formatAttachmentSize(detail.attachments.single.size), '1.5 KB');
    expect(formatAttachmentSize(20 * 1024 * 1024), '20 MB');
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
      segments.where((item) => item.uri != null).single.uri.toString(),
      url,
    );
  });

  test('uses a domain label for a bare URL and preserves punctuation', () {
    final segments = parseMessageBody(
      body: '문서: https://docs.example.com/guide.',
      links: const [],
    );

    expect(segments.map((item) => item.text).join(), '문서: docs.example.com.');
    expect(
      segments.where((item) => item.uri != null).single.text,
      'docs.example.com',
    );
  });

  testWidgets('opens a rendered mail link with the external launcher', (
    WidgetTester tester,
  ) async {
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

  test('swaps the signature only when the user has not edited it', () {
    expect(swapSignature('', '', 'A'), '\n\n-- \nA');
    expect(swapSignature('hi', '', ''), 'hi');
    expect(swapSignature('hi\n\n-- \nA', 'A', 'B'), 'hi\n\n-- \nB');
    expect(swapSignature('hi\n\n-- \nA', 'A', ''), 'hi');
    expect(
      swapSignature('hi\n\n-- \nA edited', 'A', 'B'),
      'hi\n\n-- \nA edited',
    );
  });

  testWidgets('compose appends the account signature and swaps it', (
    WidgetTester tester,
  ) async {
    const accounts = [
      MailAccountSummary(
        id: 'a',
        providerId: 'gmail',
        emailAddress: 'a@example.com',
        incomingProtocol: 'imap',
        authMode: 'oauth2',
        syncStatus: 'idle',
        syncError: null,
        initialSync: InitialSyncOption.recommended,
        lastSyncedAtLabel: 'now',
        signature: 'Sig A',
      ),
      MailAccountSummary(
        id: 'b',
        providerId: 'gmail',
        emailAddress: 'b@example.com',
        incomingProtocol: 'imap',
        authMode: 'oauth2',
        syncStatus: 'idle',
        syncError: null,
        initialSync: InitialSyncOption.recommended,
        lastSyncedAtLabel: 'now',
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          composeAccountsProvider.overrideWith((ref) async => accounts),
        ],
        child: const MaterialApp(home: ComposePage()),
      ),
    );
    await tester.pumpAndSettle();

    String body() =>
        tester.widget<TextField>(find.byType(TextField).last).controller!.text;
    expect(body(), '\n\n-- \nSig A');

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b@example.com').last);
    await tester.pumpAndSettle();
    expect(body(), '');
  });

  testWidgets('reply puts the signature above the quote; recovery adds none', (
    WidgetTester tester,
  ) async {
    const accounts = [
      MailAccountSummary(
        id: 'a',
        providerId: 'gmail',
        emailAddress: 'a@example.com',
        incomingProtocol: 'imap',
        authMode: 'oauth2',
        syncStatus: 'idle',
        syncError: null,
        initialSync: InitialSyncOption.recommended,
        lastSyncedAtLabel: 'now',
        signature: 'Sig A',
      ),
    ];
    Future<String> open(ComposePage page) async {
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            composeAccountsProvider.overrideWith((ref) async => accounts),
          ],
          child: MaterialApp(home: page),
        ),
      );
      await tester.pumpAndSettle();
      return tester
          .widget<TextField>(find.byType(TextField).last)
          .controller!
          .text;
    }

    const quote = '\n\nOn x, y wrote:\n> hi';
    expect(
      await open(
        const ComposePage(
          reply: ReplyDraft(
            to: ['y@example.com'],
            cc: [],
            subject: 'Re: s',
            body: quote,
          ),
        ),
      ),
      '\n\n-- \nSig A$quote',
    );
    const recovered = 'text\n\n-- \nSig A';
    expect(
      await open(
        const ComposePage(
          initialDraft: ComposeDraft(
            accountId: 'a',
            to: 'y@example.com',
            subject: 's',
            body: recovered,
          ),
        ),
      ),
      recovered,
    );
  });

  testWidgets('compose keeps an edited signature without duplicating it', (
    WidgetTester tester,
  ) async {
    MailAccountSummary account(String id, String signature) =>
        MailAccountSummary(
          id: id,
          providerId: 'gmail',
          emailAddress: '$id@example.com',
          incomingProtocol: 'imap',
          authMode: 'oauth2',
          syncStatus: 'idle',
          syncError: null,
          initialSync: InitialSyncOption.recommended,
          lastSyncedAtLabel: 'now',
          signature: signature,
        );
    final accounts = [account('a', 'Sig A'), account('b', '')];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          composeAccountsProvider.overrideWith((ref) async => accounts),
        ],
        child: const MaterialApp(home: ComposePage()),
      ),
    );
    await tester.pumpAndSettle();

    final bodyField = tester.widget<TextField>(find.byType(TextField).last);
    bodyField.controller!.text = '\n\n-- \nSig A edited';

    Future<void> pick(String email) async {
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(email).last);
      await tester.pumpAndSettle();
    }

    await pick('b@example.com');
    await pick('a@example.com');
    expect(bodyField.controller!.text, '\n\n-- \nSig A edited');
  });

  testWidgets('compose types before the signature and still swaps it', (
    WidgetTester tester,
  ) async {
    MailAccountSummary account(String id, String signature) =>
        MailAccountSummary(
          id: id,
          providerId: 'gmail',
          emailAddress: '$id@example.com',
          incomingProtocol: 'imap',
          authMode: 'oauth2',
          syncStatus: 'idle',
          syncError: null,
          initialSync: InitialSyncOption.recommended,
          lastSyncedAtLabel: 'now',
          signature: signature,
        );
    final accounts = [account('a', 'Sig A'), account('b', 'Sig B')];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          composeAccountsProvider.overrideWith((ref) async => accounts),
        ],
        child: const MaterialApp(home: ComposePage()),
      ),
    );
    await tester.pumpAndSettle();

    final controller = tester
        .widget<TextField>(find.byType(TextField).last)
        .controller!;
    await tester.showKeyboard(find.byType(TextField).last);
    await tester.pump();
    // Type at the caret the way the platform IME does.
    final value = controller.value;
    tester.testTextInput.updateEditingValue(
      value.replaced(value.selection, 'Hi'),
    );
    await tester.pump();
    expect(controller.text, 'Hi\n\n-- \nSig A');

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b@example.com').last);
    await tester.pumpAndSettle();
    expect(controller.text, 'Hi\n\n-- \nSig B');
    expect(controller.selection, const TextSelection.collapsed(offset: 2));
  });

  testWidgets('signature save refreshes caches after switching accounts', (
    WidgetTester tester,
  ) async {
    MailAccountSummary account(String id) => MailAccountSummary(
      id: id,
      providerId: 'gmail',
      emailAddress: '$id@example.com',
      incomingProtocol: 'imap',
      authMode: 'oauth2',
      syncStatus: 'idle',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'now',
    );
    final api = _SlowSignatureApi();
    var accountLoads = 0;
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailApiClientProvider.overrideWithValue(api),
          accountsProvider.overrideWith((ref) async {
            accountLoads += 1;
            return [account('first'), account('second')];
          }),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith((ref, id) async => const []),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('계정관리').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Sig');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();

    await tester.tap(find.text('second@example.com').first);
    await tester.pumpAndSettle();
    final loadsBefore = accountLoads;
    api.release.complete();
    await tester.pumpAndSettle();

    expect(api.saved, [('first', 'Sig')]);
    expect(accountLoads, greaterThan(loadsBefore));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
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

  testWidgets('shows unsubscribe only for messages with the header', (
    WidgetTester tester,
  ) async {
    MessageDetail detail(Map<String, dynamic> extra) => MessageDetail.fromJson({
      'id': 'm1',
      'accountId': 'a1',
      'from': 'news@example.test',
      'subject': 'news',
      'body': 'hi',
      // Already read, so opening it does not call the flag API.
      'seen': true,
      ...extra,
    });
    final withHeader = detail({
      'unsubscribe': {'url': 'https://example.test/u', 'oneClick': false},
    });
    expect(withHeader.canUnsubscribe, isTrue);
    expect(detail({}).canUnsubscribe, isFalse);

    Future<void> pump(MessageDetail item) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messageProvider.overrideWith((ref, request) async => item),
          ],
          child: const MaterialApp(
            home: MessagePage(messageId: 'm1', accountId: 'a1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump(withHeader);
    expect(find.text('수신 거부'), findsOneWidget);
    await pump(detail({}));
    expect(find.text('수신 거부'), findsNothing);
  });

  test('unclassified mail appears only under All', () {
    MailSummary mail(String id, String? category) => MailSummary(
      id: id,
      sender: '',
      subject: '',
      snippet: '',
      receivedAtLabel: '',
      unread: true,
      category: category,
    );
    final items = [
      mail('1', null),
      mail('2', 'person'),
      mail('3', 'newsletter'),
    ];

    expect(filterByCategory(items, null).map((m) => m.id), ['1', '2', '3']);
    expect(filterByCategory(items, 'person').map((m) => m.id), ['2']);
  });

  test('groups mail by thread id and keeps unthreaded mail', () {
    MailSummary mail(String id, String? thread) => MailSummary(
      id: id,
      sender: '',
      subject: '',
      snippet: '',
      receivedAtLabel: '',
      unread: true,
      threadId: thread,
    );

    final grouped = groupByThread([
      mail('1', 'a'),
      mail('2', 'b'),
      mail('3', 'a'),
      mail('4', null),
    ]);

    expect(grouped.map((item) => item.id), ['1', '2', '4']);
  });

  testWidgets('does not offer the unimplemented POP3 protocol', (
    WidgetTester tester,
  ) async {
    const daum = MailProviderSummary(
      id: 'daum',
      displayName: 'Daum / Kakao Mail',
      authModes: ['password', 'app-password'],
      defaultProtocol: 'imap',
      supportsOAuth: false,
    );
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const []),
          providersProvider.overrideWith((ref) async => const [daum]),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('계정 추가').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daum / Kakao Mail'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsWidgets);
    expect(find.text('POP3'), findsNothing);
  });
  testWidgets('adds a custom mail server account with its server settings', (
    WidgetTester tester,
  ) async {
    const custom = MailProviderSummary(
      id: 'custom',
      displayName: 'Custom Mail Server',
      authModes: ['password'],
      defaultProtocol: 'imap',
      supportsOAuth: false,
    );
    final api = _AccountRecordingApi();
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailApiClientProvider.overrideWithValue(api),
          accountsProvider.overrideWith((ref) async => const []),
          providersProvider.overrideWith((ref) async => const [custom]),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('계정 추가').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom Mail Server'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'me@example.com');
    await tester.enterText(fields.at(1), 'password');

    // Without server addresses the account is not sent.
    await tester.tap(find.widgetWithText(FilledButton, '계정 추가').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('받는·보내는 서버 주소'), findsOneWidget);
    expect(api.added, isEmpty);

    await tester.enterText(fields.at(2), 'imap.example.com');
    await tester.enterText(fields.at(4), 'smtp.example.com');
    await tester.enterText(fields.at(5), '587');
    await tester.tap(find.text('SSL/TLS 사용').last);
    await tester.tap(find.widgetWithText(FilledButton, '계정 추가').last);
    await tester.pumpAndSettle();

    expect(api.validated.single, api.added.single);
    expect(api.added.single, {
      'incoming': {'host': 'imap.example.com', 'port': 993, 'secure': true},
      'outgoing': {'host': 'smtp.example.com', 'port': 587, 'secure': false},
    });
  });

  testWidgets('shows mail that arrives after sync without a manual refresh', (
    WidgetTester tester,
  ) async {
    const idle = MailAccountSummary(
      id: 'idle-account',
      providerId: 'naver',
      emailAddress: 'idle@example.com',
      incomingProtocol: 'imap',
      authMode: 'app-password',
      syncStatus: 'idle',
      syncError: null,
      initialSync: InitialSyncOption.recommended,
      lastSyncedAtLabel: 'now',
    );
    const arrived = MailSummary(
      id: '42',
      sender: 'sender@example.com',
      subject: 'Arrived by IDLE',
      snippet: '',
      receivedAtLabel: 'now',
      unread: true,
    );
    var messageLoads = 0;
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [idle]),
          providersProvider.overrideWith((ref) async => const []),
          accountMessagesProvider.overrideWith((ref, accountId) async {
            messageLoads += 1;
            return messageLoads == 1 ? const [] : const [arrived];
          }),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(idle.emailAddress).first);
    await tester.pumpAndSettle();
    expect(find.text('Arrived by IDLE'), findsNothing);

    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    await tester.pump();

    expect(find.text('Arrived by IDLE'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('message flag updates', () {
    Future<_FlagApi> pumpMessage(WidgetTester tester, _FlagApi api) async {
      final router = GoRouter(
        initialLocation: '/m',
        routes: [
          GoRoute(
            path: '/m',
            builder: (context, state) =>
                const MessagePage(messageId: 'm1', accountId: 'a1'),
          ),
          GoRoute(
            path: '/other',
            builder: (context, state) => const SizedBox(),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mailApiClientProvider.overrideWithValue(api),
            accountsProvider.overrideWith((ref) async => const []),
            providersProvider.overrideWith((ref) async => const []),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump();
      return api;
    }

    testWidgets('failed older request does not undo newer star', (
      tester,
    ) async {
      final api = await pumpMessage(tester, _FlagApi());
      expect(api.calls, hasLength(1)); // auto mark-read, pending
      await tester.tap(find.byIcon(Icons.star_border));
      await tester.pump();
      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(api.calls, hasLength(1)); // second request waits for the first
      api.calls[0].completeError(Exception('x'));
      await tester.pump();
      await tester.pump();
      expect(api.calls, hasLength(2));
      api.calls[1].complete();
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('consecutive failures restore the confirmed state', (
      tester,
    ) async {
      final api = await pumpMessage(tester, _FlagApi());
      api.calls[0].complete();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.star_border));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.star));
      await tester.pump();
      api.calls[1].completeError(Exception('x'));
      await tester.pump();
      await tester.pump();
      api.calls[2].completeError(Exception('x'));
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.star_border), findsOneWidget);
      expect(find.byIcon(Icons.star), findsNothing);
    });

    testWidgets('failure after confirmed star restores starred', (
      tester,
    ) async {
      final api = await pumpMessage(tester, _FlagApi());
      api.calls[0].complete();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.star_border));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.star));
      await tester.pump();
      api.calls[1].complete();
      await tester.pump();
      await tester.pump();
      api.calls[2].completeError(Exception('x'));
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('same-flag requests are sent in order', (tester) async {
      final api = await pumpMessage(tester, _FlagApi());
      api.calls[0].complete();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.star_border));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.star));
      await tester.pump();
      expect(api.sent, [true]); // unstar not sent until star finishes
      api.calls[1].complete();
      await tester.pump();
      await tester.pump();
      expect(api.sent, [true, false]);
    });

    testWidgets('success after leaving page refreshes cached detail', (
      tester,
    ) async {
      final api = await pumpMessage(tester, _FlagApi());
      final fetchesBefore = api.fetches;
      final router = GoRouter.of(tester.element(find.byType(MessagePage)));
      router.go('/other');
      await tester.pump();
      await tester.pump();
      api.calls[0].complete();
      await tester.pump();
      await tester.pump();
      // Cache is only dropped; it refetches when the detail page reopens.
      router.go('/m');
      await tester.pump();
      await tester.pump();
      expect(api.fetches, greaterThan(fetchesBefore));
      expect(tester.takeException(), isNull);
    });
  });
}

class _FlagApi extends MailApiClient {
  _FlagApi() : super(baseUrl: 'http://127.0.0.1:1');

  final calls = <Completer<void>>[];
  var fetches = 0;
  final sent = <bool>[]; // flagged values in send order

  @override
  Future<MessageDetail> fetchAccountMessage({
    required String accountId,
    required String messageId,
    bool remoteImages = false,
  }) async {
    fetches++;
    return const MessageDetail(
      id: 'm1',
      sender: 's',
      subject: 'sub',
      body: 'b',
      links: [],
      receivedAtLabel: 'now',
    );
  }

  @override
  Future<void> setMessageFlags({
    required String accountId,
    required String messageId,
    bool? seen,
    bool? flagged,
  }) {
    final c = Completer<void>();
    calls.add(c);
    if (flagged != null) sent.add(flagged);
    return c.future;
  }
}

class _SearchApi extends MailApiClient {
  _SearchApi() : super(baseUrl: 'http://127.0.0.1:1');

  static const resultSubject = '첫 계정 검색 결과';

  @override
  Future<List<MailSummary>> searchAccountMessages(
    String accountId,
    String query,
  ) async {
    return [
      const MailSummary(
        id: 'uid-1',
        sender: 'billing@example.com',
        subject: resultSubject,
        snippet: '',
        receivedAtLabel: 'now',
        unread: false,
      ),
    ];
  }
}

class _DelayedSearchApi extends MailApiClient {
  _DelayedSearchApi() : super(baseUrl: 'http://127.0.0.1:1');

  static const firstResult = MailSummary(
    id: 'uid-1',
    sender: 'billing@example.com',
    subject: '이전 검색 결과',
    snippet: '',
    receivedAtLabel: 'now',
    unread: false,
  );

  final pending = <Completer<List<MailSummary>>>[];

  @override
  Future<List<MailSummary>> searchAccountMessages(
    String accountId,
    String query,
  ) {
    final completer = Completer<List<MailSummary>>();
    pending.add(completer);
    return completer.future;
  }
}

class _SlowSignatureApi extends MailApiClient {
  _SlowSignatureApi() : super(baseUrl: 'http://127.0.0.1:1');

  final release = Completer<void>();
  final saved = <(String, String)>[];

  @override
  Future<void> updateAccountSignature({
    required String accountId,
    required String signature,
  }) async {
    await release.future;
    saved.add((accountId, signature));
  }
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

class _AccountRecordingApi extends MailApiClient {
  _AccountRecordingApi() : super(baseUrl: 'http://127.0.0.1:1');

  final validated = <Map<String, Object>?>[];
  final added = <Map<String, Object>?>[];

  @override
  Future<void> validateAccount({
    required String providerId,
    required String emailAddress,
    required String authMode,
    required String incomingProtocol,
    required String secret,
    required InitialSyncOption initialSync,
    ConnectionOverride? connectionOverride,
  }) async {
    validated.add(connectionOverride?.toJson());
  }

  @override
  Future<void> addAccount({
    required String providerId,
    required String emailAddress,
    required String authMode,
    required String incomingProtocol,
    required String secret,
    required InitialSyncOption initialSync,
    ConnectionOverride? connectionOverride,
  }) async {
    added.add(connectionOverride?.toJson());
  }
}
