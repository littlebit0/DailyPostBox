import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/accounts/accounts_page.dart';
import 'package:daily_postbox/main.dart';
import 'package:daily_postbox/services/mail_api_client.dart';

const _account = MailAccountSummary(
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
const _unread = MailSummary(
  id: 'message-1',
  sender: 'sender@example.com',
  subject: '안 읽은 메일',
  snippet: '본문 미리보기',
  receivedAtLabel: '09:30',
  unread: true,
);
const _read = MailSummary(
  id: 'message-2',
  sender: 'other@example.com',
  subject: '읽은 메일',
  snippet: '본문 미리보기',
  receivedAtLabel: '어제',
  unread: false,
);

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountsProvider.overrideWith((ref) async => const [_account]),
        providersProvider.overrideWith((ref) async => const []),
        accountMessagesProvider.overrideWith(
          (ref, accountId) async => const [_unread, _read],
        ),
      ],
      child: const DailyPostBoxApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(_account.emailAddress).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('mail rows read state, sender, subject and time as one label',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpApp(tester);

    expect(
      find.bySemanticsLabel('안 읽음, sender@example.com, 안 읽은 메일, 09:30'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('읽음, other@example.com, 읽은 메일, 어제'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('사이드바'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('mailbox meets accessibility guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpApp(tester);

    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('compose page meets accessibility guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpApp(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });
}
