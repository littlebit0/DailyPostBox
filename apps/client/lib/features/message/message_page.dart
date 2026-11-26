import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'attachment_list.dart';
import 'linked_message_body.dart';
import 'reply_draft.dart';

typedef MessageRequest = ({String messageId, String accountId});

// Messages are looked up per account: IMAP UIDs repeat across accounts.
final messageProvider =
    FutureProvider.family<MessageDetail, MessageRequest>((ref, request) {
  return ref.watch(mailApiClientProvider).fetchAccountMessage(
        accountId: request.accountId,
        messageId: request.messageId,
      );
});

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
            if (message.value case final item?) ...[
              IconButton(
                tooltip: strings.reply,
                onPressed: () => _reply(context, item, strings, all: false),
                icon: const Icon(Icons.reply),
              ),
              IconButton(
                tooltip: strings.replyAll,
                onPressed: () => _reply(context, item, strings, all: true),
                icon: const Icon(Icons.reply_all),
              ),
            ],
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
                if (item.attachments.isNotEmpty)
                  AttachmentList(
                    accountId: accountId,
                    messageId: messageId,
                    attachments: item.attachments,
                  ),
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

  void _reply(
    BuildContext context,
    MessageDetail item,
    AppStrings strings, {
    required bool all,
  }) {
    context.go(
      '/accounts/${item.accountId ?? accountId}/compose',
      extra: ReplyDraft.from(item, strings, all: all),
    );
  }
}
