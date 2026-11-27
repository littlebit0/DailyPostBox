import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:daily_postbox/core/i18n/language_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('starts in Korean when no language was saved', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await loadSavedLanguage(), AppLanguage.korean);
  });

  test('keeps the chosen language for the next launch', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(languageControllerProvider.notifier)
        .setLanguage(AppLanguage.english);
    expect(container.read(languageControllerProvider), AppLanguage.english);

    final saved = await loadSavedLanguage();
    expect(saved, AppLanguage.english);

    final nextLaunch = ProviderContainer(
      overrides: [initialLanguageProvider.overrideWithValue(saved)],
    );
    addTearDown(nextLaunch.dispose);
    expect(nextLaunch.read(languageControllerProvider), AppLanguage.english);
  });

  test('falls back to Korean for an unknown saved value', () async {
    SharedPreferences.setMockInitialValues({'app_language': 'klingon'});
    expect(await loadSavedLanguage(), AppLanguage.korean);
  });
}
