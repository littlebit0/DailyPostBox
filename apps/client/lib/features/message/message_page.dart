import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../widgets/app_shell.dart';
import '../accounts/account_providers.dart';
import 'linked_message_body.dart';
import 'snooze_options.dart';

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
            if (accountId != null)
              PopupMenuButton<String>(
                tooltip: strings.snooze,
                icon: const Icon(Icons.snooze),
                onSelected: (choice) =>
                    _snooze(context, ref, strings, choice, accountId!),
                itemBuilder: (context) {
                  final now = DateTime.now();
                  return [
                    if (snoozeTonight(now).isAfter(now))
                      PopupMenuItem(
                        value: 'tonight',
                        child: Text(strings.snoozeTonight),
                      ),
                    PopupMenuItem(
                      value: 'tomorrow',
                      child: Text(strings.snoozeTomorrow),
                    ),
                    PopupMenuItem(
                      value: 'nextWeek',
                      child: Text(strings.snoozeNextWeek),
                    ),
                    PopupMenuItem(
                      value: 'custom',
                      child: Text(strings.snoozeCustom),
                    ),
                  ];
                },
              ),
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

extension on MessagePage {
  Future<void> _snooze(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
    String choice,
    String accountId,
  ) async {
    final now = DateTime.now();
    DateTime? wakeAt = switch (choice) {
      'tonight' => snoozeTonight(now),
      'tomorrow' => snoozeTomorrowMorning(now),
      'nextWeek' => snoozeNextWeek(now),
      _ => null,
    };
    if (choice == 'custom') {
      final date = await showDatePicker(
        context: context,
        initialDate: now.add(const Duration(days: 1)),
        firstDate: now,
        lastDate: now.add(const Duration(days: 365)),
      );
      if (date == null || !context.mounted) return;
      final time = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 9, minute: 0),
      );
      if (time == null) return;
      wakeAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    }
    if (wakeAt == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    // The container outlives this page, so it is safe to use after the await.
    final container = ProviderScope.containerOf(context);
    try {
      await container
          .read(mailApiClientProvider)
          .snoozeMessage(
            accountId: accountId,
            messageId: messageId,
            wakeAt: wakeAt,
          );
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(strings.snoozeFailed)));
      return;
    }
    container.invalidate(accountMessagesProvider(accountId));
    scheduleSnoozeWakeRefresh(
      wakeAt,
      () => container.invalidate(accountMessagesProvider(accountId)),
    );
    if (context.mounted) {
      router.go(
        '/accounts/$accountId/mail',
        extra: const {'disableTransition': true},
      );
    }
    final label =
        '${wakeAt.month}/${wakeAt.day} ${wakeAt.hour.toString().padLeft(2, '0')}:${wakeAt.minute.toString().padLeft(2, '0')}';
    messenger.showSnackBar(SnackBar(content: Text(strings.snoozed(label))));
  }
}
