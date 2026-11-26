import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'failed_sends.dart';
import 'pending_sends.dart';
import 'reply_draft.dart';
import '../accounts/accounts_page.dart' show friendlyError;

final composeAccountsProvider = FutureProvider<List<MailAccountSummary>>((ref) {
  return ref.watch(mailApiClientProvider).fetchAccounts();
});

class ComposePage extends ConsumerStatefulWidget {
  const ComposePage({
    super.key,
    this.initialAccountId,
    this.initialDraft,
    this.reply,
  });

  final String? initialAccountId;

  /// Reopened failed send (from `/compose/recover`).
  final ComposeDraft? initialDraft;
  final ReplyDraft? reply;

  @override
  ConsumerState<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends ConsumerState<ComposePage> {
  final _toController = TextEditingController();
  final _ccController = TextEditingController();
  final _subjectController = TextEditingController();
  final _bodyController = TextEditingController();
  String? _accountId;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _accountId = widget.initialAccountId;
    final draft = widget.initialDraft;
    final reply = widget.reply;
    if (draft != null) {
      _toController.text = draft.to;
      _ccController.text = draft.cc;
      _subjectController.text = draft.subject;
      _bodyController.text = draft.body;
    } else if (reply != null) {
      _toController.text = reply.to.join(', ');
      _ccController.text = reply.cc.join(', ');
      _subjectController.text = reply.subject;
      _bodyController.text = reply.body;
    }
  }

  @override
  void dispose() {
    _toController.dispose();
    _ccController.dispose();
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
            onPressed: () => context.canPop() ? context.pop() : context.go(returnPath),
            icon: const Icon(Icons.close),
          ),
          title: Text(strings.compose),
          actions: [
            IconButton(
              tooltip: strings.send,
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
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
                  if (_ccController.text.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _ccController,
                      decoration: InputDecoration(labelText: strings.cc),
                    ),
                  ],
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
    if (accountId == null || _sending) return;
    final strings = ref.read(appStringsProvider);
    final messenger = ScaffoldMessenger.of(context);
    void report(String message) =>
        messenger.showSnackBar(SnackBar(content: Text(message)));

    final to = _addresses(_toController.text);
    if (to.isEmpty) {
      report(strings.recipientRequired);
      return;
    }

    final client = ref.read(mailApiClientProvider);
    final delay = ref.read(undoSendDelayProvider);
    final router = GoRouter.of(context);
    final container = ProviderScope.containerOf(context);
    final failedSends = container.read(failedSendsProvider.notifier);
    final pendingSends = container.read(pendingSendsProvider.notifier);
    final inReplyTo = widget.initialDraft?.inReplyTo ?? widget.reply?.inReplyTo;
    final references =
        widget.initialDraft?.references ?? widget.reply?.references ?? const <String>[];

    setState(() => _sending = true);
    final SendReceipt receipt;
    try {
      receipt = await client.sendMail(
        accountId: accountId,
        to: to,
        cc: _addresses(_ccController.text),
        subject: _subjectController.text,
        body: _bodyController.text,
        delaySeconds: delay,
        inReplyTo: inReplyTo,
        references: references,
      );
    } catch (error) {
      // The draft stays on screen so the user can fix it and retry.
      if (mounted) setState(() => _sending = false);
      report(strings.sendFailed(friendlyError(error, strings)));
      return;
    }

    // The countdown comes from the server's deadline: show immediately (not behind
    // older snackbars) and expire when the server actually sends. Earlier sends stay
    // cancellable from the app-level pending list after clearSnackBars().
    if (delay > 0 && receipt.remaining > Duration.zero) {
      pendingSends.add(
        PendingSend(
          id: receipt.id,
          to: _toController.text,
          subject: _subjectController.text,
        ),
        receipt.remaining,
      );
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
        content: Text(strings.mailSending),
        duration: receipt.remaining,
        action: SnackBarAction(
          label: strings.undoSend,
          onPressed: () => cancelPendingSend(
              client, strings, messenger, pendingSends, receipt.id),
        ),
      ));
    }

    // Detached from this page on purpose: the composer closes right after sending.
    unawaited(_reportFailure(client, receipt, strings, messenger, router, failedSends));

    // Pushed pages (recovery compose) pop so the composer underneath keeps its input.
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/accounts/$accountId/mail');
    }
  }

  List<String> _addresses(String value) => value
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

/// Polls the queued send after the undo window; on failure offers to reopen the draft.
Future<void> _reportFailure(
  MailApiClient client,
  SendReceipt receipt,
  AppStrings strings,
  ScaffoldMessengerState messenger,
  GoRouter router,
  FailedSendsNotifier failedSends,
) async {
  final outcome = await awaitSendOutcome(client, receipt);
  final draft = outcome?.draft;
  if (outcome == null || draft == null) return;
  final item = FailedSend(id: receipt.id, draft: draft, error: outcome.error ?? '');
  // Also kept in the app-level list: a later send's clearSnackBars() must not lose it.
  failedSends.add(item);
  messenger.showSnackBar(SnackBar(
    content: Text(strings.sendDeliveryFailed(outcome.error ?? '')),
    duration: const Duration(seconds: 15),
    action: SnackBarAction(
      label: strings.rewriteMail,
      onPressed: () => rewriteFailedSend(router, failedSends, item),
    ),
  ));
}

/// Waits out the undo window, then polls with backoff while the send is pending/sending, up to [maxWait].
/// Returns the outcome only when the send failed.
Future<SendOutcome?> awaitSendOutcome(
  MailApiClient client,
  SendReceipt receipt, {
  Duration interval = const Duration(seconds: 2),
  Duration maxInterval = const Duration(seconds: 15),
  Duration maxWait = const Duration(minutes: 5),
}) async {
  if (receipt.remaining > Duration.zero) await Future<void>.delayed(receipt.remaining);
  var waited = Duration.zero;
  var delay = interval;
  while (waited < maxWait) {
    await Future<void>.delayed(delay);
    waited += delay;
    try {
      final outcome = await client.fetchSendOutcome(receipt.id);
      if (outcome.status == 'failed') return outcome;
      if (outcome.status == 'sent' || outcome.status == 'cancelled') return null;
    } catch (_) {
      // Transient error or expired entry: keep trying until maxWait.
    }
    delay = delay * 2 > maxInterval ? maxInterval : delay * 2;
  }
  return null;
}
