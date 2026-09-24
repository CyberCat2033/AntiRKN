import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'controller uses the database identity before first VPN save and after reload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vpn-identity-test-',
      );
      final db = WorkspaceDatabase.open(
        '${directory.path}/test.sqlite',
        key: SecretKeyData(List.filled(32, 17)),
        offloadVpnWrites: true,
      );
      final controllers = <VpnController>[];
      addTearDown(() async {
        for (final controller in controllers) {
          controller.dispose();
        }
        await db.close();
        await directory.delete(recursive: true);
      });
      final identity = await db.readWorkspaceIdentity();
      for (var i = 0; i < 2; i++) {
        final controller = VpnController(
          repository: db,
          remote: (_) => null,
          template: () => '',
        );
        controllers.add(controller);
        await controller.load();
        expect(controller.error, isNull);
        expect(controller.loaded, isTrue);
        expect(controller.workspace.id, identity.workspaceId);
        expect(
          VpnWorkspace.decode((await db.readVpn()).source!).id,
          identity.workspaceId,
        );
        controller.dispose();
        controllers.remove(controller);
      }
      final changes = await db.readChanges();
      expect(
        changes
            .where((e) => e.header.entityKind == ChangeEntityKind.vpnWorkspace)
            .length,
        1,
      );
    },
  );

  test(
    'saving a client and its profile keeps the base document unchanged',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vpn-user-save-test-',
      );
      final path = '${directory.path}/test.sqlite';
      final db = WorkspaceDatabase.open(
        path,
        key: SecretKeyData(List.filled(32, 18)),
        offloadVpnWrites: true,
      );
      final controller = VpnController(
        repository: db,
        remote: (_) => null,
        template: () =>
            '{"proxies":[],"proxy-groups":[{"name":"ALL","type":"select","include-all-proxies":true}],"rules":["MATCH,ALL"]}',
      );
      addTearDown(() async {
        controller.dispose();
        await db.close();
        await directory.delete(recursive: true);
      });
      await controller.load();
      expect(controller.error, isNull);
      final initialRevision = controller.revision;
      await controller.saveUser(
        VpnUser(id: 'a' * 32, login: 'alice', name: 'Alice'),
      );
      expect(controller.error, isNull);
      expect(controller.revision, greaterThan(initialRevision));
      final raw = sqlite3.open(path);
      addTearDown(raw.dispose);
      expect(
        raw
            .select(
              "SELECT revision FROM documents WHERE id='vpn-workspace-v1'",
            )
            .single['revision'],
        initialRevision,
      );
      expect(
        raw.select('SELECT count(*) AS n FROM vpn_user_overlay').single['n'],
        1,
      );
      expect(controller.workspace.profiles['a' * 32]?['yaml'], isNotNull);
      expect(
        raw.select('SELECT count(*) AS n FROM vpn_profile_overlay').single['n'],
        1,
      );
      expect(
        VpnWorkspace.decode((await db.readVpn()).source!).users.single.login,
        'alice',
      );
    },
  );
}
