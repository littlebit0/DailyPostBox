import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/message/html_message_body.dart';
import 'package:daily_postbox/features/message/linked_message_body.dart';
import 'package:daily_postbox/features/message/message_page.dart';
import 'package:daily_postbox/services/mail_api_client.dart';

MessageDetail _detail({required String html, int blocked = 0}) {
  return MessageDetail(
    id: 'm1',
    sender: 's@example.com',
    subject: 'subject',
    body: 'plain fallback',
    links: const [],
    receivedAtLabel: '',
    html: html,
    remoteImageCount: blocked,
  );
}

void main() {
  testWidgets('renders formatted html, tables and makes no image widgets', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HtmlMessageBody(
            html:
                '<h1>Receipt</h1><p>Hello <b>bold</b></p>'
                '<table><tr><td>Item</td><td>1,000</td></tr></table>'
                '<ul><li>one</li></ul>',
          ),
        ),
      ),
    );

    expect(find.textContaining('Receipt', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('Hello bold', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Item'), findsOneWidget);
    expect(find.text('1,000'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('opens http links but ignores unsafe schemes', (tester) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HtmlMessageBody(
            html:
                '<a href="javascript:alert(1)">bad</a> '
                '<a href="https://example.com/x">good</a>',
            linkLauncher: (uri) async {
              opened = uri;
              return true;
            },
          ),
        ),
      ),
    );

    // The rich text is "bad good": the second word starts after "bad " (4 Ahem glyphs, 60px).
    final rect = tester.getRect(
      find.textContaining('good', findRichText: true),
    );
    await tester.tapAt(rect.centerLeft + const Offset(90, 0));
    await tester.pump();
    expect(opened, Uri.parse('https://example.com/x'));
  });

  testWidgets('shows blocked count and loads images only after tapping', (
    tester,
  ) async {
    final requests = <bool>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageProvider.overrideWith((ref, request) async {
            requests.add(request.remoteImages);
            return request.remoteImages
                ? _detail(html: '<p>Hi</p>')
                : _detail(html: '<p>Hi</p>', blocked: 2);
          }),
        ],
        child: const MaterialApp(home: MessagePage(messageId: 'm1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('원격 이미지 2개 차단됨'), findsOneWidget);
    expect(requests, [false]);
    expect(find.text('plain fallback'), findsNothing);

    await tester.tap(find.text('이번만 보기'));
    await tester.pumpAndSettle();

    expect(requests, [false, true]);
    expect(find.text('원격 이미지 2개 차단됨'), findsNothing);
  });

  testWidgets('falls back to plain text when there is no html', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageProvider.overrideWith(
            (ref, request) async => _detail(html: ''),
          ),
        ],
        child: const MaterialApp(home: MessagePage(messageId: 'm1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('plain fallback', findRichText: true),
      findsOneWidget,
    );
    expect(find.byType(HtmlMessageBody), findsNothing);
  });

  Future<void> pump(
    WidgetTester tester,
    String html, {
    MessageLinkLauncher? launcher,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HtmlMessageBody(html: html, linkLauncher: launcher),
          ),
        ),
      ),
    );
  }

  testWidgets('image inside a link opens the link when tapped', (tester) async {
    Uri? opened;
    await pump(
      tester,
      '<a href="https://example.com/go">'
      '<img src="https://img.example/a.png" width="40" height="40"></a>',
      launcher: (uri) async {
        opened = uri;
        return true;
      },
    );
    await tester.tap(find.byType(Image));
    expect(opened, Uri.parse('https://example.com/go'));
  });

  testWidgets('data uri image is not decoded, alt text is shown', (
    tester,
  ) async {
    await pump(
      tester,
      '<p><img src="data:image/png;base64,iVBORw0KGgo=" alt="pic"></p>',
    );
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('pic', findRichText: true), findsOneWidget);
  });

  testWidgets('pre keeps line breaks and spacing, normal text collapses', (
    tester,
  ) async {
    await pump(tester, '<pre>a  b\nc</pre><p>x  \n y</p>');
    expect(find.text('a  b\nc', findRichText: true), findsOneWidget);
    expect(find.text('x y', findRichText: true), findsOneWidget);

    await pump(tester, '<div style="white-space: pre">d  e\nf</div>');
    expect(find.text('d  e\nf', findRichText: true), findsOneWidget);
  });

  testWidgets('table and cell bgcolor are painted', (tester) async {
    await pump(
      tester,
      '<table bgcolor="#000000"><tr><td bgcolor="#ff0000">'
      '<font color="#ffffff">Your code: 1234</font></td>'
      '<td style="background-color:#00ff00">ok</td></tr></table>',
    );
    final colors = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .map((b) => b.color)
        .toSet();
    expect(
      colors,
      containsAll(const [
        Color(0xFF000000),
        Color(0xFFFF0000),
        Color(0xFF00FF00),
      ]),
    );
  });

  testWidgets('oversized rgb() does not throw', (tester) async {
    await pump(
      tester,
      '<p style="color:rgb(999999999999999999999999999999,0,0)">still shown</p>',
    );
    expect(tester.takeException(), isNull);
    expect(find.text('still shown', findRichText: true), findsOneWidget);
  });

  testWidgets('rowspan reserves its column in following rows', (tester) async {
    await pump(
      tester,
      '<table><tr><td rowspan="2">Item</td><td>10</td></tr>'
      '<tr><td>20</td></tr></table>',
    );
    final item = tester.getTopLeft(find.text('Item', findRichText: true)).dx;
    final ten = tester.getTopLeft(find.text('10', findRichText: true)).dx;
    final twenty = tester.getTopLeft(find.text('20', findRichText: true)).dx;
    expect(twenty, greaterThan(item));
    expect(twenty, ten);
  });

  testWidgets('colspan cell spans the merged width', (tester) async {
    await pump(
      tester,
      '<table><tr><td colspan="2">title</td></tr>'
      '<tr><td>a</td><td>b</td></tr></table>',
    );
    double width(String text) => tester
        .getSize(
          find
              .ancestor(
                of: find.text(text, findRichText: true),
                matching: find.byType(Row),
              )
              .first,
        )
        .width;
    final title = tester
        .getSize(
          find
              .ancestor(
                of: find.text('title', findRichText: true),
                matching: find.byType(ColoredBox),
              )
              .first,
        )
        .width;
    expect(title, closeTo(width('a'), 1));
    expect(
      tester.getTopLeft(find.text('b', findRichText: true)).dx,
      greaterThan(tester.getTopLeft(find.text('a', findRichText: true)).dx),
    );
  });

  testWidgets('failed image inside a link shows alt and stays tappable', (
    tester,
  ) async {
    Uri? opened;
    await pump(
      tester,
      '<a href="https://example.com/verify">'
      '<img src="https://cdn.example.com/missing.png" alt="인증하기"></a>',
      launcher: (uri) async {
        opened = uri;
        return true;
      },
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('인증하기'), findsOneWidget);
    await tester.tap(find.text('인증하기'));
    expect(opened, Uri.parse('https://example.com/verify'));
  });

  testWidgets('row text style is inherited by cells', (tester) async {
    await pump(
      tester,
      '<table><tr style="color:#ffffff;background-color:#000000">'
      '<td>code 1234</td></tr></table>',
    );
    final text = tester.widget<RichText>(
      find.text('code 1234', findRichText: true),
    );
    final span = (text.text as TextSpan).children!.first as TextSpan;
    expect(span.style?.color, const Color(0xFFFFFFFF));
  });

  testWidgets('blocks inside a link stay separate and tappable', (
    tester,
  ) async {
    Uri? opened;
    await pump(
      tester,
      '<a href="https://example.com/x"><p>first</p><p>second</p></a>',
      launcher: (uri) async {
        opened = uri;
        return true;
      },
    );
    final first = find.text('first', findRichText: true);
    final second = find.text('second', findRichText: true);
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(
      tester.getTopLeft(second).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
    await tester.tapAt(tester.getTopLeft(second) + const Offset(10, 10));
    await tester.pump();
    expect(opened, Uri.parse('https://example.com/x'));
  });

  testWidgets('huge element counts fall back to plain text', (tester) async {
    await pump(tester, '<div>x</div>' * (maxHtmlElements + 1));
    expect(tester.takeException(), isNull);
    expect(find.byType(Column), findsNothing);
    expect(find.textContaining('xxx', findRichText: true), findsOneWidget);

    await pump(tester, '<div>x</div>' * 10);
    expect(find.byType(Column), findsWidgets);
  });

  testWidgets('wide colspan tables over the slot budget fall back to text', (
    tester,
  ) async {
    final html =
        '<table><tr>${'<td colspan="20">a</td>' * 1000}</tr>'
        '${'<tr><td>b</td></tr>' * 1000}</table>';
    await pump(tester, html);
    expect(tester.takeException(), isNull);
    expect(find.byType(Table), findsNothing);
    expect(tester.allWidgets.length, lessThan(1000));

    await pump(tester, '<table><tr><td colspan="2">a</td></tr></table>');
    expect(find.byType(Expanded), findsOneWidget);
  });

  testWidgets('column count includes the last cell colspan', (tester) async {
    await pump(
      tester,
      '<table><tr><td>a</td><td colspan="2">b</td></tr>'
      '<tr><td>c</td></tr></table>',
    );
    double cellWidth(String text) => tester
        .getSize(
          find
              .ancestor(
                of: find.text(text, findRichText: true),
                matching: find.byType(Expanded),
              )
              .first,
        )
        .width;
    expect(cellWidth('a'), closeTo(cellWidth('c'), 1));
    expect(cellWidth('a') * 3, closeTo(cellWidth('a') + cellWidth('b'), 1));
  });

  testWidgets('bare URLs outside anchors are tappable', (tester) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HtmlMessageBody(
            html: '<p>https://example.com/reset?token=abc</p>',
            linkLauncher: (uri) async {
              opened = uri;
              return true;
            },
          ),
        ),
      ),
    );
    final link = find.textContaining('example.com', findRichText: true);
    await tester.tapAt(tester.getTopLeft(link) + const Offset(10, 10));
    await tester.pump();
    expect(opened, Uri.parse('https://example.com/reset?token=abc'));
  });

  Future<List<Uri>> tapAll(
    WidgetTester tester,
    String html,
    List<String> parts,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HtmlMessageBody(
            html: html,
            linkLauncher: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    for (final part in parts) {
      final finder = find.textContaining(part, findRichText: true);
      await tester.tapAt(tester.getTopLeft(finder) + const Offset(2, 8));
      await tester.pump();
    }
    return opened;
  }

  testWidgets('bare URL split across styled children is one link', (
    tester,
  ) async {
    final opened = await tapAll(
      tester,
      '<p>https://example.com/<span>reset?token=abc</span></p>',
      ['https://example.com/'],
    );
    expect(opened, [Uri.parse('https://example.com/reset?token=abc')]);
  });

  testWidgets('two bare URLs in one paragraph stay separate', (tester) async {
    final opened = await tapAll(
      tester,
      '<p>https://a.example/x <b>and</b> https://b.example/y</p>',
      ['https://a.example/x'],
    );
    expect(opened, [Uri.parse('https://a.example/x')]);
  });

  testWidgets('table caption is rendered above the table', (tester) async {
    await pump(
      tester,
      '<table><caption>November bill</caption><tr><td>10,000</td></tr></table>',
    );
    final caption = find.text('November bill', findRichText: true);
    expect(caption, findsOneWidget);
    expect(
      tester.getTopLeft(caption).dy,
      lessThan(tester.getTopLeft(find.byType(Table)).dy),
    );
  });

  testWidgets('div background color is painted', (tester) async {
    await pump(
      tester,
      '<div style="background-color:#000000"><font color="#ffffff">x</font></div>',
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == const Color(0xFF000000),
      ),
      findsOneWidget,
    );
  });

  testWidgets('div text color is inherited by children', (tester) async {
    await pump(
      tester,
      '<div style="background-color:#000000;color:#ffffff"><p>code 1234</p></div>',
    );
    final text = tester.widget<RichText>(
      find.text('code 1234', findRichText: true),
    );
    final span = (text.text as TextSpan).children!.first as TextSpan;
    expect(span.style?.color, const Color(0xFFFFFFFF));
  });

  testWidgets('blockquote, list and caption paint their own background', (
    tester,
  ) async {
    await pump(
      tester,
      '<blockquote style="background-color:#000001;color:#fff">a</blockquote>'
      '<ul style="background-color:#000002"><li style="background-color:#000003">b</li></ul>'
      '<table><caption style="background-color:#000004">c</caption>'
      '<tr><td>d</td></tr></table>',
    );
    bool painted(int rgb) => find
        .byWidgetPredicate(
          (w) =>
              (w is ColoredBox && w.color == Color(0xFF000000 | rgb)) ||
              (w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).color ==
                      Color(0xFF000000 | rgb)),
        )
        .evaluate()
        .isNotEmpty;
    for (final rgb in [1, 2, 3, 4]) {
      expect(painted(rgb), isTrue, reason: 'bg #00000$rgb');
    }
  });

  testWidgets('block background is not inherited as text background', (
    tester,
  ) async {
    await pump(
      tester,
      '<div style="background-color:#000000;color:#ffffff"><table><tr>'
      '<td bgcolor="#ffffff" style="color:#000000">code 1234</td></tr></table></div>',
    );
    final text = tester.widget<RichText>(
      find.text('code 1234', findRichText: true),
    );
    final span = (text.text as TextSpan).children!.first as TextSpan;
    expect(span.style?.backgroundColor, isNull);
  });

  testWidgets('inline span background still applies to text', (tester) async {
    await pump(tester, '<span style="background-color:#ffff00">hi</span>');
    final text = tester.widget<RichText>(find.text('hi', findRichText: true));
    expect(text.text.toStringDeep(), contains('backgroundColor'));
  });

  testWidgets('invalid image height does not break layout', (tester) async {
    await pump(
      tester,
      '<img src="https://example.com/a.png" height="Infinity" width="-5">',
    );
    expect(tester.takeException(), isNull);
  });

  Color? textColor(WidgetTester tester, String text) {
    final rich = tester.widget<RichText>(find.text(text, findRichText: true));
    Color? color = rich.text.style?.color;
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.toPlainText() == text) {
        color = span.style?.color ?? color;
      }
      return true;
    });
    return color;
  }

  testWidgets('row group text color reaches cells', (tester) async {
    await pump(
      tester,
      '<table bgcolor="#000000"><tbody style="color:#ffffff"><tr>'
      '<td>code 1234</td></tr></tbody></table>',
    );
    expect(textColor(tester, 'code 1234'), Colors.white);
  });

  testWidgets('row group background is painted', (tester) async {
    await pump(
      tester,
      '<table><thead style="background-color:#000001"><tr>'
      '<th>head</th></tr></thead></table>',
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == const Color(0xFF000001),
      ),
      findsOneWidget,
    );
  });

  testWidgets('white text on white falls back to dark text', (tester) async {
    await pump(tester, '<p style="color:#ffffff">invisible</p>');
    expect(textColor(tester, 'invisible'), Colors.black87);
  });

  testWidgets('black text on black falls back to white text', (tester) async {
    await pump(
      tester,
      '<div style="background-color:#000000"><p style="color:#000000">dark</p></div>',
    );
    expect(textColor(tester, 'dark'), Colors.white);
  });

  testWidgets('readable text keeps its color', (tester) async {
    await pump(
      tester,
      '<div style="background-color:#000000"><p style="color:#ffffff">ok</p></div>',
    );
    expect(textColor(tester, 'ok'), Colors.white);
  });

  List<TextSpan> allSpans(WidgetTester tester) {
    final out = <TextSpan>[];
    void walk(InlineSpan span) {
      if (span is! TextSpan) return;
      out.add(span);
      span.children?.forEach(walk);
    }

    walk(tester.widget<RichText>(find.byType(RichText).first).text);
    return out;
  }

  TextStyle? leafStyle(WidgetTester tester, String text) =>
      allSpans(tester).lastWhere((s) => s.text == text).style;

  testWidgets('auto-detected url keeps contrast against its background', (
    tester,
  ) async {
    final primary = ThemeData().colorScheme.primary;
    final hex = primary.toARGB32().toRadixString(16).substring(2);
    await pump(
      tester,
      '<div style="background-color:#$hex"><p>https://example.com/a</p></div>',
    );
    final style = allSpans(
      tester,
    ).firstWhere((s) => s.recognizer != null).style!;
    expect(style.color, isNot(primary));
    expect(style.decorationColor, isNot(primary));
    expect(style.decoration, TextDecoration.underline);
  });

  testWidgets('anchor background is painted and used for contrast', (
    tester,
  ) async {
    await pump(
      tester,
      '<a href="https://example.com" style="background-color:#000000">'
      '<font color="#ffffff">verify</font></a>'
      '<a href="https://example.com" style="background-color:#000000">'
      '<font color="#000000">dark</font></a>',
    );
    expect(
      allSpans(tester).map((s) => s.style?.backgroundColor),
      contains(const Color(0xFF000000)),
    );
    expect(leafStyle(tester, 'verify')!.color, Colors.white);
    expect(leafStyle(tester, 'dark')!.color, Colors.white);
  });

  testWidgets('unpainted ancestor background causes no correction', (
    tester,
  ) async {
    await pump(
      tester,
      '<span bgcolor="#000000"><font color="#000000">plain</font></span>',
    );
    expect(leafStyle(tester, 'plain')!.color, const Color(0xFF000000));
  });

  testWidgets('huge style attribute on an ancestor renders quickly', (
    tester,
  ) async {
    final html =
        '<div style="${'color:red;' * 180000}">${'<i>x</i>' * 4999}</div>';
    final watch = Stopwatch()..start();
    await pump(tester, html);
    expect(watch.elapsedMilliseconds, lessThan(5000));
    expect(find.byType(HtmlMessageBody), findsOneWidget);
  });

  testWidgets('style declarations beyond the cap are ignored', (tester) async {
    await pump(
      tester,
      '<p style="${'x:1;' * 32}color:#ff0000">late</p><p style="color:#ff0000">ok</p>',
    );
    expect(textColor(tester, 'late'), isNot(const Color(0xFFFF0000)));
    expect(textColor(tester, 'ok'), const Color(0xFFFF0000));
  });

  testWidgets('work over budget falls back to plain text', (tester) async {
    final html = '<p style="${'color:#333;' * 32}">x</p>' * 4000;
    await pump(tester, html);
    expect(find.text('x' * 4000), findsOneWidget);
  });

  testWidgets('table slots count toward the whole-body work budget', (
    tester,
  ) async {
    final table =
        '<table><tr>${'<td>a</td>' * 99}</tr>'
        '${'<tr><td>b</td></tr>' * 99}</table>';
    await pump(tester, table);
    expect(find.byType(Table), findsOneWidget);
    await pump(tester, table * 12);
    expect(find.byType(Table), findsNothing);
    expect(find.byType(HtmlMessageBody), findsOneWidget);
  });

  testWidgets('plain text fallback keeps readable color in dark theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: HtmlMessageBody(
            html: '<p style="${'color:#333;' * 32}">x</p>' * 4000,
          ),
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.text('x' * 4000)).style?.color,
      Colors.black87,
    );
  });

  testWidgets('oversized table fallback corrects text against outer bg', (
    tester,
  ) async {
    final html =
        '<table style="background-color:#000000;color:#ffffff">'
        '<tr>${'<td colspan="20">a</td>' * 1000}</tr>'
        '${'<tr><td>b</td></tr>' * 1000}</table>';
    await pump(tester, html);
    expect(find.byType(Table), findsNothing);
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.style?.color, Colors.black87);
  });

  testWidgets('image alt text keeps contrast against its background', (
    tester,
  ) async {
    await pump(
      tester,
      '<p style="color:#ffffff"><img alt="altx" src="cid:1"></p>',
    );
    expect(textColor(tester, 'altx'), Colors.black87);
  });

  testWidgets('image scheme check ignores case', (tester) async {
    await pump(tester, '<img src="HTTPS://cdn.example.com/a.png">');
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('remote images are capped per message', (tester) async {
    final imgs = List.generate(
      maxHtmlImages + 5,
      (i) => '<img alt="a$i" src="https://cdn.example.com/$i.png">',
    ).join();
    await pump(tester, '<p>$imgs</p>');
    expect(find.byType(Image), findsNWidgets(maxHtmlImages));
    expect(find.textContaining('a${maxHtmlImages + 4}'), findsOneWidget);
  });

  testWidgets('linked image beyond the count cap stays tappable', (
    tester,
  ) async {
    Uri? opened;
    final imgs = List.generate(
      maxHtmlImages + 1,
      (i) =>
          '<a href="https://example.com/l$i">'
          '<img alt="a$i" src="https://cdn.example.com/$i.png"></a>',
    ).join();
    await pump(
      tester,
      imgs,
      launcher: (uri) async {
        opened = uri;
        return true;
      },
    );
    final last = find.textContaining('a$maxHtmlImages', findRichText: true);
    await tester.ensureVisible(last);
    // The paragraph is full width; tap inside its first characters.
    await tester.tapAt(tester.getTopLeft(last) + const Offset(5, 5));
    expect(opened, Uri.parse('https://example.com/l$maxHtmlImages'));
  });

  testWidgets('remote image decode is bounded in both dimensions', (
    tester,
  ) async {
    await pump(tester, '<img src="https://cdn.example.com/tall.png">');
    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(provider, isA<ResizeImage>());
    final resize = provider as ResizeImage;
    expect(resize.width, isNotNull);
    expect(resize.height, isNotNull);
    expect(resize.policy, ResizeImagePolicy.fit);
  });

  test('readableTextColor keeps contrasting colors', () {
    expect(readableTextColor(Colors.black87, Colors.white), Colors.black87);
    expect(readableTextColor(Colors.white, Colors.white), Colors.black87);
    expect(readableTextColor(Colors.black, Colors.black), Colors.white);
  });
}
