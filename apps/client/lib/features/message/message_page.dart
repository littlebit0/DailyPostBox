import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'linked_message_body.dart';

typedef MessageRequest = ({String messageId, String accountId});

// Messages are looked up per account: IMAP UIDs repeat across accounts.
final messageProvider =
    FutureProvider.family<MessageDetail, MessageRequest>((ref, request) {
  return ref.watch(mailApiClientProvider).fetchAccountMessage(
        accountId: request.accountId,
        messageId: request.messageId,
      );
});

/// Opens the composer addressed to the sender with a "Re:" subject.
String replyLocation({String? accountId, required MessageDetail message}) {
  final subject = message.subject;
  return Uri(
    path: accountId == null ? '/compose' : '/accounts/$accountId/compose',
    queryParameters: {
      'to': message.sender,
      'subject':
          subject.toLowerCase().startsWith('re:') ? subject : 'Re: $subject',
    },
  ).toString();
}

class MessagePage extends ConsumerWidget {
  const MessagePage({
    super.key,
    required this.messageId,
    required this.accountId,
  });

  final String messageId;
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(
      messageProvider((messageId: messageId, accountId: accountId)),
    );
    final strings = ref.watch(appStringsProvider);
    final mailboxPath = '/accounts/$accountId/mail';

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBar(
          leading: IconButton(
            tooltip: strings.back,
            onPressed: () => context.go(
              mailboxPath,
              extra: const {'disableTransition': true},
            ),
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(strings.message),
          actions: [
            IconButton(
              tooltip: strings.reply,
              onPressed: switch (message.asData?.value) {
                final item? => () => context.go(
                      replyLocation(accountId: accountId, message: item),
                    ),
                null => null,
              },
              icon: const Icon(Icons.reply),
            ),
          ],
        ),
        Expanded(
          child: message.when(
            data: (item) => ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  item.subject,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text('${strings.from}: ${item.sender}'),
                Text(item.receivedAtLabel),
                const Divider(height: 32),
                LinkedMessageBody(body: item.body, links: item.links),
              ],
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(
              child: Text(strings.messageLoadFailedTitle),
            ),
          ),
        ),
      ],
    );

    return AppShell(
      selectedDestinationId: AppShell.accountDestinationId(accountId),
      child: content,
    );
  }
}
