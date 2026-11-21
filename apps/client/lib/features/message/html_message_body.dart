import 'dart:math' as math;

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
    if (_countElements(body) > maxHtmlElements) {
      // Same order as the server budget; avoids building a huge widget tree.
      _content = Text(body.text ?? '');
      return;
    }
    final linkColor = Theme.of(context).colorScheme.primary;
    final renderer = _Renderer(
      linkColor: linkColor,
      onLink: (uri) => (widget.linkLauncher ?? launchMessageLink)(uri),
      recognizers: _recognizers,
    );
    const base = TextStyle(color: Colors.black87, fontSize: 15, height: 1.45);
    _content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: renderer.children(body.nodes, base, Colors.white),
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

/// Above this many elements the body is shown as plain text.
const maxHtmlElements = 5000;

/// Largest colspan/rowspan honored, and rows x columns budget per table.
const maxHtmlSpan = 50;
const maxHtmlTableSlots = 10000;

int _countElements(dom.Node root) {
  var count = 0;
  final stack = <dom.Node>[root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    if (node is dom.Element) count++;
    if (count > maxHtmlElements) break;
    stack.addAll(node.nodes);
  }
  return count;
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

  /// [bg] is the background actually painted behind the content: the nearest
  /// widget/decoration color passed down, overridden for text by an inline
  /// `TextStyle.backgroundColor`.
  List<Widget> children(
    List<dom.Node> nodes,
    TextStyle style,
    Color bg, {
    TextAlign align = TextAlign.start,
    TapGestureRecognizer? recognizer,
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
      if (node is dom.Element && node.localName == 'a' && _hasBlock(node)) {
        // Keep block structure inside a link and hand the tap down to it.
        flush();
        final (linkStyle, linkRecognizer) = _link(node, style);
        widgets.addAll(
          children(
            node.nodes,
            linkStyle,
            bg,
            align: align,
            recognizer: linkRecognizer,
          ),
        );
      } else if (node is dom.Element && _blockTags.contains(node.localName)) {
        flush();
        widgets.add(_block(node, style, bg, recognizer));
      } else {
        _inline(node, style, bg, spans, recognizer: recognizer);
      }
    }
    flush();
    return widgets;
  }

  bool _hasBlock(dom.Element el) =>
      el.nodes.any((c) => c is dom.Element && _blockTags.contains(c.localName));

  (TextStyle, TapGestureRecognizer?) _link(dom.Element a, TextStyle style) {
    // The anchor background is painted as a text background.
    final anchorBg = _background(a);
    if (anchorBg != null) style = style.copyWith(backgroundColor: anchorBg);
    final uri = _safeLink(a.attributes['href']);
    if (uri == null) return (style, null);
    final recognizer = TapGestureRecognizer()..onTap = () => onLink(uri);
    recognizers.add(recognizer);
    return (
      style.copyWith(
        color: linkColor,
        decoration: TextDecoration.underline,
        decorationColor: linkColor,
      ),
      recognizer,
    );
  }

  /// Every block path paints its own element's background (never inherited).
  Widget _paint(dom.Element el, Widget child) {
    final color = _background(el);
    return color == null ? child : ColoredBox(color: color, child: child);
  }

  Widget _block(
    dom.Element el,
    TextStyle parent,
    Color outer,
    TapGestureRecognizer? recognizer,
  ) {
    final style = _styled(el, parent);
    final bg = _background(el) ?? outer;
    final align = _align(el) ?? TextAlign.start;
    final tag = el.localName;

    switch (tag) {
      case 'hr':
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1),
        );
      case 'table':
        final caption = el.children.where((c) => c.localName == 'caption');
        final table = _table(el, style, outer, recognizer);
        if (caption.isEmpty) return table;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in caption)
              _paint(
                c,
                _column(
                  c,
                  _styled(c, style),
                  _background(c) ?? outer,
                  _align(c) ?? TextAlign.center,
                  recognizer,
                ),
              ),
            table,
          ],
        );
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
                  child: Text(
                    tag == 'ol' ? '$index.' : '•',
                    style: _fix(style, bg),
                  ),
                ),
                Expanded(
                  child: _paint(
                    child,
                    _column(
                      child,
                      _styled(child, style),
                      _background(child) ?? bg,
                      align,
                      recognizer,
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return _paint(
          el,
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: items,
            ),
          ),
        );
      case 'blockquote':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            color: _background(el),
            border: const Border(
              left: BorderSide(color: Colors.black26, width: 3),
            ),
          ),
          child: _column(el, style, bg, align, recognizer),
        );
      default:
        final spacing =
            (tag == 'p' || (tag?.startsWith('h') ?? false)) ? 6.0 : 0.0;
        return _paint(
          el,
          Padding(
            padding: EdgeInsets.symmetric(vertical: spacing),
            child: _column(el, style, bg, align, recognizer),
          ),
        );
    }
  }

  Widget _column(
    dom.Element el,
    TextStyle style,
    Color bg,
    TextAlign align,
    TapGestureRecognizer? recognizer,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children(
        el.nodes,
        style,
        bg,
        align: align,
        recognizer: recognizer,
      ),
    );
  }

  Widget _table(
    dom.Element table,
    TextStyle style,
    Color outer,
    TapGestureRecognizer? recognizer,
  ) {
    final tableBg = _background(table) ?? outer;
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
    // Every row builds `columns` children, so spans can blow up the count
    // even when the element count is small.
    if (rows.length * columns > maxHtmlTableSlots) {
      return Text(table.text, style: style);
    }

    Color? cellBg(dom.Element cell, dom.Element row) =>
        _background(cell) ?? _background(row) ?? _groupBackground(row);

    TableRow toRow(Map<int, (dom.Element cell, dom.Element row)> slots) =>
        TableRow(
          children: [
            for (var i = 0; i < columns; i++)
              if (slots[i] case (final cell, final row))
                ColoredBox(
                  color: cellBg(cell, row) ?? Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: _column(
                      cell,
                      _cellStyle(cell, row, style),
                      cellBg(cell, row) ?? tableBg,
                      _align(cell) ?? _align(row) ?? TextAlign.start,
                      recognizer,
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

  static const _rowGroups = {'tbody', 'thead', 'tfoot'};

  dom.Element? _group(dom.Element row) {
    final parent = row.parent;
    return parent != null && _rowGroups.contains(parent.localName)
        ? parent
        : null;
  }

  Color? _groupBackground(dom.Element row) {
    final group = _group(row);
    return group == null ? null : _background(group);
  }

  /// Merges styles along table -> row group -> tr -> td/th.
  TextStyle _cellStyle(dom.Element cell, dom.Element row, TextStyle table) {
    final group = _group(row);
    final inherited = _styled(
      row,
      group == null ? table : _styled(group, table),
    );
    final style = _styled(cell, inherited);
    return cell.localName == 'th'
        ? style.copyWith(fontWeight: FontWeight.bold)
        : style;
  }

  /// Final step for every text style: text that would be unreadable on [bg]
  /// (contrast < 3:1) falls back to black87 or white, whichever contrasts
  /// better. Corrects the underline color too, so links stay visible.
  TextStyle _fix(TextStyle style, Color bg) {
    final under = style.backgroundColor ?? bg;
    final color = style.color ?? Colors.black87;
    final fixed = readableTextColor(color, under);
    final line = style.decorationColor;
    final fixedLine = line == null ? null : readableTextColor(line, under);
    return fixed == color && fixedLine == line
        ? style
        : style.copyWith(color: fixed, decorationColor: fixedLine);
  }

  /// Leaf text style: only color and underline color, the rest is inherited.
  TextStyle _leaf(TextStyle composed, Color bg) {
    final f = _fix(composed, bg);
    return TextStyle(color: f.color, decorationColor: f.decorationColor);
  }

  int _span(dom.Element cell, String attribute) =>
      (int.tryParse(cell.attributes[attribute] ?? '') ?? 1).clamp(
        1,
        maxHtmlSpan,
      );

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
    Color bg,
    List<InlineSpan> out, {
    TapGestureRecognizer? recognizer,
  }) {
    if (node is dom.Text) {
      final text = _collapse(node);
      if (text.isNotEmpty && recognizer == null) {
        // Bare URLs outside an anchor stay tappable, as in the plain-text view.
        for (final segment in parseMessageBody(body: text, links: const [])) {
          final uri = segment.uri;
          if (uri == null) {
            out.add(TextSpan(text: segment.text, style: _leaf(style, bg)));
            continue;
          }
          final tap = TapGestureRecognizer()..onTap = () => onLink(uri);
          recognizers.add(tap);
          out.add(
            TextSpan(
              text: segment.text,
              recognizer: tap,
              mouseCursor: SystemMouseCursors.click,
              style: _fix(
                style.copyWith(
                  color: linkColor,
                  decoration: TextDecoration.underline,
                  decorationColor: linkColor,
                ),
                bg,
              ),
            ),
          );
        }
      } else if (text.isNotEmpty) {
        // Recognizers only fire on the innermost span, so every text leaf of
        // a link carries its own.
        out.add(
          TextSpan(
            text: text,
            style: _leaf(style, bg),
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
        final (linkStyle, linkRecognizer) = _link(node, style);
        if (_hasBlock(node)) {
          // Nested inside other inline content: blocks inside a link keep their structure in a nested column.
          out.add(
            WidgetSpan(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children(
                  node.nodes,
                  linkStyle,
                  bg,
                  recognizer: linkRecognizer,
                ),
              ),
            ),
          );
          return;
        }
        final spans = <InlineSpan>[];
        for (final child in node.nodes) {
          _inline(child, linkStyle, bg, spans, recognizer: linkRecognizer);
        }
        out.add(TextSpan(style: linkStyle, children: spans));
      default:
        final next = _styled(node, style);
        final children = <InlineSpan>[];
        for (final child in node.nodes) {
          _inline(child, next, bg, children, recognizer: recognizer);
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
    final width = _imageSize(img.attributes['width']);
    final height = _imageSize(img.attributes['height']);
    Widget? image;

    // data: URIs are never decoded: a tiny PNG can claim a huge pixel size.
    if (src.startsWith('http://') || src.startsWith('https://')) {
      image = Image.network(
        src,
        width: width,
        height: height,
        // Caps decoded size (2x the 600px max layout width); keeps aspect ratio.
        cacheWidth: 1200,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    if (image == null) return TextSpan(text: img.attributes['alt'] ?? '');
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

  bool _paintsOwnBackground(dom.Element el) =>
      _blockTags.contains(el.localName) ||
      const {
        'tr',
        'td',
        'th',
        'tbody',
        'thead',
        'tfoot',
      }.contains(el.localName);

  /// Finite positive size, capped; anything else (NaN, Infinity, 0, negative,
  /// percentages) is ignored.
  double? _imageSize(String? raw) {
    final n = double.tryParse((raw ?? '').trim().replaceAll('px', ''));
    return n != null && n.isFinite && n > 0
        ? n.clamp(1, 2000).toDouble()
        : null;
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
          // Blocks paint their own box (_background); text background would be
          // inherited by children that set a different box color.
          if (color != null && !_paintsOwnBackground(el)) {
            style = style.copyWith(backgroundColor: color);
          }
        case 'font-weight':
          final bold = value == 'bold' ||
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

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

@visibleForTesting
Color readableTextColor(Color text, Color background) {
  if (_contrast(text, background) >= 3) return text;
  return _contrast(Colors.black87, background) >=
          _contrast(Colors.white, background)
      ? Colors.black87
      : Colors.white;
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
