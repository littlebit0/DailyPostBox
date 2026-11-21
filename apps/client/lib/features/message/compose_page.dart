import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';

final composeAccountsProvider = FutureProvider<List<MailAccountSummary>>((ref) {
  return ref.watch(mailApiClientProvider).fetchAccounts();
});

class ComposePage extends ConsumerStatefulWidget {
  const ComposePage({
    super.key,
    this.initialAccountId,
  });

  final String? initialAccountId;

  @override
  ConsumerState<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends ConsumerState<ComposePage> {
  final _toController = TextEditingController();
  final _subjectController = TextEditingController();
  final _bodyController = TextEditingController();
  String? _accountId;

  @override
  void initState() {
    super.initState();
    _accountId = widget.initialAccountId;
  }

  @override
  void dispose() {
    _toController.dispose();
    _subjectController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(composeAccountsProvider);
    final strings = ref.watch(appStringsProvider);
    final initialAccountId = widget.initialAccountId;
    final returnPath = initialAccountId == null
        ? '/accounts'
        : '/accounts/$initialAccountId/mail';

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBar(
          leading: IconButton(
            tooltip: strings.close,
            onPressed: () => context.go(returnPath),
            icon: const Icon(Icons.close),
          ),
          title: Text(strings.compose),
          actions: [
            IconButton(
              tooltip: strings.send,
              onPressed: _send,
              icon: const Icon(Icons.send_outlined),
            ),
          ],
        ),
        Expanded(
          child: accounts.when(
            data: (items) {
              if (_accountId == null ||
                  !items.any((account) => account.id == _accountId)) {
                _accountId = items.firstOrNull?.id;
              }

              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _accountId,
                    decoration: InputDecoration(labelText: strings.from),
                    items: [
                      for (final account in items)
                        DropdownMenuItem(
                          value: account.id,
                          child: Text(account.emailAddress),
                        ),
                    ],
                    onChanged: (value) => setState(() => _accountId = value),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _toController,
                    decoration: InputDecoration(labelText: strings.to),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _subjectController,
                    decoration: InputDecoration(labelText: strings.subject),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _bodyController,
                    minLines: 12,
                    maxLines: 24,
                    decoration: InputDecoration(labelText: strings.body),
                  ),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(
              child: Text(strings.accountLoadFailedTitle),
            ),
          ),
        ),
      ],
    );

    if (initialAccountId == null) {
      return Scaffold(body: content);
    }
    return AppShell(
      selectedDestinationId: AppShell.accountDestinationId(initialAccountId),
      child: content,
    );
  }

  Future<void> _send() async {
    final accountId = _accountId;
    if (accountId == null) return;

    final client = ref.read(mailApiClientProvider);
    final strings = ref.read(appStringsProvider);
    final delay = ref.read(undoSendDelayProvider);
    final messenger = ScaffoldMessenger.of(context);
    final started = DateTime.now();
    final id = await client.sendMail(
      accountId: accountId,
      to: _toController.text.split(',').map((item) => item.trim()).toList(),
      subject: _subjectController.text,
      body: _bodyController.text,
      delaySeconds: delay,
    );

    // Server countdown starts at enqueue: show immediately (not behind older snackbars)
    // and expire against the real send deadline.
    final remaining = Duration(seconds: delay) - DateTime.now().difference(started);
    if (delay > 0 && remaining > Duration.zero) {
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: Text(strings.mailSending),
        duration: remaining,
        action: SnackBarAction(
          label: strings.undoSend,
          onPressed: () async {
            String result;
            try {
              result = await client.cancelSend(id)
                  ? strings.sendCancelled
                  : strings.sendAlreadySent;
            } catch (_) {
              result = strings.sendCancelFailed;
            }
            messenger.showSnackBar(SnackBar(content: Text(result)));
          },
        ),
      ));
    }

    if (mounted) context.go('/accounts/$accountId/mail');
  }
}
