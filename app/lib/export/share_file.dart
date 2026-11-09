import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../ink/ink_document.dart';
import '../ink/stroke.dart';
import '../library/home_sheets.dart' show ActionRow, ActionRows;
import '../ui/brand_widgets.dart';

String mimeOf(String fileName) => switch (fileName
    .split('.')
    .last
    .toLowerCase()) {
  'pdf' => 'application/pdf',
  'png' => 'image/png',
  'docx' =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'rtf' => 'application/rtf',
  _ => 'application/octet-stream',
};

/// A finished file: saved where the user chooses (it keeps exactly its name
/// and extension), or shared. Sharing needs the type stated, or Android
/// names the file ".bin".
Future<void> shareBytes(
  BuildContext context,
  Uint8List bytes,
  String name,
) async {
  final mime = mimeOf(name);
  final action = await showNotsSheet<String>(
    context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('الملف جاهز'),
            ActionRows(
              rows: [
                ActionRow(
                  Icons.save_alt,
                  'حفظ في الجهاز',
                  () => Navigator.pop(context, 'save'),
                  subtitle: 'اختر المجلد، ويبقى الاسم والامتداد كما هما',
                ),
                ActionRow(
                  Icons.ios_share,
                  'مشاركة',
                  () => Navigator.pop(context, 'share'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (action == 'save') {
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: mime,
        dialogTitle: 'حفظ $name',
      );
      if (saved != null) {
        messenger.showSnackBar(const SnackBar(content: Text('تم الحفظ.')));
      }
    } else {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, name: name, mimeType: mime)],
          fileNameOverrides: [name],
          title: name,
        ),
      );
    }
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('تعذّر ذلك: $e')));
  }
}

/// A text note as a .nots package: its text (a Delta) and its drawing.
/// `format` says "nots-text-note", so the app opens it as a text note.
Future<Uint8List> textNotePackage({
  required String title,
  required List<dynamic> ops,
  required InkDocument ink,
}) async {
  final a = Archive()
    ..add(
      ArchiveFile.bytes(
        'manifest.json',
        utf8.encode(
          jsonEncode({
            'format': 'nots-text-note',
            'version': 1,
            'title': title,
          }),
        ),
      ),
    )
    ..add(ArchiveFile.bytes('text.json', utf8.encode(jsonEncode({'ops': ops}))))
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
  return Uint8List.fromList(ZipEncoder().encode(a));
}

/// Whether [bytes] is a text note package (rather than a book's).
bool isTextNotePackage(Uint8List bytes) {
  try {
    final m = ZipDecoder().decodeBytes(bytes).findFile('manifest.json');
    if (m == null) return false;
    final j = jsonDecode(utf8.decode(m.content));
    return j is Map && j['format'] == 'nots-text-note';
  } on Object {
    return false;
  }
}

/// The pieces of a text note package.
({String title, List<dynamic> ops, Uint8List? ink}) readTextNotePackage(
  Uint8List bytes,
) {
  final zip = ZipDecoder().decodeBytes(bytes);
  final m = jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content));
  final t = jsonDecode(utf8.decode(zip.findFile('text.json')!.content));
  final ink = zip.findFile('ink.nots')?.content;
  return (
    title: (m is Map ? m['title'] as String? : null) ?? 'ملف نصي',
    ops: (t is Map ? t['ops'] as List? : null) ?? const [],
    ink: ink == null ? null : Uint8List.fromList(ink),
  );
}

/// [image] (a long page) cut into sheets of [pageHeightPt] points, as a PDF
/// whose pages are [pageWidthPt] wide. The last sheet is white below the
/// page's end.
Future<Uint8List> cutPageImage(
  ui.Image image, {
  required double pageWidthPt,
  required double pageHeightPt,
  required double pixelRatio,
}) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) throw StateError('تعذّر رسم الصفحة');
  final whole = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: data.buffer,
    numChannels: 4,
  );
  final sheetH = (pageHeightPt * pixelRatio).round();
  final sheets = (image.height / sheetH).ceil().clamp(1, 1 << 12);
  final temps = <PdfDocument>[];
  final out = await PdfDocument.createNew(sourceName: 'nots-text-note');
  try {
    final pages = <PdfPage>[];
    for (var i = 0; i < sheets; i++) {
      final top = i * sheetH;
      final h = (image.height - top).clamp(1, sheetH);
      var piece = img.copyCrop(
        whole,
        x: 0,
        y: top,
        width: image.width,
        height: h,
      );
      if (h < sheetH) {
        // A short last sheet: white below.
        final full = img.Image(
          width: image.width,
          height: sheetH,
          numChannels: 4,
        )..clear(img.ColorRgba8(255, 255, 255, 255));
        img.compositeImage(full, piece);
        piece = full;
      }
      final jpeg = Uint8List.fromList(img.encodeJpg(piece, quality: 88));
      final one = await PdfDocument.createFromJpegData(
        jpeg,
        width: pageWidthPt,
        height: pageHeightPt,
        sourceName: 'nots-text-sheet-$i',
      );
      temps.add(one);
      pages.add(one.pages.first);
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
