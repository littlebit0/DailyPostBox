import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:universal_mail_client/features/accounts/accounts_page.dart';
import 'package:universal_mail_client/main.dart';

void main() {
  testWidgets('renders mail app shell', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWith((ref) async => const []),
          providersProvider.overrideWith((ref) async => const []),
        ],
        child: const UniversalMailApp(),
      ),
    );

    await tester.pump();

    expect(find.text('계정관리'), findsWidgets);
  });
}
