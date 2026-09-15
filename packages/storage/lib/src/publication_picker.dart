import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:url_launcher/url_launcher.dart';

PublicationFilePicker createPublicationFilePicker(
  SyncAccessTokenProvider tokens,
) => GoogleDrivePicker(
  tokens: tokens,
  openBrowser: (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);
