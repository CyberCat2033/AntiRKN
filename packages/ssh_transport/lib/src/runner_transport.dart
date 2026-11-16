import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'command_executor.dart';
import 'privilege_runner.dart';
import 'runner_bundle.g.dart';
import 'panel_api.dart';

/// Only the bundled installer and schema-validated RPC reach this adapter.
final class SshRunnerTransport implements RunnerTransport {
  SshRunnerTransport(this.executor);
  final SshCommandExecutor executor;
  String? _sessionUid;
  @override
  String get bundledRelease => runnerRelease;
  static String quote(String text) => "'${text.replaceAll("'", "'\\''")}'";
  static String python(String source) =>
      '/usr/bin/python3 -I -c ${quote(source)}';

  @override
  Future<RunnerInstallation> inspect(CancellationToken cancellation) async {
    final result = await executor.execute(
      python('$runnerInspector\nprint(json.dumps(inspect_runner()))'),
      cancellation,
      limit: 8192,
    );
    if (!result.succeeded) throw const RunnerFailure(RunnerIssue.prerequisites);
    try {
      return RunnerInstallation.fromJson(decodeRunnerObject(result.output));
    } catch (_) {
      throw const RunnerFailure(RunnerIssue.invalidResponse);
    }
  }

  @override
  Future<RunnerInstallation> install(
    RunnerInstallation plan,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    if (!plan.supported) throw const RunnerFailure(RunnerIssue.prerequisites);
    if (plan.state == 'conflict') {
      throw const RunnerFailure(RunnerIssue.conflict);
    }
    if (plan.release != null &&
        plan.release != bundledRelease &&
        !plan.upgradable) {
      throw const RunnerFailure(RunnerIssue.incompatible);
    }
    final result = await _privileged(
      python(runnerInstaller),
      '{"fingerprint":${jsonEncode(plan.fingerprint)},"bundle":$runnerBundle}',
      cancellation,
      sudoPassword: sudoPassword,
      timeout: const Duration(minutes: 4),
    );
    if (!result.succeeded) throw const RunnerFailure(RunnerIssue.installFailed);
    try {
      final installed = RunnerInstallation.fromJson(
        decodeRunnerObject(result.output),
      );
      if (installed.release != bundledRelease || !installed.active) {
        throw const FormatException('install_not_confirmed');
      }
      return installed;
    } catch (_) {
      throw const RunnerFailure(RunnerIssue.installFailed);
    }
  }

  static String get _rpcDispatchCommand => python(
    "import os, glob, sys\n"
    "t = '/usr/local/lib/antirkn-runner/v58/runner.py'\n"
    "if os.path.exists(t):\n"
    "    os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', t, 'rpc'])\n"
    "def _v(x):\n"
    "    try: return int(x.split('/v')[1].split('/')[0])\n"
    "    except Exception: return 0\n"
    "candidates = sorted(glob.glob('/usr/local/lib/antirkn-runner/v*/runner.py'), key=_v)\n"
    "if candidates:\n"
    "    os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', candidates[-1], 'rpc'])\n"
    "sys.exit(1)",
  );

  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    validateRunnerRequest(request.json);
    final action = request.json['action'];
    final result = await _privileged(
      action == 'component_plan'
          ? python(runnerComponentInspector)
          : action == 'panel_plan'
          ? python(runnerPanelInspector)
          : _rpcDispatchCommand,
      jsonEncode(
        action == 'panel_verify'
            ? {...request.json, 'action': 'panel_access'}
            : request.json,
      ),
      cancellation,
      sudoPassword: sudoPassword,
    );
    try {
      final json = decodeRunnerObject(result.output);
      final response = RunnerResponse.fromJson(json);
      if (action == 'panel_verify' && response.code == 'ok') {
        final access = response.panelAccess;
        if (access == null || access.id != request.id) {
          return RunnerResponse.fromJson({...json, 'panelVerified': false});
        }
        if (access.managed) {
          try {
            await SshPanelApi(executor.client, access, cancellation).verify();
          } catch (_) {
            return RunnerResponse.fromJson({...json, 'panelVerified': false});
          }
        } else if (!response.panelVerified) {
          return RunnerResponse.fromJson({...json, 'panelVerified': false});
        }
        return RunnerResponse.fromJson({...json, 'panelVerified': true});
      }
      return response;
    } catch (_) {
      throw const RunnerFailure(RunnerIssue.invalidResponse);
    }
  }

  @override
  Future<void> emergencyReset(
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    try {
      await _privileged(
        python(
          "import sqlite3, subprocess, sys, json, os, glob\n"
          "try:\n"
          "    db = sqlite3.connect('/var/lib/antirkn-runner/jobs.sqlite')\n"
          "    db.execute(\"UPDATE jobs SET status='cancelled', cancel=1 WHERE status IN ('planned','running')\")\n"
          "    db.commit()\n"
          "    db.close()\n"
          "except Exception:\n"
          "    pass\n"
          "for p in glob.glob('/var/lib/antirkn-runner/connectivity-probes/*.json'):\n"
          "    try: os.unlink(p)\n"
          "    except Exception: pass\n"
          "for p in glob.glob('/var/lib/antirkn-runner/apt-*.started'):\n"
          "    try: os.unlink(p)\n"
          "    except Exception: pass\n"
          "for p in glob.glob('/var/lib/antirkn-runner/xray-upgrades/*/state.json'):\n"
          "    try:\n"
          "        data = json.loads(open(p).read())\n"
          "        if data.get('phase') not in ('committed', 'rolled_back', 'not_changed'):\n"
          "            data['phase'] = 'rolled_back'\n"
          "            data['code'] = 'cancelled'\n"
          "            open(p, 'w').write(json.dumps(data))\n"
          "    except Exception: pass\n"
          "subprocess.run(['systemctl', 'restart', 'antirkn-runner.service'], check=False)\n"
          "print('__ANTIRKN_RUNNER_INPUT__', file=sys.stderr, flush=True)\n"
          "print(json.dumps({'version': 1, 'code': 'ok', 'alive': True, 'jobs': []}))",
        ),
        '{}',
        cancellation,
        sudoPassword: sudoPassword,
      );
    } catch (_) {}
  }

  Future<RemoteCommandResult> _privileged(
    String command,
    String input,
    CancellationToken cancellation, {
    String? sudoPassword,
    Duration? timeout,
  }) async {
    var uid = _sessionUid;
    if (uid == null) {
      final result = await executor.execute('id -u', cancellation, limit: 128);
      if (!result.succeeded ||
          !RegExp(r'^[0-9]+$').hasMatch(result.output.trim())) {
        throw const SshFailure(SshIssue.commandFailed);
      }
      uid = result.output.trim();
      _sessionUid = uid;
    }
    final root = uid == '0';
    if (!root && !validSudoPassword(sudoPassword)) {
      throw const SshFailure(SshIssue.invalidSudoPassword);
    }
    final secret = !root && sudoPassword?.isNotEmpty == true
        ? sudoPassword
        : null;
    final result = await executor.execute(
      root
          ? command
          : PrivilegeRunner.command(command, withPassword: secret != null),
      cancellation,
      sudoPassword: secret,
      input: Uint8List.fromList(utf8.encode(input)),
      inputPrompt: '__ANTIRKN_RUNNER_INPUT__',
      timeout: timeout,
      limit: 4 * 1024 * 1024,
    );
    if (!result.succeeded && !result.inputSent) {
      if (root) throw const RunnerFailure(RunnerIssue.unavailable);
      throw SshFailure(switch (sudoFailureStatus(result)) {
        PrivilegeStatus.passwordRequired => SshIssue.sudoPasswordRequired,
        PrivilegeStatus.authenticationFailed =>
          SshIssue.sudoAuthenticationFailed,
        PrivilegeStatus.terminalRequired => SshIssue.sudoTerminalRequired,
        PrivilegeStatus.unavailable => SshIssue.sudoUnavailable,
        _ => SshIssue.sudoDenied,
      });
    }
    return result;
  }
}
