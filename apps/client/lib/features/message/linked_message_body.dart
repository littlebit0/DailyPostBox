import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/mail_api_client.dart';

typedef MessageLinkLauncher = Future<bool> Function(Uri uri);

@immutable
class MessageBodySegment {
  const MessageBodySegment({required this.text, this.uri});

  final String text;
  final Uri? uri;
}

class LinkedMessageBody extends StatefulWidget {
  const LinkedMessageBody({
    super.key,
    required this.body,
    required this.links,
    this.linkLauncher,
  });

  final String body;
  final List<MessageLink> links;
  final MessageLinkLauncher? linkLauncher;

  @override
  State<LinkedMessageBody> createState() => _LinkedMessageBodyState();
}

class _LinkedMessageBodyState extends State<LinkedMessageBody> {
  late List<MessageBodySegment> _segments;
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _resetSegments();
  }

  @override
  void didUpdateWidget(covariant LinkedMessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.body != widget.body ||
        oldWidget.links != widget.links ||
        oldWidget.linkLauncher != widget.linkLauncher) {
      _resetSegments();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _resetSegments() {
    _disposeRecognizers();
    _segments = parseMessageBody(body: widget.body, links: widget.links);
    for (final segment in _segments.where((item) => item.uri != null)) {
      _recognizers.add(
        TapGestureRecognizer()..onTap = () => _openLink(segment.uri!),
      );
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _openLink(Uri uri) async {
    final launcher = widget.linkLauncher ?? _launchExternalLink;
    await launcher(uri);
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
          height: 1.55,
        );
    final linkColor = Theme.of(context).colorScheme.primary;
    final linkStyle = baseStyle?.copyWith(
      color: linkColor,
    );
    final spans = <InlineSpan>[];
    final linkRanges = <TextRange>[];
    var linkIndex = 0;
    var textOffset = 0;

    for (final segment in _segments) {
      if (segment.uri == null) {
        spans.add(TextSpan(text: segment.text));
      } else {
        linkRanges.add(
          TextRange(
            start: textOffset,
            end: textOffset + segment.text.length,
          ),
        );
        spans.add(
          TextSpan(
            text: segment.text,
            style: linkStyle,
            recognizer: _recognizers[linkIndex++],
            mouseCursor: SystemMouseCursors.click,
          ),
        );
      }
      textOffset += segment.text.length;
    }

    final textSpan = TextSpan(style: baseStyle, children: spans);
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);

    return SelectionArea(
      child: CustomPaint(
        foregroundPainter: _ContinuousLinkUnderlinePainter(
          text: textSpan,
          ranges: linkRanges,
          color: linkColor,
          textDirection: textDirection,
          textScaler: textScaler,
          locale: Localizations.maybeLocaleOf(context),
        ),
        child: Text.rich(
          textSpan,
          key: const ValueKey('linked-message-body-text'),
          textDirection: textDirection,
          textScaler: textScaler,
        ),
      ),
    );
  }
}

class _ContinuousLinkUnderlinePainter extends CustomPainter {
  const _ContinuousLinkUnderlinePainter({
    required this.text,
    required this.ranges,
    required this.color,
    required this.textDirection,
    required this.textScaler,
    required this.locale,
  });

  final TextSpan text;
  final List<TextRange> ranges;
  final Color color;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final Locale? locale;

  @override
  void paint(Canvas canvas, Size size) {
    if (ranges.isEmpty || size.width <= 0) return;

    final textPainter = TextPainter(
      text: text,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: size.width);
    final underlinePaint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.square;

    for (final range in ranges) {
      final boxes = textPainter.getBoxesForSelection(
        TextSelection(baseOffset: range.start, extentOffset: range.end),
      );
      for (final rect in mergeLinkUnderlineBoxes(boxes)) {
        final y = rect.bottom - 1;
        canvas.drawLine(
            Offset(rect.left, y), Offset(rect.right, y), underlinePaint);
      }
    }
    textPainter.dispose();
  }

  @override
  bool shouldRepaint(covariant _ContinuousLinkUnderlinePainter oldDelegate) {
    return oldDelegate.text != text ||
        oldDelegate.ranges != ranges ||
        oldDelegate.color != color ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.locale != locale;
  }
}

@visibleForTesting
List<Rect> mergeLinkUnderlineBoxes(List<TextBox> boxes) {
  final lines = <Rect>[];

  for (final box in boxes) {
    final rect = Rect.fromLTRB(box.left, box.top, box.right, box.bottom);
    final lineIndex = lines.indexWhere(
      (line) => line.top < rect.bottom && rect.top < line.bottom,
    );

    if (lineIndex < 0) {
      lines.add(rect);
      continue;
    }

    final line = lines[lineIndex];
    lines[lineIndex] = Rect.fromLTRB(
      line.left < rect.left ? line.left : rect.left,
      line.top < rect.top ? line.top : rect.top,
      line.right > rect.right ? line.right : rect.right,
      line.bottom > rect.bottom ? line.bottom : rect.bottom,
    );
  }

  return lines;
}

@visibleForTesting
List<MessageBodySegment> parseMessageBody({
  required String body,
  required List<MessageLink> links,
}) {
  final matches = _linkPattern.allMatches(body);
  final segments = <MessageBodySegment>[];
  var cursor = 0;

  for (final match in matches) {
    final enclosedUrl = match.group(1);
    final bareUrl = match.group(2);
    var url = enclosedUrl ?? bareUrl ?? '';
    var trailingPunctuation = '';

    if (bareUrl != null) {
      final stripped = _stripTrailingPunctuation(url);
      url = stripped.url;
      trailingPunctuation = stripped.trailing;
    }

    final uri = _safeUri(url);
    if (uri == null) continue;

    var precedingText = body.substring(cursor, match.start);
    final label = _findLinkLabel(
      url: url,
      precedingText: precedingText,
      links: links,
    );
    if (label != null) {
      precedingText = _removeTrailingLabel(precedingText, label);
    }

    _addPlainText(segments, precedingText);
    segments.add(
      MessageBodySegment(
        text: label ?? _readableUriLabel(uri),
        uri: uri,
      ),
    );
    _addPlainText(segments, trailingPunctuation);
    cursor = match.end;
  }

  _addPlainText(segments, body.substring(cursor));
  return segments;
}

final _linkPattern = RegExp(
  r'<((?:https?://|mailto:)[^>\s]+)>|((?:https?://|mailto:)[^\s<>()]+)',
  caseSensitive: false,
);

Uri? _safeUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return null;

  final scheme = uri.scheme.toLowerCase();
  if (!const {'http', 'https', 'mailto'}.contains(scheme)) return null;
  if ((scheme == 'http' || scheme == 'https') && uri.host.isEmpty) return null;
  if (scheme == 'mailto' && uri.path.isEmpty) return null;
  return uri;
}

String? _findLinkLabel({
  required String url,
  required String precedingText,
  required List<MessageLink> links,
}) {
  final readableLinks = links.where(
    (link) => _isReadableLabel(link.label),
  );

  // Some providers generate different tracking URLs for the HTML and plain
  // alternatives. An adjacent anchor label is therefore stronger evidence
  // than URL equality.
  for (final candidate in readableLinks) {
    if (_removeTrailingLabel(precedingText, candidate.label) != precedingText) {
      return candidate.label.trim();
    }
  }
  for (final candidate in readableLinks.where(
    (link) => _sameUrl(link.url, url),
  )) {
    return candidate.label.trim();
  }
  return null;
}

bool _sameUrl(String first, String second) {
  if (first == second) return true;
  final firstUri = Uri.tryParse(first);
  final secondUri = Uri.tryParse(second);
  return firstUri != null && secondUri != null && firstUri == secondUri;
}

bool _isReadableLabel(String value) {
  final label = value.trim();
  if (label.isEmpty) return false;
  if (_safeUri(label) != null) return false;
  return !label.toLowerCase().startsWith('www.');
}

String _removeTrailingLabel(String source, String label) {
  final words = label.trim().split(RegExp(r'\s+'));
  if (words.isEmpty) return source;

  final pattern = words.map(RegExp.escape).join(r'\s+');
  return source.replaceFirst(RegExp('$pattern\\s*\$'), '');
}

({String url, String trailing}) _stripTrailingPunctuation(String value) {
  var end = value.length;
  while (end > 0 && '.,;:!?)]}'.contains(value[end - 1])) {
    end -= 1;
  }
  return (url: value.substring(0, end), trailing: value.substring(end));
}

String _readableUriLabel(Uri uri) {
  if (uri.scheme.toLowerCase() == 'mailto') return uri.path;
  return uri.host.replaceFirst(RegExp(r'^www\.', caseSensitive: false), '');
}

void _addPlainText(List<MessageBodySegment> segments, String text) {
  if (text.isEmpty) return;
  if (segments.isNotEmpty && segments.last.uri == null) {
    final previous = segments.removeLast();
    segments.add(MessageBodySegment(text: previous.text + text));
    return;
  }
  segments.add(MessageBodySegment(text: text));
}

Future<bool> _launchExternalLink(Uri uri) {
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
