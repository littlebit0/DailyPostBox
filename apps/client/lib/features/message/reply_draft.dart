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
    this.forwardOf,
  });

  final List<String> to;
  final List<String> cc;
  final String subject;
  final String body;
  final String? inReplyTo;
  final List<String> references;
  final ForwardOf? forwardOf;

  factory ReplyDraft.from(
    MessageDetail message,
    AppStrings strings, {
    required bool all,
  }) {
    // HTML-only mail (e.g. one big image) has no text to quote; send the original instead.
    final includeOriginal =
        message.body.trim().isEmpty && message.html.isNotEmpty;
    final quoted = includeOriginal
        ? strings.originalAttached(originalMessageFilename)
        : message.body.split('\n').map((line) => '> $line').join('\n');
    final receivedAt = message.receivedAt;
    final quoteTime =
        receivedAt == null ? message.receivedAtLabel : strings.quoteDate(receivedAt);
    return ReplyDraft(
      to: all ? message.replyAllTo : message.replyTo,
      cc: all ? message.replyAllCc : const [],
      subject: replySubject(message.subject),
      body: '\n\n${strings.quoteHeader(quoteTime, message.sender)}'
          '\n$quoted',
      inReplyTo: message.messageId,
      references: message.references,
    );
  }

  /// Forward: no recipients and no In-Reply-To; header summary, quoted body
  /// and the original attachments (removable in the composer).
  factory ReplyDraft.forward(MessageDetail message, AppStrings strings) {
    final receivedAt = message.receivedAt;
    final header = [
      strings.forwardedMessage,
      '${strings.from}: ${message.sender}',
      '${strings.date}: ${receivedAt == null ? message.receivedAtLabel : strings.quoteDate(receivedAt)}',
      if (message.to.isNotEmpty) '${strings.to}: ${message.to.join(', ')}',
      if (message.cc.isNotEmpty) '${strings.cc}: ${message.cc.join(', ')}',
      '${strings.subject}: ${message.subject}',
    ].join('\n');
    // HTML-only mail (e.g. one big image) has no text to quote; send the original instead.
    final includeOriginal =
        message.body.trim().isEmpty && message.html.isNotEmpty;
    final quoted = includeOriginal
        ? strings.originalAttached(originalMessageFilename)
        : message.body.split('\n').map((line) => '> $line').join('\n');
    return ReplyDraft(
      to: const [],
      cc: const [],
      subject: forwardSubject(message.subject),
      body: '\n\n$header\n\n$quoted',
      forwardOf: ForwardOf(
        messageId: message.id,
        attachments: message.attachments,
        includeOriginal: includeOriginal,
      ),
    );
  }
}

/// Adds one `Fwd:` prefix; an existing `Fwd:`/`FW:`/`Fw:` (any case) is kept.
String forwardSubject(String subject) =>
    RegExp(r'^\s*(fwd?):', caseSensitive: false).hasMatch(subject)
        ? subject
        : 'Fwd: $subject';

/// Adds one `Re:` prefix; `RE:`/`re:` already present is kept as is.
String replySubject(String subject) =>
    RegExp(r'^\s*re:', caseSensitive: false).hasMatch(subject)
        ? subject
        : 'Re: $subject';
