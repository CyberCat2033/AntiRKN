import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_storage/antirkn_storage.dart' show openExternalUrl;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_localizations.dart';
import 'update/app_update_controller.dart';

const appLicenseAsset = 'assets/legal/LICENSE';
final appRepository = Uri.parse('https://github.com/CyberCat2033/AntiRKN');
final appDisclaimer = Uri.parse(
  'https://github.com/CyberCat2033/AntiRKN/blob/master/DISCLAIMER.md',
);

/// The GPL text of the app and of the embedded Mihomo core, shown on the
/// licenses page next to the Dart packages' own licenses.
void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'AntiRKN',
      'mihomo',
    ], await rootBundle.loadString(appLicenseAsset));
  });
}

/// Settings → About: purpose of the app, licenses and source code.
class AboutSettings extends StatelessWidget {
  const AboutSettings({required this.motion, super.key});
  final MotionPreference motion;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final version = AppUpdateScope.of(context)?.installed?.version;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsSection(
          title: l.aboutPurposeTitle,
          child: Padding(
            padding: const EdgeInsets.all(AppLayout.gap),
            child: Text(
              l.aboutPurpose,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
        AppSettingsSection(
          child: Column(
            children: [
              ListTile(
                key: const ValueKey('about-licenses'),
                leading: const Icon(Icons.gavel_outlined),
                title: Text(l.aboutLicenses),
                subtitle: Text(l.aboutLicensesHelp),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => pushAppPage<void>(
                  context,
                  motion: motion,
                  builder: (_) => LicensePage(
                    applicationName: 'AntiRKN',
                    applicationVersion: version,
                    applicationLegalese: l.aboutLegalese,
                  ),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                key: const ValueKey('about-disclaimer'),
                leading: const Icon(Icons.policy_outlined),
                title: Text(l.aboutDisclaimer),
                subtitle: Text(l.aboutDisclaimerHelp),
                trailing: Icon(
                  Icons.open_in_new,
                  semanticLabel: l.aboutOpensBrowser,
                ),
                onTap: () => openExternalUrl(appDisclaimer),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                key: const ValueKey('about-source'),
                leading: const Icon(Icons.code),
                title: Text(l.aboutSource),
                subtitle: Text(l.aboutSourceHelp),
                trailing: Icon(
                  Icons.open_in_new,
                  semanticLabel: l.aboutOpensBrowser,
                ),
                onTap: () => openExternalUrl(appRepository),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
