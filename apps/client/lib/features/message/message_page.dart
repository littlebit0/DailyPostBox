import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import 'linked_message_body.dart';

typedef MessageRequest = ({String messageId, String? accountId});

final messageProvider =
    FutureProvider.family<MessageDetail, MessageRequest>((ref, request) {
  final api = ref.watch(mailApiClientProvider);
  final accountId = request.accountId;
  if (accountId != null) {
    return api.fetchAccountMessage(
      accountId: accountId,
      messageId: request.messageId,
    );
  }
  return api.fetchMessage(request.messageId);
});

// autoDispose: a failed /features check is retried the next time a message opens.
final aiSummaryEnabledProvider = FutureProvider.autoDispose<bool>((ref) async {
  try {
    return await ref.watch(mailApiClientProvider).fetchAiSummaryEnabled();
  } catch (_) {
    return false;
  }
});

class MessagePage extends ConsumerWidget {
  const MessagePage({
    super.key,
    required this.messageId,
    this.accountId,
  });

  final String messageId;
  final String? accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(
      messageProvider((messageId: messageId, accountId: accountId)),
    );
    final strings = ref.watch(appStringsProvider);
    final summaryEnabled =
        accountId != null && ref.watch(aiSummaryEnabledProvider).value == true;
    final mailboxPath =
        accountId == null ? '/accounts' : '/accounts/$accountId/mail';

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppBar(
          leading: IconButton(
            tooltip: strings.back,
            onPressed: () => context.go(
              mailboxPath,
              extra: const {'disableTransition': true},
            ),
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(strings.message),
          actions: [
            IconButton(
              tooltip: strings.reply,
              onPressed: () {},
              icon: const Icon(Icons.reply),
            ),
            IconButton(
              tooltip: strings.archive,
              onPressed: () {},
              icon: const Icon(Icons.archive_outlined),
            ),
          ],
        ),
        Expanded(
          child: message.when(
            data: (item) => ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  item.subject,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text('${strings.from}: ${item.sender}'),
                Text(item.receivedAtLabel),
                const Divider(height: 32),
                if (summaryEnabled)
                  _SummaryCard(
                    accountId: accountId!,
                    messageId: messageId,
                    strings: strings,
                  ),
                LinkedMessageBody(body: item.body, links: item.links),
              ],
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(
              child: Text(strings.messageLoadFailedTitle),
            ),
          ),
        ),
      ],
    );

    final selectedAccountId = accountId;
    if (selectedAccountId == null) {
      return Scaffold(body: content);
    }
    return AppShell(
      selectedDestinationId: AppShell.accountDestinationId(selectedAccountId),
      child: content,
    );
  }
}

class _SummaryCard extends ConsumerStatefulWidget {
  const _SummaryCard({
    required this.accountId,
    required this.messageId,
    required this.strings,
  });

  final String accountId;
  final String messageId;
  final AppStrings strings;

  @override
  ConsumerState<_SummaryCard> createState() => _SummaryCardState();
}

class _SummaryCardState extends ConsumerState<_SummaryCard> {
  bool _loading = false;
  String? _summary;
  bool _failed = false;

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final text = await ref
          .read(mailApiClientProvider)
          .summarizeMessage(
            accountId: widget.accountId,
            messageId: widget.messageId,
          );
      if (mounted) setState(() => _summary = text);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.summaryTitle,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (_loading)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    TextButton.icon(
                      onPressed: _run,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: Text(strings.summarize),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                strings.summaryNotice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_summary != null) ...[
                const SizedBox(height: 12),
                SelectableText(_summary!),
              ],
              if (_failed) ...[
                const SizedBox(height: 12),
                Text(strings.summaryFailed),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
