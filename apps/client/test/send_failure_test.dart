import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:daily_postbox/features/message/compose_page.dart';
import 'package:daily_postbox/features/message/failed_sends.dart';
import 'package:daily_postbox/features/accounts/account_providers.dart';
import 'package:daily_postbox/services/mail_api_client.dart';
import 'package:daily_postbox/widgets/app_shell.dart';

const _draft = ComposeDraft(
  accountId: 'a1',
  to: 'x@example.com, y@example.com',
  subject: 'Hello',
  body: 'Body text',
);

class _PollApi extends MailApiClient {
  _PollApi(this.outcomes) : super(baseUrl: 'http://127.0.0.1:1');
  final List<SendOutcome> outcomes;
  int calls = 0;

  @override
  Future<SendOutcome> fetchSendOutcome(String id) async =>
      outcomes[calls++ < outcomes.length ? calls - 1 : outcomes.length - 1];
}

class _SendApi extends MailApiClient {
  _SendApi() : super(baseUrl: 'http://127.0.0.1:1');

  @override
  Future<SendReceipt> sendMail({
    required String accountId,
    required List<String> to,
    required String subject,
    required String body,
    int delaySeconds = 5,
  }) async =>
      const SendReceipt('id', Duration(seconds: 5));

  @override
  Future<SendOutcome> fetchSendOutcome(String id) async =>
      const SendOutcome(status: 'sent');
}

void main() {
  _failedSendsTests();
  _pendingSendsTests();
  const receipt = SendReceipt('id', Duration.zero);
  const tick = Duration(milliseconds: 1);

  test('polls past sending and returns the failed outcome with its draft',
      () async {
    final api = _PollApi([
      const SendOutcome(status: 'pending'),
      const SendOutcome(status: 'sending'),
      const SendOutcome(status: 'failed', error: 'auth', draft: _draft),
    ]);
    final outcome = await awaitSendOutcome(api, receipt, interval: tick);
    expect(outcome?.error, 'auth');
    expect(outcome?.draft?.subject, 'Hello');
    expect(api.calls, 3);
  });

  test('stops quietly once the mail is sent', () async {
    final api = _PollApi([const SendOutcome(status: 'sent')]);
    expect(await awaitSendOutcome(api, receipt, interval: tick), isNull);
    expect(api.calls, 1);
  });

  testWidgets('composer reopens prefilled with the failed draft',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        composeAccountsProvider.overrideWith((ref) async => const []),
      ],
      child: const MaterialApp(home: ComposePage(initialDraft: _draft)),
    ));
    await tester.pump();
    expect(find.text('x@example.com, y@example.com'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('Body text'), findsOneWidget);
  });

  test('keeps polling past 10 tries while still sending, until failure',
      () async {
    final api = _PollApi([
      for (var i = 0; i < 25; i++) const SendOutcome(status: 'sending'),
      const SendOutcome(status: 'failed', error: 'late', draft: _draft),
    ]);
    final outcome = await awaitSendOutcome(api, receipt,
        interval: tick, maxInterval: tick, maxWait: const Duration(seconds: 5));
    expect(outcome?.error, 'late');
    expect(api.calls, 26);
  });

  test('gives up after maxWait while still pending', () async {
    final api = _PollApi([const SendOutcome(status: 'pending')]);
    expect(
        await awaitSendOutcome(api, receipt,
            interval: tick,
            maxInterval: tick,
            maxWait: const Duration(milliseconds: 20)),
        isNull);
  });

  testWidgets('recovery is stacked: original compose input survives pop',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const ComposePage()),
      GoRoute(
        path: '/compose/recover',
        builder: (_, state) =>
            ComposePage(initialDraft: state.extra as ComposeDraft),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        composeAccountsProvider.overrideWith((ref) async => const [])
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'typing in progress');
    router.push('/compose/recover', extra: _draft);
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('typing in progress'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);
  });

  testWidgets(
      'sending from recovery pops back to the original compose with undo snackbar',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const ComposePage()),
      GoRoute(
        path: '/compose/recover',
        builder: (_, state) =>
            ComposePage(initialDraft: state.extra as ComposeDraft),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mailApiClientProvider.overrideWithValue(_SendApi()),
        composeAccountsProvider.overrideWith((ref) async => const [
              MailAccountSummary(
                id: 'a1',
                providerId: 'p',
                emailAddress: 'me@example.test',
                incomingProtocol: 'imap',
                authMode: 'password',
                syncStatus: 'idle',
                syncError: null,
                initialSync: null,
                lastSyncedAtLabel: '',
              ),
            ]),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'typing in progress');
    router.push('/compose/recover', extra: _draft);
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.text('typing in progress'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(SnackBarAction), findsOneWidget);

    // Let the snackbar and the detached outcome poll finish before teardown.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 3));
  });
}

class _FailApi extends _SendApi {
  @override
  Future<SendOutcome> fetchSendOutcome(String id) async =>
      const SendOutcome(status: 'failed', error: 'auth', draft: _draft);
}

void _failedSendsTests() {
  Future<GoRouter> pumpApp(WidgetTester tester) async {
    Widget shell(Widget child) =>
        AppShell(selectedDestinationId: 'x', child: child);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const ComposePage(initialAccountId: 'a1'),
      ),
      GoRoute(
        path: '/accounts/:id/mail',
        builder: (_, __) => shell(const Text('mailbox')),
      ),
      GoRoute(
        path: '/compose/recover',
        builder: (_, state) =>
            ComposePage(initialDraft: state.extra as ComposeDraft),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mailApiClientProvider.overrideWithValue(_FailApi()),
        accountsProvider.overrideWith((ref) async => const []),
        composeAccountsProvider.overrideWith((ref) async => const [
              MailAccountSummary(
                id: 'a1',
                providerId: 'p',
                emailAddress: 'me@example.test',
                incomingProtocol: 'imap',
                authMode: 'password',
                syncStatus: 'idle',
                syncError: null,
                initialSync: null,
                lastSyncedAtLabel: '',
              ),
            ]),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    return router;
  }

  testWidgets(
      'failed draft stays recoverable from banner after snackbars are cleared',
      (tester) async {
    final router = await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // Undo window (5s) + first poll (2s), then the failure surfaces.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('발송 실패 1건'), findsOneWidget);
    expect(find.byType(SnackBarAction), findsOneWidget);

    // A new send does this to the earlier failure snackbar.
    ScaffoldMessenger.of(tester.element(find.text('mailbox'))).clearSnackBars();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('발송 실패 1건'), findsOneWidget);

    await tester.tap(find.text('보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다시 작성'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/compose/recover');
    expect(find.text('Hello'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('발송 실패 1건'), findsNothing);
  });

  testWidgets('banner delete drops the failed draft', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    expect(find.text('발송 실패 1건'), findsNothing);
  });

  testWidgets(
      '30 failures stay one compact row; dialog list is bounded and rewrite works',
      (tester) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = await pumpApp(tester);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    router.go('/accounts/a1/mail');
    await tester.pumpAndSettle();
    for (var i = 0; i < 30; i++) {
      container.read(failedSendsProvider.notifier).add(FailedSend(
          id: 'f$i',
          draft: ComposeDraft(
              accountId: 'a1',
              to: 't$i@example.com',
              subject: 'S$i',
              body: 'b'),
          error: 'e'));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('발송 실패 30건'), findsOneWidget);
    expect(find.text('mailbox'), findsOneWidget);
    expect(tester.getRect(find.text('mailbox')).bottom, lessThan(500));
    expect(find.text('다시 작성'), findsNothing);

    await tester.tap(find.text('보기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byType(AlertDialog)).height,
        lessThanOrEqualTo(500));

    await tester.tap(find.text('다시 작성').first);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/compose/recover');
    expect(find.text('S0'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('발송 실패 29건'), findsOneWidget);
  });
}

class _UndoApi extends _SendApi {
  int sent = 0;
  final cancelled = <String>[];

  @override
  Future<SendReceipt> sendMail({
    required String accountId,
    required List<String> to,
    required String subject,
    required String body,
    int delaySeconds = 5,
  }) async =>
      SendReceipt('s${++sent}', const Duration(seconds: 30));

  @override
  Future<String> cancelSend(String id) async {
    cancelled.add(id);
    return 'cancelled';
  }
}

void _pendingSendsTests() {
  testWidgets(
      'two sends in the undo window: the first stays cancellable after the second snackbar',
      (tester) async {
    final api = _UndoApi();
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const ComposePage(initialAccountId: 'a1'),
      ),
      GoRoute(
        path: '/accounts/:id/mail',
        builder: (_, __) =>
            const AppShell(selectedDestinationId: 'x', child: Text('mailbox')),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mailApiClientProvider.overrideWithValue(api),
        accountsProvider.overrideWith((ref) async => const []),
        composeAccountsProvider.overrideWith((ref) async => const [
              MailAccountSummary(
                id: 'a1',
                providerId: 'p',
                emailAddress: 'me@example.test',
                incomingProtocol: 'imap',
                authMode: 'password',
                syncStatus: 'idle',
                syncError: null,
                initialSync: null,
                lastSyncedAtLabel: '',
              ),
            ]),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();

    for (final subject in ['First', 'Second']) {
      router.go('/');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), subject);
      await tester.tap(find.byIcon(Icons.send_outlined));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    }
    // Only the newest snackbar is visible; both sends are listed.
    expect(find.byType(SnackBarAction), findsOneWidget);
    expect(find.text('보내기 대기 2건'), findsOneWidget);

    await tester.tap(find.text('보기'));
    await tester.pumpAndSettle();
    await tester.tap(find
        .descendant(of: find.byType(AlertDialog), matching: find.text('보내기 취소'))
        .first);
    await tester.pumpAndSettle();
    expect(api.cancelled, ['s1']);
    expect(find.text('보내기 대기 1건'), findsWidgets);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    // The rest expires with the server deadline.
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(find.text('보내기 대기 1건'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });
}
