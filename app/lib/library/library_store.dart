import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A book (PDF) kept in the app's own storage.
class BookEntry {
  BookEntry({
    required this.id,
    required this.title,
    required this.fileName,
    required this.size,
    required this.added,
    required this.lastOpened,
  });

  /// Content fingerprint of the PDF. The ink, the linked Word text and the
  /// reading position are stored under this id, so they follow the book
  /// whatever path or name it is opened from.
  final String id;
  String title;
  final String fileName;
  final int size;
  final DateTime added;
  DateTime lastOpened;

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'file': fileName,
    'size': size,
    'added': added.toIso8601String(),
    'opened': lastOpened.toIso8601String(),
  };

  static BookEntry fromJson(Map<String, dynamic> j) => BookEntry(
    id: j['id'] as String,
    title: j['title'] as String,
    fileName: j['file'] as String,
    size: j['size'] as int,
    added: DateTime.parse(j['added'] as String),
    lastOpened: DateTime.parse(j['opened'] as String),
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

  String pathOf(BookEntry b) => p.join(_root.path, 'books', '${b.id}.pdf');

  BookEntry? byId(String id) {
    for (final b in _books) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// Copies [sourcePath] into the library (once per distinct content) and
  /// returns its entry. Opening the same book again, from any path, gives
  /// the same entry and therefore the same writing.
  Future<BookEntry> importPdf(String sourcePath, {String? title}) async {
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
        fileName: p.basename(sourcePath),
        size: await src.length(),
        added: now,
        lastOpened: now,
      );
      _books.add(entry);
    } else {
      entry.lastOpened = now;
    }
    await _save();
    notifyListeners();
    return entry;
  }

  Future<void> touch(BookEntry b) async {
    b.lastOpened = DateTime.now();
    await _save();
    notifyListeners();
  }

  Future<void> rename(BookEntry b, String title) async {
    b.title = title;
    await _save();
    notifyListeners();
  }

  /// Removes the book's copy from the library. Its writing is kept unless
  /// [deleteWriting] is true, so re-adding the same PDF brings it back.
  Future<void> remove(BookEntry b, {bool deleteWriting = false}) async {
    _books.removeWhere((e) => e.id == b.id);
    final f = File(pathOf(b));
    if (await f.exists()) await f.delete();
    if (deleteWriting) {
      for (final sub in ['ink', 'links', 'prefs']) {
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
