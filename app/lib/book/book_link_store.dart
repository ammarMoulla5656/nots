import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'book_text.dart';

BookText _parseInBackground(({Uint8List bytes, String source}) a) =>
    parseDocx(a.bytes, source: a.source);

/// Keeps the Word text linked to a PDF, next to the PDF's ink file. The
/// .docx is read once (in a background isolate); later opens load the
/// prepared text directly.
class BookLinkStore {
  static Future<File> _fileFor(String bookId) async {
    final dir = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'links'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, '$bookId.json'));
  }

  /// The linked text of the book [bookId], or null when none is linked.
  static Future<BookText?> load(String bookId) async {
    final f = await _fileFor(bookId);
    if (!await f.exists()) return null;
    try {
      return BookText.fromJson(await f.readAsString());
    } on FormatException {
      return null;
    }
  }

  /// Reads [docxPath] and links it to the book [bookId].
  static Future<BookText> link(String bookId, String docxPath) async {
    final bytes = await File(docxPath).readAsBytes();
    final text = await compute(_parseInBackground,
        (bytes: bytes, source: p.basename(docxPath)));
    final f = await _fileFor(bookId);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text.toJson(), flush: true);
    await tmp.rename(f.path);
    return text;
  }

  /// The saved link of [bookId] as JSON, or null.
  static Future<String?> rawJson(String bookId) async {
    final f = await _fileFor(bookId);
    return await f.exists() ? f.readAsString() : null;
  }

  /// Saves a link received in a package, unless the book already has one.
  static Future<void> saveRawIfMissing(String bookId, String json) async {
    BookText.fromJson(json); // validate
    final f = await _fileFor(bookId);
    if (await f.exists()) return;
    await f.writeAsString(json, flush: true);
  }

  static Future<void> unlink(String bookId) async {
    final f = await _fileFor(bookId);
    if (await f.exists()) await f.delete();
  }
}
