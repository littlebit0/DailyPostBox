import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final pushServiceProvider = Provider<PushService>((ref) => PushService());

class PushService {
  static const _channel = MethodChannel('dailypostbox/push');

  Future<void> initialize() async {}

  /// Whether this platform can register for remote push yet.
  bool get isSupported => Platform.isMacOS;

  /// Asks for notification permission and returns the APNs device token.
  /// Throws a [PlatformException] when permission or registration fails.
  Future<String?> getDeviceToken() async {
    if (!isSupported) return null;
    return _channel.invokeMethod<String>('getDeviceToken');
  }

  String get platformName {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'unknown';
  }
}
