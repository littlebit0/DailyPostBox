import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../accounts/account_providers.dart';
import '../../widgets/app_shell.dart';
import 'attachment_list.dart';
import 'html_message_body.dart';
import 'linked_message_body.dart';
import 'reply_draft.dart';
import 'snooze_options.dart';

typedef MessageRequest = ({
  String messageId,
  String accountId,
  bool remoteImages,
});

// Messages are looked up per account: IMAP UIDs repeat across accounts.
final messageProvider =
    FutureProvider.family<MessageDetail, MessageRequest>((ref, request) {
  return ref.watch(mailApiClientProvider).fetchAccountMessage(
        accountId: request.accountId,
        messageId: request.messageId,
        remoteImages: request.remoteImages,
      );
});

class MessagePage extends ConsumerStatefulWidget {
  const MessagePage({
    super.key,
    required this.messageId,
    required this.accountId,
  });

  final String messageId;
  final String accountId;

  @override
  ConsumerState<MessagePage> createState() => _MessagePageState();
}

class _MessagePageState extends ConsumerState<MessagePage> {
  // Per-view only: remote images are never remembered across messages.
  bool _showRemoteImages = false;

  @override
  void didUpdateWidget(MessagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId != widget.messageId ||
        oldWidget.accountId != widget.accountId) {
      _showRemoteImages = false;
    }
  }

  // Local overrides until the server confirms; null means "as loaded".
  bool? _seen;
  bool? _flagged;
  bool _autoMarked = false;

  String get messageId => widget.messageId;
  String get accountId => widget.accountId;

  // Last server-confirmed values (null = as loaded); failures roll back to these.
  bool? _confirmedSeen;
  bool? _confirmedFlagged;

  // Bumped per request so a failure only rolls back when no newer request for the field is pending.
  int _seenVersion = 0;
  int _flaggedVersion = 0;

  // Requests run one at a time so the server applies them in tap order.
  Future<void> _queue = Future.value();

  Future<void> _setFlags({bool? seen, bool? flagged}) async {
    final id = accountId;
    // The container outlives this widget, so invalidation still works after dispose.
    final container = ProviderScope.containerOf(context, listen: false);
    final seenVersion = seen != null ? ++_seenVersion : _seenVersion;
    final flaggedVersion =
        flagged != null ? ++_flaggedVersion : _flaggedVersion;
    setState(() {
      if (seen != null) _seen = seen;
      if (flagged != null) _flagged = flagged;
    });
    try {
      final run = _queue.then(
        (_) => container.read(mailApiClientProvider).setMessageFlags(
              accountId: id,
              messageId: messageId,
              seen: seen,
              flagged: flagged,
            ),
      );
      _queue = run.catchError((_) {});
      await run;
      if (seen != null) _confirmedSeen = seen;
      if (flagged != null) _confirmedFlagged = flagged;
      container.invalidate(accountMessagesProvider(id));
      container.invalidate(
        messageProvider((
          messageId: messageId,
          accountId: id,
          remoteImages: _showRemoteImages,
        )),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (seen != null && seenVersion == _seenVersion) _seen = _confirmedSeen;
        if (flagged != null && flaggedVersion == _flaggedVersion) {
          _flagged = _confirmedFlagged;
        }
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(ref.read(appStringsProvider).flagUpdateFailed)),
      );
    }
  }

  // Opening a message marks it read, matching other mail apps.
  void _markReadOnOpen(AsyncValue<MessageDetail> value) {
    final item = value.valueOrNull;
    if (item == null || _autoMarked) return;
    _autoMarked = true;
    if (!item.seen) _setFlags(seen: true);
  }

  @override
  Widget build(BuildContext context) {
    final request = (
      messageId: messageId,
      accountId: accountId,
      remoteImages: _showRemoteImages,
    );
    final message = ref.watch(messageProvider(request));
    final detail = message.valueOrNull;
    if (!_autoMarked && detail != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _markReadOnOpen(message);
      });
    }
    final seen = _seen ?? detail?.seen ?? false;
    final flagged = _flagged ?? detail?.flagged ?? false;
    final strings = ref.watch(appStringsProvider);
    final mailboxPath = '/accounts/$accountId/mail';

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
            if (detail != null) ...[
              IconButton(
                tooltip: flagged ? strings.removeStar : strings.addStar,
                onPressed: () => _setFlags(flagged: !flagged),
                icon: Icon(
                  flagged ? Icons.star : Icons.star_border,
                  color: flagged ? Colors.amber : null,
                ),
              ),
              IconButton(
                tooltip: seen ? strings.markUnread : strings.markRead,
                onPressed: () => _setFlags(seen: !seen),
                icon: Icon(
                  seen
                      ? Icons.mark_email_unread_outlined
                      : Icons.drafts_outlined,
                ),
              ),
            ],
            if (message.value case final item?) ...[
              IconButton(
                tooltip: strings.reply,
                onPressed: () => _reply(context, item, strings, all: false),
                icon: const Icon(Icons.reply),
              ),
              IconButton(
                tooltip: strings.replyAll,
                onPressed: () => _reply(context, item, strings, all: true),
                icon: const Icon(Icons.reply_all),
              ),
            ],
            PopupMenuButton<String>(
              tooltip: strings.snooze,
              icon: const Icon(Icons.snooze),
              onSelected: (choice) =>
                  widget._snooze(context, ref, strings, choice, accountId),
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
                if (item.remoteImageCount > 0 && !_showRemoteImages)
                  _RemoteImageBanner(
                    count: item.remoteImageCount,
                    onShow: () => setState(() => _showRemoteImages = true),
                  ),
                if (item.html.isNotEmpty)
                  HtmlMessageBody(html: item.html)
                else
                  LinkedMessageBody(body: item.body, links: item.links),
                if (item.attachments.isNotEmpty)
                  AttachmentList(
                    accountId: accountId,
                    messageId: messageId,
                    attachments: item.attachments,
                  ),
              ],
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) =>
                Center(child: Text(strings.messageLoadFailedTitle)),
          ),
        ),
      ],
    );

    return AppShell(
      selectedDestinationId: AppShell.accountDestinationId(accountId),
      child: content,
    );
  }

  void _reply(
    BuildContext context,
    MessageDetail item,
    AppStrings strings, {
    required bool all,
  }) {
    context.go(
      '/accounts/${item.accountId ?? accountId}/compose',
      extra: ReplyDraft.from(item, strings, all: all),
    );
  }
}

class _RemoteImageBanner extends ConsumerWidget {
  const _RemoteImageBanner({required this.count, required this.onShow});

  final int count;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(strings.remoteImagesBlocked(count))),
          TextButton(onPressed: onShow, child: Text(strings.showImagesOnce)),
        ],
      ),
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
