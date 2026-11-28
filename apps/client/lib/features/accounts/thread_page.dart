import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'account_providers.dart';

class ThreadPage extends ConsumerWidget {
  const ThreadPage({
    super.key,
    required this.accountId,
    required this.threadId,
  });

  final String accountId;
  final String threadId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final messages = ref.watch(
      threadMessagesProvider((accountId: accountId, threadId: threadId)),
    );

    return AppShell(
      selectedDestinationId: AppShell.accountDestinationId(accountId),
      cachePaths: [MailApiClient.threadPath(accountId, threadId)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBar(
            leading: BackButton(
              onPressed: () => context.go('/accounts/$accountId/mail'),
            ),
            title: Text(strings.thread),
          ),
          Expanded(
            child: messages.when(
              data: (items) => ListView.separated(
                itemCount: items.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final message = items[index];
                  return ListTile(
                    title: Text(
                      message.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${message.sender}\n${message.snippet}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(message.receivedAtLabel),
                    onTap: () => context.go(
                      '/accounts/$accountId/messages/${Uri.encodeComponent(message.id)}',
                      extra: const {'disableTransition': true},
                    ),
                  );
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) =>
                  Center(child: Text(strings.mailLoadFailedTitle)),
            ),
          ),
        ],
      ),
    );
  }
}
