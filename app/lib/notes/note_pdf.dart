import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../library/library_store.dart';
import 'paper.dart';

/// A4 in PDF points.
const _pageW = 595.28;
const _pageH = 841.89;
const _mm = _pageW / 210;

String _rgb(int argb) {
  String c(int shift) => (((argb >> shift) & 255) / 255).toStringAsFixed(4);
  return '${c(16)} ${c(8)} ${c(0)}';
}

/// The drawing of one sheet as PDF operators: the paper's colour, then its
/// lines. Real vector lines, sharp at any zoom, a few kilobytes in all.
String paperContent(PaperStyle s) {
  final b = StringBuffer()
    ..writeln('${_rgb(s.paper)} rg')
    ..writeln('0 0 $_pageW $_pageH re f');
  final lines = paperLines(s.kind);
  if (lines.isNotEmpty) {
    b
      ..writeln('${_rgb(s.line)} RG')
      ..writeln('${(paperLineWidth(s.kind) * _mm).toStringAsFixed(3)} w');
    for (final (x1, y1, x2, y2) in lines) {
      b.writeln(
        '${(x1 * _mm).toStringAsFixed(2)} ${(_pageH - y1 * _mm).toStringAsFixed(2)} m '
        '${(x2 * _mm).toStringAsFixed(2)} ${(_pageH - y2 * _mm).toStringAsFixed(2)} l',
      );
    }
    b.writeln('S');
  }
  return b.toString();
}

/// A PDF of [pages] sheets of the paper [style]. The drawing is stored once
/// and every page points at it.
///
/// [stamp] goes into the file's information, so two notes of the same paper
/// are different files (a book's writing is kept under the file's own id).
Uint8List buildNotePdf({
  required PaperStyle style,
  required int pages,
  required String title,
  required String stamp,
}) {
  final out = BytesBuilder();
  final offsets = <int>[];
  void put(String s) => out.add(latin1.encode(s));
  void object(int n, void Function() body) {
    offsets.add(out.length);
    put('$n 0 obj\n');
    body();
    put('endobj\n');
  }

  final draw = paperContent(style);
  // Objects: 1 catalog, 2 page tree, 3 drawing, 4 information, then pages.
  const first = 5;
  put('%PDF-1.4\n');
  object(1, () => put('<< /Type /Catalog /Pages 2 0 R >>\n'));
  object(2, () {
    final kids = [for (var i = 0; i < pages; i++) '${first + i} 0 R'].join(' ');
    put('<< /Type /Pages /Count $pages /Kids [$kids] >>\n');
  });
  object(
    3,
    () => put('<< /Length ${draw.length} >>\nstream\n${draw}endstream\n'),
  );
  object(4, () {
    put(
      '<< /Title <${_hex(title)}> /Producer (Nots) '
      '/Keywords (${stamp.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '')}) >>\n',
    );
  });
  for (var i = 0; i < pages; i++) {
    object(first + i, () {
      put(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $_pageW $_pageH] '
        '/Resources << >> /Contents 3 0 R >>\n',
      );
    });
  }
  final xref = out.length;
  final count = first + pages;
  put('xref\n0 $count\n0000000000 65535 f \n');
  for (final o in offsets) {
    put('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  put(
    'trailer\n<< /Size $count /Root 1 0 R /Info 4 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return out.takeBytes();
}

/// A text string in UTF-16BE hex, as a PDF title.
String _hex(String s) {
  final b = StringBuffer('FEFF');
  for (final u in s.codeUnits) {
    b.write(u.toRadixString(16).padLeft(4, '0').toUpperCase());
  }
  return b.toString();
}

/// Makes a new note on [style] in [library] and returns its entry. The paper
/// is saved as a PDF in the app's own folder and added like any book, filed
/// under [noteSubject], with the paper's description in its author field.
Future<BookEntry> createNote(
  LibraryStore library,
  PaperStyle style, {
  String title = 'ملاحظة بلا عنوان',
}) async {
  final stamp =
      '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';
  final bytes = buildNotePdf(
    style: style,
    pages: PaperStyle.pages,
    title: title,
    stamp: stamp,
  );
  final tmp = Directory(p.join((await getTemporaryDirectory()).path, 'notes'));
  await tmp.create(recursive: true);
  final file = File(p.join(tmp.path, 'note-$stamp.pdf'));
  await file.writeAsBytes(bytes, flush: true);
  try {
    final entry = await library.importPdf(
      file.path,
      title: title,
      fileName: '$title.pdf',
    );
    await library.markNote(entry, template: style.encode());
    return entry;
  } finally {
    if (await file.exists()) await file.delete();
  }
}
