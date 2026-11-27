import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'external_url.dart';

PublicationFilePicker createPublicationFilePicker(
  SyncAccessTokenProvider tokens,
) => GoogleDrivePicker(tokens: tokens, openBrowser: openExternalUrl);
