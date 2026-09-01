import 'package:url_launcher/url_launcher.dart';

Future<bool> openExternalBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
    return false;
  }

  try {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
