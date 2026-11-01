import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Per-book reading state: the page last read (to reopen there) and the
/// bookmarked pages.
class ReaderPrefs extends ChangeNotifier {
  ReaderPrefs._(this._file, this.lastPage, this._bookmarks);

  final File _file;
  int lastPage;
  final Set<int> _bookmarks;
  Timer? _timer;

  List<int> get bookmarks => _bookmarks.toList()..sort();
  bool isBookmarked(int page) => _bookmarks.contains(page);

  static Future<ReaderPrefs> open(String bookId) async {
    final dir = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'prefs'));
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, '$bookId.json'));
    var last = 1;
    final marks = <int>{};
    if (await f.exists()) {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        last = j['last'] as int? ?? 1;
        marks.addAll(((j['bookmarks'] as List?) ?? const []).cast<int>());
      } on FormatException {
        // A damaged file only loses the reading position and bookmarks.
      }
    }
    return ReaderPrefs._(f, last, marks);
  }

  void setLastPage(int page) {
    if (page == lastPage) return;
    lastPage = page;
    _scheduleSave();
  }

  void toggleBookmark(int page) {
    if (!_bookmarks.remove(page)) _bookmarks.add(page);
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), flush);
  }

  Future<void> flush() async {
    _timer?.cancel();
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode({'last': lastPage, 'bookmarks': bookmarks}),
        flush: true);
    await tmp.rename(_file.path);
  }

  @override
  void dispose() {
    unawaited(flush());
    super.dispose();
  }
}
