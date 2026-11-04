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

  @override
  String toString() => 'Drive $status: $message';
}

/// The app's private folder in the user's Drive (appDataFolder): the user's
/// own files stay out of reach of the app, and this folder out of their way.
class DriveClient {
  DriveClient(this._token, {http.Client? client})
    : _client = client ?? http.Client();

  final TokenSource _token;
  final http.Client _client;

  static const _api = 'https://www.googleapis.com/drive/v3/files';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';
  static const _fields = 'id,name,modifiedTime,description';

  /// Sends a request built by [make], once more with a new token if the one
  /// in use is refused.
  Future<http.StreamedResponse> _send(
    http.BaseRequest Function(String token) make,
  ) async {
    var r = await _client.send(make(await _token()));
    if (r.statusCode == 401) {
      await r.stream.drain<void>();
      r = await _client.send(make(await _token(renew: true)));
    }
    return r;
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
    final url = Uri.parse(id == null ? _upload : '$_upload/$id').replace(
      queryParameters: {'uploadType': 'multipart', 'fields': _fields},
    );
    final r = await _call(
      (t) =>
          _request(id == null ? 'POST' : 'PATCH', url, t)
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
    final url = Uri.parse(_upload).replace(
      queryParameters: {'uploadType': 'resumable', 'fields': _fields},
    );
    final start = await _call(
      (t) =>
          _request('POST', url, t)
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
          ..let((q) => file.openRead().listen(
            q.sink.add,
            onDone: q.sink.close,
            onError: q.sink.addError,
          )),
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
