import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nots/catalog/book_detail_screen.dart';
import 'package:nots/catalog/catalog_models.dart';
import 'package:nots/catalog/catalog_store.dart';
import 'package:nots/catalog/cover_image.dart';
import 'package:nots/catalog/download_manager.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/reader/reader_prefs.dart';
import 'package:path/path.dart' as p;

Map<String, Object> _part(int n, {List<int>? bytes, String format = 'pdf'}) => {
  'n': n,
  'label': 'الجزء $n',
  'format': format,
  'file': 'books/b1/p$n.$format',
  'size': bytes?.length ?? 1000,
  'sha256': bytes == null ? '' : sha256.convert(bytes).toString(),
  'pages': 300,
  'features': {'search': true, 'toc': n == 1},
};

Map<String, Object> _book(
  String id,
  String title, {
  String author = '',
  String subject = '',
  String language = 'العربية',
  String added = '2026-01-01',
  List<Map<String, Object>>? parts,
}) => {
  'id': id,
  'title': title,
  'author': author,
  'subject': subject,
  'language': language,
  'added': added,
  'parts_count': parts?.length ?? 1,
  'parts': parts ?? [_part(1)],
};

String _catalog(List<Map<String, Object>> books) => jsonEncode({
  'format': 'nots-catalog',
  'version': 1,
  'updated': 'x',
  'books': books,
});

void main() {
  group('reading the catalogue', () {
    test('a book in parts, in order, with its features', () {
      final c = Catalog.parse(
        _catalog([
          _book('b1', 'الكافي', parts: [_part(2), _part(1)]),
        ]),
      );
      final b = c.books.single;
      expect(b.multiPart, isTrue);
      expect(b.parts.map((e) => e.number), [1, 2]);
      expect(b.parts.first.features.toc, isTrue);
      expect(b.parts.last.features.toc, isFalse);
      expect(b.titleOf(b.parts.last), 'الكافي - الجزء 2');
    });

    test('a damaged book is skipped, the rest stay', () {
      final c = Catalog.parse(
        _catalog([
          {'id': 5},
          _book('b1', 'سليم'),
        ]),
      );
      expect(c.books.map((e) => e.id), ['b1']);
    });

    test('anything else is refused', () {
      expect(() => Catalog.parse('{"format":"other"}'), throwsFormatException);
      expect(() => Catalog.parse('<html>'), throwsFormatException);
    });
  });

  group('searching and sorting', () {
    final books = Catalog.parse(
      _catalog([
        _book(
          '1',
          'تَهْذِيبُ الأحكام',
          author: 'الطوسي',
          subject: 'حديث',
          added: '2026-03-01',
        ),
        _book(
          '2',
          'الكافي',
          author: 'الكليني',
          subject: 'حديث',
          added: '2026-01-01',
        ),
        _book(
          '3',
          'منية المريد',
          author: 'الشهيد الثاني',
          subject: 'أخلاق',
          language: 'فارسي',
          added: '2026-02-01',
        ),
      ]),
    ).books;

    List<String> ids(CatalogQuery q) =>
        runQuery(books, q).map((b) => b.id).toList();

    test('finds a title whatever its diacritics and hamza', () {
      expect(ids(const CatalogQuery(text: 'تهذيب الاحكام')), ['1']);
    });

    test('words may come from different fields, in any order', () {
      expect(ids(const CatalogQuery(text: 'الطوسي تهذيب')), ['1']);
      expect(ids(const CatalogQuery(text: 'لا يوجد')), isEmpty);
    });

    test('filters combine', () {
      expect(
        ids(const CatalogQuery(subject: 'حديث', sort: CatalogSort.title)),
        ['2', '1'],
      );
      expect(ids(const CatalogQuery(subject: 'حديث', author: 'الكليني')), [
        '2',
      ]);
      expect(ids(const CatalogQuery(language: 'فارسي')), ['3']);
    });

    test('sorts by each order', () {
      expect(ids(const CatalogQuery()), ['1', '3', '2']); // newest first
      expect(ids(const CatalogQuery(sort: CatalogSort.subject)).first, '3');
      expect(ids(const CatalogQuery(sort: CatalogSort.author)).last, '2');
    });

    test('stays fast on a very large catalogue', () {
      final many = Catalog.parse(
        _catalog([
          for (var i = 0; i < 50000; i++)
            _book(
              '$i',
              'كتاب رقم $i في الفقه',
              author: 'مؤلف ${i % 500}',
              subject: 'فقه ${i % 40}',
            ),
        ]),
      ).books;
      final clock = Stopwatch()..start();
      final hits = runQuery(
        many,
        const CatalogQuery(text: 'رقم 4999', sort: CatalogSort.title),
      );
      clock.stop();
      expect(hits, isNotEmpty);
      expect(clock.elapsedMilliseconds, lessThan(2000));
    });

    test('offers each value once', () {
      expect(valuesOf(books, (b) => b.subject), ['أخلاق', 'حديث']);
    });
  });

  group('the catalogue on the device', () {
    late Directory root;
    setUp(
      () async => root = await Directory.systemTemp.createTemp('nots_cat_'),
    );
    tearDown(() async => root.delete(recursive: true));

    CatalogStore store(http.Client client, [String bundled = '']) =>
        CatalogStore(
          root,
          client: client,
          bundled: () async =>
              bundled.isEmpty ? _catalog([_book('in', 'المضمّن')]) : bundled,
        );

    final offline = MockClient(
      (_) async => throw const SocketException('down'),
    );

    test('the first start shows the catalogue built into the app', () async {
      final s = store(offline);
      await s.load();
      expect(s.books.single.id, 'in');
      await s.refresh();
      expect(s.failed, isTrue);
      expect(s.books.single.id, 'in'); // still there
    });

    test('Arabic arrives whole, and the newest catalogue is kept', () async {
      final body = utf8.encode(_catalog([_book('s', 'من السيرفر')]));
      final s = store(
        MockClient((r) async {
          expect(r.url.toString(), '${libraryUrl}catalog.txt');
          return http.Response.bytes(
            body,
            200,
            headers: {'content-type': 'text/plain'},
          );
        }),
      );
      await s.load();
      await s.refresh();
      expect(s.books.single.title, 'من السيرفر');

      final later = store(offline);
      await later.load();
      expect(later.books.single.title, 'من السيرفر');
    });

    test('an error page from the server changes nothing', () async {
      final s = store(MockClient((_) async => http.Response('<html>', 200)));
      await s.load();
      await s.refresh();
      expect(s.failed, isTrue);
      expect(s.books.single.id, 'in');
    });
  });

  group('downloading', () {
    late Directory root;
    late LibraryStore lib;
    final data = List.generate(30000, (i) => (i * 13) & 0xFF);

    setUp(() async {
      root = await Directory.systemTemp.createTemp('nots_dl_');
      lib = await LibraryStore.openAt(root);
    });
    tearDown(() async => root.delete(recursive: true));

    CatalogBook book(List<int> bytes, {int parts = 1}) => CatalogBook.fromJson(
      _book(
        'b1',
        'الكافي',
        author: 'الكليني',
        subject: 'حديث',
        parts: [for (var i = 1; i <= parts; i++) _part(i, bytes: bytes)],
      ),
    );

    Future<void> settle(DownloadManager m) async {
      while (m.active) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    http.StreamedResponse full(List<int> b) =>
        http.StreamedResponse(Stream.value(b), 200, contentLength: b.length);

    test('a file enters the library with its book information', () async {
      final imported = <BookEntry>[];
      final m = DownloadManager(
        lib,
        root,
        clientFactory: () => MockClient.streaming((r, _) async => full(data)),
        afterImport: (e) async => imported.add(e),
      );
      final b = book(data);
      m.enqueue(b, b.parts.single);
      await settle(m);
      final e = lib.byCatalog('b1', 1)!;
      expect(e.title, 'الكافي');
      expect(e.author, 'الكليني');
      expect(e.subject, 'حديث');
      expect(File(lib.pathOf(e)).lengthSync(), data.length);
      expect(imported.single.id, e.id);
      expect(Directory(p.join(root.path, 'downloads')).listSync(), isEmpty);
    });

    test('all the parts of a book, one after another', () async {
      var running = 0;
      var most = 0;
      final m = DownloadManager(
        lib,
        root,
        clientFactory: () => MockClient.streaming((r, _) async {
          most = ++running > most ? running : most;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          running--;
          final n = int.parse(
            RegExp(r'p(\d)').firstMatch(r.url.path)!.group(1)!,
          );
          return full(data.map((x) => x ^ n).toList());
        }),
      );
      final b = CatalogBook.fromJson(
        _book(
          'b1',
          'الكافي',
          parts: [
            for (var i = 1; i <= 3; i++)
              _part(i, bytes: data.map((x) => x ^ i).toList()),
          ],
        ),
      );
      m.enqueueAll(b);
      await settle(m);
      expect(most, 1);
      expect(lib.books.length, 3);
      expect(lib.byCatalog('b1', 2)!.title, 'الكافي - الجزء 2');
    });

    test('an interrupted download continues where it stopped', () async {
      final b = book(data);
      var calls = 0;
      String? range;
      final m = DownloadManager(
        lib,
        root,
        clientFactory: () => MockClient.streaming((r, _) async {
          if (++calls == 1) {
            Stream<List<int>> cut() async* {
              yield data.sublist(0, 10000);
              throw const SocketException('lost');
            }

            return http.StreamedResponse(cut(), 200);
          }
          range = r.headers['Range'];
          return http.StreamedResponse(Stream.value(data.sublist(10000)), 206);
        }),
      );
      m.enqueue(b, b.parts.single);
      await settle(m);
      final t = m.taskOf('b1', 1)!;
      expect(t.state, DownloadState.failed);
      expect(t.error, contains('انقطع'));
      m.enqueue(b, b.parts.single);
      await settle(m);
      expect(range, 'bytes=10000-');
      expect(lib.byCatalog('b1', 1), isNotNull);
      expect(File(lib.pathOf(lib.byCatalog('b1', 1)!)).readAsBytesSync(), data);
    });

    test('a server ignoring the range starts the file over', () async {
      final b = book(data);
      var calls = 0;
      final m = DownloadManager(
        lib,
        root,
        clientFactory: () => MockClient.streaming((r, _) async {
          if (++calls == 1) {
            Stream<List<int>> cut() async* {
              yield data.sublist(0, 10000);
              throw const SocketException('lost');
            }

            return http.StreamedResponse(cut(), 200);
          }
          return full(data);
        }),
      );
      m.enqueue(b, b.parts.single);
      await settle(m);
      m.enqueue(b, b.parts.single);
      await settle(m);
      expect(File(lib.pathOf(lib.byCatalog('b1', 1)!)).readAsBytesSync(), data);
    });

    test('a damaged file never enters the library', () async {
      final bad = List.of(data)..[500] ^= 0xFF;
      final m = DownloadManager(
        lib,
        root,
        clientFactory: () => MockClient.streaming((r, _) async => full(bad)),
      );
      final b = book(data);
      m.enqueue(b, b.parts.single);
      await settle(m);
      expect(m.taskOf('b1', 1)!.state, DownloadState.failed);
      expect(lib.books, isEmpty);
    });

    test('a missing file on the server is reported', () async {
      final m = DownloadManager(
        lib,
        root,
        clientFactory: () => MockClient.streaming(
          (r, _) async => http.StreamedResponse(const Stream.empty(), 404),
        ),
      );
      final b = book(data);
      m.enqueue(b, b.parts.single);
      await settle(m);
      expect(m.taskOf('b1', 1)!.error, contains('404'));
    });

    test('a book already in the library is not downloaded again', () async {
      var calls = 0;
      final m = DownloadManager(
        lib,
        root,
        clientFactory: () => MockClient.streaming((r, _) async {
          calls++;
          return full(data);
        }),
      );
      final b = book(data);
      m.enqueue(b, b.parts.single);
      await settle(m);
      m.enqueue(b, b.parts.single);
      await settle(m);
      expect(calls, 1);
    });
  });

  group('covers', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('nots_cover_');
      CoverCache.dirProvider = () async => dir;
    });
    tearDown(() => dir.delete(recursive: true));

    // These hung for ever before, so no cover ever appeared: a limit turns
    // that back into a failure.
    test('a cover is fetched once, then read from the device', () async {
      var fetched = 0;
      CoverCache.client = MockClient((r) async {
        fetched++;
        return http.Response.bytes([1, 2, 3], 200);
      });
      final limit = const Duration(seconds: 5);
      final f = await CoverCache.get('covers/a.jpg').timeout(limit);
      expect(f!.readAsBytesSync(), [1, 2, 3]);
      expect(await CoverCache.get('covers/a.jpg').timeout(limit), isNotNull);
      expect(fetched, 1);
    });

    test('a cover that cannot be fetched is tried again next time', () async {
      var up = false;
      CoverCache.client = MockClient((r) async {
        if (!up) throw http.ClientException('down');
        return http.Response.bytes([1], 200);
      });
      final limit = const Duration(seconds: 5);
      expect(await CoverCache.get('covers/b.jpg').timeout(limit), isNull);
      up = true;
      expect(await CoverCache.get('covers/b.jpg').timeout(limit), isNotNull);
    });

    test('many covers at once all arrive', () async {
      CoverCache.client = MockClient(
        (r) async => http.Response.bytes([1], 200),
      );
      final all = await Future.wait([
        for (var i = 0; i < 12; i++) CoverCache.get('covers/$i.jpg'),
      ]).timeout(const Duration(seconds: 5));
      expect(all.every((f) => f != null), isTrue);
    });
  });

  group('the place in the book', () {
    const page = Rect.fromLTWH(10, 2000, 600, 800);

    test('comes back exactly on the same screen', () {
      final saved = ReadingPosition.capture(
        page: 3,
        pageRect: page,
        center: const Offset(250, 2333),
        zoom: 3.25,
        fit: 1.5,
      );
      final back = ReadingPosition.fromJson(
        jsonDecode(jsonEncode(saved.toJson())),
      )!;
      expect(back, saved);
      expect(back.centerIn(page).dx, closeTo(250, 1e-9));
      expect(back.centerIn(page).dy, closeTo(2333, 1e-9));
      expect(back.zoomFor(1.5), 3.25);
    });

    test('holds on another screen or after rotating', () {
      final saved = ReadingPosition.capture(
        page: 3,
        pageRect: page,
        center: const Offset(310, 2400), // the page's very middle
        zoom: 3,
        fit: 1.5,
      );
      const other = Rect.fromLTWH(0, 900, 300, 400);
      expect(saved.centerIn(other), const Offset(150, 1100));
      expect(saved.zoomFor(3), 6); // the same share of the screen's width
    });

    test('older saved files without it are not an error', () {
      expect(ReadingPosition.fromJson(null), isNull);
      expect(ReadingPosition.fromJson({'p': 'x'}), isNull);
    });

    test('is saved with the page and bookmarks', () async {
      final dir = await Directory.systemTemp.createTemp('nots_pos_');
      ReaderPrefs.dirProvider = () async => dir;
      const pos = ReadingPosition(page: 7, fx: .2, fy: .9, zoom: 2, fit: 1);
      final a = await ReaderPrefs.open('x');
      a.setPosition(pos);
      a.toggleBookmark(2);
      await a.flush();
      a.dispose();
      final b = await ReaderPrefs.open('x');
      expect(b.position, pos);
      expect(b.lastPage, 7);
      expect(await ReaderPrefs.peekPage('x'), 7);
      b.dispose();
      await dir.delete(recursive: true);
    });
  });

  group('the screen of a book', () {
    late Directory root;
    late LibraryStore lib;
    late DownloadManager downloads;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('nots_ui_');
      lib = await LibraryStore.openAt(root);
      downloads = DownloadManager(lib, root);
    });
    tearDown(() => root.delete(recursive: true));

    Widget screen(CatalogBook b) => MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: BookDetailScreen(
          book: b,
          downloads: downloads,
          library: lib,
          onOpen: (_) {},
        ),
      ),
    );

    testWidgets('a single book: its information and what it allows', (t) async {
      await t.pumpWidget(
        screen(
          CatalogBook.fromJson({
            ..._book('b', 'الكافي', author: 'الكليني', subject: 'حديث'),
            'investigator': 'الغفاري',
            'edition': 'الرابعة',
            'publisher': 'دار الكتب',
          }),
        ),
      );
      for (final s in [
        'الكليني',
        'الغفاري',
        'الرابعة',
        'حديث',
        'دار الكتب',
        'العربية',
        'تحميل',
      ]) {
        expect(find.textContaining(s), findsWidgets, reason: s);
      }
      expect(find.text('الكتابة بالقلم'), findsOneWidget);
      expect(find.text('بحث'), findsOneWidget);
      expect(find.textContaining('تحميل كل الأجزاء'), findsNothing);
    });

    testWidgets('a book in parts offers each part and all of them', (t) async {
      await t.pumpWidget(
        screen(
          CatalogBook.fromJson({
            ..._book('b', 'الكافي', parts: [_part(1), _part(2)]),
            'parts_count': 8,
          }),
        ),
      );
      expect(find.text('تحميل كل الأجزاء (2)'), findsOneWidget);
      expect(find.text('الجزء 1'), findsOneWidget);
      expect(find.text('الجزء 2'), findsOneWidget);
      expect(find.textContaining('متوفر 2 من 8'), findsOneWidget);
    });
  });
}
