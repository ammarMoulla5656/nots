import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ink_document.dart';
import 'stroke.dart';

/// Saves and loads the ink of one PDF next to the app data, never touching
/// the PDF itself.
class InkStore {
  InkStore._(this._file, this.document) {
    document.addListener(_scheduleSave);
  }

  final File _file;
  final InkDocument document;
  Timer? _timer;
  var _saving = Future<void>.value();

  static Future<InkStore> open(String pdfPath) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'ink'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '${documentKey(pdfPath)}.nots'));
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
        await file.rename('${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      }
    }
    return InkStore._(file, doc);
  }

  /// Stable key for a PDF: FNV-1a over its path and size. Good enough for the
  /// standalone prototype; library books will use a content hash instead.
  static String documentKey(String pdfPath) {
    final size = File(pdfPath).existsSync() ? File(pdfPath).lengthSync() : 0;
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode('${p.canonicalize(pdfPath)}|$size')) {
      h = (h ^ b) * 0x100000001b3;
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
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
