import 'dart:async';

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
      // Keep the mailbox (and its sync polling) mounted when a background
      // refresh fails, so the next poll can recover once the API is back.
      child: accounts.when(
        skipError: true,
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

class _MailboxContent extends ConsumerStatefulWidget {
  const _MailboxContent({required this.account});

  final MailAccountSummary account;

  @override
  ConsumerState<_MailboxContent> createState() => _MailboxContentState();
}

class _MailboxContentState extends ConsumerState<_MailboxContent> {
  Timer? _refreshTimer;
  bool _refreshing = false;

  bool get _isSyncing =>
      const {'syncing', 'validating'}.contains(widget.account.syncStatus);

  @override
  void initState() {
    super.initState();
    _configureRefreshTimer();
  }

  @override
  void didUpdateWidget(covariant _MailboxContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasSyncing =
        const {'syncing', 'validating'}.contains(oldWidget.account.syncStatus);
    if (oldWidget.account.id == widget.account.id &&
        wasSyncing &&
        !_isSyncing) {
      // The last poll may have read messages before the final batch was
      // saved, so fetch the list once more after sync finishes.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.invalidate(accountMessagesProvider(widget.account.id));
      });
    }
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.account.syncStatus != widget.account.syncStatus) {
      _configureRefreshTimer();
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _configureRefreshTimer() {
    if (_isSyncing) {
      if (_refreshTimer == null && !_refreshing) _scheduleRefresh();
      return;
    }

    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _scheduleRefresh() {
    _refreshTimer = Timer(const Duration(seconds: 3), () {
      _refreshTimer = null;
      unawaited(_refresh());
    });
  }

  // Polls only after both requests finish, so a slow response is never
  // discarded by a newer invalidation.
  Future<void> _refresh() async {
    if (!mounted || _refreshing) return;
    _refreshing = true;
    try {
      await Future.wait([
        ref.refresh(accountsProvider.future),
        ref.refresh(accountMessagesProvider(widget.account.id).future),
      ]);
    } catch (_) {
      // The providers expose the error; the next poll retries.
    } finally {
      _refreshing = false;
    }
    if (mounted && _isSyncing && _refreshTimer == null) _scheduleRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
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
            if (_isSyncing)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Tooltip(
                  message: strings.statusSyncing,
                  child: const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            IconButton(
              tooltip: strings.refresh,
              onPressed: _refresh,
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
                      if (_isSyncing)
                        const SizedBox.square(
                          dimension: 44,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                      else
                        Icon(
                          Icons.inbox_outlined,
                          size: 56,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      const SizedBox(height: 16),
                      Text(
                        _isSyncing
                            ? strings.loadingAccountMail
                            : strings.noMessagesForAccount,
                        style: Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      if (_isSyncing) ...[
                        const SizedBox(height: 8),
                        Text(
                          strings.loadingAccountMailDescription,
                          textAlign: TextAlign.center,
                        ),
                      ],
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
