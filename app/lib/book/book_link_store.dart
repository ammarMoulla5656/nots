import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ink/ink_store.dart';
import 'book_text.dart';

BookText _parseInBackground(({Uint8List bytes, String source}) a) =>
    parseDocx(a.bytes, source: a.source);

/// Keeps the Word text linked to a PDF, next to the PDF's ink file. The
/// .docx is read once (in a background isolate); later opens load the
/// prepared text directly.
class BookLinkStore {
  static Future<File> _fileFor(String pdfPath) async {
    final dir = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'links'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, '${InkStore.documentKey(pdfPath)}.json'));
  }

  /// The linked text of [pdfPath], or null when none is linked.
  static Future<BookText?> load(String pdfPath) async {
    final f = await _fileFor(pdfPath);
    if (!await f.exists()) return null;
    try {
      return BookText.fromJson(await f.readAsString());
    } on FormatException {
      return null;
    }
  }

  /// Reads [docxPath] and links it to [pdfPath].
  static Future<BookText> link(String pdfPath, String docxPath) async {
    final bytes = await File(docxPath).readAsBytes();
    final text = await compute(_parseInBackground,
        (bytes: bytes, source: p.basename(docxPath)));
    final f = await _fileFor(pdfPath);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text.toJson(), flush: true);
    await tmp.rename(f.path);
    return text;
  }

  static Future<void> unlink(String pdfPath) async {
    final f = await _fileFor(pdfPath);
    if (await f.exists()) await f.delete();
  }
}
