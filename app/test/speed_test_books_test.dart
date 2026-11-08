import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/ink/ink_store.dart';
import 'package:nots/library/library_store.dart';
import 'package:nots/library/speed_test_books.dart';
import 'package:path/path.dart' as p;

void main() {
  test('the test library is made, written on every page, and removed', () async {
    final root = await Directory.systemTemp.createTemp('speed-test');
    addTearDown(() => root.delete(recursive: true));
    InkStore.dirProvider = () async => Directory(p.join(root.path, 'ink'));
    final lib = await LibraryStore.openAt(root);
    final progress = ValueNotifier<String?>(null);
    await addSpeedTestLibrary(
      lib,
      progress,
      books: 3,
      bookPages: 12,
      notes: 2,
      notePages: 7,
    );
    final all = lib.books;
    expect(all.length, 5);
    expect(all.where((b) => b.isNote).length, 2);
    expect(all.every((b) => b.isSpeedTest), isTrue);
    expect(lib.ids.length, 5, reason: 'every item has its own id');
    for (final b in all) {
      expect(lib.isOnDevice(b), isTrue);
      final ink = await InkStore.open(b.id);
      final pages = ink.document.pages.keys.where(
        (k) => ink.document.pages[k]!.isNotEmpty,
      );
      expect(pages.length, b.isNote ? 7 : 12);
      await ink.dispose();
    }
    expect(progress.value, isNull);
    await removeSpeedTestLibrary(lib);
    expect(lib.books, isEmpty);
    expect(
      Directory(p.join(root.path, 'ink')).listSync().whereType<File>(),
      isEmpty,
    );
  });
}
