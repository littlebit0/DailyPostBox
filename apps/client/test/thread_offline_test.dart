import 'dart:io';

import 'package:daily_postbox/services/mail_api_client.dart';
import 'package:daily_postbox/services/mail_cache.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

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
  test('offline thread is rebuilt from the saved mailbox, oldest first',
      () async {
    final dir = Directory.systemTemp.createTempSync('thread_offline_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = MailCache(() async => dir);
    await cache.write(MailApiClient.accountMessagesPath('a1'), [
      {'id': 'm3', 'subject': 'Re: hi', 'threadId': 't1'},
      {'id': 'm2', 'subject': 'other', 'threadId': 't2'},
      {'id': 'm1', 'subject': 'hi', 'threadId': 't1'},
    ]);
    final states = <String, DateTime?>{};
    final client = MailApiClient(
      baseUrl: 'http://127.0.0.1:1',
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
        ..httpClientAdapter = _DownAdapter(),
      cache: cache,
      onCacheState: (path, cachedAt) => states[path] = cachedAt,
    );

    final thread = await client.fetchThread('a1', 't1');
    expect(thread.map((m) => m.id), ['m1', 'm3']);
    expect(states[MailApiClient.threadPath('a1', 't1')], isNotNull);

    await expectLater(
      client.fetchThread('a1', 'missing'),
      throwsA(isA<DioException>()),
    );
  });
}
