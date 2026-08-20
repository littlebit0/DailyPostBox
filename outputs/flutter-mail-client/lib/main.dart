import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_router.dart';
import 'core/app_theme.dart';
import 'core/i18n/language_controller.dart';
import 'services/push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final pushService = PushService();
  await pushService.initialize();

  runApp(
    ProviderScope(
      overrides: [
        pushServiceProvider.overrideWithValue(pushService),
      ],
      child: const UniversalMailApp(),
    ),
  );
}

class UniversalMailApp extends ConsumerWidget {
  const UniversalMailApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final language = ref.watch(languageControllerProvider);
    final strings = ref.watch(appStringsProvider);

    return MaterialApp.router(
      title: strings.appTitle,
      locale: language.locale,
      supportedLocales: AppLanguage.values.map((language) => language.locale),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
