import 'dart:async';

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
    this.initialDraft,
  });

  final String? initialAccountId;
  final ComposeDraft? initialDraft;

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
    final draft = widget.initialDraft;
    if (draft != null) {
      _toController.text = draft.to;
      _subjectController.text = draft.subject;
      _bodyController.text = draft.body;
    }
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
    final router = GoRouter.of(context);
    final receipt = await client.sendMail(
      accountId: accountId,
      to: _toController.text.split(',').map((item) => item.trim()).toList(),
      subject: _subjectController.text,
      body: _bodyController.text,
      delaySeconds: delay,
    );

    // The countdown comes from the server's deadline: show immediately (not behind
    // older snackbars) and expire when the server actually sends.
    if (delay > 0 && receipt.remaining > Duration.zero) {
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: Text(strings.mailSending),
        duration: receipt.remaining,
        action: SnackBarAction(
          label: strings.undoSend,
          onPressed: () async {
            String result;
            try {
              final status = await client.cancelSend(receipt.id);
              result = switch (status) {
                'cancelled' => strings.sendCancelled,
                'failed' => strings.sendFailedShort,
                _ => strings.sendAlreadySent,
              };
            } catch (_) {
              result = strings.sendCancelFailed;
            }
            messenger.showSnackBar(SnackBar(content: Text(result)));
          },
        ),
      ));
    }

    // Detached from this page on purpose: the composer closes right after sending.
    unawaited(_reportFailure(client, receipt, strings, messenger, router));

    if (mounted) context.go('/accounts/$accountId/mail');
  }
}

/// Polls the queued send after the undo window; on failure offers to reopen the draft.
Future<void> _reportFailure(
  MailApiClient client,
  SendReceipt receipt,
  AppStrings strings,
  ScaffoldMessengerState messenger,
  GoRouter router,
) async {
  final outcome = await awaitSendOutcome(client, receipt);
  final draft = outcome?.draft;
  if (outcome == null || draft == null) return;
  messenger.showSnackBar(SnackBar(
    content: Text(strings.sendDeliveryFailed(outcome.error ?? '')),
    duration: const Duration(seconds: 15),
    action: SnackBarAction(
      label: strings.rewriteMail,
      onPressed: () => router.go('/accounts/${draft.accountId}/compose', extra: draft),
    ),
  ));
}

/// Waits out the undo window, then polls a few times. Returns the outcome only when the send failed.
Future<SendOutcome?> awaitSendOutcome(
  MailApiClient client,
  SendReceipt receipt, {
  Duration interval = const Duration(seconds: 2),
  int attempts = 10,
}) async {
  if (receipt.remaining > Duration.zero) await Future<void>.delayed(receipt.remaining);
  for (var i = 0; i < attempts; i++) {
    await Future<void>.delayed(interval);
    try {
      final outcome = await client.fetchSendOutcome(receipt.id);
      if (outcome.status == 'failed') return outcome;
      if (outcome.status == 'sent' || outcome.status == 'cancelled') return null;
    } catch (_) {
      // Transient error or expired entry: try again, then give up quietly.
    }
  }
  return null;
}
