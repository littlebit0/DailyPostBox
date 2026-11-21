import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/services/mail_api_client.dart';
import 'package:daily_postbox/services/mail_cache.dart';

class _FakeAdapter implements HttpClientAdapter {
  bool offline = false;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    if (offline) {
      throw DioException.connectionError(
          requestOptions: options, reason: 'down');
    }
    final body = options.path.endsWith('/messages')
        ? '[{"id":"m1","from":"a@example.test","subject":"hi","snippet":"s"}]'
        : '{"id":"m1","from":"a@example.test","subject":"hi","body":"text"}';
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory dir;
  late MailCache cache;
  late _FakeAdapter adapter;
  late MailApiClient api;
  late List<DateTime?> states;
  late ProviderContainer container;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mail_cache_test');
    cache = MailCache(() async => dir);
    adapter = _FakeAdapter();
    states = [];
    container = ProviderContainer();
    final cached = container.read(cachedPathsProvider.notifier);
    api = MailApiClient(
      baseUrl: 'http://127.0.0.1:1',
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
        ..httpClientAdapter = adapter,
      cache: cache,
      onCacheState: (path, cachedAt) {
        states.add(cachedAt);
        recordCacheState(cached, path, cachedAt);
      },
    );
  });

  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  test('serves cached list and body when the server is unreachable', () async {
    await api.fetchAccountMessages('acc1');
    await api.fetchAccountMessage(accountId: 'acc1', messageId: 'm1');
    expect(states, [null, null]);

    adapter.offline = true;
    final list = await api.fetchAccountMessages('acc1');
    final detail =
        await api.fetchAccountMessage(accountId: 'acc1', messageId: 'm1');
    expect(list.single.subject, 'hi');
    expect(detail.body, 'text');
    expect(states.skip(2).every((state) => state != null), isTrue);
  });

  test('rethrows offline when nothing is cached', () async {
    adapter.offline = true;
    expect(api.fetchAccountMessages('acc1'), throwsA(isA<DioException>()));
  });

  test('clearAccount removes that account and the shared lists only', () async {
    await cache.write('/accounts/acc1/messages', []);
    await cache.write('/accounts/acc2/messages', []);
    await cache.write('/mail/inbox', []);

    await cache.clearAccount('acc1');

    expect(await cache.read('/accounts/acc1/messages'), isNull);
    expect(await cache.read('/mail/inbox'), isNull);
    expect(await cache.read('/accounts/acc2/messages'), isNotNull);
  });

  test('clearAccount keeps the provider list cache', () async {
    await cache.write('/providers', [
      {'id': 'gmail', 'displayName': 'Gmail'},
    ]);
    await cache.write('/accounts', []);

    await cache.clearAccount('acc1');

    expect(await cache.read('/accounts'), isNull);
    expect((await cache.read('/providers'))?.data, isA<List<dynamic>>());
  });

  test('offline state is tracked per resource path', () async {
    final messagePath =
        MailApiClient.messagePath(messageId: 'm1', accountId: 'acc1');
    final mailboxPath = MailApiClient.accountMessagesPath('acc1');
    await api.fetchAccountMessage(accountId: 'acc1', messageId: 'm1');

    adapter.offline = true;
    await api.fetchAccountMessage(accountId: 'acc1', messageId: 'm1');
    adapter.offline = false;
    await api.fetchAccountMessages('acc1');

    final cached = container.read(cachedPathsProvider);
    expect(offlineSinceFor(cached, [messagePath]), isNotNull);
    expect(offlineSinceFor(cached, [mailboxPath]), isNull);

    await api.fetchAccountMessage(accountId: 'acc1', messageId: 'm1');
    expect(
      offlineSinceFor(container.read(cachedPathsProvider), [messagePath]),
      isNull,
    );
  });
}
