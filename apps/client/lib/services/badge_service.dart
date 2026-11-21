import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/accounts/account_providers.dart';

final badgeServiceProvider = Provider<BadgeService>((ref) => BadgeService());

/// Unread count over the mailbox lists loaded so far.
final unreadCountProvider = Provider<int>((ref) {
  final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
  var count = 0;
  for (final account in accounts) {
    final messages = ref.watch(accountMessagesProvider(account.id)).valueOrNull;
    count += messages?.where((message) => message.unread).length ?? 0;
  }
  return count;
});

/// Pushes every change of the unread count to the Dock badge.
final badgeSyncProvider = Provider<void>((ref) {
  ref.listen<int>(
    unreadCountProvider,
    (_, count) => ref.read(badgeServiceProvider).setUnreadCount(count),
    fireImmediately: true,
  );
});

class BadgeService {
  static const _channel = MethodChannel('dailypostbox/badge');

  /// Shows [count] on the macOS Dock icon; 0 clears it.
  Future<void> setUnreadCount(int count) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>('setBadge', count);
    } on PlatformException {
      // The badge is cosmetic; ignore native failures.
    } on MissingPluginException {
      // No native side (tests).
    }
  }
}
