import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/message/compose_page.dart';
import 'package:daily_postbox/services/mail_api_client.dart';

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

void main() {
  const receipt = SendReceipt('id', Duration.zero);
  const tick = Duration(milliseconds: 1);

  test('polls past sending and returns the failed outcome with its draft', () async {
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

  testWidgets('composer reopens prefilled with the failed draft', (tester) async {
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

  test('keeps polling past 10 tries while still sending, until failure', () async {
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
            interval: tick, maxInterval: tick, maxWait: const Duration(milliseconds: 20)),
        isNull);
  });

  testWidgets('recovery draft replaces an already-open composer via new key', (tester) async {
    Widget app(Widget page) => ProviderScope(
          overrides: [composeAccountsProvider.overrideWith((ref) async => const [])],
          child: MaterialApp(home: page),
        );
    await tester.pumpWidget(app(const ComposePage()));
    await tester.pump();
    expect(find.text('Hello'), findsNothing);
    await tester.pumpWidget(app(ComposePage(key: ObjectKey(_draft), initialDraft: _draft)));
    await tester.pump();
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('Body text'), findsOneWidget);
  });
}
