import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
