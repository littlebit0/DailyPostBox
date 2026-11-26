import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'i18n/language_controller.dart';

/// Commands the active mailbox exposes in the native "Mail" menu.
class MailboxMenuCommands {
  const MailboxMenuCommands({
    required this.compose,
    required this.openSelected,
    required this.next,
    required this.previous,
    required this.showHelp,
  });

  final VoidCallback compose;
  final VoidCallback openSelected;
  final VoidCallback next;
  final VoidCallback previous;
  final VoidCallback showHelp;
}

/// The mounted mailbox registers its commands here; null hides the Mail menu.
final mailboxMenuCommandsProvider =
    Provider<ValueNotifier<MailboxMenuCommands?>>((ref) {
  final notifier = ValueNotifier<MailboxMenuCommands?>(null);
  ref.onDispose(notifier.dispose);
  return notifier;
});

/// Native macOS menu bar mounted once above the router, so route changes
/// never dispose it (disposal clears every native menu, Quit included).
class AppMenuBar extends ConsumerWidget {
  const AppMenuBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;
    final strings = ref.watch(appStringsProvider);
    return ValueListenableBuilder<MailboxMenuCommands?>(
      valueListenable: ref.watch(mailboxMenuCommandsProvider),
      builder: (context, commands, child) => PlatformMenuBar(
        menus: [
          const PlatformMenu(
            label: 'DailyPostBox',
            menus: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.about,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.servicesSubmenu,
              ),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hideOtherApplications,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.showAllApplications,
              ),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
            ],
          ),
          if (commands != null)
            PlatformMenu(
              label: strings.mailMenu,
              menus: [
                PlatformMenuItem(
                  label: strings.compose,
                  // shortcut: 단일 키 네이티브 가속키는 입력창에서도 발동하므로 쓰지 않음.
                  onSelected: commands.compose,
                ),
                PlatformMenuItem(
                  label: strings.shortcutOpenMessage,
                  onSelected: commands.openSelected,
                ),
                PlatformMenuItem(
                  label: strings.shortcutNextMessage,
                  onSelected: commands.next,
                ),
                PlatformMenuItem(
                  label: strings.shortcutPreviousMessage,
                  onSelected: commands.previous,
                ),
                PlatformMenuItem(
                  label: strings.shortcutHelp,
                  onSelected: commands.showHelp,
                ),
              ],
            ),
          PlatformMenu(
            label: strings.editMenu,
            menus: const [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.startSpeaking,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.stopSpeaking,
              ),
            ],
          ),
          PlatformMenu(
            label: strings.windowMenu,
            menus: const [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.minimizeWindow,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.zoomWindow,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.toggleFullScreen,
              ),
            ],
          ),
        ],
        child: child!,
      ),
      child: child,
    );
  }
}
