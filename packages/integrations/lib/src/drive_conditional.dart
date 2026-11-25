/// Drive v3 has no ETag preconditions, so conditional writes of every Drive
/// adapter go through v2 with `If-Match`. A changed file answers 412 and is
/// left untouched.
abstract final class DriveConditional {
  static const preconditionFailed = 412;
  static final _etag = RegExp(r'^[\x20-\x7e]{1,1024}$');

  static Uri v2(
    String path, [
    Map<String, String>? query,
    bool upload = false,
  ]) => Uri.https(
    'www.googleapis.com',
    '${upload ? '/upload' : ''}/drive/v2/$path',
    query,
  );

  /// The precondition header, or null when [etag] cannot be sent safely.
  static Map<String, String>? ifMatch(String etag) =>
      _etag.hasMatch(etag) ? {'If-Match': etag} : null;
}
