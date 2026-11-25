import 'dart:async';

/// One in-memory bearer token for every Drive caller of an account. While it
/// is fresh it is returned at once; callers arriving during a renewal await
/// that renewal instead of starting their own. Never persisted.
final class SharedAccessToken {
  SharedAccessToken({
    DateTime Function()? now,
    this.margin = const Duration(seconds: 60),
  }) : _now = now ?? DateTime.now;
  final DateTime Function() _now;

  /// A token closer than this to its expiry is renewed.
  final Duration margin;
  String? _value;
  DateTime? _expires;
  Future<String>? _renewal;
  int _generation = 0;

  String? get fresh =>
      _value != null && _expires!.isAfter(_now().add(margin)) ? _value : null;

  void remember(String token, DateTime expires) {
    _value = token;
    _expires = expires;
  }

  /// Forgets [rejected] (any token when null) so the next caller renews.
  void invalidate([String? rejected]) {
    if (rejected == null || rejected == _value) {
      _value = null;
      _expires = null;
    }
  }

  /// The account changed: drop the token and detach a running renewal.
  void clear() {
    _generation++;
    _value = null;
    _expires = null;
    _renewal = null;
  }

  /// [renew] runs once for all concurrent callers. Its token is kept unless
  /// [clear] was called while it ran.
  Future<String> get(Future<(String, DateTime)> Function() renew) {
    final cached = fresh;
    if (cached != null) return Future.value(cached);
    return _renewal ??= () async {
      final generation = _generation;
      try {
        final (token, expires) = await renew();
        if (generation == _generation) remember(token, expires);
        return token;
      } finally {
        if (generation == _generation) _renewal = null;
      }
    }();
  }
}
