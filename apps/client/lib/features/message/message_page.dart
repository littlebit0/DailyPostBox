import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'linked_message_body.dart';

typedef MessageRequest = ({String messageId, String? accountId});

final messageProvider =
    FutureProvider.family<MessageDetail, MessageRequest>((ref, request) {
  final api = ref.watch(mailApiClientProvider);
  final accountId = request.accountId;
  if (accountId != null) {
    return api.fetchAccountMessage(
      accountId: accountId,
      messageId: request.messageId,
    );
  }
  return api.fetchMessage(request.messageId);
});

class MessagePage extends ConsumerWidget {
  const MessagePage({
    super.key,
    required this.messageId,
    this.accountId,
  });

  final String messageId;
  final String? accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(
      messageProvider((messageId: messageId, accountId: accountId)),
    );
    final strings = ref.watch(appStringsProvider);
    final mailboxPath =
        accountId == null ? '/accounts' : '/accounts/$accountId/mail';

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
              onPressed: () {},
              icon: const Icon(Icons.reply),
            ),
            IconButton(
              tooltip: strings.archive,
              onPressed: () {},
              icon: const Icon(Icons.archive_outlined),
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

    final selectedAccountId = accountId;
    if (selectedAccountId == null) {
      return Scaffold(body: content);
    }
    return AppShell(
      selectedDestinationId: AppShell.accountDestinationId(selectedAccountId),
      child: content,
    );
  }
}
