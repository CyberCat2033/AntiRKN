import 'package:antirkn_domain/antirkn_domain.dart';

/// Recheck persisted conflicts immediately before every remote call, including
/// calls from controllers whose in-memory data predates an incoming change.
final class GuardedRunnerTransport implements RunnerTransport {
  const GuardedRunnerTransport(this.delegate, this.guard);
  final RunnerTransport delegate;
  final SyncEffectGuard guard;
  @override
  String get bundledRelease => delegate.bundledRelease;
  Future<void> _check(CancellationToken cancellation) async {
    await guard.checkSyncEffects();
    cancellation.check();
  }

  @override
  Future<RunnerInstallation> inspect(CancellationToken cancellation) async {
    await _check(cancellation);
    return delegate.inspect(cancellation);
  }

  @override
  Future<RunnerInstallation> install(
    RunnerInstallation plan,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    await _check(cancellation);
    return delegate.install(plan, cancellation, sudoPassword: sudoPassword);
  }

  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    if (request.json['action'] != 'status' &&
        request.json['action'] != 'list') {
      await _check(cancellation);
    } else {
      cancellation.check();
    }
    return delegate.request(request, cancellation, sudoPassword: sudoPassword);
  }
}
