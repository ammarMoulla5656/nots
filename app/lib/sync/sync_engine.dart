import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../book/book_link_store.dart';
import '../ink/ink_store.dart';
import '../library/library_store.dart';
import '../reader/reader_prefs.dart';
import 'drive_client.dart';
import 'google_account.dart';

/// The work on one book, as kept in Drive: the writing, the place reached,
/// the bookmarks and a Word text linked by hand. Never the book itself.
class WorkBundle {
  const WorkBundle({this.ink, this.prefs, this.link});

  final Uint8List? ink;
  final Uint8List? prefs;
  final String? link;

  Uint8List encode() {
    final a = Archive();
    if (ink != null) a.add(ArchiveFile.bytes('ink.nots', ink!));
    if (prefs != null) a.add(ArchiveFile.bytes('prefs.json', prefs!));
    if (link != null) {
      a.add(ArchiveFile.bytes('link.json', utf8.encode(link!)));
    }
    return Uint8List.fromList(ZipEncoder().encode(a));
  }

  static WorkBundle decode(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    final link = zip.findFile('link.json');
    return WorkBundle(
      ink: zip.findFile('ink.nots')?.content,
      prefs: zip.findFile('prefs.json')?.content,
      link: link == null ? null : utf8.decode(link.content),
    );
  }

  /// Tells apart two states of the work.
  String get hash {
    final all = BytesBuilder(copy: false);
    for (final part in [ink, prefs, if (link != null) utf8.encode(link!)]) {
      all
        ..add(part ?? const [])
        ..add(const [0xFF, 0x00, 0xFF]);
    }
    return sha256.convert(all.takeBytes()).toString();
  }
}

/// A book with saved work in the user's Drive.
class RemoteBook {
  const RemoteBook({
    required this.id,
    required this.file,
    required this.title,
    required this.savedAt,
    this.catalogId,
    this.part,
    this.author = '',
    this.subject = '',
    this.cover = '',
    this.pdfFile,
  });

  final String id;
  final DriveFile file;
  final String title;

  /// When the work last changed on the device that saved it.
  final DateTime savedAt;
  final String? catalogId;
  final int? part;
  final String author;
  final String subject;
  final String cover;

  /// A book added from a file is on no server: its PDF is kept in Drive.
  final DriveFile? pdfFile;

  static RemoteBook? parse(DriveFile f, DriveFile? pdf) {
    if (!f.name.startsWith(_workPrefix) || !f.name.endsWith('.zip')) {
      return null;
    }
    final id = f.name.substring(_workPrefix.length, f.name.length - 4);
    Map<String, dynamic> m;
    try {
      m = jsonDecode(f.description) as Map<String, dynamic>;
    } on FormatException {
      m = const {};
    }
    return RemoteBook(
      id: id,
      file: f,
      title: m['title'] as String? ?? 'كتاب',
      savedAt: DateTime.tryParse(m['saved'] as String? ?? '') ?? DateTime(0),
      catalogId: m['catalog'] as String?,
      part: m['part'] as int?,
      author: m['author'] as String? ?? '',
      subject: m['subject'] as String? ?? '',
      cover: m['cover'] as String? ?? '',
      pdfFile: pdf,
    );
  }
}

const _workPrefix = 'book-';
const _pdfPrefix = 'pdf-';

/// What was last agreed with Drive for a book.
class _Synced {
  const _Synced(this.fileId, this.hash, this.remoteTime);

  final String fileId;
  final String hash;
  final String remoteTime;

  Map<String, String> toJson() => {'f': fileId, 'h': hash, 't': remoteTime};

  static _Synced fromJson(Map<String, dynamic> j) =>
      _Synced(j['f'] as String, j['h'] as String, j['t'] as String);
}

/// Keeps the work on the user's books in their Drive. Only books with
/// writing, bookmarks or a linked text are kept there, so after reinstalling
/// the app, linking the account lists them; downloading one brings it back
/// with everything done on it.
///
/// Each book is one file. When two devices changed the same book, the
/// newest work wins and the other stays on the device beside it
/// ([InkStore.keepCopy]), so no writing is lost.
class SyncEngine extends ChangeNotifier {
  SyncEngine(
    this._library, {
    required this.isLinked,
    required DriveClient Function() drive,
    this.statePath,
  }) : _newDrive = drive;

  final LibraryStore _library;
  final bool Function() isLinked;
  final DriveClient Function() _newDrive;
  final String? statePath;

  final _state = <String, _Synced>{};
  bool _stateLoaded = false;
  var _remote = <String, RemoteBook>{};
  bool _running = false;
  bool _again = false;
  Timer? _soon;

  /// The book open in the reader: its files are not replaced under it.
  String? openBook;

  String? lastError;
  DateTime? lastSync;
  bool get running => _running;

  File get _stateFile =>
      File(statePath ?? p.join(_library.root.path, 'sync', 'state.json'));

  /// Books in Drive that are not in the library on this device.
  List<RemoteBook> get remoteOnly {
    final out = [
      for (final r in _remote.values)
        if (_localOf(r) == null) r,
    ]..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return out;
  }

  BookEntry? _localOf(RemoteBook r) {
    final byId = _library.byId(r.id);
    if (byId != null) return byId;
    final c = r.catalogId;
    final n = r.part;
    return c != null && n != null ? _library.byCatalog(c, n) : null;
  }

  RemoteBook? _remoteOf(BookEntry b) {
    final byId = _remote[b.id];
    if (byId != null) return byId;
    if (b.catalogId == null) return null;
    for (final r in _remote.values) {
      if (r.catalogId == b.catalogId && r.part == b.part) return r;
    }
    return null;
  }

  Future<void> _loadState() async {
    if (_stateLoaded) return;
    _stateLoaded = true;
    final f = _stateFile;
    if (!await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _state.addAll(
        j.map((k, v) => MapEntry(k, _Synced.fromJson(v as Map<String, dynamic>))),
      );
    } on FormatException {
      _state.clear(); // the next sync compares everything again
    }
  }

  Future<void> _saveState() async {
    final f = _stateFile;
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(_state), flush: true);
    await tmp.rename(f.path);
  }

  /// Syncs a little later, so that writing just finished is on disk and a
  /// burst of events is one sync.
  void requestSoon() {
    if (!isLinked()) return;
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 3), () => unawaited(syncNow()));
  }

  Future<void> syncNow() async {
    if (!isLinked()) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    lastError = null;
    notifyListeners();
    try {
      do {
        _again = false;
        await _pass();
      } while (_again);
      lastSync = DateTime.now();
    } on RelinkNeeded {
      lastError = 'انتهى ربط الحساب. اربطه مرة أخرى.';
    } on DriveException catch (e) {
      lastError = 'رفض Drive الطلب (${e.status}).';
    } on SocketException {
      lastError = 'لا يوجد اتصال.';
    } on TimeoutException {
      lastError = 'لا يوجد اتصال.';
    } on Exception {
      lastError = 'تعذّرت المزامنة، ستُعاد لاحقاً.';
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _fetchRemote(DriveClient drive) async {
    final files = await drive.list();
    final pdfs = {
      for (final f in files)
        if (f.name.startsWith(_pdfPrefix))
          p.basenameWithoutExtension(f.name).substring(_pdfPrefix.length): f,
    };
    _remote = {
      for (final f in files)
        if (RemoteBook.parse(f, null) case final r?)
          r.id: RemoteBook.parse(f, pdfs[r.id])!,
    };
  }

  Future<void> _pass() async {
    await _loadState();
    final drive = _newDrive();
    await _fetchRemote(drive);
    for (final b in _library.books) {
      if (b.id == openBook) continue;
      await _syncBook(drive, b);
    }
    await _saveState();
  }

  /// The work on [b] on this device, or null when there is nothing to keep.
  Future<WorkBundle?> _localWork(BookEntry b) async {
    final prefs = await ReaderPrefs.rawBytes(b.id);
    final link = await BookLinkStore.handLinkedJson(b.id);
    final written = await InkStore.hasWriting(b.id);
    if (!written && link == null && !_hasBookmarks(prefs)) return null;
    return WorkBundle(
      ink: written ? await InkStore.rawBytes(b.id) : null,
      prefs: prefs,
      link: link,
    );
  }

  bool _hasBookmarks(Uint8List? prefs) {
    if (prefs == null) return false;
    try {
      final j = jsonDecode(utf8.decode(prefs)) as Map<String, dynamic>;
      return (j['bookmarks'] as List?)?.isNotEmpty ?? false;
    } on FormatException {
      return false;
    }
  }

  Future<void> _syncBook(DriveClient drive, BookEntry b) async {
    final work = await _localWork(b);
    final hash = work?.hash;
    final r = _remoteOf(b);
    final st = _state[b.id];
    final localChanged = hash != null && hash != st?.hash;
    final remoteChanged = r != null && r.file.modified != st?.remoteTime;

    if (r == null) {
      if (work != null) await _push(drive, b, work, null);
      return;
    }
    if (localChanged && remoteChanged) {
      final mine = await InkStore.modifiedAt(b.id);
      if (mine != null && mine.isAfter(r.savedAt)) {
        await _push(drive, b, work!, r);
      } else {
        await _pull(drive, b, r);
      }
    } else if (remoteChanged) {
      await _pull(drive, b, r);
    } else if (localChanged) {
      await _push(drive, b, work!, r);
    }
  }

  Future<void> _push(
    DriveClient drive,
    BookEntry b,
    WorkBundle work,
    RemoteBook? r,
  ) async {
    final description = jsonEncode({
      'title': b.title,
      'saved': DateTime.now().toUtc().toIso8601String(),
      'catalog': ?b.catalogId,
      'part': ?b.part,
      if (b.author.isNotEmpty) 'author': b.author,
      if (b.subject.isNotEmpty) 'subject': b.subject,
      if (b.cover.isNotEmpty) 'cover': b.cover,
    });
    Future<DriveFile> send(String? id) => drive.upload(
      id: id,
      name: '$_workPrefix${b.id}.zip',
      description: description,
      bytes: work.encode(),
    );
    final known = r?.file.id ?? _state[b.id]?.fileId;
    DriveFile f;
    try {
      f = await send(known);
    } on DriveException catch (e) {
      if (!e.notFound) rethrow;
      f = await send(null); // removed from Drive meanwhile
    }
    _state[b.id] = _Synced(f.id, work.hash, f.modified);
    final pdf = r?.pdfFile;
    final parsed = RemoteBook.parse(f, pdf);
    if (parsed != null) _remote[b.id] = parsed;
    if (r != null && r.id != b.id) _remote.remove(r.id);
    if (b.catalogId == null && pdf == null) await _pushPdf(drive, b);
  }

  Future<void> _pushPdf(DriveClient drive, BookEntry b) async {
    final f = await drive.uploadFile(
      name: '$_pdfPrefix${b.id}.pdf',
      description: b.title,
      file: File(_library.pathOf(b)),
    );
    final r = _remote[b.id];
    if (r == null) return;
    _remote[b.id] = RemoteBook(
      id: r.id,
      file: r.file,
      title: r.title,
      savedAt: r.savedAt,
      pdfFile: f,
    );
  }

  /// Brings the work of [r] to [b], keeping any writing it replaces.
  Future<void> _pull(DriveClient drive, BookEntry b, RemoteBook r) async {
    final w = WorkBundle.decode(await drive.download(r.file.id));
    final ink = w.ink;
    if (ink != null) {
      final mine = await InkStore.rawBytes(b.id);
      if (mine != null &&
          !listEquals(mine, ink) &&
          await InkStore.hasWriting(b.id)) {
        await InkStore.keepCopy(b.id);
      }
      await InkStore.writeRaw(b.id, ink);
    }
    final prefs = w.prefs;
    if (prefs != null) await ReaderPrefs.writeRaw(b.id, prefs);
    final link = w.link;
    if (link != null) await BookLinkStore.saveRawIfMissing(b.id, link);
    final now = await _localWork(b);
    _state[b.id] = _Synced(r.file.id, now?.hash ?? '', r.file.modified);
  }

  /// A book just entered the library: brings back the work saved for it.
  /// Matches by content, or by catalogue part when the file on the server
  /// was replaced by a new edition of the same book.
  Future<void> afterImport(BookEntry b) async {
    if (!isLinked()) return;
    try {
      await _loadState();
      final drive = _newDrive();
      if (_remote.isEmpty) await _fetchRemote(drive);
      final r = _remoteOf(b);
      if (r == null || _state[b.id]?.remoteTime == r.file.modified) return;
      // Newer writing already here goes up with the next sync instead.
      final mine = await InkStore.modifiedAt(b.id);
      if (mine != null &&
          mine.isAfter(r.savedAt) &&
          await InkStore.hasWriting(b.id)) {
        return;
      }
      await _pull(drive, b, r);
      await _saveState();
    } on Exception catch (e) {
      lastError = '$e';
    }
    notifyListeners();
  }

  /// Brings back a book that is on no server, from its PDF in Drive.
  Future<BookEntry> restoreFromDrive(RemoteBook r) async {
    final pdf = r.pdfFile;
    if (pdf == null) throw 'هذا الكتاب غير متوفر للتحميل.';
    final dir = await Directory.systemTemp.createTemp('nots_restore_');
    try {
      final file = File(p.join(dir.path, 'book.pdf'));
      final drive = _newDrive();
      await drive.downloadTo(pdf.id, file);
      final entry = await _library.importPdf(file.path, title: r.title);
      await _loadState();
      await _pull(drive, entry, r);
      await _saveState();
      notifyListeners();
      return entry;
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Removes the work on the book [bookId] from Drive.
  Future<void> forget(String bookId) async {
    if (!isLinked()) return;
    await _loadState();
    final drive = _newDrive();
    if (_remote.isEmpty) await _fetchRemote(drive);
    final r = _remote.remove(bookId);
    final id = r?.file.id ?? _state[bookId]?.fileId;
    if (id != null) await drive.delete(id);
    final pdf = r?.pdfFile;
    if (pdf != null) await drive.delete(pdf.id);
    _state.remove(bookId);
    await _saveState();
    notifyListeners();
  }

  /// The account was unlinked: what was agreed with it no longer holds.
  Future<void> reset() async {
    _soon?.cancel();
    _state.clear();
    _remote = {};
    lastSync = null;
    lastError = null;
    final f = _stateFile;
    if (await f.exists()) await f.delete();
    notifyListeners();
  }

  @override
  void dispose() {
    _soon?.cancel();
    super.dispose();
  }
}
