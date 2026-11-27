import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/message/bounded_network_image.dart';
import 'package:daily_postbox/features/message/html_message_body.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  late HttpServer server;
  late Uri base;

  setUp(() async {
    // flutter_test stubs HttpClient with 400s; these tests need real loopback.
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((req) async {
      final res = req.response;
      switch (req.uri.path) {
        case '/small.png':
          res.add(_png);
        case '/big':
          res.contentLength = 2048;
          res.add(List.filled(2048, 0));
        case '/stream':
          // No Content-Length: chunked, never ends on its own.
          try {
            for (var i = 0; i < 1000; i++) {
              res.add(List.filled(1024, 0));
              await res.flush();
            }
          } catch (_) {}
      }
      await res.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('oversized Content-Length is rejected', () async {
    await expectLater(
      fetchBoundedImage(base.resolve('/big'), maxBytes: 1024),
      throwsA(isA<HttpException>()),
    );
  });

  test('chunked stream over the limit is aborted', () async {
    await expectLater(
      fetchBoundedImage(base.resolve('/stream'), maxBytes: 4096),
      throwsA(isA<HttpException>()),
    );
  });

  test('non-http scheme is rejected', () async {
    await expectLater(
      fetchBoundedImage(Uri.parse('file:///etc/hosts')),
      throwsA(isA<ArgumentError>()),
    );
  });

  testWidgets('small PNG renders', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HtmlMessageBody(
              html: '<img src="${base.resolve('/small.png')}" alt="ALT">',
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(find.text('ALT', findRichText: true), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('failed image falls back to alt text', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HtmlMessageBody(
              html: '<img src="${base.resolve('/missing')}" alt="ALT">',
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(find.text('ALT', findRichText: true), findsOneWidget);
  });
}
