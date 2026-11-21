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
            html: '<h1>Receipt</h1><p>Hello <b>bold</b></p>'
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
            html: '<a href="javascript:alert(1)">bad</a> '
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

  testWidgets('data uri image is not decoded, alt text is shown', (tester) async {
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
    final html = '<table><tr>${'<td colspan="20">a</td>' * 1000}</tr>'
        '${'<tr><td>b</td></tr>' * 1000}</table>';
    await pump(tester, html);
    expect(tester.takeException(), isNull);
    expect(find.byType(Table), findsNothing);
    expect(tester.allWidgets.length, lessThan(1000));

    await pump(tester, '<table><tr><td colspan="2">a</td></tr></table>');
    expect(find.byType(Table), findsOneWidget);
  });
}
