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
    return SectionCard(
      title: l.uiAppearance,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.theme),
          const SizedBox(height: AppLayout.smallGap),
          AppChoice<ThemeMode>(
            value: theme,
            options: [
              (ThemeMode.system, l.system),
              (ThemeMode.light, l.light),
              (ThemeMode.dark, l.dark),
            ],
            onChanged: onTheme,
          ),
          const SizedBox(height: AppLayout.gap),
          Text(l.language),
          const SizedBox(height: AppLayout.smallGap),
          AppChoice<AppLanguage>(
            value: languages.language,
            keyPrefix: 'language',
            options: [
              (AppLanguage.system, l.languageSystem),
              (AppLanguage.ru, l.languageRussian),
              (AppLanguage.en, l.languageEnglish),
            ],
            onChanged: languages.saving ? null : languages.select,
          ),
          if (languages.savingFailed) Text(l.localeSaveError),
          if (languages.loadingFailed) Text(l.localeLoadError),
          const SizedBox(height: AppLayout.smallGap),
          AppExpansionTile(
            key: const PageStorageKey('appearance-motion'),
            tilePadding: EdgeInsets.zero,
            title: Text(l.motion),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppChoice<MotionPreference>(
                value: motion,
                options: [
                  (MotionPreference.system, l.system),
                  (MotionPreference.reduced, l.reduced),
                  (MotionPreference.off, l.off),
                ],
                onChanged: onMotion,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
