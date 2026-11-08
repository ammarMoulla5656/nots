import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The category a note (a page of paper made in the app) is filed under. It
/// travels with the book's information, so a note stays a note on every
/// device of the account.
const noteSubject = 'ملاحظاتي';

/// A book (PDF) kept in the app's own storage.
class BookEntry {
  BookEntry({
    required this.id,
    required this.title,
    required this.fileName,
    required this.size,
    required this.added,
    required this.lastOpened,
    this.catalogId,
    this.part,
    this.author = '',
    this.subject = '',
    this.cover = '',
    this.offloaded = false,
    this.readAt,
    double? rank,
  }) : rank = rank ?? -added.millisecondsSinceEpoch.toDouble();

  /// When the book was last opened to read; null until it is (a download is
  /// not a reading). The "last 10 books" come from this.
  DateTime? readAt;

  /// Place in "my order": smaller comes first. A new book gets the place
  /// before every other one; the user may then move it anywhere.
  double rank;

  /// Content fingerprint of the PDF. The ink, the linked Word text and the
  /// reading position are stored under this id, so they follow the book
  /// whatever path or name it is opened from.
  final String id;
  String title;
  final String fileName;
  final int size;
  final DateTime added;
  DateTime lastOpened;

  /// The book and part of the server's library this came from; null for a
  /// file the user added.
  String? catalogId;
  int? part;
  String author;
  String subject;

  /// Path of the cover on the server.
  String cover;

  /// The user took the file off this device: it stays in their account and
  /// comes back only when asked for.
  bool offloaded;

  /// A note: paper made in the app, not a book.
  bool get isNote => subject == noteSubject;

  /// Part of the test library for measuring speed: kept on this device,
  /// never sent to Drive.
  bool get isSpeedTest => fileName.startsWith('speed-test-');

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'file': fileName,
    'size': size,
    'added': added.toIso8601String(),
    'opened': lastOpened.toIso8601String(),
    if (catalogId != null) 'catalog': catalogId,
    if (part != null) 'part': part,
    if (author.isNotEmpty) 'author': author,
    if (subject.isNotEmpty) 'subject': subject,
    if (cover.isNotEmpty) 'cover': cover,
    if (offloaded) 'offloaded': true,
    if (readAt != null) 'read': readAt!.toIso8601String(),
    'rank': rank,
  };

  static BookEntry fromJson(Map<String, dynamic> j) => BookEntry(
    id: j['id'] as String,
    title: j['title'] as String,
    fileName: j['file'] as String,
    size: j['size'] as int,
    added: DateTime.parse(j['added'] as String),
    lastOpened: DateTime.parse(j['opened'] as String),
    catalogId: j['catalog'] as String?,
    part: j['part'] as int?,
    author: j['author'] as String? ?? '',
    subject: j['subject'] as String? ?? '',
    cover: j['cover'] as String? ?? '',
    offloaded: j['offloaded'] as bool? ?? false,
    readAt: j['read'] == null ? null : DateTime.parse(j['read'] as String),
    rank: (j['rank'] as num?)?.toDouble(),
  );
}

/// FNV-1a over the file size, its first and its last megabyte: identical
/// files always get the same id, quickly, even for very large books.
Future<String> fingerprintFile(File f) async {
  const chunk = 1 << 20;
  final size = await f.length();
  final raf = await f.open();
  try {
    var h = 0xcbf29ce484222325;
    void eat(List<int> bytes) {
      for (final b in bytes) {
        h = (h ^ b) * 0x100000001b3;
      }
    }

    eat(utf8.encode('$size|'));
    eat(await raf.read(math.min(chunk, size)));
    if (size > chunk) {
      await raf.setPosition(math.max(chunk, size - chunk));
      eat(await raf.read(chunk));
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  } finally {
    await raf.close();
  }
}

/// Books in the app's storage, most recently opened first.
class LibraryStore extends ChangeNotifier {
  LibraryStore._(this._root, this._books);

  final Directory _root;
  final List<BookEntry> _books;

  /// For tests: a library in [root] instead of the app support folder.
  static Future<LibraryStore> openAt(Directory root) async {
    await Directory(p.join(root.path, 'books')).create(recursive: true);
    final index = File(p.join(root.path, 'library.json'));
    final books = <BookEntry>[];
    if (await index.exists()) {
      try {
        final list = jsonDecode(await index.readAsString()) as List;
        books.addAll(
          list.map((e) => BookEntry.fromJson(e as Map<String, dynamic>)),
        );
      } on FormatException {
        await index.rename('${index.path}.corrupt');
      }
    }
    return LibraryStore._(root, books);
  }

  static Future<LibraryStore> open() async =>
      openAt(await getApplicationSupportDirectory());

  List<BookEntry> get books =>
      List.of(_books)..sort((a, b) => b.lastOpened.compareTo(a.lastOpened));

  Set<String> get ids => {for (final b in _books) b.id};

  /// Folder of the app's own data.
  Directory get root => _root;

  String pathOf(BookEntry b) => p.join(_root.path, 'books', '${b.id}.pdf');

  BookEntry? byId(String id) {
    for (final b in _books) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// The library's copy of part [part] of the catalogue book [catalogId].
  BookEntry? byCatalog(String catalogId, int part) {
    for (final b in _books) {
      if (b.catalogId == catalogId && b.part == part) return b;
    }
    return null;
  }

  /// Like [byCatalog], for a copy whose file is on this device.
  BookEntry? installedCatalog(String catalogId, int part) {
    final b = byCatalog(catalogId, part);
    return b != null && isOnDevice(b) ? b : null;
  }

  /// Marks [b] as part [part] of the catalogue book [catalogId].
  Future<void> linkCatalog(
    BookEntry b, {
    required String catalogId,
    required int part,
    required String title,
    String author = '',
    String subject = '',
    String cover = '',
  }) async {
    b
      ..catalogId = catalogId
      ..part = part
      ..title = title
      ..author = author
      ..subject = subject
      ..cover = cover;
    await _save();
    notifyListeners();
  }

  /// Copies [sourcePath] into the library (once per distinct content) and
  /// returns its entry. Opening the same book again, from any path, gives
  /// the same entry and therefore the same writing.
  Future<BookEntry> importPdf(
    String sourcePath, {
    String? title,
    String? fileName,
  }) async {
    final src = File(sourcePath);
    final id = await fingerprintFile(src);
    final now = DateTime.now();
    var entry = byId(id);
    final dest = File(p.join(_root.path, 'books', '$id.pdf'));
    if (!await dest.exists()) {
      final tmp = File('${dest.path}.part');
      await src.copy(tmp.path);
      await tmp.rename(dest.path);
    }
    if (entry == null) {
      entry = BookEntry(
        id: id,
        title: title ?? p.basenameWithoutExtension(sourcePath),
        fileName: fileName ?? p.basename(sourcePath),
        size: await src.length(),
        added: now,
        lastOpened: now,
      );
      _books.add(entry);
    } else {
      entry.lastOpened = now;
      entry.offloaded = false;
    }
    await _save();
    notifyListeners();
    return entry;
  }

  /// Files [b] as a note: paper made in the app. [template] (the paper's
  /// id) is kept in the author field, which a note has no other use for.
  Future<void> markNote(BookEntry b, {String template = ''}) async {
    b.subject = noteSubject;
    b.author = template;
    await _save();
    notifyListeners();
  }

  Future<void> touch(BookEntry b) async {
    b.lastOpened = b.readAt = DateTime.now();
    await _save();
    notifyListeners();
  }

  /// The order of the books and when each was last read, for the account.
  Uint8List readingBytes() => utf8.encode(
    jsonEncode({
      for (final b in _books)
        b.id: {
          'rank': b.rank,
          if (b.readAt != null) 'read': b.readAt!.toIso8601String(),
        },
    }),
  );

  /// Takes the order and last readings sent by another device: the later
  /// reading wins, the order comes as it was sent.
  Future<void> applyReading(Uint8List bytes) async {
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    for (final b in _books) {
      final e = j[b.id] as Map<String, dynamic>?;
      if (e == null) continue;
      b.rank = (e['rank'] as num?)?.toDouble() ?? b.rank;
      final read = e['read'] == null
          ? null
          : DateTime.parse(e['read'] as String);
      if (read != null && (b.readAt == null || read.isAfter(b.readAt!))) {
        b.readAt = read;
      }
    }
    await _save();
    notifyListeners();
  }

  /// The books really opened to read, the last one first, at most [count].
  List<BookEntry> recentlyRead({int count = 10}) {
    final read = [
      for (final b in _books)
        if (b.readAt != null && !b.isNote) b,
    ]..sort((a, b) => b.readAt!.compareTo(a.readAt!));
    return read.take(count).toList();
  }

  /// [b] goes just before [before] in "my order" (to the end when null).
  Future<void> moveBook(BookEntry b, {BookEntry? before}) async {
    final list = List.of(_books)..sort((x, y) => x.rank.compareTo(y.rank));
    list.remove(b);
    final i = before == null ? list.length : list.indexOf(before);
    list.insert(i < 0 ? list.length : i, b);
    for (var k = 0; k < list.length; k++) {
      list[k].rank = k.toDouble();
    }
    await _save();
    notifyListeners();
  }

  Future<void> rename(BookEntry b, String title) async {
    b.title = title;
    await _save();
    notifyListeners();
  }

  /// Whether the file of [b] is here; a book of the account can be listed
  /// before its file arrives.
  bool isOnDevice(BookEntry b) => _exists(pathOf(b));

  /// Pages of [b] are waiting for the user to choose between two devices.
  bool hasConflicts(BookEntry b) =>
      _exists(p.join(_root.path, 'conflicts', '${b.id}.zip'));

  /// Answers of [_exists], each good for a moment: lists of many books ask
  /// for every book on every build, and the disk must not slow them.
  final _seen = <String, (bool, int)>{};
  static const _seenFor = Duration(seconds: 2);

  bool _exists(String path) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final hit = _seen[path];
    if (hit != null && now - hit.$2 < _seenFor.inMilliseconds) return hit.$1;
    final yes = File(path).existsSync();
    _seen[path] = (yes, now);
    return yes;
  }

  @override
  void notifyListeners() {
    // Something changed: ask the disk again.
    _seen.clear();
    super.notifyListeners();
  }

  /// Lists a book of the user's account whose file is not here yet.
  Future<void> addListed(BookEntry b) async {
    if (byId(b.id) != null) return;
    _books.add(b);
    await _save();
    notifyListeners();
  }

  Future<void> setOffloaded(BookEntry b, bool value) async {
    if (b.offloaded == value) return;
    b.offloaded = value;
    await _save();
    notifyListeners();
  }

  /// The file of [b] has just come to this device.
  Future<void> fileArrived(BookEntry b) async {
    if (b.offloaded) {
      await setOffloaded(b, false);
    } else {
      notifyListeners();
    }
  }

  /// Takes the file of [b] off this device; the book stays listed, with its
  /// work, and can be brought back from the user's account.
  Future<void> offload(BookEntry b) async {
    final f = File(pathOf(b));
    if (await f.exists()) await f.delete();
    await setOffloaded(b, true);
  }

  /// Removes every book and all the work on them from this device. What
  /// belongs to no account (the catalogue, covers) stays.
  Future<void> wipe() async {
    _books.clear();
    for (final sub in [
      'books',
      'ink',
      'links',
      'prefs',
      'sync',
      'downloads',
      'conflicts',
    ]) {
      final dir = Directory(p.join(_root.path, sub));
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    await Directory(p.join(_root.path, 'books')).create(recursive: true);
    await _save();
    notifyListeners();
  }

  /// Adds many books whose files are already in place, saving once.
  Future<void> addMany(List<BookEntry> entries) async {
    final known = ids;
    _books.addAll(entries.where((e) => !known.contains(e.id)));
    await _save();
    notifyListeners();
  }

  /// Removes every book [test] picks, like [remove], saving once. Returns
  /// their ids.
  Future<List<String>> removeWhere(
    bool Function(BookEntry) test, {
    bool deleteWriting = false,
  }) async {
    final gone = _books.where(test).toList();
    _books.removeWhere(test);
    final ids = {for (final b in gone) b.id};
    for (final b in gone) {
      final f = File(pathOf(b));
      if (await f.exists()) await f.delete();
    }
    if (deleteWriting) {
      for (final sub in ['ink', 'links', 'prefs', 'conflicts']) {
        final dir = Directory(p.join(_root.path, sub));
        if (!await dir.exists()) continue;
        await for (final e in dir.list()) {
          final name = p.basename(e.path);
          final dot = name.indexOf('.');
          if (ids.contains(dot < 0 ? name : name.substring(0, dot))) {
            await e.delete();
          }
        }
      }
    }
    await _save();
    notifyListeners();
    return ids.toList();
  }

  /// Removes the book's copy from the library. Its writing is kept unless
  /// [deleteWriting] is true, so re-adding the same PDF brings it back.
  Future<void> remove(BookEntry b, {bool deleteWriting = false}) async {
    _books.removeWhere((e) => e.id == b.id);
    final f = File(pathOf(b));
    if (await f.exists()) await f.delete();
    if (deleteWriting) {
      for (final sub in ['ink', 'links', 'prefs', 'conflicts']) {
        final dir = Directory(p.join(_root.path, sub));
        if (!await dir.exists()) continue;
        await for (final e in dir.list()) {
          if (p.basename(e.path).startsWith(b.id)) await e.delete();
        }
      }
    }
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final index = File(p.join(_root.path, 'library.json'));
    final tmp = File('${index.path}.tmp');
    await tmp.writeAsString(
      jsonEncode([for (final b in _books) b.toJson()]),
      flush: true,
    );
    await tmp.rename(index.path);
  }
}
