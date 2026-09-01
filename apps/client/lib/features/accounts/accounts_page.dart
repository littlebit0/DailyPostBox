import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/browser_launcher.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'account_providers.dart';

export 'account_providers.dart' show accountsProvider, accountMessagesProvider;

const _naverAppPasswordGuideUrl =
    'https://help.naver.com/service/30029/bookmark/24347?lang=ko&osType=COMMONOS';
const _naverImapGuideUrl =
    'https://help.naver.com/service/30029/contents/21344?osType=COMMONOS';

final providersProvider = FutureProvider<List<MailProviderSummary>>((ref) {
  return ref.watch(mailApiClientProvider).fetchProviders();
});

class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final providers = ref.watch(providersProvider);
    final strings = ref.watch(appStringsProvider);
    final providerItems = providers.asData?.value;

    return AppShell(
      selectedDestinationId: AppShell.managementDestinationId,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBar(
            title: Text(strings.accountManagement),
            actions: [
              IconButton(
                tooltip: strings.refresh,
                onPressed: () {
                  ref.invalidate(accountsProvider);
                  ref.invalidate(providersProvider);
                },
                icon: const Icon(Icons.refresh),
              ),
              FilledButton.icon(
                onPressed: providerItems == null || providerItems.isEmpty
                    ? null
                    : () => _showAddAccountDialog(context, providerItems),
                icon: const Icon(Icons.add),
                label: Text(strings.addAccountButton),
              ),
              const SizedBox(width: 16),
            ],
          ),
          Expanded(
            child: providers.when(
              data: (providerItems) => accounts.when(
                data: (accountItems) => _AccountsContent(
                  providers: providerItems,
                  accounts: accountItems,
                  onAddAccount: () =>
                      _showAddAccountDialog(context, providerItems),
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) => _AccountsLoadFailure(
                  error: error,
                  onRetry: () {
                    ref.invalidate(accountsProvider);
                    ref.invalidate(providersProvider);
                  },
                ),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) => _AccountsLoadFailure(
                error: error,
                onRetry: () {
                  ref.invalidate(accountsProvider);
                  ref.invalidate(providersProvider);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountsLoadFailure extends ConsumerWidget {
  const _AccountsLoadFailure({
    required this.error,
    required this.onRetry,
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final connectionError = isMailApiConnectionError(error);
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 56,
                color: scheme.error,
              ),
              const SizedBox(height: 18),
              Text(
                connectionError
                    ? strings.serverUnavailableTitle
                    : strings.accountLoadFailedTitle,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                connectionError
                    ? strings.serverUnavailableDescription
                    : friendlyError(error, strings),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(strings.tryAgain),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountsContent extends ConsumerStatefulWidget {
  const _AccountsContent({
    required this.providers,
    required this.accounts,
    required this.onAddAccount,
  });

  final List<MailProviderSummary> providers;
  final List<MailAccountSummary> accounts;
  final VoidCallback onAddAccount;

  @override
  ConsumerState<_AccountsContent> createState() => _AccountsContentState();
}

class _AccountsContentState extends ConsumerState<_AccountsContent> {
  String? _selectedAccountId;

  @override
  Widget build(BuildContext context) {
    if (widget.accounts.isEmpty) {
      return _EmptyAccountsState(onAddAccount: widget.onAddAccount);
    }

    final selectedAccount = widget.accounts.firstWhere(
      (account) => account.id == _selectedAccountId,
      orElse: () => widget.accounts.first,
    );
    _selectedAccountId = selectedAccount.id;

    final accountList = _AccountListPane(
      accounts: widget.accounts,
      selectedAccountId: selectedAccount.id,
      onAddAccount: widget.onAddAccount,
      onSelected: (accountId) {
        setState(() => _selectedAccountId = accountId);
      },
    );
    final accountDetail = _AccountDetail(
      account: selectedAccount,
      providerName: _providerName(widget.providers, selectedAccount.providerId),
      onDeleted: () {
        setState(() => _selectedAccountId = null);
      },
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 680) {
          return Column(
            children: [
              Flexible(flex: 5, child: accountList),
              const Divider(height: 1),
              Expanded(flex: 6, child: accountDetail),
            ],
          );
        }

        return Row(
          children: [
            SizedBox(width: 330, child: accountList),
            const VerticalDivider(width: 1),
            Expanded(child: accountDetail),
          ],
        );
      },
    );
  }
}

class _AccountListPane extends ConsumerWidget {
  const _AccountListPane({
    required this.accounts,
    required this.selectedAccountId,
    required this.onAddAccount,
    required this.onSelected,
  });

  final List<MailAccountSummary> accounts;
  final String selectedAccountId;
  final VoidCallback onAddAccount;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                strings.accountList,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton.filledTonal(
              tooltip: strings.addAccountButton,
              onPressed: onAddAccount,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final account in accounts)
          _AccountTile(
            account: account,
            selected: account.id == selectedAccountId,
            onTap: () => onSelected(account.id),
          ),
      ],
    );
  }
}

class _EmptyAccountsState extends ConsumerWidget {
  const _EmptyAccountsState({required this.onAddAccount});

  final VoidCallback onAddAccount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.alternate_email,
              size: 64,
              color: Theme.of(context).colorScheme.secondary,
            ),
            const SizedBox(height: 18),
            Text(
              strings.noAccountsYet,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              strings.addRealtimeAccountHint,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAddAccount,
              icon: const Icon(Icons.add),
              label: Text(strings.addFirstAccount),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountTile extends ConsumerWidget {
  const _AccountTile({
    required this.account,
    required this.selected,
    required this.onTap,
  });

  final MailAccountSummary account;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      elevation: selected ? 1 : 0,
      color: selected ? scheme.secondaryContainer : null,
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: const Icon(Icons.mail_outline),
        title: Text(
          account.emailAddress,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
            '${account.providerId} · ${account.incomingProtocol.toUpperCase()}'),
        trailing: _SyncStatusChip(status: account.syncStatus),
        onTap: onTap,
      ),
    );
  }
}

class _AccountDetail extends ConsumerWidget {
  const _AccountDetail({
    required this.account,
    required this.providerName,
    required this.onDeleted,
  });

  final MailAccountSummary account;
  final String providerName;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.emailAddress,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(label: Text(providerName)),
                      Chip(
                          label: Text(
                              '${strings.protocol}: ${account.incomingProtocol.toUpperCase()}')),
                      Chip(
                          label:
                              Text('${strings.authMode}: ${account.authMode}')),
                      _SyncStatusChip(status: account.syncStatus),
                    ],
                  ),
                ],
              ),
            ),
            IconButton.filledTonal(
              tooltip: strings.accountMessages,
              onPressed: () => context.go(
                '/accounts/${account.id}/mail',
                extra: const {'verticalDirection': 1},
              ),
              icon: const Icon(Icons.inbox_outlined),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: strings.validateConnection,
              onPressed: () => _validateStoredAccount(context, ref, account.id),
              icon: const Icon(Icons.verified_outlined),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: strings.syncNow,
              onPressed: () => _syncAccount(ref, account.id),
              icon: const Icon(Icons.sync),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              tooltip: strings.more,
              onSelected: (value) {
                if (value == 'delete') {
                  _confirmDelete(context, ref, account.id, onDeleted);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'server',
                  enabled: false,
                  child:
                      Text('${strings.serverSettings} · ${strings.comingSoon}'),
                ),
                PopupMenuItem(
                  value: 'range',
                  enabled: false,
                  child: Text(
                    '${strings.syncRange} · ${_syncLabel(account.initialSync, strings)}',
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(strings.deleteAccount),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        _InfoRow(
          label: strings.lastSynced,
          value: account.lastSyncedAtLabel.isEmpty
              ? strings.neverSynced
              : account.lastSyncedAtLabel,
        ),
        if (account.syncError != null) ...[
          const SizedBox(height: 12),
          Text(
            account.syncError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Expanded(child: Text(value)),
      ],
    );
  }
}

class _SyncStatusChip extends ConsumerWidget {
  const _SyncStatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final scheme = Theme.of(context).colorScheme;

    final label = switch (status) {
      'validating' => strings.statusValidating,
      'syncing' => strings.statusSyncing,
      'error' => strings.statusError,
      _ => strings.statusIdle,
    };
    final color = switch (status) {
      'syncing' || 'validating' => scheme.primaryContainer,
      'error' => scheme.errorContainer,
      _ => scheme.surfaceContainerHighest,
    };

    return Chip(
      label: Text(label),
      backgroundColor: color,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ProviderChooserDialog extends ConsumerWidget {
  const _ProviderChooserDialog({required this.providers});

  final List<MailProviderSummary> providers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return AlertDialog(
      title: Text(strings.chooseMailService),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(strings.chooseMailServiceDescription),
            const SizedBox(height: 16),
            for (final provider in providers)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: Icon(
                      provider.supportsOAuth
                          ? Icons.open_in_browser_outlined
                          : Icons.mail_outline,
                    ),
                    title: Text(provider.displayName),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).pop(provider),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
      ],
    );
  }
}

class _BrowserLoginDialog extends ConsumerStatefulWidget {
  const _BrowserLoginDialog({
    required this.provider,
    required this.onAuthenticated,
  });

  final MailProviderSummary provider;
  final Future<void> Function(String state, String emailAddress)
      onAuthenticated;

  @override
  ConsumerState<_BrowserLoginDialog> createState() =>
      _BrowserLoginDialogState();
}

class _BrowserLoginDialogState extends ConsumerState<_BrowserLoginDialog> {
  static const _maxPollAttempts = 300;

  bool _busy = true;
  String? _error;
  String? _loginUrl;
  String? _sessionState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final strings = ref.read(appStringsProvider);
    try {
      final api = ref.read(mailApiClientProvider);
      final login = await api.startOAuthLogin(providerId: widget.provider.id);
      final opened = await openExternalBrowser(login.authorizationUrl);
      if (!mounted) return;
      setState(() {
        _sessionState = login.state;
        _busy = true;
        _loginUrl = opened ? null : login.authorizationUrl;
        _error = opened ? null : strings.browserCouldNotOpen;
      });

      await _pollSession(login.state);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _pollSession(String state) async {
    final api = ref.read(mailApiClientProvider);
    final strings = ref.read(appStringsProvider);

    for (var attempt = 0; attempt < _maxPollAttempts && mounted; attempt++) {
      final session = await api.fetchOAuthSession(state);
      if (session.status == 'authenticated' && session.emailAddress != null) {
        if (!mounted) return;
        Navigator.of(context).pop();
        await widget.onAuthenticated(state, session.emailAddress!);
        return;
      }
      if (session.status == 'error') {
        throw Exception(session.error ?? strings.connectionFailed);
      }

      await Future<void>.delayed(const Duration(seconds: 2));
    }

    throw Exception(strings.waitingBrowserLogin);
  }

  Future<void> _retryPolling() async {
    final state = _sessionState;
    if (state == null || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await _pollSession(state);
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    final strings = ref.read(appStringsProvider);
    setState(() {
      _busy = false;
      _error = '${strings.connectionFailed}: ${friendlyError(error, strings)}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    return AlertDialog(
      title: Text('${widget.provider.displayName} ${strings.browserLogin}'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(strings.browserLoginDescription),
            const SizedBox(height: 18),
            if (_busy)
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(strings.waitingBrowserLogin)),
                ],
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_loginUrl != null) ...[
              const SizedBox(height: 8),
              SelectableText(_loginUrl!),
            ],
          ],
        ),
      ),
      actions: [
        if (!_busy && _sessionState != null)
          TextButton.icon(
            onPressed: _retryPolling,
            icon: const Icon(Icons.refresh),
            label: Text(strings.checkBrowserLogin),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
      ],
    );
  }
}

class _OAuthSetupDialog extends ConsumerStatefulWidget {
  const _OAuthSetupDialog({
    required this.provider,
    required this.state,
    required this.emailAddress,
  });

  final MailProviderSummary provider;
  final String state;
  final String emailAddress;

  @override
  ConsumerState<_OAuthSetupDialog> createState() => _OAuthSetupDialogState();
}

class _OAuthSetupDialogState extends ConsumerState<_OAuthSetupDialog> {
  String _protocol = 'imap';
  InitialSyncOption _initialSync = InitialSyncOption.recommended;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _protocol = widget.provider.defaultProtocol;
  }

  Future<void> _complete() async {
    final strings = ref.read(appStringsProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(mailApiClientProvider).completeOAuthLogin(
            state: widget.state,
            incomingProtocol: _protocol,
            initialSync: _initialSync,
          );
      ref.invalidate(accountsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error =
            '${strings.connectionFailed}: ${friendlyError(error, strings)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    return AlertDialog(
      title: Text(strings.finishSetup),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${strings.connectedAs}: ${widget.emailAddress}'),
              const SizedBox(height: 6),
              Text(strings.finishSetupDescription),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'imap', label: Text('IMAP')),
                  ButtonSegment(value: 'pop3', label: Text('POP3')),
                ],
                selected: {_protocol},
                onSelectionChanged: _busy
                    ? null
                    : (value) => setState(() => _protocol = value.first),
              ),
              const SizedBox(height: 20),
              Text(strings.importPreviousMail,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final tileWidth = (constraints.maxWidth - 8) / 2;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in _syncOptions(strings))
                        SizedBox(
                          width: tileWidth,
                          child: _SyncOptionTile(
                            option: option,
                            selected: option.value == _initialSync,
                            enabled: !_busy,
                            onTap: () =>
                                setState(() => _initialSync = option.value),
                          ),
                        ),
                    ],
                  );
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _complete,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sync),
          label: Text(strings.startConnection),
        ),
      ],
    );
  }
}

class _NaverConnectionGuide extends StatelessWidget {
  const _NaverConnectionGuide({
    required this.strings,
    required this.enabled,
    required this.onOpenAppPasswordGuide,
    required this.onOpenImapGuide,
  });

  final AppStrings strings;
  final bool enabled;
  final VoidCallback onOpenAppPasswordGuide;
  final VoidCallback onOpenImapGuide;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.verified_user_outlined),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                strings.naverSetupTitle,
                style: textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(strings.naverSetupDescription),
        const SizedBox(height: 12),
        _NaverSetupStep(
          icon: Icons.security_outlined,
          label: strings.naverTwoFactorStep,
        ),
        _NaverSetupStep(
          icon: Icons.key_outlined,
          label: strings.naverAppPasswordStep,
        ),
        _NaverSetupStep(
          icon: Icons.sync_alt_outlined,
          label: strings.naverImapStep,
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: enabled ? onOpenAppPasswordGuide : null,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(strings.naverAppPasswordGuide),
            ),
            OutlinedButton.icon(
              onPressed: enabled ? onOpenImapGuide : null,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(strings.naverImapGuide),
            ),
          ],
        ),
      ],
    );
  }
}

class _NaverSetupStep extends StatelessWidget {
  const _NaverSetupStep({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _AddAccountDialog extends ConsumerStatefulWidget {
  const _AddAccountDialog({required this.provider});

  final MailProviderSummary provider;

  @override
  ConsumerState<_AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends ConsumerState<_AddAccountDialog> {
  final _emailController = TextEditingController();
  final _secretController = TextEditingController();
  late String _providerId;
  late String _authMode;
  late String _protocol;
  InitialSyncOption _initialSync = InitialSyncOption.recommended;
  bool _busy = false;
  String? _status;
  String? _error;

  bool get _isNaver => _providerId == 'naver';

  @override
  void initState() {
    super.initState();
    final provider = widget.provider;
    _providerId = provider.id;
    _authMode = _preferredAuthMode(provider);
    _protocol = provider.defaultProtocol;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final selectedProvider = widget.provider;

    return AlertDialog(
      title: Text(strings.addAccount),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                selectedProvider.displayName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              if (_isNaver) ...[
                _NaverConnectionGuide(
                  strings: strings,
                  enabled: !_busy,
                  onOpenAppPasswordGuide: () =>
                      _openNaverGuide(_naverAppPasswordGuideUrl),
                  onOpenImapGuide: () => _openNaverGuide(_naverImapGuideUrl),
                ),
                const SizedBox(height: 16),
              ],
              if (selectedProvider.authModes.length > 1) ...[
                Text(
                  strings.authMode,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [
                    for (final mode in selectedProvider.authModes)
                      ButtonSegment(
                        value: mode,
                        label: Text(strings.authModeLabel(mode)),
                      ),
                  ],
                  selected: {_authMode},
                  onSelectionChanged: _busy
                      ? null
                      : (value) => setState(() => _authMode = value.first),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                strings.protocol,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'imap', label: Text('IMAP')),
                  ButtonSegment(value: 'pop3', label: Text('POP3')),
                ],
                selected: {_protocol},
                onSelectionChanged: _busy
                    ? null
                    : (value) => setState(() => _protocol = value.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _emailController,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(labelText: strings.emailAddress),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _secretController,
                enabled: !_busy,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: _isNaver
                      ? strings.applicationPassword
                      : strings.secretLabel,
                  helperText: _isNaver ? strings.naverAppPasswordHelper : null,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                strings.importPreviousMail,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final tileWidth = (constraints.maxWidth - 8) / 2;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in _syncOptions(strings))
                        SizedBox(
                          width: tileWidth,
                          child: _SyncOptionTile(
                            option: option,
                            selected: option.value == _initialSync,
                            enabled: !_busy,
                            onTap: () =>
                                setState(() => _initialSync = option.value),
                          ),
                        ),
                    ],
                  );
                },
              ),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_status!)),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _addAccount,
          icon: const Icon(Icons.add),
          label: Text(strings.addAccountButton),
        ),
      ],
    );
  }

  Future<void> _addAccount() async {
    final strings = ref.read(appStringsProvider);
    final email = _emailController.text.trim();
    final secret = _secretController.text;

    if (email.isEmpty || secret.isEmpty) {
      setState(() {
        _error = _isNaver
            ? strings.naverCredentialsRequired
            : strings.emailAndSecretRequired;
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _status = strings.checkingCredentials;
    });

    try {
      final api = ref.read(mailApiClientProvider);
      await api.validateAccount(
        providerId: _providerId,
        emailAddress: email,
        authMode: _authMode,
        incomingProtocol: _protocol,
        secret: secret,
        initialSync: _initialSync,
      );

      setState(() => _status = strings.checkingSync);

      await api.addAccount(
        providerId: _providerId,
        emailAddress: email,
        authMode: _authMode,
        incomingProtocol: _protocol,
        secret: secret,
        initialSync: _initialSync,
      );

      ref.invalidate(accountsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      setState(() {
        _busy = false;
        _status = null;
        _error =
            '${strings.connectionFailed}: ${friendlyError(error, strings)}';
      });
    }
  }

  Future<void> _openNaverGuide(String url) async {
    final opened = await openExternalBrowser(url);
    if (!mounted || opened) return;
    setState(
        () => _error = ref.read(appStringsProvider).naverGuideCouldNotOpen);
  }
}

class _SyncChoice {
  const _SyncChoice(this.label, this.value, [this.warning]);

  final String label;
  final InitialSyncOption value;
  final String? warning;
}

class _SyncOptionTile extends StatelessWidget {
  const _SyncOptionTile({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final _SyncChoice option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      color: selected ? scheme.secondaryContainer : null,
      child: ListTile(
        dense: true,
        minVerticalPadding: 8,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        enabled: enabled,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? scheme.primary : null,
        ),
        title: Text(option.label),
        subtitle: option.warning == null ? null : Text(option.warning!),
        onTap: enabled ? onTap : null,
      ),
    );
  }
}

List<_SyncChoice> _syncOptions(AppStrings strings) {
  return [
    _SyncChoice(strings.import100, InitialSyncOption.recommended),
    _SyncChoice(
      strings.import500,
      const InitialSyncOption(includePreviousMessages: true, limit: 500),
    ),
    _SyncChoice(
      strings.import1000,
      const InitialSyncOption(includePreviousMessages: true, limit: 1000),
    ),
    _SyncChoice(
      strings.importAll,
      const InitialSyncOption(includePreviousMessages: true, limit: 'all'),
      strings.importAllWarning,
    ),
    _SyncChoice(
      strings.importNone,
      const InitialSyncOption(includePreviousMessages: false, limit: 100),
    ),
  ];
}

Future<void> _showAddAccountDialog(
  BuildContext context,
  List<MailProviderSummary> providers,
) async {
  if (providers.isEmpty) return;

  final provider = await showDialog<MailProviderSummary>(
    context: context,
    builder: (context) => _ProviderChooserDialog(providers: providers),
  );
  if (!context.mounted || provider == null) return;

  if (provider.supportsOAuth && _preferredAuthMode(provider) == 'oauth2') {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _BrowserLoginDialog(
        provider: provider,
        onAuthenticated: (state, emailAddress) async {
          if (!context.mounted) return;
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (setupContext) => _OAuthSetupDialog(
              provider: provider,
              state: state,
              emailAddress: emailAddress,
            ),
          );
        },
      ),
    );
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (context) => _AddAccountDialog(provider: provider),
  );
}

Future<void> _validateStoredAccount(
  BuildContext context,
  WidgetRef ref,
  String accountId,
) async {
  try {
    await ref.read(mailApiClientProvider).validateStoredAccount(accountId);
  } finally {
    ref.invalidate(accountsProvider);
  }
}

Future<void> _syncAccount(WidgetRef ref, String accountId) async {
  await ref.read(mailApiClientProvider).syncAccount(accountId);
  ref.invalidate(accountsProvider);
  ref.invalidate(accountMessagesProvider(accountId));
}

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  String accountId,
  VoidCallback onDeleted,
) async {
  final strings = ref.read(appStringsProvider);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(strings.confirmDeleteAccount),
      content: Text(strings.deleteAccountDescription),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(strings.deleteAccount),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  await ref.read(mailApiClientProvider).deleteAccount(accountId);
  onDeleted();
  ref.invalidate(accountsProvider);
}

String _providerName(List<MailProviderSummary> providers, String providerId) {
  return providers
      .firstWhere(
        (provider) => provider.id == providerId,
        orElse: () => MailProviderSummary(
          id: providerId,
          displayName: providerId,
          authModes: const [],
          defaultProtocol: 'imap',
          supportsOAuth: false,
        ),
      )
      .displayName;
}

String _preferredAuthMode(MailProviderSummary provider) {
  if (provider.supportsOAuth && provider.authModes.contains('oauth2')) {
    return 'oauth2';
  }
  if (provider.authModes.contains('app-password')) return 'app-password';
  if (provider.authModes.contains('password')) return 'password';
  return provider.authModes.firstOrNull ?? 'password';
}

String friendlyError(Object error, AppStrings strings) {
  if (error is DioException) {
    if (isMailApiConnectionError(error)) {
      return strings.serverUnavailableDescription;
    }
    final data = error.response?.data;
    if (data is Map && data['error'] is String) {
      return data['error'] as String;
    }
    if (error.response?.statusCode == 400) return strings.oauthClientMissing;
    if (error.response?.statusCode == 500) return strings.connectionFailed;
    return error.message ?? strings.connectionFailed;
  }

  final message = error.toString();
  if (message.contains('OAuth client id') || message.contains('OAuth 클라이언트')) {
    return strings.oauthClientMissing;
  }
  final errorBodyMatch = RegExp(r'error: ([^}]+)').firstMatch(message);
  if (errorBodyMatch != null) {
    return errorBodyMatch.group(1)?.trim() ?? strings.connectionFailed;
  }
  if (message.contains('500')) {
    return strings.connectionFailed;
  }
  return message.replaceFirst('Exception: ', '');
}

String _syncLabel(InitialSyncOption? option, AppStrings strings) {
  if (option == null) return strings.neverSynced;
  return strings.currentLanguage == AppLanguage.korean
      ? option.labelKo()
      : option.labelEn();
}
