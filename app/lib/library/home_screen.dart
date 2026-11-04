import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../book/book_text.dart';
import '../catalog/catalog_screen.dart';
import '../catalog/catalog_store.dart';
import '../catalog/cover_image.dart';
import '../catalog/download_manager.dart';
import '../ink/ink_store.dart';
import '../reader/reader_prefs.dart';
import '../reader/reader_screen.dart';
import '../sync/drive_client.dart';
import '../sync/google_account.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_sheet.dart';
import 'library_store.dart';
import 'package_import.dart';

enum _BookSort { recent, title, author, subject }

const _sortNames = {
  _BookSort.recent: 'آخر ما فُتح',
  _BookSort.title: 'العنوان',
  _BookSort.author: 'المؤلف',
  _BookSort.subject: 'التصنيف',
};

/// How many books the "continue reading" row shows.
const _recentCount = 8;

/// The main screen, with two tabs: the books on this device, and the library
/// on the server to download from.
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
  int _tab = 0;
  String _filter = '';
  String _subject = '';
  _BookSort _sort = _BookSort.recent;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        if (_library != null) _sync.requestSoon();
      },
    );
    _init();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _init() async {
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
      drive: () =>
          DriveClient(({renew = false}) => account.accessToken(renew: renew)),
    );
    _catalog = catalog;
    _account = account;
    _sync = sync;
    _downloads = DownloadManager(lib, lib.root, afterImport: sync.afterImport);
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

  Future<void> _open(BookEntry b) async {
    final lib = _library!;
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
    if (mounted) setState(() {});
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Brings back a book listed in Drive: from the library when it is there,
  /// else from the copy of its PDF in Drive. The saved work comes with it.
  Future<void> _restore(RemoteBook r) async {
    final id = r.catalogId;
    final book = id == null ? null : _catalog.byId(id);
    final part = book?.partNumbered(r.part ?? 1);
    if (book != null && part != null) {
      _downloads.enqueue(book, part);
      return;
    }
    setState(() => _busy = true);
    try {
      await _sync.restoreFromDrive(r);
    } catch (e) {
      _say(
        r.pdfFile == null
            ? 'لم يعد هذا الكتاب متوفراً في المكتبة، وكتابتك عليه محفوظة في درايف.'
            : 'تعذّر التحميل: $e',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetRemote(RemoteBook r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('حذف «${r.title}» من درايف؟'),
        content: const Text('تُحذف كتابتك وعلاماتك على هذا الكتاب نهائياً.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _sync.forget(r.id);
    } on Exception catch (e) {
      _say('تعذّر الحذف: $e');
    }
  }

  void _showSync() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => SyncSheet(account: _account, sync: _sync),
  );

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر ملف PDF أو ملف نوتس (.nots).')),
      );
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذّر إضافة الملف: $e')));
      }
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

  Future<void> _rename(BookEntry b) async {
    final c = TextEditingController(text: b.title);
    final t = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اسم الكتاب'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    c.dispose();
    if (t != null && t.isNotEmpty) await _library!.rename(b, t);
  }

  Future<void> _remove(BookEntry b) async {
    var deleteWriting = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('إزالة «${b.title}» من المكتبة؟'),
          content: CheckboxListTile(
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
              child: const Text('إزالة'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _library!.remove(b, deleteWriting: deleteWriting);
    if (!deleteWriting) return;
    try {
      await _sync.forget(b.id);
    } on Exception {
      _say('حُذف من هذا الجهاز، وتعذّر حذفه من درايف الآن.');
    }
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'الآن';
    if (d.inHours < 1) return 'قبل ${d.inMinutes} دقيقة';
    if (d.inDays < 1) return 'قبل ${d.inHours} ساعة';
    if (d.inDays < 30) return 'قبل ${d.inDays} يوم';
    return t.toLocal().toString().substring(0, 10);
  }

  List<BookEntry> _sorted(List<BookEntry> all) {
    final q = normalizeForSearch(_filter).text.trim();
    final out = [
      for (final b in all)
        if ((_subject.isEmpty || b.subject == _subject) &&
            (q.isEmpty ||
                normalizeForSearch('${b.title} ${b.author}').text.contains(q)))
          b,
    ];
    int byTitle(BookEntry a, BookEntry b) => a.title.compareTo(b.title);
    switch (_sort) {
      case _BookSort.recent:
        break; // the library's own order
      case _BookSort.title:
        out.sort(byTitle);
      case _BookSort.author:
        out.sort((a, b) {
          final c = a.author.compareTo(b.author);
          return c != 0 ? c : byTitle(a, b);
        });
      case _BookSort.subject:
        out.sort((a, b) {
          final c = a.subject.compareTo(b.subject);
          return c != 0 ? c : byTitle(a, b);
        });
    }
    return out;
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _recents(List<BookEntry> all) => SizedBox(
    height: 190,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final b in all.take(_recentCount))
          _RecentCard(book: b, onTap: () => _open(b)),
      ],
    ),
  );

  Widget _remoteTile(RemoteBook r) {
    final id = r.catalogId;
    final loading = id != null && _downloads.taskOf(id, r.part ?? 1) != null;
    return Card(
      child: ListTile(
        leading: CoverImage(r.cover, width: 40, height: 56),
        title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: const Text('كتابتك عليه محفوظة في درايف'),
        trailing: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                tooltip: 'تنزيل',
                icon: const Icon(Icons.download),
                onPressed: _busy ? null : () => _restore(r),
              ),
        onLongPress: () => _forgetRemote(r),
      ),
    );
  }

  Widget _bookTile(BookEntry b) => Card(
    child: ListTile(
      leading: CoverImage(b.cover, width: 40, height: 56),
      title: Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        joinFacts([b.author, formatSize(b.size), _ago(b.lastOpened)]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _open(b),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'rename' ? _rename(b) : _remove(b),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'rename', child: Text('إعادة التسمية')),
          PopupMenuItem(value: 'remove', child: Text('إزالة من المكتبة')),
        ],
      ),
    ),
  );

  Widget _listTools(List<BookEntry> all) {
    final subjects = ({for (final b in all) b.subject}..remove('')).toList()
      ..sort();
    return Row(
      children: [
        Expanded(child: _heading('كل الكتب (${all.length})')),
        if (subjects.isNotEmpty)
          PopupMenuButton<String>(
            tooltip: 'التصنيف',
            icon: Icon(
              Icons.filter_list,
              color: _subject.isEmpty
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
            onSelected: (v) => setState(() => _subject = v),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: '',
                checked: _subject.isEmpty,
                child: const Text('كل التصنيفات'),
              ),
              for (final s in subjects)
                CheckedPopupMenuItem(
                  value: s,
                  checked: s == _subject,
                  child: Text(s),
                ),
            ],
          ),
        PopupMenuButton<_BookSort>(
          tooltip: 'الترتيب',
          icon: const Icon(Icons.sort),
          onSelected: (v) => setState(() => _sort = v),
          itemBuilder: (_) => [
            for (final e in _sortNames.entries)
              CheckedPopupMenuItem(
                value: e.key,
                checked: e.key == _sort,
                child: Text(e.value),
              ),
          ],
        ),
      ],
    );
  }

  Widget _emptyLibrary() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'مكتبتك فارغة.\n\nنزّل كتاباً من خانة «تحميل»، أو أضف ملفاً من جهازك. تبقى كتابتك في ملف منفصل ولا يتغيّر الكتاب الأصلي.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () => setState(() => _tab = 1),
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('تصفّح المكتبة'),
          ),
          if (!_account.linked) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _showSync,
              icon: const Icon(Icons.login),
              label: const Text('استعادة كتابتي من درايف'),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _booksTab(LibraryStore lib) => ListenableBuilder(
    listenable: Listenable.merge([lib, _sync, _downloads, _account]),
    builder: (context, _) {
      final all = lib.books;
      final remote = _sync.remoteOnly;
      if (all.isEmpty && remote.isEmpty) return _emptyLibrary();
      final searching = _filter.trim().isNotEmpty;
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        children: [
          if (all.length > 5)
            TextField(
              decoration: const InputDecoration(
                hintText: 'ابحث في كتبك',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          if (all.isNotEmpty && !searching) ...[
            _heading('تابع القراءة'),
            _recents(all),
          ],
          if (remote.isNotEmpty && !searching) ...[
            _heading('في درايف'),
            for (final r in remote) _remoteTile(r),
          ],
          if (all.isNotEmpty) ...[
            _listTools(all),
            for (final b in _sorted(all)) _bookTile(b),
          ],
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final lib = _library;
    return Scaffold(
      appBar: AppBar(
        title: const Text('نوتس'),
        actions: [
          if (lib != null)
            ListenableBuilder(
              listenable: _account,
              builder: (context, _) => IconButton(
                tooltip: 'Google Drive',
                onPressed: _showSync,
                icon: Icon(
                  _account.linked
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: 'الكتب',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_download_outlined),
            selectedIcon: Icon(Icons.cloud_download),
            label: 'تحميل',
          ),
        ],
      ),
      floatingActionButton: _tab != 0
          ? null
          : FloatingActionButton.extended(
              onPressed: lib == null || _busy ? null : _add,
              icon: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: const Text('إضافة كتاب'),
            ),
      body: lib == null
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _tab,
              children: [
                _booksTab(lib),
                CatalogScreen(
                  store: _catalog,
                  downloads: _downloads,
                  library: lib,
                  onOpen: _open,
                ),
              ],
            ),
    );
  }
}

/// A book in the "continue reading" row. Opening it goes to the exact place
/// and zoom it was left at; the page shown here is only a reminder.
class _RecentCard extends StatefulWidget {
  const _RecentCard({required this.book, required this.onTap});

  final BookEntry book;
  final VoidCallback onTap;

  @override
  State<_RecentCard> createState() => _RecentCardState();
}

class _RecentCardState extends State<_RecentCard> {
  int? _page;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_RecentCard old) {
    super.didUpdateWidget(old);
    _load();
  }

  Future<void> _load() async {
    final n = await ReaderPrefs.peekPage(widget.book.id);
    if (mounted && n != _page) setState(() => _page = n);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      width: 104,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverImage(widget.book.cover, width: 96, height: 124),
              const SizedBox(height: 4),
              Text(
                widget.book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelMedium,
              ),
              if (_page != null) Text('صفحة $_page', style: text.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}
