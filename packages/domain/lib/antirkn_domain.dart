export 'src/core_probe.dart';
export 'src/core_validation.dart';
export 'src/network/ip_diagnostics.dart';
export 'src/publication.dart';
export 'src/auto_sync.dart';
export 'src/google_account.dart';
export 'src/sync_transport.dart';
export 'src/sync_merge.dart';
export 'src/canonical_json.dart';
export 'src/backup.dart';
export 'src/change_journal.dart';
export 'src/sync.dart';
export 'src/tt.dart';
export 'src/awg.dart';
export 'src/runner.dart';
export 'src/server_operation.dart';
export 'src/component_updates.dart';
export 'src/vpn.dart';
export 'src/client_login.dart';
export 'src/privileges.dart';
export 'src/workspace.dart';
export 'src/network/ip_address.dart';
export 'src/network/network_inventory.dart';
export 'src/network/address_selection.dart';
export 'src/ssh.dart';
export 'src/vault.dart';
export 'src/server_inventory.dart';
export 'src/ssh_harden.dart';

/// Identifies an already provisioned access. Compiling never creates credentials.
final class AccessIdentity {
  const AccessIdentity({
    required this.id,
    required this.userId,
    required this.active,
    required this.confirmed,
  });

  final String id;
  final String userId;
  final bool active;
  final bool confirmed;
}

enum DiagnosticSeverity { info, warning, error }

/// Safe message codes only: never include YAML excerpts or credentials.
final class ProfileDiagnostic {
  const ProfileDiagnostic(this.code, this.severity, {this.subject});
  final String code;
  final DiagnosticSeverity severity;
  final String? subject;
}

enum VerificationStatus { notRun, passed, failed }

enum AppLanguage { system, ru, en }

abstract interface class LanguagePreferenceStore {
  Future<AppLanguage> readLanguage();
  Future<void> writeLanguage(AppLanguage language);
}

final class ImportedTemplate {
  const ImportedTemplate({required this.name, required this.source});
  final String name;
  final String source;
}

abstract interface class TemplateFilePicker {
  Future<ImportedTemplate?> pick();
}
