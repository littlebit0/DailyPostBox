import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_menu_bar.dart';
import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'account_providers.dart';
import 'accounts_page.dart' show reconnectAccount;

class AccountMailboxPage extends ConsumerWidget {
  const AccountMailboxPage({super.key, required this.accountId});

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
        error: (error, stackTrace) =>
            Center(child: Text(strings.accountLoadFailedTitle)),
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

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
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
  final _searchController = TextEditingController();
  Future<List<MailSummary>>? _search;
  String? _category;
  final _searchFocus = FocusNode(debugLabel: 'mailbox search');
  String? _selectedId;
  final _rowKeys = <String, GlobalKey>{};
  final _mailboxFocus = FocusNode(debugLabel: 'mailbox');
  // Rows currently shown (search results or the filtered/threaded list), so
  // j/k/Enter follow exactly what the user sees.
  List<MailSummary> _shownItems = const [];
  bool _shownThreaded = false;

  static bool _busy(MailAccountSummary account) =>
      account.threadBackfilling ||
      const {'syncing', 'validating'}.contains(account.syncStatus);

  bool get _isSyncing => _busy(widget.account);

  late final _menuNotifier = ref.read(mailboxMenuCommandsProvider);
  late final _menuCommands = MailboxMenuCommands(
    compose: _compose,
    openSelected: _openSelected,
    next: () => _moveSelection(1),
    previous: () => _moveSelection(-1),
    showHelp: _showHelp,
  );

  @override
  void initState() {
    super.initState();
    _configureRefreshTimer();
    // The menu bar sits above this widget; update it after the frame so an
    // ancestor is never marked dirty during build or tree finalization.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menuNotifier.value = _menuCommands;
    });
  }

  @override
  void didUpdateWidget(covariant _MailboxContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id) {
      // Search results belong to the previous account; their UIDs are not
      // valid for the newly selected one.
      _searchController.clear();
      _search = null;
    }
    final wasSyncing = _busy(oldWidget.account);
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
        _busy(oldWidget.account) != _isSyncing) {
      _configureRefreshTimer();
    }
  }

  @override
  void dispose() {
    final notifier = _menuNotifier;
    final commands = _menuCommands;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Another mailbox may have registered meanwhile; only clear our own.
      if (notifier.value == commands) notifier.value = null;
    });
    _refreshTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _mailboxFocus.dispose();
    super.dispose();
  }

  void _runSearch(String value) {
    final query = value.trim();
    setState(() {
      _search = query.isEmpty
          ? null
          : ref
              .read(mailApiClientProvider)
              .searchAccountMessages(widget.account.id, query);
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _search = null);
  }

  // The server saves IDLE mail at any time, so the list keeps polling after
  // sync too, just less often.
  Duration get _refreshInterval =>
      _isSyncing ? const Duration(seconds: 3) : const Duration(seconds: 30);

  void _configureRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (!_refreshing) _scheduleRefresh();
  }

  void _scheduleRefresh() {
    _refreshTimer = Timer(_refreshInterval, () {
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
    if (mounted && _refreshTimer == null) _scheduleRefresh();
  }

  void _moveSelection(int delta) {
    final items = _shownItems;
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

  void _openMessage(MailSummary message, {bool threaded = false}) {
    final accountId = widget.account.id;
    context.go(
      threaded && message.threadCount > 1
          ? '/accounts/$accountId/threads/${Uri.encodeComponent(message.threadId!)}'
          : '/accounts/$accountId/messages/${Uri.encodeComponent(message.id)}',
      extra: const {'disableTransition': true},
    );
  }

  void _openSelected() {
    final selected =
        _shownItems.where((item) => item.id == _selectedId).firstOrNull;
    if (selected != null) _openMessage(selected, threaded: _shownThreaded);
  }

  void _compose() => context.go('/accounts/${widget.account.id}/compose');

  void _showHelp() {
    final strings = ref.read(appStringsProvider);
    final rows = [
      ('j', strings.shortcutNextMessage),
      ('k', strings.shortcutPreviousMessage),
      ('Enter', strings.shortcutOpenMessage),
      ('/', strings.shortcutFocusSearch),
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
    return Shortcuts(
      shortcuts: const {
        CharacterActivator('j'): _MoveSelectionIntent(1),
        CharacterActivator('k'): _MoveSelectionIntent(-1),
        SingleActivator(LogicalKeyboardKey.enter): _OpenSelectedIntent(),
        CharacterActivator('/'): _FocusSearchIntent(),
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
          _FocusSearchIntent: _GuardedCallbackAction<_FocusSearchIntent>(
            onInvoke: (_) => _searchFocus.requestFocus(),
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
  }

  Widget _messageList(List<MailSummary> items, {bool threaded = false}) {
    final strings = ref.read(appStringsProvider);
    _shownItems = items;
    _shownThreaded = threaded;
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final message = items[index];
        void open() => _openMessage(message, threaded: threaded);
        final thread = threaded && message.threadCount > 1
            ? ', ${strings.threadMessageCount(message.threadCount)}'
            : '';
        // One spoken label: state, sender, subject, time (and thread size).
        return Semantics(
          button: true,
          selected: message.id == _selectedId,
          label: strings.mailRowLabel(
                unread: message.unread,
                sender: message.sender,
                subject: message.subject,
                receivedAt: message.receivedAtLabel,
              ) +
              thread,
          onTap: open,
          excludeSemantics: true,
          child: ListTile(
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
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.flagged) ...[
                  const Icon(Icons.star, size: 18, color: Colors.amber),
                  const SizedBox(width: 6),
                ],
                Text(
                  threaded && message.threadCount > 1
                      ? '${strings.threadMessageCount(message.threadCount)}\n${message.receivedAtLabel}'
                      : message.receivedAtLabel,
                  textAlign: TextAlign.end,
                ),
              ],
            ),
            onTap: open,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final messages = ref.watch(accountMessagesProvider(account.id));
    final threaded = ref.watch(threadViewProvider);
    final strings = ref.watch(appStringsProvider);
    // _messageList refills this when rows are shown.
    _shownItems = const [];

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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            onSubmitted: _runSearch,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.search),
              hintText: strings.searchHint,
              suffixIcon: _search == null
                  ? null
                  : IconButton(
                      tooltip: strings.clearSearch,
                      onPressed: _clearSearch,
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final (value, label) in [
              (null, strings.categoryAll),
              ('person', strings.categoryPerson),
              ('notification', strings.categoryNotification),
              ('newsletter', strings.categoryNewsletter),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: ChoiceChip(
                  label: Text(label),
                  selected: _category == value,
                  onSelected: (_) => setState(() => _category = value),
                ),
              ),
          ],
        ),
        Expanded(
          child: _search != null
              ? FutureBuilder<List<MailSummary>>(
                  future: _search,
                  builder: (context, snapshot) {
                    // A new future keeps the previous snapshot's data/error
                    // while waiting, so check the state before rendering it.
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(child: Text(strings.searchFailedTitle));
                    }
                    final results = filterByCategory(snapshot.data!, _category);
                    if (results.isEmpty) {
                      return Center(child: Text(strings.noSearchResults));
                    }
                    return _messageList(results);
                  },
                )
              : messages.when(
                  data: (all) {
                    // Filter first so a thread row shows its newest mail in the category.
                    final filtered = filterByCategory(all, _category);
                    final items = threaded ? groupByThread(filtered) : filtered;
                    if (items.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isSyncing)
                              const SizedBox.square(
                                dimension: 44,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                ),
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

                    return _messageList(items, threaded: threaded);
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, stackTrace) =>
                      Center(child: Text(strings.mailLoadFailedTitle)),
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
