import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/i18n/language_controller.dart';
import '../features/accounts/account_providers.dart';

class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.selectedDestinationId,
    required this.child,
    this.floatingActionButton,
  });

  static const managementDestinationId = 'account-management';
  static const settingsDestinationId = 'settings';

  static String accountDestinationId(String accountId) =>
      'mail-account:$accountId';

  final String selectedDestinationId;
  final Widget child;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final accounts = ref.watch(accountsProvider).asData?.value ?? const [];
    final destinations = [
      _Destination(
        id: managementDestinationId,
        label: strings.accountManagement,
        icon: Icons.alternate_email,
        path: '/accounts',
      ),
      for (final account in accounts)
        _Destination(
          id: accountDestinationId(account.id),
          label: account.emailAddress,
          subtitle:
              '${account.providerId.toUpperCase()} · ${account.incomingProtocol.toUpperCase()}',
          icon: Icons.mail_outline,
          path: '/accounts/${account.id}/mail',
        ),
      _Destination(
        id: settingsDestinationId,
        label: strings.settings,
        icon: Icons.settings_outlined,
        path: '/settings',
      ),
    ];
    final selectedIndex = destinations.indexWhere(
      (destination) => destination.id == selectedDestinationId,
    );
    final compact = MediaQuery.sizeOf(context).width < 720;

    void selectDestination(int index) {
      if (index < 0 || index >= destinations.length) return;
      final destination = destinations[index];
      if (destination.id == selectedDestinationId) {
        if (compact && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        return;
      }

      if (compact && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      context.go(
        destination.path,
        extra: const {'disableTransition': true},
      );
    }

    final navigation = _SideNavigation(
      selectedIndex: selectedIndex,
      destinations: destinations,
      onDestinationSelected: selectDestination,
    );

    return Scaffold(
      drawer: compact
          ? Drawer(
              width: 292,
              child: navigation,
            )
          : null,
      body: compact
          ? child
          : Row(
              children: [
                SizedBox(width: 284, child: navigation),
                const VerticalDivider(width: 1),
                Expanded(child: child),
              ],
            ),
      floatingActionButton: floatingActionButton,
    );
  }
}

class _Destination {
  const _Destination({
    required this.id,
    required this.label,
    required this.icon,
    required this.path,
    this.subtitle,
  });

  final String id;
  final String label;
  final String? subtitle;
  final IconData icon;
  final String path;
}

class _SideNavigation extends ConsumerWidget {
  const _SideNavigation({
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final List<_Destination> destinations;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final accountDestinations = destinations.length > 2
        ? destinations.sublist(1, destinations.length - 1)
        : const <_Destination>[];

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Text(
              strings.appTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          _SideNavigationItem(
            destination: destinations.first,
            selected: selectedIndex == 0,
            onTap: () => onDestinationSelected(0),
          ),
          if (accountDestinations.isNotEmpty) ...[
            const Divider(height: 22, indent: 14, endIndent: 14),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: accountDestinations.length,
                itemBuilder: (context, index) {
                  final destinationIndex = index + 1;
                  return _SideNavigationItem(
                    destination: accountDestinations[index],
                    selected: selectedIndex == destinationIndex,
                    onTap: () => onDestinationSelected(destinationIndex),
                  );
                },
              ),
            ),
          ] else
            const Spacer(),
          const Divider(height: 22, indent: 14, endIndent: 14),
          _SideNavigationItem(
            destination: destinations.last,
            selected: selectedIndex == destinations.length - 1,
            onTap: () => onDestinationSelected(destinations.length - 1),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _SideNavigationItem extends StatelessWidget {
  const _SideNavigationItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground =
        selected ? scheme.onSecondaryContainer : scheme.onSurface;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(7),
        child: ListTile(
          minTileHeight: destination.subtitle == null ? 52 : 60,
          minLeadingWidth: 24,
          horizontalTitleGap: 10,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(destination.icon, color: foreground),
          title: Text(
            destination.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontSize: destination.subtitle == null ? null : 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
          ),
          subtitle: destination.subtitle == null
              ? null
              : Text(
                  destination.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: foreground.withValues(alpha: 0.72),
                      ),
                ),
          selected: selected,
          onTap: onTap,
        ),
      ),
    );
  }
}
