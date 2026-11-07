import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ink_document.dart';
import 'stroke.dart';

/// Writing saved in the ink folder that no book in the library points to:
/// left over from versions that keyed writing by file path. Shown so the
/// user can link it back to its book.
class OrphanInk {
  const OrphanInk({
    required this.key,
    required this.modified,
    required this.pages,
    required this.strokes,
    required this.items,
  });

  final String key;
  final DateTime modified;

  /// Pages that carry writing, in order.
  final List<int> pages;
  final int strokes;
  final int items;
}

/// Saves and loads the ink of one book in the app's storage, never touching
/// the PDF itself. Files are named by the book id (content fingerprint).
class InkStore {
  InkStore._(this._file, this.document) {
    document.addListener(_scheduleSave);
  }

  final File _file;
  final InkDocument document;
  Timer? _timer;
  var _saving = Future<void>.value();

  /// Folder of the ink files; tests may point it elsewhere.
  static Future<Directory> Function() dirProvider = () async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'ink'));

  static Future<Directory> _dir() async {
    final d = await dirProvider();
    await d.create(recursive: true);
    return d;
  }

  static Future<InkStore> open(String bookId) async {
    final file = File(p.join((await _dir()).path, '$bookId.nots'));
    var doc = InkDocument();
    if (await file.exists()) {
      try {
        final decoded = StrokeCodec.decodeDocument(await file.readAsBytes());
        doc = InkDocument(
          pages: decoded.pages,
          items: decoded.items,
          nextStrokeId: decoded.nextStrokeId,
        );
      } on FormatException {
        // Keep the unreadable file for inspection instead of overwriting it.
        await file.rename(
          '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
        );
      }
    }
    return InkStore._(file, doc);
  }

  /// The key older versions used: FNV-1a over the PDF's path and size. Only
  /// used to find and move writing saved by those versions.
  static String legacyKey(String pdfPath) {
    final size = File(pdfPath).existsSync() ? File(pdfPath).lengthSync() : 0;
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode('${p.canonicalize(pdfPath)}|$size')) {
      h = (h ^ b) * 0x100000001b3;
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  /// Ink files with writing that belong to no id in [knownIds].
  static Future<List<OrphanInk>> orphans(Set<String> knownIds) async {
    final out = <OrphanInk>[];
    await for (final e in (await _dir()).list()) {
      if (e is! File || !e.path.endsWith('.nots')) continue;
      final key = p.basenameWithoutExtension(e.path);
      if (knownIds.contains(key)) continue;
      try {
        final d = StrokeCodec.decodeDocument(await e.readAsBytes());
        final pages = <int>{
          for (final x in d.pages.entries)
            if (x.value.isNotEmpty) x.key,
          for (final x in d.items.entries)
            if (x.value.isNotEmpty) x.key,
        }.toList()..sort();
        if (pages.isEmpty) continue;
        out.add(
          OrphanInk(
            key: key,
            modified: await e.lastModified(),
            pages: pages,
            strokes: d.pages.values.fold(0, (n, l) => n + l.length),
            items: d.items.values.fold(0, (n, l) => n + l.length),
          ),
        );
      } on FormatException {
        // Not readable: not offered.
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// Moves the writing saved under [fromKey] to the book [bookId], with the
  /// linked Word text and reading position saved under the same key. Fails
  /// (returns false) when the book already has writing of its own.
  static Future<bool> adopt(String fromKey, String bookId) async {
    if (fromKey == bookId) return true;
    final dir = await _dir();
    final from = File(p.join(dir.path, '$fromKey.nots'));
    final to = File(p.join(dir.path, '$bookId.nots'));
    if (!await from.exists()) return false;
    if (await to.exists()) {
      final d = StrokeCodec.decodeDocument(await to.readAsBytes());
      final hasWriting =
          d.pages.values.any((l) => l.isNotEmpty) ||
          d.items.values.any((l) => l.isNotEmpty);
      if (hasWriting) return false;
      await to.delete();
    }
    await from.rename(to.path);
    final root = dir.parent.path;
    for (final sub in ['links', 'prefs']) {
      final f = File(p.join(root, sub, '$fromKey.json'));
      final t = File(p.join(root, sub, '$bookId.json'));
      if (await f.exists() && !await t.exists()) await f.rename(t.path);
    }
    return true;
  }

  /// Copies the writing and reading position of the book [fromId] to the
  /// book [toId], which must have no writing yet: used when a linked
  /// edition of a PDF (same pages, same places) replaces the original. The
  /// original keeps its own copy. Returns false when nothing was copied.
  static Future<bool> copyWriting(String fromId, String toId) async {
    if (fromId == toId || !await hasWriting(fromId) || await hasWriting(toId)) {
      return false;
    }
    final dir = await _dir();
    await writeRaw(
      toId,
      await File(p.join(dir.path, '$fromId.nots')).readAsBytes(),
    );
    final prefs = File(p.join(dir.parent.path, 'prefs', '$fromId.json'));
    final to = File(p.join(dir.parent.path, 'prefs', '$toId.json'));
    if (await prefs.exists() && !await to.exists()) await prefs.copy(to.path);
    return true;
  }

  /// Whether the book [bookId] has any writing saved.
  static Future<bool> hasWriting(String bookId) async {
    final f = File(p.join((await _dir()).path, '$bookId.nots'));
    if (!await f.exists()) return false;
    try {
      final d = StrokeCodec.decodeDocument(await f.readAsBytes());
      return d.pages.values.any((l) => l.isNotEmpty) ||
          d.items.values.any((l) => l.isNotEmpty);
    } on FormatException {
      return true; // unreadable: never overwrite it silently
    }
  }

  /// The saved writing of [bookId] as it is, or null.
  static Future<Uint8List?> rawBytes(String bookId) async {
    final f = File(p.join((await _dir()).path, '$bookId.nots'));
    return await f.exists() ? f.readAsBytes() : null;
  }

  /// Removes the saved writing of [bookId].
  static Future<void> deleteRaw(String bookId) async {
    final f = File(p.join((await _dir()).path, '$bookId.nots'));
    if (await f.exists()) await f.delete();
  }

  /// Replaces the saved writing of [bookId] with an encoded document
  /// (validated first).
  static Future<void> writeRaw(String bookId, Uint8List bytes) async {
    StrokeCodec.decodeDocument(bytes);
    final f = File(p.join((await _dir()).path, '$bookId.nots'));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  void _scheduleSave() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), flush);
  }

  /// Writes now (atomically: temp file, then rename).
  Future<void> flush() {
    _timer?.cancel();
    final bytes = StrokeCodec.encodeDocument(
      document.pages,
      document.nextStrokeId,
      items: document.items,
    );
    return _saving = _saving.then((_) async {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(_file.path);
    });
  }

  Future<void> dispose() async {
    document.removeListener(_scheduleSave);
    await flush();
  }
}
