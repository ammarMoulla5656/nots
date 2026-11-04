import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nots/book/book_link_store.dart';
import 'package:nots/ink/ink_store.dart';
import 'package:nots/ink/stroke.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/reader/reader_prefs.dart';
import 'package:nots/sync/drive_client.dart';
import 'package:nots/sync/google_account.dart';
import 'package:nots/sync/sync_engine.dart';
import 'package:path/path.dart' as p;

/// The Drive REST API, in memory, as far as the app uses it.
class FakeDrive {
  final files = <String, ({String name, String description, Uint8List body, String time})>{};
  int _clock = 0;
  int _nextId = 0;
  int uploads = 0;
  int refusedTokens = 0;
  String goodToken = 'good';

  String _now() => '2026-11-05T10:00:${(++_clock).toString().padLeft(2, '0')}.000Z';

  Map<String, Object> _json(String id) {
    final f = files[id]!;
    return {'id': id, 'name': f.name, 'description': f.description, 'modifiedTime': f.time};
  }

  http.Response _ok(Object j) => http.Response(
    jsonEncode(j),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  void _store(String? id, Map<String, dynamic> meta, Uint8List body) {
    uploads++;
    final key = id ?? 'f${_nextId++}';
    files[key] = (
      name: meta['name'] as String? ?? files[key]!.name,
      description: meta['description'] as String? ?? '',
      body: body,
      time: _now(),
    );
    lastId = key;
  }

  String lastId = '';

  /// Splits the two parts of a multipart/related body.
  (Map<String, dynamic>, Uint8List) _multipart(http.Request r) {
    final boundary = r.headers['content-type']!.split('boundary=').last;
    final bytes = r.bodyBytes;
    final text = latin1.decode(bytes);
    final first = text.indexOf('\r\n\r\n') + 4;
    final metaEnd = text.indexOf('\r\n--$boundary', first);
    final meta = jsonDecode(utf8.decode(bytes.sublist(first, metaEnd)));
    final mediaStart = text.indexOf('\r\n\r\n', metaEnd) + 4;
    final mediaEnd = text.lastIndexOf('\r\n--$boundary--');
    return (meta as Map<String, dynamic>, bytes.sublist(mediaStart, mediaEnd));
  }

  late final client = MockClient((r) async {
    if (r.headers['Authorization'] != 'Bearer $goodToken' &&
        r.url.host == 'www.googleapis.com' &&
        !r.url.path.startsWith('/session')) {
      refusedTokens++;
      return http.Response('no', 401);
    }
    final path = r.url.path;
    if (r.method == 'GET' && path == '/drive/v3/files') {
      expect(r.url.queryParameters['spaces'], 'appDataFolder');
      return _ok({'files': [for (final id in files.keys) _json(id)]});
    }
    if (r.method == 'GET' && path.startsWith('/drive/v3/files/')) {
      final f = files[p.basename(path)];
      if (f == null) return http.Response('gone', 404);
      return http.Response.bytes(f.body, 200);
    }
    if (r.method == 'DELETE') {
      return files.remove(p.basename(path)) == null
          ? http.Response('gone', 404)
          : http.Response('', 204);
    }
    if (path == '/upload/drive/v3/files' && r.url.queryParameters['uploadType'] == 'resumable') {
      _pending = jsonDecode(r.body) as Map<String, dynamic>;
      return http.Response('', 200, headers: {'location': 'https://www.googleapis.com/session/1'});
    }
    if (r.method == 'PUT' && path == '/session/1') {
      _store(null, _pending, r.bodyBytes);
      return _ok(_json(lastId));
    }
    if (path.startsWith('/upload/drive/v3/files')) {
      final id = r.method == 'PATCH' ? p.basename(path) : null;
      if (id != null && !files.containsKey(id)) return http.Response('gone', 404);
      final (meta, body) = _multipart(r);
      if (id == null) expect(meta['parents'], ['appDataFolder']);
      _store(id, meta, body);
      return _ok(_json(lastId));
    }
    return http.Response('unexpected ${r.method} ${r.url}', 500);
  });

  Map<String, dynamic> _pending = {};

  Iterable<String> get names => files.values.map((f) => f.name);
}

/// One installation of the app: its own storage, sharing a [drive].
class Device {
  Device(this.root, this.lib, this.sync);

  final Directory root;
  final LibraryStore lib;
  final SyncEngine sync;

  void activate() {
    InkStore.dirProvider = () async => Directory(p.join(root.path, 'ink'));
    ReaderPrefs.dirProvider = () async => Directory(p.join(root.path, 'prefs'));
    BookLinkStore.dirProvider = () async => Directory(p.join(root.path, 'links'));
  }

  static Future<Device> install(Directory base, String name, FakeDrive drive) async {
    final root = Directory(p.join(base.path, name));
    await root.create(recursive: true);
    final lib = await LibraryStore.openAt(root);
    final sync = SyncEngine(
      lib,
      isLinked: () => true,
      drive: () => DriveClient(({renew = false}) async => drive.goodToken, client: drive.client),
    );
    return Device(root, lib, sync)..activate();
  }
}

Stroke _stroke(int id) => Stroke(
  id: id,
  tool: InkTool.pen,
  color: 0xFF000000,
  width: 1,
  points: const [StrokePoint(1, 1, 0.5, 0), StrokePoint(9, 9, 0.5, 5)],
);

Future<void> _write(String bookId, int page) async {
  final s = await InkStore.open(bookId);
  s.document.add(page, _stroke(s.document.nextStrokeId));
  await s.dispose();
}

Future<int> _strokes(String bookId, int page) async {
  final s = await InkStore.open(bookId);
  final n = s.document.strokesOf(page).length;
  await s.dispose();
  return n;
}

void main() {
  late Directory base;
  late FakeDrive drive;
  late File source;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('nots_sync_');
    drive = FakeDrive();
    source = File(p.join(base.path, 'book.pdf'));
    await source.writeAsBytes(List.generate(5000, (i) => (i * 7) & 0xFF));
  });
  tearDown(() async => base.delete(recursive: true));

  Future<BookEntry> download(Device d) async {
    final e = await d.lib.importPdf(source.path, title: 'الكافي - الجزء 1');
    await d.lib.linkCatalog(e, catalogId: 'b1', part: 1, title: 'الكافي - الجزء 1', author: 'الكليني');
    return e;
  }

  const place = ReadingPosition(page: 42, fx: 0.31, fy: 0.77, zoom: 2.5, fit: 1.1);

  Future<void> savePlace(String id) async {
    final prefs = await ReaderPrefs.open(id);
    prefs.setPosition(place);
    prefs.toggleBookmark(42);
    await prefs.flush();
    prefs.dispose();
  }

  test('reinstalling: the books appear, and download with all the work', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await download(a);
    await _write(book.id, 3);
    await savePlace(book.id);
    await a.sync.syncNow();
    expect(a.sync.lastError, isNull);
    expect(drive.names, ['book-${book.id}.zip']); // the work only, not the PDF

    // The app was deleted: nothing of the old storage is left.
    final b = await Device.install(base, 'b', drive);
    expect(b.lib.books, isEmpty);
    await b.sync.syncNow();
    final listed = b.sync.remoteOnly.single;
    expect(listed.title, 'الكافي - الجزء 1');
    expect(listed.catalogId, 'b1');
    expect(listed.part, 1);
    expect(await InkStore.hasWriting(book.id), isFalse);

    final again = await download(b);
    await b.sync.afterImport(again);
    expect(b.sync.lastError, isNull);
    expect(await _strokes(again.id, 3), 1);
    final prefs = await ReaderPrefs.open(again.id);
    expect(prefs.position, place);
    expect(prefs.isBookmarked(42), isTrue);
    prefs.dispose();
    expect(b.sync.remoteOnly, isEmpty);
  });

  test('a new edition on the server still receives the work', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await download(a);
    await _write(book.id, 3);
    await a.sync.syncNow();

    final b = await Device.install(base, 'b', drive);
    await b.sync.syncNow();
    await source.writeAsBytes(List.generate(6000, (i) => (i * 11) & 0xFF));
    final edition = await download(b);
    expect(edition.id, isNot(book.id));
    await b.sync.afterImport(edition);
    expect(await _strokes(edition.id, 3), 1);

    // The next change replaces the old file; no second copy appears.
    await _write(edition.id, 4);
    await b.sync.syncNow();
    expect(drive.names, ['book-${edition.id}.zip']);
  });

  test('a book only read stays out of Drive', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await download(a);
    final prefs = await ReaderPrefs.open(book.id);
    prefs.setPosition(place); // read, but nothing written or bookmarked
    await prefs.flush();
    prefs.dispose();
    await a.sync.syncNow();
    expect(drive.files, isEmpty);
  });

  test('a book added from a file keeps its PDF in Drive too', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await a.lib.importPdf(source.path, title: 'ملفي');
    await _write(book.id, 1);
    await a.sync.syncNow();
    expect(drive.names, unorderedEquals(['book-${book.id}.zip', 'pdf-${book.id}.pdf']));

    final b = await Device.install(base, 'b', drive);
    await b.sync.syncNow();
    final listed = b.sync.remoteOnly.single;
    expect(listed.pdfFile, isNotNull);
    final back = await b.sync.restoreFromDrive(listed);
    expect(back.id, book.id);
    expect(back.title, 'ملفي');
    expect(await _strokes(back.id, 1), 1);
  });

  test('nothing is sent again while nothing changed', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await download(a);
    await _write(book.id, 1);
    await a.sync.syncNow();
    final sent = drive.uploads;
    await a.sync.syncNow();
    expect(drive.uploads, sent);
    await _write(book.id, 2);
    await a.sync.syncNow();
    expect(drive.uploads, sent + 1);
    expect(drive.files.length, 1);
  });

  test('writing on one device reaches the other', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await download(a);
    await _write(book.id, 1);
    await a.sync.syncNow();

    final b = await Device.install(base, 'b', drive);
    final same = await download(b);
    await b.sync.afterImport(same);
    await _write(same.id, 2);
    await b.sync.syncNow();

    a.activate();
    await a.sync.syncNow();
    expect(await _strokes(book.id, 2), 1);
  });

  test('when both devices changed a book, no writing is lost', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await download(a);
    await _write(book.id, 1);
    await a.sync.syncNow();

    final b = await Device.install(base, 'b', drive);
    final same = await download(b);
    await b.sync.afterImport(same);
    await _write(same.id, 2);
    await b.sync.syncNow();

    a.activate();
    await _write(book.id, 3); // changed here too, before hearing of the other
    final older = File(p.join(a.root.path, 'ink', '${book.id}.nots'));
    await older.setLastModified(DateTime(2020));
    await a.sync.syncNow();
    expect(await _strokes(book.id, 2), 1); // Drive was newer: it won
    final kept = Directory(p.join(a.root.path, 'ink'))
        .listSync()
        .where((e) => e.path.contains('.older-'));
    expect(kept.length, 1); // and this device's version is kept beside it
  });

  test('newer writing here is not overwritten when re-adding the file', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await download(a);
    await _write(book.id, 1);
    await a.sync.syncNow();
    await _write(book.id, 2);
    await File(p.join(a.root.path, 'ink', '${book.id}.nots'))
        .setLastModified(DateTime.now().add(const Duration(hours: 1)));
    await a.sync.afterImport(book);
    expect(await _strokes(book.id, 2), 1);
  });

  test('the book open in the reader is left alone', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await download(a);
    await _write(book.id, 1);
    a.sync.openBook = book.id;
    await a.sync.syncNow();
    expect(drive.files, isEmpty);
    a.sync.openBook = null;
    await a.sync.syncNow();
    expect(drive.files.length, 1);
  });

  test('deleting the work removes it from Drive', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await a.lib.importPdf(source.path, title: 'ملفي');
    await _write(book.id, 1);
    await a.sync.syncNow();
    expect(drive.files.length, 2);
    await a.sync.forget(book.id);
    expect(drive.files, isEmpty);
  });

  test('a file removed from Drive is sent again', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await download(a);
    await _write(book.id, 1);
    await a.sync.syncNow();
    drive.files.clear();
    await a.sync.syncNow();
    expect(drive.names, ['book-${book.id}.zip']);
  });

  test('a refused token is renewed once', () async {
    var renewed = 0;
    final client = DriveClient(({renew = false}) async {
      if (renew) renewed++;
      return renew ? drive.goodToken : 'stale';
    }, client: drive.client);
    expect(await client.list(), isEmpty);
    expect(drive.refusedTokens, 1);
    expect(renewed, 1);
  });

  test('losing the connection is reported, not thrown', () async {
    final a = await Device.install(base, 'a', drive);
    final sync = SyncEngine(
      a.lib,
      isLinked: () => true,
      drive: () => DriveClient(
        ({renew = false}) async => 't',
        client: MockClient((_) async => throw http.ClientException('down')),
      ),
    );
    await sync.syncNow();
    expect(sync.lastError, isNotNull);
    expect(sync.running, isFalse);
  });

  test('sign-in helpers', () {
    // The example of RFC 7636.
    expect(
      pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
    final payload = base64Url.encode(utf8.encode('{"email":"a@b.c"}')).replaceAll('=', '');
    expect(emailOfIdToken('h.$payload.s'), 'a@b.c');
    expect(emailOfIdToken('nonsense'), isNull);
    expect(emailOfIdToken(null), isNull);
  });
}
