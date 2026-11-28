import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/main.dart';
import 'package:daily_postbox/services/mail_api_client.dart';
import 'package:daily_postbox/services/mail_cache.dart';

class _DownAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'down',
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets('accounts page lists cached accounts with the offline banner', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('accounts_offline_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = MailCache(() async => dir);
    await tester.runAsync(() async {
      await cache.write('/accounts', [
        {
          'id': 'a1',
          'providerId': 'gmail',
          'emailAddress': 'cached@example.test',
          'incomingProtocol': 'imap',
        },
      ]);
      await cache.write('/providers', [
        {
          'id': 'gmail',
          'displayName': 'Gmail',
          'authModes': ['oauth2'],
          'defaultProtocol': 'imap',
          'supportsOAuth': true,
        },
      ]);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailApiClientProvider.overrideWith((ref) {
            final cached = ref.read(cachedPathsProvider.notifier);
            return MailApiClient(
              baseUrl: 'http://127.0.0.1:1',
              dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
                ..httpClientAdapter = _DownAdapter(),
              cache: cache,
              onCacheState: (path, cachedAt) => Future.microtask(
                () => recordCacheState(cached, path, cachedAt),
              ),
            );
          }),
        ],
        child: const DailyPostBoxApp(),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('메일 서버에 연결할 수 없습니다'), findsNothing);
    expect(find.text('cached@example.test'), findsWidgets);
    expect(find.textContaining('오프라인'), findsOneWidget);
    final sync = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.sync),
    );
    expect(sync.onPressed, isNull);
  });
}
