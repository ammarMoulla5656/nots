import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../book/book_link_store.dart';
import '../ink/ink_store.dart';
import '../ink/stroke.dart';
import '../catalog/own_covers.dart';
import '../ui/speed_log.dart';
import '../library/library_store.dart';
import '../reader/reader_prefs.dart';
import 'drive_client.dart';
import 'conflicts.dart';
import 'google_account.dart';
import 'merge.dart';

/// The work on one book, as kept in Drive: the writing, the place reached,
/// the bookmarks and a Word text linked by hand.
class WorkBundle {
  const WorkBundle({this.ink, this.prefs, this.link});

  final Uint8List? ink;
  final Uint8List? prefs;
  final String? link;

  /// Nothing the user would miss: at most the page reached.
  bool get isEmpty {
    if (ink != null || link != null) return false;
    final raw = prefs;
    if (raw == null) return true;
    try {
      final j = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      // Bookmarks and added pages are work too.
      return ((j['bookmarks'] as List?)?.isEmpty ?? true) &&
          ((j['extra'] as List?)?.isEmpty ?? true);
    } on FormatException {
      return true;
    }
  }

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
    this.fileName = '',
    this.size = 0,
    this.device = '',
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
  final String fileName;
  final int size;

  /// The device that saved this last.
  final String device;

  /// A book added from a file is on no server: its PDF is kept in Drive.
  final DriveFile? pdfFile;

  RemoteBook withPdf(DriveFile pdf) => RemoteBook(
    id: id,
    file: file,
    title: title,
    savedAt: savedAt,
    catalogId: catalogId,
    part: part,
    author: author,
    subject: subject,
    cover: cover,
    fileName: fileName,
    size: size,
    device: device,
    pdfFile: pdf,
  );

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
      fileName: m['file'] as String? ?? '$id.pdf',
      size: m['size'] as int? ?? 0,
      device: m['device'] as String? ?? '',
      pdfFile: pdf,
    );
  }
}

const _workPrefix = 'book-';
const _pdfPrefix = 'pdf-';

/// A mark that a book was removed from the account, for the other devices.
const _gonePrefix = 'gone-';
const _settingsName = 'settings.json';
const _settingsKey = '@settings';

/// What was last agreed with Drive for a book.
class _Synced {
  const _Synced(this.fileId, this.hash, this.remoteTime, [this.stamp = '']);

  final String fileId;
  final String hash;
  final String remoteTime;

  /// How the files of the work looked (sizes and times) when this was
  /// agreed; the same again means nothing changed, without reading them.
  /// Empty when not known.
  final String stamp;

  Map<String, String> toJson() => {
    'f': fileId,
    'h': hash,
    't': remoteTime,
    if (stamp.isNotEmpty) 's': stamp,
  };

  static _Synced fromJson(Map<String, dynamic> j) => _Synced(
    j['f'] as String,
    j['h'] as String,
    j['t'] as String,
    j['s'] as String? ?? '',
  );
}

/// Keeps everything of an account in its Drive: every book in the library
/// with the work on it, and the settings. The rule of this class: nothing
/// leaves this device until Drive holds it.
///
/// - A book from the server is listed with its work; its PDF stays on the
///   server. A book the user added goes with its PDF.
/// - A book of the account missing here enters the library at once, and its
///   file follows ([BookEntry.offloaded] books excepted).
/// - Two devices that changed the same book are merged, not overwritten
///   (see merge.dart). What was agreed last is kept as the merge's base.
/// - Removing a book everywhere leaves a mark in Drive that the other
///   devices follow, unless they changed the book since.
/// A small thing kept in the account besides the books: the app's settings,
/// the arrangement of the tools, the order and the last readings of the
/// books. Each is one small file on Drive, sent only when it changed.
class SyncedPref {
  SyncedPref(this.name, {required this.read, required this.write});

  /// The file's name on Drive.
  final String name;

  /// What this device holds now, or null when it has nothing yet.
  final Future<Uint8List?> Function() read;

  /// Takes what another device sent.
  final Future<void> Function(Uint8List bytes) write;
}

const _prefPrefix = 'pref-';

/// The cover made on a device from a book's first page.
const _coverPrefix = 'cover-';

class SyncEngine extends ChangeNotifier {
  /// The settings kept in the account (set by the app).
  List<SyncedPref> prefs = const [];
  Map<String, DriveFile> _prefFiles = {};

  SyncEngine(
    this._library, {
    required this.isLinked,
    required DriveClient Function() drive,
    this.accountEmail,
    this.deviceName,
    this.fetchCatalogBook,
    this.statePath,
    this.covers,
  }) : _newDrive = drive;

  /// Covers made from the first page of books added from a file: kept in
  /// Drive, so every device of the account shows the same.
  final OwnCovers? covers;

  /// Those covers in Drive, by book id.
  final _coverFiles = <String, DriveFile>{};

  final LibraryStore _library;
  final bool Function() isLinked;
  final DriveClient Function() _newDrive;
  final String? statePath;

  /// The account in use, to know whose data is on this device.
  final String? Function()? accountEmail;

  /// This device's name, shown on other devices when two versions meet.
  final Future<String> Function()? deviceName;

  /// Asks for the file of a book of the server's library.
  void Function(BookEntry book)? fetchCatalogBook;

  final _state = <String, _Synced>{};
  final _forgetting = <String>{};
  String? _owner;
  bool _stateLoaded = false;
  var _remote = <String, RemoteBook>{};
  var _gone = <String, DriveFile>{};
  DriveFile? _settings;
  bool _running = false;
  bool _again = false;
  Future<void> _current = Future.value();
  Timer? _soon;

  /// PDFs in Drive for books whose work is not there yet.
  final _pdfs = <String, DriveFile>{};

  /// The book open in the reader: its files are not replaced under it.
  String? openBook;

  String? lastError;
  DateTime? lastSync;
  bool get running => _running;

  /// What is being done right now, to show the user.
  String? activity;

  /// Google no longer accepts this device: only signing in again helps.
  bool needsSignIn = false;

  /// Drive has no room: nothing new reaches it until there is.
  bool driveFull = false;
  DriveQuota? quota;

  /// The account this device's data belongs to.
  Future<String?> owner() async {
    await _loadState();
    return _owner;
  }

  /// The account signed in is not the one this device's data belongs to. Until
  /// the user decides ([moveTo]), nothing may pass between the two.
  Future<bool> otherAccountsData() async {
    await _loadState();
    final email = accountEmail?.call();
    return _owner != null && email != null && _owner != email;
  }

  File get _stateFile =>
      File(statePath ?? p.join(_library.root.path, 'sync', 'state.json'));

  File _baseFile(String id) =>
      File(p.join(_stateFile.parent.path, 'base', '$id.zip'));

  File get _wipeMark => File(p.join(_library.root.path, 'wipe.pending'));

  File get _colors => File(p.join(_library.root.path, 'prefs', 'colors.json'));

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
      // Versions before accounts kept the books alone.
      final books = (j['books'] ?? j) as Map<String, dynamic>;
      _state.addAll(
        books.map(
          (k, v) => MapEntry(k, _Synced.fromJson(v as Map<String, dynamic>)),
        ),
      );
      _owner = j['owner'] as String?;
      _forgetting.addAll(((j['forget'] as List?) ?? const []).cast<String>());
    } on FormatException {
      _state.clear(); // the next sync compares everything again
    }
  }

  Future<void> _saveState() async {
    final f = _stateFile;
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'owner': ?_owner,
        'books': _state,
        'forget': _forgetting.toList(),
      }),
      flush: true,
    );
    await tmp.rename(f.path);
  }

  /// Syncs a little later, so that writing just finished is on disk and a
  /// burst of events is one sync.
  void requestSoon({Duration after = const Duration(seconds: 3)}) {
    if (!isLinked()) return;
    _soon?.cancel();
    _soon = Timer(after, () => unawaited(syncNow()));
  }

  /// Syncs, and returns when no sync is running: a caller that must know the
  /// result is never answered by a sync still half way.
  Future<void> syncNow() {
    if (!isLinked()) return Future.value();
    if (_running) {
      _again = true;
      return _current;
    }
    return _current = _run();
  }

  Future<void> _run() async {
    _running = true;
    lastError = null;
    needsSignIn = false;
    notifyListeners();
    try {
      do {
        _again = false;
        await _pass();
      } while (_again);
      lastSync = DateTime.now();
    } on RelinkNeeded {
      needsSignIn = true;
      lastError = 'انتهى تسجيل الدخول. سجّل الدخول مرة أخرى.';
    } on DriveException catch (e) {
      lastError = 'رفض Drive الطلب (${e.status}).';
    } on SocketException {
      lastError = 'لا يوجد اتصال.';
    } on http.ClientException {
      lastError = 'لا يوجد اتصال.';
    } on TimeoutException {
      lastError = 'لا يوجد اتصال.';
    } on Exception {
      lastError = 'تعذّرت المزامنة، ستُعاد لاحقاً.';
    } finally {
      _running = false;
      activity = null;
      notifyListeners();
    }
  }

  void _doing(String? what) {
    activity = what;
    notifyListeners();
  }

  Future<void> _fetchRemote(DriveClient drive) async {
    final files = await drive.list();
    DriveFile? settings;
    final prefFiles = <String, DriveFile>{};
    final pdfs = <String, DriveFile>{};
    final gone = <String, DriveFile>{};
    final covers = <String, DriveFile>{};
    for (final f in files) {
      if (f.name == _settingsName) settings = f;
      if (f.name.startsWith(_prefPrefix)) prefFiles[f.name] = f;
      if (f.name.startsWith(_pdfPrefix)) {
        final id = p.basenameWithoutExtension(f.name);
        pdfs[id.substring(_pdfPrefix.length)] = f;
      }
      if (f.name.startsWith(_gonePrefix)) {
        gone[f.name.substring(_gonePrefix.length)] = f;
      }
      if (f.name.startsWith(_coverPrefix) && f.name.endsWith('.jpg')) {
        final id = p.basenameWithoutExtension(f.name);
        covers[id.substring(_coverPrefix.length)] = f;
      }
    }
    _coverFiles
      ..clear()
      ..addAll(covers);
    _settings = settings;
    _prefFiles = prefFiles;
    _gone = gone;
    _pdfs
      ..clear()
      ..addAll(pdfs);
    _remote = {
      for (final f in files)
        if (RemoteBook.parse(f, null) case final r?)
          if (!gone.containsKey(r.id)) r.id: RemoteBook.parse(f, pdfs[r.id])!,
    };
  }

  /// Time spent reading the work of books and fingerprinting it, during a
  /// pass (for the speed log).
  final _readClock = Stopwatch(), _hashClock = Stopwatch();

  Future<void> _pass() async {
    if (await otherAccountsData()) return;
    final log = SpeedLog.instance;
    final passClock = Stopwatch()..start();
    _readClock.reset();
    _hashClock.reset();
    _owner ??= accountEmail?.call();
    final drive = _newDrive();
    _doing('جارٍ فحص درايف…');
    await log.span('sync: list Drive', () => _fetchRemote(drive));
    driveFull = false;
    for (final id in _forgetting.toList()) {
      await _forgetNow(drive, id);
    }
    await _followRemovals(drive);
    await _listAccountBooks();
    Object? failed;
    final books = _library.books;
    _workDirs = null;
    var read = 0;
    for (var i = 0; i < books.length; i++) {
      // Telling every book would rebuild what listens many times a second.
      if (i % 20 == 0) _doing('جارٍ المزامنة ${i + 1} من ${books.length}…');
      try {
        if (await _syncBook(drive, books[i])) {
          read++;
          await _saveState();
        }
      } on DriveException catch (e) {
        if (e.storageFull) {
          driveFull = true;
        } else {
          failed = e; // the other books still go
        }
      }
    }
    try {
      await _syncSettings(drive);
      for (final pref in prefs) {
        await _syncPref(drive, pref);
      }
      await _syncCovers(drive);
    } on DriveException catch (e) {
      if (e.storageFull) driveFull = true;
    }
    await _saveState();
    log.took(
      'sync pass',
      passClock.elapsedMilliseconds,
      '${books.length} books, $read read · reading work ${_readClock.elapsedMilliseconds}ms · '
          'fingerprints ${_hashClock.elapsedMilliseconds}ms',
    );
    try {
      quota = await drive.quota();
      if (quota?.full ?? false) driveFull = true;
    } on DriveException {
      quota = null; // only the gauge is lost: the sync itself went well
    }
    _doing(null);
    await _bringFiles(drive);
    if (failed != null) throw failed;
  }

  /// Removes here the books removed on another device, unless they changed
  /// here since; then the removal is undone, and they go up again.
  Future<void> _followRemovals(DriveClient drive) async {
    for (final e in _gone.entries.toList()) {
      final b = _library.byId(e.key);
      if (b == null || b.id == openBook) continue;
      final work = await _localWork(b);
      final st = _state[b.id];
      final untouched = st == null
          ? work.isEmpty
          : await _hashOf(b, work) == st.hash;
      if (untouched) {
        await _library.remove(b, deleteWriting: true);
        _state.remove(b.id);
        await _dropBase(b.id);
      } else {
        await drive.delete(e.value.id);
        _gone.remove(e.key);
      }
    }
  }

  /// Every book of the account enters the library, even before its file.
  Future<void> _listAccountBooks() async {
    for (final r in _remote.values) {
      if (_localOf(r) != null || _forgetting.contains(r.id)) continue;
      await _library.addListed(
        BookEntry(
          id: r.id,
          title: r.title,
          fileName: r.fileName,
          size: r.size,
          added: r.savedAt,
          lastOpened: r.savedAt,
          catalogId: r.catalogId,
          part: r.part,
          author: r.author,
          subject: r.subject,
          cover: r.cover,
        ),
      );
    }
  }

  /// The work on [b] on this device.
  Future<WorkBundle> _localWork(BookEntry b) async {
    final running = _readClock.isRunning;
    _readClock.start();
    try {
      final raw = await InkStore.rawBytes(b.id);
      return WorkBundle(
        ink: raw != null && StrokeCodec.hasContent(raw) ? raw : null,
        prefs: await ReaderPrefs.rawBytes(b.id),
        link: await BookLinkStore.handLinkedJson(b.id),
      );
    } finally {
      if (!running) _readClock.stop();
    }
  }

  /// A book's state as agreed with Drive: its work and its name.
  Future<String> _hashOf(BookEntry b, WorkBundle w) async {
    final running = _hashClock.isRunning;
    _hashClock.start();
    try {
      final title = b.title;
      final size = (w.ink?.length ?? 0) + (w.prefs?.length ?? 0);
      // A large book's writing takes a while to fingerprint: not on the
      // thread that draws the screen.
      return size > 64 * 1024
          ? await Isolate.run(() => _bundleHash(w, title))
          : _bundleHash(w, title);
    } finally {
      if (!running) _hashClock.stop();
    }
  }

  static String _bundleHash(WorkBundle w, String title) =>
      sha256.convert(utf8.encode('${w.hash}|$title')).toString();

  /// Folders of the work's files, looked up once per pass.
  ({String ink, String prefs, String links})? _workDirs;

  /// How the files of [b]'s work look on disk (size and time of each) and
  /// its title. The same as when last agreed means nothing changed here,
  /// and nothing needs reading.
  Future<String> _stampOf(BookEntry b) async {
    final d = _workDirs ??= (
      ink: (await InkStore.dirProvider()).path,
      prefs: (await ReaderPrefs.dirProvider()).path,
      links: (await BookLinkStore.dirProvider()).path,
    );
    Future<String> one(String dir, String ext) async {
      final st = await FileStat.stat(p.join(dir, '${b.id}$ext'));
      return st.type == FileSystemEntityType.notFound
          ? '-'
          : '${st.size}@${st.modified.microsecondsSinceEpoch}';
    }

    return '${await one(d.ink, '.nots')}|${await one(d.prefs, '.json')}|'
        '${await one(d.links, '.json')}|${b.title}';
  }

  Future<void> _agree(
    BookEntry b,
    DriveFile f,
    WorkBundle w, {
    String stamp = '',
  }) async {
    _state[b.id] = _Synced(f.id, await _hashOf(b, w), f.modified, stamp);
    final base = _baseFile(b.id);
    await base.parent.create(recursive: true);
    final tmp = File('${base.path}.tmp');
    await tmp.writeAsBytes(w.encode(), flush: true);
    await tmp.rename(base.path);
  }

  Future<WorkBundle> _baseOf(String id) async {
    final f = _baseFile(id);
    if (!await f.exists()) return const WorkBundle();
    try {
      return WorkBundle.decode(await f.readAsBytes());
    } on Exception {
      return const WorkBundle(); // no history: both sides are kept whole
    }
  }

  Future<void> _dropBase(String id) async {
    final f = _baseFile(id);
    if (await f.exists()) await f.delete();
  }

  /// Brings [b] and Drive to the same state. Returns false when nothing
  /// had changed on either side: then not one of its files was read.
  Future<bool> _syncBook(DriveClient drive, BookEntry b) async {
    final r = _remoteOf(b);
    final st = _state[b.id];
    final remoteChanged = r != null && r.file.modified != st?.remoteTime;
    // The file first: another device must never see a book it cannot get.
    final needsPdf =
        !driveFull &&
        !b.isSpeedTest &&
        b.catalogId == null &&
        r?.pdfFile == null &&
        !_pdfs.containsKey(b.id) &&
        _library.isOnDevice(b);
    final stamp = await _stampOf(b);
    if (st != null &&
        st.stamp == stamp &&
        !remoteChanged &&
        !needsPdf &&
        (r != null || b.isSpeedTest)) {
      return false;
    }
    final work = await _localWork(b);
    final localChanged = st == null
        ? !work.isEmpty
        : await _hashOf(b, work) != st.hash;
    final open = b.id == openBook;
    // The test library is read and fingerprinted like a synced book (that
    // is what is measured), but stays on this device.
    if (b.isSpeedTest) {
      _state[b.id] = _Synced('', await _hashOf(b, work), '', stamp);
      return true;
    }

    if (needsPdf) await _pushPdf(drive, b);
    if (r == null) {
      if (!driveFull) await _push(drive, b, work, null, stamp: stamp);
    } else if (remoteChanged && open) {
      return true; // it comes when the book is closed
    } else if (localChanged && remoteChanged) {
      await _merge(drive, b, work, r);
    } else if (remoteChanged) {
      await _pull(drive, b, r);
    } else if (localChanged && !driveFull) {
      await _push(drive, b, work, r, stamp: stamp);
    } else if (st != null && !localChanged) {
      // The same work; only the files were touched. Remember how they look.
      _state[b.id] = _Synced(st.fileId, st.hash, st.remoteTime, stamp);
    }
    return true;
  }

  Future<void> _push(
    DriveClient drive,
    BookEntry b,
    WorkBundle work,
    RemoteBook? r, {
    String stamp = '',
  }) async {
    final device = await deviceName?.call();
    final description = jsonEncode({
      'title': b.title,
      'saved': DateTime.now().toUtc().toIso8601String(),
      'device': ?device,
      'file': b.fileName,
      'size': b.size,
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
    await _agree(b, f, work, stamp: stamp);
    final parsed = RemoteBook.parse(f, r?.pdfFile ?? _pdfs[b.id]);
    if (parsed != null) _remote[b.id] = parsed;
    if (r != null && r.id != b.id) _remote.remove(r.id);
  }

  Future<void> _pushPdf(DriveClient drive, BookEntry b) async {
    _doing('جارٍ رفع «${b.title}»…');
    final f = await drive.uploadFile(
      name: '$_pdfPrefix${b.id}.pdf',
      description: b.title,
      file: File(_library.pathOf(b)),
    );
    _pdfs[b.id] = f;
    final r = _remote[b.id];
    if (r != null) _remote[b.id] = r.withPdf(f);
  }

  Future<void> _write(BookEntry b, WorkBundle w) async {
    final ink = w.ink;
    if (ink != null) {
      await InkStore.writeRaw(b.id, ink);
    } else {
      await InkStore.deleteRaw(b.id);
    }
    final prefs = w.prefs;
    if (prefs != null) await ReaderPrefs.writeRaw(b.id, prefs);
    final link = w.link;
    if (link != null) await BookLinkStore.saveRawIfMissing(b.id, link);
  }

  /// Takes the state of Drive: nothing changed here since the last agreement.
  Future<void> _pull(DriveClient drive, BookEntry b, RemoteBook r) async {
    final w = WorkBundle.decode(await drive.download(r.file.id));
    await _write(b, w);
    if (r.title != b.title) await _library.rename(b, r.title);
    final stamp = await _stampOf(b);
    await _agree(b, r.file, await _localWork(b), stamp: stamp);
  }

  /// Both sides changed: keeps what each one did, and sends the result.
  Future<void> _merge(
    DriveClient drive,
    BookEntry b,
    WorkBundle mine,
    RemoteBook r,
  ) async {
    final theirs = WorkBundle.decode(await drive.download(r.file.id));
    final base = await _baseOf(b.id);
    final mineAt = await ReaderPrefs.modifiedAt(b.id);
    final theirsNewer = mineAt == null || r.savedAt.isAfter(mineAt);
    final ink = mergeBook(base.ink, mine.ink, theirs.ink);
    await _write(
      b,
      WorkBundle(
        ink: ink.ink,
        prefs: mergePrefs(
          base.prefs,
          mine.prefs,
          theirs.prefs,
          theirsNewer: theirsNewer,
        ),
        link: mine.link ?? theirs.link,
      ),
    );
    if (ink.sides.isNotEmpty) {
      await ConflictStore.add(b.id, ink.sides, device: r.device, at: r.savedAt);
    }
    if (theirsNewer && r.title != b.title) await _library.rename(b, r.title);
    if (driveFull) {
      // It goes up when there is room; until then Drive's state is the base.
      await _agree(b, r.file, theirs);
    } else {
      final stamp = await _stampOf(b);
      await _push(drive, b, await _localWork(b), r, stamp: stamp);
    }
  }

  /// A cover made here goes up once; one made on another device comes down.
  Future<void> _syncCovers(DriveClient drive) async {
    final own = covers;
    if (own == null) return;
    await own.load();
    for (final b in _library.books) {
      if (!OwnCovers.wants(b) || b.isSpeedTest) continue;
      final remote = _coverFiles[b.id];
      if (own.has(b.id)) {
        if (remote != null || driveFull) continue;
        final bytes = await own.bytesOf(b.id);
        if (bytes == null) continue;
        _coverFiles[b.id] = await drive.upload(
          name: '$_coverPrefix${b.id}.jpg',
          description: '',
          bytes: bytes,
        );
      } else if (remote != null) {
        await own.save(b.id, await drive.download(remote.id));
      }
    }
  }

  Future<void> _syncSettings(DriveClient drive) async {
    final f = _colors;
    final mine = await f.exists() ? await f.readAsBytes() : null;
    final hash = mine == null ? null : sha256.convert(mine).toString();
    final st = _state[_settingsKey];
    final r = _settings;
    if (r != null && r.modified != st?.remoteTime) {
      final bytes = await drive.download(r.id);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
      _state[_settingsKey] = _Synced(
        r.id,
        sha256.convert(bytes).toString(),
        r.modified,
      );
    } else if (mine != null && hash != st?.hash && !driveFull) {
      final sent = await drive.upload(
        id: r?.id,
        name: _settingsName,
        description: '',
        bytes: mine,
      );
      _settings = sent;
      _state[_settingsKey] = _Synced(sent.id, hash!, sent.modified);
    }
  }

  /// The same as [_syncSettings], for one of [prefs]: what changed on
  /// another device comes here; what changed here goes up.
  Future<void> _syncPref(DriveClient drive, SyncedPref pref) async {
    final name = '$_prefPrefix${pref.name}';
    final key = '@$name';
    final mine = await pref.read();
    final hash = mine == null ? null : sha256.convert(mine).toString();
    final st = _state[key];
    final r = _prefFiles[name];
    if (r != null && r.modified != st?.remoteTime) {
      final bytes = await drive.download(r.id);
      await pref.write(bytes);
      final now = await pref.read();
      _state[key] = _Synced(
        r.id,
        now == null ? '' : sha256.convert(now).toString(),
        r.modified,
      );
    } else if (mine != null && hash != st?.hash && !driveFull) {
      final sent = await drive.upload(
        id: r?.id,
        name: name,
        description: '',
        bytes: mine,
      );
      _prefFiles[name] = sent;
      _state[key] = _Synced(sent.id, hash!, sent.modified);
    }
  }

  /// Brings the files of the books that are only listed so far. Returns the
  /// books whose file is not here afterwards. With [all], also the ones the
  /// user took off this device; books of the server's library are left out
  /// then, as any device can get them from the server.
  Future<List<BookEntry>> _bringFiles(
    DriveClient drive, {
    bool all = false,
  }) async {
    final missing = <BookEntry>[];
    final books = [
      for (final b in _library.books)
        if (!_library.isOnDevice(b) && (all || !b.offloaded)) b,
    ];
    for (var i = 0; i < books.length; i++) {
      final b = books[i];
      if (b.catalogId != null) {
        if (!all) fetchCatalogBook?.call(b);
        continue;
      }
      _doing('جارٍ تنزيل كتبك ${i + 1} من ${books.length}…');
      if (!await _bringFile(drive, b)) missing.add(b);
    }
    _doing(null);
    return missing;
  }

  Future<bool> _bringFile(DriveClient drive, BookEntry b) async {
    final pdf = _remoteOf(b)?.pdfFile ?? _pdfs[b.id];
    if (pdf == null) return false;
    final target = File(_library.pathOf(b));
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    await drive.downloadTo(pdf.id, part);
    if (await fingerprintFile(part) != b.id) {
      await part.delete();
      return false; // damaged on the way: the next sync tries again
    }
    await part.rename(target.path);
    await _library.fileArrived(b);
    return true;
  }

  /// Brings the file of [b] now, because the user asked for it.
  Future<void> bring(BookEntry b) async {
    if (b.catalogId != null) {
      await _library.setOffloaded(b, false);
      fetchCatalogBook?.call(b);
      return;
    }
    await _loadState();
    final drive = _newDrive();
    if (_remote.isEmpty) await _fetchRemote(drive);
    if (!await _bringFile(drive, b)) throw 'هذا الكتاب غير متوفر في درايف.';
    notifyListeners();
  }

  /// A book just entered the library: joins it with what Drive has for it.
  /// Matches by content, or by catalogue part when the file on the server
  /// was replaced by a new edition of the same book.
  Future<void> afterImport(BookEntry b) async {
    if (!isLinked() || await otherAccountsData()) return;
    try {
      if (b.catalogId != null) {
        for (final old in _library.books) {
          final listedOnly =
              old.id != b.id &&
              old.catalogId == b.catalogId &&
              old.part == b.part &&
              !_library.isOnDevice(old);
          if (!listedOnly) continue;
          // Listed under the old edition: its work is in Drive.
          await _library.remove(old, deleteWriting: true);
          _state.remove(old.id);
          await _dropBase(old.id);
        }
      }
      final drive = _newDrive();
      if (_remote.isEmpty) await _fetchRemote(drive);
      await _syncBook(drive, b);
      await _saveState();
    } on Exception catch (e) {
      lastError = '$e';
    }
    notifyListeners();
  }

  /// Removes the book [bookId] from the account, on every device. Without a
  /// connection it is remembered and done by the next sync.
  Future<void> forget(String bookId) async {
    if (!isLinked()) return;
    await _loadState();
    _forgetting.add(bookId);
    await _saveState();
    final drive = _newDrive();
    if (_remote.isEmpty) await _fetchRemote(drive);
    await _forgetNow(drive, bookId);
    await _saveState();
    notifyListeners();
  }

  Future<void> _forgetNow(DriveClient drive, String bookId) async {
    if (!_gone.containsKey(bookId)) {
      _gone[bookId] = await drive.upload(
        name: '$_gonePrefix$bookId',
        description: '',
        bytes: Uint8List(0),
      );
    }
    final r = _remote.remove(bookId);
    final id = r?.file.id ?? _state[bookId]?.fileId;
    if (id != null) await drive.delete(id);
    final pdf = r?.pdfFile ?? _pdfs[bookId];
    if (pdf != null) await drive.delete(pdf.id);
    final cover = _coverFiles.remove(bookId);
    if (cover != null) await drive.delete(cover.id);
    _pdfs.remove(bookId);
    _state.remove(bookId);
    await _dropBase(bookId);
    await ConflictStore.save(bookId, const {});
    _forgetting.remove(bookId);
  }

  /// The books whose latest state is not in Drive: leaving the account now
  /// would lose them.
  Future<List<BookEntry>> unsaved() async {
    await _loadState();
    final out = <BookEntry>[];
    for (final b in _library.books) {
      final st = _state[b.id];
      final r = _remoteOf(b);
      final saved =
          st != null &&
          r != null &&
          (st.stamp.isNotEmpty && st.stamp == await _stampOf(b) ||
              st.hash == await _hashOf(b, await _localWork(b))) &&
          (b.catalogId != null || r.pdfFile != null);
      if (!saved) out.add(b);
    }
    return out;
  }

  /// Before leaving: sends what is left, and says what could not be sent.
  Future<List<BookEntry>> saveEverything() async {
    await syncNow();
    return unsaved();
  }

  /// Before moving to another account: everything of this account is brought
  /// to this device, since the next account can only receive what is here.
  /// Returns the books whose file could not be brought.
  Future<List<BookEntry>> gatherEverything() async {
    await syncNow();
    return _bringFiles(_newDrive(), all: true);
  }

  /// This device's data now belongs to [email]: all of it goes to that
  /// account by the next sync. The old account's Drive is left as it is.
  Future<void> moveTo(String? email) async {
    await _loadState();
    _soon?.cancel();
    _state.clear();
    _remote = {};
    _gone = {};
    _settings = null;
    _forgetting.clear();
    _pdfs.clear();
    _owner = email;
    driveFull = false;
    quota = null;
    lastError = null;
    final base = Directory(p.join(_stateFile.parent.path, 'base'));
    if (await base.exists()) await base.delete(recursive: true);
    await _saveState();
    notifyListeners();
  }

  /// The account left: its data leaves this device. A mark on disk finishes
  /// the job if the app is stopped half way, so no account's books are ever
  /// left for the next one to inherit.
  Future<void> wipeDevice() async {
    _soon?.cancel();
    await _wipeMark.writeAsString('', flush: true);
    await finishWipe();
  }

  /// Finishes a removal that was interrupted; does nothing otherwise.
  Future<void> finishWipe() async {
    if (!await _wipeMark.exists()) return;
    await _library.wipe();
    _state.clear();
    _forgetting.clear();
    _pdfs.clear();
    _remote = {};
    _gone = {};
    _settings = null;
    _owner = null;
    _stateLoaded = false;
    driveFull = false;
    quota = null;
    lastSync = null;
    lastError = null;
    await _wipeMark.delete();
    notifyListeners();
  }

  @override
  void dispose() {
    _soon?.cancel();
    super.dispose();
  }
}
