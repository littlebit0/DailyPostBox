import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/services/mail_api_client.dart';
import 'package:daily_postbox/services/mail_cache.dart';

class _FakeAdapter implements HttpClientAdapter {
  bool offline = false;
  Completer<void>? gate;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    await gate?.future;
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

  test('remote-image body is never cached', () async {
    await api.fetchAccountMessage(
      accountId: 'acc1',
      messageId: 'm1',
      remoteImages: true,
    );
    expect(
      await cache.read(
        MailApiClient.messagePath(accountId: 'acc1', messageId: 'm1'),
      ),
      isNull,
    );
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

  test('a read started before account deletion does not recache it',
      () async {
    adapter.gate = Completer<void>();
    final pending = api.fetchAccountMessages('a1');
    await Future<void>.delayed(Duration.zero);
    await cache.clearAccount('a1');
    adapter.gate!.complete();
    await pending;

    expect(await cache.read(MailApiClient.accountMessagesPath('a1')), isNull);
    expect(dir.existsSync() ? dir.listSync() : [], isEmpty);

    // Reads that start after the deletion cache normally again.
    adapter.gate = null;
    await api.fetchAccountMessages('a1');
    expect(await cache.read(MailApiClient.accountMessagesPath('a1')), isNotNull);
  });

  test('overwrite replaces the file without leaving temp files', () async {
    await cache.write('/accounts/acc1/messages', ['old']);
    await cache.write('/accounts/acc1/messages', ['new']);

    expect((await cache.read('/accounts/acc1/messages'))?.data, ['new']);
    final files = Directory('${dir.path}/a_acc1').listSync();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('.json'));
  });

  test('failed write keeps the last complete copy', () async {
    await cache.write('/accounts/acc1/messages', ['old']);
    final folder = Directory('${dir.path}/a_acc1');
    final target = folder.listSync().single as File;
    // Read-only folder: a temp file cannot be created, but the target itself
    // stays writable, so an in-place write would still replace it.
    await Process.run('chmod', ['555', folder.path]);
    addTearDown(() => Process.runSync('chmod', ['755', folder.path]));

    await cache.write('/accounts/acc1/messages', ['new']);

    expect(target.existsSync(), isTrue);
    expect((await cache.read('/accounts/acc1/messages'))?.data, ['old']);
  }, skip: Platform.isWindows);
}
