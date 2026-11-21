import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/message/html_message_body.dart';
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
    final rect =
        tester.getRect(find.textContaining('good', findRichText: true));
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
}
