import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ink/ink_document.dart';
import '../ink/stroke.dart';
import 'merge.dart';

/// What the user sees on a page written on from two devices.
enum PageChoice { merged, mine, theirs }

/// A page written on from two devices since they last agreed: its three
/// versions, whole, as strokes and items that can still be moved and edited.
class PageConflict {
  PageConflict({
    required this.page,
    required this.mine,
    required this.theirs,
    required this.merged,
    required this.device,
    required this.at,
    this.choice = PageChoice.merged,
  });

  final int page;
  final PageVersion mine;
  final PageVersion theirs;
  final PageVersion merged;

  /// The other device, and when it last saved.
  final String device;
  final DateTime at;

  /// The version on the page now. Until the user decides it is the merged
  /// one, so that nothing is out of sight.
  PageChoice choice;

  PageVersion versionOf(PageChoice c) => switch (c) {
    PageChoice.merged => merged,
    PageChoice.mine => mine,
    PageChoice.theirs => theirs,
  };
}

Uint8List _encode(
  Iterable<PageConflict> all,
  PageVersion Function(PageConflict) of,
) => StrokeCodec.encodeDocument(
  {for (final c in all) c.page: of(c).strokes},
  1,
  items: {for (final c in all) c.page: of(c).items},
);

/// The pages of each book waiting for the user's decision. Kept apart from
/// the writing, which holds the merged version meanwhile: losing this file
/// loses a question, never any writing.
class ConflictStore {
  /// Folder of the files; tests may point it elsewhere.
  static Future<Directory> Function() dirProvider = () async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'conflicts'),
  );

  static Future<File> _fileFor(String bookId) async {
    final dir = await dirProvider();
    await dir.create(recursive: true);
    return File(p.join(dir.path, '$bookId.zip'));
  }

  static Future<Map<int, PageConflict>> load(String bookId) async {
    final f = await _fileFor(bookId);
    if (!await f.exists()) return {};
    try {
      final zip = ZipDecoder().decodeBytes(await f.readAsBytes());
      final meta = jsonDecode(
        utf8.decode(zip.findFile('meta.json')!.content),
      ) as Map<String, dynamic>;
      final docs = {
        for (final name in ['mine', 'theirs', 'merged'])
          name: StrokeCodec.decodeDocument(zip.findFile('$name.nots')!.content),
      };
      PageVersion version(String name, int page) {
        final d = docs[name]!;
        return PageVersion(
          d.pages[page] ?? const [],
          d.items[page] ?? const [],
        );
      }

      return {
        for (final e in meta.entries)
          int.parse(e.key): PageConflict(
            page: int.parse(e.key),
            mine: version('mine', int.parse(e.key)),
            theirs: version('theirs', int.parse(e.key)),
            merged: version('merged', int.parse(e.key)),
            device: e.value['device'] as String? ?? '',
            at:
                DateTime.tryParse(e.value['at'] as String? ?? '') ??
                DateTime(0),
            choice: PageChoice.values.byName(
              e.value['choice'] as String? ?? 'merged',
            ),
          ),
      };
    } on Exception {
      return {}; // the writing is whole: only the question is gone
    } on TypeError {
      return {};
    }
  }

  static Future<void> save(String bookId, Map<int, PageConflict> all) async {
    final f = await _fileFor(bookId);
    if (all.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    final pages = all.values;
    final a = Archive()
      ..add(
        ArchiveFile.bytes(
          'meta.json',
          utf8.encode(
            jsonEncode({
              for (final c in pages)
                '${c.page}': {
                  'device': c.device,
                  'at': c.at.toUtc().toIso8601String(),
                  'choice': c.choice.name,
                },
            }),
          ),
        ),
      )
      ..add(ArchiveFile.bytes('mine.nots', _encode(pages, (c) => c.mine)))
      ..add(ArchiveFile.bytes('theirs.nots', _encode(pages, (c) => c.theirs)))
      ..add(ArchiveFile.bytes('merged.nots', _encode(pages, (c) => c.merged)));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(ZipEncoder().encode(a), flush: true);
    await tmp.rename(f.path);
  }

  /// Adds the pages of a new merge. A page already waiting takes the new
  /// versions: the writing of the old ones is in them.
  static Future<void> add(
    String bookId,
    Map<int, PageSides> pages, {
    required String device,
    required DateTime at,
  }) async {
    final all = await load(bookId);
    for (final e in pages.entries) {
      all[e.key] = PageConflict(
        page: e.key,
        mine: e.value.mine,
        theirs: e.value.theirs,
        merged: e.value.merged,
        device: device,
        at: at,
      );
    }
    await save(bookId, all);
  }
}

/// The user going through the waiting pages of the book open in the reader.
class ConflictSession extends ChangeNotifier {
  ConflictSession(this.bookId, this._doc, this._pages);

  final String bookId;
  final InkDocument _doc;
  final Map<int, PageConflict> _pages;

  /// The waiting pages, in order.
  List<int> get pages => _pages.keys.toList()..sort();
  bool get isEmpty => _pages.isEmpty;

  PageConflict? of(int page) => _pages[page];

  /// One write at a time: they share a temporary file, and pressing through
  /// the versions quickly asks for several.
  var _saving = Future<void>.value();

  Future<void> _save() =>
      _saving = _saving.then((_) => ConflictStore.save(bookId, _pages));

  /// Done writing: for whoever removes the folder.
  Future<void> get saved => _saving;

  /// Puts version [choice] on the page. What was written on the page since
  /// the version before it was shown stays.
  Future<void> show(int page, PageChoice choice) async {
    final c = _pages[page];
    if (c == null || c.choice == choice) return;
    final now = PageVersion(_doc.strokesOf(page), _doc.itemsOf(page));
    final next = mergePage(c.versionOf(c.choice), now, c.versionOf(choice));
    _doc.replacePage(page, next.strokes, next.items);
    c.choice = choice;
    notifyListeners();
    await _save();
  }

  /// Settles the page with the version on it. Returns what [reopen] takes to
  /// ask again.
  Future<PageConflict?> accept(int page) async {
    final c = _pages.remove(page);
    notifyListeners();
    await _save();
    return c;
  }

  Future<void> reopen(PageConflict c) async {
    _pages[c.page] = c;
    notifyListeners();
    await _save();
  }

  /// Keeps both sides on all the waiting pages.
  Future<void> mergeAll() async {
    for (final page in pages) {
      await show(page, PageChoice.merged);
    }
    _pages.clear();
    notifyListeners();
    await _save();
  }
}

/// A word for the other device when it gave no name.
String deviceLabel(String device) => device.isEmpty ? 'الجهاز الآخر' : device;
