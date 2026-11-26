import 'dart:math';

/// 15 Fullmetal Alchemist characters used for hardened user accounts.
const List<String> fmaUsernames = <String>[
  'edward',
  'alphonse',
  'elric',
  'mustang',
  'hawkeye',
  'armstrong',
  'hughes',
  'scar',
  'winry',
  'rockbell',
  'bradley',
  'greed',
  'envy',
  'ling',
  'hohenheim',
];

/// Selects a random FMA username.
String randomFmaUsername([Random? random]) {
  final r = random ?? Random();
  return fmaUsernames[r.nextInt(fmaUsernames.length)];
}

/// Generates a random ASCII sudo password satisfying [validSudoPassword].
String randomSudoPassword([Random? random, int length = 20]) {
  if (length < 4 || length > 1024) {
    throw RangeError.range(length, 4, 1024, 'length');
  }
  const lower = 'abcdefghijkmnopqrstuvwxyz';
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const digits = '23456789';
  const symbols = '-_@#%^&*+=';
  const all = '$lower$upper$digits$symbols';
  final r = random ?? Random.secure();
  final chars = <String>[
    lower[r.nextInt(lower.length)],
    upper[r.nextInt(upper.length)],
    digits[r.nextInt(digits.length)],
    symbols[r.nextInt(symbols.length)],
    for (var i = 4; i < length; i++) all[r.nextInt(all.length)],
  ];
  for (var i = chars.length - 1; i > 0; i--) {
    final j = r.nextInt(i + 1);
    final tmp = chars[i];
    chars[i] = chars[j];
    chars[j] = tmp;
  }
  return chars.join();
}

/// Plan returned by runner RPC `ssh_harden_plan`.
final class SshHardenPlan {
  const SshHardenPlan({
    required this.supported,
    required this.currentPort,
    required this.currentRootLogin,
    required this.socketActivation,
    required this.proposedPort,
    required this.proposedUser,
    required this.portAvailable,
    required this.userAvailable,
    required this.fingerprint,
  });

  factory SshHardenPlan.fromJson(Map<String, dynamic> json) {
    return SshHardenPlan(
      supported: json['supported'] as bool? ?? false,
      currentPort: (json['currentPort'] as num?)?.toInt() ?? 22,
      currentRootLogin: json['currentRootLogin'] as String? ?? 'allowed',
      socketActivation: json['socketActivation'] as bool? ?? false,
      proposedPort: (json['proposedPort'] as num?)?.toInt() ?? 2222,
      proposedUser: json['proposedUser'] as String? ?? 'admin',
      portAvailable: json['portAvailable'] as bool? ?? true,
      userAvailable: json['userAvailable'] as bool? ?? true,
      fingerprint: json['fingerprint'] as String? ?? '',
    );
  }

  final bool supported;
  final int currentPort;
  final String currentRootLogin;
  final bool socketActivation;
  final int proposedPort;
  final String proposedUser;
  final bool portAvailable;
  final bool userAvailable;
  final String fingerprint;

  bool get isRootAllowed => currentRootLogin == 'allowed';

  Map<String, dynamic> toJson() => {
    'supported': supported,
    'currentPort': currentPort,
    'currentRootLogin': currentRootLogin,
    'socketActivation': socketActivation,
    'proposedPort': proposedPort,
    'proposedUser': proposedUser,
    'portAvailable': portAvailable,
    'userAvailable': userAvailable,
    'fingerprint': fingerprint,
  };
}

/// Payload sent in runner job submission for kind `ssh_harden`.
final class SshHardenSubmission {
  const SshHardenSubmission({
    required this.username,
    required this.port,
    required this.sudoPassword,
    this.publicKey,
    this.disableRootLogin = true,
    this.deadlineSeconds = 300,
  });

  final String username;
  final int port;
  final String sudoPassword;
  final String? publicKey;
  final bool disableRootLogin;
  final int deadlineSeconds;

  Map<String, dynamic> toJson() => {
    'username': username,
    'port': port,
    'sudoPassword': sudoPassword,
    if (publicKey != null && publicKey!.isNotEmpty) 'publicKey': publicKey,
    'disableRootLogin': disableRootLogin,
    'deadlineSeconds': deadlineSeconds,
  };
}

/// Result returned by `ssh_harden_confirm` or `ssh_harden_abort`.
final class SshHardenResult {
  const SshHardenResult({
    this.confirmed = false,
    this.aborted = false,
    this.finalized = false,
    this.phase = '',
    this.deadline,
    this.port,
    this.username,
  });

  factory SshHardenResult.fromJson(Map<String, dynamic> json) {
    return SshHardenResult(
      confirmed: json['confirmed'] as bool? ?? false,
      aborted: json['aborted'] as bool? ?? false,
      finalized: json['finalized'] as bool? ?? false,
      phase: json['phase'] as String? ?? '',
      deadline: json['deadline'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              ((json['deadline'] as num) * 1000).round(),
              isUtc: true,
            ),
      port: (json['port'] as num?)?.toInt(),
      username: json['username'] as String?,
    );
  }

  final bool confirmed;
  final bool aborted;
  final bool finalized;
  final String phase;
  final DateTime? deadline;
  final int? port;
  final String? username;
}
