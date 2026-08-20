import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';

final messageProvider =
    FutureProvider.family<MessageDetail, String>((ref, messageId) {
  return ref.watch(mailApiClientProvider).fetchMessage(messageId);
});

class MessagePage extends ConsumerWidget {
  const MessagePage({
    super.key,
    required this.messageId,
  });

  final String messageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(messageProvider(messageId));
    final strings = ref.watch(appStringsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: strings.back,
          onPressed: () => context.go('/'),
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
      body: message.when(
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
            Text(item.body),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text('$error')),
      ),
    );
  }
}
