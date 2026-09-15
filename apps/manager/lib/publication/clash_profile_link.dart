/// Clash Mi and Clash Meta accept this common remote-profile import scheme.
/// Clash Mi's import form defaults to 24 hours. Its scheme handler does not
/// accept an interval parameter; adding one would not configure the client.
Uri clashProfileLink(String downloadUrl, {String name = ''}) {
  final url = Uri.parse(downloadUrl);
  if (url.scheme != 'https' || url.host.isEmpty || url.userInfo.isNotEmpty) {
    throw const FormatException('invalid_profile_link');
  }
  return Uri(
    scheme: 'clash',
    host: 'install-config',
    queryParameters: {
      'url': downloadUrl,
      if (name.trim().isNotEmpty) 'name': name.trim(),
    },
  );
}
