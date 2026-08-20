import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final pushServiceProvider = Provider<PushService>((ref) => PushService());

class PushService {
  Future<void> initialize() async {
    // Native push providers are wired after platform-specific Firebase/APNs setup.
  }

  Future<String?> getDeviceToken() async {
    return null;
  }

  String get platformName {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'unknown';
  }
}
