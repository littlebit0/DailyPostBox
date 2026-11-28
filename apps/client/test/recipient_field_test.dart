import 'dart:async';

import 'package:daily_postbox/features/message/compose_page.dart';
import 'package:daily_postbox/features/message/recipient_field.dart';
import 'package:daily_postbox/services/mail_api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('validates email format', () {
    expect(isValidEmailAddress('a@example.test'), isTrue);
    expect(isValidEmailAddress('a@example'), isFalse);
    expect(isValidEmailAddress('a b@example.test'), isFalse);
  });

  testWidgets('suggests, selects by keyboard, deletes and flags invalid chips',
      (tester) async {
    final addresses = <String>[];
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecipientField(
          label: 'To',
          errorText: 'bad',
          suggest: (q) async => ['alice@example.test', 'alan@example.test'],
          addresses: addresses,
          controller: controller,
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), 'al');
    await tester.pumpAndSettle();
    expect(find.text('alice@example.test'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'alan@example.test'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'broken,');
    await tester.pumpAndSettle();
    expect(find.text('bad'), findsOneWidget);
    expect(hasInvalidRecipient(addresses), isTrue);

    await tester.tap(find.descendant(
        of: find.widgetWithText(InputChip, 'broken'),
        matching: find.byType(Icon)));
    await tester.pumpAndSettle();
    expect(find.text('bad'), findsNothing);
    expect(addresses, ['alan@example.test']);
  });

  testWidgets('Enter keeps a fully typed address over a lookalike suggestion',
      (tester) async {
    final addresses = <String>[];
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecipientField(
          label: 'To',
          errorText: 'bad',
          suggest: (q) async => ['alice@company.test.evil.example'],
          addresses: addresses,
          controller: controller,
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), 'alice@company.test');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(addresses, ['alice@company.test']);
  });

  testWidgets('Enter commits the typed address while a newer lookup is pending',
      (tester) async {
    final addresses = <String>[];
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final pending = Completer<List<String>>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecipientField(
          label: 'To',
          errorText: 'bad',
          suggest: (q) => q == 'al'
              ? Future.value(['alan@example.test'])
              : pending.future,
          addresses: addresses,
          controller: controller,
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), 'al');
    await tester.pumpAndSettle();
    expect(find.text('alan@example.test'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'alice@example.test');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(addresses, ['alice@example.test']);

    pending.complete(['alan@example.test']);
    await tester.pumpAndSettle();
    expect(addresses, ['alice@example.test']);
  });

  testWidgets('scrolls the keyboard-highlighted suggestion into view',
      (tester) async {
    final suggestions = [for (var i = 0; i < 8; i++) 'user$i@example.test'];
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecipientField(
          label: 'To',
          errorText: 'bad',
          suggest: (q) async => suggestions,
          addresses: <String>[],
          controller: controller,
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), 'us');
    await tester.pumpAndSettle();
    for (var i = 0; i < 7; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }

    final list = tester.getRect(find.byType(ListView));
    final last = tester.getRect(find.widgetWithText(ListTile, suggestions[7]));
    expect(list.top <= last.top && last.bottom <= list.bottom, isTrue,
        reason: 'highlighted tile $last should be inside popup $list');
  });

  testWidgets('keeps recipients when the field scrolls out of the compose list',
      (tester) async {
    final api = _SendRecordingApi();
    await tester.binding.setSurfaceSize(const Size(800, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => const ComposePage()),
      GoRoute(
        path: '/accounts/:id/mail',
        builder: (context, state) => const Text('sent'),
      ),
    ]);
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        mailApiClientProvider.overrideWithValue(api),
        composeAccountsProvider.overrideWith((ref) async => const [_account]),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.descendant(
            of: find.byType(RecipientField), matching: find.byType(TextField)),
        'bob@example.test,');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'bob@example.test'), findsOneWidget);

    // Scroll far enough that the lazy ListView disposes the recipient field.
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.byType(RecipientField), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'bob@example.test'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle();
    expect(api.sent, [
      ['bob@example.test']
    ]);
    // Let the post-send outcome poll finish so no timer is left pending.
    await tester.pump(const Duration(seconds: 3));
  });
}

const _account = MailAccountSummary(
  id: 'acc-1',
  providerId: 'custom',
  emailAddress: 'me@example.test',
  incomingProtocol: 'imap',
  authMode: 'app-password',
  syncStatus: 'idle',
  syncError: null,
  initialSync: null,
  lastSyncedAtLabel: '',
);

class _SendRecordingApi extends MailApiClient {
  _SendRecordingApi() : super(baseUrl: 'http://127.0.0.1:1');

  final sent = <List<String>>[];

  @override
  Future<List<String>> suggestContacts(String query) async => const [];

  @override
  Future<SendReceipt> sendMail({
    required String accountId,
    required List<String> to,
    required String subject,
    required String body,
    List<String> cc = const [],
    int delaySeconds = 0,
    String? inReplyTo,
    List<String> references = const [],
  }) async {
    sent.add(to);
    return const SendReceipt('send-1', Duration.zero);
  }

  @override
  Future<SendOutcome> fetchSendOutcome(String id) async =>
      const SendOutcome(status: 'sent');
}
