import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';

import 'command_executor.dart';
import 'inventory_probes.dart';

/// Password probes are serialized. A rejected password stops remaining probes.
final class PrivilegeRunner {
  PrivilegeRunner(this.executor, this.cancellation, {this.password});
  final SshCommandExecutor executor;
  final CancellationToken cancellation;
  final String? password;
  Future<void> _tail = Future.value();
  SshFailure? _failure;

  Future<PrivilegeCheck> check() async {
    if (!validSudoPassword(password)) {
      return const PrivilegeCheck(PrivilegeStatus.invalidPassword);
    }
    final uid = await executor.execute('id -u', cancellation, limit: 128);
    if (!uid.succeeded) throw const SshFailure(SshIssue.commandFailed);
    if (uid.output.trim() == '0') {
      return const PrivilegeCheck(PrivilegeStatus.root);
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(uid.output.trim())) {
      throw const SshFailure(SshIssue.invalidInventory);
    }
    final available = await executor.execute(
      '${InventoryProbes.prefix}command -v sudo >/dev/null 2>&1',
      cancellation,
      limit: 128,
    );
    if (!available.succeeded) {
      return const PrivilegeCheck(PrivilegeStatus.unavailable);
    }
    final result = await _sudo('/usr/bin/id -u');
    if (result.succeeded && result.output.trim() == '0') {
      return PrivilegeCheck(
        result.passwordSent
            ? PrivilegeStatus.sudoWithPassword
            : PrivilegeStatus.sudoWithoutPassword,
      );
    }
    if (result.succeeded) throw const SshFailure(SshIssue.invalidInventory);
    return PrivilegeCheck(sudoFailureStatus(result));
  }

  static String command(String read, {required bool withPassword}) =>
      '${InventoryProbes.prefix}sudo -k '
      '${withPassword ? "-S -p '$sudoPrompt'" : '-n'} -- $read';

  static String shellRead(String read) =>
      "/bin/sh -c '${read.replaceAll("'", "'\\''")}'";

  Future<RemoteCommandResult> _sudo(String read) async {
    final result = await executor.execute(
      command(read, withPassword: password?.isNotEmpty == true),
      cancellation,
      sudoPassword: password?.isNotEmpty == true ? password : null,
      limit: 65536,
    );
    if (result.signalled || result.exitCode == null) {
      throw const SshFailure(SshIssue.disconnected);
    }
    return result;
  }

  Future<String> read(String command) async {
    if (!InventoryProbes.canElevate(command)) {
      throw const SshFailure(SshIssue.commandFailed);
    }
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    try {
      await cancellation.bind(previous);
      cancellation.check();
      if (_failure != null) throw _failure!;
      // Only a validated, generated read probe reaches sh.
      final result = await _sudo(shellRead(command));
      if (result.succeeded) return result.output;
      final status = sudoFailureStatus(result);
      if (status == PrivilegeStatus.denied) return '@denied\n';
      final issue = switch (status) {
        PrivilegeStatus.passwordRequired => SshIssue.sudoPasswordRequired,
        PrivilegeStatus.authenticationFailed =>
          SshIssue.sudoAuthenticationFailed,
        PrivilegeStatus.unavailable => SshIssue.sudoUnavailable,
        PrivilegeStatus.terminalRequired => SshIssue.sudoTerminalRequired,
        _ => SshIssue.sudoDenied,
      };
      _failure = SshFailure(issue);
      throw _failure!;
    } finally {
      done.complete();
    }
  }
}

PrivilegeStatus sudoFailureStatus(RemoteCommandResult result) {
  final error = result.error.toLowerCase();
  if (error.contains('must have a tty') ||
      error.contains('a terminal is required')) {
    return PrivilegeStatus.terminalRequired;
  }
  if (error.contains('not in the sudoers') ||
      error.contains('not allowed to') ||
      error.contains('may not run sudo')) {
    return PrivilegeStatus.denied;
  }
  if (result.passwordSent &&
      (error.contains('incorrect password') ||
          error.contains('sorry, try again') ||
          error.contains('authentication failure'))) {
    return PrivilegeStatus.authenticationFailed;
  }
  if (error.contains('a password is required') ||
      error.contains('no password was provided') ||
      error.contains('no password was supplied')) {
    return PrivilegeStatus.passwordRequired;
  }
  return PrivilegeStatus.denied;
}
