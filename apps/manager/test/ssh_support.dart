import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';

import 'network_support.dart';

class FakeVault implements SecretVault {
  VaultMode? mode;
  bool unlocked = false;
  SshProfile? saved;
  bool failWrite = false;
  int writes = 0;
  @override
  bool get isUnlocked => unlocked;
  @override
  Future<VaultMode?> inspect() async => mode;
  @override
  Future<void> create(VaultMode mode, {String? password}) async {
    this.mode = mode;
    unlocked = true;
  }

  @override
  Future<void> unlock({String? password}) async {
    unlocked = true;
  }

  @override
  SshProfile? get profile {
    if (!unlocked) throw const VaultFailure(VaultIssue.locked);
    return saved;
  }

  @override
  Future<void> saveProfile(SshProfile? profile) async {
    if (!unlocked) throw const VaultFailure(VaultIssue.locked);
    if (failWrite) throw const VaultFailure(VaultIssue.writeFailed);
    saved = profile;
    writes++;
  }

  @override
  void lock() {
    unlocked = false;
  }
}

class FakeKeyPicker implements PrivateKeyFilePicker {
  Future<ImportedPrivateKey?> Function() callback = () async => null;
  @override
  Future<ImportedPrivateKey?> pick() => callback();
}

class FakeConnection implements SshConnection {
  int reads = 0;
  bool closed = false;
  final ended = Completer<void>();
  Future<ServerObservation> Function()? reader;
  @override
  Future<void> get done => ended.future;
  @override
  Future<ServerObservation> observe(CancellationToken cancellation) async {
    reads++;
    cancellation.check();
    return reader == null
        ? ServerObservation(
            os: 'Ubuntu 24.04',
            architecture: 'x86_64',
            network: testInventory(),
          )
        : reader!();
  }

  @override
  void close() {
    closed = true;
    if (!ended.isCompleted) ended.complete();
  }
}

class FakeConnector implements SshConnector {
  TrustedHostKey key = const TrustedHostKey('ssh-ed25519', 'SHA256:fixture');
  FakeConnection connection = FakeConnection();
  int authentications = 0;
  int calls = 0;
  @override
  Future<SshConnection> connect(
    SshProfile profile, {
    required Future<bool> Function(TrustedHostKey) verifyHostKey,
    required CancellationToken cancellation,
  }) async {
    calls++;
    if (!await cancellation.bind(verifyHostKey(key))) {
      throw const SshFailure(SshIssue.hostKeyRejected);
    }
    cancellation.check();
    authentications++;
    return connection;
  }
}

SshController controller(
  FakeVault vault,
  FakeConnector connector, {
  FakeKeyPicker? picker,
  Duration? idleTimeout,
}) => SshController(
  openVault: () async => vault,
  connector: connector,
  picker: picker ?? FakeKeyPicker(),
  network: NetworkController(
    reader: TestInventoryReader(() async => testInventory()),
  ),
  idleTimeout: idleTimeout ?? const Duration(minutes: 5),
);

Future<void> prepare(SshController c) async {
  await c.initialise();
  await c.open(createMode: VaultMode.system);
  c.host.text = 'fixture.example';
  c.port.text = '22';
  c.username.text = 'root';
  c.password.text = 'fixture-password-only';
}
