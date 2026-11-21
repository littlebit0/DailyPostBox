import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';

class AttachmentList extends ConsumerWidget {
  const AttachmentList({
    super.key,
    required this.accountId,
    required this.messageId,
    required this.attachments,
  });

  final String accountId;
  final String messageId;
  final List<MessageAttachment> attachments;

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    MessageAttachment attachment,
  ) async {
    final strings = ref.read(appStringsProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // shortcut: file_selector save dialog is desktop only, add a mobile
      // share/save flow in a follow-up.
      final location = await getSaveLocation(
        suggestedName: attachment.filename,
      );
      if (location == null) return;
      await ref.read(mailApiClientProvider).downloadAttachment(
            accountId: accountId,
            messageId: messageId,
            part: attachment.part,
            savePath: location.path,
          );
      messenger.showSnackBar(
        SnackBar(content: Text(strings.attachmentSaved(location.path))),
      );
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(strings.attachmentSaveFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text(strings.attachments,
            style: Theme.of(context).textTheme.titleSmall),
        for (final attachment in attachments)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.attach_file),
            title: Text(attachment.filename),
            subtitle: Text(
              '${formatAttachmentSize(attachment.size)} · ${attachment.contentType}',
            ),
            trailing: IconButton(
              tooltip: strings.saveAttachment,
              onPressed: () => _save(context, ref, attachment),
              icon: const Icon(Icons.download),
            ),
          ),
      ],
    );
  }
}
