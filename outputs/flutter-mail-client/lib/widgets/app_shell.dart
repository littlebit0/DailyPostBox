import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/i18n/language_controller.dart';

class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.selectedIndex,
    required this.child,
    this.floatingActionButton,
  });

  final int selectedIndex;
  final Widget child;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final destinations = [
      _Destination(
          strings.accountManagement, Icons.alternate_email, '/accounts'),
      _Destination(strings.settings, Icons.settings_outlined, '/settings'),
    ];

    return Scaffold(
      body: Row(
        children: [
          _AnimatedSideNavigation(
            selectedIndex: selectedIndex,
            destinations: destinations,
            onDestinationSelected: (index) {
              if (index == selectedIndex) return;

              context.go(
                destinations[index].path,
                extra: {
                  'verticalDirection': index > selectedIndex ? 1 : -1,
                },
              );
            },
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.path);

  final String label;
  final IconData icon;
  final String path;
}

class _AnimatedSideNavigation extends StatelessWidget {
  const _AnimatedSideNavigation({
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
  });

  static const double _railWidth = 80;
  static const double _topPadding = 44;
  static const double _itemHeight = 64;

  final int selectedIndex;
  final List<_Destination> destinations;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: _railWidth,
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            top: _topPadding + selectedIndex * _itemHeight + 8,
            left: 12,
            right: 12,
            height: 40,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: _topPadding),
            child: Column(
              children: [
                for (var index = 0; index < destinations.length; index++)
                  _RailDestinationButton(
                    height: _itemHeight,
                    destination: destinations[index],
                    selected: index == selectedIndex,
                    onTap: () => onDestinationSelected(index),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailDestinationButton extends StatelessWidget {
  const _RailDestinationButton({
    required this.height,
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final double height;
  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground =
        selected ? scheme.onSecondaryContainer : scheme.onSurface;

    return Tooltip(
      message: destination.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(destination.icon, color: foreground),
              const SizedBox(height: 6),
              Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
