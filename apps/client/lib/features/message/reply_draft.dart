import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';

/// Prefilled compose state for a reply, passed through the router `extra`.
class ReplyDraft {
  const ReplyDraft({
    required this.to,
    required this.cc,
    required this.subject,
    required this.body,
    this.inReplyTo,
    this.references = const [],
  });

  final List<String> to;
  final List<String> cc;
  final String subject;
  final String body;
  final String? inReplyTo;
  final List<String> references;

  factory ReplyDraft.from(
    MessageDetail message,
    AppStrings strings, {
    required bool all,
  }) {
    final quoted = message.body.split('\n').map((line) => '> $line').join('\n');
    return ReplyDraft(
      to: all ? message.replyAllTo : message.replyTo,
      cc: all ? message.replyAllCc : const [],
      subject: replySubject(message.subject),
      body: '\n\n${strings.quoteHeader(message.receivedAtLabel, message.sender)}'
          '\n$quoted',
      inReplyTo: message.messageId,
      references: message.references,
    );
  }
}

/// Adds one `Re:` prefix; `RE:`/`re:` already present is kept as is.
String replySubject(String subject) =>
    RegExp(r'^\s*re:', caseSensitive: false).hasMatch(subject)
        ? subject
        : 'Re: $subject';
