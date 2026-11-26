import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/core/app_router.dart';
import 'package:daily_postbox/features/accounts/accounts_page.dart';
import 'package:daily_postbox/features/message/compose_page.dart';
import 'package:daily_postbox/features/message/message_page.dart';
import 'package:daily_postbox/features/message/reply_draft.dart';
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

MessageDetail _message(String subject) => MessageDetail(
      id: '5',
      sender: 'friend@example.com',
      subject: subject,
      body: 'Hello',
      links: const [],
      receivedAtLabel: 'now',
      replyTo: const ['friend@example.com'],
    );

void main() {
  test('a reply keeps an existing Re: prefix', () {
    expect(replySubject('Re: Hi'), 'Re: Hi');
    expect(replySubject('Hi'), 'Re: Hi');
  });

  testWidgets('reply opens the composer filled in; no dead buttons remain',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const [_account]),
          providersProvider.overrideWith((ref) async => const []),
          composeAccountsProvider.overrideWith((ref) async => const [_account]),
          messageProvider.overrideWith((ref, request) async => _message('Hi')),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    container.read(appRouterProvider).go('/accounts/account-1/messages/5');
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.archive_outlined), findsNothing);
    await tester.tap(find.byIcon(Icons.reply));
    await tester.pumpAndSettle();

    expect(find.byType(ComposePage), findsOneWidget);
    expect(find.widgetWithText(TextField, 'friend@example.com'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Re: Hi'), findsOneWidget);

    container.read(appRouterProvider).go('/settings');
    await tester.pumpAndSettle();
    // Only the working conversation-view toggle; the dead push switch is gone.
    expect(find.byType(SwitchListTile), findsOneWidget);
  });
}
