import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../book/book_link_store.dart';
import '../export/exporter.dart';
import '../ink/ink_store.dart';
import '../reader/reader_prefs.dart';
import 'library_store.dart';

/// Adds the book of a .nots package to [library] with its writing, linked
/// Word text and bookmarks. When the same book already has writing here,
/// [confirmReplace] decides whether the package's writing replaces it.
Future<BookEntry> importPackage(
  LibraryStore library,
  Uint8List bytes, {
  required Future<bool> Function(String title) confirmReplace,
}) async {
  final pkg = NotsPackage.read(bytes);
  final dir = await Directory.systemTemp.createTemp('nots_import_');
  try {
    final pdf = File(p.join(dir.path, 'book.pdf'));
    await pdf.writeAsBytes(pkg.pdf, flush: true);
    final entry = await library.importPdf(pdf.path, title: pkg.title);
    if (!await InkStore.hasWriting(entry.id) ||
        await confirmReplace(entry.title)) {
      await InkStore.writeRaw(entry.id, pkg.ink);
    }
    final link = pkg.linkJson;
    if (link != null) await BookLinkStore.saveRawIfMissing(entry.id, link);
    if (pkg.bookmarks.isNotEmpty) {
      final prefs = await ReaderPrefs.open(entry.id);
      prefs.addBookmarks(pkg.bookmarks);
      await prefs.flush();
      prefs.dispose();
    }
    return entry;
  } finally {
    await dir.delete(recursive: true);
  }
}
