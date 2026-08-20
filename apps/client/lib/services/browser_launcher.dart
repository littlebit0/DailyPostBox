import 'dart:io';

Future<bool> openExternalBrowser(String url) async {
  try {
    if (Platform.isMacOS) {
      final result = await Process.run('/usr/bin/open', [url]);
      return result.exitCode == 0;
    }
    if (Platform.isWindows) {
      final result =
          await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      return result.exitCode == 0;
    }
    if (Platform.isLinux) {
      final result = await Process.run('xdg-open', [url]);
      return result.exitCode == 0;
    }
  } catch (_) {
    return false;
  }

  return false;
}
