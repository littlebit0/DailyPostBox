import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/core/app_router.dart';
import 'package:daily_postbox/core/i18n/language_controller.dart';
import 'package:daily_postbox/features/accounts/accounts_page.dart';
import 'package:daily_postbox/features/message/compose_page.dart';
import 'package:daily_postbox/features/message/message_page.dart';
import 'package:daily_postbox/features/message/recipient_field.dart';
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

class _ForwardApi extends MailApiClient {
  _ForwardApi() : super(baseUrl: 'http://127.0.0.1:1');

  ForwardOf? forwardOf;
  String? inReplyTo;
  String subject = '';

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
  }) async {
    this.forwardOf = forwardOf;
    this.inReplyTo = inReplyTo;
    this.subject = subject;
    return const SendReceipt('s1', Duration.zero);
  }

  @override
  Future<SendOutcome> fetchSendOutcome(String id) async =>
      const SendOutcome(status: 'sent');
}

MessageDetail _forwardable(String subject) => MessageDetail(
      id: '5',
      sender: 'friend@example.com',
      subject: subject,
      body: 'Hello\nBye',
      links: const [],
      receivedAtLabel: 'now',
      messageId: '<m1@example.com>',
      to: const ['me@example.com'],
      cc: const ['boss@example.com'],
      attachments: const [
        MessageAttachment(
            part: '2',
            filename: 'a.pdf',
            contentType: 'application/pdf',
            size: 2048),
        MessageAttachment(
            part: '3', filename: 'b.txt', contentType: 'text/plain', size: 10),
      ],
    );

void main() {
  test('a forward adds Fwd: once and keeps FW:/Fw: prefixes', () {
    expect(forwardSubject('Hi'), 'Fwd: Hi');
    expect(forwardSubject('Fwd: Hi'), 'Fwd: Hi');
    expect(forwardSubject('FW: Hi'), 'FW: Hi');
    expect(forwardSubject('fw: Hi'), 'fw: Hi');
    expect(forwardSubject('Re: Hi'), 'Fwd: Re: Hi');
  });

  test('forward body has the header summary and the quoted original', () {
    final draft = ReplyDraft.forward(
        _forwardable('Hi'), const AppStrings(AppLanguage.english));
    expect(draft.to, isEmpty);
    expect(draft.inReplyTo, isNull);
    expect(
      draft.body,
      '\n\n---------- Forwarded message ----------\n'
      'From: friend@example.com\nDate: now\nTo: me@example.com\n'
      'Cc: boss@example.com\nSubject: Hi\n\n> Hello\n> Bye',
    );
    expect(draft.forwardOf?.attachments.map((a) => a.part), ['2', '3']);
    final ko = ReplyDraft.forward(
        _forwardable('Hi'), const AppStrings(AppLanguage.korean));
    expect(ko.body,
        contains('---------- 전달된 메일 ----------\n보낸 사람: friend@example.com'));
  });

  testWidgets(
      'forward opens the composer with Fwd:, the header and removable attachments',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ForwardApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailApiClientProvider.overrideWithValue(api),
          accountsProvider.overrideWith((ref) async => const [_account]),
          providersProvider.overrideWith((ref) async => const []),
          composeAccountsProvider.overrideWith((ref) async => const [_account]),
          accountMessagesProvider.overrideWith((ref, id) async => const []),
          messageProvider
              .overrideWith((ref, request) async => _forwardable('Hi')),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    container.read(appRouterProvider).go('/accounts/account-1/messages/5');
    await tester.pumpAndSettle();

    final strings = container.read(appStringsProvider);
    await tester.tap(find.byTooltip(strings.forward));
    await tester.pumpAndSettle();

    expect(find.byType(ComposePage), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Fwd: Hi'), findsOneWidget);
    expect(find.textContaining(strings.forwardedMessage), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'a.pdf (2.0 KB)'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'b.txt (10 B)'), findsOneWidget);

    await tester.tap(find.byTooltip(strings.removeAttachment('a.pdf')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'a.pdf (2.0 KB)'), findsNothing);

    await tester.enterText(
        find.descendant(
            of: find.byType(RecipientField), matching: find.byType(TextField)),
        'x@example.com, ');
    await tester.tap(find.byTooltip(strings.send));
    await tester.pumpAndSettle();

    expect(api.subject, 'Fwd: Hi');
    expect(api.inReplyTo, isNull);
    expect(api.forwardOf?.messageId, '5');
    expect(api.forwardOf?.attachments.map((a) => a.part), ['3']);
    // Let the post-send status poll finish.
    await tester.pump(const Duration(seconds: 3));
  });

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
    expect(find.widgetWithText(InputChip, 'friend@example.com'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Re: Hi'), findsOneWidget);

    container.read(appRouterProvider).go('/settings');
    await tester.pumpAndSettle();
    // Only the working conversation-view toggle; the dead push switch is gone.
    expect(find.byType(SwitchListTile), findsOneWidget);
  });

  testWidgets('a rewritten failed forward keeps its attachment chips',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
        .push('/compose/recover',
            extra: ComposeDraft(
              accountId: 'account-1',
              to: 'x@example.com',
              subject: 'Fwd: Hi',
              body: '',
              forwardOf: ForwardOf(
                  messageId: '5',
                  attachments: _forwardable('Hi').attachments.sublist(1)),
            ));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'b.txt (10 B)'), findsOneWidget);
  });

  for (final removeOriginal in [false, true]) {
    testWidgets(
        'forwarding image-only HTML mail attaches the original '
        '(removed: $removeOriginal)', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ForwardApi();
      const htmlOnly = MessageDetail(
        id: '5',
        sender: 'friend@example.com',
        subject: 'Hi',
        body: '',
        html: '<img src="cid:x">',
        links: [],
        receivedAtLabel: 'now',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mailApiClientProvider.overrideWithValue(api),
            accountsProvider.overrideWith((ref) async => const [_account]),
            providersProvider.overrideWith((ref) async => const []),
            composeAccountsProvider
                .overrideWith((ref) async => const [_account]),
            accountMessagesProvider.overrideWith((ref, id) async => const []),
            messageProvider.overrideWith((ref, request) async => htmlOnly),
          ],
          child: const DailyPostBoxApp(),
        ),
      );
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
      container.read(appRouterProvider).go('/accounts/account-1/messages/5');
      await tester.pumpAndSettle();
      final strings = container.read(appStringsProvider);
      await tester.tap(find.byTooltip(strings.forward));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(InputChip, 'original.eml'), findsOneWidget);
      expect(find.textContaining(strings.originalAttached('original.eml')),
          findsOneWidget);
      if (removeOriginal) {
        await tester
            .tap(find.byTooltip(strings.removeAttachment('original.eml')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(InputChip, 'original.eml'), findsNothing);
      }

      await tester.enterText(
          find.descendant(
              of: find.byType(RecipientField),
              matching: find.byType(TextField)),
          'x@example.com, ');
      await tester.tap(find.byTooltip(strings.send));
      await tester.pumpAndSettle();

      expect(api.forwardOf?.includeOriginal, !removeOriginal);
      await tester.pump(const Duration(seconds: 3));
    });
  }
}
