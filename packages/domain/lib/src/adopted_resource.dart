/// Imported resources keep their server configuration; only client access and
/// public connection coordinates participate in the desired document.
void validateAdoptedResource(Map spec) {
  if (['', '0.0.0.0', '::'].contains(spec['endpoint']) ||
      spec['deleted'] == true && spec['enabled'] == true) {
    throw const FormatException('vpn_invalid');
  }
}
