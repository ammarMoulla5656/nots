import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../catalog/catalog_store.dart';
import 'note_pdf.dart';
import 'paper.dart';

/// A paper offered by the server, next to the built-in ones: either a paper
/// style (kind and colours) or a page designed as a one-page PDF (a form, a
/// study sheet).
@immutable
class PaperTemplate {
  const PaperTemplate({
    required this.id,
    required this.title,
    this.style,
    this.file = '',
    this.thumb = '',
  });

  final String id;
  final String title;

  /// A plain paper of this style, or null for a PDF page.
  final PaperStyle? style;

  /// Path of the one-page PDF on the server.
  final String file;

  /// Path of its small picture on the server.
  final String thumb;

  bool get isPage => style == null;

  /// What a note or an added page keeps to know its paper (see [Paper]).
  String get code =>
      style?.encode() ?? '${Paper.templatePrefix}${p.basename(file)}';

  static PaperTemplate? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], title = j['title'];
    if (id is! String || title is! String) return null;
    final style = j['style'];
    final file = j['file'];
    if (style is String) {
      return PaperTemplate(
        id: id,
        title: title,
        style: PaperStyle.parse(style),
      );
    }
    if (file is String && file.isNotEmpty) {
      return PaperTemplate(
        id: id,
        title: title,
        file: file,
        thumb: j['thumb'] as String? ?? '',
      );
    }
    return null;
  }
}

/// The paper of a note or of a page added in a book, kept as text: a
/// [PaperStyle] (`kind|paper|line`), or `tpl|<file>` for a template page.
class Paper {
  static const templatePrefix = 'tpl|';

  static bool isTemplate(String code) => code.startsWith(templatePrefix);

  /// Sheets of the paper [code], [width] by [height] points when it is a
  /// style (a template page keeps its own size), as a PDF.
  static Future<Uint8List> pdf(
    String code, {
    required int pages,
    String title = '',
    String stamp = '',
    double? width,
    double? height,
  }) async {
    if (isTemplate(code)) {
      final file = await PaperTemplates.instance.fileFor(
        code.substring(templatePrefix.length),
      );
      if (file != null) return repeatPage(file.path, pages);
    }
    final style = PaperStyle.parse(code);
    return width == null || height == null
        ? buildNotePdf(style: style, pages: pages, title: title, stamp: stamp)
        : buildNotePdf(
            style: style,
            pages: pages,
            title: title,
            stamp: stamp,
            width: width,
            height: height,
          );
  }

  /// A PDF of the first page of [path], [pages] times.
  static Future<Uint8List> repeatPage(String path, int pages) async {
    final src = await PdfDocument.openFile(path);
    final out = await PdfDocument.createNew(sourceName: 'paper-$pages-$path');
    try {
      out.pages = List.filled(pages, src.pages.first);
      return await out.encodePdf();
    } finally {
      await out.dispose();
      await src.dispose();
    }
  }
}

/// The papers the server offers (`papers.txt` beside the catalogue), kept on
/// the device so they work offline, and their PDF pages once fetched.
class PaperTemplates extends ChangeNotifier {
  PaperTemplates._();

  static final instance = PaperTemplates._();

  static Future<Directory> Function() dirProvider = () async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'papers'),
  );
  static http.Client client = http.Client();

  List<PaperTemplate> _all = const [];
  bool _loaded = false;

  List<PaperTemplate> get all => _all;

  Future<File> get _list async =>
      File(p.join((await dirProvider()).path, 'papers.txt'));

  /// The kept list, then the server's (when there is a connection).
  Future<void> load() async {
    if (!_loaded) {
      _loaded = true;
      try {
        final f = await _list;
        if (await f.exists()) _all = _parse(await f.readAsString());
        notifyListeners();
      } on Object {
        // nothing kept yet
      }
    }
    await refresh();
  }

  Future<void> refresh() async {
    try {
      final r = await client
          .get(CatalogStore.urlOf('papers.txt'))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return;
      final text = utf8.decode(r.bodyBytes);
      final parsed = _parse(text);
      final f = await _list;
      await f.parent.create(recursive: true);
      await f.writeAsString(text, flush: true);
      _all = parsed;
      notifyListeners();
    } on Object {
      // offline: the kept list stays
    }
  }

  static List<PaperTemplate> _parse(String text) {
    final j = jsonDecode(text);
    final list = j is Map ? j['papers'] : j;
    if (list is! List) return const [];
    return [for (final e in list) ?PaperTemplate.fromJson(e)];
  }

  /// The PDF page of the template file [name], fetched once. Null without a
  /// connection when it was never fetched.
  Future<File?> fileFor(String name) async {
    final dir = await dirProvider();
    final f = File(p.join(dir.path, name));
    if (await f.exists()) return f;
    var path = 'papers/$name';
    for (final t in _all) {
      if (p.basename(t.file) == name) path = t.file;
    }
    try {
      final r = await client
          .get(CatalogStore.urlOf(path))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return null;
      await dir.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(r.bodyBytes, flush: true);
      return await tmp.rename(f.path);
    } on Object {
      return null;
    }
  }
}
