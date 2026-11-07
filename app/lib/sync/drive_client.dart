import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Gives the access token for the user's Drive. With [renew], the last one
/// was refused, so it must not be reused.
typedef TokenSource = Future<String> Function({bool renew});

class DriveFile {
  const DriveFile({
    required this.id,
    required this.name,
    required this.modified,
    this.description = '',
  });

  final String id;
  final String name;

  /// Drive's own time of the last change, compared as it is: only Drive's
  /// clock matters, not the device's.
  final String modified;
  final String description;

  static DriveFile fromJson(Map<String, dynamic> j) => DriveFile(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    modified: j['modifiedTime'] as String? ?? '',
    description: j['description'] as String? ?? '',
  );
}

class DriveException implements Exception {
  DriveException(this.status, this.message);

  final int status;
  final String message;

  bool get notFound => status == 404;

  /// The user's Google storage has no room left.
  bool get storageFull =>
      status == 403 && message.contains('storageQuotaExceeded');

  @override
  String toString() => 'Drive $status: $message';
}

/// How much of the user's Google storage is in use, in bytes. It is shared
/// with Gmail and Photos. [limit] is null when the account has none.
class DriveQuota {
  const DriveQuota(this.used, this.limit);

  final int used;
  final int? limit;

  double? get share {
    final l = limit;
    return l == null || l <= 0 ? null : (used / l).clamp(0.0, 1.0);
  }

  /// Bytes still free, or null when there is no limit.
  int? get left {
    final l = limit;
    return l == null ? null : (l - used).clamp(0, l);
  }

  /// Little enough room left to warn about.
  bool get nearlyFull => (share ?? 0) >= 0.95;
  bool get full => (share ?? 0) >= 0.999;

  static DriveQuota fromJson(Map<String, dynamic> j) {
    int? n(Object? v) => v == null ? null : int.tryParse('$v');
    return DriveQuota(n(j['usage']) ?? 0, n(j['limit']));
  }
}

/// The app's private folder in the user's Drive (appDataFolder): the user's
/// own files stay out of reach of the app, and this folder out of their way.
class DriveClient {
  DriveClient(this._token, {http.Client? client, this.retryDelay = _doubling})
    : _client = client ?? http.Client();

  final TokenSource _token;
  final http.Client _client;

  /// How long to wait before attempt [n] of a request Drive turned away for
  /// now.
  final Duration Function(int n) retryDelay;

  static Duration _doubling(int n) => Duration(seconds: 1 << n);
  static const _attempts = 4;

  static const _api = 'https://www.googleapis.com/drive/v3/files';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';
  static const _fields = 'id,name,modifiedTime,description';

  /// Sends a request built by [make], once more with a new token if the one
  /// in use is refused, and again after a pause while Drive is busy.
  Future<http.StreamedResponse> _send(
    http.BaseRequest Function(String token) make,
  ) async {
    for (var n = 1; ; n++) {
      var r = await _client.send(make(await _token()));
      if (r.statusCode == 401) {
        await r.stream.drain<void>();
        r = await _client.send(make(await _token(renew: true)));
      }
      final busy = r.statusCode == 429 || r.statusCode >= 500;
      final limited = r.statusCode == 403;
      if (!busy && !limited) return r;
      final body = await r.stream.toBytes();
      final tryAgain =
          n < _attempts &&
          (busy ||
              utf8.decode(body, allowMalformed: true).contains('ateLimit'));
      if (!tryAgain) {
        return http.StreamedResponse(
          Stream.value(body),
          r.statusCode,
          headers: r.headers,
        );
      }
      await Future<void>.delayed(retryDelay(n));
    }
  }

  Future<http.Response> _call(
    http.BaseRequest Function(String token) make,
  ) async {
    final r = await http.Response.fromStream(await _send(make));
    if (r.statusCode >= 300) throw DriveException(r.statusCode, r.body);
    return r;
  }

  http.Request _request(String method, Uri url, String token) =>
      http.Request(method, url)..headers['Authorization'] = 'Bearer $token';

  /// The account's storage, or null when Google does not say.
  Future<DriveQuota?> quota() async {
    final url = Uri.parse('https://www.googleapis.com/drive/v3/about')
        .replace(queryParameters: {'fields': 'storageQuota'});
    final r = await _call((t) => _request('GET', url, t));
    final q = (jsonDecode(r.body) as Map<String, dynamic>)['storageQuota'];
    return q is Map<String, dynamic> ? DriveQuota.fromJson(q) : null;
  }

  Future<List<DriveFile>> list() async {
    final out = <DriveFile>[];
    String? page;
    do {
      final url = Uri.parse(_api).replace(
        queryParameters: {
          'spaces': 'appDataFolder',
          'pageSize': '1000',
          'fields': 'nextPageToken,files($_fields)',
          'pageToken': ?page,
        },
      );
      final r = await _call((t) => _request('GET', url, t));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      out.addAll(
        (j['files'] as List).map(
          (e) => DriveFile.fromJson(e as Map<String, dynamic>),
        ),
      );
      page = j['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }

  Uri _media(String id) =>
      Uri.parse('$_api/$id').replace(queryParameters: {'alt': 'media'});

  Future<Uint8List> download(String id) async =>
      (await _call((t) => _request('GET', _media(id), t))).bodyBytes;

  Future<void> downloadTo(String id, File target) async {
    final r = await _send((t) => _request('GET', _media(id), t));
    if (r.statusCode >= 300) {
      final body = await r.stream.bytesToString();
      throw DriveException(r.statusCode, body);
    }
    await r.stream.pipe(target.openWrite());
  }

  /// Creates a file, or replaces the one with [id], from [bytes].
  Future<DriveFile> upload({
    String? id,
    required String name,
    required String description,
    required Uint8List bytes,
  }) async {
    const boundary = 'nots_part_boundary_7f3a';
    final meta = jsonEncode({
      'name': name,
      'description': description,
      if (id == null) 'parents': ['appDataFolder'],
    });
    final body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$meta\r\n'
          '--$boundary\r\n'
          'Content-Type: application/octet-stream\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final payload = body.takeBytes();
    final url = Uri.parse(
      id == null ? _upload : '$_upload/$id',
    ).replace(queryParameters: {'uploadType': 'multipart', 'fields': _fields});
    final r = await _call(
      (t) => _request(id == null ? 'POST' : 'PATCH', url, t)
        ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
        ..bodyBytes = payload,
    );
    return DriveFile.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Creates a file from a large [file], without holding it in memory.
  Future<DriveFile> uploadFile({
    required String name,
    required String description,
    required File file,
  }) async {
    final size = await file.length();
    final url = Uri.parse(
      _upload,
    ).replace(queryParameters: {'uploadType': 'resumable', 'fields': _fields});
    final start = await _call(
      (t) => _request('POST', url, t)
        ..headers['Content-Type'] = 'application/json; charset=UTF-8'
        ..headers['X-Upload-Content-Length'] = '$size'
        ..body = jsonEncode({
          'name': name,
          'description': description,
          'parents': ['appDataFolder'],
        }),
    );
    final session = Uri.parse(start.headers['location']!);
    final r = await http.Response.fromStream(
      await _client.send(
        http.StreamedRequest('PUT', session)
          ..contentLength = size
          ..headers['Content-Type'] = 'application/octet-stream'
          ..let(
            (q) => file.openRead().listen(
              q.sink.add,
              onDone: q.sink.close,
              onError: q.sink.addError,
            ),
          ),
      ),
    );
    if (r.statusCode >= 300) throw DriveException(r.statusCode, r.body);
    return DriveFile.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> delete(String id) async {
    try {
      await _call((t) => _request('DELETE', Uri.parse('$_api/$id'), t));
    } on DriveException catch (e) {
      if (!e.notFound) rethrow;
    }
  }
}

extension<T> on T {
  T let(void Function(T) f) {
    f(this);
    return this;
  }
}
