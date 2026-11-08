import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../ink/image_items.dart';
import '../ink/ink_document.dart';
import '../ink/item_painter.dart';
import '../ink/stroke.dart';
import '../ink/stroke_painter.dart';

/// Pages of [ink] that carry writing, marks or notes.
Set<int> annotatedPages(InkDocument ink) => {
  // The book's own pages: those added inside it (keys from 1000000 on, see
  // PageMap) are not part of its file.
  for (final e in ink.pages.entries)
    if (e.value.isNotEmpty && e.key < 1000000) e.key,
  for (final e in ink.items.entries)
    if (e.value.isNotEmpty) e.key,
};

/// Renders [pageNumber] of [doc] with its writing on top. [pxPerPt] sets the
/// resolution (3 ≈ 216 dpi). The caller disposes the returned image.
Future<ui.Image> renderPageWithInk(
  PdfDocument doc,
  InkDocument ink,
  int pageNumber, {
  double pxPerPt = 3,
}) async {
  await ImageItems.instance.preload(ink.itemsOf(pageNumber));
  final page = doc.pages[pageNumber - 1];
  final w = (page.width * pxPerPt).round();
  final h = (page.height * pxPerPt).round();
  final pdfImage = await page.render(
    fullWidth: w.toDouble(),
    fullHeight: h.toDouble(),
    backgroundColor: 0xFFFFFFFF,
  );
  if (pdfImage == null) throw StateError('تعذّر رسم الصفحة $pageNumber');
  final background = await pdfImage.createImage();
  pdfImage.dispose();

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImage(background, Offset.zero, Paint());
  background.dispose();
  for (final s in ink.strokesOf(pageNumber)) {
    paintStroke(canvas, s, pxPerPt);
  }
  ItemsPainter(
    items: () => ink.itemsOf(pageNumber),
    preview: () => null,
    scale: pxPerPt,
    repaint: const AlwaysStoppedAnimation(0),
  ).paint(canvas, Size(w.toDouble(), h.toDouble()));
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  return image;
}

/// PNG of one page with its writing.
Future<Uint8List> pagePng(
  PdfDocument doc,
  InkDocument ink,
  int pageNumber,
) async {
  final image = await renderPageWithInk(doc, ink, pageNumber);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _pageJpeg(
  PdfDocument doc,
  InkDocument ink,
  int pageNumber,
) async {
  final image = await renderPageWithInk(doc, ink, pageNumber, pxPerPt: 2.5);
  try {
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final decoded = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: rgba!.buffer,
      numChannels: 4,
    );
    return img.encodeJpg(decoded, quality: 90);
  } finally {
    image.dispose();
  }
}

/// A PDF of the book with the writing. Pages with writing are drawn as
/// high-resolution images with the writing on them; the other pages are the
/// book's own pages, unchanged. With [onlyAnnotated] only the pages with
/// writing are included.
Future<Uint8List> exportPdf(
  PdfDocument doc,
  InkDocument ink, {
  bool onlyAnnotated = false,
  void Function(int done, int total)? progress,
}) async {
  final marked = annotatedPages(ink);
  final numbers = onlyAnnotated
      ? (marked.toList()..sort())
      : [for (var i = 1; i <= doc.pages.length; i++) i];
  final temps = <PdfDocument>[];
  final out = await PdfDocument.createNew(sourceName: 'nots-export');
  try {
    final pages = <PdfPage>[];
    var done = 0;
    final work = numbers.where(marked.contains).length;
    for (final n in numbers) {
      if (marked.contains(n)) {
        final page = doc.pages[n - 1];
        final jpeg = await _pageJpeg(doc, ink, n);
        final one = await PdfDocument.createFromJpegData(
          jpeg,
          width: page.width,
          height: page.height,
          sourceName: 'nots-page-$n',
        );
        temps.add(one);
        pages.add(one.pages.first);
        progress?.call(++done, work);
      } else {
        pages.add(doc.pages[n - 1]);
      }
    }
    out.pages = pages;
    return await out.encodePdf();
  } finally {
    await out.dispose();
    for (final t in temps) {
      await t.dispose();
    }
  }
}

/// Everything needed to continue working on the book in Nots on another
/// device: the PDF, the writing, the linked Word text and the bookmarks.
Future<Uint8List> exportPackage({
  required String title,
  required String bookId,
  required File pdf,
  required InkDocument ink,
  String? linkJson,
  List<int> bookmarks = const [],
}) async {
  final a = Archive()
    ..add(
      ArchiveFile.bytes(
        'manifest.json',
        utf8.encode(
          jsonEncode({
            'format': 'nots-package',
            'version': 1,
            'title': title,
            'book': bookId,
            'bookmarks': bookmarks,
          }),
        ),
      ),
    )
    ..add(ArchiveFile.bytes('book.pdf', await pdf.readAsBytes()))
    ..add(
      ArchiveFile.bytes(
        'ink.nots',
        StrokeCodec.encodeDocument(
          ink.pages,
          ink.nextStrokeId,
          items: ink.items,
        ),
      ),
    );
  if (linkJson != null) {
    a.add(ArchiveFile.bytes('link.json', utf8.encode(linkJson)));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

/// Contents of a .nots package.
class NotsPackage {
  NotsPackage(this.title, this.pdf, this.ink, this.linkJson, this.bookmarks);

  final String title;
  final Uint8List pdf;
  final Uint8List ink;
  final String? linkJson;
  final List<int> bookmarks;

  static NotsPackage read(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    final manifest = zip.findFile('manifest.json');
    final pdf = zip.findFile('book.pdf');
    final ink = zip.findFile('ink.nots');
    if (manifest == null || pdf == null || ink == null) {
      throw const FormatException('ليس ملف نوتس صالحاً');
    }
    final m = jsonDecode(utf8.decode(manifest.content)) as Map<String, dynamic>;
    if (m['format'] != 'nots-package') {
      throw const FormatException('ليس ملف نوتس صالحاً');
    }
    // Validate the writing before anything is written to the library.
    StrokeCodec.decodeDocument(ink.content);
    final link = zip.findFile('link.json');
    return NotsPackage(
      m['title'] as String? ?? 'كتاب',
      pdf.content,
      ink.content,
      link == null ? null : utf8.decode(link.content),
      ((m['bookmarks'] as List?) ?? const []).cast<int>(),
    );
  }
}

/// A safe file name (title, dot, extension) from a book title. The extension is
/// always appended after a dot, and a dot inside the title is kept.
String exportFileName(String title, String ext) {
  final clean = title
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
      .replaceAll(RegExp(r'[\u0000-\u001f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final base = clean.isEmpty ? 'nots' : clean;
  final dotted = ext.startsWith('.') ? ext : '.$ext';
  final cut = base.length > 80 ? base.substring(0, 80).trim() : base;
  return '$cut$dotted';
}
