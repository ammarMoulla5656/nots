import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/reader/reader_prefs.dart';
import 'package:nots/stats/usage.dart';
import 'package:nots/stats/usage_upload.dart';
import 'package:path/path.dart' as p;

BookEntry _book(String id, {String? catalog}) => BookEntry(
  id: id,
  title: 'كتاب $id',
  fileName: '$id.pdf',
  size: 1000,
  added: DateTime(2026),
  lastOpened: DateTime(2026),
  catalogId: catalog,
  author: 'مؤلف',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  var now = DateTime(2026, 11, 10, 21, 0);
  final u = Usage.instance;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('usage');
    Usage.dirProvider = () async => Directory(p.join(root.path, 'prefs'));
    ReaderPrefs.dirProvider = () async => Directory(p.join(root.path, 'rp'));
    u.resetForTest();
    now = DateTime(2026, 11, 10, 21, 0);
    u.clock = () => now;
    await u.load();
  });

  tearDown(() => u.resetForTest());

  test('reading time is counted, a long silence only up to five minutes', () {
    final b = _book('a', catalog: 'c1');
    u.bookOpened(b);
    now = now.add(const Duration(minutes: 3));
    u.activity();
    now = now.add(const Duration(minutes: 40)); // the phone left on a page
    u.page(12, 300);
    u.bookClosed();
    final book = (u.data['books'] as Map)['a'] as Map;
    expect(book['s'], 8 * 60, reason: '3 minutes, then 5 of the 40');
    expect(book['o'], 1);
    expect(book['c'], 'c1');
    expect(book['pg'], 12);
    expect(book['far'], 12);
    expect((u.data['tot'] as Map)['read'], 8 * 60);
    expect((u.data['hours'] as List)[21], 8 * 60);
    expect((u.data['days'] as Map)['2026-11-10'], 8 * 60);
  });

  test('a scroll asks only the clock until two seconds passed', () {
    u.bookOpened(_book('a'));
    now = now.add(const Duration(milliseconds: 500));
    u.activity();
    expect((u.data['tot'] as Map?)?['read'], isNull);
    now = now.add(const Duration(seconds: 2));
    u.activity();
    expect((u.data['tot'] as Map)['read'], 2.5);
  });

  test('time with the app in the back is not reading', () {
    u.bookOpened(_book('a'));
    now = now.add(const Duration(minutes: 1));
    u.foreground(false);
    now = now.add(const Duration(minutes: 30));
    u.foreground(true);
    now = now.add(const Duration(minutes: 1));
    u.bookClosed();
    expect((u.data['tot'] as Map)['read'], 120);
  });

  test('the clean screen: its time and the hour it is used', () {
    u.bookOpened(_book('a'));
    u.clean(true);
    now = now.add(const Duration(minutes: 2));
    u.clean(false);
    now = now.add(const Duration(minutes: 1));
    u.bookClosed();
    expect((u.data['tot'] as Map)['clean'], 120);
    expect((u.data['cleanHours'] as List)[21], 120);
    expect((u.data['tot'] as Map)['read'], 180);
    expect((u.data['f'] as Map)['clean_screen'], 1);
  });

  test('tools and features, for the app and for the book', () {
    u.bookOpened(_book('a'));
    u.tool('pen');
    u.tool('pen');
    u.feature('search');
    u.bookClosed();
    u.feature('library_search');
    u.catalog('c9', 'view');
    u.catalog('c9', 'dl');
    expect(u.data['tools'], {'pen': 2});
    expect(u.data['f'], {'search': 1, 'library_search': 1});
    final book = (u.data['books'] as Map)['a'] as Map;
    expect(book['tools'], {'pen': 2});
    expect(book['f'], {'search': 1});
    expect(u.data['catalog'], {
      'c9': {'view': 1, 'dl': 1},
    });
  });

  test('kept across a restart, with the same device id', () async {
    u.feature('toc');
    final id = u.deviceId;
    expect(id, hasLength(32));
    u.sharing = false;
    await u.save();
    u.resetForTest();
    u.clock = () => now;
    await u.load();
    expect(u.deviceId, id);
    expect(u.sharing, isFalse);
    expect((u.data['f'] as Map)['toc'], 1);
  });

  group('the report', () {
    late LibraryStore lib;
    late UsageUploader up;
    late List<http.Request> sent;
    var status = 200;

    setUp(() async {
      lib = await LibraryStore.openAt(root);
      final f = File(p.join(root.path, 'x.pdf'))
        ..writeAsBytesSync(List.generate(3000, (i) => i & 255));
      await lib.importPdf(f.path, title: 'كتابي الخاص');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('nots/app'), (c) async {
            if (c.method == 'deviceInfo') {
              return {'model': 'KJ5', 'maker': 'TECNO', 'android': '14'};
            }
            if (c.method == 'network') return 'wifi';
            return null;
          });
      sent = [];
      status = 200;
      up = UsageUploader(
        library: lib,
        account: () => (email: 'a@b.com', name: 'علي', linked: true),
        reading: () => false,
        client: MockClient((r) async {
          sent.add(r);
          return http.Response('{"ok":true}', status);
        }),
      );
      await FeedbackOutbox.instance.load();
    });

    test('holds the device, the account, the library and the usage', () async {
      u.feature('toc');
      final r = await up.report();
      expect((r['device'] as Map)['id'], u.deviceId);
      expect((r['device'] as Map)['model'], 'KJ5');
      expect(r['account'], {'email': 'a@b.com', 'name': 'علي', 'linked': true});
      final l = r['library'] as Map;
      expect(l['items'], 1);
      expect(l['own'], 1);
      expect((l['ownBooks'] as List).single['t'], 'كتابي الخاص');
      expect(((r['usage'] as Map)['f'] as Map)['toc'], 1);
    });

    test(
      'goes gzipped with the key; the messages leave the device after',
      () async {
        await FeedbackOutbox.instance.add('book', 'الكافي', about: 'اقتراح');
        expect(await up.send(), isTrue);
        final r = sent.single;
        expect(r.headers['X-Nots-Key'], statsKey);
        final body = jsonDecode(utf8.decode(gzip.decode(r.bodyBytes))) as Map;
        expect((body['messages'] as List).single['text'], 'الكافي');
        expect(FeedbackOutbox.instance.waiting, isEmpty);
        expect(u.data['sent'], isNotNull);
      },
    );

    test('a refused report keeps the messages for the next time', () async {
      status = 500;
      await FeedbackOutbox.instance.add('problem', 'لا تفتح');
      expect(await up.send(), isFalse);
      expect(FeedbackOutbox.instance.waiting, hasLength(1));
      await FeedbackOutbox.instance.sent([
        for (final m in FeedbackOutbox.instance.waiting) m['id'] as String,
      ]);
    });

    test('never on mobile data, never while reading, never when off', () async {
      u.network = 'mobile';
      await up.tick();
      expect(sent, isEmpty);
      u.network = 'wifi';
      u.sharing = false;
      await up.tick();
      expect(sent, isEmpty);
      u.sharing = true;
      final reading = UsageUploader(
        library: lib,
        account: () => (email: null, name: null, linked: false),
        reading: () => true,
        client: MockClient((r) async {
          sent.add(r);
          return http.Response('', 200);
        }),
      );
      await reading.tick();
      expect(sent, isEmpty);
      await up.tick();
      expect(sent, hasLength(1), reason: 'on Wi-Fi, quiet, due');
    });
  });
}
