import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/language_controller.dart';
import '../../services/mail_api_client.dart';
import '../../services/push_service.dart';
import '../../widgets/app_shell.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(languageControllerProvider);
    final strings = ref.watch(appStringsProvider);

    return AppShell(
      selectedDestinationId: AppShell.settingsDestinationId,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBar(title: Text(strings.settings)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                ListTile(
                  leading: const Icon(Icons.language),
                  title: Text(strings.languageSetting),
                  subtitle: Text(strings.languageDescription),
                  trailing: SegmentedButton<AppLanguage>(
                    segments: [
                      for (final item in AppLanguage.values)
                        ButtonSegment(
                          value: item,
                          label: Text(item.label),
                        ),
                    ],
                    selected: {language},
                    onSelectionChanged: (value) {
                      ref
                          .read(languageControllerProvider.notifier)
                          .setLanguage(value.first);
                    },
                  ),
                ),
                SwitchListTile(
                  value: true,
                  onChanged: (_) {},
                  title: Text(strings.pushNotifications),
                  subtitle: Text(strings.pushNotificationsDescription),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: Text(strings.registerThisDevice),
                  subtitle: Text(strings.registerThisDeviceDescription),
                  onTap: () async {
                    final push = ref.read(pushServiceProvider);
                    final token = await push.getDeviceToken();
                    if (token == null) return;

                    await ref.read(mailApiClientProvider).registerPushToken(
                          platform: push.platformName,
                          token: token,
                        );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
