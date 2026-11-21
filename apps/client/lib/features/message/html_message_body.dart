import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'linked_message_body.dart';

/// Renders HTML that the server already sanitized with an allow-list.
///
/// Only a small tag set is understood and no network request is made unless
/// the HTML itself contains an http(s) `img`, which the server only returns
/// after the user asked to load remote images.
class HtmlMessageBody extends StatefulWidget {
  const HtmlMessageBody({super.key, required this.html, this.linkLauncher});

  final String html;
  final MessageLinkLauncher? linkLauncher;

  @override
  State<HtmlMessageBody> createState() => _HtmlMessageBodyState();
}

class _HtmlMessageBodyState extends State<HtmlMessageBody> {
  final List<TapGestureRecognizer> _recognizers = [];
  Widget? _content;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rebuild();
  }

  @override
  void didUpdateWidget(covariant HtmlMessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        oldWidget.linkLauncher != widget.linkLauncher) {
      _rebuild();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _rebuild() {
    _disposeRecognizers();
    final body = html_parser.parseFragment(widget.html);
    final linkColor = Theme.of(context).colorScheme.primary;
    final renderer = _Renderer(
      linkColor: linkColor,
      onLink: (uri) => (widget.linkLauncher ?? launchMessageLink)(uri),
      recognizers: _recognizers,
    );
    const base = TextStyle(color: Colors.black87, fontSize: 15, height: 1.45);
    _content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: renderer.children(body.nodes, base),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Mail HTML assumes a light background, so keep it on a light surface
    // even in the dark theme.
    return SelectionArea(
      child: DecoratedBox(
        key: const ValueKey('html-message-body'),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(padding: const EdgeInsets.all(16), child: _content),
      ),
    );
  }
}

const _blockTags = {
  'p',
  'div',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'pre',
  'ul',
  'ol',
  'li',
  'hr',
  'table',
  'center',
  'dl',
  'dt',
  'dd',
  'caption',
};

class _Renderer {
  _Renderer({
    required this.linkColor,
    required this.onLink,
    required this.recognizers,
  });

  final Color linkColor;
  final void Function(Uri uri) onLink;
  final List<TapGestureRecognizer> recognizers;

  List<Widget> children(
    List<dom.Node> nodes,
    TextStyle style, {
    TextAlign align = TextAlign.start,
  }) {
    final widgets = <Widget>[];
    var spans = <InlineSpan>[];

    void flush() {
      if (spans.isEmpty) return;
      final onlySpace = spans.every(
        (span) => span.toPlainText().trim().isEmpty,
      );
      if (!onlySpace) {
        widgets.add(
          Text.rich(
            TextSpan(style: style, children: spans),
            textAlign: align,
          ),
        );
      }
      spans = <InlineSpan>[];
    }

    for (final node in nodes) {
      if (node is dom.Element && _blockTags.contains(node.localName)) {
        flush();
        widgets.add(_block(node, style));
      } else {
        _inline(node, style, spans);
      }
    }
    flush();
    return widgets;
  }

  Widget _block(dom.Element el, TextStyle parent) {
    final style = _styled(el, parent);
    final align = _align(el) ?? TextAlign.start;
    final tag = el.localName;

    switch (tag) {
      case 'hr':
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1),
        );
      case 'table':
        return _table(el, style);
      case 'ul':
      case 'ol':
        var index = 0;
        final items = <Widget>[];
        for (final child in el.children.where((c) => c.localName == 'li')) {
          index += 1;
          items.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: Text(tag == 'ol' ? '$index.' : '•', style: style),
                ),
                Expanded(child: _column(child, style, align)),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: items,
          ),
        );
      case 'blockquote':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.only(left: 12),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: Colors.black26, width: 3)),
          ),
          child: _column(el, style, align),
        );
      default:
        final spacing = (tag == 'p' || (tag?.startsWith('h') ?? false))
            ? 6.0
            : 0.0;
        return Padding(
          padding: EdgeInsets.symmetric(vertical: spacing),
          child: _column(el, style, align),
        );
    }
  }

  Widget _column(dom.Element el, TextStyle style, TextAlign align) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children(el.nodes, style, align: align),
    );
  }

  Widget _table(dom.Element table, TextStyle style) {
    final rows = <Map<int, (dom.Element cell, dom.Element row)>>[];
    // column -> number of following rows still covered by a rowspan cell.
    var pending = <int, int>{};
    for (final row in _descendants(table, 'tr')) {
      final cells = row.children
          .where((c) => c.localName == 'td' || c.localName == 'th')
          .toList();
      if (cells.isEmpty) continue;
      final slots = <int, (dom.Element, dom.Element)>{};
      final next = <int, int>{
        for (final e in pending.entries)
          if (e.value > 1) e.key: e.value - 1,
      };
      var col = 0;
      for (final cell in cells) {
        while ((pending[col] ?? 0) > 0) {
          col++;
        }
        final colspan = _span(cell, 'colspan');
        final rowspan = _span(cell, 'rowspan');
        slots[col] = (cell, row);
        for (var i = 0; i < colspan; i++) {
          if (rowspan > 1) next[col + i] = rowspan - 1;
        }
        col += colspan;
      }
      pending = next;
      rows.add(slots);
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.fold<int>(0, (m, r) {
      final width = r.keys.fold<int>(0, (a, k) => k + 1 > a ? k + 1 : a);
      return width > m ? width : m;
    });

    TableRow toRow(Map<int, (dom.Element cell, dom.Element row)> slots) =>
        TableRow(
          children: [
            for (var i = 0; i < columns; i++)
              if (slots[i] case (final cell, final row))
                ColoredBox(
                  color:
                      _background(cell) ??
                      _background(row) ??
                      Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: _column(
                      cell,
                      cell.localName == 'th'
                          ? _styled(
                              cell,
                              style,
                            ).copyWith(fontWeight: FontWeight.bold)
                          : _styled(cell, style),
                      _align(cell) ?? TextAlign.start,
                    ),
                  ),
                )
              else
                const SizedBox.shrink(),
          ],
        );

    final bordered = (int.tryParse(table.attributes['border'] ?? '') ?? 0) > 0;
    return ColoredBox(
      color: _background(table) ?? Colors.transparent,
      child: Table(
        border: bordered ? TableBorder.all(color: Colors.black26) : null,
        children: rows.map(toRow).toList(growable: false),
      ),
    );
  }

  int _span(dom.Element cell, String attribute) =>
      (int.tryParse(cell.attributes[attribute] ?? '') ?? 1).clamp(1, 20);

  /// `bgcolor` attribute or inline `background-color` of a table element.
  Color? _background(dom.Element el) {
    Color? color = _color(el.attributes['bgcolor']);
    for (final declaration in (el.attributes['style'] ?? '').split(';')) {
      final index = declaration.indexOf(':');
      if (index < 0) continue;
      if (declaration.substring(0, index).trim().toLowerCase() ==
          'background-color') {
        color = _color(declaration.substring(index + 1)) ?? color;
      }
    }
    return color;
  }

  Iterable<dom.Element> _descendants(dom.Element root, String tag) sync* {
    for (final child in root.children) {
      if (child.localName == tag) {
        yield child;
      } else if (child.localName != 'table') {
        yield* _descendants(child, tag);
      }
    }
  }

  void _inline(
    dom.Node node,
    TextStyle style,
    List<InlineSpan> out, {
    TapGestureRecognizer? recognizer,
  }) {
    if (node is dom.Text) {
      final text = _collapse(node);
      if (text.isNotEmpty) {
        // Recognizers only fire on the innermost span, so every text leaf of
        // a link carries its own.
        out.add(
          TextSpan(
            text: text,
            recognizer: recognizer,
            mouseCursor: recognizer == null ? null : SystemMouseCursors.click,
          ),
        );
      }
      return;
    }
    if (node is! dom.Element) return;

    switch (node.localName) {
      case 'br':
        out.add(const TextSpan(text: '\n'));
      case 'img':
        out.add(_image(node, recognizer));
      case 'a':
        final uri = _safeLink(node.attributes['href']);
        final linkStyle = uri == null
            ? style
            : style.copyWith(
                color: linkColor,
                decoration: TextDecoration.underline,
                decorationColor: linkColor,
              );
        TapGestureRecognizer? linkRecognizer;
        if (uri != null) {
          linkRecognizer = TapGestureRecognizer()..onTap = () => onLink(uri);
          recognizers.add(linkRecognizer);
        }
        final children = <InlineSpan>[];
        for (final child in node.nodes) {
          _inline(child, linkStyle, children, recognizer: linkRecognizer);
        }
        out.add(TextSpan(style: linkStyle, children: children));
      default:
        final next = _styled(node, style);
        final children = <InlineSpan>[];
        for (final child in node.nodes) {
          _inline(child, next, children, recognizer: recognizer);
        }
        out.add(TextSpan(style: next, children: children));
    }
  }

  /// Collapses whitespace unless an ancestor is `<pre>` or `white-space: pre*`.
  String _collapse(dom.Text node) {
    var keepAll = false;
    var keepBreaks = false;
    for (dom.Element? e = node.parent; e != null; e = e.parent) {
      var mode = e.localName == 'pre' ? 'pre' : null;
      for (final declaration in (e.attributes['style'] ?? '').split(';')) {
        final index = declaration.indexOf(':');
        if (index > 0 &&
            declaration.substring(0, index).trim().toLowerCase() ==
                'white-space') {
          mode = declaration.substring(index + 1).trim().toLowerCase();
        }
      }
      if (mode == null) continue;
      keepAll = mode == 'pre' || mode == 'pre-wrap' || mode == 'break-spaces';
      keepBreaks = mode == 'pre-line';
      break;
    }
    if (keepAll) return node.text;
    if (keepBreaks) return node.text.replaceAll(RegExp(r'[ \t\r\f]+'), ' ');
    return node.text.replaceAll(RegExp(r'\s+'), ' ');
  }

  InlineSpan _image(dom.Element img, TapGestureRecognizer? recognizer) {
    final src = img.attributes['src'] ?? '';
    final width = double.tryParse(img.attributes['width'] ?? '');
    final height = double.tryParse(img.attributes['height'] ?? '');
    Widget? image;

    if (src.startsWith('data:image/')) {
      final comma = src.indexOf(',');
      try {
        final bytes = base64.decode(
          src.substring(comma + 1).replaceAll(RegExp(r'\s'), ''),
        );
        image = Image.memory(bytes, width: width, height: height);
      } on FormatException {
        image = null;
      }
    } else if (src.startsWith('http://') || src.startsWith('https://')) {
      image = Image.network(
        src,
        width: width,
        height: height,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    if (image == null) return const TextSpan();
    final onTap = recognizer?.onTap;
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: onTap == null
            ? image
            : MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(onTap: onTap, child: image),
              ),
      ),
    );
  }

  TextStyle _styled(dom.Element el, TextStyle parent) {
    var style = parent;
    switch (el.localName) {
      case 'b':
      case 'strong':
      case 'th':
        style = style.copyWith(fontWeight: FontWeight.bold);
      case 'i':
      case 'em':
        style = style.copyWith(fontStyle: FontStyle.italic);
      case 'u':
        style = style.copyWith(decoration: TextDecoration.underline);
      case 's':
      case 'strike':
        style = style.copyWith(decoration: TextDecoration.lineThrough);
      case 'small':
        style = style.copyWith(fontSize: (style.fontSize ?? 15) * 0.85);
      case 'big':
        style = style.copyWith(fontSize: (style.fontSize ?? 15) * 1.2);
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final scale = const {
          'h1': 1.8,
          'h2': 1.5,
          'h3': 1.3,
          'h4': 1.15,
          'h5': 1.0,
          'h6': 0.9,
        }[el.localName]!;
        style = style.copyWith(
          fontSize: 15 * scale,
          fontWeight: FontWeight.bold,
        );
      case 'pre':
      case 'code':
        style = style.copyWith(fontFamily: 'monospace');
      case 'font':
        final color = _color(el.attributes['color']);
        if (color != null) style = style.copyWith(color: color);
    }

    for (final declaration in (el.attributes['style'] ?? '').split(';')) {
      final index = declaration.indexOf(':');
      if (index < 0) continue;
      final prop = declaration.substring(0, index).trim().toLowerCase();
      final value = declaration.substring(index + 1).trim().toLowerCase();
      switch (prop) {
        case 'color':
          final color = _color(value);
          if (color != null) style = style.copyWith(color: color);
        case 'background-color':
          final color = _color(value);
          if (color != null) style = style.copyWith(backgroundColor: color);
        case 'font-weight':
          final bold =
              value == 'bold' ||
              value == 'bolder' ||
              (int.tryParse(value) ?? 0) >= 600;
          style = style.copyWith(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          );
        case 'font-style':
          if (value == 'italic') {
            style = style.copyWith(fontStyle: FontStyle.italic);
          }
        case 'text-decoration':
          if (value.contains('underline')) {
            style = style.copyWith(decoration: TextDecoration.underline);
          } else if (value.contains('line-through')) {
            style = style.copyWith(decoration: TextDecoration.lineThrough);
          }
        case 'font-size':
          final px = double.tryParse(value.replaceAll('px', ''));
          if (px != null && px >= 8 && px <= 48) {
            style = style.copyWith(fontSize: px);
          }
      }
    }
    return style;
  }

  TextAlign? _align(dom.Element el) {
    var value = el.attributes['align']?.toLowerCase();
    if (el.localName == 'center') value = 'center';
    for (final declaration in (el.attributes['style'] ?? '').split(';')) {
      final parts = declaration.split(':');
      if (parts.length == 2 && parts[0].trim().toLowerCase() == 'text-align') {
        value = parts[1].trim().toLowerCase();
      }
    }
    return switch (value) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'left' => TextAlign.left,
      _ => null,
    };
  }
}

Uri? _safeLink(String? value) {
  final uri = Uri.tryParse((value ?? '').trim());
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'mailto') return uri.path.isEmpty ? null : uri;
  if ((scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty) {
    return uri;
  }
  return null;
}

Color? _color(String? value) {
  if (value == null) return null;
  final v = value.trim().toLowerCase();
  const names = {
    'black': Colors.black,
    'white': Colors.white,
    'red': Colors.red,
    'green': Colors.green,
    'blue': Colors.blue,
    'gray': Colors.grey,
    'grey': Colors.grey,
    'orange': Colors.orange,
    'yellow': Colors.yellow,
    'purple': Colors.purple,
    'navy': Color(0xFF000080),
  };
  if (names.containsKey(v)) return names[v];
  final hex = RegExp(r'^#([0-9a-f]{3}|[0-9a-f]{6})$').firstMatch(v)?.group(1);
  if (hex != null) {
    final full = hex.length == 3 ? hex.split('').map((c) => c + c).join() : hex;
    return Color(0xFF000000 | int.parse(full, radix: 16));
  }
  final rgb = RegExp(
    r'^rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$',
  ).firstMatch(v);
  if (rgb != null) {
    // Oversized digit runs overflow int.parse on native; treat them as max.
    int c(int i) => (int.tryParse(rgb.group(i)!) ?? 255).clamp(0, 255);
    return Color.fromARGB(255, c(1), c(2), c(3));
  }
  return null;
}
