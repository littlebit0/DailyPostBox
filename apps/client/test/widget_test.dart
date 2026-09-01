import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/accounts/accounts_page.dart';
import 'package:daily_postbox/main.dart';
import 'package:daily_postbox/services/mail_api_client.dart';

void main() {
  testWidgets('renders mail app shell', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const []),
          providersProvider.overrideWith((ref) async => const []),
        ],
        child: const DailyPostBoxApp(),
      ),
    );

    await tester.pump();

    expect(find.text('계정관리'), findsWidgets);
  });

  testWidgets('shows a friendly server connection error',
      (WidgetTester tester) async {
    final error = DioException.connectionError(
      requestOptions: RequestOptions(path: '/accounts'),
      reason: 'Failed host lookup',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) => Future.error(error)),
          providersProvider.overrideWith((ref) => Future.error(error)),
        ],
        child: const DailyPostBoxApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('메일 서버에 연결할 수 없습니다'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    expect(find.textContaining('DioException'), findsNothing);
  });

  test('uses the loopback API during local development', () {
    expect(
      resolveMailApiBaseUrl(configured: '', isRelease: false),
      'http://127.0.0.1:4000',
    );
  });
}
