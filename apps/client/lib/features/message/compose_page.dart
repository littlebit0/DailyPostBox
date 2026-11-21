import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';

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
  String _signature = '';
  bool _signatureInitialized = false;

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
              if (!_signatureInitialized && items.isNotEmpty) {
                _signatureInitialized = true;
                _useSignatureOf(items, _accountId);
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
                    onChanged: (value) => setState(() {
                      _accountId = value;
                      _useSignatureOf(items, value);
                    }),
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

  void _useSignatureOf(List<MailAccountSummary> items, String? accountId) {
    final next =
        items.where((a) => a.id == accountId).firstOrNull?.signature ?? '';
    _bodyController.text = swapSignature(_bodyController.text, _signature, next);
    _signature = next;
  }

  Future<void> _send() async {
    final accountId = _accountId;
    if (accountId == null) return;

    await ref.read(mailApiClientProvider).sendMail(
          accountId: accountId,
          to: _toController.text.split(',').map((item) => item.trim()).toList(),
          subject: _subjectController.text,
          body: _bodyController.text,
        );

    if (mounted) context.go('/accounts/$accountId/mail');
  }
}
