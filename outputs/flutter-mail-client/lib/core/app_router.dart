import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/accounts/accounts_page.dart';
import '../features/message/compose_page.dart';
import '../features/message/message_page.dart';
import '../features/settings/settings_page.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/accounts',
    routes: [
      GoRoute(
        path: '/',
        redirect: (context, state) => '/accounts',
      ),
      GoRoute(
        path: '/accounts',
        pageBuilder: (context, state) => _verticalPage(
          state: state,
          child: const AccountsPage(),
        ),
      ),
      GoRoute(
        path: '/messages/:id',
        pageBuilder: (context, state) => _verticalPage(
          state: state,
          child: MessagePage(
            messageId: state.pathParameters['id']!,
          ),
        ),
      ),
      GoRoute(
        path: '/compose',
        pageBuilder: (context, state) => _verticalPage(
          state: state,
          child: const ComposePage(),
        ),
      ),
      GoRoute(
        path: '/settings',
        pageBuilder: (context, state) => _verticalPage(
          state: state,
          child: const SettingsPage(),
        ),
      ),
    ],
  );
});

CustomTransitionPage<void> _verticalPage({
  required GoRouterState state,
  required Widget child,
}) {
  final extra = state.extra;
  final direction = extra is Map<String, Object?>
      ? extra['verticalDirection'] as int? ?? 1
      : 1;

  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 360),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final enter = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutQuart,
        reverseCurve: Curves.easeInQuart,
      );
      final exit = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutQuart,
        reverseCurve: Curves.easeInQuart,
      );

      return AnimatedBuilder(
        animation: Listenable.merge([enter, exit]),
        child: child,
        builder: (context, child) {
          final enterDy = direction * (1 - enter.value) * 56;
          final exitDy = -direction * exit.value * 34;
          final opacity = (0.82 + enter.value * 0.18) * (1 - exit.value * 0.10);
          final scale = 0.985 + enter.value * 0.015 - exit.value * 0.006;

          return Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, enterDy + exitDy),
              child: Transform.scale(
                scale: scale,
                child: child,
              ),
            ),
          );
        },
      );
    },
  );
}
