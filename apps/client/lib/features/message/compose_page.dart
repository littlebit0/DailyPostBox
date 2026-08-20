import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';

final composeAccountsProvider = FutureProvider<List<MailAccountSummary>>((ref) {
  return ref.watch(mailApiClientProvider).fetchAccounts();
});

class ComposePage extends ConsumerStatefulWidget {
  const ComposePage({super.key});

  @override
  ConsumerState<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends ConsumerState<ComposePage> {
  final _toController = TextEditingController();
  final _subjectController = TextEditingController();
  final _bodyController = TextEditingController();
  String? _accountId;

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

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: strings.close,
          onPressed: () => context.go('/'),
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
      body: accounts.when(
        data: (items) {
          _accountId ??= items.firstOrNull?.id;

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
        error: (error, stackTrace) => Center(child: Text('$error')),
      ),
    );
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

    if (mounted) context.go('/');
  }
}
