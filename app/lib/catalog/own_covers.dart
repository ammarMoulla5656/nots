import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../library/library_store.dart';

/// Covers made on the device for books that came without one (a PDF the
/// user added): a small picture of the book's first page. Each is kept as
/// `<book id>.jpg`, so it stays when the app opens again, and the sync keeps
/// a copy in the account's Drive.
class OwnCovers extends ChangeNotifier {
  OwnCovers._();

  static final instance = OwnCovers._();

  /// Where the covers are kept; tests may point it elsewhere.
  static Future<Directory> Function() dirProvider = () async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'own-covers'),
  );

  /// Width of a cover in pixels: sharp in a grid, a few tens of kilobytes.
  static const width = 360;

  Directory? _dir;
  final _have = <String>{};
  Future<void>? _loading;
  var _queue = Future<void>.value();
  final _making = <String>{};

  /// Reads which covers exist. Called once; later calls wait for the first.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final dir = await dirProvider();
    await dir.create(recursive: true);
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.jpg')) {
        _have.add(p.basenameWithoutExtension(e.path));
      }
    }
    _dir = dir;
    notifyListeners();
  }

  /// The cover of book [id], or null when there is none (yet). Answers at
  /// once, without touching the disk, so lists stay smooth.
  File? fileOf(String id) {
    final dir = _dir;
    if (dir == null || !_have.contains(id)) return null;
    return File(p.join(dir.path, '$id.jpg'));
  }

  bool has(String id) => _have.contains(id);

  /// Ids of every cover kept here.
  Set<String> get ids => Set.of(_have);

  Future<Uint8List?> bytesOf(String id) async {
    return fileOf(id)?.readAsBytes();
  }

  /// Keeps [jpg] as the cover of [id] (one that came from Drive).
  Future<void> save(String id, Uint8List jpg) async {
    await load();
    final f = File(p.join(_dir!.path, '$id.jpg'));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(jpg, flush: true);
    await tmp.rename(f.path);
    // A new picture under the same name: the old one must leave the cache.
    PaintingBinding.instance.imageCache.evict(FileImage(f));
    _have.add(id);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    final f = fileOf(id);
    _have.remove(id);
    if (f != null && await f.exists()) await f.delete();
    notifyListeners();
  }

  /// Whether [b] should get a cover made from its first page.
  static bool wants(BookEntry b) =>
      b.cover.isEmpty && (!b.isNote || b.author.startsWith('tpl|'));

  /// Makes the cover of [b] from the first page of its PDF at [pdfPath],
  /// unless it has one. One at a time, so a weak phone stays responsive.
  Future<void> make(BookEntry b, String pdfPath) {
    if (!wants(b) || _making.contains(b.id)) return Future.value();
    _making.add(b.id);
    return _queue = _queue.then((_) async {
      try {
        await load();
        if (has(b.id) || !await File(pdfPath).exists()) return;
        final jpg = await renderFirstPage(pdfPath);
        if (jpg != null) await save(b.id, jpg);
        // A breath between covers, so many of them never crowd the screen.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } on Object catch (e) {
        debugPrint('cover of ${b.id}: $e');
      } finally {
        _making.remove(b.id);
      }
    });
  }

  /// Covers for every book of [library] that is here and has none.
  Future<void> fillMissing(LibraryStore library) async {
    await load();
    for (final b in library.books) {
      if (wants(b) && !has(b.id) && library.isOnDevice(b)) {
        await make(b, library.pathOf(b));
      }
    }
  }

  /// The first page of the PDF at [path] as a JPEG [width] pixels wide.
  static Future<Uint8List?> renderFirstPage(String path) async {
    final doc = await PdfDocument.openFile(path);
    try {
      if (doc.pages.isEmpty) return null;
      final page = doc.pages.first;
      final w = width;
      final h = (w * page.height / page.width).round();
      final pic = await page.render(
        fullWidth: w.toDouble(),
        fullHeight: h.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (pic == null) return null;
      final pixels = Uint8List.fromList(pic.pixels);
      final (pw, ph) = (pic.width, pic.height);
      pic.dispose();
      // Making the JPEG is the slow part: not on the thread that draws.
      return await Isolate.run(() {
        final image = img.Image.fromBytes(
          width: pw,
          height: ph,
          bytes: pixels.buffer,
          numChannels: 4,
          order: img.ChannelOrder.bgra,
        );
        return img.encodeJpg(image, quality: 80);
      });
    } finally {
      await doc.dispose();
    }
  }
}
