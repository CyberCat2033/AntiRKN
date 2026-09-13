// Emits only the fixed, public commands used by the read-only inventory adapter.
import 'dart:convert';
import 'package:antirkn_ssh_transport/src/inventory_probes.dart';

void main() => print(jsonEncode(InventoryProbes.allowedCommands.toList()));
