import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daily_postbox/features/accounts/accounts_page.dart';
import 'package:daily_postbox/main.dart';

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
}
