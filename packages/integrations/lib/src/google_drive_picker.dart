import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:antirkn_domain/antirkn_domain.dart';

/// A short-lived loopback page uses the existing file-scoped OAuth token.
/// Tokens are never placed in browser URLs, persisted or returned to the app UI.
final class GoogleDrivePicker implements PublicationFilePicker {
  GoogleDrivePicker({
    required this.tokens,
    required this.openBrowser,
    this.timeout = const Duration(minutes: 3),
  });
  final SyncAccessTokenProvider tokens;
  final Future<bool> Function(Uri) openBrowser;
  final Duration timeout;
  Completer<PublicationTarget?>? _pending;

  @override
  void cancel() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }

  @override
  Future<PublicationTarget?> pick({
    required String apiKey,
    required String appId,
  }) async {
    if (_pending != null) {
      throw const GoogleAccountFailure(GoogleAccountIssue.busy);
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{20,256}$').hasMatch(apiKey) ||
        !RegExp(r'^[0-9]{1,30}$').hasMatch(appId)) {
      throw const GoogleAccountFailure(GoogleAccountIssue.configuration);
    }
    final pending = Completer<PublicationTarget?>();
    _pending = pending;
    HttpServer? server;
    Timer? timer, accountTimer;
    // Attach the error handler before token/browser operations can be cancelled.
    final result = pending.future.then<Object?>(
      (value) => value,
      onError: (Object error) => error,
    );
    void fail(Object error) {
      if (!pending.isCompleted) pending.completeError(error);
    }

    try {
      final accountKey = tokens.accountKey;
      timer = Timer(
        timeout,
        () => fail(const PublicationFailure(PublicationIssue.network)),
      );
      final tokenOrEnd = await Future.any<Object?>([
        tokens.accessToken(),
        result,
      ]);
      if (pending.isCompleted) {
        final ended = await result;
        if (ended != null) throw ended;
        return null;
      }
      final token = tokenOrEnd as String;
      if (tokens.accountKey != accountKey) {
        throw const PublicationFailure(PublicationIssue.accountChanged);
      }
      final random = Random.secure();
      final nonce = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final path = '/picker/$nonce';
      final page = _page(
        token: token,
        apiKey: apiKey,
        appId: appId,
        callback: '$path/result',
      );
      accountTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        try {
          if (tokens.accountKey != accountKey) {
            fail(const PublicationFailure(PublicationIssue.accountChanged));
          }
        } catch (_) {
          fail(const PublicationFailure(PublicationIssue.accountChanged));
        }
      });
      server.listen(
        (request) async {
          try {
            final response = request.response;
            response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
            response.headers.set('Referrer-Policy', 'no-referrer');
            response.headers.set('X-Content-Type-Options', 'nosniff');
            response.headers.set(
              'Content-Security-Policy',
              "frame-ancestors 'none'",
            );
            if (pending.isCompleted ||
                request.headers.value('host') != '127.0.0.1:${server!.port}' ||
                request.uri.hasQuery) {
              response.statusCode = HttpStatus.notFound;
            } else if (request.method == 'GET' && request.uri.path == path) {
              response.headers.contentType = ContentType.html;
              response.write(page);
            } else if (request.method == 'POST' &&
                request.uri.path == '$path/result' &&
                request.headers.value('origin') == origin &&
                request.headers.contentType?.mimeType == 'application/json') {
              final bytes = <int>[];
              await for (final chunk in request) {
                bytes.addAll(chunk);
                if (bytes.length > 4096) throw const FormatException();
              }
              final data =
                  jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
              if (tokens.accountKey != accountKey) {
                throw const PublicationFailure(PublicationIssue.accountChanged);
              }
              if (data['action'] == 'cancel') {
                if (!pending.isCompleted) pending.complete(null);
              } else if (data['action'] == 'picked') {
                final target = PublicationTarget(
                  data['id'] as String,
                  resourceKey: data['resourceKey'] as String?,
                );
                if (!pending.isCompleted) pending.complete(target);
              } else {
                fail(const PublicationFailure(PublicationIssue.unavailable));
              }
              response.write('{}');
            } else {
              response.statusCode = HttpStatus.notFound;
            }
            await response.close();
          } catch (error) {
            request.response.statusCode = HttpStatus.badRequest;
            await request.response.close();
            if (error is PublicationFailure) fail(error);
          }
        },
        onError: (Object _) =>
            fail(const PublicationFailure(PublicationIssue.network)),
      );
      if (!pending.isCompleted &&
          !await openBrowser(Uri.parse('$origin$path'))) {
        fail(const GoogleAccountFailure(GoogleAccountIssue.unavailable));
      }
      final value = await result;
      if (value is PublicationTarget || value == null) {
        return value as PublicationTarget?;
      }
      throw value;
    } finally {
      timer?.cancel();
      accountTimer?.cancel();
      if (!pending.isCompleted) pending.complete(null);
      await server?.close(force: true);
      _pending = null;
    }
  }

  static String _page({
    required String token,
    required String apiKey,
    required String appId,
    required String callback,
  }) {
    String js(String value) => jsonEncode(value).replaceAll('<', r'\u003c');
    return '''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AntiRKN · Google Drive</title></head>
<body><p id="status">Google Drive</p><button id="cancel">Cancel / Отмена</button>
<script>
let completed=false;
async function finish(data){if(completed)return;completed=true;
 try{await fetch(${js(callback)},{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});
 document.getElementById('status').textContent='Return to AntiRKN / Вернитесь в AntiRKN';}catch(e){document.getElementById('status').textContent='Session ended / Сеанс завершён';}}
document.getElementById('cancel').onclick=()=>finish({action:'cancel'});
function ready(){gapi.load('picker',{callback:()=>{try{
const view=new google.picker.DocsView().setIncludeFolders(false).setSelectFolderEnabled(false);
const picker=new google.picker.PickerBuilder().setDeveloperKey(${js(apiKey)}).setAppId(${js(appId)}).setOAuthToken(${js(token)})
.setOrigin(location.origin).setTitle('AntiRKN · Google Drive').addView(view).setCallback(data=>{
 if(data.action===google.picker.Action.CANCEL)finish({action:'cancel'});
 if(data.action===google.picker.Action.PICKED){const doc=data[google.picker.Response.DOCUMENTS][0];finish({action:'picked',id:doc[google.picker.Document.ID],resourceKey:doc.resourceKey||null});}
}).build();picker.setVisible(true);
}catch(e){finish({action:'error'});}},onerror:()=>finish({action:'error'}),timeout:30000,ontimeout:()=>finish({action:'error'})});}
</script><script src="https://apis.google.com/js/api.js" onload="ready()" onerror="finish({action:'error'})"></script></body></html>''';
  }
}
