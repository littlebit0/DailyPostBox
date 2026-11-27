import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/message/message_page.dart';
import 'package:daily_postbox/services/mail_api_client.dart';
import 'package:daily_postbox/services/mail_cache.dart';

void main() {
  testWidgets('account-less message route shows the offline banner', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageProvider.overrideWith(
            (ref, request) async => const MessageDetail(
              id: 'm1',
              sender: 'a@example.test',
              subject: 'cached subject',
              body: 'text',
              links: [],
              receivedAtLabel: '',
            ),
          ),
          cachedPathsProvider.overrideWith(
            (ref) => {
              MailApiClient.messagePath(messageId: 'm1'): DateTime(2026, 1, 2),
            },
          ),
        ],
        child: const MaterialApp(home: MessagePage(messageId: 'm1')),
      ),
    );
    await tester.pump();

    expect(find.text('cached subject'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });
}
