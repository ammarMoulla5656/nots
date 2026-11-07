import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nots/book/book_link_store.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/ink_store.dart';
import 'package:nots/ink/note_items.dart';
import 'package:nots/ink/stroke.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/reader/reader_prefs.dart';
import 'package:nots/sync/conflicts.dart';
import 'package:nots/sync/drive_client.dart';
import 'package:nots/sync/google_account.dart';
import 'package:nots/sync/merge.dart';
import 'package:nots/sync/sync_engine.dart';
import 'package:path/path.dart' as p;

/// The Drive REST API, in memory, as far as the app uses it.
class FakeDrive {
  final files =
      <
        String,
        ({String name, String description, Uint8List body, String time})
      >{};
  int _clock = 0;
  int _nextId = 0;
  int uploads = 0;
  int refusedTokens = 0;
  String goodToken = 'good';

  /// No room left: uploads are turned away the way Google does.
  bool full = false;

  /// No connection.
  bool down = false;

  /// Uploads of files with this start of a name fail.
  String? refuse;

  /// This many requests get "try again later".
  int busy = 0;

  int used = 10;
  int? limit = 1000;

  String _now() =>
      '2026-11-05T10:00:${(++_clock).toString().padLeft(2, '0')}.000Z';

  Map<String, Object> _json(String id) {
    final f = files[id]!;
    return {
      'id': id,
      'name': f.name,
      'description': f.description,
      'modifiedTime': f.time,
    };
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

  static const _fullBody =
      '{"error":{"errors":[{"reason":"storageQuotaExceeded"}],"code":403}}';

  late final client = MockClient((r) async {
    if (down) throw http.ClientException('down');
    if (busy > 0) {
      busy--;
      return http.Response('busy', 503);
    }
    if (r.url.path.startsWith('/upload') && r.method != 'GET') {
      if (full) return http.Response(_fullBody, 403);
      final named = r.url.queryParameters['uploadType'] == 'resumable'
          ? (jsonDecode(r.body) as Map)['name'] as String
          : latin1.decode(r.bodyBytes);
      if (refuse != null && named.contains(refuse!)) {
        return http.Response('no', 400);
      }
    }
    if (r.headers['Authorization'] != 'Bearer $goodToken' &&
        r.url.host == 'www.googleapis.com' &&
        !r.url.path.startsWith('/session')) {
      refusedTokens++;
      return http.Response('no', 401);
    }
    final path = r.url.path;
    if (path == '/drive/v3/about') {
      return _ok({
        'storageQuota': {'usage': '$used', 'limit': ?limit?.toString()},
      });
    }
    if (r.method == 'GET' && path == '/drive/v3/files') {
      expect(r.url.queryParameters['spaces'], 'appDataFolder');
      return _ok({
        'files': [for (final id in files.keys) _json(id)],
      });
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
    if (path == '/upload/drive/v3/files' &&
        r.url.queryParameters['uploadType'] == 'resumable') {
      _pending = jsonDecode(r.body) as Map<String, dynamic>;
      return http.Response(
        '',
        200,
        headers: {'location': 'https://www.googleapis.com/session/1'},
      );
    }
    if (r.method == 'PUT' && path == '/session/1') {
      _store(null, _pending, r.bodyBytes);
      return _ok(_json(lastId));
    }
    if (path.startsWith('/upload/drive/v3/files')) {
      final id = r.method == 'PATCH' ? p.basename(path) : null;
      if (id != null && !files.containsKey(id)) {
        return http.Response('gone', 404);
      }
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
  Device(this.root, this.lib);

  final Directory root;
  final LibraryStore lib;
  late final SyncEngine sync;
  late FakeDrive drive;
  String? email;

  /// Signs in to another account.
  void use(FakeDrive d, String mail) {
    drive = d;
    email = mail;
  }

  void activate() {
    InkStore.dirProvider = () async => Directory(p.join(root.path, 'ink'));
    ReaderPrefs.dirProvider = () async => Directory(p.join(root.path, 'prefs'));
    ConflictStore.dirProvider = () async =>
        Directory(p.join(root.path, 'conflicts'));
    BookLinkStore.dirProvider = () async =>
        Directory(p.join(root.path, 'links'));
  }

  static Future<Device> install(
    Directory base,
    String name,
    FakeDrive drive, {
    String? email,
  }) async {
    final root = Directory(p.join(base.path, name));
    await root.create(recursive: true);
    final lib = await LibraryStore.openAt(root);
    final d = Device(root, lib)
      ..drive = drive
      ..email = email;
    d.sync = SyncEngine(
      lib,
      isLinked: () => true,
      accountEmail: () => d.email,
      deviceName: () async => 'جهاز $name',
      drive: () => DriveClient(
        ({renew = false}) async => d.drive.goodToken,
        client: d.drive.client,
        retryDelay: (_) => Duration.zero,
      ),
    );
    return d..activate();
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
    await d.lib.linkCatalog(
      e,
      catalogId: 'b1',
      part: 1,
      title: 'الكافي - الجزء 1',
      author: 'الكليني',
    );
    return e;
  }

  /// A second book of the server's library.
  Future<BookEntry> downloadOther(Device d) async {
    final f = File(p.join(base.path, 'book2.pdf'));
    await f.writeAsBytes(List.generate(7000, (i) => (i * 13) & 0xFF));
    final e = await d.lib.importPdf(f.path, title: 'الوسائل');
    await d.lib.linkCatalog(e, catalogId: 'b2', part: 1, title: 'الوسائل');
    return e;
  }

  /// [d] and a new device wrote on page 1 of a new book at the same time.
  Future<(Device, BookEntry)> clash2(Device d) async {
    d.activate();
    final book = await downloadOther(d);
    await _write(book.id, 1);
    await d.sync.syncNow();
    final b = await Device.install(base, 'x', drive);
    await b.sync.syncNow();
    final s = await InkStore.open(book.id);
    s.document.add(1, _stroke(s.document.takeStrokeId()).translated(40, 0));
    await s.dispose();
    await b.sync.syncNow();
    d.activate();
    await _write(book.id, 1);
    await d.sync.syncNow();
    return (d, book);
  }

  const place = ReadingPosition(
    page: 42,
    fx: 0.31,
    fy: 0.77,
    zoom: 2.5,
    fit: 1.1,
  );

  Future<void> savePlace(String id) async {
    final prefs = await ReaderPrefs.open(id);
    prefs.setPosition(place);
    prefs.toggleBookmark(42);
    await prefs.flush();
    prefs.dispose();
  }

  test(
    'reinstalling: the books appear, and download with all the work',
    () async {
      final a = await Device.install(base, 'a', drive);
      final book = await download(a);
      await _write(book.id, 3);
      await savePlace(book.id);
      await a.sync.syncNow();
      expect(a.sync.lastError, isNull);
      expect(drive.names, [
        'book-${book.id}.zip',
      ]); // the work only, not the PDF

      // The app was deleted: nothing of the old storage is left.
      final b = await Device.install(base, 'b', drive);
      expect(b.lib.books, isEmpty);
      await b.sync.syncNow();
      final listed = b.lib.books.single;
      expect(listed.title, 'الكافي - الجزء 1');
      expect(listed.catalogId, 'b1');
      expect(listed.part, 1);
      expect(b.lib.isOnDevice(listed), isFalse);

      final again = await download(b);
      await b.sync.afterImport(again);
      expect(b.sync.lastError, isNull);
      expect(await _strokes(again.id, 3), 1);
      final prefs = await ReaderPrefs.open(again.id);
      expect(prefs.position, place);
      expect(prefs.isBookmarked(42), isTrue);
      prefs.dispose();
      expect(b.lib.books.length, 1);
      expect(b.lib.isOnDevice(b.lib.books.single), isTrue);
    },
  );

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

  test('a book added from a file comes back with its PDF', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await a.lib.importPdf(source.path, title: 'ملفي');
    await _write(book.id, 1);
    await a.sync.syncNow();
    expect(
      drive.names,
      unorderedEquals(['book-${book.id}.zip', 'pdf-${book.id}.pdf']),
    );

    final b = await Device.install(base, 'b', drive);
    await b.sync.syncNow();
    final back = b.lib.books.single;
    expect(back.id, book.id);
    expect(back.title, 'ملفي');
    expect(back.size, 5000);
    expect(b.lib.isOnDevice(back), isTrue);
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

  test('when both devices changed a book, both versions join', () async {
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
    await a.sync.syncNow();
    expect(await _strokes(book.id, 2), 1);
    expect(await _strokes(book.id, 3), 1);
    final extra = Directory(p.join(a.root.path, 'ink'))
        .listSync()
        .where((e) => !e.path.endsWith('.nots'));
    expect(extra, isEmpty); // joined in the book, not kept beside it
  });

  test(
    'newer writing here is not overwritten when re-adding the file',
    () async {
      final a = await Device.install(base, 'a', drive);
      final book = await download(a);
      await _write(book.id, 1);
      await a.sync.syncNow();
      await _write(book.id, 2);
      await File(p.join(a.root.path, 'ink', '${book.id}.nots'))
          .setLastModified(DateTime.now().add(const Duration(hours: 1)));
      await a.sync.afterImport(book);
      expect(await _strokes(book.id, 2), 1);
    },
  );

  test(
    'the book open in the reader goes up, but nothing replaces it',
    () async {
      final a = await Device.install(base, 'a', drive);
      final book = await download(a);
      await _write(book.id, 1);
      await a.sync.syncNow();
      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();
      await _write(book.id, 2);
      await b.sync.syncNow();

      a.activate();
      a.sync.openBook = book.id;
      await a.sync.syncNow();
      expect(await _strokes(book.id, 2), 0);
      a.sync.openBook = null;
      await a.sync.syncNow();
      expect(await _strokes(book.id, 2), 1);

      a.sync.openBook = book.id;
      await _write(book.id, 3); // written with the book open
      await a.sync.syncNow();
      b.activate();
      await b.sync.syncNow();
      expect(await _strokes(book.id, 3), 1);
    },
  );

  test('deleting a book removes it from Drive', () async {
    final a = await Device.install(base, 'a', drive);
    final book = await a.lib.importPdf(source.path, title: 'ملفي');
    await _write(book.id, 1);
    await a.sync.syncNow();
    expect(drive.files.length, 2);
    await a.sync.forget(book.id);
    expect(drive.names, ['gone-${book.id}']); // only the mark for other devices
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

  group('accounts', () {
    Future<void> leave(Device d) async {
      expect(await d.sync.saveEverything(), isEmpty);
      await d.sync.wipeDevice();
    }

    test(
      'each account brings its own data, and takes it when it leaves',
      () async {
        final d = await Device.install(base, 'a', drive, email: 'one@x');
        final mine = await d.lib.importPdf(source.path, title: 'ملفي');
        await _write(mine.id, 1);
        await savePlace(mine.id);
        await d.sync.syncNow();
        await leave(d);
        expect(d.lib.books, isEmpty);
        expect(File(d.lib.pathOf(mine)).existsSync(), isFalse);
        expect(await InkStore.hasWriting(mine.id), isFalse);
        expect(await ReaderPrefs.rawBytes(mine.id), isNull);

        // Another account on the same device sees none of it.
        final other = FakeDrive();
        d.use(other, 'two@x');
        await d.sync.syncNow();
        expect(d.lib.books, isEmpty);
        final second = File(p.join(base.path, 'other.pdf'));
        await second.writeAsBytes(List.generate(4000, (i) => (i * 3) & 0xFF));
        final theirs = await d.lib.importPdf(second.path, title: 'كتاب الثاني');
        await _write(theirs.id, 9);
        await d.sync.syncNow();
        await leave(d);
        expect(drive.names, isNot(contains('book-${theirs.id}.zip')));

        // The first account comes back whole, file and writing.
        d.use(drive, 'one@x');
        await d.sync.syncNow();
        expect(d.lib.books.map((b) => b.id), [mine.id]);
        final back = d.lib.books.single;
        expect(back.title, 'ملفي');
        expect(d.lib.isOnDevice(back), isTrue);
        expect(
          File(d.lib.pathOf(back)).readAsBytesSync(),
          source.readAsBytesSync(),
        );
        expect(await _strokes(mine.id, 1), 1);
        expect(await _strokes(mine.id, 9), 0);
        final prefs = await ReaderPrefs.open(mine.id);
        expect(prefs.position, place);
        prefs.dispose();
      },
    );

    test(
      'a book of the library comes back from the server, not from Drive',
      () async {
        final d = await Device.install(base, 'a', drive, email: 'one@x');
        final book = await download(d);
        await _write(book.id, 2);
        await d.sync.syncNow();
        await leave(d);

        final asked = <BookEntry>[];
        d.sync.fetchCatalogBook = asked.add;
        await d.sync.syncNow();
        final listed = d.lib.books.single;
        expect(d.lib.isOnDevice(listed), isFalse);
        expect(listed.catalogId, 'b1');
        expect(listed.author, 'الكليني');
        expect(asked.single.id, book.id);
        expect(await _strokes(book.id, 2), 1); // the writing is there already

        final file = await download(d);
        expect(file.id, book.id);
        expect(d.lib.books.length, 1);
        expect(d.lib.isOnDevice(d.lib.books.single), isTrue);
      },
    );

    test('nothing leaves the device while Drive cannot take it', () async {
      final d = await Device.install(base, 'a', drive, email: 'one@x');
      final mine = await d.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      drive.full = true;
      final left = await d.sync.saveEverything();
      expect(left.single.id, mine.id);
      expect(d.sync.driveFull, isTrue);
      expect(d.sync.lastError, isNull); // not an error: its own warning
      expect(d.lib.isOnDevice(mine), isTrue);
      expect(await _strokes(mine.id, 1), 1);

      drive.full = false; // room was made
      expect(await d.sync.saveEverything(), isEmpty);
      expect(d.sync.driveFull, isFalse);
    });

    test('without a connection, leaving says what would be lost', () async {
      final d = await Device.install(base, 'a', drive, email: 'one@x');
      final mine = await d.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      await d.sync.syncNow();
      await _write(mine.id, 2);
      drive.down = true;
      expect((await d.sync.saveEverything()).single.id, mine.id);
      expect(d.sync.lastError, isNotNull);
    });

    test('a removal stopped half way is finished at the next start', () async {
      final d = await Device.install(base, 'a', drive, email: 'one@x');
      final mine = await d.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      await File(p.join(d.root.path, 'wipe.pending')).writeAsString('');
      final again = await LibraryStore.openAt(d.root);
      final sync = SyncEngine(
        again,
        isLinked: () => false,
        drive: () => throw StateError('not needed'),
      );
      await sync.finishWipe();
      expect(again.books, isEmpty);
      expect(await InkStore.hasWriting(mine.id), isFalse);
      expect(File(p.join(d.root.path, 'wipe.pending')).existsSync(), isFalse);
    });

    test('the catalogue and covers belong to no account', () async {
      final d = await Device.install(base, 'a', drive, email: 'one@x');
      final cover = File(p.join(d.root.path, 'covers', 'c.jpg'));
      await cover.create(recursive: true);
      await d.sync.wipeDevice();
      expect(cover.existsSync(), isTrue);
    });

    test('moving: everything reaches the new account, and the old one keeps its copy', () async {
      final d = await Device.install(base, 'a', drive, email: 'one@x');
      final mine = await d.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      final library = await downloadOther(d);
      await _write(library.id, 2);
      await d.sync.syncNow();
      await d.lib.offload(mine); // its file is only in Drive now
      expect(await d.sync.gatherEverything(), isEmpty);
      expect(d.lib.isOnDevice(mine), isTrue);
      final before = drive.names.toSet();

      final next = FakeDrive();
      d.use(next, 'two@x');
      await d.sync.moveTo('two@x');
      await d.sync.syncNow();
      expect(d.sync.lastError, isNull);
      expect(await d.sync.owner(), 'two@x');
      expect(
        next.names,
        unorderedEquals([
          'book-${mine.id}.zip',
          'pdf-${mine.id}.pdf',
          'book-${library.id}.zip',
        ]),
      );
      expect(drive.names.toSet(), before);
      expect(await _strokes(mine.id, 1), 1);
      expect(await _strokes(library.id, 2), 1);
      expect(await d.sync.unsaved(), isEmpty);
    });

    test('a full Drive can still be left for another account', () async {
      final d = await Device.install(base, 'a', drive, email: 'one@x');
      final mine = await d.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      drive.full = true;
      await d.sync.syncNow();
      expect(d.sync.driveFull, isTrue);
      expect(await d.sync.gatherEverything(), isEmpty);

      final next = FakeDrive();
      d.use(next, 'two@x');
      await d.sync.moveTo('two@x');
      await d.sync.syncNow();
      expect(d.sync.driveFull, isFalse);
      expect(next.names.length, 2);
    });

    test('moving into an account with its own books joins them', () async {
      final d = await Device.install(base, 'a', drive, email: 'one@x');
      final mine = await d.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      await d.sync.syncNow();

      final next = FakeDrive();
      final e = await Device.install(base, 'b', next, email: 'two@x');
      final same = await e.lib.importPdf(source.path, title: 'ملفي');
      await _write(same.id, 5);
      await e.sync.syncNow();

      d.activate();
      d.use(next, 'two@x');
      await d.sync.moveTo('two@x');
      await d.sync.syncNow();
      expect(await _strokes(mine.id, 1), 1);
      expect(await _strokes(mine.id, 5), 1);
    });

    test(
      'signing in to another account moves nothing until the user says so',
      () async {
        final d = await Device.install(base, 'a', drive, email: 'one@x');
        final mine = await d.lib.importPdf(source.path, title: 'ملفي');
        await _write(mine.id, 1);
        await d.sync.syncNow();

        final next = FakeDrive();
        d.use(next, 'two@x'); // signed in; the question is still on the screen
        expect(await d.sync.otherAccountsData(), isTrue);
        await d.sync.syncNow();
        await d.sync.afterImport(mine);
        expect(next.files, isEmpty);
        await d.sync.moveTo('two@x');
        expect(await d.sync.otherAccountsData(), isFalse);
        await d.sync.syncNow();
        expect(next.files.length, 2);
      },
    );

    test('the device remembers whose data it holds', () async {
      final d = await Device.install(base, 'a', drive, email: 'one@x');
      await d.sync.syncNow();
      final again = SyncEngine(
        d.lib,
        isLinked: () => true,
        drive: () => DriveClient(
          ({renew = false}) async => 'good',
          client: drive.client,
        ),
      );
      expect(await again.owner(), 'one@x');
    });

    test('state saved by the version before accounts still reads', () async {
      final d = await Device.install(base, 'a', drive, email: 'one@x');
      final book = await download(d);
      await _write(book.id, 1);
      final f = File(p.join(d.root.path, 'sync', 'state.json'));
      await f.create(recursive: true);
      await f.writeAsString(
        jsonEncode({
          book.id: {'f': 'x', 'h': 'y', 't': 'z'},
        }),
      );
      await d.sync.syncNow();
      expect(d.sync.lastError, isNull);
      expect(await d.sync.owner(), 'one@x');
      expect(await d.sync.unsaved(), isEmpty);
    });
  });

  group('storage', () {
    test('the room in Drive is reported', () async {
      final d = await Device.install(base, 'a', drive);
      drive.used = 96;
      drive.limit = 100;
      await d.sync.syncNow();
      expect(d.sync.quota!.used, 96);
      expect(d.sync.quota!.nearlyFull, isTrue);
      expect(d.sync.driveFull, isFalse);
      drive.used = 100;
      await d.sync.syncNow();
      expect(d.sync.driveFull, isTrue);
    });

    test('an account with no limit is never full', () {
      const q = DriveQuota(1 << 40, null);
      expect(q.share, isNull);
      expect(q.nearlyFull, isFalse);
      expect(q.full, isFalse);
    });

    test(
      'while Drive is full, changes from other devices still arrive',
      () async {
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
        await _write(book.id, 3);
        drive.full = true;
        await a.sync.syncNow();
        expect(a.sync.driveFull, isTrue);
        expect(await _strokes(book.id, 2), 1);
        expect(await _strokes(book.id, 3), 1);

        drive.full = false;
        await a.sync.syncNow();
        b.activate();
        await b.sync.syncNow();
        expect(await _strokes(same.id, 3), 1); // and what was held back follows
      },
    );
  });

  group('every book of the account', () {
    test('a book with no writing yet is in the account too', () async {
      final a = await Device.install(base, 'a', drive);
      final mine = await a.lib.importPdf(source.path, title: 'ملفي');
      await a.sync.syncNow();
      expect(
        drive.names,
        unorderedEquals(['book-${mine.id}.zip', 'pdf-${mine.id}.pdf']),
      );
    });

    test('a book of the library never sends its PDF', () async {
      final a = await Device.install(base, 'a', drive);
      final book = await download(a);
      await _write(book.id, 1);
      await a.sync.syncNow();
      expect(drive.names, ['book-${book.id}.zip']);
    });

    test('changes on a book added from a file keep going up', () async {
      final a = await Device.install(base, 'a', drive);
      final mine = await a.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      await a.sync.syncNow();
      final sent = drive.uploads;
      await _write(mine.id, 2);
      await a.sync.syncNow();
      expect(drive.uploads, sent + 1); // the work again, not the PDF

      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();
      expect(await _strokes(mine.id, 2), 1);
      await _write(mine.id, 3); // and editing goes on from the other device
      await b.sync.syncNow();
      a.activate();
      await a.sync.syncNow();
      expect(await _strokes(mine.id, 3), 1);
    });

    test('the file goes first: no device sees a book it cannot get', () async {
      final a = await Device.install(base, 'a', drive);
      final mine = await a.lib.importPdf(source.path, title: 'ملفي');
      drive.refuse = 'pdf-';
      await a.sync.syncNow();
      expect(a.sync.lastError, isNotNull);
      expect(drive.names, isEmpty);
      drive.refuse = null;
      await a.sync.syncNow();
      expect(drive.names.length, 2);
      expect(await a.sync.unsaved(), isEmpty);
      expect(mine.id, isNotEmpty);
    });

    test('one book failing does not hold back the others', () async {
      final a = await Device.install(base, 'a', drive);
      final one = await download(a);
      final two = await downloadOther(a);
      await _write(one.id, 1);
      await _write(two.id, 1);
      drive.refuse = 'book-${one.id}';
      await a.sync.syncNow();
      expect(a.sync.lastError, isNotNull);
      expect(drive.names, ['book-${two.id}.zip']);
      expect((await a.sync.unsaved()).single.id, one.id);
    });

    test('Drive being busy is waited out', () async {
      drive.busy = 2;
      final a = await Device.install(base, 'a', drive);
      await a.sync.syncNow();
      expect(a.sync.lastError, isNull);
      expect(drive.busy, 0);
    });

    test('a file damaged on the way is not taken', () async {
      final a = await Device.install(base, 'a', drive);
      final mine = await a.lib.importPdf(source.path, title: 'ملفي');
      await a.sync.syncNow();
      final id = drive.files.keys.firstWhere(
        (k) => drive.files[k]!.name.startsWith('pdf-'),
      );
      final f = drive.files[id]!;
      drive.files[id] = (
        name: f.name,
        description: f.description,
        body: Uint8List(9),
        time: f.time,
      );

      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();
      expect(b.lib.isOnDevice(b.lib.books.single), isFalse);
      expect(File('${b.lib.pathOf(mine)}.part').existsSync(), isFalse);
    });

    test('a new name reaches the other devices', () async {
      final a = await Device.install(base, 'a', drive);
      final book = await download(a);
      await a.sync.syncNow();
      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();
      a.activate();
      await a.lib.rename(book, 'اسم جديد');
      await a.sync.syncNow();
      b.activate();
      await b.sync.syncNow();
      expect(b.lib.books.single.title, 'اسم جديد');
    });

    test('the colours follow the account', () async {
      final a = await Device.install(base, 'a', drive);
      final colours = File(p.join(a.root.path, 'prefs', 'colors.json'));
      await colours.create(recursive: true);
      await colours.writeAsString('{"colors":[1,2],"mark":1}');
      await a.sync.syncNow();
      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();
      expect(
        File(p.join(b.root.path, 'prefs', 'colors.json')).readAsStringSync(),
        '{"colors":[1,2],"mark":1}',
      );
    });

    test('a book taken off this device stays off until asked for', () async {
      final a = await Device.install(base, 'a', drive);
      final mine = await a.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      await a.sync.syncNow();
      await a.lib.offload(mine);
      await a.sync.syncNow();
      expect(a.lib.isOnDevice(mine), isFalse);
      expect(a.lib.books.single.id, mine.id);
      expect(await _strokes(mine.id, 1), 1);

      await a.sync.bring(mine);
      expect(a.lib.isOnDevice(mine), isTrue);
      expect(mine.offloaded, isFalse);
    });
  });

  group('removing', () {
    test('a book removed everywhere leaves the other devices too', () async {
      final a = await Device.install(base, 'a', drive);
      final mine = await a.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      await a.sync.syncNow();
      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();
      expect(b.lib.books.length, 1);

      a.activate();
      await a.lib.remove(mine, deleteWriting: true);
      await a.sync.forget(mine.id);
      b.activate();
      await b.sync.syncNow();
      expect(b.lib.books, isEmpty);
      expect(await InkStore.hasWriting(mine.id), isFalse);
    });

    test(
      'unless that device wrote on it since: its work is not thrown away',
      () async {
        final a = await Device.install(base, 'a', drive);
        final mine = await a.lib.importPdf(source.path, title: 'ملفي');
        await a.sync.syncNow();
        final b = await Device.install(base, 'b', drive);
        await b.sync.syncNow();
        await _write(mine.id, 7);

        a.activate();
        await a.lib.remove(mine, deleteWriting: true);
        await a.sync.forget(mine.id);
        b.activate();
        await b.sync.syncNow();
        expect(b.lib.books.single.id, mine.id);
        expect(await _strokes(mine.id, 7), 1);
        expect(drive.names, contains('book-${mine.id}.zip'));
        expect(drive.names, contains('pdf-${mine.id}.pdf'));
        expect(drive.names.where((n) => n.startsWith('gone-')), isEmpty);
      },
    );

    test('a removal without a connection is done by the next sync', () async {
      final a = await Device.install(base, 'a', drive);
      final mine = await a.lib.importPdf(source.path, title: 'ملفي');
      await a.sync.syncNow();
      await a.lib.remove(mine, deleteWriting: true);
      drive.down = true;
      await expectLater(a.sync.forget(mine.id), throwsA(anything));
      drive.down = false;
      await a.sync.syncNow();
      expect(a.lib.books, isEmpty); // it does not come back
      expect(drive.names, ['gone-${mine.id}']);
    });

    test('adding a removed book again brings it back everywhere', () async {
      final a = await Device.install(base, 'a', drive);
      final mine = await a.lib.importPdf(source.path, title: 'ملفي');
      await a.sync.syncNow();
      await a.lib.remove(mine, deleteWriting: true);
      await a.sync.forget(mine.id);
      await a.lib.importPdf(source.path, title: 'ملفي');
      await _write(mine.id, 1);
      await a.sync.syncNow();
      expect(a.lib.books.length, 1);
      expect(drive.names.where((n) => n.startsWith('gone-')), isEmpty);
    });
  });

  group('merging', () {
    Stroke line(int id, double x) => Stroke(
      id: id,
      tool: InkTool.pen,
      color: 0xFF000000,
      width: 1,
      points: [StrokePoint(x, 1, 0.5, 0), StrokePoint(x, 9, 0.5, 5)],
    );
    Uint8List doc(List<Stroke> s, {List<NoteItem> items = const []}) =>
        StrokeCodec.encodeDocument({1: s}, 50, items: {1: items});
    List<Stroke> strokes(Uint8List? d) =>
        StrokeCodec.decodeDocument(d!).pages[1]!;

    test('what each side added stays; what either erased goes', () {
      final base = doc([line(1, 1), line(2, 2)]);
      final mine = doc([line(1, 1), line(3, 3)]); // erased 2, added 3
      final theirs = doc([line(1, 1), line(2, 2), line(3, 4)]); // added another
      final out = strokes(mergeInk(base, mine, theirs));
      expect(out.map((s) => s.points.first.x), [1, 3, 4]);
    });

    test('ids stay unique when both devices used the same one', () {
      final out = strokes(mergeInk(null, doc([line(7, 1)]), doc([line(7, 2)])));
      expect(out.length, 2);
      expect(out.map((s) => s.id).toSet().length, 2);
    });

    test('with no shared past, the same line is kept once', () {
      final out = strokes(mergeInk(null, doc([line(1, 1)]), doc([line(9, 1)])));
      expect(out.length, 1);
    });

    test('a comment changed on both sides keeps both texts', () {
      NoteItem note(String t) =>
          NoteItem(id: 5, kind: ItemKind.text, x: 1, y: 1, text: t);
      final out = StrokeCodec.decodeDocument(
        mergeInk(
          doc([], items: [note('أ')]),
          doc([], items: [note('ب')]),
          doc([], items: [note('ج')]),
        )!,
      ).items[1]!;
      expect(out.map((i) => i.text), ['ب', 'ج']);
      expect(out.map((i) => i.id).toSet().length, 2);
    });

    test('a merge of the same thing twice changes nothing', () {
      final d = doc([line(1, 1), line(2, 2)]);
      expect(strokes(mergeInk(d, d, d)).length, 2);
    });

    test('bookmarks merge; the place comes from whoever read last', () {
      Uint8List prefs(int page, List<int> marks) => Uint8List.fromList(
        utf8.encode(jsonEncode({'last': page, 'bookmarks': marks})),
      );
      final out = jsonDecode(
        utf8.decode(
          mergePrefs(
            prefs(1, [1, 2]),
            prefs(5, [1, 3]),
            prefs(9, [2, 4]),
            theirsNewer: true,
          )!,
        ),
      );
      expect(out['last'], 9);
      expect(out['bookmarks'], [3, 4]);
    });

    test(
      'two devices that wrote at the same time both reach everyone',
      () async {
        final a = await Device.install(base, 'a', drive);
        final book = await download(a);
        await _write(book.id, 1);
        await a.sync.syncNow();
        final b = await Device.install(base, 'b', drive);
        await b.sync.syncNow();

        await _write(book.id, 2); // on b
        a.activate();
        await _write(book.id, 3); // on a, before hearing of b
        b.activate();
        await b.sync.syncNow();
        a.activate();
        await a.sync.syncNow();
        b.activate();
        await b.sync.syncNow();
        for (final d in [a, b]) {
          d.activate();
          expect(await _strokes(book.id, 1), 1);
          expect(await _strokes(book.id, 2), 1);
          expect(await _strokes(book.id, 3), 1);
        }
      },
    );

    test('what one device erased does not come back from the other', () async {
      final a = await Device.install(base, 'a', drive);
      final book = await download(a);
      await _write(book.id, 1);
      await a.sync.syncNow();
      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();

      final s = await InkStore.open(book.id); // on b: erase it
      s.document.removeStrokes(1, {s.document.strokesOf(1).single.id});
      await s.dispose();
      await b.sync.syncNow();

      a.activate();
      await _write(book.id, 2); // a wrote elsewhere meanwhile
      await a.sync.syncNow();
      expect(await _strokes(book.id, 1), 0);
      expect(await _strokes(book.id, 2), 1);
    });
  });

  group('two devices on the same page', () {
    Stroke mark(int id, double x) => Stroke(
      id: id,
      tool: InkTool.pen,
      color: 0xFFD32F2F,
      width: 2.5,
      points: [StrokePoint(x, 1, 0.7, 0), StrokePoint(x, 9, 0.2, 5)],
    );

    Future<void> writeAt(String id, int page, double x) async {
      final s = await InkStore.open(id);
      s.document.add(page, mark(s.document.takeStrokeId(), x));
      await s.dispose();
    }

    List<double> xs(InkDocument d, int page) =>
        d.strokesOf(page).map((s) => s.points.first.x).toList()..sort();

    /// Both devices wrote on page 1 at x 10 (a) and 20 (b).
    Future<(Device, BookEntry)> clash() async {
      final a = await Device.install(base, 'a', drive);
      final book = await download(a);
      await writeAt(book.id, 1, 1);
      await a.sync.syncNow();
      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();
      await writeAt(book.id, 1, 20);
      await b.sync.syncNow();
      a.activate();
      await writeAt(book.id, 1, 10);
      await a.sync.syncNow();
      return (a, book);
    }

    Future<(ConflictSession, InkStore)> open(BookEntry book) async {
      final store = await InkStore.open(book.id);
      final all = await ConflictStore.load(book.id);
      return (ConflictSession(book.id, store.document, all), store);
    }

    test(
      'the page is asked about, showing both until the user decides',
      () async {
        final (a, book) = await clash();
        expect(a.lib.hasConflicts(book), isTrue);
        final (session, store) = await open(book);
        expect(session.pages, [1]);
        final c = session.of(1)!;
        expect(c.device, 'جهاز b');
        expect(c.choice, PageChoice.merged);
        expect(xs(store.document, 1), [1, 10, 20]);
        await store.dispose();
      },
    );

    test('pages written on by one device alone are not asked about', () async {
      final a = await Device.install(base, 'a', drive);
      final book = await download(a);
      await writeAt(book.id, 1, 1);
      await a.sync.syncNow();
      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();
      await writeAt(book.id, 2, 20);
      await b.sync.syncNow();
      a.activate();
      await writeAt(book.id, 3, 10);
      await a.sync.syncNow();
      expect(a.lib.hasConflicts(book), isFalse);
    });

    test(
      'each version can be seen, and the one chosen is what stays',
      () async {
        final (a, book) = await clash();
        final (session, store) = await open(book);
        await session.show(1, PageChoice.theirs);
        expect(xs(store.document, 1), [1, 20]);
        await session.show(1, PageChoice.mine);
        expect(xs(store.document, 1), [1, 10]);
        await session.accept(1);
        await store.dispose();
        expect(a.lib.hasConflicts(book), isFalse);

        await a.sync.syncNow();
        final other = await Device.install(base, 'c', drive);
        await other.sync.syncNow();
        final s = await InkStore.open(book.id);
        expect(xs(s.document, 1), [1, 10]);
        await s.dispose();
      },
    );

    test(
      'merged writing keeps everything it was: it can still be moved',
      () async {
        final (_, book) = await clash();
        final (session, store) = await open(book);
        await session.accept(1);
        final d = store.document;
        final ids = d.strokesOf(1).map((s) => s.id).toSet();
        expect(ids.length, 3);
        final s = d.strokesOf(1).firstWhere((e) => e.points.first.x == 20);
        expect(s.color, 0xFFD32F2F);
        expect(s.width, 2.5);
        expect(s.points.map((q) => q.pressure), [
          closeTo(0.7, 0.01),
          closeTo(0.2, 0.01),
        ]);
        d.replaceStrokes(1, {s.id: s.translated(5, 0)});
        expect(xs(d, 1), [1, 10, 25]);
        d.removeStrokes(1, {d.strokesOf(1).first.id});
        expect(d.strokesOf(1).length, 2);
        await store.dispose();
      },
    );

    test('what is written while looking at a version is not lost', () async {
      final (_, book) = await clash();
      final (session, store) = await open(book);
      final d = store.document;
      await session.show(1, PageChoice.mine);
      d.add(1, mark(d.takeStrokeId(), 77));
      await session.show(1, PageChoice.theirs);
      expect(xs(d, 1), [1, 20, 77]);
      await store.dispose();
    });

    test('a choice can be undone, as a step or after settling', () async {
      final (_, book) = await clash();
      final (session, store) = await open(book);
      final d = store.document;
      await session.show(1, PageChoice.mine);
      d.undo();
      expect(xs(d, 1), [1, 10, 20]);
      d.redo();
      final settled = await session.accept(1);
      expect(session.isEmpty, isTrue);
      await session.reopen(settled!);
      await session.show(1, PageChoice.merged);
      expect(xs(d, 1), [1, 10, 20]);
      await store.dispose();
    });

    test(
      'the question survives closing the app, with the version on show',
      () async {
        final (_, book) = await clash();
        final (session, store) = await open(book);
        await session.show(1, PageChoice.theirs);
        await store.dispose();
        final (again, store2) = await open(book);
        expect(again.of(1)!.choice, PageChoice.theirs);
        expect(xs(store2.document, 1), [1, 20]);
        await again.show(1, PageChoice.merged);
        expect(xs(store2.document, 1), [1, 10, 20]);
        await store2.dispose();
      },
    );

    test('merging everything settles every page with both sides', () async {
      final a = await Device.install(base, 'a', drive);
      final book = await download(a);
      await a.sync.syncNow();
      final b = await Device.install(base, 'b', drive);
      await b.sync.syncNow();
      await writeAt(book.id, 1, 20);
      await writeAt(book.id, 2, 20);
      await b.sync.syncNow();
      a.activate();
      await writeAt(book.id, 1, 10);
      await writeAt(book.id, 2, 10);
      await a.sync.syncNow();
      final (session, store) = await open(book);
      expect(session.pages, [1, 2]);
      await session.show(2, PageChoice.mine);
      await session.mergeAll();
      expect(session.isEmpty, isTrue);
      expect(xs(store.document, 1), [10, 20]);
      expect(xs(store.document, 2), [10, 20]);
      await store.dispose();
      expect(a.lib.hasConflicts(book), isFalse);
    });

    test('a damaged question file costs no writing', () async {
      final (a, book) = await clash();
      final f = File(p.join(a.root.path, 'conflicts', '${book.id}.zip'));
      await f.writeAsBytes([1, 2, 3]);
      expect(await ConflictStore.load(book.id), isEmpty);
      expect(await _strokes(book.id, 1), 3);
    });

    test(
      'leaving the account or removing the book drops the question',
      () async {
        final (a, book) = await clash();
        await a.lib.remove(book, deleteWriting: true);
        expect(a.lib.hasConflicts(book), isFalse);
        final (b, again) = await clash2(a);
        await b.sync.wipeDevice();
        expect(b.lib.hasConflicts(again), isFalse);
      },
    );
  });

  test('sign-in helpers', () {
    // The example of RFC 7636.
    expect(
      pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
    final payload = base64Url
        .encode(utf8.encode('{"email":"a@b.c"}'))
        .replaceAll('=', '');
    expect(emailOfIdToken('h.$payload.s'), 'a@b.c');
    expect(emailOfIdToken('nonsense'), isNull);
    expect(emailOfIdToken(null), isNull);
  });
}
