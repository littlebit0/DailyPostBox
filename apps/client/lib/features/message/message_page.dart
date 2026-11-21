import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/browser_launcher.dart';
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
            if (message.valueOrNull?.canUnsubscribe ?? false)
              TextButton(
                onPressed: () => _unsubscribe(
                  context,
                  ref,
                  strings,
                  message.requireValue,
                ),
                child: Text(strings.unsubscribe),
              ),
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

Future<void> _unsubscribe(
  BuildContext context,
  WidgetRef ref,
  AppStrings strings,
  MessageDetail item,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final url = item.unsubscribeUrl;
  var ok = true;
  if (url != null) {
    ok = await openExternalBrowser(url);
  } else {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.unsubscribeConfirmTitle),
        content: Text(strings.unsubscribeConfirmBody(item.unsubscribeMailto!)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.unsubscribe),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(mailApiClientProvider)
          .unsubscribeByMail(accountId: item.accountId!, messageId: item.id);
      messenger?.showSnackBar(SnackBar(content: Text(strings.unsubscribeSent)));
      return;
    } catch (_) {
      ok = false;
    }
  }
  if (!ok) {
    messenger?.showSnackBar(SnackBar(content: Text(strings.unsubscribeFailed)));
  }
}
