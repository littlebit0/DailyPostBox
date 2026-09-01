import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'account_providers.dart';

class AccountMailboxPage extends ConsumerWidget {
  const AccountMailboxPage({
    super.key,
    required this.accountId,
  });

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final strings = ref.watch(appStringsProvider);

    return AppShell(
      selectedDestinationId: AppShell.accountDestinationId(accountId),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/accounts/$accountId/compose'),
        icon: const Icon(Icons.edit_outlined),
        label: Text(strings.compose),
      ),
      child: accounts.when(
        data: (items) {
          final account =
              items.where((item) => item.id == accountId).firstOrNull;
          if (account == null) {
            return _MissingAccount(onBack: () => context.go('/accounts'));
          }
          return _MailboxContent(account: account);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Text(strings.accountLoadFailedTitle),
        ),
      ),
    );
  }
}

class _MailboxContent extends ConsumerWidget {
  const _MailboxContent({required this.account});

  final MailAccountSummary account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(accountMessagesProvider(account.id));
    final strings = ref.watch(appStringsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBar(
          title: Text(
            account.emailAddress,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: strings.refresh,
              onPressed: () =>
                  ref.invalidate(accountMessagesProvider(account.id)),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        Expanded(
          child: messages.when(
            data: (items) {
              if (items.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.inbox_outlined,
                        size: 56,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        strings.noMessagesForAccount,
                        style: Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                );
              }

              return ListView.separated(
                itemCount: items.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final message = items[index];
                  return ListTile(
                    minLeadingWidth: 28,
                    leading: Icon(
                      message.unread
                          ? Icons.mark_email_unread_outlined
                          : Icons.mail_outline,
                    ),
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
                      '/accounts/${account.id}/messages/${Uri.encodeComponent(message.id)}',
                      extra: const {'disableTransition': true},
                    ),
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(
              child: Text(strings.mailLoadFailedTitle),
            ),
          ),
        ),
      ],
    );
  }
}

class _MissingAccount extends ConsumerWidget {
  const _MissingAccount({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mail_outline, size: 52),
          const SizedBox(height: 14),
          Text(strings.noAccountSelected),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.manage_accounts_outlined),
            label: Text(strings.accountManagement),
          ),
        ],
      ),
    );
  }
}
