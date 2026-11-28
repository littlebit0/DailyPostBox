import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/core/app_router.dart';
import 'package:daily_postbox/features/accounts/accounts_page.dart';
import 'package:daily_postbox/features/message/compose_page.dart';
import 'package:daily_postbox/features/message/recipient_field.dart';
import 'package:daily_postbox/main.dart';
import 'package:daily_postbox/services/mail_api_client.dart';

const _account = MailAccountSummary(
  id: 'account-1',
  providerId: 'naver',
  emailAddress: 'me@example.com',
  incomingProtocol: 'imap',
  authMode: 'app-password',
  syncStatus: 'idle',
  syncError: null,
  initialSync: InitialSyncOption.recommended,
  lastSyncedAtLabel: 'now',
);

class _SendingApi extends MailApiClient {
  _SendingApi() : super(baseUrl: 'http://127.0.0.1:1');

  final sent = <List<String>>[];
  Completer<SendReceipt> reply = Completer<SendReceipt>();

  @override
  Future<SendReceipt> sendMail({
    required String accountId,
    required List<String> to,
    required String subject,
    required String body,
    int delaySeconds = 5,
    List<String> cc = const [],
    String? inReplyTo,
    List<String> references = const [],
    ForwardOf? forwardOf,
  }) {
    sent.add(to);
    return reply.future;
  }

  @override
  Future<SendOutcome> fetchSendOutcome(String id) async =>
      const SendOutcome(status: 'sent');
}

Future<_SendingApi> _openComposer(WidgetTester tester) async {
  final api = _SendingApi();
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mailApiClientProvider.overrideWithValue(api),
        accountsProvider.overrideWith((ref) async => const [_account]),
        providersProvider.overrideWith((ref) async => const []),
        composeAccountsProvider.overrideWith((ref) async => const [_account]),
        accountMessagesProvider.overrideWith((ref, id) async => const []),
      ],
      child: const DailyPostBoxApp(),
    ),
  );
  await tester.pumpAndSettle();
  ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
      .read(appRouterProvider)
      .go('/accounts/account-1/compose');
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('a failed send shows the reason and keeps the draft',
      (WidgetTester tester) async {
    final api = await _openComposer(tester);
    await tester.enterText(
        find.descendant(
            of: find.byType(RecipientField), matching: find.byType(TextField)),
        'a@example.com, ');
    await tester.enterText(find.widgetWithText(TextField, '제목'), 'Hello');

    await tester.tap(find.byTooltip('보내기'));
    await tester.pump();
    // A second tap while sending does not send again.
    await tester.tap(find.byTooltip('보내기'));
    await tester.pump();
    expect(api.sent, [
      ['a@example.com'],
    ]);

    api.reply.completeError(DioException.badResponse(
      statusCode: 502,
      requestOptions: RequestOptions(path: '/mail/send'),
      response: Response(
        requestOptions: RequestOptions(path: '/mail/send'),
        statusCode: 502,
        data: {'error': 'SMTP rejected the message'},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('SMTP rejected the message'), findsOneWidget);
    expect(find.byType(ComposePage), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Hello'), findsOneWidget);

    api.reply = Completer<SendReceipt>()
      ..complete(const SendReceipt('id', Duration.zero));
    await tester.tap(find.byTooltip('보내기'));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2));
    expect(find.byType(ComposePage), findsNothing);
    // Let the post-send outcome poll finish so no timer is left pending.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('asks for a recipient instead of sending an empty list',
      (WidgetTester tester) async {
    final api = await _openComposer(tester);
    await tester.enterText(
        find.descendant(
            of: find.byType(RecipientField), matching: find.byType(TextField)),
        ' , ');
    await tester.tap(find.byTooltip('보내기'));
    await tester.pumpAndSettle();

    expect(find.text('받는 사람을 입력하세요.'), findsOneWidget);
    expect(api.sent, isEmpty);
  });
}
