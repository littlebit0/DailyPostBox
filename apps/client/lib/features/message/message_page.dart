import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../accounts/account_providers.dart';
import '../../widgets/app_shell.dart';
import 'linked_message_body.dart';

typedef MessageRequest = ({String messageId, String accountId});

// Messages are looked up per account: IMAP UIDs repeat across accounts.
final messageProvider =
    FutureProvider.family<MessageDetail, MessageRequest>((ref, request) {
  return ref.watch(mailApiClientProvider).fetchAccountMessage(
        accountId: request.accountId,
        messageId: request.messageId,
      );
});

/// Opens the composer addressed to the sender with a "Re:" subject.
String replyLocation({String? accountId, required MessageDetail message}) {
  final subject = message.subject;
  return Uri(
    path: accountId == null ? '/compose' : '/accounts/$accountId/compose',
    queryParameters: {
      'to': message.sender,
      'subject':
          subject.toLowerCase().startsWith('re:') ? subject : 'Re: $subject',
    },
  ).toString();
}

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
        messageProvider((messageId: messageId, accountId: id)),
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
    final request = (messageId: messageId, accountId: accountId);
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
            IconButton(
              tooltip: strings.reply,
              onPressed: switch (message.asData?.value) {
                final item? => () => context.go(
                      replyLocation(accountId: accountId, message: item),
                    ),
                null => null,
              },
              icon: const Icon(Icons.reply),
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
}
