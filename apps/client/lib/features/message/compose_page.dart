import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'failed_sends.dart';
import 'pending_sends.dart';
import 'recipient_field.dart';
import 'reply_draft.dart';
import '../accounts/accounts_page.dart' show friendlyError;

final composeAccountsProvider = FutureProvider<List<MailAccountSummary>>((ref) {
  return ref.watch(mailApiClientProvider).fetchAccounts();
});

const _signatureSeparator = '\n\n-- \n';

/// Appends [signature] to [body], or swaps it for [previous] when the user
/// has not edited the old signature block.
String swapSignature(String body, String previous, String signature) {
  final oldBlock = previous.isEmpty ? '' : _signatureSeparator + previous;
  final newBlock = signature.isEmpty ? '' : _signatureSeparator + signature;
  if (oldBlock.isNotEmpty) {
    // Edited or deleted by the user: leave the body alone.
    if (!body.endsWith(oldBlock)) return body;
    return body.substring(0, body.length - oldBlock.length) + newBlock;
  }
  return body + newBlock;
}

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
  final _toAddresses = <String>[];
  final _toController = TextEditingController();
  final _ccController = TextEditingController();
  final _subjectController = TextEditingController();
  final _bodyController = TextEditingController();
  String? _accountId;
  String _signature = '';
  bool _signatureInitialized = false;
  bool _sending = false;
  ForwardOf? _forwardOf;

  @override
  void initState() {
    super.initState();
    _accountId = widget.initialAccountId;
    final draft = widget.initialDraft;
    final reply = widget.reply;
    _forwardOf = draft?.forwardOf ?? reply?.forwardOf;
    if (draft != null) {
      _toController.text = draft.to;
      commitRecipientText(_toAddresses, _toController);
      _ccController.text = draft.cc;
      _subjectController.text = draft.subject;
      _bodyController.text = draft.body;
    } else if (reply != null) {
      _toAddresses.addAll(reply.to);
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
              if (!_signatureInitialized && items.isNotEmpty) {
                _signatureInitialized = true;
                if (widget.initialDraft != null) {
                  // Recovered draft already carries its signature: adopt, don't re-insert.
                  _signature = _signatureOf(items, _accountId);
                } else {
                  _useSignatureOf(items, _accountId);
                }
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
                    // Forwarded parts are read from the original account's mailbox.
                    onChanged: !(_forwardOf?.isEmpty ?? true)
                        ? null
                        : (value) => setState(() {
                              _accountId = value;
                              _useSignatureOf(items, value);
                            }),
                  ),
                  const SizedBox(height: 12),
                  RecipientField(
                    label: strings.to,
                    errorText: strings.invalidRecipient,
                    suggest: ref.read(mailApiClientProvider).suggestContacts,
                    addresses: _toAddresses,
                    controller: _toController,
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
                  if (_forwardOf case final forward?
                      when !forward.isEmpty) ...[
                    const SizedBox(height: 12),
                    Text(strings.forwardedAttachments,
                        style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final attachment in forward.attachments)
                          InputChip(
                            avatar: const Icon(Icons.attach_file, size: 18),
                            label: Text(
                                '${attachment.filename} (${formatAttachmentSize(attachment.size)})'),
                            deleteButtonTooltipMessage:
                                strings.removeAttachment(attachment.filename),
                            onDeleted: () => setState(() {
                              _forwardOf = ForwardOf(
                                messageId: forward.messageId,
                                attachments: [
                                  for (final a in forward.attachments)
                                    if (a.part != attachment.part) a,
                                ],
                                includeOriginal: forward.includeOriginal,
                              );
                            }),
                          ),
                        if (forward.includeOriginal)
                          InputChip(
                            avatar: const Icon(Icons.mail_outline, size: 18),
                            label: const Text(originalMessageFilename),
                            deleteButtonTooltipMessage: strings
                                .removeAttachment(originalMessageFilename),
                            onDeleted: () => setState(() {
                              _forwardOf = ForwardOf(
                                messageId: forward.messageId,
                                attachments: forward.attachments,
                              );
                            }),
                          ),
                      ],
                    ),
                  ],
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
      cachePaths: const [MailApiClient.accountsPath],
      child: content,
    );
  }

  String _signatureOf(List<MailAccountSummary> items, String? accountId) =>
      items.where((a) => a.id == accountId).firstOrNull?.signature ?? '';

  void _useSignatureOf(List<MailAccountSummary> items, String? accountId) {
    final next = _signatureOf(items, accountId);
    // Reply quote stays below the signature (signature sits above the quote).
    final quote = widget.initialDraft == null ? widget.reply?.body ?? '' : '';
    final full = _bodyController.text;
    if (!full.endsWith(quote)) return;
    final body = full.substring(0, full.length - quote.length);
    // User edited the managed block: keep owning the old signature so later
    // switches neither overwrite the edit nor append a duplicate.
    if (_signature.isNotEmpty &&
        !body.endsWith(_signatureSeparator + _signature)) {
      return;
    }
    final text = swapSignature(body, _signature, next);
    final bodyEnd = text.length -
        (next.isEmpty ? 0 : _signatureSeparator.length + next.length);
    final selection = _bodyController.selection;
    // An invalid selection jumps to the end on focus, i.e. after the signature.
    _bodyController.value = TextEditingValue(
      text: text + quote,
      selection: selection.isValid && selection.end <= bodyEnd
          ? selection
          : TextSelection.collapsed(offset: bodyEnd),
    );
    _signature = next;
  }

  Future<void> _send() async {
    final accountId = _accountId;
    if (accountId == null || _sending) return;
    final strings = ref.read(appStringsProvider);
    final messenger = ScaffoldMessenger.of(context);
    void report(String message) =>
        messenger.showSnackBar(SnackBar(content: Text(message)));

    if (commitRecipientText(_toAddresses, _toController)) setState(() {});
    final to = List<String>.unmodifiable(_toAddresses);
    if (to.isEmpty || hasInvalidRecipient(to)) {
      report(to.isEmpty ? strings.recipientRequired : strings.invalidRecipient);
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
        forwardOf: _forwardOf,
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
          to: to.join(', '),
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
