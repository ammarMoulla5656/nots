import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../library/library_store.dart';
import 'note_pdf.dart';
import 'paper.dart';

/// A text note: a long page you type on, with fonts, colours, headings and a
/// contents, and draw on top of. Its text is kept as a Delta (JSON), so it
/// stays text (small, sharp, editable); its drawing is vector, in the same
/// file as the writing on books.
///
/// In the library it is a note like any other (so the library, Drive and
/// removal all work as they do), told apart by the paper code `text|lined`
/// in its author field, and by a one-page blank PDF it carries.
const textPaperPrefix = 'text|';

bool isTextNote(BookEntry b) =>
    b.isNote && b.author.startsWith(textPaperPrefix);

/// Whether the text note has ruled lines (the paper code says it).
bool textNoteHasLines(BookEntry b) => !b.author.endsWith('|plain');

class TextNoteStore {
  /// Where the documents are kept; tests may point it elsewhere.
  static Future<Directory> Function() dirProvider = () async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'docs'));

  static Future<File> _file(String id) async {
    final dir = await dirProvider();
    await dir.create(recursive: true);
    return File(p.join(dir.path, '$id.json'));
  }

  /// The document of note [id] as Delta operations (a new one for none).
  static Future<List<dynamic>> read(String id) async {
    final f = await _file(id);
    if (!await f.exists()) return emptyOps();
    try {
      final j = jsonDecode(await f.readAsString());
      final ops = j is Map ? j['ops'] : null;
      return ops is List && ops.isNotEmpty ? ops : emptyOps();
    } on FormatException {
      return emptyOps();
    }
  }

  static List<dynamic> emptyOps() => [
    {'insert': '\n'},
  ];

  static Future<void> write(String id, List<dynamic> ops) async {
    final f = await _file(id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'v': 1, 'ops': ops}), flush: true);
    await tmp.rename(f.path);
  }

  /// The saved file as it is, for the account; null when none.
  static Future<Uint8List?> rawBytes(String id) async {
    final f = await _file(id);
    return await f.exists() ? f.readAsBytes() : null;
  }

  static Future<void> writeRaw(String id, Uint8List bytes) async {
    final f = await _file(id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> delete(String id) async {
    final f = await _file(id);
    if (await f.exists()) await f.delete();
  }

  /// When two devices changed the same note: the later text stays whole,
  /// and the other is put under it, marked, so nothing is lost.
  static Uint8List mergeBoth(Uint8List later, Uint8List other) {
    List<dynamic> ops(Uint8List b) {
      try {
        final j = jsonDecode(utf8.decode(b));
        final o = j is Map ? j['ops'] : null;
        return o is List ? o : emptyOps();
      } on FormatException {
        return emptyOps();
      }
    }

    final a = ops(later), b = ops(other);
    if (jsonEncode(a) == jsonEncode(b)) return later;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'ops': [
            ...a,
            {'insert': '\n'},
            {
              'insert': '— النص الذي كُتب على الجهاز الآخر —',
              'attributes': {'bold': true},
            },
            {
              'insert': '\n',
              'attributes': {'header': 3},
            },
            ...b,
          ],
        }),
      ),
    );
  }

  /// The first lines of the text, for the card in «ملاحظاتي».
  static final _previews = <String, String>{};

  static Future<String> preview(String id) async {
    final hit = _previews[id];
    if (hit != null) return hit;
    final ops = await read(id);
    final text = StringBuffer();
    for (final o in ops) {
      final t = o is Map ? o['insert'] : null;
      if (t is String) text.write(t);
      if (text.length > 400) break;
    }
    return _previews[id] = text.toString().trim();
  }

  static void forgetPreview(String id) => _previews.remove(id);
}

/// Whether a saved document is the empty one (no text typed yet).
bool isBlankTextDoc(Uint8List bytes) {
  try {
    final j = jsonDecode(utf8.decode(bytes));
    final ops = j is Map ? j['ops'] : null;
    if (ops is! List) return true;
    return ops.every((o) {
      final t = o is Map ? o['insert'] : null;
      return t is String && t.trim().isEmpty;
    });
  } on FormatException {
    return true;
  }
}

/// Makes a new text note in [library] and returns its entry.
Future<BookEntry> createTextNote(
  LibraryStore library, {
  String title = 'ملف نصي',
  bool lines = true,
}) async {
  final stamp =
      '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';
  final bytes = buildNotePdf(
    style: const PaperStyle(),
    pages: 1,
    title: title,
    stamp: stamp,
  );
  final tmp = await Directory.systemTemp.createTemp('nots_text_');
  final file = File(p.join(tmp.path, 'text-$stamp.pdf'));
  await file.writeAsBytes(bytes, flush: true);
  try {
    final entry = await library.importPdf(
      file.path,
      title: title,
      fileName: '$title.pdf',
    );
    await library.markNote(
      entry,
      template: '$textPaperPrefix${lines ? 'lined' : 'plain'}',
    );
    await TextNoteStore.write(entry.id, TextNoteStore.emptyOps());
    return entry;
  } finally {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  }
}

/// A heading of the document, for the contents.
typedef TextHeading = ({String title, int level, int offset});

/// The headings (levels 1 to 3) of [doc], in order, with where each starts.
List<TextHeading> headingsOf(Document doc) {
  final out = <TextHeading>[];
  for (final node in doc.root.children) {
    if (node is! Line) continue;
    final level = node.style.attributes[Attribute.header.key]?.value;
    if (level is! int || level < 1 || level > 3) continue;
    final title = node.toPlainText().replaceAll('\n', '').trim();
    if (title.isEmpty) continue;
    out.add((title: title, level: level, offset: node.documentOffset));
  }
  return out;
}

/// The Delta of [ops] (for the writers of Word and RTF).
Delta deltaOf(List<dynamic> ops) => Delta.fromJson(ops);
