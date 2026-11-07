import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../catalog/catalog_screen.dart';
import '../catalog/catalog_store.dart';
import '../catalog/download_manager.dart';
import '../ink/ink_store.dart';
import '../notes/note_pdf.dart';
import '../notes/paper.dart';
import '../reader/reader_screen.dart';
import '../sync/drive_client.dart';
import '../sync/google_account.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_sheet.dart';
import '../ui/app_settings.dart';
import '../ui/brand_widgets.dart';
import '../ui/theme.dart';
import 'book_widgets.dart';
import 'books_tab.dart';
import 'home_bar.dart';
import 'home_sheets.dart';
import 'library_store.dart';
import 'notes_tab.dart';
import 'package_import.dart';

/// How many books "the last books" lists.
const historyCount = 10;

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
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        if (_library != null) _sync.requestSoon();
      },
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
    );
    await sync.finishWipe();
    // Stopped while being asked about another account's data: ask again.
    if (await sync.otherAccountsData()) await account.unlink();
    _catalog = catalog;
    _account = account;
    _sync = sync;
    _downloads = DownloadManager(lib, lib.root, afterImport: sync.afterImport);
    sync.fetchCatalogBook = _fetchFromLibrary;
    if (!mounted) return;
    setState(() => _library = lib);
    unawaited(catalog.refresh());
    sync.requestSoon();
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

  Future<void> _open(BookEntry b) async {
    final lib = _library!;
    if (!lib.isOnDevice(b)) {
      if (!_busy) await _bring(b);
      if (!lib.isOnDevice(b)) return;
    }
    await lib.touch(b);
    if (!mounted) return;
    _sync.openBook = b.id;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(library: lib, book: b),
      ),
    );
    _sync.openBook = null;
    _sync.requestSoon();
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
      beforeWipe: _downloads.cancelAll,
    ),
  );

  Future<void> _showHistory() async {
    final lib = _library!;
    final books = [
      for (final b in lib.books)
        if (!b.isNote) b,
    ].take(historyCount).toList();
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
      await _makeNote(r);
    } else if (r == NewPaperSheet.addBook) {
      await _add();
    }
  }

  Future<void> _makeNote(PaperStyle style) async {
    setState(() => _busy = true);
    try {
      final entry = await createNote(_library!, style);
      await _sync.afterImport(entry);
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
      await _sync.afterImport(entry);
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
    if (r == 'rename') await _rename(b);
    if (r == 'remove') await _remove(b);
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
            b.isNote
                ? 'حذف «${b.title}»؟'
                : 'إزالة «${b.title}» من المكتبة؟',
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
  }

  // ---- the category buttons ----

  /// The same buttons in "my books" and in the catalogue: "all", then the
  /// categories of the catalogue (the most used first) and of the books the
  /// user added from files.
  List<String> _categories() {
    final counts = <String, int>{};
    for (final b in _catalog.books) {
      if (b.subject.isNotEmpty) counts[b.subject] = (counts[b.subject] ?? 0) + 1;
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
                        ),
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
