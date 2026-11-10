import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../book/masdar_link.dart';
import '../catalog/author_screen.dart';
import '../catalog/book_detail_screen.dart';
import '../catalog/catalog_screen.dart';
import '../catalog/catalog_store.dart';
import '../catalog/download_manager.dart';
import '../catalog/own_covers.dart';
import '../ink/ink_store.dart';
import '../notes/note_pdf.dart';
import '../notes/paper_templates.dart';
import '../notes/paper.dart';
import '../reader/reader_prefs.dart';
import '../reader/reader_screen.dart';
import '../reader/tool_layout.dart';
import '../sync/drive_client.dart';
import '../sync/google_account.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_sheet.dart';
import '../stats/usage.dart';
import '../stats/usage_upload.dart';
import '../ui/app_settings.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'book_widgets.dart';
import 'books_tab.dart';
import 'home_bar.dart';
import 'home_sheets.dart';
import 'collections.dart';
import 'collections_ui.dart';
import 'library_store.dart';
import 'notes_tab.dart';
import 'package_import.dart';

/// How many books "the last books" lists.
const historyCount = 10;

/// Names of the tabs in the speed log.

/// The main screen: three tabs (my books, the books to download, my notes),
/// a floating bar to move between them and the star that starts a new paper.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  LibraryStore? _library;
  late CatalogStore _catalog;
  late DownloadManager _downloads;
  late GoogleAccount _account;
  late SyncEngine _sync;
  late final AppLifecycleListener _lifecycle;
  final _progress = ReadProgress();
  int _tab = 0;

  /// A book is open in the reader (the statistics wait meanwhile).
  bool _reading = false;
  bool _busy = false;

  /// Tabs shown at least once. The others are not built: at start only
  /// «كتبي» does any work.
  final _visited = <int>{};

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        Usage.instance.foreground(false);
        if (_library != null) _sync.requestSoon();
      },
      onShow: () => Usage.instance.foreground(true),
      // What another device did since shows up when coming back.
      onResume: () {
        if (_library != null) _sync.requestSoon();
      },
    );
    _init();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    unawaited(AppSettings.instance.load());
    final lib = await LibraryStore.open();
    await _migrateRecentList(lib);
    final catalog = CatalogStore(lib.root);
    await catalog.load();
    final account = GoogleAccount();
    try {
      await account.restore();
    } on Exception {
      // An unreadable key store only means linking the account again.
    }
    final sync = SyncEngine(
      lib,
      isLinked: () => account.linked,
      accountEmail: () => account.email,
      deviceName: deviceNameOfThis,
      drive: () =>
          DriveClient(({renew = false}) => account.accessToken(renew: renew)),
      covers: OwnCovers.instance,
    );
    await sync.finishWipe();
    // Stopped while being asked about another account's data: ask again.
    if (await sync.otherAccountsData()) await account.unlink();
    _catalog = catalog;
    _account = account;
    _sync = sync;
    _downloads = DownloadManager(lib, lib.root, afterImport: sync.afterImport);
    sync.fetchCatalogBook = _fetchFromLibrary;
    // Everything the user set goes to the account with the books.
    Future<SyncedPref> fileIn(
      String name,
      Future<Directory> Function() dir,
      Future<void> Function() reload,
    ) async => SyncedPref(
      name,
      read: () async {
        final f = File(p.join((await dir()).path, name));
        return await f.exists() ? f.readAsBytes() : null;
      },
      write: (bytes) async {
        final d = await dir();
        await d.create(recursive: true);
        await File(p.join(d.path, name)).writeAsBytes(bytes, flush: true);
        await reload();
      },
    );
    sync.prefs = [
      await fileIn(
        'settings.json',
        AppSettings.dirProvider,
        AppSettings.instance.load,
      ),
      await fileIn(
        'tools.json',
        ToolLayout.dirProvider,
        ToolLayout.instance.load,
      ),
      SyncedPref(
        'reading.json',
        read: () async => lib.readingBytes(),
        write: lib.applyReading,
      ),
      // The collections: merged, the later change of each one winning.
      SyncedPref(
        Collections.fileName,
        read: () async => Collections.instance.bytes(),
        write: Collections.instance.applyBytes,
      ),
    ];
    await Collections.instance.load();
    Collections.instance.addListener(sync.requestSoon);
    AppSettings.instance.addListener(sync.requestSoon);
    ToolLayout.instance.addListener(sync.requestSoon);
    if (!mounted) return;
    setState(() => _library = lib);
    // The reader asks here which books are in Masdar, and at which volume.
    MasdarRef.resolve = _masdarOf;
    unawaited(_listenForLinks());
    // A book with no cover gets a picture of its first page, now and
    // whenever one arrives (added, or brought from the account).
    // Not on every change of the library (a sync makes many): once it has
    // been quiet for a moment.
    Timer? coversSoon;
    lib.addListener(() {
      coversSoon?.cancel();
      coversSoon = Timer(
        const Duration(seconds: 2),
        () => unawaited(OwnCovers.instance.fillMissing(lib)),
      );
    });
    Timer(
      const Duration(seconds: 4),
      () => unawaited(OwnCovers.instance.fillMissing(lib)),
    );
    unawaited(_dropTextNotes(lib));
    unawaited(_startUsage(lib));
    unawaited(PaperTemplates.instance.load());
    unawaited(catalog.refresh());
    // Not while the first screen is being shown and scrolled.
    sync.requestSoon(after: const Duration(seconds: 8));
  }

  /// The statistics: recorded on this device, sent now and then over
  /// Wi-Fi in a quiet moment.
  Future<void> _startUsage(LibraryStore lib) async {
    await Usage.instance.load();
    await FeedbackOutbox.instance.load();
    final up = UsageUploader(
      library: lib,
      account: () =>
          (email: _account.email, name: _account.name, linked: _account.linked),
      reading: () => _reading,
    );
    Usage.instance.onMinute = () => unawaited(up.tick());
  }

  /// A test version had typed text notes (paper code `text|…`); they were
  /// taken out of the app. Any made then leave this device and the account.
  Future<void> _dropTextNotes(LibraryStore lib) async {
    final gone = [
      for (final b in lib.books)
        if (b.isNote && b.author.startsWith('text|')) b,
    ];
    for (final b in gone) {
      await lib.remove(b, deleteWriting: true);
      Collections.instance.forget(b.id);
      try {
        await _sync.forget(b.id);
      } on Exception {
        // Without a connection: the next sync of the account removes it.
      }
    }
    // The speed test's generated library (files named speed-test-…, kept
    // on this device only): its panel left the app, so does the library.
    for (final b in [...lib.books.where((b) => b.isSpeedTest)]) {
      await lib.remove(b, deleteWriting: true);
      Collections.instance.forget(b.id);
    }
    final docs = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'docs'),
    );
    if (await docs.exists()) await docs.delete(recursive: true);
  }

  /// Older versions kept a list of opened file paths and keyed writing by
  /// path. Bring the files that still exist into the library, with their
  /// writing.
  Future<void> _migrateRecentList(LibraryStore lib) async {
    final f = File(
      p.join((await getApplicationSupportDirectory()).path, 'recent.json'),
    );
    if (!await f.exists()) return;
    try {
      final paths = (jsonDecode(await f.readAsString()) as List).cast<String>();
      for (final path in paths) {
        if (!File(path).existsSync()) continue;
        final legacy = InkStore.legacyKey(path);
        final entry = await lib.importPdf(path);
        await InkStore.adopt(legacy, entry.id);
      }
    } on FormatException {
      // Nothing to bring over.
    }
    await f.rename('${f.path}.migrated');
  }

  /// A book of the account from the server's library: its file comes from
  /// there, like any download.
  void _fetchFromLibrary(BookEntry b) {
    final id = b.catalogId;
    final book = id == null ? null : _catalog.byId(id);
    final part = book?.partNumbered(b.part ?? 1);
    if (book != null && part != null) _downloads.enqueue(book, part);
  }

  Future<void> _bring(BookEntry b) async {
    setState(() => _busy = true);
    try {
      await _sync.bring(b);
      if (b.catalogId != null) _say('جارٍ تنزيل الكتاب…');
    } catch (e) {
      _say(
        b.catalogId == null
            ? 'تعذّر التنزيل: $e'
            : 'لم يعد هذا الكتاب متوفراً في المكتبة، وكتابتك عليه محفوظة.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The book in the Masdar app, from the library's catalogue.
  MasdarRef? _masdarOf(BookEntry b) {
    final id = b.catalogId;
    final book = id == null ? null : _catalog.byId(id);
    final masdar = book?.masdarId;
    if (book == null || masdar == null) return null;
    return MasdarRef(
      masdar,
      MasdarRef.volumeOf(multiPart: book.multiPart, part: b.part ?? 1),
    );
  }

  static const _app = MethodChannel('nots/app');

  /// Masdar links opened with the app, or shared to it: the link the app
  /// was started with, then each one that comes while it runs.
  Future<void> _listenForLinks() async {
    _app.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) {
        await _openLink(call.arguments as String);
      }
    });
    try {
      final first = await _app.invokeMethod<String>('takeLink');
      if (first != null) await _openLink(first);
    } on MissingPluginException {
      // Not on Android: links do not come this way.
    }
  }

  /// Opens the page a Masdar link points to, in the same book here.
  Future<void> _openLink(String text) async {
    final link = parseMasdarLink(text);
    if (link == null) {
      _say('لا يوجد في هذا النص رابط من المصدر.');
      return;
    }
    final book = _catalog.books.where((b) => b.masdarId == link.id).firstOrNull;
    if (book == null) {
      _say('هذا الكتاب من المصدر ليس في مكتبة قلم المصدر بعد.');
      return;
    }
    // A book without volumes is volume 0 in the link.
    final part = link.volume == 0
        ? (book.parts.firstOrNull?.number ?? 1)
        : link.volume;
    final lib = _library!;
    final here = lib.installedCatalog(book.id, part);
    if (here != null) {
      await _open(here, page: link.page);
      return;
    }
    final file = book.partNumbered(part);
    if (file == null) {
      _say('هذا الجزء من «${book.title}» غير متوفر في المكتبة بعد.');
      return;
    }
    // Not on this device yet: it downloads, and opens at the page when it
    // is here.
    _downloads.enqueue(book, file);
    _say(
      'جارٍ تنزيل «${book.titleOf(file)}»، وتُفتح الصفحة ${link.page} حين يكتمل.',
    );
    void arrived() {
      final entry = lib.installedCatalog(book.id, part);
      if (entry == null) return;
      lib.removeListener(arrived);
      if (mounted) unawaited(_open(entry, page: link.page));
    }

    lib.addListener(arrived);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookDetailScreen(
          book: book,
          downloads: _downloads,
          library: lib,
          onOpen: _open,
          store: _catalog,
        ),
      ),
    );
  }

  Future<void> _open(BookEntry b, {int? page}) async {
    final lib = _library!;
    if (!lib.isOnDevice(b)) {
      if (!_busy) await _bring(b);
      if (!lib.isOnDevice(b)) return;
    }
    await lib.touch(b);
    if (!mounted) return;
    _sync.openBook = b.id;
    _reading = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(library: lib, book: b, openAtPage: page),
      ),
    );
    _sync.openBook = null;
    _reading = false;
    // Leaving a book or a note saves everything to Drive at once.
    if (_library != null) unawaited(_sync.syncNow());
    unawaited(_progress.load([b.id]));
    if (mounted) setState(() {});
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _showAccount() => showNotsSheet<void>(
    context,
    builder: (_) => SyncSheet(
      account: _account,
      sync: _sync,
      library: _library!,
      beforeWipe: _downloads.cancelAll,
    ),
  );

  Future<void> _showHistory() async {
    final lib = _library!;
    final books = lib.recentlyRead(count: historyCount);
    unawaited(_progress.load(books.map((b) => b.id)));
    final picked = await showNotsSheet<BookEntry>(
      context,
      builder: (_) => HistorySheet(books: books, progress: _progress),
    );
    if (picked != null) await _open(picked);
  }

  Future<void> _showNew() async {
    if (_library == null || _busy) return;
    final r = await showNotsSheet<Object>(
      context,
      builder: (_) => const NewPaperSheet(),
    );
    if (r is PaperStyle) {
      await _makeNote(r.encode());
    } else if (r is PaperTemplate) {
      await _makeNote(r.code);
    } else if (r == NewPaperSheet.addBook) {
      await _add();
    }
  }

  Future<void> _makeNote(String paper) async {
    setState(() => _busy = true);
    Usage.instance.feature('new_note');
    try {
      final entry = await createNoteOn(_library!, paper);
      // It opens at once; the next sync takes it to Drive meanwhile (it
      // used to be sent first, which took seconds before the page showed).
      _sync.requestSoon();
      if (!mounted) return;
      setState(() => _tab = 2);
      await _open(entry);
    } catch (e) {
      _say('تعذّر إنشاء الورقة: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    // Any file: Android does not know the .nots extension, so a filter on it
    // would hide the packages.
    final files = await FilePicker.pickFiles(
      type: FileType.any,
      dialogTitle: 'اختر كتاب PDF أو ملف نوتس',
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null || !mounted) return;
    final ext = p.extension(files.first.name).toLowerCase();
    Usage.instance.feature('add_file');
    if (ext != '.pdf' && ext != '.nots') {
      _say('اختر ملف PDF أو ملف نوتس (.nots).');
      return;
    }
    setState(() => _busy = true);
    try {
      final BookEntry entry;
      if (ext == '.nots') {
        entry = await importPackage(
          _library!,
          await File(path).readAsBytes(),
          confirmReplace: _confirmReplace,
        );
      } else {
        entry = await _library!.importPdf(
          path,
          title: p.basenameWithoutExtension(files.first.name),
        );
      }
      // Opens at once; the sync sends it to Drive in the background.
      _sync.requestSoon();
      if (mounted) await _open(entry);
    } catch (e) {
      _say('تعذّر إضافة الملف: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmReplace(String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('«$title» عليه كتابة في هذا الجهاز'),
        content: const Text(
          'هل تستبدل الكتابة الموجودة هنا بالكتابة التي في الملف؟ إن اخترت «إبقاء» يُضاف الكتاب وتبقى كتابتك الحالية كما هي.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إبقاء كتابتي'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('استبدال'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---- a book's own actions ----

  Future<void> _showActions(BookEntry b) async {
    final r = await showNotsSheet<String>(
      context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(b.title),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: ActionRows(
                rows: [
                  ActionRow(
                    Icons.info_outline,
                    b.isNote ? 'معلومات الملاحظة' : 'معلومات الكتاب',
                    () => Navigator.pop(context, 'info'),
                  ),
                  ActionRow(
                    Icons.folder_special_outlined,
                    'إضافة إلى تجميعة',
                    () => Navigator.pop(context, 'collect'),
                  ),
                  if (!b.isNote && b.author.isNotEmpty)
                    ActionRow(
                      Icons.person_search_outlined,
                      'كل مؤلفات ${b.author}',
                      () => Navigator.pop(context, 'author'),
                    ),
                  ActionRow(
                    Icons.edit_outlined,
                    'إعادة التسمية',
                    () => Navigator.pop(context, 'rename'),
                  ),
                  ActionRow(
                    Icons.delete_outline,
                    b.isNote ? 'حذف الملاحظة' : 'إزالة من المكتبة',
                    () => Navigator.pop(context, 'remove'),
                    danger: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (r == 'info') await _showInfo(b);
    if (r == 'collect' && mounted) await showCollectionPicker(context, b);
    if (r == 'author' && mounted) {
      await AuthorScreen.open(
        context,
        author: b.author,
        store: _catalog,
        downloads: _downloads,
        library: _library!,
        onOpen: _open,
      );
    }
    if (r == 'rename') await _rename(b);
    if (r == 'remove') await _remove(b);
  }

  /// What is known about a book, in a small window.
  Future<void> _showInfo(BookEntry b) async {
    final c = b.catalogId == null ? null : _catalog.byId(b.catalogId!);
    String date(DateTime? d) =>
        d == null ? 'لم يُفتح بعد' : '${d.year}/${d.month}/${d.day}';
    final pages = (await ReaderPrefs.peekProgress(b.id))?.count;
    final rows = <(String, String)>[
      ('العنوان', b.title),
      if (b.author.isNotEmpty && !b.isNote) ('المؤلف', b.author),
      if (c != null && c.investigator.isNotEmpty) ('المحقق', c.investigator),
      if (b.subject.isNotEmpty && !b.isNote) ('التصنيف', b.subject),
      if (c != null && c.publisher.isNotEmpty) ('الناشر', c.publisher),
      if (c != null && c.edition.isNotEmpty) ('الطبعة', c.edition),
      if (b.part != null && (c?.partsCount ?? 1) > 1)
        ('الجزء', '${b.part} من ${c!.partsCount}'),
      if (pages != null && pages > 0) ('الصفحات', '$pages'),
      ('الحجم', '${(b.size / (1024 * 1024)).toStringAsFixed(1)} م.ب'),
      ('أُضيف', date(b.added)),
      ('آخر قراءة', date(b.readAt)),
      ('المكان', _library!.isOnDevice(b) ? 'على هذا الجهاز' : 'في حسابك فقط'),
    ];
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(b.isNote ? 'معلومات الملاحظة' : 'معلومات الكتاب'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (k, v) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 84,
                        child: Text(k, style: TextStyle(color: Brand.muted)),
                      ),
                      Expanded(
                        child: Text(
                          v,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BookEntry b) async {
    final c = TextEditingController(text: b.title);
    final t = await showNotsSheet<String>(
      context,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHeader('اسم الكتاب'),
                TextField(
                  controller: c,
                  autofocus: true,
                  onSubmitted: (v) => Navigator.pop(context, v.trim()),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('إلغاء'),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, c.text.trim()),
                        child: const Text('حفظ'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    c.dispose();
    if (t != null && t.isNotEmpty) await _library!.rename(b, t);
  }

  Future<void> _remove(BookEntry b) =>
      _account.linked ? _removeFromAccount(b) : _removeHere(b);

  /// With an account: the file can leave this device alone, or the book can
  /// leave the account, and with it every device.
  Future<void> _removeFromAccount(BookEntry b) async {
    final lib = _library!;
    final here = lib.isOnDevice(b) && !b.isNote;
    final choice = await showNotsSheet<String>(
      context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader('إزالة «${b.title}»'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                here
                    ? 'يمكن إزالة الملف من هذا الجهاز فقط، ويبقى الكتاب وكتابتك في حسابك. أو حذفه من حسابك ومن كل أجهزتك نهائياً.'
                    : 'حذف هذا ${b.isNote ? 'الملف' : 'الكتاب'} وكتابتك عليه من حسابك ومن كل أجهزتك نهائياً؟',
                style: TextStyle(color: Brand.muted, height: 1.7),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: ActionRows(
                rows: [
                  if (here)
                    ActionRow(
                      Icons.cloud_outlined,
                      'من هذا الجهاز',
                      () => Navigator.pop(context, 'here'),
                    ),
                  ActionRow(
                    Icons.delete_outline,
                    'حذف من كل مكان',
                    () => Navigator.pop(context, 'everywhere'),
                    danger: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (choice == 'here') {
      final saved = !(await _sync.unsaved()).any((e) => e.id == b.id);
      if (!saved) {
        _say('لم يُرفع هذا الكتاب إلى درايف بعد، فلم يُحذف من جهازك.');
        return;
      }
      await lib.offload(b);
    } else if (choice == 'everywhere') {
      await lib.remove(b, deleteWriting: true);
      Collections.instance.forget(b.id);
      await OwnCovers.instance.remove(b.id);
      try {
        await _sync.forget(b.id);
      } on Exception {
        _say('حُذف من هذا الجهاز، ويُحذف من درايف عند عودة الاتصال.');
      }
    }
  }

  Future<void> _removeHere(BookEntry b) async {
    var deleteWriting = b.isNote;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
            b.isNote ? 'حذف «${b.title}»؟' : 'إزالة «${b.title}» من المكتبة؟',
          ),
          content: b.isNote
              ? const Text('تُحذف الورقة وكل ما كتبته عليها.')
              : CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: deleteWriting,
                  onChanged: (v) => setState(() => deleteWriting = v ?? false),
                  title: const Text('احذف كتابتي عليه أيضاً'),
                  subtitle: const Text(
                    'إن لم تحذفها تعود الكتابة تلقائياً متى أضفت الملف نفسه مرة أخرى.',
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('تراجع'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(b.isNote ? 'حذف' : 'إزالة'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _library!.remove(b, deleteWriting: deleteWriting);
    Collections.instance.forget(b.id);
    if (deleteWriting) await OwnCovers.instance.remove(b.id);
  }

  // ---- the category buttons ----

  /// The same buttons in "my books" and in the catalogue: "all", then the
  /// categories of the catalogue (the most used first) and of the books the
  /// user added from files.
  List<String> _categories() {
    final counts = <String, int>{};
    for (final b in _catalog.books) {
      if (b.subject.isNotEmpty) {
        counts[b.subject] = (counts[b.subject] ?? 0) + 1;
      }
    }
    final top = counts.keys.toList()
      ..sort((a, b) {
        final c = masdarRank(a).compareTo(masdarRank(b));
        return c != 0 ? c : counts[b]!.compareTo(counts[a]!);
      });
    // All of them: the ones of the Masdar app in its order, then any the
    // library adds on the server.
    final out = top.toList();
    for (final b in _library!.books) {
      if (!b.isNote && b.subject.isNotEmpty && !out.contains(b.subject)) {
        out.add(b.subject);
      }
    }
    return ['الكل', ...out];
  }

  @override
  Widget build(BuildContext context) {
    final lib = _library;
    _visited.add(_tab);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Brand.paper,
        body: lib == null
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  Positioned.fill(
                    child: IndexedStack(
                      index: _tab,
                      children: [
                        BooksTab(
                          library: lib,
                          sync: _sync,
                          downloads: _downloads,
                          account: _account,
                          progress: _progress,
                          categories: _categories(),
                          onOpen: _open,
                          onMore: _showActions,
                          onAccount: _showAccount,
                          onHistory: _showHistory,
                          onBrowse: () => setState(() => _tab = 1),
                          onDriveWarning: _showAccount,
                          catalogTitle: (id) => _catalog.byId(id)?.title,
                        ),
                        if (!_visited.contains(1))
                          const SizedBox.shrink()
                        else
                          ListenableBuilder(
                            listenable: _catalog,
                            builder: (context, _) => CatalogScreen(
                              store: _catalog,
                              downloads: _downloads,
                              library: lib,
                              account: _account,
                              categories: _categories(),
                              onOpen: _open,
                              onAccount: _showAccount,
                              onHistory: _showHistory,
                            ),
                          ),
                        if (!_visited.contains(2))
                          const SizedBox.shrink()
                        else
                          NotesTab(
                            library: lib,
                            account: _account,
                            onOpen: _open,
                            onMore: _showActions,
                            onAccount: _showAccount,
                            onHistory: _showHistory,
                            onNew: _showNew,
                          ),
                      ],
                    ),
                  ),
                  HomeBar(
                    tab: _tab,
                    busy: _busy,
                    onTab: (i) => setState(() => _tab = i),
                    onNew: _showNew,
                  ),
                ],
              ),
      ),
    );
  }
}
