import 'package:flutter/material.dart';

/// The one icon of a protocol and of the component that serves it, so a
/// protocol looks the same on the server page and in the software list.
/// [component] is a release key: `panel` and `xray` (VLESS through 3x-ui
/// and its Xray core), `trusttunnel`, `amneziawg`.
IconData protocolIcon(String component) => switch (component) {
  'panel' || 'xray' => Icons.hub_outlined,
  'trusttunnel' => Icons.vpn_lock_outlined,
  'amneziawg' => Icons.vpn_key_outlined,
  _ => Icons.extension_outlined,
};
