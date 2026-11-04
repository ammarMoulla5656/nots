import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'book_text.dart';
import 'word_map.dart';

BookText _parseInBackground(({Uint8List bytes, String source}) a) =>
    parseDocx(a.bytes, source: a.source);

BookText _parseJson(String json) => BookText.fromJson(json);

/// The word map embedded in the PDF at [pdfPath], as JSON and parsed.
({String json, BookText text})? _extractInBackground(String pdfPath) {
  final json = findWordMapJson(File(pdfPath).readAsBytesSync());
  if (json == null) return null;
  return (json: json, text: BookText.fromJson(json));
}

/// Keeps the text linked to a PDF, next to the PDF's ink file: the word map
/// embedded in the PDF by nots-cook (found once, then kept here), or a Word
/// file linked by hand. Reading and parsing happen in a background isolate.
class BookLinkStore {
  /// Folder of the links; tests may point it elsewhere.
  static Future<Directory> Function() dirProvider = () async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'links'));

  static Future<File> _fileFor(String bookId) async {
    final dir = await dirProvider();
    await dir.create(recursive: true);
    return File(p.join(dir.path, '$bookId.json'));
  }

  /// The text of the book [bookId] stored at [pdfPath]: the PDF's own word
  /// map when it carries one (looked for once per book), else a Word file
  /// linked by hand, else null.
  static Future<BookText?> open(String bookId, String pdfPath) async {
    final f = await _fileFor(bookId);
    final looked = File('${f.path}.looked');
    BookText? linked;
    if (await f.exists()) {
      try {
        linked = await compute(_parseJson, await f.readAsString());
      } catch (_) {
        linked = null;
      }
      // A Word link may have been made before the PDF was looked at: the
      // PDF's own map, with every word's place, is better.
      if (linked != null && (linked.embedded || await looked.exists())) {
        return linked;
      }
    } else if (await looked.exists()) {
      return null;
    }
    ({String json, BookText text})? found;
    try {
      found = await compute(_extractInBackground, pdfPath);
    } catch (_) {
      found = null; // a damaged map: the book opens without it
    }
    await looked.writeAsString('', flush: true);
    if (found == null) return linked;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(found.json, flush: true);
    await tmp.rename(f.path);
    return found.text;
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
    final text = await compute(_parseInBackground, (
      bytes: bytes,
      source: p.basename(docxPath),
    ));
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

  /// The saved link of [bookId] when the user made it by hand. A word map
  /// is left out: it comes again with the PDF.
  static Future<String?> handLinkedJson(String bookId) async {
    final raw = await rawJson(bookId);
    if (raw == null) return null;
    try {
      return (await compute(_parseJson, raw)).embedded ? null : raw;
    } catch (_) {
      return null;
    }
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
