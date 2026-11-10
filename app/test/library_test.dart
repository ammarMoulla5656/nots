import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nots/export/exporter.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/ink_store.dart';
import 'package:nots/ink/stroke.dart';
import 'package:nots/library/library_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nots_lib_');
    InkStore.dirProvider = () async => Directory(p.join(root.path, 'ink'));
  });
  tearDown(() async => root.delete(recursive: true));

  Future<File> pdf(String name, List<int> bytes) async {
    final f = File(p.join(root.path, 'src', name));
    await f.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f;
  }

  Uint8List bytes(int n, int seed) =>
      Uint8List.fromList([for (var i = 0; i < n; i++) (i * seed + 7) & 0xFF]);

  test('the same content from two paths is one book with one id', () async {
    final lib = await LibraryStore.openAt(root);
    final data = bytes(3 * 1024 * 1024, 31); // larger than the 1 MB windows
    final a = await lib.importPdf((await pdf('a/book.pdf', data)).path);
    final b = await lib.importPdf((await pdf('cache/123/copy.pdf', data)).path);
    expect(b.id, a.id);
    expect(lib.books.length, 1);
    expect(File(lib.pathOf(a)).lengthSync(), data.length);

    final other = await lib.importPdf(
      (await pdf('x.pdf', bytes(1000, 17))).path,
    );
    expect(other.id, isNot(a.id));
    expect(lib.books.length, 2);
  });

  test('the library survives a restart', () async {
    final lib = await LibraryStore.openAt(root);
    final e = await lib.importPdf(
      (await pdf('k.pdf', bytes(5000, 3))).path,
      title: 'كتاب',
    );
    await lib.rename(e, 'المسائل المنتخبة');
    final again = await LibraryStore.openAt(root);
    expect(again.books.single.title, 'المسائل المنتخبة');
    expect(again.byId(e.id), isNotNull);
  });

  test(
    'writing follows the book id, and old path-keyed writing can be adopted',
    () async {
      final lib = await LibraryStore.openAt(root);
      final src = await pdf('old/place.pdf', bytes(4000, 5));

      // Writing saved by an older version under the path-based key.
      final legacy = InkStore.legacyKey(src.path);
      final old = await InkStore.open(legacy);
      old.document.add(
        3,
        Stroke(
          id: 1,
          tool: InkTool.pen,
          color: 0xFF000000,
          width: 1,
          points: const [StrokePoint(1, 1, 0.5, 0), StrokePoint(9, 9, 0.5, 5)],
        ),
      );
      await old.dispose();

      final entry = await lib.importPdf(src.path);
      // Opening the book once creates its (empty) ink file.
      await (await InkStore.open(entry.id)).dispose();

      final orphans = await InkStore.orphans(lib.ids);
      expect(orphans.single.key, legacy);
      expect(orphans.single.pages, [3]);

      expect(await InkStore.adopt(legacy, entry.id), isTrue);
      final store = await InkStore.open(entry.id);
      expect(store.document.strokesOf(3).length, 1);
      await store.dispose();
      expect(await InkStore.orphans(lib.ids), isEmpty);
    },
  );

  test('adopting never overwrites a book that already has writing', () async {
    final a = await InkStore.open('aaaa');
    a.document.add(
      1,
      Stroke(
        id: 1,
        tool: InkTool.pen,
        color: 0,
        width: 1,
        points: const [StrokePoint(0, 0, 0.5, 0)],
      ),
    );
    await a.dispose();
    final b = await InkStore.open('bbbb');
    b.document.add(
      2,
      Stroke(
        id: 1,
        tool: InkTool.pen,
        color: 0,
        width: 1,
        points: const [StrokePoint(0, 0, 0.5, 0)],
      ),
    );
    await b.dispose();
    expect(await InkStore.adopt('aaaa', 'bbbb'), isFalse);
    final check = await InkStore.open('bbbb');
    expect(check.document.strokesOf(2).length, 1);
    expect(check.document.strokesOf(1), isEmpty);
    await check.dispose();
  });

  test('removing a book can keep or delete its writing', () async {
    final lib = await LibraryStore.openAt(root);
    final e = await lib.importPdf((await pdf('r.pdf', bytes(2000, 9))).path);
    final s = await InkStore.open(e.id);
    s.document.add(
      1,
      Stroke(
        id: 1,
        tool: InkTool.pen,
        color: 0,
        width: 1,
        points: const [StrokePoint(0, 0, 0.5, 0)],
      ),
    );
    await s.dispose();

    await lib.remove(e);
    expect(File(lib.pathOf(e)).existsSync(), isFalse);
    expect(File(p.join(root.path, 'ink', '${e.id}.nots')).existsSync(), isTrue);

    final again = await lib.importPdf(
      (await pdf('r2.pdf', bytes(2000, 9))).path,
    );
    expect(again.id, e.id); // same content: the writing is back
    await lib.remove(again, deleteWriting: true);
    expect(
      File(p.join(root.path, 'ink', '${e.id}.nots')).existsSync(),
      isFalse,
    );
  });

  test('an empty document is never offered as old writing', () async {
    await (await InkStore.open('empty')).dispose();
    expect(await InkStore.orphans({}), isEmpty);
    expect(InkDocument().strokeCount, 0);
  });

  test('export file names always have a dot and the right extension', () {
    expect(
      exportFileName('المسائل المنتخبة 1441', 'pdf'),
      'المسائل المنتخبة 1441.pdf',
    );
    expect(exportFileName('Book v1.2', 'nots'), 'Book v1.2.nots');
    expect(exportFileName('a/b:c*d', 'png'), 'a b c d.png');
    expect(exportFileName('   ', '.nots'), 'nots.nots');
    expect(exportFileName('x' * 200, 'pdf').length, 84);
    expect(exportFileName('x', 'pdf').endsWith('.pdf'), isTrue);
  });
}
