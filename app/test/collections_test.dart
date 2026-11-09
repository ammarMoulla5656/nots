import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nots/library/collections.dart';

Future<Collections> _device(String name) async {
  final dir = await Directory.systemTemp.createTemp(name);
  addTearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the file a moment: the temp folder keeps it.
    }
  });
  Collections.dirProvider = () async => dir;
  final c = Collections();
  await c.load();
  return c;
}

void main() {
  test('a book can be in several collections', () async {
    final c = await _device('coll-a');
    final intro = c.create('المقدمات');
    final fiqh = c.create('الفقه');
    c.add(intro, 'book1');
    c.add(fiqh, 'book1');
    c.add(fiqh, 'book1'); // twice: once
    c.add(fiqh, 'note1');
    expect(c.containing('book1').map((x) => x.name), ['المقدمات', 'الفقه']);
    expect(fiqh.items, ['book1', 'note1']);

    c.take(intro, 'book1');
    expect(c.containing('book1').map((x) => x.name), ['الفقه']);

    // Removed from the library: out of every collection.
    c.forget('book1');
    expect(c.containing('book1'), isEmpty);
    expect(fiqh.items, ['note1']);
  });

  test('collections are kept in the file and read again', () async {
    final dir = await Directory.systemTemp.createTemp('coll-b');
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold the file a moment: the temp folder keeps it.
      }
    });
    Collections.dirProvider = () async => dir;
    final a = Collections();
    await a.load();
    final c = a.create('المقدمات');
    a.add(c, 'book1');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final b = Collections();
    await b.load();
    expect(b.all.single.name, 'المقدمات');
    expect(b.all.single.items, ['book1']);
  });

  test('two devices merge: the later change wins, a removal stays', () async {
    final a = await _device('coll-c');
    final shared = a.create('المقدمات');
    a.add(shared, 'book1');
    final gone = a.create('قديمة');

    final b = await _device('coll-d');
    await b.applyBytes(a.bytes());
    expect(b.all.length, 2);

    // Device B adds a book and removes a collection; device A, later,
    // renames the first one.
    b.add(b.byId(shared.id)!, 'book2');
    b.remove(b.byId(gone.id)!);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    a.rename(shared, 'مقدمات الفقه');

    // A takes B's version: its removal comes, and A's own later rename
    // is kept (it is the later change of that collection).
    await a.applyBytes(b.bytes());
    expect(a.all.map((x) => x.name), ['مقدمات الفقه']);

    // B takes A's: the rename comes with it.
    await b.applyBytes(a.bytes());
    expect(b.all.single.name, 'مقدمات الفقه');
    expect(b.all.length, 1, reason: 'the removed one does not come back');
  });
}
