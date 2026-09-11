import 'package:url_launcher/url_launcher.dart';
import '../utils/constants.dart';

/// Helper membuka WhatsApp, telepon, email, dan browser.
class ExternalService {
  /// Buka chat WA ke admin dengan pesan [message].
  static Future<bool> openWhatsApp(String message) async {
    final uri = Uri.parse(
      'https://wa.me/${AppConstants.phoneWa}?text=${Uri.encodeComponent(message)}',
    );
    return _launch(uri);
  }

  static Future<bool> openPhone() async =>
      _launch(Uri.parse('tel:+${AppConstants.phoneWa}'));

  static Future<bool> openEmail({
    String subject = '',
    String body = '',
  }) async => _launch(
    Uri(
      scheme: 'mailto',
      path: AppConstants.email,
      queryParameters: {'subject': subject, 'body': body},
    ),
  );

  static Future<bool> openLink(String url) async => _launch(Uri.parse(url));

  static Future<bool> _launch(Uri uri) async {
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return ok;
    } catch (_) {
      return false;
    }
  }
}
