import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'account_providers.dart';
import 'accounts_page.dart' show reconnectAccount;

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

class _MoveSelectionIntent extends Intent {
  const _MoveSelectionIntent(this.delta);

  final int delta;
}

class _OpenSelectedIntent extends Intent {
  const _OpenSelectedIntent();
}

class _ComposeIntent extends Intent {
  const _ComposeIntent();
}

class _ShowHelpIntent extends Intent {
  const _ShowHelpIntent();
}

/// Single-key shortcuts must not fire while the user types in a text field.
bool _typingInTextField() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>() !=
    null;

class _GuardedCallbackAction<T extends Intent> extends CallbackAction<T> {
  _GuardedCallbackAction({required super.onInvoke, this.requiredFocus});

  /// When set, the action runs only while this node itself has primary focus,
  /// so focused buttons and rows keep their default activation.
  final FocusNode? requiredFocus;

  @override
  bool isEnabled(T intent) =>
      !_typingInTextField() &&
      (requiredFocus == null || requiredFocus!.hasPrimaryFocus);
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
  String? _selectedId;
  final _rowKeys = <String, GlobalKey>{};
  final _mailboxFocus = FocusNode(debugLabel: 'mailbox');

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
    _mailboxFocus.dispose();
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

  List<MailSummary> get _items =>
      ref.read(accountMessagesProvider(widget.account.id)).asData?.value ??
      const [];

  void _moveSelection(int delta) {
    final items = _items;
    if (items.isEmpty) return;
    final current = items.indexWhere((item) => item.id == _selectedId);
    final next = current == -1
        ? (delta > 0 ? 0 : items.length - 1)
        : (current + delta).clamp(0, items.length - 1);
    final id = items[next].id;
    setState(() => _selectedId = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowContext = _rowKeys[id]?.currentContext;
      if (rowContext != null) Scrollable.ensureVisible(rowContext);
    });
  }

  void _openMessage(String messageId) => context.go(
    '/accounts/${widget.account.id}/messages/${Uri.encodeComponent(messageId)}',
    extra: const {'disableTransition': true},
  );

  void _openSelected() {
    if (_items.any((item) => item.id == _selectedId)) {
      _openMessage(_selectedId!);
    }
  }

  void _compose() => context.go('/accounts/${widget.account.id}/compose');

  void _showHelp() {
    final strings = ref.read(appStringsProvider);
    final rows = [
      ('j', strings.shortcutNextMessage),
      ('k', strings.shortcutPreviousMessage),
      ('Enter', strings.shortcutOpenMessage),
      ('c', strings.compose),
      ('?', strings.shortcutHelp),
    ];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.shortcutHelp),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, label) in rows)
              ListTile(
                dense: true,
                leading: Text(
                  key,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                title: Text(label),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.close),
          ),
        ],
      ),
    );
  }

  Widget _withShortcuts(Widget child) {
    final strings = ref.read(appStringsProvider);
    final body = Shortcuts(
      shortcuts: const {
        CharacterActivator('j'): _MoveSelectionIntent(1),
        CharacterActivator('k'): _MoveSelectionIntent(-1),
        SingleActivator(LogicalKeyboardKey.enter): _OpenSelectedIntent(),
        CharacterActivator('c'): _ComposeIntent(),
        CharacterActivator('?'): _ShowHelpIntent(),
      },
      child: Actions(
        actions: {
          _MoveSelectionIntent: _GuardedCallbackAction<_MoveSelectionIntent>(
            onInvoke: (intent) => _moveSelection(intent.delta),
          ),
          _OpenSelectedIntent: _GuardedCallbackAction<_OpenSelectedIntent>(
            onInvoke: (_) => _openSelected(),
            requiredFocus: _mailboxFocus,
          ),
          _ComposeIntent: _GuardedCallbackAction<_ComposeIntent>(
            onInvoke: (_) => _compose(),
          ),
          _ShowHelpIntent: _GuardedCallbackAction<_ShowHelpIntent>(
            onInvoke: (_) => _showHelp(),
          ),
        },
        child: Focus(focusNode: _mailboxFocus, autofocus: true, child: child),
      ),
    );
    if (defaultTargetPlatform != TargetPlatform.macOS) return body;
    return PlatformMenuBar(
      menus: [
        const PlatformMenu(
          label: 'DailyPostBox',
          menus: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.servicesSubmenu,
            ),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hideOtherApplications,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.showAllApplications,
            ),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ],
        ),
        PlatformMenu(
          label: strings.mailMenu,
          menus: [
            PlatformMenuItem(
              label: strings.compose,
              // shortcut: 단일 키 네이티브 가속키는 입력창에서도 발동하므로 쓰지 않음.
              onSelected: _compose,
            ),
            PlatformMenuItem(
              label: strings.shortcutOpenMessage,
              onSelected: _openSelected,
            ),
            PlatformMenuItem(
              label: strings.shortcutNextMessage,
              onSelected: () => _moveSelection(1),
            ),
            PlatformMenuItem(
              label: strings.shortcutPreviousMessage,
              onSelected: () => _moveSelection(-1),
            ),
            PlatformMenuItem(
              label: strings.shortcutHelp,
              onSelected: _showHelp,
            ),
          ],
        ),
        PlatformMenu(
          label: strings.editMenu,
          menus: const [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.startSpeaking,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.stopSpeaking,
            ),
          ],
        ),
        PlatformMenu(
          label: strings.windowMenu,
          menus: const [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.toggleFullScreen,
            ),
          ],
        ),
      ],
      child: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final messages = ref.watch(accountMessagesProvider(account.id));
    final strings = ref.watch(appStringsProvider);

    return _withShortcuts(
      Column(
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
        if (account.syncStatus == 'error')
          MaterialBanner(
            leading: Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            content: Text(
              strings.syncFailure(account.syncErrorCode, account.syncError),
            ),
            actions: [
              if (account.syncErrorCode == 'authentication')
                TextButton(
                  onPressed: () => reconnectAccount(context, ref, account),
                  child: Text(strings.reconnectAccount),
                ),
              TextButton(
                onPressed: () => context.go('/accounts'),
                child: Text(strings.accountManagement),
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
                    key: _rowKeys.putIfAbsent(message.id, GlobalKey.new),
                    selected: message.id == _selectedId,
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
                    onTap: () => _openMessage(message.id),
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
    ),
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
