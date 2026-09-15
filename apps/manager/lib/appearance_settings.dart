import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import 'l10n/app_localizations.dart';
import 'language_controller.dart';

class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({
    required this.languages,
    required this.theme,
    required this.motion,
    required this.onTheme,
    required this.onMotion,
    super.key,
  });
  final LanguageController languages;
  final ThemeMode theme;
  final MotionPreference motion;
  final ValueChanged<ThemeMode> onTheme;
  final ValueChanged<MotionPreference> onMotion;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppSettingsSection(
      title: l.uiAppearance,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(l.theme),
            subtitle: Text(switch (theme) {
              ThemeMode.system => l.system,
              ThemeMode.light => l.light,
              ThemeMode.dark => l.dark,
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final value = await showAppChoice<ThemeMode>(
                context,
                title: l.theme,
                value: theme,
                options: [
                  (ThemeMode.system, l.system),
                  (ThemeMode.light, l.light),
                  (ThemeMode.dark, l.dark),
                ],
              );
              if (value != null) onTheme(value);
            },
          ),
          const Divider(indent: 17, endIndent: 17),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l.language),
            subtitle: Text(switch (languages.language) {
              AppLanguage.system => l.languageSystem,
              AppLanguage.ru => l.languageRussian,
              AppLanguage.en => l.languageEnglish,
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: languages.saving
                ? null
                : () async {
                    final value = await showAppChoice<AppLanguage>(
                      context,
                      title: l.language,
                      value: languages.language,
                      options: [
                        (AppLanguage.system, l.languageSystem),
                        (AppLanguage.ru, l.languageRussian),
                        (AppLanguage.en, l.languageEnglish),
                      ],
                    );
                    if (value != null) languages.select(value);
                  },
          ),
          if (languages.savingFailed)
            AppNotice(message: l.localeSaveError, error: true),
          if (languages.loadingFailed)
            AppNotice(message: l.localeLoadError, error: true),
        ],
      ),
    );
  }
}
