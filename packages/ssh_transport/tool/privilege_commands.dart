import 'dart:convert';
import 'package:antirkn_ssh_transport/src/inventory_probes.dart';
import 'package:antirkn_ssh_transport/src/privilege_runner.dart';

void main() => print(
  jsonEncode(
    {
      'id -u',
      '${InventoryProbes.prefix}command -v sudo >/dev/null 2>&1',
      'cat /etc/os-release',
      'uname -m',
      'ip -j -details address show',
      'ip -j -4 route show table all',
      'ip -j -6 route show table all',
      'ip -j -4 rule show',
      'ip -j -6 rule show',
      ...InventoryProbes.allowedCommands,
      for (final withPassword in [false, true]) ...{
        PrivilegeRunner.command('/usr/bin/id -u', withPassword: withPassword),
        for (final read in InventoryProbes.allowedCommands.where(
          InventoryProbes.canElevate,
        ))
          PrivilegeRunner.command(
            PrivilegeRunner.shellRead(read),
            withPassword: withPassword,
          ),
      },
    }.toList(),
  ),
);
