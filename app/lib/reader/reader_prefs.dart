import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'page_map.dart';

/// The exact place the reader was: which page, where in that page the middle
/// of the screen was, and the zoom. The place is kept relative to the page,
/// not the document, so it still holds after a rotation or on another screen.
@immutable
class ReadingPosition {
  const ReadingPosition({
    required this.page,
    required this.fx,
    required this.fy,
    required this.zoom,
    required this.fit,
  });

  /// [center] and [pageRect] are in document coordinates. [fit] is the zoom
  /// at which the page fills the width of the screen at this moment.
  factory ReadingPosition.capture({
    required int page,
    required Rect pageRect,
    required Offset center,
    required double zoom,
    required double fit,
  }) => ReadingPosition(
    page: page,
    fx: (center.dx - pageRect.left) / pageRect.width,
    fy: (center.dy - pageRect.top) / pageRect.height,
    zoom: zoom,
    fit: fit,
  );

  final int page;

  /// The screen's middle as a share of the page's width and height. Beyond
  /// 0..1 when the middle of the screen lies outside the page.
  final double fx;
  final double fy;
  final double zoom;
  final double fit;

  /// Where the middle of the screen goes, in document coordinates.
  Offset centerIn(Rect pageRect) => Offset(
    pageRect.left + fx * pageRect.width,
    pageRect.top + fy * pageRect.height,
  );

  /// The zoom to use now. The same as saved on the same screen; on another
  /// (or after rotating) the page keeps the same share of the screen's width.
  double zoomFor(double currentFit) =>
      fit > 0 && currentFit > 0 ? zoom * currentFit / fit : zoom;

  Map<String, num> toJson() => {
    'p': page,
    'x': fx,
    'y': fy,
    'z': zoom,
    'f': fit,
  };

  static ReadingPosition? fromJson(Object? j) {
    if (j is! Map) return null;
    final (page, x, y, z, f) = (j['p'], j['x'], j['y'], j['z'], j['f']);
    if (page is! num || x is! num || y is! num || z is! num || f is! num) {
      return null;
    }
    return ReadingPosition(
      page: page.toInt(),
      fx: x.toDouble(),
      fy: y.toDouble(),
      zoom: z.toDouble(),
      fit: f.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReadingPosition &&
      other.page == page &&
      other.fx == fx &&
      other.fy == fy &&
      other.zoom == zoom &&
      other.fit == fit;

  @override
  int get hashCode => Object.hash(page, fx, fy, zoom, fit);
}

/// Per-book reading state: the exact place last read (to reopen there) and
/// the bookmarked pages.
class ReaderPrefs extends ChangeNotifier {
  ReaderPrefs._(
    this._file,
    this.lastPage,
    this._position,
    this._bookmarks,
    this.pageCount,
    this._extras,
  );

  final File _file;
  int lastPage;

  /// Pages of the book, known once it has been opened (0 until then).
  int pageCount;
  ReadingPosition? _position;
  final Set<int> _bookmarks;
  final List<ExtraPage> _extras;
  Timer? _timer;

  /// Blank pages added inside the book, in the order they were placed.
  List<ExtraPage> get extras => List.unmodifiable(_extras);

  /// Adds a blank page after book page [after] and returns it.
  ExtraPage addExtra(int after, {String paper = ''}) {
    final id = _extras.fold<int>(0, (m, e) => e.id > m ? e.id : m) + 1;
    final e = ExtraPage(id, after, paper);
    _extras.add(e);
    notifyListeners();
    _scheduleSave();
    return e;
  }

  /// Puts the added page [id] after book page [after] (last among those
  /// already there).
  void moveExtra(int id, int after) {
    final i = _extras.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final paper = _extras[i].paper;
    _extras
      ..removeAt(i)
      ..add(ExtraPage(id, after, paper));
    notifyListeners();
    _scheduleSave();
  }

  void removeExtra(int id) {
    _extras.removeWhere((e) => e.id == id);
    notifyListeners();
    _scheduleSave();
  }

  /// There are changes not yet on disk.
  bool _dirty = false;
  var _saving = Future<void>.value();

  ReadingPosition? get position => _position;
  List<int> get bookmarks => _bookmarks.toList()..sort();
  bool isBookmarked(int page) => _bookmarks.contains(page);

  /// Folder of the files; tests may point it elsewhere.
  static Future<Directory> Function() dirProvider = () async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'prefs'));

  static Future<File> _fileFor(String bookId) async {
    final dir = await dirProvider();
    await dir.create(recursive: true);
    return File(p.join(dir.path, '$bookId.json'));
  }

  static Future<ReaderPrefs> open(String bookId) async {
    final f = await _fileFor(bookId);
    var last = 1;
    var count = 0;
    ReadingPosition? pos;
    final marks = <int>{};
    final extras = <ExtraPage>[];
    if (await f.exists()) {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        last = j['last'] as int? ?? 1;
        count = j['n'] as int? ?? 0;
        pos = ReadingPosition.fromJson(j['pos']);
        marks.addAll(((j['bookmarks'] as List?) ?? const []).cast<int>());
        for (final e in (j['extra'] as List?) ?? const []) {
          if (ExtraPage.fromJson(e) case final x?) extras.add(x);
        }
      } on FormatException {
        // A damaged file only loses the reading position and bookmarks.
      }
    }
    return ReaderPrefs._(f, last, pos, marks, count, extras);
  }

  /// The page last read in [bookId], for showing in lists.
  static Future<int?> peekPage(String bookId) async {
    final raw = await rawBytes(bookId);
    if (raw == null) return null;
    try {
      return (jsonDecode(utf8.decode(raw)) as Map)['last'] as int?;
    } on FormatException {
      return null;
    }
  }

  /// The page last read and the number of pages of [bookId], for the lists
  /// of books. The count is 0 until the book has been opened once.
  static Future<({int page, int count})?> peekProgress(String bookId) async {
    final raw = await rawBytes(bookId);
    if (raw == null) return null;
    try {
      final j = jsonDecode(utf8.decode(raw)) as Map;
      return (page: j['last'] as int? ?? 1, count: j['n'] as int? ?? 0);
    } on FormatException {
      return null;
    }
  }

  /// The saved file of [bookId] as it is, or null.
  static Future<Uint8List?> rawBytes(String bookId) async {
    final f = await _fileFor(bookId);
    return await f.exists() ? f.readAsBytes() : null;
  }

  /// When the reading state of [bookId] last changed here, or null.
  static Future<DateTime?> modifiedAt(String bookId) async {
    final f = await _fileFor(bookId);
    return await f.exists() ? f.lastModified() : null;
  }

  /// Replaces the saved file of [bookId].
  static Future<void> writeRaw(String bookId, Uint8List bytes) async {
    final f = await _fileFor(bookId);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  void addBookmarks(Iterable<int> pages) {
    _bookmarks.addAll(pages);
    notifyListeners();
    _scheduleSave();
  }

  void setPageCount(int n) {
    if (n == pageCount) return;
    pageCount = n;
    _scheduleSave();
  }

  void setLastPage(int page) {
    if (page == lastPage) return;
    lastPage = page;
    _scheduleSave();
  }

  void setPosition(ReadingPosition pos) {
    if (pos == _position) return;
    _position = pos;
    lastPage = pos.page;
    _scheduleSave();
  }

  void toggleBookmark(int page) {
    if (!_bookmarks.remove(page)) _bookmarks.add(page);
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), flush);
  }

  /// Writes any changes now, one write at a time: they share a temporary
  /// file, and the app leaving the screen can ask while the timer is at it.
  Future<void> flush() {
    _timer?.cancel();
    if (!_dirty) return _saving;
    _dirty = false;
    final text = jsonEncode({
      'last': lastPage,
      if (pageCount > 0) 'n': pageCount,
      'pos': ?_position?.toJson(),
      'bookmarks': bookmarks,
      if (_extras.isNotEmpty) 'extra': [for (final e in _extras) e.toJson()],
    });
    return _saving = _saving.then((_) async {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(_file.path);
    });
  }

  @override
  void dispose() {
    unawaited(flush());
    super.dispose();
  }
}
