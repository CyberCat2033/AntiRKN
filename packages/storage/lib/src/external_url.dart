import 'package:url_launcher/url_launcher.dart';

/// Opens [uri] in the system browser or the app that handles it.
Future<bool> openExternalUrl(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
